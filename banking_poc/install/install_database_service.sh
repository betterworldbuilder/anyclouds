#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_as_root() {
  local db_engine="${BANK_DB_ENGINE:-mysql}"
  local mysql_database="${BANK_MYSQL_DATABASE:-bankvault_poc}"
  local mysql_user="${BANK_MYSQL_USER:-bankpoc}"
  local mysql_password="${BANK_MYSQL_PASSWORD:-bankpoc_poc_password}"
  local postgres_database="${BANK_POSTGRES_DATABASE:-${BANK_MYSQL_DATABASE:-bankvault_poc}}"
  local postgres_user="${BANK_POSTGRES_USER:-${BANK_MYSQL_USER:-bankpoc}}"
  local postgres_password="${BANK_POSTGRES_PASSWORD:-${BANK_MYSQL_PASSWORD:-bankpoc_poc_password}}"

  apt-get update
  case "$db_engine" in
    mysql)
      apt-get install -y mysql-server python3-pymysql
      systemctl enable --now mysql

      mysql --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`$mysql_database\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$mysql_user'@'localhost' IDENTIFIED BY '$mysql_password';
CREATE USER IF NOT EXISTS '$mysql_user'@'127.0.0.1' IDENTIFIED BY '$mysql_password';
GRANT ALL PRIVILEGES ON \`$mysql_database\`.* TO '$mysql_user'@'localhost';
GRANT ALL PRIVILEGES ON \`$mysql_database\`.* TO '$mysql_user'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
      ;;
    postgres|postgresql)
      db_engine="postgresql"
      apt-get install -y postgresql postgresql-client python3-psycopg2
      systemctl enable --now postgresql

      if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$postgres_user'" | grep -q 1; then
        runuser -u postgres -- psql -c "CREATE ROLE \"$postgres_user\" LOGIN PASSWORD '$postgres_password';"
      else
        runuser -u postgres -- psql -c "ALTER ROLE \"$postgres_user\" WITH PASSWORD '$postgres_password';"
      fi
      if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='$postgres_database'" | grep -q 1; then
        runuser -u postgres -- createdb -O "$postgres_user" "$postgres_database"
      fi
      runuser -u postgres -- psql -d "$postgres_database" -c "GRANT ALL PRIVILEGES ON DATABASE \"$postgres_database\" TO \"$postgres_user\";"
      runuser -u postgres -- psql -d "$postgres_database" -c "GRANT ALL ON SCHEMA public TO \"$postgres_user\";"
      ;;
    *)
      echo "Unsupported BANK_DB_ENGINE: $db_engine"
      echo "Use mysql or postgresql."
      exit 1
      ;;
  esac

  BANK_DB_ENGINE="$db_engine" \
  BANK_MYSQL_HOST="${BANK_MYSQL_HOST:-127.0.0.1}" \
  BANK_MYSQL_PORT="${BANK_MYSQL_PORT:-3306}" \
  BANK_MYSQL_DATABASE="$mysql_database" \
  BANK_MYSQL_USER="$mysql_user" \
  BANK_MYSQL_PASSWORD="$mysql_password" \
  BANK_POSTGRES_HOST="${BANK_POSTGRES_HOST:-127.0.0.1}" \
  BANK_POSTGRES_PORT="${BANK_POSTGRES_PORT:-5432}" \
  BANK_POSTGRES_DATABASE="$postgres_database" \
  BANK_POSTGRES_USER="$postgres_user" \
  BANK_POSTGRES_PASSWORD="$postgres_password" \
    "$DIR/install_common.sh" database database_service.py "${BANK_DATABASE_PORT:-8106}"
}

if [[ "$(id -u)" -eq 0 ]]; then
  run_as_root
else
  sudo env \
    BANK_DATABASE_PORT="${BANK_DATABASE_PORT:-8106}" \
    BANK_DB_ENGINE="${BANK_DB_ENGINE:-mysql}" \
    BANK_MYSQL_HOST="${BANK_MYSQL_HOST:-127.0.0.1}" \
    BANK_MYSQL_PORT="${BANK_MYSQL_PORT:-3306}" \
    BANK_MYSQL_DATABASE="${BANK_MYSQL_DATABASE:-bankvault_poc}" \
    BANK_MYSQL_USER="${BANK_MYSQL_USER:-bankpoc}" \
    BANK_MYSQL_PASSWORD="${BANK_MYSQL_PASSWORD:-bankpoc_poc_password}" \
    BANK_POSTGRES_HOST="${BANK_POSTGRES_HOST:-127.0.0.1}" \
    BANK_POSTGRES_PORT="${BANK_POSTGRES_PORT:-5432}" \
    BANK_POSTGRES_DATABASE="${BANK_POSTGRES_DATABASE:-${BANK_MYSQL_DATABASE:-bankvault_poc}}" \
    BANK_POSTGRES_USER="${BANK_POSTGRES_USER:-${BANK_MYSQL_USER:-bankpoc}}" \
    BANK_POSTGRES_PASSWORD="${BANK_POSTGRES_PASSWORD:-${BANK_MYSQL_PASSWORD:-bankpoc_poc_password}}" \
    bash "$0"
fi
