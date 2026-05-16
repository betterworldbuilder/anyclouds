#!/usr/bin/env bash
# jumphost_provision.sh
# -----------------------------------------------------------------------------
# Fully provisions a fresh Ubuntu 22.04/24.04 Rackspace jumphost for the
# OSPC→Flex image migration pipeline.
#
# Run from the dashboard host (WSL/Linux) against the NEW jumphost IP:
#
#   JUMP_IP=1.2.3.4 ./jumphost_provision.sh
#   JUMP_IP=1.2.3.4 SKIP_VOLUME=1 ./jumphost_provision.sh   # skip disk format
#   JUMP_IP=1.2.3.4 SKIP_VIRTIO=1 ./jumphost_provision.sh   # skip virtio copy
#
# What this does (in order):
#   1. Block-storage volume format + mount at /mnt/migration (XFS, 500 GB)
#   2. apt package install (qemu, guestfs, hivex, openstack CLI, etc.)
#   3. Passwordless sudo for nbd/guestfs/ntfs tools
#   4. Directory scaffold under /mnt/migration
#   5. virtio-win.iso + virtio-win-gt-x64.msi → /mnt/migration/virtio/
#   6. Credential files → /mnt/migration/ospc2flex_image/creds/
#   7. All migration scripts → /tmp/   (same as push_scripts_to_jumphost.sh)
#   8. Warm libguestfs appliance kernel cache
#   9. Dry-run preflight smoke-test
# -----------------------------------------------------------------------------
set -euo pipefail

JUMP_IP="${JUMP_IP:-}"
JUMP_USER="${JUMP_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
DEV="${DEV:-/dev/xvdb}"
MNT="${MNT:-/mnt/migration}"

# Flags
SKIP_VOLUME="${SKIP_VOLUME:-0}"   # set 1 if volume already mounted
SKIP_VIRTIO="${SKIP_VIRTIO:-0}"   # set 1 if virtio already present on jump
SKIP_CREDS="${SKIP_CREDS:-0}"     # set 1 to skip cred copy (fill manually)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SCRIPTS="${SCRIPT_DIR}/ospc2Flex-Image-migtool"
LOCAL_VIRTIO_ISO="${LOCAL_VIRTIO_ISO:-$MNT/virtio/virtio-win.iso}"
LOCAL_VIRTIO_MSI="${LOCAL_VIRTIO_MSI:-$MNT/virtio/virtio-win-gt-x64.msi}"
LOCAL_OSPC_CRED="${LOCAL_OSPC_CRED:-$MNT/ospc2flex_image/creds/ospc_openrc.sh}"
LOCAL_FLEX_CRED="${LOCAL_FLEX_CRED:-$MNT/ospc2flex_image/creds/flex_openrc.sh}"

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [ -z "$JUMP_IP" ]; then
    echo "ERROR: JUMP_IP is required. Example: JUMP_IP=1.2.3.4 $0" >&2
    exit 1
fi
if [ ! -f "$SSH_KEY" ]; then
    echo "ERROR: SSH key not found: $SSH_KEY" >&2
    exit 1
fi

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o ServerAliveInterval=30)
SCP_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30)

ssh_run() { ssh "${SSH_OPTS[@]}" "${JUMP_USER}@${JUMP_IP}" "$@"; }
scp_put() { scp "${SCP_OPTS[@]}" "$1" "${JUMP_USER}@${JUMP_IP}:$2"; }

banner() { echo; echo "============================================================"; echo "  $*"; echo "============================================================"; }

banner "OSPC→Flex Jumphost Provisioner"
echo "  Target : ${JUMP_USER}@${JUMP_IP}"
echo "  Key    : $SSH_KEY"
echo "  Device : $DEV → $MNT"

# ---------------------------------------------------------------------------
# Step 1 — Block-storage volume
# ---------------------------------------------------------------------------
banner "[1/9] Block-storage volume ($DEV → $MNT)"
if [ "$SKIP_VOLUME" = "1" ]; then
    echo "  SKIP_VOLUME=1 — assuming $MNT is already mounted"
else
    JUMP_IP="$JUMP_IP" JUMP_USER="$JUMP_USER" SSH_KEY="$SSH_KEY" DEV="$DEV" MNT="$MNT" \
        bash "${SCRIPT_DIR}/setup_jumphost_volume.sh"
fi

# ---------------------------------------------------------------------------
# Step 2 — apt packages
# ---------------------------------------------------------------------------
banner "[2/9] Installing apt packages"
ssh_run bash -s <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "[apt] Updating package lists..."
sudo apt-get update -qq

