#!/usr/bin/env bash
set -euo pipefail

LABEL="flex2flex-region"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
SOURCE_OPENRC=""
TARGET_OPENRC=""
SOURCE_REGION=""
TARGET_REGION=""
SOURCE_SERVER_ID=""
SOURCE_IMAGE_ID=""
TARGET_IMAGE_NAME=""
TARGET_FLAVOR=""
TARGET_NETWORK=""
TARGET_KEY_NAME=""
DRY_RUN=1
BOOT_TARGET=0
START_FRESH=0

usage() {
  cat <<'USAGE'
R3 FLEX2FLEX-Region Cloning

Method:
  Snapshot migration clone:
    Flex server snapshot or existing Glance image
    -> openstack image save
    -> target-region openstack image create
    -> optional target boot

Required:
  --source-openrc PATH
  --target-openrc PATH
  --source-region REGION
  --target-region REGION
  --source-server-id SERVER_ID or --source-image-id IMAGE_ID

Optional:
  --label NAME
  --run-id ID
  --target-image-name NAME
  --target-flavor FLAVOR
  --target-network NETWORK
  --target-key-name KEY
  --dry-run true|false
  --boot-target true|false
  --start-fresh true|false
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --source-openrc) SOURCE_OPENRC="${2:-}"; shift 2 ;;
    --target-openrc) TARGET_OPENRC="${2:-}"; shift 2 ;;
    --source-region) SOURCE_REGION="${2:-}"; shift 2 ;;
    --target-region) TARGET_REGION="${2:-}"; shift 2 ;;
    --source-server-id) SOURCE_SERVER_ID="${2:-}"; shift 2 ;;
    --source-image-id) SOURCE_IMAGE_ID="${2:-}"; shift 2 ;;
    --target-image-name) TARGET_IMAGE_NAME="${2:-}"; shift 2 ;;
    --target-flavor) TARGET_FLAVOR="${2:-}"; shift 2 ;;
    --target-network) TARGET_NETWORK="${2:-}"; shift 2 ;;
    --target-key-name) TARGET_KEY_NAME="${2:-}"; shift 2 ;;
    --dry-run)
      if [[ $# -lt 2 || "${2:-}" == --* ]]; then
        DRY_RUN=1; shift
      else
        case "${2:-true}" in false|0|no|off) DRY_RUN=0 ;; *) DRY_RUN=1 ;; esac; shift 2
      fi
      ;;
    --boot-target)
      if [[ $# -lt 2 || "${2:-}" == --* ]]; then
        BOOT_TARGET=1; shift
      else
        case "${2:-false}" in true|1|yes|on) BOOT_TARGET=1 ;; *) BOOT_TARGET=0 ;; esac; shift 2
      fi
      ;;
    --start-fresh)
      if [[ $# -lt 2 || "${2:-}" == --* ]]; then
        START_FRESH=1; shift
      else
        case "${2:-false}" in true|1|yes|on) START_FRESH=1 ;; *) START_FRESH=0 ;; esac; shift 2
      fi
      ;;
    --help|-h) usage; exit 0 ;;
    *) echo "[R3-F2F][ERROR] Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

safe_label="$(printf '%s' "$LABEL" | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^_+|_+$//g')"
[[ -n "$safe_label" ]] || safe_label="flex2flex-region"
RUN_ROOT="${FLEX2FLEX_RUN_ROOT:-$PWD/.tmp_runs/flex2flex}"
source_run_key="$(printf '%s' "${SOURCE_IMAGE_ID:-${SOURCE_SERVER_ID:-}}" | sed -E 's/[^A-Za-z0-9._-]+/_/g' | cut -c1-12)"
[[ -n "$source_run_key" ]] || source_run_key="no-source"
safe_run_dir="$(printf '%s_%s_%s' "$RUN_ID" "$safe_label" "$source_run_key" | sed -E 's/[^A-Za-z0-9._-]+/_/g')"
RUN_DIR="$RUN_ROOT/$safe_run_dir"
ARTIFACT_DIR="$RUN_DIR/artifacts"

early_log() {
  printf '[%s][%s][R3-F2F] %s\n' "$(date -u +%H:%M:%S)" "$safe_label" "$*"
}

preflight_run_root_space() {
  mkdir -p "$RUN_ROOT" 2>/dev/null || true
  [[ -d "$RUN_ROOT" ]] || return 0

  local before after avail_kb min_kb
  before="$(df -hP "$RUN_ROOT" 2>/dev/null | awk 'NR==2{print $4 " free / " $2 " total (" $5 " used)"}' || true)"
  early_log "[LS0A] run root disk before cleanup: ${before:-unknown}"

  if [[ "$START_FRESH" -eq 1 ]]; then
    find "$RUN_ROOT" -mindepth 1 -maxdepth 1 -type d -name "*_${safe_label}_*" ! -name "$safe_run_dir" -print 2>/dev/null | while read -r old_run; do
      [[ -n "$old_run" ]] || continue
      early_log "[LS0A] delete same-label old run: $old_run"
      rm -rf -- "$old_run"
    done
  fi

  avail_kb="$(df -Pk "$RUN_ROOT" 2>/dev/null | awk 'NR==2{print $4+0}' || echo 0)"
  min_kb="${FLEX2FLEX_MIN_FREE_KB:-26214400}"
  if [[ "${avail_kb:-0}" -lt "$min_kb" ]]; then
    early_log "[LS0A] low free space (${avail_kb:-0}KB); pruning stale flex2flex runs older than 6h"
    find "$RUN_ROOT" -mindepth 1 -maxdepth 1 -type d -mmin +360 ! -name "$safe_run_dir" -print 2>/dev/null | sort | while read -r old_run; do
      [[ -n "$old_run" ]] || continue
      early_log "[LS0A] delete stale old run: $old_run"
      rm -rf -- "$old_run"
    done
  fi

  after="$(df -hP "$RUN_ROOT" 2>/dev/null | awk 'NR==2{print $4 " free / " $2 " total (" $5 " used)"}' || true)"
  early_log "[LS0A] run root disk after cleanup: ${after:-unknown}"
}

