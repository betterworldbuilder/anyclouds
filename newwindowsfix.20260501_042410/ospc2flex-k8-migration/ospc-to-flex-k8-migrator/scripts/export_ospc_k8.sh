#!/usr/bin/env bash
# export_ospc_k8.sh — Stage 1: SSH to OSPC master and export cluster resources.
#
# Architecture rule: ALL kubectl/helm commands run on the OSPC master via SSH.
# Results are copied back to the local output directory via scp.
# The remote temp directory is cleaned up unless --keep-remote is passed.
#
# Required (env or flags):
#   OSPC_MASTER_IP  or  --master-ip
#   SSH_USER        or  --ssh-user
#   SSH_KEY_PATH    or  --ssh-key
#
# Usage:
#   export_ospc_k8.sh --output-dir ./output [options]
#
# Options:
#   --master-ip IP      OSPC master node IP
#   --ssh-user USER     SSH username (default: $SSH_USER env)
#   --ssh-key PATH      SSH private key path (default: $SSH_KEY_PATH env)
#   --ssh-port PORT     SSH port (default: 22)
#   --output-dir DIR    Local root output directory (required)
#   --plan FILE         Path to migration-plan.yaml (optional)
#   --keep-remote       Do not delete remote temp dir after copy
#   --dry-run           Print what would happen without executing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Defaults from env ─────────────────────────────────────────────────────────
MASTER_IP="${OSPC_MASTER_IP:-}"
SSH_USER_VAL="${SSH_USER:-}"
SSH_KEY="${SSH_KEY_PATH:-}"
SSH_PORT=22
OUTPUT_DIR=""
PLAN_FILE=""
KEEP_REMOTE=false
DRY_RUN=false
LOG_DIR="${REPO_ROOT}/output/logs"

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --master-ip)   MASTER_IP="$2";     shift 2 ;;
    --ssh-user)    SSH_USER_VAL="$2";  shift 2 ;;
    --ssh-key)     SSH_KEY="$2";       shift 2 ;;
    --ssh-port)    SSH_PORT="$2";      shift 2 ;;
    --output-dir)  OUTPUT_DIR="$2";    shift 2 ;;
    --plan)        PLAN_FILE="$2";     shift 2 ;;
    --keep-remote) KEEP_REMOTE=true;   shift   ;;
    --dry-run)     DRY_RUN=true;       shift   ;;
    -h|--help)     usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Validate required inputs ──────────────────────────────────────────────────
ERRORS=()
[[ -z "${MASTER_IP}" ]]    && ERRORS+=("OSPC_MASTER_IP not set (use --master-ip or env var)")
[[ -z "${SSH_USER_VAL}" ]] && ERRORS+=("SSH_USER not set (use --ssh-user or env var)")
[[ -z "${SSH_KEY}" ]]      && ERRORS+=("SSH_KEY_PATH not set (use --ssh-key or env var)")
[[ -z "${OUTPUT_DIR}" ]]   && ERRORS+=("--output-dir is required")
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "Error(s):" >&2
  for e in "${ERRORS[@]}"; do echo "  - $e" >&2; done
  exit 1
fi

if [[ ! -f "${SSH_KEY}" ]]; then
  echo "Error: SSH key not found: ${SSH_KEY}" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}" "${LOG_DIR}"

# ── Build Python CLI args ─────────────────────────────────────────────────────
ARGS=(export
  --master-ip   "${MASTER_IP}"
  --ssh-user    "${SSH_USER_VAL}"
  --ssh-key     "${SSH_KEY}"
  --ssh-port    "${SSH_PORT}"
  --output-dir  "${OUTPUT_DIR}"
  --log-dir     "${LOG_DIR}"
)
[[ -n "${PLAN_FILE}" ]]   && ARGS+=(--plan "${PLAN_FILE}")
$KEEP_REMOTE               && ARGS+=(--keep-remote)
$DRY_RUN                   && ARGS+=(--dry-run)

# ── Pre-flight SSH check ──────────────────────────────────────────────────────
echo "=== Stage 1: Export from OSPC Master ==="
echo "  Master:     ${SSH_USER_VAL}@${MASTER_IP}:${SSH_PORT}"
echo "  SSH key:    ${SSH_KEY}"
echo "  Output dir: ${OUTPUT_DIR}"
$DRY_RUN && echo "  [DRY-RUN MODE]"
echo ""

if ! $DRY_RUN; then
  echo "Checking SSH connectivity …"
  if ! ssh \
    -i "${SSH_KEY}" \
    -p "${SSH_PORT}" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    "${SSH_USER_VAL}@${MASTER_IP}" \
    "echo ssh-preflight-ok" 2>/dev/null | grep -q ssh-preflight-ok; then
    echo "ERROR: Cannot connect to ${MASTER_IP} via SSH." >&2
    echo "Check: host reachable, port open, key authorized." >&2
    exit 1
  fi
  echo "SSH OK."
  echo ""
fi

# ── Run export via Python CLI ─────────────────────────────────────────────────
PYTHONPATH="${REPO_ROOT}/src" python3 -m ospc_to_flex_k8.cli "${ARGS[@]}"

echo ""
echo "=== Export complete ==="
echo "Output: ${OUTPUT_DIR}"
