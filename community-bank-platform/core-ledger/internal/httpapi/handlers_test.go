package httpapi

import (
	"context"
	"errors"
	"net/http"
	"testing"

	"core-ledger/internal/store"
)

func TestHTTPStatusForErr(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want int
	}{
		{"validation", store.ErrValidation, http.StatusBadRequest},
		{"notfound", store.ErrNotFound, http.StatusNotFound},
		{"idem", store.ErrIdempotencyConflict, http.StatusConflict},
		{"deadline", context.DeadlineExceeded, http.StatusGatewayTimeout},
		{"canceled", context.Canceled, http.StatusRequestTimeout}, // if you choose 408
		{"other", errors.New("x"), http.StatusInternalServerError},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := httpStatusForErr(tc.err)
			if got != tc.want {
				t.Fatalf("got %d want %d", got, tc.want)
			}
		})
	}
}
