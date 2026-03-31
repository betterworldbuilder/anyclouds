#!/bin/bash
fuser -k 5001/tcp 2>/dev/null || true
pkill -9 -f 'python3 app.py' 2>/dev/null || true
cd /home/dzoan/OSPC2FLEX/osflex-deployer-2.0/workflow_dashboard
nohup python3 app.py > /tmp/flask_app.log 2>&1 &
echo "Started Flask!"
