#!/usr/bin/env bash
# ospc2flex_linux_snap_migrate.sh — Linux snapshot migration (runs on jumphost)
#
# Download:  Method Z waterfall (Glance direct → curl → Cloud Files → Cinder)
# Repair:    ospc2flex_offline_repair.sh  (mig_worker_v4 Step 4 — proven working)
# Upload:    openstack image create with retry  (mig_worker_v4 Step 5)
# Boot:      FLEX VM create + wait ACTIVE  (mig_worker_v4 Step 7)
# SSH test:  FIP + ssh-ok probe  (mig_worker_v4 Step 9)
#
# Resume:    If QCOW exists → skip download.  If repair marker exists → skip repair.

set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

if [ -z "${OSPC2FLEX_LINEBUF_WRAPPER:-}" ] && command -v stdbuf >/dev/null 2>&1; then
  export OSPC2FLEX_LINEBUF_WRAPPER=1
  exec stdbuf -oL -eL bash "$0" "$@"
fi

# ── Defaults ─────────────────────────────────────────────────────────────────
LABEL=""
OSPC_IMAGE_ID=""
OSPC_OPENRC=""
FLEX_OPENRC=""
OS_TYPE=""
BASE_DIR="${OSPC2FLEX_LINUX_SNAP_BASE_DIR:-/mnt/migration/ospc2flex_linux_snap}"
FLEX_REGION="${FLEX_REGION:-DFW3}"
FLAVOR="${FLEX_FLAVOR:-${MIG_FLAVOR:-gp.0.4.4}}"
NETWORK="${FLEX_NETWORK:-${MIG_NETWORK:-tenant-net}}"
KEYPAIR="${FLEX_KEYPAIR:-}"
FLEX_EXT_NET="${OSPC2FLEX_FLEX_EXT_NET:-PUBLICNET}"
EXPORT_RETRIES="${OSPC2FLEX_IMAGE_EXPORT_RETRIES:-4}"
EXPORT_RETRY_WAIT="${OSPC2FLEX_IMAGE_EXPORT_RETRY_WAIT:-15}"
CLOUD_FILES_EXPORT_TIMEOUT="${OSPC2FLEX_CF_EXPORT_TIMEOUT:-7200}"
CINDER_VOLUME_EXPORT_ON_LICENSED="${OSPC2FLEX_CINDER_VOLUME_EXPORT_ON_LICENSED:-1}"
CINDER_MIN_VOLUME_SIZE_GB="${OSPC2FLEX_CINDER_MIN_VOLUME_SIZE_GB:-75}"
DOWNLOAD_ONLY=0
REPAIR_VERSION="${OSPC2FLEX_LINUX_SNAP_REPAIR_VERSION:-20260516-v1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)              LABEL="$2";        shift 2 ;;
    --ospc-image-id|--ospc-snapshot-id) OSPC_IMAGE_ID="$2"; shift 2 ;;
    --ospc-openrc)        OSPC_OPENRC="$2";  shift 2 ;;
    --flex-openrc)        FLEX_OPENRC="$2";  shift 2 ;;
    --os-type)            OS_TYPE="$2";      shift 2 ;;
    --base-dir)           BASE_DIR="$2";     shift 2 ;;
    --flex-region)        FLEX_REGION="$2";  shift 2 ;;
    --flavor|--flex-flavor) FLAVOR="$2";     shift 2 ;;
    --network|--flex-network) NETWORK="$2";  shift 2 ;;
    --keypair|--flex-keypair) KEYPAIR="$2";  shift 2 ;;
    --nbd-dev)           NBD_DEV="$2";      shift 2 ;;
    --download-only)      DOWNLOAD_ONLY=1;   shift ;;
    *) echo "ERROR: Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$LABEL" ]       || { echo "ERROR: --label required" >&2; exit 2; }
[ -n "$OSPC_OPENRC" ] || { echo "ERROR: --ospc-openrc required" >&2; exit 2; }
[ -n "$FLEX_OPENRC" ] || { echo "ERROR: --flex-openrc required" >&2; exit 2; }

LABEL_SAFE="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_$//')"
RUN_ID="${OSPC2FLEX_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
RUN_DIR="$BASE_DIR/runs/$LABEL_SAFE/$RUN_ID"
JOB_ART="$RUN_DIR/artifacts"
JOB_LOG="$RUN_DIR/logs"
JOB_TMP="$RUN_DIR/tmp"

if ! mkdir -p "$JOB_ART" "$JOB_LOG" "$JOB_TMP" 2>/dev/null; then
  sudo mkdir -p "$BASE_DIR" && sudo chown -R "$(id -u):$(id -g)" "$BASE_DIR"
  mkdir -p "$JOB_ART" "$JOB_LOG" "$JOB_TMP"
fi

PROGRESS_LOG="$JOB_LOG/linux_snap.progress.log"
BACKGROUND_LOG="$JOB_LOG/linux_snap.background.log"
: >"$PROGRESS_LOG"; : >"$BACKGROUND_LOG"

QCOW="$JOB_ART/${LABEL_SAFE}.qcow2"
REPAIR_MARKER="${QCOW}.linux_repaired"
REPAIR_LOG="$JOB_ART/${LABEL_SAFE}.repair.log"
NBD_DEV="/dev/nbd0"
CURRENT_STAGE="LS0_PREFLIGHT"
DOWNLOAD_FAILURE_REASON="OSPC_SNAPSHOT_DOWNLOAD_UNAVAILABLE"

# ── Per-OS defaults ───────────────────────────────────────────────────────────
infer_flex_user() {
  case "${OS_TYPE,,}" in
    ubuntu*) echo "ubuntu" ;;
    debian*) echo "admin" ;;
    centos*|rhel7*|rhel6*) echo "centos" ;;
    alma*|almalinux*) echo "almalinux" ;;
    rocky*) echo "rocky" ;;
    *) echo "root" ;;
  esac
}
FLEX_USER="${FLEX_USER:-$(infer_flex_user)}"

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
  local msg="$*" ts
  ts="[$(date '+%H:%M:%S')]"
  echo "${ts}[$LABEL_SAFE][LINSNAP] ${msg}"
  echo "${ts}[$LABEL_SAFE][LINSNAP] ${msg}" >>"$BACKGROUND_LOG"
  echo "${ts}[$LABEL_SAFE][LINSNAP] ${msg}" >>"$PROGRESS_LOG"
}
kv() { log "  $(printf '%-18s' "$1") : ${*:2}"; }
stage() {
  CURRENT_STAGE="$1"
  log "══════════════════════════════════════════════════════"
  log "  $CURRENT_STAGE"
  log "══════════════════════════════════════════════════════"
}
fail_exit() {
  local s="$1" reason="$2"
  log "[$s] FAILED: $reason"
  exit 1
}
trap 'log "TRAP: unexpected error at line $LINENO: $BASH_COMMAND"; exit 1' ERR

# ── Tool check / install ──────────────────────────────────────────────────────
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail_exit "$CURRENT_STAGE" "missing_command: $1 — install it on the jumphost"
}
install_if_missing() {
  local missing=() c pkg
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [ "${#missing[@]}" -gt 0 ] || return 0
  log "[LS0] Installing missing: ${missing[*]}"
  command -v apt-get >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1 || {
    fail_exit "LS0_PREFLIGHT" "Missing: ${missing[*]} and cannot auto-install (no apt-get or passwordless sudo)"
  }
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update >>"$BACKGROUND_LOG" 2>&1
  for c in "${missing[@]}"; do
    case "$c" in
      qemu-img|qemu-nbd) pkg="qemu-utils" ;;
      openstack) pkg="python3-openstackclient" ;;
      curl) pkg="curl" ;;
      python3) pkg="python3" ;;
      *) pkg="$c" ;;
    esac
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >>"$BACKGROUND_LOG" 2>&1 || true
    command -v "$c" >/dev/null 2>&1 || fail_exit "LS0_PREFLIGHT" "$c still missing after install attempt"
    log "[LS0] OK: $c"
  done
}

