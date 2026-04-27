#!/usr/bin/env bash
set -euo pipefail

log() { echo "$@"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

_source_openrc() {
  local openrc="$1"
  [ -f "$openrc" ] || die "OpenRC not found: $openrc"
  set +u
  # shellcheck disable=SC1090
  source "$openrc"
  set -u
}

_region_short() {
  local r="${OS_REGION_NAME:-IAD}"
  r=$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]' | tr -d '0-9')
  [ -n "$r" ] || r="iad"
  printf '%s' "$r"
}

_normalize_glance_base() {
  printf '%s' "$1" | tr -d '[:space:]' | sed -E 's#/v2/?$##'
}

_url_host() {
  printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://([^/:]+).*$#\1#'
}

_host_resolves() {
  local h="$1"
  [ -n "$h" ] || return 1
  if printf '%s' "$h" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+$'; then
    return 0
  fi
  getent hosts "$h" >/dev/null 2>&1
}

_dedup_lines() {
  awk 'NF && !seen[$0]++'
}

_image_bases() {
  local region catalog_json
  region=$(_region_short)
  catalog_json=$(openstack catalog show image -f json 2>/dev/null || true)
  {
    if [ -n "$catalog_json" ]; then
      CATALOG_JSON="$catalog_json" python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    data = json.loads(os.environ.get("CATALOG_JSON", "{}"))
except Exception:
    data = {}
eps = data.get("endpoints") or []
for wanted in ("internal", "admin", "public"):
    for ep in eps:
        iface = str(ep.get("interface") or "").lower()
        if iface == wanted:
            url = ep.get("url") or ep.get("publicURL") or ep.get("internalURL") or ep.get("adminURL")
            if url:
                print(str(url).rstrip("/"))
PY
    fi
    openstack endpoint list --service image -f value -c URL 2>/dev/null || true
    printf 'https://snet-%s.images.api.rackspacecloud.com\n' "$region"
    printf 'https://%s.images.api.rackspacecloud.com\n' "$region"
  } | while IFS= read -r url; do
    [ -n "$url" ] || continue
    _normalize_glance_base "$url"
    printf '\n'
  done | _dedup_lines
}

_first_resolvable_image_base() {
  local b h fallback=""
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    [ -n "$fallback" ] || fallback="$b"
    h=$(_url_host "$b")
    if _host_resolves "$h"; then
      printf '%s' "$b"
      return 0
    fi
  done < <(_image_bases)
  [ -n "$fallback" ] || fallback="https://$(_region_short).images.api.rackspacecloud.com"
  printf '%s' "$fallback"
}

_catalog_service_url() {
  local service="$1" interface="${2:-public}"
  local catalog_json
  catalog_json=$(openstack catalog show "$service" -f json 2>/dev/null || true)
  [ -n "$catalog_json" ] || return 0
  CATALOG_JSON="$catalog_json" SERVICE_IFACE="$interface" python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    data = json.loads(os.environ.get("CATALOG_JSON", "{}"))
except Exception:
    data = {}
eps = data.get("endpoints") or []
wanted = os.environ.get("SERVICE_IFACE", "public").lower()
region = os.environ.get("OS_REGION_NAME", "").upper()
aliases = {"DFW3": "DFW", "IAD3": "IAD", "ORD3": "ORD"}
region = aliases.get(region, region)
best = ""
fallback = ""
for ep in eps:
    iface = str(ep.get("interface") or "").lower()
    url = ep.get("url") or ep.get("publicURL") or ep.get("internalURL") or ep.get("adminURL") or ""
    if not url:
        continue
    ep_region = str(ep.get("region") or "").upper()
    if iface == wanted:
        fallback = fallback or url.rstrip("/")
        if not region or ep_region == region:
            best = url.rstrip("/")
            break
print(best or fallback)
PY
}

