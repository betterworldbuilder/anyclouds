/**
 * generateRehostScript()
 * Full 13-layer OSPC → FLEX server clone script generator.
 * Called from agent1.html when mode === 'rehost'.
 */
window.generateRehostScript = function() {
    try {
        const custName  = (document.getElementById('project_customer_name')||{value:'UnknownCustomer'}).value||'UnknownCustomer';
        const safeName  = custName.replace(/[^a-zA-Z0-9_-]/g,'_');
        const fUser     = (document.getElementById('flex_ssh_user')||{value:'ubuntu'}).value||'ubuntu';
        const oUser     = (document.getElementById('ospc_ssh_user')||{value:'ubuntu'}).value||fUser;
        const sshKey    = '/home/dzoan/.ssh/id_rsa';
        const isDryRun  = (document.getElementById('rehost_dry_run')||{checked:true}).checked;
        const appPaths  = ((document.getElementById('rehost_app_paths')||{value:'/opt/app /srv /var/www /var/lib/app'}).value||'/opt/app').trim();

        const L = {
            identity : (document.getElementById('rl_identity')||{checked:true}).checked,
            ssh      : (document.getElementById('rl_ssh')||{checked:true}).checked,
            users    : (document.getElementById('rl_users')||{checked:true}).checked,
            disk     : (document.getElementById('rl_disk')||{checked:false}).checked,
            packages : (document.getElementById('rl_packages')||{checked:true}).checked,
            kernel   : (document.getElementById('rl_kernel')||{checked:true}).checked,
            network  : (document.getElementById('rl_network')||{checked:false}).checked,
            runtime  : (document.getElementById('rl_runtime')||{checked:true}).checked,
            appcode  : (document.getElementById('rl_appcode')||{checked:true}).checked,
            services : (document.getElementById('rl_services')||{checked:true}).checked,
            data     : (document.getElementById('rl_data')||{checked:false}).checked,
            tls      : (document.getElementById('rl_tls')||{checked:true}).checked,
            external : (document.getElementById('rl_external')||{checked:false}).checked,
        };

        const activeL = Object.entries(L).filter(([,v])=>v).map(([k])=>k).join(', ');
        const sec = (t) => `\necho ""\necho "══════════════════════ ${t} ══════════════════════"\n`;

        let s = `#!/usr/bin/env bash\n`;
        s += `# set -e intentionally omitted — each layer handles its own errors\n`;
        s += `set -uo pipefail\n\n`;
        s += `# ================================================================\n`;
        s += `# OSPC -> FLEX  Full Server Rehost Clone Script\n`;
        s += `# Customer  : ${custName}\n`;
        s += `# Generated : $(date)\n`;
        s += `# Layers    : ${activeL}\n`;
        s += `# ================================================================\n\n`;
        s += `DRY_RUN=${isDryRun ? '1' : '0'}\n`;
        s += `SRC_USER="${oUser}"\n`;
        s += `DST_USER="${fUser}"\n`;
        s += `SSH_KEY="${sshKey}"\n`;
        s += `SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"\n`;
        s += `RSYNC_OPTS="-aHAX --numeric-ids --info=progress2"\n`;
        s += `APP_PATHS="${appPaths}"\n`;
        s += `AUDIT_DIR="./migration-csv/${safeName}-audit"\n`;
        s += `mkdir -p "$AUDIT_DIR"\n\n`;
        s += `# DRY_RUN wrapper: prints command instead of running it\n`;
        s += `run() {\n  if [ "$DRY_RUN" = "1" ]; then\n    echo "  [DRY] $*"\n  else\n    eval "$@"\n  fi\n}\n\n`;
        s += `src_cmd() { ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "$@" 2>/dev/null; }\n`;
        s += `dst_cmd() { ssh $SSH_OPTS "$DST_USER@$DST_IP" "$@" 2>/dev/null; }\n`;
        s += `src_pull() { scp -q $SSH_OPTS "$SRC_USER@$SRC_IP:$1" "$2" 2>/dev/null || true; }\n`;
        s += `dst_push() { scp -q $SSH_OPTS "$1" "$DST_USER@$DST_IP:$2" 2>/dev/null || true; }\n\n`;

        const cards = document.querySelectorAll('.custom-node-group-s2');
        if (cards.length === 0) {
            s += `echo "WARNING: No nodes loaded — import topology first."\n`;
        } else {
            const seen = new Set();
            cards.forEach(card => {
                const name    = card.getAttribute('data-name') || 'node';
                const flexIp  = (card.querySelector('input[name="flex_custom_ip[]"]')||{value:''}).value.trim();
                const ospcIp  = (card.querySelector('input[name="ospc_custom_ip[]"]')||{value:''}).value.trim();

                if (!flexIp || flexIp === 'N/A' || flexIp === '0.0.0.0') { s += `echo "[SKIP] ${name} -- no FLEX IP"\n`; return; }
                if (seen.has(flexIp)) { s += `echo "[SKIP] ${name} -- FLEX ${flexIp} already done"\n`; return; }
                seen.add(flexIp);

                s += `\necho ""\n`;
                s += `echo "##############################################################"\n`;
                s += `echo "#  NODE : ${name}"\n`;
                s += `echo "#  OSPC : ${ospcIp || '(not set)'}  -->  FLEX : ${flexIp}"\n`;
                s += `echo "##############################################################"\n`;
                s += `SRC_IP="${ospcIp}"\n`;
                s += `DST_IP="${flexIp}"\n`;
                s += `NODE_AUDIT="$AUDIT_DIR/${name}"\n`;
                s += `mkdir -p "$NODE_AUDIT"\n\n`;

                // PREFLIGHT
                s += `# PREFLIGHT SSH checks\n`;
                if (ospcIp) s += `src_cmd "echo OK" || { echo "[ERROR] Cannot SSH to OSPC $SRC_IP -- skipping"; continue 2>/dev/null || true; }\n`;
                s += `dst_cmd "echo OK" || { echo "[ERROR] Cannot SSH to FLEX $DST_IP -- skipping"; continue 2>/dev/null || true; }\n\n`;

                // PHASE 1 — AUDIT
                if (ospcIp) {
                    s += sec('PHASE 1 -- AUDIT OSPC SOURCE');
                    s += `src_cmd "\n`;
                    s += `  mkdir -p ~/server-clone-audit\n`;
                    s += `  hostnamectl > ~/server-clone-audit/hostnamectl.txt 2>/dev/null || true\n`;
                    s += `  timedatectl > ~/server-clone-audit/timedatectl.txt 2>/dev/null || true\n`;
                    s += `  locale > ~/server-clone-audit/locale.txt 2>/dev/null || true\n`;
                    s += `  getent passwd > ~/server-clone-audit/passwd.txt\n`;
                    s += `  getent group  > ~/server-clone-audit/group.txt\n`;
                    s += `  sudo sshd -T > ~/server-clone-audit/sshd-T.txt 2>/dev/null || true\n`;
                    s += `  sudo tar -czf ~/server-clone-audit/etc-ssh.tgz /etc/ssh 2>/dev/null || true\n`;
                    s += `  dpkg --get-selections > ~/server-clone-audit/dpkg-selections.txt 2>/dev/null || true\n`;
                    s += `  apt-mark showmanual > ~/server-clone-audit/apt-manual.txt 2>/dev/null || true\n`;
                    s += `  grep -r . /etc/apt/sources.list* > ~/server-clone-audit/apt-sources.txt 2>/dev/null || true\n`;
                    s += `  lsblk -f > ~/server-clone-audit/lsblk.txt && df -Th > ~/server-clone-audit/df.txt && cat /etc/fstab > ~/server-clone-audit/fstab.txt\n`;
                    s += `  uname -r > ~/server-clone-audit/kernel.txt\n`;
                    s += `  sysctl -a > ~/server-clone-audit/sysctl.txt 2>/dev/null || true\n`;
                    s += `  grep -r . /etc/sysctl* > ~/server-clone-audit/sysctl-conf.txt 2>/dev/null || true\n`;
                    s += `  grep -r . /etc/security/limits* > ~/server-clone-audit/limits.txt 2>/dev/null || true\n`;
                    s += `  ip addr > ~/server-clone-audit/ip-addr.txt && ip route > ~/server-clone-audit/ip-route.txt\n`;
                    s += `  systemctl list-unit-files --type=service > ~/server-clone-audit/systemd-services.txt\n`;
                    s += `  systemctl list-unit-files --state=enabled > ~/server-clone-audit/systemd-enabled.txt\n`;
                    s += `  ss -ltnp > ~/server-clone-audit/ports.txt\n`;
                    s += `  sudo crontab -l > ~/server-clone-audit/root-crontab.txt 2>/dev/null || true\n`;
                    s += `  crontab -l > ~/server-clone-audit/user-crontab.txt 2>/dev/null || true\n`;
                    s += `  tar -czf ~/server-clone-audit.tgz ~/server-clone-audit/ 2>/dev/null\n`;
                    s += `"\n`;
                    s += `src_pull "~/server-clone-audit.tgz" "$NODE_AUDIT/audit.tgz"\n`;
                    s += `echo "[AUDIT] Saved $NODE_AUDIT/audit.tgz"\n\n`;
                }

                // PHASE 2 — CLONE
                s += sec('PHASE 2 -- CLONE TO FLEX (safe order)');

                if (L.identity && ospcIp) {
                    s += `echo "[L1] Server Identity"\n`;
                    s += `SRC_HOST=$(src_cmd "hostname -f 2>/dev/null || hostname")\n`;
                    s += `SRC_TZ=$(src_cmd "cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo UTC")\n`;
                    s += `run dst_cmd "sudo hostnamectl set-hostname '$SRC_HOST'"\n`;
                    s += `run dst_cmd "sudo timedatectl set-timezone '$SRC_TZ'"\n\n`;
                }

                if (L.ssh && ospcIp) {
                    s += `echo "[L2] SSH & Access"\n`;
                    s += `src_pull "/etc/ssh/sshd_config" "/tmp/${name}_sshd_config"\n`;
                    s += `run dst_push "/tmp/${name}_sshd_config" "/tmp/sshd_config" && run dst_cmd "sudo cp /tmp/sshd_config /etc/ssh/sshd_config && sudo systemctl reload ssh || true"\n`;
                    s += `src_pull "~/.ssh/authorized_keys" "/tmp/${name}_authkeys" && run dst_push "/tmp/${name}_authkeys" "~/.ssh/authorized_keys" && run dst_cmd "chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"\n`;
                    s += `src_cmd "sudo tar -czf /tmp/sudoers_d.tgz /etc/sudoers.d/ 2>/dev/null || true" && src_pull "/tmp/sudoers_d.tgz" "/tmp/${name}_sudoers_d.tgz"\n`;
                    s += `run dst_push "/tmp/${name}_sudoers_d.tgz" "/tmp/sudoers_d.tgz" && run dst_cmd "sudo tar -xzf /tmp/sudoers_d.tgz -C / 2>/dev/null || true"\n\n`;
                }

                if (L.users && ospcIp) {
                    s += `echo "[L3] Users & Groups (UID/GID preserved)"\n`;
                    s += `src_cmd "getent passwd | awk -F: '\\$3>=1000 && \\$3<65000{print}'" | while IFS=: read user pw uid gid gecos home shell; do\n`;
                    s += `  run dst_cmd "sudo groupadd -g $gid $user 2>/dev/null || true && sudo useradd -u $uid -g $gid -m -s '$shell' -c '$gecos' '$user' 2>/dev/null || true"\n`;
                    s += `done\n`;
                    s += `run "rsync $RSYNC_OPTS --rsync-path='sudo rsync' -e 'ssh $SSH_OPTS' $SRC_USER@$SRC_IP:/home/ /tmp/${name}_homes/"\n`;
                    s += `run "rsync $RSYNC_OPTS --rsync-path='sudo rsync' -e 'ssh $SSH_OPTS' /tmp/${name}_homes/ $DST_USER@$DST_IP:/home/"\n\n`;
                }

                if (L.disk && ospcIp) {
                    s += `echo "[L4] Disk/Mounts -- AUDIT ONLY (no partition changes)"\n`;
                    s += `src_cmd "lsblk -f; df -Th; cat /etc/fstab" > "$NODE_AUDIT/L4_disk.txt" 2>/dev/null || true\n`;
                    s += `echo "  Disk layout saved to $NODE_AUDIT/L4_disk.txt -- apply fstab entries MANUALLY"\n\n`;
                }

                if (L.packages) {
                    s += `echo "[L5] Packages & Repos"\n`;
                    s += `run dst_cmd "sudo sed -i '/rax\\.mirror\\.rackspace\\.com/d;/mirror\\.rackspace\\.com\\/opensuse/d' /etc/apt/sources.list 2>/dev/null || true"\n`;
                    s += `run dst_cmd "sudo find /etc/apt/sources.list.d/ \\( -name 'holland*' -o -name '*rackspace*' \\) -delete 2>/dev/null || true"\n`;
                    if (ospcIp) {
                        s += `APT_LIST=$(src_cmd "apt-mark showmanual 2>/dev/null" | tr '\\n' ' ' || true)\n`;
                        s += `[ -n "$APT_LIST" ] && run dst_cmd "sudo apt-get update -qq 2>/dev/null || true && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $APT_LIST" || true\n\n`;
                    }
                }

                if (L.kernel && ospcIp) {
                    s += `echo "[L6] Kernel / Sysctl / Limits"\n`;
                    s += `src_cmd "sudo cat /etc/sysctl.conf; grep -r . /etc/sysctl.d/ 2>/dev/null" > "/tmp/${name}_sysctl.conf" || true\n`;
                    s += `src_cmd "grep -r . /etc/security/limits.conf /etc/security/limits.d/ 2>/dev/null" > "/tmp/${name}_limits.conf" || true\n`;
                    s += `run dst_push "/tmp/${name}_sysctl.conf" "/tmp/sysctl_clone.conf" && run dst_cmd "sudo cp /tmp/sysctl_clone.conf /etc/sysctl.d/99-ospc-clone.conf && sudo sysctl --system 2>/dev/null || true"\n`;
                    s += `[ -s "/tmp/${name}_limits.conf" ] && run dst_push "/tmp/${name}_limits.conf" "/tmp/limits_clone.conf" && run dst_cmd "sudo cp /tmp/limits_clone.conf /etc/security/limits.d/99-ospc-clone.conf" || true\n\n`;
                }

                if (L.network && ospcIp) {
                    s += `echo "[L7] Network -- EXPORT ONLY (IPs differ on FLEX)"\n`;
                    s += `src_cmd "ip addr; ip route; cat /etc/netplan/*.yaml 2>/dev/null || true" > "$NODE_AUDIT/L7_network.txt" 2>/dev/null || true\n`;
                    s += `echo "  Network config saved to $NODE_AUDIT/L7_network.txt -- update IPs/NIC names MANUALLY"\n\n`;
                }

                if (L.runtime && ospcIp) {
                    s += `echo "[L8] Runtime Environment"\n`;
                    s += `PYTHON_V=$(src_cmd "python3 --version 2>/dev/null" | awk '{print $2}' | cut -d. -f1-2 || true)\n`;
                    s += `NODE_V=$(src_cmd "node --version 2>/dev/null" | tr -d 'v' || true)\n`;
                    s += `HAS_DOCKER=$(src_cmd "which docker 2>/dev/null" || true)\n`;
                    s += `HAS_PM2=$(src_cmd "which pm2 2>/dev/null" || true)\n`;
                    s += `[ -n "$PYTHON_V" ] && run dst_cmd "which python3 || sudo apt-get install -y python3 python3-pip python3-venv" || true\n`;
                    s += `[ -n "$NODE_V" ] && run dst_cmd "which node || (curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt-get install -y nodejs)" || true\n`;
                    s += `[ -n "$HAS_DOCKER" ] && run dst_cmd "which docker || (curl -fsSL https://get.docker.com | sudo sh)" || true\n`;
                    s += `[ -n "$HAS_PM2" ] && run dst_cmd "which pm2 || sudo npm install -g pm2" || true\n\n`;
                }

                if (L.appcode && ospcIp) {
                    s += `echo "[L9] App Code & Config"\n`;
                    s += `for SRC_PATH in ${appPaths}; do\n`;
                    s += `  src_cmd "[ -d $SRC_PATH ] && echo exists" 2>/dev/null | grep -q exists || continue\n`;
                    s += `  echo "  Syncing $SRC_PATH"\n`;
                    s += `  LOCAL_TMP="/tmp/${name}_app$(echo $SRC_PATH | tr '/' '_')"\n`;
                    s += `  run "mkdir -p $LOCAL_TMP"\n`;
                    s += `  run "rsync $RSYNC_OPTS --rsync-path='sudo rsync' -e 'ssh $SSH_OPTS' $SRC_USER@$SRC_IP:$SRC_PATH/ $LOCAL_TMP/"\n`;
                    s += `  run "rsync $RSYNC_OPTS --rsync-path='sudo rsync' -e 'ssh $SSH_OPTS' $LOCAL_TMP/ $DST_USER@$DST_IP:$SRC_PATH/"\n`;
                    s += `done\n`;
                    s += `src_cmd "find ${appPaths} -name '.env' -o -name '*.yml' -o -name '*.yaml' -o -name '*.ini' 2>/dev/null | head -30" > "$NODE_AUDIT/L9_configs.txt" 2>/dev/null || true\n`;
                    s += `echo "  Config file list saved to $NODE_AUDIT/L9_configs.txt -- review endpoints/secrets before starting services"\n\n`;
                }

                if (L.services && ospcIp) {
                    s += `echo "[L10] Systemd Units & Cron"\n`;
                    s += `src_cmd "sudo tar -czf /tmp/systemd_units.tgz /etc/systemd/system/ 2>/dev/null || true" && src_pull "/tmp/systemd_units.tgz" "/tmp/${name}_systemd.tgz"\n`;
                    s += `run dst_push "/tmp/${name}_systemd.tgz" "/tmp/systemd_units.tgz" && run dst_cmd "sudo tar -xzf /tmp/systemd_units.tgz -C / 2>/dev/null || true && sudo systemctl daemon-reload"\n`;
                    s += `ENABLED=$(src_cmd "systemctl list-unit-files --state=enabled --type=service --no-legend 2>/dev/null | awk '{print \\$1}'" || true)\n`;
                    s += `for svc in $ENABLED; do run dst_cmd "sudo systemctl enable '$svc' 2>/dev/null || true"; done\n`;
                    s += `src_cmd "sudo tar -czf /tmp/cron_backup.tgz /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly 2>/dev/null || true" && src_pull "/tmp/cron_backup.tgz" "/tmp/${name}_cron.tgz"\n`;
                    s += `run dst_push "/tmp/${name}_cron.tgz" "/tmp/cron_backup.tgz" && run dst_cmd "sudo tar -xzf /tmp/cron_backup.tgz -C / 2>/dev/null || true"\n\n`;
                }

                if (L.data && ospcIp) {
                    s += `echo "[L11] Data"\n`;
                    s += `for DATA_PATH in /var/lib/app /srv/data; do\n`;
                    s += `  src_cmd "[ -d $DATA_PATH ] && echo exists" 2>/dev/null | grep -q exists || continue\n`;
                    s += `  run "rsync $RSYNC_OPTS --rsync-path='sudo rsync' -e 'ssh $SSH_OPTS' $SRC_USER@$SRC_IP:$DATA_PATH/ $DST_USER@$DST_IP:$DATA_PATH/"\n`;
                    s += `done\n`;
                    s += `echo "  DB DUMP (run manually on OSPC source):"\n`;
                    s += `echo "    pg_dump -U postgres DBNAME | gzip > /tmp/db.sql.gz  # then scp to FLEX and restore"\n`;
                    s += `echo "    mysqldump -u root -p DBNAME | gzip > /tmp/db.sql.gz"\n\n`;
                }

                if (L.tls && ospcIp) {
                    s += `echo "[L12] TLS & Certs"\n`;
                    s += `src_cmd "[ -d /etc/letsencrypt ] && echo exists" 2>/dev/null | grep -q exists && {\n`;
                    s += `  src_cmd "sudo tar -czf /tmp/letsencrypt.tgz /etc/letsencrypt/ 2>/dev/null || true"\n`;
                    s += `  src_pull "/tmp/letsencrypt.tgz" "/tmp/${name}_letsencrypt.tgz"\n`;
                    s += `  run dst_push "/tmp/${name}_letsencrypt.tgz" "/tmp/letsencrypt.tgz"\n`;
                    s += `  run dst_cmd "sudo tar -xzf /tmp/letsencrypt.tgz -C / 2>/dev/null || true"\n`;
                    s += `} || true\n`;
                    s += `src_cmd "ls /usr/local/share/ca-certificates/ 2>/dev/null" | while read ca; do\n`;
                    s += `  src_pull "/usr/local/share/ca-certificates/$ca" "/tmp/${name}_ca_$ca"\n`;
                    s += `  run dst_push "/tmp/${name}_ca_$ca" "/usr/local/share/ca-certificates/$ca"\n`;
                    s += `done\n`;
                    s += `run dst_cmd "sudo update-ca-certificates 2>/dev/null || true"\n\n`;
                }

                if (L.external && ospcIp) {
                    s += `echo "[L13] External Dependencies (audit only)"\n`;
                    s += `src_cmd "grep -rE '(DB_HOST|DATABASE_URL|PG_HOST|REDIS_URL|API_URL)' ${appPaths} 2>/dev/null | head -30" > "$NODE_AUDIT/L13_external.txt" 2>/dev/null || true\n`;
                    s += `src_cmd "ss -ltnp 2>/dev/null" >> "$NODE_AUDIT/L13_external.txt" || true\n`;
                    s += `echo "  External config saved to $NODE_AUDIT/L13_external.txt -- update on FLEX"\n\n`;
                }

                // PHASE 3 — VALIDATION
                s += sec('PHASE 3 -- VALIDATION');
                s += `echo "[VALIDATE] Post-clone checks on FLEX $DST_IP"\n`;
                s += `dst_cmd "\n`;
                s += `  echo '--- Hostname ---' && hostnamectl 2>/dev/null | head -5 || true\n`;
                s += `  echo '--- Disk ---' && df -Th\n`;
                s += `  echo '--- Listening ports ---' && ss -ltnp\n`;
                s += `  echo '--- Running services ---' && systemctl list-units --type=service --state=running --no-pager 2>/dev/null | head -15 || true\n`;
                s += `  echo '--- sshd config test ---' && sudo sshd -t 2>/dev/null && echo 'sshd OK' || echo 'sshd config WARNING'\n`;
                s += `" | tee "$NODE_AUDIT/validation.txt" || true\n`;
                s += `echo "[DONE] ${name} complete. Reports: $NODE_AUDIT/"\n`;
            });
        }

        s += `\necho ""\necho "================================================================"\necho "ALL NODES PROCESSED"\necho "Audit + validation reports: ./migration-csv/${safeName}-audit/"\necho "================================================================"\n`;

        const codeEl = document.getElementById('script-output-stage1');
        const panel  = document.getElementById('output-container-stage1');
        if (codeEl) { codeEl.innerHTML = (typeof syntaxHighlight === 'function' ? syntaxHighlight(s) : s); codeEl.setAttribute('data-raw', s); }
        if (panel)  { panel.style.display = 'block'; setTimeout(() => panel.scrollIntoView({behavior:'smooth'}), 100); }
        if (typeof showToast === 'function') showToast(isDryRun ? '🔍 Rehost script generated (DRY RUN)' : '🖥️ Full Rehost script generated');

    } catch(err) {
        console.error('[ReHost] Generator error:', err);
        if (typeof showToast === 'function') showToast('❌ ' + err.message);
    }
};
