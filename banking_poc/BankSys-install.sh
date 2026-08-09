#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$SCRIPT_DIR"
PACKAGE="/tmp/banksys-poc-$$.tgz"
STATE_FILE="${BANKSYS_STATE_FILE:-$SCRIPT_DIR/.banksys-install.env}"
SSH_USER_DEFAULT="${BANKSYS_SSH_USER:-ubuntu}"
SSH_PORT_DEFAULT="22"
AUTH_SECRET_DEFAULT="$(date +%s | sha256sum | awk '{print $1}')"
SSH_KEY_DEFAULT=""
if [[ -f "$HOME/.ssh/id_rsa" ]]; then
  SSH_KEY_DEFAULT="$HOME/.ssh/id_rsa"
fi
DB_PASSWORD_DEFAULT="$(date +%s:%N | sha256sum | awk '{print substr($1,1,24)}')"
MOCK_BANK_USERNAME="${BANKSYS_MOCK_USERNAME:-alex}"
MOCK_BANK_PASSWORD="${BANKSYS_MOCK_PASSWORD:-demo}"
MOCK_BANK_EMAIL="${BANKSYS_MOCK_EMAIL:-alex@example.com}"
MOCK_BANK_NAME="${BANKSYS_MOCK_NAME:-Alex Morgan}"

if [[ ! -d "$POC_DIR" ]]; then
  echo "banking_poc folder not found."
  exit 1
fi

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi

for cmd in tar ssh scp curl python3 sha256sum awk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd"
    exit 1
  fi
done

prompt() {
  local label="$1"
  local default="$2"
  local value
  read -r -p "$label [$default]: " value
  echo "${value:-$default}"
}

prompt_ip() {
  local label="$1"
  local fallback="$2"
  local default="${RUN_LAST_IP:-$fallback}"
  local value
  value="$(prompt "$label" "$default")"
  RUN_LAST_IP="$value"
  echo "$value"
}

save_state() {
  umask 077
  cat >"$STATE_FILE" <<EOF
LAST_SSH_USER=$(printf '%q' "$SSH_USER")
LAST_SSH_PORT=$(printf '%q' "$SSH_PORT")
LAST_SSH_KEY=$(printf '%q' "$SSH_KEY")
LAST_AUTH_SECRET=$(printf '%q' "$AUTH_SECRET")
LAST_DB_ENGINE=$(printf '%q' "$DB_ENGINE")
LAST_DB_NAME=$(printf '%q' "$DB_NAME")
LAST_DB_USER=$(printf '%q' "$DB_USER")
LAST_DB_PASSWORD=$(printf '%q' "$DB_PASSWORD")
LAST_DATABASE_IP=$(printf '%q' "$DATABASE_IP")
LAST_CACHE_IP=$(printf '%q' "$CACHE_IP")
LAST_AUTH_IP=$(printf '%q' "$AUTH_IP")
LAST_AUDIT_IP=$(printf '%q' "$AUDIT_IP")
LAST_NOTIFICATION_IP=$(printf '%q' "$NOTIFICATION_IP")
LAST_CORE_IP=$(printf '%q' "$CORE_IP")
LAST_LEDGER_IP=$(printf '%q' "$LEDGER_IP")
LAST_API_IP=$(printf '%q' "$API_IP")
LAST_FRONTEND_IP=$(printf '%q' "$FRONTEND_IP")
LAST_FRONTEND_HTML=$(printf '%q' "$FRONTEND_HTML")
EOF
  echo "Saved installer defaults to $STATE_FILE"
}

prompt_optional() {
  local label="$1"
  local value
  read -r -p "$label: " value
  echo "$value"
}

show_readme() {
  local readme="$SCRIPT_DIR/README.md"
  if [[ ! -f "$readme" ]]; then
    echo "README.md not found at $readme"
    return
  fi
  clear 2>/dev/null || true
  cat "$readme"
  echo
  read -r -p "Press Enter to continue to the interactive installer, or Ctrl+C to stop..."
  clear 2>/dev/null || true
}

is_local_host() {
  case "$1" in
    127.0.0.1|localhost|"$(hostname -I 2>/dev/null | awk '{print $1}')"|"$(hostname -f 2>/dev/null || true)") return 0 ;;
    *) return 1 ;;
  esac
}