_refresh_rax_token() {
  local token auth_url api_key auth_resp
  token=$(openstack token issue -f value -c id 2>/dev/null || true)
  if [ -n "$token" ]; then
    printf '%s' "$token"
    return 0
  fi
  api_key="${OS_API_KEY:-${OS_PASSWORD:-}}"
  [ -n "${OS_USERNAME:-}" ] && [ -n "$api_key" ] || return 1
  auth_url="${OS_AUTH_URL:-https://identity.api.rackspacecloud.com/v2.0/}"
  auth_url="${auth_url%/}/tokens"
  auth_resp=$(curl -sS -X POST "$auth_url" \
    -H "Content-Type: application/json" \
    -d "{\"auth\":{\"RAX-KSKEY:apiKeyCredentials\":{\"username\":\"$OS_USERNAME\",\"apiKey\":\"$api_key\"}}}" \
    2>/dev/null || true)
  printf '%s' "$auth_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access"]["token"]["id"])' 2>/dev/null
}

_valid_file() {
  local path="$1" min="$2" size
  size=$(stat -c%s "$path" 2>/dev/null || echo 0)
  [ "$size" -ge "$min" ]
}

_safe_object_name() {
  python3 - "$1" <<'PY'
import re, sys
name = sys.argv[1]
name = re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("._-")
print(name or "ospc2flex-image")
PY
}

_download_openstack_save() {
  local base="$1" image_id="$2" dest="$3" min_bytes="$4" log_file="$5" rc size
  rm -f "$dest"
  log "  [classic-glance] openstack image save via ${base:-catalog default}"
  set +e
  if [ -n "$base" ]; then
    OS_IMAGE_URL="$base" openstack image save --file "$dest" "$image_id" >"$log_file" 2>&1
  else
    openstack image save --file "$dest" "$image_id" >"$log_file" 2>&1
  fi
  rc=$?
  set -e
  size=$(stat -c%s "$dest" 2>/dev/null || echo 0)
  if [ "$rc" -eq 0 ] && [ "$size" -ge "$min_bytes" ]; then
    log "  [OK] openstack image save downloaded $size bytes"
    return 0
  fi
  warn "openstack image save failed rc=$rc size=${size}B; log=$log_file"
  grep -iE 'error|fail|invalid|413|forbidden|unauthorized|endpoint|resolve|timeout' "$log_file" 2>/dev/null | tail -8 >&2 || true
  return 1
}

_download_curl() {
  local base="$1" image_id="$2" dest="$3" min_bytes="$4" token="$5" log_file="$6" url rc size
  rm -f "$dest"
  url="${base}/v2/images/${image_id}/file"
  log "  [classic-glance] curl $url"
  set +e
  curl -fSL --connect-timeout 30 --retry 2 --retry-delay 10 \
    --speed-time 180 --speed-limit 1024 \
    -H "X-Auth-Token: $token" \
    -H "Accept: application/octet-stream" \
    -H "Expect:" \
    -A "ospc2flex-glance-bridge/1.0" \
    -o "$dest" \
    --write-out "\nHTTP_CODE=%{http_code} SIZE=%{size_download}B TIME=%{time_total}s\n" \
    "$url" >"$log_file" 2>&1
  rc=$?
  set -e
  size=$(stat -c%s "$dest" 2>/dev/null || echo 0)
  if [ "$rc" -eq 0 ] && [ "$size" -ge "$min_bytes" ]; then
    log "  [OK] curl downloaded $size bytes"
    return 0
  fi
  warn "curl failed rc=$rc size=${size}B; log=$log_file"
  tail -8 "$log_file" >&2 2>/dev/null || true
  if [ -s "$dest" ] && [ "$size" -lt 4096 ]; then
    warn "small error body:"
    head -c 768 "$dest" >&2 || true
    printf '\n' >&2
  fi
  return 1
}

