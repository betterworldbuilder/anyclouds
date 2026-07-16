"""Shared TTL cache with single-flight execution.

Several browsers watching the same cluster share one cached result per
command, so concurrent viewers never multiply the polling load.
"""
from __future__ import annotations

import threading
import time
from typing import Any, Callable, Dict, Tuple


class TTLCache:
    def __init__(self):
        self._data: Dict[Tuple, Tuple[float, Any]] = {}
        self._locks: Dict[Tuple, threading.Lock] = {}
        self._guard = threading.Lock()

    def _lock_for(self, key: Tuple) -> threading.Lock:
        with self._guard:
            lock = self._locks.get(key)
            if lock is None:
                lock = threading.Lock()
                self._locks[key] = lock
            return lock

    def get(self, key: Tuple, ttl: float, producer: Callable[[], Any]) -> Any:
        now = time.monotonic()
        entry = self._data.get(key)
        if entry and now - entry[0] < ttl:
            return entry[1]
        lock = self._lock_for(key)
        with lock:
            # Re-check after acquiring: another thread may have refreshed it.
            entry = self._data.get(key)
            now = time.monotonic()
            if entry and now - entry[0] < ttl:
                return entry[1]
            value = producer()
            self._data[key] = (time.monotonic(), value)
            return value

    def peek(self, key: Tuple, max_age: float = 300.0) -> Any:
        entry = self._data.get(key)
        if not entry or time.monotonic() - entry[0] > max_age:
            return None
        return entry[1]

    def put(self, key: Tuple, value: Any) -> None:
        self._data[key] = (time.monotonic(), value)

    def invalidate(self, key: Tuple) -> None:
        with self._guard:
            self._data.pop(key, None)


CACHE = TTLCache()


def cached_command(ctx, command_id: str, runner: Callable, json_output: bool = True):
    """Run ``command_id`` for ``ctx`` through the shared cache at its tier TTL."""
    from .command_registry import get_command

    spec = get_command(command_id)
    key = (command_id, ctx.org, ctx.cluster)
    return CACHE.get(key, spec.tier, lambda: runner(ctx, command_id))
