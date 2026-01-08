#!/usr/bin/env bash
set -euo pipefail

export PSQL_PAGER=cat
export PSQLRC=/dev/null

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="${ROOT_DIR}/infra"

# Auto-detect core-ledger location (supports your monorepo layout)
if [ -z "${LEDGER_DIR:-}" ]; then
  if [ -d "${ROOT_DIR}/core-ledger" ]; then
    LEDGER_DIR="${ROOT_DIR}/core-ledger"
  elif [ -d "${ROOT_DIR}/../community-bank-platform/core-ledger" ]; then
    LEDGER_DIR="${ROOT_DIR}/../community-bank-platform/core-ledger"
  else
    echo "E2E FAILED: core-ledger not found. Set LEDGER_DIR explicitly." >&2
    exit 1
  fi
fi
LEDGER_DIR="$(cd "$LEDGER_DIR" && pwd)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need curl
need jq
need go
need psql
need lsof
need python3

LOG_FILE="/tmp/core-ledger.log"

# Config is owned by sandbox/env.sh (or caller). No autodetect. No defaults.
: "${POSTGRES_HOST:?POSTGRES_HOST required}"
: "${POSTGRES_PORT:?POSTGRES_PORT required}"
: "${POSTGRES_DB:?POSTGRES_DB required}"
: "${LEDGER_DB_DSN:?missing LEDGER_DB_DSN}"
: "${LEDGER_DB_DSN_APP:?missing LEDGER_DB_DSN_APP}"

export LEDGER_HTTP_ADDR="${LEDGER_HTTP_ADDR:-:8080}"
E2E_SKIP_SERVER="${E2E_SKIP_SERVER:-0}"

# Derive URL from addr if user didn't override
if [ -z "${LEDGER_URL:-}" ]; then
  if [[ "$LEDGER_HTTP_ADDR" == :* ]]; then
    LEDGER_URL="http://localhost${LEDGER_HTTP_ADDR}"
  else
    LEDGER_URL="http://${LEDGER_HTTP_ADDR}"
  fi
fi

fail() {
  echo "E2E FAILED: $*" >&2
  echo "---- ${LOG_FILE} (tail) ----" >&2
  tail -n 200 "${LOG_FILE}" 2>/dev/null || true
  exit 1
}

psql_admin_tac() {
  local sql="$1"
  psql "$LEDGER_DB_DSN" -X -P pager=off -v ON_ERROR_STOP=1 -tAc "$sql"
}

psql_app_tac() {
  local sql="$1"
  psql "$LEDGER_DB_DSN_APP" -X -P pager=off -v ON_ERROR_STOP=1 -tAc "$sql"
}

expect_psql_fail_admin() {
  local sql="$1"
  if psql "$LEDGER_DB_DSN" -X -P pager=off -v ON_ERROR_STOP=1 -c "$sql" >/dev/null 2>&1; then
    fail "expected SQL to fail but it succeeded"
  fi
  echo "  expected failure: ok"
}

uuid_lc() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  python3 - <<'PY'
import uuid
print(str(uuid.uuid4()))
PY
}

# ------------------------------------------------------------
# Infra + server orchestration
#   - E2E_SKIP_SERVER=1: sandbox already started infra+server.
#   - otherwise: e2e_smoke manages infra+server itself.
# ------------------------------------------------------------

SERVER_PID=""
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
BIN_DIR="/tmp/core-ledger-e2e/${RUN_ID}"
BIN="${BIN_DIR}/core-ledger-server"
E2E_OK=0

