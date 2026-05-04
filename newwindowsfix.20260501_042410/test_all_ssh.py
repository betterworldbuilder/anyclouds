#!/usr/bin/env python3
import subprocess
import concurrent.futures

targets = [
    ("ospc2flex-u22-20260425-2221", "50.56.158.21", ["ubuntu", "root"]),
    ("ospc2flex-dbian12-20260425-2221", "174.143.59.58", ["debian", "admin", "root"]),
    ("ospc2flex-alma8-20260425-2221", "50.56.159.162", ["almalinux", "centos", "root"]),
    ("ospc2flex-rocky8-20260425-2221", "50.56.158.55", ["rocky", "rockylinux", "root"]),
    ("ospc2flex-rocky9-20260425-2221", "50.56.159.105", ["rocky", "rockylinux", "root"]),
    ("ospc2flex-u20-20260425-2221", "50.56.158.85", ["ubuntu", "root"]),
    ("ospc2flex-Alma9-20260425-2221", "50.56.159.32", ["almalinux", "centos", "root"]),
    ("ospc2flex-centos7-20260425-2221", "50.56.159.207", ["centos", "root"]),
    ("ospc2flex-dbian10new-20260425-2221", "50.56.157.200", ["debian", "admin", "root"]),
    ("ospc2flex-debian11new-20260425-2221", "50.56.159.164", ["debian", "admin", "root"])
]

timeout = "10"

def get_ssh_cmd(user, ip):
    return f"ssh -o BatchMode=yes -o ConnectTimeout={timeout} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q {user}@{ip} 'uptime'"

def check_target(args):
    name, ip, users = args
    
    # Check Ping
    ping_cmd = f"ping -c 1 -W 5 {ip}"
    ping_result = subprocess.run(ping_cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    if ping_result.returncode != 0:
        return f"{name[:25].ljust(25)} | {ip.ljust(15)} | [PING: FAILED] | N/A"
        
    ping_status = "[PING: OK]"
    
    # Try SSH users
    last_err = "No users tried"
    for user in users:
        ssh_cmd = get_ssh_cmd(user, ip)
        ssh_result = subprocess.run(ssh_cmd, shell=True, capture_output=True, text=True)
        
        if ssh_result.returncode == 0:
            return f"{name[:25].ljust(25)} | {ip.ljust(15)} | {ping_status} | [SSH: SUCCESS] as '{user}' -> {ssh_result.stdout.strip()}"
        else:
            last_err_text = ssh_result.stderr.strip() or ssh_result.stdout.strip()
            if "Permission denied" in last_err_text:
                last_err = f"Auth failed for '{user}' (Permission denied)"
            else:
                last_err = f"Connection error: {last_err_text}"
            
    return f"{name[:25].ljust(25)} | {ip.ljust(15)} | {ping_status} | [SSH: FAILED] -> {last_err}"

print("=========================================================================================================")
print(f" Starting Connectivity & OS Login Check for {len(targets)} Targets")
print("=========================================================================================================")

with concurrent.futures.ThreadPoolExecutor(max_workers=len(targets)) as executor:
    results = list(executor.map(check_target, targets))

for res in results:
    print(res)

print("=========================================================================================================")
print(" Finalized Check")
print("=========================================================================================================")
