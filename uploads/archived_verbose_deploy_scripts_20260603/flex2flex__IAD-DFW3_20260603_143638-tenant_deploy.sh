#!/usr/bin/env bash
set -uo pipefail

PUBLIC_NETWORK='PUBLICNET'
PRIVATE_NETWORK='tenant-net'
SUBNET_NAME='tenant-subnet'
SUBNET_CIDR='10.60.0.0/24'
ROUTER_NAME='tenant-router'
SECURITY_GROUP='default'
VOLUME_TYPE='Performance'
KEY_NAME='laptopubuntu24'
SSH_PUB_KEY=''
FAIL_FAST=0
RESULTS_CSV='/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/flex2flex__IAD-DFW3_20260603_143638-tenant_deploy_results.csv'
RESOURCE_MAP_CSV='/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/flex2flex__IAD-DFW3_20260603_143638-tenant_deploy_resource_map.csv'
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
openstack server create --flavor 'gp.5.8.32' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'FlexDFWjumphost'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'FlexDFWjumphost' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'FlexDFWjumphost' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'FlexDFWjumphost' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '632e1a39-10fd-45c3-b995-b22aed273108' 'FlexDFWjumphost' 'server' 'FlexDFWjumphost' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0002' 'compute' 'floating_ip' 'FlexDFWjumphost' 'assign_floating_ip' 'server=FlexDFWjumphost,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'FlexDFWjumphost'
if server_has_floating_ip 'FlexDFWjumphost'; then
  echo "Server FlexDFWjumphost already has a floating IP; skipping assignment."
else
  assign_floating_ip 'FlexDFWjumphost' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0003' 'compute' 'server' 'FlexDFWjumphost' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server FlexDFWjumphost"
openstack server create --flavor 'gp.5.8.32' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'FlexDFWjumphost'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'FlexDFWjumphost' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'FlexDFWjumphost' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'FlexDFWjumphost' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '51a1ed0c-9ca4-4966-aca8-8145f7c3b3b6' 'FlexDFWjumphost' 'server' 'FlexDFWjumphost' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0004' 'compute' 'floating_ip' 'FlexDFWjumphost' 'assign_floating_ip' 'server=FlexDFWjumphost,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'FlexDFWjumphost'
if server_has_floating_ip 'FlexDFWjumphost'; then
  echo "Server FlexDFWjumphost already has a floating IP; skipping assignment."
else
  assign_floating_ip 'FlexDFWjumphost' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0005' 'compute' 'server' 'FlexDFWjumphost' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server FlexDFWjumphost"
openstack server create --flavor 'gp.5.8.32' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'FlexDFWjumphost'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'FlexDFWjumphost' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'FlexDFWjumphost' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'FlexDFWjumphost' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '26f81255-643a-41aa-93b5-7d3a3b699fd4' 'FlexDFWjumphost' 'server' 'FlexDFWjumphost' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0006' 'compute' 'floating_ip' 'FlexDFWjumphost' 'assign_floating_ip' 'server=FlexDFWjumphost,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'FlexDFWjumphost'
if server_has_floating_ip 'FlexDFWjumphost'; then
  echo "Server FlexDFWjumphost already has a floating IP; skipping assignment."
else
  assign_floating_ip 'FlexDFWjumphost' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0007' 'compute' 'server' 'FlexDFWjumphost' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server FlexDFWjumphost"
openstack server create --flavor 'gp.5.8.32' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'FlexDFWjumphost'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'FlexDFWjumphost' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'FlexDFWjumphost' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'FlexDFWjumphost' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'c0fd39c2-1f5c-4834-90e2-3652eda1af70' 'FlexDFWjumphost' 'server' 'FlexDFWjumphost' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0008' 'compute' 'floating_ip' 'FlexDFWjumphost' 'assign_floating_ip' 'server=FlexDFWjumphost,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'FlexDFWjumphost'
if server_has_floating_ip 'FlexDFWjumphost'; then
  echo "Server FlexDFWjumphost already has a floating IP; skipping assignment."
else
  assign_floating_ip 'FlexDFWjumphost' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0009' 'compute' 'server' 'Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' 'create_server_local_boot' 'image=Windows Server 2019,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating server Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio"
openstack server create --flavor 'gp.5.4.4' --image 'Windows Server 2019' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password 'x2PmcjKnpzm5rC' 'Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '58d7c38c-a086-4b1a-b43a-9ce058c1c3ae' 'Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' 'server' 'Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0010' 'compute' 'floating_ip' 'Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' 'assign_floating_ip' 'server=Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio'
if server_has_floating_ip 'Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio'; then
  echo "Server Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio already has a floating IP; skipping assignment."
else
  assign_floating_ip 'Windows_Server_2019Re-snap-20260416211842-snapwin-safe-ide-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0011' 'compute' 'server' 'opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' 'create_server_local_boot' 'image=Windows Server 2016,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating server opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio"
