#!/usr/bin/env python3
import argparse
import ast
import csv
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple


@dataclass(frozen=True)
class Flavor:
    flavor_id: str
    name: str
    ram_mb: int
    disk_gb: int
    vcpus: int


SOURCE_FLAVORS: Dict[str, Flavor] = {
    "2": Flavor("2", "512MB Standard Instance", 512, 20, 1),
    "3": Flavor("3", "1GB Standard Instance", 1024, 40, 1),
    "4": Flavor("4", "2GB Standard Instance", 2048, 80, 2),
    "5": Flavor("5", "4GB Standard Instance", 4096, 160, 2),
    "6": Flavor("6", "8GB Standard Instance", 8192, 320, 4),
    "7": Flavor("7", "15GB Standard Instance", 15360, 620, 6),
    "8": Flavor("8", "30GB Standard Instance", 30720, 1200, 8),
    "classic1-256": Flavor("classic1-256", "256 MB Classic v1", 256, 10, 4),
    "classic1-512": Flavor("classic1-512", "512 MB Classic v1", 512, 20, 4),
    "classic1-1": Flavor("classic1-1", "1 GB Classic v1", 1024, 40, 4),
    "classic1-2": Flavor("classic1-2", "2 GB Classic v1", 2048, 80, 4),
    "classic1-4": Flavor("classic1-4", "4 GB Classic v1", 4096, 160, 4),
    "classic1-8": Flavor("classic1-8", "8 GB Classic v1", 8192, 320, 4),
    "classic1-15": Flavor("classic1-15", "15 GB Classic v1", 15360, 620, 6),
    "classic1-30": Flavor("classic1-30", "30 GB Classic v1", 30720, 1200, 8),
    "compute1-15": Flavor("compute1-15", "15 GB Compute v1", 15360, 0, 8),
    "compute1-30": Flavor("compute1-30", "30 GB Compute v1", 30720, 0, 16),
    "compute1-4": Flavor("compute1-4", "3.75 GB Compute v1", 3840, 0, 2),
    "compute1-60": Flavor("compute1-60", "60 GB Compute v1", 61440, 0, 32),
    "compute1-8": Flavor("compute1-8", "7.5 GB Compute v1", 7680, 0, 4),
    "general1-1": Flavor("general1-1", "1 GB General Purpose v1", 1024, 20, 1),
    "general1-2": Flavor("general1-2", "2 GB General Purpose v1", 2048, 40, 2),
    "general1-4": Flavor("general1-4", "4 GB General Purpose v1", 4096, 80, 4),
    "general1-8": Flavor("general1-8", "8 GB General Purpose v1", 8192, 160, 8),
    "io1-120": Flavor("io1-120", "120 GB I/O v1", 122880, 40, 32),
    "io1-15": Flavor("io1-15", "15 GB I/O v1", 15360, 40, 4),
    "io1-30": Flavor("io1-30", "30 GB I/O v1", 30720, 40, 8),
    "io1-60": Flavor("io1-60", "60 GB I/O v1", 61440, 40, 16),
    "io1-90": Flavor("io1-90", "90 GB I/O v1", 92160, 40, 24),
    "memory1-120": Flavor("memory1-120", "120 GB Memory v1", 122880, 0, 16),
    "memory1-15": Flavor("memory1-15", "15 GB Memory v1", 15360, 0, 2),
    "memory1-240": Flavor("memory1-240", "240 GB Memory v1", 245760, 0, 32),
    "memory1-30": Flavor("memory1-30", "30 GB Memory v1", 30720, 0, 4),
    "memory1-60": Flavor("memory1-60", "60 GB Memory v1", 61440, 0, 8),
    "onmetal-general2-large": Flavor("onmetal-general2-large", "OnMetal General Purpose v2 Large", 131072, 800, 24),
    "onmetal-general2-medium": Flavor("onmetal-general2-medium", "OnMetal General Purpose v2 Medium", 65536, 800, 24),
    "onmetal-general2-small": Flavor("onmetal-general2-small", "OnMetal General Purpose v2 Small", 32768, 800, 12),
    "onmetal-io2": Flavor("onmetal-io2", "OnMetal I/O v2", 131072, 240, 40),
    "performance1-1": Flavor("performance1-1", "1 GB Performance", 1024, 20, 1),
    "performance1-2": Flavor("performance1-2", "2 GB Performance", 2048, 40, 2),
    "performance1-4": Flavor("performance1-4", "4 GB Performance", 4096, 40, 4),
    "performance1-8": Flavor("performance1-8", "8 GB Performance", 8192, 40, 8),
    "performance2-120": Flavor("performance2-120", "120 GB Performance", 122880, 40, 32),
    "performance2-15": Flavor("performance2-15", "15 GB Performance", 15360, 40, 4),
    "performance2-30": Flavor("performance2-30", "30 GB Performance", 30720, 40, 8),
    "performance2-60": Flavor("performance2-60", "60 GB Performance", 61440, 40, 16),
    "performance2-90": Flavor("performance2-90", "90 GB Performance", 92160, 40, 24),
}


DEFAULT_TARGET_FLAVORS: List[Flavor] = [
    Flavor("03acf2b1-631f-40e0-bb94-994d3eca2b58", "mo.6.2.16", 16384, 80, 2),
    Flavor("05d771d6-a4c2-48e8-9c28-c7a029cdeb94", "gp.5.2.6", 6144, 40, 2),
    Flavor("06aba8cf-7181-4d70-be1d-2a46e8c46f22", "gp.5.2.8", 8192, 40, 2),
    Flavor("109b073d-f085-451f-88e6-10b73fa23197", "mo.6.4.32", 32768, 80, 4),
    Flavor("13a531a8-11ae-40e9-9910-f63de0d42faa", "mo.6.4.20", 20480, 80, 4),
    Flavor("1ba37c74-34c1-47f8-965b-c5005c3825d2", "gp.5.4.4", 4096, 80, 4),
    Flavor("1ed24200-5d11-4fde-814d-6b2c2449b313", "gp.5.32.128", 131072, 240, 32),
    Flavor("40d4958a-56d9-4c8e-ae8b-3e5072398739", "gp.5.24.96", 98304, 240, 24),
    Flavor("6bc9e614-d561-477c-a0e2-9122b115789d", "gp.5.1.2", 2048, 0, 1),
    Flavor("6bdc8ea7-c5ee-41ea-9d0f-3c56eec58a17", "mo.6.4.24", 24576, 80, 4),
    Flavor("7d1b2ff0-c0cb-4241-bc4f-fece811d6cb1", "gp.5.48.192", 196608, 240, 48),
    Flavor("813056ca-3e63-4db4-9833-64a8019688e5", "gp.5.16.64", 65536, 240, 16),
    Flavor("a78521e3-903a-4124-a844-35893a4b639e", "gp.5.4.16", 16384, 80, 4),
    Flavor("b5ccd490-b138-4d81-b8c3-c074287708e8", "gp.5.2.4", 4096, 40, 2),
    Flavor("bde423c4-dd71-4710-901d-11905d22229d", "mo.6.2.12", 12288, 80, 2),
    Flavor("c2e4f7c5-26ef-49ca-a121-97e0193304c1", "gp.5.4.8", 8192, 80, 4),
    Flavor("c85a20aa-30ee-40ba-8724-51f4860acc7d", "gp.5.1.4", 4096, 10, 1),
    Flavor("d00a18da-865b-4b89-9036-ed1736d54649", "gp.5.8.16", 16384, 160, 8),
    Flavor("d3a4a3f8-1aa3-4f9e-b08d-9081bb8aea08", "gp.5.2.2", 2048, 40, 2),
    Flavor("dbd37462-133a-4177-b1f1-56e5a773a027", "gp.5.8.24", 24576, 160, 8),
    Flavor("e3c7bac5-0652-4122-8597-8eebf7143bb4", "mo.6.8.64", 65536, 80, 8),
    Flavor("f2e07e6c-20b0-4ffd-92ad-dbafb9fe86fb", "gp.5.4.12", 12288, 80, 4),
    Flavor("fa77d19e-cd7f-4eee-9222-a5680a58834b", "gp.5.8.32", 32768, 160, 8),
]


