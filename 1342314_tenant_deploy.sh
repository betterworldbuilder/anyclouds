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

run_step 'step-0001' 'compute' 'server' 'bigjumpiad2' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server bigjumpiad2"
openstack server create --flavor 'gp.0.16.64' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'bigjumpiad2'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'bigjumpiad2' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'bigjumpiad2' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'bigjumpiad2' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '77fbe978-4b0b-43cd-8722-47a495827d49' 'bigjumpiad2' 'server' 'bigjumpiad2' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0002' 'compute' 'floating_ip' 'bigjumpiad2' 'assign_floating_ip' 'server=bigjumpiad2,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'bigjumpiad2'
if server_has_floating_ip 'bigjumpiad2'; then
  echo "Server bigjumpiad2 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'bigjumpiad2' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0003' 'compute' 'server' 'Bigjim-iad' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Bigjim-iad"
openstack server create --flavor 'gp.0.16.64' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Bigjim-iad'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Bigjim-iad' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Bigjim-iad' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Bigjim-iad' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'server' 'Bigjim-iad' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0004' 'compute' 'floating_ip' 'Bigjim-iad' 'assign_floating_ip' 'server=Bigjim-iad,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
if server_has_floating_ip 'Bigjim-iad'; then
  echo "Server Bigjim-iad already has a floating IP; skipping assignment."
else
  assign_floating_ip 'Bigjim-iad' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0005' 'compute' 'server' 'jenkins' 'create_server_local_boot' 'image=Rocky Linux 8,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server jenkins"
openstack server create --flavor 'gp.0.4.4' --image 'Rocky Linux 8' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'jenkins'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'jenkins' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'jenkins' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'jenkins' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '107d8faf-4a18-4d50-88c9-f49042843f18' 'jenkins' 'server' 'jenkins' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0006' 'compute' 'floating_ip' 'jenkins' 'assign_floating_ip' 'server=jenkins,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'jenkins'
if server_has_floating_ip 'jenkins'; then
  echo "Server jenkins already has a floating IP; skipping assignment."
else
  assign_floating_ip 'jenkins' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0007' 'compute' 'server' 'drupalphp' 'create_server_local_boot' 'image=Rocky Linux 8,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server drupalphp"
openstack server create --flavor 'gp.0.4.4' --image 'Rocky Linux 8' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'drupalphp'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'drupalphp' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'drupalphp' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'drupalphp' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'eb026661-818d-49f2-9886-6e5186984edb' 'drupalphp' 'server' 'drupalphp' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0008' 'compute' 'floating_ip' 'drupalphp' 'assign_floating_ip' 'server=drupalphp,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'drupalphp'
if server_has_floating_ip 'drupalphp'; then
  echo "Server drupalphp already has a floating IP; skipping assignment."
else
  assign_floating_ip 'drupalphp' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0009' 'compute' 'server' 'lamp' 'create_server_local_boot' 'image=Rocky Linux 8,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server lamp"
openstack server create --flavor 'gp.0.4.4' --image 'Rocky Linux 8' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'lamp'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'lamp' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'lamp' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'lamp' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '09a734ca-8929-42be-803b-d6b6504c4d93' 'lamp' 'server' 'lamp' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0010' 'compute' 'floating_ip' 'lamp' 'assign_floating_ip' 'server=lamp,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'lamp'
if server_has_floating_ip 'lamp'; then
  echo "Server lamp already has a floating IP; skipping assignment."
else
  assign_floating_ip 'lamp' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0011' 'compute' 'server' 'centos7' 'create_server_boot_from_volume' 'boot_volume_size_gb=80,source_boot_size_gb=80,image_min_disk_gb=20,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating boot volume for centos7"
openstack volume create --size 80 --type "$VOLUME_TYPE" --image 'Rocky Linux 8' 'boot-centos7'
wait_for_volume_available 'boot-centos7'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-centos7')
openstack server create --flavor 'gp.0.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'centos7'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'centos7' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'centos7' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'centos7' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '8daf4f80-47bc-41a6-bbcb-cd5974193b41' 'centos7' 'server' 'centos7' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0012' 'compute' 'floating_ip' 'centos7' 'assign_floating_ip' 'server=centos7,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'centos7'
if server_has_floating_ip 'centos7'; then
  echo "Server centos7 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'centos7' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0013' 'compute' 'server' 'win2019' 'create_server_boot_from_volume' 'boot_volume_size_gb=80,source_boot_size_gb=50,image_min_disk_gb=80,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating boot volume for win2019"
