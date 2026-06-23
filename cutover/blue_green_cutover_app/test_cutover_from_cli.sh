#!/usr/bin/env bash
set -euo pipefail

CUTOVER_API="${CUTOVER_API:-http://localhost:8000}"
SOURCE_URL="${SOURCE_URL:?SOURCE_URL is required}"
TARGET_URL="${TARGET_URL:?TARGET_URL is required}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
SMOKE_PATH="${SMOKE_PATH:-/}"

echo "Configuring cutover tester..."
curl -sS -X POST "$CUTOVER_API/config" \
  -H "Content-Type: application/json" \
  -d "{
    \"active_environment\": \"source\",
    \"traffic_mode\": \"simulation\",
    \"source\": {
      \"name\": \"source-blue\",
      \"base_url\": \"$SOURCE_URL\",
      \"health_path\": \"$HEALTH_PATH\",
      \"smoke_path\": \"$SMOKE_PATH\",
      \"expected_status\": 200,
      \"timeout_seconds\": 5
    },
    \"target\": {
      \"name\": \"target-green\",
      \"base_url\": \"$TARGET_URL\",
      \"health_path\": \"$HEALTH_PATH\",
      \"smoke_path\": \"$SMOKE_PATH\",
      \"expected_status\": 200,
      \"timeout_seconds\": 5
    }
  }" | jq .

echo "Running health check..."
curl -sS "$CUTOVER_API/health-check" | jq .

echo "Running smoke test..."
curl -sS "$CUTOVER_API/smoke-test" | jq .

echo "Running pre-cutover check..."
curl -sS -X POST "$CUTOVER_API/pre-cutover-check" | jq .
