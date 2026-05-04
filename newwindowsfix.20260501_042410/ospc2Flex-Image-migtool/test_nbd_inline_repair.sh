#!/usr/bin/env bash
# Test harness for NBD inline repair (Stage 4.5 from ospc2flex_image_migrator.py)
# This simulates what the migration pipeline does when "NBD Inline Repair (per-OS)" is selected
set -euo pipefail

TESTDIR=/tmp/ospc2flex_nbd_inline_test
rm -rf "$TESTDIR" && mkdir -p "$TESTDIR"

# ── Logging helpers (same as pipeline) ─────────────────────────────────
log() { echo "$@"; }

create_test_image() {
  local name=$1 os_id=$2 ver=$3 has_netplan=$4
  local img=$TESTDIR/${name}.qcow2
  local mnt=$TESTDIR/mnt_${name}

  qemu-img create -f qcow2 "$img" 200M >/dev/null 2>&1
  sudo modprobe nbd max_part=8 2>/dev/null || true
  sudo qemu-nbd --disconnect /dev/nbd1 2>/dev/null || true
  sleep 1
  sudo qemu-nbd --connect=/dev/nbd1 "$img"
  sleep 2
  echo -e "n\np\n1\n\n\nw" | sudo fdisk /dev/nbd1 >/dev/null 2>&1 || true
  sleep 1
  sudo mkfs.ext4 -F /dev/nbd1p1 >/dev/null 2>&1
  sudo mkdir -p "$mnt"
  sudo mount /dev/nbd1p1 "$mnt"

  sudo mkdir -p "$mnt/etc"
  echo "ID=$os_id" | sudo tee "$mnt/etc/os-release" >/dev/null
  echo "VERSION_ID=\"$ver\"" | sudo tee -a "$mnt/etc/os-release" >/dev/null
  echo "PRETTY_NAME=\"Test $os_id $ver\"" | sudo tee -a "$mnt/etc/os-release" >/dev/null

  if [ "$has_netplan" = "yes" ]; then
    sudo mkdir -p "$mnt/etc/netplan"
  fi
  if [ "$os_id" = "debian" ] && [ "$has_netplan" != "yes" ]; then
    sudo mkdir -p "$mnt/etc/network"
    echo "auto lo" | sudo tee "$mnt/etc/network/interfaces" >/dev/null
  fi
  if echo "$os_id" | grep -qE "almalinux|rocky|centos|rhel"; then
    sudo mkdir -p "$mnt/etc/sysconfig/network-scripts"
    sudo mkdir -p "$mnt/etc/NetworkManager/system-connections"
  fi
  echo "/ ext4 defaults 0 1" | sudo tee "$mnt/etc/fstab" >/dev/null

  sudo umount "$mnt"
  sudo qemu-nbd --disconnect /dev/nbd1 2>/dev/null || true
  sleep 1
  echo "  [SETUP] Created: $name ($os_id $ver netplan=$has_netplan)"
}

