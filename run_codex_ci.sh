#!/usr/bin/env bash
set -euo pipefail

# run_codex_ci.sh
#
# Maintainer-grade, falsifiable runner.
#
# Steps:
# 0) (optional) purge + bring infra up ONCE
# 1) (re)create isolated DBs: ledger_proof + ledger_gotest
# 2) run genesis+SQL assertions+audits on ledger_proof (NO_PURGE=1, RUN_GO_TESTS=0)
# 3) run Go tests on ledger_gotest (destructive allowed)
# 4) re-audit ledger_proof and FAIL if it changed
#
# Env options:
#   OUT_DIR=demo_out
#   PG_HOST=localhost
#   PG_PORT=55432
#   PG_USER=ledger
#   PG_PASS=ledger
#   ADMIN_DB=postgres
#   PROOF_DB=ledger_proof
#   GO_DB=ledger_gotest
#   DO_PURGE=1|0        (default 1) call ./purge_and_up.sh once
#   RECREATE_DBS=1|0    (default 1) drop/create proof+gotest each run
#   DROP_DBS_ON_EXIT=0|1 (default 0)
#
# Pass-through to run_genesis.sh:
#   PSQL_VERBOSE=0|1 (default 0)
#   DIAG_TRIGGERS=1  (default 1)
#
# Output:
#   demo_out/codex-ci-<ts>.log
#   demo_out/codex-ci-<ts>-summary.txt
#   plus genesis-* artifacts emitted by run_genesis.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/demo_out}"
mkdir -p "${OUT_DIR}"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${OUT_DIR}/codex-ci-${TS}.log"
SUMMARY="${OUT_DIR}/codex-ci-${TS}-summary.txt"

exec > >(tee -a "${LOG}") 2>&1

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }

need psql
need tee
need date
need grep
need sed
need diff
need go
need docker
if ! docker compose version >/dev/null 2>&1; then
  echo "Missing dependency: docker compose (Compose v2)" >&2
  exit 1
fi

PG_HOST="${PG_HOST:-localhost}"
DEFAULT_PORT="$(grep '^POSTGRES_PORT=' "${ROOT_DIR}/community-bank/infra/.env" 2>/dev/null | cut -d= -f2 || true)"
PG_PORT="${PG_PORT:-${DEFAULT_PORT:-55432}}"
PG_USER="${PG_USER:-ledger}"
PG_PASS="${PG_PASS:-ledger}"
ADMIN_DB="${ADMIN_DB:-postgres}"

PROOF_DB="${PROOF_DB:-ledger_proof}"
GO_DB="${GO_DB:-ledger_gotest}"

DO_PURGE="${DO_PURGE:-1}"
RECREATE_DBS="${RECREATE_DBS:-1}"
DROP_DBS_ON_EXIT="${DROP_DBS_ON_EXIT:-0}"

PSQL_VERBOSE="${PSQL_VERBOSE:-0}"
DIAG_TRIGGERS="${DIAG_TRIGGERS:-1}"

export PGPASSWORD="${PG_PASS}"

ADMIN_DSN="postgres://${PG_USER}:${PG_PASS}@${PG_HOST}:${PG_PORT}/${ADMIN_DB}?sslmode=disable"
PROOF_DSN="postgres://${PG_USER}:${PG_PASS}@${PG_HOST}:${PG_PORT}/${PROOF_DB}?sslmode=disable"
GO_DSN="postgres://${PG_USER}:${PG_PASS}@${PG_HOST}:${PG_PORT}/${GO_DB}?sslmode=disable"

log_section() { echo; echo "==> $1"; }

psql_admin() { psql "${ADMIN_DSN}" -v ON_ERROR_STOP=1 -X -q "$@"; }
psql_admin_at() { psql "${ADMIN_DSN}" -v ON_ERROR_STOP=1 -X -qAt "$@"; }

terminate_db_sessions() {
  local db="$1"
  psql_admin <<SQL >/dev/null
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${db}'
  AND pid <> pg_backend_pid();
SQL
}

drop_db() {
  local db="$1"
  terminate_db_sessions "${db}" || true
  psql_admin -c "DROP DATABASE IF EXISTS \"${db}\";" >/dev/null
}

