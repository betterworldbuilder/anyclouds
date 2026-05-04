#!/usr/bin/env bash
# restore_db.sh — Restore MySQL/PostgreSQL database dumps to a target pod.
#
# Dumps are taken from the source pod via mysqldump / pg_dump,
# transferred locally, then restored into the target pod on Flex.
#
# Usage:
#   restore_db.sh --type mysql|postgres
#                 --source-context CTX --source-ns NS --source-pod POD
#                 --target-context CTX --target-ns  NS --target-pod POD
#                 --db-name DBNAME
#                 [--dump-file FILE]   (skip dump; restore existing file)
#                 [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DUMP_DIR="${REPO_ROOT}/output/db_dumps"

DB_TYPE="mysql"
SRC_CTX=""
SRC_NS=""
SRC_POD=""
TGT_CTX=""
TGT_NS=""
TGT_POD=""
DB_NAME=""
DUMP_FILE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)            DB_TYPE="$2";    shift 2 ;;
    --source-context)  SRC_CTX="$2";   shift 2 ;;
    --source-ns)       SRC_NS="$2";    shift 2 ;;
    --source-pod)      SRC_POD="$2";   shift 2 ;;
    --target-context)  TGT_CTX="$2";   shift 2 ;;
    --target-ns)       TGT_NS="$2";    shift 2 ;;
    --target-pod)      TGT_POD="$2";   shift 2 ;;
    --db-name)         DB_NAME="$2";   shift 2 ;;
    --dump-file)       DUMP_FILE="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=true;   shift   ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

for req in DB_NAME TGT_CTX TGT_NS TGT_POD; do
  [[ -z "${!req}" ]] && { echo "Error: --${req//_/-} is required" >&2; exit 1; }
done

mkdir -p "${DUMP_DIR}"
TIMESTAMP="$(date +%Y%m%dT%H%M%S)"

run() {
  if $DRY_RUN; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

# ── Step 1: Dump from source (if no --dump-file given) ────────────────────────
if [[ -z "${DUMP_FILE}" ]]; then
  [[ -z "${SRC_CTX}" || -z "${SRC_NS}" || -z "${SRC_POD}" ]] && {
    echo "Error: --source-context/ns/pod required when not using --dump-file" >&2; exit 1
  }
  SRC_FLAGS="--context=${SRC_CTX}"
  DUMP_FILE="${DUMP_DIR}/${DB_NAME}_${TIMESTAMP}.sql"

  echo "=== Dumping ${DB_TYPE} database '${DB_NAME}' from ${SRC_POD} ==="
  case "${DB_TYPE}" in
    mysql)
      run kubectl ${SRC_FLAGS} exec -n "${SRC_NS}" "${SRC_POD}" -- \
        sh -c "mysqldump --single-transaction --routines --triggers ${DB_NAME}" \
        > "${DUMP_FILE}"
      ;;
    postgres|postgresql)
      run kubectl ${SRC_FLAGS} exec -n "${SRC_NS}" "${SRC_POD}" -- \
        pg_dump -U postgres "${DB_NAME}" \
        > "${DUMP_FILE}"
      ;;
    *) echo "Unsupported DB type: ${DB_TYPE}" >&2; exit 1 ;;
  esac
  echo "Dump saved: ${DUMP_FILE}"
fi

# ── Step 2: Copy dump into target pod ────────────────────────────────────────
TGT_FLAGS="--context=${TGT_CTX}"
REMOTE_DUMP="/tmp/${DB_NAME}_restore.sql"

echo "=== Copying dump to target pod ${TGT_POD} ==="
run kubectl ${TGT_FLAGS} cp "${DUMP_FILE}" "${TGT_NS}/${TGT_POD}:${REMOTE_DUMP}"

# ── Step 3: Restore in target pod ────────────────────────────────────────────
echo "=== Restoring ${DB_TYPE} database '${DB_NAME}' in ${TGT_POD} ==="
case "${DB_TYPE}" in
  mysql)
    run kubectl ${TGT_FLAGS} exec -n "${TGT_NS}" "${TGT_POD}" -- \
      sh -c "mysql ${DB_NAME} < ${REMOTE_DUMP}"
    ;;
  postgres|postgresql)
    run kubectl ${TGT_FLAGS} exec -n "${TGT_NS}" "${TGT_POD}" -- \
      sh -c "psql -U postgres ${DB_NAME} < ${REMOTE_DUMP}"
    ;;
esac

echo "=== DB restore complete ==="
