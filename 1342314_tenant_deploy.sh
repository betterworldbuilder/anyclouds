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
FAIL_FAST=0
RESULTS_CSV='/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/1342314_tenant_deploy_results.csv'
RESOURCE_MAP_CSV='/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/1342314_tenant_deploy_resource_map.csv'
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
  local attempt fip
  for attempt in 1 2 3; do
    echo "Floating IP attempt $attempt/3: server=$server_name network=$public_network"
    fip=$(openstack floating ip list --network "$public_network" --status DOWN -f value -c "Floating IP Address" 2>/dev/null | head -n 1 || true)
    if [ -z "$fip" ]; then
      fip=$(openstack floating ip create "$public_network" -f value -c floating_ip_address 2>/dev/null || true)
    fi
    if [ -n "$fip" ] && openstack server add floating ip "$server_name" "$fip"; then
      echo "Floating IP $fip attached to $server_name"
      return 0
    fi
    echo "Floating IP attach failed for $server_name on attempt $attempt/3; retrying..." >&2
    sleep 5
  done
  echo "WARN: Failed to attach floating IP to $server_name after 3 attempts; continuing." >&2
  return 0
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

echo "PHASE 1: Network - ensuring tenant network resources..."
openstack network show "$PRIVATE_NETWORK" >/dev/null 2>&1 || openstack network create "$PRIVATE_NETWORK"
openstack subnet show "$SUBNET_NAME" >/dev/null 2>&1 || openstack subnet create --network "$PRIVATE_NETWORK" --subnet-range "$SUBNET_CIDR" "$SUBNET_NAME"
openstack router show "$ROUTER_NAME" >/dev/null 2>&1 || openstack router create "$ROUTER_NAME"
openstack router set --external-gateway "$PUBLIC_NETWORK" "$ROUTER_NAME"
openstack router add subnet "$ROUTER_NAME" "$SUBNET_NAME" >/dev/null 2>&1 || true

echo "PHASE 4: Compute - executing deployment steps..."

run_step 'step-0001' 'compute' 'server' 'Server-27' 'create_server_local_boot' 'image=AlmaLinux 9,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Server-27"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'AlmaLinux 9' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Server-27'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Server-27' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Server-27' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Server-27' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'a0d77b7e-385e-4768-baa9-29e564a40052' 'Server-27' 'server' 'Server-27' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0002' 'compute' 'floating_ip' 'Server-27' 'assign_floating_ip' 'server=Server-27,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'Server-27'
if server_has_floating_ip 'Server-27'; then
  echo "Server Server-27 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'Server-27' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0003' 'compute' 'server' 'haproxyopsc' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server haproxyopsc"
openstack server create -f value -c id --flavor 'gp.5.4.4' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'haproxyopsc'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'haproxyopsc' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'haproxyopsc' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'haproxyopsc' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '08c9a1a4-55b9-45e0-8b99-eeb5789c4fe2' 'haproxyopsc' 'server' 'haproxyopsc' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0004' 'compute' 'floating_ip' 'haproxyopsc' 'assign_floating_ip' 'server=haproxyopsc,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'haproxyopsc'
if server_has_floating_ip 'haproxyopsc'; then
  echo "Server haproxyopsc already has a floating IP; skipping assignment."
else
  assign_floating_ip 'haproxyopsc' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0005' 'compute' 'server' 'u24clean' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server u24clean"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u24clean'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u24clean' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u24clean' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u24clean' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'de46ca25-136c-4b88-b7a3-40c680962c5c' 'u24clean' 'server' 'u24clean' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0006' 'compute' 'floating_ip' 'u24clean' 'assign_floating_ip' 'server=u24clean,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'u24clean'
if server_has_floating_ip 'u24clean'; then
  echo "Server u24clean already has a floating IP; skipping assignment."
else
  assign_floating_ip 'u24clean' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0007' 'compute' 'server' 'debian12' 'create_server_local_boot' 'image=Debian 12,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server debian12"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Debian 12' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'debian12'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'debian12' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'debian12' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'debian12' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '59065b63-15b9-4099-b5ea-f5ab005f8b2c' 'debian12' 'server' 'debian12' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0008' 'compute' 'floating_ip' 'debian12' 'assign_floating_ip' 'server=debian12,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'debian12'
if server_has_floating_ip 'debian12'; then
  echo "Server debian12 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'debian12' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0009' 'compute' 'server' 'u24 green server' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server u24 green server"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u24 green server'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u24 green server' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u24 green server' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u24 green server' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '13b9ba25-fe39-4169-a1fb-437276a07e45' 'u24 green server' 'server' 'u24 green server' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0010' 'compute' 'floating_ip' 'u24 green server' 'assign_floating_ip' 'server=u24 green server,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'u24 green server'
if server_has_floating_ip 'u24 green server'; then
  echo "Server u24 green server already has a floating IP; skipping assignment."
else
  assign_floating_ip 'u24 green server' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0011' 'compute' 'server' 'u-22' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server u-22"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u-22'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u-22' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u-22' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u-22' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'dd5476a0-6479-4f56-aefd-8b50db956412' 'u-22' 'server' 'u-22' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0012' 'compute' 'floating_ip' 'u-22' 'assign_floating_ip' 'server=u-22,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'u-22'
if server_has_floating_ip 'u-22'; then
  echo "Server u-22 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'u-22' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0013' 'compute' 'server' 'Server-21' 'create_server_local_boot' 'image=AlmaLinux 9,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Server-21"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'AlmaLinux 9' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Server-21'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Server-21' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Server-21' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Server-21' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'bb29c9d8-1b00-4c6f-852f-d07fe4c8b749' 'Server-21' 'server' 'Server-21' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0014' 'compute' 'floating_ip' 'Server-21' 'assign_floating_ip' 'server=Server-21,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'Server-21'
if server_has_floating_ip 'Server-21'; then
  echo "Server Server-21 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'Server-21' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0015' 'compute' 'server' 'musicradio' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server musicradio"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'musicradio'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'musicradio' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'musicradio' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'musicradio' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'faa49462-d7ab-475b-9aa6-5d65a16667e8' 'musicradio' 'server' 'musicradio' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0016' 'compute' 'floating_ip' 'musicradio' 'assign_floating_ip' 'server=musicradio,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'musicradio'
if server_has_floating_ip 'musicradio'; then
  echo "Server musicradio already has a floating IP; skipping assignment."
else
  assign_floating_ip 'musicradio' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0017' 'compute' 'server' 'postgresqlU24' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server postgresqlU24"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'postgresqlU24'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'postgresqlU24' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'postgresqlU24' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'postgresqlU24' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '7beb21aa-2937-43b5-ae77-3d849ba2bd5e' 'postgresqlU24' 'server' 'postgresqlU24' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0018' 'compute' 'floating_ip' 'postgresqlU24' 'assign_floating_ip' 'server=postgresqlU24,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'postgresqlU24'
if server_has_floating_ip 'postgresqlU24'; then
  echo "Server postgresqlU24 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'postgresqlU24' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0019' 'compute' 'server' 'mongo db u24' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server mongo db u24"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'mongo db u24'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'mongo db u24' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'mongo db u24' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'mongo db u24' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '401890d9-81b8-4a8c-9ede-cfe6f4397eeb' 'mongo db u24' 'server' 'mongo db u24' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0020' 'compute' 'floating_ip' 'mongo db u24' 'assign_floating_ip' 'server=mongo db u24,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'mongo db u24'
if server_has_floating_ip 'mongo db u24'; then
  echo "Server mongo db u24 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'mongo db u24' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0021' 'compute' 'server' 'ospcwin2019' 'create_server_boot_from_volume' 'boot_volume_size_gb=80,source_boot_size_gb=50,image_min_disk_gb=80,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating boot volume for ospcwin2019"
openstack volume create --size 80 --type "$VOLUME_TYPE" --image 'Windows Server 2019' 'boot-ospcwin2019'
wait_for_volume_available 'boot-ospcwin2019'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-ospcwin2019')
openstack server create -f value -c id --flavor 'gp.5.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password 'wUVPVr8cxY2tIf' 'ospcwin2019'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'ospcwin2019' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'ospcwin2019' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'ospcwin2019' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '09d88d96-901d-4741-9a61-38bfbd466e84' 'ospcwin2019' 'server' 'ospcwin2019' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0022' 'compute' 'floating_ip' 'ospcwin2019' 'assign_floating_ip' 'server=ospcwin2019,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'ospcwin2019'
if server_has_floating_ip 'ospcwin2019'; then
  echo "Server ospcwin2019 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'ospcwin2019' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0023' 'compute' 'server' 'opscwin2016' 'create_server_local_boot' 'image=Windows Server 2016,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating server opscwin2016"
