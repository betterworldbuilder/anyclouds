"""
volume_pairing.py — OSPC Volume Snapshot → FLEX VM Target Auto-Pairing

Implements the Auto → Review → Manual matching pipeline for resolving which
FLEX VM a migrated Cinder volume should be attached to.

Matching chain:
  OSPC volume snapshot
    → snapshot.volume_id
    → original OSPC source volume
    → OSPC VM that had the volume attached
    → migration_map.json  (ospc_server_id → flex_server_id)
    → migrated FLEX VM
    → attach migrated FLEX Cinder volume to that FLEX VM
"""
from __future__ import annotations

import csv
import json
import logging
import os
import re
import shlex
import subprocess
import unicodedata
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

log = logging.getLogger(__name__)

# ── Constants ────────────────��─────────────────���──────────────────────────────

ATTACH_MODES    = ("auto", "review", "manual")
PAIRING_STATUSES = (
    "matched", "review_needed", "manual_required", "manual_selected",
    "approved", "attached", "blocked", "failed", "skipped",
)
CONFIDENCE_LEVELS = ("high", "medium", "low", "none", "manual")


# ── Models ─────────────────────���──────────────────────────────────────────────

@dataclass
class VolumePairingResult:
    snapshot_id:               str
    snapshot_name:             str = ""
    snapshot_status:           str = ""
    source_volume_id:          str = ""
    source_volume_name:        str = ""
    source_volume_size_gb:     int = 0
    ospc_server_id:            str = ""
    ospc_server_name:          str = ""
    ospc_server_snapshot_id:   str = ""
    ospc_server_snapshot_name: str = ""
    ospc_device:               str = ""
    flex_server_id:            str = ""
    flex_server_name:          str = ""
    flex_volume_id:            Optional[str] = None
    flex_volume_name:          Optional[str] = None
    pairing_status:            str = "manual_required"
    confidence:                str = "none"
    attach_mode:               str = "review"
    reason:                    str = ""
    warnings:                  List[str] = field(default_factory=list)
    approved:                  bool = False
    manual_override:           bool = False
    final_attach_status:       str = "pending"

    def as_dict(self) -> dict:
        return {
            "snapshot_id":               self.snapshot_id,
            "snapshot_name":             self.snapshot_name,
            "snapshot_status":           self.snapshot_status,
            "source_volume_id":          self.source_volume_id,
            "source_volume_name":        self.source_volume_name,
            "source_volume_size_gb":     self.source_volume_size_gb,
            "ospc_server_id":            self.ospc_server_id,
            "ospc_server_name":          self.ospc_server_name,
            "ospc_server_snapshot_id":   self.ospc_server_snapshot_id,
            "ospc_server_snapshot_name": self.ospc_server_snapshot_name,
            "ospc_device":               self.ospc_device,
            "flex_server_id":            self.flex_server_id,
            "flex_server_name":          self.flex_server_name,
            "flex_volume_id":            self.flex_volume_id,
            "flex_volume_name":          self.flex_volume_name,
            "pairing_status":            self.pairing_status,
            "confidence":                self.confidence,
            "attach_mode":               self.attach_mode,
            "reason":                    self.reason,
            "warnings":                  list(self.warnings),
            "approved":                  self.approved,
            "manual_override":           self.manual_override,
            "final_attach_status":       self.final_attach_status,
        }


@dataclass
class PreflightSummary:
    matched:         int = 0
    review_needed:   int = 0
    manual_required: int = 0
    blocked:         int = 0
    total:           int = 0

    def as_dict(self) -> dict:
        return {
            "matched":         self.matched,
            "review_needed":   self.review_needed,
            "manual_required": self.manual_required,
            "blocked":         self.blocked,
            "total":           self.total,
        }


# ── Low-level helpers ─────────────────────────────────────────────────────────

def _run_openstack(openrc_path: str, args: List[str], timeout: int = 300) -> subprocess.CompletedProcess:
    """Run an openstack CLI command with credentials isolated to openrc_path."""
    env = os.environ.copy()
    for k in list(env):
        if k.startswith("OS_"):
            del env[k]
    env["OS_CLIENT_CONFIG_FILE"] = "/dev/null"
    cmd = ["bash", "-c", f"source {shlex.quote(openrc_path)} && openstack " +
           " ".join(shlex.quote(a) for a in args)]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)


def _normalize_name(name: str) -> str:
    """Lowercase, strip accents, collapse non-alphanumeric runs to a single hyphen."""
    name = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    name = name.lower().strip()
    name = re.sub(r"[^a-z0-9]+", "-", name).strip("-")
    return name


def _parse_json(raw: str) -> Optional[object]:
    raw = raw.strip()
    if not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


# ── Inspection functions ──────────────────���───────────────────────────────────