# ── openrc helpers ────────────────────────────────────────────────────────────
source_ospc_openrc() {
  [ -f "$OSPC_OPENRC" ] || fail_exit "$CURRENT_STAGE" "OSPC openrc not found: $OSPC_OPENRC"
  unset OS_TOKEN OS_AUTH_TOKEN OS_SERVICE_TOKEN OS_AUTH_TYPE \
        OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_NAME OS_APPLICATION_CREDENTIAL_SECRET \
        OS_USERNAME OS_PASSWORD OS_PROJECT_ID OS_PROJECT_NAME OS_TENANT_ID OS_TENANT_NAME \
        OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_NAME OS_DOMAIN_NAME 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$OSPC_OPENRC"
}
source_flex_openrc() {
  [ -f "$FLEX_OPENRC" ] || fail_exit "$CURRENT_STAGE" "FLEX openrc not found: $FLEX_OPENRC"
  unset OS_TOKEN OS_AUTH_TOKEN OS_SERVICE_TOKEN OS_AUTH_TYPE \
        OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_NAME OS_APPLICATION_CREDENTIAL_SECRET \
        OS_USERNAME OS_PASSWORD OS_PROJECT_ID OS_PROJECT_NAME OS_TENANT_ID OS_TENANT_NAME \
        OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_NAME OS_DOMAIN_NAME 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$FLEX_OPENRC"
}

# ════════════════════════════════════════════════════════════════════════════
# ── DOWNLOAD HELPERS — copied verbatim from Method Z (proven working) ────────
# ════════════════════════════════════════════════════════════════════════════
url_host() { printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://([^/:]+).*$#\1#'; }
host_resolves() {
  local h="$1"; [ -n "$h" ] || return 1
  printf '%s' "$h" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+$' && return 0
  getent hosts "$h" >/dev/null 2>&1
}
normalize_glance_base() { printf '%s' "$1" | tr -d '[:space:]' | sed -E 's#/v2/?$##'; }
region_short() {
  local r="${OS_REGION_NAME:-IAD}"
  r="$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]' | tr -d '0-9')"
  [ -n "$r" ] || r="iad"; printf '%s' "$r"
}
ospc_tenant_id() {
  printf '%s' "${OS_TENANT_ID:-${OS_PROJECT_ID:-${OS_TENANT_NAME:-${OS_PROJECT_NAME:-}}}}"
}
translate_rackspace_images_base() {
  local base host label prefix region translated_host
  base="$(normalize_glance_base "$1")"
  host="$(url_host "$base")"
  case "$host" in
    *.images.api.rackspacecloud.com)
      label="${host%.images.api.rackspacecloud.com}"; prefix=""; region="$label"
      printf '%s' "$region" | grep -q '^snet-' && { prefix="snet-"; region="${region#snet-}"; }
      printf '%s' "$region" | grep -q '[0-9]' || region="${region}3"
      translated_host="${prefix}${region}.images.api.rackspacecloud.com"
      printf '%s' "$base" | sed "s#${host}#${translated_host}#" ;;
    *) printf '%s' "$base" ;;
  esac
}
image_bases() {
  local region catalog_json url translated
  region="$(region_short)"
  catalog_json="$(openstack catalog show image -f json 2>/dev/null || true)"
  {
    if [ -s "$JOB_TMP/ospc_identity_v2_auth.json" ]; then
      WANTED_REGION="$(printf '%s' "${OS_REGION_NAME:-ALL}" | tr '[:lower:]' '[:upper:]')" python3 - "$JOB_TMP/ospc_identity_v2_auth.json" <<'PY' 2>/dev/null || true
import json, os, sys
wanted = (os.environ.get("WANTED_REGION") or "ALL").strip().upper()
try: data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception: data = {}
for svc in (((data or {}).get("access") or {}).get("serviceCatalog") or []):
    stype = str((svc or {}).get("type") or "").strip().lower()
    sname = str((svc or {}).get("name") or "").strip().lower()
    if stype not in {"image","cloudimages"} and sname not in {"image","cloudimages"}: continue
    for ep in (svc or {}).get("endpoints") or []:
        region = str((ep or {}).get("region") or "").strip().upper()
        url = str((ep or {}).get("publicURL") or (ep or {}).get("url") or "").strip().rstrip("/")
        if not url: continue
        if wanted != "ALL" and region != wanted: continue
        print(url)
PY
    fi
    if [ -n "$catalog_json" ]; then
      CATALOG_JSON="$catalog_json" python3 - <<'PY' 2>/dev/null || true
import json, os
try: data = json.loads(os.environ.get("CATALOG_JSON","{}"))
except Exception: data = {}
for ep in data.get("endpoints") or []:
    iface = str(ep.get("interface") or "").lower()
    if iface == "public":
        url = ep.get("url") or ep.get("publicURL") or ep.get("internalURL") or ep.get("adminURL")
        if url: print(str(url).rstrip("/"))
PY
    fi
    openstack endpoint list --service image --interface public -f value -c URL 2>/dev/null || true
    printf 'https://%s.images.api.rackspacecloud.com\n' "$region"
    printf 'https://%s3.images.api.rackspacecloud.com\n' "$region"
  } | while IFS= read -r url; do
    [ -n "$url" ] || continue
    url="$(normalize_glance_base "$url")"
    printf '%s\n' "$url"
    translated="$(translate_rackspace_images_base "$url")"
    [ "$translated" != "$url" ] && printf '%s\n' "$translated"
  done | awk 'NF && !seen[$0]++'
}

