#!/usr/bin/env bash
set -euo pipefail

read -r -p "Windows IP: " IP

if [ -z "$IP" ]; then
  echo "ERROR: IP is required" >&2
  exit 2
fi

exec xfreerdp /v:"$IP" /u:Administrator /d:flexwin2016
