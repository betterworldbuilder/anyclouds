# IaC backup / restore → GitOps pipeline

This describes how the Cloud Jumper **workflow dashboard** connects Stage 5 (bundle), Stage 7 (IaC DR / restore UI), and a **GitOps** Git repository.

## Architecture

| Step | Where it runs | What happens |
|------|----------------|--------------|
| Generate bundle | **Dashboard server** | Writes `uploads/migration_output_bundles/<customer>/<stamp>/` including `tenant-iac-dr/`. |
| Local copy on operator laptop | **Browser** | Download the ZIP / files from Stage 5 links (same origin as the app). |
| GitOps sync / commit / push | **Dashboard server** | Copies bundle slices into a **local Git clone** pointed at by env vars, then `git add` / `commit` / `tag` / optional `push`. |

The dashboard **never** pushes to `git@github.com:...` by URL alone. You must clone your GitOps repo **onto the machine that runs Flask** (or mount it) and set `GITOPS_REPO_PATH` to that directory.

Example clone (on the dashboard host):

```bash
git clone git@github.com:betterworldbuilder/iac-Gitops.git /opt/gitops/iac-Gitops
export GITOPS_REPO_PATH=/opt/gitops/iac-Gitops
```

If you run the dashboard **on your laptop**, `GITOPS_REPO_PATH` can be your laptop clone of the same repo.

## Environment variables

| Variable | Purpose |
|----------|---------|
| `GITOPS_REPO_PATH` or `IAC_BACKUP_GIT_REPO_PATH` | Absolute path to Git working tree (required for **real** push, optional for **dry run** plan). |
| `GITOPS_BRANCH` or `IAC_BACKUP_GIT_BRANCH` | Branch for commits (default `main`). |
| `GITOPS_PUSH_AFTER_COMMIT` | `true` / `1` / `yes` → run `git push` after commit. |
| `GITOPS_PUSH_REMOTE` | Remote name (default `origin`). |
| `IAC_BACKUP_S3_BUCKET` | Optional: Stage 7 **Export IaC Backup** can upload archives. |
| `GITOPS_PUBLIC_REPO_URL` | Optional: default `git_url` for **GET `/api/gitops/register-snippets`** (e.g. `https://github.com/ORG/iac-gitops.git`). |
| `GITOPS_FLUX_NAMESPACE` | Optional: Flux install namespace for snippets (default `flux-system`). |

Full operator guide (Flux install, Argo CD, templates): **`gitops/README.md`** at the repository root.

## API: `GET /api/gitops/register-snippets`

Query params: `customer`, `stamp` (optional), `git_url` (optional), `branch` (optional), `flux_namespace` (optional).

Returns JSON with rendered **Flux GitRepository**, **Flux Kustomization**, and **Argo CD Application** YAML (from `gitops/templates/*.yaml.tpl`) using the bundle path:

`customers/<customer>/bundles/<stamp>/gitops-flux-stub`

That directory is created on each **push-backup** with a valid empty `kustomization.yaml` so controllers can use `path:` immediately.

```bash
curl -sS "http://127.0.0.1:5000/api/gitops/register-snippets?customer=my-tenant&git_url=https://github.com/ORG/iac-gitops.git" | python3 -m json.tool
```

## API: `POST /api/gitops/push-backup`

JSON body (all optional except logic below):

| Field | Effect |
|-------|--------|
| `customer` | Customer id (defaults to active session customer). |
| `stamp` | Bundle stamp; empty string uses latest bundle for that customer. |
| `dry_run` | `true` → **plan only**: resolve bundle, return paths and git **intent**; **no** writes under the repo, **no** `git` commands. `GITOPS_REPO_PATH` **not required**. |
| `push` | `false` → after a **non–dry-run** sync, skip `git push` even if `GITOPS_PUSH_AFTER_COMMIT` is set (commit/tag still attempted). |

### Dry run example

```bash
curl -sS -X POST "http://127.0.0.1:5000/api/gitops/push-backup" \
  -H "Content-Type: application/json" \
  -d '{"customer":"my-tenant","stamp":"","dry_run":true}'
```

### Real push without publishing to origin

```bash
curl -sS -X POST "http://127.0.0.1:5000/api/gitops/push-backup" \
  -H "Content-Type: application/json" \
  -d '{"customer":"my-tenant","stamp":"","dry_run":false,"push":false}'
```

## Repo layout after a real push

Under `GITOPS_REPO_PATH`:

- `customers/<customer>/bundles/<stamp>/` — `tenant-iac-dr`, optional `discovery-output`, `stage2-migration-output`, `terraform`, `opencenter`, root manifest files, `BACKUP_SCOPE.md`, `gitops-backup-manifest.json`, **`gitops-flux-stub/`** (empty Kustomize root for Flux/Argo `path:`).
- `customers/<customer>/tenant-iac-dr/` — latest copy of the pack (“legacy” path in code).
- `customers/<customer>/LATEST_STAMP.txt` — stamp string.
- Git: commit on configured branch, tag `gitops-<customer>-<stamp>`, optional push.

## UI

- **Stage 5** (after Generate Bundle): download ZIP for local archive; **Push this bundle to GitOps repo** or **Dry run (plan only)**.
- **Stage 7**, Option B → Advanced: checkbox **GitOps push dry run**, buttons **Push backup** / **Dry run (plan only)**.
- **Stage 8 bridge** (“Push Recovery Pack → Continue to Stage 8”) always calls a **real** push (`dry_run: false`); it does not honor the dry-run checkbox.
- **Stage 8** “Enable GitOps on your repo”: **Generate Flux / Argo snippets** calls `GET /api/gitops/register-snippets`.

## Restore vs GitOps

**Push-backup** only lands artifacts in Git. **Restore** (Terraform / Ansible / OpenCenter prep) is separate; Flux/Argo reconcile the **`gitops-flux-stub`** path (or overlays you add) and may reference `tenant-iac-dr/` for non-K8s automation outside the controller.