rackspace_identity_v2_auth() {
  local auth_url api_key tenant payload auth_resp token
  api_key="${OS_API_KEY:-${OS_PASSWORD:-}}"
  tenant="$(ospc_tenant_id)"
  [ -n "${OS_USERNAME:-}" ] && [ -n "$api_key" ] && [ -n "$tenant" ] || return 1
  auth_url="${OS_AUTH_URL:-https://identity.api.rackspacecloud.com/v2.0/}"
  auth_url="${auth_url%/}/tokens"
  payload="$(OSPC_USER="$OS_USERNAME" OSPC_API_KEY="$api_key" OSPC_TENANT="$tenant" python3 - <<'PY'
import json, os
print(json.dumps({"auth":{"RAX-KSKEY:apiKeyCredentials":{"username":os.environ["OSPC_USER"],"apiKey":os.environ["OSPC_API_KEY"]},"tenantId":os.environ["OSPC_TENANT"]}},separators=(",",":")))
PY
)"
  auth_resp="$(curl -sS -k -X POST "$auth_url" -H "Content-Type: application/json" -H "Accept: application/json" -d "$payload" 2>/dev/null || true)"
  token="$(printf '%s' "$auth_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access"]["token"]["id"])' 2>/dev/null || true)"
  [ -n "$token" ] || return 1
  printf '%s\n' "$auth_resp" >"$JOB_TMP/ospc_identity_v2_auth.json" 2>/dev/null || true
  chmod 600 "$JOB_TMP/ospc_identity_v2_auth.json" 2>/dev/null || true
  printf '%s' "$token"
}
refresh_ospc_token() {
  local token
  token="$(rackspace_identity_v2_auth || true)"
  [ -n "$token" ] && { printf '%s' "$token"; return 0; }
  token="$(openstack token issue -f value -c id 2>/dev/null || true)"
  [ -n "$token" ] && { printf '%s' "$token"; return 0; }
  return 1
}
safe_object_name() {
  python3 -c 'import re,sys; print(re.sub(r"[^A-Za-z0-9._-]+","_",sys.argv[1]).strip("._-") or "ospc2flex-linux-snap-image")' "$1"
}
first_resolvable_image_base() {
  local base host
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    host="$(url_host "$base")"
    if host_resolves "$host"; then printf '%s' "$base"; return 0; fi
  done < <(image_bases)
  return 1
}
log_file_excerpt() {
  local prefix="$1" file="$2"
  [ -s "$file" ] || return 0
  grep -iE 'error|fail|invalid|413|403|404|forbidden|unauthorized|endpoint|resolve|timeout|exception|denied' "$file" 2>/dev/null | tail -8 | while IFS= read -r line; do [ -n "$line" ] && log "$prefix $line"; done
  tail -5 "$file" 2>/dev/null | while IFS= read -r line; do [ -n "$line" ] && log "$prefix tail: $line"; done
}
is_terminal_direct_download_block() {
  local file="$1"
  [ -s "$file" ] || return 1
  grep -qiE 'HTTP_CODE=413|returned error: 413|Request Entity Too Large|InvalidResponse' "$file"
}
download_openstack_save() {
  local base="$1" image_id="$2" dest="$3" min_bytes="$4" tmp_log="$5" rc size
  rm -f "$dest"
  [ -n "$base" ] && log "[ZS3] openstack image save via OS_IMAGE_URL=$base" || log "[ZS3] openstack image save via catalog default"
  set +e
  if [ -n "$base" ]; then
    OS_IMAGE_URL="$base" openstack image save --file "$dest" "$image_id" >"$tmp_log" 2>&1
  else
    openstack image save --file "$dest" "$image_id" >"$tmp_log" 2>&1
  fi
  rc=$?; set -e
  size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  if [ "$rc" -eq 0 ] && [ "$size" -ge "$min_bytes" ]; then
    log "[ZS3] HIT openstack image save downloaded $size bytes"; return 0
  fi
  log "[ZS3] WARN openstack image save failed rc=$rc size=${size}B"
  log_file_excerpt "[ZS3] save-error:" "$tmp_log"
  rm -f "$dest"; return 1
}
download_curl_glance() {
  local base="$1" image_id="$2" dest="$3" min_bytes="$4" token="$5" tmp_log="$6" url rc size project_header=()
  rm -f "$dest"
  url="${base}/v2/images/${image_id}/file"
  [ -n "$(ospc_tenant_id)" ] && project_header=(-H "X-Auth-Project-Id: $(ospc_tenant_id)")
  log "[ZS3] curl direct Glance download: $url"
  set +e
  curl -fSL --connect-timeout 30 --retry 2 --retry-delay 10 \
    --speed-time 180 --speed-limit 1024 \
    -H "X-Auth-Token: $token" "${project_header[@]}" \
    -H "Accept: application/octet-stream" -H "Expect:" \
    -A "ospc2flex-linsnap/1.0" -o "$dest" \
    --write-out "\nHTTP_CODE=%{http_code} SIZE=%{size_download}B TIME=%{time_total}s\n" \
    "$url" >"$tmp_log" 2>&1
  rc=$?; set -e
  size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  if [ "$rc" -eq 0 ] && [ "$size" -ge "$min_bytes" ]; then
    log "[ZS3] HIT curl downloaded $size bytes"; return 0
  fi
  log "[ZS3] WARN curl failed rc=$rc size=${size}B"
  log_file_excerpt "[ZS3] curl-error:" "$tmp_log"
  rm -f "$dest"; return 1
}
download_cloud_files_object() {
  local container="$1" object_name="$2" dest="$3" min_bytes="$4" tmp_log="$5" size
  rm -f "$dest"
  log "[ZS3] Cloud Files object download: $container/$object_name"
  if openstack object save "$container" "$object_name" --file "$dest" >"$tmp_log" 2>&1; then
    size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
    if [ "$size" -ge "$min_bytes" ]; then log "[ZS3] HIT Cloud Files downloaded $size bytes"; return 0; fi
  fi
  log "[ZS3] WARN Cloud Files download failed"
  log_file_excerpt "[ZS3] cloud-files-error:" "$tmp_log"
  rm -f "$dest"; return 1
}
download_cloud_files_export_task() {
  local image_id="$1" dest="$2" container="$3" min_bytes="$4"
  local object_name glance_base tasks_url payload token create_resp task_id task_json status elapsed start task_msg tmp_log project_header=()
  [ -n "$container" ] || container="ospc2flex-export"
  object_name="$(safe_object_name "${LABEL_SAFE}-${image_id}.vhd")"
  tmp_log="$JOB_LOG/cloud_files_object_save.log"
  log "[ZS3] Cloud Files export task → $container/$object_name"
  openstack container create "$container" >"$JOB_LOG/cf_container_create.log" 2>&1 || true
  download_cloud_files_object "$container" "$object_name" "$dest" "$min_bytes" "$tmp_log" && return 0
  local _uuid_vhd="${image_id}.vhd"
  if [ "$_uuid_vhd" != "$object_name" ]; then
    log "[ZS3] Checking UUID-based CF object: $container/$_uuid_vhd"
    download_cloud_files_object "$container" "$_uuid_vhd" "$dest" "$min_bytes" "$tmp_log" && return 0
  fi
  glance_base="$(first_resolvable_image_base || true)"
  [ -n "$glance_base" ] || return 1
  tasks_url="${glance_base}/v2/tasks"
  payload="$(IMAGE_ID="$image_id" CF_CONTAINER="$container" CF_OBJECT="$object_name" python3 - <<'PY'
import json, os
print(json.dumps({"type":"export","input":{"image_uuid":os.environ["IMAGE_ID"],"receiving_swift_container":os.environ["CF_CONTAINER"],"image_name":os.environ["CF_OBJECT"]}},separators=(",",":")))
PY
)"
  token="$(refresh_ospc_token || true)"
  [ -n "$token" ] || return 1
  [ -n "$(ospc_tenant_id)" ] && project_header=(-H "X-Auth-Project-Id: $(ospc_tenant_id)")
  create_resp="$(curl -sS -X POST "$tasks_url" -H "X-Auth-Token: $token" "${project_header[@]}" -H "Content-Type: application/json" -d "$payload" 2>"$JOB_LOG/cf_task_create.err" || true)"
  task_id="$(printf '%s' "$create_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
  [ -n "$task_id" ] || { log "[ZS3] WARN Cloud Files task create failed: ${create_resp:0:300}"; return 1; }
  log "[ZS3] Cloud Files export task: $task_id"
  start="$(date +%s)"
  while true; do
    elapsed=$(( $(date +%s) - start ))
    [ "$elapsed" -gt "$CLOUD_FILES_EXPORT_TIMEOUT" ] && { log "[ZS3] WARN Cloud Files export timed out after ${elapsed}s"; return 1; }
    token="$(refresh_ospc_token || printf '%s' "$token")"
    task_json="$(curl -sS "$tasks_url/$task_id" -H "X-Auth-Token: $token" "${project_header[@]}" 2>/dev/null || true)"
    status="$(printf '%s' "$task_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","unknown"))' 2>/dev/null || echo unknown)"
    log "[ZS3] CF task status=$status elapsed=${elapsed}s"
    case "$status" in
      success) break ;;
      failure|error)
        task_msg="$(printf '%s' "$task_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("message") or d.get("result") or "")' 2>/dev/null || true)"
        log "[ZS3] WARN CF task failed: ${task_msg:-<no message>}"
        if printf '%s' "$task_msg $task_json" | grep -qiE 'licensing|billing restrictions|cannot be exported|com\.rackspace__1__options'; then
          DOWNLOAD_FAILURE_REASON="OSPC_SNAPSHOT_EXPORT_BLOCKED_LICENSED"
          log "[ZS3] Licensed image — Cinder fallback"
          cinder_volume_raw_export "$image_id" "$dest" && return 0
          return 1
        fi
        if printf '%s' "$task_msg $task_json" | grep -qi 'Object already exists'; then
          _actual_obj="$(printf '%s' "$task_msg" | python3 -c '
import sys, re
blob = sys.stdin.read()
m = re.search(r"Container/Object:\s*[^/]+/(\S+?)[\s\"\x27}]", blob + " ")
print(m.group(1) if m else "")
' 2>/dev/null || true)"
          log "[ZS3] Object-already-exists: actual_obj='${_actual_obj:-<empty>}'"
          if [ -n "$_actual_obj" ] && [ "$_actual_obj" != "$object_name" ]; then
            log "[ZS3] Trying CF object from error: $container/$_actual_obj"
            download_cloud_files_object "$container" "$_actual_obj" "$dest" "$min_bytes" "$tmp_log" && return 0
          fi
          _uuid_vhd="${image_id}.vhd"
          if [ "$_uuid_vhd" != "$object_name" ]; then
            log "[ZS3] Trying UUID-based CF object: $container/$_uuid_vhd"
            download_cloud_files_object "$container" "$_uuid_vhd" "$dest" "$min_bytes" "$tmp_log" && return 0
          fi
          download_cloud_files_object "$container" "$object_name" "$dest" "$min_bytes" "$tmp_log" && return 0
        fi
        return 1 ;;
      *) sleep 15 ;;
    esac
  done
  download_cloud_files_object "$container" "$object_name" "$dest" "$min_bytes" "$tmp_log" && return 0
  local _uuid_vhd="${image_id}.vhd"
  if [ "$_uuid_vhd" != "$object_name" ]; then
    log "[ZS3] Trying UUID-based CF object after task success: $container/$_uuid_vhd"
    download_cloud_files_object "$container" "$_uuid_vhd" "$dest" "$min_bytes" "$tmp_log" && return 0
  fi
  return 1
}

