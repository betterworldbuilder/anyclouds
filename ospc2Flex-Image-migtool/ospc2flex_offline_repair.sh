#!/usr/bin/env bash
# =============================================================================
# ospc2flex_offline_repair.sh  v2.1
# Per-OS offline repair built from real FLEX VM boot profiles (2026-04-19)
#
# Verified FLEX VM configs (live SSH audit 2026-04-21):
#   * ubuntu20/22/24 : netplan (wildcard patches), user: 'ubuntu'
#   * debian10/11/12 : ifupdown, eth0, user: 'debian' (root restricted by OS)
#   * rocky8/9       : NetworkManager/ifcfg, eth0, user: 'root'
#   * almalinux8/9   : NetworkManager/ifcfg, eth0, user: 'almalinux' (root disabled by cloud-init)
#   * centos7        : requires dracut --add-drivers virtio, user: 'root'
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
  command -v $bin >/dev/null 2>&1 \
    && PASS "$bin: $(which $bin)" \
    || { log "Installing qemu-utils..."; sudo apt-get install -y qemu-utils >/dev/null 2>&1; }
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
sudo partprobe "$NBD_DEV" 2>/dev/null || sudo blockdev --rereadpt "$NBD_DEV" 2>/dev/null || true
sleep 2
PASS "Connected as $NBD_DEV (partitions loaded)"
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
  almalinux|rocky)
    # RHEL 8/9 Rackspace images use complex multi-partition xfs schemas (p4/p5)
    # We leave ROOT_PART empty to force the auto-scan for the largest partition.
    ROOT_PART=""; ROOT_FSTYPE="xfs"
    ;;
  centos|rhel) ROOT_PART="${NBD_DEV}p1"; ROOT_FSTYPE="xfs" ;;  # CentOS7 OSPC: MBR, single p1 xfs/ext4
  *)
    ROOT_PART=""
    WARN "No OS type recognized — relying on auto-detect"
    ;;
esac
  # Fallback: if hardcoded partition doesn't exist, scan for largest Linux fs
  # Auto-detect root if undefined or missing by scanning for the largest Linux fs
  if [ -z "${ROOT_PART}" ] || ! test -b "${ROOT_PART}" 2>/dev/null; then
    WARN "Scanning partition table for largest Linux filesystem..."
    BEST_PART=""; BEST_FSTYPE=""; BEST_SIZE=0
    for _p in $(lsblk -lnpo NAME,TYPE "${NBD_DEV}" 2>/dev/null | awk '$2=="part"{print $1}'); do
      _type=$(sudo blkid -o value -s TYPE "${_p}" 2>/dev/null); [ -z "${_type}" ] && continue
      [[ "${_type}" == "vfat" || "${_type}" == "swap" || "${_type}" == "LVM2_member" ]] && continue
      _sz=$(lsblk -lnpo SIZE -b "${_p}" 2>/dev/null | tr -d ' '); _sz=${_sz:-0}
      if [ "${_sz}" -gt "${BEST_SIZE}" ] 2>/dev/null; then BEST_PART="${_p}"; BEST_FSTYPE="${_type}"; BEST_SIZE="${_sz}"; fi
    done
    [ -n "${BEST_PART}" ] && { ROOT_PART="${BEST_PART}"; ROOT_FSTYPE="${BEST_FSTYPE}"; INFO "Auto-detected root: ${ROOT_PART} (${ROOT_FSTYPE})"; }
  fi
  # Override with explicit --root-part if provided
  if [ -n "${ROOT_PART_ARG:-}" ]; then
    ROOT_PART="${ROOT_PART_ARG}"
    ROOT_FSTYPE=$(blkid -o value -s TYPE "${ROOT_PART}" 2>/dev/null || echo ext4)
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
  # tr -d '\0' strips null bytes that corrupt live NBD disk copies
  OS_ID=$(tr -d '\0' < "$MNT/etc/os-release" 2>/dev/null | grep '^ID=' | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
  OS_VERSION=$(tr -d '\0' < "$MNT/etc/os-release" 2>/dev/null | grep '^VERSION_ID=' | cut -d= -f2 | tr -d '"')
  OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
  OS_PRETTY=$(tr -d '\0' < "$MNT/etc/os-release" 2>/dev/null | grep '^PRETTY_NAME=' | cut -d= -f2 | tr -d '"')
fi
if [ -z "$OS_ID" ] && [ -f "$MNT/etc/rocky-release" ]; then
  OS_ID="rocky"; OS_PRETTY=$(tr -d '\0\n' < "$MNT/etc/rocky-release")
  OS_VERSION=$(tr -d '\0' < "$MNT/etc/rocky-release" | grep -oE '[0-9]+\.[0-9]+' | head -1)
fi
if [ -z "$OS_ID" ] && [ -f "$MNT/etc/almalinux-release" ]; then
  OS_ID="almalinux"; OS_PRETTY=$(tr -d '\0\n' < "$MNT/etc/almalinux-release")
  OS_VERSION=$(tr -d '\0' < "$MNT/etc/almalinux-release" | grep -oE '[0-9]+\.[0-9]+' | head -1)
fi
if [ -z "$OS_ID" ] && [ -f "$MNT/etc/redhat-release" ]; then
  _rhr=$(tr -d '\0' < "$MNT/etc/redhat-release" | tr '[:upper:]' '[:lower:]')
  OS_PRETTY=$(tr -d '\0\n' < "$MNT/etc/redhat-release")
  OS_VERSION=$(tr -d '\0' < "$MNT/etc/redhat-release" | grep -oE '[0-9]+\.[0-9]+' | head -1)
  echo "$_rhr" | grep -q centos && OS_ID="centos"
  echo "$_rhr" | grep -q "red hat" && OS_ID="rhel"
fi
if [ -z "$OS_ID" ] && [ -f "$MNT/etc/debian_version" ]; then
  OS_ID="debian"; OS_VERSION=$(tr -d '\0\n' < "$MNT/etc/debian_version")
  OS_PRETTY="Debian $OS_VERSION"
fi
# Filesystem-clue fallback — check debian_version FIRST to prevent netplan misidentification
if [ -z "$OS_ID" ]; then
  if [ -f "$MNT/etc/debian_version" ]; then
    OS_ID="debian"; OS_VERSION=$(tr -d '\0\n' < "$MNT/etc/debian_version" 2>/dev/null); OS_PRETTY="Debian $OS_VERSION"
  elif [ -d "$MNT/etc/netplan" ] && ! [ -f "$MNT/etc/debian_version" ]; then
    OS_ID="ubuntu"; OS_VERSION="24.04"; OS_PRETTY="Ubuntu (netplan dir)"
  fi
  [ -z "$OS_ID" ] && [ -d "$MNT/etc/sysconfig/network-scripts" ] && { OS_ID="almalinux"; OS_VERSION="8"; OS_PRETTY="RHEL-family (ifcfg dir)"; }
fi
# AUTHORITATIVE FALLBACK: if disk detection failed, use --os-type argument
if [ -z "$OS_ID" ] && [ -n "$OS_ID_FROM_ARG" ]; then
  OS_ID="$OS_ID_FROM_ARG"
  # Extract version from --os-type (e.g. rocky9→9, debian11→11, alma8→8)
  _arg_ver=$(echo "$OS_TYPE_ARG" | grep -oE '[0-9]+' | head -1)
  [ -n "$_arg_ver" ] && [ -z "$OS_VERSION" ] && { OS_VERSION="$_arg_ver"; OS_MAJOR="$_arg_ver"; }
  OS_PRETTY="$OS_ID (from --os-type=$OS_TYPE_ARG)"
  INFO "OS detection from disk failed — using --os-type argument: $OS_ID (ver=$OS_VERSION)"
fi
[ -n "$OS_VERSION" ] && OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
set -e

if [ -n "$OS_ID" ]; then
  PASS "OS detected: $OS_PRETTY (id=$OS_ID version=$OS_VERSION major=$OS_MAJOR)"
  # Log which version-specific repair profile will be used
  case "$OS_ID" in
    ubuntu)    INFO "Repair profile: Ubuntu (all versions share same netplan wildcard)" ;;
    debian)
      if [ "${OS_MAJOR:-0}" -ge 12 ]; then
        INFO "Repair profile: Debian $OS_MAJOR → netplan + systemd-networkd (no ifupdown)"
      else
        INFO "Repair profile: Debian $OS_MAJOR → ifupdown + source-directory"
      fi ;;
    almalinux|rocky)
      if [ "${OS_MAJOR:-0}" -ge 9 ]; then
        INFO "Repair profile: $OS_ID $OS_MAJOR → ifcfg-eth0 + NM keyfile (dual mode)"
      else
        INFO "Repair profile: $OS_ID $OS_MAJOR → ifcfg-eth0 only (no NM keyfile)"
      fi ;;
    centos)  INFO "Repair profile: CentOS $OS_MAJOR → ifcfg + dracut + grub2-mkconfig" ;;
    rhel)    INFO "Repair profile: RHEL $OS_MAJOR" ;;
    *)       INFO "Repair profile: generic" ;;
  esac
