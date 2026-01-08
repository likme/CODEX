#!/usr/bin/env bash
set -euo pipefail

# retail_30d synthetic scenario with two customer types:
# - PREPAID: cannot go below 0 (wallet-like). Transfers are skipped if insufficient funds.
# - OVERDRAFT: allowed to go negative down to -OVERDRAFT_LIMIT_CENTS (checking-like).
#
# Deterministic by SEED. Uses the same HTTP API as e2e_smoke.sh.

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need curl
need jq
need python3
need sha256sum

: "${LEDGER_URL:?missing LEDGER_URL}"

SEED="${SEED:-42}"
DAYS="${DAYS:-30}"
ACCOUNTS="${ACCOUNTS:-1000}"

# Mix of customer types
PREPAID_RATIO="${PREPAID_RATIO:-0.70}"              # 0..1 fraction of customers that are prepaid
OVERDRAFT_LIMIT_CENTS="${OVERDRAFT_LIMIT_CENTS:-50000}"  # overdraft floor is -limit (e.g. 50000 => -500.00)

# Behavior knobs
DAILY_DEPOSIT_PROB="${DAILY_DEPOSIT_PROB:-0.02}"
DAILY_TRANSFER_FACTOR="${DAILY_TRANSFER_FACTOR:-0.01}"   # transfers per day ~= accounts * factor
MIN_AMOUNT_CENTS="${MIN_AMOUNT_CENTS:-100}"
MAX_AMOUNT_CENTS="${MAX_AMOUNT_CENTS:-500000}"

CURRENCY="${CURRENCY:-EUR}"
IDEM_PREFIX="${IDEM_PREFIX:-retail30d}"

# Test knobs
IDEMPOTENCE_SAMPLE="${IDEMPOTENCE_SAMPLE:-25}"
VERBOSE="${VERBOSE:-0}"

# Optional output directory injected by replay.sh
OUT_DIR="${OUT_DIR:-}"

ts_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { local lvl="$1"; shift; printf '%s %-5s %s\n' "$(ts_utc)" "$lvl" "$*" >&2; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
dbg() { if [ "$VERBOSE" = "1" ]; then log DEBUG "$@"; fi; }
die() { log ERROR "$*"; exit 1; }

cleanup() { [ -n "${TMPDIR:-}" ] && rm -rf "$TMPDIR" || true; }
trap cleanup EXIT
TMPDIR="$(mktemp -d)"

# ---------- HTTP helpers ----------

curl_json() {
  local method="$1" url="$2" payload="$3"
  curl -sS -X "$method" -H 'content-type: application/json' --data "$payload" "$url"
}

post_with_code_time() {
  # stdout: body + "\n<http_code> <time_total_seconds>"
  local url="$1" payload="$2"
  local bodyf="${TMPDIR}/body.$RANDOM"
  local meta
  meta="$(
    curl -sS -o "$bodyf" -w "%{http_code} %{time_total}" \
      -X POST -H 'content-type: application/json' \
      --data "$payload" \
      "$url"
  )" || return 1
  cat "$bodyf"
  printf '\n%s\n' "$meta"
}

expect_transfer_ok() {
  # prints tx id if present else "ok"
  local code="$1" body="$2"

  if [ "$code" != "200" ] && [ "$code" != "201" ]; then
    echo "$body" >&2
    die "transfer failed http=$code"
  fi

  local tx
  tx="$(echo "$body" | jq -r '
    .tx_id
    // .id
    // .transaction_id
    // .ledger_tx_id
    // .transfer_id
    // .tx?.id
    // .transfer?.id
    // empty
  ' 2>/dev/null || true)"

  if [ -z "$tx" ] || [ "$tx" = "null" ]; then
    printf '%s\n' "ok"
    return 0
  fi

  printf '%s\n' "$tx"
}

# ---------- domain helpers ----------

create_account() {
  local label="$1"
  local resp account_id payload
  payload="$(jq -Rn --arg cur "${CURRENCY}" '{label: input, currency: $cur}' <<<"$label")"
  resp="$(curl_json POST "${LEDGER_URL}/v1/accounts" "$payload")" || return 1
  account_id="$(echo "$resp" | jq -r '.account_id // empty')"
  [ -n "$account_id" ] || { echo "$resp" >&2; die "create_account failed for label=$label"; }
  printf '%s\n' "$account_id"
}

balance_cents() {
  local account_id="$1"
  curl -sS "${LEDGER_URL}/v1/accounts/${account_id}/balance" | jq -r '.balance_cents'
}

