"""
Unit tests for planner.py.

Tests:
  - load_plan from a YAML string (via tmp file)
  - default_plan defaults
  - Restore phase ordering (group_manifests_by_phase, ordered_restore_phases)
  - phase_for_kind mapping
"""
from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

from ospc_to_flex_k8.models import RestorePhase
from ospc_to_flex_k8.planner import (
    default_plan,
    load_plan,
    ordered_restore_phases,
    phase_for_kind,
    group_manifests_by_phase,
    STAGE_2_DESIGN_CHECKPOINTS,
    STAGE_7_VALIDATION_CHECKPOINTS,
    MIGRATION_STAGES,
)


# ── load_plan ─────────────────────────────────────────────────────────────────

class TestLoadPlan:
    def test_load_minimal_plan(self, tmp_path: Path):
        plan_file = tmp_path / "plan.yaml"
        plan_file.write_text("include_namespaces: [production]\n")
        plan = load_plan(plan_file)
        assert plan.include_namespaces == ["production"]

    def test_load_full_plan(self, tmp_path: Path):
        yaml_text = textwrap.dedent("""\
            include_namespaces:
              - production
              - staging
            exclude_namespaces:
              - kube-system
            exclude_kinds:
              - Event
              - Lease
            remove_node_selectors: true
            remove_affinity: true
            remove_tolerations: false
            storage_mapping:
              default: cinder-standard
              mappings:
                local-path: cinder-fast
                nfs-client: cinder-nfs
            ingress_mapping:
              default: nginx
              mappings:
                traefik: nginx
            endpoint_replacements:
              - old: old.internal
                new: new.flex.cloud
              - old: ospc-db.local
                new: flex-db.svc.cluster.local
            exclude_secret_names:
              - tls-wildcard
        """)
        plan_file = tmp_path / "plan.yaml"
        plan_file.write_text(yaml_text)
        plan = load_plan(plan_file)

        assert plan.include_namespaces == ["production", "staging"]
        assert plan.exclude_namespaces == ["kube-system"]
        assert plan.exclude_kinds == ["Event", "Lease"]
        assert plan.remove_node_selectors is True
        assert plan.remove_affinity is True
        assert plan.remove_tolerations is False
        assert plan.storage_mapping.default == "cinder-standard"
        assert plan.storage_mapping.old_to_new == {
            "local-path": "cinder-fast",
            "nfs-client": "cinder-nfs",
        }
        assert plan.ingress_mapping.old_to_new == {"traefik": "nginx"}
        assert len(plan.endpoint_replacements) == 2
        assert plan.endpoint_replacements[0].old == "old.internal"
        assert plan.endpoint_replacements[0].new == "new.flex.cloud"
        assert plan.exclude_secret_names == ["tls-wildcard"]

    def test_file_not_found_raises(self, tmp_path: Path):
        with pytest.raises(FileNotFoundError):
            load_plan(tmp_path / "nonexistent.yaml")

    def test_empty_plan_uses_defaults(self, tmp_path: Path):
        plan_file = tmp_path / "plan.yaml"
        plan_file.write_text("{}\n")
        plan = load_plan(plan_file)
        # Should not raise; all fields use dataclass defaults
        assert plan.storage_mapping.default == "cinder-standard"
        assert plan.ingress_mapping.default == "nginx"

    def test_invalid_endpoint_entries_skipped(self, tmp_path: Path):
        plan_file = tmp_path / "plan.yaml"
        plan_file.write_text(
            "endpoint_replacements:\n  - bad_entry: true\n  - old: x\n    new: y\n"
        )
        plan = load_plan(plan_file)
        # Only the valid entry is kept
        assert len(plan.endpoint_replacements) == 1
        assert plan.endpoint_replacements[0].old == "x"


# ── default_plan ──────────────────────────────────────────────────────────────

class TestDefaultPlan:
    def test_defaults_exclude_system_namespaces(self):
        plan = default_plan()
        assert "kube-system" in plan.exclude_namespaces
        assert "kube-public" in plan.exclude_namespaces

    def test_defaults_exclude_event_and_lease(self):
        plan = default_plan()
        assert "Event" in plan.exclude_kinds
        assert "Lease" in plan.exclude_kinds

    def test_default_storage_class(self):
        plan = default_plan()
        assert plan.storage_mapping.default == "cinder-standard"

    def test_remove_node_selectors_default_true(self):
        plan = default_plan()
        assert plan.remove_node_selectors is True

    def test_remove_affinity_default_false(self):
        plan = default_plan()
        assert plan.remove_affinity is False


# ── Restore phase ordering ────────────────────────────────────────────────────

