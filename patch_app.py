import sys
import re

app_path = '/home/dzoan/OSPC2FLEX/osflex-deployer-2.0/workflow_dashboard/app.py'

with open(app_path, 'r') as f:
    content = f.read()

content = content.replace(
    '#!/usr/bin/env python3\nimport csv',
    '#!/usr/bin/env python3\nimport sys\nimport csv',
    1,
)

content = content.replace(
    'BASE_DIR = Path(__file__).resolve().parents[1]\n',
    'BASE_DIR = Path(__file__).resolve().parents[1]\nPYTHON = sys.executable\n',
    1,
)

content = content.replace('\
