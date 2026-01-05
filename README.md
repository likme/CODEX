# Codex

Codex is a minimal, deterministic, and auditable accounting ledger.

It is designed as a **core accounting kernel**, not a product suite.
The focus is on mechanical guarantees, reproducibility, and verifiable invariants.

## Scope

Codex provides a strict accounting core with the following properties:

- append-only storage at the database level
- strict double-entry accounting
- full idempotency, including under concurrency
- deterministic execution for identical canonical inputs
- immutable event log chained by cryptographic hashes
- verifiable detection of any tampering or invalid mutation
- reproducible hashing via RFC 8785 (JSON Canonicalization Scheme)

The database enforces critical invariants.
The application layer orchestrates operations but cannot rewrite history,
patch errors a posteriori, or produce divergent results for the same request.

Everything outside the core (APIs, workflows, business logic, reporting,
risk models) is intentionally out of scope.

## Architecture principles

- The ledger does not interpret business meaning.
- It records facts, enforces invariants, and produces proofs.
- Security relies on mechanical constraints, not operator discipline.
- Auditability is continuous, not ex post.

The system provides a strict logical order and a local authoritative timestamp.
When external precedence matters, ledger states can be cryptographically
anchored into a public high-consensus registry to prove existence before time T.

## License

Codex is free software licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**.

You are free to use, modify, and redistribute this software under the terms of the AGPL.
If you run a modified version and provide network access to users, you must make the
corresponding source code available to those users, as required by the license.

See the `LICENSE` file for details.

## Commercial activities

Commercial activities relate exclusively to:

- technical consulting and architecture reviews
- integration and customization support
- security audits and reproducibility analysis
- operational support and deployment assistance

No additional restrictions are imposed on the code.

See `COMMERCIAL.md` for details.

## Status

Codex is a low-level technical core.
It is intended to be integrated, evaluated, extended, or rejected
without dependency on a specific vendor or individual.

If this core cannot be transmitted independently, it has no value
for a serious technical partnership.
