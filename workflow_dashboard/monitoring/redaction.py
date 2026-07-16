"""Secret redaction and safe text rendering for monitoring output."""
from __future__ import annotations

import re

REDACTED = "<redacted>"

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07")

# Order matters: the most specific patterns run first.
_SECRET_PATTERNS = [
    # key: value / key=value pairs for sensitive key names (yaml, env, logs)
    re.compile(
        r"(?i)\b((?:application_credential_secret|client_secret|secret_key|private_key|"
        r"password|passwd|api[_-]?key|access[_-]?key|auth[_-]?token|token|secret)s?)"
        r"(\s*[:=]\s*)(\"[^\"]*\"|'[^']*'|\S+)"
    ),
    # HTTP Authorization headers (Basic/Bearer)
    re.compile(r"(?i)\b(authorization\s*[:=]\s*(?:basic|bearer)\s+)\S+"),
    # tokens embedded in URLs: scheme://user:token@host
    re.compile(r"(?i)(://[^/\s:@]+:)[^@\s/]+(@)"),
    # age secret keys
    re.compile(r"AGE-SECRET-KEY-1[0-9A-Z]+"),
    # OpenStack application credential secrets exported in env dumps
    re.compile(r"(?i)\b(OS_APPLICATION_CREDENTIAL_SECRET|OS_PASSWORD)(=)\S+"),
]

_PRIVATE_KEY_BLOCK = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
    re.DOTALL,
)

# Key names whose values are dropped when redacting mappings.
_SENSITIVE_KEY_RE = re.compile(
    r"(?i)(secret|password|passwd|token|api[_-]?key|private[_-]?key|credential)"
)


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text or "")


def redact_text(text: str) -> str:
    """Redact secret material from free-form text (logs, command output)."""
    if not text:
        return text
    result = _PRIVATE_KEY_BLOCK.sub(REDACTED, text)
    for pattern in _SECRET_PATTERNS[:2]:
        result = pattern.sub(lambda m: m.group(1) + m.group(2) + REDACTED, result)
    result = _SECRET_PATTERNS[2].sub(lambda m: m.group(1) + REDACTED + m.group(2), result)
    result = _SECRET_PATTERNS[3].sub(REDACTED, result)
    result = _SECRET_PATTERNS[4].sub(lambda m: m.group(1) + m.group(2) + REDACTED, result)
    return result


def redact_line(line: str) -> str:
    """Strip ANSI and redact a single log line for browser rendering."""
    return redact_text(strip_ansi(line))


def redact_mapping(data):
    """Recursively drop values for sensitive keys in dict/list structures."""
    if isinstance(data, dict):
        return {
            key: (REDACTED if _SENSITIVE_KEY_RE.search(str(key)) else redact_mapping(value))
            for key, value in data.items()
        }
    if isinstance(data, list):
        return [redact_mapping(item) for item in data]
    if isinstance(data, str):
        return redact_text(data)
    return data