openstack server create --flavor 'gp.5.4.4' --image 'Windows Server 2016' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password 'lj2sJCgL26LTHJ' 'opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '13c18f3e-a792-4eb7-a2bf-92bb00d2adb9' 'opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' 'server' 'opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0012' 'compute' 'floating_ip' 'opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' 'assign_floating_ip' 'server=opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio'
if server_has_floating_ip 'opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio'; then
  echo "Server opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio already has a floating IP; skipping assignment."
else
  assign_floating_ip 'opscwin2016-20260509-150218-snap-202605091502-snapwin-virtio-ready-img-snapwin-safe-ide-img-r3-f2f-DFW3-to-IAD3-snapwin-final-virtio' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0013' 'compute' 'server' 'IADjumphostu24' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server IADjumphostu24"
openstack server create --flavor 'gp.5.4.16' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'IADjumphostu24'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'IADjumphostu24' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'IADjumphostu24' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'IADjumphostu24' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'e2039b99-474c-49c5-9271-469ae7a1fa26' 'IADjumphostu24' 'server' 'IADjumphostu24' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0014' 'compute' 'floating_ip' 'IADjumphostu24' 'assign_floating_ip' 'server=IADjumphostu24,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'IADjumphostu24'
if server_has_floating_ip 'IADjumphostu24'; then
  echo "Server IADjumphostu24 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'IADjumphostu24' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0015' 'load_balancer' 'load_balancer' 'frontend- Load-Balancer-01' 'create_or_reuse_lb_stack' 'provider=ovn,protocol=HTTP,listener_port=80,algorithm=ROUND_ROBIN' <<'STEP_EOF'
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

run_step 'step-0016' 'load_balancer' 'load_balancer' 'u24backend' 'create_or_reuse_lb_stack' 'provider=ovn,protocol=HTTP,listener_port=80,algorithm=ROUND_ROBIN' <<'STEP_EOF'
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

run_step 'step-0017' 'load_balancer' 'load_balancer' 'DB_loadbalancer MYSQL' 'create_or_reuse_lb_stack' 'provider=ovn,protocol=HTTP,listener_port=80,algorithm=ROUND_ROBIN' <<'STEP_EOF'
echo "Ensuring load balancer DB_loadbalancer MYSQL"
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
openstack loadbalancer show 'DB_loadbalancer MYSQL' >/dev/null 2>&1 || openstack loadbalancer create --name 'DB_loadbalancer MYSQL' --provider 'ovn' --vip-subnet-id "$VIP_SUBNET_ID"
wait_for_loadbalancer_active 'DB_loadbalancer MYSQL'
openstack loadbalancer listener show 'db-loadbalancer-mysql-listener' >/dev/null 2>&1 || openstack loadbalancer listener create --name 'db-loadbalancer-mysql-listener' --protocol 'HTTP' --protocol-port 80 'DB_loadbalancer MYSQL'
wait_for_loadbalancer_active 'DB_loadbalancer MYSQL'
openstack loadbalancer pool show 'db-loadbalancer-mysql-pool' >/dev/null 2>&1 || openstack loadbalancer pool create --name 'db-loadbalancer-mysql-pool' --lb-algorithm 'ROUND_ROBIN' --listener 'db-loadbalancer-mysql-listener' --protocol 'HTTP'
wait_for_loadbalancer_active 'DB_loadbalancer MYSQL'
STEP_EOF

# Map OSPC LB → FLEX LB
_MAP_LB_ID=$(openstack loadbalancer show -f value -c id 'DB_loadbalancer MYSQL' 2>/dev/null || echo "")
_MAP_LB_VIP=$(openstack loadbalancer show -f value -c vip_address 'DB_loadbalancer MYSQL' 2>/dev/null || echo "")
append_resource_map '' '' 'load_balancer' 'DB_loadbalancer MYSQL' "$_MAP_LB_ID" "$_MAP_LB_VIP" "" 'created'

run_step 'step-0018' 'load_balancer' 'load_balancer' 'LBmariaDB' 'create_or_reuse_lb_stack' 'provider=ovn,protocol=HTTP,listener_port=80,algorithm=ROUND_ROBIN' <<'STEP_EOF'
echo "Ensuring load balancer LBmariaDB"
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
openstack loadbalancer show 'LBmariaDB' >/dev/null 2>&1 || openstack loadbalancer create --name 'LBmariaDB' --provider 'ovn' --vip-subnet-id "$VIP_SUBNET_ID"
wait_for_loadbalancer_active 'LBmariaDB'
openstack loadbalancer listener show 'lbmariadb-listener' >/dev/null 2>&1 || openstack loadbalancer listener create --name 'lbmariadb-listener' --protocol 'HTTP' --protocol-port 80 'LBmariaDB'
wait_for_loadbalancer_active 'LBmariaDB'
openstack loadbalancer pool show 'lbmariadb-pool' >/dev/null 2>&1 || openstack loadbalancer pool create --name 'lbmariadb-pool' --lb-algorithm 'ROUND_ROBIN' --listener 'lbmariadb-listener' --protocol 'HTTP'
wait_for_loadbalancer_active 'LBmariaDB'
STEP_EOF

