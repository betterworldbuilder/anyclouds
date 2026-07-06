# Dashboard Template Partials

`combined.html` is a 20-line Jinja2 shell that assembles the full dashboard from these partial files at Flask render time. Each stage and sub-stage has its own file — edit one stage without touching any other.

## How it works

```
Flask renders combined.html
  └── Jinja2 {% include %} assembles all partials at request time
  └── Browser receives one complete HTML document (identical to before the split)
  └── No JS changes required — all pane IDs, activateSub(), and event wiring unchanged
```

## Shell file

| File | Lines | Role |
|---|---|---|
| `combined.html` | 20 | Shell only — `{% include %}` directives, nothing else |
| `partials/_head_nav.html` | 2276 | `<head>`, global CSS variables, navbar, stage tabs, sub-menu buttons |
| `partials/_closing_scripts.html` | 11789 | All shared JavaScript — activateSub, stage logic, JARVIS, UAT, etc. |

---

## Stage Partials

### Pre-Stage — Why / Tour

| File | Lines | Stage | Pane ID | Description |
|---|---|---|---|---|
| `_panel_why.html` | 914 | Why Move to FLEX | `panel-s_why` | FLEX value proposition — WHO / WHAT / WHEN / WHY sections |
| `_panel_tour.html` | 432 | Quick Tour | `panel-s_tour` | Interactive 3D tour / mission control animation |

---

### Stage 0 — Discovery & Assessment Shell

| File | Lines | Stage | Pane ID | Description |
|---|---|---|---|---|
| `_panel_s0.html` | 290 | Stage 0 | `panel-s0` | OSPC Cloud mockup, quick-access dashboard portal |

---

### Stage 1 — Discovery & Assessment

`_panel_s1.html` (8 lines) is a shell that includes all Stage 1 sub-stages below.

| File | Lines | Sub-Stage | Pane ID | Description |
|---|---|---|---|---|
| `_s1_info.html` | 26 | S1 — Overview | `s1info-pane` | Stage 1 panel wrapper and overview header |
| `_s1_iframes.html` | 24 | S1 — Scanners | Various `s1*-pane` | Iframe panes: OSPC Scanner, FLEX2FLEX Scanner, Hyper-AWS/GCP/Azure scanners, TCO Dashboard, References, Flavor Mappers |
| `_s1_appdep.html` | 310 | S1 — App Dependency | `s1appdep-pane` | Application dependency mapping — Migration Log, Business Systems, topology cards |
| `_s1_readiness.html` | 50 | S1 — Readiness | `s1readiness-pane` | OSPC→FLEX migration readiness checklist |
| `_s1_preflight.html` | 60 | S1 — Preflight | `s1preflight-pane` | Pre-migration preflight checks |
| `_s1_k8s.html` | 53 | S1 — Kubernetes | `s1k8s-pane` | Kubernetes cluster inventory and assessment |
| `_s1_business_ontology.html` | 17 | S1 — Business Ontology | `s1business_ontology-pane` | Business system ontology handoff |
| `_s1_system_ontology.html` | 30 | S1 — System Ontology | `s1system_ontology_handoff-pane` | System ontology and migration handoff |

---

### Stage 2 — Migration Strategies Hub

`_panel_s2.html` (16 lines) is a shell that includes all Stage 2 sub-stages below.

