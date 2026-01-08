# Full Local End-to-End Run (Canonical)

This document describes the **authoritative local execution sequence** for the Community Bank / Core Ledger stack.

The goal is to move from a **zero-entropy machine state** to a **fully verified ledger, risk layer, CI, and demo**, with explicit proofs at each layer.

This sequence is designed to be:

* Deterministic
* Reproducible
* CI-aligned
* Auditable

---

## 0. Full Infrastructure Reset

```bash
docker compose -f community-bank/infra/docker-compose.yml down -v --remove-orphans
```

**Purpose**

* Destroys all containers, volumes, and networks.
* Eliminates hidden state.
* Guarantees a clean start.

**Invariant**

No previous database, cache, or service state survives.

---

## 1. Pin PostgreSQL Port in `infra/.env`

```bash
sed -i 's/^POSTGRES_PORT=.*/POSTGRES_PORT=55432/' community-bank/infra/.env
grep '^POSTGRES_PORT=' community-bank/infra/.env
```

**Purpose**

* Forces a known port for all downstream scripts.
* `e2e_smoke.sh` reads *only* `infra/.env`.

**Invariant**

All components agree on the same PostgreSQL port.

---

## 2. Ensure Port Availability

```bash
lsof -i :55432 || true
```

**Purpose**

* Detects local conflicts.
* If the port is busy, `bootstrap_env.sh` will auto-bump it.

**Invariant**

Postgres will start on a usable port, even under contention.

---

## 3. Run Infrastructure + E2E Smoke Test

```bash
./community-bank/scripts/e2e_smoke.sh
```

**Purpose**

* Boots Docker infrastructure.
* Runs end-to-end smoke checks.
* May rewrite `infra/.env` if port bumping occurs.

**Important**

Do **not** run `docker compose up` manually.
This script is the single entry point.

**Invariant**

Base services are live and minimally functional.

---

## 4. Re-read PostgreSQL Port After E2E

```bash
POSTGRES_PORT="$(grep '^POSTGRES_PORT=' community-bank/infra/.env | cut -d= -f2)"
export POSTGRES_PORT
export PGPASSWORD=ledger
```

**Purpose**

* Synchronizes the shell with the actual runtime port.
* Required because step 3 may modify `.env`.

**Invariant**

All subsequent steps target the correct database.

---

## 5. Genesis (Schema + Proofs)

```bash
./run_genesis.sh
```

**Purpose**

* Drops and recreates the database schema.
* Applies `000_genesis.sql`.
* Runs SQL assertions.
* Verifies:

  * Double-entry invariants
  * Idempotency
  * Snapshot immutability
  * Event-log append-only behavior
  * Cryptographic hash chain integrity

**Invariant**

The database is **structurally correct and self-verifying** without application code.

---

## 6. Codex CI

```bash
PG_PORT="$POSTGRES_PORT" ./run_codex_ci.sh
```

**Purpose**

* Runs Codex CI checks.
* Assumes `PG_PORT` is set explicitly.

**Invariant**

CI assumptions match the local runtime environment.

---

## 7. Demo Run

```bash
./run_demo.sh
```

**Purpose**

* Executes the demo pipeline on top of the verified ledger.
* Uses the already-proven schema and infra.

**Invariant**

Demo behavior is grounded on a verified database, not a mock.

---

## 8. SQL Genesis Verification (Standalone)

```bash
PGURI="postgres://ledger:ledger@localhost:${POSTGRES_PORT}/postgres?sslmode=disable" \
GENESIS_SQL="community-bank-platform/core-ledger/internal/store/migrations/000_genesis.sql" \
bash -lc 'chmod +x ./community-bank/scripts/test_genesis.sh && ./community-bank/scripts/test_genesis.sh'
```

**Purpose**

* Re-runs genesis verification independently.
* Validates that `000_genesis.sql` is self-contained and reproducible.

**Invariant**

Genesis correctness does not depend on prior steps or hidden state.

---

## 9. Fetch Real Scenario Data (Regime Break)

```bash
chmod +x ./community-bank/scripts/fetch_real_data_regime_break.sh
./community-bank/scripts/fetch_real_data_regime_break.sh
```

**Purpose**

* Downloads real-world data used in risk-layer scenarios.
* Enables deterministic replay of regime breaks.

**Invariant**

Scenario tests operate on known, versioned inputs.

---

## 10. Go Tests on a Fresh Database

```bash
psql "postgres://ledger@localhost:${POSTGRES_PORT}/postgres?sslmode=disable" \
  -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS ledger_gotest;'

psql "postgres://ledger@localhost:${POSTGRES_PORT}/postgres?sslmode=disable" \
  -v ON_ERROR_STOP=1 -c 'CREATE DATABASE ledger_gotest;'
```

```bash
cd community-bank-platform/core-ledger

LEDGER_DB_DSN="postgres://ledger:ledger@localhost:${POSTGRES_PORT}/ledger_gotest?sslmode=disable" \
go test ./... -count=1 -p 1

cd -
```

**Purpose**

* Runs Go tests against a *fresh* database.
* No schema reuse.
* No test interdependence.

**Invariant**

Application-level correctness is validated independently of genesis and demo state.

---

## Final Guarantees

After completing all steps:

* Infrastructure is reproducible.
* Database invariants are DB-enforced.
* Event sourcing is cryptographically verifiable.
* Risk scenarios are replayable.
* CI, demo, SQL, and Go layers agree on reality.

This sequence defines the **canonical local truth** of the system.