DEFAULT_TARGET_HOURLY_RATES_USD: Dict[str, float] = {
    "gp.5.1.2": 0.0200,
    "gp.5.1.4": 0.0320,
    "gp.5.2.2": 0.0390,
    "gp.5.2.4": 0.0490,
    "gp.5.2.6": 0.0590,
    "gp.5.2.8": 0.0700,
    "gp.5.4.4": 0.0860,
    "mo.6.2.12": 0.0990,
    "gp.5.4.8": 0.1060,
    "mo.6.2.16": 0.1200,
    "gp.5.4.12": 0.1260,
    "gp.5.4.16": 0.1470,
    "mo.6.4.20": 0.1590,
    "mo.6.4.24": 0.1800,
    "gp.5.8.16": 0.2120,
    "mo.6.4.32": 0.2210,
    "gp.5.8.24": 0.2530,
    "gp.5.8.32": 0.2940,
    "mo.6.8.64": 0.4230,
    "gp.5.16.64": 0.5530,
    "gp.5.24.96": 0.7940,
    "gp.5.32.128": 1.0340,
    "gp.5.48.192": 1.5150,
}


def infer_account_id_from_filename(path: Path) -> str:
    stem = path.stem
    m = re.match(r"^(\d+)_", stem)
    if m:
        return m.group(1)
    return stem


def first_nonempty(row: Dict[str, str], keys: List[str]) -> str:
    for key in keys:
        value = row.get(key)
        if value is not None and str(value).strip() != "":
            return str(value).strip()
    return ""


def normalize_row_keys(row: Dict[str, str]) -> Dict[str, str]:
    normalized: Dict[str, str] = {}
    for key, value in row.items():
        k = (key or "").strip().lstrip("\ufeff").strip('"').strip("'").lower()
        normalized[k] = value
    return normalized


def parse_number(value: str) -> float:
    text = (value or "").strip()
    if not text:
        return 0.0
    cleaned = re.sub(r"[^0-9.\-]", "", text)
    try:
        return float(cleaned) if cleaned else 0.0
    except ValueError:
        return 0.0


def parse_memory_to_mb(value: str) -> int:
    text = (value or "").strip().lower()
    if not text:
        return 0
    n = parse_number(text)
    if "gib" in text or "gb" in text:
        return int(n * 1024)
    return int(n)


def to_int(value: str) -> int:
    try:
        return int(float((value or "").strip()))
    except ValueError:
        return 0


def load_target_flavor_catalog(path: Path, target_region: str) -> Tuple[List[Flavor], Dict[str, float]]:
    with path.open(newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))

    flavors: List[Flavor] = []
    hourly_rates: Dict[str, float] = {}
    region_filter = (target_region or "").strip().upper()

    for raw_row in rows:
        row = normalize_row_keys(raw_row)
        row_region = first_nonempty(row, ["region", "target_region", "deployment_region"]).upper()
        if region_filter and row_region and row_region != region_filter:
            continue

        flavor_id = first_nonempty(row, ["flavor_id", "target_flavor_id", "id"])
        name = first_nonempty(row, ["name", "flavor_name", "target_flavor_name"])
        ram_mb_raw = first_nonempty(row, ["ram_mb", "ram", "memory_mb", "memory"])
        ram_mb = parse_memory_to_mb(ram_mb_raw)
        disk_gb = to_int(first_nonempty(row, ["disk_gb", "disk", "root_disk_gb", "disk (gib)", "disk (gb)"]))
        vcpus = to_int(first_nonempty(row, ["vcpus", "vcpu", "cpu"]))

        if not flavor_id or not name or ram_mb <= 0 or vcpus <= 0:
            continue

        flavors.append(Flavor(flavor_id, name, ram_mb, disk_gb, vcpus))

        rate_raw = first_nonempty(
            row,
            ["target_hourly_rate_usd", "hourly_rate_usd", "hourly_rate", "price_per_hour_usd", "cost per hour"],
        )
        if rate_raw:
            rate = parse_number(rate_raw)
            if rate > 0:
                hourly_rates[name] = rate

    if not flavors:
        raise ValueError(
            "No usable target flavors found in catalog CSV. "
            "Expected columns like flavor_id/name/ram_mb/vcpus/disk_gb."
        )

    return flavors, hourly_rates


def extract_major_version(text: str) -> int:
    m = re.search(r"(\d+)", text or "")
    return int(m.group(1)) if m else 0


