package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/gowebpki/jcs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrIdempotencyConflict = errors.New("idempotency key used with different payload")
	ErrNotFound            = errors.New("not found")
	ErrValidation          = errors.New("validation error")
)

type Store struct {
	db *pgxpool.Pool
}

func New(db *pgxpool.Pool) *Store { return &Store{db: db} }

// =========================
// Idempotency canonical shape
// =========================

// TransferIdemShape is the canonical, deterministic request shape for transfer idempotency hashing.
// No floats. No maps. Stable JSON field order via struct marshaling.
type TransferIdemShape struct {
	FromAccountID  string `json:"from_account_id"`
	ToAccountID    string `json:"to_account_id"`
	AmountCents    int64  `json:"amount_cents"`
	Currency       string `json:"currency"`
	ExternalRef    string `json:"external_ref"`
	IdempotencyKey string `json:"idempotency_key"`
	CorrelationID  string `json:"correlation_id"`
}

func hashTransferIdem(shape TransferIdemShape) (string, error) {
	b, err := json.Marshal(shape)
	if err != nil {
		return "", err
	}
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:]), nil
}

func normalizeCurrency(cur string) (string, error) {
	cur = strings.ToUpper(strings.TrimSpace(cur))
	if len(cur) != 3 {
		return "", ErrValidation
	}
	return cur, nil
}

func buildTransferIdemShape(
	fromAcc, toAcc uuid.UUID,
	amountCents int64,
	currency, externalRef, idemKey, correlationID string,
) (TransferIdemShape, error) {
	if fromAcc == uuid.Nil || toAcc == uuid.Nil || fromAcc == toAcc {
		return TransferIdemShape{}, ErrValidation
	}
	if amountCents <= 0 {
		return TransferIdemShape{}, ErrValidation
	}

	externalRef = strings.TrimSpace(externalRef)
	idemKey = strings.TrimSpace(idemKey)
	correlationID = strings.TrimSpace(correlationID)
	if externalRef == "" || idemKey == "" || correlationID == "" {
		return TransferIdemShape{}, ErrValidation
	}

	cur, err := normalizeCurrency(currency)
	if err != nil {
		return TransferIdemShape{}, err
	}

	return TransferIdemShape{
		FromAccountID:  fromAcc.String(),
		ToAccountID:    toAcc.String(),
		AmountCents:    amountCents,
		Currency:       cur,
		ExternalRef:    externalRef,
		IdempotencyKey: idemKey,
		CorrelationID:  correlationID,
	}, nil
}

// =========================
// RFC 8785 (JCS) for event payloads
// =========================

type JSONBytes = json.RawMessage

// jcsPayload returns both representations required by the DB schema:
// - payload_json: regular JSON bytes (to be cast to jsonb in SQL)
// - payload_canonical: RFC 8785 canonical JSON string (JCS)
func jcsPayload(v any) (payloadJSON JSONBytes, payloadCanonical string, err error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, "", err
	}
	canon, err := jcs.Transform(raw)
	if err != nil {
		return nil, "", err
	}
	return JSONBytes(raw), string(canon), nil
}

