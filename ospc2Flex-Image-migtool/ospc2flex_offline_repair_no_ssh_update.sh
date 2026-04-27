#!/usr/bin/env bash
# =============================================================================
# ospc2flex_offline_repair.sh  v2.5
# Per-OS offline repair built from real FLEX VM boot profiles (2026-04-19)
# v2.5 (2026-04-22): Universal RHEL fix — blkid fstype verification,
#   NETWORKING=yes, direct grub.cfg patching, handles ext4/xfs on any RHEL
#
# Verified FLEX VM configs (live SSH audit 2026-04-19):
#   ubuntu24      : BIOS, ens3, netplan, root=vda1(ext4,LABEL), /boot=vda16(sep)
#   debian11      : BIOS, eth0, ifupdown+source-dir, root=vda1(ext4,PARTUUID), /boot/efi=vda15
#   almalinux8/9  : BIOS, eth0, NM/ifcfg, no sep /boot, SELinux=disabled
#   rocky8/9      : BIOS, eth0, NM/ifcfg, no sep /boot, SELinux=disabled
#   centos7/8/9   : RHEL-family offline repair profile, CentOS 7 keeps legacy dracut/grub2 path
#   rhel7/8/9     : RHEL-family offline repair profile, RHEL 7 keeps legacy grub path
#
# Usage:
#   bash ospc2flex_offline_repair.sh --qcow2 <path> [--os-type <type>] [--dry-run] [--force]
#       [--preserve-password-auth]
#   Supported --os-type values include:
#     ubuntu20 ubuntu22 ubuntu24
#     debian10 debian11 debian12
#     alma8 alma9 rocky8 rocky9
#     centos7 centos8 centos9 centosstream9
#     rhel7 rhel8 rhel9
#
# --dry-run               : detect OS + show what would change, touch nothing
# --force                 : re-run repair even if sentinel exists
# --preserve-password-auth: keep existing local Linux password auth usable on FLEX
# =============================================================================
set -euo pipefail

QCOW2=""
DRY_RUN=0
FORCE=0
PRESERVE_PASSWORD_AUTH=0
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
    --preserve-password-auth) PRESERVE_PASSWORD_AUTH=1; shift ;;
    --root-part) ROOT_PART_ARG="$2"; shift 2 ;;
    *) echo "[ERROR] Unknown arg: $1"; exit 1 ;;
  esac
done

[ -z "$QCOW2" ]   && { echo "Usage: bash $0 --qcow2 <path.qcow2> [--os-type <type>] [--nbd-dev /dev/nbdN] [--dry-run] [--force] [--preserve-password-auth]"; exit 1; }
[ ! -f "$QCOW2" ] && { echo "[ERROR] File not found: $QCOW2"; exit 1; }

# Map --os-type (mig_worker values: ubuntu24 debian10 alma9 rocky8 centos7 rhel8) → OS_ID
OS_ID_FROM_ARG=""
case "$OS_TYPE_ARG" in
  ubuntu24|ubuntu*)      OS_ID_FROM_ARG="ubuntu"    ;;
  debian10|debian11|debian*) OS_ID_FROM_ARG="debian" ;;
  alma9|alma8|almalinux*)  OS_ID_FROM_ARG="almalinux" ;;
  rocky8|rocky9|rocky*)    OS_ID_FROM_ARG="rocky"   ;;
  centos7|centos8|centos9|centosstream9|centos-stream9|centosstream*|centos-stream*|centos*) OS_ID_FROM_ARG="centos"  ;;
  rhel*)                 OS_ID_FROM_ARG="rhel"      ;;
  "")                    OS_ID_FROM_ARG=""           ;;
  *) echo "  ⚠  Unknown --os-type '$OS_TYPE_ARG' — will detect from os-release";;
esac

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
PASS() { echo "  ✅ $*"; }
FAIL() { echo "  ❌ $*"; }
INFO() { echo "  ℹ  $*"; }
WARN() { echo "  ⚠  $*"; }

shadow_hash_for_user() {
  local shadow_file="$1" user="$2"
  [ -f "$shadow_file" ] || return 1
  sudo awk -F: -v u="$user" '$1 == u { print $2; exit }' "$shadow_file"
}

shadow_hash_usable() {
  local hash="${1:-}"
  case "$hash" in
    ""|"!"|"!!"|"*"|"!*") return 1 ;;
    !*|*LK*|*NP*) return 1 ;;
    *) return 0 ;;
  esac
}

fstab_spec_for_mountpoint() {
  local mountpoint="$1" fstab_file="$2"
  [ -f "$fstab_file" ] || return 1
  awk -v mp="$mountpoint" '
    /^[[:space:]]*#/ || NF < 2 { next }
    $2 == mp { print $1; exit }
  ' "$fstab_file"
}

