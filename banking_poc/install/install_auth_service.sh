#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(id -u)" -eq 0 ]]; then
  "$DIR/install_common.sh" auth auth_service.py "${BANK_AUTH_PORT:-8101}"
else
  sudo "$DIR/install_common.sh" auth auth_service.py "${BANK_AUTH_PORT:-8101}"
fi
