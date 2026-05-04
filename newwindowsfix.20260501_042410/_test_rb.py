import sys, traceback
sys.path.insert(0, '/home/dzoan/OSPC2FLEX/osflex-deployer-2.0/workflow_dashboard')
from app import app
app.config['TESTING'] = True
with app.test_client() as c:
    try:
        r = c.post('/api/topology/rollback', json={'openrc_content':'','openrc_file':''})
        print('STATUS:', r.status_code)
        print('BODY:', r.data[:1200].decode())
    except Exception as e:
        traceback.print_exc()
