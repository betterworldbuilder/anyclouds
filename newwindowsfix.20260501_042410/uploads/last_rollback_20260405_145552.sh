#!/usr/bin/env bash
# AUTO-GENERATED rollback — deletes ONLY resources created in THIS run.
# Pre-existing (reused) resources are NOT touched.
set -uo pipefail
ROLLBACK_AUTO_APPROVE=1
log() { echo "[$(date +%H:%M:%S)] $*"; }
log "Starting rollback: 6 step(s) in reverse creation order"
log "  [1/6] openstack volume delete --force "windows-server-2016-sql-server-2019-data-1" || true"
openstack volume delete --force "windows-server-2016-sql-server-2019-data-1" || true
log "  [2/6] openstack volume delete --force "win2019websql2019-data-1" || true"
openstack volume delete --force "win2019websql2019-data-1" || true
log "  [3/6] openstack volume delete --force "windows-server-2019re-data-1" || true"
openstack volume delete --force "windows-server-2019re-data-1" || true
log "  [4/6] openstack volume delete --force "u24-frontend-data-2" || true"
openstack volume delete --force "u24-frontend-data-2" || true
log "  [5/6] openstack volume delete --force "u24-frontend-data-1" || true"
openstack volume delete --force "u24-frontend-data-1" || true
log "  [6/6] openstack volume delete --force "u24-postgresl-data-1" || true"
openstack volume delete --force "u24-postgresl-data-1" || true
log "✅  Rollback complete."
