# Migration Runbook

Step-by-step operator guide for a full OSPC K8s → Rackspace Flex Magnum migration
using the **9-stage model**.

---

## Prerequisites Checklist

- [ ] SSH access to OSPC master node (`ssh -i <key> user@<master-ip>`)
- [ ] kubectl working on OSPC master (`ssh ... kubectl get nodes`)
- [ ] helm installed on OSPC master (optional, for Helm exports)
- [ ] Rackspace Flex account with Magnum enabled
- [ ] Magnum ClusterTemplate already created in Flex (see Stage 2)
- [ ] OpenRC credentials file for Flex
- [ ] `openstack` CLI installed locally (`pip install python-openstackclient`)
- [ ] Python 3.11+ installed locally
- [ ] `pip install -r requirements.txt` completed
- [ ] `configs/migration-plan.yaml` reviewed and edited (includes `stage2_design` section)

---

## Stage 1 — Export from OSPC

```bash
# Set required env vars
export OSPC_MASTER_IP=10.x.x.x
export SSH_USER=centos
export SSH_KEY_PATH=~/.ssh/id_rsa

# Run export
./scripts/export_ospc_k8.sh \
  --output-dir ./output \
  --plan ./configs/migration-plan.yaml

# Verify output
ls ./output/<timestamp>/export/
cat ./output/<timestamp>/export/inventory.txt
cat ./output/<timestamp>/export/summary.json
```

**Success criteria:**
- `summary.json` exists and contains `kubernetes_version`, `node_count`, `namespace_count`
- `inventory.txt` lists all exported namespaces
- `manifests/` subdirectory contains YAML files
- `images/images.txt` contains container image list

---

## Stage 2 — Design and Validate Flex Magnum ClusterTemplate

Before creating the cluster you must confirm that the ClusterTemplate meets
Magnum 2025.2 requirements.

**2A — Create (or obtain) a ClusterTemplate on Flex:**

```bash
# Example using openstack CLI (Magnum 2025.2 / k8s_capi_helm driver)
openstack coe cluster template create flex-k8s-1-29-coreos \
  --coe kubernetes \
  --image <fedora-coreos-image-id> \
  --external-network <external-net-id> \
  --network-driver calico \
  --volume-driver cinder \
  --keypair "${MAGNUM_KEYPAIR}" \
  --master-flavor m1.medium \
  --flavor m1.large \
  --master-lb-enabled \
  --floating-ip-enabled \
  --docker-volume-size 50
```

**2B — Validate the template:**

```bash
python -m ospc_to_flex_k8.cli design-template \
  --template-name flex-k8s-1-29-coreos \
  --openrc "${FLEX_OPENRC}" \
  --output-dir ./output/<timestamp>
```

Review `output/<timestamp>/design/design-report.json`.

**Stage 2 validation checklist:**

- [ ] `coe_is_kubernetes` — PASS
- [ ] `image_os_distro_compatible` — PASS (fedora-coreos)
- [ ] `external_network_present` — PASS
- [ ] `network_driver_selected` — PASS (calico or flannel)
- [ ] `volume_driver_selected` — PASS (cinder)
- [ ] `keypair_present` — PASS
- [ ] `flavor_decision_recorded` — PASS (both flavor_id and master_flavor_id set)
- [ ] `driver_note` — no Heat driver warning (informational)
- [ ] `master_lb_decision_recorded` — reviewed (informational)

**Success criteria:**
- `design-report.json` shows zero `passed: false` entries
- No Heat driver warning (or warning is acknowledged)

---

## Stage 3 — Create Flex Magnum Cluster

```bash
source ./configs/cluster-create.env

./scripts/create_flex_magnum_cluster.sh \
  --name  "${MAGNUM_CLUSTER_NAME}" \
  --template "${MAGNUM_TEMPLATE}" \
  --openrc "${FLEX_OPENRC}" \
  --masters 3 \
  --workers 5 \
  --keypair "${MAGNUM_KEYPAIR}" \
  --kubeconfig-out ./output/flex-kubeconfig
```

**Success criteria:**
- `openstack coe cluster show <name>` shows `CREATE_COMPLETE`
- `kubectl --kubeconfig ./output/flex-kubeconfig get nodes` returns Ready nodes