// insertEvent is the single entry point for event_log inserts.
// It guarantees payload_json (bytes) + payload_canonical (JCS string), matching DB invariants.
func insertEvent(
	ctx context.Context,
	tx pgx.Tx,
	eventType, aggregateType, aggregateID, correlationID string,
	payload any,
) error {
	if strings.TrimSpace(eventType) == "" ||
		strings.TrimSpace(aggregateType) == "" ||
		strings.TrimSpace(aggregateID) == "" ||
		strings.TrimSpace(correlationID) == "" {
		return ErrValidation
	}

	payloadJSON, payloadCanonical, err := jcsPayload(payload)
	if err != nil {
		return err
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO event_log(
			event_id, event_type, aggregate_type, aggregate_id, correlation_id, payload_json, payload_canonical
		) VALUES($1,$2,$3,$4,$5,$6::jsonb,$7)`,
		uuid.New(), eventType, aggregateType, aggregateID, correlationID, payloadJSON, payloadCanonical,
	)
	return err
}

type accountCreatedPayload struct {
	AccountID string `json:"account_id"`
	Label     string `json:"label"`
	Currency  string `json:"currency"`
}

type transferPostedPayload struct {
	TxID        string `json:"tx_id"`
	From        string `json:"from"`
	To          string `json:"to"`
	AmountCents int64  `json:"amount_cents"`
	Currency    string `json:"currency"`
	ExternalRef string `json:"external_ref"`
	Idempotency string `json:"idempotency"`
}

// TransferResponse is the canonical, minimal, stable response stored in idempotency.response_json.
type TransferResponse struct {
	TxID string `json:"tx_id"`
}

func (s *Store) CreateAccount(ctx context.Context, label, currency, correlationID string) (uuid.UUID, error) {
	label = strings.TrimSpace(label)
	if label == "" || strings.TrimSpace(correlationID) == "" {
		return uuid.Nil, ErrValidation
	}
	cur, err := normalizeCurrency(currency)
	if err != nil {
		return uuid.Nil, err
	}

	accID := uuid.New()

	tx, err := s.db.BeginTx(ctx, pgx.TxOptions{
		IsoLevel:   pgx.ReadCommitted,
		AccessMode: pgx.ReadWrite,
	})
	if err != nil {
		return uuid.Nil, err
	}
	defer tx.Rollback(ctx)

	_, err = tx.Exec(ctx,
		`INSERT INTO accounts(account_id, label, currency) VALUES($1,$2,$3)`,
		accID, label, cur,
	)
	if err != nil {
		return uuid.Nil, err
	}

	payload := accountCreatedPayload{
		AccountID: accID.String(),
		Label:     label,
		Currency:  cur,
	}
	if err := insertEvent(ctx, tx, "ACCOUNT_CREATED", "ACCOUNT", accID.String(), correlationID, payload); err != nil {
		return uuid.Nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return uuid.Nil, err
	}
	return accID, nil
}

// PostTransfer posts a single balanced transaction (1 debit, 1 credit) with strict idempotency.
// DB enforces accounting invariants and append-only behavior.
// Contract: external_ref and idempotency_key are unique (DB constraints).
func (s *Store) PostTransfer(
	ctx context.Context,
	fromAcc, toAcc uuid.UUID,
	amountCents int64,
	currency, externalRef, idemKey, correlationID string,
) (uuid.UUID, error) {
	shape, err := buildTransferIdemShape(fromAcc, toAcc, amountCents, currency, externalRef, idemKey, correlationID)
	if err != nil {
		return uuid.Nil, err
	}

	requestHash, err := hashTransferIdem(shape)
	if err != nil {
		return uuid.Nil, err
	}

	tx, err := s.db.BeginTx(ctx, pgx.TxOptions{
		IsoLevel:   pgx.ReadCommitted,
		AccessMode: pgx.ReadWrite,
	})
	if err != nil {
		return uuid.Nil, err
	}
	defer tx.Rollback(ctx)

	// Serialize per idempotency key to eliminate the "RESERVED without tx_id" window.
	_, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, shape.IdempotencyKey)
	if err != nil {
		return uuid.Nil, err
	}

	tag, err := tx.Exec(ctx,
		`INSERT INTO idempotency(key, request_hash, status)
		 VALUES($1,$2,'RESERVED')
		 ON CONFLICT (key) DO NOTHING`,
		shape.IdempotencyKey, requestHash,
	)
	if err != nil {
		return uuid.Nil, err
	}

	if tag.RowsAffected() == 0 {
		var existingHash string
		var existingTx *uuid.UUID

		err := tx.QueryRow(ctx,
			`SELECT request_hash, tx_id FROM idempotency WHERE key=$1`,
			shape.IdempotencyKey,
		).Scan(&existingHash, &existingTx)
		if err != nil {
			return uuid.Nil, err
		}
		if existingHash != requestHash {
			return uuid.Nil, ErrIdempotencyConflict
		}
		if existingTx == nil {
			return uuid.Nil, fmt.Errorf("%w: idempotency reserved without tx_id", ErrValidation)
		}
		if err := tx.Commit(ctx); err != nil {
			return uuid.Nil, err
		}
		return *existingTx, nil
	}

	// Ensure accounts exist and currency matches (DB is authoritative).
	var cur1, cur2 string
	err = tx.QueryRow(ctx, `SELECT currency FROM accounts WHERE account_id=$1`, fromAcc).Scan(&cur1)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return uuid.Nil, ErrNotFound
		}
		return uuid.Nil, err
	}
	err = tx.QueryRow(ctx, `SELECT currency FROM accounts WHERE account_id=$1`, toAcc).Scan(&cur2)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return uuid.Nil, ErrNotFound
		}
		return uuid.Nil, err
	}
	if cur1 != shape.Currency || cur2 != shape.Currency {
		return uuid.Nil, fmt.Errorf("%w: currency mismatch", ErrValidation)
	}

	txID := uuid.New()
	debitEntryID := uuid.New()
	creditEntryID := uuid.New()

	// Canonical DB posting: creates ledger_tx + exactly 2 entries atomically.
	_, err = tx.Exec(ctx, `
		SELECT post_balanced_tx($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
	`,
		txID,
		shape.ExternalRef,
		shape.CorrelationID,
		shape.IdempotencyKey,
		fromAcc,
		toAcc,
		shape.AmountCents,
		shape.Currency,
		debitEntryID,
		creditEntryID,
	)
	if err != nil {
		return uuid.Nil, err
	}

	// Build canonical minimal response once tx_id exists (stable replay contract).
	resp := TransferResponse{TxID: txID.String()}
	respJSON, _, err := jcsPayload(resp)
	if err != nil {
		return uuid.Nil, err
	}
	// Use JCS bytes as the stored jsonb for maximal stability.
	respCanonBytes, err := jcs.Transform([]byte(respJSON))
	if err != nil {
		return uuid.Nil, err
	}
	responseJSON := JSONBytes(respCanonBytes)

	// Bind idempotency key -> tx_id via DB API (SECURITY DEFINER).
	var committedTx uuid.UUID
	err = tx.QueryRow(ctx,
		`SELECT tx_id FROM idem_commit($1,$2,$3::jsonb)`,
		shape.IdempotencyKey, txID, responseJSON,
	).Scan(&committedTx)
	if err != nil {
		return uuid.Nil, err
	}
	txID = committedTx

	// Event log append (hash-chain computed in DB trigger).
	evPayload := transferPostedPayload{
		TxID:        txID.String(),
		From:        fromAcc.String(),
		To:          toAcc.String(),
		AmountCents: shape.AmountCents,
		Currency:    shape.Currency,
		ExternalRef: shape.ExternalRef,
		Idempotency: shape.IdempotencyKey,
	}
	if err := insertEvent(ctx, tx, "TRANSFER_POSTED", "LEDGER_TX", txID.String(), shape.CorrelationID, evPayload); err != nil {
		return uuid.Nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return uuid.Nil, err
	}
	return txID, nil
}

func (s *Store) Balance(ctx context.Context, accountID uuid.UUID) (currency string, balanceCents int64, err error) {
	if accountID == uuid.Nil {
		return "", 0, ErrValidation
	}

	var cur string
	err = s.db.QueryRow(ctx, `SELECT currency FROM accounts WHERE account_id=$1`, accountID).Scan(&cur)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", 0, ErrNotFound
		}
		return "", 0, err
	}

	// CREDIT - DEBIT
	var credit, debit int64
	err = s.db.QueryRow(ctx,
		`SELECT COALESCE(SUM(amount_cents),0)
		   FROM ledger_entry
		  WHERE account_id=$1 AND direction='CREDIT'`,
		accountID,
	).Scan(&credit)
	if err != nil {
		return "", 0, err
	}

	err = s.db.QueryRow(ctx,
		`SELECT COALESCE(SUM(amount_cents),0)
		   FROM ledger_entry
		  WHERE account_id=$1 AND direction='DEBIT'`,
		accountID,
	).Scan(&debit)
	if err != nil {
		return "", 0, err
	}

	return cur, credit - debit, nil
}
