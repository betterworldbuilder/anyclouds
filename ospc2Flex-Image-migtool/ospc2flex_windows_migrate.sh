#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# ospc2flex_windows_migrate.sh — Windows VM Migration via OSPC Glance Snapshot
# ═══════════════════════════════════════════════════════════════════════════════
# Windows VMs cannot use NBD (no SSH/qemu-nbd on Windows).
# This script uses the OSPC API to snapshot → download → repair → upload.
#
# Usage:
#   bash ospc2flex_windows_migrate.sh \
#     --server-name "win2019websql2019" \
#     --server-ip "104.130.26.6" \
#     --label "ospc2flex-win2019" \
#     [--flavor "gp.5.4.4"] [--network "tenant-net"] [--keypair "laptopubuntu24"]
#
# Requires: /tmp/ospc2flex_ospc.sh (OSPC creds) and /tmp/ospc2flex_flex.sh (FLEX creds)
#           /tmp/ospc2flex_windows_repair.sh (VirtIO driver injection script)
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SERVER_NAME=""
SERVER_IP=""
LABEL=""
FLAVOR="gp.5.4.4"
NETWORK="tenant-net"
KEYPAIR="laptopubuntu24"
WORK="/mnt/migration/ospc2flex_image"
DATE_STR=$(date +%Y%m%d-%H%M)
LOG_FILE="/tmp/winmig_${LABEL}.log"
OSPC_CREDS="/tmp/ospc2flex_ospc.sh"
FLEX_CREDS="/tmp/ospc2flex_flex.sh"
WIN_REPAIR="/tmp/ospc2flex_windows_repair.sh"
DRY_RUN=0
OS_FAMILY="windows"
OS_TYPE="win2019"
LINUX_REPAIR="/tmp/ospc2flex_offline_repair.sh"

# ── Color helpers ─────────────────────────────────────────────────────────────
# Log helpers write to STDERR (not stdout) so they never contaminate captured
# command substitutions like $(_resolve_glance_base) — previous bug was
# WARN inside that helper polluting $OS_IMAGE_URL with multi-line text +
# emoji, which curl then rejected with "URL rejected: Malformed input to a
# URL function" (curl exit 3).  The caller invokes this script with
# `... >log 2>&1` so stderr still lands in the SSE-streamed log file.
log()  { echo "[$(date '+%H:%M:%S')][$LABEL] $*" >&2; }
PASS() { echo "  ✅ $*" >&2; }
FAIL() { echo "  ❌ $*" >&2; }
WARN() { echo "  ⚠️  $*" >&2; }
INFO() { echo "  ℹ️  $*" >&2; }

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-name) SERVER_NAME="$2"; shift 2 ;;
    --server-ip)   SERVER_IP="$2"; shift 2 ;;
    --label)       LABEL="$2"; shift 2 ;;
    --flavor)      FLAVOR="$2"; shift 2 ;;
    --network)     NETWORK="$2"; shift 2 ;;
    --keypair)     KEYPAIR="$2"; shift 2 ;;
    --os-family)   OS_FAMILY="$2"; shift 2 ;;
    --os-type)     OS_TYPE="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: $0 --server-name <name> --server-ip <ip> --label <label> [--flavor <f>] [--network <n>] [--keypair <k>]"
      exit 0 ;;
    *) INFO "Ignoring unknown arg: $1"; shift 1 ;;
  esac
done

[ -z "$SERVER_NAME" ] && { echo "ERROR: --server-name required"; exit 1; }
[ -z "$LABEL" ] && LABEL="ospc2flex-$(echo "$SERVER_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"



QCOW="$WORK/${LABEL}.qcow2"
LOG="/tmp/mig_${LABEL}.log"
exec > >(tee -a "$LOG") 2>&1

