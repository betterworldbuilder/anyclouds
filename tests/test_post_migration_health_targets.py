from services.ui.pages.post_migration_health_validation import (
    build_health_validation_targets,
    build_uat_checkpoints,
    run_health_validation_dry_run,
)


def test_build_health_validation_targets_imports_full_migration_rows():
    stage2_data = {
        "uploads/stage2_full_migration_link_map_latest.csv": [
            {
                "source_server_id": "src-app-1",
                "source_vm": "legacy-app-1",
                "target_server_name": "flex-app-1",
                "target_region": "DFW",
                "status": "ready",
            }
        ],
        "customer_tenant_deploy_resource_map.csv": [
            {
                "source_server_id": "src-db-1",
                "source_name": "legacy-postgres-db",
                "resource_type": "server",
                "flex_name": "flex-postgres-db",
                "flex_id": "flex-db-id",
                "flex_private_ip": "10.20.30.40",
                "status": "ACTIVE",
            }
        ],
    }

    targets = build_health_validation_targets(stage2_data)

    assert {target["vm_name"] for target in targets} == {"flex-app-1", "flex-postgres-db"}
    db_target = next(target for target in targets if target["vm_name"] == "flex-postgres-db")
    assert db_target["instance_id"] == "flex-db-id"
    assert db_target["target_ip"] == "10.20.30.40"
    assert db_target["workload_type"] == "database_server"


def test_database_targets_require_explicit_db_validation_evidence():
    targets = build_health_validation_targets({
        "resource_map.csv": [
            {
                "source_name": "orders-db",
                "flex_name": "orders-db-flex",
                "flex_private_ip": "10.0.0.15",
                "resource_type": "server",
                "status": "ACTIVE",
            }
        ]
    })

    results = run_health_validation_dry_run(targets)

    assert results[0]["checks"]["database"]["status"] == "NEEDS INPUT"
    assert results[0]["overall_status"] == "NOT READY"


def test_uat_checkpoints_include_frontend_api_and_db_tiers():
    app_checkpoints = build_uat_checkpoints({
        "vm_name": "flex-web-1",
        "target_ip": "10.0.0.10",
        "workload_type": "app_server",
    })
    db_checkpoints = build_uat_checkpoints({
        "vm_name": "flex-orders-db",
        "target_ip": "10.0.0.20",
        "workload_type": "database_server",
    })

    assert {"frontend", "api"}.issubset({checkpoint["tier"] for checkpoint in app_checkpoints})
    assert {checkpoint["tier"] for checkpoint in db_checkpoints} == {"database"}
    assert any(checkpoint["checkpoint_id"] == "db-stage2-migration-result" for checkpoint in db_checkpoints)
