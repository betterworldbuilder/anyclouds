#!/usr/bin/env bash
set -euo pipefail

LABEL="flex-glance-direct"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
SOURCE_OPENRC=""
TARGET_OPENRC=""
SOURCE_REGION=""
TARGET_REGION=""
SOURCE_IMAGE_ID=""
TARGET_IMAGE_NAME=""
TARGET_FLAVOR=""
TARGET_NETWORK=""
TARGET_KEY_NAME=""
FLOATING_IP=""
DRY_RUN=1
BOOT_TARGET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --source-openrc) SOURCE_OPENRC="${2:-}"; shift 2 ;;
    --target-openrc) TARGET_OPENRC="${2:-}"; shift 2 ;;
    --source-region) SOURCE_REGION="${2:-}"; shift 2 ;;
    --target-region) TARGET_REGION="${2:-}"; shift 2 ;;
    --source-image-id) SOURCE_IMAGE_ID="${2:-}"; shift 2 ;;
    --target-image-name) TARGET_IMAGE_NAME="${2:-}"; shift 2 ;;
    --target-flavor) TARGET_FLAVOR="${2:-}"; shift 2 ;;
    --target-network) TARGET_NETWORK="${2:-}"; shift 2 ;;
    --target-key-name) TARGET_KEY_NAME="${2:-}"; shift 2 ;;
    --floating-ip) FLOATING_IP="${2:-}"; shift 2 ;;
    --dry-run) case "${2:-true}" in false|0|no|off) DRY_RUN=0 ;; *) DRY_RUN=1 ;; esac; shift 2 ;;
    --boot-target) case "${2:-false}" in true|1|yes|on) BOOT_TARGET=1 ;; *) BOOT_TARGET=0 ;; esac; shift 2 ;;
    *) echo "[FLEX-GLANCE-DIRECT][ERROR] Unknown argument: $1" >&2; exit 2 ;;
  esac
done

safe_label="$(printf '%s' "$LABEL" | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^_+|_+$//g')"
[[ -n "$safe_label" ]] || safe_label="flex-glance-direct"
RUN_ROOT="${FLEX_GLANCE_DIRECT_RUN_ROOT:-$PWD/.tmp_runs/flex_glance_direct}"
source_run_key="$(printf '%s' "$SOURCE_IMAGE_ID" | sed -E 's/[^A-Za-z0-9._-]+/_/g' | cut -c1-12)"
[[ -n "$source_run_key" ]] || source_run_key="no-source"
safe_run_dir="$(printf '%s_%s_%s' "$RUN_ID" "$safe_label" "$source_run_key" | sed -E 's/[^A-Za-z0-9._-]+/_/g')"
RUN_DIR="$RUN_ROOT/$safe_run_dir"
ARTIFACT_DIR="$RUN_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR"
MAP_JSON="$RUN_DIR/source_target_mapping.json"
REPORT_MD="$RUN_DIR/flex_glance_direct_report.md"

log() { printf '[%s][%s][FLEX-DIRECT] %s\n' "$(date -u +%H:%M:%S)" "$safe_label" "$*"; }
stage() { log "══════════════════════════════════════════════════════"; log "$1"; log "══════════════════════════════════════════════════════"; }
json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'; }

