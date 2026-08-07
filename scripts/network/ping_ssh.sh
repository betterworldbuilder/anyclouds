#!/usr/bin/env bash
set -euo pipefail

read -r -p "Enter IP or hostname: " host
host="${host//[[:space:]]/}"

if [[ -z "$host" ]]; then
  echo "No IP/hostname entered."
  exit 1
fi

echo "Pinging $host..."
if ping -c 4 -W 2 "$host"; then
  echo "Ping OK."
else
  echo "Ping failed or ICMP is blocked. You can still try SSH."
fi

read -r -p "Enter SSH username: " user
user="${user//[[:space:]]/}"

if [[ -z "$user" ]]; then
  echo "No username entered."
  exit 1
fi

echo "Connecting to $user@$host..."
exec ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=4 "$user@$host"
