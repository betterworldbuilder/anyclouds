#!/usr/bin/env bash
# Shared OpenStack + in-guest execution helpers for Method G Simple (sourced only).
# Not an entrypoint — do not run directly.

get_server_ips() {
  local server_id="$1"
  openstack server show "$server_id" -f value -c addresses 2>/dev/null \
    | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
}

get_probe_ip_list() {
  local server_id="$1"
  local prefer raw
  prefer="${OSPC2FLEX_V2_PREFERRED_IP:-}"
  raw=$(get_server_ips "$server_id")
  # SC2259 fix: heredoc overrides pipe for python3 stdin, so pass IPs via env var
  MGS_RAW_IPS="$raw" MGS_PREFER_IP="$prefer" python3 <<'PY'
import os, sys
prefer = (os.environ.get("MGS_PREFER_IP") or "").strip()
raw    = (os.environ.get("MGS_RAW_IPS") or "")
ips_in = [ln.strip() for ln in raw.splitlines() if ln.strip()]
seen, ips = set(), []
for ip in ips_in:
    if ip not in seen:
        seen.add(ip)
        ips.append(ip)

def is_private(ip):
    parts = ip.split(".")
    if len(parts) != 4:
        return True
    try:
        a, b = int(parts[0]), int(parts[1])
    except ValueError:
        return True
    if a == 10:
        return True
    if a == 192 and b == 168:
        return True
    if a == 172 and 16 <= b <= 31:
        return True
    return False

ordered = []

def add(ip):
    if ip and ip not in ordered:
        ordered.append(ip)

if prefer:
    add(prefer)
for ip in ips:
    if not is_private(ip):
        add(ip)
for ip in ips:
    if is_private(ip):
        add(ip)
print("\n".join(ordered))
PY
}

probe_winrm_quick() {
  local host="$1" port="$2"
  [ -n "${WIN_PASSWORD:-}" ] || return 1
  WINRM_PROBE_HOST="$host" WINRM_PROBE_PORT="$port" WINRM_USER="$WIN_USER" WINRM_PASS="$WIN_PASSWORD" python3 - <<'PY' 2>/dev/null
import os, sys
try:
    import winrm
except Exception:
    sys.exit(99)
host = os.environ["WINRM_PROBE_HOST"]
port = os.environ["WINRM_PROBE_PORT"]
user = os.environ["WINRM_USER"]
password = os.environ["WINRM_PASS"]
scheme = "https" if str(port) == "5986" else "http"
try:
    session = winrm.Session(
        f"{scheme}://{host}:{port}/wsman",
        auth=(user, password),
        transport="ntlm",
        server_cert_validation="ignore",
        read_timeout_sec=18,
        operation_timeout_sec=14,
    )
    result = session.run_ps("1")
    sys.exit(result.status_code)
except Exception:
    sys.exit(96)
PY
}

probe_ssh_quick() {
  local host="$1"
  [ -n "${WIN_PASSWORD:-}" ] || return 1
  sshpass -p "$WIN_PASSWORD" ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=14 \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no \
    "$WIN_USER@$host" \
    "powershell -NoProfile -ExecutionPolicy Bypass -Command exit 0" </dev/null >/dev/null 2>&1
}

try_ip_guest_access() {
  local ip="$1" deep_ssh="$2"
  local pr
  probe_winrm_quick "$ip" 5986
  pr=$?
  if [ "$pr" -eq 0 ]; then
    ACCESS_METHOD="winrm_https"
    ACCESS_IP="$ip"
    ACCESS_PORT="5986"
    return 0
  fi
  probe_winrm_quick "$ip" 5985
  pr=$?
  if [ "$pr" -eq 0 ]; then
    ACCESS_METHOD="winrm_http"
    ACCESS_IP="$ip"
    ACCESS_PORT="5985"
    return 0
  fi
  if [ "$deep_ssh" = 1 ] || nc -z -w 4 "$ip" 22 2>/dev/null; then
    if probe_ssh_quick "$ip"; then
      ACCESS_METHOD="ssh"
      ACCESS_IP="$ip"
      ACCESS_PORT="22"
      return 0
    fi
  fi
  return 1
}