_download_cloud_files_export_task() {
  local image_id="$1" dest="$2" container="$3" min_bytes="$4"
  local token object_name glance_base tasks_url payload create_resp task_id status task_json elapsed start rc size

  log "[INFO] Cloud Files primary path: Glance export task -> Cloud Files -> jumphost"
  log "[INFO] Source region from OpenRC: ${OS_REGION_NAME:-IAD}. Fastest when this jumphost is in the same OSPC region."

  object_name="$(_safe_object_name "${image_id}.vhd")"
  openstack container create "$container" >/tmp/ospc2flex_cf_container.log 2>&1 || true
  glance_base=$(_first_resolvable_image_base)
  tasks_url="${glance_base}/v2/tasks"
  payload=$(IMAGE_ID="$image_id" CF_CONTAINER="$container" CF_OBJECT="$object_name" python3 - <<'PY'
import json, os
print(json.dumps({
    "type": "export",
    "input": {
        "image_uuid": os.environ["IMAGE_ID"],
        "receiving_swift_container": os.environ["CF_CONTAINER"],
        "image_name": os.environ["CF_OBJECT"],
    },
}, separators=(",", ":")))
PY
)
  token=$(_refresh_rax_token || true)
  if [ -z "$token" ]; then
    warn "Could not refresh token before Cloud Files export task"
    return 1
  fi
  create_resp=$(curl -sS -X POST "$tasks_url" \
    -H "X-Auth-Token: $token" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/tmp/ospc2flex_cf_task_create.err || true)
  task_id=$(printf '%s' "$create_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
  if [ -z "$task_id" ]; then
    warn "Cloud Files export task create response: $create_resp"
    return 1
  fi
  log "[INFO] Cloud Files export task created: $task_id container=$container object=$object_name"

  start=$(date +%s)
  while true; do
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -gt 7200 ]; then
      warn "Cloud Files export task timed out after ${elapsed}s"
      return 1
    fi
    task_json=$(curl -sS "$tasks_url/$task_id" -H "X-Auth-Token: $token" 2>/dev/null || true)
    status=$(printf '%s' "$task_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","unknown"))' 2>/dev/null || echo unknown)
    log "[INFO] Cloud Files export task status=$status elapsed=${elapsed}s"
    case "$status" in
      success) break ;;
      failure|error)
        warn "$task_json"
        return 1
        ;;
      *)
        sleep 15
        ;;
    esac
    token=$(_refresh_rax_token || printf '%s' "$token")
  done

  rm -f "$dest"
  log "[INFO] Downloading Cloud Files object to jumphost: $container/$object_name"
  set +e
  openstack object save "$container" "$object_name" --file "$dest" >/tmp/ospc2flex_cf_object_save.log 2>&1
  rc=$?
  set -e
  size=$(stat -c%s "$dest" 2>/dev/null || echo 0)
  if [ "$rc" -ne 0 ] || [ "$size" -lt "$min_bytes" ]; then
    warn "openstack object save failed rc=$rc size=${size}B"
    tail -20 /tmp/ospc2flex_cf_object_save.log >&2 2>/dev/null || true
    return 1
  fi
  openstack object delete "$container" "$object_name" >/dev/null 2>&1 || true
  log "[OK] Cloud Files export downloaded $size bytes"
  return 0
}

download_cloud_files_export() {
  local openrc="" image_id="" dest="" container="ospc2flex-export" retries=4 retry_wait=15 min_bytes=1048576 prefer_cloud_files=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --ospc-openrc) openrc="$2"; shift 2 ;;
      --image-id) image_id="$2"; shift 2 ;;
      --dest) dest="$2"; shift 2 ;;
      --container) container="$2"; shift 2 ;;
      --prefer-cloud-files) prefer_cloud_files=1; shift ;;
      --retries) retries="$2"; shift 2 ;;
      --retry-wait) retry_wait="$2"; shift 2 ;;
      --min-bytes) min_bytes="$2"; shift 2 ;;
      *) die "download: unknown argument $1" ;;
    esac
  done
  [ -n "$openrc" ] && [ -n "$image_id" ] && [ -n "$dest" ] || die "download requires --ospc-openrc, --image-id and --dest"
  _source_openrc "$openrc"
  mkdir -p "$(dirname "$dest")"

  local token attempt base h log_file size
  token=$(_refresh_rax_token || true)
  [ -n "$token" ] || die "Could not obtain OSPC token"

  log "[INFO] Download waterfall: Classic Glance endpoint list"
  _image_bases | sed 's/^/  - /'

  if [ "$prefer_cloud_files" = "1" ]; then
    log "[INFO] Prefer Cloud Files mode enabled: starting with Glance export to Cloud Files"
    if _download_cloud_files_export_task "$image_id" "$dest" "$container" "$min_bytes"; then
      return 0
    fi
    warn "Cloud Files preferred path failed; falling back to direct Classic Glance methods"
  fi

  attempt=1
  while [ "$attempt" -le "$retries" ]; do
    log "[INFO] Classic Glance attempt $attempt/$retries"
    if _download_openstack_save "" "$image_id" "$dest" "$min_bytes" "/tmp/ospc2flex_osave_default_${image_id}_${attempt}.log"; then
      return 0
    fi
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      h=$(_url_host "$base")
      if ! _host_resolves "$h"; then
        warn "Glance host unresolved on this host: $h"
        continue
      fi
      log_file="/tmp/ospc2flex_glance_${image_id}_${attempt}_$(printf '%s' "$h" | tr -cd 'A-Za-z0-9._-').log"
      if _download_openstack_save "$base" "$image_id" "$dest" "$min_bytes" "$log_file"; then
        return 0
      fi
      token=$(_refresh_rax_token || printf '%s' "$token")
      if _download_curl "$base" "$image_id" "$dest" "$min_bytes" "$token" "$log_file.curl"; then
        return 0
      fi
    done < <(_image_bases)
    [ "$attempt" -lt "$retries" ] && sleep "$retry_wait"
    token=$(_refresh_rax_token || printf '%s' "$token")
    attempt=$((attempt + 1))
  done

  log "[INFO] Classic Glance download failed; starting Cloud Files export task fallback"
  if _download_cloud_files_export_task "$image_id" "$dest" "$container" "$min_bytes"; then
    return 0
  fi
  die "OSPC snapshot download failed: Cloud Files export and direct Glance methods exhausted"
}

