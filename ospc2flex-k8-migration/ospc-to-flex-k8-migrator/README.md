# ospc-to-flex-k8-migrator

Migrate Kubernetes workloads from **OSPC** (OpenStack Private Cloud) to a new
**Rackspace Flex Magnum** Kubernetes cluster.

---

## Purpose

This toolkit automates all stages of an OSPC → Flex K8s migration:

1. Export cluster resources from OSPC (via SSH to the master node)
2. Design and validate Flex Magnum ClusterTemplate (Magnum 2025.2 requirements)
3. Create a new Flex Magnum cluster
4. Transform manifests to be Flex-compatible
5. Restore workloads to Flex in the correct phase order
6. Restore stateful data (databases, PVCs)
7. Test and validate (incl. Magnum health check + LoadBalancer test)
8. Cut over traffic (DNS/LB)
9. Roll back if needed

## Architecture

> **Core rule: do not import the old OSPC control plane into Magnum.**
>
> Magnum creates a brand-new cluster. This toolkit exports, transforms, and
> re-applies all workloads onto the new cluster.

See [docs/architecture.md](docs/architecture.md) for the full design.

---

## Prerequisites

| Tool | Required | Purpose |
|------|----------|---------|
| Python 3.11+ | Yes | CLI and transform engine |
| ssh, scp | Yes | Stage 1 remote export |
| kubectl | Yes (on OSPC master) | Source cluster export |
| helm | Optional (on OSPC master) | Helm release export |
| openstack CLI | Yes | Stage 2 cluster creation |

```bash
pip install -r requirements.txt
cp env.example .env && vi .env
```

---

## Quick Start

### Stage 1 — Export from OSPC

Stage 1 **always runs via SSH to the OSPC master node**. All kubectl/helm commands
execute on the master; results are copied back locally via scp.

```bash
export OSPC_MASTER_IP=10.1.2.3
export SSH_USER=centos
export SSH_KEY_PATH=~/.ssh/id_rsa

./scripts/export_ospc_k8.sh \
  --output-dir ./output \
  --plan ./configs/migration-plan.yaml
```

Output:
```
output/<timestamp>/export/
├── kubeconfig-ospc
├── inventory.txt          # human-readable summary
├── summary.json           # machine-readable summary
├── manifests/
│   ├── cluster/           # storageclasses, CRDs, clusterroles, PVs …
│   └── namespaces/        # per-namespace YAML exports
├── helm/                  # helm values + manifests per release
├── images/images.txt      # all container images
└── logs/
```

### Stage 2 — Design and Validate Flex Magnum ClusterTemplate

Validate the ClusterTemplate against Magnum 2025.2 requirements before creating
any cluster resources.

```bash
python -m ospc_to_flex_k8.cli design-template \
  --template-name flex-k8s-1-29-coreos \
  --openrc ~/openrc.sh \
  --output-dir ./output/<ts>
```

Key checks performed: COE type, `image_os_distro=fedora-coreos`, network driver
(flannel/calico), volume driver (cinder), keypair, flavor, external network,
and Heat driver deprecation warning.

### Stage 3 — Create Flex Magnum Cluster

```bash
source ./configs/cluster-create.example.env
./scripts/create_flex_magnum_cluster.sh \
  --name flex-k8s-prod \
  --template flex-k8s-1-29-coreos \
  --openrc ~/openrc.sh \
  --kubeconfig-out ./output/flex-kubeconfig
```

### Stage 4 — Transform Manifests

```bash
./scripts/transform_for_flex.sh \
  --source-dir ./output/<ts>/export/manifests \
  --output-dir ./output/<ts> \
  --plan ./configs/migration-plan.yaml
```

### Stage 5 — Restore to Flex

```bash
# Always dry-run first
./scripts/restore_to_flex.sh \
  --transformed-dir ./output/<ts>/transform/transformed-manifests \
  --kubeconfig ./output/flex-kubeconfig \
  --dry-run

# Real apply
./scripts/restore_to_flex.sh \
  --transformed-dir ./output/<ts>/transform/transformed-manifests \
  --kubeconfig ./output/flex-kubeconfig \
  --report-dir ./output/<ts>
```

### Stage 6 — Restore Data

