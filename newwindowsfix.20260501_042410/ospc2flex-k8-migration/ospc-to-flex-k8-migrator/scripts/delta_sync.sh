#!/usr/bin/env bash
# delta_sync.sh — Re-export + re-transform changed resources (delta sync).
#
# Re-runs export and transform for a specific namespace list, then applies
# only the changed manifests. Useful for keeping Flex in sync with OSPC
# during a pre-cutover rehearsal period.
#
# Usage:
#   delta_sync.sh --namespaces ns1,ns2
#                 --src-context CTX  --src-kubeconfig FILE
#                 --tgt-context CTX  --tgt-kubeconfig FILE
#                 [--plan FILE] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACES=""
SRC_CTX=""
SRC_KC=""
TGT_CTX=""
TGT_KC=""
PLAN_FILE=""
DRY_RUN=""
LOG_DIR="${REPO_ROOT}/output/logs"
TIMESTAMP="$(date +%Y%m%dT%H%M%S)"
OUTPUT_BASE="${REPO_ROOT}/output/delta_${TIMESTAMP}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespaces)      NAMESPACES="$2";  shift 2 ;;
    --src-context)     SRC_CTX="$2";    shift 2 ;;
    --src-kubeconfig)  SRC_KC="$2";     shift 2 ;;
    --tgt-context)     TGT_CTX="$2";    shift 2 ;;
    --tgt-kubeconfig)  TGT_KC="$2";     shift 2 ;;
    --plan)            PLAN_FILE="$2";  shift 2 ;;
    --dry-run)         DRY_RUN="--dry-run"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "${NAMESPACES}" ]] && { echo "Error: --namespaces is required" >&2; exit 1; }

EXPORT_DIR="${OUTPUT_BASE}/export"
TRANSFORM_DIR="${OUTPUT_BASE}/transformed"
mkdir -p "${EXPORT_DIR}" "${TRANSFORM_DIR}" "${LOG_DIR}"

echo "=== Delta Sync: ${TIMESTAMP} ==="
echo "Namespaces: ${NAMESPACES}"

# ── Export ────────────────────────────────────────────────────────────────────
EXP_ARGS=(export --output-dir "${EXPORT_DIR}" --log-dir "${LOG_DIR}")
[[ -n "${SRC_CTX}" ]] && EXP_ARGS+=(--context "${SRC_CTX}")
[[ -n "${SRC_KC}" ]]  && EXP_ARGS+=(--kubeconfig "${SRC_KC}")
[[ -n "${PLAN_FILE}" ]] && EXP_ARGS+=(--plan "${PLAN_FILE}")
[[ -n "${DRY_RUN}" ]] && EXP_ARGS+=(--dry-run)

echo "--- Exporting ---"
python -m ospc_to_flex_k8.cli "${EXP_ARGS[@]}"

# ── Transform ─────────────────────────────────────────────────────────────────
XFM_ARGS=(transform
  --source-dir "${EXPORT_DIR}"
  --output-dir "${TRANSFORM_DIR}"
  --log-dir    "${LOG_DIR}"
)
[[ -n "${PLAN_FILE}" ]] && XFM_ARGS+=(--plan "${PLAN_FILE}")
[[ -n "${DRY_RUN}" ]] && XFM_ARGS+=(--dry-run)

echo "--- Transforming ---"
python -m ospc_to_flex_k8.cli "${XFM_ARGS[@]}"

# ── Apply (delta) ─────────────────────────────────────────────────────────────
RST_ARGS=(restore --transformed-dir "${TRANSFORM_DIR}" --log-dir "${LOG_DIR}")
[[ -n "${TGT_CTX}" ]] && RST_ARGS+=(--context "${TGT_CTX}")
[[ -n "${TGT_KC}" ]]  && RST_ARGS+=(--kubeconfig "${TGT_KC}")
[[ -n "${DRY_RUN}" ]] && RST_ARGS+=(--dry-run)
# Skip heavy phases in delta mode
RST_ARGS+=(--skip-phases crds storage helm data validation)

echo "--- Applying delta ---"
python -m ospc_to_flex_k8.cli "${RST_ARGS[@]}"

echo "=== Delta Sync Complete ==="
