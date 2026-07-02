#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(id -u)" -eq 0 ]]; then
  "$DIR/install_common.sh" core-banking core_banking_service.py "${BANK_CORE_PORT:-8102}"
else
  sudo "$DIR/install_common.sh" core-banking core_banking_service.py "${BANK_CORE_PORT:-8102}"
fi
