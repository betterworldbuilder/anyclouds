from services.ui.pages.cutover_plan_generator import (
    apply_app_lb_option,
    build_blue_green_scan_rows,
    build_cutover_items,
    build_cutover_plan,
    build_stage2_scanner_indexes,
    generate_cutover_commands,
    scan_rows_to_cutover_items,
)
from services.ui.pages.cutover_tester import stream_blue_green_config_action


def test_cutover_items_cover_app_and_database_targets():
    targets = [
        {
            "vm_name": "flex-web-1",
            "instance_id": "app-target-id",
            "target_ip": "10.0.0.10",
            "workload_type": "app_server",
            "source_vm_name": "legacy-web-1",
            "source_instance_id": "app-source-id",
            "source_ip": "192.0.2.10",
        },
        {
            "vm_name": "flex-orders-db",
            "instance_id": "db-target-id",
            "target_ip": "10.0.0.20",
            "workload_type": "database_server",
            "source_vm_name": "legacy-orders-db",
            "source_instance_id": "db-source-id",
            "source_ip": "192.0.2.20",
        },
    ]

    items = build_cutover_items(targets)

    assert len(items) == 2
    assert {item["cutover_area"] for item in items} == {"APP", "DB"}
    assert next(item for item in items if item["cutover_area"] == "DB")["owner"] == "DBA Team"
    assert next(item for item in items if item["cutover_area"] == "APP")["target_cutover_value"] == "10.0.0.10"


def test_cutover_plan_generates_per_target_commands():
    items = build_cutover_items([
        {
            "vm_name": "flex-orders-db",
            "target_ip": "10.0.0.20",
            "workload_type": "database_server",
            "source_ip": "192.0.2.20",
        }
    ])

    plan = build_cutover_plan(items)
    commands = generate_cutover_commands(plan["cutover_items"])

    assert plan["summary"]["database_targets"] == 1
    assert "Promote FLEX DB target 10.0.0.20" in commands
    assert "mode tcp" in commands
    assert "server green_flex 10.0.0.20" in commands


def test_app_cutover_can_generate_source_haproxy_or_source_lb_commands():
    items = build_cutover_items([
        {
            "vm_name": "flex-web-1",
            "target_ip": "10.0.0.10",
            "workload_type": "app_server",
            "source_ip": "192.0.2.10",
        }
    ])

    haproxy_plan = build_cutover_plan(apply_app_lb_option(items, "source_haproxy"))
    haproxy_commands = generate_cutover_commands(haproxy_plan["cutover_items"])
    assert "SOURCE_CUTOVER_HOST" in haproxy_commands
    assert "haproxy-blue-green.cfg" in haproxy_commands
    assert "server green_flex 10.0.0.10:80 check weight 10" in haproxy_commands

    lb_plan = build_cutover_plan(apply_app_lb_option(items, "source_lb"))
    lb_commands = generate_cutover_commands(lb_plan["cutover_items"])
    assert "SOURCE_OPENRC" in lb_commands
    assert "openstack loadbalancer create" in lb_commands
    assert "--weight 10" in lb_commands


def test_blue_green_matrix_uses_existing_stage2_scanner_tables():
    targets = [
        {
            "vm_name": "orders-web",
            "target_ip": "10.0.0.10",
            "workload_type": "app_server",
            "source_vm_name": "orders-web",
            "source_ip": "192.0.2.10",
        }
    ]
    scanner_indexes = build_stage2_scanner_indexes({
        "1342314_flavormap.csv": [
            {
                "server_name": "orders-web",
                "server_id": "src-1",
                "target_server_name": "orders-web",
                "source_image_os_distro": "linux",
            }
        ],
        "1342314_blockmap.csv": [
            {
                "source_server_name": "orders-web",
                "target_server_name": "orders-web",
                "source_volume_name": "orders-data-src",
                "target_volume_name": "orders-data-flex",
            }
        ],
        "test_app_dependencies.csv": [
            {
                "Source Hostname": "orders-web",
                "Target Hostname": "orders-db",
                "Target Stack": "Database MySQL",
                "Dependency Type": "TCP/3306",
            }
        ],
        "1342314_lbmap.csv": [
            {
                "source_server_name": "orders-web",
                "load_balancer_name": "orders-lb",
                "member_port": "80",
            }
        ],
    })

    rows = build_blue_green_scan_rows(targets, "source_lb", 80, scanner_indexes)

    assert len(rows) == 1
    row = rows[0]
    assert row["server_os"] == "linux"
    assert row["source_volume_hint"] == "orders-data-src"
    assert row["target_volume_hint"] == "orders-data-flex"
    assert row["attached_db"] == "orders-db"
    assert row["existing_lb_hint"] == "orders-lb"
    assert row["lb_method"] == "source_lb"
    assert row["source_weight"] == 20
    assert row["target_weight"] == 80

    items = scan_rows_to_cutover_items(rows)
    assert items[0]["cutover_method"] == "blue_green_source_load_balancer"
    assert "Volumes: source=orders-data-src target=orders-data-flex" in items[0]["notes"]


