#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/community-bank/infra/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: .env not found at ${ENV_FILE}" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

: "${POSTGRES_HOST:?missing POSTGRES_HOST in .env}"
: "${POSTGRES_PORT:?missing POSTGRES_PORT in .env}"
: "${POSTGRES_DB:?missing POSTGRES_DB in .env}"
: "${POSTGRES_USER:?missing POSTGRES_USER in .env}"
: "${POSTGRES_PASSWORD:?missing POSTGRES_PASSWORD in .env}"

[[ "${POSTGRES_PORT}" =~ ^[0-9]+$ ]] || { echo "ERROR: POSTGRES_PORT must be numeric, got '${POSTGRES_PORT}'" >&2; exit 1; }

export PGURI="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=disable"
export PGURI_ADMIN="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/postgres?sslmode=disable"

# Contract for e2e_smoke.sh and sandbox/up.sh
: "${POSTGRES_APP_USER:?missing POSTGRES_APP_USER in .env}"
: "${POSTGRES_APP_PASSWORD:?missing POSTGRES_APP_PASSWORD in .env}"

export LEDGER_DB_DSN="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=disable"
export LEDGER_DB_DSN_APP="postgres://${POSTGRES_APP_USER}:${POSTGRES_APP_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=disable"


export SANDBOX_ROOT="${ROOT_DIR}/sandbox"
export SANDBOX_OUT="${SANDBOX_ROOT}/out"
mkdir -p "${SANDBOX_OUT}"
