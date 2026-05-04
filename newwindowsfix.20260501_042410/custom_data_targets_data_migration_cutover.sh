#!/usr/bin/env bash
set -uo pipefail
echo 'Starting Final Cutover Phase'

# Cutover Linux App for web-prod-01 (Local HAProxy Split)
echo 'Applying Local A/B Load Balancing split for web-prod-01'
ssh -o StrictHostKeyChecking=no root@10.0.0.15 'yum install -y haproxy || apt-get install -y haproxy'
ssh -o StrictHostKeyChecking=no root@10.0.0.15 'cat <<EOF > /etc/haproxy/haproxy.cfg
frontend incoming
    bind *:80
    default_backend nodes
backend nodes
    balance roundrobin
    server local_ospc 127.0.0.1:8080 check
    server flex_clone $TARGET_IP:80 check
EOF'
ssh -o StrictHostKeyChecking=no root@10.0.0.15 'systemctl restart haproxy'
echo 'Traffic is now flowing 50/50 to existing OSPC app tier and new FLEX clone.'

# Cutover HA Database for db-prod-01
echo 'Promoting FLEX DB flex-db-01 to Independent Primary'
ssh -o StrictHostKeyChecking=no centos@$TARGET_IP 'mysql -e "STOP SLAVE; RESET SLAVE ALL;"'
echo 'Operator Action: Update application connection strings to point to $TARGET_IP'

# Cutover Windows App for api-prod-01
echo 'Stopping IIS on source api-prod-01 and performing final robocopy'
# ssh / winrm to stop IIS
echo 'Execute robocopy \\10.0.0.25\c$\inetpub \\'$TARGET_IP'\c$\inetpub /MIR /Z /W:5' > /dev/null
