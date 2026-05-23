#!/usr/bin/env bash
# ospc2flex_volsnap_migrate.sh — OSPC Cinder volume snapshot → FLEX Cinder volume (direct block stream)
#
# VS0:  Load + validate OSPC credentials
# VS1:  Create temp OSPC Cinder volume from snapshot
# VS2:  Attach temp volume to this jumphost; detect source block device
# VS3:  Get source device size
# VS4:  Source FLEX creds; create blank FLEX Cinder volume (same size)
# VS5:  Attach blank FLEX volume to FLEX helper VM
# VS6:  Detect target block device on FLEX helper via SSH
# VS7:  Validate target_bytes >= source_bytes
# VS8:  Direct block stream: dd | gzip | ssh ... gunzip | dd
# VS9:  Validate FLEX target disk (blkid, file -s)
# VS10: Detach FLEX volume from helper VM
# VS11: Attach FLEX volume to paired migrated FLEX VM (optional)
# VOL_POST_ATTACH_VALIDATE: optionally mount migrated volume and optionally query PostgreSQL proof table
# VS12: Cleanup — detach + delete temp OSPC volume
#
# No FLEX Glance. No qcow2. No image create. No virtual-size mismatch.

set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

if [ -z "${OSPC2FLEX_LINEBUF_WRAPPER:-}" ] && command -v stdbuf >/dev/null 2>&1; then
  export OSPC2FLEX_LINEBUF_WRAPPER=1
  exec stdbuf -oL -eL bash "$0" "$@"
fi

# ── Args ──────────────────────────────────────────────────────────────────────
LABEL=""
SNAPSHOT_ID=""
OSPC_OPENRC=""
FLEX_OPENRC=""
FLEX_HELPER_VM_ID=""
FLEX_HELPER_IP=""
FLEX_HELPER_USER="ubuntu"
SSH_KEY_PATH="${HOME}/.ssh/id_rsa"
FLEX_TARGET_VM_ID=""
FLEX_VOLUME_NAME_OVERRIDE=""
SNAP_SIZE_GB=0                      # 0 = auto-detect from snapshot
CLEANUP_TEMP="true"
ATTACH_TO_FINAL="true"
SOURCE_DEVICE_OVERRIDE=""
TARGET_DEVICE_OVERRIDE=""
POST_ATTACH_VALIDATE_MOUNT="false"
POST_ATTACH_VALIDATE_PG="false"
POST_ATTACH_DB_VALIDATOR="none"
POST_ATTACH_CUSTOM_VALIDATE_CMD=""
POST_ATTACH_PG_DB_NAME="openstack_drinks"
POST_ATTACH_PG_TABLE_NAME="preferred_drinks"
POST_ATTACH_MOUNT_POINT=""
POST_ATTACH_DEVICE_HINT=""
POST_ATTACH_SSH_USER="ubuntu"
POST_ATTACH_SSH_KEY_PATH="${HOME}/.ssh/id_rsa"
POST_ATTACH_SSH_IP=""
POST_ATTACH_ALLOW_LUKS_OPEN="true"
POST_ATTACH_ALLOW_LVM_ACTIVATE="true"
POST_ATTACH_UPDATE_POSTGRESQL_CONF="true"
POST_ATTACH_START_POSTGRESQL="true"
POST_ATTACH_SCRIPT_PATH="/tmp/osflex_post_attach_pg_mount_validate.sh"
BASE_DIR="${OSPC2FLEX_LINUX_SNAP_BASE_DIR:-/mnt/migration/ospc2flex_linux_snap}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)               LABEL="$2";                  shift 2 ;;
    --snapshot-id)         SNAPSHOT_ID="$2";             shift 2 ;;
    --ospc-openrc)         OSPC_OPENRC="$2";             shift 2 ;;
    --flex-openrc)         FLEX_OPENRC="$2";             shift 2 ;;
    --flex-helper-vm-id)   FLEX_HELPER_VM_ID="$2";       shift 2 ;;
    --flex-helper-ip)      FLEX_HELPER_IP="$2";          shift 2 ;;
    --flex-helper-user)    FLEX_HELPER_USER="$2";        shift 2 ;;
    --ssh-key-path)        SSH_KEY_PATH="$2";            shift 2 ;;
    --flex-target-vm-id)   FLEX_TARGET_VM_ID="$2";       shift 2 ;;
    --flex-volume-name)    FLEX_VOLUME_NAME_OVERRIDE="$2"; shift 2 ;;
    --snap-size-gb)        SNAP_SIZE_GB="$2";            shift 2 ;;
    --cleanup-temp)        CLEANUP_TEMP="$2";            shift 2 ;;
    --attach-to-final)     ATTACH_TO_FINAL="$2";         shift 2 ;;
    --source-device)       SOURCE_DEVICE_OVERRIDE="$2";  shift 2 ;;
    --target-device)       TARGET_DEVICE_OVERRIDE="$2";  shift 2 ;;
    --post-attach-validate-mount) POST_ATTACH_VALIDATE_MOUNT="$2"; shift 2 ;;
    --post-attach-validate-pg) POST_ATTACH_VALIDATE_PG="$2"; shift 2 ;;
    --post-attach-db-validator) POST_ATTACH_DB_VALIDATOR="$2"; shift 2 ;;
    --post-attach-custom-validate-cmd) POST_ATTACH_CUSTOM_VALIDATE_CMD="$2"; shift 2 ;;
    --post-attach-pg-db-name) POST_ATTACH_PG_DB_NAME="$2"; shift 2 ;;
    --post-attach-pg-table-name) POST_ATTACH_PG_TABLE_NAME="$2"; shift 2 ;;
    --post-attach-mount-point) POST_ATTACH_MOUNT_POINT="$2"; shift 2 ;;
    --post-attach-device-hint) POST_ATTACH_DEVICE_HINT="$2"; shift 2 ;;
    --post-attach-ssh-user) POST_ATTACH_SSH_USER="$2"; shift 2 ;;
    --post-attach-ssh-key-path) POST_ATTACH_SSH_KEY_PATH="$2"; shift 2 ;;
    --post-attach-ssh-ip) POST_ATTACH_SSH_IP="$2"; shift 2 ;;
    --post-attach-allow-luks-open) POST_ATTACH_ALLOW_LUKS_OPEN="$2"; shift 2 ;;
    --post-attach-allow-lvm-activate) POST_ATTACH_ALLOW_LVM_ACTIVATE="$2"; shift 2 ;;
    --post-attach-update-postgresql-conf) POST_ATTACH_UPDATE_POSTGRESQL_CONF="$2"; shift 2 ;;
    --post-attach-start-postgresql) POST_ATTACH_START_POSTGRESQL="$2"; shift 2 ;;
    --post-attach-script-path) POST_ATTACH_SCRIPT_PATH="$2"; shift 2 ;;
    --base-dir)            BASE_DIR="$2";                shift 2 ;;
    --dry-run)             DRY_RUN=1;                    shift ;;
    # legacy compat — ignored
    --os-type|--nbd-dev)   shift 2 ;;
    *) echo "ERROR: Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$LABEL" ]             || { echo "ERROR: --label required" >&2; exit 2; }
[ -n "$SNAPSHOT_ID" ]       || { echo "ERROR: --snapshot-id required" >&2; exit 2; }
if [ "$DRY_RUN" != 1 ]; then
  [ -n "$OSPC_OPENRC" ]       || { echo "ERROR: --ospc-openrc required" >&2; exit 2; }
  [ -n "$FLEX_OPENRC" ]       || { echo "ERROR: --flex-openrc required" >&2; exit 2; }
  [ -n "$FLEX_HELPER_IP" ]    || { echo "ERROR: --flex-helper-ip required" >&2; exit 2; }
