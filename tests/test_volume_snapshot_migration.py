"""
tests/test_volume_snapshot_migration.py
Unit tests for the OSPC → FLEX Cinder volume snapshot direct-stream migration.

Run:  pytest -q tests/test_volume_snapshot_migration.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import MagicMock, patch, call

# ---------------------------------------------------------------------------
# Load the module under test without requiring it to be installed.
# ---------------------------------------------------------------------------
_MODULE_PATH = os.path.join(
    os.path.dirname(__file__), "..",
    "services", "api", "workflows", "volume_snapshot_migration.py",
)
_spec = importlib.util.spec_from_file_location("volume_snapshot_migration", _MODULE_PATH)
vsm = importlib.util.module_from_spec(_spec)
sys.modules["volume_snapshot_migration"] = vsm  # required so @dataclass can resolve cls.__module__
_spec.loader.exec_module(vsm)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_openrc() -> str:
    fd, path = tempfile.mkstemp(suffix=".sh")
    with os.fdopen(fd, "w") as f:
        f.write("#!/usr/bin/env bash\nexport OS_AUTH_URL=https://example.com\n")
    return path


def _make_key(mode: int = 0o600) -> str:
    fd, path = tempfile.mkstemp(suffix=".pem")
    os.close(fd)
    os.chmod(path, mode)
    return path


def _minimal_config(**overrides) -> vsm.VolumeSnapshotMigrationConfig:
    ospc_rc = _make_openrc()
    flex_rc = _make_openrc()
    key = _make_key()
    defaults = dict(
        ospc_openrc=ospc_rc,
        flex_openrc=flex_rc,
        ospc_snapshot="snap-abc123",
        ospc_helper_vm="ospc-helper",
        flex_helper_vm="flex-helper",
        flex_helper_ip="10.0.0.1",
        target_volume_name="test-vol",
        target_size_gb=75,
        ssh_key_path=key,
        dry_run=True,
    )
    defaults.update(overrides)
    return vsm.VolumeSnapshotMigrationConfig(**defaults)


# ---------------------------------------------------------------------------
# 1. Input validation
# ---------------------------------------------------------------------------

class TestValidateInputs(unittest.TestCase):

    def _run(self, cfg):
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        list(vsm._stage_validate_inputs(cfg, result))
        return result.steps[-1]

    def test_all_valid(self):
        cfg = _minimal_config()
        step = self._run(cfg)
        self.assertEqual(step.status, "success")

    def test_missing_snapshot(self):
        cfg = _minimal_config(ospc_snapshot="")
        step = self._run(cfg)
        self.assertEqual(step.status, "failed")
        self.assertIn("ospc_snapshot", step.message)

    def test_missing_ospc_helper(self):
        cfg = _minimal_config(ospc_helper_vm="")
        step = self._run(cfg)
        self.assertEqual(step.status, "failed")
        self.assertIn("ospc_helper_vm", step.message)

    def test_missing_flex_helper(self):
        cfg = _minimal_config(flex_helper_vm="")
        step = self._run(cfg)
        self.assertEqual(step.status, "failed")
        self.assertIn("flex_helper_vm", step.message)

    def test_attach_final_vm_requires_target(self):
        cfg = _minimal_config(attach_to_final_vm=True, flex_target_vm="")
        step = self._run(cfg)
        self.assertEqual(step.status, "failed")
        self.assertIn("flex_target_vm", step.message)

    def test_missing_ssh_key(self):
        cfg = _minimal_config(ssh_key_path="/nonexistent/key.pem")
        step = self._run(cfg)
        self.assertEqual(step.status, "failed")
        self.assertIn("SSH key not found", step.message)

    def test_unsafe_ssh_key_permissions(self):
        key = _make_key(mode=0o644)
        cfg = _minimal_config(ssh_key_path=key)
        step = self._run(cfg)
        self.assertEqual(step.status, "failed")
        self.assertIn("permissions too open", step.message)

    def test_size_zero_fails(self):
        cfg = _minimal_config(target_size_gb=0)
        step = self._run(cfg)
        self.assertEqual(step.status, "failed")
        self.assertIn("target_size_gb", step.message)

    def test_source_device_root_rejected(self):
        cfg = _minimal_config(source_device="/dev/vda")
        step = self._run(cfg)
        self.assertEqual(step.status, "failed")
        self.assertIn("root disk", step.message)

    def test_target_device_root_rejected(self):
        cfg = _minimal_config(target_device="/dev/sda")
        step = self._run(cfg)
        self.assertEqual(step.status, "failed")
        self.assertIn("root disk", step.message)

    def test_missing_flex_helper_ip(self):
        cfg = _minimal_config(flex_helper_ip="")
        step = self._run(cfg)
        self.assertEqual(step.status, "failed")


# ---------------------------------------------------------------------------
# 2. Root-disk detection
# ---------------------------------------------------------------------------

class TestRootDiskDetection(unittest.TestCase):

    def test_vda_is_root(self):
        self.assertTrue(vsm._is_root_device("/dev/vda"))

    def test_sda_is_root(self):
        self.assertTrue(vsm._is_root_device("/dev/sda"))

    def test_xvda_is_root(self):
        self.assertTrue(vsm._is_root_device("/dev/xvda"))

    def test_nvme0n1_is_root(self):
        self.assertTrue(vsm._is_root_device("/dev/nvme0n1"))

    def test_vdb_not_root(self):
        self.assertFalse(vsm._is_root_device("/dev/vdb"))

    def test_sdb_not_root(self):
        self.assertFalse(vsm._is_root_device("/dev/sdb"))

    def test_xvdj_not_root(self):
        self.assertFalse(vsm._is_root_device("/dev/xvdj"))


# ---------------------------------------------------------------------------
# 3. Snapshot status parsing
# ---------------------------------------------------------------------------

class TestInspectSnapshot(unittest.TestCase):

    def _run_with_mock(self, openstack_output: dict, rc: int = 0):
        cfg = _minimal_config(dry_run=False)
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        mock_proc = MagicMock()
        mock_proc.returncode = rc
        mock_proc.stdout = json.dumps(openstack_output)
        mock_proc.stderr = ""
        with patch.object(vsm, "run_openstack", return_value=mock_proc):
            list(vsm._stage_inspect_snapshot(cfg, result))
        return result

    def test_available_snapshot_succeeds(self):
        result = self._run_with_mock({"id": "snap-1", "name": "my-snap", "size": 75, "status": "available", "volume_id": "vol-x"})
        self.assertEqual(result.steps[-1].status, "success")
        self.assertEqual(result.source_snapshot_id, "snap-1")

    def test_non_available_status_fails(self):
        result = self._run_with_mock({"id": "snap-1", "size": 75, "status": "creating", "volume_id": "vol-x"})
        self.assertEqual(result.steps[-1].status, "failed")
        self.assertIn("status=creating", result.steps[-1].message)

    def test_error_status_fails(self):
        result = self._run_with_mock({"id": "snap-1", "size": 75, "status": "error", "volume_id": ""})
        self.assertEqual(result.steps[-1].status, "failed")

    def test_openstack_command_failure(self):
        result = self._run_with_mock({}, rc=1)
        self.assertEqual(result.steps[-1].status, "failed")
        self.assertIn("snapshot show failed", result.steps[-1].message)

    def test_dry_run_skips_api(self):
        cfg = _minimal_config(dry_run=True)
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        with patch.object(vsm, "run_openstack") as mock_os:
            list(vsm._stage_inspect_snapshot(cfg, result))
            mock_os.assert_not_called()
        self.assertEqual(result.steps[-1].status, "dry_run")

    def test_size_check_fails_when_target_smaller(self):
        cfg = _minimal_config(dry_run=False, target_size_gb=10)
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.stdout = json.dumps({"id": "snap-1", "size": 75, "status": "available"})
        mock_proc.stderr = ""
        with patch.object(vsm, "run_openstack", return_value=mock_proc):
            list(vsm._stage_inspect_snapshot(cfg, result))
        self.assertEqual(result.steps[-1].status, "failed")
        self.assertIn("target_size_gb=10", result.steps[-1].message)


# ---------------------------------------------------------------------------
# 4. Size comparison
# ---------------------------------------------------------------------------

class TestSizeComparison(unittest.TestCase):

    def _make_ssh_mock(self, src_bytes: int, tgt_bytes: int):
        def _side_effect(ip, user, key, cmd, timeout=60):
            m = MagicMock()
            m.returncode = 0
            m.stdout = str(src_bytes) if "ospc" in ip else str(tgt_bytes)
            m.stderr = ""
            return m
        return _side_effect

    def test_target_smaller_than_source_fails(self):
        cfg = _minimal_config(dry_run=False, ospc_helper_ip="10.0.0.2")
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        with patch.object(vsm, "_ssh_run") as m:
            m.side_effect = lambda ip, user, key, cmd, timeout=60: MagicMock(
                returncode=0,
                stdout="107374182400" if "10.0.0.2" in ip else "53687091200",
                stderr="",
            )
            list(vsm._stage_pre_stream_validation(cfg, "/dev/vdb", "/dev/vdb", result))
        self.assertEqual(result.steps[-1].status, "failed")
        self.assertIn("target", result.steps[-1].message)

    def test_target_equal_passes(self):
        cfg = _minimal_config(dry_run=False, ospc_helper_ip="10.0.0.2", flex_helper_ip="10.0.0.1")
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        call_count = [0]
        def _mock_ssh(ip, user, key, cmd, timeout=60):
            call_count[0] += 1
            m = MagicMock()
            m.returncode = 0
            if "blockdev" in cmd:
                m.stdout = "107374182400"
            elif "OSPC2FLEX_SSH_OK" in cmd:
                m.stdout = "OSPC2FLEX_SSH_OK"
            else:
                m.stdout = ""
            m.stderr = ""
            return m
        with patch.object(vsm, "_ssh_run", side_effect=_mock_ssh):
            list(vsm._stage_pre_stream_validation(cfg, "/dev/vdb", "/dev/vdb", result))
        self.assertEqual(result.steps[-1].status, "success")


# ---------------------------------------------------------------------------
# 5. Stream copy command generation
# ---------------------------------------------------------------------------

class TestStreamCopyCommandGeneration(unittest.TestCase):

    def test_dry_run_returns_command_in_summary(self):
        cfg = _minimal_config(dry_run=True, flex_helper_ip="10.0.0.1", flex_helper_user="ubuntu")
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        list(vsm._stage_stream_copy(cfg, "/dev/vdb", "/dev/vdb", result))
        self.assertTrue(any("dd" in c and "gzip" in c for c in result.commands_summary))

    def test_stream_command_contains_expected_pieces(self):
        cfg = _minimal_config(
            dry_run=True, flex_helper_ip="192.168.1.50",
            flex_helper_user="ubuntu", source_device="/dev/vdb",
        )
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        logs = list(vsm._stage_stream_copy(cfg, "/dev/vdb", "/dev/vdb", result))
        cmd_summary = " ".join(result.commands_summary)
        self.assertIn("dd if=/dev/vdb", cmd_summary)
        self.assertIn("gzip -1", cmd_summary)
        self.assertIn("192.168.1.50", cmd_summary)
        self.assertIn("gunzip", cmd_summary)
        self.assertIn("dd of=/dev/vdb", cmd_summary)
        self.assertIn("conv=fsync", cmd_summary)

    def test_no_ospc_helper_ip_fails_non_dryrun(self):
        cfg = _minimal_config(dry_run=False, ospc_helper_ip="")
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        list(vsm._stage_stream_copy(cfg, "/dev/vdb", "/dev/vdb", result))
        self.assertEqual(result.steps[-1].status, "failed")
        self.assertIn("ospc_helper_ip", result.steps[-1].message)


# ---------------------------------------------------------------------------
# 6. Rollback behaviour
# ---------------------------------------------------------------------------

class TestRollback(unittest.TestCase):

    def test_rollback_deletes_ospc_volume_when_cleanup_true(self):
        cfg = _minimal_config(dry_run=False, cleanup_temp_ospc_volume=True)
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        mock_proc = MagicMock(returncode=0, stdout="", stderr="")
        with patch.object(vsm, "run_openstack", return_value=mock_proc) as mock_os:
            list(vsm._rollback(cfg, "vol-ospc-123", "", result))
        calls_str = " ".join(str(c) for c in mock_os.call_args_list)
        self.assertIn("vol-ospc-123", calls_str)
        self.assertIn("delete", calls_str)

    def test_rollback_keeps_flex_volume_by_default(self):
        cfg = _minimal_config(dry_run=False, cleanup_temp_ospc_volume=False, rollback_delete_flex_volume=False)
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        mock_proc = MagicMock(returncode=0, stdout="", stderr="")
        with patch.object(vsm, "run_openstack", return_value=mock_proc) as mock_os:
            logs = list(vsm._rollback(cfg, "", "flex-vol-456", result))
        calls_str = " ".join(str(c) for c in mock_os.call_args_list)
        self.assertNotIn("delete", calls_str.lower() if "flex-vol-456" in calls_str else "")
        self.assertTrue(any("kept for inspection" in l for l in logs))

    def test_rollback_deletes_flex_when_flag_set(self):
        cfg = _minimal_config(dry_run=False, rollback_delete_flex_volume=True)
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        mock_proc = MagicMock(returncode=0, stdout="", stderr="")
        with patch.object(vsm, "run_openstack", return_value=mock_proc) as mock_os:
            list(vsm._rollback(cfg, "", "flex-vol-789", result))
        calls_str = " ".join(str(c) for c in mock_os.call_args_list)
        self.assertIn("flex-vol-789", calls_str)

    def test_rollback_dry_run_noop(self):
        cfg = _minimal_config(dry_run=True)
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        with patch.object(vsm, "run_openstack") as mock_os:
            list(vsm._rollback(cfg, "vol-1", "flex-1", result))
            mock_os.assert_not_called()


# ---------------------------------------------------------------------------
# 7. Full dry-run pipeline (smoke test)
# ---------------------------------------------------------------------------

class TestFullDryRunPipeline(unittest.TestCase):

    def test_full_dry_run_completes_success(self):
        cfg = _minimal_config(dry_run=True, attach_to_final_vm=True, flex_target_vm="my-flex-vm")
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        logs = list(vsm.migrate_volume_snapshot_to_flex_stream(cfg, result))
        self.assertEqual(result.status, "success")
        step_names = [s.name for s in result.steps]
        # All 14 stages should appear (some as skipped/dry_run)
        for expected in [
            "validate_inputs",
            "ospc_snapshot",
            "temporary_ospc_volume",
            "attach_temp_volume_to_ospc_helper_vm",
            "create_blank_flex_cinder_volume",
            "attach_flex_volume_to_flex_helper_vm",
            "pre_stream_validation",
            "stream_block_device_over_ssh",
            "post_stream_validation",
            "detach_from_helper",
            "attach_final_flex_volume_to_target_vm",
            "VOL_POST_ATTACH_VALIDATE",
            "cleanup",
        ]:
            self.assertIn(expected, step_names, f"Stage '{expected}' missing from pipeline")

    def test_full_dry_run_no_openstack_calls(self):
        cfg = _minimal_config(dry_run=True)
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        with patch.object(vsm, "run_openstack") as mock_os:
            list(vsm.migrate_volume_snapshot_to_flex_stream(cfg, result))
            mock_os.assert_not_called()

    def test_full_dry_run_no_ssh_calls(self):
        cfg = _minimal_config(dry_run=True)
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        with patch.object(vsm, "_ssh_run") as mock_ssh:
            list(vsm.migrate_volume_snapshot_to_flex_stream(cfg, result))
            mock_ssh.assert_not_called()


# ---------------------------------------------------------------------------
# 8. run_openstack credential isolation
# ---------------------------------------------------------------------------

class TestRunOpenstackIsolation(unittest.TestCase):

    def test_os_env_vars_stripped(self):
        captured_env = {}
        def _fake_run(cmd, **kwargs):
            captured_env.update(kwargs.get("env", {}))
            return MagicMock(returncode=0, stdout="", stderr="")

        osrc = _make_openrc()
        with patch("subprocess.run", side_effect=_fake_run):
            vsm.run_openstack(osrc, ["volume", "list"])

        for k in captured_env:
            # OS_CLIENT_CONFIG_FILE is intentionally injected by run_openstack to suppress clouds.yaml
            if k == "OS_CLIENT_CONFIG_FILE":
                continue
            self.assertFalse(k.startswith("OS_"), f"OS_ var leaked: {k}")


# ---------------------------------------------------------------------------
# 9. Result serialisation
# ---------------------------------------------------------------------------

class TestResultSerialisation(unittest.TestCase):

    def test_as_dict_complete(self):
        r = vsm.VolumeSnapshotMigrationResult(status="success")
        r.source_snapshot_id = "snap-1"
        r.temp_ospc_volume_id = "vol-tmp"
        r.flex_volume_id = "flex-vol"
        r.attached_to_final_vm = True
        r.steps.append(vsm.VolumeSnapshotMigrationStepResult(
            name="validate_inputs", status="success", message="OK",
            started_at="2026-01-01T00:00:00+00:00", ended_at="2026-01-01T00:00:01+00:00"
        ))
        d = r.as_dict()
        self.assertEqual(d["status"], "success")
        self.assertEqual(d["flex_volume_id"], "flex-vol")
        self.assertTrue(d["attached_to_final_vm"])
        self.assertEqual(len(d["steps"]), 1)
        self.assertEqual(d["steps"][0]["name"], "validate_inputs")
        self.assertIn("source_bytes", d["validation"])
        json.dumps(d)  # must be JSON-serialisable


if __name__ == "__main__":
    unittest.main()
