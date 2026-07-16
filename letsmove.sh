#!/usr/bin/env bash
# No set -e here — we want to stay alive even if sub-commands return non-zero

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── PERMANENT PERMISSION FIX ──────────────────────────────────────────────────
# Prevent Python from ever writing __pycache__ files (avoids root-owned debris)
export PYTHONDONTWRITEBYTECODE=1

# Self-healing: reclaim any root-owned files silently (happens if someone ran
# "sudo python3" directly in the past).
if find "$SCRIPT_DIR" -not -user "$(whoami)" -print -quit 2>/dev/null | grep -q .; then
    echo "-> Fixing file ownership (root-owned files detected)..."
    sudo chown -R "$(whoami)":"$(whoami)" "$SCRIPT_DIR" 2>/dev/null || true
fi
# ─────────────────────────────────────────────────────────────────────────────

# Ensure ~/.local/bin is on PATH (where pip installs CLIs like openstack)
export PATH="$HOME/.local/bin:$PATH"

# Expose the dashboard on every interface: public server addresses AND localhost.
# nginx (:5002 TLS) already listens on all interfaces; Flask itself binds per
# this env var (app.py: WORKFLOW_DASHBOARD_HOST, default 127.0.0.1).
export WORKFLOW_DASHBOARD_HOST="${WORKFLOW_DASHBOARD_HOST:-0.0.0.0}"
# First non-loopback address, for the URLs printed at the end.
PUBLIC_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | grep -v '^$' | head -1)"

echo "================================================"
echo " Starting OSPC to FLEX Migration Dashboard "
echo "================================================"

DASHBOARD_URL="https://127.0.0.1:5002"
FLEX_MOCKUP_BASE_URL="http://127.0.0.1:5005/Flex-Skyline-New-Ui.html"
FLEX_MOCKUP_URL="${FLEX_MOCKUP_BASE_URL}?v=$(date +%s)"
OSPC_MOCKUP_URL="https://127.0.0.1:5002/ospc_cloud_mockup/"
OSPC_MIGRATION_URL="https://127.0.0.1:5002/ospc_cloud_mockup/?migration=1"

echo "-> Cleaning up previous background instances..."
systemctl --user stop osflex-dashboard >/dev/null 2>&1 || true
pkill -f "$SCRIPT_DIR/workflow_dashboard/run_dashboard.sh" >/dev/null 2>&1 || true
rm -f /tmp/osflex-dashboard.pid
fuser -k 5001/tcp >/dev/null 2>&1 || true
fuser -k 5005/tcp >/dev/null 2>&1 || true
sleep 1

# ── FRESH-SERVER BOOTSTRAP ────────────────────────────────────────────────────
# A brand-new Ubuntu host has no pip3/nginx and the ubuntu user has no password,
# so plain `systemctl restart nginx` hangs on an interactive polkit prompt.
# Everything below is non-interactive; nginx is optional (dashboard falls back
# to plain HTTP on :5001 when it is unavailable).
if ! command -v pip3 >/dev/null 2>&1; then
    echo "-> Fresh host detected: installing python3-pip/python3-venv (sudo apt)..."
    sudo apt-get update -qq && sudo apt-get install -y -qq python3-pip python3-venv || {
        echo "ERROR: could not install python3-pip. Run manually: sudo apt-get install -y python3-pip"
        exit 1
    }
fi
if ! command -v nginx >/dev/null 2>&1; then
    echo "-> Fresh host: installing nginx (HTTPS proxy on :5002)..."
    sudo apt-get install -y -qq nginx || echo "WARN: nginx install failed — dashboard will be HTTP-only on :5001"
fi
if command -v nginx >/dev/null 2>&1 && [[ ! -f /etc/nginx/conf.d/osflex.conf ]] \
        && [[ -f "$SCRIPT_DIR/workflow_dashboard/osflex_nginx.conf" ]]; then
    echo "-> Fresh host: installing nginx site config + self-signed certificate..."
    sudo mkdir -p /etc/nginx/ssl
    if [[ ! -f /etc/nginx/ssl/osflex.key ]]; then
        sudo openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -keyout /etc/nginx/ssl/osflex.key -out /etc/nginx/ssl/osflex.crt \
            -subj "/CN=osflex-dashboard" >/dev/null 2>&1
    fi
    sudo cp "$SCRIPT_DIR/workflow_dashboard/osflex_nginx.conf" /etc/nginx/conf.d/osflex.conf
