import subprocess, json, os, sys

script = os.path.abspath(os.path.join(os.path.dirname(__file__), 'flexvmscan.sh'))
env = {
    **os.environ,
    'OS_AUTH_URL':         'https://keystone.api.dfw3.rackspacecloud.com/v3',
    'OS_USERNAME':         'dzng.8294',
    'OS_PASSWORD':         '0b6f44aad11f4c6fbaeaa159151dd316',
    'OS_PROJECT_ID':       '49a2c18a567c402ef560bb0f11821b61',
    'OS_USER_DOMAIN_NAME': 'rackspace_cloud_domain',
}

print(f"Running: {script}")
r = subprocess.run(['bash', script], env=env, capture_output=True, text=True, timeout=45)

if r.stderr:
    print(f"STDERR: {r.stderr[:300]}")
if not r.stdout.strip():
    print(f"ERROR: No output (exit {r.returncode})")
    sys.exit(1)

data = json.loads(r.stdout)
print(f"\n✅ Count: {data['count']}  Nova: {data['nova_url']}\n")
print(f"{'Name':<42} {'External IP':<18} {'Internal IP'}")
print("-" * 80)
for s in data['servers']:
    print(f"  {s['name']:<40} {s['external_ip']:<18} {s['internal_ip']}")