# ── NBD Inline Repair Function (Stage 4.5 logic from ospc2flex_image_migrator.py) ──
nbd_inline_repair() {
  local converted_path=$1
  local test_name=$2
  local repair_ok=0
  local NBD_DEV=/dev/nbd0
  local MNT=/tmp/ospc2flex_mnt_$$

  echo ""
  echo "┌──────────────────────────────────────────────────────────┐"
  echo "│ NBD INLINE REPAIR (Stage 4.5) — $test_name"
  echo "└──────────────────────────────────────────────────────────┘"

  sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
  sleep 1
  sudo modprobe nbd max_part=8 2>/dev/null || true
  sleep 1
  if sudo qemu-nbd --connect="$NBD_DEV" "$converted_path" 2>/tmp/nbd_err.txt; then
    sleep 3
    ROOT_PART=$(sudo fdisk -l "$NBD_DEV" 2>/dev/null | awk '/Linux filesystem/{print $1; exit}')
    [ -z "$ROOT_PART" ] && ROOT_PART="${NBD_DEV}p1"
    log "  Root partition: $ROOT_PART"
    sudo mkdir -p "$MNT"
    # Try mount
    if sudo mount "$ROOT_PART" "$MNT" 2>/dev/null; then
      log '  [OK] Mounted normally'
    elif sudo mount -o norecovery,errors=remount-ro "$ROOT_PART" "$MNT" 2>/dev/null; then
      log '  [INFO] Mounted with norecovery flag'
    else
      log '  [WARN] Mount failed — skipping offline repair'
      sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
      return 1
    fi

    if sudo mountpoint -q "$MNT" 2>/dev/null; then
      # ── Fix fstab ──
      if [ -f "$MNT/etc/fstab" ]; then
        sudo cp "$MNT/etc/fstab" "$MNT/etc/fstab.ospc2flex.bak"
        sudo sed -i '/^[[:space:]]*#/b; /^[[:space:]]*$/b; /[[:space:]]\/[[:space:]]/b; /[[:space:]]swap[[:space:]]/b; s/^/# [ospc2flex] /' "$MNT/etc/fstab"
        log '  [OK] fstab non-root mounts commented out'
      fi

      # ── OS Detection ──
      _os_id_45=$(sudo grep '^ID=' "$MNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || true)
      _os_ver_45=$(sudo grep '^VERSION_ID=' "$MNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
      _os_major_45=$(echo "$_os_ver_45" | cut -d. -f1)
      log "  [4.5] Detected OS: $_os_id_45 version $_os_ver_45 (major=$_os_major_45)"

      # ── Fix netplan (Ubuntu + Debian 12+) ──
      if [ -d "$MNT/etc/netplan" ]; then
        sudo tee "$MNT/etc/netplan/99-ospc2flex.yaml" >/dev/null <<'NETPLAN_EOF'
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
        sudo chmod 600 "$MNT/etc/netplan/99-ospc2flex.yaml"
        log '  [OK] Netplan wildcard DHCP written (en*/eth*)'
        sudo rm -f "$MNT/etc/netplan/50-cloud-init.yaml" "$MNT/etc/netplan/50-curtin-networking.yaml" 2>/dev/null || true
        # Common cleanup
        sudo rm -f "$MNT/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
        echo "" | sudo tee "$MNT/etc/machine-id" >/dev/null
        log '  [OK] cloud-init state cleared, machine-id reset'
        sudo umount "$MNT" && repair_ok=1 || log '  [WARN] umount failed'
      elif [ "$_os_id_45" = "debian" ] && [ "${_os_major_45:-0}" -lt 12 ]; then
        log "  [INFO] Debian $_os_major_45 uses ifupdown (no netplan). repair_ok=0 → Stage 4.6"
        sudo umount "$MNT" 2>/dev/null || true
      else
        log "  [INFO] No /etc/netplan dir — RHEL/CentOS/Alma/Rocky. repair_ok=0 → Stage 4.6"
        sudo umount "$MNT" 2>/dev/null || true
      fi
    fi
    sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    sudo rm -rf "$MNT"
  else
    log "  [WARN] qemu-nbd connect failed: $(cat /tmp/nbd_err.txt 2>/dev/null | head -3)"
  fi

  if [ $repair_ok -eq 1 ]; then
    log "  ✅ NBD inline repair_ok=1 — would skip Stage 4.6"
  else
    log "  ⚠️  NBD inline repair_ok=0 — would trigger Stage 4.6 (ospc2flex_offline_repair.sh)"
  fi

  # ── Verify what was written ──
  log "  ── Verifying written files ──"
  sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
  sleep 1
  sudo qemu-nbd --connect="$NBD_DEV" "$converted_path" 2>/dev/null
  sleep 2
  local VMNT=/tmp/ospc2flex_verify_$$
  ROOT_PART=$(sudo fdisk -l "$NBD_DEV" 2>/dev/null | awk '/Linux filesystem/{print $1; exit}')
  [ -z "$ROOT_PART" ] && ROOT_PART="${NBD_DEV}p1"
  sudo mkdir -p "$VMNT"
  if sudo mount -o ro "$ROOT_PART" "$VMNT" 2>/dev/null; then
    local _vid=$(sudo grep '^ID=' "$VMNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"')
    local _vver=$(sudo grep '^VERSION_ID=' "$VMNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"')
    log "  [VERIFY] OS: $_vid $_vver"
    if sudo ls "$VMNT/etc/netplan/"*.yaml 2>/dev/null | grep -q .; then
      log "  [VERIFY] netplan YAML: FOUND ✅"
      sudo cat "$VMNT/etc/netplan/99-ospc2flex.yaml" 2>/dev/null | head -5 | sed 's/^/    /'
    else
      log "  [VERIFY] netplan YAML: NOT FOUND"
    fi
    if sudo test -f "$VMNT/etc/network/interfaces" 2>/dev/null; then
      log "  [VERIFY] /etc/network/interfaces: FOUND"
    fi
    if sudo test -f "$VMNT/etc/sysconfig/network-scripts/ifcfg-eth0" 2>/dev/null; then
      log "  [VERIFY] ifcfg-eth0: FOUND"
    fi
    if sudo test -f "$VMNT/etc/NetworkManager/system-connections/eth0.nmconnection" 2>/dev/null; then
      log "  [VERIFY] eth0.nmconnection: FOUND"
    fi
    sudo umount "$VMNT" 2>/dev/null || true
  fi
  sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
  sudo rm -rf "$VMNT"

  echo "  ────────────────────────────────────────────────────"
  return 0
}

# ── Create test images ──
echo "============================================================"
echo "  CREATING TEST IMAGES"
echo "============================================================"
create_test_image u20test ubuntu 20.04 yes
create_test_image u22test ubuntu 22.04 yes
create_test_image u24test ubuntu 24.04 yes
create_test_image d10test debian 10.13 no
create_test_image d11test debian 11.8 no
create_test_image d12test debian 12.4 yes
create_test_image a8test almalinux 8.9 no
create_test_image a9test almalinux 9.3 no
create_test_image c7test centos 7.9 no
create_test_image r8test rhel 8.10 no

echo ""
echo "============================================================"
echo "  NBD INLINE REPAIR DRY-RUN TESTS (Stage 4.5)"
echo "============================================================"

for img in u20test u22test u24test d10test d11test d12test a8test a9test c7test r8test; do
  nbd_inline_repair "$TESTDIR/${img}.qcow2" "$img"
done

echo ""
echo "============================================================"
echo "  ALL NBD INLINE TESTS COMPLETE"
echo "============================================================"
rm -rf "$TESTDIR"
