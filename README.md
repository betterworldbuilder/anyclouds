# CloudJumper / OSPC2FLEX

Browser-based migration cockpit for moving Rackspace OpenStack Private Cloud
(OSPC) workloads to Rackspace FLEX.

The full historical README has been preserved as `README.long.MD`.

## What It Does

- Discovers OSPC and FLEX inventory, images, flavors, networks, volumes, and load balancers.
- Builds migration maps from CSV inventory and target flavor/block/LB mappings.
- Migrates Linux and Windows VM images through a jumphost using NBD, Glance, `qemu-img`, and offline repair.
- Repairs migrated guest images before FLEX boot: fstab, bootloader, initramfs, virtio drivers, cloud-init, SSH, and network config.
- Boots FLEX test instances, attaches floating IPs, and streams live logs to the dashboard.
- Tracks batch VM jobs, private snapshot jobs, Glance uploads, and jumphost telemetry in the MBUX/Apollo dashboard.
- Supports Jarvis-style browser audio alerts and optional local TTS helpers.

## Main Entry Points

| Path | Purpose |
|---|---|
| `workflow_dashboard/app.py` | Flask dashboard backend and API endpoints |
| `workflow_dashboard/templates/image_migrator.html` | Main VM/image migration dashboard |
| `ospc2Flex-Image-migtool/ospc2flex_offline_repair.sh` | Linux offline guest repair engine |
| `ospc2Flex-Image-migtool/ospc2flex_image_migrator.py` | Image migration CLI pipeline |
| `ospc2Flex-Image-migtool/ospc2flex_windows_repair.sh` | Windows offline repair engine |
| `requirements/requirements.txt` | Python package requirements |

## Quick Start

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements/requirements.txt
python3 workflow_dashboard/app.py
```

Then open the dashboard URL printed by Flask.

## System Packages

The migration jumphost needs OpenStack CLI tooling plus disk/image repair tools:

```bash
sudo apt-get update
sudo apt-get install -y \
  qemu-utils gdisk e2fsprogs xfsprogs parted \
  ntfs-3g chntpw libhivex-bin wget \
  mysql-client pulseaudio-utils mpg123 ffmpeg
```

`qemu-utils` provides `qemu-img` and `qemu-nbd`. Windows repair uses `ntfs-3g`,
`chntpw`, and `libhivex-bin`. Audio helpers use `paplay`, `mpg123`, or `ffplay`.

## Credentials

The dashboard can generate runtime OpenRC files from the credential fields.
Importing an OpenRC is optional.

Required credential groups:

- OSPC username, API key/password, account/project ID, and region.
- FLEX auth URL, username, password, project ID, domain, and target region.
- Jumphost IP, SSH user, and SSH key path.

## Common SSH Users

| OS | Primary user | Fallback |
|---|---:|---:|
| Ubuntu | `ubuntu` | `root` |
| Debian | `root` or `debian` | `root` |
| CentOS 7 | `centos` | `root` |
| AlmaLinux | `almalinux` | `root` |
| Rocky Linux | `cloud-user` | `root` |
| RHEL 6 | `root` | `root` |

RHEL 6 may require legacy SSH options:

```bash
ssh -i ~/.ssh/id_rsa \
  -o HostKeyAlgorithms=+ssh-dss \
  -o PubkeyAcceptedKeyTypes=+ssh-rsa \
  -o StrictHostKeyChecking=no \
  root@FLOATING_IP
```

## Audio / Voice

The dashboard uses browser `speechSynthesis` for Jarvis-style alerts.

Optional local helper:

```bash
python3 announce.py "Migration complete"
```

`announce.py` uses `edge-tts` first and falls back to `gTTS`. The `voice` helper
records microphone audio and transcribes it with Whisper.

## Notes

- Keep large generated migration artifacts out of git unless they are intentional fixtures.
- The working dashboard is stateful through browser `localStorage` plus CSV files.
- Use same-region jumphosts where possible for faster snapshot/image transfer.
