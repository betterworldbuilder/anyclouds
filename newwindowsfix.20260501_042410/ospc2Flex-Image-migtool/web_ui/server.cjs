const express = require('express');
const { spawn } = require('child_process');
const path = require('path');
const cors = require('cors');

const app = express();
app.use(cors());
app.use(express.json());

const SCRIPT_PATH = path.resolve(__dirname, '../ospc2flex_image_migrator.py');

app.post('/api/run', (req, res) => {
    // Set headers for Server-Sent Events (SSE)
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    
    // We optionally pad with whitespace to bypass some proxies holding initial buffers
    res.write(':' + Array(2048).join(' ') + '\n');
    res.write('retry: 10000\n\n');

    const body = req.body;
    const args = [];

    // Core
    if (body.ospc_openrc) args.push('--ospc-openrc', body.ospc_openrc);
    if (body.flex_openrc) args.push('--flex-openrc', body.flex_openrc);
    if (body.server_name) args.push('--server-name', body.server_name);
    if (body.snapshot_name) args.push('--snapshot-name', body.snapshot_name);
    if (body.workdir) args.push('--workdir', body.workdir);
    if (body.target_format) args.push('--target-format', body.target_format);
    if (body.source_format) args.push('--source-format', body.source_format);
    if (body.flex_image_name) args.push('--flex-image-name', body.flex_image_name);
    if (body.visibility) args.push('--visibility', body.visibility);
    if (body.container_format) args.push('--container-format', body.container_format);
    if (body.keep_export) args.push('--keep-export');
    if (body.cleanup_snapshot) args.push('--cleanup-snapshot');
    if (body.dry_run) args.push('--dry-run');

    // Test VM
    if (body.boot_test_vm) {
        args.push('--boot-test-vm');
        if (body.test_server_name) args.push('--test-server-name', body.test_server_name);
        if (body.flex_flavor) args.push('--flex-flavor', body.flex_flavor);
        if (body.flex_network_id) args.push('--flex-network-id', body.flex_network_id);
        if (body.flex_key_name) args.push('--flex-key-name', body.flex_key_name);
        if (body.flex_security_group) args.push('--flex-security-group', body.flex_security_group);
        if (body.floating_ip) args.push('--floating-ip', body.floating_ip);
        if (body.test_server_ip) args.push('--test-server-ip', body.test_server_ip);
    }

    // Guest Repair
    if (body.repair_guest) {
        args.push('--repair-guest');
        if (body.ssh_key_path) args.push('--ssh-key-path', body.ssh_key_path);
        if (body.ssh_user) args.push('--ssh-user', body.ssh_user);
        if (body.ssh_port && body.ssh_port !== 22) args.push('--ssh-port', String(body.ssh_port));
        if (body.jump_host) args.push('--jump-host', body.jump_host);
        if (body.new_hostname) args.push('--new-hostname', body.new_hostname);
        if (body.fix_fstab) args.push('--fix-fstab');
        if (body.fix_netplan) args.push('--fix-netplan');
        if (body.flex_net_iface) args.push('--flex-net-iface', body.flex_net_iface);
        if (body.no_dhcp) args.push('--no-dhcp');
        if (body.skip_cloud_init_clean) args.push('--skip-cloud-init-clean');
        if (body.skip_qemu_guest_agent) args.push('--skip-qemu-guest-agent');
        if (body.clean_hosts_file) args.push('--clean-hosts-file');
        if (body.app_endpoint_map_file) args.push('--app-endpoint-map-file', body.app_endpoint_map_file);
        if (body.systemd_services) args.push('--systemd-services', body.systemd_services);
    }

    // Log the command
    const safeCmdString = 'python ' + SCRIPT_PATH + ' ' + args.join(' ');
    res.write(`data: --- EXECUTING ---\n\n`);
    res.write(`data: ${safeCmdString}\n\n`);
    res.write(`data: \n\n`);

    const child = spawn('python', [SCRIPT_PATH, ...args], {
        cwd: path.dirname(SCRIPT_PATH),
        env: process.env
    });

    child.stdout.on('data', (data) => {
        const lines = data.toString().split('\n');
        for (const line of lines) {
            // we omit completely empty trailing lines, but otherwise stream
            res.write(`data: ${line}\n\n`);
        }
    });

    child.stderr.on('data', (data) => {
        const lines = data.toString().split('\n');
        for (const line of lines) {
            res.write(`data: ${line}\n\n`);
        }
    });

    child.on('close', (code) => {
        res.write(`data: \n\n`);
        res.write(`data: [PROCESS EXITED WITH CODE ${code}]\n\n`);
        res.write(`data: [DONE]\n\n`);
        res.end();
    });

    child.on('error', (err) => {
        res.write(`data: [SUBPROCESS LAUNCH ERROR: ${err.message}]\n\n`);
        res.write(`data: [DONE]\n\n`);
        res.end();
    });

    // Handle client disconnect gracefully
    req.on('close', () => {
        child.kill();
    });
});

// Optionally serve static build files in production
// app.use(express.static(path.join(__dirname, 'dist')));

const PORT = 8000;
app.listen(PORT, '0.0.0.0', () => {
    console.log(`Backend API running cleanly on http://0.0.0.0:${PORT}`);
});
