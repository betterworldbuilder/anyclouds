#!/usr/bin/env bash
set -euo pipefail

JH_IP="${1:-104.130.165.124}"
JH_USER="${2:-ubuntu}"
KEY="${3:-$HOME/.ssh/id_rsa}"

ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${JH_USER}@${JH_IP}" 'bash -s' <<'EOF'
set -euo pipefail
source /mnt/migration/ospc2flex_image/creds/ospc_openrc.sh

IMG="aea39a50-dc0b-430f-9c14-1cf2fd1b4290"
CONTAINER="ospc2flex-export"
OBJ="${IMG}.vhd"

BASE="$(openstack catalog show image -f json | python3 -c 'import sys,json;d=json.load(sys.stdin);eps=d.get("endpoints") or [];pick=eps[0] if eps else {};print((pick.get("publicURL") or pick.get("url") or "https://iad.images.api.rackspacecloud.com/v2").rstrip("/"))')"
TASKS_URL="${BASE}/tasks"
echo "BASE=$BASE"
echo "TASKS_URL=$TASKS_URL"

OS_API_KEY="${OS_API_KEY:-${OS_PASSWORD:-}}"
AUTH_PAYLOAD="$(printf '{"auth":{"RAX-KSKEY:apiKeyCredentials":{"username":"%s","apiKey":"%s"}}}' "$OS_USERNAME" "$OS_API_KEY")"
TOK="$(
  curl -sS -X POST "https://identity.api.rackspacecloud.com/v2.0/tokens" \
    -H "Content-Type: application/json" \
    -d "$AUTH_PAYLOAD" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access"]["token"]["id"])'
)"

REQ="$(printf '{"type":"export","input":{"image_uuid":"%s","receiving_swift_container":"%s","image_name":"%s"}}' "$IMG" "$CONTAINER" "$OBJ")"
echo "REQ=$REQ"

set +e
curl -sS -X POST "$TASKS_URL" \
  -H "X-Auth-Token: $TOK" \
  -H "Content-Type: application/json" \
  -d "$REQ" -D /tmp/task_api_hdr.txt -o /tmp/task_api_body.json
RC=$?
set -e
echo "curl_rc=$RC"
sed -n '1,20p' /tmp/task_api_hdr.txt || true
sed -n '1,120p' /tmp/task_api_body.json || true
EOF
