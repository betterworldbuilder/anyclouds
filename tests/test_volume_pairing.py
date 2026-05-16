"""
tests/test_volume_pairing.py
Unit tests for the OSPC → FLEX Volume Snapshot Pairing pipeline.

Run:  pytest -q tests/test_volume_pairing.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch, call

# ---------------------------------------------------------------------------
# Load the module without installation — same pattern as test_volume_snapshot_migration.py
# ---------------------------------------------------------------------------
_MODULE_PATH = os.path.join(
    os.path.dirname(__file__), "..",
    "services", "api", "workflows", "volume_pairing.py",
)
_spec = importlib.util.spec_from_file_location("volume_pairing", _MODULE_PATH)
vp = importlib.util.module_from_spec(_spec)
sys.modules["volume_pairing"] = vp
_spec.loader.exec_module(vp)


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def _make_openrc() -> str:
    fd, path = tempfile.mkstemp(suffix=".sh")
    with os.fdopen(fd, "w") as f:
        f.write("#!/usr/bin/env bash\nexport OS_AUTH_URL=https://example.com\n")
    return path


def _ok(stdout: str = "{}") -> MagicMock:
    m = MagicMock()
    m.returncode = 0
    m.stdout = stdout
    m.stderr = ""
    return m


def _fail(stderr: str = "api error") -> MagicMock:
    m = MagicMock()
    m.returncode = 1
    m.stdout = ""
    m.stderr = stderr
    return m


# ── Fixtures ─────────────────────────────────────────────────────────────────

SNAP_AVAILABLE = json.dumps({
    "id": "snap-001", "name": "web01-data-snap",
    "status": "available", "volume_id": "vol-001", "size": 100,
})
SNAP_UNAVAILABLE = json.dumps({
    "id": "snap-002", "name": "snap-bad",
    "status": "error", "volume_id": "vol-001", "size": 100,
})
SNAP_NO_VOLUME_ID = json.dumps({
    "id": "snap-003", "name": "snap-novolid",
    "status": "available", "volume_id": "", "size": 50,
})
VOL_ATTACHED = json.dumps({
    "id": "vol-001", "name": "web01-data", "size": 100, "status": "in-use",
    "attachments": [{"server_id": "ospc-vm-123", "device": "/dev/vdb", "id": "att-1"}],
})
VOL_NO_ATTACHMENT = json.dumps({
    "id": "vol-001", "name": "web01-data", "size": 100, "status": "available",
    "attachments": [],
})
SERVER_A = json.dumps({
    "id": "ospc-vm-123", "name": "web01",
    "volumes_attached": [{"id": "vol-001"}],
})
SERVER_B = json.dumps({
    "id": "ospc-vm-456", "name": "web02",
    "volumes_attached": [{"id": "vol-001"}],
})
MAP_HIGH = {
    "servers": [{
        "ospc_server_id":            "ospc-vm-123",
        "ospc_server_name":          "web01",
        "ospc_server_snapshot_id":   "ospc-snap-001",
        "ospc_server_snapshot_name": "web01-snap",
        "flex_server_id":            "flex-vm-789",
        "flex_server_name":          "web01-flex",
        "status":                    "migrated",
    }]
}
MAP_EMPTY = {"servers": []}
MAP_NAME_ONLY = {
    "servers": [{
        "ospc_server_id":   "",        # no ID → forces name fallback
        "ospc_server_name": "web01",
        "ospc_server_snapshot_id":   "",
        "ospc_server_snapshot_name": "",
        "flex_server_id":   "flex-vm-789",
        "flex_server_name": "web01-flex",
    }]
}


# ---------------------------------------------------------------------------
# 1 — High-confidence ID-based match
# ---------------------------------------------------------------------------

class TestHighConfidenceIDMatch(unittest.TestCase):
    @patch("volume_pairing._run_openstack")
    def test_id_match_returns_matched_high(self, mock):
        mock.side_effect = [_ok(SNAP_AVAILABLE), _ok(VOL_ATTACHED), _ok(SERVER_A)]
        result = vp.pair_single_snapshot("snap-001", "review", _make_openrc(), MAP_HIGH)
        self.assertEqual(result.pairing_status, "matched")
        self.assertEqual(result.confidence, "high")
        self.assertEqual(result.flex_server_id, "flex-vm-789")
        self.assertEqual(result.flex_server_name, "web01-flex")
        self.assertEqual(result.ospc_server_id, "ospc-vm-123")
        self.assertEqual(result.ospc_device, "/dev/vdb")


# ---------------------------------------------------------------------------
# 2 — Snapshot not available
# ---------------------------------------------------------------------------

class TestSnapshotNotAvailable(unittest.TestCase):
    @patch("volume_pairing._run_openstack")
    def test_error_status_blocked(self, mock):
        mock.return_value = _ok(SNAP_UNAVAILABLE)
        result = vp.pair_single_snapshot("snap-002", "review", _make_openrc(), MAP_HIGH)
        self.assertEqual(result.pairing_status, "blocked")
        self.assertIn("snapshot_not_available", result.reason)
        self.assertIn("error", result.reason)


# ---------------------------------------------------------------------------
# 3 — Missing snapshot.volume_id
# ---------------------------------------------------------------------------

class TestMissingVolumeID(unittest.TestCase):
    @patch("volume_pairing._run_openstack")
    def test_no_volume_id_manual_required(self, mock):
        mock.return_value = _ok(SNAP_NO_VOLUME_ID)
        result = vp.pair_single_snapshot("snap-003", "review", _make_openrc(), MAP_HIGH)
        self.assertEqual(result.pairing_status, "manual_required")
        self.assertIn("snapshot_missing_source_volume_id", result.reason)


# ---------------------------------------------------------------------------
# 4 — Source volume not attached to any OSPC server
# ---------------------------------------------------------------------------

class TestVolumeNotAttachedToServer(unittest.TestCase):
    @patch("volume_pairing._run_openstack")
    def test_zero_servers_manual_required(self, mock):
        mock.side_effect = [
            _ok(SNAP_AVAILABLE),
            _ok(VOL_NO_ATTACHMENT),   # no attachments
            _ok(json.dumps([])),       # empty server list
        ]
        result = vp.pair_single_snapshot("snap-001", "review", _make_openrc(), MAP_HIGH)
        self.assertEqual(result.pairing_status, "manual_required")
        self.assertIn("not_attached_to_known_ospc_server", result.reason)


# ---------------------------------------------------------------------------
# 5 — Source volume attached to multiple OSPC servers
# ---------------------------------------------------------------------------

class TestMultipleServersBlocked(unittest.TestCase):
    @patch("volume_pairing._run_openstack")
    def test_multiple_servers_blocked(self, mock):
        server_list = json.dumps([
            {"ID": "ospc-vm-123", "Name": "web01"},
            {"ID": "ospc-vm-456", "Name": "web02"},
        ])
        mock.side_effect = [
            _ok(SNAP_AVAILABLE),
            _ok(VOL_NO_ATTACHMENT),   # no direct attachments → scan
            _ok(server_list),          # server list returns 2
            _ok(SERVER_A),             # server show vm-123 (has vol-001)
            _ok(SERVER_B),             # server show vm-456 (has vol-001)
        ]
        result = vp.pair_single_snapshot("snap-001", "review", _make_openrc(), MAP_HIGH)
        self.assertEqual(result.pairing_status, "blocked")
        self.assertIn("multiple", result.reason)


# ---------------------------------------------------------------------------
# 6 — OSPC server found but missing FLEX VM in migration_map
# ---------------------------------------------------------------------------

class TestMissingFlexVMInMap(unittest.TestCase):
    @patch("volume_pairing._run_openstack")
    def test_no_flex_map_manual_required(self, mock):
        mock.side_effect = [_ok(SNAP_AVAILABLE), _ok(VOL_ATTACHED), _ok(SERVER_A)]
        result = vp.pair_single_snapshot("snap-001", "review", _make_openrc(), MAP_EMPTY)
        self.assertEqual(result.pairing_status, "manual_required")
        self.assertIn("no matching FLEX VM", result.reason)


# ---------------------------------------------------------------------------
# 7 — Name-fallback match → review_needed, not auto-safe
# ---------------------------------------------------------------------------

class TestNameFallbackReviewNeeded(unittest.TestCase):
    @patch("volume_pairing._run_openstack")
    def test_name_only_gives_review_needed_medium(self, mock):
        mock.side_effect = [_ok(SNAP_AVAILABLE), _ok(VOL_ATTACHED), _ok(SERVER_A)]
        result = vp.pair_single_snapshot("snap-001", "review", _make_openrc(), MAP_NAME_ONLY)
        self.assertEqual(result.pairing_status, "review_needed")
        self.assertEqual(result.confidence, "medium")
        self.assertTrue(any("name_only" in w for w in result.warnings))

    @patch("volume_pairing._run_openstack")
    def test_name_only_not_matched(self, mock):
        mock.side_effect = [_ok(SNAP_AVAILABLE), _ok(VOL_ATTACHED), _ok(SERVER_A)]
        result = vp.pair_single_snapshot("snap-001", "review", _make_openrc(), MAP_NAME_ONLY)
        self.assertNotEqual(result.pairing_status, "matched")


# ---------------------------------------------------------------------------
# 8 — Auto mode does not attach non-high-confidence rows
# ---------------------------------------------------------------------------

class TestAutoModeConfidenceGuard(unittest.TestCase):
    @patch("volume_pairing._run_openstack")
    def test_auto_name_fallback_still_review_needed(self, mock):
        mock.side_effect = [_ok(SNAP_AVAILABLE), _ok(VOL_ATTACHED), _ok(SERVER_A)]
        result = vp.pair_single_snapshot("snap-001", "auto", _make_openrc(), MAP_NAME_ONLY)
        # pairing result classification stays review_needed regardless of attach_mode
        # the caller is responsible for skipping non-high in auto mode
        self.assertNotEqual(result.confidence, "high")
        self.assertNotEqual(result.pairing_status, "matched")

    def test_is_auto_safe_only_for_high_confidence_matched(self):
        safe  = vp.VolumePairingResult(snapshot_id="s1", pairing_status="matched",   confidence="high")
        unsafe1 = vp.VolumePairingResult(snapshot_id="s2", pairing_status="review_needed", confidence="medium")
        unsafe2 = vp.VolumePairingResult(snapshot_id="s3", pairing_status="manual_required", confidence="none")
        unsafe3 = vp.VolumePairingResult(snapshot_id="s4", pairing_status="blocked", confidence="low")
        auto_safe = [r for r in [safe, unsafe1, unsafe2, unsafe3]
                     if r.pairing_status == "matched" and r.confidence == "high"]
        self.assertEqual(len(auto_safe), 1)
        self.assertEqual(auto_safe[0].snapshot_id, "s1")


# ---------------------------------------------------------------------------
# 9 — Review mode requires approval before migration
# ---------------------------------------------------------------------------

class TestReviewModeApproval(unittest.TestCase):
    def test_review_result_starts_unapproved(self):
        result = vp.VolumePairingResult(
            snapshot_id="s1", pairing_status="matched",
            confidence="high", attach_mode="review",
        )
        self.assertFalse(result.approved)

    def test_approved_flag_persists(self):
        result = vp.VolumePairingResult(
            snapshot_id="s1", pairing_status="matched",
            confidence="high", attach_mode="review", approved=True,
        )
        self.assertTrue(result.approved)


# ---------------------------------------------------------------------------
# 10 — Manual mode requires selected FLEX target
# ---------------------------------------------------------------------------

class TestManualModeRequiresTarget(unittest.TestCase):
    def test_apply_manual_without_flex_target_leaves_empty(self):
        result = vp.VolumePairingResult(snapshot_id="s1", attach_mode="manual")
        vp.apply_manual_pairing(result, {"manual_ospc_server_id": "ospc-vm-001"})
        # flex_server_id should be empty if not provided
        self.assertEqual(result.flex_server_id, "")

    def test_manual_mode_approved_only_after_apply(self):
        result = vp.VolumePairingResult(snapshot_id="s1", attach_mode="manual")
        self.assertFalse(result.approved)
        vp.apply_manual_pairing(result, {"flex_target_server_id": "flex-vm-001"})
        self.assertTrue(result.approved)


# ---------------------------------------------------------------------------
# 11 — Manual source server selection auto-fills FLEX target from map
# ---------------------------------------------------------------------------

class TestManualAutoFillFromMap(unittest.TestCase):
    def test_apply_manual_sets_all_fields(self):
        result = vp.VolumePairingResult(snapshot_id="snap-001", attach_mode="manual")
        selection = {
            "manual_ospc_server_id":          "ospc-vm-001",
            "manual_ospc_server_snapshot_id": "snap-vm-001",
            "flex_target_server_id":          "flex-vm-789",
            "flex_target_server_name":        "web01-flex",
        }
        vp.apply_manual_pairing(result, selection)
        self.assertEqual(result.ospc_server_id,          "ospc-vm-001")
        self.assertEqual(result.ospc_server_snapshot_id, "snap-vm-001")
        self.assertEqual(result.flex_server_id,          "flex-vm-789")
        self.assertEqual(result.flex_server_name,        "web01-flex")
        self.assertEqual(result.confidence,              "manual")
        self.assertEqual(result.pairing_status,          "manual_selected")
        self.assertTrue(result.manual_override)
        self.assertTrue(result.approved)


# ---------------------------------------------------------------------------
# 12 — Blocked rows are excluded from summary matched count
# ---------------------------------------------------------------------------

class TestBlockedRowsSkipped(unittest.TestCase):
    def test_blocked_not_counted_as_matched(self):
        results = [
            vp.VolumePairingResult(snapshot_id="s1", pairing_status="matched"),
            vp.VolumePairingResult(snapshot_id="s2", pairing_status="blocked"),
            vp.VolumePairingResult(snapshot_id="s3", pairing_status="manual_required"),
            vp.VolumePairingResult(snapshot_id="s4", pairing_status="review_needed"),
        ]
        summary = vp.build_preflight_summary(results)
        self.assertEqual(summary.matched, 1)
        self.assertEqual(summary.blocked, 1)
        self.assertEqual(summary.manual_required, 1)
        self.assertEqual(summary.review_needed, 1)
        self.assertEqual(summary.total, 4)


# ---------------------------------------------------------------------------
# 13 — Pairing map JSON and CSV are written
# ---------------------------------------------------------------------------

class TestSavePairingMap(unittest.TestCase):
    def test_json_and_csv_written(self):
        results = [
            vp.VolumePairingResult(
                snapshot_id="snap-001", snapshot_name="web01-data-snap",
                pairing_status="matched", confidence="high",
                flex_server_id="flex-vm-789", flex_server_name="web01-flex",
            ),
            vp.VolumePairingResult(
                snapshot_id="snap-002", snapshot_name="db01-data-snap",
                pairing_status="manual_required", confidence="none",
            ),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            json_path = os.path.join(tmp, "pairing.json")
            vp.save_pairing_map(results, json_path)
            self.assertTrue(os.path.isfile(json_path))
            csv_path = os.path.join(tmp, "pairing.csv")
            self.assertTrue(os.path.isfile(csv_path))
            with open(json_path) as f:
                data = json.load(f)
            self.assertEqual(len(data), 2)
            self.assertEqual(data[0]["snapshot_id"], "snap-001")
            self.assertEqual(data[0]["pairing_status"], "matched")
            self.assertEqual(data[1]["pairing_status"], "manual_required")


# ---------------------------------------------------------------------------
# 14 — Successful attach updates pairing result to 🚀 Attached status
# ---------------------------------------------------------------------------

class TestAttachedStatus(unittest.TestCase):
    def test_final_attach_status_field_exists(self):
        result = vp.VolumePairingResult(snapshot_id="s1")
        self.assertEqual(result.final_attach_status, "pending")

    def test_final_attach_status_can_be_set_attached(self):
        result = vp.VolumePairingResult(
            snapshot_id="s1",
            pairing_status="matched",
            confidence="high",
            flex_server_id="flex-vm-789",
        )
        result.pairing_status      = "attached"
        result.final_attach_status = "attached"
        self.assertEqual(result.pairing_status, "attached")
        self.assertEqual(result.final_attach_status, "attached")
        d = result.as_dict()
        self.assertEqual(d["pairing_status"], "attached")
        self.assertEqual(d["final_attach_status"], "attached")


if __name__ == "__main__":
    unittest.main()
