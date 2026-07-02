#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(id -u)" -eq 0 ]]; then
  "$DIR/install_common.sh" audit audit_service.py "${BANK_AUDIT_PORT:-8104}"
else
  sudo "$DIR/install_common.sh" audit audit_service.py "${BANK_AUDIT_PORT:-8104}"
fi
