#!/usr/bin/env bash
# MockBank E2E: mock banking app -> R6 refactor -> docker images -> Kind -> OpenCenter(mock) deploy
# Usage: e2e_run.sh <phase>   phases: setup | refactor | build | deploy | verify
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

E2E=/home/dzoan/cloudmax/mockbank-e2e
LOG="$E2E/report/e2e.log"
mkdir -p "$E2E/report"
phase="${1:-all}"

note() { echo "== $*" | tee -a "$LOG"; }
run()  { echo "\$ $*" | tee -a "$LOG"; "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }

# ─────────────────────────────────────────────────────────────────── setup ──
do_setup() {
  note "PHASE setup: kind binary + opencenter mock shim"
  mkdir -p "$HOME/.local/bin"
  if ! command -v kind >/dev/null 2>&1; then
    ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
    run curl -fsSLo /tmp/kind "https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-${ARCH}" || return 1
    chmod +x /tmp/kind && mv /tmp/kind "$HOME/.local/bin/kind"
  fi
  install -m 755 "$E2E/bin/opencenter" "$HOME/.local/bin/opencenter"
  run kind --version || return 1
  run opencenter version || return 1
  run docker info --format 'docker server {{.ServerVersion}}' || return 1
}

# ──────────────────────────────────────────────────────────────── refactor ──
do_refactor() {
  note "PHASE refactor: call the real dashboard R6 generate-bundle endpoint"
  # dashboard test instance on :5091 (restart if down)
  if ! curl -s -o /dev/null http://127.0.0.1:5091/; then
    note "dashboard not running - starting on :5091"
    (cd /home/dzoan/cloudmax/workflow_dashboard && WORKFLOW_DASHBOARD_PORT=5091 nohup python3 app.py > /tmp/wf_test_5091.log 2>&1 &)
    sleep 6
  fi
  cat > /tmp/r6_payload.json <<'EOF'
{
  "org": "mockbank-org",
  "cluster": "mockbank",
  "region": "local",
  "registry": {"type": "dockerhub", "project": "mockbank", "user": "", "password": ""},
  "source_vm": {"host": "127.0.0.1", "user": "dzoan"},
  "auto_commit": false,
  "import_to_gitops": false,
  "bundle": {
    "id": "r6p-mockbank-e2e",
    "businessSystemName": "MockBank Mobile Banking",
    "workloads": [
      {"component": "bank-api", "image": "mockbank/bank-api:1.0.0", "replicas": 2,
       "readiness": "READY", "layer": "API", "sourcePath": "/opt/bank-api",
       "targetForm": "CONTAINERIZED", "targetIp": "127.0.0.1",
       "startCommand": "gunicorn -b 0.0.0.0:8000 --workers 2 app:app",
       "persistentPath": "None - stateless"},
      {"component": "bank-frontend", "image": "mockbank/bank-frontend:1.0.0", "replicas": 1,
       "readiness": "READY", "layer": "Frontend", "sourcePath": "/opt/bank-frontend",
       "targetForm": "CONTAINERIZED", "targetIp": "127.0.0.1",
       "startCommand": "nginx -g 'daemon off;'",
       "persistentPath": "None - stateless"}
    ]
  }
}
EOF
  note "POST /api/r6/generate-bundle"
  curl -s -X POST http://127.0.0.1:5091/api/r6/generate-bundle \
       -H 'Content-Type: application/json' --data @/tmp/r6_payload.json \
       | tee /tmp/r6_result.json | python3 -m json.tool | head -40 | tee -a "$LOG"
  OUT_DIR=$(python3 -c "import json;d=json.load(open('/tmp/r6_result.json'));print(d.get('out_dir') or d.get('bundle_dir') or '')" 2>/dev/null)
  note "ACE bundle dir: ${OUT_DIR:-(see /tmp/r6_result.json)}"
  [ -n "$OUT_DIR" ] && run ls -R "$OUT_DIR" | head -40
  return 0
}

# ─────────────────────────────────────────────────────────────────── build ──
do_build() {
  note "PHASE build: docker images from R6 refactor Dockerfiles"
  BUILD=/tmp/mockbank-build; rm -rf "$BUILD"; mkdir -p "$BUILD/api" "$BUILD/fe"
  cp "$E2E/src/bank-api/app.py" "$E2E/src/bank-api/requirements.txt" "$BUILD/api/"
  cp "$E2E/refactor/dockerfiles/Dockerfile.bank-api" "$BUILD/api/Dockerfile"
  cp "$E2E/src/bank-frontend/index.html" "$E2E/src/bank-frontend/nginx.conf" "$BUILD/fe/"
  cp "$E2E/refactor/dockerfiles/Dockerfile.bank-frontend" "$BUILD/fe/Dockerfile"
  run docker build -q -t mockbank/bank-api:1.0.0 "$BUILD/api" || return 1
  run docker build -q -t mockbank/bank-frontend:1.0.0 "$BUILD/fe" || return 1

  note "smoke test: docker run bank-api"
  docker rm -f mockbank-smoke >/dev/null 2>&1
  run docker run -d --name mockbank-smoke -p 18000:8000 mockbank/bank-api:1.0.0 || return 1
  sleep 4
  run curl -s http://127.0.0.1:18000/health || return 1
  run curl -s http://127.0.0.1:18000/api/accounts | head -c 400
  echo | tee -a "$LOG"
  note "smoke test: transfer 100 from ACC-1001 to ACC-1002"
  run curl -s -X POST http://127.0.0.1:18000/api/transfer \
      -H 'Content-Type: application/json' \
      -d '{"from":"ACC-1001","to":"ACC-1002","amount":100}'
  echo | tee -a "$LOG"
  docker rm -f mockbank-smoke >/dev/null 2>&1
  note "docker smoke test PASSED"
}

# ────────────────────────────────────────────────────────────────── deploy ──
do_deploy() {
  note "PHASE deploy: OpenCenter kind flow (same commands the dashboard generates)"
  ORG=mockbank-org CLUSTER=mockbank
  run opencenter local gitea up || return 1
  run opencenter cluster init "$CLUSTER" --org "$ORG" --type kind || return 1
  run opencenter cluster use "$ORG/$CLUSTER" || return 1
  GITEA_REPO_URL=$(opencenter local gitea status 2>/dev/null | grep "Bootstrap repo URL:" | awk '{print $NF}')
  GITEA_TOKEN_PATH=$(opencenter local gitea status 2>/dev/null | grep "User token present:" | sed 's/.*(\(.*\))/\1/')
  run opencenter cluster set "$ORG/$CLUSTER" \
      "opencenter.gitops.git_url=$GITEA_REPO_URL" \
      "opencenter.gitops.git_token=$GITEA_TOKEN_PATH" \
      "opencenter.gitops.git_token_provider=gitea" || return 1
  run opencenter cluster validate "$ORG/$CLUSTER" || return 1
  run opencenter cluster generate "$ORG/$CLUSTER" || return 1
  # R6 image side-load list for the deploy step
  OVERLAY="$HOME/.config/opencenter/clusters/gitops/$ORG/applications/overlays/$CLUSTER"
  printf 'mockbank/bank-api:1.0.0\nmockbank/bank-frontend:1.0.0\n' > "$OVERLAY/images.txt"
  run opencenter cluster deploy "$ORG/$CLUSTER" --container-runtime docker || return 1
}

# ────────────────────────────────────────────────────────────────── verify ──
do_verify() {
  note "PHASE verify: cluster + banking transactions"
  ORG=mockbank-org CLUSTER=mockbank
  export KUBECONFIG="$HOME/.config/opencenter/clusters/gitops/$ORG/infrastructure/clusters/$CLUSTER/kubeconfig.yaml"
  run kubectl get nodes -o wide
  run kubectl get pods -n flux-system
  run kubectl get pods -n mockbank-prod -o wide
  run kubectl get svc -n mockbank-prod

  note "port-forward bank-frontend :19080 and exercise the app through nginx -> bank-api"
  kubectl -n mockbank-prod port-forward svc/bank-frontend 19080:80 >/tmp/pf.log 2>&1 &
  PF=$!; sleep 4
  run curl -s http://127.0.0.1:19080/health
  run curl -s -o /dev/null -w 'frontend index: HTTP %{http_code}\n' http://127.0.0.1:19080/
  run curl -s http://127.0.0.1:19080/api/accounts
  echo | tee -a "$LOG"
  note "in-cluster banking transaction: ACC-1002 -> ACC-1003 : 42.50"
  run curl -s -X POST http://127.0.0.1:19080/api/transfer \
      -H 'Content-Type: application/json' \
      -d '{"from":"ACC-1002","to":"ACC-1003","amount":42.5}'
  echo | tee -a "$LOG"
  run curl -s http://127.0.0.1:19080/api/transactions
  echo | tee -a "$LOG"
  kill $PF 2>/dev/null
  note "GitOps repo state:"
  run git -C "$HOME/.config/opencenter/clusters/gitops/$ORG" log --oneline -5
  note "VERIFY PHASE COMPLETE"
}

case "$phase" in
  setup) do_setup ;;
  refactor) do_refactor ;;
  build) do_build ;;
  deploy) do_deploy ;;
  verify) do_verify ;;
  all) do_setup && do_refactor && do_build && do_deploy && do_verify ;;
  *) echo "usage: $0 setup|refactor|build|deploy|verify|all"; exit 2 ;;
esac
