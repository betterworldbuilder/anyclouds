import csv
import json
import argparse
from datetime import datetime
from getpass import getpass

import requests


def parse_args():
    parser = argparse.ArgumentParser(description="Export Rackspace account inventory to a single CSV file.")
    parser.add_argument("--username", default="", help="Rackspace username")
    parser.add_argument("--api-key", default="", help="Rackspace API key")
    parser.add_argument("--account-id", default="", help="Rackspace account ID")
    parser.add_argument(
        "--regions",
        default="dfw,iad,ord,hkg,syd",
        help="Comma-separated regions to scan (default: dfw,iad,ord,hkg,syd)",
    )
    return parser.parse_args()


# ----------------------------
# User input
# ----------------------------
args = parse_args()
username = (args.username or "").strip() or input("Enter your Rackspace username: ").strip()
api_key = (args.api_key or "").strip() or getpass("Enter your Rackspace API key: ").strip()
account_id = (args.account_id or "").strip() or input("Enter your Rackspace account ID: ").strip()
regions = [r.strip().lower() for r in (args.regions or "").split(",") if r.strip()]

# ----------------------------
# CSV schema (single file)
# ----------------------------
FIELDNAMES = [
    "collected_at",
    "service_type",
    "region",
    "name",
    "resource_id",
    "status",
    "created",
    "updated",
    "public_ips",
    "private_ips",
    "flavor_id",
    "image_id",
    "image_name",
    "image_os_distro",
    "image_os_version",
    "image_os_type",
    "image_release_id",
    "image_lookup_error",
    "image_schedule",
    "hypervisor_id",
    "size_gb",
    "attachments",
    "protocol",
    "node_count",
    "datastore_type",
    "datastore_version",
    "backup_schedule_enabled",
    "ha_group_id",
    "email_address",
    "backup_container",
    "is_encrypted",
    "datacenter",
    "details_json",
    "cidr",
    "gateway_ip",
    "network_id",
    "object_count",
    "bytes_used",
    "cdn_enabled",
    "stack_status_reason",
]

# Reuse one HTTP session for better performance
session = requests.Session()


def progress(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] IN PROGRESS - PLEASE WAIT: {msg}", flush=True)


def fetch_json(url, headers, timeout=30):
    try:
        response = session.get(url, headers=headers, timeout=timeout)
        if response.status_code == 200:
            try:
                return True, response.json(), None
            except json.JSONDecodeError:
                return False, None, f"Invalid JSON from {url}"
        return False, None, f"HTTP {response.status_code} from {url}: {response.text[:300]}"
    except requests.RequestException as e:
        return False, None, f"Request error for {url}: {e}"


def collect_lb_ips(detail_obj):
    public = []
    private = []
    lb = detail_obj.get("loadBalancer", {}) if isinstance(detail_obj, dict) else {}
    for vip in lb.get("virtualIps", []) if isinstance(lb, dict) else []:
        if not isinstance(vip, dict):
            continue
        ip = str(vip.get("address", "")).strip()
        ip_type = str(vip.get("type", "")).strip().upper()
        if not ip:
            continue
        if ip_type in {"PUBLIC"}:
            public.append(ip)
        elif ip_type in {"SERVICENET", "PRIVATE"}:
            private.append(ip)
        else:
            public.append(ip)
    return "; ".join(public), "; ".join(private)


def format_addresses(addresses_obj, network_name):
    values = addresses_obj.get(network_name, [])
    out = []
    for item in values:
        if isinstance(item, dict):
            addr = item.get("addr")
            if addr:
                out.append(str(addr))
        elif item:
            out.append(str(item))
    return "; ".join(out)


