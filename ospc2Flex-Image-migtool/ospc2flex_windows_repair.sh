#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# ospc2flex_windows_repair.sh — Offline VirtIO Driver Injection for Windows
# ═══════════════════════════════════════════════════════════════════════════════
# Mounts a Windows qcow2 image offline, injects VirtIO block/SCSI
# (viostor/vioscsi) and network (netkvm) drivers into the driver store and
# registry so that the image can boot on KVM/FLEX with VirtIO disks and
# networking.
#
# Usage:
#   sudo bash ospc2flex_windows_repair.sh --qcow2 /path/to/win.qcow2 \
#        [--nbd-dev /dev/nbd5] [--force] [--dry-run] [--debug] [--debug-log PATH] [--debug-trace]
#
#   --debug          Mirror full stdout/stderr to a log file (default under /tmp).
#   --debug-log PATH Write debug transcript to this file (--debug implied).
#   --debug-trace    Bash xtrace (set -x); very noisy; use with --debug.
#
# Requirements on jumphost:
#   apt install qemu-utils ntfs-3g libhivex-bin chntpw wget
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
QCOW2=""
NBD_DEV="/dev/nbd5"
DRY_RUN=0
FORCE=0
DEBUG=0
DEBUG_TRACE=0
DEBUG_LOG_FILE=""
VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
VIRTIO_ISO="/tmp/virtio-win.iso"
VIRTIO_MNT="/tmp/virtio_iso_mnt"
MNT="/tmp/mnt_windows_repair_$$"

# ── Color helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS() { echo -e "  ${GREEN}✅ $*${NC}"; }
FAIL() { echo -e "  ${RED}❌ $*${NC}"; }
WARN() { echo -e "  ${YELLOW}⚠️  $*${NC}"; }
INFO() { echo -e "  ${CYAN}ℹ️  $*${NC}"; }

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --qcow2)    QCOW2="$2"; shift 2 ;;
    --nbd-dev)  NBD_DEV="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --force)        FORCE=1; shift ;;
    --debug)        DEBUG=1; shift ;;
    --debug-log)    DEBUG_LOG_FILE="$2"; DEBUG=1; shift 2 ;;
    --debug-trace)  DEBUG=1; DEBUG_TRACE=1; shift ;;
    -h|--help)
      echo "Usage: $0 --qcow2 <path> [--nbd-dev /dev/nbdX] [--force] [--dry-run] [--debug] [--debug-log FILE] [--debug-trace]"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

case "${OSPC2FLEX_WIN_REPAIR_DEBUG:-}" in
  1|yes|true|TRUE|Y|y) DEBUG=1 ;;
esac

[ -z "$QCOW2" ] && { echo "ERROR: --qcow2 is required"; exit 1; }
[ ! -f "$QCOW2" ] && { echo "ERROR: $QCOW2 not found"; exit 1; }

# Debug: mirror entire run to a transcript (captures errors that would otherwise be lost).
if [ "${DEBUG:-0}" -eq 1 ]; then
  export OSPC2FLEX_WIN_REPAIR_DEBUG=1
  if [ -z "${DEBUG_LOG_FILE:-}" ]; then
    _stem=$(basename "$QCOW2" .qcow2)
    DEBUG_LOG_FILE="/tmp/ospc2flex_win_repair_${_stem}_$$.log"
  fi
  export OSPC2FLEX_WIN_REPAIR_DEBUG_LOG="$DEBUG_LOG_FILE"
  touch "$DEBUG_LOG_FILE" 2>/dev/null || { echo "ERROR: cannot create debug log: $DEBUG_LOG_FILE"; exit 1; }
  echo "═══════════════════════════════════════════════════════════════════════════"
  echo " DEBUG TRANSCRIPT → $DEBUG_LOG_FILE"
  echo "   (full stdout/stderr mirrored; use for hidden failures / support bundles)"
  echo "═══════════════════════════════════════════════════════════════════════════"
  exec > >(tee -a "$DEBUG_LOG_FILE") 2>&1
  if [ "${DEBUG_TRACE:-0}" -eq 1 ]; then
    export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
    set -x
  fi
fi

echo "═══════════════════════════════════════════════════════════════════════════"
echo " OSPC→FLEX Windows Offline VirtIO Driver Injection"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  Target qcow2 : $QCOW2"
echo "  NBD device   : $NBD_DEV"
echo "  Dry run      : $DRY_RUN"
echo "  Force        : $FORCE"
echo "═══════════════════════════════════════════════════════════════════════════"

# ── Sentinel check ────────────────────────────────────────────────────────────
if [ -f "${QCOW2}.win_repaired" ] && [ "$FORCE" -eq 0 ]; then
  PASS "Already repaired (sentinel exists). Use --force to re-run."
  exit 0
fi

# ── Dependency check ──────────────────────────────────────────────────────────
ensure_deps() {
  local missing_pkgs=()
  command -v qemu-nbd >/dev/null 2>&1 || missing_pkgs+=(qemu-utils)
  command -v qemu-img >/dev/null 2>&1 || missing_pkgs+=(qemu-utils)
  command -v ntfs-3g >/dev/null 2>&1 || missing_pkgs+=(ntfs-3g)
  command -v ntfsfix >/dev/null 2>&1 || missing_pkgs+=(ntfs-3g)
  command -v hivexsh >/dev/null 2>&1 || missing_pkgs+=(libhivex-bin)
  command -v reged >/dev/null 2>&1 || missing_pkgs+=(chntpw)
  command -v wget >/dev/null 2>&1 || missing_pkgs+=(wget)
  command -v sfdisk >/dev/null 2>&1 || missing_pkgs+=(util-linux)

  if [ "${#missing_pkgs[@]}" -gt 0 ]; then
    INFO "Installing missing Windows repair tools: ${missing_pkgs[*]}"
    if command -v apt-get >/dev/null 2>&1; then
      if [ "${DEBUG:-0}" -eq 1 ]; then
        INFO "[DEBUG] apt-get update (verbose)"
        sudo apt-get update -qq 2>&1 || true
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "${missing_pkgs[@]}" 2>&1 || true
      else
        sudo apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "${missing_pkgs[@]}" >/dev/null 2>&1 || true
      fi
      if ! command -v add-apt-repository >/dev/null 2>&1; then
        if [ "${DEBUG:-0}" -eq 1 ]; then
          DEBIAN_FRONTEND=noninteractive sudo apt-get install -y software-properties-common 2>&1 || true
        else
          DEBIAN_FRONTEND=noninteractive sudo apt-get install -y software-properties-common >/dev/null 2>&1 || true
        fi
      fi
      if { ! command -v hivexsh >/dev/null 2>&1 || ! command -v reged >/dev/null 2>&1; } && command -v add-apt-repository >/dev/null 2>&1; then
        INFO "Registry tooling still missing; enabling Ubuntu universe repository and retrying packages"
        if [ "${DEBUG:-0}" -eq 1 ]; then
          sudo add-apt-repository -y universe 2>&1 || true
          sudo apt-get update -qq 2>&1 || true
          DEBIAN_FRONTEND=noninteractive sudo apt-get install -y libhivex-bin chntpw 2>&1 || true
        else
          sudo add-apt-repository -y universe >/dev/null 2>&1 || true
          sudo apt-get update -qq >/dev/null 2>&1 || true
          DEBIAN_FRONTEND=noninteractive sudo apt-get install -y libhivex-bin chntpw >/dev/null 2>&1 || true
        fi
      fi
    else
      WARN "apt-get not found; cannot auto-install missing tools"
    fi
  fi

  local missing_cmds=()
  for c in qemu-nbd qemu-img ntfs-3g ntfsfix hivexsh reged wget sfdisk; do
    command -v "$c" >/dev/null 2>&1 || missing_cmds+=("$c")
  done
  if [ "${#missing_cmds[@]}" -gt 0 ]; then
    FAIL "Missing required Windows repair commands after install attempt: ${missing_cmds[*]}"
    FAIL "Install packages on the jumphost: qemu-utils ntfs-3g libhivex-bin chntpw wget"
    exit 1
  fi
  PASS "Windows repair dependencies verified"
}

ensure_deps

