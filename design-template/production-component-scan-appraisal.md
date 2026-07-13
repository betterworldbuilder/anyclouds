CODEX IMPLEMENTATION INSTRUCTION
Production Component Scan Appraisal + Business System Final Verdict

Upgrade the existing FLEX live VM scanner into a structured, production-grade component appraisal system.

The current scanner already collects useful host, process, service, port, disk, mount, configuration-path and application-file evidence. However, do not treat SSH command completion as proof that a component is healthy or ready for containerization.

Implement the following flow:

Live VM scan
→ independent probe execution
→ structured evidence
→ logical component detection
→ per-component appraisal cards
→ containerization recommendation
→ Business Apps System final verdict

Do not replace the existing scanner. Refactor and extend it cleanly while preserving current workflows and tests.

======================================================================
1. SCAN EXECUTION MODEL
======================================================================

Replace the current single large shell command with independently executed named probes.

Do not use one command chain containing:

command1 || true
command2 || true
command3 | head -30

Each probe must capture:

- probe ID
- probe name
- start time
- completion time
- duration
- command identifier
- exit code
- stdout
- stderr
- timeout status
- evidence count
- truncated flag
- canonical status
- remediation

Do not silently discard stderr.

Do not mark a probe PASS when the underlying command fails.

Do not mark the complete component PASS merely because SSH connectivity succeeded.

Use predefined commands only. Never accept arbitrary shell commands from the frontend.

Use a command allowlist, timeouts, output limits and secret redaction.

======================================================================
2. CANONICAL PROBE STATUSES
======================================================================

Use only:

PENDING
RUNNING
PASS
WARNING
PARTIAL
FAIL
BLOCKED
NOT_APPLICABLE
NOT_TESTED
CANCELLED

Definitions:

PASS:
The probe executed successfully and sufficient evidence was collected.

WARNING:
The probe completed but detected a non-blocking concern.

PARTIAL:
The probe ran, but important evidence is missing or incomplete.

FAIL:
The probe executed and returned an invalid result.

BLOCKED:
The probe could not execute because a prerequisite failed.

NOT_APPLICABLE:
The probe does not apply to this component.

NOT_TESTED:
The probe was not configured or has not yet run.

CANCELLED:
The scan was interrupted before completion.

======================================================================
3. REQUIRED PROBE REGISTRY
======================================================================

Implement these probes independently:

SCAN-001 — SSH Connectivity
Collect connection status, latency and verified host fingerprint.

SCAN-002 — Host Identity
Collect VM ID, hostname, machine ID, operating system, kernel,
architecture and virtualization type.

SCAN-003 — Runtime Detection
Detect Python, Java, Node.js, PHP, .NET, Go and application-server
versions.

SCAN-004 — Process Discovery
Collect PID, user, executable, arguments, parent process and working
directory.

SCAN-005 — Service Discovery
Collect systemd unit, ExecStart, User, Group, WorkingDirectory,
EnvironmentFile, restart policy and service dependencies.

SCAN-006 — Port Discovery
Collect protocol, bind address, port, PID and owning process.

SCAN-007 — Application Path Discovery
Identify application source, binaries, static assets, libraries and
configuration roots.

SCAN-008 — Mounted Storage
Collect device, OpenStack volume ID when available, filesystem, mount
path, size and read/write status.

SCAN-009 — Writable Path Discovery
Identify paths written to by each application process.

SCAN-010 — Persistent Path Discovery
Identify database directories, uploads, queues, state files, file
shares and durable storage.

SCAN-011 — Configuration Classification
Separate ConfigMap candidates, Secret candidates, environment files
and host-specific configuration.

SCAN-012 — Outbound Dependency Discovery
Collect remote host or IP, port, protocol, owning process, TLS usage
and configured endpoint.

SCAN-013 — Health Validation
Run approved HTTP, TCP or application-specific health checks.

SCAN-014 — Scheduled Work
Collect cron jobs, systemd timers and application schedulers.

SCAN-015 — Resource Baseline
Collect CPU, memory, disk and optional network samples over a controlled
interval.