def base_row(service_type, region=""):
    return {
        "collected_at": datetime.utcnow().isoformat() + "Z",
        "service_type": service_type,
        "region": region,
        "name": "",
        "resource_id": "",
        "status": "",
        "created": "",
        "updated": "",
        "public_ips": "",
        "private_ips": "",
        "flavor_id": "",
        "image_id": "",
        "image_name": "",
        "image_os_distro": "",
        "image_os_version": "",
        "image_os_type": "",
        "image_release_id": "",
        "image_lookup_error": "",
        "image_schedule": "",
        "hypervisor_id": "",
        "size_gb": "",
        "attachments": "",
        "protocol": "",
        "node_count": "",
        "datastore_type": "",
        "datastore_version": "",
        "backup_schedule_enabled": "",
        "ha_group_id": "",
        "email_address": "",
        "backup_container": "",
        "is_encrypted": "",
        "datacenter": "",
        "details_json": "",
        "cidr": "",
        "gateway_ip": "",
        "network_id": "",
        "object_count": "",
        "bytes_used": "",
        "cdn_enabled": "",
        "stack_status_reason": "",
    }


def extract_volume_image_info(volume_obj):
    metadata = volume_obj.get("volume_image_metadata", {})
    if not isinstance(metadata, dict):
        metadata = {}
    return {
        "image_id": metadata.get("image_id", ""),
        "image_name": metadata.get("image_name", ""),
        "image_os_distro": metadata.get("org.openstack__1__os_distro", ""),
        "image_os_version": metadata.get("org.openstack__1__os_version", ""),
        "image_os_type": metadata.get("os_type", ""),
        "image_release_id": metadata.get("com.rackspace__1__release_id", ""),
    }


def get_image_info(region, account_id, image_id, headers, cache):
    if not image_id:
        return {}

    cache_key = f"{region}:{image_id}"
    if cache_key in cache:
        return cache[cache_key]

    progress(f"{region.upper()} - Looking up image metadata for image_id={image_id}")
    url = f"https://{region}.servers.api.rackspacecloud.com/v2/{account_id}/images/{image_id}"
    ok, data, err = fetch_json(url, headers)

    if not ok:
        cache[cache_key] = {"image_lookup_error": err}
        return cache[cache_key]

    image = data.get("image", {})
    metadata = image.get("metadata", {})

    result = {
        "image_name": image.get("name", ""),
        "image_os_distro": metadata.get("os_distro", ""),
        "image_os_version": metadata.get("org.openstack__1__os_version", ""),
        "image_os_type": metadata.get("os_type", ""),
        "image_release_id": metadata.get("com.rackspace__1__release_id", ""),
        "image_lookup_error": "",
    }
    cache[cache_key] = result
    return result


# ----------------------------
# Authenticate
# ----------------------------
progress("Authenticating with Rackspace Identity API")
auth_url = "https://identity.api.rackspacecloud.com/v2.0/tokens"
auth_payload = {
    "auth": {
        "RAX-KSKEY:apiKeyCredentials": {
            "username": username,
            "apiKey": api_key,
        }
    }
}
auth_response = session.post(auth_url, json=auth_payload, timeout=30)
if auth_response.status_code != 200:
    raise SystemExit(f"Authentication failed: HTTP {auth_response.status_code} - {auth_response.text[:300]}")

auth_data = auth_response.json()
token = auth_data["access"]["token"]["id"]
headers = {"X-Auth-Token": token}
service_catalog = auth_data["access"].get("serviceCatalog", [])


def get_catalog_endpoint(catalog, service_type, region_name):
    """Extract publicURL from the service catalog for a given service type and region."""
    for svc in catalog:
        if svc.get("type") == service_type:
            for ep in svc.get("endpoints", []):
                if ep.get("region", "").upper() == region_name.upper():
                    return ep.get("publicURL", "")
    return ""

rows = []
image_cache = {}
collection_errors = []


def record_collection_error(region, service_name, err):
    msg = f"{region.upper()} - {service_name}: {err}"
    collection_errors.append(msg)
    print(f"[{datetime.now().strftime('%H:%M:%S')}] WARNING - {msg}", flush=True)

