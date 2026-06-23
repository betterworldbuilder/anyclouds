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
delete_load_balancer 'backend'
delete_load_balancer 'dblb'
delete_load_balancer 'perconaLB'
delete_load_balancer 'LBmariaDB'
delete_load_balancer 'DB_loadbalancer MYSQL'
delete_load_balancer 'u24backend'
delete_load_balancer 'frontend- Load-Balancer-01'

log "Step 2/5: Delete servers"
delete_server 'IADjumphostu24'
delete_server 'opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio'
delete_server 'Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio'
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
