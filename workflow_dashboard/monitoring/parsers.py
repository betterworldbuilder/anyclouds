"""Parsers that normalize logs and command output into structured JSON."""
from __future__ import annotations

import re
from typing import Any, Dict, List, Optional, Tuple

from .redaction import redact_line, strip_ansi

# ---------------------------------------------------------------------------
# Deployment pipeline definition (15 stages)
# ---------------------------------------------------------------------------
PIPELINE_STAGES: List[Tuple[str, str]] = [
    ("git_auth", "Git authentication"),
    ("git_sync", "Git fetch & synchronization"),
    ("generate", "Cluster manifest generation"),
    ("secrets", "Secret synchronization & encryption"),
    ("git_commit", "Git commit"),
    ("git_push", "Git push"),
    ("validate", "OpenCenter validation"),
    ("tofu_init", "OpenTofu initialization"),
    ("tofu_apply", "OpenTofu apply"),
    ("cloud_init", "Cloud-init readiness"),
    ("kubespray", "Kubespray installation"),
    ("kubeconfig", "Kubeconfig generation"),
    ("flux_bootstrap", "Flux bootstrap"),
    ("services", "Platform service reconciliation"),
    ("final_validate", "Final validation"),
]

_STEP_ID_TO_STAGE = [
    (re.compile(r"tofu-init"), "tofu_init"),
    (re.compile(r"tofu-apply|tofu-plan"), "tofu_apply"),
    (re.compile(r"cloud[-_]?init"), "cloud_init"),
    (re.compile(r"kubespray|ansible"), "kubespray"),
    (re.compile(r"kubeconfig"), "kubeconfig"),
    (re.compile(r"network-plugin|calico|cni"), "flux_bootstrap"),
    (re.compile(r"flux"), "flux_bootstrap"),
    (re.compile(r"service|reconcil|platform"), "services"),
    (re.compile(r"validat"), "final_validate"),
]

# Bootstrap log markers, e.g.:
#   2026-07-15T16:25:10Z step started: opentofu-init - Initialize OpenTofu
#   2026-07-15T16:25:11Z step completed: opentofu-init
#   2026-07-15T17:28:05Z step failed: openstack-install-network-plugin: helm install ...
# (the "[k/n] → ..." markers exist only on CLI stdout, never in the log file)
_STEP_START = re.compile(r"step started:\s*(?P<step>[a-z0-9_-]+)(?:\s*-\s*(?P<title>.+))?")
_STEP_DONE = re.compile(r"step completed:\s*(?P<step>[a-z0-9_-]+)")
_STEP_FAIL = re.compile(r"step failed:\s*(?P<step>[a-z0-9_-]+):?\s*(?P<msg>.*)")
_BOOTSTRAP_START = re.compile(r"(?i)bootstrap started for ")
_BOOTSTRAP_FAIL = re.compile(r"(?i)bootstrap failed")
_BOOTSTRAP_OK = re.compile(r"(?i)bootstrap (?:succeeded|completed|complete|finished)")
_TS_LINE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s")


