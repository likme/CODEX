#!/usr/bin/env bash
set -euo pipefail

# scripts/test_genesis.sh
#
# Usage:
#   PGURI="postgres://user:pass@localhost:5432/postgres?sslmode=disable" \
#   GENESIS_SQL="community-bank-platform/core-ledger/internal/store/migrations/000_genesis.sql" \
#   ./scripts/test_genesis.sh
#
# Options:
#   PURGE=1        -> drop DB à la fin (default: 1)
#   KEEP_DB=0      -> alias inverse de PURGE, si KEEP_DB=1 alors PURGE=0
#   DBNAME=...     -> nom DB de test (default: ledger_genesis_test)
#   LEDGER_ROLE=...     -> rôle owner attendu par genesis (default: ledger)
#   LEDGER_APP_ROLE=... -> rôle runtime attendu (default: ledger_app)
#   PSQL_VERBOSE=1 -> psql sans -q

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PGURI="${PGURI:-}"
GENESIS_SQL="${GENESIS_SQL:-}"
PURGE="${PURGE:-1}"
KEEP_DB="${KEEP_DB:-0}"
DBNAME="${DBNAME:-ledger_genesis_test}"
LEDGER_ROLE="${LEDGER_ROLE:-ledger}"
LEDGER_APP_ROLE="${LEDGER_APP_ROLE:-ledger_app}"
PSQL_VERBOSE="${PSQL_VERBOSE:-0}"

die() { echo "ERROR: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

need psql
need sed

[[ -n "${PGURI}" ]] || die "PGURI is required"
[[ -n "${GENESIS_SQL}" ]] || die "GENESIS_SQL is required (path to 000_genesis.sql)"

# Resolve path
GENESIS_PATH="${ROOT_DIR}/${GENESIS_SQL}"
[[ -f "${GENESIS_PATH}" ]] || die "GENESIS_SQL not found: ${GENESIS_PATH}"

TEST_SQL_PATH="${ROOT_DIR}/scripts/sql/test_genesis.sql"
[[ -f "${TEST_SQL_PATH}" ]] || die "test SQL not found: ${TEST_SQL_PATH}"

# KEEP_DB overrides PURGE
if [[ "${KEEP_DB}" == "1" ]]; then
  PURGE=0
fi

PSQL_FLAGS=(-v ON_ERROR_STOP=1 -X)
if [[ "${PSQL_VERBOSE}" != "1" ]]; then
  PSQL_FLAGS+=(-q)
fi

psql_base=(psql "${PGURI}" "${PSQL_FLAGS[@]}")

# --- Helpers to build DBURI even if PGURI contains query params
# Split PGURI into "base" + "?query"
PGURI_BASE="${PGURI%%\?*}"
PGURI_QS=""
if [[ "${PGURI}" == *"?"* ]]; then
  PGURI_QS="?${PGURI#*\?}"
fi
DBURI="${PGURI_BASE%/*}/${DBNAME}${PGURI_QS}"
psql_db=(psql "${DBURI}" "${PSQL_FLAGS[@]}")

# Defensive: only allow safe DB and role names (SQL identifiers)
safe_ident_re='^[a-zA-Z_][a-zA-Z0-9_]*$'
[[ "${DBNAME}" =~ ${safe_ident_re} ]] || die "DBNAME must be a safe identifier: ${DBNAME}"
[[ "${LEDGER_ROLE}" =~ ${safe_ident_re} ]] || die "LEDGER_ROLE must be a safe identifier: ${LEDGER_ROLE}"
[[ "${LEDGER_APP_ROLE}" =~ ${safe_ident_re} ]] || die "LEDGER_APP_ROLE must be a safe identifier: ${LEDGER_APP_ROLE}"

echo "==> Drop/create DB: ${DBNAME}"

# Terminate sessions to allow DROP DATABASE in CI/dev.
"${psql_base[@]}" <<SQL >/dev/null
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${DBNAME}'
  AND pid <> pg_backend_pid();
SQL

"${psql_base[@]}" -c "DROP DATABASE IF EXISTS ${DBNAME};" >/dev/null
"${psql_base[@]}" -c "CREATE DATABASE ${DBNAME};" >/dev/null

echo "==> Preflight roles (create if missing)"
"${psql_db[@]}" <<SQL >/dev/null
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${LEDGER_ROLE}') THEN
    EXECUTE format('CREATE ROLE %I NOLOGIN', '${LEDGER_ROLE}');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${LEDGER_APP_ROLE}') THEN
    EXECUTE format('CREATE ROLE %I NOLOGIN', '${LEDGER_APP_ROLE}');
  END IF;
END
\$\$;
SQL

echo "==> Apply genesis: ${GENESIS_SQL}"
"${psql_db[@]}" -f "${GENESIS_PATH}"

echo "==> Run tests: scripts/sql/test_genesis.sql"
"${psql_db[@]}" -f "${TEST_SQL_PATH}"

echo "==> OK"

if [[ "${PURGE}" == "1" ]]; then
  echo "==> Purge DB: ${DBNAME}"
  "${psql_base[@]}" <<SQL >/dev/null
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${DBNAME}'
  AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS ${DBNAME};
SQL
fi
