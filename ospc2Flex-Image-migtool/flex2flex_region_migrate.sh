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
FLOATING_IP=""
DRY_RUN=1
BOOT_TARGET=0
START_FRESH=0
WINDOWS_METHOD_Z_SCRIPT="${FLEX2FLEX_WINDOWS_METHOD_Z_SCRIPT:-/tmp/ospc2flex_windows_method_z_snapshot_existing.sh}"
WINDOWS_METHOD_Z_REPAIR="${FLEX2FLEX_WINDOWS_METHOD_Z_REPAIR:-auto}"
WINDOWS_METHOD_Z_COMPLETED=0
METHOD_Z_RESULT_JSON=""
TARGET_SERVER_ID=""

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
  --floating-ip IP   Reuse this existing floating IP: detach it from any old port, then attach to the new VM
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
    --floating-ip) FLOATING_IP="${2:-}"; shift 2 ;;
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

  local before after avail_kb min_kb win_mmin
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

  avail_kb="$(df -Pk "$RUN_ROOT" 2>/dev/null | awk 'NR==2{print $4+0}' || echo 0)"
  if [[ "${FLEX2FLEX_WINDOWS_AGGRESSIVE_CLEANUP:-0}" == "1" && "${avail_kb:-0}" -lt "$min_kb" ]]; then
    win_mmin="${FLEX2FLEX_WINDOWS_CLEANUP_AGE_MIN:-60}"
    [[ "$win_mmin" =~ ^[0-9]+$ ]] || win_mmin=60
    early_log "[LS0A] Windows cleanup: pruning stale flex2flex runs older than ${win_mmin}m"
    find "$RUN_ROOT" -mindepth 1 -maxdepth 1 -type d -mmin +"$win_mmin" ! -name "$safe_run_dir" -print 2>/dev/null | sort | while read -r old_run; do
      [[ -n "$old_run" ]] || continue
      case "$old_run" in
        "$RUN_ROOT"/*)
          early_log "[LS0A] delete Windows stale run: $old_run"
          rm -rf -- "$old_run"
          ;;
        *)
          early_log "[LS0A] skip unsafe stale run path: $old_run"
          ;;
      esac
    done
  fi

  after="$(df -hP "$RUN_ROOT" 2>/dev/null | awk 'NR==2{print $4 " free / " $2 " total (" $5 " used)"}' || true)"
  early_log "[LS0A] run root disk after cleanup: ${after:-unknown}"
}

cleanup_stale_jumphost_images() {
  [[ "${FLEX2FLEX_CLEAN_STALE_IMAGES:-1}" == "1" ]] || {
    early_log "[LS0A] stale image cleanup disabled"
    return 0
  }

  local min_age_minutes="${FLEX2FLEX_CLEAN_MIN_AGE_MIN:-60}"
  [[ "$min_age_minutes" =~ ^[0-9]+$ ]] || min_age_minutes=60

  local roots=()
  [[ -d "$RUN_ROOT" ]] && roots+=("$RUN_ROOT")
  [[ -d /mnt/migration/flex2flex ]] && roots+=("/mnt/migration/flex2flex")
  [[ -d /mnt/migration/ospc2flex_method_z ]] && roots+=("/mnt/migration/ospc2flex_method_z")
  [[ -d /mnt/migration/ospc2flex_image ]] && roots+=("/mnt/migration/ospc2flex_image")

  local delete_list="$RUN_ROOT/stale_image_delete_${safe_label}_${RUN_ID}.tsv"
  : >"$delete_list" 2>/dev/null || delete_list="/tmp/stale_image_delete_${safe_label}_${RUN_ID}.tsv"
  : >"$delete_list"

  local root root_real
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    root_real="$(readlink -f "$root" 2>/dev/null || true)"
    case "$root_real" in
      /mnt/migration|/mnt/migration/*|/tmp|/tmp/*|"$RUN_ROOT"|"$RUN_ROOT"/*) ;;
      *) early_log "[LS0A] refusing stale image cleanup outside migration/tmp root: $root"; continue ;;
    esac
    find "$root" -xdev -type f -mmin +"$min_age_minutes" \( \
        -iname "*.img" -o -iname "*.raw" -o -iname "*.vhd" -o -iname "*.vhdx" -o -iname "*.vmdk" -o -iname "*.vpc" \
        -o -iname "*repaired*.qcow2" -o -iname "*repair*.qcow2" \
        -o -iname "*flex-rescue*.qcow2" -o -iname "*safe-ide*.qcow2" -o -iname "*final*.qcow2" -o -iname "*rescue*.qcow2" \
        -o -iname "*.invalid*" -o -iname "*.partial*" \
      \) -printf '%s\t%p\n' 2>/dev/null >>"$delete_list" || true
  done

  sort -nr -u -o "$delete_list" "$delete_list" 2>/dev/null || true
  local count bytes
  count="$(wc -l <"$delete_list" | tr -d '[:space:]')"
  bytes="$(awk -F '\t' '{s+=$1} END{printf "%.0f", s+0}' "$delete_list")"
  if [[ "${count:-0}" -eq 0 ]]; then
    early_log "[LS0A] no stale image files found; keeping unrepaired qcow2 files"
    rm -f -- "$delete_list" 2>/dev/null || true
    return 0
  fi

  early_log "[LS0A] stale image cleanup candidates older than ${min_age_minutes}m: count=$count bytes=$bytes"
  local deleted=0 freed=0 sz path run_root
  while IFS=$'\t' read -r sz path; do
    [[ -n "$path" ]] || continue
    case "$(basename "$path")" in
      source_snapshot.qcow2|source_snapshot-*.qcow2)
        early_log "[LS0A] keep unrepaired source qcow2: $path"
        continue
        ;;
    esac
    case "$path" in
      "$RUN_DIR"/*|"$ARTIFACT_DIR"/*)
        early_log "[LS0A] keep current run artifact: $path"
        continue
        ;;
    esac
    run_root="$(printf '%s\n' "$path" | sed -E 's#^(/mnt/migration/flex2flex/[^/]+).*#\1#; s#^(/mnt/migration/ospc2flex_method_z/runs/[^/]+/[^/]+).*#\1#; s#^(/mnt/migration/ospc2flex_image/[^/]+).*#\1#')"
    if [[ -n "$run_root" ]] && ps -eo args= 2>/dev/null | grep -F -- "$run_root" | grep -vq grep; then
      early_log "[LS0A] keep active run artifact: $path"
      continue
    fi
    case "$path" in
      /mnt/migration/*|"$RUN_ROOT"/*|/tmp/*)
        early_log "[LS0A] delete stale image: ${sz}B $path"
        rm -f -- "$path" 2>/dev/null || sudo rm -f -- "$path" 2>/dev/null || true
        deleted=$((deleted + 1))
        freed=$((freed + ${sz:-0}))
        ;;
      *) early_log "[LS0A] skip unsafe stale image path: $path" ;;
    esac
  done <"$delete_list"
  rm -f -- "$delete_list" 2>/dev/null || true
  early_log "[LS0A] stale image cleanup complete; deleted=$deleted freed_bytes=$freed"
}

preflight_run_root_space
cleanup_stale_jumphost_images
if ! mkdir -p "$ARTIFACT_DIR" 2>/dev/null; then
  fallback_run_root="${FLEX2FLEX_FALLBACK_RUN_ROOT:-/tmp/flex2flex}"
  if [[ -n "$fallback_run_root" && "$fallback_run_root" != "$RUN_ROOT" ]]; then
    early_log "[WARN] primary run root unavailable: $RUN_ROOT; trying fallback run root: $fallback_run_root"
    RUN_ROOT="$fallback_run_root"
    RUN_DIR="$RUN_ROOT/$safe_run_dir"
    ARTIFACT_DIR="$RUN_DIR/artifacts"
    preflight_run_root_space
    cleanup_stale_jumphost_images
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
  "target_image_id": "$(printf '%s' "${TARGET_IMAGE_ID:-}" | json_escape)",
  "target_server_id": "$(printf '%s' "${TARGET_SERVER_ID:-}" | json_escape)",
  "windows_method_z": $([[ "${WINDOWS_METHOD_Z_COMPLETED:-0}" -eq 1 ]] && echo true || echo false),
  "method_z_result_json": "$(printf '%s' "${METHOD_Z_RESULT_JSON:-}" | json_escape)",
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

bytes_to_gib() {
  awk -v bytes="${1:-0}" 'BEGIN { printf "%.1fGiB", bytes / 1073741824 }'
}

ensure_source_export_space() {
  local image_file="$1"
  local expected_size="$2"
  local actual_size="${3:-0}"
  local phase="${4:-source image export}"
  local image_dir avail_kb avail_bytes remaining_bytes reserve_bytes required_bytes

  [[ "$expected_size" =~ ^[0-9]+$ ]] || return 0
  [[ "$actual_size" =~ ^[0-9]+$ ]] || actual_size=0
  if [[ "$actual_size" -gt "$expected_size" ]]; then
    actual_size=0
  fi

  reserve_bytes="${FLEX2FLEX_IMAGE_EXPORT_RESERVE_BYTES:-}"
  if ! [[ "$reserve_bytes" =~ ^[0-9]+$ ]]; then
    if should_use_windows_method_z; then
      reserve_bytes=$((40 * 1024 * 1024 * 1024))
    else
      reserve_bytes=$((8 * 1024 * 1024 * 1024))
    fi
  fi

  image_dir="$(dirname "$image_file")"
  mkdir -p "$image_dir" 2>/dev/null || true
  avail_kb="$(df -Pk "$image_dir" 2>/dev/null | awk 'NR==2{print $4+0}' || echo 0)"
  [[ "$avail_kb" =~ ^[0-9]+$ ]] || avail_kb=0
  avail_bytes=$((avail_kb * 1024))
  remaining_bytes=$((expected_size - actual_size))
  required_bytes=$((remaining_bytes + reserve_bytes))

  if [[ "$avail_bytes" -lt "$required_bytes" ]]; then
    log "[ERROR] insufficient jumphost space for $phase: free=$(bytes_to_gib "$avail_bytes") required=$(bytes_to_gib "$required_bytes") image_size=$(bytes_to_gib "$expected_size") resume_from=$(bytes_to_gib "$actual_size") reserve=$(bytes_to_gib "$reserve_bytes") path=$image_dir"
    log "ICF Issue=Flex2Flex source export cannot write image artifact"
    log "ICF Cause=jumphost migration filesystem does not have enough free space for the source image plus Windows Method Z/SNAPWIN working reserve"
    log "ICF Fix=free space under /mnt/migration/flex2flex, reduce concurrent image jobs, or point FLEX2FLEX_RUN_ROOT at a larger filesystem; then rerun START FRESH"
    write_plan "failed" "Flex2Flex source export has insufficient jumphost space" "free=$(bytes_to_gib "$avail_bytes") required=$(bytes_to_gib "$required_bytes") at $image_dir" "Free /mnt/migration/flex2flex space or use a larger FLEX2FLEX_RUN_ROOT, then rerun START FRESH."
    return 28
  fi
  return 0
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
  local self_pgid
  self_pgid="$(ps -o pgid= -p "$self_pid" 2>/dev/null | tr -d '[:space:]' || true)"
  local pids
  if should_use_windows_method_z; then
    pids="$(
      ps -eo pid=,pgid=,cmd= 2>/dev/null | awk -v label="$safe_label" -v self="$self_pid" -v self_pgid="$self_pgid" '
        $1 != self && (self_pgid == "" || $2 != self_pgid) {
          cmd = $0
          sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", cmd)
          if ((index(cmd, "flex2flex_region_migrate.sh") && index(cmd, "--label " label)) ||
              index(cmd, "snapwin_run_" label "_") ||
              (index(cmd, "ospc2flex_windows_method_z_snapshot_existing") && index(cmd, "--label " label)) ||
              (index(cmd, "openstack image create") && index(cmd, label "-snapwin"))) {
            print $1
          }
        }
      ' | sort -u
    )"
  else
    pids="$(
      ps -eo pid=,pgid=,cmd= 2>/dev/null | awk -v label="$safe_label" -v self="$self_pid" -v self_pgid="$self_pgid" '
        $1 != self && (self_pgid == "" || $2 != self_pgid) {
          cmd = $0
          sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", cmd)
          if (index(cmd, "flex2flex_region_migrate.sh") && index(cmd, "--label " label)) {
            print $1
          }
        }
      ' | sort -u
    )"
  fi
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

attach_replacement_or_new_fip() {
  local server_id="$1"
  local replacement_ip="${2:-}"
  local ext_net="${3:-PUBLICNET}"
  local port_id fip_id fip_addr fixed
  ATTACHED_FIP=""

  [[ -n "$server_id" ]] || return 1
  port_id="$(run_os "$TARGET_OPENRC" "$TARGET_REGION" "find target server port" port list --server "$server_id" --format value -c ID 2>/dev/null | head -1 || true)"
  if [[ -z "$port_id" ]]; then
    log "[FIP][WARN] no neutron port found for target server $server_id; skipping FIP attach"
    return 1
  fi

  if [[ -n "$replacement_ip" ]]; then
    log "[FIP] replacement IP requested: $replacement_ip"
    fip_id="$(run_os "$TARGET_OPENRC" "$TARGET_REGION" "find replacement floating ip" floating ip list --format value -c ID -c 'Floating IP Address' 2>/dev/null | awk -v ip="$replacement_ip" '$2==ip{print $1; exit}' || true)"
    if [[ -z "$fip_id" ]]; then
      log "[FIP][WARN] replacement IP $replacement_ip not found in target region; falling back to new/available FIP"
    else
      fixed="$(run_os "$TARGET_OPENRC" "$TARGET_REGION" "show replacement floating ip" floating ip show "$fip_id" -f value -c fixed_ip_address 2>/dev/null || true)"
      if [[ -n "$fixed" && "$fixed" != "None" ]]; then
        log "[FIP] detaching replacement IP $replacement_ip from existing fixed IP $fixed"
        run_os "$TARGET_OPENRC" "$TARGET_REGION" "detach replacement floating ip" floating ip unset --port "$fip_id" >/dev/null 2>&1 || true
        sleep 3
      fi
      log "[FIP] attaching replacement IP $replacement_ip to new target port $port_id"
      run_os "$TARGET_OPENRC" "$TARGET_REGION" "attach replacement floating ip" floating ip set --port "$port_id" "$fip_id" >/dev/null 2>&1 || true
      sleep 5
      fixed="$(run_os "$TARGET_OPENRC" "$TARGET_REGION" "verify replacement floating ip" floating ip show "$fip_id" -f value -c fixed_ip_address 2>/dev/null || true)"
      if [[ -n "$fixed" && "$fixed" != "None" ]]; then
        log "[FIP] replacement IP attached OK: $replacement_ip -> $fixed"
        ATTACHED_FIP="$replacement_ip"
        return 0
      fi
      log "[FIP][WARN] replacement IP $replacement_ip did not attach; falling back to new/available FIP"
    fi
  fi

  fip_id="$(run_os "$TARGET_OPENRC" "$TARGET_REGION" "allocate floating ip" floating ip create "$ext_net" -f value -c id 2>/dev/null || true)"
  if [[ -z "$fip_id" ]]; then
    fip_id="$(run_os "$TARGET_OPENRC" "$TARGET_REGION" "find available floating ip" floating ip list --status DOWN --format value -c ID 2>/dev/null | head -1 || true)"
  fi
  [[ -n "$fip_id" ]] || { log "[FIP][WARN] no floating IP available"; return 1; }
  fip_addr="$(run_os "$TARGET_OPENRC" "$TARGET_REGION" "show floating ip address" floating ip show "$fip_id" -f value -c floating_ip_address 2>/dev/null || true)"
  run_os "$TARGET_OPENRC" "$TARGET_REGION" "attach floating ip" floating ip set --port "$port_id" "$fip_id" >/dev/null 2>&1 || true
  log "[FIP] floating IP attached: ${fip_addr:-$fip_id}"
  ATTACHED_FIP="${fip_addr:-$fip_id}"
}

validate_openrc_access() {
  local rc_file="$1"
  local region="$2"
  local label="$3"
  local token_out token_err service_err cmd_rc err_tail

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] Would validate $label OpenRC token and Glance access in $region"
    return 0
  fi

  token_out="$RUN_DIR/${label// /_}-token.out"
  token_err="$RUN_DIR/${label// /_}-token.err"
  service_err="$RUN_DIR/${label// /_}-image-list.err"
  rm -f -- "$token_out" "$token_err" "$service_err"

  set +e
  (
    set +u
    # shellcheck source=/dev/null
    . "$rc_file"
    export OS_REGION_NAME="$region"
    set -u
    openstack token issue -f value -c id
  ) >"$token_out" 2>"$token_err"
  cmd_rc=$?
  set -e
  if [[ "$cmd_rc" -ne 0 || ! -s "$token_out" ]]; then
    err_tail="$(tail -c 1200 "$token_err" 2>/dev/null | tr '\n' ' ')"
    log "[ERROR] $label OpenRC token validation failed region=$region rc=$cmd_rc: ${err_tail:-no stderr}"
    return 1
  fi
  log "[LS1] HIT $label OpenRC token validation region=$region"

  set +e
  (
    set +u
    # shellcheck source=/dev/null
    . "$rc_file"
    export OS_REGION_NAME="$region"
    set -u
    openstack image list -f value -c ID >/dev/null
  ) 2>"$service_err"
  cmd_rc=$?
  set -e
  if [[ "$cmd_rc" -ne 0 ]]; then
    err_tail="$(tail -c 1200 "$service_err" 2>/dev/null | tr '\n' ' ')"
    log "[ERROR] $label OpenRC Glance access failed region=$region rc=$cmd_rc: ${err_tail:-no stderr}"
    return 1
  fi
  log "[LS1] HIT $label Glance access validation region=$region"
  return 0
}

target_openstack_capture() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  (
    set +u
    # shellcheck source=/dev/null
    . "$TARGET_OPENRC"
    export OS_REGION_NAME="$TARGET_REGION"
    set -u
    openstack "$@" 2>/dev/null || true
  )
}

windows_method_z_required_disk_gb() {
  local image_file="$1"
  local info_json parsed
  [[ -s "$image_file" ]] || { printf '0\n'; return 0; }
  info_json="$(qemu-img info --output=json "$image_file" 2>/dev/null || true)"
  parsed="$(
    QEMU_IMG_INFO_JSON="$info_json" python3 - <<'PY' 2>/dev/null || true
import json, math, os
try:
    data = json.loads(os.environ.get("QEMU_IMG_INFO_JSON") or "{}")
except Exception:
    print(0)
    raise SystemExit
size = int(data.get("virtual-size") or 0)
print(int(math.ceil(size / 1073741824.0)) if size > 0 else 0)
PY
  )"
  parsed="$(printf '%s' "$parsed" | tr -dc '0-9' | head -c 12)"
  if [[ -n "$parsed" && "$parsed" != "0" ]]; then
    printf '%s\n' "$parsed"
    return 0
  fi
  qemu-img info "$image_file" 2>/dev/null |
    sed -nE 's/.*virtual size: ([0-9]+) GiB.*/\1/p' |
    head -1
}