cleanup_stale_direct_artifacts() {
  [[ "${FLEX_DIRECT_CLEAN_STALE_IMAGES:-1}" == "1" ]] || {
    log "[DG0] stale direct artifact cleanup disabled"
    return 0
  }
  local min_age_minutes="${FLEX_DIRECT_CLEAN_MIN_AGE_MIN:-60}"
  [[ "$min_age_minutes" =~ ^[0-9]+$ ]] || min_age_minutes=60
  local before after delete_list
  before="$(df -hP "$RUN_ROOT" 2>/dev/null | awk 'NR==2{print $4 " free / " $2 " total (" $5 " used)"}' || true)"
  log "[DG0] run root disk before cleanup: ${before:-unknown}"
  delete_list="$RUN_DIR/stale_direct_images.tsv"
  : >"$delete_list"
  find "$RUN_ROOT" -xdev -type f -mmin +"$min_age_minutes" \( \
      -iname "*.img" -o -iname "*.raw" -o -iname "*.vhd" -o -iname "*.vhdx" -o -iname "*.vmdk" -o -iname "*.partial*" \
    \) -printf '%s\t%p\n' 2>/dev/null | sort -nr -u >"$delete_list" || true
  local count bytes deleted=0 freed=0 sz path run_root
  count="$(wc -l <"$delete_list" | tr -d '[:space:]')"
  bytes="$(awk -F '\t' '{s+=$1} END{printf "%.0f", s+0}' "$delete_list")"
  if [[ "${count:-0}" -gt 0 ]]; then
    log "[DG0] stale direct artifact cleanup candidates older than ${min_age_minutes}m: count=$count bytes=$bytes"
    while IFS=$'\t' read -r sz path; do
      [[ -n "$path" ]] || continue
      case "$path" in "$RUN_DIR"/*) log "[DG0] keep current direct artifact: $path"; continue ;; esac
      run_root="$(printf '%s\n' "$path" | sed -E "s#^(${RUN_ROOT}/[^/]+).*#\\1#")"
      if [[ -n "$run_root" ]] && ps -eo args= 2>/dev/null | grep -F -- "$run_root" | grep -vq grep; then
        log "[DG0] keep active direct artifact: $path"
        continue
      fi
      case "$path" in
        "$RUN_ROOT"/*)
          log "[DG0] delete stale direct artifact: ${sz}B $path"
          rm -f -- "$path" 2>/dev/null || true
          deleted=$((deleted + 1))
          freed=$((freed + ${sz:-0}))
          ;;
        *) log "[DG0] skip unsafe direct artifact path: $path" ;;
      esac
    done <"$delete_list"
  else
    log "[DG0] no stale direct image artifacts found"
  fi
  rm -f -- "$delete_list" 2>/dev/null || true
  after="$(df -hP "$RUN_ROOT" 2>/dev/null | awk 'NR==2{print $4 " free / " $2 " total (" $5 " used)"}' || true)"
  log "[DG0] stale direct artifact cleanup complete; deleted=$deleted freed_bytes=$freed"
  log "[DG0] run root disk after cleanup: ${after:-unknown}"
}

require_file() {
  [[ -f "$1" ]] && return 0
  log "[ERROR] $2 missing: $1"
  exit 1
}

source_os() {
  local rc="$1" region="$2"
  set +u
  # shellcheck source=/dev/null
  . "$rc"
  export OS_REGION_NAME="$region"
  set -u
}

wait_image_active() {
  local rc="$1" region="$2" image_id="$3" waited=0 status="" failed_import=""
  while [[ "$waited" -le 900 ]]; do
    image_wait_json="$RUN_DIR/target-image-wait-${waited}.json"
    if (
      set +e
      source_os "$rc" "$region"
      openstack image show "$image_id" -f json >"$image_wait_json" 2>/dev/null
    ); then
      status="$(python3 - "$image_wait_json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    data = {}
print(str(data.get("status") or ""))
PY
)"
      failed_import="$(python3 - "$image_wait_json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    data = {}
props = data.get("properties") or {}
print(str(props.get("os_glance_failed_import") or ""))
PY
)"
    else
      status="$(
      set +e
      (source_os "$rc" "$region"; openstack image show "$image_id" -f value -c status) 2>/dev/null
      )"
      failed_import=""
    fi
    log "[WAIT] target image=$image_id status=${status:-unknown} waited=${waited}s"
    [[ "$status" == "active" ]] && return 0
    if [[ -n "$failed_import" ]]; then
      log "[ERROR] target Glance import failed: os_glance_failed_import=$failed_import"
      log "ICF Issue=Direct Flex Glance web-download import failed"
      log "ICF Cause=target Glance accepted the import request but the backend store rejected source TempURL import ($failed_import)"
      log "ICF Fix=retry the same image using the Jumphost temp-file stream fallback"
      (source_os "$rc" "$region"; openstack image delete "$image_id" >/dev/null 2>&1 || true)
      write_mapping "fallback_required" "" "" "target-glance-import-failed"
      return 86
    fi
    [[ "$status" == "killed" || "$status" == "deleted" ]] && return 1
    sleep 15
    waited=$((waited + 15))
  done
  return 1
}

write_mapping() {
  local status="$1" target_image_id="${2:-}" target_server_id="${3:-}" copy_method="${4:-}"
  cat > "$MAP_JSON" <<JSON
{
  "workflow_id": "flex_glance_direct_region_copy",
  "status": "$(printf '%s' "$status" | json_escape)",
  "copy_method": "$(printf '%s' "$copy_method" | json_escape)",
  "label": "$(printf '%s' "$safe_label" | json_escape)",
  "run_id": "$(printf '%s' "$RUN_ID" | json_escape)",
  "source_region": "$(printf '%s' "$SOURCE_REGION" | json_escape)",
  "target_region": "$(printf '%s' "$TARGET_REGION" | json_escape)",
  "source_image_id": "$(printf '%s' "$SOURCE_IMAGE_ID" | json_escape)",
  "target_image_id": "$(printf '%s' "$target_image_id" | json_escape)",
  "target_server_id": "$(printf '%s' "$target_server_id" | json_escape)",
  "target_image_name": "$(printf '%s' "$TARGET_IMAGE_NAME" | json_escape)",
  "run_dir": "$(printf '%s' "$RUN_DIR" | json_escape)"
}
JSON
}

stage "DG0_PREFLIGHT"
cleanup_stale_direct_artifacts
require_file "$SOURCE_OPENRC" "source Flex OpenRC"
require_file "$TARGET_OPENRC" "target Flex OpenRC"
[[ -n "$SOURCE_REGION" && -n "$TARGET_REGION" && -n "$SOURCE_IMAGE_ID" ]] || { log "[ERROR] source-region, target-region, source-image-id required"; exit 1; }
[[ -n "$TARGET_IMAGE_NAME" ]] || TARGET_IMAGE_NAME="${safe_label}-direct-${SOURCE_REGION}-to-${TARGET_REGION}-${RUN_ID}"
log "workflow_id=flex_glance_direct_region_copy run_id=$RUN_ID"
log "source=$SOURCE_REGION target=$TARGET_REGION dry_run=$DRY_RUN"
log "No jumphost, no SSH relay, no rescue VM, no intermediate target VM."
log "Source image IDs are region-scoped; target image ID will be newly created."

stage "DG1_VALIDATE_SOURCE_AND_TARGET"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[DRY-RUN] Would validate source image $SOURCE_IMAGE_ID in $SOURCE_REGION"
  log "[DRY-RUN] Would validate target credentials in $TARGET_REGION"
else
  SOURCE_IMAGE_JSON="$RUN_DIR/source-image.json"
  (source_os "$SOURCE_OPENRC" "$SOURCE_REGION"; openstack image show "$SOURCE_IMAGE_ID" -f json) > "$SOURCE_IMAGE_JSON"
  (source_os "$TARGET_OPENRC" "$TARGET_REGION"; openstack token issue >/dev/null)
  source_status="$(python3 - "$SOURCE_IMAGE_JSON" <<'PY'
import json, sys
print(str(json.load(open(sys.argv[1])).get("status") or "").lower())
PY
  )"
  source_size="$(python3 - "$SOURCE_IMAGE_JSON" <<'PY'
import json, sys
value = json.load(open(sys.argv[1])).get("size")
try:
    print(int(value or 0))
except Exception:
    print(0)
PY
  )"
  if [[ "$source_status" != "active" ]]; then
    log "[ERROR] source image is not active: status=${source_status:-unknown}"
    log "ICF Issue=Direct Flex Glance copy cannot start"
    log "ICF Cause=source image $SOURCE_IMAGE_ID in $SOURCE_REGION is status=${source_status:-unknown}; Glance has no readable active image body yet"
    log "ICF Fix=select an active source image/snapshot or wait/recreate the source image before direct region copy"
    write_mapping "failed" "" "" "source-image-not-active"
    exit 1
  fi
  if [[ ! "$source_size" =~ ^[0-9]+$ || "$source_size" -le 0 ]]; then
    log "[ERROR] source image has no positive byte size: size=${source_size:-unknown}"
    log "ICF Issue=Direct Flex Glance copy cannot read source image bytes"
    log "ICF Cause=source image $SOURCE_IMAGE_ID reports no positive size in $SOURCE_REGION"
    log "ICF Fix=select an active source image with uploaded data, or recreate/resnapshot the source image"
    write_mapping "failed" "" "" "source-image-empty"
    exit 1
  fi
  log "Source image and target credentials validated."
fi

TARGET_IMAGE_ID=""
COPY_METHOD=""
case "${FLEX_GLANCE_DIRECT_ALLOW_RAW_GLANCE_STREAM:-0}" in
  1|true|yes|on) skip_direct_glance_stream=0 ;;
  *) skip_direct_glance_stream=1 ;;
esac

stage "DG2_STREAM_SOURCE_GLANCE_TO_TARGET_GLANCE"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[DRY-RUN] Would create queued target image, then stream source image bytes into Glance upload API."
  TARGET_IMAGE_ID="DRYRUN_TARGET_IMAGE_${RUN_ID}"
  COPY_METHOD="dry-run-glance-api-stream"
else
  stream_log="$RUN_DIR/direct-stream.log"
  upload_body="$RUN_DIR/direct-upload.response"
  http_status_file="$RUN_DIR/direct-upload.http"
  SOURCE_TOKEN="$(source_os "$SOURCE_OPENRC" "$SOURCE_REGION"; openstack token issue -f value -c id)"
  SOURCE_TOKEN="$(printf '%s' "$SOURCE_TOKEN" | tail -1 | tr -d '[:space:]')"
  set +e
  SOURCE_IMAGE_URL="$(
    source_os "$SOURCE_OPENRC" "$SOURCE_REGION"
    openstack endpoint list --service image --interface public --region "$SOURCE_REGION" -f value -c URL 2>/dev/null | head -1
  )"
  source_endpoint_rc=$?
  set -e
  SOURCE_IMAGE_URL="${SOURCE_IMAGE_URL%/}"
  if [[ -z "$SOURCE_IMAGE_URL" ]]; then
    source_region_lc="$(printf '%s' "$SOURCE_REGION" | tr '[:upper:]' '[:lower:]')"
    SOURCE_IMAGE_URL="https://glance.api.${source_region_lc}.rackspacecloud.com/v2"
    log "[WARN] source Glance endpoint discovery failed rc=$source_endpoint_rc; using Rackspace FLEX endpoint fallback: $SOURCE_IMAGE_URL"
  fi
  case "$SOURCE_IMAGE_URL" in
    */v2) SOURCE_IMAGE_API="$SOURCE_IMAGE_URL" ;;
    *) SOURCE_IMAGE_API="$SOURCE_IMAGE_URL/v2" ;;
  esac
  SOURCE_DOWNLOAD_URL="$SOURCE_IMAGE_API/images/$SOURCE_IMAGE_ID/file"
  TARGET_TOKEN="$(source_os "$TARGET_OPENRC" "$TARGET_REGION"; openstack token issue -f value -c id)"
  TARGET_TOKEN="$(printf '%s' "$TARGET_TOKEN" | tail -1 | tr -d '[:space:]')"
  set +e
  TARGET_IMAGE_URL="$(
    source_os "$TARGET_OPENRC" "$TARGET_REGION"
    openstack endpoint list --service image --interface public --region "$TARGET_REGION" -f value -c URL 2>/dev/null | head -1
  )"
  endpoint_rc=$?
  set -e
  TARGET_IMAGE_URL="${TARGET_IMAGE_URL%/}"
  if [[ -z "$TARGET_IMAGE_URL" ]]; then
    region_lc="$(printf '%s' "$TARGET_REGION" | tr '[:upper:]' '[:lower:]')"
    TARGET_IMAGE_URL="https://glance.api.${region_lc}.rackspacecloud.com/v2"
    log "[WARN] target Glance endpoint discovery failed rc=$endpoint_rc; using Rackspace FLEX endpoint fallback: $TARGET_IMAGE_URL"
  fi
  case "$TARGET_IMAGE_URL" in
    */v2) IMAGE_API="$TARGET_IMAGE_URL" ;;
    *) IMAGE_API="$TARGET_IMAGE_URL/v2" ;;
  esac
  create_payload="$(
    TARGET_IMAGE_NAME="$TARGET_IMAGE_NAME" SOURCE_REGION="$SOURCE_REGION" SOURCE_IMAGE_ID="$SOURCE_IMAGE_ID" python3 - "$SOURCE_IMAGE_JSON" <<'PY'
