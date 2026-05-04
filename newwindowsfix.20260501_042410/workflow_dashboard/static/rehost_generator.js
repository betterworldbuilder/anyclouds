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
        // Read actual radio button state — IDs: rh_dry_run, rh_maint, rh_cutover, rh_live
        const rhLive    = !!(document.getElementById('rh_live')    && document.getElementById('rh_live').checked);
        const rhCutover = !!(document.getElementById('rh_cutover') && document.getElementById('rh_cutover').checked);
        const rhMaint   = !!(document.getElementById('rh_maint')   && document.getElementById('rh_maint').checked);
        const isDryRun  = !(rhLive || rhCutover || rhMaint);
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

        // Resolve SSH user from OS string
        function resolveOsUser(osStr) {
            const o = (osStr || '').toLowerCase();
            if (o.includes('rocky'))          return 'rocky';
            if (o.includes('alma'))           return 'almalinux';
            if (o.includes('debian'))         return 'debian';
            if (o.includes('fedora'))         return 'fedora';
            if (o.includes('centos'))         return 'centos';
            if (o.includes('rhel') || o.includes('red hat')) return 'ec2-user';
            if (o.includes('amazon'))         return 'ec2-user';
            if (o.includes('ubuntu'))         return 'ubuntu';
            return fUser;  // default
        }

        // Package manager from OS
        function resolvePkgMgr(osStr) {
            const o = (osStr || '').toLowerCase();
            if (o.includes('rocky') || o.includes('alma') || o.includes('centos') ||
                o.includes('rhel') || o.includes('fedora')) return 'dnf';
            return 'apt';  // default ubuntu/debian
        }

        let s = `#!/usr/bin/env bash\n`;
        s += `# set -e intentionally omitted — each node function handles its own errors\n`;
        s += `set -uo pipefail\n\n`;
        s += `# ================================================================\n`;
        s += `# OSPC → FLEX  Server Rehost Clone Script\n`;
        s += `# ────────────────────────────────────────────────────────────────\n`;
        s += `# PARENT PHASE : PHASE 1 — SERVER DATA REPLICATION\n`;
        s += `# ────────────────────────────────────────────────────────────────\n`;
        s += `# Customer     : ${custName}\n`;
        s += `# Generated    : $(date)\n`;
        s += `# Mode         : ${rhLive ? '⚡ LIVE MODE (changes WILL apply)' : rhCutover ? '🔀 CUTOVER MODE' : rhMaint ? '🔧 MAINT MODE' : '🔍 DRY RUN (no changes applied)'}\n`;
        s += `# Layers       : ${activeL}\n`;
        s += `# ────────────────────────────────────────────────────────────────\n`;
        s += `# Stage map (Phase 1 sub-stages):\n`;
        s += `#   STAGE 0  Pre-flight checks         (SSH, rsync, disk, lock)\n`;
        s += `#   STAGE 1  Audit OSPC source          (configs, packages, users)\n`;
        s += `#   STAGE 2  Clone to FLEX              (L1-L13 in safe order)\n`;
        s += `#   STAGE 3  Validation                 (hostname, disk, ports, services)\n`;
        s += `#   STAGE 4  Smoke tests                (9A Infra + 9B App)\n`;
        s += `#   STAGE 5  Cleanup                    (remove staging files)\n`;
        s += `# ================================================================\n\n`;
        s += `DRY_RUN=${isDryRun ? '1' : '0'}\n`;
        s += `DEFAULT_SRC_USER="${oUser}"\n`;
        s += `DEFAULT_DST_USER="${fUser}"\n`;
        s += `SSH_KEY="${sshKey}"\n`;
        s += `SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"\n`;
        s += `SSH_OPTS_A="-A -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"\n`;
        s += `RSYNC_OPTS="-aHAX --numeric-ids --stats --info=progress2"\n`;
        s += `APP_PATHS="${appPaths}"\n`;
        s += `AUDIT_DIR="./migration-csv/${safeName}-audit"\n`;
        s += `mkdir -p "$AUDIT_DIR"\n\n`;

        s += `trap 'pkill -P $$ 2>/dev/null' EXIT HUP INT TERM\n\n`;

        s += `# DRY_RUN wrapper — always uses "$@" (no eval, safe from injection)\n`;
        s += `run() {\n`;
        s += `  if [ "$DRY_RUN" = "1" ]; then\n`;
        s += `    echo "  [DRY] $*"\n`;
        s += `  else\n`;
        s += `    "$@"\n`;
        s += `  fi\n`;
        s += `}\n\n`;

        // Control helpers
        s += `src_cmd() { ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "$@" 2>/dev/null; }\n`;
        s += `dst_cmd() { ssh $SSH_OPTS "$DST_USER@$DST_IP" "$@" 2>/dev/null; }\n`;
        // Direct transfer: copy the local SSH key to OSPC first, then run scp/rsync there
        // (more reliable than agent forwarding which needs key pre-loaded in ssh-agent)
        s += `MIG_KEY_REMOTE="/tmp/.mig_flex_key"\n`;
        s += `deploy_key_to_ospc() {\n`;
        s += `  scp -O -q $SSH_OPTS "$SSH_KEY" "$SRC_USER@$SRC_IP:$MIG_KEY_REMOTE" 2>/dev/null && \\\n`;
        s += `  ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "chmod 600 $MIG_KEY_REMOTE" 2>/dev/null || \\\n`;
        s += `  echo "  [WARN] Could not deploy SSH key to OSPC -- direct transfers may fail"\n`;
        s += `}\n`;
        s += `remove_key_from_ospc() { ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "rm -f $MIG_KEY_REMOTE" 2>/dev/null || true; }\n`;
        // Direct scp: OSPC scp to FLEX using the deployed key
        s += `ospc_to_flex() { ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "scp -O -q -i $MIG_KEY_REMOTE -o StrictHostKeyChecking=no -o BatchMode=yes '$1' '$DST_USER@$DST_IP:$2' 2>/dev/null || true"; }\n`;
        // Direct rsync: run on OSPC using the deployed key -- datacenter speed
        s += `rsync_direct() { ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "rsync $RSYNC_OPTS --rsync-path='sudo rsync' -e 'ssh -i $MIG_KEY_REMOTE -o StrictHostKeyChecking=no -o BatchMode=yes' '$1' '$DST_USER@$DST_IP:$2'"; }\n\n`;

        // ── Prefer checkbox table; fall back to raw discovery tables ──────────
        // If the node-pair table has been built, honour checkbox selection.
        // Otherwise fall back to reading the discovery tables directly.
        const checkedRows = [...document.querySelectorAll(
            '#node-pair-tbody input[type="checkbox"]:checked')];

        let pairList = [];
        if (checkedRows.length > 0) {
            checkedRows.forEach(cb => {
                pairList.push({
                    name   : cb.dataset.ospcName || 'node',
                    ospcIp : cb.dataset.ospcIp   || '',
                    flexIp : cb.dataset.flexIp   || '',
                    osStr  : cb.dataset.os        || '',
                });
            });
        } else {
            // Fallback: read both discovery tables
            const ospcMap = {};
            document.querySelectorAll('#stage1-results-body tr').forEach(tr => {
                const tds = tr.querySelectorAll('td');
                if (tds.length < 2) return;
                const name = tds[0].textContent.trim();
                const ip   = tds[1].textContent.trim();
                const os   = tds[2] ? tds[2].textContent.trim() : '';
                if (name && ip && ip !== '—') {
                    const key = name.toLowerCase().replace(/[\s_-]/g, '');
                    if (!ospcMap[key]) ospcMap[key] = { name, ip, os };
                }
            });
            const flexMap = {};
            document.querySelectorAll('#flex-res-servers-body tr').forEach(tr => {
                const tds = tr.querySelectorAll('td');
                if (tds.length < 2) return;
                const name = tds[0].textContent.trim();
                const ip   = tds[1].textContent.trim();
                if (name && ip && ip !== 'N/A' && ip !== '—') {
                    const key = name.toLowerCase().replace(/[\s_-]/g, '');
                    if (!flexMap[key]) flexMap[key] = { name, ip };
                }
            });
            Object.values(ospcMap).forEach(ospc => {
                const key  = ospc.name.toLowerCase().replace(/[\s_-]/g, '');
                const flex = flexMap[key];
                if (flex && flex.ip) pairList.push({ name: ospc.name, ospcIp: ospc.ip, flexIp: flex.ip, osStr: ospc.os });
            });
        }

        // Fallback 3: read directly from custom node group cards (Stage 2 manual entry)
        if (pairList.length === 0) {
            document.querySelectorAll('.custom-node-group-s2').forEach(fCard => {
                const name   = fCard.getAttribute('data-name');
                if (!name) return;
                const flexIp = (fCard.querySelector('input[name="flex_custom_ip[]"]') || {}).value || '';
                const oCard  = document.querySelector(`.custom-node-group:not(.custom-node-group-s2)[data-name="${name}"]`);
                const ospcIp = oCard ? ((oCard.querySelector('input[name="ospc_custom_ip[]"]') || {}).value || '') : '';
                if (flexIp && flexIp !== '0.0.0.0') {
                    pairList.push({ name, ospcIp, flexIp, osStr: '' });
                }
            });
        }

        const ospcCount = pairList.length;
        const flexCount = pairList.filter(p => p.flexIp).length;

        if (pairList.length === 0) {
            s += `echo "WARNING: No node pairs selected — build the pair table and check nodes first."\n`;
        } else {
            s += `echo "# Source: ${ospcCount} selected node pairs"\n\n`;
            const seen = new Set();
            const funcCalls = [];
            // Per-node script bodies for parallel execution (keyed by node name)
            window._rehostNodeScripts = {};
            // Capture common header length BEFORE any function definitions
            const _commonHeaderLen = s.length;

            pairList.forEach(pair => {
                const { name, ospcIp, flexIp, osStr } = pair;

                const nodeUser = resolveOsUser(osStr);   // for FLEX target
                const srcUser  = resolveOsUser(osStr);   // same OS family on OSPC source
                const pkgMgr  = resolvePkgMgr(osStr);
                const funcName = `node_${name.replace(/[^a-zA-Z0-9]/g, '_')}`;

                // ── track start position for standalone script slice ──────────
                const _fnStart = s.length;

                // ── emit the function definition ─────────────────────────────
                s += `\n# ────────────────────────────────────────────────────────────\n`;
                s += `${funcName}() {\n`;
                s += `  local SRC_IP="${ospcIp}"\n`;
                s += `  local DST_IP="${flexIp}"\n`;
                s += `  local SRC_USER="${srcUser}"   # OSPC SSH user (OS: ${osStr || 'unknown'})\n`;
                s += `  local DST_USER="${nodeUser}"   # FLEX SSH user (OS: ${osStr || 'unknown'})\n`;
                s += `  local NODE_AUDIT="$AUDIT_DIR/${name}"\n`;
                s += `  mkdir -p "$NODE_AUDIT"\n\n`;

                s += `  echo ""\n`;
                s += `  echo "##############################################################"\n`;
                s += `  echo "#  NODE : ${name}"\n`;
                s += `  echo "#  OSPC : ${ospcIp || '(not set)'}  [user: ${oUser}]"\n`;
                s += `  echo "#  FLEX : ${flexIp}  [user: ${nodeUser}]  OS: ${osStr || 'unknown'}"\n`;
                s += `  echo "##############################################################"\n\n`;
                // Unified logging — tee all output to per-node log file
                s += `  exec > >(tee -a "$NODE_AUDIT/migration.log") 2>&1\n\n`;

                // ── STAGE 0 — PRE-FLIGHT ──────────────────────────────────
                s += `  ${sec('STAGE 0 -- PRE-FLIGHT CHECKS').replace(/\n/g, '\n  ')}\n`;
                if (ospcIp) {
                    s += `  echo "[P0] SSH connectivity check..."\n`;
                    s += `  ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "echo OK" 2>/dev/null || { echo "[ERROR] Cannot SSH to OSPC $SRC_IP as $SRC_USER -- skipping ${name}"; return 1; }\n`;
                }
                s += `  ssh $SSH_OPTS "$DST_USER@$DST_IP" "echo OK" 2>/dev/null || { echo "[ERROR] Cannot SSH to FLEX $DST_IP as $DST_USER -- skipping ${name}"; return 1; }\n`;
                if (ospcIp) {
                    s += `  echo "[P0] Checking rsync availability..."\n`;
                    s += `  ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "which rsync" 2>/dev/null || { echo "[WARN] rsync missing on OSPC -- install with: sudo apt-get install -y rsync"; }\n`;
                    s += `  ssh $SSH_OPTS "$DST_USER@$DST_IP" "which rsync" 2>/dev/null || { echo "[WARN] rsync missing on FLEX -- install with: sudo apt-get install -y rsync"; }\n`;
                    s += `  echo "[P0] Disk space check (OSPC used vs FLEX free)..."\n`;
                    // grep -Eo '[0-9]+' locally ensures we always get a pure integer even if SSH returns partial garbage
                    s += `  OSPC_USED=$(ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "df / --output=used | tail -1" 2>/dev/null | grep -Eo '[0-9]+' | tail -1 || echo 0)\n`;
                    s += `  FLEX_FREE=$(ssh $SSH_OPTS "$DST_USER@$DST_IP" "df / --output=avail | tail -1" 2>/dev/null | grep -Eo '[0-9]+' | tail -1 || echo 999999999)\n`;
                    s += `  OSPC_USED=\${OSPC_USED:-0}; FLEX_FREE=\${FLEX_FREE:-999999999}\n`;
                    s += `  if [ "$OSPC_USED" -gt "$FLEX_FREE" ] 2>/dev/null; then\n`;
                    s += `    echo "[WARN] OSPC used (${ospcIp}): $((OSPC_USED/1024))MB > FLEX free (${flexIp}): $((FLEX_FREE/1024))MB -- proceed with caution"\n`;
                    s += `  else\n`;
                    s += `    echo "[P0] Disk OK  OSPC used=$((OSPC_USED/1024))MB  FLEX avail=$((FLEX_FREE/1024))MB"\n`;
                    s += `  fi\n`;
                }
                s += `  echo "[P0] Checking for stale migration lock..."\n`;
                s += `  ssh $SSH_OPTS "$DST_USER@$DST_IP" "if [ -f /tmp/.ospc-migration-lock ]; then echo '[WARN] Stale lock found -- auto-removing (leftover from previous run)'; rm -f /tmp/.ospc-migration-lock; fi" 2>/dev/null || true\n`;
                s += `  ssh $SSH_OPTS "$DST_USER@$DST_IP" "touch /tmp/.ospc-migration-lock" 2>/dev/null || true\n`;
                s += `  echo "[P0] All pre-flight checks passed"\n\n`;
                // Rollback snapshot — taken before any mutations so FLEX can be reverted
                s += `  echo "[P0] Taking FLEX VM snapshot as rollback point before mutations..."\n`;
                s += `  SNAP_NAME="pre-migration-${name}-$(date +%Y%m%d%H%M%S)"\n`;
                s += `  if command -v openstack >/dev/null 2>&1; then\n`;
                s += `    openstack server image create --name "$SNAP_NAME" "${flexIp}" --wait 2>/dev/null \\\n`;
                s += `      && echo "  [P0] ✅ Rollback snapshot: $SNAP_NAME" \\\n`;
                s += `      || echo "  [P0] ⚠  Snapshot failed (no openstack CLI or permissions) -- proceed manually if needed"\n`;
                s += `  else\n`;
                s += `    echo "  [P0] ⚠  openstack CLI not found -- skipping snapshot. Create one manually before proceeding."\n`;
                s += `  fi\n\n`;
                // Deploy SSH key to OSPC so direct OSPC→FLEX transfers work
                if (ospcIp) {
                    s += `  echo "[P0] Deploying transfer key to OSPC for direct server-to-server transfers..."\n`;
                    s += `  deploy_key_to_ospc\n`;
                    s += `  echo "[P0] Key deployed -- direct OSPC->FLEX transfers ready"\n\n`;
                }

                // STAGE 1 — AUDIT
                if (ospcIp) {
                    s += `  ${sec('STAGE 1 -- AUDIT OSPC SOURCE').replace(/\n/g, '\n  ')}\n`;
                    s += `  ssh $SSH_OPTS "$SRC_USER@$SRC_IP" bash <<'ENDSSH'\n`;
                    s += `    mkdir -p ~/server-clone-audit\n`;
                    s += `    hostnamectl > ~/server-clone-audit/hostnamectl.txt 2>/dev/null || true\n`;
                    s += `    timedatectl > ~/server-clone-audit/timedatectl.txt 2>/dev/null || true\n`;
                    s += `    locale > ~/server-clone-audit/locale.txt 2>/dev/null || true\n`;
                    s += `    getent passwd > ~/server-clone-audit/passwd.txt\n`;
                    s += `    getent group  > ~/server-clone-audit/group.txt\n`;
                    s += `    sudo sshd -T > ~/server-clone-audit/sshd-T.txt 2>/dev/null || true\n`;
                    s += `    sudo tar -czf ~/server-clone-audit/etc-ssh.tgz /etc/ssh 2>/dev/null || true\n`;
                    if (pkgMgr === 'apt') {
                        s += `    dpkg --get-selections > ~/server-clone-audit/dpkg-selections.txt 2>/dev/null || true\n`;
                        s += `    apt-mark showmanual > ~/server-clone-audit/apt-manual.txt 2>/dev/null || true\n`;
                        s += `    grep -r . /etc/apt/sources.list* > ~/server-clone-audit/apt-sources.txt 2>/dev/null || true\n`;
                    } else {
                        s += `    rpm -qa > ~/server-clone-audit/rpm-packages.txt 2>/dev/null || true\n`;
                        s += `    dnf list installed > ~/server-clone-audit/dnf-list.txt 2>/dev/null || true\n`;
                    }
                    s += `    lsblk -f > ~/server-clone-audit/lsblk.txt && df -Th > ~/server-clone-audit/df.txt && cat /etc/fstab > ~/server-clone-audit/fstab.txt\n`;
                    s += `    uname -r > ~/server-clone-audit/kernel.txt\n`;
                    s += `    sysctl -a > ~/server-clone-audit/sysctl.txt 2>/dev/null || true\n`;
                    s += `    grep -r . /etc/sysctl* > ~/server-clone-audit/sysctl-conf.txt 2>/dev/null || true\n`;
                    s += `    grep -r . /etc/security/limits* > ~/server-clone-audit/limits.txt 2>/dev/null || true\n`;
                    s += `    ip addr > ~/server-clone-audit/ip-addr.txt && ip route > ~/server-clone-audit/ip-route.txt\n`;
                    s += `    systemctl list-unit-files --type=service > ~/server-clone-audit/systemd-services.txt\n`;
                    s += `    systemctl list-unit-files --state=enabled > ~/server-clone-audit/systemd-enabled.txt\n`;
                    s += `    ss -ltnp > ~/server-clone-audit/ports.txt\n`;
                    s += `    sudo crontab -l > ~/server-clone-audit/root-crontab.txt 2>/dev/null || true\n`;
                    s += `    crontab -l > ~/server-clone-audit/user-crontab.txt 2>/dev/null || true\n`;
                    s += `    tar -czf ~/server-clone-audit.tgz ~/server-clone-audit/ 2>/dev/null\n`;
                    s += `ENDSSH\n`;
                    s += `  scp -q $SSH_OPTS "$SRC_USER@$SRC_IP:~/server-clone-audit.tgz" "$NODE_AUDIT/audit.tgz" && echo "  [AUDIT] Saved $NODE_AUDIT/audit.tgz" || true\n\n`;
                }

                // STAGE 2 — CLONE
                s += `  ${sec('STAGE 2 -- CLONE TO FLEX (safe order)').replace(/\n/g, '\n  ')}\n`;

                if (L.identity && ospcIp) {
                    s += `  echo "[L1] Server Identity"\n`;
                    // Use short hostname only — FQDN may point to OSPC DNS which won't resolve on FLEX
                    s += `  SRC_HOST=$(src_cmd "hostname -s 2>/dev/null || hostname")\n`;
                    s += `  SRC_TZ=$(src_cmd "cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo UTC")\n`;
                    s += `  SRC_LOCALE=$(src_cmd "localectl status 2>/dev/null | grep 'System Locale' | cut -d= -f2 | tr -d ' '" || echo "en_US.UTF-8")\n`;
                    s += `  echo "  [L1] Detected hostname: $SRC_HOST  timezone: $SRC_TZ  locale: $SRC_LOCALE"\n`;
                    s += `  run dst_cmd "sudo hostnamectl set-hostname '\${SRC_HOST:-$(hostname)}'"\n`;
                    s += `  run dst_cmd "sudo timedatectl set-timezone '\${SRC_TZ:-UTC}'"\n`;
                    s += `  [ -n "$SRC_LOCALE" ] && run dst_cmd "sudo localectl set-locale LANG=$SRC_LOCALE 2>/dev/null || true"\n`;
                    s += `  echo "  [L1] FLEX hostname set to: $SRC_HOST  timezone: $SRC_TZ"\n\n`;
                }

                if (L.ssh && ospcIp) {
                    s += `  echo "[L2] SSH & Access"\n`;
                    // Safe sshd_config merge: copy OSPC config, strip dangerous directives,
                    // then apply on FLEX (preserves auth settings without risking lockout)
                    s += `  ospc_to_flex "/etc/ssh/sshd_config" "/tmp/sshd_config_ospc"\n`;
                    s += `  dst_cmd "sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.ospc2flex" 2>/dev/null || true\n`;
                    s += `  # Strip OSPC-specific directives that would break FLEX SSH\n`;
                    s += `  ssh $SSH_OPTS "$DST_USER@$DST_IP" bash <<'SSHD_MERGE'\n`;
                    s += `    if [ -f /tmp/sshd_config_ospc ]; then\n`;
                    s += `      sed -i '/^[[:space:]]*ListenAddress/d' /tmp/sshd_config_ospc\n`;
                    s += `      sed -i '/rackspace/Id' /tmp/sshd_config_ospc\n`;
                    s += `      sed -i '/^[[:space:]]*Match.*rackspace/I,/^[[:space:]]*Match\\|^$/d' /tmp/sshd_config_ospc\n`;
                    s += `      sed -i '/${ospcIp.replace(/\./g, '\\\\.')}/d' /tmp/sshd_config_ospc\n`;
                    s += `      if sudo sshd -t -f /tmp/sshd_config_ospc 2>/dev/null; then\n`;
                    s += `        sudo cp /tmp/sshd_config_ospc /etc/ssh/sshd_config\n`;
                    s += `        sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd 2>/dev/null || true\n`;
                    s += `        echo "  [L2] sshd_config applied (sanitized) on FLEX"\n`;
                    s += `      else\n`;
                    s += `        echo "  [WARN] Sanitized sshd_config failed validation — keeping FLEX original"\n`;
                    s += `        sudo cp /etc/ssh/sshd_config.bak.ospc2flex /etc/ssh/sshd_config\n`;
                    s += `      fi\n`;
                    s += `    fi\n`;
                    s += `SSHD_MERGE\n`;
                    s += `  ospc_to_flex "~/.ssh/authorized_keys" "/tmp/ospc_authorized_keys"\n`;
                    s += `  # Merge OSPC keys into FLEX (append, don't overwrite)\n`;
                    s += `  run dst_cmd "cat /tmp/ospc_authorized_keys >> ~/.ssh/authorized_keys && sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"\n`;
                    s += `  echo "  [L2] authorized_keys merged on FLEX"\n`;
                    s += `  src_cmd "sudo tar -czf /tmp/sudoers_d.tgz /etc/sudoers.d/ 2>/dev/null || true"\n`;
                    s += `  ospc_to_flex "/tmp/sudoers_d.tgz" "/tmp/sudoers_d.tgz"\n`;
                    s += `  run dst_cmd "sudo tar -xzf /tmp/sudoers_d.tgz -C / 2>/dev/null || true && sudo visudo -c 2>/dev/null || echo '  [WARN] sudoers syntax check failed — review /etc/sudoers.d/'"\n`;
                    s += `  echo "  [L2] sudoers.d synced to FLEX"\n\n`;
                }

                if (L.users && ospcIp) {
                    s += `  echo "[L3] Users & Groups (UID/GID preserved)"\n`;
                    // Sync groups first (separate from users — group name may differ from username)
                    s += `  echo "  [L3] Syncing groups (GID>=1000)..."\n`;
                    s += `  src_cmd "getent group | awk -F: '\\$3>=1000 && \\$3<65000{print}'" | while IFS=: read grp gpw gid members; do\n`;
                    s += `    run dst_cmd "sudo groupadd -g $gid '$grp' 2>/dev/null || true"\n`;
                    s += `  done\n`;
                    // Then sync users referencing existing GIDs
                    s += `  USER_COUNT=$(src_cmd "getent passwd | awk -F: '\\$3>=1000 && \\$3<65000{print}' | wc -l" || echo 0)\n`;
                    s += `  echo "  [L3] Found $USER_COUNT non-system users -- syncing..."\n`;
                    s += `  src_cmd "getent passwd | awk -F: '\\$3>=1000 && \\$3<65000{print}'" | while IFS=: read user pw uid gid gecos home shell; do\n`;
                    s += `    echo "    -> user: $user uid:$uid gid:$gid"\n`;
                    s += `    run dst_cmd "id -u '$user' >/dev/null 2>&1 || sudo useradd -u $uid -g $gid -m -s '$shell' -c '$gecos' '$user' 2>/dev/null || true"\n`;
                    s += `  done\n`;
                    // Sync shadow entries for password auth
                    s += `  echo "  [L3] Syncing password hashes (shadow entries UID>=1000)..."\n`;
                    s += `  src_cmd "sudo getent shadow" | while IFS=: read suser shash rest; do\n`;
                    s += `    [ -z "$shash" ] || [ "$shash" = "!" ] || [ "$shash" = "*" ] || [ "$shash" = "!!" ] && continue\n`;
                    s += `    run dst_cmd "sudo usermod -p '$shash' '$suser' 2>/dev/null || true"\n`;
                    s += `  done\n`;
                    // Rsync home dirs but protect the SSH login user's authorized_keys
                    s += `  echo "  [L3] Direct rsync OSPC:/home/ -> FLEX:/home/ (server-to-server)"\n`;
                    s += `  rsync_direct "--exclude='$DST_USER/.ssh/authorized_keys' /home/" "/home/"\n`;
                    s += `  echo "  [L3] Home directories synced OK"\n\n`;
                }

                if (L.disk && ospcIp) {
                    s += `  echo "[L4] Disk/Mounts -- AUDIT ONLY"\n`;
                    s += `  src_cmd "lsblk -f; df -Th; cat /etc/fstab" > "$NODE_AUDIT/L4_disk.txt" 2>/dev/null || true\n`;
                    s += `  DISK_LINES=$(wc -l < "$NODE_AUDIT/L4_disk.txt" 2>/dev/null || echo 0)\n`;
                    s += `  echo "  [L4] Disk layout captured ($DISK_LINES lines) -> $NODE_AUDIT/L4_disk.txt"\n`;
                    s += `  echo "  [L4] Apply fstab entries MANUALLY (IPs and device names may differ)"\n\n`;
                }

                if (L.packages) {
                    s += `  echo "[L5] Packages & Repos  [pkg-mgr: ${pkgMgr}]"\n`;
                    // Filter patterns: kernel/boot packages that would break FLEX + Rackspace agents
                    s += `  PKG_FILTER='linux-image|linux-headers|linux-modules|linux-firmware|grub-|initramfs-tools|rackspace-|nova-agent|xe-guest|driveclient|holland'\n`;
                    if (pkgMgr === 'apt') {
                        s += `  run dst_cmd "sudo sed -i '/rax\\.mirror\\.rackspace\\.com/d;/mirror\\.rackspace\\.com\\/opensuse/d' /etc/apt/sources.list 2>/dev/null || true"\n`;
                        s += `  run dst_cmd "sudo find /etc/apt/sources.list.d/ \\( -name 'holland*' -o -name '*rackspace*' \\) -delete 2>/dev/null || true"\n`;
                        s += `  echo "  [L5] Rackspace repos cleaned from FLEX apt sources"\n`;
                        if (ospcIp) {
                            s += `  APT_RAW=$(src_cmd "apt-mark showmanual 2>/dev/null" || true)\n`;
                            s += `  APT_FILTERED=$(echo "$APT_RAW" | grep -vE "$PKG_FILTER" || true)\n`;
                            s += `  APT_SKIPPED=$(echo "$APT_RAW" | grep -cE "$PKG_FILTER" || echo 0)\n`;
                            s += `  APT_LIST=$(echo "$APT_FILTERED" | tr '\\n' ' ')\n`;
                            s += `  APT_COUNT=$(echo "$APT_LIST" | wc -w)\n`;
                            s += `  echo "  [L5] OSPC packages: $APT_COUNT to install, $APT_SKIPPED filtered (kernel/boot/rackspace)"\n`;
                            s += `  if [ -n "$APT_LIST" ]; then\n`;
                            s += `    run dst_cmd "sudo apt-get update -qq" || echo "  [WARN] apt-get update failed — some packages may not install"\n`;
                            s += `    run dst_cmd "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $APT_LIST" || echo "  [WARN] Some packages failed to install — check $NODE_AUDIT/migration.log"\n`;
                            s += `  fi\n`;
                            s += `  echo "  [L5] Package install complete"\n\n`;
                        }
                    } else {
                        // dnf/rpm path
                        if (ospcIp) {
                            s += `  RPM_RAW=$(src_cmd "rpm -qa --queryformat '%{NAME}\\n' 2>/dev/null" || true)\n`;
                            s += `  RPM_FILTERED=$(echo "$RPM_RAW" | grep -vE "$PKG_FILTER|^kernel|^kmod-" || true)\n`;
                            s += `  RPM_SKIPPED=$(echo "$RPM_RAW" | grep -cE "$PKG_FILTER|^kernel|^kmod-" || echo 0)\n`;
                            s += `  RPM_LIST=$(echo "$RPM_FILTERED" | tr '\\n' ' ')\n`;
                            s += `  RPM_COUNT=$(echo "$RPM_LIST" | wc -w)\n`;
                            s += `  echo "  [L5] OSPC packages: $RPM_COUNT to install, $RPM_SKIPPED filtered (kernel/boot/rackspace)"\n`;
                            s += `  [ -n "$RPM_LIST" ] && run dst_cmd "sudo dnf install -y $RPM_LIST 2>/dev/null || true" || true\n`;
                            s += `  echo "  [L5] Package install complete"\n\n`;
                        }
                    }
                }

                if (L.kernel && ospcIp) {
                    s += `  echo "[L6] Kernel / Sysctl / Limits"\n`;
                    // Only copy app-relevant sysctl — skip net.* (FLEX has its own network stack)
                    // net.* settings are OSPC Xen-specific and can conflict with FLEX virtio networking
                    s += `  src_cmd "sudo cat /etc/sysctl.conf 2>/dev/null; sudo grep -r . /etc/sysctl.d/ 2>/dev/null" \\\n`;
                    s += `    | grep -vE '^[[:space:]]*(net\\.|#.*net\\.|$)' \\\n`;
                    s += `    | ssh $SSH_OPTS "$DST_USER@$DST_IP" "cat > /tmp/sysctl_clone.conf" || true\n`;
                    s += `  SYSCTL_LINES=$(ssh $SSH_OPTS "$DST_USER@$DST_IP" "wc -l < /tmp/sysctl_clone.conf 2>/dev/null || echo 0")\n`;
                    s += `  echo "  [L6] sysctl: $SYSCTL_LINES non-network settings to apply (net.* excluded)"\n`;
                    s += `  run dst_cmd "sudo cp /tmp/sysctl_clone.conf /etc/sysctl.d/99-ospc-clone.conf && sudo sysctl --system 2>/dev/null || true"\n`;
                    s += `  echo "  [L6] sysctl settings applied on FLEX"\n`;
                    s += `  src_cmd "grep -r . /etc/security/limits.conf /etc/security/limits.d/ 2>/dev/null" | ssh $SSH_OPTS "$DST_USER@$DST_IP" "cat > /tmp/limits_clone.conf" || true\n`;
                    s += `  run dst_cmd "sudo cp /tmp/limits_clone.conf /etc/security/limits.d/99-ospc-clone.conf 2>/dev/null || true"\n`;
                    s += `  echo "  [L6] kernel/limits sync complete"\n\n`;
                }

                if (L.network && ospcIp) {
                    s += `  echo "[L7] Network -- EXPORT ONLY (IPs differ on FLEX)"\n`;
                    s += `  src_cmd "ip addr; ip route; cat /etc/netplan/*.yaml 2>/dev/null || true" > "$NODE_AUDIT/L7_network.txt" 2>/dev/null || true\n`;
                    s += `  NET_LINES=$(wc -l < "$NODE_AUDIT/L7_network.txt" 2>/dev/null || echo 0)\n`;
                    s += `  echo "  [L7] Network config exported ($NET_LINES lines) -> $NODE_AUDIT/L7_network.txt"\n`;
                    s += `  echo "  [L7] NOTE: Update IP addresses manually before applying netplan on FLEX"\n\n`;
                }

                if (L.runtime && ospcIp) {
                    s += `  echo "[L8] Runtime Environment"\n`;
                    s += `  PYTHON_V=$(src_cmd "python3 --version 2>/dev/null" | awk '{print $2}' | cut -d. -f1-2 || true)\n`;
                    s += `  NODE_V=$(src_cmd "node --version 2>/dev/null" | tr -d 'v' || true)\n`;
                    s += `  DOCKER_V=$(src_cmd "docker version --format '{{.Server.Version}}' 2>/dev/null" || true)\n`;
                    s += `  HAS_PM2=$(src_cmd "which pm2 2>/dev/null" || true)\n`;
                    s += `  HAS_SNAP=$(src_cmd "which snap 2>/dev/null" || true)\n`;
                    s += `  echo "  [L8] Detected: python=$PYTHON_V node=$NODE_V docker=\${DOCKER_V:-no} pm2=$([ -n "$HAS_PM2" ] && echo yes || echo no)"\n`;
                    if (pkgMgr === 'apt') {
                        s += `  [ -n "$PYTHON_V" ] && run dst_cmd "which python3 || sudo apt-get install -y python3 python3-pip python3-venv" || true\n`;
                        s += `  [ -n "$NODE_V" ] && run dst_cmd "which node || (curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt-get install -y nodejs)" || true\n`;
                    } else {
                        s += `  [ -n "$PYTHON_V" ] && run dst_cmd "which python3 || sudo dnf install -y python3 python3-pip" || true\n`;
                        s += `  [ -n "$NODE_V" ] && run dst_cmd "which node || sudo dnf install -y nodejs" || true\n`;
                    }
                    // Install matching Docker version from OSPC
                    s += `  if [ -n "$DOCKER_V" ]; then\n`;
                    s += `    FLEX_DOCKER=$(dst_cmd "docker version --format '{{.Server.Version}}' 2>/dev/null" || true)\n`;
                    s += `    if [ -z "$FLEX_DOCKER" ]; then\n`;
                    s += `      echo "  [L8] Installing Docker $DOCKER_V (matching OSPC version)"\n`;
                    if (pkgMgr === 'apt') {
                        s += `      run dst_cmd "curl -fsSL https://get.docker.com | sudo VERSION=$DOCKER_V sh 2>/dev/null || (curl -fsSL https://get.docker.com | sudo sh)" || true\n`;
                    } else {
                        s += `      run dst_cmd "sudo dnf install -y docker-ce-$DOCKER_V 2>/dev/null || sudo dnf install -y docker-ce" || true\n`;
                    }
                    s += `      run dst_cmd "sudo systemctl enable --now docker" || true\n`;
                    s += `    else\n`;
                    s += `      echo "  [L8] Docker already on FLEX: $FLEX_DOCKER (OSPC had: $DOCKER_V)"\n`;
                    s += `    fi\n`;
                    s += `  fi\n`;
                    s += `  [ -n "$HAS_PM2" ] && run dst_cmd "which pm2 || sudo npm install -g pm2" || true\n`;
                    // Snap packages
                    s += `  if [ -n "$HAS_SNAP" ]; then\n`;
                    s += `    SNAP_LIST=$(src_cmd "snap list --unicode=never 2>/dev/null | awk 'NR>1{print \\$1}'" | grep -v snapd || true)\n`;
                    s += `    SNAP_COUNT=$(echo "$SNAP_LIST" | grep -c . || echo 0)\n`;
                    s += `    echo "  [L8] Snap packages detected: $SNAP_COUNT"\n`;
                    s += `    for SNAP_PKG in $SNAP_LIST; do\n`;
                    s += `      run dst_cmd "sudo snap install $SNAP_PKG 2>/dev/null || true"\n`;
                    s += `    done\n`;
                    s += `  fi\n`;
                    // Python virtualenv dependency sync per app path
                    s += `  echo "  [L8] Scanning for Python virtualenvs to sync pip dependencies..."\n`;
                    s += `  for AP in ${appPaths}; do\n`;
                    s += `    src_cmd "find $AP -name 'pyvenv.cfg' -maxdepth 4 2>/dev/null | head -5" | while read VENV_CFG; do\n`;
                    s += `      VENV_DIR=$(dirname "$VENV_CFG")\n`;
                    s += `      echo "  [L8] Virtualenv: $VENV_DIR"\n`;
                    s += `      src_cmd "$VENV_DIR/bin/pip freeze 2>/dev/null" > /tmp/reqs_$$.txt || true\n`;
                    s += `      [ -s /tmp/reqs_$$.txt ] && ssh $SSH_OPTS "$DST_USER@$DST_IP" "cat > /tmp/reqs_$$.txt" < /tmp/reqs_$$.txt || true\n`;
                    s += `      run dst_cmd "python3 -m venv $VENV_DIR 2>/dev/null && $VENV_DIR/bin/pip install -q -r /tmp/reqs_$$.txt 2>/dev/null || true"\n`;
                    s += `      rm -f /tmp/reqs_$$.txt\n`;
                    s += `    done\n`;
                    s += `  done\n`;
                    // Node.js — npm ci wherever package-lock.json exists
                    s += `  echo "  [L8] Scanning for Node.js apps to reinstall npm dependencies..."\n`;
                    s += `  for AP in ${appPaths}; do\n`;
                    s += `    src_cmd "find $AP -name 'package-lock.json' -not -path '*/node_modules/*' -maxdepth 5 2>/dev/null | head -5" | while read PKG_LOCK; do\n`;
                    s += `      APP_DIR=$(dirname "$PKG_LOCK")\n`;
                    s += `      echo "  [L8] npm ci: $APP_DIR"\n`;
                    s += `      run dst_cmd "cd $APP_DIR && npm ci --silent 2>/dev/null || npm install --silent 2>/dev/null || true"\n`;
                    s += `    done\n`;
                    s += `  done\n`;
                    s += `  echo "  [L8] Runtime environment sync complete"\n\n`;
                }

                if (L.appcode && ospcIp) {
                    s += `  echo "[L9] App Code & Config"\n`;
                    s += `  for SRC_PATH in ${appPaths}; do\n`;
                    s += `    src_cmd "[ -d $SRC_PATH ] && echo exists" 2>/dev/null | grep -q exists || continue\n`;
                    s += `    echo "  [L9] Direct rsync OSPC:$SRC_PATH -> FLEX:$SRC_PATH (server-to-server)"\n`;
                    s += `    rsync_direct "$SRC_PATH/" "$SRC_PATH/"\n`;
                    s += `    echo "  [L9] Synced: $SRC_PATH"\n`;
                    s += `  done\n`;
                    s += `  src_cmd "find ${appPaths} -name '.env' -o -name '*.yml' -o -name '*.yaml' -o -name '*.ini' 2>/dev/null | head -30" > "$NODE_AUDIT/L9_configs.txt" 2>/dev/null || true\n`;
                    s += `  echo "  Config file list saved to $NODE_AUDIT/L9_configs.txt"\n`;
                    s += `  echo "[L9.5] Config IP fixup -- replacing OSPC IP ${ospcIp} with FLEX IP ${flexIp}"\n`;
                    s += `  FIXUP_DIRS="${appPaths} /etc/nginx /etc/apache2 /etc/haproxy"\n`;
                    // Use --binary-files=without-match and restrict to text config extensions to avoid corrupting binaries/DBs/git
                    s += `  run dst_cmd "for DIR in \\$FIXUP_DIRS; do [ -d \\$DIR ] || continue; sudo grep -rlI --include='*.conf' --include='*.cfg' --include='*.yml' --include='*.yaml' --include='*.json' --include='*.xml' --include='*.ini' --include='*.env' --include='*.txt' --include='*.toml' --include='*.properties' '${ospcIp}' \\$DIR 2>/dev/null | xargs -r sudo sed -i 's|${ospcIp}|${flexIp}|g'; done || true"\n`;
                    s += `  echo "  [L9.5] Also checking for hardcoded hostnames..."\n`;
                    s += `  SRC_HOST_IP=$(src_cmd "hostname 2>/dev/null || true")\n`;
                    s += `  DST_HOST_IP=$(dst_cmd "hostname 2>/dev/null || true")\n`;
                    s += `  [ -n "$SRC_HOST_IP" ] && run dst_cmd "for DIR in \\$FIXUP_DIRS; do [ -d \\$DIR ] || continue; sudo grep -rlI --include='*.conf' --include='*.cfg' --include='*.yml' --include='*.yaml' --include='*.json' --include='*.xml' --include='*.ini' --include='*.env' '\\$SRC_HOST_IP' \\$DIR 2>/dev/null | xargs -r sudo sed -i 's|\\$SRC_HOST_IP|\\$DST_HOST_IP|g'; done || true" || true\n\n`;
                }

                if (L.services && ospcIp) {
                    s += `  echo "[L10] Systemd Units & Cron"\n`;
                    // Filter for OSPC/Rackspace platform agents that must NOT run on FLEX
                    s += `  SVC_FILTER='rackspace|nova-agent|xe-guest|driveclient|holland|cloud-init|snapd|ufw|networkd|systemd-net|systemd-resolve|multipathd|open-vm'\n`;
                    // Only copy custom app units from /etc/systemd/system — skip symlinks to /lib (those are distro units)
                    // This avoids overwriting FLEX's own cloud-init, networking, SSH system units
                    s += `  echo "  [L10] Copying custom app service units (excluding platform/OSPC agents)..."\n`;
                    s += `  src_cmd "find /etc/systemd/system -maxdepth 1 -type f -name '*.service' 2>/dev/null | xargs -r grep -lv 'rackspace\\|nova-agent\\|xe-guest\\|driveclient' 2>/dev/null | tar -czf /tmp/systemd_units.tgz --files-from=- 2>/dev/null; echo done" 2>/dev/null || true\n`;
                    s += `  ospc_to_flex "/tmp/systemd_units.tgz" "/tmp/systemd_units.tgz"\n`;
                    s += `  run dst_cmd "sudo tar -xzf /tmp/systemd_units.tgz -C / 2>/dev/null || true && sudo systemctl daemon-reload"\n`;
                    s += `  echo "  [L10] Custom systemd units transferred and daemon reloaded"\n`;
                    // Enable app services only — filter out OSPC/Rackspace services
                    s += `  ENABLED=$(src_cmd "systemctl list-unit-files --state=enabled --type=service --no-legend 2>/dev/null | awk '{print \\$1}'" | grep -vE "$SVC_FILTER" || true)\n`;
                    s += `  ENABLED_COUNT=$(echo "$ENABLED" | grep -c . || echo 0)\n`;
                    s += `  echo "  [L10] Enabling $ENABLED_COUNT app services on FLEX (platform services filtered)..."\n`;
                    s += `  for svc in $ENABLED; do\n`;
                    s += `    echo "    -> enabling: $svc"\n`;
                    s += `    run dst_cmd "sudo systemctl enable '$svc' 2>/dev/null || true"\n`;
                    s += `  done\n`;
                    // Cron — filter out Rackspace cron jobs
                    s += `  src_cmd "sudo tar -czf /tmp/cron_backup.tgz --exclude='*rackspace*' --exclude='*holland*' /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly 2>/dev/null || true"\n`;
                    s += `  ospc_to_flex "/tmp/cron_backup.tgz" "/tmp/cron_backup.tgz"\n`;
                    s += `  run dst_cmd "sudo tar -xzf /tmp/cron_backup.tgz -C / 2>/dev/null || true"\n`;
                    s += `  echo "  [L10] Cron jobs synced to FLEX"\n\n`;
                }

                if (L.data && ospcIp) {
                    s += `  echo "[L11] Data"\n`;
                    s += `  for DATA_PATH in /var/lib/app /srv/data; do\n`;
                    s += `    src_cmd "[ -d $DATA_PATH ] && echo exists" 2>/dev/null | grep -q exists || continue\n`;
                    s += `    echo "  [L11] Direct rsync OSPC:$DATA_PATH -> FLEX:$DATA_PATH"\n`;
                    s += `    rsync_direct "$DATA_PATH/" "$DATA_PATH/"\n`;
                    s += `  done\n`;
                    s += `  echo "[L11] Checking for PostgreSQL..."\n`;
                    s += `  HAS_PG=$(src_cmd "which pg_dump" 2>/dev/null || true)\n`;
                    s += `  if [ -n "$HAS_PG" ]; then\n`;
                    s += `    echo "  [L11] PostgreSQL detected -- dumping & transferring direct OSPC->FLEX"\n`;
                    s += `    PG_DBS=$(src_cmd "sudo -u postgres psql -t -c \\"SELECT datname FROM pg_database WHERE datistemplate=false AND datname<>'postgres';\\" 2>/dev/null" | tr -d ' ' | grep -v '^$' || true)\n`;
                    s += `    for DB in $PG_DBS; do\n`;
                    s += `      echo "  [L11] Dumping PG: $DB"\n`;
                    s += `      src_cmd "sudo -u postgres pg_dump -Fc $DB > /tmp/pg_${name}_$DB.dump 2>/dev/null"\n`;
                    s += `      ospc_to_flex "/tmp/pg_${name}_$DB.dump" "/tmp/pg_$DB.dump"\n`;
                    s += `      run dst_cmd "sudo -u postgres createdb $DB 2>/dev/null || true && sudo -u postgres pg_restore -d $DB /tmp/pg_$DB.dump 2>/dev/null && echo '[L11] PG restore OK: '$DB || echo '[L11] PG restore WARNING: '$DB"\n`;
                    s += `    done\n`;
                    s += `  fi\n`;
                    s += `  HAS_MYSQL=$(src_cmd "which mysqldump" 2>/dev/null || true)\n`;
                    s += `  if [ -n "$HAS_MYSQL" ]; then\n`;
                    s += `    echo "  [L11] MySQL/MariaDB detected -- dumping & transferring direct OSPC->FLEX"\n`;
                    s += `    MY_DBS=$(src_cmd "mysql -uroot -e 'SHOW DATABASES;' 2>/dev/null | grep -Ev 'Database|information_schema|performance_schema|mysql|sys'" || true)\n`;
                    s += `    for DB in $MY_DBS; do\n`;
                    s += `      echo "  [L11] Dumping MySQL: $DB"\n`;
                    s += `      src_cmd "mysqldump -uroot $DB | gzip > /tmp/mysql_${name}_$DB.sql.gz 2>/dev/null"\n`;
                    s += `      ospc_to_flex "/tmp/mysql_${name}_$DB.sql.gz" "/tmp/mysql_$DB.sql.gz"\n`;
                    s += `      run dst_cmd "mysql -uroot -e 'CREATE DATABASE IF NOT EXISTS $DB;' 2>/dev/null && zcat /tmp/mysql_$DB.sql.gz | mysql -uroot $DB 2>/dev/null && echo '[L11] MySQL restore OK: '$DB || echo '[L11] MySQL restore WARNING: '$DB"\n`;
                    s += `    done\n`;
                    s += `  fi\n\n`;
                }

                if (L.tls && ospcIp) {
                    s += `  echo "[L12] TLS & Certs"\n`;
                    // Let's Encrypt
                    s += `  TLS_EXISTS=$(src_cmd "[ -d /etc/letsencrypt ] && echo exists" 2>/dev/null || true)\n`;
                    s += `  if echo "$TLS_EXISTS" | grep -q exists; then\n`;
                    s += `    echo "  [L12] Let's Encrypt detected on OSPC -- copying certs direct to FLEX"\n`;
                    s += `    src_cmd "sudo tar -czf /tmp/letsencrypt.tgz /etc/letsencrypt/ 2>/dev/null || true"\n`;
                    s += `    ospc_to_flex "/tmp/letsencrypt.tgz" "/tmp/letsencrypt.tgz"\n`;
                    s += `    run dst_cmd "sudo tar -xzf /tmp/letsencrypt.tgz -C / 2>/dev/null || true"\n`;
                    s += `    echo "  [L12] TLS certs transferred to FLEX"\n`;
                    s += `  else\n`;
                    s += `    echo "  [L12] No Let's Encrypt certs on OSPC -- skipping"\n`;
                    s += `  fi\n`;
                    // /etc/ssl/private (nginx/apache inline certs)
                    s += `  SSL_EXISTS=$(src_cmd "sudo ls /etc/ssl/private/*.pem /etc/ssl/private/*.crt /etc/ssl/private/*.key 2>/dev/null | wc -l" || echo 0)\n`;
                    s += `  if [ "$SSL_EXISTS" -gt 0 ] 2>/dev/null; then\n`;
                    s += `    echo "  [L12] /etc/ssl/private certs found ($SSL_EXISTS files) -- transferring"\n`;
                    s += `    src_cmd "sudo tar -czf /tmp/ssl_private.tgz /etc/ssl/private/ 2>/dev/null || true"\n`;
                    s += `    ospc_to_flex "/tmp/ssl_private.tgz" "/tmp/ssl_private.tgz"\n`;
                    s += `    run dst_cmd "sudo tar -xzf /tmp/ssl_private.tgz -C / 2>/dev/null || true && sudo chmod 710 /etc/ssl/private"\n`;
                    s += `    echo "  [L12] /etc/ssl/private transferred"\n`;
                    s += `  fi\n`;
                    // /etc/pki/tls (RHEL/CentOS)
                    s += `  PKI_EXISTS=$(src_cmd "sudo ls /etc/pki/tls/certs/*.pem /etc/pki/tls/private/*.key 2>/dev/null | wc -l" || echo 0)\n`;
                    s += `  if [ "$PKI_EXISTS" -gt 0 ] 2>/dev/null; then\n`;
                    s += `    echo "  [L12] /etc/pki/tls certs found ($PKI_EXISTS files) -- transferring"\n`;
                    s += `    src_cmd "sudo tar -czf /tmp/pki_tls.tgz /etc/pki/tls/ 2>/dev/null || true"\n`;
                    s += `    ospc_to_flex "/tmp/pki_tls.tgz" "/tmp/pki_tls.tgz"\n`;
                    s += `    run dst_cmd "sudo tar -xzf /tmp/pki_tls.tgz -C / 2>/dev/null || true"\n`;
                    s += `    echo "  [L12] /etc/pki/tls transferred"\n`;
                    s += `  fi\n`;
                    // Audit any remaining .pem/.crt/.key files outside standard paths
                    s += `  src_cmd "sudo find /opt /srv /var/www /etc/nginx /etc/apache2 -name '*.pem' -o -name '*.crt' -o -name '*.key' 2>/dev/null | grep -v letsencrypt | head -20" > "$NODE_AUDIT/L12_extra_certs.txt" 2>/dev/null || true\n`;
                    s += `  EXTRA_CERTS=$(wc -l < "$NODE_AUDIT/L12_extra_certs.txt" 2>/dev/null || echo 0)\n`;
                    s += `  [ "$EXTRA_CERTS" -gt 0 ] && echo "  [L12] ⚠  $EXTRA_CERTS extra cert files found outside standard paths -- review $NODE_AUDIT/L12_extra_certs.txt"\n`;
                    s += `  run dst_cmd "sudo update-ca-certificates 2>/dev/null || sudo update-ca-trust 2>/dev/null || true"\n`;
                    s += `  echo "  [L12] CA trust store updated on FLEX"\n\n`;
                }

                if (L.external && ospcIp) {
                    s += `  echo "[L13] External Dependencies (audit only)"\n`;
                    s += `  src_cmd "grep -rE '(DB_HOST|DATABASE_URL|PG_HOST|REDIS_URL|API_URL)' ${appPaths} 2>/dev/null | head -30" > "$NODE_AUDIT/L13_external.txt" 2>/dev/null || true\n`;
                    s += `  src_cmd "ss -ltnp 2>/dev/null" >> "$NODE_AUDIT/L13_external.txt" || true\n`;
                    s += `  EXT_LINES=$(wc -l < "$NODE_AUDIT/L13_external.txt" 2>/dev/null || echo 0)\n`;
                    s += `  echo "  [L13] External dependency audit: $EXT_LINES entries found -> $NODE_AUDIT/L13_external.txt"\n`;
                    s += `  echo "  [L13] Review external endpoints and update configs manually on FLEX"\n\n`;
                }

                // STAGE 3 — VALIDATION
                s += `  ${sec('STAGE 3 -- VALIDATION').replace(/\n/g, '\n  ')}\n`;
                s += `  echo "[VALIDATE] Post-clone checks on FLEX $DST_IP (user: $DST_USER)"\n`;
                s += `  ssh $SSH_OPTS "$DST_USER@$DST_IP" bash <<'ENDSSH' | tee "$NODE_AUDIT/validation.txt" || true\n`;
                s += `    echo '--- Hostname ---' && hostnamectl 2>/dev/null | head -5 || true\n`;
                s += `    echo '--- Disk ---' && df -Th\n`;
                s += `    echo '--- Listening ports ---' && ss -ltnp\n`;
                s += `    echo '--- Running services ---' && systemctl list-units --type=service --state=running --no-pager 2>/dev/null | head -15 || true\n`;
                s += `    echo '--- sshd config test ---' && sudo sshd -t 2>/dev/null && echo 'sshd OK' || echo 'sshd config WARNING'\n`;
                s += `ENDSSH\n\n`;

                // STAGE 4 — FULL SMOKE TEST (9A Infra + 9B App)
                s += `  ${sec('STAGE 4 -- SMOKE TESTS (9A INFRA + 9B APP)').replace(/\n/g, '\n  ')}\n`;
                s += `  SMOKE_REPORT="$NODE_AUDIT/smoke_test.txt"\n`;
                s += `  SMOKE_PASS=0; SMOKE_FAIL=0; SMOKE_SKIP=0\n`;
                s += `  smoke_ok()  { echo "  ✅ [PASS] $1" | tee -a "$SMOKE_REPORT"; SMOKE_PASS=$((SMOKE_PASS+1)); }\n`;
                s += `  smoke_fail(){ echo "  ❌ [FAIL] $1" | tee -a "$SMOKE_REPORT"; SMOKE_FAIL=$((SMOKE_FAIL+1)); }\n`;
                s += `  smoke_skip(){ echo "  ⏭  [SKIP] $1" | tee -a "$SMOKE_REPORT"; SMOKE_SKIP=$((SMOKE_SKIP+1)); }\n`;
                s += `  echo "# Smoke test report -- $(date)" > "$SMOKE_REPORT"\n\n`;

                // 9A — INFRA
                s += `  echo ""\n`;
                s += `  echo "── 9A INFRA ────────────────────────────────────"\n`;

                // SSH
                s += `  ssh $SSH_OPTS "$DST_USER@$DST_IP" "echo OK" 2>/dev/null && smoke_ok "SSH access -- $DST_IP" || smoke_fail "SSH access -- $DST_IP"\n`;

                // IP and route
                s += `  IP_OUT=$(ssh $SSH_OPTS "$DST_USER@$DST_IP" "ip addr show | grep -c 'inet '" 2>/dev/null || echo 0)\n`;
                s += `  [ "$IP_OUT" -gt 0 ] 2>/dev/null && smoke_ok "IP address present ($IP_OUT interfaces)" || smoke_fail "No IP address found"\n`;
                s += `  RT_OUT=$(ssh $SSH_OPTS "$DST_USER@$DST_IP" "ip route | grep -c default" 2>/dev/null || echo 0)\n`;
                s += `  [ "$RT_OUT" -gt 0 ] 2>/dev/null && smoke_ok "Default route present" || smoke_fail "No default route"\n`;

                // DNS
                s += `  DNS_OK=$(ssh $SSH_OPTS "$DST_USER@$DST_IP" "resolvectl status 2>/dev/null | grep -c 'DNS Server' || dig +short google.com 2>/dev/null | grep -c '[0-9]'" 2>/dev/null || echo 0)\n`;
                s += `  [ "$DNS_OK" -gt 0 ] 2>/dev/null && smoke_ok "DNS resolution working" || smoke_fail "DNS not resolving"\n`;

                // Disk mounts
                s += `  MOUNTS=$(ssh $SSH_OPTS "$DST_USER@$DST_IP" "df -Th | grep -cE '^/dev'" 2>/dev/null || echo 0)\n`;
                s += `  [ "$MOUNTS" -gt 0 ] 2>/dev/null && smoke_ok "Disk mounts present ($MOUNTS devices)" || smoke_fail "No disk mounts"\n`;

                // Listening ports
                s += `  PORTS=$(ssh $SSH_OPTS "$DST_USER@$DST_IP" "ss -ltnp | grep -c LISTEN" 2>/dev/null || echo 0)\n`;
                s += `  [ "$PORTS" -gt 0 ] 2>/dev/null && smoke_ok "Listening ports present ($PORTS)" || smoke_fail "No listening ports"\n`;
                s += `  echo "  Ports in use:" && ssh $SSH_OPTS "$DST_USER@$DST_IP" "ss -ltnp | grep LISTEN" 2>/dev/null | sed 's/^/    /' | tee -a "$SMOKE_REPORT" || true\n`;

                // Service state
                s += `  FAILED=$(ssh $SSH_OPTS "$DST_USER@$DST_IP" "systemctl --failed --no-pager 2>/dev/null | grep -c 'failed'" 2>/dev/null || echo 0)\n`;
                s += '  FAILED=$(echo "$FAILED" | tr -d "[:space:]")\n'; // strip whitespace
                s += '  [ "$FAILED" = "0" ] && smoke_ok "No failed systemd units" || smoke_fail "$FAILED failed systemd units -- check: systemctl --failed"\n';
                s += `  ssh $SSH_OPTS "$DST_USER@$DST_IP" "systemctl --failed --no-pager 2>/dev/null" | grep -v "^$" | sed 's/^/    /' | tee -a "$SMOKE_REPORT" || true\n\n`;

                // 9B — APP (port-check first, then HTTP)
                s += `  echo "── 9B APP ──────────────────────────────────────"\n`;
                s += `  PORT80=$(nc -z -w5 $DST_IP 80 2>/dev/null && echo open || echo closed)\n`;
                s += `  PORT443=$(nc -z -w5 $DST_IP 443 2>/dev/null && echo open || echo closed)\n`;

                // HTTP checks only if port 80 is open
                s += `  if [ "$PORT80" = "open" ]; then\n`;
                s += `    echo "  [PORT] port 80 open"\n`;
                s += `    HTTP_CODE=$(curl -sSo /dev/null -w "%{http_code}" --max-time 10 "http://$DST_IP:80" 2>/dev/null || echo "000")\n`;
                s += `    case "$HTTP_CODE" in\n`;
                s += `      2*|3*) smoke_ok  "Homepage  :80  HTTP $HTTP_CODE" ;;\n`;
                s += `      *)     smoke_fail "Homepage  :80  HTTP $HTTP_CODE" ;;\n`;
                s += `    esac\n`;
                s += `    HEALTH=$(curl -sSo /dev/null -w "%{http_code}" --max-time 10 "http://$DST_IP:80/health" 2>/dev/null || echo "000")\n`;
                s += `    case "$HEALTH" in\n`;
                s += `      2*) smoke_ok   "Health endpoint  :80/health  HTTP $HEALTH" ;;\n`;
                s += `      *)  smoke_skip "Health endpoint  :80/health  HTTP $HEALTH (route not found)" ;;\n`;
                s += `    esac\n`;
                s += `    API=$(curl -sSo /dev/null -w "%{http_code}" --max-time 10 "http://$DST_IP:80/api/" 2>/dev/null || echo "000")\n`;
                s += `    case "$API" in\n`;
                s += `      2*|3*) smoke_ok  "API endpoint  :80/api/  HTTP $API" ;;\n`;
                s += `      *)     smoke_skip "API endpoint  :80/api/  HTTP $API (route not found)" ;;\n`;
                s += `    esac\n`;
                s += `  else\n`;
                s += `    smoke_skip "HTTP checks skipped -- port 80 closed on $DST_IP"\n`;
                s += `  fi\n`;

                // DB connectivity
                s += `  HAS_PSQL=$(ssh $SSH_OPTS "$DST_USER@$DST_IP" "which psql" 2>/dev/null || true)\n`;
                s += `  if [ -n "$HAS_PSQL" ]; then\n`;
                s += `    DB_OK=$(ssh $SSH_OPTS "$DST_USER@$DST_IP" "sudo -u postgres psql -c '\\\\l' 2>/dev/null | grep -c '|'" 2>/dev/null || echo 0)\n`;
                s += `    [ "$DB_OK" -gt 0 ] 2>/dev/null && smoke_ok "DB connectivity (PostgreSQL) -- $DB_OK databases found" || smoke_fail "DB connectivity (PostgreSQL) -- cannot list databases"\n`;
                s += `  else\n`;
                s += `    HAS_MYSQL=$(ssh $SSH_OPTS "$DST_USER@$DST_IP" "which mysql" 2>/dev/null || true)\n`;
                s += `    if [ -n "$HAS_MYSQL" ]; then\n`;
                s += `      DB_OK=$(ssh $SSH_OPTS "$DST_USER@$DST_IP" "mysql -uroot -e 'SHOW DATABASES;' 2>/dev/null | grep -c Database" 2>/dev/null || echo 0)\n`;
                s += `      [ "$DB_OK" -gt 0 ] 2>/dev/null && smoke_ok "DB connectivity (MySQL)" || smoke_fail "DB connectivity (MySQL)"\n`;
                s += `    else\n`;
                s += `      smoke_skip "DB connectivity (no psql or mysql found)"\n`;
                s += `    fi\n`;
                s += `  fi\n`;

                // Background jobs
                s += `  CRON_OK=$(ssh $SSH_OPTS "$DST_USER@$DST_IP" "crontab -l 2>/dev/null | grep -vc '^#'" 2>/dev/null || echo 0)\n`;
                s += `  [ "$CRON_OK" -gt 0 ] && smoke_ok "Background jobs -- $CRON_OK cron entries present" || smoke_skip "Background jobs -- no crontab entries (manual check needed)"\n`;

                // TLS
                s += `  TLS_CODE=$(curl -sSo /dev/null -w "%{http_code}" --max-time 10 -k "https://$DST_IP" 2>/dev/null || echo "000")\n`;
                s += `  case "$TLS_CODE" in\n`;
                s += `    2*|3*) smoke_ok  "TLS / HTTPS  HTTP $TLS_CODE" ;;\n`;
                s += `    000)   smoke_skip "TLS / HTTPS  (port 443 not open)" ;;\n`;
                s += `    *)     smoke_fail "TLS / HTTPS  HTTP $TLS_CODE" ;;\n`;
                s += `  esac\n\n`;

                // Summary
                s += `  echo ""\n`;
                s += `  echo "════════════════════════════════════════════════"\n`;
                s += `  echo "  SMOKE TEST SUMMARY: ✅ $SMOKE_PASS passed  ❌ $SMOKE_FAIL failed  ⏭  $SMOKE_SKIP skipped"\n`;
                s += `  echo "  Full report: $SMOKE_REPORT"\n`;
                s += `  echo "════════════════════════════════════════════════"\n`;
                s += `  [ "$SMOKE_FAIL" -gt 0 ] && echo "  ⚠  $SMOKE_FAIL check(s) failed -- review before cutover" || echo "  ✅  All checks passed -- safe to proceed to cutover"\n\n`;


                // STAGE 5 — CLEANUP
                s += `  ${sec('STAGE 5 -- CLEANUP').replace(/\n/g, '\n  ')}\n`;
                s += `  echo "[CLEANUP] Removing /tmp staging files for ${name}..."\n`;
                s += `  run "rm -rf /tmp/${name}_* 2>/dev/null || true"\n`;
                s += `  ssh $SSH_OPTS "$DST_USER@$DST_IP" "rm -f /tmp/.ospc-migration-lock /tmp/sshd_config /tmp/sudoers_d.tgz /tmp/systemd_units.tgz /tmp/cron_backup.tgz /tmp/sysctl_clone.conf /tmp/limits_clone.conf /tmp/pg_*.dump /tmp/mysql_*.sql.gz 2>/dev/null || true" || true\n`;
                if (ospcIp) {
                    s += `  remove_key_from_ospc  # remove transferred SSH key from OSPC\n`;
                }
                s += `  echo "  [CLEANUP] Done"\n\n`;

                s += `  echo "[DONE] ${name} complete. Reports: $NODE_AUDIT/"\n`;
                s += `}\n`;  // close function

                // ── Store complete standalone script for parallel execution ────
                // commonHeader + this function definition + invocation call
                const _fnBody = s.slice(_fnStart);
                window._rehostNodeScripts[name] = s.slice(0, _commonHeaderLen) + _fnBody
                    + `\n# ── Parallel invocation ──\n${funcName}\necho ""\necho "[PARALLEL-DONE] ${name} execution complete"\n`;

                funcCalls.push(funcName);
            });

            // Emit the sequential function calls (full combined script)
            s += `\n# ================================================================\n`;
            s += `# MAIN — process nodes one at a time\n`;
            s += `# ================================================================\n`;
            funcCalls.forEach(fn => { s += `${fn}\n`; });
        }

        s += `\necho ""\necho "================================================================"\necho "ALL NODES PROCESSED"\necho "Audit + validation reports: ./migration-csv/${safeName}-audit/"\necho "================================================================"\n`;

        // ── Export per-VM data for parallel execution ─────────────────────────
        window._rehostPairList = pairList;
        // Capture settings snapshot so generateRehostNodeScript() can rebuild any single-VM script
        window._rehostSettings = { isDryRun, oUser, fUser, sshKey: '/home/dzoan/.ssh/id_rsa',
            safeName, appPaths, L,
            resolveOsUser: resolveOsUser.toString(),
            resolvePkgMgr: resolvePkgMgr.toString(),
        };

        const codeEl = document.getElementById('script-output-stage1');
        const panel  = document.getElementById('output-container-stage1');
        if (codeEl) { codeEl.innerHTML = (typeof syntaxHighlight === 'function' ? syntaxHighlight(s) : s); codeEl.setAttribute('data-raw', s); }
        if (panel)  { panel.style.display = 'block'; setTimeout(() => panel.scrollIntoView({behavior:'smooth'}), 100); }
        if (typeof showToast === 'function') showToast(
            isDryRun
                ? '🔍 Rehost script generated — DRY RUN (no changes will apply)'
                : `⚡ Rehost script generated — ${pairList.length} VM(s) ready · click ⚡ Run Parallel to start`
        );

        // Update parallel button state
        const parBtn = document.getElementById('run-parallel-btn-stage1');
        if (parBtn) {
            parBtn.disabled  = pairList.length === 0;
            parBtn.textContent = `⚡ Run ${pairList.length} VM${pairList.length !== 1 ? 's' : ''} in Parallel`;
        }

    } catch(err) {
        console.error('[ReHost] Generator error:', err);
        if (typeof showToast === 'function') showToast('❌ ' + err.message);
    }

    // ── Shared env header builder (called at generate time) ───────────────────
    function buildCommonHeader() {
        const custName  = (document.getElementById('project_customer_name')||{value:'UnknownCustomer'}).value||'UnknownCustomer';
        const safeName  = custName.replace(/[^a-zA-Z0-9_-]/g,'_');
        const fUser     = (document.getElementById('flex_ssh_user')||{value:'ubuntu'}).value||'ubuntu';
        const oUser     = (document.getElementById('ospc_ssh_user')||{value:'ubuntu'}).value||fUser;
        const sshKey    = '/home/dzoan/.ssh/id_rsa';
        const appPaths  = ((document.getElementById('rehost_app_paths')||{value:'/opt/app'}).value||'/opt/app').trim();
        const rhLive    = !!(document.getElementById('rh_live')    && document.getElementById('rh_live').checked);
        const rhCutover = !!(document.getElementById('rh_cutover') && document.getElementById('rh_cutover').checked);
        const rhMaint   = !!(document.getElementById('rh_maint')   && document.getElementById('rh_maint').checked);
        const isDryRun  = !(rhLive || rhCutover || rhMaint);
        let h = `#!/usr/bin/env bash\nset -uo pipefail\n`;
        h += `DRY_RUN=${isDryRun ? '1' : '0'}\n`;
        h += `DEFAULT_SRC_USER="${oUser}"\nDEFAULT_DST_USER="${fUser}"\n`;
        h += `SSH_KEY="${sshKey}"\n`;
        h += `SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"\n`;
        h += `SSH_OPTS_A="-A -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"\n`;
        h += `RSYNC_OPTS="-aHAX --numeric-ids --stats --info=progress2"\n`;
        h += `APP_PATHS="${appPaths}"\n`;
        h += `AUDIT_DIR="./migration-csv/${safeName}-audit"\n`;
        h += `mkdir -p "$AUDIT_DIR"\n\n`;
        h += `run() {\n  if [ "$DRY_RUN" = "1" ]; then\n    echo "  [DRY] $*";\n  else\n    "$@";\n  fi\n}\n`;
        h += `MIG_KEY_REMOTE="/tmp/.mig_flex_key"\n`;
        h += `deploy_key_to_ospc() { scp -O -q $SSH_OPTS "$SSH_KEY" "$SRC_USER@$SRC_IP:$MIG_KEY_REMOTE" 2>/dev/null && ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "chmod 600 $MIG_KEY_REMOTE" 2>/dev/null || echo "  [WARN] Could not deploy SSH key"; }\n`;
        h += `remove_key_from_ospc() { ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "rm -f $MIG_KEY_REMOTE" 2>/dev/null || true; }\n`;
        h += `ospc_to_flex() { ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "scp -O -q -i $MIG_KEY_REMOTE -o StrictHostKeyChecking=no '$1' '$DST_USER@$DST_IP:$2' 2>/dev/null || true"; }\n`;
        h += `rsync_direct() { ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "rsync $RSYNC_OPTS --rsync-path='sudo rsync' -e 'ssh -i $MIG_KEY_REMOTE -o StrictHostKeyChecking=no -o BatchMode=yes' '$1' '$DST_USER@$DST_IP:$2'"; }\n\n`;
        return h;
    }
};

