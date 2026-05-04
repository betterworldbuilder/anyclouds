#!/usr/bin/env bash
set -uo pipefail
echo 'Starting Initial Data Sync Phase'

# Server: web-prod-01 -> flex-web-01 (Category: linux_app)
TARGET_IP="192.168.1.15"
echo 'Syncing Linux App Files for web-prod-01'
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@10.0.0.15:/var/www/html/ centos@$TARGET_IP:/var/www/html/

# Server: db-prod-01 -> flex-db-01 (Category: database)
TARGET_IP="192.168.1.20"
echo 'Syncing highly-available DB Replica for db-prod-01'
# Configure OSPC DB to act as Replication Primary and FLEX target to act as Replica
ssh -o StrictHostKeyChecking=no root@10.0.0.20 'mysql -e "CREATE USER IF NOT EXISTS \'repl\'@\'%\' IDENTIFIED BY \'mig_password\'; GRANT REPLICATION SLAVE ON *.* TO \'repl\'@\'%\'; FLUSH PRIVILEGES;"'
ssh -o StrictHostKeyChecking=no root@10.0.0.20 'mysqldump --all-databases --single-transaction --master-data=1 --quick' | ssh -o StrictHostKeyChecking=no centos@$TARGET_IP 'mysql'
ssh -o StrictHostKeyChecking=no centos@$TARGET_IP 'mysql -e "CHANGE MASTER TO MASTER_HOST=\'10.0.0.20\', MASTER_USER=\'repl\', MASTER_PASSWORD=\'mig_password\'; START SLAVE;"'

# Server: api-prod-01 -> flex-api-01 (Category: windows_app)
TARGET_IP="192.168.1.25"
echo 'Syncing Windows App for api-prod-01'
# Windows file transfer using initial SMB / Robocopy approach from orchestration node or target
# NOTE: Requires SMB connectivity from script executor to source 10.0.0.25 and target $TARGET_IP
echo 'Execute robocopy \\10.0.0.25\c$\inetpub \\'$TARGET_IP'\c$\inetpub /MIR /Z /W:5' > /dev/null
