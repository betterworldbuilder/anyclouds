#!/usr/bin/env bash
set -euo pipefail
cd /home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current
source ospc-iad-openrc.sh
OS_API_KEY="${OS_API_KEY:-${OS_PASSWORD:-}}"
AUTH_PAYLOAD="$(printf '{"auth":{"RAX-KSKEY:apiKeyCredentials":{"username":"%s","apiKey":"%s"}}}' "$OS_USERNAME" "$OS_API_KEY")"
TOK="$(
  curl -sS -X POST "https://identity.api.rackspacecloud.com/v2.0/tokens" \
    -H "Content-Type: application/json" \
    -d "$AUTH_PAYLOAD" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["access"]["token"]["id"])'
)"
IMG="aea39a50-dc0b-430f-9c14-1cf2fd1b4290"

for BASE in \
  "https://snet-iad.images.api.rackspacecloud.com" \
  "https://iad.images.api.rackspacecloud.com" \
  "https://snet-dfw.images.api.rackspacecloud.com"
do
  URL="${BASE}/v2/images/${IMG}/file"
  echo "=== ${URL} ==="
  set +e
  curl -sS -L --max-time 30 \
    -H "X-Auth-Token: ${TOK}" \
    -H "Range: bytes=0-1023" \
    -o /tmp/glance_probe.bin \
    -D /tmp/glance_probe.hdr \
    "${URL}" >/tmp/glance_probe.out 2>/tmp/glance_probe.err || true
  RC=$?
  set -e
  CODE="$(awk 'toupper($1) ~ /^HTTP/ {c=$2} END {print c+0}' /tmp/glance_probe.hdr 2>/dev/null)"
  SZ="$(stat -c%s /tmp/glance_probe.bin 2>/dev/null || echo 0)"
  echo "curl_rc=${RC} HTTP=${CODE} size=${SZ}"
  sed -n '1,8p' /tmp/glance_probe.hdr
  sed -n '1,4p' /tmp/glance_probe.err
done
