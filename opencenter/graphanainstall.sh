

#!/usr/bin/env bash
set -Eeuo pipefail

# OpenCenter monitoring all-in-one installer for Ubuntu 24.04
# Installs Prometheus, Node Exporter, Grafana, an OpenCenter exporter,
# alert rules, and four provisioned Grafana dashboards.

PROJECT_ROOT="${PROJECT_ROOT:-/home/${SUDO_USER:-$USER}/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current}"
RUN_USER="${RUN_USER:-${SUDO_USER:-$USER}}"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-3.13.0}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.10.2}"
GRAFANA_BIND="${GRAFANA_BIND:-0.0.0.0}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
PROM_RETENTION="${PROM_RETENTION:-30d}"
PROM_RETENTION_SIZE="${PROM_RETENTION_SIZE:-20GB}"
EXPORTER_PORT="${EXPORTER_PORT:-9187}"

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Run with sudo: sudo PROJECT_ROOT=... bash $0" >&2
  exit 1
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "[ERROR] OpenCenter project root not found: $PROJECT_ROOT" >&2
  exit 1
fi

case "$(dpkg --print-architecture)" in
  amd64) BIN_ARCH=amd64 ;;
  arm64) BIN_ARCH=arm64 ;;
  *) echo "[ERROR] Unsupported architecture" >&2; exit 1 ;;
esac

