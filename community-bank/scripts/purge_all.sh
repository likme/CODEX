#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="${ROOT_DIR}/infra"

echo "[purge] stopping core-ledger processes"
pkill -f 'go run ./cmd/server' || true
pkill -f 'core-ledger' || true

echo "[purge] freeing ports (8080 / 18080)"
for p in 8080 18080; do
  if lsof -i :"$p" >/dev/null 2>&1; then
    lsof -ti :"$p" | xargs -r kill -9
  fi
done

echo "[purge] stopping docker compose infra"
cd "$INFRA_DIR"
docker compose down -v

echo "[purge] removing dangling volumes (ledger-related)"
docker volume ls | awk '/infra_pgdata/ {print $2}' | xargs -r docker volume rm

echo "[purge] cleaning tmp logs"
rm -f /tmp/core-ledger.log
rm -f /tmp/core-ledger-foreground.log

echo "[purge] done. system is clean."
