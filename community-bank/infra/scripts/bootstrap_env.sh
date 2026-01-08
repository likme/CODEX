#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE=".env"
EXAMPLE_FILE=".env.example"

if [ ! -f "$ENV_FILE" ]; then
  cp "$EXAMPLE_FILE" "$ENV_FILE"
fi

pick_port() {
  local p="$1"
  while ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; do
    p=$((p+1))
  done
  echo "$p"
}

PORT="$(pick_port 55432)"

if grep -q '^POSTGRES_PORT=' "$ENV_FILE"; then
  sed -i "s/^POSTGRES_PORT=.*/POSTGRES_PORT=$PORT/" "$ENV_FILE"
else
  echo "POSTGRES_PORT=$PORT" >> "$ENV_FILE"
fi

echo "POSTGRES_PORT=$PORT"
