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

echo "================================================"
echo " Starting OSPC to FLEX Migration Dashboard "
echo "================================================"

echo "-> Cleaning up previous background instances..."
pkill -f "python3 app.py" 2>/dev/null || true
fuser -k 5001/tcp 2>/dev/null || true
sleep 1

echo "-> Starting nginx (HTTP/2 on port 5002)..."
systemctl restart nginx 2>/dev/null || true

echo "-> Installing dependencies..."
pip3 install --break-system-packages -q -r "$SCRIPT_DIR/requirements/requirements.txt"

# Navigate to dashboard directory
cd "$SCRIPT_DIR/workflow_dashboard" || exit 1

# Check syntax before launching (no bytecode writing)
echo "-> Verifying app.py syntax..."
if ! python3 -B -m py_compile app.py; then
    echo "ERROR: app.py has a syntax error. Dashboard cannot start."
    exit 1
fi

# Start the Flask app in the background
echo "-> Starting Flask application..."
python3 app.py &> "$SCRIPT_DIR/dashboard.log" &
APP_PID=$!

echo "-> Waiting for server to initialize (up to 30s)..."
for i in $(seq 1 30); do
    sleep 1
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "ERROR: Flask app exited unexpectedly. Check $SCRIPT_DIR/dashboard.log for details."
        cat "$SCRIPT_DIR/dashboard.log" | tail -20
        exit 1
    fi
    if curl -sk --max-time 1 https://127.0.0.1:5002/ > /dev/null 2>&1; then
        echo "-> Server is up!"
        break
    fi
    echo "   ... waiting ($i/30)"
done

echo "-> Opening Google Chrome to https://127.0.0.1:5002..."
if command -v cmd.exe > /dev/null 2>&1; then
    cmd.exe /C start chrome "https://127.0.0.1:5002"
elif command -v explorer.exe > /dev/null 2>&1; then
    explorer.exe "https://127.0.0.1:5002"
elif command -v xdg-open > /dev/null 2>&1; then
    xdg-open "https://127.0.0.1:5002"
else
    echo "Please manually open https://127.0.0.1:5002 in Google Chrome."
fi

echo "================================================"
echo " Dashboard is running. Press [Ctrl+C] to stop."
echo " Logs: $SCRIPT_DIR/dashboard.log"
echo "================================================"

trap "echo 'Shutting down dashboard...'; kill $APP_PID 2>/dev/null; exit 0" SIGINT SIGTERM
wait $APP_PID
