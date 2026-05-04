#!/usr/bin/env bash
# flexvmscan.sh - Scan FLEX VMs via Keystone v3 + Nova API
# Credentials via env vars: OS_AUTH_URL, OS_USERNAME, OS_PASSWORD, OS_PROJECT_ID, OS_USER_DOMAIN_NAME
# Output: JSON {"servers": [...], "count": N}

AUTH_URL="${OS_AUTH_URL:-https://keystone.api.dfw3.rackspacecloud.com/v3}"
USERNAME="${OS_USERNAME:-}"
PASSWORD="${OS_PASSWORD:-}"
PROJECT_ID="${OS_PROJECT_ID:-}"
DOMAIN="${OS_USER_DOMAIN_NAME:-rackspace_cloud_domain}"

AUTH_URL="${AUTH_URL%/}"
[[ "$AUTH_URL" != */v3 && "$AUTH_URL" != */v2.0 ]] && AUTH_URL="${AUTH_URL}/v3"

if [[ -z "$USERNAME" || -z "$PASSWORD" || -z "$PROJECT_ID" ]]; then
    echo '{"error": "Missing credentials: OS_USERNAME, OS_PASSWORD, OS_PROJECT_ID required"}' >&2
    exit 1
fi

TMPDIR_SCAN=$(mktemp -d)
trap "rm -rf $TMPDIR_SCAN" EXIT

# ── Step 1: Keystone v3 token ─────────────────────────────────────────────────
curl -s -k -i -X POST "${AUTH_URL}/auth/tokens" \
    -H "Content-Type: application/json" \
    -d "{
  \"auth\": {
    \"identity\": {
      \"methods\": [\"password\"],
      \"password\": {
        \"user\": {
          \"name\": \"${USERNAME}\",
          \"domain\": {\"name\": \"${DOMAIN}\"},
          \"password\": \"${PASSWORD}\"
        }
      }
    },
    \"scope\": {\"project\": {\"id\": \"${PROJECT_ID}\"}}
  }
}" > "$TMPDIR_SCAN/auth_response.txt" 2>&1

TOKEN=$(grep -i "^X-Subject-Token:" "$TMPDIR_SCAN/auth_response.txt" | awk '{print $2}' | tr -d '\r\n')

if [[ -z "$TOKEN" ]]; then
    HTTP_STATUS=$(grep -E "^HTTP/" "$TMPDIR_SCAN/auth_response.txt" | tail -1 | awk '{print $2}')
    echo "{\"error\": \"Keystone auth failed (HTTP ${HTTP_STATUS:-unknown}). Check credentials.\"}" >&2
    exit 1
fi

# ── Step 2: Extract Nova public endpoint from catalog ─────────────────────────
# The body starts after the blank line following HTTP headers
awk 'found{print} /^\r?$/{found=1}' "$TMPDIR_SCAN/auth_response.txt" > "$TMPDIR_SCAN/catalog.json"

NOVA_URL=$(python3 << PYEOF
import json, sys
try:
    with open("$TMPDIR_SCAN/catalog.json") as f:
        data = json.load(f)
    for svc in data.get('token', {}).get('catalog', []):
        if svc.get('type') in ('compute', 'nova'):
            for ep in svc.get('endpoints', []):
                if ep.get('interface') == 'public':
                    print(ep.get('url','').rstrip('/'))
                    sys.exit(0)
except Exception as e:
    sys.stderr.write(str(e) + "\n")
PYEOF
)

if [[ -z "$NOVA_URL" ]]; then
    echo '{"error": "No public Nova endpoint found in service catalog"}' >&2
    exit 1
fi

# ── Step 3: Fetch servers and parse ──────────────────────────────────────────
curl -s -k "${NOVA_URL}/servers/detail" \
    -H "X-Auth-Token: ${TOKEN}" > "$TMPDIR_SCAN/servers.json"

python3 << PYEOF
import json, sys

SKIP_NETS   = {'public', 'publicnet', 'servicenet'}
SKIP_RANGES = ('10.176.', '10.177.', '10.178.', '10.179.', '10.208.', '10.209.')
PRIV_STARTS = ('10.', '192.168.', '172.')

try:
    with open("$TMPDIR_SCAN/servers.json") as f:
        data = json.load(f)
except Exception as e:
    print(json.dumps({"error": "Failed to parse Nova response: " + str(e)}))
    sys.exit(1)

servers = data.get('servers', [])
result  = []

for s in servers:
    addresses = s.get('addresses', {})
    ext_ip    = None
    int_ip    = None

    # Floating IP first
    for net, addrs in addresses.items():
        for a in addrs:
            if a.get('OS-EXT-IPS:type') == 'floating':
                ext_ip = a.get('addr')
                break
        if ext_ip:
            break

    # Internal: prefer tenant nets, skip Rackspace backbone
    for net, addrs in addresses.items():
        if net.lower() in SKIP_NETS:
            continue
        for a in addrs:
            ip = a.get('addr', '')
            if ip and ':' not in ip and ip.startswith(PRIV_STARTS) and not ip.startswith(SKIP_RANGES):
                int_ip = ip
                break
        if int_ip:
            break

    # Fallback: any private non-backbone IP
    if not int_ip:
        for net, addrs in addresses.items():
            for a in addrs:
                ip = a.get('addr', '')
                if ip and ':' not in ip and ip.startswith(PRIV_STARTS) and not ip.startswith(SKIP_RANGES):
                    int_ip = ip
                    break
            if int_ip:
                break

    result.append({
        'name':        s.get('name', '?'),
        'id':          s.get('id', ''),
        'status':      s.get('status', 'UNKNOWN'),
        'external_ip': ext_ip or 'N/A',
        'internal_ip': int_ip or 'N/A',
        'flavor':      s.get('flavor', {}).get('original_name') or s.get('flavor', {}).get('id', ''),
        'addresses':   addresses,
    })

print(json.dumps({'servers': result, 'count': len(result)}))
PYEOF