resolve_target_flavor_for_windows_method_z() {
  local image_file="$1"
  local requested="$TARGET_FLAVOR"
  local required_disk_gb rows mapped chosen
  [[ "$DRY_RUN" -eq 1 ]] && return 0

  if [[ -n "$requested" ]] && [[ -n "$(target_openstack_capture flavor show "$requested" -f value -c id | head -1)" ]]; then
    log "[METHOD_Z] Target flavor exists in $TARGET_REGION: $requested"
    return 0
  fi
  [[ -n "$requested" ]] && log "[METHOD_Z] WARN target flavor '$requested' not found in $TARGET_REGION; resolving like OSPC2FLEX boot path."

  if [[ "$requested" == gp.0.* ]]; then
    mapped="${requested/gp.0./gp.5.}"
    if [[ -n "$(target_openstack_capture flavor show "$mapped" -f value -c id | head -1)" ]]; then
      log "[METHOD_Z] Target flavor '$requested' not found; using mapped FLEX flavor '$mapped'"
      TARGET_FLAVOR="$mapped"
      return 0
    fi
  fi

  required_disk_gb="$(windows_method_z_required_disk_gb "$image_file" | tr -dc '0-9' | head -c 12)"
  required_disk_gb="${required_disk_gb:-0}"
  rows="$(target_openstack_capture flavor list --long -f json -c ID -c Name -c RAM -c Disk -c VCPUs)"
  chosen="$(
    FLAVOR_ROWS_JSON="$rows" REQUIRED_DISK_GB="$required_disk_gb" python3 - <<'PY' 2>/dev/null || true
import json, os

def to_int(v):
    try:
        return int(str(v).strip())
    except Exception:
        return 0

try:
    rows = json.loads(os.environ.get("FLAVOR_ROWS_JSON") or "[]")
except Exception:
    rows = []
required = to_int(os.environ.get("REQUIRED_DISK_GB"))
candidates = []
for r in rows if isinstance(rows, list) else []:
    fid = str(r.get("ID") or "").strip()
    name = str(r.get("Name") or "").strip()
    ram = to_int(r.get("RAM"))
    disk = to_int(r.get("Disk"))
    vcpus = to_int(r.get("VCPUs"))
    if fid and ram > 0 and vcpus > 0:
        candidates.append({"id": fid, "name": name, "ram": ram, "disk": disk, "vcpus": vcpus})
if not candidates:
    raise SystemExit
pool = [c for c in candidates if c["disk"] > 0] or candidates
if required > 0:
    fit = [c for c in pool if c["disk"] >= required]
    pool = fit or sorted(pool, key=lambda c: c["disk"], reverse=True)
chosen = min(pool, key=lambda c: (
    c["disk"] - required if required > 0 and c["disk"] >= required else abs(c["disk"] - required),
    c["vcpus"],
    c["ram"],
))
print(chosen["id"])
PY
  )"
  chosen="$(printf '%s' "$chosen" | tr -d '\r' | head -1)"
  if [[ -n "$chosen" ]]; then
    log "[METHOD_Z] Auto-selected target flavor in $TARGET_REGION: $chosen required_disk_gb=${required_disk_gb:-0}"
    TARGET_FLAVOR="$chosen"
  elif [[ -n "$requested" ]]; then
    log "[METHOD_Z] ERROR no valid target flavor could be resolved in $TARGET_REGION after requested flavor '$requested' was rejected."
    TARGET_FLAVOR=""
  fi
}