echo "═══════════════════════════════════════════════════════════════════════════"
echo " OSPC→FLEX Windows Migration (Glance Snapshot Method)"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  Server    : $SERVER_NAME ($SERVER_IP)"
echo "  Label     : $LABEL"
echo "  Flavor    : $FLAVOR"
echo "  Network   : $NETWORK"
echo "  Keypair   : $KEYPAIR"
echo "  OS Family : $OS_FAMILY"
echo "  OS Type   : $OS_TYPE"
echo "═══════════════════════════════════════════════════════════════════════════"

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Create OSPC Snapshot
# ═══════════════════════════════════════════════════════════════════════════════
log "Step 1: Creating OSPC snapshot of '$SERVER_NAME'..."
source /tmp/ospc2flex_ospc.sh

export OS_IDENTITY_API_VERSION=2
OS_TOKEN=$(openstack token issue -f value -c id 2>/dev/null || true)
if [ -z "$OS_TOKEN" ] && [ -n "${OS_USERNAME:-}" ] && [ -n "${OS_PASSWORD:-}" ]; then
  # RAX apikey auth via curl fallback for openstack CLI
  _AUTH=$(curl -s -X POST "${OS_AUTH_URL:-https://identity.api.rackspacecloud.com/v2.0/}tokens" \
    -H "Content-Type: application/json" \
    -d "{\"auth\":{\"RAX-KSKEY:apiKeyCredentials\":{\"username\":\"$OS_USERNAME\",\"apiKey\":\"$OS_PASSWORD\"}}}" 2>/dev/null || true)
  OS_TOKEN=$(echo "$_AUTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['access']['token']['id'])" 2>/dev/null || true)
  if [ -n "$OS_TOKEN" ]; then
    export OS_TOKEN
    export OS_AUTH_TYPE=token
  fi
fi

SNAP_NAME="${LABEL}-snap-$(date +%Y%m%d%H%M)"

# Get SERVER_ID using openstack CLI. Try searching by IP first.
# If that fails, fallback to name parsing.
SERVER_ID=$(openstack server list -f value -c ID -c Networks 2>/dev/null | grep -F "$SERVER_IP" | head -1 | awk '{print $1}' || true)
if [ -z "$SERVER_ID" ]; then
  INFO "Could not find server by IP $SERVER_IP. Falling back to SERVER_NAME '$SERVER_NAME'..."
  SERVER_ID=$(openstack server list -f value -c ID -c Name 2>/dev/null | grep -F "$SERVER_NAME" | head -1 | awk '{print $1}' || true)
fi

if [ -z "$SERVER_ID" ]; then
  FAIL "No Server found for $SERVER_NAME or IP $SERVER_IP. (Is OSPC authentication working?)"
  exit 1
fi


# Check if server is in image_uploading state (from a previous run) — wait for it
log "  Checking server task state..."
for i in $(seq 1 30); do
  TASK_STATE=$(openstack server show "$SERVER_ID" -f value -c OS-EXT-STS:task_state 2>/dev/null || echo "none")
  if [ "$TASK_STATE" = "None" ] || [ "$TASK_STATE" = "none" ] || [ -z "$TASK_STATE" ]; then
    break
  fi
  WARN "Server is in task_state: $TASK_STATE — waiting 30s... ($i/30)"
  sleep 30
done

# Check if a usable snapshot already exists for this label (from a previous run)
SNAP_ID=$(openstack image list --name "${LABEL}-snap" -f value -c ID 2>/dev/null | head -1 || true)
if [ -z "$SNAP_ID" ]; then
  # Look for any snap with our label prefix
  SNAP_ID=$(openstack image list -f value -c ID -c Name 2>/dev/null | grep -F "${LABEL}-snap" | head -1 | awk '{print $1}' || true)
fi

if [ -n "$SNAP_ID" ]; then
  SNAP_STATUS=$(openstack image show "$SNAP_ID" -f value -c status 2>/dev/null || echo "unknown")
  if [ "$SNAP_STATUS" = "active" ]; then
    PASS "Reusing existing snapshot: $SNAP_ID (status: active)"
  else
    INFO "Existing snapshot $SNAP_ID is in state: $SNAP_STATUS — creating fresh one"
    SNAP_ID=""
  fi
