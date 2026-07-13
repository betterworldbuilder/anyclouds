# Scan UI v1

Status: Active baseline  
Registered ID: `scan-ui-v1`  
Saved: 2026-07-13

## Purpose

Production Stage 3 interface for structured Business Apps System component scanning and appraisal.

## Stable layout contract

1. UI-version selector at the upper-left.
2. Component Scan Appraisal explanation.
3. Component scan-scope selector with All Components and individual components.
4. SSH user, key path and managed `known_hosts` inputs.
5. Run Scan, Stop Scan, Refresh Appraisal and Export Evidence actions.
6. Persisted scan progress terminal with Copy Log support.
7. Business Apps System final-verdict card.
8. Responsive logical-component appraisal cards.
9. View Appraisal drawer and targeted Retry Scan action.
10. Stage completion and continuation controls governed by structured evidence.

## Safety contract

- UI selection changes presentation only.
- Switching or reselecting this UI never starts or stops a scan.
- Existing run ID, progress, evidence and appraisal state remain intact.
- Stage 8 evidence requirements and Stage 9 approval/snapshot gates remain unchanged.
- Unknown results display `PENDING`, `NOT_TESTED` or `—`; the UI never fabricates readiness.

