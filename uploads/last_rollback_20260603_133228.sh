#!/usr/bin/env bash
# AUTO-GENERATED rollback — deletes ONLY resources created in THIS run.
# Pre-existing (reused) resources are NOT touched.
set -uo pipefail
ROLLBACK_AUTO_APPROVE=1
log() { echo "[$(date +%H:%M:%S)] $*"; }
log "Starting rollback: 1 step(s) in reverse creation order"
log "  [1/1] openstack server delete --wait "ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845" 2>/dev/null || openstack server delete "ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845" || true"
openstack server delete --wait "ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845" 2>/dev/null || openstack server delete "ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845" || true
log "✅  Rollback complete."
