#!/usr/bin/env bash
# community-bank/scripts/fetch_real_data_regime_break.sh
#
# Purpose:
#   Fetch public market data (FRED) for a fixed COVID-2020 window and materialize
#   a deterministic CSV fixture consumed by:
#     TestScenario_RealData_RegimeBreak_RiskLayer
#
# Output:
#   community-bank-platform/core-ledger/internal/store/testdata/real_data_regime_break.csv
#
# Notes:
# - Tests must be offline and deterministic. This script is the only network step.
# - Uses FRED "fredgraph.csv" endpoints which do not require an API key.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_REL="community-bank-platform/core-ledger/internal/store/testdata/real_data_regime_break.csv"
OUT_PATH="${ROOT_DIR}/${OUT_REL}"

mkdir -p "$(dirname "$OUT_PATH")"

need_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need_bin curl
need_bin awk
need_bin sed

SHA_BIN=""
if command -v sha256sum >/dev/null 2>&1; then
  SHA_BIN="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA_BIN="shasum -a 256"
else
  echo "missing sha tool: sha256sum or shasum" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Fixed window used elsewhere in the demo outputs.
DATES=(
  "2020-02-14"
  "2020-03-16"
  "2020-03-23"
  "2020-04-09"
)

# Public sources (FRED):
# - DGS10   : 10-Year Treasury Constant Maturity Rate (percent)
# - DEXUSEU : U.S. Dollars to One Euro (USD per EUR)
FRED_SERIES=(
  "DGS10"
  "DEXUSEU"
)

fetch_fred_csv() {
  local series="$1"
  local out="$2"
  # Endpoint returns CSV with DATE,VALUE
  # (kept in code block for auditability)
  # https://fred.stlouisfed.org/graph/fredgraph.csv?id=<SERIES>
  curl -fsSL "https://fred.stlouisfed.org/graph/fredgraph.csv?id=${series}" -o "$out"
}

value_for_date() {
  local csv="$1"
  local date="$2"
  # Return VALUE for exact DATE, ignore "." missing values.
  awk -F',' -v d="$date" 'NR>1 && $1==d && $2!="." {print $2; exit}' "$csv"
}

# Deterministic derived liquidity haircuts for the regime-break narrative.
# This is NOT "from FRED". It is a documented, reproducible transform.
# Rule: haircut_bps is stepwise by date in this window (matches demo narrative).
haircut_for_date() {
  local date="$1"
  case "$date" in
    "2020-02-14") echo "200" ;;
    "2020-03-16") echo "4000" ;;
    "2020-03-23") echo "4000" ;;
    "2020-04-09") echo "4000" ;;
    *) echo "200" ;;
  esac
}

# Deterministic time-to-cash for all rows in this fixture.
TTC_SECONDS="86400"

# Fetch source series once.
declare -A SERIES_CSV
for s in "${FRED_SERIES[@]}"; do
  p="${TMP_DIR}/${s}.csv"
  fetch_fred_csv "$s" "$p"
  SERIES_CSV["$s"]="$p"
done

# Emit fixture.
# Required columns:
# as_of,asset_id,price,currency,haircut_bps,time_to_cash_seconds
#
# Semantics:
# - asset_id values are stable identifiers; they become ingestion correlation ids too.
# - price is a string (test passes it through as NUMERIC).
# - currency must be 3-letter uppercase (DB constraint).
{
  echo "as_of,asset_id,price,currency,haircut_bps,time_to_cash_seconds"

  for d in "${DATES[@]}"; do
    asof="${d}T00:00:00Z"

    dgs10="$(value_for_date "${SERIES_CSV[DGS10]}" "$d" || true)"
    dexuseu="$(value_for_date "${SERIES_CSV[DEXUSEU]}" "$d" || true)"

    # Hard fail if public data missing for a required date.
    if [[ -z "${dgs10}" ]]; then
      echo "missing FRED value: DGS10 for ${d}" >&2
      exit 1
    fi
    if [[ -z "${dexuseu}" ]]; then
      echo "missing FRED value: DEXUSEU for ${d}" >&2
      exit 1
    fi

    haircut="$(haircut_for_date "$d")"

    # Two assets per date:
    # - RATE_10Y_US: DGS10 (percent)
    # - FX_EURUSD  : DEXUSEU (USD per EUR)
    echo "${asof},RATE_10Y_US,${dgs10},USD,${haircut},${TTC_SECONDS}"
    echo "${asof},FX_EURUSD,${dexuseu},USD,${haircut},${TTC_SECONDS}"
  done
} > "$OUT_PATH"

echo "Wrote ${OUT_PATH}"
echo "SHA256:"
# shellcheck disable=SC2086
$SHA_BIN "$OUT_PATH"
