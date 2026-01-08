package httpapi

import (
	"net/http"
	"os"
	"strconv"
)

func Router(h *Handlers) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", h.Healthz)
	mux.HandleFunc("/v1/accounts", h.CreateAccount)     // POST
	mux.HandleFunc("/v1/transfers", h.PostTransfer)     // POST
	mux.HandleFunc("/v1/accounts/", h.GetBalanceByPath) // GET /v1/accounts/{uuid}/balance

	// Backpressure at the edge.
	// Prevents unbounded goroutine/pool queueing when DB is saturated.
	max := mustIntEnv("LEDGER_HTTP_MAX_INFLIGHT", 64)
	return withConcurrencyLimit(mux, max)
}

func mustIntEnv(key string, def int) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return def
	}
	return n
}

func withConcurrencyLimit(next http.Handler, max int) http.Handler {
	if max <= 0 {
		max = 64
	}
	sem := make(chan struct{}, max)

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case sem <- struct{}{}:
			defer func() { <-sem }()
			next.ServeHTTP(w, r)
		default:
			// Fast fail instead of queueing forever.
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"error":"server busy"}`))
		}
	})
}