# Map OSPC LB → FLEX LB
_MAP_LB_ID=$(openstack loadbalancer show -f value -c id 'LBmariaDB' 2>/dev/null || echo "")
_MAP_LB_VIP=$(openstack loadbalancer show -f value -c vip_address 'LBmariaDB' 2>/dev/null || echo "")
append_resource_map '' '' 'load_balancer' 'LBmariaDB' "$_MAP_LB_ID" "$_MAP_LB_VIP" "" 'created'

run_step 'step-0019' 'load_balancer' 'load_balancer' 'perconaLB' 'create_or_reuse_lb_stack' 'provider=ovn,protocol=HTTP,listener_port=80,algorithm=ROUND_ROBIN' <<'STEP_EOF'
echo "Ensuring load balancer perconaLB"
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
openstack loadbalancer show 'perconaLB' >/dev/null 2>&1 || openstack loadbalancer create --name 'perconaLB' --provider 'ovn' --vip-subnet-id "$VIP_SUBNET_ID"
wait_for_loadbalancer_active 'perconaLB'
openstack loadbalancer listener show 'perconalb-listener' >/dev/null 2>&1 || openstack loadbalancer listener create --name 'perconalb-listener' --protocol 'HTTP' --protocol-port 80 'perconaLB'
wait_for_loadbalancer_active 'perconaLB'
openstack loadbalancer pool show 'perconalb-pool' >/dev/null 2>&1 || openstack loadbalancer pool create --name 'perconalb-pool' --lb-algorithm 'ROUND_ROBIN' --listener 'perconalb-listener' --protocol 'HTTP'
wait_for_loadbalancer_active 'perconaLB'
STEP_EOF

# Map OSPC LB → FLEX LB
_MAP_LB_ID=$(openstack loadbalancer show -f value -c id 'perconaLB' 2>/dev/null || echo "")
_MAP_LB_VIP=$(openstack loadbalancer show -f value -c vip_address 'perconaLB' 2>/dev/null || echo "")
append_resource_map '' '' 'load_balancer' 'perconaLB' "$_MAP_LB_ID" "$_MAP_LB_VIP" "" 'created'

run_step 'step-0020' 'load_balancer' 'load_balancer' 'dblb' 'create_or_reuse_lb_stack' 'provider=ovn,protocol=HTTP,listener_port=80,algorithm=ROUND_ROBIN' <<'STEP_EOF'
echo "Ensuring load balancer dblb"
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
openstack loadbalancer show 'dblb' >/dev/null 2>&1 || openstack loadbalancer create --name 'dblb' --provider 'ovn' --vip-subnet-id "$VIP_SUBNET_ID"
wait_for_loadbalancer_active 'dblb'
openstack loadbalancer listener show 'dblb-listener' >/dev/null 2>&1 || openstack loadbalancer listener create --name 'dblb-listener' --protocol 'HTTP' --protocol-port 80 'dblb'
wait_for_loadbalancer_active 'dblb'
openstack loadbalancer pool show 'dblb-pool' >/dev/null 2>&1 || openstack loadbalancer pool create --name 'dblb-pool' --lb-algorithm 'ROUND_ROBIN' --listener 'dblb-listener' --protocol 'HTTP'
wait_for_loadbalancer_active 'dblb'
STEP_EOF

# Map OSPC LB → FLEX LB
_MAP_LB_ID=$(openstack loadbalancer show -f value -c id 'dblb' 2>/dev/null || echo "")
_MAP_LB_VIP=$(openstack loadbalancer show -f value -c vip_address 'dblb' 2>/dev/null || echo "")
append_resource_map '' '' 'load_balancer' 'dblb' "$_MAP_LB_ID" "$_MAP_LB_VIP" "" 'created'

run_step 'step-0021' 'load_balancer' 'load_balancer' 'backend' 'create_or_reuse_lb_stack' 'provider=ovn,protocol=HTTP,listener_port=80,algorithm=ROUND_ROBIN' <<'STEP_EOF'
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

echo "Deployment script finished."
echo "Step results: PASS=$STEP_PASS FAIL=$STEP_FAIL IGNORED=$STEP_IGNORED"
echo "Results CSV: $RESULTS_CSV"
echo "Resource mapping CSV: $RESOURCE_MAP_CSV"
if [ "$STEP_FAIL" -gt 0 ]; then
  echo "One or more deployment steps failed." >&2
  exit 2
fi
