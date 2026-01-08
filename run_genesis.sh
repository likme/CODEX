#!/usr/bin/env bash
set -euo pipefail

# run_genesis.sh
#
# Purpose:
# - (optional) purge + bring infra up (reuse purge_and_up.sh)
# - reset DB schema public
# - apply 000_genesis.sql
# - run scripts/sql/test_genesis.sql
# - optionally run Go integration tests
# - write artifacts to demo_out/ (logs + audits + diagnostics)
#
# Usage:
#   ./run_genesis.sh
#
# Options (env):
#   OUT_DIR=demo_out
#   GENESIS_SQL=... (default: community-bank-platform/core-ledger/internal/store/migrations/000_genesis.sql)
#   TEST_SQL=...    (default: scripts/sql/test_genesis.sql)
#   NO_PURGE=1      (skip purge_and_up.sh, assumes infra already up)
#   KEEP_SCHEMA=1   (skip DROP/CREATE public)
#   PSQL_VERBOSE=1  (psql without -q, shows more output)
#   RUN_GO_TESTS=1  (run go test ./... in core-ledger, using LEDGER_DB_DSN)
#   DIAG_TRIGGERS=1 (print snapshot->event_log trigger diagnostics)
#   POST_GO_AUDIT=1 (when RUN_GO_TESTS=1, run post-go audits; default: 1)
#
# New (orchestration-only):
#   LEDGER_DB_DSN=...  (if set, do NOT overwrite it from infra/.env)
#   DB_NAME=...        (only used when LEDGER_DB_DSN is NOT set; overrides POSTGRES_DB)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CB_DIR="${ROOT_DIR}/community-bank"
INFRA_DIR="${CB_DIR}/infra"
LEDGER_DIR="${ROOT_DIR}/community-bank-platform/core-ledger"

OUT_DIR="${OUT_DIR:-${ROOT_DIR}/demo_out}"
GENESIS_SQL="${GENESIS_SQL:-${LEDGER_DIR}/internal/store/migrations/000_genesis.sql}"
TEST_SQL="${TEST_SQL:-${ROOT_DIR}/scripts/sql/test_genesis.sql}"

NO_PURGE="${NO_PURGE:-0}"
KEEP_SCHEMA="${KEEP_SCHEMA:-0}"
PSQL_VERBOSE="${PSQL_VERBOSE:-0}"
RUN_GO_TESTS="${RUN_GO_TESTS:-0}"
DIAG_TRIGGERS="${DIAG_TRIGGERS:-1}"
POST_GO_AUDIT="${POST_GO_AUDIT:-1}"

DB_NAME="${DB_NAME:-}" # optional override when LEDGER_DB_DSN not set

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }

log_section() {
  local name="$1"
  echo
  echo "==> ${name}"
}

psql_run() {
  # Usage: psql_run <<'SQL' ... SQL
  "${PSQL[@]}" "$@"
}

psql_scalar() {
  # Usage: psql_scalar "SELECT 1;"
  # Must output a single scalar value deterministically.
  local sql="$1"
  local out
  out="$("${PSQL_AT[@]}" -c "${sql}")"
  echo "${out}" | tr -d '[:space:]'
}

audit_event_log_totals() {
  # Usage: audit_event_log_totals /path/to/file
  local out_file="$1"
  psql_run <<'SQL' | tee "${out_file}"
SELECT aggregate_type, count(*) AS n
FROM public.event_log
GROUP BY 1
ORDER BY 1;
SQL
}

audit_risk_proofs_persisted_counts() {
  # Usage: audit_risk_proofs_persisted_counts /path/to/file
  local out_file="$1"
  psql_run <<'SQL' | tee "${out_file}"
SELECT
  (SELECT count(*) FROM public.valuation_snapshot) AS valuation_snapshots,
  (SELECT count(*) FROM public.liquidity_snapshot) AS liquidity_snapshots,
  (SELECT count(*) FROM public.event_log WHERE event_type='VALUATION_SNAPSHOT') AS valuation_events,
  (SELECT count(*) FROM public.event_log WHERE event_type='LIQUIDITY_SNAPSHOT') AS liquidity_events;
SQL
}

