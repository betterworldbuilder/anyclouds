"""
Unit tests for transformer.py and manifests.py.

Tests:
  - Storage class mapping (exact match, fallback default, None input)
  - Endpoint replacement (single, multiple, nested dicts/lists, no match)
  - Runtime field stripping (uid, resourceVersion, status, extras)
  - Ingress class remapping
  - Node selector / affinity / toleration removal
  - transform_manifest exclusion logic (kind, namespace, secret name)
"""
from __future__ import annotations

import copy
import pytest

from ospc_to_flex_k8.models import (
    MigrationPlan,
    StorageMapping,
    IngressMapping,
    EndpointReplacement,
    TransformReport,
)
from ospc_to_flex_k8.manifests import (
    get_kind,
    get_namespace,
    get_storage_class,
    set_storage_class,
    get_ingress_class,
    set_ingress_class,
    remove_node_selectors,
    remove_affinity,
    remove_tolerations,
    replace_endpoints,
    strip_runtime_fields,
    categorize_kind,
    restore_priority,
    sort_manifests_for_restore,
)
from ospc_to_flex_k8.transformer import transform_manifest


# ── Fixtures ──────────────────────────────────────────────────────────────────

def _pvc(name: str = "test-pvc", sc: str = "local-path", ns: str = "default") -> dict:
    return {
        "apiVersion": "v1",
        "kind": "PersistentVolumeClaim",
        "metadata": {
            "name": name,
            "namespace": ns,
            "uid": "abc-123",
            "resourceVersion": "99999",
        },
        "spec": {
            "storageClassName": sc,
            "accessModes": ["ReadWriteOnce"],
        },
        "status": {"phase": "Bound"},
    }


def _deployment(name: str = "my-app", ns: str = "production") -> dict:
    return {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": name,
            "namespace": ns,
            "uid": "def-456",
            "resourceVersion": "1234",
            "managedFields": [{"manager": "kubectl"}],
        },
        "spec": {
            "replicas": 2,
            "template": {
                "spec": {
                    "nodeSelector": {"zone": "ospc-az1"},
                    "affinity": {"nodeAffinity": {}},
                    "tolerations": [{"key": "dedicated", "operator": "Equal"}],
                    "containers": [{"name": "app", "image": "myapp:1.0"}],
                }
            },
        },
        "status": {"availableReplicas": 2},
    }


def _ingress(name: str = "web-ingress", ns: str = "default") -> dict:
    return {
        "apiVersion": "networking.k8s.io/v1",
        "kind": "Ingress",
        "metadata": {
            "name": name,
            "namespace": ns,
            "annotations": {"kubernetes.io/ingress.class": "traefik"},
        },
        "spec": {
            "ingressClassName": "traefik",
            "rules": [{"host": "old.internal"}],
        },
    }


# ── Storage class mapping ─────────────────────────────────────────────────────

class TestStorageMapping:
    def test_exact_match(self):
        sm = StorageMapping(old_to_new={"local-path": "cinder-fast"}, default="cinder-standard")
        assert sm.translate("local-path") == "cinder-fast"

    def test_fallback_to_default(self):
        sm = StorageMapping(old_to_new={"local-path": "cinder-fast"}, default="cinder-standard")
        assert sm.translate("unknown-sc") == "cinder-standard"

    def test_none_input_returns_default(self):
        sm = StorageMapping(default="cinder-standard")
        assert sm.translate(None) == "cinder-standard"

    def test_empty_string_returns_default(self):
        sm = StorageMapping(default="cinder-standard")
        assert sm.translate("") == "cinder-standard"

    def test_get_and_set_storage_class(self):
        pvc = _pvc(sc="local-path")
        assert get_storage_class(pvc) == "local-path"
        set_storage_class(pvc, "cinder-fast")
        assert get_storage_class(pvc) == "cinder-fast"


# ── Endpoint replacement ──────────────────────────────────────────────────────

