#!/usr/bin/env bash
set -euo pipefail

JH_IP="${1:-104.130.165.124}"
JH_USER="${2:-ubuntu}"
KEY="${3:-$HOME/.ssh/id_rsa}"

ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${JH_USER}@${JH_IP}" 'bash -s' <<'EOF'
set -euo pipefail

source /mnt/migration/ospc2flex_image/creds/ospc_openrc.sh
OS_API_KEY="${OS_API_KEY:-${OS_PASSWORD:-}}"
AUTH_PAYLOAD="$(printf '{"auth":{"RAX-KSKEY:apiKeyCredentials":{"username":"%s","apiKey":"%s"}}}' "$OS_USERNAME" "$OS_API_KEY")"
TOK="$(
  curl -sS -X POST "https://identity.api.rackspacecloud.com/v2.0/tokens" \
    -H "Content-Type: application/json" \
    -d "$AUTH_PAYLOAD" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access"]["token"]["id"])'
)"

for IMG in \
  "aea39a50-dc0b-430f-9c14-1cf2fd1b4290" \
  "18b288f2-34cb-4aac-8e14-4fdb4af9206e"
do
  echo "==== IMG: $IMG ===="
  for BASE in \
    "https://snet-iad.images.api.rackspacecloud.com" \
    "https://iad.images.api.rackspacecloud.com"
  do
    URL="${BASE}/v2/images/${IMG}/file"
    rm -f /tmp/jh_probe.bin /tmp/jh_probe.hdr /tmp/jh_probe.err
    set +e
    curl -sS -L --max-time 45 \
      -H "X-Auth-Token: ${TOK}" \
      -H "Range: bytes=0-1023" \
      -o /tmp/jh_probe.bin \
      -D /tmp/jh_probe.hdr \
      "$URL" >/tmp/jh_probe.out 2>/tmp/jh_probe.err
    RC=$?
    set -e
    CODE="$(awk 'toupper($1) ~ /^HTTP/ {c=$2} END {print c+0}' /tmp/jh_probe.hdr 2>/dev/null)"
    SZ="$(stat -c%s /tmp/jh_probe.bin 2>/dev/null || echo 0)"
    echo "URL=$URL"
    echo "curl_rc=$RC http=$CODE size=$SZ"
    sed -n '1,6p' /tmp/jh_probe.hdr || true
    sed -n '1,2p' /tmp/jh_probe.err || true
  done
done
EOF