SCAN-016 — Container Constraints
Detect privileged requirements, host networking, kernel modules,
hardware dependencies, system-level dependencies and machine identity.

SCAN-017 — Licensing Constraints
Detect indicators of host-bound, MAC-bound or machine-bound licensing.

SCAN-018 — Secret Exposure
Detect secret paths, private keys, tokens, credential files and unsafe
capture paths without storing secret values.

SCAN-019 — Database Detection
Detect PostgreSQL, MySQL, MariaDB, MongoDB, Redis and other data
services, including version, port and data path.

SCAN-020 — Snapshot Source Readiness
Identify source VM, root volume, attached volumes and relevant
application paths required by the later Stage 9 snapshot workflow.

======================================================================
4. LOGICAL COMPONENT DETECTION
======================================================================

Appraise logical application components, not only VMs.

A VM running multiple application services must produce multiple
component records.

Example:

One VM running:

- auth_service.py on port 8101
- core_banking_service.py on port 8102

must produce:

- Auth / SSO component
- Core Banking Backend component

Do not combine them into one component merely because they share a VM.

Associate each component with:

- source VM ID
- process
- service unit
- runtime
- ports
- application paths
- configuration paths
- dependencies
- persistent paths
- health result
- source evidence

Detect duplicate or overlapping services across multiple VMs and report:

POSSIBLE_HA
POSSIBLE_CLONE
POSSIBLE_STALE_VM
MAPPING_CONFLICT

Do not automatically assume duplicate services represent valid HA.

======================================================================
5. COMPONENT APPRAISAL DATA MODEL
======================================================================

Create one structured appraisal per logical component.

Example:

{
  "componentId": "core-banking-api",
  "componentName": "Core Banking Backend",
  "sourceVmId": "vm-core-01",
  "scanRunId": "scan-20260713-001",
  "scanStatus": "COMPLETE",
  "probeSummary": {
    "pass": 15,
    "warning": 2,
    "partial": 2,
    "fail": 0,
    "blocked": 1,
    "notApplicable": 0,
    "notTested": 0
  },
  "evidenceCompletenessScore": 86,
  "containerReadinessScore": 78,
  "stateClassification": "STATELESS",
  "captureRecommendation": "LIVE_PLUS_SNAPSHOT",
  "containerizationRecommendation": "CANDIDATE_WITH_REMEDIATION",
  "componentVerdict": "READY_FOR_STAGE_8_WITH_WARNINGS",
  "runtime": {
    "type": "python",
    "version": "3.12"
  },
  "services": [
    "banking-core-banking.service"
  ],
  "ports": [
    8102
  ],
  "applicationPaths": [
    "/opt/banking-poc/services/core_banking_service.py",
    "/opt/banking-poc/common.py"
  ],
  "configurationPaths": [
    "/etc/banking-poc/core-banking.env"
  ],
  "persistentPaths": [],
  "excludedPaths": [
    "/home/ubuntu/.ssh",
    "/var/log",
    "/tmp"
  ],
  "warnings": [
    {
      "code": "HEALTH_ENDPOINT_NOT_CONFIRMED",
      "message": "Port 8102 is listening but application health was not validated."
    }
  ],
  "blockers": [],
  "recommendedActions": [
    "Define an HTTP health endpoint.",
    "Move environment secrets into an OpenCenter SecretContract."
  ]
}

======================================================================
6. COMPONENT VERDICTS
======================================================================

Use only these canonical component verdicts:

READY_FOR_STAGE_8
READY_FOR_STAGE_8_WITH_WARNINGS
NEEDS_MORE_EVIDENCE
MANUAL_REVIEW_REQUIRED
DB_NATIVE_REQUIRED
RETAIN_VM_RECOMMENDED
BLOCKED
SCAN_FAILED

Rules:

READY_FOR_STAGE_8:
- required evidence complete
- no blockers
- container-readiness score at least 85

READY_FOR_STAGE_8_WITH_WARNINGS:
- no blockers
- score at least 70
- minor warnings or incomplete non-critical evidence

NEEDS_MORE_EVIDENCE:
- required probes are PARTIAL, BLOCKED or NOT_TESTED
- application path, dependency or persistence evidence is incomplete

