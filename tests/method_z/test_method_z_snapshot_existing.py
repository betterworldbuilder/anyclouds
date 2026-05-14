from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ospc2Flex-Image-migtool" / "ospc2flex_windows_method_z_snapshot_existing.sh"
APP = ROOT / "workflow_dashboard" / "app.py"
TEMPLATE = ROOT / "workflow_dashboard" / "templates" / "image_migrator.html"
PUSH = ROOT / "push_scripts_to_jumphost.sh"


def _txt(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def test_method_z_files_and_dashboard_key_present():
    assert SCRIPT.exists()
    assert "windows_method_z_snapshot_existing" in _txt(APP)
    assert "windows_method_z_snapshot_existing" in _txt(TEMPLATE)
    assert 'id="start-snapwin-migration-btn"' in _txt(TEMPLATE)
    assert 'data-windows-repair-method="windows_method_z_snapshot_existing"' in _txt(TEMPLATE)
    assert "SNAPWIN" in _txt(TEMPLATE)
    assert "ospc2flex_windows_method_z_snapshot_existing.sh" in _txt(PUSH)


def test_method_z_starts_from_existing_snapshot_only():
    txt = _txt(SCRIPT)
    assert "--ospc-snapshot-id" in txt
    assert "--ospc-image-id" in txt
    assert "--local-artifact" in txt
    assert "--download-only" in txt
    assert "METHOD_SNAPWIN_DOWNLOAD_READY" in txt
    assert "openstack image save" in txt
    assert "download_cloud_files_export_task" in txt
    assert "Glance export task -> Cloud Files -> jumphost" in txt
    assert "receiving_swift_container" in txt
    assert "ospc2flex-export" in txt
    assert "OSPC_SNAPSHOT_EXPORT_BLOCKED_LICENSED_CINDER_ONLY" in txt
    assert "com.rackspace__1__options=4" in txt
    assert "ZS3B_CINDER_VOLUME_EXPORT" in txt
    assert "rackspace_create_volume_from_image" in txt
    assert "rackspace_attach_volume" in txt
    assert "CINDER_MIN_VOLUME_SIZE_GB" in txt
    assert "os-volume_attachments" in txt
    assert "sudo dd if=" in txt
    assert "openstack server image create" in txt
    assert "server create" in txt
    assert "DUMMY_VOLUME_SIZE_GB" in txt
    assert 'DUMMY_VOLUME_SIZE_GB="${OSPC2FLEX_DUMMY_VOLUME_SIZE_GB:-10}"' in txt
    assert 'openstack volume create --size "$DUMMY_VOLUME_SIZE_GB"' in txt
    forbidden = [
        "openstack server image create --name source",
        "openstack server backup create",
        "virt-install ",
        "virsh ",
    ]
    for token in forbidden:
        assert token not in txt
    assert "ospc2flex_windows_repair.sh" not in txt
    assert "ospc2flex_windows_method_g_simple_lib.sh" not in txt
    assert 'source "${SELF_DIR}' not in txt
    assert "source_openrc_if_present" in txt
    assert "download-only mode: deferred offline-repair dependency checks" in txt
    assert "BASE_CMDS=(qemu-img openstack jq curl rsync python3)" in txt
    assert "REPAIR_CMDS=(guestmount guestunmount qemu-nbd hivexsh reged chntpw ntfs-3g ntfsfix 7z)" in txt
    assert "image_is_licensed_cinder_only()" in txt
    assert "Prioritizing Cinder volume attach/raw-copy fallback before Glance export attempts" in txt
    assert "ospc_image_exists()" in txt
    assert 'curl -sS -o /dev/null -w \'%{http_code}\'' in txt
    assert "REPAIR_CMDS=(guestmount guestunmount qemu-nbd hivexsh reged chntpw ntfs-3g ntfsfix 7z)" in txt
    assert "install_missing_prereqs" in txt
    assert "python3-openstackclient" in txt
    assert "libguestfs-tools" in txt
    assert "ensure_virtio_iso" in txt
    assert "qemu-img convert -f raw" in txt
    assert "ensure_libguestfs_kernel_readable" in txt
    assert "chmod a+r" in txt
    assert "OSPC2FLEX_LOCAL_ARTIFACT_IN_PLACE" in txt
    assert "OSPC2FLEX_SNAPWIN_AUTO_RESUME" in txt
    assert "find_resume_artifact()" in txt
    assert "HIT auto-resume artifact found on jumphost" in txt
    assert "Reusing previously repaired qcow2 in place" in txt
    assert "unset OS_TOKEN OS_AUTH_TOKEN OS_SERVICE_TOKEN OS_AUTH_TYPE" in txt
    assert "cleanup_guest_mountpoint" in txt
    assert "prepare_guest_mountpoint" in txt
    assert "preclean_ntfs_for_rw_mount" in txt
    assert "ntfsfix -d" in txt
    assert "cleanup_stale_guestfs_for_qcow2" in txt
    assert 'done < <(pgrep -f "$QCOW2" 2>/dev/null || true)' in txt
    assert "detect_windows_ntfs_partition" in txt
    assert "rw,remove_hiberfile" in txt
    assert "mount_windows_ntfs_nbd_rw" in txt
    assert "ntfs-3g -o rw,remove_hiberfile,big_writes" in txt
    assert "upload_flex_rescue_image_method_ab" in txt
    assert "Method A/B Glance upload path" in txt
    assert "image create \"$RESCUE_IMAGE_NAME\"" in txt
    assert "find_existing_rescue_image()" in txt
    assert "Reusing existing active rescue image" in txt
    assert "HIT rescue image ready" in txt
    assert "find_existing_rescue_server()" in txt
    assert "Reusing existing ACTIVE rescue VM" in txt
    assert "effective_keypair()" in txt
    assert "openstack keypair show" in txt
    assert "booting without keypair" in txt
    assert "--private" in txt
    assert "rackspace_identity_v2_auth" in txt
    assert "RAX-KSKEY:apiKeyCredentials" in txt
    assert "\"tenantId\"" in txt
    assert "X-Auth-Project-Id" in txt
    assert "Rackspace Identity v2 auth succeeded" in txt


def test_method_z_result_schema_and_checkpoints():
    txt = _txt(SCRIPT)
    assert '"method": "SNAPWIN_STANDALONE"' in txt
    assert '"method_key": "windows_method_z_snapshot_existing"' in txt
    for key in [
        "preflight",
        "snapshot_selected",
        "snapshot_downloaded",
        "cinder_volume_export",
        "qcow2_normalized",
        "offline_repair",
        "flex_upload",
        "rescue_boot",
        "dummy_attach",
        "driver_bind",
        "final_snapshot",
        "final_boot",
        "validation",
    ]:
        assert f'"{key}": "PENDING"' in txt
    assert "WAITING_FOR_SNAPSHOT_SELECTION" in txt
    assert "WAITING_FOR_DRIVER_BIND" in txt
    assert "METHOD_SNAPWIN_SUCCESS" in txt


def test_method_z_offline_repair_uses_sectioned_reg_imports():
    txt = _txt(SCRIPT)
    assert "[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Services\\xenbus]" in txt
    assert "[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Control\\CriticalDeviceDatabase\\pci#ven_1af4&dev_1001]" in txt
    assert "[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\RunOnce]" in txt
    assert '"ControlSet001\\Services\\xenbus\\Start"=dword:00000004' not in txt


def test_cold_scan_dispatch_passes_snapshot_id_to_method_z():
    txt = _txt(TEMPLATE)
    assert "start-snapwin-migration-btn" in txt
    assert "snapshot_id:   iid" in txt
    assert "ospc_image_id: iid" in txt
    assert "imageWindowsMethod" in txt
    assert "windows_repair_method: imageWindowsMethod" in txt


def test_snapwin_not_in_live_windows_dropdown():
    txt = _txt(TEMPLATE)
    assert '<option value="windows_method_z_snapshot_existing">' not in txt


def test_app_branches_image_migrator_run_to_method_z():
    txt = _txt(APP)
    assert "_windows_method == 'windows_method_z_snapshot_existing'" in txt
    assert "ospc2flex_windows_method_z_snapshot_existing.sh" in txt
    assert "--ospc-image-id" in txt
    assert "--download-only" in txt
    assert "manual_driver_bind" in txt
    assert "Method SNAPWIN is a standalone cold snapshot method" in txt
    assert "Refusing live VM/NBD launch" in txt
    assert "build_flex_method_ab_openrc" in txt
    assert "OS_IDENTITY_API_VERSION=3" in txt
    assert "OS_AUTH_TYPE=password" in txt
    assert "OS_PROJECT_DOMAIN_NAME" in txt




def test_method_z_tcp_preflight_and_auth_tuning_present():
    txt = _txt(APP)
    assert "Checking jumphost TCP/22 reachability before SSH staging." in txt
    assert "def _tcp_probe_host_port" in txt
    assert '"-o", "IdentitiesOnly=yes"' in txt
    assert '"-o", "PreferredAuthentications=publickey"' in txt
    assert '"-o", "IPQoS=none"' in txt

def test_method_z_bash_syntax_checked():
    r = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_workflow_dashboard_app_py_compile():
    r = subprocess.run([sys.executable, "-m", "py_compile", str(APP)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