import json, os, sys
source = json.load(open(sys.argv[1]))
props = source.get("properties") or {}
payload = {
    "name": os.environ["TARGET_IMAGE_NAME"],
    "disk_format": source.get("disk_format") or "qcow2",
    "container_format": source.get("container_format") or "bare",
    "visibility": "private",
    "migrated_by": "ospc2flex",
    "migrated_workflow": "flex_glance_direct_region_copy",
    "migrated_from_region": os.environ["SOURCE_REGION"],
    "migrated_from_image_id": os.environ["SOURCE_IMAGE_ID"],
}
for field in ("min_disk", "min_ram"):
    try:
        value = int(source.get(field) or 0)
    except Exception:
        value = 0
    if value > 0:
        payload[field] = value
allowed_prefixes = ("hw_", "os_", "vm_")
allowed_keys = {"architecture"}
blocked_prefixes = ("os_hash_", "owner_specified.", "direct_url", "locations", "stores")
for key, value in props.items():
    if value in (None, ""):
        continue
    if key.startswith(blocked_prefixes):
        continue
    if key.startswith(allowed_prefixes) or key in allowed_keys:
        payload[key] = value
print(json.dumps(payload, separators=(",", ":")))
PY
  )"
  SOURCE_PROJECT_ID="$(source_os "$SOURCE_OPENRC" "$SOURCE_REGION"; printf '%s' "${OS_PROJECT_ID:-}")"
  SOURCE_SWIFT_URL=""
  source_swift_catalog="$RUN_DIR/source-swift-catalog.json"
  if (source_os "$SOURCE_OPENRC" "$SOURCE_REGION"; openstack catalog show object-store -f json >"$source_swift_catalog" 2>"$RUN_DIR/source-swift-catalog.err"); then
    SOURCE_SWIFT_URL="$(python3 - "$SOURCE_REGION" "$source_swift_catalog" <<'PY' || true
import json, sys
region = sys.argv[1].upper()
try:
    data = json.load(open(sys.argv[2]))
except Exception:
    sys.exit(0)
for ep in data.get("endpoints", []):
    if str(ep.get("interface", "")).lower() == "public" and str(ep.get("region", ep.get("region_id", ""))).upper() == region:
        print(str(ep.get("url", "")).rstrip("/"))
        break
