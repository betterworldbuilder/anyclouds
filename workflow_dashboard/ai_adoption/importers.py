"""Import providers: GitHub, Upload, FLEX business system.

Three providers, not the nine in the specification. LaunchPad and AI 4 the
People packages are handled by the upload provider plus a manifest validator —
both are "a zip with a manifest", so a separate provider class per vendor would
have been duplication. Container/model-registry/endpoint imports are deferred:
they produce metadata no downstream plan step consumes yet.

Imported content is untrusted. Nothing here executes it: no notebook is run, no
image is built, no repository script is invoked. Discovery is pure file reading.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from .models import now_ms

# Caps. A hostile archive's whole purpose is to be larger or deeper than you
# expected, so every dimension is bounded, not just total size.
MAX_ARCHIVE_BYTES = 250 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 1024 * 1024 * 1024
MAX_ENTRIES = 20000
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_PATH_DEPTH = 24

CLONE_TIMEOUT_SEC = 180

# Extensions worth reading during discovery. Anything else is recorded by name
# and never opened.
TEXT_EXTS = {
    ".py", ".js", ".ts", ".tsx", ".jsx", ".java", ".go", ".rb", ".rs", ".cs",
    ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf", ".env",
    ".txt", ".md", ".rst", ".sh", ".bash", ".sql", ".ipynb", ".lock",
    ".dockerfile", ".tf", ".tfvars", ".gradle", ".properties", ".xml",
}

BLOCKED_EXTS = {".exe", ".dll", ".so", ".dylib", ".bin", ".pyc", ".class", ".jar"}


class ImportError_(Exception):
    """Import failed for a reason worth showing the user."""


# ---------------------------------------------------------------- archive safety


def _reject_member(name: str, size: int) -> Optional[str]:
    """Return a rejection reason, or None when the member is acceptable."""
    if not name or name.strip() != name.strip("\x00"):
        return "null byte in entry name"
    p = Path(name)
    if p.is_absolute() or name.startswith("/") or name.startswith("\\"):
        return f"absolute path in archive: {name}"
    # Reject traversal on the parts, not on the string: "a/../../b" has no
    # literal "../" prefix but still escapes.
    if any(part == ".." for part in p.parts):
        return f"path traversal in archive: {name}"
    if len(p.parts) > MAX_PATH_DEPTH:
        return f"path too deep: {name}"
    if ":" in name and os.name == "nt":
        return f"drive-relative path: {name}"
    if size > MAX_FILE_BYTES:
        return f"member exceeds {MAX_FILE_BYTES} bytes: {name}"
    if p.suffix.lower() in BLOCKED_EXTS:
        return f"blocked file type: {name}"
    return None


def _safe_extract_zip(archive: Path, dest: Path) -> List[str]:
    warnings: List[str] = []
    total = 0
    with zipfile.ZipFile(archive) as zf:
        members = zf.infolist()
        if len(members) > MAX_ENTRIES:
            raise ImportError_(f"archive has {len(members)} entries (max {MAX_ENTRIES})")
        for info in members:
            if info.is_dir():
                continue
            reason = _reject_member(info.filename, info.file_size)
            if reason:
                warnings.append(reason)
                continue
            total += info.file_size
            if total > MAX_UNCOMPRESSED_BYTES:
                raise ImportError_("archive expands beyond the uncompressed size limit")
            target = (dest / info.filename).resolve()
            # Belt and braces: even after the checks above, confirm the resolved
            # path is inside dest before writing.
            if not str(target).startswith(str(dest.resolve()) + os.sep):
                warnings.append(f"escapes destination: {info.filename}")
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, open(target, "wb") as out:
                shutil.copyfileobj(src, out, 1024 * 64)
    return warnings


def _safe_extract_tar(archive: Path, dest: Path) -> List[str]:
    warnings: List[str] = []
    total = 0
    with tarfile.open(archive, "r:*") as tf:
        count = 0
        for member in tf:
            count += 1
            if count > MAX_ENTRIES:
                raise ImportError_(f"archive has more than {MAX_ENTRIES} entries")
            # Symlinks and hardlinks are how a tar escapes a directory it was
            # correctly extracted into. Drop them rather than resolve them.
            if member.issym() or member.islnk():
                warnings.append(f"link entry skipped: {member.name}")
                continue
            if member.isdev() or member.isfifo():
                warnings.append(f"device entry skipped: {member.name}")
                continue
            if not member.isfile():
                continue
            reason = _reject_member(member.name, member.size)
            if reason:
                warnings.append(reason)
                continue
            total += member.size
            if total > MAX_UNCOMPRESSED_BYTES:
                raise ImportError_("archive expands beyond the uncompressed size limit")
            target = (dest / member.name).resolve()
            if not str(target).startswith(str(dest.resolve()) + os.sep):
                warnings.append(f"escapes destination: {member.name}")
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            extracted = tf.extractfile(member)
            if extracted is None:
                continue
            with extracted as src, open(target, "wb") as out:
                shutil.copyfileobj(src, out, 1024 * 64)
    return warnings


def extract_archive(archive: Path, dest: Path) -> List[str]:
    dest.mkdir(parents=True, exist_ok=True)
    size = archive.stat().st_size
    if size > MAX_ARCHIVE_BYTES:
        raise ImportError_(f"archive is {size} bytes (max {MAX_ARCHIVE_BYTES})")
    if zipfile.is_zipfile(archive):
        return _safe_extract_zip(archive, dest)
    if tarfile.is_tarfile(archive):
        return _safe_extract_tar(archive, dest)
    raise ImportError_("unsupported archive format (expected zip or tar)")


# ---------------------------------------------------------------- github


def _git(args: List[str], cwd: Optional[Path] = None, token_env: str = "") -> Tuple[int, str]:
    env = dict(os.environ)
    # Never let git block on a credential prompt; a hung clone would pin a
    # worker thread until the timeout.
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GCM_INTERACTIVE"] = "never"
    askpass: Optional[Path] = None
    if token_env:
        token = os.environ.get(token_env, "")
        if not token:
            raise ImportError_(f"credential reference {token_env} is not set in the environment")
        # The token goes to git through GIT_ASKPASS, never on the command line:
        # argv is world-readable via ps, a process environment is not.
        askpass = Path(tempfile.mkdtemp(prefix="aiadopt-ap-")) / "askpass.sh"
        askpass.write_text('#!/bin/sh\nprintf "%s" "$AI_ADOPTION_GIT_TOKEN"\n', encoding="utf-8")
        askpass.chmod(0o700)
        env["GIT_ASKPASS"] = str(askpass)
        env["AI_ADOPTION_GIT_TOKEN"] = token
    try:
        proc = subprocess.run(
            ["git"] + args,
            cwd=str(cwd) if cwd else None,
            env=env,
            capture_output=True,
            text=True,
            timeout=CLONE_TIMEOUT_SEC,
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode, _redact(out)
    except subprocess.TimeoutExpired:
        return 124, f"git timed out after {CLONE_TIMEOUT_SEC}s"
    finally:
        if askpass is not None:
            shutil.rmtree(askpass.parent, ignore_errors=True)


def _redact(text: str) -> str:
    """Strip anything token-shaped before the text reaches a log or a response."""
    import re

    text = re.sub(r"gh[pousr]_[A-Za-z0-9]{16,}", "***", text)
    text = re.sub(r"github_pat_[A-Za-z0-9_]{20,}", "***", text)
    # https://user:secret@host -> https://***@host
    text = re.sub(r"(https?://)[^/\s:@]+:[^/\s@]+@", r"\1***@", text)
    return text


def import_github(
    repo_url: str,
    workspace: Path,
    branch: str = "",
    commit: str = "",
    subdir: str = "",
    credential_reference: str = "",
) -> Dict[str, Any]:
    """Shallow-clone a repository into an isolated workspace.

    credential_reference is the *name of an environment variable* holding a
    read-only token, never the token itself — a raw secret in a request body
    would end up in access logs and in the project document.
    """
    url = (repo_url or "").strip()
    if not (url.startswith("https://") or url.startswith("git@") or url.startswith("ssh://")):
        raise ImportError_("repository URL must be https:// or ssh")

    src = workspace / "src"
    src.mkdir(parents=True, exist_ok=True)

    args = ["clone", "--depth", "1", "--single-branch", "--no-tags"]
    # Submodules are separate untrusted repositories; do not fetch them.
    if branch:
        args += ["--branch", branch]
    args += [url, str(src)]
    rc, log = _git(args, token_env=credential_reference)
    if rc != 0:
        raise ImportError_(f"git clone failed: {log.strip()[:400]}")

    if commit:
        rc2, log2 = _git(["fetch", "--depth", "1", "origin", commit], cwd=src, token_env=credential_reference)
        if rc2 == 0:
            _git(["checkout", "--detach", "FETCH_HEAD"], cwd=src, token_env=credential_reference)
        else:
            log += f"\n(requested commit {commit} not fetchable: {log2.strip()[:200]})"

    rc3, head = _git(["rev-parse", "HEAD"], cwd=src)
    resolved_commit = head.strip() if rc3 == 0 else ""
    rc4, ref = _git(["rev-parse", "--abbrev-ref", "HEAD"], cwd=src)
    resolved_branch = ref.strip() if rc4 == 0 else branch

    root = src
    if subdir:
        candidate = (src / subdir).resolve()
        if not str(candidate).startswith(str(src.resolve())) or not candidate.is_dir():
            raise ImportError_(f"project subdirectory not found: {subdir}")
        root = candidate

    # The .git directory is metadata, not project content; dropping it keeps it
    # out of the scanner's file inventory and out of any retained artifact.
    shutil.rmtree(src / ".git", ignore_errors=True)

    return {
        "provider": "GITHUB",
        "source_uri": _redact(url),
        "display_name": url.rstrip("/").split("/")[-1].removesuffix(".git"),
        "branch": resolved_branch,
        "commit_sha": resolved_commit,
        "project_path": subdir,
        "root": str(root),
        "imported_at": now_ms(),
        "import_status": "OK",
        "warnings": [],
        "credential_reference": credential_reference,  # the name, never the value
    }


# ---------------------------------------------------------------- upload


def import_upload(archive_path: Path, workspace: Path, display_name: str = "") -> Dict[str, Any]:
    src = workspace / "src"
    name = Path(archive_path).name

    if name.lower().endswith(".ipynb"):
        # A bare notebook is its own project.
        src.mkdir(parents=True, exist_ok=True)
        shutil.copy2(archive_path, src / name)
        warnings: List[str] = []
    else:
        warnings = extract_archive(Path(archive_path), src)

    # A zip normally contains a single top-level directory; descend into it so
    # the scanner sees the project root rather than a wrapper.
    root = src
    entries = [p for p in src.iterdir()] if src.is_dir() else []
    if len(entries) == 1 and entries[0].is_dir():
        root = entries[0]

    return {
        "provider": "UPLOAD",
        "source_uri": name,
        "display_name": display_name or Path(name).stem,
        "branch": "",
        "commit_sha": "",
        "project_path": "",
        "root": str(root),
        "imported_at": now_ms(),
        "import_status": "OK" if not warnings else "OK_WITH_WARNINGS",
        "warnings": warnings,
        "credential_reference": "",
    }


# ---------------------------------------------------------------- flex system


def import_flex_system(system: Dict[str, Any]) -> Dict[str, Any]:
    """The 'source' is an already-migrated FLEX business system.

    Used by both modes: Brownfield adds AI beside the app, Greenfield builds a
    new AI platform seeded from it. Either way there is no code to fetch — the
    application stays where it is.

    What we do capture is its **cloud-native posture**. A containerized app
    already running on OpenCenter Kubernetes, with health endpoints and a
    published API, is materially readier to host AI features than a lift-and-
    shifted VM, and the assessment should be able to tell them apart instead of
    reporting everything as unchecked.
    """
    name = str(system.get("name") or "Business System").strip()

    raw_components = system.get("components") or system.get("parts") or []
    if not isinstance(raw_components, list):
        raw_components = []
    component_records = []
    for component in raw_components:
        if isinstance(component, dict):
            component_name = str(
                component.get("name")
                or component.get("component")
                or component.get("role")
                or ""
            ).strip()
            if not component_name:
                continue
            component_records.append(
                {
                    "name": component_name,
                    "type": str(component.get("type") or component.get("role") or "").strip(),
                    "runtime": str(component.get("runtime") or component.get("product") or "").strip(),
                    "source": str(
                        component.get("src")
                        or component.get("source")
                        or component.get("source_url")
                        or ""
                    ).strip(),
                    "target": str(
                        component.get("tgt")
                        or component.get("target")
                        or component.get("target_url")
                        or ""
                    ).strip(),
                    "path": str(component.get("path") or "").strip(),
                }
            )
        else:
            component_name = str(component).strip()
            if component_name:
                component_records.append({"name": component_name})

    vm_source = system.get("vms")
    if vm_source is None:
        vm_source = system.get("apps")
    if isinstance(vm_source, (list, tuple, dict)):
        vm_count = len(vm_source)
    else:
        try:
            vm_count = int(vm_source or 0)
        except (TypeError, ValueError):
            vm_count = 0

    def _flag(*keys: str) -> bool:
        for key in keys:
            if bool(system.get(key)):
                return True
        return False

    posture = {
        "containerised": _flag("containerised", "containerized", "container_image"),
        "kubernetes": _flag("kubernetes", "openceter", "opencenter", "k8s", "namespace"),
        "health_endpoint": _flag("health_endpoint", "health"),
        "api_published": _flag("openapi", "api_spec", "api_published"),
        "container_image": str(system.get("container_image") or "").strip(),
        "namespace": str(system.get("namespace") or "").strip(),
    }
    posture["cloud_native"] = posture["containerised"] and posture["kubernetes"]

    return {
        "provider": "FLEX_BUSINESS_SYSTEM",
        "source_uri": f"flex://{system.get('id') or name}",
        "display_name": name,
        "branch": "",
        "commit_sha": "",
        "project_path": "",
        "root": "",
        "imported_at": now_ms(),
        "import_status": "OK",
        "warnings": [],
        "credential_reference": "",
        "declared": {
            "vms": vm_count,
            "data_types": system.get("dataTypes") or system.get("data_type") or [],
            "sensitivity": (system.get("sensitivity") or "").upper(),
            "status": system.get("status") or "MIGRATED",
            # From the Migration Log business-system engine. These are the parts
            # an AI layer will actually integrate with, so they are recorded as
            # components rather than collapsed into a VM count.
            "archetype": str(system.get("archetype") or "").strip(),
            "criticality": str(system.get("criticality") or "").strip(),
            "components": [record["name"] for record in component_records],
            "component_records": component_records,
            "region": str(system.get("region") or "").strip(),
            "wave": str(system.get("wave") or system.get("migrationWave") or "").strip(),
            "risk": str(system.get("risk") or "").strip(),
        },
        "posture": posture,
    }


# ---------------------------------------------------------------- manifests


def import_opencenter_workload(workload: Dict[str, Any]) -> Dict[str, Any]:
    """A containerised FLEX application already running on OpenCenter.

    No source tree either, but unlike a declared FLEX system this one arrives
    *from* Kubernetes — so containerised and orchestrated are observed facts,
    not assertions. Health and API posture still have to be declared, because a
    workload can run happily on Kubernetes without exposing either.
    """
    name = str(workload.get("name") or workload.get("deployment") or "Workload").strip()
    image = str(workload.get("image") or workload.get("container_image") or "").strip()
    namespace = str(workload.get("namespace") or "").strip()

    posture = {
        # Observed: it is running on OpenCenter.
        "containerised": True,
        "kubernetes": True,
        # Declared: a probe or a published spec may or may not exist.
        "health_endpoint": bool(workload.get("health_endpoint") or workload.get("readiness_probe")),
        "api_published": bool(workload.get("openapi") or workload.get("api_published")),
        "container_image": image,
        "namespace": namespace,
        "cloud_native": True,
        "observed_from": "OpenCenter",
    }

    return {
        "provider": "OPENCENTER",
        "source_uri": f"opencenter://{namespace or 'default'}/{name}",
        "display_name": name,
        "branch": "",
        "commit_sha": "",
        "project_path": "",
        "root": "",
        "imported_at": now_ms(),
        "import_status": "OK",
        "warnings": [] if image else ["container image digest not supplied — deployment is not reproducible"],
        "credential_reference": "",
        "declared": {
            "cluster": str(workload.get("cluster") or "").strip(),
            "namespace": namespace,
            "replicas": workload.get("replicas") or 0,
            "image": image,
            "sensitivity": str(workload.get("sensitivity") or "").upper(),
        },
        "posture": posture,
    }


LAUNCHPAD_MANIFEST = "launchpad-project.json"
AI4PEOPLE_MANIFEST = "cloudjumper-handoff.yaml"

# Required top-level keys. Absence is reported as a compatibility finding rather
# than a hard failure: a partial bundle is still worth importing, it just cannot
# claim readiness it has not evidenced.
AI4PEOPLE_REQUIRED = ["schema_version", "project", "agent", "model", "data", "deployment"]
LAUNCHPAD_REQUIRED = ["name", "use_case", "owner"]


def detect_manifest(root: Path) -> Dict[str, Any]:
    """Identify a LaunchPad or AI 4 the People bundle and validate its manifest."""
    result: Dict[str, Any] = {"kind": "", "findings": [], "manifest": {}}

    lp = root / LAUNCHPAD_MANIFEST
    a4p = root / AI4PEOPLE_MANIFEST

    if a4p.is_file():
        result["kind"] = "AI4PEOPLE"
        try:
            import yaml

            data = yaml.safe_load(a4p.read_text(encoding="utf-8", errors="replace")) or {}
        except Exception as exc:
            result["findings"].append(f"{AI4PEOPLE_MANIFEST} is not valid YAML: {exc}")
            return result
        if not isinstance(data, dict):
            result["findings"].append(f"{AI4PEOPLE_MANIFEST} must be a mapping")
            return result
        result["manifest"] = data
        for key in AI4PEOPLE_REQUIRED:
            if key not in data:
                result["findings"].append(f"missing required section: {key}")
        if str(data.get("schema_version") or "") not in ("1.0", "1"):
            result["findings"].append(f"unsupported schema_version: {data.get('schema_version')!r}")
        model = data.get("model") if isinstance(data.get("model"), dict) else {}
        if not model.get("license"):
            result["findings"].append("model license not declared")
        dat = data.get("data") if isinstance(data.get("data"), dict) else {}
        if not dat.get("sensitivity"):
            result["findings"].append("data sensitivity not declared")
        proj = data.get("project") if isinstance(data.get("project"), dict) else {}
        if not proj.get("owner"):
            result["findings"].append("project owner not declared")
        agent = data.get("agent") if isinstance(data.get("agent"), dict) else {}
        if not agent.get("health_endpoint"):
            result["findings"].append("health endpoint not declared")
        return result

    if lp.is_file():
        result["kind"] = "LAUNCHPAD"
        try:
            import json as _json

            data = _json.loads(lp.read_text(encoding="utf-8", errors="replace"))
        except Exception as exc:
            result["findings"].append(f"{LAUNCHPAD_MANIFEST} is not valid JSON: {exc}")
            return result
        if not isinstance(data, dict):
            result["findings"].append(f"{LAUNCHPAD_MANIFEST} must be an object")
            return result
        result["manifest"] = data
        for key in LAUNCHPAD_REQUIRED:
            if not data.get(key):
                result["findings"].append(f"missing required field: {key}")
        return result

    return result


def cleanup(workspace: Path) -> None:
    """Delete the temporary import workspace. Always called, including on error."""
    shutil.rmtree(workspace, ignore_errors=True)