need docker
if ! docker compose version >/dev/null 2>&1; then
  echo "Missing dependency: docker compose (Compose v2)" >&2
  exit 1
fi
need psql
need grep
need cut
need tee
need sed
need date
need diff

if [[ "${RUN_GO_TESTS}" == "1" ]]; then
  need go
fi

mkdir -p "${OUT_DIR}"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${OUT_DIR}/genesis-${TS}.log"
AUDIT_CHAIN="${OUT_DIR}/genesis-${TS}-audit-chain.txt"
AUDIT_EVENTS_PRE="${OUT_DIR}/genesis-${TS}-audit-events-pre-go.txt"
AUDIT_EVENTS_POST="${OUT_DIR}/genesis-${TS}-audit-events-post-go.txt"
AUDIT_EVENTS_DIFF="${OUT_DIR}/genesis-${TS}-audit-events-diff.txt"
AUDIT_PROOFS="${OUT_DIR}/genesis-${TS}-audit-proofs.txt"
AUDIT_PROOFS_COUNTS="${OUT_DIR}/genesis-${TS}-audit-proofs-counts.txt"
AUDIT_PROOFS_COUNTS_POST="${OUT_DIR}/genesis-${TS}-audit-proofs-counts-post-go.txt"
AUDIT_CHAIN_POST="${OUT_DIR}/genesis-${TS}-audit-chain-post-go.txt"
AUDIT_DIAG_TRIGGERS="${OUT_DIR}/genesis-${TS}-diag-triggers.txt"
SUMMARY="${OUT_DIR}/genesis-${TS}-summary.txt"

exec > >(tee -a "${LOG}") 2>&1

echo "==> Context"
echo "ROOT_DIR=${ROOT_DIR}"
echo "CB_DIR=${CB_DIR}"
echo "INFRA_DIR=${INFRA_DIR}"
echo "LEDGER_DIR=${LEDGER_DIR}"
echo "OUT_DIR=${OUT_DIR}"
echo "GENESIS_SQL=${GENESIS_SQL}"
echo "TEST_SQL=${TEST_SQL}"
echo "NO_PURGE=${NO_PURGE}"
echo "KEEP_SCHEMA=${KEEP_SCHEMA}"
echo "RUN_GO_TESTS=${RUN_GO_TESTS}"
echo "POST_GO_AUDIT=${POST_GO_AUDIT}"
echo "DIAG_TRIGGERS=${DIAG_TRIGGERS}"
echo "DB_NAME=${DB_NAME:-<unset>}"
echo "LOG=${LOG}"
echo "TS=${TS}"

if [[ ! -f "${GENESIS_SQL}" ]]; then
  echo "ERROR: genesis SQL missing: ${GENESIS_SQL}" >&2
  exit 1
fi
if [[ ! -f "${TEST_SQL}" ]]; then
  echo "ERROR: test SQL missing: ${TEST_SQL}" >&2
  exit 1
fi

if [[ "${NO_PURGE}" != "1" ]]; then
  log_section "Step 0. Clean + Infra up"
  "${ROOT_DIR}/purge_and_up.sh"
else
  log_section "Step 0. NO_PURGE=1, skipping purge_and_up.sh"
fi

if [[ ! -f "${INFRA_DIR}/.env" ]]; then
  echo "ERROR: missing ${INFRA_DIR}/.env" >&2
  exit 1
fi

POSTGRES_DB="$(grep '^POSTGRES_DB=' "${INFRA_DIR}/.env" | cut -d= -f2)"
POSTGRES_USER="$(grep '^POSTGRES_USER=' "${INFRA_DIR}/.env" | cut -d= -f2)"
POSTGRES_PASSWORD="$(grep '^POSTGRES_PASSWORD=' "${INFRA_DIR}/.env" | cut -d= -f2)"
POSTGRES_PORT="$(grep '^POSTGRES_PORT=' "${INFRA_DIR}/.env" | cut -d= -f2)"

