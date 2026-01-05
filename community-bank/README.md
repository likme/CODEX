# Community Bank (Minimal Core Ledger)

A minimal, auditable banking core with a double-entry ledger and a fully reproducible local E2E test.

## Goals

- Clone-and-run: `make e2e` works on a clean machine
- Double-entry accounting
- Strict idempotency for transfers
- Audit-friendly behavior and deterministic startup
- Local reproducible infra (Docker Compose)

License: AGPL-3.0

## Repository layout

This repository uses Git submodules:

- `infra/` (Postgres, Redis, Prometheus, Grafana)
- `core-ledger/` (Go HTTP API + storage layer)

## Prerequisites

- Docker + Docker Compose
- Go (latest stable recommended)
- curl
- jq

## Quick start

Clone with submodules:

```
git clone --recurse-submodules git@github.com:likme/community-bank.git
cd community-bank
make e2e
```

If you already cloned without submodules:

```
git submodule update --init --recursive
make e2e
```

## What make e2e does

1. Starts local infra via Docker Compose (dynamic Postgres port)

2. Starts the Go API server

3. Creates 3 accounts (Alice, Bob, SYSTEM)

4. Mints funds to Alice

5. Transfers funds from Alice to Bob

6. Verifies balances

7. Stops the server

Expected output ends with: E2E OK

## Reproducibility notes

- Postgres port is chosen dynamically to avoid collisions.

- The API server must receive LEDGER_DB_DSN from the E2E script (no hardcoded DB defaults).

- Database migrations are embedded and applied at startup.

- If port 8080 is already in use, the E2E script will pick a free port automatically.


## Troubleshooting

### Port already in use (8080)

The E2E script uses a free port automatically. If you run the server manually, ensure no other process is listening on the same port:

```
ss -ltnp | grep ':8080' || true
```

### Docker leftovers

If you need to wipe project containers/networks:

```
docker ps -a --filter "name=cbp-" --format "{{.ID}}" | xargs -r docker rm -f
docker network ls --filter "name=infra_default" -q | xargs -r docker network rm
```



