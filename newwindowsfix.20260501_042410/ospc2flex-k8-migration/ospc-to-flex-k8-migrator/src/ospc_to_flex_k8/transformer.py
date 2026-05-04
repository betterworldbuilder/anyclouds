"""
Transformer: manifest transformation engine.

Reads exported YAML files from the source export directory, applies all
configured transformations (strip runtime fields, remap storage/ingress,
replace endpoints, remove scheduling hints), and writes clean manifests
to the output directory ready to be applied to the Flex Magnum cluster.
"""
from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Dict, List, Optional

from .io_utils import ensure_dir, load_yaml_multidoc, dump_yaml_multidoc
from .manifests import (
    strip_runtime_fields,
    get_kind,
    get_name,
    get_namespace,
    get_storage_class,
    set_storage_class,
    get_ingress_class,
    set_ingress_class,
    remove_node_selectors,
    remove_affinity,
    remove_tolerations,
    replace_endpoints,
    sort_manifests_for_restore,
)
from .models import MigrationPlan, TransformReport

log = logging.getLogger(__name__)


# ── Single-manifest transformer ───────────────────────────────────────────────

def transform_manifest(
    manifest: Dict[str, Any],
    plan: MigrationPlan,
    report: TransformReport,
) -> Optional[Dict[str, Any]]:
    """
    Apply all transformations from ``plan`` to a single manifest dict.

    Returns the transformed manifest, or None if it should be skipped
    (excluded namespace, excluded kind, excluded secret name).

    Mutations are applied in-place AND the manifest is returned.

    Args:
        manifest: Raw manifest dict loaded from the source export.
        plan:     Migration plan controlling what to skip/transform.
        report:   Accumulates per-transformation statistics (mutated in-place).

    Returns:
        Transformed manifest dict, or None to skip.
    """
    kind = get_kind(manifest)
    name = get_name(manifest)
    ns = get_namespace(manifest)

    report.total_input += 1

    # ── Exclusion checks ──────────────────────────────────────────────────────
    if kind in plan.exclude_kinds:
        log.debug("Skipping excluded kind: %s/%s", kind, name)
        report.skipped += 1
        return None

    if ns and plan.include_namespaces and ns not in plan.include_namespaces:
        log.debug("Skipping ns not in include list: %s", ns)
        report.skipped += 1
        return None

    if ns and ns in plan.exclude_namespaces:
        log.debug("Skipping excluded namespace: %s", ns)
        report.skipped += 1
        return None

    if kind == "Secret" and name in plan.exclude_secret_names:
        log.debug("Skipping excluded secret: %s/%s", ns, name)
        report.skipped += 1
        return None

    # ── Strip runtime fields ──────────────────────────────────────────────────
    strip_runtime_fields(manifest, extra_fields=plan.strip_fields)

    # ── Storage class remapping ───────────────────────────────────────────────
    if kind in ("PersistentVolumeClaim", "PersistentVolume"):
        old_sc = get_storage_class(manifest)
        new_sc = plan.storage_mapping.translate(old_sc)
        if old_sc != new_sc:
            set_storage_class(manifest, new_sc)
            msg = f"{kind}/{name}: {old_sc!r} → {new_sc!r}"
            report.storage_remaps.append(msg)
            log.debug("StorageClass remap: %s", msg)

    # ── Ingress class remapping ───────────────────────────────────────────────
    if kind == "Ingress":
        old_cls = get_ingress_class(manifest)
        new_cls = plan.ingress_mapping.translate(old_cls)
        if old_cls != new_cls:
            set_ingress_class(manifest, new_cls)
            msg = f"Ingress/{name}: {old_cls!r} → {new_cls!r}"
            report.ingress_remaps.append(msg)
            log.debug("IngressClass remap: %s", msg)

    # ── Scheduling-field removal ──────────────────────────────────────────────
    if plan.remove_node_selectors:
        remove_node_selectors(manifest)
    if plan.remove_affinity:
        remove_affinity(manifest)
    if plan.remove_tolerations:
        remove_tolerations(manifest)

    # ── Endpoint replacement ──────────────────────────────────────────────────
    if plan.endpoint_replacements:
        pairs = [(r.old, r.new) for r in plan.endpoint_replacements]
        count = replace_endpoints(manifest, pairs)
        if count:
            msg = f"{kind}/{name}: {count} substitution(s)"
            report.endpoint_replacements.append(msg)
            log.debug("EndpointReplace: %s", msg)

    report.total_output += 1
    return manifest


# ── Directory-level transformer ───────────────────────────────────────────────

def transform_directory(
    source_dir: Path,
    output_dir: Path,
    plan: MigrationPlan,
) -> TransformReport:
    """
    Walk ``source_dir`` recursively, transform every .yaml file, and write
    results to the mirrored path under ``output_dir``.

    Files with no surviving manifests (all skipped) are not written.
    The final combined file ``output_dir/all_manifests.yaml`` contains all
    surviving manifests sorted into restore order.

    Args:
        source_dir: Root of the kubectl-exported YAML files.
        output_dir: Root for transformed output.
        plan:       Migration plan.

    Returns:
        TransformReport with totals and per-transformation details.
    """
    ensure_dir(output_dir)
    report = TransformReport()
    all_manifests: List[Dict[str, Any]] = []

    yaml_files = sorted(source_dir.rglob("*.yaml"))
    log.info("Transforming %d YAML files from %s", len(yaml_files), source_dir)

    for yaml_file in yaml_files:
        try:
            docs = load_yaml_multidoc(yaml_file)
        except Exception as exc:
            log.warning("Could not parse %s: %s", yaml_file, exc)
            report.warnings.append(f"Parse error: {yaml_file}: {exc}")
            continue

        # Flatten List-type docs (kubectl get -o yaml returns *List objects)
        expanded: List[Dict[str, Any]] = []
        for doc in docs:
            if not doc:
                continue
            if doc.get("kind", "").endswith("List"):
                for item in doc.get("items", []):
                    if item:
                        expanded.append(item)
            else:
                expanded.append(doc)

        transformed: List[Dict[str, Any]] = []
        for raw in expanded:
            result = transform_manifest(raw, plan, report)
            if result is not None:
                transformed.append(result)
                all_manifests.append(result)

        if not transformed:
            continue

        # Mirror directory structure
        rel = yaml_file.relative_to(source_dir)
        out_file = output_dir / rel
        ensure_dir(out_file.parent)
        try:
            dump_yaml_multidoc(transformed, out_file)
            log.debug("Written: %s (%d docs)", out_file, len(transformed))
        except Exception as exc:
            log.warning("Could not write %s: %s", out_file, exc)
            report.warnings.append(f"Write error: {out_file}: {exc}")

    # Write sorted combined manifest
    if all_manifests:
        sorted_manifests = sort_manifests_for_restore(all_manifests)
        combined_file = output_dir / "all_manifests.yaml"
        dump_yaml_multidoc(sorted_manifests, combined_file)
        log.info(
            "Combined manifest: %s (%d resources)", combined_file, len(sorted_manifests)
        )

    log.info(
        "Transform complete: in=%d out=%d skipped=%d warns=%d",
        report.total_input,
        report.total_output,
        report.skipped,
        len(report.warnings),
    )
    return report