preflight_run_root_space
if ! mkdir -p "$ARTIFACT_DIR" 2>/dev/null; then
  fallback_run_root="${FLEX2FLEX_FALLBACK_RUN_ROOT:-/tmp/flex2flex}"
  if [[ -n "$fallback_run_root" && "$fallback_run_root" != "$RUN_ROOT" ]]; then
    early_log "[WARN] primary run root unavailable: $RUN_ROOT; trying fallback run root: $fallback_run_root"
    RUN_ROOT="$fallback_run_root"
    RUN_DIR="$RUN_ROOT/$safe_run_dir"
    ARTIFACT_DIR="$RUN_DIR/artifacts"
    preflight_run_root_space
  fi
  if ! mkdir -p "$ARTIFACT_DIR" 2>/dev/null; then
    early_log "[ERROR] cannot create run directory: $ARTIFACT_DIR"
    early_log "ICF Issue=Flex2Flex jumphost run directory creation failed"
    early_log "ICF Cause=jumphost filesystem has no free space or neither /mnt/migration/flex2flex nor the fallback run root is writable"
    early_log "ICF Fix=free space under the jumphost migration filesystem or reduce concurrent large image fallback jobs, then rerun START FRESH"
    exit 28
  fi
fi
PLAN_JSON="$RUN_DIR/flex2flex_region_plan.json"
REPORT_MD="$RUN_DIR/flex2flex_region_report.md"

log() {
  printf '[%s][%s][R3-F2F] %s\n' "$(date -u +%H:%M:%S)" "$safe_label" "$*"
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'
}