sum_balances() {
  local sum=0 b
  for a in "$@"; do
    b="$(balance_cents "$a")"
    [ "$b" != "null" ] || die "balance null for $a"
    sum=$((sum + b))
  done
  printf '%s\n' "$sum"
}

post_transfer_payload() {
  local from="$1" to="$2" amount="$3" currency="$4" external_ref="$5" idem="$6" corr="$7"
  jq -nc \
    --arg from "$from" \
    --arg to "$to" \
    --arg currency "$currency" \
    --arg external_ref "$external_ref" \
    --arg idempotency_key "$idem" \
    --arg correlation_id "$corr" \
    --argjson amount_cents "$amount" \
    '{from_account_id:$from,to_account_id:$to,amount_cents:$amount_cents,currency:$currency,external_ref:$external_ref,idempotency_key:$idempotency_key,correlation_id:$correlation_id}'
}

do_transfer() {
  local kind="$1" from="$2" to="$3" amount="$4" external_ref="$5" idem="$6" corr="$7"
  local payload resp code tsec body tx ms

  payload="$(post_transfer_payload "$from" "$to" "$amount" "$CURRENCY" "$external_ref" "$idem" "$corr")"

  resp="$(post_with_code_time "${LEDGER_URL}/v1/transfers" "$payload")"
  code="$(echo "$resp" | tail -n1 | awk '{print $1}')"
  tsec="$(echo "$resp" | tail -n1 | awk '{print $2}')"
  body="$(echo "$resp" | sed '$d')"

  tx="$(expect_transfer_ok "$code" "$body")"

  ms="$(python3 - <<PY
t=float("${tsec}")
print(int(round(t*1000)))
PY
)"

  echo -e "${kind}\t${code}\t${ms}" >> "${TMPDIR}/latency.tsv"

  if [ "$VERBOSE" = "1" ]; then
    dbg "POST /v1/transfers kind=${kind} code=${code} ms=${ms} amount=${amount} from=${from:0:8} to=${to:0:8} idem=${idem}"
  fi

  echo "$payload" >> "${TMPDIR}/executed_payloads.jsonl"
  printf '%s\n' "$tx"
}

percentile_ms() {
  # percentile_ms <p> from TMPDIR/latency.tsv 3rd col
  local p="$1"
  python3 - "$p" "${TMPDIR}/latency.tsv" <<'PY'
import math, sys

p = float(sys.argv[1])
path = sys.argv[2]

xs = []
with open(path, "r", encoding="utf-8") as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3:
            try:
                xs.append(int(parts[2]))
            except ValueError:
                pass

xs.sort()
if not xs:
    print("0")
    raise SystemExit

k = int(math.ceil((p/100.0) * len(xs)) - 1)
k = max(0, min(len(xs)-1, k))
print(xs[k])
PY
}


sha256_file() { sha256sum "$1" | awk '{print $1}'; }

# ---------- start ----------

info "Scenario retail_30d starting"
info "LEDGER_URL=${LEDGER_URL}"
info "SEED=${SEED} DAYS=${DAYS} ACCOUNTS=${ACCOUNTS} CURRENCY=${CURRENCY}"
info "PREPAID_RATIO=${PREPAID_RATIO} OVERDRAFT_LIMIT_CENTS=${OVERDRAFT_LIMIT_CENTS}"
info "DEPOSIT_PROB=${DAILY_DEPOSIT_PROB} TRANSFER_FACTOR=${DAILY_TRANSFER_FACTOR}"
info "AMOUNT_RANGE=${MIN_AMOUNT_CENTS}..${MAX_AMOUNT_CENTS} IDEM_PREFIX=${IDEM_PREFIX}"
info "IDEMPOTENCE_SAMPLE=${IDEMPOTENCE_SAMPLE} VERBOSE=${VERBOSE}"

[ -z "$OUT_DIR" ] || { mkdir -p "$OUT_DIR"; info "OUT_DIR=${OUT_DIR}"; }

# Accounts
info "Creating ${ACCOUNTS} customer accounts"
declare -a ACC=()
declare -a TYPE=()   # PREPAID | OVERDRAFT

for i in $(seq 0 $((ACCOUNTS-1))); do
  ACC+=("$(create_account "Customer-$(printf '%05d' "$i")")")
done

FUNDING="$(create_account "FundingPool")"
SYS="$(create_account "SYSTEM")"
info "Accounts created. funding=${FUNDING} system=${SYS}"

