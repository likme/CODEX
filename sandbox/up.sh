#!/usr/bin/env bash
set -euo pipefail

SCENARIO="${1:-smoke}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/sandbox/env.sh"

INFRA_DIR="${ROOT_DIR}/community-bank/infra"
LEDGER_DIR="${ROOT_DIR}/community-bank-platform/core-ledger"

cd "${INFRA_DIR}"
docker compose up -d

echo "Waiting for postgres (host-side)..."
until psql "${PGURI_ADMIN}" -X -tAc "SELECT 1;" >/dev/null 2>&1
do
  sleep 1
done
echo "Postgres ready"

# Create DB if missing
if ! psql "${PGURI_ADMIN}" -X -tAc "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}';" | grep -qx "1"; then
  echo "Creating database ${POSTGRES_DB}..."
  psql "${PGURI_ADMIN}" -X -v ON_ERROR_STOP=1 -c \
    "CREATE DATABASE ${POSTGRES_DB} WITH TEMPLATE template0 ENCODING 'UTF8';"
else
  echo "Database ${POSTGRES_DB} already exists"
fi

# Ensure runtime role exists (using .env source of truth)
: "${POSTGRES_APP_USER:?missing POSTGRES_APP_USER in .env}"
: "${POSTGRES_APP_PASSWORD:?missing POSTGRES_APP_PASSWORD in .env}"

echo "Ensuring runtime role ${POSTGRES_APP_USER}..."
psql "${PGURI_ADMIN}" -X -v ON_ERROR_STOP=1 -c "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_APP_USER}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${POSTGRES_APP_USER}', '${POSTGRES_APP_PASSWORD}');
  ELSE
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${POSTGRES_APP_USER}', '${POSTGRES_APP_PASSWORD}');
  END IF;
END
\$\$;
"

psql "${PGURI_ADMIN}" -X -v ON_ERROR_STOP=1 -c \
  "ALTER ROLE ${POSTGRES_APP_USER} NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION INHERIT;"

# e2e contract
: "${LEDGER_DB_DSN:?missing LEDGER_DB_DSN}"
: "${LEDGER_DB_DSN_APP:?missing LEDGER_DB_DSN_APP}"

LEDGER_LOG="${SANDBOX_OUT}/core-ledger.log"
rm -f "${LEDGER_LOG}"

echo "Building core-ledger..."
cd "${LEDGER_DIR}"
BIN_DIR="${SANDBOX_OUT}/bin"
mkdir -p "${BIN_DIR}"
BIN="${BIN_DIR}/core-ledger-server"
go build -o "${BIN}" ./cmd/server

echo "Starting core-ledger (migrate phase as admin)..."
export LEDGER_URL="${LEDGER_URL:-http://127.0.0.1:8080}"
export LEDGER_HTTP_ADDR="${LEDGER_HTTP_ADDR:-:8080}"

# Phase 1: migrations with admin DSN
LEDGER_DB_DSN="${LEDGER_DB_DSN}" \
LEDGER_DB_MIGRATE=1 \
LEDGER_HTTP_ADDR="${LEDGER_HTTP_ADDR}" \
"${BIN}" >"${LEDGER_LOG}" 2>&1 &
LEDGER_PID=$!

cleanup() {
  kill "${LEDGER_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Waiting for ledger /healthz (migrate)..."
until curl -fsS "${LEDGER_URL}/healthz" >/dev/null 2>&1
do
  if ! kill -0 "${LEDGER_PID}" >/dev/null 2>&1; then
    echo "core-ledger exited during migrate. Log tail:" >&2
    tail -n 200 "${LEDGER_LOG}" >&2 || true
    exit 1
  fi
  sleep 1
done
echo "Ledger healthy (migrate done)"

# Stop migrate instance
kill "${LEDGER_PID}" >/dev/null 2>&1 || true
wait "${LEDGER_PID}" >/dev/null 2>&1 || true

echo "Starting core-ledger (runtime phase as app)..."
: > "${LEDGER_LOG}"

# Phase 2: runtime with least-privilege DSN, no migrations
LEDGER_DB_DSN="${LEDGER_DB_DSN_APP}" \
LEDGER_DB_MIGRATE=0 \
LEDGER_HTTP_ADDR="${LEDGER_HTTP_ADDR}" \
"${BIN}" >"${LEDGER_LOG}" 2>&1 &
LEDGER_PID=$!

echo "Waiting for ledger /healthz (runtime)..."
until curl -fsS "${LEDGER_URL}/healthz" >/dev/null 2>&1
do
  if ! kill -0 "${LEDGER_PID}" >/dev/null 2>&1; then
    echo "core-ledger exited during runtime start. Log tail:" >&2
    tail -n 200 "${LEDGER_LOG}" >&2 || true
    exit 1
  fi
  sleep 1
done
echo "Ledger healthy (runtime)"

cd "${ROOT_DIR}/community-bank/scripts"

# Force correct LEDGER_DIR for e2e script (monorepo layout)
export LEDGER_DIR="${LEDGER_DIR}"

# Critical: do not let e2e_smoke start infra/server again
export E2E_SKIP_SERVER=1

case "${SCENARIO}" in
  smoke)
    ./e2e_smoke.sh
    ;;
  retail_30d)
    ./e2e_retail_30d.sh
    ;;
  carbon_mrv)
    ./e2e_carbon_mrv.sh
    ;;
  *)
    echo "Unknown scenario: ${SCENARIO}" >&2
    exit 1
    ;;
esac
