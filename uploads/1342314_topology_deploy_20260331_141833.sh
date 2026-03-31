#!/usr/bin/env bash
set -uo pipefail

echo "Starting topology deployment..."

OS_CMD_TIMEOUT_SEC="${OS_CMD_TIMEOUT_SEC:-120}"
RESOURCE_COLLISION_POLICY="${RESOURCE_COLLISION_POLICY:-reuse}"

run_with_timeout() {
  local timeout_sec="$1"
  shift
  "$@" &
  local pid=$!
  local start_ts now elapsed
  start_ts=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    elapsed=$((now - start_ts))
    if (( elapsed >= timeout_sec )); then
      echo "Timed out after ${timeout_sec}s: $*" >&2
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
  done
  wait "$pid"
}

os() {
  echo "+ openstack $*" >&2
  run_with_timeout "$OS_CMD_TIMEOUT_SEC" openstack "$@"
}

resource_exists() {
  local kind="$1"
  local name="$2"
  case "$kind" in
    network) os network show "$name" >/dev/null 2>&1 ;;
    subnet) os subnet show "$name" >/dev/null 2>&1 ;;
    router) os router show "$name" >/dev/null 2>&1 ;;
    security_group) os security group show "$name" >/dev/null 2>&1 ;;
    instance) os server show "$name" >/dev/null 2>&1 ;;
    volume) os volume show "$name" >/dev/null 2>&1 ;;
    load_balancer) os loadbalancer show "$name" >/dev/null 2>&1 ;;
    listener) os loadbalancer listener show "$name" >/dev/null 2>&1 ;;
    pool) os loadbalancer pool show "$name" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

create_or_reuse() {
  local kind="$1"
  local name="$2"
  shift 2
  if resource_exists "$kind" "$name"; then
    if [[ "$RESOURCE_COLLISION_POLICY" == "fail" ]]; then
      echo "Resource exists and collision policy is fail: $kind $name" >&2
      return 1
    fi
    echo "Reusing existing $kind: $name"
    return 0
  fi
  "$@"
}

wait_for_server_active() {
  local name="$1"
  local attempts="${2:-24}"
  local sleep_sec="${3:-5}"
  local i status
  for ((i=1; i<=attempts; i++)); do
    status=$(os server show "$name" -f value -c status 2>/dev/null || true)
    if [[ "$status" == "ACTIVE" ]]; then
      return 0
    fi
    if [[ "$status" == "ERROR" ]]; then
      echo "Server $name entered ERROR state." >&2
      return 1
    fi
    sleep "$sleep_sec"
  done
  echo "Timed out waiting for server $name to become ACTIVE." >&2
  return 1
}

wait_for_volume_available() {
  local name="$1"
  local attempts="${2:-24}"
  local sleep_sec="${3:-5}"
  local i status
  for ((i=1; i<=attempts; i++)); do
    status=$(os volume show "$name" -f value -c status 2>/dev/null || true)
    if [[ "$status" == "available" ]]; then
      return 0
    fi
    if [[ "$status" == "error" ]]; then
      echo "Volume $name entered error state." >&2
      return 1
    fi
    sleep "$sleep_sec"
  done
  echo "Timed out waiting for volume $name to become available." >&2
  return 1
}

volume_status() {
  local name="$1"
  os volume show "$name" -f value -c status 2>/dev/null || true
}

server_has_volume() {
  local server_name="$1"
  local volume_name="$2"
  local volume_id
  volume_id=$(os volume show "$volume_name" -f value -c id 2>/dev/null || true)
  if [[ -z "$volume_id" ]]; then
    return 1
  fi
  os server volume list "$server_name" -f value -c ID 2>/dev/null | grep -Fx "$volume_id" >/dev/null 2>&1
}

wait_for_loadbalancer_active() {
  local name="$1"
  local attempts="${2:-24}"
  local sleep_sec="${3:-5}"
  local i status
  for ((i=1; i<=attempts; i++)); do
    status=$(os loadbalancer show "$name" -f value -c provisioning_status 2>/dev/null || true)
    if [[ "$status" == "ACTIVE" ]]; then
      return 0
    fi
    if [[ "$status" == "ERROR" ]]; then
      echo "Load balancer $name entered ERROR provisioning state." >&2
      return 1
    fi
    sleep "$sleep_sec"
  done
  echo "Timed out waiting for load balancer $name to become ACTIVE." >&2
  return 1
}

subnet_id_from_name() {
  local subnet_name="$1"
  os subnet show "$subnet_name" -f value -c id 2>/dev/null || true
}

