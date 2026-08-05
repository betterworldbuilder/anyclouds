#!/usr/bin/env python3
"""
server_deep_scan.py
====================
Deep-scan a list of servers via SSH and collect:
  • Exact OS version  (from /etc/os-release)
  • Installed packages (apt / yum / rpm / dnf / apk / brew)
  • Running runtimes   (Python, Node, Java, PHP, Ruby, Go, .NET, Rust…)
  • Environment snapshot (systemd services, cron jobs, open ports, env vars,
                          kernel version, hostname, CPU / RAM, disk layout)

INPUT  (env vars + CLI):
  --hosts   CSV of "name:ip" pairs   e.g.  web01:1.2.3.4,db01:5.6.7.8
  --ip-csv  Path to CSV file with columns: name, ip  (or: server_name, ip_address)
  --user    SSH user (default: ubuntu)
  --key     Path to SSH private key (default: ~/.ssh/id_rsa)
  --port    SSH port (default: 22)
  --timeout SSH connect timeout in seconds (default: 15)
  --output  Output JSON file path (default: stdout)
  --workers Parallel worker threads (default: 8)
  --no-packages  Skip package list scan (fast mode)
  --no-ports     Skip netstat/ss port scan

  Environment variable overrides:
    SCAN_SSH_USER   SCAN_SSH_KEY   SCAN_SSH_PORT   SCAN_SSH_TIMEOUT

OUTPUT (JSON array, one entry per host):
[
  {
    "name":           "web01",
    "ip":             "1.2.3.4",
    "ssh_ok":         true,
    "os_type":        "Linux",          # Linux | Windows | FreeBSD
    "os_distro":      "ubuntu",
    "os_version":     "22.04",
    "os_pretty":      "Ubuntu 22.04.3 LTS",
    "kernel":         "5.15.0-97-generic",
    "hostname":       "web01.example.com",
    "cpu_cores":      4,
    "ram_mb":         8192,
    "disk_gb":        50,
    "packages": [
      {"name": "nginx", "version": "1.18.0"},
      ...
    ],
    "package_count":  243,
    "runtimes": {
      "python":  "3.10.12",
      "python2": null,
      "node":    "18.19.0",
      "npm":     "9.2.0",
      "java":    "17.0.10",
      "php":     "8.1.2",
      "ruby":    "3.0.2",
      "go":      "1.21.5",
      "dotnet":  null,
      "rust":    null,
      "perl":    "5.34.0",
      "lua":     null,
      "r":       null
    },
    "services": {
      "running":  ["nginx", "postgresql", "redis-server"],
      "enabled":  ["nginx", "postgresql", "redis-server", "cron"],
      "failed":   []
    },
    "cron_jobs": ["0 2 * * * /opt/backup.sh", ...],
    "open_ports": [
      {"port": 80,   "proto": "tcp", "process": "nginx"},
      {"port": 443,  "proto": "tcp", "process": "nginx"},
      {"port": 5432, "proto": "tcp", "process": "postgres"},
      ...
    ],
    "env_vars": {
      "PATH": "/usr/local/sbin:/usr/local/bin:...",
      "JAVA_HOME": "/usr/lib/jvm/java-17-openjdk-amd64",
      ...
    },
    "docker": {
      "installed": true,
      "version": "24.0.5",
      "containers_running": 3,
      "images": ["nginx:latest", "postgres:15"]
    },
    "databases": {
      "postgresql": {"installed": true, "version": "15.4", "port": 5432},
      "mysql":      {"installed": false},
      "mariadb":    {"installed": false},
      "mongodb":    {"installed": false},
      "redis":      {"installed": true, "version": "7.0.11", "port": 6379}
    },
    "web_servers": {
      "nginx":   {"installed": true,  "version": "1.24.0"},
      "apache2": {"installed": false},
      "caddy":   {"installed": false}
    },
    "error":   null,
    "scan_duration_s": 4.2,
    "scanned_at": "2026-04-05T22:00:00Z"
  },
  ...
]
"""

import argparse
import concurrent.futures
import csv
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


