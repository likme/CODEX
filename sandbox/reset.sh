#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/sandbox/env.sh"

cd "${ROOT_DIR}/community-bank/infra"

# Reset infra + volumes (PG data wiped)
docker compose down -v

# Remove sandbox outputs
rm -rf "${SANDBOX_OUT:?}/"*
