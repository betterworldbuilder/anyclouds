# 🚀 CLOUD FLEX UPLOAD MISSION CONTROL

Any OpenStack Cloud to FLEX Migration Full Cycle Mission Control

Browser-based orbital migration cockpit for safely jumping Rackspace OpenStack Private Cloud (OSPC) workloads into the modern Rackspace FLEX atmosphere.

Move the customers who trusted Rackspace OpenStack Private Cloud into the next Rackspace cloud chapter: FLEX.

CloudJumper is a migration cockpit for discovering OSPC estates, translating their topology, moving their VM images, repairing old guest operating systems, and validating workloads on Rackspace FLEX. It is built for the practical middle of migration work: the place where APIs, snapshots, old kernels, customer timelines, and operator judgment all meet.

*(The full historical telemetry and operator manual has been restored in `README.long.MD`)*

## 🛰️ Mission Capabilities (What It Does)

CloudJumper is a browser-based control room for OSPC to FLEX migration. It brings together:

- **Deep Space Recon**: OSPC and FLEX discovery.
- **Flight Path Tracking**: Customer migration tracking.
- **Orbital Mechanics**: Topology import, design, validation, deploy, and rollback.
- **Zero-G Image Transport**: VM image migration through a jumphost using NBD, Glance, Cloud Files, and `qemu-img`.
- **In-Flight Pod Repair**: Linux offline repair (Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux) and Windows offline VirtIO repair/snapshot-based migration.
- **Mission Telemetry**: Batch job telemetry in the MBUX/Apollo dashboard.
- **Atmospheric Re-entry**: SSH/UAT verification, reports, and J.A.R.V.I.S. audio alerts.
- **Tenant IaC DR Pack**: Preflight checks, target cloud credential profile, OpenRC import, restore-plan overlays, and Git/S3 backup export for cross-region or cross-cloud restore.

## 🌌 The "Why" and "So What"

**Why:** OSPC was a powerful chapter in Rackspace cloud history. It gave customers dedicated OpenStack environments, real control, familiar APIs, and the confidence of a managed private cloud. But platforms age. Images accumulate assumptions. Networks drift. Kernels, initramfs, cloud-init, virtio drivers, static routes, bootloaders, and application dependencies all remember the cloud they came from. FLEX is the forward path: modern Rackspace cloud capacity, newer operating models, cleaner automation targets, and a better place for customers to keep building. The challenge is carrying customer trust forward without losing the details that make their workloads boot, connect, and serve traffic.

**So What:** Migration should not feel like a blind leap from one console to another. CloudJumper turns migration into an observable workflow:
- See the source estate before you move it.
- Map the target before you build it.
- Generate scripts instead of hand-copying commands.
- Repair guest images before first boot instead of debugging every failure live.
- Track every VM, image, upload, and jumphost signal from one place.
- Keep rollback and verification close to the work.

The result is fewer mystery failures, faster test boots, cleaner customer updates, and a migration path that feels engineered instead of improvised.

## 🚀 Full-Cycle Migration Phases (How)

CloudJumper works as a full-cycle migration Mission Control. Each stage turns unknowns into artifacts: CSVs, maps, scripts, repaired images, booted test instances, verification results, and rollback path

| Phase | Stage | Mission Control Function | Benefit |
|:---:|---|---|---|
| 📡 | 0. Customer Tracker | Tracks customer, estate, status, and active migration context. | Keeps multiple migrations organized without losing the human thread. |
| 🔭 | 1. Discovery | Scans OSPC and FLEX inventory: servers, images, networks, etc. | Builds a factual source-of-truth before anyone starts changing infrastructure. |
| 🗺️ | 2. Select & Execute R-Path | **Gartner 7R Governance**: Strategic selection of Retain, Retire, Rehost, Replatform, or Refactor paths. | Turns "what do we have?" into a strategic "where should it go?" decision based on business value. |
| 🧪 | 3. Validation & UAT | Creates FLEX test instances, checks connectivity, and streams logs. | Changes "the image uploaded" into "the workload is alive." |
| ✂️ | 4. Cutover | Final validation and live traffic shift using cutover scripts. | Gives the migration a controlled finish line instead of a nervous handoff. |
| 🏁 | 5. Post-Migration | Final documentation, infrastructure clean-up, and handoff. | Delivers a modernized, production-ready environment. |
| 💰 | 6. TCO / FinOps | Cost tracking and cloud optimization telemetry for the new environment. | Provides immediate visibility into cost savings and resource utilization. |
| 🛡️ | 7. IAC Backup & Restore | Automated generation of IAC backup and DR restore packs. | Ensures the new environment is protected and recoverable from day one. |
| 🚀 | 8. GitOps / OpenCenter | Integration with OpenCenter and GitOps-driven deployment models. | Moves from manual management to automated, version-controlled operations. |
| 🤖 | 9. AI OPS | Context pack generation for AI-driven predictive maintenance. | Prepares the platform for advanced automation and AI-assisted troubleshooting. |