def _iso_delta(start: str, end: str) -> Optional[str]:
    """Human duration between two log timestamps like 2026-07-15T16:25:10Z."""
    import datetime as _dt

    try:
        fmt = "%Y-%m-%dT%H:%M:%SZ"
        seconds = int((_dt.datetime.strptime(end, fmt) - _dt.datetime.strptime(start, fmt)).total_seconds())
    except (ValueError, TypeError):
        return None
    if seconds < 0:
        return None
    if seconds >= 3600:
        return "%dh%02dm" % (seconds // 3600, (seconds % 3600) // 60)
    if seconds >= 60:
        return "%dm%02ds" % (seconds // 60, seconds % 60)
    return "%ds" % seconds


def stage_for_step_id(step_id: str) -> str:
    for pattern, stage in _STEP_ID_TO_STAGE:
        if pattern.search(step_id or ""):
            return stage
    return "services"


def new_parse_state() -> Dict[str, Any]:
    """Fresh incremental parse state for one bootstrap log."""
    stages: Dict[str, Dict[str, Any]] = {
        sid: {"id": sid, "title": title, "status": "pending", "message": "", "duration": None, "evidence": []}
        for sid, title in PIPELINE_STAGES
    }
    return {
        "started": False, "finished": False, "failed_step": "", "active_step": "",
        "stages": stages, "tofu": parse_empty_tofu(), "ansible": {"last_task": "", "recap": {}, "unreachable": []},
        "cloud_init": {"status": "unknown", "attempts": 0, "detail": ""},
        "errors": [], "warnings": [],
    }


def parse_bootstrap_log(text: str, state: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Parse bootstrap log text into stage states; feeds an existing state when
    given, so callers can parse only newly appended bytes (tail -F semantics)."""
    result = state if state is not None else new_parse_state()
    if not text:
        return result
    stages = result["stages"]

    for raw in text.splitlines():
        line = strip_ansi(raw).rstrip()
        if not line:
            continue
        ts_match = _TS_LINE.match(line)
        line_ts = ts_match.group(1) if ts_match else None

        if _BOOTSTRAP_START.search(line):
            result["started"] = True
        if "Configuration valid" in line:
            stages["validate"]["status"] = "passed"
        m = _STEP_FAIL.search(line)
        if m:
            stage = stage_for_step_id(m.group("step"))
            stages[stage]["status"] = "failed"
            stages[stage]["message"] = redact_line((m.group("msg") or line)[-300:])
            result["failed_step"] = m.group("step")
            result["active_step"] = ""
        else:
            m = _STEP_DONE.search(line)
            if m:
                stage = stage_for_step_id(m.group("step"))
                if stages[stage]["status"] != "failed":
                    stages[stage]["status"] = "passed"
                    started_at = stages[stage].get("started_at_ts")
                    if line_ts and started_at:
                        stages[stage]["duration"] = _iso_delta(started_at, line_ts)
                if result["active_step"] == m.group("step"):
                    result["active_step"] = ""
            else:
                m = _STEP_START.search(line)
                if m:
                    stage = stage_for_step_id(m.group("step"))
                    if stages[stage]["status"] in ("pending", "passed"):
                        stages[stage]["status"] = "running"
                    if line_ts:
                        stages[stage]["started_at_ts"] = line_ts
                        stages[stage]["started_at"] = line_ts
                    if m.group("title"):
                        stages[stage]["message"] = m.group("title")[:160]
                    result["active_step"] = m.group("step")

        _feed_tofu(result["tofu"], line)
        _feed_ansible(result["ansible"], line)
        _feed_cloud_init(result["cloud_init"], line)

        if re.search(r"(?i)\berror\b|✗|\bfatal\b|\[BLOCKED\]", line):
            classified = classify_error_line(line)
            if classified:
                classified["evidence"] = redact_line(line[-400:])
                result["errors"].append(classified)
        elif re.search(r"(?i)\bwarn(ing)?\b", line):
            result["warnings"].append(redact_line(line[-300:]))

        if _BOOTSTRAP_FAIL.search(line):
            result["finished"] = True
            result["success"] = False
        elif _BOOTSTRAP_OK.search(line):
            result["finished"] = True
            result["success"] = True

    # Kubespray and cloud-init run inside the opentofu-apply step; surface
    # them as their own pipeline stages from their sub-signals.
    if result["ansible"].get("last_task"):
        if stages["kubespray"]["status"] == "pending":
            stages["kubespray"]["status"] = "running"
        stages["kubespray"]["message"] = result["ansible"]["last_task"]
        recap = result["ansible"].get("recap") or {}
        if recap and all(h.get("failed", 0) == 0 and h.get("unreachable", 0) == 0 for h in recap.values()):
            stages["kubespray"]["status"] = "passed"
        elif any(h.get("failed", 0) or h.get("unreachable", 0) for h in recap.values()):
            stages["kubespray"]["status"] = "failed"
        if stages["cloud_init"]["status"] in ("pending", "running"):
            # Ansible reaching the hosts implies cloud-init/SSH became ready.
            stages["cloud_init"]["status"] = "passed"
    elif result["cloud_init"].get("status") == "running":
        stages["cloud_init"]["status"] = "running"
    elif result["cloud_init"].get("status") == "error":
        stages["cloud_init"]["status"] = "failed"
    if stages["kubespray"]["status"] == "passed" and stages["tofu_apply"]["status"] == "running":
        stages["tofu_apply"]["message"] = "kubespray finished; finalizing OpenTofu step"

    # Keep only the most recent few of each list to bound payload size.
    result["errors"] = result["errors"][-25:]
    result["warnings"] = result["warnings"][-25:]
    return result


# ---------------------------------------------------------------------------
# OpenTofu event parsing
# ---------------------------------------------------------------------------
_TOFU_EVENTS = [
    ("creating", re.compile(r"^(?P<res>[\w.\[\]\"-]+): Creating\.")),
    ("still_creating", re.compile(r"^(?P<res>[\w.\[\]\"-]+): Still creating")),
    ("created", re.compile(r"^(?P<res>[\w.\[\]\"-]+): Creation complete")),
    ("modifying", re.compile(r"^(?P<res>[\w.\[\]\"-]+): Modifying\.")),
    ("destroying", re.compile(r"^(?P<res>[\w.\[\]\"-]+): Destroying\.")),
    ("destroyed", re.compile(r"^(?P<res>[\w.\[\]\"-]+): Destruction complete")),
]


def parse_empty_tofu() -> Dict[str, Any]:
    return {"creating": [], "created": [], "modifying": [], "destroying": [],
            "errors": [], "lock": "", "summary": ""}


def _feed_tofu(state: Dict[str, Any], line: str) -> None:
    for kind, pattern in _TOFU_EVENTS:
        m = pattern.match(line.strip())
        if not m:
            continue
        res = m.group("res")
        if kind == "creating" and res not in state["creating"]:
            state["creating"].append(res)
        elif kind == "created":
            if res in state["creating"]:
                state["creating"].remove(res)
            if res not in state["created"]:
                state["created"].append(res)
        elif kind == "modifying" and res not in state["modifying"]:
            state["modifying"].append(res)
        elif kind == "destroying" and res not in state["destroying"]:
            state["destroying"].append(res)
        return
    if re.search(r"Error acquiring the state lock|state lock", line):
        state["lock"] = redact_line(line[-200:])
    if re.match(r"\s*Error:", line):
        state["errors"].append(redact_line(line.strip()[-300:]))
        state["errors"] = state["errors"][-10:]
    m = re.search(r"Apply complete! Resources: (.+)", line)
    if m:
        state["summary"] = m.group(1)


# ---------------------------------------------------------------------------
# Ansible / cloud-init parsing
# ---------------------------------------------------------------------------
def _feed_ansible(state: Dict[str, Any], line: str) -> None:
    m = re.search(r"TASK \[(.+?)\]", line)
    if m:
        state["last_task"] = m.group(1)[:160]
    # Log lines are prefixed by tofu's "(local-exec):", so no start anchor.
    m = re.search(r"(?P<host>[\w.-]+)\s*:\s*ok=(\d+)\s+changed=(\d+)\s+unreachable=(\d+)\s+failed=(\d+)", line)
    if m:
        state["recap"][m.group("host")] = {
            "ok": int(m.group(2)), "changed": int(m.group(3)),
            "unreachable": int(m.group(4)), "failed": int(m.group(5)),
        }
    if "UNREACHABLE!" in line:
        host = line.split("|")[0].strip().split(" ")[-1]
        if host and host not in state["unreachable"]:
            state["unreachable"].append(host)


def _feed_cloud_init(state: Dict[str, Any], line: str) -> None:
    low = line.lower()
    if "cloud-init" not in low:
        return
    state["detail"] = redact_line(line[-200:])
    if re.search(r"status: done|cloud-init.*done", low):
        state["status"] = "done"
    elif re.search(r"status: running|waiting for cloud-init", low):
        state["status"] = "running"
        state["attempts"] += 1
    elif "error" in low:
        state["status"] = "error"


# ---------------------------------------------------------------------------
# Error intelligence
# ---------------------------------------------------------------------------
_ERROR_RULES: List[Tuple[str, re.Pattern, str, str, bool, str]] = [
    # (category, pattern, root cause, safe next command, resumable, from_step)
    ("quota", re.compile(r"(?i)OverQuota|quota exceeded|exceeds available quota"),
     "OpenStack project quota exhausted for the requested resource.",
     "openstack quota show --usage", True, "opentofu-apply"),
    ("image", re.compile(r"(?i)can not find requested image|image.*not found|No Image found"),
     "The configured Glance image no longer exists in this region.",
     "openstack image list --status active", True, "opentofu-apply"),
    ("scheduling", re.compile(r"(?i)NoValidHost|No valid host was found"),
     "Nova could not schedule the instance (capacity/flavor constraints).",
     "openstack flavor list", True, "opentofu-apply"),
    ("networking", re.compile(r"(?i)Multiple security_group matches|conflictingRequest.*security_group"),
     "Duplicate security groups with the same name exist; Nova resolves by name.",
     "openstack security group list", True, "opentofu-apply"),
    ("networking", re.compile(r"(?i)Key pair.*already exists"),
     "An orphaned Nova keypair with this name already exists.",
     "openstack keypair list", True, "opentofu-apply"),
    ("openstack_endpoint", re.compile(r"(?i)EndpointNotFound|Unable to establish connection|ConnectFailure|Service Unavailable"),
     "An OpenStack API endpoint is unreachable or misconfigured.",
     "openstack catalog list", True, ""),
    ("authentication", re.compile(r"(?i)401|Unauthorized|rejected the (saved )?token|authentication failed|credential"),
     "Cloud or Git credentials were rejected.",
     "opencenter cluster validate <org>/<cluster>", True, ""),
    ("gitops_dirty", re.compile(r"(?i)\[BLOCKED\].*GitOps|working tree.*dirty|uncommitted"),
     "The GitOps working tree has uncommitted changes.",
     "git -C <gitops-dir> status", True, ""),
    ("git", re.compile(r"(?i)non-fast-forward|rebase|merge conflict|failed to push"),
     "Git history conflict between local and remote GitOps branches.",
     "git -C <gitops-dir> status && git log --oneline -5", True, ""),
    ("cloud_init", re.compile(r"(?i)cloud-init.*(timeout|error|failed)"),
     "Cloud-init did not finish on one or more VMs.",
     "openstack console log show <server> | tail -50", True, "opentofu-apply"),
    ("ssh", re.compile(r"(?i)Permission denied \(publickey\)|Connection refused|Connection timed out.*ssh|UNREACHABLE"),
     "SSH connectivity to a node failed (key, security group or boot issue).",
     "openstack server list --name <cluster>", True, "kubespray"),
    ("ansible", re.compile(r"(?i)fatal:.*FAILED!|PLAY RECAP.*failed=[1-9]"),
     "Kubespray/Ansible task failed on at least one host.",
     "tail -100 <bootstrap-log>", True, "kubespray"),
    ("flux", re.compile(r"(?i)ensure CRDs are installed first|kustomization.*failed|helmrelease.*failed|flux.*error"),
     "Flux/network-plugin bootstrap failed (often a chart/CRD version mismatch).",
     "kubectl get kustomizations -n flux-system", True, "openstack-install-network-plugin"),
    ("kubernetes", re.compile(r"(?i)apiserver|connection to the server.*refused|nodes? NotReady"),
     "Kubernetes control-plane is unreachable or nodes are not ready.",
     "kubectl get nodes", True, ""),
]


def classify_error_line(line: str) -> Optional[Dict[str, Any]]:
    for category, pattern, cause, command, resumable, from_step in _ERROR_RULES:
        if pattern.search(line):
            return {
                "category": category,
                "root_cause": cause,
                "next_command": command,
                "resumable": resumable,
                "from_step": from_step,
                # Never recommend --break-lock while a deployment is running;
                # the monitor endpoint enforces this before display.
            }
    if re.search(r"(?i)error|✗|fatal", line):
        return {"category": "unknown", "root_cause": "Unclassified failure",
                "next_command": "", "resumable": False, "from_step": ""}
    return None


# ---------------------------------------------------------------------------
# Process list parsing
# ---------------------------------------------------------------------------
def parse_deploy_processes(ps_output: str, org: str, cluster: str) -> List[Dict[str, Any]]:
    """Extract `opencenter cluster deploy` processes for org/cluster from ps."""
    rows: List[Dict[str, Any]] = []
    target = "%s/%s" % (org, cluster)
    for line in (ps_output or "").splitlines():
        if "opencenter" not in line or "cluster deploy" not in line:
            continue
        if "grep" in line or "ps -eo" in line:
            continue
        if cluster not in line and target not in line:
            continue
        parts = line.split(None, 7)
        if len(parts) < 8:
            continue
        pid, ppid = parts[0], parts[1]
        lstart = " ".join(parts[2:7])
        try:
            etimes = int(parts[7].split(None, 1)[0])
            cmd = parts[7].split(None, 1)[1]
        except (ValueError, IndexError):
            continue
        rows.append({
            "pid": int(pid), "ppid": int(ppid), "started": lstart,
            "elapsed_seconds": etimes, "command": redact_line(cmd[:300]),
        })
    return rows


# ---------------------------------------------------------------------------
# Kubernetes / Flux / OpenStack JSON normalizers
# ---------------------------------------------------------------------------
def parse_nodes(data: Dict[str, Any]) -> List[Dict[str, Any]]:
    nodes = []
    for item in (data or {}).get("items", []):
        meta, status = item.get("metadata", {}), item.get("status", {})
        conditions = {c.get("type"): c.get("status") for c in status.get("conditions", [])}
        labels = meta.get("labels", {})
        role = "control-plane" if "node-role.kubernetes.io/control-plane" in labels else "worker"
        addresses = {a.get("type"): a.get("address") for a in status.get("addresses", [])}
        nodes.append({
            "name": meta.get("name"),
            "role": role,
            "ready": conditions.get("Ready") == "True",
            "internal_ip": addresses.get("InternalIP", ""),
            "external_ip": addresses.get("ExternalIP", ""),
            "cpu": status.get("capacity", {}).get("cpu", ""),
            "memory": status.get("capacity", {}).get("memory", ""),
            "kubelet_version": status.get("nodeInfo", {}).get("kubeletVersion", ""),
            "os_image": status.get("nodeInfo", {}).get("osImage", ""),
            "zone": labels.get("topology.kubernetes.io/zone", ""),
        })
    return nodes


def parse_pods(data: Dict[str, Any]) -> Dict[str, Any]:
    summary = {"total": 0, "running": 0, "pending": 0, "failed": 0, "succeeded": 0,
               "crashloop": 0, "imagepull": 0, "unknown": 0, "restarts": 0,
               "by_namespace": {}, "top_restarting": [], "problem_pods": []}
    restart_rows = []
    for item in (data or {}).get("items", []):
        summary["total"] += 1
        meta = item.get("metadata", {})
        ns = meta.get("namespace", "")
        phase = (item.get("status", {}).get("phase") or "Unknown").lower()
        summary["by_namespace"][ns] = summary["by_namespace"].get(ns, 0) + 1
        if phase in summary:
            summary[phase] += 1
        else:
            summary["unknown"] += 1
        restarts = 0
        problem = ""
        for cs in item.get("status", {}).get("containerStatuses", []) or []:
            restarts += int(cs.get("restartCount") or 0)
            waiting = (cs.get("state", {}) or {}).get("waiting", {}) or {}
            reason = waiting.get("reason", "")
            if reason == "CrashLoopBackOff":
                summary["crashloop"] += 1
                problem = reason
            elif reason in ("ImagePullBackOff", "ErrImagePull"):
                summary["imagepull"] += 1
                problem = reason
        summary["restarts"] += restarts
        if restarts:
            restart_rows.append({"pod": meta.get("name"), "namespace": ns, "restarts": restarts})
        if problem or phase in ("failed", "pending"):
            summary["problem_pods"].append({"pod": meta.get("name"), "namespace": ns,
                                            "phase": phase, "reason": problem})
    restart_rows.sort(key=lambda r: -r["restarts"])
    summary["top_restarting"] = restart_rows[:10]
    summary["problem_pods"] = summary["problem_pods"][:25]
    return summary


def _flux_condition(item: Dict[str, Any]) -> Tuple[bool, str, str]:
    ready, message = False, ""
    for cond in (item.get("status", {}) or {}).get("conditions", []) or []:
        if cond.get("type") == "Ready":
            ready = cond.get("status") == "True"
            message = cond.get("message", "")
    return ready, message, (item.get("status", {}) or {}).get("lastAppliedRevision", "") or \
        ((item.get("status", {}) or {}).get("artifact", {}) or {}).get("revision", "")


def parse_flux_objects(data: Dict[str, Any]) -> List[Dict[str, Any]]:
    rows = []
    for item in (data or {}).get("items", []):
        meta = item.get("metadata", {})
        ready, message, revision = _flux_condition(item)
        rows.append({
            "kind": item.get("kind", ""),
            "name": meta.get("name", ""),
            "namespace": meta.get("namespace", ""),
            "ready": ready,
            "suspended": bool(item.get("spec", {}).get("suspend")),
            "revision": revision,
            "message": redact_line(str(message)[:300]),
        })
    return rows


def parse_events(data: Dict[str, Any], limit: int = 50) -> List[Dict[str, Any]]:
    events = []
    for item in (data or {}).get("items", []):
        events.append({
            "namespace": item.get("metadata", {}).get("namespace", ""),
            "reason": item.get("reason", ""),
            "type": item.get("type", ""),
            "object": "%s/%s" % (item.get("involvedObject", {}).get("kind", ""),
                                 item.get("involvedObject", {}).get("name", "")),
            "message": redact_line(str(item.get("message", ""))[:300]),
            "last_seen": item.get("lastTimestamp") or item.get("eventTime") or "",
            "count": item.get("count", 1),
        })
    events.sort(key=lambda e: str(e.get("last_seen") or ""), reverse=True)
    return events[:limit]


def parse_servers(data: List[Dict[str, Any]], cluster: str) -> List[Dict[str, Any]]:
    rows = []
    for server in data or []:
        name = server.get("Name") or server.get("name") or ""
        if cluster not in name:
            continue
        networks = server.get("Networks") or {}
        ips: List[str] = []
        if isinstance(networks, dict):
            for values in networks.values():
                ips.extend(values if isinstance(values, list) else [values])
        rows.append({
            "name": name,
            "status": server.get("Status") or server.get("status", ""),
            "task_state": server.get("Task State") or "",
            "vm_state": server.get("Power State") or "",
            "host": server.get("Host") or "",
            "ips": ips,
            "flavor": server.get("Flavor Name") or server.get("Flavor") or "",
            "image": server.get("Image Name") or server.get("Image ID") or "",
            "fault": redact_line(str(server.get("Fault") or ""))[:200],
        })
    return rows


def parse_quota(data: Any) -> Dict[str, Any]:
    """Normalize `openstack quota show --usage -f json` output rows."""
    quotas: Dict[str, Any] = {}
    rows = data if isinstance(data, list) else []
    if isinstance(data, dict):
        rows = [{"Resource": k, **v} if isinstance(v, dict) else {"Resource": k, "Limit": v}
                for k, v in data.items()]
    for row in rows:
        name = str(row.get("Resource") or row.get("resource") or "").strip()
        if not name:
            continue
        limit = row.get("Limit", row.get("limit"))
        used = row.get("In Use", row.get("used", row.get("in_use")))
        try:
            limit = int(limit)
            used = int(used)
        except (TypeError, ValueError):
            continue
        ratio = round(used / limit, 3) if limit and limit > 0 else 0.0
        quotas[name] = {"limit": limit, "used": used, "ratio": ratio,
                        "alert": "critical" if ratio >= 0.95 else
                                 "warning" if ratio >= 0.85 else
                                 "notice" if ratio >= 0.70 else ""}
    return quotas


def parse_git_status(porcelain: str) -> Dict[str, Any]:
    info = {"branch": "", "upstream": "", "ahead": 0, "behind": 0,
            "clean": True, "dirty_files": []}
    for line in (porcelain or "").splitlines():
        if line.startswith("# branch.head"):
            info["branch"] = line.split(" ", 2)[-1]
        elif line.startswith("# branch.upstream"):
            info["upstream"] = line.split(" ", 2)[-1]
        elif line.startswith("# branch.ab"):
            m = re.search(r"\+(\d+) -(\d+)", line)
            if m:
                info["ahead"], info["behind"] = int(m.group(1)), int(m.group(2))
        elif line and not line.startswith("#"):
            info["clean"] = False
            parts = line.split()
            if parts:
                info["dirty_files"].append(parts[-1])
    info["dirty_files"] = info["dirty_files"][:50]
    return info