create_db() {
  local db="$1"
  psql_admin -c "CREATE DATABASE \"${db}\";" >/dev/null
}

db_exists() {
  local db="$1"
  psql_admin_at -c "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -qx "1"
}

cleanup_dbs() {
  if [[ "${DROP_DBS_ON_EXIT}" != "1" ]]; then
    return 0
  fi
  log_section "Cleanup: dropping DBs (DROP_DBS_ON_EXIT=1)"
  drop_db "${PROOF_DB}" || true
  drop_db "${GO_DB}" || true
  echo "Dropped: ${PROOF_DB}, ${GO_DB}"
}
trap cleanup_dbs EXIT
proof_snapshot() {
  # Stable, falsifiable snapshot of PROOF_DB state.
  #
  # Captures:
  # - chain_ok (verify_event_chain)
  # - chain_head (last_seq + last_hash)
  # - event_log_fingerprint (sha256 over seq:hash for all events ordered by seq)
  # - event_log_totals (by aggregate_type)
  # - event_log_tail (last 5 events: seq + hash + prev_hash + types) for human inspection
  #
  # Output is diff-friendly and deterministic for identical DB state.
  local out_file="$1"

  {
    echo "chain_ok=$(
      psql "${PROOF_DSN}" -v ON_ERROR_STOP=1 -X -qAt -c "SELECT public.verify_event_chain();" \
      | tr -d '[:space:]'
    )"

    echo "chain_head=$(
      psql "${PROOF_DSN}" -v ON_ERROR_STOP=1 -X -qAt -c \
        "SELECT last_seq::text || '|' || encode(last_hash,'hex')
         FROM public.event_chain_head
         WHERE id=1;" \
      | tr -d '[:space:]'
    )"

    echo "event_log_fingerprint=$(
      psql "${PROOF_DSN}" -v ON_ERROR_STOP=1 -X -qAt -c \
        "SELECT encode(
            digest(
              COALESCE(string_agg(seq::text || ':' || encode(hash,'hex'), '|' ORDER BY seq), ''),
              'sha256'
            ),
            'hex'
          )
         FROM public.event_log;" \
      | tr -d '[:space:]'
    )"

    echo "event_log_totals:"
    psql "${PROOF_DSN}" -v ON_ERROR_STOP=1 -X -qAt -c \
      "SELECT aggregate_type, count(*)::bigint
       FROM public.event_log
       GROUP BY aggregate_type
       ORDER BY aggregate_type;"

    echo "event_log_tail:"
    psql "${PROOF_DSN}" -v ON_ERROR_STOP=1 -X -qAt -c \
      "SELECT
         seq::bigint,
         encode(hash,'hex') AS hash,
         encode(prev_hash,'hex') AS prev_hash,
         event_type,
         aggregate_type,
         aggregate_id::text
       FROM public.event_log
       ORDER BY seq DESC
       LIMIT 5;"
  } >"${out_file}"
}


log_section "Context"
echo "ROOT_DIR=${ROOT_DIR}"
echo "OUT_DIR=${OUT_DIR}"
echo "TS=${TS}"
echo "LOG=${LOG}"
echo "PG_HOST=${PG_HOST}"
echo "PG_PORT=${PG_PORT}"
echo "PG_USER=${PG_USER}"
echo "ADMIN_DB=${ADMIN_DB}"
echo "PROOF_DB=${PROOF_DB}"
echo "GO_DB=${GO_DB}"
echo "DO_PURGE=${DO_PURGE}"
echo "RECREATE_DBS=${RECREATE_DBS}"
echo "DROP_DBS_ON_EXIT=${DROP_DBS_ON_EXIT}"
echo "PROOF_DSN=${PROOF_DSN}"
echo "GO_DSN=${GO_DSN}"


log_section "Step 0. Infra up (purge once)"
if [[ "${DO_PURGE}" == "1" ]]; then
  "${ROOT_DIR}/purge_and_up.sh"
else
  echo "DO_PURGE=0: skipping purge_and_up.sh"
fi

