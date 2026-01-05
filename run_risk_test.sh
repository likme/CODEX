#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CB_INFRA_ENV="${ROOT_DIR}/community-bank/infra/.env"
LEDGER_DIR="${ROOT_DIR}/community-bank-platform/core-ledger"

log() { printf "\n==> %s\n" "$*"; }

log "Resolve POSTGRES_PORT from community-bank/infra/.env"
if [ ! -f "$CB_INFRA_ENV" ]; then
  echo "ERROR: missing $CB_INFRA_ENV (run ./purge_and_up.sh first)" >&2
  exit 1
fi

POSTGRES_PORT="$(grep '^POSTGRES_PORT=' "$CB_INFRA_ENV" | cut -d= -f2 || true)"
if [ -z "$POSTGRES_PORT" ]; then
  echo "ERROR: POSTGRES_PORT missing in $CB_INFRA_ENV" >&2
  echo "File content:" >&2
  sed 's/^/  /' "$CB_INFRA_ENV" >&2
  exit 1
fi
echo "POSTGRES_PORT=${POSTGRES_PORT}"

export LEDGER_DB_DSN="postgres://ledger:ledger@localhost:${POSTGRES_PORT}/ledger?sslmode=disable"
echo "LEDGER_DB_DSN=${LEDGER_DB_DSN}"

log "Connectivity check"
psql "$LEDGER_DB_DSN" -c 'select now() as db_now, current_user as db_user, current_database() as db_name;'

log "Run Go test (risk layer)"
if [ ! -d "$LEDGER_DIR" ]; then
  echo "ERROR: missing $LEDGER_DIR" >&2
  exit 1
fi

cd "$LEDGER_DIR"
go test ./internal/store -run TestRiskLayer_EventLogProofs_AppendOnly_ChainOK -count=1 -v

log "Done"