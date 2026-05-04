"""
I/O utilities: YAML/JSON read-write, subprocess wrapper, logging setup.

Uses ruamel.yaml when available (preserves comments/quotes/order);
falls back to pyyaml transparently.
"""
from __future__ import annotations

import json
import logging
import os
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple, Union

# ── YAML backend selection ────────────────────────────────────────────────────
try:
    from ruamel.yaml import YAML as _RuamelYAML
    from ruamel.yaml.compat import StringIO as _RuamelStringIO

    def _get_yaml() -> _RuamelYAML:
        y = _RuamelYAML()
        y.preserve_quotes = True
        y.default_flow_style = False
        y.width = 4096  # prevent wrapping
        return y

    def load_yaml(path: Union[str, Path]) -> Dict[str, Any]:
        """Load a single-document YAML file."""
        y = _get_yaml()
        with open(path, encoding="utf-8") as f:
            return y.load(f) or {}

    def load_yaml_multidoc(path: Union[str, Path]) -> List[Dict[str, Any]]:
        """Load a multi-document YAML file; skips None docs."""
        y = _get_yaml()
        with open(path, encoding="utf-8") as f:
            return [doc for doc in y.load_all(f) if doc is not None]

    def dump_yaml(data: Any, path: Union[str, Path]) -> None:
        """Write a single-document YAML file."""
        y = _get_yaml()
        with open(path, "w", encoding="utf-8") as f:
            y.dump(data, f)

    def dump_yaml_multidoc(docs: List[Any], path: Union[str, Path]) -> None:
        """Write a multi-document YAML file with --- separators."""
        y = _get_yaml()
        with open(path, "w", encoding="utf-8") as f:
            for i, doc in enumerate(docs):
                if i > 0:
                    f.write("---\n")
                stream = _RuamelStringIO()
                y.dump(doc, stream)
                f.write(stream.getvalue())

    _YAML_BACKEND = "ruamel"

except ImportError:
    import yaml as _pyyaml  # type: ignore

    def load_yaml(path: Union[str, Path]) -> Dict[str, Any]:  # type: ignore[misc]
        """Load a single-document YAML file (pyyaml fallback)."""
        with open(path, encoding="utf-8") as f:
            return _pyyaml.safe_load(f) or {}

    def load_yaml_multidoc(path: Union[str, Path]) -> List[Dict[str, Any]]:  # type: ignore[misc]
        """Load a multi-document YAML file (pyyaml fallback)."""
        with open(path, encoding="utf-8") as f:
            return [doc for doc in _pyyaml.safe_load_all(f) if doc is not None]

    def dump_yaml(data: Any, path: Union[str, Path]) -> None:  # type: ignore[misc]
        """Write a single-document YAML file (pyyaml fallback)."""
        with open(path, "w", encoding="utf-8") as f:
            _pyyaml.dump(data, f, default_flow_style=False, allow_unicode=True)

    def dump_yaml_multidoc(docs: List[Any], path: Union[str, Path]) -> None:  # type: ignore[misc]
        """Write a multi-document YAML file (pyyaml fallback)."""
        with open(path, "w", encoding="utf-8") as f:
            _pyyaml.dump_all(docs, f, default_flow_style=False, allow_unicode=True,
                             explicit_start=True)

    _YAML_BACKEND = "pyyaml"


# ── JSON helpers ──────────────────────────────────────────────────────────────

def load_json(path: Union[str, Path]) -> Any:
    """Load a JSON file and return the parsed object."""
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def dump_json(data: Any, path: Union[str, Path]) -> None:
    """Write data to a JSON file with 2-space indentation."""
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, default=str)


# ── Filesystem helpers ────────────────────────────────────────────────────────

def ensure_dir(path: Union[str, Path]) -> Path:
    """Create directory (and parents) if it does not exist. Returns Path."""
    p = Path(path)
    p.mkdir(parents=True, exist_ok=True)
    return p


# ── Subprocess wrapper ────────────────────────────────────────────────────────

def run_cmd(
    cmd: Union[str, List[str]],
    capture: bool = True,
    dry_run: bool = False,
    timeout: int = 300,
    check: bool = False,
    env: Optional[Dict[str, str]] = None,
    cwd: Optional[str] = None,
) -> Tuple[int, str, str]:
    """
    Run a shell command and return (returncode, stdout, stderr).

    Args:
        cmd:     Command as a string or list of strings.
        capture: If True, capture stdout/stderr; otherwise stream to terminal.
        dry_run: If True, print the command but do not execute it.
        timeout: Seconds before subprocess.TimeoutExpired is raised.
        check:   If True, raise RuntimeError on non-zero exit code.
        env:     Optional environment dict (merged with os.environ).
        cwd:     Optional working directory.

    Returns:
        (returncode, stdout, stderr)

    Raises:
        RuntimeError: if check=True and returncode != 0.
    """
    if isinstance(cmd, str):
        shell_cmd = cmd
        display_cmd = cmd
    else:
        shell_cmd = shlex.join(cmd)
        display_cmd = shell_cmd

    if dry_run:
        print(f"[DRY-RUN] {display_cmd}")
        return (0, "", "")

    merged_env: Optional[Dict[str, str]] = None
    if env:
        merged_env = {**os.environ, **env}

    try:
        if capture:
            result = subprocess.run(
                shell_cmd,
                shell=True,
                capture_output=True,
                text=True,
                timeout=timeout,
                env=merged_env,
                cwd=cwd,
            )
            stdout = result.stdout.strip()
            stderr = result.stderr.strip()
            rc = result.returncode
        else:
            result = subprocess.run(
                shell_cmd,
                shell=True,
                timeout=timeout,
                env=merged_env,
                cwd=cwd,
            )
            stdout = ""
            stderr = ""
            rc = result.returncode
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"Command timed out after {timeout}s: {display_cmd}")

    if check and rc != 0:
        raise RuntimeError(
            f"Command failed (exit {rc}): {display_cmd}\nstderr: {stderr}"
        )
    return (rc, stdout, stderr)


# ── Logging setup ─────────────────────────────────────────────────────────────

def setup_logging(
    log_dir: Union[str, Path],
    run_id: str,
    level: str = "INFO",
) -> logging.Logger:
    """
    Configure a logger that writes to stdout and to a file in log_dir.

    Args:
        log_dir: Directory where the log file will be written.
        run_id:  Unique identifier for this run; used as part of the filename.
        level:   Logging level string ('DEBUG', 'INFO', 'WARNING', 'ERROR').

    Returns:
        Configured Logger instance.
    """
    ensure_dir(log_dir)
    log_file = Path(log_dir) / f"migration_{run_id}.log"

    fmt = "%(asctime)s  %(levelname)-8s  %(name)s — %(message)s"
    date_fmt = "%Y-%m-%dT%H:%M:%S"

    logger = logging.getLogger(f"ospc2flex.{run_id}")
    logger.setLevel(getattr(logging, level.upper(), logging.INFO))
    logger.handlers.clear()

    # File handler
    fh = logging.FileHandler(log_file, encoding="utf-8")
    fh.setFormatter(logging.Formatter(fmt, datefmt=date_fmt))
    logger.addHandler(fh)

    # Stdout handler
    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(logging.Formatter(fmt, datefmt=date_fmt))
    logger.addHandler(sh)

    logger.info("Logging initialised. Backend: yaml=%s  log=%s", _YAML_BACKEND, log_file)
    return logger
