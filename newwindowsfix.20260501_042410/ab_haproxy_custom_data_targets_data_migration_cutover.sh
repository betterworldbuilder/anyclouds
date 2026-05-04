#!/usr/bin/env bash
set -uo pipefail
echo 'Starting Final Cutover Phase'

# Cutover Linux App for web (Local HAProxy Split)
echo 'Applying Local A/B Load Balancing split for web'
ssh -o StrictHostKeyChecking=no root@UNKNOWN_IP 'yum install -y haproxy || apt-get install -y haproxy'
ssh -o StrictHostKeyChecking=no root@UNKNOWN_IP 'cat <<EOF > /etc/haproxy/haproxy.cfg
frontend incoming
    bind *:80
    default_backend nodes
backend nodes
    balance roundrobin
    server local_ospc 127.0.0.1:8080 check
    server flex_clone $TARGET_IP:80 check
EOF'
ssh -o StrictHostKeyChecking=no root@UNKNOWN_IP 'systemctl restart haproxy'
echo 'Traffic is now flowing 50/50 to existing OSPC app tier and new FLEX clone.'

# Cutover Linux App for db (Local HAProxy Split)
echo 'Applying Local A/B Load Balancing split for db'
ssh -o StrictHostKeyChecking=no root@UNKNOWN_IP 'yum install -y haproxy || apt-get install -y haproxy'
ssh -o StrictHostKeyChecking=no root@UNKNOWN_IP 'cat <<EOF > /etc/haproxy/haproxy.cfg
frontend incoming
    bind *:80
    default_backend nodes
backend nodes
    balance roundrobin
    server local_ospc 127.0.0.1:8080 check
    server flex_clone $TARGET_IP:80 check
EOF'
ssh -o StrictHostKeyChecking=no root@UNKNOWN_IP 'systemctl restart haproxy'
echo 'Traffic is now flowing 50/50 to existing OSPC app tier and new FLEX clone.'
