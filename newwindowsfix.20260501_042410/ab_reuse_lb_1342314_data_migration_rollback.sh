#!/usr/bin/env bash
set -uo pipefail
echo 'Starting Rollback Phase'

# Rollback Linux App for ospc-jumpHost (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "ospc-jumpHost-ab-member"

# Rollback Linux App for u24-postgresl (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "u24-postgresl-ab-member"

# Rollback Linux App for u24-FrontEnd (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "u24-FrontEnd-ab-member"

# Rollback Linux App for php-ospc (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "php-ospc-ab-member"

# Rollback Linux App for Windows Server 2019Re (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "Windows Server 2019Re-ab-member"

# Rollback Linux App for win2019websql2019 (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "win2019websql2019-ab-member"

# Rollback Linux App for Windows Server 2016 + SQL Server 2019 (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "Windows Server 2016 + SQL Server 2019-ab-member"

# Rollback Linux App for u24Backend (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "u24Backend-ab-member"

# Rollback Linux App for HA percona 8-02 (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "HA percona 8-02-ab-member"

# Rollback Linux App for drupal (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "drupal-ab-member"

# Rollback Linux App for HA-Mysql8-01 (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "HA-Mysql8-01-ab-member"

# Rollback Linux App for HA-mariaDB-02 (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "HA-mariaDB-02-ab-member"

# Rollback Linux App for php-ospc_Database (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "php-ospc_Database-ab-member"

# Rollback Linux App for HA percona 8-03 (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "HA percona 8-03-ab-member"

# Rollback Linux App for HA-mariaDB-03 (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "HA-mariaDB-03-ab-member"

# Rollback Linux App for Stack-05_Database (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "Stack-05_Database-ab-member"

# Rollback Linux App for sql (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "sql-ab-member"

# Rollback Linux App for HA-Mysql8-02 (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "HA-Mysql8-02-ab-member"

# Rollback Linux App for HA-mariaDB-01 (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "HA-mariaDB-01-ab-member"

# Rollback Linux App for Instance-05-03 (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "Instance-05-03-ab-member"

# Rollback Linux App for HA percona 8-01 (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "HA percona 8-01-ab-member"

# Rollback Linux App for Instance-05-02 (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "Instance-05-02-ab-member"

# Rollback Linux App for HA-Mysql8-03 (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "HA-Mysql8-03-ab-member"
