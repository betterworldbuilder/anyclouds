#!/usr/bin/env python3
"""
Shared OS profile hints for ospc2flex_offline_repair.sh --os-type
and routing to ospc2flex_windows_repair.sh (windows).

Used by:
  - ospc2flex_image_migrator.py (VM / remote-export pipeline)
  - ospc2flex_glance_image_migrator.py (Glance image pipeline)
"""
from __future__ import annotations

import re
from typing import Any, Dict, Optional


def infer_offline_os_type(
    *,
    name: str = "",
    os_id: str = "",
    os_ver: str = "",
    image_props: Optional[Dict[str, Any]] = None,
) -> str:
    """
    Return a token understood by ospc2flex_offline_repair.sh --os-type,
    or 'windows' to trigger VirtIO repair, or '' for auto-detect inside the script.
    """
    hay_parts = [str(name or "")]
    if image_props:
        hay_parts.extend(
            [
                str(image_props.get("os_distro") or ""),
                str(image_props.get("os_version") or ""),
                str(image_props.get("os_type") or ""),
                str(image_props.get("name") or ""),
            ]
        )
    hay = " ".join(hay_parts).lower()

    oid = str(os_id or "").strip().lower().strip('"')
    ver = str(os_ver or "").strip().strip('"')
    major = ""
    if ver:
        major = ver.split(".")[0].split("_")[0]
        try:
            int(major)
        except ValueError:
            major = ""

    if oid == "ubuntu" and major.isdigit():
        m = int(major)
        if m >= 24:
            return "ubuntu24"
        if m >= 22:
            return "ubuntu22"
        if m >= 20:
            return "ubuntu20"
        return "ubuntu"
    if oid == "debian" and major.isdigit():
        m = int(major)
        if m >= 12:
            return "debian12"
        if m >= 11:
            return "debian11"
        if m >= 10:
            return "debian10"
        return "debian"
    if oid in {"rocky", "rockylinux"} and major.isdigit():
        m = int(major)
        if m >= 9:
            return "rocky9"
        return "rocky8"
    if oid in {"almalinux", "alma"} and major.isdigit():
        m = int(major)
        if m >= 9:
            return "alma9"
        return "alma8"
    if oid in {"centos", "centosstream"} and major.isdigit():
        m = int(major)
        if m >= 9:
            return "centos9"
        if m >= 8:
            return "centos8"
        return "centos7"
    if oid in {"rhel", "redhat"} and major.isdigit():
        m = int(major)
        if m >= 9:
            return "rhel9"
        if m >= 8:
            return "rhel8"
        return "rhel7"

    token_map = [
        ("ubuntu24", [r"ubuntu[\s\-_]*24", r"\bu24\b"]),
        ("ubuntu22", [r"ubuntu[\s\-_]*22", r"\bu22\b", r"jammy"]),
        ("ubuntu20", [r"ubuntu[\s\-_]*20", r"\bu20\b", r"focal"]),
        ("debian12", [r"debian[\s\-_]*12", r"bookworm"]),
        ("debian11", [r"debian[\s\-_]*11", r"bullseye"]),
        ("debian10", [r"debian[\s\-_]*10", r"buster"]),
        ("rocky9", [r"rocky[\s\-_]*9"]),
        ("rocky8", [r"rocky[\s\-_]*8"]),
        ("alma9", [r"alma[\s\-_]*9", r"almalinux[\s\-_]*9"]),
        ("alma8", [r"alma[\s\-_]*8", r"almalinux[\s\-_]*8"]),
        ("rhel9", [r"rhel[\s\-_]*9", r"red[\s\-_]*hat[\s\-_]*9"]),
        ("rhel8", [r"rhel[\s\-_]*8", r"red[\s\-_]*hat[\s\-_]*8"]),
        ("rhel7", [r"rhel[\s\-_]*7", r"red[\s\-_]*hat[\s\-_]*7"]),
        ("centos9", [r"centos[\s\-_]*9"]),
        ("centos8", [r"centos[\s\-_]*8"]),
        ("centos7", [r"centos[\s\-_]*7"]),
        ("windows", [r"windows", r"win2019", r"win2022", r"win2016", r"win2012", r"winserv"]),
    ]
    for os_type, patterns in token_map:
        for pat in patterns:
            if re.search(pat, hay, re.I):
                return os_type

    if "ubuntu" in hay:
        return "ubuntu"
    if "debian" in hay:
        return "debian"
    if "rocky" in hay:
        return "rocky8"
    if "alma" in hay:
        return "alma8"
    if "centos" in hay:
        return "centos7"
    if "rhel" in hay or "red hat" in hay:
        return "rhel8"
    return ""