# ── Cinder helpers (for licensed images — copied from Method Z) ───────────────
rackspace_region_lc() { printf '%s' "${OS_REGION_NAME:-IAD}" | tr '[:upper:]' '[:lower:]' | tr -d '0-9'; }
rackspace_tenant_id() { printf '%s' "${OS_TENANT_ID:-${OS_PROJECT_ID:-${OS_TENANT_NAME:-${OS_PROJECT_NAME:-}}}}"; }
rackspace_blockstorage_base() {
  local r t; r="$(rackspace_region_lc)"; t="$(rackspace_tenant_id)"
  [ -n "$t" ] || return 1
  printf 'https://%s.blockstorage.api.rackspacecloud.com/v1/%s' "$r" "$t"
}
rackspace_compute_base() {
  local r t; r="$(rackspace_region_lc)"; t="$(rackspace_tenant_id)"
  [ -n "$t" ] || return 1
  printf 'https://%s.servers.api.rackspacecloud.com/v2/%s' "$r" "$t"
}
rackspace_volume_status() {
  local vol_id="$1" token base resp
  token="$(refresh_ospc_token || true)"; base="$(rackspace_blockstorage_base)"
  [ -n "$token" ] && [ -n "$base" ] || return 1
  resp="$(curl -sS "$base/volumes/$vol_id" -H "X-Auth-Token: $token" 2>/dev/null || true)"
  printf '%s' "$resp" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("volume") or {}).get("status","unknown"))' 2>/dev/null || echo unknown
}
cinder_wait_volume_status() {
  local vol_id="$1" want="$2" timeout="${3:-1800}" waited=0 status
  while [ "$waited" -lt "$timeout" ]; do
    status="$(rackspace_volume_status "$vol_id" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '\r' || echo unknown)"
    [ "$status" = "$want" ] && return 0
    [ "$status" = "error" ] && return 1
    [ $((waited % 60)) -eq 0 ] && log "[CINDER] vol=$vol_id status=$status target=$want waited=${waited}s"
    sleep 10; waited=$((waited + 10))
  done
  return 1
}
local_block_disks() {
  sudo lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 !~ /^\/dev\/(nbd|loop|sr|fd)/ {print $1}' | sort
}
find_new_block_disk() {
  comm -13 "$1" "$2" | while IFS= read -r c; do [ -b "$c" ] && printf '%s\n' "$c" && break; done | head -1
}
rackspace_create_volume_from_image() {
  local image_id="$1" size_gb="$2" vol_name="$3" token base payload resp http body
  token="$(refresh_ospc_token || true)"; base="$(rackspace_blockstorage_base)"
  [ -n "$token" ] && [ -n "$base" ] || return 1
  payload="$(IMAGE_ID="$image_id" SIZE_GB="$size_gb" VNAME="$vol_name" python3 - <<'PY'
import json,os; print(json.dumps({"volume":{"display_name":os.environ["VNAME"],"size":int(os.environ["SIZE_GB"]),"imageRef":os.environ["IMAGE_ID"]}},separators=(",",":")))
PY
)"
  resp="$(curl -sS -w '\nHTTP_CODE=%{http_code}\n' -X POST "$base/volumes" -H "X-Auth-Token: $token" -H "Content-Type: application/json" -d "$payload" 2>>"$JOB_LOG/cinder.log" || true)"
  http="$(printf '%s' "$resp" | awk -F= '/HTTP_CODE=/{print $2}' | tail -1)"
  body="$(printf '%s' "$resp" | sed '/^HTTP_CODE=/d')"
  case "$http" in 200|202) ;; *) log "[CINDER] WARN volume create HTTP=$http"; return 1 ;; esac
  printf '%s' "$body" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("volume") or {}).get("id",""))' 2>/dev/null
}
rackspace_attach_volume() {
  local server_id="$1" vol_id="$2" token base payload resp http
  token="$(refresh_ospc_token || true)"; base="$(rackspace_compute_base)"
  [ -n "$token" ] && [ -n "$base" ] || return 1
  payload="$(VOL_ID="$vol_id" python3 - <<'PY'
import json,os; print(json.dumps({"volumeAttachment":{"volumeId":os.environ["VOL_ID"]}},separators=(",",":")))
PY
)"
  resp="$(curl -sS -w '\nHTTP_CODE=%{http_code}\n' -X POST "$base/servers/$server_id/os-volume_attachments" -H "X-Auth-Token: $token" -H "Content-Type: application/json" -d "$payload" 2>>"$JOB_LOG/cinder.log" || true)"
  http="$(printf '%s' "$resp" | awk -F= '/HTTP_CODE=/{print $2}' | tail -1)"
  case "$http" in 200|202) return 0 ;; esac
  log "[CINDER] WARN volume attach HTTP=$http"; return 1
}
rackspace_detach_volume() {
  local server_id="$1" vol_id="$2" token base
  token="$(refresh_ospc_token || true)"; base="$(rackspace_compute_base)"
  [ -n "$server_id" ] && [ -n "$vol_id" ] && [ -n "$token" ] && [ -n "$base" ] || return 0
  curl -sS -X DELETE "$base/servers/$server_id/os-volume_attachments/$vol_id" -H "X-Auth-Token: $token" -o /dev/null >>"$JOB_LOG/cinder.log" 2>&1 || true
}
rackspace_delete_volume() {
  local vol_id="$1" token base
  token="$(refresh_ospc_token || true)"; base="$(rackspace_blockstorage_base)"
  [ -n "$vol_id" ] && [ -n "$token" ] && [ -n "$base" ] || return 0
  curl -sS -X DELETE "$base/volumes/$vol_id" -H "X-Auth-Token: $token" -o /dev/null >>"$JOB_LOG/cinder.log" 2>&1 || true
}
discover_ospc_helper_server_id() {
  hostname 2>/dev/null | head -1 >&2
  local ips_json server_json
  ips_json="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk 'NF' | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  server_json="$(openstack server list --long -f json 2>/dev/null || true)"
  LOCAL_IPS_JSON="$ips_json" SERVER_JSON="$server_json" python3 - <<'PY' 2>/dev/null || true
import json, os
try: rows = json.loads(os.environ.get("SERVER_JSON") or "[]")
except Exception: rows = []
try: ips = json.loads(os.environ.get("LOCAL_IPS_JSON") or "[]")
except Exception: ips = []
for row in rows:
    blob = json.dumps(row).lower()
    if any(ip and ip.lower() in blob for ip in ips):
        print(row.get("ID") or row.get("Id") or row.get("id") or ""); raise SystemExit
PY
}
image_cinder_size_gb() {
  local image_id="$1" meta="$JOB_TMP/cinder_img_meta.json"
  openstack image show "$image_id" -f json >"$meta"
  python3 - "$meta" <<'PY'
import json, math, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
size = int(d.get("size") or 0); min_disk = int(d.get("min_disk") or 0); virtual = int(d.get("virtual_size") or 0)
gb = max(1, min_disk, math.ceil(size/(1024**3)), math.ceil(virtual/(1024**3)) if virtual else 0)
print(max(gb, int(os.environ.get("CINDER_MIN_VOLUME_SIZE_GB","75")) if False else gb))
PY
}
image_is_licensed_cinder_only() {
  local image_id="$1" meta="$JOB_TMP/img_meta_export.json"
  openstack image show "$image_id" -f json >"$meta" 2>/dev/null || return 1
  python3 - "$meta" <<'PY'
import json, sys
try: d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception: print("0"); raise SystemExit
props = d.get("properties") or {}
flag = str(props.get("com.rackspace__1__options","")).strip() if isinstance(props,dict) else ""
if not flag: flag = str(d.get("com.rackspace__1__options","")).strip()
print("1" if flag == "4" else "0")
PY
}
cinder_volume_raw_export() {
  local image_id="$1" dest="$2"
  local helper_id volume_name volume_id before_file after_file dev dev_size dd_rc
  helper_id="$(discover_ospc_helper_server_id | head -1 | tr -d '[:space:]')"
  [ -n "$helper_id" ] || return 1
  local size_gb; size_gb="$(image_cinder_size_gb "$image_id")"
  [ "$size_gb" -lt "$CINDER_MIN_VOLUME_SIZE_GB" ] && size_gb="$CINDER_MIN_VOLUME_SIZE_GB"
  volume_name="${LABEL_SAFE}-linsnap-cinder-${RUN_ID}"
  before_file="$JOB_TMP/cinder_before.txt"; after_file="$JOB_TMP/cinder_after.txt"
  log "[CINDER] Licensed image — Cinder attach fallback: helper=$helper_id size=${size_gb}GB"
  local_block_disks >"$before_file"
  volume_id="$(rackspace_create_volume_from_image "$image_id" "$size_gb" "$volume_name" | tr -d '\r' | tail -1)"
  [ -n "$volume_id" ] || return 1
  log "[CINDER] volume=$volume_id — waiting available"
  cinder_wait_volume_status "$volume_id" "available" 7200 || return 1
  rackspace_attach_volume "$helper_id" "$volume_id" || return 1
  cinder_wait_volume_status "$volume_id" "in-use" 900 || return 1
  dev=""
  for _i in $(seq 1 60); do sleep 3; local_block_disks >"$after_file"; dev="$(find_new_block_disk "$before_file" "$after_file" || true)"; [ -n "$dev" ] && break; done
  [ -n "$dev" ] || return 1
  dev_size="$(sudo blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
  log "[CINDER] attached block device: $dev bytes=$dev_size"
  [ "$dev_size" -gt 1073741824 ] || return 1
  rm -f "$dest"
  log "[CINDER] raw-copying $dev → $dest"
  set +e; sudo dd if="$dev" of="$dest" bs=64M status=progress conv=noerror,sync >>"$JOB_LOG/cinder.log" 2>&1; dd_rc=$?; set -e
  [ "$dd_rc" -eq 0 ] || return 1
  sudo chown "$(id -u):$(id -g)" "$dest" 2>/dev/null || true
  log "[CINDER] HIT raw artifact: $dest ($(stat -c%s "$dest" 2>/dev/null || echo 0) bytes)"
  rackspace_detach_volume "$helper_id" "$volume_id"
  cinder_wait_volume_status "$volume_id" "available" 900 || true
  rackspace_delete_volume "$volume_id"
  return 0
}

