#!/usr/bin/env bash
set -euo pipefail

# ─── Logging helpers ────────────────────────────────────────────────────────
log() { echo "$@"; }
stage_start() { local n=$1 t=$2 d=$3
  echo ""
  echo ""
  echo "┌──────────────────────────────────────────────────────┐"
  echo "│ STAGE $n ── $t"
  echo "│ $d"
  echo "└──────────────────────────────────────────────────────┘"
}
stage_done() { local n=$1; echo "✅ STAGE $n RESULT: SUCCESS"; echo ""; }
stage_fail() { local n=$1 msg=$2; echo "❌ STAGE $n RESULT: FAILED ── $msg"; echo ""; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║        OSPC → FLEX Datacenter Backbone Pipeline ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

export_retries=4
export_retry_wait=15
# ── Workspace Initialization ──────────────────────────────────────────────────
# Dynamically find the mount point with the largest available free space (Strictly bypassing root drive if possible)
BEST_MOUNT=$(df -P -k | awk 'NR>1 && $1 !~ /tmpfs|udev|devtmpfs|overlay|shm|loop/ && $6 !~ /^[/](boot|run|dev|sys|proc|snap|var[/]lib)/ && $6 != "/" { print $4, $6 }' | sort -rn | head -n1 | awk '{print $2}')

if [ -n "$BEST_MOUNT" ]; then
    workdir="$BEST_MOUNT/ospc2flex_image"
else
    workdir=$(eval echo '$HOME/image')
    log "[WARN] Strict policy fallback: No external data volumes found. Resorting to root drive."
fi

log "[INFO] Largest volume identified: $BEST_MOUNT"
log "[INFO] Using workspace folder: $workdir"
sudo mkdir -p "$workdir"
sudo chown $(whoami):$(whoami) "$workdir" 2>/dev/null || true
# ── Path definitions — always tied to THIS VM's snap_name ─────────────────────
# Never reuse another VM's leftover qcow2 (parallel jobs share the same workdir)
repaired_path="$workdir/centos7-snap-20260416210941-repaired.qcow2"
converted_path="$workdir/centos7-snap-20260416210941.qcow2"

# Only resume if the exact file for this snap_name exists
if [ -f "$repaired_path" ]; then
    log "[INFO] Found retained repaired image from previous run: $repaired_path"
fi
if [ -f "$converted_path" ]; then
    log "[INFO] Found retained converted image from previous run: $converted_path"
fi

img_path="$workdir/centos7-snap-20260416210941.img"

# ── STAGE 1 ─────────────────────────────────────────────────────────────────
stage_start 1 'Validate Dependencies' 'Checking openstack CLI and qemu-img'
if ! command -v openstack >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/openstack" ]; then
  log '  Installing OpenStack CLI...'
  sudo apt-get update >/dev/null 2>&1 || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-openstackclient >/dev/null 2>&1 || \
    python3 -m pip install --break-system-packages --user python-openstackclient >/dev/null 2>&1 || true
  log '  [OK] openstack CLI installed'
else
  log '  [OK] openstack CLI present'
fi
if ! command -v qemu-img >/dev/null 2>&1; then
  log '  Installing qemu-utils...'
  sudo apt-get update >/dev/null 2>&1 || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-utils >/dev/null 2>&1
  log '  [OK] qemu-img installed'
else
  log '  [OK] qemu-img present'
fi
stage_done 1

# ── Fast-path: if repaired image already exists, skip everything ──────────────
if [ -f "$repaired_path" ]; then
  log "  [INFO] Repaired image already exists: $repaired_path"
  log "  [INFO] Skipping stages 1-4.5 — going straight to upload handoff"
else

# ── STAGE 2.5: Clean Old Workspace Images ────────────────────────────────────
# Only delete files belonging to THIS VM's snap prefix — never touch other VMs' files
# (parallel jobs share the same workdir — deleting other VMs' qcow2s would corrupt them)
stage_start '2.5' 'Clean Old Workspace' 'Removing previous .img + .qcow2 from old runs (freeing disk space)'
cleaned=0
SNAP_PREFIX="centos7-snap-20260416210941"
for f in "$workdir"/"$SNAP_PREFIX"*.img "$workdir"/"$SNAP_PREFIX"*.qcow2; do
  [ -f "$f" ] || continue
  [ "$f" = "$img_path" ] && continue
  [ "$f" = "$converted_path" ] && continue
  [ "$f" = "$repaired_path" ] && continue
  rm -f "$f" && log "  [DEL] $f" && cleaned=$((cleaned+1))
done
[ $cleaned -eq 0 ] && log '  [OK] No old images to clean' || log "  [OK] Removed $cleaned old image file(s)"
df -h "$workdir" | tail -1 | awk '{print "  [INFO] Disk free: " $4 " / " $2}'
stage_done '2.5'

# ── Check: skip to repair if converted .qcow2 already exists ─────────────────
if [ -f "$converted_path" ]; then
  log "  [INFO] Converted qcow2 exists: $converted_path — skipping to stage 4.5 (offline repair)"
else
# ── STAGE 3: Download OSPC Snapshot ──────────────────────────────────────────
stage_start 3 'Download OSPC Snapshot' 'Streaming disk image from OSPC Glance'
log '  Sourcing OSPC credentials...'
source /tmp/ospc2flex_ospc.sh
log '  Acquiring OSPC Keystone token...'
OS_TOKEN=$(openstack token issue -f value -c id 2>/dev/null || true)
if [ -z "$OS_TOKEN" ]; then
  stage_fail 3 'No OSPC token — check OSPC credentials'
fi
OS_IMAGE_URL=$(openstack catalog show image -f json 2>/dev/null | python3 -c "
import sys,json
data=json.load(sys.stdin)
eps=[e for e in data.get('endpoints',[]) if e.get('interface')=='public']
print(eps[0]['url'].rstrip('/') if eps else '')
" 2>/dev/null || true)
if [ -z "$OS_IMAGE_URL" ]; then
  log '  [WARN] Catalog lookup failed — using DFW3 Glance default'
  OS_IMAGE_URL='https://glance.api.dfw3.rackspacecloud.com'
fi
IMG_DOWNLOAD_URL="$OS_IMAGE_URL/v2/images/477f0792-e508-4ab7-a458-fe67c05ed8fd/file"
log "  Target: $IMG_DOWNLOAD_URL"
success=0
for attempt in $(seq 1 $export_retries); do
  log "  Attempt $attempt/$export_retries — large file, please wait..."
  HTTP_STATUS=$(curl -s -C - -L --retry 3 --retry-delay 10 --retry-max-time 180 \
    -H "X-Auth-Token: $OS_TOKEN" \
    -o "$img_path" \
    --write-out '%{http_code}' \
    "$IMG_DOWNLOAD_URL" 2>/dev/null || echo '000')
  size=$(stat -c%s "$img_path" 2>/dev/null || echo 0)
  log "  HTTP $HTTP_STATUS | $size bytes received"
  if [ "$size" -gt 1048576 ]; then
    log "  [OK] Download complete: $size bytes"
    success=1; break
  else
    log "  [WARN] Incomplete (size=$size) — refreshing token and retrying..."
    OS_TOKEN=$(openstack token issue -f value -c id 2>/dev/null || true)
    rm -f "$img_path"
  fi
  [ $attempt -lt $export_retries ] && { log "  Waiting ${export_retry_wait}s..."; sleep $export_retry_wait; }
done
[ $success -eq 0 ] && stage_fail 3 'Download failed after all attempts'
stage_done 3

# ── STAGE 4: Convert Image Format ────────────────────────────────────────────
stage_start 4 'Convert Image Format' 'Detect format via qemu-img info then convert → qcow2'
DETECTED_FMT=$(qemu-img info --output=json "$img_path" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('format','raw'))" 2>/dev/null || echo 'raw')
log "  [INFO] Detected source format: $DETECTED_FMT"
if [ "$DETECTED_FMT" = "qcow2" ]; then
  log '  [INFO] Source already in target format — copying without re-encoding'
  cp "$img_path" "$converted_path"
else
  log "  [INFO] Converting $DETECTED_FMT → qcow2..."
  qemu-img convert -p -f "$DETECTED_FMT" -O qcow2 "$img_path" "$converted_path"
fi
SIZE=$(ls -lh "$converted_path" | awk '{print $5}')
log "  [OK] Output: $converted_path ($SIZE)"
stage_done 4

fi  # end skip-if-qcow2-exists

# ── STAGE 4.5: Offline Guest Repair ──────────────────────────────────────────
REPAIR_METHOD=custom_os   # custom_os | generic
repair_ok=0   # initialized here; set to 1 by custom_os on successful umount
if [ "$REPAIR_METHOD" = "generic" ]; then
  stage_start '4.5' 'Offline Guest Repair' 'Generic mode — running ospc2flex_offline_repair.sh directly (no per-OS profile)'
  STANDALONE_REPAIR=/tmp/ospc2flex_offline_repair.sh
  cp "$converted_path" "$repaired_path"
  log "  [INFO] Generic repair: running $STANDALONE_REPAIR on $repaired_path"
  if [ -f "$STANDALONE_REPAIR" ]; then
    if bash "$STANDALONE_REPAIR" --qcow2 "$repaired_path" --force; then
      log "  [OK] Generic repair completed successfully"
      repair_ok=1
    else
      log "  [WARN] Generic repair failed — will retry in Stage 4.6 fallback"
    fi
  else
    log "  [WARN] $STANDALONE_REPAIR not found on jumphost — skipping generic repair"
    log "  [WARN] Was the script staged in pre-flight? Falling back to Stage 4.6"
  fi
  stage_done '4.5'
else
stage_start '4.5' 'Offline Guest Repair' 'Smart OS-profile repair: fstab + network + cloud-init + pkg install per detected OS'
MNT=/tmp/ospc2flex_mnt_$$
if ! command -v qemu-nbd >/dev/null 2>&1; then
  log '  [INFO] qemu-nbd not found — installing qemu-utils...'
  sudo apt-get install -y qemu-utils >/dev/null 2>&1 && log '  [OK] qemu-utils installed' || log '  [WARN] Install failed'
fi
if command -v qemu-nbd >/dev/null 2>&1; then
  # Pick a free NBD device (parallel jobs may be using nbd0, nbd1, etc.)
  sudo modprobe nbd max_part=8 2>/dev/null || true
  NBD_DEV=""
  for _nbd in /dev/nbd{0..15}; do
    if ! sudo lsblk "$_nbd" 2>/dev/null | grep -q "disk"; then
      if ! sudo fuser "$_nbd" 2>/dev/null | grep -q .; then
        NBD_DEV="$_nbd"
        break
      fi
    fi
  done
  if [ -z "$NBD_DEV" ]; then
    log "  [WARN] No free NBD device found — skipping offline repair (all nbd0-15 busy)"
  else
  log "  [INFO] Using NBD device: $NBD_DEV"
  # Disconnect any stale connection on this device first
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
    # Run fsck to repair dirty journal from live snapshot
    log '  Running fsck to repair dirty journal...'
    sudo fsck -y "$ROOT_PART" >/tmp/fsck_out.txt 2>&1 || true
    log "  fsck: $(tail -2 /tmp/fsck_out.txt 2>/dev/null | tr '\n' ' ')"
    # Try normal mount, then ro fallback, then norecovery fallback
    if sudo mount "$ROOT_PART" "$MNT" 2>/dev/null; then
      log '  [OK] Mounted normally'
    elif sudo mount -o ro "$ROOT_PART" "$MNT" 2>/dev/null; then
      log '  [INFO] Mounted read-only (journal may still be dirty)'
    elif sudo mount -o norecovery,ro "$ROOT_PART" "$MNT" 2>/dev/null; then
      log '  [INFO] Mounted with norecovery,ro'
    else
      log '  [WARN] Mount failed (tried normal + ro + norecovery) — skipping offline repair'
      sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
      sudo rmmod nbd 2>/dev/null || true
    fi
    if sudo mountpoint -q "$MNT" 2>/dev/null; then
      # OS pre-detected from live origin VM via SSH (injected by orchestrator)
      OS_ID=''
      OS_VER=''
      if [ -z "$OS_ID" ] || [ "$OS_ID" = 'unknown' ]; then
        # Fallback: detect from mounted image (may be unreliable for cloud images)
        OS_ID=$(sudo grep '^ID=' "$MNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || true)
        OS_VER=$(sudo grep '^VERSION_ID=' "$MNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
        if [ -z "$OS_ID" ] || [ "$OS_ID" = 'unknown' ]; then
          OS_ID='ubuntu'; OS_VER='24.04'
          log '  [OS] Detection failed — defaulting to ubuntu (netplan repair)'
        else
          log "  [OS] Detected from mounted image: $OS_ID $OS_VER"
        fi
      else
        log "  [OS] Using pre-detected OS (from live SSH): $OS_ID $OS_VER"
      fi

      # Fix fstab — keep LABEL=/UUID=/PARTUUID= entries, comment /dev/* paths
      if [ -f "$MNT/etc/fstab" ]; then
        sudo cp "$MNT/etc/fstab" "$MNT/etc/fstab.ospc2flex.bak"
        sudo sed -i '/^[[:space:]]*#/b; /^[[:space:]]*$/b; /LABEL=/b; /UUID=/b; /PARTUUID=/b; s/^/# [ospc2flex] /' "$MNT/etc/fstab"
        log '  [OK] fstab: kept LABEL=/UUID=/PARTUUID= — commented /dev/* paths (vdb swap etc.)'
        sudo grep -v '^#' "$MNT/etc/fstab" | grep -v '^[[:space:]]*$' || log '  (no active non-commented entries)'
      fi
      # ── OS-Profile Repair: network config per detected OS ────────────────────
      log "  [PROFILE] Applying OS repair profile for: $OS_ID $OS_VER"
      case "$OS_ID" in

        # ── Ubuntu ───────────────────────────────────────────────────────────
        ubuntu)
          OS_MAJOR_VER="${OS_VER%%.*}"
          if [ "$OS_MAJOR_VER" = "24" ]; then
            # ── Ubuntu 24.04 custom profile (flex_repair_template_ubuntu24.yaml) ──
            # FLEX NIC is enp3s0. cloud-init writes 50-cloud-init.yaml locked to
            # original OSPC MAC — must be deleted or network breaks on first boot.
            log '  [PROFILE] Ubuntu 24.04 → custom profile (enp3s0, delete 50-cloud-init.yaml)'
            sudo rm -f "$MNT/etc/netplan/50-cloud-init.yaml" 2>/dev/null || true
            log '  [OK] Ubuntu 24: deleted MAC-locked 50-cloud-init.yaml'
            sudo mkdir -p "$MNT/etc/netplan"
            sudo tee "$MNT/etc/netplan/99-ospc2flex.yaml" >/dev/null <<'NETPLAN_U24_EOF'
network:
  version: 2
  ethernets:
    enp3s0:
      dhcp4: true
      dhcp6: false
NETPLAN_U24_EOF
            log '  [OK] Ubuntu 24: wrote 99-ospc2flex.yaml (enp3s0 DHCP)'
          else
            # ── Ubuntu 16 / 18 / 20 / 22 — generic wildcard fallback (proven Apr 9) ──
            log "  [PROFILE] Ubuntu $OS_VER → generic wildcard DHCP netplan (en*/eth*)"
            sudo mkdir -p "$MNT/etc/netplan.ospc2flex.bak"
            sudo cp -a "$MNT/etc/netplan/"*.yaml "$MNT/etc/netplan.ospc2flex.bak/" 2>/dev/null || true
            sudo cp -a "$MNT/etc/netplan/"*.yml  "$MNT/etc/netplan.ospc2flex.bak/" 2>/dev/null || true
            sudo rm -f "$MNT/etc/netplan/"*.yaml "$MNT/etc/netplan/"*.yml 2>/dev/null || true
            sudo mkdir -p "$MNT/etc/netplan"
            sudo tee "$MNT/etc/netplan/99-flex-fallback.yaml" >/dev/null <<'NETPLAN_FLEX_EOF'
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
NETPLAN_FLEX_EOF
            sudo chmod 600 "$MNT/etc/netplan/99-flex-fallback.yaml"
            log "  [OK] Ubuntu $OS_VER: wildcard DHCP fallback netplan written"
          fi
          CHROOT_PKG_MGR="apt"
          CHROOT_INITRD="update-initramfs -u -k all"
          ;;

        # ── Debian 10 / 11 / 12 ──────────────────────────────────────────────
        debian)
          log '  [PROFILE] Debian → /etc/network/interfaces (ifupdown DHCP)'
          sudo cp "$MNT/etc/network/interfaces" "$MNT/etc/network/interfaces.ospc2flex.bak" 2>/dev/null || true
          sudo tee "$MNT/etc/network/interfaces" >/dev/null <<'IFACE_EOF'
auto lo
iface lo inet loopback
auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
    mtu 3942
IFACE_EOF
          # Remove any leftover netplan that may conflict
          sudo rm -f "$MNT/etc/netplan/"*.yaml "$MNT/etc/netplan/"*.yml 2>/dev/null || true
          log '  [OK] Debian: /etc/network/interfaces written (eth0 DHCP, mtu 3942)'
          CHROOT_PKG_MGR="apt"
          CHROOT_INITRD="update-initramfs -u -k all"
          ;;

        # ── AlmaLinux 8 / 9 ──────────────────────────────────────────────────
        almalinux)
          log "  [PROFILE] AlmaLinux $OS_VER → NetworkManager keyfile (DHCP)"
          sudo mkdir -p "$MNT/etc/NetworkManager/system-connections"
          sudo tee "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection" >/dev/null <<'NM_EOF'
[connection]
id=eth0
type=ethernet
interface-name=eth0
autoconnect=true

[ethernet]
mtu=3942

[ipv4]
method=auto

[ipv6]
method=disabled
NM_EOF
          sudo chmod 600 "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection"
          # Remove legacy ifcfg if present (AlmaLinux 9 dropped it)
          sudo rm -f "$MNT/etc/sysconfig/network-scripts/ifcfg-eth0" 2>/dev/null || true
          log '  [OK] AlmaLinux: NetworkManager keyfile written'
          CHROOT_PKG_MGR="dnf"
          CHROOT_INITRD="dracut -f --regenerate-all"
          ;;

        # ── Rocky Linux 8 / 9 ────────────────────────────────────────────────
        rocky)
          log "  [PROFILE] Rocky Linux $OS_VER → NetworkManager keyfile (DHCP)"
          sudo mkdir -p "$MNT/etc/NetworkManager/system-connections"
          sudo tee "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection" >/dev/null <<'NM_EOF'
