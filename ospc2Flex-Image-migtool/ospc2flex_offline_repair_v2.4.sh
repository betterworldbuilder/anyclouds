#!/usr/bin/env bash
# =============================================================================
# ospc2flex_offline_repair.sh  v2.1
# Per-OS offline repair built from real FLEX VM boot profiles (2026-04-19)
#
# Verified FLEX VM configs (live SSH audit 2026-04-19):
#   ubuntu24  : BIOS, ens3, netplan, root=vda1(ext4,LABEL), /boot=vda16(sep)
#   debian11  : BIOS, eth0, ifupdown+source-dir, root=vda1(ext4,PARTUUID), /boot/efi=vda15
#   almalinux8: BIOS, eth0, NM/ifcfg, root=vda2(xfs), no sep /boot, SELinux=disabled
#   rocky8    : BIOS, eth0, NM/ifcfg, root=vda2(ext4), no sep /boot, SELinux=disabled
#   centos7   : BIOS, eth0, NM/ifcfg, root=vda1(ext4,MBR), /boot on root, SELinux=disabled
#               virtio NOT in initramfs — dracut --add-drivers required
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
  almalinux)  ROOT_PART="${NBD_DEV}p2"; ROOT_FSTYPE="ext4"  ;;
  rocky)      ROOT_PART="${NBD_DEV}p2"; ROOT_FSTYPE="ext4"  ;;
  centos|rhel) ROOT_PART="${NBD_DEV}p1"; ROOT_FSTYPE="ext4" ;;  # CentOS7 OSPC: MBR, single p1 ext4
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
    for _p in $(lsblk -lnpo NAME,TYPE "${NBD_DEV}" 2>/dev/null | awk '$2=="part"{print $1}'); do
      _type=$(blkid -o value -s TYPE "${_p}" 2>/dev/null); [ -z "${_type}" ] && continue
      [[ "${_type}" == "vfat" || "${_type}" == "swap" ]] && continue
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
  [ -d "$MNT/etc/netplan" ]                  && { OS_ID="ubuntu"; OS_VERSION="24.04"; OS_PRETTY="Ubuntu (netplan dir)"; }
  [ -d "$MNT/etc/sysconfig/network-scripts" ] && { OS_ID="almalinux"; OS_VERSION="8"; OS_PRETTY="RHEL-family (ifcfg dir)"; }
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
      # Debian 12+ uses netplan+systemd-networkd (no ifupdown)
      # Debian 10/11 uses ifupdown + /etc/network/interfaces
      if [ "${OS_MAJOR:-0}" -ge 12 ] || \
         ( [ -d "$MNT/usr/share/netplan" ] && ! dpkg --root="$MNT" -l ifupdown 2>/dev/null | grep -q '^ii' ); then
        INFO "Debian $OS_MAJOR detected — using netplan (no ifupdown)"
        # Write netplan config matching FLEX Debian 12 profile
        sudo mkdir -p "$MNT/etc/netplan"
        sudo rm -f "$MNT/etc/netplan/50-cloud-init.yaml" 2>/dev/null || true
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
        PASS "Wrote /etc/netplan/99-flex-fallback.yaml (Debian 12 netplan+networkd)"
      else
        INFO "Debian $OS_MAJOR — using ifupdown (traditional)"
        # Write /etc/network/interfaces for Debian 10/11
        sudo tee "$MNT/etc/network/interfaces" >/dev/null <<'IF_EOF'
# Include files from /etc/network/interfaces.d:
source-directory /etc/network/interfaces.d

# Cloud images dynamically generate config fragments for newly
# attached interfaces. See /etc/udev/rules.d/75-cloud-ifupdown.rules
# and /etc/network/cloud-ifupdown-helper. Dynamically generated
# configuration fragments are stored in /run:
source-directory /run/network/interfaces.d
IF_EOF
        PASS "Wrote /etc/network/interfaces (source-dir, matches FLEX Debian 11)"
      fi

      # Remove any old udev NIC rename rules that might block eth0
      sudo rm -f "$MNT/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
      sudo rm -f "$MNT/lib/udev/rules.d/75-persistent-net-generator.rules" 2>/dev/null || true
      PASS "Cleared persistent NIC rename rules"

      # Write full FLEX-compatible /etc/default/grub for Debian
      # Verified from live FLEX Debian VM: GRUB_TERMINAL="console serial" + serial speed
      if [ -f "$MNT/etc/default/grub" ]; then
        # Set GRUB_CMDLINE_LINUX to match verified FLEX Debian profile
        sudo sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="console=ttyS0,115200 console=tty0 earlyprintk=ttyS0,115200 consoleblank=0 net.ifnames=0"/' \
          "$MNT/etc/default/grub" 2>/dev/null || true
        PASS "Set GRUB_CMDLINE_LINUX (console+serial+net.ifnames=0)"
        # Set GRUB_CMDLINE_LINUX_DEFAULT to empty (no quiet splash)
        sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=""/' \
          "$MNT/etc/default/grub" 2>/dev/null || true
        # Add serial terminal config
        if ! grep -q 'GRUB_TERMINAL=' "$MNT/etc/default/grub"; then
          echo 'GRUB_TERMINAL="console serial"' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
        else
          sudo sed -i 's/^.*GRUB_TERMINAL=.*/GRUB_TERMINAL="console serial"/' "$MNT/etc/default/grub" 2>/dev/null || true
        fi
        if ! grep -q 'GRUB_SERIAL_COMMAND=' "$MNT/etc/default/grub"; then
          echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
        fi
        PASS "Set GRUB_TERMINAL=console serial + GRUB_SERIAL_COMMAND"
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
            sudo sed -i '/^\s*linux\s.*root=/{s/$/ console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0/}' \
              "$_gcfg" 2>/dev/null || true
            PASS "Patched $(basename $_gcfg) kernel lines with console=ttyS0"
          else
            INFO "console=ttyS0 already in $(basename $_gcfg)"
          fi
        fi
      done
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
    WARN "Unknown OS '$OS_ID' — applying generic fixes only"
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
#                 /.autorelabel (created above) fixes all other unlabeled files.
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
    ubuntu)
      # DELETE for Ubuntu: cloud-init regenerates host keys before sshd starts.
      sudo rm -f "$MNT/etc/ssh/ssh_host_"* 2>/dev/null || true
      PASS "SSH host keys removed (Ubuntu cloud-init will regenerate on first FLEX boot)"
      ;;
    debian)
      # KEEP for Debian: deleting keys causes sshd to fail (read-only fs on first boot).
      _key_count=$(sudo ls "$MNT/etc/ssh/ssh_host_"* 2>/dev/null | wc -l || echo 0)
      if [ "${_key_count:-0}" -gt 0 ]; then
        PASS "SSH host keys PRESERVED for Debian ($_key_count files)"
      else
        WARN "No SSH host keys found — sshd may fail on first boot"
      fi
      ;;
    *)
      # Unknown OS: preserve keys (safer default)
      WARN "Unknown OS — SSH host keys PRESERVED (safer default)"
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