def recommend_target_image_name(row: Dict[str, str]) -> Tuple[str, str]:
    distro = (row.get("image_os_distro") or "").strip().lower()
    version = (row.get("image_os_version") or "").strip().lower()
    image_name = (row.get("image_name") or "").strip().lower()
    text = " ".join([distro, version, image_name]).strip()

    if not text:
        return "", "no_source_os_data"

    if "windows" in text:
        if "sql" in text and "web" in text:
            if "2016" in text:
                return "Windows Server 2016 with SQL 2016 Web", "windows_sql_web_nearest"
            if "2019" in text:
                return "Windows Server 2019 with SQL 2019 Web", "windows_sql_web_nearest"
            if "2025" in text:
                return "Windows Server 2025 with SQL 2022 Web", "windows_sql_web_nearest"
            return "Windows Server 2022 with SQL 2022 Web", "windows_sql_web_nearest"
        if "sql" in text and "std" in text:
            if "2016" in text:
                return "Windows Server 2016 with SQL 2016 Std", "windows_sql_std_nearest"
            if "2019" in text:
                return "Windows Server 2019 with SQL 2019 Std", "windows_sql_std_nearest"
            if "2025" in text and "sql 2025" in text:
                return "Windows Server 2025 with SQL 2025 Std", "windows_sql_std_nearest"
            if "2025" in text:
                return "Windows Server 2025 with SQL 2022 Std", "windows_sql_std_nearest"
            return "Windows Server 2022 with SQL 2022 Std", "windows_sql_std_nearest"
        yr = extract_major_version(text)
        if yr and yr <= 2016:
            return "Windows Server 2016", "windows_nearest"
        if yr and yr <= 2019:
            return "Windows Server 2019", "windows_nearest"
        if yr and yr <= 2022:
            return "Windows Server 2022", "windows_nearest"
        return "Windows Server 2025", "windows_nearest"

    if "ubuntu" in text:
        major = extract_major_version(version or text)
        if major <= 20:
            return "Ubuntu 20.04", "ubuntu_nearest"
        if major <= 22:
            return "Ubuntu 22.04", "ubuntu_nearest"
        return "Ubuntu 24.04", "ubuntu_nearest"

    if "debian" in text:
        major = extract_major_version(version or text)
        return ("Debian 11", "debian_nearest") if major <= 11 else ("Debian 12", "debian_nearest")

    if "centos" in text:
        major = extract_major_version(version or text)
        return ("Rocky Linux 8", "centos_to_rocky") if major <= 8 else ("Rocky Linux 9", "centos_to_rocky")

    if "rocky" in text:
        major = extract_major_version(version or text)
        return ("Rocky Linux 8", "rocky_nearest") if major <= 8 else ("Rocky Linux 9", "rocky_nearest")

    if "alma" in text:
        major = extract_major_version(version or text)
        return ("AlmaLinux 8", "alma_nearest") if major <= 8 else ("AlmaLinux 9", "alma_nearest")

    if "oracle" in text:
        major = extract_major_version(version or text)
        return ("Oracle Linux 8", "oracle_nearest") if major <= 8 else ("Oracle Linux 9", "oracle_nearest")

    if "red hat" in text or "rhel" in text:
        major = extract_major_version(version or text)
        return ("Red Hat Enterprise Linux 8", "rhel_nearest") if major <= 8 else ("Red Hat Enterprise Linux 9", "rhel_nearest")

    if "fedora-coreos" in text:
        return ("magnum-fedora-coreos-40", "fedora_coreos_nearest") if "magnum" in text else ("fedora-coreos-40", "fedora_coreos_nearest")

    if "linux" in text:
        return "Ubuntu 22.04", "generic_linux_fallback"

    return "", "no_recommendation"


def score_candidate(source: Flavor, target: Flavor) -> Tuple[float, bool, str]:
    """Score how well a target flavor fits the source.
    Lower = better.  Downsizing is heavily penalised so it only wins when
    nothing bigger exists at all.
    """
    cpu_ratio = target.vcpus / source.vcpus if source.vcpus else 999
    ram_ratio = target.ram_mb / source.ram_mb if source.ram_mb else 999

    if source.disk_gb > 0:
        disk_gap = abs(target.disk_gb - source.disk_gb) / source.disk_gb
        disk_shortfall = max(source.disk_gb - target.disk_gb, 0)
    else:
        disk_gap = 0.0
        disk_shortfall = 0

    # Base score: prefer closest match
    score = (0.60 * abs(cpu_ratio - 1.0)) + (0.35 * abs(ram_ratio - 1.0)) + (0.05 * disk_gap)

    downsized = False
    notes: List[str] = []
    if target.vcpus < source.vcpus:
        downsized = True
        score += 8.0 + 2.0 * (source.vcpus - target.vcpus) / source.vcpus
        notes.append("cpu_downsize")
    if target.ram_mb < source.ram_mb:
        downsized = True
        score += 8.0 + 2.0 * (source.ram_mb - target.ram_mb) / source.ram_mb
        notes.append("ram_downsize")
    if disk_shortfall > 0:
        score += 1.5 * (disk_shortfall / source.disk_gb)
        notes.append(f"disk_shortfall={disk_shortfall}GB")
    # Small penalty for excessive oversize (don't jump 4x when 2x is available)
    if cpu_ratio > 2.0:
        score += 0.20 * (cpu_ratio - 2.0)
        notes.append("cpu_oversize_gt_2x")
    if ram_ratio > 2.0:
        score += 0.20 * (ram_ratio - 2.0)
        notes.append("ram_oversize_gt_2x")
    return score, downsized, ";".join(notes)


def rank_candidates(source: Flavor, target_flavors: List[Flavor]) -> List[Tuple[Flavor, float, bool, str]]:
    """Return target flavors ranked best-first.

    Priority order (guarantees we never downsize when a bigger option exists):
      1. Exact match (all three dimensions equal).
      2. Smallest flavor that is >= source on vCPUs, RAM *and* disk.
      3. Smallest flavor that is >= source on vCPUs and RAM (disk covered by Cinder).
      4. Fall back to lowest penalty score (rare – only when catalog is tiny).
    """
    # ── Tier 1: exact match ───────────────────────────────────────────────────
    exact = [
        f for f in target_flavors
        if f.vcpus == source.vcpus
        and f.ram_mb == source.ram_mb
        and (source.disk_gb == 0 or f.disk_gb == source.disk_gb)
    ]
    if exact:
        ranked_exact = sorted(exact, key=lambda f: (f.ram_mb, f.vcpus, f.disk_gb, f.name))
        result = [(f, 0.0, False, "exact") for f in ranked_exact]
        # Append the rest as alternatives
        rest = [f for f in target_flavors if f not in exact]
        for f in rest:
            s, d, n = score_candidate(source, f)
            result.append((f, s, d, n))
        return result

    # ── Tier 2: all-dimensions upsell (vcpus >= AND ram >= AND disk >=) ──────
    upsell_all = [
        f for f in target_flavors
        if f.vcpus >= source.vcpus
        and f.ram_mb >= source.ram_mb
        and (source.disk_gb == 0 or f.disk_gb >= source.disk_gb)
    ]
    if upsell_all:
        # Pick the smallest qualifying flavor (fewest resources = cheapest)
        ranked_up = sorted(upsell_all, key=lambda f: (f.ram_mb, f.vcpus, f.disk_gb, f.name))
        result = [(ranked_up[0], 0.0, False, "next_up_all")]
        for f in ranked_up[1:]:
            s, d, n = score_candidate(source, f)
            result.append((f, s, d, "next_up_all;" + n))
        # Tack on downsize candidates at the end as emergency alternatives
        rest = [f for f in target_flavors if f not in upsell_all]
        for f in rest:
            s, d, n = score_candidate(source, f)
            result.append((f, s, d, n))
        return result

    # ── Tier 3: compute-only upsell (vcpus >= AND ram >=, disk via Cinder) ───
    upsell_compute = [
        f for f in target_flavors
        if f.vcpus >= source.vcpus
        and f.ram_mb >= source.ram_mb
    ]
    if upsell_compute:
        ranked_up = sorted(upsell_compute, key=lambda f: (f.ram_mb, f.vcpus, f.disk_gb, f.name))
        result = [(ranked_up[0], 0.0, False, "next_up_compute")]
        for f in ranked_up[1:]:
            s, d, n = score_candidate(source, f)
            result.append((f, s, d, "next_up_compute;" + n))
        rest = [f for f in target_flavors if f not in upsell_compute]
        for f in rest:
            s, d, n = score_candidate(source, f)
            result.append((f, s, d, n))
        return result

    # ── Tier 4: nothing larger exists — use best scored (downsize disclosed) ──
    scored = [(f,) + score_candidate(source, f) for f in target_flavors]
    scored.sort(key=lambda item: item[1])
    return [(f, s, d, "scored_best_no_upsell;" + n) for f, s, d, n in scored]