ssh_target() {
  echo "$SSH_USER@$1"
}

ssh_cmd() {
  local host="$1"
  shift
  if is_local_host "$host"; then
    bash -lc "$*"
  else
    ssh "${SSH_ARGS[@]}" "$(ssh_target "$host")" "$*"
  fi
}

copy_package() {
  local host="$1"
  if is_local_host "$host"; then
    mkdir -p "/tmp/banksys-install"
    cp "$PACKAGE" "/tmp/banksys-install/package.tgz"
    return
  fi
  ssh "${SSH_ARGS[@]}" "$(ssh_target "$host")" "mkdir -p /tmp/banksys-install"
  scp "${SCP_ARGS[@]}" "$PACKAGE" "$(ssh_target "$host"):/tmp/banksys-install/package.tgz"
}

copy_frontend_html() {
  local host="$1"
  local source_html="$2"
  if is_local_host "$host"; then
    mkdir -p "/tmp/banksys-install"
    cp "$source_html" "/tmp/banksys-install/piggybank_frontend.html"
    return
  fi
  ssh "${SSH_ARGS[@]}" "$(ssh_target "$host")" "mkdir -p /tmp/banksys-install"
  scp "${SCP_ARGS[@]}" "$source_html" "$(ssh_target "$host"):/tmp/banksys-install/piggybank_frontend.html"
}

