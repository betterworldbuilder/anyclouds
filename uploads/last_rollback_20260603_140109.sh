#!/usr/bin/env bash
# AUTO-GENERATED rollback — deletes ONLY resources created in THIS run.
# Pre-existing (reused) resources are NOT touched.
set -uo pipefail
ROLLBACK_AUTO_APPROVE=1
log() { echo "[$(date +%H:%M:%S)] $*"; }
log "Starting rollback: 8 step(s) in reverse creation order"
log "  [1/8] openstack server delete --wait "ospc2flex-rocky9-20260425-2221" 2>/dev/null || openstack server delete "ospc2flex-rocky9-20260425-2221" || true"
openstack server delete --wait "ospc2flex-rocky9-20260425-2221" 2>/dev/null || openstack server delete "ospc2flex-rocky9-20260425-2221" || true
log "  [2/8] openstack server delete --wait "ospc2flex-rocky8-20260425-2221" 2>/dev/null || openstack server delete "ospc2flex-rocky8-20260425-2221" || true"
openstack server delete --wait "ospc2flex-rocky8-20260425-2221" 2>/dev/null || openstack server delete "ospc2flex-rocky8-20260425-2221" || true
log "  [3/8] openstack server delete --wait "ospc2flex-alma8-20260425-2221" 2>/dev/null || openstack server delete "ospc2flex-alma8-20260425-2221" || true"
openstack server delete --wait "ospc2flex-alma8-20260425-2221" 2>/dev/null || openstack server delete "ospc2flex-alma8-20260425-2221" || true
log "  [4/8] openstack server delete --wait "ospc2flex-dbian12-20260425-2221" 2>/dev/null || openstack server delete "ospc2flex-dbian12-20260425-2221" || true"
openstack server delete --wait "ospc2flex-dbian12-20260425-2221" 2>/dev/null || openstack server delete "ospc2flex-dbian12-20260425-2221" || true
log "  [5/8] openstack server delete --wait "ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845" 2>/dev/null || openstack server delete "ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845" || true"
openstack server delete --wait "ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845" 2>/dev/null || openstack server delete "ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845" || true
log "  [6/8] openstack server delete --wait "ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794" 2>/dev/null || openstack server delete "ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794" || true"
openstack server delete --wait "ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794" 2>/dev/null || openstack server delete "ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794" || true
log "  [7/8] openstack server delete --wait "Windows-Vol-Helper" 2>/dev/null || openstack server delete "Windows-Vol-Helper" || true"
openstack server delete --wait "Windows-Vol-Helper" 2>/dev/null || openstack server delete "Windows-Vol-Helper" || true
log "  [8/8] openstack server delete --wait "FlexDFWjumphost" 2>/dev/null || openstack server delete "FlexDFWjumphost" || true"
openstack server delete --wait "FlexDFWjumphost" 2>/dev/null || openstack server delete "FlexDFWjumphost" || true
log "✅  Rollback complete."
