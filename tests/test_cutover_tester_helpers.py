from services.ui.pages.cutover_tester import (
    build_performance_config_payload,
    discover_stage2_jumphosts,
    ensure_output_dirs,
    load_cutover_tester_results,
    write_cutover_tester_evidence,
)


def test_discovers_jumphosts_from_stage2_rows():
    rows = discover_stage2_jumphosts(
        {
            "stage2_full_migration_link_map_IAD_DFW.csv": [
                {
                    "source_region": "IAD",
                    "source_vm": "IADjumphostu24",
                    "process_host_ip": "192.0.2.50",
                    "process_ssh_user": "ubuntu",
                    "process_ssh_key": "/keys/jump.pem",
                },
                {"source_region": "IAD", "source_vm": "orders-web", "source_ip": "192.0.2.10"},
            ]
        },
        include_cache=False,
        include_env=False,
    )

    assert len(rows) == 1
    assert rows[0]["region"] == "IAD"
    assert rows[0]["jumphost_ip"] == "192.0.2.50"
    assert rows[0]["status"] == "READY"


def test_performance_config_uses_selected_cutover_row_urls():
    payload = build_performance_config_payload(
        {
            "selected_row": {
                "source_server_ip": "192.0.2.10",
                "target_server_ip": "10.0.0.10",
                "app_port": 8080,
                "health_path": "/ready",
            },
            "smoke_path": "/",
            "target_concurrent_users": 25,
            "peak_concurrent_users_tested": 50,
            "requests_per_user": 5,
        }
    )

    assert payload["source_base_url"] == "http://192.0.2.10:8080"
    assert payload["target_base_url"] == "http://10.0.0.10:8080"
    assert payload["health_path"] == "/ready"
    assert payload["concurrent_users"] == 25
    assert payload["peak_concurrent_users"] == 50


def test_evidence_writes_results_table_and_csv():
    dirs = ensure_output_dirs()
    try:
        artifacts = write_cutover_tester_evidence(
            "performance-validation",
            {
                "migration_id": "mig-1",
                "source_url": "http://192.0.2.10:80",
                "target_url": "http://10.0.0.10:80",
            },
            {
                "ok": True,
                "steps": [
                    {
                        "label": "performance-validation",
                        "ok": True,
                        "result": {
                            "ospc_avg_response_ms": 100,
                            "flex_avg_response_ms": 120,
                            "ospc_p95_ms": 200,
                            "flex_p95_ms": 260,
                            "avg_response_delta": 20,
                            "p95_delta": 60,
                            "api_error_rate_percent": 0,
                            "target_concurrent_users": 10,
                            "peak_concurrent_users_tested": 25,
                            "active_sessions_tested": 10,
                            "mobile_lag_status": "Pass",
                            "performance_status": "PASS",
                            "recommendation": "Target performance is acceptable for cutover.",
                            "created_at": "2026-06-11T00:00:00+00:00",
                            "source_result": {"successful_requests": 50, "avg_response_ms": 100},
                            "target_result": {"successful_requests": 50, "avg_response_ms": 120},
                        },
                    }
                ],
            },
        )
        table = load_cutover_tester_results()

        assert "outputs/cutover/cutover_tester_results.csv" in artifacts
        assert table["rows"][0]["performance_status"] == "PASS"
        assert table["rows"][0]["cutover_gate"] == "APPROVED"
    finally:
        for base in (dirs["cutover"], dirs["tmp"]):
            for name in (
                "cutover_tester_evidence.json",
                "cutover_tester_evidence.jsonl",
                "cutover_tester_results.json",
                "cutover_tester_results.csv",
            ):
                path = base / name
                if path.exists():
                    path.unlink()
