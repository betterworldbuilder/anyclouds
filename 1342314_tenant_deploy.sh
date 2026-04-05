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
RESULTS_CSV='/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-3.0/1342314_tenant_deploy_results.csv'
RESOURCE_MAP_CSV='/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-3.0/1342314_tenant_deploy_resource_map.csv'
STEP_PASS=0
STEP_FAIL=0

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
    STEP_FAIL=$((STEP_FAIL + 1))
    last_error=$(tail -n 1 "$output_file" | tr '\r\n' ' ' || true)
    append_result "$step_id" "$phase" "$resource_type" "$resource_name" "$action" "FAIL" "$exit_code" "$last_error"
    echo "Step failed: $step_id phase=$phase type=$resource_type name=$resource_name action=$action reason=$reason" >&2
    cat "$output_file" >&2
    if [ "$FAIL_FAST" = "1" ]; then
      rm -f "$script_file" "$output_file"
      echo "Fail-fast is enabled; aborting after first failed step." >&2
      exit "$exit_code"
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
      echo "Keypair $KEY_NAME was not found in target project. Create it first or provide the SSH Public Key." >&2
      exit 1
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

run_step 'step-0001' 'compute' 'server' 'u24-postgresl-2' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server u24-postgresl-2"
openstack server create --flavor 'gp.5.4.8' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u24-postgresl-2'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u24-postgresl-2' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u24-postgresl-2' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u24-postgresl-2' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'dc368b96-8438-435e-a658-80de118e6c0b' 'u24-postgresl-2' 'server' 'u24-postgresl-2' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0002' 'compute' 'floating_ip' 'u24-postgresl-2' 'assign_floating_ip' 'server=u24-postgresl-2,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'u24-postgresl-2'
if server_has_floating_ip 'u24-postgresl-2'; then
  echo "Server u24-postgresl-2 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'u24-postgresl-2' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0003' 'compute' 'server' 'u24-BackEnd-2' 'create_server_local_boot' 'image=Ubuntu 20.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server u24-BackEnd-2"
openstack server create --flavor 'gp.5.4.8' --image 'Ubuntu 20.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u24-BackEnd-2'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u24-BackEnd-2' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u24-BackEnd-2' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u24-BackEnd-2' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'd4270fdb-5def-472b-bafd-3d461c4d5d4c' 'u24-BackEnd-2' 'server' 'u24-BackEnd-2' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0004' 'compute' 'floating_ip' 'u24-BackEnd-2' 'assign_floating_ip' 'server=u24-BackEnd-2,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'u24-BackEnd-2'
if server_has_floating_ip 'u24-BackEnd-2'; then
  echo "Server u24-BackEnd-2 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'u24-BackEnd-2' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0005' 'compute' 'server' 'u24-BackEnd-2' 'create_server_local_boot' 'image=Ubuntu 20.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server u24-BackEnd-2"
openstack server create --flavor 'gp.5.4.8' --image 'Ubuntu 20.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u24-BackEnd-2'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u24-BackEnd-2' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u24-BackEnd-2' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u24-BackEnd-2' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'ece54f3a-6c6d-490a-ba59-e28e135878f6' 'u24-BackEnd-2' 'server' 'u24-BackEnd-2' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0006' 'compute' 'floating_ip' 'u24-BackEnd-2' 'assign_floating_ip' 'server=u24-BackEnd-2,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'u24-BackEnd-2'
if server_has_floating_ip 'u24-BackEnd-2'; then
  echo "Server u24-BackEnd-2 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'u24-BackEnd-2' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0007' 'compute' 'server' 'u24-FrontEnd 2' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server u24-FrontEnd 2"