def parse_attachments(raw: str) -> List[Dict[str, str]]:
    text = (raw or "").strip()
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


def normalize_device_path(device: str) -> str:
    d = (device or "").strip()
    if d.startswith("/dev/xvd"):
        return "/dev/vd" + d[len("/dev/xvd"):]
    return d


def split_ip_values(raw: str) -> List[str]:
    text = (raw or "").strip()
    if not text:
        return []
    out: List[str] = []
    for part in re.split(r"[;, \t\r\n]+", text):
        p = part.strip()
        if p:
            out.append(p)
    return out


def safe_json_loads(text: str) -> Dict:
    try:
        data = json.loads(text or "")
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def load_ip_to_server_index(server_rows: List[Dict[str, str]]) -> Dict[str, List[Dict[str, str]]]:
    index: Dict[str, List[Dict[str, str]]] = {}
    for row in server_rows:
        server_id = (row.get("resource_id") or "").strip()
        server_name = (row.get("name") or "").strip()
        region = (row.get("region") or "").strip()
        private_ips = split_ip_values(row.get("private_ips") or "")
        for ip in private_ips:
            index.setdefault(ip, []).append(
                {
                    "server_id": server_id,
                    "server_name": server_name,
                    "region": region,
                }
            )
    return index


def build_load_balancer_mapping_rows(
    rows: List[Dict[str, str]],
    server_rows: List[Dict[str, str]],
) -> List[Dict[str, str]]:
    lb_rows = [r for r in rows if (r.get("service_type") or "").strip() == "load_balancer"]
    ip_index = load_ip_to_server_index(server_rows)
    out_rows: List[Dict[str, str]] = []

    for lb in lb_rows:
        lb_id = (lb.get("resource_id") or "").strip()
        lb_name = (lb.get("name") or "").strip()
        lb_region = (lb.get("region") or "").strip()
        lb_status = (lb.get("status") or "").strip()
        lb_protocol = ((lb.get("protocol") or "").strip() or "HTTP").upper()
        details = safe_json_loads(lb.get("details_json") or "")
        lb_obj = details.get("loadBalancer", {}) if isinstance(details, dict) else {}
        if not isinstance(lb_obj, dict):
            lb_obj = {}

        listener_port = str(lb_obj.get("port") or "")
        if not listener_port:
            listener_port = "80" if lb_protocol in {"HTTP", "HTTPS"} else "443"

        pool_algorithm = str(lb_obj.get("algorithm") or lb_obj.get("algorithmType") or "").strip().upper() or "ROUND_ROBIN"
        provider = "amphora"

        hm = lb_obj.get("healthMonitor", {})
        if not isinstance(hm, dict):
            hm = {}
        hm_type = str(hm.get("type") or "").strip().upper()
        hm_delay = str(hm.get("delay") or "").strip()
        hm_timeout = str(hm.get("timeout") or "").strip()
        hm_attempts = str(hm.get("attemptsBeforeDeactivation") or hm.get("max_retries") or "").strip()

        vip_public = []
        vip_private = []
        for vip in lb_obj.get("virtualIps", []) if isinstance(lb_obj.get("virtualIps"), list) else []:
            if not isinstance(vip, dict):
                continue
            vip_ip = str(vip.get("address") or "").strip()
            vip_type = str(vip.get("type") or "").strip().upper()
            if not vip_ip:
                continue
            if vip_type == "PUBLIC":
                vip_public.append(vip_ip)
            elif vip_type in {"SERVICENET", "PRIVATE"}:
                vip_private.append(vip_ip)
            else:
                vip_public.append(vip_ip)

        nodes = lb_obj.get("nodes", [])
        if not isinstance(nodes, list):
            nodes = []

        if not nodes:
            out_rows.append(
                {
                    "region": lb_region,
                    "load_balancer_id": lb_id,
                    "load_balancer_name": lb_name,
                    "load_balancer_status": lb_status,
                    "provider": provider,
                    "target_protocol": lb_protocol,
                    "listener_port": listener_port,
                    "member_port": listener_port,
                    "pool_algorithm": pool_algorithm,
                    "health_monitor_type": hm_type,
                    "health_monitor_delay": hm_delay,
                    "health_monitor_timeout": hm_timeout,
                    "health_monitor_attempts": hm_attempts,
                    "vip_public_ips": ";".join(vip_public),
                    "vip_private_ips": ";".join(vip_private),
                    "source_member_ip": "",
                    "source_member_port": "",
                    "source_member_condition": "",
                    "source_member_status": "",
                    "source_server_id": "",
                    "source_server_name": "",
                    "target_server_name": "",
                    "member_include_in_deploy": "no",
                    "member_match_note": "no_nodes_in_source_lb",
                }
            )
            continue

        for node in nodes:
            if not isinstance(node, dict):
                continue
            source_member_ip = str(node.get("address") or node.get("ipAddress") or "").strip()
            source_member_port = str(node.get("port") or listener_port).strip()
            source_member_condition = str(node.get("condition") or "").strip()
            source_member_status = str(node.get("status") or "").strip()

            matches = ip_index.get(source_member_ip, []) if source_member_ip else []
            source_server_id = ""
            source_server_name = ""
            target_server_name = ""
            member_include = "no"
            match_note = "no_private_ip_match"

            if len(matches) == 1:
                match = matches[0]
                source_server_id = match.get("server_id", "")
                source_server_name = match.get("server_name", "")
                target_server_name = source_server_name
                member_include = "yes"
                match_note = "exact_private_ip_match"
            elif len(matches) > 1:
                match = matches[0]
                source_server_id = match.get("server_id", "")
                source_server_name = match.get("server_name", "")
                target_server_name = source_server_name
                member_include = "yes"
                match_note = "multiple_private_ip_matches_using_first"

            out_rows.append(
                {
                    "region": lb_region,
                    "load_balancer_id": lb_id,
                    "load_balancer_name": lb_name,
                    "load_balancer_status": lb_status,
                    "provider": provider,
                    "target_protocol": lb_protocol,
                    "listener_port": listener_port,
                    "member_port": source_member_port or listener_port,
                    "pool_algorithm": pool_algorithm,
                    "health_monitor_type": hm_type,
                    "health_monitor_delay": hm_delay,
                    "health_monitor_timeout": hm_timeout,
                    "health_monitor_attempts": hm_attempts,
                    "vip_public_ips": ";".join(vip_public),
                    "vip_private_ips": ";".join(vip_private),
                    "source_member_ip": source_member_ip,
                    "source_member_port": source_member_port,
                    "source_member_condition": source_member_condition,
                    "source_member_status": source_member_status,
                    "source_server_id": source_server_id,
                    "source_server_name": source_server_name,
                    "target_server_name": target_server_name,
                    "member_include_in_deploy": member_include,
                    "member_match_note": match_note,
                }
            )

    return out_rows


