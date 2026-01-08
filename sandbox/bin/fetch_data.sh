#!/usr/bin/env bash
set -euo pipefail

# download_scenario_data.sh
#
# Purpose:
# - Download public reference datasets (FX, rates, prices, carbon factors)
# - Produce SHA256SUMS for integrity and auditability
# - Write a source manifest (urls + timestamps) suitable for consulting deliverables
#
# Usage:
#   ./download_scenario_data.sh                # defaults ROOT=./scenario_data
#   ./download_scenario_data.sh ./scenario_data
#
# Optional env:
#   VERBOSE=1        # more logs
#   DRY_RUN=1        # print actions, do not download
#   CONTINUE=1       # do not fail the whole script on a single download failure (still reports)
#   CURL_RETRIES=6   # curl retries
#   CURL_TIMEOUT=30  # seconds
#   USER_AGENT="..." # custom UA

ROOT="${1:-./scenario_data}"

VERBOSE="${VERBOSE:-0}"
DRY_RUN="${DRY_RUN:-0}"
CONTINUE="${CONTINUE:-0}"

CURL_RETRIES="${CURL_RETRIES:-6}"
CURL_TIMEOUT="${CURL_TIMEOUT:-30}"
USER_AGENT="${USER_AGENT:-scenario-data-fetch/1.0 (+public-datasets; no-pii)}"

mkdir -p "$ROOT"

ts_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {
  # log LEVEL MESSAGE...
  local lvl="$1"; shift
  printf '%s %-5s %s\n' "$(ts_utc)" "$lvl" "$*" >&2
}
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
err()  { log ERROR "$@"; }
dbg()  { if [ "$VERBOSE" = "1" ]; then log DEBUG "$@"; fi; }

die() { err "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
need_cmd curl
need_cmd sha256sum || need_cmd shasum

MANIFEST="${ROOT}/MANIFEST.txt"
FAILURES="${ROOT}/FAILURES.txt"
: > "$MANIFEST"
: > "$FAILURES"

record_manifest() {
  # record_manifest <url> <out>
  printf '%s\t%s\t%s\n' "$(ts_utc)" "$out" "$url" >> "$MANIFEST"
}

sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    shasum -a 256 "$f" | awk '{print $1}'
  fi
}

dl() {
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"

  record_manifest "$url" "$out"

  if [ "$DRY_RUN" = "1" ]; then
    info "[dry-run] would download: $url -> $out"
    return 0
  fi

  info "download: $out"
  dbg  "url: $url"

  # curl robustness:
  # -f: fail on 4xx/5xx
  # -S: show error
  # -L: follow redirects
  # --retry: retry on transient errors
  # --retry-all-errors: also retry on more cases (curl>=7.71)
  # timeouts to avoid hanging
  set +e
  curl -fSSL \
    --connect-timeout 10 \
    --max-time "$CURL_TIMEOUT" \
    --retry "$CURL_RETRIES" \
    --retry-delay 1 \
    --retry-max-time 120 \
    --user-agent "$USER_AGENT" \
    -o "$out" \
    "$url"
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    err "download failed (rc=$rc): $url"
    printf '%s\t%s\t%s\n' "$(ts_utc)" "$out" "$url" >> "$FAILURES"
    if [ "$CONTINUE" = "1" ]; then
      warn "CONTINUE=1 set, continuing despite failure"
      return 0
    fi
    return "$rc"
  fi

  # quick integrity: non-empty file
  if [ ! -s "$out" ]; then
    err "download produced empty file: $out"
    printf '%s\t%s\t%s\n' "$(ts_utc)" "$out" "$url" >> "$FAILURES"
    if [ "$CONTINUE" = "1" ]; then
      warn "CONTINUE=1 set, continuing despite empty file"
      return 0
    fi
    return 2
  fi

  dbg "sha256($(basename "$out"))=$(sha256_file "$out")"
}

