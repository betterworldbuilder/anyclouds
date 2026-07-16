# OpenCenter Grafana Monitoring Package

Provisioning assets for the OpenCenter monitoring stack.

## Contents

| Path | Purpose |
| --- | --- |
| `dashboards/opencenter-cluster-overview.json` | Executive health, nodes/capacity, workloads, control plane, platform services, storage, networking, security |
| `dashboards/opencenter-deployment.json` | Deployment state/stage metrics, history, Loki deployment-log panels |
| `dashboards/opencenter-gitops.json` | GitOps tree state, Flux controllers, Flux logs |
| `dashboards/opencenter-infrastructure.json` | OpenStack VM status + quota ratios, node readiness |
| `provisioning/dashboards/opencenter.yaml` | Grafana file-provider that loads the dashboards into an "OpenCenter" folder |
| `provisioning/datasources/datasources.yaml` | Prometheus/Loki/Tempo datasources — apply **only** where OpenCenter has not already provisioned them |
| `alerts/opencenter-alerts.yaml` | Prometheus alert rules (deployment failure, duplicate deploys, node/flux/service health, quota pressure, cert expiry) |
| `../promtail/promtail-opencenter.yaml` | Deployer-host Promtail shipping bootstrap/dashboard logs to Loki |
| `../prometheus/opencenter-exporter-scrape.yaml` | Scrape config / ScrapeConfig CR for the deployer `/metrics` exporter |

## Installing into an OpenCenter cluster

Grafana is deployed by the `kube-prometheus-stack` GitOps service. To load
these dashboards, mount them via the Helm values in the cluster overlay
(`applications/overlays/<cluster>/services/kube-prometheus-stack/helm-values/`):

```yaml
grafana:
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: opencenter
          folder: OpenCenter
          type: file
          options: {path: /var/lib/grafana/dashboards/opencenter}
  dashboardsConfigMaps:
    opencenter: grafana-opencenter-dashboards
```

Create the ConfigMap from this directory:

```bash
kubectl -n observability create configmap grafana-opencenter-dashboards \
  --from-file=dashboards/ --dry-run=client -o yaml | kubectl apply -f -
```

Alert rules load through `additionalPrometheusRulesMap` in the same values
file, or as a `PrometheusRule` CR.

Deployment-history panels use the deployer exporter metrics
(`opencenter_*`); configure the scrape per
`../prometheus/opencenter-exporter-scrape.yaml`. Dashboards degrade
gracefully (empty panels, no errors) when a metric source is absent.

## Dashboard variables

`datasource`, `loki`, `org`, `cluster`, `region`, `namespace`, `node`,
`service`, `pod` — all query-driven; `org`/`cluster` come from
`opencenter_deployment_info`.
