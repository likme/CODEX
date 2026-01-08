> Documentation notice
>
> This document reflects the **current canonical migration model**.
> Earlier references to `001_init.sql` and `002_risk.sql` were deprecated and replaced by:
>
> - `000_genesis.sql` as the immutable base migration
> - additive migrations starting at `001_*.sql`
>
> Any documentation still referring to the old numbering scheme is obsolete and should not be used as a reference.

# Technical Documentation: Weapon-Grade Core Ledger and Deterministic Scenarios

## Scope

This repository contains two main components:

- **community-bank**: E2E orchestration, Docker infrastructure, CI scripts.
- **community-bank-platform/core-ledger**: Go ledger server, PostgreSQL storage, banking invariants, auditability, and replayability.

Operational goals:

- Run deterministic E2E tests that prove *weapon-grade* properties at the database and server levels.
- Run multi-phase economic scenarios that separate **facts vs value** without breaking ledger invariants.

---

## High-Level Architecture

### Processes

- Infrastructure: PostgreSQL, Redis, Prometheus, Grafana via Docker Compose.
- Ledger server: single Go process exposing an HTTP API.
- Tests:
  - **Smoke E2E**: proves invariants (double-entry, idempotency, append-only, audit chain, least privilege).
  - **Scenario E2E**: adds value + liquidity snapshots, computes UDI, demonstrates collapse and recovery.

### Directory Layout

- community-bank/infra/: docker-compose and role initialization.
- community-bank/scripts/: E2E scripts (smoke + scenario).
- community-bank-platform/core-ledger/cmd/server/: server entrypoint.
- community-bank-platform/core-ledger/internal/httpapi/: HTTP handlers, router, tests.
- community-bank-platform/core-ledger/internal/store/: DB access, migrations, DB-level invariants.
- community-bank-platform/core-ledger/internal/scenario/: deterministic economic scenarios.

---

## Go Server: Technical Components

### Entry Point

- cmd/server/main.go
  - Loads configuration from environment variables.
  - Opens database connection.
  - Initializes the store layer.
  - Starts the HTTP server.

### HTTP API Layer

- internal/httpapi/router.go
  - Maps routes to handlers.
- internal/httpapi/handlers.go
  - Parses input.
  - Validates requests.
  - Calls store methods.
  - Returns structured JSON errors.

Key properties:

- No external network calls in critical E2E paths.
- Explicit and reproducible error handling.

### Store Layer (Database Access)

- internal/store/store.go
  - DB-level business primitives: account creation, transfers, queries.
- internal/store/migrate.go
  - Applies SQL migrations in lexical order.

Design rule:

- All critical invariants are enforced in PostgreSQL, not trusted to Go code.
- The application is a thin orchestrator. The database is the source of truth.

---

## PostgreSQL: Weapon-Grade Proof Model

### Core Security and Audit Principles

1. **Double-Entry Accounting**  
   Every financial transaction produces symmetric debit and credit entries. Enforced by database constraints and triggers.

2. **Append-Only Storage**  
   Critical tables disallow UPDATE and DELETE. Corrections are represented as new events, never as mutations.

3. **Audit Chain (event_log hash-chain)**  
   Every significant action emits an event into event_log. A hash chain links events so any tampering is detectable.  
   The function ****verify_event_chain()**** recomputes and validates integrity.

4. **Strict Idempotency**  
   All write commands exposed to the server must be idempotent using stable keys. Replays either succeed with no change or fail deterministically.

5. **Least Privilege**  
   The application role ****ledger_app**** has only required permissions. Read-only or audit roles are separated.

---

## Migrations

### Conventions

- Location: core-ledger/internal/store/migrations/
- Order: lexical (001_init.sql, 002_risk.sql, …)
- Rule: ****001_init.sql**** is stable until publication. All extensions are additive migrations.

### 001_init.sql (Weapon-Grade Base)

Provides:

- Ledger schema (accounts, transactions, entries).
- Double-entry enforcement.
- Append-only triggers (****forbid_update_delete()****).
- event_log hash-chain.
- Idempotency mechanisms.
- Base roles and grants.

### 002_risk.sql (Facts vs Value Layer)

Adds:

- ****valuation_snapshot**** table  
  Price, currency, confidence, payload.