resolve_target_network_for_windows_method_z() {
  local requested="$TARGET_NETWORK"
  local rows chosen
  [[ "$DRY_RUN" -eq 1 ]] && return 0

  if [[ -n "$requested" ]] && [[ -n "$(target_openstack_capture network show "$requested" -f value -c id | head -1)" ]]; then
    log "[METHOD_Z] Target network exists in $TARGET_REGION: $requested"
    return 0
  fi
  [[ -n "$requested" ]] && log "[METHOD_Z] WARN target network '$requested' not found in $TARGET_REGION; resolving like OSPC2FLEX boot path."

  rows="$(target_openstack_capture network list -f json -c ID -c Name)"
  chosen="$(
    NETWORK_ROWS_JSON="$rows" python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    rows = json.loads(os.environ.get("NETWORK_ROWS_JSON") or "[]")
except Exception:
    rows = []
items = []
for r in rows if isinstance(rows, list) else []:
    nid = str(r.get("ID") or "").strip()
    name = str(r.get("Name") or "").strip()
    if nid:
        items.append((nid, name))
if not items:
    raise SystemExit
for nid, name in items:
    lname = name.lower()
    if any(x in lname for x in ("private", "tenant", "internal")) and "public" not in lname:
        print(nid)
        raise SystemExit
print(items[0][0])
PY
  )"
  chosen="$(printf '%s' "$chosen" | tr -d '\r' | head -1)"
  if [[ -n "$chosen" ]]; then
    log "[METHOD_Z] Auto-selected target network in $TARGET_REGION: $chosen"
    TARGET_NETWORK="$chosen"
  elif [[ -n "$requested" ]]; then
    log "[METHOD_Z] ERROR no valid target network could be resolved in $TARGET_REGION after requested network '$requested' was rejected."
    TARGET_NETWORK=""
  fi
}

