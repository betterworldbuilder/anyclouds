# tools/migration

Generators for migration/deploy artifacts.

Destined for this folder:
`flavor_mapper.py`, `generate_data_migration_script.py`,
`generate_project_deploy_script.py`, `generate_app_dependency_map.py`,
`fix_windows_migration.py`, `assign_ips.py`

**Wiring note:** referenced as bare argv entries in `workflow_dashboard/app.py`
(~lines 11678, 11821, 12245, 12325) with `cwd=BASE_DIR`.

> Placeholder. Files are still in the repo root; nothing has been moved yet.
> Moving them requires updating the call sites in `workflow_dashboard/app.py`.