openstack server create -f value -c id --flavor 'gp.5.2.4' --image 'Windows Server 2016' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password 'Wfas1Yed9ctrIC' 'opscwin2016'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'opscwin2016' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'opscwin2016' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'opscwin2016' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'd69037a7-8441-42e2-b349-30628dbd7ecc' 'opscwin2016' 'server' 'opscwin2016' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0024' 'compute' 'floating_ip' 'opscwin2016' 'assign_floating_ip' 'server=opscwin2016,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'opscwin2016'
if server_has_floating_ip 'opscwin2016'; then
  echo "Server opscwin2016 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'opscwin2016' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0025' 'compute' 'server' 'bigjumpwindowsiad' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server bigjumpwindowsiad"
openstack server create -f value -c id --flavor 'gp.5.16.64' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'bigjumpwindowsiad'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'bigjumpwindowsiad' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'bigjumpwindowsiad' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'bigjumpwindowsiad' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '77fbe978-4b0b-43cd-8722-47a495827d49' 'bigjumpwindowsiad' 'server' 'bigjumpwindowsiad' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0026' 'compute' 'floating_ip' 'bigjumpwindowsiad' 'assign_floating_ip' 'server=bigjumpwindowsiad,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'bigjumpwindowsiad'
if server_has_floating_ip 'bigjumpwindowsiad'; then
  echo "Server bigjumpwindowsiad already has a floating IP; skipping assignment."
else
  assign_floating_ip 'bigjumpwindowsiad' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0027' 'compute' 'server' 'Bigjim-iad' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Bigjim-iad"
openstack server create -f value -c id --flavor 'gp.5.16.64' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Bigjim-iad'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Bigjim-iad' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Bigjim-iad' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Bigjim-iad' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'server' 'Bigjim-iad' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0028' 'compute' 'floating_ip' 'Bigjim-iad' 'assign_floating_ip' 'server=Bigjim-iad,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
if server_has_floating_ip 'Bigjim-iad'; then
  echo "Server Bigjim-iad already has a floating IP; skipping assignment."
else
  assign_floating_ip 'Bigjim-iad' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0029' 'compute' 'server' 'jenkins' 'create_server_local_boot' 'image=Rocky Linux 8,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server jenkins"
openstack server create -f value -c id --flavor 'gp.5.4.4' --image 'Rocky Linux 8' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'jenkins'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'jenkins' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'jenkins' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'jenkins' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '107d8faf-4a18-4d50-88c9-f49042843f18' 'jenkins' 'server' 'jenkins' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0030' 'compute' 'floating_ip' 'jenkins' 'assign_floating_ip' 'server=jenkins,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'jenkins'
if server_has_floating_ip 'jenkins'; then
  echo "Server jenkins already has a floating IP; skipping assignment."
else
  assign_floating_ip 'jenkins' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0031' 'compute' 'server' 'centos7' 'create_server_boot_from_volume' 'boot_volume_size_gb=80,source_boot_size_gb=80,image_min_disk_gb=20,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating boot volume for centos7"
openstack volume create --size 80 --type "$VOLUME_TYPE" --image 'Rocky Linux 8' 'boot-centos7'
wait_for_volume_available 'boot-centos7'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-centos7')
openstack server create -f value -c id --flavor 'gp.5.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'centos7'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'centos7' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'centos7' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'centos7' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '8daf4f80-47bc-41a6-bbcb-cd5974193b41' 'centos7' 'server' 'centos7' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0032' 'compute' 'floating_ip' 'centos7' 'assign_floating_ip' 'server=centos7,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'centos7'
if server_has_floating_ip 'centos7'; then
  echo "Server centos7 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'centos7' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0033' 'compute' 'server' 'win2019' 'create_server_boot_from_volume' 'boot_volume_size_gb=80,source_boot_size_gb=50,image_min_disk_gb=80,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating boot volume for win2019"
openstack volume create --size 80 --type "$VOLUME_TYPE" --image 'Windows Server 2019' 'boot-win2019'
wait_for_volume_available 'boot-win2019'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-win2019')
openstack server create -f value -c id --flavor 'gp.5.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password '5eT19U0kB8sHRs' 'win2019'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'win2019' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'win2019' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'win2019' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'aaabe292-762c-4847-b249-b181ead4737c' 'win2019' 'server' 'win2019' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0034' 'compute' 'floating_ip' 'win2019' 'assign_floating_ip' 'server=win2019,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'win2019'
if server_has_floating_ip 'win2019'; then
  echo "Server win2019 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'win2019' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0035' 'compute' 'server' 'windows2016' 'create_server_local_boot' 'image=Windows Server 2016,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating server windows2016"
openstack server create -f value -c id --flavor 'gp.5.2.4' --image 'Windows Server 2016' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password 'gzxrv87PJ5g3Vy' 'windows2016'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'windows2016' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'windows2016' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'windows2016' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '1850f963-95f6-477f-97da-81e5b404694f' 'windows2016' 'server' 'windows2016' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0036' 'compute' 'floating_ip' 'windows2016' 'assign_floating_ip' 'server=windows2016,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'windows2016'
if server_has_floating_ip 'windows2016'; then
  echo "Server windows2016 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'windows2016' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0037' 'compute' 'server' 'debian11new' 'create_server_local_boot' 'image=Debian 11,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server debian11new"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Debian 11' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'debian11new'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'debian11new' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'debian11new' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'debian11new' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'cd6a356c-62fc-4763-aafc-ca342ec8f923' 'debian11new' 'server' 'debian11new' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0038' 'compute' 'floating_ip' 'debian11new' 'assign_floating_ip' 'server=debian11new,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'debian11new'
if server_has_floating_ip 'debian11new'; then
  echo "Server debian11new already has a floating IP; skipping assignment."
else
  assign_floating_ip 'debian11new' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0039' 'compute' 'server' 'dbian10new' 'create_server_local_boot' 'image=Debian 11,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server dbian10new"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Debian 11' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'dbian10new'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'dbian10new' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'dbian10new' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'dbian10new' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '9262a99e-6bd3-495d-bacd-06a015b29088' 'dbian10new' 'server' 'dbian10new' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0040' 'compute' 'floating_ip' 'dbian10new' 'assign_floating_ip' 'server=dbian10new,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'dbian10new'
if server_has_floating_ip 'dbian10new'; then
  echo "Server dbian10new already has a floating IP; skipping assignment."
else
  assign_floating_ip 'dbian10new' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0041' 'compute' 'server' 'u20' 'create_server_local_boot' 'image=Ubuntu 20.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server u20"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 20.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u20'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u20' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u20' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u20' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'f4dd8084-20c4-40a4-8784-7db8c6c5162a' 'u20' 'server' 'u20' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0042' 'compute' 'floating_ip' 'u20' 'assign_floating_ip' 'server=u20,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'u20'
if server_has_floating_ip 'u20'; then
  echo "Server u20 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'u20' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0043' 'compute' 'server' 'rocky9' 'create_server_local_boot' 'image=Rocky Linux 9,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server rocky9"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Rocky Linux 9' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'rocky9'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'rocky9' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'rocky9' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'rocky9' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '12962165-11ca-498c-8a2f-db69947f9264' 'rocky9' 'server' 'rocky9' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0044' 'compute' 'floating_ip' 'rocky9' 'assign_floating_ip' 'server=rocky9,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'rocky9'
if server_has_floating_ip 'rocky9'; then
  echo "Server rocky9 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'rocky9' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0045' 'compute' 'server' 'alma8' 'create_server_boot_from_volume' 'boot_volume_size_gb=50,source_boot_size_gb=50,image_min_disk_gb=20,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating boot volume for alma8"
openstack volume create --size 50 --type "$VOLUME_TYPE" --image 'AlmaLinux 8' 'boot-alma8'
wait_for_volume_available 'boot-alma8'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-alma8')
openstack server create -f value -c id --flavor 'gp.5.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'alma8'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'alma8' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'alma8' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'alma8' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'f4680994-c54f-473a-8549-b6fb1176088c' 'alma8' 'server' 'alma8' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0046' 'compute' 'floating_ip' 'alma8' 'assign_floating_ip' 'server=alma8,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'alma8'
if server_has_floating_ip 'alma8'; then
  echo "Server alma8 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'alma8' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0047' 'compute' 'server' 'dbian12' 'create_server_boot_from_volume' 'boot_volume_size_gb=50,source_boot_size_gb=50,image_min_disk_gb=20,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating boot volume for dbian12"
