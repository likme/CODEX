#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCEN_DIR="${ROOT_DIR}/sandbox/scenarios/retail_30d"

: "${LEDGER_URL:?LEDGER_URL must be set (e.g. http://127.0.0.1:8080)}"

# optional: allow replay.sh to pass OUT_DIR
export SCENARIO_OUT_DIR="${SCENARIO_OUT_DIR:-${ROOT_DIR}/sandbox/out/scenario_runs/retail_30d}"

python3 "${SCEN_DIR}/generate_and_run.py" "${SCEN_DIR}/config.yaml"
echo "[retail_30d] OK"
