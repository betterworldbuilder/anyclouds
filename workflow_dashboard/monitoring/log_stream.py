"""Latest bootstrap log discovery and tail streaming."""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Iterator, Optional

from .models import MonitoringContext
from .redaction import redact_line

MAX_INITIAL_LINES = 200
POLL_INTERVAL = 0.5
SNAPSHOT_INTERVAL = 2.0


def latest_bootstrap_log(ctx: MonitoringContext) -> Optional[Path]:
    """Newest bootstrap-*.log for the cluster, or None when nothing exists."""
    try:
        logs = sorted(
            ctx.bootstrap_log_dir.glob("bootstrap-*.log"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
    except OSError:
        return None
    return logs[0] if logs else None


def read_log_tail(path: Path, max_bytes: int = 512 * 1024) -> str:
    """Read at most the last ``max_bytes`` of a log file."""
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            if size > max_bytes:
                handle.seek(size - max_bytes)
            return handle.read().decode("utf-8", errors="replace")
    except OSError:
        return ""


def sse_event(event: str, payload) -> str:
    return "event: %s\ndata: %s\n\n" % (event, json.dumps(payload, default=str))


def stream_deployment(ctx: MonitoringContext, snapshot_producer) -> Iterator[str]:
    """SSE generator: tails the newest bootstrap log and emits snapshots.

    - switches automatically when a newer bootstrap log appears
    - emits `log` events per appended line (redacted, ANSI-stripped)
    - emits `snapshot` events every SNAPSHOT_INTERVAL seconds
    - emits `status` events on log switches and idle states
    """
    current: Optional[Path] = None
    handle = None
    last_snapshot = 0.0
    try:
        while True:
            newest = latest_bootstrap_log(ctx)
            if newest != current:
                if handle:
                    handle.close()
                    handle = None
                current = newest
                if current:
                    yield sse_event("status", {"log": current.name})
                    handle = current.open("r", encoding="utf-8", errors="replace")
                    # start from the tail: replay only the last N lines
                    tail_lines = read_log_tail(current).splitlines()[-MAX_INITIAL_LINES:]
                    for line in tail_lines:
                        yield sse_event("log", {"line": redact_line(line)})
                    handle.seek(0, 2)
                else:
                    yield sse_event("status", {"log": "", "message": "no bootstrap log yet"})

            emitted = False
            if handle:
                while True:
                    line = handle.readline()
                    if not line:
                        break
                    emitted = True
                    yield sse_event("log", {"line": redact_line(line.rstrip("\n"))})

            now = time.monotonic()
            if now - last_snapshot >= SNAPSHOT_INTERVAL:
                last_snapshot = now
                try:
                    yield sse_event("snapshot", snapshot_producer())
                except Exception as exc:  # keep the stream alive on parse errors
                    yield sse_event("status", {"error": str(exc)[:200]})

            if not emitted:
                time.sleep(POLL_INTERVAL)
    finally:
        if handle:
            handle.close()


def stream_cluster(snapshot_producer, interval: float = 5.0) -> Iterator[str]:
    """SSE generator emitting cluster snapshots on a fixed interval."""
    while True:
        try:
            yield sse_event("snapshot", snapshot_producer())
        except Exception as exc:
            yield sse_event("status", {"error": str(exc)[:200]})
        time.sleep(interval)
