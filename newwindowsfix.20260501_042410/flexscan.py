#!/usr/bin/env python3
"""
flexscan.py  — Live scan of FLEX servers via OpenStack Keystone v3 + Nova + Glance APIs
=========================================================================================
Credentials via env vars:
    OS_AUTH_URL           – Keystone v3 endpoint
    OS_USERNAME           – OpenStack username
    OS_PASSWORD           – OpenStack password
    OS_PROJECT_ID         – Project / tenant UUID
    OS_REGION_NAME        – Region (default: DFW3)
    OS_USER_DOMAIN_NAME   – Domain (default: rackspace_cloud_domain)

OUTPUT (stdout, JSON):
{
  "servers": [
    {
      "name":        <str>,
      "id":          <str>,
      "status":      <str>,
      "external_ip": <str>,
      "internal_ip": <str>,
      "flavor_id":   <str>,
      "image_id":    <str>,
      "os_type":     "Linux" | "Windows" | "Unknown",
      "os_distro":   <str>,   — e.g. "ubuntu", "centos", "rhel"
      "os_version":  <str>,   — e.g. "22.04", "8"
      "os_label":    <str>,   — e.g. "Ubuntu 22.04 LTS"
      "service_type": "cloud_server",
      "region":      <str>
    }, ...
  ],
  "count":    <int>,
  "nova_url": <str>
}
"""

import json
import os
import re
import subprocess
import sys


# ── Config ────────────────────────────────────────────────────────────────────
AUTH_URL   = os.environ.get("OS_AUTH_URL", "")
USERNAME   = os.environ.get("OS_USERNAME", "")
PASSWORD   = os.environ.get("OS_PASSWORD", "")
PROJECT_ID = os.environ.get("OS_PROJECT_ID", "")
REGION     = os.environ.get("OS_REGION_NAME", "DFW3")
DOMAIN     = os.environ.get("OS_USER_DOMAIN_NAME", "rackspace_cloud_domain")
MAX_IMAGE_LOOKUPS = int(os.environ.get("FLEX_MAX_IMAGE_LOOKUPS", "50"))

if not all([AUTH_URL, USERNAME, PASSWORD, PROJECT_ID]):
    print(json.dumps({"error": "Missing OS_AUTH_URL, OS_USERNAME, OS_PASSWORD, or OS_PROJECT_ID"}))
    sys.exit(1)


# ── HTTP helpers ──────────────────────────────────────────────────────────────
def curl_get(url: str, token: str, timeout: int = 30) -> str:
    r = subprocess.run(
        ["curl", "-s", "-k", url,
         "-H", f"X-Auth-Token: {token}",
         "-H", "Accept: application/json"],
        capture_output=True, text=True, timeout=timeout,
    )
    return r.stdout


# ── OS detection helpers ──────────────────────────────────────────────────────
DISTRO_MAP = [
    (r"ubuntu",                       ("ubuntu",   "Linux")),
    (r"debian",                       ("debian",   "Linux")),
    (r"almalinux|alma",               ("almalinux","Linux")),
    (r"rocky",                        ("rocky",    "Linux")),
    (r"centos",                       ("centos",   "Linux")),
    (r"rhel|red\s*hat",               ("rhel",     "Linux")),
    (r"fedora",                       ("fedora",   "Linux")),
    (r"opensuse|suse",                ("opensuse", "Linux")),
    (r"coreos|flatcar",               ("coreos",   "Linux")),
    (r"windows|win\s*20\d{2}|win2019|win2022|win2016|win2012",
                                      ("windows",  "Windows")),
    (r"freebsd",                      ("freebsd",  "FreeBSD")),
]

VERSION_RE = [
    r"\b(\d{2}\.\d{2}(?:\.\d+)?)\b",   # 22.04, 20.04.3
    r"\b(20\d{2})\b",                   # 2019, 2022 (Windows)
    r"\b([5-9]|1\d)\b",                 # 5, 8, 9, 10…
]


def guess_os(text: str):
    """Return (os_type, os_distro, os_version) from a free-form string."""
    low = text.lower()
    distro, os_type = "", "Linux"
    for pattern, (name, typ) in DISTRO_MAP:
        if re.search(pattern, low):
            distro, os_type = name, typ
            break
    version = ""
    for vp in VERSION_RE:
        m = re.search(vp, text)
        if m:
            version = m.group(1)
            break
    return os_type, distro, version


