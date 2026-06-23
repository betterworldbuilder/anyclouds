#!/usr/bin/env bash
# AUTO-GENERATED rollback — deletes ONLY resources created in THIS run.
# Pre-existing (reused) resources are NOT touched.
set -uo pipefail
ROLLBACK_AUTO_APPROVE=1
log() { echo "[$(date +%H:%M:%S)] $*"; }
log "Starting rollback: 6 step(s) in reverse creation order"
log "  [1/6] openstack server delete --wait "IADjumphostu24" 2>/dev/null || openstack server delete "IADjumphostu24" || true"
openstack server delete --wait "IADjumphostu24" 2>/dev/null || openstack server delete "IADjumphostu24" || true
log "  [2/6] openstack server delete --wait "FlexDFWjumphost" 2>/dev/null || openstack server delete "FlexDFWjumphost" || true"
openstack server delete --wait "FlexDFWjumphost" 2>/dev/null || openstack server delete "FlexDFWjumphost" || true
log "  [3/6] openstack loadbalancer delete --cascade "dblb" 2>/dev/null || openstack loadbalancer delete "dblb" || true"
openstack loadbalancer delete --cascade "dblb" 2>/dev/null || openstack loadbalancer delete "dblb" || true
log "  [4/6] openstack loadbalancer delete --cascade "perconaLB" 2>/dev/null || openstack loadbalancer delete "perconaLB" || true"
openstack loadbalancer delete --cascade "perconaLB" 2>/dev/null || openstack loadbalancer delete "perconaLB" || true
log "  [5/6] openstack loadbalancer delete --cascade "LBmariaDB" 2>/dev/null || openstack loadbalancer delete "LBmariaDB" || true"
openstack loadbalancer delete --cascade "LBmariaDB" 2>/dev/null || openstack loadbalancer delete "LBmariaDB" || true
log "  [6/6] openstack loadbalancer delete --cascade "DB_loadbalancer MYSQL" 2>/dev/null || openstack loadbalancer delete "DB_loadbalancer MYSQL" || true"
openstack loadbalancer delete --cascade "DB_loadbalancer MYSQL" 2>/dev/null || openstack loadbalancer delete "DB_loadbalancer MYSQL" || true
log "✅  Rollback complete."