instance_ip_on_network() {
  local server_name="$1"
  local network_name="$2"
  local line ip ports_line
  ports_line=$(os port list --server "$server_name" --network "$network_name" -f value -c "Fixed IP Addresses" 2>/dev/null | head -n 1 || true)
  if [[ -n "$ports_line" ]]; then
    ip=$(echo "$ports_line" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1 || true)
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
  fi
  line=$(os server show "$server_name" -f value -c addresses 2>/dev/null | tr ',' '\n' | sed 's/^ *//g' | grep "^${network_name}=" | head -n 1 || true)
  if [[ -z "$line" ]]; then
    return 0
  fi
  ip=$(echo "$line" | sed -E 's/^[^=]+=([0-9.]+).*/\1/g')
  echo "$ip"
}

wait_for_instance_ip_on_network() {
  local server_name="$1"
  local network_name="$2"
  local attempts="${3:-24}"
  local sleep_sec="${4:-5}"
  local i ip
  for ((i=1; i<=attempts; i++)); do
    ip=$(instance_ip_on_network "$server_name" "$network_name")
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
    sleep "$sleep_sec"
  done
  return 1
}

pool_has_member_ip() {
  local pool_name="$1"
  local addr="$2"
  os loadbalancer member list "$pool_name" -f value -c address 2>/dev/null | grep -Fx "$addr" >/dev/null 2>&1
}

loadbalancer_vip_port_id() {
  local lb_name="$1"
  os loadbalancer show "$lb_name" -f value -c vip_port_id 2>/dev/null || true
}

port_has_floating_ip() {
  local port_id="$1"
  local out
  out=$(os floating ip list --port "$port_id" -f value -c "Floating IP Address" 2>/dev/null || true)
  [[ -n "$(echo "$out" | tr -d '[:space:]')" ]]
}

assign_floating_ip_to_port() {
  local port_id="$1"
  local public_network="$2"
  local fip
  fip=$(os floating ip list --network "$public_network" --status DOWN -f value -c "Floating IP Address" 2>/dev/null | head -n 1 || true)
  if [[ -z "$fip" ]]; then
    fip=$(os floating ip create "$public_network" -f value -c floating_ip_address 2>/dev/null || true)
  fi
  if [[ -z "$fip" ]]; then
    echo "Failed to allocate floating IP on network $public_network for port $port_id." >&2
    return 1
  fi
  os floating ip set --port "$port_id" "$fip" || true
}

server_has_floating_ip() {
  local server_name="$1"
  local out
  out=$(os floating ip list --server "$server_name" -f value -c "Floating IP Address" 2>/dev/null || true)
  [[ -n "$(echo "$out" | tr -d '[:space:]')" ]]
}

assign_floating_ip() {
  local server_name="$1"
  local public_network="$2"
  local fip
  fip=$(os floating ip list --network "$public_network" --status DOWN -f value -c "Floating IP Address" 2>/dev/null | head -n 1 || true)
  if [[ -z "$fip" ]]; then
    fip=$(os floating ip create "$public_network" -f value -c floating_ip_address 2>/dev/null || true)
  fi
  if [[ -z "$fip" ]]; then
    echo "Failed to allocate floating IP on network $public_network for $server_name." >&2
    return 1
  fi
  os server add floating ip "$server_name" "$fip" || true
}