download_existing_ospc_snapshot() {
  local image_id="$1" dest="$2" min_bytes=1073741824 tmp_log token attempt base host base_i direct_blocked=0
  log "[ZS3] Download waterfall for image=$image_id"
  if [ "$CINDER_VOLUME_EXPORT_ON_LICENSED" = "1" ] && [ "$(image_is_licensed_cinder_only "$image_id" || echo 0)" = "1" ]; then
    log "[ZS3] Licensed image — prioritizing Cinder fallback"
    cinder_volume_raw_export "$image_id" "$dest" && return 0
    return 1
  fi
  log "[ZS3] Glance endpoints:"; image_bases | sed 's/^/  - /' | while IFS= read -r l; do log "$l"; done
  token="$(refresh_ospc_token || true)"
  attempt=1
  while [ "$attempt" -le "$EXPORT_RETRIES" ]; do
    log "[ZS3] Direct Glance attempt $attempt/$EXPORT_RETRIES"
    tmp_log="$JOB_LOG/image_save_default_a${attempt}.log"
    download_openstack_save "" "$image_id" "$dest" "$min_bytes" "$tmp_log" && return 0
    is_terminal_direct_download_block "$tmp_log" && { direct_blocked=1; log "[ZS3] terminal block — skipping direct retries"; break; }
    base_i=0
    while IFS= read -r base; do
      [ -n "$base" ] || continue; base_i=$((base_i+1))
      host="$(url_host "$base")"
      host_resolves "$host" || { log "[ZS3] WARN unresolved host: $host"; continue; }
      tmp_log="$JOB_LOG/image_save_a${attempt}_b${base_i}.log"
      download_openstack_save "$base" "$image_id" "$dest" "$min_bytes" "$tmp_log" && return 0
      is_terminal_direct_download_block "$tmp_log" && { direct_blocked=1; break; }
      token="$(refresh_ospc_token || printf '%s' "$token")"
      if [ -n "$token" ]; then
        tmp_log="$JOB_LOG/curl_a${attempt}_b${base_i}.log"
        download_curl_glance "$base" "$image_id" "$dest" "$min_bytes" "$token" "$tmp_log" && return 0
        is_terminal_direct_download_block "$tmp_log" && { direct_blocked=1; break; }
      fi
    done < <(image_bases)
    [ "$direct_blocked" = "1" ] && break
    [ "$attempt" -lt "$EXPORT_RETRIES" ] && sleep "$EXPORT_RETRY_WAIT"
    token="$(refresh_ospc_token || printf '%s' "$token")"
    attempt=$((attempt+1))
  done
  set +e; download_cloud_files_export_task "$image_id" "$dest" "ospc2flex-export" "$min_bytes"; local cf_rc=$?; set -e
  [ "$cf_rc" -eq 0 ] && return 0
  log "[ZS3] CF export failed — trying Cinder volume fallback"
  cinder_volume_raw_export "$image_id" "$dest" && return 0
  return 1
}

# ── Resume: find existing qcow2 across all run dirs ───────────────────────────
find_resume_qcow2() {
  find "$BASE_DIR/runs/$LABEL_SAFE" -type f -name "*.qcow2" -size +64k -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | awk '{$1=""; sub(/^ /,""); print; exit}'
}

# ── FLEX helpers (mig_worker_v4 verbatim) ────────────────────────────────────
detect_virtual_size_bytes() {
  command -v qemu-img >/dev/null 2>&1 || { echo 0; return 0; }
  qemu-img info --output json "$1" 2>/dev/null | python3 -c 'import json,sys; print(int(json.load(sys.stdin).get("virtual-size") or 0))' 2>/dev/null || echo 0
}
infer_image_os_family() {
  case "${OS_TYPE,,}" in win*|windows*) echo "windows" ;; *) echo "linux" ;; esac
}
infer_image_os_distro() {
  case "${OS_TYPE,,}" in
    ubuntu24*|ubuntu22*|ubuntu20*|ubuntu*) echo "ubuntu" ;;
    debian*) echo "debian" ;;
    rocky*) echo "rocky" ;;
    alma*|almalinux*) echo "almalinux" ;;
    centos*) echo "centos" ;;
    rhel*|redhat*) echo "rhel" ;;
    *) echo "" ;;
  esac
}
normalize_int() { printf '%s' "${1:-}" | tr -cd '0-9'; }
resolve_target_flavor() {
  local req="$1"
  [ -n "$req" ] && openstack flavor show "$req" >/dev/null 2>&1 && { echo "$req"; return 0; }
  local rows _rows_fit _best _fallback _chosen _cid _cname _cram _cdisk _cvcpu
  rows="$(openstack flavor list --long --format value -c ID -c Name -c RAM -c Disk -c VCPUs 2>/dev/null || true)"
  [ -z "$rows" ] && { echo "$req"; return 0; }
  _rows_fit="$(printf '%s\n' "$rows" | awk 'NF>=5 && ($4+0) > 0')"
  [ -n "$_rows_fit" ] && rows="$_rows_fit"
  _fallback="$(printf '%s\n' "$rows" | awk 'NF>=5{id=$1;name=$2;ram=$3+0;disk=$4+0;vcpu=$5+0;score=(vcpu*1000000000)+(ram*1000000)+disk;if(!seen||score<best){seen=1;best=score;out=id"|"name}}END{if(seen)print out}')"
  _chosen="${_fallback}"; _cid="$(echo "$_chosen" | cut -d'|' -f1)"; _cname="$(echo "$_chosen" | cut -d'|' -f2)"
  [ -n "$_cid" ] && { echo "  Flavor auto-pick: $_cid ($_cname)" >&2; echo "$_cid"; return 0; }
  echo "$req"
}
resolve_target_network() {
  local req="$1"
  [ -n "$req" ] && openstack network show "$req" >/dev/null 2>&1 && { echo "$req"; return 0; }
  local pick
  pick="$(openstack network list --format value -c ID -c Name 2>/dev/null | awk 'tolower($2)~/(private|tenant|internal)/{print $1;exit}')"
  [ -z "$pick" ] && pick="$(openstack network list --format value -c ID 2>/dev/null | awk 'NF>=1{print $1;exit}')"
  [ -n "$pick" ] && { echo "  Network auto-pick: $pick" >&2; echo "$pick"; return 0; }
  echo "$req"
}
resolve_target_keypair() {
  local req="$1"
  [ -n "$req" ] && openstack keypair show "$req" >/dev/null 2>&1 && { echo "$req"; return 0; }
  local pick
  pick="$(openstack keypair list --format value -c Name 2>/dev/null | awk 'NF>=1{print $1;exit}')"
  [ -n "$pick" ] && { echo "  Keypair auto-pick: $pick" >&2; echo "$pick"; return 0; }
  echo ""
}