sha_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  info "hashing dir: $dir"

  # Exclude SHA256SUMS.txt itself to make re-runs stable.
  # Use portable find ordering: -maxdepth before -type for BusyBox/macOS compatibility.
  local out="${dir}/SHA256SUMS.txt"
  if [ "$DRY_RUN" = "1" ]; then
    info "[dry-run] would write: $out"
    return 0
  fi

  (
    cd "$dir"
    # shellcheck disable=SC2016
    find . -maxdepth 5 -type f \
      ! -name 'SHA256SUMS.txt' \
      ! -name 'MANIFEST.txt' \
      ! -name 'FAILURES.txt' \
      -print0 \
    | sort -z \
    | xargs -0 sha256sum
  ) > "$out"
}

info "Starting dataset fetch"
info "ROOT=$ROOT"
info "MANIFEST=$MANIFEST"
info "FAILURES=$FAILURES"
info "VERBOSE=$VERBOSE DRY_RUN=$DRY_RUN CONTINUE=$CONTINUE"

# =========================
# 1) Banque retail / Macro
# =========================
# ECB FX (latest + historique)
dl "https://www.ecb.europa.eu/stats/eurofxref/eurofxref.zip" \
   "$ROOT/retail_macro/fx/ecb_eurofxref_latest.zip"
dl "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.zip" \
   "$ROOT/retail_macro/fx/ecb_eurofxref_hist.zip"

# FRED rates (CSV direct, no API key)
dl "https://fred.stlouisfed.org/graph/fredgraph.csv?id=FEDFUNDS" \
   "$ROOT/retail_macro/rates/fred_FEDFUNDS.csv"
dl "https://fred.stlouisfed.org/graph/fredgraph.csv?id=SOFR" \
   "$ROOT/retail_macro/rates/fred_SOFR.csv"
dl "https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS10" \
   "$ROOT/retail_macro/rates/fred_DGS10.csv"
dl "https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS2" \
   "$ROOT/retail_macro/rates/fred_DGS2.csv"

# =========================
# 2) Finance (prix historiques)
# =========================
# Note: Stooq is convenient. Availability can change. If it starts returning 403/HTML,
# keep the file for forensic trace, but treat as failure (FAILURES.txt will show it).
TICKERS=("AAPL.US" "MSFT.US" "SPY.US")
for t in "${TICKERS[@]}"; do
  tlow="$(echo "$t" | tr '[:upper:]' '[:lower:]')"
  dl "https://stooq.com/q/d/l/?s=${tlow}&i=d" \
     "$ROOT/finance/prices/stooq_${t}.csv"
done

# =========================
# 3) Carbone (MRV)
# =========================
dl "https://assets.publishing.service.gov.uk/media/6846a4f55e92539572806125/ghg-conversion-factors-2025-full-set.xlsx" \
   "$ROOT/carbon/factors_uk/ghg-conversion-factors-2025-full-set.xlsx"
dl "https://assets.publishing.service.gov.uk/media/6846a4e6d25e6f6afd4c0180/ghg-conversion-factors-2025-condensed-set.xlsx" \
   "$ROOT/carbon/factors_uk/ghg-conversion-factors-2025-condensed-set.xlsx"
dl "https://assets.publishing.service.gov.uk/media/6846b6ea57f3515d9611f0dd/ghg-conversion-factors-2025-flat-format.xlsx" \
   "$ROOT/carbon/factors_uk/ghg-conversion-factors-2025-flat-format.xlsx"

dl "https://assets.publishing.service.gov.uk/government/uploads/system/uploads/attachment_data/file/1134700/final-greenhouse-gas-emissions-2021-by-source-dataset.csv" \
   "$ROOT/carbon/uk_emissions/final-greenhouse-gas-emissions-2021-by-source-dataset.csv"

# =========================
# Checksums per domain
# =========================
sha_dir "$ROOT/retail_macro"
sha_dir "$ROOT/finance"
sha_dir "$ROOT/carbon"

# Summary
if [ -s "$FAILURES" ]; then
  warn "Completed with failures. See: $FAILURES"
  warn "Manifest saved: $MANIFEST"
  exit 2
fi

info "Completed successfully"
info "Data in: $ROOT"
info "Manifest: $MANIFEST"
