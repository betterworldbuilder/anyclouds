#!/usr/bin/env bash
set -uo pipefail

echo "Starting Active Dependency Discovery..."
mkdir -p active_discovery_logs

echo 'Scanning server3 (10.0.0.12)...'
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@10.0.0.12 "netstat -tunap" > "active_discovery_logs/server3_netstat.log" || echo 'Failed to scan server3'

echo 'Scanning server4 (10.0.0.13)...'
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@10.0.0.13 "netstat -tunap" > "active_discovery_logs/server4_netstat.log" || echo 'Failed to scan server4'

echo 'Scanning server5 (10.0.0.14)...'
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@10.0.0.14 "netstat -tunap" > "active_discovery_logs/server5_netstat.log" || echo 'Failed to scan server5'

echo "Discovery complete. Logs saved to active_discovery_logs/"
echo "Parse these logs to determine true port-level dependencies."