# ── ANSI colours (safe to disable if piped) ───────────────────────────────────
USE_COLOR = sys.stderr.isatty()
def _c(code, text):  return f"\033[{code}m{text}\033[0m" if USE_COLOR else text
def green(t):  return _c("32", t)
def yellow(t): return _c("33", t)
def red(t):    return _c("31", t)
def cyan(t):   return _c("36", t)
def bold(t):   return _c("1",  t)


# ── Discovery shell script injected remotely ───────────────────────────────────
# This single heredoc runs on the target host and prints JSON to stdout.
# It is intentionally written to work on bash 3.x+ (RHEL 6, Debian 7…).
REMOTE_SCRIPT = r"""
#!/bin/bash
set -euo pipefail

# ── helpers ────────────────────────────────────────────────────────────────
cmd_exists()  { command -v "$1" >/dev/null 2>&1; }
safe_run()    { "$@" 2>/dev/null || true; }
ver_of()      { "$1" --version 2>&1 | head -1 | grep -oP '[\d]+\.[\d]+\.?[\d]*' | head -1 || echo ""; }
ver_of_V()    { "$1" -V       2>&1 | head -1 | grep -oP '[\d]+\.[\d]+\.?[\d]*' | head -1 || echo ""; }

# json string escape
json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ── OS information ─────────────────────────────────────────────────────────
OS_TYPE="Linux"
OS_DISTRO=""
OS_VERSION=""
OS_PRETTY=""
KERNEL=""
HOSTNAME_VAL=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_DISTRO="${ID:-}"
    OS_VERSION="${VERSION_ID:-}"
    OS_PRETTY="${PRETTY_NAME:-}"
elif [ -f /etc/redhat-release ]; then
    OS_PRETTY="$(cat /etc/redhat-release)"
    OS_DISTRO="rhel"
    OS_VERSION="$(grep -oP '[\d.]+' /etc/redhat-release | head -1)"
elif [ -f /etc/debian_version ]; then
    OS_DISTRO="debian"
    OS_VERSION="$(cat /etc/debian_version)"
    OS_PRETTY="Debian $OS_VERSION"
fi

KERNEL="$(uname -r 2>/dev/null || echo '')"
HOSTNAME_VAL="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo '')"

# ── CPU / RAM / Disk ───────────────────────────────────────────────────────
CPU_CORES="$(nproc 2>/dev/null || grep -c processor /proc/cpuinfo 2>/dev/null || echo 0)"
RAM_MB="$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
DISK_GB="$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$2); print $2}' || echo 0)"

# ── Runtimes ───────────────────────────────────────────────────────────────
PY3=""
PY2=""
NODE=""
NPM=""
JAVA=""
PHP=""
RUBY=""
GO=""
DOTNET=""
RUST=""
PERL=""
LUA=""
R_VER=""

cmd_exists python3   && PY3="$(ver_of   python3)"
cmd_exists python2   && PY2="$(ver_of   python2)"
cmd_exists python    && [ -z "$PY2" ] && PY2="$(ver_of python)"
cmd_exists node      && NODE="$(ver_of  node)"
cmd_exists nodejs    && [ -z "$NODE" ] && NODE="$(ver_of nodejs)"
cmd_exists npm       && NPM="$(ver_of   npm)"
cmd_exists java      && JAVA="$(java -version 2>&1 | head -1 | grep -oP '[\d]+\.[\d]+\.?[\d]*' | head -1 || echo '')"
cmd_exists php       && PHP="$(ver_of   php)"
cmd_exists ruby      && RUBY="$(ver_of  ruby)"
cmd_exists go        && GO="$(ver_of    go)"
cmd_exists dotnet    && DOTNET="$(ver_of dotnet)"
cmd_exists rustc     && RUST="$(ver_of  rustc)"
cmd_exists perl      && PERL="$(ver_of  perl)"
cmd_exists lua       && LUA="$(ver_of   lua)"
cmd_exists Rscript   && R_VER="$(Rscript --version 2>&1 | grep -oP '[\d]+\.[\d]+\.?[\d]*' | head -1)"

# ── Installed packages ─────────────────────────────────────────────────────
PACKAGES_JSON="[]"
PKG_COUNT=0
if cmd_exists dpkg-query; then
    # Debian / Ubuntu
    PKG_RAW="$(dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null)"
    PKG_COUNT="$(echo "$PKG_RAW" | grep -c . || echo 0)"
    PACKAGES_JSON="$(echo "$PKG_RAW" | awk -F'\t' 'NF==2{
        gsub(/\\/,"\\\\"); gsub(/"/,"\\\"");
        printf "%s{\"name\":\"%s\",\"version\":\"%s\"}", (NR>1?",":""), $1, $2
    }' | sed 's/^/[/' | sed 's/$/]/')"
elif cmd_exists rpm; then
    # RHEL / CentOS / Rocky / Alma / Fedora
    PKG_RAW="$(rpm -qa --queryformat '%{NAME}\t%{VERSION}-%{RELEASE}\n' 2>/dev/null | sort)"
    PKG_COUNT="$(echo "$PKG_RAW" | grep -c . || echo 0)"
    PACKAGES_JSON="$(echo "$PKG_RAW" | awk -F'\t' 'NF==2{
        gsub(/\\/,"\\\\"); gsub(/"/,"\\\"");
        printf "%s{\"name\":\"%s\",\"version\":\"%s\"}", (NR>1?",":""), $1, $2
    }' | sed 's/^/[/' | sed 's/$/]/')"
elif cmd_exists apk; then
    # Alpine Linux
    PKG_RAW="$(apk info -v 2>/dev/null | sort)"
    PKG_COUNT="$(echo "$PKG_RAW" | grep -c . || echo 0)"
    PACKAGES_JSON="$(echo "$PKG_RAW" | awk '{
        match($0, /^([^-]+.*)-([0-9].*)$/, a)
        if (a[1]!="") {
            gsub(/\\/,"\\\\"); gsub(/"/,"\\\"");
            printf "%s{\"name\":\"%s\",\"version\":\"%s\"}", (NR>1?",":""), a[1], a[2]
        }
    }' | sed 's/^/[/' | sed 's/$/]/')"
fi

# ── Systemd services ────────────────────────────────────────────────────────
SVCRUN_JSON="[]"
SVCENABLE_JSON="[]"
SVCFAIL_JSON="[]"

if cmd_exists systemctl; then
    RUNNING="$(systemctl list-units --type=service --state=running --no-pager --plain 2>/dev/null | awk '/\.service/{gsub(/\.service/,"",$1); print $1}')"
    ENABLED="$(systemctl list-unit-files --type=service --state=enabled --no-pager --plain 2>/dev/null | awk '/\.service/{gsub(/\.service/,"",$1); print $1}')"
    FAILED="$(systemctl list-units  --type=service --state=failed  --no-pager --plain 2>/dev/null | awk '/\.service.*failed/{gsub(/\.service/,"",$1); print $1}')"
    SVCRUN_JSON="$(echo "$RUNNING" | awk 'NF{printf "%s\"%s\"", (NR>1?",":""), $1}' | sed 's/^/[/' | sed 's/$/]/')"
    SVCENABLE_JSON="$(echo "$ENABLED" | awk 'NF{printf "%s\"%s\"", (NR>1?",":""), $1}' | sed 's/^/[/' | sed 's/$/]/')"
    SVCFAIL_JSON="$(echo "$FAILED"  | awk 'NF{printf "%s\"%s\"", (NR>1?",":""), $1}' | sed 's/^/[/' | sed 's/$/]/')"
elif [ -f /etc/init.d ]; then
    RUNNING="$(service --status-all 2>&1 | awk '/\[\s+\+\s+\]/{print $NF}')"
    SVCRUN_JSON="$(echo "$RUNNING" | awk 'NF{printf "%s\"%s\"", (NR>1?",":""), $1}' | sed 's/^/[/' | sed 's/$/]/')"
fi

# ── Cron jobs ──────────────────────────────────────────────────────────────
CRON_JSON="[]"
ALL_CRONS=""
for u in root $(cut -d: -f1 /etc/passwd 2>/dev/null | head -20); do
    CTAB="$(crontab -u "$u" -l 2>/dev/null | grep -v '^#' | grep -v '^$' || true)"
    [ -n "$CTAB" ] && ALL_CRONS+="$CTAB"$'\n'
done
for d in /etc/cron.d/* /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/*; do
    [ -f "$d" ] && ALL_CRONS+="$(grep -v '^#' "$d" 2>/dev/null | grep -v '^$' || true)"$'\n'
done
CRON_JSON="$(echo "$ALL_CRONS" | awk 'NF{
    gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\n/,"");
    printf "%s\"%s\"", (NR>1?",":""), $0
}' | sed 's/^/[/' | sed 's/$/]/')"

# ── Open ports ─────────────────────────────────────────────────────────────
PORTS_JSON="[]"
if cmd_exists ss; then
    PORTS_RAW="$(ss -tlnp 2>/dev/null | awk 'NR>1 && /LISTEN/{
        split($4,a,":");
        port=a[length(a)];
        proc="unknown";
        match($6,/users:\(\(\"([^\"]+)\"/,arr);
        if(arr[1]!="") proc=arr[1];
        printf "%s{\"port\":%s,\"proto\":\"tcp\",\"process\":\"%s\"}", (NR>2?",":""), port, proc
    }' | sed 's/^/[/' | sed 's/$/]/')"
    PORTS_JSON="${PORTS_RAW:-[]}"
elif cmd_exists netstat; then
    PORTS_RAW="$(netstat -tlnp 2>/dev/null | awk 'NR>2 && /LISTEN/{
        split($4,a,":");
        port=a[length(a)];
        split($7,b,"/");
        proc=b[2]; if(proc=="")proc="unknown";
        printf "%s{\"port\":%s,\"proto\":\"tcp\",\"process\":\"%s\"}", (NR>3?",":""), port, proc
    }' | sed 's/^/[/' | sed 's/$/]/')"
    PORTS_JSON="${PORTS_RAW:-[]}"
fi

# ── Key environment variables ──────────────────────────────────────────────
KEY_ENV_VARS="PATH JAVA_HOME PYTHONPATH NODE_PATH GOPATH GEM_HOME RAILS_ENV DJANGO_SETTINGS_MODULE APP_ENV ENVIRONMENT RAILS_LOG_LEVEL DATABASE_URL REDIS_URL"
ENV_JSON="{"
FIRST=1
for VAR in $KEY_ENV_VARS; do
    VAL="${!VAR:-}"
    if [ -n "$VAL" ]; then
        ESCAPED="$(json_str "$VAL")"
        [ "$FIRST" -eq 0 ] && ENV_JSON+=","
        ENV_JSON+="\"$VAR\":\"$ESCAPED\""
        FIRST=0
    fi
done
ENV_JSON+="}"

# ── Docker ─────────────────────────────────────────────────────────────────
DOCKER_INSTALLED="false"
DOCKER_VERSION=""
DOCKER_RUNNING=0
DOCKER_IMAGES_JSON="[]"
if cmd_exists docker; then
    DOCKER_INSTALLED="true"
    DOCKER_VERSION="$(safe_run docker version --format '{{.Server.Version}}')"
    DOCKER_RUNNING="$(safe_run docker ps -q | wc -l | tr -d ' ')"
    DOCKER_IMAGES_JSON="$(safe_run docker images --format '{{.Repository}}:{{.Tag}}' | head -20 | awk 'NF{printf "%s\"%s\"", (NR>1?",":""), $1}' | sed 's/^/[/' | sed 's/$/]/')"
fi

# ── Database detection ─────────────────────────────────────────────────────
pg_installed="false"; pg_ver=""; pg_port=5432
mysql_installed="false"; mysql_ver=""; mysql_port=3306
mariadb_installed="false"; mariadb_ver=""
mongo_installed="false"; mongo_ver=""; mongo_port=27017
redis_installed="false"; redis_ver=""; redis_port=6379
elasticsearch_installed="false"; es_ver=""

cmd_exists psql       && pg_installed="true" && pg_ver="$(psql --version 2>&1 | grep -oP '[\d]+\.[\d]+' | head -1)"
cmd_exists mysqld     && mysql_installed="true" && mysql_ver="$(mysqld --version 2>&1 | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1)"
cmd_exists mysql      && [ "$mysql_installed" = "false" ] && mysql_installed="true" && mysql_ver="$(mysql --version 2>&1 | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1)"
cmd_exists mariadbd   && mariadb_installed="true" && mariadb_ver="$(mariadbd --version 2>&1 | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1)"
cmd_exists mongod     && mongo_installed="true"   && mongo_ver="$(mongod --version 2>&1 | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1)"
cmd_exists redis-server && redis_installed="true" && redis_ver="$(redis-server --version 2>&1 | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1)"
cmd_exists elasticsearch && elasticsearch_installed="true" && es_ver="$(elasticsearch --version 2>&1 | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1)"

# ── Web server detection ───────────────────────────────────────────────────
nginx_installed="false"; nginx_ver=""
apache_installed="false"; apache_ver=""
caddy_installed="false"; caddy_ver=""
haproxy_installed="false"; haproxy_ver=""

cmd_exists nginx   && nginx_installed="true"  && nginx_ver="$(nginx -v 2>&1 | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1)"
cmd_exists apache2 && apache_installed="true" && apache_ver="$(apache2 -v 2>&1 | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1)"
cmd_exists httpd   && [ "$apache_installed" = "false" ] && apache_installed="true" && apache_ver="$(httpd -v 2>&1 | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1)"
cmd_exists caddy   && caddy_installed="true"  && caddy_ver="$(ver_of caddy)"
cmd_exists haproxy && haproxy_installed="true" && haproxy_ver="$(ver_of_V haproxy)"

# ── Output JSON ────────────────────────────────────────────────────────────
cat <<JSONEOF
{
  "os_type":    "$(json_str "$OS_TYPE")",
  "os_distro":  "$(json_str "$OS_DISTRO")",
  "os_version": "$(json_str "$OS_VERSION")",
  "os_pretty":  "$(json_str "$OS_PRETTY")",
  "kernel":     "$(json_str "$KERNEL")",
  "hostname":   "$(json_str "$HOSTNAME_VAL")",
  "cpu_cores":  $CPU_CORES,
  "ram_mb":     $RAM_MB,
  "disk_gb":    $DISK_GB,
  "package_count": $PKG_COUNT,
  "packages":   $PACKAGES_JSON,
  "runtimes": {
    "python":  $([ -n "$PY3"    ] && echo "\"$PY3\""    || echo "null"),
    "python2": $([ -n "$PY2"    ] && echo "\"$PY2\""    || echo "null"),
    "node":    $([ -n "$NODE"   ] && echo "\"$NODE\""   || echo "null"),
    "npm":     $([ -n "$NPM"    ] && echo "\"$NPM\""    || echo "null"),
    "java":    $([ -n "$JAVA"   ] && echo "\"$JAVA\""   || echo "null"),
    "php":     $([ -n "$PHP"    ] && echo "\"$PHP\""    || echo "null"),
    "ruby":    $([ -n "$RUBY"   ] && echo "\"$RUBY\""   || echo "null"),
    "go":      $([ -n "$GO"     ] && echo "\"$GO\""     || echo "null"),
    "dotnet":  $([ -n "$DOTNET" ] && echo "\"$DOTNET\"" || echo "null"),
    "rust":    $([ -n "$RUST"   ] && echo "\"$RUST\""   || echo "null"),
    "perl":    $([ -n "$PERL"   ] && echo "\"$PERL\""   || echo "null"),
    "lua":     $([ -n "$LUA"    ] && echo "\"$LUA\""    || echo "null"),
    "r":       $([ -n "$R_VER"  ] && echo "\"$R_VER\""  || echo "null")
  },
  "services": {
    "running": $SVCRUN_JSON,
    "enabled": $SVCENABLE_JSON,
    "failed":  $SVCFAIL_JSON
  },
  "cron_jobs":   $CRON_JSON,
  "open_ports":  $PORTS_JSON,
  "env_vars":    $ENV_JSON,
  "docker": {
    "installed":          $DOCKER_INSTALLED,
    "version":            $([ -n "$DOCKER_VERSION" ] && echo "\"$DOCKER_VERSION\"" || echo "null"),
    "containers_running": $DOCKER_RUNNING,
    "images":             $DOCKER_IMAGES_JSON
  },
  "databases": {
    "postgresql":    {"installed": $pg_installed,              "version": $([ -n "$pg_ver"    ] && echo "\"$pg_ver\""    || echo "null"), "port": $pg_port},
    "mysql":         {"installed": $mysql_installed,           "version": $([ -n "$mysql_ver" ] && echo "\"$mysql_ver\"" || echo "null"), "port": $mysql_port},
    "mariadb":       {"installed": $mariadb_installed,         "version": $([ -n "$mariadb_ver" ] && echo "\"$mariadb_ver\"" || echo "null")},
    "mongodb":       {"installed": $mongo_installed,           "version": $([ -n "$mongo_ver" ] && echo "\"$mongo_ver\"" || echo "null"), "port": $mongo_port},
    "redis":         {"installed": $redis_installed,           "version": $([ -n "$redis_ver" ] && echo "\"$redis_ver\"" || echo "null"), "port": $redis_port},
    "elasticsearch": {"installed": $elasticsearch_installed,   "version": $([ -n "$es_ver"    ] && echo "\"$es_ver\""    || echo "null")}
  },
  "web_servers": {
    "nginx":   {"installed": $nginx_installed,   "version": $([ -n "$nginx_ver"   ] && echo "\"$nginx_ver\""   || echo "null")},
    "apache2": {"installed": $apache_installed,  "version": $([ -n "$apache_ver"  ] && echo "\"$apache_ver\""  || echo "null")},
    "caddy":   {"installed": $caddy_installed,   "version": $([ -n "$caddy_ver"   ] && echo "\"$caddy_ver\""   || echo "null")},
    "haproxy": {"installed": $haproxy_installed, "version": $([ -n "$haproxy_ver" ] && echo "\"$haproxy_ver\"" || echo "null")}
  }
}
JSONEOF
"""


