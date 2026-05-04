"""
Unit tests for validator.py.

Tests the validation_summary helper and the ValidationResult model.
The individual check functions (check_nodes_ready, etc.) require a live
cluster and are tested via integration tests; here we test the pure logic.
New tests cover validate_magnum_cluster, validate_loadbalancer, and the
MAGNUM_VALIDATION_CHECKS constant.
"""
from __future__ import annotations

from unittest.mock import patch, MagicMock

import pytest

from ospc_to_flex_k8.models import ValidationResult
from ospc_to_flex_k8.validator import (
    validation_summary,
    validate_magnum_cluster,
    validate_loadbalancer,
    MAGNUM_VALIDATION_CHECKS,
)


# ── validation_summary ────────────────────────────────────────────────────────

class TestValidationSummary:
    def test_all_passed(self):
        results = [
            ValidationResult(check="nodes_ready", passed=True, detail="3 nodes Ready"),
            ValidationResult(check="pvcs_bound", passed=True, detail="5 PVCs Bound"),
        ]
        summary = validation_summary(results)
        assert summary["total"] == 2
        assert summary["passed"] == 2
        assert summary["failed"] == 0
        assert summary["all_passed"] is True

    def test_one_failure(self):
        results = [
            ValidationResult(check="nodes_ready", passed=True, detail="ok"),
            ValidationResult(check="deployments_available", passed=False,
                             detail="1 deployment not available"),
        ]
        summary = validation_summary(results)
        assert summary["total"] == 2
        assert summary["passed"] == 1
        assert summary["failed"] == 1
        assert summary["all_passed"] is False

    def test_all_failed(self):
        results = [
            ValidationResult(check="nodes_ready", passed=False, detail="no nodes"),
        ]
        summary = validation_summary(results)
        assert summary["all_passed"] is False
        assert summary["failed"] == 1

    def test_empty_results(self):
        summary = validation_summary([])
        assert summary["total"] == 0
        assert summary["all_passed"] is True

    def test_summary_contains_result_dicts(self):
        results = [
            ValidationResult(check="pvcs_bound", passed=True, detail="all bound"),
        ]
        summary = validation_summary(results)
        assert isinstance(summary["results"], list)
        assert summary["results"][0] == {
            "check": "pvcs_bound",
            "passed": True,
            "detail": "all bound",
        }


# ── MAGNUM_VALIDATION_CHECKS constant ────────────────────────────────────────

class TestMagnumValidationChecks:
    def test_is_list(self):
        assert isinstance(MAGNUM_VALIDATION_CHECKS, list)

    def test_contains_required_checks(self):
        required = [
            "magnum_cluster_status",
            "loadbalancer_test",
            "kubectl_nodes",
            "pvc_binding",
            "svc_endpoints",
            "ingress_objects",
        ]
        for check in required:
            assert check in MAGNUM_VALIDATION_CHECKS, f"Missing: {check}"

    def test_all_strings(self):
        for item in MAGNUM_VALIDATION_CHECKS:
            assert isinstance(item, str)


# ── validate_magnum_cluster ───────────────────────────────────────────────────

class TestValidateMagnumCluster:
    def test_skipped_when_openstack_not_available(self):
        with patch("ospc_to_flex_k8.validator.shutil.which", return_value=None):
            result = validate_magnum_cluster("my-cluster")
        assert result.check == "magnum_cluster_status"
        assert result.passed is True
        assert "skipped" in result.detail.lower()

    def test_passes_on_create_complete(self):
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = "CREATE_COMPLETE\n"
        mock_proc.stderr = ""
        with patch("ospc_to_flex_k8.validator.shutil.which", return_value="/usr/bin/openstack"), \
             patch("ospc_to_flex_k8.validator.subprocess.run", return_value=mock_proc):
            result = validate_magnum_cluster("my-cluster")
        assert result.passed is True
        assert "CREATE_COMPLETE" in result.detail

    def test_fails_on_create_failed(self):
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = "CREATE_FAILED\n"
        mock_proc.stderr = ""
        with patch("ospc_to_flex_k8.validator.shutil.which", return_value="/usr/bin/openstack"), \
             patch("ospc_to_flex_k8.validator.subprocess.run", return_value=mock_proc):
            result = validate_magnum_cluster("my-cluster")
        assert result.passed is False
        assert "CREATE_FAILED" in result.detail

    def test_fails_on_cli_error(self):
        mock_proc = MagicMock()
        mock_proc.returncode = 1
        mock_proc.stdout = ""
        mock_proc.stderr = "Authentication error"
        with patch("ospc_to_flex_k8.validator.shutil.which", return_value="/usr/bin/openstack"), \
             patch("ospc_to_flex_k8.validator.subprocess.run", return_value=mock_proc):
            result = validate_magnum_cluster("my-cluster")
        assert result.passed is False
        assert "Authentication error" in result.detail

    def test_check_name_is_magnum_cluster_status(self):
        with patch("ospc_to_flex_k8.validator.shutil.which", return_value=None):
            result = validate_magnum_cluster("any-cluster")
        assert result.check == "magnum_cluster_status"


# ── validate_loadbalancer ─────────────────────────────────────────────────────

class TestValidateLoadbalancer:
    def test_returns_dict(self):
        result = validate_loadbalancer()
        assert isinstance(result, dict)

    def test_has_required_keys(self):
        result = validate_loadbalancer()
        for key in ("check", "service_yaml", "commands", "success_criteria", "notes"):
            assert key in result, f"Missing key: {key}"

    def test_check_key_is_loadbalancer_test(self):
        result = validate_loadbalancer()
        assert result["check"] == "loadbalancer_test"

    def test_service_yaml_is_loadbalancer_type(self):
        result = validate_loadbalancer()
        assert "LoadBalancer" in result["service_yaml"]

    def test_commands_is_list(self):
        result = validate_loadbalancer()
        assert isinstance(result["commands"], list)
        assert len(result["commands"]) > 0

    def test_custom_namespace_and_name(self):
        result = validate_loadbalancer(namespace="my-ns", service_name="my-svc")
        assert "my-ns" in result["service_yaml"]
        assert "my-svc" in result["service_yaml"]

    def test_kubeconfig_flag_included_in_commands(self):
        result = validate_loadbalancer(kubeconfig="/tmp/kc.yaml")
        for cmd in result["commands"]:
            assert "--kubeconfig=/tmp/kc.yaml" in cmd

    def test_notes_mentions_magnum_2025(self):
        result = validate_loadbalancer()
        assert "2025" in result["notes"] or "Magnum" in result["notes"]


# ── ValidationResult model ────────────────────────────────────────────────────

class TestValidationResult:
    def test_to_dict_structure(self):
        r = ValidationResult(check="nodes_ready", passed=True, detail="All good")
        d = r.to_dict()
        assert d["check"] == "nodes_ready"
        assert d["passed"] is True
        assert d["detail"] == "All good"

    def test_default_detail_is_empty_string(self):
        r = ValidationResult(check="something", passed=False)
        assert r.detail == ""
        assert r.to_dict()["detail"] == ""

    @pytest.mark.parametrize("passed", [True, False])
    def test_passed_values(self, passed: bool):
        r = ValidationResult(check="x", passed=passed)
        assert r.passed is passed
        assert r.to_dict()["passed"] is passed
