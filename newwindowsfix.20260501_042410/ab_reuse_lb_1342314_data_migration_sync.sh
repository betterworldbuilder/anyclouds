#!/usr/bin/env bash
set -uo pipefail
echo 'Starting Initial Data Sync Phase'

# Server: ospc-jumpHost -> ospc-jumpHost (Category: linux_app)
TARGET_IP=$(openstack server show ospc-jumpHost -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for ospc-jumpHost'
mkdir -p /tmp/sync_ospc-jumpHost
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_ospc-jumpHost/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_ospc-jumpHost/ centos@$TARGET_IP:/var/www/html/

# Server: u24-postgresl -> u24-postgresl (Category: linux_app)
TARGET_IP=$(openstack server show u24-postgresl -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for u24-postgresl'
mkdir -p /tmp/sync_u24-postgresl
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_u24-postgresl/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_u24-postgresl/ centos@$TARGET_IP:/var/www/html/

# Server: u24-FrontEnd -> u24-FrontEnd (Category: linux_app)
TARGET_IP=$(openstack server show u24-FrontEnd -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for u24-FrontEnd'
mkdir -p /tmp/sync_u24-FrontEnd
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_u24-FrontEnd/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_u24-FrontEnd/ centos@$TARGET_IP:/var/www/html/

# Server: php-ospc -> php-ospc (Category: linux_app)
TARGET_IP=$(openstack server show php-ospc -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for php-ospc'
mkdir -p /tmp/sync_php-ospc
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_php-ospc/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_php-ospc/ centos@$TARGET_IP:/var/www/html/

# Server: Windows Server 2019Re -> Windows Server 2019Re (Category: linux_app)
TARGET_IP=$(openstack server show Windows Server 2019Re -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for Windows Server 2019Re'
mkdir -p /tmp/sync_Windows Server 2019Re
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_Windows Server 2019Re/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_Windows Server 2019Re/ centos@$TARGET_IP:/var/www/html/

# Server: win2019websql2019 -> win2019websql2019 (Category: linux_app)
TARGET_IP=$(openstack server show win2019websql2019 -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for win2019websql2019'
mkdir -p /tmp/sync_win2019websql2019
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_win2019websql2019/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_win2019websql2019/ centos@$TARGET_IP:/var/www/html/

# Server: Windows Server 2016 + SQL Server 2019 -> Windows Server 2016 + SQL Server 2019 (Category: linux_app)
TARGET_IP=$(openstack server show Windows Server 2016 + SQL Server 2019 -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for Windows Server 2016 + SQL Server 2019'
mkdir -p /tmp/sync_Windows Server 2016 + SQL Server 2019
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_Windows Server 2016 + SQL Server 2019/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_Windows Server 2016 + SQL Server 2019/ centos@$TARGET_IP:/var/www/html/

# Server: u24Backend -> u24Backend (Category: linux_app)
TARGET_IP=$(openstack server show u24Backend -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for u24Backend'
mkdir -p /tmp/sync_u24Backend
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_u24Backend/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_u24Backend/ centos@$TARGET_IP:/var/www/html/

# Server: HA percona 8-02 -> HA percona 8-02 (Category: linux_app)
TARGET_IP=$(openstack server show HA percona 8-02 -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for HA percona 8-02'
mkdir -p /tmp/sync_HA percona 8-02
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_HA percona 8-02/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_HA percona 8-02/ centos@$TARGET_IP:/var/www/html/

# Server: drupal -> drupal (Category: linux_app)
TARGET_IP=$(openstack server show drupal -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for drupal'
mkdir -p /tmp/sync_drupal
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_drupal/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_drupal/ centos@$TARGET_IP:/var/www/html/

# Server: HA-Mysql8-01 -> HA-Mysql8-01 (Category: linux_app)
TARGET_IP=$(openstack server show HA-Mysql8-01 -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for HA-Mysql8-01'
mkdir -p /tmp/sync_HA-Mysql8-01
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_HA-Mysql8-01/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_HA-Mysql8-01/ centos@$TARGET_IP:/var/www/html/

# Server: HA-mariaDB-02 -> HA-mariaDB-02 (Category: linux_app)
TARGET_IP=$(openstack server show HA-mariaDB-02 -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for HA-mariaDB-02'
mkdir -p /tmp/sync_HA-mariaDB-02
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_HA-mariaDB-02/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_HA-mariaDB-02/ centos@$TARGET_IP:/var/www/html/

# Server: php-ospc_Database -> php-ospc_Database (Category: linux_app)
TARGET_IP=$(openstack server show php-ospc_Database -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for php-ospc_Database'
mkdir -p /tmp/sync_php-ospc_Database
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_php-ospc_Database/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_php-ospc_Database/ centos@$TARGET_IP:/var/www/html/

# Server: HA percona 8-03 -> HA percona 8-03 (Category: linux_app)
TARGET_IP=$(openstack server show HA percona 8-03 -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for HA percona 8-03'
mkdir -p /tmp/sync_HA percona 8-03
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_HA percona 8-03/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_HA percona 8-03/ centos@$TARGET_IP:/var/www/html/

# Server: HA-mariaDB-03 -> HA-mariaDB-03 (Category: linux_app)
TARGET_IP=$(openstack server show HA-mariaDB-03 -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for HA-mariaDB-03'
mkdir -p /tmp/sync_HA-mariaDB-03
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_HA-mariaDB-03/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_HA-mariaDB-03/ centos@$TARGET_IP:/var/www/html/

# Server: Stack-05_Database -> Stack-05_Database (Category: linux_app)
TARGET_IP=$(openstack server show Stack-05_Database -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for Stack-05_Database'
mkdir -p /tmp/sync_Stack-05_Database
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_Stack-05_Database/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_Stack-05_Database/ centos@$TARGET_IP:/var/www/html/

# Server: sql -> sql (Category: linux_app)
TARGET_IP=$(openstack server show sql -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for sql'
mkdir -p /tmp/sync_sql
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_sql/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_sql/ centos@$TARGET_IP:/var/www/html/

# Server: HA-Mysql8-02 -> HA-Mysql8-02 (Category: linux_app)
TARGET_IP=$(openstack server show HA-Mysql8-02 -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for HA-Mysql8-02'
mkdir -p /tmp/sync_HA-Mysql8-02
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_HA-Mysql8-02/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_HA-Mysql8-02/ centos@$TARGET_IP:/var/www/html/

# Server: HA-mariaDB-01 -> HA-mariaDB-01 (Category: linux_app)
TARGET_IP=$(openstack server show HA-mariaDB-01 -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for HA-mariaDB-01'
mkdir -p /tmp/sync_HA-mariaDB-01
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_HA-mariaDB-01/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_HA-mariaDB-01/ centos@$TARGET_IP:/var/www/html/

# Server: Instance-05-03 -> Instance-05-03 (Category: linux_app)
TARGET_IP=$(openstack server show Instance-05-03 -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for Instance-05-03'
mkdir -p /tmp/sync_Instance-05-03
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_Instance-05-03/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_Instance-05-03/ centos@$TARGET_IP:/var/www/html/

# Server: HA percona 8-01 -> HA percona 8-01 (Category: linux_app)
TARGET_IP=$(openstack server show HA percona 8-01 -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for HA percona 8-01'
mkdir -p /tmp/sync_HA percona 8-01
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_HA percona 8-01/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_HA percona 8-01/ centos@$TARGET_IP:/var/www/html/

# Server: Instance-05-02 -> Instance-05-02 (Category: linux_app)
TARGET_IP=$(openstack server show Instance-05-02 -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for Instance-05-02'
mkdir -p /tmp/sync_Instance-05-02
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_Instance-05-02/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_Instance-05-02/ centos@$TARGET_IP:/var/www/html/

# Server: HA-Mysql8-03 -> HA-Mysql8-03 (Category: linux_app)
TARGET_IP=$(openstack server show HA-Mysql8-03 -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for HA-Mysql8-03'
mkdir -p /tmp/sync_HA-Mysql8-03
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_HA-Mysql8-03/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_HA-Mysql8-03/ centos@$TARGET_IP:/var/www/html/
