#!/usr/bin/env bash
# local.sh — localhost-only launcher for the OSPC to FLEX Migration Dashboard.
# Lean sibling of letsmove.sh: no public-IP lookup, no apt/kubectl bootstrap,
# no systemd (this WSL distro runs /init, so systemctl never works here).
# Usage: ./local.sh [--no-browser]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
export PATH="$HOME/.local/bin:$PATH"

OPEN_BROWSER=1
[[ "$1" == "--no-browser" ]] && OPEN_BROWSER=0

# Localhost only: Flask binds loopback, nothing is exposed to the LAN.
# nginx (passwordless sudo via /etc/sudoers.d/nginx-nopasswd) terminates TLS
# on :5002 and proxies to Flask on :5001 — the dashboard URL is https://...:5002.
export WORKFLOW_DASHBOARD_HOST="127.0.0.1"
export WORKFLOW_DASHBOARD_PORT="${WORKFLOW_DASHBOARD_PORT:-5001}"

FLASK_URL="http://127.0.0.1:${WORKFLOW_DASHBOARD_PORT}"
NGINX_URL="https://127.0.0.1:5002"
FLEX_MOCKUP_URL="http://127.0.0.1:5005/Flex-Skyline-New-Ui.html?v=$(date +%s)"

echo "================================================"
echo " OSPC to FLEX Migration Dashboard (localhost)"
echo "================================================"

echo "-> Cleaning up previous instances..."
pkill -f "workflow_dashboard/app.py" 2>/dev/null || true
pkill -f "python3 app.py" 2>/dev/null || true
pkill -f "http.server 5005" 2>/dev/null || true
fuser -k "${WORKFLOW_DASHBOARD_PORT}/tcp" 2>/dev/null || true
fuser -k 5005/tcp 2>/dev/null || true
sleep 1

# nginx serves https://127.0.0.1:5002. No systemd here, so run the daemon
# directly (passwordless sudo is configured for /usr/sbin/nginx).
DASHBOARD_URL="$FLASK_URL"
if command -v nginx >/dev/null 2>&1; then
    echo "-> Starting nginx for $NGINX_URL ..."
    if pgrep -x nginx >/dev/null 2>&1; then
        sudo -n nginx -s reload >/dev/null 2>&1 || true
    else
        sudo -n nginx >/dev/null 2>&1 || true
    fi
    if pgrep -x nginx >/dev/null 2>&1; then
        DASHBOARD_URL="$NGINX_URL"
    else
        echo "   WARN: nginx failed to start — falling back to $FLASK_URL"
    fi
fi

cd "$SCRIPT_DIR/workflow_dashboard" || exit 1

echo "-> Verifying app.py syntax..."
if ! python3 -B -m py_compile app.py; then
    echo "ERROR: app.py has a syntax error. Dashboard cannot start."
    exit 1
fi

echo "-> Starting Flask application on $FLASK_URL ..."
python3 app.py &> "$SCRIPT_DIR/dashboard.log" &
APP_PID=$!

MOCKUP_HTML="$SCRIPT_DIR/Flex-Skyline-New-Ui.html"
MOCKUP_PID=""
if [[ -f "$MOCKUP_HTML" ]]; then
    echo "-> Starting FLEX mockup on $FLEX_MOCKUP_URL ..."
    (cd "$SCRIPT_DIR" && python3 -m http.server 5005 --bind 127.0.0.1) \
        &> "$SCRIPT_DIR/flex_mockup_5005.log" &
    MOCKUP_PID=$!
fi

echo "-> Waiting for server to initialize (up to 30s)..."
SERVER_UP=0
for i in $(seq 1 30); do
    sleep 1
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "ERROR: Flask app exited unexpectedly. Last log lines:"
        tail -20 "$SCRIPT_DIR/dashboard.log"
        exit 1
    fi
    if [[ "$DASHBOARD_URL" == "$NGINX_URL" ]] \
            && curl -sk --max-time 2 "$NGINX_URL/" >/dev/null 2>&1; then
        SERVER_UP=1; break
    fi
    if curl -s --max-time 2 "$FLASK_URL/" >/dev/null 2>&1; then
        SERVER_UP=1
        DASHBOARD_URL="$FLASK_URL"
        break
    fi
    echo "   ... waiting ($i/30)"
done
if [[ "$SERVER_UP" -ne 1 ]]; then
    echo "ERROR: Dashboard did not respond on $DASHBOARD_URL within 30s."
    tail -30 "$SCRIPT_DIR/dashboard.log"
    kill "$APP_PID" 2>/dev/null || true
    exit 1
fi
echo "-> Server is up at $DASHBOARD_URL"

OSPC_URL="$DASHBOARD_URL/ospc_cloud_mockup/"
OSPC_MIGRATION_URL="$DASHBOARD_URL/ospc_cloud_mockup/?migration=1"

OPEN_URLS=("$DASHBOARD_URL" "$OSPC_URL" "$OSPC_MIGRATION_URL")
[[ -n "$MOCKUP_PID" ]] && OPEN_URLS+=("$FLEX_MOCKUP_URL")

open_browser_url() {
    local url="$1"
    # powershell Start-Process uses the Windows default browser (WSL-safe cwd)
    if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "Start-Process '$url'" >/dev/null 2>&1
    elif command -v cmd.exe >/dev/null 2>&1; then
        (cd /mnt/c 2>/dev/null || cd /tmp; cmd.exe /C start "" "$url" >/dev/null 2>&1)
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 &
    else
        return 1
    fi
}

if [[ "$OPEN_BROWSER" -eq 1 ]]; then
    echo "-> Opening all pages in the default browser..."
    for url in "${OPEN_URLS[@]}"; do
        echo "   opening $url"
        open_browser_url "$url" || echo "   Open manually: $url"
        # brief pause so a cold browser start doesn't swallow the next tab
        sleep 1
    done
fi

echo "================================================"
echo " Dashboard is running. Press [Ctrl+C] to stop."
echo " Logs:          $SCRIPT_DIR/dashboard.log"
echo " Dashboard:     $DASHBOARD_URL"
echo " OSPC mockup:   $OSPC_URL"
echo " OSPC + migration: $OSPC_MIGRATION_URL"
[[ -n "$MOCKUP_PID" ]] && echo " FLEX mockup:   $FLEX_MOCKUP_URL"
echo "================================================"

trap 'echo "Shutting down dashboard..."; kill $APP_PID 2>/dev/null; [[ -n "$MOCKUP_PID" ]] && kill $MOCKUP_PID 2>/dev/null; exit 0' SIGINT SIGTERM
wait $APP_PID