log(){ printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
backup(){ [[ -e "$1" ]] && cp -a "$1" "$1.bak.$(date +%Y%m%d%H%M%S)" || true; }

log "Installing base packages"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl wget gnupg jq tar gzip python3 python3-venv python3-pip

log "Creating service users and directories"
getent group prometheus >/dev/null || groupadd --system prometheus
id prometheus >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin --gid prometheus prometheus
getent group node_exporter >/dev/null || groupadd --system node_exporter
id node_exporter >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin --gid node_exporter node_exporter
install -d -o prometheus -g prometheus -m 0750 /etc/prometheus /etc/prometheus/rules /var/lib/prometheus
install -d -o root -g root -m 0755 /opt/opencenter-monitoring

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "Installing Prometheus ${PROMETHEUS_VERSION}"
PROM_TGZ="prometheus-${PROMETHEUS_VERSION}.linux-${BIN_ARCH}.tar.gz"
curl -fL --retry 3 "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/${PROM_TGZ}" -o "$TMP/$PROM_TGZ"
tar -xzf "$TMP/$PROM_TGZ" -C "$TMP"
install -m 0755 "$TMP/prometheus-${PROMETHEUS_VERSION}.linux-${BIN_ARCH}/prometheus" /usr/local/bin/prometheus
install -m 0755 "$TMP/prometheus-${PROMETHEUS_VERSION}.linux-${BIN_ARCH}/promtool" /usr/local/bin/promtool

log "Installing Node Exporter ${NODE_EXPORTER_VERSION}"
NODE_TGZ="node_exporter-${NODE_EXPORTER_VERSION}.linux-${BIN_ARCH}.tar.gz"
curl -fL --retry 3 "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_TGZ}" -o "$TMP/$NODE_TGZ"
tar -xzf "$TMP/$NODE_TGZ" -C "$TMP"
install -m 0755 "$TMP/node_exporter-${NODE_EXPORTER_VERSION}.linux-${BIN_ARCH}/node_exporter" /usr/local/bin/node_exporter

log "Installing Grafana from official APT repository"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg-full.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
chmod 0644 /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y grafana

log "Creating OpenCenter exporter"
python3 -m venv /opt/opencenter-monitoring/venv
/opt/opencenter-monitoring/venv/bin/pip install --upgrade pip >/dev/null
/opt/opencenter-monitoring/venv/bin/pip install prometheus-client psutil pyyaml >/dev/null

cat > /opt/opencenter-monitoring/opencenter_exporter.py <<'PY'
#!/usr/bin/env python3
import glob, json, os, re, subprocess, time
from pathlib import Path
from prometheus_client import Gauge, Info, start_http_server

CONFIG = Path(os.environ.get("OPENCENTER_CONFIG_DIR", str(Path.home()/".config/opencenter")))
STATE = Path(os.environ.get("OPENCENTER_STATE_DIR", str(Path.home()/".local/state/opencenter")))
PORT = int(os.environ.get("OPENCENTER_EXPORTER_PORT", "9187"))
INTERVAL = int(os.environ.get("OPENCENTER_EXPORTER_INTERVAL", "10"))

info = Info("opencenter_exporter", "OpenCenter exporter information")
processes = Gauge("opencenter_deployment_processes", "Active deploy processes", ["org","cluster"])
status = Gauge("opencenter_deployment_status", "Deployment state", ["org","cluster","status"])
stage = Gauge("opencenter_deployment_stage_status", "Deployment stage state", ["org","cluster","stage","status"])
git_clean = Gauge("opencenter_gitops_clean", "GitOps repo clean", ["org"])
unpushed = Gauge("opencenter_gitops_unpushed_commits", "Unpushed Git commits", ["org"])
node_ready = Gauge("opencenter_cluster_node_ready", "Kubernetes node ready", ["org","cluster","node","role"])
pods = Gauge("opencenter_cluster_pods", "Kubernetes pods by phase", ["org","cluster","phase"])
last_log_age = Gauge("opencenter_bootstrap_log_age_seconds", "Age of newest bootstrap log", ["org","cluster"])

STAGES = [
 ("git_sync", r"Already up to date|fetch origin"),
 ("generate", r"Generate complete"),
 ("secrets", r"Secrets sync completed"),
 ("validate", r"Validation successful"),
 ("opentofu_init", r"Initialize OpenTofu.*✓"),
 ("opentofu_apply", r"Apply OpenTofu infrastructure.*✓|Apply complete"),
 ("cloud_init", r"All nodes have completed cloud-init"),
 ("kubespray", r"Kubespray|ansible-playbook"),
 ("flux", r"Flux.*(ready|bootstrap|complete)"),
]

def run(cmd, timeout=8):
    try:
        return subprocess.run(cmd, text=True, capture_output=True, timeout=timeout, check=False)
    except Exception:
        return None

def clusters():
    root = STATE / "logs/bootstrap"
    if not root.exists(): return []
    out=[]
    for org in root.iterdir():
        if not org.is_dir(): continue
        for cl in org.iterdir():
            if cl.is_dir(): out.append((org.name, cl.name, cl))
    return out

def latest_log(path):
    files = list(path.glob("bootstrap-*.log"))
    return max(files, key=lambda p:p.stat().st_mtime) if files else None

def process_count(org, cluster):
    r=run(["ps","-eo","args="])
    if not r: return 0
    needle=f"opencenter cluster deploy"
    target=f"{org}/{cluster}"
    return sum(1 for x in r.stdout.splitlines() if needle in x and target in x)

def collect_git():
    root=CONFIG/"clusters/gitops"
    if not root.exists(): return
    for org in root.iterdir():
        if not (org/".git").exists(): continue
        r=run(["git","-C",str(org),"status","--porcelain"])
        git_clean.labels(org.name).set(1 if r and not r.stdout.strip() else 0)
        r=run(["git","-C",str(org),"rev-list","--count","@{u}..HEAD"])
        try: unpushed.labels(org.name).set(int(r.stdout.strip()))
        except Exception: unpushed.labels(org.name).set(-1)

def collect_k8s(org, cluster):
    # Uses current service user's kubeconfig/context when available.
    r=run(["kubectl","get","nodes","-o","json"], 10)
    if r and r.returncode==0:
        try:
            data=json.loads(r.stdout)
            for n in data.get("items",[]):
                name=n["metadata"]["name"]
                labels=n["metadata"].get("labels",{})
                role="control-plane" if ("node-role.kubernetes.io/control-plane" in labels or "node-role.kubernetes.io/master" in labels) else "worker"
                ready=any(c.get("type")=="Ready" and c.get("status")=="True" for c in n.get("status",{}).get("conditions",[]))
                node_ready.labels(org,cluster,name,role).set(1 if ready else 0)
        except Exception: pass
    r=run(["kubectl","get","pods","-A","-o","json"], 10)
    if r and r.returncode==0:
        try:
            counts={}
            for p in json.loads(r.stdout).get("items",[]):
                ph=p.get("status",{}).get("phase","Unknown")
                counts[ph]=counts.get(ph,0)+1
            for ph,v in counts.items(): pods.labels(org,cluster,ph).set(v)
        except Exception: pass

def collect():
    info.info({"version":"1","state_dir":str(STATE)})
    collect_git()
    for org,cluster,path in clusters():
        pc=process_count(org,cluster)
        processes.labels(org,cluster).set(pc)
        log=latest_log(path)
        text=""
        if log:
            last_log_age.labels(org,cluster).set(max(0,time.time()-log.stat().st_mtime))
            try: text=log.read_text(errors="replace")[-500000:]
            except Exception: text=""
        state_name="running" if pc else "idle"
        if re.search(r"Bootstrap.*(complete|successful)|Deployment successful", text, re.I): state_name="succeeded"
        if re.search(r"\b(ERROR|FAILED|FATAL|BLOCKED)\b", text): state_name="failed"
        for s in ("idle","running","succeeded","failed","blocked"):
            status.labels(org,cluster,s).set(1 if s==state_name else 0)
        for st,pat in STAGES:
            hit=bool(re.search(pat,text,re.I))
            stage.labels(org,cluster,st,"passed").set(1 if hit else 0)
        collect_k8s(org,cluster)

if __name__=="__main__":
    start_http_server(PORT, addr="127.0.0.1")
    while True:
        try: collect()
        except Exception: pass
        time.sleep(INTERVAL)
PY
chmod 0755 /opt/opencenter-monitoring/opencenter_exporter.py
chown -R "$RUN_USER":"$RUN_USER" /opt/opencenter-monitoring

log "Creating systemd services"
cat > /etc/systemd/system/node_exporter.service <<'EOF_NODE'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target
[Service]
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100 --collector.systemd --collector.processes
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
[Install]
WantedBy=multi-user.target
EOF_NODE

cat > /etc/systemd/system/prometheus.service <<EOF_PROM
[Unit]
Description=Prometheus
After=network-online.target
Wants=network-online.target
[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --storage.tsdb.retention.time=${PROM_RETENTION} --storage.tsdb.retention.size=${PROM_RETENTION_SIZE} --web.listen-address=127.0.0.1:9090 --web.enable-lifecycle
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/prometheus
[Install]
WantedBy=multi-user.target
EOF_PROM

cat > /etc/systemd/system/opencenter-exporter.service <<EOF_EXP
[Unit]
Description=OpenCenter Prometheus Exporter
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
Environment=OPENCENTER_CONFIG_DIR=${RUN_HOME}/.config/opencenter
Environment=OPENCENTER_STATE_DIR=${RUN_HOME}/.local/state/opencenter
Environment=OPENCENTER_EXPORTER_PORT=${EXPORTER_PORT}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/opt/opencenter-monitoring/venv/bin/python /opt/opencenter-monitoring/opencenter_exporter.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=false
[Install]
WantedBy=multi-user.target
EOF_EXP

log "Configuring Prometheus"
backup /etc/prometheus/prometheus.yml
cat > /etc/prometheus/prometheus.yml <<EOF_PROMCFG
global:
  scrape_interval: 15s
  evaluation_interval: 15s
rule_files:
  - /etc/prometheus/rules/*.yml
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:9090']
  - job_name: opencenter-host
    static_configs:
      - targets: ['127.0.0.1:9100']
  - job_name: opencenter-exporter
    static_configs:
      - targets: ['127.0.0.1:${EXPORTER_PORT}']
EOF_PROMCFG

cat > /etc/prometheus/rules/opencenter.yml <<'EOF_RULES'
groups:
- name: opencenter
  rules:
  - alert: OpenCenterExporterDown
    expr: up{job="opencenter-exporter"} == 0
    for: 2m
    labels: {severity: critical}
    annotations:
      summary: OpenCenter exporter is down
  - alert: OpenCenterDuplicateDeployment
    expr: opencenter_deployment_processes > 1
    for: 30s
    labels: {severity: critical}
    annotations:
      summary: Multiple OpenCenter deployment processes detected
  - alert: OpenCenterDeploymentFailed
    expr: opencenter_deployment_status{status="failed"} == 1
    for: 1m
    labels: {severity: critical}
    annotations:
      summary: OpenCenter deployment failed
  - alert: OpenCenterNodeNotReady
    expr: opencenter_cluster_node_ready == 0
    for: 5m
    labels: {severity: critical}
    annotations:
      summary: OpenCenter Kubernetes node not ready
EOF_RULES
chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
chmod 0640 /etc/prometheus/prometheus.yml /etc/prometheus/rules/opencenter.yml

log "Provisioning Grafana datasource and dashboards"
install -d -o root -g grafana -m 0750 /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards
install -d -o grafana -g grafana -m 0750 /var/lib/grafana/dashboards/opencenter
cat > /etc/grafana/provisioning/datasources/opencenter-prometheus.yml <<'EOF_DS'
apiVersion: 1
datasources:
- name: Prometheus
  uid: prometheus
  type: prometheus
  access: proxy
  url: http://127.0.0.1:9090
  isDefault: true
  editable: false
  jsonData:
    timeInterval: 15s
EOF_DS
cat > /etc/grafana/provisioning/dashboards/opencenter.yml <<'EOF_DP'
apiVersion: 1
providers:
- name: OpenCenter
  orgId: 1
  folder: OpenCenter
  type: file
  disableDeletion: false
  allowUiUpdates: true
  updateIntervalSeconds: 30
  options:
    path: /var/lib/grafana/dashboards/opencenter
EOF_DP

make_dashboard(){
  local uid="$1" title="$2" body="$3"
  cat > "/var/lib/grafana/dashboards/opencenter/${uid}.json" <<EOF_DASH
{
  "uid":"${uid}","title":"${title}","tags":["opencenter"],"timezone":"browser","schemaVersion":39,"version":1,"refresh":"10s",
  "templating":{"list":[
    {"name":"org","type":"query","datasource":{"type":"prometheus","uid":"prometheus"},"query":{"query":"label_values(opencenter_deployment_status, org)"},"includeAll":true,"multi":true},
    {"name":"cluster","type":"query","datasource":{"type":"prometheus","uid":"prometheus"},"query":{"query":"label_values(opencenter_deployment_status{org=~\"\$org\"}, cluster)"},"includeAll":true,"multi":true}
  ]},
  "panels":${body}
}
EOF_DASH
}

make_dashboard "opencenter-deployment" "OpenCenter Deployment" '[
 {"id":1,"type":"stat","title":"Deployment processes","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"sum(opencenter_deployment_processes{org=~\"$org\",cluster=~\"$cluster\"})"}],"gridPos":{"x":0,"y":0,"w":6,"h":5}},
 {"id":2,"type":"stat","title":"Failed deployments","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"sum(opencenter_deployment_status{org=~\"$org\",cluster=~\"$cluster\",status=\"failed\"})"}],"gridPos":{"x":6,"y":0,"w":6,"h":5}},
 {"id":3,"type":"timeseries","title":"Deployment state","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"opencenter_deployment_status{org=~\"$org\",cluster=~\"$cluster\"}","legendFormat":"{{org}}/{{cluster}} {{status}}"}],"gridPos":{"x":0,"y":5,"w":12,"h":8}},
 {"id":4,"type":"table","title":"Stage status","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"opencenter_deployment_stage_status{org=~\"$org\",cluster=~\"$cluster\",status=\"passed\"}","format":"table","instant":true}],"gridPos":{"x":12,"y":0,"w":12,"h":13}}
]'

make_dashboard "opencenter-cluster-overview" "OpenCenter Cluster Overview" '[
 {"id":1,"type":"stat","title":"Ready nodes","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"sum(opencenter_cluster_node_ready{org=~\"$org\",cluster=~\"$cluster\"})"}],"gridPos":{"x":0,"y":0,"w":6,"h":5}},
 {"id":2,"type":"piechart","title":"Pods by phase","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"sum by (phase) (opencenter_cluster_pods{org=~\"$org\",cluster=~\"$cluster\"})","legendFormat":"{{phase}}"}],"gridPos":{"x":6,"y":0,"w":8,"h":8}},
 {"id":3,"type":"timeseries","title":"Host CPU","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"100 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100","legendFormat":"CPU %"}],"gridPos":{"x":14,"y":0,"w":10,"h":8}},
 {"id":4,"type":"timeseries","title":"Host memory","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"100 * (1 - node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes)","legendFormat":"Memory %"}],"gridPos":{"x":0,"y":8,"w":12,"h":8}},
 {"id":5,"type":"table","title":"Node readiness","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"opencenter_cluster_node_ready{org=~\"$org\",cluster=~\"$cluster\"}","format":"table","instant":true}],"gridPos":{"x":12,"y":8,"w":12,"h":8}}
]'

make_dashboard "opencenter-gitops" "OpenCenter GitOps" '[
 {"id":1,"type":"stat","title":"GitOps clean","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"min(opencenter_gitops_clean{org=~\"$org\"})"}],"gridPos":{"x":0,"y":0,"w":8,"h":6}},
 {"id":2,"type":"stat","title":"Unpushed commits","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"sum(opencenter_gitops_unpushed_commits{org=~\"$org\"})"}],"gridPos":{"x":8,"y":0,"w":8,"h":6}},
 {"id":3,"type":"timeseries","title":"GitOps status history","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"opencenter_gitops_clean{org=~\"$org\"}","legendFormat":"{{org}} clean"},{"expr":"opencenter_gitops_unpushed_commits{org=~\"$org\"}","legendFormat":"{{org}} unpushed"}],"gridPos":{"x":0,"y":6,"w":24,"h":9}}
]'

make_dashboard "opencenter-infrastructure" "OpenCenter Infrastructure" '[
 {"id":1,"type":"stat","title":"Prometheus targets up","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"sum(up)"}],"gridPos":{"x":0,"y":0,"w":6,"h":5}},
 {"id":2,"type":"timeseries","title":"Disk usage","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"100*(1-node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay\"}/node_filesystem_size_bytes{fstype!~\"tmpfs|overlay\"})","legendFormat":"{{mountpoint}}"}],"gridPos":{"x":0,"y":5,"w":12,"h":8}},
 {"id":3,"type":"timeseries","title":"Network throughput","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"rate(node_network_receive_bytes_total{device!=\"lo\"}[5m])","legendFormat":"RX {{device}}"},{"expr":"rate(node_network_transmit_bytes_total{device!=\"lo\"}[5m])","legendFormat":"TX {{device}}"}],"gridPos":{"x":12,"y":5,"w":12,"h":8}},
 {"id":4,"type":"table","title":"Scrape targets","datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"up","format":"table","instant":true}],"gridPos":{"x":6,"y":0,"w":18,"h":5}}
]'

chown -R grafana:grafana /var/lib/grafana/dashboards/opencenter
chmod 0640 /etc/grafana/provisioning/datasources/opencenter-prometheus.yml /etc/grafana/provisioning/dashboards/opencenter.yml

log "Configuring Grafana listener"
backup /etc/grafana/grafana.ini
sed -ri "s|^;?http_addr =.*|http_addr = ${GRAFANA_BIND}|" /etc/grafana/grafana.ini
sed -ri "s|^;?http_port =.*|http_port = ${GRAFANA_PORT}|" /etc/grafana/grafana.ini

log "Validating configuration"
/usr/local/bin/promtool check config /etc/prometheus/prometheus.yml
/usr/local/bin/promtool check rules /etc/prometheus/rules/opencenter.yml
for f in /var/lib/grafana/dashboards/opencenter/*.json; do jq empty "$f"; done

log "Starting services"
systemctl daemon-reload
systemctl enable --now node_exporter prometheus opencenter-exporter grafana-server
sleep 8

log "Running health checks"
for svc in node_exporter prometheus opencenter-exporter grafana-server; do
  systemctl is-active --quiet "$svc" || { journalctl -u "$svc" -n 80 --no-pager; exit 1; }
done
curl -fsS http://127.0.0.1:9100/metrics >/dev/null
curl -fsS http://127.0.0.1:9090/-/ready >/dev/null
curl -fsS "http://127.0.0.1:${EXPORTER_PORT}/metrics" | grep -q '^opencenter_'
curl -fsS "http://127.0.0.1:${GRAFANA_PORT}/api/health" | jq -e '.database == "ok"' >/dev/null

cat <<EOF_DONE

============================================================
OpenCenter monitoring installation completed successfully.

Grafana:            http://SERVER_IP:${GRAFANA_PORT}
Prometheus local:   http://127.0.0.1:9090
Node Exporter:      http://127.0.0.1:9100/metrics
OpenCenter metrics: http://127.0.0.1:${EXPORTER_PORT}/metrics

Grafana dashboards folder: OpenCenter
  - OpenCenter Deployment
  - OpenCenter Cluster Overview
  - OpenCenter GitOps
  - OpenCenter Infrastructure

Initial Grafana login is normally admin/admin; Grafana will require
changing the password on first login.

Useful live logs:
  sudo journalctl -fu opencenter-exporter
  sudo journalctl -fu prometheus
  sudo journalctl -fu grafana-server

For secure remote access without opening port ${GRAFANA_PORT}:
  ssh -L ${GRAFANA_PORT}:127.0.0.1:${GRAFANA_PORT} ${RUN_USER}@SERVER_IP
============================================================
EOF_DONE