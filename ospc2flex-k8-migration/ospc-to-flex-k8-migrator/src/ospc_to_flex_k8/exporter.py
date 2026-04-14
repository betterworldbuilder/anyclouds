"""
Exporter — Stage 1: SSH to OSPC master and export all cluster resources.

Architecture rule
-----------------
Stage 1 MUST use remote-master mode.
All kubectl/helm commands run on the OSPC master node via SSH.
Results are copied back to the local output directory via scp.
The remote temp directory is cleaned up unless KEEP_REMOTE_EXPORT=true.

Required inputs: OSPC_MASTER_IP, SSH_USER, SSH_KEY_PATH, OUTPUT_DIR

Remote temp path:  /tmp/ospc-k8-export-<timestamp>/
Local output path: output/<timestamp>/export/
"""
from __future__ import annotations

import json
import logging
import os
import shlex
import subprocess
import textwrap
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from .io_utils import ensure_dir, run_cmd, dump_json
from .models import ClusterInventory, ExportConfig, HelmRelease

log = logging.getLogger(__name__)

# ── Resource types to export per namespace ────────────────────────────────────
_NS_RESOURCE_TYPES: List[str] = [
    "serviceaccounts",
    "configmaps",
    "secrets",
    "services",
    "endpoints",
    "persistentvolumeclaims",
    "deployments",
    "statefulsets",
    "daemonsets",
    "replicasets",
    "jobs",
    "cronjobs",
    "ingresses",
    "networkpolicies",
    "roles",
    "rolebindings",
    "horizontalpodautoscalers",
    "poddisruptionbudgets",
]

# Cluster-scoped (non-namespaced) resource types
_CLUSTER_RESOURCE_TYPES: List[str] = [
    "namespaces",
    "storageclasses",
    "customresourcedefinitions",
    "clusterroles",
    "clusterrolebindings",
    "persistentvolumes",
    "ingressclasses",
]


# ── SSH helpers ───────────────────────────────────────────────────────────────

def _ssh_base(cfg: ExportConfig) -> List[str]:
    """Return the base SSH command list for non-interactive use."""
    return [
        "ssh",
        "-i", cfg.ssh_key_path,
        "-p", str(cfg.ssh_port),
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=30",
        "-o", "BatchMode=yes",
        f"{cfg.ssh_user}@{cfg.ospc_master_ip}",
    ]


def ssh_run(
    cfg: ExportConfig,
    remote_cmd: str,
    capture: bool = True,
    timeout: int = 120,
    check: bool = False,
) -> Tuple[int, str, str]:
    """
    Run a command on the OSPC master via SSH.

    Args:
        cfg:        Export configuration.
        remote_cmd: Shell command string to execute on the remote host.
        capture:    Capture stdout/stderr instead of streaming.
        timeout:    Seconds before timeout.
        check:      Raise RuntimeError on non-zero exit.

    Returns:
        (returncode, stdout, stderr)
    """
    cmd = _ssh_base(cfg) + [remote_cmd]
    try:
        if capture:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=timeout
            )
        else:
            result = subprocess.run(cmd, timeout=timeout)
        rc = result.returncode
        out = result.stdout.strip() if capture else ""
        err = result.stderr.strip() if capture else ""
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"SSH command timed out ({timeout}s): {remote_cmd}")
    except FileNotFoundError:
        raise RuntimeError("ssh binary not found on PATH")

    if check and rc != 0:
        raise RuntimeError(
            f"Remote command failed (exit {rc}): {remote_cmd}\nstderr: {err}"
        )
    return rc, out, err