def inspect_ospc_volume_snapshot(
    snapshot_id: str, ospc_openrc: str
) -> Tuple[Optional[dict], Optional[str]]:
    """
    Return (snapshot_dict, error).  error is None on success.
    """
    r = _run_openstack(ospc_openrc, ["volume", "snapshot", "show", snapshot_id, "-f", "json"], timeout=60)
    if r.returncode != 0:
        return None, f"volume snapshot show failed: {r.stderr.strip()}"
    data = _parse_json(r.stdout)
    if not isinstance(data, dict):
        return None, "empty JSON from volume snapshot show"
    return data, None


def inspect_ospc_volume(
    volume_id: str, ospc_openrc: str
) -> Tuple[Optional[dict], Optional[str]]:
    """
    Return (volume_dict, error).  error is None on success.
    """
    r = _run_openstack(ospc_openrc, ["volume", "show", volume_id, "-f", "json"], timeout=60)
    if r.returncode != 0:
        return None, f"volume show failed: {r.stderr.strip()}"
    data = _parse_json(r.stdout)
    if not isinstance(data, dict):
        return None, "empty JSON from volume show"
    return data, None


def find_ospc_server_for_volume(
    source_volume_id: str,
    ospc_openrc: str,
    volume_data: Optional[dict] = None,
) -> Tuple[List[dict], Optional[str]]:
    """
    Find OSPC server(s) that have source_volume_id attached.

    Returns (servers, error).
    - servers may be [], [one], or [multiple].
    - error is set only for hard API failures.

    Method A: attachments on the volume object (fast).
    Method B: server list scan (fallback).
    """
    # Method A — direct attachment list
    if volume_data:
        attachments = volume_data.get("attachments") or []
        if isinstance(attachments, str):
            try:
                attachments = json.loads(attachments)
            except Exception:
                attachments = []
        server_ids = list({a.get("server_id") for a in attachments if a.get("server_id")})
        if server_ids:
            servers = []
            for sid in server_ids:
                r = _run_openstack(ospc_openrc, ["server", "show", sid, "-f", "json"], timeout=60)
                if r.returncode == 0:
                    d = _parse_json(r.stdout)
                    if isinstance(d, dict):
                        servers.append(d)
            if servers:
                return servers, None
            # IDs found but server show failed — fall through to scan

    # Method B — full server list scan
    r = _run_openstack(ospc_openrc, ["server", "list", "--all-projects", "-f", "json"], timeout=120)
    if r.returncode != 0:
        return [], f"server list failed: {r.stderr.strip()}"
    server_list = _parse_json(r.stdout)
    if not isinstance(server_list, list):
        return [], None

    matched: List[dict] = []
    for entry in server_list:
        sid = str(entry.get("ID") or entry.get("id") or "").strip()
        if not sid:
            continue
        r2 = _run_openstack(ospc_openrc, ["server", "show", sid, "-f", "json"], timeout=60)
        if r2.returncode != 0:
            continue
        sdata = _parse_json(r2.stdout)
        if not isinstance(sdata, dict):
            continue
        vols = sdata.get("volumes_attached") or sdata.get("os-extended-volumes:volumes_attached") or []
        if isinstance(vols, str):
            try:
                vols = json.loads(vols)
            except Exception:
                vols = []
        vol_ids = {str(v.get("id") or v.get("ID") or "") for v in vols if isinstance(v, dict)}
        if source_volume_id in vol_ids:
            matched.append(sdata)

    return matched, None


# ── Migration-map helpers ───────────────────��────────────────────��────────────

def load_migration_map(path: str = "./migration_map.json") -> dict:
    """
    Load the VM migration map.  Returns {"servers": []} if missing or invalid.
    """
    expanded = os.path.expanduser(path)
    if not os.path.isfile(expanded):
        return {"servers": []}
    try:
        with open(expanded) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return {"servers": []}
        data.setdefault("servers", [])
        return data
    except (json.JSONDecodeError, OSError):
        return {"servers": []}


