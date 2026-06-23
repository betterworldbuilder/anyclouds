from generate_project_deploy_script import build_server_actions
from validate_migration_inputs import validate


def _flavor_row(server_id: str, target_server_name: str) -> dict:
    return {
        "server_id": server_id,
        "server_name": "shared-source-name",
        "target_server_name": target_server_name,
        "include_in_deploy": "yes",
        "target_flavor_name": "gp.5.2.4",
        "recommended_target_image_name": "Ubuntu 24.04",
        "boot_strategy": "local_boot",
        "boot_from_volume_size_gb": "",
    }


def test_duplicate_source_names_are_valid_when_target_names_are_unique():
    findings, error_count = validate(
        [
            _flavor_row("src-1", "shared-source-name-a"),
            _flavor_row("src-2", "shared-source-name-b"),
        ],
        [],
    )

    codes = {finding["code"] for finding in findings}
    assert error_count == 0
    assert "duplicate_server_name" not in codes
    assert "duplicate_target_server_name" not in codes


def test_deploy_generator_uses_target_server_name_for_vm_resources():
    rows = [
        _flavor_row("src-1", "shared-source-name-a"),
        _flavor_row("src-2", "shared-source-name-b"),
    ]

    _, plan, unresolved, source_map, _, _ = build_server_actions(
        rows,
        key_name="flex-key",
        private_network="tenant-net",
        ssh_pub_key="",
        generate_windows_passwords=True,
        windows_password_length=14,
        windows_admin_user="Administrator",
    )

    server_resources = [
        row["resource_name"]
        for row in plan
        if row["resource_type"] == "server"
    ]
    assert server_resources == ["shared-source-name-a", "shared-source-name-b"]
    assert source_map == {
        "src-1": "shared-source-name-a",
        "src-2": "shared-source-name-b",
    }
    assert unresolved == []