PY
    )"
  fi
  SOURCE_SWIFT_URL="${SOURCE_SWIFT_URL%/}"
  if [[ -z "$SOURCE_SWIFT_URL" && -n "$SOURCE_PROJECT_ID" ]]; then
    source_region_lc="$(printf '%s' "$SOURCE_REGION" | tr '[:upper:]' '[:lower:]')"
    SOURCE_SWIFT_URL="https://swift.api.${source_region_lc}.rackspacecloud.com/v1/AUTH_${SOURCE_PROJECT_ID}"
  fi

  if [[ -n "$SOURCE_SWIFT_URL" ]]; then
    stage "DG2A_SOURCE_SWIFT_OBJECT_STREAM"
    mapfile -t source_swift_object_urls < <(
      SOURCE_SWIFT_URL="$SOURCE_SWIFT_URL" SOURCE_IMAGE_ID="$SOURCE_IMAGE_ID" python3 - "$SOURCE_IMAGE_JSON" <<'PY'
import json, os, sys
base = os.environ["SOURCE_SWIFT_URL"].rstrip("/")
image_id = os.environ["SOURCE_IMAGE_ID"]
seen = set()
def emit(path):
    path = (path or "").strip().lstrip("/")
    if not path:
        return
    url = f"{base}/{path}"
    if url not in seen:
        seen.add(url)
        print(url)
emit(f"glance_{image_id}/{image_id}")
try:
    source = json.load(open(sys.argv[1]))
    props = source.get("properties") or {}
except Exception:
    props = {}
emit(props.get("owner_specified.openstack.object") or "")
PY
    )

    swift_head_status=""
    swift_head_headers="$RUN_DIR/swift-source.head.headers"
    swift_head_status_file="$RUN_DIR/swift-source.head.http"
    source_swift_object_url=""
    for candidate_url in "${source_swift_object_urls[@]}"; do
      : > "$swift_head_headers"
      printf '' > "$swift_head_status_file"
      curl -sS -I "$candidate_url" \
        -H "X-Auth-Token: $SOURCE_TOKEN" \
        --write-out "%{http_code}" \
        -o "$swift_head_headers" >"$swift_head_status_file" 2>"$RUN_DIR/swift-source.head.err" || true
      swift_head_status="$(cat "$swift_head_status_file" 2>/dev/null || true)"
      if [[ "$swift_head_status" =~ ^(200|204)$ ]]; then
        source_swift_object_url="$candidate_url"
        break
      fi
      log "[WARN] source Swift candidate not available http=${swift_head_status:-none}: $candidate_url"
    done

    if [[ -n "$source_swift_object_url" ]]; then
      source_swift_size="$(
        awk 'BEGIN{IGNORECASE=1} /^Content-Length:/ {gsub("\r","",$2); print $2; exit}' "$swift_head_headers" 2>/dev/null || true
      )"
      SOURCE_SWIFT_OBJECT_URL_FOR_LOCAL="$source_swift_object_url"
      SOURCE_SWIFT_OBJECT_SIZE_FOR_LOCAL="$source_swift_size"
	      stream_byte_limit="${FLEX_GLANCE_DIRECT_STREAM_MAX_BYTES:-134217728}"
	      [[ "$stream_byte_limit" =~ ^[0-9]+$ && "$stream_byte_limit" -ge 0 ]] || stream_byte_limit=8589934592
		      skip_web_download=0
		      if [[ "$source_swift_size" =~ ^[0-9]+$ && "$source_swift_size" -gt "$stream_byte_limit" ]]; then
			        log "[WARN] Source object is $source_swift_size bytes; skipping pipe stream above ${stream_byte_limit}B and trying target Glance web-download import."
		        skip_direct_glance_stream=1
	      else
	        create_body="$RUN_DIR/swift-stream-image-create.response"
	        create_status_file="$RUN_DIR/swift-stream-image-create.http"
	        log "Creating queued target image in $TARGET_REGION via Glance API for source Swift object stream."
	        curl -sS -X POST "$IMAGE_API/images" \
	          -H "X-Auth-Token: $TARGET_TOKEN" \
	          -H "Content-Type: application/json" \
	          -H "Accept: application/json" \
	          -d "$create_payload" \
	          --write-out "%{http_code}" \
	          -o "$create_body" >"$create_status_file" 2>"$RUN_DIR/swift-stream-image-create.err" || true
	        create_status="$(cat "$create_status_file" 2>/dev/null || true)"
	        if [[ "$create_status" =~ ^(200|201)$ ]]; then
	          TARGET_IMAGE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$create_body" 2>/dev/null || true)"
	          if [[ -n "$TARGET_IMAGE_ID" ]]; then
	            UPLOAD_URL="$IMAGE_API/images/$TARGET_IMAGE_ID/file"
	            stream_log="$RUN_DIR/swift-stream-upload.log"
	            upload_body="$RUN_DIR/swift-stream-upload.response"
	            http_status_file="$RUN_DIR/swift-stream-upload.http"
	            log "Streaming source Swift-backed Glance object directly into target Glance upload API."
	            [[ "$source_swift_size" =~ ^[0-9]+$ ]] && log "Source Swift object size: $source_swift_size bytes"
	            log "Progress note: target image remains queued until the upload PUT closes and Glance activates it."
	            upload_headers=(
	              -H "X-Auth-Token: $TARGET_TOKEN"
	              -H "Content-Type: application/octet-stream"
	              -H "Accept: application/json"
	              -H "Expect:"
	            )
	            if [[ "$source_swift_size" =~ ^[0-9]+$ && "$source_swift_size" -gt 0 ]]; then
	              upload_headers+=(-H "Content-Length: $source_swift_size")
	            fi
	            stream_rc_file="$RUN_DIR/swift-stream-upload.rc"
	            rm -f "$stream_rc_file"
	            set +e
	            (
	              set +e
	              (
	                set -o pipefail
	                curl --http1.1 -fSsL \
	                  --connect-timeout 30 \
	                  --speed-time 300 \
	                  --speed-limit 1024 \
	                  -H "X-Auth-Token: $SOURCE_TOKEN" \
	                  -H "Accept: application/octet-stream" \
	                  "$source_swift_object_url" | \
	                curl --http1.1 -fSs -X PUT "$UPLOAD_URL" \
	                  "${upload_headers[@]}" \
	                  --data-binary @- \
	                  --write-out "%{http_code}" \
	                  -o "$upload_body"
	              ) >"$http_status_file" 2>"$stream_log"
	              printf '%s\n' "$?" >"$stream_rc_file"
	            ) &
	            stream_pid=$!
	            stream_started="$(date +%s)"
	            stream_interval="${FLEX_GLANCE_DIRECT_PROGRESS_INTERVAL:-20}"
	            [[ "$stream_interval" =~ ^[0-9]+$ && "$stream_interval" -ge 5 ]] || stream_interval=20
	            while kill -0 "$stream_pid" >/dev/null 2>&1; do
	              sleep "$stream_interval"
	              if kill -0 "$stream_pid" >/dev/null 2>&1; then
	                stream_elapsed=$(( $(date +%s) - stream_started ))
	                log "[STREAM] source Swift object upload still running elapsed=${stream_elapsed}s target_image=$TARGET_IMAGE_ID"
	              fi
	            done
	            wait "$stream_pid" >/dev/null 2>&1 || true
	            swift_stream_rc="$(cat "$stream_rc_file" 2>/dev/null || echo 1)"
	            set -e
	            http_status="$(cat "$http_status_file" 2>/dev/null || true)"
	            if [[ "$swift_stream_rc" -eq 0 && "$http_status" =~ ^(200|201|204)$ ]]; then
	              COPY_METHOD="swift-object-glance-upload-stream"
	              log "Source Swift object stream uploaded into target image: $TARGET_IMAGE_ID"
	            else
	              log "[WARN] source Swift object stream failed rc=$swift_stream_rc http=${http_status:-none}: $(tail -c 500 "$stream_log" 2>/dev/null | tr '\n' ' ') $(head -c 300 "$upload_body" 2>/dev/null | tr '\n' ' ')"
	              (source_os "$TARGET_OPENRC" "$TARGET_REGION"; openstack image delete "$TARGET_IMAGE_ID" >/dev/null 2>&1 || true)
	              TARGET_IMAGE_ID=""
	            fi
	          fi
	        else
	          log "[WARN] queued target image create for Swift object stream failed http=${create_status:-none}: $(head -c 500 "$create_body" 2>/dev/null | tr '\n' ' ')"
	        fi
	      fi

	      if [[ -z "$TARGET_IMAGE_ID" && "$skip_web_download" -eq 0 ]]; then
        temp_key="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
        curl -sS -X POST "$SOURCE_SWIFT_URL" \
          -H "X-Auth-Token: $SOURCE_TOKEN" \
          -H "X-Account-Meta-Temp-URL-Key-2: $temp_key" \
          --write-out "%{http_code}" \
          -o "$RUN_DIR/swift-tempurl-key.response" >"$RUN_DIR/swift-tempurl-key.http" 2>"$RUN_DIR/swift-tempurl-key.err" || true
        temp_key_status="$(cat "$RUN_DIR/swift-tempurl-key.http" 2>/dev/null || true)"
        if [[ "$temp_key_status" =~ ^(200|201|202|204)$ ]]; then
        temp_url="$(
          TEMP_KEY="$temp_key" SOURCE_SWIFT_URL="$SOURCE_SWIFT_URL" SOURCE_IMAGE_ID="$SOURCE_IMAGE_ID" python3 - <<'PY'