def make_label(os_type, distro, version):
    if os_type == "Windows":
        return f"Windows Server {version}".strip() if version else "Windows Server"
    if distro:
        label = distro.title().replace("Rhel", "RHEL").replace("Almalinux", "AlmaLinux")
        return (label + " " + version).strip()
    return "Linux" if os_type == "Linux" else os_type


# ── Rackspace backbone IP ranges (internal/management) ────────────────────────
BACKBONE = tuple(f"10.{n}." for n in range(176, 210))


# ── Step 1: Authenticate (Keystone v3) ───────────────────────────────────────
auth_body = json.dumps({
    "auth": {
        "identity": {
            "methods": ["password"],
            "password": {
                "user": {
                    "name": USERNAME,
                    "domain": {"name": DOMAIN},
                    "password": PASSWORD,
                }
            },
        },
        "scope": {"project": {"id": PROJECT_ID}},
    }
})

r_auth = subprocess.run(
    ["curl", "-s", "-k", "-i", "-X", "POST",
     f"{AUTH_URL}/auth/tokens",
     "-H", "Content-Type: application/json",
     "-d", auth_body],
    capture_output=True, text=True, timeout=30,
)

# Extract token from X-Subject-Token header
token = None
for line in r_auth.stdout.splitlines():
    if line.lower().startswith("x-subject-token:"):
        token = line.split(":", 1)[1].strip()
        break

if not token:
    print(json.dumps({"error": "Auth failed — no token in response", "detail": r_auth.stdout[:400]}))
    sys.exit(1)

# ── Parse service catalog from response body ──────────────────────────────────
catalog_data = {}
try:
    sep = "\r\n\r\n" if "\r\n\r\n" in r_auth.stdout else "\n\n"
    body_str = r_auth.stdout[r_auth.stdout.index(sep):].strip()
    catalog_data = json.loads(body_str)
except Exception:
    pass

nova_url    = None
neutron_url = None
glance_url  = None

for svc in catalog_data.get("token", {}).get("catalog", []):
    stype = svc.get("type", "")
    for ep in svc.get("endpoints", []):
        if ep.get("region_id") != REGION or ep.get("interface") != "public":
            continue
        url = ep.get("url", "")
        if stype == "compute" and not nova_url:
            nova_url = url
        elif stype == "network" and not neutron_url:
            neutron_url = url
        elif stype in ("image", "image_v2") and not glance_url:
            glance_url = url

# Fallback URLs
if not nova_url:
    nova_url = f"https://nova.{REGION.lower()}.rackspacecloud.com/v2.1/{PROJECT_ID}"
if not glance_url:
    glance_url = nova_url.split("/v2")[0] + "/image/v2"


# ── Step 2: Fetch servers ─────────────────────────────────────────────────────
raw_servers = curl_get(f"{nova_url}/servers/detail", token)
try:
    servers_data = json.loads(raw_servers).get("servers", [])
except Exception as e:
    print(json.dumps({"error": f"Failed to parse server list: {e}"}))
    sys.exit(1)


# ── Step 3: Fetch floating IPs via Neutron ────────────────────────────────────
floating_ips: dict = {}    # fixed_ip_address → floating_ip_address
if neutron_url:
    try:
        fip_raw = curl_get(f"{neutron_url}/v2.0/floatingips?status=ACTIVE", token)
        fips = json.loads(fip_raw).get("floatingips", [])
        for fip in fips:
            fixed = fip.get("fixed_ip_address") or fip.get("port_id")
            flt   = fip.get("floating_ip_address")
            if fixed and flt:
                floating_ips[fixed] = flt
    except Exception:
        pass


# ── Step 4: Build Glance image cache ─────────────────────────────────────────
image_cache: dict = {}

# Try Glance v2 image list
try:
    raw_imgs = curl_get(f"{glance_url}/images?limit=200", token)
    imgs = json.loads(raw_imgs).get("images", [])
    for img in imgs:
        if img.get("id"):
            image_cache[img["id"]] = img
except Exception:
    pass