def resolve_flex_target_vm(
    ospc_server_id: str,
    ospc_server_name: str,
    ospc_server_snapshot_id: str,
    migration_map: dict,
    allow_name_fallback: bool = True,
) -> Tuple[str, str, str, str, str]:
    """
    Resolve the FLEX target VM from migration_map.

    Returns (flex_server_id, flex_server_name,
             ospc_snap_id, ospc_snap_name, confidence).
    confidence: "high" | "medium" | "low" | "none"
    """
    servers = migration_map.get("servers") or []

    def _extract(m: dict) -> Tuple[str, str, str, str]:
        return (
            m.get("flex_server_id", ""),
            m.get("flex_server_name", ""),
            m.get("ospc_server_snapshot_id", ""),
            m.get("ospc_server_snapshot_name", ""),
        )

    # Primary: ospc_server_id
    if ospc_server_id:
        hits = [s for s in servers if s.get("ospc_server_id") == ospc_server_id and s.get("flex_server_id")]
        if len(hits) == 1:
            return (*_extract(hits[0]), "high")
        if len(hits) > 1:
            return ("", "", "", "", "low")

    # Secondary: ospc_server_snapshot_id
    if ospc_server_snapshot_id:
        hits = [s for s in servers if s.get("ospc_server_snapshot_id") == ospc_server_snapshot_id and s.get("flex_server_id")]
        if len(hits) == 1:
            return (*_extract(hits[0]), "high")
        if len(hits) > 1:
            return ("", "", "", "", "low")

    # Fallback: normalized name
    if allow_name_fallback and ospc_server_name:
        norm = _normalize_name(ospc_server_name)
        hits = [s for s in servers if _normalize_name(s.get("ospc_server_name", "")) == norm and s.get("flex_server_id")]
        if len(hits) == 1:
            return (*_extract(hits[0]), "medium")
        if len(hits) > 1:
            return ("", "", "", "", "low")

    return ("", "", "", "", "none")


def list_manual_target_options(
    migration_map: dict,
    flex_openrc: Optional[str] = None,
) -> dict:
    """
    Build dropdown option lists for the manual pairing UI.
    """
    servers = migration_map.get("servers") or []
    source_opts: List[dict] = []
    flex_opts: List[dict] = []
    seen_flex: set = set()

    for s in servers:
        source_opts.append({
            "ospc_server_id":            s.get("ospc_server_id", ""),
            "ospc_server_name":          s.get("ospc_server_name", ""),
            "ospc_server_snapshot_id":   s.get("ospc_server_snapshot_id", ""),
            "ospc_server_snapshot_name": s.get("ospc_server_snapshot_name", ""),
            "mapped_flex_server_id":     s.get("flex_server_id", ""),
            "mapped_flex_server_name":   s.get("flex_server_name", ""),
        })
        fid = s.get("flex_server_id", "")
        if fid and fid not in seen_flex:
            seen_flex.add(fid)
            flex_opts.append({
                "flex_server_id":   fid,
                "flex_server_name": s.get("flex_server_name", ""),
                "ospc_server_id":   s.get("ospc_server_id", ""),
                "ospc_server_name": s.get("ospc_server_name", ""),
            })

    return {"source_server_options": source_opts, "flex_server_options": flex_opts}


def apply_manual_pairing(
    pairing_result: VolumePairingResult,
    manual_selection: dict,
) -> VolumePairingResult:
    """
    Apply user's manual selections to a pairing result.
    Sets confidence=manual, pairing_status=manual_selected, approved=True.
    """
    pairing_result.ospc_server_id          = manual_selection.get("manual_ospc_server_id", "") or pairing_result.ospc_server_id
    pairing_result.ospc_server_snapshot_id = manual_selection.get("manual_ospc_server_snapshot_id", "") or pairing_result.ospc_server_snapshot_id
    pairing_result.flex_server_id          = manual_selection.get("flex_target_server_id", "")
    pairing_result.flex_server_name        = manual_selection.get("flex_target_server_name", "") or pairing_result.flex_server_name
    pairing_result.confidence              = "manual"
    pairing_result.pairing_status          = "manual_selected"
    pairing_result.manual_override         = True
    pairing_result.approved                = True
    return pairing_result


# ── Preflight summary ───────────��─────────────────────────────────────────────

def build_preflight_summary(pairing_results: List[VolumePairingResult]) -> PreflightSummary:
    s = PreflightSummary(total=len(pairing_results))
    for r in pairing_results:
        if r.pairing_status == "matched":
            s.matched += 1
        elif r.pairing_status == "review_needed":
            s.review_needed += 1
        elif r.pairing_status in ("manual_required", "manual_selected"):
            s.manual_required += 1
        elif r.pairing_status == "blocked":
            s.blocked += 1
    return s


# ── Core single-snapshot pairing ────────���────────────────────────────────────

