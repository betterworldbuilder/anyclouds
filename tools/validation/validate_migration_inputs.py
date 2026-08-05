#!/usr/bin/env python3
import argparse
import csv
import re
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


def is_truthy(value: str) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "y", "on"}


def to_int(value: str) -> int:
    try:
        return int(float((value or "").strip()))
    except ValueError:
        return 0


def infer_image_min_disk_gb(image_name: str) -> int:
    name = (image_name or "").strip().lower()
    if "windows" in name:
        return 80
    return 20


def add_finding(findings: List[Dict[str, str]], severity: str, code: str, scope: str, message: str) -> None:
    findings.append(
        {
            "severity": severity,
            "code": code,
            "scope": scope,
            "message": message,
        }
    )


def validate(flavor_rows: List[Dict[str, str]], block_rows: List[Dict[str, str]]) -> Tuple[List[Dict[str, str]], int]:
    findings: List[Dict[str, str]] = []
    error_count = 0

    required_flavor_cols = {
        "server_id",
        "server_name",
        "include_in_deploy",
        "target_flavor_name",
        "recommended_target_image_name",
        "boot_strategy",
        "boot_from_volume_size_gb",
    }
    required_block_cols = {
        "source_server_id",
        "source_volume_name",
        "volume_size_gb",
        "target_device_path",
        "volume_role",
        "target_action",
    }

    flavor_cols = set(flavor_rows[0].keys()) if flavor_rows else set()
    block_cols = set(block_rows[0].keys()) if block_rows else set()

    missing_flavor = sorted(required_flavor_cols - flavor_cols)
    missing_block = sorted(required_block_cols - block_cols)

    if missing_flavor:
        add_finding(findings, "ERROR", "missing_flavor_columns", "flavormap", f"Missing required columns: {', '.join(missing_flavor)}")
        error_count += 1
    if not block_rows:
        add_finding(findings, "INFO", "block_mapping_empty", "blockmap", "Block mapping has no rows.")
    elif missing_block:
        add_finding(findings, "ERROR", "missing_block_columns", "blockmap", f"Missing required columns: {', '.join(missing_block)}")
        error_count += 1

    included_ids = set()
    included_target_names = {}

    for idx, row in enumerate(flavor_rows, start=2):
        server_id = (row.get("server_id") or "").strip()
        server_name = (row.get("server_name") or "").strip()
        target_server_name = (row.get("target_server_name") or "").strip() or server_name
        include_raw = row.get("include_in_deploy")

        if include_raw is None or include_raw.strip() == "":
            add_finding(findings, "WARN", "empty_include_flag", f"flavormap:row:{idx}", "include_in_deploy is blank; defaulting to include")
            include = True
        else:
            include = is_truthy(include_raw)

        if not include:
            continue

        included_ids.add(server_id)
        if target_server_name:
            included_target_names.setdefault(target_server_name, []).append(idx)

        target_flavor = (row.get("target_flavor_name") or "").strip()
        image = (row.get("recommended_target_image_name") or "").strip()
        boot_strategy = (row.get("boot_strategy") or "").strip()
        boot_size = to_int(row.get("boot_from_volume_size_gb") or "")

        if not target_flavor:
            add_finding(findings, "ERROR", "missing_target_flavor", f"flavormap:row:{idx}", f"server_id={server_id} missing target_flavor_name")
            error_count += 1

        is_flex2flex_reuse = (
            boot_strategy == "flex2flex_rebuild_from_source_image"
            or "flex2flex_source_image_reuse" in (row.get("image_recommendation_note") or "").lower()
        )
        if not image and not is_flex2flex_reuse:
            add_finding(findings, "ERROR", "missing_target_image", f"flavormap:row:{idx}", f"server_id={server_id} missing recommended_target_image_name")
            error_count += 1

        if boot_strategy == "boot_from_volume" and boot_size <= 0:
            add_finding(findings, "ERROR", "invalid_boot_volume_size", f"flavormap:row:{idx}", f"server_id={server_id} has boot_from_volume but invalid size")
            error_count += 1
        if boot_strategy == "boot_from_volume" and boot_size > 0 and image:
            min_disk = infer_image_min_disk_gb(image)
            if boot_size < min_disk:
                add_finding(
                    findings,
                    "WARN",
                    "boot_volume_below_image_min_disk",
                    f"flavormap:row:{idx}",
                    f"server_id={server_id} boot_from_volume_size_gb={boot_size} is below image minimum {min_disk} for '{image}'",
                )

        if boot_strategy == "boot_from_volume_required_by_target_flavor" and boot_size <= 0:
            add_finding(
                findings,
                "ERROR",
                "missing_required_boot_volume_size",
                f"flavormap:row:{idx}",
                f"server_id={server_id} target flavor requires boot volume but size is missing",
            )
            error_count += 1

    for name, rows in included_target_names.items():
        if len(rows) > 1:
            add_finding(
                findings,
                "WARN",
                "duplicate_target_server_name",
                "flavormap",
                f"Included target_server_name '{name}' appears multiple times at rows {rows}; target name collisions can break deployment",
            )

    for idx, row in enumerate(block_rows, start=2):
        source_server_id = (row.get("source_server_id") or "").strip()
        role = (row.get("volume_role") or "").strip().lower()
        action = (row.get("target_action") or "").strip().lower()
        size = to_int(row.get("volume_size_gb") or "")
        target_device = (row.get("target_device_path") or "").strip()

        if source_server_id and source_server_id not in included_ids:
            add_finding(
                findings,
                "INFO",
                "volume_for_excluded_or_unknown_server",
                f"blockmap:row:{idx}",
                f"source_server_id={source_server_id} is excluded or not included in deploy",
            )

        if role == "data" and action == "create_and_attach_volume":
            if size <= 0:
                add_finding(findings, "ERROR", "invalid_data_volume_size", f"blockmap:row:{idx}", f"source_server_id={source_server_id} has non-positive volume_size_gb")
                error_count += 1
            if not target_device:
                add_finding(findings, "ERROR", "missing_target_device", f"blockmap:row:{idx}", f"source_server_id={source_server_id} missing target_device_path")
                error_count += 1
            elif not target_device.startswith("/dev/vd"):
                add_finding(findings, "WARN", "nonstandard_target_device", f"blockmap:row:{idx}", f"target_device_path={target_device} expected /dev/vd*")

    if not findings:
        add_finding(findings, "INFO", "validation_passed", "all", "No issues found")

    return findings, error_count