fi

if [ -z "$SNAP_ID" ]; then
  # Create fresh snapshot
  openstack server image create --name "$SNAP_NAME" "$SERVER_ID" --wait 2>&1 || true
  sleep 5
  SNAP_ID=$(openstack image list --name "$SNAP_NAME" -f value -c ID 2>/dev/null | head -1 || true)
  if [ -z "$SNAP_ID" ]; then
    SNAP_ID=$(openstack image show "$SNAP_NAME" -f value -c id 2>/dev/null || true)
  fi
fi

if [ -z "$SNAP_ID" ]; then
  FAIL "Failed to create snapshot for '$SERVER_NAME'"
  exit 1
fi
PASS "Snapshot ready: $SNAP_ID"

# Wait for snapshot to become active
log "  Waiting for snapshot to become active..."
for i in $(seq 1 60); do
  STATUS=$(openstack image show "$SNAP_ID" -f value -c status 2>/dev/null || echo "unknown")
  if [ "$STATUS" = "active" ]; then
    PASS "Snapshot active after $((i * 10)) seconds"
    break
  fi
  if [ "$STATUS" = "error" ] || [ "$STATUS" = "killed" ]; then
    FAIL "Snapshot entered $STATUS state"
    exit 1
  fi
  INFO "Status: $STATUS (waiting 10s...)"
  sleep 10
done

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Download Snapshot
# ═══════════════════════════════════════════════════════════════════════════════
log "Step 2: Downloading snapshot (via ServiceNet)..."
INFO "Large Windows disks often take 30–120+ minutes — heartbeat + size logged every 60s."
mkdir -p "$WORK"
IMG_PATH="$WORK/${LABEL}.img"
rm -f "$IMG_PATH"

# OSPC Rackspace Public Cloud only exposes PUBLIC Glance endpoints per region.
# Using OS_INTERFACE=internal causes `openstack image save` to error with
# "internal endpoint for image service in <region> not found". Force public.
export OS_INTERFACE=public
OS_USERNAME="${OS_USERNAME:-}"
OS_PASSWORD="${OS_PASSWORD:-}"
OS_REGION_NAME="${OS_REGION_NAME:-IAD}"
export OS_USERNAME OS_PASSWORD OS_REGION_NAME

_refresh_ospc_token() {
  OS_TOKEN=$(openstack token issue -f value -c id 2>/dev/null || true)
  if [ -z "$OS_TOKEN" ] && [ -n "$OS_USERNAME" ] && [ -n "$OS_PASSWORD" ]; then
    _AUTH=$(curl -s -X POST "${OS_AUTH_URL:-https://identity.api.rackspacecloud.com/v2.0/}tokens" \
      -H "Content-Type: application/json" \
      -d "{\"auth\":{\"RAX-KSKEY:apiKeyCredentials\":{\"username\":\"$OS_USERNAME\",\"apiKey\":\"$OS_PASSWORD\"}}}" 2>/dev/null || true)
    OS_TOKEN=$(echo "$_AUTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['access']['token']['id'])" 2>/dev/null || true)
  fi
  # Strip whitespace/CR that would make curl -H "X-Auth-Token: ..." malformed.
  OS_TOKEN=$(printf '%s' "$OS_TOKEN" | tr -d '[:space:]')
}

_region_short() {
  # lowercase region name with trailing digits stripped (e.g. "IAD" -> "iad",
  # "DFW" -> "dfw", "IAD3" -> "iad"). Defaults to "iad" when unset.
  local r
  r=$(echo "$OS_REGION_NAME" | tr '[:upper:]' '[:lower:]' | tr -d '0-9')
  [ -z "$r" ] && r="iad"
  printf '%s' "$r"
}