PKGS=(
    # QEMU / image tools
    qemu-utils
    qemu-system-x86
    ovmf
    seabios
    # GuestFS offline filesystem repair
    libguestfs-tools
    libguestfs-xfs
    libguestfs-reiserfs
    libguestfs-hfsplus
    # Hive / registry editing
    libhivex-bin
    hivex-utils
    # NBD
    nbd-client
    nbdkit
    # NTFS / Windows filesystem
    ntfs-3g
    chntpw
    # Compression
    p7zip-full
    lzop
    xz-utils
    pigz
    pv
    # OpenStack CLI
    python3-openstackclient
    python3-pip
    python3-venv
    # Misc utilities
    jq
    curl
    wget
    rsync
    sshpass
    # Virt tools (needed by guestfs internally)
    libvirt-clients
    virtinst
)

MISSING=()
for p in "${PKGS[@]}"; do
    dpkg -l "$p" 2>/dev/null | grep -q "^ii" || MISSING+=("$p")
done

if [ "${#MISSING[@]}" -eq 0 ]; then
    echo "[apt] All packages already installed."
else
    echo "[apt] Installing: ${MISSING[*]}"
    sudo apt-get install -y "${MISSING[@]}"
    echo "[apt] Done."
fi
REMOTE

# ---------------------------------------------------------------------------
# Step 3 — Passwordless sudo for nbd / guestfs / ntfs tools
# ---------------------------------------------------------------------------
banner "[3/9] Configuring passwordless sudo"
ssh_run bash -s <<'REMOTE'
set -euo pipefail
SUDOERS_FILE="/etc/sudoers.d/ospc2flex-migration"
if [ -f "$SUDOERS_FILE" ]; then
    echo "[sudo] $SUDOERS_FILE already exists — skipping"
else
    cat <<'EOF' | sudo tee "$SUDOERS_FILE" >/dev/null
# ospc2flex migration — required by ospc2flex_windows_method_z_snapshot_existing.sh
ubuntu ALL=(ALL) NOPASSWD: /usr/bin/qemu-nbd, /usr/sbin/qemu-nbd, \
    /bin/mount, /bin/umount, \
    /usr/bin/guestmount, /usr/bin/guestunmount, \
    /usr/bin/ntfsfix, /sbin/ntfsfix, \
    /usr/sbin/ntfsfix, \
    /usr/bin/ntfs-3g, /usr/bin/udevadm, \
    /sbin/udevadm, /usr/sbin/udevadm, \
    /usr/bin/modprobe, /sbin/modprobe
EOF
    sudo chmod 440 "$SUDOERS_FILE"
    sudo visudo -cf "$SUDOERS_FILE" && echo "[sudo] sudoers file installed OK" || { echo "[sudo] ERROR: invalid sudoers — removing" >&2; sudo rm "$SUDOERS_FILE"; exit 1; }
fi
# Load NBD module now
sudo modprobe nbd max_part=16 2>/dev/null || true
# Persist nbd module across reboots
echo "nbd" | sudo tee /etc/modules-load.d/nbd.conf >/dev/null
REMOTE

# ---------------------------------------------------------------------------
# Step 4 — Directory scaffold
# ---------------------------------------------------------------------------
banner "[4/9] Creating directory structure under $MNT"
ssh_run bash -s <<REMOTE
set -euo pipefail
MNT="$MNT"
USER=\$(id -u)
GROUP=\$(id -g)
dirs=(
    "\$MNT/ospc2flex_image"
    "\$MNT/ospc2flex_image/creds"
    "\$MNT/ospc2flex_image/locks"
    "\$MNT/ospc2flex_image/cloudboot_cache"
    "\$MNT/ospc2flex_method_z"
    "\$MNT/virtio"
    "\$MNT/logs"
)
for d in "\${dirs[@]}"; do
    sudo mkdir -p "\$d"
done
sudo chown -R "\$USER:\$GROUP" "\$MNT"
echo "[dirs] Done:"
ls -la "\$MNT/"
REMOTE

# ---------------------------------------------------------------------------
# Step 5 — VirtIO ISO + MSI
# ---------------------------------------------------------------------------
banner "[5/9] Staging VirtIO drivers"
if [ "$SKIP_VIRTIO" = "1" ]; then
    echo "  SKIP_VIRTIO=1 — skipping virtio copy"