fi
# ─────────────────────────────────────────────────────────────────────────────

echo "-> Starting nginx (HTTP/2 on port 5002)..."
# sudo -n first: never hang on an interactive polkit/password prompt.
sudo -n systemctl restart nginx >/dev/null 2>&1 \
    || systemctl restart nginx >/dev/null 2>&1 \
    || sudo -n nginx -s reload >/dev/null 2>&1 \
    || nginx -s reload >/dev/null 2>&1 \
    || echo "WARN: nginx not restarted — dashboard reachable directly at http://127.0.0.1:5001"

echo "-> Installing dependencies..."
pip3 install --break-system-packages -q -r "$SCRIPT_DIR/requirements/requirements.txt" || {
    echo "ERROR: pip install failed — Flask cannot start without its dependencies."
    echo "       Run manually: pip3 install --break-system-packages -r $SCRIPT_DIR/requirements/requirements.txt"
    exit 1
}

# Navigate to dashboard directory
cd "$SCRIPT_DIR/workflow_dashboard" || exit 1

# Check syntax before launching (no bytecode writing)
echo "-> Verifying app.py syntax..."
if ! python3 -B -m py_compile app.py; then
    echo "ERROR: app.py has a syntax error. Dashboard cannot start."
    exit 1
fi

# Start Flask via systemd user service (keeps it alive across sessions, no port conflicts)
echo "-> Starting Flask application (via systemd user service)..."
if systemctl --user is-enabled osflex-dashboard >/dev/null 2>&1; then
    # Make the public bind reach the systemd-managed Flask too.
    systemctl --user set-environment "WORKFLOW_DASHBOARD_HOST=$WORKFLOW_DASHBOARD_HOST" 2>/dev/null || true
    systemctl --user restart osflex-dashboard
    APP_PID=$(systemctl --user show osflex-dashboard --value --property MainPID 2>/dev/null || echo "")
else
    # Fallback: direct launch if service not installed
    python3 app.py &>> "$SCRIPT_DIR/dashboard.log" &
    APP_PID=$!
fi

# Serve the FLEX cloud mockup HTML on its own lightweight local port.
MOCKUP_HTML="$SCRIPT_DIR/Flex-Skyline-New-Ui.html"
MOCKUP_LOG="$SCRIPT_DIR/flex_mockup_5005.log"
MOCKUP_PID=""
if [[ -f "$MOCKUP_HTML" ]]; then
    echo "-> Starting FLEX web UI mockup on $FLEX_MOCKUP_URL..."
    (cd "$SCRIPT_DIR" && python3 -m http.server 5005 --bind 0.0.0.0) &> "$MOCKUP_LOG" &
    MOCKUP_PID=$!
else
    echo "WARN: FLEX web UI mockup file not found: $MOCKUP_HTML"
fi

echo "-> Waiting for server to initialize (up to 30s)..."
for i in $(seq 1 30); do
    sleep 1
    # Check via systemd if managed, else check PID directly
    if systemctl --user is-enabled osflex-dashboard >/dev/null 2>&1; then
        if ! systemctl --user is-active --quiet osflex-dashboard; then
            echo "ERROR: Flask service failed. Check: journalctl --user -u osflex-dashboard -n 30"
            exit 1
        fi
    elif ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "ERROR: Flask app exited unexpectedly. Check $SCRIPT_DIR/dashboard.log for details."
        cat "$SCRIPT_DIR/dashboard.log" | tail -20
        exit 1
    fi
    if curl -sk --max-time 1 "$DASHBOARD_URL/" > /dev/null 2>&1; then
        echo "-> Server is up!"
        break
    fi
    # nginx-less fresh hosts: Flask itself answers on plain HTTP :5001
    if curl -s --max-time 1 "http://127.0.0.1:5001/" > /dev/null 2>&1; then
        echo "-> Server is up (direct HTTP on :5001 — nginx proxy not active)."
        DASHBOARD_URL="http://127.0.0.1:5001"
        break
    fi
    echo "   ... waiting ($i/30)"
done