_glance_public_base() {
  # Public (internet) Glance endpoint — subject to the WAF that has been
  # returning HTTP 413 on large image /file downloads from OSPC PubCloud.
  printf 'https://%s.images.api.rackspacecloud.com' "$(_region_short)"
}

_glance_snet_base() {
  # ServiceNet (10/8) Glance endpoint — bypasses the public WAF. Reachable
  # from any OSPC jumphost and is the correct path for bulk image downloads.
  printf 'https://snet-%s.images.api.rackspacecloud.com' "$(_region_short)"
}

_resolve_glance_base() {
  # Prefer the catalog's "internal" (ServiceNet) URL when present; fall back
  # to our predictable snet-<region> hostname; then public catalog URL; then
  # public predictable hostname. ServiceNet is strongly preferred because the
  # public endpoint's load-balancer returns HTTP 413 on image file GETs.
  local out u
  u=""
  if out=$(openstack catalog show image -f json 2>/dev/null); then
    u=$(OPENSTACK_JSON="$out" python3 - <<'PY' 2>/dev/null || true
import json, os
d = json.loads(os.environ["OPENSTACK_JSON"])
eps = d.get("endpoints") or []
for w in ("internal", "admin", "public"):
    for e in eps:
        if str(e.get("interface", "")).lower() == w and e.get("url"):
            print(str(e["url"]).rstrip("/"))
            raise SystemExit(0)
print("")
PY
)
  fi
  if [ -z "$u" ]; then
    u=$(openstack endpoint list --service image --interface internal -f value -c URL 2>/dev/null | head -1 | sed 's|/$||' || true)
  fi
  if [ -z "$u" ]; then
    u=$(openstack endpoint list --service image --interface public -f value -c URL 2>/dev/null | head -1 | sed 's|/$||' || true)
  fi
  if [ -z "$u" ]; then
    u=$(_glance_snet_base)
    WARN "Catalog/endpoints empty — ServiceNet fallback: $u (OS_REGION_NAME=$OS_REGION_NAME)"
  fi
  printf '%s' "$u"
}

_url_host() {
  # Extract host from URL like https://host/path
  printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://([^/:]+).*$#\1#'
}

_host_resolves() {
  local h="$1"
  [ -z "$h" ] && return 1
  # If host is already a literal IPv4/IPv6, treat as usable endpoint.
  if echo "$h" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+$'; then
    return 0
  fi
  getent hosts "$h" >/dev/null 2>&1
}

_refresh_ospc_token
if [ -z "${OS_TOKEN:-}" ]; then
  FAIL "No OSPC token for Glance download"
  exit 1
fi

OS_IMAGE_URL=$(_resolve_glance_base)
# Defensive: strip any stray whitespace / CR / log contamination so curl never
# sees a malformed URL (curl ≥7.85 rejects URLs with whitespace).
OS_IMAGE_URL=$(printf '%s' "$OS_IMAGE_URL" | tr -d '[:space:]')

# Build ordered list of Glance base URLs to try. ServiceNet first (bypasses
# the public WAF that returns HTTP 413 on image /file GETs), public last.
SNET_BASE=$(_glance_snet_base)
PUB_BASE=$(_glance_public_base)
# Dedup/order: catalog-resolved (if it differs from both), snet, public
GLANCE_BASES=""
for b in "$SNET_BASE" "$OS_IMAGE_URL" "$PUB_BASE"; do
  b=$(printf '%s' "$b" | tr -d '[:space:]')
  [ -z "$b" ] && continue
  _h=$(_url_host "$b")
  if ! _host_resolves "$_h"; then
    WARN "Skipping unresolved Glance host: $_h (base=$b)"
    continue
  fi
  case " $GLANCE_BASES " in
    *" $b "*) : ;;
    *) GLANCE_BASES="$GLANCE_BASES $b" ;;
  esac
