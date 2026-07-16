# OpenCenter Real-Time Monitoring

Three connected monitoring experiences, all strictly **read-only**:

1. **Deployment Live Dashboard** — `/opencenter/monitor/deployment/<org>/<cluster>`
2. **Cluster Operations Dashboard** — `/opencenter/monitor/cluster/<org>/<cluster>`
3. **Grafana OpenCenter dashboards** — provisioned from `infrastructure/monitoring/grafana/`

Both live dashboards are linked from the Stage 2 OpenCenter quickstart (ocqs)
and production (ocqp) panels via the **📡 Deployment Live Monitor** and
**🩺 Cluster Live Monitor** buttons next to AutoRun.

## Architecture

```
browser ──SSE/JSON──▶ Flask blueprint (workflow_dashboard/routes/monitoring_api.py)
                          │
                          ▼
        workflow_dashboard/monitoring/
          command_registry.py   allowlisted argv builders + cache tiers
          command_runner.py     timeouts, kubeconfig/OpenStack gating, env isolation
          cache.py              shared TTL cache, single-flight (many viewers → one poll)
          parsers.py            bootstrap-log stages, OpenTofu events, Ansible recap,
                                error classification, k8s/Flux/OpenStack JSON normalizers
          log_stream.py         newest-log discovery + tail -F SSE generator
          deployment_monitor.py DeploymentSnapshot builder (incremental log parse)
          cluster_monitor.py    ClusterHealthSnapshot builder + health score
          opencenter_exporter.py Prometheus /metrics (scrape-cheap)
          redaction.py          ANSI strip + secret redaction
          models.py             MonitoringContext (validated paths), snapshots
```

- The browser never supplies command text; endpoints reference registry ids.
- `MonitoringContext.resolve()` validates org/cluster against
  `[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?` and requires an existing blueprint —
  path traversal is impossible by construction.
- OpenStack credentials come from the cluster blueprint
  (`opencenter.infrastructure.cloud.openstack`); they are injected into child
  process env only and never returned. Ambient `OS_*` variables are stripped
  from every non-OpenStack command.
- Commands are gated: kubectl/Flux only after the cluster-owned kubeconfig
  exists; OpenStack only when the provider is `openstack`; anything missing
  returns `not available yet` instead of an error.

## Polling intervals (cache tiers)

| Tier | Interval | Used for |
| --- | --- | --- |
| process/log | 2 s | deploy process table, bootstrap log parse |
| VM | 5 s | `openstack server list`, k8s nodes/pods, Flux CRs |
| quota | 15 s | quotas, secgroups, FIPs, services, certs, PVCs |
| static | 30 s | namespaces, storage classes |

The cache is shared and single-flight: N browsers watching one cluster cause
one command execution per interval. OpenTofu plan is never executed at all —
Tofu state is derived purely from log parsing, so nothing can collide with a
running apply.

## Deployment pipeline stages

Log markers (`step started/completed/failed: <id>`) map to 15 UI stages;
`opentofu-apply` internally hosts cloud-init and Kubespray, which are surfaced
from their own sub-signals (cloud-init status lines, `TASK [...]`, `PLAY
RECAP`). Git-side stages derive from live `git status --porcelain=v2` of the
GitOps tree. To add a new stage parser: extend `PIPELINE_STAGES` and
`_STEP_ID_TO_STAGE` in `parsers.py`, and add a fixture test.

## Error intelligence

`parsers.classify_error_line` maps failures to categories (auth, git, gitops
dirty, endpoint, quota, image, scheduling, networking, cloud-init, ssh,
ansible, kubernetes, flux, unknown) with root cause, evidence, safe next
command, resumability and a `--from-step` hint. `--break-lock` is never
recommended while a deploy process is alive. Duplicate deploy processes are
detected from the process table and shown as CRITICAL without killing
anything.

## API