run_winrm_ps() {
  local host="$1" port="$2" script="$3"
  WINRM_HOST="$host" WINRM_PORT="$port" WINRM_USER="$WIN_USER" WINRM_PASS="$WIN_PASSWORD" WINRM_SCRIPT="$script" python3 - <<'PY'
import os, sys
try:
    import winrm
except Exception as exc:
    print(f"[WINRM] import failed: {exc}", file=sys.stderr)
    sys.exit(97)
host = os.environ["WINRM_HOST"]
port = os.environ["WINRM_PORT"]
user = os.environ["WINRM_USER"]
password = os.environ["WINRM_PASS"]
script = os.environ["WINRM_SCRIPT"]
scheme = "https" if str(port) == "5986" else "http"
session = winrm.Session(
    f"{scheme}://{host}:{port}/wsman",
    auth=(user, password),
    transport="ntlm",
    server_cert_validation="ignore",
    read_timeout_sec=900,
    operation_timeout_sec=300,
)
result = session.run_ps(script)
out = result.std_out.decode("utf-8", errors="replace")
err = result.std_err.decode("utf-8", errors="replace")
if out:
    print(out, end="")
if err:
    print(err, end="", file=sys.stderr)
sys.exit(result.status_code)
PY
}

run_ssh_ps() {
  local host="$1" script="$2"
  local escaped="${script//\"/\\\"}"
  sshpass -p "$WIN_PASSWORD" ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=30 \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no \
    "$WIN_USER@$host" \
    "powershell -NoProfile -ExecutionPolicy Bypass -Command \"$escaped\""
}

mgs_run_windows_ps() {
  local script="$1"
  case "$ACCESS_METHOD" in
    winrm_http|winrm_https) run_winrm_ps "$ACCESS_IP" "$ACCESS_PORT" "$script" ;;
    ssh) run_ssh_ps "$ACCESS_IP" "$script" ;;
    *) return 1 ;;
  esac
}

mgs_save_console_log() {
  local server_id="$1" out="$2"
  if [ -n "${BACKGROUND_LOG:-}" ]; then
    {
      echo "[CONSOLE] server=$server_id"
      openstack console log show "$server_id" 2>&1 || true
    } >>"$BACKGROUND_LOG"
  else
    openstack console log show "$server_id" >"$out" 2>&1 || true
  fi
}

mgs_wait_for_server_status() {
  local server_id="$1" target="$2" timeout="$3" waited=0 last_report=0 st
  log "[mgs_wait_status] Waiting for server=$server_id target=$target timeout=${timeout}s"
  while [ "$waited" -lt "$timeout" ]; do
    st=$(openstack server show "$server_id" -f value -c status 2>/dev/null | tr -d '\r' || echo "UNKNOWN")
    [ "$st" = "$target" ] && { log "[mgs_wait_status] server=$server_id reached $target after ${waited}s"; return 0; }
    if [ "$st" = "ERROR" ]; then
      log "[mgs_wait_status] server=$server_id entered ERROR state — aborting wait (target=$target waited=${waited}s)"
      { echo "[CONSOLE on SERVER ERROR] server=$server_id waited=${waited}s"; openstack console log show "$server_id" 2>&1 || echo "(console unavailable)"; } >>"${BACKGROUND_LOG:-/dev/stderr}"
      return 1
    fi
    if [ $((waited - last_report)) -ge 30 ]; then
      log "[mgs_wait_status] server=$server_id status=$st waited=${waited}s target=$target"
      last_report=$waited
    fi
    sleep 10
    waited=$((waited + 10))
  done
  st=$(openstack server show "$server_id" -f value -c status 2>/dev/null | tr -d '\r' || echo "UNKNOWN")
  log "[mgs_wait_status] TIMEOUT ${timeout}s: server=$server_id status=$st target=$target"
  { echo "[CONSOLE on STATUS TIMEOUT] server=$server_id"; openstack console log show "$server_id" 2>&1 || echo "(console unavailable)"; } >>"${BACKGROUND_LOG:-/dev/stderr}"
  return 1
}

