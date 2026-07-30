# AI SWITCH Stage — AI Adoption & Production Factory: Implementation Plan

Status: implemented (phase 1). Feature flag `AI_ADOPTION_FACTORY_ENABLED`.

## 1. Existing architecture (inspected)

| Concern | Finding |
|---|---|
| Entry point | `workflow_dashboard/app.py` (~25k lines, single module) |
| AI SWITCH today | `templates/_ai_powerup.html` + `templates/_ai_powerup_js.html`, 100% client-side |
| AI SWITCH state | `localStorage['ospcFlex_stage9_aiPowerUp']`, seeded from `osflex_migration_tracker` |
| AI SWITCH backend | One route, `GET /ai-powerup` — renders a template. No models, no scoring. |
| A1–A9 assessment | `templates/_ai_readiness.html`, stage id `sai_readiness` |
| Persistence | JSON files on disk, atomic `tmp` + `os.replace` (see `app.py:_save_snapshot_scan_cache`) |
| ORM / database | **None** |
| Auth | **None** (added by this change, for AI Adoption routes only) |
| Blueprints | `create_<name>_blueprint(BASE_DIR)` factory, dual import (package + flat) |
| Background jobs | `queue.SimpleQueue` + SSE streaming |
| Tests | pytest in `tests/` |

## 2. Design decisions (deltas from the original spec)

The spec describes a platform; the objective is a customer deploying their first
AI product quickly. Scope was cut to the path that produces that outcome.

| Spec | Decision |
|---|---|
| 8 entities, UUID PKs, migrations | **1 JSON document per project** (`outputs/ai_adoption/<id>.json`) with embedded components/gaps/scores. Spec field names retained so a future DB port is mechanical. No DB introduced into an app that has none. |
| 20 statuses | **6**: DRAFT → IMPORTED → ASSESSED → PLANNED → HANDED_OFF → ARCHIVED. Cut states describe events in Rackspace ops systems, not in a planning tool. |
| 24 artifact types | **6**: SOURCE, SCAN, PLAN, PASSPORT, ARCHITECTURE, HANDOFF. The rest are files inside the handoff bundle. |
| 9 import providers | **3**: GitHub, Upload (zip/notebook/LaunchPad/AI4People bundle), FLEX business system. LaunchPad + AI4People are "a zip with a manifest" — one provider, two schema validators. |
| Container / model registry / endpoint import | **Deferred** — yields metadata no plan step consumes. |
| 9 score categories × 3 weight tables | **5 scores**: value, data, security, production, operations. Weights configurable per mode. |
| 4 passports | **1** `Passport` with a `kind` field (~80% field overlap). |
| 12 reports | **1** mode-aware report in the existing 3 formats (JSON/CSV/Markdown). |
| 30 endpoints | **6** — most listed operations are computed fields of one document. |
| AI Integration Gateway (generated security middleware) | **Removed.** Generating an unaudited auth/PII/circuit-breaker proxy is a liability. Replaced by a gateway *configuration* for review. |
| Canary orchestration + live KPI capture | **Removed.** Flex Migration Hub is not in the traffic path and cannot measure success rate/latency/quality. Replaced by a canary runbook + rollback matrix in the handoff. |
| Integration codegen (stubs, tests, retry config) | **Removed.** The API→Tool→Action *mapping table* is kept — it is the Palantir input. |

Additions not in the spec:

- **Time-to-plan** recorded on every project (the actual objective is "record time").
- **NOT_CHECKED promoted into the score** — a score with unverified controls is
  reported as unverified, never as a clean pass.
- **Evidence-or-blank**: fields without evidence render blank, never a plausible default.

## 3. Security posture

Imported projects are untrusted. Enforced in `importers.py`:

- No execution of imported code — no notebook run, no `docker build`, no repo scripts.
- Archive traversal (`..`, absolute paths, symlinks) rejected.
- Per-file and per-archive size caps; extension allow-list; entry-count cap.
- Secret detection; findings recorded as redacted fingerprints, never values.
- Shallow, depth-1, read-only clone into a temp workspace, deleted after normalization.
- Tokens never persisted and never logged — only a credential *reference*.
- Every import writes an audit event.

**GitHub OAuth** (`auth.py`) gates every mutating AI Adoption route, resolving the
blocker that the dashboard has no authentication while binding `0.0.0.0`. Optional
`AI_ADOPTION_ALLOWED_LOGINS` / `AI_ADOPTION_ALLOWED_ORG` restrict access.

## 4. Module map

```
workflow_dashboard/ai_adoption/
  models.py     enums, project document, scoring weights
  store.py      atomic JSON persistence + audit log
  auth.py       GitHub OAuth login/callback/logout + @require_ai_auth
  importers.py  GitHub / Upload / FLEX providers + archive safety
  scanner.py    static discovery (frameworks, AI libs, runtimes, vector stores, IaC)
  assess.py     production gaps + 5 scores + recommendation
  generate.py   architecture + mermaid, Palantir mapping, passport, report
  routes.py     blueprint (6 endpoints + auth routes)
```

## 5. Backward compatibility

- No existing persisted field renamed or removed.
- Existing AI SWITCH localStorage flow untouched; new work is additive.
- With `AI_ADOPTION_FACTORY_ENABLED=0` the blueprint is not registered and
  AI SWITCH behaves exactly as before.
