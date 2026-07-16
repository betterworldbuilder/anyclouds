#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 ORGANIZATION/CLUSTER --yes" >&2
  exit 2
}

target="${1:-}"
confirmation="${2:-}"
[[ "$target" =~ ^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*$ ]] || usage
[[ "$confirmation" == "--yes" ]] || {
  echo "[BLOCKED] Destructive cleanup requires --yes." >&2
  exit 2
}

org="${target%%/*}"
cluster="${target#*/}"
config_dir="${OPENCENTER_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencenter}"
infra_dir="$config_dir/clusters/gitops/$org/infrastructure/clusters/$cluster"
state_dir="$infra_dir/.opentofu-local-$cluster"
state_file="$state_dir/terraform.tfstate"
backup_file="$state_file.backup"
tofu_lock="$state_dir/.terraform.tfstate.lock.info"

command -v opencenter >/dev/null || { echo "[BLOCKED] opencenter is not installed." >&2; exit 3; }
command -v openstack >/dev/null || { echo "[BLOCKED] openstack CLI is not installed." >&2; exit 3; }
[[ -d "$infra_dir" ]] || { echo "[BLOCKED] Generated infrastructure directory not found: $infra_dir" >&2; exit 4; }

if pgrep -x tofu >/dev/null 2>&1 || pgrep -x terraform >/dev/null 2>&1; then
  echo "[BLOCKED] OpenTofu/Terraform is still running. Stop or finish it before destroying the cluster." >&2
  exit 5
fi

echo "[1/5] Loading cluster-scoped OpenStack credentials..."
# opencenter owns secret retrieval; do not print this output or enable shell tracing.
# Clear credentials inherited by the dashboard service so openstack cannot select
# password authentication when this cluster exports an application credential.
unset OS_AUTH_TYPE OS_USERNAME OS_USER_ID OS_PASSWORD OS_TOKEN
unset OS_PROJECT_ID OS_PROJECT_NAME OS_PROJECT_DOMAIN_ID OS_PROJECT_DOMAIN_NAME
# Only import OpenStack variables. Some CLI builds also emit an unquoted PATH,
# which is invalid when WSL inherits Windows paths containing spaces.
eval "$(opencenter cluster env "$target" --shell bash | grep '^export OS_')"
if [[ -n "${OS_APPLICATION_CREDENTIAL_ID:-}" && -n "${OS_APPLICATION_CREDENTIAL_SECRET:-}" ]]; then
  export OS_AUTH_TYPE=v3applicationcredential
  unset OS_PROJECT_ID OS_PROJECT_NAME OS_PROJECT_DOMAIN_ID OS_PROJECT_DOMAIN_NAME
fi
openstack token issue -f value -c id >/dev/null

echo "[2/5] Checking interrupted OpenTofu state..."
if [[ ! -s "$state_file" ]]; then
  [[ -s "$backup_file" ]] || {
    echo "[BLOCKED] OpenTofu state is empty and no non-empty backup exists." >&2
    exit 6
  }
  python3 - "$backup_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    state = json.load(stream)
if not isinstance(state.get("resources"), list) or not state["resources"]:
    raise SystemExit("[BLOCKED] OpenTofu backup has no managed resources.")
PY
  if [[ -e "$state_file" ]]; then
    mv -- "$state_file" "$state_file.interrupted-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  cp --preserve=mode,timestamps -- "$backup_file" "$state_file"
  echo "Recovered the last valid OpenTofu state backup."
fi
rm -f -- "$tofu_lock"

