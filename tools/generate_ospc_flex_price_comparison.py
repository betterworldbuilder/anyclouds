#!/usr/bin/env python3
"""Generate inferred OSPC price lists and regional OSPC/FLEX comparisons.

The repository has FLEX regional flavor catalogs, but no standalone OSPC
flavor price catalog. This generator infers OSPC monthly prices by aligning
TCO_Comparison_Report.csv with the same-row TCO flavormap used to produce it,
then aggregates observed legacy monthly cost by source OSPC flavor.
"""

from __future__ import annotations

import csv
import re
import statistics
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOURS_PER_MONTH = 720
SOURCE_MAP = ROOT / "uploads" / "tco_flavormap_1780381947_1342314_flavormap.csv"
SOURCE_TCO = ROOT / "TCO_Comparison_Report.csv"
FLAVOR_DIR = ROOT / "uploads" / "flavors"
REGIONS = ("IAD", "DFW", "SJC")
PRICING_SOURCE = (
    "Inferred from TCO_Comparison_Report.csv aligned with "
    "uploads/tco_flavormap_1780381947_1342314_flavormap.csv"
)


def money(value: object) -> float:
    text = str(value or "").replace("$", "").replace(",", "").strip()
    return float(text or 0)


def memory_to_mb(value: object) -> int:
    text = str(value or "").strip().replace(",", "")
    match = re.search(r"([0-9.]+)\s*GiB", text, re.I)
    if match:
        return int(round(float(match.group(1)) * 1024))
    match = re.search(r"([0-9.]+)\s*GB", text, re.I)
    if match:
        return int(round(float(match.group(1)) * 1024))
    return int(float(text or 0)) if text else 0


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig", errors="replace") as handle:
        return [{clean_header(k): v for k, v in row.items()} for row in csv.DictReader(handle)]


def clean_header(value: object) -> str:
    return str(value).replace("\ufeff", "").replace('"', "").strip()


