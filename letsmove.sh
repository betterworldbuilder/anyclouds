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

# ── Local unprivileged nginx (TLS :5002) ─────────────────────────────────────
# Hosts without systemd (WSL) or without passwordless sudo cannot restart the
# system nginx, which used to leave the dashboard on plain http://…:5001.
# Port 5002 is unprivileged, so run our own nginx master from a user-owned
# prefix instead: same TLS URL and HTTP/2, no root required.
USER_NGINX_PREFIX="$HOME/.cache/osflex-nginx"
USER_NGINX_CONF="$USER_NGINX_PREFIX/nginx.conf"
USER_NGINX_PID="$USER_NGINX_PREFIX/nginx.pid"

stop_user_nginx() {
    [[ -s "$USER_NGINX_PID" ]] || return 0
    nginx -p "$USER_NGINX_PREFIX" -c "$USER_NGINX_CONF" -s stop >/dev/null 2>&1 \
        || kill "$(cat "$USER_NGINX_PID" 2>/dev/null)" 2>/dev/null || true
    rm -f "$USER_NGINX_PID"
}

# Issue the TLS material for the unprivileged nginx. We mint a small local CA
# and sign a leaf from it (the mkcert model) rather than using a bare
# self-signed cert: browsers reject a cert with no subjectAltName outright, and
# a CA is what a trust store can actually anchor. Install
# $USER_NGINX_PREFIX/ssl/osflex-ca.crt once on the workstation and
# https://127.0.0.1:5002 loads without a warning — see install_local_ca_hint().
ensure_user_nginx_cert() {
    local ssl="$USER_NGINX_PREFIX/ssl"
    mkdir -p "$ssl" || return 1

    # Reuse existing material only if the leaf already carries the loopback SAN;
    # certs from older runs are CN-only and Chrome refuses them.
    if [[ -s "$ssl/osflex.key" && -s "$ssl/fullchain.crt" ]] \
        && openssl x509 -in "$ssl/osflex.crt" -noout -ext subjectAltName 2>/dev/null \
           | grep -q 'IP Address:127.0.0.1'; then
        return 0
    fi

    if [[ ! -s "$ssl/osflex-ca.key" ]]; then
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -sha256 \
            -keyout "$ssl/osflex-ca.key" -out "$ssl/osflex-ca.crt" \
            -subj "/CN=OSFlex Dashboard Local CA/O=OSFlex" \
            -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1 || return 1
    fi

    # Every address the launcher may print must be in the SAN list, or the
    # browser fails the name check even with the CA trusted.
    local sans="DNS:localhost,DNS:osflex-dashboard,IP:127.0.0.1,IP:::1"
    local host_fqdn; host_fqdn="$(hostname -f 2>/dev/null || hostname 2>/dev/null)"
    [[ -n "$host_fqdn" && "$host_fqdn" != "localhost" ]] && sans+=",DNS:$host_fqdn"
    [[ -n "${PUBLIC_IP:-}" ]] && sans+=",IP:$PUBLIC_IP"

    openssl req -nodes -newkey rsa:2048 -sha256 \
        -keyout "$ssl/osflex.key" -out "$ssl/osflex.csr" \
        -subj "/CN=osflex-dashboard" >/dev/null 2>&1 || return 1
    cat > "$ssl/leaf.ext" <<EXT
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$sans
EXT
    # 825 days: browsers cap leaf lifetime, and a longer one is silently rejected.
    openssl x509 -req -in "$ssl/osflex.csr" -days 825 -sha256 \
        -CA "$ssl/osflex-ca.crt" -CAkey "$ssl/osflex-ca.key" -CAcreateserial \
        -out "$ssl/osflex.crt" -extfile "$ssl/leaf.ext" >/dev/null 2>&1 || return 1
    cat "$ssl/osflex.crt" "$ssl/osflex-ca.crt" > "$ssl/fullchain.crt" || return 1
    rm -f "$ssl/osflex.csr" "$ssl/leaf.ext"
    chmod 600 "$ssl/osflex.key" "$ssl/osflex-ca.key" 2>/dev/null || true
}

