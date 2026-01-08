package store

import (
	"context"
	"encoding/json"
	"os"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

type idemRow struct {
	Status       string
	TxID         *uuid.UUID
	ResponseText []byte
}

func TestPostTransfer_AnchorsStableResponseJSON(t *testing.T) {
	dsn := os.Getenv("LEDGER_DB_DSN")
	if dsn == "" {
		dsn = os.Getenv("TEST_DATABASE_URL")
	}
	if dsn == "" {
		t.Skip("missing LEDGER_DB_DSN or TEST_DATABASE_URL")
	}

	ctx := context.Background()

	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("pgxpool.New: %v", err)
	}
	defer pool.Close()

	s := New(pool)

	corr := "corr-" + uuid.NewString()

	fromID, err := s.CreateAccount(ctx, "from", "EUR", corr)
	if err != nil {
		t.Fatalf("CreateAccount(from): %v", err)
	}
	toID, err := s.CreateAccount(ctx, "to", "EUR", corr)
	if err != nil {
		t.Fatalf("CreateAccount(to): %v", err)
	}

	idemKey := "idem-" + uuid.NewString()
	externalRef := "ext-" + uuid.NewString()

	// First call
	txID1, err := s.PostTransfer(ctx, fromID, toID, 123, "EUR", externalRef, idemKey, corr)
	if err != nil {
		t.Fatalf("PostTransfer(1): %v", err)
	}

	// Replay must return same tx_id
	txID2, err := s.PostTransfer(ctx, fromID, toID, 123, "EUR", externalRef, idemKey, corr)
	if err != nil {
		t.Fatalf("PostTransfer(2): %v", err)
	}
	if txID2 != txID1 {
		t.Fatalf("replay tx_id mismatch: got=%s want=%s", txID2, txID1)
	}

	// Verify idempotency row
	var row idemRow
	err = pool.QueryRow(ctx,
		`SELECT status, tx_id, response_json::text
		   FROM idempotency
		  WHERE key=$1`,
		idemKey,
	).Scan(&row.Status, &row.TxID, &row.ResponseText)
	if err != nil {
		t.Fatalf("select idempotency: %v", err)
	}

	if row.Status != "COMMITTED" {
		t.Fatalf("status: got=%s want=COMMITTED", row.Status)
	}
	if row.TxID == nil {
		t.Fatalf("tx_id is NULL")
	}
	if *row.TxID != txID1 {
		t.Fatalf("tx_id mismatch: got=%s want=%s", row.TxID, txID1)
	}
	if len(row.ResponseText) == 0 {
		t.Fatalf("response_json empty")
	}

	// Semantic check: response_json contains exactly tx_id (at least)
	var resp struct {
		TxID string `json:"tx_id"`
	}
	if err := json.Unmarshal(row.ResponseText, &resp); err != nil {
		t.Fatalf("response_json invalid json: %v; raw=%s", err, string(row.ResponseText))
	}
	if resp.TxID != txID1.String() {
		t.Fatalf("response_json.tx_id mismatch: got=%s want=%s", resp.TxID, txID1.String())
	}

	// Stability check: response_json must not change on replay
	var after []byte
	err = pool.QueryRow(ctx,
		`SELECT response_json::text FROM idempotency WHERE key=$1`,
		idemKey,
	).Scan(&after)
	if err != nil {
		t.Fatalf("select response_json again: %v", err)
	}
	if string(after) != string(row.ResponseText) {
		t.Fatalf("response_json changed on replay: before=%s after=%s", string(row.ResponseText), string(after))
	}
}
