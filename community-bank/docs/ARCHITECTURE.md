# community-bank/docs/ARCHITECTURE.md

# Architecture

- **infra**: local runtime services (Postgres, Redis, Prometheus, Grafana).
- **core-ledger**: double-entry ledger, idempotency, audit/event log.

Next: holds (card authorizations) and available balance.

---

## Ledger invariants (Phase A)

The ledger is designed around Phase A invariants:

- **Double-entry enforced by DB**: every transfer must balance.
- **Append-only**: events are never mutated in place.
- **Idempotency**: duplicate requests do not create duplicate economic effects.
- **Tamper-evident chain**: events are linked in a hash chain to make history edits detectable.
- **DB is the oracle**: verification is possible from Postgres state alone.

These invariants intentionally bias the design toward integrity over throughput.

---

## Throughput and contention

### Single global chain head

The audit chain is implemented as a **single global chain**. Each appended event updates the chain head and links to the previous event hash.

This implies a structural trade-off:

- **Unique global chain = maximal integrity and ordering**
- **Unique global chain = global contention and capped throughput**

### Why throughput is capped

The append path takes a **global lock** to ensure strict serialization of the chain head update:

- The implementation uses `event_chain_head FOR UPDATE`.
- This lock **serializes all event inserts**, even if the events concern unrelated accounts or domains.
- Qualitatively: **each `INSERT` into `event_log` participates in a single global critical section**.
- Consequence: on a single Postgres primary, effective throughput becomes approximately “one event append at a time” (plus transaction overhead), regardless of how many clients are producing events.

This is not accidental. It is the mechanism that makes the chain’s global ordering and tamper-evidence straightforward and defensible.

### What this means for scaling

- Scaling reads is easy (indexes, replicas, projections).
- Scaling writes is intentionally constrained by the global lock.
- Any claim that the system can scale write throughput linearly without changing the chaining model is false.

If write scale becomes a primary objective, the chaining strategy must change. The roadmap contains mitigation options that preserve the Phase A intent while relaxing global serialization.