done
GLANCE_BASES=$(echo "$GLANCE_BASES" | sed -E 's/^ +//')
INFO "Glance bases (try order): $GLANCE_BASES"
if [ -z "$GLANCE_BASES" ]; then
  WARN "No resolvable endpoint from computed list; forcing public base fallback"
  GLANCE_BASES="$PUB_BASE"
fi
DL_URL="$OS_IMAGE_URL/v2/images/$SNAP_ID/file"
DL_URL=$(printf '%s' "$DL_URL" | tr -d '[:space:]')
INFO "Catalog-resolved Glance GET: $DL_URL"

# Start a heartbeat watcher that monitors $IMG_PATH size while any download
# method is running. This replaces the per-method heartbeat loops.
_start_heartbeat() {
  (
    n=0
    while [ -f "/tmp/winmig_hb_active_${LABEL}" ]; do
      sleep 60
      n=$((n + 1))
      sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
      log "  … download heartbeat #${n} — $((sz / 1024 / 1024)) MiB on disk (still running)"
    done
  ) &
  echo $! > "/tmp/winmig_hb_pid_${LABEL}"
}
_stop_heartbeat() {
  rm -f "/tmp/winmig_hb_active_${LABEL}" 2>/dev/null || true
  if [ -f "/tmp/winmig_hb_pid_${LABEL}" ]; then
    kill "$(cat "/tmp/winmig_hb_pid_${LABEL}" 2>/dev/null)" 2>/dev/null || true
    rm -f "/tmp/winmig_hb_pid_${LABEL}" 2>/dev/null || true
  fi
}

# One curl attempt to $1=base URL. Returns 0 on success (file ≥1MB).
_curl_download_from() {
  local base="$1" attempt="$2"
  local url log
  url="${base}/v2/images/${SNAP_ID}/file"
  url=$(printf '%s' "$url" | tr -d '[:space:]')
  log="/tmp/winmig_curl_${LABEL}_${attempt}_$(echo "$base" | sed 's|[^a-zA-Z0-9]|_|g').log"
  rm -f "$IMG_PATH"
  INFO "  → curl $url"
  : > "/tmp/winmig_hb_active_${LABEL}"
  _start_heartbeat
  set +e
  curl -fSL --connect-timeout 30 --retry 2 --retry-delay 10 \
    -H 'Expect:' \
    -H 'Accept: application/octet-stream' \
    -H "X-Auth-Token: $OS_TOKEN" \
    -A 'ospc2flex/1.0 (+jumphost-migrator)' \
    -o "$IMG_PATH" \
    --write-out "\\nHTTP_CODE=%{http_code} SIZE=%{size_download}B TIME=%{time_total}s\\n" \
    "$url" >"$log" 2>&1
  local rc=$?
  set -e
  _stop_heartbeat
  LAST_CURL_LOG="$log"
  local sz
  sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
  if [ "$rc" -eq 0 ] && [ "$sz" -ge 1048576 ]; then
    return 0
  fi
  WARN "  curl rc=$rc size=${sz}B log=$log — last lines:"
  # show both the curl stderr (headers/errors) AND the response body so 413
  # messages are visible
  tail -6 "$log" 2>/dev/null | while read -r _ln; do WARN "    $_ln"; done || true
  if [ -s "$IMG_PATH" ] && [ "$sz" -lt 2048 ]; then
    # small body = error payload, show it
    WARN "  error body ($sz B):"
    head -c 512 "$IMG_PATH" 2>/dev/null | sed 's/^/    /' | while read -r _ln; do WARN "$_ln"; done || true
  fi
  # Track root-cause signals so the outer loop can fail fast with a useful message.
  if grep -qi "Could not resolve host" "$log" 2>/dev/null; then
    SAW_SNET_DNS_FAIL=1
  fi
  if grep -qiE "HTTP_CODE=413|returned error: 413|Unable to download image: InvalidResponse" "$log" 2>/dev/null; then
    SAW_PUBLIC_413=1
  fi
  return 1
}

