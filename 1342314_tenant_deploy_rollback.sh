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
delete_load_balancer 'perconaLB'
delete_load_balancer 'LBmariaDB'
delete_load_balancer 'DB_loadbalancer MYSQL'
delete_load_balancer 'u24backend'
delete_load_balancer 'frontend- Load-Balancer-01'

log "Step 2/5: Delete servers"
delete_server 'u24Backend'
delete_server 'Windows Server 2016 + SQL Server 2019'
delete_server 'win2019websql2019'
delete_server 'Windows Server 2019Re'
delete_server 'u24-postgresl'
delete_server 'ospc-jumpHost'
delete_server 'rocky8'
delete_server 'Alma9'
delete_server 'target flex dbaas'
delete_server 'db-replica1'
delete_server 'db-replica2'
delete_server 'u24-FrontEndlaptou24'
delete_server 'VMmigrator'
delete_server 'debianlaptopu24'
delete_server 'u22'
delete_server 'dbian12'
delete_server 'dbian11'
delete_server 'alma8'
delete_server 'rocky9'
delete_server 'debian10'
delete_server 'u20'
delete_server 'dbian10new'
delete_server 'debian11new'
delete_server 'jenkins'

log "Step 3/5: Detach and delete data volumes"
detach_volume_if_needed 'u24Backend' 'u24backend-data-1'
delete_volume 'u24backend-data-1'
detach_volume_if_needed 'Windows Server 2016 + SQL Server 2019' 'windows-server-2016-sql-server-2019-data-1'
delete_volume 'windows-server-2016-sql-server-2019-data-1'
detach_volume_if_needed 'win2019websql2019' 'win2019websql2019-data-1'
delete_volume 'win2019websql2019-data-1'
detach_volume_if_needed 'Windows Server 2019Re' 'windows-server-2019re-data-1'
delete_volume 'windows-server-2019re-data-1'
detach_volume_if_needed 'u24-postgresl' 'u24-postgresl-data-1'
delete_volume 'u24-postgresl-data-1'
detach_volume_if_needed 'ospc-jumpHost' 'ospc-jumphost-data-2'
delete_volume 'ospc-jumphost-data-2'
detach_volume_if_needed 'ospc-jumpHost' 'ospc-jumphost-data-1'
delete_volume 'ospc-jumphost-data-1'
detach_volume_if_needed 'VMmigrator' 'vmmigrator-data-1'
delete_volume 'vmmigrator-data-1'

log "Step 4/5: Delete boot volumes created by deploy script"
delete_volume 'boot-debianlaptopu24'
delete_volume 'boot-u22'
delete_volume 'boot-dbian12'
delete_volume 'boot-dbian11'
delete_volume 'boot-alma8'

log "Step 5/5: Delete tenant network resources"
if resource_exists router "$ROUTER_NAME"; then
  safe_run openstack router remove subnet "$ROUTER_NAME" "$SUBNET_NAME"
  safe_run openstack router unset --external-gateway "$ROUTER_NAME"
  safe_run openstack router delete "$ROUTER_NAME"
fi
safe_run openstack subnet delete "$SUBNET_NAME"
safe_run openstack network delete "$PRIVATE_NETWORK"

log "Rollback script complete."