[connection]
id=eth0
type=ethernet
interface-name=eth0
autoconnect=true

[ethernet]
mtu=3942

[ipv4]
method=auto

[ipv6]
method=disabled
NM_EOF
          sudo chmod 600 "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection"
          sudo rm -f "$MNT/etc/sysconfig/network-scripts/ifcfg-eth0" 2>/dev/null || true
          log '  [OK] Rocky Linux: NetworkManager keyfile written'
          CHROOT_PKG_MGR="dnf"
          CHROOT_INITRD="dracut -f --regenerate-all"
          ;;

        # ── RHEL 8 / 9 ───────────────────────────────────────────────────────
        rhel)
          log "  [PROFILE] RHEL $OS_VER → NetworkManager keyfile (DHCP)"
          sudo mkdir -p "$MNT/etc/NetworkManager/system-connections"
          sudo tee "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection" >/dev/null <<'NM_EOF'
[connection]
id=eth0
type=ethernet
interface-name=eth0
autoconnect=true

[ethernet]
mtu=3942

[ipv4]
method=auto

[ipv6]
method=disabled
NM_EOF
          sudo chmod 600 "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection"
          log '  [OK] RHEL: NetworkManager keyfile written'
          CHROOT_PKG_MGR="dnf"
          CHROOT_INITRD="dracut -f --regenerate-all"
          ;;

        # ── CentOS 7 (legacy ifcfg + yum) ────────────────────────────────────
        centos)
          log "  [PROFILE] CentOS $OS_VER → ifcfg-eth0 (legacy network-scripts)"
          sudo mkdir -p "$MNT/etc/sysconfig/network-scripts"
          sudo cp "$MNT/etc/sysconfig/network-scripts/ifcfg-eth0"                   "$MNT/etc/sysconfig/network-scripts/ifcfg-eth0.ospc2flex.bak" 2>/dev/null || true
          sudo tee "$MNT/etc/sysconfig/network-scripts/ifcfg-eth0" >/dev/null <<'IFCFG_EOF'
