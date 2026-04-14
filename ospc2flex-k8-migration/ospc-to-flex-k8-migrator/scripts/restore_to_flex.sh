#!/usr/bin/env bash
# restore_to_flex.sh — Apply transformed manifests to the Flex Magnum cluster.
#
# Usage:
#   restore_to_flex.sh --transformed-dir DIR [--context CTX] [--kubeconfig FILE]
#                      [--server-side] [--skip-phases p1 p2] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TRANSFORMED_DIR=""
CONTEXT=""
KUBECONFIG_PATH=""
SERVER_SIDE=""
SKIP_PHASES=()
DRY_RUN=""
LOG_DIR="${REPO_ROOT}/output/logs"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --transformed-dir) TRANSFORMED_DIR="$2"; shift 2 ;;
    --context)         CONTEXT="$2";          shift 2 ;;
    --kubeconfig)      KUBECONFIG_PATH="$2";  shift 2 ;;
    --server-side)     SERVER_SIDE="--server-side"; shift ;;
    --skip-phases)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        SKIP_PHASES+=("$1"); shift
      done
      ;;
    --dry-run) DRY_RUN="--dry-run"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${TRANSFORMED_DIR}" ]]; then
  echo "Error: --transformed-dir is required" >&2
  exit 1
fi

ARGS=(restore
  --transformed-dir "${TRANSFORMED_DIR}"
  --log-dir         "${LOG_DIR}"
)
[[ -n "${CONTEXT}" ]]        && ARGS+=(--context "${CONTEXT}")
[[ -n "${KUBECONFIG_PATH}" ]] && ARGS+=(--kubeconfig "${KUBECONFIG_PATH}")
[[ -n "${SERVER_SIDE}" ]]    && ARGS+=(--server-side)
[[ -n "${DRY_RUN}" ]]        && ARGS+=(--dry-run)
if [[ ${#SKIP_PHASES[@]} -gt 0 ]]; then
  ARGS+=(--skip-phases "${SKIP_PHASES[@]}")
fi

mkdir -p "${LOG_DIR}"

echo "=== Restore to Flex Magnum ==="
echo "Transformed: ${TRANSFORMED_DIR}"
[[ -n "${DRY_RUN}" ]] && echo "[DRY-RUN MODE]"

python -m ospc_to_flex_k8.cli "${ARGS[@]}"