start_user_nginx() {
    command -v nginx >/dev/null 2>&1 || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    mkdir -p "$USER_NGINX_PREFIX"/logs "$USER_NGINX_PREFIX"/tmp || return 1
    # Our own cert: /etc/nginx/ssl/osflex.key is mode 0600 root and unreadable
    # by an unprivileged worker.
    ensure_user_nginx_cert || return 1
    # Mirrors workflow_dashboard/osflex_nginx.conf, with every runtime path
    # relocated under the user prefix so no root-owned dir is touched.
    cat > "$USER_NGINX_CONF" <<EOF
worker_processes 1;
pid $USER_NGINX_PID;
error_log $USER_NGINX_PREFIX/logs/error.log warn;

events { worker_connections 768; }

http {
    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;
    access_log          $USER_NGINX_PREFIX/logs/access.log;
    client_body_temp_path $USER_NGINX_PREFIX/tmp/client_body;
    proxy_temp_path       $USER_NGINX_PREFIX/tmp/proxy;
    fastcgi_temp_path     $USER_NGINX_PREFIX/tmp/fastcgi;
    uwsgi_temp_path       $USER_NGINX_PREFIX/tmp/uwsgi;
    scgi_temp_path        $USER_NGINX_PREFIX/tmp/scgi;
    sendfile            on;

    server {
        listen 5002 ssl http2;
        server_name localhost 127.0.0.1;

        ssl_certificate     $USER_NGINX_PREFIX/ssl/fullchain.crt;
        ssl_certificate_key $USER_NGINX_PREFIX/ssl/osflex.key;
        ssl_protocols       TLSv1.2 TLSv1.3;

        # Allow large uploads (scripts)
        client_max_body_size 50M;

        location / {
            proxy_pass         http://127.0.0.1:5001;
            proxy_http_version 1.1;

            # SSE settings
            proxy_set_header   Connection '';
            proxy_buffering    off;
            proxy_cache        off;
            proxy_read_timeout 3600s;

            proxy_set_header   Host \$host;
            proxy_set_header   X-Real-IP \$remote_addr;
        }
    }
}
EOF
    nginx -p "$USER_NGINX_PREFIX" -c "$USER_NGINX_CONF" -t >/dev/null 2>&1 || return 1
    nginx -p "$USER_NGINX_PREFIX" -c "$USER_NGINX_CONF" || return 1
}
# ─────────────────────────────────────────────────────────────────────────────

