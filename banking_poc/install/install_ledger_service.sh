#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(id -u)" -eq 0 ]]; then
  "$DIR/install_common.sh" ledger ledger_service.py "${BANK_LEDGER_PORT:-8103}"
else
  sudo "$DIR/install_common.sh" ledger ledger_service.py "${BANK_LEDGER_PORT:-8103}"
fi
