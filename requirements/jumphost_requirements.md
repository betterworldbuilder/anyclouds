# Jumphost Requirements — OSPC→Flex Migration Pipeline

## Base OS
- Ubuntu 22.04 LTS or 24.04 LTS (amd64)
- Passwordless sudo for the `ubuntu` user (or whichever user runs migrations)

## Block Storage
| Item | Spec |
|------|------|
| Data volume | ≥ 500 GB SSD attached at `/dev/xvdb` |
| Filesystem | XFS (`mkfs.xfs -f /dev/xvdb`) |
| Mount point | `/mnt/migration` — persistent via `/etc/fstab` |

Run `setup_jumphost_volume.sh` to format and mount automatically.

## Required apt Packages

```
# Image tools
qemu-utils              # qemu-img, qemu-nbd
qemu-system-x86         # QEMU x86 emulator (guestfs backend)
ovmf                    # UEFI firmware for QEMU
seabios                 # BIOS firmware for QEMU

# Offline filesystem repair (libguestfs)
libguestfs-tools        # guestmount, guestunmount, virt-* tools
libguestfs-xfs          # XFS support in guestfs
libguestfs-reiserfs     # ReiserFS support
libguestfs-hfsplus      # HFS+ support

# Windows registry / hive editing
libhivex-bin            # hivexsh
hivex-utils             # reged

# NTFS / Windows filesystem
ntfs-3g                 # ntfs-3g, ntfsfix
chntpw                  # chntpw, reged (offline registry editor)

# NBD (network block device)
nbd-client
nbdkit

# Compression & streaming
p7zip-full              # 7z (extract VirtIO ISO)
lzop
xz-utils
pigz
pv

# OpenStack CLI
python3-openstackclient # openstack command
python3-pip
python3-venv

# Libvirt (needed internally by guestfs)
libvirt-clients
virtinst

# Utilities
jq curl wget rsync sshpass python3
```

Install command:
```bash
sudo apt-get install -y qemu-utils qemu-system-x86 ovmf seabios \
    libguestfs-tools libguestfs-xfs libguestfs-reiserfs libguestfs-hfsplus \
    libhivex-bin hivex-utils ntfs-3g chntpw nbd-client nbdkit \
    p7zip-full lzop xz-utils pigz pv \
    python3-openstackclient python3-pip python3-venv \
    libvirt-clients virtinst \
    jq curl wget rsync sshpass python3
```

## Sudo Configuration

File: `/etc/sudoers.d/ospc2flex-migration` (mode 440)

```
ubuntu ALL=(ALL) NOPASSWD: /usr/bin/qemu-nbd, /usr/sbin/qemu-nbd, \
    /bin/mount, /bin/umount, \
    /usr/bin/guestmount, /usr/bin/guestunmount, \
    /usr/bin/ntfsfix, /sbin/ntfsfix, /usr/sbin/ntfsfix, \
    /usr/bin/ntfs-3g, /usr/bin/udevadm, \
    /sbin/udevadm, /usr/sbin/udevadm, \
    /usr/bin/modprobe, /sbin/modprobe
```

Also load NBD kernel module at boot:
```bash
echo "nbd" | sudo tee /etc/modules-load.d/nbd.conf
sudo modprobe nbd max_part=16
```

## Directory Structure

```
/mnt/migration/
├── ospc2flex_image/            # Working area for all migrations
│   ├── creds/                  # OpenStack credentials (chmod 600)
│   │   ├── ospc_openrc.sh      # OSPC source cloud credentials
│   │   └── flex_openrc.sh      # Flex target cloud credentials
│   ├── locks/                  # Per-VM lock files
│   └── cloudboot_cache/        # Cloudboot method cache
├── ospc2flex_method_z/         # SNAPWIN per-run workdirs
├── virtio/                     # VirtIO drivers (required for Windows)
│   ├── virtio-win.iso          # ≥ 754 MB — VirtIO ISO (all drivers)
│   └── virtio-win-gt-x64.msi  # VirtIO MSI installer
└── logs/                       # General log archive
```