cleanup() {
  echo
  if [ -n "${SERVER_PID}" ]; then
    echo "[cleanup] stopping core-ledger (pid=$SERVER_PID)"
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
  fi
  if [ "${E2E_KEEP_ARTIFACTS:-0}" = "1" ] || [ "${E2E_OK}" -ne 1 ]; then
    echo "[cleanup] keeping artifacts: ${BIN_DIR:-<none>} and ${LOG_FILE}"
    return 0
  fi
  if [ -n "${BIN_DIR}" ]; then
    rm -rf "${BIN_DIR}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ "${E2E_SKIP_SERVER}" = "1" ]; then
  echo "[1/6] Using existing infra + server (sandbox mode)"
  echo "  Using POSTGRES_HOST=$POSTGRES_HOST"
  echo "  Using POSTGRES_PORT=$POSTGRES_PORT"
  echo "  Using POSTGRES_DB=$POSTGRES_DB"
  echo "  Using LEDGER_DB_DSN(admin)=$LEDGER_DB_DSN"
  echo "  Using LEDGER_DB_DSN_APP(runtime)=$LEDGER_DB_DSN_APP"
  echo "  Using LEDGER_HTTP_ADDR=$LEDGER_HTTP_ADDR"
  echo "  Using LEDGER_URL=$LEDGER_URL"
  echo "  Using LEDGER_DIR=$LEDGER_DIR"

  curl -fsS --max-time 2 "${LEDGER_URL}/healthz" >/dev/null 2>&1 \
    || fail "expected running core-ledger at ${LEDGER_URL}/healthz"
else
  echo "[1/6] Starting infra (docker compose)"
  cd "$INFRA_DIR"

  # Infra env must remain local. Do not auto-create .env here.
  if [ ! -f .env ]; then
    fail "infra .env missing at ${INFRA_DIR}/.env (sandbox must provide it locally)"
  fi

  make up >/dev/null

  echo "  Using POSTGRES_HOST=$POSTGRES_HOST"
  echo "  Using POSTGRES_PORT=$POSTGRES_PORT"
  echo "  Using POSTGRES_DB=$POSTGRES_DB"
  echo "  Using LEDGER_DB_DSN(admin)=$LEDGER_DB_DSN"
  echo "  Using LEDGER_DB_DSN_APP(runtime)=$LEDGER_DB_DSN_APP"
  echo "  Using LEDGER_HTTP_ADDR=$LEDGER_HTTP_ADDR"
  echo "  Using LEDGER_URL=$LEDGER_URL"
  echo "  Using LEDGER_DIR=$LEDGER_DIR"

  # Fail fast if HTTP port is busy
  PORT="${LEDGER_HTTP_ADDR##*:}"
  if lsof -i :"$PORT" >/dev/null 2>&1; then
    echo "Port $PORT already in use:" >&2
    lsof -i :"$PORT" >&2 || true
    fail "cannot start core-ledger, port busy"
  fi

  # Optional: schema fingerprint (auditable). OK to read embedded migration sources.
  if command -v sha256sum >/dev/null 2>&1; then
    if compgen -G "$LEDGER_DIR/internal/store/migrations/*.sql" >/dev/null; then
      echo "  Schema sha256:"
      sha256sum "$LEDGER_DIR/internal/store/migrations/"*.sql | sed 's/^/    /'
    else
      echo "  Schema sha256: <no local migration files found>"
    fi
  fi

  echo "[1.6/6] Running Go tests (concurrency + http mapping)"
  cd "$LEDGER_DIR"
  LEDGER_DB_DSN="$LEDGER_DB_DSN" go test ./internal/store -run TestConcurrent -count=1 || fail "store tests failed"
  go test ./internal/httpapi -run TestHTTPStatusForErr -count=1 || fail "httpapi tests failed"

  echo "[2/6] Starting core-ledger server"
  cd "$LEDGER_DIR"
  : > "${LOG_FILE}"

  redact_dsn_user() { echo "$1" | sed 's#^\(postgres://\)\([^:]*\):.*#\1\2:***@...#'; }
  ms_now() { date +%s%3N; }

  mkdir -p "$BIN_DIR"

  echo "  Run ID:     $RUN_ID"
  echo "  Server DSN: $(redact_dsn_user "$LEDGER_DB_DSN_APP")"
  echo "  HTTP addr:  $LEDGER_HTTP_ADDR"
  echo "  Health URL: ${LEDGER_URL}/healthz"
  echo "  Logs:       $LOG_FILE"
  echo "  Bin:        $BIN"

  BUILD_START="$(ms_now)"
  go build -o "$BIN" ./cmd/server >/dev/null 2>&1 || fail "go build failed"
  BUILD_END="$(ms_now)"
  echo "  Build:      $((BUILD_END - BUILD_START))ms"

  BIN_SHA256=""
  if command -v sha256sum >/dev/null 2>&1; then
    BIN_SHA256="$(sha256sum "$BIN" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    BIN_SHA256="$(shasum -a 256 "$BIN" | awk '{print $1}')"
  elif command -v openssl >/dev/null 2>&1; then
    BIN_SHA256="$(openssl dgst -sha256 "$BIN" | awk '{print $2}')"
  else
    BIN_SHA256="<sha256 unavailable>"
  fi
  echo "  Bin sha256: $BIN_SHA256"

  RUN_START="$(ms_now)"
  LEDGER_DB_DSN="$LEDGER_DB_DSN_APP" LEDGER_DB_MIGRATE=1 LEDGER_HTTP_ADDR="$LEDGER_HTTP_ADDR" \
    "$BIN" >"${LOG_FILE}" 2>&1 &
  SERVER_PID=$!
  echo "  PID:        $SERVER_PID"

  READY=0
  for _ in {1..120}; do
    if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      fail "core-ledger process exited early"
    fi
    if curl -fsS --max-time 1 "${LEDGER_URL}/healthz" >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 0.25
  done
  [ "$READY" -eq 1 ] || fail "core-ledger did not become healthy at ${LEDGER_URL}/healthz"

  RUN_END="$(ms_now)"
  echo "  Ready:      $((RUN_END - RUN_START))ms"
fi

# ---------- HTTP helpers ----------

curl_json() {
  local method="$1" url="$2" body="$3"
  shift 3
  curl -sS --fail-with-body --max-time 5 \
    -X "$method" "$url" \
    -H 'Content-Type: application/json' \
    "$@" \
    -d "$body"
}

post_with_code() {
  local url="$1" body="$2"
  curl -sS --max-time 5 -X POST "$url" \
    -H 'Content-Type: application/json' \
    -w $'\n%{http_code}' \
    -d "$body"
}

create_account() {
  local label="$1"
  local resp id
  resp="$(curl_json POST "${LEDGER_URL}/v1/accounts" \
    "{\"label\":\"${label}\",\"currency\":\"EUR\"}" \
    -H 'X-Correlation-Id: e2e-1' \
  )" || {
    echo "Create account HTTP failed for label=$label. Body:" >&2
    echo "${resp:-<no body>}" >&2
    fail "account creation http failed"
  }

  id="$(echo "$resp" | jq -r '.account_id // empty' 2>/dev/null || true)"
  if [ -z "$id" ] || [ "$id" = "null" ]; then
    echo "Create account missing account_id for label=$label. Response:" >&2
    echo "$resp" >&2
    fail "account creation returned no account_id"
  fi
  echo "$id"
}