# ----------------------------
# Region-scoped services
# ----------------------------
for region in regions:
    progress(f"{region.upper()} - Fetching Cloud Servers")
    ok, data, err = fetch_json(
        f"https://{region}.servers.api.rackspacecloud.com/v2/{account_id}/servers/detail",
        headers,
    )
    if ok:
        for s in data.get("servers", []):
            image_id = (s.get("image") or {}).get("id", "") if isinstance(s.get("image"), dict) else ""
            image_info = get_image_info(region, account_id, image_id, headers, image_cache)

            row = base_row("cloud_server", region)
            row.update({
                "name": s.get("name", ""),
                "resource_id": s.get("id", ""),
                "status": s.get("status", ""),
                "created": s.get("created", ""),
                "public_ips": format_addresses(s.get("addresses", {}), "public"),
                "private_ips": format_addresses(s.get("addresses", {}), "private"),
                "flavor_id": (s.get("flavor") or {}).get("id", ""),
                "image_id": image_id,
                "image_schedule": s.get("RAX-SI:image_schedule", ""),
                "hypervisor_id": s.get("hostId", ""),
                "image_name": image_info.get("image_name", ""),
                "image_os_distro": image_info.get("image_os_distro", ""),
                "image_os_version": image_info.get("image_os_version", ""),
                "image_os_type": image_info.get("image_os_type", ""),
                "image_release_id": image_info.get("image_release_id", ""),
                "image_lookup_error": image_info.get("image_lookup_error", ""),
            })
            rows.append(row)
    else:
        record_collection_error(region, "cloud_servers", err)

    progress(f"{region.upper()} - Fetching Block Storage")
    ok, data, err = fetch_json(
        f"https://{region}.blockstorage.api.rackspacecloud.com/v1/{account_id}/volumes/detail",
        headers,
    )
    if ok:
        for v in data.get("volumes", []):
            vol_image_info = extract_volume_image_info(v)
            row = base_row("block_storage_volume", region)
            row.update({
                "name": v.get("display_name", ""),
                "resource_id": v.get("id", ""),
                "status": v.get("status", ""),
                "size_gb": v.get("size", ""),
                "attachments": json.dumps(v.get("attachments", [])),
                "image_id": vol_image_info.get("image_id", ""),
                "image_name": vol_image_info.get("image_name", ""),
                "image_os_distro": vol_image_info.get("image_os_distro", ""),
                "image_os_version": vol_image_info.get("image_os_version", ""),
                "image_os_type": vol_image_info.get("image_os_type", ""),
                "image_release_id": vol_image_info.get("image_release_id", ""),
            })
            rows.append(row)
    else:
        record_collection_error(region, "block_storage", err)

    progress(f"{region.upper()} - Fetching Load Balancers")
    ok, data, err = fetch_json(
        f"https://{region}.loadbalancers.api.rackspacecloud.com/v1.0/{account_id}/loadbalancers",
        headers,
    )
    if ok:
        for lb in data.get("loadBalancers", []):
            lb_id = lb.get("id", "")
            detail_url = f"https://{region}.loadbalancers.api.rackspacecloud.com/v1.0/{account_id}/loadbalancers/{lb_id}"
            detail_ok, detail_data, detail_err = fetch_json(detail_url, headers)

            lb_protocol = lb.get("protocol", "")
            lb_node_count = lb.get("nodeCount", "")
            lb_created = lb.get("created", "")
            lb_status = lb.get("status", "")
            lb_public_ips = ""
            lb_private_ips = ""
            lb_details_json = ""

            if detail_ok and isinstance(detail_data, dict):
                lb_obj = detail_data.get("loadBalancer", {})
                if isinstance(lb_obj, dict):
                    lb_protocol = lb_obj.get("protocol", lb_protocol)
                    if isinstance(lb_obj.get("nodes"), list):
                        lb_node_count = len(lb_obj.get("nodes", []))
                    else:
                        lb_node_count = lb_obj.get("nodeCount", lb_node_count)
                    lb_created = lb_obj.get("created", lb_created)
                    lb_status = lb_obj.get("status", lb_status)
                    lb_public_ips, lb_private_ips = collect_lb_ips(detail_data)
                lb_details_json = json.dumps(detail_data, separators=(",", ":"))
            else:
                lb_details_json = json.dumps(
                    {"detail_lookup_error": detail_err or "unknown_error", "list_payload": lb},
                    separators=(",", ":"),
                )

            row = base_row("load_balancer", region)
            row.update({
                "name": lb.get("name", ""),
                "resource_id": lb_id,
                "status": lb_status,
                "created": lb_created,
                "protocol": lb_protocol,
                "node_count": lb_node_count,
                "public_ips": lb_public_ips,
                "private_ips": lb_private_ips,
                "details_json": lb_details_json,
            })
            rows.append(row)
    else:
        record_collection_error(region, "load_balancers", err)

    progress(f"{region.upper()} - Fetching Database Instances")
    ok, data, err = fetch_json(
        f"https://{region}.databases.api.rackspacecloud.com/v1.0/{account_id}/instances",
        headers,
    )
    if ok:
        for db in data.get("instances", []):
            row = base_row("database_instance", region)
            row.update({
                "name": db.get("name", ""),
                "resource_id": db.get("id", ""),
                "status": db.get("status", ""),
                "datastore_type": (db.get("datastore") or {}).get("type", ""),
                "datastore_version": (db.get("datastore") or {}).get("version", ""),
                "size_gb": (db.get("volume") or {}).get("size", ""),
                "backup_schedule_enabled": (db.get("schedule") or {}).get("enabled", ""),
                "ha_group_id": db.get("ha_id", ""),
            })
            rows.append(row)
    else:
        record_collection_error(region, "databases", err)

    progress(f"{region.upper()} - Fetching HA Databases")
    ok, data, err = fetch_json(
        f"https://{region}.databases.api.rackspacecloud.com/v1.0/{account_id}/ha",
        headers,
    )
    if ok:
        for ha in data.get("ha_instances", []):
            row = base_row("ha_database_group", region)
            row.update({
                "name": ha.get("name", ""),
                "resource_id": ha.get("id", ""),
                "status": ha.get("state", ""),
                "datastore_type": (ha.get("datastore") or {}).get("type", ""),
            })
            rows.append(row)
    else:
        record_collection_error(region, "ha_databases", err)

    progress(f"{region.upper()} - Fetching Backup Agents")
    ok, data, err = fetch_json(
        f"https://{region}.backup.api.rackspacecloud.com/v1.0/{account_id}/user/agents",
        headers,
    )
    if ok and isinstance(data, list):
        for a in data:
            row = base_row("backup_agent", region)
            row.update({
                "name": a.get("MachineName", ""),
                "resource_id": a.get("MachineAgentId", ""),
                "status": a.get("Status") or a.get("status", ""),
                "backup_container": a.get("BackupContainer", ""),
                "is_encrypted": a.get("IsEncrypted", ""),
                "datacenter": a.get("Datacenter", ""),
            })
            rows.append(row)
    elif not ok:
        record_collection_error(region, "cloud_backup", err)

    # ---- Cloud Networks (Nova extension: os-networksv2) ----
    progress(f"{region.upper()} - Fetching Cloud Networks")
    ok, data, err = fetch_json(
        f"https://{region}.servers.api.rackspacecloud.com/v2/{account_id}/os-networksv2",
        headers,
    )
    if ok:
        for net in data.get("networks", []):
            row = base_row("cloud_network", region)
            row.update({
                "name": net.get("label", net.get("name", "")),
                "resource_id": net.get("id", ""),
                "cidr": net.get("cidr", ""),
                "details_json": json.dumps(net, separators=(",", ":")),
            })
            rows.append(row)
    else:
        record_collection_error(region, "cloud_networks", err)

    # ---- Security Groups (Neutron / cloudNetworks) ----
    progress(f"{region.upper()} - Fetching Security Groups")
    ok, data, err = fetch_json(
        f"https://{region}.networks.api.rackspacecloud.com/v2.0/security-groups",
        headers,
    )
    if ok:
        for sg in data.get("security_groups", []):
            rules = sg.get("security_group_rules", [])
            sg_name = sg.get("name", "")
            sg_id = sg.get("id", "")
            row = base_row("security_group", region)
            row.update({
                "name": sg_name,
                "resource_id": sg_id,
                "node_count": len(rules),
                "details_json": json.dumps(sg, separators=(",", ":")),
            })
            rows.append(row)

            # Emit each rule as its own row for card-based detail UI
            for rule in rules:
                port_min = rule.get("port_range_min", "")
                port_max = rule.get("port_range_max", "")
                if port_min and port_max:
                    port_range = f"{port_min}-{port_max}" if str(port_min) != str(port_max) else str(port_min)
                elif port_min:
                    port_range = str(port_min)
                else:
                    port_range = "Any"

                rrow = base_row("security_group_rule", region)
                rrow.update({
                    "name": sg_name,
                    "resource_id": rule.get("id", ""),
                    "network_id": sg_id,
                    "cidr": rule.get("remote_ip_prefix", "Any"),
                    "gateway_ip": rule.get("direction", ""),
                    "cdn_enabled": rule.get("ethertype", ""),
                    "stack_status_reason": f"{rule.get('protocol', 'Any')}:{port_range}",
                    "details_json": json.dumps(rule, separators=(",", ":")),
                })
                rows.append(rrow)
    else:
        record_collection_error(region, "security_groups", err)

    # ---- Cloud Files (Object Storage via Service Catalog) ----
    cf_url = get_catalog_endpoint(service_catalog, "object-store", region)
    if cf_url:
        progress(f"{region.upper()} - Fetching Cloud Files Containers")
        ok, data, err = fetch_json(cf_url + "?format=json", headers)
        if ok and isinstance(data, list):
            for container in data:
                row = base_row("cloud_files_container", region)
                row.update({
                    "name": container.get("name", ""),
                    "object_count": container.get("count", ""),
                    "bytes_used": container.get("bytes", ""),
                })
                rows.append(row)
        elif not ok:
            record_collection_error(region, "cloud_files", err)

    # ---- CDN-enabled Containers (via Service Catalog) ----
    cdn_url = get_catalog_endpoint(service_catalog, "rax:object-cdn", region)
    if cdn_url:
        progress(f"{region.upper()} - Fetching CDN-Enabled Containers")
        ok, data, err = fetch_json(cdn_url + "?format=json", headers)
        if ok and isinstance(data, list):
            for container in data:
                row = base_row("cdn_container", region)
                row.update({
                    "name": container.get("name", ""),
                    "cdn_enabled": str(container.get("cdn_enabled", "")),
                    "details_json": json.dumps(container, separators=(",", ":")),
                })
                rows.append(row)
        elif not ok:
            record_collection_error(region, "cdn_containers", err)

    # ---- Orchestration / Heat Stacks ----
    progress(f"{region.upper()} - Fetching Orchestration Stacks")
    ok, data, err = fetch_json(
        f"https://{region}.orchestration.api.rackspacecloud.com/v1/{account_id}/stacks",
        headers,
    )
    if ok:
        for stack in data.get("stacks", []):
            row = base_row("orchestration_stack", region)
            row.update({
                "name": stack.get("stack_name", ""),
                "resource_id": stack.get("id", ""),
                "status": stack.get("stack_status", ""),
                "stack_status_reason": stack.get("stack_status_reason", ""),
                "created": stack.get("creation_time", ""),
                "updated": stack.get("updated_time", ""),
                "details_json": json.dumps(stack, separators=(",", ":")),
            })
            rows.append(row)
    else:
        record_collection_error(region, "orchestration_stacks", err)

    # ---- Database Backups ----
    progress(f"{region.upper()} - Fetching Database Backups")
    ok, data, err = fetch_json(
        f"https://{region}.databases.api.rackspacecloud.com/v1.0/{account_id}/backups",
        headers,
    )
    if ok:
        for bk in data.get("backups", []):
            row = base_row("database_backup", region)
            row.update({
                "name": bk.get("name", ""),
                "resource_id": bk.get("id", ""),
                "status": bk.get("status", ""),
                "datastore_type": (bk.get("datastore") or {}).get("type", ""),
                "datastore_version": (bk.get("datastore") or {}).get("version", ""),
                "size_gb": bk.get("size", ""),
                "created": bk.get("created", ""),
                "updated": bk.get("updated", ""),
                "details_json": json.dumps(bk, separators=(",", ":")),
            })
            rows.append(row)
    else:
        record_collection_error(region, "database_backups", err)

    # ---- Backup Configurations (Cloud Backup) ----
    progress(f"{region.upper()} - Fetching Backup Configurations")
    ok, data, err = fetch_json(
        f"https://{region}.backup.api.rackspacecloud.com/v1.0/{account_id}/backup-configuration",
        headers,
    )
    if ok:
        configs = data if isinstance(data, list) else data.get("BackupConfigurations", data.get("backup_configurations", []))
        if isinstance(configs, list):
            for cfg in configs:
                row = base_row("backup_configuration", region)
                row.update({
                    "name": cfg.get("BackupConfigurationName", cfg.get("name", "")),
                    "resource_id": cfg.get("BackupConfigurationId", cfg.get("id", "")),
                    "status": "enabled" if cfg.get("IsActive", cfg.get("is_active", False)) else "disabled",
                    "backup_schedule_enabled": str(cfg.get("IsActive", cfg.get("is_active", ""))),
                    "details_json": json.dumps(cfg, separators=(",", ":")),
                })
                rows.append(row)
    else:
        record_collection_error(region, "backup_configurations", err)

