# Sandbox

This directory contains an experimental sandbox used to **prove determinism and auditability**
of the ledger without changing its semantics.

The sandbox orchestrates a local end-to-end run, exports database proofs, and derives
**stable fingerprints** suitable for reproducibility checks and CI.

The sandbox is intentionally isolated from production code.

---

## What this sandbox does

1. Starts local infrastructure (Postgres, Redis, monitoring)
2. Builds and runs `core-ledger`
3. Executes a minimal end-to-end scenario (`smoke`)
4. Exports database audit artifacts
5. Produces reproducible fingerprints

No business logic is implemented here.

---

## Scenarios

### `smoke`

`smoke` is a **minimal deterministic scenario** designed to:
- exercise the full ledger pipeline
- validate DB invariants (double-entry, append-only, idempotency)
- produce a small, inspectable audit trail

It is not a performance test.
It is not a fuzz test.
It is a proof harness.

---

## Artifacts

Each run produces a directory:

```

sandbox/out/<scenario>/<timestamp>/

```

### DB proof artifacts (run-scoped)

- `payload_fingerprint.csv`  
  Exported from the database. Each row contains:
  - `seq`
  - `payload_canonical` (RFC 8785 JCS, app-owned)
  - `payload_hash_hex = sha256_utf8(payload_canonical)` (DB-owned)

This fingerprint reflects **exact DB commitments** for that run.

- `proof_summary.txt`  
  High-level database proofs (event chain, counts, head hash).

---

### Facts fingerprint (inter-run stable) — **Option A**

Some fields (UUIDs, idempotency keys) are intentionally non-deterministic across runs.
They are not part of the economic facts.

The sandbox therefore derives a second fingerprint:

- `payload_fingerprint_normalized.csv`  
  `payload_canonical` normalized by:
  - replacing UUIDs with stable tokens (`UUID1`, `UUID2`, …)
  - replacing time-based idempotency tokens with `IDEM1`, `IDEM2`, …

- `payload_fingerprint_facts.csv`  
  For each row:
```

facts_hash_hex = sha256(payload_canonical_normalized)

````

- `payload_fingerprint_facts.sha256`  
A single hash over the facts fingerprint.

This hash is expected to be **identical across runs** when starting from the same initial state.

This is **Option A**: a stable fingerprint over facts, not identities.

---

## Usage

### Run a scenario once
```bash
./sandbox/replay.sh smoke
````

### Prove reproducibility (recommended)

Runs the scenario twice with a clean DB and checks that the facts fingerprint is identical.

```bash
./sandbox/ci_fingerprint.sh
```

### Verify a run against the current DB

```bash
./sandbox/verify_fingerprint.sh sandbox/out/smoke/<timestamp>
```

---

## Safety

* Database reset is **opt-in** via `RESET_DB=1`
* Reset is only allowed on `localhost`
* All sandbox outputs are ignored by git (`sandbox/out/`)

---

## Design notes

* The ledger commits to `payload_canonical` exactly as stored in the DB
* `payload_hash` is computed by the DB as `sha256_utf8(payload_canonical)`
* Facts fingerprinting is an **external, derived proof**
* No ledger semantics are modified

Option B (a pure DB-hash-based fingerprint) is intentionally **not implemented here** and
may be explored separately.

---

## Non-goals

* Production deployment
* Performance benchmarking
* Consensus or distributed execution

This sandbox exists to make **claims provable**.