post_transfer() {
  local from="$1" to="$2" amt="$3" cur="$4" ext="$5" idem="$6" corr="$7"
  local payload
  payload="$(cat <<JSON
{
  "from_account_id":"$from",
  "to_account_id":"$to",
  "amount_cents":$amt,
  "currency":"$cur",
  "external_ref":"$ext",
  "idempotency_key":"$idem",
  "correlation_id":"$corr"
}
JSON
)"
  post_with_code "${LEDGER_URL}/v1/transfers" "$payload"
}

expect_transfer_ok() {
  local code="$1" body="$2" tx
  if [[ "$code" != "200" && "$code" != "201" ]]; then
    echo "Transfer failed. HTTP $code. Body:" >&2
    echo "$body" >&2
    fail "transfer http not ok"
  fi
  tx="$(echo "$body" | jq -r '.tx_id // empty' 2>/dev/null || true)"
  if [ -z "$tx" ] || [ "$tx" = "null" ]; then
    echo "Transfer ok HTTP $code but missing tx_id. Body:" >&2
    echo "$body" >&2
    fail "missing tx_id"
  fi
  echo "$tx"
}

expect_transfer_http() {
  local want="$1" code="$2" body="$3"
  if [ "$code" != "$want" ]; then
    echo "Expected HTTP $want, got $code. Body:" >&2
    echo "$body" >&2
    fail "unexpected http code"
  fi
}

