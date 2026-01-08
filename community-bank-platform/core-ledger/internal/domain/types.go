package domain

import "github.com/google/uuid"

type CreateAccountRequest struct {
	Label    string `json:"label"`
	Currency string `json:"currency"`
}

type CreateAccountResponse struct {
	AccountID uuid.UUID `json:"account_id"`
}

type PostTransferRequest struct {
	FromAccountID  uuid.UUID `json:"from_account_id"`
	ToAccountID    uuid.UUID `json:"to_account_id"`
	AmountCents    int64     `json:"amount_cents"`
	Currency       string    `json:"currency"`
	ExternalRef    string    `json:"external_ref"`
	IdempotencyKey string    `json:"idempotency_key"`
	CorrelationID  string    `json:"correlation_id"`
}

type PostTransferResponse struct {
	TxID uuid.UUID `json:"tx_id"`
}

type BalanceResponse struct {
	AccountID    uuid.UUID `json:"account_id"`
	Currency     string    `json:"currency"`
	BalanceCents int64     `json:"balance_cents"`
}
