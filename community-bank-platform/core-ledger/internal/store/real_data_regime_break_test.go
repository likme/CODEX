package store_test

import (
	"context"
	"crypto/sha256"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"core-ledger/internal/store"

	"path/filepath"
	"runtime"
)

func TestScenario_RealData_RegimeBreak_RiskLayer(t *testing.T) {
	ctx := context.Background()

	dsn := os.Getenv("LEDGER_DB_DSN")
	if dsn == "" {
		t.Skip("LEDGER_DB_DSN is required")
	}

	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("pgxpool new: %v", err)
	}
	defer pool.Close()

	if err := store.Migrate(ctx, pool); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	path := os.Getenv("REAL_DATA_REGIME_BREAK_CSV")
	if path == "" {
		_, thisFile, _, ok := runtime.Caller(0)
		if !ok {
			t.Fatal("runtime.Caller failed")
		}
		// thisFile = .../internal/store/real_data_regime_break_test.go
		path = filepath.Join(filepath.Dir(thisFile), "testdata", "real_data_regime_break.csv")
	}

	f, err := os.Open(path)
	if err != nil {
		t.Skipf("missing CSV fixture %q: %v", path, err)
	}
	defer f.Close()

	r := csv.NewReader(f)
	r.FieldsPerRecord = -1

	records, err := r.ReadAll()
	if err != nil {
		t.Fatalf("read csv: %v", err)
	}
	if len(records) < 2 {
		t.Fatalf("csv: expected header + rows")
	}

	header := records[0]
	col := make(map[string]int, len(header))
	for i, h := range header {
		col[h] = i
	}

	get := func(row []string, name string) string {
		i, ok := col[name]
		if !ok || i >= len(row) {
			return ""
		}
		return row[i]
	}

	assetType := "REALDATA"
	source := "fixture"

	totalInserts := 0

	for _, row := range records[1:] {
		asOfStr := get(row, "as_of")
		assetID := get(row, "asset_id")
		priceStr := get(row, "price")
		ccy := get(row, "currency")
		haircutStr := get(row, "haircut_bps")
		ttcStr := get(row, "time_to_cash_seconds")

		if asOfStr == "" || assetID == "" {
			continue
		}

		asOf, err := time.Parse(time.RFC3339, asOfStr)
		if err != nil {
			t.Fatalf("parse as_of %q: %v", asOfStr, err)
		}

		ingestCorr := "ingest-RealData-RegimeBreak-" + assetID + "-" + asOf.UTC().Format("2006-01-02")

		// payload is traceable and deterministic
		payloadObj := map[string]any{
			"fixture": "real_data_regime_break",
			"asset":   assetID,
			"as_of":   asOf.UTC().Format(time.RFC3339Nano),
		}

		if priceStr != "" {
			confidence := 90
			if err := insertValuationRegimeBreak(ctx, t, pool, assetType, assetID, asOf, priceStr, ccy, source, confidence, ingestCorr, payloadObj); err != nil {
				t.Fatalf("insert valuation asset=%s asOf=%s: %v", assetID, asOfStr, err)
			}
			totalInserts++
		}

		if haircutStr != "" && ttcStr != "" {
			haircutBps, err := strconv.Atoi(haircutStr)
			if err != nil {
				t.Fatalf("parse haircut_bps %q: %v", haircutStr, err)
			}
			ttcSeconds, err := strconv.Atoi(ttcStr)
			if err != nil {
				t.Fatalf("parse time_to_cash_seconds %q: %v", ttcStr, err)
			}

			if err := insertLiquidityRegimeBreak(ctx, t, pool, assetType, assetID, asOf, haircutBps, ttcSeconds, source, ingestCorr, payloadObj); err != nil {
				t.Fatalf("insert liquidity asset=%s asOf=%s: %v", assetID, asOfStr, err)
			}
			totalInserts++
		}
	}

	var evCount int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM event_log WHERE aggregate_type = 'RISK_SNAPSHOT'`).Scan(&evCount); err != nil {
		t.Fatalf("count event_log: %v", err)
	}
	if evCount != totalInserts {
		t.Fatalf("expected %d RISK_SNAPSHOT events, got %d", totalInserts, evCount)
	}

	if _, err := pool.Exec(ctx, `SELECT verify_event_chain()`); err != nil {
		t.Fatalf("verify_event_chain failed: %v", err)
	}
}

func insertValuationRegimeBreak(
	ctx context.Context,
	t *testing.T,
	pool *pgxpool.Pool,
	assetType, assetID string,
	asOf time.Time,
	price, currency, source string,
	confidence int,
	ingestionCorrelationID string,
	payload any,
) error {
	t.Helper()

	jcs := mustJCS(t, payload)
	h := riskPayloadHashValuation(assetType, assetID, asOf, price, currency, source, confidence, jcs)

	// payload_json must match canonical content but can be stored as jsonb; we reuse the JCS string.
	_, err := pool.Exec(ctx, `
		INSERT INTO valuation_snapshot(
			asset_type,
			asset_id,
			as_of,
			price,
			currency,
			source,
			confidence,
			ingestion_correlation_id,
			payload_json,
			payload_canonical,
			payload_hash
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10,$11)
	`,
		assetType,
		assetID,
		asOf,
		price,
		currency,
		source,
		confidence,
		ingestionCorrelationID,
		string(jcs),
		string(jcs),
		h[:],
	)
	return err
}

func insertLiquidityRegimeBreak(
	ctx context.Context,
	t *testing.T,
	pool *pgxpool.Pool,
	assetType, assetID string,
	asOf time.Time,
	haircutBps int,
	ttcSeconds int,
	source string,
	ingestionCorrelationID string,
	payload any,
) error {
	t.Helper()

	jcs := mustJCS(t, payload)
	h := riskPayloadHashLiquidity(assetType, assetID, asOf, haircutBps, ttcSeconds, source, jcs)

	_, err := pool.Exec(ctx, `
		INSERT INTO liquidity_snapshot(
			asset_type,
			asset_id,
			as_of,
			haircut_bps,
			time_to_cash_seconds,
			source,
			ingestion_correlation_id,
			payload_json,
			payload_canonical,
			payload_hash
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9,$10)
	`,
		assetType,
		assetID,
		asOf,
		haircutBps,
		ttcSeconds,
		source,
		ingestionCorrelationID,
		string(jcs),
		string(jcs),
		h[:],
	)
	return err
}

// keep this tiny helper if the file already used it elsewhere;
// otherwise it is harmless and local to this test file.
func stableRowID(parts ...string) string {
	h := sha256.Sum256([]byte(fmt.Sprintf("%v", parts)))
	return fmt.Sprintf("%x", h[:8])
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("json marshal: %v", err)
	}
	return string(b)
}