else
    REMOTE_VIRTIO_ISO="$MNT/virtio/virtio-win.iso"
    REMOTE_VIRTIO_MSI="$MNT/virtio/virtio-win-gt-x64.msi"

    if [ ! -f "$LOCAL_VIRTIO_ISO" ]; then
        echo "  WARNING: LOCAL_VIRTIO_ISO not found: $LOCAL_VIRTIO_ISO"
        echo "  Set LOCAL_VIRTIO_ISO=/path/to/virtio-win.iso or copy it manually."
        echo "  Expected remote path: $REMOTE_VIRTIO_ISO"
    else
        ISO_SIZE=$(stat -c%s "$LOCAL_VIRTIO_ISO")
        REMOTE_SIZE=$(ssh_run "stat -c%s $REMOTE_VIRTIO_ISO 2>/dev/null || echo 0" || echo 0)
        if [ "$ISO_SIZE" = "$REMOTE_SIZE" ]; then
            echo "  virtio-win.iso already present and same size — skipping"
        else
            echo "  Copying virtio-win.iso ($((ISO_SIZE/1024/1024)) MB) → ${JUMP_USER}@${JUMP_IP}:$REMOTE_VIRTIO_ISO"
            scp_put "$LOCAL_VIRTIO_ISO" "$REMOTE_VIRTIO_ISO"
        fi
    fi

    if [ ! -f "$LOCAL_VIRTIO_MSI" ]; then
        echo "  WARNING: LOCAL_VIRTIO_MSI not found: $LOCAL_VIRTIO_MSI"
    else
        MSI_SIZE=$(stat -c%s "$LOCAL_VIRTIO_MSI")
        REMOTE_MSI_SIZE=$(ssh_run "stat -c%s $REMOTE_VIRTIO_MSI 2>/dev/null || echo 0" || echo 0)
        if [ "$MSI_SIZE" = "$REMOTE_MSI_SIZE" ]; then
            echo "  virtio-win-gt-x64.msi already present — skipping"
        else
            echo "  Copying virtio-win-gt-x64.msi → $REMOTE_VIRTIO_MSI"
            scp_put "$LOCAL_VIRTIO_MSI" "$REMOTE_VIRTIO_MSI"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Step 6 — Credential files
# ---------------------------------------------------------------------------
banner "[6/9] Staging OpenStack credentials"
if [ "$SKIP_CREDS" = "1" ]; then
    echo "  SKIP_CREDS=1 — skipping. Place creds manually at:"
    echo "    $MNT/ospc2flex_image/creds/ospc_openrc.sh"
    echo "    $MNT/ospc2flex_image/creds/flex_openrc.sh"
else
    for pair in "$LOCAL_OSPC_CRED:$MNT/ospc2flex_image/creds/ospc_openrc.sh" "$LOCAL_FLEX_CRED:$MNT/ospc2flex_image/creds/flex_openrc.sh"; do
        src="${pair%%:*}"
        dst="${pair##*:}"
        if [ ! -f "$src" ]; then
            echo "  WARNING: $src not found — copy it manually to jumphost:$dst"
        else
            echo "  $src → jumphost:$dst"
            scp_put "$src" "$dst"
            ssh_run "chmod 600 $dst"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Step 7 — Migration scripts
# ---------------------------------------------------------------------------
banner "[7/9] Staging migration scripts to /tmp"
SCRIPTS=(
    ospc2flex_windows_method_z_snapshot_existing.sh
    ospc2flex_offline_repair.sh
    ospc2flex_windows_repair.sh
    ospc2flex_windows_migrate.sh
    ospc2flex_windows_method_d_capture.sh
    ospc2flex_windows_method_d_standalone.sh
    ospc2flex_windows_method_g_simple.sh
    ospc2flex_windows_method_g_simple_lib.sh
    ospc2flex_windows_method_h_local_kvm.sh
    ospc2flex_windows_v2_engine.sh
    ospc2flex_windows_firstboot.ps1
    ospc2flex_windows_v2_verify.ps1
    ospc2flex_glance_bridge.sh
)
for f in "${SCRIPTS[@]}"; do
    src="${SRC_SCRIPTS}/${f}"
    if [ ! -f "$src" ]; then
        echo "  SKIP (not found): $src"
        continue
    fi
    LOCAL_MD5=$(md5sum "$src" | awk '{print $1}')
    REMOTE_MD5=$(ssh_run "md5sum /tmp/$f 2>/dev/null | awk '{print \$1}' || echo NONE")
    if [ "$LOCAL_MD5" = "$REMOTE_MD5" ]; then
        echo "  up-to-date: $f"
    else
        echo "  uploading : $f"
        scp_put "$src" "/tmp/$f"
    fi
done