### How narrative phases map to the Mission Control UI

The top bar uses **Customer List** (tracker) plus **Stages 1–9**: Discovery, Migration, Validation & UAT, Cutover, Post-Migration output bundle, TCO/FinOps baseline/right-size, **IAC Backup & Restore (Terraform + Ansible)**, **GitOps / OpenCenter**, and **AI OPS**. The **0–9** table above is the *full lifecycle story*; phases **3–6** (generate, rehost, image repair, Kubernetes) surface mainly inside **Stage 2 (Migration)** and its subtabs, while **7–9** align with post-migration handoff and continuous operations.

The dashboard is not only a launcher. It is an evidence machine. Every scan, map, run log, repair log, manifest, and verification table becomes data that can feed the next automation layer.

### 1. Linux VM Migration Process

`mig_worker_v4.sh` — NBD/DD direct disk read over SSH.

| Stage | What Happens | Where | Estimated Time (80 GB) |
|-------|-------------|-------|----------------------|
| **Step 1** | OSPC auth → find VM → check disk size | Jumphost → OSPC API | < 1 min |
| **Step 2** | SSH tunnel → `qemu-nbd` exposes remote disk as local NBD device | Jumphost ↔ Linux VM | < 1 min |
| **Step 3** | `dd` reads NBD device to `.img` at ~50–80 MB/s | Linux VM → Jumphost | ~20–30 min |
| **Step 4** | `qemu-img convert` raw → qcow2 | Jumphost (local) | 5–10 min |
| **Step 5** | Offline guest repair: bootloader, fstab, virtio drivers, network config | Jumphost (local) | 3–5 min |
| **Step 6** | Upload qcow2 to FLEX Glance | Jumphost → FLEX cloud | 10–20 min |
| **Step 7** | Boot VM from image | FLEX cloud (server-side) | 2–3 min |
| **Step 8** | Assign floating IP | FLEX cloud (server-side) | < 1 min |
| **TOTAL** | | | ~45–70 min |

### 2. Windows VM Migration Process

`ospc2flex_windows_migrate.sh` — SSH direct disk read via PowerShell, no agent required.

| Stage | What Happens | Where | Estimated Time (80 GB) |
|-------|-------------|-------|----------------------|
| **Step 1b** | Check SSH port 22 (public → ServiceNet fallback) → WinRM bootstrap if needed | Jumphost → Windows VM | < 1 min |
| **Step 1** | OSPC auth (curl) → Nova API find server → create Glance snapshot *(skipped if SSH reachable)* | OSPC cloud (server-side) | 10–20 min |
| **Step 2** | SSH → PowerShell disk dump → `dd` to `.img` at ~20 MB/s | Windows VM → Jumphost | ~70 min |
| **Step 3** | `qemu-img convert` raw → qcow2 | Jumphost (local) | 5–10 min |
| **Step 4** | Offline VirtIO driver injection into qcow2 | Jumphost (local) | 3–5 min |
| **Step 5** | Upload qcow2 to FLEX Glance | Jumphost → FLEX cloud | 10–20 min |
| **Step 6** | Boot VM from image | FLEX cloud (server-side) | 2–3 min |
| **Step 7** | Assign floating IP | FLEX cloud (server-side) | < 1 min |
| **TOTAL** | | | ~105–130 min |

## Current Status

