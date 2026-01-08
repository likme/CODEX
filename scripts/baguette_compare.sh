#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Baguette Index Comparator
# ============================================================
# Compares two result.json files.
# Comparison is allowed ONLY if payload_hash_sha256 is identical.
# Verbose by default. English output only.
# ============================================================

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need jq

# ---------------- Logging ----------------
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '%s %-5s %s\n' "$(ts)" "$1" "$2" >&2; }
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
die()  { log ERROR "$*"; exit 1; }

# ---------------- Args ----------------
A="${1:-}"
B="${2:-}"

[ -n "$A" ] || die "Missing first result.json argument"
[ -n "$B" ] || die "Missing second result.json argument"

[ -f "$A" ] || die "File not found: $A"
[ -f "$B" ] || die "File not found: $B"

info "Baguette index comparison starting"
info "File A: $A"
info "File B: $B"

# ---------------- Load hashes ----------------
HASH_A="$(jq -r '.payload_hash_sha256 // empty' "$A")"
HASH_B="$(jq -r '.payload_hash_sha256 // empty' "$B")"

[ -n "$HASH_A" ] || die "payload_hash_sha256 missing in $A"
[ -n "$HASH_B" ] || die "payload_hash_sha256 missing in $B"

info "Hash A: $HASH_A"
info "Hash B: $HASH_B"

# ---------------- Unit equality check ----------------
if [ "$HASH_A" != "$HASH_B" ]; then
  warn "Unit mismatch detected"
  warn "Comparison refused: measured unit is not the same"
  echo
  echo "INVALID COMPARISON:"
  echo "The two values are bound to different unit definitions (u)."
  echo "Direct comparison is not allowed."
  exit 2
fi

info "Unit match confirmed (hash identical)"

# ---------------- Load numeric values ----------------
N_A="$(jq -r '.n.value_cents' "$A")"
N_B="$(jq -r '.n.value_cents' "$B")"

PERIOD_A="$(jq -r '.n.period' "$A")"
PERIOD_B="$(jq -r '.n.period' "$B")"

info "Value A: ${N_A} cents (period ${PERIOD_A})"
info "Value B: ${N_B} cents (period ${PERIOD_B})"

# ---------------- Compute delta ----------------
DELTA=$((N_B - N_A))

if [ "$DELTA" -gt 0 ]; then
  SIGN="+"
else
  SIGN=""
fi

info "Delta computed: ${SIGN}${DELTA} cents"

# ---------------- Output (machine + human) ----------------
cat <<EOF

COMPARISON RESULT (VALID)

Unit hash:
  ${HASH_A}

Period A:
  ${PERIOD_A}
Value A:
  ${N_A} cents

Period B:
  ${PERIOD_B}
Value B:
  ${N_B} cents

Delta (B - A):
  ${SIGN}${DELTA} cents

Note:
This comparison is valid because both values share
the exact same unit definition (identical payload hash).
No economic interpretation is implied.

EOF

info "Comparison completed successfully"