openstack server create --flavor 'gp.5.4.8' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u24-FrontEnd 2'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u24-FrontEnd 2' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u24-FrontEnd 2' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u24-FrontEnd 2' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '13822abd-c2c5-49d0-97d2-4b4c627df7a6' 'u24-FrontEnd 2' 'server' 'u24-FrontEnd 2' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0008' 'compute' 'floating_ip' 'u24-FrontEnd 2' 'assign_floating_ip' 'server=u24-FrontEnd 2,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'u24-FrontEnd 2'
if server_has_floating_ip 'u24-FrontEnd 2'; then
  echo "Server u24-FrontEnd 2 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'u24-FrontEnd 2' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0009' 'compute' 'server' 'rocky8' 'create_server_local_boot' 'image=Rocky Linux 8,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server rocky8"
openstack server create --flavor 'gp.5.4.8' --image 'Rocky Linux 8' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'rocky8'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'rocky8' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'rocky8' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'rocky8' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '7afcc45d-4080-475e-a771-8ee1f265ef5c' 'rocky8' 'server' 'rocky8' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0010' 'compute' 'floating_ip' 'rocky8' 'assign_floating_ip' 'server=rocky8,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'rocky8'
if server_has_floating_ip 'rocky8'; then
  echo "Server rocky8 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'rocky8' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0011' 'compute' 'server' 'alma9-2gv1' 'create_server_local_boot' 'image=AlmaLinux 8,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server alma9-2gv1"
openstack server create --flavor 'gp.5.2.2' --image 'AlmaLinux 8' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'alma9-2gv1'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'alma9-2gv1' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'alma9-2gv1' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'alma9-2gv1' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '61313846-d2c3-4159-b471-7b9ab60be650' 'alma9-2gv1' 'server' 'alma9-2gv1' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0012' 'compute' 'floating_ip' 'alma9-2gv1' 'assign_floating_ip' 'server=alma9-2gv1,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'alma9-2gv1'
if server_has_floating_ip 'alma9-2gv1'; then
  echo "Server alma9-2gv1 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'alma9-2gv1' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0013' 'compute' 'server' 'debian10-Flav2gv1' 'create_server_local_boot' 'image=Debian 11,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server debian10-Flav2gv1"
openstack server create --flavor 'gp.5.2.2' --image 'Debian 11' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'debian10-Flav2gv1'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'debian10-Flav2gv1' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'debian10-Flav2gv1' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'debian10-Flav2gv1' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '30a41d3e-718e-4410-a2c1-505edb81c092' 'debian10-Flav2gv1' 'server' 'debian10-Flav2gv1' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0014' 'compute' 'floating_ip' 'debian10-Flav2gv1' 'assign_floating_ip' 'server=debian10-Flav2gv1,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'debian10-Flav2gv1'
if server_has_floating_ip 'debian10-Flav2gv1'; then
  echo "Server debian10-Flav2gv1 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'debian10-Flav2gv1' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0015' 'compute' 'server' 'ospc-jumpHost' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server ospc-jumpHost"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'ospc-jumpHost'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'ospc-jumpHost' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'ospc-jumpHost' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'ospc-jumpHost' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '39e0d438-46cf-47c3-88e6-5a5f84859a84' 'ospc-jumpHost' 'server' 'ospc-jumpHost' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0016' 'compute' 'floating_ip' 'ospc-jumpHost' 'assign_floating_ip' 'server=ospc-jumpHost,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'ospc-jumpHost'
if server_has_floating_ip 'ospc-jumpHost'; then
  echo "Server ospc-jumpHost already has a floating IP; skipping assignment."
else
  assign_floating_ip 'ospc-jumpHost' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0017' 'compute' 'server' 'u24-postgresl' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server u24-postgresl"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u24-postgresl'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u24-postgresl' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u24-postgresl' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u24-postgresl' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'd9b51e0a-f7ae-4678-9e18-2971089c6af7' 'u24-postgresl' 'server' 'u24-postgresl' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0018' 'compute' 'floating_ip' 'u24-postgresl' 'assign_floating_ip' 'server=u24-postgresl,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'u24-postgresl'
if server_has_floating_ip 'u24-postgresl'; then
  echo "Server u24-postgresl already has a floating IP; skipping assignment."