resolve_target_keypair_for_windows_method_z() {
  local requested="$TARGET_KEY_NAME"
  local chosen
  [[ "$DRY_RUN" -eq 1 ]] && return 0

  if [[ -n "$requested" ]] && [[ -n "$(target_openstack_capture keypair show "$requested" -f value -c name | head -1)" ]]; then
    log "[METHOD_Z] Target keypair exists in $TARGET_REGION: $requested"
    return 0
  fi
  if [[ -n "$requested" ]]; then
    chosen="$(target_openstack_capture keypair list -f value -c Name | awk 'NF{print; exit}')"
    if [[ -n "$chosen" ]]; then
      log "[METHOD_Z] Target keypair '$requested' not found in $TARGET_REGION; using existing keypair '$chosen'"
      TARGET_KEY_NAME="$chosen"
    else
      log "[METHOD_Z] Target keypair '$requested' not found in $TARGET_REGION and no keypairs exist; booting without keypair"
      TARGET_KEY_NAME=""
    fi
  fi
}

resolve_windows_method_z_target_boot_inputs() {
  local image_file="$1"
  resolve_target_flavor_for_windows_method_z "$image_file"
  resolve_target_network_for_windows_method_z
  resolve_target_keypair_for_windows_method_z
  log "[METHOD_Z] Resolved target boot inputs: region=$TARGET_REGION flavor=${TARGET_FLAVOR:-<empty>} network=${TARGET_NETWORK:-<empty>} keypair=${TARGET_KEY_NAME:-<none>}"
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

    if ! ensure_source_export_space "$image_file" "$expected_size" "$actual_size" "source Swift download"; then
      return 28
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
      if [[ "$rc" -eq 23 ]]; then
        log "[ERROR] source Swift download cannot write to destination: $image_file"
        log "ICF Issue=Flex2Flex source Swift export write failed"
        log "ICF Cause=curl could not extend the local image file; this is usually jumphost disk space, quota, or a non-writable migration filesystem"
        log "ICF Fix=free space under /mnt/migration/flex2flex or move FLEX2FLEX_RUN_ROOT to a larger writable filesystem, then rerun START FRESH"
        write_plan "failed" "Flex2Flex source Swift export write failed" "curl rc=23 while writing $image_file" "Free jumphost migration space or use a larger run root, then rerun START FRESH."
        return 28
      fi
    fi
    [[ "$attempt" -lt "$attempts" ]] && sleep "$wait_s"
  done

  return 1
}