def pair_single_snapshot(
    snapshot_id: str,
    attach_mode: str,
    ospc_openrc: str,
    migration_map: dict,
    allow_name_fallback: bool = True,
) -> VolumePairingResult:
    """
    Run the full Auto→Review→Manual pairing chain for one volume snapshot.
    Does NOT execute any migration — classification only.
    """
    result = VolumePairingResult(snapshot_id=snapshot_id, attach_mode=attach_mode)

    # Step 1 — inspect snapshot
    snap_data, err = inspect_ospc_volume_snapshot(snapshot_id, ospc_openrc)
    if err or not snap_data:
        result.pairing_status = "blocked"
        result.confidence     = "none"
        result.reason         = err or "failed to inspect snapshot"
        return result

    result.snapshot_name   = str(snap_data.get("name")      or snap_data.get("Name")      or "")
    result.snapshot_status = str(snap_data.get("status")    or snap_data.get("Status")    or "").lower()
    source_volume_id       = str(snap_data.get("volume_id") or snap_data.get("Volume ID") or "").strip()

    if result.snapshot_status != "available":
        result.pairing_status = "blocked"
        result.reason         = f"snapshot_not_available (status={result.snapshot_status})"
        return result

    if not source_volume_id:
        result.pairing_status = "manual_required"
        result.reason         = "snapshot_missing_source_volume_id"
        return result

    result.source_volume_id = source_volume_id

    # Step 2 — inspect source volume
    vol_data, _ = inspect_ospc_volume(source_volume_id, ospc_openrc)
    if vol_data:
        result.source_volume_name    = str(vol_data.get("name") or vol_data.get("Name") or "")
        result.source_volume_size_gb = int(vol_data.get("size") or vol_data.get("Size") or 0)

    # Step 3 — find OSPC server
    servers, err = find_ospc_server_for_volume(source_volume_id, ospc_openrc, vol_data)

    if err:
        result.pairing_status = "manual_required"
        result.reason         = f"server_scan_failed: {err}"
        return result

    if len(servers) == 0:
        result.pairing_status = "manual_required"
        result.reason         = "source_volume_not_attached_to_known_ospc_server"
        return result

    if len(servers) > 1:
        result.pairing_status = "blocked"
        result.reason         = "multiple_ospc_servers_reference_source_volume"
        return result

    server = servers[0]
    result.ospc_server_id   = str(server.get("id")   or server.get("ID")   or "")
    result.ospc_server_name = str(server.get("name") or server.get("Name") or "")

    # Extract device from attachment
    if vol_data:
        attachments = vol_data.get("attachments") or []
        if isinstance(attachments, str):
            try:
                attachments = json.loads(attachments)
            except Exception:
                attachments = []
        for a in attachments:
            if a.get("server_id") == result.ospc_server_id:
                result.ospc_device = str(a.get("device") or "")
                break

    # Steps 4 & 5 — resolve FLEX VM
    flex_id, flex_name, snap_id, snap_name, confidence = resolve_flex_target_vm(
        result.ospc_server_id,
        result.ospc_server_name,
        "",
        migration_map,
        allow_name_fallback=allow_name_fallback,
    )
    result.ospc_server_snapshot_id   = snap_id
    result.ospc_server_snapshot_name = snap_name

    if confidence == "high":
        result.flex_server_id   = flex_id
        result.flex_server_name = flex_name
        result.confidence       = "high"
        result.pairing_status   = "matched"
        result.reason           = (
            "Matched by snapshot.volume_id → OSPC attached volume → "
            "OSPC server ID → FLEX migration map."
        )
    elif confidence == "medium":
        result.flex_server_id   = flex_id
        result.flex_server_name = flex_name
        result.confidence       = "medium"
        result.pairing_status   = "review_needed"
        result.reason           = "Name-only fallback match — requires review before attach."
        result.warnings.append("name_only_fallback: ID match not available; server names were used.")
    elif confidence == "low":
        result.confidence     = "low"
        result.pairing_status = "blocked"
        result.reason         = "Multiple FLEX VMs match the OSPC server — ambiguous."
    else:
        result.confidence     = "none"
        result.pairing_status = "manual_required"
        result.reason         = "OSPC server found but no matching FLEX VM in migration map."

    return result


def pair_selected_volume_snapshots(
    selected_snapshot_ids: List[str],
    attach_mode: str,
    ospc_openrc: str,
    migration_map_path: str = "./migration_map.json",
    allow_name_fallback: bool = True,
) -> List[VolumePairingResult]:
    """
    Run pairing for all selected snapshot IDs.  Pairing only — no migration.
    """
    if attach_mode not in ATTACH_MODES:
        raise ValueError(f"attach_mode must be one of {ATTACH_MODES}, got {attach_mode!r}")
    migration_map = load_migration_map(migration_map_path)
    return [
        pair_single_snapshot(sid, attach_mode, ospc_openrc, migration_map, allow_name_fallback)
        for sid in selected_snapshot_ids
    ]


# ─��� Persistence ───────────────────────────────────────────────────────────────

def save_pairing_map(
    pairing_results: List[VolumePairingResult],
    path: str = "./migration_volume_pairing_map.json",
) -> None:
    """Persist pairing results to JSON and CSV (same stem, .csv extension)."""
    records = [r.as_dict() for r in pairing_results]
    with open(path, "w") as f:
        json.dump(records, f, indent=2)
    csv_path = os.path.splitext(path)[0] + ".csv"
    if records:
        with open(csv_path, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(records[0].keys()))
            writer.writeheader()
            writer.writerows(records)