```
GET /api/monitoring/clusters
GET /api/monitoring/deployment/<org>/<cluster>/{summary,stages,processes,infrastructure,events,stream}
GET /api/monitoring/cluster/<org>/<cluster>/{summary,nodes,pods,flux,services,network,storage,security,events,stream}
GET /metrics      GET /healthz
```

`stream` endpoints are Server-Sent Events: `log`, `snapshot` and `status`
events. The deployment stream auto-switches when a newer
`bootstrap-*.log` appears.

## Prometheus metrics

Exported by `opencenter_exporter.py` at `/metrics` (port 5001):
`opencenter_deployment_info/status/stage_status/stage_state/
total_duration_seconds/failures_total/lock_conflicts_total`,
`opencenter_gitops_clean/unpushed_commits/last_commit_timestamp_seconds`,
`opencenter_openstack_vm_status/quota_usage_ratio`,
`opencenter_cluster_node_ready/pods`, `opencenter_flux_resource_ready`,
`opencenter_platform_service_ready`.

Scrapes are cheap: deployment metrics come from local files/process table;
cluster metrics are served from the shared cache only. Set
`OPENCENTER_EXPORTER_ACTIVE=1` on the dashboard service to run a 60 s
background refresher for clusters with a kubeconfig. Scrape config:
`infrastructure/monitoring/prometheus/opencenter-exporter-scrape.yaml`.

## Loki

`infrastructure/monitoring/promtail/promtail-opencenter.yaml` ships deployer
host logs (bootstrap + dashboard) with labels `app=opencenter`, `org`,
`cluster`, `source`, `severity` — never message text, tokens or IDs — and
redacts `password/secret/token/api-key` assignments before shipping.
In-cluster pod logs are collected by the Loki GitOps service's own agent.

## Grafana

See `infrastructure/monitoring/grafana/README.md` for installation. Four
dashboards (`opencenter-cluster-overview`, `-deployment`, `-gitops`,
`-infrastructure`) with `datasource/org/cluster/region/namespace/node/
service/pod` variables, plus alert rules in `alerts/opencenter-alerts.yaml`.

## Security model

- Read-only: no kill, no `--break-lock`, no destroy/delete anywhere.
  Destructive advice is never executed — at most shown as a copyable command,
  marked destructive.
- Explicit command allowlist with per-command timeouts.
- Secrets redacted in logs, API payloads and metric labels
  (`monitoring/redaction.py`).
- Same (local, unauthenticated) exposure model as the rest of the workflow
  dashboard — bind accordingly.

## Required binaries

`ps`, `git` always; `kubectl` for cluster views; `openstack` CLI for
FLEX/OpenStack cards; `promtail` only if log shipping is enabled. Missing
binaries degrade to "not available", never crash.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Stages all pending | newest `bootstrap-*.log` exists under `~/.local/state/opencenter/logs/bootstrap/<org>/<cluster>/` |
| VM card "not available" | provider is `openstack` and blueprint has app credentials |
| Cluster page "kubeconfig does not exist" | deploy has not reached the kubeconfig step yet |
| `/metrics` missing cluster series | warm the cache by opening the cluster dashboard, or set `OPENCENTER_EXPORTER_ACTIVE=1` |
| SSE stops | the pulse dot turns red; the client reconnects automatically every 4–5 s |

## Adding a monitored platform service

Append to `PLATFORM_SERVICES` in `cluster_monitor.py`
(`id, title, namespace, workload-name prefixes`) — the matrix, health score
and `opencenter_platform_service_ready` metric pick it up automatically.

## Running the tests

```bash
pytest tests/test_monitoring_backend.py -v
```

Covers log discovery, incremental stage parsing, ANSI/secret redaction,
duplicate-deploy detection, OpenTofu/OpenStack/k8s/Flux/quota parsing, missing
kubeconfig/credential behaviour, allowlist enforcement, timeouts, cache TTL,
path-traversal rejection, the metrics endpoint and Grafana JSON validity,
with fixtures for success, quota failure, invalid image, cloud-init timeout,
Flux/CRD failure and duplicate deployments.
