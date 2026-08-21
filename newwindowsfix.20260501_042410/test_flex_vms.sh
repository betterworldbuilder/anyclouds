#!/usr/bin/env bash
# Test: Pull FLEX VMs directly via Keystone v3 + Nova API
# Usage: OS_PASSWORD=yourpassword bash test_flex_vms.sh

AUTH_URL="https://keystone.api.dfw3.rackspacecloud.com/v3"
USERNAME="${OS_USERNAME:?Set OS_USERNAME (source your OpenRC)}"
PROJECT_ID="49a2c18a567c402ef560bb0f11821b61"
DOMAIN="rackspace_cloud_domain"
PASSWORD="${OS_PASSWORD:-}"

if [ -z "$PASSWORD" ]; then
    echo "Enter FLEX password:"
    read -sr PASSWORD
    echo
fi

echo "=== Step 1: Keystone v3 Auth ==="
AUTH_RESPONSE=$(curl -s -k -i -X POST "$AUTH_URL/auth/tokens" \
  -H "Content-Type: application/json" \
  -d "{
    \"auth\": {
      \"identity\": {
        \"methods\": [\"password\"],
        \"password\": {
          \"user\": {
            \"name\": \"$USERNAME\",
            \"domain\": {\"name\": \"$DOMAIN\"},
            \"password\": \"$PASSWORD\"
          }
        }
      },
      \"scope\": {
        \"project\": {\"id\": \"$PROJECT_ID\"}
      }
    }
  }" 2>&1)

TOKEN=$(echo "$AUTH_RESPONSE" | grep -i "X-Subject-Token" | awk '{print $2}' | tr -d '\r')

if [ -z "$TOKEN" ]; then
    echo "ERROR: Could not get token. Auth response headers:"
    echo "$AUTH_RESPONSE" | head -20
    exit 1
fi

echo "SUCCESS: Got token: ${TOKEN:0:20}..."

echo ""
echo "=== Step 2: Get Nova compute endpoint from service catalog ==="
# Extract compute endpoints from catalog body
CATALOG_BODY=$(echo "$AUTH_RESPONSE" | grep -o '"catalog":\[.*\]' | head -1)
TENANT_ID=$(echo "$AUTH_RESPONSE" | python3 -c "
import sys, json, re
body = sys.stdin.read()
# Find JSON body after headers
idx = body.find('{\"token\"')
if idx < 0: idx = body.find('{\"access\"')
if idx >= 0:
    try:
        data = json.loads(body[idx:])
        token = data.get('token', {})
        print('TENANT:', token.get('project', {}).get('id', 'N/A'))
        for svc in token.get('catalog', []):
            if svc.get('type') in ('compute', 'nova'):
                for ep in svc.get('endpoints', []):
                    print('COMPUTE_EP:', ep.get('region_id','?'), ep.get('interface','?'), ep.get('url','?'))
    except Exception as e:
        print('PARSE ERROR:', e)
" 2>&1)

echo "$CATALOG_BODY"
echo "$TENANT_ID"

echo ""
echo "=== Step 3: Find DFW3 compute endpoint and list servers ==="
NOVA_URL=$(echo "$AUTH_RESPONSE" | python3 -c "
import sys, json
body = sys.stdin.read()
idx = body.find('{\"token\"')
if idx >= 0:
    try:
        data = json.loads(body[idx:])
        for svc in data.get('token', {}).get('catalog', []):
            if svc.get('type') in ('compute', 'nova'):
                # Try DFW3 first
                for ep in svc.get('endpoints', []):
                    if ep.get('interface') == 'public' and 'dfw3' in ep.get('region_id','').lower():
                        print(ep.get('url','').rstrip('/'))
                        exit()
                # fallback: any public
                for ep in svc.get('endpoints', []):
                    if ep.get('interface') == 'public':
                        print(ep.get('url','').rstrip('/'))
                        exit()
    except Exception as e:
        print('ERROR:' + str(e), file=sys.stderr)
" 2>&1)

if [ -z "$NOVA_URL" ]; then
    echo "WARNING: No compute endpoint in catalog, trying direct DFW3 URL"
    NOVA_URL="https://dfw3.servers.api.rackspacecloud.com/v2/$PROJECT_ID"
fi

echo "Using Nova URL: $NOVA_URL"
echo ""
echo "=== Step 4: List servers ==="
curl -s -k "$NOVA_URL/servers/detail" \
  -H "X-Auth-Token: $TOKEN" | python3 -c "
import sys, json
data = json.load(sys.stdin)
servers = data.get('servers', [])
print(f'Found {len(servers)} servers:')
for s in servers:
    name = s.get('name','?')
    addresses = s.get('addresses', {})
    ext_ip = 'N/A'
    for net, addrs in addresses.items():
        for a in addrs:
            if a.get('OS-EXT-IPS:type') == 'floating':
                ext_ip = a['addr']; break
        if ext_ip != 'N/A': break
    if ext_ip == 'N/A':
        for net, addrs in addresses.items():
            for a in addrs:
                ip = a.get('addr','')
                if ip and ':' not in ip and not ip.startswith(('10.','192.168.','172.')):
                    ext_ip = ip; break
    print(f'  {name:45s} ExternalIP: {ext_ip}')
" 2>&1