_wait_flex_image_active() {
  local id="$1" timeout="${2:-1800}" start status elapsed
  start=$(date +%s)
  while true; do
    elapsed=$(( $(date +%s) - start ))
    status=$(openstack image show "$id" -f value -c status 2>/dev/null || echo unknown)
    log "[INFO] FLEX image $id status=$status elapsed=${elapsed}s"
    case "$status" in
      active) return 0 ;;
      killed|deleted|error) return 1 ;;
    esac
    [ "$elapsed" -lt "$timeout" ] || return 1
    sleep 10
  done
}

_direct_flex_upload() {
  local image_file="$1" image_name="$2" disk_format="$3" container_format="$4" visibility="$5" out rc id
  log "[INFO] Direct FLEX Glance upload via openstack image create"
  set +e
  out=$(openstack image create \
    --disk-format "$disk_format" \
    --container-format "$container_format" \
    --file "$image_file" \
    --property "visibility=$visibility" \
    --format value -c id \
    "$image_name" 2>&1)
  rc=$?
  set -e
  id=$(printf '%s\n' "$out" | awk '/^[0-9a-fA-F-]{32,36}$/ {print; exit}')
  if [ "$rc" -eq 0 ] && [ -n "$id" ] && _wait_flex_image_active "$id" 1800; then
    log "[OK] Direct FLEX Glance upload complete: $id"
    echo "FLEX_IMAGE_ID=$id"
    return 0
  fi
  warn "Direct FLEX Glance upload failed rc=$rc id=${id:-none}"
  printf '%s\n' "$out" | tail -20 >&2
  return 1
}

_temp_url() {
  local swift_url="$1" container="$2" object="$3" key="$4" expires="$5"
  python3 - "$swift_url" "$container" "$object" "$key" "$expires" <<'PY'
import hashlib, hmac, sys
from urllib.parse import urlsplit
swift_url, container, obj, key, expires = sys.argv[1:]
u = urlsplit(swift_url)
account_path = u.path.rstrip("/")
path = f"{account_path}/{container}/{obj}"
msg = f"GET\n{expires}\n{path}"
sig = hmac.new(key.encode(), msg.encode(), hashlib.sha1).hexdigest()
print(f"{u.scheme}://{u.netloc}{path}?temp_url_sig={sig}&temp_url_expires={expires}")
PY
}

