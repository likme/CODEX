#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-}"
if [ -z "${OUT_DIR}" ]; then
  echo "Usage: $0 <out_dir>" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/sandbox/env.sh"

RAW="${OUT_DIR}/payload_fingerprint.csv"
FACTS="${OUT_DIR}/payload_fingerprint_facts.csv"

if [ ! -f "${RAW}" ]; then
  echo "ERROR: missing ${RAW}" >&2
  exit 1
fi
if [ ! -f "${FACTS}" ]; then
  echo "ERROR: missing ${FACTS}" >&2
  exit 1
fi

# 1) CSV raw matches DB for (seq, payload_hash_hex, payload_canonical)
python3 - <<'PY' "${RAW}" "${LEDGER_DB_DSN}"
import csv, sys, subprocess

raw_path = sys.argv[1]
dsn = sys.argv[2]

def q(sql: str) -> str:
    out = subprocess.check_output(["psql", dsn, "-X", "-tA", "-c", sql], text=True)
    return out

with open(raw_path, newline="") as f:
    r = csv.reader(f)
    hdr = next(r, None)
    if hdr != ["seq","payload_hash_hex","payload_canonical"]:
        raise SystemExit(f"unexpected header in raw: {hdr!r}")

    # check first 5 rows (enough to catch mismatch, cheap)
    for i, row in enumerate(r, start=1):
        if i > 5:
            break
        seq, payload_hash_hex_csv, payload_canon_csv = row

        payload_hash_hex_db = q(f"SELECT encode(payload_hash,'hex') FROM event_log WHERE seq={int(seq)};").strip()
        payload_canon_db = q(f"SELECT payload_canonical FROM event_log WHERE seq={int(seq)};").strip()

        if payload_hash_hex_db != payload_hash_hex_csv:
            raise SystemExit(f"FAIL raw hash mismatch seq={seq}: db={payload_hash_hex_db} csv={payload_hash_hex_csv}")
        if payload_canon_db != payload_canon_csv:
            raise SystemExit(f"FAIL raw canonical mismatch seq={seq}")

print("OK: raw CSV matches DB for first rows")
PY

# 2) DB hash is sha256_utf8(payload_canonical) exactly (no newline injection)
python3 - <<'PY' "${LEDGER_DB_DSN}"
import hashlib, sys, subprocess

dsn = sys.argv[1]
seq = 1

canon = subprocess.check_output(
    ["psql", dsn, "-X", "-tA", "-c", f"SELECT payload_canonical FROM event_log WHERE seq={seq};"],
    text=True,
).rstrip("\n")  # psql adds newline; DB TEXT does not include it
payload_hash_hex_db = subprocess.check_output(
    ["psql", dsn, "-X", "-tA", "-c", f"SELECT encode(payload_hash,'hex') FROM event_log WHERE seq={seq};"],
    text=True,
).strip()

h = hashlib.sha256(canon.encode("utf-8")).hexdigest()
if h != payload_hash_hex_db:
    raise SystemExit(f"FAIL db sha256 mismatch seq={seq}: computed={h} db={payload_hash_hex_db}")

print("OK: db payload_hash = sha256_utf8(payload_canonical) (checked on seq=1)")
PY

# 3) facts_hash_hex matches sha256(payload_canonical_normalized)
python3 - <<'PY' "${FACTS}"
import csv, hashlib, sys

facts_path = sys.argv[1]
with open(facts_path, newline="") as f:
    r = csv.reader(f)
    hdr = next(r, None)
    if hdr != ["seq","facts_hash_hex","payload_canonical_normalized"]:
        raise SystemExit(f"unexpected header in facts: {hdr!r}")

    for i, row in enumerate(r, start=1):
        if i > 20:
            break
        seq, facts_hash_hex, canon_norm = row
        h = hashlib.sha256(canon_norm.encode("utf-8")).hexdigest()
        if h != facts_hash_hex:
            raise SystemExit(f"FAIL facts hash mismatch seq={seq}: computed={h} file={facts_hash_hex}")

print("OK: facts hashes match sha256(canonical_normalized) for first rows")
PY

echo "OK: verify_fingerprint.sh passed for ${OUT_DIR}"
