# Reproducible E2E

This project enforces a **deterministic, fully automated end-to-end test**.
A clean clone must be able to run the full scenario without manual steps.

Reproducibility is defined precisely in this document.
There is no implicit or informal guarantee.

---

## Single command
```
make e2e
```


This command is the **only supported entry point** for validation.

---

## What the E2E does

1. Starts local infrastructure via Docker Compose
2. Selects a free Postgres port dynamically
3. Starts the Go API server with an explicit DSN
4. Applies embedded database migrations
5. Creates test accounts
6. Executes a mint operation
7. Executes a transfer
8. Verifies balances
9. Shuts everything down

Successful execution ends with:
```
E2E OK
```

---

## Reproducibility contract

The project distinguishes **two different notions of reproducibility**.
They must not be conflated.

### (A) Reproducibility of projected state

Given:

- the same ordered set of logical events,
- the same code version,
- the same schema version,

the **final projected state** is reproducible.

This includes, at minimum:

- account balances,
- ledger invariants,
- derived projections computed from events.

Formally:

> Replaying the same event set yields the same state, byte-for-byte where applicable.

This is the primary reproducibility guarantee of the system.

---

### (B) Non-reproducibility of event hash chains under reinsertion

The system **does not guarantee** reproducibility of the full event hash chain
when events are reinserted into a fresh database.

Reason:

- `event_log.created_at` is **owned by the database**,
- it is assigned at INSERT time,
- it depends on database wall-clock time,
- it therefore varies between executions.

Because `created_at` participates in the hash material:

- the per-row hash changes,
- the chained hashes change,
- the final chain root changes.

This behavior is **expected, documented, and intentional**.

Formally:

> Hash-chain equality is not a reproducibility target across executions that reinsert events.

---

## Proof protocol

Reproducibility is established by **comparing explicit outputs**.

### What is compared

The E2E compares:

- final account balances,
- invariant checks (double-entry, zero-sum),
- API-level observable results.

Optional diagnostic outputs may include:

- ordered event payloads without DB-owned fields,
- recomputed projections.

### What is explicitly NOT compared

- raw `event_log.created_at`,
- per-event hash values,
- final audit-chain hash after reinsertion.

These values are time-dependent by design.

---

## Why this is sufficient

The system’s purpose is to ensure:

- accounting correctness,
- invariant preservation,
- deterministic state derivation.

Hash chains provide **tamper evidence within a run**.
They are not used as cross-run fingerprints.

State equality is the only meaningful reproducibility criterion.

---

## Determinism rules

The following rules are **non-negotiable**:

* No fixed Postgres port  
  The infra layer selects a free port at runtime.

* No fixed HTTP port  
  The E2E script selects a free port for the API server.

* No hardcoded database defaults  
  `LEDGER_DB_DSN` is mandatory and must be provided by the E2E script.

* Embedded migrations  
  Database schema is embedded in the binary and applied at startup.

* Fail fast  
  Any failure must abort the run immediately.

---

## Environment variables

Set automatically by the E2E script:

* `LEDGER_DB_DSN`  
  Postgres connection string used by the API server.

* `LEDGER_HTTP_ADDR`  
  Address and port used by the API server.

Manual overrides are not supported for E2E.

---

## Scope

This document specifies **reproducibility guarantees only**.
It does not define business semantics or economic interpretation.