echo "[3/6] Creating accounts"
ALICE="$(create_account "Alice")"
BOB="$(create_account "Bob")"
SYS="$(create_account "SYSTEM")"
echo "  Alice=$ALICE"
echo "  Bob=$BOB"
echo "  System=$SYS"

echo "[4/6] Mint 10000 cents to Alice"
MINT_KEY="idem-mint-$(date +%s)"
RESP="$(post_transfer "$SYS" "$ALICE" 10000 "EUR" "mint-$MINT_KEY" "$MINT_KEY" "e2e-1")"
CODE="$(echo "$RESP" | tail -n1)"
BODY="$(echo "$RESP" | sed '$d')"
_="$(expect_transfer_ok "$CODE" "$BODY")"

echo "[5/6] Transfer 2500 cents Alice -> Bob"
PMT_KEY="idem-pmt-$(date +%s)"

RESP1="$(post_transfer "$ALICE" "$BOB" 2500 "EUR" "pmt-$PMT_KEY" "$PMT_KEY" "e2e-1")"
CODE1="$(echo "$RESP1" | tail -n1)"
BODY1="$(echo "$RESP1" | sed '$d')"
TX1="$(expect_transfer_ok "$CODE1" "$BODY1")"

echo "[5.1/6] Idempotency replay should return same tx_id"
RESP2="$(post_transfer "$ALICE" "$BOB" 2500 "EUR" "pmt-$PMT_KEY" "$PMT_KEY" "e2e-1")"
CODE2="$(echo "$RESP2" | tail -n1)"
BODY2="$(echo "$RESP2" | sed '$d')"
TX2="$(expect_transfer_ok "$CODE2" "$BODY2")"

if [ "$TX1" != "$TX2" ]; then
  echo "Replay mismatch. TX1=$TX1 TX2=$TX2" >&2
  echo "Replay body:" >&2
  echo "$BODY2" >&2
  fail "idempotency replay returned different tx_id"
fi

echo "[5.2/6] Idempotency conflict should be rejected"
RESP3="$(post_transfer "$ALICE" "$BOB" 2501 "EUR" "pmt-$PMT_KEY" "$PMT_KEY" "e2e-1")"
CODE3="$(echo "$RESP3" | tail -n1)"
BODY3="$(echo "$RESP3" | sed '$d')"
expect_transfer_http "409" "$CODE3" "$BODY3"

# =========================
# Evil tests MUST run as ledger_app (not admin)
# =========================
echo "[5.3/6] Evil: ledger_app cannot bypass triggers via session_replication_role"
tmp_err="$(mktemp)"
tmp_out="$(mktemp)"
trap 'rm -f "$tmp_err" "$tmp_out"' RETURN

if psql "$LEDGER_DB_DSN_APP" -X -P pager=off -v ON_ERROR_STOP=1 \
    -c "SET session_replication_role = replica;" >"$tmp_out" 2>"$tmp_err"; then
  echo "FAIL: ledger_app could set session_replication_role" >&2
  cat "$tmp_out" >&2 || true
  exit 1
fi
grep -Eqi "permission denied|must be superuser|not permitted" "$tmp_err" || {
  echo "FAIL: unexpected error when setting session_replication_role" >&2
  cat "$tmp_err" >&2
  exit 1
}
echo "  expected failure: ok"