source_glance_file_export_with_resume() {
  local image_file="$1"
  local image_id="$2"
  local source_json="$RUN_DIR/source_image.json"
  local source_token source_glance_catalog source_glance_url region_lc image_file_path
  local head_headers head_status_file head_status expected_size actual_size attempt attempts wait_s rc err_tail download_url

  [[ -s "$source_json" ]] || return 2

  source_token="$(
    set +u
    # shellcheck source=/dev/null
    . "$SOURCE_OPENRC"
    export OS_REGION_NAME="$SOURCE_REGION"
    openstack token issue -f value -c id 2>/dev/null | head -1
  )"
  source_glance_catalog="$RUN_DIR/source-glance-catalog.json"
  source_glance_url=""
  if (
    set +u
    # shellcheck source=/dev/null
    . "$SOURCE_OPENRC"
    export OS_REGION_NAME="$SOURCE_REGION"
    openstack catalog show image -f json >"$source_glance_catalog" 2>"$RUN_DIR/source-glance-catalog.err"
  ); then
    source_glance_url="$(python3 - "$SOURCE_REGION" "$source_glance_catalog" <<'PY' || true
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
  if [[ -z "$source_glance_url" ]]; then
    region_lc="$(printf '%s' "$SOURCE_REGION" | tr '[:upper:]' '[:lower:]')"
    source_glance_url="https://glance.api.${region_lc}.rackspacecloud.com/v2"
  fi
  source_glance_url="${source_glance_url%/}"

  if [[ -z "$source_token" || -z "$source_glance_url" ]]; then
    log "[WARN] source Glance file export unavailable: token or endpoint missing"
    return 2
  fi

  image_file_path="$(python3 - "$source_json" "$image_id" <<'PY' 2>/dev/null || true
import json, sys
image_id = sys.argv[2]
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    data = {}
path = str(data.get("file") or "").strip()
if not path:
    path = f"/v2/images/{image_id}/file"
if path.startswith("/v2/"):
    path = path[3:]
print(path if path.startswith("/") else "/" + path)
PY
)"
  [[ -n "$image_file_path" ]] || image_file_path="/images/$image_id/file"
  download_url="${source_glance_url}${image_file_path}"

  head_headers="$RUN_DIR/source-glance-file.head.headers"
  head_status_file="$RUN_DIR/source-glance-file.head.http"
  : > "$head_headers"
  printf '' > "$head_status_file"
  curl -sS -I "$download_url" \
    -H "X-Auth-Token: $source_token" \
    --write-out "%{http_code}" \
    -o "$head_headers" >"$head_status_file" 2>"$RUN_DIR/source-glance-file.head.err" || true
  head_status="$(cat "$head_status_file" 2>/dev/null || true)"
  if [[ ! "$head_status" =~ ^(200|204)$ ]]; then
    log "[WARN] source Glance file endpoint unavailable http=${head_status:-none}: $download_url"
    return 2
  fi

  expected_size="$(python3 - "$source_json" <<'PY' 2>/dev/null || true
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("size") or "")
except Exception:
    print("")
PY
)"
  if [[ -z "$expected_size" ]]; then
    expected_size="$(awk 'BEGIN{IGNORECASE=1} /^Content-Length:/ {gsub("\r","",$2); print $2; exit}' "$head_headers" 2>/dev/null || true)"
  fi

  attempts="${FLEX2FLEX_GLANCE_FILE_DOWNLOAD_ATTEMPTS:-6}"
  wait_s="${FLEX2FLEX_GLANCE_FILE_DOWNLOAD_RETRY_WAIT:-10}"
  log "[LS3] source Glance file endpoint selected: $download_url size=${expected_size:-unknown}"
  for attempt in $(seq 1 "$attempts"); do
    actual_size="$(stat -c%s "$image_file" 2>/dev/null || echo 0)"
    if [[ "$expected_size" =~ ^[0-9]+$ && "$actual_size" -gt "$expected_size" ]]; then
      log "[WARN] existing Glance file download is larger than expected; restarting file"
      rm -f -- "$image_file"
      actual_size=0
    fi
    if [[ "$expected_size" =~ ^[0-9]+$ && "$actual_size" -eq "$expected_size" && "$actual_size" -gt 0 ]] && qemu-img info "$image_file" >/dev/null 2>&1; then
      log "[LS3] HIT source Glance file export: $image_file ($actual_size bytes)"
      return 0
    fi
    if ! ensure_source_export_space "$image_file" "$expected_size" "$actual_size" "source Glance file download"; then
      return 28
    fi

    log "[LS3] downloading source Glance file attempt $attempt/$attempts resume_from=$actual_size"
    set +e
    curl --http1.1 -fL \
      -C - \
      --retry 4 \
      --retry-delay 8 \
      --retry-connrefused \
      --connect-timeout 30 \
      --speed-time 300 \
      --speed-limit 1024 \
      -H "X-Auth-Token: $source_token" \
      -H "Accept: application/octet-stream" \
      "$download_url" \
      -o "$image_file" >"$RUN_DIR/source-glance-file-download.out" 2>"$RUN_DIR/source-glance-file-download.err"
    rc=$?
    set -e

    actual_size="$(stat -c%s "$image_file" 2>/dev/null || echo 0)"
    if [[ "$rc" -eq 0 && "$actual_size" -gt 0 ]] && qemu-img info "$image_file" >/dev/null 2>&1; then
      log "[LS3] HIT source Glance file export: $image_file ($actual_size bytes)"
      return 0
    fi
    err_tail="$(tail -c 800 "$RUN_DIR/source-glance-file-download.err" 2>/dev/null | tr '\n' ' ')"
    log "[WARN] source Glance file download failed attempt $attempt/$attempts rc=$rc: ${err_tail:-no stderr}"
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

should_use_windows_method_z() {
  case "$(printf '%s' "${WINDOWS_METHOD_Z_REPAIR:-auto}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on|force) return 0 ;;
    0|false|no|off|disabled) return 1 ;;
    auto|"") source_image_looks_windows ;;
    *) source_image_looks_windows ;;
  esac
}

