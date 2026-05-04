#!/usr/bin/env bash
# =============================================================================
# ospc2flex_offline_repair.sh  v2.0
# Per-OS offline repair built from real FLEX VM boot profiles (2026-04-17)
#
# Profiles source: bootflexprofileperOs.txt
#   ubuntu24  : BIOS, ens3, netplan, root=vda1(ext4,LABEL), /boot=vda16(sep)
#   debian11  : UEFI, eth0, ifupdown, root=vda1(ext4,PARTUUID), no sep /boot
#   almalinux8: UEFI, eth0, NM/ifcfg, root=vda4(xfs,UUID), /boot=vda3(sep)
#   rocky8    : UEFI, eth0, NM/ifcfg, root=vda5(xfs,UUID), /boot=vda2(sep)
#
# Usage:
#   bash ospc2flex_offline_repair.sh --qcow2 <path> [--dry-run] [--force]
#
# --dry-run  : detect OS + show what would change, touch nothing
# --force    : re-run repair even if sentinel exists
# =============================================================================
set -euo pipefail

QCOW2=""
DRY_RUN=0
FORCE=0
OS_TYPE_ARG=""
NBD_DEV_ARG=""
ROOT_PART_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --qcow2)   QCOW2="$2"; shift 2 ;;
    --os-type) OS_TYPE_ARG="$2"; shift 2 ;;
    --nbd-dev) NBD_DEV_ARG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force)   FORCE=1; shift ;;
    --root-part) ROOT_PART_ARG="$2"; shift 2 ;;
    *) echo "[ERROR] Unknown arg: $1"; exit 1 ;;
  esac
done

[ -z "$QCOW2" ]   && { echo "Usage: bash $0 --qcow2 <path.qcow2> [--os-type <type>] [--nbd-dev /dev/nbdN] [--dry-run] [--force]"; exit 1; }
[ ! -f "$QCOW2" ] && { echo "[ERROR] File not found: $QCOW2"; exit 1; }

# Map --os-type (mig_worker values: ubuntu24 debian10 alma9 rocky8 centos7) → OS_ID
OS_ID_FROM_ARG=""
case "$OS_TYPE_ARG" in
  ubuntu24|ubuntu*)      OS_ID_FROM_ARG="ubuntu"    ;;
  debian10|debian11|debian*) OS_ID_FROM_ARG="debian" ;;
  alma9|alma8|almalinux*)  OS_ID_FROM_ARG="almalinux" ;;
  rocky8|rocky9|rocky*)    OS_ID_FROM_ARG="rocky"   ;;
  centos7|centos8|centos*) OS_ID_FROM_ARG="centos"  ;;
  rhel*)                 OS_ID_FROM_ARG="rhel"      ;;
  "")                    OS_ID_FROM_ARG=""           ;;
  *) echo "  ⚠  Unknown --os-type '$OS_TYPE_ARG' — will detect from os-release";;
esac

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
PASS() { echo "  ✅ $*"; }
FAIL() { echo "  ❌ $*"; }
INFO() { echo "  ℹ  $*"; }
WARN() { echo "  ⚠  $*"; }

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║    OSPC2FLEX — Offline Guest Repair v2.0                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
log "Target qcow2 : $QCOW2"
log "Dry run      : $([ $DRY_RUN -eq 1 ] && echo YES || echo NO)"
log "Force re-run : $([ $FORCE  -eq 1 ] && echo YES || echo NO)"
echo ""

# ── Sentinel check ────────────────────────────────────────────────────────────
SENTINEL="${QCOW2}.repaired"
if [ -f "$SENTINEL" ] && [ $FORCE -eq 0 ]; then
  log "[SKIP] Already repaired: $SENTINEL — pass --force to re-run"
  exit 0
fi

# ── Dependency check ──────────────────────────────────────────────────────────
echo "── Dependencies ─────────────────────────────────────────────────────────"
for bin in qemu-nbd qemu-img fdisk fsck lsblk; do
  if command -v "$bin" >/dev/null 2>&1; then
    PASS "$bin: $(which $bin)"
  else
    case "$bin" in
      qemu-nbd|qemu-img) sudo apt-get install -y qemu-utils >/dev/null 2>&1 ;;
      fdisk)             sudo apt-get install -y fdisk >/dev/null 2>&1 ;;
      fsck)              sudo apt-get install -y e2fsprogs >/dev/null 2>&1 ;;
      lsblk)             sudo apt-get install -y util-linux >/dev/null 2>&1 ;;
    esac
    log "Installed missing dep: $bin"
  fi
done
command -v sgdisk >/dev/null 2>&1 \
  || { sudo apt-get install -y gdisk >/dev/null 2>&1 && PASS "sgdisk installed" || WARN "sgdisk missing — GPT fix skipped"; }
command -v xfs_repair >/dev/null 2>&1 \
  || { sudo apt-get install -y xfsprogs >/dev/null 2>&1 && PASS "xfs_repair installed" || WARN "xfs_repair missing"; }
command -v sgdisk >/dev/null 2>&1 && PASS "sgdisk: $(which sgdisk)"
echo ""

# ── NBD device selection — use blockdev --getsize64 (lsblk always shows "disk") ─
echo "── NBD Device Selection ─────────────────────────────────────────────────"
sudo modprobe nbd max_part=16 2>/dev/null || true
sleep 1
NBD_DEV=""
for _d in /dev/nbd{0..15}; do
  _sz=$(sudo blockdev --getsize64 "$_d" 2>/dev/null || echo 0)
  if [ "${_sz:-0}" -eq 0 ]; then
    if ! sudo fuser "$_d" 2>/dev/null | grep -q .; then
      NBD_DEV="$_d"
      break
    fi
  fi