DEVICE=eth0
NAME=eth0
TYPE=Ethernet
BOOTPROTO=dhcp
ONBOOT=yes
MTU=3942
NM_CONTROLLED=yes
IFCFG_EOF
          # Enable legacy network service via direct symlink (no chroot — RPM from Ubuntu jumphost unsafe)
          sudo mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
          sudo ln -sf /lib/systemd/system/network.service             "$MNT/etc/systemd/system/multi-user.target.wants/network.service" 2>/dev/null || true
          log '  [OK] CentOS: ifcfg-eth0 written (DHCP, mtu 3942)'
          CHROOT_PKG_MGR="yum"
          CHROOT_INITRD="dracut -f --regenerate-all"
          ;;

        # ── Fedora (38+) ─────────────────────────────────────────────────────
        fedora)
          log "  [PROFILE] Fedora $OS_VER → NetworkManager keyfile (DHCP)"
          sudo mkdir -p "$MNT/etc/NetworkManager/system-connections"
          sudo tee "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection" >/dev/null <<'NM_EOF'
[connection]
id=eth0
type=ethernet
interface-name=eth0
autoconnect=true

[ethernet]
mtu=3942

[ipv4]
method=auto

[ipv6]
method=disabled
NM_EOF
          sudo chmod 600 "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection"
          log '  [OK] Fedora: NetworkManager keyfile written'
          CHROOT_PKG_MGR="dnf"
          CHROOT_INITRD="dracut -f --regenerate-all"
          ;;

        # ── openSUSE / SLES ───────────────────────────────────────────────────
        opensuse*|sles|suse)
          log "  [PROFILE] openSUSE/SLES $OS_VER → /etc/sysconfig/network/ifcfg-eth0"
          sudo mkdir -p "$MNT/etc/sysconfig/network"
          sudo tee "$MNT/etc/sysconfig/network/ifcfg-eth0" >/dev/null <<'SUSE_EOF'
