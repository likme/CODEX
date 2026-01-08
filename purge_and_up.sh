#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CB_DIR="${ROOT_DIR}/community-bank"
INFRA_DIR="${CB_DIR}/infra"

log() { printf "\n==> %s\n" "$*"; }

log "Context"
echo "ROOT_DIR=${ROOT_DIR}"
echo "CB_DIR=${CB_DIR}"
echo "INFRA_DIR=${INFRA_DIR}"

if [ ! -d "$CB_DIR" ]; then
  echo "ERROR: missing ${CB_DIR}" >&2
  exit 1
fi
if [ ! -d "$INFRA_DIR" ]; then
  echo "ERROR: missing ${INFRA_DIR}" >&2
  exit 1
fi

log "Step 1/4: Purge (stop processes, stop compose, remove volumes)"
bash "${CB_DIR}/scripts/purge_all.sh"

log "Step 2/4: Ensure infra env file exists"
if [ ! -f "${INFRA_DIR}/.env" ]; then
  echo "INFO: ${INFRA_DIR}/.env missing, running bootstrap_env.sh"
  bash "${INFRA_DIR}/scripts/bootstrap_env.sh"
fi
echo "INFO: current infra/.env:"
sed 's/^/  /' "${INFRA_DIR}/.env" || true

log "Step 3/4: Docker compose up"
cd "${INFRA_DIR}"
docker compose up -d

log "Step 4/4: Health checks"
echo "INFO: docker compose ps:"
docker compose ps

echo "INFO: waiting for postgres container to be healthy (max 30s)"
for i in $(seq 1 30); do
  if docker inspect --format '{{.State.Health.Status}}' infra-postgres-1 2>/dev/null | grep -q healthy; then
    echo "OK: postgres is healthy"
    break
  fi
  sleep 1
  if [ "$i" -eq 30 ]; then
    echo "ERROR: postgres not healthy after 30s" >&2
    docker logs infra-postgres-1 | tail -n 200 >&2
    exit 1
  fi
done

log "Done"