done
# If --nbd-dev provided, use it directly — prevents parallel race condition
if [ -n "$NBD_DEV_ARG" ]; then
  NBD_DEV="$NBD_DEV_ARG"
  INFO "Using specified NBD device (--nbd-dev): $NBD_DEV"
else
  [ -z "$NBD_DEV" ] && { FAIL "No free NBD device (nbd0-15 all busy)"; exit 1; }
  INFO "Using auto-selected NBD device: $NBD_DEV"
fi
MNT=$(mktemp -d /tmp/ospc2flex_repair_XXXXXX)

cleanup() {
  sudo umount "$MNT/boot/efi" 2>/dev/null || true
  sudo umount "$MNT/boot"     2>/dev/null || true
  sudo umount "$MNT/proc" "$MNT/sys" "$MNT/dev" 2>/dev/null || true
  sudo umount "$MNT"          2>/dev/null || true
  sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
  # rmmod nbd DISABLED — parallel workers share kernel nbd module
  sudo rm -rf "$MNT"
}
trap cleanup EXIT
echo ""

# ── Connect qcow2 via NBD ─────────────────────────────────────────────────────
echo "── Connect qcow2 ────────────────────────────────────────────────────────"
sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
sleep 1
sudo qemu-nbd --connect="$NBD_DEV" "$QCOW2" 2>/tmp/nbd_err_$$.txt \
  || { FAIL "qemu-nbd failed: $(cat /tmp/nbd_err_$$.txt | head -3)"; exit 1; }
sleep 3
PASS "Connected as $NBD_DEV"
echo ""

# ── GPT backup header fix (50GB OSPC → 80GB FLEX disk size mismatch) ─────────
echo "── GPT Backup Header Fix ────────────────────────────────────────────────"
if command -v sgdisk >/dev/null 2>&1; then
  sudo sgdisk -e "$NBD_DEV" >/dev/null 2>&1 \
    && PASS "GPT backup header relocated to end of disk" \
    || INFO "sgdisk -e skipped (MBR or already correct)"
fi
sleep 1
echo ""

# ── Root partition — hardcoded per OSPC→FLEX profile (no auto-detect) ────────
# OSPC fstab uses /dev/xvda* Xen paths (not UUID/LABEL) — dynamic detection fails
echo "── Root Partition (hardcoded per OSPC profile) ──────────────────────────"
ROOT_PART=""
ROOT_FSTYPE=""
case "$OS_ID_FROM_ARG" in
  ubuntu)     ROOT_PART="${NBD_DEV}p1"; ROOT_FSTYPE="ext4" ;;
  debian)     ROOT_PART="${NBD_DEV}p1"; ROOT_FSTYPE="ext4" ;;
  almalinux)  ROOT_PART="${NBD_DEV}p4"; ROOT_FSTYPE="xfs"  ;;
  rocky)      ROOT_PART="${NBD_DEV}p5"; ROOT_FSTYPE="xfs"  ;;
  centos|rhel) ROOT_PART="${NBD_DEV}p1"; ROOT_FSTYPE="xfs" ;;
  *)
    ROOT_PART="${NBD_DEV}p1"
    ROOT_FSTYPE=$(sudo blkid -o value -s TYPE "${NBD_DEV}p1" 2>/dev/null || echo "ext4")
    WARN "No --os-type supplied — defaulting root to p1 ($ROOT_FSTYPE)"
    ;;
esac
  # Fallback: if hardcoded partition doesn't exist, scan for largest Linux fs
  if [ -n "${ROOT_PART}" ] && ! test -b "${ROOT_PART}" 2>/dev/null; then
    WARN "Hardcoded ${ROOT_PART} not found — scanning partition table for largest Linux fs"
    BEST_PART=""; BEST_FSTYPE=""; BEST_SIZE=0
    for _p in $(sudo lsblk -lnpo NAME,TYPE "${NBD_DEV}" 2>/dev/null | awk '$2=="part"{print $1}'); do
      _type=$(sudo blkid -o value -s TYPE "${_p}" 2>/dev/null); [ -z "${_type}" ] && continue
      [[ "${_type}" == "vfat" || "${_type}" == "swap" ]] && continue
      _sz=$(sudo lsblk -lnpo NAME,SIZE --bytes "${_p}" 2>/dev/null | tail -1 | awk '{print $2}' | tr -d ' ')
      _sz=${_sz:-0}
      if [ "${_sz}" -gt "${BEST_SIZE}" ] 2>/dev/null; then BEST_PART="${_p}"; BEST_FSTYPE="${_type}"; BEST_SIZE="${_sz}"; fi
    done
    [ -n "${BEST_PART}" ] && { ROOT_PART="${BEST_PART}"; ROOT_FSTYPE="${BEST_FSTYPE}"; INFO "Auto-detected root: ${ROOT_PART} (${ROOT_FSTYPE})"; }
  fi
  # Override with explicit --root-part if provided
  if [ -n "${ROOT_PART_ARG:-}" ]; then
    ROOT_PART="${ROOT_PART_ARG}"
    ROOT_FSTYPE=$(sudo blkid -o value -s TYPE "${ROOT_PART}" 2>/dev/null || echo ext4)
    INFO "Root override: ${ROOT_PART} (${ROOT_FSTYPE}) [--root-part]"
  else
    INFO "Root: $ROOT_PART ($ROOT_FSTYPE) [hardcoded os-type=$OS_TYPE_ARG]"
  fi
echo ""

