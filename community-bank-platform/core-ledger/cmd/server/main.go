package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"time"

	"core-ledger/internal/httpapi"
	"core-ledger/internal/store"

	"github.com/jackc/pgx/v5/pgxpool"
)

func mustEnv(key, def string) string {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	return v
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

func clamp(n, lo, hi int) int {
	if n < lo {
		return lo
	}
	if n > hi {
		return hi
	}
	return n
}

func main() {
	start := time.Now()

	dsn := mustEnv("LEDGER_DB_DSN", "postgres://ledger:ledger@localhost:5432/ledger?sslmode=disable")
	addr := mustEnv("LEDGER_HTTP_ADDR", ":8080")
	migrate := mustEnv("LEDGER_DB_MIGRATE", "0") == "1"

	log.Printf("[startup] begin addr=%s migrate=%t", addr, migrate)

	// DB pool sizing
	cpu := runtime.GOMAXPROCS(0)
	defMaxConns := clamp(cpu*4, 4, 50)
	maxConns := mustIntEnv("LEDGER_DB_MAX_CONNS", defMaxConns)

	log.Printf("[startup] cpu=%d maxConns=%d", cpu, maxConns)

	// Startup context
	startCtx, startCancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer startCancel()

	log.Printf("[startup] parsing DB config")
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		log.Fatalf("[startup] parse dsn failed: %v", err)
	}

	cfg.MaxConns = int32(maxConns)
	cfg.MinConns = 1
	cfg.HealthCheckPeriod = 10 * time.Second
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute

	log.Printf("[startup] connecting to DB")
	pool, err := pgxpool.NewWithConfig(startCtx, cfg)
	if err != nil {
		log.Fatalf("[startup] db connect failed: %v", err)
	}
	defer pool.Close()

	log.Printf("[startup] ping DB")
	if err := pool.Ping(startCtx); err != nil {
		log.Fatalf("[startup] db ping failed: %v", err)
	}

	if migrate {
		log.Printf("[startup] running migrations")
		if err := store.Migrate(startCtx, pool); err != nil {
			log.Fatalf("[startup] migrations failed: %v", err)
		}
		log.Printf("[startup] migrations complete")
	} else {
		log.Printf("[startup] migrations disabled")
	}

	st := store.New(pool)
	h := httpapi.NewHandlers(st)

	srv := &http.Server{
		Addr:    addr,
		Handler: httpapi.Router(h),

		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	log.Printf(
		"[startup] ready in %s, listening on %s",
		time.Since(start).Truncate(time.Millisecond),
		addr,
	)

	log.Fatal(srv.ListenAndServe())
}