## Migration Scripts (staged to /tmp on jumphost)

| File | Purpose |
|------|---------|
| `ospc2flex_windows_method_z_snapshot_existing.sh` | **Primary** — SNAPWIN Windows offline repair → Flex |
| `ospc2flex_windows_method_g_simple.sh` | Method G — Glance export path |
| `ospc2flex_windows_method_g_simple_lib.sh` | Method G library |
| `ospc2flex_windows_method_h_local_kvm.sh` | Method H — local KVM boot |
| `ospc2flex_windows_method_d_capture.sh` | Method D capture |
| `ospc2flex_windows_method_d_standalone.sh` | Method D standalone |
| `ospc2flex_windows_v2_engine.sh` | v2 engine |
| `ospc2flex_windows_firstboot.ps1` | Windows first-boot PowerShell |
| `ospc2flex_windows_v2_verify.ps1` | Verification PowerShell |
| `ospc2flex_glance_bridge.sh` | Glance bridge helper |
| `ospc2flex_offline_repair.sh` | Offline repair helper |
| `ospc2flex_windows_repair.sh` | Windows repair helper |
| `ospc2flex_windows_migrate.sh` | Migration wrapper |
| `wincloudbootmigrator.py` | Cloudboot Python helper |

All staged to `/tmp/` by `push_scripts_to_jumphost.sh` or `jumphost_provision.sh`.

## SSH Access

The dashboard host connects to the jumphost using:
- **Key**: `~/.ssh/id_rsa`
- **User**: `ubuntu`
- **Port**: 22 (default)

The dashboard needs SSH access to both the jumphost AND OSPC/Flex OpenStack APIs
from the jumphost's IP (check Rackspace security groups / firewall rules).

## libguestfs Appliance Cache

After package install, warm the appliance so the first migration is not slow:
```bash
sudo chmod +r /boot/vmlinuz-*
sudo update-guestfs-appliance     # or:
LIBGUESTFS_BACKEND=direct guestfish --version
```

## Environment Variables (set by dashboard at runtime)

| Variable | Default | Purpose |
|----------|---------|---------|
| `OSPC2FLEX_ARTIFACT_SEARCH_DIRS` | `/mnt/migration/ospc2flex_image` | Where to look for resume artifacts |
| `OSPC2FLEX_SNAPWIN_AUTO_RESUME` | `1` | `0` = Start Fresh, skip resume |
| `OSPC2FLEX_VIRTIO_ISO_LOCAL` | `/mnt/migration/virtio/virtio-win.iso` | VirtIO ISO path on jumphost |

## Quick Provision Command

```bash
# From dashboard host (WSL):
JUMP_IP=<new-jumphost-ip> bash jumphost_provision.sh

# If volume already mounted:
JUMP_IP=<new-jumphost-ip> SKIP_VOLUME=1 bash jumphost_provision.sh

# If virtio ISO is not local (pull from old jumphost first):
scp -i ~/.ssh/id_rsa ubuntu@104.239.169.89:/mnt/migration/virtio/virtio-win.iso /tmp/virtio-win.iso
LOCAL_VIRTIO_ISO=/tmp/virtio-win.iso JUMP_IP=<new-ip> bash jumphost_provision.sh
```

## Verification Checklist

After provisioning, confirm:

- [ ] `ssh -i ~/.ssh/id_rsa ubuntu@<NEW_IP> df -h /mnt/migration` shows ≥ 500 GB mounted
- [ ] `ssh ... ls /mnt/migration/virtio/virtio-win.iso` exists and ≥ 700 MB
- [ ] `ssh ... ls /mnt/migration/ospc2flex_image/creds/` shows both openrc files
- [ ] `ssh ... command -v qemu-img guestmount hivexsh ntfsfix 7z openstack jq` all resolve
- [ ] `ssh ... sudo -n qemu-nbd --version` exits 0
- [ ] Dashboard: enter new jumphost IP, click "Test Connection" → green
