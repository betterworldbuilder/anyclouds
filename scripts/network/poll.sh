#!/bin/bash
# poll.sh — Check all current NBD migration jobs on jumphost
# Usage:
#   ./poll.sh              # one-shot status
#   ./poll.sh 5            # repeat every 5 minutes until done
#   ./poll.sh watch        # repeat every 30 seconds (live watch)

JUMPHOST=23.253.159.193
JUMPHOST_USER=ubuntu
SSH_KEY=~/.ssh/id_rsa
WORK=/mnt/migration/ospc2flex_image

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

check_once() {
  NOW=$(TZ='Asia/Bangkok' date '+%Y-%m-%d %H:%M:%S')
  echo ""
  echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  JUMPHOST MIGRATION STATUS — $NOW${NC}"
  echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"

  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 \
    "${JUMPHOST_USER}@${JUMPHOST}" bash << 'REMOTE'

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
WORK=/mnt/migration/ospc2flex_image

echo ""
echo -e "${BOLD}── Active qemu-img downloads ─────────────────────────${NC}"
ACTIVE_QEMU=$(pgrep -a qemu-img 2>/dev/null | grep "convert" || true)
if [ -n "$ACTIVE_QEMU" ]; then
  echo "$ACTIVE_QEMU" | while IFS= read -r line; do
    QCOW=$(echo "$line" | grep -oE '/mnt/[^ ]+\.qcow2' || true)
    LABEL=$(basename "$QCOW" .qcow2 2>/dev/null || echo "?")
    SZ=$(stat -c%s "$QCOW" 2>/dev/null || echo 0)
    SZ_MB=$((SZ/1024/1024))
    echo -e "  ${GREEN}▶${NC} $LABEL — ${BOLD}${SZ_MB}MB${NC} and growing..."
  done
else
  echo -e "  ${YELLOW}No active qemu-img downloads${NC}"
fi

echo ""
echo -e "${BOLD}── Active mig_worker_v4 processes ────────────────────${NC}"
WORKERS=$(pgrep -a mig_worker_v4 2>/dev/null || true)
if [ -n "$WORKERS" ]; then
  echo "$WORKERS" | while IFS= read -r line; do
    echo "  ▶ $line"
  done
else
  echo -e "  ${YELLOW}No workers running${NC}"
fi

echo ""
echo -e "${BOLD}── qcow2 files on disk ───────────────────────────────${NC}"
if ls "$WORK"/*.qcow2 &>/dev/null; then
  ls -lh "$WORK"/*.qcow2 2>/dev/null | awk '{print "  "$5"  "$9}' | while IFS= read -r line; do
    QCOW=$(echo "$line" | awk '{print $2}')
    LABEL=$(basename "$QCOW" .qcow2)
    SZ=$(echo "$line" | awk '{print $1}')
    # Check sentinel files
    REPAIRED=""
    CONVERTED=""
    [ -f "${QCOW}.repaired"  ] && REPAIRED=" ${GREEN}[repaired]${NC}"
    [ -f "${QCOW}.converted" ] && CONVERTED=" ${CYAN}[converted]${NC}"
    echo -e "  ${SZ}  ${LABEL}${REPAIRED}${CONVERTED}"
  done
else
  echo -e "  ${YELLOW}No qcow2 files found${NC}"
fi

echo ""
echo -e "${BOLD}── Latest log lines per VM ───────────────────────────${NC}"
for LOG in /tmp/mig_*.log; do
  [ -f "$LOG" ] || continue
  LABEL=$(basename "$LOG" .log | sed 's/^mig_//')
  LAST=$(tail -3 "$LOG" 2>/dev/null | grep -v '^$' | tail -1)
  MODIFIED=$(stat -c %Y "$LOG" 2>/dev/null || echo 0)
  NOW_TS=$(date +%s)
  AGE=$(( (NOW_TS - MODIFIED) ))
  if [ "$AGE" -lt 300 ]; then
    COLOR="$GREEN"   # active < 5 min
  elif [ "$AGE" -lt 1800 ]; then
    COLOR="$YELLOW"  # stale 5-30 min
  else
    COLOR="$RED"     # dead > 30 min
  fi
  echo -e "  ${COLOR}[$LABEL]${NC} ${LAST}"
done

echo ""
echo -e "${BOLD}── Results file (/tmp/par_results_v4.txt) ───────────${NC}"
if [ -f /tmp/par_results_v4.txt ] && [ -s /tmp/par_results_v4.txt ]; then
  cat /tmp/par_results_v4.txt | while IFS='|' read -r STATUS LABEL FIP VM_ID IMG_ID EXTRA; do
    case "$STATUS" in
      OK)        echo -e "  ${GREEN}✅ $LABEL — FIP=$FIP VM=$VM_ID${NC}" ;;
      FAIL_*)    echo -e "  ${RED}❌ $LABEL — $STATUS${NC}" ;;
      *)         echo -e "  $STATUS|$LABEL|$FIP|$VM_ID" ;;
    esac
  done
else
  echo -e "  ${YELLOW}(empty — no completed migrations yet)${NC}"
fi
REMOTE
}

MODE=${1:-once}

if [ "$MODE" = "watch" ]; then
  echo "Watching every 30 seconds — Ctrl+C to stop"
  while true; do check_once; sleep 30; done
elif [[ "$MODE" =~ ^[0-9]+$ ]]; then
  echo "Polling every ${MODE} minutes — Ctrl+C to stop"
  while true; do check_once; sleep $(( MODE * 60 )); done
else
  check_once
fi
