#!/usr/bin/env python3
import argparse
import csv
import re
import secrets
import string
from pathlib import Path
from typing import Dict, List, Optional, Tuple


def slugify(value: str) -> str:
    text = (value or "").strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    return text or "resource"


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


def is_windows_image(image_name: str) -> bool:
    return "windows" in (image_name or "").strip().lower()


def generate_windows_password(length: int) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def decode_cloud_init_user_data(value: str) -> str:
    text = (value or "").strip()
    if not text:
        return ""
    # Allow CSV-friendly escaped newlines while still supporting real multiline cells.
    if "\\n" in text and "\n" not in text:
        text = text.replace("\\n", "\n")
    return text


def heredoc_delimiter(base: str, content: str) -> str:
    delim = re.sub(r"[^A-Za-z0-9_]", "_", base or "CLOUD_INIT_EOF")
    if not delim:
        delim = "CLOUD_INIT_EOF"
    while delim in (content or ""):
        delim += "_X"
    return delim


def read_csv(path: Path) -> List[Dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def write_csv(path: Path, rows: List[Dict[str, str]], fieldnames: List[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def shell_quote(text: str) -> str:
    return "'" + (text or "").replace("'", "'\"'\"'") + "'"


def infer_account_id_from_filename(path: Path) -> str:
    m = re.match(r"^(\d+)_", path.stem)
    if m:
        return m.group(1)
    return path.stem


def is_truthy(value: str) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "y", "on"}


def build_server_actions(
    flavor_rows: List[Dict[str, str]],
    key_name: str,
    private_network: str,
    ssh_pub_key: str,
    generate_windows_passwords: bool,
    windows_password_length: int,
    windows_admin_user: str,
) -> Tuple[List[str], List[Dict[str, str]], List[Dict[str, str]], Dict[str, str], set, List[Dict[str, str]]]:
    commands: List[str] = []
    plan: List[Dict[str, str]] = []
    unresolved: List[Dict[str, str]] = []
    source_server_to_target_name: Dict[str, str] = {}
    included_source_server_ids = set()
    used_names: Dict[str, int] = {}
    windows_credentials: List[Dict[str, str]] = []
    server_seq = 0

    for row in flavor_rows:
        server_id = (row.get("server_id") or "").strip()
        server_name = (row.get("server_name") or server_id or "unnamed-server").strip()
        target_server_name = (
            (row.get("target_server_name") or "").strip()
            or (row.get("target_flex_vm") or "").strip()
            or server_name
        )
        flavor = (row.get("target_flavor_name") or "").strip()
        image = (row.get("recommended_target_image_name") or "").strip()
        cloud_init_user_data = decode_cloud_init_user_data((row.get("cloud_init_user_data") or ""))
        boot_strategy = (row.get("boot_strategy") or "").strip()
        needs_floating_ip = True  # Assign a public floating IP to every deployed VM, best effort.
        floating_network = (row.get("floating_network") or "").strip() or "PUBLICNET"
        is_windows = is_windows_image(image)
        auth_mode = "windows_password" if is_windows else "ssh_key"
        windows_password = ""
        include_in_deploy = row.get("include_in_deploy")
        include = True if include_in_deploy is None or include_in_deploy == "" else is_truthy(include_in_deploy)

        if not include:
            unresolved.append(
                {
                    "resource_type": "server",
                    "source_server_id": server_id,
                    "source_name": server_name,
                    "reason": "excluded_by_user",
                }
            )
            continue

        if not flavor:
            unresolved.append(
                {
                    "resource_type": "server",
                    "source_server_id": server_id,
                    "source_name": server_name,
                    "reason": "missing_target_flavor_name",
                }
            )
            continue

        if not image and not boot_strategy.startswith("boot_from_volume"):
            unresolved.append(
                {
                    "resource_type": "server",
                    "source_server_id": server_id,
                    "source_name": server_name,
                    "reason": "missing_recommended_target_image_name",
                }
            )
            continue

        if auth_mode == "ssh_key" and not key_name:
            unresolved.append(
                {
                    "resource_type": "server",
                    "source_server_id": server_id,
                    "source_name": server_name,
                    "reason": "missing_key_name_for_linux_instance",
                }
            )
            continue
        if auth_mode == "windows_password":
            if not generate_windows_passwords:
                unresolved.append(
                    {
                        "resource_type": "server",
                        "source_server_id": server_id,
                        "source_name": server_name,
                        "reason": "windows_password_generation_disabled",
                    }
                )
                continue
            windows_password = generate_windows_password(windows_password_length)

        server_seq += 1
        source_server_to_target_name[server_id] = target_server_name
        included_source_server_ids.add(server_id)
        user_data_var = f"USER_DATA_FILE_{server_seq}"
        user_data_lines: List[str] = []
        if cloud_init_user_data:
            delim = heredoc_delimiter(f"CLOUD_INIT_EOF_{server_seq}", cloud_init_user_data)
            user_data_lines.append(f'{user_data_var}=$(mktemp)')
            user_data_lines.append(f"cat > \"${user_data_var}\" <<'{delim}'")
            user_data_lines.extend(cloud_init_user_data.splitlines())
            user_data_lines.append(delim)

        # Identify Kubernetes Nodes from Stage 1 Scanner data
        is_k8s = False
        if str(row.get("is_k8s_node") or "").strip().lower() in ("true", "1", "yes", "y"):
            is_k8s = True
        elif any(k in target_server_name.lower() for k in ["k8s", "kube", "rancher", "rke", "worker-", "master-", "control-plane"]):
            is_k8s = True
            
        k8s_msg: List[str] = [f'echo "☸️ Kubernetes Node Detected: {target_server_name}. Target VM is tracked for cluster redeployment."'] if is_k8s else []

        if boot_strategy == "boot_from_volume":
            boot_size_source = to_int(row.get("boot_from_volume_size_gb") or "")
            if boot_size_source <= 0:
                unresolved.append(
                    {
                        "resource_type": "server",
                        "source_server_id": server_id,
                        "source_name": server_name,
                        "reason": "boot_from_volume_missing_size",
                    }
                )
                continue
            if not image:
                unresolved.append(
                    {
                        "resource_type": "server",
                        "source_server_id": server_id,
                        "source_name": server_name,
                        "reason": "boot_from_volume_missing_recommended_target_image_name",
                    }
                )
                continue
            image_min_disk_gb = infer_image_min_disk_gb(image)
            boot_size = max(boot_size_source, image_min_disk_gb)
            boot_vol_name = f"boot-{slugify(target_server_name)}"
            auth_arg = (
                f"--password {shell_quote(windows_password)} "
                if auth_mode == "windows_password"
                else '${KEY_NAME:+--key-name "$KEY_NAME"} '
            )
            user_data_arg = f'--user-data "${user_data_var}" ' if cloud_init_user_data else ""
            commands.extend(
                [
                    *user_data_lines,
                    *k8s_msg,
                    f'echo "Creating boot volume for {target_server_name}"',
                    (
                        "openstack volume create "
                        f"--size {boot_size} "
                        "--type \"$VOLUME_TYPE\" "
                        f"--image {shell_quote(image)} "
                        f"{shell_quote(boot_vol_name)}"
                    ),
                    f'wait_for_volume_available {shell_quote(boot_vol_name)}',
                    f'BOOT_VOL_ID=$(openstack volume show -f value -c id {shell_quote(boot_vol_name)})',
                    (
                        "openstack server create -f value -c id "
                        f"--flavor {shell_quote(flavor)} "
                        "--volume \"$BOOT_VOL_ID\" "
                        "--network \"$PRIVATE_NETWORK\" "
                        "--security-group \"$SECURITY_GROUP\" "
                        f"{user_data_arg}"
                        f"{auth_arg}"
                        f"{shell_quote(target_server_name)}"
                    ),
                    *( [f'rm -f "${user_data_var}"'] if cloud_init_user_data else [] ),
                    "",
                ]
            )
            plan.append(
                {
                    "phase": "compute",
                    "resource_type": "server",
                    "source_server_id": server_id,
                    "source_name": server_name,
                    "source_flavor_name": (row.get("source_flavor_name") or row.get("source_flavor_id") or "").strip(),
                    "resource_name": target_server_name,
                    "target_flavor_name": flavor,
                    "action": "create_server_boot_from_volume",
                    "status": "planned",
                    "reason": (
                        f"boot_volume_size_gb={boot_size},"
                        f"source_boot_size_gb={boot_size_source},"
                        f"image_min_disk_gb={image_min_disk_gb},"
                        f"auth_mode={auth_mode}"
                    ),
                }
            )
        elif boot_strategy == "boot_from_volume_required_by_target_flavor":
            unresolved.append(
                {
                    "resource_type": "server",
                    "source_server_id": server_id,
                    "source_name": server_name,
                    "reason": "target_flavor_requires_boot_volume_size_not_defined",
                }
            )
            continue
        else:
            auth_arg = (
                f"--password {shell_quote(windows_password)} "
                if auth_mode == "windows_password"
                else '${KEY_NAME:+--key-name "$KEY_NAME"} '
            )
            user_data_arg = f'--user-data "${user_data_var}" ' if cloud_init_user_data else ""
            commands.extend(
                [
                    *user_data_lines,
                    *k8s_msg,
                    f'echo "Creating server {target_server_name}"',
                    (
                        "openstack server create -f value -c id "
                        f"--flavor {shell_quote(flavor)} "
                        f"--image {shell_quote(image)} "
                        "--network \"$PRIVATE_NETWORK\" "
                        "--security-group \"$SECURITY_GROUP\" "
                        f"{user_data_arg}"
                        f"{auth_arg}"
                        f"{shell_quote(target_server_name)}"
                    ),
                    *( [f'rm -f "${user_data_var}"'] if cloud_init_user_data else [] ),
                    "",
                ]
            )
            plan.append(
                {
                    "phase": "compute",
                    "resource_type": "server",
                    "source_server_id": server_id,
                    "source_name": server_name,
                    "source_flavor_name": (row.get("source_flavor_name") or row.get("source_flavor_id") or "").strip(),
                    "resource_name": target_server_name,
                    "target_flavor_name": flavor,
                    "action": "create_server_local_boot",
                    "status": "planned",
                    "reason": f"image={image},auth_mode={auth_mode}",
                }
            )

        if needs_floating_ip:
            commands.extend(
                [
                    f'wait_for_server_active {shell_quote(target_server_name)}',
                    f"if server_has_floating_ip {shell_quote(target_server_name)}; then",
                    f'  echo "Server {target_server_name} already has a floating IP; skipping assignment."',
                    "else",
                    f"  assign_floating_ip {shell_quote(target_server_name)} {shell_quote(floating_network)}",
                    "fi",
                    "",
                ]
            )
            plan.append(
                {
                    "phase": "compute",
                    "resource_type": "floating_ip",
                    "source_server_id": server_id,
                    "resource_name": target_server_name,
                    "target_flavor_name": flavor,
                    "action": "assign_floating_ip",
                    "status": "planned",
                    "reason": f"server={target_server_name},network={floating_network}",
                }
            )

        if auth_mode == "windows_password":
            windows_credentials.append(
                {
                    "server_id": server_id,
                    "server_name": target_server_name,
                    "admin_user": windows_admin_user or "Administrator",
                    "admin_password": windows_password,
                    "image": image,
                    "boot_strategy": boot_strategy,
                }
            )

    return commands, plan, unresolved, source_server_to_target_name, included_source_server_ids, windows_credentials


def build_volume_actions(
    block_rows: List[Dict[str, str]],
    source_server_to_target_name: Dict[str, str],
    included_source_server_ids: set,
) -> Tuple[List[str], List[Dict[str, str]], List[Dict[str, str]]]:
    commands: List[str] = []
    plan: List[Dict[str, str]] = []
    unresolved: List[Dict[str, str]] = []

    counter_by_server: Dict[str, int] = {}
    for row in block_rows:
        role = (row.get("volume_role") or "").strip().lower()
        action = (row.get("target_action") or "").strip().lower()
        if role != "data" or action != "create_and_attach_volume":
            continue

        source_server_id = (row.get("source_server_id") or "").strip()
        if source_server_id and source_server_id not in included_source_server_ids:
            unresolved.append(
                {
                    "resource_type": "volume",
                    "source_server_id": source_server_id,
                    "source_name": (row.get("source_volume_name") or "").strip(),
                    "reason": "excluded_by_user",
                }
            )
            continue
        target_server_name = (row.get("target_server_name") or "").strip()
        if source_server_id in source_server_to_target_name:
            target_server_name = source_server_to_target_name[source_server_id]
        if not target_server_name:
            unresolved.append(
                {
                    "resource_type": "volume",
                    "source_server_id": source_server_id,
                    "source_name": (row.get("source_volume_name") or "").strip(),
                    "reason": "missing_target_server_name",
                }
            )
            continue

        size_gb = to_int(row.get("volume_size_gb") or "")
        if size_gb <= 0:
            unresolved.append(
                {
                    "resource_type": "volume",
                    "source_server_id": source_server_id,
                    "source_name": (row.get("source_volume_name") or "").strip(),
                    "reason": "invalid_volume_size_gb",
                }
            )
            continue

        target_device = (row.get("target_device_path") or "").strip()
        if not target_device:
            unresolved.append(
                {
                    "resource_type": "volume",
                    "source_server_id": source_server_id,
                    "source_name": (row.get("source_volume_name") or "").strip(),
                    "reason": "missing_target_device_path",
                }
            )
            continue

        counter_by_server[target_server_name] = counter_by_server.get(target_server_name, 0) + 1
        idx = counter_by_server[target_server_name]
        # Volume name explicitly matches the instance name for clear traceability
        volume_name = f"{slugify(target_server_name)}-data-{idx}"

        commands.extend(
            [
                f'wait_for_server_active {shell_quote(target_server_name)}',
                f'echo "Creating data volume {volume_name} for instance {target_server_name}"',
                f"openstack volume create --size {size_gb} --type \"$VOLUME_TYPE\" {shell_quote(volume_name)}",
                f'wait_for_volume_available {shell_quote(volume_name)}',
                f'VOL_ID=$(openstack volume show -f value -c id {shell_quote(volume_name)})',
                f'echo "Attaching volume {volume_name} to instance {target_server_name} at {target_device} (max 5 retries)"',
                (
                    f"attach_volume_with_retry "
                    f"{shell_quote(target_server_name)} "
                    f"\"$VOL_ID\" "
                    f"{shell_quote(target_device)}"
                ),
                "",
            ]
        )
        plan.append(
            {
                "phase": "storage",
                "resource_type": "volume",
                "source_server_id": source_server_id,
                "resource_name": volume_name,
                "target_flavor_name": (row.get("target_flavor_name") or "").strip(),
                "action": "create_and_attach_volume",
                "status": "planned",
                "reason": f"server={target_server_name},device={target_device},size_gb={size_gb}",
            }
        )

    return commands, plan, unresolved


def build_load_balancer_actions(
    lb_rows: List[Dict[str, str]],
    source_server_to_target_name: Dict[str, str],
    included_source_server_ids: set,
) -> Tuple[List[str], List[Dict[str, str]], List[Dict[str, str]]]:
    commands: List[str] = []
    plan: List[Dict[str, str]] = []
    unresolved: List[Dict[str, str]] = []

    grouped: Dict[str, List[Dict[str, str]]] = {}
    for row in lb_rows:
        lb_id = (row.get("load_balancer_id") or "").strip()
        lb_name = (row.get("load_balancer_name") or "").strip()
        key = lb_id or lb_name
        if not key:
            continue
        grouped.setdefault(key, []).append(row)

    for group_rows in grouped.values():
        first = group_rows[0]
        lb_name = (first.get("load_balancer_name") or "").strip()
        if not lb_name:
            lb_name = f"lb-{slugify(first.get('load_balancer_id') or 'unknown')}"
        provider = ((first.get("provider") or "").strip().lower() or "amphora")
        protocol = ((first.get("target_protocol") or "").strip().upper() or "HTTP")
        listener_port = to_int(first.get("listener_port") or "")
        member_port_default = to_int(first.get("member_port") or "")
        pool_algorithm = ((first.get("pool_algorithm") or "").strip().upper() or "ROUND_ROBIN")
        if listener_port <= 0:
            listener_port = 80
        if member_port_default <= 0:
            member_port_default = listener_port

        listener_name = f"{slugify(lb_name)}-listener"
        pool_name = f"{slugify(lb_name)}-pool"

        commands.extend(
            [
                f'echo "Ensuring load balancer {lb_name}"',
                'VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")',
                (
                    f"openstack loadbalancer show {shell_quote(lb_name)} >/dev/null 2>&1 || "
                    f"openstack loadbalancer create --name {shell_quote(lb_name)} "
                    f"--provider {shell_quote(provider)} --vip-subnet-id \"$VIP_SUBNET_ID\""
                ),
                f'wait_for_loadbalancer_active {shell_quote(lb_name)}',
                (
                    f"openstack loadbalancer listener show {shell_quote(listener_name)} >/dev/null 2>&1 || "
                    f"openstack loadbalancer listener create --name {shell_quote(listener_name)} "
                    f"--protocol {shell_quote(protocol)} --protocol-port {listener_port} {shell_quote(lb_name)}"
                ),
                f'wait_for_loadbalancer_active {shell_quote(lb_name)}',
                (
                    f"openstack loadbalancer pool show {shell_quote(pool_name)} >/dev/null 2>&1 || "
                    f"openstack loadbalancer pool create --name {shell_quote(pool_name)} "
                    f"--lb-algorithm {shell_quote(pool_algorithm)} "
                    f"--listener {shell_quote(listener_name)} --protocol {shell_quote(protocol)}"
                ),
                f'wait_for_loadbalancer_active {shell_quote(lb_name)}',
                "",
            ]
        )
        plan.append(
            {
                "phase": "load_balancer",
                "resource_type": "load_balancer",
                "source_server_id": "",
                "resource_name": lb_name,
                "target_flavor_name": "",
                "action": "create_or_reuse_lb_stack",
                "status": "planned",
                "reason": f"provider={provider},protocol={protocol},listener_port={listener_port},algorithm={pool_algorithm}",
            }
        )

        for row in group_rows:
            include_member = is_truthy(row.get("member_include_in_deploy") or "no")
            if not include_member:
                unresolved.append(
                    {
                        "resource_type": "load_balancer_member",
                        "source_server_id": (row.get("source_server_id") or "").strip(),
                        "source_name": (row.get("source_member_ip") or "").strip(),
                        "reason": (row.get("member_match_note") or "member_excluded"),
                    }
                )
                continue
            source_server_id = (row.get("source_server_id") or "").strip()
            source_server_name = (row.get("source_server_name") or "").strip()
            if source_server_id and source_server_id not in included_source_server_ids:
                unresolved.append(
                    {
                        "resource_type": "load_balancer_member",
                        "source_server_id": source_server_id,
                        "source_name": source_server_name,
                        "reason": "excluded_by_user",
                    }
                )
                continue

            target_server_name = (row.get("target_server_name") or "").strip()
            if source_server_id in source_server_to_target_name:
                target_server_name = source_server_to_target_name[source_server_id]
            if not target_server_name:
                unresolved.append(
                    {
                        "resource_type": "load_balancer_member",
                        "source_server_id": source_server_id,
                        "source_name": source_server_name or (row.get("source_member_ip") or "").strip(),
                        "reason": "missing_target_server_name",
                    }
                )
                continue

            member_port = to_int(row.get("member_port") or "")
            if member_port <= 0:
                member_port = member_port_default

            commands.extend(
                [
                    f'wait_for_server_active {shell_quote(target_server_name)}',
                    'VIP_SUBNET_ID=$(openstack subnet show -f value -c id "$SUBNET_NAME")',
                    f'MEMBER_IP=$(wait_for_instance_ip_on_network {shell_quote(target_server_name)} "$PRIVATE_NETWORK" || true)',
                    'if [ -n "$MEMBER_IP" ]; then',
                    (
                        f"  if openstack loadbalancer member list {shell_quote(pool_name)} -f value -c address 2>/dev/null | "
                        'grep -Fx "$MEMBER_IP" >/dev/null 2>&1; then'
                    ),
                    f'    echo "LB member already exists for $MEMBER_IP on pool {pool_name}"',
                    "  else",
                    (
                        f"    openstack loadbalancer member create --subnet-id \"$VIP_SUBNET_ID\" "
                        f"--address \"$MEMBER_IP\" --protocol-port {member_port} {shell_quote(pool_name)} || true"
                    ),
                    "  fi",
                    "else",
                    f'  echo "Could not resolve member IP for {target_server_name} on $PRIVATE_NETWORK; skipping member add." >&2',
                    "fi",
                    "",
                ]
            )
            plan.append(
                {
                    "phase": "load_balancer",
                    "resource_type": "load_balancer_member",
                    "source_server_id": source_server_id,
                    "resource_name": target_server_name,
                    "target_flavor_name": "",
                    "action": "ensure_lb_pool_member",
                    "status": "planned",
                    "reason": f"lb={lb_name},pool={pool_name},member_port={member_port}",
                }
            )
    return commands, plan, unresolved


def build_script(
    path: Path,
    compute_commands: List[str],
    compute_plan: List[Dict[str, str]],
    volume_commands: List[str],
    volume_plan: List[Dict[str, str]],
    lb_commands: List[str],
    lb_plan: List[Dict[str, str]],
    results_path: Path,
    resource_map_path: Path,
    args: argparse.Namespace,
) -> None:
    def split_blocks(commands: List[str]) -> List[List[str]]:
        blocks: List[List[str]] = []
        current: List[str] = []
        for line in commands:
            if line.strip() == "":
                if current:
                    blocks.append(current)
                    current = []
                continue
            current.append(line)
        if current:
            blocks.append(current)
        return blocks

    compute_blocks = split_blocks(compute_commands)
    volume_blocks = split_blocks(volume_commands)
    lb_blocks = split_blocks(lb_commands)
    if len(compute_blocks) != len(compute_plan):
        raise ValueError(
            f"Compute command block count ({len(compute_blocks)}) does not match plan count ({len(compute_plan)})."
        )
    if len(volume_blocks) != len(volume_plan):
        raise ValueError(
            f"Volume command block count ({len(volume_blocks)}) does not match plan count ({len(volume_plan)})."
        )
    if len(lb_blocks) != len(lb_plan):
        raise ValueError(
            f"Load balancer command block count ({len(lb_blocks)}) does not match plan count ({len(lb_plan)})."
        )

    planned_steps: List[Tuple[Dict[str, str], List[str]]] = []
    planned_steps.extend((row, block) for row, block in zip(compute_plan, compute_blocks))
    planned_steps.extend((row, block) for row, block in zip(lb_plan, lb_blocks))
    # Volume attachment is intentionally LAST — after all instances and LBs are created
    planned_steps.extend((row, block) for row, block in zip(volume_plan, volume_blocks))

    preflight = [
        "#!/usr/bin/env bash",
        "set -uo pipefail",
        "",
        f'PUBLIC_NETWORK={shell_quote(args.public_network)}',
        f'PRIVATE_NETWORK={shell_quote(args.private_network)}',
        f'SUBNET_NAME={shell_quote(args.subnet_name)}',
        f'SUBNET_CIDR={shell_quote(args.subnet_cidr)}',
        f'ROUTER_NAME={shell_quote(args.router_name)}',
        f'SECURITY_GROUP={shell_quote(args.security_group)}',
        f'VOLUME_TYPE={shell_quote(args.volume_type)}',
        f'KEY_NAME={shell_quote(args.key_name or "latopras")}',
        f'SSH_PUB_KEY={shell_quote(args.ssh_pub_key or "")}',
        f'FAIL_FAST={"1" if args.fail_fast else "0"}',
        f'RESULTS_CSV={shell_quote(str(results_path))}',
        f'RESOURCE_MAP_CSV={shell_quote(str(resource_map_path))}',
        "STEP_PASS=0",
        "STEP_FAIL=0",
        "STEP_IGNORED=0",
        "",
        'printf "%s\\n" "step_id,phase,resource_type,resource_name,action,status,exit_code,error" > "$RESULTS_CSV"',
        'printf "%s\\n" "source_server_id,source_name,resource_type,flex_name,flex_id,flex_private_ip,flex_floating_ip,status" > "$RESOURCE_MAP_CSV"',
        "",
        "append_resource_map() {",
        "  local src_id=\"$1\"",
        "  local src_name=\"$2\"",
        "  local res_type=\"$3\"",
        "  local flex_name=\"$4\"",
        "  local flex_id=\"$5\"",
        "  local flex_priv_ip=\"$6\"",
        "  local flex_float_ip=\"$7\"",
        "  local map_status=\"$8\"",
        "  printf '%s,%s,%s,%s,%s,%s,%s,%s\\n' \\",
        "    \"$(csv_escape \"$src_id\")\" \\",
        "    \"$(csv_escape \"$src_name\")\" \\",
        "    \"$(csv_escape \"$res_type\")\" \\",
        "    \"$(csv_escape \"$flex_name\")\" \\",
        "    \"$(csv_escape \"$flex_id\")\" \\",
        "    \"$(csv_escape \"$flex_priv_ip\")\" \\",
        "    \"$(csv_escape \"$flex_float_ip\")\" \\",
        "    \"$(csv_escape \"$map_status\")\" >> \"$RESOURCE_MAP_CSV\"",
        "}",
        "",
        "csv_escape() {",
        "  local text=\"${1:-}\"",
        "  text=${text//\\\"/\\\"\\\"}",
        "  printf '\"%s\"' \"$text\"",
        "}",
        "",
        "append_result() {",
        "  local step_id=\"$1\"",
        "  local phase=\"$2\"",
        "  local resource_type=\"$3\"",
        "  local resource_name=\"$4\"",
        "  local action=\"$5\"",
        "  local status=\"$6\"",
        "  local exit_code=\"$7\"",
        "  local error=\"$8\"",
        "  printf '%s,%s,%s,%s,%s,%s,%s,%s\\n' \\",
        "    \"$(csv_escape \"$step_id\")\" \\",
        "    \"$(csv_escape \"$phase\")\" \\",
        "    \"$(csv_escape \"$resource_type\")\" \\",
        "    \"$(csv_escape \"$resource_name\")\" \\",
        "    \"$(csv_escape \"$action\")\" \\",
        "    \"$(csv_escape \"$status\")\" \\",
        "    \"$(csv_escape \"$exit_code\")\" \\",
        "    \"$(csv_escape \"$error\")\" >> \"$RESULTS_CSV\"",
        "}",
        "",
        "run_step() {",
        "  local step_id=\"$1\"",
        "  local phase=\"$2\"",
        "  local resource_type=\"$3\"",
        "  local resource_name=\"$4\"",
        "  local action=\"$5\"",
        "  local reason=\"$6\"",
        "  local script_file output_file exit_code last_error",
        "  script_file=$(mktemp)",
        "  output_file=$(mktemp)",
        "  cat > \"$script_file\"",
        "  if ( set -euo pipefail; source \"$script_file\" ) > \"$output_file\" 2>&1; then",
        "    STEP_PASS=$((STEP_PASS + 1))",
        "    append_result \"$step_id\" \"$phase\" \"$resource_type\" \"$resource_name\" \"$action\" \"PASS\" \"0\" \"\"",
        "    cat \"$output_file\"",
        "  else",
        "    exit_code=$?",
        "    last_error=$(tail -n 1 \"$output_file\" | tr '\\r\\n' ' ' || true)",
        "    if [ \"$phase\" = \"load_balancer\" ]; then",
        "      STEP_IGNORED=$((STEP_IGNORED + 1))",
        "      append_result \"$step_id\" \"$phase\" \"$resource_type\" \"$resource_name\" \"$action\" \"IGNORED\" \"$exit_code\" \"$last_error\"",
        "      echo \"Ignoring LB step failure: $step_id phase=$phase type=$resource_type name=$resource_name action=$action reason=$reason\" >&2",
        "      cat \"$output_file\" >&2",
        "    else",
        "      STEP_FAIL=$((STEP_FAIL + 1))",
        "      append_result \"$step_id\" \"$phase\" \"$resource_type\" \"$resource_name\" \"$action\" \"FAIL\" \"$exit_code\" \"$last_error\"",
        "      echo \"Step failed: $step_id phase=$phase type=$resource_type name=$resource_name action=$action reason=$reason\" >&2",
        "      cat \"$output_file\" >&2",
        "      if [ \"$FAIL_FAST\" = \"1\" ]; then",
        "        rm -f \"$script_file\" \"$output_file\"",
        "        echo \"Fail-fast is enabled; aborting after first failed non-LB step.\" >&2",
        "        exit \"$exit_code\"",
        "      fi",
        "    fi",
        "  fi",
        "  rm -f \"$script_file\" \"$output_file\"",
        "}",
        "",
        "wait_for_volume_available() {",
        "  local volume_name=\"$1\"",
        "  local timeout=900",
        "  local interval=5",
        "  local elapsed=0",
        "  while true; do",
        "    local status",
        "    status=$(openstack volume show -f value -c status \"$volume_name\" 2>/dev/null || true)",
        "    if [ \"$status\" = \"available\" ] || [ \"$status\" = \"in-use\" ]; then",
        "      return 0",
        "    fi",
        "    if [ \"$status\" = \"error\" ] || [ \"$status\" = \"error_restoring\" ] || [ \"$status\" = \"error_extending\" ]; then",
        "      echo \"Volume $volume_name entered error status: $status\" >&2",
        "      return 1",
        "    fi",
        "    if [ \"$elapsed\" -ge \"$timeout\" ]; then",
        "      echo \"Timed out waiting for volume $volume_name to become available\" >&2",
        "      return 1",
        "    fi",
        "    sleep \"$interval\"",
        "    elapsed=$((elapsed + interval))",
        "  done",
        "}",
        "",
        "wait_for_server_active() {",
        "  local server_name=\"$1\"",
        "  local timeout=1800",
        "  local interval=5",
        "  local elapsed=0",
        "  while true; do",
        "    local status",
        "    status=$(openstack server show -f value -c status \"$server_name\" 2>/dev/null || true)",
        "    if [ \"$status\" = \"ACTIVE\" ]; then",
        "      return 0",
        "    fi",
        "    if [ \"$status\" = \"ERROR\" ]; then",
        "      echo \"Server $server_name entered ERROR state\" >&2",
        "      return 1",
        "    fi",
        "    if [ \"$elapsed\" -ge \"$timeout\" ]; then",
        "      echo \"Timed out waiting for server $server_name to become ACTIVE\" >&2",
        "      return 1",
        "    fi",
        "    sleep \"$interval\"",
        "    elapsed=$((elapsed + interval))",
        "  done",
        "}",
        "",
        "wait_for_loadbalancer_active() {",
        "  local lb_name=\"$1\"",
        "  local timeout=1800",
        "  local interval=5",
        "  local elapsed=0",
        "  while true; do",
        "    local status",
        "    status=$(openstack loadbalancer show -f value -c provisioning_status \"$lb_name\" 2>/dev/null || true)",
        "    if [ \"$status\" = \"ACTIVE\" ]; then",
        "      return 0",
        "    fi",
        "    if [ \"$status\" = \"ERROR\" ]; then",
        "      echo \"Load balancer $lb_name entered ERROR state\" >&2",
        "      return 1",
        "    fi",
        "    if [ \"$elapsed\" -ge \"$timeout\" ]; then",
        "      echo \"Timed out waiting for load balancer $lb_name to become ACTIVE\" >&2",
        "      return 1",
        "    fi",
        "    sleep \"$interval\"",
        "    elapsed=$((elapsed + interval))",
        "  done",
        "}",
        "",
        "instance_ip_on_network() {",
        "  local server_name=\"$1\"",
        "  local network_name=\"$2\"",
        "  local ports_line line ip",
        "  ports_line=$(openstack port list --server \"$server_name\" --network \"$network_name\" -f value -c \"Fixed IP Addresses\" 2>/dev/null | head -n 1 || true)",
        "  if [ -n \"$ports_line\" ]; then",
        "    ip=$(echo \"$ports_line\" | grep -Eo '([0-9]{1,3}\\.){3}[0-9]{1,3}' | head -n 1 || true)",
        "    if [ -n \"$ip\" ]; then",
        "      echo \"$ip\"",
        "      return 0",
        "    fi",
        "  fi",
        "  line=$(openstack server show \"$server_name\" -f value -c addresses 2>/dev/null | tr ',' '\\n' | sed 's/^ *//g' | grep \"^${network_name}=\" | head -n 1 || true)",
        "  ip=$(echo \"$line\" | sed -E 's/^[^=]+=([0-9.]+).*/\\1/g')",
        "  echo \"$ip\"",
        "}",
        "",
        "wait_for_instance_ip_on_network() {",
        "  local server_name=\"$1\"",
        "  local network_name=\"$2\"",
        "  local timeout=180",
        "  local interval=5",
        "  local elapsed=0",
        "  while true; do",
        "    local ip",
        "    ip=$(instance_ip_on_network \"$server_name\" \"$network_name\")",
        "    if [ -n \"$ip\" ]; then",
        "      echo \"$ip\"",
        "      return 0",
        "    fi",
        "    if [ \"$elapsed\" -ge \"$timeout\" ]; then",
        "      return 1",
        "    fi",
        "    sleep \"$interval\"",
        "    elapsed=$((elapsed + interval))",
        "  done",
        "}",
        "",
        "server_has_floating_ip() {",
        "  local server_name=\"$1\"",
        "  local out",
        "  out=$(openstack floating ip list --server \"$server_name\" -f value -c \"Floating IP Address\" 2>/dev/null || true)",
        "  [[ -n \"$(echo \"$out\" | tr -d '[:space:]')\" ]]",
        "}",
        "",
        "assign_floating_ip() {",
        "  local server_name=\"$1\"",
        "  local public_network=\"$2\"",
        "  local attempt fip",
        "  for attempt in 1 2 3; do",
        "    echo \"Floating IP attempt $attempt/3: server=$server_name network=$public_network\"",
        "    fip=$(openstack floating ip list --network \"$public_network\" --status DOWN -f value -c \"Floating IP Address\" 2>/dev/null | head -n 1 || true)",
        "    if [ -z \"$fip\" ]; then",
        "      fip=$(openstack floating ip create \"$public_network\" -f value -c floating_ip_address 2>/dev/null || true)",
        "    fi",
        "    if [ -n \"$fip\" ] && openstack server add floating ip \"$server_name\" \"$fip\"; then",
        "      echo \"Floating IP $fip attached to $server_name\"",
        "      return 0",
        "    fi",
        "    echo \"Floating IP attach failed for $server_name on attempt $attempt/3; retrying...\" >&2",
        "    sleep 5",
        "  done",
        "  echo \"WARN: Failed to attach floating IP to $server_name after 3 attempts; continuing.\" >&2",
        "  return 0",
        "}",
        "",
        "attach_volume_with_retry() {",
        "  local server_name=\"$1\"",
        "  local vol_id=\"$2\"",
        "  local device=\"$3\"",
        "  local max_retries=5",
        "  local attempt=0",
        "  local delay=10",
        "  while [ \"$attempt\" -lt \"$max_retries\" ]; do",
        "    attempt=$((attempt + 1))",
        "    echo \"Attach attempt $attempt/$max_retries: server=$server_name vol=$vol_id device=$device\"",
        "    if openstack server add volume \"$server_name\" \"$vol_id\" --device \"$device\"; then",
        "      echo \"Volume $vol_id successfully attached to $server_name at $device\"",
        "      return 0",
        "    fi",
        "    if [ \"$attempt\" -lt \"$max_retries\" ]; then",
        "      echo \"Attach failed (attempt $attempt/$max_retries); retrying in ${delay}s...\" >&2",
        "      sleep \"$delay\"",
        "    fi",
        "  done",
        "  echo \"ERROR: Failed to attach volume $vol_id to $server_name after $max_retries attempts.\" >&2",
        "  return 1",
        "}",
        "",
        'echo "Preflight checks..."',
        'openstack network show "$PUBLIC_NETWORK" >/dev/null',
        'openstack security group show "$SECURITY_GROUP" >/dev/null 2>&1 || openstack security group create "$SECURITY_GROUP" >/dev/null',
        'openstack volume type show "$VOLUME_TYPE" >/dev/null',
        'if [ -n "$KEY_NAME" ]; then',
        '  if [ -n "$SSH_PUB_KEY" ]; then',
        '    openstack keypair show "$KEY_NAME" >/dev/null 2>&1 || {',
        '      echo "Keypair $KEY_NAME not found. Creating it from provided public key..."',
        '      temp_key_file=$(mktemp)',
        '      echo "$SSH_PUB_KEY" > "$temp_key_file"',
        '      openstack keypair create --public-key "$temp_key_file" "$KEY_NAME"',
        '      rm -f "$temp_key_file"',
        '    }',
        '  else',
        '    openstack keypair show "$KEY_NAME" >/dev/null 2>&1 || {',
        '      echo "Keypair $KEY_NAME was not found in target project; continuing without --key-name." >&2',
        '      KEY_NAME=""',
        '    }',
        '  fi',
        'fi',
        "",
        'echo "PHASE 1: Network - ensuring tenant network resources..."',
        'openstack network show "$PRIVATE_NETWORK" >/dev/null 2>&1 || openstack network create "$PRIVATE_NETWORK"',
        'openstack subnet show "$SUBNET_NAME" >/dev/null 2>&1 || openstack subnet create --network "$PRIVATE_NETWORK" --subnet-range "$SUBNET_CIDR" "$SUBNET_NAME"',
        'openstack router show "$ROUTER_NAME" >/dev/null 2>&1 || openstack router create "$ROUTER_NAME"',
        'openstack router set --external-gateway "$PUBLIC_NETWORK" "$ROUTER_NAME"',
        'openstack router add subnet "$ROUTER_NAME" "$SUBNET_NAME" >/dev/null 2>&1 || true',
        "",
        'echo "PHASE 4: Compute - executing deployment steps..."',
        "",
    ]

    lines = preflight
    for idx, (row, block) in enumerate(planned_steps, start=1):
        step_id = f"step-{idx:04d}"
        phase = row.get("phase") or ""
        resource_type = row.get("resource_type") or ""
        resource_name = row.get("resource_name") or ""
        action = row.get("action") or ""
        reason = row.get("reason") or ""
        source_server_id = row.get("source_server_id") or ""
        lines.append(
            "run_step "
            f"{shell_quote(step_id)} "
            f"{shell_quote(phase)} "
            f"{shell_quote(resource_type)} "
            f"{shell_quote(resource_name)} "
            f"{shell_quote(action)} "
            f"{shell_quote(reason)} "
            "<<'STEP_EOF'"
        )
        lines.extend(block)
        lines.append("STEP_EOF")
        lines.append("")

        # ── Emit OSPC→FLEX resource mapping after each creation step ──
        if resource_type == "server" and action in ("create_server_local_boot", "create_server_boot_from_volume"):
            lines.append(f"# Map OSPC server → FLEX server")
            lines.append(f"_MAP_FLEX_ID=$(openstack server show -f value -c id {shell_quote(resource_name)} 2>/dev/null || echo \"\")")
            lines.append(f"_MAP_FLEX_PRIV=$(instance_ip_on_network {shell_quote(resource_name)} \"$PRIVATE_NETWORK\" 2>/dev/null || echo \"\")")
            lines.append(f"_MAP_FLEX_FLOAT=$(openstack floating ip list --server {shell_quote(resource_name)} -f value -c 'Floating IP Address' 2>/dev/null | head -n1 || echo \"\")")
            lines.append(f"_MAP_STATUS=\"created\"")
            lines.append(f"[ -z \"$_MAP_FLEX_ID\" ] && _MAP_STATUS=\"failed\"")
            lines.append(
                f"append_resource_map "
                f"{shell_quote(source_server_id)} "
                f"{shell_quote(resource_name)} "
                f"'server' "
                f"{shell_quote(resource_name)} "
                f"\"$_MAP_FLEX_ID\" "
                f"\"$_MAP_FLEX_PRIV\" "
                f"\"$_MAP_FLEX_FLOAT\" "
                f"\"$_MAP_STATUS\""
            )
            lines.append("")
        elif resource_type == "volume" and action == "create_and_attach_volume":
            lines.append(f"# Map OSPC volume → FLEX volume")
            lines.append(f"_MAP_VOL_ID=$(openstack volume show -f value -c id {shell_quote(resource_name)} 2>/dev/null || echo \"\")")
            vol_server = parse_server_from_reason(reason)
            lines.append(
                f"append_resource_map "
                f"{shell_quote(source_server_id)} "
                f"{shell_quote(vol_server)} "
                f"'volume' "
                f"{shell_quote(resource_name)} "
                f"\"$_MAP_VOL_ID\" "
                f"\"\" "
                f"\"\" "
                f"'created'"
            )
            lines.append("")
        elif resource_type == "load_balancer" and action == "create_or_reuse_lb_stack":
            lines.append(f"# Map OSPC LB → FLEX LB")
            lines.append(f"_MAP_LB_ID=$(openstack loadbalancer show -f value -c id {shell_quote(resource_name)} 2>/dev/null || echo \"\")")
            lines.append(f"_MAP_LB_VIP=$(openstack loadbalancer show -f value -c vip_address {shell_quote(resource_name)} 2>/dev/null || echo \"\")")
            lines.append(
                f"append_resource_map "
                f"'' "
                f"'' "
                f"'load_balancer' "
                f"{shell_quote(resource_name)} "
                f"\"$_MAP_LB_ID\" "
                f"\"$_MAP_LB_VIP\" "
                f"\"\" "
                f"'created'"
            )
            lines.append("")

    server_summary_rows = [
        row for row, _block in planned_steps
        if row.get("resource_type") == "server" and str(row.get("action") or "").startswith("create_server")
    ]
    volume_summary_count = sum(1 for row, _block in planned_steps if row.get("resource_type") == "volume")
    lb_summary_count = sum(1 for row, _block in planned_steps if row.get("resource_type") == "load_balancer")
    lines.extend(
        [
            'echo ""',
            'echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"',
            'echo "SOURCE INFRA → TARGET FLEX DEPLOY SUMMARY"',
            f'echo "Source elements planned: VMs={len(server_summary_rows)} Volumes={volume_summary_count} LoadBalancers={lb_summary_count}"',
            'printf "| %-34s | %-24s | %-34s | %-18s | %-8s |\\n" "Source VM" "Original Flavor" "Target FLEX VM" "FLEX Flavor" "Status"',
            'printf "| %-34s | %-24s | %-34s | %-18s | %-8s |\\n" "----------------------------------" "------------------------" "----------------------------------" "------------------" "--------"',
            '_SUMMARY_VM_OK=0',
            '_SUMMARY_VM_FAIL=0',
        ]
    )
    for row in server_summary_rows:
        source_name = (row.get("source_name") or row.get("source_server_id") or "-").strip()
        source_flavor = (row.get("source_flavor_name") or "-").strip()
        target_name = (row.get("resource_name") or "-").strip()
        target_flavor = (row.get("target_flavor_name") or "-").strip()
        lines.extend(
            [
                f"if openstack server show {shell_quote(target_name)} >/dev/null 2>&1; then _VM_STATUS='created'; _SUMMARY_VM_OK=$((_SUMMARY_VM_OK + 1)); else _VM_STATUS='failed'; _SUMMARY_VM_FAIL=$((_SUMMARY_VM_FAIL + 1)); fi",
                f'printf "| %-34.34s | %-24.24s | %-34.34s | %-18.18s | %-8s |\\n" {shell_quote(source_name)} {shell_quote(source_flavor)} {shell_quote(target_name)} {shell_quote(target_flavor)} "$_VM_STATUS"',
            ]
        )
    lines.extend(
        [
            'echo "Target FLEX VM count: $_SUMMARY_VM_OK created/reused, $_SUMMARY_VM_FAIL failed, total planned: '
            + str(len(server_summary_rows))
            + '"',
            'echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"',
        ]
    )

    lines += [
        'echo "Deployment script finished."',
        'echo "Step results: PASS=$STEP_PASS FAIL=$STEP_FAIL IGNORED=$STEP_IGNORED"',
        'echo "Results CSV: $RESULTS_CSV"',
        'echo "Resource mapping CSV: $RESOURCE_MAP_CSV"',
        'if [ "$STEP_FAIL" -gt 0 ]; then',
        '  echo "One or more deployment steps failed." >&2',
        "  exit 2",
        "fi",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    path.chmod(0o755)


def parse_server_from_reason(reason: str) -> str:
    text = (reason or "").strip()
    m = re.search(r"(?:^|,)server=([^,]+)", text)
    return (m.group(1).strip() if m else "")


def build_rollback_script(
    path: Path,
    compute_plan: List[Dict[str, str]],
    volume_plan: List[Dict[str, str]],
    lb_plan: List[Dict[str, str]],
    args: argparse.Namespace,
) -> None:
    server_names: List[str] = []
    boot_volume_names: List[str] = []
    data_volumes: List[Tuple[str, str]] = []
    lb_names: List[str] = []

    for row in compute_plan:
        if (row.get("resource_type") or "") != "server":
            continue
        server_name = (row.get("resource_name") or "").strip()
        if not server_name:
            continue
        server_names.append(server_name)
        if (row.get("action") or "") == "create_server_boot_from_volume":
            boot_volume_names.append(f"boot-{slugify(server_name)}")

    for row in volume_plan:
        if (row.get("resource_type") or "") != "volume":
            continue
        vol_name = (row.get("resource_name") or "").strip()
        if not vol_name:
            continue
        attached_server = parse_server_from_reason(row.get("reason") or "")
        data_volumes.append((vol_name, attached_server))

    for row in lb_plan:
        if (row.get("resource_type") or "") != "load_balancer":
            continue
        lb_name = (row.get("resource_name") or "").strip()
        if lb_name:
            lb_names.append(lb_name)

    # Reverse order for dependency-safe teardown.
    server_names = list(reversed(list(dict.fromkeys(server_names))))
    boot_volume_names = list(reversed(list(dict.fromkeys(boot_volume_names))))
    lb_names = list(reversed(list(dict.fromkeys(lb_names))))
    dedup_data: Dict[str, str] = {}
    for vol_name, server_name in data_volumes:
        dedup_data[vol_name] = server_name
    data_volumes = list(reversed([(k, v) for k, v in dedup_data.items()]))

    lines: List[str] = [
        "#!/usr/bin/env bash",
        "set -uo pipefail",
        "",
        f'PUBLIC_NETWORK={shell_quote(args.public_network)}',
        f'PRIVATE_NETWORK={shell_quote(args.private_network)}',
        f'SUBNET_NAME={shell_quote(args.subnet_name)}',
        f'ROUTER_NAME={shell_quote(args.router_name)}',
        "",
        "log() {",
        '  echo "[$(date +%H:%M:%S)] $*"',
        "}",
        "",
        "safe_run() {",
        '  echo "+ $*"',
        '  "$@" || true',
        "}",
        "",
        "resource_exists() {",
        '  local kind="$1"',
        '  local name="$2"',
        '  openstack "$kind" show "$name" >/dev/null 2>&1',
        "}",
        "",
        "delete_load_balancer() {",
        '  local lb_name="$1"',
        '  if ! resource_exists loadbalancer "$lb_name"; then',
        "    return 0",
        "  fi",
        '  log "Deleting load balancer: $lb_name"',
        '  openstack loadbalancer delete --cascade "$lb_name" >/dev/null 2>&1 || openstack loadbalancer delete "$lb_name" >/dev/null 2>&1 || true',
        "}",
        "",
        "delete_server() {",
        '  local server_name="$1"',
        '  if ! resource_exists server "$server_name"; then',
        "    return 0",
        "  fi",
        '  log "Deleting server: $server_name"',
        '  openstack server delete --wait "$server_name" >/dev/null 2>&1 || openstack server delete "$server_name" >/dev/null 2>&1 || true',
        "}",
        "",
        "detach_volume_if_needed() {",
        '  local server_name="$1"',
        '  local volume_name="$2"',
        '  [ -z "$server_name" ] && return 0',
        '  resource_exists server "$server_name" || return 0',
        '  resource_exists volume "$volume_name" || return 0',
        '  log "Detaching volume $volume_name from $server_name (if attached)"',
        '  openstack server remove volume "$server_name" "$volume_name" >/dev/null 2>&1 || true',
        "}",
        "",
        "delete_volume() {",
        '  local volume_name="$1"',
        '  if ! resource_exists volume "$volume_name"; then',
        "    return 0",
        "  fi",
        '  log "Deleting volume: $volume_name"',
        '  openstack volume delete --force "$volume_name" >/dev/null 2>&1 || openstack volume delete "$volume_name" >/dev/null 2>&1 || true',
        "}",
        "",
        "confirm_rollback() {",
        '  if [ "${ROLLBACK_AUTO_APPROVE:-0}" = "1" ]; then',
        "    return 0",
        "  fi",
        '  echo "This rollback will attempt to DELETE generated resources."',
        '  echo "Set ROLLBACK_AUTO_APPROVE=1 to skip confirmation."',
        '  if [ -t 0 ]; then',
        '    read -r -p "Type DELETE to continue: " answer',
        '    [ "$answer" = "DELETE" ] || { echo "Rollback canceled."; exit 1; }',
        "  else",
        '    echo "Non-interactive shell without ROLLBACK_AUTO_APPROVE=1; refusing to continue."',
        "    exit 1",
        "  fi",
        "}",
        "",
        "confirm_rollback",
        'log "Starting rollback..."',
        "",
    ]

    if lb_names:
        lines.append('log "Step 1/5: Delete load balancers"')
        for lb_name in lb_names:
            lines.append(f"delete_load_balancer {shell_quote(lb_name)}")
        lines.append("")

    if server_names:
        lines.append('log "Step 2/5: Delete servers"')
        for server_name in server_names:
            lines.append(f"delete_server {shell_quote(server_name)}")
        lines.append("")

    if data_volumes:
        lines.append('log "Step 3/5: Detach and delete data volumes"')
        for vol_name, server_name in data_volumes:
            if server_name:
                lines.append(f"detach_volume_if_needed {shell_quote(server_name)} {shell_quote(vol_name)}")
            lines.append(f"delete_volume {shell_quote(vol_name)}")
        lines.append("")

    if boot_volume_names:
        lines.append('log "Step 4/5: Delete boot volumes created by deploy script"')
        for vol_name in boot_volume_names:
            lines.append(f"delete_volume {shell_quote(vol_name)}")
        lines.append("")

    lines += [
        'log "Step 5/5: Delete tenant network resources"',
        'if resource_exists router "$ROUTER_NAME"; then',
        '  safe_run openstack router remove subnet "$ROUTER_NAME" "$SUBNET_NAME"',
        '  safe_run openstack router unset --external-gateway "$ROUTER_NAME"',
        '  safe_run openstack router delete "$ROUTER_NAME"',
        "fi",
        'safe_run openstack subnet delete "$SUBNET_NAME"',
        'safe_run openstack network delete "$PRIVATE_NETWORK"',
        "",
        'log "Rollback script complete."',
    ]

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    path.chmod(0o755)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate tenant-safe OpenStack deployment artifacts from mapping CSVs."
    )
    parser.add_argument("--flavor-mapping", required=True, help="Path to flavor mapping CSV (e.g., 123456_flavormap.csv).")
    parser.add_argument("--block-storage-mapping", default="", help="Optional path to block storage mapping CSV (e.g., 123456_blockmap.csv).")
    parser.add_argument("--load-balancer-mapping", default="", help="Optional path to load balancer mapping CSV (e.g., 123456_lbmap.csv).")
    parser.add_argument("--output-prefix", default="", help="Optional prefix for generated files. Defaults to <account_id>_tenant_deploy.")
    parser.add_argument("--public-network", default="PUBLICNET", help="External network name.")
    parser.add_argument("--private-network", required=True, help="Network name for private instances")
    parser.add_argument("--subnet-name", default="tenant-subnet", help="Subnet name to create/use.")
    parser.add_argument("--subnet-cidr", default="10.60.0.0/24", help="Subnet CIDR for tenant subnet.")
    parser.add_argument("--router-name", default="tenant-router", help="Router name to create/use.")
    parser.add_argument("--security-group", default="default", help="Security group to apply.")
    parser.add_argument("--volume-type", default="Performance", help="Cinder volume type for boot/data volumes.")
    parser.add_argument("--key-name", required=False, help="OpenStack Keypair name")
    parser.add_argument("--ssh-pub-key", required=False, help="Raw SSH Public Key string to auto-import if Keypair does not exist")
    parser.add_argument("--windows-password-length", type=int, default=14, help="Length for generated Windows admin passwords (12-16).")
    parser.add_argument("--windows-admin-user", default="Administrator", help="Admin username to record for generated Windows credentials.")
    parser.add_argument("--no-generate-windows-passwords", action="store_true", help="Disable generated Windows passwords; Windows instances become unresolved.")
    parser.add_argument("--fail-fast", action="store_true", help="Abort deployment script execution on first failed step.")
    parser.add_argument("--no-rollback", action="store_true", help="Do not generate a rollback shell script.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.windows_password_length < 12 or args.windows_password_length > 16:
        raise SystemExit("windows-password-length must be between 12 and 16.")
    flavor_path = Path(args.flavor_mapping).expanduser()
    if not flavor_path.exists():
        raise SystemExit(f"Flavor mapping file not found: {flavor_path}")

    block_path: Optional[Path] = None
    if args.block_storage_mapping.strip():
        block_path = Path(args.block_storage_mapping).expanduser()
    else:
        account_id = infer_account_id_from_filename(flavor_path)
        candidate = flavor_path.with_name(f"{account_id}_blockmap.csv")
        if candidate.exists():
            block_path = candidate

    lb_path: Optional[Path] = None
    if args.load_balancer_mapping.strip():
        lb_path = Path(args.load_balancer_mapping).expanduser()
    else:
        account_id = infer_account_id_from_filename(flavor_path)
        candidate = flavor_path.with_name(f"{account_id}_lbmap.csv")
        if candidate.exists():
            lb_path = candidate

    flavor_rows = read_csv(flavor_path)
    block_rows = read_csv(block_path) if block_path else []
    lb_rows = read_csv(lb_path) if lb_path else []

    compute_commands, compute_plan, compute_unresolved, source_map, included_server_ids, windows_credentials = build_server_actions(
        flavor_rows,
        (args.key_name or "latopras").strip(),
        (args.private_network or "").strip(),
        (args.ssh_pub_key or "").strip(),
        not args.no_generate_windows_passwords,
        args.windows_password_length,
        (args.windows_admin_user or "Administrator").strip(),
    )
    volume_commands, volume_plan, volume_unresolved = build_volume_actions(block_rows, source_map, included_server_ids)
    lb_commands, lb_plan, lb_unresolved = build_load_balancer_actions(lb_rows, source_map, included_server_ids)

    # Execution order: compute first, LBs next, volume attachments LAST
    plan_rows = compute_plan + lb_plan + volume_plan
    unresolved_rows = compute_unresolved + volume_unresolved + lb_unresolved

    account_id = infer_account_id_from_filename(flavor_path)
    output_prefix = args.output_prefix.strip() or f"{account_id}_tenant_deploy"
    out_base = Path.cwd() / output_prefix
    script_path = out_base.with_name(out_base.name + ".sh")
    plan_path = out_base.with_name(out_base.name + "_plan.csv")
    unresolved_path = out_base.with_name(out_base.name + "_unresolved.csv")
    results_path = out_base.with_name(out_base.name + "_results.csv")
    resource_map_path = out_base.with_name(out_base.name + "_resource_map.csv")
    rollback_path = out_base.with_name(out_base.name + "_rollback.sh")
    windows_credentials_path = out_base.with_name(out_base.name + "_windows_credentials.csv")

    build_script(script_path, compute_commands, compute_plan, volume_commands, volume_plan, lb_commands, lb_plan, results_path, resource_map_path, args)
    if not args.no_rollback:
        build_rollback_script(rollback_path, compute_plan, volume_plan, lb_plan, args)
    write_csv(
        plan_path,
        plan_rows,
        ["phase", "resource_type", "source_server_id", "resource_name", "target_flavor_name", "action", "status", "reason"],
    )
    write_csv(
        unresolved_path,
        unresolved_rows,
        ["resource_type", "source_server_id", "source_name", "reason"],
    )
    if windows_credentials:
        write_csv(
            windows_credentials_path,
            windows_credentials,
            ["server_id", "server_name", "admin_user", "admin_password", "image", "boot_strategy"],
        )

    print(f"Deployment script: {script_path}")
    if not args.no_rollback:
        print(f"Rollback script: {rollback_path}")
    print(f"Deployment plan CSV: {plan_path}")
    print(f"Unresolved CSV: {unresolved_path}")
    print(f"Expected results CSV after script run: {results_path}")
    print(f"OSPC→FLEX resource map CSV (after script run): {resource_map_path}")
    if windows_credentials:
        print(f"Windows credentials CSV: {windows_credentials_path}")
    print(f"Planned actions: {len(plan_rows)}")
    print(f"Unresolved items: {len(unresolved_rows)}")


if __name__ == "__main__":
    main()