def load_volume_attachments(account_overview_path: Optional[str]) -> Dict[str, List[Dict[str, str]]]:
    by_server: Dict[str, List[Dict[str, str]]] = {}
    if not account_overview_path:
        return by_server

    with open(account_overview_path, newline="", encoding="utf-8") as infile:
        rows = list(csv.DictReader(infile))

    for row in rows:
        if row.get("service_type") != "block_storage_volume":
            continue
        if (row.get("status") or "").lower() != "in-use":
            continue

        volume_id = (row.get("resource_id") or "").strip()
        volume_name = (row.get("name") or "").strip()
        size_gb_raw = (row.get("size_gb") or "").strip()
        volume_image_name = (row.get("image_name") or "").strip()
        volume_image_os_distro = (row.get("image_os_distro") or "").strip()
        volume_image_os_version = (row.get("image_os_version") or "").strip()
        volume_image_os_type = (row.get("image_os_type") or "").strip()
        volume_image_release_id = (row.get("image_release_id") or "").strip()
        try:
            size_gb = int(float(size_gb_raw)) if size_gb_raw else 0
        except ValueError:
            size_gb = 0

        attachments = parse_attachments(row.get("attachments") or "")
        for a in attachments:
            server_id = str(a.get("server_id") or a.get("serverId") or a.get("server") or "").strip()
            device_source = str(a.get("device") or "").strip()
            if not server_id:
                continue
            rec = {
                "source_volume_id": volume_id,
                "source_volume_name": volume_name,
                "size_gb": size_gb,
                "device_source": device_source,
                "device_target": normalize_device_path(device_source),
                "source_image_name": volume_image_name,
                "source_image_os_distro": volume_image_os_distro,
                "source_image_os_version": volume_image_os_version,
                "source_image_os_type": volume_image_os_type,
                "source_image_release_id": volume_image_release_id,
            }
            by_server.setdefault(server_id, []).append(rec)

    return by_server


def choose_boot_volume(server_vols: List[Dict[str, str]]) -> Optional[Dict[str, str]]:
    boot_candidates = [
        v for v in server_vols
        if (v.get("device_source") or "").lower() in {"/dev/xvda", "/dev/vda"}
    ]
    if not boot_candidates:
        return None
    return sorted(boot_candidates, key=lambda v: int(v.get("size_gb") or 0), reverse=True)[0]


def resolve_source_image_hints(server_row: Dict[str, str], boot_vol: Optional[Dict[str, str]]) -> Tuple[Dict[str, str], str]:
    server_hints = {
        "image_name": (server_row.get("image_name") or "").strip(),
        "image_os_distro": (server_row.get("image_os_distro") or "").strip(),
        "image_os_version": (server_row.get("image_os_version") or "").strip(),
        "image_os_type": (server_row.get("image_os_type") or "").strip(),
        "image_release_id": (server_row.get("image_release_id") or "").strip(),
    }
    if any(server_hints.values()):
        return server_hints, "server_image_metadata"

    if boot_vol:
        boot_hints = {
            "image_name": (boot_vol.get("source_image_name") or "").strip(),
            "image_os_distro": (boot_vol.get("source_image_os_distro") or "").strip(),
            "image_os_version": (boot_vol.get("source_image_os_version") or "").strip(),
            "image_os_type": (boot_vol.get("source_image_os_type") or "").strip(),
            "image_release_id": (boot_vol.get("source_image_release_id") or "").strip(),
        }
        if any(boot_hints.values()):
            return boot_hints, "boot_volume_image_metadata"

    return server_hints, "no_source_os_data"


def recommend_database_target_image_name(row: Dict[str, str]) -> Tuple[str, str]:
    datastore = (row.get("datastore_type") or "").strip().lower()
    if datastore in {"sqlserver", "mssql"}:
        return "Windows Server 2022 with SQL 2022 Std", "db_instance_sqlserver_to_windows_sql"
    return "Ubuntu 22.04", "db_instance_to_linux_server"


def rank_db_conversion_candidates(size_gb: int, target_flavors: List[Flavor]) -> List[Tuple[Flavor, str]]:
    if not target_flavors:
        return []
    local_disk_flavors = [f for f in target_flavors if f.disk_gb > 0]
    candidate_pool = local_disk_flavors if local_disk_flavors else target_flavors
    # Prefer disk-fit candidates first. Within the same RAM class, prefer larger
    # local disk to satisfy DB storage needs more safely.
    fits = [f for f in candidate_pool if size_gb <= 0 or f.disk_gb >= size_gb]
    if fits:
        ranked = sorted(fits, key=lambda f: (f.ram_mb, -f.disk_gb, f.vcpus, f.name))
        return [(f, "disk_fit") for f in ranked]

    ranked = sorted(candidate_pool, key=lambda f: (-f.disk_gb, f.ram_mb, f.vcpus, f.name))
    if local_disk_flavors:
        return [(f, "no_disk_fit_largest_local_disk") for f in ranked]
    return [(f, "no_local_disk_flavors_region_fallback") for f in ranked]


