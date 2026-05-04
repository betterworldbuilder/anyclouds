#!/usr/bin/env bash
# rollback_helper.sh — Point traffic back at the OSPC cluster after a failed cutover.
#
# Rollback actions:
#   1. Scale down workloads on the Flex cluster (stop conflicting writes)
#   2. Re-enable workloads on the OSPC cluster (if previously scaled down)
#   3. Print DNS/LB switchback instructions
#
# Usage:
#   rollback_helper.sh --src-context CTX [--src-kubeconfig FILE]
#                      --tgt-context CTX [--tgt-kubeconfig FILE]
#                      [--namespaces ns1,ns2]
#                      [--dry-run]
set -euo pipefail

SRC_CTX=""
SRC_KC=""
TGT_CTX=""
TGT_KC=""
NAMESPACES=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src-context)     SRC_CTX="$2";  shift 2 ;;
    --src-kubeconfig)  SRC_KC="$2";   shift 2 ;;
    --tgt-context)     TGT_CTX="$2";  shift 2 ;;
    --tgt-kubeconfig)  TGT_KC="$2";   shift 2 ;;
    --namespaces)      NAMESPACES="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=true;  shift   ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "${SRC_CTX}" || -z "${TGT_CTX}" ]] && {
  echo "Error: --src-context and --tgt-context are required" >&2; exit 1
}

run_kubectl() {
  local ctx="$1"; shift
  local kc="$1";  shift
  local flags="--context=${ctx}"
  [[ -n "${kc}" ]] && flags+=" --kubeconfig=${kc}"
  if $DRY_RUN; then
    echo "[DRY-RUN] kubectl ${flags} $*"
  else
    kubectl ${flags} "$@"
  fi
}

echo "========================================"
echo "  ROLLBACK HELPER — OSPC K8 Migration"
echo "========================================"
echo "Source (OSPC): ${SRC_CTX}"
echo "Target (Flex): ${TGT_CTX}"
$DRY_RUN && echo "[DRY-RUN MODE]"
echo ""

# ── Step 1: Scale DOWN flex workloads ────────────────────────────────────────
echo "--- Step 1: Scale down Flex workloads ---"

NS_FLAG="--all-namespaces"
if [[ -n "${NAMESPACES}" ]]; then
  IFS=',' read -ra NS_ARR <<< "${NAMESPACES}"
else
  NS_ARR=()
fi

if [[ ${#NS_ARR[@]} -gt 0 ]]; then
  for ns in "${NS_ARR[@]}"; do
    echo "  Scaling down deployments in Flex namespace: ${ns}"
    run_kubectl "${TGT_CTX}" "${TGT_KC}" scale deployment --all -n "${ns}" --replicas=0
    echo "  Scaling down statefulsets in Flex namespace: ${ns}"
    run_kubectl "${TGT_CTX}" "${TGT_KC}" scale statefulset --all -n "${ns}" --replicas=0
  done
else
  echo "  WARNING: No --namespaces specified. Skipping automatic scale-down."
  echo "  Manually run: kubectl --context=${TGT_CTX} scale deployment --all -n <ns> --replicas=0"
fi

echo ""

# ── Step 2: Scale UP OSPC workloads (if they were scaled down) ───────────────
echo "--- Step 2: Restore OSPC workloads ---"
echo "  NOTE: Only run this if OSPC workloads were scaled down during cutover."
echo ""

if [[ ${#NS_ARR[@]} -gt 0 ]]; then
  for ns in "${NS_ARR[@]}"; do
    echo "  Re-scaling OSPC deployments in namespace: ${ns}"
    # We cannot know the original replica count here; annotate then restore
    run_kubectl "${SRC_CTX}" "${SRC_KC}" \
      get deployment -n "${ns}" -o name \
      | while read -r dep; do
          echo "    Scaling up: ${dep}"
          run_kubectl "${SRC_CTX}" "${SRC_KC}" scale "${dep}" -n "${ns}" --replicas=1
        done
  done
else
  echo "  WARNING: No --namespaces specified. Manually restore OSPC workloads."
fi

echo ""

# ── Step 3: DNS / LB switchback reminder ─────────────────────────────────────
echo "--- Step 3: DNS / Load-Balancer Switchback ---"
echo ""
echo "  If DNS was updated to point to Flex, revert the following records:"
echo "    * A / CNAME records that pointed to Flex Ingress LB IP"
echo "    * Any internal CoreDNS overrides applied to Flex"
echo ""
echo "  If a cloud LB was used, re-point the backend pool to OSPC node IPs."
echo ""
echo "========================================"
echo "  Rollback guidance complete."
echo "  Verify OSPC services are responding before closing incident."
echo "========================================"