fi

LABEL_SAFE="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_$//')"
RUN_ID="${OSPC2FLEX_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
RUN_DIR="$BASE_DIR/runs/$LABEL_SAFE/$RUN_ID"
JOB_ART="$RUN_DIR/artifacts"
JOB_TMP="$RUN_DIR/tmp"
JOB_LOG="$RUN_DIR/logs"
OSPC_VOL_ID=""
SELF_SERVER_ID=""
FLEX_VOL_ID=""
FLEX_TARGET_DEV=""
CLEANUP_DONE=0
FLEX_FINAL_ATTACHED=0

mkdir -p "$JOB_ART" "$JOB_TMP" "$JOB_LOG"
exec > >(tee -a "$JOB_LOG/volsnap_direct.log") 2>&1

log()      { printf '[%s][%s][VOLSNAP] %s\n' "$(date -u +%H:%M:%S)" "$LABEL_SAFE" "$*"; }
stage()    { log "══════════════════════════════════════════════════════"; log "  $1"; log "══════════════════════════════════════════════════════"; }
fail_exit(){ log "FAILED: $*"; exit 1; }
kv()       { log "  $(printf '%-24s' "$1"): $2"; }

if [ "$DRY_RUN" = 1 ]; then
  for s in \
    VS0_LOAD_CREDENTIALS \
    VS1_CREATE_TEMP_OSPC_VOLUME \
    VS2_ATTACH_OSPC_VOLUME \
    VS3_GET_SOURCE_SIZE \
    VS4_CREATE_FLEX_CINDER_VOLUME \
    VS5_ATTACH_FLEX_VOLUME_TO_HELPER \
    VS6_DETECT_FLEX_TARGET_DEVICE \
    VS7_VALIDATE_SIZES \
    VS8_STREAM_BLOCK_DATA \
    VS9_VALIDATE_FLEX_DISK \
    VS10_DETACH_FLEX_FROM_HELPER \
    VOL_POST_ATTACH_VALIDATE \
    VS12_CLEANUP_OSPC
  do
    stage "$s"
    log "[$s] DRY-RUN volume snapshot stage; no Cinder volume create, attach, block stream, detach, or delete"
  done
  log "METHOD_VOLSNAP_DRY_RUN_SUCCESS"
  exit 0
fi

cleanup_on_exit() {
  local rc=$?
  [ "$CLEANUP_DONE" = "1" ] && return "$rc"
  CLEANUP_DONE=1
  [ "$rc" -eq 0 ] && return 0

  log "[CLEANUP] Failure cleanup start rc=$rc"
  if [ -n "${FLEX_VOL_ID:-}" ] && [ -n "${FLEX_HELPER_VM_ID:-}" ] && [ "$FLEX_FINAL_ATTACHED" != "1" ]; then
    # shellcheck disable=SC1090
    source "$FLEX_OPENRC" 2>/dev/null || true
    log "[CLEANUP] Detaching FLEX volume $FLEX_VOL_ID from helper $FLEX_HELPER_VM_ID"
    openstack server remove volume "$FLEX_HELPER_VM_ID" "$FLEX_VOL_ID" >>"$JOB_LOG/flex_cinder.log" 2>&1 || true
  elif [ -n "${FLEX_VOL_ID:-}" ] && [ "$FLEX_FINAL_ATTACHED" = "1" ]; then
    log "[CLEANUP] Keeping migrated FLEX volume $FLEX_VOL_ID attached to final target after post-copy failure"
  fi
  if [ -n "${OSPC_VOL_ID:-}" ] && [ -n "${SELF_SERVER_ID:-}" ]; then
    # shellcheck disable=SC1090
    source "$OSPC_OPENRC" 2>/dev/null || true
    log "[CLEANUP] Detaching OSPC temp volume $OSPC_VOL_ID from $SELF_SERVER_ID"
    _compute_delete "servers/$SELF_SERVER_ID/os-volume_attachments/$OSPC_VOL_ID" || true
    ospc_wait_volume "$OSPC_VOL_ID" "available" 300 || true
    if [ "$CLEANUP_TEMP" = "true" ]; then
      log "[CLEANUP] Deleting OSPC temp volume $OSPC_VOL_ID"
      _cinder_delete "volumes/$OSPC_VOL_ID" || true
    fi
  fi
  log "[CLEANUP] Failure cleanup complete"
  return "$rc"
}
trap cleanup_on_exit EXIT

# ── SSH helper to FLEX helper VM ──────────────────────────────────────────────
SSH_FLEX_BASE=()
set_ssh_flex_base() {
  SSH_FLEX_BASE=(
    ssh -i "$SSH_KEY_PATH"
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o BatchMode=yes
    -o ConnectTimeout=30
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=4
    "${FLEX_HELPER_USER}@${FLEX_HELPER_IP}"
  )
}
set_ssh_flex_base
ssh_flex() { "${SSH_FLEX_BASE[@]}" "$@"; }

# ── OSPC Cinder/Compute REST helpers (use saved OSPC_TOKEN, never overwritten) ─
_cinder_get()    { curl -sS -H "X-Auth-Token: $OSPC_TOKEN" "$OSPC_BS_BASE/$1" 2>>"$JOB_LOG/cinder.log"; }
_cinder_post()   { curl -sS -w '\nHTTP_CODE=%{http_code}\n' -X POST \
                     -H "X-Auth-Token: $OSPC_TOKEN" -H "Content-Type: application/json" \
                     -d "$2" "$OSPC_BS_BASE/$1" 2>>"$JOB_LOG/cinder.log"; }
_cinder_delete() { curl -sS -o /dev/null -X DELETE -H "X-Auth-Token: $OSPC_TOKEN" \
                     "$OSPC_BS_BASE/$1" 2>>"$JOB_LOG/cinder.log" || true; }
_compute_post()  { curl -sS -w '\nHTTP_CODE=%{http_code}\n' -X POST \
                     -H "X-Auth-Token: $OSPC_TOKEN" -H "Content-Type: application/json" \
                     -d "$2" "$OSPC_COMPUTE_BASE/$1" 2>>"$JOB_LOG/cinder.log"; }
_compute_delete(){ curl -sS -o /dev/null -X DELETE -H "X-Auth-Token: $OSPC_TOKEN" \
                     "$OSPC_COMPUTE_BASE/$1" 2>>"$JOB_LOG/cinder.log" || true; }

ospc_volume_status() {
  _cinder_get "volumes/$1" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["volume"]["status"])' 2>/dev/null || echo unknown
}
ospc_wait_volume() {
  local vid="$1" want="$2" timeout="${3:-3600}" waited=0 status
  while [ "$waited" -lt "$timeout" ]; do
    status="$(ospc_volume_status "$vid")"
    [ "$status" = "$want" ] && return 0
    [ "$status" = "error" ] && { log "[OSPC] vol=$vid error state"; return 1; }
    [ $((waited % 60)) -eq 0 ] && log "[OSPC] vol=$vid status=$status → $want (${waited}s)"
    sleep 10; waited=$((waited + 10))
  done
  log "[OSPC] TIMEOUT vol=$vid target=$want after ${timeout}s"; return 1
}