| Category                        | Details                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Current Status                                                                                       |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| **Workflow Stages**             | Stage 0: Customer Migration Tracker (Backlog management)<br>Stage 1: Discovery & Assessment (OSPC/FLEX scanning & topology import)<br>Stage 2: Migration Pipeline (Shift & Lift Images, REHOST Apps/DBs, Kubernetes)<br>Stage 3: Validation & UAT (Automated cross-cloud checks & HTTP health tests)<br>Stage 4: Cutover & Handover (Traffic split, DB promotion, final sync)<br>Stage 5: Post-Migration (Stability tracking, artifact bundle generation)<br>Stage 6: TCO / FinOps<br>Stage 7: IAC Backup & Restore (Terraform + Ansible)<br>Stage 8: GitOps / OpenCenter<br>Stage 9: AI OPS | Stage 2 VM shift and lift: ready<br>Server and DB rehost: ready<br>Windows VM migration: WIP<br>Stage 3 to 5: under construction<br>Stage 6 to 9: to be validated and build |
| **Current Features (✅ Ready)**  | Single-Tab Mission Control: No CLI required, full GUI wrapper<br>Live Execution: Real-time logs streaming to browser<br>Visual Topology Designer: Drag-and-drop infra cloning<br>Offline Guest Repair: Pre-boot image patching for networks<br>Parallel Execution: Migrate multiple DBs/Servers simultaneously<br>No Database Required: Stateless backend (CSV + local browser storage)                                                                                                                                                          | **READY**                                                                                            |
| **Available Migration Methods** | Direct Shift & Lift (Images): Production Mode, External Offload, Direct Export<br><br>REHOST (Apps & Servers): Infra duplication, Full Clone, Quick Install<br><br>Database Replication: Dump & Restore, DBaaS Streaming, HA Replica<br><br>Kubernetes Migration: Genestack/Kubespray, OpenCenter (GitOps), Magnum export                                                                                                                                                                                                                        | All Shift and rehost READY<br>Windows VM migration: under Test<br>Stage 3 to 5: under construction<br>Stage 6 to 9: to be validated and build |
| **Supported OS Types**          | Ubuntu (20.04, 22.04, 24.04)<br>Debian (10, 11, 12)<br>CentOS 7<br>RedHat 6, 8<br>Rocky Linux 8 / 9<br>AlmaLinux 8 / 9<br>Windows Server 2016 / 2019                                                                                                                                                                                                                                                                                                                                                                                             | Linux VM rehost set: ready<br>Windows VM set: under Test                                             |
| **Future / Upcoming**           | Stage 6: TCO / FinOps (Right-sizing + cost summary)<br>Stage 7: IAC Backup & Restore (Terraform + Ansible)<br>Stage 8: GitOps / OpenCenter<br>Stage 9: AI OPS (optimization + autorepair recommendations using GitOps)                                                                                                                                                                                                                                                                                                                                                                          | under construction |

## 👨‍🚀 For Who

CloudJumper is for:
- **Rackspace Migration Engineers** moving customer workloads from OSPC to FLEX.
- **Cloud Operators** who need repeatable VM, image, topology, and data migration workflows.
- **Architects** planning customer modernization paths.
- **Support Teams** validating migrated servers after boot.
- Anyone who has stared at a migrated CentOS 7 image with no network and thought: *there has to be a better ritual for this.*

## 📡 Primary Control Modules (Where)

Run the dashboard from a Linux or WSL2 operator workstation. Run heavy image work on a same-region migration jumphost with enough block storage mounted at `/mnt/migration/ospc2flex_image`.

| Module Path | Mission Purpose |
|---|---|
| `workflow_dashboard/app.py` | Flask dashboard backend and API endpoints |
| `workflow_dashboard/templates/image_migrator.html` | Main VM/image migration console |
| `ospc2Flex-Image-migtool/ospc2flex_image_migrator.py` | Standalone image migration pipeline |
| `ospc2Flex-Image-migtool/ospc2flex_offline_repair.sh` | Linux offline repair engine |
| `ospc2Flex-Image-migtool/ospc2flex_windows_migrate.sh` | Windows migration workflow |
| `ospc2Flex-Image-migtool/ospc2flex_windows_repair.sh` | Windows VirtIO repair engine |
| `ospc2Flex-Image-migtool/setup_jumphost.sh` | Jumphost bootstrap |

## 🛠️ Easy Install + Launch

### Fast path (recommended)

```bash
git clone <your-repo-url> cloudjumper
cd cloudjumper
chmod +x ./letsmove.sh
./letsmove.sh
```

This script handles dependency install, syntax check, app startup, and opens the dashboard at:

`https://127.0.0.1:5002`

Logs are written to:

`./dashboard.log`

### What `./letsmove.sh` does

- Cleans old app processes and frees conflicting ports.
- Installs Python requirements from `requirements/requirements.txt`.
- Validates `workflow_dashboard/app.py` syntax before launch.
- Starts the Flask dashboard and waits for health.
- Opens the dashboard URL automatically when possible.