if [[ -z "${POSTGRES_DB}" || -z "${POSTGRES_USER}" || -z "${POSTGRES_PASSWORD}" || -z "${POSTGRES_PORT}" ]]; then
  echo "ERROR: POSTGRES_* vars missing in ${INFRA_DIR}/.env" >&2
  exit 1
fi

# Respect externally provided DSN. This is required for runner isolation (ledger_proof/ledger_gotest).
if [[ -n "${LEDGER_DB_DSN:-}" ]]; then
  echo
  echo "LEDGER_DB_DSN is pre-set by caller. Using it as-is."
else
  eff_db="${POSTGRES_DB}"
  if [[ -n "${DB_NAME}" ]]; then
    eff_db="${DB_NAME}"
  fi
  export LEDGER_DB_DSN="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${POSTGRES_PORT}/${eff_db}?sslmode=disable"
  echo
  echo "LEDGER_DB_DSN derived from infra/.env (DB=${eff_db})"
fi

echo "LEDGER_DB_DSN=${LEDGER_DB_DSN}"

PSQL_FLAGS=(-v ON_ERROR_STOP=1 -X)
if [[ "${PSQL_VERBOSE}" != "1" ]]; then
  PSQL_FLAGS+=(-q)
fi
PSQL=(psql "${LEDGER_DB_DSN}" "${PSQL_FLAGS[@]}")
PSQL_AT=(psql "${LEDGER_DB_DSN}" -v ON_ERROR_STOP=1 -X -qAt)

log_section "Step 0b. Connectivity"
"${PSQL_AT[@]}" -c "SELECT now(), current_user, current_database();"

log_section "Step 1. Reset DB schema (clean slate)"
if [[ "${KEEP_SCHEMA}" == "1" ]]; then
  echo "KEEP_SCHEMA=1, skipping schema reset"
else
  psql_run <<SQL >/dev/null
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO ${POSTGRES_USER};
GRANT ALL ON SCHEMA public TO public;
SQL
  echo "DB reset: OK"
fi

log_section "Step 1b. Sanity: reset really dropped snapshot columns"
pre_cols="$(
  psql "$LEDGER_DB_DSN" -v ON_ERROR_STOP=1 -X -qAt -c "
    SELECT count(*)
    FROM information_schema.columns
    WHERE table_schema='public'
      AND table_name IN ('valuation_snapshot','liquidity_snapshot')
      AND column_name IN ('ingestion_correlation_id','payload_canonical');
  " | tr -d '[:space:]'
)"
echo "pre_existing_snapshot_columns=${pre_cols}"
if [[ "${pre_cols}" != "0" ]]; then
  echo "ERROR: reset is not a clean slate. snapshot columns still exist pre-genesis." >&2
  exit 1
fi


log_section "Step 2. Apply genesis"
psql_run -f "${GENESIS_SQL}"
echo "Genesis applied: OK"

if [[ "${DIAG_TRIGGERS}" == "1" ]]; then
  log_section "Step 2b. Diagnostics: snapshot triggers"
  psql_run <<'SQL' | tee "${AUDIT_DIAG_TRIGGERS}"
SELECT
  c.relname AS table_name,
  tg.tgname AS trigger_name,
  tg.tgenabled AS enabled,
  pg_get_triggerdef(tg.oid) AS def
FROM pg_trigger tg
JOIN pg_class c ON c.oid = tg.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname='public'
  AND c.relname IN ('valuation_snapshot','liquidity_snapshot')
  AND NOT tg.tgisinternal
ORDER BY c.relname, tg.tgname;
SQL
fi

log_section "Step 2c. Diagnostics: risk triggers + functions"
psql_run <<'SQL'
SELECT
  tg.tgname,
  c.relname AS table_name,
  tg.tgenabled,
  pg_get_triggerdef(tg.oid) AS trigger_def