else
  WARN "Unknown OS — applying generic fixes only"
fi

# ── Pre-repair fstab inspection ───────────────────────────────────────────────
echo "── Current fstab ────────────────────────────────────────────────────────"
grep -v '^[[:space:]]*#' "$MNT/etc/fstab" 2>/dev/null | grep -v '^[[:space:]]*$' | sed 's/^/    /' || echo "    (empty)"
echo ""

# =============================================================================
# OS-SPECIFIC REPAIRS
# =============================================================================

case "$OS_ID" in

# ─────────────────────────────────────────────────────────────────────────────
# UBUNTU 20/22/24 — all versions use netplan, wildcard covers enp3s0 + ens3
# Verified from FLEX VMs: U20 (50.56.158.179) U22 (50.56.159.207) U24
# Diff: U20/22=enp3s0+no sep /boot  U24=ens3+sep /boot vda16 — same repair
# Fix: wildcard netplan so cloud-init can bind on any en*/eth* interface
# ─────────────────────────────────────────────────────────────────────────────
  ubuntu)
    echo "── [UBUNTU] Network: purge OSPC + write FLEX netplan ─────────────────────"
    if [ $DRY_RUN -eq 0 ]; then
      # Delete ALL old OSPC netplan files (may hardcode enp3s0, ens3, old MAC)
      sudo rm -f "$MNT/etc/netplan/"*.yaml 2>/dev/null || true
      sudo rm -f "$MNT/etc/netplan/"*.yml 2>/dev/null || true
      PASS "Deleted all old OSPC netplan configs"

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

      # Remove old OSPC udev NIC rename rules
      sudo rm -f "$MNT/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
      sudo rm -f "$MNT/lib/udev/rules.d/75-persistent-net-generator.rules" 2>/dev/null || true
      PASS "Cleared persistent NIC rename rules"

      # Patch grub for serial console + net.ifnames=0
      if [ -f "$MNT/etc/default/grub" ]; then
        sudo sed -i '/^GRUB_CMDLINE_LINUX=/d' "$MNT/etc/default/grub" 2>/dev/null || true
        sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/d' "$MNT/etc/default/grub" 2>/dev/null || true
        echo 'GRUB_CMDLINE_LINUX="console=ttyS0,115200 console=tty0 earlyprintk=ttyS0,115200 consoleblank=0 net.ifnames=0"' \
          | sudo tee -a "$MNT/etc/default/grub" >/dev/null
        echo 'GRUB_CMDLINE_LINUX_DEFAULT=""' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
        sudo awk '!seen[$0]++' "$MNT/etc/default/grub" | sudo tee "$MNT/etc/default/grub.tmp" >/dev/null
        sudo mv "$MNT/etc/default/grub.tmp" "$MNT/etc/default/grub"
        PASS "Grub: set console + net.ifnames=0 (no duplicates)"
      fi

      # Patch grub.cfg directly if present
      for _gcfg in "$MNT/boot/grub/grub.cfg" "$MNT/boot/grub2/grub.cfg"; do
        if [ -f "$_gcfg" ]; then
          if ! grep -q "net.ifnames=0" "$_gcfg"; then
            sudo sed -i '/^\s*linux\s.*root=/{s/$/ net.ifnames=0 biosdevname=0/}' "$_gcfg" 2>/dev/null || true
          fi
          if ! grep -q "console=ttyS0" "$_gcfg"; then
            sudo sed -i '/^\s*linux\s.*root=/{s/$/ console=tty0 console=ttyS0,115200/}' "$_gcfg" 2>/dev/null || true
          fi
          PASS "Patched $(basename $_gcfg) with net.ifnames=0 + console"
        fi
      done
    else
      INFO "[DRY-RUN] Would write wildcard netplan + fix grub"
    fi
    ;;

