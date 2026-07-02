#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_as_root() {
  apt-get update
  apt-get install -y redis-server redis-tools
  systemctl enable --now redis-server

  BANK_CACHE_BACKEND="${BANK_CACHE_BACKEND:-redis}" \
  BANK_REDIS_HOST="${BANK_REDIS_HOST:-127.0.0.1}" \
  BANK_REDIS_PORT="${BANK_REDIS_PORT:-6379}" \
    "$DIR/install_common.sh" cache cache_service.py "${BANK_CACHE_PORT:-8107}"
}

if [[ "$(id -u)" -eq 0 ]]; then
  run_as_root
else
  sudo env \
    BANK_CACHE_PORT="${BANK_CACHE_PORT:-8107}" \
    BANK_CACHE_BACKEND="${BANK_CACHE_BACKEND:-redis}" \
    BANK_REDIS_HOST="${BANK_REDIS_HOST:-127.0.0.1}" \
    BANK_REDIS_PORT="${BANK_REDIS_PORT:-6379}" \
    bash "$0"
fi