FROM pg_trigger tg
JOIN pg_class c ON c.oid = tg.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname='public'
  AND c.relname IN ('valuation_snapshot','liquidity_snapshot','event_log')
  AND NOT tg.tgisinternal
ORDER BY c.relname, tg.tgname;

SELECT p.proname, pg_get_functiondef(p.oid) AS func_def
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname='public'
  AND p.proname IN (
    'trg_valuation_snapshot_event_log',
    'trg_liquidity_snapshot_event_log',
    'trg_event_log_hash_chain'
  )
ORDER BY p.proname;
SQL

log_section "Step 3. Run SQL assertions"
psql_run -f "${TEST_SQL}"
echo "Assertions: OK"

log_section "Step 4. Audits (post-genesis + post-SQL, pre-Go)"

echo
echo "[audit] verify_event_chain() (scalar)"
chain_ok_pre="$(psql_scalar "SELECT public.verify_event_chain();")"
echo "${chain_ok_pre}" | tee "${AUDIT_CHAIN}"

echo
echo "[audit] event_log_totals (public.event_log) pre-Go"
audit_event_log_totals "${AUDIT_EVENTS_PRE}"

echo
echo "[audit] risk proofs: trigger probe (BEGIN/ROLLBACK) pre-Go"
psql_run <<'SQL' | tee "${AUDIT_PROOFS}"
BEGIN;

-- valuation probe
WITH ins AS (
  INSERT INTO public.valuation_snapshot(
    ingestion_correlation_id, asset_type, asset_id, as_of, price, currency, source, confidence,
    payload_json, payload_canonical, payload_hash
  )
  VALUES (
    'probe-' || gen_random_uuid()::text,
    'BOND', 'PROBE1', now(), 1.23, 'EUR', 'PROBE', 99,
    '{"p":1}'::jsonb, '{"p":1}', decode(repeat('ab',32),'hex')
  )
  RETURNING snapshot_id, ingestion_correlation_id
)
SELECT
  'valuation_probe' AS kind,
  ins.snapshot_id,
  ins.ingestion_correlation_id,
  (SELECT count(*) FROM public.event_log
     WHERE event_type='VALUATION_SNAPSHOT'
       AND aggregate_id = ins.snapshot_id) AS events_for_snapshot,
  (SELECT count(*) FROM public.event_log
     WHERE event_type='VALUATION_SNAPSHOT'
       AND correlation_id = ins.ingestion_correlation_id) AS events_for_corr
FROM ins;

-- liquidity probe
WITH ins AS (
  INSERT INTO public.liquidity_snapshot(
    ingestion_correlation_id, asset_type, asset_id, as_of, haircut_bps, time_to_cash_seconds, source,
    payload_json, payload_canonical, payload_hash
  )
  VALUES (
    'probe-' || gen_random_uuid()::text,
    'BOND', 'PROBE1', now(), 100, 3600, 'PROBE',
    '{"l":1}'::jsonb, '{"l":1}', decode(repeat('cd',32),'hex')
  )
  RETURNING snapshot_id, ingestion_correlation_id
)
SELECT
  'liquidity_probe' AS kind,
  ins.snapshot_id,
  ins.ingestion_correlation_id,
  (SELECT count(*) FROM public.event_log
     WHERE event_type='LIQUIDITY_SNAPSHOT'
       AND aggregate_id = ins.snapshot_id) AS events_for_snapshot,
  (SELECT count(*) FROM public.event_log
     WHERE event_type='LIQUIDITY_SNAPSHOT'
       AND correlation_id = ins.ingestion_correlation_id) AS events_for_corr
FROM ins;

ROLLBACK;
SQL

echo
echo "[audit] risk proofs: persisted counts (snapshots vs events) pre-Go"
audit_risk_proofs_persisted_counts "${AUDIT_PROOFS_COUNTS}"

