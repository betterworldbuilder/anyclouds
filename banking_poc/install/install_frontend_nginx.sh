#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

API_GATEWAY_URL="${BANK_API_GATEWAY_URL:-http://127.0.0.1:8100}"
SITE_ROOT="${BANKING_SITE_ROOT:-/var/www/bankvault}"
LISTEN_PORT="${BANKING_FRONTEND_PORT:-8080}"
DEMO_USERNAME="${BANKING_DEMO_USERNAME:-alex}"
DEMO_PASSWORD="${BANKING_DEMO_PASSWORD:-demo}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLED_FRONTEND_HTML="$SRC_DIR/banking_app_live.html"
if [[ -n "${BANKING_FRONTEND_HTML:-}" ]]; then
  FRONTEND_HTML="$BANKING_FRONTEND_HTML"
elif [[ -f "$BUNDLED_FRONTEND_HTML" ]]; then
  FRONTEND_HTML="$BUNDLED_FRONTEND_HTML"
else
  FRONTEND_HTML="./banking_app.html"
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo/root."
  exit 1
fi
if [[ ! -f "$FRONTEND_HTML" ]]; then
  echo "Frontend HTML not found: $FRONTEND_HTML"
  echo "Set BANKING_FRONTEND_HTML=/path/to/banking_app.html"
  exit 1
fi

apt-get update
apt-get install -y nginx
mkdir -p "$SITE_ROOT"
cp "$FRONTEND_HTML" "$SITE_ROOT/index.html"
cp "$SRC_DIR/frontend/bankvault_api_adapter.js" "$SITE_ROOT/bankvault_api_adapter.js"
cat >"$SITE_ROOT/bankvault_config.js" <<EOF
window.BANKVAULT_CREDENTIALS = {
  username: "$DEMO_USERNAME",
  password: "$DEMO_PASSWORD"
};
EOF
ASSET_VERSION="20260702-piggybank-live-v2"
if ! grep -q "bankvault_config.js" "$SITE_ROOT/index.html"; then
  sed -i 's#</body>#<script src="/bankvault_config.js"></script>\n</body>#' "$SITE_ROOT/index.html"
fi
if ! grep -q "bankvault_api_adapter.js" "$SITE_ROOT/index.html"; then
  sed -i "s#</body>#<script src=\"/bankvault_api_adapter.js?v=$ASSET_VERSION\"></script>\n</body>#" "$SITE_ROOT/index.html"
elif grep -q 'src="/bankvault_api_adapter.js"' "$SITE_ROOT/index.html"; then
  sed -i "s#src=\"/bankvault_api_adapter.js[^\"]*\"#src=\"/bankvault_api_adapter.js?v=$ASSET_VERSION\"#g" "$SITE_ROOT/index.html"
fi

cat >/etc/nginx/sites-available/bankvault-poc <<EOF
server {
    listen $LISTEN_PORT;
    server_name _;
    root $SITE_ROOT;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /api/ {
        proxy_pass $API_GATEWAY_URL;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/bankvault-poc /etc/nginx/sites-enabled/bankvault-poc
nginx -t
systemctl enable --now nginx
systemctl reload nginx
echo "Installed PIGGYBANK frontend on http://127.0.0.1:$LISTEN_PORT"
echo "API gateway proxied from /api/ to $API_GATEWAY_URL"
echo "Frontend demo account: $DEMO_USERNAME"
echo "PIGGYBANK UI features: login/register card, logout, Send transfer card, registered-user dropdown, mock Pay/Analytics/Cards/Invest/Settings screens, external Dev View"
