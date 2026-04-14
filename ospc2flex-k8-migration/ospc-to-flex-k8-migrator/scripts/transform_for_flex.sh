#!/usr/bin/env bash
# transform_for_flex.sh — Transform exported OSPC manifests for Flex Magnum.
#
# Usage:
#   transform_for_flex.sh --source-dir DIR --output-dir DIR [--plan FILE] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SOURCE_DIR=""
OUTPUT_DIR="${REPO_ROOT}/output/transformed"
PLAN_FILE=""
DRY_RUN=""
LOG_DIR="${REPO_ROOT}/output/logs"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir)  SOURCE_DIR="$2";  shift 2 ;;
    --output-dir)  OUTPUT_DIR="$2";  shift 2 ;;
    --plan)        PLAN_FILE="$2";   shift 2 ;;
    --dry-run)     DRY_RUN="--dry-run"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${SOURCE_DIR}" ]]; then
  echo "Error: --source-dir is required" >&2
  exit 1
fi

ARGS=(transform
  --source-dir "${SOURCE_DIR}"
  --output-dir "${OUTPUT_DIR}"
  --log-dir    "${LOG_DIR}"
)
[[ -n "${PLAN_FILE}" ]] && ARGS+=(--plan "${PLAN_FILE}")
[[ -n "${DRY_RUN}" ]]   && ARGS+=(--dry-run)

mkdir -p "${OUTPUT_DIR}" "${LOG_DIR}"

echo "=== Transform Manifests for Flex ==="
echo "Source: ${SOURCE_DIR}"
echo "Output: ${OUTPUT_DIR}"
[[ -n "${DRY_RUN}" ]] && echo "[DRY-RUN MODE]"

python -m ospc_to_flex_k8.cli "${ARGS[@]}"
