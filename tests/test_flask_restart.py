import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))

import workflow_dashboard.app as dashboard


def test_restart_flask_endpoint_is_suppressed_under_testing():
    dashboard.app.config["TESTING"] = True
    try:
        resp = dashboard.app.test_client().post("/api/dev/restart-flask")
        data = resp.get_json()
        assert resp.status_code == 200
        assert data["ok"] is True
        assert data["restart"] == "suppressed-for-test"
    finally:
        dashboard.app.config["TESTING"] = False


def test_restart_flask_endpoint_is_localhost_only():
    dashboard.app.config["TESTING"] = True
    try:
        resp = dashboard.app.test_client().post("/api/dev/restart-flask", environ_base={"REMOTE_ADDR": "10.0.0.5"})
        assert resp.status_code == 403
        assert resp.get_json()["ok"] is False
    finally:
        dashboard.app.config["TESTING"] = False


def test_restart_hotkey_button_is_wired_in_r6_ui():
    script = (pathlib.Path(__file__).parent.parent / "workflow_dashboard" / "static" / "r6ace.js").read_text()
    assert "r6p-flask-restart-panel" in script
    assert "Ctrl + Shift + R opened this panel" in script
    assert "r6pRestartFlask" in script
    assert "fetch('/api/dev/restart-flask'" in script
    assert "e.ctrlKey&&e.shiftKey" in script
    assert "toLowerCase()==='r'" in script
