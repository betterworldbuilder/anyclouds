#!/usr/bin/env bash
set -uo pipefail

PUBLIC_NETWORK='PUBLICNET'
PRIVATE_NETWORK='tenant-net'
SUBNET_NAME='tenant-subnet'
SUBNET_CIDR='10.60.0.0/24'
ROUTER_NAME='tenant-router'
SECURITY_GROUP='default'
VOLUME_TYPE='Performance'
KEY_NAME='ospc2flex'
SSH_PUB_KEY=''
FAIL_FAST=0
RESULTS_CSV='/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/1342314_tenant_deploy_results.csv'
RESOURCE_MAP_CSV='/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/1342314_tenant_deploy_resource_map.csv'
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

run_step 'step-0001' 'compute' 'server' 'jenkins' 'create_server_local_boot' 'image=Rocky Linux 8,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server jenkins"
openstack server create --flavor 'gp.5.4.4' --image 'Rocky Linux 8' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'jenkins'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'jenkins' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'jenkins' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'jenkins' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '55ee25c0-0fea-45c7-a800-8594ba587ba8' 'jenkins' 'server' 'jenkins' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0002' 'compute' 'server' 'debian11new' 'create_server_local_boot' 'image=Debian 11,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server debian11new"
openstack server create --flavor 'gp.5.2.2' --image 'Debian 11' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'debian11new'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'debian11new' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'debian11new' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'debian11new' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'cd6a356c-62fc-4763-aafc-ca342ec8f923' 'debian11new' 'server' 'debian11new' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0003' 'compute' 'server' 'dbian10new' 'create_server_local_boot' 'image=Debian 11,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server dbian10new"
openstack server create --flavor 'gp.5.2.2' --image 'Debian 11' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'dbian10new'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'dbian10new' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'dbian10new' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'dbian10new' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '9262a99e-6bd3-495d-bacd-06a015b29088' 'dbian10new' 'server' 'dbian10new' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0004' 'compute' 'server' 'u20' 'create_server_local_boot' 'image=Ubuntu 20.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server u20"
openstack server create --flavor 'gp.5.2.2' --image 'Ubuntu 20.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u20'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u20' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u20' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u20' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'f4dd8084-20c4-40a4-8784-7db8c6c5162a' 'u20' 'server' 'u20' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0005' 'compute' 'server' 'debian10' 'create_server_local_boot' 'image=Debian 11,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server debian10"
openstack server create --flavor 'gp.5.2.2' --image 'Debian 11' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'debian10'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'debian10' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'debian10' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'debian10' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '690a3cb9-2cd7-43ac-aa5d-16f1092b9ac2' 'debian10' 'server' 'debian10' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0006' 'compute' 'server' 'rocky9' 'create_server_local_boot' 'image=Rocky Linux 9,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server rocky9"
openstack server create --flavor 'gp.5.2.2' --image 'Rocky Linux 9' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'rocky9'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'rocky9' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'rocky9' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'rocky9' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '12962165-11ca-498c-8a2f-db69947f9264' 'rocky9' 'server' 'rocky9' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0007' 'compute' 'server' 'alma8' 'create_server_boot_from_volume' 'boot_volume_size_gb=50,source_boot_size_gb=50,image_min_disk_gb=20,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating boot volume for alma8"
openstack volume create --size 50 --type "$VOLUME_TYPE" --image 'AlmaLinux 8' 'boot-alma8'
wait_for_volume_available 'boot-alma8'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-alma8')
openstack server create --flavor 'gp.5.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'alma8'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'alma8' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'alma8' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'alma8' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'f4680994-c54f-473a-8549-b6fb1176088c' 'alma8' 'server' 'alma8' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0008' 'compute' 'server' 'dbian11' 'create_server_boot_from_volume' 'boot_volume_size_gb=50,source_boot_size_gb=50,image_min_disk_gb=20,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating boot volume for dbian11"
openstack volume create --size 50 --type "$VOLUME_TYPE" --image 'Debian 11' 'boot-dbian11'
wait_for_volume_available 'boot-dbian11'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-dbian11')
openstack server create --flavor 'gp.5.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'dbian11'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'dbian11' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'dbian11' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'dbian11' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '74ae2aed-ea59-49f4-8e1d-cca502d526b8' 'dbian11' 'server' 'dbian11' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0009' 'compute' 'server' 'dbian12' 'create_server_boot_from_volume' 'boot_volume_size_gb=50,source_boot_size_gb=50,image_min_disk_gb=20,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating boot volume for dbian12"
openstack volume create --size 50 --type "$VOLUME_TYPE" --image 'Debian 12' 'boot-dbian12'
wait_for_volume_available 'boot-dbian12'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-dbian12')
openstack server create --flavor 'gp.5.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'dbian12'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'dbian12' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'dbian12' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'dbian12' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '8d7309ea-f39c-417b-8f50-c28f76ffd9db' 'dbian12' 'server' 'dbian12' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0010' 'compute' 'server' 'u22' 'create_server_boot_from_volume' 'boot_volume_size_gb=50,source_boot_size_gb=50,image_min_disk_gb=20,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating boot volume for u22"
openstack volume create --size 50 --type "$VOLUME_TYPE" --image 'Ubuntu 22.04' 'boot-u22'
wait_for_volume_available 'boot-u22'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-u22')
openstack server create --flavor 'gp.5.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u22'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u22' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u22' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u22' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '3c37b506-7570-4d9d-8843-3629f65bcbda' 'u22' 'server' 'u22' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0011' 'compute' 'server' 'debianlaptopu24' 'create_server_boot_from_volume' 'boot_volume_size_gb=50,source_boot_size_gb=50,image_min_disk_gb=20,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating boot volume for debianlaptopu24"
openstack volume create --size 50 --type "$VOLUME_TYPE" --image 'Debian 12' 'boot-debianlaptopu24'
wait_for_volume_available 'boot-debianlaptopu24'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-debianlaptopu24')
openstack server create --flavor 'gp.5.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'debianlaptopu24'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'debianlaptopu24' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'debianlaptopu24' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'debianlaptopu24' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'e177369d-f3f2-4593-bfb1-d8837614ce57' 'debianlaptopu24' 'server' 'debianlaptopu24' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0012' 'compute' 'server' 'VMmigrator' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server VMmigrator"
openstack server create --flavor 'gp.5.8.16' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'VMmigrator'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'VMmigrator' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'VMmigrator' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'VMmigrator' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '4229bb9a-cc0e-4f4b-9142-949cb887cc50' 'VMmigrator' 'server' 'VMmigrator' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0013' 'compute' 'server' 'u24-FrontEndlaptou24' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server u24-FrontEndlaptou24"
openstack server create --flavor 'gp.5.4.8' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u24-FrontEndlaptou24'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u24-FrontEndlaptou24' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u24-FrontEndlaptou24' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u24-FrontEndlaptou24' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'e015f188-5e04-4af8-884b-d924375c82ea' 'u24-FrontEndlaptou24' 'server' 'u24-FrontEndlaptou24' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0014' 'compute' 'server' 'db-replica2' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server db-replica2"
openstack server create --flavor 'gp.5.4.8' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'db-replica2'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'db-replica2' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'db-replica2' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'db-replica2' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '0c0f8ab2-da94-4356-9bc0-ca13e0a14563' 'db-replica2' 'server' 'db-replica2' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0015' 'compute' 'server' 'db-replica1' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server db-replica1"
openstack server create --flavor 'gp.5.4.8' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'db-replica1'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'db-replica1' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'db-replica1' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'db-replica1' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '6f7faf71-b98b-4b2f-a99e-92da841318fa' 'db-replica1' 'server' 'db-replica1' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0016' 'compute' 'server' 'target flex dbaas' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server target flex dbaas"
openstack server create --flavor 'gp.5.4.8' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'target flex dbaas'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'target flex dbaas' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'target flex dbaas' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'target flex dbaas' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '64783844-672f-4c87-8bd5-dac19690875f' 'target flex dbaas' 'server' 'target flex dbaas' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0017' 'compute' 'server' 'Alma9' 'create_server_local_boot' 'image=AlmaLinux 9,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Alma9"
openstack server create --flavor 'gp.5.4.8' --image 'AlmaLinux 9' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Alma9'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Alma9' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Alma9' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Alma9' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'de2cc03b-b53a-4f32-8b1b-8a3c9d757069' 'Alma9' 'server' 'Alma9' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0018' 'compute' 'server' 'rocky8' 'create_server_local_boot' 'image=Rocky Linux 8,auth_mode=ssh_key' <<'STEP_EOF'
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