# ── SSH helper ────────────────────────────────────────────────────────────────
def ssh_run(
    ip: str,
    user: str,
    key: str,
    port: int,
    command: str,
    timeout: int = 15,
    jump_host: str = "",
) -> Tuple[int, str, str]:
    """Run a command on a remote host via SSH. Returns (returncode, stdout, stderr)."""
    base_opts = [
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={timeout}",
        "-o", "ServerAliveInterval=10",
        "-o", "ServerAliveCountMax=3",
    ]
    if jump_host:
        base_opts += ["-J", jump_host]

    cmd = (
        ["ssh"] + base_opts +
        ["-i", key, "-p", str(port), f"{user}@{ip}", command]
    )
    try:
        r = subprocess.run(
            cmd, capture_output=True, text=True,
            timeout=timeout + 120,  # give the remote script time to run
        )
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "SSH command timed out"
    except FileNotFoundError:
        return -1, "", "ssh binary not found – install OpenSSH client"


# ── Scan a single host ────────────────────────────────────────────────────────
def scan_host(
    name: str,
    ip: str,
    user: str,
    key: str,
    port: int,
    timeout: int,
    jump_host: str,
    skip_packages: bool,
    skip_ports: bool,
    verbose: bool,
) -> Dict[str, Any]:
    t0 = time.time()
    now_iso = datetime.now(timezone.utc).replace(microsecond=0).isoformat()

    base = {
        "name": name,
        "ip":   ip,
        "ssh_ok": False,
        "os_type": "Unknown",
        "os_distro": "",
        "os_version": "",
        "os_pretty": "",
        "kernel": "",
        "hostname": "",
        "cpu_cores": 0,
        "ram_mb": 0,
        "disk_gb": 0,
        "package_count": 0,
        "packages": [],
        "runtimes": {},
        "services": {"running": [], "enabled": [], "failed": []},
        "cron_jobs": [],
        "open_ports": [],
        "env_vars": {},
        "docker": {"installed": False, "version": None, "containers_running": 0, "images": []},
        "databases": {},
        "web_servers": {},
        "error": None,
        "scan_duration_s": 0.0,
        "scanned_at": now_iso,
    }

    if not ip or ip == "N/A":
        base["error"] = "No IP address available"
        return base

    if verbose:
        print(f"  {cyan('→')} {bold(name)} ({ip}) scanning…", file=sys.stderr)

    # Build the remote script, optionally stripping package collection for speed
    script = REMOTE_SCRIPT
    if skip_packages:
        # Replace dpkg/rpm/apk blocks with a stub
        script = re.sub(
            r'# ── Installed packages.*?# ── Systemd',
            '# packages skipped\nPACKAGES_JSON="[]"\nPKG_COUNT=0\n# ── Systemd',
            script,
            flags=re.DOTALL,
        )
    if skip_ports:
        script = re.sub(
            r'# ── Open ports.*?# ── Key environment',
            '# ports skipped\nPORTS_JSON="[]"\n# ── Key environment',
            script,
            flags=re.DOTALL,
        )

    rc, stdout, stderr = ssh_run(ip, user, key, port, script, timeout, jump_host)

    if rc != 0 or not stdout.strip():
        base["error"] = (stderr or stdout or f"SSH failed (rc={rc})").strip()[:500]
        base["scan_duration_s"] = round(time.time() - t0, 2)
        if verbose:
            print(f"  {red('✗')} {bold(name)}: {base['error']}", file=sys.stderr)
        return base

    try:
        data = json.loads(stdout)
    except json.JSONDecodeError as e:
        # Try to salvage partial JSON
        base["error"] = f"JSON parse error: {e} — raw: {stdout[:300]}"
        base["scan_duration_s"] = round(time.time() - t0, 2)
        return base

    base.update({
        "ssh_ok":        True,
        "os_type":       data.get("os_type", "Linux"),
        "os_distro":     data.get("os_distro", ""),
        "os_version":    data.get("os_version", ""),
        "os_pretty":     data.get("os_pretty", ""),
        "kernel":        data.get("kernel", ""),
        "hostname":      data.get("hostname", ""),
        "cpu_cores":     int(data.get("cpu_cores", 0) or 0),
        "ram_mb":        int(data.get("ram_mb", 0) or 0),
        "disk_gb":       int(data.get("disk_gb", 0) or 0),
        "package_count": int(data.get("package_count", 0) or 0),
        "packages":      data.get("packages", []),
        "runtimes":      data.get("runtimes", {}),
        "services":      data.get("services", {"running": [], "enabled": [], "failed": []}),
        "cron_jobs":     data.get("cron_jobs", []),
        "open_ports":    data.get("open_ports", []),
        "env_vars":      data.get("env_vars", {}),
        "docker":        data.get("docker", {}),
        "databases":     data.get("databases", {}),
        "web_servers":   data.get("web_servers", {}),
        "error":         None,
    })
    base["scan_duration_s"] = round(time.time() - t0, 2)

    if verbose:
        os_lbl = data.get("os_pretty") or f"{data.get('os_distro','?')} {data.get('os_version','')}".strip()
        pkg_c  = data.get("package_count", 0)
        rts    = [k for k, v in data.get("runtimes", {}).items() if v]
        print(
            f"  {green('✓')} {bold(name)}: {os_lbl}  "
            f"({pkg_c} pkgs, runtimes: {', '.join(rts) or 'none'})  "
            f"[{base['scan_duration_s']}s]",
            file=sys.stderr,
        )
    return base


