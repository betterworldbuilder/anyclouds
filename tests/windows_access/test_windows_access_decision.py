from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from workflow_dashboard.windows_access_decision import (
    decide_capture_mode,
    openssh_install_classification,
    powershell_payload_preserves_dollar_tokens,
    redact_password,
    should_skip_winrm_openssh_install,
)


def test_winrm_auth_ok_ssh_open_false_reports_bulk_transfer_required():
    d = decide_capture_mode(ssh_open=False, winrm_auth_ok=True, winrm_agent_capture=False)
    assert d.status == "WINDOWS_BULK_TRANSFER_REQUIRED"
    assert d.failure_reason == "WINRM_AUTH_OK_BUT_SSH_UNAVAILABLE"


def test_winrm_auth_failed_reports_auth_failed():
    d = decide_capture_mode(ssh_open=False, winrm_auth_ok=False, winrm_agent_capture=False)
    assert d.status == "WINDOWS_SOURCE_ACCESS_BLOCKED"
    assert d.failure_reason == "NO_VALID_GUEST_ACCESS"


def test_openssh_install_access_denied_not_bad_password():
    assert openssh_install_classification(winrm_auth_ok=True, access_denied=True) == "WINDOWS_OPENSSH_INSTALL_DENIED"


def test_openssh_enable_success_requires_external_port_22_open():
    d_fail = decide_capture_mode(ssh_open=False, winrm_auth_ok=True, winrm_agent_capture=False)
    d_ok = decide_capture_mode(ssh_open=True, winrm_auth_ok=True, winrm_agent_capture=False)
    assert d_fail.capture_mode == "blocked"
    assert d_ok.capture_mode == "ssh_guest_capture"


def test_powershell_payload_preserves_dollar_tokens():
    payload = r"$ErrorActionPreference='Stop'; if (-not $svc) { $msg = $_.Exception.Message }"
    assert powershell_payload_preserves_dollar_tokens(payload)


def test_password_redacted_from_logs():
    secret = "SdeGqsD9KrGjVJuF6nAAJVok"
    raw = f"login ok for Administrator with {secret}"
    out = redact_password(raw, secret)
    assert secret not in out
    assert "***REDACTED***" in out


def test_ssh_open_skips_winrm_openssh_install():
    assert should_skip_winrm_openssh_install(ssh_open=True) is True


def test_winrm_agent_capture_selected_when_enabled():
    d = decide_capture_mode(ssh_open=False, winrm_auth_ok=True, winrm_agent_capture=True)
    assert d.capture_mode == "winrm_agent_capture"


def test_method_f_approved_export_keeps_running_without_ssh():
    d = decide_capture_mode(
        ssh_open=False,
        winrm_auth_ok=True,
        winrm_agent_capture=False,
        approved_export_available=True,
        guest_capture_allowed=False,
    )
    assert d.status == "WINDOWS_WINRM_CONTROL_READY"
    assert d.capture_mode == "provider_export_artifact"


def test_method_f_blocks_when_export_missing_and_guest_capture_disallowed():
    d = decide_capture_mode(
        ssh_open=False,
        winrm_auth_ok=True,
        winrm_agent_capture=False,
        approved_export_available=False,
        guest_capture_allowed=False,
    )
    assert d.status == "SOURCE_DISK_ACQUISITION_BLOCKED"
    assert d.failure_reason == "NO_APPROVED_DISK_EXPORT_PATH"
