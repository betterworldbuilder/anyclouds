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
# Public IPv4 address for the externally reachable URLs printed at the end.
# PUBLIC_IP can be supplied explicitly for hosts without outbound web access.
# Do not fall back to `hostname -I`: on cloud hosts it normally returns the
# private service-network address and incorrectly labels it as public.
# On WSL the detected IP is the home router's NAT address — unreachable
# without port forwarding — so skip it and use localhost URLs only.
IS_WSL=0
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1
if [[ -z "${PUBLIC_IP:-}" && "$IS_WSL" -eq 0 ]]; then
    for PUBLIC_IP_SERVICE in \
        "https://api.ipify.org" \
        "https://checkip.amazonaws.com" \
        "https://ifconfig.me/ip"; do
        PUBLIC_IP="$(curl -4fsS --connect-timeout 2 --max-time 4 "$PUBLIC_IP_SERVICE" 2>/dev/null | tr -d '[:space:]')"
        [[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
        PUBLIC_IP=""
    done
fi

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
# Everything below is non-interactive and idempotent; nginx is optional (the
# dashboard falls back to plain HTTP on :5001 when it is unavailable).
export DEBIAN_FRONTEND=noninteractive

# System packages the dashboard and its panels need. This is the union of the
# core runtime and the jumphost tool list documented in
# requirements/requirements.txt (VM offline repair, DBaaS migration, audio).
APT_PACKAGES=(
    # core runtime
    python3-pip python3-venv nginx git curl wget jq unzip zip openssl
    ca-certificates psmisc procps openssh-client rsync sshpass
    # DBaaS migration (mysqldump/mysql via Cloud LB)
    mysql-client
    # Linux VM offline repair
    qemu-utils gdisk e2fsprogs xfsprogs parted
    # Windows VM offline repair
    ntfs-3g chntpw libhivex-bin
    # announce.py audio playback
    pulseaudio-utils mpg123 ffmpeg
)
MISSING_PKGS=()
for pkg in "${APT_PACKAGES[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING_PKGS+=("$pkg")
done
if ((${#MISSING_PKGS[@]})); then
    echo "-> Fresh host: installing ${#MISSING_PKGS[@]} system package(s): ${MISSING_PKGS[*]}"
    sudo apt-get update -qq || true
    if ! sudo apt-get install -y -qq "${MISSING_PKGS[@]}"; then
        # mysql-client is a meta package that is absent on some Ubuntu variants;
        # retry without it (mariadb-client is the drop-in) before giving up.
        RETRY_PKGS=()
        for pkg in "${MISSING_PKGS[@]}"; do [[ "$pkg" == "mysql-client" ]] || RETRY_PKGS+=("$pkg"); done
        sudo apt-get install -y -qq "${RETRY_PKGS[@]}" mariadb-client || {
            echo "ERROR: apt package installation failed. Run manually:"
            echo "       sudo apt-get install -y ${MISSING_PKGS[*]}"
            exit 1
        }
    fi
fi

# Kubernetes/GitOps CLIs used by the OpenCenter panels and live monitors.
# Best-effort: the dashboard runs without them; cluster panels need them.
if ! command -v kubectl >/dev/null 2>&1; then
    echo "-> Fresh host: installing kubectl..."
    KVER=$(curl -fsSL --max-time 15 https://dl.k8s.io/release/stable.txt 2>/dev/null)
    if [[ -n "$KVER" ]] && curl -fsSL --max-time 120 -o /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"; then
        sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl && rm -f /tmp/kubectl
    else
        echo "WARN: kubectl install failed — cluster panels will show 'not available'"
    fi
fi
if ! command -v helm >/dev/null 2>&1; then
    echo "-> Fresh host: installing helm..."
    curl -fsSL --max-time 120 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 2>/dev/null | bash >/dev/null 2>&1 \
        || echo "WARN: helm install failed — OpenCenter network-plugin step needs it on deployer hosts"
fi
if ! command -v flux >/dev/null 2>&1; then
    echo "-> Fresh host: installing flux CLI..."
    curl -fsSL --max-time 120 https://fluxcd.io/install.sh 2>/dev/null | sudo bash >/dev/null 2>&1 \
        || echo "WARN: flux CLI install failed — OpenCenter flux bootstrap needs it on deployer hosts"
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

echo "-> Opening dashboard and all mockup pages in the default browser..."
if [[ -n "$PUBLIC_IP" ]]; then
    if [[ "$DASHBOARD_URL" == http://* ]]; then
        OPEN_DASHBOARD_URL="http://$PUBLIC_IP:5001"
    else
        OPEN_DASHBOARD_URL="https://$PUBLIC_IP:5002"
    fi
    OPEN_FLEX_URL="http://$PUBLIC_IP:5005/Flex-Skyline-New-Ui.html?v=$(date +%s)"
else
    OPEN_DASHBOARD_URL="$DASHBOARD_URL"
    OPEN_FLEX_URL="$FLEX_MOCKUP_URL"
fi
OPEN_OSPC_URL="$OPEN_DASHBOARD_URL/ospc_cloud_mockup/"
OPEN_OSPC_MIGRATION_URL="$OPEN_DASHBOARD_URL/ospc_cloud_mockup/?migration=1"

OPEN_URLS=("$OPEN_DASHBOARD_URL" "$OPEN_OSPC_URL" "$OPEN_OSPC_MIGRATION_URL")
# Also open the exact localhost OSPC pages printed in the startup summary.
# They are distinct from the public URLs on remote/cloud hosts.
[[ "$OSPC_MOCKUP_URL" != "$OPEN_OSPC_URL" ]] && OPEN_URLS+=("$OSPC_MOCKUP_URL")
[[ "$OSPC_MIGRATION_URL" != "$OPEN_OSPC_MIGRATION_URL" ]] && OPEN_URLS+=("$OSPC_MIGRATION_URL")
[[ -n "$MOCKUP_PID" ]] && OPEN_URLS+=("$OPEN_FLEX_URL")

open_browser_url() {
    local url="$1"
    if command -v cmd.exe > /dev/null 2>&1; then
        (cd /mnt/c/Windows/System32 2>/dev/null || cd /tmp; cmd.exe /C start "" chrome "$url")
    elif command -v explorer.exe > /dev/null 2>&1; then
        (cd /mnt/c/Windows/System32 2>/dev/null || cd /tmp; explorer.exe "$url")
    elif command -v xdg-open > /dev/null 2>&1; then
        xdg-open "$url" > /dev/null 2>&1 &
    elif command -v google-chrome > /dev/null 2>&1; then
        google-chrome "$url" > /dev/null 2>&1 &
    elif command -v chromium > /dev/null 2>&1; then
        chromium "$url" > /dev/null 2>&1 &
    else
        return 1
    fi
}

BROWSER_OPENED=1
for url in "${OPEN_URLS[@]}"; do
    if ! open_browser_url "$url"; then
        BROWSER_OPENED=0
        break
    fi
done
if [[ "$BROWSER_OPENED" -eq 0 ]]; then
    echo "No graphical browser launcher was found on this host. Open these URLs from your workstation:"
    printf '  %s\n' "${OPEN_URLS[@]}"
fi
echo "================================================"
echo " Dashboard is running. Press [Ctrl+C] to stop."
echo " Logs: $SCRIPT_DIR/dashboard.log"
echo " Dashboard (localhost): $DASHBOARD_URL"
if [[ -n "$PUBLIC_IP" ]]; then
    echo " Dashboard (public, TLS):  https://$PUBLIC_IP:5002"
    echo " Dashboard (public, HTTP): http://$PUBLIC_IP:5001"
    echo " OSPC mockup (public):      $OPEN_OSPC_URL"
    echo " OSPC migration (public):   $OPEN_OSPC_MIGRATION_URL"
    [[ -n "$MOCKUP_PID" ]] && echo " FLEX mockup (public):      $OPEN_FLEX_URL"
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