def scp_get(
    cfg: ExportConfig,
    remote_path: str,
    local_path: Path,
    recursive: bool = True,
    timeout: int = 600,
) -> bool:
    """
    Copy files from the OSPC master to the local machine via scp.

    Args:
        cfg:         Export configuration.
        remote_path: Absolute path on the remote host.
        local_path:  Local destination path.
        recursive:   Use -r flag.
        timeout:     Seconds before timeout.

    Returns:
        True on success.
    """
    ensure_dir(local_path.parent)
    flags = ["-r"] if recursive else []
    cmd = [
        "scp",
        "-i", cfg.ssh_key_path,
        "-P", str(cfg.ssh_port),
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=30",
        "-o", "BatchMode=yes",
    ] + flags + [
        f"{cfg.ssh_user}@{cfg.ospc_master_ip}:{remote_path}",
        str(local_path),
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        log.error("scp timed out after %ds for %s", timeout, remote_path)
        return False
    if result.returncode != 0:
        log.error("scp failed: %s", result.stderr.strip())
        return False
    return True


def test_ssh_connection(cfg: ExportConfig) -> bool:
    """
    Verify SSH connectivity to the OSPC master.

    Returns True if connection is successful and a test command works.
    """
    log.info("Testing SSH connection to %s@%s:%d …",
             cfg.ssh_user, cfg.ospc_master_ip, cfg.ssh_port)
    rc, out, err = ssh_run(cfg, "echo ssh-ok", timeout=cfg.ssh_timeout)
    if rc != 0 or "ssh-ok" not in out:
        log.error("SSH connection failed: rc=%d err=%s", rc, err)
        return False
    log.info("SSH connection OK")
    return True


def test_kubectl_remote(cfg: ExportConfig) -> bool:
    """Verify kubectl is available and works on the remote master."""
    rc, out, err = ssh_run(cfg, "kubectl version --client --short 2>/dev/null || kubectl version --client", timeout=30)
    if rc != 0:
        log.error("kubectl not available on remote: %s", err)
        return False
    log.info("kubectl OK on remote: %s", out.splitlines()[0] if out else "unknown version")
    return True


def test_helm_remote(cfg: ExportConfig) -> Tuple[bool, str]:
    """
    Check if helm is installed on the remote master.

    Returns (available, version_string).
    """
    rc, out, err = ssh_run(cfg, "helm version --short 2>/dev/null", timeout=30)
    if rc != 0:
        log.warning("helm not available on remote master — Helm exports will be skipped")
        return False, ""
    ver = out.strip()
    log.info("helm OK on remote: %s", ver)
    return True, ver


# ── Remote export script builder ──────────────────────────────────────────────

def _build_remote_export_script(remote_dir: str, warnings_file: str) -> str:
    """
    Build the full bash script that runs on the OSPC master.

    The script exports all resources into subdirectories under remote_dir
    and writes a warnings.txt file for any resources that could not be exported.
    """
    ns_types = " ".join(_NS_RESOURCE_TYPES)
    cluster_types = " ".join(_CLUSTER_RESOURCE_TYPES)

    return textwrap.dedent(f"""\
        #!/usr/bin/env bash
        set -euo pipefail
        EXPORT_DIR="{remote_dir}"
        WARN_FILE="{warnings_file}"
        echo "" > "$WARN_FILE"

        mkdir -p "$EXPORT_DIR/manifests/cluster" \\
                 "$EXPORT_DIR/manifests/namespaces" \\
                 "$EXPORT_DIR/helm" \\
                 "$EXPORT_DIR/images" \\
                 "$EXPORT_DIR/logs"

        log() {{ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$EXPORT_DIR/logs/export.log"; }}
        warn() {{ echo "WARN: $*" | tee -a "$WARN_FILE" >> "$EXPORT_DIR/logs/export.log"; }}

        # ── Cluster info ──────────────────────────────────────────────────────
        log "Collecting cluster info …"
        kubectl version -o json 2>/dev/null > "$EXPORT_DIR/cluster-version.json" || warn "kubectl version failed"
        kubectl cluster-info 2>/dev/null > "$EXPORT_DIR/cluster-info.txt" || warn "cluster-info failed"
        kubectl get nodes -o wide 2>/dev/null > "$EXPORT_DIR/nodes.txt" || warn "get nodes failed"
        kubectl get nodes -o json 2>/dev/null > "$EXPORT_DIR/nodes.json" || warn "get nodes json failed"

        # Copy kubeconfig if available
        if [ -f "$HOME/.kube/config" ]; then
            cp "$HOME/.kube/config" "$EXPORT_DIR/kubeconfig-ospc" 2>/dev/null || warn "kubeconfig copy failed"
        elif [ -n "${{KUBECONFIG:-}}" ] && [ -f "$KUBECONFIG" ]; then
            cp "$KUBECONFIG" "$EXPORT_DIR/kubeconfig-ospc" 2>/dev/null || warn "kubeconfig copy failed"
        else
            warn "No kubeconfig found — kubeconfig-ospc not exported"
        fi

        # ── Cluster-scoped resources ──────────────────────────────────────────
        log "Exporting cluster-scoped resources …"
        for RTYPE in {cluster_types}; do
            log "  cluster: $RTYPE"
            kubectl get "$RTYPE" -o yaml 2>/dev/null \\
                > "$EXPORT_DIR/manifests/cluster/${{RTYPE}}.yaml" \\
                || warn "cluster resource failed: $RTYPE"
        done

        # ── Namespace list ────────────────────────────────────────────────────
        log "Collecting namespace list …"
        NS_LIST=$(kubectl get ns -o jsonpath='{{range .items[*]}}{{.metadata.name}}\\n{{end}}' 2>/dev/null || true)
        echo "$NS_LIST" > "$EXPORT_DIR/namespace-list.txt"

        # ── Per-namespace resources ───────────────────────────────────────────
        while IFS= read -r NS; do
            [ -z "$NS" ] && continue
            # Skip system namespaces
            case "$NS" in kube-system|kube-public|kube-node-lease) continue ;; esac
            log "  namespace: $NS"
            mkdir -p "$EXPORT_DIR/manifests/namespaces/$NS"
            for RTYPE in {ns_types}; do
                kubectl get "$RTYPE" -n "$NS" -o yaml 2>/dev/null \\
                    > "$EXPORT_DIR/manifests/namespaces/$NS/${{RTYPE}}.yaml" \\
                    || true   # non-fatal: resource type may not exist in this NS
            done
        done < "$EXPORT_DIR/namespace-list.txt"

        # ── Image inventory ───────────────────────────────────────────────────
        log "Collecting image inventory …"
        kubectl get pods -A -o jsonpath='{{range .items[*]}}{{range .spec.containers[*]}}{{.image}}\\n{{end}}{{range .spec.initContainers[*]}}{{.image}}\\n{{end}}{{end}}' \\
            2>/dev/null | sort -u > "$EXPORT_DIR/images/images.txt" || warn "image inventory failed"

        # ── Helm inventory ────────────────────────────────────────────────────
        if command -v helm &>/dev/null; then
            log "Exporting Helm releases …"
            helm list -A -o json 2>/dev/null > "$EXPORT_DIR/helm/releases.json" || warn "helm list failed"
            RELEASES=$(helm list -A -o json 2>/dev/null | python3 -c \\
                "import sys,json; [print(r['name']+'|'+r['namespace']) for r in json.load(sys.stdin)]" 2>/dev/null || true)
            while IFS='|' read -r RNAME RNS; do
                [ -z "$RNAME" ] && continue
                mkdir -p "$EXPORT_DIR/helm/$RNS/$RNAME"
                helm get values "$RNAME" -n "$RNS" -o yaml 2>/dev/null \\
                    > "$EXPORT_DIR/helm/$RNS/$RNAME/values.yaml" || warn "helm get values failed: $RNAME"
                helm get manifest "$RNAME" -n "$RNS" 2>/dev/null \\
                    > "$EXPORT_DIR/helm/$RNS/$RNAME/manifest.yaml" || warn "helm get manifest failed: $RNAME"
            done <<< "$RELEASES"
        else
            warn "helm not found — skipping Helm export"
        fi

        # ── Summary ───────────────────────────────────────────────────────────
        log "Writing summary …"
        NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo 0)
        NS_COUNT=$(cat "$EXPORT_DIR/namespace-list.txt" | grep -vc '^$' || echo 0)
        K8S_VER=$(kubectl version -o json 2>/dev/null | python3 -c \\
            "import sys,json; d=json.load(sys.stdin); print(d.get('serverVersion',{{}}).get('gitVersion','unknown'))" \\
            2>/dev/null || echo "unknown")
        IMAGE_COUNT=$(wc -l < "$EXPORT_DIR/images/images.txt" 2>/dev/null || echo 0)
        HELM_COUNT=$(python3 -c \\
            "import json,sys; d=json.load(open('$EXPORT_DIR/helm/releases.json')); print(len(d))" \\
            2>/dev/null || echo 0)
        WARN_COUNT=$(grep -vc '^$' "$WARN_FILE" 2>/dev/null || echo 0)

        python3 - <<PYEOF
import json, datetime
summary = {{
    "export_timestamp": datetime.datetime.utcnow().isoformat() + "Z",
    "kubernetes_version": "$K8S_VER",
    "node_count": int("$NODE_COUNT".strip()),
    "namespace_count": int("$NS_COUNT".strip()),
    "image_count": int("$IMAGE_COUNT".strip()),
    "helm_release_count": int("$HELM_COUNT".strip()),
    "warning_count": int("$WARN_COUNT".strip()),
    "export_dir": "$EXPORT_DIR",
}}
with open("$EXPORT_DIR/summary.json", "w") as f:
    json.dump(summary, f, indent=2)
PYEOF

        # Human-readable inventory
        {{
        echo "OSPC Kubernetes Cluster Export Inventory"
        echo "Generated: $(date -u)"
        echo "========================================"
        echo "Kubernetes version: $K8S_VER"
        echo "Node count:         $NODE_COUNT"
        echo "Namespace count:    $NS_COUNT"
        echo "Image count:        $IMAGE_COUNT"
        echo "Helm release count: $HELM_COUNT"
        echo "Warnings:           $WARN_COUNT"
        echo ""
        echo "Namespaces exported:"
        cat "$EXPORT_DIR/namespace-list.txt" | grep -v '^$' | sed 's/^/  /'
        echo ""
        echo "Images:"
        head -50 "$EXPORT_DIR/images/images.txt" | sed 's/^/  /'
        echo ""
        if [ "$WARN_COUNT" -gt 0 ]; then
            echo "Warnings:"
            cat "$WARN_FILE" | grep -v '^$' | sed 's/^/  /'
        fi
        }} > "$EXPORT_DIR/inventory.txt"

        log "Export complete. Warnings: $WARN_COUNT"
        echo "EXPORT_DONE"
    """)


# ── Main export orchestrator ──────────────────────────────────────────────────

def export_cluster(
    cfg: ExportConfig,
    plan_namespaces: Optional[List[str]] = None,
) -> Tuple[Path, Dict[str, Any]]:
    """
    Stage 1: SSH to OSPC master, export all cluster resources, copy back locally.

    Workflow:
        1. Verify SSH + kubectl on remote master.
        2. Create remote temp directory.
        3. Run the remote export script.
        4. Copy results back via scp.
        5. Clean up remote temp dir (unless KEEP_REMOTE_EXPORT=true).
        6. Return (local_export_dir, summary_dict).

    Args:
        cfg:               Export configuration (master IP, SSH creds, output dir).
        plan_namespaces:   If set, only these namespaces are exported (informational;
                           the script-level filter removes kube-system etc).

    Returns:
        (local_export_dir, summary_dict)

    Raises:
        RuntimeError: If SSH connection or kubectl on remote fails hard.
    """
    timestamp = datetime.now(tz=timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    remote_dir = f"{cfg.remote_temp_base}/ospc-k8-export-{timestamp}"
    warnings_file = f"{remote_dir}/warnings.txt"

    local_export_dir = ensure_dir(Path(cfg.output_dir) / timestamp / "export")
    log_dir = ensure_dir(local_export_dir / "logs")

    log.info("=" * 60)
    log.info("Stage 1 — Export from OSPC  (remote master mode)")
    log.info("  Master:    %s@%s", cfg.ssh_user, cfg.ospc_master_ip)
    log.info("  Remote:    %s", remote_dir)
    log.info("  Local:     %s", local_export_dir)
    log.info("=" * 60)

    # ── Step 1: Validate SSH ──────────────────────────────────────────────────
    if not test_ssh_connection(cfg):
        raise RuntimeError(
            f"Cannot connect to OSPC master at {cfg.ospc_master_ip}. "
            "Check SSH_USER, SSH_KEY_PATH, and firewall rules."
        )

    # ── Step 2: Validate kubectl on remote ────────────────────────────────────
    if not test_kubectl_remote(cfg):
        raise RuntimeError(
            "kubectl is not available on the OSPC master. "
            "Ensure it is installed and on PATH for the SSH user."
        )

    helm_available, helm_ver = test_helm_remote(cfg)

    # ── Step 3: Create remote temp dir ───────────────────────────────────────
    rc, _, err = ssh_run(cfg, f"mkdir -p {remote_dir}", check=True)
    log.info("Remote export dir created: %s", remote_dir)

    # ── Step 4: Upload and run export script ─────────────────────────────────
    export_script = _build_remote_export_script(remote_dir, warnings_file)
    # Write script locally, copy to remote, execute
    local_script = local_export_dir / "remote_export.sh"
    local_script.write_text(export_script, encoding="utf-8")

    # Transfer script
    _scp_put(cfg, str(local_script), f"{remote_dir}/export.sh")

    log.info("Running remote export script (this may take several minutes) …")
    rc, out, err = ssh_run(
        cfg,
        f"bash {remote_dir}/export.sh",
        timeout=cfg.kubectl_timeout,
    )

    if rc != 0:
        log.error("Remote export script failed (rc=%d):\n%s\n%s", rc, out, err)
        raise RuntimeError(f"Remote export script exited with code {rc}")

    if "EXPORT_DONE" not in out:
        log.warning("Export script did not print EXPORT_DONE — output may be incomplete")

    # ── Step 5: Copy results back ─────────────────────────────────────────────
    log.info("Copying export results back to %s …", local_export_dir)
    ok = scp_get(cfg, f"{remote_dir}/*", local_export_dir, recursive=False)
    if not ok:
        # Try recursive fallback
        ok = scp_get(cfg, remote_dir, local_export_dir.parent, recursive=True)
    if not ok:
        raise RuntimeError("scp of remote export results failed")

    log.info("Export files copied locally.")

    # ── Step 6: Cleanup remote temp dir ──────────────────────────────────────
    if not cfg.keep_remote_export:
        log.info("Cleaning up remote temp dir: %s", remote_dir)
        ssh_run(cfg, f"rm -rf {shlex.quote(remote_dir)}", timeout=30)
    else:
        log.info("KEEP_REMOTE_EXPORT=true — leaving remote dir: %s", remote_dir)

    # ── Step 7: Load and return summary ──────────────────────────────────────
    summary_file = local_export_dir / "summary.json"
    summary: Dict[str, Any] = {}
    if summary_file.exists():
        try:
            summary = json.loads(summary_file.read_text())
        except Exception as exc:
            log.warning("Could not parse summary.json: %s", exc)
    else:
        log.warning("summary.json not found in export output")
        summary = {
            "export_timestamp": timestamp,
            "export_dir": str(local_export_dir),
            "warning": "summary.json was not generated — check export logs",
        }

    log.info("Stage 1 complete. Export at: %s", local_export_dir)
    if summary.get("warning_count", 0):
        log.warning("Export had %d warning(s). Check %s/warnings.txt",
                    summary["warning_count"], local_export_dir)

    return local_export_dir, summary


def _scp_put(cfg: ExportConfig, local_path: str, remote_path: str) -> bool:
    """Upload a local file to the OSPC master via scp."""
    cmd = [
        "scp",
        "-i", cfg.ssh_key_path,
        "-P", str(cfg.ssh_port),
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=30",
        "-o", "BatchMode=yes",
        local_path,
        f"{cfg.ssh_user}@{cfg.ospc_master_ip}:{remote_path}",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        log.error("scp upload failed: %s", result.stderr.strip())
        return False
    return True


# ── Export config from env ────────────────────────────────────────────────────

def export_config_from_env(output_dir: str) -> ExportConfig:
    """
    Build an ExportConfig from environment variables.

    Required env vars:
        OSPC_MASTER_IP
        SSH_USER
        SSH_KEY_PATH

    Optional:
        SSH_PORT           (default: 22)
        SSH_TIMEOUT        (default: 30)
        KUBECTL_TIMEOUT    (default: 300)
        KEEP_REMOTE_EXPORT (default: false)
        REMOTE_TEMP_BASE   (default: /tmp)
    """
    missing = [v for v in ("OSPC_MASTER_IP", "SSH_USER", "SSH_KEY_PATH")
               if not os.environ.get(v)]
    if missing:
        raise RuntimeError(
            f"Missing required environment variables: {', '.join(missing)}\n"
            "Set OSPC_MASTER_IP, SSH_USER, SSH_KEY_PATH before running export."
        )

    return ExportConfig(
        ospc_master_ip=os.environ["OSPC_MASTER_IP"],
        ssh_user=os.environ["SSH_USER"],
        ssh_key_path=os.environ["SSH_KEY_PATH"],
        output_dir=output_dir,
        ssh_port=int(os.environ.get("SSH_PORT", "22")),
        ssh_timeout=int(os.environ.get("SSH_TIMEOUT", "30")),
        kubectl_timeout=int(os.environ.get("KUBECTL_TIMEOUT", "300")),
        keep_remote_export=os.environ.get("KEEP_REMOTE_EXPORT", "false").lower() == "true",
        remote_temp_base=os.environ.get("REMOTE_TEMP_BASE", "/tmp"),
    )