import hmac, hashlib, os, time
from urllib.parse import urlparse
key = os.environ["TEMP_KEY"].encode()
base = os.environ["SOURCE_SWIFT_URL"].rstrip("/")
image_id = os.environ["SOURCE_IMAGE_ID"]
parsed = urlparse(base)
expires = int(time.time()) + 86400
path = f"{parsed.path}/glance_{image_id}/{image_id}"
body = f"GET\n{expires}\n{path}".encode()
sig = hmac.new(key, body, hashlib.sha1).hexdigest()
print(f"{base}/glance_{image_id}/{image_id}?temp_url_sig={sig}&temp_url_expires={expires}")
PY
        )"
        create_body="$RUN_DIR/web-download-image-create.response"
        create_status_file="$RUN_DIR/web-download-image-create.http"
        log "Creating queued target image in $TARGET_REGION via Glance API for Swift TempURL web-download."
        curl -sS -X POST "$IMAGE_API/images" \
          -H "X-Auth-Token: $TARGET_TOKEN" \
          -H "Content-Type: application/json" \
          -H "Accept: application/json" \
          -d "$create_payload" \
          --write-out "%{http_code}" \
          -o "$create_body" >"$create_status_file" 2>"$RUN_DIR/web-download-image-create.err" || true
        create_status="$(cat "$create_status_file" 2>/dev/null || true)"
        if [[ "$create_status" =~ ^(200|201)$ ]]; then
          TARGET_IMAGE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$create_body" 2>/dev/null || true)"
          import_body="$RUN_DIR/web-download-import.response"
          import_status_file="$RUN_DIR/web-download-import.http"
          import_payload="$(
            TEMP_URL="$temp_url" python3 - <<'PY'
import json, os
print(json.dumps({"method": {"name": "web-download", "uri": os.environ["TEMP_URL"]}}, separators=(",", ":")))
PY
          )"
          log "Starting target Glance web-download import from source Swift TempURL."
          curl -sS -X POST "$IMAGE_API/images/$TARGET_IMAGE_ID/import" \
            -H "X-Auth-Token: $TARGET_TOKEN" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$import_payload" \
            --write-out "%{http_code}" \
            -o "$import_body" >"$import_status_file" 2>"$RUN_DIR/web-download-import.err" || true
          import_status="$(cat "$import_status_file" 2>/dev/null || true)"
          if [[ "$import_status" =~ ^(200|201|202|204)$ ]]; then
            COPY_METHOD="swift-tempurl-glance-web-download"
            log "Target Glance web-download import accepted for target image: $TARGET_IMAGE_ID"
          else
            log "[WARN] target Glance web-download import failed http=${import_status:-none}: $(head -c 500 "$import_body" 2>/dev/null | tr '\n' ' ')"
            (source_os "$TARGET_OPENRC" "$TARGET_REGION"; openstack image delete "$TARGET_IMAGE_ID" >/dev/null 2>&1 || true)
            TARGET_IMAGE_ID=""
          fi
        else
          log "[WARN] queued target image create for web-download failed http=${create_status:-none}: $(head -c 500 "$create_body" 2>/dev/null | tr '\n' ' ')"
        fi
      else
        log "[WARN] could not set source Swift TempURL key http=${temp_key_status:-none}; falling back to Glance byte stream."
      fi
      fi
    else
      log "[WARN] source Swift Glance object not available; using local Glance save fallback."
    fi
  else
    log "[WARN] source Swift endpoint unavailable; using local Glance save fallback."
  fi

	  if [[ -z "$TARGET_IMAGE_ID" && "$skip_direct_glance_stream" -eq 0 ]]; then
    stream_attempts="${FLEX_GLANCE_DIRECT_STREAM_ATTEMPTS:-1}"
    [[ "$stream_attempts" =~ ^[0-9]+$ && "$stream_attempts" -ge 1 ]] || stream_attempts=1
    for attempt in $(seq 1 "$stream_attempts"); do
      create_body="$RUN_DIR/direct-image-create.${attempt}.response"
      create_status_file="$RUN_DIR/direct-image-create.${attempt}.http"
      stream_log="$RUN_DIR/direct-stream.${attempt}.log"
      upload_body="$RUN_DIR/direct-upload.${attempt}.response"
      http_status_file="$RUN_DIR/direct-upload.${attempt}.http"
      TARGET_IMAGE_ID=""

      log "Creating queued target image in $TARGET_REGION via Glance API: $TARGET_IMAGE_NAME (attempt $attempt/$stream_attempts)"
      curl -sS -X POST "$IMAGE_API/images" \
        -H "X-Auth-Token: $TARGET_TOKEN" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$create_payload" \
        --write-out "%{http_code}" \
        -o "$create_body" >"$create_status_file" 2>"$RUN_DIR/direct-image-create.${attempt}.err" || true
      create_status="$(cat "$create_status_file" 2>/dev/null || true)"
      if [[ ! "$create_status" =~ ^(200|201)$ ]]; then
        log "[WARN] queued target image create failed http=${create_status:-none}: $(head -c 500 "$create_body" 2>/dev/null | tr '\n' ' ')"
        sleep $((attempt * 5))
        continue
      fi
      TARGET_IMAGE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$create_body" 2>/dev/null || true)"
      if [[ -z "$TARGET_IMAGE_ID" ]]; then
        log "[WARN] target Glance API create did not return an image ID"
        sleep $((attempt * 5))
        continue
      fi

      UPLOAD_URL="$IMAGE_API/images/$TARGET_IMAGE_ID/file"
      log "Streaming source Glance bytes directly into target Glance upload API (attempt $attempt/$stream_attempts)."
      set +e
      (
        set -o pipefail
        curl --http1.1 -fSsL \
          --connect-timeout 30 \
          --speed-time 120 \
          --speed-limit 1024 \
          -H "X-Auth-Token: $SOURCE_TOKEN" \
          -H "Accept: application/octet-stream" \
          "$SOURCE_DOWNLOAD_URL" | \
        curl --http1.1 -fSs -X PUT "$UPLOAD_URL" \
          -H "X-Auth-Token: $TARGET_TOKEN" \
          -H "Content-Type: application/octet-stream" \
          -H "Accept: application/json" \
          --data-binary @- \
          --write-out "%{http_code}" \
          -o "$upload_body"
      ) >"$http_status_file" 2>"$stream_log"
      stream_rc=$?
      set -e
      http_status="$(cat "$http_status_file" 2>/dev/null || true)"
      if [[ "$stream_rc" -eq 0 && "$http_status" =~ ^(200|201|204)$ ]]; then
        COPY_METHOD="glance-http-download-upload-stream"
        log "Direct stream uploaded source image into target image: $TARGET_IMAGE_ID"
        break
      fi

      log "[WARN] Streaming mode failed rc=$stream_rc http=${http_status:-none}: $(tail -c 500 "$stream_log" | tr '\n' ' ') $(head -c 300 "$upload_body" 2>/dev/null | tr '\n' ' ')"
      (source_os "$TARGET_OPENRC" "$TARGET_REGION"; openstack image delete "$TARGET_IMAGE_ID" >/dev/null 2>&1 || true)
      TARGET_IMAGE_ID=""
      sleep $((attempt * 10))
    done
  fi
