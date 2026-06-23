#!/usr/bin/env bash
set -uo pipefail

PUBLIC_NETWORK='PUBLICNET'
PRIVATE_NETWORK='tenant-net'
SUBNET_NAME='tenant-subnet'
SUBNET_CIDR='10.60.0.0/24'
ROUTER_NAME='tenant-router'
SECURITY_GROUP='default'
VOLUME_TYPE='Performance'
KEY_NAME='latopras'
SSH_PUB_KEY=''
FAIL_FAST=1
RESULTS_CSV='/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/flex2flex__DFW-IAD3_20260603_133144-tenant_deploy_results.csv'
RESOURCE_MAP_CSV='/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/flex2flex__DFW-IAD3_20260603_133144-tenant_deploy_resource_map.csv'
STEP_PASS=0
STEP_FAIL=0
STEP_IGNORED=0

printf "%s\n" "step_id,phase,resource_type,resource_name,action,status,exit_code,error" > "$RESULTS_CSV"
printf "%s\n" "source_server_id,source_name,resource_type,flex_name,flex_id,flex_private_ip,flex_floating_ip,status" > "$RESOURCE_MAP_CSV"

append_resource_map() {
  local src_id="$1"
  local src_name="$2"
  local res_type="$3"
  local flex_name="$4"
  local flex_id="$5"
  local flex_priv_ip="$6"
  local flex_float_ip="$7"
  local map_status="$8"
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(csv_escape "$src_id")" \
    "$(csv_escape "$src_name")" \
    "$(csv_escape "$res_type")" \
    "$(csv_escape "$flex_name")" \
    "$(csv_escape "$flex_id")" \
    "$(csv_escape "$flex_priv_ip")" \
    "$(csv_escape "$flex_float_ip")" \
    "$(csv_escape "$map_status")" >> "$RESOURCE_MAP_CSV"
}

