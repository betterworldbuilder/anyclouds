# Rollback Guide

This document describes how to roll back from Flex to OSPC if the migration fails
or the cutover must be aborted.

---

## When to Roll Back

Trigger rollback if any of these conditions occur after cutover:

- Application error rate exceeds acceptable threshold on Flex
- Critical data is missing or corrupt on Flex
- Flex cluster enters a degraded state
- SLA is at risk and OSPC is still healthy

---

## Rollback Trigger Table (9-Stage Model)

| Stage | Trigger condition | Rollback effort |
|-------|------------------|-----------------|
| Stage 1 — Export | Export fails or data is incomplete | Re-run export; no Flex resources created |
| Stage 2 — Design template | ClusterTemplate validation fails | Fix template; no cluster created — easy rollback (delete/recreate template) |
| Stage 3 — Create cluster | `CREATE_FAILED` or timeout | `openstack coe cluster delete <name>`; recreate |
| Stage 4 — Transform | Transform errors or validation rejects manifests | Fix transforms; cluster is still empty — easy rollback |
| Stage 5 — Restore apps | `apply-report.json` shows failures | Scale down Flex, investigate, re-apply or restore from OSPC |
| Stage 6 — Restore data | Data sync fails or integrity check fails | Re-run restore_db.sh or restore_pv.sh; no traffic cutover yet |
| Stage 7 — Test & validate | LB test fails or validation errors | No cutover yet; investigate on Flex, re-run validation |
| Stage 8 — Cut over | Traffic issues after DNS switch | Revert DNS to OSPC (see below) |
| Stage 9 — Rollback | Rollback triggered | Follow steps in this document |

---

## Migration States

| State | Meaning |
|-------|---------|
| `rehearsal` | First dry-run test; no cutover attempted |
| `pre-cutover` | Final sync running; OSPC still serving traffic |
| `cutover-started` | DNS/LB switched to Flex; monitoring window open |
| `cutover-complete` | Traffic confirmed healthy on Flex |
| `rollback-triggered` | Decision made to roll back |
| `rollback-complete` | Traffic back on OSPC; Flex isolated |

---

## Generate a Rollback Plan

```bash
python -m ospc_to_flex_k8.cli rollback-plan \
  --stage cutover-started \
  --source-context ospc-production \
  --target-context flex-magnum-production \
  --output ./output/rollback-plan.json
```

### Stage 2 Rollback Note

If Stage 2 (ClusterTemplate design/validation) fails:

- No cluster has been created — rollback is trivial.
- Fix the ClusterTemplate fields and re-run `design-template`.
- If the template must be deleted: `openstack coe cluster template delete <name>`
- No OSPC traffic is affected; OSPC continues serving normally.

### Stage 9 — LB Validation Failure Tracking

If a LoadBalancer test failure was recorded in Stage 7:

```bash
# Check the validation report for LB test details
cat ./output/<timestamp>/validation/validation-report.json | \
  python3 -c "import json,sys; r=json.load(sys.stdin); \
  print(next((x for x in r['results'] if x['check']=='loadbalancer_test'), {}))"
```

If LB provisioning failed in Stage 7 and cutover (Stage 8) was skipped, record
the failure in the rollback plan:

```bash
python -m ospc_to_flex_k8.cli rollback-plan \
  --stage pre-cutover \
  --notes "LB test failed in Stage 7 — Octavia quota or Magnum misconfiguration" \
  --output ./output/rollback-plan.json
```

---

## Step-by-Step Rollback

### 1. Scale Down Flex Workloads

Prevent Flex from accepting new writes while rolling back:

```bash
FLEX_KC=./output/flex-kubeconfig
for NS in myapp backend api; do
  kubectl --kubeconfig=$FLEX_KC scale deployment --all -n $NS --replicas=0
  kubectl --kubeconfig=$FLEX_KC scale statefulset --all -n $NS --replicas=0
done
```

### 2. Re-enable OSPC Workloads

If OSPC workloads were scaled down during cutover:

```bash
OSPC_CTX=ospc-production
for NS in myapp backend api; do
  kubectl --context=$OSPC_CTX scale deployment --all -n $NS --replicas=1
  kubectl --context=$OSPC_CTX scale statefulset --all -n $NS --replicas=1
done
```

### 3. Revert DNS / Load Balancer

Update your DNS records to point back to OSPC Ingress/LoadBalancer IPs.

For Route53:
```bash
aws route53 change-resource-record-sets --hosted-zone-id <id> --change-batch file://ospc-dns.json
```

For Rackspace DNS:
```bash
# Use Rackspace Cloud Control Panel or pyrax CLI
```

### 4. Verify OSPC Is Healthy

```bash
kubectl --context=ospc-production get pods -A | grep -v Running
curl -I https://myapp.example.com  # should return 200
```

### 5. Record Rollback Completion

```bash
# Update state file
python -m ospc_to_flex_k8.cli rollback-plan \
  --stage rollback-complete \
  --output ./output/rollback-complete.json
```

---

## Data Considerations

- If writes went to Flex during the cutover window, those writes are on Flex PVCs.
- Before rollback, assess whether these writes need to be synced back to OSPC.
- For databases: check transaction logs on both sides before deciding.

---

## Using the rollback_helper.sh Script

```bash
./scripts/rollback_helper.sh \
  --src-context ospc-production \
  --tgt-context flex-magnum-production \
  --namespaces myapp,backend,api \
  --dry-run   # review first

# Then without --dry-run
./scripts/rollback_helper.sh \
  --src-context ospc-production \
  --tgt-context flex-magnum-production \
  --namespaces myapp,backend,api
```
