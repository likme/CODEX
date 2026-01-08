# Option B Tutorial: Unit-committed measurements (u) + quantities (n)

## Goal
Prevent silent unit drift.
A numeric value is valid only if it is bound to an explicit, canonical unit object `u` committed by SHA-256.

## Core rule
You may compare two values only if their `payload_hash_sha256` values are identical.
Otherwise: "Invalid comparison: measured unit is not the same."

## Conceptual model
- `u`: the full unit definition (scope, methods, assumptions, perimeter, period).
- `n`: the measured quantity computed under `u`.
- `payload_canonical.json`: canonical representation of `u` (stable key ordering).
- `payload_hash_sha256`: SHA-256(payload_canonical).

## Repository map
- `scripts/`
  - `baguette_demo.sh`: minimal end-to-end Option B demo (offline-first).
  - `baguette_compare.sh`: strict comparator (hash-gated).
  - `sql/`: invariant tests (double entry, idempotency responses).
- `sandbox/`
  - `up.sh`: start local infra.
  - `replay.sh`: deterministic replay and invariant checks.
  - `check_replay.sh`: wrapper to run scenarios and verify replay stability.
  - `verify_fingerprint.sh`: verifies deterministic fingerprints.
  - `scenarios/`
    - `retail_30d/`: synthetic retail scenario.
    - `carbon_mrv/`: carbon MRV scenario.
- `community-bank/` and `community-bank-platform/`: ledger + infra.

---

# Part 1: Minimal Option B demo (Baguette)

## Run (offline)
```
./scripts/baguette_demo.sh
````

Outputs:

* `out/baguette/Paris/YYYY-MM/payload_canonical.json`
* `out/baguette/Paris/YYYY-MM/payload_hash.sha256`
* `out/baguette/Paris/YYYY-MM/result.json`

Inspect:

```
jq . out/baguette/Paris/2026-01/payload_canonical.json
jq . out/baguette/Paris/2026-01/result.json
```

## Prove reproducibility

Same inputs -> same hash and same value:

```
./scripts/baguette_demo.sh
jq -r '.payload_hash_sha256, .n.value_cents' out/baguette/Paris/2026-01/result.json
```

## Prove invalid comparison (unit drift)

Generate two results with different `u`:

```
WEIGHT_GRAMS=250 OUT_DIR=out/baguette/Paris/2026-01_w250 ./scripts/baguette_demo.sh
WEIGHT_GRAMS=260 OUT_DIR=out/baguette/Paris/2026-01_w260 ./scripts/baguette_demo.sh
```

Compare:

```
./scripts/baguette_compare.sh \
  out/baguette/Paris/2026-01_w250/result.json \
  out/baguette/Paris/2026-01_w260/result.json
```

Expected: comparison refused (exit code 2).

---

# Part 2: Option B at system scale (sandbox scenarios)

## What the sandbox proves

* Deterministic scenario generation (SEED-based).
* Replayability (same inputs -> same outputs).
* Invariants (accounting conservation, constraints).
* Fingerprints/hashes that act as commitments for scenario definitions and outputs.

## Start local infra

```
./sandbox/up.sh
```

If you want a clean state:

```bash
./sandbox/reset.sh
./sandbox/up.sh
```

## Run scenario: retail_30d

This scenario generates a synthetic retail ledger workload (accounts, deposits, transfers),
with deterministic plans and invariant checks.

Run:

```
./sandbox/scenarios/retail_30d/run.sh
```

Typical outputs (paths vary by timestamp):

* `sandbox/out/retail_30d/.../plan.txt` (or equivalent)
* `sandbox/out/retail_30d/.../fingerprint*.txt|sha256`
* latency metrics and summaries

Replay verification (determinism check):

```
./sandbox/replay.sh retail_30d
```

Or use the wrapper:

```
./sandbox/check_replay.sh retail_30d
```

What “success” means:

* Replay does not diverge.
* Fingerprints match expected invariants.
* No “naked” metrics: outputs are bound to scenario definitions (hash inputs).

## Run scenario: carbon_mrv

This scenario demonstrates MRV-style accounting with explicit assumptions and reference datasets.
It is designed to make unit/assumption drift visible and non-comparable by default.

Run:

```
./sandbox/scenarios/carbon_mrv/run.sh
```

Replay verification:

```
./sandbox/replay.sh carbon_mrv
```

Or:

```
./sandbox/check_replay.sh carbon_mrv
```

## Verify fingerprints directly

```
./sandbox/verify_fingerprint.sh
```

---

# Part 3: Pattern to apply elsewhere

## Generic Option B pipeline

1. Define `u` as a structured object.
2. Canonicalize `u` (stable ordering).
3. Commit `u` with SHA-256.
4. Compute `n` only under that `u`.
5. Store/emit `{n, u, payload_hash}` together.
6. Refuse comparisons when hashes differ.

## Non-negotiable constraints

* No naked numbers. Every value must carry `payload_hash`.
* Any correction, smoothing, imputation, extrapolation must be declared in `u`.
* Any change to assumptions or perimeter changes `u` and invalidates direct comparison.

