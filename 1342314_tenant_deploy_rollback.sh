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
delete_server 'Instance-20'
delete_server 'hadbaas-vip-01'
delete_server 'Mariadb'
delete_server 'sql'
delete_server 'mysql8instance'
delete_server 'Instance-21'
delete_server 'hadbaas-vip-03'
delete_server 'mariad1'
delete_server 'HAmysql-01'
delete_server 'Stack-05_Database'
delete_server 'HAdbaasSql-03'
delete_server 'lamp_Database'
delete_server 'HA-mariaDB-03'
delete_server 'HA percona 8-03'
delete_server 'drupalphp_Database'
delete_server 'HA-mariaDB-02'
delete_server 'HA-Mysql8-01'
delete_server 'dbaasmariadb'
delete_server 'drupal'
delete_server 'HA percona 8-02'
delete_server 'rocky8'
delete_server 'Alma9'
delete_server 'dbian12'
delete_server 'alma8'
delete_server 'rocky9'
delete_server 'u20'
delete_server 'dbian10new'
delete_server 'debian11new'
delete_server 'windows2016'
delete_server 'win2019'
delete_server 'centos7'
delete_server 'jenkins'
delete_server 'Bigjim-iad'
delete_server 'bigjumpwindowsiad'
delete_server 'opscwin2016'
delete_server 'ospcwin2019'
delete_server 'mongo db u24'
delete_server 'postgresqlU24'
delete_server 'musicradio'
delete_server 'Server-21'
delete_server 'u-22'
delete_server 'u24 green server'
delete_server 'debian12'
delete_server 'u24clean'
delete_server 'haproxyopsc'
delete_server 'Server-27'

log "Step 3/5: Detach and delete data volumes"
detach_volume_if_needed 'Alma9' 'alma9-data-1'
delete_volume 'alma9-data-1'
detach_volume_if_needed 'u20' 'u20-data-1'
delete_volume 'u20-data-1'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-52'
delete_volume 'bigjim-iad-data-52'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-51'
delete_volume 'bigjim-iad-data-51'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-50'
delete_volume 'bigjim-iad-data-50'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-49'
delete_volume 'bigjim-iad-data-49'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-48'
delete_volume 'bigjim-iad-data-48'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-47'
delete_volume 'bigjim-iad-data-47'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-46'
delete_volume 'bigjim-iad-data-46'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-45'
delete_volume 'bigjim-iad-data-45'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-44'
delete_volume 'bigjim-iad-data-44'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-43'
delete_volume 'bigjim-iad-data-43'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-42'
delete_volume 'bigjim-iad-data-42'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-41'
delete_volume 'bigjim-iad-data-41'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-40'
delete_volume 'bigjim-iad-data-40'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-39'
delete_volume 'bigjim-iad-data-39'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-38'
delete_volume 'bigjim-iad-data-38'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-37'
delete_volume 'bigjim-iad-data-37'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-36'
delete_volume 'bigjim-iad-data-36'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-35'
delete_volume 'bigjim-iad-data-35'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-34'
delete_volume 'bigjim-iad-data-34'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-33'
delete_volume 'bigjim-iad-data-33'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-32'
delete_volume 'bigjim-iad-data-32'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-31'
delete_volume 'bigjim-iad-data-31'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-30'
delete_volume 'bigjim-iad-data-30'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-29'
delete_volume 'bigjim-iad-data-29'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-28'
delete_volume 'bigjim-iad-data-28'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-27'
delete_volume 'bigjim-iad-data-27'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-26'
delete_volume 'bigjim-iad-data-26'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-25'
delete_volume 'bigjim-iad-data-25'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-24'
delete_volume 'bigjim-iad-data-24'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-23'
delete_volume 'bigjim-iad-data-23'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-22'
delete_volume 'bigjim-iad-data-22'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-21'
delete_volume 'bigjim-iad-data-21'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-20'
delete_volume 'bigjim-iad-data-20'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-19'
delete_volume 'bigjim-iad-data-19'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-18'
delete_volume 'bigjim-iad-data-18'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-17'
delete_volume 'bigjim-iad-data-17'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-16'
delete_volume 'bigjim-iad-data-16'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-15'
delete_volume 'bigjim-iad-data-15'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-14'
delete_volume 'bigjim-iad-data-14'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-13'
delete_volume 'bigjim-iad-data-13'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-12'
delete_volume 'bigjim-iad-data-12'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-11'
delete_volume 'bigjim-iad-data-11'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-10'
delete_volume 'bigjim-iad-data-10'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-9'
delete_volume 'bigjim-iad-data-9'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-8'
delete_volume 'bigjim-iad-data-8'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-7'
delete_volume 'bigjim-iad-data-7'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-6'
delete_volume 'bigjim-iad-data-6'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-5'
delete_volume 'bigjim-iad-data-5'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-4'
delete_volume 'bigjim-iad-data-4'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-3'
delete_volume 'bigjim-iad-data-3'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-2'
delete_volume 'bigjim-iad-data-2'
detach_volume_if_needed 'Bigjim-iad' 'bigjim-iad-data-1'
delete_volume 'bigjim-iad-data-1'
detach_volume_if_needed 'bigjumpwindowsiad' 'bigjumpwindowsiad-data-1'
delete_volume 'bigjumpwindowsiad-data-1'
detach_volume_if_needed 'postgresqlU24' 'postgresqlu24-data-1'
delete_volume 'postgresqlu24-data-1'
detach_volume_if_needed 'u24 green server' 'u24-green-server-data-2'
delete_volume 'u24-green-server-data-2'
detach_volume_if_needed 'u24 green server' 'u24-green-server-data-1'
delete_volume 'u24-green-server-data-1'

log "Step 4/5: Delete boot volumes created by deploy script"
delete_volume 'boot-dbian12'
delete_volume 'boot-alma8'
delete_volume 'boot-win2019'
delete_volume 'boot-centos7'
delete_volume 'boot-ospcwin2019'

log "Step 5/5: Delete tenant network resources"
if resource_exists router "$ROUTER_NAME"; then
  safe_run openstack router remove subnet "$ROUTER_NAME" "$SUBNET_NAME"
  safe_run openstack router unset --external-gateway "$ROUTER_NAME"
  safe_run openstack router delete "$ROUTER_NAME"
fi
safe_run openstack subnet delete "$SUBNET_NAME"
safe_run openstack network delete "$PRIVATE_NETWORK"

log "Rollback script complete."
