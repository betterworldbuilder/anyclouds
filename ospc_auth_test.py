#!/usr/bin/env python3
import json, subprocess, sys, os

env = os.environ.copy()
env.update({
    "OSPC_USERNAME":  "dzng.8294",
    "OSPC_APIKEY":    "0b6f44aad11f4c6fbaeaa159151dd316",
    "OSPC_TENANT_ID": "1342314",
    "OSPC_REGION":    "IAD",
})

r = subprocess.run(
    ["python3", "ospcscan.py"],
    env=env, capture_output=True, text=True, timeout=90,
    cwd="/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-3.0"
)

if r.stderr: print("STDERR:", r.stderr[:400])
if not r.stdout.strip(): print("No output!"); sys.exit(1)

d = json.loads(r.stdout)
if "error" in d: print("ERROR:", d["error"]); sys.exit(1)

print(f"\n✅  Servers: {d['count']}   DBs: {d['db_count']}   Region: {d['region']}\n")
for s in d["servers"]:
    print(f"  {s['name']:<35} {s['external_ip']:<20} {s['os_label']}")
print()
for db in d["databases"]:
    print(f"  [DB] {db['name']:<35} {db['os_label']}")
