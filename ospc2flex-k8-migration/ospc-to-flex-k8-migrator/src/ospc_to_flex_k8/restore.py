"""
Restore: apply transformed manifests to the Flex Magnum target cluster.

Applies manifests in the correct restore phase order (CRDs → Namespaces →
RBAC → ConfigMaps → Secrets → Storage → Services → Deployments → …),
with optional dry-run, Helm re-installation, and per-phase retry logic.
"""
from __future__ import annotations

import logging
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from .io_utils import ensure_dir, run_cmd, load_yaml_multidoc, dump_yaml
from .models import ApplyResult, HelmRelease, RestorePhase
from .planner import ordered_restore_phases, group_manifests_by_phase

log = logging.getLogger(__name__)

# ── kubectl apply wrapper ─────────────────────────────────────────────────────

def _kubectl_apply(
    manifest_file: Path,
    context: Optional[str] = None,
    kubeconfig: Optional[str] = None,
    dry_run: bool = False,
    server_side: bool = False,
    timeout: int = 120,
) -> ApplyResult:
    """
    Run ``kubectl apply`` on a single YAML file.

    Args:
        manifest_file: Path to the YAML file to apply.
        context:       kubectl context for the target cluster.
        kubeconfig:    Path to kubeconfig for the target cluster.
        dry_run:       Pass ``--dry-run=client`` if True.
        server_side:   Use ``--server-side`` apply strategy.
        timeout:       Command timeout in seconds.

    Returns:
        ApplyResult with success flag, stdout output, and any stderr.
    """
    flags = ""
    if context:
        flags += f" --context={context}"
    if kubeconfig:
        flags += f" --kubeconfig={kubeconfig}"
    if dry_run:
        flags += " --dry-run=client"
    if server_side:
        flags += " --server-side --force-conflicts"

    cmd = f"kubectl apply{flags} -f {manifest_file}"
    rc, out, err = run_cmd(cmd, capture=True, dry_run=False, timeout=timeout)
    return ApplyResult(
        file=str(manifest_file),
        success=(rc == 0),
        output=out,
        error=err,
        dry_run=dry_run,
    )


def _kubectl_wait(
    resource: str,
    condition: str = "condition=available",
    namespace: str = "--all-namespaces",
    timeout_s: int = 120,
    context: Optional[str] = None,
    kubeconfig: Optional[str] = None,
) -> bool:
    """
    Run ``kubectl wait`` for a resource condition.  Returns True on success.
    """
    ns_flag = f"-n {namespace}" if namespace != "--all-namespaces" else "--all-namespaces"
    flags = ""
    if context:
        flags += f" --context={context}"
    if kubeconfig:
        flags += f" --kubeconfig={kubeconfig}"
    cmd = (
        f"kubectl wait {resource} {ns_flag}{flags}"
        f" --for={condition} --timeout={timeout_s}s 2>/dev/null || true"
    )
    rc, _, _ = run_cmd(cmd, capture=True)
    return rc == 0


# ── Phase restore ─────────────────────────────────────────────────────────────

def restore_phase(
    phase: RestorePhase,
    manifest_files: List[Path],
    context: Optional[str] = None,
    kubeconfig: Optional[str] = None,
    dry_run: bool = False,
    server_side: bool = False,
    retry_count: int = 2,
    retry_delay: int = 5,
) -> List[ApplyResult]:
    """
    Apply all manifest files belonging to a single restore phase.

    Retries failed applies up to ``retry_count`` times with ``retry_delay``
    seconds between attempts (useful for CRD propagation timing).

    Args:
        phase:          Which phase is being restored (for logging).
        manifest_files: List of YAML file paths to apply.
        context:        kubectl context for target cluster.
        kubeconfig:     Path to kubeconfig for target cluster.
        dry_run:        Pass --dry-run=client to kubectl.
        server_side:    Use server-side apply.
        retry_count:    Number of retry attempts for failed files.
        retry_delay:    Seconds to wait between retries.

    Returns:
        List of ApplyResult (one per file attempt, including retries).
    """
    results: List[ApplyResult] = []
    log.info("=== Restoring phase: %s (%d files) ===", phase.value, len(manifest_files))

    for mf in manifest_files:
        attempt = 0
        while attempt <= retry_count:
            result = _kubectl_apply(
                mf,
                context=context,
                kubeconfig=kubeconfig,
                dry_run=dry_run,
                server_side=server_side,
            )
            results.append(result)
            if result.success:
                log.debug("  Applied: %s", mf.name)
                break
            attempt += 1
            if attempt <= retry_count:
                log.warning(
                    "  Apply failed (attempt %d/%d): %s — retrying in %ds",
                    attempt, retry_count + 1, mf.name, retry_delay,
                )
                time.sleep(retry_delay)
            else:
                log.error("  Apply FAILED after %d attempts: %s\n  %s", retry_count + 1, mf.name, result.error)

    return results


