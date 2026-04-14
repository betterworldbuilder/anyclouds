#!/usr/bin/env bash
# smoke_tests.sh — Run post-migration smoke tests against the Flex cluster.
#
# Performs basic connectivity and workload availability checks, then
# calls the Python validator for a full structured report.
#
# Usage:
#   smoke_tests.sh [--context CTX] [--kubeconfig FILE]
#                  [--namespaces ns1,ns2] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONTEXT=""
KUBECONFIG_PATH=""
NAMESPACES=""
DRY_RUN=false
LOG_DIR="${REPO_ROOT}/output/logs"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)     CONTEXT="$2";          shift 2 ;;
    --kubeconfig)  KUBECONFIG_PATH="$2";  shift 2 ;;
    --namespaces)  NAMESPACES="$2";       shift 2 ;;
    --dry-run)     DRY_RUN=true;          shift   ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

KC_FLAGS=""
[[ -n "${CONTEXT}" ]]        && KC_FLAGS+=" --context=${CONTEXT}"
[[ -n "${KUBECONFIG_PATH}" ]] && KC_FLAGS+=" --kubeconfig=${KUBECONFIG_PATH}"

run_kubectl() {
  if $DRY_RUN; then
    echo "[DRY-RUN] kubectl${KC_FLAGS} $*"
    return 0
  fi
  kubectl ${KC_FLAGS} "$@"
}

PASS=0
FAIL=0

check() {
  local label="$1"; shift
  echo -n "  CHECK: ${label} ... "
  if "$@" &>/dev/null; then
    echo "PASS"
    ((PASS++)) || true
  else
    echo "FAIL"
    ((FAIL++)) || true
  fi
}

echo "=== Flex Magnum Smoke Tests ==="
[[ -n "${CONTEXT}" ]] && echo "Context: ${CONTEXT}"

echo ""
echo "-- Cluster connectivity --"
check "API server reachable"    run_kubectl version --short
check "Nodes present"           bash -c "run_kubectl get nodes --no-headers 2>/dev/null | grep -q ."
check "All nodes Ready"         bash -c "! run_kubectl get nodes --no-headers 2>/dev/null | grep -qE 'NotReady|Unknown'"

echo ""
echo "-- Workload health --"
check "No CrashLoopBackOff pods"   bash -c "! run_kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -q CrashLoopBackOff"
check "No ImagePullBackOff pods"   bash -c "! run_kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -q ImagePullBackOff"
check "No Pending PVCs"            bash -c "! run_kubectl get pvc  --all-namespaces --no-headers 2>/dev/null | grep -q Pending"

echo ""
echo "-- Python validator --"
ARGS=(validate --log-dir "${LOG_DIR}")
[[ -n "${CONTEXT}" ]]        && ARGS+=(--context "${CONTEXT}")
[[ -n "${KUBECONFIG_PATH}" ]] && ARGS+=(--kubeconfig "${KUBECONFIG_PATH}")
if [[ -n "${NAMESPACES}" ]]; then
  IFS=',' read -ra NS_ARR <<< "${NAMESPACES}"
  ARGS+=(--namespaces "${NS_ARR[@]}")
fi

if $DRY_RUN; then
  echo "[DRY-RUN] python -m ospc_to_flex_k8.cli ${ARGS[*]}"
else
  python -m ospc_to_flex_k8.cli "${ARGS[@]}" || true
fi

echo ""
echo "=== Smoke Test Summary: PASS=${PASS} FAIL=${FAIL} ==="
[[ "${FAIL}" -eq 0 ]] && exit 0 || exit 1