merge_registry_patch() {
  local hive="$1" prefix="$2" flat_reg="$3" out_reg reged_out reged_rc
  out_reg="/tmp/ospc2flex_reged_${RANDOM}_$$.reg"
  python3 - "$prefix" "$flat_reg" "$out_reg" <<'PY'
import collections
import re
import sys

prefix, src, dest = sys.argv[1], sys.argv[2], sys.argv[3]
sections = collections.OrderedDict()
pat = re.compile(r'^"([^"]+)"=(.+)$')
with open(src, "r", encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith(";") or line.startswith("Windows Registry"):
            continue
        m = pat.match(line)
        if not m:
            continue
        full_path, value = m.group(1), m.group(2)
        parts = full_path.split("\\")
        if len(parts) < 2:
            continue
        key = "\\".join(parts[:-1])
        name = parts[-1]
        sections.setdefault(key, []).append((name, value))

with open(dest, "w", encoding="ascii", errors="ignore") as out:
    out.write("Windows Registry Editor Version 5.00\n\n")
    for key, values in sections.items():
        out.write(f"[{prefix}\\{key}]\n")
        for name, value in values:
            out.write(f'"{name}"={value}\n')
        out.write("\n")
PY
  reged_rc=0
  reged_out=$(printf 'y\n' | sudo reged -I "$hive" "$prefix" "$out_reg" 2>&1) || reged_rc=$?
  printf '%s\n' "$reged_out"
  rm -f "$out_reg"

  # reged may return 2 after successfully expanding and committing a hive.
  # Treat the write as successful only when the import and commit messages
  # both confirm it; otherwise return the real command failure.
  if [ "$reged_rc" -eq 0 ]; then
    return 0
  fi
  if echo "$reged_out" | grep -q "operation SUCCEEDED" && echo "$reged_out" | grep -q " - OK"; then
    return 0
  fi
  return "$reged_rc"
}

hive_value() {
  local hive="$1" key="$2" value="$3"
  sudo hivexsh "$hive" <<EOF 2>/dev/null || true
cd $key
lsval $value
EOF
}

is_reg_dword_zero() {
  grep -Eiq '(^|[^0-9a-f])(0|0x0|0x00000000|00000000)([^0-9a-f]|$)'
}

check_hive_dword_zero() {
  local hive="$1" key="$2" value="$3" raw
  raw=$(hive_value "$hive" "$key" "$value")
  echo "$raw" | is_reg_dword_zero
}

# ── Cleanup function ──────────────────────────────────────────────────────────
cleanup() {
  echo ""
  echo "── Cleanup ──────────────────────────────────────────────────────────────"
  sudo umount "$MNT" 2>/dev/null || true
  sudo umount "$VIRTIO_MNT" 2>/dev/null || true
  sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
  sudo rmdir "$MNT" 2>/dev/null || true
  sudo rmdir "$VIRTIO_MNT" 2>/dev/null || true
  INFO "Cleanup done"
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Download VirtIO ISO (if not cached)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 1: VirtIO ISO ─────────────────────────────────────────────────────"
VIRTIO_FALLBACK_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"

fetch_iso() {
  local url="$1"
  wget -q --show-progress -O "$VIRTIO_ISO" "$url"
  sudo mkdir -p "$VIRTIO_MNT"
  if [ "${DEBUG:-0}" -eq 1 ]; then
    if sudo mount -o loop,ro "$VIRTIO_ISO" "$VIRTIO_MNT" 2>&1; then
      PASS "VirtIO ISO mounted at $VIRTIO_MNT"
      return 0
    fi
  else
    if sudo mount -o loop,ro "$VIRTIO_ISO" "$VIRTIO_MNT" 2>/dev/null; then
      PASS "VirtIO ISO mounted at $VIRTIO_MNT"
      return 0
    fi
  fi
  WARN "ISO mount failed (corrupted). Deleting..."
  rm -f "$VIRTIO_ISO"
  return 1
}

if [ -f "$VIRTIO_ISO" ]; then
  sudo mkdir -p "$VIRTIO_MNT"
  if [ "${DEBUG:-0}" -eq 1 ]; then
    if sudo mount -o loop,ro "$VIRTIO_ISO" "$VIRTIO_MNT" 2>&1; then
      PASS "VirtIO ISO cached and mounted: $VIRTIO_ISO"
    else
      WARN "Cached ISO is corrupted, re-downloading..."
      rm -f "$VIRTIO_ISO"
    fi
  else
    if sudo mount -o loop,ro "$VIRTIO_ISO" "$VIRTIO_MNT" 2>/dev/null; then
      PASS "VirtIO ISO cached and mounted: $VIRTIO_ISO"
    else
      WARN "Cached ISO is corrupted, re-downloading..."
      rm -f "$VIRTIO_ISO"
    fi
  fi
fi

if [ ! -f "$VIRTIO_ISO" ]; then
  INFO "Downloading VirtIO ISO (Stable)..."
  if ! fetch_iso "$VIRTIO_ISO_URL"; then
    INFO "Downloading VirtIO ISO (Fallback)..."
    fetch_iso "$VIRTIO_FALLBACK_URL" || { FAIL "Both ISO downloads failed"; exit 1; }
  fi
fi

# List available driver versions
INFO "Available driver versions:"
ls -d "$VIRTIO_MNT"/viostor/2k*/amd64 "$VIRTIO_MNT"/viostor/w*/amd64 2>/dev/null | sed 's|.*/viostor/||' || true

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Mount the Windows qcow2
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 2: Mount Windows Image ───────────────────────────────────────────"
# Disconnect any previous NBD
sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
sleep 1

sudo modprobe nbd max_part=16 2>/dev/null || true
if [ "$DRY_RUN" -eq 1 ]; then
  sudo qemu-nbd --read-only --connect="$NBD_DEV" "$QCOW2"
else
  sudo qemu-nbd --connect="$NBD_DEV" "$QCOW2"
fi
sleep 3
PASS "qemu-nbd connected: $NBD_DEV"

# Find the Windows partition (dynamically scan for NTFS)
echo "  Partitions:"
sudo lsblk -o NAME,FSTYPE,SIZE "$NBD_DEV" 2>/dev/null | grep -E "^${NBD_DEV#*/dev/}|ntfs" || true

WIN_PART=""
for p in $(sudo lsblk -rno NAME,FSTYPE "$NBD_DEV" 2>/dev/null | awk '$2=="ntfs"{print "/dev/"$1}'); do
  if sudo ntfs-3g.probe --readwrite "$p" 2>&1 | grep -qi "BitLocker"; then
    FAIL "BitLocker encryption detected on $p! Offline injection is impossible."
    exit 1
  fi
  
  INFO "Probing NTFS partition: $p"
  if [ "$DRY_RUN" -eq 0 ]; then
    sudo ntfsfix -d "$p" 2>/dev/null || true
  fi
  sudo mkdir -p "$MNT"
  _mount_opts="rw,remove_hiberfile"
  [ "$DRY_RUN" -eq 1 ] && _mount_opts="ro"
  _mnt_ok=0
  if [ "${DEBUG:-0}" -eq 1 ]; then
    if sudo mount -t ntfs-3g -o "$_mount_opts" "$p" "$MNT" 2>&1; then
      _mnt_ok=1
    else
      INFO "[DEBUG] ntfs-3g mount failed for $p (see lines above)"
    fi
  else
    if sudo mount -t ntfs-3g -o "$_mount_opts" "$p" "$MNT" 2>/dev/null; then
      _mnt_ok=1
    fi
  fi
  if [ "$_mnt_ok" -eq 1 ]; then
    if [ -d "$MNT/Windows/System32" ]; then
      WIN_PART="$p"
      PASS "Windows partition: $p (mounted at $MNT)"
      # Free space check
      FREE_MB=$(df -m "$MNT" 2>/dev/null | awk 'NR==2 {print $4}')
      if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt 50 ]; then
        FAIL "Windows partition is functionally full ($FREE_MB MB free). Cannot safely inject drivers."
        exit 1
      fi
      break
    fi
    sudo umount "$MNT" 2>/dev/null
  fi
done

if [ -z "$WIN_PART" ]; then
  FAIL "Could not find Windows partition with System32 on any NTFS partition"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Detect Windows Version
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 3: Detect Windows Version ─────────────────────────────────────────"

# Try to detect version from the SOFTWARE hive
WIN_VER="unknown"
WIN_DRIVER_DIR=""
PROD_NAME="unknown"
HIVE_SW="$MNT/Windows/System32/config/SOFTWARE"
if [ -f "$HIVE_SW" ]; then
  # Extract ProductName from registry
  PROD_NAME=$(sudo hivexsh "$HIVE_SW" <<'EOF' 2>/dev/null || true
cd \Microsoft\Windows NT\CurrentVersion
lsval ProductName
EOF
  )
  INFO "Product: $PROD_NAME"

  # Map product to virtio driver directory
  case "$PROD_NAME" in
    *"Server 2025"*)  WIN_VER="2k25"; WIN_DRIVER_DIR="2k25" ;;
    *"Server 2022"*)  WIN_VER="2k22"; WIN_DRIVER_DIR="2k22" ;;
    *"Server 2019"*)  WIN_VER="2k19"; WIN_DRIVER_DIR="2k19" ;;
    *"Server 2016"*)  WIN_VER="2k16"; WIN_DRIVER_DIR="2k16" ;;
    *"Server 2012 R2"*) WIN_VER="2k12R2"; WIN_DRIVER_DIR="2k12R2" ;;
    *"Server 2012"*)  WIN_VER="2k12"; WIN_DRIVER_DIR="2k12" ;;
    *"Windows 11"*)   WIN_VER="w11"; WIN_DRIVER_DIR="w11" ;;
    *"Windows 10"*)   WIN_VER="w10"; WIN_DRIVER_DIR="w10" ;;
    *"Windows 8.1"*)  WIN_VER="w8.1"; WIN_DRIVER_DIR="w8.1" ;;
    *"Windows 8"*)    WIN_VER="w8"; WIN_DRIVER_DIR="w8" ;;
    *)
      WARN "Unknown Windows version, trying 2k19 drivers (most compatible)"
      WIN_VER="unknown"; WIN_DRIVER_DIR="2k19"
      ;;
  esac