openstack volume create --size 50 --type "$VOLUME_TYPE" --image 'Debian 12' 'boot-dbian12'
wait_for_volume_available 'boot-dbian12'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-dbian12')
openstack server create -f value -c id --flavor 'gp.5.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'dbian12'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'dbian12' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'dbian12' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'dbian12' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '8d7309ea-f39c-417b-8f50-c28f76ffd9db' 'dbian12' 'server' 'dbian12' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0048' 'compute' 'floating_ip' 'dbian12' 'assign_floating_ip' 'server=dbian12,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'dbian12'
if server_has_floating_ip 'dbian12'; then
  echo "Server dbian12 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'dbian12' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0049' 'compute' 'server' 'Alma9' 'create_server_local_boot' 'image=AlmaLinux 9,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Alma9"
openstack server create -f value -c id --flavor 'gp.5.4.8' --image 'AlmaLinux 9' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Alma9'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Alma9' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Alma9' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Alma9' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'de2cc03b-b53a-4f32-8b1b-8a3c9d757069' 'Alma9' 'server' 'Alma9' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0050' 'compute' 'floating_ip' 'Alma9' 'assign_floating_ip' 'server=Alma9,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'Alma9'
if server_has_floating_ip 'Alma9'; then
  echo "Server Alma9 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'Alma9' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0051' 'compute' 'server' 'rocky8' 'create_server_local_boot' 'image=Rocky Linux 8,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server rocky8"
openstack server create -f value -c id --flavor 'gp.5.4.8' --image 'Rocky Linux 8' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'rocky8'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'rocky8' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'rocky8' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'rocky8' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '7afcc45d-4080-475e-a771-8ee1f265ef5c' 'rocky8' 'server' 'rocky8' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0052' 'compute' 'floating_ip' 'rocky8' 'assign_floating_ip' 'server=rocky8,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'rocky8'
if server_has_floating_ip 'rocky8'; then
  echo "Server rocky8 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'rocky8' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0053' 'compute' 'server' 'HA percona 8-02' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA percona 8-02"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA percona 8-02'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA percona 8-02' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA percona 8-02' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA percona 8-02' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '0651b25a-9810-41d2-ac00-d30aae53fcdc' 'HA percona 8-02' 'server' 'HA percona 8-02' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0054' 'compute' 'floating_ip' 'HA percona 8-02' 'assign_floating_ip' 'server=HA percona 8-02,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'HA percona 8-02'
if server_has_floating_ip 'HA percona 8-02'; then
  echo "Server HA percona 8-02 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'HA percona 8-02' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0055' 'compute' 'server' 'drupal' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server drupal"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'drupal'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'drupal' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'drupal' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'drupal' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '0e0c1ccf-e8be-4e40-8e04-772307364118' 'drupal' 'server' 'drupal' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0056' 'compute' 'floating_ip' 'drupal' 'assign_floating_ip' 'server=drupal,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'drupal'
if server_has_floating_ip 'drupal'; then
  echo "Server drupal already has a floating IP; skipping assignment."
else
  assign_floating_ip 'drupal' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0057' 'compute' 'server' 'dbaasmariadb' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server dbaasmariadb"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'dbaasmariadb'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'dbaasmariadb' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'dbaasmariadb' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'dbaasmariadb' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '1456f7cd-0080-45e8-9617-cb797ba2ee97' 'dbaasmariadb' 'server' 'dbaasmariadb' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0058' 'compute' 'floating_ip' 'dbaasmariadb' 'assign_floating_ip' 'server=dbaasmariadb,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'dbaasmariadb'
if server_has_floating_ip 'dbaasmariadb'; then
  echo "Server dbaasmariadb already has a floating IP; skipping assignment."
else
  assign_floating_ip 'dbaasmariadb' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0059' 'compute' 'server' 'HA-Mysql8-01' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA-Mysql8-01"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA-Mysql8-01'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA-Mysql8-01' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA-Mysql8-01' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA-Mysql8-01' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '15794001-4db3-41bf-adbd-a00a149d02d6' 'HA-Mysql8-01' 'server' 'HA-Mysql8-01' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0060' 'compute' 'floating_ip' 'HA-Mysql8-01' 'assign_floating_ip' 'server=HA-Mysql8-01,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'HA-Mysql8-01'
if server_has_floating_ip 'HA-Mysql8-01'; then
  echo "Server HA-Mysql8-01 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'HA-Mysql8-01' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0061' 'compute' 'server' 'HA-mariaDB-02' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA-mariaDB-02"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA-mariaDB-02'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA-mariaDB-02' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA-mariaDB-02' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA-mariaDB-02' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '1a36ff59-5a25-4777-a8df-aabf6cf7edb0' 'HA-mariaDB-02' 'server' 'HA-mariaDB-02' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0062' 'compute' 'floating_ip' 'HA-mariaDB-02' 'assign_floating_ip' 'server=HA-mariaDB-02,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'HA-mariaDB-02'
if server_has_floating_ip 'HA-mariaDB-02'; then
  echo "Server HA-mariaDB-02 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'HA-mariaDB-02' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0063' 'compute' 'server' 'drupalphp_Database' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server drupalphp_Database"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'drupalphp_Database'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'drupalphp_Database' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'drupalphp_Database' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'drupalphp_Database' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '2c8023c1-bc51-4a07-96b6-8a075250cc21' 'drupalphp_Database' 'server' 'drupalphp_Database' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0064' 'compute' 'floating_ip' 'drupalphp_Database' 'assign_floating_ip' 'server=drupalphp_Database,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'drupalphp_Database'
if server_has_floating_ip 'drupalphp_Database'; then
  echo "Server drupalphp_Database already has a floating IP; skipping assignment."
else
  assign_floating_ip 'drupalphp_Database' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0065' 'compute' 'server' 'HA percona 8-03' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA percona 8-03"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA percona 8-03'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA percona 8-03' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA percona 8-03' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA percona 8-03' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '3fdbbf29-3a17-4bd3-9c86-0b74baf18624' 'HA percona 8-03' 'server' 'HA percona 8-03' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0066' 'compute' 'floating_ip' 'HA percona 8-03' 'assign_floating_ip' 'server=HA percona 8-03,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'HA percona 8-03'
if server_has_floating_ip 'HA percona 8-03'; then
  echo "Server HA percona 8-03 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'HA percona 8-03' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0067' 'compute' 'server' 'HA-mariaDB-03' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA-mariaDB-03"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA-mariaDB-03'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA-mariaDB-03' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA-mariaDB-03' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA-mariaDB-03' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '40a3b380-61cf-4a69-a474-d8f68d81c750' 'HA-mariaDB-03' 'server' 'HA-mariaDB-03' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0068' 'compute' 'floating_ip' 'HA-mariaDB-03' 'assign_floating_ip' 'server=HA-mariaDB-03,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'HA-mariaDB-03'
if server_has_floating_ip 'HA-mariaDB-03'; then
  echo "Server HA-mariaDB-03 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'HA-mariaDB-03' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0069' 'compute' 'server' 'lamp_Database' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server lamp_Database"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'lamp_Database'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'lamp_Database' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'lamp_Database' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'lamp_Database' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '4579ebd6-0409-4ba3-86dc-83e94629dd6d' 'lamp_Database' 'server' 'lamp_Database' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0070' 'compute' 'floating_ip' 'lamp_Database' 'assign_floating_ip' 'server=lamp_Database,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'lamp_Database'
if server_has_floating_ip 'lamp_Database'; then
  echo "Server lamp_Database already has a floating IP; skipping assignment."
else
  assign_floating_ip 'lamp_Database' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0071' 'compute' 'server' 'HAdbaasSql-03' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HAdbaasSql-03"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HAdbaasSql-03'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HAdbaasSql-03' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HAdbaasSql-03' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HAdbaasSql-03' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '4988843f-7f1b-4a12-9a97-a5fefc011970' 'HAdbaasSql-03' 'server' 'HAdbaasSql-03' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0072' 'compute' 'floating_ip' 'HAdbaasSql-03' 'assign_floating_ip' 'server=HAdbaasSql-03,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'HAdbaasSql-03'
if server_has_floating_ip 'HAdbaasSql-03'; then
  echo "Server HAdbaasSql-03 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'HAdbaasSql-03' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0073' 'compute' 'server' 'Stack-05_Database' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Stack-05_Database"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Stack-05_Database'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Stack-05_Database' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Stack-05_Database' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Stack-05_Database' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '4d0ced3c-c5b5-4cf3-aa17-729cd74ce1e5' 'Stack-05_Database' 'server' 'Stack-05_Database' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0074' 'compute' 'floating_ip' 'Stack-05_Database' 'assign_floating_ip' 'server=Stack-05_Database,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'Stack-05_Database'
