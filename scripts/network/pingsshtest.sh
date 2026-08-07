#!/usr/bin/env bash

while true; do
  read -rp "Enter IP address (blank to quit): " IP

  if [[ -z "$IP" ]]; then
    echo "Done."
    exit 0
  fi

  read -rp "Enter SSH username for $IP: " USERNAME

  echo "Pinging $IP..."
  if ping -c 3 -W 2 "$IP" >/dev/null 2>&1; then
    echo "✅ Ping OK: $IP"
  else
    echo "❌ Ping failed: $IP"
    continue
  fi

  echo "Testing SSH to $USERNAME@$IP..."
  ssh -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new \
      "$USERNAME@$IP" "echo '✅ SSH OK on $(hostname)'"

  if [[ $? -eq 0 ]]; then
    echo "✅ SSH test successful: $USERNAME@$IP"
  else
    echo "❌ SSH test failed: $USERNAME@$IP"
  fi

  echo "--------------------------------------"
done