def test_blue_green_matrix_can_filter_source_and_target_regions():
    targets = [
        {
            "vm_name": "orders-web",
            "target_ip": "10.0.0.10",
            "target_region": "DFW",
            "workload_type": "app_server",
            "source_vm_name": "orders-web",
            "source_ip": "192.0.2.10",
            "raw": {"source_region": "IAD", "target_region": "DFW"},
        },
        {
            "vm_name": "billing-web",
            "target_ip": "10.0.1.10",
            "target_region": "ORD",
            "workload_type": "app_server",
            "source_vm_name": "billing-web",
            "source_ip": "192.0.2.20",
            "raw": {"source_region": "IAD", "target_region": "ORD"},
        },
    ]

    rows = build_blue_green_scan_rows(targets, "source_haproxy", 10, {}, "IAD", "DFW")

    assert len(rows) == 1
    assert rows[0]["source_region"] == "IAD"
    assert rows[0]["target_region"] == "DFW"
    assert rows[0]["source_server_name"] == "orders-web"


def test_cutover_commands_include_traffic_switch_steps_10_to_100():
    rows = [{
        "tier": "APP",
        "source_server_name": "orders-web",
        "source_server_ip": "192.0.2.10",
        "target_server_name": "orders-web-flex",
        "target_server_ip": "10.0.0.10",
        "lb_method": "source_haproxy",
        "source_weight": 40,
        "target_weight": 60,
        "app_port": 80,
        "health_path": "/health",
        "status": "READY WITH WARNING",
    }]

    commands = generate_cutover_commands(scan_rows_to_cutover_items(rows))

    assert "Initial generated split: FLEX 60% / source 40%." in commands
    assert "FLEX 10% / source 90%" in commands
    assert "FLEX 100% / source 0%" in commands
    assert "set server app_blue_green/green_flex weight 80" in commands


def test_cutover_commands_skip_incomplete_rows_without_placeholder_backends():
    rows = [{
        "tier": "APP",
        "source_server_name": "legacy-web",
        "source_server_ip": "",
        "target_server_name": "flex-web",
        "target_server_ip": "",
        "lb_method": "source_haproxy",
        "source_weight": 90,
        "target_weight": 10,
        "app_port": 80,
        "health_path": "/health",
        "status": "NEEDS INPUT",
    }]

    commands = generate_cutover_commands(scan_rows_to_cutover_items(rows))

    assert "[SKIP]" in commands
    assert "source and target IPs are missing" in commands
    assert "<source_ip>" not in commands
    assert "<target_ip>" not in commands
    assert 'eval "$@"' not in commands
    assert "ssh_source sudo" not in commands
    assert "server blue_source" not in commands
    assert "Generated applyable HAProxy/LB block(s): 0" in commands


def test_export_only_blue_green_config_never_applies_even_if_apply_flag_is_true():
    rows = [{
        "tier": "APP",
        "source_server_name": "orders-web",
        "source_server_ip": "192.0.2.10",
        "target_server_name": "orders-web-flex",
        "target_server_ip": "10.0.0.10",
        "lb_method": "source_haproxy",
        "source_weight": 90,
        "target_weight": 10,
        "app_port": 80,
        "health_path": "/health",
        "status": "READY WITH WARNING",
    }]

    output = "\n".join(stream_blue_green_config_action({
        "rows": rows,
        "lb_option": "source_haproxy",
        "green_weight": 10,
        "apply": True,
        "export_only": True,
        "source_cutover_host": "198.51.100.10",
    }))

    assert "Export commands only requested" in output
    assert "[DRY-RUN] run_or_print ssh_source" in output
    assert "Apply is on" not in output
    assert "[apply-lb-haproxy-config]" not in output
