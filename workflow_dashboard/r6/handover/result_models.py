"""Shared result and status constants for the R6 handover engine."""
import enum


class CheckStatus(str, enum.Enum):
    PENDING = "PENDING"
    RUNNING = "RUNNING"
    PASS = "PASS"
    FAIL = "FAIL"
    WARNING = "WARNING"
    NOT_APPLICABLE = "NOT_APPLICABLE"
    CANCELLED = "CANCELLED"
    WARNING_APPROVED = "WARNING_APPROVED"


class RunStatus(str, enum.Enum):
    PENDING = "PENDING"
    RUNNING = "RUNNING"
    COMPLETE = "COMPLETE"
    CANCELLED = "CANCELLED"
    FAILED = "FAILED"


class Verdict(str, enum.Enum):
    READY = "READY"
    READY_WITH_WARNINGS = "READY_WITH_WARNINGS"
    NOT_READY = "NOT_READY"
    BLOCKED = "BLOCKED"


def make_check_result(check_id, status, message="", evidence=None, output=""):
    return {
        "checkId": check_id,
        "status": status.value if isinstance(status, CheckStatus) else status,
        "message": message,
        "evidence": evidence or {},
        "output": output,
    }
