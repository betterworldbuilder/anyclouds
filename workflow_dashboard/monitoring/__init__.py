"""Read-only OpenCenter monitoring backend.

Provides allowlisted command execution, log streaming, parsing and caching for
the Deployment Live Dashboard, the Cluster Operations Dashboard and the
Prometheus exporter. Nothing in this package mutates cluster or cloud state.
"""

MONITORING_VERSION = "1.0.0"
