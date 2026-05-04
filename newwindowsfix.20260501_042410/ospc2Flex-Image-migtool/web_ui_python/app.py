import asyncio
import os
import sys
import shlex
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

app = FastAPI(title="OSPC2FLEX Image Migrator UI")

# Setup relative directory paths
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(BASE_DIR, "static")
TEMPLATES_DIR = os.path.join(BASE_DIR, "templates")

# Ensure directories exist
os.makedirs(STATIC_DIR, exist_ok=True)
os.makedirs(TEMPLATES_DIR, exist_ok=True)

app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

# The migration script is one level up from the web_ui directory
SCRIPT_PATH = os.path.abspath(os.path.join(BASE_DIR, "..", "ospc2flex_image_migrator.py"))

class MigrationRequest(BaseModel):
    # Core
    ospc_openrc: str = ""
    flex_openrc: str = ""
    server_name: str = ""
    snapshot_name: str = ""
    workdir: str = ""
    target_format: str = "qcow2"
    source_format: str = ""
    flex_image_name: str = ""
    visibility: str = "private"
    container_format: str = "bare"
    keep_export: bool = False
    cleanup_snapshot: bool = False
    dry_run: bool = False

    # VM Boot Test
    boot_test_vm: bool = False
    test_server_name: str = ""
    flex_flavor: str = ""
    flex_network_id: str = ""
    flex_key_name: str = ""
    flex_security_group: str = "default"
    floating_ip: str = ""
    test_server_ip: str = ""

    # Guest Repair
    repair_guest: bool = False
    ssh_user: str = "ubuntu"
    ssh_key_path: str = ""
    ssh_port: int = 22
    jump_host: str = ""
    new_hostname: str = ""
    fix_fstab: bool = False
    fix_netplan: bool = False
    flex_net_iface: str = ""
    no_dhcp: bool = False
    skip_cloud_init_clean: bool = False
    skip_qemu_guest_agent: bool = False
    clean_hosts_file: bool = False
    app_endpoint_map_file: str = ""
    systemd_services: str = ""

@app.get("/", response_class=HTMLResponse)
async def index():
    with open(os.path.join(TEMPLATES_DIR, "index.html"), "r", encoding="utf-8") as f:
        return f.read()

async def run_migration_stream(req: MigrationRequest):
    cmd = [sys.executable, SCRIPT_PATH]
    
    # Core Image Commands
    if req.ospc_openrc: cmd.extend(["--ospc-openrc", req.ospc_openrc])
    if req.flex_openrc: cmd.extend(["--flex-openrc", req.flex_openrc])
    if req.server_name: cmd.extend(["--server-name", req.server_name])
    if req.snapshot_name: cmd.extend(["--snapshot-name", req.snapshot_name])
    if req.workdir: cmd.extend(["--workdir", req.workdir])
    if req.target_format: cmd.extend(["--target-format", req.target_format])
    if req.source_format: cmd.extend(["--source-format", req.source_format])
    if req.flex_image_name: cmd.extend(["--flex-image-name", req.flex_image_name])
    if req.visibility: cmd.extend(["--visibility", req.visibility])
    if req.container_format: cmd.extend(["--container-format", req.container_format])
    if req.keep_export: cmd.append("--keep-export")
    if req.cleanup_snapshot: cmd.append("--cleanup-snapshot")
    if req.dry_run: cmd.append("--dry-run")

    # Test VM Commands
    if req.boot_test_vm:
        cmd.append("--boot-test-vm")
        if req.test_server_name: cmd.extend(["--test-server-name", req.test_server_name])
        if req.flex_flavor: cmd.extend(["--flex-flavor", req.flex_flavor])
        if req.flex_network_id: cmd.extend(["--flex-network-id", req.flex_network_id])
        if req.flex_key_name: cmd.extend(["--flex-key-name", req.flex_key_name])
        if req.flex_security_group: cmd.extend(["--flex-security-group", req.flex_security_group])
        if req.floating_ip: cmd.extend(["--floating-ip", req.floating_ip])
        if req.test_server_ip: cmd.extend(["--test-server-ip", req.test_server_ip])

    # Guest Repair Commands
    if req.repair_guest:
        cmd.append("--repair-guest")
        if req.ssh_key_path: cmd.extend(["--ssh-key-path", req.ssh_key_path])
        if req.ssh_user: cmd.extend(["--ssh-user", req.ssh_user])
        if req.ssh_port != 22: cmd.extend(["--ssh-port", str(req.ssh_port)])
        if req.jump_host: cmd.extend(["--jump-host", req.jump_host])
        if req.new_hostname: cmd.extend(["--new-hostname", req.new_hostname])
        if req.fix_fstab: cmd.append("--fix-fstab")
        if req.fix_netplan: cmd.append("--fix-netplan")
        if req.flex_net_iface: cmd.extend(["--flex-net-iface", req.flex_net_iface])
        if req.no_dhcp: cmd.append("--no-dhcp")
        if req.skip_cloud_init_clean: cmd.append("--skip-cloud-init-clean")
        if req.skip_qemu_guest_agent: cmd.append("--skip-qemu-guest-agent")
        if req.clean_hosts_file: cmd.append("--clean-hosts-file")
        if req.app_endpoint_map_file: cmd.extend(["--app-endpoint-map-file", req.app_endpoint_map_file])
        if req.systemd_services: cmd.extend(["--systemd-services", req.systemd_services])

    # Command Execution String formatting for logging safely
    safe_cmd_str = ' '.join(shlex.quote(c) for c in cmd)
    yield f"data: --- EXECUTING --- \n\n"
    yield f"data: {safe_cmd_str}\n\n"
    yield f"data: \n\n"

    try:
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=os.path.dirname(SCRIPT_PATH)
        )

        if process.stdout:
            while True:
                line = await process.stdout.readline()
                if not line:
                    break
                decoded_line = line.decode('utf-8').rstrip()
                # Yielding the line as Server-Sent Events data
                yield f"data: {decoded_line}\n\n"

        await process.wait()
        yield f"data: \n\n"
        yield f"data: [PROCESS EXITED WITH CODE {process.returncode}]\n\n"
    except Exception as e:
        yield f"data: [SUBPROCESS LAUNCH ERROR: {str(e)}]\n\n"
    finally:
        yield "data: [DONE]\n\n"

@app.post("/api/run")
async def run_migration(request: MigrationRequest):
    return StreamingResponse(run_migration_stream(request), media_type="text/event-stream")
