#!/usr/bin/env bash
# MockBank E2E v2 — 3-tier app (frontend + api + PostgreSQL) deployed on Kind
# through the REAL OpenCenter CLI (1.0.0-rc03). Phases:
#   cleanmock | build | deploy | appload | verify
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

E2E=/home/dzoan/cloudmax/mockbank-e2e
LOG="$E2E/report/e2e_v2.log"
mkdir -p "$E2E/report"
ORG=mockbank-org CLUSTER=mockbank
phase="${1:-}"

note() { echo "== $*" | tee -a "$LOG"; }
run()  { echo "\$ $*" | tee -a "$LOG"; "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }

# `opencenter local ...` is provided by the opencenter-local plugin binary; rc03's
# root command does not dispatch plugins, so call the plugin directly as fallback.
oc_local() {
  if opencenter local --help >/dev/null 2>&1; then opencenter local "$@"
  else opencenter-local "$@"; fi
}

do_cleanmock() {
  note "PHASE cleanmock: remove mock-shim state + v1 kind cluster"
  run kind delete cluster --name "$CLUSTER"
  rm -rf "$HOME/.config/opencenter/clusters/blueprints/$ORG" \
         "$HOME/.config/opencenter/clusters/gitops/$ORG" \
         "$HOME/.config/opencenter/clusters/secrets/$ORG" \
         "$HOME/.config/opencenter/mock-gitea" \
         "$HOME/.config/opencenter/active"
  note "mock state removed; real CLI: $(opencenter version 2>/dev/null | head -1)"
}

do_build() {
  note "PHASE build: v2 images (api now speaks PostgreSQL)"
  BUILD=/tmp/mockbank-build2; rm -rf "$BUILD"; mkdir -p "$BUILD/api" "$BUILD/fe"
  cp "$E2E/src/bank-api/app.py" "$E2E/src/bank-api/requirements.txt" "$BUILD/api/"
  cp "$E2E/refactor/dockerfiles/Dockerfile.bank-api" "$BUILD/api/Dockerfile"
  cp "$E2E/src/bank-frontend/index.html" "$E2E/src/bank-frontend/nginx.conf" "$BUILD/fe/"
  cp "$E2E/refactor/dockerfiles/Dockerfile.bank-frontend" "$BUILD/fe/Dockerfile"
  run docker build -q -t mockbank/bank-api:2.0.0 "$BUILD/api" || return 1
  run docker build -q -t mockbank/bank-frontend:2.0.0 "$BUILD/fe" || return 1

  note "docker smoke test: real 3-tier (postgres container + api container)"
  docker rm -f mb2-api mb2-db >/dev/null 2>&1; docker network rm mb2 >/dev/null 2>&1
  run docker network create mb2
  run docker run -d --name mb2-db --network mb2 \
      -e POSTGRES_DB=mockbank -e POSTGRES_USER=bank -e POSTGRES_PASSWORD=pw \
      postgres:16-alpine || return 1
  run docker run -d --name mb2-api --network mb2 -p 18001:8000 \
      -e DATABASE_URL=postgresql://bank:pw@mb2-db:5432/mockbank \
      mockbank/bank-api:2.0.0 || return 1
  sleep 12
  run curl -s http://127.0.0.1:18001/health || return 1
  run curl -s -X POST http://127.0.0.1:18001/api/transfer \
      -H 'Content-Type: application/json' -d '{"from":"ACC-1001","to":"ACC-1003","amount":55}'
  echo | tee -a "$LOG"
  run curl -s http://127.0.0.1:18001/api/transactions
  echo | tee -a "$LOG"
  docker rm -f mb2-api mb2-db >/dev/null 2>&1; docker network rm mb2 >/dev/null 2>&1
  note "docker 3-tier smoke test done"
}

do_deploy() {
  note "PHASE deploy: REAL opencenter CLI kind flow"
  run oc_local gitea up || return 1
  run oc_local gitea status
  run opencenter cluster init "$CLUSTER" --org "$ORG" --type kind \
    || note "cluster config already exists - continuing"
  run opencenter cluster use "$ORG/$CLUSTER" || true
  GITEA_REPO_URL=$(oc_local gitea status 2>/dev/null | grep "Bootstrap repo URL:" | awk '{print $NF}')
  GITEA_TOKEN_PATH=$(oc_local gitea status 2>/dev/null | grep "User token present:" | sed 's/.*(\(.*\))/\1/')
  note "gitea repo: $GITEA_REPO_URL  token: $GITEA_TOKEN_PATH"
  # rc03 schema: gitops repo/auth live under repository.url + auth.token.token_file
  run opencenter cluster set "$ORG/$CLUSTER" \
      "opencenter.gitops.repository.url=$GITEA_REPO_URL" \
      "opencenter.gitops.auth.token.token_file=$GITEA_TOKEN_PATH" \
      "opencenter.gitops.auth.token.provider=gitea" || return 1
  # first local bootstrap: disable keycloak so no admin password secret is required
  run opencenter cluster set "$ORG/$CLUSTER" "opencenter.services.keycloak.enabled=false" \
    || run opencenter cluster set "$ORG/$CLUSTER" \
         "secrets.keycloak.admin_password=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)aA1"
  # commit generated blueprint state so validate's dirty-tree warning clears
  GD="$HOME/.config/opencenter/clusters/gitops/$ORG"
  if [ -d "$GD/.git" ]; then
    git -C "$GD" add -A
    git -C "$GD" -c user.email=e2e@mockbank -c user.name=e2e commit -q -m "Cluster blueprint state" || true
  fi
  run opencenter cluster validate "$ORG/$CLUSTER" || return 1
  run opencenter cluster generate "$ORG/$CLUSTER" --force || return 1
  run opencenter cluster deploy "$ORG/$CLUSTER" --container-runtime docker
}

do_appload() {
  note "PHASE appload: side-load images + GitOps-import the R6 banking manifests"
  GITOPS_DIR=$(opencenter cluster describe "$ORG/$CLUSTER" 2>/dev/null | grep "git_dir:" | awk '{print $2}')
  [ -z "$GITOPS_DIR" ] && GITOPS_DIR="$HOME/.config/opencenter/clusters/gitops/$ORG"
  note "gitops dir: $GITOPS_DIR"
  KC="$GITOPS_DIR/infrastructure/clusters/$CLUSTER/kubeconfig.yaml"
  [ -f "$KC" ] || KC="$HOME/.kube/config"
  export KUBECONFIG="$KC"
  note "kubeconfig: $KC"
  run kind load docker-image mockbank/bank-api:2.0.0 mockbank/bank-frontend:2.0.0 --name "$CLUSTER" || return 1

  APPDIR="$GITOPS_DIR/applications/overlays/$CLUSTER/managed-services/mockbank"
  mkdir -p "$APPDIR"
  cp "$E2E/refactor/k8s/"*.yaml "$APPDIR/"
  if [ -d "$GITOPS_DIR/.git" ]; then
    git -C "$GITOPS_DIR" add -A
    git -C "$GITOPS_DIR" -c user.email=e2e@mockbank -c user.name=e2e \
        commit -q -m "Import R6 bundle: MockBank 3-tier (frontend/api/postgres)" || true
    git -C "$GITOPS_DIR" push -q origin HEAD 2>/dev/null && note "GitOps pushed to gitea" || note "GitOps push skipped"
  fi
  note "reconcile (flux if wired, else kubectl apply as reconcile stand-in)"
  flux --kubeconfig "$KC" reconcile source git flux-system --timeout 60s 2>/dev/null || true
  run kubectl apply -k "$APPDIR"
  run kubectl -n mockbank-prod rollout status deploy/bank-db --timeout=240s || return 1
  run kubectl -n mockbank-prod rollout status deploy/bank-api --timeout=240s || return 1
  run kubectl -n mockbank-prod rollout status deploy/bank-frontend --timeout=120s || return 1
}

do_verify() {
  note "PHASE verify: 3-tier consistency across API replicas"
  GITOPS_DIR=$(opencenter cluster describe "$ORG/$CLUSTER" 2>/dev/null | grep "git_dir:" | awk '{print $2}')
  [ -z "$GITOPS_DIR" ] && GITOPS_DIR="$HOME/.config/opencenter/clusters/gitops/$ORG"
  KC="$GITOPS_DIR/infrastructure/clusters/$CLUSTER/kubeconfig.yaml"
  [ -f "$KC" ] || KC="$HOME/.kube/config"
  export KUBECONFIG="$KC"
  run kubectl get nodes
  run kubectl get pods -n flux-system
  run kubectl get pods -n mockbank-prod -o wide
  kubectl -n mockbank-prod port-forward svc/bank-frontend 19081:80 >/tmp/pf2.log 2>&1 &
  PF=$!; sleep 4
  run curl -s http://127.0.0.1:19081/health
  run curl -s http://127.0.0.1:19081/api/accounts
  echo | tee -a "$LOG"
  note "transfer 77.25: ACC-1001 -> ACC-1002 (via frontend proxy -> api -> postgres)"
  run curl -s -X POST http://127.0.0.1:19081/api/transfer \
      -H 'Content-Type: application/json' -d '{"from":"ACC-1001","to":"ACC-1002","amount":77.25}'
  echo | tee -a "$LOG"
  note "consistency: read transactions 4x (service load-balances across 2 api replicas)"
  ok=0
  for i in 1 2 3 4; do
    r=$(curl -s http://127.0.0.1:19081/api/transactions)
    echo "read $i: $r" | tee -a "$LOG"
    echo "$r" | grep -q '77.25' && ok=$((ok+1))
  done
  note "reads seeing the transfer: $ok/4 (must be 4/4 with shared PostgreSQL)"
  run curl -s http://127.0.0.1:19081/api/accounts
  echo | tee -a "$LOG"
  kill $PF 2>/dev/null
  [ "$ok" = "4" ] && note "CONSISTENCY PASS — database tier fixes the v1 SQLite replica drift" \
                  || { note "CONSISTENCY FAIL"; return 1; }
  note "VERIFY v2 COMPLETE"
}

case "$phase" in
  cleanmock) do_cleanmock ;;
  build) do_build ;;
  deploy) do_deploy ;;
  appload) do_appload ;;
  verify) do_verify ;;
  all) do_cleanmock && do_build && do_deploy && do_appload && do_verify ;;
  *) echo "usage: $0 cleanmock|build|deploy|appload|verify|all"; exit 2 ;;
esac
