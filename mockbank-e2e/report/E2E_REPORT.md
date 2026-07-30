# MockBank E2E v2 — 3-Tier App Deployed Through the REAL OpenCenter CLI · PASS

**Date:** 2026-07-19 · **Result: PASS** — frontend + API + PostgreSQL on a 3-node Kind cluster, bootstrapped end-to-end by the **real `opencenter` CLI 1.0.0-rc03** (built from source with mise; no mock shim).

## v2 pipeline (all real)
1. **CLI install**: `mise install && mise run build` from openCenter-cli repo → `opencenter 1.0.0-rc03` + `opencenter-local` plugin in `~/.local/bin`.
2. **App**: bank-api 2.0.0 now speaks PostgreSQL via `DATABASE_URL` (SQLite fallback for dev); new `bank-db` tier: postgres:16-alpine + PVC + Secret ([refactor/k8s/bank-db.yaml](../refactor/k8s/bank-db.yaml)).
3. **Build + Docker 3-tier smoke**: both images built; postgres + api on a docker network — health `{"db":"postgresql","db_reachable":true}`, $55 transfer persisted.
4. **Real CLI deploy** (`e2e_v2.sh deploy`): `gitea up` (real Gitea container, TLS, tokens, attached to kind network) → `cluster init --type kind` → `cluster set` gitops/auth → `validate` (26/26) → `generate` (80 manifests) → `deploy --container-runtime docker`: kind-create (3 nodes) → kubeconfig-export → gitea-attach → gitea-rebase → gitops-push → flux-verify → **Cluster ready at https://127.0.0.1:6443**.
5. **Appload**: images side-loaded to all 3 nodes; app manifests into `applications/overlays/mockbank/managed-services/mockbank/`; applied + rolled out (db 1/1, api 2/2, frontend 1/1).
6. **Verify**: $77.25 transfer via frontend→api→postgres; **4/4 consistent reads across both api replicas**; balances updated exactly (2422.75 / 1277.75). The v1 SQLite replica-drift bug is gone — proving the R6 externalization rule.

## Real-CLI findings (fixes applied)
| Finding | Root cause | Fix |
|---|---|---|
| `opencenter local` unknown | `local` is the separate `opencenter-local` plugin binary | installed plugin to PATH |
| Gitea port 3000 bind failure | **stale Windows portproxy** `0.0.0.0:3000 → 172.17.10.162` (dead WSL IP; deleting needs admin) | patched plugin `DefaultSettings` to 3300/3301/2322 and fixed a hardcoded `%d:3001` container mapping in [gitea/service.go](../../openCenter-cli/internal/localdev/gitea/service.go); rebuilt both binaries |
| `cluster set opencenter.gitops.git_url` rejected | docs use a newer schema; rc03 wants `opencenter.gitops.repository.url` + `opencenter.gitops.auth.token.token_file` + `auth.token.provider` | dashboard Kind commands updated to rc03 schema (ocqs/ocqp K3 + r6ace Stage 12) |
| validate fail: keycloak admin password | keycloak enabled by default | `cluster set secrets.keycloak.admin_password=…` |
| deploy blocked on CHANGEME stubs | headlamp OIDC + loki/tempo S3 secrets | `cluster set secrets.{headlamp,loki,tempo}.…` then `generate --force` (quickstart step 6 is real) |
| GitOps push of app rejected | CLI security hook: plaintext K8s Secret must be SOPS-encrypted | demo used kubectl-apply stand-in; production: SOPS-encrypt `bank-db-credentials` |

Re-run: `bash mockbank-e2e/e2e_v2.sh all` · Full log: `report/e2e_v2.log` · Cluster left running (`opencenter cluster destroy mockbank-org/mockbank` or `kind delete cluster --name mockbank`).

---

# (v1, superseded) MockBank E2E Test Report — FLEX app → R6 Refactor → Docker → Kind → OpenCenter Deploy

**Date:** 2026-07-19 · **Result: PASS (all 5 phases)**
Everything real except the `opencenter` CLI itself, which is not installed on this host and was **mocked** by a shim (`~/.local/bin/opencenter`, source: `mockbank-e2e/bin/opencenter`) that implements the exact subcommands the dashboard's Kind flow generates, backed by **real** kind / kubectl / flux / git.

## What was tested

| Phase | What ran | Real or mock | Result |
|---|---|---|---|
| 1. Setup | kind v0.32.0 installed to ~/.local/bin; opencenter shim installed | real / mock CLI | PASS |
| 2. Refactor | **Real** dashboard backend `POST /api/r6/generate-bundle` on :5091 → 22-artifact ACE bundle (`~/.config/opencenter/bundles/r6/mockbank-mobile-banking-*`) | real | PASS |
| 3. Build | `docker build` of `mockbank/bank-api:1.0.0` + `mockbank/bank-frontend:1.0.0` from refactor Dockerfiles; docker-run smoke: /health, /api/accounts, $100 transfer | real | PASS |
| 4. Deploy | Dashboard's Kind command sequence: `local gitea up` → `cluster init --type kind` → `use` → `set git_url/git_token/git_token_provider=gitea` → `validate` (5/5 checks) → `generate` (GitOps tree + git commit + push) → `deploy --container-runtime docker` (kind create 18s → kubeconfig export → gitea attach → **real flux install** → `kind load` both images → apply + rollout) | real infra, mock CLI | PASS |
| 5. Verify | Node Ready (v1.36.1); 4 flux-system pods Running; 3 mockbank-prod pods Running; frontend HTTP 200; accounts listed and **$42.50 in-cluster transfer OK** through nginx→bank-api proxy; GitOps commit `45e2949` pushed | real | PASS |

## Validation gate proved itself
First refactor call was **BLOCKED** by the engine: `startCommand not set` on both components (Live Scan skipped). After supplying start commands + `persistentPath: None - stateless` the gate returned `PASSED_WITH_WARNINGS`, blockers = 0. The gate works as designed.

## Best find: the state-externalization warning is real
`bank-api` runs **2 replicas**, each with its own embedded SQLite. A transfer succeeded on one replica but `/api/transactions` (and stale balances) can be served by the other. This is precisely the R6 warning (`persistentPath` / ExternalDB classification): **stateful data must be externalized (operator-managed PostgreSQL / external DB) before scaling containerized workloads**. The mock deliberately kept SQLite embedded; production remediation is in the bundle's `container-externalization-contract.json`.

## Artifacts
- App source: `mockbank-e2e/src/` (Flask API + mobile web frontend)
- Refactor output: `mockbank-e2e/refactor/` (Dockerfiles, k8s, kustomize, import manifest with `deployTarget: kind`)
- ACE bundle (real engine): `~/.config/opencenter/bundles/r6/mockbank-mobile-banking-20260719_161506/`
- GitOps repo: `~/.config/opencenter/clusters/gitops/mockbank-org/` (pushed to mock Gitea `~/.config/opencenter/mock-gitea/test-repo.git`)
- Full log: `mockbank-e2e/report/e2e.log`
- Re-run: `bash mockbank-e2e/e2e_run.sh all` (or per phase: setup|refactor|build|deploy|verify)

## Cleanup / notes
- Kind cluster `mockbank` is left **running** (`kind delete cluster --name mockbank` or `opencenter cluster destroy mockbank --force` to remove).
- The shim also makes the dashboard's Kind-band **Run buttons** work end-to-end (the Flask process must have `~/.local/bin` on PATH).
- To test against the **real** OpenCenter CLI later: `rm ~/.local/bin/opencenter` and install the real binary — the command sequence is identical.