# One openstack image save attempt against a forced endpoint URL. Uses
# --os-image-url to bypass catalog interface selection.
_osave_download_from() {
  local base="$1" attempt="$2"
  local log
  log="/tmp/winmig_osave_${LABEL}_${attempt}_$(echo "$base" | sed 's|[^a-zA-Z0-9]|_|g').log"
  rm -f "$IMG_PATH"
  INFO "  → openstack image save $SNAP_ID (default endpoint)"
  : > "/tmp/winmig_hb_active_${LABEL}"
  _start_heartbeat
  set +e
  # Prefer plain image save first (most compatible across OpenStack clients).
  openstack image save --file "$IMG_PATH" "$SNAP_ID" >"$log" 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    INFO "  default endpoint failed; retrying with OS_IMAGE_URL=$base"
    OS_IMAGE_URL="$base" openstack image save --file "$IMG_PATH" "$SNAP_ID" >"$log" 2>&1
    rc=$?
  fi
  set -e
  _stop_heartbeat
  local sz
  sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
  if [ "$rc" -eq 0 ] && [ "$sz" -ge 1048576 ]; then
    return 0
  fi
  WARN "  openstack image save rc=$rc size=${sz}B log=$log — key error lines:"
  grep -iE "error|fail|forbidden|unauthorized|not found|unrecognized|invalid|endpoint|timeout" "$log" 2>/dev/null | tail -10 | while read -r _ln; do WARN "    $_ln"; done || true
  tail -6 "$log" 2>/dev/null | while read -r _ln; do WARN "    $_ln"; done || true
  return 1
}

# Master waterfall: for each base URL, try openstack CLI then curl.
# First success wins.
_try_download_methods() {
  local attempt="$1"
  local base

  for base in $GLANCE_BASES; do
    INFO "Attempt ${attempt}: trying Glance base: $base"

    # Method A: openstack image save (pinned to this base)
    if _osave_download_from "$base" "$attempt"; then
      _sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
      DOWNLOAD_METHOD="openstack image save via $base"
      PASS "Downloaded via $DOWNLOAD_METHOD: $((_sz / 1024 / 1024))MB (attempt $attempt)"
      return 0
    fi
    if [ -f "/tmp/winmig_osave_${LABEL}_${attempt}_$(echo "$base" | sed 's|[^a-zA-Z0-9]|_|g').log" ]; then
      _oslog="/tmp/winmig_osave_${LABEL}_${attempt}_$(echo "$base" | sed 's|[^a-zA-Z0-9]|_|g').log"
      if grep -qiE "Unable to download image: InvalidResponse|HTTP 413|returned error: 413" "$_oslog" 2>/dev/null; then
        SAW_PUBLIC_413=1
      fi
      if grep -qi "Could not resolve host" "$_oslog" 2>/dev/null; then
        SAW_SNET_DNS_FAIL=1
      fi
    fi

    # Method B: curl direct with X-Auth-Token
    if _curl_download_from "$base" "$attempt"; then
      _sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
      DOWNLOAD_METHOD="curl via $base"
      PASS "Downloaded via $DOWNLOAD_METHOD: $((_sz / 1024 / 1024))MB (attempt $attempt)"
      return 0
    fi
  done

  return 1
}