# ════════════════════════════════════════════════════════════════════════════
# ── MAIN PIPELINE ────────────────────────────────────────────────────────────
# ════════════════════════════════════════════════════════════════════════════

stage "LS0_PREFLIGHT"
log "label=$LABEL_SAFE run_id=$RUN_ID"
log "ospc_openrc=$OSPC_OPENRC flex_openrc=$FLEX_OPENRC"
log "os_type=${OS_TYPE:-auto} flex_user=$FLEX_USER"
log "base_dir=$BASE_DIR"
install_if_missing qemu-img qemu-nbd python3 openstack curl

stage "LS1_LOAD_CREDENTIALS"
source_ospc_openrc
log "OSPC region=${OS_REGION_NAME:-?} user=${OS_USERNAME:-?} tenant=$(ospc_tenant_id)"
log "LS1 OK"

stage "LS2_SELECT_SNAPSHOT"
if [ -z "$OSPC_IMAGE_ID" ]; then
  log "Looking up image by name: $LABEL"
  OSPC_IMAGE_ID="$(openstack image show "$LABEL" -f value -c id 2>/dev/null | tr -d '\r' | head -1 || true)"
  [ -n "$OSPC_IMAGE_ID" ] || fail_exit "LS2_SELECT_SNAPSHOT" "Could not find OSPC image '$LABEL' — pass --ospc-image-id explicitly"
fi
log "OSPC image ID: $OSPC_IMAGE_ID"

# ── LS3: Resume check + Download ─────────────────────────────────────────────
stage "LS3_DOWNLOAD_SNAPSHOT"
RESUME_QCOW="$(find_resume_qcow2 || true)"
if [ -n "$RESUME_QCOW" ] && [ -f "$RESUME_QCOW" ]; then
  sz="$(stat -c%s "$RESUME_QCOW" 2>/dev/null || echo 0)"
  log "[LS3] HIT resume artifact found: $RESUME_QCOW ($sz bytes) — skipping download"
  QCOW="$RESUME_QCOW"
  REPAIR_MARKER="${QCOW}.linux_repaired"
  REPAIR_LOG="${QCOW%.qcow2}.repair.log"
else
  RESUME_RAW="$(find "$BASE_DIR/runs/$LABEL_SAFE" -type f -name "source_snapshot.img" -size +1G -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{$1=""; sub(/^ /,""); print; exit}')"
  if [ -n "$RESUME_RAW" ] && [ -f "$RESUME_RAW" ]; then
    log "[LS3] HIT resume raw img found: $RESUME_RAW — skipping download"
    SOURCE_RAW="$RESUME_RAW"
  else
    log "[LS3] No valid resume artifact — downloading from OSPC"
    SOURCE_RAW="$JOB_ART/source_snapshot.img"
    download_existing_ospc_snapshot "$OSPC_IMAGE_ID" "$SOURCE_RAW" \
      || fail_exit "LS3_DOWNLOAD_SNAPSHOT" "All download strategies failed. Check $JOB_LOG for details."
  fi
  sz="$(stat -c%s "$SOURCE_RAW" 2>/dev/null || echo 0)"
  log "[LS3] HIT downloaded: $SOURCE_RAW ($sz bytes)"
fi

# ── LS4: Normalize to qcow2 ──────────────────────────────────────────────────
stage "LS4_NORMALIZE_QCOW2"
if [ -f "$QCOW" ] && [ "$(stat -c%s "$QCOW" 2>/dev/null || echo 0)" -gt 65536 ]; then
  log "[LS4] qcow2 already present: $QCOW — skipping convert"
else
  SOURCE_RAW="${SOURCE_RAW:-$JOB_ART/source_snapshot.img}"
  FMT="$(qemu-img info --output=json "$SOURCE_RAW" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("format","raw"))' 2>/dev/null || echo raw)"
  log "[LS4] Converting $SOURCE_RAW (format=$FMT) → $QCOW"
  rm -f "$QCOW"
  qemu-img convert -p -f "$FMT" -O qcow2 -c "$SOURCE_RAW" "$QCOW" 2>&1 | tee -a "$BACKGROUND_LOG" || fail_exit "LS4_NORMALIZE_QCOW2" "qemu-img convert failed — check disk space"
  sz="$(stat -c%s "$QCOW" 2>/dev/null || echo 0)"
  log "[LS4] HIT qcow2: $QCOW ($sz bytes)"
fi
[ -f "$QCOW" ] || fail_exit "LS4_NORMALIZE_QCOW2" "qcow2 not found after normalize step"

[ "$DOWNLOAD_ONLY" = "1" ] && { log "DOWNLOAD_ONLY=1 — stopping after LS4"; exit 0; }

# ── LS5: Offline repair (mig_worker_v4 Step 4 — verbatim) ────────────────────
stage "LS5_OFFLINE_REPAIR"
REPAIR_SCRIPT=/tmp/ospc2flex_offline_repair.sh
if [ -f "$REPAIR_MARKER" ]; then
  log "[LS5] Repair marker found: $REPAIR_MARKER — skipping repair (resume)"
else
  if [ -f "$REPAIR_SCRIPT" ]; then
    if [ -z "${OS_TYPE:-}" ]; then
      log "[LS5] WARN OS_TYPE not set — repair script will auto-detect"
    fi
    log "[LS5] Running: $REPAIR_SCRIPT --qcow2 $QCOW --os-type ${OS_TYPE:-} --nbd-dev $NBD_DEV --force"
    rm -f "$REPAIR_LOG"
    # Force-umount any filesystems still on the NBD device (e.g. leftover from a previous session)
    for _mp in $(lsblk -npo MOUNTPOINT "$NBD_DEV" 2>/dev/null | awk 'NF'); do
      log "[LS5] Force-umounting leftover mount: $_mp"
      sudo umount -l "$_mp" 2>/dev/null || true
    done
    sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    sudo modprobe nbd max_part=8 2>/dev/null || true
    set +eo pipefail
    if [ -n "${OS_TYPE:-}" ]; then
      bash "$REPAIR_SCRIPT" --qcow2 "$QCOW" --os-type "$OS_TYPE" --nbd-dev "$NBD_DEV" --force 2>&1 | tee "$REPAIR_LOG"
    else
      bash "$REPAIR_SCRIPT" --qcow2 "$QCOW" --nbd-dev "$NBD_DEV" --force 2>&1 | tee "$REPAIR_LOG"
    fi
    REPAIR_EXIT="${PIPESTATUS[0]}"
    set -eo pipefail
    if [ "$REPAIR_EXIT" -eq 0 ]; then
      log "[LS5] ospc2flex_offline_repair.sh completed successfully"
    else
      log "[LS5] WARN repair exit=$REPAIR_EXIT — continuing (image may need manual fix)"
    fi
    # CentOS/RHEL LAN markers — warn-only, same relaxed approach as alma9
    case "${OS_TYPE,,}" in
      centos*|rhel7*|rhel6*)
        if [ -f "$REPAIR_LOG" ] \
           && grep -q "Wrote fresh ifcfg-eth0 (no HWADDR, ONBOOT=yes, DHCP, NM_CONTROLLED=no)" "$REPAIR_LOG" \
           && grep -q "Enabled network.service" "$REPAIR_LOG"; then
          log "[LS5] PASS — CentOS/RHEL LAN repair markers present"
        else
          log "[LS5] WARN [REPAIR-LAN-W5] CentOS/RHEL LAN repair markers not confirmed — continuing (alma9-style, no hard fail)"
        fi ;;
    esac
    sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
  else
    log "[LS5] WARN $REPAIR_SCRIPT not found — running minimal inline repair"
    sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    sudo modprobe nbd max_part=8 2>/dev/null || true
    sudo qemu-nbd --connect="$NBD_DEV" "$QCOW"; sleep 3
    ROOT_PART="$(sudo fdisk -l "$NBD_DEV" 2>/dev/null | awk '/Linux filesystem/{print $1; exit}')"
    [ -n "$ROOT_PART" ] || ROOT_PART="${NBD_DEV}p1"
    log "[LS5] minimal: root=$ROOT_PART"
    FS_TYPE="$(sudo blkid -o value -s TYPE "$ROOT_PART" 2>/dev/null || echo ext4)"
    [ "$FS_TYPE" = "xfs" ] && sudo xfs_repair -L "$ROOT_PART" >/dev/null 2>&1 || true \
      || sudo fsck -y -f "$ROOT_PART" >/dev/null 2>&1 || true
    MNT_TMP="/tmp/linsnap_mnt_$$"; sudo mkdir -p "$MNT_TMP"
    if sudo mount "$ROOT_PART" "$MNT_TMP" 2>/dev/null || sudo mount -o norecovery "$ROOT_PART" "$MNT_TMP" 2>/dev/null; then
      sudo test -f "$MNT_TMP/etc/fstab" && { sudo cp "$MNT_TMP/etc/fstab" "$MNT_TMP/etc/fstab.orig" 2>/dev/null || true; sudo sed -i '/^[[:space:]]*#/b;/^[[:space:]]*$/b;/LABEL=/b;/UUID=/b;/PARTUUID=/b;s/^/# [flex] /' "$MNT_TMP/etc/fstab"; } || true
      sudo rm -rf "$MNT_TMP/var/lib/cloud/instance" "$MNT_TMP/var/lib/cloud/instances/"* 2>/dev/null || true
      printf '' | sudo tee "$MNT_TMP/etc/machine-id" >/dev/null
      sudo rm -f "$MNT_TMP/var/lib/dbus/machine-id" "$MNT_TMP/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
      log "[LS5] minimal: fstab + cloud-init + machine-id cleaned"
      sudo umount "$MNT_TMP" 2>/dev/null || true
    fi
    sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    sudo rm -rf "$MNT_TMP"
  fi
  echo "LINUX_SNAP_REPAIR_VERSION=$REPAIR_VERSION" >"$REPAIR_MARKER"
  log "[LS5] Repair marker written: $REPAIR_MARKER"