run_windows_method_z_repair() {
  local image_file="$1"
  local method_z_script="${FLEX2FLEX_WINDOWS_METHOD_Z_SCRIPT:-$WINDOWS_METHOD_Z_SCRIPT}"
  local method_z_base="$RUN_DIR/method_z"
  local method_z_run_id="${RUN_ID}-method-z"
  local method_z_log="$RUN_DIR/method-z.out"
  local method_z_result="$method_z_base/runs/$safe_label/$method_z_run_id/artifacts/result.json"
  local method_z_exec="$RUN_DIR/snapwin_run_${safe_label}_${RUN_ID}.sh"
  local method_z_rc final_image_id final_server_id method_status snapwin_auto_resume
  local -a zcmd

  if [[ ! -f "$method_z_script" ]]; then
    log "[ERROR] Windows Method Z script missing on jumphost: $method_z_script"
    log "ICF Issue=Windows FLEX2FLEX repair script missing"
    log "ICF Cause=FLEX2FLEX detected Windows but ospc2flex_windows_method_z_snapshot_existing.sh was not staged"
    log "ICF Fix=restage dashboard scripts to the jumphost and rerun START FRESH"
    write_plan "failed" "Windows Method Z script missing" "SNAPWIN script was not found on the jumphost" "Restage dashboard scripts and rerun START FRESH."
    exit 1
  fi
  resolve_windows_method_z_target_boot_inputs "$image_file"
  if [[ -z "$TARGET_FLAVOR" || -z "$TARGET_NETWORK" ]]; then
    log "[ERROR] Windows Method Z requires target flavor and network for rescue/final boot."
    log "ICF Issue=Windows Method Z target boot inputs missing"
    log "ICF Cause=SNAPWIN needs a target flavor and network to boot the safe IDE rescue VM and final repaired VM"
    log "ICF Fix=set Flex target flavor/network in the dashboard, then rerun START FRESH"
    write_plan "failed" "Windows Method Z boot inputs missing" "Target flavor or target network was empty" "Set Flex target flavor/network and rerun START FRESH."
    exit 1
  fi

  mkdir -p "$method_z_base" "$RUN_DIR"
  cp "$method_z_script" "$method_z_exec"
  chmod +x "$method_z_exec"
  zcmd=(
    bash "$method_z_exec"
    --label "$safe_label"
    --local-artifact "$image_file"
    --flex-openrc "$TARGET_OPENRC"
    --flex-region "$TARGET_REGION"
    --windows-version "${FLEX2FLEX_WINDOWS_VERSION:-auto}"
    --flavor "$TARGET_FLAVOR"
    --network "$TARGET_NETWORK"
  )
  [[ -n "$TARGET_KEY_NAME" ]] && zcmd+=(--keypair "$TARGET_KEY_NAME")
  [[ -n "${FLEX2FLEX_WINDOWS_SECURITY_GROUP:-}" ]] && zcmd+=(--security-group "$FLEX2FLEX_WINDOWS_SECURITY_GROUP")
  [[ -n "${FLEX2FLEX_WINDOWS_VIRTIO_ISO:-}" ]] && zcmd+=(--virtio-iso "$FLEX2FLEX_WINDOWS_VIRTIO_ISO")
  [[ -n "${FLEX2FLEX_WINDOWS_ADMIN_USER:-}" ]] && zcmd+=(--windows-user "$FLEX2FLEX_WINDOWS_ADMIN_USER")
  [[ -n "${FLEX2FLEX_WINDOWS_ADMIN_PASSWORD:-}" ]] && zcmd+=(--windows-password "$FLEX2FLEX_WINDOWS_ADMIN_PASSWORD")
  [[ "${FLEX2FLEX_WINDOWS_METHOD_Z_FORCE_MANUAL_BIND:-0}" == "1" ]] && zcmd+=(--manual-driver-bind)
  [[ "${FLEX2FLEX_WINDOWS_METHOD_Z_SKIP_RESCUE_BOOT:-0}" == "1" ]] && zcmd+=(--skip-rescue-boot)
  [[ "${FLEX2FLEX_WINDOWS_METHOD_Z_DOWNLOAD_ONLY:-0}" == "1" ]] && zcmd+=(--download-only)

  log "[METHOD_Z] Windows source detected; handing exported source artifact to existing SNAPWIN Method Z."
  log "[METHOD_Z] Source artifact: $image_file"
  log "[METHOD_Z] Run-local SNAPWIN script: $method_z_exec"
  log "[METHOD_Z] Method Z workspace: $method_z_base/runs/$safe_label/$method_z_run_id"
  snapwin_auto_resume="${FLEX2FLEX_WINDOWS_METHOD_Z_AUTO_RESUME:-1}"
  [[ "$START_FRESH" -eq 1 ]] && snapwin_auto_resume=0
  set +e
  OSPC2FLEX_METHOD_Z_BASE_DIR="$method_z_base" \
  OSPC2FLEX_RUN_ID="$method_z_run_id" \
  OSPC2FLEX_LOCAL_ARTIFACT_IN_PLACE="${FLEX2FLEX_WINDOWS_METHOD_Z_LOCAL_IN_PLACE:-1}" \
  OSPC2FLEX_ARTIFACT_SEARCH_DIRS="$ARTIFACT_DIR:$RUN_DIR" \
  OSPC2FLEX_SNAPWIN_AUTO_RESUME="$snapwin_auto_resume" \
  OSPC2FLEX_SNAPWIN_FORCE_MANUAL_BIND="${FLEX2FLEX_WINDOWS_METHOD_Z_FORCE_MANUAL_BIND:-0}" \
  OSPC2FLEX_REPLACEMENT_FLOATING_IP="$FLOATING_IP" \
  OSPC2FLEX_IMAGE_UPLOAD_TIMEOUT="${OSPC2FLEX_IMAGE_UPLOAD_TIMEOUT:-${FLEX2FLEX_IMAGE_CREATE_TIMEOUT:-21600}}" \
  OSPC2FLEX_IMAGE_UPLOAD_HEARTBEAT_SECONDS="${OSPC2FLEX_IMAGE_UPLOAD_HEARTBEAT_SECONDS:-25}" \
  "${zcmd[@]}" 2>&1 | tee "$method_z_log"
  method_z_rc=${PIPESTATUS[0]}
  set -e

  if [[ "$method_z_rc" -ne 0 ]]; then
    log "[ERROR] Windows Method Z failed rc=$method_z_rc. See $method_z_log"
    log "ICF Issue=Windows FLEX2FLEX boot repair failed"
    log "ICF Cause=SNAPWIN Method Z did not complete the offline repair/rescue boot/final snapshot sequence"
    log "ICF Fix=inspect Method Z logs under $method_z_base and rerun START FRESH after fixing the reported SNAPWIN stage"
    write_plan "failed" "Windows Method Z repair failed" "SNAPWIN exited rc=$method_z_rc" "Inspect $method_z_log and rerun START FRESH."
    exit "$method_z_rc"
  fi

  METHOD_Z_RESULT_JSON="$method_z_result"
  if [[ -s "$method_z_result" ]]; then
    final_image_id="$(python3 - "$method_z_result" <<'PY' 2>/dev/null || true
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(d.get("final_image_id") or "")
PY
)"
    final_server_id="$(python3 - "$method_z_result" <<'PY' 2>/dev/null || true
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(d.get("final_server_id") or "")
PY
)"
    method_status="$(python3 - "$method_z_result" <<'PY' 2>/dev/null || true
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(d.get("status") or "")
PY
)"
  else
    final_image_id=""
    final_server_id=""
    method_status=""
  fi

  if [[ -z "$final_image_id" && "${FLEX2FLEX_WINDOWS_METHOD_Z_ALLOW_PARTIAL:-0}" != "1" ]]; then
    log "[ERROR] Windows Method Z returned success but no final_image_id was found in $method_z_result"
    log "ICF Issue=Windows Method Z final image missing"
    log "ICF Cause=SNAPWIN did not produce the expected virtio-ready final image result"
    log "ICF Fix=inspect $method_z_log and Method Z result JSON before booting the target VM"
    write_plan "failed" "Windows Method Z final image missing" "SNAPWIN result did not include final_image_id" "Inspect Method Z result JSON and rerun START FRESH."
    exit 1
  fi

  TARGET_IMAGE_ID="$final_image_id"
  TARGET_SERVER_ID="$final_server_id"
  WINDOWS_METHOD_Z_COMPLETED=1
  log "[METHOD_Z] HIT Windows Method Z complete status=${method_status:-unknown} final_image=${TARGET_IMAGE_ID:-none} final_server=${TARGET_SERVER_ID:-none}"
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
  local attempt rc err_tail image_bytes cinder_rc swift_rc actual_bytes
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
  if [[ "$swift_rc" -eq 28 ]]; then
    exit 28
  fi
  if [[ "$swift_rc" -eq 1 ]]; then
    log "[WARN] source Swift resumable export failed; trying source Glance file endpoint"
  else
    log "[WARN] source Swift resumable export not available; trying source Glance file endpoint"
  fi

  set +e
  source_glance_file_export_with_resume "$image_file" "$image_id"
  glance_file_rc=$?
  set -e
  if [[ "$glance_file_rc" -eq 0 ]]; then
    return 0
  fi
  if [[ "$glance_file_rc" -eq 28 ]]; then
    exit 28
  fi
  log "[WARN] source Glance file export unavailable or failed; falling back to openstack image save"

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
    actual_bytes="$(stat -c%s "$image_file" 2>/dev/null || echo 0)"
    if ! ensure_source_export_space "$image_file" "${image_bytes:-}" "$actual_bytes" "openstack image save"; then
      exit 28
    fi
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
stage "LS1_LOAD_CREDENTIALS"
if ! validate_openrc_access "$SOURCE_OPENRC" "$SOURCE_REGION" "source Flex"; then
  log "ICF Issue=Flex2Flex source OpenRC validation failed"
  log "ICF Cause=source Flex credentials, project scope, auth URL, or region endpoint could not issue a token or access Glance"
  log "ICF Fix=verify source Flex OpenRC/project/application credential for $SOURCE_REGION, then retry START FRESH"
  write_plan "failed" "Source Flex OpenRC validation failed" "source region $SOURCE_REGION token or Glance access failed" "Fix source Flex OpenRC/project/application credential and retry."
  exit 1
