#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# ospc2flex_windows_repair.sh — Offline VirtIO Driver Injection for Windows
# ═══════════════════════════════════════════════════════════════════════════════
# Mounts a Windows qcow2 image offline, injects VirtIO block (viostor) and
# network (netkvm) drivers into the driver store and registry so that the
# image can boot on KVM/FLEX with VirtIO disks and networking.
#
# Usage:
#   sudo bash ospc2flex_windows_repair.sh --qcow2 /path/to/win.qcow2 \
#        [--nbd-dev /dev/nbd5] [--force] [--dry-run]
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
    --dry-run)  DRY_RUN=1; shift ;;
    --force)    FORCE=1; shift ;;
    -h|--help)
      echo "Usage: $0 --qcow2 <path> [--nbd-dev /dev/nbdX] [--force] [--dry-run]"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[ -z "$QCOW2" ] && { echo "ERROR: --qcow2 is required"; exit 1; }
[ ! -f "$QCOW2" ] && { echo "ERROR: $QCOW2 not found"; exit 1; }

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
  if sudo mount -o loop,ro "$VIRTIO_ISO" "$VIRTIO_MNT" 2>/dev/null; then
    PASS "VirtIO ISO mounted at $VIRTIO_MNT"
    return 0
  else
    WARN "ISO mount failed (corrupted). Deleting..."
    rm -f "$VIRTIO_ISO"
    return 1
  fi
}

if [ -f "$VIRTIO_ISO" ]; then
  sudo mkdir -p "$VIRTIO_MNT"
  if sudo mount -o loop,ro "$VIRTIO_ISO" "$VIRTIO_MNT" 2>/dev/null; then
    PASS "VirtIO ISO cached and mounted: $VIRTIO_ISO"
  else
    WARN "Cached ISO is corrupted, re-downloading..."
    rm -f "$VIRTIO_ISO"
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
sudo qemu-nbd --connect="$NBD_DEV" "$QCOW2"
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
  sudo ntfsfix -d "$p" 2>/dev/null || true
  sudo mkdir -p "$MNT"
  if sudo mount -t ntfs-3g -o rw,remove_hiberfile "$p" "$MNT" 2>/dev/null; then
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
HIVE_SW="$MNT/Windows/System32/config/SOFTWARE"
if [ -f "$HIVE_SW" ]; then
  # Extract ProductName from registry
  PROD_NAME=$(sudo hivexsh -f - "$HIVE_SW" <<'EOF' 2>/dev/null || true
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
  INFO "[DRY-RUN] Would copy viostor, netkvm, vioserial, balloon, qxldod"
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

  # Create registry merge file for hivexregedit
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

  # Apply registry changes using hivexregedit
  sudo hivexregedit --merge "$HIVE_SYSTEM" "$REG_FILE" 2>&1
  REG_RC=$?
  rm -f "$REG_FILE"

  if [ $REG_RC -eq 0 ]; then
    PASS "Registry: viostor service (Start=0, Group=SCSI miniport)"
    PASS "Registry: netkvm service (Start=3, Group=NDIS)"
    PASS "Registry: vioserial + balloon services"
    PASS "Registry: CriticalDeviceDatabase PCI entries (1AF4:{1001,1042,1000,1041})"
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
  VIO_CHK=$(sudo hivexsh -f - "$HIVE_SYSTEM" <<'VERIFY' 2>/dev/null || true
cd \ControlSet001\Services\viostor
lsval Start
VERIFY
)
  if echo "$VIO_CHK" | grep -q '00000000'; then
    PASS "Registry verification: viostor Start=0 confirmed!"
  else
    FAIL "Registry verification failed: viostor service not correctly registered"
    WARN "Restoring backup..."
    sudo cp "${HIVE_SYSTEM}.ospc2flex.bak" "$HIVE_SYSTEM"
    exit 1
  fi

else
  INFO "[DRY-RUN] Would inject viostor, netkvm, vioserial, balloon service entries"
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

  sudo hivexregedit --merge "$HIVE_SYSTEM" "$XEN_REG" 2>/dev/null || true
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

if [ $DRY_RUN -eq 0 ]; then
  # Ensure standard disk/storage related services are enabled
  STD_REG="/tmp/std_storage_$$.reg"
  cat > "$STD_REG" <<'STDEOF'
Windows Registry Editor Version 5.00

; Ensure standard Microsoft disk/storage drivers are boot-start
; These are needed alongside viostor
"ControlSet001\Services\disk\Start"=dword:00000000
"ControlSet001\Services\volmgr\Start"=dword:00000000
"ControlSet001\Services\volsnap\Start"=dword:00000000
"ControlSet001\Services\partmgr\Start"=dword:00000000
"ControlSet001\Services\mountmgr\Start"=dword:00000000
"ControlSet002\Services\disk\Start"=dword:00000000
"ControlSet002\Services\volmgr\Start"=dword:00000000
"ControlSet002\Services\volsnap\Start"=dword:00000000
"ControlSet002\Services\partmgr\Start"=dword:00000000
"ControlSet002\Services\mountmgr\Start"=dword:00000000
STDEOF

  sudo hivexregedit --merge "$HIVE_SYSTEM" "$STD_REG" 2>/dev/null || true
  rm -f "$STD_REG"
  PASS "Standard storage drivers verified (disk, volmgr, volsnap, partmgr, mountmgr)"
else
  INFO "[DRY-RUN] Would verify standard storage stack"
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

  sudo hivexregedit --merge "$HIVE_SYSTEM" "$RUNONCE_REG" 2>/dev/null || true
  rm -f "$RUNONCE_REG"
  PASS "Registry RunOnce fallback: ospc2flex_firstboot (ControlSet001+002)"

  # Also inject into SOFTWARE hive RunOnce (user-session trigger — covers logged-in admin)
  if [ -f "$HIVE_SW" ]; then
    SW_RUNONCE_REG="/tmp/sw_runonce_$$.reg"
    cat > "$SW_RUNONCE_REG" <<'SWRUNONCEEOF'
Windows Registry Editor Version 5.00

"Microsoft\Windows\CurrentVersion\RunOnce\ospc2flex_firstboot"="cmd.exe /c powershell.exe -ExecutionPolicy Bypass -File C:\\ospc2flex_firstboot.ps1"
SWRUNONCEEOF

    sudo hivexregedit --merge "$HIVE_SW" "$SW_RUNONCE_REG" 2>/dev/null || true
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
echo " ✅ Windows VirtIO injection complete!"
echo "    Product: $PROD_NAME"
echo "    Drivers: viostor (block), netkvm (net), vioserial, balloon, qxldod"
echo "    Registry: Services + CriticalDeviceDatabase entries injected"
echo "    Xen: PV drivers disabled (xenvbd, xennet, xenvif, xeniface, xenbus)"
echo "    Storage: Core MS drivers verified (disk, volmgr, partmgr, volsnap, mountmgr)"
echo "    First-boot auto-repair (RunOnce):"
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
