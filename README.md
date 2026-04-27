# CloudJumper / OSPC2FLEX

Move the customers who trusted Rackspace OpenStack Private Cloud into the next Rackspace cloud chapter: FLEX.

CloudJumper is a migration cockpit for discovering OSPC estates, translating their topology, moving their VM images, repairing old guest operating systems, and validating workloads on Rackspace FLEX. It is built for the practical middle of migration work: the place where APIs, snapshots, old kernels, customer timelines, and operator judgment all meet.

The full operator manual lives in `README.long.md`.

## What

CloudJumper is a browser-based control room for OSPC to FLEX migration.

It brings together:

- OSPC and FLEX discovery.
- Customer migration tracking.
- Topology import, design, validation, deploy, and rollback.
- VM image migration through a jumphost using NBD, Glance, Cloud Files, and `qemu-img`.
- Linux offline repair for Ubuntu, Debian, CentOS, RHEL, Rocky, and AlmaLinux.
- Windows offline VirtIO repair and snapshot-based migration.
- Batch job telemetry in the MBUX/Apollo dashboard.
- SSH/UAT verification, reports, and operator audio alerts.

## Why

OSPC was a powerful chapter in Rackspace cloud history. It gave customers dedicated OpenStack environments, real control, familiar APIs, and the confidence of a managed private cloud.

But platforms age. Images accumulate assumptions. Networks drift. Kernels, initramfs, cloud-init, virtio drivers, static routes, bootloaders, and application dependencies all remember the cloud they came from.

FLEX is the forward path: modern Rackspace cloud capacity, newer operating models, cleaner automation targets, and a better place for customers to keep building. The challenge is not simply copying servers. The challenge is carrying customer trust forward without losing the details that make their workloads boot, connect, and serve traffic.

CloudJumper exists for that crossing.

## So What

Migration should not feel like a blind leap from one console to another.

CloudJumper turns migration into an observable workflow:

- See the source estate before you move it.
- Map the target before you build it.
- Generate scripts instead of hand-copying commands.
- Repair guest images before first boot instead of debugging every failure live.
- Track every VM, image, upload, and jumphost signal from one place.
- Keep rollback and verification close to the work.

The result is fewer mystery failures, faster test boots, cleaner customer updates, and a migration path that feels engineered instead of improvised.

## For Who

CloudJumper is for:

- Rackspace migration engineers moving customer workloads from OSPC to FLEX.
- Cloud operators who need repeatable VM, image, topology, and data migration workflows.
- Architects planning customer modernization paths.
- Support teams validating migrated servers after boot.
- Anyone who has stared at a migrated CentOS 7 image with no network and thought: there has to be a better ritual for this.

## Where

Run the dashboard from a Linux or WSL2 operator workstation:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements/requirements.txt
python3 workflow_dashboard/app.py
```

Then open the Flask URL printed in the terminal.

Run heavy image work on a same-region migration jumphost with enough block storage mounted at:

```text
/mnt/migration/ospc2flex_image
```

Important entry points:

| Path | Purpose |
|---|---|
| `workflow_dashboard/app.py` | Flask dashboard backend and APIs |
| `workflow_dashboard/templates/image_migrator.html` | Main VM/image migration console |
| `ospc2Flex-Image-migtool/ospc2flex_image_migrator.py` | Standalone image migration pipeline |
| `ospc2Flex-Image-migtool/ospc2flex_offline_repair.sh` | Linux offline repair engine |
| `ospc2Flex-Image-migtool/ospc2flex_windows_migrate.sh` | Windows migration workflow |
| `ospc2Flex-Image-migtool/ospc2flex_windows_repair.sh` | Windows VirtIO repair engine |
| `ospc2Flex-Image-migtool/setup_jumphost.sh` | Jumphost bootstrap |
| `README.long.md` | Full operator reference |

## What Now

1. Install the Python and system dependencies.
2. Start `workflow_dashboard/app.py`.
3. Enter OSPC, FLEX, and jumphost credentials in the dashboard.
4. Run discovery and review the generated CSVs.
5. Build or import topology.
6. Prepare the jumphost.
7. Start VM/image migration jobs.
8. Watch MBUX/Apollo for progress, errors, uploads, and storage health.
9. Boot FLEX test instances and run SSH/UAT checks.
10. Cut over only when the customer workload is visible, verified, and ready.

Jumphost package baseline:

```bash
sudo apt-get update
sudo apt-get install -y \
  qemu-utils gdisk e2fsprogs xfsprogs parted \
  ntfs-3g chntpw libhivex-bin wget curl jq \
  mysql-client pulseaudio-utils mpg123 ffmpeg
```

## The Promise

OSPC carried important workloads for a long time. FLEX is where those workloads can keep moving.

CloudJumper is the bridge: part scanner, part repair bench, part launch console, part field notebook. It does not replace engineering judgment. It gives that judgment a cockpit, a checklist, and a live instrument panel.

Move carefully. Verify everything. Bring the customer forward.