# Assign customer types deterministically
python3 - <<PY > "${TMPDIR}/types.txt"
import os, random
seed=int(os.environ.get("SEED","42"))
n=int(os.environ.get("ACCOUNTS","1000"))
ratio=float(os.environ.get("PREPAID_RATIO","0.70"))
rng=random.Random(seed + 99991)
for i in range(n):
    t="PREPAID" if rng.random() < ratio else "OVERDRAFT"
    print(t)
PY

i=0
while IFS= read -r t; do
  TYPE[$i]="$t"
  i=$((i+1))
done < "${TMPDIR}/types.txt"

# Bootstrap funding (initial mint)
BOOT_KEY="${IDEM_PREFIX}:bootstrap"
BOOT_AMT=100000000
_="$(do_transfer "BOOT" "$SYS" "$FUNDING" "$BOOT_AMT" "bootstrap-${BOOT_KEY}" "${BOOT_KEY}" "retail-1")" >/dev/null
info "Bootstrap funding ok"

# Plan generation (deterministic)
PLAN="$(mktemp)"
SEED="$SEED" DAYS="$DAYS" ACCOUNTS="$ACCOUNTS" \
DAILY_DEPOSIT_PROB="$DAILY_DEPOSIT_PROB" DAILY_TRANSFER_FACTOR="$DAILY_TRANSFER_FACTOR" \
MIN_AMOUNT_CENTS="$MIN_AMOUNT_CENTS" MAX_AMOUNT_CENTS="$MAX_AMOUNT_CENTS" \
python3 - <<PY >"$PLAN"
import random, os
seed=int(os.environ["SEED"]); days=int(os.environ["DAYS"]); accounts=int(os.environ["ACCOUNTS"])
p_dep=float(os.environ["DAILY_DEPOSIT_PROB"]); tf=float(os.environ["DAILY_TRANSFER_FACTOR"])
min_amt=int(os.environ["MIN_AMOUNT_CENTS"]); max_amt=int(os.environ["MAX_AMOUNT_CENTS"])
rng=random.Random(seed)

for day in range(days):
    mint_amt=rng.randint(min_amt*100, max_amt*10)
    print(f"MINT {mint_amt} day:{day}")

    for i in range(accounts):
        if rng.random() < p_dep:
            amt=rng.randint(min_amt, max_amt)
            print(f"DEP {i} {amt} dep:{day}:{i}")

    n_xfer=int(accounts*tf)
    for _ in range(n_xfer):
        a=rng.randrange(accounts); b=rng.randrange(accounts)
        if a==b: continue
        amt=rng.randint(min_amt, max_amt//10 if max_amt>=10 else max_amt)
        print(f"XFER {a} {b} {amt} xfer:{day}:{a}:{b}:{amt}")
PY

PLAN_HASH="$(sha256_file "$PLAN")"
[ -z "$OUT_DIR" ] || cp -f "$PLAN" "${OUT_DIR}/plan.txt"
[ -z "$OUT_DIR" ] || cp -f "${TMPDIR}/types.txt" "${OUT_DIR}/customer_types.txt"
info "Executing plan: ${PLAN} (sha256=${PLAN_HASH})"

CNT_MINT=0
CNT_DEP=0
CNT_XFER=0
SKIP_XFER=0
MINT_TOTAL="$BOOT_AMT"

# Execute plan
while read -r kind a b c d; do
  [ -z "${kind:-}" ] && continue
  case "$kind" in
    MINT)
      amt="$a"; tag="$b"
      idem="${IDEM_PREFIX}:mint:${tag}"
      _="$(do_transfer "MINT" "$SYS" "$FUNDING" "$amt" "mint-${idem}" "$idem" "retail-1")" >/dev/null
      CNT_MINT=$((CNT_MINT+1))
      MINT_TOTAL=$((MINT_TOTAL + amt))
      ;;
    DEP)
      idx="$a"; amt="$b"; tag="$c"
      idem="${IDEM_PREFIX}:dep:${tag}"
      _="$(do_transfer "DEP" "$FUNDING" "${ACC[$idx]}" "$amt" "dep-${idem}" "$idem" "retail-1")" >/dev/null
      CNT_DEP=$((CNT_DEP+1))
      ;;
    XFER)
      ia="$a"; ib="$b"; amt="$c"; tag="$d"
      idem="${IDEM_PREFIX}:xfer:${tag}"

      t="${TYPE[$ia]}"

      if [ "$t" = "PREPAID" ]; then
        bal_a="$(balance_cents "${ACC[$ia]}")"
        if [ "$bal_a" -lt "$amt" ]; then
          SKIP_XFER=$((SKIP_XFER+1))
          [ "$VERBOSE" = "1" ] && dbg "SKIP XFER prepaid insufficient ia=$ia bal=$bal_a amt=$amt"
          continue
        fi
      else
        # OVERDRAFT: enforce floor = -OVERDRAFT_LIMIT_CENTS
        bal_a="$(balance_cents "${ACC[$ia]}")"
        floor=$(( -OVERDRAFT_LIMIT_CENTS ))
        if [ $((bal_a - amt)) -lt "$floor" ]; then
          SKIP_XFER=$((SKIP_XFER+1))
          [ "$VERBOSE" = "1" ] && dbg "SKIP XFER overdraft floor ia=$ia bal=$bal_a amt=$amt floor=$floor"
          continue
        fi
      fi

      _="$(do_transfer "XFER" "${ACC[$ia]}" "${ACC[$ib]}" "$amt" "xfer-${idem}" "$idem" "retail-1")" >/dev/null
      CNT_XFER=$((CNT_XFER+1))
      ;;
    *)
      die "unknown plan line: $kind"
      ;;
  esac
