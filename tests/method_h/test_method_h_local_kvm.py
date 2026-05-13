from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ospc2Flex-Image-migtool" / "ospc2flex_windows_method_h_local_kvm.sh"
APP = ROOT / "workflow_dashboard" / "app.py"
TEMPLATE = ROOT / "workflow_dashboard" / "templates" / "image_migrator.html"


def _txt(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def test_method_h_script_and_workflow_key_exist():
    assert SCRIPT.exists()
    assert "Method H — Local KVM VirtIO Prep + Flex Import" in _txt(SCRIPT)
    assert "windows_method_h_local_kvm" in _txt(APP)
    assert "windows_method_h_local_kvm" in _txt(TEMPLATE)


def test_method_h_routes_to_correct_script():
    txt = _txt(APP)
    assert "_win_entry = '/tmp/ospc2flex_windows_method_h_local_kvm.sh'" in txt
    assert "method_h_local_kvm" in txt


def test_method_h_is_ssh_only_no_fallbacks():
    txt = _txt(SCRIPT)
    assert "OSPC2FLEX_ALLOW_WINDOWS_GLANCE_FALLBACK=0" in txt
    assert "OSPC2FLEX_ALLOW_PROVIDER_EXPORT_FALLBACK=0" in txt
    assert "OSPC2FLEX_ALLOW_DISK2VHD=0" in txt
    assert "OSPC2FLEX_ALLOW_VSS_CAPTURE=0" in txt
    assert "OSPC2FLEX_ALLOW_SMB_HTTPS_OBJECT_TRANSFER=0" in txt
    assert "OSPC2FLEX_ALLOW_WINRM_AGENT_CAPTURE=0" in txt
    assert "ospc2flex_windows_v2_engine.sh" not in txt
    assert "provider export" not in txt.lower()


def test_method_h_state_schema():
    txt = _txt(SCRIPT)
    assert '"method": "H_LOCAL_KVM"' in txt
    assert ".method_h_local_kvm.json" in txt
    for key in ["capture", "local_kvm_boot", "virtio_drivers_bound", "flex_final_boot"]:
        assert f'"{key}": "PENDING"' in txt
    assert '"firmware_type": "unknown"' in txt


def test_method_h_uses_method_b_d_ssh_capture_pattern():
    txt = _txt(SCRIPT)
    capture_txt = _txt(ROOT / "ospc2Flex-Image-migtool" / "ospc2flex_windows_method_d_capture.sh")
    assert "OSPC2FLEX_METHOD_H_CAPTURE_ONLY=1" in txt
    assert 'OSPC2FLEX_PARENT_METHOD_NAME="Method H Local KVM"' in txt
    assert "ospc2flex_windows_method_d_capture.sh" in txt
    assert "Using Method B SSH disk download engine" in txt
    assert "METHOD_B_SSH_CAPTURE_FAILED" in txt
    assert 'pipe_status=("${PIPESTATUS[@]}")' in txt
    assert "METHOD_H_CAPTURE_ONLY_QCOW" in capture_txt
    assert "uses Method B SSH download only" in capture_txt


def test_method_h_launcher_does_not_kill_all_diskdump_streams():
    txt = _txt(APP)
    assert "pkill -f '[o]spc2flex_diskdump.ps1'" not in txt


def test_method_h_local_kvm_requirements_present():
    txt = _txt(SCRIPT)
    assert "virt-install" in txt
    assert "virsh" in txt
    assert "qemu-system-x86_64" in txt
    assert "qemu-img create -f qcow2 \"$DUMMY_DISK\" 5G" in txt
    assert "qemu-img convert -f raw -O qcow2" not in txt
    assert "--disk \"path=$QCOW,bus=ide,format=qcow2\"" in txt
    assert "--disk \"path=$DUMMY_DISK,bus=virtio,format=qcow2\"" in txt
    assert "--cdrom \"$VIRTIO_ISO\"" in txt


def test_method_h_firmware_rules():
    txt = _txt(SCRIPT)
    assert "detect_firmware_type" in txt
    assert 'if [ "$FIRMWARE_TYPE" = "uefi" ]; then' in txt
    assert "boot_args+=(--boot uefi)" in txt
    assert "--property hw_firmware_type=uefi" in txt


def test_method_h_final_flex_metadata_and_success():
    txt = _txt(SCRIPT)
    assert "--property hw_disk_bus=scsi" in txt
    assert "--property hw_scsi_model=virtio-scsi" in txt
    assert "--property hw_vif_model=virtio" in txt
    assert "--property hw_qemu_guest_agent=yes" in txt
    assert "METHOD_H_SUCCESS" in txt
    assert "console_has_fatal_boot_error" in txt


def test_method_h_bash_syntax_checked():
    r = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_workflow_dashboard_app_py_compile():
    r = subprocess.run([sys.executable, "-m", "py_compile", str(APP)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
