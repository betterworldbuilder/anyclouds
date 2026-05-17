# Local Knowledge Base

This folder stores project-local known-good references.

## Working Scripts Baseline

 contains backups of the currently working migration scripts:

- Linux VM/image migration
- Windows snapshot migration
- Volume snapshot migration
- Shared offline repair helpers
- Glance/Cloud Files bridge helper

Rules:

- Check this baseline before changing migration logic.
- Reuse working script patterns when creating or fixing features.
- Do not overwrite these backups unless explicitly requested.
- If a migration breaks, compare current scripts against this baseline first.
- Use ICF for debugging: Issue, Cause, Fix.
