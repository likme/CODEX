# Option B (DB-proof fingerprint)

Option B defines a database-proof fingerprint. It does not depend on the clear payload, and it is verifiable after the fact.

## Goals

- Represent exactly what the DB committed.
- Verify an export/snapshot without depending on the normalized payload.
- Detect any tampering via a hash-chain.
- Clearly separate Option B (DB proof) from Option A (facts).

## Definitions

### Primitives

- `sha256_utf8(t) = SHA256(UTF8(t))`
- `lp(s)` = length-prefix encoding (existing SQL function).

### B1: payload_hash (already existing)

The DB `payload_hash` is defined as:

- `payload_hash := sha256_utf8(payload_canonical)`

DB constraints:
- `payload_canonical` is non-empty.
- `payload_canonical::jsonb = payload_json`.

### B2: event_chain_material (DB-owned canonical text)

The **exact** canonical text is produced by:

`event_chain_material(_seq, _prev_hash, _event_id, _created_at, _event_type, _aggregate_type, _aggregate_id, _correlation_id, _payload_hash)`

It is defined as the concatenation (in this order), with each segment encoded via `lp(...)`:

1. `lp(_seq::text)`
2. `lp(encode(COALESCE(_prev_hash,'\x'::bytea), 'hex'))`
3. `lp(_event_id::text)`
4. `lp(to_char(_created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))`
5. `lp(COALESCE(_event_type,''))`
6. `lp(COALESCE(_aggregate_type,''))`
7. `lp(_aggregate_id::text)`
8. `lp(COALESCE(_correlation_id,''))`
9. `lp(encode(COALESCE(_payload_hash,'\x'::bytea), 'hex'))`

Notes:
- `_created_at` is normalized to UTC with microseconds (`US`) and a `Z` suffix.
- `BYTEA` values are hex-encoded (`encode(...,'hex')`).
- `NULL`s become `''` (TEXT) or empty `\x` (BYTEA) via `COALESCE`.

### B3: db_event_fingerprint (event fingerprint)

Per-event Option B is:

- `db_event_fingerprint := event_log.hash`

Where:
- `hash := sha256_utf8(event_chain_material(seq, prev_hash, event_id, created_at, event_type, aggregate_type, aggregate_id, correlation_id, payload_hash))`

### B4: db_run_fingerprint (snapshot / range fingerprint)

For an export ordered by `seq` and chained via `prev_hash`:

- `db_run_fingerprint(range) := hash` of the last event (`max(seq)` in the range)

The export manifest must include at minimum:
- `seq_start`
- `seq_end`
- `count`
- `head_hash` (hex)

## Offline verification

### Minimal verification (no recompute)

Input: an export containing `seq`, `prev_hash_hex`, `hash_hex`, plus a manifest (`seq_start`, `seq_end`, `count`, `head_hash`).

1. Verify `seq` is strictly increasing.
2. Verify `prev_hash(i) == hash(i-1)` for each row (except the first).
3. Verify `hash(last) == head_hash`.

### Strong verification (recompute hash)

If the export also contains:
- `event_id, created_at, event_type, aggregate_type, aggregate_id, correlation_id, payload_hash_hex`

Then:
4. Rebuild `event_chain_material` exactly as defined in B2.
5. Compute `expected_hash = sha256_utf8(material)`.
6. Compare `expected_hash` to `hash`.

## Reference implementation

The reference SQL definitions live in:
- `internal/store/migrations/000_genesis.sql`
- `event_chain_material(...)`
- the trigger that computes `payload_hash` and `hash`
- the verification function that recomputes `expected_hash`
