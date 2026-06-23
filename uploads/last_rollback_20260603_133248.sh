#!/usr/bin/env bash
# AUTO-GENERATED rollback — deletes ONLY resources created in THIS run.
# Pre-existing (reused) resources are NOT touched.
set -uo pipefail
ROLLBACK_AUTO_APPROVE=1
log() { echo "[$(date +%H:%M:%S)] $*"; }
log "Starting rollback: 1 step(s) in reverse creation order"
log "  [1/1] openstack server delete --wait "ospc2flex-dbian12-20260425-2221" 2>/dev/null || openstack server delete "ospc2flex-dbian12-20260425-2221" || true"
openstack server delete --wait "ospc2flex-dbian12-20260425-2221" 2>/dev/null || openstack server delete "ospc2flex-dbian12-20260425-2221" || true
log "✅  Rollback complete."
