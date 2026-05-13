from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "workflow_dashboard" / "app.py"
V2 = ROOT / "ospc2Flex-Image-migtool" / "ospc2flex_windows_v2_engine.sh"
CAPTURE = ROOT / "ospc2Flex-Image-migtool" / "ospc2flex_windows_method_d_capture.sh"


def _txt(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def test_method_a_defaults_to_method_b_capture_engine():
    txt = _txt(APP)
    assert "_win_entry = '/tmp/ospc2flex_windows_method_d_capture.sh'" in txt
    assert "_workflow_mode = 'method_a_offline'" in txt


def test_method_c_routes_through_v2_to_method_b_capture_engine():
    app = _txt(APP)
    v2 = _txt(V2)
    assert "elif repair_method == 'windows_method_c_dynamic_auto':" in app
    assert "_workflow_mode = 'method_c_dynamic_auto'" in app
    assert 'METHOD_D_CAPTURE="/tmp/ospc2flex_windows_method_d_capture.sh"' in v2
    assert 'exec "$METHOD_D_CAPTURE" "${METHOD_D_CAPTURE_ARGS[@]}"' in v2


def test_shared_method_b_capture_has_ssh_first_path():
    txt = _txt(CAPTURE)
    assert "CAPTURE_LOG_PREFIX" in txt
    assert "CAPTURE_HANDOFF_READY=0" in txt
    assert "Capture phase result: INCOMPLETE" in txt
    assert "CAPTURE_HANDOFF_READY=1" in txt
    assert 'step_start "1b" "Checking Windows SSH availability (public IP + ServiceNet)"' in txt
    assert 'SSH port 22 open on $WIN_SSH_IP' in txt
    assert "CAPTURE_MODE=ssh_guest_capture" in txt
    assert "powershell -NonInteractive -File C:\\Windows\\Temp\\ospc2flex_diskdump.ps1" in txt


def test_shared_method_b_capture_rejects_partial_ssh_streams():
    txt = _txt(CAPTURE)
    assert "SSH_SIZE_MISMATCH=0" in txt
    assert "SSH disk stream size mismatch" in txt
    assert "SSH disk read was partial" in txt


def test_dashboard_running_probe_is_label_scoped():
    txt = _txt(APP)
    assert "pgrep -f '[q]emu-img .*convert'" not in txt
    assert "pgrep -f '[q]emu-img .*info'" not in txt
    assert "pgrep -f '[o]penstack image '" not in txt
    assert "pgrep -f '[q]emu-img.*{label}'" in txt
