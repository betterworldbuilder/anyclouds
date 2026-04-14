#!/usr/bin/env bash
# create_flex_magnum_cluster.sh — Create a Rackspace Flex Magnum K8s cluster.
#
# Usage:
#   create_flex_magnum_cluster.sh --name NAME --template TPL [options]
#
# Options:
#   --name NAME             Cluster name (required)
#   --template TPL          Magnum cluster template name or UUID (required)
#   --openrc FILE           OpenRC credentials file
#   --masters N             Master node count (default: 3)
#   --workers N             Worker node count (default: 3)
#   --keypair KP            SSH keypair name
#   --kubeconfig-out FILE   Write retrieved kubeconfig to this path
#   --no-wait               Do not wait for cluster to become ready
#   --dry-run               Print commands without executing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLUSTER_NAME=""
TEMPLATE=""
OPENRC=""
MASTERS=3
WORKERS=3
KEYPAIR=""
KUBECONFIG_OUT=""
NO_WAIT=""
DRY_RUN=""
LOG_DIR="${REPO_ROOT}/output/logs"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)            CLUSTER_NAME="$2";   shift 2 ;;
    --template)        TEMPLATE="$2";       shift 2 ;;
    --openrc)          OPENRC="$2";         shift 2 ;;
    --masters)         MASTERS="$2";        shift 2 ;;
    --workers)         WORKERS="$2";        shift 2 ;;
    --keypair)         KEYPAIR="$2";        shift 2 ;;
    --kubeconfig-out)  KUBECONFIG_OUT="$2"; shift 2 ;;
    --no-wait)         NO_WAIT="--no-wait"; shift   ;;
    --dry-run)         DRY_RUN="--dry-run"; shift   ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${CLUSTER_NAME}" || -z "${TEMPLATE}" ]]; then
  echo "Error: --name and --template are required" >&2
  exit 1
fi

ARGS=(create-cluster
  --cluster-name "${CLUSTER_NAME}"
  --template      "${TEMPLATE}"
  --master-count  "${MASTERS}"
  --node-count    "${WORKERS}"
  --log-dir       "${LOG_DIR}"
)
[[ -n "${OPENRC}" ]]         && ARGS+=(--openrc "${OPENRC}")
[[ -n "${KEYPAIR}" ]]        && ARGS+=(--keypair "${KEYPAIR}")
[[ -n "${KUBECONFIG_OUT}" ]] && ARGS+=(--kubeconfig-out "${KUBECONFIG_OUT}")
[[ -n "${NO_WAIT}" ]]        && ARGS+=(--no-wait)
[[ -n "${DRY_RUN}" ]]        && ARGS+=(--dry-run)

mkdir -p "${LOG_DIR}"

echo "=== Create Flex Magnum Cluster ==="
echo "Name: ${CLUSTER_NAME}  Template: ${TEMPLATE}  Masters: ${MASTERS}  Workers: ${WORKERS}"
[[ -n "${DRY_RUN}" ]] && echo "[DRY-RUN MODE]"

python -m ospc_to_flex_k8.cli "${ARGS[@]}"
