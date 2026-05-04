#!/usr/bin/env bash
set -u

JH_USER="ubuntu"
JH_HOST="104.239.169.89"
SSH_KEY="$HOME/.ssh/id_rsa"

LOGS=(
  "/tmp/mig_ospc2flex-win2019.log"
  "/tmp/mig_ospc2flex-win2029.log"
  "/tmp/mig_ospc2flex-win2016.log"
)

for log in "${LOGS[@]}"; do
  echo "=================================================================="
  echo "LATEST STATUS: ${log}"
  echo "=================================================================="
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${JH_USER}@${JH_HOST}" "
    if [ ! -f '$log' ]; then
      echo '[ERROR] Log not found: $log'
      exit 0
    fi
    # Show only recent completion window to avoid stale historical errors.
    tail -n 400 '$log' | grep -E '=== DONE ===|FAILED|VM:|RDP:|Step [0-9]+ completed|syntax error|unbound variable|INACCESSIBLE_BOOT_DEVICE' | tail -n 20
  "
  echo

done