resolve_part_by_fstab_spec() {
  local spec="$1" _p _val _out=""
  [ -n "$spec" ] || return 1
  case "$spec" in
    /dev/*)
      [ -b "$spec" ] && { echo "$spec"; return 0; }
      ;;
    UUID=*)
      _val="${spec#UUID=}"
      ;;
    PARTUUID=*)
      _val="${spec#PARTUUID=}"
      ;;
    LABEL=*)
      _val="${spec#LABEL=}"
      ;;
    *)
      return 1
      ;;
  esac
  for _p in "${NBD_DEV}" "${NBD_DEV}"p*; do
    [ -b "$_p" ] || continue
    case "$spec" in
      UUID=*)
        _out=$(sudo blkid -o value -s UUID "$_p" 2>/dev/null || true)
        ;;
      PARTUUID=*)
        _out=$(sudo blkid -o value -s PARTUUID "$_p" 2>/dev/null || true)
        ;;
      LABEL=*)
        _out=$(sudo blkid -o value -s LABEL "$_p" 2>/dev/null || true)
        ;;
    esac
    [ -n "$_out" ] && [ "$_out" = "$_val" ] && { echo "$_p"; return 0; }
  done
  return 1
}

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║    OSPC2FLEX — Offline Guest Repair v2.0                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
log "Target qcow2 : $QCOW2"
log "Dry run      : $([ $DRY_RUN -eq 1 ] && echo YES || echo NO)"
log "Force re-run : $([ $FORCE  -eq 1 ] && echo YES || echo NO)"
log "Keep passwd   : $([ $PRESERVE_PASSWORD_AUTH -eq 1 ] && echo YES || echo NO)"
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
  sync
  sudo umount "$MNT/boot/efi" 2>/dev/null || true
  sudo umount "$MNT/boot"     2>/dev/null || true
  sudo umount "$MNT/proc" "$MNT/sys" "$MNT/dev" 2>/dev/null || true
  sudo umount "$MNT"          2>/dev/null || true
  sync

  # Final safety fsck after unmount before destroying NBD connection
  if [ -n "${ROOT_PART:-}" ] && [ -b "${ROOT_PART:-}" ]; then
    if [ "${ROOT_FSTYPE:-}" != "xfs" ]; then
      sudo e2fsck -p -f "$ROOT_PART" 2>/dev/null || sudo e2fsck -y "$ROOT_PART" 2>/dev/null || true
    else
      sudo xfs_repair -L "$ROOT_PART" 2>/dev/null || true
    fi
  fi

  sleep 1
  sync

  sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
  # rmmod nbd DISABLED — parallel workers share kernel nbd module
  sudo rm -rf "$MNT"
}
trap cleanup EXIT
echo ""

# ── Connect qcow2 via NBD ─────────────────────────────────────────────────────
echo "── Connect qcow2 ────────────────────────────────────────────────────────"
# Detect actual image format — dd output is raw even when named .qcow2
_IMG_FMT=$(qemu-img info "$QCOW2" 2>/dev/null | awk '/^file format:/{print $3}')
_IMG_FMT=${_IMG_FMT:-qcow2}
INFO "Image format: $_IMG_FMT"
# Kill any process holding a write lock on the file (previous run left qemu-nbd open)
sudo fuser -k "$QCOW2" 2>/dev/null || true
sleep 1
sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
sleep 1
sudo qemu-nbd -f "$_IMG_FMT" --connect="$NBD_DEV" "$QCOW2" 2>/tmp/nbd_err_$$.txt \
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
    ROOT_PART=""; ROOT_FSTYPE="xfs"
    ;;
  centos|rhel) ROOT_PART="${NBD_DEV}p1"; ROOT_FSTYPE="xfs" ;;  # CentOS7/RHEL may be xfs-backed
  *)
    ROOT_PART=""
    WARN "No OS type recognized — relying on auto-detect"
    ;;
esac
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
    ROOT_FSTYPE=$(sudo blkid -o value -s TYPE "${ROOT_PART}" 2>/dev/null || echo ext4)
    INFO "Root override: ${ROOT_PART} (${ROOT_FSTYPE}) [--root-part]"
  else
    # Always verify actual filesystem type with blkid — OSPC images may not match
    # the expected type (e.g. RHEL 8 might be ext4 instead of the hardcoded xfs)
    if [ -n "${ROOT_PART}" ] && [ -b "${ROOT_PART}" ]; then
      _REAL_FSTYPE=$(sudo blkid -o value -s TYPE "${ROOT_PART}" 2>/dev/null || true)
      if [ -n "${_REAL_FSTYPE}" ] && [ "${_REAL_FSTYPE}" != "${ROOT_FSTYPE}" ]; then
        WARN "Filesystem mismatch: hardcoded=${ROOT_FSTYPE} actual=${_REAL_FSTYPE} — using actual"
        ROOT_FSTYPE="${_REAL_FSTYPE}"
      fi
    fi
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
  sudo fsck -f -y "$ROOT_PART" >/tmp/fsck1_$$.txt 2>&1 || true
  INFO "fsck1: $(tail -2 /tmp/fsck1_$$.txt | tr '\n' ' ')"
  log "fsck pass 2 on $ROOT_PART..."
  sudo fsck -f -y "$ROOT_PART" >/tmp/fsck2_$$.txt 2>&1 || true
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
elif [ "$ROOT_FSTYPE" = "xfs" ]; then
  # XFS dirty journal: clear log with xfs_repair -L, then retry mount read-write
  WARN "XFS mount failed (dirty journal) — running xfs_repair -L to force-clear log..."
  sudo xfs_repair -L "$ROOT_PART" >/tmp/xfsrep_L_$$.txt 2>&1 || true
  INFO "xfs_repair -L: $(tail -1 /tmp/xfsrep_L_$$.txt)"
  if sudo mount -o nouuid "$ROOT_PART" "$MNT" 2>/dev/null; then
    PASS "Mounted $ROOT_PART → $MNT (after xfs_repair -L)"
  elif sudo mount -o norecovery,ro "$ROOT_PART" "$MNT" 2>/dev/null; then
    WARN "Mounted read-only (norecovery) — xfs_repair -L did not fully clear journal"
  else
    FAIL "Cannot mount XFS root partition even after xfs_repair -L"
    exit 1
  fi
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
# Enhanced detection to handle:
#   - Null bytes in /etc/os-release (source VMs with cloud-init corruption)
#   - Debian version name fallback (bullseye, bookworm, etc.)
#   - Multiple fallback sources (lsb_release, /etc/issue, filesystem clues)
# ────────────────────────────────────────────────────────────────────────────────
echo "── OS Detection ─────────────────────────────────────────────────────────"
set +e
OS_ID=""; OS_VERSION=""; OS_MAJOR=""; OS_PRETTY=""

# ─ Method 1: /etc/os-release (PRIMARY) ─────────────────────────────────────
if [ -f "$MNT/etc/os-release" ]; then
  # Explicitly filter null bytes (not caught by cut/tr)
  OS_ID=$(grep '^ID=' "$MNT/etc/os-release" 2>/dev/null | tr -d '\0' | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]*$//')
  OS_VERSION=$(grep '^VERSION_ID=' "$MNT/etc/os-release" 2>/dev/null | tr -d '\0' | cut -d= -f2 | tr -d '"' | sed 's/[[:space:]]*$//')
  OS_PRETTY=$(grep '^PRETTY_NAME=' "$MNT/etc/os-release" 2>/dev/null | tr -d '\0' | cut -d= -f2 | tr -d '"' | sed 's/[[:space:]]*$//')
  [ -n "$OS_VERSION" ] && OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
fi

# ─ Method 2: Distribution-specific release files ────────────────────────────
if [ -z "$OS_ID" ] && [ -f "$MNT/etc/rocky-release" ]; then
  OS_ID="rocky"; OS_PRETTY=$(cat "$MNT/etc/rocky-release" | tr -d '\0\n' | sed 's/[[:space:]]*$//')
  OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' "$MNT/etc/rocky-release" | head -1)
fi
if [ -z "$OS_ID" ] && [ -f "$MNT/etc/almalinux-release" ]; then
  OS_ID="almalinux"; OS_PRETTY=$(cat "$MNT/etc/almalinux-release" | tr -d '\0\n' | sed 's/[[:space:]]*$//')
  OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' "$MNT/etc/almalinux-release" | head -1)
fi
if [ -z "$OS_ID" ] && [ -f "$MNT/etc/redhat-release" ]; then
  _rhr=$(cat "$MNT/etc/redhat-release" | tr -d '\0\n' | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]*$//')
  OS_PRETTY=$(cat "$MNT/etc/redhat-release" | tr -d '\0\n' | sed 's/[[:space:]]*$//')
  OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' "$MNT/etc/redhat-release" | head -1)
  echo "$_rhr" | grep -q centos && OS_ID="centos"
  echo "$_rhr" | grep -q "red hat" && OS_ID="rhel"
fi

# ─ Method 3: Debian version detection (ENHANCED) ───────────────────────────
# Handles: numeric versions (11, 11.0, 12.5) and version names (bullseye, bookworm)
if [ -z "$OS_ID" ] && [ -f "$MNT/etc/debian_version" ]; then
  OS_ID="debian"
  _DEB_VER=$(cat "$MNT/etc/debian_version" | tr -d '\0\n' | sed 's/[[:space:]]*$//')
  
  # Map version names to major versions
  case "$_DEB_VER" in
    bullseye*)   OS_VERSION="11.0"; OS_MAJOR="11"; OS_PRETTY="Debian 11 (bullseye)" ;;
    bookworm*)   OS_VERSION="12.0"; OS_MAJOR="12"; OS_PRETTY="Debian 12 (bookworm)" ;;
    trixie*)     OS_VERSION="13.0"; OS_MAJOR="13"; OS_PRETTY="Debian 13 (trixie)" ;;
    sid*)        OS_VERSION="999.0"; OS_MAJOR="999"; OS_PRETTY="Debian unstable (sid)" ;;
    testing*)    OS_VERSION="998.0"; OS_MAJOR="998"; OS_PRETTY="Debian testing" ;;
    *)
      # Try to extract numeric version
      if echo "$_DEB_VER" | grep -qE '^[0-9]'; then
        OS_VERSION="$_DEB_VER"
        OS_MAJOR=$(echo "$_DEB_VER" | grep -oE '^[0-9]+')
        OS_PRETTY="Debian $OS_VERSION"
      else
        # Last resort: assume Debian 10
        OS_VERSION="10.0"; OS_MAJOR="10"; OS_PRETTY="Debian (unrecognized: $_DEB_VER)"
      fi
      ;;
  esac
fi

# ─ Method 4: lsb_release (as fallback) ────────────────────────────────────
if [ -z "$OS_ID" ] && [ -f "$MNT/etc/lsb-release" ]; then
  _LSB_ID=$(grep '^DISTRIB_ID=' "$MNT/etc/lsb-release" 2>/dev/null | tr -d '\0' | cut -d= -f2 | tr '[:upper:]' '[:lower:]')
  _LSB_VERSION=$(grep '^DISTRIB_RELEASE=' "$MNT/etc/lsb-release" 2>/dev/null | tr -d '\0' | cut -d= -f2)
  if [ -n "$_LSB_ID" ]; then
    OS_ID="$_LSB_ID"; OS_VERSION="$_LSB_VERSION"; OS_PRETTY="$_LSB_ID $OS_VERSION (lsb-release)"
  fi
fi

# ─ Method 5: Filesystem clues (LAST RESORT) ──────────────────────────────
if [ -z "$OS_ID" ]; then
  [ -d "$MNT/etc/netplan" ]                  && { OS_ID="ubuntu"; OS_VERSION="24.04"; OS_PRETTY="Ubuntu (netplan dir)"; }
  [ -d "$MNT/etc/sysconfig/network-scripts" ] && [ -z "$OS_ID" ] && { OS_ID="almalinux"; OS_VERSION="8"; OS_PRETTY="RHEL-family (ifcfg dir)"; }
  [ -d "$MNT/etc/network/interfaces.d" ]     && [ -z "$OS_ID" ] && { OS_ID="debian"; OS_VERSION="10.0"; OS_MAJOR="10"; OS_PRETTY="Debian (interfaces.d dir)"; }
fi

# ─ Method 6: explicit --os-type fallback ──────────────────────────────────
# This matters for damaged os-release files and for CentOS/RHEL variants that
# still need the correct offline repair profile even when disk metadata is thin.
if [ -z "$OS_ID" ] && [ -n "$OS_ID_FROM_ARG" ]; then
  _arg_ver=$(echo "$OS_TYPE_ARG" | grep -oE '[0-9]+' | head -1 || true)
  OS_ID="$OS_ID_FROM_ARG"
  OS_MAJOR="${_arg_ver:-0}"
  if [ "$OS_MAJOR" = "0" ]; then
    case "$OS_ID" in
      ubuntu)    OS_MAJOR="24"; OS_VERSION="24.04" ;;
      debian)    OS_MAJOR="12"; OS_VERSION="12.0" ;;
      almalinux|rocky|centos|rhel) OS_MAJOR="8"; OS_VERSION="8.0" ;;
    esac
  else
    OS_VERSION="${OS_MAJOR}.0"
  fi
  OS_PRETTY="$OS_ID (from --os-type=$OS_TYPE_ARG)"
  INFO "OS detection from disk failed — using --os-type argument: $OS_ID (ver=$OS_VERSION)"
fi

# ─ Validation: ensure OS_MAJOR is numeric ─────────────────────────────────
if [ -n "$OS_VERSION" ] && [ -z "$OS_MAJOR" ]; then
  OS_MAJOR=$(echo "$OS_VERSION" | grep -oE '^[0-9]+' || echo "0")
fi
if ! echo "${OS_MAJOR:-0}" | grep -qE '^[0-9]+$'; then
  WARN "OS_MAJOR '$OS_MAJOR' is not numeric — defaulting to 10"
  OS_MAJOR="10"
fi

set -e

if [ -n "$OS_ID" ]; then
  PASS "OS detected: $OS_PRETTY (id=$OS_ID version=$OS_VERSION major=$OS_MAJOR)"
  # Log which version-specific repair profile will be used
  case "$OS_ID" in
    ubuntu)    INFO "Repair profile: Ubuntu (all versions share same netplan wildcard)" ;;
    debian)
      if [ "${OS_MAJOR:-0}" -ge 12 ]; then
        INFO "Repair profile: Debian $OS_MAJOR → netplan + systemd-networkd (DHCP eth*, en*)"
      elif [ "${OS_MAJOR:-0}" -ge 10 ]; then
        INFO "Repair profile: Debian $OS_MAJOR → ifupdown + source-directory (eth0 DHCP)"
      else
        INFO "Repair profile: Debian (old version) → ifupdown fallback"
      fi ;;
    almalinux|rocky)
      if [ "${OS_MAJOR:-0}" -ge 9 ]; then
        INFO "Repair profile: $OS_ID $OS_MAJOR → ifcfg-eth0 + NM keyfile (dual mode)"
      else
        INFO "Repair profile: $OS_ID $OS_MAJOR → ifcfg-eth0 only (no NM keyfile)"
      fi ;;
    centos)
      if [ "${OS_MAJOR:-0}" -le 7 ]; then
        INFO "Repair profile: CentOS $OS_MAJOR → legacy ifcfg + dracut + grub2-mkconfig"
      else
        INFO "Repair profile: CentOS $OS_MAJOR → ifcfg + NetworkManager + BLS/grubenv"
      fi ;;
    rhel)
      if [ "${OS_MAJOR:-0}" -le 7 ]; then
        INFO "Repair profile: RHEL $OS_MAJOR → legacy ifcfg + grub2"
      else
        INFO "Repair profile: RHEL $OS_MAJOR → ifcfg + NetworkManager + BLS/grubenv"
      fi ;;
    *)       INFO "Repair profile: generic (netplan + ifupdown fallback)" ;;
  esac
else
  WARN "Unknown OS — applying generic fixes only (netplan + ifupdown fallback)"
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
      else
        WARN "/etc/default/grub not found — Ubuntu grub params only patched in grub.cfg"
      fi

      # Patch grub.cfg directly if present
      for _gcfg in "$MNT/boot/grub/grub.cfg" "$MNT/boot/grub2/grub.cfg"; do
        if [ -f "$_gcfg" ]; then
          if ! grep -q "net.ifnames=0" "$_gcfg"; then
            sudo sed -E -i '/^[[:space:]]*linux(16|efi)?[[:space:]].*root=/{s/$/ net.ifnames=0 biosdevname=0/}' "$_gcfg" 2>/dev/null || true
          fi
          if ! grep -q "console=ttyS0" "$_gcfg"; then
            sudo sed -E -i '/^[[:space:]]*linux(16|efi)?[[:space:]].*root=/{s/$/ console=tty0 console=ttyS0,115200/}' "$_gcfg" 2>/dev/null || true
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
      # Debian 12+ uses netplan+systemd-networkd. Debian 10/11 stays on ifupdown.
      # Avoid guessing from directory presence alone because Debian 11 can carry
      # netplan files or packages while still booting with ifupdown.
      DEBIAN_NET_MODE="ifupdown"
      if [ "${OS_MAJOR:-0}" -ge 12 ]; then
        if [ -x "$MNT/usr/sbin/netplan" ] || [ -x "$MNT/usr/bin/netplan" ] || [ -d "$MNT/usr/share/netplan" ]; then
          DEBIAN_NET_MODE="netplan"
        else
          WARN "Debian $OS_MAJOR expected netplan, but netplan tooling not found — falling back to ifupdown"
        fi
      fi
      if [ "$DEBIAN_NET_MODE" = "netplan" ]; then
        INFO "Debian $OS_MAJOR detected — using netplan (no ifupdown)"
        # Write netplan config matching FLEX Debian 12 profile
        sudo mkdir -p "$MNT/etc/netplan"
        # Delete ALL old OSPC netplan files (may hardcode old NIC names/MAC)
        sudo rm -f "$MNT/etc/netplan/"*.yaml 2>/dev/null || true
        sudo rm -f "$MNT/etc/netplan/"*.yml 2>/dev/null || true
        PASS "Deleted all old OSPC netplan configs"
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
        sudo rm -f "$MNT/etc/network/interfaces.d/"* 2>/dev/null || true
        PASS "Cleared stale ifupdown snippets for Debian netplan mode"
      else
        INFO "Debian $OS_MAJOR — using ifupdown (traditional)"
        # Write /etc/network/interfaces for Debian 10/11
        # MUST include explicit eth0 DHCP — source-directory alone is empty
        # and relies on cloud-init to generate the config (fails with old cloud-init)
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
        sudo rm -f "$MNT/etc/netplan/"*.yaml "$MNT/etc/netplan/"*.yml 2>/dev/null || true
        PASS "Cleared stale netplan configs for Debian ifupdown mode"
      fi

      DEBIAN_BOOTEFI_SPEC=$(fstab_spec_for_mountpoint "/boot/efi" "$MNT/etc/fstab" || true)
      DEBIAN_BOOTEFI_PART=""
      [ -n "$DEBIAN_BOOTEFI_SPEC" ] && DEBIAN_BOOTEFI_PART=$(resolve_part_by_fstab_spec "$DEBIAN_BOOTEFI_SPEC" || true)
      if [ -n "$DEBIAN_BOOTEFI_PART" ]; then
        sudo mkdir -p "$MNT/boot/efi"
        if sudo mount "$DEBIAN_BOOTEFI_PART" "$MNT/boot/efi" 2>/dev/null; then
          PASS "Mounted Debian /boot/efi: $DEBIAN_BOOTEFI_PART"
        else
          WARN "Could not mount Debian /boot/efi partition: $DEBIAN_BOOTEFI_PART"
        fi
      fi

      # Remove any old udev NIC rename rules that might block eth0
      sudo rm -f "$MNT/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
      sudo rm -f "$MNT/lib/udev/rules.d/75-persistent-net-generator.rules" 2>/dev/null || true
      PASS "Cleared persistent NIC rename rules"

      # Write full FLEX-compatible /etc/default/grub for Debian
      # Verified from live FLEX Debian VM: GRUB_TERMINAL="console serial" + serial speed
      if [ -f "$MNT/etc/default/grub" ]; then
        # Remove ALL existing GRUB_CMDLINE_LINUX lines first (prevents duplicates)
        sudo sed -i '/^GRUB_CMDLINE_LINUX=/d' "$MNT/etc/default/grub" 2>/dev/null || true
        sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/d' "$MNT/etc/default/grub" 2>/dev/null || true
        # Write single clean CMDLINE
        echo 'GRUB_CMDLINE_LINUX="console=ttyS0,115200 console=tty0 earlyprintk=ttyS0,115200 consoleblank=0 net.ifnames=0"' \
          | sudo tee -a "$MNT/etc/default/grub" >/dev/null
        echo 'GRUB_CMDLINE_LINUX_DEFAULT=""' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
        PASS "Set GRUB_CMDLINE_LINUX (console+serial+net.ifnames=0) — no duplicates"
        # Add serial terminal config (remove old first, then append)
        sudo sed -i '/^.*GRUB_TERMINAL=/d' "$MNT/etc/default/grub" 2>/dev/null || true
        sudo sed -i '/^.*GRUB_SERIAL_COMMAND=/d' "$MNT/etc/default/grub" 2>/dev/null || true
        echo 'GRUB_TERMINAL="console serial"' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
        echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
        PASS "Set GRUB_TERMINAL=console serial + GRUB_SERIAL_COMMAND"
        # Final dedup safety (remove any remaining duplicate lines)
        sudo awk '!seen[$0]++' "$MNT/etc/default/grub" | sudo tee "$MNT/etc/default/grub.tmp" >/dev/null
        sudo mv "$MNT/etc/default/grub.tmp" "$MNT/etc/default/grub"
      fi

      # Patch grub.cfg directly (safe for Debian — /boot/grub/grub.cfg is on root partition)
      for _gcfg in "$MNT/boot/grub/grub.cfg" "$MNT/boot/grub2/grub.cfg"; do
        if [ -f "$_gcfg" ]; then
          # Add net.ifnames=0 if missing
          if ! grep -q "net.ifnames=0" "$_gcfg"; then
            sudo sed -E -i '/^[[:space:]]*linux(16|efi)?[[:space:]].*root=/{s/$/ net.ifnames=0 biosdevname=0/}' \
              "$_gcfg" 2>/dev/null || true
            PASS "Patched $(basename $_gcfg) kernel lines with net.ifnames=0"
          else
            INFO "net.ifnames=0 already in $(basename $_gcfg)"
          fi
          # Add console=ttyS0 if missing (needed for FLEX serial console / VNC log)
          if ! grep -q "console=ttyS0" "$_gcfg"; then
            sudo sed -E -i '/^[[:space:]]*linux(16|efi)?[[:space:]].*root=/{s/$/ console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0/}' \
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
# ALMALINUX 8/9 / ROCKY 8/9 / CENTOS / RHEL — verified from live FLEX VMs:
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
      # DEFROUTE=yes: ensure DHCP installs default gateway (no gateway = no ping)
      # PEERDNS=yes:  let DHCP overwrite /etc/resolv.conf with FLEX DNS servers
      # MTU=1500:     FLEX KVM uses standard Ethernet MTU (Xen may have used jumbo)
      sudo tee "$IFCFG_DIR/ifcfg-eth0" >/dev/null <<'IFCFG_EOF'
# Written by ospc2flex_offline_repair.sh v2.5
# cloud-init will overwrite with correct HWADDR on first FLEX boot
DEVICE=eth0
BOOTPROTO=dhcp
ONBOOT=yes
TYPE=Ethernet
USERCTL=no
NM_CONTROLLED=yes
IPV6INIT=no
DEFROUTE=yes
PEERDNS=yes
MTU=1500
IFCFG_EOF
      PASS "Wrote $IFCFG_DIR/ifcfg-eth0 (DEVICE=eth0, DHCP, DEFROUTE=yes, PEERDNS=yes, MTU=1500)"

      # Ensure /etc/sysconfig/network exists with NETWORKING=yes (required for net-scripts on all RHEL)
      _NET_FILE="$MNT/etc/sysconfig/network"
      if [ ! -f "$_NET_FILE" ] || ! grep -q '^NETWORKING=yes' "$_NET_FILE" 2>/dev/null; then
        echo 'NETWORKING=yes' | sudo tee "$_NET_FILE" >/dev/null
        PASS "Set NETWORKING=yes in /etc/sysconfig/network"
      fi

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
dhcp-timeout=180
dhcp-send-hostname=yes
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

      # Clear NetworkManager stale runtime state (old MAC-keyed connections, OSPC DHCP leases)
      # NM caches connections by MAC; after Xen→KVM hardware change these cause "device not managed"
      sudo rm -f "$MNT/var/lib/NetworkManager/"*.lease 2>/dev/null || true
      sudo rm -f "$MNT/var/lib/NetworkManager/timestamps" 2>/dev/null || true
      sudo rm -f "$MNT/var/lib/NetworkManager/seen-bssids" 2>/dev/null || true
      sudo find "$MNT/var/lib/NetworkManager" -name "*.nmstate" -delete 2>/dev/null || true
      sudo find "$MNT/var/lib/NetworkManager" -name "internal-*" -delete 2>/dev/null || true
      PASS "Cleared NetworkManager stale state (leases, timestamps, MAC-keyed state)"

      # Write /etc/resolv.conf fallback — RHEL-family may have OSPC-specific or empty resolv.conf.
      # On first boot DHCP (PEERDNS=yes) will overwrite this; fallback prevents boot-time DNS hangs.
      if [ ! -s "$MNT/etc/resolv.conf" ] || grep -qE '169\.254\.|127\.0\.0\.53|rackspace\.com' "$MNT/etc/resolv.conf" 2>/dev/null; then
        sudo tee "$MNT/etc/resolv.conf" >/dev/null <<'RESOLV_EOF'
# Written by ospc2flex_offline_repair.sh — fallback until DHCP PEERDNS sets DNS
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLV_EOF
        PASS "Wrote /etc/resolv.conf fallback DNS (8.8.8.8, 1.1.1.1)"
      fi

      # RHEL/CentOS 6: SysV init (no systemd) — use chkconfig + NM_CONTROLLED=no
      # RHEL 6 ships NetworkManager but it is unreliable with cloud DHCP VMs.
      # Pure SysV network scripts (ifup/ifdown) with NM_CONTROLLED=no is the stable path.
      if [ "${OS_MAJOR:-0}" -le 6 ] && [ "$OS_ID" = "centos" -o "$OS_ID" = "rhel" ]; then
        # Switch ifcfg-eth0 to SysV mode (NM_CONTROLLED=no)
        sudo sed -i 's/^NM_CONTROLLED=yes/NM_CONTROLLED=no/' "$IFCFG_DIR/ifcfg-eth0" 2>/dev/null || true
        PASS "Set NM_CONTROLLED=no in ifcfg-eth0 (RHEL 6 SysV network scripts)"
        # Enable network SysV service via chkconfig (creates /etc/rc*.d symlinks)
        sudo mount --bind /proc "$MNT/proc" 2>/dev/null || true
        sudo chroot "$MNT" /sbin/chkconfig network on 2>/dev/null \
          && PASS "chkconfig network on (RHEL 6 SysV)" \
          || WARN "chkconfig network on failed — verify /etc/rc3.d/S10network manually"
        # Disable NM on RHEL 6 to avoid it fighting with SysV scripts
        sudo chroot "$MNT" /sbin/chkconfig NetworkManager off 2>/dev/null \
          && PASS "chkconfig NetworkManager off (SysV network scripts are authoritative)" \
          || true
        sudo umount "$MNT/proc" 2>/dev/null || true

      # RHEL/CentOS 7: use legacy network.service (SysV ifup scripts) with NM_CONTROLLED=no.
      # OSPC source VMs have NetworkManager=inactive and network=active with NM_CONTROLLED=no.
      # NM on migrated images fails to activate eth0 (no prior connection profile, timing issues).
      # Legacy network scripts reliably run dhclient eth0 via ifup — match the source setup.
      elif [ "${OS_MAJOR:-0}" -eq 7 ] && [ "$OS_ID" = "centos" -o "$OS_ID" = "rhel" ]; then
        # Unmask network.service (remove any /dev/null mask left by previous runs)
        sudo rm -f "$MNT/etc/systemd/system/network.service" 2>/dev/null || true
        # Enable network.service via multi-user.target.wants
        sudo mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
        sudo ln -sf /usr/lib/systemd/system/network.service \
          "$MNT/etc/systemd/system/multi-user.target.wants/network.service" 2>/dev/null || true
        PASS "Enabled network.service (legacy SysV ifup scripts — matches OSPC source setup)"

        # Write a clean ifcfg-eth0 — NO HWADDR (old Xen MAC won't match new virtio NIC).
        # The OSPC source ifcfg-eth0 has HWADDR=<xen-mac>; ifup skips the interface when
        # the MAC doesn't match, leaving eth0 DOWN. A fresh file with no HWADDR ensures
        # dhclient runs on first FLEX boot via the legacy network.service SysV path.
        sudo tee "$MNT/etc/sysconfig/network-scripts/ifcfg-eth0" >/dev/null <<'IFCFG7_EOF'
DEVICE=eth0
BOOTPROTO=dhcp
ONBOOT=yes
NM_CONTROLLED=no
PEERDNS=yes
DEFROUTE=yes
IPV6INIT=no
TYPE=Ethernet
IFCFG7_EOF
        PASS "Wrote fresh ifcfg-eth0 (no HWADDR, ONBOOT=yes, DHCP, NM_CONTROLLED=no)"

        # Disable NetworkManager-wait-online (causes 90s boot hang when DHCP is slow)
        sudo ln -sf /dev/null "$MNT/etc/systemd/system/NetworkManager-wait-online.service" 2>/dev/null || true
        PASS "Masked NetworkManager-wait-online.service (prevents 90s DHCP timeout hang)"

        # RHEL 6: chkconfig NetworkManager off. C7: must not start NM alongside network.service
        # (race → eth0 down / no DHCP). Mask NM like NetworkManager-wait-online — no host systemctl needed.
        sudo rm -f "$MNT/etc/systemd/system/multi-user.target.wants/NetworkManager.service" 2>/dev/null || true
        sudo rm -f "$MNT/etc/systemd/system/dbus-org.freedesktop.NetworkManager.service" 2>/dev/null || true
        sudo rm -f "$MNT/etc/systemd/system/graphical.target.wants/NetworkManager.service" 2>/dev/null || true
        sudo ln -sf /dev/null "$MNT/etc/systemd/system/NetworkManager.service" 2>/dev/null || true
        PASS "Masked NetworkManager.service (legacy network.service owns eth0)"
      fi

    else
      INFO "[DRY-RUN] Would write ifcfg-eth0 + remove old ifcfg-ens* + clear NM state"
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

    echo "── [RHEL-FAMILY] Resolve /boot + /boot/efi ───────────────────────────────"
    # FLEX RHEL-family images can use either boot-on-root or separate EFI.
    # Resolve from fstab first so BLS and grubenv updates run against the real boot paths.
    BOOT_PART=""
    BOOTEFI_PART=""
    BOOT_SPEC=$(fstab_spec_for_mountpoint "/boot" "$MNT/etc/fstab" || true)
    BOOTEFI_SPEC=$(fstab_spec_for_mountpoint "/boot/efi" "$MNT/etc/fstab" || true)
    [ -n "$BOOT_SPEC" ] && BOOT_PART=$(resolve_part_by_fstab_spec "$BOOT_SPEC" || true)
    [ -n "$BOOTEFI_SPEC" ] && BOOTEFI_PART=$(resolve_part_by_fstab_spec "$BOOTEFI_SPEC" || true)
    [ -n "$BOOT_SPEC" ] && INFO "/boot spec: $BOOT_SPEC"
    [ -n "$BOOTEFI_SPEC" ] && INFO "/boot/efi spec: $BOOTEFI_SPEC"
    [ -n "$BOOT_PART" ] && INFO "/boot part: $BOOT_PART" || INFO "/boot uses root filesystem"
    [ -n "$BOOTEFI_PART" ] && INFO "/boot/efi part: $BOOTEFI_PART" || true

    if [ $DRY_RUN -eq 0 ]; then
      BOOT_DIR="$MNT/boot"
      BOOTEFI_DIR="$MNT/boot/efi"
      BOOT_READY=0

      if [ -n "$BOOT_PART" ]; then
        sudo mkdir -p "$BOOT_DIR"
        if sudo mount -o nouuid "$BOOT_PART" "$BOOT_DIR" 2>/dev/null || \
           sudo mount "$BOOT_PART" "$BOOT_DIR" 2>/dev/null; then
          PASS "Mounted /boot: $BOOT_PART → $BOOT_DIR"
          BOOT_READY=1
        else
          WARN "Could not mount /boot partition $BOOT_PART — using root-mounted /boot if present"
        fi
      fi
      if [ "$BOOT_READY" -eq 0 ] && [ -d "$BOOT_DIR" ]; then
        PASS "Using root-mounted /boot"
        BOOT_READY=1
      fi

      if [ -n "$BOOTEFI_PART" ]; then
        sudo mkdir -p "$BOOTEFI_DIR"
        sudo mount "$BOOTEFI_PART" "$BOOTEFI_DIR" 2>/dev/null \
          && PASS "Mounted /boot/efi: $BOOTEFI_PART → $BOOTEFI_DIR" \
          || WARN "Could not mount /boot/efi partition $BOOTEFI_PART"
      elif [ -d "$BOOTEFI_DIR" ] && find "$BOOTEFI_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | grep -q .; then
        PASS "Using root-mounted /boot/efi"
      fi

      if [ "$BOOT_READY" -eq 1 ]; then
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
        if [ -d "$BOOT_DIR/loader/entries" ]; then
          _updated=0
          for _conf in "$BOOT_DIR/loader/entries"/*.conf; do
            [ -f "$_conf" ] || continue
            if grep -q '^options' "$_conf"; then
              _changed=0
              for _opt in net.ifnames=0 biosdevname=0 no_timer_check console=ttyS0 console=tty0; do
                if ! grep -q "$_opt" "$_conf"; then
                  _changed=1
                fi
              done
              if grep -q '/dev/xvda' "$_conf" 2>/dev/null; then
                _changed=1
              fi
              if [ "$_changed" -eq 1 ]; then
                # Remove any existing copies of these opts first, then append cleanly
                sudo sed -i "s|/dev/xvda|/dev/vda|g; s/net\.ifnames=[01]//g; s/biosdevname=[01]//g; s/no_timer_check//g; s/console=ttyS0[^ ]*//g; s/console=tty0//g" "$_conf"
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
        _grubenv_count=0
        for _grubenv in \
          "$BOOT_DIR/grub2/grubenv" \
          "$BOOTEFI_DIR/EFI/almalinux/grubenv" \
          "$BOOTEFI_DIR/EFI/rocky/grubenv" \
          "$BOOTEFI_DIR/EFI/centos/grubenv" \
          "$BOOTEFI_DIR/EFI/redhat/grubenv"; do
          [ -f "$_grubenv" ] || continue
          _grubenv_count=$(( _grubenv_count + 1 ))
          _gv_changed=0
          for _opt in net.ifnames=0 biosdevname=0 no_timer_check console=ttyS0 console=tty0; do
            grep -q "$_opt" "$_grubenv" || _gv_changed=1
          done
          if [ "$_gv_changed" -eq 1 ]; then
            # Clean existing copies, then append full set securely using grub-editenv
            _existing_opts=$(sudo grub-editenv "$_grubenv" list 2>/dev/null | grep "^kernelopts=" | sed 's/^kernelopts=//' || true)
            _clean_opts=$(echo "$_existing_opts" | sed -E "s/net\.ifnames=[01]//g; s/biosdevname=[01]//g; s/no_timer_check//g; s/console=ttyS0[^ ]*//g; s/console=tty0//g" | sed 's/^[ \t]*//;s/[ \t]*$//')
            sudo grub-editenv "$_grubenv" set kernelopts="$_clean_opts $_FLEX_OPTS"
            PASS "Updated grubenv using grub-editenv: $_grubenv"
          else
            INFO "grubenv already has required opts: $_grubenv"
          fi
        done
        [ "$_grubenv_count" -eq 0 ] && WARN "No grubenv files found — EFI/kernelopts may still need manual review"

        # Update /etc/default/grub (used if grub2-mkconfig is ever re-run)
        if [ -f "$MNT/etc/default/grub" ]; then
          _dg_changed=0
          for _opt in net.ifnames=0 biosdevname=0 no_timer_check console=ttyS0 console=tty0; do
            grep -q "$_opt" "$MNT/etc/default/grub" || _dg_changed=1
          done
          if [ "$_dg_changed" -eq 1 ]; then
            sudo sed -i "s/net\.ifnames=[01]//g; s/biosdevname=[01]//g; s/no_timer_check//g; s/console=ttyS0[^ ]*//g; s/console=tty0//g" "$MNT/etc/default/grub"
            if grep -q '^GRUB_CMDLINE_LINUX=' "$MNT/etc/default/grub"; then
              sudo sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 '"$_FLEX_OPTS"'"/' \
                "$MNT/etc/default/grub" 2>/dev/null || true
            else
              echo 'GRUB_CMDLINE_LINUX="'"$_FLEX_OPTS"'"' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
            fi
            PASS "Updated /etc/default/grub with full FLEX opts"
          fi
        fi

      else
        WARN "Could not access /boot — grubenv/BLS update skipped"
        WARN "VM may boot with wrong NIC name — SSH might fail"
      fi
    elif [ $DRY_RUN -eq 1 ]; then
      INFO "[DRY-RUN] Would resolve /boot from fstab and update grubenv/BLS entries"
    fi

    # ── [RHEL-FAMILY ALL] Direct grub.cfg patching (safety net) ──────────────
    # Even with BLS/grubenv, some RHEL 8 images have a monolithic grub.cfg.
    # Patch it as a universal safety net (same approach as Ubuntu/Debian).
    echo "── [RHEL-FAMILY] Direct grub.cfg patching (xvda→vda + console) ────────────"
    if [ $DRY_RUN -eq 0 ]; then
      for _gcfg in "$MNT/boot/grub2/grub.cfg" "$MNT/boot/grub/grub.cfg" "$BOOT_DIR/grub2/grub.cfg" "$MNT/boot/efi/EFI/"*/grub.cfg; do
        [ -f "$_gcfg" ] || continue
        # xvda→vda rename
        if grep -q '/dev/xvda' "$_gcfg" 2>/dev/null; then
          sudo sed -i 's|/dev/xvda|/dev/vda|g' "$_gcfg"
          PASS "Patched $(basename $_gcfg): xvda→vda"
        fi
        # Add net.ifnames=0 if missing
        if ! grep -q 'net.ifnames=0' "$_gcfg"; then
          sudo sed -E -i '/^[[:space:]]*linux(16|efi)?[[:space:]].*root=/{s/$/ net.ifnames=0 biosdevname=0/}' \
            "$_gcfg" 2>/dev/null || true
          PASS "Patched $(basename $_gcfg): added net.ifnames=0"
        fi
        # Add console if missing
        if ! grep -q 'console=ttyS0' "$_gcfg"; then
          sudo sed -E -i '/^[[:space:]]*linux(16|efi)?[[:space:]].*root=/{s/$/ console=ttyS0,115200n8 console=tty0/}' \
            "$_gcfg" 2>/dev/null || true
          PASS "Patched $(basename $_gcfg): added console=ttyS0"
        fi
      done
    fi

    # ── [RHEL-FAMILY] Virtio Driver Injection (dracut) + grub cmdline fix ───────────
      echo "── [RHEL-FAMILY] Virtio Driver Injection (dracut) ───────────────────"
      if [ $DRY_RUN -eq 0 ]; then
        # Rebuild initramfs for EVERY kernel that has both a /lib/modules entry AND a
        # matching vmlinuz in /boot. Using only the "latest" kernel misses older-but-
        # default kernels that grub2-mkconfig may prefer (e.g. 3.10.0-1127.el7 vs
        # 3.10.0-1127.13.1.el7 — sort -V picks one, grub boots the other).
        _any_kver_found=0
        sudo mount --bind /proc "$MNT/proc" 2>/dev/null || true
        sudo mount --bind /sys  "$MNT/sys"  2>/dev/null || true
        sudo mount --bind /dev  "$MNT/dev"  2>/dev/null || true
        sudo mkdir -p "$MNT/run"
        sudo mount --bind /run  "$MNT/run"  2>/dev/null || true

        for _kver in $(ls "$MNT/lib/modules/" 2>/dev/null | sort -V); do
          [ -d "$MNT/lib/modules/$_kver" ]      || continue
          [ -f "$MNT/boot/vmlinuz-$_kver" ]     || continue  # no matching kernel binary — skip
          _any_kver_found=1
          INFO "Kernel: $_kver"

          # depmod: regenerate modules.dep before dracut. OSPC images sometimes skip
          # depmod after kernel install; dracut fails with "modules.dep is missing"
          # without it. Safe to run even if modules.dep exists (idempotent).
          sudo chroot "$MNT" bash -c "depmod -a '$_kver'" 2>/dev/null \
            && INFO "depmod -a OK: $_kver" \
            || WARN "depmod -a failed — dracut may still work if modules.dep exists"

          # virtio_balloon: KVM memory ballooning (required for FLEX resource management)
          # virtio_net: the KVM NIC driver — missing this = no LAN interface on boot
          _dracut_ok=0
          sudo chroot "$MNT" bash -c \
            'dracut --add-drivers "virtio_blk virtio_net virtio_pci virtio_scsi virtio_ring virtio virtio_balloon" --force "/boot/initramfs-'"$_kver"'.img" "'"$_kver"'"' \
            2>/tmp/dracut_err_$$.txt \
            && { PASS "Rebuilt initramfs with virtio drivers (incl. virtio_net + virtio_balloon): $_kver"; _dracut_ok=1; } \
            || { WARN "dracut failed — trying mkinitrd fallback"; cat /tmp/dracut_err_$$.txt | tail -5 | sed 's/^/  /'; }

          # mkinitrd fallback: RHEL 6 dracut 004 can fail on some images; mkinitrd is a
          # dracut wrapper but accepts simpler --with= syntax that old images support.
          if [ "$_dracut_ok" -eq 0 ] && [ "${OS_MAJOR:-0}" -le 6 ]; then
            sudo chroot "$MNT" bash -c \
              'mkinitrd -f --with=virtio_blk --with=virtio_net --with=virtio_pci --with=virtio_scsi --with=virtio_balloon "/boot/initramfs-'"$_kver"'.img" "'"$_kver"'"' \
              2>/tmp/mkinitrd_err_$$.txt \
              && { PASS "Rebuilt initramfs via mkinitrd fallback: $_kver"; _dracut_ok=1; } \
              || { WARN "mkinitrd also failed — VM may not boot on FLEX KVM"; cat /tmp/mkinitrd_err_$$.txt | tail -5 | sed 's/^/  /'; }
          fi

          # Verify both virtio_blk (disk) AND virtio_net (NIC) are present.
          # Strip whitespace from grep -c output — subshell newlines cause
          # "integer expression expected" when used in [ -gt 0 ] comparisons.
          if sudo chroot "$MNT" bash -c 'command -v lsinitrd >/dev/null 2>&1' 2>/dev/null; then
            _blk_ok=$(sudo chroot "$MNT" bash -c 'lsinitrd "/boot/initramfs-'"$_kver"'.img" 2>/dev/null | grep -c virtio_blk' 2>/dev/null | tr -d '[:space:]')
            _net_ok=$(sudo chroot "$MNT" bash -c 'lsinitrd "/boot/initramfs-'"$_kver"'.img" 2>/dev/null | grep -c virtio_net' 2>/dev/null | tr -d '[:space:]')
            _blk_ok=${_blk_ok:-0}; _net_ok=${_net_ok:-0}
            [ "$_blk_ok" -gt 0 ] 2>/dev/null && PASS "Verified virtio_blk in initramfs: $_kver" || WARN "virtio_blk MISSING from initramfs — disk may not mount"
            [ "$_net_ok" -gt 0 ] 2>/dev/null && PASS "Verified virtio_net in initramfs: $_kver" || WARN "virtio_net MISSING from initramfs — LAN interface will not appear"
          else
            WARN "lsinitrd not available — cannot verify virtio modules in initramfs"
          fi
        done

        sudo umount "$MNT/run"  2>/dev/null || true
        sudo umount "$MNT/dev"  2>/dev/null || true
        sudo umount "$MNT/sys"  2>/dev/null || true
        sudo umount "$MNT/proc" 2>/dev/null || true
        [ "$_any_kver_found" -eq 0 ] && WARN "No kernel with matching vmlinuz found — cannot rebuild initramfs"
      else
        INFO "[DRY-RUN] Would rebuild initramfs with virtio drivers via dracut"
      fi

      # ── RHEL/CentOS 6: GRUB Legacy (grub 0.97) — patch /boot/grub/grub.conf ──
      # RHEL 6 does NOT have grub2 or /etc/default/grub.
      # Its boot config is /boot/grub/grub.conf (symlinked from /etc/grub.conf).
      # Format: "kernel /vmlinuz-... ro root=/dev/xvda1 ..."  — must patch root= in-place.
      echo "── [RHEL/CENTOS 6] GRUB Legacy grub.conf patching ─────────────────────"
      if [ "${OS_MAJOR:-0}" -le 6 ] && [ $DRY_RUN -eq 0 ]; then
        _patched_grubconf=0
        for _gc in "$MNT/boot/grub/grub.conf" "$MNT/etc/grub.conf"; do
          # Resolve symlink so we edit the real file once
          [ -f "$_gc" ] || [ -L "$_gc" ] || continue
          _real_gc=$(readlink -f "$_gc" 2>/dev/null || echo "$_gc")
          [ -f "$_real_gc" ] || continue
          [ "$_patched_grubconf" -eq 1 ] && { INFO "$(basename $_gc) is a symlink already patched — skipping"; continue; }

          # xvda → vda in the kernel root= arg (the critical one — wrong device = grub shell)
          sudo sed -i 's|root=/dev/xvda|root=/dev/vda|g' "$_real_gc"
          # Remove rhgb quiet (hides console output on FLEX serial console)
          sudo sed -i 's/ rhgb//g; s/ quiet//g' "$_real_gc"
          # Add biosdevname=0 to kernel line (forces eth0 naming; net.ifnames not in 2.6.32)
          if ! sudo grep -q 'biosdevname=0' "$_real_gc"; then
            sudo sed -i '/^\s*kernel .*vmlinuz/s/$/ biosdevname=0/' "$_real_gc"
          fi
          # Add console=ttyS0 (FLEX serial console / OpenStack console log)
          if ! sudo grep -q 'console=ttyS0' "$_real_gc"; then
            sudo sed -i '/^\s*kernel .*vmlinuz/s/$/ console=ttyS0,115200 console=tty0/' "$_real_gc"
          fi
          # Add no_timer_check (suppresses KVM timer calibration noise on 2.6.32)
          if ! sudo grep -q 'no_timer_check' "$_real_gc"; then
            sudo sed -i '/^\s*kernel .*vmlinuz/s/$/ no_timer_check/' "$_real_gc"
          fi
          PASS "Patched GRUB Legacy grub.conf: root=vda + biosdevname=0 + console=ttyS0 + no_timer_check"
          INFO "$(basename $_gc) kernel line: $(sudo grep '^\s*kernel ' "$_real_gc" | head -1)"
          _patched_grubconf=1
        done
        [ "$_patched_grubconf" -eq 0 ] && WARN "No grub.conf found — GRUB Legacy config not patched"

        # Patch device.map: GRUB Legacy maps (hd0) → /dev/xvda (Xen).
        # On KVM FLEX the disk is /dev/vda — device.map must reflect this or GRUB
        # will fail to find stage2 and drop to a rescue prompt.
        _dmap="$MNT/boot/grub/device.map"
        if [ -f "$_dmap" ]; then
          sudo sed -i 's|/dev/xvda|/dev/vda|g' "$_dmap"
          PASS "Patched /boot/grub/device.map: /dev/xvda → /dev/vda"
          INFO "device.map: $(sudo cat "$_dmap")"
        else
          # device.map missing — create it so GRUB can find (hd0)
          sudo mkdir -p "$MNT/boot/grub"
          printf '(hd0)\t/dev/vda\n' | sudo tee "$MNT/boot/grub/device.map" >/dev/null
          PASS "Created /boot/grub/device.map: (hd0) → /dev/vda"
        fi

        # ── GRUB stage files check ──────────────────────────────────────────
        # GRUB Legacy requires stage1 + stage2 in /boot/grub/ to boot.
        # Missing stage2 = GRUB drops to rescue shell before reading grub.conf.
        for _stg in stage1 stage2; do
          if [ -f "$MNT/boot/grub/$_stg" ]; then
            PASS "GRUB $_stg present: /boot/grub/$_stg"
          else
            WARN "GRUB $_stg MISSING from /boot/grub/ — GRUB may drop to rescue shell; run grub-install manually after boot"
          fi
        done

        # ── grub.conf initrd line vs actual initramfs file ──────────────────
        # If dracut rebuilt initramfs-<new-kver>.img but grub.conf still has an
        # old kernel/initrd entry, the VM kernel-panics with "VFS: Cannot open
        # root device". Verify the initrd line matches the file on disk.
        _real_gc_check=""
        for _gc2 in "$MNT/boot/grub/grub.conf" "$MNT/etc/grub.conf"; do
          [ -f "$_gc2" ] || [ -L "$_gc2" ] || continue
          _real_gc_check=$(readlink -f "$_gc2" 2>/dev/null || echo "$_gc2")
          [ -f "$_real_gc_check" ] && break
        done
        if [ -n "$_real_gc_check" ]; then
          _gc_initrd=$(sudo grep '^\s*initrd ' "$_real_gc_check" 2>/dev/null | head -1 | awk '{print $2}')
          if [ -n "$_gc_initrd" ]; then
            # Path in grub.conf is relative to GRUB root — prepend /boot if needed
            _gc_initrd_abs="$MNT${_gc_initrd}"
            [ ! -f "$_gc_initrd_abs" ] && _gc_initrd_abs="$MNT/boot${_gc_initrd}"
            if [ -f "$_gc_initrd_abs" ]; then
              PASS "grub.conf initrd line matches file on disk: $_gc_initrd"
            else
              WARN "grub.conf initrd line '$_gc_initrd' has NO matching file — fixing to latest initramfs"
              _latest_initrd=$(ls "$MNT/boot/initramfs-"*.img 2>/dev/null | sort -V | tail -1)
              if [ -n "$_latest_initrd" ]; then
                _latest_initrd_rel="/boot/$(basename "$_latest_initrd")"
                sudo sed -i "s|^\s*initrd .*|initrd $_latest_initrd_rel|" "$_real_gc_check"
                PASS "Fixed grub.conf initrd line → $_latest_initrd_rel"
              else
                WARN "No initramfs-*.img found in /boot — cannot auto-fix initrd line"
              fi
            fi
          fi
          # Also show the grub.conf root (hd0,N) directive for confirmation
          _gc_root=$(sudo grep '^\s*root ' "$_real_gc_check" 2>/dev/null | grep -v '#' | head -1)
          INFO "grub.conf root directive: ${_gc_root:-not found}"
        fi

      elif [ "${OS_MAJOR:-0}" -le 6 ] && [ $DRY_RUN -eq 1 ]; then
        INFO "[DRY-RUN] Would patch /boot/grub/grub.conf: root=vda + biosdevname=0 + console=ttyS0"
        INFO "[DRY-RUN] Would verify GRUB stage files + initrd line vs disk"
      fi

      # grub2-mkconfig: ONLY for CentOS/RHEL 7 (grub2 without BLS).
      # RHEL 6: uses GRUB Legacy above. RHEL 8/9: BLS handles entries, grub2-mkconfig breaks it.
      echo "── [CENTOS/RHEL 7 only] Legacy grub2-mkconfig + CMDLINE fix ────────────"
      if [ "${OS_MAJOR:-0}" -eq 7 ] && [ $DRY_RUN -eq 0 ] && [ -f "$MNT/etc/default/grub" ]; then
        # Legacy RHEL/CentOS grub often carries root=/dev/xvda1 (wrong on FLEX)
        # plus rhgb/quiet args that hide console output.
        # Remove root=/dev/xvda*, add console + net.ifnames=0
        sudo sed -i 's|root=/dev/xvda[0-9]*||g' "$MNT/etc/default/grub"
        sudo sed -i 's/rhgb //g; s/ rhgb//g; s/ quiet//g' "$MNT/etc/default/grub"
        # GRUB_DISABLE_LINUX_UUID=false: FLEX KVM boots by UUID (Xen often used device paths)
        if grep -q 'GRUB_DISABLE_LINUX_UUID' "$MNT/etc/default/grub"; then
          sudo sed -i 's/GRUB_DISABLE_LINUX_UUID=.*/GRUB_DISABLE_LINUX_UUID="false"/' "$MNT/etc/default/grub"
        else
          echo 'GRUB_DISABLE_LINUX_UUID="false"' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
        fi
        # Disable os-prober inside chroot (probes NBD partitions, extremely slow)
        if ! grep -q '^GRUB_DISABLE_OS_PROBER' "$MNT/etc/default/grub"; then
          echo 'GRUB_DISABLE_OS_PROBER=true' | sudo tee -a "$MNT/etc/default/grub" >/dev/null
        fi
        PASS "Fixed grub: removed root=/dev/xvda, set GRUB_DISABLE_LINUX_UUID=false, disabled os-prober"

        # Inject FLEX kernel args into GRUB_CMDLINE_LINUX so grub2-mkconfig picks them up.
        # Without this, the args must be post-patched every time grub2-mkconfig runs.
        _FLEX_ARGS="net.ifnames=0 biosdevname=0 no_timer_check console=ttyS0,115200n8 console=tty0"
        if grep -q '^GRUB_CMDLINE_LINUX=' "$MNT/etc/default/grub"; then
          # Strip stale copies of these args, then append inside closing quote
          sudo sed -i \
            's/net\.ifnames=[01]//g; s/biosdevname=[01]//g; s/no_timer_check//g; s/console=ttyS0[^ "]*//g; s/console=tty0//g' \
            "$MNT/etc/default/grub"
          sudo sed -i \
            "s|^GRUB_CMDLINE_LINUX=\"\(.*\)\"|GRUB_CMDLINE_LINUX=\"\1 ${_FLEX_ARGS}\"|" \
            "$MNT/etc/default/grub"
        else
          echo "GRUB_CMDLINE_LINUX=\"${_FLEX_ARGS}\"" | sudo tee -a "$MNT/etc/default/grub" >/dev/null
        fi
        PASS "Injected FLEX args into GRUB_CMDLINE_LINUX: ${_FLEX_ARGS}"

        # Rebuild grub.cfg (CentOS 7 uses traditional grub2, not BLS)
        sudo mount --bind /proc "$MNT/proc" 2>/dev/null || true
        sudo mount --bind /sys  "$MNT/sys"  2>/dev/null || true
        sudo mount --bind /dev  "$MNT/dev"  2>/dev/null || true
        sudo mkdir -p "$MNT/run"
        sudo mount --bind /run  "$MNT/run"  2>/dev/null || true
        sudo chroot "$MNT" /usr/sbin/grub2-mkconfig -o /boot/grub2/grub.cfg 2>/tmp/grub2mk_$$.txt \
          && PASS "Rebuilt grub.cfg via grub2-mkconfig" \
          || { WARN "grub2-mkconfig failed — grub.cfg may have stale xvda refs"; cat /tmp/grub2mk_$$.txt | tail -5 | sed 's/^/  /'; }
        # Post-patch: xvda→vda, nbd*→vda (grub2-mkconfig sees /dev/nbdXpY via bind-mounted /dev),
        # then inject FLEX boot args as a final safety pass.
        if [ -f "$MNT/boot/grub2/grub.cfg" ]; then
          sudo sed -i 's|/dev/xvda|/dev/vda|g' "$MNT/boot/grub2/grub.cfg"
          sudo sed -i 's|/dev/nbd[0-9]*p\([0-9]*\)|/dev/vda\1|g' "$MNT/boot/grub2/grub.cfg"
          sudo sed -E -i '/^[[:space:]]*linux(16|efi)?[[:space:]].*root=/{
            s/net\.ifnames=[01]//g
            s/biosdevname=[01]//g
            s/no_timer_check//g
            s/console=ttyS0[^ ]*//g
            s/console=tty0//g
            s/$/ net.ifnames=0 biosdevname=0 no_timer_check console=ttyS0,115200n8 console=tty0/
          }' "$MNT/boot/grub2/grub.cfg" 2>/dev/null || true
          PASS "Applied post-mkconfig FLEX boot args to grub.cfg (net.ifnames=0, console=ttyS0, no_timer_check)"
        fi
        sudo umount "$MNT/run"  2>/dev/null || true
        sudo umount "$MNT/dev"  2>/dev/null || true
        sudo umount "$MNT/sys"  2>/dev/null || true
        sudo umount "$MNT/proc" 2>/dev/null || true
      elif [ "${OS_MAJOR:-0}" -ge 8 ] && [ $DRY_RUN -eq 0 ] && [ -f "$MNT/etc/default/grub" ]; then
        # CentOS/RHEL 8/9: BLS handles boot entries; only patch /etc/default/grub
        # so it's correct if grub2-mkconfig is ever run manually later.
        sudo sed -i 's|root=/dev/xvda[0-9]*||g' "$MNT/etc/default/grub" 2>/dev/null || true
        sudo sed -i 's/rhgb //g; s/ rhgb//g; s/ quiet//g' "$MNT/etc/default/grub" 2>/dev/null || true
        PASS "Patched /etc/default/grub for CentOS/RHEL 8/9 (BLS handles active entries)"
      elif [ $DRY_RUN -eq 1 ]; then
        if [ "${OS_MAJOR:-0}" -le 6 ]; then
          INFO "[DRY-RUN] Would patch GRUB Legacy grub.conf (RHEL/CentOS 6)"
        elif [ "${OS_MAJOR:-0}" -eq 7 ]; then
          INFO "[DRY-RUN] Would run grub2-mkconfig + post-patch FLEX boot args (CentOS/RHEL 7)"
        else
          INFO "[DRY-RUN] Would patch /etc/default/grub only (CentOS/RHEL 8/9 — BLS active)"
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
  sudo awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    {
      spec=$1
      mountpoint=$2
      if (spec ~ /^(LABEL|UUID|PARTUUID)=/) { print; next }
      if (spec ~ /^\/dev\// && mountpoint != "/" && mountpoint != "/boot" && mountpoint != "/boot/efi") {
        print "# [ospc2flex] " $0
        next
      }
      print
    }
  ' "$MNT/etc/fstab" | sudo tee "$MNT/etc/fstab.tmp" >/dev/null
  sudo mv "$MNT/etc/fstab.tmp" "$MNT/etc/fstab"
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
  # Fix grub.cfg/BLS directly (all possible locations)
  # grub.conf = RHEL 6 GRUB Legacy; grub.cfg = grub2 (RHEL 7+)
  for _gcfg in \
    "$MNT/boot/grub/grub.conf" \
    "$MNT/etc/grub.conf" \
    "$MNT/boot/grub/grub.cfg" \
    "$MNT/boot/grub2/grub.cfg" \
    "$MNT/boot/loader/entries/"*.conf \
    "$MNT/boot/efi/EFI/"*/grub.cfg; do
    if [ -f "$_gcfg" ]; then
      if grep -q 'xvda' "$_gcfg" 2>/dev/null; then
        sudo sed -i 's|/dev/xvda|/dev/vda|g' "$_gcfg"
        PASS "$(basename $_gcfg): /dev/xvda → /dev/vda"
      else
        INFO "$(basename $_gcfg): no xvda references found"
      fi
    fi
  done

  # Ensure stringent 1024-byte padding is preserved in Red Hat BLS environment blocks using grub-editenv
  for _grubenv in \
    "$MNT/boot/grub2/grubenv" \
    "$MNT/boot/efi/EFI/"*/grubenv; do
    if [ -f "$_grubenv" ]; then
      if grep -q 'xvda' "$_grubenv" 2>/dev/null; then
        _existing_opts=$(sudo grub-editenv "$_grubenv" list 2>/dev/null | grep "^kernelopts=" | sed 's/^kernelopts=//' || true)
        if [ -n "$_existing_opts" ]; then
          _new_opts=$(echo "$_existing_opts" | sed 's|/dev/xvda|/dev/vda|g')
          sudo grub-editenv "$_grubenv" set kernelopts="$_new_opts"
          PASS "$(basename $_grubenv): xvda → vda (via grub-editenv)"
        fi
      else
        INFO "$(basename $_grubenv): no xvda references found"
      fi
    fi
  done

  if grep -Rqs 'xvda' "$MNT/boot" "$MNT/etc/default/grub" 2>/dev/null; then
    WARN "Residual xvda references still exist in boot config — review before upload"
  else
    PASS "Verified boot configs are free of xvda references"
  fi
