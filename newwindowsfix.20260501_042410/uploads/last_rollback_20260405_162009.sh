#!/usr/bin/env bash
# AUTO-GENERATED rollback — deletes ONLY resources created in THIS run.
# Pre-existing (reused) resources are NOT touched.
set -uo pipefail
ROLLBACK_AUTO_APPROVE=1
log() { echo "[$(date +%H:%M:%S)] $*"; }
log "Starting rollback: 4 step(s) in reverse creation order"
log "  [1/4] openstack server delete --wait "rocky8" 2>/dev/null || openstack server delete "rocky8" || true"
openstack server delete --wait "rocky8" 2>/dev/null || openstack server delete "rocky8" || true
log "  [2/4] openstack server delete --wait "u24-FrontEnd 2" 2>/dev/null || openstack server delete "u24-FrontEnd 2" || true"
openstack server delete --wait "u24-FrontEnd 2" 2>/dev/null || openstack server delete "u24-FrontEnd 2" || true
log "  [3/4] openstack server delete --wait "u24-BackEnd-2" 2>/dev/null || openstack server delete "u24-BackEnd-2" || true"
openstack server delete --wait "u24-BackEnd-2" 2>/dev/null || openstack server delete "u24-BackEnd-2" || true
log "  [4/4] openstack server delete --wait "u24-postgresl-2" 2>/dev/null || openstack server delete "u24-postgresl-2" || true"
openstack server delete --wait "u24-postgresl-2" 2>/dev/null || openstack server delete "u24-postgresl-2" || true
log "✅  Rollback complete."