if [[ -n "$MOCKUP_PID" ]]; then
    echo "-> Waiting for FLEX web UI mockup on port 5005..."
    for i in $(seq 1 10); do
        sleep 1
        if ! kill -0 "$MOCKUP_PID" 2>/dev/null; then
            echo "WARN: FLEX mockup server exited unexpectedly. Check $MOCKUP_LOG for details."
            tail -20 "$MOCKUP_LOG" 2>/dev/null || true
            break
        fi
        if curl -s --max-time 1 "$FLEX_MOCKUP_BASE_URL" > /dev/null 2>&1; then
            echo "-> FLEX web UI mockup is up!"
            break
        fi
        echo "   ... waiting for mockup ($i/10)"
    done
fi

echo "-> Verifying OSPC web UI mockup on $OSPC_MOCKUP_URL..."
if curl -sk --max-time 3 "$OSPC_MOCKUP_URL" > /dev/null 2>&1; then
    echo "-> OSPC web UI mockup is up!"
else
    echo "WARN: OSPC web UI mockup did not respond yet. It is served by the dashboard route."
fi

echo "-> Opening Google Chrome to dashboard and mockup web UIs..."
if command -v cmd.exe > /dev/null 2>&1; then
    (cd /mnt/c/Windows/System32 2>/dev/null || cd /tmp; cmd.exe /C start "" chrome "$DASHBOARD_URL")
    [[ -n "$MOCKUP_PID" ]] && (cd /mnt/c/Windows/System32 2>/dev/null || cd /tmp; cmd.exe /C start "" chrome "$FLEX_MOCKUP_URL")
    (cd /mnt/c/Windows/System32 2>/dev/null || cd /tmp; cmd.exe /C start "" chrome "$OSPC_MIGRATION_URL")
elif command -v explorer.exe > /dev/null 2>&1; then
    (cd /mnt/c/Windows/System32 2>/dev/null || cd /tmp; explorer.exe "$DASHBOARD_URL")
    [[ -n "$MOCKUP_PID" ]] && (cd /mnt/c/Windows/System32 2>/dev/null || cd /tmp; explorer.exe "$FLEX_MOCKUP_URL")
    (cd /mnt/c/Windows/System32 2>/dev/null || cd /tmp; explorer.exe "$OSPC_MIGRATION_URL")
elif command -v xdg-open > /dev/null 2>&1; then
    xdg-open "$DASHBOARD_URL"
    [[ -n "$MOCKUP_PID" ]] && xdg-open "$FLEX_MOCKUP_URL"
    xdg-open "$OSPC_MIGRATION_URL"
else
    echo "Please manually open $DASHBOARD_URL in Google Chrome."
    [[ -n "$MOCKUP_PID" ]] && echo "Please manually open $FLEX_MOCKUP_URL in Google Chrome."
    echo "Please manually open $OSPC_MIGRATION_URL in Google Chrome."
fi

echo "================================================"
echo " Dashboard is running. Press [Ctrl+C] to stop."
echo " Logs: $SCRIPT_DIR/dashboard.log"
echo " Dashboard (localhost): $DASHBOARD_URL"
if [[ -n "$PUBLIC_IP" ]]; then
    echo " Dashboard (public, TLS): https://$PUBLIC_IP:5002"
    echo " Dashboard (public, HTTP): http://$PUBLIC_IP:5001"
    [[ -n "$MOCKUP_PID" ]] && echo " FLEX mockup (public):     http://$PUBLIC_IP:5005/Flex-Skyline-New-Ui.html"
    echo " NOTE: open ports 5001/5002/5005 in the server's security group to reach these."
fi
[[ -n "$MOCKUP_PID" ]] && echo " FLEX mockup: $FLEX_MOCKUP_URL"
echo " OSPC mockup: $OSPC_MOCKUP_URL"
echo " OSPC mockup with Migration to FLEX open: $OSPC_MIGRATION_URL"
[[ -n "$MOCKUP_PID" ]] && echo " FLEX mockup logs: $MOCKUP_LOG"
echo "================================================"

trap "echo 'Shutting down dashboard...'; [[ -n \"$MOCKUP_PID\" ]] && kill \$MOCKUP_PID 2>/dev/null; exit 0" SIGINT SIGTERM
# If using systemd service, just wait in the foreground (service manages Flask)
if systemctl --user is-enabled osflex-dashboard >/dev/null 2>&1; then
    echo "(Flask managed by systemd — ctrl+C to exit this script, Flask stays running)"
    wait
else
    wait $APP_PID
fi
