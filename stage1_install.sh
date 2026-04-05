#!/usr/bin/env bash
# Stage 1: OS Packages, Runtimes & Environments Setup
# Generated: 2026-04-05 (Fixed version)
# Customer:  ospc2flex rax
# Goal:      Install required packages on FLEX target servers

export INSTALL_USER="${INSTALL_USER:-ubuntu}"
export INSTALL_KEY="${INSTALL_KEY:-$HOME/.ssh/id_rsa}"
SSH_OPTS="-i $INSTALL_KEY -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15"

RUN_TS=$(date +%Y%m%dT%H%M%SZ)
mkdir -p ./migration-csv
RESULTS_CSV="./migration-csv/stage1-${RUN_TS}.csv"
echo "node,ip,os_type,packages,status" > "$RESULTS_CSV"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

log()  { echo "[$(date +%H:%M:%S)] $*"; }
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
err()  { echo "  [ERR]  $*"; }

# ── install_apt: install packages on Ubuntu/Debian ────────────────────────────
install_apt() {
    local node=$1 ip=$2; shift 2
    local pkgs=("$@")
    local pkgs_str="${pkgs[*]}"

    log "[$node @ $ip] apt install: $pkgs_str"

    # Run install
    if ssh $SSH_OPTS "${INSTALL_USER}@${ip}" \
        "sudo apt-get update -qq 2>/dev/null && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs_str}"; then
        ok "$node packages installed"
        echo "$node,$ip,debian,$pkgs_str,PASS" >> "$RESULTS_CSV"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        err "$node apt-get failed on $ip"
        echo "$node,$ip,debian,$pkgs_str,FAIL" >> "$RESULTS_CSV"
        FAIL_COUNT=$((FAIL_COUNT+1))
        return 1
    fi

    # Verify each package
    for pkg in "${pkgs[@]}"; do
        if ssh $SSH_OPTS "${INSTALL_USER}@${ip}" \
            "dpkg -l 2>/dev/null | grep -qE '^ii\s+${pkg}' || command -v ${pkg} >/dev/null 2>&1"; then
            ok "[PASS] $pkg"
        else
            warn "[WARN] $pkg not confirmed"
        fi
    done
}

# ── install_dnf: install packages on RHEL/Rocky/AlmaLinux/CentOS ──────────────
install_dnf() {
    local node=$1 ip=$2; shift 2
    local pkgs=("$@")
    local pkgs_str="${pkgs[*]}"

    log "[$node @ $ip] dnf install: $pkgs_str"

    if ssh $SSH_OPTS "${INSTALL_USER}@${ip}" \
        "sudo dnf install -y ${pkgs_str} 2>&1"; then
        ok "$node packages installed"
        echo "$node,$ip,rhel,$pkgs_str,PASS" >> "$RESULTS_CSV"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        err "$node dnf failed on $ip"
        echo "$node,$ip,rhel,$pkgs_str,FAIL" >> "$RESULTS_CSV"
        FAIL_COUNT=$((FAIL_COUNT+1))
        return 1
    fi

    for pkg in "${pkgs[@]}"; do
        if ssh $SSH_OPTS "${INSTALL_USER}@${ip}" \
            "rpm -q ${pkg} >/dev/null 2>&1 || command -v ${pkg} >/dev/null 2>&1"; then
            ok "[PASS] $pkg"
        else
            warn "[WARN] $pkg not confirmed"
        fi
    done
}

# ── skip_windows: handle Windows nodes ───────────────────────────────────────
skip_windows() {
    local node=$1 ip=$2
    warn "[$node @ $ip] SKIPPED — Windows Server detected. Use WinRM/Ansible for Windows setup."
    echo "$node,$ip,windows,N/A,SKIPPED" >> "$RESULTS_CSV"
    SKIP_COUNT=$((SKIP_COUNT+1))
}

echo "============================================================"
echo " Stage 1: OS Package & Runtime Installation"
echo " Started: $RUN_TS"
echo "============================================================"

# ── u24-BackEnd-2 @ 50.56.158.247 (Ubuntu 24.04) ────────────────────────────
echo "------------------------------------------------------------"
install_apt "u24-BackEnd-2" "50.56.158.247" \
    python3-pip python3 python3.10 gunicorn

# ── u24-FrontEnd 2 @ 50.56.158.17 (Ubuntu 24.04) ────────────────────────────
echo "------------------------------------------------------------"
install_apt "u24-FrontEnd-2" "50.56.158.17" \
    nginx nodejs npm

# ── rocky8 @ 50.56.158.196 (Rocky Linux 8) ──────────────────────────────────
echo "------------------------------------------------------------"
install_dnf "rocky8" "50.56.158.196" \
    openssh-server python3 bash

# ── alma9-2gv1 @ N/A (no floating IP) ───────────────────────────────────────
echo "------------------------------------------------------------"
warn "[alma9-2gv1] No floating IP — assign one in Horizon first, then re-run."
echo "alma9-2gv1,N/A,rhel,N/A,SKIPPED-NO-IP" >> "$RESULTS_CSV"
SKIP_COUNT=$((SKIP_COUNT+1))

# ── debian10-Flav2gv1 @ 50.56.159.78 (Debian 10) ────────────────────────────
echo "------------------------------------------------------------"
install_apt "debian10-Flav2gv1" "50.56.159.78" \
    openssh-server python3 bash

# ── u24-postgresl @ 50.56.158.138 (Ubuntu 24.04) ────────────────────────────
echo "------------------------------------------------------------"
install_apt "u24-postgresl" "50.56.158.138" \
    postgresql libpq-dev

# ── u24-FrontEnd @ 50.56.158.36 (Ubuntu 24.04) ──────────────────────────────
echo "------------------------------------------------------------"
install_apt "u24-FrontEnd" "50.56.158.36" \
    nginx nodejs npm

# ── Windows Server 2019Re — SKIP (Windows, no apt) ──────────────────────────
echo "------------------------------------------------------------"
skip_windows "Windows Server 2019Re" "104.130.13.83"

# ── win2019websql2019 — SKIP (Windows, no apt) ───────────────────────────────
echo "------------------------------------------------------------"
skip_windows "win2019websql2019" "104.130.26.6"

# ── Windows Server 2016 + SQL Server 2019 — SKIP ────────────────────────────
echo "------------------------------------------------------------"
skip_windows "Windows-2016-SQL2019" "23.253.159.213"

# ── u24Backend @ 50.56.159.90 (Ubuntu 24.04) ────────────────────────────────
echo "------------------------------------------------------------"
install_apt "u24Backend" "50.56.159.90" \
    python3-pip python3 python3.10 gunicorn celery

# ── Summary ──────────────────────────────────────────────────────────────────
echo "============================================================"
echo " Stage 1 Complete"
echo "   PASS:    $PASS_COUNT"
echo "   FAIL:    $FAIL_COUNT"
echo "   SKIPPED: $SKIP_COUNT"
echo "   Report:  $RESULTS_CSV"
echo "============================================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "WARNING: $FAIL_COUNT node(s) failed. Check report: $RESULTS_CSV"
    exit 1
fi