def write_findings(path: Path, findings: List[Dict[str, str]]) -> None:
    fields = ["severity", "code", "scope", "message"]
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(findings)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate flavormap/blockmap inputs before deployment generation.")
    parser.add_argument("--flavor-mapping", required=True, help="Path to <account_id>_flavormap.csv")
    parser.add_argument("--block-storage-mapping", required=True, help="Path to <account_id>_blockmap.csv")
    parser.add_argument("--output", default="", help="Output CSV path for validation report")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    flavor_path = Path(args.flavor_mapping).expanduser()
    block_path = Path(args.block_storage_mapping).expanduser()

    if not flavor_path.exists():
        raise SystemExit(f"Flavor mapping file not found: {flavor_path}")
    if not block_path.exists():
        raise SystemExit(f"Block storage mapping file not found: {block_path}")

    flavor_rows = read_csv(flavor_path)
    block_rows = read_csv(block_path)

    findings, error_count = validate(flavor_rows, block_rows)

    if args.output.strip():
        output_path = Path(args.output).expanduser()
    else:
        account_id = infer_account_id_from_filename(flavor_path)
        output_path = flavor_path.with_name(f"{account_id}_validation_report.csv")

    write_findings(output_path, findings)

    print(f"Validation report: {output_path}")
    print(f"Findings: {len(findings)}")
    print(f"Errors: {error_count}")

    if error_count > 0:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
