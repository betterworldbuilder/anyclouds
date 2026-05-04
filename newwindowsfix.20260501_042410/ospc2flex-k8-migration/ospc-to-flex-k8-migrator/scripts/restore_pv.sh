#!/usr/bin/env bash
# restore_pv.sh — Sync PersistentVolume data from OSPC pods to Flex pods.
#
# Uses kubectl exec + tar to stream data between pods across clusters.
# Requires both clusters to be reachable from this machine simultaneously.
#
# Usage:
#   restore_pv.sh --source-context CTX --source-ns NS --source-pod POD
#                 --target-context CTX --target-ns  NS --target-pod POD
#                 --path /data/path
#                 [--dry-run]
set -euo pipefail

SRC_CTX=""
SRC_NS=""
SRC_POD=""
TGT_CTX=""
TGT_NS=""
TGT_POD=""
DATA_PATH="/data"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-context) SRC_CTX="$2";    shift 2 ;;
    --source-ns)      SRC_NS="$2";     shift 2 ;;
    --source-pod)     SRC_POD="$2";    shift 2 ;;
    --target-context) TGT_CTX="$2";    shift 2 ;;
    --target-ns)      TGT_NS="$2";     shift 2 ;;
    --target-pod)     TGT_POD="$2";    shift 2 ;;
    --path)           DATA_PATH="$2";  shift 2 ;;
    --dry-run)        DRY_RUN=true;    shift   ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

for req in SRC_CTX SRC_NS SRC_POD TGT_CTX TGT_NS TGT_POD; do
  [[ -z "${!req}" ]] && { echo "Error: --${req//_/-} is required" >&2; exit 1; }
done

echo "=== PV Data Sync ==="
echo "Source: ${SRC_CTX}/${SRC_NS}/${SRC_POD}:${DATA_PATH}"
echo "Target: ${TGT_CTX}/${TGT_NS}/${TGT_POD}:${DATA_PATH}"

if $DRY_RUN; then
  echo "[DRY-RUN] kubectl --context=${SRC_CTX} exec -n ${SRC_NS} ${SRC_POD} -- tar czf - ${DATA_PATH} \\"
  echo "          | kubectl --context=${TGT_CTX} exec -i -n ${TGT_NS} ${TGT_POD} -- tar xzf - -C /"
  exit 0
fi

# Ensure target directory exists
kubectl --context="${TGT_CTX}" exec -n "${TGT_NS}" "${TGT_POD}" -- \
  mkdir -p "${DATA_PATH}"

# Stream tar from source → target
kubectl --context="${SRC_CTX}" exec -n "${SRC_NS}" "${SRC_POD}" -- \
  tar czf - "${DATA_PATH}" \
  | kubectl --context="${TGT_CTX}" exec -i -n "${TGT_NS}" "${TGT_POD}" -- \
  tar xzf - -C /

echo "=== PV sync complete: ${DATA_PATH} ==="