class TestRestorePhaseOrdering:
    def test_ordered_phases_starts_with_crds(self):
        phases = ordered_restore_phases()
        assert phases[0] == RestorePhase.CRDS

    def test_ordered_phases_ends_with_validation(self):
        phases = ordered_restore_phases()
        assert phases[-1] == RestorePhase.VALIDATION

    def test_namespaces_before_rbac(self):
        phases = ordered_restore_phases()
        assert phases.index(RestorePhase.NAMESPACES) < phases.index(RestorePhase.RBAC)

    def test_rbac_before_configmaps(self):
        phases = ordered_restore_phases()
        assert phases.index(RestorePhase.RBAC) < phases.index(RestorePhase.CONFIGMAPS)

    def test_storage_before_deployments(self):
        phases = ordered_restore_phases()
        assert phases.index(RestorePhase.STORAGE) < phases.index(RestorePhase.DEPLOYMENTS)

    @pytest.mark.parametrize("kind,expected_phase", [
        ("CustomResourceDefinition", RestorePhase.CRDS),
        ("Namespace", RestorePhase.NAMESPACES),
        ("ServiceAccount", RestorePhase.RBAC),
        ("ClusterRole", RestorePhase.RBAC),
        ("ConfigMap", RestorePhase.CONFIGMAPS),
        ("Secret", RestorePhase.SECRETS),
        ("PersistentVolumeClaim", RestorePhase.STORAGE),
        ("StorageClass", RestorePhase.STORAGE),
        ("Service", RestorePhase.SERVICES),
        ("Deployment", RestorePhase.DEPLOYMENTS),
        ("StatefulSet", RestorePhase.STATEFULSETS),
        ("DaemonSet", RestorePhase.DAEMONSETS),
        ("Ingress", RestorePhase.INGRESSES),
        ("PodDisruptionBudget", RestorePhase.POLICY),
    ])
    def test_phase_for_kind(self, kind: str, expected_phase: RestorePhase):
        assert phase_for_kind(kind) == expected_phase

    def test_unknown_kind_maps_to_deployments(self):
        assert phase_for_kind("SomeCRDResource") == RestorePhase.DEPLOYMENTS


# ── Stage checkpoint constants ────────────────────────────────────────────────

class TestStage2DesignCheckpoints:
    def test_all_required_checkpoints_present(self):
        required = [
            "cluster_template_exists",
            "coe_is_kubernetes",
            "image_validated",
            "image_os_distro_compatible",
            "external_network_present",
            "network_driver_selected",
            "volume_driver_selected",
            "keypair_present",
            "master_lb_decision_recorded",
            "flavor_decision_recorded",
        ]
        for name in required:
            assert name in STAGE_2_DESIGN_CHECKPOINTS, f"Missing checkpoint: {name}"

    def test_is_list_of_strings(self):
        assert isinstance(STAGE_2_DESIGN_CHECKPOINTS, list)
        for item in STAGE_2_DESIGN_CHECKPOINTS:
            assert isinstance(item, str)

    def test_has_expected_length(self):
        assert len(STAGE_2_DESIGN_CHECKPOINTS) == 10


class TestStage7ValidationCheckpoints:
    def test_all_required_checkpoints_present(self):
        required = [
            "magnum_cluster_status_collected",
            "loadbalancer_test_deployed",
            "loadbalancer_result_recorded",
            "node_group_awareness_recorded",
        ]
        for name in required:
            assert name in STAGE_7_VALIDATION_CHECKPOINTS, f"Missing checkpoint: {name}"

    def test_is_list_of_strings(self):
        assert isinstance(STAGE_7_VALIDATION_CHECKPOINTS, list)
        for item in STAGE_7_VALIDATION_CHECKPOINTS:
            assert isinstance(item, str)

    def test_has_expected_length(self):
        assert len(STAGE_7_VALIDATION_CHECKPOINTS) == 4


class TestMigrationStages:
    def test_nine_stages(self):
        assert len(MIGRATION_STAGES) == 9

    def test_stage2_is_design(self):
        assert MIGRATION_STAGES[1] == "stage2_design_template"

    def test_stage3_is_create_cluster(self):
        assert MIGRATION_STAGES[2] == "stage3_create_cluster"

    def test_stage7_is_test_validate(self):
        assert MIGRATION_STAGES[6] == "stage7_test_validate"

    def test_stage9_is_rollback(self):
        assert MIGRATION_STAGES[8] == "stage9_rollback"


# ── group_manifests_by_phase ──────────────────────────────────────────────────

class TestGroupManifestsByPhase:
    def test_groups_correctly(self):
        manifests = [
            {"kind": "Deployment", "metadata": {"name": "app"}},
            {"kind": "Namespace",  "metadata": {"name": "prod"}},
            {"kind": "Secret",     "metadata": {"name": "db"}},
            {"kind": "ConfigMap",  "metadata": {"name": "cfg"}},
        ]
        grouped = group_manifests_by_phase(manifests)
        assert RestorePhase.NAMESPACES in grouped
        assert RestorePhase.SECRETS in grouped
        assert RestorePhase.CONFIGMAPS in grouped
        assert RestorePhase.DEPLOYMENTS in grouped
        assert grouped[RestorePhase.NAMESPACES][0]["metadata"]["name"] == "prod"

    def test_phase_order_preserved(self):
        manifests = [
            {"kind": "Deployment", "metadata": {"name": "app"}},
            {"kind": "Namespace",  "metadata": {"name": "prod"}},
        ]
        grouped = group_manifests_by_phase(manifests)
        keys = list(grouped.keys())
        assert keys.index(RestorePhase.NAMESPACES) < keys.index(RestorePhase.DEPLOYMENTS)

    def test_empty_input(self):
        grouped = group_manifests_by_phase([])
        assert grouped == {}