# ── Host parsing ──────────────────────────────────────────────────────────────
def parse_hosts_arg(raw: str) -> List[Tuple[str, str]]:
    """Parse 'name:ip,name:ip,...' or 'ip,ip,...' string into (name, ip) pairs."""
    hosts = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        if ":" in part:
            name, ip = part.split(":", 1)
        else:
            name, ip = part, part
        hosts.append((name.strip(), ip.strip()))
    return hosts


def parse_ip_csv(path: str) -> List[Tuple[str, str]]:
    """Read a CSV with columns 'name'/'server_name' and 'ip'/'ip_address'."""
    hosts = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Be lenient about column names
            name = (
                row.get("name") or row.get("server_name") or
                row.get("Name") or row.get("Server Name") or ""
            ).strip()
            ip = (
                row.get("ip") or row.get("ip_address") or
                row.get("IP") or row.get("IP Address") or
                row.get("external_ip") or row.get("internal_ip") or ""
            ).strip()
            if ip and ip != "N/A":
                hosts.append((name or ip, ip))
    return hosts


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(
        description="Deep-scan servers via SSH: OS, packages, runtimes, environment"
    )
    ap.add_argument("--hosts",    help="'name:ip,name:ip,...'")
    ap.add_argument("--ip-csv",   help="CSV file with name/ip columns")
    ap.add_argument("--user",     default=os.environ.get("SCAN_SSH_USER", "ubuntu"))
    ap.add_argument("--key",      default=os.environ.get("SCAN_SSH_KEY",  str(Path.home() / ".ssh" / "id_rsa")))
    ap.add_argument("--port",     type=int, default=int(os.environ.get("SCAN_SSH_PORT", "22")))
    ap.add_argument("--timeout",  type=int, default=int(os.environ.get("SCAN_SSH_TIMEOUT", "15")))
    ap.add_argument("--jump",     default=os.environ.get("SCAN_JUMP_HOST", ""), help="Optional jump/bastion host user@ip")
    ap.add_argument("--output",   default="-", help="JSON output file (default: stdout)")
    ap.add_argument("--workers",  type=int, default=8, help="Parallel SSH workers")
    ap.add_argument("--no-packages", action="store_true", help="Skip package list (faster)")
    ap.add_argument("--no-ports",    action="store_true", help="Skip open port scan")
    ap.add_argument("--verbose",  "-v", action="store_true")
    args = ap.parse_args()

    # ── Collect hosts ──────────────────────────────────────────────────────
    hosts: List[Tuple[str, str]] = []
    if args.hosts:
        hosts += parse_hosts_arg(args.hosts)
    if args.ip_csv:
        hosts += parse_ip_csv(args.ip_csv)

    if not hosts:
        ap.error("Provide --hosts or --ip-csv with at least one host")

    # ── Validate SSH key ───────────────────────────────────────────────────
    key_path = args.key
    if not Path(key_path).exists():
        print(
            f"{yellow('WARN')} SSH key not found: {key_path}  "
            "(will rely on ssh-agent or default key)",
            file=sys.stderr,
        )
    else:
        # Ensure correct permissions
        os.chmod(key_path, 0o600)

    print(
        f"\n{bold('='*60)}\n"
        f"  Server Deep Scan  —  {len(hosts)} host(s)\n"
        f"  User: {args.user}   Key: {key_path}   Port: {args.port}\n"
        f"{bold('='*60)}\n",
        file=sys.stderr,
    )

    # ── Run scans in parallel ──────────────────────────────────────────────
    results: List[Dict[str, Any]] = []
    scan_kwargs = dict(
        user=args.user,
        key=key_path,
        port=args.port,
        timeout=args.timeout,
        jump_host=args.jump,
        skip_packages=args.no_packages,
        skip_ports=args.no_ports,
        verbose=args.verbose,
    )

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {
            pool.submit(scan_host, name, ip, **scan_kwargs): (name, ip)
            for name, ip in hosts
        }
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())

    # Sort by original order
    order = {(name, ip): i for i, (name, ip) in enumerate(hosts)}
    results.sort(key=lambda r: order.get((r["name"], r["ip"]), 999))

    # ── Summary ───────────────────────────────────────────────────────────
    ok    = sum(1 for r in results if r["ssh_ok"])
    failed = len(results) - ok
    print(
        f"\n{bold('Scan complete')}: {green(str(ok))} succeeded, "
        f"{(red(str(failed)) if failed else '0')} failed\n",
        file=sys.stderr,
    )

    # ── Output ────────────────────────────────────────────────────────────
    json_out = json.dumps(results, indent=2)
    if args.output == "-":
        print(json_out)
    else:
        Path(args.output).write_text(json_out, encoding="utf-8")
        print(f"Results written to: {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