echo "[5.4/6] Evil: idempotency direct UPDATE must fail (ledger_app)"
if psql "$LEDGER_DB_DSN_APP" -X -P pager=off -v ON_ERROR_STOP=1 \
    -c "UPDATE idempotency SET status='COMMITTED' WHERE 1=0;" >/dev/null 2>&1; then
  fail "UPDATE idempotency unexpectedly succeeded as ledger_app"
fi
echo "  expected failure: ok"

echo "[5.5/6] Evil: append-only tables must reject UPDATE (ledger_app)"
if psql "$LEDGER_DB_DSN_APP" -X -P pager=off -v ON_ERROR_STOP=1 \
    -c "UPDATE event_log SET event_type = event_type WHERE 1=0;" >/dev/null 2>&1; then
  fail "UPDATE event_log unexpectedly succeeded as ledger_app"
fi
echo "  expected failure: ok"

echo "[6/6] Checking balances"
BAL_A="$(curl -sS "${LEDGER_URL}/v1/accounts/$ALICE/balance" | jq -r .balance_cents)"
BAL_B="$(curl -sS "${LEDGER_URL}/v1/accounts/$BOB/balance" | jq -r .balance_cents)"
echo "  Alice balance_cents=$BAL_A (expected 7500)"
echo "  Bob   balance_cents=$BAL_B (expected 2500)"
if [ "$BAL_A" != "7500" ] || [ "$BAL_B" != "2500" ]; then
  fail "unexpected balances"
fi

# =========================
# Weapon-grade DB checks (admin role)
# =========================

echo "[6.5/6] Verifying database-enforced double-entry invariant"
UNBAL_TX="$(uuid_lc)"
UNBAL_ENTRY="$(uuid_lc)"
expect_psql_fail_admin "BEGIN;
  INSERT INTO ledger_tx(tx_id, external_ref, correlation_id, idempotency_key)
    VALUES('$UNBAL_TX','e2e-unbal-$UNBAL_TX','e2e-1','e2e-unbal-$UNBAL_TX');
  INSERT INTO ledger_entry(entry_id, tx_id, account_id, direction, amount_cents, currency)
    VALUES('$UNBAL_ENTRY','$UNBAL_TX','$ALICE','DEBIT',123,'EUR');
COMMIT;"

echo "[6.6/6] Verifying append-only enforcement at database level"
expect_psql_fail_admin "UPDATE ledger_entry SET amount_cents = amount_cents + 1;"
expect_psql_fail_admin "DELETE FROM event_log;"

echo "[6.6.1] Double-entry invariant per tx (admin proof)"
psql_admin_tac \
  "SELECT e.tx_id||' debits='||
          sum(CASE WHEN e.direction='DEBIT'  THEN e.amount_cents ELSE 0 END)
          ||' credits='||
          sum(CASE WHEN e.direction='CREDIT' THEN e.amount_cents ELSE 0 END)
   FROM ledger_entry e
   GROUP BY e.tx_id
   ORDER BY e.tx_id
   LIMIT 20;" | sed 's/^/  /'

echo "[6.6.2] DB counts (admin proof)"
psql_admin_tac \
  "SELECT 'accounts='||(SELECT count(*) FROM accounts)
        ||' tx='||(SELECT count(*) FROM ledger_tx)
        ||' entries='||(SELECT count(*) FROM ledger_entry)
        ||' events='||(SELECT count(*) FROM event_log);" | sed 's/^/  /'

echo "[6.7/6] Verifying tamper-evident audit chain (admin)"
psql_admin_tac "SELECT verify_event_chain();" | grep -qx "t" || fail "event chain verification failed"

# =========================
# RFC 8785 payload canonical proofs (admin)
# =========================

echo "[6.7.1/6] Verifying RFC 8785 payload canonical invariants (admin)"
BAD_CANON="$(psql_admin_tac "
SELECT count(*)
FROM event_log
WHERE payload_canonical IS NULL
   OR length(btrim(payload_canonical)) = 0
   OR payload_canonical::jsonb <> payload_json;
