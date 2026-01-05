package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"core-ledger/internal/domain"
	"core-ledger/internal/store"

	"github.com/google/uuid"
)

type Handlers struct {
	st *store.Store
}

func NewHandlers(st *store.Store) *Handlers { return &Handlers{st: st} }

func (h *Handlers) Healthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

func decodeJSON(r *http.Request, dst any) error {
	defer r.Body.Close()
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	return dec.Decode(dst)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]any{"error": msg})
}

func httpStatusForErr(err error) int {
	switch {
	case err == nil:
		return http.StatusOK

	// Store-level semantic errors
	case errors.Is(err, store.ErrValidation):
		return http.StatusBadRequest
	case errors.Is(err, store.ErrNotFound):
		return http.StatusNotFound
	case errors.Is(err, store.ErrIdempotencyConflict):
		return http.StatusConflict

	// Context / timeouts
	case errors.Is(err, context.DeadlineExceeded):
		return http.StatusGatewayTimeout
	case errors.Is(err, context.Canceled):
		return http.StatusRequestTimeout

	default:
		return http.StatusInternalServerError
	}
}

func publicErrMessage(code int, err error) string {
	// Don’t leak internals on 5xx.
	if code >= 500 {
		return "internal error"
	}
	return err.Error()
}

func (h *Handlers) CreateAccount(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req domain.CreateAccountRequest
	if err := decodeJSON(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid json")
		return
	}

	corr := r.Header.Get("X-Correlation-Id")
	if corr == "" {
		corr = uuid.New().String()
	}

	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()

	id, err := h.st.CreateAccount(ctx, req.Label, strings.ToUpper(req.Currency), corr)
	if err != nil {
		code := httpStatusForErr(err)
		writeErr(w, code, publicErrMessage(code, err))
		return
	}

	writeJSON(w, http.StatusCreated, domain.CreateAccountResponse{AccountID: id})
}

func (h *Handlers) PostTransfer(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req domain.PostTransferRequest
	if err := decodeJSON(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid json")
		return
	}

	// Prefer body correlation_id, fall back to header, else generate.
	if strings.TrimSpace(req.CorrelationID) == "" {
		req.CorrelationID = r.Header.Get("X-Correlation-Id")
	}
	if strings.TrimSpace(req.CorrelationID) == "" {
		req.CorrelationID = uuid.New().String()
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	txID, err := h.st.PostTransfer(
		ctx,
		req.FromAccountID,
		req.ToAccountID,
		req.AmountCents,
		strings.ToUpper(req.Currency),
		req.ExternalRef,
		req.IdempotencyKey,
		req.CorrelationID,
	)
	if err != nil {
		code := httpStatusForErr(err)
		writeErr(w, code, publicErrMessage(code, err))
		return
	}

	writeJSON(w, http.StatusCreated, domain.PostTransferResponse{TxID: txID})
}

// GET /v1/accounts/{uuid}/balance
func (h *Handlers) GetBalanceByPath(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeErr(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/v1/accounts/")
	parts := strings.Split(path, "/")
	if len(parts) != 2 || parts[1] != "balance" {
		writeErr(w, http.StatusNotFound, "not found")
		return
	}

	accID, err := uuid.Parse(parts[0])
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid account id")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()

	cur, bal, err := h.st.Balance(ctx, accID)
	if err != nil {
		code := httpStatusForErr(err)
		writeErr(w, code, publicErrMessage(code, err))
		return
	}

	writeJSON(w, http.StatusOK, domain.BalanceResponse{
		AccountID:    accID,
		Currency:     cur,
		BalanceCents: bal,
	})
}