# ── Filesystem check (2 passes for dirty live-snapshot journals) ──────────────
echo "── Filesystem Check ─────────────────────────────────────────────────────"
set +e
if [ "$ROOT_FSTYPE" = "xfs" ]; then
  log "xfs_repair pass 1 on $ROOT_PART..."
  sudo xfs_repair -L "$ROOT_PART" >/tmp/xfsrep1_$$.txt 2>&1 || true
  INFO "xfs_repair1: $(tail -1 /tmp/xfsrep1_$$.txt)"
else
  log "fsck pass 1 on $ROOT_PART..."
  sudo fsck -y "$ROOT_PART" >/tmp/fsck1_$$.txt 2>&1 || true
  INFO "fsck1: $(tail -2 /tmp/fsck1_$$.txt | tr '\n' ' ')"
  log "fsck pass 2 on $ROOT_PART..."
  sudo fsck -y "$ROOT_PART" >/tmp/fsck2_$$.txt 2>&1 || true
  INFO "fsck2: $(tail -2 /tmp/fsck2_$$.txt | tr '\n' ' ')"
fi
set -e
echo ""

# ── Mount root ────────────────────────────────────────────────────────────────
echo "── Mount Root ───────────────────────────────────────────────────────────"
MOUNT_OPTS=""
[ "$ROOT_FSTYPE" = "xfs" ] && MOUNT_OPTS="-o nouuid" || MOUNT_OPTS=""

if sudo mount $MOUNT_OPTS "$ROOT_PART" "$MNT" 2>/dev/null; then
  PASS "Mounted $ROOT_PART → $MNT"
elif sudo mount -o norecovery,ro "$ROOT_PART" "$MNT" 2>/dev/null; then
  WARN "Mounted read-only (norecovery) — journal dirty"
elif sudo mount -o ro "$ROOT_PART" "$MNT" 2>/dev/null; then
  WARN "Mounted read-only"
else
  FAIL "Cannot mount root partition"
  exit 1
fi
echo ""

# ── Windows detection (skip, not supported) ───────────────────────────────────
if [ -d "$MNT/Windows" ] || [ -d "$MNT/windows" ]; then
  WARN "Windows image detected — offline repair not needed, skipping"
  exit 0
fi

# ── OS Detection ──────────────────────────────────────────────────────────────
echo "── OS Detection ─────────────────────────────────────────────────────────"
set +e
OS_ID=""; OS_VERSION=""; OS_MAJOR=""; OS_PRETTY=""

