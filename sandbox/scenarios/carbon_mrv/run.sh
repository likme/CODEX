#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCEN_DIR="${ROOT_DIR}/sandbox/scenarios/carbon_mrv"

: "${LEDGER_URL:?LEDGER_URL must be set (e.g. http://127.0.0.1:8080)}"

export SCENARIO_OUT_DIR="${SCENARIO_OUT_DIR:-${ROOT_DIR}/sandbox/out/scenario_runs/carbon_mrv}"

python3 "${SCEN_DIR}/generate_and_run.py" "${SCEN_DIR}/config.yaml"
echo "[carbon_mrv] OK"