- ****liquidity_snapshot**** table  
  Haircut (bps), time-to-cash, payload.
- Indexes on (asset_type, asset_id, as_of).
- Append-only enforcement via ****forbid_update_delete()****.
- AFTER INSERT triggers emitting event_log entries:
  - VALUATION_SNAPSHOT
  - LIQUIDITY_SNAPSHOT
- Read-only role ****ledger_risk_ro**** with SELECT only.

Purpose:

- Introduce value and liquidity data without touching the ledger core.
- Preserve full auditability through event_log.

---

## Deterministic Economic Scenarios

### Objective

Simulate a multi-regime financial system:

1. **NORMAL**  
   Assets liquid, deposits stable.
2. **GEO_SHOCK**  
   Price collapse, haircuts spike, deposit run.
3. **CONTAGION**  
   Further liquidity degradation and settlement friction.
4. **BACKSTOP**  
   Central-bank-like injection, partial recovery.

### Determinism Guarantees

- Fixed timestamps in scenario JSON.
- Snapshots use ****created_at = as_of****.
- Ledger actions use fixed idempotency keys.
- No external calls.
- No randomness.

---

## Scenario Definition

- File: internal/scenario/scenarios/geoshock.json
- Contents:
  - Asset universe.
  - Ordered phases with:
    - valuations
    - liquidities
    - ledger_actions
    - UDI assertions

### Runner

- internal/scenario/runner.go
  - Loads scenario JSON.
  - For each phase:
    - Inserts valuation and liquidity snapshots (append-only).
    - Executes deterministic ledger actions.
    - Computes UDI.
    - Asserts expected regime behavior.

---

## UDI: Unit Deformation Index

Definition:

- mobilisable(asset) = price × (1 − haircut_bps / 10000)
- total_mobilisable = sum of mobilisable assets
- short_liabilities = sum of client balances (excluding SYSTEM) at time T
- ****UDI = total_mobilisable / short_liabilities****

Implementation details:

- Latest snapshot per asset selected using DISTINCT ON (<= as_of).
- Liabilities computed from ledger entries joined with accounts where is_system = false.

---

## Tests and Proofs

### Smoke E2E

Proves:

- Double-entry invariants.
- Idempotency behavior.
- event_log hash-chain integrity.
- Append-only enforcement.
- Least privilege enforcement.

### Scenario Test

- internal/scenario/runner_test.go

Asserts:

- ****verify_event_chain()**** succeeds after scenario execution.
- UDI behavior:
  - NORMAL ≥ 1.10
  - GEO_SHOCK < 1.00
  - BACKSTOP > 1.00
- UPDATE on snapshot tables fails.
- ****ledger_risk_ro**** can read but cannot write.

---

## E2E Scripts

### Smoke

- community-bank/scripts/e2e_smoke.sh  
  Starts infra, runs server, executes core E2E tests.

### Scenario

- community-bank/scripts/e2e_scenario.sh  
  Reuses infra and runs scenario tests only.

---

## Environment Variables

Key variables:

- ****LEDGER_DIR****: path to core-ledger.
- ****LEDGER_DB_DSN****: PostgreSQL DSN.
- ****LEDGER_HTTP_ADDR****: HTTP bind address.

---

## Troubleshooting

### Migration Fails

- Check lexical order and file presence.
- Ensure migrate.go scans the migrations directory.
- Ensure ****forbid_update_delete()**** exists in 001.

### Snapshot Trigger Fails

- event_log column names may differ.
- Adjust only trigger functions in 002_risk.sql.

### Transfers Fail in Scenario

- ****post_transfer()**** is an integration point.
- Adapt Runner.callTransfer() to your actual DB primitive.

### Liability Query Mismatch

- Adjust only the short-liabilities query in ComputeUDIAt().

---

## Execution Commands

### Smoke E2E

```
cd community-bank
./scripts/purge_all.sh 
LEDGER_HTTP_MAX_INFLIGHT=16 LEDGER_DIR=../community-bank-platform/core-ledger make e2e
```


## Expected Guarantees (Checklist)

* [ ] All critical tables are append-only.
* [ ] Every significant insert emits an event_log entry.
* [ ] Hash-chain verification passes.
* [ ] Idempotency proven via replay.
* [ ] Least privilege enforced by tests.
* [ ] Scenario is fully reproducible in CI.