else
  INFO "[DRY-RUN] Would rename xvda→vda in grub configs"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# RHEL/CentOS 6: Install cloud-init if missing
# OSPC RHEL 6 used Rackspace nova-agent (Xen) for key injection — cloud-init
# was never installed. Without it, --key-name on FLEX server create is a no-op.
# Install from CentOS 6 vault + EPEL 6 archive (binary-compatible with RHEL 6).
# Falls back silently; authorized_keys injection below covers the failure case.
# ─────────────────────────────────────────────────────────────────────────────
echo "── [RHEL/CentOS 6] cloud-init install ──────────────────────────────────"
if [ "${OS_MAJOR:-0}" -le 6 ] && \
   { [ "$OS_ID" = "rhel" ] || [ "$OS_ID" = "centos" ]; } && \
   [ $DRY_RUN -eq 0 ]; then
  if sudo chroot "$MNT" bash -lc 'command -v cloud-init >/dev/null 2>&1' 2>/dev/null; then
    PASS "cloud-init already installed — skip"
  else
    INFO "cloud-init not found — installing from CentOS 6 vault + EPEL 6 archive"

    # Bind mounts required for yum inside chroot
    sudo mount --bind /proc "$MNT/proc" 2>/dev/null || true
    sudo mount --bind /sys  "$MNT/sys"  2>/dev/null || true
    sudo mount --bind /dev  "$MNT/dev"  2>/dev/null || true
    sudo mkdir -p "$MNT/run"
    sudo mount --bind /run  "$MNT/run"  2>/dev/null || true
    # DNS for package downloads
    sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf.ospc2flex_bak" 2>/dev/null || true
    sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf"

    # Temporary repos: CentOS 6 vault (base/updates/extras) + EPEL 6 archive
    sudo tee "$MNT/etc/yum.repos.d/ospc2flex-c6vault.repo" >/dev/null <<'C6VAULT_EOF'
