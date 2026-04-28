from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List

from services.ui.lib.uat_runner import read_command_runs


def autorun_summary(outputs_dir: Path) -> Dict[str, Any]:
    runs = read_command_runs(outputs_dir)
    counts: Dict[str, int] = {}
    for run in runs:
        status = str(run.get("status") or "Unknown")
        counts[status] = counts.get(status, 0) + 1
    failed = [run for run in runs if run.get("status") in {"Failed", "Timeout", "Blocked"}]
    return {
        "total_runs": len(runs),
        "counts": counts,
        "failed_runs": failed,
        "recent_runs": runs[-20:],
    }


def selected_batch_payload(checklist: List[Dict[str, Any]], selected_ids: List[str]) -> List[Dict[str, Any]]:
    selected = set(selected_ids)
    return [row for row in checklist if str(row.get("id")) in selected]


def safe_result_for_issue(run: Dict[str, Any]) -> Dict[str, str]:
    return {
        "linked_system": str(run.get("linked_system", "")),
        "linked_test": str(run.get("linked_test", "")),
        "severity": "High" if run.get("status") in {"Failed", "Timeout"} else "Medium",
        "status": "Open",
        "description": f"UAT command {run.get('status')}: {run.get('command', '')}",
        "evidence": "\n".join([
            f"stdout: {run.get('stdout', '')}",
            f"stderr: {run.get('stderr', '')}",
            f"error: {run.get('error', '')}",
        ]).strip(),
    }