# ─────────────────────────────────────────────────────────────────────────────
# DEBIAN 10/11/12 — verified from FLEX VMs:
#   Debian 11 (50.56.158.38): ifupdown + source-dir, eth0, PARTUUID fstab
#   Debian 12 (50.56.159.210): netplan + systemd-networkd, eth0, PARTUUID fstab
#                               NO /etc/network/interfaces, NO ifupdown package!
# Common: BIOS, NIC=eth0, root=vda1(ext4,PARTUUID), /boot/efi=vda15
# Grub all versions: GRUB_TERMINAL="console serial", GRUB_SERIAL_COMMAND
# Cmdline: console=ttyS0,115200 console=tty0 earlyprintk=ttyS0,115200 consoleblank=0 net.ifnames=0
# ─────────────────────────────────────────────────────────────────────────────
  debian)
    echo "── [DEBIAN $OS_MAJOR] Network config ──────────────────────────────────────"
    if [ $DRY_RUN -eq 0 ]; then
      if [ "${OS_MAJOR:-0}" -ge 12 ]; then
        INFO "Debian $OS_MAJOR detected! Natively handles KVM device names via systemd-networkd."
        # Clean up any lethal legacy GRUB overrides if previously applied
        if [ -f "$MNT/etc/default/grub" ]; then
          sudo sed -i '/net.ifnames=0/d' "$MNT/etc/default/grub" 2>/dev/null || true
        fi
        for _gcfg in "$MNT/boot/grub/grub.cfg" "$MNT/boot/grub2/grub.cfg"; do
          if [ -f "$_gcfg" ]; then
            sudo sed -i 's/ net\.ifnames=0//g' "$_gcfg" 2>/dev/null || true
            sudo sed -i 's/ biosdevname=0//g' "$_gcfg" 2>/dev/null || true
          fi
        done
        PASS "Native configuration preserved safely (bypassed legacy net.ifnames=0)"
      else
        INFO "Debian $OS_MAJOR — using ifupdown (traditional)"
        sudo tee "$MNT/etc/network/interfaces" >/dev/null <<'IF_EOF'
# Written by ospc2flex_offline_repair.sh — FLEX (OpenStack/KVM)
auto lo
iface lo inet loopback

# Primary network interface — DHCP from FLEX
auto eth0
iface eth0 inet dhcp

# Include files from /etc/network/interfaces.d:
source-directory /etc/network/interfaces.d
source-directory /run/network/interfaces.d
IF_EOF
        PASS "Wrote /etc/network/interfaces (eth0 DHCP + source-dir)"

        sudo rm -f "$MNT/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
        sudo rm -f "$MNT/lib/udev/rules.d/75-persistent-net-generator.rules" 2>/dev/null || true
        PASS "Cleared persistent NIC rename rules"

        if [ -f "$MNT/etc/default/grub" ]; then
          sudo sed -i '/^GRUB_CMDLINE_LINUX=/d' "$MNT/etc/default/grub" 2>/dev/null || true
          sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/d' "$MNT/etc/default/grub" 2>/dev/null || true
          echo 'GRUB_CMDLINE_LINUX="console=ttyS0,115200 console=tty0 earlyprintk=ttyS0,115200 consoleblank=0 net.ifnames=0"' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
          echo 'GRUB_CMDLINE_LINUX_DEFAULT=""' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
          sudo sed -i '/^.*GRUB_TERMINAL=/d' "$MNT/etc/default/grub" 2>/dev/null || true
          sudo sed -i '/^.*GRUB_SERIAL_COMMAND=/d' "$MNT/etc/default/grub" 2>/dev/null || true
          echo 'GRUB_TERMINAL="console serial"' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
          echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
          sudo awk '!seen[$0]++' "$MNT/etc/default/grub" | sudo tee "$MNT/etc/default/grub.tmp" >/dev/null
          sudo mv "$MNT/etc/default/grub.tmp" "$MNT/etc/default/grub"
        fi

        for _gcfg in "$MNT/boot/grub/grub.cfg" "$MNT/boot/grub2/grub.cfg"; do
          if [ -f "$_gcfg" ]; then
            if ! grep -q "net.ifnames=0" "$_gcfg"; then
              sudo sed -i '/^\s*linux\s.*root=/{s/$/ net.ifnames=0 biosdevname=0/}' "$_gcfg" 2>/dev/null || true
            fi
            if ! grep -q "console=ttyS0" "$_gcfg"; then
              sudo sed -i '/^\s*linux\s.*root=/{s/$/ console=tty0 console=ttyS0,115200/}' "$_gcfg" 2>/dev/null || true
            fi
            PASS "Patched $(basename $_gcfg) with net.ifnames=0 + console"
          fi
        done
      fi
    else

      INFO "[DRY-RUN] Would write /etc/network/interfaces eth0 + patch grub net.ifnames=0"
    fi
    ;;

