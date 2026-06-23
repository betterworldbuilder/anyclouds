#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/blue-green-cutover-app}"

echo "Installing Blue/Green Cutover Tester on source jumphost..."

sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin curl unzip jq

sudo systemctl enable --now docker

if sudo ufw status 2>/dev/null | grep -q active; then
  sudo ufw allow 8000/tcp
  sudo ufw allow 8080/tcp
fi

sudo mkdir -p "$APP_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$SCRIPT_DIR" != "$APP_DIR" ]; then
  sudo cp -r backend frontend docker-compose.yml *.sh cutover_client.py README.md "$APP_DIR"/
else
  echo "Application bundle already staged in $APP_DIR."
fi
sudo chown -R "$USER":"$USER" "$APP_DIR"
chmod +x "$APP_DIR"/*.sh

cd "$APP_DIR"
docker compose pull || true
docker compose up -d --build

HOST_IP="$(hostname -I | awk '{print $1}')"
echo "Blue/Green Cutover Tester installed."
echo "Frontend: http://${HOST_IP}:8080"
echo "Backend:  http://${HOST_IP}:8000/docs"
echo "Security note: keep ports 8000 and 8080 private/admin-restricted."
