#!/usr/bin/env bash
set -Eeuo pipefail

echo "============================================================"
echo "ORIGIN -> TARGET HOME COPY TOOL"
echo "This script SSHes to the origin server and runs rsync there."
echo "============================================================"
echo

read -rp "Origin server IP: " ORIGIN_IP
read -rp "Origin username [ubuntu]: " ORIGIN_USER
ORIGIN_USER="${ORIGIN_USER:-ubuntu}"

read -rp "Origin SSH key path on THIS machine [$HOME/.ssh/id_rsa]: " ORIGIN_KEY
ORIGIN_KEY="${ORIGIN_KEY:-$HOME/.ssh/id_rsa}"

read -rp "Target username [ubuntu]: " TARGET_USER
TARGET_USER="${TARGET_USER:-ubuntu}"

read -rp "Target server IPs (space-separated): " TARGET_IPS

read -rp "SSH key path ON ORIGIN SERVER used to reach targets [/home/${ORIGIN_USER}/.ssh/id_rsa]: " ORIGIN_TO_TARGET_KEY
ORIGIN_TO_TARGET_KEY="${ORIGIN_TO_TARGET_KEY:-/home/${ORIGIN_USER}/.ssh/id_rsa}"

read -rp "Source dir on origin [/home/${ORIGIN_USER}/]: " SRC_DIR
SRC_DIR="${SRC_DIR:-/home/${ORIGIN_USER}/}"

read -rp "Target dir on targets [/home/${TARGET_USER}/]: " TARGET_DIR
TARGET_DIR="${TARGET_DIR:-/home/${TARGET_USER}/}"

read -rp "Mirror delete extra files on target? (0=no, 1=yes) [0]: " DELETE_MODE
DELETE_MODE="${DELETE_MODE:-0}"

if [[ -z "$ORIGIN_IP" || -z "$TARGET_IPS" ]]; then
  echo "[ERROR] Origin IP and at least one target IP are required."
  exit 1
fi

if [[ ! -f "$ORIGIN_KEY" ]]; then
  echo "[ERROR] Origin SSH key not found on this machine: $ORIGIN_KEY"
  exit 1
fi

DELETE_FLAG=""
[[ "$DELETE_MODE" == "1" ]] && DELETE_FLAG="--delete"

echo
echo "============================================================"
echo "ORIGIN        : ${ORIGIN_USER}@${ORIGIN_IP}"
echo "SOURCE DIR    : ${SRC_DIR}"
echo "TARGET USER   : ${TARGET_USER}"
echo "TARGET DIR    : ${TARGET_DIR}"
echo "TARGET IPS    : ${TARGET_IPS}"
echo "DELETE MODE   : ${DELETE_MODE}"
echo "============================================================"
echo

ssh -i "$ORIGIN_KEY" \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=accept-new \
  "${ORIGIN_USER}@${ORIGIN_IP}" "bash -s" <<REMOTE_SCRIPT
set -Eeuo pipefail

SRC_DIR='$SRC_DIR'
TARGET_USER='$TARGET_USER'
TARGET_DIR='$TARGET_DIR'
TARGET_IPS='$TARGET_IPS'
ORIGIN_TO_TARGET_KEY='$ORIGIN_TO_TARGET_KEY'
DELETE_FLAG='$DELETE_FLAG'

echo "[INFO] Running on origin: \$(hostname)"
echo "[INFO] Source dir: \$SRC_DIR"
echo "[INFO] Checking source dir..."
test -d "\$SRC_DIR"
du -sh "\$SRC_DIR" || true

if [[ ! -f "\$ORIGIN_TO_TARGET_KEY" ]]; then
  echo "[ERROR] Key not found on origin server: \$ORIGIN_TO_TARGET_KEY"
  exit 1
fi

FAILED=0
for ip in \$TARGET_IPS; do
  echo
  echo "-------------------- TARGET: \$ip --------------------"

  if ! ssh -i "\$ORIGIN_TO_TARGET_KEY" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      "\${TARGET_USER}@\${ip}" \
      "mkdir -p '\${TARGET_DIR}' && echo '[OK] Target ready: \${TARGET_DIR}'"
  then
    echo "[ERROR] Cannot prepare target \$ip"
    FAILED=1
    continue
  fi

  if rsync -aHAX \$DELETE_FLAG --info=progress2 \
      -e "ssh -i \$ORIGIN_TO_TARGET_KEY -o StrictHostKeyChecking=accept-new" \
      "\${SRC_DIR}" \
      "\${TARGET_USER}@\${ip}:\${TARGET_DIR}"
  then
    echo "[OK] Sync completed for \$ip"
    ssh -i "\$ORIGIN_TO_TARGET_KEY" \
      -o StrictHostKeyChecking=accept-new \
      "\${TARGET_USER}@\${ip}" \
      "echo 'Target path: \${TARGET_DIR}'; find '\${TARGET_DIR}' -type f | wc -l; du -sh '\${TARGET_DIR}'" || true
  else
    echo "[ERROR] Sync failed for \$ip"
    FAILED=1
  fi
done

if [[ "\$FAILED" -ne 0 ]]; then
  echo "[DONE] Completed with failures."
  exit 1
fi

echo
echo "[DONE] All targets synced successfully."
REMOTE_SCRIPT
