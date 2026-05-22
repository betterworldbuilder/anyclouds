from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch


REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "services" / "api" / "workflows" / "volume_snapshot_migration.py"
SCRIPT_PATH = REPO_ROOT / "scripts" / "osflex_post_attach_pg_mount_validate.sh"

spec = importlib.util.spec_from_file_location("volume_snapshot_migration_pg", MODULE_PATH)
vsm = importlib.util.module_from_spec(spec)
sys.modules["volume_snapshot_migration_pg"] = vsm
spec.loader.exec_module(vsm)


def _make_openrc() -> str:
    fd, path = tempfile.mkstemp(suffix=".sh")
    with os.fdopen(fd, "w") as f:
        f.write("export OS_AUTH_URL=https://example.com\n")
    return path


def _make_key() -> str:
    fd, path = tempfile.mkstemp(suffix=".pem")
    os.close(fd)
    os.chmod(path, 0o600)
    return path


def _cfg(**overrides) -> vsm.VolumeSnapshotMigrationConfig:
    tmp = tempfile.mkdtemp()
    defaults = dict(
        ospc_openrc=_make_openrc(),
        flex_openrc=_make_openrc(),
        ospc_snapshot="snap-1",
        ospc_helper_vm="ospc-helper",
        flex_helper_vm="flex-helper",
        flex_helper_ip="10.0.0.5",
        target_volume_name="pg-vol",
        target_size_gb=75,
        ssh_key_path=_make_key(),
        post_attach_ssh_key_path=_make_key(),
        post_attach_artifact_dir=tmp,
        post_attach_script_path=str(SCRIPT_PATH),
    )
    defaults.update(overrides)
    return vsm.VolumeSnapshotMigrationConfig(**defaults)


class TestPostAttachScriptSafety(unittest.TestCase):
    def test_script_syntax(self):
        proc = subprocess.run(["bash", "-n", str(SCRIPT_PATH)], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_script_has_required_detection_paths(self):
        text = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertIn("DEV_HINT", text)
        self.assertIn("first_fs_partition", text)
        self.assertIn("whole_disk_fstype", text)
        self.assertIn("vgchange -ay", text)
        self.assertIn("cryptsetup isLuks", text)
        self.assertIn("PG_VERSION", text)
        self.assertIn("data_directory", text)
        self.assertIn("preferred_drinks", text)

    def test_script_does_not_format_or_repair(self):
        text = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertNotIn("mkfs", text)
        self.assertNotIn("xfs_repair", text)
        self.assertNotIn("fsck -y", text)


class TestPostAttachBackend(unittest.TestCase):
    def test_backend_skips_when_disabled(self):
        cfg = _cfg(post_attach_validate_mount=False, post_attach_validate_pg=False)
        result = vsm.run_post_attach_pg_validation({"flex_volume_id": "vol-1"}, cfg)
        self.assertEqual(result["post_attach_validation_status"], "skipped")
        self.assertTrue(Path(result["result_path"]).is_file())

    def test_stage_only_runs_when_enabled_and_final_attach_succeeded(self):
        cfg = _cfg(post_attach_validate_mount=True, dry_run=False)
        result = vsm.VolumeSnapshotMigrationResult(status="running")
        list(vsm._stage_post_attach_pg_validate(cfg, "vol-1", result))
        self.assertEqual(result.steps[-1].status, "skipped")
        self.assertEqual(result.validation.post_attach_validation_status, "skipped")

    def test_generic_mount_validation_does_not_enable_pg(self):
        cfg = _cfg(post_attach_validate_mount=True, post_attach_validate_pg=False, post_attach_device_hint="/dev/vdd")
        commands = []

        def fake_run(cmd, **kwargs):
            commands.append(cmd)
            stdout = kwargs.get("stdout")
            if stdout and hasattr(stdout, "write"):
                stdout.write("[OSFLEX-VOL-POSTATTACH] Mount point: /mnt/osflex-volume\n")
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch.object(vsm, "_resolve_server_ip", return_value="10.60.0.59"), \
             patch.object(vsm.subprocess, "run", side_effect=fake_run):
            result = vsm.run_post_attach_pg_validation(
                {"flex_volume_id": "vol-1", "flex_target_vm_id": "vm-1"},
                cfg,
            )

        joined = " ".join(" ".join(c) if isinstance(c, list) else str(c) for c in commands)
        self.assertIn("VALIDATE_PG=false", joined)
        self.assertEqual(result["post_attach_validation_status"], "success")

    def test_device_hint_passed_to_remote_command(self):
        cfg = _cfg(
            post_attach_validate_mount=True,
            post_attach_validate_pg=True,
            post_attach_device_hint="/dev/vdd",
            post_attach_mount_point="/mnt/pgdata",
            post_attach_pg_db_name="openstack_drinks",
            post_attach_pg_table_name="preferred_drinks",
        )

        commands = []

        def fake_run(cmd, **kwargs):
            commands.append(cmd)
            stdout = kwargs.get("stdout")
            if stdout and hasattr(stdout, "write"):
                stdout.write("[OSFLEX-PG-POSTATTACH] Mount point: /mnt/pgdata\n")
                stdout.write("[OSFLEX-PG-POSTATTACH] Detected PostgreSQL data directory: /mnt/pgdata/postgresql/14/main\n")
                stdout.write("[OSFLEX-PG-POSTATTACH] Row count:\n10\n")
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch.object(vsm, "_resolve_server_ip", return_value="10.60.0.59"), \
             patch.object(vsm.subprocess, "run", side_effect=fake_run):
            result = vsm.run_post_attach_pg_validation(
                {"flex_volume_id": "vol-1", "flex_target_vm_id": "vm-1"},
                cfg,
            )

        joined = " ".join(" ".join(c) if isinstance(c, list) else str(c) for c in commands)
        self.assertIn("DEV_HINT=/dev/vdd", joined)
        self.assertIn("MOUNT_POINT=/mnt/pgdata", joined)
        self.assertEqual(result["post_attach_validation_status"], "success")
        self.assertEqual(result["post_attach_query_row_count"], 10)

    def test_missing_target_ip_fails_safely(self):
        cfg = _cfg(post_attach_validate_mount=True, flex_helper_ip="")
        with patch.object(vsm, "_resolve_server_ip", return_value=""):
            result = vsm.run_post_attach_pg_validation({"flex_volume_id": "vol-1", "flex_target_vm_id": "vm-1"}, cfg)
        self.assertEqual(result["post_attach_validation_status"], "failed")
        self.assertEqual(result["reason"], "target_vm_ip_not_resolved")

    def test_result_serializes_post_attach_fields(self):
        result = vsm.VolumeSnapshotMigrationResult(status="success")
        result.validation.post_attach_validation_status = "success"
        result.validation.post_attach_query_row_count = 10
        data = result.as_dict()
        self.assertEqual(data["validation"]["post_attach_validation_status"], "success")
        self.assertEqual(data["validation"]["post_attach_query_row_count"], 10)
        json.dumps(data)


if __name__ == "__main__":
    unittest.main()
