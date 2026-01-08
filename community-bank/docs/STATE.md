> Documentation notice
>
> This document reflects the **current canonical migration model**.
> Earlier references to `001_init.sql` and `002_risk.sql` were deprecated and replaced by:
>
> - `000_genesis.sql` as the immutable base migration
> - additive migrations starting at `001_*.sql`
>
> Any documentation still referring to the old numbering scheme is obsolete and should not be used as a reference.

# Project State

## Scope

Factual state of the core-ledger.
What is proven.
What is frozen.
What is explicitly not frozen.

---

## Current status

- Schema file: `internal/store/migrations/001_init.sql`
- Mode: reset-based (DROP / CREATE)
- E2E: `scripts/e2e_smoke.sh` passes end-to-end
- Schema hash (example):
  - sha256: 8222c1c3c032709e5516654f648176680c02eb612b8aa2aa0a9b47cf4e3c0d56

---

## Reproducibility model

This project guarantees **state reproducibility**, not **history byte identity**.

### Guaranteed

- Identical final balances after replay
- Identical invariant outcomes
- Identical projections derived from events
- Deterministic behavior under the same inputs

### Explicitly not guaranteed

- Equality of `event_log.created_at`
- Equality of per-event hashes after reinsertion
- Equality of full hash-chain roots across runs

Reason:

- `created_at` is DB-owned,
- assigned at insertion time,
- dependent on database clock.

Any design claiming otherwise would be misleading.

---

## Proven invariants (by E2E)

- Double-entry accounting enforced at DB level
- Deferred constraint blocks unbalanced transactions at COMMIT
- Append-only enforcement on critical tables
- Strict idempotency with replay vs conflict
- Tamper-evident audit chain (in-run)
- Least-privilege runtime role (`ledger_app`)

---

## Explicit assumptions

- `001_init.sql` is **not frozen**
- Any schema change requires DROP + recreate
- Event timestamps are not part of reproducibility guarantees
- JSON canonicalisation relies on Postgres `jsonb::text` stability

---

## Known risks

- Trigger-heavy design impacts throughput
- Audit-chain verification is O(n)
- No sharding or partitioning yet
- No external time authority

---

## Non-goals (current phase)

- ISO 20022 semantic mapping
- Economic valuation or liquidity modeling
- External anchoring (blockchain, TSA)
