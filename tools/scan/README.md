# tools/scan

Python inventory and deep-scan tooling.

Destined for this folder:
`flexscan.py`, `ospcscan.py`, `server_deep_scan.py`,
`account_overview.py`, `analyze_win.py`

**Wiring note:** all five are called from `workflow_dashboard/app.py` via
`BASE_DIR / "<name>.py"` or `os.path.join(os.path.dirname(__file__), '..', ...)`
(see ~lines 6416, 6447, 20367, 20685). Update those on move.

> Placeholder. Files are still in the repo root; nothing has been moved yet.
> Moving them requires updating the call sites in `workflow_dashboard/app.py`.