attempt=1
max_dl=5
IMG_SIZE=0
LAST_CURL_LOG=""
DOWNLOAD_METHOD=""
SAW_SNET_DNS_FAIL=0
SAW_PUBLIC_413=0
while [ "$attempt" -le "$max_dl" ]; do
  if _try_download_methods "$attempt"; then
    IMG_SIZE=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
    break
  fi
  if [ "$SAW_SNET_DNS_FAIL" -eq 1 ] && [ "$SAW_PUBLIC_413" -eq 1 ]; then
    FAIL "Glance download blocked: ServiceNet endpoint is unresolved on jumphost and public endpoint is returning HTTP 413."
    FAIL "Use a jumphost with working ServiceNet DNS/routing (snet-<region>.images.api.rackspacecloud.com) or request Rackspace to remove public /file 413 limit."
    exit 1
  fi
  WARN "All download methods failed on attempt $attempt/$max_dl — refreshing token and retrying..."
  _refresh_ospc_token
  if [ -z "${OS_TOKEN:-}" ]; then
    FAIL "Lost OSPC token during download retries"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 10
done

if [ "${IMG_SIZE:-0}" -lt 1048576 ]; then
  FAIL "Glance download failed after $max_dl attempts (${IMG_SIZE:-0} bytes). Last curl log: ${LAST_CURL_LOG:-none}"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Convert to qcow2
# ═══════════════════════════════════════════════════════════════════════════════
log "Step 3: Converting to qcow2..."
DETECTED_FMT=$(qemu-img info --output=json "$IMG_PATH" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('format','raw'))" 2>/dev/null || echo "raw")
INFO "Detected format: $DETECTED_FMT"

if [ "$DETECTED_FMT" = "qcow2" ]; then
  mv "$IMG_PATH" "$QCOW"
  PASS "Already qcow2 — renamed"
else
  qemu-img convert -p -f "$DETECTED_FMT" -O qcow2 "$IMG_PATH" "$QCOW" 2>&1 || { FAIL "qemu-img convert failed"; exit 1; }
  rm -f "$IMG_PATH"
  PASS "Converted to qcow2"
fi
QCOW_SIZE=$(stat -c%s "$QCOW" 2>/dev/null || echo 0)
INFO "qcow2 size: $((QCOW_SIZE/1024/1024))MB"

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: Windows VirtIO Repair
# ═══════════════════════════════════════════════════════════════════════════════
log "Step 4: Offline VirtIO driver injection & Repair..."
if [ "$OS_FAMILY" = "linux" ]; then
  if [ -f "$LINUX_REPAIR" ]; then
    set +e
    # Call the v2.5 RHEL-aware linux repair script
    bash "$LINUX_REPAIR" --qcow2 "$QCOW" --os-type "$OS_TYPE" --force --preserve-password-auth 2>&1
    REPAIR_EXIT=$?
    set -e
    if [ "$REPAIR_EXIT" -eq 0 ]; then
      PASS "Linux repair completed successfully"
    else
      WARN "Linux repair exited with code $REPAIR_EXIT — continuing anyway"
    fi
  else
    WARN "$LINUX_REPAIR not found — skipping Linux virtio injection!"
  fi
else
  if [ -f "$WIN_REPAIR" ]; then
    set +e  # temporarily disable abort on error
    bash "$WIN_REPAIR" --qcow2 "$QCOW" --force 2>&1
    REPAIR_EXIT=$?
    set -e
    if [ "$REPAIR_EXIT" -eq 0 ]; then
      PASS "Windows repair completed successfully"
    else
      WARN "Windows repair exited with code $REPAIR_EXIT — continuing anyway"
    fi
  else
    WARN "$WIN_REPAIR not found — skipping VirtIO injection"
    WARN "Windows VM may not boot without VirtIO drivers!"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 5: Upload to FLEX
# ═══════════════════════════════════════════════════════════════════════════════
log "Step 5: Uploading to FLEX..."
OSPC_TOKEN="${OS_TOKEN:-}"
unset OS_TOKEN OS_AUTH_TYPE OS_IDENTITY_API_VERSION
source /tmp/ospc2flex_flex.sh

# Kept logic to not delete old images
OLD_IIDS=$(openstack image list --name "$LABEL" -f value -c ID 2>/dev/null)
if [ -n "$OLD_IIDS" ]; then
  INFO "Old images found: $OLD_IIDS (Skipping deletion as per user request)"