BOOTPROTO=dhcp
STARTMODE=auto
MTU=3942
SUSE_EOF
          sudo tee "$MNT/etc/sysconfig/network/routes" >/dev/null <<'ROUTE_EOF'
default - - -
ROUTE_EOF
          log '  [OK] openSUSE/SLES: ifcfg-eth0 written (DHCP)'
          CHROOT_PKG_MGR="zypper"
          CHROOT_INITRD="mkinitrd"
          ;;

        # ── Fallback: unknown OS ──────────────────────────────────────────────
        *)
          log "  [WARN] Unknown OS '$OS_ID' — applying generic netplan DHCP fallback"
          sudo mkdir -p "$MNT/etc/netplan"
          sudo tee "$MNT/etc/netplan/99-flex-fallback.yaml" >/dev/null <<'NETPLAN_FALLBACK_EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      optional: true
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      optional: true
NETPLAN_FALLBACK_EOF
          sudo chmod 600 "$MNT/etc/netplan/99-flex-fallback.yaml"
          log "  [WARN] Fallback netplan written — manual network review recommended after boot"
          CHROOT_PKG_MGR="apt"
          CHROOT_INITRD="update-initramfs -u -k all"
          ;;
      esac

      # ── Common: clear OSPC udev rules ────────────────────────────────────
      sudo rm -f "$MNT/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
      sudo rm -f "$MNT/etc/udev/rules.d/75-persistent-net-generator.rules" 2>/dev/null || true
      log '  [OK] OSPC udev persistent-net rules removed'

      # ── Common: reset cloud-init state ───────────────────────────────────
      sudo rm -f "$MNT/etc/cloud/cloud-init.disabled" 2>/dev/null || true
      sudo rm -rf "$MNT/var/lib/cloud/instance" "$MNT/var/lib/cloud/instances/"* 2>/dev/null || true
      sudo rm -f "$MNT/var/lib/cloud/data/result.json" 2>/dev/null || true
      echo "" | sudo tee "$MNT/etc/machine-id" >/dev/null
      sudo rm -f "$MNT/var/lib/dbus/machine-id" 2>/dev/null || true
      sudo rm -f "$MNT/var/lib/dhcp/"*.leases 2>/dev/null || true
      sudo rm -f "$MNT/var/lib/dhclient/"*.lease 2>/dev/null || true
      log '  [OK] cloud-init state cleared, machine-id reset, DHCP leases removed'

      # ── Chroot pkg install — Debian-family only (apt safe from Ubuntu jumphost) ─
      # RPM-based (AlmaLinux/Rocky/RHEL/CentOS/Fedora) and openSUSE skip chroot —
      # cross-distro chroot from Ubuntu jumphost is untested and risks corruption.
      # cloud-init + qemu-guest-agent are pre-installed in most RHEL cloud images.
      case "$CHROOT_PKG_MGR" in
        apt)
          log "  [INFO] Chroot pass (apt): installing cloud-init + qemu-guest-agent..."
          sudo mount --bind /proc "$MNT/proc" 2>/dev/null || true
          sudo mount --bind /sys  "$MNT/sys"  2>/dev/null || true
          sudo mount --bind /dev  "$MNT/dev"  2>/dev/null || true
          sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
          sudo chroot "$MNT" bash -c             'DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null && apt-get install -y cloud-init qemu-guest-agent 2>/dev/null'             >/dev/null 2>&1 || log '  [WARN] apt install partial or skipped'
          log "  [INFO] Rebuilding initramfs: $CHROOT_INITRD"
          sudo chroot "$MNT" bash -c "$CHROOT_INITRD" >/dev/null 2>&1             || log '  [WARN] initramfs rebuild partial or skipped'
          sudo umount "$MNT/dev" "$MNT/sys" "$MNT/proc" 2>/dev/null || true
          log "  [OK] Chroot pass complete for $OS_ID $OS_VER"
          ;;
        dnf|yum|zypper)
          log "  [INFO] Skipping chroot pkg install for $OS_ID (RPM/SUSE from Ubuntu jumphost — unsafe)"
          log "  [INFO] cloud-init + qemu-guest-agent expected pre-installed in cloud image"
          ;;
      esac

      sudo umount "$MNT" && repair_ok=1 || log '  [WARN] umount failed'

    fi
    sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    sudo rmmod nbd 2>/dev/null || true
    sudo rm -rf "$MNT"
  else
    log "  [WARN] qemu-nbd connect failed"
    sudo rmmod nbd 2>/dev/null || true
  fi
  fi  # end if NBD_DEV found
