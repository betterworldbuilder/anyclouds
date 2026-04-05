#!/usr/bin/env bash
# AUTO-GENERATED rollback — deletes ONLY resources created in THIS run.
# Pre-existing (reused) resources are NOT touched.
set -uo pipefail
ROLLBACK_AUTO_APPROVE=1
log() { echo "[$(date +%H:%M:%S)] $*"; }
log "Starting rollback: 1 step(s) in reverse creation order"
log "  [1/1] openstack volume delete --force "u24backend-data-1" || true"
openstack volume delete --force "u24backend-data-1" || true
log "✅  Rollback complete."