done < "$PLAN"

info "Plan executed"
info "Counts: mints=${CNT_MINT} deposits=${CNT_DEP} transfers=${CNT_XFER} skipped_transfers=${SKIP_XFER}"

# ---------- Invariants ----------

# Invariant 1: PREPAID never negative, OVERDRAFT not below floor.
BAD=0
for i in $(seq 0 $((ACCOUNTS-1))); do
  b="$(balance_cents "${ACC[$i]}")"
  t="${TYPE[$i]}"
  if [ "$t" = "PREPAID" ]; then
    if [ "$b" -lt 0 ]; then
      BAD=$((BAD+1))
      warn "invariant fail prepaid negative customer[$i]=${ACC[$i]} bal=${b}"
      [ "$BAD" -ge 10 ] && break
    fi
  else
    floor=$(( -OVERDRAFT_LIMIT_CENTS ))
    if [ "$b" -lt "$floor" ]; then
      BAD=$((BAD+1))
      warn "invariant fail overdraft below floor customer[$i]=${ACC[$i]} bal=${b} floor=${floor}"
      [ "$BAD" -ge 10 ] && break
    fi
  fi
done
[ "$BAD" = "0" ] || die "invariant failed: customer constraints violated count=${BAD}"
info "Invariant ok: prepaid>=0 and overdraft>=-${OVERDRAFT_LIMIT_CENTS}"

# Invariant 2: Conservation outside SYSTEM: sum(all except SYS) == total minted
declare -a NONSYS=()
NONSYS+=("$FUNDING")
for a in "${ACC[@]}"; do NONSYS+=("$a"); done
SUM_NONSYS="$(sum_balances "${NONSYS[@]}")"
if [ "$SUM_NONSYS" -ne "$MINT_TOTAL" ]; then
  die "invariant failed: sum(nonSYS)=${SUM_NONSYS} != minted_total=${MINT_TOTAL}"
fi
info "Invariant ok: conservation (nonSYS) sum=${SUM_NONSYS} minted_total=${MINT_TOTAL}"

# ---------- Idempotence test ----------

SAMPLE_N="$IDEMPOTENCE_SAMPLE"
[ "$SAMPLE_N" -ge 1 ] || SAMPLE_N=1

declare -a MON=()
MON+=("$FUNDING")
for i in $(seq 0 9); do MON+=("${ACC[$i]}"); done

snap_before="$TMPDIR/bal_before.tsv"
snap_after="$TMPDIR/bal_after.tsv"
for a in "${MON[@]}"; do echo -e "${a}\t$(balance_cents "$a")" >> "$snap_before"; done

i=0
while IFS= read -r payload; do
  [ -n "$payload" ] || continue
  resp="$(post_with_code_time "${LEDGER_URL}/v1/transfers" "$payload")"
  code="$(echo "$resp" | tail -n1 | awk '{print $1}')"
  body="$(echo "$resp" | sed '$d')"
  if [ "$code" != "200" ] && [ "$code" != "201" ]; then
    echo "$body" >&2
    die "idempotence replay failed http=$code"
  fi
  i=$((i+1))
  [ "$i" -ge "$SAMPLE_N" ] && break
