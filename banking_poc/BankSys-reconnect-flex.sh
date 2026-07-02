#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_STATE="${SCRIPT_DIR}/.banksys-install.env"
FLEX_STATE="${BANKSYS_FLEX_STATE_FILE:-${SCRIPT_DIR}/.banksys-flex.env}"

if [[ -f "$SOURCE_STATE" ]]; then
  # shellcheck disable=SC1090
  source "$SOURCE_STATE"
fi
if [[ -f "$FLEX_STATE" ]]; then
  # shellcheck disable=SC1090
  source "$FLEX_STATE"
fi

prompt() {
  local label="$1" default="$2" value
  read -r -p "$label [$default]: " value
  echo "${value:-$default}"
}

prompt_ip() {
  local label="$1" fallback="$2"
  local default="${RUN_LAST_IP:-$fallback}" value
  value="$(prompt "$label" "$default")"
  RUN_LAST_IP="$value"
  echo "$value"
}

SSH_USER="$(prompt "SSH user for cloned FLEX component servers" "${FLEX_SSH_USER:-${LAST_SSH_USER:-ubuntu}}")"
SSH_PORT="$(prompt "SSH port" "${FLEX_SSH_PORT:-${LAST_SSH_PORT:-22}}")"
SSH_KEY="$(prompt "SSH private key path, blank for default agent/key" "${FLEX_SSH_KEY:-${LAST_SSH_KEY:-$HOME/.ssh/id_rsa}}")"
AUTH_SECRET="$(prompt "Shared auth secret" "${FLEX_AUTH_SECRET:-${LAST_AUTH_SECRET:-change-me-for-poc}}")"

echo
echo "Enter the new FLEX IP for each cloned component."
RUN_LAST_IP=""
DATABASE_IP="$(prompt_ip "FLEX Database component IP" "${FLEX_DATABASE_IP:-${LAST_DATABASE_IP:-127.0.0.1}}")"
CACHE_IP="$(prompt_ip "FLEX Cache component IP" "${FLEX_CACHE_IP:-${LAST_CACHE_IP:-$DATABASE_IP}}")"
AUTH_IP="$(prompt_ip "FLEX Auth component IP" "${FLEX_AUTH_IP:-${LAST_AUTH_IP:-$CACHE_IP}}")"
AUDIT_IP="$(prompt_ip "FLEX Audit component IP" "${FLEX_AUDIT_IP:-${LAST_AUDIT_IP:-$AUTH_IP}}")"
NOTIFICATION_IP="$(prompt_ip "FLEX Notification component IP" "${FLEX_NOTIFICATION_IP:-${LAST_NOTIFICATION_IP:-$AUDIT_IP}}")"
CORE_IP="$(prompt_ip "FLEX Core Banking component IP" "${FLEX_CORE_IP:-${LAST_CORE_IP:-$NOTIFICATION_IP}}")"
LEDGER_IP="$(prompt_ip "FLEX Ledger component IP" "${FLEX_LEDGER_IP:-${LAST_LEDGER_IP:-$CORE_IP}}")"
API_IP="$(prompt_ip "FLEX API Gateway component IP" "${FLEX_API_IP:-${LAST_API_IP:-$LEDGER_IP}}")"
FRONTEND_IP="$(prompt_ip "FLEX Frontend web/mobile app IP" "${FLEX_FRONTEND_IP:-${LAST_FRONTEND_IP:-$API_IP}}")"

DATABASE_URL="http://${DATABASE_IP}:8106"
CACHE_URL="http://${CACHE_IP}:8107"
AUTH_URL="http://${AUTH_IP}:8101"
AUDIT_URL="http://${AUDIT_IP}:8104"
NOTIFICATION_URL="http://${NOTIFICATION_IP}:8105"
CORE_URL="http://${CORE_IP}:8102"
LEDGER_URL="http://${LEDGER_IP}:8103"
API_URL="http://${API_IP}:8100"

