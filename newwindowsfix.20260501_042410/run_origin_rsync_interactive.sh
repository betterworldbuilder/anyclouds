#!/usr/bin/env bash
set -Eeuo pipefail

echo "============================================================"
echo "LAPTOP -> ORIGIN -> TARGET RSYNC TOOL"
echo "Interactive target username/IP entry"
echo "Shows DONE + copied file list per target"
echo "============================================================"
echo

read -rp "Origin server IP: " ORIGIN_IP
read -rp "Origin username [ubuntu]: " ORIGIN_USER
ORIGIN_USER="${ORIGIN_USER:-ubuntu}"

read -rp "Source dir on origin [/home/${ORIGIN_USER}/]: " SRC_DIR
SRC_DIR="${SRC_DIR:-/home/${ORIGIN_USER}/}"

read -rp "Destination dir on targets [/home/ubuntu/]: " DST_DIR
DST_DIR="${DST_DIR:-/home/ubuntu/}"

read -rp "Parallel jobs [4]: " JOBS
JOBS="${JOBS:-4}"

read -rp "Mirror delete extra files on targets? (0=no, 1=yes) [0]: " DELETE_MODE
DELETE_MODE="${DELETE_MODE:-0}"

if [[ -z "$ORIGIN_IP" ]]; then
  echo "[ERROR] Origin IP is required."
  exit 1
fi

if ! ssh-add -l >/dev/null 2>&1; then
  echo "[ERROR] No SSH key loaded in your laptop agent."
  echo 'Run these first:'
  echo '  eval "$(ssh-agent -s)"'
  echo '  ssh-add ~/.ssh/id_rsa'
  exit 1
fi

declare -A SEEN
TARGET_LINES=()

echo
echo "Enter target username/IP pairs."
echo "Leave IP empty when finished."
echo

while true; do
  read -rp "Target username [ubuntu]: " TUSER
  TUSER="${TUSER:-ubuntu}"
  read -rp "Target IP: " TIP
  [[ -z "$TIP" ]] && break

  KEY="${TUSER}@${TIP}"
  if [[ -n "${SEEN[$KEY]:-}" ]]; then
    echo "[WARN] Duplicate target ignored: $KEY"
    continue
  fi

  SEEN["$KEY"]=1
  TARGET_LINES+=("$KEY")
done

if [[ ${#TARGET_LINES[@]} -eq 0 ]]; then
  echo "[ERROR] At least one target is required."
  exit 1
fi

TMP_TARGETS="$(mktemp)"
for t in "${TARGET_LINES[@]}"; do
  echo "$t" >> "$TMP_TARGETS"
done

REMOTE_TARGET_FILE="/tmp/rsync_targets_$$.txt"

echo
echo "============================================================"
echo "ORIGIN      : ${ORIGIN_USER}@${ORIGIN_IP}"
echo "SOURCE DIR  : ${SRC_DIR}"
echo "DEST DIR    : ${DST_DIR}"
echo "JOBS        : ${JOBS}"
echo "DELETE MODE : ${DELETE_MODE}"
echo "TARGETS     :"
printf '  - %s\n' "${TARGET_LINES[@]}"
echo "============================================================"
echo

scp -o StrictHostKeyChecking=accept-new "$TMP_TARGETS" "${ORIGIN_USER}@${ORIGIN_IP}:${REMOTE_TARGET_FILE}"

ssh -A \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=accept-new \
  "${ORIGIN_USER}@${ORIGIN_IP}" \
  "SRC_DIR='${SRC_DIR}' DST_DIR='${DST_DIR}' JOBS='${JOBS}' DELETE_MODE='${DELETE_MODE}' TARGET_FILE='${REMOTE_TARGET_FILE}' bash -s" <<'REMOTE_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

: "${SRC_DIR:?missing SRC_DIR}"
: "${DST_DIR:?missing DST_DIR}"
: "${JOBS:?missing JOBS}"
: "${DELETE_MODE:?missing DELETE_MODE}"
: "${TARGET_FILE:?missing TARGET_FILE}"

if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
  echo "[ERROR] No SSH agent forwarding detected on origin."
  exit 1
fi

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "[ERROR] Target file not found on origin: $TARGET_FILE"
  exit 1
fi

RSYNC_DELETE=""
[[ "$DELETE_MODE" == "1" ]] && RSYNC_DELETE="--delete"

mkdir -p "$HOME/rsync_logs"

run_one() {
  local target="$1"
  local safe
  safe="$(echo "$target" | tr '@/:' '___')"
  local log="$HOME/rsync_logs/${safe}.log"
  local filelist="$HOME/rsync_logs/${safe}.files.txt"

  : > "$log"
  : > "$filelist"

  echo "[INFO] $(date -Is) Preparing $target"
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    "$target" "mkdir -p '$DST_DIR' && hostname && echo ready" >>"$log" 2>&1

  echo "[INFO] $(date -Is) Syncing $SRC_DIR -> $target:$DST_DIR"
  if rsync -aHAX $RSYNC_DELETE --info=NAME,STATS2,FLIST2 \
      --out-format='%n' \
      -e "ssh -A -o StrictHostKeyChecking=accept-new" \
      "$SRC_DIR" "$target:$DST_DIR" >"$filelist" 2>>"$log"; then

    echo "[INFO] $(date -Is) Verifying $target"
    ssh -o StrictHostKeyChecking=accept-new "$target" \
      "echo Target: \$(hostname); echo Path: '$DST_DIR'; find '$DST_DIR' -type f | wc -l; du -sh '$DST_DIR'" >>"$log" 2>&1

    echo "============================================================"
    echo "[DONE] $target"
    echo "Log file      : $log"
    echo "Copied files  : $filelist"
    echo "Copied count  : $(grep -c . "$filelist" || true)"
    echo "---------------- FILES COPIED ----------------"
    if [[ -s "$filelist" ]]; then
      cat "$filelist"
    else
      echo "(no file-level changes reported by rsync)"
    fi
    echo "============================================================"
  else
    echo "============================================================"
    echo "[ERROR] $target"
    echo "Check log: $log"
    echo "============================================================"
    return 1
  fi
}

export -f run_one
export SRC_DIR DST_DIR RSYNC_DELETE HOME

FAIL=0
while IFS= read -r target; do
  [[ -z "$target" ]] && continue
  if ! printf '%s\n' "$target" | xargs -I{} -P "$JOBS" bash -lc 'run_one "$1"' _ {}; then
    FAIL=1
  fi
done < "$TARGET_FILE"

rm -f "$TARGET_FILE"

if [[ "$FAIL" -ne 0 ]]; then
  echo "[DONE] Completed with failures."
  exit 1
fi

echo
echo "[DONE] All targets processed successfully."
REMOTE_SCRIPT

rm -f "$TMP_TARGETS"