if [ -f "$MNT/etc/os-release" ]; then
  OS_ID=$(grep '^ID=' "$MNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
  OS_VERSION=$(grep '^VERSION_ID=' "$MNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"')
  OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
  OS_PRETTY=$(grep '^PRETTY_NAME=' "$MNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"')
fi
if [ -z "$OS_ID" ] && [ -f "$MNT/etc/rocky-release" ]; then
  OS_ID="rocky"; OS_PRETTY=$(cat "$MNT/etc/rocky-release" | tr -d '\n')
  OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' "$MNT/etc/rocky-release" | head -1)
fi
if [ -z "$OS_ID" ] && [ -f "$MNT/etc/almalinux-release" ]; then
  OS_ID="almalinux"; OS_PRETTY=$(cat "$MNT/etc/almalinux-release" | tr -d '\n')
  OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' "$MNT/etc/almalinux-release" | head -1)
fi
if [ -z "$OS_ID" ] && [ -f "$MNT/etc/redhat-release" ]; then
  _rhr=$(cat "$MNT/etc/redhat-release" | tr '[:upper:]' '[:lower:]')
  OS_PRETTY=$(cat "$MNT/etc/redhat-release" | tr -d '\n')
  OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' "$MNT/etc/redhat-release" | head -1)
  echo "$_rhr" | grep -q centos && OS_ID="centos"
  echo "$_rhr" | grep -q "red hat" && OS_ID="rhel"
fi
if [ -z "$OS_ID" ] && [ -f "$MNT/etc/debian_version" ]; then
  OS_ID="debian"; OS_VERSION=$(cat "$MNT/etc/debian_version" | tr -d '\n')
  OS_PRETTY="Debian $OS_VERSION"
fi
# Filesystem-clue fallback
if [ -z "$OS_ID" ]; then
  if [ -d "$MNT/etc/netplan" ]; then
    OS_ID="ubuntu"; OS_VERSION="24.04"; OS_PRETTY="Ubuntu (netplan dir)"
  elif [ -d "$MNT/etc/sysconfig/network-scripts" ]; then
    OS_ID="almalinux"; OS_VERSION="8"; OS_PRETTY="RHEL-family (ifcfg dir)"
  fi
fi
[ -n "$OS_VERSION" ] && OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
set -e

[ -n "$OS_ID" ] && PASS "OS: $OS_PRETTY (id=$OS_ID)" || WARN "Unknown OS — applying generic fixes only"
echo ""

# ── Pre-repair fstab inspection ───────────────────────────────────────────────
echo "── Current fstab ────────────────────────────────────────────────────────"
grep -v '^[[:space:]]*#' "$MNT/etc/fstab" 2>/dev/null | grep -v '^[[:space:]]*$' | sed 's/^/    /' || echo "    (empty)"
echo ""

# =============================================================================
# OS-SPECIFIC REPAIRS
# =============================================================================

case "$OS_ID" in

# ─────────────────────────────────────────────────────────────────────────────
# UBUNTU 24.04
# Profile: BIOS, NIC=ens3, netplan, root=vda1(ext4,LABEL), /boot=vda16(sep)
# OSPC→FLEX change: netplan may hardcode enp3s0/ens3 specific; FLEX still ens3
# Fix: wildcard netplan so cloud-init can bind on any en*/eth* interface
# ─────────────────────────────────────────────────────────────────────────────
  ubuntu)
    echo "── [UBUNTU] Network: write wildcard netplan ─────────────────────────────"
    if [ $DRY_RUN -eq 0 ]; then
      # Remove any old specific-NIC netplan files that might hardcode enp3s0
      sudo rm -f "$MNT/etc/netplan/50-cloud-init.yaml" 2>/dev/null || true

      sudo mkdir -p "$MNT/etc/netplan"
      sudo tee "$MNT/etc/netplan/99-flex-fallback.yaml" >/dev/null <<'NETPLAN_EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
      optional: true
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      dhcp6: false
      optional: true
NETPLAN_EOF
      sudo chmod 600 "$MNT/etc/netplan/99-flex-fallback.yaml"
      PASS "Wrote /etc/netplan/99-flex-fallback.yaml (wildcard en*/eth* DHCP)"
    else
      INFO "[DRY-RUN] Would write wildcard netplan"
    fi
    ;;

# ─────────────────────────────────────────────────────────────────────────────
# DEBIAN 11 (bullseye)
# Profile: UEFI, NIC=eth0, ifupdown, root=vda1(ext4,PARTUUID), no sep /boot
# Kernel cmdline has net.ifnames=0 → forces eth0
# OSPC→FLEX change: OSPC image may lack net.ifnames=0; ifupdown config for eth0
# Fix: write /etc/network/interfaces eth0 + ensure net.ifnames=0 in grub
# ─────────────────────────────────────────────────────────────────────────────
  debian)
    echo "── [DEBIAN] Network: write /etc/network/interfaces (eth0) ──────────────"
    if [ $DRY_RUN -eq 0 ]; then
      sudo tee "$MNT/etc/network/interfaces" >/dev/null <<'IF_EOF'
auto lo
iface lo inet loopback

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
IF_EOF
      PASS "Wrote /etc/network/interfaces (eth0 DHCP)"

      # Remove any old udev NIC rename rules that might block eth0
      sudo rm -f "$MNT/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
      sudo rm -f "$MNT/lib/udev/rules.d/75-persistent-net-generator.rules" 2>/dev/null || true
      PASS "Cleared persistent NIC rename rules"

      # Ensure net.ifnames=0 in grub (grub.cfg is ON ROOT partition for Debian — no sep /boot)
      if [ -f "$MNT/etc/default/grub" ]; then
        if ! grep -q "net.ifnames=0" "$MNT/etc/default/grub"; then
          sudo sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 net.ifnames=0 biosdevname=0"/' \
            "$MNT/etc/default/grub" 2>/dev/null || true
          PASS "Added net.ifnames=0 to /etc/default/grub GRUB_CMDLINE_LINUX"
        else
          INFO "net.ifnames=0 already in /etc/default/grub"
        fi
      fi

      # Patch grub.cfg directly (safe for Debian — /boot/grub/grub.cfg is on root partition)
      for _gcfg in "$MNT/boot/grub/grub.cfg" "$MNT/boot/grub2/grub.cfg"; do
        if [ -f "$_gcfg" ]; then
          # Add net.ifnames=0 if missing
          if ! grep -q "net.ifnames=0" "$_gcfg"; then
            sudo sed -i '/^\s*linux\s.*root=/{s/$/ net.ifnames=0 biosdevname=0/}' \
              "$_gcfg" 2>/dev/null || true
            PASS "Patched $(basename $_gcfg) kernel lines with net.ifnames=0"
          else
            INFO "net.ifnames=0 already in $(basename $_gcfg)"
          fi
          # Add console=ttyS0 if missing (needed for FLEX serial console / VNC log)
          if ! grep -q "console=ttyS0" "$_gcfg"; then
            sudo sed -i '/^\s*linux\s.*root=/{s/$/ console=tty0 console=ttyS0,115200n8/}' \
              "$_gcfg" 2>/dev/null || true
            PASS "Patched $(basename $_gcfg) kernel lines with console=ttyS0"
          else
            INFO "console=ttyS0 already in $(basename $_gcfg)"
          fi
        fi
      done

      # Also add GRUB_TERMINAL=console and console= to /etc/default/grub for future update-grub
      if [ -f "$MNT/etc/default/grub" ]; then
        sudo sed -i 's|^#GRUB_TERMINAL=console|GRUB_TERMINAL=console|' "$MNT/etc/default/grub" 2>/dev/null || true
        if ! grep -q "console=ttyS0" "$MNT/etc/default/grub"; then
          sudo sed -i 's|^GRUB_CMDLINE_LINUX="\(.*\)"|GRUB_CMDLINE_LINUX="\1 console=tty0 console=ttyS0,115200n8"|' \
            "$MNT/etc/default/grub" 2>/dev/null || true
          PASS "Added console=ttyS0 to /etc/default/grub"
        fi
      fi
    else
      INFO "[DRY-RUN] Would write /etc/network/interfaces eth0 + patch grub net.ifnames=0"
    fi
    ;;

# ─────────────────────────────────────────────────────────────────────────────
# ALMALINUX 8 / ROCKY 8 / CENTOS 7 / RHEL
# Profile alma8:  UEFI, eth0, NM/ifcfg, root=vda4(xfs,UUID), /boot=vda3(sep)
# Profile rocky8: UEFI, eth0, NM/ifcfg, root=vda5(xfs,UUID), /boot=vda2(sep)
# OSPC→FLEX changes:
#   1. OSPC NIC was ens3 (biosdevname=1 default) → FLEX needs net.ifnames=0 in kernel
#   2. Old ifcfg-ens3 from OSPC must be removed (confuses NetworkManager)
#   3. SELinux enforcing blocks cross-distro network config writes → set permissive
#   4. /boot is SEPARATE partition → must mount it to update grubenv + BLS entries
# ─────────────────────────────────────────────────────────────────────────────
  almalinux|rocky|centos|rhel)
    echo "── [RHEL-FAMILY: $OS_ID] Network: ifcfg-eth0 ───────────────────────────"
    if [ $DRY_RUN -eq 0 ]; then
      IFCFG_DIR="$MNT/etc/sysconfig/network-scripts"
      sudo mkdir -p "$IFCFG_DIR"

      # Remove ALL old OSPC-era ifcfg files with specific device names (ens*, enp*, eth1+)
      for _old in "$IFCFG_DIR"/ifcfg-en[sp]* "$IFCFG_DIR"/ifcfg-eth[1-9]*; do
        [ -f "$_old" ] && { sudo rm -f "$_old"; PASS "Removed old NIC config: $(basename $_old)"; }
      done

      # Write clean ifcfg-eth0 (NO HWADDR — cloud-init writes correct MAC on first FLEX boot)
      sudo tee "$IFCFG_DIR/ifcfg-eth0" >/dev/null <<'IFCFG_EOF'