fi

# ── LS6: Upload to FLEX Glance (mig_worker_v4 Step 5 — verbatim) ─────────────
stage "LS6_UPLOAD_FLEX"
source_flex_openrc
log "FLEX region=${OS_REGION_NAME:-?} user=${OS_USERNAME:-?}"
openstack token issue >/dev/null 2>&1 || fail_exit "LS6_UPLOAD_FLEX" "FLEX authentication failed"

QCOW_BYTES="$(stat -c%s "$QCOW" 2>/dev/null || echo 0)"
QCOW_MIB="$((QCOW_BYTES / 1024 / 1024))"
QCOW_VIRTUAL_BYTES="$(detect_virtual_size_bytes "$QCOW")"
QCOW_VIRTUAL_GIB=0
[ "$QCOW_VIRTUAL_BYTES" -gt 0 ] 2>/dev/null && QCOW_VIRTUAL_GIB=$(( (QCOW_VIRTUAL_BYTES + 1073741823) / 1073741824 ))
IMG_NAME="${LABEL_SAFE}-linsnap-flex"
IMG_OS_FAMILY="$(infer_image_os_family)"
IMG_OS_DISTRO="$(infer_image_os_distro)"
kv "Image name"    "$IMG_NAME"
kv "Source qcow2"  "$QCOW"
kv "File size"     "${QCOW_BYTES}B (${QCOW_MIB} MiB)"
kv "Virtual size"  "~${QCOW_VIRTUAL_GIB} GiB"
kv "os_family"     "$IMG_OS_FAMILY / distro=${IMG_OS_DISTRO:-unset}"

IMAGE_CREATE_ARGS=(
  --disk-format qcow2 --container-format bare --file "$QCOW" --private
  --property "architecture=x86_64"
  --property "vm_mode=hvm"
  --property "os_type=$IMG_OS_FAMILY"
  --property "hw_disk_bus=virtio"
  --property "hw_vif_model=virtio"
  --property "hw_qemu_guest_agent=yes"
)
[ -n "$IMG_OS_DISTRO" ] && IMAGE_CREATE_ARGS+=(--property "os_distro=$IMG_OS_DISTRO")

NEW_ID=""
for _up_try in 1 2 3; do
  log "  [UPLOAD $_up_try/3] starting..."
  NEW_ID="$(openstack image create --format value -c id "${IMAGE_CREATE_ARGS[@]}" "$IMG_NAME" 2>>"$BACKGROUND_LOG" || true)"
  [ -n "$NEW_ID" ] && { log "  [UPLOAD $_up_try/3] image id: $NEW_ID"; break; }
  log "  [WARN] upload attempt $_up_try failed"
  [ "$_up_try" -lt 3 ] && sleep 20
done
[ -n "$NEW_ID" ] || fail_exit "LS6_UPLOAD_FLEX" "Upload failed after 3 attempts"
for _poll in $(seq 1 60); do
  ST="$(openstack image show "$NEW_ID" -f value -c status 2>/dev/null || echo "")"
  [ "$ST" = "active" ] && break
  [ "$ST" = "killed" ] && fail_exit "LS6_UPLOAD_FLEX" "Image $NEW_ID killed by Glance"
  log "  [UPLOAD_POLL $_poll/60] status=${ST:-unknown}"; sleep 20
done
[ "$ST" = "active" ] || fail_exit "LS6_UPLOAD_FLEX" "Image $NEW_ID never reached active (status=$ST)"
log "[LS6] HIT image active: $NEW_ID"

# ── LS6A: Volume-snapshot only — fix Glance virtual_size + create FLEX Cinder volume ──
if printf '%s' "${OSPC_IMAGE_ID:-}" | grep -q '^volsnap-'; then
  stage "LS6A_CREATE_FLEX_CINDER_VOLUME"

  # Fix Glance virtual_size metadata to match the actual qcow2 virtual size from
  # qemu-img. Without this, Cinder rejects volume creation if virtual_size in
  # Glance doesn't match the requested volume size.
  if [ "${QCOW_VIRTUAL_BYTES:-0}" -gt 0 ] 2>/dev/null; then
    log "[LS6A] Setting Glance virtual_size=${QCOW_VIRTUAL_BYTES}B on image $NEW_ID"
    openstack image set --property "virtual_size=${QCOW_VIRTUAL_BYTES}" "$NEW_ID" \
      2>>"$BACKGROUND_LOG" || log "[LS6A] WARN: image set virtual_size failed (non-fatal)"
  fi

  FLEX_VOL_SIZE_GB="${QCOW_VIRTUAL_GIB:-0}"
  [ "${FLEX_VOL_SIZE_GB}" -gt 0 ] 2>/dev/null || FLEX_VOL_SIZE_GB=75
  FLEX_VOL_NAME="${LABEL_SAFE}-flex-vol-${RUN_ID}"
  kv "FLEX volume name"    "$FLEX_VOL_NAME"
  kv "FLEX volume size GB" "$FLEX_VOL_SIZE_GB"
  kv "Source image"        "$NEW_ID"

  FLEX_VOL_ID="$(openstack volume create \
    --image "$NEW_ID" \
    --size  "$FLEX_VOL_SIZE_GB" \
    --format value -c id \
    "$FLEX_VOL_NAME" 2>>"$BACKGROUND_LOG" || true)"
  [ -n "$FLEX_VOL_ID" ] || fail_exit "LS6A_CREATE_FLEX_CINDER_VOLUME" \
    "openstack volume create failed — check $BACKGROUND_LOG"
  kv "FLEX volume ID" "$FLEX_VOL_ID"

  log "[LS6A] Waiting for volume $FLEX_VOL_ID to become available…"
  _VSTAT=""
  for _vp in $(seq 1 180); do
    _VSTAT="$(openstack volume show "$FLEX_VOL_ID" -f value -c status 2>/dev/null || echo "")"
    [ "$_VSTAT" = "available" ] && break
    [ "$_VSTAT" = "error" ] && fail_exit "LS6A_CREATE_FLEX_CINDER_VOLUME" \
      "Volume $FLEX_VOL_ID entered error state"
    [ $((_vp % 6)) -eq 0 ] && log "  [VOL_WAIT] $_vp/180 status=${_VSTAT:-unknown}"
    sleep 10
  done
  [ "$_VSTAT" = "available" ] || fail_exit "LS6A_CREATE_FLEX_CINDER_VOLUME" \
    "Volume $FLEX_VOL_ID never reached available after $(( 180 * 10 ))s (status=${_VSTAT})"
  log "[LS6A] HIT FLEX Cinder volume ready: $FLEX_VOL_ID (${FLEX_VOL_SIZE_GB}GB)"

  log "[LS6A] Volume snapshot migration complete. Skipping LS7 VM boot (not needed for data volumes)."
  log "[LS6A] Summary:"
  log "  FLEX Glance image  : $NEW_ID  ($IMG_NAME)"
  log "  FLEX Cinder volume : $FLEX_VOL_ID  ($FLEX_VOL_NAME, ${FLEX_VOL_SIZE_GB}GB)"
  exit 0
