#!/usr/bin/env bash
set -euo pipefail

JUMPHOST_IP="${JUMPHOST_IP:-23.253.159.193}"
JUMPHOST_USER="${JUMPHOST_USER:-ubuntu}"
JUMPHOST_KEY="${JUMPHOST_KEY:-$HOME/.ssh/id_rsa}"
WORKSPACE_PATH="${WORKSPACE_PATH:-/mnt/migration/ospc2flex_image}"
INTERVAL="${INTERVAL:-300}"
ONCE=0

declare -a JOBS=()

usage() {
  cat <<'EOF'
Usage:
  bash monitor_jumphost_nbd_jobs.sh [--once] [--interval 300] [job1 job2 ...]

Defaults:
  JUMPHOST_IP=23.253.159.193
  JUMPHOST_USER=ubuntu
  JUMPHOST_KEY=~/.ssh/id_rsa
  WORKSPACE_PATH=/mnt/migration/ospc2flex_image
  jobs=debian11new dbian10new dbian12

Examples:
  bash monitor_jumphost_nbd_jobs.sh --once
  bash monitor_jumphost_nbd_jobs.sh --interval 300 debian11new dbian10new dbian12
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)
      ONCE=1
      shift
      ;;
    --interval)
      INTERVAL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      JOBS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#JOBS[@]} -eq 0 ]]; then
  JOBS=(debian11new dbian10new dbian12)
fi

if [[ ! -f "$JUMPHOST_KEY" ]]; then
  echo "[ERROR] SSH key not found: $JUMPHOST_KEY" >&2
  exit 1
fi

SSH_OPTS=(
  -i "$JUMPHOST_KEY"
  -o StrictHostKeyChecking=no
  -o BatchMode=yes
  -o ConnectTimeout=15
)

run_snapshot() {
  local jobs_csv
  jobs_csv=$(IFS=,; echo "${JOBS[*]}")

  ssh "${SSH_OPTS[@]}" "${JUMPHOST_USER}@${JUMPHOST_IP}" \
    "WORKSPACE_PATH=$(printf '%q' "$WORKSPACE_PATH") JOBS_CSV=$(printf '%q' "$jobs_csv") bash -s" <<'REMOTE'
set -euo pipefail

IFS=',' read -r -a JOBS <<< "${JOBS_CSV}"

hr() {
  printf '%*s\n' "${COLUMNS:-90}" '' | tr ' ' '-'
}

printf '[%s] Jumphost=%s Workspace=%s\n' \
  "$(date '+%F %T %Z')" "$(hostname)" "${WORKSPACE_PATH}"
hr

echo "Active conversion processes:"
pgrep -a -f 'mig_worker_v4\.sh|qemu-img convert|qemu-nbd|ssh -N -L' 2>/dev/null || echo "  none"
hr

for job in "${JOBS[@]}"; do
  log="/tmp/mig_${job}.log"
  qcow="${WORKSPACE_PATH}/${job}.qcow2"

  echo "Job: ${job}"

  if [ -f "$qcow" ]; then
    size_bytes=$(stat -c '%s' "$qcow" 2>/dev/null || echo 0)
    size_human=$(numfmt --to=iec --suffix=B "$size_bytes" 2>/dev/null || echo "${size_bytes}B")
    mtime=$(stat -c '%y' "$qcow" 2>/dev/null || echo unknown)
    echo "  qcow2 : ${qcow}"
    echo "  size  : ${size_human} (${size_bytes} bytes)"
    echo "  mtime : ${mtime}"
  else
    echo "  qcow2 : missing (${qcow})"
  fi

  if [ -f "$log" ]; then
    echo "  log   : ${log}"
    echo "  last  : $(tail -n 1 "$log" 2>/dev/null || echo 'empty')"
    echo "  tail  :"
    tail -n 8 "$log" 2>/dev/null | sed 's/^/    /'
  else
    echo "  log   : missing (${log})"
  fi

  echo "  pids  :"
  pgrep -a -f "mig_worker_v4\.sh ${job}|qemu-img convert .*${job}\.qcow2" 2>/dev/null | sed 's/^/    /' || echo "    none"
  hr
done
REMOTE
}

while true; do
  run_snapshot
  [[ "$ONCE" -eq 1 ]] && exit 0
  sleep "$INTERVAL"
done