fi
if ! validate_openrc_access "$TARGET_OPENRC" "$TARGET_REGION" "target Flex"; then
  log "ICF Issue=Flex2Flex target OpenRC validation failed"
  log "ICF Cause=target Flex credentials, project scope, auth URL, or region endpoint could not issue a token or access Glance"
  log "ICF Fix=verify target Flex OpenRC/project/application credential for $TARGET_REGION, then retry START FRESH"
  write_plan "failed" "Target Flex OpenRC validation failed" "target region $TARGET_REGION token or Glance access failed" "Fix target Flex OpenRC/project/application credential and retry."
  exit 1
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
if [[ "$(printf '%s' "${WINDOWS_METHOD_Z_REPAIR:-auto}" | tr '[:upper:]' '[:lower:]')" =~ ^(1|true|yes|on|force)$ ]]; then
  log "Windows Method Z/SNAPWIN repair requested after source export; source cleanup remains disabled."
else
  log "No source cleanup. Windows images auto-route to Method Z/SNAPWIN when detected."
fi

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

if should_use_windows_method_z; then
  stage "R3.4_WINDOWS_METHOD_Z_REPAIR"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] Would run existing Method Z/SNAPWIN against exported artifact $IMAGE_FILE, then boot safe IDE rescue VM, bind VirtIO, snapshot final image, and boot final VM."
    TARGET_IMAGE_ID="DRYRUN_METHOD_Z_FINAL_IMAGE_${RUN_ID}"
    WINDOWS_METHOD_Z_COMPLETED=1
  else
    run_windows_method_z_repair "$IMAGE_FILE"
  fi