openstack volume create --size 80 --type "$VOLUME_TYPE" --image 'Windows Server 2019' 'boot-win2019'
wait_for_volume_available 'boot-win2019'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-win2019')
openstack server create --flavor 'gp.0.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password 'LzhHrj3dnLWHnC' 'win2019'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'win2019' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'win2019' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'win2019' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'aaabe292-762c-4847-b249-b181ead4737c' 'win2019' 'server' 'win2019' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0014' 'compute' 'floating_ip' 'win2019' 'assign_floating_ip' 'server=win2019,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'win2019'
if server_has_floating_ip 'win2019'; then
  echo "Server win2019 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'win2019' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0015' 'compute' 'server' 'win2019' 'create_server_local_boot' 'image=Windows Server 2019,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating server win2019"
openstack server create --flavor 'gp.0.2.4' --image 'Windows Server 2019' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password 'ZI7Ccp50raukkm' 'win2019'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'win2019' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'win2019' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'win2019' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'b7e292ba-84d3-4871-9180-c020a43bf312' 'win2019' 'server' 'win2019' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0016' 'compute' 'floating_ip' 'win2019' 'assign_floating_ip' 'server=win2019,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'win2019'
if server_has_floating_ip 'win2019'; then
  echo "Server win2019 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'win2019' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0017' 'compute' 'server' 'windows2016' 'create_server_local_boot' 'image=Windows Server 2016,auth_mode=windows_password' <<'STEP_EOF'
echo "Creating server windows2016"
openstack server create --flavor 'gp.0.2.4' --image 'Windows Server 2016' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" --password 'vdP8ZlP5GkxmXt' 'windows2016'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'windows2016' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'windows2016' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'windows2016' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '1850f963-95f6-477f-97da-81e5b404694f' 'windows2016' 'server' 'windows2016' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0018' 'compute' 'floating_ip' 'windows2016' 'assign_floating_ip' 'server=windows2016,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'windows2016'
if server_has_floating_ip 'windows2016'; then
  echo "Server windows2016 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'windows2016' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0019' 'compute' 'server' 'debian11new' 'create_server_local_boot' 'image=Debian 11,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server debian11new"
openstack server create --flavor 'gp.0.2.2' --image 'Debian 11' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'debian11new'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'debian11new' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'debian11new' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'debian11new' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'cd6a356c-62fc-4763-aafc-ca342ec8f923' 'debian11new' 'server' 'debian11new' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0020' 'compute' 'floating_ip' 'debian11new' 'assign_floating_ip' 'server=debian11new,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'debian11new'
if server_has_floating_ip 'debian11new'; then
  echo "Server debian11new already has a floating IP; skipping assignment."
else
  assign_floating_ip 'debian11new' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0021' 'compute' 'server' 'dbian10new' 'create_server_local_boot' 'image=Debian 11,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server dbian10new"
openstack server create --flavor 'gp.0.2.2' --image 'Debian 11' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'dbian10new'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'dbian10new' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'dbian10new' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'dbian10new' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '9262a99e-6bd3-495d-bacd-06a015b29088' 'dbian10new' 'server' 'dbian10new' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0022' 'compute' 'floating_ip' 'dbian10new' 'assign_floating_ip' 'server=dbian10new,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'dbian10new'
if server_has_floating_ip 'dbian10new'; then
  echo "Server dbian10new already has a floating IP; skipping assignment."
else
  assign_floating_ip 'dbian10new' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0023' 'compute' 'server' 'u20' 'create_server_local_boot' 'image=Ubuntu 20.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server u20"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 20.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u20'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u20' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u20' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u20' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'f4dd8084-20c4-40a4-8784-7db8c6c5162a' 'u20' 'server' 'u20' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0024' 'compute' 'floating_ip' 'u20' 'assign_floating_ip' 'server=u20,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'u20'
if server_has_floating_ip 'u20'; then
  echo "Server u20 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'u20' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0025' 'compute' 'server' 'debian10' 'create_server_local_boot' 'image=Debian 11,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server debian10"
