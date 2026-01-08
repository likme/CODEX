// core-ledger/internal/store/geoshock_risk_scenario_test.go
package store_test

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"core-ledger/internal/store"
)

type phase struct {
	name string
	asOf time.Time
	v    map[string]string
	h    map[string]int
}

func TestScenario_GeoShock_RiskLayer(t *testing.T) {
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

	phases := []phase{
		{
			name: "NORMAL",
			asOf: time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC),
			v: map[string]string{
				"BOND_GOV_10Y":     "100",
				"BOND_BANK_SENIOR": "100",
			},
			h: map[string]int{
				"BOND_GOV_10Y":     200,
				"BOND_BANK_SENIOR": 200,
			},
		},
		{
			name: "GEO_SHOCK",
			asOf: time.Date(2025, 1, 2, 0, 0, 0, 0, time.UTC),
			v: map[string]string{
				"BOND_GOV_10Y":     "60",
				"BOND_BANK_SENIOR": "60",
			},
			h: map[string]int{
				"BOND_GOV_10Y":     2500,
				"BOND_BANK_SENIOR": 2500,
			},
		},
		{
			name: "CONTAGION",
			asOf: time.Date(2025, 1, 3, 0, 0, 0, 0, time.UTC),
			v:    map[string]string{},
			h: map[string]int{
				"BOND_GOV_10Y":     4000,
				"BOND_BANK_SENIOR": 4000,
			},
		},
		{
			name: "BACKSTOP",
			asOf: time.Date(2025, 1, 4, 0, 0, 0, 0, time.UTC),
			v: map[string]string{
				"BOND_GOV_10Y":     "80",
				"BOND_BANK_SENIOR": "75",
			},
			h: map[string]int{
				"BOND_GOV_10Y":     1000,
				"BOND_BANK_SENIOR": 1000,
			},
		},
	}

	assetType := "BOND"
	currency := "EUR"
	source := "scenario"

	totalInserts := 0
	for _, p := range phases {
		ingestCorr := "ingest-GeoShock-" + p.name + "-" + p.asOf.Format("2006-01-02")
		payloadObj := map[string]any{"phase": p.name}

		for assetID, price := range p.v {
			if err := insertValuation(ctx, t, pool, assetType, assetID, p.asOf, price, currency, source, 90, ingestCorr, payloadObj); err != nil {
				t.Fatalf("%s: insert valuation: %v", p.name, err)
			}
			totalInserts++
		}
		for assetID, haircut := range p.h {
			if err := insertLiquidity(ctx, t, pool, assetType, assetID, p.asOf, haircut, 86400, source, ingestCorr, payloadObj); err != nil {
				t.Fatalf("%s: insert liquidity: %v", p.name, err)
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

	if _, err := pool.Exec(ctx, `UPDATE valuation_snapshot SET price = price + 1`); err == nil {
		t.Fatalf("expected UPDATE valuation_snapshot to fail (append-only), but it succeeded")
	}
	if _, err := pool.Exec(ctx, `DELETE FROM liquidity_snapshot`); err == nil {
		t.Fatalf("expected DELETE liquidity_snapshot to fail (append-only), but it succeeded")
	}

	if _, err := pool.Exec(ctx, `SELECT verify_event_chain()`); err != nil {
		t.Fatalf("verify_event_chain failed: %v", err)
	}

	m0 := mustMobilisable(ctx, t, pool, phases[0].asOf)
	m1 := mustMobilisable(ctx, t, pool, phases[1].asOf)
	m2 := mustMobilisable(ctx, t, pool, phases[2].asOf)
	m3 := mustMobilisable(ctx, t, pool, phases[3].asOf)

	if !(m1 < m0) {
		t.Fatalf("expected GEO_SHOCK mobilisable < NORMAL, got m0=%f m1=%f", m0, m1)
	}
	if !(m2 < m1) {
		t.Fatalf("expected CONTAGION mobilisable < GEO_SHOCK, got m1=%f m2=%f", m1, m2)
	}
	if !(m3 > m2) {
		t.Fatalf("expected BACKSTOP mobilisable > CONTAGION, got m2=%f m3=%f", m2, m3)
	}
}

func insertValuation(
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
	`, assetType, assetID, asOf, price, currency, source, confidence, ingestionCorrelationID, string(jcs), string(jcs), h[:])
	return err
}

func insertLiquidity(
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
	`, assetType, assetID, asOf, haircutBps, ttcSeconds, source, ingestionCorrelationID, string(jcs), string(jcs), h[:])
	return err
}

func mustMobilisable(ctx context.Context, t *testing.T, pool *pgxpool.Pool, asOf time.Time) float64 {
	t.Helper()

	var total float64
	err := pool.QueryRow(ctx, `
		WITH v AS (
		  SELECT DISTINCT ON (asset_type, asset_id)
		    asset_type, asset_id, price::float8 AS price
		  FROM valuation_snapshot
		  WHERE as_of <= $1
		  ORDER BY asset_type, asset_id, as_of DESC, snapshot_id DESC
		),
		l AS (
		  SELECT DISTINCT ON (asset_type, asset_id)
		    asset_type, asset_id, haircut_bps
		  FROM liquidity_snapshot
		  WHERE as_of <= $1
		  ORDER BY asset_type, asset_id, as_of DESC, snapshot_id DESC
		)
		SELECT COALESCE(SUM(v.price * ((10000 - l.haircut_bps)::float8 / 10000.0)), 0)::float8
		FROM v JOIN l USING(asset_type, asset_id)
	`, asOf).Scan(&total)
	if err != nil {
		t.Fatalf("mobilisable query: %v", err)
	}
	return total
}
