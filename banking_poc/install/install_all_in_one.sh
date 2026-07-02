#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$DIR/install_database_service.sh"
"$DIR/install_cache_service.sh"
"$DIR/install_auth_service.sh"
"$DIR/install_audit_service.sh"
"$DIR/install_notification_service.sh"
"$DIR/install_core_banking_service.sh"
"$DIR/install_ledger_service.sh"
"$DIR/install_api_gateway.sh"

echo "All backend services installed."
echo "Test login:"
echo "curl -s -X POST http://127.0.0.1:8100/api/login -H 'Content-Type: application/json' -d '{\"username\":\"alex\",\"password\":\"demo\"}'"

