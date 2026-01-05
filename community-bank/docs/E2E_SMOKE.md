# e2e_smoke.sh – Weapon-Grade v0 Verification

## Scope

This document explains **what is verified by e2e_smoke.sh** and **which weapon-grade properties are effectively proven** by this script.

No claims are made beyond what is explicitly tested.

---

## Definition of Weapon-Grade v0 (operational)

For this repository, *weapon-grade v0* means:

- core accounting invariants are enforced at the database level,
- incorrect usage is rejected, not corrected,
- replay and duplication are safe,
- history cannot be silently modified,
- the runtime application operates under strict least-privilege,
- integrity can be verified after execution.

The e2e_smoke.sh script is the mechanism that validates these points.

---

## Script Structure Overview

The script executes the following logical stages:

1. Controlled infrastructure startup
2. Explicit schema application
3. Pre-runtime correctness tests
4. Runtime functional checks via HTTP
5. Adversarial database operations
6. Privilege boundary verification

Each stage fails immediately on violation.

---

## Stage 1 – Infrastructure Initialization

### What is executed

- Docker Compose starts PostgreSQL and dependencies.
- Environment variables are generated from a known template.
- Port conflicts are checked before startup.

### What is verified

- The test runs on a clean, isolated database.
- No external or residual state is reused.

This ensures reproducibility and isolation.

---

## Stage 2 – Schema Application and Fingerprinting

### What is executed

- All SQL migrations in internal/store/migrations are applied using psql.
- Migrations are applied in lexical order.
- A sha256 checksum of migration files is printed.

### What is verified

- The database schema is fully defined by migrations.
- The schema used during the test is auditable.
- No implicit or hidden schema changes exist.

This establishes the database as the authoritative source of invariants.

---

## Stage 3 – Pre-Runtime Go Tests

### What is executed

- Store concurrency tests.
- HTTP error-mapping tests.

### What is verified

- Concurrent access does not violate invariants.
- Error conditions are mapped deterministically.

This validates behavior under parallel execution before runtime.

---

## Stage 4 – Server Build and Startup

### What is executed

- The ledger server is built once.
- The binary hash (sha256) is computed.
- The server is started using the least-privilege DSN.

### What is verified

- The exact executable is known and hashable.
- The server does not run with admin database privileges.
- Health endpoint becomes available within bounded time.

This establishes a controlled and inspectable runtime.

---

## Stage 5 – Functional Ledger Operations (HTTP)

### Account creation

- Accounts are created via the public HTTP API.
- Returned identifiers are validated.

This confirms that state creation is only performed through controlled interfaces.

### Mint and transfer

- SYSTEM credits Alice.
- Alice transfers to Bob.
- Balances are retrieved and checked.

This validates end-to-end accounting correctness under normal usage.

---

## Stage 6 – Idempotency and Replay Verification

### What is executed

- A transfer is replayed with the same idempotency key.
- The returned transaction identifier is compared.
- A conflicting replay (same key, different amount) is attempted.

### What is verified

- Replays do not duplicate effects.
- Conflicting replays are rejected with a deterministic error.

This demonstrates replay safety at the ledger boundary.

---

## Stage 7 – Database-Level Adversarial Checks

All checks in this stage bypass the application and target the database directly.

### Double-entry enforcement

- An unbalanced transaction is inserted manually via SQL.
- The transaction is expected to fail at commit.

This proves that accounting balance is enforced by the database itself.

---

### Append-only enforcement

- UPDATE is attempted on ledger_entry.
- DELETE is attempted on event_log.

Both operations must fail.

This proves that historical data cannot be modified or removed.

---

### Transaction balance inspection

- Debits and credits are aggregated per transaction.
- Results are printed for inspection.

This confirms that all persisted transactions are balanced.

---

### Audit chain verification

- ****verify_event_chain()**** is executed.

The function must return true.

This proves that the event log has not been altered, reordered, or truncated.

---

## Stage 8 – Least-Privilege Verification

Using the runtime database role ****ledger_app****, the script checks:

- UPDATE on accounts → denied
- DELETE on accounts → denied
- UPDATE on ledger_entry → denied
- DELETE on event_log → denied
- SELECT on event_log → denied

This confirms that the application:

- cannot modify history,
- cannot access audit data,
- cannot escalate privileges through SQL.

---

## Stage 9 – Observable Proof Summary

The script prints:

- counts of accounts, transactions, entries, and events,
- recent transaction identifiers and timestamps,
- audit chain head information.

These outputs provide concrete artifacts for inspection and audit.

---

## What Is Proven by e2e_smoke.sh

The script demonstrates that:

- accounting invariants are database-enforced,
- incorrect or partial writes are rejected,
- replay does not create duplicate effects,
- history is append-only,
- audit integrity is verifiable,
- the runtime application operates with restricted privileges.

---

## Explicit Limitations

The script does not attempt to protect against:

- PostgreSQL superuser compromise,
- operating system compromise,
- hardware-level attacks.

These are out of scope for weapon-grade v0.

---

## Conclusion

e2e_smoke.sh provides an executable, repeatable verification that the ledger:

- enforces correctness structurally,
- rejects invalid operations,
- preserves auditable history,
- limits the authority of the application.

This set of properties is what qualifies the system as **weapon-grade v0**.
