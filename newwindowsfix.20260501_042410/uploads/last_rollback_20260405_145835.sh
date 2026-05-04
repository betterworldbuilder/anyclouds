#!/usr/bin/env bash
# AUTO-GENERATED rollback — deletes ONLY resources created in THIS run.
# Pre-existing (reused) resources are NOT touched.
set -uo pipefail
ROLLBACK_AUTO_APPROVE=1
log() { echo "[$(date +%H:%M:%S)] $*"; }
log "Starting rollback: 2 step(s) in reverse creation order"
log "  [1/2] openstack server delete --wait "debian10-Flav2gv1" 2>/dev/null || openstack server delete "debian10-Flav2gv1" || true"
openstack server delete --wait "debian10-Flav2gv1" 2>/dev/null || openstack server delete "debian10-Flav2gv1" || true
log "  [2/2] openstack server delete --wait "alma9-2gv1" 2>/dev/null || openstack server delete "alma9-2gv1" || true"
openstack server delete --wait "alma9-2gv1" 2>/dev/null || openstack server delete "alma9-2gv1" || true
log "✅  Rollback complete."