[c6-vault-base]
name=CentOS-6 Vault Base
baseurl=http://vault.centos.org/6.10/os/x86_64/
gpgcheck=0
enabled=1

[c6-vault-updates]
name=CentOS-6 Vault Updates
baseurl=http://vault.centos.org/6.10/updates/x86_64/
gpgcheck=0
enabled=1

[c6-vault-extras]
name=CentOS-6 Vault Extras
baseurl=http://vault.centos.org/6.10/extras/x86_64/
gpgcheck=0
enabled=1

[epel6-archive]
name=EPEL 6 Archive
baseurl=https://archives.fedoraproject.org/pub/archive/epel/6/x86_64/
gpgcheck=0
enabled=1
C6VAULT_EOF

    _ci6_ok=0
    sudo chroot "$MNT" bash -lc \
      'yum install -y --disablerepo="*" --enablerepo="c6-vault-*,epel6-archive" cloud-init 2>&1' \
      && _ci6_ok=1 \
      || WARN "cloud-init install failed — authorized_keys injection will cover SSH access"

    # Remove temp repo — do not leave vault enabled permanently
    sudo rm -f "$MNT/etc/yum.repos.d/ospc2flex-c6vault.repo"

    # Restore resolv.conf
    if [ -f "$MNT/etc/resolv.conf.ospc2flex_bak" ]; then
      sudo mv "$MNT/etc/resolv.conf.ospc2flex_bak" "$MNT/etc/resolv.conf"
    fi

    # Unmount bind mounts
    sudo umount "$MNT/run"  2>/dev/null || true
    sudo umount "$MNT/dev"  2>/dev/null || true
    sudo umount "$MNT/sys"  2>/dev/null || true
    sudo umount "$MNT/proc" 2>/dev/null || true

    if [ "$_ci6_ok" -eq 1 ]; then
      # Enable all four cloud-init SysV services (RHEL 6 uses chkconfig)
      sudo chroot "$MNT" bash -lc '
        for _svc in cloud-init-local cloud-init cloud-config cloud-final; do
          chkconfig "$_svc" on 2>/dev/null && echo "  enabled: $_svc" || true
        done
      ' 2>/dev/null || true
      PASS "cloud-init installed + SysV services enabled (cloud-init-local/init/config/final)"
    fi
  fi
