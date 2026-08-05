#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent

# This helper intentionally relies on environment variables or an OpenRC file.
# Do not embed API keys/tokens in source control.
env = os.environ.copy()

r = subprocess.run(
    ["python3", "ospcscan.py"],
    env=env,
    capture_output=True,
    text=True,
    timeout=90,
    cwd=str(BASE_DIR),
)

if r.stderr:
    print("STDERR:", r.stderr[:400])
if not r.stdout.strip():
    print("No output!")
    sys.exit(1)

d = json.loads(r.stdout)
if "error" in d:
    print("ERROR:", d["error"])
    sys.exit(1)

print(f"\n✅  Servers: {d.get('count')}   DBs: {d.get('db_count')}   Region: {d.get('region')}\n")
for s in d.get("servers", []):
    print(f"  {s.get('name',''):<35} {s.get('external_ip',''):<20} {s.get('os_label','')}")
print()
for db in d.get("databases", []):
    print(f"  [DB] {db.get('name',''):<35} {db.get('os_label','')}")
