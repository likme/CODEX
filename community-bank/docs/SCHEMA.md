# Schema Contract (Weapon-Grade)

## Scope
Defines database-level contracts that MUST hold regardless of application behavior.

## Roles
- `ledger` (admin): migrations, verification
- `ledger_app` (runtime): minimal INSERT/SELECT only

## Core tables
- `accounts`: identity + currency
- `ledger_tx`: transaction envelope
- `ledger_entry`: double-entry lines
- `idempotency`: request anchor and replay
- `event_log`: append-only audit events
- `event_chain_head`: serialized chain state

## Accounting invariant
For every `tx_id`:
- Exactly 2 entries
- 1 DEBIT + 1 CREDIT
- Same amount
- Same currency

Enforced by:
- DEFERRABLE constraint trigger
- Checked at COMMIT, not per statement

## Append-only guarantee
- UPDATE and DELETE forbidden on:
  - `ledger_tx`
  - `ledger_entry`
  - `event_log`
- Enforced via triggers raising exceptions

## Idempotency contract
- `idempotency.key` is the replay anchor
- First request binds key → tx_id
- Same request hash → replay same response
- Different request hash → hard conflict

## Audit chain
- Gapless `seq` enforced via `event_chain_head FOR UPDATE`
- Hash material includes:
  - seq, prev_hash
  - event_id
  - DB-owned created_at (UTC)
  - event metadata
  - payload_hash
- Hashing:
  - Canonical JSON via `jsonb::text`
  - SHA256 over length-prefixed fields

## Verification
- `verify_event_chain_detail()`:
  - recomputes full chain
  - returns break point and reason
- Used by E2E and admin audits

## Non-goals
- Soft deletes
- Partial transactions
- Event mutation