risk_status_pre="$("${PSQL_AT[@]}" -c "
WITH snaps AS (
  SELECT snapshot_id AS sid, 'VALUATION_SNAPSHOT'::text AS et
  FROM public.valuation_snapshot
  UNION ALL
  SELECT snapshot_id AS sid, 'LIQUIDITY_SNAPSHOT'::text AS et
  FROM public.liquidity_snapshot
),
proofs AS (
  SELECT s.sid, s.et, count(e.*) AS n
  FROM snaps s
  LEFT JOIN public.event_log e
    ON e.aggregate_id = s.sid
   AND e.event_type   = s.et
  GROUP BY s.sid, s.et
),
agg AS (
  SELECT
    count(*) AS snapshots,
    sum(CASE WHEN n = 1 THEN 1 ELSE 0 END) AS ok_1,
    sum(CASE WHEN n = 0 THEN 1 ELSE 0 END) AS missing,
    sum(CASE WHEN n > 1 THEN 1 ELSE 0 END) AS dup
  FROM proofs
)
SELECT CASE
  WHEN (SELECT snapshots FROM agg)=0 THEN 'OK: no snapshots'
  WHEN (SELECT missing FROM agg)>0 THEN 'WARN: snapshots present but missing proofs'
  WHEN (SELECT dup FROM agg)>0 THEN 'WARN: duplicate proofs for some snapshots'
  WHEN (SELECT ok_1 FROM agg)=(SELECT snapshots FROM agg) THEN 'OK: 1:1 proofs'
  ELSE 'WARN: partial proofs'
END;
")"

log_section "Step 5. Go integration tests (optional)"
if [[ "${RUN_GO_TESTS}" == "1" ]]; then
  (cd "${LEDGER_DIR}" && LEDGER_DB_DSN="${LEDGER_DB_DSN}" go test ./... -count=1)
  echo "Go tests: OK"
else
  echo "RUN_GO_TESTS=0, skipping go test"
fi

chain_ok_post=""
risk_status_post=""
post_go_delta="SKIPPED"
if [[ "${RUN_GO_TESTS}" == "1" && "${POST_GO_AUDIT}" == "1" ]]; then
  log_section "Step 6. Audits (post-Go) and delta"

  echo
  echo "[audit] verify_event_chain() (scalar) post-Go"
  chain_ok_post="$(psql_scalar "SELECT public.verify_event_chain();")"
  echo "${chain_ok_post}" | tee "${AUDIT_CHAIN_POST}"

  echo
  echo "[audit] event_log_totals (public.event_log) post-Go"
  audit_event_log_totals "${AUDIT_EVENTS_POST}"

  echo
  echo "[audit] risk proofs: persisted counts (snapshots vs events) post-Go"
  audit_risk_proofs_persisted_counts "${AUDIT_PROOFS_COUNTS_POST}"

  risk_status_post="$("${PSQL_AT[@]}" -c "
WITH snaps AS (
  SELECT snapshot_id AS sid, 'VALUATION_SNAPSHOT'::text AS et
  FROM public.valuation_snapshot
  UNION ALL
  SELECT snapshot_id AS sid, 'LIQUIDITY_SNAPSHOT'::text AS et
  FROM public.liquidity_snapshot
),
proofs AS (
  SELECT s.sid, s.et, count(e.*) AS n
  FROM snaps s
  LEFT JOIN public.event_log e
    ON e.aggregate_id = s.sid
   AND e.event_type   = s.et
  GROUP BY s.sid, s.et
),
agg AS (
  SELECT
    count(*) AS snapshots,
    sum(CASE WHEN n = 1 THEN 1 ELSE 0 END) AS ok_1,
    sum(CASE WHEN n = 0 THEN 1 ELSE 0 END) AS missing,
    sum(CASE WHEN n > 1 THEN 1 ELSE 0 END) AS dup
  FROM proofs
)
SELECT CASE
  WHEN (SELECT snapshots FROM agg)=0 THEN 'OK: no snapshots'
  WHEN (SELECT missing FROM agg)>0 THEN 'WARN: snapshots present but missing proofs'
  WHEN (SELECT dup FROM agg)>0 THEN 'WARN: duplicate proofs for some snapshots'
  WHEN (SELECT ok_1 FROM agg)=(SELECT snapshots FROM agg) THEN 'OK: 1:1 proofs'
  ELSE 'WARN: partial proofs'
