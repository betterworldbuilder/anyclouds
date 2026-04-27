# CloudJumper / OSPC2FLEX Full Operator README

CloudJumper, also called OSPC2FLEX in the scripts, is a browser-based migration cockpit for moving Rackspace OpenStack Private Cloud workloads to Rackspace FLEX. It combines discovery, topology planning, script generation, VM image migration, offline guest repair, batch job tracking, verification, and operator telemetry into one Flask dashboard.

This is the long-form README. The short project entry point is `README.md`.

## Current Feature Set

- Flask dashboard with tabbed workflows for discovery, topology design, image migration, REHOST migration, validation, and reports.
- Customer migration tracker backed by CSV plus browser `localStorage`.
- OSPC and FLEX inventory discovery for servers, images, volumes, networks, security groups, load balancers, floating IPs, and flavor mapping.
- Topology canvas that can import live OpenStack inventory or parse existing `openstack` CLI scripts.
- Topology validation, plan generation, deploy, async deploy status, stop, rollback, and latest rollback lookup.
- Tenant deployment script generator with result CSV and resource-map CSV outputs.
- Data migration script generator for app and database replication flows.
- Kubernetes migration support through manual runbooks, deploy helpers, active log parsing, and migration report endpoints.
- Private snapshot scanner with migratable/filter state, manifest generation, and selected snapshot download flow.
- VM image migration through jumphost-based NBD workers and the standalone image migration CLI.
- Linux offline repair using `qemu-nbd` with OS-specific boot, fstab, initramfs, cloud-init, network, SSH, and virtio fixes.
- Windows migration through OSPC Glance snapshots, qcow2 conversion, and offline VirtIO driver injection.
- Cloud Files / Glance bridge helpers for cases where direct Glance image download or upload is unreliable.
- MBUX / Apollo dashboard for jumphost health, VM jobs, Glance image jobs, per-job progress, kill/stop controls, and storage telemetry.
- SSH and ping verification helpers for migrated instances.
- Jarvis-style browser speech alerts plus local `announce.py` TTS and `voice` Whisper transcription helpers.
- Guardrails in `.gitignore` for OpenRC, openrac typo variants, credentials, tokens, secrets, env files, SSH keys, credential CSVs, terminal dumps, logs, and generated cloudfiles output.

## Repository Map

| Path | Purpose |
|---|---|
| `workflow_dashboard/app.py` | Main Flask backend, API routes, SSE streams, script orchestration |
| `workflow_dashboard/templates/image_migrator.html` | Main VM/image migration dashboard and MBUX UI |
| `workflow_dashboard/templates/combined.html` | Unified shell for dashboard tabs |
| `workflow_dashboard/static/` | Dashboard assets, audio, background images, generated media |
| `requirements/requirements.txt` | Python requirements plus system package notes |
| `README.md` | Concise README |
| `README.long.md` | Full operator README |
| `ospc2Flex-Image-migtool/` | Image migration, offline repair, Windows repair, jumphost setup tools |
| `ospc2Flex-Image-conversion/` | Older Glance image migration helper |
| `ospc2flex-k8-migration/` | Kubernetes migration tooling |
| `uploads/` | Uploaded/generated migration scripts |
| `inventory-csv/` | Discovery and dashboard inventory CSV workspace |
| `output/` | Generated reports and logs |
| `backups/` | Historical local backups, ignored by git |

## Architecture

| Layer | Technology |
|---|---|
| Backend | Python 3, Flask |
| Frontend | Vanilla HTML, CSS, JavaScript |
| Realtime logs | Server-Sent Events and streaming HTTP responses |
| Execution | Python `subprocess`, Bash workers, SSH to jumphost |
| State | CSV files, local files, in-memory job registry, browser `localStorage` |
| OpenStack | `python-openstackclient`, `python-octaviaclient`, Glance/Cinder/Nova/Neutron APIs |
| Image handling | `qemu-img`, `qemu-nbd`, Glance image import/export |
| Linux repair | Offline mount/chroot with per-OS repair profiles |
| Windows repair | Offline NTFS mount, VirtIO ISO, registry/driver injection helpers |
| Audio | Browser `speechSynthesis`, `edge-tts`, `gTTS`, Whisper |

Typical operator flow:

