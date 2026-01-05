package store

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func mustEnv(t *testing.T, key string) string {
	t.Helper()
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		t.Skipf("missing %s env var", key)
	}
	return v
}

func applySchema(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()

	// Test runner cwd is typically the package dir: internal/store
	sqlPath := filepath.Join("migrations", "000_genesis.sql")
	b, err := os.ReadFile(sqlPath)
	if err != nil {
		t.Fatalf("read schema %s: %v", sqlPath, err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	_, err = pool.Exec(ctx, string(b))
	if err != nil {
		t.Fatalf("apply schema: %v", err)
	}
}

func newTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()

	dsn := mustEnv(t, "LEDGER_DB_DSN")

	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatalf("parse dsn: %v", err)
	}
	// Concurrency tests. Keep it bounded.
	cfg.MaxConns = 20
	cfg.MinConns = 1

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("ping: %v", err)
	}
	return pool
}

func verifyEventChain(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var ok bool
	err := pool.QueryRow(ctx, `SELECT verify_event_chain()`).Scan(&ok)
	if err != nil {
		t.Fatalf("verify_event_chain query: %v", err)
	}
	if !ok {
		t.Fatalf("verify_event_chain returned false")
	}
}

func assertSeqContiguous(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var cnt, minSeq, maxSeq int64
	err := pool.QueryRow(ctx,
		`SELECT count(*), COALESCE(min(seq),0), COALESCE(max(seq),0) FROM event_log`,
	).Scan(&cnt, &minSeq, &maxSeq)
	if err != nil {
		t.Fatalf("seq stats: %v", err)
	}
	if cnt == 0 {
		return
	}
	if cnt != (maxSeq - minSeq + 1) {
		t.Fatalf("seq not contiguous: count=%d min=%d max=%d", cnt, minSeq, maxSeq)
	}
}

func TestConcurrentSameIdempotencyKey_ReplaysSameTxID(t *testing.T) {
	// Not parallel. Shares DB.
	pool := newTestPool(t)
	applySchema(t, pool)

	s := New(pool)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	alice, err := s.CreateAccount(ctx, "Alice-"+uuid.NewString(), "EUR", "t-conc-1")
	if err != nil {
		t.Fatalf("CreateAccount alice: %v", err)
	}
	bob, err := s.CreateAccount(ctx, "Bob-"+uuid.NewString(), "EUR", "t-conc-1")
	if err != nil {
		t.Fatalf("CreateAccount bob: %v", err)
	}
	sys, err := s.CreateAccount(ctx, "SYSTEM-"+uuid.NewString(), "EUR", "t-conc-1")
	if err != nil {
		t.Fatalf("CreateAccount sys: %v", err)
	}

	// Fund Alice so the single committed transfer cannot fail for lack of funds.
	mintIdem := "idem-mint-" + uuid.NewString()
	mintExt := "mint-" + mintIdem
	_, err = s.PostTransfer(ctx, sys, alice, int64(10000), "EUR", mintExt, mintIdem, "t-conc-1")
	if err != nil {
		t.Fatalf("mint: %v", err)
	}

	// Same key, same request. Only one should "create"; the rest must replay same tx_id.
	idem := "idem-same-" + uuid.NewString()
	ext := "pmt-" + idem

	const N = 50
	var wg sync.WaitGroup
	wg.Add(N)

	txIDs := make([]uuid.UUID, N)
	errs := make([]error, N)

	for i := 0; i < N; i++ {
		i := i
		go func() {
			defer wg.Done()
			txID, e := s.PostTransfer(ctx, alice, bob, int64(1), "EUR", ext, idem, "t-conc-1")
			txIDs[i] = txID
			errs[i] = e
		}()
	}
	wg.Wait()

	// Ensure no idempotency rows remain RESERVED for the key.
	var status string
	err = pool.QueryRow(ctx, `SELECT status FROM idempotency WHERE key=$1`, idem).Scan(&status)
	if err != nil {
		t.Fatalf("read idempotency status: %v", err)
	}
	if status != "COMMITTED" {
		t.Fatalf("expected COMMITTED, got %s", status)
	}

	// All calls must succeed and return same tx id.
	var first uuid.UUID
	for i := 0; i < N; i++ {
		if errs[i] != nil {
			t.Fatalf("call %d failed: %v", i, errs[i])
		}
		if txIDs[i] == uuid.Nil {
			t.Fatalf("call %d returned nil tx_id", i)
		}
		if first == uuid.Nil {
			first = txIDs[i]
			continue
		}
		if txIDs[i] != first {
			t.Fatalf("mismatched tx_id: got %s expected %s", txIDs[i], first)
		}
	}

	// DB-level checks: exactly one ledger_tx for that idempotency key.
	var cnt int
	err = pool.QueryRow(ctx, `SELECT COUNT(*) FROM ledger_tx WHERE idempotency_key=$1`, idem).Scan(&cnt)
	if err != nil {
		t.Fatalf("count ledger_tx: %v", err)
	}
	if cnt != 1 {
		t.Fatalf("expected 1 ledger_tx for idempotency_key, got %d", cnt)
	}

	// Ensure idempotency row is bound.
	var hasTx bool
	err = pool.QueryRow(ctx, `SELECT (tx_id IS NOT NULL) FROM idempotency WHERE key=$1`, idem).Scan(&hasTx)
	if err != nil {
		t.Fatalf("check idempotency tx_id: %v", err)
	}
	if !hasTx {
		t.Fatalf("idempotency.tx_id is NULL")
	}

	verifyEventChain(t, pool)
	assertSeqContiguous(t, pool)
}