# ── FLEX Cinder helpers (openstack CLI, requires FLEX openrc to be sourced) ──
flex_volume_status() {
  openstack volume show "$1" -f value -c status 2>/dev/null || echo unknown
}
flex_wait_volume() {
  local vid="$1" want="$2" timeout="${3:-3600}" waited=0 status
  while [ "$waited" -lt "$timeout" ]; do
    status="$(flex_volume_status "$vid")"
    [ "$status" = "$want" ] && return 0
    [ "$status" = "error" ] && { log "[FLEX] vol=$vid error state"; return 1; }
    [ $((waited % 60)) -eq 0 ] && log "[FLEX] vol=$vid status=$status → $want (${waited}s)"
    sleep 10; waited=$((waited + 10))
  done
  log "[FLEX] TIMEOUT vol=$vid target=$want after ${timeout}s"; return 1
}
flex_wait_volume_deleted() {
  local vid="$1" timeout="${2:-300}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if ! openstack volume show "$vid" >/dev/null 2>&1; then
      return 0
    fi
    [ $((waited % 60)) -eq 0 ] && log "[FLEX] vol=$vid waiting for delete (${waited}s)"
    sleep 10
    waited=$((waited + 10))
  done
  log "[FLEX] TIMEOUT vol=$vid delete after ${timeout}s"; return 1
}
flex_volume_device() {
  openstack volume show "$1" -f json 2>/dev/null | python3 -c \
    'import json,sys; v=json.load(sys.stdin); a=v.get("attachments") or []; print(a[0].get("device","") if a else "")' \
    2>/dev/null || true
}
flex_cleanup_existing_mig_volumes() {
  local name="$1" out="$JOB_TMP/flex_existing_${LABEL_SAFE}.tsv"
  : >"$out"
  openstack volume list --name "$name" -f json 2>>"$JOB_LOG/flex_cinder.log" | python3 - "$name" >"$out" <<'PY' 2>>"$JOB_LOG/flex_cinder.log" || true
import json, sys
name = sys.argv[1]
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
for row in rows:
    row_name = row.get("Name") or row.get("name") or ""
    if row_name != name:
        continue
    vid = row.get("ID") or row.get("Id") or row.get("id") or ""
    status = row.get("Status") or row.get("status") or ""
    attachments = row.get("Attachments") or row.get("attachments") or ""
    if isinstance(attachments, list):
        servers = []
        for item in attachments:
            if isinstance(item, dict):
                servers.append(item.get("server_id") or item.get("serverId") or item.get("server") or "")
        attachments = ",".join(x for x in servers if x)
    print(f"{vid}\t{status}\t{attachments}")
PY
  [ -s "$out" ] || return 0
  while IFS=$'\t' read -r vid status attachments; do
    [ -n "$vid" ] || continue
    log "[VS4] START FRESH: removing existing FLEX volume name=$name id=$vid status=${status:-unknown}"
    if [ -n "${attachments:-}" ] || [ "${status:-}" = "in-use" ]; then
      local servers="$attachments"
      if [ -z "$servers" ]; then
        servers="$(openstack volume show "$vid" -f json 2>>"$JOB_LOG/flex_cinder.log" | python3 - <<'PY' 2>>"$JOB_LOG/flex_cinder.log" || true
import json, sys
try:
    v=json.load(sys.stdin)
except Exception:
    v={}
servers=[]
for item in (v.get("attachments") or []):
    if isinstance(item, dict):
        sid=item.get("server_id") or item.get("serverId") or item.get("server") or ""
        if sid:
            servers.append(sid)
print(",".join(servers))
PY
)"
      fi
      IFS=',' read -r -a server_arr <<<"$servers"
      for sid in "${server_arr[@]}"; do
        [ -n "$sid" ] || continue
        log "[VS4] START FRESH: detaching old FLEX volume $vid from $sid"
        openstack server remove volume "$sid" "$vid" >>"$JOB_LOG/flex_cinder.log" 2>&1 || true
      done
      flex_wait_volume "$vid" "available" 300 || true
    fi
    log "[VS4] START FRESH: deleting old FLEX volume $vid"
    openstack volume delete "$vid" >>"$JOB_LOG/flex_cinder.log" 2>&1 || true
    flex_wait_volume_deleted "$vid" 300 || true
  done <"$out"
}
flex_server_first_ip() {
  openstack server show "$1" -f json 2>/dev/null | python3 -c '
import json, re, sys
try:
    data=json.load(sys.stdin)
except Exception:
    sys.exit(0)
addresses=data.get("addresses") or data.get("Addresses") or ""
if isinstance(addresses, dict):
    blob=" ".join(str(x) for vals in addresses.values() for x in (vals if isinstance(vals, list) else [vals]))
else:
    blob=str(addresses)
ips=re.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", blob)
print(ips[-1] if ips else "")
' || true
}
validate_flex_helper_server() {
  [ -n "$FLEX_HELPER_VM_ID" ] || return 0
  local out="$JOB_LOG/flex_helper_preflight.log"
  : >"$out"
  (
    set +u
    unset OS_TOKEN OS_AUTH_TYPE OS_AUTH_URL OS_TENANT_ID OS_TENANT_NAME \
          OS_REGION_NAME OS_IDENTITY_API_VERSION OS_INTERFACE \
          OS_PROJECT_ID OS_PROJECT_NAME OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_ID
    # shellcheck disable=SC1090
    source "$FLEX_OPENRC"
    openstack token issue >/dev/null 2>&1 || { echo "FLEX authentication failed"; exit 10; }
    if openstack server show "$FLEX_HELPER_VM_ID" -f value -c id >/dev/null 2>&1; then
      exit 0
    fi
    echo "No FLEX server found for: $FLEX_HELPER_VM_ID"
    if openstack image show "$FLEX_HELPER_VM_ID" -f value -c id >/dev/null 2>&1; then
      echo "That UUID exists as an image, not a server. Use the instance/server ID from the VM details."
    fi
    if [ -n "$FLEX_HELPER_IP" ]; then
      echo "Servers matching helper IP $FLEX_HELPER_IP:"
      openstack server list --long -f value -c ID -c Name -c Networks 2>/dev/null | grep -F "$FLEX_HELPER_IP" | head -5 || true
    fi
    exit 11
  ) >"$out" 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && log "[FLEX-PREFLIGHT] $line"
    done <"$out"
    fail_exit "Invalid FLEX helper VM ID '$FLEX_HELPER_VM_ID' — use the FLEX instance/server ID, not the Image Info ID"
  fi
}

