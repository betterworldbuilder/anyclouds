#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def _repo_root() -> Path:
    here = Path(__file__).resolve()
    for parent in (here.parent, *here.parents):
        if (parent / "migration" / "os_repair" / "centos_repair.py").exists():
            return parent
    return here.parents[1]


sys.path.insert(0, str(_repo_root()))

from migration.os_repair.centos_repair import main, repair_centos_for_flex  # noqa: E402


if __name__ == "__main__":
    raise SystemExit(main())