openstack server create --flavor 'gp.0.2.2' --image 'Debian 11' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'debian10'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'debian10' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'debian10' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'debian10' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '690a3cb9-2cd7-43ac-aa5d-16f1092b9ac2' 'debian10' 'server' 'debian10' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0026' 'compute' 'floating_ip' 'debian10' 'assign_floating_ip' 'server=debian10,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'debian10'
if server_has_floating_ip 'debian10'; then
  echo "Server debian10 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'debian10' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0027' 'compute' 'server' 'rocky9' 'create_server_local_boot' 'image=Rocky Linux 9,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server rocky9"
openstack server create --flavor 'gp.0.2.2' --image 'Rocky Linux 9' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'rocky9'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'rocky9' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'rocky9' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'rocky9' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '12962165-11ca-498c-8a2f-db69947f9264' 'rocky9' 'server' 'rocky9' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0028' 'compute' 'floating_ip' 'rocky9' 'assign_floating_ip' 'server=rocky9,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'rocky9'
if server_has_floating_ip 'rocky9'; then
  echo "Server rocky9 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'rocky9' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0029' 'compute' 'server' 'alma8' 'create_server_boot_from_volume' 'boot_volume_size_gb=50,source_boot_size_gb=50,image_min_disk_gb=20,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating boot volume for alma8"
openstack volume create --size 50 --type "$VOLUME_TYPE" --image 'AlmaLinux 8' 'boot-alma8'
wait_for_volume_available 'boot-alma8'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-alma8')
openstack server create --flavor 'gp.0.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'alma8'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'alma8' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'alma8' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'alma8' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'f4680994-c54f-473a-8549-b6fb1176088c' 'alma8' 'server' 'alma8' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0030' 'compute' 'floating_ip' 'alma8' 'assign_floating_ip' 'server=alma8,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'alma8'
if server_has_floating_ip 'alma8'; then
  echo "Server alma8 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'alma8' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0031' 'compute' 'server' 'dbian12' 'create_server_boot_from_volume' 'boot_volume_size_gb=50,source_boot_size_gb=50,image_min_disk_gb=20,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating boot volume for dbian12"
openstack volume create --size 50 --type "$VOLUME_TYPE" --image 'Debian 12' 'boot-dbian12'
wait_for_volume_available 'boot-dbian12'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-dbian12')
openstack server create --flavor 'gp.0.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'dbian12'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'dbian12' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'dbian12' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'dbian12' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '8d7309ea-f39c-417b-8f50-c28f76ffd9db' 'dbian12' 'server' 'dbian12' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0032' 'compute' 'floating_ip' 'dbian12' 'assign_floating_ip' 'server=dbian12,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'dbian12'
if server_has_floating_ip 'dbian12'; then
  echo "Server dbian12 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'dbian12' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0033' 'compute' 'server' 'u22' 'create_server_boot_from_volume' 'boot_volume_size_gb=50,source_boot_size_gb=50,image_min_disk_gb=20,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating boot volume for u22"
openstack volume create --size 50 --type "$VOLUME_TYPE" --image 'Ubuntu 22.04' 'boot-u22'
wait_for_volume_available 'boot-u22'
BOOT_VOL_ID=$(openstack volume show -f value -c id 'boot-u22')
openstack server create --flavor 'gp.0.2.4' --volume "$BOOT_VOL_ID" --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'u22'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'u22' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'u22' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'u22' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '3c37b506-7570-4d9d-8843-3629f65bcbda' 'u22' 'server' 'u22' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0034' 'compute' 'floating_ip' 'u22' 'assign_floating_ip' 'server=u22,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'u22'
if server_has_floating_ip 'u22'; then
  echo "Server u22 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'u22' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0035' 'compute' 'server' 'Alma9' 'create_server_local_boot' 'image=AlmaLinux 9,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Alma9"
