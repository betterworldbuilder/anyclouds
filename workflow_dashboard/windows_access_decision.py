from dataclasses import dataclass


@dataclass
class AccessDecision:
    status: str
    capture_mode: str
    failure_reason: str = ""
    next_action: str = ""


def decide_capture_mode(
    ssh_open: bool,
    winrm_auth_ok: bool,
    winrm_agent_capture: bool,
    approved_export_available: bool = False,
    guest_capture_allowed: bool = True,
) -> AccessDecision:
    if ssh_open:
        return AccessDecision(status="WINDOWS_SSH_OPEN", capture_mode="ssh_guest_capture")
    if approved_export_available:
        return AccessDecision(status="WINDOWS_WINRM_CONTROL_READY", capture_mode="provider_export_artifact")
    if not guest_capture_allowed:
        return AccessDecision(
            status="SOURCE_DISK_ACQUISITION_BLOCKED",
            capture_mode="blocked",
            failure_reason="NO_APPROVED_DISK_EXPORT_PATH",
            next_action="Request provider export or manually enable an approved bulk capture path.",
        )
    if winrm_auth_ok and winrm_agent_capture:
        return AccessDecision(status="WINDOWS_SOURCE_ACCESS_READY", capture_mode="winrm_agent_capture")
    if winrm_auth_ok:
        return AccessDecision(
            status="WINDOWS_BULK_TRANSFER_REQUIRED",
            capture_mode="blocked",
            failure_reason="WINRM_AUTH_OK_BUT_SSH_UNAVAILABLE",
            next_action="Use WinRM-agent capture, enable SMB/HTTPS/object upload, or install OpenSSH manually from elevated Windows console/RDP.",
        )
    return AccessDecision(
        status="WINDOWS_SOURCE_ACCESS_BLOCKED",
        capture_mode="blocked",
        failure_reason="NO_VALID_GUEST_ACCESS",
        next_action="Provide valid Windows Administrator credentials, enable WinRM, or enable SSH.",
    )


def openssh_install_classification(winrm_auth_ok: bool, access_denied: bool) -> str:
    if winrm_auth_ok and access_denied:
        return "WINDOWS_OPENSSH_INSTALL_DENIED"
    if winrm_auth_ok:
        return "WINDOWS_OPENSSH_NOT_INSTALLED"
    return "WINDOWS_WINRM_AUTH_FAILED"


def should_skip_winrm_openssh_install(ssh_open: bool) -> bool:
    return ssh_open


def powershell_payload_preserves_dollar_tokens(payload: str) -> bool:
    return "$ErrorActionPreference" in payload and "$_" in payload and "$svc" in payload


def redact_password(text: str, password: str) -> str:
    if not password:
        return text
    return text.replace(password, "***REDACTED***")
