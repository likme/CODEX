// core-ledger/internal/store/jcs_store_test.go
package store_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"io"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func mustJCS(t *testing.T, v any) []byte {
	t.Helper()
	b, err := jcsMarshal(v)
	if err != nil {
		t.Fatalf("jcs marshal: %v", err)
	}
	if len(b) == 0 || string(b) == "null" {
		t.Fatalf("jcs marshal produced empty/null output")
	}
	return b
}

func riskPayloadHashValuation(assetType, assetID string, asOf time.Time, price, currency, source string, confidence int, payloadJCS []byte) [32]byte {
	s := "valuation_snapshot:v1|" +
		assetType + "|" +
		assetID + "|" +
		asOf.UTC().Format(time.RFC3339Nano) + "|" +
		price + "|" +
		strings.ToUpper(currency) + "|" +
		source + "|" +
		strconv.Itoa(confidence) + "|" +
		string(payloadJCS)
	return sha256.Sum256([]byte(s))
}

func riskPayloadHashLiquidity(assetType, assetID string, asOf time.Time, haircutBps, ttcSeconds int, source string, payloadJCS []byte) [32]byte {
	s := "liquidity_snapshot:v1|" +
		assetType + "|" +
		assetID + "|" +
		asOf.UTC().Format(time.RFC3339Nano) + "|" +
		strconv.Itoa(haircutBps) + "|" +
		strconv.Itoa(ttcSeconds) + "|" +
		source + "|" +
		string(payloadJCS)
	return sha256.Sum256([]byte(s))
}

func jcsMarshal(v any) ([]byte, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var tmp any
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	if err := dec.Decode(&tmp); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, io.ErrUnexpectedEOF
	}
	var buf bytes.Buffer
	if err := jcsWrite(&buf, tmp); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func jcsWrite(w *bytes.Buffer, v any) error {
	switch x := v.(type) {
	case nil:
		w.WriteString("null")
	case bool:
		if x {
			w.WriteString("true")
		} else {
			w.WriteString("false")
		}
	case string:
		b, _ := json.Marshal(x)
		w.Write(b)
	case json.Number:
		w.WriteString(x.String())
	case float64:
		w.WriteString(strconv.FormatFloat(x, 'g', -1, 64))
	case []any:
		w.WriteByte('[')
		for i := range x {
			if i > 0 {
				w.WriteByte(',')
			}
			if err := jcsWrite(w, x[i]); err != nil {
				return err
			}
		}
		w.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		w.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				w.WriteByte(',')
			}
			kb, _ := json.Marshal(k)
			w.Write(kb)
			w.WriteByte(':')
			if err := jcsWrite(w, x[k]); err != nil {
				return err
			}
		}
		w.WriteByte('}')
	default:
		b, err := json.Marshal(x)
		if err != nil {
			return err
		}
		var tmp any
		dec := json.NewDecoder(bytes.NewReader(b))
		dec.UseNumber()
		if err := dec.Decode(&tmp); err != nil {
			return err
		}
		return jcsWrite(w, tmp)
	}
	return nil
}

func hasColumn(ctx context.Context, pool *pgxpool.Pool, table, column string) (bool, error) {
	var ok bool
	err := pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1
			FROM information_schema.columns
			WHERE table_schema = current_schema()
			  AND table_name = $1
			  AND column_name = $2
		)
	`, table, column).Scan(&ok)
	return ok, err
}