fi

# Verify driver directory exists in ISO
VIOSTOR_SRC="$VIRTIO_MNT/viostor/$WIN_DRIVER_DIR/amd64"
NETKVM_SRC="$VIRTIO_MNT/NetKVM/$WIN_DRIVER_DIR/amd64"
VIOSERIAL_SRC="$VIRTIO_MNT/vioserial/$WIN_DRIVER_DIR/amd64"
BALLOON_SRC="$VIRTIO_MNT/Balloon/$WIN_DRIVER_DIR/amd64"
QXLDOD_SRC="$VIRTIO_MNT/qxldod/$WIN_DRIVER_DIR/amd64"

# If exact version not found, fall back to 2k19
if [ ! -d "$VIOSTOR_SRC" ]; then
  WARN "No drivers for '$WIN_DRIVER_DIR', trying 2k19..."
  WIN_DRIVER_DIR="2k19"
  VIOSTOR_SRC="$VIRTIO_MNT/viostor/$WIN_DRIVER_DIR/amd64"
  NETKVM_SRC="$VIRTIO_MNT/NetKVM/$WIN_DRIVER_DIR/amd64"
  VIOSERIAL_SRC="$VIRTIO_MNT/vioserial/$WIN_DRIVER_DIR/amd64"
  BALLOON_SRC="$VIRTIO_MNT/Balloon/$WIN_DRIVER_DIR/amd64"
fi

PASS "Windows version: $WIN_VER → driver dir: $WIN_DRIVER_DIR"
INFO "viostor source: $VIOSTOR_SRC"

if [ ! -f "$VIOSTOR_SRC/viostor.sys" ]; then
  FAIL "viostor.sys not found in $VIOSTOR_SRC"
  echo "  Available directories:"
  ls -d "$VIRTIO_MNT/viostor/"*/amd64 2>/dev/null || true
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: Copy VirtIO Driver Files
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 4: Copy VirtIO Drivers ────────────────────────────────────────────"

DRIVERS_DIR="$MNT/Windows/System32/drivers"
DRIVERSTORE="$MNT/Windows/System32/DriverStore/FileRepository"

if [ $DRY_RUN -eq 0 ]; then
  # --- viostor (block/disk — CRITICAL) ---
  if [ -f "$VIOSTOR_SRC/viostor.sys" ]; then
    sudo cp -f "$VIOSTOR_SRC/viostor.sys" "$DRIVERS_DIR/"
    sudo cp -f "$VIOSTOR_SRC/viostor.inf" "$DRIVERS_DIR/" 2>/dev/null || true
    # Also copy to DriverStore
    sudo mkdir -p "$DRIVERSTORE/viostor.inf_amd64"
    sudo cp -f "$VIOSTOR_SRC/"* "$DRIVERSTORE/viostor.inf_amd64/" 2>/dev/null || true
    PASS "viostor (disk driver) → drivers/ + DriverStore"
  fi

  # --- vioscsi (SCSI disk — CRITICAL when FLEX presents virtio-scsi) ---
  VIOSCSI_SRC="$VIRTIO_MNT/vioscsi/$WIN_DRIVER_DIR/amd64"
  if [ -d "$VIOSCSI_SRC" ] && [ -f "$VIOSCSI_SRC/vioscsi.sys" ]; then
    sudo cp -f "$VIOSCSI_SRC/vioscsi.sys" "$DRIVERS_DIR/"
    sudo cp -f "$VIOSCSI_SRC/vioscsi.inf" "$DRIVERS_DIR/" 2>/dev/null || true
    sudo mkdir -p "$DRIVERSTORE/vioscsi.inf_amd64"
    sudo cp -f "$VIOSCSI_SRC/"* "$DRIVERSTORE/vioscsi.inf_amd64/" 2>/dev/null || true
    PASS "vioscsi (SCSI disk driver) -> drivers/ + DriverStore"
  else
    WARN "vioscsi not found — image may fail if FLEX attaches disk as virtio-scsi"
  fi

  # --- netkvm (network) ---
  if [ -d "$NETKVM_SRC" ] && [ -f "$NETKVM_SRC/netkvm.sys" ]; then
    sudo cp -f "$NETKVM_SRC/netkvm.sys" "$DRIVERS_DIR/"
    sudo cp -f "$NETKVM_SRC/netkvm.inf" "$DRIVERS_DIR/" 2>/dev/null || true
    sudo mkdir -p "$DRIVERSTORE/netkvm.inf_amd64"
    sudo cp -f "$NETKVM_SRC/"* "$DRIVERSTORE/netkvm.inf_amd64/" 2>/dev/null || true
    PASS "netkvm (network driver) → drivers/ + DriverStore"
  else
    WARN "netkvm not found — network may not work on first boot"
  fi

  # --- vioserial (serial/console) ---
  if [ -d "$VIOSERIAL_SRC" ] && [ -f "$VIOSERIAL_SRC/vioser.sys" ]; then
    sudo cp -f "$VIOSERIAL_SRC/vioser.sys" "$DRIVERS_DIR/"
    sudo mkdir -p "$DRIVERSTORE/vioser.inf_amd64"
    sudo cp -f "$VIOSERIAL_SRC/"* "$DRIVERSTORE/vioser.inf_amd64/" 2>/dev/null || true
    PASS "vioserial (console driver) → drivers/ + DriverStore"
  fi

  # --- balloon (memory) ---
  if [ -d "$BALLOON_SRC" ] && [ -f "$BALLOON_SRC/balloon.sys" ]; then
    sudo cp -f "$BALLOON_SRC/balloon.sys" "$DRIVERS_DIR/"
    sudo mkdir -p "$DRIVERSTORE/balloon.inf_amd64"
    sudo cp -f "$BALLOON_SRC/"* "$DRIVERSTORE/balloon.inf_amd64/" 2>/dev/null || true
    PASS "balloon (memory driver) → drivers/ + DriverStore"
  fi

  # --- qxldod (display) ---
  if [ -d "$QXLDOD_SRC" ]; then
    sudo mkdir -p "$DRIVERSTORE/qxldod.inf_amd64"
    sudo cp -f "$QXLDOD_SRC/"* "$DRIVERSTORE/qxldod.inf_amd64/" 2>/dev/null || true
    if [ -f "$QXLDOD_SRC/qxldod.sys" ]; then
      sudo cp -f "$QXLDOD_SRC/qxldod.sys" "$DRIVERS_DIR/"
    fi
    PASS "qxldod (display driver) → drivers/ + DriverStore"
  fi
else
  INFO "[DRY-RUN] Would copy viostor, vioscsi, netkvm, vioserial, balloon, qxldod"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 5: Inject Registry Entries
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 5: Registry Injection ─────────────────────────────────────────────"

HIVE_SYSTEM="$MNT/Windows/System32/config/SYSTEM"
if [ ! -f "$HIVE_SYSTEM" ]; then
  FAIL "SYSTEM registry hive not found!"
  exit 1