MANUAL_REVIEW_REQUIRED:
- licensing, hardware, privileged access, machine identity or ambiguous
  mapping is detected

DB_NATIVE_REQUIRED:
- database or active database data directory is detected

RETAIN_VM_RECOMMENDED:
- strong VM dependency, unsupported host requirement or machine-bound
  application is detected

BLOCKED:
- unsafe secret exposure
- private key in capture path
- unresolved persistent storage
- unresolved mandatory dependency
- invalid source mapping
- active database files proposed for normal image build

SCAN_FAILED:
- SSH connectivity or core host inspection failed and no reliable
  fallback evidence exists

Database-native and retained-VM verdicts are valid outcomes and must not
automatically block the full Business System when explicitly planned.

======================================================================
7. CONTAINERIZATION RECOMMENDATIONS
======================================================================

Keep the recommendation separate from the scan verdict.

Use:

STRONG_CONTAINER_CANDIDATE
CANDIDATE_WITH_REMEDIATION
PARTIAL_CONTAINERIZATION
KUBERNETES_NATIVE_REPLACEMENT
OPERATOR_MANAGED
DB_NATIVE_MIGRATION
RETAIN_FLEX_VM
REDEPLOY_FLEX_VM
EXTERNAL_SERVICE
MANUAL_REVIEW
BLOCKED

Example mappings:

Python service with known startup command, explicit port, known
application paths and no durable state:
STRONG_CONTAINER_CANDIDATE

Static Nginx frontend:
STRONG_CONTAINER_CANDIDATE

Application requiring persistent upload storage:
CANDIDATE_WITH_REMEDIATION

PostgreSQL, MySQL or Redis with active data:
DB_NATIVE_MIGRATION or OPERATOR_MANAGED

Machine-bound licence:
RETAIN_FLEX_VM

Unknown application paths:
MANUAL_REVIEW or NEEDS_MORE_EVIDENCE

Secret or private key in planned build context:
BLOCKED

======================================================================
8. CAPTURE RECOMMENDATIONS
======================================================================

Use:

LIVE_PLUS_SNAPSHOT
LIVE_ONLY
SNAPSHOT_ONLY
DB_NATIVE
STORAGE_NATIVE_CLONE
IMPORTED_ARTIFACT
RETAIN_VM
NO_CAPTURE_REQUIRED
BLOCKED

Rules:

- normal reachable container candidate:
  LIVE_PLUS_SNAPSHOT

- runtime inspection only:
  LIVE_ONLY

- stopped or unreachable VM with usable snapshot:
  SNAPSHOT_ONLY

- database:
  DB_NATIVE

- large independent data volume:
  STORAGE_NATIVE_CLONE

- retained application:
  RETAIN_VM

- operator or external service:
  NO_CAPTURE_REQUIRED

- no reliable source:
  BLOCKED

This appraisal recommends the capture method but must not create a new
snapshot. Snapshot creation remains in Stage 9 after Stage 8 approval.

======================================================================
9. EVIDENCE COMPLETENESS SCORE
======================================================================

Calculate an evidence-completeness score from applicable probes.

Suggested weights:

Connectivity and host identity: 5
Processes and services: 15
Runtime and ports: 10
Application paths: 15
Configuration and secret classification: 10
Dependencies: 15
Storage and persistence: 15
Health: 10
Container constraints and licensing: 5

Scoring:

PASS = full probe weight
WARNING = 75 percent of probe weight
PARTIAL = 50 percent
FAIL = 0
BLOCKED = 0
NOT_TESTED = 0
NOT_APPLICABLE = excluded

Do not use the score to override a blocker.

======================================================================
10. CONTAINER READINESS SCORE
======================================================================

Start from 100 and apply deductions.

Health not tested:
minus 10

Each unresolved dependency:
minus 10, capped at minus 30

Unknown persistent path:
minus 20

Unknown startup command:
minus 20

Root-required runtime:
minus 10

Fixed-IP dependency:
minus 10

Host networking dependency:
minus 15

Privileged container requirement:
minus 20

