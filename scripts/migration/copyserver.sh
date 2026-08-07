#!/usr/bin/env bash
set -Eeuo pipefail

# copy_remote_home_to_targets.sh
# Pull /home/<source_user>/ from a remote source server and push it to /home/<target_user>/ on target servers.

TS="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="./copy_remote_home_logs_${TS}"
mkdir -p "$LOG_DIR"

echo "============================================================"
echo "REMOTE HOME COPY TOOL"
echo "This copies /home/<source_user>/ from a source server"
echo "to /home/<target_user>/ on one or more target servers."
echo "============================================================"
echo

read -rp "Source server IP: " SRC_IP
read -rp "Source username [ubuntu]: " SRC_USER
SRC_USER="${SRC_USER:-ubuntu}"

read -rp "Source SSH key path [$HOME/.ssh/id_rsa]: " SRC_KEY
SRC_KEY="${SRC_KEY:-$HOME/.ssh/id_rsa}"

read -rp "Target username [ubuntu]: " DST_USER
DST_USER="${DST_USER:-ubuntu}"

read -rp "Target SSH key path [$HOME/.ssh/id_rsa]: " DST_KEY
DST_KEY="${DST_KEY:-$HOME/.ssh/id_rsa}"

read -rp "Target server IPs (space-separated): " TARGETS

read -rp "Mirror delete extra files on target? (0=no, 1=yes) [0]: " DELETE_MODE
DELETE_MODE="${DELETE_MODE:-0}"

SRC_HOME="/home/${SRC_USER}"
DST_HOME="/home/${DST_USER}"

if [[ -z "$SRC_IP" ]]; then
  echo "[ERROR] Source IP is required."
  exit 1
fi

if [[ -z "$TARGETS" ]]; then
  echo "[ERROR] At least one target IP is required."
  exit 1
fi

if [[ ! -f "$SRC_KEY" ]]; then
  echo "[ERROR] Source SSH key not found: $SRC_KEY"
  exit 1
fi

if [[ ! -f "$DST_KEY" ]]; then
  echo "[ERROR] Target SSH key not found: $DST_KEY"
  exit 1
fi

RSYNC_DELETE=""
[[ "$DELETE_MODE" == "1" ]] && RSYNC_DELETE="--delete"

echo
echo "============================================================"
echo "SOURCE        : ${SRC_USER}@${SRC_IP}:${SRC_HOME}/"
echo "TARGET USER   : ${DST_USER}"
echo "TARGET HOME   : ${DST_HOME}/"
echo "TARGETS       : ${TARGETS}"
echo "DELETE MODE   : ${DELETE_MODE}"
echo "LOG DIR       : ${LOG_DIR}"
echo "============================================================"
echo

echo "[INFO] Checking source connectivity..."
ssh -i "$SRC_KEY" \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=accept-new \
  "${SRC_USER}@${SRC_IP}" \
  "test -d '${SRC_HOME}' && echo '[OK] Source path exists: ${SRC_HOME}' && hostname && du -sh '${SRC_HOME}'" \
  | tee "${LOG_DIR}/source_check.log"

copy_one() {
  local dst_ip="$1"
  local log_file="${LOG_DIR}/${dst_ip}.log"

  {
    echo "[INFO] $(date -Is) Checking target ${dst_ip}"
    ssh -i "$DST_KEY" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      "${DST_USER}@${dst_ip}" \
      "mkdir -p '${DST_HOME}' && echo '[OK] Target ready: ${DST_HOME}'"

    echo "[INFO] $(date -Is) Starting copy: ${SRC_USER}@${SRC_IP}:${SRC_HOME}/ -> ${DST_USER}@${dst_ip}:${DST_HOME}/"

    rsync -aHAX ${RSYNC_DELETE} --info=progress2 \
      -e "ssh -i ${SRC_KEY} -o StrictHostKeyChecking=accept-new" \
      --rsync-path="mkdir -p '${DST_HOME}' && rsync" \
      "${SRC_USER}@${SRC_IP}:${SRC_HOME}/" \
      -e "ssh -i ${DST_KEY} -o StrictHostKeyChecking=accept-new" \
      "${DST_USER}@${dst_ip}:${DST_HOME}/"

    echo "[OK] $(date -Is) Copy completed for ${dst_ip}"

    echo "[INFO] $(date -Is) Remote verification"
    ssh -i "$DST_KEY" \
      -o StrictHostKeyChecking=accept-new \
      "${DST_USER}@${dst_ip}" \
      "echo 'Target path: ${DST_HOME}'; find '${DST_HOME}' -type f | wc -l; du -sh '${DST_HOME}'"
  } | tee "$log_file"
}

FAILED=0
for dst_ip in $TARGETS; do
  echo
  echo "-------------------- TARGET: ${dst_ip} --------------------"
  if ! copy_one "$dst_ip"; then
    echo "[ERROR] Copy failed for ${dst_ip}"
    FAILED=1
  fi
done

echo
echo "============================================================"
if [[ "$FAILED" -eq 0 ]]; then
  echo "[DONE] All target copies completed successfully."
else
  echo "[DONE] Completed with failures. Check logs in ${LOG_DIR}"
fi
echo "============================================================"


