# Smoke Tests

Smoke tests are quick, non-destructive checks that verify the Flex cluster
and migrated workloads are functioning correctly after restore.

---

## Running Smoke Tests

```bash
# Via shell wrapper
./scripts/smoke_tests.sh \
  --kubeconfig ./output/flex-kubeconfig \
  --namespaces myapp backend

# Via Python CLI
python -m ospc_to_flex_k8.cli smoke-test \
  --kubeconfig ./output/flex-kubeconfig \
  --namespaces myapp backend \
  --url-checks https://myapp.flex.example.com https://api.flex.example.com
```

---

## Checks Performed

| Check | What it verifies |
|-------|-----------------|
| `api_server_reachable` | `kubectl version` succeeds |
| `nodes_ready` | All nodes in Ready state |
| `pvcs_bound` | All PVCs are Bound (no Pending) |
| `services_have_endpoints` | Non-headless Services have ready endpoints |
| `no_crashlooping_pods` | No pods in CrashLoopBackOff / Error / OOMKilled |
| `url_<URL>` | HTTP status 2xx/3xx for each --url-checks URL |

---

## Full Validation Suite

Smoke tests are a quick gate check. For a full structured validation:

```bash
python -m ospc_to_flex_k8.cli validate \
  --kubeconfig ./output/flex-kubeconfig \
  --namespaces myapp backend monitoring \
  --report-dir ./output/<timestamp>/validate
```

This produces:
- `validation-report.json` — machine-readable
- `validation-summary.txt` — human-readable

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All checks passed |
| `1` | One or more checks failed |
| `130` | Interrupted (Ctrl-C) |

---

## Interpreting Failures

**No endpoints for service X:**
- The pod(s) backing the service may still be starting. Wait and re-run.
- The pod may have a PVC in Pending state — check PVC binding.

**CrashLoopBackOff:**
- Check pod logs: `kubectl logs <pod> -n <ns> --previous`
- Common causes: missing ConfigMap, wrong env var, PVC not bound, image pull failure.

**PVC Pending:**
- StorageClass may not match — check `kubectl describe pvc <name> -n <ns>`
- Ensure the target StorageClass exists: `kubectl get storageclass`

---

## Example Output

```
=== Flex Magnum Smoke Tests ===
Context: flex-magnum-production

-- Cluster connectivity --
  CHECK: API server reachable ... PASS
  CHECK: Nodes present ... PASS
  CHECK: All nodes Ready ... PASS

-- Workload health --
  CHECK: No CrashLoopBackOff pods ... PASS
  CHECK: No ImagePullBackOff pods ... PASS
  CHECK: No Pending PVCs ... PASS

-- Python validator --
  [PASS] nodes_ready: 5 node(s) all Ready
  [PASS] deployments_available: All 12 deployment(s) available
  [PASS] statefulsets_ready: All 3 StatefulSet(s) ready
  [PASS] pvcs_bound: All 8 PVC(s) Bound

=== Smoke Test Summary: PASS=6 FAIL=0 ===
```