run_step 'step-0019' 'compute' 'server' 'ospc-jumpHost' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
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

run_step 'step-0020' 'compute' 'server' 'u24-postgresl' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
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

run_step 'step-0021' 'compute' 'server' 'Windows Server 2019Re' 'create_server_local_boot' 'image=Windows Server 2019,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating server Windows Server 2019Re"
openstack server create --flavor 'gp.5.2.4' --image 'Windows Server 2019' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password 'IHxswwOBzjptZc' 'Windows Server 2019Re'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Windows Server 2019Re' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Windows Server 2019Re' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Windows Server 2019Re' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'd8753e16-0039-4c04-993c-7e14be21e212' 'Windows Server 2019Re' 'server' 'Windows Server 2019Re' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0022' 'compute' 'server' 'win2019websql2019' 'create_server_local_boot' 'image=Windows Server 2019 with SQL 2019 Web,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating server win2019websql2019"
openstack server create --flavor 'gp.5.2.4' --image 'Windows Server 2019 with SQL 2019 Web' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password 'Ji7fRagQVsGzMQ' 'win2019websql2019'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'win2019websql2019' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'win2019websql2019' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'win2019websql2019' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '47f882bf-4d6d-41d6-baef-cfcc7a9c5e61' 'win2019websql2019' 'server' 'win2019websql2019' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0023' 'compute' 'server' 'Windows Server 2016 + SQL Server 2019' 'create_server_local_boot' 'image=Windows Server 2016,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating server Windows Server 2016 + SQL Server 2019"
openstack server create --flavor 'gp.5.2.4' --image 'Windows Server 2016' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password 'jafbZgqNLhE0ae' 'Windows Server 2016 + SQL Server 2019'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Windows Server 2016 + SQL Server 2019' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Windows Server 2016 + SQL Server 2019' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Windows Server 2016 + SQL Server 2019' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '741c63ea-e4ae-4048-b6cb-fc7b7716034e' 'Windows Server 2016 + SQL Server 2019' 'server' 'Windows Server 2016 + SQL Server 2019' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0024' 'compute' 'server' 'u24Backend' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
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

