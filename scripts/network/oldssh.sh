#!/usr/bin/env bash
# Connect to a RHEL 6 VM using legacy SSH key algorithms

read -rp "Enter RHEL 6 VM IP: " VM_IP

CMD="ssh -i ~/.ssh/id_rsa \
  -o HostKeyAlgorithms=+ssh-dss \
  -o PubkeyAcceptedKeyTypes=+ssh-rsa \
  -o StrictHostKeyChecking=no \
  root@${VM_IP}"

echo ""
echo "Running: $CMD"
echo ""
eval "$CMD"
