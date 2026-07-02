#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(id -u)" -eq 0 ]]; then
  "$DIR/install_common.sh" notification notification_service.py "${BANK_NOTIFICATION_PORT:-8105}"
else
  sudo "$DIR/install_common.sh" notification notification_service.py "${BANK_NOTIFICATION_PORT:-8105}"
fi
