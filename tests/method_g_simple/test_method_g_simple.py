from pathlib import Path
import sys
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

G_SIMPLE = ROOT / "ospc2Flex-Image-migtool" / "ospc2flex_windows_method_g_simple.sh"
METHOD_D_CAPTURE = ROOT / "ospc2Flex-Image-migtool" / "ospc2flex_windows_method_d_capture.sh"
APP = ROOT / "workflow_dashboard" / "app.py"
TEMPLATE = ROOT / "workflow_dashboard" / "templates" / "image_migrator.html"


def _txt(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def test_method_g_simple_uses_new_workflow_key_and_banner():
    script = _txt(G_SIMPLE)
    app = _txt(APP)
    template = _txt(TEMPLATE)
    assert "Method G Simple — SSH Capture + Dummy VirtIO Boot" in script
    assert "windows_method_g_simple_ssh_dummy_virtio" in app
    assert "windows_method_g_simple_ssh_dummy_virtio" in template


def test_method_g_simple_routes_to_correct_script():
    txt = _txt(APP)
    assert "windows_method_g_simple_ssh_dummy_virtio" in txt
    assert "_win_entry = '/tmp/ospc2flex_windows_method_g_simple.sh'" in txt


def test_method_g_simple_never_calls_v2():
    txt = _txt(G_SIMPLE)
    assert "ospc2flex_windows_v2_engine.sh" not in txt
    assert "Using Method B SSH disk download engine" in txt
    assert "ospc2flex_windows_method_d_capture.sh" in txt
    assert 'OSPC2FLEX_PARENT_METHOD_NAME="Method G Simple"' in txt


def test_method_g_simple_never_calls_glance_or_provider_export():
    txt = _txt(G_SIMPLE)
    assert "OSPC2FLEX_ALLOW_WINDOWS_GLANCE_FALLBACK=0" in txt
    assert "OSPC2FLEX_ALLOW_PROVIDER_EXPORT_FALLBACK=0" in txt
    assert "OSPC2FLEX_ALLOW_DISK2VHD=0" in txt
    assert "OSPC2FLEX_ALLOW_VSS_CAPTURE=0" in txt
    assert "OSPC2FLEX_ALLOW_SMB_HTTPS_OBJECT_TRANSFER=0" in txt
    assert "OSPC2FLEX_ALLOW_WINRM_AGENT_CAPTURE=0" in txt
    assert "OSPC2FLEX_DISABLE_RESUME=1" in txt
    assert "OSPC2FLEX_RESUME_MODE=off" in txt


def test_method_g_simple_linear_stages_exactly_defined():
    txt = _txt(G_SIMPLE)
    expected = [
        "G0_PREFLIGHT",
        "G1_SSH_ACCESS_CHECK",
        "G2_SSH_DISK_CAPTURE",
        "G3_ARTIFACT_VALIDATE",
        "G4_QCOW2_CONVERT",
        "G5_WINDOWS_REPAIR",
        "G6_UPLOAD_SAFE_RESCUE_IMAGE",
        "G7_BOOT_SAFE_RESCUE_VM",
        "G8_ATTACH_DUMMY_VIRTIO",
        "G9_ONLINE_VIRTIO_BINDING",
        "G10_REBOOT_STILL_IDE",
        "G11_SNAPSHOT_VIRTIO_READY",
        "G12_BOOT_FINAL_VIRTIO",
        "G13_FINAL_VALIDATE",
        "G14_SUCCESS",
    ]
    starts = re.findall(r'stage_start "([^"]+)"', txt)
    assert starts == expected


def test_method_g_simple_state_schema_is_ssh_only():
    txt = _txt(G_SIMPLE)
    assert '"method": "G_SIMPLE_SSH_ONLY"' in txt
    for key in [
        "ssh_capture",
        "artifact_validated",
        "windows_repaired",
        "safe_rescue_boot",
        "dummy_virtio_attached",
        "online_virtio_bound",
        "final_boot_validated",
    ]:
        assert f'"{key}": "PENDING"' in txt


def test_method_g_simple_fails_fast_if_ssh_closed():
    txt = _txt(G_SIMPLE)
    capture_txt = _txt(METHOD_D_CAPTURE)
    assert "Capture-only mode requires Method B SSH disk download" in capture_txt
    assert "WINDOWS_SSH_BLOCKED" in capture_txt
    assert "OSPC2FLEX_METHOD_B_CAPTURE_ONLY=1" in txt


def test_method_g_simple_requires_admin_elevation():
    capture_txt = _txt(METHOD_D_CAPTURE)
    assert "Administrator" in capture_txt
    assert "WIN_USER=\"Administrator\"" in capture_txt


def test_method_g_simple_classifies_incorrect_function():
    txt = _txt(G_SIMPLE)
    capture_txt = _txt(METHOD_D_CAPTURE)
    assert "OSPC2FLEX_PHYSICAL_DRIVE_OPEN_FAILED" in capture_txt
    assert "WINDOWS_RAW_DISK_READ_FAILED" in txt
    assert 'fail_exit "G2_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" "WINDOWS_RAW_DISK_READ_FAILED"' in txt


def test_method_g_simple_safe_pipe_status_under_set_u():
    txt = _txt(G_SIMPLE)
    assert "trap - ERR" in txt
    assert "set +u" in txt
    assert 'pipe_status=("${PIPESTATUS[@]}")' in txt
    pipeline_idx = txt.index('bash "$METHOD_B_CAPTURE_SCRIPT" "${capture_args[@]}" 2>&1 | tee -a "$BACKGROUND_LOG"')
    pipe_status_idx = txt.index('pipe_status=("${PIPESTATUS[@]}")')
    set_plus_u_idx = txt.index("set +u", pipe_status_idx)
    assert pipeline_idx < pipe_status_idx < set_plus_u_idx
    assert "set -u" in txt
    assert 'capture_rc="${pipe_status[0]:-99}"' in txt
    assert 'tee_rc="${pipe_status[1]:-0}"' in txt


def test_method_g_simple_does_not_mark_capture_hit_until_size_validates():
    txt = _txt(G_SIMPLE)
    assert "METHOD_B_CAPTURE_ONLY_QCOW" in _txt(METHOD_D_CAPTURE)
    assert "Capture phase result: METHOD_B_SSH_CAPTURE_READY" in _txt(METHOD_D_CAPTURE)
    assert 'qemu-img info "$QCOW"' in txt
    assert 'qemu-img check "$QCOW"' in txt
    assert '\\"ssh_capture\\":\\"HIT\\"' in txt
    assert "PhysicalDrive0" not in txt
    assert "ospc2flex_diskdump.ps1" not in txt


def test_method_g_simple_safe_boot_not_hit_before_rescue_active():
    txt = _txt(G_SIMPLE)
    active_idx = txt.index('mgs_wait_for_server_status "$RESCUE_SERVER_ID" "ACTIVE"')
    hit_idx = txt.index('\\"safe_rescue_boot\\":\\"HIT\\"')
    assert active_idx < hit_idx


def test_method_g_simple_preserves_dummy_disk_on_failure():
    txt = _txt(G_SIMPLE)
    assert 'DUMMY_VOLUME_ID=$(openstack volume create --size 1 "$DUMMY_VOLUME_NAME"' in txt
    assert "preserve rescue VM and dummy disk" in txt
    assert "openstack volume delete" not in txt


def test_method_g_simple_success_requires_final_healthcheck():
    txt = _txt(G_SIMPLE)
    health_idx = txt.index("verify_guest_health || fail_exit")
    success_idx = txt.index("METHOD_G_SIMPLE_SUCCESS")
    assert health_idx < success_idx
    assert '\\"final\\":true' in txt


def test_method_g_simple_system_hive_error_before_inaccessible_boot():
    txt = _txt(G_SIMPLE)
    assert txt.index("Windows\\\\system32\\\\config\\\\system|0xc0000225") < txt.index("INACCESSIBLE_BOOT_DEVICE")
    assert "WINDOWS_SYSTEM_HIVE_OR_REGISTRY_STOP" in txt


def test_dashboard_status_reads_new_checkpoints():
    txt = _txt(APP)
    for key in [
        'str(cp.get("ssh_capture"',
        'str(cp.get("artifact_validated"',
        'str(cp.get("windows_repaired"',
        'str(cp.get("safe_rescue_boot"',
        'str(cp.get("dummy_virtio_attached"',
        'str(cp.get("online_virtio_bound"',
        'str(cp.get("final_boot_validated"',
    ]:
        assert key in txt


def test_dashboard_cards_show_new_method_g_checkpoints():
    txt = _txt(TEMPLATE)
    assert "{ key: 'ssh_capture', tab: 'G1-G2', label: 'SSH Capture' }" in txt
    assert "{ key: 'dummy_virtio_attached', tab: 'G8', label: 'Dummy VirtIO' }" in txt
    assert "{ key: 'final_boot_validated', tab: 'G11-G14', label: 'Final Validate' }" in txt


def test_method_g_simple_bash_syntax_checked():
    r = subprocess.run(["bash", "-n", str(G_SIMPLE)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_workflow_dashboard_app_py_compile():
    r = subprocess.run([sys.executable, "-m", "py_compile", str(APP)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