fi

if [[ -z "$TARGET_IMAGE_ID" && "$DRY_RUN" -eq 0 ]]; then
		  case "${FLEX_GLANCE_DIRECT_ALLOW_LOCAL_FALLBACK:-0}" in
		    1|true|TRUE|yes|YES|on|ON) ;;
		    *)
		      stage "DG2B_JUMPHOST_FALLBACK_REQUIRED"
		      log "[ERROR] Direct stream did not produce a target image and local dashboard downloads are disabled."
		      log "ICF Issue=Direct Flex Glance copy cannot continue locally"
		      log "ICF Cause=source-to-target API stream failed or image is too large for direct pipe; local dashboard temp-file fallback is disabled"
		      log "ICF Fix=use the Jumphost temp-file stream fallback method for this image"
		      write_mapping "fallback_required" "" "" "jumphost-fallback-required"
		      exit 86
		      ;;
		  esac
		  stage "DG2B_LOCAL_TEMP_FILE_FALLBACK"
		  local_image="$ARTIFACT_DIR/${safe_label}-${SOURCE_IMAGE_ID}.img"
	  log "Direct pipe failed; falling back to local dashboard temp-file mode (no jumphost/SSH/helper VM): $local_image"
	  download_rc=1
	  if [[ -s "$local_image" && "${SOURCE_SWIFT_OBJECT_SIZE_FOR_LOCAL:-}" =~ ^[0-9]+$ ]]; then
	    existing_size="$(stat -c%s "$local_image" 2>/dev/null || echo 0)"
	    if [[ "$existing_size" -eq "$SOURCE_SWIFT_OBJECT_SIZE_FOR_LOCAL" ]]; then
	      log "RESUME: reusing existing local temp image: $local_image ($existing_size bytes)"
	      download_rc=0
	    fi
	  fi
	  [[ "$download_rc" -eq 0 ]] || rm -f "$local_image"
	  if [[ -n "${SOURCE_SWIFT_OBJECT_URL_FOR_LOCAL:-}" ]]; then
	    if [[ "$download_rc" -eq 0 && -s "$local_image" ]]; then
	      log "Source Swift-backed Glance object already downloaded; skipping download."
	    else
	      if [[ -s "$local_image" ]]; then
	        log "RESUME: continuing partial local temp image: $local_image ($(stat -c%s "$local_image" 2>/dev/null || echo 0) bytes)"
	        resume_opts=(--continue-at -)
	      else
	        resume_opts=()
	      fi
	      log "Downloading source Swift-backed Glance object to local temp file."
	      set +e
	      curl --http1.1 -fSsL \
	        --connect-timeout 30 \
	        --retry 5 --retry-delay 10 --retry-connrefused \
	        --speed-time 600 \
	        --speed-limit 1024 \
	        -H "X-Auth-Token: $SOURCE_TOKEN" \
	        -H "Accept: application/octet-stream" \
	        "${SOURCE_SWIFT_OBJECT_URL_FOR_LOCAL}" \
	        -o "$local_image" "${resume_opts[@]}" >"$RUN_DIR/local-swift-download.out" 2>"$RUN_DIR/local-swift-download.err"
	      download_rc=$?
	      set -e
	      if [[ "$download_rc" -eq 0 && -s "$local_image" && "${SOURCE_SWIFT_OBJECT_SIZE_FOR_LOCAL:-}" =~ ^[0-9]+$ ]]; then
	        actual_size="$(stat -c%s "$local_image" 2>/dev/null || echo 0)"
	        if [[ "$actual_size" -ne "$SOURCE_SWIFT_OBJECT_SIZE_FOR_LOCAL" ]]; then
	          log "[WARN] source Swift local download size mismatch expected=${SOURCE_SWIFT_OBJECT_SIZE_FOR_LOCAL} actual=$actual_size"
	          download_rc=1
	        fi
	      fi
	      if [[ "$download_rc" -ne 0 || ! -s "$local_image" ]]; then
	        log "[WARN] source Swift local download failed rc=$download_rc: $(tail -c 500 "$RUN_DIR/local-swift-download.err" 2>/dev/null | tr '\n' ' ')"
	        rm -f "$local_image"
	      fi
	    fi
	  fi
	  if [[ "$download_rc" -ne 0 || ! -s "$local_image" ]]; then
	    set +e
	    (source_os "$SOURCE_OPENRC" "$SOURCE_REGION"; openstack image save --file "$local_image" "$SOURCE_IMAGE_ID") >"$RUN_DIR/local-download.out" 2>"$RUN_DIR/local-download.err"
	    download_rc=$?
	    set -e
	  fi
	  if [[ "$download_rc" -ne 0 || ! -s "$local_image" ]]; then
	    log "[ERROR] openstack image save --file failed rc=$download_rc: $(tail -c 800 "$RUN_DIR/local-download.err" 2>/dev/null | tr '\n' ' ')"
	    rm -f "$local_image"
	    log "ICF Issue=Direct Flex Glance copy could not read source image bytes"
	    log "ICF Cause=source Swift object was unavailable and source Glance /file returned no valid image body (often HTTP 204/empty or checksum mismatch)"
	    log "ICF Fix=use a source image with downloadable Glance bytes, recreate/resnapshot the image in source FLEX, or use a non-direct source-region boot/volume method"
	    write_mapping "failed" "" "" "source-image-bytes-unavailable"
	    exit 1
	  fi
  log "Downloaded source image to local temp file: $local_image ($(stat -c%s "$local_image") bytes)"
  if command -v qemu-img >/dev/null 2>&1; then
    qemu-img info "$local_image" 2>&1 | sed 's/^/[qemu-img] /' || true
  fi

  disk_format="$(CREATE_PAYLOAD="$create_payload" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["CREATE_PAYLOAD"])
