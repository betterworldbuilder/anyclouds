#!/usr/bin/env bash
# OSFlex Dashboard self-restarting launcher.
# Uses double-fork so the daemon survives WSL session end.
# Called by @reboot cron and the 1-minute watchdog cron.

LOGFILE="/tmp/osflex-dashboard.log"
PIDFILE="/tmp/osflex-dashboard.pid"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_DIR/workflow_dashboard"
PYTHON="$PROJECT_DIR/.venv/bin/python"

if [[ ! -x "$PYTHON" ]]; then
    echo "[osflex] Missing $PYTHON; run $PROJECT_DIR/letsmove.sh first" >> "$LOGFILE"
    exit 1
fi

# This host now uses the osflex-dashboard user service as the single owner of
# Flask. Cron may still call this legacy watchdog with a minimal environment,
# so if the unit exists, delegate to systemd and never start a competing app.py
# process on port 5001.
if [ -f "$HOME/.config/systemd/user/osflex-dashboard.service" ]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    systemctl --user start osflex-dashboard >/dev/null 2>&1 || true
    exit 0
fi

# One-instance guard: exit if wrapper is already running
if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        exit 0
    fi
    rm -f "$PIDFILE"
fi

echo $$ > "$PIDFILE"
echo "[osflex] Wrapper started (pid $$) at $(date)" >> "$LOGFILE"

# Inner restart loop — double-fork each Flask child so it is detached
while true; do
    echo "[osflex] Starting Flask at $(date)" >> "$LOGFILE"
    (
        # First fork already done by subshell; do second fork via disown
        cd "$APP_DIR"
        WORKFLOW_DASHBOARD_HOST=127.0.0.1 \
        WORKFLOW_DASHBOARD_PORT=5001 \
        "$PYTHON" app.py >> "$LOGFILE" 2>&1
        EXIT_CODE=$?
        echo "[osflex] Flask exited (code $EXIT_CODE) at $(date)" >> "$LOGFILE"
    ) &
    CHILD_PID=$!
    # Wait for child Flask to die, then restart
    wait $CHILD_PID
    echo "[osflex] Restarting in 3s…" >> "$LOGFILE"
    sleep 3
done
