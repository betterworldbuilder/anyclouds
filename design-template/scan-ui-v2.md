CODEX FULL UI UPDATE INSTRUCTION
User-Friendly R6 Component Scan Appraisal Interface

Redesign the existing R6 live-scan and component-appraisal interface so it is simple to understand, fast to operate, and suitable for production users.

Do not change the existing backend scan logic, canonical statuses, component verdicts, scoring rules, or API contracts unless required for UI integration.

The interface must guide the user through this flow:

Discover
→ Analyze
→ Validate
→ Decide
→ Export

======================================================================
1. MAIN PAGE LAYOUT
======================================================================

Create a responsive three-area layout:

1. Top header
2. Main content area
3. Optional sticky summary rail

The top header must show:

- Business System name
- Source environment
- Target environment
- Last scan time
- Overall evidence score
- Overall readiness score
- Final verdict
- Run Scan button
- Stop button while running
- Retry Failed button after completion
- Export Evidence button

Example:

Bank Mobile Transformation
Source: FLEX Production
Target: OpenCenter Staging

Evidence: 86%
Readiness: 78%
Verdict: READY FOR STAGE 8 WITH WARNINGS

[Run Full Scan] [Retry Failed] [Export Evidence]

======================================================================
2. WIZARD NAVIGATION
======================================================================

Add a horizontal wizard directly below the header.

Use these five steps:

1. Discover
2. Analyze
3. Validate
4. Decide
5. Export

Each step must show:

- step number
- title
- status icon
- short summary
- completion percentage

Step meaning:

Discover:
VM connectivity, host identity, runtime, services, processes and ports.

Analyze:
Application paths, configuration, storage, writable paths and dependencies.

Validate:
Health tests, secret checks, persistence checks and container constraints.

Decide:
Component verdicts, capture recommendations and Stage 8 recommendations.

Export:
Reports, evidence packages and final appraisal.

Wizard statuses:

PENDING
RUNNING
COMPLETE
WARNING
BLOCKED

Allow the user to navigate to completed steps.

Do not allow navigation to a later step when required earlier evidence is missing.

======================================================================
3. BUSINESS SYSTEM FINAL VERDICT CARD
======================================================================

Place the Business System Final Verdict card at the top of the main content area.

The card must immediately answer:

- Is the system ready?
- How many components passed?
- What is blocked?
- What should the user do next?

Show:

Business Apps System Scan Appraisal

- Source VMs scanned
- Logical components discovered
- Ready components
- Ready with warnings
- Database-native components
- Retained-VM components
- Needs review
- Blocked
- Scan failures
- Overall evidence score
- Overall readiness score
- Final verdict
- Recommended next action

Example:

6 components discovered
2 ready
2 ready with warnings
1 database-native
1 needs review
0 blocked

Final verdict:
READY FOR STAGE 8 WITH WARNINGS

Next action:
Review two warnings, then continue to classification.

Add actions:

[Review Warnings]
[Review Blockers]
[Continue to Classification]

Disable Continue to Classification when verdict is:

BLOCKED
SCAN_FAILED

Allow continuation with explicit acknowledgement when verdict is:

READY_FOR_STAGE_8_WITH_WARNINGS
PARTIALLY_READY
MANUAL_REVIEW_REQUIRED

======================================================================
4. COMPONENT CARD GRID
======================================================================

Display one card per logical component.

Use a responsive grid:

- 3 columns on large screens
- 2 columns on medium screens
- 1 column on small screens

Each card must show only the most important information by default.

Card header:

- Component name
- Source VM
- Canonical verdict chip
- Readiness score
- Evidence score

Card summary:

- Runtime
- Services
- Ports
- Dependencies
- Persistence
- Health
- Secret safety
- Capture recommendation
- Containerization recommendation
- Warning count
- Blocker count

Example:

Core Banking Backend
VM: core-bank-01

Verdict: READY WITH WARNINGS
Readiness: 78%
Evidence: 86%

Runtime: Python 3.12
Services: 1 detected
Ports: 8102
Dependencies: 3 resolved, 1 unresolved
Persistence: None detected
Health: Not confirmed
Secrets: Passed
Capture: Live + Snapshot
Recommendation: Candidate with remediation

1 warning
0 blockers

[View Appraisal] [View Evidence] [Retry]

Do not show raw logs on the card.

======================================================================
5. CARD VISUAL STATES
======================================================================

Use a consistent status system everywhere.

PASS:
Green

WARNING:
Amber

PARTIAL:
Amber

FAIL:
Red

BLOCKED:
Red

RUNNING:
Blue

PENDING:
Grey

NOT_TESTED:
Grey

DB_NATIVE_REQUIRED:
Blue

RETAIN_VM_RECOMMENDED:
Purple

Do not color the whole card green because SSH succeeded.

Use a colored left border or small status badge instead of large solid backgrounds.

Always include text labels with colors for accessibility.

======================================================================
6. COMPONENT DETAIL DRAWER
======================================================================

Clicking View Appraisal must open a right-side drawer.

The drawer must contain collapsible sections:

