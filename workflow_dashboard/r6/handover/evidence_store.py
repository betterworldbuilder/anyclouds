"""Persist run results to disk for audit/export."""
import json
import pathlib
import datetime

_REPORTS_DIR = pathlib.Path.home() / ".config" / "opencenter" / "handover-reports"


def save_run(run_id, run_data):
    _REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    path = _REPORTS_DIR / f"{run_id}.json"
    with open(path, "w") as f:
        json.dump(run_data, f, indent=2, default=str)
    return str(path)


def load_run(run_id):
    path = _REPORTS_DIR / f"{run_id}.json"
    if not path.is_file():
        return None
    with open(path) as f:
        return json.load(f)


def list_runs():
    _REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    runs = []
    for p in sorted(_REPORTS_DIR.glob("*.json"), reverse=True):
        try:
            with open(p) as f:
                data = json.load(f)
            runs.append({
                "runId": data.get("runId"),
                "startedAt": data.get("startedAt"),
                "verdict": data.get("verdict"),
                "status": data.get("status"),
            })
        except Exception:
            pass
    return runs
