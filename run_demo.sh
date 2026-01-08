#!/usr/bin/env bash
set -euo pipefail

# One-command terminal demo:
# - purge + bring infra up
# - fetch real public fixture (COVID 2020)
# - hard-reset DB schema
# - run store tests (tamper, concurrency, scenarios)
# - run audits that print directly in the terminal
# - write all artifacts to demo_out/

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CB_DIR="${ROOT_DIR}/community-bank"
LEDGER_DIR="${ROOT_DIR}/community-bank-platform/core-ledger"
FIXTURE_SH="${LEDGER_DIR}/internal/store/testdata/fetch_real_fixture.sh"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }

need docker
if ! docker compose version >/dev/null 2>&1; then
  echo "Missing dependency: docker compose (Compose v2)" >&2
  exit 1
fi

need go
need psql
need grep
need tee
need sed

echo "==> 0) Clean + Infra up"
"${ROOT_DIR}/purge_and_up.sh"

POSTGRES_PORT="$(grep '^POSTGRES_PORT=' "${CB_DIR}/infra/.env" | cut -d= -f2)"
export LEDGER_DB_DSN="postgres://ledger:ledger@localhost:${POSTGRES_PORT}/ledger?sslmode=disable"
echo "LEDGER_DB_DSN=${LEDGER_DB_DSN}"

PSQL=(psql "${LEDGER_DB_DSN}" -v ON_ERROR_STOP=1 -qAt)

echo
echo "==> 1) Fetch real public fixture (COVID 2020)"
chmod +x "${FIXTURE_SH}"
"${FIXTURE_SH}"

echo
echo "==> 2) Reset DB (clean slate)"
# Wipes everything created by previous runs/tests. Migrations will recreate.
"${PSQL[@]}" <<'SQL' >/dev/null
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO ledger;
GRANT ALL ON SCHEMA public TO public;
SQL
echo "DB reset: OK"

echo
echo "==> 3) Run tests (store package)"
pushd "${LEDGER_DIR}" >/dev/null
go test ./internal/store -count=1 -v | tee /tmp/core-ledger-demo-tests.log

echo
echo "==> 4) Audit (prints live)"

echo
echo "[audit] event_log totals"
"${PSQL[@]}" <<'SQL' | tee /tmp/core-ledger-demo-audit-events.txt
SELECT aggregate_type, count(*) AS n
FROM event_log
GROUP BY 1
ORDER BY 1;
SQL

echo
echo "[audit] event_log sample (last 20)"
"${PSQL[@]}" <<'SQL' | tee /tmp/core-ledger-demo-audit-eventlog-sample.txt
SELECT
  to_char(created_at,'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS created_at,
  aggregate_type,
  aggregate_id,
  event_type
FROM event_log
ORDER BY created_at DESC
LIMIT 20;
SQL

echo
echo "[audit] verify_event_chain()"
"${PSQL[@]}" <<'SQL' | tee /tmp/core-ledger-demo-audit-chain.txt
SELECT verify_event_chain();
SQL

echo
echo "[audit] snapshots per day (valuation/liquidity) [COVID window]"
"${PSQL[@]}" <<'SQL' | tee /tmp/core-ledger-demo-audit-snapshots.txt
WITH days AS (
  SELECT DISTINCT as_of::date AS d
  FROM valuation_snapshot
  WHERE as_of >= '2020-02-01'::timestamptz AND as_of < '2020-05-01'::timestamptz
  UNION
  SELECT DISTINCT as_of::date AS d
  FROM liquidity_snapshot
  WHERE as_of >= '2020-02-01'::timestamptz AND as_of < '2020-05-01'::timestamptz
)
SELECT
  to_char(d, 'YYYY-MM-DD') AS day,
  (SELECT count(*) FROM valuation_snapshot v WHERE v.as_of::date = days.d) AS valuations,
  (SELECT count(*) FROM liquidity_snapshot l WHERE l.as_of::date = days.d) AS liquidities
FROM days
ORDER BY d;
SQL

echo
echo "[audit] regime break (deterministic, derived) [COVID window]"
"${PSQL[@]}" <<'SQL' | tee /tmp/core-ledger-demo-audit-regime.txt
WITH fx AS (
  SELECT as_of, max(price::numeric) AS fx
  FROM valuation_snapshot
  WHERE asset_id='ECB:EXR.D.USD.EUR.SP00.A'
    AND as_of >= '2020-02-01'::timestamptz AND as_of < '2020-05-01'::timestamptz
  GROUP BY as_of
),
r AS (
  SELECT as_of, max(price::numeric) AS dgs10
  FROM valuation_snapshot
  WHERE asset_id='FRED:DGS10'
    AND as_of >= '2020-02-01'::timestamptz AND as_of < '2020-05-01'::timestamptz
  GROUP BY as_of
),
h AS (
  SELECT as_of, max(haircut_bps) AS haircut_bps
  FROM liquidity_snapshot
  WHERE asset_id='ECB:EXR.D.USD.EUR.SP00.A'
    AND as_of >= '2020-02-01'::timestamptz AND as_of < '2020-05-01'::timestamptz
  GROUP BY as_of
),
j AS (
  SELECT fx.as_of, fx.fx, r.dgs10, h.haircut_bps
  FROM fx JOIN r USING(as_of) JOIN h USING(as_of)
),
d AS (
  SELECT
    as_of,
    fx,
    dgs10,
    haircut_bps,
    abs(fx - lag(fx) OVER (ORDER BY as_of)) AS d_fx,
    abs(dgs10 - lag(dgs10) OVER (ORDER BY as_of)) AS d_rate
  FROM j
)
SELECT
  to_char(as_of,'YYYY-MM-DD') AS day,
  fx::text,
  dgs10::text,
  haircut_bps,
  coalesce(d_fx,0)::text AS d_fx,
  coalesce(d_rate,0)::text AS d_rate,
  CASE
    WHEN haircut_bps >= 2000 THEN true
    WHEN coalesce(d_rate,0) >= 0.50 THEN true
    WHEN coalesce(d_fx,0) >= 0.02 THEN true
    ELSE false
  END AS regime_break
FROM d
ORDER BY as_of;
SQL

echo
echo "==> 5) Bundle outputs"
OUT="${ROOT_DIR}/demo_out"
mkdir -p "${OUT}"

cp -f /tmp/core-ledger-demo-tests.log "${OUT}/tests.log"
cp -f /tmp/core-ledger-demo-audit-*.txt "${OUT}/"
cp -f "${LEDGER_DIR}/internal/store/testdata/real_covid2020.json" "${OUT}/real_covid2020.json"

# Single-screen summary for live demos
{
  echo "DEMO SUMMARY"
  echo "dsn=${LEDGER_DB_DSN}"
  echo
  echo "chain_verify=$(cat /tmp/core-ledger-demo-audit-chain.txt)"
  echo
  echo "event_log_totals:"
  cat /tmp/core-ledger-demo-audit-events.txt
  echo
  echo "covid_snapshots:"
  cat /tmp/core-ledger-demo-audit-snapshots.txt
  echo
  echo "covid_regime_break:"
  cat /tmp/core-ledger-demo-audit-regime.txt
} | tee "${OUT}/summary.txt"

echo
echo "Artifacts written to: ${OUT}"
ls -1 "${OUT}" | sed 's/^/  - /'

popd >/dev/null
echo
echo "==> DONE"