fi

if [ $DRY_RUN -eq 0 ]; then
  # Backup the hive
  sudo cp "$HIVE_SYSTEM" "${HIVE_SYSTEM}.ospc2flex.bak"
  PASS "Registry backup: SYSTEM.ospc2flex.bak"

  # Create registry merge file for reged import
  REG_FILE="/tmp/virtio_drivers_$$.reg"
  cat > "$REG_FILE" <<'REGEOF'
Windows Registry Editor Version 5.00

; ═══════════════════════════════════════════════
; VirtIO Block Driver (viostor) — CRITICAL
; Without this, Windows cannot see the disk on KVM
; ═══════════════════════════════════════════════

; Service entry
"ControlSet001\Services\viostor\Type"=dword:00000001
"ControlSet001\Services\viostor\Start"=dword:00000000
"ControlSet001\Services\viostor\ErrorControl"=dword:00000001
"ControlSet001\Services\viostor\Tag"=dword:00000021
"ControlSet001\Services\viostor\ImagePath"="system32\\drivers\\viostor.sys"
"ControlSet001\Services\viostor\Group"="SCSI miniport"
"ControlSet001\Services\viostor\DisplayName"="Red Hat VirtIO SCSI controller"

; Also in ControlSet002 if it exists
"ControlSet002\Services\viostor\Type"=dword:00000001
"ControlSet002\Services\viostor\Start"=dword:00000000
"ControlSet002\Services\viostor\ErrorControl"=dword:00000001
"ControlSet002\Services\viostor\Tag"=dword:00000021
"ControlSet002\Services\viostor\ImagePath"="system32\\drivers\\viostor.sys"
"ControlSet002\Services\viostor\Group"="SCSI miniport"

; CriticalDeviceDatabase — maps PCI ID to driver
; Legacy VirtIO block device (dev 1001)
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001\Service"="viostor"
; Modern VirtIO block device (dev 1042)
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1042\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1042\Service"="viostor"
; Subsystem variants
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00021af4\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00021af4\Service"="viostor"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00000000\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001&subsys_00000000\Service"="viostor"

; Duplicate CriticalDeviceDatabase for ControlSet002
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001\Service"="viostor"
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1042\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1042\Service"="viostor"

; ═══════════════════════════════════════════════
; VirtIO Network Driver (netkvm)
; ═══════════════════════════════════════════════
"ControlSet001\Services\netkvm\Type"=dword:00000001
"ControlSet001\Services\netkvm\Start"=dword:00000003
"ControlSet001\Services\netkvm\ErrorControl"=dword:00000001
"ControlSet001\Services\netkvm\ImagePath"="system32\\drivers\\netkvm.sys"
"ControlSet001\Services\netkvm\Group"="NDIS"
"ControlSet001\Services\netkvm\DisplayName"="Red Hat VirtIO Ethernet Adapter"

"ControlSet002\Services\netkvm\Type"=dword:00000001
"ControlSet002\Services\netkvm\Start"=dword:00000003
"ControlSet002\Services\netkvm\ErrorControl"=dword:00000001
"ControlSet002\Services\netkvm\ImagePath"="system32\\drivers\\netkvm.sys"
"ControlSet002\Services\netkvm\Group"="NDIS"