if server_has_floating_ip 'Stack-05_Database'; then
  echo "Server Stack-05_Database already has a floating IP; skipping assignment."
else
  assign_floating_ip 'Stack-05_Database' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0075' 'compute' 'server' 'HAmysql-01' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HAmysql-01"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HAmysql-01'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HAmysql-01' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HAmysql-01' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HAmysql-01' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '4d3ba66a-081c-411a-ba88-c5d3eae98644' 'HAmysql-01' 'server' 'HAmysql-01' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0076' 'compute' 'floating_ip' 'HAmysql-01' 'assign_floating_ip' 'server=HAmysql-01,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'HAmysql-01'
if server_has_floating_ip 'HAmysql-01'; then
  echo "Server HAmysql-01 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'HAmysql-01' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0077' 'compute' 'server' 'mariad1' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server mariad1"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'mariad1'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'mariad1' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'mariad1' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'mariad1' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '4ddfa7e3-7dc4-46b0-9dcb-35ff8d85a92e' 'mariad1' 'server' 'mariad1' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0078' 'compute' 'floating_ip' 'mariad1' 'assign_floating_ip' 'server=mariad1,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'mariad1'
if server_has_floating_ip 'mariad1'; then
  echo "Server mariad1 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'mariad1' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0079' 'compute' 'server' 'hadbaas-vip-03' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server hadbaas-vip-03"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'hadbaas-vip-03'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'hadbaas-vip-03' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'hadbaas-vip-03' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'hadbaas-vip-03' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '4e15dd55-7c7c-4d08-9d2e-055fb7060d59' 'hadbaas-vip-03' 'server' 'hadbaas-vip-03' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0080' 'compute' 'floating_ip' 'hadbaas-vip-03' 'assign_floating_ip' 'server=hadbaas-vip-03,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'hadbaas-vip-03'
if server_has_floating_ip 'hadbaas-vip-03'; then
  echo "Server hadbaas-vip-03 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'hadbaas-vip-03' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0081' 'compute' 'server' 'Instance-21' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Instance-21"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Instance-21'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Instance-21' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Instance-21' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Instance-21' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '53ed4836-2719-4058-b084-5ca6cffbf2b4' 'Instance-21' 'server' 'Instance-21' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0082' 'compute' 'floating_ip' 'Instance-21' 'assign_floating_ip' 'server=Instance-21,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'Instance-21'
if server_has_floating_ip 'Instance-21'; then
  echo "Server Instance-21 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'Instance-21' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0083' 'compute' 'server' 'mysql8instance' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server mysql8instance"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'mysql8instance'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'mysql8instance' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'mysql8instance' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'mysql8instance' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '5800f484-5abf-4ba3-97ad-fdf2645e9e07' 'mysql8instance' 'server' 'mysql8instance' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0084' 'compute' 'floating_ip' 'mysql8instance' 'assign_floating_ip' 'server=mysql8instance,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'mysql8instance'
if server_has_floating_ip 'mysql8instance'; then
  echo "Server mysql8instance already has a floating IP; skipping assignment."
else
  assign_floating_ip 'mysql8instance' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0085' 'compute' 'server' 'sql' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server sql"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'sql'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'sql' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'sql' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'sql' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '5b05ea2c-c452-4069-97f3-f2bc80e7182f' 'sql' 'server' 'sql' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0086' 'compute' 'floating_ip' 'sql' 'assign_floating_ip' 'server=sql,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'sql'
if server_has_floating_ip 'sql'; then
  echo "Server sql already has a floating IP; skipping assignment."
else
  assign_floating_ip 'sql' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0087' 'compute' 'server' 'Mariadb' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Mariadb"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Mariadb'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Mariadb' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Mariadb' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Mariadb' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '5c916b27-aa26-4a6e-a488-64d6386b90c9' 'Mariadb' 'server' 'Mariadb' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0088' 'compute' 'floating_ip' 'Mariadb' 'assign_floating_ip' 'server=Mariadb,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'Mariadb'
if server_has_floating_ip 'Mariadb'; then
  echo "Server Mariadb already has a floating IP; skipping assignment."
else
  assign_floating_ip 'Mariadb' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0089' 'compute' 'server' 'hadbaas-vip-01' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server hadbaas-vip-01"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'hadbaas-vip-01'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'hadbaas-vip-01' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'hadbaas-vip-01' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'hadbaas-vip-01' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '6f7cf30a-1833-49d1-a500-059820a40333' 'hadbaas-vip-01' 'server' 'hadbaas-vip-01' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0090' 'compute' 'floating_ip' 'hadbaas-vip-01' 'assign_floating_ip' 'server=hadbaas-vip-01,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'hadbaas-vip-01'
if server_has_floating_ip 'hadbaas-vip-01'; then
  echo "Server hadbaas-vip-01 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'hadbaas-vip-01' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0091' 'compute' 'server' 'Instance-20' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Instance-20"
openstack server create -f value -c id --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Instance-20'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Instance-20' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Instance-20' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Instance-20' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '7a350577-6f75-48fc-aa8a-fa08a7a38664' 'Instance-20' 'server' 'Instance-20' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0092' 'compute' 'floating_ip' 'Instance-20' 'assign_floating_ip' 'server=Instance-20,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'Instance-20'
if server_has_floating_ip 'Instance-20'; then
  echo "Server Instance-20 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'Instance-20' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0093' 'load_balancer' 'load_balancer' 'frontend- Load-Balancer-01' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=HTTP,listener_port=80,algorithm=WEIGHTED_LEAST_CONNECTIONS' <<'STEP_EOF'
echo "Ensuring load balancer frontend- Load-Balancer-01"
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
openstack loadbalancer show 'frontend- Load-Balancer-01' >/dev/null 2>&1 || openstack loadbalancer create --name 'frontend- Load-Balancer-01' --provider 'amphora' --vip-subnet-id "$VIP_SUBNET_ID"
wait_for_loadbalancer_active 'frontend- Load-Balancer-01'
openstack loadbalancer listener show 'frontend-load-balancer-01-listener' >/dev/null 2>&1 || openstack loadbalancer listener create --name 'frontend-load-balancer-01-listener' --protocol 'HTTP' --protocol-port 80 'frontend- Load-Balancer-01'
wait_for_loadbalancer_active 'frontend- Load-Balancer-01'
openstack loadbalancer pool show 'frontend-load-balancer-01-pool' >/dev/null 2>&1 || openstack loadbalancer pool create --name 'frontend-load-balancer-01-pool' --lb-algorithm 'WEIGHTED_LEAST_CONNECTIONS' --listener 'frontend-load-balancer-01-listener' --protocol 'HTTP'
wait_for_loadbalancer_active 'frontend- Load-Balancer-01'
STEP_EOF

# Map OSPC LB → FLEX LB
_MAP_LB_ID=$(openstack loadbalancer show -f value -c id 'frontend- Load-Balancer-01' 2>/dev/null || echo "")
_MAP_LB_VIP=$(openstack loadbalancer show -f value -c vip_address 'frontend- Load-Balancer-01' 2>/dev/null || echo "")
append_resource_map '' '' 'load_balancer' 'frontend- Load-Balancer-01' "$_MAP_LB_ID" "$_MAP_LB_VIP" "" 'created'

run_step 'step-0094' 'load_balancer' 'load_balancer' 'u24backend' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=HTTP,listener_port=80,algorithm=LEAST_CONNECTIONS' <<'STEP_EOF'
echo "Ensuring load balancer u24backend"
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
openstack loadbalancer show 'u24backend' >/dev/null 2>&1 || openstack loadbalancer create --name 'u24backend' --provider 'amphora' --vip-subnet-id "$VIP_SUBNET_ID"
wait_for_loadbalancer_active 'u24backend'
openstack loadbalancer listener show 'u24backend-listener' >/dev/null 2>&1 || openstack loadbalancer listener create --name 'u24backend-listener' --protocol 'HTTP' --protocol-port 80 'u24backend'
wait_for_loadbalancer_active 'u24backend'
openstack loadbalancer pool show 'u24backend-pool' >/dev/null 2>&1 || openstack loadbalancer pool create --name 'u24backend-pool' --lb-algorithm 'LEAST_CONNECTIONS' --listener 'u24backend-listener' --protocol 'HTTP'
wait_for_loadbalancer_active 'u24backend'
STEP_EOF