done < "${TMPDIR}/executed_payloads.jsonl"

for a in "${MON[@]}"; do echo -e "${a}\t$(balance_cents "$a")" >> "$snap_after"; done

if ! diff -u "$snap_before" "$snap_after" >/dev/null 2>&1; then
  warn "balances changed after idempotence replay (diff below)"
  diff -u "$snap_before" "$snap_after" >&2 || true
  die "idempotence invariant failed: balances changed"
fi
info "Idempotence ok: replay(${SAMPLE_N}) did not change monitored balances"

# ---------- Metrics + summary ----------

P50="$(percentile_ms 50)"
P95="$(percentile_ms 95)"

A0="${ACC[0]}"; B0="${ACC[1]}"
BAL0="$(balance_cents "$A0")"
BAL1="$(balance_cents "$B0")"

info "Latency ms: p50=${P50} p95=${P95}"
info "Sample balances: acc0=${BAL0} acc1=${BAL1}"

FINGERPRINT_INPUT="${TMPDIR}/fingerprint.txt"
{
  echo "scenario=retail_30d"
  echo "ledger_url=${LEDGER_URL}"
  echo "seed=${SEED}"
  echo "days=${DAYS}"
  echo "accounts=${ACCOUNTS}"
  echo "prepaid_ratio=${PREPAID_RATIO}"
  echo "overdraft_limit_cents=${OVERDRAFT_LIMIT_CENTS}"
  echo "currency=${CURRENCY}"
  echo "deposit_prob=${DAILY_DEPOSIT_PROB}"
  echo "transfer_factor=${DAILY_TRANSFER_FACTOR}"
  echo "min_amt=${MIN_AMOUNT_CENTS}"
  echo "max_amt=${MAX_AMOUNT_CENTS}"
  echo "plan_sha256=${PLAN_HASH}"
  echo "counts_mint=${CNT_MINT}"
  echo "counts_dep=${CNT_DEP}"
  echo "counts_xfer=${CNT_XFER}"
  echo "skipped_xfer=${SKIP_XFER}"
  echo "mint_total=${MINT_TOTAL}"
  echo "sum_nonsys=${SUM_NONSYS}"
  echo "lat_p50_ms=${P50}"
  echo "lat_p95_ms=${P95}"
} > "$FINGERPRINT_INPUT"

RUN_FINGERPRINT="$(sha256_file "$FINGERPRINT_INPUT")"
info "Run fingerprint sha256=${RUN_FINGERPRINT}"

if [ -n "$OUT_DIR" ]; then
  cp -f "${TMPDIR}/latency.tsv" "${OUT_DIR}/latency.tsv" || true
  cp -f "$FINGERPRINT_INPUT" "${OUT_DIR}/fingerprint_input.txt" || true
  echo "$RUN_FINGERPRINT" > "${OUT_DIR}/fingerprint.sha256"
  jq -nc \
    --arg scenario "retail_30d" \
    --arg seed "$SEED" \
    --arg days "$DAYS" \
    --arg accounts "$ACCOUNTS" \
    --arg currency "$CURRENCY" \
    --arg plan_sha256 "$PLAN_HASH" \
    --arg fingerprint "$RUN_FINGERPRINT" \
    --arg p50 "$P50" \
    --arg p95 "$P95" \
    --arg prepaid_ratio "$PREPAID_RATIO" \
    --arg overdraft_limit_cents "$OVERDRAFT_LIMIT_CENTS" \
    --arg mints "$CNT_MINT" \
    --arg deps "$CNT_DEP" \
    --arg xfers "$CNT_XFER" \
    --arg skipped "$SKIP_XFER" \
    --arg minted_total "$MINT_TOTAL" \
    --arg sum_nonsys "$SUM_NONSYS" \
    '{scenario:$scenario,seed:$seed,days:$days,accounts:$accounts,currency:$currency,customer_mix:{prepaid_ratio:$prepaid_ratio,overdraft_limit_cents:$overdraft_limit_cents},plan_sha256:$plan_sha256,fingerprint_sha256:$fingerprint,latency_ms:{p50:$p50,p95:$p95},counts:{mints:$mints,deposits:$deps,transfers_executed:$xfers,transfers_skipped:$skipped},minted_total_cents:$minted_total,sum_nonsys_cents:$sum_nonsys}' \
    > "${OUT_DIR}/summary.json"
fi

info "retail_30d OK"
