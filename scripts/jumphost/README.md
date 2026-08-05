# scripts/jumphost

Jumphost provisioning, health and probe scripts.

Destined for this folder:
`check_jumphost.sh`, `setup_jumphost_volume.sh`, `monitor_jumphost_nbd_jobs.sh`,
`run_jh_glance_probe.sh`, `run_jh_task_api_test.sh`, `run_jh_task_create_test.sh`,
`tmp_glance_probe.sh`

**Wiring note:** `check_jumphost.sh` is invoked by an absolute path in
`workflow_dashboard/app.py` (~line 20122) — that path must be updated on move.

> Placeholder. Files are still in the repo root; nothing has been moved yet.
> Moving them requires updating the call sites in `workflow_dashboard/app.py`.
