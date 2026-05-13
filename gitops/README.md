# Enable GitOps for Cloud Jumper bundle repos

This folder contains **templates** and docs to connect your GitOps repository (where `POST /api/gitops/push-backup` lands artifacts) to **Flux CD** or **Argo CD**.

## 1. Land bundles from the dashboard (prerequisite)

On the host that runs `workflow_dashboard`:

1. Clone your GitOps repo, e.g. `git clone git@github.com:ORG/iac-gitops.git /opt/gitops/iac-gitops`
2. Export `GITOPS_REPO_PATH=/opt/gitops/iac-gitops` (or `IAC_BACKUP_GIT_REPO_PATH`)
3. Optional: `GITOPS_PUSH_AFTER_COMMIT=true`, `GITOPS_BRANCH=main`
4. In the UI: Stage 5 **Generate Bundle** → **Push this bundle to GitOps repo** (or Stage 7 / API).

Each push creates / updates:

- `customers/<customer>/bundles/<stamp>/…` (including `tenant-iac-dr/`, manifests, `gitops-flux-stub/`)
- `customers/<customer>/tenant-iac-dr/` (latest pack copy)
- `customers/<customer>/LATEST_STAMP.txt`

## 2. Flux CD (Kubernetes)

1. Install Flux on the cluster: see [Flux installation](https://fluxcd.io/flux/installation/).
2. Ensure the cluster can reach your Git remote (SSH deploy key or HTTPS token).
3. Apply the **GitRepository** and **Kustomization** manifests from the dashboard **Stage 8 → Generate Flux / Argo snippets** (HTTP `GET /api/gitops/register-snippets`) or copy from `gitops/templates/` and replace placeholders.
4. Point the Flux `Kustomization` `spec.path` at:

   `customers/<customer>/bundles/<stamp>/gitops-flux-stub`

   That path contains a **valid empty `kustomization.yaml`** so Flux can reconcile immediately; add your own `HelmRelease`, `ConfigMap`, or extra Kustomize layers beside `tenant-iac-dr/` as needed.

## 3. Argo CD (Kubernetes)

1. Install Argo CD: [Getting started](https://argo-cd.readthedocs.io/en/stable/getting_started/).
2. Register a cluster and create an **Application** whose `spec.source.repoURL` / `targetRevision` / `path` match your repo (use the same `gitops-flux-stub` path or your own overlay path).
3. Use the generated snippet from Stage 8 or `gitops/templates/argocd-application.yaml.tpl`.

## 4. Public repo URL for snippet generation

Set `GITOPS_PUBLIC_REPO_URL` on the dashboard host (e.g. `https://github.com/ORG/iac-gitops.git`) so **GET `/api/gitops/register-snippets`** can default the Git URL when the UI leaves the field blank.

## Files

| File | Purpose |
|------|---------|
| `templates/flux-gitrepository.yaml.tpl` | Flux `GitRepository` |
| `templates/flux-kustomization.yaml.tpl` | Flux `Kustomization` → `gitops-flux-stub` |
| `templates/argocd-application.yaml.tpl` | Argo CD `Application` |

Placeholders: `__GIT_URL__`, `__BRANCH__`, `__CUSTOMER__`, `__STAMP__`, `__STAMP_SLUG__`, `__KUSTOMIZE_PATH__`, `__FLUX_NS__`.
