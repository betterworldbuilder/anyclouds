"""Load and index the handover checklist JSON."""
import json
import pathlib

_CHECKLIST_PATH = pathlib.Path(__file__).parent.parent.parent.parent / "config" / "r6-opencenter-handover-checklist.json"

_cache = None


def load():
    global _cache
    if _cache is None:
        with open(_CHECKLIST_PATH) as f:
            _cache = json.load(f)
    return _cache


def get_checks():
    return load()["checks"]


def get_sections():
    return sorted(load()["sections"], key=lambda s: s["order"])


def checks_by_section():
    result = {}
    for check in get_checks():
        result.setdefault(check["section"], []).append(check)
    return result


def get_check(check_id):
    for c in get_checks():
        if c["id"] == check_id:
            return c
    return None