# Fallback: Nova image list (v2 compute API includes basic image metadata)
if not image_cache:
    try:
        raw_imgs = curl_get(f"{nova_url}/images/detail?limit=200", token)
        imgs = json.loads(raw_imgs).get("images", [])
        for img in imgs:
            if img.get("id"):
                image_cache[img["id"]] = img
    except Exception:
        pass


def get_image_meta(image_id: str) -> dict:
    if not image_id or image_id in ("N/A", ""):
        return {}
    if image_id in image_cache:
        return image_cache[image_id]
    # Individual lookup
    try:
        raw = curl_get(f"{glance_url}/images/{image_id}", token)
        meta = json.loads(raw)
        image_cache[image_id] = meta
        return meta
    except Exception:
        pass
    # Try Nova fallback
    try:
        raw = curl_get(f"{nova_url}/images/{image_id}", token)
        meta = json.loads(raw).get("image", {})
        image_cache[image_id] = meta
        return meta
    except Exception:
        return {}


# ── Step 5: Parse servers with OS detection ───────────────────────────────────
servers = []
image_lookups = 0

for s in servers_data:
    addrs = s.get("addresses", {})
    ext_ip = int_ip = None

    for net_name, alist in addrs.items():
        for a in alist:
            ip    = a.get("addr", "")
            atype = a.get("OS-EXT-IPS:type", "fixed")
            if ":" in ip:    # skip IPv6
                continue
            if atype == "floating":
                ext_ip = ext_ip or ip
            elif atype == "fixed":
                # Skip Rackspace backbone addresses
                if not any(ip.startswith(b) for b in BACKBONE):
                    int_ip = int_ip or ip
                # Check if there's a floating IP for this fixed address
                if ip in floating_ips:
                    ext_ip = ext_ip or floating_ips[ip]

    # Flavor
    flavor = s.get("flavor", {})
    flavor_id = (
        flavor.get("original_name") or flavor.get("id", "")
        if isinstance(flavor, dict) else str(flavor)
    )

    # Image reference
    image_ref = s.get("image") or {}
    image_id  = image_ref.get("id", "") if isinstance(image_ref, dict) else str(image_ref or "")

    # ── OS detection: server-level metadata first ─────────────────────────
    server_meta = s.get("metadata", {}) or {}
    os_type    = server_meta.get("os_type", "")
    os_distro  = server_meta.get("os_distro", "")
    os_version = server_meta.get("os_version", "")

    # ── Server name heuristic ─────────────────────────────────────────────
    if not (os_type or os_distro):
        os_type, os_distro, os_version = guess_os(s.get("name", ""))

    # ── Glance image metadata (most authoritative) ────────────────────────
    if image_id and image_lookups < MAX_IMAGE_LOOKUPS:
        img = get_image_meta(image_id)
        image_lookups += 1
        if img:
            # Glance v2 top-level properties
            img_distro  = (img.get("os_distro") or img.get("image_os_distro") or
                           img.get("properties", {}).get("os_distro", ""))
            img_version = (img.get("os_version") or img.get("image_os_version") or
                           img.get("properties", {}).get("os_version", ""))
            img_type    = (img.get("os_type") or
                           img.get("properties", {}).get("os_type", ""))

            # Also try parsing the image name
            if not (img_distro and img_version):
                img_name = img.get("name") or img.get("originalName") or ""
                n_type, n_distro, n_version = guess_os(img_name)
                img_distro  = img_distro  or n_distro
                img_type    = img_type    or n_type
                img_version = img_version or n_version

            os_distro  = os_distro  or img_distro
            os_type    = os_type    or img_type
            os_version = os_version or img_version

    if not os_type:
        os_type = "Linux"

    os_label = make_label(os_type, os_distro, os_version)

    servers.append({
        "name":        s.get("name", "?"),
        "id":          s.get("id", ""),
        "status":      s.get("status", "UNKNOWN"),
        "external_ip": ext_ip or "N/A",
        "internal_ip": int_ip or "N/A",
        "flavor_id":   flavor_id,
        "image_id":    image_id,
        "os_type":     os_type,
        "os_distro":   os_distro,
        "os_version":  os_version,
        "os_label":    os_label,
        "service_type": "cloud_server",
        "region":      REGION,
    })

print(json.dumps({
    "servers":  servers,
    "count":    len(servers),
    "nova_url": nova_url,
}))