# Map OSPC LB → FLEX LB
_MAP_LB_ID=$(openstack loadbalancer show -f value -c id 'u24backend' 2>/dev/null || echo "")
_MAP_LB_VIP=$(openstack loadbalancer show -f value -c vip_address 'u24backend' 2>/dev/null || echo "")
append_resource_map '' '' 'load_balancer' 'u24backend' "$_MAP_LB_ID" "$_MAP_LB_VIP" "" 'created'

run_step 'step-0095' 'load_balancer' 'load_balancer_member' 'Alma9' 'ensure_lb_pool_member' 'lb=u24backend,pool=u24backend-pool,member_port=80' <<'STEP_EOF'
wait_for_server_active 'Alma9'
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
MEMBER_IP=$(wait_for_instance_ip_on_network 'Alma9' "$PRIVATE_NETWORK" || true)
if [ -n "$MEMBER_IP" ]; then
  if openstack loadbalancer member list 'u24backend-pool' -f value -c address 2>/dev/null | grep -Fx "$MEMBER_IP" >/dev/null 2>&1; then
    echo "LB member already exists for $MEMBER_IP on pool u24backend-pool"
  else
    openstack loadbalancer member create --subnet-id "$VIP_SUBNET_ID" --address "$MEMBER_IP" --protocol-port 80 'u24backend-pool' || true
  fi
else
  echo "Could not resolve member IP for Alma9 on $PRIVATE_NETWORK; skipping member add." >&2
fi
STEP_EOF

run_step 'step-0096' 'load_balancer' 'load_balancer' 'DB_loadbalancer MYSQL' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=MYSQL,listener_port=3306,algorithm=ROUND_ROBIN' <<'STEP_EOF'
echo "Ensuring load balancer DB_loadbalancer MYSQL"
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
openstack loadbalancer show 'DB_loadbalancer MYSQL' >/dev/null 2>&1 || openstack loadbalancer create --name 'DB_loadbalancer MYSQL' --provider 'amphora' --vip-subnet-id "$VIP_SUBNET_ID"
wait_for_loadbalancer_active 'DB_loadbalancer MYSQL'
openstack loadbalancer listener show 'db-loadbalancer-mysql-listener' >/dev/null 2>&1 || openstack loadbalancer listener create --name 'db-loadbalancer-mysql-listener' --protocol 'MYSQL' --protocol-port 3306 'DB_loadbalancer MYSQL'
wait_for_loadbalancer_active 'DB_loadbalancer MYSQL'
openstack loadbalancer pool show 'db-loadbalancer-mysql-pool' >/dev/null 2>&1 || openstack loadbalancer pool create --name 'db-loadbalancer-mysql-pool' --lb-algorithm 'ROUND_ROBIN' --listener 'db-loadbalancer-mysql-listener' --protocol 'MYSQL'
wait_for_loadbalancer_active 'DB_loadbalancer MYSQL'
STEP_EOF

# Map OSPC LB → FLEX LB
_MAP_LB_ID=$(openstack loadbalancer show -f value -c id 'DB_loadbalancer MYSQL' 2>/dev/null || echo "")
_MAP_LB_VIP=$(openstack loadbalancer show -f value -c vip_address 'DB_loadbalancer MYSQL' 2>/dev/null || echo "")
append_resource_map '' '' 'load_balancer' 'DB_loadbalancer MYSQL' "$_MAP_LB_ID" "$_MAP_LB_VIP" "" 'created'

run_step 'step-0097' 'load_balancer' 'load_balancer' 'LBmariaDB' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=MYSQL,listener_port=3306,algorithm=LEAST_CONNECTIONS' <<'STEP_EOF'
echo "Ensuring load balancer LBmariaDB"
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
openstack loadbalancer show 'LBmariaDB' >/dev/null 2>&1 || openstack loadbalancer create --name 'LBmariaDB' --provider 'amphora' --vip-subnet-id "$VIP_SUBNET_ID"
wait_for_loadbalancer_active 'LBmariaDB'
openstack loadbalancer listener show 'lbmariadb-listener' >/dev/null 2>&1 || openstack loadbalancer listener create --name 'lbmariadb-listener' --protocol 'MYSQL' --protocol-port 3306 'LBmariaDB'
wait_for_loadbalancer_active 'LBmariaDB'
openstack loadbalancer pool show 'lbmariadb-pool' >/dev/null 2>&1 || openstack loadbalancer pool create --name 'lbmariadb-pool' --lb-algorithm 'LEAST_CONNECTIONS' --listener 'lbmariadb-listener' --protocol 'MYSQL'
wait_for_loadbalancer_active 'LBmariaDB'
STEP_EOF

# Map OSPC LB → FLEX LB
_MAP_LB_ID=$(openstack loadbalancer show -f value -c id 'LBmariaDB' 2>/dev/null || echo "")
_MAP_LB_VIP=$(openstack loadbalancer show -f value -c vip_address 'LBmariaDB' 2>/dev/null || echo "")
append_resource_map '' '' 'load_balancer' 'LBmariaDB' "$_MAP_LB_ID" "$_MAP_LB_VIP" "" 'created'

run_step 'step-0098' 'load_balancer' 'load_balancer' 'perconaLB' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=MYSQL,listener_port=3306,algorithm=LEAST_CONNECTIONS' <<'STEP_EOF'
echo "Ensuring load balancer perconaLB"
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
openstack loadbalancer show 'perconaLB' >/dev/null 2>&1 || openstack loadbalancer create --name 'perconaLB' --provider 'amphora' --vip-subnet-id "$VIP_SUBNET_ID"
wait_for_loadbalancer_active 'perconaLB'
openstack loadbalancer listener show 'perconalb-listener' >/dev/null 2>&1 || openstack loadbalancer listener create --name 'perconalb-listener' --protocol 'MYSQL' --protocol-port 3306 'perconaLB'
wait_for_loadbalancer_active 'perconaLB'
openstack loadbalancer pool show 'perconalb-pool' >/dev/null 2>&1 || openstack loadbalancer pool create --name 'perconalb-pool' --lb-algorithm 'LEAST_CONNECTIONS' --listener 'perconalb-listener' --protocol 'MYSQL'
wait_for_loadbalancer_active 'perconaLB'
STEP_EOF

# Map OSPC LB → FLEX LB
_MAP_LB_ID=$(openstack loadbalancer show -f value -c id 'perconaLB' 2>/dev/null || echo "")
_MAP_LB_VIP=$(openstack loadbalancer show -f value -c vip_address 'perconaLB' 2>/dev/null || echo "")
append_resource_map '' '' 'load_balancer' 'perconaLB' "$_MAP_LB_ID" "$_MAP_LB_VIP" "" 'created'

