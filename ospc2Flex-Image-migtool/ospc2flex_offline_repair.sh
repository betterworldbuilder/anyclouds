#!/usr/bin/env bash
# =============================================================================
# ospc2flex_offline_repair.sh
# Standalone offline guest repair — mounts a qcow2, detects OS, applies repair
# Usage:
#   bash ospc2flex_offline_repair.sh --qcow2 <path> [--dry-run] [--force]
#
# --dry-run  : detect OS + show what WOULD be changed, touch nothing
# --force    : re-run repair even if sentinel exists
# =============================================================================
set -euo pipefail

QCOW2=""
DRY_RUN=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --qcow2)  QCOW2="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force)   FORCE=1; shift ;;
    *) echo "[ERROR] Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$QCOW2" ]; then
  echo "Usage: bash ospc2flex_offline_repair.sh --qcow2 <path.qcow2> [--dry-run] [--force]"
  exit 1
fi
if [ ! -f "$QCOW2" ]; then
  echo "[ERROR] File not found: $QCOW2"
  exit 1
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }
PASS() { echo "  ✅ $*"; }
FAIL() { echo "  ❌ $*"; }
INFO() { echo "  ℹ  $*"; }
WARN() { echo "  ⚠  $*"; }

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║      OSPC2FLEX — Offline Guest Repair Test               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
log "Target qcow2 : $QCOW2"
log "Dry run      : $([ $DRY_RUN -eq 1 ] && echo YES || echo NO)"
log "Force re-run : $([ $FORCE  -eq 1 ] && echo YES || echo NO)"
echo ""

# ── Sentinel check ────────────────────────────────────────────────────────────
SENTINEL="${QCOW2}.repaired"
if [ -f "$SENTINEL" ] && [ $FORCE -eq 0 ]; then
  log "[SKIP] Repair sentinel found: $SENTINEL"
  log "[INFO] Pass --force to re-run repair anyway"
  exit 0
fi

# ── Dependency check ──────────────────────────────────────────────────────────
echo "── Dependency Check ─────────────────────────────────────────────────────"
for bin in qemu-nbd qemu-img fdisk fsck; do
  if command -v $bin >/dev/null 2>&1; then
    PASS "$bin found: $(which $bin)"
  else
    FAIL "$bin NOT found"
    if [[ "$bin" == "qemu-nbd" || "$bin" == "qemu-img" ]]; then
      log "  Installing qemu-utils..."
      sudo apt-get install -y qemu-utils >/dev/null 2>&1 && PASS "qemu-utils installed" || { FAIL "Install failed"; exit 1; }
    fi
  fi
done
echo ""

# ── Mount via NBD ─────────────────────────────────────────────────────────────
echo "── Mount qcow2 via NBD ──────────────────────────────────────────────────"
NBD_DEV=/dev/nbd0
MNT=$(mktemp -d /tmp/ospc2flex_repair_XXXXXX)

cleanup() {
  sudo umount "$MNT" 2>/dev/null || true
  sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
  sudo rmmod nbd 2>/dev/null || true
  sudo rm -rf "$MNT"
}
trap cleanup EXIT

sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
sleep 1
sudo modprobe nbd max_part=8 2>/dev/null || true
sleep 1

if ! sudo qemu-nbd --connect="$NBD_DEV" "$QCOW2" 2>/tmp/nbd_err.txt; then
  FAIL "qemu-nbd connect failed: $(cat /tmp/nbd_err.txt | head -3)"
  exit 1
fi
sleep 3
PASS "qcow2 connected as $NBD_DEV"

# Detect root partition — try fdisk first, then p1, then whole device (no partition table)
ROOT_PART=$(sudo fdisk -l "$NBD_DEV" 2>/dev/null | awk '/Linux filesystem/{print $1; exit}')
if [ -z "$ROOT_PART" ]; then
  if sudo blkid "${NBD_DEV}p1" >/dev/null 2>&1; then
    ROOT_PART="${NBD_DEV}p1"
  else
    ROOT_PART="$NBD_DEV"   # filesystem directly on device (no partition table)
    INFO "No partitions found — trying whole device $NBD_DEV"
  fi
fi
INFO "Root partition: $ROOT_PART"

# Run fsck
log "Running fsck on $ROOT_PART..."
sudo fsck -y "$ROOT_PART" >/tmp/fsck_out.txt 2>&1 || true
FSCK_RESULT=$(tail -2 /tmp/fsck_out.txt 2>/dev/null | tr '\n' ' ')
INFO "fsck: $FSCK_RESULT"

