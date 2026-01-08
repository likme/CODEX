#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Indice Baguette — Paris (DEMO, OFFLINE-FIRST)
# ============================================================
# - Panel: synthetic by default (no network)
# - Prices: 100% synthetic
# - Output: n + u(canonical) + payload_hash + statement
# - Deterministic by SEED
# ============================================================

# ---------------- Dependencies ----------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need jq
need python3
need sha256sum

# ---------------- Config ----------------
SEED="${SEED:-42}"
PERIOD="${PERIOD:-2026-01}"              # YYYY-MM
LOCATION="${LOCATION:-Paris}"

OUT_DIR="${OUT_DIR:-./out/baguette/${LOCATION}/${PERIOD}_w${WEIGHT_GRAMS}}"


# Panel source: synthetic | osm
PANEL_SOURCE="${PANEL_SOURCE:-synthetic}"

# Synthetic panel
SYNTH_PANEL_SIZE="${SYNTH_PANEL_SIZE:-500}"

# Synthetic price model
MEAN_CENTS="${MEAN_CENTS:-120}"
STD_CENTS="${STD_CENTS:-15}"
MIN_CENTS="${MIN_CENTS:-50}"

# Unit definition
WEIGHT_GRAMS="${WEIGHT_GRAMS:-250}"
FLOUR_TYPE="${FLOUR_TYPE:-T65}"
BAKING_METHOD="${BAKING_METHOD:-electric_oven}"
REGULATORY_FRAMEWORK="${REGULATORY_FRAMEWORK:-decret_1993}"
CALC_METHOD="${CALC_METHOD:-mean_price_panel}"
ENERGY_ASSUMPTIONS="${ENERGY_ASSUMPTIONS:-electricity_mix_2024}"
TAXES_AND_SUBSIDIES="${TAXES_AND_SUBSIDIES:-included}"

VERBOSE="${VERBOSE:-0}"

# ---------------- Logging ----------------
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '%s %-5s %s\n' "$(ts)" "$1" "$2" >&2; }
info() { log INFO "$*"; }
dbg() { [ "$VERBOSE" = "1" ] && log DEBUG "$*"; }
die() { log ERROR "$*"; exit 1; }

# ---------------- Setup ----------------
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$OUT_DIR"

sha256_file() { sha256sum "$1" | awk '{print $1}'; }

# ============================================================
# Panel generation (synthetic, offline)
# ============================================================
generate_panel_synthetic() {
  local out="$1"
  info "Generating synthetic panel (offline) size=${SYNTH_PANEL_SIZE}"

  SEED="$SEED" LOCATION="$LOCATION" SYNTH_PANEL_SIZE="$SYNTH_PANEL_SIZE" \
  python3 - <<'PY' > "$out"
import os, random
seed=int(os.environ["SEED"])
loc=os.environ["LOCATION"]
n=int(os.environ["SYNTH_PANEL_SIZE"])

rng=random.Random(seed)
for i in range(n):
    pid=f"synthetic:{loc}:{i:05d}"
    name=f"Synthetic Bakery {i:05d}"
    addr=f"{rng.randint(1,250)} Rue Démo"
    postcode=f"750{rng.randint(1,20):02d}"
    print("\t".join([pid,name,addr,postcode,loc,"",""]))
PY
}

# ============================================================
# Canonicalize panel
# ============================================================
canonicalize_panel() {
  local in_tsv="$1" out_jsonl="$2"
  python3 - <<PY
import json
rows=[]
with open("$in_tsv","r",encoding="utf-8") as f:
    for l in f:
        p=l.rstrip("\n").split("\t")
        if len(p)!=7: continue
        rows.append({
          "panel_id":p[0],"name":p[1],"address":p[2],
          "postcode":p[3],"city":p[4],"lat":p[5],"lon":p[6]
        })
rows.sort(key=lambda r:r["panel_id"])
with open("$out_jsonl","w",encoding="utf-8") as o:
    for r in rows:
        o.write(json.dumps(r,sort_keys=True,separators=(",",":"))+"\n")
print(len(rows))
PY
}