local_block_disks() {
  sudo lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 !~ /^\/dev\/(nbd|loop|sr|fd)/ {print $1}' | sort
}
flex_remote_block_disks() {
  ssh_flex "lsblk -dnpo NAME,TYPE 2>/dev/null | awk '\$2==\"disk\" && \$1 !~ /^\\/dev\\/(nbd|loop|sr|fd)/ {print \$1}' | sort" 2>>"$JOB_LOG/flex_ssh.log" || true
}
select_flex_helper_ssh_user() {
  [ -n "$FLEX_HELPER_IP" ] || return 0
  local original_user="$FLEX_HELPER_USER" candidates=() seen=" " user
  for user in "$original_user" root debian ubuntu cloud-user centos almalinux rocky ec2-user; do
    [ -n "$user" ] || continue
    case "$seen" in *" $user "*) continue ;; esac
    seen="${seen}${user} "
    candidates+=("$user")
  done
  for user in "${candidates[@]}"; do
    FLEX_HELPER_USER="$user"
    set_ssh_flex_base
    if ssh_flex "command -v lsblk >/dev/null && lsblk -dnpo NAME,TYPE >/dev/null" >>"$JOB_LOG/flex_ssh.log" 2>&1; then
      if [ "$user" != "$original_user" ]; then
        log "[FLEX-SSH] Row SSH user '$original_user' failed; using '$user' for FLEX helper/target SSH"
      else
        log "[FLEX-SSH] SSH user '$user' verified for FLEX helper/target"
      fi
      return 0
    fi
  done
  FLEX_HELPER_USER="$original_user"
  set_ssh_flex_base
  fail_exit "Cannot SSH to FLEX helper/target ${FLEX_HELPER_IP} with key ${SSH_KEY_PATH}; tried users: ${candidates[*]}"
}
select_post_attach_ssh_user() {
  local target_ip="$1"
  [ -n "$target_ip" ] || return 0
  local original_user="$POST_ATTACH_SSH_USER" candidates=() seen=" " user
  for user in "$POST_ATTACH_SSH_USER" "$FLEX_HELPER_USER" root debian ubuntu cloud-user centos almalinux rocky ec2-user; do
    [ -n "$user" ] || continue
    case "$seen" in *" $user "*) continue ;; esac
    seen="${seen}${user} "
    candidates+=("$user")
  done
  for user in "${candidates[@]}"; do
    if ssh -i "$POST_ATTACH_SSH_KEY_PATH" \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes -o ConnectTimeout=12 \
      "${user}@${target_ip}" "command -v sh >/dev/null" >>"$VALIDATE_LOG" 2>&1; then
      POST_ATTACH_SSH_USER="$user"
      if [ "$user" != "$original_user" ]; then
        log "[VOL_POST_ATTACH_VALIDATE] Row SSH user '$original_user' failed; using '$user' for target validation SSH"
      else
        log "[VOL_POST_ATTACH_VALIDATE] SSH user '$user' verified for target validation"
      fi
      return 0
    fi
  done
  fail_exit "Cannot SSH to post-attach target ${target_ip} with key ${POST_ATTACH_SSH_KEY_PATH}; tried users: ${candidates[*]}"
}
flex_remote_device_is_safe() {
  local dev="$1"
  case "$dev" in /dev/*) ;; *) return 1 ;; esac
  printf '%s' "$dev" | grep -Eq '^/dev/[A-Za-z0-9._/-]+$' || return 1
  ssh_flex "set -e
dev='$dev'
[ -b \"\$dev\" ] || { echo \"missing block device: \$dev\" >&2; exit 20; }
[ \"\$(lsblk -dnro TYPE \"\$dev\")\" = disk ] || { echo \"not a disk: \$dev\" >&2; exit 21; }
root_src=\$(findmnt -n -o SOURCE /)
root_mm=\$(findmnt -n -o MAJ:MIN /)
dev_mm=\$(lsblk -dnro MAJ:MIN \"\$dev\")
root_pk=\$(lsblk -npo PKNAME \"\$root_src\" 2>/dev/null | head -1)
[ \"\$dev\" != \"\$root_src\" ] || { echo \"device is root source: \$dev\" >&2; exit 22; }
[ \"\$dev_mm\" != \"\$root_mm\" ] || { echo \"device has root maj:min: \$dev\" >&2; exit 23; }
[ -z \"\$root_pk\" ] || [ \"\$dev\" != \"\$root_pk\" ] || { echo \"device is root parent: \$dev\" >&2; exit 24; }
if lsblk -nrpo NAME,MOUNTPOINT \"\$dev\" | awk 'NF>=2 && \$2 != \"\" {found=1} END{exit found?0:1}'; then
  echo \"device has mounted filesystem: \$dev\" >&2
  exit 25
fi" 2>>"$JOB_LOG/flex_ssh.log"
}
flex_find_new_safe_disk() {
  local before="$1" before_b64
  before_b64="$(printf '%s' "$before" | base64 | tr -d '\n')"
  ssh_flex "set -e
before=\$(printf '%s' '$before_b64' | base64 -d 2>/dev/null || true)
for dev in \$(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '\$2==\"disk\" && \$1 !~ /^\\/dev\\/(nbd|loop|sr|fd)/ {print \$1}' | sort); do
  case \" \$before \" in *\" \$dev \"*) continue ;; esac
  [ -b \"\$dev\" ] || continue
  [ \"\$(lsblk -dnro TYPE \"\$dev\")\" = disk ] || continue
  root_src=\$(findmnt -n -o SOURCE /)
  root_mm=\$(findmnt -n -o MAJ:MIN /)
  dev_mm=\$(lsblk -dnro MAJ:MIN \"\$dev\")
  root_pk=\$(lsblk -npo PKNAME \"\$root_src\" 2>/dev/null | head -1)
  [ \"\$dev\" != \"\$root_src\" ] || continue
  [ \"\$dev_mm\" != \"\$root_mm\" ] || continue
  [ -z \"\$root_pk\" ] || [ \"\$dev\" != \"\$root_pk\" ] || continue
  if lsblk -nrpo NAME,MOUNTPOINT \"\$dev\" | awk 'NF>=2 && \$2 != \"\" {found=1} END{exit found?0:1}'; then
    continue
  fi
  echo \"\$dev\"
  exit 0
done
exit 1" 2>>"$JOB_LOG/flex_ssh.log" || true
}
region_short() {
  local r="${OS_REGION_NAME:-IAD}"
  r="$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]' | tr -d '0-9')"
  [ -n "$r" ] || r="iad"
  printf '%s' "$r"
}
discover_self_server_id() {
  local ips_json server_json
  ips_json="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk 'NF' | \
    python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  server_json="$(openstack server list --long -f json 2>/dev/null || true)"
  LOCAL_IPS_JSON="$ips_json" SERVER_JSON="$server_json" python3 - <<'PY' 2>/dev/null || true
import json, os
try: rows = json.loads(os.environ.get("SERVER_JSON") or "[]")
except Exception: rows = []
try: ips  = json.loads(os.environ.get("LOCAL_IPS_JSON") or "[]")
except Exception: ips  = []
for row in rows:
    blob = json.dumps(row).lower()
    if any(ip and ip.lower() in blob for ip in ips):
        print(row.get("ID") or row.get("Id") or row.get("id") or ""); raise SystemExit
PY
}

# ── VS0: Load + validate OSPC credentials ─────────────────────────────────────
stage "VS0_LOAD_CREDENTIALS"
# shellcheck disable=SC1090
source "$OSPC_OPENRC"
OSPC_TOKEN="${OS_TOKEN:-}"
OSPC_TENANT="${OS_TENANT_ID:-${OS_PROJECT_ID:-}}"
[ -n "$OSPC_TOKEN" ]  || fail_exit "OS_TOKEN not set in $OSPC_OPENRC"
[ -n "$OSPC_TENANT" ] || fail_exit "OS_TENANT_ID not set in $OSPC_OPENRC"
OSPC_API_REGION="$(region_short)"
OSPC_BS_BASE="https://${OSPC_API_REGION}.blockstorage.api.rackspacecloud.com/v1/$OSPC_TENANT"
OSPC_COMPUTE_BASE="https://${OSPC_API_REGION}.servers.api.rackspacecloud.com/v2/$OSPC_TENANT"
kv "OSPC tenant"   "$OSPC_TENANT"
kv "OSPC region"   "$OSPC_API_REGION"
kv "Snapshot ID"   "$SNAPSHOT_ID"
kv "Label"         "$LABEL_SAFE"
validate_flex_helper_server
select_flex_helper_ssh_user
kv "FLEX helper"   "${FLEX_HELPER_USER}@${FLEX_HELPER_IP} (vm=${FLEX_HELPER_VM_ID:-none})"

# ── VS1: Create temp OSPC Cinder volume from snapshot ─────────────────────────
stage "VS1_CREATE_TEMP_OSPC_VOLUME"

# Auto-detect snapshot size if not overridden
if [ "$SNAP_SIZE_GB" -le 0 ] 2>/dev/null; then
  SNAP_SIZE_GB="$(_cinder_get "snapshots/$SNAPSHOT_ID" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["snapshot"]["size"])' 2>/dev/null || echo 75)"
  log "[VS1] Auto-detected snapshot size: ${SNAP_SIZE_GB}GB"
fi
[ "$SNAP_SIZE_GB" -gt 0 ] 2>/dev/null || fail_exit "Could not determine snapshot size"
SNAP_SIZE_ORIG_GB="$SNAP_SIZE_GB"
# OSPC Cinder requires minimum 75 GB per volume; use 80 GB default floor for headroom
if [ "$SNAP_SIZE_GB" -lt 80 ] 2>/dev/null; then
  log "[VS1] Snapshot size ${SNAP_SIZE_GB}GB below minimum — using 80GB for OSPC temp vol (FLEX vol stays ${SNAP_SIZE_ORIG_GB}GB)"
  SNAP_SIZE_GB=80
fi

SNAP_STATUS="$(_cinder_get "snapshots/$SNAPSHOT_ID" | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["snapshot"]["status"])' 2>/dev/null || echo unknown)"
[ "$SNAP_STATUS" = "available" ] || fail_exit "Snapshot $SNAPSHOT_ID not available (status=$SNAP_STATUS)"
kv "Snapshot status" "$SNAP_STATUS"
kv "Snapshot size"   "${SNAP_SIZE_GB}GB"

OSPC_VOL_NAME="tmp-osflex-${LABEL_SAFE}-${RUN_ID}"
PAYLOAD="$(SNAP_ID="$SNAPSHOT_ID" SIZE="$SNAP_SIZE_GB" VNAME="$OSPC_VOL_NAME" python3 - <<'PY'
import json, os
print(json.dumps({"volume":{"snapshot_id":os.environ["SNAP_ID"],"size":int(os.environ["SIZE"]),"display_name":os.environ["VNAME"]}},separators=(",",":")))
PY
)"
RESP="$(_cinder_post "volumes" "$PAYLOAD")"
HTTP="$(printf '%s' "$RESP" | awk -F= '/HTTP_CODE=/{print $2}' | tail -1)"
BODY="$(printf '%s' "$RESP" | sed '/^HTTP_CODE=/d')"
case "$HTTP" in 200|202) ;; *) fail_exit "Cinder volume create HTTP=$HTTP body=${BODY:0:200}" ;; esac
OSPC_VOL_ID="$(printf '%s' "$BODY" | python3 -c \
  'import json,sys; print((json.load(sys.stdin).get("volume") or {}).get("id",""))' 2>/dev/null || true)"
[ -n "$OSPC_VOL_ID" ] || fail_exit "No volume ID in create response: ${BODY:0:300}"
kv "OSPC temp vol"   "$OSPC_VOL_ID"
log "[VS1] Waiting for temp volume to become available…"
ospc_wait_volume "$OSPC_VOL_ID" "available" 3600 || fail_exit "Temp volume $OSPC_VOL_ID never became available"
log "[VS1] HIT temp volume available"

# ── VS2: Attach temp OSPC volume to this jumphost ─────────────────────────────
stage "VS2_ATTACH_OSPC_VOLUME"
SELF_SERVER_ID="$(discover_self_server_id | head -1 | tr -d '[:space:]')"
[ -n "$SELF_SERVER_ID" ] || fail_exit "Could not determine jumphost Nova server ID"
kv "Jumphost server" "$SELF_SERVER_ID"

ATTACH_PAYLOAD="$(VOL_ID="$OSPC_VOL_ID" python3 - <<'PY'
import json, os; print(json.dumps({"volumeAttachment":{"volumeId":os.environ["VOL_ID"]}},separators=(",",":")))
PY
)"
ATTACH_RESP="$(_compute_post "servers/$SELF_SERVER_ID/os-volume_attachments" "$ATTACH_PAYLOAD")"
ATTACH_HTTP="$(printf '%s' "$ATTACH_RESP" | awk -F= '/HTTP_CODE=/{print $2}' | tail -1)"
case "$ATTACH_HTTP" in 200|202) ;; *) fail_exit "Volume attach HTTP=$ATTACH_HTTP" ;; esac
log "[VS2] Attach request OK — waiting in-use"
ospc_wait_volume "$OSPC_VOL_ID" "in-use" 300 || fail_exit "Temp volume did not reach in-use"

# Detect source device from Cinder attachment record (avoids parallel-job race)
if [ -n "$SOURCE_DEVICE_OVERRIDE" ]; then
  SOURCE_DEV="$SOURCE_DEVICE_OVERRIDE"
  log "[VS2] Source device overridden: $SOURCE_DEV"
else
  SOURCE_DEV=""
  for _i in $(seq 1 24); do
    sleep 5
    SOURCE_DEV="$(_cinder_get "volumes/$OSPC_VOL_ID" | python3 -c \
      'import json,sys; v=json.load(sys.stdin)["volume"]; a=v.get("attachments") or []; print(a[0]["device"] if a else "")' \
      2>/dev/null || true)"
    [ -n "$SOURCE_DEV" ] && [ -b "$SOURCE_DEV" ] && break
    SOURCE_DEV=""
  done
  [ -n "$SOURCE_DEV" ] || fail_exit "Could not get source device from Cinder for vol $OSPC_VOL_ID"
fi
kv "Source device" "$SOURCE_DEV"

# ── VS3: Get source device size ───────────────────────────────────────────────
stage "VS3_GET_SOURCE_SIZE"
SOURCE_BYTES="$(sudo blockdev --getsize64 "$SOURCE_DEV" 2>/dev/null || echo 0)"
[ "$SOURCE_BYTES" -gt 1073741824 ] || fail_exit "Source device $SOURCE_DEV too small: ${SOURCE_BYTES}B"
kv "Source bytes" "$SOURCE_BYTES"
kv "Source GB"    "$(( SOURCE_BYTES / 1073741824 ))"

# ── VS4: Create blank FLEX Cinder volume ──────────────────────────────────────
stage "VS4_CREATE_FLEX_CINDER_VOLUME"
# Unset OSPC token vars before sourcing FLEX openrc — OS_TOKEN + OS_AUTH_TYPE=token
# from OSPC openrc crash the password auth plugin with "unexpected keyword argument 'token'"
unset OS_TOKEN OS_AUTH_TYPE OS_AUTH_URL OS_TENANT_ID OS_TENANT_NAME \
      OS_REGION_NAME OS_IDENTITY_API_VERSION OS_INTERFACE \
      OS_PROJECT_ID OS_PROJECT_NAME OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_ID
# shellcheck disable=SC1090
source "$FLEX_OPENRC"
openstack token issue >/dev/null 2>&1 || fail_exit "FLEX authentication failed — check $FLEX_OPENRC"

# FLEX encrypted Cinder can expose a guest block device slightly smaller than
# the requested size because of provider-side encryption/header reservation.
# Use +1GiB headroom so a full original-size block stream does not hit EOD.
FLEX_VOL_SIZE_GB=$(( SNAP_SIZE_ORIG_GB + 1 ))
FLEX_VOL_NAME="${FLEX_VOLUME_NAME_OVERRIDE:-mig-${LABEL_SAFE}-flex}"
kv "FLEX volume name" "$FLEX_VOL_NAME"
kv "FLEX volume size" "${FLEX_VOL_SIZE_GB}GB"
log "[VS4] FLEX volume includes +1GB safety headroom for encrypted Cinder presented-size differences"
flex_cleanup_existing_mig_volumes "$FLEX_VOL_NAME"

FLEX_VOL_ID="$(openstack volume create \
  --size "$FLEX_VOL_SIZE_GB" \
  --format value -c id \
  "$FLEX_VOL_NAME" 2>>"$JOB_LOG/flex_cinder.log" || true)"
[ -n "$FLEX_VOL_ID" ] || fail_exit "openstack volume create failed — check $JOB_LOG/flex_cinder.log"
kv "FLEX volume ID" "$FLEX_VOL_ID"
log "[VS4] Waiting for FLEX volume to become available…"
flex_wait_volume "$FLEX_VOL_ID" "available" 3600 || fail_exit "FLEX volume $FLEX_VOL_ID never became available"
log "[VS4] HIT FLEX volume available"

# ── VS5: Attach blank FLEX volume to FLEX helper VM ───────────────────────────
stage "VS5_ATTACH_FLEX_VOLUME_TO_HELPER"
FLEX_PRE_ATTACH_DISKS=""
if [ -n "$FLEX_HELPER_VM_ID" ]; then
  FLEX_PRE_ATTACH_DISKS="$(flex_remote_block_disks | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [ -n "$FLEX_PRE_ATTACH_DISKS" ]; then
    log "[VS5] FLEX helper disks before attach: $FLEX_PRE_ATTACH_DISKS"
  else
    log "[VS5] FLEX helper pre-attach disk scan empty; will still use Cinder-reported device"
  fi
  log "[VS5] Attaching $FLEX_VOL_ID to FLEX helper vm=$FLEX_HELPER_VM_ID"
  openstack server add volume "$FLEX_HELPER_VM_ID" "$FLEX_VOL_ID" \
    2>>"$JOB_LOG/flex_cinder.log" || fail_exit "openstack server add volume failed"
  log "[VS5] Waiting for FLEX volume in-use…"
  flex_wait_volume "$FLEX_VOL_ID" "in-use" 300 || fail_exit "FLEX volume did not reach in-use"
  log "[VS5] FLEX volume in-use"
else
  log "[VS5] No FLEX helper VM ID provided — skipping API attach (assuming volume pre-attached or TARGET_DEVICE_OVERRIDE set)"
fi

# ── VS6: Detect target device on FLEX helper ──────────────────────────────────
stage "VS6_DETECT_FLEX_TARGET_DEVICE"
if [ -n "$TARGET_DEVICE_OVERRIDE" ]; then
  FLEX_TARGET_DEV="$TARGET_DEVICE_OVERRIDE"
  log "[VS6] Target device overridden: $FLEX_TARGET_DEV"
elif [ -n "$FLEX_HELPER_VM_ID" ]; then
  # Full path: poll Cinder API for the exact attachment device.
  FLEX_TARGET_DEV=""
  for _i in $(seq 1 24); do
    sleep 5
    FLEX_TARGET_DEV="$(flex_volume_device "$FLEX_VOL_ID" || true)"
    [ -n "$FLEX_TARGET_DEV" ] && break
    FLEX_TARGET_DEV=""
  done
  [ -n "$FLEX_TARGET_DEV" ] || fail_exit "Cinder did not report target device for FLEX volume $FLEX_VOL_ID — pass --target-device explicitly"
else
  fail_exit "No FLEX helper VM ID was provided — set --target-device explicitly if the FLEX volume is already attached"
fi
kv "FLEX target device" "$FLEX_TARGET_DEV"

# Safety: never allow target to be mounted or be the root device
case "$FLEX_TARGET_DEV" in /dev/*) ;; *) fail_exit "FLEX target device must be a /dev path: $FLEX_TARGET_DEV" ;; esac
printf '%s' "$FLEX_TARGET_DEV" | grep -Eq '^/dev/[A-Za-z0-9._/-]+$' || fail_exit "Unsafe FLEX target device path: $FLEX_TARGET_DEV"
FLEX_TARGET_DEV_REPORTED="$FLEX_TARGET_DEV"
FLEX_TARGET_DEV_READY=""
for _i in $(seq 1 24); do
  if flex_remote_device_is_safe "$FLEX_TARGET_DEV_REPORTED"; then
    FLEX_TARGET_DEV="$FLEX_TARGET_DEV_REPORTED"
    FLEX_TARGET_DEV_READY="true"
    break
  fi
  FLEX_TARGET_DEV_FALLBACK="$(flex_find_new_safe_disk "$FLEX_PRE_ATTACH_DISKS")"
  if [ -n "$FLEX_TARGET_DEV_FALLBACK" ] && flex_remote_device_is_safe "$FLEX_TARGET_DEV_FALLBACK"; then
    if [ "$FLEX_TARGET_DEV_FALLBACK" != "$FLEX_TARGET_DEV_REPORTED" ]; then
      log "[VS6] Remapped Cinder device to guest device: $FLEX_TARGET_DEV_REPORTED -> $FLEX_TARGET_DEV_FALLBACK"
    fi
    FLEX_TARGET_DEV="$FLEX_TARGET_DEV_FALLBACK"
    FLEX_TARGET_DEV_READY="true"
    break
  fi
  [ $((_i % 6)) -eq 0 ] && log "[VS6] Waiting for new safe FLEX guest disk (${_i}/24)"
  sleep 5
done
[ "$FLEX_TARGET_DEV_READY" = "true" ] || {
  log "[VS6] Current FLEX helper disks: $(flex_remote_block_disks | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  fail_exit "FLEX target device $FLEX_TARGET_DEV_REPORTED is root, mounted, missing, or unsafe — aborting to prevent data loss"
}
kv "FLEX target device" "$FLEX_TARGET_DEV"

# ── VS7: Validate target_bytes >= source_bytes ────────────────────────────────
stage "VS7_VALIDATE_SIZES"
# blockdev --getsize64 can return 0 immediately after attach while the kernel
# is still initializing the block device — retry up to 60s
TARGET_BYTES=0
for _i in $(seq 1 12); do
  TARGET_BYTES="$(ssh_flex "sudo blockdev --getsize64 $FLEX_TARGET_DEV" 2>/dev/null || echo 0)"
  [ "${TARGET_BYTES:-0}" -gt 0 ] 2>/dev/null && break
  log "[VS7] Device not ready (size=0) — retry ${_i}/12 in 5s"
  sleep 5
done
kv "Target bytes" "$TARGET_BYTES"
kv "Source bytes" "$SOURCE_BYTES"
# Compare FLEX target against original snapshot size (not padded OSPC vol which may be 80GB).
# The target must be large enough for the exact byte stream; otherwise dd fails
# at the end and leaves a partial destination volume.
STREAM_BYTES=$(( SNAP_SIZE_ORIG_GB * 1073741824 ))
kv "Stream bytes (orig ${SNAP_SIZE_ORIG_GB}GB)" "$STREAM_BYTES"
[ "${TARGET_BYTES}" -ge "${STREAM_BYTES}" ] || \
  fail_exit "FLEX target too small for exact stream: ${TARGET_BYTES}B < ${STREAM_BYTES}B (original snapshot ${SNAP_SIZE_ORIG_GB}GB; recreate FLEX volume with +1GB headroom)"
log "[VS7] Size validation passed (target=${TARGET_BYTES}B stream=${STREAM_BYTES}B)"

# ── VS8: Direct block stream ──────────────────────────────────────────────────
stage "VS8_STREAM_BLOCK_DATA"
log "[VS8] Streaming $SOURCE_DEV → ${FLEX_HELPER_USER}@${FLEX_HELPER_IP}:${FLEX_TARGET_DEV}"
log "[VS8] Pipeline: dd | gzip -1 | ssh | gunzip | dd"

_DD_COUNT=$(( SNAP_SIZE_ORIG_GB * 16 ))  # 64M * 16 = 1 GiB → count = orig GB * 16
log "[VS8] Streaming ${SNAP_SIZE_ORIG_GB}GB (${_DD_COUNT} blocks of 64M)"
set +e
(
  set -o pipefail
  sudo dd if="$SOURCE_DEV" bs=64M count="$_DD_COUNT" status=progress conv=sync,noerror 2>>"$JOB_LOG/stream_src.log" \
    | gzip -1 \
    | "${SSH_FLEX_BASE[@]}" "gunzip | sudo dd of='$FLEX_TARGET_DEV' bs=64M status=progress conv=fsync 2>>/tmp/volsnap_stream_dst_${LABEL_SAFE}.log" \
    2>&1 | tee -a "$JOB_LOG/stream.log"
) &
STREAM_PID=$!
while kill -0 "$STREAM_PID" 2>/dev/null; do
  sleep 60
  if kill -0 "$STREAM_PID" 2>/dev/null; then
    STREAM_DONE_BYTES="$(python3 - "$JOB_LOG/stream_src.log" <<'PY' 2>/dev/null || true
import re, sys
path = sys.argv[1]
try:
    data = open(path, "rb").read().decode("utf-8", "ignore")
except Exception:
    data = ""
matches = re.findall(r"(\d+)\s+bytes", data)
print(matches[-1] if matches else "")
PY
)"
    if [ -n "$STREAM_DONE_BYTES" ]; then
      log "[VS8] Streaming progress: ${STREAM_DONE_BYTES}/${STREAM_BYTES} bytes"
    else
      log "[VS8] Streaming progress: active"
    fi
  fi
done
wait "$STREAM_PID"
STREAM_RC=$?
set -e
[ "$STREAM_RC" -eq 0 ] || fail_exit "Block stream failed rc=$STREAM_RC — check $JOB_LOG/stream.log"
log "[VS8] HIT block stream complete"

# ── VS9: Validate FLEX target disk ────────────────────────────────────────────
stage "VS9_VALIDATE_FLEX_DISK"
ssh_flex "sudo partprobe $FLEX_TARGET_DEV 2>/dev/null || true; \
  echo '--- blkid ---'; sudo blkid 2>/dev/null || true; \
  echo '--- file -s ---'; sudo file -s $FLEX_TARGET_DEV 2>/dev/null || true; \
  echo '--- lsblk ---'; lsblk $FLEX_TARGET_DEV 2>/dev/null || true" \
  2>&1 | tee -a "$JOB_LOG/flex_validate.log" || true
log "[VS9] Validation output saved to $JOB_LOG/flex_validate.log"

# ── VS10: Detach FLEX volume from helper VM ───────────────────────────────────
stage "VS10_DETACH_FLEX_FROM_HELPER"
if [ -n "$FLEX_HELPER_VM_ID" ]; then
  log "[VS10] Detaching $FLEX_VOL_ID from helper vm=$FLEX_HELPER_VM_ID"
  openstack server remove volume "$FLEX_HELPER_VM_ID" "$FLEX_VOL_ID" \
    2>>"$JOB_LOG/flex_cinder.log" || log "[VS10] WARN: remove volume returned non-zero (continuing)"
  flex_wait_volume "$FLEX_VOL_ID" "available" 300 || log "[VS10] WARN: FLEX volume did not return to available quickly"
  log "[VS10] FLEX volume detached from helper"
else
  log "[VS10] No FLEX helper VM ID — skipping API detach"
fi

# ── VS11: Attach FLEX volume to paired migrated FLEX VM ───────────────────────
FINAL_ATTACH_DEVICE=""
FINAL_TARGET_VM_ID="${FLEX_TARGET_VM_ID:-$FLEX_HELPER_VM_ID}"
if [ "$ATTACH_TO_FINAL" = "true" ] && [ -n "$FLEX_TARGET_VM_ID" ]; then
  stage "VS11_ATTACH_TO_FINAL_FLEX_VM"
  kv "Final FLEX VM" "$FLEX_TARGET_VM_ID"
  openstack server add volume "$FLEX_TARGET_VM_ID" "$FLEX_VOL_ID" \
    2>>"$JOB_LOG/flex_cinder.log" || fail_exit "Final attach to $FLEX_TARGET_VM_ID failed"
  flex_wait_volume "$FLEX_VOL_ID" "in-use" 300 || \
    log "[VS11] WARN: FLEX volume did not reach in-use after final attach"
  log "[VS11] HIT FLEX volume attached to final VM $FLEX_TARGET_VM_ID"
  FLEX_FINAL_ATTACHED=1
  FINAL_ATTACH_DEVICE="$(flex_volume_device "$FLEX_VOL_ID" || true)"
  [ -n "$FINAL_ATTACH_DEVICE" ] && log "[VS11] Final attachment device: $FINAL_ATTACH_DEVICE"
elif [ "$ATTACH_TO_FINAL" = "true" ] && [ -n "$FLEX_HELPER_VM_ID" ]; then
  stage "VS11_ATTACH_TO_FINAL_FLEX_VM"
  kv "Final FLEX VM" "$FLEX_HELPER_VM_ID (helper reused as final target)"
  openstack server add volume "$FLEX_HELPER_VM_ID" "$FLEX_VOL_ID" \
    2>>"$JOB_LOG/flex_cinder.log" || fail_exit "Final attach to helper/final target $FLEX_HELPER_VM_ID failed"
  flex_wait_volume "$FLEX_VOL_ID" "in-use" 300 || \
    log "[VS11] WARN: FLEX volume did not reach in-use after final attach"
  log "[VS11] HIT FLEX volume attached to final VM $FLEX_HELPER_VM_ID"
  FLEX_FINAL_ATTACHED=1
  FINAL_ATTACH_DEVICE="$(flex_volume_device "$FLEX_VOL_ID" || true)"
  [ -n "$FINAL_ATTACH_DEVICE" ] && log "[VS11] Final attachment device: $FINAL_ATTACH_DEVICE"
else
  log "[VS11] Skipped final attach (attach_to_final=$ATTACH_TO_FINAL flex_target_vm_id='${FLEX_TARGET_VM_ID}')"
fi

# ── VOL_POST_ATTACH_VALIDATE: mount migrated volume + optional PostgreSQL query ──
if [ "$POST_ATTACH_VALIDATE_MOUNT" = "true" ] || [ "$POST_ATTACH_VALIDATE_PG" = "true" ]; then
  stage "VOL_POST_ATTACH_VALIDATE"
  [ -n "$FINAL_TARGET_VM_ID" ] || fail_exit "Post-attach validation requested but no final FLEX target VM is known"
  [ "$ATTACH_TO_FINAL" = "true" ] || fail_exit "Post-attach validation requires attach_to_final=true"
  if [ ! -f "$POST_ATTACH_SCRIPT_PATH" ]; then
    fail_exit "Post-attach script not found on jumphost: $POST_ATTACH_SCRIPT_PATH"
  fi

  TARGET_SSH_IP="$POST_ATTACH_SSH_IP"
  if [ -z "$TARGET_SSH_IP" ]; then
    TARGET_SSH_IP="$(flex_server_first_ip "$FINAL_TARGET_VM_ID" | tail -1 | tr -d '[:space:]')"
  fi
  if [ -z "$TARGET_SSH_IP" ]; then
    TARGET_SSH_IP="$FLEX_HELPER_IP"
    log "[VOL_POST_ATTACH_VALIDATE] WARN: could not resolve final VM IP from OpenStack; using FLEX helper IP $TARGET_SSH_IP"
  fi
  [ -n "$TARGET_SSH_IP" ] || fail_exit "Could not determine target VM SSH IP for post-attach validation"

  if [ -z "$POST_ATTACH_DEVICE_HINT" ]; then
    POST_ATTACH_DEVICE_HINT="$FINAL_ATTACH_DEVICE"
  fi

  VALIDATE_LOG="$JOB_ART/post_attach_validate_${FLEX_VOL_ID}.log"
  VALIDATE_JSON="$JOB_ART/post_attach_validate_${FLEX_VOL_ID}.json"
  REMOTE_VALIDATE_SCRIPT="/tmp/osflex_post_attach_pg_mount_validate.sh"
  : >"$VALIDATE_LOG"
  select_post_attach_ssh_user "$TARGET_SSH_IP"
  log "[VOL_POST_ATTACH_VALIDATE] Target SSH: ${POST_ATTACH_SSH_USER}@${TARGET_SSH_IP}"
  log "[VOL_POST_ATTACH_VALIDATE] Device hint: ${POST_ATTACH_DEVICE_HINT:-auto}"
  log "[VOL_POST_ATTACH_VALIDATE] Mount override: ${POST_ATTACH_MOUNT_POINT:-auto}"
  log "[VOL_POST_ATTACH_VALIDATE] DB validator: ${POST_ATTACH_DB_VALIDATOR}"

  scp -i "$POST_ATTACH_SSH_KEY_PATH" \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=30 \
    "$POST_ATTACH_SCRIPT_PATH" "${POST_ATTACH_SSH_USER}@${TARGET_SSH_IP}:${REMOTE_VALIDATE_SCRIPT}" \
    >>"$VALIDATE_LOG" 2>&1 || fail_exit "Failed to upload post-attach validation script"

  set +e
  ssh -i "$POST_ATTACH_SSH_KEY_PATH" \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=30 \
    "${POST_ATTACH_SSH_USER}@${TARGET_SSH_IP}" \
    "sudo DEV_HINT='${POST_ATTACH_DEVICE_HINT}' MOUNT_POINT='${POST_ATTACH_MOUNT_POINT}' DB_NAME='${POST_ATTACH_PG_DB_NAME}' TABLE_NAME='${POST_ATTACH_PG_TABLE_NAME}' VALIDATE_PG='${POST_ATTACH_VALIDATE_PG}' DB_VALIDATOR='${POST_ATTACH_DB_VALIDATOR}' CUSTOM_VALIDATE_CMD='${POST_ATTACH_CUSTOM_VALIDATE_CMD}' ALLOW_LVM='${POST_ATTACH_ALLOW_LVM_ACTIVATE}' ALLOW_LUKS='${POST_ATTACH_ALLOW_LUKS_OPEN}' UPDATE_PG_CONF='${POST_ATTACH_UPDATE_POSTGRESQL_CONF}' START_POSTGRES='${POST_ATTACH_START_POSTGRESQL}' bash '$REMOTE_VALIDATE_SCRIPT'" \
    2>&1 | tee -a "$VALIDATE_LOG"
  VALIDATE_RC=${PIPESTATUS[0]}
  set -e

  ROW_COUNT="$(awk '/Row count:/{flag=1; next} flag && $0 ~ /^[[:space:]]*[0-9]+[[:space:]]*$/ {print; exit}' "$VALIDATE_LOG" 2>/dev/null | tr -d '[:space:]' || true)"
  python3 - "$VALIDATE_JSON" "$VALIDATE_RC" "$FLEX_VOL_ID" "$POST_ATTACH_DEVICE_HINT" "$POST_ATTACH_MOUNT_POINT" "$POST_ATTACH_PG_DB_NAME" "$POST_ATTACH_PG_TABLE_NAME" "${ROW_COUNT:-}" <<'PY'
import json, sys
path, rc, vol, dev, mp, db, table, rows = sys.argv[1:]
status = "success" if rc == "0" else "failed"
payload = {
    "post_attach_validation_status": status,
    "flex_volume_id": vol,
    "attached_device_hint": dev,
    "post_attach_mount_point": mp,
    "db_name": db,
    "table_name": table,
    "post_attach_query_row_count": int(rows) if rows.isdigit() else None,
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
PY
  log "[VOL_POST_ATTACH_VALIDATE] Log: $VALIDATE_LOG"
  log "[VOL_POST_ATTACH_VALIDATE] Result JSON: $VALIDATE_JSON"
  [ "$VALIDATE_RC" -eq 0 ] || fail_exit "Post-attach validation failed rc=$VALIDATE_RC"
  log "[VOL_POST_ATTACH_VALIDATE] HIT validation complete"
else
  log "[VOL_POST_ATTACH_VALIDATE] skipped (post_attach_validate_mount=false)"
fi

# ── VS12: Cleanup — detach + optionally delete temp OSPC volume ───────────────
stage "VS12_CLEANUP_OSPC"
log "[VS12] Detaching temp OSPC vol=$OSPC_VOL_ID from server=$SELF_SERVER_ID"
# Switch back to OSPC env for cleanup
# shellcheck disable=SC1090
source "$OSPC_OPENRC"
_compute_delete "servers/$SELF_SERVER_ID/os-volume_attachments/$OSPC_VOL_ID"
ospc_wait_volume "$OSPC_VOL_ID" "available" 300 || true

if [ "$CLEANUP_TEMP" = "true" ]; then
  log "[VS12] Deleting temp OSPC volume $OSPC_VOL_ID"
  _cinder_delete "volumes/$OSPC_VOL_ID"
  log "[VS12] Temp OSPC volume deleted"
else
  log "[VS12] cleanup_temp=false — temp OSPC volume $OSPC_VOL_ID left in available state"
fi
CLEANUP_DONE=1

log "══════════════════════════════════════════════════════"
log "  VOLSNAP DIRECT CINDER COMPLETE"
log "══════════════════════════════════════════════════════"
log "  OSPC snapshot         : $SNAPSHOT_ID"
log "  FLEX Cinder volume    : $FLEX_VOL_ID  ($FLEX_VOL_NAME, ${FLEX_VOL_SIZE_GB}GB)"
[ -n "$FLEX_TARGET_VM_ID" ] && log "  Attached to FLEX VM   : $FLEX_TARGET_VM_ID"
log "  Storage path          : Storage → Volumes (not Compute → Images)"