class TestEndpointReplacement:
    def test_single_replacement(self):
        manifest = {"spec": {"env": [{"value": "http://old.internal/api"}]}}
        count = replace_endpoints(manifest, [("old.internal", "new.flex.cloud")])
        assert count == 1
        assert manifest["spec"]["env"][0]["value"] == "http://new.flex.cloud/api"

    def test_multiple_replacements(self):
        manifest = {
            "spec": {
                "env": [
                    {"value": "postgres.old.svc"},
                    {"value": "redis.old.svc"},
                ]
            }
        }
        count = replace_endpoints(manifest, [
            ("postgres.old.svc", "postgres.flex.svc"),
            ("redis.old.svc", "redis.flex.svc"),
        ])
        assert count == 2
        assert manifest["spec"]["env"][0]["value"] == "postgres.flex.svc"
        assert manifest["spec"]["env"][1]["value"] == "redis.flex.svc"

    def test_nested_dict_replacement(self):
        manifest = {"data": {"config.yaml": "host: old.internal\nport: 5432"}}
        count = replace_endpoints(manifest, [("old.internal", "new.flex.cloud")])
        assert count == 1
        assert "new.flex.cloud" in manifest["data"]["config.yaml"]

    def test_no_match_returns_zero(self):
        manifest = {"spec": {"env": [{"value": "http://something.else"}]}}
        count = replace_endpoints(manifest, [("old.internal", "new.flex.cloud")])
        assert count == 0

    def test_list_replacement(self):
        manifest = {"spec": {"hosts": ["old.internal", "other.host", "old.internal"]}}
        count = replace_endpoints(manifest, [("old.internal", "new.flex.cloud")])
        assert count == 2
        assert manifest["spec"]["hosts"] == ["new.flex.cloud", "other.host", "new.flex.cloud"]


# ── Runtime field stripping ───────────────────────────────────────────────────

class TestStripRuntimeFields:
    def test_strips_default_fields(self):
        pvc = _pvc()
        strip_runtime_fields(pvc)
        assert "uid" not in pvc["metadata"]
        assert "resourceVersion" not in pvc["metadata"]
        assert "status" not in pvc

    def test_strips_managed_fields(self):
        dep = _deployment()
        strip_runtime_fields(dep)
        assert "managedFields" not in dep["metadata"]

    def test_extra_fields_stripped(self):
        manifest = {
            "kind": "ConfigMap",
            "metadata": {"name": "cfg", "annotations": {"last-applied": "v1"}},
        }
        strip_runtime_fields(manifest, extra_fields=["metadata.annotations"])
        assert "annotations" not in manifest["metadata"]

    def test_missing_fields_no_error(self):
        manifest = {"kind": "ConfigMap", "metadata": {"name": "cfg"}}
        # Should not raise even if fields are missing
        strip_runtime_fields(manifest)


# ── Ingress class remapping ───────────────────────────────────────────────────

class TestIngressMapping:
    def test_get_ingress_class_from_spec(self):
        ingress = _ingress()
        assert get_ingress_class(ingress) == "traefik"

    def test_get_ingress_class_from_annotation(self):
        ingress = _ingress()
        del ingress["spec"]["ingressClassName"]
        assert get_ingress_class(ingress) == "traefik"

    def test_set_ingress_class_updates_both(self):
        ingress = _ingress()
        set_ingress_class(ingress, "nginx")
        assert ingress["spec"]["ingressClassName"] == "nginx"
        assert ingress["metadata"]["annotations"]["kubernetes.io/ingress.class"] == "nginx"

    def test_ingress_mapping_translate(self):
        im = IngressMapping(old_to_new={"traefik": "nginx"}, default="nginx")
        assert im.translate("traefik") == "nginx"
        assert im.translate("unknown") == "nginx"
        assert im.translate(None) == "nginx"


# ── Scheduling field removal ──────────────────────────────────────────────────

class TestSchedulingFields:
    def test_remove_node_selectors(self):
        dep = _deployment()
        result = remove_node_selectors(dep)
        assert result is True
        pod_spec = dep["spec"]["template"]["spec"]
        assert "nodeSelector" not in pod_spec

    def test_remove_affinity(self):
        dep = _deployment()
        result = remove_affinity(dep)
        assert result is True
        pod_spec = dep["spec"]["template"]["spec"]
        assert "affinity" not in pod_spec

    def test_remove_tolerations(self):
        dep = _deployment()
        result = remove_tolerations(dep)
        assert result is True
        pod_spec = dep["spec"]["template"]["spec"]
        assert "tolerations" not in pod_spec

    def test_remove_absent_field_returns_false(self):
        dep = _deployment()
        del dep["spec"]["template"]["spec"]["nodeSelector"]
        result = remove_node_selectors(dep)
        assert result is False


# ── Kind categorisation ───────────────────────────────────────────────────────

