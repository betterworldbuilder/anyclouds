#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(id -u)" -eq 0 ]]; then
  "$DIR/install_common.sh" api-gateway api_gateway.py "${BANK_API_PORT:-8100}"
else
  sudo "$DIR/install_common.sh" api-gateway api_gateway.py "${BANK_API_PORT:-8100}"
fi
