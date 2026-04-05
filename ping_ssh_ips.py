#!/usr/bin/env python3
import subprocess
import concurrent.futures

ips = [
    "50.56.158.17",
    "50.56.158.247",
    "50.56.159.141",
    "50.56.159.233",
    "50.56.159.230",
    "50.56.159.145",
    "50.56.159.176",
    "50.56.158.36",
    "50.56.159.90",
    "50.56.158.196"
]

username = "ubuntu"
timeout = "5"

def check_ip(ip):
    # 1. Check Ping
    ping_cmd = f"ping -c 1 -W {timeout} {ip}"
    ping_result = subprocess.run(ping_cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    if ping_result.returncode == 0:
        ping_status = "[PING: OK]"
    else:
        ping_status = "[PING: FAILED]"
        
    # 2. Check SSH
    ssh_cmd = f"ssh -o BatchMode=yes -o ConnectTimeout={timeout} -o StrictHostKeyChecking=accept-new -q {username}@{ip} 'echo ok'"
    ssh_result = subprocess.run(ssh_cmd, shell=True, capture_output=True, text=True)
    
    if ssh_result.returncode == 0:
        ssh_status = f"[SSH: SUCCESS (Logged in as {username})]"
    elif "Permission denied" in ssh_result.stderr or "Permission denied" in ssh_result.stdout:
        ssh_status = "[SSH: REACHABLE but Permission denied (Needs valid SSH Key)]"
    else:
        ssh_status = f"[SSH: FAILED (Port closed or timed out)]"
        
    return f"{ip.ljust(15)} | {ping_status.ljust(16)} | {ssh_status}"

print("=================================================================================")
print(f" Starting Connectivity Check for {len(ips)} IPs (User: {username})")
print("=================================================================================")

with concurrent.futures.ThreadPoolExecutor(max_workers=min(10, len(ips))) as executor:
    results = list(executor.map(check_ip, ips))

for res in results:
    print(res)

print("=================================================================================")
print(" Finalized Connectivity Check")
print("=================================================================================")
