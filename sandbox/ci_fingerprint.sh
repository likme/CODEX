#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}/sandbox"

run_and_get_out() {
  local scenario="$1"
  RESET_DB=1 ./replay.sh "$scenario" | awk '/^OK: /{print $2}' | tail -n1
}

out1="$(run_and_get_out smoke)"
./verify_fingerprint.sh "$out1"

out2="$(run_and_get_out smoke)"
./verify_fingerprint.sh "$out2"

h1="$(cat "$out1/payload_fingerprint_facts.sha256" | tr -d ' \r\n')"
h2="$(cat "$out2/payload_fingerprint_facts.sha256" | tr -d ' \r\n')"

if [ "$h1" != "$h2" ]; then
  echo "FAIL: facts sha differs" >&2
  echo "run1=$h1" >&2
  echo "run2=$h2" >&2
  exit 1
fi

echo "OK: ci_fingerprint passed"
echo "run1=$out1"
echo "run2=$out2"
echo "facts_sha256=$h1"