")"
echo "  bad_payload_canonical_rows=$BAD_CANON"
[ "$BAD_CANON" = "0" ] || fail "payload_canonical invariants failed (bad_rows=$BAD_CANON)"

echo "[6.7.2/6] Verifying payload_hash is sha256(payload_canonical) (admin)"
BAD_PHASH="$(psql_admin_tac "
SELECT count(*)
FROM event_log
WHERE payload_hash <> digest(convert_to(payload_canonical,'UTF8'),'sha256');
")"
echo "  bad_payload_hash_rows=$BAD_PHASH"
[ "$BAD_PHASH" = "0" ] || fail "payload_hash mismatch vs payload_canonical (bad_rows=$BAD_PHASH)"

echo "[6.7.3/6] Exporting deterministic payload fingerprint (admin)"
FP_FILE="/tmp/e2e_payload_fingerprint_${RUN_ID}.csv"
psql_admin_tac "
COPY (
  SELECT
    seq,
    encode(payload_hash,'hex') AS payload_hash_hex,
    payload_canonical
  FROM event_log
  ORDER BY seq
) TO STDOUT WITH (FORMAT csv, HEADER true);
" > "$FP_FILE"
echo "  fingerprint_file=$FP_FILE"
if command -v sha256sum >/dev/null 2>&1; then
  echo "  fingerprint_sha256=$(sha256sum "$FP_FILE" | awk '{print $1}')"
fi

echo "  audit_proof_summary:"
psql_admin_tac \
  "SELECT 'verify='||verify_event_chain()
        ||' count='||(SELECT count(*) FROM event_log)
        ||' height='||(SELECT COALESCE(max(seq),0) FROM event_log);" | sed 's/^/    /'

psql_admin_tac \
  "SELECT 'head_seq='||seq
        ||' head_hash='||encode(hash,'hex')
        ||' head_created_at='||to_char(created_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')
   FROM event_log
   ORDER BY seq DESC
   LIMIT 1;" | sed 's/^/    /'

# =========================
# Least-privilege proofs (runtime role)
# =========================

echo "[6.8/6] Verifying DB least-privilege for ledger_app (privileges)"

psql_app_tac "SELECT has_table_privilege('ledger_app','accounts','UPDATE');" | grep -qx "f" \
  || fail "ledger_app unexpectedly has UPDATE on accounts"

psql_app_tac "SELECT has_table_privilege('ledger_app','accounts','DELETE');" | grep -qx "f" \
  || fail "ledger_app unexpectedly has DELETE on accounts"

psql_app_tac "SELECT has_table_privilege('ledger_app','ledger_entry','UPDATE');" | grep -qx "f" \
  || fail "ledger_app unexpectedly has UPDATE on ledger_entry"

psql_app_tac "SELECT has_table_privilege('ledger_app','event_log','DELETE');" | grep -qx "f" \
  || fail "ledger_app unexpectedly has DELETE on event_log"

psql_app_tac "SELECT has_table_privilege('ledger_app','event_log','SELECT');" | grep -qx "f" \
  || fail "ledger_app unexpectedly has SELECT on event_log"

# =========================
# DB proof summary (admin)
# =========================

echo "[6.9/6] DB proof summary (admin)"
psql_admin_tac "SELECT count(*) FROM accounts;" | sed 's/^/  accounts: /'
psql_admin_tac "SELECT count(*) FROM ledger_tx;" | sed 's/^/  ledger_tx: /'
psql_admin_tac "SELECT count(*) FROM ledger_entry;" | sed 's/^/  ledger_entry: /'
psql_admin_tac "SELECT count(*) FROM event_log;" | sed 's/^/  event_log: /'

echo "  sample ledger_tx:"
psql_admin_tac \
  "SELECT tx_id||' '||external_ref||' '||idempotency_key||' '||to_char(created_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')
   FROM ledger_tx
   ORDER BY created_at DESC
   LIMIT 5;" | sed 's/^/    /'

E2E_OK=1
echo "E2E OK"