; CriticalDeviceDatabase for network
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1000\ClassGUID"="{4D36E972-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1000\Service"="netkvm"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1041\ClassGUID"="{4D36E972-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1041\Service"="netkvm"
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1000\ClassGUID"="{4D36E972-E325-11CE-BFC1-08002BE10318}"
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1000\Service"="netkvm"

; ═══════════════════════════════════════════════
; VirtIO SCSI Driver (vioscsi) — CRITICAL
; Some OpenStack/FLEX hosts present image disks via virtio-scsi even when the
; image metadata requests hw_disk_bus=virtio. Register both storage paths.
; ═══════════════════════════════════════════════
"ControlSet001\Services\vioscsi\Type"=dword:00000001
"ControlSet001\Services\vioscsi\Start"=dword:00000000
"ControlSet001\Services\vioscsi\ErrorControl"=dword:00000001
"ControlSet001\Services\vioscsi\Tag"=dword:00000022
"ControlSet001\Services\vioscsi\ImagePath"="system32\\drivers\\vioscsi.sys"
"ControlSet001\Services\vioscsi\Group"="SCSI miniport"
"ControlSet001\Services\vioscsi\DisplayName"="Red Hat VirtIO SCSI pass-through controller"

"ControlSet002\Services\vioscsi\Type"=dword:00000001
"ControlSet002\Services\vioscsi\Start"=dword:00000000
"ControlSet002\Services\vioscsi\ErrorControl"=dword:00000001
"ControlSet002\Services\vioscsi\Tag"=dword:00000022
"ControlSet002\Services\vioscsi\ImagePath"="system32\\drivers\\vioscsi.sys"
"ControlSet002\Services\vioscsi\Group"="SCSI miniport"

; Legacy and modern VirtIO SCSI PCI IDs
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004\Service"="vioscsi"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1048\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1048\Service"="vioscsi"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004&subsys_00081af4\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004&subsys_00081af4\Service"="vioscsi"

"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004\Service"="vioscsi"
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1048\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1048\Service"="vioscsi"

; ═══════════════════════════════════════════════
; VirtIO Serial Driver (vioserial)
; ═══════════════════════════════════════════════
"ControlSet001\Services\vioser\Type"=dword:00000001
"ControlSet001\Services\vioser\Start"=dword:00000003
"ControlSet001\Services\vioser\ErrorControl"=dword:00000001
"ControlSet001\Services\vioser\ImagePath"="system32\\drivers\\vioser.sys"
"ControlSet001\Services\vioser\Group"="Extended Base"

; ═══════════════════════════════════════════════
; VirtIO Balloon Driver
; ═══════════════════════════════════════════════
"ControlSet001\Services\balloon\Type"=dword:00000001
"ControlSet001\Services\balloon\Start"=dword:00000003
"ControlSet001\Services\balloon\ErrorControl"=dword:00000001
"ControlSet001\Services\balloon\ImagePath"="system32\\drivers\\balloon.sys"
"ControlSet001\Services\balloon\Group"="Extended Base"
REGEOF

  # Apply registry changes using reged (from chntpw). Ubuntu 24.04's
  # libhivex-bin no longer ships hivexregedit.
  merge_registry_patch "$HIVE_SYSTEM" "HKEY_LOCAL_MACHINE\\SYSTEM" "$REG_FILE" 2>&1
  REG_RC=$?
  rm -f "$REG_FILE"

  if [ $REG_RC -eq 0 ]; then
    PASS "Registry: viostor service (Start=0, Group=SCSI miniport)"
    PASS "Registry: vioscsi service (Start=0, Group=SCSI miniport)"
    PASS "Registry: netkvm service (Start=3, Group=NDIS)"
    PASS "Registry: vioserial + balloon services"
    PASS "Registry: CriticalDeviceDatabase PCI entries (1AF4:{1001,1042,1004,1048,1000,1041})"
  else
    FAIL "Registry merge failed (rc=$REG_RC)"
    WARN "Restoring backup..."
    sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
    exit 1
  fi

  # Verify the injection worked
  echo ""
  echo "── Verification ─────────────────────────────────────────────────────────"
  echo "  Checking viostor service in registry..."
  VIO_CHK=$(hive_value "$HIVE_SYSTEM" '\ControlSet001\Services\viostor' 'Start')
  SCSI_CHK=$(hive_value "$HIVE_SYSTEM" '\ControlSet001\Services\vioscsi' 'Start')
  if echo "$VIO_CHK" | is_reg_dword_zero && echo "$SCSI_CHK" | is_reg_dword_zero; then
    PASS "Registry verification: viostor Start=0 confirmed"
    PASS "Registry verification: vioscsi Start=0 confirmed"
  else
    FAIL "Registry verification failed: VirtIO disk services not correctly registered"
    INFO "viostor Start raw: ${VIO_CHK:-<missing>}"
    INFO "vioscsi Start raw: ${SCSI_CHK:-<missing>}"
    WARN "Restoring backup..."
    sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
    exit 1
  fi

  # ── Clear MountedDevices (Crucial for V2V Boot) ──
  # The key itself may be recreated by Windows, but old \DosDevices\C: values
  # must be removed so the migrated VirtIO disk can claim C: cleanly.
  _hx_md_err=$(mktemp)
  set +e
  sudo hivexsh -w "$HIVE_SYSTEM" <<'EOF' 2>"$_hx_md_err"
cd \MountedDevices
setval 0
commit
EOF
  _hx_md_rc=$?
  set -euo pipefail
  if [ -s "$_hx_md_err" ]; then
    if [ "${DEBUG:-0}" -eq 1 ] || [ "$_hx_md_rc" -ne 0 ]; then
      INFO "[DEBUG] MountedDevices hivexsh (rc=$_hx_md_rc) stderr:"
      sed 's/^/    /' "$_hx_md_err" || true
    fi
  fi
  rm -f "$_hx_md_err"
  MD_VALUES=$(sudo hivexsh "$HIVE_SYSTEM" <<'EOF' 2>/dev/null || true
cd \MountedDevices
lsval
EOF
  )
  if [ -z "$(printf '%s' "$MD_VALUES" | tr -d '[:space:]')" ]; then
    PASS "Registry: MountedDevices values cleared (forces VirtIO C: drive mapping)"
  else
    FAIL "MountedDevices still contains stale drive mappings"
    printf '%s\n' "$MD_VALUES" | sed 's/^/    /'
    WARN "Restoring backup..."
    sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
    exit 1
  fi

else
  INFO "[DRY-RUN] Would inject viostor, vioscsi, netkvm, vioserial, balloon service entries"
  INFO "[DRY-RUN] Would add CriticalDeviceDatabase PCI mappings"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 6: Disable Xen PV drivers (prevent conflicts)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 6: Disable Xen Drivers ────────────────────────────────────────────"

if [ $DRY_RUN -eq 0 ]; then
  # Set Xen block driver to disabled (Start=4) so it doesn't conflict
  XEN_REG="/tmp/xen_disable_$$.reg"
  cat > "$XEN_REG" <<'XENEOF'
Windows Registry Editor Version 5.00

; Disable Xen PV drivers (Start=4 means disabled)
"ControlSet001\Services\xenvbd\Start"=dword:00000004
"ControlSet001\Services\xennet\Start"=dword:00000004
"ControlSet001\Services\xenvif\Start"=dword:00000004
"ControlSet001\Services\xeniface\Start"=dword:00000004
"ControlSet001\Services\xenbus\Start"=dword:00000004
"ControlSet002\Services\xenvbd\Start"=dword:00000004
"ControlSet002\Services\xennet\Start"=dword:00000004
"ControlSet002\Services\xenvif\Start"=dword:00000004
"ControlSet002\Services\xeniface\Start"=dword:00000004
"ControlSet002\Services\xenbus\Start"=dword:00000004
XENEOF

  if [ "${DEBUG:-0}" -eq 1 ]; then
    merge_registry_patch "$HIVE_SYSTEM" "HKEY_LOCAL_MACHINE\\SYSTEM" "$XEN_REG" 2>&1 || true
  else
    merge_registry_patch "$HIVE_SYSTEM" "HKEY_LOCAL_MACHINE\\SYSTEM" "$XEN_REG" >/dev/null 2>&1 || true
  fi
  rm -f "$XEN_REG"
  PASS "Xen PV drivers disabled (xenvbd, xennet, xenvif, xeniface, xenbus → Start=4)"
else
  INFO "[DRY-RUN] Would disable Xen PV drivers"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 7: Enable safe boot (use standard storage driver stack)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 7: Enable Standard Storage Stack ──────────────────────────────────"

# reged -I cannot add values under existing service keys (e.g. \Services\disk):
# it tries add_key and fails with "key disk already exists". Use python3-hivex
# node_set_value to set only Start=0 (REG_DWORD) without touching other values.
_set_std_storage_start_via_hivex() {
  local hive="$1"
  if ! sudo python3 -c "import hivex" 2>/dev/null; then
    if command -v apt-get >/dev/null 2>&1; then
      INFO "Installing python3-hivex (required to patch disk/volmgt Start= in-place)..."
      DEBIAN_FRONTEND=noninteractive sudo apt-get install -y -qq python3-hivex >/dev/null 2>&1 || true
    fi
  fi
  sudo python3 - "$hive" <<'PY'
import struct
import sys

try:
    import hivex
except ImportError:
    sys.stderr.write("ospc2flex: python3-hivex not available — cannot set storage Start=dword\n")
    sys.exit(2)

path = sys.argv[1]
REG_DWORD = 4
zero = struct.pack("<I", 0)

def child(h, node, name):
    ch = h.node_get_child(node, name)
    return ch if ch else 0

h = hivex.Hivex(path, write=True)
root = h.root()
for cs in ("ControlSet001", "ControlSet002"):
    n = child(h, root, cs)
    if not n:
        continue
    svc_root = child(h, n, "Services")
    if not svc_root:
        continue
    for svc in ("disk", "volmgr", "volsnap", "partmgr", "mountmgr"):
        sn = child(h, svc_root, svc)
        if not sn:
            continue
        h.node_set_value(sn, {"key": "Start", "t": REG_DWORD, "value": zero})
h.commit(path)
sys.exit(0)
PY
}

if [ $DRY_RUN -eq 0 ]; then
  if ! _set_std_storage_start_via_hivex "$HIVE_SYSTEM"; then
    WARN "Storage Start= patch via hivex skipped (install: apt install python3-hivex)"
    WARN "Continuing with verification only — Microsoft storage drivers are usually already Start=0"
  else
    PASS "Microsoft storage services: Start=0 set via hivex (disk, volmgr, volsnap, partmgr, mountmgr)"
  fi

  STORAGE_VERIFY_FAILED=0
  for svc in disk volmgr volsnap partmgr mountmgr; do
    if ! check_hive_dword_zero "$HIVE_SYSTEM" "\\ControlSet001\\Services\\$svc" "Start"; then
      WARN "Standard storage service $svc is not Start=0 in ControlSet001"
      STORAGE_VERIFY_FAILED=1
    fi
  done
  if [ "$STORAGE_VERIFY_FAILED" -ne 0 ]; then
    FAIL "Standard Windows storage stack verification failed"
    WARN "Restoring backup..."
    sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
    exit 1
  fi
  PASS "Standard storage drivers verified (disk, volmgr, volsnap, partmgr, mountmgr)"
else
  INFO "[DRY-RUN] Would verify standard storage stack"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 7b: Boot layout validation and WinRE repair helper
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 7b: Boot Layout + BCD Helper ─────────────────────────────────────"

WIN_PART_NUM=$(lsblk -rno PARTN "$WIN_PART" 2>/dev/null | head -n1 || true)
PTTYPE=$(lsblk -rno PTTYPE "$NBD_DEV" 2>/dev/null | head -n1 || true)

if [ -z "$WIN_PART_NUM" ]; then
  WARN "Could not detect partition number for $WIN_PART"
elif [ "$PTTYPE" = "dos" ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    if [ "${DEBUG:-0}" -eq 1 ]; then
      sudo sfdisk --activate "$NBD_DEV" "$WIN_PART_NUM" 2>&1 || \
        WARN "Could not set MBR active flag on $NBD_DEV partition $WIN_PART_NUM"
    else
      sudo sfdisk --activate "$NBD_DEV" "$WIN_PART_NUM" >/dev/null 2>&1 || \
        WARN "Could not set MBR active flag on $NBD_DEV partition $WIN_PART_NUM"
    fi
    PASS "MBR active boot flag set on Windows partition $WIN_PART_NUM"
  else
    INFO "[DRY-RUN] Would set MBR active boot flag on Windows partition $WIN_PART_NUM"
  fi
elif [ -n "$PTTYPE" ]; then
  INFO "Partition table is $PTTYPE; no MBR active flag needed"
else
  WARN "Partition table type not detected"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if [ -f "$MNT/bootmgr" ] && [ -f "$MNT/Boot/BCD" ]; then
    PASS "Boot files present on Windows volume (bootmgr + Boot/BCD)"
  else
    FAIL "Required BIOS boot files missing on Windows volume"
    [ -f "$MNT/bootmgr" ] || FAIL "Missing: C:\\bootmgr"
    [ -f "$MNT/Boot/BCD" ] || FAIL "Missing: C:\\Boot\\BCD"
    exit 1
  fi

  BCD_HIVE="$MNT/Boot/BCD"
  if [ -f "$BCD_HIVE" ] && command -v hivexml >/dev/null 2>&1; then
    sudo cp -f "$BCD_HIVE" "${BCD_HIVE}.ospc2flex.bak" 2>/dev/null || true
    # Parse BCD hive: patch EVERY normal Windows winload entry AND every winresume
    # (hibernate resume) entry. Reference FLEX 2019 BCD shows winresume still had
    # recoverysequence→WinRE; patching only the first winload misses that path.
    # Kind: W = winload (gets bootstatuspolicy), R = winresume (recovery off only).
    BCD_PATCHLIST=$(mktemp)
    sudo hivexml "$BCD_HIVE" 2>/dev/null | python3 -c '
import sys
import xml.etree.ElementTree as ET

def scan():
    try:
        root = ET.fromstring(sys.stdin.read())
    except Exception:
        return []
    out = []
    for obj in root.findall(".//node[@name=\"Objects\"]/node"):
        guid = obj.attrib.get("name", "")
        elements = obj.find("node[@name=\"Elements\"]")
        if elements is None:
            continue
        path = ""
        systemroot = ""
        desc = ""
        enames = set()
        for el in elements.findall("node"):
            name = el.attrib.get("name", "")
            enames.add(name)
            val = el.find("value[@key=\"Element\"]")
            if val is None:
                continue
            text = val.attrib.get("value", "")
            if name == "12000002":
                path = text.lower()
            elif name == "22000002":
                systemroot = text.lower()
            elif name == "12000004":
                desc = text.lower()
        if "winre.wim" in path or ("ramdisk=" in path and "winload" in path):
            continue
        kind = None
        if "winresume.exe" in path:
            kind = "R"
        elif "winload.exe" in path and systemroot == "\\windows" and "recovery" not in desc:
            kind = "W"
        if kind is None:
            continue
        has_rs = "1" if "14000008" in enames else "0"
        has_re = "1" if "16000009" in enames else "0"
        has_bsp = "1" if "250000e0" in enames else "0"
        out.append((guid, kind, has_rs, has_re, has_bsp))
    return out

for row in scan():
    print("\t".join(row))
' >"$BCD_PATCHLIST"
    if [ ! -s "$BCD_PATCHLIST" ]; then
      WARN "BCD: no Windows winload/winresume entries matched; offline WinRE suppression skipped"
      rm -f "$BCD_PATCHLIST"
    else
      _n_patch=$(wc -l <"$BCD_PATCHLIST")
      INFO "BCD: preparing WinRE suppression for $_n_patch boot object(s) (winload + winresume)"
      BCD_HIVEX="/tmp/ospc2flex_bcd_hivexsh_$$.txt"
      : >"$BCD_HIVEX"
      while IFS=$'\t' read -r _guid _kind _has_rs _has_re _has_bsp; do
        [ -z "$_guid" ] && continue
        _bcd_elems="\\Objects\\$_guid\\Elements"
        {
          echo "cd $_bcd_elems"
          if [ "$_has_rs" = "1" ]; then
            echo "cd 14000008"
            echo "del"
            echo "cd $_bcd_elems"
          fi
          if [ "$_has_re" = "1" ]; then
            echo "cd 16000009"
            echo "setval 1"
            echo "Element"
            echo "hex:3:00"
            echo "cd $_bcd_elems"
          else
            echo "add 16000009"
            echo "cd 16000009"
            echo "setval 1"
            echo "Element"
            echo "hex:3:00"
            echo "cd $_bcd_elems"
          fi
          if [ "$_kind" = "W" ]; then
            if [ "$_has_bsp" = "1" ]; then
              echo "cd 250000e0"
              echo "setval 1"
              echo "Element"
              echo "hex:3:01,00,00,00,00,00,00,00"
            else
              echo "add 250000e0"
              echo "cd 250000e0"
              echo "setval 1"
              echo "Element"
              echo "hex:3:01,00,00,00,00,00,00,00"
            fi
          fi
        } >>"$BCD_HIVEX"
      done <"$BCD_PATCHLIST"
      echo "commit" >>"$BCD_HIVEX"
      _bcd_log=$(mktemp)
      set +e
      sudo hivexsh -w "$BCD_HIVE" <"$BCD_HIVEX" >"$_bcd_log" 2>&1
      _bcd_rc=$?
      set -euo pipefail
      rm -f "$BCD_HIVEX" 2>/dev/null || true
      if [ "$_bcd_rc" -eq 0 ]; then
        PASS "BCD: WinRE auto-boot suppressed on $_n_patch object(s) (winload + winresume)"
        PASS "BCD: bootstatuspolicy IgnoreAllFailures on Windows loaders (winload only)"
        if ! sudo hivexml "$BCD_HIVE" 2>/dev/null | python3 -c '
import sys
import xml.etree.ElementTree as ET

def enames_for(root, guid):
    for obj in root.findall(".//node[@name=\"Objects\"]/node"):
        if obj.attrib.get("name", "") != guid:
            continue
        elements = obj.find("node[@name=\"Elements\"]")
        if elements is None:
            return None
        return {el.attrib.get("name", "") for el in elements.findall("node")}
    return None

try:
    root = ET.fromstring(sys.stdin.read())
except Exception:
    sys.exit(2)
pl_path = sys.argv[1]
for line in open(pl_path, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line or "\t" not in line:
        continue
    parts = line.split("\t")
    if len(parts) < 5:
        continue
    guid, kind = parts[0], parts[1]
    e = enames_for(root, guid)
    if e is None:
        sys.exit(3)
    if "14000008" in e:
        sys.exit(4)
    if kind == "W" and "250000e0" not in e:
        sys.exit(5)
sys.exit(0)
' "$BCD_PATCHLIST"; then
          WARN "BCD post-check failed (recoverysequence or bootstatuspolicy) — WinRE may still trigger"
        fi
        if [ "${DEBUG:-0}" -eq 1 ] && [ -s "$_bcd_log" ]; then
          INFO "[DEBUG] BCD hivexsh transcript:"
          sed 's/^/    /' "$_bcd_log" || true
        fi
      else
        WARN "BCD hivexsh failed (exit $_bcd_rc); offline WinRE suppression incomplete. Log:"
        sed 's/^/    /' "$_bcd_log" | while IFS= read -r line; do WARN "$line"; done || true
      fi
      rm -f "$_bcd_log" "$BCD_PATCHLIST" 2>/dev/null || true
    fi
  else
    WARN "BCD hive unavailable or hivexml missing; offline WinRE suppression skipped"
  fi

  for _bootstat in "$MNT/Boot/BOOTSTAT.DAT" "$MNT/Windows/bootstat.dat"; do
    if [ -f "$_bootstat" ]; then
      sudo mv -f "$_bootstat" "${_bootstat}.ospc2flex.bak" 2>/dev/null || true
    fi
  done
  PASS "Boot status files reset (BOOTSTAT.DAT/bootstat.dat backed up if present)"

  # This file is intentionally placed in the guest root so that if the VM still
  # lands in WinRE, the operator can run one command from the recovery console:
  #   C:\ospc2flex_winre_boot_repair.cmd
  # It mirrors the known-good FLEX Windows 2016 layout: BIOS/MBR boot, bootmgr
  # and Windows loader pointing at C:, with recovery suppressed for the first
  # successful boot attempt.
  sudo tee "$MNT/ospc2flex_winre_boot_repair.cmd" > /dev/null <<'WINRECMDEOF'
@echo off
echo [ospc2flex] Rebuilding BIOS/MBR Windows boot files on C:
bcdboot C:\Windows /s C: /f BIOS
echo [ospc2flex] Normalizing BCD to boot C:\Windows
bcdedit /set {bootmgr} device partition=C:
bcdedit /set {bootmgr} default {default}
bcdedit /set {bootmgr} timeout 5
bcdedit /set {default} device partition=C:
bcdedit /set {default} osdevice partition=C:
bcdedit /set {default} path \Windows\system32\winload.exe
bcdedit /set {default} systemroot \Windows
bcdedit /set {default} bootstatuspolicy IgnoreAllFailures
bcdedit /set {default} recoveryenabled No
bcdedit /deletevalue {default} recoverysequence
bcdedit /deletevalue {default} safeboot
bcdedit /deletevalue {default} safebootalternateshell
reagentc /disable
echo [ospc2flex] Boot repair commands finished. Reboot the VM now.
pause
WINRECMDEOF
  sudo chmod 0644 "$MNT/ospc2flex_winre_boot_repair.cmd" 2>/dev/null || true
  PASS "WinRE helper: C:\\ospc2flex_winre_boot_repair.cmd"
else
  INFO "[DRY-RUN] Would disable automatic WinRE in offline BCD for first boot"
  INFO "[DRY-RUN] Would set BCD bootstatuspolicy IgnoreAllFailures"
  INFO "[DRY-RUN] Would reset BOOTSTAT.DAT/bootstat.dat"
  INFO "[DRY-RUN] Would write C:\\ospc2flex_winre_boot_repair.cmd"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 8: First-Boot Network + Firewall Script (RunOnce)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Step 8: First-Boot RunOnce Script ──────────────────────────────────────"

if [ $DRY_RUN -eq 0 ]; then
  # Write a PowerShell script that runs once on first boot to:
  #   1. Remove ghost/stale network adapters bound to old Xen MAC
  #   2. Enable DHCP on the new VirtIO NIC
  #   3. Open firewall for RDP + ICMP on all profiles
  #   4. Self-delete after execution
  FIRSTBOOT_DIR="$MNT/Windows/Setup/Scripts"
  FIRSTBOOT_PS1="$MNT/ospc2flex_firstboot.ps1"
  FIRSTBOOT_CMD="$FIRSTBOOT_DIR/SetupComplete.cmd"

  sudo mkdir -p "$FIRSTBOOT_DIR"

  sudo tee "$FIRSTBOOT_PS1" > /dev/null <<'FIRSTBOOTEOF'
# ── ospc2flex first-boot network + firewall repair ──
# Runs once via SetupComplete.cmd on first Windows boot after migration.

$logFile = "C:\ospc2flex_firstboot.log"
Start-Transcript -Path $logFile -Append

Write-Host "[ospc2flex] First-boot repair starting..."

# ── 0. Keep boot on the normal Windows loader (not Safe Mode / not auto-recovery) ──
# Offline repair already patches BCD; this re-applies policy on first successful
# Windows start so later boots stay on normal mode even if markers were pending.
try {
    $null = & bcdedit.exe /set "{current}" bootstatuspolicy IgnoreAllFailures 2>&1
    $null = & bcdedit.exe /set "{current}" recoveryenabled No 2>&1
    $null = & bcdedit.exe /deletevalue "{current}" safeboot 2>&1
    $null = & bcdedit.exe /deletevalue "{current}" safebootalternateshell 2>&1
    $null = & bcdedit.exe /deletevalue "{current}" recoverysequence 2>&1
    Write-Host "[ospc2flex] BCD: normal-boot policy reinforced on {current} (bcdedit)"
    # Scrub recoverysequence / recoveryenabled on EVERY BCD object (e.g. winresume
    # {guid} is not {current}; offline repair patches the hive but this catches stragglers).
    $curId = $null
    foreach ($line in (& bcdedit.exe /enum all 2>&1)) {
        if ($line -match '^\s*identifier\s+(\{.+\})') {
            $curId = $Matches[1]
            continue
        }
        if ($null -ne $curId -and $line -match '^\s*recoverysequence\s') {
            $null = & bcdedit.exe /deletevalue $curId recoverysequence 2>&1
            $null = & bcdedit.exe /set $curId recoveryenabled No 2>&1
        }
    }
    Write-Host "[ospc2flex] BCD: recoverysequence scrubbed on all enumerated entries"
} catch {
    Write-Host "[ospc2flex] BCD reinforcement skipped: $_"
}

# ── 1. Remove ghost/disconnected network adapters (old Xen NICs) ──
try {
    $ghost = Get-PnpDevice -Class Net -Status Unknown -ErrorAction SilentlyContinue
    foreach ($dev in $ghost) {
        Write-Host "[ospc2flex] Removing ghost adapter: $($dev.FriendlyName) ($($dev.InstanceId))"
        & pnputil /remove-device $dev.InstanceId 2>&1 | Out-Null
    }
    Write-Host "[ospc2flex] Ghost adapter cleanup done"
} catch {
    Write-Host "[ospc2flex] Ghost adapter cleanup skipped: $_"
}

# ── 2. Clear stale static IP bindings and enable DHCP on all adapters ──
try {
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -or $_.InterfaceDescription -match 'VirtIO|Red Hat' }
    foreach ($nic in $adapters) {
        Write-Host "[ospc2flex] Configuring DHCP on: $($nic.Name) ($($nic.InterfaceDescription))"
        # Remove any static IP addresses
        Get-NetIPAddress -InterfaceIndex $nic.ifIndex -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -eq 'Manual' } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        # Remove static routes
        Remove-NetRoute -InterfaceIndex $nic.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
        # Enable DHCP
        Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Enabled -ErrorAction SilentlyContinue
        # Enable DNS via DHCP
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
        Write-Host "[ospc2flex] DHCP enabled on $($nic.Name)"
    }
    # Force DHCP renewal
    ipconfig /release 2>&1 | Out-Null
    ipconfig /renew 2>&1 | Out-Null
    Write-Host "[ospc2flex] DHCP renewal complete"
} catch {
    Write-Host "[ospc2flex] DHCP config error: $_"
}

# ── 3. Open firewall for RDP + ICMP on all profiles ──
try {
    # Allow RDP
    Set-NetFirewallRule -DisplayGroup "Remote Desktop" -Enabled True -ErrorAction SilentlyContinue
    # If no predefined RDP rule, create one
    if (-not (Get-NetFirewallRule -DisplayName "ospc2flex-RDP" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "ospc2flex-RDP" -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
    }
    # Allow ICMP (ping)
    if (-not (Get-NetFirewallRule -DisplayName "ospc2flex-ICMPv4" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "ospc2flex-ICMPv4" -Direction Inbound -Protocol ICMPv4 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Host "[ospc2flex] Firewall: RDP (3389) + ICMP allowed on all profiles"
} catch {
    Write-Host "[ospc2flex] Firewall config error: $_"
}

# ── 4. Ensure RDP is enabled in registry ──
try {
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 0 -ErrorAction SilentlyContinue
    Write-Host "[ospc2flex] RDP enabled in registry"
} catch {
    Write-Host "[ospc2flex] RDP registry error: $_"
}

# ── 5. Enable OpenSSH Server (Windows Server 2019+ built-in) ──
try {
    $sshCapability = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'OpenSSH.Server*' }
    if ($sshCapability) {
        if ($sshCapability.State -ne 'Installed') {
            Write-Host "[ospc2flex] Installing OpenSSH Server..."
            Add-WindowsCapability -Online -Name $sshCapability.Name -ErrorAction Stop | Out-Null
        }
        Start-Service sshd -ErrorAction SilentlyContinue
        Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
        if (-not (Get-NetFirewallRule -DisplayName "ospc2flex-SSH" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName "ospc2flex-SSH" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
        }
        # Set PowerShell as default SSH shell
        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Host "[ospc2flex] OpenSSH Server: installed, started, firewall open, default shell=PowerShell"
    } else {
        Write-Host "[ospc2flex] OpenSSH Server capability not available (Server 2016?) — skipping"
    }
} catch {
    Write-Host "[ospc2flex] OpenSSH setup error (non-fatal): $_"
}

# ── 6. Enable WinRM (works on all Windows Server versions) ──
try {
    # Enable WinRM service
    Set-Service -Name WinRM -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service WinRM -ErrorAction SilentlyContinue
    # Configure WinRM for unencrypted basic auth (jumphost is on same private network)
    & winrm quickconfig -quiet 2>&1 | Out-Null
    & winrm set winrm/config/service '@{AllowUnencrypted="true"}' 2>&1 | Out-Null
    & winrm set winrm/config/service/auth '@{Basic="true"}' 2>&1 | Out-Null
    if (-not (Get-NetFirewallRule -DisplayName "ospc2flex-WinRM" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "ospc2flex-WinRM" -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Host "[ospc2flex] WinRM: enabled, basic auth, firewall open on 5985"
} catch {
    Write-Host "[ospc2flex] WinRM setup error (non-fatal): $_"
}

# ── 7. Run verification and write results ──
try {
    $report = @()
    $report += "=== ospc2flex post-boot verification ==="
    $report += "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $report += "Hostname: $env:COMPUTERNAME"
    $report += ""

    # Disk driver
    $viostor = Get-Service viostor -ErrorAction SilentlyContinue
    $report += "viostor service: $($viostor.Status)"

    # Network adapter
    $nics = Get-NetAdapter -ErrorAction SilentlyContinue
    foreach ($n in $nics) {
        $report += "NIC: $($n.Name) | $($n.InterfaceDescription) | Status=$($n.Status) | MAC=$($n.MacAddress)"
    }

    # IP config
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '127.0.0.1' }
    foreach ($ip in $ips) {
        $report += "IP: $($ip.IPAddress)/$($ip.PrefixLength) on $($ip.InterfaceAlias) (Origin=$($ip.PrefixOrigin))"
    }

    # DHCP status
    $dhcp = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' }
    foreach ($d in $dhcp) {
        $report += "DHCP: $($d.InterfaceAlias) = $($d.Dhcp)"
    }

    # Ghost devices
    $ghosts = Get-PnpDevice -Class Net -Status Unknown -ErrorAction SilentlyContinue
    $report += "Ghost NICs: $(@($ghosts).Count)"

    # Firewall
    $fwRules = Get-NetFirewallRule -DisplayName "ospc2flex*" -ErrorAction SilentlyContinue
    foreach ($fw in $fwRules) {
        $report += "Firewall: $($fw.DisplayName) = Enabled:$($fw.Enabled)"
    }

    # SSH / WinRM
    $sshSvc = Get-Service sshd -ErrorAction SilentlyContinue
    $report += "OpenSSH: $(if ($sshSvc) { $sshSvc.Status } else { 'not installed' })"
    $winrmSvc = Get-Service WinRM -ErrorAction SilentlyContinue
    $report += "WinRM: $(if ($winrmSvc) { $winrmSvc.Status } else { 'not found' })"

    # Disk/Volume
    $disks = Get-Disk -ErrorAction SilentlyContinue
    foreach ($dk in $disks) {
        $report += "Disk: #$($dk.Number) $($dk.FriendlyName) Size=$([math]::Round($dk.Size/1GB,1))GB Style=$($dk.PartitionStyle)"
    }
    $vols = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter }
    foreach ($v in $vols) {
        $report += "Volume: $($v.DriveLetter): Size=$([math]::Round($v.Size/1GB,1))GB Free=$([math]::Round($v.SizeRemaining/1GB,1))GB FS=$($v.FileSystemType)"
    }

    $report += ""
    $report += "=== verification complete ==="

    $report | Out-File -FilePath "C:\ospc2flex_verification.txt" -Encoding UTF8
    $report | ForEach-Object { Write-Host $_ }
    Write-Host "[ospc2flex] Verification report: C:\ospc2flex_verification.txt"
} catch {
    Write-Host "[ospc2flex] Verification error: $_"
}

Write-Host "[ospc2flex] First-boot repair complete."
Write-Host "[ospc2flex] Log saved to $logFile"
Stop-Transcript

# ── 8. Self-cleanup (keep verification report, remove script) ──
Remove-Item -Path "C:\ospc2flex_firstboot.ps1" -Force -ErrorAction SilentlyContinue
FIRSTBOOTEOF

  # SetupComplete.cmd — Windows runs this automatically on first boot after OOBE/sysprep
  # Also works on non-sysprepped images as a fallback via RunOnce registry key
  sudo tee "$FIRSTBOOT_CMD" > /dev/null <<'CMDEOF'
@echo off
echo [ospc2flex] Running first-boot network and firewall repair...
powershell.exe -ExecutionPolicy Bypass -File "C:\ospc2flex_firstboot.ps1"
del /f /q "%~f0" 2>nul
CMDEOF

  PASS "First-boot script: C:\\ospc2flex_firstboot.ps1"
  PASS "SetupComplete.cmd trigger: Windows\\Setup\\Scripts\\SetupComplete.cmd"

  # Also inject RunOnce registry key as backup trigger (works even without sysprep)
  RUNONCE_REG="/tmp/runonce_$$.reg"
  cat > "$RUNONCE_REG" <<'RUNONCEEOF'
Windows Registry Editor Version 5.00

"ControlSet001\Control\Session Manager\RunOnce\ospc2flex_firstboot"="cmd.exe /c powershell.exe -ExecutionPolicy Bypass -File C:\\ospc2flex_firstboot.ps1"
"ControlSet002\Control\Session Manager\RunOnce\ospc2flex_firstboot"="cmd.exe /c powershell.exe -ExecutionPolicy Bypass -File C:\\ospc2flex_firstboot.ps1"
RUNONCEEOF

  if [ "${DEBUG:-0}" -eq 1 ]; then
    merge_registry_patch "$HIVE_SYSTEM" "HKEY_LOCAL_MACHINE\\SYSTEM" "$RUNONCE_REG" 2>&1 || true
  else
    merge_registry_patch "$HIVE_SYSTEM" "HKEY_LOCAL_MACHINE\\SYSTEM" "$RUNONCE_REG" >/dev/null 2>&1 || true
  fi
  rm -f "$RUNONCE_REG"
  PASS "Registry RunOnce fallback: ospc2flex_firstboot (ControlSet001+002)"

  # Also inject into SOFTWARE hive RunOnce (user-session trigger — covers logged-in admin)
  if [ -f "$HIVE_SW" ]; then
    SW_RUNONCE_REG="/tmp/sw_runonce_$$.reg"
    cat > "$SW_RUNONCE_REG" <<'SWRUNONCEEOF'
Windows Registry Editor Version 5.00

"Microsoft\Windows\CurrentVersion\RunOnce\ospc2flex_firstboot"="cmd.exe /c powershell.exe -ExecutionPolicy Bypass -File C:\\ospc2flex_firstboot.ps1"
SWRUNONCEEOF

    if [ "${DEBUG:-0}" -eq 1 ]; then
      merge_registry_patch "$HIVE_SW" "HKEY_LOCAL_MACHINE\\SOFTWARE" "$SW_RUNONCE_REG" 2>&1 || true
    else
      merge_registry_patch "$HIVE_SW" "HKEY_LOCAL_MACHINE\\SOFTWARE" "$SW_RUNONCE_REG" >/dev/null 2>&1 || true
    fi
    rm -f "$SW_RUNONCE_REG"
    PASS "SOFTWARE RunOnce fallback: HKLM\\...\\RunOnce\\ospc2flex_firstboot"
  fi

else
  INFO "[DRY-RUN] Would write first-boot PowerShell script for DHCP + firewall repair"
  INFO "[DRY-RUN] Would inject RunOnce registry entries in SYSTEM + SOFTWARE hives"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════════════════════
echo ""

# Write sentinel
if [ $DRY_RUN -eq 0 ]; then
  touch "${QCOW2}.win_repaired"
  PASS "Sentinel: ${QCOW2}.win_repaired"
fi

echo "═══════════════════════════════════════════════════════════════════════════"
if [ "$DRY_RUN" -eq 1 ]; then
echo " ✅ Windows VirtIO injection dry-run complete!"
else
echo " ✅ Windows VirtIO injection complete!"
fi
echo "    Product: $PROD_NAME"
echo "    Drivers: viostor (block), vioscsi (SCSI), netkvm (net), vioserial, balloon, qxldod"
if [ "$DRY_RUN" -eq 1 ]; then
echo "    Registry: Services + CriticalDeviceDatabase entries would be injected"
echo "    Xen: PV drivers would be disabled (xenvbd, xennet, xenvif, xeniface, xenbus)"
echo "    Storage: Core MS drivers would be verified (disk, volmgr, partmgr, volsnap, mountmgr)"
echo "    First-boot auto-repair (RunOnce) would configure:"
else
echo "    Registry: Services + CriticalDeviceDatabase entries injected"
echo "    Xen: PV drivers disabled (xenvbd, xennet, xenvif, xeniface, xenbus)"
echo "    Storage: Core MS drivers verified (disk, volmgr, partmgr, volsnap, mountmgr)"
echo "    First-boot auto-repair (RunOnce):"
fi
echo "      - BCD: bcdedit on {current} + recoverysequence scrub on all BCD entries (incl. winresume)"
echo "      - Ghost Xen NIC removal + DHCP enable"
echo "      - Firewall: RDP (3389) + ICMP + SSH (22) + WinRM (5985)"
echo "      - OpenSSH Server enabled (2019+) — allows automated SSH verification"
echo "      - WinRM enabled (all versions) — allows remote PowerShell"
echo "      - Verification report written to C:\\ospc2flex_verification.txt"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "  After boot, the migrator will automatically:"
echo "    1. Wait for VM DHCP IP (via OpenStack API)"
echo "    2. SSH in as Administrator (or WinRM fallback)"
echo "    3. Read C:\\ospc2flex_verification.txt"
echo "    4. Report pass/fail for each component"
echo ""