mgs_attach_floating_ip() {
  local server_id="$1"
  local port_id fip_json fip_id fip row
  log "[mgs_attach_fip] Attaching floating IP to server=$server_id ext_net=${FLEX_EXT_NET:-PUBLICNET}"
  port_id=$(openstack port list --server "$server_id" -f value -c ID -c Status 2>/dev/null | tr -d '\r' | awk '$2=="ACTIVE"{print $1; exit}' || true)
  [ -z "$port_id" ] && port_id=$(openstack port list --server "$server_id" -f value -c ID 2>/dev/null | tr -d '\r' | head -1 || true)
  if [ -z "$port_id" ]; then
    log "[mgs_attach_fip] WARNING: no port found on server=$server_id — skipping FIP"
    return 1
  fi
  log "[mgs_attach_fip] Found port=$port_id; allocating FIP"
  fip_json=$(openstack floating ip create "${FLEX_EXT_NET:-PUBLICNET}" -f json 2>/dev/null || true)
  fip_id=$(printf '%s' "$fip_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("id",""))' 2>/dev/null || true)
  fip=$(printf '%s' "$fip_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("floating_ip_address",""))' 2>/dev/null || true)
  if [ -z "$fip_id" ]; then
    log "[mgs_attach_fip] FIP create failed; trying to reuse existing DOWN FIP"
    row=$(openstack floating ip list --status DOWN -f value -c ID -c "Floating IP Address" 2>/dev/null | head -1 || true)
    fip_id=$(echo "$row" | awk '{print $1}')
    fip=$(echo "$row" | awk '{print $2}')
  fi
  if [ -z "$fip_id" ]; then
    log "[mgs_attach_fip] WARNING: no FIP available — VM will use tenant network IP only"
    return 1
  fi
  openstack floating ip set --port "$port_id" "$fip_id" >>"${BACKGROUND_LOG:-/dev/stderr}" 2>&1 || true
  log "[mgs_attach_fip] FIP attached: $fip (fip_id=$fip_id port=$port_id)"
  printf '%s\n' "$fip"
  return 0
}

mgs_wait_for_windows_guest_access() {
  local server_id="$1" label_prefix="$2" timeout="$3"
  local waited=0 poll=15 last_report=0 console_path="$WORK/logs/${LABEL}.${label_prefix}_console.log"
  local ips ips_line deep_ssh status
  log "[mgs_wait_guest] Waiting for Windows guest access: server=$server_id timeout=${timeout}s"
  while [ "$waited" -lt "$timeout" ]; do
    status=$(openstack server show "$server_id" -f value -c status 2>/dev/null || echo "UNKNOWN")
    if [ "$status" = "ERROR" ]; then
      log "[mgs_wait_guest] server=$server_id entered ERROR — aborting guest access wait"
      { echo "[CONSOLE on SERVER ERROR] server=$server_id"; openstack console log show "$server_id" 2>&1 || echo "(console unavailable)"; } >>"${BACKGROUND_LOG:-/dev/stderr}"
      return 1
    fi
    ACCESS_METHOD=""
    ACCESS_IP=""
    ACCESS_PORT=""
    ips=$(get_probe_ip_list "$server_id")
    deep_ssh=0
    [ "$waited" -ge 60 ] && deep_ssh=1
    ips_line=$(printf '%s' "$ips" | tr '\n' ' ' | xargs)
    if [ -z "$ips_line" ]; then
      [ $((waited - last_report)) -ge 30 ] && log "[mgs_wait_guest] waited=${waited}s: no IPs yet (server_status=$status)"
    else
      [ $((waited - last_report)) -ge 30 ] && log "[mgs_wait_guest] waited=${waited}s: probing [$ips_line] deep_ssh=$deep_ssh server_status=$status"
    fi
    while read -r ip; do
      [ -n "$ip" ] || continue
      if try_ip_guest_access "$ip" "$deep_ssh"; then
        log "[mgs_wait_guest] Guest accessible after ${waited}s: method=$ACCESS_METHOD ip=$ACCESS_IP port=$ACCESS_PORT"
        return 0
      fi
    done <<<"$ips"
    if [ $((waited - last_report)) -ge 60 ]; then
      mgs_save_console_log "$server_id" "$console_path"
      last_report=$waited
    fi
    sleep "$poll"
    waited=$((waited + poll))
  done
  log "[mgs_wait_guest] TIMEOUT ${timeout}s: server=$server_id — guest unreachable; saving console"
  mgs_save_console_log "$server_id" "$console_path"
  { echo "[CONSOLE on GUEST ACCESS TIMEOUT] server=$server_id"; cat "$console_path" 2>/dev/null || echo "(console unavailable)"; } >>"${BACKGROUND_LOG:-/dev/stderr}"
  return 1
}

mgs_prop_equals() {
  local props="$1" key="$2" expected="$3"
  printf '%s\n' "$props" | grep -Eq \
    "${key}[\"']?[[:space:]]*[:=][[:space:]]*[\"']?${expected}([\"']|,|}|[[:space:]]|$)"
}