echo "-> Cleaning up previous background instances..."
systemctl --user stop osflex-dashboard >/dev/null 2>&1 || true
pkill -f "$SCRIPT_DIR/workflow_dashboard/run_dashboard.sh" >/dev/null 2>&1 || true
rm -f /tmp/osflex-dashboard.pid
stop_user_nginx
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
    # Fresh cloud images often have an interrupted dpkg state or a stale apt
    # lock (cloud-init/unattended-upgrades). Wait for the lock, then repair
    # before installing — otherwise every install fails with
    # "E: Unmet dependencies. Try 'apt --fix-broken install'".
    for _i in $(seq 1 30); do
        sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
        [[ "$_i" == 1 ]] && echo "   waiting for another apt/dpkg process to finish..."
        sleep 5
    done
    sudo dpkg --configure -a >/dev/null 2>&1 || true
    sudo apt-get install -y -qq --fix-broken >/dev/null 2>&1 || true
    sudo apt-get update -qq || true
    if ! sudo apt-get install -y -qq "${MISSING_PKGS[@]}"; then
        # mysql-client is a meta package that is absent on some Ubuntu variants;
        # retry without it (mariadb-client is the drop-in) before giving up.
        RETRY_PKGS=()
        for pkg in "${MISSING_PKGS[@]}"; do [[ "$pkg" == "mysql-client" ]] || RETRY_PKGS+=("$pkg"); done
        sudo apt-get install -y -qq "${RETRY_PKGS[@]}" mariadb-client || {
            echo "ERROR: apt package installation failed. Diagnose with:"
            echo "       sudo apt --fix-broken install"
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
# mise: the OpenCenter Quick Start training lab's Stage 1 builds the CLI with
# `mise trust && mise install && mise run build`. The lab's command policy
# deliberately refuses to pipe a fetched installer into a shell for a learner
# (shared multi-tenant sandbox), so mise has to exist on the host before any
# student session starts. Without it Stage 1 fails with "mise: command not
# found" for every learner and the CLI never gets built - which is why the
# hosted deployment failed while a dev box with a manually-installed copy at
# ~/.local/bin/mise worked fine.
if ! command -v mise >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/mise" ]]; then
    echo "-> Fresh host: installing mise (OpenCenter training lab Stage 1 needs it)..."
    curl -fsSL --max-time 120 https://mise.run 2>/dev/null | sh >/dev/null 2>&1 \
        || echo "WARN: mise install failed — OpenCenter Quick Start Stage 1 cannot build the CLI without it"
fi
if command -v nginx >/dev/null 2>&1 && [[ ! -f /etc/nginx/conf.d/osflex.conf ]] \
        && [[ -f "$SCRIPT_DIR/workflow_dashboard/osflex_nginx.conf" ]]; then
    echo "-> Fresh host: installing nginx site config + self-signed certificate..."
    # sudo -n throughout: without passwordless sudo this must fail fast rather
    # than block the launcher on a password prompt (the unprivileged nginx
    # fallback below covers that host anyway).
    sudo -n mkdir -p /etc/nginx/ssl 2>/dev/null
    if [[ ! -f /etc/nginx/ssl/osflex.key ]]; then
        sudo -n openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -keyout /etc/nginx/ssl/osflex.key -out /etc/nginx/ssl/osflex.crt \
            -subj "/CN=osflex-dashboard" >/dev/null 2>&1
    fi
    sudo -n cp "$SCRIPT_DIR/workflow_dashboard/osflex_nginx.conf" /etc/nginx/conf.d/osflex.conf 2>/dev/null || true
fi
# ─────────────────────────────────────────────────────────────────────────────

echo "-> Starting nginx (HTTP/2 on port 5002)..."
# sudo -n first: never hang on an interactive polkit/password prompt.
if sudo -n systemctl restart nginx >/dev/null 2>&1 \
    || systemctl restart nginx >/dev/null 2>&1 \
    || sudo -n nginx -s reload >/dev/null 2>&1 \
    || nginx -s reload >/dev/null 2>&1; then
    :
elif start_user_nginx; then
    # No systemd / no passwordless sudo (typical on WSL): our own nginx master
    # owns :5002 instead, so the UI stays on the documented HTTPS port.
    echo "-> System nginx unavailable — started unprivileged nginx on :5002 (prefix: $USER_NGINX_PREFIX)"
    USER_NGINX_STARTED=1
else
    echo "WARN: nginx not started — dashboard reachable directly at http://127.0.0.1:5001"
fi

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

# Start Flask via a self-healing systemd user service.
# IMPORTANT: always rewrite the unit from this clone. An older version only
# restarted an already-enabled service, so its stale WorkingDirectory could
# continue serving a completely different checkout after a fresh git clone.
echo "-> Starting Flask application (via self-healing systemd user service)..."
SYSTEMD_MANAGED=0
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SYSTEMD_SERVICE_NAME="osflex-dashboard.service"
SYSTEMD_SERVICE_FILE="$SYSTEMD_USER_DIR/$SYSTEMD_SERVICE_NAME"
DASHBOARD_DIR="$(readlink -f "$SCRIPT_DIR/workflow_dashboard")"
PYTHON_BIN="$(command -v python3)"

install_dashboard_user_service() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl --user show-environment >/dev/null 2>&1 || return 1

    mkdir -p "$SYSTEMD_USER_DIR" || return 1
    local candidate="${SYSTEMD_SERVICE_FILE}.new"
    cat > "$candidate" <<EOF
[Unit]
Description=OSPC to FLEX Migration Dashboard
After=network.target

[Service]
Type=simple
WorkingDirectory=$DASHBOARD_DIR
ExecStart=$PYTHON_BIN -B $DASHBOARD_DIR/app.py
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=WORKFLOW_DASHBOARD_HOST=$WORKFLOW_DASHBOARD_HOST
Environment=PATH=$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF

    # Replace stale units, including units created from a different clone.
    if [[ ! -f "$SYSTEMD_SERVICE_FILE" ]] || ! cmp -s "$candidate" "$SYSTEMD_SERVICE_FILE"; then
        mv "$candidate" "$SYSTEMD_SERVICE_FILE" || return 1
        echo "   refreshed $SYSTEMD_SERVICE_FILE for this checkout"
    else
        rm -f "$candidate"
    fi

    systemctl --user daemon-reload || return 1
    systemctl --user reset-failed "$SYSTEMD_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl --user enable "$SYSTEMD_SERVICE_NAME" >/dev/null 2>&1 || return 1
    systemctl --user restart "$SYSTEMD_SERVICE_NAME" || return 1

    # systemctl restart can return just before MainPID becomes non-zero. Wait for
    # a real process instead of incorrectly falling back to a second Flask copy.
    APP_PID=""
    for _i in $(seq 1 50); do
        APP_PID="$(systemctl --user show "$SYSTEMD_SERVICE_NAME" --value --property MainPID 2>/dev/null || true)"
        [[ "$APP_PID" =~ ^[1-9][0-9]*$ ]] && break
        sleep 0.1
    done
    [[ "$APP_PID" =~ ^[1-9][0-9]*$ ]] || return 1

    # Fail loudly rather than silently serving an old checkout again.
    local actual_dir=""
    for _i in $(seq 1 20); do
        actual_dir="$(readlink -f "/proc/$APP_PID/cwd" 2>/dev/null || true)"
        [[ -n "$actual_dir" ]] && break
        sleep 0.1
    done
    if [[ "$actual_dir" != "$DASHBOARD_DIR" ]]; then
        echo "ERROR: systemd started Flask from the wrong directory."
        echo "       Expected: $DASHBOARD_DIR"
        echo "       Actual:   ${actual_dir:-unknown}"
        systemctl --user status "$SYSTEMD_SERVICE_NAME" --no-pager -l 2>/dev/null || true
        return 1
    fi

    echo "   Flask service directory verified: $actual_dir"
    SYSTEMD_MANAGED=1
    return 0
}