run_step 'step-0025' 'load_balancer' 'load_balancer' 'frontend- Load-Balancer-01' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=HTTP,listener_port=80,algorithm=LEAST_CONNECTIONS' <<'STEP_EOF'
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

run_step 'step-0026' 'load_balancer' 'load_balancer' 'u24backend' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=HTTP,listener_port=80,algorithm=LEAST_CONNECTIONS' <<'STEP_EOF'
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

run_step 'step-0027' 'load_balancer' 'load_balancer_member' 'Alma9' 'ensure_lb_pool_member' 'lb=u24backend,pool=u24backend-pool,member_port=80' <<'STEP_EOF'
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

run_step 'step-0028' 'load_balancer' 'load_balancer_member' 'u24Backend' 'ensure_lb_pool_member' 'lb=u24backend,pool=u24backend-pool,member_port=80' <<'STEP_EOF'
wait_for_server_active 'u24Backend'
VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")
MEMBER_IP=$(wait_for_instance_ip_on_network 'u24Backend' "$PRIVATE_NETWORK" || true)
if [ -n "$MEMBER_IP" ]; then
  if openstack loadbalancer member list 'u24backend-pool' -f value -c address 2>/dev/null | grep -Fx "$MEMBER_IP" >/dev/null 2>&1; then
    echo "LB member already exists for $MEMBER_IP on pool u24backend-pool"
  else
    openstack loadbalancer member create --subnet-id "$VIP_SUBNET_ID" --address "$MEMBER_IP" --protocol-port 80 'u24backend-pool' || true
  fi
else
  echo "Could not resolve member IP for u24Backend on $PRIVATE_NETWORK; skipping member add." >&2
fi
STEP_EOF

run_step 'step-0029' 'load_balancer' 'load_balancer' 'DB_loadbalancer MYSQL' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=MYSQL,listener_port=3306,algorithm=ROUND_ROBIN' <<'STEP_EOF'
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

run_step 'step-0030' 'load_balancer' 'load_balancer' 'LBmariaDB' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=MYSQL,listener_port=3306,algorithm=LEAST_CONNECTIONS' <<'STEP_EOF'
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

run_step 'step-0031' 'load_balancer' 'load_balancer' 'perconaLB' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=MYSQL,listener_port=3306,algorithm=LEAST_CONNECTIONS' <<'STEP_EOF'
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