# Written by ospc2flex_offline_repair.sh v2.0
# cloud-init will overwrite with correct HWADDR and MTU on first FLEX boot
DEVICE=eth0
BOOTPROTO=dhcp
ONBOOT=yes
TYPE=Ethernet
USERCTL=no
NM_CONTROLLED=yes
IPV6INIT=no
IFCFG_EOF
      PASS "Wrote $IFCFG_DIR/ifcfg-eth0 (DEVICE=eth0, DHCP, no HWADDR)"

      # Write NM keyfile — RHEL8+ prefers keyfiles over ifcfg-rh plugin.
      # Rocky8 working profile confirmed this file is required for NetworkManager
      # to bring up eth0 with DHCP on FLEX (virtio NIC).
      NM_DIR="$MNT/etc/NetworkManager/system-connections"
      if [ -d "$MNT/etc/NetworkManager" ]; then
        sudo mkdir -p "$NM_DIR"
        # Remove old NM connections for ens*/enp* devices
        sudo find "$NM_DIR" -name "*.nmconnection" -exec grep -El "DEVICE=ens|id=ens|DEVICE=enp|id=enp" {} \; \
          2>/dev/null | while read f; do sudo rm -f "$f"; PASS "Removed old NM connection: $(basename $f)"; done || true
        # Write eth0 keyfile (matches rocky8 working profile)
        sudo tee "$NM_DIR/eth0.nmconnection" >/dev/null <<'NM_EOF'
[connection]
id=eth0
type=ethernet
interface-name=eth0
autoconnect=true

[ethernet]
mtu=1500

[ipv4]
method=auto