```bash
# Database
./scripts/restore_db.sh \
  --type mysql \
  --source-context ospc-ctx --source-ns myapp --source-pod mysql-0 \
  --target-context flex-ctx --target-ns myapp --target-pod mysql-0 \
  --db-name myappdb

# PVC data (via helper pod)
kubectl apply -f templates/pvc_restore_helper.pod.yaml
kubectl cp ./backup/ myns/pvc-restore-helper:/data/
```

### Stage 7 — Test and Validate

```bash
./scripts/smoke_tests.sh --kubeconfig ./output/flex-kubeconfig
python -m ospc_to_flex_k8.cli validate \
  --kubeconfig ./output/flex-kubeconfig \
  --cluster-name flex-k8s-prod \
  --openrc ~/openrc.sh \
  --lb-test
```

### Stage 8 — Cut Over

```bash
# Final sync + DNS switch (see docs/runbook.md Stage 8)
./scripts/delta_sync.sh --namespaces myapp,backend --tgt-kubeconfig ./output/flex-kubeconfig
# Then update DNS/LB to Flex Ingress IP
```

### Stage 9 — Rollback

```bash
python -m ospc_to_flex_k8.cli rollback-plan \
  --stage cutover-started --output ./output/rollback-plan.json

./scripts/rollback_helper.sh \
  --src-context ospc-production \
  --tgt-context flex-magnum-production \
  --namespaces myapp,backend
```

---

## Python CLI Reference

```
python -m ospc_to_flex_k8.cli <command> [options]

Commands:
  export            Stage 1 — SSH to OSPC master, export cluster resources
  design-template   Stage 2 — Validate Flex Magnum ClusterTemplate (Magnum 2025.2)
  create-target     Stage 3 — Create Flex Magnum cluster
  plan              Display the migration plan as JSON
  transform         Stage 4 — Transform exported manifests for Flex
  restore           Stage 5 — Apply manifests to Flex in phase order
  validate          Stage 7 — Run structured validation checks (incl. Magnum + LB)
  smoke-test        Stage 7 — Quick connectivity + health checks
  rollback-plan     Stage 9 — Generate rollback plan from migration state
```

---

## Directory Layout

```
ospc-to-flex-k8-migrator/
├── README.md
├── env.example
├── requirements.txt
├── Makefile
├── .gitignore
├── docs/
│   ├── architecture.md
│   ├── runbook.md
│   ├── rollback.md
│   ├── smoke-tests.md
│   └── assumptions.md
├── configs/
│   ├── migration-plan.example.yaml
│   ├── storage-map.example.yaml
│   ├── ingress-map.example.yaml
│   ├── endpoint-map.example.yaml
│   └── cluster-create.example.env
├── scripts/
│   ├── export_ospc_k8.sh
│   ├── create_flex_magnum_cluster.sh
│   ├── transform_for_flex.sh
│   ├── restore_to_flex.sh
│   ├── restore_db.sh
│   ├── restore_pv.sh
│   ├── smoke_tests.sh
│   ├── delta_sync.sh
│   └── rollback_helper.sh
├── src/ospc_to_flex_k8/
│   ├── cli.py, exporter.py, transformer.py, validator.py
│   ├── planner.py, magnum.py, restore.py
│   ├── manifests.py, io_utils.py, models.py
├── templates/
│   ├── pvc_restore_helper.pod.yaml
│   ├── namespace_order.txt
│   └── restore-order.txt
├── output/              # generated — gitignored except .gitkeep
└── tests/
    ├── test_transformer.py
    ├── test_validator.py
    └── test_planner.py
```

---

## Limitations

- Live PV block data is **not automatically migrated** — use `restore_pv.sh`
- `ReadWriteMany` PVCs require NFS or Manila on Flex (not Cinder)
- Helm re-installs require the original chart registry to be reachable
- API version deprecations are not auto-upgraded (use `kubectl-convert`)
- This toolkit is **non-destructive** — it never deletes source resources

See [docs/assumptions.md](docs/assumptions.md) for the full list.

---

## Development

```bash
make install   # install deps
make test      # run unit tests
make lint      # lint
```

---

## Safe Usage

- Never commit `.env`, kubeconfig, or OpenRC files
- Always run `--dry-run` before real apply
- Keep OSPC cluster healthy until `cutover-complete` is confirmed
- Back up `output/<timestamp>/` — it contains exported secrets