END;
  ")"

  echo
  echo "[diag] after go test: diff event_log_totals pre vs post"
  if diff -u "${AUDIT_EVENTS_PRE}" "${AUDIT_EVENTS_POST}" >"${AUDIT_EVENTS_DIFF}"; then
    post_go_delta="UNCHANGED"
    echo "event_log_totals delta: UNCHANGED"
  else
    post_go_delta="CHANGED"
    echo "event_log_totals delta: CHANGED (see ${AUDIT_EVENTS_DIFF})"
    cat "${AUDIT_EVENTS_DIFF}"
  fi
fi

log_section "Step 7. Summary"
{
  echo "GENESIS SUMMARY"
  echo "ts=${TS}"
  echo "dsn=${LEDGER_DB_DSN}"
  echo
  echo "chain_ok_pre_go=${chain_ok_pre}"
  if [[ -n "${chain_ok_post}" ]]; then
    echo "chain_ok_post_go=${chain_ok_post}"
  fi
  echo "risk_proofs_status_pre_go=${risk_status_pre}"
  if [[ -n "${risk_status_post}" ]]; then
    echo "risk_proofs_status_post_go=${risk_status_post}"
  fi
  echo "post_go_delta=${post_go_delta}"
  echo
  echo "event_log_totals_pre_go:"
  cat "${AUDIT_EVENTS_PRE}"
  echo
  if [[ -f "${AUDIT_EVENTS_POST}" ]]; then
    echo "event_log_totals_post_go:"
    cat "${AUDIT_EVENTS_POST}"
    echo
  fi
  echo
  echo "risk_proofs:"
  cat "${AUDIT_PROOFS}"
  echo
  echo "risk_proofs_persisted_counts_pre_go:"
  cat "${AUDIT_PROOFS_COUNTS}"
  echo
  if [[ -f "${AUDIT_PROOFS_COUNTS_POST}" ]]; then
    echo "risk_proofs_persisted_counts_post_go:"
    cat "${AUDIT_PROOFS_COUNTS_POST}"
    echo
  fi
  if [[ "${DIAG_TRIGGERS}" == "1" ]]; then
    echo "diag_triggers:"
    cat "${AUDIT_DIAG_TRIGGERS}"
    echo
  fi
  echo "artifacts:"
  echo "  - ${LOG}"
  echo "  - ${AUDIT_CHAIN}"
  echo "  - ${AUDIT_EVENTS_PRE}"
  echo "  - ${AUDIT_PROOFS}"
  echo "  - ${AUDIT_PROOFS_COUNTS}"
  if [[ -f "${AUDIT_CHAIN_POST}" ]]; then
    echo "  - ${AUDIT_CHAIN_POST}"
  fi
  if [[ -f "${AUDIT_EVENTS_POST}" ]]; then
    echo "  - ${AUDIT_EVENTS_POST}"
    echo "  - ${AUDIT_EVENTS_DIFF}"
  fi
  if [[ -f "${AUDIT_PROOFS_COUNTS_POST}" ]]; then
    echo "  - ${AUDIT_PROOFS_COUNTS_POST}"
  fi
  if [[ "${DIAG_TRIGGERS}" == "1" ]]; then
    echo "  - ${AUDIT_DIAG_TRIGGERS}"
  fi
} | tee "${SUMMARY}"

log_section "DONE"
echo "Artifacts written to: ${OUT_DIR}"
ls -1 "${OUT_DIR}" | grep "^genesis-${TS}" | sed 's/^/  - /'