def write_csv(path: Path, fieldnames: list[str], rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def build_ospc_catalog() -> list[dict[str, object]]:
    map_rows = read_csv(SOURCE_MAP)
    tco_rows = read_csv(SOURCE_TCO)
    by_flavor: dict[tuple[str, str, str, str, str], list[float]] = {}

    for mapped, tco in zip(map_rows, tco_rows):
        key = (
            mapped.get("source_flavor_id", ""),
            mapped.get("source_flavor_name", ""),
            mapped.get("source_ram_mb", ""),
            mapped.get("source_vcpus", ""),
            mapped.get("source_disk_gb", ""),
        )
        if not key[0]:
            continue
        by_flavor.setdefault(key, []).append(money(tco.get("Legacy Cloud Cost ($)")))

    catalog: list[dict[str, object]] = []
    for key, values in sorted(by_flavor.items(), key=lambda item: (int(item[0][3] or 0), int(item[0][2] or 0), item[0][0])):
        flavor_id, name, ram_mb, vcpus, disk_gb = key
        monthly = round(statistics.mean(values), 2)
        hourly = round(monthly / HOURS_PER_MONTH, 3)
        catalog.append(
            {
                "ID": flavor_id,
                "Name": name,
                "Category": "Compute Optimized" if flavor_id.startswith("compute") else "General Purpose",
                "Disk (GiB)": disk_gb,
                "CPU": vcpus,
                "Memory": f"{int(ram_mb) / 1024:g} GiB",
                "Internal Network Bandwidth (Gbps)": "",
                "Ephemeral Disk (GiB)": 0,
                "Cost per Hour": f"${hourly:.3f}",
                "Public": "Yes",
                "Monthly Cost": f"${monthly:.2f}",
                "Sample Count": len(values),
                "Pricing Source": PRICING_SOURCE,
            }
        )
    return catalog


def flex_catalog(region: str) -> list[dict[str, object]]:
    rows = []
    for row in read_csv(FLAVOR_DIR / f"{region}Flavors.csv"):
        rows.append(
            {
                "ID": row.get("ID", ""),
                "Name": row.get("Name", ""),
                "Category": row.get("Category", ""),
                "Disk (GiB)": int(float(row.get("Disk (GiB)") or 0)),
                "CPU": int(float(row.get("CPU") or 0)),
                "Memory": row.get("Memory", ""),
                "memory_mb": memory_to_mb(row.get("Memory", "")),
                "Cost per Hour": row.get("Cost per Hour", "$0.000"),
                "hourly": money(row.get("Cost per Hour")),
            }
        )
    return rows


def best_flex_match(source: dict[str, object], region: str) -> dict[str, object]:
    source_cpu = int(source["CPU"])
    source_ram = memory_to_mb(source["Memory"])
    source_disk = int(float(source["Disk (GiB)"] or 0))
    candidates = []
    for flavor in flex_catalog(region):
        if int(flavor["CPU"]) >= source_cpu and int(flavor["memory_mb"]) >= source_ram and int(flavor["Disk (GiB)"]) >= source_disk:
            overage = (
                (int(flavor["CPU"]) - source_cpu) * 10
                + (int(flavor["memory_mb"]) - source_ram) / 1024
                + max(0, int(flavor["Disk (GiB)"]) - source_disk) / 40
            )
            candidates.append((float(flavor["hourly"]), overage, flavor))
    if not candidates:
        candidates = [(float(flavor["hourly"]), 9999, flavor) for flavor in flex_catalog(region)]
    return sorted(candidates, key=lambda item: (item[0], item[1]))[0][2]


def comparison_rows(region: str, catalog: list[dict[str, object]]) -> list[dict[str, object]]:
    rows = []
    for source in catalog:
        flex = best_flex_match(source, region)
        ospc_monthly = money(source["Monthly Cost"])
        flex_hourly = float(flex["hourly"])
        flex_monthly = round(flex_hourly * HOURS_PER_MONTH, 2)
        savings = round(ospc_monthly - flex_monthly, 2)
        savings_pct = round((savings / ospc_monthly) * 100, 1) if ospc_monthly else 0
        rows.append(
            {
                "Region": region,
                "OSPC Flavor ID": source["ID"],
                "OSPC Flavor Name": source["Name"],
                "OSPC CPU": source["CPU"],
                "OSPC Memory": source["Memory"],
                "OSPC Disk (GiB)": source["Disk (GiB)"],
                "OSPC Hourly": source["Cost per Hour"],
                "OSPC Monthly": f"${ospc_monthly:.2f}",
                "FLEX Flavor ID": flex["ID"],
                "FLEX Flavor Name": flex["Name"],
                "FLEX CPU": flex["CPU"],
                "FLEX Memory": flex["Memory"],
                "FLEX Disk (GiB)": flex["Disk (GiB)"],
                "FLEX Hourly": f"${flex_hourly:.3f}",
                "FLEX Monthly": f"${flex_monthly:.2f}",
                "Monthly Savings": f"${savings:.2f}",
                "Savings %": f"{savings_pct:.1f}%",
                "Pricing Note": PRICING_SOURCE,
            }
        )
    return rows


def performance_rows(region: str, catalog: list[dict[str, object]]) -> list[dict[str, object]]:
    rows = []
    for source in catalog:
        flex = best_flex_match(source, region)
        ospc_cpu = int(source["CPU"])
        ospc_ram = memory_to_mb(source["Memory"])
        ospc_disk = int(float(source["Disk (GiB)"] or 0))
        flex_cpu = int(flex["CPU"])
        flex_ram = int(flex["memory_mb"])
        flex_disk = int(flex["Disk (GiB)"])
        cpu_gain = round((flex_cpu / ospc_cpu) * 100, 0) if ospc_cpu else 0
        ram_gain = round((flex_ram / ospc_ram) * 100, 0) if ospc_ram else 0
        if ospc_disk:
            disk_gain = round((flex_disk / ospc_disk) * 100, 0)
        else:
            disk_gain = "N/A"
        rows.append(
            {
                "Region": region,
                "OSPC Flavor ID": source["ID"],
                "OSPC Flavor Name": source["Name"],
                "OSPC CPU": ospc_cpu,
                "OSPC Memory": source["Memory"],
                "OSPC Disk (GiB)": ospc_disk,
                "FLEX Flavor ID": flex["ID"],
                "FLEX Flavor Name": flex["Name"],
                "FLEX CPU": flex_cpu,
                "FLEX Memory": flex["Memory"],
                "FLEX Disk (GiB)": flex_disk,
                "FLEX Internal Network Bandwidth": next(
                    (row.get("Internal Network Bandwidth (Gbps)", "") for row in read_csv(FLAVOR_DIR / f"{region}Flavors.csv") if row.get("Name") == flex["Name"]),
                    "",
                ),
                "CPU Capacity Index": f"{cpu_gain:.0f}%",
                "Memory Capacity Index": f"{ram_gain:.0f}%",
                "Disk Capacity Index": f"{disk_gain}%" if isinstance(disk_gain, (int, float)) else disk_gain,
                "Performance Note": "Compares matched FLEX flavor capacity against source OSPC flavor; FLEX also exposes regional bandwidth metadata.",
            }
        )
    return rows


def tco_summary_rows(region: str, catalog: list[dict[str, object]]) -> list[dict[str, object]]:
    rows = comparison_rows(region, catalog)
    ospc_monthly = sum(money(row["OSPC Monthly"]) for row in rows)
    flex_monthly = sum(money(row["FLEX Monthly"]) for row in rows)
    monthly_savings = ospc_monthly - flex_monthly
    savings_pct = (monthly_savings / ospc_monthly * 100) if ospc_monthly else 0
    return [
        {
            "Region": region,
            "Matched Flavors": len(rows),
            "OSPC Monthly": f"${ospc_monthly:.2f}",
            "FLEX Monthly": f"${flex_monthly:.2f}",
            "Monthly Savings": f"${monthly_savings:.2f}",
            "Savings %": f"{savings_pct:.1f}%",
            "1-Year Savings": f"${monthly_savings * 12:.2f}",
            "3-Year Savings": f"${monthly_savings * 36:.2f}",
            "5-Year Savings": f"${monthly_savings * 60:.2f}",
            "Pricing Note": PRICING_SOURCE,
        }
    ]


def main() -> None:
    catalog = build_ospc_catalog()
    ospc_fields = [
        "ID",
        "Name",
        "Category",
        "Disk (GiB)",
        "CPU",
        "Memory",
        "Internal Network Bandwidth (Gbps)",
        "Ephemeral Disk (GiB)",
        "Cost per Hour",
        "Public",
        "Monthly Cost",
        "Sample Count",
        "Pricing Source",
    ]
    comparison_fields = [
        "Region",
        "OSPC Flavor ID",
        "OSPC Flavor Name",
        "OSPC CPU",
        "OSPC Memory",
        "OSPC Disk (GiB)",
        "OSPC Hourly",
        "OSPC Monthly",
        "FLEX Flavor ID",
        "FLEX Flavor Name",
        "FLEX CPU",
        "FLEX Memory",
        "FLEX Disk (GiB)",
        "FLEX Hourly",
        "FLEX Monthly",
        "Monthly Savings",
        "Savings %",
        "Pricing Note",
    ]
    performance_fields = [
        "Region",
        "OSPC Flavor ID",
        "OSPC Flavor Name",
        "OSPC CPU",
        "OSPC Memory",
        "OSPC Disk (GiB)",
        "FLEX Flavor ID",
        "FLEX Flavor Name",
        "FLEX CPU",
        "FLEX Memory",
        "FLEX Disk (GiB)",
        "FLEX Internal Network Bandwidth",
        "CPU Capacity Index",
        "Memory Capacity Index",
        "Disk Capacity Index",
        "Performance Note",
    ]
    tco_summary_fields = [
        "Region",
        "Matched Flavors",
        "OSPC Monthly",
        "FLEX Monthly",
        "Monthly Savings",
        "Savings %",
        "1-Year Savings",
        "3-Year Savings",
        "5-Year Savings",
        "Pricing Note",
    ]
    for region in REGIONS:
        region_catalog = [dict(row, Region=region) for row in catalog]
        write_csv(FLAVOR_DIR / f"OSPC_{region}Flavors.csv", ["Region", *ospc_fields], region_catalog)
        write_csv(FLAVOR_DIR / f"{region}_OSPC_FLEX_Price_Comparison.csv", comparison_fields, comparison_rows(region, catalog))
        write_csv(FLAVOR_DIR / f"{region}_OSPC_FLEX_Performance_Comparison.csv", performance_fields, performance_rows(region, catalog))
        write_csv(FLAVOR_DIR / f"{region}_OSPC_FLEX_TCO_Summary.csv", tco_summary_fields, tco_summary_rows(region, catalog))


if __name__ == "__main__":
    main()
