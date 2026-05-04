#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# test_migrated_vms.sh — Ping + SSH verification for all migrated FLEX VMs
# Run from operator laptop:  bash test_migrated_vms.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SSH_KEY="$HOME/.ssh/id_rsa"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o BatchMode=yes"

# ── VM List: name | floating_ip | ssh_user ────────────────────────────────────
declare -a VMS=(
  "ospc2flex-alma8-20260420|50.56.158.15|almalinux"
  "ospc2flex-alma8-20260420-v2|50.56.159.162|almalinux"
  "ospc2flex-dbian12-20260420|50.56.158.89|debian"
  "ospc2flex-rocky8-20260420|50.56.158.38|root"
  "ospc2flex-Alma9-20260420|50.56.158.185|almalinux"
  "ospc2flex-dbian10new-20260420|50.56.157.118|debian"
  "flex-rocky9-20260420|50.56.159.149|root"
  "ospc2flex-rocky9-20260420|50.56.158.53|root"
  "flex-u20-20260420|50.56.158.63|ubuntu"
  "flex-debian11new-20260420|50.56.159.66|debian"
  "ospc2flex-u20-20260420|50.56.159.81|ubuntu"
  "flex-debian11new-20260420-v2|50.56.159.168|debian"
  "ospc2flex-debian11new-20260420|50.56.157.230|debian"
)

# ── Colors ────────────────────────────────────────────────────────────────────
G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; C='\033[0;36m'; N='\033[0m'

printf "\n${C}═══════════════════════════════════════════════════════════════════${N}\n"
printf "${C}  OSPC→FLEX Migration Verification — %d VMs${N}\n" "${#VMS[@]}"
printf "${C}═══════════════════════════════════════════════════════════════════${N}\n\n"
printf "%-38s %-18s %-12s %-8s %-8s %s\n" "VM NAME" "FLOATING IP" "USER" "PING" "SSH" "OS INFO"
printf "%-38s %-18s %-12s %-8s %-8s %s\n" "------" "----------" "----" "----" "---" "-------"

PASS=0; FAIL=0; PARTIAL=0

for entry in "${VMS[@]}"; do
  IFS='|' read -r name fip user <<< "$entry"
  
  # ── Ping test ──
  if ping -c 2 -W 3 "$fip" >/dev/null 2>&1; then
    ping_status="${G}✅${N}"
    ping_ok=1
  else
    ping_status="${R}❌${N}"
    ping_ok=0
  fi

  # ── SSH test (try specified user, fallback to root) ──
  ssh_status="${R}❌${N}"
  ssh_ok=0
  os_info="-"
  
  for try_user in "$user" "root" "cloud-user"; do
    result=$(ssh $SSH_OPTS "${try_user}@${fip}" 'cat /etc/os-release 2>/dev/null | head -1; hostname' 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$result" ]; then
      ssh_status="${G}✅${N}"
      ssh_ok=1
      os_info=$(echo "$result" | head -1 | sed 's/PRETTY_NAME=//;s/"//g')
      if [ "$try_user" != "$user" ]; then
        ssh_status="${Y}✅${N}"
        user="${try_user}*"
      fi
      break
    fi
  done

  # ── Print result ──
  printf "%-38s %-18s %-12s " "$name" "$fip" "$user"
  printf "${ping_status}      ${ssh_status}      ${N}"
  printf "%s\n" "$os_info"

  if [ $ping_ok -eq 1 ] && [ $ssh_ok -eq 1 ]; then
    ((PASS++))
  elif [ $ping_ok -eq 1 ] || [ $ssh_ok -eq 1 ]; then
    ((PARTIAL++))
  else
    ((FAIL++))
  fi
done

printf "\n${C}═══════════════════════════════════════════════════════════════════${N}\n"
printf "  ${G}✅ PASS: %d${N}   ${Y}⚠ PARTIAL: %d${N}   ${R}❌ FAIL: %d${N}   Total: %d\n" "$PASS" "$PARTIAL" "$FAIL" "${#VMS[@]}"
printf "${C}═══════════════════════════════════════════════════════════════════${N}\n"