# Mount
if sudo mount "$ROOT_PART" "$MNT" 2>/dev/null; then
  PASS "Mounted $ROOT_PART → $MNT"
elif sudo mount -o norecovery,errors=remount-ro "$ROOT_PART" "$MNT" 2>/dev/null; then
  PASS "Mounted with norecovery flag"
else
  FAIL "Mount failed — cannot repair"
  exit 1
fi
echo ""

# ── OS Detection ──────────────────────────────────────────────────────────────
echo "── OS Detection ─────────────────────────────────────────────────────────"
OS_ID=""
OS_VERSION=""
OS_MAJOR=""
OS_PRETTY=""

if [ -d "$MNT/Windows" ] || [ -d "$MNT/windows" ]; then
  WARN "Windows image detected — offline repair not supported (NTFS)"
  exit 0
fi

set +e

# Method 1: /etc/os-release (may be blank in cloud images)
if [ -f "$MNT/etc/os-release" ]; then
  OS_ID=$(grep '^ID=' "$MNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
  OS_VERSION=$(grep '^VERSION_ID=' "$MNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"')
  OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
  OS_PRETTY=$(grep '^PRETTY_NAME=' "$MNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"')
fi

# Method 2: /etc/lsb-release (Ubuntu fallback)
if [ -z "$OS_ID" ] && [ -f "$MNT/etc/lsb-release" ]; then
  _distro=$(grep '^DISTRIB_ID=' "$MNT/etc/lsb-release" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
  _ver=$(grep '^DISTRIB_RELEASE=' "$MNT/etc/lsb-release" 2>/dev/null | cut -d= -f2 | tr -d '"')
  if [ -n "$_distro" ]; then
    OS_ID="$_distro"; OS_VERSION="$_ver"; OS_MAJOR=$(echo "$_ver" | cut -d. -f1)
    OS_PRETTY="$_distro $_ver (from lsb-release)"
  fi
fi

# Method 3: distro-specific release files
if [ -z "$OS_ID" ]; then
  if [ -f "$MNT/etc/rocky-release" ]; then
    OS_ID="rocky"
    OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' "$MNT/etc/rocky-release" 2>/dev/null | head -1)
    OS_PRETTY=$(cat "$MNT/etc/rocky-release" 2>/dev/null | tr -d '\n')
  elif [ -f "$MNT/etc/almalinux-release" ]; then
    OS_ID="almalinux"
    OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' "$MNT/etc/almalinux-release" 2>/dev/null | head -1)
    OS_PRETTY=$(cat "$MNT/etc/almalinux-release" 2>/dev/null | tr -d '\n')
  elif [ -f "$MNT/etc/redhat-release" ]; then
    _rhr=$(cat "$MNT/etc/redhat-release" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' "$MNT/etc/redhat-release" 2>/dev/null | head -1)
    OS_PRETTY=$(cat "$MNT/etc/redhat-release" 2>/dev/null | tr -d '\n')
    if echo "$_rhr" | grep -q centos; then OS_ID="centos"
    elif echo "$_rhr" | grep -q "red hat"; then OS_ID="rhel"
    fi
  elif [ -f "$MNT/etc/debian_version" ]; then
    OS_ID="debian"
    OS_VERSION=$(cat "$MNT/etc/debian_version" 2>/dev/null | tr -d '\n')
    OS_PRETTY="Debian $OS_VERSION"
  fi
  [ -n "$OS_VERSION" ] && OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
fi

# Method 4: filesystem clues (netplan → ubuntu, ifcfg → rhel family)
if [ -z "$OS_ID" ]; then
  if [ -d "$MNT/etc/netplan" ]; then
    OS_ID="ubuntu"; OS_VERSION="24.04"; OS_PRETTY="Ubuntu (detected via netplan)"
    WARN "OS detected via netplan directory — assuming Ubuntu"
  elif [ -d "$MNT/etc/sysconfig/network-scripts" ]; then
    OS_ID="almalinux"; OS_VERSION="8"; OS_PRETTY="RHEL-family (detected via ifcfg)"
    WARN "OS detected via ifcfg network-scripts — assuming AlmaLinux/RHEL"
  fi
fi

set -e

if [ -n "$OS_ID" ]; then
  PASS "OS detected: $OS_PRETTY"
  INFO "id=$OS_ID  version=$OS_VERSION"
else
  WARN "Could not determine OS — fstab fix only, no network repair"
fi

# Map OS to repair profile
case "$OS_ID" in
  ubuntu)
    PROFILE="flex_repair_template_ubuntu24.yaml"
    REPAIR_TYPE="netplan (enp3s0 DHCP, delete MAC-locked 50-cloud-init.yaml)"
    ;;
  almalinux)
    PROFILE="flex_repair_template_almalinux9.yaml"
    REPAIR_TYPE="ifcfg (delete HWADDR, delete udev MAC rule, restorecon)"
    ;;
  rocky)
    PROFILE="flex_repair_template_rocky8.yaml"
    REPAIR_TYPE="ifcfg (delete HWADDR, delete udev MAC rule, restorecon)"
    ;;
  debian)
    PROFILE="flex_repair_template_debian11.yaml"
    REPAIR_TYPE="ifupdown (delete udev MAC rules, cloud-init handles rest)"
    ;;
  rhel|centos)
    PROFILE="flex_repair_template_almalinux9.yaml"
    REPAIR_TYPE="ifcfg (delete HWADDR, delete udev MAC rule)"
    ;;
  *)
    PROFILE="(none — unknown OS)"
    REPAIR_TYPE="fstab fix only — no network repair template available"
    WARN "Unknown OS '$OS_ID' — only fstab will be fixed"
    ;;