Unknown writable paths:
minus 15

Plaintext secret:
immediate blocker

Private key in capture path:
immediate blocker

Database data directory in normal build context:
immediate blocker

Machine-bound licence:
manual review or retain VM recommendation

Score thresholds support the verdict but never override blockers.

======================================================================
11. COMPONENT RESULT CARDS
======================================================================

Add a responsive result card for every component.

Card header:

Core Banking Backend
Source VM: core-bank-01
Verdict: READY FOR STAGE 8 WITH WARNINGS
Readiness: 78%

Each card must show:

- component name
- source VM
- verdict
- readiness score
- evidence score
- connectivity
- runtime
- services detected
- ports
- application paths
- persistent paths
- dependencies
- health
- secret safety
- capture recommendation
- container recommendation
- evidence confidence
- warning count
- blocker count

Example visual structure:

┌──────────────────────────────────────────────────────┐
│ Core Banking Backend                 [WARNING]       │
│ VM: core-bank-01        Readiness: 78%               │
│ Evidence: 86%                                       │
├──────────────────────────────────────────────────────┤
│ Connectivity   SSH + fingerprint verified   PASS     │
│ Runtime        Python 3.12                  PASS     │
│ Services       1 detected                   PASS     │
│ Ports          8102                         PASS     │
│ Dependencies   3 resolved / 1 unknown       PARTIAL  │
│ Health         Endpoint not confirmed       WARNING  │
│ Persistence    No durable writes detected   PASS     │
│ Secrets        No unsafe capture path       PASS     │
├──────────────────────────────────────────────────────┤
│ Recommendation: Candidate with remediation           │
│ Capture: Live scan + snapshot                         │
│ 1 warning • 0 blockers                               │
│ [View Evidence] [View Appraisal] [Retry Scan]         │
└──────────────────────────────────────────────────────┘

Status visual treatment:

PASS:
green

WARNING or PARTIAL:
amber

FAIL or BLOCKED:
red

NOT_TESTED:
grey

DB_NATIVE_REQUIRED:
blue

RETAIN_VM_RECOMMENDED:
purple

Do not color the entire card green merely because SSH succeeded.

======================================================================
12. COMPONENT DETAIL DRAWER
======================================================================

The View Appraisal action must open a drawer containing:

1. Summary
2. Probe results
3. Processes
4. Services and startup commands
5. Ports
6. Runtime
7. Application paths
8. Configuration and secret classification
9. Dependencies
10. Mounted storage
11. Writable and persistent paths
12. Health evidence
13. Container constraints
14. Licensing findings
15. Recommended Stage 8 decision
16. Capture recommendation
17. Warnings
18. Blockers
19. Remediation

Each probe row must show:

- probe ID
- probe title
- status
- concise result
- evidence
- exit code
- stderr when present
- duration
- truncated status
- remediation

======================================================================
13. BUSINESS APPS SYSTEM FINAL VERDICT CARD
======================================================================

Add one final summary card above all component cards.

Title:

Business Apps System Scan Appraisal

Example:

6 logical components discovered
5 VMs scanned
2 ready
2 ready with warnings
1 database-native
1 needs review
0 blocked
0 scan failures

Final verdict:
READY FOR STAGE 8 WITH WARNINGS

Display:

- source VMs
- logical components
- probes executed
- probes passed
- warnings
- partial probes
- failures
- blocked probes
- ready components
- ready-with-warning components
- database-native components
- retained-VM components
- needs-review components
- blocked components
- scan failures
- overall evidence score
- final verdict
- next recommended action

======================================================================
14. BUSINESS SYSTEM FINAL VERDICTS
======================================================================

Use only:

READY_FOR_STAGE_8
READY_FOR_STAGE_8_WITH_WARNINGS
PARTIALLY_READY
MANUAL_REVIEW_REQUIRED
BLOCKED
SCAN_FAILED

Rules:

READY_FOR_STAGE_8:
- all mandatory components have valid recommendations
- no warnings
- no blockers
- no failed mandatory probes

