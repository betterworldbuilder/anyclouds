#!/usr/bin/env python3
"""
Application Dependency Mapping (ADM) Generator
Infers network and application dependencies (Option C) from OSPC inventory metadata.
"""
import csv
import argparse
import sys
from pathlib import Path
from typing import List, Dict, Any

def group_dependencies(rows: List[Dict[str, Any]]) -> List[Dict[str, str]]:
    dependencies = []
    
    # Identify key infrastructural roles based on the stack_membership
    databases = [r for r in rows if 'database' in str(r.get('stack_membership', '')).lower() or 'db' in str(r.get('stack_membership', '')).lower()]
    ad_servers = [r for r in rows if 'ad service' in str(r.get('stack_membership', '')).lower() or 'domain controller' in str(r.get('stack_membership', '')).lower()]
    dns_servers = [r for r in rows if 'dns' in str(r.get('stack_membership', '')).lower()]
    
    for row in rows:
        source_host = row.get('hostname', 'UNKNOWN')
        stack = str(row.get('stack_membership', 'Unknown'))
        os_type = str(row.get('os', '')).lower()
        
        # 1. Active Directory Dependency
        if 'windows' in os_type and 'ad service' not in stack.lower():
            for ad in ad_servers:
                dependencies.append({
                    'Source Hostname': source_host,
                    'Source Stack': stack,
                    'Target Hostname': ad.get('hostname', 'UNKNOWN'),
                    'Target Stack': ad.get('stack_membership', 'AD Service'),
                    'Protocol/Port': 'TCP/389, TCP/636 (LDAP)',
                    'Dependency Type': 'Inferred Domain Infrastructure'
                })
        
        # 2. DNS Dependency
        if 'dns' not in stack.lower() and dns_servers:
            for dns in dns_servers:
                dependencies.append({
                    'Source Hostname': source_host,
                    'Source Stack': stack,
                    'Target Hostname': dns.get('hostname', 'UNKNOWN'),
                    'Target Stack': dns.get('stack_membership', 'DNS Server'),
                    'Protocol/Port': 'UDP/53 (DNS)',
                    'Dependency Type': 'Inferred Network Infrastructure'
                })
                
        # 3. Application -> Database Dependency
        if any(keyword in stack.lower() for keyword in ['application', 'api', 'adapter', 'client', 'server']):
            if 'database' not in stack.lower():
                for db in databases:
                    db_stack = str(db.get('stack_membership', '')).lower()
                    
                    if 'oracle' in db_stack:
                        port = 'TCP/1521 (Oracle)'
                    elif 'mysql' in db_stack or 'mariadb' in db_stack:
                        port = 'TCP/3306 (MySQL)'
                    elif 'postgres' in db_stack:
                        port = 'TCP/5432 (PostgreSQL)'
                    elif 'redis' in db_stack:
                        port = 'TCP/6379 (Redis)'
                    elif 'sql server' in db_stack or 'mssql' in db_stack:
                        port = 'TCP/1433 (MSSQL)'
                    else:
                        port = 'TCP/Database'
                        
                    dependencies.append({
                        'Source Hostname': source_host,
                        'Source Stack': stack,
                        'Target Hostname': db.get('hostname', 'UNKNOWN'),
                        'Target Stack': db.get('stack_membership', 'Database'),
                        'Protocol/Port': port,
                        'Dependency Type': 'Inferred Application Layer'
                    })
    
    return dependencies