_poll_glance_task() {
  local image_base="$1" token="$2" task_id="$3" timeout="$4" start elapsed task_json status image_id
  start=$(date +%s)
  while true; do
    elapsed=$(( $(date +%s) - start ))
    task_json=$(curl -sS "$image_base/v2/tasks/$task_id" -H "X-Auth-Token: $token" 2>/dev/null || true)
    status=$(printf '%s' "$task_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","unknown"))' 2>/dev/null || echo unknown)
    log "[INFO] FLEX import task $task_id status=$status elapsed=${elapsed}s"
    if [ "$status" = "success" ]; then
      image_id=$(printf '%s' "$task_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("result") or {}).get("image_id",""))' 2>/dev/null || true)
      [ -n "$image_id" ] && echo "FLEX_IMAGE_ID=$image_id"
      return 0
    fi
    if [ "$status" = "failure" ] || [ "$status" = "error" ]; then
      warn "$task_json"
      return 1
    fi
    [ "$elapsed" -lt "$timeout" ] || return 1
    sleep 10
  done
}

_cloud_files_flex_import() {
  local image_file="$1" image_name="$2" disk_format="$3" container_format="$4" visibility="$5" container="$6"
  local token swift_url image_base object size status key expires temp_url payload resp image_id import_status task_id
  token=$(_refresh_rax_token || true)
  [ -n "$token" ] || die "Could not obtain FLEX token for Cloud Files import"
  swift_url=$(_catalog_service_url object-store public)
  [ -n "$swift_url" ] || swift_url=$(_catalog_service_url object-store internal)
  [ -n "$swift_url" ] || die "Could not determine FLEX Cloud Files endpoint from catalog"
  image_base=$(_first_resolvable_image_base)
  object="$(_safe_object_name "${image_name}.${disk_format}")"
  size=$(stat -c%s "$image_file" 2>/dev/null || echo 0)

  log "[INFO] FLEX Cloud Files staging endpoint: $swift_url"
  log "[INFO] Staging $size bytes to Cloud Files: $container/$object"
  curl -sS -X PUT "$swift_url/$container" -H "X-Auth-Token: $token" -o /tmp/ospc2flex_flex_cf_container.out || true
  status=$(curl -sS --http1.1 -X PUT "$swift_url/$container/$object" \
    -H "X-Auth-Token: $token" \
    -H "Content-Type: application/octet-stream" \
    -H "Transfer-Encoding: chunked" \
    --data-binary @"$image_file" \
    --write-out "%{http_code}" -o /tmp/ospc2flex_flex_cf_upload.out 2>/tmp/ospc2flex_flex_cf_upload.err || echo 000)
  if [ "$status" != "201" ] && [ "$status" != "200" ]; then
    warn "Cloud Files upload HTTP=$status"
    head -c 800 /tmp/ospc2flex_flex_cf_upload.out >&2 2>/dev/null || true
    return 1
  fi

  key=$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)
  curl -sS -X POST "$swift_url" \
    -H "X-Auth-Token: $token" \
    -H "X-Account-Meta-Temp-URL-Key: $key" -o /tmp/ospc2flex_flex_cf_key.out || true
  expires=$(python3 - <<'PY'
import time
print(int(time.time()) + 21600)
PY
)
  temp_url=$(_temp_url "$swift_url" "$container" "$object" "$key" "$expires")
  log "[INFO] TempURL generated for Glance web-download import"

  log "[INFO] Trying Glance interoperable image import API"
  payload=$(IMAGE_NAME="$image_name" DISK_FORMAT="$disk_format" CONTAINER_FORMAT="$container_format" VISIBILITY="$visibility" python3 - <<'PY'
import json, os
print(json.dumps({
    "name": os.environ["IMAGE_NAME"],
    "disk_format": os.environ["DISK_FORMAT"],
    "container_format": os.environ["CONTAINER_FORMAT"],
    "visibility": os.environ["VISIBILITY"],
}, separators=(",", ":")))
PY
)
  resp=$(curl -sS -X POST "$image_base/v2/images" \
    -H "X-Auth-Token: $token" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/tmp/ospc2flex_flex_image_create.err || true)
  image_id=$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
  if [ -n "$image_id" ]; then
    payload=$(TEMP_URL="$temp_url" python3 - <<'PY'
import json, os
print(json.dumps({"method": {"name": "web-download", "uri": os.environ["TEMP_URL"]}}, separators=(",", ":")))
PY
)
    import_status=$(curl -sS -X POST "$image_base/v2/images/$image_id/import" \
      -H "X-Auth-Token: $token" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      --write-out "%{http_code}" -o /tmp/ospc2flex_flex_image_import.out 2>/tmp/ospc2flex_flex_image_import.err || echo 000)
    if [ "$import_status" = "202" ] || [ "$import_status" = "204" ] || [ "$import_status" = "200" ]; then
      if _wait_flex_image_active "$image_id" 3600; then
        openstack object delete "$container" "$object" >/dev/null 2>&1 || true
        echo "FLEX_IMAGE_ID=$image_id"
        return 0
      fi
    fi
    warn "Image import API did not complete (HTTP=$import_status); trying legacy task import"
    curl -sS -X DELETE "$image_base/v2/images/$image_id" -H "X-Auth-Token: $token" -o /dev/null || true
  else
    warn "Could not create queued Glance image for import; trying legacy task import"
  fi

  payload=$(IMAGE_NAME="$image_name" DISK_FORMAT="$disk_format" CONTAINER_FORMAT="$container_format" VISIBILITY="$visibility" TEMP_URL="$temp_url" python3 - <<'PY'
import json, os
print(json.dumps({
    "type": "import",
    "input": {
        "image_properties": {
            "name": os.environ["IMAGE_NAME"],
            "disk_format": os.environ["DISK_FORMAT"],
            "container_format": os.environ["CONTAINER_FORMAT"],
            "visibility": os.environ["VISIBILITY"],
        },
        "import_from": os.environ["TEMP_URL"],
        "import_from_format": os.environ["DISK_FORMAT"],
    },
}, separators=(",", ":")))
PY
)
  resp=$(curl -sS -X POST "$image_base/v2/tasks" \
    -H "X-Auth-Token: $token" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/tmp/ospc2flex_flex_task_import.err || true)
  task_id=$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
  if [ -z "$task_id" ]; then
    warn "Legacy import task response: $resp"
    openstack object delete "$container" "$object" >/dev/null 2>&1 || true
    return 1
  fi
  if _poll_glance_task "$image_base" "$token" "$task_id" 3600; then
    openstack object delete "$container" "$object" >/dev/null 2>&1 || true
    return 0
  fi
  openstack object delete "$container" "$object" >/dev/null 2>&1 || true
  return 1
}

