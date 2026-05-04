#!/usr/bin/env python3
import argparse
import ast
import csv
import json
import re
import subprocess
from pathlib import Path
from typing import Dict, List, Tuple


def infer_account_id_from_filename(path: Path) -> str:
    m = re.match(r"^(\d+)_", path.stem)
    if m:
        return m.group(1)
    return path.stem


def read_csv(path: Path) -> List[Dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def write_csv(path: Path, rows: List[Dict[str, str]], fieldnames: List[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def run_openstack_json(args: List[str]) -> Tuple[bool, object, str]:
    cmd = ["openstack"] + args
    try:
        cp = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return False, None, "openstack CLI not found in PATH"

    if cp.returncode != 0:
        return False, None, (cp.stderr or cp.stdout or "unknown openstack CLI error").strip()

    try:
        return True, json.loads(cp.stdout), ""
    except json.JSONDecodeError:
        return False, None, f"failed to parse JSON from: {' '.join(cmd)}"


def parse_reason(reason: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    text = reason or ""
    for key in ("server", "device", "size_gb", "image"):
        m = re.search(rf"(?:^|,){key}=([^,]+)", text)
        if m:
            out[key] = m.group(1).strip()
    m = re.search(r"boot_volume_size_gb=(\d+)", text)
    if m:
        out["boot_volume_size_gb"] = m.group(1)
    return out


def normalize_flavor_name(flavor_field: object) -> str:
    if isinstance(flavor_field, dict):
        name = flavor_field.get("original_name") or flavor_field.get("name") or ""
        return str(name).strip()
    text = str(flavor_field or "").strip()
    if " (" in text:
        return text.split(" (", 1)[0].strip()
    return text


def parse_attachments(value: object) -> List[Dict[str, str]]:
    if isinstance(value, list):
        return [x for x in value if isinstance(x, dict)]
    text = str(value or "").strip()
    if not text:
        return []
    for parser in (json.loads, ast.literal_eval):
        try:
            parsed = parser(text)
            if isinstance(parsed, list):
                return [x for x in parsed if isinstance(x, dict)]
        except Exception:
            pass
    return []


def add_result(rows: List[Dict[str, str]], resource_type: str, resource_name: str, check: str, status: str, expected: str, actual: str, details: str) -> None:
    rows.append(
        {
            "resource_type": resource_type,
            "resource_name": resource_name,
            "check": check,
            "status": status,
            "expected": expected,
            "actual": actual,
            "details": details,
        }
    )


def verify(plan_rows: List[Dict[str, str]]) -> List[Dict[str, str]]:
    report: List[Dict[str, str]] = []

    for row in plan_rows:
        resource_type = (row.get("resource_type") or "").strip()
        action = (row.get("action") or "").strip()
        resource_name = (row.get("resource_name") or "").strip()
        reason = parse_reason(row.get("reason") or "")

        if resource_type == "server" and action.startswith("create_server"):
            expected_flavor = (row.get("target_flavor_name") or "").strip()
            ok, servers, err = run_openstack_json(["server", "list", "--name", resource_name, "-f", "json"])
            if not ok:
                add_result(report, "server", resource_name, "exists", "FAIL", "server should exist", "not found", err)
                continue

            exact = [s for s in (servers or []) if (s.get("Name") or "") == resource_name]
            if len(exact) == 0:
                add_result(report, "server", resource_name, "exists", "FAIL", "server should exist", "not found", "No exact name match")
                continue
            if len(exact) > 1:
                add_result(report, "server", resource_name, "unique", "FAIL", "single server", str(len(exact)), "Multiple servers with same name")
                continue

            server_id = exact[0].get("ID")
            ok, detail, err = run_openstack_json(["server", "show", str(server_id), "-f", "json"])
            if not ok:
                add_result(report, "server", resource_name, "details", "FAIL", "server show succeeds", "failed", err)
                continue

            status = (detail.get("status") or detail.get("Status") or "").strip()
            add_result(report, "server", resource_name, "status", "PASS" if status == "ACTIVE" else "WARN", "ACTIVE", status, "")

            actual_flavor = normalize_flavor_name(detail.get("flavor") or detail.get("Flavor"))
            add_result(
                report,
                "server",
                resource_name,
                "flavor",
                "PASS" if expected_flavor and actual_flavor == expected_flavor else "WARN",
                expected_flavor,
                actual_flavor,
                "",
            )

            if action == "create_server_local_boot" and reason.get("image"):
                image_field = detail.get("image") or detail.get("Image")
                image_text = str(image_field)
                add_result(
                    report,
                    "server",
                    resource_name,
                    "boot_source",
                    "PASS" if reason["image"] in image_text else "WARN",
                    f"image contains {reason['image']}",
                    image_text,
                    "",
                )

        if resource_type == "volume" and action == "create_and_attach_volume":
            expected_size = reason.get("size_gb", "")
            expected_server = reason.get("server", "")
            expected_device = reason.get("device", "")

            ok, detail, err = run_openstack_json(["volume", "show", resource_name, "-f", "json"])
            if not ok:
                add_result(report, "volume", resource_name, "exists", "FAIL", "volume should exist", "not found", err)
                continue

            size = str(detail.get("size") or detail.get("Size") or "")
            add_result(
                report,
                "volume",
                resource_name,
                "size_gb",
                "PASS" if expected_size and size == expected_size else "WARN",
                expected_size,
                size,
                "",
            )

            vstatus = (detail.get("status") or detail.get("Status") or "").strip()
            add_result(report, "volume", resource_name, "status", "PASS" if vstatus == "in-use" else "WARN", "in-use", vstatus, "")

            attachments = parse_attachments(detail.get("attachments") or detail.get("Attachments"))
            ok_attach = False
            attach_actual = ""
            for a in attachments:
                srv = str(a.get("server_id") or a.get("serverId") or "").strip()
                dev = str(a.get("device") or "").strip()
                attach_actual = f"server_id={srv},device={dev}"
                if expected_device and dev == expected_device:
                    ok_attach = True
            add_result(
                report,
                "volume",
                resource_name,
                "attachment_device",
                "PASS" if ok_attach else "WARN",
                f"server={expected_server},device={expected_device}",
                attach_actual,
                "Expected server name is from plan; attachment check uses device path primarily",
            )

    if not report:
        add_result(report, "all", "n/a", "plan_rows", "WARN", "non-empty plan", "empty", "No plan rows found to verify")

    return report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify deployed resources against tenant deploy plan CSV.")
    parser.add_argument("--plan", required=True, help="Path to <account_id>_tenant_deploy_plan.csv")
    parser.add_argument("--output", default="", help="Output CSV path for post-deploy verification report")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    plan_path = Path(args.plan).expanduser()
    if not plan_path.exists():
        raise SystemExit(f"Plan file not found: {plan_path}")

    plan_rows = read_csv(plan_path)
    report_rows = verify(plan_rows)

    if args.output.strip():
        out_path = Path(args.output).expanduser()
    else:
        account_id = infer_account_id_from_filename(plan_path)
        out_path = plan_path.with_name(f"{account_id}_post_deploy_report.csv")

    fields = ["resource_type", "resource_name", "check", "status", "expected", "actual", "details"]
    write_csv(out_path, report_rows, fields)

    pass_count = sum(1 for r in report_rows if r["status"] == "PASS")
    warn_count = sum(1 for r in report_rows if r["status"] == "WARN")
    fail_count = sum(1 for r in report_rows if r["status"] == "FAIL")

    print(f"Post-deploy report: {out_path}")
    print(f"Checks: {len(report_rows)}")
    print(f"PASS={pass_count} WARN={warn_count} FAIL={fail_count}")

    if fail_count > 0:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
