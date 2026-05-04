#!/usr/bin/env bash
set -uo pipefail
echo 'Starting Final Cutover Phase'

# Cutover Linux App for ospc-jumpHost (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "ospc-jumpHost-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for u24-postgresl (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "u24-postgresl-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for u24-FrontEnd (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "u24-FrontEnd-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for php-ospc (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "php-ospc-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for Windows Server 2019Re (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "Windows Server 2019Re-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for win2019websql2019 (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "win2019websql2019-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for Windows Server 2016 + SQL Server 2019 (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "Windows Server 2016 + SQL Server 2019-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for u24Backend (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "u24Backend-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for HA percona 8-02 (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "HA percona 8-02-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for drupal (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "drupal-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for HA-Mysql8-01 (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "HA-Mysql8-01-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for HA-mariaDB-02 (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "HA-mariaDB-02-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for php-ospc_Database (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "php-ospc_Database-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for HA percona 8-03 (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "HA percona 8-03-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for HA-mariaDB-03 (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "HA-mariaDB-03-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for Stack-05_Database (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "Stack-05_Database-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for sql (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "sql-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for HA-Mysql8-02 (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "HA-Mysql8-02-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for HA-mariaDB-01 (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "HA-mariaDB-01-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for Instance-05-03 (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "Instance-05-03-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for HA percona 8-01 (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "HA percona 8-01-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for Instance-05-02 (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "Instance-05-02-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover Linux App for HA-Mysql8-03 (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "HA-Mysql8-03-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'