upload_flex_image() {
  local openrc="" image_file="" image_name="" disk_format="qcow2" container_format="bare" visibility="private" container="ospc2flex-staging"
  while [ $# -gt 0 ]; do
    case "$1" in
      --flex-openrc) openrc="$2"; shift 2 ;;
      --image-file) image_file="$2"; shift 2 ;;
      --image-name) image_name="$2"; shift 2 ;;
      --disk-format) disk_format="$2"; shift 2 ;;
      --container-format) container_format="$2"; shift 2 ;;
      --visibility) visibility="$2"; shift 2 ;;
      --container) container="$2"; shift 2 ;;
      *) die "upload: unknown argument $1" ;;
    esac
  done
  [ -n "$openrc" ] && [ -n "$image_file" ] && [ -n "$image_name" ] || die "upload requires --flex-openrc, --image-file and --image-name"
  [ -f "$image_file" ] || die "image file not found: $image_file"
  _source_openrc "$openrc"

  if _direct_flex_upload "$image_file" "$image_name" "$disk_format" "$container_format" "$visibility"; then
    return 0
  fi
  log "[INFO] Direct FLEX upload failed; trying Cloud Files -> FLEX Glance import"
  _cloud_files_flex_import "$image_file" "$image_name" "$disk_format" "$container_format" "$visibility" "$container"
}

usage() {
  cat <<'EOF'
Usage:
  ospc2flex_glance_bridge.sh download --ospc-openrc FILE --image-id UUID --dest FILE [--container NAME] [--prefer-cloud-files]
  ospc2flex_glance_bridge.sh upload --flex-openrc FILE --image-file FILE --image-name NAME [--container NAME]
EOF
}

cmd="${1:-}"
[ -n "$cmd" ] || { usage; exit 2; }
shift
case "$cmd" in
  download) download_cloud_files_export "$@" ;;
  upload) upload_flex_image "$@" ;;
  -h|--help|help) usage ;;
  *) usage; die "unknown command: $cmd" ;;
esac