---

## Stage 4 — Transform Manifests

```bash
./scripts/transform_for_flex.sh \
  --source-dir ./output/<timestamp>/export/manifests \
  --output-dir ./output/<timestamp> \
  --plan ./configs/migration-plan.yaml
```

Review the report:
```bash
cat ./output/<timestamp>/transform/transform-report.json
```

**Success criteria:**
- `transform-report.json` shows `total_output > 0`
- `transformed-manifests/all_manifests.yaml` exists
- Warnings are reviewed and accepted

---

## Stage 5 — Restore Apps to Flex

```bash
# Dry-run first
./scripts/restore_to_flex.sh \
  --transformed-dir ./output/<timestamp>/transform/transformed-manifests \
  --kubeconfig ./output/flex-kubeconfig \
  --dry-run

# Real apply
./scripts/restore_to_flex.sh \
  --transformed-dir ./output/<timestamp>/transform/transformed-manifests \
  --kubeconfig ./output/flex-kubeconfig \
  --report-dir ./output/<timestamp>
```

**Success criteria:**
- `apply-report.json` shows `failed == 0`
- `kubectl get pods -A` shows pods starting

---

## Stage 6 — Restore Data

**6A — Databases:**
```bash
./scripts/restore_db.sh \
  --type mysql \
  --source-context ospc-ctx --source-ns myapp --source-pod mysql-0 \
  --target-context flex-ctx --target-ns myapp --target-pod mysql-0 \
  --db-name myappdb
```

**6B — PVC data:**
```bash
# Edit the helper pod template
cp templates/pvc_restore_helper.pod.yaml /tmp/restore-helper.yaml
# Edit PVC_NAME and NAMESPACE in the file
kubectl --kubeconfig ./output/flex-kubeconfig apply -f /tmp/restore-helper.yaml
kubectl --kubeconfig ./output/flex-kubeconfig cp ./local-backup/ myns/pvc-restore-helper:/data/
kubectl --kubeconfig ./output/flex-kubeconfig delete pod pvc-restore-helper -n myns
```

---

## Stage 7 — Test and Validate

**7A — Smoke tests:**
```bash
./scripts/smoke_tests.sh \
  --kubeconfig ./output/flex-kubeconfig
```

**7B — Structured validation (incl. Magnum health + LoadBalancer test):**
```bash
python -m ospc_to_flex_k8.cli validate \
  --kubeconfig ./output/flex-kubeconfig \
  --cluster-name "${MAGNUM_CLUSTER_NAME}" \
  --openrc "${FLEX_OPENRC}" \
  --lb-test \
  --report-dir ./output/<timestamp>/validation
```

**7C — Magnum cluster health check:**
```bash
openstack coe cluster show "${MAGNUM_CLUSTER_NAME}" -f value -c status
# Expected: CREATE_COMPLETE
```

**7D — LoadBalancer test:**

Run the kubectl commands from `validation-report.json` under the `loadbalancer_test`
entry to deploy a test Service of type LoadBalancer and confirm an external IP is
assigned within 3 minutes.

**Stage 7 validation checklist:**

- [ ] `magnum_cluster_status` — CREATE_COMPLETE
- [ ] `loadbalancer_test` — external IP assigned
- [ ] `kubectl_nodes` — all nodes Ready
- [ ] `pvc_binding` — all PVCs Bound
- [ ] `svc_endpoints` — all services have endpoints
- [ ] `ingress_objects` — Ingress rules resolve

**Success criteria:**
- `validation-report.json` shows `all_passed: true`
- LoadBalancer Service receives an external IP within 3 minutes
- No pods in CrashLoopBackOff or Error state

---

## Stage 8 — Cut Over

1. Run final DB delta sync (see `scripts/delta_sync.sh`).
2. Enable maintenance mode on OSPC (prevent new writes).
3. Run final PVC sync if needed.
4. Update DNS records to point to Flex Ingress LB IP.
5. Verify traffic flows to Flex.
6. Monitor for 30 minutes.

---

## Stage 9 — Rollback (if needed)

See [rollback.md](rollback.md).
