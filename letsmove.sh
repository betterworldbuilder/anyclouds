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
fuser -k 5005/tcp 2>/dev/null || true
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

# Serve the FLEX cloud mockup HTML on its own lightweight local port.
MOCKUP_HTML="$SCRIPT_DIR/Flex-Skyline-New-Ui.html"
MOCKUP_LOG="$SCRIPT_DIR/flex_mockup_5005.log"
MOCKUP_PID=""
if [[ -f "$MOCKUP_HTML" ]]; then
    echo "-> Starting FLEX web UI mockup on http://127.0.0.1:5005/Flex-Skyline-New-Ui.html..."
    (cd "$SCRIPT_DIR" && python3 -m http.server 5005 --bind 127.0.0.1) &> "$MOCKUP_LOG" &
    MOCKUP_PID=$!
else
    echo "WARN: FLEX web UI mockup file not found: $MOCKUP_HTML"
fi

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

if [[ -n "$MOCKUP_PID" ]]; then
    echo "-> Waiting for FLEX web UI mockup on port 5005..."
    for i in $(seq 1 10); do
        sleep 1
        if ! kill -0 "$MOCKUP_PID" 2>/dev/null; then
            echo "WARN: FLEX mockup server exited unexpectedly. Check $MOCKUP_LOG for details."
            tail -20 "$MOCKUP_LOG" 2>/dev/null || true
            break
        fi
        if curl -s --max-time 1 "http://127.0.0.1:5005/Flex-Skyline-New-Ui.html" > /dev/null 2>&1; then
            echo "-> FLEX web UI mockup is up!"
            break
        fi
        echo "   ... waiting for mockup ($i/10)"
    done
fi

echo "-> Opening Google Chrome to https://127.0.0.1:5002..."
if command -v cmd.exe > /dev/null 2>&1; then
    cmd.exe /C start chrome "https://127.0.0.1:5002"
    [[ -n "$MOCKUP_PID" ]] && cmd.exe /C start chrome "http://127.0.0.1:5005/Flex-Skyline-New-Ui.html"
elif command -v explorer.exe > /dev/null 2>&1; then
    explorer.exe "https://127.0.0.1:5002"
    [[ -n "$MOCKUP_PID" ]] && explorer.exe "http://127.0.0.1:5005/Flex-Skyline-New-Ui.html"
elif command -v xdg-open > /dev/null 2>&1; then
    xdg-open "https://127.0.0.1:5002"
    [[ -n "$MOCKUP_PID" ]] && xdg-open "http://127.0.0.1:5005/Flex-Skyline-New-Ui.html"
else
    echo "Please manually open https://127.0.0.1:5002 in Google Chrome."
    [[ -n "$MOCKUP_PID" ]] && echo "Please manually open http://127.0.0.1:5005/Flex-Skyline-New-Ui.html in Google Chrome."
fi

echo "================================================"
echo " Dashboard is running. Press [Ctrl+C] to stop."
echo " Logs: $SCRIPT_DIR/dashboard.log"
[[ -n "$MOCKUP_PID" ]] && echo " FLEX mockup: http://127.0.0.1:5005/Flex-Skyline-New-Ui.html"
[[ -n "$MOCKUP_PID" ]] && echo " FLEX mockup logs: $MOCKUP_LOG"
echo "================================================"

trap "echo 'Shutting down dashboard...'; kill $APP_PID 2>/dev/null; [[ -n \"$MOCKUP_PID\" ]] && kill $MOCKUP_PID 2>/dev/null; exit 0" SIGINT SIGTERM
wait $APP_PID