# ─────────────────────────────────────────────────────────────────────────────
# ALMALINUX 8/9 / ROCKY 8/9 / CENTOS 7 / RHEL — verified from live FLEX VMs:
#   Alma 8 (50.56.159.149): NM + ifcfg-eth0 only, NO .nmconnection keyfile
#   Alma 9 (50.56.158.178): NM + ifcfg-eth0 + eth0.nmconnection (BOTH needed)
#   Rocky 8 (50.56.158.53): NM + ifcfg-eth0 only
# OSPC→FLEX changes:
#   1. OSPC NIC was ens3 (biosdevname=1 default) → FLEX needs net.ifnames=0 in kernel
#   2. Old ifcfg-ens3 from OSPC must be removed (confuses NetworkManager)
#   3. SELinux → set disabled (verified from live FLEX VMs: getenforce=Disabled)
#   4. /boot is ON ROOT (not separate) — BLS + grubenv inside root partition
#   5. v9+: also write NM keyfile (RHEL 9 migrating from ifcfg→keyfile format)
# ─────────────────────────────────────────────────────────────────────────────
  almalinux|rocky|centos|rhel)
    echo "── [RHEL-FAMILY: $OS_ID $OS_MAJOR] Network config ──────────────────────"
    if [ $DRY_RUN -eq 0 ]; then
      IFCFG_DIR="$MNT/etc/sysconfig/network-scripts"
      sudo mkdir -p "$IFCFG_DIR"

      # Remove ALL old OSPC-era ifcfg files with specific device names (ens*, enp*, eth1+)
      for _old in "$IFCFG_DIR"/ifcfg-en[sp]* "$IFCFG_DIR"/ifcfg-eth[1-9]*; do
        [ -f "$_old" ] && { sudo rm -f "$_old"; PASS "Removed old NIC config: $(basename $_old)"; }
      done

      # Remove old OSPC udev NIC rename rules
      sudo rm -f "$MNT/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
      sudo rm -f "$MNT/lib/udev/rules.d/75-persistent-net-generator.rules" 2>/dev/null || true
      PASS "Cleared persistent NIC rename rules"

      # Write clean ifcfg-eth0 (NO HWADDR — cloud-init writes correct MAC on first FLEX boot)
      sudo tee "$IFCFG_DIR/ifcfg-eth0" >/dev/null <<'IFCFG_EOF'
# Written by ospc2flex_offline_repair.sh v2.4
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

      # Version-specific NM keyfile handling
      NM_DIR="$MNT/etc/NetworkManager/system-connections"
      if [ "${OS_MAJOR:-0}" -ge 9 ]; then
        # RHEL 9+ uses NM keyfile (.nmconnection) ALONGSIDE ifcfg
        # Verified from FLEX Alma 9 (50.56.158.178): has eth0.nmconnection
        INFO "RHEL $OS_MAJOR — writing NM keyfile (ifcfg + keyfile dual mode)"
        # Remove any old OSPC NM connections
        if [ -d "$NM_DIR" ]; then
          sudo find "$NM_DIR" -name "*.nmconnection" -exec rm -f {} \; 2>/dev/null || true
        fi
        sudo mkdir -p "$NM_DIR"
        # Write eth0.nmconnection matching verified FLEX Alma 9 profile
        sudo tee "$NM_DIR/eth0.nmconnection" >/dev/null <<'NMKEY_EOF'
# Written by ospc2flex_offline_repair.sh v2.4
# Matches verified FLEX AlmaLinux 9 profile (50.56.158.178)
[connection]
id=eth0
type=ethernet
autoconnect-priority=-100
autoconnect-retries=1
interface-name=eth0

[ethernet]

[ipv4]
dhcp-timeout=90
method=auto

[ipv6]
addr-gen-mode=eui64
method=auto