func TestConcurrentDistinctTransfers_AllCommitAndRemainConsistent(t *testing.T) {
	pool := newTestPool(t)
	applySchema(t, pool)

	s := New(pool)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	alice, err := s.CreateAccount(ctx, "Alice2-"+uuid.NewString(), "EUR", "t-conc-2")
	if err != nil {
		t.Fatalf("CreateAccount alice: %v", err)
	}
	bob, err := s.CreateAccount(ctx, "Bob2-"+uuid.NewString(), "EUR", "t-conc-2")
	if err != nil {
		t.Fatalf("CreateAccount bob: %v", err)
	}
	sys, err := s.CreateAccount(ctx, "SYSTEM2-"+uuid.NewString(), "EUR", "t-conc-2")
	if err != nil {
		t.Fatalf("CreateAccount sys: %v", err)
	}

	// Fund Alice.
	mintIdem := "idem-mint2-" + uuid.NewString()
	mintExt := "mint-" + mintIdem
	_, err = s.PostTransfer(ctx, sys, alice, int64(50000), "EUR", mintExt, mintIdem, "t-conc-2")
	if err != nil {
		t.Fatalf("mint: %v", err)
	}

	const N = 100
	const Amt = int64(2)

	var wg sync.WaitGroup
	wg.Add(N)

	errs := make([]error, N)
	for i := 0; i < N; i++ {
		i := i
		go func() {
			defer wg.Done()
			idem := "idem-" + uuid.NewString()
			ext := "pmt-" + idem
			_, e := s.PostTransfer(ctx, alice, bob, Amt, "EUR", ext, idem, "t-conc-2")
			errs[i] = e
		}()
	}
	wg.Wait()

	for i := 0; i < N; i++ {
		if errs[i] != nil {
			t.Fatalf("call %d failed: %v", i, errs[i])
		}
	}

	// Balances must match.
	_, balAlice, err := s.Balance(ctx, alice)
	if err != nil {
		t.Fatalf("balance alice: %v", err)
	}
	_, balBob, err := s.Balance(ctx, bob)
	if err != nil {
		t.Fatalf("balance bob: %v", err)
	}

	// Alice got +50000, then sent N*Amt to Bob.
	wantAlice := int64(50000) - int64(N)*Amt
	wantBob := int64(N) * Amt

	if balAlice != wantAlice {
		t.Fatalf("alice balance mismatch: got %d want %d", balAlice, wantAlice)
	}
	if balBob != wantBob {
		t.Fatalf("bob balance mismatch: got %d want %d", balBob, wantBob)
	}

	verifyEventChain(t, pool)
	assertSeqContiguous(t, pool)
}

func TestEventChain_TamperByDisablingTriggers_FailsVerification(t *testing.T) {
	pool := newTestPool(t)
	applySchema(t, pool)

	s := New(pool)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Generate at least a couple of events.
	_, err := s.CreateAccount(ctx, "Tamper-"+uuid.NewString(), "EUR", "t-tamper-1")
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	_, err = s.CreateAccount(ctx, "Tamper2-"+uuid.NewString(), "EUR", "t-tamper-1")
	if err != nil {
		t.Fatalf("CreateAccount2: %v", err)
	}

	// Chain must be valid before tamper.
	verifyEventChain(t, pool)

	// Tamper as admin: disable user triggers, update payload_json, re-enable.
	_, err = pool.Exec(ctx, `ALTER TABLE event_log DISABLE TRIGGER USER;`)
	if err != nil {
		t.Fatalf("disable triggers: %v", err)
	}
	_, err = pool.Exec(ctx, `
		UPDATE event_log
			SET payload_json='{"tampered":true}'::jsonb,
				payload_canonical='{"tampered":true}'
		WHERE seq=1;
		`)

	if err != nil {
		t.Fatalf("tamper update: %v", err)
	}
	_, err = pool.Exec(ctx, `ALTER TABLE event_log ENABLE TRIGGER USER;`)
	if err != nil {
		t.Fatalf("enable triggers: %v", err)
	}

	// Verification must now return false (patched SQL returns boolean).
	var ok bool
	err = pool.QueryRow(ctx, `SELECT verify_event_chain()`).Scan(&ok)
	if err != nil {
		t.Fatalf("verify_event_chain query: %v", err)
	}
	if ok {
		t.Fatalf("expected verify_event_chain=false after tamper")
	}

	// Optional: verify detail provides diagnostics.
	var reason string
	var breakSeq int64
	err = pool.QueryRow(ctx, `SELECT COALESCE(reason,''), COALESCE(break_seq,0) FROM verify_event_chain_detail()`).Scan(&reason, &breakSeq)
	if err != nil {
		t.Fatalf("verify_event_chain_detail: %v", err)
	}
	if reason == "" || breakSeq == 0 {
		t.Fatalf("expected detail fields set, got break_seq=%d reason=%q", breakSeq, reason)
	}
}