esac

PASS "Repair profile: $PROFILE"
INFO "Repair type  : $REPAIR_TYPE"
echo ""

# ── Pre-repair Inspection ─────────────────────────────────────────────────────
echo "── Pre-repair State ─────────────────────────────────────────────────────"
echo ""
echo "  /etc/fstab (current):"
echo "  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄"
set +e
grep -v '^[[:space:]]*#' "$MNT/etc/fstab" 2>/dev/null | grep -v '^[[:space:]]*$' | sed 's/^/    /' || echo "    (empty)"
set -e
echo ""

# Network config inspection
case "$OS_ID" in
  ubuntu)
    echo "  Netplan files:"
    ls "$MNT/etc/netplan/" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
    if [ -f "$MNT/etc/netplan/50-cloud-init.yaml" ]; then
      WARN "50-cloud-init.yaml present (MAC-locked — will be DELETED)"
    fi
    ;;
  almalinux|rocky|rhel|centos)
    echo "  ifcfg-eth0:"
    cat "$MNT/etc/sysconfig/network-scripts/ifcfg-eth0" 2>/dev/null | sed 's/^/    /' || echo "    (not found)"
    echo ""
    echo "  udev persistent-net rule:"
    cat "$MNT/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null | sed 's/^/    /' || echo "    (not found — good)"
    ;;
  debian)
    echo "  udev persistent-net rules:"
    for f in "$MNT/etc/udev/rules.d/70-persistent-net.rules" "$MNT/etc/udev/rules.d/75-persistent-net-generator.rules"; do
      if [ -f "$f" ]; then
        WARN "$(basename $f) present (MAC-locked — will be DELETED):"
        cat "$f" 2>/dev/null | sed 's/^/    /'
      else
        INFO "$(basename $f) not present"
      fi
    done
    ;;
esac
echo ""

if [ $DRY_RUN -eq 1 ]; then
  echo "── DRY-RUN: Repair Actions That WOULD Be Applied ────────────────────────"
  echo ""
  set +e
  # fstab
  echo "  [fstab] Lines that would be COMMENTED (block device paths):"
  grep -v '^[[:space:]]*#' "$MNT/etc/fstab" 2>/dev/null | grep -v '^[[:space:]]*$' | \
    grep -E '/dev/(vd|sd|xvd|hd)' | sed 's/^/    # [ospc2flex] /' || echo "    (none — fstab already clean)"
  echo ""
  echo "  [fstab] Lines that would be KEPT (LABEL/UUID/PARTUUID):"
  grep -v '^[[:space:]]*#' "$MNT/etc/fstab" 2>/dev/null | grep -v '^[[:space:]]*$' | \
    grep -E '(LABEL=|UUID=|PARTUUID=)' | sed 's/^/    /' || echo "    (none)"
  set -e
  echo ""
  case "$OS_ID" in
    ubuntu)
      echo "  [network] Would DELETE: /etc/netplan/50-cloud-init.yaml"
      echo "  [network] Would WRITE:  /etc/netplan/99-ospc2flex.yaml"
      echo "    network:"
      echo "      version: 2"
      echo "      ethernets:"
      echo "        enp3s0:"
      echo "          dhcp4: true"
      echo "          dhcp6: false"
      ;;
    almalinux|rocky|rhel|centos)
      echo "  [network] Would DELETE: /etc/udev/rules.d/70-persistent-net.rules"
      echo "  [network] Would REWRITE: /etc/sysconfig/network-scripts/ifcfg-eth0"
      echo "    TYPE=Ethernet"
      echo "    BOOTPROTO=dhcp"
      echo "    DEVICE=eth0"
      echo "    ONBOOT=yes"
      echo "    # HWADDR removed (MAC changes after migration)"
      echo "  [selinux] Would run: restorecon /etc/sysconfig/network-scripts/ifcfg-eth0"
      ;;
    debian)
      echo "  [network] Would DELETE: /etc/udev/rules.d/70-persistent-net.rules"
      echo "  [network] Would DELETE: /etc/udev/rules.d/75-persistent-net-generator.rules"
      echo "  [network] cloud-init handles network config at first FLEX boot — nothing else needed"
      ;;
  esac
  echo ""
  PASS "DRY-RUN complete — no changes made"
  exit 0