# ============================================================
# Generate synthetic prices
# ============================================================
generate_prices() {
  local panel="$1" out="$2"
  SEED="$SEED" PERIOD="$PERIOD" \
  MEAN="$MEAN_CENTS" STD="$STD_CENTS" MIN="$MIN_CENTS" \
  python3 - <<PY
import os, json, random, hashlib
seed=int(os.environ["SEED"])
period=os.environ["PERIOD"]
mean=int(os.environ["MEAN"])
std=int(os.environ["STD"])
minc=int(os.environ["MIN"])

mix=f"{seed}|{period}".encode()
rng=random.Random(int(hashlib.sha256(mix).hexdigest()[:16],16))
spec=f"synthetic:gauss(mean={mean},std={std},min={minc});seed={seed};period={period}"

with open("$panel","r") as f, open("$out","w") as o:
    for l in f:
        r=json.loads(l)
        p=max(minc,int(round(rng.gauss(mean,std))))
        o.write(f"{r['panel_id']}\t{p}\tsynthetic\t{spec}\n")
PY
}

# ============================================================
# Build u and hash
# ============================================================
build_u() {
  local panel_hash="$1" panel_size="$2" gen_spec="$3"
  jq -nc \
    --arg object "baguette" \
    --argjson weight "$WEIGHT_GRAMS" \
    --arg flour "$FLOUR_TYPE" \
    --arg bake "$BAKING_METHOD" \
    --arg reg "$REGULATORY_FRAMEWORK" \
    --arg loc "$LOCATION" \
    --arg calc "$CALC_METHOD" \
    --arg energy "$ENERGY_ASSUMPTIONS" \
    --arg tax "$TAXES_AND_SUBSIDIES" \
    --arg period "$PERIOD" \
    --arg ph "$panel_hash" \
    --argjson ps "$panel_size" \
    --arg gen "$gen_spec" \
    '{
      object:$object,
      weight_grams:$weight,
      flour_type:$flour,
      baking_method:$bake,
      regulatory_framework:$reg,
      location:$loc,
      calculation_method:$calc,
      energy_assumptions:$energy,
      taxes_and_subsidies:$tax,
      period:$period,
      data_sources:{
        panel:{source:"synthetic_only",panel_hash_sha256:$ph,panel_size:$ps},
        prices:{source:"synthetic_only",generator_spec:$gen}
      },
      hypotheses:{smoothing:"none",extrapolation:"none"}
    }'
}

# ============================================================
# Compute n
# ============================================================
compute_n() {
  local obs="$1" ucanon="$2" uhash="$3"
  python3 - <<PY
import json, statistics
prices=[int(l.split("\t")[1]) for l in open("$obs")]
n=int(round(statistics.mean(prices)))
u=json.loads(open("$ucanon").read())
print(json.dumps({
  "n":{"value_cents":n,"unit":"EUR_cent","panel_size":len(prices),"period":"$PERIOD"},
  "u":u,
  "payload_hash_sha256":"$uhash",
  "statement":"Cette valeur correspond à cet objet défini ainsi, pour cette période."
},indent=2,ensure_ascii=False))
PY
}

# ============================================================
# Run
# ============================================================
info "Indice Baguette demo starting"
info "PANEL_SOURCE=${PANEL_SOURCE} SEED=${SEED} PERIOD=${PERIOD}"

PANEL_TSV="${OUT_DIR}/panel.tsv"
PANEL_JSONL="${OUT_DIR}/panel_canonical.jsonl"
OBS_TSV="${OUT_DIR}/observations.tsv"
U_CANON="${OUT_DIR}/payload_canonical.json"
RES_JSON="${OUT_DIR}/result.json"

generate_panel_synthetic "$PANEL_TSV"
N="$(canonicalize_panel "$PANEL_TSV" "$PANEL_JSONL")"
PANEL_HASH="$(sha256_file "$PANEL_JSONL")"

generate_prices "$PANEL_JSONL" "$OBS_TSV"
GEN_SPEC="$(awk -F'\t' 'NR==1{print $4}' "$OBS_TSV")"

build_u "$PANEL_HASH" "$N" "$GEN_SPEC" | jq -S -c . > "$U_CANON"
U_HASH="$(sha256_file "$U_CANON")"

compute_n "$OBS_TSV" "$U_CANON" "$U_HASH" > "$RES_JSON"

info "RESULT written -> $RES_JSON"
info "payload_hash=${U_HASH}"
info "DONE"