echo "[3/5] Finding cluster VMs, including resources orphaned by an interrupted apply..."
mapfile -t server_ids < <(
  openstack server list --name "$cluster-" -f value -c ID -c Name |
    awk -v prefix="$cluster-" 'index($2, prefix) == 1 { print $1 }'
)
if ((${#server_ids[@]})); then
  echo "Deleting ${#server_ids[@]} cluster VM(s) and waiting for Nova cleanup..."
  openstack server delete --wait "${server_ids[@]}"
else
  echo "No matching cluster VMs remain."
fi

echo "[4/5] Destroying state-managed OpenStack resources..."
# Do not pass --break-lock: affected CLI builds advertise it but reject it at runtime.
opencenter cluster destroy "$target" --force

echo "[5/5] Sweeping cluster-named resources the OpenTofu state no longer tracks..."
# A reset or partial state leaves keypairs, security groups, networks, routers,
# ports, and floating IPs behind; redeploys then fail with Nova 409 name conflicts.
# Everything below matches the exact "$cluster-" name prefix so sibling clusters
# in the organization are never touched.
sweep_failures=0
sweep() {
  local description="$1"; shift
  if "$@"; then
    echo "  removed $description"
  else
    echo "[SWEEP FAILED] $description" >&2
    sweep_failures=$((sweep_failures + 1))
  fi
}

mapfile -t sweep_network_ids < <(
  openstack network list -f value -c ID -c Name |
    awk -v prefix="$cluster-" 'index($2, prefix) == 1 { print $1 }'
)
mapfile -t sweep_router_ids < <(
  openstack router list -f value -c ID -c Name |
    awk -v prefix="$cluster-" 'index($2, prefix) == 1 { print $1 }'
)

# Release floating IPs bound to ports on the cluster networks while those ports
# still exist; once the ports are gone the FIPs become anonymous orphans.
declare -A cluster_port=()
for network_id in "${sweep_network_ids[@]}"; do
  while read -r port_id; do
    [[ -n "$port_id" ]] && cluster_port["$port_id"]=1
  done < <(openstack port list --network "$network_id" -f value -c ID)
done
if ((${#cluster_port[@]})); then
  while read -r fip_id fip_port; do
    [[ -n "${cluster_port[$fip_port]:-}" ]] && sweep "floating IP $fip_id" openstack floating ip delete "$fip_id"
  done < <(openstack floating ip list -f value -c ID -c Port | awk '$2 != "None" && $2 != ""')
fi

# Routers must be detached from subnets and their gateway before deletion.
for router_id in "${sweep_router_ids[@]}"; do
  for network_id in "${sweep_network_ids[@]}"; do
    while read -r subnet_id; do
      [[ -n "$subnet_id" ]] && openstack router remove subnet "$router_id" "$subnet_id" 2>/dev/null || true
    done < <(openstack subnet list --network "$network_id" -f value -c ID)
  done
  openstack router unset --external-gateway "$router_id" 2>/dev/null || true
  sweep "router $router_id" openstack router delete "$router_id"
done

# Remaining ports block network deletion; subnets cascade with the network.
for network_id in "${sweep_network_ids[@]}"; do
  while read -r port_id; do
    [[ -n "$port_id" ]] && sweep "port $port_id" openstack port delete "$port_id"
  done < <(openstack port list --network "$network_id" -f value -c ID)
  sweep "network $network_id" openstack network delete "$network_id"
done

while read -r secgroup_id; do
  [[ -n "$secgroup_id" ]] && sweep "security group $secgroup_id" openstack security group delete "$secgroup_id"
done < <(openstack security group list -f value -c ID -c Name | awk -v prefix="$cluster-" 'index($2, prefix) == 1 { print $1 }')

while read -r server_group_id; do
  [[ -n "$server_group_id" ]] && sweep "server group $server_group_id" openstack server group delete "$server_group_id"
done < <(openstack server group list -f value -c ID -c Name | awk -v prefix="$cluster-" 'index($2, prefix) == 1 { print $1 }')

if openstack keypair show "$cluster-key" >/dev/null 2>&1; then
  sweep "keypair $cluster-key" openstack keypair delete "$cluster-key"
fi

if ((sweep_failures)); then
  echo "[BLOCKED] $sweep_failures orphaned resource(s) could not be deleted; review the sweep output above." >&2
  exit 7
fi
echo "Cluster $target infrastructure was fully decommissioned, including resources the state no longer tracked."
echo "Local and shared GitOps files were preserved to protect other clusters in $org."