fi

# ── Apply Repair ──────────────────────────────────────────────────────────────
echo "── Applying Repair ──────────────────────────────────────────────────────"
echo ""

# fstab fix
if [ -f "$MNT/etc/fstab" ]; then
  sudo cp "$MNT/etc/fstab" "$MNT/etc/fstab.ospc2flex.bak"
  sudo sed -i '/^[[:space:]]*#/b; /^[[:space:]]*$/b; /LABEL=/b; /UUID=/b; /PARTUUID=/b; s/^/# [ospc2flex] /' "$MNT/etc/fstab"
  PASS "fstab: kept LABEL=/UUID=/PARTUUID=, commented /dev/* paths"
  echo "  Active fstab entries after repair:"
  grep -v '^[[:space:]]*#' "$MNT/etc/fstab" | grep -v '^[[:space:]]*$' | sed 's/^/    /' || echo "    (none)"
fi
echo ""

# OS-specific network repair
case "$OS_ID" in
  ubuntu)
    sudo rm -f "$MNT/etc/netplan/50-cloud-init.yaml" 2>/dev/null || true
    PASS "Ubuntu: deleted MAC-locked /etc/netplan/50-cloud-init.yaml"
    sudo tee "$MNT/etc/netplan/99-ospc2flex.yaml" >/dev/null <<'NETPLAN_EOF'
network:
  version: 2
  ethernets:
    enp3s0:
      dhcp4: true
      dhcp6: false
NETPLAN_EOF
    PASS "Ubuntu: wrote /etc/netplan/99-ospc2flex.yaml (DHCP on enp3s0)"
    echo "  Netplan files after repair:"
    ls "$MNT/etc/netplan/" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
    ;;

  almalinux|rocky|rhel|centos)
    sudo rm -f "$MNT/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
    PASS "$OS_ID: deleted MAC-locked udev net rule"
    _ifcfg="$MNT/etc/sysconfig/network-scripts/ifcfg-eth0"
    sudo mkdir -p "$(dirname $_ifcfg)"
    sudo tee "$_ifcfg" >/dev/null <<'IFCFG_EOF'
TYPE=Ethernet
BOOTPROTO=dhcp
DEVICE=eth0
ONBOOT=yes
# HWADDR removed by ospc2flex repair (MAC changes after migration)
IFCFG_EOF
    PASS "$OS_ID: ifcfg-eth0 rewritten without HWADDR"
    echo "  ifcfg-eth0 after repair:"
    cat "$_ifcfg" 2>/dev/null | sed 's/^/    /'
    if sudo chroot "$MNT" which restorecon >/dev/null 2>&1; then
      sudo chroot "$MNT" restorecon -v /etc/sysconfig/network-scripts/ifcfg-eth0 2>/dev/null || true
      PASS "$OS_ID: SELinux context restored on ifcfg-eth0"
    fi
    ;;

  debian)
    sudo rm -f "$MNT/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
    sudo rm -f "$MNT/etc/udev/rules.d/75-persistent-net-generator.rules" 2>/dev/null || true
    PASS "Debian: deleted MAC-locked udev net rules"
    INFO "Debian: network via ifupdown+cloud-init — no static config needed"
    ;;

  *)
    WARN "Unknown OS '$OS_ID' — fstab fixed but no network repair applied"
    INFO "Run flexvmcheck on a live FLEX VM with this OS to generate a repair template"
    ;;
esac
echo ""

# ── Unmount ───────────────────────────────────────────────────────────────────
sudo umount "$MNT" && PASS "Unmounted cleanly" || WARN "Unmount had issues"
sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
sudo rmmod nbd 2>/dev/null || true
sudo rm -rf "$MNT"
trap - EXIT

touch "$SENTINEL"
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅ OFFLINE REPAIR COMPLETE                              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
PASS "Sentinel written: $SENTINEL"
PASS "Image is ready for FLEX Glance upload"
echo ""