def generate_active_scanner(rows: List[Dict[str, Any]], output_file: str):
    script_lines = [
        "#!/usr/bin/env bash",
        "set -uo pipefail",
        "",
        "echo \"Starting Active Dependency Discovery...\"",
        "mkdir -p active_discovery_logs",
        ""
    ]
    
    linux_servers = [r for r in rows if 'linux' in str(r.get('os', '')).lower()]
    
    if not linux_servers:
        script_lines.append("echo 'No Linux servers found for SSH active mapping.'")
    
    for server in linux_servers:
        ip = server.get('managementip', '') or server.get('ip_address', '')
        hostname = server.get('hostname', 'UNKNOWN')
        if not ip:
            continue

        ssh_cmd = f"ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@{ip}"

        script_lines.append(f"echo '══════════════════════════════════════════════════════'")
        script_lines.append(f"echo 'Scanning {hostname} ({ip})...'")
        script_lines.append(f"echo '══════════════════════════════════════════════════════'")
        script_lines.append("")

        # 1. Network connections & listeners
        script_lines.append(f"echo '  → Network connections & listeners...'")
        script_lines.append(f"{ssh_cmd} \"ss -tunlp 2>/dev/null || netstat -tunap 2>/dev/null\" > \"active_discovery_logs/{hostname}_network.log\" || echo '  ✗ Failed network scan for {hostname}'")
        script_lines.append("")

        # 2. Running services
        script_lines.append(f"echo '  → Running services...'")
        script_lines.append(f"{ssh_cmd} \"systemctl list-units --type=service --state=running --no-pager 2>/dev/null || service --status-all 2>/dev/null\" > \"active_discovery_logs/{hostname}_services.log\" || echo '  ✗ Failed services scan for {hostname}'")
        script_lines.append("")

        # 3. Installed packages
        script_lines.append(f"echo '  → Installed packages...'")
        script_lines.append(f"{ssh_cmd} \"dpkg -l 2>/dev/null || rpm -qa --qf '%{{NAME}}-%{{VERSION}}-%{{RELEASE}}.%{{ARCH}}\\n' 2>/dev/null\" > \"active_discovery_logs/{hostname}_packages.log\" || echo '  ✗ Failed packages scan for {hostname}'")
        script_lines.append("")

        # 4. Cron jobs
        script_lines.append(f"echo '  → Cron jobs...'")
        script_lines.append(f"{ssh_cmd} \"crontab -l 2>/dev/null; echo '--- /etc/crontab ---'; cat /etc/crontab 2>/dev/null; echo '--- /etc/cron.d/ ---'; ls -la /etc/cron.d/ 2>/dev/null; cat /etc/cron.d/* 2>/dev/null\" > \"active_discovery_logs/{hostname}_cron.log\" || echo '  ✗ Failed cron scan for {hostname}'")
        script_lines.append("")

        # 5. OS & kernel info, disk usage, memory
        script_lines.append(f"echo '  → OS & system info...'")
        script_lines.append(f"{ssh_cmd} \"cat /etc/os-release 2>/dev/null; echo '---KERNEL---'; uname -a; echo '---DISK---'; df -h; echo '---MEMORY---'; free -m; echo '---UPTIME---'; uptime\" > \"active_discovery_logs/{hostname}_system.log\" || echo '  ✗ Failed system scan for {hostname}'")
        script_lines.append("")

        # 6. Firewall rules
        script_lines.append(f"echo '  → Firewall rules...'")
        script_lines.append(f"{ssh_cmd} \"iptables -L -n -v 2>/dev/null; echo '---NFTABLES---'; nft list ruleset 2>/dev/null; echo '---UFW---'; ufw status verbose 2>/dev/null\" > \"active_discovery_logs/{hostname}_firewall.log\" || echo '  ✗ Failed firewall scan for {hostname}'")
        script_lines.append("")

    script_lines.append("echo \"\"")
    script_lines.append("echo \"══════════════════════════════════════════════════════\"")
    script_lines.append("echo \"Discovery complete. Logs saved to active_discovery_logs/\"")
    script_lines.append("echo \"\"")
    script_lines.append("echo \"Log files per host:\"")
    script_lines.append("echo \"  *_network.log   - Active TCP/UDP connections & listening ports\"")
    script_lines.append("echo \"  *_services.log  - Running systemd/init services\"")
    script_lines.append("echo \"  *_packages.log  - Installed packages (deb/rpm)\"")
    script_lines.append("echo \"  *_cron.log      - Scheduled cron jobs\"")
    script_lines.append("echo \"  *_system.log    - OS release, kernel, disk, memory\"")
    script_lines.append("echo \"  *_firewall.log  - iptables / nftables / ufw rules\"")
    script_lines.append("echo \"\"")
    script_lines.append("echo \"Parse these logs to determine true port-level dependencies\"")
    
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write("\n".join(script_lines) + "\n")

def main():
    parser = argparse.ArgumentParser(description="Generate Application Dependency Mapping (ADM)")
    parser.add_argument('--inventory', required=True, help='Path to account overview CSV')
    parser.add_argument('--mode', choices=['inference', 'active'], default='inference', help='Mode of generation')
    args = parser.parse_args()

    inventory_path = Path(args.inventory)
    if not inventory_path.exists():
        print(f"ERROR: Inventory file {inventory_path} not found.")
        sys.exit(1)

    with open(inventory_path, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        rows = list(reader)

    base_name = inventory_path.stem.replace("_overview", "").replace("_inventory", "")
    
    if args.mode == 'inference':
        deps = group_dependencies(rows)
        output_file = f"{base_name}_app_dependencies.csv"
        fieldnames = ['Source Hostname', 'Source Stack', 'Target Hostname', 'Target Stack', 'Protocol/Port', 'Dependency Type']
        
        with open(output_file, 'w', encoding='utf-8', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(deps)

        print(f"Generated {output_file} successfully!")
        print(f"Discovered {len(deps)} inferred relationships.")
        print("WARNING: These dependencies are inferred automatically from stack metadata.")
    
    elif args.mode == 'active':
        output_file = f"{base_name}_active_dependency_scanner.sh"
        generate_active_scanner(rows, output_file)
        
        print(f"Generated {output_file} successfully!")
        print("Execute this bash script from a secure jumpbox to pull active netstat data.")

if __name__ == "__main__":
    main()
