#!/usr/bin/env bash
set -u
pkill -f "WORKFLOW_DASHBOARD_PORT=5091" 2>/dev/null
pkill -f "app.py" 2>/dev/null && sleep 2
cd /home/dzoan/cloudmax/workflow_dashboard || exit 1
WORKFLOW_DASHBOARD_PORT=5091 nohup python3 app.py > /tmp/wf_test_5091.log 2>&1 &
sleep 7
curl -s -o /tmp/idx2.html -w "index: HTTP %{http_code}\n" http://127.0.0.1:5091/
echo "new r6ace version param: $(grep -c 20260719mockbankdemo /tmp/idx2.html)"
echo "served js has demo seed: $(curl -s http://127.0.0.1:5091/static/r6ace.js | grep -c bs-mockbank-demo)"