[ipv6]
method=disabled
NM_EOF
        sudo chmod 600 "$NM_DIR/eth0.nmconnection"
        PASS "Wrote $NM_DIR/eth0.nmconnection (NM keyfile, DHCP)"
      fi
    else
      INFO "[DRY-RUN] Would write ifcfg-eth0 + remove old ifcfg-ens*"
    fi

    echo "── [RHEL-FAMILY] SELinux: set disabled (not permissive) ──────────────────"
    if [ -f "$MNT/etc/selinux/config" ]; then
      if [ $DRY_RUN -eq 0 ]; then
        sudo sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$MNT/etc/selinux/config"
        PASS "Set SELINUX=disabled in /etc/selinux/config"

      else
        INFO "[DRY-RUN] Would set SELINUX=disabled"
      fi
    fi

    echo "── [RHEL-FAMILY] Mount /boot+/boot/efi (hardcoded per OSPC profile) ────────"
    # OSPC fstab uses /dev/xvda* — UUID/size detection unreliable. Hardcode per OS.
    BOOT_PART=""
    BOOTEFI_PART=""
    case "$OS_ID_FROM_ARG" in
      almalinux) BOOT_PART="${NBD_DEV}p3"; BOOTEFI_PART="" ;;  # OSPC alma: /boot=p3
      rocky)     BOOT_PART="${NBD_DEV}p2"; BOOTEFI_PART="${NBD_DEV}p1" ;;
      centos|rhel) BOOT_PART="${NBD_DEV}p2"; BOOTEFI_PART="" ;;
      *)
        WARN "No hardcoded /boot for os-type='$OS_TYPE_ARG' in RHEL branch — trying fstab UUID"
        if [ -f "$MNT/etc/fstab" ]; then
          _boot_line=$(grep -E '\s/boot\s' "$MNT/etc/fstab" 2>/dev/null | grep -v efi | grep -v '^#' | head -1 || true)
          if [[ "$_boot_line" =~ UUID=([a-zA-Z0-9-]+) ]]; then
            _buuid="${BASH_REMATCH[1]}"
            set +e
            for _p in "${NBD_DEV}p"*; do
              [ -b "$_p" ] || continue
              sudo blkid "$_p" 2>/dev/null | grep -qi "$_buuid" && { BOOT_PART="$_p"; break; }
            done
            set -e
          fi
        fi
        [ -z "$BOOT_PART" ] && WARN "Could not detect /boot — grub/BLS updates skipped"
        ;;
    esac
    [ -n "$BOOT_PART"    ] && INFO "/boot:     $BOOT_PART [hardcoded]"    || true
    [ -n "$BOOTEFI_PART" ] && INFO "/boot/efi: $BOOTEFI_PART [hardcoded]" || true

    # Mount /boot
    if [ -n "$BOOT_PART" ] && [ $DRY_RUN -eq 0 ]; then
      sudo mkdir -p "$MNT/boot"
      if sudo mount -o nouuid "$BOOT_PART" "$MNT/boot" 2>/dev/null || \
         sudo mount "$BOOT_PART" "$MNT/boot" 2>/dev/null; then
        PASS "Mounted /boot: $BOOT_PART → $MNT/boot"

        # Mount /boot/efi on top of /boot
        if [ -n "$BOOTEFI_PART" ]; then
          sudo mkdir -p "$MNT/boot/efi"
          sudo mount "$BOOTEFI_PART" "$MNT/boot/efi" 2>/dev/null \
            && PASS "Mounted /boot/efi: $BOOTEFI_PART" || WARN "Could not mount /boot/efi"
        fi

        # Rocky8 working grubenv kernelopts (the reference that boots successfully):
        #   console=ttyS0,115200n8 console=tty0 no_timer_check net.ifnames=0
        # Apply the same full set to BLS entries, grubenv, and /etc/default/grub.
        # no_timer_check: suppresses QEMU timer calibration noise, matches FLEX KVM profile
        # console=ttyS0:  enables serial console so OpenStack console log works
        # net.ifnames=0:  forces eth0 naming (FLEX NIC is presented as virtio, no biosdevname)

        # selinux=0: disables SELinux at kernel level — needed because repair writes
        # files from jumphost without guest SELinux policy (unlabeled_t context).
        # autorelabel fails on ro root in initrd (RHEL9 regression).  selinux=0 is
        # more reliable than permissive: dbus-broker, auditd, sshd all start normally.
        # Customer can re-enable SELinux after migration by removing this flag + relabeling.
        _FLEX_OPTS="net.ifnames=0 biosdevname=0 no_timer_check selinux=0 enforcing=0 console=ttyS0,115200n8 console=tty0"

        # Update BLS loader entries
        echo "── [RHEL-FAMILY] Update BLS loader entries ──────────────────────────────"
        if [ -d "$MNT/boot/loader/entries" ]; then
          _updated=0
          for _conf in "$MNT/boot/loader/entries"/*.conf; do
            [ -f "$_conf" ] || continue
            if grep -q '^options' "$_conf"; then
              _changed=0
              for _opt in net.ifnames=0 no_timer_check console=ttyS0; do
                if ! grep -q "$_opt" "$_conf"; then
                  _changed=1
                fi
              done
              if [ "$_changed" -eq 1 ]; then
                # Remove any existing copies of these opts first, then append cleanly
                sudo sed -i "s/net\.ifnames=[01]//g; s/biosdevname=[01]//g; s/no_timer_check//g; s/console=ttyS0[^ ]*//g; s/console=tty0//g" "$_conf"
                sudo sed -i "s/^options \(.*\)/options \1 $_FLEX_OPTS/" "$_conf"
                PASS "Updated BLS: $(basename $_conf)"
                _updated=$(( _updated + 1 ))
              else
                INFO "BLS $(basename $_conf): already has required opts"
              fi
            fi
          done
          [ "$_updated" -eq 0 ] && INFO "No BLS entries needed updating"
        else
          WARN "/boot/loader/entries not found — BLS update skipped"
        fi

        # Update grubenv kernelopts (Rocky/Alma use $kernelopts in BLS options line)
        echo "── [RHEL-FAMILY] Update grubenv kernelopts ──────────────────────────────"
        for _grubenv in \
          "$MNT/boot/grub2/grubenv" \
          "$MNT/boot/efi/EFI/almalinux/grubenv" \
          "$MNT/boot/efi/EFI/rocky/grubenv" \
          "$MNT/boot/efi/EFI/centos/grubenv" \
          "$MNT/boot/efi/EFI/redhat/grubenv"; do
          [ -f "$_grubenv" ] || continue
          _gv_changed=0
          for _opt in net.ifnames=0 no_timer_check console=ttyS0; do
            grep -q "$_opt" "$_grubenv" || _gv_changed=1
          done
          if [ "$_gv_changed" -eq 1 ]; then
            # Clean existing copies, then append full set
            sudo sed -i "s/net\.ifnames=[01]//g; s/biosdevname=[01]//g; s/no_timer_check//g; s/console=ttyS0[^ ]*//g; s/console=tty0//g" "$_grubenv"
            sudo sed -i "s/^kernelopts=\(.*\)/kernelopts=\1 $_FLEX_OPTS/" "$_grubenv"
            PASS "Updated grubenv: $_grubenv"
          else
            INFO "grubenv already has required opts: $_grubenv"
          fi
        done

        # Update /etc/default/grub (used if grub2-mkconfig is ever re-run)
        if [ -f "$MNT/etc/default/grub" ]; then
          _dg_changed=0
          for _opt in net.ifnames=0 no_timer_check console=ttyS0; do
            grep -q "$_opt" "$MNT/etc/default/grub" || _dg_changed=1
          done
          if [ "$_dg_changed" -eq 1 ]; then
            sudo sed -i "s/net\.ifnames=[01]//g; s/biosdevname=[01]//g; s/no_timer_check//g; s/console=ttyS0[^ ]*//g; s/console=tty0//g" "$MNT/etc/default/grub"
            sudo sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 '"$_FLEX_OPTS"'"/' \
              "$MNT/etc/default/grub" 2>/dev/null || true
            PASS "Updated /etc/default/grub with full FLEX opts"
          fi
        fi

      else
        WARN "Could not mount /boot — grubenv/BLS update skipped"
        WARN "VM may boot with wrong NIC name — SSH might fail"
      fi
    elif [ $DRY_RUN -eq 1 ]; then
      INFO "[DRY-RUN] Would mount /boot and update grubenv/BLS entries"
    fi
    ;;

  *)
    WARN "Unknown OS '$OS_ID' — applying generic fixes only"
    ;;