```text
Credentials
  -> Discovery and inventory CSVs
  -> Flavor/network/block/LB mapping
  -> Topology script generation
  -> Jumphost preparation
  -> VM/image migration jobs
  -> Offline guest repair
  -> FLEX image upload and VM boot
  -> SSH/UAT verification
  -> Cutover and rollback scripts
```

## Quick Start

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements/requirements.txt
python3 workflow_dashboard/app.py
```

Open the URL printed by Flask. The normal dashboard entry point is:

```text
http://127.0.0.1:5000/
```

Useful direct pages:

| URL | Purpose |
|---|---|
| `/` | Unified dashboard shell |
| `/run/` | Discovery/script run page |
| `/migrate/` | Migration pipeline page |
| `/designer/` | Topology designer |
| `/references/` | Reference catalogs |
| `/rehost_manual/` | Manual REHOST runbook page |
| `/image_migrator/` | VM/image migration console |
| `/dashboard/` | CSV dashboard/browser |
| `/readme` | Markdown README view |
| `/readme.html` | HTML README view |

## Local Requirements

Install Python packages:

```bash
pip install -r requirements/requirements.txt
```

Install common system packages on the operator box or jumphost:

```bash
sudo apt-get update
sudo apt-get install -y \
  qemu-utils gdisk e2fsprogs xfsprogs parted \
  ntfs-3g chntpw libhivex-bin wget curl jq \
  mysql-client pulseaudio-utils mpg123 ffmpeg