csv_escape() {
  local text="${1:-}"
  text=${text//\"/\"\"}
  printf '"%s"' "$text"
}

append_result() {
  local step_id="$1"
  local phase="$2"
  local resource_type="$3"
  local resource_name="$4"
  local action="$5"
  local status="$6"
  local exit_code="$7"
  local error="$8"
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(csv_escape "$step_id")" \
    "$(csv_escape "$phase")" \
    "$(csv_escape "$resource_type")" \
    "$(csv_escape "$resource_name")" \
    "$(csv_escape "$action")" \
    "$(csv_escape "$status")" \
    "$(csv_escape "$exit_code")" \
    "$(csv_escape "$error")" >> "$RESULTS_CSV"
}

run_step() {
  local step_id="$1"
  local phase="$2"
  local resource_type="$3"
  local resource_name="$4"
  local action="$5"
  local reason="$6"
  local script_file output_file exit_code last_error
  script_file=$(mktemp)
  output_file=$(mktemp)
  cat > "$script_file"
  if ( set -euo pipefail; source "$script_file" ) > "$output_file" 2>&1; then
    STEP_PASS=$((STEP_PASS + 1))
    append_result "$step_id" "$phase" "$resource_type" "$resource_name" "$action" "PASS" "0" ""
    cat "$output_file"
  else
    exit_code=$?
    last_error=$(tail -n 1 "$output_file" | tr '\r\n' ' ' || true)
    if [ "$phase" = "load_balancer" ]; then
      STEP_IGNORED=$((STEP_IGNORED + 1))
      append_result "$step_id" "$phase" "$resource_type" "$resource_name" "$action" "IGNORED" "$exit_code" "$last_error"
      echo "Ignoring LB step failure: $step_id phase=$phase type=$resource_type name=$resource_name action=$action reason=$reason" >&2
      cat "$output_file" >&2
    else
      STEP_FAIL=$((STEP_FAIL + 1))
      append_result "$step_id" "$phase" "$resource_type" "$resource_name" "$action" "FAIL" "$exit_code" "$last_error"
      echo "Step failed: $step_id phase=$phase type=$resource_type name=$resource_name action=$action reason=$reason" >&2
      cat "$output_file" >&2
      if [ "$FAIL_FAST" = "1" ]; then
        rm -f "$script_file" "$output_file"
        echo "Fail-fast is enabled; aborting after first failed non-LB step." >&2
        exit "$exit_code"
      fi
    fi
  fi
  rm -f "$script_file" "$output_file"
}

wait_for_volume_available() {
  local volume_name="$1"
  local timeout=900
  local interval=5
  local elapsed=0
  while true; do
    local status
    status=$(openstack volume show -f value -c status "$volume_name" 2>/dev/null || true)
    if [ "$status" = "available" ] || [ "$status" = "in-use" ]; then
      return 0
    fi
    if [ "$status" = "error" ] || [ "$status" = "error_restoring" ] || [ "$status" = "error_extending" ]; then
      echo "Volume $volume_name entered error status: $status" >&2
      return 1
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "Timed out waiting for volume $volume_name to become available" >&2
      return 1
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
}

wait_for_server_active() {
  local server_name="$1"
  local timeout=1800
  local interval=5
  local elapsed=0
  while true; do
    local status
    status=$(openstack server show -f value -c status "$server_name" 2>/dev/null || true)
    if [ "$status" = "ACTIVE" ]; then
      return 0
    fi
    if [ "$status" = "ERROR" ]; then
      echo "Server $server_name entered ERROR state" >&2
      return 1
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "Timed out waiting for server $server_name to become ACTIVE" >&2
      return 1
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
}

wait_for_loadbalancer_active() {
  local lb_name="$1"
  local timeout=1800
  local interval=5
  local elapsed=0
  while true; do
    local status
    status=$(openstack loadbalancer show -f value -c provisioning_status "$lb_name" 2>/dev/null || true)
    if [ "$status" = "ACTIVE" ]; then
      return 0
    fi
    if [ "$status" = "ERROR" ]; then
      echo "Load balancer $lb_name entered ERROR state" >&2
      return 1
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "Timed out waiting for load balancer $lb_name to become ACTIVE" >&2
      return 1
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
}

instance_ip_on_network() {
  local server_name="$1"
  local network_name="$2"
  local ports_line line ip
  ports_line=$(openstack port list --server "$server_name" --network "$network_name" -f value -c "Fixed IP Addresses" 2>/dev/null | head -n 1 || true)
  if [ -n "$ports_line" ]; then
    ip=$(echo "$ports_line" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1 || true)
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
  fi
  line=$(openstack server show "$server_name" -f value -c addresses 2>/dev/null | tr ',' '\n' | sed 's/^ *//g' | grep "^${network_name}=" | head -n 1 || true)
  ip=$(echo "$line" | sed -E 's/^[^=]+=([0-9.]+).*/\1/g')
  echo "$ip"
}

wait_for_instance_ip_on_network() {
  local server_name="$1"
  local network_name="$2"
  local timeout=180
  local interval=5
  local elapsed=0
  while true; do
    local ip
    ip=$(instance_ip_on_network "$server_name" "$network_name")
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      return 1
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
}

server_has_floating_ip() {
  local server_name="$1"
  local out
  out=$(openstack floating ip list --server "$server_name" -f value -c "Floating IP Address" 2>/dev/null || true)
  [[ -n "$(echo "$out" | tr -d '[:space:]')" ]]
}

assign_floating_ip() {
  local server_name="$1"
  local public_network="$2"
  local fip
  fip=$(openstack floating ip list --network "$public_network" --status DOWN -f value -c "Floating IP Address" 2>/dev/null | head -n 1 || true)
  if [ -z "$fip" ]; then
    fip=$(openstack floating ip create "$public_network" -f value -c floating_ip_address 2>/dev/null || true)
  fi
  if [ -z "$fip" ]; then
    echo "Failed to allocate floating IP on network $public_network for $server_name" >&2
    return 1
  fi
  openstack server add floating ip "$server_name" "$fip"
}

attach_volume_with_retry() {
  local server_name="$1"
  local vol_id="$2"
  local device="$3"
  local max_retries=5
  local attempt=0
  local delay=10
  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$((attempt + 1))
    echo "Attach attempt $attempt/$max_retries: server=$server_name vol=$vol_id device=$device"
    if openstack server add volume "$server_name" "$vol_id" --device "$device"; then
      echo "Volume $vol_id successfully attached to $server_name at $device"
      return 0
    fi
    if [ "$attempt" -lt "$max_retries" ]; then
      echo "Attach failed (attempt $attempt/$max_retries); retrying in ${delay}s..." >&2
      sleep "$delay"
    fi
  done
  echo "ERROR: Failed to attach volume $vol_id to $server_name after $max_retries attempts." >&2
  return 1
}

echo "Preflight checks..."
openstack network show "$PUBLIC_NETWORK" >/dev/null
openstack security group show "$SECURITY_GROUP" >/dev/null 2>&1 || openstack security group create "$SECURITY_GROUP" >/dev/null
openstack volume type show "$VOLUME_TYPE" >/dev/null
if [ -n "$KEY_NAME" ]; then
  if [ -n "$SSH_PUB_KEY" ]; then
    openstack keypair show "$KEY_NAME" >/dev/null 2>&1 || {
      echo "Keypair $KEY_NAME not found. Creating it from provided public key..."
      temp_key_file=$(mktemp)
      echo "$SSH_PUB_KEY" > "$temp_key_file"
      openstack keypair create --public-key "$temp_key_file" "$KEY_NAME"
      rm -f "$temp_key_file"
    }
  else
    openstack keypair show "$KEY_NAME" >/dev/null 2>&1 || {
      echo "Keypair $KEY_NAME was not found in target project; continuing without --key-name." >&2
      KEY_NAME=""
    }
  fi
fi

echo "Ensuring tenant network resources..."
openstack network show "$PRIVATE_NETWORK" >/dev/null 2>&1 || openstack network create "$PRIVATE_NETWORK"
openstack subnet show "$SUBNET_NAME" >/dev/null 2>&1 || openstack subnet create --network "$PRIVATE_NETWORK" --subnet-range "$SUBNET_CIDR" "$SUBNET_NAME"
openstack router show "$ROUTER_NAME" >/dev/null 2>&1 || openstack router create "$ROUTER_NAME"
openstack router set --external-gateway "$PUBLIC_NETWORK" "$ROUTER_NAME"
openstack router add subnet "$ROUTER_NAME" "$SUBNET_NAME" >/dev/null 2>&1 || true

echo "Executing deployment steps..."

run_step 'step-0001' 'compute' 'server' 'FlexDFWjumphost' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server FlexDFWjumphost"
openstack server create --flavor 'gp.0.8.32' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'FlexDFWjumphost'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'FlexDFWjumphost' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'FlexDFWjumphost' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'FlexDFWjumphost' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'cc84a892-b01f-4180-86e8-b434d8513d6a' 'FlexDFWjumphost' 'server' 'FlexDFWjumphost' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0002' 'compute' 'floating_ip' 'FlexDFWjumphost' 'assign_floating_ip' 'server=FlexDFWjumphost,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'FlexDFWjumphost'
if server_has_floating_ip 'FlexDFWjumphost'; then
  echo "Server FlexDFWjumphost already has a floating IP; skipping assignment."
else
  assign_floating_ip 'FlexDFWjumphost' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0003' 'compute' 'server' 'Windows-Vol-Helper' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Windows-Vol-Helper"
openstack server create --flavor 'gp.0.4.16' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Windows-Vol-Helper'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Windows-Vol-Helper' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Windows-Vol-Helper' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Windows-Vol-Helper' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'ad73fa8f-c43b-457b-944d-34441b4ce7a9' 'Windows-Vol-Helper' 'server' 'Windows-Vol-Helper' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0004' 'compute' 'floating_ip' 'Windows-Vol-Helper' 'assign_floating_ip' 'server=Windows-Vol-Helper,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'Windows-Vol-Helper'
if server_has_floating_ip 'Windows-Vol-Helper'; then
  echo "Server Windows-Vol-Helper already has a floating IP; skipping assignment."
else
  assign_floating_ip 'Windows-Vol-Helper' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0005' 'compute' 'server' 'ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794' 'create_server_local_boot' 'image=AlmaLinux 9,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794"
openstack server create --flavor 'gp.0.4.4' --image 'AlmaLinux 9' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '187a47b1-da8d-4f87-aec9-6f03801457b5' 'ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794' 'server' 'ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0006' 'compute' 'floating_ip' 'ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794' 'assign_floating_ip' 'server=ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794'
if server_has_floating_ip 'ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794'; then
  echo "Server ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'ospc2flex-Alma9-20260428-0625-r3-f2f-DFW3-r3-f2f-1779927070636232216-203261d8-8031b346-794' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0007' 'compute' 'server' 'ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845' 'create_server_local_boot' 'image=Debian 11,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845"
openstack server create --flavor 'gp.0.4.4' --image 'Debian 11' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '3ddbfc93-3e37-4736-be23-e36dc11daac7' 'ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845' 'server' 'ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0008' 'compute' 'floating_ip' 'ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845' 'assign_floating_ip' 'server=ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845'
if server_has_floating_ip 'ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845'; then
  echo "Server ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'ospc2flex-debian11new-20260427-1342-r3-f2f-DFW3-r3-f2f-1779927071389806333-6415bd62-56855e4d-845' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0009' 'compute' 'server' 'ospc2flex-dbian12-20260425-2221' 'create_server_local_boot' 'image=Debian 12,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server ospc2flex-dbian12-20260425-2221"
openstack server create --flavor 'gp.0.4.4' --image 'Debian 12' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'ospc2flex-dbian12-20260425-2221'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'ospc2flex-dbian12-20260425-2221' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'ospc2flex-dbian12-20260425-2221' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'ospc2flex-dbian12-20260425-2221' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'c120c803-0979-4b02-9ff3-449297926a4a' 'ospc2flex-dbian12-20260425-2221' 'server' 'ospc2flex-dbian12-20260425-2221' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0010' 'compute' 'floating_ip' 'ospc2flex-dbian12-20260425-2221' 'assign_floating_ip' 'server=ospc2flex-dbian12-20260425-2221,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'ospc2flex-dbian12-20260425-2221'
if server_has_floating_ip 'ospc2flex-dbian12-20260425-2221'; then
  echo "Server ospc2flex-dbian12-20260425-2221 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'ospc2flex-dbian12-20260425-2221' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0011' 'compute' 'server' 'ospc2flex-alma8-20260425-2221' 'create_server_local_boot' 'image=AlmaLinux 8,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server ospc2flex-alma8-20260425-2221"
openstack server create --flavor 'gp.0.4.4' --image 'AlmaLinux 8' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'ospc2flex-alma8-20260425-2221'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'ospc2flex-alma8-20260425-2221' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'ospc2flex-alma8-20260425-2221' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'ospc2flex-alma8-20260425-2221' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'b64cf830-f23c-4c3b-987d-f95e6eb10354' 'ospc2flex-alma8-20260425-2221' 'server' 'ospc2flex-alma8-20260425-2221' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0012' 'compute' 'floating_ip' 'ospc2flex-alma8-20260425-2221' 'assign_floating_ip' 'server=ospc2flex-alma8-20260425-2221,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'ospc2flex-alma8-20260425-2221'
if server_has_floating_ip 'ospc2flex-alma8-20260425-2221'; then
  echo "Server ospc2flex-alma8-20260425-2221 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'ospc2flex-alma8-20260425-2221' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0013' 'compute' 'server' 'ospc2flex-rocky8-20260425-2221' 'create_server_local_boot' 'image=Rocky Linux 8,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server ospc2flex-rocky8-20260425-2221"
openstack server create --flavor 'gp.0.4.4' --image 'Rocky Linux 8' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'ospc2flex-rocky8-20260425-2221'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'ospc2flex-rocky8-20260425-2221' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'ospc2flex-rocky8-20260425-2221' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'ospc2flex-rocky8-20260425-2221' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '451dd3e2-990e-4852-bfcd-cd7814b393b2' 'ospc2flex-rocky8-20260425-2221' 'server' 'ospc2flex-rocky8-20260425-2221' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0014' 'compute' 'floating_ip' 'ospc2flex-rocky8-20260425-2221' 'assign_floating_ip' 'server=ospc2flex-rocky8-20260425-2221,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'ospc2flex-rocky8-20260425-2221'
if server_has_floating_ip 'ospc2flex-rocky8-20260425-2221'; then
  echo "Server ospc2flex-rocky8-20260425-2221 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'ospc2flex-rocky8-20260425-2221' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0015' 'compute' 'server' 'ospc2flex-rocky9-20260425-2221' 'create_server_local_boot' 'image=Rocky Linux 9,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server ospc2flex-rocky9-20260425-2221"
openstack server create --flavor 'gp.0.4.4' --image 'Rocky Linux 9' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'ospc2flex-rocky9-20260425-2221'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'ospc2flex-rocky9-20260425-2221' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'ospc2flex-rocky9-20260425-2221' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'ospc2flex-rocky9-20260425-2221' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'c57b2cda-9621-4d2c-bfd3-3ab3eeab520a' 'ospc2flex-rocky9-20260425-2221' 'server' 'ospc2flex-rocky9-20260425-2221' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0016' 'compute' 'floating_ip' 'ospc2flex-rocky9-20260425-2221' 'assign_floating_ip' 'server=ospc2flex-rocky9-20260425-2221,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'ospc2flex-rocky9-20260425-2221'
if server_has_floating_ip 'ospc2flex-rocky9-20260425-2221'; then
  echo "Server ospc2flex-rocky9-20260425-2221 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'ospc2flex-rocky9-20260425-2221' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0017' 'load_balancer' 'load_balancer' 'frontend- Load-Balancer-01' 'create_or_reuse_lb_stack' 'provider=ovn,protocol=HTTP,listener_port=80,algorithm=ROUND_ROBIN' <<'STEP_EOF'
echo "Ensuring load balancer frontend- Load-Balancer-01"
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
openstack loadbalancer show 'frontend- Load-Balancer-01' >/dev/null 2>&1 || openstack loadbalancer create --name 'frontend- Load-Balancer-01' --provider 'ovn' --vip-subnet-id "$VIP_SUBNET_ID"
wait_for_loadbalancer_active 'frontend- Load-Balancer-01'
openstack loadbalancer listener show 'frontend-load-balancer-01-listener' >/dev/null 2>&1 || openstack loadbalancer listener create --name 'frontend-load-balancer-01-listener' --protocol 'HTTP' --protocol-port 80 'frontend- Load-Balancer-01'
wait_for_loadbalancer_active 'frontend- Load-Balancer-01'
openstack loadbalancer pool show 'frontend-load-balancer-01-pool' >/dev/null 2>&1 || openstack loadbalancer pool create --name 'frontend-load-balancer-01-pool' --lb-algorithm 'ROUND_ROBIN' --listener 'frontend-load-balancer-01-listener' --protocol 'HTTP'
wait_for_loadbalancer_active 'frontend- Load-Balancer-01'
STEP_EOF

# Map OSPC LB → FLEX LB
_MAP_LB_ID=$(openstack loadbalancer show -f value -c id 'frontend- Load-Balancer-01' 2>/dev/null || echo "")
_MAP_LB_VIP=$(openstack loadbalancer show -f value -c vip_address 'frontend- Load-Balancer-01' 2>/dev/null || echo "")
append_resource_map '' '' 'load_balancer' 'frontend- Load-Balancer-01' "$_MAP_LB_ID" "$_MAP_LB_VIP" "" 'created'

run_step 'step-0018' 'load_balancer' 'load_balancer' 'backend' 'create_or_reuse_lb_stack' 'provider=ovn,protocol=HTTP,listener_port=80,algorithm=ROUND_ROBIN' <<'STEP_EOF'
echo "Ensuring load balancer backend"
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
openstack loadbalancer show 'backend' >/dev/null 2>&1 || openstack loadbalancer create --name 'backend' --provider 'ovn' --vip-subnet-id "$VIP_SUBNET_ID"
wait_for_loadbalancer_active 'backend'
openstack loadbalancer listener show 'backend-listener' >/dev/null 2>&1 || openstack loadbalancer listener create --name 'backend-listener' --protocol 'HTTP' --protocol-port 80 'backend'
wait_for_loadbalancer_active 'backend'
openstack loadbalancer pool show 'backend-pool' >/dev/null 2>&1 || openstack loadbalancer pool create --name 'backend-pool' --lb-algorithm 'ROUND_ROBIN' --listener 'backend-listener' --protocol 'HTTP'
wait_for_loadbalancer_active 'backend'
STEP_EOF

# Map OSPC LB → FLEX LB
_MAP_LB_ID=$(openstack loadbalancer show -f value -c id 'backend' 2>/dev/null || echo "")
_MAP_LB_VIP=$(openstack loadbalancer show -f value -c vip_address 'backend' 2>/dev/null || echo "")
append_resource_map '' '' 'load_balancer' 'backend' "$_MAP_LB_ID" "$_MAP_LB_VIP" "" 'created'

run_step 'step-0019' 'load_balancer' 'load_balancer' 'u24backend' 'create_or_reuse_lb_stack' 'provider=ovn,protocol=HTTP,listener_port=80,algorithm=ROUND_ROBIN' <<'STEP_EOF'
echo "Ensuring load balancer u24backend"
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
openstack loadbalancer show 'u24backend' >/dev/null 2>&1 || openstack loadbalancer create --name 'u24backend' --provider 'ovn' --vip-subnet-id "$VIP_SUBNET_ID"
wait_for_loadbalancer_active 'u24backend'
openstack loadbalancer listener show 'u24backend-listener' >/dev/null 2>&1 || openstack loadbalancer listener create --name 'u24backend-listener' --protocol 'HTTP' --protocol-port 80 'u24backend'
wait_for_loadbalancer_active 'u24backend'
openstack loadbalancer pool show 'u24backend-pool' >/dev/null 2>&1 || openstack loadbalancer pool create --name 'u24backend-pool' --lb-algorithm 'ROUND_ROBIN' --listener 'u24backend-listener' --protocol 'HTTP'
wait_for_loadbalancer_active 'u24backend'
STEP_EOF

# Map OSPC LB → FLEX LB
_MAP_LB_ID=$(openstack loadbalancer show -f value -c id 'u24backend' 2>/dev/null || echo "")
_MAP_LB_VIP=$(openstack loadbalancer show -f value -c vip_address 'u24backend' 2>/dev/null || echo "")
append_resource_map '' '' 'load_balancer' 'u24backend' "$_MAP_LB_ID" "$_MAP_LB_VIP" "" 'created'

echo "Deployment script finished."
echo "Step results: PASS=$STEP_PASS FAIL=$STEP_FAIL IGNORED=$STEP_IGNORED"
echo "Results CSV: $RESULTS_CSV"
echo "Resource mapping CSV: $RESOURCE_MAP_CSV"
if [ "$STEP_FAIL" -gt 0 ]; then
  echo "One or more deployment steps failed." >&2
  exit 2
fi
