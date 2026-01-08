// core-ledger/internal/store/real_data_scenario_test.go
package store_test

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"core-ledger/internal/store"
)

type RealScenario struct {
	ScenarioID  string `json:"scenario_id"`
	Description string `json:"description"`
	Phases      []struct {
		PhaseID    string `json:"phase_id"`
		AsOf       string `json:"as_of"`
		Valuations []struct {
			AssetType  string         `json:"asset_type"`
			AssetID    string         `json:"asset_id"`
			AsOf       string         `json:"as_of"`
			Price      string         `json:"price"`
			Currency   string         `json:"currency"`
			Source     string         `json:"source"`
			Confidence int            `json:"confidence"`
			Payload    map[string]any `json:"payload"`
		} `json:"valuations"`
		Liquidities []struct {
			AssetType         string         `json:"asset_type"`
			AssetID           string         `json:"asset_id"`
			AsOf              string         `json:"as_of"`
			HaircutBps        int            `json:"haircut_bps"`
			TimeToCashSeconds int            `json:"time_to_cash_seconds"`
			Source            string         `json:"source"`
			Payload           map[string]any `json:"payload"`
		} `json:"liquidities"`
	} `json:"phases"`
}

func TestScenario_RealPublicData_Covid2020(t *testing.T) {
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

	b, err := os.ReadFile("testdata/real_covid2020.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}

	var sc RealScenario
	if err := json.Unmarshal(b, &sc); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	if sc.ScenarioID == "" || len(sc.Phases) == 0 {
		t.Fatalf("bad fixture: missing scenario_id or phases")
	}

	totalInserts := 0

	for _, p := range sc.Phases {
		asOf, err := time.Parse(time.RFC3339, p.AsOf)
		if err != nil {
			t.Fatalf("bad phase as_of %q: %v", p.AsOf, err)
		}
		ingestCorr := "ingest-" + sc.ScenarioID + "-" + p.PhaseID + "-" + asOf.Format("2006-01-02")

		for _, v := range p.Valuations {
			payloadJCS := mustJCS(t, v.Payload)
			payloadHash := riskPayloadHashValuation(
				v.AssetType, v.AssetID, asOf, v.Price, v.Currency, v.Source, v.Confidence, payloadJCS,
			)

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
			`, v.AssetType, v.AssetID, asOf, v.Price, v.Currency, v.Source, v.Confidence, ingestCorr,
				string(payloadJCS), string(payloadJCS), payloadHash[:],
			)
			if err != nil {
				t.Fatalf("phase %s: insert valuation: %v", p.PhaseID, err)
			}
			totalInserts++
		}

		for _, l := range p.Liquidities {
			payloadJCS := mustJCS(t, l.Payload)
			payloadHash := riskPayloadHashLiquidity(
				l.AssetType, l.AssetID, asOf, l.HaircutBps, l.TimeToCashSeconds, l.Source, payloadJCS,
			)

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
			`, l.AssetType, l.AssetID, asOf, l.HaircutBps, l.TimeToCashSeconds, l.Source, ingestCorr,
				string(payloadJCS), string(payloadJCS), payloadHash[:],
			)
			if err != nil {
				t.Fatalf("phase %s: insert liquidity: %v", p.PhaseID, err)
			}
			totalInserts++
		}
	}

	var evCount int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM event_log WHERE aggregate_type='RISK_SNAPSHOT'`).Scan(&evCount); err != nil {
		t.Fatalf("count event_log: %v", err)
	}
	if evCount != totalInserts {
		t.Fatalf("expected %d RISK_SNAPSHOT events, got %d", totalInserts, evCount)
	}

	if _, err := pool.Exec(ctx, `SELECT verify_event_chain()`); err != nil {
		t.Fatalf("verify_event_chain failed: %v", err)
	}
}
