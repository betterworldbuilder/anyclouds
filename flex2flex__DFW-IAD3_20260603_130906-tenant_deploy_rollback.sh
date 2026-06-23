#!/usr/bin/env bash
set -uo pipefail

PUBLIC_NETWORK='PUBLICNET'
PRIVATE_NETWORK='tenant-net'
SUBNET_NAME='tenant-subnet'
ROUTER_NAME='tenant-router'

log() {
  echo "[$(date +%H:%M:%S)] $*"
}

safe_run() {
  echo "+ $*"
  "$@" || true
}

resource_exists() {
  local kind="$1"
  local name="$2"
  openstack "$kind" show "$name" >/dev/null 2>&1
}

delete_load_balancer() {
  local lb_name="$1"
  if ! resource_exists loadbalancer "$lb_name"; then
    return 0
  fi
  log "Deleting load balancer: $lb_name"
  openstack loadbalancer delete --cascade "$lb_name" >/dev/null 2>&1 || openstack loadbalancer delete "$lb_name" >/dev/null 2>&1 || true
}

delete_server() {
  local server_name="$1"
  if ! resource_exists server "$server_name"; then
    return 0
  fi
  log "Deleting server: $server_name"
  openstack server delete --wait "$server_name" >/dev/null 2>&1 || openstack server delete "$server_name" >/dev/null 2>&1 || true
}

detach_volume_if_needed() {
  local server_name="$1"
  local volume_name="$2"
  [ -z "$server_name" ] && return 0
  resource_exists server "$server_name" || return 0
  resource_exists volume "$volume_name" || return 0
  log "Detaching volume $volume_name from $server_name (if attached)"
  openstack server remove volume "$server_name" "$volume_name" >/dev/null 2>&1 || true
}

delete_volume() {
  local volume_name="$1"
  if ! resource_exists volume "$volume_name"; then
    return 0
  fi
  log "Deleting volume: $volume_name"
  openstack volume delete --force "$volume_name" >/dev/null 2>&1 || openstack volume delete "$volume_name" >/dev/null 2>&1 || true
}

confirm_rollback() {
  if [ "${ROLLBACK_AUTO_APPROVE:-0}" = "1" ]; then
    return 0
  fi
  echo "This rollback will attempt to DELETE generated resources."
  echo "Set ROLLBACK_AUTO_APPROVE=1 to skip confirmation."
  if [ -t 0 ]; then
    read -r -p "Type DELETE to continue: " answer
    [ "$answer" = "DELETE" ] || { echo "Rollback canceled."; exit 1; }
  else
    echo "Non-interactive shell without ROLLBACK_AUTO_APPROVE=1; refusing to continue."
    exit 1
  fi
}

confirm_rollback
log "Starting rollback..."

log "Step 1/5: Delete load balancers"
delete_load_balancer 'u24backend'
delete_load_balancer 'backend'
delete_load_balancer 'frontend- Load-Balancer-01'

log "Step 2/5: Delete servers"
delete_server 'ospc2flex-rocky9-20260425-2221'
delete_server 'ospc2flex-rocky8-20260425-2221'
delete_server 'ospc2flex-alma8-20260425-2221'
delete_server 'ospc2flex-dbian12-20260425-2221'
delete_server 'ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845'
delete_server 'ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794'
delete_server 'Windows-Vol-Helper'
delete_server 'FlexDFWjumphost'

log "Step 5/5: Delete tenant network resources"
if resource_exists router "$ROUTER_NAME"; then
  safe_run openstack router remove subnet "$ROUTER_NAME" "$SUBNET_NAME"
  safe_run openstack router unset --external-gateway "$ROUTER_NAME"
  safe_run openstack router delete "$ROUTER_NAME"
fi
safe_run openstack subnet delete "$SUBNET_NAME"
safe_run openstack network delete "$PRIVATE_NETWORK"

log "Rollback script complete."