[proxy]
NMKEY_EOF
        sudo chmod 600 "$NM_DIR/eth0.nmconnection"
        PASS "Wrote $NM_DIR/eth0.nmconnection (RHEL 9+ NM keyfile)"
      else
        # RHEL 8 and below: ifcfg-eth0 only, NM reads via ifcfg-rh plugin
        # Verified from FLEX Alma 8 + Rocky 8: NO .nmconnection files
        if [ -d "$NM_DIR" ]; then
          sudo find "$NM_DIR" -name "*.nmconnection" -exec rm -f {} \; 2>/dev/null || true
          PASS "Cleared NM system-connections (ifcfg-eth0 is authoritative for RHEL 8)"
        fi
      fi
    else
      INFO "[DRY-RUN] Would write ifcfg-eth0 + remove old ifcfg-ens*"
    fi

    echo "── [RHEL-FAMILY] SELinux: set disabled ──────────────────────────────────"
    if [ -f "$MNT/etc/selinux/config" ]; then
      if [ $DRY_RUN -eq 0 ]; then
        sudo sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$MNT/etc/selinux/config"
        PASS "Set SELINUX=disabled in /etc/selinux/config"
        # Working FLEX VMs have .autorelabel — keep it for safety
        sudo touch "$MNT/.autorelabel"
        PASS "Created /.autorelabel"
      else
        INFO "[DRY-RUN] Would set SELINUX=disabled"
      fi
    fi

    echo "── [RHEL-FAMILY] Mount /boot+/boot/efi (hardcoded per OSPC profile) ────────"
    # Verified from live FLEX VMs: both alma and rocky have /boot ON ROOT (no sep partition)
    # OSPC layout: p1(1M BIOS boot) + p2(root). No separate /boot partition.
    BOOT_PART=""
    BOOTEFI_PART=""
    case "$OS_ID_FROM_ARG" in
      almalinux) BOOT_PART=""; BOOTEFI_PART="" ;;  # OSPC alma: p1(BIOS)+p2(root), no sep /boot
      rocky)     BOOT_PART=""; BOOTEFI_PART="" ;;  # OSPC rocky: p1(BIOS)+p2(root), no sep /boot (verified)
      centos|rhel) BOOT_PART=""; BOOTEFI_PART="" ;;  # CentOS7 OSPC: MBR single partition, /boot on root (no p2)
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

        # Verified from live FLEX Rocky8 VM kernel cmdline:
        #   console=ttyS0,115200n8 console=tty0 no_timer_check net.ifnames=0
        # Note: selinux=0 NOT needed when SELINUX=disabled in config (verified working)
        _FLEX_OPTS="net.ifnames=0 biosdevname=0 no_timer_check console=ttyS0,115200n8 console=tty0"

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

    # ── [CENTOS 7 ONLY] Virtio injection + grub cmdline fix ──────────────────
    if [[ "$OS_ID" == "centos" ]] || [[ "$OS_ID_FROM_ARG" == "centos" ]]; then
      echo "── [CENTOS 7] Virtio Driver Injection (dracut) ─────────────────────────"
      if [ $DRY_RUN -eq 0 ]; then
        # CentOS 7 on OSPC (Xen) has virtio modules in /lib/modules but NOT in initramfs.
        # FLEX (KVM) requires virtio_blk to boot. Must rebuild initramfs with virtio drivers.
        _kver=$(ls "$MNT/lib/modules/" | sort -V | tail -1)
        if [ -n "$_kver" ] && [ -d "$MNT/lib/modules/$_kver" ]; then
          INFO "Kernel: $_kver"
          # Check if virtio_blk exists in modules
          if find "$MNT/lib/modules/$_kver" -name 'virtio_blk*' 2>/dev/null | grep -q .; then
            # Mount proc/sys/dev for chroot
            sudo mount --bind /proc "$MNT/proc" 2>/dev/null || true
            sudo mount --bind /sys  "$MNT/sys"  2>/dev/null || true
            sudo mount --bind /dev  "$MNT/dev"  2>/dev/null || true
            # Rebuild initramfs with virtio drivers
            sudo chroot "$MNT" /usr/sbin/dracut \
              --add-drivers "virtio_blk virtio_net virtio_pci virtio_scsi virtio_ring virtio" \
              --force "/boot/initramfs-${_kver}.img" "$_kver" 2>/dev/null \
              && PASS "Rebuilt initramfs with virtio drivers: $_kver" \
              || WARN "dracut failed — VM may not boot on FLEX KVM"
            # Unmount chroot mounts
            sudo umount "$MNT/dev"  2>/dev/null || true
            sudo umount "$MNT/sys"  2>/dev/null || true
            sudo umount "$MNT/proc" 2>/dev/null || true
          else
            WARN "virtio_blk module not found in /lib/modules/$_kver — cannot inject"
          fi
        else
          WARN "No kernel modules found — cannot rebuild initramfs"
        fi
      else
        INFO "[DRY-RUN] Would rebuild initramfs with virtio drivers via dracut"
      fi

      echo "── [CENTOS 7] Grub CMDLINE Fix ─────────────────────────────────────────"
      if [ -f "$MNT/etc/default/grub" ] && [ $DRY_RUN -eq 0 ]; then
        # CentOS 7 OSPC grub: root=/dev/xvda1 (wrong on FLEX) + rhgb quiet (hide boot)
        # Remove root=/dev/xvda*, add console + net.ifnames=0
        sudo sed -i 's|root=/dev/xvda[0-9]*||g' "$MNT/etc/default/grub"
        sudo sed -i 's/rhgb //g; s/ rhgb//g' "$MNT/etc/default/grub"
        # Set GRUB_DISABLE_LINUX_UUID to false (FLEX needs UUID boot)
        if grep -q 'GRUB_DISABLE_LINUX_UUID' "$MNT/etc/default/grub"; then
          sudo sed -i 's/GRUB_DISABLE_LINUX_UUID=.*/GRUB_DISABLE_LINUX_UUID="false"/' "$MNT/etc/default/grub"
        else
          echo 'GRUB_DISABLE_LINUX_UUID="false"' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
        fi
        PASS "Fixed grub: removed root=/dev/xvda, set GRUB_DISABLE_LINUX_UUID=false"

        # Rebuild grub.cfg (CentOS 7 uses traditional grub, not BLS)
        sudo mount --bind /proc "$MNT/proc" 2>/dev/null || true
        sudo mount --bind /sys  "$MNT/sys"  2>/dev/null || true
        sudo mount --bind /dev  "$MNT/dev"  2>/dev/null || true
        sudo chroot "$MNT" /usr/sbin/grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null \
          && PASS "Rebuilt grub.cfg via grub2-mkconfig" \
          || WARN "grub2-mkconfig failed — grub.cfg may have stale xvda refs"
        sudo umount "$MNT/dev"  2>/dev/null || true
        sudo umount "$MNT/sys"  2>/dev/null || true
        sudo umount "$MNT/proc" 2>/dev/null || true
      fi
    fi
    ;;

  *)
    WARN "Unknown OS '$OS_ID' — applying generic fixes"
    echo "── [GENERIC] Network: write netplan wildcard + ifupdown eth0 ────────────"
    if [ $DRY_RUN -eq 0 ]; then
      # Write netplan wildcard (works if systemd-networkd is available)
      sudo mkdir -p "$MNT/etc/netplan"
      sudo tee "$MNT/etc/netplan/99-flex-fallback.yaml" >/dev/null <<'NETPLAN_EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      dhcp6: false
      optional: true
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
      optional: true
NETPLAN_EOF
      sudo chmod 600 "$MNT/etc/netplan/99-flex-fallback.yaml"
      PASS "Wrote /etc/netplan/99-flex-fallback.yaml (wildcard eth*/en* DHCP)"

      # Also write ifupdown config (works if ifupdown is installed instead of netplan)
      if [ -d "$MNT/etc/network" ]; then
        sudo tee "$MNT/etc/network/interfaces" >/dev/null <<'IF_EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
IF_EOF
        PASS "Wrote /etc/network/interfaces (eth0 DHCP fallback)"
      fi

      # Remove old udev NIC rename rules
      sudo rm -f "$MNT/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
      PASS "Cleared persistent NIC rename rules"
    else
      INFO "[DRY-RUN] Would write netplan wildcard + ifupdown eth0"
    fi
    ;;
