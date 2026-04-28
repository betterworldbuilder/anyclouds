# 🚀 CLOUD JUMPER

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

CloudJumper works as a full-cycle migration Mission Control. Each stage turns unknowns into artifacts: CSVs, maps, scripts, repaired images, booted test instances, verification results, and rollback paths.

| Phase | Stage | Mission Control Function | Benefit |
|:---:|---|---|---|
| 📡 | **0. Customer Tracker** | Tracks customer, estate, status, notes, stage progress, and active migration context. | Keeps multiple migrations organized without losing the human thread. |
| 🔭 | **1. Discover** | Scans OSPC and FLEX inventory: servers, images, flavors, volumes, networks, security groups, load balancers, and floating IPs. | Builds a factual source-of-truth before anyone starts changing infrastructure. |
| 🗺️ | **2. Map & Design** | Compares source/target capacity, edges, and imports topology into a visual model to plan the target build. | Turns "what do we have?" into "where will it land?" and lets engineers see the shape of the migration. |
| ⚙️ | **3. Generate** | Produces deployment, data migration, sync, cutover, rollback, and validation scripts from the migration map. | Makes the work repeatable, reviewable, and safer than manual command assembly. |
| 💾 | **4. Database & Server Rehost** | Provisions target FLEX servers and orchestrates the database migration/sync (MySQL, PostgreSQL, block syncs). | Ensures data gravity is handled seamlessly alongside compute. |
| 📦 | **5. Image Migration & Repair** | Moves Linux/Windows workloads via NBD/Glance and applies offline guest repair (bootloaders, fstab, virtio, network config). | Converts old cloud images into FLEX-ready artifacts and fixes common first-boot failures offline. |
| ☸️ | **6. Kubernetes Mig (WIP)** | Translates Magnum OSPC clusters or raw k8s nodes into modern FLEX Kubernetes deployment models. | Containerized workloads jump alongside legacy VMs. |
| 🔬 | **7. UAT (Boot & Verify)** | Creates FLEX test instances, attaches access, checks ping/SSH, gathers host/kernel data, and streams logs. | Changes "the image uploaded" into "the workload is alive." |
| ✂️ | **8. Cut Over** | Uses generated cutover and rollback scripts with final validation evidence to shift live traffic. | Gives the migration a controlled finish line instead of a nervous handoff. |
| 🏁 | **9. Post Migration** | Generates infrastructure-as-code manifests, documentation, and optimization telemetry. | Hands off a modernized, GitOps-ready environment to the customer. |

The dashboard is not only a launcher. It is an evidence machine. Every scan, map, run log, repair log, manifest, and verification table becomes data that can feed the next automation layer.

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

## 🛠️ Liftoff Sequence (What Now)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements/requirements.txt
python3 workflow_dashboard/app.py
```
*Mission Control will print your local orbital dashboard URL.*

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
        +--> Stage 7: OpenCenter
        |       Day-2 platform view
        |       K8s/OpenStack operations
        |       GitOps workflows
        |       observability/runbooks
        |
        +--> Stage 8: Genestack
        |       OpenStack/FLEX landing zone
        |       Helm/OpenStack service config
        |       /etc/genestack overrides
        |       cloud components/versioning
        |
        +--> Stage 9: AI Anywhere
                private AI context pack
                autorepair plans
                risk and right-sizing recommendations
                Terraform/Ansible/Genestack patch suggestions
```

UAT does not need a separate disconnected artifact. It reuses the Migration Output Bundle through `uat-input/`, and that UAT view points back to `discovery-output/` and `stage2-migration-output/` so testers can validate what was discovered, what migrated, what was repaired, and what evidence exists before cutover.

That means CloudJumper can interconnect with FinOps reporting, **OpenCenter**, **Genestack**, Magnum, and other GitOps control planes. TCO / FinOps turns the migration into financial evidence: source baseline, target run-rate, right-sizing candidates, and executive reporting. OpenCenter becomes the Day-2 operations cockpit for migrated estates: platform view, Kubernetes/OpenStack operations, GitOps workflows, observability, and runbooks. Genestack becomes the repeatable FLEX/OpenStack foundation layer: landing-zone configuration, Helm/OpenStack service config, `/etc/genestack` overrides, and cloud component/version tracking.

AI Anywhere becomes the private intelligence layer over the whole chain. It reads the CloudJumper output bundle plus OpenCenter and Genestack outputs, then produces risk scores, autorepair plans, right-sizing recommendations, runbook improvements, and infrastructure patch suggestions without losing the customer-specific context.

Instead of finishing with a one-time migration script, the customer leaves with a repeatable operating model: infrastructure saved as code, repairs encoded as playbooks, topology represented as reviewable templates, and deployment state controlled through pull requests.

From there, AI agents can help with the work that usually gets lost after migration day: autorepair failed boots, recommend right-sized FLEX flavors, generate Terraform patches from validated migration maps, summarize risk before each cutover, and keep customer environments optimized as they scale.

### 🌟 The Promise

OSPC carried important workloads for a long time. FLEX is where those workloads can keep moving.

CloudJumper is the bridge: part scanner, part repair bench, part launch console, part field notebook. It does not replace engineering judgment. It gives that judgment a cockpit, a checklist, and a live instrument panel.

**Move carefully. Verify everything. Bring the customer forward.**

## Details for the Nerds

Need the full operator notes, workflow history, script map, and deeper telemetry? Read the extended mission manual: [README.long.MD](README.long.MD).

Made with Love by Dzoan.nguyen@Rackspace.com using brian.abshier@RACKSPACE.COM awesome flexos tool.