1. Summary
2. Probe results
3. Processes
4. Services and startup commands
5. Runtime
6. Ports
7. Application paths
8. Configuration
9. Secrets
10. Dependencies
11. Storage
12. Writable paths
13. Persistent paths
14. Health checks
15. Container constraints
16. Licensing
17. Capture recommendation
18. Stage 8 recommendation
19. Warnings
20. Blockers
21. Remediation

Keep sections collapsed by default except Summary, Warnings and Blockers.

Each probe row must show:

- Probe ID
- Probe title
- Status
- Short result
- Duration
- Exit code
- Truncated status
- Evidence link
- Remediation

Provide a Show Raw Output action inside the probe details.

Do not display raw shell output automatically.

======================================================================
7. FILTERS AND SEARCH
======================================================================

Add a compact filter bar above the component grid.

Include:

- Search by component or VM
- Filter by verdict
- Filter by runtime
- Filter by capture mode
- Filter by recommendation
- Show blockers only
- Show warnings only
- Show databases only
- Sort by readiness
- Sort by risk
- Sort by component name

Default ordering after scan completion:

1. Blocked
2. Manual review
3. Needs more evidence
4. Ready with warnings
5. Database-native
6. Retain VM
7. Ready

======================================================================
8. STICKY SUMMARY RAIL
======================================================================

On large screens, add a sticky right-side summary rail.

Show:

- Current wizard step
- Scan progress
- Current component being processed
- Overall verdict
- Highest-risk components
- Top warnings
- Top blockers
- Recommended next action

Example:

Current step:
Validate

Progress:
14 of 20 probes complete

Top issue:
API Gateway health endpoint not confirmed

Next action:
Retry health probe or approve warning

Add:

[Explain Verdict]
[Show Blockers]
[Show Next Action]

Hide or collapse the rail on small screens.

======================================================================
9. SCAN PROGRESS EXPERIENCE
======================================================================

During a scan, show:

- overall progress bar
- VMs completed
- components discovered
- probes completed
- current VM
- current component
- current probe
- elapsed time

Example:

Scanning FLEX Business System

VMs: 4 of 6
Components: 5 discovered
Probes: 67 of 120

Current:
Core Banking Backend
Probe: Outbound Dependency Discovery

[Stop Scan]

Update progress through polling or streaming.

Do not freeze the page while scanning.

Preserve progress after page refresh.

======================================================================
10. QUICK APPRAISAL VIEW
======================================================================

Add a compact table view toggle beside the card-grid toggle.

Table columns:

- Status
- Component
- Source VM
- Runtime
- Readiness
- Evidence
- Health
- Persistence
- Capture mode
- Recommendation
- Warnings
- Blockers
- Action

The user must be able to switch between:

Cards
Table

Preserve the selected view in browser storage.

======================================================================
11. WARNINGS AND BLOCKERS EXPERIENCE
======================================================================

Create separate summary panels for warnings and blockers.

Blocker panel:

- blocker code
- component
- reason
- affected stage
- exact remediation
- retry action

Warning panel:

- warning code
- component
- reason
- impact
- recommended action
- acknowledgement action when allowed

Warning acknowledgement must require:

- user identity
- reason
- timestamp

Do not allow warnings to disappear after acknowledgement.

Mark them as:

ACKNOWLEDGED

======================================================================
12. DECISION EXPERIENCE
======================================================================

Inside the Decide wizard step, show one decision row per component.

Columns:

- Component
- Scan verdict
- Recommended target
- Capture mode
- Risk
- Evidence confidence
- User decision
- Approval state

Recommended targets include:

CONTAINERIZE
PARTIALLY_CONTAINERIZE
DEPLOY_OPERATOR
RETAIN_FLEX_VM
REDEPLOY_FLEX_VM
CONNECT_EXTERNAL_SERVICE
MIGRATE_DATA_SEPARATELY
MANUAL_REVIEW
BLOCKED
EXCLUDE

Allow override only with:

- user identity
- reason
- timestamp
- previous value
- new value

Visually distinguish:

System recommendation
User-approved decision

Do not automatically create snapshots from this page.

Stage 9 must create snapshots only after the final Stage 8 decision is approved.

======================================================================
13. DATABASE COMPONENT EXPERIENCE
======================================================================

Database components must use a different card style.

Show:

- database product
- version
- port
- data directory
- approximate data size
- replication mode
- backup mechanism
- migration recommendation

Verdict:

DB_NATIVE_REQUIRED

Recommended actions:

- Retain VM
- Operator-managed migration
- External managed database
- Native dump and restore
- Replication

Do not show Build Container as the primary action for database components.

Show:

[View Migration Plan]

======================================================================
14. RESULT EXPLANATIONS
======================================================================

Every score and verdict must have an explanation tooltip or info drawer.

Evidence score explanation:

“How complete and reliable the collected runtime evidence is.”

Readiness score explanation:

“How suitable the component is for containerization after applying risks and blockers.”

Final verdict explanation:

“The overall ability of the complete Business Apps System to continue to classification and transformation.”

Do not show unexplained percentages.

======================================================================
15. EMPTY, LOADING AND ERROR STATES
======================================================================