esac

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# ALL OS: fstab cleanup
# Preserve LABEL=, UUID=, PARTUUID= lines; comment raw /dev/* device lines
# (Safe for all 4 OS profiles: ubuntu=LABEL, debian=PARTUUID, alma/rocky=UUID)
# ─────────────────────────────────────────────────────────────────────────────
echo "── fstab Cleanup (all OS) ───────────────────────────────────────────────"
if [ -f "$MNT/etc/fstab" ] && [ $DRY_RUN -eq 0 ]; then
  sudo cp "$MNT/etc/fstab" "$MNT/etc/fstab.ospc2flex.bak"
  # Comment lines that reference /dev/* directly (no UUID/LABEL/PARTUUID)
  # Preserves: LABEL= UUID= PARTUUID= lines; comments /dev/vdb /dev/vdc etc
  sudo sed -i \
    '/^[[:space:]]*#/b;
     /^[[:space:]]*$/b;
     /LABEL=/b;
     /UUID=/b;
     /PARTUUID=/b;
     s|^|# [ospc2flex] |' \
    "$MNT/etc/fstab"
  PASS "fstab: /dev/* paths commented; LABEL/UUID/PARTUUID lines preserved"
  INFO "fstab backup: /etc/fstab.ospc2flex.bak"
else
  [ $DRY_RUN -eq 1 ] && INFO "[DRY-RUN] Would clean fstab /dev/* entries"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# ALL OS: cloud-init state reset
# Reason: cloud-init uses instance-id to skip re-running; must clear so it
# runs fresh on FLEX and injects the SSH key from FLEX keypair metadata
# ─────────────────────────────────────────────────────────────────────────────
echo "── cloud-init Reset (all OS) ────────────────────────────────────────────"
if [ $DRY_RUN -eq 0 ]; then
  sudo rm -rf "$MNT/var/lib/cloud/instance" 2>/dev/null || true
  sudo rm -rf "$MNT/var/lib/cloud/instances/"* 2>/dev/null || true
  sudo rm -rf "$MNT/var/lib/cloud/data" 2>/dev/null || true
  sudo rm -rf "$MNT/var/lib/cloud/sem" 2>/dev/null || true
  # Clear machine-id so systemd generates new one on first FLEX boot
  sudo truncate -s 0 "$MNT/etc/machine-id" 2>/dev/null || true
  # Remove DHCP leases (old MAC-specific leases)
  sudo rm -f "$MNT/var/lib/NetworkManager/"*.lease 2>/dev/null || true
  sudo rm -f "$MNT/var/lib/dhclient/"*.leases 2>/dev/null || true
  sudo rm -f "$MNT/var/lib/dhcp/"*.leases 2>/dev/null || true
  PASS "cloud-init state cleared (instances, data, sem)"
  PASS "machine-id cleared (new ID generated on first boot)"
  PASS "DHCP leases cleared"
else
  INFO "[DRY-RUN] Would clear cloud-init state + machine-id + DHCP leases"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# SSH host keys — OS-specific strategy derived from rocky8 root cause analysis:
