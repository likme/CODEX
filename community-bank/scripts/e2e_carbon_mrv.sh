#!/usr/bin/env bash
set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need curl
need jq
need python3

: "${LEDGER_URL:?missing LEDGER_URL}"

SEED="${SEED:-1337}"
DAYS="${DAYS:-30}"
ORGS="${ORGS:-500}"
CURRENCY="${CURRENCY:-EUR}"

DAILY_ACTIVITY_PROB="${DAILY_ACTIVITY_PROB:-0.15}"
MIN_KGCO2="${MIN_KGCO2:-1}"
MAX_KGCO2="${MAX_KGCO2:-500}"

IDEM_PREFIX="${IDEM_PREFIX:-carbonmrv}"
VERBOSE="${VERBOSE:-0}"

OUT_DIR="${OUT_DIR:-}"

ts_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { local lvl="$1"; shift; printf '%s %-5s %s\n' "$(ts_utc)" "$lvl" "$*" >&2; }
info() { log INFO "$@"; }
dbg() { if [ "$VERBOSE" = "1" ]; then log DEBUG "$@"; fi; }
die() { log ERROR "$*"; exit 1; }

curl_json() {
  local method="$1" url="$2" payload="$3"
  curl -sS -X "$method" -H 'content-type: application/json' --data "$payload" "$url"
}

post_with_code() {
  local url="$1" payload="$2"
  # stdout: body + "\n<http_code>"
  curl -sS -w "\n%{http_code}" \
    -X POST -H 'content-type: application/json' \
    --data "$payload" \
    "$url"
}

create_account() {
  local label="$1"
  local resp account_id payload

  payload="$(jq -Rn --arg cur "${CURRENCY}" '{label: input, currency: $cur}' <<<"$label")"
  resp="$(curl_json POST "${LEDGER_URL}/v1/accounts" "$payload")" || return 1
  account_id="$(echo "$resp" | jq -r '.account_id // empty')"

  [ -n "$account_id" ] || {
    echo "$resp" >&2
    die "create_account failed for label=$label"
  }
  printf '%s\n' "$account_id"
}

post_transfer() {
  local from="$1" to="$2" amount="$3" currency="$4" external_ref="$5" idem="$6" corr="$7"
  local payload
  payload="$(jq -nc \
    --arg from "$from" --arg to "$to" --arg currency "$currency" \
    --arg external_ref "$external_ref" --arg idempotency_key "$idem" --arg correlation_id "$corr" \
    --argjson amount_cents "$amount" \
    '{from_account_id:$from,to_account_id:$to,amount_cents:$amount_cents,currency:$currency,external_ref:$external_ref,idempotency_key:$idempotency_key,correlation_id:$correlation_id}')"
  post_with_code "${LEDGER_URL}/v1/transfers" "$payload"
}

expect_transfer_ok() {
  local code="$1" body="$2"

  if [ "$code" != "200" ] && [ "$code" != "201" ]; then
    echo "$body" >&2
    die "transfer failed http=$code"
  fi

  # Strict by default. If your API ever changes, expand this like retail.
  local tx
  tx="$(echo "$body" | jq -r '.tx_id // empty' 2>/dev/null || true)"
  if [ -z "$tx" ] || [ "$tx" = "null" ]; then
    echo "$body" >&2
    die "transfer ok but missing tx_id"
  fi
  printf '%s\n' "$tx"
}

info "Scenario carbon_mrv starting"
info "LEDGER_URL=${LEDGER_URL}"
info "SEED=${SEED} DAYS=${DAYS} ORGS=${ORGS} CURRENCY=${CURRENCY}"
info "ACTIVITY_PROB=${DAILY_ACTIVITY_PROB} KG_RANGE=${MIN_KGCO2}..${MAX_KGCO2}"
info "IDEM_PREFIX=${IDEM_PREFIX}"
[ -z "$OUT_DIR" ] || { mkdir -p "$OUT_DIR"; info "OUT_DIR=${OUT_DIR}"; }

# Accounts
SINK="$(create_account "CARBON_SINK")"
SYS="$(create_account "SYSTEM")"
FUNDING="$(create_account "FundingPool")"
info "Accounts created. sink=${SINK} system=${SYS} funding=${FUNDING}"

# Bootstrap funding
BOOT_KEY="${IDEM_PREFIX}:bootstrap"
RESP="$(post_transfer "$SYS" "$FUNDING" 100000000 "EUR" "bootstrap-${BOOT_KEY}" "${BOOT_KEY}" "carbon-1")"
CODE="$(echo "$RESP" | tail -n1)"
BODY="$(echo "$RESP" | sed '$d')"
_="$(expect_transfer_ok "$CODE" "$BODY")" >/dev/null
info "Bootstrap funding ok"

# Orgs + seeding
declare -a ORG=()
for i in $(seq 0 $((ORGS-1))); do
  id="$(create_account "Org-$(printf '%05d' "$i")")"
  ORG+=("$id")
  idem="${IDEM_PREFIX}:seed:${i}"
  RESP="$(post_transfer "$FUNDING" "$id" 10000 "$CURRENCY" "seed-${idem}" "$idem" "carbon-1")"
  CODE="$(echo "$RESP" | tail -n1)"
  BODY="$(echo "$RESP" | sed '$d')"
  _="$(expect_transfer_ok "$CODE" "$BODY")" >/dev/null
done
info "Orgs created and seeded"

# Plan + execute (1 kgCO2 == 1 cent proxy)
PLAN="$(mktemp)"

SEED="$SEED" DAYS="$DAYS" ORGS="$ORGS" \
DAILY_ACTIVITY_PROB="$DAILY_ACTIVITY_PROB" MIN_KGCO2="$MIN_KGCO2" MAX_KGCO2="$MAX_KGCO2" \
python3 - <<PY >"$PLAN"
import random, os
seed=int(os.environ["SEED"]); days=int(os.environ["DAYS"]); orgs=int(os.environ["ORGS"])
p=float(os.environ["DAILY_ACTIVITY_PROB"])
mn=int(os.environ["MIN_KGCO2"]); mx=int(os.environ["MAX_KGCO2"])
rng=random.Random(seed)
for day in range(days):
    for i in range(orgs):
        if rng.random() < p:
            kg=rng.randint(mn,mx)
            print(f"EMIT {i} {kg} emit:{day}:{i}:{kg}")
PY

[ -z "$OUT_DIR" ] || cp -f "$PLAN" "${OUT_DIR}/plan.txt"
info "Executing plan: ${PLAN}"

CNT_EMIT=0
while read -r kind a b c; do
  [ -z "${kind:-}" ] && continue
  case "$kind" in
    EMIT)
      idx="$a"; kg="$b"; tag="$c"
      idem="${IDEM_PREFIX}:emit:${tag}"
      RESP="$(post_transfer "${ORG[$idx]}" "$SINK" "$kg" "$CURRENCY" "emit-${idem}" "$idem" "carbon-1")"
      CODE="$(echo "$RESP" | tail -n1)"
      BODY="$(echo "$RESP" | sed '$d')"
      _="$(expect_transfer_ok "$CODE" "$BODY")" >/dev/null
      CNT_EMIT=$((CNT_EMIT+1))
      ;;
    *)
      die "unknown plan line: $kind"
      ;;
  esac
done < "$PLAN"

info "Emissions posted: ${CNT_EMIT}"
info "carbon_mrv OK"
