# tools/validation

Pre-flight and post-deploy validation.

Destined for this folder:
`validate_migration_inputs.py`, `verify_post_deploy.py`, `ospc_auth_test.py`,
`test_all_ssh.py`, `ping_ssh_ips.py`, `test_flexscan_py.py`

**Wiring note:** `verify_post_deploy.py` is run as a bare relative path
(`app.py` ~line 12816); `validate_migration_inputs.py` ~line 11718.

> Placeholder. Files are still in the repo root; nothing has been moved yet.
> Moving them requires updating the call sites in `workflow_dashboard/app.py`.
