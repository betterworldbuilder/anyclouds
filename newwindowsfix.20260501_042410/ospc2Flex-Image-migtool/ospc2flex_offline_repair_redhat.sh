#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE_SCRIPT="$SCRIPT_DIR/ospc2flex_offline_repair.sh"

VERSION=""
PASS_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    *)
      PASS_ARGS+=("$1")
      shift
      ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "Usage: bash $0 --version <7|8|9> --qcow2 <path.qcow2> [other ospc2flex_offline_repair.sh args]"
  exit 1
fi

case "${VERSION,,}" in
  7|rhel7|redhat7) OS_TYPE="rhel7" ;;
  8|rhel8|redhat8) OS_TYPE="rhel8" ;;
  9|rhel9|redhat9) OS_TYPE="rhel9" ;;
  *)
    echo "[ERROR] Unsupported Red Hat version '$VERSION'. Use 7, 8, or 9."
    exit 1
    ;;
esac

exec bash "$BASE_SCRIPT" --os-type "$OS_TYPE" "${PASS_ARGS[@]}"