if ! install_dashboard_user_service; then
    echo "WARN: systemd user service unavailable or failed; starting Flask directly."
    systemctl --user stop "$SYSTEMD_SERVICE_NAME" >/dev/null 2>&1 || true
    python3 -B app.py &>> "$SCRIPT_DIR/dashboard.log" &
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
    if [[ "$SYSTEMD_MANAGED" -eq 1 ]]; then
        if ! systemctl --user is-active --quiet "$SYSTEMD_SERVICE_NAME"; then
            echo "ERROR: Flask service failed. Check: journalctl --user -u $SYSTEMD_SERVICE_NAME -n 30"
            exit 1
        fi
    elif ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "ERROR: Flask app exited unexpectedly. Check $SCRIPT_DIR/dashboard.log for details."
        cat "$SCRIPT_DIR/dashboard.log" | tail -20
        exit 1
    fi
    # Flask on :5001 is the real readiness signal — nginx is already listening
    # on :5002 by now and would answer a bare curl with a 502 while Flask boots.
    if curl -s --max-time 1 "http://127.0.0.1:5001/" > /dev/null 2>&1; then
        if curl -sk --max-time 2 "https://127.0.0.1:5002/" > /dev/null 2>&1; then
            DASHBOARD_URL="https://127.0.0.1:5002"
            echo "-> Server is up (HTTPS on :5002 via nginx)."
        else
            DASHBOARD_URL="http://127.0.0.1:5001"
            echo "-> Server is up (direct HTTP on :5001 — nginx proxy not active)."
        fi
        break
    fi
    echo "   ... waiting ($i/30)"
done

# Keep every printed/opened URL on whichever port actually answered.
OSPC_MOCKUP_URL="$DASHBOARD_URL/ospc_cloud_mockup/"
OSPC_MIGRATION_URL="$DASHBOARD_URL/ospc_cloud_mockup/?migration=1"

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
if [[ -n "${USER_NGINX_STARTED:-}" ]]; then
    echo " TLS: local CA at $USER_NGINX_PREFIX/ssl/osflex-ca.crt"
    echo "      Trust it once to drop the browser warning (NET::ERR_CERT_AUTHORITY_INVALID):"
    echo "        Windows: certutil -user -addstore Root \\\\wsl\$\\Ubuntu$USER_NGINX_PREFIX/ssl/osflex-ca.crt"
    echo "        Linux:   sudo cp $USER_NGINX_PREFIX/ssl/osflex-ca.crt /usr/local/share/ca-certificates/osflex-ca.crt && sudo update-ca-certificates"
fi
[[ -n "$MOCKUP_PID" ]] && echo " FLEX mockup: $FLEX_MOCKUP_URL"
echo " OSPC mockup: $OSPC_MOCKUP_URL"
echo " OSPC mockup with Migration to FLEX open: $OSPC_MIGRATION_URL"
[[ -n "$MOCKUP_PID" ]] && echo " FLEX mockup logs: $MOCKUP_LOG"
echo "================================================"

trap "echo 'Shutting down dashboard...'; [[ -n \"${USER_NGINX_STARTED:-}\" ]] && stop_user_nginx; [[ -n \"$MOCKUP_PID\" ]] && kill \$MOCKUP_PID 2>/dev/null; exit 0" SIGINT SIGTERM
# If using systemd service, just wait in the foreground (service manages Flask)
if [[ "$SYSTEMD_MANAGED" -eq 1 ]]; then
    echo "(Flask managed by systemd from $DASHBOARD_DIR — ctrl+C exits this launcher; Flask stays running)"
    wait
else
    wait "$APP_PID"
fi