class TestCategorizeKind:
    @pytest.mark.parametrize("kind,expected", [
        ("Deployment", "workload"),
        ("StatefulSet", "workload"),
        ("DaemonSet", "workload"),
        ("PersistentVolumeClaim", "storage"),
        ("PersistentVolume", "storage"),
        ("StorageClass", "storage"),
        ("Service", "network"),
        ("Ingress", "network"),
        ("ConfigMap", "config"),
        ("Secret", "config"),
        ("Namespace", "namespace"),
        ("CustomResourceDefinition", "crd"),
        ("ClusterRole", "rbac"),
        ("PodDisruptionBudget", "policy"),
        ("SomeCRD", "other"),
    ])
    def test_categories(self, kind, expected):
        assert categorize_kind(kind) == expected


# ── Restore ordering ──────────────────────────────────────────────────────────

class TestRestoreOrdering:
    def test_namespace_before_deployment(self):
        assert restore_priority("Namespace") < restore_priority("Deployment")

    def test_crd_before_namespace(self):
        assert restore_priority("CustomResourceDefinition") < restore_priority("Namespace")

    def test_rbac_before_configmap(self):
        assert restore_priority("Role") < restore_priority("ConfigMap")

    def test_sort_manifests(self):
        manifests = [
            {"kind": "Deployment", "metadata": {"name": "app"}},
            {"kind": "Namespace", "metadata": {"name": "prod"}},
            {"kind": "CustomResourceDefinition", "metadata": {"name": "foo.crd"}},
            {"kind": "Secret", "metadata": {"name": "db-creds"}},
        ]
        sorted_m = sort_manifests_for_restore(manifests)
        kinds = [m["kind"] for m in sorted_m]
        assert kinds.index("CustomResourceDefinition") < kinds.index("Namespace")
        assert kinds.index("Namespace") < kinds.index("Secret")
        assert kinds.index("Secret") < kinds.index("Deployment")


# ── transform_manifest exclusion ─────────────────────────────────────────────

class TestTransformManifestExclusions:
    def _default_plan(self) -> MigrationPlan:
        return MigrationPlan()

    def test_excluded_kind_returns_none(self):
        plan = self._default_plan()
        plan.exclude_kinds = ["Event"]
        manifest = {"kind": "Event", "metadata": {"name": "e1"}}
        report = TransformReport()
        result = transform_manifest(manifest, plan, report)
        assert result is None
        assert report.skipped == 1

    def test_excluded_namespace_returns_none(self):
        plan = self._default_plan()
        plan.exclude_namespaces = ["kube-system"]
        manifest = {
            "kind": "ConfigMap",
            "metadata": {"name": "cfg", "namespace": "kube-system"},
        }
        report = TransformReport()
        result = transform_manifest(manifest, plan, report)
        assert result is None

    def test_excluded_secret_name_returns_none(self):
        plan = self._default_plan()
        plan.exclude_secret_names = ["tls-secret"]
        manifest = {
            "kind": "Secret",
            "metadata": {"name": "tls-secret", "namespace": "default"},
        }
        report = TransformReport()
        result = transform_manifest(manifest, plan, report)
        assert result is None

    def test_include_namespace_filter(self):
        plan = self._default_plan()
        plan.include_namespaces = ["prod"]
        manifest = {
            "kind": "Deployment",
            "metadata": {"name": "app", "namespace": "staging"},
            "spec": {"template": {"spec": {}}},
            "status": {},
        }
        report = TransformReport()
        result = transform_manifest(manifest, plan, report)
        assert result is None
        assert report.skipped == 1

    def test_valid_manifest_passes_through(self):
        plan = self._default_plan()
        pvc = _pvc()
        report = TransformReport()
        result = transform_manifest(pvc, plan, report)
        assert result is not None
        assert report.total_output == 1
        # Runtime fields should be stripped
        assert "uid" not in result["metadata"]
        assert "status" not in result

    def test_storage_class_remapped(self):
        plan = self._default_plan()
        plan.storage_mapping = StorageMapping(
            old_to_new={"local-path": "cinder-fast"},
            default="cinder-standard",
        )
        pvc = _pvc(sc="local-path")
        report = TransformReport()
        result = transform_manifest(pvc, plan, report)
        assert result is not None
        assert get_storage_class(result) == "cinder-fast"
        assert len(report.storage_remaps) == 1
