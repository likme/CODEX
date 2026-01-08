#!/usr/bin/env bash
set -euo pipefail

# sandbox/check_replay.sh
#
# Professional verification harness for A/B/C1 exports.
#
# - Runs replay N times with RESET_DB=1
# - Validates per-run integrity (sha256 + DB chain verification)
# - Validates cross-run expectations:
#     A  (facts)         MUST be stable across runs
#     C1 (stable proof)  MUST be stable across runs
#     B  (db-proof)      MUST differ across runs (UUID/time variance), but MUST verify per-run
#
# Usage:
#   ./sandbox/check_replay.sh                 # defaults: smoke, 2 runs
#   ./sandbox/check_replay.sh smoke 2
#   SCENARIO=smoke RUNS=2 ./sandbox/check_replay.sh
#
# Verbosity:
#   VERBOSE=1 ./sandbox/check_replay.sh smoke 2
#
# Output:
#   sandbox/out/check/<scenario>/<ts>/
#     run_1.log, run_2.log, ...
#     report.txt
#     report.json
#     report.md
#     env.txt

SCENARIO="${1:-${SCENARIO:-smoke}}"
RUNS="${2:-${RUNS:-2}}"
VERBOSE="${VERBOSE:-0}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/sandbox/env.sh"

CHECK_TS="$(date -u +%Y%m%dT%H%M%SZ)"
CHECK_DIR="${SANDBOX_OUT}/check/${SCENARIO}/${CHECK_TS}"
mkdir -p "${CHECK_DIR}"

ts_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {
  # log <LEVEL> <MESSAGE...>
  local lvl="$1"; shift
  printf '%s %-5s %s\n' "$(ts_utc)" "$lvl" "$*" >&2
}
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
err()  { log ERROR "$@"; }
dbg()  { if [ "$VERBOSE" = "1" ]; then log DEBUG "$@"; fi; }

die() { err "$*"; exit 1; }

need_file() { [ -f "$1" ] || die "Missing file: $1"; }
need_dir()  { [ -d "$1" ] || die "Missing directory: $1"; }

sha256_of_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    die "sha256 tool not found. Install sha256sum (coreutils) or shasum."
  fi
}

read_sha256_file() {
  local f="$1"
  awk '{print $1}' "$f" | tr -d '\r\n'
}

extract_kv() {
  # extract_kv <file> <key> -> value (after '=')
  local f="$1" key="$2"
  grep -E "^${key}=" "$f" | head -n1 | sed -E "s/^${key}=//" | tr -d '\r\n'
}

assert_eq() {
  local a="$1" b="$2" msg="$3"
  if [ "$a" != "$b" ]; then
    err "FAIL: ${msg}"
    err "  left : $a"
    err "  right: $b"
    exit 1
  fi
  info "OK: ${msg}"
}

assert_ne() {
  local a="$1" b="$2" msg="$3"
  if [ "$a" = "$b" ]; then
    err "FAIL: ${msg}"
    err "  both: $a"
    exit 1
  fi
  info "OK: ${msg}"
}

# Write a stable environment snapshot for consulting/audit notes.
{
  echo "timestamp_utc=$(ts_utc)"
  echo "root_dir=${ROOT_DIR}"
  echo "scenario=${SCENARIO}"
  echo "runs=${RUNS}"
  echo "verbose=${VERBOSE}"
  echo "postgres_host=${POSTGRES_HOST:-}"
  echo "postgres_port=${POSTGRES_PORT:-}"
  echo "postgres_db=${POSTGRES_DB:-}"
  echo "ledger_db_dsn_admin=${LEDGER_DB_DSN:-}"
  echo "ledger_url=${LEDGER_URL:-}"
  if command -v git >/dev/null 2>&1; then
    echo "git_commit=$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null || true)"
    echo "git_dirty_count=$(git -C "${ROOT_DIR}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  fi
  echo "host_uname=$(uname -a 2>/dev/null || true)"
} > "${CHECK_DIR}/env.txt"