openstack server create --flavor 'gp.0.4.8' --image 'AlmaLinux 9' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Alma9'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Alma9' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Alma9' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Alma9' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map 'de2cc03b-b53a-4f32-8b1b-8a3c9d757069' 'Alma9' 'server' 'Alma9' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0036' 'compute' 'floating_ip' 'Alma9' 'assign_floating_ip' 'server=Alma9,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'Alma9'
if server_has_floating_ip 'Alma9'; then
  echo "Server Alma9 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'Alma9' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0037' 'compute' 'server' 'rocky8' 'create_server_local_boot' 'image=Rocky Linux 8,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server rocky8"
openstack server create --flavor 'gp.0.4.8' --image 'Rocky Linux 8' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'rocky8'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'rocky8' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'rocky8' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'rocky8' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '7afcc45d-4080-475e-a771-8ee1f265ef5c' 'rocky8' 'server' 'rocky8' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0038' 'compute' 'floating_ip' 'rocky8' 'assign_floating_ip' 'server=rocky8,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'rocky8'
if server_has_floating_ip 'rocky8'; then
  echo "Server rocky8 already has a floating IP; skipping assignment."
else
  assign_floating_ip 'rocky8' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0039' 'compute' 'server' 'ospc-jumpHost' 'create_server_local_boot' 'image=Ubuntu 24.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server ospc-jumpHost"
openstack server create --flavor 'gp.0.4.4' --image 'Ubuntu 24.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'ospc-jumpHost'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'ospc-jumpHost' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'ospc-jumpHost' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'ospc-jumpHost' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '39e0d438-46cf-47c3-88e6-5a5f84859a84' 'ospc-jumpHost' 'server' 'ospc-jumpHost' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0040' 'compute' 'floating_ip' 'ospc-jumpHost' 'assign_floating_ip' 'server=ospc-jumpHost,network=PUBLICNET' <<'STEP_EOF'
wait_for_server_active 'ospc-jumpHost'
if server_has_floating_ip 'ospc-jumpHost'; then
  echo "Server ospc-jumpHost already has a floating IP; skipping assignment."
else
  assign_floating_ip 'ospc-jumpHost' 'PUBLICNET'
fi
STEP_EOF

