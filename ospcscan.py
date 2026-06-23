#!/usr/bin/env python3
"""
ospcscan.py — Live scan of OSPC via Rackspace Identity v2.0 + Nova + Trove.
Uses curl (like the original) — Python urllib is blocked by Cloudflare WAF.

Env vars:
    OSPC_USERNAME   – Rackspace username
    OSPC_APIKEY     – Rackspace API key
    OSPC_TENANT_ID  – Tenant / account ID
    OSPC_REGION     – Region (default: IAD)

Outputs JSON to stdout.
"""
import json, os, re, subprocess, sys

USERNAME  = os.environ.get("OSPC_USERNAME",  "").strip()
APIKEY    = os.environ.get("OSPC_APIKEY",    "").strip()
TENANT_ID = os.environ.get("OSPC_TENANT_ID", "").strip()
REGION    = os.environ.get("OSPC_REGION",    "IAD").strip().upper()

if not all([USERNAME, APIKEY, TENANT_ID]):
    print(json.dumps({"error": "Missing OSPC_USERNAME, OSPC_APIKEY, or OSPC_TENANT_ID"}))
    sys.exit(1)


def curl_get(url, token):
    r = subprocess.run(
        ["curl", "-s", "-k", url,
         "-H", f"X-Auth-Token: {token}",
         "-H", "Accept: application/json",
         "-H", f"X-Auth-Project-Id: {TENANT_ID}"],
        capture_output=True, text=True, timeout=30
    )
    return json.loads(r.stdout)


def curl_post(url, body):
    r = subprocess.run(
        ["curl", "-s", "-k", "-X", "POST", url,
         "-H", "Content-Type: application/json",
         "-H", "Accept: application/json",
         "-d", json.dumps(body)],
        capture_output=True, text=True, timeout=30
    )
    return json.loads(r.stdout)


# ── OS heuristics ─────────────────────────────────────────────────────────────
DISTRO_PATTERNS = [
    (r"windows|win\s*\d{4}|win2019|win2022|win2016|win2012", "windows",   "Windows"),
    (r"ubuntu",                                               "ubuntu",    "Linux"),
    (r"debian",                                               "debian",    "Linux"),
    (r"almalinux|alma",                                       "almalinux", "Linux"),
    (r"rocky",                                                "rocky",     "Linux"),
    (r"centos",                                               "centos",    "Linux"),
    (r"rhel|red\s*hat",                                       "rhel",      "Linux"),
    (r"fedora",                                               "fedora",    "Linux"),
    (r"opensuse|suse",                                        "opensuse",  "Linux"),
    (r"freebsd",                                              "freebsd",   "FreeBSD"),
]
VERSION_RE = re.compile(r"\b(\d{2}\.\d{2}(?:\.\d+)?)\b|\b(20\d{2})\b|\b([5-9]|1\d)\b")


def guess_os(text):
    low = text.lower()
    distro, os_type = "", "Linux"
    for pat, d, t in DISTRO_PATTERNS:
        if re.search(pat, low):
            distro, os_type = d, t
            break
    version = ""
    m = VERSION_RE.search(text)
    if m:
        version = next(g for g in m.groups() if g)
    return os_type, distro, version


def make_label(os_type, distro, version):
    if os_type == "Windows":
        return f"Windows Server {version}".strip() if version else "Windows Server"
    if distro:
        label = distro.title().replace("Rhel", "RHEL").replace("Almalinux", "AlmaLinux")
        return f"{label} {version}".strip() if version else label
    return "Linux" if os_type == "Linux" else os_type or "Unknown"


# ── Step 1: Auth ──────────────────────────────────────────────────────────────
try:
    auth = curl_post("https://identity.api.rackspacecloud.com/v2.0/tokens", {
        "auth": {
            "RAX-KSKEY:apiKeyCredentials": {"username": USERNAME, "apiKey": APIKEY},
            "tenantId": TENANT_ID
        }
    })
    if "access" not in auth:
        fault = auth.get("unauthorized") or auth.get("forbidden") or auth.get("badRequest") or auth.get("itemNotFound") or auth
        print(json.dumps({"error": f"Auth failed for tenant {TENANT_ID}: {fault}"}))
        sys.exit(1)
    token = auth["access"]["token"]["id"]
except Exception as e:
    print(json.dumps({"error": f"Auth failed for tenant {TENANT_ID}: {e}"}))
    sys.exit(1)

# ── Step 2: Resolve endpoints ─────────────────────────────────────────────────
nova_url = trove_url = None
for svc in auth["access"]["serviceCatalog"]:
    stype = svc.get("type", "")
    for ep in svc.get("endpoints", []):
        if ep.get("region", "").upper() != REGION:
            continue
        pub = ep.get("publicURL", "")
        if stype == "compute" and not nova_url:
            nova_url = pub
        if stype in ("rax:database", "database") and not trove_url:
            trove_url = pub

if not nova_url:
    print(json.dumps({"error": f"No Nova endpoint for region {REGION}"}))
    sys.exit(1)