def map_inventory(
    inventory_path: str,
    output_path: str,
    account_overview_path: Optional[str],
    block_output_path: Optional[str] = None,
    lb_output_path: Optional[str] = None,
    include_database_instances_as_servers: bool = False,
    include_floating_ips: bool = True,
    target_region: str = "",
    target_flavor_catalog_path: str = "",
) -> Tuple[int, float, float, str, str]:
    with open(inventory_path, newline="", encoding="utf-8") as infile:
        rows = list(csv.DictReader(infile))

    server_rows = [r for r in rows if r.get("service_type") == "cloud_server"]
    db_instance_rows = [r for r in rows if r.get("service_type") == "database_instance"]
    if not server_rows and not (include_database_instances_as_servers and db_instance_rows):
        raise ValueError(
            "No rows with service_type=cloud_server found in inventory CSV. "
            "Use --include-database-instances-as-servers to map database_instance rows."
        )

    volumes_by_server = load_volume_attachments(account_overview_path)
    selected_target_region = (target_region or "").strip().upper()
    if target_flavor_catalog_path:
        target_flavors, target_hourly_rates = load_target_flavor_catalog(Path(target_flavor_catalog_path).expanduser(), selected_target_region)
    else:
        target_flavors = DEFAULT_TARGET_FLAVORS
        target_hourly_rates = DEFAULT_TARGET_HOURLY_RATES_USD

    out_rows = []
    block_storage_rows = []
    lb_mapping_rows = build_load_balancer_mapping_rows(rows, server_rows)
    priced_row_count = 0
    total_daily_min = 0.0
    total_monthly_min = 0.0

    for row in server_rows:
        source_flavor_id = (row.get("flavor_id") or "").strip()
        source_flavor_key = source_flavor_id.lower()
        region = (row.get("region") or "").strip()
        server_name = (row.get("name") or "").strip()
        server_id = (row.get("resource_id") or "").strip()
        public_ips = (row.get("public_ips") or "").strip()
        needs_floating_ip = "yes" if include_floating_ips else "no"
        floating_network = "PUBLICNET" if include_floating_ips else ""

        source = SOURCE_FLAVORS.get(source_flavor_key)
        if not source:
            out_rows.append({
                "source_resource_type": "cloud_server",
                "region": region,
                "target_region": selected_target_region,
                "server_name": server_name,
                "target_server_name": server_name,
                "server_id": server_id,
                "include_in_deploy": "yes",
                "source_flavor_id": source_flavor_id,
                "source_flavor_name": "",
                "source_ram_mb": "",
                "source_vcpus": "",
                "source_disk_gb": "",
                "source_image_name": (row.get("image_name") or "").strip(),
                "source_image_os_distro": (row.get("image_os_distro") or "").strip(),
                "source_image_os_version": (row.get("image_os_version") or "").strip(),
                "target_flavor_id": "",
                "target_flavor_name": "",
                "target_ram_mb": "",
                "target_vcpus": "",
                "target_disk_gb": "",
                "target_hourly_rate_usd": "",
                "target_daily_cost_min_usd": "",
                "target_monthly_cost_min_usd": "",
                "recommended_target_image_name": "",
                "image_recommendation_note": "",
                "boot_volume_source_size_gb": "",
                "boot_volume_source_device": "",
                "boot_volume_target_device": "",
                "needs_floating_ip": needs_floating_ip,
                "floating_network": floating_network,
                "boot_strategy": "unknown_source_flavor",
                "boot_from_volume_size_gb": "",
                "attached_data_volumes_count": "",
                "conversion_note": "",
                "alt_1": "",
                "alt_2": "",
                "alt_3": "",
            })
            continue

        attached_vols = volumes_by_server.get(server_id, [])
        boot_vol = choose_boot_volume(attached_vols)
        data_vols = [v for v in attached_vols if v is not boot_vol]
        image_hints, image_hint_source = resolve_source_image_hints(row, boot_vol)
        recommended_image_name, image_note = recommend_target_image_name(image_hints)
        if image_hint_source == "boot_volume_image_metadata" and image_note and image_note not in {"no_source_os_data", "no_recommendation"}:
            image_note = f"{image_note};boot_volume_metadata_fallback"

        min_ram_mb = 0
        if "Windows" in recommended_image_name:
            min_ram_mb = 4096

        valid_flavors = [f for f in target_flavors if f.ram_mb >= min_ram_mb]
        if not valid_flavors:
            valid_flavors = target_flavors

        ranked = rank_candidates(source, valid_flavors)
        target, _, _, _ = ranked[0]
        alts = ranked[1:4]
        hourly = target_hourly_rates.get(target.name)
        if hourly is not None:
            daily = hourly * 24
            monthly = daily * 30
            priced_row_count += 1
            total_daily_min += daily
            total_monthly_min += monthly
            hourly_s = f"{hourly:.4f}"
            daily_s = f"{daily:.2f}"
            monthly_s = f"{monthly:.2f}"
        else:
            hourly_s = ""
            daily_s = ""
            monthly_s = ""

        if boot_vol:
            boot_size = int(boot_vol.get("size_gb") or 0)
            boot_source_device = boot_vol.get("device_source") or "/dev/xvda"
            boot_target_device = boot_vol.get("device_target") or "/dev/vda"
            if boot_size > target.disk_gb:
                boot_strategy = "boot_from_volume"
                boot_from_volume_size = str(boot_size)
            else:
                boot_strategy = "local_boot_use_flavor_disk"
                boot_from_volume_size = ""
        else:
            boot_size = 0
            boot_source_device = ""
            boot_target_device = ""
            if target.disk_gb == 0:
                boot_strategy = "boot_from_volume_required_by_target_flavor"
                boot_from_volume_size = ""
            else:
                boot_strategy = "local_boot_no_source_boot_volume"
                boot_from_volume_size = ""

        out_rows.append({
            "source_resource_type": "cloud_server",
            "region": region,
            "target_region": selected_target_region,
            "server_name": server_name,
            "target_server_name": server_name,
            "server_id": server_id,
            "include_in_deploy": "yes",
            "source_flavor_id": source.flavor_id,
            "source_flavor_name": source.name,
            "source_ram_mb": source.ram_mb,
            "source_vcpus": source.vcpus,
            "source_disk_gb": source.disk_gb,
            "source_image_name": image_hints.get("image_name", ""),
            "source_image_os_distro": image_hints.get("image_os_distro", ""),
            "source_image_os_version": image_hints.get("image_os_version", ""),
            "target_flavor_id": target.flavor_id,
            "target_flavor_name": target.name,
            "target_ram_mb": target.ram_mb,
            "target_vcpus": target.vcpus,
            "target_disk_gb": target.disk_gb,
            "target_hourly_rate_usd": hourly_s,
            "target_daily_cost_min_usd": daily_s,
            "target_monthly_cost_min_usd": monthly_s,
            "recommended_target_image_name": recommended_image_name,
            "image_recommendation_note": image_note,
            "boot_volume_source_size_gb": str(boot_size) if boot_size else "",
            "boot_volume_source_device": boot_source_device,
            "boot_volume_target_device": boot_target_device,
            "needs_floating_ip": needs_floating_ip,
            "floating_network": floating_network,
            "boot_strategy": boot_strategy,
            "boot_from_volume_size_gb": boot_from_volume_size,
            "attached_data_volumes_count": str(len(data_vols)),
            "conversion_note": "",
            "alt_1": f"{alts[0][0].name} ({alts[0][0].flavor_id}) score={alts[0][1]:.4f}" if len(alts) > 0 else "",
            "alt_2": f"{alts[1][0].name} ({alts[1][0].flavor_id}) score={alts[1][1]:.4f}" if len(alts) > 1 else "",
            "alt_3": f"{alts[2][0].name} ({alts[2][0].flavor_id}) score={alts[2][1]:.4f}" if len(alts) > 2 else "",
        })

        if boot_vol:
            block_storage_rows.append({
                "region": region,
                "source_server_id": server_id,
                "source_server_name": server_name,
                "target_server_name": server_name,
                "target_flavor_name": target.name,
                "source_volume_id": boot_vol.get("source_volume_id") or "",
                "source_volume_name": boot_vol.get("source_volume_name") or "",
                "volume_size_gb": boot_vol.get("size_gb") or "",
                "source_device_path": boot_vol.get("device_source") or "",
                "target_device_path": boot_vol.get("device_target") or "",
                "volume_role": "boot",
                "target_action": "boot_from_volume" if boot_strategy == "boot_from_volume" else "local_boot_use_flavor_disk",
                "boot_strategy": boot_strategy,
                "boot_from_volume_size_gb": boot_from_volume_size,
            })

        for dv in data_vols:
            block_storage_rows.append({
                "region": region,
                "source_server_id": server_id,
                "source_server_name": server_name,
                "target_server_name": server_name,
                "target_flavor_name": target.name,
                "source_volume_id": dv.get("source_volume_id") or "",
                "source_volume_name": dv.get("source_volume_name") or "",
                "volume_size_gb": dv.get("size_gb") or "",
                "source_device_path": dv.get("device_source") or "",
                "target_device_path": dv.get("device_target") or "",
                "volume_role": "data",
                "target_action": "create_and_attach_volume",
                "boot_strategy": "",
                "boot_from_volume_size_gb": "",
            })

    if include_database_instances_as_servers:
        for row in db_instance_rows:
            region = (row.get("region") or "").strip()
            db_name = (row.get("name") or "").strip()
            db_id = (row.get("resource_id") or "").strip()
            db_size_gb_raw = (row.get("size_gb") or "").strip()
            datastore_type = (row.get("datastore_type") or "").strip()
            datastore_version = (row.get("datastore_version") or "").strip()

            try:
                db_size_gb = int(float(db_size_gb_raw)) if db_size_gb_raw else 0
            except ValueError:
                db_size_gb = 0

            ranked_db = rank_db_conversion_candidates(db_size_gb, target_flavors)
            if not ranked_db:
                out_rows.append({
                    "source_resource_type": "database_instance",
                    "region": region,
                    "target_region": selected_target_region,
                    "server_name": db_name,
                    "target_server_name": db_name,
                    "server_id": db_id,
                    "include_in_deploy": "yes",
                    "source_flavor_id": "",
                    "source_flavor_name": "",
                    "source_ram_mb": "",
                    "source_vcpus": "",
                    "source_disk_gb": db_size_gb if db_size_gb > 0 else "",
                    "source_image_name": "",
                    "source_image_os_distro": "",
                    "source_image_os_version": "",
                    "target_flavor_id": "",
                    "target_flavor_name": "",
                    "target_ram_mb": "",
                    "target_vcpus": "",
                    "target_disk_gb": "",
                    "target_hourly_rate_usd": "",
                    "target_daily_cost_min_usd": "",
                    "target_monthly_cost_min_usd": "",
                    "recommended_target_image_name": "",
                    "image_recommendation_note": "db_instance_no_target_flavor_candidates",
                    "boot_volume_source_size_gb": "",
                    "boot_volume_source_device": "",
                    "boot_volume_target_device": "",
                    "needs_floating_ip": "no",
                    "floating_network": "",
                    "boot_strategy": "db_instance_no_target_flavor_candidates",
                    "boot_from_volume_size_gb": "",
                    "attached_data_volumes_count": "0",
                    "conversion_note": "db_to_server_conversion;no_target_flavor_candidates",
                    "alt_1": "",
                    "alt_2": "",
                    "alt_3": "",
                })
                continue
            target, selection_note = ranked_db[0]
            db_alts = ranked_db[1:4]
            recommended_image_name, image_note = recommend_database_target_image_name(row)

            hourly = target_hourly_rates.get(target.name)
            if hourly is not None:
                daily = hourly * 24
                monthly = daily * 30
                priced_row_count += 1
                total_daily_min += daily
                total_monthly_min += monthly
                hourly_s = f"{hourly:.4f}"
                daily_s = f"{daily:.2f}"
                monthly_s = f"{monthly:.2f}"
            else:
                hourly_s = ""
                daily_s = ""
                monthly_s = ""

            size_note = f"db_size_gb={db_size_gb}" if db_size_gb > 0 else "db_size_gb=unknown"
            datastore_note = f"datastore={datastore_type or 'unknown'}:{datastore_version or 'unknown'}"
            conversion_note = f"db_to_server_conversion;{selection_note};{size_note};{datastore_note}"

            out_rows.append({
                "source_resource_type": "database_instance",
                "region": region,
                "target_region": selected_target_region,
                "server_name": db_name,
                "target_server_name": db_name,
                "server_id": db_id,
                "include_in_deploy": "yes",
                "source_flavor_id": "",
                "source_flavor_name": "",
                "source_ram_mb": "",
                "source_vcpus": "",
                "source_disk_gb": db_size_gb if db_size_gb > 0 else "",
                "source_image_name": "",
                "source_image_os_distro": "",
                "source_image_os_version": "",
                "target_flavor_id": target.flavor_id,
                "target_flavor_name": target.name,
                "target_ram_mb": target.ram_mb,
                "target_vcpus": target.vcpus,
                "target_disk_gb": target.disk_gb,
                "target_hourly_rate_usd": hourly_s,
                "target_daily_cost_min_usd": daily_s,
                "target_monthly_cost_min_usd": monthly_s,
                "recommended_target_image_name": recommended_image_name,
                "image_recommendation_note": image_note,
                "boot_volume_source_size_gb": "",
                "boot_volume_source_device": "",
                "boot_volume_target_device": "",
                "needs_floating_ip": "no",
                "floating_network": "",
                "boot_strategy": "local_boot_use_flavor_disk",
                "boot_from_volume_size_gb": "",
                "attached_data_volumes_count": "0",
                "conversion_note": conversion_note,
                "alt_1": f"{db_alts[0][0].name} ({db_alts[0][0].flavor_id}) note={db_alts[0][1]}" if len(db_alts) > 0 else "",
                "alt_2": f"{db_alts[1][0].name} ({db_alts[1][0].flavor_id}) note={db_alts[1][1]}" if len(db_alts) > 1 else "",
                "alt_3": f"{db_alts[2][0].name} ({db_alts[2][0].flavor_id}) note={db_alts[2][1]}" if len(db_alts) > 2 else "",
            })

    main_fieldnames = [
        "source_resource_type",
        "region", "target_region", "server_name", "target_server_name", "server_id", "include_in_deploy", "source_flavor_id", "source_flavor_name",
        "source_ram_mb", "source_vcpus", "source_disk_gb",
        "source_image_name", "source_image_os_distro", "source_image_os_version",
        "target_flavor_id", "target_flavor_name", "target_ram_mb", "target_vcpus", "target_disk_gb",
        "target_hourly_rate_usd", "target_daily_cost_min_usd", "target_monthly_cost_min_usd",
        "recommended_target_image_name", "image_recommendation_note", "cloud_init_user_data",
        "boot_volume_source_size_gb", "boot_volume_source_device", "boot_volume_target_device",
        "needs_floating_ip", "floating_network",
        "boot_strategy", "boot_from_volume_size_gb", "attached_data_volumes_count", "conversion_note",
        "alt_1", "alt_2", "alt_3",
    ]

    with open(output_path, "w", newline="", encoding="utf-8") as outfile:
        writer = csv.DictWriter(outfile, fieldnames=main_fieldnames)
        writer.writeheader()
        writer.writerows(out_rows)

    if block_output_path:
        block_storage_path = block_output_path
    else:
        block_storage_path = str(Path(output_path).with_name(Path(output_path).stem + "_block_storage_mapping.csv"))
    block_fieldnames = [
        "region", "source_server_id", "source_server_name", "target_server_name", "target_flavor_name",
        "source_volume_id", "source_volume_name", "volume_size_gb",
        "source_device_path", "target_device_path", "volume_role", "target_action",
        "boot_strategy", "boot_from_volume_size_gb",
    ]
    with open(block_storage_path, "w", newline="", encoding="utf-8") as dvfile:
        writer = csv.DictWriter(dvfile, fieldnames=block_fieldnames)
        writer.writeheader()
        writer.writerows(block_storage_rows)
    if lb_output_path:
        lb_mapping_path = lb_output_path
    else:
        lb_mapping_path = str(Path(output_path).with_name(Path(output_path).stem + "_lb_mapping.csv"))
    lb_fieldnames = [
        "region",
        "load_balancer_id",
        "load_balancer_name",
        "load_balancer_status",
        "provider",
        "target_protocol",
        "listener_port",
        "member_port",
        "pool_algorithm",
        "health_monitor_type",
        "health_monitor_delay",
        "health_monitor_timeout",
        "health_monitor_attempts",
        "vip_public_ips",
        "vip_private_ips",
        "source_member_ip",
        "source_member_port",
        "source_member_condition",
        "source_member_status",
        "source_server_id",
        "source_server_name",
        "target_server_name",
        "member_include_in_deploy",
        "member_match_note",
    ]
    with open(lb_mapping_path, "w", newline="", encoding="utf-8") as lbfile:
        writer = csv.DictWriter(lbfile, fieldnames=lb_fieldnames)
        writer.writeheader()
        writer.writerows(lb_mapping_rows)

    return priced_row_count, total_daily_min, total_monthly_min, block_storage_path, lb_mapping_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Map Rackspace cloud server flavors to closest target platform flavors.")
    parser.add_argument("--inventory", required=False, help="Path to your exported inventory CSV.")
    parser.add_argument("--account-overview", default="", help="Optional account_overview CSV for block volume planning.")
    parser.add_argument("--output", default="", help="Path to write mapping CSV.")
    parser.add_argument("--block-output", default="", help="Path to write block storage mapping CSV.")
    parser.add_argument("--lb-output", default="", help="Path to write load balancer mapping CSV.")
    parser.add_argument("--target-region", default="", help="Target deployment region label (e.g., IAD, DFW).")
    parser.add_argument("--target-flavor-catalog", default="", help="CSV path containing target region flavor IDs/specs/costs.")
    parser.add_argument(
        "--include-database-instances-as-servers",
        action="store_true",
        help="Include database_instance rows from inventory as server rows in flavormap output (opt-in).",
    )
    parser.add_argument(
        "--no-include-floating-ips",
        action="store_true",
        help="Do not populate needs_floating_ip/floating_network defaults in flavormap output.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    inventory = (args.inventory or "").strip()
    if not inventory:
        inventory = input("Enter path to inventory CSV file: ").strip()

    inventory_path = Path(inventory).expanduser()
    if not inventory_path.exists():
        raise SystemExit(f"Inventory file not found: {inventory_path}")

    account_overview = (args.account_overview or "").strip()
    if account_overview:
        aop = Path(account_overview).expanduser()
        if not aop.exists():
            raise SystemExit(f"Account overview file not found: {aop}")
        account_overview_path: Optional[str] = str(aop)
    else:
        # Default to the same file provided via --inventory since it already
        # contains cloud_server + block_storage_volume rows from account_overview.py.
        account_overview_path = str(inventory_path)

    account_id = infer_account_id_from_filename(inventory_path)

    if args.output.strip():
        output_path = Path(args.output).expanduser()
    else:
        output_path = inventory_path.with_name(f"{account_id}_flavormap.csv")

    if args.block_output.strip():
        block_output_path = str(Path(args.block_output).expanduser())
    else:
        block_output_path = str(inventory_path.with_name(f"{account_id}_blockmap.csv"))
    if args.lb_output.strip():
        lb_output_path = str(Path(args.lb_output).expanduser())
    else:
        lb_output_path = str(inventory_path.with_name(f"{account_id}_lbmap.csv"))

    priced_rows, total_daily, total_monthly, block_storage_path, lb_mapping_path = map_inventory(
        str(inventory_path),
        str(output_path),
        account_overview_path,
        block_output_path,
        lb_output_path,
        args.include_database_instances_as_servers,
        not args.no_include_floating_ips,
        args.target_region,
        args.target_flavor_catalog,
    )

    print(f"Mapping complete: {output_path}")
    print(f"Block storage mapping: {block_storage_path}")
    print(f"Load balancer mapping: {lb_mapping_path}")
    print(
        "Minimum estimated cost for mapped server types "
        f"(priced rows: {priced_rows}): ${total_daily:.2f}/day, ${total_monthly:.2f}/month"
    )


if __name__ == "__main__":
    main()
