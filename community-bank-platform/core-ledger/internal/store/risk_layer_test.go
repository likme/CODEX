// core-ledger/internal/store/risk_layer_test.go
package store

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestRiskLayer_EventLogProofs_AppendOnly_ChainOK(t *testing.T) {
	pool := newTestPool(t)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := Migrate(ctx, pool); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	corr := "t-risk-" + uuid.NewString()

	asOf := time.Date(2020, 2, 14, 0, 0, 0, 0, time.UTC)
	ingestCorr := "ingest-" + corr + "-" + asOf.Format("2006-01-02")

	valPayload := map[string]any{"source": "fred", "note": "test"}
	valPayloadJCS := mustJCS(t, valPayload)
	valHash := riskPayloadHashValuation("RATE", "FRED:DGS10", asOf, "4.06", "USD", "fred", 90, valPayloadJCS)

	_, err := pool.Exec(ctx, `
		INSERT INTO valuation_snapshot(
			snapshot_id,
			ingestion_correlation_id,
			asset_type,
			asset_id,
			as_of,
			price,
			currency,
			source,
			confidence,
			payload_json,
			payload_canonical,
			payload_hash
		) VALUES (
			$1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,$11,$12
		)
	`,
		uuid.New(),
		ingestCorr,
		"RATE",
		"FRED:DGS10",
		asOf,
		"4.06",
		"USD",
		"fred",
		90,
		string(valPayloadJCS),
		string(valPayloadJCS),
		valHash[:],
	)
	if err != nil {
		t.Fatalf("insert valuation_snapshot: %v", err)
	}

	liqPayload := map[string]any{"source": "synthetic", "note": "test"}
	liqPayloadJCS := mustJCS(t, liqPayload)
	liqHash := riskPayloadHashLiquidity("FX", "ECB:EXR.D.USD.EUR.SP00.A", asOf, 0, 0, "synthetic", liqPayloadJCS)

	_, err = pool.Exec(ctx, `
		INSERT INTO liquidity_snapshot(
			snapshot_id,
			ingestion_correlation_id,
			asset_type,
			asset_id,
			as_of,
			haircut_bps,
			time_to_cash_seconds,
			source,
			payload_json,
			payload_canonical,
			payload_hash
		) VALUES (
			$1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10,$11
		)
	`,
		uuid.New(),
		ingestCorr,
		"FX",
		"ECB:EXR.D.USD.EUR.SP00.A",
		asOf,
		0,
		0,
		"synthetic",
		string(liqPayloadJCS),
		string(liqPayloadJCS),
		liqHash[:],
	)
	if err != nil {
		t.Fatalf("insert liquidity_snapshot: %v", err)
	}

	verifyEventChain(t, pool)
	assertSeqContiguous(t, pool)
}