fi  # end if qemu-nbd available

if [ $repair_ok -eq 1 ]; then
  mv "$converted_path" "$repaired_path"
  log "  [OK] Repaired image saved as: $repaired_path"
else
  cp "$converted_path" "$repaired_path"
  log "  [WARN] Stage 4.5 repair skipped — will attempt Stage 4.6 standalone fallback"
fi
stage_done '4.5'
fi  # end custom_os vs generic branch

# ── STAGE 4.6: Standalone Offline Repair Fallback ────────────────────────────
# Runs if Stage 4.5 repair_ok=0 — covers both modes:
#   custom_os: NBD fail / mount fail / unknown OS
#   generic:   ospc2flex_offline_repair.sh failed or not found in Stage 4.5
if [ $repair_ok -eq 0 ]; then
  stage_start '4.6' 'Standalone Repair Fallback' 'Stage 4.5 repair_ok=0 — retrying with ospc2flex_offline_repair.sh'
  STANDALONE_REPAIR=/tmp/ospc2flex_offline_repair.sh
  if [ -f "$STANDALONE_REPAIR" ]; then
    log "  [INFO] Running standalone repair on: $repaired_path"
    if bash "$STANDALONE_REPAIR" --qcow2 "$repaired_path" --force; then
      log "  [OK] Standalone repair completed successfully"
      repair_ok=1
    else
      log "  [WARN] Standalone repair also failed — image will be uploaded as-is"
      log "  [WARN] Manual guest repair may be needed after FLEX boot"
    fi
  else
    log "  [WARN] $STANDALONE_REPAIR not found — standalone fallback unavailable"
    log "  [WARN] Image will be uploaded as-is — manual repair may be needed after boot"
  fi
  stage_done '4.6'