| File | Lines | Sub-Stage | Pane ID | Description |
|---|---|---|---|---|
| `_panel_s2_fullmig.html` | 110 | R0 — Full Business System Rehost | `s2fullmig-pane` | Full business system migration workflow |
| `_panel_s2_migstrategy.html` | 5 | Migration Strategy | `s2migstrategy-pane` | Migration strategy overview card |
| `_panel_s2_retain.html` | 86 | R1 — Retain / Keep on OSPC | `s2retain-pane` | Keep workloads on OSPC — decommission plan |
| `_panel_s2_retire.html` | 72 | R2 — Retire / Decommission | `s2retire-pane` | Retire and decommission workflow |
| *(inline in `_panel_s2.html`)* | 6 | Iframe Panes | `s2rehost_p1`, `s2image`, `s2vmware`, `s2flex2flex`, `s2flexanywhere`, `s2rehost_p2_1` | Infrastructure Migration, VMware→FLEX, FLEX2FLEX, FLEX Anywhere, Agent (R5 Replatform) — all iframe-embedded tools |
| `_panel_s2_rehost_p2_2.html` | 252 | R6 — Rearchitect APPs | `s2rehost_p2_2-pane` | R6 Refactor / Rearchitect APPs to Containerization — full Kubernetes/container refactor workflow |
| `r6ace_pane.html` | 137 | R6 — APPS to Container Refactor Engine | `s2r6ace-pane` | 12-step domino workflow: Preflight → Input → Snapshot → Scan → Build → GitOps → OpenCenter bundle |
| `_panel_s2_opencenter.html` | 2323 | OpenCenter Migration | `s2opencenter-pane` | OpenCenter GitOps platform — Quick Start, credentials, cluster deploy, Flux, bundle import from R6 |
| `_panel_s2_repurchase.html` | 65 | R7 — Repurchase / SaaS | `s2repurchase-pane` | Replace with SaaS/managed product path |

---

### Stage 4 — Cutover & Traffic Transition

| File | Lines | Stage | Pane ID | Description |
|---|---|---|---|---|
| `_panel_s4.html` | 2801 | Stage 4 | `panel-s4` | DNS cutover, traffic transition, rollback controls, live migration status board |

---

### Stage 5 — GC Backup, DR & Restore

| File | Lines | Stage | Pane ID | Description |
|---|---|---|---|---|
| `_panel_s5.html` | 3356 | Stage 5 | `panel-s5` | Backup verification, DR plan, restore runbook, cloud-native backup tooling |

---

### Stage 5b — Business System Cutover

| File | Lines | Stage | Pane ID | Description |
|---|---|---|---|---|
| `_panel_s5b.html` | 868 | Stage 5b | `panel-s5b` | Business system cutover readiness, final sign-off checklist |

---

### Stage 6 — Handover & Deliverable

| File | Lines | Stage | Pane ID | Description |
|---|---|---|---|---|
| `_panel_s6.html` | 145 | Stage 6 | `panel-s6` | Customer handover pack, deliverables checklist, sign-off |

---

### Stage 7 — Validation & UAT

| File | Lines | Stage | Pane ID | Description |
|---|---|---|---|---|
| `_panel_s7.html` | 858 | Stage 7 | `panel-s7` | UAT test runner, DB compare, cutover readiness scanner, PASS/FIX buttons |

---

### Stage 7a — Cost Optimisation

| File | Lines | Stage | Pane ID | Description |
|---|---|---|---|---|
| `_panel_s7a.html` | 175 | Stage 7a | `panel-s7a` | TCO chart, OSPC vs FLEX cost comparison, price list upload |

---

### Stage 8 — AIOps & Continuous Operations

| File | Lines | Stage | Pane ID | Description |
|---|---|---|---|---|
| `_panel_s8.html` | 208 | Stage 8 | `panel-s8` | AIOps monitoring, continuous operations, performance telemetry |

---

### Stage 9 — AI Power Up

| File | Lines | Stage | Pane ID | Description |
|---|---|---|---|---|
| `_panel_s9.html` | 78 | Stage 9 | `panel-s9` | AI Power Up panel — includes `_ai_powerup.html` partial |

---

### Stage 10 — (Reserved)

| File | Lines | Stage | Pane ID | Description |
|---|---|---|---|---|
| `_panel_s10.html` | 23 | Stage 10 | `panel-s10` | Reserved stage — panel wrapper + panel-area close tag |

---

## Editing guide

- **Edit a single stage**: open its partial file directly — no risk of affecting any other stage
- **Add a new sub-stage to Stage 2**: create a new partial, add `{% include "partials/_new_pane.html" %}` to `_panel_s2.html`
- **Add a new top-level stage**: create a new partial, add it to `combined.html` between the correct panels
- **JavaScript**: shared JS lives in `_closing_scripts.html`; stage-specific JS lives in static files (`r6ace.js`, `ace.js`, etc.)
- **CSS**: global styles in `_head_nav.html`; stage-specific styles at the top of each partial

## Backup

Original monolithic `combined.html` (27,846 lines) is preserved at:
```
templates/backups/combined.html.bak_20260707_013959
```
