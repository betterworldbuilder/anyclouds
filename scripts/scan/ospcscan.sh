#!/usr/bin/env bash
# ospcscan.sh - Live scan of OSPC servers via Rackspace Identity v2.0 + Nova API
# Credentials via env vars: OSPC_USERNAME, OSPC_APIKEY, OSPC_TENANT_ID, OSPC_REGION
# Output: JSON {"servers": [...], "databases": [...], "count": N}

OSPC_USERNAME="${OSPC_USERNAME:-}"
OSPC_APIKEY="${OSPC_APIKEY:-}"
OSPC_TENANT_ID="${OSPC_TENANT_ID:-}"
OSPC_REGION="${OSPC_REGION:-IAD}"

if [[ -z "$OSPC_USERNAME" || -z "$OSPC_APIKEY" || -z "$OSPC_TENANT_ID" ]]; then
    echo '{"error": "Missing credentials: OSPC_USERNAME, OSPC_APIKEY, OSPC_TENANT_ID required"}' >&2
    exit 1
fi

TMPDIR_SCAN=$(mktemp -d)
trap "rm -rf $TMPDIR_SCAN" EXIT

# ── Step 1: Authenticate ──────────────────────────────────────────────────────
AUTH_BODY="{\"auth\":{\"RAX-KSKEY:apiKeyCredentials\":{\"username\":\"${OSPC_USERNAME}\",\"apiKey\":\"${OSPC_APIKEY}\"}}}"

curl -s -k -X POST "https://identity.api.rackspacecloud.com/v2.0/tokens" \
    -H "Content-Type: application/json" \
    -d "$AUTH_BODY" > "$TMPDIR_SCAN/auth.json"

# ── Step 2: Extract token + Nova URL ─────────────────────────────────────────
python3 << PYEOF
import json, sys

with open("$TMPDIR_SCAN/auth.json") as f:
    d = json.load(f)

token = d['access']['token']['id']
region = "${OSPC_REGION}"

nova_url = None
trove_url = None
for svc in d['access']['serviceCatalog']:
    if svc['type'] == 'compute':
        for ep in svc['endpoints']:
            if ep['region'] == region:
                nova_url = ep['publicURL']
    if svc['type'] == 'rax:database':
        for ep in svc['endpoints']:
            if ep['region'] == region:
                trove_url = ep['publicURL']

with open("$TMPDIR_SCAN/meta.json", "w") as f:
    json.dump({"token": token, "nova_url": nova_url, "trove_url": trove_url}, f)

if not nova_url:
    print(json.dumps({"error": f"No Nova endpoint found for region {region}"}))
    sys.exit(1)
PYEOF

# ── Step 3: Fetch servers ─────────────────────────────────────────────────────
TOKEN=$(python3 -c "import json; print(json.load(open('$TMPDIR_SCAN/meta.json'))['token'])")
NOVA_URL=$(python3 -c "import json; print(json.load(open('$TMPDIR_SCAN/meta.json'))['nova_url'])")
TROVE_URL=$(python3 -c "import json; d=json.load(open('$TMPDIR_SCAN/meta.json')); print(d.get('trove_url') or '')")

curl -s -k "${NOVA_URL}/servers/detail" \
    -H "X-Auth-Token: ${TOKEN}" \
    -H "X-Auth-Project-Id: ${OSPC_TENANT_ID}" \
    -H "Accept: application/json" > "$TMPDIR_SCAN/servers.json"

# Fetch databases if Trove endpoint exists
if [[ -n "$TROVE_URL" ]]; then
    curl -s -k "${TROVE_URL}/instances" \
        -H "X-Auth-Token: ${TOKEN}" \
        -H "Accept: application/json" > "$TMPDIR_SCAN/databases.json"
else
    echo '{"instances":[]}' > "$TMPDIR_SCAN/databases.json"
fi

# ── Step 4: Parse and output JSON ─────────────────────────────────────────────
python3 << PYEOF
import json, sys

with open("$TMPDIR_SCAN/servers.json") as f:
    raw = json.load(f)
servers_raw = raw.get('servers', [])

with open("$TMPDIR_SCAN/databases.json") as f:
    db_raw = json.load(f)
dbs_raw = db_raw.get('instances', [])

servers = []
for s in servers_raw:
    name   = s.get('name', '?')
    status = s.get('status', 'UNKNOWN')
    flavor = s.get('flavor', {}).get('id', '')
    addrs  = s.get('addresses', {})

    pub_ip = priv_ip = None
    for net, alist in addrs.items():
        for a in alist:
            ip = a.get('addr', '')
            if ':' in ip:
                continue
            if ip.startswith(('10.', '192.168.', '172.')):
                priv_ip = ip
            elif ip:
                pub_ip = ip

    servers.append({
        'name':        name,
        'id':          s.get('id', ''),
        'status':      status,
        'external_ip': pub_ip or 'N/A',
        'internal_ip': priv_ip or 'N/A',
        'flavor':      flavor,
        'service_type': 'cloud_server',
        'region':      '${OSPC_REGION}',
        'image_name':  s.get('image', {}).get('id', ''),
    })

databases = []
for db in dbs_raw:
    databases.append({
        'name':             db.get('name', '?'),
        'id':               db.get('id', ''),
        'status':           db.get('status', 'UNKNOWN'),
        'flavor':           db.get('flavor', {}).get('id', ''),
        'datastore_type':   db.get('datastore', {}).get('type', ''),
        'datastore_version':db.get('datastore', {}).get('version', ''),
        'service_type':     'database_instance',
        'region':           '${OSPC_REGION}',
    })

result = {
    'servers':   servers,
    'databases': databases,
    'count':     len(servers),
    'db_count':  len(databases),
}
print(json.dumps(result))
PYEOF