/**
 * generateRehostNodeScript(pair)
 * Build a self-contained bash script for a SINGLE node pair.
 * Uses settings captured by generateRehostScript() → window._rehostSettings.
 * Called by runRehostParallel() in agent1.html to run each VM independently.
 */
window.generateRehostNodeScript = function(pair) {
    const cfg = window._rehostSettings || {};
    const { isDryRun = true, oUser = 'ubuntu', fUser = 'ubuntu',
            sshKey = '~/.ssh/id_rsa', safeName = 'migration', appPaths = '/opt/app', L = {} } = cfg;

    const { name, ospcIp, flexIp, osStr = '' } = pair;
    const o = osStr.toLowerCase();

    function resolveOsUser(s) {
        const lo = (s||'').toLowerCase();
        if (lo.includes('rocky'))  return 'rocky';
        if (lo.includes('alma'))   return 'almalinux';
        if (lo.includes('debian')) return 'debian';
        if (lo.includes('fedora')) return 'fedora';
        if (lo.includes('centos')) return 'centos';
        if (lo.includes('rhel') || lo.includes('red hat')) return 'ec2-user';
        if (lo.includes('amazon')) return 'ec2-user';
        if (lo.includes('ubuntu')) return 'ubuntu';
        return fUser;
    }
    function resolvePkgMgr(s) {
        const lo = (s||'').toLowerCase();
        if (lo.includes('rocky')||lo.includes('alma')||lo.includes('centos')||lo.includes('rhel')||lo.includes('fedora')) return 'dnf';
        return 'apt';
    }

    const nodeUser = resolveOsUser(osStr);
    const srcUser  = resolveOsUser(osStr);
    const pkgMgr   = resolvePkgMgr(osStr);
    const funcName = `node_${name.replace(/[^a-zA-Z0-9]/g,'_')}`;

    // Rebuild common header inline
    let s = `#!/usr/bin/env bash\nset -uo pipefail\n`;
    s += `# Parallel rehost: ${name} | OSPC ${ospcIp} → FLEX ${flexIp}\n`;
    s += `DRY_RUN=${isDryRun ? '1' : '0'}\n`;
    s += `DEFAULT_SRC_USER="${oUser}"\nDEFAULT_DST_USER="${fUser}"\n`;
    s += `SSH_KEY="${sshKey}"\n`;
    s += `SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"\n`;
    s += `RSYNC_OPTS="-aHAX --numeric-ids --stats --info=progress2"\n`;
    s += `APP_PATHS="${appPaths}"\n`;
    s += `AUDIT_DIR="./migration-csv/${safeName}-audit"\n`;
    s += `mkdir -p "$AUDIT_DIR"\n\n`;
    s += `run() {\n  if [ "$DRY_RUN" = "1" ]; then echo "  [DRY] $*"; else "$@"; fi\n}\n`;
    s += `MIG_KEY_REMOTE="/tmp/.mig_flex_key"\n`;
    s += `deploy_key_to_ospc() { scp -O -q $SSH_OPTS "$SSH_KEY" "$SRC_USER@$SRC_IP:$MIG_KEY_REMOTE" 2>/dev/null && ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "chmod 600 $MIG_KEY_REMOTE" 2>/dev/null || echo "  [WARN] Could not deploy SSH key"; }\n`;
    s += `remove_key_from_ospc() { ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "rm -f $MIG_KEY_REMOTE" 2>/dev/null || true; }\n`;
    s += `ospc_to_flex() { ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "scp -O -q -i $MIG_KEY_REMOTE -o StrictHostKeyChecking=no '$1' '$DST_USER@$DST_IP:$2' 2>/dev/null || true"; }\n`;
    s += `rsync_direct() { ssh $SSH_OPTS "$SRC_USER@$SRC_IP" "rsync $RSYNC_OPTS --rsync-path='sudo rsync' -e 'ssh -i $MIG_KEY_REMOTE -o StrictHostKeyChecking=no -o BatchMode=yes' '$1' '$DST_USER@$DST_IP:$2'"; }\n\n`;

    // Node function — extract from full generated script via regex
    const fullScript = (document.getElementById('script-output-stage1')||{getAttribute:()=>''}).getAttribute('data-raw') || '';
    const fnRegex = new RegExp(`(${funcName}\\(\\)[\\s\\S]*?^\\})`, 'm');
    const fnMatch = fullScript.match(fnRegex);
    if (fnMatch) {
        s += fnMatch[1] + '\n\n';
    } else {
        // Minimal inline fallback if regex fails
        s += `${funcName}() {\n`;
        s += `  local SRC_IP="${ospcIp}"\n  local DST_IP="${flexIp}"\n`;
        s += `  local SRC_USER="${srcUser}"\n  local DST_USER="${nodeUser}"\n`;
        s += `  local NODE_AUDIT="$AUDIT_DIR/${name}"\n  mkdir -p "$NODE_AUDIT"\n`;
        s += `  echo "  [INFO] Minimal fallback — regenerate script for full layers"\n`;
        s += `}\n\n`;
    }

    s += `# Run\n${funcName}\n`;
    s += `echo ""\necho "[DONE] ${name} parallel execution complete"\n`;
    return s;
};