Before scan:

No scan results yet.

Run a live scan to discover application components, dependencies,
storage and containerization constraints.

[Run Full Scan]

While loading:

Use skeleton cards.

On API error:

Show:

Scan data could not be loaded.

[Retry]

When no components are found:

No application components were detected.

Review VM selection, SSH access and scanner permissions.

Do not show an empty blank page.

======================================================================
16. ACCESSIBILITY
======================================================================

Implement:

- keyboard navigation
- visible focus states
- semantic headings
- ARIA labels
- screen-reader status announcements
- non-color status indicators
- accessible dialogs and drawers
- escape key closes drawer
- tab focus stays inside open drawer
- minimum accessible contrast
- responsive text sizes

All actions must be usable without a mouse.

======================================================================
17. RESPONSIVE DESIGN
======================================================================

Desktop:

- wizard at top
- component grid in center
- sticky summary rail on right

Tablet:

- two-column component grid
- summary rail collapses into top panel

Mobile:

- one-column cards
- horizontally scrollable wizard
- bottom action bar for Run, Retry and Export
- drawer becomes full-screen sheet

Do not hide essential warnings or blockers on mobile.

======================================================================
18. PERFORMANCE
======================================================================

Implement:

- lazy loading for raw evidence
- pagination or virtualization for large probe tables
- polling only while scan is active
- stop polling after terminal result
- local caching of latest summaries
- debounce search input
- avoid rerendering all component cards on one progress update

Target:

- initial screen usable within 2 seconds on normal internal networks
- component card interactions respond within 200 milliseconds
- large raw logs loaded only when requested

======================================================================
19. REUSABLE FRONTEND COMPONENTS
======================================================================

Create reusable components such as:

ScanWizard
ScanHeader
FinalVerdictCard
ComponentCard
ComponentGrid
ComponentTable
StatusChip
ScoreGauge
ProbeResultRow
AppraisalDrawer
WarningPanel
BlockerPanel
ScanProgress
SummaryRail
DecisionTable
EvidenceViewer
ExportMenu
EmptyState
ErrorState

Do not place all logic in one HTML template or one JavaScript function.

Separate:

- API client
- state management
- presentation
- scoring display
- status mapping
- filters
- export actions

======================================================================
20. API INTEGRATION
======================================================================

Connect the UI to real endpoints:

POST /api/r6/scans/business-system/run

GET /api/r6/scans/runs/{runId}

GET /api/r6/scans/runs/{runId}/components

GET /api/r6/scans/runs/{runId}/components/{componentId}

POST /api/r6/scans/runs/{runId}/components/{componentId}/retry

GET /api/r6/scans/runs/{runId}/appraisal

GET /api/r6/scans/runs/{runId}/export

Do not use fake data after the API is available.

Allow fixture data only in explicit development mode.

======================================================================
21. REQUIRED FRONTEND TESTS
======================================================================

Add tests for:

test_scan_wizard_renders_all_five_steps

test_wizard_marks_completed_steps_correctly

test_run_scan_button_calls_real_backend

test_scan_progress_updates_without_page_reload

test_scan_progress_restores_after_page_refresh

test_component_cards_render_from_real_appraisal_data

test_component_card_does_not_show_ready_when_only_ssh_passed

test_component_card_shows_warning_count

test_component_card_shows_blocker_count

test_component_card_shows_capture_recommendation

test_component_card_shows_container_recommendation

test_component_drawer_opens_and_closes

test_component_drawer_displays_probe_results

test_component_drawer_displays_raw_output_on_request

test_component_filter_by_verdict

test_component_filter_blockers_only

test_component_search_by_name_or_vm

test_card_and_table_view_toggle

test_final_verdict_card_counts_components_correctly

test_continue_button_disabled_when_blocked

test_continue_button_requires_warning_acknowledgement

test_database_card_shows_migration_action_not_build_action

test_retry_component_calls_retry_endpoint

test_export_button_downloads_evidence

test_mobile_layout_preserves_blockers

test_keyboard_navigation_works

test_screen_reader_announces_scan_completion

All existing backend and frontend tests must remain green.

======================================================================
22. DEFINITION OF DONE
======================================================================

The UI update is complete only when:

- the user sees a simple five-step wizard
- the final Business System verdict is immediately visible
- every logical component has a clear appraisal card
- cards show readiness, evidence, warnings and blockers
- raw technical evidence is hidden until requested
- component details are available in a structured drawer
- filters and search work
- scan progress updates live
- progress survives page refresh
- blocker and warning actions are clear
- database components use migration-specific UI
- Stage 8 decisions are easy to understand and audit
- Stage 9 snapshots remain gated by approved decisions
- the interface works on desktop, tablet and mobile
- keyboard and screen-reader access works
- all old and new tests pass

Use these user-facing titles:

Page title:
R6 Business System Appraisal

Subtitle:
Discover, evaluate and prepare every FLEX application component for
containerization, migration or continued VM operation.

Final verdict card:
Business Apps System Final Verdict

Component section:
Component Scan Appraisals

Wizard:
Discover → Analyze → Validate → Decide → Export