# cloudboot helper
CLOUDBOOT="${SRC_SCRIPTS}/cloudboot/wincloudbootmigrator.py"
if [ -f "$CLOUDBOOT" ]; then
    LOCAL_MD5=$(md5sum "$CLOUDBOOT" | awk '{print $1}')
    REMOTE_MD5=$(ssh_run "md5sum /tmp/wincloudbootmigrator.py 2>/dev/null | awk '{print \$1}' || echo NONE")
    if [ "$LOCAL_MD5" = "$REMOTE_MD5" ]; then
        echo "  up-to-date: wincloudbootmigrator.py"
    else
        echo "  uploading : wincloudbootmigrator.py"
        scp_put "$CLOUDBOOT" "/tmp/wincloudbootmigrator.py"
    fi
fi

ssh_run "chmod +x /tmp/ospc2flex_*.sh 2>/dev/null; chmod +x /tmp/wincloudbootmigrator.py 2>/dev/null; echo '[scripts] chmod done'"

# ---------------------------------------------------------------------------
# Step 8 — Warm libguestfs appliance cache
# ---------------------------------------------------------------------------
banner "[8/9] Warming libguestfs appliance kernel cache"
ssh_run bash -s <<'REMOTE'
set -euo pipefail
# Make the guestfs appliance readable without root
if ! sudo chmod +r /boot/vmlinuz-* 2>/dev/null; then
    echo "[guestfs] Could not chmod vmlinuz — may still work via fallback kernel"
fi
# Try warming the appliance cache (builds if first run)
if sudo -n update-guestfs-appliance >/dev/null 2>&1; then
    echo "[guestfs] appliance updated via update-guestfs-appliance"
else
    echo "[guestfs] Warming appliance via test run (first run may take 1–2 min)..."
    export LIBGUESTFS_BACKEND=direct
    timeout 120 guestfish --version >/dev/null 2>&1 && echo "[guestfs] guestfish OK" || echo "[guestfs] WARN: guestfish warmup timed out — will warm on first migration"
fi
REMOTE

# ---------------------------------------------------------------------------
# Step 9 — Dry-run preflight smoke-test
# ---------------------------------------------------------------------------
banner "[9/9] Dry-run preflight smoke-test"
REMOTE_CRED_OSPC="$MNT/ospc2flex_image/creds/ospc_openrc.sh"
REMOTE_CRED_FLEX="$MNT/ospc2flex_image/creds/flex_openrc.sh"
ssh_run bash -s <<REMOTE
set -euo pipefail
REMOTE_SCRIPT="/tmp/ospc2flex_windows_method_z_snapshot_existing.sh"
if [ ! -x "\$REMOTE_SCRIPT" ]; then
    echo "[preflight] ERROR: script not found or not executable: \$REMOTE_SCRIPT" >&2
    exit 1
fi
# Check creds exist
[ -f "$REMOTE_CRED_OSPC" ] && echo "[preflight] ospc_openrc.sh: OK" || echo "[preflight] WARN: ospc_openrc.sh missing — set SKIP_CREDS=0 or place manually"
[ -f "$REMOTE_CRED_FLEX" ] && echo "[preflight] flex_openrc.sh: OK" || echo "[preflight] WARN: flex_openrc.sh missing"
# Check virtio ISO
[ -f "$MNT/virtio/virtio-win.iso" ] && echo "[preflight] virtio-win.iso: OK" || echo "[preflight] WARN: virtio-win.iso missing at $MNT/virtio/virtio-win.iso"
# Verify key commands
for cmd in qemu-img qemu-nbd guestmount guestunmount hivexsh reged chntpw ntfs-3g ntfsfix 7z openstack jq curl rsync python3; do
    if command -v "\$cmd" >/dev/null 2>&1; then
        echo "[preflight] \$cmd: OK"
    else
        echo "[preflight] MISSING: \$cmd — check Step 2 apt install"
    fi
done
# Verify sudo for nbd
sudo -n qemu-nbd --version >/dev/null 2>&1 && echo "[preflight] sudo qemu-nbd: OK" || echo "[preflight] WARN: sudo qemu-nbd not working — check Step 3 sudoers"
echo "[preflight] Done."
REMOTE

banner "PROVISIONING COMPLETE"
echo "  ${JUMP_USER}@${JUMP_IP} is ready for OSPC→Flex migrations."
echo
echo "  Next steps if any WARNINGs above:"
echo "    - Missing creds: scp -i $SSH_KEY ospc_openrc.sh ${JUMP_USER}@${JUMP_IP}:$MNT/ospc2flex_image/creds/ospc_openrc.sh"
echo "    - Missing virtio: set LOCAL_VIRTIO_ISO=/path/to/virtio-win.iso and re-run with SKIP_VOLUME=1"
echo "    - Update dashboard: set JUMP_IP=$JUMP_IP in the dashboard jumphost field"
echo
