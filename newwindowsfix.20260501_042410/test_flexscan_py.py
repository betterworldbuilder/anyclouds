import subprocess, json, os, sys

script = os.path.abspath(os.path.join(os.path.dirname(__file__), 'flexvmscan.sh'))

# Credentials come from the environment — source your OpenRC before running:
#   OS_AUTH_URL OS_USERNAME OS_PASSWORD OS_PROJECT_ID OS_USER_DOMAIN_NAME
env = {
    **os.environ,
    'OS_AUTH_URL':         os.environ.get('OS_AUTH_URL', 'https://keystone.api.dfw3.rackspacecloud.com/v3'),
    'OS_USERNAME':         os.environ.get('OS_USERNAME', ''),
    'OS_PASSWORD':         os.environ.get('OS_PASSWORD', ''),
    'OS_PROJECT_ID':       os.environ.get('OS_PROJECT_ID', ''),
    'OS_USER_DOMAIN_NAME': os.environ.get('OS_USER_DOMAIN_NAME', 'rackspace_cloud_domain'),
}

_missing = [k for k in ('OS_USERNAME', 'OS_PASSWORD', 'OS_PROJECT_ID') if not env[k]]
if _missing:
    print(f"ERROR: missing environment variables: {', '.join(_missing)}")
    sys.exit(1)

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