fi

openstack image create "$LABEL" \
  --disk-format qcow2 \
  --container-format bare \
  --file "$QCOW" \
  --private 2>&1

# Wait for image to become active
FLEX_IMG_ID=$(openstack image list --name "$LABEL" -f value -c ID 2>/dev/null | head -1 || true)
if [ -z "$FLEX_IMG_ID" ]; then
  FAIL "Image upload failed"
  exit 1
fi

for i in $(seq 1 30); do
  STATUS=$(openstack image show "$FLEX_IMG_ID" -f value -c status 2>/dev/null || echo "unknown")
  [ "$STATUS" = "active" ] && break
  sleep 5
done
PASS "Image uploaded: $FLEX_IMG_ID (status: $STATUS)"

# ═══════════════════════════════════════════════════════════════════════════════
# Step 6: Boot VM on FLEX
# ═══════════════════════════════════════════════════════════════════════════════
log "Step 6: Booting VM on FLEX..."

# Kept logic to not delete old VMs
OLD_VIDS=$(openstack server list -f value -c ID -c Name 2>/dev/null | grep -F "$LABEL" | awk '{print $1}' || true)
if [ -n "$OLD_VIDS" ]; then
  INFO "Old VMs found: $OLD_VIDS (Skipping deletion as per user request)"
fi

openstack server create "$LABEL" \
  --image "$FLEX_IMG_ID" \
  --flavor "$FLAVOR" \
  --network "$NETWORK" \
  --key-name "$KEYPAIR" \
  --wait 2>&1

sleep 10

# Get VM status
VM_ID=$(openstack server list -f value -c ID -c Name 2>/dev/null | grep -F "$LABEL" | head -1 | awk '{print $1}' || true)
VM_STATUS=$(openstack server show "$VM_ID" -f value -c status 2>/dev/null || echo "unknown")

if [ "$VM_STATUS" = "ACTIVE" ]; then
  PASS "VM booted: $VM_ID (ACTIVE)"
else
  WARN "VM status: $VM_STATUS (may need console check)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 7: Assign Floating IP
# ═══════════════════════════════════════════════════════════════════════════════
log "Step 7: Assigning floating IP..."
FIP=$(openstack floating ip list --status DOWN -f value -c "Floating IP Address" 2>/dev/null | shuf | head -1 || true)
if [ -z "$FIP" ]; then
  WARN "No available floating IPs"
else
  openstack server add floating ip "$VM_ID" "$FIP" 2>/dev/null || true
  sleep 3
  # Verify
  ACTUAL_FIP=$(openstack server show "$VM_ID" -f value -c addresses 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | grep -v '^10\.' | head -1 || true)
  if [ -n "$ACTUAL_FIP" ]; then
    PASS "Floating IP: $ACTUAL_FIP"
    INFO "RDP: mstsc /v:$ACTUAL_FIP"
  else
    WARN "FIP assignment may have failed"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
log "=== DONE ==="
echo "  Server:   $LABEL"
echo "  Image:    $FLEX_IMG_ID"
echo "  VM:       $VM_ID ($VM_STATUS)"
echo "  RDP:      mstsc /v:${ACTUAL_FIP:-unknown}"
echo "  Download: ${DOWNLOAD_METHOD:-unknown} (Step 2: OSPC Glance → jumphost)"
echo "═══════════════════════════════════════════════════════════════════════════"

# Cleanup OSPC snapshot
log "Cleaning up OSPC snapshot $SNAP_NAME..."
source /tmp/ospc2flex_ospc.sh
if [ -n "${OSPC_TOKEN:-}" ]; then
  export OS_TOKEN="$OSPC_TOKEN"
  export OS_AUTH_TYPE=token
  export OS_IDENTITY_API_VERSION=2
fi
openstack image delete "$SNAP_ID" 2>/dev/null || true
PASS "OSPC snapshot deleted"