# ── Helm reinstall ────────────────────────────────────────────────────────────

def restore_helm_releases(
    helm_dir: Path,
    context: Optional[str] = None,
    kubeconfig: Optional[str] = None,
    dry_run: bool = False,
) -> List[ApplyResult]:
    """
    Re-install Helm releases from exported values.yaml files.

    Expects the directory structure produced by exporter.export_helm_releases:
        helm_dir/<namespace>/<release_name>/values.yaml

    For each release, runs ``helm upgrade --install`` with the saved values.

    Note: This installs from the chart registry, not from stored manifests.
    The chart name and version are inferred from the directory structure only
    if a ``chart_meta.json`` file exists; otherwise the chart name == release name.

    Args:
        helm_dir:  Path to the helm/ subdirectory of the export output.
        context:   kubectl context for target cluster.
        kubeconfig: Path to kubeconfig for target cluster.
        dry_run:   Pass --dry-run to helm.

    Returns:
        List of ApplyResult (one per release).
    """
    results: List[ApplyResult] = []
    if not helm_dir.exists():
        log.info("No helm directory found at %s — skipping Helm restore", helm_dir)
        return results

    env: Dict[str, str] = {}
    if context:
        env["HELM_KUBECONTEXT"] = context
    if kubeconfig:
        env["KUBECONFIG"] = kubeconfig

    for ns_dir in sorted(helm_dir.iterdir()):
        if not ns_dir.is_dir():
            continue
        namespace = ns_dir.name
        for release_dir in sorted(ns_dir.iterdir()):
            if not release_dir.is_dir():
                continue
            release_name = release_dir.name
            values_file = release_dir / "values.yaml"
            meta_file = release_dir / "chart_meta.json"

            chart = release_name  # default: use release name as chart
            chart_version_flag = ""
            if meta_file.exists():
                import json
                try:
                    meta = json.loads(meta_file.read_text())
                    chart = meta.get("chart", release_name)
                    cv = meta.get("chart_version", "")
                    if cv:
                        chart_version_flag = f" --version {cv}"
                except Exception:
                    pass

            values_flag = f" -f {values_file}" if values_file.exists() else ""
            dry_flag = " --dry-run" if dry_run else ""

            cmd = (
                f"helm upgrade --install {release_name} {chart}"
                f" -n {namespace} --create-namespace"
                f"{chart_version_flag}{values_flag}{dry_flag}"
            )

            rc, out, err = run_cmd(cmd, capture=True, env=env or None, timeout=300)
            results.append(ApplyResult(
                file=f"{namespace}/{release_name}",
                success=(rc == 0),
                output=out,
                error=err,
                dry_run=dry_run,
            ))
            if rc == 0:
                log.info("Helm: installed %s/%s", namespace, release_name)
            else:
                log.error("Helm: FAILED %s/%s: %s", namespace, release_name, err)

    return results


# ── Full restore orchestration ────────────────────────────────────────────────