info "Replay verification starting"
info "ROOT_DIR=${ROOT_DIR}"
info "CHECK_DIR=${CHECK_DIR}"
info "SCENARIO=${SCENARIO}"
info "RUNS=${RUNS}"
[ "$RUNS" -ge 2 ] || die "RUNS must be >= 2"

declare -a OUTS=()

run_replay_once() {
  local idx="$1"
  local logf="${CHECK_DIR}/run_${idx}.log"

  info "Run ${idx}/${RUNS}: executing replay (RESET_DB=1)"
  dbg  "Command: RESET_DB=1 ${ROOT_DIR}/sandbox/replay.sh ${SCENARIO}"
  dbg  "Log file: ${logf}"

  local out rc outdir
  set +e
  out="$(RESET_DB=1 "${ROOT_DIR}/sandbox/replay.sh" "${SCENARIO}" 2>&1 | tee "$logf")"
  rc="${PIPESTATUS[0]}"
  set -e
  [ "$rc" -eq 0 ] || die "Replay failed (run ${idx}). See ${logf}"

  outdir="$(printf '%s\n' "$out" | grep -E '^OK: ' | tail -n1 | sed -E 's/^OK: //')"
  [ -n "$outdir" ] || die "Could not parse outdir from replay output (run ${idx}). See ${logf}"
  need_dir "$outdir"

  info "Run ${idx}/${RUNS}: completed"
  info "Run ${idx}/${RUNS}: OUT_DIR=${outdir}"

  if [ "$VERBOSE" = "1" ]; then
    dbg "Run ${idx}: first lines of proof_summary.txt"
    if [ -f "${outdir}/proof_summary.txt" ]; then
      sed -n '1,10p' "${outdir}/proof_summary.txt" >&2 || true
    fi
  fi

  printf '%s\n' "$outdir"
}

for i in $(seq 1 "$RUNS"); do
  OUTS+=("$(run_replay_once "$i")")
done

info "Per-run validation: integrity and DB chain verification"
for i in "${!OUTS[@]}"; do
  idx=$((i+1))
  d="${OUTS[$i]}"

  info "Validating run ${idx}: ${d}"

  need_file "${d}/proof_summary.txt"
  need_file "${d}/artifacts.txt"

  # Option A
  need_file "${d}/payload_fingerprint_facts.csv"
  need_file "${d}/payload_fingerprint_facts.sha256"

  # Option B
  need_file "${d}/proof_fingerprint.csv"
  need_file "${d}/proof_fingerprint.sha256"

  # Option C1
  need_file "${d}/proof_fingerprint_stable.csv"
  need_file "${d}/proof_fingerprint_stable.sha256"

  # sha checks
  assert_eq "$(sha256_of_file "${d}/payload_fingerprint_facts.csv")" \
            "$(read_sha256_file "${d}/payload_fingerprint_facts.sha256")" \
            "Run ${idx}: Option A sha256 matches file"

  assert_eq "$(sha256_of_file "${d}/proof_fingerprint.csv")" \
            "$(read_sha256_file "${d}/proof_fingerprint.sha256")" \
            "Run ${idx}: Option B sha256 matches file"

  assert_eq "$(sha256_of_file "${d}/proof_fingerprint_stable.csv")" \
            "$(read_sha256_file "${d}/proof_fingerprint_stable.sha256")" \
            "Run ${idx}: Option C1 sha256 matches file"

  # DB chain verification
  v="$(extract_kv "${d}/proof_summary.txt" "verify_event_chain")"
  [ -n "$v" ] || die "Run ${idx}: Missing verify_event_chain in proof_summary.txt"
  if [ "$v" != "t" ] && [ "$v" != "true" ]; then
    die "Run ${idx}: verify_event_chain expected true but got '${v}'"
  fi
  info "Run ${idx}: verify_event_chain=${v}"

  # Heads
  bhead="$(extract_kv "${d}/proof_summary.txt" "option_b_head")"
  chead="$(extract_kv "${d}/proof_summary.txt" "c1_head")"
  [ -n "$bhead" ] || die "Run ${idx}: Missing option_b_head"
  [ -n "$chead" ] || die "Run ${idx}: Missing c1_head"
  dbg "Run ${idx}: option_b_head=${bhead}"
  dbg "Run ${idx}: c1_head=${chead}"
