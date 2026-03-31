#!/usr/bin/env python3
import argparse
import csv
import re
from pathlib import Path
from typing import Dict, List, Optional, Tuple

def read_csv(path: Path) -> List[Dict[str, str]]:
    with path.open("r", newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

def slugify(value: str) -> str:
    text = (value or "").strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    return text or "resource"

def is_truthy(value: str) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "y", "on"}

def identify_workload_category(stack: str, os_name: str) -> str:
    stack_lower = stack.lower()
    os_lower = os_name.lower()
    
    if "database" in stack_lower:
        return "database"
    if "k8s" in stack_lower or "kubernetes" in stack_lower or "docker" in stack_lower:
        return "container"
    if "windows" in os_lower:
        return "windows_app"
    return "linux_app"

def main():
    parser = argparse.ArgumentParser(description="Generate data migration scripts from OSPC to FLEX.")
    parser.add_argument("--inventory", required=False, help="Path to overview/inventory CSV e.g., 123456_overview.csv")
    parser.add_argument("--flavor-mapping", required=False, help="Path to generated flavor map CSV e.g., 123456_flavormap.csv")
    parser.add_argument("--custom-ips", required=False, help="Path to custom override CSV containing source_ip and target_ip")
    parser.add_argument("--resource-map", required=False, help="Path to OSPC→FLEX resource mapping CSV from Stage 2 deploy (e.g., 123456_tenant_deploy_resource_map.csv)")
    parser.add_argument("--strategy", default="direct", choices=["direct", "ab_haproxy", "ab_reuse_lb"], help="Migration strategy logic")
    args = parser.parse_args()

    strategy = args.strategy

    # Load OSPC→FLEX resource map if provided
    resource_map = {}  # keyed by source_name (lowercase) -> {flex_name, flex_id, flex_private_ip, flex_floating_ip}
    if args.resource_map:
        rmap_path = Path(args.resource_map)
        if rmap_path.exists():
            for rrow in read_csv(rmap_path):
                if (rrow.get("resource_type") or "").strip() != "server":
                    continue
                if (rrow.get("status") or "").strip() != "created":
                    continue
                key_by_name = (rrow.get("source_name") or "").strip().lower()
                key_by_id = (rrow.get("source_server_id") or "").strip()
                entry = {
                    "flex_name": (rrow.get("flex_name") or "").strip(),
                    "flex_id": (rrow.get("flex_id") or "").strip(),
                    "flex_private_ip": (rrow.get("flex_private_ip") or "").strip(),
                    "flex_floating_ip": (rrow.get("flex_floating_ip") or "").strip(),
                }
                if key_by_name:
                    resource_map[key_by_name] = entry
                if key_by_id:
                    resource_map[key_by_id] = entry
            print(f"Loaded {len(resource_map)} server entries from resource map: {rmap_path}")
        else:
            print(f"WARNING: resource-map file not found: {rmap_path}")

    migration_targets = []

    if args.custom_ips:
        custom_path = Path(args.custom_ips)
        if not custom_path.exists():
            print(f"Error: {custom_path} not found.")
            return
        
        for idx, row in enumerate(read_csv(custom_path)):
            source_ip = (row.get("source_ip") or "").strip()
            target_ip = (row.get("target_ip") or "").strip()
            if not source_ip or not target_ip:
                continue
            
            category = (row.get("category") or "").strip() or "linux_app"
            source_name = (row.get("source_name") or source_ip).strip()
            target_name = (row.get("target_name") or target_ip).strip()
            
            migration_targets.append({
                "source_name": source_name,
                "target_name": target_name,
                "source_ip": source_ip,
                "target_ip": target_ip,
                "category": category,
            })

    else:
        if not args.inventory or not args.flavor_mapping:
            print("Error: --inventory and --flavor-mapping required if not using --custom-ips")
            return

        inventory_path = Path(args.inventory)
        flavormap_path = Path(args.flavor_mapping)
        
        if not inventory_path.exists():
            print(f"Error: {inventory_path} not found.")
            return
        if not flavormap_path.exists():
            print(f"Error: {flavormap_path} not found.")
            return

        inventory_rows = read_csv(inventory_path)
        flavormap_rows = read_csv(flavormap_path)

        inventory_by_id = {}
        inventory_by_name = {}
        for row in inventory_rows:
            hostname = (row.get("hostname") or row.get("workloadname") or "").strip()
            server_id = (row.get("id") or row.get("deviceid") or hostname).strip()
            if server_id:
                inventory_by_id[server_id] = row
            if hostname:
                inventory_by_name[hostname.lower()] = row

        for row in flavormap_rows:
            include_in_deploy = row.get("include_in_deploy")
            include = True if include_in_deploy is None or include_in_deploy == "" else is_truthy(include_in_deploy)
            if not include:
                continue
                
            server_id = (row.get("server_id") or "").strip()
            source_name = (row.get("server_name") or server_id or "unnamed-server").strip()
            
            inv_row = inventory_by_id.get(server_id) or inventory_by_name.get(source_name.lower()) or {}
            
            stack = (inv_row.get("stack_membership") or "").strip()
            os_name = (inv_row.get("os") or inv_row.get("softwareversion") or "").strip()
            mgmt_ip = (inv_row.get("floatingip") or inv_row.get("managementip") or inv_row.get("ipaddress") or "UNKNOWN_IP").strip()
            
            category = identify_workload_category(stack, os_name)

            # Resolve target IP from resource map if available
            rmap_entry = resource_map.get(server_id) or resource_map.get(source_name.lower()) or {}
            if rmap_entry.get("flex_private_ip"):
                target_ip = rmap_entry["flex_private_ip"]
                target_name = rmap_entry.get("flex_name") or source_name
            else:
                target_ip = "$RESOLVE_FROM_OS"
                target_name = source_name

            migration_targets.append({
                "source_name": source_name,
                "target_name": target_name,
                "source_ip": mgmt_ip,
                "target_ip": target_ip,
                "category": category,
                "flex_id": rmap_entry.get("flex_id", ""),
            })

    sync_commands = ["#!/usr/bin/env bash", "set -uo pipefail", "echo 'Starting Initial Data Sync Phase'", ""]
    cutover_commands = ["#!/usr/bin/env bash", "set -uo pipefail", "echo 'Starting Final Cutover Phase'", ""]
    rollback_commands = ["#!/usr/bin/env bash", "set -uo pipefail", "echo 'Starting Rollback Phase'", ""]

    target_names_used = {}

    for spec in migration_targets:
        source_name = spec["source_name"]
        target_server_name = spec["target_name"]
        mgmt_ip = spec["source_ip"]
        category = spec["category"]

        sync_commands.append(f"# Server: {source_name} -> {target_server_name} (Category: {category})")
        if spec["target_ip"] == "$RESOLVE_FROM_OS":
            sync_commands.append(f"TARGET_IP=$(openstack server show {target_server_name} -f value -c addresses | awk -F'=' '{{print $2}}' | awk '{{print $1}}' || echo \"TARGET_IP_UNKNOWN\")")
        else:
            sync_commands.append(f"TARGET_IP=\"{spec['target_ip']}\"")

        if category == "database":
            if strategy in ["ab_haproxy", "ab_reuse_lb"]:
                sync_commands.extend([
                    f"echo 'Syncing highly-available DB Replica for {source_name}'",
                    f"# Configure OSPC DB to act as Replication Primary and FLEX target to act as Replica",
                    f"echo \"CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY 'mig_password'; GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%'; FLUSH PRIVILEGES;\" | ssh -o StrictHostKeyChecking=no root@{mgmt_ip} 'mysql'",
                    f"ssh -o StrictHostKeyChecking=no root@{mgmt_ip} 'mysqldump --all-databases --single-transaction --master-data=1 --quick' | ssh -o StrictHostKeyChecking=no centos@$TARGET_IP 'mysql'",
                    f"echo \"CHANGE MASTER TO MASTER_HOST='{mgmt_ip}', MASTER_USER='repl', MASTER_PASSWORD='mig_password'; START SLAVE;\" | ssh -o StrictHostKeyChecking=no centos@$TARGET_IP 'mysql'",
                    ""
                ])
                cutover_commands.extend([
                    f"# Cutover HA Database for {source_name}",
                    f"echo 'Promoting FLEX DB {target_server_name} to Independent Primary'",
                    f"ssh -o StrictHostKeyChecking=no centos@$TARGET_IP 'mysql -e \"STOP SLAVE; RESET SLAVE ALL;\"'",
                    f"echo 'Operator Action: Update application connection strings to point to $TARGET_IP'",
                    ""
                ])
                rollback_commands.extend([
                    f"# Rollback DB Cutover for {source_name}",
                    f"echo 'Reverting application strings back to OSPC Primary {mgmt_ip}'",
                    ""
                ])
            else:
                sync_commands.extend([
                    f"echo 'Syncing Database for {source_name}'",
                    f"# Run initial DB dump on OSPC over SSH and pipe to target",
                    f"ssh -o StrictHostKeyChecking=no root@{mgmt_ip} 'mysqldump --all-databases --single-transaction --quick' | ssh -o StrictHostKeyChecking=no centos@$TARGET_IP 'mysql'",
                    ""
                ])
                cutover_commands.extend([
                    f"# Cutover Database for {source_name}",
                    f"echo 'Freezing DB writes and doing final sync for {source_name}'",
                    f"ssh -o StrictHostKeyChecking=no root@{mgmt_ip} 'systemctl stop application_service || true; mysqldump --all-databases --single-transaction --master-data=2' | ssh -o StrictHostKeyChecking=no centos@$TARGET_IP 'mysql'",
                    ""
                ])
                rollback_commands.extend([
                    f"# Rollback Database for {source_name}",
                    f"echo 'Restarting source DB services for {source_name}'",
                    f"ssh -o StrictHostKeyChecking=no root@{mgmt_ip} 'systemctl start application_service || true'",
                    ""
                ])

        elif category == "linux_app":
            if strategy == "ab_haproxy":
                sync_commands.extend([
                    f"echo 'Syncing Linux App Files for {source_name}'",
                    f"mkdir -p /tmp/sync_{source_name}",
                    f"rsync -avz --progress -e \"ssh -o StrictHostKeyChecking=no\" root@{mgmt_ip}:/var/www/html/ /tmp/sync_{source_name}/",
                    f"rsync -avz --progress -e \"ssh -o StrictHostKeyChecking=no\" /tmp/sync_{source_name}/ centos@$TARGET_IP:/var/www/html/",
                    ""
                ])
                cutover_commands.extend([
                    f"# Cutover Linux App for {source_name} (Local HAProxy Split)",
                    f"echo 'Applying Local A/B Load Balancing split for {source_name}'",
                    f"ssh -o StrictHostKeyChecking=no root@{mgmt_ip} 'yum install -y haproxy || apt-get install -y haproxy'",
                    f"ssh -o StrictHostKeyChecking=no root@{mgmt_ip} 'cat <<EOF > /etc/haproxy/haproxy.cfg",
                    f"frontend incoming",
                    f"    bind *:80",
                    f"    default_backend nodes",
                    f"backend nodes",
                    f"    balance roundrobin",
                    f"    server local_ospc 127.0.0.1:8080 check",
                    f"    server flex_clone $TARGET_IP:80 check",
                    f"EOF'",
                    f"ssh -o StrictHostKeyChecking=no root@{mgmt_ip} 'systemctl restart haproxy'",
                    f"echo 'Traffic is now flowing 50/50 to existing OSPC app tier and new FLEX clone.'",
                    ""
                ])
                rollback_commands.extend([
                    f"# Rollback Linux App for {source_name} (Local HAProxy Split)",
                    f"echo 'Removing HAProxy and restoring 100% traffic to local OSPC node'",
                    f"ssh -o StrictHostKeyChecking=no root@{mgmt_ip} 'systemctl stop haproxy && systemctl disable haproxy'",
                    ""
                ])
            elif strategy == "ab_reuse_lb":
                sync_commands.extend([
                    f"echo 'Syncing Linux App Files for {source_name}'",
                    f"mkdir -p /tmp/sync_{source_name}",
                    f"rsync -avz --progress -e \"ssh -o StrictHostKeyChecking=no\" root@{mgmt_ip}:/var/www/html/ /tmp/sync_{source_name}/",
                    f"rsync -avz --progress -e \"ssh -o StrictHostKeyChecking=no\" /tmp/sync_{source_name}/ centos@$TARGET_IP:/var/www/html/",
                    ""
                ])
                cutover_commands.extend([
                    f"# Cutover Linux App for {source_name} (OpenStack LB Reuse)",
                    f"echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'",
                    f"read -p \"Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: \" OSPC_OCTAVIA_POOL_NAME",
                    f"openstack loadbalancer member create --name \"{target_server_name}-ab-member\" --address \"$TARGET_IP\" --protocol-port 80 \"$OSPC_OCTAVIA_POOL_NAME\"",
                    f"echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'",
                    ""
                ])
                rollback_commands.extend([
                    f"# Rollback Linux App for {source_name} (OpenStack LB Reuse)",
                    f"echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'",
                    f"read -p \"Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: \" OSPC_OCTAVIA_POOL_NAME",
                    f"openstack loadbalancer member delete \"$OSPC_OCTAVIA_POOL_NAME\" \"{target_server_name}-ab-member\"",
                    ""
                ])
            else:
                sync_commands.extend([
                    f"echo 'Syncing Linux App Files for {source_name}'",
                    f"mkdir -p /tmp/sync_{source_name}",
                    f"rsync -avz --progress -e \"ssh -o StrictHostKeyChecking=no\" root@{mgmt_ip}:/var/www/html/ /tmp/sync_{source_name}/",
                    f"rsync -avz --progress -e \"ssh -o StrictHostKeyChecking=no\" /tmp/sync_{source_name}/ centos@$TARGET_IP:/var/www/html/",
                    ""
                ])
                cutover_commands.extend([
                    f"# Cutover Linux App for {source_name}",
                    f"echo 'Stopping app writes and final rsync for {source_name}'",
                    f"ssh -o StrictHostKeyChecking=no root@{mgmt_ip} 'systemctl stop nginx apache2 || true'",
                    f"rsync -avz --delete -e \"ssh -o StrictHostKeyChecking=no\" root@{mgmt_ip}:/var/www/html/ /tmp/sync_{source_name}/",
                    f"rsync -avz --delete -e \"ssh -o StrictHostKeyChecking=no\" /tmp/sync_{source_name}/ centos@$TARGET_IP:/var/www/html/",
                    ""
                ])
                rollback_commands.extend([
                    f"# Rollback Linux App for {source_name}",
                    f"echo 'Starting source app services for {source_name}'",
                    f"ssh -o StrictHostKeyChecking=no root@{mgmt_ip} 'systemctl start nginx apache2 || true'",
                    ""
                ])
            
        elif category == "windows_app":
            sync_commands.extend([
                f"echo 'Syncing Windows App for {source_name}'",
                f"# Windows file transfer using initial SMB / Robocopy approach from orchestration node or target",
                f"# NOTE: Requires SMB connectivity from script executor to source {mgmt_ip} and target $TARGET_IP",
                f"echo 'Execute robocopy \\\\{mgmt_ip}\\c$\\inetpub \\\\'$TARGET_IP'\\c$\\inetpub /MIR /Z /W:5' > /dev/null",
                ""
            ])
            cutover_commands.extend([
                f"# Cutover Windows App for {source_name}",
                f"echo 'Stopping IIS on source {source_name} and performing final robocopy'",
                f"# ssh / winrm to stop IIS",
                f"echo 'Execute robocopy \\\\{mgmt_ip}\\c$\\inetpub \\\\'$TARGET_IP'\\c$\\inetpub /MIR /Z /W:5' > /dev/null",
                ""
            ])
            rollback_commands.extend([
                f"# Rollback Windows App for {source_name}",
                f"echo 'Restarting IIS on source {source_name}'",
                ""
            ])
            
        elif category == "container":
            sync_commands.extend([
                f"echo 'Syncing Container PVs for {source_name}'",
                f"# Requires specialized PV backup (Velero or rsync of PV mount paths)",
                f"mkdir -p /tmp/sync_{source_name}_volumes",
                f"rsync -avz --progress -e \"ssh -o StrictHostKeyChecking=no\" root@{mgmt_ip}:/var/lib/docker/volumes/ /tmp/sync_{source_name}_volumes/ || true",
                f"rsync -avz --progress -e \"ssh -o StrictHostKeyChecking=no\" /tmp/sync_{source_name}_volumes/ centos@$TARGET_IP:/var/lib/docker/volumes/ || true",
                ""
            ])
            cutover_commands.extend([
                f"# Cutover Container workloads for {source_name}",
                f"echo 'Scaling down statefulsets on source {source_name} and final rsync'",
                f"ssh -o StrictHostKeyChecking=no root@{mgmt_ip} 'kubectl scale deploy --all --replicas=0 || true'",
                f"rsync -avz --delete -e \"ssh -o StrictHostKeyChecking=no\" root@{mgmt_ip}:/var/lib/docker/volumes/ /tmp/sync_{source_name}_volumes/ || true",
                f"rsync -avz --delete -e \"ssh -o StrictHostKeyChecking=no\" /tmp/sync_{source_name}_volumes/ centos@$TARGET_IP:/var/lib/docker/volumes/ || true",
                ""
            ])
            rollback_commands.extend([
                f"# Rollback Container workloads for {source_name}",
                f"echo 'Scaling up statefulsets on source {source_name}'",
                f"ssh -o StrictHostKeyChecking=no root@{mgmt_ip} 'kubectl scale deploy --all --replicas=1 || true'",
                ""
            ])

    if args.custom_ips:
        base_name = Path(args.custom_ips).stem.replace("_custom", "").replace("_ips", "")
    else:
        base_name = Path(args.inventory).stem.replace("_overview", "").replace("_inventory", "")
    
    sync_file = f"{args.strategy}_{base_name}_data_migration_sync.sh"
    cutover_file = f"{args.strategy}_{base_name}_data_migration_cutover.sh"
    rollback_file = f"{args.strategy}_{base_name}_data_migration_rollback.sh"
    
    with open(sync_file, "w") as f:
        f.write("\n".join(sync_commands))
    with open(cutover_file, "w") as f:
        f.write("\n".join(cutover_commands))
    with open(rollback_file, "w") as f:
        f.write("\n".join(rollback_commands))
        
    print(f"Generated data migration scripts:")
    print(f"  - {sync_file}")
    print(f"  - {cutover_file}")
    print(f"  - {rollback_file}")

if __name__ == "__main__":
    main()