write_plan() {
  local status="$1"
  local issue="$2"
  local cause="$3"
  local fix="$4"
  cat > "$PLAN_JSON" <<JSON
{
  "workflow_id": "flex2flex_region_migration",
  "stage": "R3 FLEX2FLEX-Region Cloning",
  "clone_method": "snapshot_migration_glance_save_import",
  "clone_method_steps": [
    "source Flex server snapshot or existing source Glance image",
    "openstack image save from source Flex region",
    "openstack image create into target Flex region",
    "optional target server boot from imported image"
  ],
  "label": "$(printf '%s' "$safe_label" | json_escape)",
  "run_id": "$(printf '%s' "$RUN_ID" | json_escape)",
  "status": "$(printf '%s' "$status" | json_escape)",
  "dry_run": $([[ "$DRY_RUN" -eq 1 ]] && echo true || echo false),
  "preserve_source": true,
  "source_region": "$(printf '%s' "$SOURCE_REGION" | json_escape)",
  "target_region": "$(printf '%s' "$TARGET_REGION" | json_escape)",
  "source_server_id": "$(printf '%s' "$SOURCE_SERVER_ID" | json_escape)",
  "source_image_id": "$(printf '%s' "$SOURCE_IMAGE_ID" | json_escape)",
  "target_image_name": "$(printf '%s' "$TARGET_IMAGE_NAME" | json_escape)",
  "target_flavor": "$(printf '%s' "$TARGET_FLAVOR" | json_escape)",
  "target_network": "$(printf '%s' "$TARGET_NETWORK" | json_escape)",
  "target_key_name": "$(printf '%s' "$TARGET_KEY_NAME" | json_escape)",
  "icf": {
    "issue": "$(printf '%s' "$issue" | json_escape)",
    "cause": "$(printf '%s' "$cause" | json_escape)",
    "fix": "$(printf '%s' "$fix" | json_escape)"
  },
  "artifacts": {
    "run_dir": "$(printf '%s' "$RUN_DIR" | json_escape)",
    "plan_json": "$(printf '%s' "$PLAN_JSON" | json_escape)",
    "report_md": "$(printf '%s' "$REPORT_MD" | json_escape)"
  }
}
JSON
  cat > "$REPORT_MD" <<MD
# R3 FLEX2FLEX-Region Cloning

- Label: \`$safe_label\`
- Run ID: \`$RUN_ID\`
- Source region: \`$SOURCE_REGION\`
- Target region: \`$TARGET_REGION\`
- Dry run: \`$([[ "$DRY_RUN" -eq 1 ]] && echo true || echo false)\`
- Preserve source: \`true\`
- Clone method: \`snapshot_migration_glance_save_import\`

## Snapshot Migration Method

1. Use an existing source Glance snapshot/image, or create a source server snapshot.
2. Export it from the source Flex region with \`openstack image save\`.
3. Import it into the target Flex region with \`openstack image create\`.
4. Optionally boot a target server from the imported image.

## ICF

- Issue: $issue
- Cause: $cause
- Fix: $fix

## Artifacts

- Plan JSON: \`$PLAN_JSON\`
- Report: \`$REPORT_MD\`
MD
}

stage() {
  log "══════════════════════════════════════════════════════"
  log "$1"
  log "══════════════════════════════════════════════════════"
}

require_file() {
  if [[ ! -f "$1" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[DRY-RUN] $2 missing: $1 (allowed; no cloud command will run)"
      return 0
    fi
    write_plan "failed" "$2 missing" "Required OpenRC file was not staged on the jumphost." "Restage credentials from the dashboard and retry R3 FLEX2FLEX."
    log "[ERROR] $2 missing: $1"
    exit 1
  fi
}

start_fresh_clear_label_resume() {
  [ "$START_FRESH" = "1" ] || return 0
  local label_root="$RUN_ROOT"
  [ -d "$label_root" ] || return 0

  log "[LS0B] START FRESH: cleaning previous flex2flex runs for $safe_label"
  local self_pid="$$"
  local pids
  pids=$(pgrep -af 'flex2flex_region_migrate.sh' 2>/dev/null | grep -F -- "--label $safe_label" | awk '{print $1}' | sort -u | grep -v "^$self_pid$" || true)
  if [[ -n "$pids" ]]; then
    log "[LS0B] killing existing flex2flex job pid(s): $pids"
    for pid in $pids; do
      kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 2
    for pid in $pids; do
      kill -KILL "$pid" 2>/dev/null || true
    done
  else
    log "[LS0B] no existing flex2flex jobs found"
  fi
  find "$label_root" -mindepth 1 -maxdepth 1 -type d -name "*_${safe_label}_*" ! -name "$safe_run_dir" -print 2>/dev/null | while read -r old_run; do
    [ -n "$old_run" ] || continue
    log "[LS0B] delete old run: $old_run"
    rm -rf -- "$old_run"
  done
}

run_os() {
  local rc="$1"; shift
  local region="$1"; shift
  local desc="$1"; shift
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] $desc: openstack $*"
    return 0
  fi
  (
    set +u
    # shellcheck source=/dev/null
    . "$rc"
    export OS_REGION_NAME="$region"
    set -u
    openstack "$@"
  )
}

source_swift_export_with_resume() {
  local image_file="$1"
  local image_id="$2"
  local source_json="$RUN_DIR/source_image.json"
  local source_token source_project_id source_swift_url source_swift_catalog
  local head_headers head_status_file candidate_url source_swift_size
  local expected_size actual_size attempt attempts wait_s rc err_tail

  [[ -s "$source_json" ]] || return 2

  source_token="$(
    set +u
    # shellcheck source=/dev/null
    . "$SOURCE_OPENRC"
    export OS_REGION_NAME="$SOURCE_REGION"
    openstack token issue -f value -c id 2>/dev/null | head -1
  )"
  source_project_id="$(
    set +u
    # shellcheck source=/dev/null
    . "$SOURCE_OPENRC"
    printf '%s' "${OS_PROJECT_ID:-${OS_TENANT_ID:-}}"
  )"
  source_swift_catalog="$RUN_DIR/source-swift-catalog.json"
  source_swift_url=""
  if (
    set +u
    # shellcheck source=/dev/null
    . "$SOURCE_OPENRC"
    export OS_REGION_NAME="$SOURCE_REGION"
    openstack catalog show object-store -f json >"$source_swift_catalog" 2>"$RUN_DIR/source-swift-catalog.err"
  ); then
    source_swift_url="$(python3 - "$SOURCE_REGION" "$source_swift_catalog" <<'PY' || true
import json, sys
region = sys.argv[1].upper()
try:
    data = json.load(open(sys.argv[2]))
except Exception:
    sys.exit(0)
for ep in data.get("endpoints", []):
    iface = str(ep.get("interface", "")).lower()
    ep_region = str(ep.get("region", ep.get("region_id", ""))).upper()
    if iface == "public" and ep_region == region:
        print(str(ep.get("url", "")).rstrip("/"))
        break
PY
)"
  fi
  source_swift_url="${source_swift_url%/}"
  if [[ -z "$source_swift_url" && -n "$source_project_id" ]]; then
    region_lc="$(printf '%s' "$SOURCE_REGION" | tr '[:upper:]' '[:lower:]')"
    source_swift_url="https://swift.api.${region_lc}.rackspacecloud.com/v1/AUTH_${source_project_id}"
  fi

  if [[ -z "$source_token" || -z "$source_swift_url" ]]; then
    log "[WARN] source Swift export unavailable: token or Swift endpoint missing"
    return 2
  fi

  head_headers="$RUN_DIR/source-swift.head.headers"
  head_status_file="$RUN_DIR/source-swift.head.http"
  candidate_url=""
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    : > "$head_headers"
    printf '' > "$head_status_file"
    curl -sS -I "$candidate" \
      -H "X-Auth-Token: $source_token" \
      --write-out "%{http_code}" \
      -o "$head_headers" >"$head_status_file" 2>"$RUN_DIR/source-swift.head.err" || true
    head_status="$(cat "$head_status_file" 2>/dev/null || true)"
    if [[ "$head_status" =~ ^(200|204)$ ]]; then
      candidate_url="$candidate"
      break
    fi
    log "[WARN] source Swift candidate not available http=${head_status:-none}: $candidate"
  done < <(
    SOURCE_SWIFT_URL="$source_swift_url" SOURCE_IMAGE_ID="$image_id" python3 - "$source_json" <<'PY'
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

  [[ -n "$candidate_url" ]] || return 2

  source_swift_size="$(awk 'BEGIN{IGNORECASE=1} /^Content-Length:/ {gsub("\r","",$2); print $2; exit}' "$head_headers" 2>/dev/null || true)"
  expected_size="$(python3 - "$source_json" <<'PY' 2>/dev/null || true
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("size") or "")
except Exception:
    print("")
PY
)"
  if [[ -z "$expected_size" && "$source_swift_size" =~ ^[0-9]+$ ]]; then
    expected_size="$source_swift_size"
  fi
  log "[LS3] source Swift object selected: $candidate_url size=${source_swift_size:-unknown}"

  attempts="${FLEX2FLEX_SWIFT_DOWNLOAD_ATTEMPTS:-12}"
  wait_s="${FLEX2FLEX_SWIFT_DOWNLOAD_RETRY_WAIT:-10}"
  for attempt in $(seq 1 "$attempts"); do
    actual_size="$(stat -c%s "$image_file" 2>/dev/null || echo 0)"
    if [[ "$expected_size" =~ ^[0-9]+$ && "$actual_size" -gt "$expected_size" ]]; then
      log "[WARN] existing Swift download is larger than expected; restarting file"
      rm -f -- "$image_file"
      actual_size=0
    fi
    if [[ "$expected_size" =~ ^[0-9]+$ && "$actual_size" -eq "$expected_size" && "$actual_size" -gt 0 ]]; then
      if qemu-img info "$image_file" >/dev/null 2>&1; then
        log "[LS3] HIT source Swift export: $image_file ($actual_size bytes)"
        return 0
      fi
      log "[WARN] source Swift export has expected size but qemu-img validation failed; restarting"
      rm -f -- "$image_file"
    fi

    log "[LS3] downloading source Swift object attempt $attempt/$attempts resume_from=$actual_size"
    set +e
    curl --http1.1 -fL \
      -C - \
      --retry 6 \
      --retry-delay 8 \
      --retry-connrefused \
      --connect-timeout 30 \
      --speed-time 300 \
      --speed-limit 1024 \
      -H "X-Auth-Token: $source_token" \
      -H "Accept: application/octet-stream" \
      "$candidate_url" \
      -o "$image_file" >"$RUN_DIR/source-swift-download.out" 2>"$RUN_DIR/source-swift-download.err"
    rc=$?
    set -e

    actual_size="$(stat -c%s "$image_file" 2>/dev/null || echo 0)"
    if [[ "$rc" -eq 0 && "$actual_size" -gt 0 ]]; then
      if [[ "$expected_size" =~ ^[0-9]+$ && "$actual_size" -ne "$expected_size" ]]; then
        log "[WARN] source Swift download size mismatch expected=$expected_size actual=$actual_size"
      elif qemu-img info "$image_file" >/dev/null 2>&1; then
        log "[LS3] HIT source Swift export: $image_file ($actual_size bytes)"
        return 0
      else
        log "[WARN] source Swift download completed but qemu-img validation failed"
      fi
    else
      err_tail="$(tail -c 800 "$RUN_DIR/source-swift-download.err" 2>/dev/null | tr '\n' ' ')"
      log "[WARN] source Swift download failed attempt $attempt/$attempts rc=$rc: ${err_tail:-no stderr}"
    fi
    [[ "$attempt" -lt "$attempts" ]] && sleep "$wait_s"
  done

  return 1
}

flex_local_block_disks() {
  sudo lsblk -dnpo NAME,TYPE 2>/dev/null \
    | awk '$2=="disk" && $1 !~ /^\/dev\/(nbd|loop|sr|fd)/ {print $1}' \
    | sort
}

flex_find_new_block_disk() {
  local before_file="$1" after_file="$2"
  comm -13 "$before_file" "$after_file" | while IFS= read -r candidate; do
    [[ -b "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    break
  done | head -1
}

source_flex_helper_server_id() {
  local ips_json hostname_text server_json
  hostname_text="$(hostname 2>/dev/null || true)"
  ips_json="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk 'NF' | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  server_json="$(
    set +u
    # shellcheck source=/dev/null
    . "$SOURCE_OPENRC"
    export OS_REGION_NAME="$SOURCE_REGION"
    set -u
    openstack server list --long -f json 2>/dev/null || true
  )"
  LOCAL_IPS_JSON="$ips_json" LOCAL_HOSTNAME="$hostname_text" SERVER_JSON="$server_json" python3 - <<'PY'
import json, os
try:
    rows = json.loads(os.environ.get("SERVER_JSON") or "[]")
except Exception:
    rows = []
try:
    ips = json.loads(os.environ.get("LOCAL_IPS_JSON") or "[]")
except Exception:
    ips = []
host = (os.environ.get("LOCAL_HOSTNAME") or "").lower()
for row in rows:
    blob = json.dumps(row).lower()
    if any(ip and ip.lower() in blob for ip in ips):
        print(row.get("ID") or row.get("Id") or row.get("id") or "")
        raise SystemExit
if host:
    for row in rows:
        name = str(row.get("Name") or row.get("name") or "").lower()
        if host == name or host in name or name in host:
            print(row.get("ID") or row.get("Id") or row.get("id") or "")
            raise SystemExit
PY
}

source_image_looks_windows() {
  local haystack="$safe_label $LABEL"
  if [[ -s "$RUN_DIR/source_image.json" ]]; then
    haystack="$haystack $(cat "$RUN_DIR/source_image.json" 2>/dev/null || true)"
  fi
  printf '%s' "$haystack" | grep -qiE 'windows|snapwin|win2012|win2016|win2019|win2022|virtio-ready'
}

source_image_prefers_cinder_export() {
  [[ "${FLEX2FLEX_ENABLE_CINDER_IMAGE_EXPORT:-0}" == "1" ]] && return 0
  source_image_looks_windows && return 0
  return 1
}

source_image_cinder_size_gb() {
  local image_id="$1" meta_json="$RUN_DIR/source_image.json"
  if [[ ! -s "$meta_json" ]]; then
    meta_json="$RUN_DIR/source_image_for_cinder.json"
    (
      set +u
      # shellcheck source=/dev/null
      . "$SOURCE_OPENRC"
      export OS_REGION_NAME="$SOURCE_REGION"
      set -u
      openstack image show "$image_id" -f json
    ) >"$meta_json"
  fi
  python3 - "$meta_json" "$(source_image_looks_windows && echo 1 || echo 0)" <<'PY'
import json, math, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
size = int(d.get("size") or 0)
min_disk = int(d.get("min_disk") or 0)
virtual = int(d.get("virtual_size") or 0)
gb = max(1, min_disk, math.ceil(size / (1024**3)), math.ceil(virtual / (1024**3)) if virtual else 0)
if sys.argv[2] == "1":
    gb = max(gb, int(__import__("os").environ.get("FLEX2FLEX_WINDOWS_CINDER_MIN_GB", "80")))
print(gb)
PY
}

source_volume_status() {
  local volume_id="$1"
  (
    set +u
    # shellcheck source=/dev/null
    . "$SOURCE_OPENRC"
    export OS_REGION_NAME="$SOURCE_REGION"
    set -u
    openstack volume show "$volume_id" -f value -c status 2>/dev/null || true
  ) | tail -1 | tr '[:upper:]' '[:lower:]' | tr -d '\r'
}

wait_source_volume_status() {
  local volume_id="$1" want="$2" timeout="${3:-1800}" waited=0 status
  while [[ "$waited" -lt "$timeout" ]]; do
    status="$(source_volume_status "$volume_id")"
    [[ "$status" == "$want" ]] && return 0
    [[ "$status" == "error" ]] && return 1
    sleep 5
    waited=$((waited + 5))
    if (( waited % 30 == 0 )); then
      log "[LS3B] waiting for source temp volume=$volume_id status=${status:-unknown} want=$want waited=${waited}s"
    fi
  done
  return 1
}

source_flex_cinder_image_raw_export() {
  local image_id="$1" dest="$2"
  local helper_id volume_size volume_name volume_id before_file after_file dev tmp_qcow rc
  local attached=0

  helper_id="$(source_flex_helper_server_id | head -1 | tr -d '[:space:]')"
  if [[ -z "$helper_id" ]]; then
    log "[WARN] Cinder image export skipped: this jumphost could not be matched to a source FLEX server"
    return 1
  fi
  volume_size="$(source_image_cinder_size_gb "$image_id" | tail -1 | tr -d '[:space:]')"
  [[ "$volume_size" =~ ^[0-9]+$ ]] || volume_size="80"
  volume_name="${safe_label}-f2f-cinder-image-export-${RUN_ID}"
  before_file="$RUN_DIR/cinder-before-disks.txt"
  after_file="$RUN_DIR/cinder-after-disks.txt"
  tmp_qcow="${dest}.cinder.tmp"

  stage "R3.3B_SOURCE_CINDER_IMAGE_VOLUME_EXPORT"
  log "[LS3B] START Windows/Cinder fallback: source image -> temp source FLEX volume -> qcow2 artifact"
  log "[LS3B] helper_server_id=$helper_id image=$image_id volume_size=${volume_size}GB"
  flex_local_block_disks >"$before_file"

  set +e
  volume_id="$(
    set +u
    # shellcheck source=/dev/null
    . "$SOURCE_OPENRC"
    export OS_REGION_NAME="$SOURCE_REGION"
    set -u
    openstack volume create --image "$image_id" --size "$volume_size" "$volume_name" -f value -c id
  )"
  rc=$?
  set -e
  volume_id="$(printf '%s' "$volume_id" | tail -1 | tr -d '[:space:]')"
  if [[ "$rc" -ne 0 || -z "$volume_id" ]]; then
    log "[WARN] Cinder image export could not create source temp volume rc=$rc"
    return 1
  fi
  log "[LS3B] created source temp volume=$volume_id name=$volume_name"

  if ! wait_source_volume_status "$volume_id" "available" "${FLEX2FLEX_CINDER_VOLUME_WAIT:-3600}"; then
    log "[WARN] Cinder image export temp volume did not become available"
    (
      set +u; . "$SOURCE_OPENRC"; export OS_REGION_NAME="$SOURCE_REGION"; set -u
      openstack volume delete "$volume_id" >/dev/null 2>&1 || true
    )
    return 1
  fi

  if ! (
    set +u
    # shellcheck source=/dev/null
    . "$SOURCE_OPENRC"
    export OS_REGION_NAME="$SOURCE_REGION"
    set -u
    openstack server add volume "$helper_id" "$volume_id"
  ); then
    log "[WARN] Cinder image export could not attach temp volume to source jumphost"
    (
      set +u; . "$SOURCE_OPENRC"; export OS_REGION_NAME="$SOURCE_REGION"; set -u
      openstack volume delete "$volume_id" >/dev/null 2>&1 || true
    )
    return 1
  fi
  attached=1
  wait_source_volume_status "$volume_id" "in-use" 900 || true

  dev=""
  for _i in $(seq 1 80); do
    sleep 3
    flex_local_block_disks >"$after_file"
    dev="$(flex_find_new_block_disk "$before_file" "$after_file" || true)"
    [[ -n "$dev" ]] && break
  done
  if [[ -z "$dev" ]]; then
    log "[WARN] Cinder image export could not detect attached source block device"
    rc=1
  else
    log "[LS3B] detected source block device: $dev"
    rm -f -- "$dest" "$tmp_qcow"
    set +e
    sudo env "PATH=$PATH" qemu-img convert -p -f raw -O qcow2 "$dev" "$tmp_qcow" >"$RUN_DIR/cinder-qcow-convert.out" 2>"$RUN_DIR/cinder-qcow-convert.err"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 && -s "$tmp_qcow" ]] && qemu-img info "$tmp_qcow" >/dev/null 2>&1; then
      sudo chown "$(id -u):$(id -g)" "$tmp_qcow" 2>/dev/null || true
      mv -f "$tmp_qcow" "$dest"
      log "[LS3B] HIT Cinder image export qcow2 artifact: $dest ($(stat -c%s "$dest" 2>/dev/null || echo 0) bytes)"
      rc=0
    else
      log "[WARN] Cinder image export qemu-img convert failed rc=$rc: $(tail -c 800 "$RUN_DIR/cinder-qcow-convert.err" 2>/dev/null | tr '\n' ' ')"
      rc=1
    fi
  fi

  if [[ "$attached" -eq 1 ]]; then
    (
      set +u; . "$SOURCE_OPENRC"; export OS_REGION_NAME="$SOURCE_REGION"; set -u
      openstack server remove volume "$helper_id" "$volume_id" >/dev/null 2>&1 || true
    )
    wait_source_volume_status "$volume_id" "available" 900 || true
  fi
  if [[ "${FLEX2FLEX_KEEP_CINDER_EXPORT_VOLUME:-0}" != "1" ]]; then
    (
      set +u; . "$SOURCE_OPENRC"; export OS_REGION_NAME="$SOURCE_REGION"; set -u
      openstack volume delete "$volume_id" >/dev/null 2>&1 || true
    )
  else
    log "[LS3B] keeping source temp Cinder export volume by request: $volume_id"
  fi
  return "$rc"
}

export_source_image_with_retry() {
  local image_file="$1"
  local image_id="$2"
  local attempts="${FLEX2FLEX_IMAGE_SAVE_ATTEMPTS:-4}"
  local wait_s="${FLEX2FLEX_IMAGE_SAVE_RETRY_WAIT:-20}"
  local attempt rc err_tail image_bytes cinder_rc
  local err_file="$RUN_DIR/source-image-save.err"

  image_bytes="$(python3 - "$RUN_DIR/source_image.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("size") or "")
except Exception:
    print("")
PY
)"

  if [[ -s "$image_file" ]] && qemu-img info "$image_file" >/dev/null 2>&1; then
    log "[LS3] RESUME: existing source export looks valid: $image_file ($(stat -c%s "$image_file" 2>/dev/null || echo 0) bytes)"
    return 0
  fi

  set +e
  source_swift_export_with_resume "$image_file" "$image_id"
  swift_rc=$?
  set -e
  if [[ "$swift_rc" -eq 0 ]]; then
    return 0
  fi
  if [[ "$swift_rc" -eq 1 ]]; then
    log "[WARN] source Swift resumable export failed; falling back to openstack image save"
  else
    log "[WARN] source Swift resumable export not available; falling back to openstack image save"
  fi

  if source_image_prefers_cinder_export; then
    log "[LS3] Windows/Cinder export fallback enabled; trying source FLEX volume-from-image raw stream before repeated Glance download attempts"
    set +e
    source_flex_cinder_image_raw_export "$image_id" "$image_file"
    cinder_rc=$?
    set -e
    if [[ "$cinder_rc" -eq 0 ]]; then
      return 0
    fi
    log "[WARN] source FLEX Cinder image export fallback failed rc=$cinder_rc; continuing to openstack image save"
  fi

  for attempt in $(seq 1 "$attempts"); do
    [[ "$attempt" -gt 1 ]] && log "[LS3] retrying source image export attempt $attempt/$attempts after previous failure"
    rm -f -- "$err_file"
    set +e
    (
      set +u
      # shellcheck source=/dev/null
      . "$SOURCE_OPENRC"
      export OS_REGION_NAME="$SOURCE_REGION"
      set -u
      openstack image save --file "$image_file" "$image_id"
    ) 2>"$err_file"
    rc=$?
    set -e

    if [[ "$rc" -eq 0 ]] && [[ -s "$image_file" ]] && qemu-img info "$image_file" >/dev/null 2>&1; then
      if [[ -n "$image_bytes" ]]; then
        actual_bytes="$(stat -c%s "$image_file" 2>/dev/null || echo 0)"
        if [[ "$actual_bytes" -lt "$image_bytes" ]]; then
          log "[WARN] source export attempt $attempt/$attempts produced smaller file than source metadata: got=$actual_bytes expected=$image_bytes"
          rc=97
        else
          log "[LS3] HIT source image export: $image_file ($actual_bytes bytes)"
          return 0
        fi
      else
        log "[LS3] HIT source image export: $image_file ($(stat -c%s "$image_file" 2>/dev/null || echo 0) bytes)"
        return 0
      fi
    fi

    err_tail="$(tail -c 1200 "$err_file" 2>/dev/null | tr '\n' ' ')"
    log "[WARN] source image export failed attempt $attempt/$attempts rc=$rc: ${err_tail:-no stderr}"
    if [[ "$attempt" -lt "$attempts" ]]; then
      sleep "$wait_s"
      rm -f -- "$image_file"
    fi
  done

  log "[ERROR] source image export failed after $attempts attempts"
  log "ICF Issue=Flex2Flex source Glance export failed"
  log "ICF Cause=openstack image save could not complete; Rackspace closed the download stream or returned an incomplete image body"
  log "ICF Fix=rerun START FRESH; if repeated, reduce batch concurrency or retry this large image by itself"
  write_plan "failed" "Source Flex Glance export failed" "openstack image save failed after $attempts attempts" "Retry START FRESH; reduce concurrent image jobs for large Windows images."
  exit 1
}

read_os_json() {
  local rc="$1"; shift
  local region="$1"; shift
  local desc="$1"; shift
  local out_file err_file cmd_rc err_tail
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] $desc: openstack $* -f json"
    printf '{}\n'
    return 0
  fi
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  set +e
  (
    set +u
    # shellcheck source=/dev/null
    . "$rc"
    export OS_REGION_NAME="$region"
    set -u
    openstack "$@" -f json
  ) >"$out_file" 2>"$err_file"
  cmd_rc=$?
  set -e
  if [[ "$cmd_rc" -ne 0 ]]; then
    err_tail="$(tail -c 600 "$err_file" 2>/dev/null | tr '\n' ' ')"
    printf '[%s][%s][R3-F2F] [WARN] %s failed rc=%s: %s\n' "$(date +%H:%M:%S)" "$safe_label" "$desc" "$cmd_rc" "${err_tail:-no stderr}" >&2
    printf '{}\n'
  else
    cat "$out_file"
  fi
  rm -f "$out_file" "$err_file"
  return 0
}

stage "R3.0_PREFLIGHT"
start_fresh_clear_label_resume
require_file "$SOURCE_OPENRC" "source Flex OpenRC"
require_file "$TARGET_OPENRC" "target Flex OpenRC"
if [[ -z "$SOURCE_REGION" || -z "$TARGET_REGION" ]]; then
  write_plan "failed" "Source/target region missing" "R3 FLEX2FLEX needs explicit Flex source and target regions." "Set source and target regions in the dashboard."
  log "[ERROR] source-region and target-region are required"
  exit 1
fi
if [[ "$SOURCE_REGION" == "$TARGET_REGION" ]]; then
  log "[WARN] source and target region are the same; this will behave like an in-region copy plan."
fi
if [[ -z "$SOURCE_SERVER_ID" && -z "$SOURCE_IMAGE_ID" ]]; then
  write_plan "failed" "No source server or image selected" "R3 FLEX2FLEX needs an existing Flex server ID or Glance image/snapshot ID." "Enter source server ID or source image ID."
  log "[ERROR] source-server-id or source-image-id required"
  exit 1
fi
if [[ -z "$TARGET_IMAGE_NAME" ]]; then
  TARGET_IMAGE_NAME="${safe_label}-r3-f2f-${SOURCE_REGION}-to-${TARGET_REGION}-${RUN_ID}"
fi
log "workflow_id=flex2flex_region_migration run_id=$RUN_ID"
log "source=$SOURCE_REGION target=$TARGET_REGION dry_run=$DRY_RUN preserve_source=true"
log "clone_method=snapshot_migration_glance_save_import"
log "Snapshot method: source server snapshot or existing Glance image -> openstack image save -> target openstack image create."
log "No Xen-to-KVM repair, no VirtIO conversion, no source cleanup."

stage "R3.1_SOURCE_INVENTORY"
if [[ -n "$SOURCE_SERVER_ID" ]]; then
  read_os_json "$SOURCE_OPENRC" "$SOURCE_REGION" "[READ] source server inventory: $SOURCE_SERVER_ID" server show "$SOURCE_SERVER_ID" > "$RUN_DIR/source_server.json"
  read_os_json "$SOURCE_OPENRC" "$SOURCE_REGION" "[READ] attached volumes for source server: $SOURCE_SERVER_ID" volume list --server "$SOURCE_SERVER_ID" > "$RUN_DIR/source_volumes.json"
else
  log "[READ] source server inventory skipped; source-image-id supplied."
fi
if [[ -n "$SOURCE_IMAGE_ID" ]]; then
  read_os_json "$SOURCE_OPENRC" "$SOURCE_REGION" "[READ] source image inventory: $SOURCE_IMAGE_ID" image show "$SOURCE_IMAGE_ID" > "$RUN_DIR/source_image.json"
fi

stage "R3.2_SNAPSHOT_CAPTURE_OR_SELECT"
if [[ -z "$SOURCE_IMAGE_ID" ]]; then
  SNAP_NAME="${safe_label}-r3-f2f-source-snapshot-${RUN_ID}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] Would create source Flex instance snapshot using snapshot migration method: $SNAP_NAME from $SOURCE_SERVER_ID"
    SOURCE_IMAGE_ID="DRYRUN_SOURCE_IMAGE_FROM_${SOURCE_SERVER_ID}"
  else
    SOURCE_IMAGE_ID="$(
      set +u
      # shellcheck source=/dev/null
      . "$SOURCE_OPENRC"
      export OS_REGION_NAME="$SOURCE_REGION"
      set -u
      openstack server image create --name "$SNAP_NAME" --wait "$SOURCE_SERVER_ID" -f value -c id 2>/dev/null \
        || openstack server image create --name "$SNAP_NAME" --wait "$SOURCE_SERVER_ID" -f value -c image_id 2>/dev/null \
        || openstack server image create --name "$SNAP_NAME" "$SOURCE_SERVER_ID" -f value -c id 2>/dev/null \
        || openstack server image create --name "$SNAP_NAME" "$SOURCE_SERVER_ID" -f value -c image_id 2>/dev/null \
        || openstack image list --name "$SNAP_NAME" -f value -c ID 2>/dev/null | head -1
    )"
    SOURCE_IMAGE_ID="$(printf '%s' "$SOURCE_IMAGE_ID" | tail -1 | tr -d '[:space:]')"
    if [[ -z "$SOURCE_IMAGE_ID" ]]; then
      write_plan "failed" "Source snapshot creation failed" "OpenStack did not return a source image ID." "Check server status and source region credentials, then retry R3 FLEX2FLEX."
      log "[ERROR] source snapshot creation failed"
      exit 1
    fi
  fi
else
  log "Using existing source image/snapshot ID for snapshot migration method: $SOURCE_IMAGE_ID"
fi

stage "R3.3_EXPORT_SOURCE_SNAPSHOT_IMAGE"
IMAGE_FILE="$ARTIFACT_DIR/${safe_label}-${SOURCE_IMAGE_ID}.img"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[DRY-RUN] Would export source image: openstack image save --file $IMAGE_FILE $SOURCE_IMAGE_ID"
else
  export_source_image_with_retry "$IMAGE_FILE" "$SOURCE_IMAGE_ID"
  qemu-img info "$IMAGE_FILE" | tee "$RUN_DIR/qemu-img-info.txt"
fi

stage "R3.4_IMPORT_TARGET_GLANCE"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[DRY-RUN] Would import to target Glance in $TARGET_REGION as $TARGET_IMAGE_NAME"
  TARGET_IMAGE_ID="DRYRUN_TARGET_IMAGE_${RUN_ID}"
else
  image_create_timeout="${FLEX2FLEX_IMAGE_CREATE_TIMEOUT:-21600}"
  image_create_out="$RUN_DIR/target-image-create.out"
  image_create_err="$RUN_DIR/target-image-create.err"
  image_bytes="$(stat -c%s "$IMAGE_FILE" 2>/dev/null || printf 'unknown')"
  log "[UPLOAD] target Glance image create: region=$TARGET_REGION bytes=$image_bytes timeout=${image_create_timeout}s"
  set +e
  (
    set +u
    # shellcheck source=/dev/null
    . "$TARGET_OPENRC"
    export OS_REGION_NAME="$TARGET_REGION"
    set -u
    timeout "$image_create_timeout" openstack image create "$TARGET_IMAGE_NAME" \
      --file "$IMAGE_FILE" \
      --disk-format qcow2 \
      --container-format bare \
      --private \
      --property migrated_by=ospc2flex \
      --property migrated_workflow=flex2flex_region_migration \
      --property migrated_from_region="$SOURCE_REGION" \
      --property migrated_from_image_id="$SOURCE_IMAGE_ID" \
      -f value -c id
  ) >"$image_create_out" 2>"$image_create_err"
  image_create_rc=$?
  set -e
  if [[ "$image_create_rc" -ne 0 ]]; then
    err_tail="$(tail -c 1200 "$image_create_err" 2>/dev/null | tr '\n' ' ')"
    [[ "$image_create_rc" -eq 124 ]] && err_tail="target Glance upload timed out after ${image_create_timeout}s ${err_tail}"
    log "[ERROR] target Glance upload failed rc=$image_create_rc: ${err_tail:-no stderr}"
    (
      set +u
      # shellcheck source=/dev/null
      . "$TARGET_OPENRC"
      export OS_REGION_NAME="$TARGET_REGION"
      set -u
      stale_target_id="$(openstack image list --private --name "$TARGET_IMAGE_NAME" -f value -c ID 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
      if [[ -n "$stale_target_id" ]]; then
        log "[UPLOAD] deleting incomplete target image after failed upload: $stale_target_id"
        openstack image delete "$stale_target_id" >/dev/null 2>&1 || true
      fi
    ) || true
    log "ICF Issue=Flex2Flex target Glance import failed"
    log "ICF Cause=openstack image create --file did not complete successfully for target region $TARGET_REGION"
    log "ICF Fix=retry START FRESH; if repeated, verify target Glance upload quota/service health or use a smaller/active source image"
    write_plan "failed" "Target Flex Glance upload failed" "openstack image create --file exited rc=$image_create_rc" "Retry START FRESH after validating target Glance service/quota."
    exit 1
  fi
  TARGET_IMAGE_ID="$(grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$image_create_out" | tail -1 || true)"
  if [[ -z "$TARGET_IMAGE_ID" ]]; then
    TARGET_IMAGE_ID="$(tail -1 "$image_create_out" | tr -d '[:space:]')"
  fi
  if [[ -z "$TARGET_IMAGE_ID" ]]; then
    log "[ERROR] target Glance upload returned success but no target image id was captured"
    log "ICF Issue=Flex2Flex target image id missing"
    log "ICF Cause=openstack image create output did not contain a UUID"
    log "ICF Fix=check $image_create_out and rerun START FRESH"
    write_plan "failed" "Target image id missing" "openstack image create returned no parseable image id" "Check target-image-create.out and rerun."
    exit 1
  fi
  log "Target image ID: $TARGET_IMAGE_ID"
fi

stage "R3.5_VOLUME_AND_DB_PLAN"
log "Attached Cinder volumes are source-preserved. Use the existing Volume-Snapshot-Mig stream path for data volumes."
log "DB plan: prefer logical backup plus volume snapshot; no DB stop/promotion/cutover is automatic in R3 FLEX2FLEX."
cat > "$RUN_DIR/volume_db_plan.md" <<MD
# R3 FLEX2FLEX Volume and DB Plan

1. Preserve source server, source volumes, source snapshots, and source images.
2. For attached data volumes, reuse the existing Volume-Snapshot-Mig direct stream path.
3. For PostgreSQL/MySQL/MariaDB, run logical backup before volume snapshot when application consistency matters.
4. Replica promotion, DNS, floating IP, and load balancer cutover require explicit operator action.
MD

stage "R3.6_OPTIONAL_TARGET_BOOT"
if [[ "$BOOT_TARGET" -eq 1 ]]; then
  if [[ -z "$TARGET_FLAVOR" || -z "$TARGET_NETWORK" ]]; then
    log "[WARN] boot-target requested but target flavor/network missing; boot plan only."
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] Would boot target server from $TARGET_IMAGE_ID flavor=$TARGET_FLAVOR network=$TARGET_NETWORK key=$TARGET_KEY_NAME"
  else
    if ! run_os "$TARGET_OPENRC" "$TARGET_REGION" "validate target flavor" flavor show "$TARGET_FLAVOR" >/dev/null 2>&1; then
      mapped_flavor=""
      if [[ "$TARGET_FLAVOR" == gp.0.* ]]; then
        mapped_flavor="${TARGET_FLAVOR/gp.0./gp.5.}"
      fi
      if [[ -n "$mapped_flavor" ]] && run_os "$TARGET_OPENRC" "$TARGET_REGION" "validate mapped target flavor" flavor show "$mapped_flavor" >/dev/null 2>&1; then
        log "[BOOT] target flavor '$TARGET_FLAVOR' not found; using mapped FLEX flavor '$mapped_flavor'"
        TARGET_FLAVOR="$mapped_flavor"
      elif run_os "$TARGET_OPENRC" "$TARGET_REGION" "validate fallback target flavor" flavor show gp.5.4.4 >/dev/null 2>&1; then
        log "[BOOT] target flavor '$TARGET_FLAVOR' not found; using fallback FLEX flavor 'gp.5.4.4'"
        TARGET_FLAVOR="gp.5.4.4"
      else
        log "[WARN] target flavor '$TARGET_FLAVOR' not found and no fallback flavor available; boot skipped."
        TARGET_FLAVOR=""
      fi
    fi

    if [[ -n "$TARGET_KEY_NAME" ]] && ! run_os "$TARGET_OPENRC" "$TARGET_REGION" "validate target keypair" keypair show "$TARGET_KEY_NAME" >/dev/null 2>&1; then
      fallback_key="$(
        (
          set +u
          # shellcheck source=/dev/null
          . "$TARGET_OPENRC"
          export OS_REGION_NAME="$TARGET_REGION"
          set -u
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
      boot_cmd=(server create "${safe_label}-r3-f2f-${TARGET_REGION}-${RUN_ID}" --image "$TARGET_IMAGE_ID" --flavor "$TARGET_FLAVOR" --network "$TARGET_NETWORK" --wait)
      [[ -n "$TARGET_KEY_NAME" ]] && boot_cmd+=(--key-name "$TARGET_KEY_NAME")
      run_os "$TARGET_OPENRC" "$TARGET_REGION" "boot target instance" "${boot_cmd[@]}"
    fi
  fi
else
  log "Target boot skipped. R3 FLEX2FLEX produced image/plan only."
fi

stage "R3.7_VALIDATE_PLAN"
log "Validation plan: target image active, target instance ACTIVE if booted, volumes attached, DB service checks, app smoke test."
if [[ "$DRY_RUN" -eq 0 && -n "${TARGET_IMAGE_ID:-}" ]]; then
  read_os_json "$TARGET_OPENRC" "$TARGET_REGION" "[READ] target image status: $TARGET_IMAGE_ID" image show "$TARGET_IMAGE_ID" > "$RUN_DIR/target_image.json"
fi

stage "R3.8_REPORT_AND_ROLLBACK"
write_plan "planned" "Flex2Flex R3 snapshot clone plan generated" "Region-to-region cloning uses the proven snapshot migration image export/import method." "Review plan, run live image import only when ready, then validate before cutover."
log "Reports written:"
log "  $PLAN_JSON"
log "  $REPORT_MD"
log "R3 FLEX2FLEX-Region Cloning complete. Source resources were not deleted, stopped, detached, promoted, or cut over."
