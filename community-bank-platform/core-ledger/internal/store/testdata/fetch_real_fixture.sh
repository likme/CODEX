#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_JSON="${OUT_DIR}/real_covid2020.json"

# 4 dates autour du choc COVID (jours ouvrés US/EU)
DATES=("2020-02-14" "2020-03-16" "2020-03-23" "2020-04-09")

# FRED CSV
FRED_DGS10="https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS10"
FRED_VIX="https://fred.stlouisfed.org/graph/fredgraph.csv?id=VIXCLS"

# ECB SDMX CSV
ECB_USDEUR="https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "${FRED_DGS10}" -o "${tmp}/dgs10.csv"
curl -fsSL "${FRED_VIX}"   -o "${tmp}/vix.csv"
curl -fsSL "${ECB_USDEUR}?startPeriod=2020-02-01&endPeriod=2020-04-30&format=csvdata" -o "${tmp}/usdeur.csv"

python3 - <<'PY' "$OUT_JSON" "$tmp" "${DATES[@]}"
import csv, json, sys, os

out_json = sys.argv[1]
tmp = sys.argv[2]
dates = sys.argv[3:]

def load_two_col_csv(path):
    # first col = date, second col = value (works for FRED: observation_date,SERIES)
    m = {}
    with open(path, newline='') as f:
        r = csv.reader(f)
        header = next(r, None)
        if not header or len(header) < 2:
            raise RuntimeError(f"bad csv header in {path}: {header}")
        for row in r:
            if not row or len(row) < 2:
                continue
            d = row[0].strip()
            v = row[1].strip()
            if not d or not v or v == '.' or v.lower() == 'nan':
                continue
            m[d] = v
    return m

def load_ecb_csv(path):
    # ECB csvdata usually: TIME_PERIOD, OBS_VALUE
    m = {}
    with open(path, newline='') as f:
        r = csv.DictReader(f)
        cols = r.fieldnames or []
        tp = 'TIME_PERIOD' if 'TIME_PERIOD' in cols else (cols[0] if cols else None)
        ov = 'OBS_VALUE' if 'OBS_VALUE' in cols else (cols[-1] if cols else None)
        if tp is None or ov is None:
            raise RuntimeError(f"bad ecb csv header in {path}: {cols}")
        for row in r:
            d = (row.get(tp) or "").strip()
            v = (row.get(ov) or "").strip()
            if not d or not v:
                continue
            m[d] = v
    return m

dgs10 = load_two_col_csv(os.path.join(tmp, 'dgs10.csv'))
vix = load_two_col_csv(os.path.join(tmp, 'vix.csv'))
usdeur = load_ecb_csv(os.path.join(tmp, 'usdeur.csv'))

def haircut_from_vix(v):
    # haircut_bps = clamp((VIX - 15) * 200, 200, 4000)
    x = (float(v) - 15.0) * 200.0
    if x < 200: x = 200
    if x > 4000: x = 4000
    return int(round(x))

phases = []
for d in dates:
    if d not in usdeur:
        raise SystemExit(f"missing {d} in ECB USD/EUR series")
    if d not in vix:
        raise SystemExit(f"missing {d} in FRED VIX series")

    valuations = [
        {
            "asset_type": "FX",
            "asset_id": "ECB:EXR.D.USD.EUR.SP00.A",
            "as_of": d + "T00:00:00Z",
            "price": usdeur[d],
            "currency": "EUR",
            "source": "ecb",
            "confidence": 99,
            "payload": {"series": "EXR.D.USD.EUR.SP00.A"},
        }
    ]
    if d in dgs10:
        valuations.append(
            {
                "asset_type": "RATE",
                "asset_id": "FRED:DGS10",
                "as_of": d + "T00:00:00Z",
                "price": dgs10[d],
                "currency": "PCT",
                "source": "fred",
                "confidence": 99,
                "payload": {"series": "DGS10"},
            }
        )

    h = haircut_from_vix(vix[d])

    liquidities = [
        {
            "asset_type": "FX",
            "asset_id": "ECB:EXR.D.USD.EUR.SP00.A",
            "as_of": d + "T00:00:00Z",
            "haircut_bps": h,
            "time_to_cash_seconds": 86400,
            "source": "vix_proxy",
            "payload": {"vix": vix[d], "rule": "clamp((VIX-15)*200,200,4000)"},
        }
    ]
    if d in dgs10:
        liquidities.append(
            {
                "asset_type": "RATE",
                "asset_id": "FRED:DGS10",
                "as_of": d + "T00:00:00Z",
                "haircut_bps": h,
                "time_to_cash_seconds": 86400,
                "source": "vix_proxy",
                "payload": {"vix": vix[d], "rule": "clamp((VIX-15)*200,200,4000)"},
            }
        )

    phases.append(
        {
            "phase_id": d,
            "as_of": d + "T00:00:00Z",
            "valuations": valuations,
            "liquidities": liquidities,
        }
    )

doc = {
    "scenario_id": "real_covid2020_v1",
    "description": "Real public data around Mar 2020. ECB USD/EUR + FRED VIX/DGS10. Haircut derived from VIX proxy rule.",
    "phases": phases,
}

with open(out_json, "w") as f:
    json.dump(doc, f, indent=2)

print(out_json)
PY

echo "Wrote ${OUT_JSON}"