```

Install OpenStack clients if they are not already present:

```bash
pip install python-openstackclient python-octaviaclient
```

## Credentials Model

The dashboard can generate runtime OpenRC files from credential fields. Importing an OpenRC file is optional when the UI has enough values to generate one.

Credential groups:

- OSPC username, API key/password, account/project ID, and region.
- FLEX Keystone v3 auth URL, username, password, project ID, domain, and target region.
- Jumphost IP, jumphost SSH user, and private key path.
- Optional origin VM SSH user/key/password for direct disk export or password-only legacy systems.

Do not commit credential material. `.gitignore` excludes OpenRC files, `openrac` typo variants, credential CSVs, tokens, secrets, env files, private keys, terminal dumps, and generated cloudfiles work directories.

## Dashboard APIs

The Flask app exposes these main API families:

| API family | Purpose |
|---|---|
| `/api/tracker/*` | Customer tracker list, upload, manual save, active customer, stage updates, export |
| `/api/topology/*` | Load/save topology, validate, plan, import live, import script, generate, deploy, status, stop, rollback |
| `/api/run/*` | Account overview, flavor mapper, validation, dependency mapping, data migration script, deploy script, verify |
| `/api/image_migrator/*` | Image/snapshot scan, latest maps, run single image migration, stop/kill jobs |
| `/api/vm_migrator/nbd/*` | Batch NBD migration run, single run, stream logs, status, stop, kill, job control, size checks |
| `/api/dashboard/*` | CSV file listing and content view |
| `/api/stream/*` | Stream bash execution and guest repair logs |
| `/api/flex/import-sgs` | Import security groups to FLEX |
| `/api/files` and `/api/download/*` | Workspace file list and downloads |

## Stage 0: Customer Migration Tracker

The tracker keeps customer migration state in `migration_tracker_db.csv`.

Features:

- Import an XLSX/CSV backlog.
- Save manual customer rows.
- Mark active customer for downstream workflows.
- Update stage 1 fields and status.
- Export tracker state.
- Keep browser UI state in `localStorage` so the dashboard can recover after refresh.

Main backend routes:

- `GET /api/tracker/list`
- `POST /api/tracker/upload`
- `POST /api/tracker/save_manual`
- `POST /api/tracker/update_status`
- `POST /api/tracker/set_active`
- `POST /api/tracker/stage1_update`
- `GET /api/tracker/export`

## Stage 1: Discovery And Assessment

Discovery builds the CSVs that feed topology design, flavor mapping, validation, and deployment generation.

Main scripts:

| Script | Purpose |
|---|---|
| `account_overview.py` | Export Rackspace account inventory to one CSV |
| `ospcscan.py` / `ospcscan.sh` | Scan OSPC inventory and enrich server details |
| `flexscan.py` / `flexvmscan.sh` | Scan FLEX inventory and target VM state |
| `server_deep_scan.py` | Deeper per-server inspection |
| `flavor_mapper.py` | Map OSPC flavors to FLEX flavors |
| `validate_migration_inputs.py` | Validate migration CSV inputs before generation |
| `generate_app_dependency_map.py` | Build app dependency relationships from discovered data/logs |

Typical flow:

```bash
python3 account_overview.py --help
python3 flavor_mapper.py --help
python3 validate_migration_inputs.py --help
```

Dashboard flow:

```text
Open dashboard
  -> enter/import OSPC credentials
  -> run account overview/discovery
  -> review inventory CSVs
  -> generate flavor, block, LB, and dependency mappings
  -> validate mappings before generating deploy scripts
```

## Stage 2: Topology Designer And REHOST Infra Clone

The topology designer supports both live import and script import.

Capabilities:

- Import live topology from OpenStack APIs.
- Import existing Bash/OpenStack scripts and infer networks, subnets, routers, servers, ports, security groups, volumes, and load balancer links.
- Validate graph references before deployment.
- Generate a deploy plan.
- Generate OpenStack CLI deploy scripts.
- Run deploy scripts asynchronously with browser-visible logs.
- Stop running deploy jobs.
- Generate rollback and execute rollback safely.
- Show LB and block-map edges for topology context.

Main routes:

- `GET /api/topology/list`
- `GET /api/topology/openrc-files`
- `GET /api/topology/load`
- `POST /api/topology/save`
- `POST /api/topology/validate`
- `POST /api/topology/plan`
- `POST /api/topology/import-live`
- `POST /api/topology/import-script`
- `POST /api/topology/generate-script`
- `POST /api/topology/deploy-async`
- `GET /api/topology/deploy-status`
- `POST /api/topology/stop-deploy`
- `GET /api/topology/latest-rollback-name`
- `POST /api/topology/rollback`
- `POST /api/topology/deploy`

Generated deployment examples in this repo:

| Script | Purpose |
|---|---|
| `1342314_tenant_deploy.sh` | Create FLEX tenant resources, servers, volumes, LB resources, and write result/resource maps |
| `1342314_tenant_deploy_rollback.sh` | Delete generated resources with confirmation guard |
| `1342314_topology_deploy_20260405_172854.sh` | Historical generated topology deploy script |

Deployment outputs:

- `*_tenant_deploy_results.csv`
- `*_tenant_deploy_resource_map.csv`
- `*_tenant_deploy_unresolved.csv`
- `*_validation_report.csv`

## Stage 3: VM Image Migration

There are two related migration paths:

1. Dashboard batch workers through `/api/vm_migrator/nbd/*`.
2. Standalone bridge CLI: `ospc2Flex-Image-migtool/ospc2flex_image_migrator.py`.

### Dashboard Batch Worker Flow

The image migrator UI can stage worker scripts on a jumphost, start multiple jobs, stream logs, poll job status, and stop/kill individual workers.

Main routes:

- `POST /api/vm_migrator/nbd/run`
- `POST /api/vm_migrator/nbd/run_single`
- `GET /api/vm_migrator/nbd/stream`
- `GET /api/vm_migrator/nbd/status`
- `POST /api/vm_migrator/nbd/stop`
- `POST /api/vm_migrator/nbd/kill_one`
- `POST /api/vm_migrator/nbd/job_control`
- `POST /api/vm_migrator/nbd/sizes`
- `GET /api/vm_migrator/global_jobs`

The status endpoint normalizes VM labels and merges:

- live jumphost worker state,
- local UI job state,
- log-only jobs,
- sentinel files from completed image jobs,
- Glance upload jobs.

This powers the MBUX/Apollo tracker in `workflow_dashboard/templates/image_migrator.html`.

### Standalone Image Migrator Flow

Main script:

```bash
python3 ospc2Flex-Image-migtool/ospc2flex_image_migrator.py --help
```

Core stages:

```text
OSPC VM
  -> create snapshot or stream disk directly
  -> export/download image
  -> inspect with qemu-img
  -> convert to qcow2/raw
  -> offline guest repair
  -> upload to FLEX Glance
  -> optional boot-test VM
  -> optional post-boot guest repair and validation
```

Supported acquisition modes:

| Mode | Options | Use case |
|---|---|---|
| Snapshot/offload | default | Standard OSPC Glance snapshot export/download |
| Remote export | `--remote-export` | Run export from a remote processing host |
| Direct export | `--direct-export --origin-vm-ip ...` | Stream `/dev/vda` from a source VM over SSH |
| Cloud Files fallback | default unless disabled | Work around Glance download/upload failures |

Common command:

```bash
python3 ospc2Flex-Image-migtool/ospc2flex_image_migrator.py \
  --ospc-openrc "$OSPC_OPENRC" \
  --flex-openrc "$FLEX_OPENRC" \
  --server-name "$SOURCE_SERVER_NAME" \
  --boot-test-vm \
  --flex-flavor "$FLEX_FLAVOR" \
  --flex-network-id "$FLEX_NETWORK_ID" \
  --flex-key-name "$FLEX_KEY_NAME" \
  --repair-guest \
  --ssh-key-path "$SSH_KEY_PATH" \
  --fix-fstab \
  --fix-netplan
```

Useful options:

| Option | Purpose |
|---|---|
| `--target-format qcow2|raw` | Output image format |
| `--cleanup-snapshot` | Delete temporary OSPC snapshot after export |
| `--boot-test-vm` | Boot a FLEX test VM from the imported image |
| `--auto-floating-ip` | Allocate/associate a floating IP |
| `--repair-guest` | Run online guest repair after boot |
| `--offline-repair-method custom_os|generic` | Choose OS-profile repair or generic repair script |
| `--no-cloud-files-fallback` | Disable Cloud Files fallback path |
| `--windows-admin-password` | Enable Windows post-boot verification where supported |

## Linux Offline Repair

Main script:

```bash
sudo bash ospc2Flex-Image-migtool/ospc2flex_offline_repair.sh \
  --qcow2 /path/to/image.qcow2 \
  --os-type ubuntu22 \
  --force
```

What it does:

- Loads/connects `qemu-nbd`.
- Finds root and boot partitions.
- Runs filesystem checks for ext and XFS where appropriate.
- Mounts the guest image safely.
- Detects OS from `/etc/os-release` or uses `--os-type`.
- Fixes `/etc/fstab` root and boot references.
- Rebuilds initramfs/dracut and grub where supported.
- Ensures virtio block/network drivers are present.
- Fixes cloud-init/network config for FLEX NIC naming.
- Repairs RHEL-family ifcfg/NetworkManager/network.service combinations.
- Optionally preserves password SSH auth for legacy guests.
- Writes repair sentinels to avoid unnecessary repeated repairs.

Supported OS profiles include:

| Family | Versions/profiles |
|---|---|
| Ubuntu | 20, 22, 24 |
| Debian | 10, 11, 12 |
| AlmaLinux | 8, 9 |
| Rocky Linux | 8, 9 |
| CentOS | 7, 8, 9, Stream 9 |
| RHEL | 7, 8, 9 |

CentOS 7 uses the legacy repair profile: DHCP `ifcfg-eth0`, `network.service`, masked NetworkManager where needed, dracut rebuild, grub2 config rebuild, virtio modules, and cloud-init network disablement.

## Windows Migration And Repair

Windows guests use snapshot export instead of Linux NBD/direct SSH disk streaming.

Main scripts:

| Script | Purpose |
|---|---|
| `ospc2Flex-Image-migtool/ospc2flex_windows_migrate.sh` | Snapshot, download, repair, upload, and boot Windows VM |
| `ospc2Flex-Image-migtool/ospc2flex_windows_repair.sh` | Offline VirtIO driver injection for Windows qcow2 |
| `fix_windows_migration.py` | Local helper for Windows migration fixes |

Windows migration flow:

```text
OSPC Windows VM
  -> Glance snapshot
  -> download image to jumphost
  -> convert/normalize qcow2
  -> mount NTFS offline
  -> download/cache VirtIO ISO
  -> inject viostor/vioscsi/netkvm drivers
  -> patch registry/driver store where possible
  -> upload FLEX image
  -> boot FLEX test VM
```

Example:

```bash
bash ospc2Flex-Image-migtool/ospc2flex_windows_migrate.sh \
  --server-name "win2019websql2019" \
  --server-ip "104.130.26.6" \
  --label "ospc2flex-win2019" \
  --flavor "gp.5.4.4" \
  --network "tenant-net" \
  --keypair "laptopubuntu24"
```

Repair-only example:

```bash
sudo bash ospc2Flex-Image-migtool/ospc2flex_windows_repair.sh \
  --qcow2 /mnt/migration/ospc2flex_image/win2019.qcow2 \
  --nbd-dev /dev/nbd5 \
  --force
```

## Glance And Cloud Files Bridge

Main script:

```bash
bash ospc2Flex-Image-migtool/ospc2flex_glance_bridge.sh
```

The bridge discovers Glance endpoints, normalizes Rackspace image API URLs, checks host resolution, and helps move image data through Cloud Files when direct Glance transfer is unreliable.

Related probe scripts:

| Script | Purpose |
|---|---|
| `run_jh_glance_probe.sh` | Test image file endpoint access from jumphost |
| `run_jh_task_api_test.sh` | Test raw Glance task API export call |
| `run_jh_task_create_test.sh` | Test OpenStack/glance task creation commands |
| `tmp_glance_probe.sh` | Temporary local Glance probe helper |

## Jumphost Workflow

The jumphost does the heavy image work. It should be in the same region as the source/target image services where possible.

Bootstrap:

```bash
sudo bash ospc2Flex-Image-migtool/setup_jumphost.sh
```

Prepare a large attached volume:

```bash
JUMP_IP=104.239.169.89 DEV=/dev/xvdb ./setup_jumphost_volume.sh
```

Default workspace:

```text
/mnt/migration/ospc2flex_image
```

Useful jumphost ops scripts:

| Script | Purpose |
|---|---|
| `check_jumphost.sh` | Show migration processes, disk, staged files, NBD devices, latest logs |
| `monitor_jumphost_nbd_jobs.sh` | Poll selected worker jobs and print progress |
| `poll.sh` | Poll status/logs |
| `copyserver.sh` / `copyserv.sh` | Copy server-side files |
| `remote_push_home_from_origin.sh` | Push files from origin VM home where needed |
| `run_origin_rsync_interactive.sh` | Interactive rsync from origin systems |

## MBUX / Apollo Job Tracker

The MBUX panel in the image migrator page is the operator console for active work.

It displays:

- jumphost IP and core specs,
- CPU, memory, volume, and uplink telemetry,
- engine live/load status,
- VM jobs,
- Glance image jobs,
- progress, speed, ETA, and storage usage,
- per-job state from live workers, logs, and sentinels,
- stop/restart/tracker controls.

The tracker combines backend `/api/vm_migrator/nbd/status`, local dashboard state, and generated job artifacts so completed or log-only jobs do not disappear from the console.

## Data Migration Workflows

The data migration generator creates sync, cutover, and rollback scripts from CSV mapping inputs.

Main scripts:

| Script | Purpose |
|---|---|
| `generate_data_migration_script.py` | Generate migration scripts from source/target CSV data |
| `*_data_migration_sync.sh` | Sync application/database data |
| `*_data_migration_cutover.sh` | Final sync and service cutover |
| `*_data_migration_rollback.sh` | Roll back to source-side service state |
| `generate_app_dependency_map.py` | Build application dependency map |

Examples in repo:

- `111_data_migration_sync.sh`
- `111_data_migration_cutover.sh`
- `111_data_migration_rollback.sh`
- `custom_data_targets_data_migration_sync.sh`
- `ab_reuse_lb_1342314_data_migration_sync.sh`

Dashboard route:

```text
POST /api/run/generate-data-migration
```

## Kubernetes / Genestack Migration Support

The dashboard includes Kubernetes-oriented helpers and routes for manual and automated migration activity.

Supported patterns:

- manual runbook execution,
- Genestack/Kubespray/OpenCenter-style deployment helpers,
- OSPC Kubernetes to FLEX Magnum staged migration,
- active log parsing,
- generated migration report view.

Main routes:

- `GET /api/data/runbook-ips`
- `POST /api/run/execute-manual-cmd`
- `POST /api/run/k8s-deploy`
- `GET /api/run/migration-report`
- `GET /api/run/parse-active-logs`

Related path:

```text
ospc2flex-k8-migration/
```

## Verification And Post-Deploy

Main scripts:

| Script | Purpose |
|---|---|
| `verify_post_deploy.py` | Validate generated FLEX resources after deploy |
| `test_migrated_vms.sh` | Ping and SSH verification for known migrated FLEX VMs |
| `test_all_ssh.py` | Concurrent ping/SSH checks against target list |
| `test_flex_vms.sh` | FLEX VM test helper |
| `vmbootscan.sh` | Boot state scan helper |
| `ping_ssh_ips.py` | Simple ping/SSH IP checker |
| `get_console.sh` | Pull console output from instances |

Common SSH users:

| OS | Primary user | Fallback |
|---|---|---|
| Ubuntu | `ubuntu` | `root` |
| Debian | `debian` or `root` | `root` |
| CentOS 7 | `centos` | `root` |
| AlmaLinux | `almalinux` | `root` |
| Rocky Linux | `cloud-user` | `root` |
| RHEL 6 | `root` | `root` |

Legacy RHEL 6 SSH often needs old algorithms:

```bash
ssh -i ~/.ssh/id_rsa \
  -o HostKeyAlgorithms=+ssh-dss \
  -o PubkeyAcceptedKeyTypes=+ssh-rsa \
  -o StrictHostKeyChecking=no \
  root@FLOATING_IP
```

## Reports And CSV Dashboard

The repo contains CSV and XLS/XLSX outputs used by the dashboard:

- account overview CSVs,
- flavor maps,
- block maps,
- LB maps,
- topology deploy plans,
- tenant deploy results,
- validation reports,
- TCO reports,
- DB and VM migration matrices.

The CSV dashboard endpoints are:

- `GET /api/dashboard/csv-files`
- `GET /api/dashboard/csv-content/<filename>`

## Audio And Voice Helpers

Browser alerts use `speechSynthesis` inside the dashboard.

Local TTS:

```bash
python3 announce.py "Migration complete"
```

`announce.py` uses `edge-tts` first and falls back to `gTTS`. Playback tries `paplay`, `mpg123`, then `ffplay`.

Local microphone transcription:

```bash
./voice 10
```

The `voice` helper records with `parec` and transcribes with Whisper. Set model with:

```bash
WHISPER_MODEL=small ./voice 10
```

## Security Notes

- Never commit OpenRC files, token dumps, credential exports, private keys, or generated terminal captures.
- Runtime credential files should live in temporary paths such as `/tmp` or the jumphost workspace and should be deleted after use.
- The `.gitignore` intentionally blocks broad credential patterns, including `*credential*`, `*secret*`, `*token*`, `*openrc*`, `*openrac*`, `.env`, private key names, and credential CSVs.
- Be careful with generated scripts: they may contain customer topology names, IP addresses, keypair names, and environment-specific references.
- `dashboard.log`, `migration_log.txt`, backup files, caches, and generated cloudfiles directories are ignored.

## Troubleshooting

Jumphost has no visible jobs:

```bash
bash check_jumphost.sh
bash monitor_jumphost_nbd_jobs.sh --once
```

NBD repair is stuck:

```bash
ssh ubuntu@JUMPHOST_IP "ps fux | grep -E 'qemu-nbd|mig_worker|ospc2flex' | grep -v grep"
ssh ubuntu@JUMPHOST_IP "lsblk | grep nbd || true"
```

Glance download/upload fails:

```bash
bash run_jh_glance_probe.sh JUMPHOST_IP ubuntu ~/.ssh/id_rsa
bash run_jh_task_api_test.sh JUMPHOST_IP ubuntu ~/.ssh/id_rsa
```

CentOS/RHEL image boots but has no network:

- confirm the repair log says the CentOS/RHEL profile was used,
- confirm `ifcfg-eth0` or NetworkManager config was written,
- confirm cloud-init network config was disabled,
- confirm `virtio_net` is in initramfs,
- inspect console output with `get_console.sh`.

Windows image does not boot:

- rerun Windows repair with `--force`,
- confirm VirtIO ISO was downloaded,
- check that `viostor`, `vioscsi`, and `netkvm` were injected,
- verify the FLEX flavor uses compatible virtualization/storage settings.

## Current Development Notes

- The dashboard is intentionally stateful. Browser `localStorage`, CSV files, jumphost logs, and sentinel files all contribute to the operator view.
- Some historical generated scripts and reports are kept as working examples.
- The root `README.md` is concise; this file is the full operator reference.
