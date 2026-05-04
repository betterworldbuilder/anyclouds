#!/usr/bin/env bash
# setup_jumphost_volume.sh
# -----------------------------------------------------------------------------
# Formats the attached Rackspace block-storage SSD on a fresh jumphost and
# mounts it at /mnt/migration so the dashboard's staging + migration scripts
# have the ~500 GB workspace they expect.
#
# Defaults target the new jumphost:
#   ip=104.130.165.124  user=ubuntu  dev=/dev/xvdb  mount=/mnt/migration  fs=xfs
# Override any of them via env vars if needed.
#
# Usage:
#   ./setup_jumphost_volume.sh                          # use defaults
#   JUMP_IP=1.2.3.4 DEV=/dev/xvdc ./setup_jumphost_volume.sh
# -----------------------------------------------------------------------------
set -euo pipefail

JUMP_IP="${JUMP_IP:-104.130.165.124}"
JUMP_USER="${JUMP_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
DEV="${DEV:-/dev/xvdb}"
MNT="${MNT:-/mnt/migration}"
FS="${FS:-xfs}"                # xfs recommended for large qcow2 files

echo "============================================================"
echo "Jumphost volume setup"
echo "  ip     : $JUMP_IP"
echo "  user   : $JUMP_USER"
echo "  key    : $SSH_KEY"
echo "  device : $DEV"
echo "  mount  : $MNT"
echo "  fs     : $FS"
echo "============================================================"

ssh_opts=(
    -i "$SSH_KEY"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=30
    -o ServerAliveInterval=30
)

ssh "${ssh_opts[@]}" "${JUMP_USER}@${JUMP_IP}" bash -s <<EOF
set -euo pipefail

DEV="$DEV"
MNT="$MNT"
FS="$FS"

echo "[1/8] Host: \$(hostname)  Kernel: \$(uname -r)"

echo "[2/8] Current block devices:"
lsblk -f

if [ ! -b "\$DEV" ]; then
    echo "[ERR] \$DEV not found. Available disks:" >&2
    lsblk -d -n -o NAME,SIZE,TYPE >&2
    exit 1
fi

# -- Safety: refuse to reformat if already mounted somewhere we didn't expect
CUR_MNT=\$(findmnt -n -o TARGET "\$DEV" 2>/dev/null || true)
if [ -n "\$CUR_MNT" ] && [ "\$CUR_MNT" != "\$MNT" ]; then
    echo "[ERR] \$DEV is already mounted at \$CUR_MNT — refusing to reformat." >&2
    exit 2
fi

echo "[3/8] Installing xfsprogs + util-linux if missing"
if ! command -v mkfs.xfs >/dev/null 2>&1; then
    sudo apt-get update -qq >/dev/null 2>&1 || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y xfsprogs util-linux parted e2fsprogs >/dev/null 2>&1
fi

echo "[4/8] Checking existing filesystem on \$DEV"
EXISTING_FS=\$(sudo blkid -s TYPE -o value "\$DEV" 2>/dev/null || true)
if [ -n "\$EXISTING_FS" ] && [ "\$EXISTING_FS" = "\$FS" ]; then
    echo "      [+] \$DEV already formatted as \$FS — skipping mkfs"
elif [ -n "\$EXISTING_FS" ]; then
    echo "      [!] \$DEV has an existing \$EXISTING_FS filesystem"
    echo "      Reformatting to \$FS in 5 s — Ctrl+C to abort..."
    sleep 5
    if [ -n "\$CUR_MNT" ]; then
        echo "      unmounting existing \$CUR_MNT"
        sudo umount "\$CUR_MNT" 2>/dev/null || true
    fi
    echo "      wiping old signatures"
    sudo wipefs -a "\$DEV"
    echo "      mkfs.\$FS \$DEV"
    sudo mkfs."\$FS" -f "\$DEV"
else
    echo "      no filesystem found — running mkfs.\$FS"
    sudo mkfs."\$FS" -f "\$DEV"
fi

echo "[5/8] Creating mount point \$MNT"
sudo mkdir -p "\$MNT"

echo "[6/8] Ensuring fstab entry"
UUID=\$(sudo blkid -s UUID -o value "\$DEV")
FSTAB_LINE="UUID=\$UUID \$MNT \$FS defaults,nofail,x-systemd.device-timeout=30 0 2"
# Remove any stale entry for this device or mount point before appending
sudo sed -i -E "/[[:space:]]\$MNT[[:space:]]/d" /etc/fstab
sudo sed -i -E "/UUID=\$UUID/d" /etc/fstab
echo "\$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null
echo "      added: \$FSTAB_LINE"

echo "[7/8] Mounting \$MNT"
sudo mount -a
sudo mkdir -p "\$MNT/ospc2flex_image"
sudo chown -R \$(id -u):\$(id -g) "\$MNT"

echo "[8/8] Verification"
df -hT "\$MNT"
mountpoint -q "\$MNT" && echo "      [+] \$MNT is a real mount point" \
                      || { echo "      [-] \$MNT is NOT mounted" >&2; exit 3; }
echo "      fstab entry:"
grep -F "\$MNT" /etc/fstab

echo "============================================================"
echo "DONE — \$MNT ready for migrations"
echo "============================================================"
EOF
