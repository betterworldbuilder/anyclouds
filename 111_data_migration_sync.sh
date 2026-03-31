#!/usr/bin/env bash
set -uo pipefail
echo 'Starting Initial Data Sync Phase'

# Server: web -> web (Category: linux_app)
TARGET_IP=$(openstack server show web -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for web'
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@10.0.0.1:/var/www/html/ centos@$TARGET_IP:/var/www/html/

# Server: db -> db (Category: database)
TARGET_IP=$(openstack server show db -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing highly-available DB Replica for db'
# Configure OSPC DB to act as Replication Primary and FLEX target to act as Replica
ssh -o StrictHostKeyChecking=no root@10.0.0.2 'mysql -e "CREATE USER IF NOT EXISTS \'repl\'@\'%\' IDENTIFIED BY \'mig_password\'; GRANT REPLICATION SLAVE ON *.* TO \'repl\'@\'%\'; FLUSH PRIVILEGES;"'
ssh -o StrictHostKeyChecking=no root@10.0.0.2 'mysqldump --all-databases --single-transaction --master-data=1 --quick' | ssh -o StrictHostKeyChecking=no centos@$TARGET_IP 'mysql'
ssh -o StrictHostKeyChecking=no centos@$TARGET_IP 'mysql -e "CHANGE MASTER TO MASTER_HOST=\'10.0.0.2\', MASTER_USER=\'repl\', MASTER_PASSWORD=\'mig_password\'; START SLAVE;"'