print(payload.get("disk_format") or "qcow2")
PY
  )"
  container_format="$(CREATE_PAYLOAD="$create_payload" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["CREATE_PAYLOAD"])
print(payload.get("container_format") or "bare")
PY
  )"
  min_disk="$(CREATE_PAYLOAD="$create_payload" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["CREATE_PAYLOAD"])
print(int(payload.get("min_disk") or 0))
PY
  )"
  min_ram="$(CREATE_PAYLOAD="$create_payload" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["CREATE_PAYLOAD"])
print(int(payload.get("min_ram") or 0))
PY
  )"
  mapfile -t image_properties < <(CREATE_PAYLOAD="$create_payload" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["CREATE_PAYLOAD"])
skip = {"name", "disk_format", "container_format", "visibility", "min_disk", "min_ram"}
for key in sorted(payload):
    if key in skip:
        continue
    value = payload[key]
    if value is None or isinstance(value, (dict, list)):
        continue
    print(f"{key}={value}")
PY
  )

  image_create_args=(--disk-format "$disk_format" --container-format "$container_format" --file "$local_image" --private)
  [[ "$min_disk" =~ ^[0-9]+$ && "$min_disk" -gt 0 ]] && image_create_args+=(--min-disk "$min_disk")
  [[ "$min_ram" =~ ^[0-9]+$ && "$min_ram" -gt 0 ]] && image_create_args+=(--min-ram "$min_ram")
  for prop in "${image_properties[@]}"; do
    image_create_args+=(--property "$prop")
  done

  log "Creating target image in $TARGET_REGION using OpenStack image create --file: $TARGET_IMAGE_NAME"
  log "This is the same target Glance upload path used by the working OSPC->Flex snapshot migrator."
  set +e
  TARGET_IMAGE_ID="$(
    source_os "$TARGET_OPENRC" "$TARGET_REGION"
    openstack image create --format value -c id "${image_create_args[@]}" "$TARGET_IMAGE_NAME" 2>"$RUN_DIR/local-openstack-image-create.err"
  )"
  image_create_rc=$?
  set -e
  printf '%s\n' "$TARGET_IMAGE_ID" >"$RUN_DIR/local-openstack-image-create.out"
  TARGET_IMAGE_ID="$(printf '%s' "$TARGET_IMAGE_ID" | tail -1 | tr -d '[:space:]')"
  if [[ "$image_create_rc" -ne 0 || -z "$TARGET_IMAGE_ID" ]]; then
    log "[ERROR] openstack image create --file failed rc=$image_create_rc: $(tail -c 800 "$RUN_DIR/local-openstack-image-create.err" 2>/dev/null | tr '\n' ' ')"
    write_mapping "failed" "" "" "local-temp-openstack-image-create-failed"
    exit 1
  fi
  COPY_METHOD="local-temp-file-openstack-image-create"
  log "Local temp file uploaded through OpenStack image create: $TARGET_IMAGE_ID"
fi

stage "DG3_WAIT_TARGET_IMAGE_ACTIVE"
if [[ "$DRY_RUN" -eq 0 ]]; then
  wait_image_active "$TARGET_OPENRC" "$TARGET_REGION" "$TARGET_IMAGE_ID"
fi