else
  assign_floating_ip 'u24-postgresl' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0019' 'compute' 'server' 'u24-FrontEnd' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server u24-FrontEnd"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u24-FrontEnd'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u24-FrontEnd' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u24-FrontEnd' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u24-FrontEnd' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '7c7f7240-9973-43b6-9b14-bf4969806e86' 'u24-FrontEnd' 'server' 'u24-FrontEnd' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0020' 'compute' 'floating_ip' 'u24-FrontEnd' 'assign_floating_ip' 'server=u24-FrontEnd,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'u24-FrontEnd'
if server_has_floating_ip 'u24-FrontEnd'; then
  echo "Server u24-FrontEnd already has a floating IP; skipping assignment."
else
  assign_floating_ip 'u24-FrontEnd' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0021' 'compute' 'server' 'php-ospc' 'create_server_local_boot' 'image=Rocky Linux 8,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server php-ospc"
openstack server create --flavor 'gp.5.4.4' --image 'Rocky Linux 8' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'php-ospc'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'php-ospc' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'php-ospc' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'php-ospc' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'b6bbe416-0eac-4aa2-8dd1-89b8e0fbd969' 'php-ospc' 'server' 'php-ospc' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0022' 'compute' 'floating_ip' 'php-ospc' 'assign_floating_ip' 'server=php-ospc,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'php-ospc'
if server_has_floating_ip 'php-ospc'; then
  echo "Server php-ospc already has a floating IP; skipping assignment."
else
  assign_floating_ip 'php-ospc' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0023' 'compute' 'server' 'Windows Server 2019Re' 'create_server_local_boot' 'image=Windows Server 2019,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating server Windows Server 2019Re"
openstack server create --flavor 'gp.5.2.4' --image 'Windows Server 2019' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password '2UuKmoCptzNpm3' 'Windows Server 2019Re'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Windows Server 2019Re' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Windows Server 2019Re' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Windows Server 2019Re' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'd8753e16-0039-4c04-993c-7e14be21e212' 'Windows Server 2019Re' 'server' 'Windows Server 2019Re' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0024' 'compute' 'floating_ip' 'Windows Server 2019Re' 'assign_floating_ip' 'server=Windows Server 2019Re,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'Windows Server 2019Re'
if server_has_floating_ip 'Windows Server 2019Re'; then
  echo "Server Windows Server 2019Re already has a floating IP; skipping assignment."
else
  assign_floating_ip 'Windows Server 2019Re' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0025' 'compute' 'server' 'win2019websql2019' 'create_server_local_boot' 'image=Windows Server 2019 with SQL 2019 Web,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating server win2019websql2019"
openstack server create --flavor 'gp.5.2.4' --image 'Windows Server 2019 with SQL 2019 Web' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password 'PgQChS5vqZJWmU' 'win2019websql2019'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'win2019websql2019' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'win2019websql2019' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'win2019websql2019' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '47f882bf-4d6d-41d6-baef-cfcc7a9c5e61' 'win2019websql2019' 'server' 'win2019websql2019' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0026' 'compute' 'floating_ip' 'win2019websql2019' 'assign_floating_ip' 'server=win2019websql2019,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'win2019websql2019'
if server_has_floating_ip 'win2019websql2019'; then
  echo "Server win2019websql2019 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'win2019websql2019' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0027' 'compute' 'server' 'Windows Server 2016 + SQL Server 2019' 'create_server_local_boot' 'image=Windows Server 2016,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating server Windows Server 2016 + SQL Server 2019"