run_step 'step-0032' 'storage' 'volume' 'vmmigrator-data-1' 'create_and_attach_volume' 'server=VMmigrator,device=/dev/vdb,size_gb=750' <<'STEP_EOF'
wait_for_server_active 'VMmigrator'
echo "Creating data volume vmmigrator-data-1 for instance VMmigrator"
openstack volume create --size 750 --type "$VOLUME_TYPE" 'vmmigrator-data-1'
wait_for_volume_available 'vmmigrator-data-1'
VOL_ID=$(openstack volume show -f value -c id 'vmmigrator-data-1')
echo "Attaching volume vmmigrator-data-1 to instance VMmigrator at /dev/vdb (max 5 retries)"
attach_volume_with_retry 'VMmigrator' "$VOL_ID" '/dev/vdb'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'vmmigrator-data-1' 2>/dev/null || echo "")
append_resource_map '4229bb9a-cc0e-4f4b-9142-949cb887cc50' 'VMmigrator' 'volume' 'vmmigrator-data-1' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0033' 'storage' 'volume' 'ospc-jumphost-data-1' 'create_and_attach_volume' 'server=ospc-jumpHost,device=/dev/vdc,size_gb=200' <<'STEP_EOF'
wait_for_server_active 'ospc-jumpHost'
echo "Creating data volume ospc-jumphost-data-1 for instance ospc-jumpHost"
openstack volume create --size 200 --type "$VOLUME_TYPE" 'ospc-jumphost-data-1'
wait_for_volume_available 'ospc-jumphost-data-1'
VOL_ID=$(openstack volume show -f value -c id 'ospc-jumphost-data-1')
echo "Attaching volume ospc-jumphost-data-1 to instance ospc-jumpHost at /dev/vdc (max 5 retries)"
attach_volume_with_retry 'ospc-jumpHost' "$VOL_ID" '/dev/vdc'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'ospc-jumphost-data-1' 2>/dev/null || echo "")
append_resource_map '39e0d438-46cf-47c3-88e6-5a5f84859a84' 'ospc-jumpHost' 'volume' 'ospc-jumphost-data-1' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0034' 'storage' 'volume' 'ospc-jumphost-data-2' 'create_and_attach_volume' 'server=ospc-jumpHost,device=/dev/vdb,size_gb=500' <<'STEP_EOF'
wait_for_server_active 'ospc-jumpHost'
echo "Creating data volume ospc-jumphost-data-2 for instance ospc-jumpHost"
openstack volume create --size 500 --type "$VOLUME_TYPE" 'ospc-jumphost-data-2'
wait_for_volume_available 'ospc-jumphost-data-2'
VOL_ID=$(openstack volume show -f value -c id 'ospc-jumphost-data-2')
echo "Attaching volume ospc-jumphost-data-2 to instance ospc-jumpHost at /dev/vdb (max 5 retries)"
attach_volume_with_retry 'ospc-jumpHost' "$VOL_ID" '/dev/vdb'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'ospc-jumphost-data-2' 2>/dev/null || echo "")
append_resource_map '39e0d438-46cf-47c3-88e6-5a5f84859a84' 'ospc-jumpHost' 'volume' 'ospc-jumphost-data-2' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0035' 'storage' 'volume' 'u24-postgresl-data-1' 'create_and_attach_volume' 'server=u24-postgresl,device=/dev/vdb,size_gb=75' <<'STEP_EOF'
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

run_step 'step-0036' 'storage' 'volume' 'windows-server-2019re-data-1' 'create_and_attach_volume' 'server=Windows Server 2019Re,device=/dev/vdb,size_gb=75' <<'STEP_EOF'
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

run_step 'step-0037' 'storage' 'volume' 'win2019websql2019-data-1' 'create_and_attach_volume' 'server=win2019websql2019,device=/dev/vdb,size_gb=75' <<'STEP_EOF'
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

run_step 'step-0038' 'storage' 'volume' 'windows-server-2016-sql-server-2019-data-1' 'create_and_attach_volume' 'server=Windows Server 2016 + SQL Server 2019,device=/dev/vdb,size_gb=75' <<'STEP_EOF'
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

run_step 'step-0039' 'storage' 'volume' 'u24backend-data-1' 'create_and_attach_volume' 'server=u24Backend,device=/dev/vdb,size_gb=75' <<'STEP_EOF'
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
