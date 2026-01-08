#!/usr/bin/env bash
set -euo pipefail

SCENARIO="${1:-smoke}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/sandbox/env.sh"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${SANDBOX_OUT}/${SCENARIO}/${ts}"
mkdir -p "${OUT_DIR}"
export OUT_DIR


log() { printf '%s\n' "$*" >&2; }

# sha256 helpers
sha256_file() {
  local f="$1" out="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}' > "$out"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}' > "$out"
  else
    echo "<sha256 unavailable>" > "$out"
  fi
}

# Optional: reset DB to ensure identical starting state across runs.
# Must be explicitly enabled to be safe.
# Usage: RESET_DB=1 ./replay.sh smoke
if [ "${RESET_DB:-0}" = "1" ]; then
  if [ -z "${POSTGRES_HOST:-}" ] || [ -z "${POSTGRES_PORT:-}" ] || [ -z "${POSTGRES_DB:-}" ]; then
    log "ERROR: RESET_DB=1 but POSTGRES_HOST/POSTGRES_PORT/POSTGRES_DB not set"
    exit 1
  fi

  # Only allow local reset to avoid foot-guns.
  case "${POSTGRES_HOST}" in
    localhost|127.0.0.1) ;;
    *)
      log "ERROR: RESET_DB=1 only allowed when POSTGRES_HOST is localhost/127.0.0.1 (got ${POSTGRES_HOST})"
      exit 1
      ;;
  esac

  ADMIN_DSN="postgres://ledger:ledger@${POSTGRES_HOST}:${POSTGRES_PORT}/postgres?sslmode=disable"

  log "[replay] RESET_DB=1 dropping and recreating database ${POSTGRES_DB}"
  psql "${ADMIN_DSN}" -v ON_ERROR_STOP=1 -X -c "DROP DATABASE IF EXISTS ${POSTGRES_DB};"
  psql "${ADMIN_DSN}" -v ON_ERROR_STOP=1 -X -c "CREATE DATABASE ${POSTGRES_DB};"
fi

# Run scenario (produces /tmp/e2e_payload_fingerprint_*.csv)
OUT_DIR="${OUT_DIR}" "${ROOT_DIR}/sandbox/up.sh" "${SCENARIO}" | tee "${OUT_DIR}/run.log"
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ]; then
  log "ERROR: up.sh failed rc=$rc"
  exit "$rc"
fi


# Option B: export DB-proof (hash-chain material) from the DB view (no clear payload)
psql "${LEDGER_DB_DSN}" -X -v ON_ERROR_STOP=1 <<SQL
\copy (SELECT * FROM event_log_proof_export_v) TO '${OUT_DIR}/proof_fingerprint.csv' WITH CSV HEADER
SQL
sha256_file "${OUT_DIR}/proof_fingerprint.csv" "${OUT_DIR}/proof_fingerprint.sha256"

# Capture env snapshot (non sensitive)
{
  echo "POSTGRES_HOST=${POSTGRES_HOST}"
  echo "POSTGRES_PORT=${POSTGRES_PORT}"
  echo "POSTGRES_DB=${POSTGRES_DB}"
  echo "LEDGER_HTTP_ADDR=${LEDGER_HTTP_ADDR:-:8080}"
  echo "LEDGER_URL=${LEDGER_URL:-http://127.0.0.1:8080}"
  echo "RESET_DB=${RESET_DB:-0}"
  if command -v git >/dev/null 2>&1; then
    echo "GIT_COMMIT=$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null || true)"
    echo "GIT_DIRTY=$(git -C "${ROOT_DIR}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  fi
} > "${OUT_DIR}/env_snapshot.txt"

# Copy core-ledger log if present
if [ -f "${SANDBOX_OUT}/core-ledger.log" ]; then
  cp -f "${SANDBOX_OUT}/core-ledger.log" "${OUT_DIR}/core-ledger.log"
fi

# Grab latest fingerprint produced in /tmp (DB-proof export by up.sh)
FP_SRC="$(ls -1t /tmp/e2e_payload_fingerprint_*.csv 2>/dev/null | head -n1 || true)"
if [ -z "${FP_SRC}" ]; then
  log "ERROR: fingerprint CSV not found in /tmp"
  exit 1
fi
echo "${FP_SRC}" > "${OUT_DIR}/payload_fingerprint.source.txt"
cp -f "${FP_SRC}" "${OUT_DIR}/payload_fingerprint.csv"

# Normalize for inter-run stable "facts" representation:
# - UUID -> UUID1, UUID2, ... (first-seen order)
# - any token containing 'idem' and ending with -<digits> -> IDEM1, IDEM2, ...
python3 - <<'PY' "${OUT_DIR}/payload_fingerprint.csv" "${OUT_DIR}/payload_fingerprint_normalized.csv"
import csv, re, sys
from pathlib import Path

in_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

uuid_re = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.IGNORECASE)
idem_any_re = re.compile(r"\b[a-z0-9_-]*idem[a-z0-9_-]*-\d+\b", re.IGNORECASE)

uuid_map = {}
idem_map = {}

def uuid_repl(m):
    u = m.group(0).lower()
    if u not in uuid_map:
        uuid_map[u] = f"UUID{len(uuid_map)+1}"
    return uuid_map[u]

def idem_repl(m):
    k = m.group(0).lower()
    if k not in idem_map:
        idem_map[k] = f"IDEM{len(idem_map)+1}"
    return idem_map[k]

def norm(s: str) -> str:
    s = uuid_re.sub(uuid_repl, s)
    s = idem_any_re.sub(idem_repl, s)
    return s

