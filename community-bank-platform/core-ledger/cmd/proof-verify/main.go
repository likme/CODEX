package proofverify
package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
)

type row struct {
	Seq         string
	PrevHex     string
	HashHex     string
}

func sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func main() {
	var (
		inPath   = flag.String("in", "", "CSV exported from event_log_proof_export_v")
		headHash = flag.String("head", "", "expected head hash hex (db_run_fingerprint)")
	)
	flag.Parse()

	if *inPath == "" {
		fmt.Fprintln(os.Stderr, "missing -in")
		os.Exit(2)
	}
	if *headHash == "" {
		fmt.Fprintln(os.Stderr, "missing -head")
		os.Exit(2)
	}

	f, err := os.Open(*inPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "open:", err)
		os.Exit(2)
	}
	defer f.Close()

	r := csv.NewReader(bufio.NewReader(f))
	r.FieldsPerRecord = -1

	// Read header
	header, err := r.Read()
	if err != nil {
		fmt.Fprintln(os.Stderr, "read header:", err)
		os.Exit(2)
	}

	col := map[string]int{}
	for i, h := range header {
		col[strings.TrimSpace(h)] = i
	}
	for _, need := range []string{"seq", "prev_hash_hex", "hash_hex"} {
		if _, ok := col[need]; !ok {
			fmt.Fprintln(os.Stderr, "missing column:", need)
			os.Exit(2)
		}
	}

	var (
		lineNo      = 1
		prevHashHex string
		lastHashHex string
		rows        int
	)

	for {
		rec, err := r.Read()
		if err == io.EOF {
			break
		}
		lineNo++
		if err != nil {
			fmt.Fprintln(os.Stderr, "csv read:", err)
			os.Exit(2)
		}

		cur := row{
			Seq:     rec[col["seq"]],
			PrevHex: strings.ToLower(strings.TrimSpace(rec[col["prev_hash_hex"]])),
			HashHex: strings.ToLower(strings.TrimSpace(rec[col["hash_hex"]])),
		}

		// Basic hex sanity
		if _, err := hex.DecodeString(cur.PrevHex); err != nil {
			fmt.Fprintf(os.Stderr, "line %d: invalid prev_hash_hex: %v\n", lineNo, err)
			os.Exit(1)
		}
		if _, err := hex.DecodeString(cur.HashHex); err != nil {
			fmt.Fprintf(os.Stderr, "line %d: invalid hash_hex: %v\n", lineNo, err)
			os.Exit(1)
		}

		if rows > 0 {
			// chain check: prev_hash(i) == hash(i-1)
			if cur.PrevHex != prevHashHex {
				fmt.Fprintf(os.Stderr, "FAIL: prev_hash mismatch at seq=%s line=%d\nexpected=%s\ngot=%s\n",
					cur.Seq, lineNo, prevHashHex, cur.PrevHex)
				os.Exit(1)
			}
		}

		prevHashHex = cur.HashHex
		lastHashHex = cur.HashHex
		rows++
	}

	if rows == 0 {
		fmt.Fprintln(os.Stderr, "FAIL: empty export")
		os.Exit(1)
	}

	if strings.ToLower(strings.TrimSpace(*headHash)) != lastHashHex {
		fmt.Fprintf(os.Stderr, "FAIL: head hash mismatch\nexpected=%s\ngot=%s\n", *headHash, lastHashHex)
		os.Exit(1)
	}

	fmt.Printf("OK: chain verified (%d rows). head=%s\n", rows, lastHashHex)
	_ = sha256Hex // keep helper for future “strong” mode
}
