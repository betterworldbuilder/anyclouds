#!/usr/bin/env python3
"""
ospc2flex_image_builder.py

Create a FLEX-ready image from an OSPC VM by:
1) creating a snapshot in OSPC
2) exporting the image locally
3) inspecting the image with qemu-img
4) converting it to a FLEX-ready format (default: qcow2)
5) optionally importing it into FLEX Glance

This tool is intentionally CLI-driven and uses:
- openstack CLI
- qemu-img
- bash (to source openrc files)

It is designed as a bridge utility, not a full migration orchestrator.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


class ToolError(RuntimeError):
    pass


@dataclass
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


def log(msg: str) -> None:
    print(msg, flush=True)


def shell_quote(value: str) -> str:
    return shlex.quote(value)


def run(
    cmd: list[str] | str,
    *,
    cwd: Optional[Path] = None,
    dry_run: bool = False,
    env: Optional[dict[str, str]] = None,
    check: bool = True,
    capture_output: bool = True,
) -> CommandResult:
    if isinstance(cmd, list):
        printable = " ".join(shell_quote(x) for x in cmd)
    else:
        printable = cmd
    log(f"[RUN] {printable}")

    if dry_run:
        return CommandResult(0, "", "")

    completed = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        shell=isinstance(cmd, str),
        text=True,
        capture_output=capture_output,
    )
    result = CommandResult(completed.returncode, completed.stdout or "", completed.stderr or "")
    if check and completed.returncode != 0:
        raise ToolError(
            f"Command failed ({completed.returncode}): {printable}\n"
            f"STDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
        )
    return result


def require_binary(name: str) -> None:
    if shutil.which(name) is None:
        raise ToolError(f"Required binary not found in PATH: {name}")


def require_file(path: Path, description: str) -> None:
    if not path.is_file():
        raise ToolError(f"{description} not found: {path}")


def openstack_cmd(openrc: Path, command: str) -> str:
    return f"bash -lc 'source {shell_quote(str(openrc))} && {command}'"


def wait_for_image_status(
    *,
    openrc: Path,
    image_ref: str,
    desired_status: str = "active",
    poll_seconds: int = 5,
    timeout_seconds: int = 1800,
    dry_run: bool = False,
) -> dict:
    desired_status = desired_status.lower()
    start = time.time()
    while True:
        res = run(
            openstack_cmd(
                openrc,
                f"openstack image show {shell_quote(image_ref)} -f json"
            ),
            dry_run=dry_run,
        )
        if dry_run:
            return {"status": desired_status, "id": image_ref, "name": image_ref}

        payload = json.loads(res.stdout)
        status = str(payload.get("status", "")).lower()
        log(f"[INFO] image={payload.get('name', image_ref)} status={status}")
        if status == desired_status:
            return payload

        if time.time() - start > timeout_seconds:
            raise ToolError(
                f"Timed out waiting for image '{image_ref}' to reach status '{desired_status}'. "
                f"Last status: '{status}'."
            )
        time.sleep(poll_seconds)


def qemu_info(image_path: Path, *, dry_run: bool = False) -> dict:
    res = run(["qemu-img", "info", "--output=json", str(image_path)], dry_run=dry_run)
    if dry_run:
        return {"format": "unknown", "virtual-size": 0}
    return json.loads(res.stdout)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Create a FLEX-ready image from an OSPC VM snapshot."
    )
    p.add_argument("--ospc-openrc", required=True, help="Path to OSPC openrc file")
    p.add_argument("--flex-openrc", help="Path to FLEX openrc file (required if --import-to-flex)")
    p.add_argument("--server-name", required=True, help="OSPC source VM/server name")
    p.add_argument("--snapshot-name", help="Optional snapshot name; auto-generated if omitted")
    p.add_argument("--workdir", default="./image_bridge_work", help="Working directory")
    p.add_argument("--target-format", default="qcow2", choices=["qcow2", "raw"], help="Target FLEX image disk format")
    p.add_argument("--source-format", choices=["raw", "qcow2", "vpc", "vhd", "vmdk"], help="Force source format for qemu-img convert if detection is wrong")
    p.add_argument("--import-to-flex", action="store_true", help="Import converted image into FLEX after conversion")
    p.add_argument("--flex-image-name", help="Target FLEX image name; default: <snapshot-name>-flex")
    p.add_argument("--visibility", default="private", choices=["public", "private", "shared", "community"], help="Visibility for imported FLEX image")
    p.add_argument("--container-format", default="bare", help="Glance container format for FLEX image")
    p.add_argument("--poll-seconds", type=int, default=5, help="Polling interval while waiting on snapshot/image status")
    p.add_argument("--timeout-seconds", type=int, default=1800, help="Timeout waiting for image state changes")
    p.add_argument("--keep-export", action="store_true", help="Keep exported source image file after conversion")
    p.add_argument("--cleanup-snapshot", action="store_true", help="Delete the OSPC snapshot image after successful export")
    p.add_argument("--dry-run", action="store_true", help="Print actions without executing them")
    return p


def main() -> int:
    args = build_parser().parse_args()

    ospc_openrc = Path(args.ospc_openrc).expanduser().resolve()
    require_file(ospc_openrc, "OSPC openrc")

    flex_openrc = None
    if args.import_to_flex:
        if not args.flex_openrc:
            raise ToolError("--flex-openrc is required when --import-to-flex is used")
        flex_openrc = Path(args.flex_openrc).expanduser().resolve()
        require_file(flex_openrc, "FLEX openrc")

    require_binary("bash")
    require_binary("openstack")
    require_binary("qemu-img")

    workdir = Path(args.workdir).expanduser().resolve()
    workdir.mkdir(parents=True, exist_ok=True)

    ts = time.strftime("%Y%m%d%H%M%S", time.gmtime())
    snapshot_name = args.snapshot_name or f"{args.server_name}-snap-{ts}"
    flex_image_name = args.flex_image_name or f"{snapshot_name}-flex"

    exported_guess = workdir / f"{snapshot_name}.img"
    metadata_file = workdir / f"{snapshot_name}.metadata.json"

    log("============================================================")
    log("OSPC -> FLEX image builder")
    log("============================================================")
    log(f"[INFO] server-name      : {args.server_name}")
    log(f"[INFO] snapshot-name    : {snapshot_name}")
    log(f"[INFO] workdir          : {workdir}")
    log(f"[INFO] target-format    : {args.target_format}")
    log(f"[INFO] import-to-flex   : {args.import_to_flex}")
    log("")

    # 1) Create snapshot in OSPC
    run(
        openstack_cmd(
            ospc_openrc,
            f"openstack server image create --name {shell_quote(snapshot_name)} {shell_quote(args.server_name)}"
        ),
        dry_run=args.dry_run,
    )

    # 2) Wait until snapshot image is active and fetch metadata
    image_payload = wait_for_image_status(
        openrc=ospc_openrc,
        image_ref=snapshot_name,
        poll_seconds=args.poll_seconds,
        timeout_seconds=args.timeout_seconds,
        dry_run=args.dry_run,
    )

    if not args.dry_run:
        metadata_file.write_text(json.dumps(image_payload, indent=2), encoding="utf-8")
        log(f"[INFO] OSPC snapshot metadata written to {metadata_file}")

    image_id = image_payload.get("id", snapshot_name)

    # 3) Export the OSPC image locally
    run(
        openstack_cmd(
            ospc_openrc,
            f"openstack image save --file {shell_quote(str(exported_guess))} {shell_quote(str(image_id))}"
        ),
        dry_run=args.dry_run,
    )

    # 4) Inspect exported image
    source_info = qemu_info(exported_guess, dry_run=args.dry_run)
    detected_format = source_info.get("format", "unknown")
    source_format = args.source_format or detected_format
    log(f"[INFO] qemu-img detected format: {detected_format}")
    log(f"[INFO] using source format     : {source_format}")

    converted_path = workdir / f"{snapshot_name}.{args.target_format}"

    # 5) Convert to target format
    # If the exported image is already in the requested format, keep it as-is.
    if not args.dry_run and detected_format == args.target_format and exported_guess.suffix == f".{args.target_format}":
        log("[INFO] Exported image is already in the target format and extension; skipping conversion.")
        converted_path = exported_guess
    else:
        run(
            [
                "qemu-img",
                "convert",
                "-f",
                source_format,
                "-O",
                args.target_format,
                str(exported_guess),
                str(converted_path),
            ],
            dry_run=args.dry_run,
        )
        qemu_info(converted_path, dry_run=args.dry_run)

    # 6) Optionally import into FLEX
    if args.import_to_flex and flex_openrc is not None:
        run(
            openstack_cmd(
                flex_openrc,
                " ".join(
                    [
                        "openstack image create",
                        f"--disk-format {shell_quote(args.target_format)}",
                        f"--container-format {shell_quote(args.container_format)}",
                        f"--visibility {shell_quote(args.visibility)}",
                        f"--file {shell_quote(str(converted_path))}",
                        shell_quote(flex_image_name),
                    ]
                ),
            ),
            dry_run=args.dry_run,
        )
        wait_for_image_status(
            openrc=flex_openrc,
            image_ref=flex_image_name,
            poll_seconds=args.poll_seconds,
            timeout_seconds=args.timeout_seconds,
            dry_run=args.dry_run,
        )
        log(f"[OK] FLEX-ready image imported: {flex_image_name}")

    # 7) Cleanup if requested
    if args.cleanup_snapshot:
        run(
            openstack_cmd(
                ospc_openrc,
                f"openstack image delete {shell_quote(str(image_id))}"
            ),
            dry_run=args.dry_run,
        )
        log(f"[INFO] Deleted temporary OSPC snapshot image: {image_id}")

    if not args.keep_export and converted_path != exported_guess:
        run(["rm", "-f", str(exported_guess)], dry_run=args.dry_run)
        log(f"[INFO] Removed exported intermediary image: {exported_guess}")

    log("")
    log("============================================================")
    log("[DONE] FLEX-ready image build completed")
    log("============================================================")
    log(f"[INFO] Snapshot name        : {snapshot_name}")
    log(f"[INFO] Exported metadata    : {metadata_file}")
    log(f"[INFO] Converted image path : {converted_path}")
    if args.import_to_flex:
        log(f"[INFO] FLEX image name      : {flex_image_name}")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ToolError as exc:
        log(f"[ERROR] {exc}")
        raise SystemExit(1)
    except KeyboardInterrupt:
        log("[ERROR] Interrupted by user")
        raise SystemExit(130)