log_section "Preflight: confirm role and server"
psql_admin_at -c "SELECT now(), current_user, current_database(), inet_server_addr(), inet_server_port();" | sed 's/^/server= /'
psql_admin_at -c "SELECT rolsuper::text || '|' || rolcreatedb::text FROM pg_roles WHERE rolname=current_user;" | sed 's/^/role_flags(rolsuper|rolcreatedb)= /'


log_section "Step 1. Create isolated DBs"
if [[ "${RECREATE_DBS}" == "1" ]]; then
  drop_db "${PROOF_DB}"
  drop_db "${GO_DB}"
  create_db "${PROOF_DB}"
  create_db "${GO_DB}"
else
  if ! db_exists "${PROOF_DB}"; then create_db "${PROOF_DB}"; fi
  if ! db_exists "${GO_DB}"; then create_db "${GO_DB}"; fi
fi
db_exists "${PROOF_DB}" || { echo "ERROR: missing ${PROOF_DB}" >&2; exit 1; }
db_exists "${GO_DB}" || { echo "ERROR: missing ${GO_DB}" >&2; exit 1; }
echo "DBs ready: ${PROOF_DB}, ${GO_DB}"

log_section "Step 2. Proof run on ${PROOF_DB} (falsifiable)"
# Critical: NO_PURGE=1 so run_genesis.sh cannot nuke volumes again.
(
  export LEDGER_DB_DSN="${PROOF_DSN}"
  export NO_PURGE=1
  export RUN_GO_TESTS=0
  export POST_GO_AUDIT=0
  export OUT_DIR="${OUT_DIR}"
  export PSQL_VERBOSE="${PSQL_VERBOSE}"
  export DIAG_TRIGGERS="${DIAG_TRIGGERS}"
  "${ROOT_DIR}/run_genesis.sh"
)
echo "Proof run: OK"

log_section "Step 2b. Capture proof snapshot (baseline)"
PROOF_BASE="${OUT_DIR}/codex-ci-${TS}-proof-baseline.txt"
proof_snapshot "${PROOF_BASE}"
cat "${PROOF_BASE}"

log_section "Step 3. Go tests on ${GO_DB} (destructive allowed)"
(
  cd "${ROOT_DIR}/community-bank-platform/core-ledger"
  export LEDGER_DB_DSN="${GO_DSN}"
  go test ./... -count=1
)
echo "Go tests: OK"

log_section "Step 4. Capture proof snapshot (after Go tests) and verify unchanged"
PROOF_AFTER="${OUT_DIR}/codex-ci-${TS}-proof-after.txt"
PROOF_DIFF="${OUT_DIR}/codex-ci-${TS}-proof-diff.txt"
proof_snapshot "${PROOF_AFTER}"
cat "${PROOF_AFTER}"

if diff -u "${PROOF_BASE}" "${PROOF_AFTER}" >"${PROOF_DIFF}"; then
  PROOF_STABLE="YES"
  echo "proof_unchanged=YES"
else
  PROOF_STABLE="NO"
  echo "proof_unchanged=NO"
  echo "Diff:"
  cat "${PROOF_DIFF}"
  echo "ERROR: proof DB changed after Go tests. Isolation is broken." >&2
  exit 1
fi

log_section "Step 5. Summary"
{
  echo "CODEX CI SUMMARY"
  echo "ts=${TS}"
  echo "proof_db=${PROOF_DB}"
  echo "go_db=${GO_DB}"
  echo
  echo "proof_run=OK"
  echo "go_tests=OK"
  echo "proof_unchanged=${PROOF_STABLE}"
  echo
  echo "artifacts:"
  echo "  - ${LOG}"
  echo "  - ${SUMMARY}"
  echo "  - ${PROOF_BASE}"
  echo "  - ${PROOF_AFTER}"
  echo "  - ${PROOF_DIFF}"
  echo "  - (plus genesis-* artifacts in ${OUT_DIR})"
} | tee "${SUMMARY}"

log_section "DONE"
echo "Artifacts written to: ${OUT_DIR}"
ls -1 "${OUT_DIR}" | grep -E "^(codex-ci-${TS}|genesis-)" | sed 's/^/  - /'