openstack server create --flavor 'gp.5.2.4' --image 'Windows Server 2016' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password 'x1ScQcStTrkNNp' 'Windows Server 2016 + SQL Server 2019'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Windows Server 2016 + SQL Server 2019' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Windows Server 2016 + SQL Server 2019' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Windows Server 2016 + SQL Server 2019' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '741c63ea-e4ae-4048-b6cb-fc7b7716034e' 'Windows Server 2016 + SQL Server 2019' 'server' 'Windows Server 2016 + SQL Server 2019' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0028' 'compute' 'floating_ip' 'Windows Server 2016 + SQL Server 2019' 'assign_floating_ip' 'server=Windows Server 2016 + SQL Server 2019,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'Windows Server 2016 + SQL Server 2019'
if server_has_floating_ip 'Windows Server 2016 + SQL Server 2019'; then
  echo "Server Windows Server 2016 + SQL Server 2019 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'Windows Server 2016 + SQL Server 2019' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0029' 'compute' 'server' 'u24Backend' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server u24Backend"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u24Backend'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u24Backend' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u24Backend' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u24Backend' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '6b24fa27-fada-461b-b50a-41cb64e453ab' 'u24Backend' 'server' 'u24Backend' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0030' 'compute' 'floating_ip' 'u24Backend' 'assign_floating_ip' 'server=u24Backend,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'u24Backend'
if server_has_floating_ip 'u24Backend'; then
  echo "Server u24Backend already has a floating IP; skipping assignment."
else
  assign_floating_ip 'u24Backend' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0031' 'compute' 'server' 'HA percona 8-02' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA percona 8-02"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA percona 8-02'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA percona 8-02' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA percona 8-02' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA percona 8-02' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '0651b25a-9810-41d2-ac00-d30aae53fcdc' 'HA percona 8-02' 'server' 'HA percona 8-02' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0032' 'compute' 'server' 'drupal' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server drupal"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'drupal'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'drupal' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'drupal' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'drupal' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '0e0c1ccf-e8be-4e40-8e04-772307364118' 'drupal' 'server' 'drupal' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0033' 'compute' 'server' 'HA-Mysql8-01' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA-Mysql8-01"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA-Mysql8-01'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA-Mysql8-01' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA-Mysql8-01' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA-Mysql8-01' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '15794001-4db3-41bf-adbd-a00a149d02d6' 'HA-Mysql8-01' 'server' 'HA-Mysql8-01' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0034' 'compute' 'server' 'HA-mariaDB-02' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA-mariaDB-02"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA-mariaDB-02'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA-mariaDB-02' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA-mariaDB-02' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA-mariaDB-02' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '1a36ff59-5a25-4777-a8df-aabf6cf7edb0' 'HA-mariaDB-02' 'server' 'HA-mariaDB-02' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0035' 'compute' 'server' 'php-ospc_Database' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server php-ospc_Database"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'php-ospc_Database'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'php-ospc_Database' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'php-ospc_Database' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'php-ospc_Database' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '2c3305c8-ce6b-4863-a2a7-2c3d198f314c' 'php-ospc_Database' 'server' 'php-ospc_Database' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0036' 'compute' 'server' 'HA percona 8-03' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA percona 8-03"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA percona 8-03'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA percona 8-03' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA percona 8-03' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA percona 8-03' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '3fdbbf29-3a17-4bd3-9c86-0b74baf18624' 'HA percona 8-03' 'server' 'HA percona 8-03' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0037' 'compute' 'server' 'HA-mariaDB-03' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA-mariaDB-03"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA-mariaDB-03'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA-mariaDB-03' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA-mariaDB-03' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA-mariaDB-03' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '40a3b380-61cf-4a69-a474-d8f68d81c750' 'HA-mariaDB-03' 'server' 'HA-mariaDB-03' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0038' 'compute' 'server' 'Stack-05_Database' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Stack-05_Database"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Stack-05_Database'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Stack-05_Database' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Stack-05_Database' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Stack-05_Database' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '4d0ced3c-c5b5-4cf3-aa17-729cd74ce1e5' 'Stack-05_Database' 'server' 'Stack-05_Database' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0039' 'compute' 'server' 'sql' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server sql"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'sql'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'sql' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'sql' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'sql' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '5b05ea2c-c452-4069-97f3-f2bc80e7182f' 'sql' 'server' 'sql' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0040' 'compute' 'server' 'HA-Mysql8-02' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA-Mysql8-02"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA-Mysql8-02'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA-Mysql8-02' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA-Mysql8-02' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA-Mysql8-02' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '8e0d09e1-fce1-4343-b84c-cc2342b21310' 'HA-Mysql8-02' 'server' 'HA-Mysql8-02' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0041' 'compute' 'server' 'HA-mariaDB-01' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA-mariaDB-01"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA-mariaDB-01'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA-mariaDB-01' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA-mariaDB-01' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA-mariaDB-01' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '8fa64835-2ae3-492d-8d9b-7c19a40715b3' 'HA-mariaDB-01' 'server' 'HA-mariaDB-01' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0042' 'compute' 'server' 'Instance-05-03' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Instance-05-03"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Instance-05-03'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Instance-05-03' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Instance-05-03' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Instance-05-03' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'aa2c81fd-18de-4258-a5b5-5f23c44e8bb7' 'Instance-05-03' 'server' 'Instance-05-03' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0043' 'compute' 'server' 'HA percona 8-01' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA percona 8-01"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA percona 8-01'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA percona 8-01' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA percona 8-01' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA percona 8-01' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'b5101823-3e0c-4885-9ab9-ad06f40f5c64' 'HA percona 8-01' 'server' 'HA percona 8-01' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0044' 'compute' 'server' 'Instance-05-02' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Instance-05-02"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Instance-05-02'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Instance-05-02' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Instance-05-02' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Instance-05-02' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'c0e7d35e-1065-458e-b5f8-64fc68fcfa41' 'Instance-05-02' 'server' 'Instance-05-02' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0045' 'compute' 'server' 'HA-Mysql8-03' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA-Mysql8-03"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA-Mysql8-03'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA-Mysql8-03' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA-Mysql8-03' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA-Mysql8-03' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'c1b4a7aa-edc1-49b3-b6dc-cc136e52a06b' 'HA-Mysql8-03' 'server' 'HA-Mysql8-03' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0046' 'load_balancer' 'load_balancer' 'frontend- Load-Balancer-01' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=HTTP,listener_port=80,algorithm=LEAST_CONNECTIONS' <<'STEP_EOF'
