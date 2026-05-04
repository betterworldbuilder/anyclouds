#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  OSPC→FLEX Jumphost Bootstrap Script
#  Installs all dependencies for the migration pipeline on a fresh Ubuntu VM.
#  Usage:  sudo bash setup_jumphost.sh
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✅ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠️  $*${NC}"; }
fail() { echo -e "  ${RED}❌ $*${NC}"; }

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║    OSPC→FLEX Jumphost Bootstrap v1.0                    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Must be root ──────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  fail "This script must be run as root (sudo bash $0)"
  exit 1
fi

# ── 1. APT packages ──────────────────────────────────────────────────────────
log "Step 1/6: Installing APT packages..."
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq

PACKAGES=(
  qemu-utils        # qemu-nbd, qemu-img — NBD mount + image conversion
  gdisk             # sgdisk — GPT backup header repair
  xfsprogs          # xfs_repair — XFS filesystem check (Alma/Rocky)
  python3           # python3 runtime
  python3-pip       # pip for OpenStack CLI
  python3-venv      # virtual environments (if needed)
  openssh-client    # ssh, scp — remote access
  curl              # HTTP fallback for Glance download
  jq                # JSON parsing for OpenStack responses
  parted            # disk partition inspection
  e2fsprogs         # fsck.ext4 — ext4 filesystem repair
  dosfstools        # mkfs.fat — EFI partition handling
  nbd-client        # nbd-client userspace tools
)

for pkg in "${PACKAGES[@]}"; do
  if dpkg -s "$pkg" &>/dev/null; then
    ok "$pkg (already installed)"
  else
    apt-get install -y -qq "$pkg" &>/dev/null && ok "$pkg (installed)" || warn "$pkg (install failed — non-critical)"
  fi
done

# ── 2. OpenStack CLI ─────────────────────────────────────────────────────────
log "Step 2/6: Installing OpenStack CLI..."
if command -v openstack &>/dev/null; then
  OSC_VER=$(openstack --version 2>&1 | head -1)
  ok "openstack CLI already installed: $OSC_VER"
else
  pip3 install --break-system-packages --quiet \
    python-openstackclient \
    python-glanceclient \
    2>/dev/null \
  && ok "openstack CLI installed" \
  || {
    # Fallback: use apt
    apt-get install -y -qq python3-openstackclient &>/dev/null \
    && ok "openstack CLI installed (via apt)" \
    || warn "openstack CLI install failed — manual install needed"
  }
fi

# ── 3. Kernel module: nbd ────────────────────────────────────────────────────
log "Step 3/6: Configuring NBD kernel module..."
modprobe nbd max_part=8 2>/dev/null && ok "nbd module loaded (max_part=8)" || warn "nbd module load failed"

# Persist across reboots
if ! grep -q "^nbd" /etc/modules-load.d/nbd.conf 2>/dev/null; then
  echo "nbd" > /etc/modules-load.d/nbd.conf
  ok "nbd added to /etc/modules-load.d/nbd.conf"
else
  ok "nbd already in /etc/modules-load.d/nbd.conf"
fi

if ! grep -q "max_part=8" /etc/modprobe.d/nbd.conf 2>/dev/null; then
  echo "options nbd max_part=8" > /etc/modprobe.d/nbd.conf
  ok "nbd max_part=8 persisted in /etc/modprobe.d/nbd.conf"
else
  ok "nbd modprobe options already configured"
fi

# ── 4. Storage: auto-detect data volume ──────────────────────────────────────
log "Step 4/6: Checking storage..."
BEST_MOUNT=$(df -P -k | awk 'NR>1 && $1 !~ /tmpfs|udev|devtmpfs|overlay|shm|loop/ && $6 !~ /^[/](boot|run|dev|sys|proc|snap)/ && $6 != "/" { print $4, $6 }' | sort -rn | head -n1 | awk '{print $2}')
if [ -n "$BEST_MOUNT" ]; then
  WORKDIR="$BEST_MOUNT/ospc2flex_image"
  mkdir -p "$WORKDIR"
  FREE=$(df -h "$BEST_MOUNT" | tail -1 | awk '{print $4}')
  ok "Data volume: $BEST_MOUNT ($FREE free) → workspace: $WORKDIR"
else
  WORKDIR="/mnt/migration/ospc2flex_image"
  mkdir -p "$WORKDIR" 2>/dev/null || true
  warn "No external data volume detected. Using $WORKDIR"
  warn "Attach a volume (≥200GB) and mount to /mnt/migration for production use"
fi

# ── 5. SSH key check ─────────────────────────────────────────────────────────
log "Step 5/6: Checking SSH key..."
REAL_USER=${SUDO_USER:-ubuntu}
REAL_HOME=$(eval echo "~$REAL_USER")
if [ -f "$REAL_HOME/.ssh/id_rsa" ]; then
  ok "SSH key found: $REAL_HOME/.ssh/id_rsa"
else
  warn "No SSH key at $REAL_HOME/.ssh/id_rsa"
  warn "Copy your key: scp ~/.ssh/id_rsa $REAL_USER@<this-host>:~/.ssh/id_rsa"
fi

# ── 6. Verification ──────────────────────────────────────────────────────────
log "Step 6/6: Verification..."
echo ""
PASS=0; TOTAL=0
verify() {
  local name=$1; local cmd=$2
  TOTAL=$((TOTAL+1))
  if eval "$cmd" &>/dev/null; then
    ok "$name"; PASS=$((PASS+1))
  else
    fail "$name"
  fi
}

verify "qemu-nbd"    "command -v qemu-nbd"
verify "qemu-img"    "command -v qemu-img"
verify "fdisk"       "command -v fdisk"
verify "fsck"        "command -v fsck"
verify "lsblk"       "command -v lsblk"
verify "sgdisk"      "command -v sgdisk"
verify "openstack"   "command -v openstack"
verify "python3"     "command -v python3"
verify "ssh"         "command -v ssh"
verify "scp"         "command -v scp"
verify "curl"        "command -v curl"
verify "jq"          "command -v jq"
verify "nbd module"  "lsmod | grep -q nbd"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
if [ $PASS -eq $TOTAL ]; then
  echo "║  ✅ BOOTSTRAP COMPLETE — $PASS/$TOTAL checks passed         ║"
else
  echo "║  ⚠️  BOOTSTRAP DONE — $PASS/$TOTAL checks passed             ║"
fi
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Next steps:"
echo "    1. Copy SSH key:  scp ~/.ssh/id_rsa $REAL_USER@<this-host>:~/.ssh/"
echo "    2. Copy scripts:  scp ospc2flex_offline_repair.sh $REAL_USER@<this-host>:/tmp/"
echo "    3. Verify:        sudo bash /tmp/test_offline_repair_dryrun.sh"
echo "    4. Verify:        sudo bash /tmp/test_nbd_inline_repair.sh"
echo ""