### Manual fallback (if needed)

```bash
pip3 install -r requirements/requirements.txt
python3 workflow_dashboard/app.py
```

**Jumphost Outfitting (System Packages):**
```bash
sudo apt-get update
sudo apt-get install -y \
  qemu-utils gdisk e2fsprogs xfsprogs parted \
  ntfs-3g chntpw libhivex-bin wget curl jq \
  mysql-client pulseaudio-utils mpg123 ffmpeg
```

## 🔭 What Next: The GitOps Horizon

CloudJumper is the migration cockpit. The next step is turning its output into a durable modernization pipeline.

The vision is a **Full Cycle Migration Mission Control** that produces structured data for GitOps workflows:
- Discovery output becomes versioned infrastructure intent.
- Topology maps become Terraform modules and environment overlays.
- Server and repair profiles become Ansible playbooks.
- App dependency maps become deployment order, health checks, and service ownership.
- Validation reports become pull request evidence.
- Rollback scripts become tested recovery automation.
- Migration telemetry becomes optimization data for future waves.
- Tenant IaC DR outputs become restore-ready overlays for another FLEX region or another OpenStack cloud.

The new handoff path is:

```text
Stage 5: Migration Output Bundle
  migration_manifest.json
  discovery-output/
  stage2-migration-output/
  terraform.tfvars.json
  ansible_inventory.ini
  repaired_image_metadata.json
  boot_test_results.json
  dependency_graph.json
  uat-input/
        |
        +--> Stage 6: TCO / FinOps
        |       OSPC baseline cost
        |       FLEX projected run-rate
        |       right-sizing candidates
        |       executive TCO report
        |
        +--> Stage 7: IAC Backup & Restore (Terraform + Ansible)
        |       Terraform-first tenant restore pack
        |       target cloud profile + OpenRC import
        |       region mapping and backup policy
        |       same-region / cross-region DR runbooks
        |       Git/S3 backup export and GitOps restore hooks
        |       optional OpenCenter-oriented restore prep (Option B)
        |
        +--> Stage 8: GitOps / OpenCenter
        +--> Stage 9: AI OPS
                private AI context pack
                autorepair plans
                risk and right-sizing recommendations
                Terraform/Ansible/DR patch suggestions
```

UAT does not need a separate disconnected artifact. It reuses the Migration Output Bundle through `uat-input/`, and that UAT view points back to `discovery-output/` and `stage2-migration-output/` so testers can validate what was discovered, what migrated, what was repaired, and what evidence exists before cutover.

That means CloudJumper can interconnect with FinOps reporting, **GitOps** remotes, and other control planes. TCO / FinOps turns the migration into financial evidence: source baseline, target run-rate, right-sizing candidates, and executive reporting. **IAC DR Backup and Restore** is the repeatable customer handoff layer: Terraform-first desired state, region mapping, backup policy, tested restore runbooks, and optional GitOps/OpenCenter-oriented restore prep when you use Option B in that stage.

AI OPS becomes the private intelligence layer over the whole chain after GitOps/OpenCenter reconciliation. It reads the CloudJumper output bundle plus IAC DR outputs (and optional bundle slices such as `opencenter/` when generated), then produces risk scores, autorepair plans, right-sizing recommendations, runbook improvements, and infrastructure patch suggestions without losing the customer-specific context.

Instead of finishing with a one-time migration script, the customer leaves with a repeatable operating model: infrastructure saved as code, repairs encoded as playbooks, topology represented as reviewable templates, and deployment state controlled through pull requests.

From there, AI agents can help with the work that usually gets lost after migration day: autorepair failed boots, recommend right-sized FLEX flavors, generate Terraform patches from validated migration maps, summarize risk before each cutover, and keep customer environments optimized as they scale.

### 🌟 The Promise

OSPC carried important workloads for a long time. FLEX is where those workloads can keep moving.

CloudJumper is the bridge: part scanner, part repair bench, part launch console, part field notebook. It does not replace engineering judgment. It gives that judgment a cockpit, a checklist, and a live instrument panel.

**Move carefully. Verify everything. Bring the customer forward.**

## Details for the Nerds

Need the full operator notes, workflow history, script map, and deeper telemetry? Read the extended mission manual: [README.long.MD](README.long.MD).

Made with Love by Dzoan.nguyen@Rackspace.com using brian.abshier@RACKSPACE.COM awesome flexos tool.