echo "Ensuring load balancer frontend- Load-Balancer-01"
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
openstack loadbalancer show 'frontend- Load-Balancer-01' >/dev/null 2>&1 || openstack loadbalancer create --name 'frontend- Load-Balancer-01' --provider 'amphora' --vip-subnet-id "$VIP_SUBNET_ID"
wait_for_loadbalancer_active 'frontend- Load-Balancer-01'
openstack loadbalancer listener show 'frontend-load-balancer-01-listener' >/dev/null 2>&1 || openstack loadbalancer listener create --name 'frontend-load-balancer-01-listener' --protocol 'HTTP' --protocol-port 80 'frontend- Load-Balancer-01'
wait_for_loadbalancer_active 'frontend- Load-Balancer-01'
openstack loadbalancer pool show 'frontend-load-balancer-01-pool' >/dev/null 2>&1 || openstack loadbalancer pool create --name 'frontend-load-balancer-01-pool' --lb-algorithm 'LEAST_CONNECTIONS' --listener 'frontend-load-balancer-01-listener' --protocol 'HTTP'
wait_for_loadbalancer_active 'frontend- Load-Balancer-01'
STEP_EOF

# Map OSPC LB → FLEX LB
_MAP_LB_ID=$(openstack loadbalancer show -f value -c id 'frontend- Load-Balancer-01' 2>/dev/null || echo "")
_MAP_LB_VIP=$(openstack loadbalancer show -f value -c vip_address 'frontend- Load-Balancer-01' 2>/dev/null || echo "")
append_resource_map '' '' 'load_balancer' 'frontend- Load-Balancer-01' "$_MAP_LB_ID" "$_MAP_LB_VIP" "" 'created'