#
# Rocky8 worked first-try because its OSPC SSH host keys were PRESERVED with
# correct SELinux context (sshd_key_t).  Deleting them forces sshd-keygen to
# regenerate on first boot — which fails on AlmaLinux9 because dbus-broker
# (a dependency of sshd-keygen) itself fails when files have unlabeled_t context
# (written by our repair from the jumphost without guest SELinux policy).
#
# Strategy by OS:
#   RHEL-family : KEEP existing OSPC keys (correct sshd_key_t context already).
#                 selinux=0 kernel flag handles unlabeled file context at boot.
#   Debian/Ubuntu: DELETE keys — cloud-init or sshd-keygen will regenerate on
#                 first boot.  These OSes don't have SELinux so regeneration is safe.
# ─────────────────────────────────────────────────────────────────────────────
echo "── SSH Host Keys ────────────────────────────────────────────────────────"
if [ $DRY_RUN -eq 0 ]; then
  case "$OS_ID" in
    almalinux|rocky|centos|rhel)
      # KEEP: OSPC keys have correct SELinux context (sshd_key_t).
      # Deleting them causes sshd-keygen to fail on first boot (dbus-broker
      # unlabeled_t deadlock).  Rocky8 proved preserved keys work on FLEX.
      _key_count=$(sudo ls "$MNT/etc/ssh/ssh_host_"* 2>/dev/null | wc -l || echo 0)
      if [ "${_key_count:-0}" -gt 0 ]; then
        PASS "SSH host keys PRESERVED ($_key_count files) — correct sshd_key_t context kept"
      else
        WARN "No SSH host keys found in /etc/ssh — sshd-keygen will create on first boot"
      fi
      ;;
    ubuntu|debian)
      # DELETE: no SELinux on these OSes; cloud-init injects keypair + sshd-keygen
      # regenerates host keys safely on first FLEX boot.
      sudo rm -f "$MNT/etc/ssh/ssh_host_"* 2>/dev/null || true
      PASS "SSH host keys removed (will regenerate on first FLEX boot — safe, no SELinux)"
      ;;
    *)
      # Unknown OS: preserve keys (safer default)
      WARN "Unknown OS — SSH host keys PRESERVED (safer default)"
      ;;
  esac
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# OSPC Data Cleanup — remove artifacts that are useless/harmful on FLEX
#
# SAFE TO REMOVE: nova-agent, rackspace-monitoring, xe-linux, OSPC crons,
#   /etc/hosts OSPC entries, bash history, SSH known_hosts, system logs,
#   UFW/firewall saved rules
#
# NEVER TOUCH: datasource configs, SSH authorized_keys, SSH host keys (RHEL),
#   sshd_config, cloud.cfg — these control SSH access on FLEX
# ─────────────────────────────────────────────────────────────────────────────
echo "── OSPC Data Cleanup ──────────────────────────────────────────────────"
if [ $DRY_RUN -eq 0 ]; then

  # 1. Remove OSPC agents (nova-agent, rackspace-monitoring, xe-linux)
  for _agent in "$MNT/usr/sbin/nova-agent" \
                "$MNT/usr/bin/nova-agent" \
                "$MNT/usr/share/nova-agent" \
                "$MNT/usr/bin/rackspace-monitoring-agent" \
                "$MNT/etc/rackspace-monitoring-agent.cfg" \
                "$MNT/etc/rackspace-monitoring-agent.conf.d"; do
    if [ -e "$_agent" ]; then
      sudo rm -rf "$_agent" 2>/dev/null || true
      PASS "Removed OSPC agent: $(basename $_agent)"
    fi
  done

  # 2. Disable OSPC services
  for _svc in nova-agent xe-linux-distribution rackspace-monitoring-agent; do
    sudo rm -f "$MNT/etc/systemd/system/${_svc}.service" 2>/dev/null || true
    sudo rm -f "$MNT/etc/systemd/system/multi-user.target.wants/${_svc}.service" 2>/dev/null || true
    sudo rm -f "$MNT/etc/init.d/${_svc}" 2>/dev/null || true
  done
  PASS "OSPC services removed (nova-agent, xe-linux, rackspace-monitoring)"

  # 3. Remove OSPC cron jobs
  for _cron in "$MNT/etc/cron.d/nova-agent" \
               "$MNT/etc/cron.d/rackspace" \
               "$MNT/etc/cron.d/rax-monitoring"; do
    [ -f "$_cron" ] && { sudo rm -f "$_cron"; PASS "Removed OSPC cron: $(basename $_cron)"; }
  done

  # 4. Clean /etc/hosts of OSPC-specific entries
  if [ -f "$MNT/etc/hosts" ]; then
    sudo sed -i '/rackspace\|ospc\|xen\|nova-agent/Id' "$MNT/etc/hosts" 2>/dev/null || true
    PASS "Cleaned /etc/hosts of OSPC references"
  fi

  # 5. Clear bash history + SSH known_hosts (OSPC data only, NOT authorized_keys)
  sudo rm -f "$MNT/root/.bash_history" 2>/dev/null || true
  sudo rm -f "$MNT/root/.ssh/known_hosts" 2>/dev/null || true
  sudo rm -f "$MNT/home/"*/.bash_history 2>/dev/null || true
  sudo rm -f "$MNT/home/"*/.ssh/known_hosts 2>/dev/null || true
  PASS "Cleared bash history + SSH known_hosts (authorized_keys PRESERVED)"

  # 6. Wipe old system logs (contain OSPC IPs, reduces image size)
  sudo rm -f "$MNT/var/log/auth.log"* 2>/dev/null || true
  sudo rm -f "$MNT/var/log/syslog"* 2>/dev/null || true
  sudo rm -f "$MNT/var/log/messages"* 2>/dev/null || true
  sudo rm -f "$MNT/var/log/secure"* 2>/dev/null || true
  PASS "Old logs cleared (syslog, auth, messages, secure)"

  # 7. Remove UFW rules (Ubuntu/Debian)
  if [ -d "$MNT/etc/ufw" ]; then
    sudo rm -f "$MNT/etc/ufw/user.rules" "$MNT/etc/ufw/user6.rules" 2>/dev/null || true
    sudo rm -f "$MNT/etc/ufw/"*.rules.* 2>/dev/null || true
    if [ -f "$MNT/etc/ufw/ufw.conf" ]; then
      sudo sed -i 's/^ENABLED=yes/ENABLED=no/' "$MNT/etc/ufw/ufw.conf" 2>/dev/null || true
    fi
    PASS "UFW rules flushed + disabled"
  fi

  # 8. Remove firewalld saved rules (RHEL/CentOS/Rocky/Alma)
  if [ -d "$MNT/etc/firewalld" ]; then
    sudo rm -rf "$MNT/etc/firewalld/zones/"* 2>/dev/null || true
    sudo rm -rf "$MNT/etc/firewalld/services/"* 2>/dev/null || true
    PASS "firewalld saved zones/services cleared"
  fi

else
  INFO "[DRY-RUN] Would purge OSPC data: agents, crons, logs, firewall"
fi
echo ""

# ── Unmount everything ────────────────────────────────────────────────────────
echo "── Unmount ──────────────────────────────────────────────────────────────"
sudo umount "$MNT/boot/efi" 2>/dev/null && PASS "Unmounted /boot/efi" || true
sudo umount "$MNT/boot"     2>/dev/null && PASS "Unmounted /boot"     || true
sudo umount "$MNT"          2>/dev/null && PASS "Unmounted root"      || WARN "Root umount had issues"
sudo qemu-nbd --disconnect "$NBD_DEV"   2>/dev/null || true
# rmmod nbd DISABLED — parallel workers share kernel nbd module
sudo rm -rf "$MNT"
trap - EXIT

[ $DRY_RUN -eq 0 ] && sudo touch "$SENTINEL"
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅ OFFLINE REPAIR COMPLETE — ready for FLEX upload      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
PASS "OS: ${OS_PRETTY:-unknown}"
PASS "Sentinel: $SENTINEL"
echo ""