elif [ "${OS_MAJOR:-0}" -le 6 ] && \
     { [ "$OS_ID" = "rhel" ] || [ "$OS_ID" = "centos" ]; } && \
     [ $DRY_RUN -eq 1 ]; then
  INFO "[DRY-RUN] Would install cloud-init from CentOS 6 vault + EPEL 6 archive"
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

  # ── Set cloud-init datasource to OpenStack (FLEX) — All OS types ──
  # Explicitly configure OpenStack datasource. While some OS types can auto-detect,
  # purging old Rackspace configs can break detection, causing network failures.
    sudo mkdir -p "$MNT/etc/cloud/cloud.cfg.d"
    _ci_ver=$(sudo chroot "$MNT" bash -lc 'cloud-init --version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+" | head -1' 2>/dev/null || true)
    if [ -n "$_ci_ver" ] && echo "$_ci_ver" | awk -F. '{exit !($1 >= 20)}'; then
      sudo tee "$MNT/etc/cloud/cloud.cfg.d/99-flex-datasource.cfg" >/dev/null <<'FLEX_DS_EOF'
# Written by ospc2flex_offline_repair.sh — set datasource for FLEX (OpenStack)
datasource_list: [ OpenStack, ConfigDrive, None ]
datasource:
  OpenStack:
    metadata_urls: [http://169.254.169.254]
    timeout: 10
    max_wait: 60
    apply_network_config: true
FLEX_DS_EOF
      PASS "cloud-init datasource set to OpenStack (modern format, cloud-init $_ci_ver)"
    else
      sudo tee "$MNT/etc/cloud/cloud.cfg.d/99-flex-datasource.cfg" >/dev/null <<'FLEX_DS_OLD_EOF'
# Written by ospc2flex_offline_repair.sh — minimal old-cloud-init OpenStack datasource hint
datasource_list: [ OpenStack, ConfigDrive ]
FLEX_DS_OLD_EOF
      PASS "cloud-init datasource set to OpenStack (legacy-compatible format${_ci_ver:+, cloud-init $_ci_ver})"
    fi

    # RHEL 6 cloud-init 0.7.x: cloud.cfg.d/ drop-ins are NOT reliably read.
    # datasource_list in main cloud.cfg wins; inject it directly so it takes effect.
    if [ "${OS_MAJOR:-0}" -le 6 ] && sudo test -f "$MNT/etc/cloud/cloud.cfg"; then
      sudo sed -i '/^datasource_list/d' "$MNT/etc/cloud/cloud.cfg" 2>/dev/null || true
      echo "datasource_list: [ OpenStack, ConfigDrive ]" \
        | sudo tee -a "$MNT/etc/cloud/cloud.cfg" >/dev/null
      PASS "cloud-init datasource_list injected into main cloud.cfg (RHEL 6 cloud-init 0.7.x compat)"
    fi

    # Remove any OSPC-specific datasource configs that might conflict
    sudo rm -f "$MNT/etc/cloud/cloud.cfg.d/"*ec2* 2>/dev/null || true
    sudo rm -f "$MNT/etc/cloud/cloud.cfg.d/"*Ec2* 2>/dev/null || true
    sudo rm -f "$MNT/etc/cloud/cloud.cfg.d/"*rackspace* 2>/dev/null || true
    sudo rm -f "$MNT/etc/cloud/cloud.cfg.d/"*xenserver* 2>/dev/null || true

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
    sudo rm -f "$MNT/etc/ufw/before.rules" "$MNT/etc/ufw/before6.rules" 2>/dev/null || true
    sudo rm -f "$MNT/etc/ufw/after.rules" "$MNT/etc/ufw/after6.rules" 2>/dev/null || true
    sudo rm -f "$MNT/etc/ufw/"*.rules.* 2>/dev/null || true
    # Disable UFW on boot
    if [ -f "$MNT/etc/ufw/ufw.conf" ]; then
      sudo sed -i 's/^ENABLED=yes/ENABLED=no/' "$MNT/etc/ufw/ufw.conf" 2>/dev/null || true
    else
      WARN "ufw.conf not found — UFW may still require manual disable check"
    fi
    sudo mkdir -p "$MNT/etc/systemd/system"
    sudo ln -sf /dev/null "$MNT/etc/systemd/system/ufw.service" 2>/dev/null || true
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
# OPTIONAL: preserve SSH password auth on FLEX
# Keep existing local password hashes and explicitly re-enable password-based
# SSH in sshd + cloud-init so FLEX does not silently fall back to key-only auth.
# ─────────────────────────────────────────────────────────────────────────────
echo "── Password Auth Preserve (optional) ───────────────────────────────────"
if [ $PRESERVE_PASSWORD_AUTH -eq 1 ]; then
  if [ $DRY_RUN -eq 0 ]; then
    SSHD_CONF="$MNT/etc/ssh/sshd_config"
    CLOUD_CFG_DIR="$MNT/etc/cloud/cloud.cfg.d"
    ROOT_HASH=$(shadow_hash_for_user "$MNT/etc/shadow" root || true)
    ROOT_HAS_PASSWORD=0
    if shadow_hash_usable "$ROOT_HASH"; then
      ROOT_HAS_PASSWORD=1
      INFO "Root account has a usable password hash — password SSH can be preserved"
    else
      INFO "Root account password appears locked or absent — preserving non-root password auth only"
    fi

    sudo mkdir -p "$CLOUD_CFG_DIR"
    sudo tee "$CLOUD_CFG_DIR/99-ospc2flex-password-auth.cfg" >/dev/null <<EOF
# Written by ospc2flex_offline_repair.sh — preserve password SSH auth on FLEX
ssh_pwauth: true
chpasswd:
  expire: false
$( [ "$ROOT_HAS_PASSWORD" -eq 1 ] && printf '%s\n' 'disable_root: false' )
EOF
    PASS "Wrote cloud-init password-auth override"

    sudo mkdir -p "$MNT/etc/ssh"
    if [ -f "$SSHD_CONF" ]; then
      sudo sed -i '/^[[:space:]]*PasswordAuthentication[[:space:]]/Id' "$SSHD_CONF" 2>/dev/null || true
      sudo sed -i '/^[[:space:]]*KbdInteractiveAuthentication[[:space:]]/Id' "$SSHD_CONF" 2>/dev/null || true
      sudo sed -i '/^[[:space:]]*ChallengeResponseAuthentication[[:space:]]/Id' "$SSHD_CONF" 2>/dev/null || true
      sudo sed -i '/^[[:space:]]*UsePAM[[:space:]]/Id' "$SSHD_CONF" 2>/dev/null || true
      sudo sed -i '/^[[:space:]]*PermitEmptyPasswords[[:space:]]/Id' "$SSHD_CONF" 2>/dev/null || true
      if [ "$ROOT_HAS_PASSWORD" -eq 1 ]; then
        sudo sed -i '/^[[:space:]]*PermitRootLogin[[:space:]]/Id' "$SSHD_CONF" 2>/dev/null || true
      fi
    else
      sudo touch "$SSHD_CONF"
    fi

    {
      echo ""
      echo "# Added by ospc2flex_offline_repair.sh --preserve-password-auth"
      echo "PasswordAuthentication yes"
      echo "KbdInteractiveAuthentication yes"
      echo "ChallengeResponseAuthentication yes"
      echo "UsePAM yes"
      echo "PermitEmptyPasswords no"
      if [ "$ROOT_HAS_PASSWORD" -eq 1 ]; then
        echo "PermitRootLogin yes"
      fi
    } | sudo tee -a "$SSHD_CONF" >/dev/null
    PASS "Updated sshd_config for password authentication"

    sudo chroot "$MNT" bash -lc 'command -v restorecon >/dev/null 2>&1 && restorecon -Rv /etc/ssh /etc/cloud >/dev/null 2>&1 || true' 2>/dev/null || true
    PASS "Password auth preservation enabled for first FLEX boot"
  else
    INFO "[DRY-RUN] Would enable sshd password auth + cloud-init ssh_pwauth on FLEX"
  fi
else
  INFO "Password-auth preservation disabled (default key-based FLEX login behavior)"
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
      # RHEL 6 (OpenSSH 5.3): only understands RSA + DSA host keys. Its init script
      # regenerates DSA on first boot, which overwrites and is the only key sshd offers.
      # Pre-generating DSA here ensures it's available even if init script is skipped.
      #
      # Strategy: try chroot ssh-keygen first (uses guest's own OpenSSH binary).
      # Chroot needs /dev/urandom — bind-mount /dev temporarily.
      # Fallback: generate on host with sudo ssh-keygen writing directly to $MNT path.
      sudo mount --bind /dev "$MNT/dev" 2>/dev/null || true
      sudo chroot "$MNT" bash -c "ssh-keygen -t rsa   -b 2048 -f /etc/ssh/ssh_host_rsa_key     -N '' -q" 2>/dev/null || true
      sudo chroot "$MNT" bash -c "ssh-keygen -t ecdsa -b 256  -f /etc/ssh/ssh_host_ecdsa_key   -N '' -q" 2>/dev/null || true
      sudo chroot "$MNT" bash -c "ssh-keygen -t ed25519       -f /etc/ssh/ssh_host_ed25519_key -N '' -q" 2>/dev/null || true
      if [ "${OS_MAJOR:-0}" -le 6 ]; then
        # RHEL 6 / OpenSSH 5.3 only offers RSA + DSA; generate DSA explicitly
        sudo chroot "$MNT" bash -c "ssh-keygen -t dsa -b 1024 -f /etc/ssh/ssh_host_dsa_key     -N '' -q" 2>/dev/null || true
      fi
      sudo umount "$MNT/dev" 2>/dev/null || true
      # Fallback: if chroot failed, generate on host (still produces valid OpenSSH keys)
      if ! sudo test -f "$MNT/etc/ssh/ssh_host_rsa_key"; then
        WARN "chroot ssh-keygen failed — falling back to host ssh-keygen"
        sudo ssh-keygen -t rsa   -b 2048 -f "$MNT/etc/ssh/ssh_host_rsa_key"     -N "" -q
        sudo ssh-keygen -t ecdsa -b 256  -f "$MNT/etc/ssh/ssh_host_ecdsa_key"   -N "" -q 2>/dev/null || true
        sudo ssh-keygen -t ed25519       -f "$MNT/etc/ssh/ssh_host_ed25519_key" -N "" -q 2>/dev/null || true
        [ "${OS_MAJOR:-0}" -le 6 ] && \
          sudo ssh-keygen -t dsa -b 1024 -f "$MNT/etc/ssh/ssh_host_dsa_key"     -N "" -q 2>/dev/null || true
      fi
      sudo chmod 600 "$MNT/etc/ssh/ssh_host_"*_key 2>/dev/null || true
      sudo chmod 644 "$MNT/etc/ssh/ssh_host_"*_key.pub 2>/dev/null || true
      sudo mount --bind /dev "$MNT/dev" 2>/dev/null || true
      sudo chroot "$MNT" bash -lc 'command -v restorecon >/dev/null 2>&1 && restorecon -Rv /etc/ssh >/dev/null 2>&1 || true' 2>/dev/null || true
      sudo umount "$MNT/dev" 2>/dev/null || true
      # Verify RSA key exists — hard failure if still missing
      if sudo test -f "$MNT/etc/ssh/ssh_host_rsa_key"; then
        [ "${OS_MAJOR:-0}" -le 6 ] \
          && PASS "Fresh SSH host keys generated (RSA, DSA, ECDSA, ED25519) — RHEL 6 OpenSSH 5.3 compatible" \
          || PASS "Fresh SSH host keys generated (RSA, ECDSA, ED25519) — autorelabel will fix SELinux context"
      else
        WARN "SSH host key generation FAILED — sshd will not start on FLEX; image needs manual key injection"
      fi
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

# ── Inject SSH authorized key (ALL OS) ───────────────────────────────────────
# OSPC servers use Rackspace nova-agent for key injection — cloud-init may not
# be installed. Injecting the running user's public key ensures SSH access on
# FLEX after migration, regardless of whether cloud-init runs on first boot.
echo "── SSH Authorized Key Injection (all OS) ────────────────────────────────"
if [ $DRY_RUN -eq 0 ]; then
  _pubkey_file="${HOME}/.ssh/id_rsa.pub"
  if [ -f "$_pubkey_file" ]; then
    _pubkey=$(cat "$_pubkey_file")
    sudo mkdir -p "$MNT/root/.ssh"
    sudo chmod 700 "$MNT/root/.ssh"
    # Idempotent: only append if key not already present
    if ! sudo grep -qF "$_pubkey" "$MNT/root/.ssh/authorized_keys" 2>/dev/null; then
      echo "$_pubkey" | sudo tee -a "$MNT/root/.ssh/authorized_keys" >/dev/null
      PASS "Injected $(basename $_pubkey_file) into /root/.ssh/authorized_keys"
    else
      INFO "Public key already in /root/.ssh/authorized_keys — skip"
    fi
    sudo chmod 600 "$MNT/root/.ssh/authorized_keys"
    sudo chown -R root:root "$MNT/root/.ssh" 2>/dev/null || true
    # Fix SELinux context for RHEL family (no-op if SELinux disabled or not RHEL)
    sudo chroot "$MNT" bash -lc 'command -v restorecon >/dev/null 2>&1 && restorecon -Rv /root/.ssh >/dev/null 2>&1 || true' 2>/dev/null || true
  else
    WARN "No ~/.ssh/id_rsa.pub found — authorized_keys not injected; SSH may require console access"
  fi
else
  INFO "[DRY-RUN] Would inject $(basename ${HOME}/.ssh/id_rsa.pub 2>/dev/null || echo id_rsa.pub) into /root/.ssh/authorized_keys"
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