run_step 'step-0047' 'load_balancer' 'load_balancer_member' 'u24-FrontEnd' 'ensure_lb_pool_member' 'lb=frontend- Load-Balancer-01,pool=frontend-load-balancer-01-pool,member_port=80' <<'STEP_EOF'
wait_for_server_active 'u24-FrontEnd'
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
MEMBER_IP=$(wait_for_instance_ip_on_network 'u24-FrontEnd' "$PRIVATE_NETWORK" || true)
if [ -n "$MEMBER_IP" ]; then
  if openstack loadbalancer member list 'frontend-load-balancer-01-pool' -f value -c address 2>/dev/null | grep -Fx "$MEMBER_IP" >/dev/null 2>&1; then
    echo "LB member already exists for $MEMBER_IP on pool frontend-load-balancer-01-pool"
  else
    openstack loadbalancer member create --subnet-id "$VIP_SUBNET_ID" --address "$MEMBER_IP" --protocol-port 80 'frontend-load-balancer-01-pool' || true
  fi
else
  echo "Could not resolve member IP for u24-FrontEnd on $PRIVATE_NETWORK; skipping member add." >&2
fi
STEP_EOF

run_step 'step-0048' 'storage' 'volume' 'u24-postgresl-data-1' 'create_and_attach_volume' 'server=u24-postgresl,device=/dev/vdb,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'u24-postgresl'
echo "Creating data volume u24-postgresl-data-1 for instance u24-postgresl"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'u24-postgresl-data-1'
wait_for_volume_available 'u24-postgresl-data-1'
VOL_ID=$(openstack volume show -f value -c id 'u24-postgresl-data-1')
echo "Attaching volume u24-postgresl-data-1 to instance u24-postgresl at /dev/vdb (max 5 retries)"
attach_volume_with_retry 'u24-postgresl' "$VOL_ID" '/dev/vdb'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'u24-postgresl-data-1' 2>/dev/null || echo "")
append_resource_map 'd9b51e0a-f7ae-4678-9e18-2971089c6af7' 'u24-postgresl' 'volume' 'u24-postgresl-data-1' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0049' 'storage' 'volume' 'u24-frontend-data-1' 'create_and_attach_volume' 'server=u24-FrontEnd,device=/dev/vdc,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'u24-FrontEnd'
echo "Creating data volume u24-frontend-data-1 for instance u24-FrontEnd"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'u24-frontend-data-1'
wait_for_volume_available 'u24-frontend-data-1'
VOL_ID=$(openstack volume show -f value -c id 'u24-frontend-data-1')
echo "Attaching volume u24-frontend-data-1 to instance u24-FrontEnd at /dev/vdc (max 5 retries)"
attach_volume_with_retry 'u24-FrontEnd' "$VOL_ID" '/dev/vdc'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'u24-frontend-data-1' 2>/dev/null || echo "")
append_resource_map '7c7f7240-9973-43b6-9b14-bf4969806e86' 'u24-FrontEnd' 'volume' 'u24-frontend-data-1' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0050' 'storage' 'volume' 'u24-frontend-data-2' 'create_and_attach_volume' 'server=u24-FrontEnd,device=/dev/vdb,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'u24-FrontEnd'
echo "Creating data volume u24-frontend-data-2 for instance u24-FrontEnd"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'u24-frontend-data-2'
wait_for_volume_available 'u24-frontend-data-2'
VOL_ID=$(openstack volume show -f value -c id 'u24-frontend-data-2')
echo "Attaching volume u24-frontend-data-2 to instance u24-FrontEnd at /dev/vdb (max 5 retries)"
attach_volume_with_retry 'u24-FrontEnd' "$VOL_ID" '/dev/vdb'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'u24-frontend-data-2' 2>/dev/null || echo "")
append_resource_map '7c7f7240-9973-43b6-9b14-bf4969806e86' 'u24-FrontEnd' 'volume' 'u24-frontend-data-2' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0051' 'storage' 'volume' 'windows-server-2019re-data-1' 'create_and_attach_volume' 'server=Windows Server 2019Re,device=/dev/vdb,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Windows Server 2019Re'
echo "Creating data volume windows-server-2019re-data-1 for instance Windows Server 2019Re"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'windows-server-2019re-data-1'
wait_for_volume_available 'windows-server-2019re-data-1'
VOL_ID=$(openstack volume show -f value -c id 'windows-server-2019re-data-1')
echo "Attaching volume windows-server-2019re-data-1 to instance Windows Server 2019Re at /dev/vdb (max 5 retries)"
attach_volume_with_retry 'Windows Server 2019Re' "$VOL_ID" '/dev/vdb'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'windows-server-2019re-data-1' 2>/dev/null || echo "")
append_resource_map 'd8753e16-0039-4c04-993c-7e14be21e212' 'Windows Server 2019Re' 'volume' 'windows-server-2019re-data-1' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0052' 'storage' 'volume' 'win2019websql2019-data-1' 'create_and_attach_volume' 'server=win2019websql2019,device=/dev/vdb,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'win2019websql2019'
echo "Creating data volume win2019websql2019-data-1 for instance win2019websql2019"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'win2019websql2019-data-1'
wait_for_volume_available 'win2019websql2019-data-1'
VOL_ID=$(openstack volume show -f value -c id 'win2019websql2019-data-1')
echo "Attaching volume win2019websql2019-data-1 to instance win2019websql2019 at /dev/vdb (max 5 retries)"
attach_volume_with_retry 'win2019websql2019' "$VOL_ID" '/dev/vdb'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'win2019websql2019-data-1' 2>/dev/null || echo "")
append_resource_map '47f882bf-4d6d-41d6-baef-cfcc7a9c5e61' 'win2019websql2019' 'volume' 'win2019websql2019-data-1' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0053' 'storage' 'volume' 'windows-server-2016-sql-server-2019-data-1' 'create_and_attach_volume' 'server=Windows Server 2016 + SQL Server 2019,device=/dev/vdb,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'Windows Server 2016 + SQL Server 2019'
echo "Creating data volume windows-server-2016-sql-server-2019-data-1 for instance Windows Server 2016 + SQL Server 2019"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'windows-server-2016-sql-server-2019-data-1'
wait_for_volume_available 'windows-server-2016-sql-server-2019-data-1'
VOL_ID=$(openstack volume show -f value -c id 'windows-server-2016-sql-server-2019-data-1')
echo "Attaching volume windows-server-2016-sql-server-2019-data-1 to instance Windows Server 2016 + SQL Server 2019 at /dev/vdb (max 5 retries)"
attach_volume_with_retry 'Windows Server 2016 + SQL Server 2019' "$VOL_ID" '/dev/vdb'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'windows-server-2016-sql-server-2019-data-1' 2>/dev/null || echo "")
append_resource_map '741c63ea-e4ae-4048-b6cb-fc7b7716034e' 'Windows Server 2016 + SQL Server 2019' 'volume' 'windows-server-2016-sql-server-2019-data-1' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0054' 'storage' 'volume' 'u24backend-data-1' 'create_and_attach_volume' 'server=u24Backend,device=/dev/vdb,size_gb=75' <<'STEP_EOF'
wait_for_server_active 'u24Backend'
echo "Creating data volume u24backend-data-1 for instance u24Backend"
openstack volume create --size 75 --type "$VOLUME_TYPE" 'u24backend-data-1'
wait_for_volume_available 'u24backend-data-1'
VOL_ID=$(openstack volume show -f value -c id 'u24backend-data-1')
echo "Attaching volume u24backend-data-1 to instance u24Backend at /dev/vdb (max 5 retries)"
attach_volume_with_retry 'u24Backend' "$VOL_ID" '/dev/vdb'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'u24backend-data-1' 2>/dev/null || echo "")
append_resource_map '6b24fa27-fada-461b-b50a-41cb64e453ab' 'u24Backend' 'volume' 'u24backend-data-1' "$_MAP_VOL_ID" "" "" 'created'

echo "Deployment script finished."
echo "Step results: PASS=$STEP_PASS FAIL=$STEP_FAIL"
echo "Results CSV: $RESULTS_CSV"
echo "Resource mapping CSV: $RESOURCE_MAP_CSV"
if [ "$STEP_FAIL" -gt 0 ]; then
  echo "One or more deployment steps failed." >&2
  exit 2
fi