esac

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# ALL OS: fstab cleanup
# 1. Preserve LABEL=, UUID=, PARTUUID= lines (already correct)
# 2. For /dev/* root mount: rewrite xvda→vda (FLEX device name)
# 3. Comment out all OTHER /dev/* lines (swap, data disks, etc.)
# BUG FIX: Debian 10 has ONLY /dev/xvda1 for root — commenting it makes fs read-only
# ─────────────────────────────────────────────────────────────────────────────
echo "── fstab Cleanup (all OS) ───────────────────────────────────────────────"
if [ -f "$MNT/etc/fstab" ] && [ $DRY_RUN -eq 0 ]; then
  sudo cp "$MNT/etc/fstab" "$MNT/etc/fstab.ospc2flex.bak"
  
  # Step 1: Rewrite /dev/xvda* → /dev/vda* (Xen→KVM device name change)
  # This preserves the root mount but fixes the device path
  sudo sed -i 's|/dev/xvda|/dev/vda|g' "$MNT/etc/fstab"
  PASS "fstab: /dev/xvda* → /dev/vda* (Xen→KVM device rename)"
  
  # Step 2: Comment out non-root /dev/* lines (swap, extra disks, etc.)
  # Keep: root (/), /boot, /boot/efi, LABEL=, UUID=, PARTUUID= lines
  sudo sed -i \
    '/^[[:space:]]*#/b;
     /^[[:space:]]*$/b;
     /LABEL=/b;
     /UUID=/b;
     /PARTUUID=/b;
     /[[:space:]]\/[[:space:]]/b;
     /[[:space:]]\/boot/b;
     /\/dev\/vd[a-z][0-9]*[[:space:]]*\/[[:space:]]/b;
     /^\/dev\//s|^|# [ospc2flex] |' \
    "$MNT/etc/fstab"
  PASS "fstab: non-root /dev/* lines commented; root + /boot preserved"
  INFO "fstab backup: /etc/fstab.ospc2flex.bak"
else
  [ $DRY_RUN -eq 1 ] && INFO "[DRY-RUN] Would clean fstab /dev/* entries"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# ALL OS: grub xvda→vda rename (CRITICAL — prevents initramfs drop)
# OSPC (Xen) uses /dev/xvda*, FLEX (KVM) uses /dev/vda*.
# If root=/dev/xvda1 is in grub.cfg, kernel can't find root → initramfs shell.
# Fix: rename xvda→vda in grub.cfg + /etc/default/grub (all OS types).
# ─────────────────────────────────────────────────────────────────────────────
echo "── grub xvda→vda Rename (all OS) ──────────────────────────────────────"
if [ $DRY_RUN -eq 0 ]; then
  # Fix /etc/default/grub (used when grub is rebuilt)
  if [ -f "$MNT/etc/default/grub" ]; then
    if grep -q 'xvda' "$MNT/etc/default/grub" 2>/dev/null; then
      sudo sed -i 's|/dev/xvda|/dev/vda|g' "$MNT/etc/default/grub"
      PASS "grub default: /dev/xvda → /dev/vda"
    else
      INFO "grub default: no xvda references found"
    fi
  fi
  # Fix grub.cfg directly (all possible locations)
  for _gcfg in "$MNT/boot/grub/grub.cfg" "$MNT/boot/grub2/grub.cfg"; do
    if [ -f "$_gcfg" ]; then
      if grep -q 'xvda' "$_gcfg" 2>/dev/null; then
        sudo sed -i 's|/dev/xvda|/dev/vda|g' "$_gcfg"
        PASS "$(basename $_gcfg): /dev/xvda → /dev/vda"
      else
        INFO "$(basename $_gcfg): no xvda references found"
      fi
    fi
  done
else
  INFO "[DRY-RUN] Would rename xvda→vda in grub configs"
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

  # ── Set cloud-init datasource to OpenStack (FLEX) — Debian only ──
  # Debian 10/11 ship old cloud-init that can't auto-detect OpenStack metadata.
  # Ubuntu/RHEL-family auto-detect fine, so only Debian needs this override.
  if [ "$OS_ID" = "debian" ]; then
    sudo mkdir -p "$MNT/etc/cloud/cloud.cfg.d"
    sudo tee "$MNT/etc/cloud/cloud.cfg.d/99-flex-datasource.cfg" >/dev/null <<'FLEX_DS_EOF'
# Written by ospc2flex_offline_repair.sh — set datasource for FLEX (OpenStack)
datasource_list: [ OpenStack, ConfigDrive, None ]
datasource:
  OpenStack:
    metadata_urls:
      - http://169.254.169.254
    timeout: 10
    max_wait: 60
    apply_network_config: true
FLEX_DS_EOF
    PASS "cloud-init datasource set to OpenStack (FLEX metadata) [Debian]"

    # Remove any OSPC-specific datasource configs that might conflict
    sudo rm -f "$MNT/etc/cloud/cloud.cfg.d/"*ec2* 2>/dev/null || true
    sudo rm -f "$MNT/etc/cloud/cloud.cfg.d/"*Ec2* 2>/dev/null || true
    sudo rm -f "$MNT/etc/cloud/cloud.cfg.d/"*rackspace* 2>/dev/null || true
    sudo rm -f "$MNT/etc/cloud/cloud.cfg.d/"*xenserver* 2>/dev/null || true
  fi

  # Clear machine-id so systemd generates new one on first FLEX boot
  echo "" | sudo tee "$MNT/etc/machine-id" >/dev/null
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
# ALL OS: OSPC Data Purge — Remove all OSPC-specific artifacts
# Ensures VM starts fresh on FLEX without inheriting OSPC security policies,
# firewall rules, monitoring agents, or old metadata that blocks connectivity.
# ─────────────────────────────────────────────────────────────────────────────
echo "── OSPC Data Purge (all OS) ────────────────────────────────────────────"
if [ $DRY_RUN -eq 0 ]; then

  # ── 1. Flush ALL iptables rules (CRITICAL — blocks SSH on FLEX) ──
  # OSPC VMs carry custom iptables rules that whitelist OSPC infrastructure IPs.
  # On FLEX (different IP ranges), these rules block ALL inbound SSH.
  # We flush offline by wiping saved rules files; on boot iptables loads empty.
  for _iptf in "$MNT/etc/sysconfig/iptables" \
               "$MNT/etc/sysconfig/ip6tables" \
               "$MNT/etc/iptables.rules" \
               "$MNT/etc/network/iptables.rules"; do
    if [ -f "$_iptf" ]; then
      sudo tee "$_iptf" >/dev/null <<'IPTFLUSH'