run_step 'step-0041' 'compute' 'server' 'HA percona 8-02' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA percona 8-02"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA percona 8-02'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA percona 8-02' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA percona 8-02' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA percona 8-02' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '0651b25a-9810-41d2-ac00-d30aae53fcdc' 'HA percona 8-02' 'server' 'HA percona 8-02' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0042' 'compute' 'server' 'drupal' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server drupal"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'drupal'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'drupal' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'drupal' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'drupal' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '0e0c1ccf-e8be-4e40-8e04-772307364118' 'drupal' 'server' 'drupal' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0043' 'compute' 'server' 'dbaasmariadb' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server dbaasmariadb"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'dbaasmariadb'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'dbaasmariadb' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'dbaasmariadb' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'dbaasmariadb' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '1456f7cd-0080-45e8-9617-cb797ba2ee97' 'dbaasmariadb' 'server' 'dbaasmariadb' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0044' 'compute' 'server' 'HA-Mysql8-01' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA-Mysql8-01"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA-Mysql8-01'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA-Mysql8-01' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA-Mysql8-01' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA-Mysql8-01' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '15794001-4db3-41bf-adbd-a00a149d02d6' 'HA-Mysql8-01' 'server' 'HA-Mysql8-01' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0045' 'compute' 'server' 'HA-mariaDB-02' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA-mariaDB-02"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA-mariaDB-02'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA-mariaDB-02' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA-mariaDB-02' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA-mariaDB-02' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '1a36ff59-5a25-4777-a8df-aabf6cf7edb0' 'HA-mariaDB-02' 'server' 'HA-mariaDB-02' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0046' 'compute' 'server' 'drupalphp_Database' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server drupalphp_Database"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'drupalphp_Database'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'drupalphp_Database' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'drupalphp_Database' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'drupalphp_Database' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '2c8023c1-bc51-4a07-96b6-8a075250cc21' 'drupalphp_Database' 'server' 'drupalphp_Database' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0047' 'compute' 'server' 'HA percona 8-03' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA percona 8-03"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA percona 8-03'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA percona 8-03' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA percona 8-03' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA percona 8-03' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '3fdbbf29-3a17-4bd3-9c86-0b74baf18624' 'HA percona 8-03' 'server' 'HA percona 8-03' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0048' 'compute' 'server' 'HA-mariaDB-03' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HA-mariaDB-03"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HA-mariaDB-03'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HA-mariaDB-03' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HA-mariaDB-03' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HA-mariaDB-03' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '40a3b380-61cf-4a69-a474-d8f68d81c750' 'HA-mariaDB-03' 'server' 'HA-mariaDB-03' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0049' 'compute' 'server' 'lamp_Database' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server lamp_Database"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'lamp_Database'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'lamp_Database' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'lamp_Database' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'lamp_Database' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '4579ebd6-0409-4ba3-86dc-83e94629dd6d' 'lamp_Database' 'server' 'lamp_Database' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0050' 'compute' 'server' 'HAdbaasSql-03' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HAdbaasSql-03"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HAdbaasSql-03'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HAdbaasSql-03' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HAdbaasSql-03' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HAdbaasSql-03' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '4988843f-7f1b-4a12-9a97-a5fefc011970' 'HAdbaasSql-03' 'server' 'HAdbaasSql-03' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0051' 'compute' 'server' 'Stack-05_Database' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Stack-05_Database"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Stack-05_Database'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Stack-05_Database' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Stack-05_Database' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Stack-05_Database' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '4d0ced3c-c5b5-4cf3-aa17-729cd74ce1e5' 'Stack-05_Database' 'server' 'Stack-05_Database' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0052' 'compute' 'server' 'HAmysql-01' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server HAmysql-01"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'HAmysql-01'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'HAmysql-01' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'HAmysql-01' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'HAmysql-01' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '4d3ba66a-081c-411a-ba88-c5d3eae98644' 'HAmysql-01' 'server' 'HAmysql-01' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0053' 'compute' 'server' 'mariad1' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server mariad1"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'mariad1'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'mariad1' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'mariad1' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'mariad1' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '4ddfa7e3-7dc4-46b0-9dcb-35ff8d85a92e' 'mariad1' 'server' 'mariad1' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0054' 'compute' 'server' 'hadbaas-vip-03' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server hadbaas-vip-03"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'hadbaas-vip-03'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'hadbaas-vip-03' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'hadbaas-vip-03' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'hadbaas-vip-03' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '4e15dd55-7c7c-4d08-9d2e-055fb7060d59' 'hadbaas-vip-03' 'server' 'hadbaas-vip-03' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0055' 'compute' 'server' 'Instance-21' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Instance-21"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Instance-21'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Instance-21' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Instance-21' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Instance-21' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '53ed4836-2719-4058-b084-5ca6cffbf2b4' 'Instance-21' 'server' 'Instance-21' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0056' 'compute' 'server' 'mysql8instance' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server mysql8instance"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'mysql8instance'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'mysql8instance' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'mysql8instance' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'mysql8instance' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '5800f484-5abf-4ba3-97ad-fdf2645e9e07' 'mysql8instance' 'server' 'mysql8instance' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0057' 'compute' 'server' 'sql' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server sql"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'sql'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'sql' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'sql' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'sql' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '5b05ea2c-c452-4069-97f3-f2bc80e7182f' 'sql' 'server' 'sql' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0058' 'compute' 'server' 'Mariadb' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Mariadb"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Mariadb'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Mariadb' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Mariadb' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Mariadb' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '5c916b27-aa26-4a6e-a488-64d6386b90c9' 'Mariadb' 'server' 'Mariadb' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0059' 'compute' 'server' 'hadbaas-vip-01' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server hadbaas-vip-01"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'hadbaas-vip-01'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'hadbaas-vip-01' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'hadbaas-vip-01' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'hadbaas-vip-01' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '6f7cf30a-1833-49d1-a500-059820a40333' 'hadbaas-vip-01' 'server' 'hadbaas-vip-01' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0060' 'compute' 'server' 'Instance-20' 'create_server_local_boot' 'image=Ubuntu 22.04,auth_mode=ssh_key' <<'STEP_EOF'
echo "Creating server Instance-20"
openstack server create --flavor 'gp.0.2.2' --image 'Ubuntu 22.04' --network "$PRIVATE_NETWORK" --security-group "$SECURITY_GROUP" ${KEY_NAME:+--key-name "$KEY_NAME"} 'Instance-20'
STEP_EOF

