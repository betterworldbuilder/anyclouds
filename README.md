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

## How

CloudJumper works as a full-cycle migration Mission Control. Each stage turns unknowns into artifacts: CSVs, maps, scripts, repaired images, booted test instances, verification results, and rollback paths.

| Stage | What It Does | Benefit |
|---|---|---|
| 0. Customer Tracker | Tracks customer, estate, status, notes, stage progress, and active migration context. | Keeps multiple migrations organized without losing the human thread. |
| 1. Discover | Scans OSPC and FLEX inventory: servers, images, flavors, volumes, networks, security groups, load balancers, and floating IPs. | Builds a factual source-of-truth before anyone starts changing infrastructure. |
| 2. Map | Compares source and target capacity, flavors, block storage, networks, load balancer edges, and app dependencies. | Turns "what do we have?" into "where will it land?" |
| 3. Design | Imports live topology or existing OpenStack scripts into a visual model, then validates and plans the target build. | Lets engineers see the shape of the migration before executing it. |
| 4. Generate | Produces deployment, data migration, sync, cutover, rollback, and validation scripts from the migration map. | Makes the work repeatable, reviewable, and safer than manual command assembly. |
| 5. Migrate Images | Moves Linux and Windows workloads through jumphost workers, Glance, Cloud Files, NBD, and `qemu-img`. | Converts old cloud images into FLEX-ready artifacts with live progress tracking. |
| 6. Repair | Applies offline guest repair for bootloaders, initramfs, fstab, cloud-init, virtio, SSH, and network config. | Fixes the common first-boot failures before the customer has to see them. |
| 7. Boot And Verify | Creates FLEX test instances, attaches access, checks ping/SSH, gathers host/kernel data, and streams logs. | Changes "the image uploaded" into "the workload is alive." |
| 8. Cut Over | Uses generated cutover and rollback scripts with final validation evidence. | Gives the migration a controlled finish line instead of a nervous handoff. |

The dashboard is not only a launcher. It is an evidence machine. Every scan, map, run log, repair log, manifest, and verification table becomes data that can feed the next automation layer.

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

## What Next

CloudJumper is the migration cockpit. The next step is turning its output into a durable modernization pipeline.

The vision is a Full Cycle Migration Mission Control that produces structured data for GitOps workflows:

- Discovery output becomes versioned infrastructure intent.
- Topology maps become Terraform modules and environment overlays.
- Server and repair profiles become Ansible playbooks.
- App dependency maps become deployment order, health checks, and service ownership.
- Validation reports become pull request evidence.
- Rollback scripts become tested recovery automation.
- Migration telemetry becomes optimization data for future waves.

That means CloudJumper can interconnect with platforms like OpenCenter, Genestack, Magnum, and other GitOps control planes. Instead of finishing with a one-time migration script, the customer leaves with a repeatable operating model: infrastructure saved as code, repairs encoded as playbooks, topology represented as reviewable templates, and deployment state controlled through pull requests.

From there, AI agents can help with the work that usually gets lost after migration day:

- autorepair failed boots and broken network profiles,
- recommend right-sized FLEX flavors and storage classes,
- detect drift between discovered reality and Git state,
- generate Terraform and Ansible patches from validated migration maps,
- summarize risk before each cutover,
- keep customer environments optimized as they scale.

The goal is bigger than moving VMs. It is preserving customer infrastructure as a living system: scalable, repeatable, reviewable, and ready for the next platform shift.

## The Promise

OSPC carried important workloads for a long time. FLEX is where those workloads can keep moving.

CloudJumper is the bridge: part scanner, part repair bench, part launch console, part field notebook. It does not replace engineering judgment. It gives that judgment a cockpit, a checklist, and a live instrument panel.

Move carefully. Verify everything. Bring the customer forward.