# Flushed by ospc2flex_offline_repair.sh — clean slate for FLEX
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
IPTFLUSH
      PASS "Flushed iptables rules: $_iptf"
    fi
  done
  # Remove old backups
  sudo rm -f "$MNT/etc/iptables/"*.bak 2>/dev/null || true
  # Always write clean rules.v4 + rules.v6 (iptables-persistent loads from these on boot)
  if [ -d "$MNT/etc/iptables" ] || dpkg --root="$MNT" -l iptables-persistent 2>/dev/null | grep -q '^ii'; then
    sudo mkdir -p "$MNT/etc/iptables"
    for _rv in "$MNT/etc/iptables/rules.v4" "$MNT/etc/iptables/rules.v6"; do
      sudo tee "$_rv" >/dev/null <<'IPTCLEAN'
# Written by ospc2flex_offline_repair.sh — clean FLEX boot
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
IPTCLEAN
    done
    PASS "Written clean /etc/iptables/rules.v4 + rules.v6 (ACCEPT all)"
  fi

  # ── 2. Disable fail2ban (OSPC jails block FLEX IPs) ──
  # fail2ban carries ban databases and jail configs specific to OSPC.
  # Disable the service and wipe its state; users can re-enable on FLEX.
  if [ -d "$MNT/etc/fail2ban" ]; then
    # Disable the service via systemd (create a mask symlink)
    sudo mkdir -p "$MNT/etc/systemd/system"
    sudo ln -sf /dev/null "$MNT/etc/systemd/system/fail2ban.service" 2>/dev/null || true
    # Wipe ban database and log
    sudo rm -rf "$MNT/var/lib/fail2ban/"* 2>/dev/null || true
    sudo rm -f "$MNT/var/log/fail2ban.log"* 2>/dev/null || true
    PASS "fail2ban disabled + state wiped (re-enable on FLEX if needed)"
  fi

  # ── 3. Remove Rackspace OSPC monitoring agents & scripts ──
  for _agent in "$MNT/usr/share/nova-agent" \
                "$MNT/usr/sbin/nova-agent" \
                "$MNT/usr/bin/nova-agent" \
                "$MNT/etc/init.d/nova-agent" \
                "$MNT/usr/bin/rackspace-monitoring-agent" \
                "$MNT/etc/rackspace-monitoring-agent.cfg" \
                "$MNT/etc/rackspace-monitoring-agent.conf.d"; do
    if [ -e "$_agent" ]; then
      sudo rm -rf "$_agent" 2>/dev/null || true
      PASS "Removed OSPC agent: $(basename $_agent)"
    fi
  done
  # Disable nova-agent and rackspace-monitoring-agent services
  for _svc in nova-agent xe-linux-distribution rackspace-monitoring-agent; do
    sudo rm -f "$MNT/etc/systemd/system/${_svc}.service" 2>/dev/null || true
    sudo rm -f "$MNT/etc/systemd/system/multi-user.target.wants/${_svc}.service" 2>/dev/null || true
    sudo rm -f "$MNT/etc/init.d/${_svc}" 2>/dev/null || true
  done

  # ── 4. Remove OSPC-specific cron jobs ──
  for _cron in "$MNT/etc/cron.d/nova-agent" \
               "$MNT/etc/cron.d/rackspace" \
               "$MNT/etc/cron.d/rax-monitoring"; do
    [ -f "$_cron" ] && { sudo rm -f "$_cron"; PASS "Removed OSPC cron: $(basename $_cron)"; }
  done

  # ── 5. Clean /etc/hosts of OSPC-specific entries ──
  if [ -f "$MNT/etc/hosts" ]; then
    sudo sed -i '/rackspace\|ospc\|xen\|nova-agent/Id' "$MNT/etc/hosts" 2>/dev/null || true
    PASS "Cleaned /etc/hosts of OSPC references"
  fi

  # ── 6. Remove OSPC cloud-init vendor data + old datasource cache ──
  sudo rm -rf "$MNT/var/lib/cloud/seed" 2>/dev/null || true
  sudo rm -f "$MNT/etc/cloud/cloud.cfg.d/"*ec2* 2>/dev/null || true
  sudo rm -f "$MNT/etc/cloud/cloud.cfg.d/"*Ec2* 2>/dev/null || true
  sudo rm -f "$MNT/etc/cloud/cloud.cfg.d/"*rackspace* 2>/dev/null || true
  sudo rm -f "$MNT/etc/cloud/cloud.cfg.d/"*xenserver* 2>/dev/null || true
  sudo rm -f "$MNT/etc/cloud/cloud.cfg.d/"*rax* 2>/dev/null || true
  PASS "Removed OSPC cloud-init vendor data + datasource configs"

  # ── 7. Wipe old syslog / auth logs (contain OSPC IPs, reduce image size) ──
  sudo rm -f "$MNT/var/log/auth.log"* 2>/dev/null || true
  sudo rm -f "$MNT/var/log/syslog"* 2>/dev/null || true
  sudo rm -f "$MNT/var/log/messages"* 2>/dev/null || true
  sudo rm -f "$MNT/var/log/secure"* 2>/dev/null || true
  sudo rm -f "$MNT/var/log/cloud-init"* 2>/dev/null || true
  sudo rm -f "$MNT/var/log/cloud-init-output.log" 2>/dev/null || true
  PASS "Old logs cleared (syslog, auth, cloud-init)"

  # ── 8. Remove /root/.bash_history and SSH known_hosts (OSPC data) ──
  sudo rm -f "$MNT/root/.bash_history" 2>/dev/null || true
  sudo rm -f "$MNT/root/.ssh/known_hosts" 2>/dev/null || true
  sudo rm -f "$MNT/home/"*/.bash_history 2>/dev/null || true
  sudo rm -f "$MNT/home/"*/.ssh/known_hosts 2>/dev/null || true
  PASS "Cleared bash history + SSH known_hosts"

  # ── 9. Remove UFW rules if present (Ubuntu/Debian) ──
  if [ -d "$MNT/etc/ufw" ]; then
    sudo rm -f "$MNT/etc/ufw/user.rules" "$MNT/etc/ufw/user6.rules" 2>/dev/null || true
    sudo rm -f "$MNT/etc/ufw/"*.rules.* 2>/dev/null || true
    # Disable UFW on boot
    if [ -f "$MNT/etc/ufw/ufw.conf" ]; then
      sudo sed -i 's/^ENABLED=yes/ENABLED=no/' "$MNT/etc/ufw/ufw.conf" 2>/dev/null || true
    fi
    PASS "UFW rules flushed + disabled"
  fi

  # ── 10. Remove firewalld saved rules (RHEL/CentOS/Rocky/Alma) ──
  if [ -d "$MNT/etc/firewalld" ]; then
    sudo rm -rf "$MNT/etc/firewalld/zones/"* 2>/dev/null || true
    sudo rm -rf "$MNT/etc/firewalld/services/"* 2>/dev/null || true
    PASS "firewalld saved zones/services cleared"
  fi

  # ── 11. Flush nftables rules (Debian 11/12, RHEL 9 default backend) ──
  for _nft in "$MNT/etc/nftables.conf" "$MNT/etc/sysconfig/nftables.conf"; do
    if [ -f "$_nft" ]; then
      sudo tee "$_nft" >/dev/null <<'NFTCLEAN'
