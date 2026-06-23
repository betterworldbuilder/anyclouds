#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/blue-green-cutover-app}"

cd "$APP_DIR"
docker compose down

echo "Cutover app stopped."