# ----------------------------
# DNS (global) — zones + records
# ----------------------------
progress("GLOBAL - Fetching DNS Zones")
ok, data, err = fetch_json(
    f"https://dns.api.rackspacecloud.com/v1.0/{account_id}/domains",
    headers,
)
if ok:
    for d in data.get("domains", []):
        row = base_row("dns_zone", "global")
        row.update({
            "name": d.get("name", ""),
            "resource_id": d.get("id", ""),
            "created": d.get("created", ""),
            "updated": d.get("updated", ""),
            "email_address": d.get("emailAddress", ""),
        })
        rows.append(row)

        # Fetch DNS records for each zone
        domain_id = d.get("id", "")
        if domain_id:
            rok, rdata, rerr = fetch_json(
                f"https://dns.api.rackspacecloud.com/v1.0/{account_id}/domains/{domain_id}/records",
                headers,
            )
            if rok:
                for rec in rdata.get("records", []):
                    rrow = base_row("dns_record", "global")
                    rrow.update({
                        "name": rec.get("name", ""),
                        "resource_id": rec.get("id", ""),
                        "network_id": str(domain_id),
                        "details_json": json.dumps(rec, separators=(",", ":")),
                    })
                    rows.append(rrow)
else:
    record_collection_error("global", "dns", err)

# ----------------------------
# Write output
# ----------------------------
output_file = f"{account_id}_overview.csv"
progress(f"Writing CSV output to {output_file}")

with open(output_file, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=FIELDNAMES, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)

print(f"[{datetime.now().strftime('%H:%M:%S')}] COMPLETE - CSV export finished.", flush=True)
print(f"Output file: {output_file}", flush=True)
print(f"Rows written: {len(rows)}", flush=True)
if collection_errors:
    print(f"Warnings: {len(collection_errors)} collection errors were skipped from CSV.", flush=True)
    for w in collection_errors:
        print(f" - {w}", flush=True)
