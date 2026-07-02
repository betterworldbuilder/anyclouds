#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

ROLE="${1:?role required}"
SERVICE_FILE="${2:?service python file required}"
PORT="${3:?port required}"

APP_USER="${BANKING_APP_USER:-bankpoc}"
APP_HOME="${BANKING_APP_HOME:-/opt/banking-poc}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo/root."
  exit 1
fi

apt-get update
apt-get install -y python3 python3-venv curl

if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --home "$APP_HOME" --shell /usr/sbin/nologin "$APP_USER"
fi

mkdir -p "$APP_HOME/services" "$APP_HOME/data" "$APP_HOME/logs" /etc/banking-poc
cp "$SRC_DIR/common.py" "$APP_HOME/common.py"
cp "$SRC_DIR/services/$SERVICE_FILE" "$APP_HOME/services/$SERVICE_FILE"
chown -R "$APP_USER:$APP_USER" "$APP_HOME"

cat >/etc/banking-poc/"$ROLE".env <<EOF
BANK_DATABASE_URL=${BANK_DATABASE_URL:-http://127.0.0.1:8106}
BANK_AUTH_URL=${BANK_AUTH_URL:-http://127.0.0.1:8101}
BANK_CORE_URL=${BANK_CORE_URL:-http://127.0.0.1:8102}
BANK_LEDGER_URL=${BANK_LEDGER_URL:-http://127.0.0.1:8103}
BANK_AUDIT_URL=${BANK_AUDIT_URL:-http://127.0.0.1:8104}
BANK_NOTIFICATION_URL=${BANK_NOTIFICATION_URL:-http://127.0.0.1:8105}
BANK_CACHE_URL=${BANK_CACHE_URL:-http://127.0.0.1:8107}
BANK_AUTH_SECRET=${BANK_AUTH_SECRET:-change-me-for-poc}
BANK_DB_PATH=${BANK_DB_PATH:-$APP_HOME/data/banking.db}
BANK_DB_ENGINE=${BANK_DB_ENGINE:-sqlite}
BANK_MYSQL_HOST=${BANK_MYSQL_HOST:-127.0.0.1}
BANK_MYSQL_PORT=${BANK_MYSQL_PORT:-3306}
BANK_MYSQL_DATABASE=${BANK_MYSQL_DATABASE:-bankvault_poc}
BANK_MYSQL_USER=${BANK_MYSQL_USER:-bankpoc}
BANK_MYSQL_PASSWORD=${BANK_MYSQL_PASSWORD:-bankpoc_poc_password}
BANK_POSTGRES_HOST=${BANK_POSTGRES_HOST:-127.0.0.1}
BANK_POSTGRES_PORT=${BANK_POSTGRES_PORT:-5432}
BANK_POSTGRES_DATABASE=${BANK_POSTGRES_DATABASE:-bankvault_poc}
BANK_POSTGRES_USER=${BANK_POSTGRES_USER:-bankpoc}
BANK_POSTGRES_PASSWORD=${BANK_POSTGRES_PASSWORD:-bankpoc_poc_password}
BANK_CACHE_BACKEND=${BANK_CACHE_BACKEND:-memory}
BANK_REDIS_HOST=${BANK_REDIS_HOST:-127.0.0.1}
BANK_REDIS_PORT=${BANK_REDIS_PORT:-6379}
EOF

case "$ROLE" in
  api-gateway) echo "BANK_API_PORT=$PORT" >>/etc/banking-poc/"$ROLE".env ;;
  auth) echo "BANK_AUTH_PORT=$PORT" >>/etc/banking-poc/"$ROLE".env ;;
  core-banking) echo "BANK_CORE_PORT=$PORT" >>/etc/banking-poc/"$ROLE".env ;;
  ledger) echo "BANK_LEDGER_PORT=$PORT" >>/etc/banking-poc/"$ROLE".env ;;
  audit) echo "BANK_AUDIT_PORT=$PORT" >>/etc/banking-poc/"$ROLE".env ;;
  notification) echo "BANK_NOTIFICATION_PORT=$PORT" >>/etc/banking-poc/"$ROLE".env ;;
  database) echo "BANK_DATABASE_PORT=$PORT" >>/etc/banking-poc/"$ROLE".env ;;
  cache) echo "BANK_CACHE_PORT=$PORT" >>/etc/banking-poc/"$ROLE".env ;;
esac

cat >/etc/systemd/system/banking-"$ROLE".service <<EOF
[Unit]
Description=BankVault POC $ROLE service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_HOME
EnvironmentFile=/etc/banking-poc/$ROLE.env
ExecStart=/usr/bin/python3 $APP_HOME/services/$SERVICE_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now banking-"$ROLE"
sleep 1
systemctl --no-pager --full status banking-"$ROLE" || true
echo "Installed banking-$ROLE on port $PORT"
echo "Health: curl http://127.0.0.1:$PORT/health"
