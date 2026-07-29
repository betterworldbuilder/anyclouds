"""Persistence for AI Adoption projects.

JSON documents under outputs/ai_adoption/, written with the same atomic
tmp-then-os.replace pattern the rest of app.py uses. No database is introduced:
this application has never had one, and adding a dependency on a schema engine
would cost more than the feature is worth.
"""

from __future__ import annotations

import json
import os
import threading
from pathlib import Path
from typing import Any, Dict, List, Optional

from .models import now_ms

# One lock per process. Writes are small and infrequent (one per user action),
# so a single lock is simpler than per-file locking and rules out interleaved
# read-modify-write from concurrent requests.
_LOCK = threading.RLock()

MAX_AUDIT_ENTRIES = 500


class ProjectStore:
    def __init__(self, base_dir: Path):
        self.root = Path(base_dir) / "outputs" / "ai_adoption"
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, project_id: str) -> Path:
        # project_id comes from the URL. Anchor it to a bare filename so a
        # crafted id such as "../../etc/passwd" cannot escape the directory.
        safe = os.path.basename(str(project_id or "")).strip()
        if not safe or safe in (".", ".."):
            raise ValueError("invalid project id")
        return self.root / f"{safe}.json"

    def save(self, project: Dict[str, Any]) -> Dict[str, Any]:
        with _LOCK:
            project["updated_at"] = now_ms()
            path = self._path(project["id"])
            tmp = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
            tmp.write_text(json.dumps(project, indent=2, sort_keys=False) + "\n", encoding="utf-8")
            os.replace(tmp, path)
        return project

    def load(self, project_id: str) -> Optional[Dict[str, Any]]:
        # A malformed or hostile id is "no such project", not a server error.
        # save() still raises, because writing to an unresolvable path is a bug.
        try:
            path = self._path(project_id)
        except ValueError:
            return None
        if not path.is_file():
            return None
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return None
        return data if isinstance(data, dict) else None

    def list(self, customer_id: str = "") -> List[Dict[str, Any]]:
        """Summaries only — the full documents can carry large scan payloads."""
        out: List[Dict[str, Any]] = []
        for path in sorted(self.root.glob("*.json")):
            try:
                doc = json.loads(path.read_text(encoding="utf-8"))
            except Exception:
                continue
            if not isinstance(doc, dict):
                continue
            if customer_id and doc.get("customer_id") != customer_id:
                continue
            out.append(
                {
                    "id": doc.get("id"),
                    "name": doc.get("name"),
                    "adoption_mode": doc.get("adoption_mode"),
                    "source_type": doc.get("source_type"),
                    "status": doc.get("status"),
                    "readiness_score": doc.get("readiness_score"),
                    "production_gap_count": doc.get("production_gap_count"),
                    "estimated_value": doc.get("estimated_value"),
                    "customer_id": doc.get("customer_id", ""),
                    "updated_at": doc.get("updated_at"),
                    "time_to_plan_ms": doc.get("time_to_plan_ms"),
                }
            )
        out.sort(key=lambda r: r.get("updated_at") or 0, reverse=True)
        return out

    def delete(self, project_id: str) -> bool:
        with _LOCK:
            try:
                path = self._path(project_id)
            except ValueError:
                return False
            if not path.is_file():
                return False
            path.unlink()
        return True

    def audit(self, project: Dict[str, Any], action: str, actor: str, **detail: Any) -> None:
        """Append an audit event. Every import and every export records one.

        Callers must pass already-redacted detail: this method does not inspect
        values, so a token handed to it would be persisted.
        """
        events = project.setdefault("audit", [])
        events.append({"ts": now_ms(), "action": action, "actor": actor or "unknown", "detail": detail})
        if len(events) > MAX_AUDIT_ENTRIES:
            del events[: len(events) - MAX_AUDIT_ENTRIES]