# ── Step 3: Fetch all servers (with pagination) ───────────────────────────────
all_servers = []
next_url = f"{nova_url}/servers/detail?limit=1000"
while next_url:
    try:
        page = curl_get(next_url, token)
    except Exception as e:
        print(json.dumps({"error": f"Nova servers list failed: {e}"}))
        sys.exit(1)
    all_servers.extend(page.get("servers", []))
    next_url = None
    for link in page.get("servers_links", []):
        if link.get("rel") == "next":
            next_url = link.get("href")

# ── Step 4: Build image metadata cache ───────────────────────────────────────
image_cache = {}
try:
    imgs = curl_get(f"{nova_url}/images/detail?limit=1000", token)
    for img in imgs.get("images", []):
        if img.get("id"):
            image_cache[img["id"]] = img
except Exception:
    pass


def get_image(image_id):
    if not image_id:
        return {}
    if image_id in image_cache:
        return image_cache[image_id]
    try:
        data = curl_get(f"{nova_url}/images/{image_id}", token)
        meta = data.get("image", data)
        image_cache[image_id] = meta
        return meta
    except Exception:
        return {}


# ── Step 5: Parse servers ─────────────────────────────────────────────────────
servers = []
for s in all_servers:
    pub_ip = priv_ip = None
    for _net, alist in (s.get("addresses") or {}).items():
        for a in alist:
            ip = a.get("addr", "")
            if ":" in ip:
                continue
            
            is_priv = False
            if ip.startswith("10.") or ip.startswith("192.168."):
                is_priv = True
            elif ip.startswith("172."):
                parts = ip.split(".")
                if len(parts) >= 2 and parts[1].isdigit() and 16 <= int(parts[1]) <= 31:
                    is_priv = True
            
            if is_priv:
                priv_ip = priv_ip or ip
            elif ip:
                pub_ip = pub_ip or ip

    flavor   = s.get("flavor") or {}
    flavor_id = flavor.get("id", "") if isinstance(flavor, dict) else str(flavor)

    image_ref = s.get("image") or {}
    image_id  = image_ref.get("id", "") if isinstance(image_ref, dict) else str(image_ref)

    smeta = s.get("metadata") or {}
    os_type    = smeta.get("os_type", "")
    os_distro  = smeta.get("os_distro", smeta.get("image_os_distro", ""))
    os_version = smeta.get("os_version", smeta.get("image_os_version", ""))

    img = get_image(image_id)
    if img:
        props = img.get("metadata") or img.get("properties") or {}
        os_type    = os_type    or props.get("os_type", "")
        os_distro  = os_distro  or props.get("os_distro", props.get("image_os_distro", ""))
        os_version = os_version or props.get("os_version", props.get("image_os_version", ""))
        img_name   = img.get("name", "") or img.get("originalName", "")
        if img_name and not (os_distro and os_version):
            t, d, v = guess_os(img_name)
            os_type = os_type or t; os_distro = os_distro or d; os_version = os_version or v

    if not (os_distro and os_version):
        t, d, v = guess_os(s.get("name", ""))
        os_type = os_type or t; os_distro = os_distro or d; os_version = os_version or v

    os_type = os_type or "Linux"

    servers.append({
        "name":         s.get("name", "?"),
        "id":           s.get("id", ""),
        "status":       s.get("status", "UNKNOWN"),
        "external_ip":  pub_ip  or "N/A",
        "internal_ip":  priv_ip or "N/A",
        "flavor_id":    flavor_id,
        "image_id":     image_id,
        "os_type":      os_type,
        "os_distro":    os_distro,
        "os_version":   os_version,
        "os_label":     make_label(os_type, os_distro, os_version),
        "service_type": "cloud_server",
        "region":       s.get("_region", REGION),
    })

# ── Step 6: Fetch databases (Trove) ──────────────────────────────────────────
databases = []
if trove_url:
    try:
        for db in curl_get(f"{trove_url}/instances", token).get("instances", []):
            ds    = db.get("datastore") or {}
            ds_t  = ds.get("type",    "") if isinstance(ds, dict) else ""
            ds_v  = ds.get("version", "") if isinstance(ds, dict) else ""
            fl    = db.get("flavor")  or {}
            fl_id = fl.get("id",      "") if isinstance(fl, dict) else ""
            databases.append({
                "name":              db.get("name",   "?"),
                "id":                db.get("id",     ""),
                "status":            db.get("status", "UNKNOWN"),
                "flavor_id":         fl_id,
                "datastore_type":    ds_t,
                "datastore_version": ds_v,
                "os_type":           "Database",
                "os_distro":         ds_t.lower(),
                "os_version":        ds_v,
                "os_label":          f"{ds_t.title()} {ds_v}".strip() or "Database",
                "service_type":      "database_instance",
                "region":            REGION,
            })
    except Exception:
        pass

# ── Output ────────────────────────────────────────────────────────────────────
print(json.dumps({
    "servers":   servers,
    "databases": databases,
    "count":     len(servers),
    "db_count":  len(databases),
    "region":    REGION,
}))
