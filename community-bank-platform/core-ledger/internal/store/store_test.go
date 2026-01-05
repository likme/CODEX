package store_test

import (
	"context"
	"os"
	"testing"
	"time"

	"core-ledger/internal/store"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func testPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("LEDGER_DB_DSN")
	if dsn == "" {
		dsn = "postgres://ledger:ledger@localhost:5432/ledger?sslmode=disable"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pool.Close() })
	return pool
}

func TestDoubleEntryAndIdempotency(t *testing.T) {
	pool := testPool(t)
	ctx := context.Background()

	if err := store.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}

	st := store.New(pool)
	corr := uuid.New().String()

	a, err := st.CreateAccount(ctx, "A-"+uuid.NewString(), "EUR", corr)
	if err != nil {
		t.Fatal(err)
	}
	b, err := st.CreateAccount(ctx, "B-"+uuid.NewString(), "EUR", corr)
	if err != nil {
		t.Fatal(err)
	}

	// Mint: system -> A via synthetic system account.
	sys, err := st.CreateAccount(ctx, "SYSTEM-"+uuid.NewString(), "EUR", corr)
	if err != nil {
		t.Fatal(err)
	}

	// Use unique refs/keys per test run to avoid collisions against a reused DB.
	mintIdem := "idem-mint-" + uuid.NewString()
	mintExt := "mint-" + mintIdem
	if _, err := st.PostTransfer(ctx, sys, a, int64(10000), "EUR", mintExt, mintIdem, corr); err != nil {
		t.Fatal(err)
	}

	// Transfer A -> B (idempotent)
	idem := "idem-pmt-" + uuid.NewString()
	ext := "pmt-" + idem

	tx1, err := st.PostTransfer(ctx, a, b, int64(2500), "EUR", ext, idem, corr)
	if err != nil {
		t.Fatal(err)
	}

	// Same again must return same tx id.
	tx2, err := st.PostTransfer(ctx, a, b, int64(2500), "EUR", ext, idem, corr)
	if err != nil {
		t.Fatal(err)
	}
	if tx1 != tx2 {
		t.Fatalf("expected same tx id for idempotent call, got %s vs %s", tx1, tx2)
	}

	_, balA, err := st.Balance(ctx, a)
	if err != nil {
		t.Fatal(err)
	}
	_, balB, err := st.Balance(ctx, b)
	if err != nil {
		t.Fatal(err)
	}
	if balA != 7500 {
		t.Fatalf("A balance expected 7500, got %d", balA)
	}
	if balB != 2500 {
		t.Fatalf("B balance expected 2500, got %d", balB)
	}
}