# Map OSPC server → FLEX server
_MAP_FLEX_ID=$(openstack server show -f value -c id 'Instance-20' 2>/dev/null || echo "")
_MAP_FLEX_PRIV=$(instance_ip_on_network 'Instance-20' "$PRIVATE_NETWORK" 2>/dev/null || echo "")
_MAP_FLEX_FLOAT=$(openstack floating ip list --server 'Instance-20' -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo "")
_MAP_STATUS="created"
[ -z "$_MAP_FLEX_ID" ] && _MAP_STATUS="failed"
append_resource_map '7a350577-6f75-48fc-aa8a-fa08a7a38664' 'Instance-20' 'server' 'Instance-20' "$_MAP_FLEX_ID" "$_MAP_FLEX_PRIV" "$_MAP_FLEX_FLOAT" "$_MAP_STATUS"

run_step 'step-0061' 'load_balancer' 'load_balancer' 'frontend- Load-Balancer-01' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=HTTP,listener_port=80,algorithm=LEAST_CONNECTIONS' <<'STEP_EOF'
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

run_step 'step-0062' 'load_balancer' 'load_balancer' 'u24backend' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=HTTP,listener_port=80,algorithm=LEAST_CONNECTIONS' <<'STEP_EOF'
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

run_step 'step-0063' 'load_balancer' 'load_balancer_member' 'Alma9' 'ensure_lb_pool_member' 'lb=u24backend,pool=u24backend-pool,member_port=80' <<'STEP_EOF'
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

run_step 'step-0064' 'load_balancer' 'load_balancer' 'DB_loadbalancer MYSQL' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=MYSQL,listener_port=3306,algorithm=ROUND_ROBIN' <<'STEP_EOF'
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

run_step 'step-0065' 'load_balancer' 'load_balancer' 'LBmariaDB' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=MYSQL,listener_port=3306,algorithm=LEAST_CONNECTIONS' <<'STEP_EOF'
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

run_step 'step-0066' 'load_balancer' 'load_balancer' 'perconaLB' 'create_or_reuse_lb_stack' 'provider=amphora,protocol=MYSQL,listener_port=3306,algorithm=LEAST_CONNECTIONS' <<'STEP_EOF'
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

run_step 'step-0067' 'storage' 'volume' 'bigjim-iad-data-1' 'create_and_attach_volume' 'server=Bigjim-iad,device=/dev/vdb,size_gb=500' <<'STEP_EOF'
wait_for_server_active 'Bigjim-iad'
echo "Creating data volume bigjim-iad-data-1 for instance Bigjim-iad"
openstack volume create --size 500 --type "$VOLUME_TYPE" 'bigjim-iad-data-1'
wait_for_volume_available 'bigjim-iad-data-1'
VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-1')
echo "Attaching volume bigjim-iad-data-1 to instance Bigjim-iad at /dev/vdb (max 5 retries)"
attach_volume_with_retry 'Bigjim-iad' "$VOL_ID" '/dev/vdb'
STEP_EOF

# Map OSPC volume → FLEX volume
_MAP_VOL_ID=$(openstack volume show -f value -c id 'bigjim-iad-data-1' 2>/dev/null || echo "")
append_resource_map '467cf940-3b81-43d6-985f-3cbe90ed98e9' 'Bigjim-iad' 'volume' 'bigjim-iad-data-1' "$_MAP_VOL_ID" "" "" 'created'

run_step 'step-0068' 'storage' 'volume' 'ospc-jumphost-data-1' 'create_and_attach_volume' 'server=ospc-jumpHost,device=/dev/vdc,size_gb=200' <<'STEP_EOF'
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

run_step 'step-0069' 'storage' 'volume' 'ospc-jumphost-data-2' 'create_and_attach_volume' 'server=ospc-jumpHost,device=/dev/vdb,size_gb=500' <<'STEP_EOF'
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

echo "Deployment script finished."
echo "Step results: PASS=$STEP_PASS FAIL=$STEP_FAIL IGNORED=$STEP_IGNORED"
echo "Results CSV: $RESULTS_CSV"
echo "Resource mapping CSV: $RESOURCE_MAP_CSV"
if [ "$STEP_FAIL" -gt 0 ]; then
  echo "One or more deployment steps failed." >&2
  exit 2
fi
