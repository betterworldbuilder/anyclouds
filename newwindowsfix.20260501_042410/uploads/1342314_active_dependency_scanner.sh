#!/usr/bin/env bash
set -uo pipefail

echo "Starting Active Dependency Discovery..."
mkdir -p active_discovery_logs

echo 'No Linux servers found for SSH active mapping.'
echo ""
echo "══════════════════════════════════════════════════════"
echo "Discovery complete. Logs saved to active_discovery_logs/"
echo ""
echo "Log files per host:"
echo "  *_network.log   - Active TCP/UDP connections & listening ports"
echo "  *_services.log  - Running systemd/init services"
echo "  *_packages.log  - Installed packages (deb/rpm)"
echo "  *_cron.log      - Scheduled cron jobs"
echo "  *_system.log    - OS release, kernel, disk, memory"
echo "  *_firewall.log  - iptables / nftables / ufw rules"
echo ""
echo "Parse these logs to determine true port-level dependencies"