with in_path.open("r", newline="") as f_in, out_path.open("w", newline="") as f_out:
    r = csv.reader(f_in)
    w = csv.writer(f_out, lineterminator="\n")
    for row in r:
        w.writerow([norm(cell) for cell in row])
PY

# Derive a clean "facts" fingerprint file that is not mixing DB-hash with normalized canonical.
# Input columns: seq,payload_hash_hex,payload_canonical
# Output columns: seq,facts_hash_hex,payload_canonical_normalized
python3 - <<'PY' "${OUT_DIR}/payload_fingerprint_normalized.csv" "${OUT_DIR}/payload_fingerprint_facts.csv"
import csv, hashlib, sys
from pathlib import Path

in_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

with in_path.open(newline="") as f_in, out_path.open("w", newline="") as f_out:
    r = csv.reader(f_in)
    w = csv.writer(f_out, lineterminator="\n")

    hdr = next(r, None)
    if hdr is None or len(hdr) < 3:
        raise SystemExit(f"unexpected header: {hdr!r}")

    w.writerow(["seq", "facts_hash_hex", "payload_canonical_normalized"])

    for row in r:
        if len(row) < 3:
            raise SystemExit(f"unexpected row: {row!r}")
        seq = row[0]
        payload_canon_norm = row[2]
        facts_hash = hashlib.sha256(payload_canon_norm.encode("utf-8")).hexdigest()
        w.writerow([seq, facts_hash, payload_canon_norm])
PY

# Option C1: stable proof-like chain derived from Option A facts (inter-run comparable)
python3 - <<'PY' "${OUT_DIR}/payload_fingerprint_facts.csv" "${OUT_DIR}/proof_fingerprint_stable.csv"
import csv, hashlib, sys
from pathlib import Path

in_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()

with in_path.open(newline="") as f_in, out_path.open("w", newline="") as f_out:
    r = csv.reader(f_in)
    w = csv.writer(f_out, lineterminator="\n")

    hdr = next(r, None)
    if hdr is None:
        raise SystemExit("empty facts csv")

    if len(hdr) < 2 or hdr[0] != "seq" or hdr[1] != "facts_hash_hex":
        raise SystemExit(f"unexpected header: {hdr!r}")

    w.writerow(["seq", "prev_c1_hash_hex", "facts_hash_hex", "c1_hash_hex"])

    prev = ""
    for row in r:
        if len(row) < 2:
            raise SystemExit(f"unexpected row: {row!r}")
        seq = row[0]
        facts_hash = row[1]
        c1 = sha256_hex(f"{seq}|{prev}|{facts_hash}")
        w.writerow([seq, prev, facts_hash, c1])
        prev = c1
PY

# sha256 files
sha256_file "${OUT_DIR}/payload_fingerprint.csv" "${OUT_DIR}/payload_fingerprint.sha256"
sha256_file "${OUT_DIR}/payload_fingerprint_normalized.csv" "${OUT_DIR}/payload_fingerprint_normalized.sha256"
sha256_file "${OUT_DIR}/payload_fingerprint_facts.csv" "${OUT_DIR}/payload_fingerprint_facts.sha256"
sha256_file "${OUT_DIR}/proof_fingerprint_stable.csv" "${OUT_DIR}/proof_fingerprint_stable.sha256"
sha256_file "${OUT_DIR}/proof_fingerprint.csv" "${OUT_DIR}/proof_fingerprint.sha256"

# Proof summary from DB (admin) + C1 head
{
  echo "verify_event_chain=$(psql "${LEDGER_DB_DSN}" -X -tAc "SELECT verify_event_chain();" | tr -d ' ')"
  echo "event_log_count=$(psql "${LEDGER_DB_DSN}" -X -tAc "SELECT count(*) FROM event_log;" | tr -d ' ')"
  echo "head=$(psql "${LEDGER_DB_DSN}" -X -tAc "SELECT seq||' '||encode(hash,'hex') FROM event_log ORDER BY seq DESC LIMIT 1;" | tr -d '\r')"
  echo "option_b_head=$(psql "${LEDGER_DB_DSN}" -X -tAc "SELECT seq||' '||encode(hash,'hex') FROM event_log ORDER BY seq DESC LIMIT 1;" | tr -d '\r')"
  echo "c1_head=$(tail -n1 "${OUT_DIR}/proof_fingerprint_stable.csv" | awk -F, '{print $1" "$4}' | tr -d '\r')"
  echo "counts=$(psql "${LEDGER_DB_DSN}" -X -tAc "SELECT
     'accounts='||(SELECT count(*) FROM accounts)||' tx='||(SELECT count(*) FROM ledger_tx)
     ||' entries='||(SELECT count(*) FROM ledger_entry)||' events='||(SELECT count(*) FROM event_log);" | tr -d '\r')"
} > "${OUT_DIR}/proof_summary.txt"

# Quick pointers
{
  echo "db_proof_csv=${OUT_DIR}/payload_fingerprint.csv"
  echo "db_proof_sha256=${OUT_DIR}/payload_fingerprint.sha256"
  echo "facts_csv=${OUT_DIR}/payload_fingerprint_facts.csv"
  echo "facts_sha256=${OUT_DIR}/payload_fingerprint_facts.sha256"
  echo "option_b_csv=${OUT_DIR}/proof_fingerprint.csv"
  echo "option_b_sha256=${OUT_DIR}/proof_fingerprint.sha256"
  echo "option_c1_csv=${OUT_DIR}/proof_fingerprint_stable.csv"
  echo "option_c1_sha256=${OUT_DIR}/proof_fingerprint_stable.sha256"
} > "${OUT_DIR}/artifacts.txt"

echo "OK: ${OUT_DIR}"