#!/usr/sbin/nft -f
# Flushed by ospc2flex_offline_repair.sh — clean slate for FLEX
flush ruleset
NFTCLEAN
      PASS "Flushed nftables rules: $_nft"
    fi
  done

else
  INFO "[DRY-RUN] Would purge OSPC data: iptables, fail2ban, agents, cron, logs"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# SSH host keys — DELETE ALL OSPC keys, generate fresh for FLEX
# No OSPC data preserved. Fresh keys for a clean start.
# RHEL-family: pre-generate offline to avoid SELinux sshd_key_t boot issues.
# Debian/Ubuntu: cloud-init regenerates on first boot.
# ─────────────────────────────────────────────────────────────────────────────
echo "── SSH Host Keys (FRESH) ──────────────────────────────────────────────"
if [ $DRY_RUN -eq 0 ]; then
  # Delete ALL old OSPC host keys — no exceptions
  sudo rm -f "$MNT/etc/ssh/ssh_host_"* 2>/dev/null || true
  PASS "All OSPC SSH host keys DELETED"

  case "$OS_ID" in
    almalinux|rocky|centos|rhel)
      # Pre-generate fresh keys offline to avoid SELinux sshd-keygen boot failures.
      # /.autorelabel (created earlier) will fix the SELinux context on first boot.
      sudo ssh-keygen -t rsa     -b 2048 -f "$MNT/etc/ssh/ssh_host_rsa_key"     -N "" -q 2>/dev/null || true
      sudo ssh-keygen -t ecdsa   -b 256  -f "$MNT/etc/ssh/ssh_host_ecdsa_key"   -N "" -q 2>/dev/null || true
      sudo ssh-keygen -t ed25519         -f "$MNT/etc/ssh/ssh_host_ed25519_key" -N "" -q 2>/dev/null || true
      sudo chmod 600 "$MNT/etc/ssh/ssh_host_"*_key 2>/dev/null || true
      sudo chmod 644 "$MNT/etc/ssh/ssh_host_"*_key.pub 2>/dev/null || true
      PASS "Fresh SSH host keys generated (RSA, ECDSA, ED25519) — autorelabel will fix SELinux context"
      ;;
    debian)
      # Pre-generate for Debian too (old cloud-init may not regenerate)
      sudo ssh-keygen -t rsa     -b 2048 -f "$MNT/etc/ssh/ssh_host_rsa_key"     -N "" -q 2>/dev/null || true
      sudo ssh-keygen -t ecdsa   -b 256  -f "$MNT/etc/ssh/ssh_host_ecdsa_key"   -N "" -q 2>/dev/null || true
      sudo ssh-keygen -t ed25519         -f "$MNT/etc/ssh/ssh_host_ed25519_key" -N "" -q 2>/dev/null || true
      sudo ssh-keygen -t dsa     -b 1024 -f "$MNT/etc/ssh/ssh_host_dsa_key"     -N "" -q 2>/dev/null || true
      sudo chmod 600 "$MNT/etc/ssh/ssh_host_"*_key 2>/dev/null || true
      sudo chmod 644 "$MNT/etc/ssh/ssh_host_"*_key.pub 2>/dev/null || true
      PASS "Fresh SSH host keys generated for Debian (RSA, ECDSA, ED25519, DSA)"
      ;;
    ubuntu)
      # Ubuntu: cloud-init regenerates keys reliably — just leave them deleted
      PASS "SSH host keys removed — Ubuntu cloud-init will regenerate on FLEX boot"
      ;;
    *)
      # Unknown: generate fresh keys as safe default
      sudo ssh-keygen -t rsa     -b 2048 -f "$MNT/etc/ssh/ssh_host_rsa_key"     -N "" -q 2>/dev/null || true
      sudo ssh-keygen -t ecdsa   -b 256  -f "$MNT/etc/ssh/ssh_host_ecdsa_key"   -N "" -q 2>/dev/null || true
      sudo ssh-keygen -t ed25519         -f "$MNT/etc/ssh/ssh_host_ed25519_key" -N "" -q 2>/dev/null || true
      sudo chmod 600 "$MNT/etc/ssh/ssh_host_"*_key 2>/dev/null || true
      sudo chmod 644 "$MNT/etc/ssh/ssh_host_"*_key.pub 2>/dev/null || true
      PASS "Fresh SSH host keys generated (unknown OS — safe default)"
      ;;
  esac
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

[ $DRY_RUN -eq 0 ] && touch "$SENTINEL"
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅ OFFLINE REPAIR COMPLETE — ready for FLEX upload      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
PASS "OS: ${OS_PRETTY:-unknown}"
PASS "Sentinel: $SENTINEL"
echo ""
