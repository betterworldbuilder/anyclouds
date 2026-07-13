# R6 Scanner Status and Error Contract

Schema: `r6.scan-appraisal/v2`

| Status | Meaning |
|---|---|
| `PASS` | Required evidence was collected and validated. |
| `PASS_WITH_WARNING` | Useful evidence was collected, with non-blocking diagnostics or partial confidence. |
| `FAIL` | The probe executed but did not produce required evidence. |
| `BLOCKED` | The probe cannot run until an operator or infrastructure prerequisite is repaired. |
| `SKIPPED_PREREQUISITE` | A dependent probe was not executed; `prerequisiteProbeId` and `derivedFrom` identify the single root failure. |
| `NOT_DETECTED` | An optional capability or artifact was absent; this is not an execution failure. |
| `NOT_APPLICABLE` | Policy says the probe does not apply, such as SSH for a managed database. |

SSH failures use stable codes: `SSH_DNS_RESOLUTION_FAILED`, `SSH_NETWORK_UNREACHABLE`, `SSH_CONNECTION_REFUSED`, `SSH_NETWORK_TIMEOUT`, `SSH_HOST_KEY_CHANGED`, `SSH_HOST_KEY_UNKNOWN`, `SSH_AUTHENTICATION_FAILED`, `SSH_PERMISSION_DENIED`, `SSH_COMMAND_TIMEOUT`, `SSH_REMOTE_COMMAND_FAILED`, and `SSH_UNKNOWN_ERROR`.

Every result preserves status, error code/category, failure stage, prerequisite/root-cause references, raw exit code, timeout state, duration, bounded redacted stdout/stderr, summary, recommended actions, retryability, operator-action requirement, severity and structured evidence.

The Business System result reports discovery coverage, infrastructure access, application readiness, database readiness, snapshot readiness and containerization readiness separately. `BLOCKED_INFRASTRUCTURE` never implies that the application is incompatible.