fi

fi # end skip-if-repaired-exists

# ── STAGE 5: Upload to FLEX Glance ───────────────────────────────────────────
stage_start 5 'Upload to FLEX Glance' 'Uploading repaired qcow2 directly from origin VM to FLEX Glance'
sed -i 's/'$'''$//' /tmp/ospc2flex_flex.sh  # Strip Windows CR from openrc
source /tmp/ospc2flex_flex.sh
log '  [INFO] Authenticating to FLEX (via sourced OpenRC)...'
if ! openstack token issue >/dev/null 2>&1; then
  stage_fail 5 "FLEX authentication failed. Cannot connect to FLEX Glance. Please check credentials."
fi
log '  [OK] OpenRC sourced and authentication verified'

# Use native openstack CLI for image upload — correctly handles v3 Fernet tokens
# The CLI auto-discovers the correct Glance endpoint from the service catalog
log "  [INFO] Uploading image via openstack CLI..."
UPLOAD_SIZE=$(stat -c%s "$repaired_path" 2>/dev/null || echo 0)
log "  [INFO] Image: $repaired_path (${UPLOAD_SIZE} bytes)"
IMG_ID=$(openstack image create \
  --disk-format qcow2 \
  --container-format bare \
  --file "$repaired_path" \
  --property visibility=private \
  --format value -c id \
  "ospc2flex-centos7-20260416" 2>&1 || true)
if echo "$IMG_ID" | grep -qiE 'error|failed|traceback|exception|unauthorized'; then
  stage_fail 5 "Image upload failed: $IMG_ID"
fi
if [ -z "$IMG_ID" ]; then
  stage_fail 5 'Image upload produced no image ID — check FLEX credentials and region'
fi
log "  [OK] Upload complete — Image ID: $IMG_ID"
stage_done 5

# ── STAGE 5.5: Clean Workspace ───────────────────────────────────────────────
stage_start '5.5' 'Clean Workspace' 'Removing successfully uploaded artifact from origin VM'
rm -f "$repaired_path" "$converted_path" "$img_path" 2>/dev/null || true
log '  [OK] Workspace pruned'
stage_done '5.5'

echo "MIGRATION_COMPLETE=true"
echo "FLEX_IMAGE_ID=$IMG_ID"
exit 0

