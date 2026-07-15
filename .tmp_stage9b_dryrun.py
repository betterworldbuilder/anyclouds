
import os, sys, json, tempfile
from pathlib import Path
os.environ['R6_CAPTURE_STATE_DIR']=tempfile.mkdtemp(prefix='r6-stage9b-test-')
sys.path.insert(0, '/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/workflow_dashboard')
import app as appmod
app=appmod.app
payload={
  'dryRun': True,
  'stage8Approved': True,
  'snapshotOnly': False,
  'snapshotAction': 'verify',
  'org': 'rackspace-flex',
  'cluster': 'flex-prod-k8s',
  'region': 'DFW3',
  'cloud': {'region':'DFW3'},
  'source_vm': {'host':'174.143.59.106','user':'ubuntu'},
  'capture': {'sshKeyPath':'~/.ssh/id_rsa','knownHostsFile':'./data/ssh/known_hosts','scope':'__all__'},
  'businessSystem': {'name':'System: Automatic Business System from Existing VMs','components': [
    {'name':'Web Frontend — linsnap-bankappfrontend-20260703-0007','targetForm':'CONTAINERIZED','tgt':'http://174.143.59.106:80'},
    {'name':'Core Banking Backend — linsnap-3Auth_Identity_Service_Core_Banking_Backend-20260701-2027','targetForm':'PARTIALLY_CONTAINERIZED','tgt':'http://174.143.59.142:80'},
    {'name':'linsnap-New_Ledger_Transfer_Service_Audit_Compliance_Log_Notification','targetForm':'CONTAINERIZED','tgt':'http://174.143.59.70:80'},
  ]},
  'bundle': {'id':'stage9b-dryrun','businessSystemName':'System: Automatic Business System from Existing VMs','workloads': [
    {'component':'Web Frontend — linsnap-bankappfrontend-20260703-0007','targetForm':'CONTAINERIZED','targetIp':'174.143.59.106','sourceVmId':'174.143.59.106','sourcePath':'/opt/app','applicationPaths':['/opt/app'],'startCommand':'','healthPath':'/health'},
    {'component':'Core Banking Backend — linsnap-3Auth_Identity_Service_Core_Banking_Backend-20260701-2027','targetForm':'PARTIALLY_CONTAINERIZED','targetIp':'174.143.59.142','sourceVmId':'174.143.59.142','sourcePath':'/opt/app','applicationPaths':['/opt/app'],'startCommand':'','healthPath':'/health'},
    {'component':'linsnap-New_Ledger_Transfer_Service_Audit_Compliance_Log_Notification','targetForm':'CONTAINERIZED','targetIp':'174.143.59.70','sourceVmId':'174.143.59.70','sourcePath':'/opt/app','applicationPaths':['/opt/app'],'startCommand':'','healthPath':'/health'},
  ]}
}
# Seed verified Stage 9A lineage exactly like previous result.
state=Path(os.environ['R6_CAPTURE_STATE_DIR'])
state.mkdir(parents=True, exist_ok=True)
idx={}
import hashlib
for w,sid in zip(payload['bundle']['workloads'],['d82b3318-1323-4ed5-98e8-db733415ef5d','264ca405-f386-4560-9882-d12c238ca01e','fe4e62dd-ee85-4fb1-a768-81a534f18dc7']):
    seed={'component':w['component'],'sourceVm':w['sourceVmId'],'targetForm':w['targetForm'],'applicationPaths':['/opt/app'],'excludedPaths':['/var/log','/tmp','/etc/ssh','/root/.ssh','/home/*/.ssh','/var/lib/postgresql','/var/lib/mysql','/var/lib/mongodb','/var/lib/redis','/var/backups'],'volumes':[]}
    checksum=hashlib.sha256(json.dumps(seed,sort_keys=True,default=str).encode()).hexdigest()
    idx[f"{w['sourceVmId']}:{w['component']}:{checksum[:16]}"]={'component':w['component'],'sourceVm':w['sourceVmId'],'snapshotKind':'vm_image_snapshot','snapshotIds':[sid],'snapshotNames':[f"r6-test-{w['sourceVmId']}"],'sourceChecksum':checksum,'createdAt':'20260714_000000','region':'DFW3','status':'ACTIVE'}
(state/'snapshot-index.json').write_text(json.dumps(idx,indent=2),encoding='utf-8')
with app.test_client() as c:
    r=c.post('/api/r6/capture-sources-build', json=payload)
    print('HTTP', r.status_code)
    data=r.get_json(silent=True)
    print(json.dumps(data, indent=2)[:6000])
    if r.status_code >= 400 or not data or not data.get('ok'):
        raise SystemExit(1)
    cap=data.get('capture') or {}
    assert cap.get('approvedCount') == 3, cap
    assert cap.get('missingSnapshots') == 0, cap
    assert len(cap.get('snapshotPairs') or []) == 3, cap
    assert data.get('extract_cmd'), 'missing extract_cmd'
print('PASS actual_stage9b_route_dryrun')