def restore_cluster(
    transformed_dir: Path,
    context: Optional[str] = None,
    kubeconfig: Optional[str] = None,
    dry_run: bool = False,
    server_side: bool = False,
    skip_phases: Optional[List[RestorePhase]] = None,
    only_phases: Optional[List[RestorePhase]] = None,
) -> Dict[RestorePhase, List[ApplyResult]]:
    """
    Restore all resources from ``transformed_dir`` to the target cluster.

    Walks the directory for YAML files, groups them by resource phase,
    then applies each phase in order.

    Args:
        transformed_dir: Root of the transformer output directory.
        context:         kubectl context for the target cluster.
        kubeconfig:      Path to kubeconfig for the target cluster.
        dry_run:         Pass --dry-run=client to kubectl.
        server_side:     Use server-side apply strategy.
        skip_phases:     Phases to skip entirely.
        only_phases:     If set, only apply these phases (overrides skip_phases).

    Returns:
        Dict mapping RestorePhase → list of ApplyResult.
    """
    skip_phases = skip_phases or []

    # Load all manifests to determine phase grouping
    all_files: List[Path] = sorted(transformed_dir.rglob("*.yaml"))

    # Exclude the combined all_manifests.yaml — we apply per-file
    all_files = [f for f in all_files if f.name != "all_manifests.yaml" and "helm/" not in str(f)]

    log.info("Restore: found %d YAML files in %s", len(all_files), transformed_dir)

    # Build phase → file list mapping via manifest content
    phase_files: Dict[RestorePhase, List[Path]] = {p: [] for p in ordered_restore_phases()}

    for yaml_file in all_files:
        try:
            docs = load_yaml_multidoc(yaml_file)
        except Exception as exc:
            log.warning("Could not parse %s: %s — skipping", yaml_file, exc)
            continue
        # Determine dominant phase from first non-empty doc
        dominant_phase = RestorePhase.DEPLOYMENTS
        for doc in docs:
            if doc and isinstance(doc, dict):
                from .planner import phase_for_kind
                from .manifests import get_kind
                dominant_phase = phase_for_kind(get_kind(doc))
                break
        phase_files[dominant_phase].append(yaml_file)

    results_map: Dict[RestorePhase, List[ApplyResult]] = {}

    for phase in ordered_restore_phases():
        if phase in (RestorePhase.DATA, RestorePhase.VALIDATION):
            continue  # handled externally
        if only_phases and phase not in only_phases:
            continue
        if phase in skip_phases:
            log.info("Skipping phase: %s", phase.value)
            continue

        files = phase_files.get(phase, [])

        if phase == RestorePhase.HELM:
            helm_dir = transformed_dir / "helm"
            helm_results = restore_helm_releases(
                helm_dir,
                context=context,
                kubeconfig=kubeconfig,
                dry_run=dry_run,
            )
            results_map[phase] = helm_results
            continue

        if not files:
            continue

        # Special: after CRDs, wait briefly for API registration
        phase_results = restore_phase(
            phase=phase,
            manifest_files=files,
            context=context,
            kubeconfig=kubeconfig,
            dry_run=dry_run,
            server_side=server_side,
        )
        results_map[phase] = phase_results

        if phase == RestorePhase.CRDS and not dry_run:
            log.info("CRDs applied — waiting 10s for API group registration")
            time.sleep(10)

    return results_map


def summarize_results(
    results_map: Dict[RestorePhase, List[ApplyResult]],
) -> Dict[str, Any]:
    """
    Produce a summary dict from a restore results map.

    Returns:
        Dict with keys: total, succeeded, failed, phases (per-phase breakdown).
    """
    total = 0
    succeeded = 0
    failed = 0
    phases: Dict[str, Dict[str, int]] = {}

    for phase, results in results_map.items():
        p_ok = sum(1 for r in results if r.success)
        p_fail = len(results) - p_ok
        phases[phase.value] = {"total": len(results), "succeeded": p_ok, "failed": p_fail}
        total += len(results)
        succeeded += p_ok
        failed += p_fail

    return {
        "total": total,
        "succeeded": succeeded,
        "failed": failed,
        "phases": phases,
    }