SSH_ARGS=(-tt -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
if [[ -n "$SSH_KEY" ]]; then
  SSH_ARGS+=(-i "$SSH_KEY")
fi

ssh_target() {
  echo "$SSH_USER@$1"
}

ssh_cmd() {
  local host="$1"
  shift
  ssh "${SSH_ARGS[@]}" "$(ssh_target "$host")" "$*"
}

remote_upsert_env() {
  local host="$1" role="$2"
  shift 2
  local env_file="/etc/banking-poc/${role}.env"
  local cmd="set -e; sudo test -f ${env_file};"
  local pair key val
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    cmd+=" if sudo grep -q '^${key}=' ${env_file}; then sudo sed -i 's|^${key}=.*|${key}=${val}|' ${env_file}; else echo '${key}=${val}' | sudo tee -a ${env_file} >/dev/null; fi;"
  done
  cmd+=" sudo systemctl restart banking-${role}; sudo systemctl --no-pager --full status banking-${role} | sed -n '1,8p'"
  echo
  echo "Updating ${role} on ${host}"
  ssh_cmd "$host" "$cmd"
}

update_frontend() {
  local host="$1"
  echo
  echo "Updating frontend nginx proxy on ${host}"
  ssh_cmd "$host" "
    set -e
    sudo sed -i 's|proxy_pass .*;|proxy_pass ${API_URL};|' /etc/nginx/sites-available/bankvault-poc
    if [ -d /var/www/bankvault ]; then
      sudo tee /var/www/bankvault/bankvault_config.js >/dev/null <<'EOF'
window.BANKVAULT_CREDENTIALS = {
  username: \"alex\",
  password: \"demo\"
};
EOF
    fi
    sudo nginx -t
    sudo systemctl reload nginx
  "
}

wait_for_url() {
  local label="$1" url="$2" tries="${3:-25}"
  echo "Checking ${label}: ${url}"
  for _ in $(seq 1 "$tries"); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "OK: ${label}"
      return 0
    fi
    sleep 2
  done
  echo "WARN: ${label} did not pass health check"
  return 1
}

echo
echo "Reconnect plan:"
echo "  Database:      ${DATABASE_URL}"
echo "  Cache:         ${CACHE_URL}"
echo "  Auth:          ${AUTH_URL}"
echo "  Audit:         ${AUDIT_URL}"
echo "  Notification:  ${NOTIFICATION_URL}"
echo "  Core Banking:  ${CORE_URL}"
echo "  Ledger:        ${LEDGER_URL}"
echo "  API Gateway:   ${API_URL}"
echo "  Frontend:      http://${FRONTEND_IP}:8080/"
echo
read -r -p "Apply FLEX reconnect changes? [Y/n]: " CONFIRM
case "${CONFIRM:-Y}" in
  y|Y|yes|YES) ;;
  *) echo "Cancelled."; exit 0 ;;
esac

remote_upsert_env "$DATABASE_IP" database "BANK_AUTH_SECRET=${AUTH_SECRET}"
remote_upsert_env "$CACHE_IP" cache "BANK_AUTH_SECRET=${AUTH_SECRET}"
remote_upsert_env "$AUTH_IP" auth "BANK_DATABASE_URL=${DATABASE_URL}" "BANK_AUTH_SECRET=${AUTH_SECRET}"
remote_upsert_env "$AUDIT_IP" audit "BANK_DATABASE_URL=${DATABASE_URL}" "BANK_AUTH_SECRET=${AUTH_SECRET}"
remote_upsert_env "$NOTIFICATION_IP" notification "BANK_DATABASE_URL=${DATABASE_URL}" "BANK_AUTH_SECRET=${AUTH_SECRET}"
remote_upsert_env "$CORE_IP" core-banking "BANK_DATABASE_URL=${DATABASE_URL}" "BANK_AUTH_SECRET=${AUTH_SECRET}"
remote_upsert_env "$LEDGER_IP" ledger "BANK_DATABASE_URL=${DATABASE_URL}" "BANK_AUDIT_URL=${AUDIT_URL}" "BANK_NOTIFICATION_URL=${NOTIFICATION_URL}" "BANK_AUTH_SECRET=${AUTH_SECRET}"
remote_upsert_env "$API_IP" api-gateway "BANK_AUTH_URL=${AUTH_URL}" "BANK_CORE_URL=${CORE_URL}" "BANK_LEDGER_URL=${LEDGER_URL}" "BANK_CACHE_URL=${CACHE_URL}" "BANK_AUTH_SECRET=${AUTH_SECRET}"
update_frontend "$FRONTEND_IP"

umask 077
cat >"$FLEX_STATE" <<EOF
FLEX_SSH_USER=$(printf '%q' "$SSH_USER")
FLEX_SSH_PORT=$(printf '%q' "$SSH_PORT")
FLEX_SSH_KEY=$(printf '%q' "$SSH_KEY")
FLEX_AUTH_SECRET=$(printf '%q' "$AUTH_SECRET")
FLEX_DATABASE_IP=$(printf '%q' "$DATABASE_IP")
FLEX_CACHE_IP=$(printf '%q' "$CACHE_IP")
FLEX_AUTH_IP=$(printf '%q' "$AUTH_IP")
FLEX_AUDIT_IP=$(printf '%q' "$AUDIT_IP")
FLEX_NOTIFICATION_IP=$(printf '%q' "$NOTIFICATION_IP")
FLEX_CORE_IP=$(printf '%q' "$CORE_IP")
FLEX_LEDGER_IP=$(printf '%q' "$LEDGER_IP")
FLEX_API_IP=$(printf '%q' "$API_IP")
FLEX_FRONTEND_IP=$(printf '%q' "$FRONTEND_IP")
EOF

echo
echo "Running health checks..."
wait_for_url "database" "${DATABASE_URL}/health" || true
wait_for_url "cache" "${CACHE_URL}/health" || true
wait_for_url "auth" "${AUTH_URL}/health" || true
wait_for_url "audit" "${AUDIT_URL}/health" || true
wait_for_url "notification" "${NOTIFICATION_URL}/health" || true
wait_for_url "core banking" "${CORE_URL}/health" || true
wait_for_url "ledger" "${LEDGER_URL}/health" || true
wait_for_url "api gateway readiness" "${API_URL}/ready" || true
wait_for_url "frontend" "http://${FRONTEND_IP}:8080/" || true

echo
echo "FLEX reconnect complete."
echo "Mobile web app: http://${FRONTEND_IP}:8080/"
echo "Default users: alex/demo and alice/demo"
