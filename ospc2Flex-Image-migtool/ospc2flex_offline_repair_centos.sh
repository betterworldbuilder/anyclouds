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
  echo "Usage: bash $0 --version <7|8|9|stream9> --qcow2 <path.qcow2> [other ospc2flex_offline_repair.sh args]"
  exit 1
fi

case "${VERSION,,}" in
  7|centos7)            OS_TYPE="centos7" ;;
  8|centos8)            OS_TYPE="centos8" ;;
  9|centos9)            OS_TYPE="centos9" ;;
  stream9|centosstream9|centos-stream9) OS_TYPE="centosstream9" ;;
  *)
    echo "[ERROR] Unsupported CentOS version '$VERSION'. Use 7, 8, 9, or stream9."
    exit 1
    ;;
esac

exec bash "$BASE_SCRIPT" --os-type "$OS_TYPE" "${PASS_ARGS[@]}"