remote_install() {
  local host="$1"
  shift
  local install_script="$1"
  shift
  local env_line="$*"
  copy_package "$host"
  ssh_cmd "$host" "
    set -e
    rm -rf /tmp/banksys-install/work
    mkdir -p /tmp/banksys-install/work
    tar -xzf /tmp/banksys-install/package.tgz -C /tmp/banksys-install/work
    cd /tmp/banksys-install/work/banking_poc
    chmod +x install/*.sh
    if [ \"\$(id -u)\" -eq 0 ]; then
      env $env_line bash install/$install_script
    else
      sudo env $env_line bash install/$install_script
    fi
  "
}

wait_for_url() {
  local label="$1"
  local url="$2"
  local tries="${3:-40}"
  echo "Checking $label: $url"
  for _ in $(seq 1 "$tries"); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "OK: $label"
      return 0
    fi
    sleep 2
  done
  echo "FAILED: $label did not become healthy"
  return 1
}

json_value() {
  local expr="$1"
  python3 -c "import json,sys; data=json.load(sys.stdin); print($expr)"
}

create_mock_mobile_account() {
  local response_file="/tmp/banksys-mock-account-$$.json"
  local status login_status

  echo
  echo "Creating reusable mock bank mobile account..."
  status="$(curl -sS -o "$response_file" -w "%{http_code}" -X POST "$API_URL/api/customers" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$MOCK_BANK_NAME\",\"email\":\"$MOCK_BANK_EMAIL\",\"username\":\"$MOCK_BANK_USERNAME\",\"password\":\"$MOCK_BANK_PASSWORD\",\"opening_deposit_cents\":750000}" || true)"

  case "$status" in
    201)
      echo "Mock account created:"
      ;;
    409)
      echo "Mock account already exists; reusing it:"
      ;;
    *)
      echo "Failed to create mock account. HTTP status: $status"
      cat "$response_file" 2>/dev/null || true
      rm -f "$response_file"
      return 1
      ;;
  esac

  cat "$response_file" | python3 -m json.tool 2>/dev/null || cat "$response_file"
  rm -f "$response_file"

  login_status="$(curl -sS -o /tmp/banksys-mock-login-$$.json -w "%{http_code}" -X POST "$API_URL/api/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$MOCK_BANK_USERNAME\",\"password\":\"$MOCK_BANK_PASSWORD\"}" || true)"
  if [[ "$login_status" != "200" ]]; then
    echo "Mock account exists but login failed. HTTP status: $login_status"
    cat /tmp/banksys-mock-login-$$.json 2>/dev/null || true
    rm -f /tmp/banksys-mock-login-$$.json
    return 1
  fi
  rm -f /tmp/banksys-mock-login-$$.json

  echo "Mock mobile banking account ready:"
  echo "  username: $MOCK_BANK_USERNAME"
  echo "  password: $MOCK_BANK_PASSWORD"
}

run_business_test() {
  local frontend_base="http://$FRONTEND_IP:8080"
  local username="poc$(date +%s)"
  # Generated per run instead of hardcoded. Override with BANKSYS_TEST_PASSWORD.
  local password="${BANKSYS_TEST_PASSWORD:-Poc$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 14)aA1}"
  local create_body login_body summary_body transfer_body after_body

  wait_for_url "frontend" "$frontend_base/" 30
  wait_for_url "gateway through frontend proxy" "$frontend_base/api/server-metrics" 30

  echo "Creating mobile banking customer through $frontend_base/api/customers"
  create_body="$(curl -fsS -X POST "$frontend_base/api/customers" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"POC Mobile User\",\"email\":\"$username@example.com\",\"username\":\"$username\",\"password\":\"$password\",\"opening_deposit_cents\":500000}")"
  echo "$create_body" | python3 -m json.tool

  echo "Logging in as $username"
  login_body="$(curl -fsS -X POST "$frontend_base/api/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$username\",\"password\":\"$password\"}")"
  token="$(echo "$login_body" | json_value 'data["access_token"]')"

  echo "Getting bank account information"
  summary_body="$(curl -fsS "$frontend_base/api/mobile/summary" -H "Authorization: Bearer $token")"
  echo "$summary_body" | python3 -m json.tool
  from_account="$(echo "$summary_body" | json_value 'data["accounts"][0]["id"]')"
  to_account="$(echo "$summary_body" | json_value 'data["accounts"][1]["id"]')"

  echo "Posting test transfer from $from_account to $to_account"
  transfer_body="$(curl -fsS -X POST "$frontend_base/api/transfers" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $token" \
    -d "{\"from_account_id\":\"$from_account\",\"to_account_id\":\"$to_account\",\"amount_cents\":12345,\"description\":\"BankSys installer test transfer\"}")"
  echo "$transfer_body" | python3 -m json.tool

  echo "Getting updated account information"
  after_body="$(curl -fsS "$frontend_base/api/mobile/summary" -H "Authorization: Bearer $token")"
  echo "$after_body" | python3 -m json.tool

  echo
  echo "Business system test passed."
  echo "Created account username: $username"
  echo "Created account password: $password"
  echo "Mobile web app: $frontend_base/"
}

echo "================================================"
echo " BankSys Mobile Banking POC Interactive Installer"
echo "================================================"
echo
show_readme
echo "================================================"
echo " BankSys Mobile Banking POC Interactive Installer"
echo "================================================"
echo
echo "This installer uses SSH to copy banking_poc to each server, runs the component installer, starts systemd, then can run a full create/login/transfer/account-info test."
echo "Target OS assumption: Ubuntu 24.04 LTS on OSPC instances."
echo

SSH_USER="$(prompt "SSH user for component servers" "${LAST_SSH_USER:-$SSH_USER_DEFAULT}")"
SSH_PORT="$(prompt "SSH port" "${LAST_SSH_PORT:-$SSH_PORT_DEFAULT}")"
SSH_KEY="$(prompt "SSH private key path, blank for default agent/key" "${LAST_SSH_KEY:-$SSH_KEY_DEFAULT}")"
AUTH_SECRET="$(prompt "Shared auth secret for Auth and API Gateway" "${LAST_AUTH_SECRET:-$AUTH_SECRET_DEFAULT}")"
DB_ENGINE="$(prompt "Database engine on Database server: mysql or postgresql" "${LAST_DB_ENGINE:-mysql}")"
case "$DB_ENGINE" in
  mysql|postgres|postgresql) ;;
  *)
    echo "Unsupported database engine: $DB_ENGINE"
    echo "Use mysql or postgresql."
    exit 1
    ;;
esac
if [[ "$DB_ENGINE" == "postgres" ]]; then
  DB_ENGINE="postgresql"
fi
DB_NAME="$(prompt "Database name on Database server" "${LAST_DB_NAME:-bankvault_poc}")"
DB_USER="$(prompt "Database app user on Database server" "${LAST_DB_USER:-bankpoc}")"
DB_PASSWORD="$(prompt "Database app password on Database server" "${LAST_DB_PASSWORD:-$DB_PASSWORD_DEFAULT}")"
echo

RUN_LAST_IP=""
DATABASE_IP="$(prompt_ip "Database component IP" "${LAST_DATABASE_IP:-127.0.0.1}")"
CACHE_IP="$(prompt_ip "Cache component IP" "${LAST_CACHE_IP:-$DATABASE_IP}")"
AUTH_IP="$(prompt_ip "Auth component IP" "${LAST_AUTH_IP:-$CACHE_IP}")"
AUDIT_IP="$(prompt_ip "Audit component IP" "${LAST_AUDIT_IP:-$AUTH_IP}")"
NOTIFICATION_IP="$(prompt_ip "Notification component IP" "${LAST_NOTIFICATION_IP:-$AUDIT_IP}")"
CORE_IP="$(prompt_ip "Core Banking component IP" "${LAST_CORE_IP:-$NOTIFICATION_IP}")"
LEDGER_IP="$(prompt_ip "Ledger component IP" "${LAST_LEDGER_IP:-$CORE_IP}")"
API_IP="$(prompt_ip "API Gateway component IP" "${LAST_API_IP:-$LEDGER_IP}")"
FRONTEND_IP="$(prompt_ip "Frontend web/mobile app IP" "${LAST_FRONTEND_IP:-$API_IP}")"
echo

DEFAULT_FRONTEND_HTML="$SCRIPT_DIR/banking_app_live.html"
if [[ ! -f "$DEFAULT_FRONTEND_HTML" ]]; then
  DEFAULT_FRONTEND_HTML="$SCRIPT_DIR/banking_app.html"
fi
FRONTEND_HTML="$(prompt "Local path to BankSys frontend HTML" "$DEFAULT_FRONTEND_HTML")"
if [[ ! -f "$FRONTEND_HTML" ]]; then
  echo "Frontend HTML not found: $FRONTEND_HTML"
  exit 1
fi

SSH_ARGS=(-tt -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
SCP_ARGS=(-P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
if [[ -n "$SSH_KEY" ]]; then
  SSH_ARGS+=(-i "$SSH_KEY")
  SCP_ARGS+=(-i "$SSH_KEY")
fi

DATABASE_URL="http://$DATABASE_IP:8106"
CACHE_URL="http://$CACHE_IP:8107"
AUTH_URL="http://$AUTH_IP:8101"
AUDIT_URL="http://$AUDIT_IP:8104"
NOTIFICATION_URL="http://$NOTIFICATION_IP:8105"
CORE_URL="http://$CORE_IP:8102"
LEDGER_URL="http://$LEDGER_IP:8103"
API_URL="http://$API_IP:8100"

echo
echo "Install plan:"
echo "  Database:      $DATABASE_URL"
echo "  Cache:         $CACHE_URL"
echo "  Auth:          $AUTH_URL"
echo "  Audit:         $AUDIT_URL"
echo "  Notification:  $NOTIFICATION_URL"
echo "  Core Banking:  $CORE_URL"
echo "  Ledger:        $LEDGER_URL"
echo "  API Gateway:   $API_URL"
echo "  Frontend:      http://$FRONTEND_IP:8080/"
echo "  Frontend UI:   PIGGYBANK bundled mobile UI with login/register, logout, Send transfer card, user dropdown, mock screens, and Dev View"
echo "  DB Engine:     $DB_ENGINE local to Database server, exposed through Database Service on port 8106"
echo "  Cache Engine:  Redis local to Cache server, exposed through Cache Service on port 8107"
echo
read -r -p "Continue with install? [Y/n]: " CONTINUE
case "${CONTINUE:-Y}" in
  y|Y|yes|YES) ;;
  *) echo "Install cancelled."; exit 0 ;;
esac
save_state

tar -czf "$PACKAGE" -C "$(dirname "$POC_DIR")" "$(basename "$POC_DIR")"
trap 'rm -f "$PACKAGE"' EXIT

echo
echo "Installing Database..."
remote_install "$DATABASE_IP" install_database_service.sh "BANK_AUTH_SECRET=$AUTH_SECRET BANK_DB_ENGINE=$DB_ENGINE BANK_MYSQL_DATABASE=$DB_NAME BANK_MYSQL_USER=$DB_USER BANK_MYSQL_PASSWORD=$DB_PASSWORD BANK_POSTGRES_DATABASE=$DB_NAME BANK_POSTGRES_USER=$DB_USER BANK_POSTGRES_PASSWORD=$DB_PASSWORD"

echo
echo "Installing Cache..."
remote_install "$CACHE_IP" install_cache_service.sh "BANK_AUTH_SECRET=$AUTH_SECRET BANK_CACHE_BACKEND=redis"

echo
echo "Installing Auth..."
remote_install "$AUTH_IP" install_auth_service.sh "BANK_DATABASE_URL=$DATABASE_URL BANK_AUTH_SECRET=$AUTH_SECRET"

echo
echo "Installing Audit..."
remote_install "$AUDIT_IP" install_audit_service.sh "BANK_DATABASE_URL=$DATABASE_URL BANK_AUTH_SECRET=$AUTH_SECRET"

echo
echo "Installing Notification..."
remote_install "$NOTIFICATION_IP" install_notification_service.sh "BANK_DATABASE_URL=$DATABASE_URL BANK_AUTH_SECRET=$AUTH_SECRET"

echo
echo "Installing Core Banking..."
remote_install "$CORE_IP" install_core_banking_service.sh "BANK_DATABASE_URL=$DATABASE_URL BANK_AUTH_SECRET=$AUTH_SECRET"

echo
echo "Installing Ledger..."
remote_install "$LEDGER_IP" install_ledger_service.sh "BANK_DATABASE_URL=$DATABASE_URL BANK_AUDIT_URL=$AUDIT_URL BANK_NOTIFICATION_URL=$NOTIFICATION_URL BANK_AUTH_SECRET=$AUTH_SECRET"

echo
echo "Installing API Gateway..."
remote_install "$API_IP" install_api_gateway.sh "BANK_AUTH_URL=$AUTH_URL BANK_CORE_URL=$CORE_URL BANK_LEDGER_URL=$LEDGER_URL BANK_CACHE_URL=$CACHE_URL BANK_AUTH_SECRET=$AUTH_SECRET"

echo
echo "Installing Frontend..."
copy_package "$FRONTEND_IP"
copy_frontend_html "$FRONTEND_IP" "$FRONTEND_HTML"
ssh_cmd "$FRONTEND_IP" "
  set -e
  rm -rf /tmp/banksys-install/work
  mkdir -p /tmp/banksys-install/work
  tar -xzf /tmp/banksys-install/package.tgz -C /tmp/banksys-install/work
  cd /tmp/banksys-install/work/banking_poc
  chmod +x install/*.sh
  if [ \"\$(id -u)\" -eq 0 ]; then
    env BANKING_FRONTEND_HTML=/tmp/banksys-install/piggybank_frontend.html BANK_API_GATEWAY_URL=$API_URL BANKING_DEMO_USERNAME=$MOCK_BANK_USERNAME BANKING_DEMO_PASSWORD=$MOCK_BANK_PASSWORD bash install/install_frontend_nginx.sh
  else
    sudo env BANKING_FRONTEND_HTML=/tmp/banksys-install/piggybank_frontend.html BANK_API_GATEWAY_URL=$API_URL BANKING_DEMO_USERNAME=$MOCK_BANK_USERNAME BANKING_DEMO_PASSWORD=$MOCK_BANK_PASSWORD bash install/install_frontend_nginx.sh
  fi
"

echo
echo "Checking component health..."
wait_for_url "database" "$DATABASE_URL/health"
wait_for_url "cache" "$CACHE_URL/health"
wait_for_url "auth" "$AUTH_URL/health"
wait_for_url "audit" "$AUDIT_URL/health"
wait_for_url "notification" "$NOTIFICATION_URL/health"
wait_for_url "core banking" "$CORE_URL/health"
wait_for_url "ledger" "$LEDGER_URL/health"
wait_for_url "api gateway readiness" "$API_URL/ready"

create_mock_mobile_account

echo
read -r -p "Run end-to-end business test through the web/mobile app now? [Y/n]: " RUN_TEST
case "${RUN_TEST:-Y}" in
  y|Y|yes|YES) run_business_test ;;
  *) echo "Skipped business transaction test." ;;
esac

echo
echo "BankSys install complete."
echo "Mobile web app: http://$FRONTEND_IP:8080/"
echo "Mock account: $MOCK_BANK_USERNAME / $MOCK_BANK_PASSWORD"