run_step 'step-0099' 'storage' 'volume' 'u24-green-server-data-1' 'create_and_attach_volume' 'server=u24 green server,device=/dev/vdb,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'u24 green server'
echo "Creating data volume u24-green-server-data-1 for instance u24 green server"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'u24-green-server-data-1'
wait_for_volume_available 'u24-green-server-data-1'
VOL_ID=$(openstack volume show -f value -c id 'u24-green-server-data-1')
echo "Attaching volume u24-green-server-data-1 to instance u24 green server at /dev/vdb (max 5 retries)"
attach_volume_with_retry 'u24 green server' "$VOL_ID" '/dev/vdb'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'u24-green-server-data-1' 2>/dev/null || echo "")
append_resource_map '13b9ba25-fe39-4169-a1fb-437276a07e45' 'u24 green server' 'volume' 'u24-green-server-data-1' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0100' 'storage' 'volume' 'u24-green-server-data-2' 'create_and_attach_volume' 'server=u24 green server,device=/dev/vdc,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'u24 green server'
echo "Creating data volume u24-green-server-data-2 for instance u24 green server"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'u24-green-server-data-2'
wait_for_volume_available 'u24-green-server-data-2'
VOL_ID=$(openstack volume show -f value -c id 'u24-green-server-data-2')
echo "Attaching volume u24-green-server-data-2 to instance u24 green server at /dev/vdc (max 5 retries)"
attach_volume_with_retry 'u24 green server' "$VOL_ID" '/dev/vdc'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'u24-green-server-data-2' 2>/dev/null || echo "")
append_resource_map '13b9ba25-fe39-4169-a1fb-437276a07e45' 'u24 green server' 'volume' 'u24-green-server-data-2' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0101' 'storage' 'volume' 'postgresqlu24-data-1' 'create_and_attach_volume' 'server=postgresqlU24,device=/dev/vdc,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'postgresqlU24'
echo "Creating data volume postgresqlu24-data-1 for instance postgresqlU24"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'postgresqlu24-data-1'
wait_for_volume_available 'postgresqlu24-data-1'
VOL_ID=$(openstack volume show -f value -c id 'postgresqlu24-data-1')
echo "Attaching volume postgresqlu24-data-1 to instance postgresqlU24 at /dev/vdc (max 5 retries)"
attach_volume_with_retry 'postgresqlU24' "$VOL_ID" '/dev/vdc'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'postgresqlu24-data-1' 2>/dev/null || echo "")
append_resource_map '7beb21aa-2937-43b5-ae77-3d849ba2bd5e' 'postgresqlU24' 'volume' 'postgresqlu24-data-1' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0102' 'storage' 'volume' 'bigjumpwindowsiad-data-1' 'create_and_attach_volume' 'server=bigjumpwindowsiad,device=/dev/vdb,size_gb=500' <<'STEP_EOF'
wait_for_server_active 'bigjumpwindowsiad'
echo "Creating data volume bigjumpwindowsiad-data-1 for instance bigjumpwindowsiad"
openstack volume create --size 500 --type "$VOLUME_TYPE" 'bigjumpwindowsiad-data-1'
wait_for_volume_available 'bigjumpwindowsiad-data-1'
VOL_ID=$(openstack volume show -f value -c id 'bigjumpwindowsiad-data-1')
echo "Attaching volume bigjumpwindowsiad-data-1 to instance bigjumpwindowsiad at /dev/vdb (max 5 retries)"
attach_volume_with_retry 'bigjumpwindowsiad' "$VOL_ID" '/dev/vdb'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjumpwindowsiad-data-1' 2>/dev/null || echo "")
append_resource_map '77fbe978-4b0b-43cd-8722-47a495827d49' 'bigjumpwindowsiad' 'volume' 'bigjumpwindowsiad-data-1' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0103' 'storage' 'volume' 'bigjim-iad-data-1' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdbc,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-1 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-1'
wait_for_volume_available 'bigjim-iad-data-1'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-1')
echo "Attaching volume bigjim-iad-data-1 to instance Bigjim-iad at /dev/vdbc (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdbc'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-1' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-1' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0104' 'storage' 'volume' 'bigjim-iad-data-2' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vday,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-2 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-2'
wait_for_volume_available 'bigjim-iad-data-2'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-2')
echo "Attaching volume bigjim-iad-data-2 to instance Bigjim-iad at /dev/vday (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vday'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-2' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-2' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0105' 'storage' 'volume' 'bigjim-iad-data-3' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdba,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-3 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-3'
wait_for_volume_available 'bigjim-iad-data-3'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-3')
echo "Attaching volume bigjim-iad-data-3 to instance Bigjim-iad at /dev/vdba (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdba'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-3' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-3' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0106' 'storage' 'volume' 'bigjim-iad-data-4' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdaz,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-4 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-4'
wait_for_volume_available 'bigjim-iad-data-4'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-4')
echo "Attaching volume bigjim-iad-data-4 to instance Bigjim-iad at /dev/vdaz (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdaz'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-4' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-4' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0107' 'storage' 'volume' 'bigjim-iad-data-5' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdax,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-5 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-5'
wait_for_volume_available 'bigjim-iad-data-5'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-5')
echo "Attaching volume bigjim-iad-data-5 to instance Bigjim-iad at /dev/vdax (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdax'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-5' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-5' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0108' 'storage' 'volume' 'bigjim-iad-data-6' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdaw,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-6 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-6'
wait_for_volume_available 'bigjim-iad-data-6'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-6')
echo "Attaching volume bigjim-iad-data-6 to instance Bigjim-iad at /dev/vdaw (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdaw'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-6' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-6' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0109' 'storage' 'volume' 'bigjim-iad-data-7' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdat,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-7 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-7'
wait_for_volume_available 'bigjim-iad-data-7'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-7')
echo "Attaching volume bigjim-iad-data-7 to instance Bigjim-iad at /dev/vdat (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdat'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-7' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-7' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0110' 'storage' 'volume' 'bigjim-iad-data-8' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdav,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-8 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-8'
wait_for_volume_available 'bigjim-iad-data-8'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-8')
echo "Attaching volume bigjim-iad-data-8 to instance Bigjim-iad at /dev/vdav (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdav'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-8' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-8' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0111' 'storage' 'volume' 'bigjim-iad-data-9' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdau,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-9 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-9'
wait_for_volume_available 'bigjim-iad-data-9'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-9')
echo "Attaching volume bigjim-iad-data-9 to instance Bigjim-iad at /dev/vdau (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdau'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-9' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-9' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0112' 'storage' 'volume' 'bigjim-iad-data-10' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdan,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-10 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-10'
wait_for_volume_available 'bigjim-iad-data-10'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-10')
echo "Attaching volume bigjim-iad-data-10 to instance Bigjim-iad at /dev/vdan (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdan'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-10' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-10' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0113' 'storage' 'volume' 'bigjim-iad-data-11' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdao,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-11 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-11'
wait_for_volume_available 'bigjim-iad-data-11'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-11')
echo "Attaching volume bigjim-iad-data-11 to instance Bigjim-iad at /dev/vdao (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdao'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-11' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-11' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0114' 'storage' 'volume' 'bigjim-iad-data-12' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdas,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-12 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-12'
wait_for_volume_available 'bigjim-iad-data-12'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-12')
echo "Attaching volume bigjim-iad-data-12 to instance Bigjim-iad at /dev/vdas (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdas'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-12' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-12' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0115' 'storage' 'volume' 'bigjim-iad-data-13' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdar,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-13 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-13'
wait_for_volume_available 'bigjim-iad-data-13'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-13')
echo "Attaching volume bigjim-iad-data-13 to instance Bigjim-iad at /dev/vdar (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdar'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-13' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-13' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0116' 'storage' 'volume' 'bigjim-iad-data-14' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdap,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-14 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-14'
wait_for_volume_available 'bigjim-iad-data-14'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-14')
echo "Attaching volume bigjim-iad-data-14 to instance Bigjim-iad at /dev/vdap (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdap'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-14' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-14' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0117' 'storage' 'volume' 'bigjim-iad-data-15' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdaq,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-15 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-15'
wait_for_volume_available 'bigjim-iad-data-15'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-15')
echo "Attaching volume bigjim-iad-data-15 to instance Bigjim-iad at /dev/vdaq (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdaq'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-15' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-15' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0118' 'storage' 'volume' 'bigjim-iad-data-16' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdam,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-16 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-16'
wait_for_volume_available 'bigjim-iad-data-16'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-16')
echo "Attaching volume bigjim-iad-data-16 to instance Bigjim-iad at /dev/vdam (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdam'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-16' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-16' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0119' 'storage' 'volume' 'bigjim-iad-data-17' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdal,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-17 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-17'
wait_for_volume_available 'bigjim-iad-data-17'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-17')
echo "Attaching volume bigjim-iad-data-17 to instance Bigjim-iad at /dev/vdal (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdal'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-17' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-17' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0120' 'storage' 'volume' 'bigjim-iad-data-18' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdak,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-18 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-18'
wait_for_volume_available 'bigjim-iad-data-18'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-18')
echo "Attaching volume bigjim-iad-data-18 to instance Bigjim-iad at /dev/vdak (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdak'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-18' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-18' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0121' 'storage' 'volume' 'bigjim-iad-data-19' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdaj,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-19 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-19'
wait_for_volume_available 'bigjim-iad-data-19'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-19')
echo "Attaching volume bigjim-iad-data-19 to instance Bigjim-iad at /dev/vdaj (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdaj'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-19' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-19' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0122' 'storage' 'volume' 'bigjim-iad-data-20' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdai,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-20 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-20'
wait_for_volume_available 'bigjim-iad-data-20'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-20')
echo "Attaching volume bigjim-iad-data-20 to instance Bigjim-iad at /dev/vdai (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdai'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-20' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-20' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0123' 'storage' 'volume' 'bigjim-iad-data-21' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdag,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-21 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-21'
wait_for_volume_available 'bigjim-iad-data-21'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-21')
echo "Attaching volume bigjim-iad-data-21 to instance Bigjim-iad at /dev/vdag (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdag'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-21' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-21' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0124' 'storage' 'volume' 'bigjim-iad-data-22' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdah,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-22 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-22'
wait_for_volume_available 'bigjim-iad-data-22'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-22')
echo "Attaching volume bigjim-iad-data-22 to instance Bigjim-iad at /dev/vdah (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdah'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-22' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-22' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0125' 'storage' 'volume' 'bigjim-iad-data-23' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdae,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-23 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-23'
wait_for_volume_available 'bigjim-iad-data-23'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-23')
echo "Attaching volume bigjim-iad-data-23 to instance Bigjim-iad at /dev/vdae (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdae'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-23' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-23' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0126' 'storage' 'volume' 'bigjim-iad-data-24' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdaf,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-24 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-24'
wait_for_volume_available 'bigjim-iad-data-24'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-24')
echo "Attaching volume bigjim-iad-data-24 to instance Bigjim-iad at /dev/vdaf (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdaf'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-24' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-24' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0127' 'storage' 'volume' 'bigjim-iad-data-25' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdad,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-25 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-25'
wait_for_volume_available 'bigjim-iad-data-25'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-25')
echo "Attaching volume bigjim-iad-data-25 to instance Bigjim-iad at /dev/vdad (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdad'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-25' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-25' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0128' 'storage' 'volume' 'bigjim-iad-data-26' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdac,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-26 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-26'
wait_for_volume_available 'bigjim-iad-data-26'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-26')
echo "Attaching volume bigjim-iad-data-26 to instance Bigjim-iad at /dev/vdac (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdac'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-26' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-26' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0129' 'storage' 'volume' 'bigjim-iad-data-27' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdaa,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-27 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-27'
wait_for_volume_available 'bigjim-iad-data-27'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-27')
echo "Attaching volume bigjim-iad-data-27 to instance Bigjim-iad at /dev/vdaa (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdaa'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-27' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-27' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0130' 'storage' 'volume' 'bigjim-iad-data-28' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdab,size_gb=80' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-28 for instance Bigjim-iad"
openstack volume create --size 80 --type "$VOLUME_TYPE" 'bigjim-iad-data-28'
wait_for_volume_available 'bigjim-iad-data-28'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-28')
echo "Attaching volume bigjim-iad-data-28 to instance Bigjim-iad at /dev/vdab (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdab'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-28' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-28' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0131' 'storage' 'volume' 'bigjim-iad-data-29' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdz,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-29 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-29'
wait_for_volume_available 'bigjim-iad-data-29'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-29')
echo "Attaching volume bigjim-iad-data-29 to instance Bigjim-iad at /dev/vdz (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdz'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-29' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-29' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0132' 'storage' 'volume' 'bigjim-iad-data-30' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdy,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-30 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-30'
wait_for_volume_available 'bigjim-iad-data-30'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-30')
echo "Attaching volume bigjim-iad-data-30 to instance Bigjim-iad at /dev/vdy (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdy'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-30' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-30' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0133' 'storage' 'volume' 'bigjim-iad-data-31' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdx,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-31 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-31'
wait_for_volume_available 'bigjim-iad-data-31'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-31')
echo "Attaching volume bigjim-iad-data-31 to instance Bigjim-iad at /dev/vdx (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdx'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-31' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-31' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0134' 'storage' 'volume' 'bigjim-iad-data-32' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdw,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-32 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-32'
wait_for_volume_available 'bigjim-iad-data-32'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-32')
echo "Attaching volume bigjim-iad-data-32 to instance Bigjim-iad at /dev/vdw (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdw'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-32' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-32' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0135' 'storage' 'volume' 'bigjim-iad-data-33' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdv,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-33 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-33'
wait_for_volume_available 'bigjim-iad-data-33'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-33')
echo "Attaching volume bigjim-iad-data-33 to instance Bigjim-iad at /dev/vdv (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdv'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-33' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-33' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0136' 'storage' 'volume' 'bigjim-iad-data-34' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdu,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-34 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-34'
wait_for_volume_available 'bigjim-iad-data-34'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-34')
echo "Attaching volume bigjim-iad-data-34 to instance Bigjim-iad at /dev/vdu (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdu'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-34' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-34' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0137' 'storage' 'volume' 'bigjim-iad-data-35' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdt,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-35 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-35'
wait_for_volume_available 'bigjim-iad-data-35'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-35')
echo "Attaching volume bigjim-iad-data-35 to instance Bigjim-iad at /dev/vdt (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdt'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-35' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-35' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0138' 'storage' 'volume' 'bigjim-iad-data-36' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vds,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-36 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-36'
wait_for_volume_available 'bigjim-iad-data-36'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-36')
echo "Attaching volume bigjim-iad-data-36 to instance Bigjim-iad at /dev/vds (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vds'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-36' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-36' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0139' 'storage' 'volume' 'bigjim-iad-data-37' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdr,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-37 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-37'
wait_for_volume_available 'bigjim-iad-data-37'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-37')
echo "Attaching volume bigjim-iad-data-37 to instance Bigjim-iad at /dev/vdr (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdr'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-37' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-37' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0140' 'storage' 'volume' 'bigjim-iad-data-38' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdq,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-38 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-38'
wait_for_volume_available 'bigjim-iad-data-38'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-38')
echo "Attaching volume bigjim-iad-data-38 to instance Bigjim-iad at /dev/vdq (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdq'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-38' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-38' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0141' 'storage' 'volume' 'bigjim-iad-data-39' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdp,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-39 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-39'
wait_for_volume_available 'bigjim-iad-data-39'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-39')
echo "Attaching volume bigjim-iad-data-39 to instance Bigjim-iad at /dev/vdp (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdp'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-39' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-39' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0142' 'storage' 'volume' 'bigjim-iad-data-40' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdn,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-40 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-40'
wait_for_volume_available 'bigjim-iad-data-40'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-40')
echo "Attaching volume bigjim-iad-data-40 to instance Bigjim-iad at /dev/vdn (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdn'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-40' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-40' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0143' 'storage' 'volume' 'bigjim-iad-data-41' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdm,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-41 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-41'
wait_for_volume_available 'bigjim-iad-data-41'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-41')
echo "Attaching volume bigjim-iad-data-41 to instance Bigjim-iad at /dev/vdm (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdm'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-41' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-41' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0144' 'storage' 'volume' 'bigjim-iad-data-42' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdo,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-42 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-42'
wait_for_volume_available 'bigjim-iad-data-42'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-42')
echo "Attaching volume bigjim-iad-data-42 to instance Bigjim-iad at /dev/vdo (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdo'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-42' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-42' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0145' 'storage' 'volume' 'bigjim-iad-data-43' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdk,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-43 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-43'
wait_for_volume_available 'bigjim-iad-data-43'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-43')
echo "Attaching volume bigjim-iad-data-43 to instance Bigjim-iad at /dev/vdk (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdk'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-43' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-43' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0146' 'storage' 'volume' 'bigjim-iad-data-44' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdl,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-44 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-44'
wait_for_volume_available 'bigjim-iad-data-44'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-44')
echo "Attaching volume bigjim-iad-data-44 to instance Bigjim-iad at /dev/vdl (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdl'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-44' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-44' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0147' 'storage' 'volume' 'bigjim-iad-data-45' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdj,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-45 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-45'
wait_for_volume_available 'bigjim-iad-data-45'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-45')
echo "Attaching volume bigjim-iad-data-45 to instance Bigjim-iad at /dev/vdj (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdj'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-45' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-45' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0148' 'storage' 'volume' 'bigjim-iad-data-46' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdi,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-46 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-46'
wait_for_volume_available 'bigjim-iad-data-46'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-46')
echo "Attaching volume bigjim-iad-data-46 to instance Bigjim-iad at /dev/vdi (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdi'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-46' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-46' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0149' 'storage' 'volume' 'bigjim-iad-data-47' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdh,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-47 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-47'
wait_for_volume_available 'bigjim-iad-data-47'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-47')
echo "Attaching volume bigjim-iad-data-47 to instance Bigjim-iad at /dev/vdh (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdh'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-47' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-47' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0150' 'storage' 'volume' 'bigjim-iad-data-48' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdf,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-48 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-48'
wait_for_volume_available 'bigjim-iad-data-48'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-48')
echo "Attaching volume bigjim-iad-data-48 to instance Bigjim-iad at /dev/vdf (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdf'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-48' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-48' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0151' 'storage' 'volume' 'bigjim-iad-data-49' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vde,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-49 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-49'
wait_for_volume_available 'bigjim-iad-data-49'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-49')
echo "Attaching volume bigjim-iad-data-49 to instance Bigjim-iad at /dev/vde (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vde'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-49' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-49' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0152' 'storage' 'volume' 'bigjim-iad-data-50' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdg,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-50 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-50'
wait_for_volume_available 'bigjim-iad-data-50'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-50')
echo "Attaching volume bigjim-iad-data-50 to instance Bigjim-iad at /dev/vdg (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdg'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-50' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-50' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0153' 'storage' 'volume' 'bigjim-iad-data-51' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdc,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-51 for instance Bigjim-iad"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'bigjim-iad-data-51'
wait_for_volume_available 'bigjim-iad-data-51'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-51')
echo "Attaching volume bigjim-iad-data-51 to instance Bigjim-iad at /dev/vdc (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdc'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-51' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-51' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0154' 'storage' 'volume' 'bigjim-iad-data-52' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdb,size_gb=500' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-52 for instance Bigjim-iad"
openstack volume create --size 500 --type "$VOLUME_TYPE" 'bigjim-iad-data-52'
wait_for_volume_available 'bigjim-iad-data-52'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-52')
echo "Attaching volume bigjim-iad-data-52 to instance Bigjim-iad at /dev/vdb (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdb'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-52' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-52' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0155' 'storage' 'volume' 'u20-data-1' 'create_and_attach_volume' 'server=u20,device=/dev/vdb,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'u20'
echo "Creating data volume u20-data-1 for instance u20"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'u20-data-1'
wait_for_volume_available 'u20-data-1'
VOL_ID=$(openstack volume show -f value -c id 'u20-data-1')
echo "Attaching volume u20-data-1 to instance u20 at /dev/vdb (max 5 retries)"
attach_volume_with_retry 'u20' "$VOL_ID" '/dev/vdb'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'u20-data-1' 2>/dev/null || echo "")
append_resource_map 'f4dd8084-20c4-40a4-8784-7db8c6c5162a' 'u20' 'volume' 'u20-data-1' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0156' 'storage' 'volume' 'alma9-data-1' 'create_and_attach_volume' 'server=Alma9,device=/dev/vdb,size_gb=1024' <<'STEP_EOF'
wait_for_server_active 'Alma9'
echo "Creating data volume alma9-data-1 for instance Alma9"
openstack volume create --size 1024 --type "$VOLUME_TYPE" 'alma9-data-1'
wait_for_volume_available 'alma9-data-1'
VOL_ID=$(openstack volume show -f value -c id 'alma9-data-1')
echo "Attaching volume alma9-data-1 to instance Alma9 at /dev/vdb (max 5 retries)"
attach_volume_with_retry 'Alma9' "$VOL_ID" '/dev/vdb'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'alma9-data-1' 2>/dev/null || echo "")
append_resource_map 'de2cc03b-b53a-4f32-8b1b-8a3c9d757069' 'Alma9' 'volume' 'alma9-data-1' "$_MAP_VOL_ID" "" "" 'created'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SOURCE INFRA → TARGET FLEX DEPLOY SUMMARY"
echo "Source elements planned: VMs=46 Volumes=58 LoadBalancers=5"
printf "| %-34s | %-24s | %-34s | %-18s | %-8s |\n" "Source VM" "Original Flavor" "Target FLEX VM" "FLEX Flavor" "Status"
printf "| %-34s | %-24s | %-34s | %-18s | %-8s |\n" "----------------------------------" "------------------------" "----------------------------------" "------------------" "--------"
_SUMMARY_VM_OK=0
_SUMMARY_VM_FAIL=0
if openstack server show 'Server-27' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'Server-27' '1 GB General Purpose v1' 'Server-27' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'haproxyopsc' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'haproxyopsc' '4 GB General Purpose v1' 'haproxyopsc' 'gp.5.4.4' "$_VM_STATUS"
if openstack server show 'u24clean' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'u24clean' '2 GB General Purpose v1' 'u24clean' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'debian12' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'debian12' '2 GB General Purpose v1' 'debian12' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'u24 green server' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'u24 green server' '2 GB General Purpose v1' 'u24 green server' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'u-22' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'u-22' '2 GB General Purpose v1' 'u-22' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'Server-21' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'Server-21' '2 GB General Purpose v1' 'Server-21' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'musicradio' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'musicradio' '2 GB General Purpose v1' 'musicradio' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'postgresqlU24' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'postgresqlU24' '1 GB General Purpose v1' 'postgresqlU24' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'mongo db u24' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'mongo db u24' '1 GB General Purpose v1' 'mongo db u24' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'ospcwin2019' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'ospcwin2019' '1 GB General Purpose v1' 'ospcwin2019' 'gp.5.2.4' "$_VM_STATUS"
if openstack server show 'opscwin2016' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'opscwin2016' '2 GB General Purpose v1' 'opscwin2016' 'gp.5.2.4' "$_VM_STATUS"
if openstack server show 'bigjumpwindowsiad' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'bigjumpwindowsiad' '30 GB Compute v1' 'bigjumpwindowsiad' 'gp.5.16.64' "$_VM_STATUS"
if openstack server show 'Bigjim-iad' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'Bigjim-iad' '30 GB Compute v1' 'Bigjim-iad' 'gp.5.16.64' "$_VM_STATUS"
if openstack server show 'jenkins' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'jenkins' '4 GB General Purpose v1' 'jenkins' 'gp.5.4.4' "$_VM_STATUS"
if openstack server show 'centos7' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'centos7' '3.75 GB Compute v1' 'centos7' 'gp.5.2.4' "$_VM_STATUS"
if openstack server show 'win2019' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'win2019' '3.75 GB Compute v1' 'win2019' 'gp.5.2.4' "$_VM_STATUS"
if openstack server show 'windows2016' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'windows2016' '2 GB General Purpose v1' 'windows2016' 'gp.5.2.4' "$_VM_STATUS"
if openstack server show 'debian11new' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'debian11new' '2 GB General Purpose v1' 'debian11new' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'dbian10new' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'dbian10new' '2 GB General Purpose v1' 'dbian10new' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'u20' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'u20' '1 GB General Purpose v1' 'u20' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'rocky9' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'rocky9' '1 GB General Purpose v1' 'rocky9' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'alma8' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'alma8' '3.75 GB Compute v1' 'alma8' 'gp.5.2.4' "$_VM_STATUS"
if openstack server show 'dbian12' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'dbian12' '3.75 GB Compute v1' 'dbian12' 'gp.5.2.4' "$_VM_STATUS"
if openstack server show 'Alma9' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'Alma9' '7.5 GB Compute v1' 'Alma9' 'gp.5.4.8' "$_VM_STATUS"
if openstack server show 'rocky8' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'rocky8' '7.5 GB Compute v1' 'rocky8' 'gp.5.4.8' "$_VM_STATUS"
if openstack server show 'HA percona 8-02' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'HA percona 8-02' '-' 'HA percona 8-02' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'drupal' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'drupal' '-' 'drupal' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'dbaasmariadb' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'dbaasmariadb' '-' 'dbaasmariadb' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'HA-Mysql8-01' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'HA-Mysql8-01' '-' 'HA-Mysql8-01' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'HA-mariaDB-02' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'HA-mariaDB-02' '-' 'HA-mariaDB-02' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'drupalphp_Database' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'drupalphp_Database' '-' 'drupalphp_Database' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'HA percona 8-03' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'HA percona 8-03' '-' 'HA percona 8-03' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'HA-mariaDB-03' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'HA-mariaDB-03' '-' 'HA-mariaDB-03' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'lamp_Database' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'lamp_Database' '-' 'lamp_Database' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'HAdbaasSql-03' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'HAdbaasSql-03' '-' 'HAdbaasSql-03' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'Stack-05_Database' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'Stack-05_Database' '-' 'Stack-05_Database' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'HAmysql-01' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'HAmysql-01' '-' 'HAmysql-01' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'mariad1' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'mariad1' '-' 'mariad1' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'hadbaas-vip-03' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'hadbaas-vip-03' '-' 'hadbaas-vip-03' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'Instance-21' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'Instance-21' '-' 'Instance-21' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'mysql8instance' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'mysql8instance' '-' 'mysql8instance' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'sql' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'sql' '-' 'sql' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'Mariadb' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'Mariadb' '-' 'Mariadb' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'hadbaas-vip-01' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'hadbaas-vip-01' '-' 'hadbaas-vip-01' 'gp.5.2.2' "$_VM_STATUS"
if openstack server show 'Instance-20' >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi
printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\n" 'Instance-20' '-' 'Instance-20' 'gp.5.2.2' "$_VM_STATUS"
echo "Target FLEX VM count: $_SUMMARY_VM_OK created/reused, $_SUMMARY_VM_FAIL failed, total planned: 46"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Deployment script finished."
echo "Step results: PASS=$STEP_PASS FAIL=$STEP_FAIL IGNORED=$STEP_IGNORED"
echo "Results CSV: $RESULTS_CSV"
echo "Resource mapping CSV: $RESOURCE_MAP_CSV"
if [ "$STEP_FAIL" -gt 0 ]; then
  echo "One or more deployment steps failed." >&2
  exit 2
fi