echo "==> PHASE 4: Compute (Windows async first, Linux inline)"
echo "  -> Firing Windows VMs in background (sysprep takes longest)..."
_WIN_PIDS=()
( # Windows VM: Windows Server 2019Re
create_or_reuse instance 'Windows Server 2019Re' os server create --flavor gp.5.2.4 --image 'Windows Server 2019' --network tenant-net --security-group default --password 7VylkwfRhiCR5A 'Windows Server 2019Re'
) &
_WIN_PIDS+=($!)
( # Windows VM: win2019websql2019
create_or_reuse instance win2019websql2019 os server create --flavor gp.5.2.4 --image 'Windows Server 2019 with SQL 2019 Web' --network tenant-net --security-group default --password 5nhdgObwEx5ssy win2019websql2019
) &
_WIN_PIDS+=($!)
( # Windows VM: Windows Server 2016 + SQL Server 2019
create_or_reuse instance 'Windows Server 2016 + SQL Server 2019' os server create --flavor gp.5.2.4 --image 'Windows Server 2016' --network tenant-net --security-group default --password 31rkkj55kJV4Tb 'Windows Server 2016 + SQL Server 2019'
) &
_WIN_PIDS+=($!)
echo "  -> Provisioning Linux VMs..."
create_or_reuse instance ospc-jumpHost os server create --flavor gp.5.2.2 --image 'Ubuntu 24.04' --network tenant-net --security-group default --key-name ospc2flex ospc-jumpHost
create_or_reuse instance u24-postgresl os server create --flavor gp.5.2.2 --image 'Ubuntu 24.04' --network tenant-net --security-group default --key-name ospc2flex u24-postgresl
create_or_reuse instance u24-FrontEnd os server create --flavor gp.5.2.2 --image 'Ubuntu 24.04' --network tenant-net --security-group default --key-name ospc2flex u24-FrontEnd
create_or_reuse instance php-ospc os server create --flavor gp.5.4.4 --image 'Rocky Linux 8' --network tenant-net --security-group default --key-name ospc2flex php-ospc
create_or_reuse instance u24Backend os server create --flavor gp.5.2.2 --image 'Ubuntu 24.04' --network tenant-net --security-group default --key-name ospc2flex u24Backend
create_or_reuse instance 'HA percona 8-02' os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex 'HA percona 8-02'
create_or_reuse instance drupal os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex drupal
create_or_reuse instance HA-Mysql8-01 os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex HA-Mysql8-01
create_or_reuse instance HA-mariaDB-02 os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex HA-mariaDB-02
create_or_reuse instance php-ospc_Database os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex php-ospc_Database
create_or_reuse instance 'HA percona 8-03' os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex 'HA percona 8-03'
create_or_reuse instance HA-mariaDB-03 os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex HA-mariaDB-03
create_or_reuse instance Stack-05_Database os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex Stack-05_Database
create_or_reuse instance sql os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex sql
create_or_reuse instance HA-Mysql8-02 os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex HA-Mysql8-02
create_or_reuse instance HA-mariaDB-01 os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex HA-mariaDB-01
create_or_reuse instance Instance-05-03 os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex Instance-05-03
create_or_reuse instance 'HA percona 8-01' os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex 'HA percona 8-01'
create_or_reuse instance Instance-05-02 os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex Instance-05-02
create_or_reuse instance HA-Mysql8-03 os server create --flavor gp.5.2.2 --image 'Ubuntu 22.04' --network tenant-net --security-group default --key-name ospc2flex HA-Mysql8-03
echo "  -> Waiting for Windows VMs to finish provisioning..."
for _wpid in "${_WIN_PIDS[@]}"; do wait "$_wpid" || true; done
echo "  -> All Windows VMs provisioning complete."
echo "  -> Assigning floating IPs..."
wait_for_server_active 'Windows Server 2019Re' || true
if server_has_floating_ip 'Windows Server 2019Re'; then
  echo "Server Windows Server 2019Re already has a floating IP; skipping."
else
  assign_floating_ip 'Windows Server 2019Re' PUBLICNET
fi
wait_for_server_active win2019websql2019 || true
if server_has_floating_ip win2019websql2019; then
  echo "Server win2019websql2019 already has a floating IP; skipping."
else
  assign_floating_ip win2019websql2019 PUBLICNET
fi
wait_for_server_active 'Windows Server 2016 + SQL Server 2019' || true
if server_has_floating_ip 'Windows Server 2016 + SQL Server 2019'; then
  echo "Server Windows Server 2016 + SQL Server 2019 already has a floating IP; skipping."
else
  assign_floating_ip 'Windows Server 2016 + SQL Server 2019' PUBLICNET
fi
wait_for_server_active ospc-jumpHost || true
if server_has_floating_ip ospc-jumpHost; then
  echo "Server ospc-jumpHost already has a floating IP; skipping."
else
  assign_floating_ip ospc-jumpHost PUBLICNET
fi
wait_for_server_active u24-postgresl || true
if server_has_floating_ip u24-postgresl; then
  echo "Server u24-postgresl already has a floating IP; skipping."
else
  assign_floating_ip u24-postgresl PUBLICNET
fi
wait_for_server_active u24-FrontEnd || true
if server_has_floating_ip u24-FrontEnd; then
  echo "Server u24-FrontEnd already has a floating IP; skipping."
else
  assign_floating_ip u24-FrontEnd PUBLICNET
fi
wait_for_server_active php-ospc || true
if server_has_floating_ip php-ospc; then
  echo "Server php-ospc already has a floating IP; skipping."
else
  assign_floating_ip php-ospc PUBLICNET
fi
wait_for_server_active u24Backend || true
if server_has_floating_ip u24Backend; then
  echo "Server u24Backend already has a floating IP; skipping."
else
  assign_floating_ip u24Backend PUBLICNET
fi

echo "Topology deployment script complete."
