"""
Magnum: Rackspace Flex OpenStack Magnum cluster creation and management.

Uses the ``openstack`` CLI (via run_cmd) to create, query, and configure
Magnum Kubernetes clusters on the Flex cloud.
"""
from __future__ import annotations

import json
import logging
import shutil
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from .io_utils import run_cmd, ensure_dir

log = logging.getLogger(__name__)

# ── OpenStack CLI wrapper ─────────────────────────────────────────────────────

def _openstack(
    args: str,
    openrc: Optional[str] = None,
    dry_run: bool = False,
    timeout: int = 300,
) -> Tuple[int, str, str]:
    """
    Run an ``openstack`` CLI command, optionally sourcing an OpenRC file first.

    Returns (returncode, stdout, stderr).
    """
    if openrc:
        cmd = f"source {openrc} && openstack {args}"
    else:
        cmd = f"openstack {args}"
    return run_cmd(cmd, capture=True, dry_run=dry_run, timeout=timeout)


# ── Stage 2: ClusterTemplate design and validation ───────────────────────────

def validate_cluster_template(
    template_name: str,
    openrc: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Validate a Magnum ClusterTemplate against Magnum 2025.2 requirements.

    Checks COE type, image presence, OS distro (fedora-coreos), network
    configuration, drivers, keypair, LB settings, and flavor selection.

    If the openstack CLI is not available, returns a skipped result for every
    check rather than failing hard.

    Args:
        template_name: ClusterTemplate name or UUID.
        openrc:        Path to an OpenRC credentials file (optional).

    Returns:
        Dict mapping check name → result dict with keys:
          - passed (bool | None — None means skipped/informational)
          - value   (the actual value found, if any)
          - notes   (human-readable explanation)
    """
    if not shutil.which("openstack"):
        skipped = {"passed": None, "value": None, "notes": "openstack CLI not available — skipped"}
        return {
            "cluster_template_exists":    {"passed": None, "value": None, "notes": "openstack CLI not available — skipped"},
            "coe_is_kubernetes":          skipped,
            "image_validated":            skipped,
            "image_os_distro_compatible": skipped,
            "external_network_present":   skipped,
            "network_driver_selected":    skipped,
            "volume_driver_selected":     skipped,
            "keypair_present":            skipped,
            "master_lb_decision_recorded": skipped,
            "flavor_decision_recorded":   skipped,
            "driver_note":                skipped,
        }

    template = get_cluster_template(template_name, openrc=openrc)
    if template is None:
        return {
            "cluster_template_exists": {
                "passed": False,
                "value": None,
                "notes": f"ClusterTemplate {template_name!r} not found via openstack CLI",
            }
        }

    results: Dict[str, Any] = {}

    results["cluster_template_exists"] = {
        "passed": True,
        "value": template.get("name") or template_name,
        "notes": "ClusterTemplate found",
    }

    # COE must be kubernetes
    coe = template.get("coe") or template.get("Container Orchestration Engine", "")
    results["coe_is_kubernetes"] = {
        "passed": str(coe).lower() == "kubernetes",
        "value": coe,
        "notes": "COE must be 'kubernetes'" if str(coe).lower() != "kubernetes" else "OK",
    }

    # Image ID presence
    image_id = template.get("image_id") or template.get("Image ID", "")
    results["image_validated"] = {
        "passed": bool(image_id),
        "value": image_id,
        "notes": "image_id is set" if image_id else "image_id is missing",
    }

    # OS distro — Magnum 2025.2 requires fedora-coreos for k8s COE
    os_distro = template.get("image_os_distro") or template.get("OS Distro", "") or ""
    results["image_os_distro_compatible"] = {
        "passed": str(os_distro).lower() == "fedora-coreos",
        "value": os_distro,
        "notes": (
            "Expected 'fedora-coreos' per Magnum 2025.2 for Kubernetes COE"
            if str(os_distro).lower() != "fedora-coreos"
            else "OK"
        ),
    }

    # External network
    ext_net = (
        template.get("external_network_id")
        or template.get("external_network")
        or template.get("External Network ID", "")
    )
    results["external_network_present"] = {
        "passed": bool(ext_net),
        "value": ext_net,
        "notes": "external_network_id is set" if ext_net else "external_network_id is missing",
    }

    # Network driver (flannel or calico)
    net_driver = (
        template.get("network_driver")
        or template.get("Network Driver", "")
        or ""
    )
    valid_net_drivers = {"flannel", "calico"}
    results["network_driver_selected"] = {
        "passed": str(net_driver).lower() in valid_net_drivers,
        "value": net_driver,
        "notes": (
            f"Expected one of {sorted(valid_net_drivers)}"
            if str(net_driver).lower() not in valid_net_drivers
            else "OK"
        ),
    }

    # Volume driver (cinder)
    vol_driver = (
        template.get("volume_driver")
        or template.get("Volume Driver", "")
        or ""
    )
    results["volume_driver_selected"] = {
        "passed": str(vol_driver).lower() == "cinder",
        "value": vol_driver,
        "notes": "Expected 'cinder'" if str(vol_driver).lower() != "cinder" else "OK",
    }

    # Keypair
    keypair = template.get("keypair_id") or template.get("Keypair ID", "")
    results["keypair_present"] = {
        "passed": bool(keypair),
        "value": keypair,
        "notes": "keypair_id is set" if keypair else "keypair_id is missing",
    }

    # Master LB — informational, no fail
    master_lb = template.get("master_lb_enabled")
    if master_lb is None:
        master_lb = template.get("Master LB Enabled", None)
    results["master_lb_decision_recorded"] = {
        "passed": None,  # informational
        "value": master_lb,
        "notes": f"master_lb_enabled={master_lb!r} — record this for HA planning",
    }

    # Flavor presence
    flavor_id = template.get("flavor_id") or template.get("Flavor ID", "")
    master_flavor_id = template.get("master_flavor_id") or template.get("Master Flavor ID", "")
    results["flavor_decision_recorded"] = {
        "passed": bool(flavor_id and master_flavor_id),
        "value": {"flavor_id": flavor_id, "master_flavor_id": master_flavor_id},
        "notes": (
            "Both flavor_id and master_flavor_id are set"
            if (flavor_id and master_flavor_id)
            else "One or both of flavor_id / master_flavor_id is missing"
        ),
    }

    # Driver note: warn about Heat driver (deprecated in Magnum 2025.2)
    labels = template.get("labels") or {}
    if isinstance(labels, str):
        # Some openstack CLI versions return labels as a string
        try:
            labels = json.loads(labels)
        except (json.JSONDecodeError, TypeError):
            labels = {}
    driver = labels.get("kube_driver", "") or labels.get("driver", "") or ""
    heat_warning = (
        "WARNING: Heat driver is deprecated in Magnum 2025.2. "
        "Migrate to k8s_capi_helm or k8s_cluster_api."
        if "heat" in str(driver).lower()
        else "No Heat driver label detected — OK"
    )
    results["driver_note"] = {
        "passed": None,  # informational
        "value": driver or "(not set in labels)",
        "notes": heat_warning,
    }

    return results


def design_cluster_template(
    source_cluster_info: Dict[str, Any],
    template_name: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Generate a recommended Magnum ClusterTemplate dict based on source cluster info.

    The returned dict describes the recommended ClusterTemplate fields and
    can be used as input to an ``openstack coe cluster template create`` command.

    Args:
        source_cluster_info: Dict with keys from the source cluster export
                             (e.g. kubernetes_version, node_count, storage_class, etc.).
        template_name:       Desired template name (default: auto-generated).

    Returns:
        Dict with:
          - template_name (str)
          - recommended_fields (dict) — ClusterTemplate fields to set
          - openstack_command (str)   — example ``openstack`` CLI command
          - notes (list[str])         — operator guidance
    """
    k8s_version = source_cluster_info.get("kubernetes_version", "1.29")
    node_count = source_cluster_info.get("node_count", 3)
    master_count = source_cluster_info.get("master_count", 3)

    if template_name is None:
        # normalise k8s version for name
        k8s_slug = str(k8s_version).replace(".", "-").lstrip("v")
        template_name = f"flex-k8s-{k8s_slug}-coreos"

    recommended: Dict[str, Any] = {
        "coe": "kubernetes",
        "image_os_distro": "fedora-coreos",
        "network_driver": "calico",
        "volume_driver": "cinder",
        "master_lb_enabled": True,
        "floating_ip_enabled": True,
        "docker_volume_size": 50,
        "master_flavor_id": "m1.medium",   # operator must override
        "flavor_id": "m1.large",            # operator must override
    }

    openstack_cmd = (
        f"openstack coe cluster template create {template_name} \\\n"
        f"  --coe kubernetes \\\n"
        f"  --image <fedora-coreos-image-id> \\\n"
        f"  --external-network <external-net-id> \\\n"
        f"  --network-driver calico \\\n"
        f"  --volume-driver cinder \\\n"
        f"  --keypair <keypair-name> \\\n"
        f"  --master-flavor <master-flavor-id> \\\n"
        f"  --flavor <worker-flavor-id> \\\n"
        f"  --master-lb-enabled \\\n"
        f"  --floating-ip-enabled \\\n"
        f"  --docker-volume-size 50"
    )

    notes = [
        "Magnum 2025.2: use k8s_capi_helm or k8s_cluster_api driver (Heat is deprecated).",
        "Set --image to a Glance image with os_distro=fedora-coreos.",
        f"Source cluster has {node_count} workers and {master_count} masters — size flavors accordingly.",
        "Run 'python -m ospc_to_flex_k8.cli design-template' to validate the template after creation.",
    ]

    return {
        "template_name": template_name,
        "recommended_fields": recommended,
        "openstack_command": openstack_cmd,
        "notes": notes,
    }


# ── Cluster templates ─────────────────────────────────────────────────────────

def list_cluster_templates(
    openrc: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """
    Return a list of available Magnum cluster templates.

    Each entry is a dict with keys: id, name, coe, server_type, image_id.
    """
    rc, out, err = _openstack(
        "coe cluster template list -f json",
        openrc=openrc,
    )
    if rc != 0:
        log.warning("Could not list cluster templates: %s", err)
        return []
    try:
        return json.loads(out) if out.strip() else []
    except json.JSONDecodeError:
        log.warning("Could not parse cluster template list output")
        return []


def get_cluster_template(
    template_name: str,
    openrc: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    """
    Return details for a single cluster template by name or UUID, or None.
    """
    rc, out, err = _openstack(
        f"coe cluster template show {template_name} -f json",
        openrc=openrc,
    )
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


# ── Cluster lifecycle ─────────────────────────────────────────────────────────

def create_cluster(
    cluster_name: str,
    template: str,
    master_count: int = 3,
    node_count: int = 3,
    keypair: Optional[str] = None,
    labels: Optional[Dict[str, str]] = None,
    openrc: Optional[str] = None,
    dry_run: bool = False,
) -> Optional[str]:
    """
    Create a new Magnum Kubernetes cluster.

    Args:
        cluster_name: Name for the new cluster.
        template:     Cluster template name or UUID.
        master_count: Number of master nodes.
        node_count:   Number of worker nodes.
        keypair:      SSH keypair name for node access.
        labels:       Optional dict of extra Magnum labels (key=value).
        openrc:       Path to OpenRC credentials file.
        dry_run:      If True, print command but do not execute.

    Returns:
        UUID of the created cluster, or None on failure.
    """
    args = (
        f"coe cluster create {cluster_name}"
        f" --cluster-template {template}"
        f" --master-count {master_count}"
        f" --node-count {node_count}"
    )
    if keypair:
        args += f" --keypair {keypair}"
    if labels:
        label_str = ",".join(f"{k}={v}" for k, v in labels.items())
        args += f" --labels {label_str}"
    args += " -f value -c uuid"

    rc, out, err = _openstack(args, openrc=openrc, dry_run=dry_run, timeout=60)
    if dry_run:
        return "dry-run-uuid"
    if rc != 0:
        log.error("Cluster creation failed: %s", err)
        return None
    uuid = out.strip()
    log.info("Cluster creation initiated: %s (uuid=%s)", cluster_name, uuid)
    return uuid


def get_cluster_status(
    cluster_name_or_id: str,
    openrc: Optional[str] = None,
) -> Optional[str]:
    """
    Return the current status string of a Magnum cluster, or None on error.

    Common statuses: CREATE_IN_PROGRESS, CREATE_COMPLETE, CREATE_FAILED,
                     UPDATE_IN_PROGRESS, DELETE_IN_PROGRESS.
    """
    rc, out, err = _openstack(
        f"coe cluster show {cluster_name_or_id} -f value -c status",
        openrc=openrc,
        timeout=30,
    )
    if rc != 0:
        return None
    return out.strip() or None


def wait_for_cluster(
    cluster_name_or_id: str,
    desired_status: str = "CREATE_COMPLETE",
    poll_interval: int = 30,
    timeout: int = 3600,
    openrc: Optional[str] = None,
) -> bool:
    """
    Poll until the cluster reaches ``desired_status`` or ``timeout`` seconds elapse.

    Args:
        cluster_name_or_id: Cluster name or UUID.
        desired_status:     Status string to wait for.
        poll_interval:      Seconds between polls.
        timeout:            Maximum total seconds to wait.
        openrc:             Path to OpenRC credentials file.

    Returns:
        True if desired status was reached, False on timeout or FAILED status.
    """
    deadline = time.monotonic() + timeout
    log.info("Waiting for cluster %s → %s (timeout=%ds)", cluster_name_or_id, desired_status, timeout)

    while time.monotonic() < deadline:
        status = get_cluster_status(cluster_name_or_id, openrc=openrc)
        log.info("  Cluster status: %s", status)

        if status == desired_status:
            log.info("Cluster %s reached status: %s", cluster_name_or_id, status)
            return True

        if status and "FAILED" in status:
            log.error("Cluster %s entered FAILED state: %s", cluster_name_or_id, status)
            return False

        time.sleep(poll_interval)

    log.error("Timed out waiting for cluster %s to reach %s", cluster_name_or_id, desired_status)
    return False


def delete_cluster(
    cluster_name_or_id: str,
    openrc: Optional[str] = None,
    dry_run: bool = False,
) -> bool:
    """
    Delete a Magnum cluster.

    Returns True if the delete command was accepted (rc == 0).
    """
    rc, _, err = _openstack(
        f"coe cluster delete {cluster_name_or_id}",
        openrc=openrc,
        dry_run=dry_run,
        timeout=60,
    )
    if rc != 0:
        log.error("Cluster delete failed: %s", err)
        return False
    log.info("Cluster delete initiated: %s", cluster_name_or_id)
    return True


# ── Kubeconfig retrieval ──────────────────────────────────────────────────────

def get_kubeconfig(
    cluster_name_or_id: str,
    output_path: Path,
    openrc: Optional[str] = None,
    dry_run: bool = False,
) -> bool:
    """
    Fetch the kubeconfig for a Magnum cluster and write it to ``output_path``.

    Args:
        cluster_name_or_id: Cluster name or UUID.
        output_path:        Destination path for the kubeconfig file.
        openrc:             Path to OpenRC credentials file.
        dry_run:            If True, print command but do not write file.

    Returns:
        True on success.
    """
    ensure_dir(output_path.parent)
    rc, out, err = _openstack(
        f"coe cluster config {cluster_name_or_id} --output-certs --dir {output_path.parent}",
        openrc=openrc,
        dry_run=dry_run,
        timeout=120,
    )
    if dry_run:
        return True
    if rc != 0:
        log.error("get kubeconfig failed: %s", err)
        return False

    # openstack coe cluster config writes 'config' to the specified dir
    generated = output_path.parent / "config"
    if generated.exists() and generated != output_path:
        generated.rename(output_path)

    log.info("Kubeconfig written to %s", output_path)
    return True


# ── Cluster inventory ─────────────────────────────────────────────────────────

def show_cluster(
    cluster_name_or_id: str,
    openrc: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    """
    Return full cluster details as a dict, or None on error.
    """
    rc, out, err = _openstack(
        f"coe cluster show {cluster_name_or_id} -f json",
        openrc=openrc,
        timeout=30,
    )
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def list_clusters(
    openrc: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """Return a list of all Magnum clusters visible to the current project."""
    rc, out, err = _openstack("coe cluster list -f json", openrc=openrc)
    if rc != 0:
        log.warning("Could not list clusters: %s", err)
        return []
    try:
        return json.loads(out) if out.strip() else []
    except json.JSONDecodeError:
        return []