else
  stage "R3.4_IMPORT_TARGET_GLANCE"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] Would import to target Glance in $TARGET_REGION as $TARGET_IMAGE_NAME"
    TARGET_IMAGE_ID="DRYRUN_TARGET_IMAGE_${RUN_ID}"
  else
    image_create_timeout="${FLEX2FLEX_IMAGE_CREATE_TIMEOUT:-21600}"
    image_create_attempts="${FLEX2FLEX_IMAGE_UPLOAD_ATTEMPTS:-3}"
    image_create_poll_count="${FLEX2FLEX_IMAGE_UPLOAD_POLL_COUNT:-60}"
    image_create_poll_seconds="${FLEX2FLEX_IMAGE_UPLOAD_POLL_SECONDS:-20}"
    [[ "$image_create_attempts" =~ ^[0-9]+$ && "$image_create_attempts" -gt 0 ]] || image_create_attempts=3
    [[ "$image_create_poll_count" =~ ^[0-9]+$ && "$image_create_poll_count" -gt 0 ]] || image_create_poll_count=60
    [[ "$image_create_poll_seconds" =~ ^[0-9]+$ && "$image_create_poll_seconds" -gt 0 ]] || image_create_poll_seconds=20
    image_create_out="$RUN_DIR/target-image-create.out"
    image_create_err="$RUN_DIR/target-image-create.err"
    : >"$image_create_out"
    : >"$image_create_err"
    image_bytes="$(stat -c%s "$IMAGE_FILE" 2>/dev/null || printf 'unknown')"
    log "[UPLOAD] target Glance image create: region=$TARGET_REGION bytes=$image_bytes timeout=${image_create_timeout}s attempts=${image_create_attempts}"
    TARGET_IMAGE_ID=""
    image_create_rc=1
    for upload_try in $(seq 1 "$image_create_attempts"); do
      attempt_out="$RUN_DIR/target-image-create.${upload_try}.out"
      attempt_err="$RUN_DIR/target-image-create.${upload_try}.err"
      log "[UPLOAD ${upload_try}/${image_create_attempts}] starting target Glance image create"
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
          --property architecture=x86_64 \
          --property vm_mode=hvm \
          --property os_type=linux \
          --property hw_disk_bus=virtio \
          --property hw_vif_model=virtio \
          --property hw_qemu_guest_agent=yes \
          --property migrated_by=ospc2flex \
          --property migrated_workflow=flex2flex_region_migration \
          --property migrated_from_region="$SOURCE_REGION" \
          --property migrated_from_image_id="$SOURCE_IMAGE_ID" \
          -f value -c id
      ) >"$attempt_out" 2>"$attempt_err"
      image_create_rc=$?
      set -e
      cat "$attempt_out" >>"$image_create_out" 2>/dev/null || true
      cat "$attempt_err" >>"$image_create_err" 2>/dev/null || true
      TARGET_IMAGE_ID="$(grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$attempt_out" | tail -1 || true)"
      if [[ -z "$TARGET_IMAGE_ID" ]]; then
        TARGET_IMAGE_ID="$(tail -1 "$attempt_out" | tr -d '[:space:]')"
      fi
      if [[ "$image_create_rc" -eq 0 && -n "$TARGET_IMAGE_ID" ]]; then
        log "[UPLOAD ${upload_try}/${image_create_attempts}] returned target image id: $TARGET_IMAGE_ID"
        break
      fi

      err_tail="$(tail -c 1200 "$attempt_err" 2>/dev/null | tr '\n' ' ')"
      out_tail="$(tail -c 1200 "$attempt_out" 2>/dev/null | tr '\n' ' ')"
      [[ "$image_create_rc" -eq 124 ]] && err_tail="target Glance upload timed out after ${image_create_timeout}s ${err_tail}"
      log "[WARN] target Glance upload attempt ${upload_try}/${image_create_attempts} failed rc=$image_create_rc: ${err_tail:-no stderr} ${out_tail:+output=${out_tail}}"
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
      [[ "$upload_try" -lt "$image_create_attempts" ]] && sleep 20
    done

    if [[ -z "$TARGET_IMAGE_ID" ]]; then
      err_tail="$(tail -n 40 "$image_create_err" 2>/dev/null | tr '\n' ' ')"
      log "[ERROR] target Glance upload failed after ${image_create_attempts} attempt(s): ${err_tail:-no stderr captured}"
      log "ICF Issue=Flex2Flex target Glance import failed"
      log "ICF Cause=openstack image create --file did not complete successfully for target region $TARGET_REGION or returned no parseable image id"
      log "ICF Fix=retry START FRESH; if repeated, verify target Glance upload quota/service health or use a smaller/active source image"
      write_plan "failed" "Target Flex Glance upload failed" "openstack image create --file failed after ${image_create_attempts} attempt(s), rc=$image_create_rc" "Retry START FRESH after validating target Glance service/quota."
      exit 1
    fi
    image_status=""
    for poll in $(seq 1 "$image_create_poll_count"); do
      image_status="$(
        (
          set +u
          # shellcheck source=/dev/null
          . "$TARGET_OPENRC"
          export OS_REGION_NAME="$TARGET_REGION"
          set -u
          openstack image show "$TARGET_IMAGE_ID" -f value -c status 2>/dev/null
        ) || true
      )"
      image_status="$(printf '%s' "$image_status" | tr -d '\r' | tail -1)"
      [[ "$image_status" == "active" ]] && break
      if [[ "$image_status" == "killed" || "$image_status" == "error" ]]; then
        log "[ERROR] target image $TARGET_IMAGE_ID entered status=$image_status"
        log "ICF Issue=Flex2Flex target image import failed"
        log "ICF Cause=target Glance accepted the upload but the image did not become active"
        log "ICF Fix=inspect target Glance image details and retry START FRESH after quota/service issue is fixed"
        write_plan "failed" "Target image inactive" "target image $TARGET_IMAGE_ID status=$image_status" "Inspect target Glance image details and rerun START FRESH."
        exit 1
      fi
      log "[UPLOAD_POLL ${poll}/${image_create_poll_count}] target image status=${image_status:-unknown}"
      sleep "$image_create_poll_seconds"
    done
    if [[ "$image_status" != "active" ]]; then
      log "[ERROR] target image $TARGET_IMAGE_ID never reached active (status=${image_status:-unknown})"
      log "ICF Issue=Flex2Flex target image activation timeout"
      log "ICF Cause=target Glance did not report active within poll window"
      log "ICF Fix=inspect target Glance service/quota and rerun START FRESH"
      write_plan "failed" "Target image activation timeout" "target image $TARGET_IMAGE_ID status=${image_status:-unknown}" "Inspect target Glance and rerun START FRESH."
      exit 1
    fi
    log "[UPLOAD] HIT target image active: $TARGET_IMAGE_ID"
    log "Target image ID: $TARGET_IMAGE_ID"
  fi
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
if [[ "$WINDOWS_METHOD_Z_COMPLETED" -eq 1 ]]; then
  log "Target boot handled by Windows Method Z/SNAPWIN. Final server: ${TARGET_SERVER_ID:-see Method Z report}"
elif [[ "$BOOT_TARGET" -eq 1 ]]; then
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
      if ! TARGET_SERVER_ID="$(run_os "$TARGET_OPENRC" "$TARGET_REGION" "boot target instance" "${boot_cmd[@]}" 2>&1)"; then
        log "[WARN] optional target boot failed; keeping active target image and continuing."
        log "[WARN] target boot error: ${TARGET_SERVER_ID//$'\n'/ }"
        TARGET_SERVER_ID=""
      elif [[ -n "$TARGET_SERVER_ID" ]]; then
        log "[BOOT] target server created: $TARGET_SERVER_ID"
        attach_replacement_or_new_fip "$TARGET_SERVER_ID" "$FLOATING_IP" "${FLEX2FLEX_EXTERNAL_NETWORK:-PUBLICNET}" || true
        [[ -n "${ATTACHED_FIP:-}" ]] && log "[BOOT] target floating IP: $ATTACHED_FIP"
      fi
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
if [[ "$WINDOWS_METHOD_Z_COMPLETED" -eq 1 ]]; then
  write_plan "planned" "Windows Method Z FLEX2FLEX repair completed" "Windows source image was exported, repaired with the existing SNAPWIN Method Z flow, and booted through the safe rescue/final sequence." "Validate Windows boot, disk visibility, services, and application health before cutover."
else
  write_plan "planned" "Flex2Flex R3 snapshot clone plan generated" "Region-to-region cloning uses the proven snapshot migration image export/import method." "Review plan, run live image import only when ready, then validate before cutover."
fi
log "Reports written:"
log "  $PLAN_JSON"
log "  $REPORT_MD"
log "R3 FLEX2FLEX-Region Cloning complete. Source resources were not deleted, stopped, detached, promoted, or cut over."