done

D1="${OUTS[0]}"
D2="${OUTS[1]}"

A1="$(read_sha256_file "${D1}/payload_fingerprint_facts.sha256")"
A2="$(read_sha256_file "${D2}/payload_fingerprint_facts.sha256")"
C11="$(read_sha256_file "${D1}/proof_fingerprint_stable.sha256")"
C12="$(read_sha256_file "${D2}/proof_fingerprint_stable.sha256")"
B1="$(read_sha256_file "${D1}/proof_fingerprint.sha256")"
B2="$(read_sha256_file "${D2}/proof_fingerprint.sha256")"

C1H1="$(extract_kv "${D1}/proof_summary.txt" "c1_head")"
C1H2="$(extract_kv "${D2}/proof_summary.txt" "c1_head")"

info "Cross-run validation (run1 vs run2)"
assert_eq "$A1" "$A2"   "Option A is stable across runs (facts sha256)"
assert_eq "$C11" "$C12" "Option C1 is stable across runs (stable proof sha256)"
assert_ne "$B1" "$B2"   "Option B differs across runs (db-proof sha256)"
assert_eq "$C1H1" "$C1H2" "Option C1 head is stable across runs"

# Write reports for consulting deliverables
REPORT_TXT="${CHECK_DIR}/report.txt"
REPORT_JSON="${CHECK_DIR}/report.json"
REPORT_MD="${CHECK_DIR}/report.md"

{
  echo "timestamp_utc=$(ts_utc)"
  echo "scenario=${SCENARIO}"
  echo "runs=${RUNS}"
  echo "run1_outdir=${D1}"
  echo "run2_outdir=${D2}"
  echo "A_facts_sha256=${A1}"
  echo "C1_stable_proof_sha256=${C11}"
  echo "B_db_proof_sha256_run1=${B1}"
  echo "B_db_proof_sha256_run2=${B2}"
  echo "c1_head=${C1H1}"
  echo "verdict=PASS"
} > "$REPORT_TXT"

cat > "$REPORT_JSON" <<JSON
{
  "timestamp_utc": "$(ts_utc)",
  "scenario": "${SCENARIO}",
  "runs": ${RUNS},
  "run1_outdir": "$(printf '%s' "$D1" | sed 's/"/\\"/g')",
  "run2_outdir": "$(printf '%s' "$D2" | sed 's/"/\\"/g')",
  "option_a_facts_sha256": "${A1}",
  "option_c1_stable_proof_sha256": "${C11}",
  "option_b_db_proof_sha256": {
    "run1": "${B1}",
    "run2": "${B2}"
  },
  "c1_head": "$(printf '%s' "$C1H1" | sed 's/"/\\"/g')",
  "verdict": "PASS"
}
JSON

cat > "$REPORT_MD" <<MD
# Replay Verification Report

- Timestamp (UTC): \`$(ts_utc)\`
- Scenario: \`${SCENARIO}\`
- Runs: \`${RUNS}\`

## Run Outputs

- Run 1: \`${D1}\`
- Run 2: \`${D2}\`

## Expected Properties

- **Option A (facts)**: stable across runs.
- **Option C1 (stable proof-like)**: stable across runs.
- **Option B (DB-proof)**: differs across runs, but validates per-run.

## Results

- Option A facts sha256: \`${A1}\`
- Option C1 stable proof sha256: \`${C11}\`
- Option B db-proof sha256 run1: \`${B1}\`
- Option B db-proof sha256 run2: \`${B2}\`
- C1 head: \`${C1H1}\`

## Verdict

PASS
MD

info "PASS"
info "Report (txt) : ${REPORT_TXT}"
info "Report (json): ${REPORT_JSON}"
info "Report (md)  : ${REPORT_MD}"
info "Run logs     : ${CHECK_DIR}/run_*.log"