fi

# ── LS7: Boot FLEX VM (mig_worker_v4 Step 7 — verbatim) ──────────────────────
stage "LS7_BOOT_FLEX_VM"
DATE="$(date +%Y%m%d-%H%M)"
VMNAME="linsnap-${LABEL_SAFE}-${DATE}"
FLAVOR="$(resolve_target_flavor "$FLAVOR")"
NETWORK="$(resolve_target_network "$NETWORK")"
KEYPAIR="$(resolve_target_keypair "$KEYPAIR")"
kv "VM name"  "$VMNAME"
kv "Image"    "$NEW_ID"
kv "Flavor"   "$FLAVOR"
kv "Network"  "$NETWORK"
kv "Keypair"  "${KEYPAIR:-<none>}"

EXISTING="$(openstack server list --name "linsnap-${LABEL_SAFE}-" --format value -c ID 2>/dev/null || true)"
if [ -n "$EXISTING" ]; then
  while IFS= read -r _old_id; do
    [ -z "$_old_id" ] && continue
    log "  Deleting old test VM: $_old_id"
    timeout 300 openstack server delete "$_old_id" --wait >/dev/null 2>&1 || true
  done <<< "$EXISTING"
fi

if [ -n "$KEYPAIR" ]; then
  VM_ID="$(timeout 180 openstack server create --image "$NEW_ID" --flavor "$FLAVOR" --network "$NETWORK" --key-name "$KEYPAIR" --format value -c id "$VMNAME" 2>/tmp/srv_create_$$.err || true)"
else
  VM_ID="$(timeout 180 openstack server create --image "$NEW_ID" --flavor "$FLAVOR" --network "$NETWORK" --format value -c id "$VMNAME" 2>/tmp/srv_create_$$.err || true)"
fi
[ -n "$VM_ID" ] || fail_exit "LS7_BOOT_FLEX_VM" "Server create failed: $(tr '\n' ' ' </tmp/srv_create_$$.err 2>/dev/null | cut -c1-300)"
rm -f /tmp/srv_create_$$.err
kv "VM ID" "$VM_ID"

VM_ST=""
for _bp in $(seq 1 90); do
  VM_ST="$(openstack server show "$VM_ID" -f value -c status 2>/dev/null || echo "")"
  VM_TASK="$(openstack server show "$VM_ID" -f value -c "OS-EXT-STS:task_state" 2>/dev/null || true)"
  log "  [BOOT $_bp/90] status=${VM_ST:-?} task=${VM_TASK:-none}"
  [ "$VM_ST" = "ACTIVE" ] && break
  [ "$VM_ST" = "ERROR" ] && fail_exit "LS7_BOOT_FLEX_VM" "Server $VM_ID entered ERROR state"
  sleep 10
done
[ "$VM_ST" = "ACTIVE" ] || fail_exit "LS7_BOOT_FLEX_VM" "Server $VM_ID did not reach ACTIVE"
log "[LS7] HIT VM ACTIVE: $VM_ID"

# ── LS8: Floating IP ──────────────────────────────────────────────────────────
stage "LS8_FLOATING_IP"
_port_id=""
for _pw in $(seq 1 18); do
  _port_id="$(openstack port list --server "$VM_ID" --format value -c ID -c Status 2>/dev/null | awk '$2=="ACTIVE"{print $1; exit}')"
  [ -n "$_port_id" ] && break
  log "  [$_pw/18] waiting for port ACTIVE (10s)..."; sleep 10
done
[ -z "$_port_id" ] && _port_id="$(openstack port list --server "$VM_ID" --format value -c ID 2>/dev/null | head -1)"

REAL_FIP="NO_FIP"
if [ -n "$_port_id" ]; then
  for _fip_try in 1 2 3; do
    _fip_json="$(openstack floating ip create "$FLEX_EXT_NET" -f json 2>/tmp/fip_$$.err || true)"
    FIP_ID="$(printf '%s' "$_fip_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
    FIP="$(printf '%s' "$_fip_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("floating_ip_address",""))' 2>/dev/null || true)"
    if [ -z "$FIP_ID" ]; then
      _fip_row="$(openstack floating ip list --status DOWN --format value -c ID -c "Floating IP Address" 2>/dev/null | shuf | head -1 || true)"
      FIP_ID="$(echo "$_fip_row" | awk '{print $1}')"; FIP="$(echo "$_fip_row" | awk '{print $2}')"
    fi
    [ -z "$FIP_ID" ] && { log "  No FIP available (try $_fip_try)"; sleep 10; continue; }
    openstack floating ip set --port "$_port_id" "$FIP_ID" >/dev/null 2>&1 || true
    sleep 5
    _fip_fixed="$(openstack floating ip show "$FIP_ID" --format value -c fixed_ip_address 2>/dev/null || true)"
    if [ -n "$_fip_fixed" ] && [ "$_fip_fixed" != "None" ]; then
      REAL_FIP="$FIP"; log "  FIP attached: $REAL_FIP → $_fip_fixed"; break
    fi
    log "  FIP $FIP did not attach (try $_fip_try)"; sleep 15
  done
  rm -f /tmp/fip_$$.err
fi
[ "$REAL_FIP" = "NO_FIP" ] && log "  WARN: no floating IP attached — VM has private IP only"
kv "Floating IP" "$REAL_FIP"

# ── LS9: SSH test (mig_worker_v4 Step 9 — verbatim) ──────────────────────────
stage "LS9_SSH_TEST"
SSH_OK=0; SSH_ACTUAL_USER=""
if [ "$REAL_FIP" = "NO_FIP" ]; then
  log "  SSH test skipped — no floating IP"
else
  for i in $(seq 1 12); do
    log "  [SSH $i/12] trying ${FLEX_USER}@${REAL_FIP}"
    ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes \
        "${FLEX_USER}@${REAL_FIP}" 'echo ssh-ok' 2>/dev/null | grep -q ssh-ok \
      && { SSH_OK=1; SSH_ACTUAL_USER="$FLEX_USER"; break; }
    log "  [SSH $i/12] trying root@${REAL_FIP}"
    ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes \
        "root@${REAL_FIP}" 'echo ssh-ok' 2>/dev/null | grep -q ssh-ok \
      && { SSH_OK=1; SSH_ACTUAL_USER="root"; break; }
    log "  [SSH $i/12] not ready — retry in 10s"; sleep 10
  done
  if [ "$SSH_OK" -eq 1 ]; then
    log "=== SSH OK: ${SSH_ACTUAL_USER}@${REAL_FIP} ==="
  else
    log "=== SSH FAILED: ${FLEX_USER}@${REAL_FIP} and root@${REAL_FIP} did not respond ==="
  fi
fi

# ── Final report ──────────────────────────────────────────────────────────────
log "═══════════════════════════════════════════════════════"
log "MIGRATION COMPLETE"
log "  label        : $LABEL_SAFE"
log "  flex_image   : $NEW_ID ($IMG_NAME)"
log "  flex_vm      : $VM_ID ($VMNAME)"
log "  floating_ip  : $REAL_FIP"
log "  ssh_test     : $([ $SSH_OK -eq 1 ] && echo "PASS (${SSH_ACTUAL_USER}@${REAL_FIP})" || echo "FAIL (manual check needed)")"
log "  repair_log   : $REPAIR_LOG"
log "  background   : $BACKGROUND_LOG"
log "═══════════════════════════════════════════════════════"
echo "MIGRATION_COMPLETE=true"
echo "FLEX_IMAGE_ID=$NEW_ID"
echo "FLEX_VM_ID=$VM_ID"
echo "FLEX_FIP=$REAL_FIP"
echo "SSH_OK=$SSH_OK"
exit 0
