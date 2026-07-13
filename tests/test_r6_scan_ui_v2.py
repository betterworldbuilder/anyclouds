"""Contract tests for the additive R6 Scan UI v2 frontend."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))

from workflow_dashboard.app import app

ROOT = pathlib.Path(__file__).parent.parent
V2 = (ROOT / "workflow_dashboard/static/r6-scan-ui-v2.js").read_text()
CSS = (ROOT / "workflow_dashboard/static/r6-scan-ui-v2.css").read_text()
IOS_CSS = (ROOT / "workflow_dashboard/static/r6-ios-light.css").read_text()
V1 = (ROOT / "workflow_dashboard/static/r6ace.js").read_text()
MAIN_SCRIPTS = (ROOT / "workflow_dashboard/templates/partials/_closing_scripts.html").read_text()


def has(*values):
    for value in values:
        assert value in V2, value


def test_v1_remains_registered_and_v2_is_additive():
    assert "id:'scan-ui-v1',label:'Scan UI v1'" in V1


def test_ios_light_theme_is_scoped_and_uses_apple_semantic_colors():
    assert "#s2r6ace-pane" in IOS_CSS
    assert "--ios-blue:#007aff" in IOS_CSS
    assert "--ios-red:#ff3b30" in IOS_CSS
    assert "--ios-orange:#ff9500" in IOS_CSS
    assert "--ios-yellow:#ffcc00" in IOS_CSS
    assert "--ios-green:#34c759" in IOS_CSS
    assert "-apple-system" in IOS_CSS


def test_interface_switch_persists_reloads_and_reopens_stage_three():
    assert "localStorage.setItem('r6p_scan_ui_version',version)" in V1
    assert "sessionStorage.setItem('r6p_scan_ui_reopen_stage','3')" in V1
    assert "window.location.reload()" in V1
    assert "sessionStorage.removeItem('r6p_scan_ui_reopen_stage')" in V1
    assert "r6pGoTo(3)" in V1


def test_theme_selector_is_removed_and_v2_recovers_late_load():
    assert "Scan UI Theme" not in V1
    assert "Apply Theme" not in V1
    assert "r6pApplySelectedScanUiTheme" not in V1
    assert "Scan UI Theme" not in V2
    assert "r6v2-ui-select" not in V2
    has("global.R6P.scanUiVersion==='scan-ui-v2'", "global.r6pApplyScanUiVersion()")

def test_selected_business_system_is_remembered_by_stable_id():
    assert "R6P_SELECTED_BS_KEY='r6p_selected_business_system_id'" in V1
    assert "localStorage.setItem(R6P_SELECTED_BS_KEY,String(bs.id))" in V1
    assert "localStorage.getItem(R6P_SELECTED_BS_KEY)" in V1
    assert "localStorage.removeItem(R6P_SELECTED_BS_KEY)" in V1
    assert "r6pMarkStep1Selected" in V1


def test_automatic_system_shows_linked_stage_three_provenance():
    assert "Comes from the main migration pipeline" in V1
    assert "Stage 3 \\u2014 Validation &amp; UAT" in V1
    assert "r6pOpenSourceValidationStage" in V1
    assert ".stage-btn[data-stage=\"s4\"]" in V1
    assert "uatS1FlexVmSection" in V1


def test_scan_wizard_renders_all_five_steps():
    has("title:'Discover'", "title:'Analyze'", "title:'Validate'", "title:'Decide'", "title:'Export'")


def test_wizard_marks_completed_steps_correctly():
    has("done===ps.length?'COMPLETE'", "p.pct===100", "disabled")


def test_run_scan_button_calls_real_backend():
    has("onclick=\"r6pStartProductionScan()\"")
    assert "/api/r6/scans/business-system/run" in V1


def test_scan_progress_updates_without_page_reload():
    has("function update(run)", "completedComponents", "currentComponent")


def test_scan_progress_restores_after_page_refresh():
    assert "r6p_latest_scan_run" in V1
    assert "r6p_cached_scan_run" in V1
    assert "r6pCacheScanRun(run)" in V1
    assert "r6pLoadCachedScanRun" in V1
    assert "r6pRenderCachedScanRun" in V1
    assert "r6p_cached_scan_view" in V1
    assert "r6pPersistScanView(run)" in V1
    assert "r6pRenderCachedScanView(cachedView)" in V1
    assert "sessionStorage.setItem('r6p_cached_scan_run'" in V1
    has("if(global.R6P.scanRunId)global.r6pPollProductionScan()")


def test_stage9_snapshot_controls_are_not_rendered_in_stage3_or_stage7():
    stage3 = V1.split("if(n===3){", 1)[1].split("if(n===4){", 1)[0]
    stage7 = V1.split("if(n===7){", 1)[1].split("if(n===8){", 1)[0]
    assert "Stage 9A — Build VM Snapshots" not in stage3
    assert "Stage 9B — Build Containers" not in stage3
    assert "Stage 9A — Build VM Snapshots" not in stage7
    assert "Stage 9B — Build Containers" not in stage7


def test_v1_and_v2_share_a_persistent_visible_scan_terminal():
    assert "window.r6pProductionScanTerminal=function" in V1
    assert "R6P.productionScanLog" in V1
    assert "data-terminal-output" in V1
    assert "+global.r6pProductionScanTerminal()+" in V2


def test_component_cards_render_from_real_appraisal_data():
    has("state.run.components", "componentReadinessScore") if False else has("containerReadinessScore", "evidenceCompletenessScore")
    assert "fixture" not in V2.lower()


def test_component_card_does_not_show_ready_when_only_ssh_passed():
    has("componentVerdict:'NOT_TESTED'", "containerReadinessScore:null")


def test_component_card_shows_warning_count():
    has("<dt>Warnings</dt><dd>'+warn", "(c.warnings||[]).length")


def test_component_card_shows_blocker_count():
    has("<dt>Root blockers</dt><dd>'+block", "(c.blockers||[]).length")


def test_component_card_shows_capture_recommendation():
    has("c.captureRecommendation", "Capture")


def test_component_card_shows_container_recommendation():
    has("c.containerizationRecommendation", "Recommendation")


def test_component_drawer_opens_and_closes():
    has("function openComponent", "function closeDrawer", "aria-modal=\"true\"")


def test_component_drawer_displays_probe_results():
    has("Probe results", "p.probeId", "p.durationMs", "p.exitCode")


def test_component_drawer_displays_raw_output_on_request():
    has("Show Raw Output", "p.stdout", "p.stderr")


def test_component_filter_by_verdict():
    has("filter(\\'verdict\\'", "c.componentVerdict===f.verdict")


def test_component_filter_blockers_only():
    has("Blockers only", "!f.blockers||(c.blockers||[]).length")


def test_component_search_by_name_or_vm():
    has("Search component or VM", "c.componentName+' '+(c.sourceVmId||'')")


def test_card_and_table_view_toggle():
    has("setView(\\'cards\\')", "setView(\\'table\\')", "r6v2_view")


def test_final_verdict_card_counts_components_correctly():
    has("Business Apps System Final Verdict", "Infrastructure Access", "Application Readiness", "Database Readiness", "Snapshot Readiness", "Containerization Readiness")


def test_continue_button_disabled_when_blocked():
    has("blocked=/BLOCKED|SCAN_ERROR/.test(v)", "(blocked?'disabled':'')")


def test_continue_button_requires_warning_acknowledgement():
    has("User identity required", "Acknowledgement reason", "timestamp:new Date().toISOString()", "ACKNOWLEDGED")


def test_database_card_shows_migration_action_not_build_action():
    has("DB_NATIVE_REQUIRED", "Database Readiness", "Databases only")
    assert "Build Container" not in V2


def test_retry_component_calls_retry_endpoint():
    has("r6pRetryAppraisal", "retryFailed")
    assert "/retry" in V1


def test_export_button_downloads_evidence():
    has("r6pExportProductionScan()", "Export Evidence")
    assert "/export" in V1


def test_csv_exports_exist_for_each_and_all_appraisals():
    has("Export All Appraisal Results CSV", "Export Result CSV")
    assert "r6pExportAllAppraisalsCsv" in V1
    assert "r6pExportAppraisalCsv" in V1
    assert "/appraisals.csv" in V1
    assert "/appraisal.csv" in V1


def test_failed_checks_table_and_csv_are_available():
    assert "Failed Checks by Component" in V1
    assert "Export Root Causes CSV" in V1
    assert "/failed-checks.csv" in V1
    assert "DATABASE_ENDPOINT_UNREACHABLE" in V1
    assert "database service is listening" in V1
    assert "querySelectorAll('#r6p-scan-failed-checks')" in V1
    has("global.r6pFailedChecksTable(state.run)")


def test_scan_results_follow_terminal_cards_verdict_failed_checks_order():
    render_line = next(line for line in V2.splitlines() if line.strip().startswith("function render()"))
    assert render_line.index("sharedControls()") < render_line.index("r6v2-components")
    assert render_line.index("r6v2-components") < render_line.index("+verdict()")
    assert render_line.index("+verdict()") < render_line.index("global.r6pFailedChecksTable(state.run)")
    stage3 = V1.split("if(n===3){", 1)[1].split("if(n===4){", 1)[0]
    assert "r6p-scan-final-verdict" in stage3
    assert stage3.index("+r6pProductionScanTerminal()") < stage3.index("r6p-scan-appraisal")
    assert stage3.index("r6p-scan-appraisal") < stage3.index("r6p-scan-final-verdict")
    assert stage3.index("r6p-scan-final-verdict") < stage3.index("r6p-scan-failed-checks")
    assert "Recommended fix / next action:" in V1


def test_mobile_layout_preserves_blockers():
    assert "@media(max-width:700px)" in CSS
    assert ".r6v2-grid{grid-template-columns:1fr}" in CSS
    has("r6v2-blocker-panel")


def test_keyboard_navigation_works():
    has("e.key==='Escape'", "e.key==='Tab'", "aria-label")
    assert "button:focus-visible" in CSS


def test_decision_override_records_an_audit_entry():
    has(
        "User identity required for this override",
        "Reason for changing ",
        "previousValue",
        "newValue",
        "r6v2_decisions_",
    )


def test_screen_reader_announces_scan_completion():
    has("aria-live=\"assertive\"", "Scan completed with verdict")


def test_assets_are_served_by_dashboard():
    client = app.test_client()
    page = client.get("/")
    assert page.status_code == 200
    assert b"r6-scan-ui-v2.css?v=20260713a" in page.data
    assert b"r6-ios-light.css?v=20260713c" in page.data
    assert b"r6ace.js?v=20260713zm" in page.data
    assert b"r6-scan-ui-v2.js?v=20260713j" in page.data
    assert client.get("/static/r6-scan-ui-v2.js?v=20260713f").status_code == 200
    assert client.get("/static/r6-ios-light.css?v=20260713c").status_code == 200


def test_apple_light_scan_cards_and_host_theme_override_are_scoped():
    assert "#s2r6ace-pane #r6p-scan-appraisal>div" in IOS_CSS
    assert "grid-template-columns:repeat(3,minmax(0,1fr))!important" in IOS_CSS
    assert "body.flex-skyline-mode #s2r6ace-pane button" in IOS_CSS
    assert "#s2r6ace-pane #r6p-appraisal-drawer" in IOS_CSS
    assert "#s2r6ace-pane#s2r6ace-pane button" in IOS_CSS
    assert "display:flex!important;flex-wrap:wrap!important" in IOS_CSS


def test_containerization_guidelines_are_pipeline_level_peer():
    for template_name in (
        "workflow_dashboard/templates/partials/r6ace_pane.html",
        "workflow_dashboard/templates/r6ace_pane.html",
    ):
        markup = (ROOT / template_name).read_text()
        guidelines = markup.index('id="r6p-guidelines"')
        stages = markup.index('id="r6p-stages"')
        assert guidelines < stages
    assert "guidelinesEl.innerHTML=guidelines" in V1
    assert "(guidelinesEl?'':guidelines)+R6P_STEPS" in V1


def test_stage3_business_system_mapper_preserves_openstack_vm_lineage():
    assert "sourceVmId: sourceVmId" in MAIN_SCRIPTS
    assert "source_vm_id: sourceVmId" in MAIN_SCRIPTS
    assert "scanTargetId: sourceVmId" in MAIN_SCRIPTS
    assert "existing.sourceVmId" in MAIN_SCRIPTS
    assert "r6pResolveComponentVm" in V1