READY_FOR_STAGE_8_WITH_WARNINGS:
- no blockers
- every mandatory component has enough evidence
- warnings remain but do not prevent Stage 7 and Stage 8

PARTIALLY_READY:
- some components are ready
- other components require more evidence

MANUAL_REVIEW_REQUIRED:
- at least one mandatory component has licensing, hardware, privileged
  access, duplicate-service ambiguity or uncertain mapping

BLOCKED:
- at least one mandatory component is blocked

SCAN_FAILED:
- the complete Business System could not be reliably scanned

Database-native and retained-VM results are not blockers when they are
explicit, complete and correctly routed.

Example:

{
  "businessSystemId": "bank-mobile",
  "scanRunId": "scan-20260713-001",
  "finalVerdict": "READY_FOR_STAGE_8_WITH_WARNINGS",
  "overallEvidenceScore": 84,
  "summary": {
    "sourceVms": 5,
    "components": 6,
    "ready": 2,
    "readyWithWarnings": 2,
    "databaseNative": 1,
    "retainVm": 0,
    "needsReview": 1,
    "blocked": 0,
    "scanFailed": 0
  },
  "systemWarnings": [
    "One backend health endpoint remains unverified.",
    "One component has an unresolved outbound dependency."
  ],
  "systemBlockers": [],
  "nextAction": "Review warnings and continue to Stage 7 classification."
}

======================================================================
15. SPECIAL PRODUCTION RULES
======================================================================

SSH host verification:

- use managed known_hosts
- verify the expected fingerprint
- do not rely on trust-on-first-use in production
- prefer private FLEX IPs through bastion, VPN or management network

Scanner account:

- use a dedicated least-privilege account
- allow only approved read-only commands
- tightly control any required sudo command

Secret handling:

- never save environment secret values
- store variable names and paths only
- redact passwords, tokens, keys and credentials
- exclude SSH directories and host keys from application paths

Default path exclusions:

/home/*/.ssh
/root/.ssh
/etc/ssh/ssh_host_*
/proc
/sys
/dev
/run
/tmp
/var/tmp
/var/log
swap files
core dumps
package caches
database active data directories
backup archives
cloud-init secret files
container runtime storage

Do not classify files such as:

/home/ubuntu/.ssh/authorized_keys
downloaded .deb files
shell profile files
system agents
firmware utilities
ModemManager
Amazon SSM Agent
QEMU guest agent

as application files.

Database rule:

- PostgreSQL, MySQL, Redis and similar services must produce
  DB_NATIVE_REQUIRED
- never copy active database files into an OCI build context
- never treat a crash-consistent VM snapshot as a complete database
  migration
- generate a native dump/restore, backup or replication requirement

Multiple services rule:

- one VM may generate multiple components
- each component receives its own appraisal
- shared files such as common.py may appear as shared dependencies
- do not build one large image merely because services share a VM

======================================================================
16. STRUCTURED REPORTS
======================================================================

Generate:

reports/scans/<run-id>/
├── summary.json
├── final-appraisal.json
├── component-appraisals/
│   ├── <component-id>.json
├── probes/
│   └── <vm-id>/
│       ├── SCAN-001.json
│       ├── SCAN-002.json
│       └── ...
├── raw/
│   └── <vm-id>.log
├── evidence-checksums.json
└── scan-report.md

Persist the most recent run and scan history.

Store:

- scanner version
- schema version
- actor
- scan time
- target VM ID
- target IP
- host fingerprint
- evidence checksum
- evidence expiration timestamp

======================================================================
17. BACKEND API
======================================================================

Implement or extend:

POST /api/r6/scans/business-system/run

Start a complete Business System scan.

GET /api/r6/scans/runs/{runId}

Return overall progress and current VM/component/probe.

GET /api/r6/scans/runs/{runId}/components

Return component appraisal summaries.

GET /api/r6/scans/runs/{runId}/components/{componentId}

Return full component appraisal and probe evidence.

POST /api/r6/scans/runs/{runId}/components/{componentId}/retry

Retry only FAIL, PARTIAL, BLOCKED or NOT_TESTED probes for the selected
component.

GET /api/r6/scans/runs/{runId}/appraisal

Return the Business System final verdict.

GET /api/r6/scans/runs/{runId}/export

Export JSON, Markdown and evidence package.

All long-running scan operations must support:

- progress
- cancellation
- persisted state
- page refresh recovery
- safe retry

======================================================================
18. UI ACTIONS
======================================================================

Provide:

Run Full Live Scan
Stop Scan
Retry Failed
Refresh Appraisal
Export Evidence

Each component card must provide:

View Evidence
View Appraisal
Retry Scan

The final verdict card must provide:

Review Warnings
Review Blockers
Continue to Classification

Disable Continue to Classification when the final verdict is:

BLOCKED
SCAN_FAILED

Allow continuation with an explicit review record when the verdict is:

READY_FOR_STAGE_8_WITH_WARNINGS
PARTIALLY_READY
MANUAL_REVIEW_REQUIRED

Do not automatically approve warnings.

======================================================================
19. INTEGRATION WITH STAGES 7, 8 AND 9
======================================================================

Stage 7 must consume structured component appraisals, not raw shell logs.

Stage 8 must use:

- component verdict
- readiness score
- state classification
- persistence findings
- dependency findings
- container constraints
- database detection
- capture recommendation

Stage 9 may snapshot only components whose Stage 8 decision is:

CONTAINERIZE
PARTIALLY_CONTAINERIZE

The scan appraisal may recommend LIVE_PLUS_SNAPSHOT, but it must not
create a snapshot directly.

======================================================================
20. AUTOMATED TESTS
======================================================================

Add:

test_scan_does_not_mark_component_pass_when_only_ssh_passes

test_each_probe_preserves_exit_code_stdout_and_stderr

test_failed_probe_is_not_hidden_by_true_fallback

test_truncated_output_is_marked_explicitly

test_multiple_services_on_one_vm_create_multiple_components

test_duplicate_services_generate_mapping_warning

test_database_detection_returns_db_native_required

test_private_key_detection_blocks_container_readiness

test_plaintext_secret_detection_blocks_component

test_unknown_persistent_path_blocks_stage8_readiness

test_health_not_tested_produces_warning

test_unresolved_dependency_reduces_readiness_score

test_application_path_filter_excludes_ssh_files

test_application_path_filter_excludes_host_agents

test_component_card_displays_real_probe_results

test_component_card_shows_warnings_and_blockers

test_component_card_shows_capture_recommendation

test_final_verdict_blocked_when_mandatory_component_is_blocked

test_final_verdict_allows_explicit_db_native_component

test_final_verdict_allows_explicit_retained_vm_component

test_final_verdict_ready_with_warnings_when_no_blockers_exist

test_system_summary_counts_component_verdicts_correctly

test_retry_component_reruns_only_failed_partial_and_blocked_probes

test_scan_evidence_persists_after_page_refresh

test_export_contains_component_appraisals_and_final_verdict

test_stage7_uses_structured_appraisal_not_raw_log

test_stage9_does_not_snapshot_before_stage8_approval

All existing tests must remain green.

======================================================================
21. DEFINITION OF DONE
======================================================================

The implementation is complete only when:

The live scan runs independent named probes
→ every probe records a truthful status
→ failures are no longer hidden by || true
→ truncation is explicitly reported
→ raw output is converted into structured evidence
→ logical services are separated into components
→ every component receives an appraisal card
→ every card shows evidence score, readiness score, recommendation,
  warnings, blockers and remediation
→ database services receive DB-native verdicts
→ retained VM outcomes are supported
→ the complete Business Apps System receives one final verdict
→ SSH success is never treated as container readiness
→ Stage 7 and Stage 8 consume the structured appraisal
→ Stage 9 snapshots only approved container targets
→ evidence persists and can be exported
→ all old and new tests pass

Use these final UI descriptions:

Component Scan Appraisal

Evaluate the runtime, services, application files, dependencies, storage,
health, security and containerization constraints of every Business Apps
System component.

Business System Final Verdict

Determine whether the complete system is ready for classification and
transformation, ready with warnings, partially ready, requires manual
review, or is blocked.