TARGET_SERVER_ID=""
stage "DG4_BOOT_TARGET_VM"
if [[ "$BOOT_TARGET" -eq 1 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] Would boot target VM from $TARGET_IMAGE_ID"
    TARGET_SERVER_ID="DRYRUN_TARGET_SERVER_${RUN_ID}"
  elif [[ -z "$TARGET_FLAVOR" || -z "$TARGET_NETWORK" ]]; then
    log "[WARN] boot requested but target flavor/network missing; image copy complete, boot skipped."
  else
    if ! (source_os "$TARGET_OPENRC" "$TARGET_REGION"; openstack flavor show "$TARGET_FLAVOR" >/dev/null 2>&1); then
      mapped_flavor=""
      if [[ "$TARGET_FLAVOR" == gp.0.* ]]; then
        mapped_flavor="${TARGET_FLAVOR/gp.0./gp.5.}"
      fi
      if [[ -n "$mapped_flavor" ]] && (source_os "$TARGET_OPENRC" "$TARGET_REGION"; openstack flavor show "$mapped_flavor" >/dev/null 2>&1); then
        log "[BOOT] target flavor '$TARGET_FLAVOR' not found; using mapped FLEX flavor '$mapped_flavor'"
        TARGET_FLAVOR="$mapped_flavor"
      elif (source_os "$TARGET_OPENRC" "$TARGET_REGION"; openstack flavor show gp.5.4.4 >/dev/null 2>&1); then
        log "[BOOT] target flavor '$TARGET_FLAVOR' not found; using fallback FLEX flavor 'gp.5.4.4'"
        TARGET_FLAVOR="gp.5.4.4"
      else
        log "[WARN] target flavor '$TARGET_FLAVOR' not found and no fallback flavor available; boot skipped."
        TARGET_FLAVOR=""
      fi
    fi

    if [[ -n "$TARGET_KEY_NAME" ]] && ! (source_os "$TARGET_OPENRC" "$TARGET_REGION"; openstack keypair show "$TARGET_KEY_NAME" >/dev/null 2>&1); then
      fallback_key="$(
        (
          source_os "$TARGET_OPENRC" "$TARGET_REGION"
          openstack keypair list -f value -c Name 2>/dev/null | head -1
        ) || true
      )"
      fallback_key="$(printf '%s' "$fallback_key" | tr -d '\r' | head -1)"
      if [[ -n "$fallback_key" ]]; then
        log "[BOOT] target keypair '$TARGET_KEY_NAME' not found; using existing target keypair '$fallback_key'"
        TARGET_KEY_NAME="$fallback_key"
      else
        log "[BOOT] target keypair '$TARGET_KEY_NAME' not found and no keypairs exist; booting without keypair"
        TARGET_KEY_NAME=""
      fi
    fi

	    if [[ -z "$TARGET_FLAVOR" ]]; then
	      log "[WARN] boot skipped because no valid target flavor is available."
	    else
	      boot_from_volume_size=""
	      flavor_disk="$(
	        (
	          source_os "$TARGET_OPENRC" "$TARGET_REGION"
	          openstack flavor show "$TARGET_FLAVOR" -f value -c disk 2>/dev/null
	        ) | tail -1 | tr -dc '0-9'
	      )"
	      if [[ "${flavor_disk:-0}" == "0" ]]; then
	        image_virtual_size="$(
	          (
	            source_os "$TARGET_OPENRC" "$TARGET_REGION"
	            openstack image show "$TARGET_IMAGE_ID" -f value -c virtual_size 2>/dev/null
	          ) | tail -1 | tr -dc '0-9'
	        )"
	        image_min_disk="$(
	          (
	            source_os "$TARGET_OPENRC" "$TARGET_REGION"
	            openstack image show "$TARGET_IMAGE_ID" -f value -c min_disk 2>/dev/null
	          ) | tail -1 | tr -dc '0-9'
	        )"
	        if [[ "${image_virtual_size:-0}" =~ ^[0-9]+$ && "$image_virtual_size" -gt 0 ]]; then
	          boot_from_volume_size=$(( (image_virtual_size + 1073741823) / 1073741824 ))
	        else
	          boot_from_volume_size="${image_min_disk:-1}"
	        fi
	        [[ "$boot_from_volume_size" =~ ^[0-9]+$ && "$boot_from_volume_size" -ge 1 ]] || boot_from_volume_size=1
	        if [[ "${image_min_disk:-0}" =~ ^[0-9]+$ && "$image_min_disk" -gt "$boot_from_volume_size" ]]; then
	          boot_from_volume_size="$image_min_disk"
	        fi
	        log "[BOOT] target flavor '$TARGET_FLAVOR' has zero local disk; using volume-backed boot size ${boot_from_volume_size}GB"
	      fi

	      boot_args=(server create "${safe_label}-direct-${TARGET_REGION}-${RUN_ID}" --image "$TARGET_IMAGE_ID" --flavor "$TARGET_FLAVOR" --network "$TARGET_NETWORK")
	      [[ -n "$TARGET_KEY_NAME" ]] && boot_args+=(--key-name "$TARGET_KEY_NAME")
	      [[ -n "$boot_from_volume_size" ]] && boot_args+=(--boot-from-volume "$boot_from_volume_size")
	      boot_args+=(--wait -f value -c id)
      TARGET_SERVER_ID="$(source_os "$TARGET_OPENRC" "$TARGET_REGION"; openstack "${boot_args[@]}")"
      TARGET_SERVER_ID="$(printf '%s' "$TARGET_SERVER_ID" | tail -1 | tr -d '[:space:]')"
      log "Target server ID: $TARGET_SERVER_ID"
	      if [[ -n "$TARGET_SERVER_ID" && -n "$FLOATING_IP" ]]; then
	        log "[FIP] replacement IP requested: $FLOATING_IP"
	        (
	          source_os "$TARGET_OPENRC" "$TARGET_REGION"
	          port_id="$(openstack port list --server "$TARGET_SERVER_ID" -f value -c ID 2>/dev/null | head -1 | tr -d '\r' || true)"
	          fip_id="$(openstack floating ip list -f value -c ID -c 'Floating IP Address' 2>/dev/null | awk -v ip="$FLOATING_IP" '$2==ip{print $1; exit}' || true)"
	          if [[ -n "$port_id" && -n "$fip_id" ]]; then
	            fixed="$(openstack floating ip show "$fip_id" -f value -c fixed_ip_address 2>/dev/null || true)"
	            if [[ -n "$fixed" && "$fixed" != "None" ]]; then
	              log "[FIP] detaching replacement IP $FLOATING_IP from existing fixed IP $fixed"
	              openstack floating ip unset --port "$fip_id" >/dev/null 2>&1 || true
	              sleep 3
	            fi
	            openstack floating ip set --port "$port_id" "$fip_id" >/dev/null 2>&1 || true
	            log "[FIP] replacement IP attached: $FLOATING_IP"
	          else
	            log "[FIP][WARN] replacement IP or target port not found; ip=$FLOATING_IP port=${port_id:-missing}"
	          fi
	        )
	      fi
	    fi
  fi
else
  log "Target boot skipped."
fi

write_mapping "complete" "$TARGET_IMAGE_ID" "$TARGET_SERVER_ID" "$COPY_METHOD"
cat > "$REPORT_MD" <<MD
# FLEX Glance Direct Region Copy

- Source region: \`$SOURCE_REGION\`
- Source image ID: \`$SOURCE_IMAGE_ID\`
- Target region: \`$TARGET_REGION\`
- Target image ID: \`$TARGET_IMAGE_ID\`
- Target server ID: \`${TARGET_SERVER_ID:-}\`
- Copy method: \`$COPY_METHOD\`
- Mapping JSON: \`$MAP_JSON\`
MD

stage "DG5_COMPLETE"
log "DIRECT_GLANCE_COPY_COMPLETE=true"
log "SOURCE_IMAGE_ID=$SOURCE_IMAGE_ID"
log "TARGET_IMAGE_ID=$TARGET_IMAGE_ID"
log "TARGET_SERVER_ID=${TARGET_SERVER_ID:-}"
log "COPY_METHOD=$COPY_METHOD"
log "MAPPING_JSON=$MAP_JSON"
