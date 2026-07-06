/* ======================================================
   Apps to Containers Conversion Engine — Vertical Pipeline
   ====================================================== */

var _ace2 = {
  step: 1,
  source: null, bs: null, components: [],
  captureMethod: 'smart', compatConfirmed: false,
  stepStatus: {}, /* 1..12 => 'ns'|'ip'|'ok'|'warn'|'blocked' */
  artifacts: {},
  yaml: '', helm: '', kustomize: '', flux: '', bundle: null,
  excluded: [] /* IDs removed from conversion scope — persists across refreshes */
};

var ACE2_STEPS = [
  { n:1,  title:'Select FLEX Input',                   desc:'Choose a FLEX Business System or single FLEX VM/DB to convert.' },
  { n:2,  title:'Choose Capture Method',               desc:'Select Smart Snapshot Capture or Full Snapshot Compatibility.' },
  { n:3,  title:'Snapshot Capture / Selection',        desc:'Create or select the safe read-only capture point.' },
  { n:4,  title:'Snapshot Mount & Scan',               desc:'Mount snapshot read-only and scan the filesystem.' },
  { n:5,  title:'App Detection & File Classification', desc:'Detect runtime, ports, app paths, config, secrets, and classify files.' },
  { n:6,  title:'Container Readiness Assessment',      desc:'Determine readiness status for each component.' },
  { n:7,  title:'Container Build Plan',                desc:'Generate Dockerfile, image plan, start command, health checks.' },
  { n:8,  title:'State / Config / Secrets Externalization', desc:'Map config, secrets, volumes, logs, DB to Kubernetes targets.' },
  { n:9,  title:'Kubernetes YAML Generation',          desc:'Generate namespace, deployment, service, ingress, PVC, HPA, etc.' },
  { n:10, title:'Helm / Kustomize / Flux Packaging',   desc:'Package for GitOps with Helm, Kustomize overlays, and Flux.' },
  { n:11, title:'OpenCenter Import Bundle',            desc:'Assemble the final handoff package for OpenCenter.' },
  { n:12, title:'Send to OpenCenter GitOps',           desc:'Import bundle, generate commit commands, trigger Flux reconcile.' }
];

var ACE2_K8S = { frontend:'Deployment+Service+Ingress', web:'Deployment+Service+Ingress', api:'Deployment+Service', backend:'Deployment+Service', database:'ExternalDB', db:'ExternalDB', worker:'CronJob', batch:'CronJob', cache:'Deployment(Redis)', queue:'StatefulSet', lb:'Ingress/Gateway', storage:'PVC' };
var ACE2_READINESS = { database:'KEEP_ON_FLEX_VM_FOR_NOW', db:'KEEP_ON_FLEX_VM_FOR_NOW', cache:'READY_WITH_EXTERNALIZATION', queue:'COMPATIBILITY_CONTAINER_ONLY' };

/* ── Initialise ── */
window.ace2Init = function() {
  ace2RenderPipeline();
  ace2SelectStep(1);
  setTimeout(ace2RefreshBSList, 400);
};

/* ── Pipeline renderer ── */
window.ace2RenderPipeline = function() {
  var el = document.getElementById('ace2-pipeline'); if(!el) return;
  var statusColors = { ns:'#334155', ip:'#0369a1', ok:'#16a34a', warn:'#d97706', blocked:'#dc2626' };
  var statusLabel  = { ns:'Not Started', ip:'In Progress', ok:'Complete', warn:'Warning', blocked:'Blocked' };
  var badgeClass   = { ns:'badge-ns', ip:'badge-ip', ok:'badge-ok', warn:'badge-warn', blocked:'badge-blocked' };
  el.innerHTML = ACE2_STEPS.map(function(s) {
    var st = _ace2.stepStatus[s.n] || 'ns';
    var isActive = _ace2.step===s.n;
    return '<div class="ace2-step-item'+(isActive?' active':'')+'" onclick="ace2SelectStep('+s.n+')">'
      +'<div class="ace2-step-num" style="background:'+statusColors[st]+';color:#fff;">'+s.n+'</div>'
      +'<div class="ace2-step-body">'
      +'<div class="ace2-step-title">'+s.title+'</div>'
      +'<span class="ace2-step-badge '+badgeClass[st]+'">'+statusLabel[st]+'</span>'
      +'</div></div>';
  }).join('');
};

/* ── Step selection ── */
window.ace2SelectStep = function(n) {
  _ace2.step = n;
  ace2RenderPipeline();
  ace2RenderDetail(n);
  var bar = document.getElementById('ace2-bar-status');
  if(bar) bar.textContent = 'Step '+n+': '+ACE2_STEPS[n-1].title;
};

/* ── Detail panel renderer ── */
window.ace2RenderDetail = function(n) {
  var el = document.getElementById('ace2-detail'); if(!el) return;
  var s = ACE2_STEPS[n-1];
  var html = '<div class="ace2-detail-title">Step '+n+' &mdash; '+s.title+'</div>'
           + '<div class="ace2-detail-desc">'+s.desc+'</div>';
  if(n===1)  html += ace2DetailStep1();
  else if(n===2)  html += ace2DetailStep2();
  else if(n===3)  html += ace2DetailStep3();
  else if(n===4)  html += ace2DetailStep4();
  else if(n===5)  html += ace2DetailStep5();
  else if(n===6)  html += ace2DetailStep6();
  else if(n===7)  html += ace2DetailStep7();
  else if(n===8)  html += ace2DetailStep8();
  else if(n===9)  html += ace2DetailStep9();
  else if(n===10) html += ace2DetailStep10();
  else if(n===11) html += ace2DetailStep11();
  else if(n===12) html += ace2DetailStep12();
  el.innerHTML = html;
  /* Re-bind arch grid after render */
  if(n===1) setTimeout(ace2RefreshBSList, 100);
};

/* ── STEP 1: Select FLEX Input ── */
function ace2DetailStep1() {
  return '<div style="display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px;">'
    +'<div class="ace2-card-input'+((_ace2.source==='a')?' selected':'')+'" id="ace2-card-a" onclick="ace2SelectSource(\'a\')" style="flex:1;min-width:220px;">'
    +'<div style="font-size:14px;font-weight:800;color:#0f172a;margin-bottom:6px;">&#127970; FLEX Business System</div>'
    +'<div style="font-size:12px;color:#475569;margin-bottom:10px;">Convert all components of a migrated FLEX business system.</div>'
    +'<div style="font-size:11px;color:#64748b;"><strong style="color:#0369a1;">Requires:</strong> Business system in migration log on FLEX</div></div>'
    +'<div class="ace2-card-input'+((_ace2.source==='b')?' selected':'')+'" id="ace2-card-b" onclick="ace2SelectSource(\'b\')" style="flex:1;min-width:220px;">'
    +'<div style="font-size:14px;font-weight:800;color:#0f172a;margin-bottom:6px;">&#128187; Single FLEX VM / DB</div>'
    +'<div style="font-size:12px;color:#475569;margin-bottom:10px;">Convert or assess one FLEX VM, app VM, or DB endpoint.</div>'
    +'<div style="font-size:11px;color:#64748b;"><strong style="color:#0369a1;">Requires:</strong> Single FLEX VM or DB already on FLEX</div></div>'
    +'</div>'
    +(_ace2.source==='a' ? '<div>'
      +'<div style="display:flex;gap:8px;align-items:center;margin-bottom:10px;">'
      +'<div style="font-size:13px;font-weight:800;color:#0f172a;">FLEX Business Systems</div>'
      +'<button class="ace2-action-sec" onclick="ace2RefreshBSList()" style="padding:4px 10px;font-size:11px;">&#8635; Refresh</button>'
      +'<button onclick="ace2DeleteAll()" style="background:#fee2e2;color:#dc2626;border:1px solid #fca5a5;border-radius:6px;padding:4px 10px;font-size:11px;font-weight:700;cursor:pointer;">&#10006; Delete All</button>'
      +'</div>'
      +'<div class="uat-s1-biz-grid">'
      +'<div><div id="ace2-bs-list" style="min-height:200px;"></div></div>'
      +'<div class="uat-s1-arch-selector"><div class="uat-s1-arch-head"><div class="uat-s1-arch-title">Business System Templates</div><span class="uat-s1-arch-badge">10 Templates</span></div><div id="ace2-arch-grid" class="uat-s1-arch-grid"></div></div>'
      +'</div>'
      +(_ace2.components.length ? ace2CompTable() : '')
      +'<div style="margin-top:12px;"><button class="ace2-action-btn" onclick="ace2LoadBS()">Load FLEX Components</button><button class="ace2-action-btn" onclick="ace2SelectStep(2)">Continue to Capture Method &#8594;</button></div>'
      +'</div>'
      : _ace2.source==='b' ? '<div>'
      +'<div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:12px;">'
      +'<div><label style="display:block;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;margin-bottom:3px;">Type</label>'
      +'<select id="ace2-vm-type" style="width:100%;border:1px solid #e2e8f0;border-radius:6px;padding:7px 10px;font-size:12px;background:#fff;">'
      +'<option value="vm">FLEX App VM</option><option value="web">FLEX Web VM</option><option value="api">FLEX API VM</option><option value="worker">FLEX Worker VM</option><option value="db">FLEX Database VM</option><option value="dbendpoint">FLEX DB Endpoint</option>'
      +'</select></div>'
      +'<div><label style="display:block;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;margin-bottom:3px;">FLEX VM Name or ID</label>'
      +'<input id="ace2-vm-id" type="text" placeholder="flex-app-01" style="width:100%;border:1px solid #e2e8f0;border-radius:6px;padding:7px 10px;font-size:12px;box-sizing:border-box;"></div>'
      +'</div>'
      +'<iframe src="/image_migrator/?mode=flex2flex&embedded=1&focus=snapshot" style="width:100%;height:500px;border:1px solid #e2e8f0;border-radius:8px;"></iframe>'
      +'<div style="margin-top:12px;"><button class="ace2-action-btn" onclick="ace2RunSingle()">&#9654; Load VM Details</button><button class="ace2-action-btn" onclick="ace2SelectStep(2)">Continue &#8594;</button></div>'
      +'</div>'
      : '<div style="color:#94a3b8;font-size:13px;padding:20px;">Select an input source above to begin.</div>');
}

function ace2CompTable() {
  if(!_ace2.components.length) return '';
  return '<div style="margin-top:12px;overflow:auto;">'
    +'<div style="font-size:12px;font-weight:800;color:#0f172a;margin-bottom:6px;">FLEX Components ('+_ace2.components.length+')</div>'
    +'<table class="ace2-tbl"><thead><tr><th>Component</th><th>FLEX Source</th><th>Role</th><th>Runtime</th><th>Ports</th><th>K8s Target</th><th>Status</th></tr></thead><tbody>'
    +_ace2.components.map(function(c,i){
      var role=(c.type||c.role||'backend').toLowerCase();
      var k8s=ACE2_K8S[role]||'Deployment+Service';
      var r=ACE2_READINESS[role]||'READY';
      return '<tr><td style="font-weight:600;">'+c.name+'</td><td style="color:#0369a1;">'+(c.vmName||'-')+'</td><td><span style="background:#ede9fe;color:#6d28d9;padding:2px 7px;border-radius:999px;font-size:10px;font-weight:700;">'+role+'</span></td><td>'+(c.runtime||'-')+'</td><td>'+(c.ports?c.ports.join(','):'-')+'</td><td style="color:#7c3aed;font-size:11px;">'+k8s+'</td><td><span style="background:'+(r==='READY'?'#dcfce7':r.includes('EXTERNAL')||r.includes('KEEP')?'#dbeafe':'#fef3c7')+';color:'+(r==='READY'?'#16a34a':r.includes('EXTERNAL')||r.includes('KEEP')?'#1d4ed8':'#d97706')+';padding:2px 7px;border-radius:999px;font-size:10px;font-weight:700;">'+r.replace(/_/g,' ')+'</span></td></tr>';
    }).join('')
    +'</tbody></table></div>';
}

/* ── STEP 2: Capture Method ── */
function ace2DetailStep2() {
  var isSmart = _ace2.captureMethod==='smart';
  return '<div style="margin-bottom:16px;overflow:auto;">'
    +'<table class="ace2-tbl" style="margin-bottom:16px;"><thead><tr><th>Method</th><th>Best For</th><th>Cloud-native</th><th>Risk</th><th>Recommended</th></tr></thead><tbody>'
    +'<tr><td style="font-weight:700;color:#0369a1;">Smart Snapshot Capture</td><td>Normal FLEX apps</td><td><span style="background:#dcfce7;color:#16a34a;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">High</span></td><td><span style="background:#fef3c7;color:#d97706;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">Low</span></td><td><span style="background:#dcfce7;color:#16a34a;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">&#10003; Yes</span></td></tr>'
    +'<tr><td style="font-weight:700;color:#dc2626;">Full Snapshot Compatibility</td><td>Legacy apps</td><td><span style="background:#fee2e2;color:#dc2626;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">Low</span></td><td><span style="background:#fee2e2;color:#dc2626;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">High</span></td><td><span style="background:#fef3c7;color:#d97706;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">Fallback Only</span></td></tr>'
    +'</tbody></table></div>'
    +'<div style="display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px;">'
    +'<div class="ace2-method-card'+(isSmart?' selected':'')+'" onclick="ace2ApplyMethod(\'smart\')" style="flex:1;min-width:240px;">'
    +'<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;"><div style="font-size:14px;font-weight:800;">&#128247; Smart Snapshot Capture</div><span style="background:#dcfce7;color:#16a34a;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:800;">&#10003; Recommended</span></div>'
    +'<div style="font-size:12px;color:#475569;margin-bottom:8px;line-height:1.6;">Extracts only real app content from a read-only snapshot. Externalizes config, secrets, state. Generates clean K8s files.</div>'
    +'<div style="font-size:11px;color:#0369a1;"><strong>Best for:</strong> Normal Linux VMs, web apps, APIs, workers</div>'
    +'<div style="margin-top:8px;"><span style="background:#dcfce7;color:#16a34a;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">CLOUD_NATIVE_READY</span></div></div>'
    +'<div class="ace2-method-card'+((!isSmart&&_ace2.compatConfirmed)?' compat-selected':'')+'" onclick="ace2SelectMethod(\'compat\')" style="flex:1;min-width:240px;">'
    +'<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;"><div style="font-size:14px;font-weight:800;">&#128218; Full Snapshot Compatibility</div><span style="background:#fef3c7;color:#d97706;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:800;">Legacy Fallback</span></div>'
    +'<div style="font-size:12px;color:#475569;margin-bottom:8px;line-height:1.6;">Packages VM root filesystem into a compatibility container. Not fully cloud-native. Requires manual hardening.</div>'
    +'<div style="font-size:11px;color:#92400e;"><strong>Best for:</strong> Legacy apps, unknown structure, emergency POC</div>'
    +'<div style="margin-top:8px;"><span style="background:#fee2e2;color:#dc2626;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">COMPATIBILITY_CONTAINER_ONLY</span></div></div>'
    +'</div>'
    +'<div id="ace2-compat-confirm-box" style="display:none;background:#fff3cd;border:2px solid #ffc107;border-radius:8px;padding:14px;margin-bottom:14px;">'
    +'<div style="font-size:13px;font-weight:800;color:#856404;margin-bottom:8px;">&#9888; Confirm Full Snapshot Compatibility Mode</div>'
    +'<div style="font-size:12px;color:#664d03;margin-bottom:12px;">I understand this creates a compatibility container from a full VM snapshot. It is NOT fully cloud-native and requires manual hardening, security scanning, and image optimization before production.</div>'
    +'<button class="ace2-action-btn" style="background:#dc2626;" onclick="ace2ConfirmCompat()">&#10003; Confirm — Use Legacy Mode</button>'
    +'<button class="ace2-action-sec" onclick="ace2CancelCompat()">Cancel — Use Smart Snapshot</button>'
    +'</div>'
    +(_ace2.components.length ? '<div style="margin-bottom:14px;overflow:auto;"><div style="font-size:12px;font-weight:800;color:#0f172a;margin-bottom:8px;">Per-component Method Selection</div>'
    +'<table class="ace2-tbl"><thead><tr><th>Component</th><th>FLEX Source</th><th>Recommended Method</th><th>Selected Method</th><th>Reason</th></tr></thead><tbody>'
    +_ace2.components.map(function(c){
      var role=(c.type||c.role||'backend').toLowerCase();
      var isDb=role==='database'||role==='db';
      var rec=isDb?'ExternalDB':_ace2.captureMethod==='smart'?'Smart Snapshot':'Full Snapshot';
      return '<tr><td style="font-weight:600;">'+c.name+'</td><td style="color:#0369a1;">'+(c.vmName||'-')+'</td><td style="color:#16a34a;">'+rec+'</td><td>'+(isDb?'<span style="color:#1d4ed8;font-weight:700;">ExternalDB (locked)</span>':'<select style="font-size:11px;border:1px solid #e2e8f0;border-radius:4px;padding:2px 6px;"><option>Smart Snapshot</option><option>Full Snapshot</option></select>')+'</td><td style="color:#64748b;font-size:11px;">'+(isDb?'Stateful DB — keep external':role==='queue'?'Runtime unknown':'Normal app VM')+'</td></tr>';
    }).join('')
    +'</tbody></table></div>' : '')
    +'<div style="margin-top:8px;">'
    +'<button class="ace2-action-btn" onclick="ace2ApplyMethod(\'smart\');ace2SelectStep(3)">&#10003; Apply Smart Snapshot &amp; Continue &#8594;</button>'
    +'</div>';
}

/* ── STEP 3: Snapshot Capture ── */
function ace2DetailStep3() {
  return '<div style="background:#fef3c7;border:1px solid #fcd34d;border-radius:8px;padding:10px 14px;margin-bottom:14px;font-size:12px;color:#92400e;"><strong>Safe mode:</strong> Snapshots are mounted read-only. Smart Snapshot does NOT copy the whole VM.</div>'
    +(_ace2.components.length ? '<div style="overflow:auto;margin-bottom:14px;"><table class="ace2-tbl"><thead><tr><th>Component</th><th>FLEX VM</th><th>Method</th><th>Snapshot</th><th>Status</th><th>Action</th></tr></thead><tbody>'
    +_ace2.components.map(function(c,i){
      return '<tr><td style="font-weight:600;">'+c.name+'</td><td style="color:#0369a1;">'+(c.vmName||'flex-vm-'+(i+1))+'</td><td style="color:#7c3aed;font-size:11px;">'+(_ace2.captureMethod==='smart'?'Smart Snapshot':'Full Snapshot')+'</td><td>snap-'+(c.name||'comp').toLowerCase().replace(/\s+/g,'-')+'-001</td><td><span style="background:#dcfce7;color:#16a34a;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">Ready</span></td><td><button onclick="ace2RCmd(\'openstack server snapshot create '+( c.vmName||'flex-vm-'+(i+1))+'\',\'ace2-snap-out\')" style="background:#f1f5f9;color:#0369a1;border:1px solid #e2e8f0;border-radius:4px;padding:3px 10px;font-size:10px;cursor:pointer;">Create</button></td></tr>';
    }).join('')
    +'</tbody></table></div>' : '<div style="color:#94a3b8;font-size:12px;margin-bottom:14px;">Load FLEX components in Step 1 first.</div>')
    +'<div style="margin-bottom:10px;"><button class="ace2-action-btn" onclick="ace2RCmd(\'openstack server snapshot create flex-app --name ace2-snapshot\',\'ace2-snap-out\')">&#128247; Create Smart Snapshots</button>'
    +'<button class="ace2-action-sec" onclick="ace2RCmd(\'openstack image list --private --long\',\'ace2-snap-out\')">List Existing Snapshots</button>'
    +'<button class="ace2-action-sec" onclick="ace2RCmd(\'openstack volume snapshot list --long\',\'ace2-snap-out\')">Volume Snapshots</button></div>'
    +'<div id="ace2-snap-out" class="ace2-preview">$ Snapshot output will appear here...</div>';
}

/* ── STEP 4: Mount & Scan ── */
function ace2DetailStep4() {
  return '<div style="background:#0f172a;border-radius:8px;padding:12px;margin-bottom:14px;">'
    +'<div style="font-size:11px;font-weight:700;color:#7dd3fc;margin-bottom:8px;text-transform:uppercase;">Mount &amp; Scan Commands</div>'
    +'<pre style="color:#86efac;font-size:11px;white-space:pre-wrap;">sudo guestmount -a /dev/snap-device -i --ro /mnt/snap-capture\n\nfind /mnt/snap-capture -type f \\\n  -not -path "*/proc/*" -not -path "*/sys/*" \\\n  -not -path "*/dev/*" -not -path "*/boot/*" | head -50\n\n# Detect runtime\nls /mnt/snap-capture/usr/bin/node /usr/bin/python* 2>/dev/null</pre></div>'
    +'<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:14px;">'
    +['OS Type/Version','CPU/RAM','Attached Volumes','Open Ports','Running Services','Systemd Services','Cron Jobs','App Runtime','Config Files','Secrets Candidates','Log Paths','DB Dependencies'].map(function(item,i){
      var found=['Ubuntu 22.04','4 vCPU / 8GB','2 volumes (10GB, 50GB)','3000, 80, 443','nginx, node, postgres','app.service, nginx','3 cron jobs','Node.js 20','app.env, config.yaml','1 .env file detected','2 log dirs','postgres:5432'][i]||'Scanning...';
      return '<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:8px 10px;"><div style="font-size:10px;font-weight:700;color:#64748b;text-transform:uppercase;margin-bottom:3px;">'+item+'</div><div style="font-size:12px;color:#0f172a;font-weight:700;">'+found+'</div></div>';
    }).join('')
    +'</div>'
    +'<button class="ace2-action-btn" onclick="ace2RCmd(\'echo Mounting snapshot read-only... && echo Scanning filesystem...\',\'ace2-mount-out\')">&#128270; Mount &amp; Scan Snapshot</button>'
    +'<div id="ace2-mount-out" class="ace2-preview">$ Mount and scan output will appear here...</div>';
}

/* ── STEP 5: App Detection & Classification ── */
function ace2DetailStep5() {
  var classifications=[
    ['app_code','/opt/customer-api/src/','Container image'],
    ['app_binary','/opt/customer-api/bin/server','Container image'],
    ['config_template','/etc/customer-api/app.env','ConfigMap'],
    ['secret_candidate','/opt/customer-api/.env','Secret / SOPS'],
    ['log_file','/var/log/customer-api/','stdout/stderr'],
    ['upload_data','/data/uploads/','Object storage / PVC'],
    ['database_data','/var/lib/postgresql/','ExternalDB (exclude from container)'],
    ['system_file','/etc/systemd/','Excluded'],
    ['boot_file','/boot/','Excluded'],
    ['temp_file','/tmp/','Excluded']
  ];
  return '<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:14px;">'
    +'<div style="background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:10px;"><div style="font-size:10px;font-weight:700;color:#0369a1;text-transform:uppercase;margin-bottom:3px;">Detected Runtime</div><div style="font-size:14px;font-weight:900;color:#0f172a;">Node.js 20</div></div>'
    +'<div style="background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:10px;"><div style="font-size:10px;font-weight:700;color:#0369a1;text-transform:uppercase;margin-bottom:3px;">Detected Ports</div><div style="font-size:14px;font-weight:900;color:#0f172a;">3000, 443</div></div>'
    +'<div style="background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:10px;"><div style="font-size:10px;font-weight:700;color:#0369a1;text-transform:uppercase;margin-bottom:3px;">App Path</div><div style="font-size:14px;font-weight:900;color:#0f172a;">/opt/customer-api</div></div>'
    +'<div style="background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:10px;"><div style="font-size:10px;font-weight:700;color:#dc2626;text-transform:uppercase;margin-bottom:3px;">Secrets Detected</div><div style="font-size:14px;font-weight:900;color:#dc2626;">.env file found</div></div>'
    +'<div style="background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:10px;"><div style="font-size:10px;font-weight:700;color:#0369a1;text-transform:uppercase;margin-bottom:3px;">Startup Command</div><div style="font-size:14px;font-weight:900;color:#0f172a;">npm start</div></div>'
    +'<div style="background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:10px;"><div style="font-size:10px;font-weight:700;color:#7c3aed;text-transform:uppercase;margin-bottom:3px;">K8s Target</div><div style="font-size:14px;font-weight:900;color:#7c3aed;">Deployment+Service</div></div>'
    +'</div>'
    +'<div style="overflow:auto;margin-bottom:12px;"><table class="ace2-tbl"><thead><tr><th>Path</th><th>Classification</th><th>K8s Target</th><th>Include</th></tr></thead><tbody>'
    +classifications.map(function(r){
      var isExc=r[0]==='system_file'||r[0]==='boot_file'||r[0]==='temp_file';
      var colors={app_code:'#dcfce7,#16a34a',config_template:'#dbeafe,#1d4ed8',secret_candidate:'#fee2e2,#dc2626',log_file:'#fef3c7,#d97706',upload_data:'#fef3c7,#d97706',database_data:'#fee2e2,#dc2626',system_file:'#f1f5f9,#94a3b8',boot_file:'#f1f5f9,#94a3b8',temp_file:'#f1f5f9,#94a3b8',app_binary:'#dcfce7,#16a34a'};
      var c=(colors[r[0]]||'#f1f5f9,#94a3b8').split(',');
      return '<tr><td style="font-family:monospace;font-size:11px;color:#0f172a;">'+r[1]+'</td><td><span style="background:'+c[0]+';color:'+c[1]+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+r[0]+'</span></td><td style="color:#6d28d9;font-size:11px;">'+r[2]+'</td><td style="text-align:center;"><input type="checkbox" '+(isExc?'':'checked')+'></td></tr>';
    }).join('')
    +'</tbody></table></div>'
    +'<button class="ace2-action-btn" onclick="ace2RunDetection()">&#9656; Run App Detection</button>'
    +'<button class="ace2-action-sec" onclick="ace2RCmd(\'find /mnt/snap-capture/opt -type f | head -30\',\'ace2-detect-out\')">Scan App Paths</button>'
    +'<div id="ace2-detect-out" class="ace2-preview">$ Detection output will appear here...</div>';
}

/* ── STEP 6: Readiness ── */
function ace2DetailStep6() {
  var buckets=[
    ['CLOUD_NATIVE_READY','#dcfce7','#16a34a',_ace2.components.filter(function(c){var r=(c.type||c.role||'').toLowerCase();return r!=='database'&&r!=='queue';}).length],
    ['READY_WITH_EXTERNALIZATION','#fef3c7','#d97706',1],
    ['KEEP_ON_FLEX_VM_FOR_NOW','#dbeafe','#1d4ed8',_ace2.components.filter(function(c){return (c.type||c.role||'').toLowerCase()==='database';}).length],
    ['COMPATIBILITY_ONLY','#fee2e2','#dc2626',_ace2.components.filter(function(c){return (c.type||c.role||'').toLowerCase()==='queue';}).length],
    ['BLOCKED','#f1f5f9','#94a3b8',0]
  ];
  return '<div style="display:grid;grid-template-columns:repeat(5,1fr);gap:8px;margin-bottom:16px;">'
    +buckets.map(function(b){ return '<div style="background:'+b[1]+';border-radius:8px;padding:12px;text-align:center;"><div style="font-size:22px;font-weight:900;color:'+b[2]+';">'+b[3]+'</div><div style="font-size:9px;color:'+b[2]+';font-weight:700;margin-top:4px;">'+b[0]+'</div></div>'; }).join('')
    +'</div>'
    +(_ace2.components.length ? '<div style="overflow:auto;margin-bottom:12px;"><table class="ace2-tbl"><thead><tr><th>Component</th><th>Readiness</th><th>Reason</th><th>Required Action</th></tr></thead><tbody>'
    +_ace2.components.map(function(c){
      var role=(c.type||c.role||'backend').toLowerCase();
      var r=role==='database'||role==='db'?['KEEP_ON_FLEX_VM_FOR_NOW','#dbeafe','#1d4ed8','Generate ExternalDB reference']:role==='queue'?['COMPATIBILITY_ONLY','#fee2e2','#dc2626','Review full snapshot container']:['CLOUD_NATIVE_READY','#dcfce7','#16a34a','None'];
      return '<tr><td style="font-weight:600;">'+c.name+'</td><td><span style="background:'+r[1]+';color:'+r[2]+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+r[0]+'</span></td><td style="color:#64748b;font-size:11px;">'+(role==='database'?'Stateful DB':role==='queue'?'Runtime unknown':'Stateless app')+'</td><td style="color:#64748b;font-size:11px;">'+r[3]+'</td></tr>';
    }).join('')+'</tbody></table></div>' : '')
    +'<button class="ace2-action-btn" onclick="ace2RunEngine()">&#9656; Run Readiness Assessment</button>'
    +'<button class="ace2-action-sec" onclick="ace2DownloadArtifact(\'container_readiness_assessment.json\')">&#11015; readiness.json</button>'
    +'<button class="ace2-action-sec" onclick="ace2DownloadArtifact(\'container_readiness_assessment.md\')">&#11015; readiness.md</button>';
}

/* ── STEP 7: Build Plan ── */
function ace2DetailStep7() {
  var isCompat=_ace2.captureMethod==='compat';
  var dockerfile=isCompat?'FROM ubuntu:22.04\n\nCOPY rootfs/ /\nCOPY start-compat.sh /start-compat.sh\nRUN chmod +x /start-compat.sh\n\nEXPOSE 80\nCMD ["/start-compat.sh"]\n\n# ⚠ Compatibility container — manual hardening required':'FROM node:20-alpine\nWORKDIR /app\nCOPY package*.json ./\nRUN npm ci --production\nCOPY . .\nEXPOSE 3000\nHEALTHCHECK --interval=30s CMD wget -qO- http://localhost:3000/health\nCMD ["npm","start"]';
  return (_ace2.components.length ? '<div style="overflow:auto;margin-bottom:14px;"><table class="ace2-tbl"><thead><tr><th>Component</th><th>Image</th><th>Start Cmd</th><th>Port</th><th>Health</th><th>CPU</th><th>Mem</th></tr></thead><tbody>'
    +_ace2.components.filter(function(c){return (c.type||c.role||'').toLowerCase()!=='database';}).map(function(c){
      var role=(c.type||c.role||'backend').toLowerCase();
      var img=isCompat?'ubuntu:22.04':(role==='frontend'||role==='web'?'nginx:1.25-alpine':role==='api'?'node:20-alpine':'python:3.11-slim');
      return '<tr><td style="font-weight:600;">'+c.name+'</td><td style="font-family:monospace;font-size:11px;color:#0369a1;">'+img+'</td><td style="font-family:monospace;font-size:11px;">npm start</td><td>'+(c.ports&&c.ports[0]||'8080')+'</td><td style="font-size:11px;">/health 200</td><td>500m</td><td>512Mi</td></tr>';
    }).join('')+'</tbody></table></div>' : '')
    +'<div style="font-size:12px;font-weight:700;color:#0f172a;margin-bottom:6px;">Generated Dockerfile</div>'
    +'<pre class="ace2-preview">'+dockerfile+'</pre>'
    +'<div style="margin-top:10px;"><button class="ace2-action-btn" onclick="ace2RunEngine()">&#9656; Generate Dockerfiles</button>'
    +'<button class="ace2-action-sec" onclick="ace2DownloadArtifact(\'image_build_plan.yaml\')">&#11015; image_build_plan.yaml</button></div>';
}

/* ── STEP 8: Externalization ── */
function ace2DetailStep8() {
  var rows=[
    ['.env file','/opt/app/.env','ConfigMap + SOPS Secret','&#10003;'],
    ['DB password','OS environment var','SOPS Secret placeholder','&#10003;'],
    ['Local logs','/var/log/app/','stdout/stderr (Loki)','&#10003;'],
    ['Upload folder','/data/uploads/','PVC or object storage','&#9888;'],
    ['Database VM','postgres VM','ExternalDB reference','&#10003;'],
    ['Cron job','crontab -l','Kubernetes CronJob','&#10003;'],
    ['Session store','Redis socket','External Redis service','&#9888;']
  ];
  return '<div style="overflow:auto;margin-bottom:14px;"><table class="ace2-tbl"><thead><tr><th>VM Pattern</th><th>Source</th><th>Kubernetes/OpenCenter Target</th><th>Status</th></tr></thead><tbody>'
    +rows.map(function(r){ return '<tr><td style="font-weight:600;">'+r[0]+'</td><td style="font-family:monospace;font-size:11px;color:#64748b;">'+r[1]+'</td><td style="color:#7c3aed;font-size:11px;">'+r[2]+'</td><td style="text-align:center;font-size:16px;">'+r[3]+'</td></tr>'; }).join('')
    +'</tbody></table></div>'
    +'<div style="display:flex;flex-wrap:wrap;">'
    +'<button class="ace2-action-btn">Generate ConfigMap</button>'
    +'<button class="ace2-action-btn">Generate Secret Placeholder</button>'
    +'<button class="ace2-action-sec">Generate PVC Plan</button>'
    +'<button class="ace2-action-sec">Generate ExternalDB Reference</button>'
    +'<button class="ace2-action-sec" onclick="ace2DownloadArtifact(\'externalization_plan.md\')">&#11015; externalization_plan.md</button>'
    +'</div>';
}

/* ── STEP 9: K8s YAML ── */
function ace2DetailStep9() {
  var files=['namespace.yaml','deployment.yaml','service.yaml','ingress.yaml','httproute.yaml','configmap.yaml','secret.sops.yaml','pvc.yaml','networkpolicy.yaml','hpa.yaml','pdb.yaml','servicemonitor.yaml','cronjob.yaml','external-db.yaml'];
  return '<div style="display:flex;gap:8px;margin-bottom:12px;flex-wrap:wrap;">'
    +'<button class="ace2-action-btn" onclick="ace2GenYAML()">&#9656; Generate All YAML</button>'
    +'<button class="ace2-action-sec" onclick="navigator.clipboard&&navigator.clipboard.writeText(document.getElementById(\'ace2-yaml-preview\')&&document.getElementById(\'ace2-yaml-preview\').textContent)">&#128203; Copy</button>'
    +'<button class="ace2-action-sec" onclick="ace2DownloadArtifact(\'k8s-manifests.yaml\')">&#11015; Download</button>'
    +'</div>'
    +'<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:6px;margin-bottom:12px;">'
    +files.map(function(f){ var ready=_ace2.artifacts.yaml;return '<div style="background:'+(ready?'#f0fdf4':'#f8fafc')+';border:1px solid '+(ready?'#86efac':'#e2e8f0')+';border-radius:6px;padding:6px 10px;font-family:monospace;font-size:11px;color:'+(ready?'#16a34a':'#64748b')+';">'+f+'</div>'; }).join('')
    +'</div>'
    +'<pre id="ace2-yaml-preview" class="ace2-preview">'+(_ace2.yaml||'-- Generate YAML to see preview --')+'</pre>';
}

/* ── STEP 10: Helm/Kustomize/Flux ── */
function ace2DetailStep10() {
  var n=(_ace2.bs&&_ace2.bs.name||'app').toLowerCase().replace(/\s+/g,'-');
  return '<div style="display:flex;gap:8px;margin-bottom:12px;flex-wrap:wrap;">'
    +'<button class="ace2-action-btn" onclick="ace2GenHelm()">Generate Helm Chart</button>'
    +'<button class="ace2-action-btn" onclick="ace2GenKustomize()">Generate Kustomize Bundle</button>'
    +'<button class="ace2-action-btn" onclick="ace2GenFlux()">Generate Flux Kustomization</button>'
    +'</div>'
    +'<div style="background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:14px;font-family:monospace;font-size:12px;color:#334155;margin-bottom:12px;line-height:1.8;">'
    +'opencenter-app-bundle/<br>'
    +'&nbsp;&nbsp;helm/<br>'
    +'&nbsp;&nbsp;&nbsp;&nbsp;Chart.yaml<br>'
    +'&nbsp;&nbsp;&nbsp;&nbsp;values.yaml<br>'
    +'&nbsp;&nbsp;&nbsp;&nbsp;templates/<br>'
    +'&nbsp;&nbsp;kustomize/<br>'
    +'&nbsp;&nbsp;&nbsp;&nbsp;base/<br>'
    +'&nbsp;&nbsp;&nbsp;&nbsp;overlays/<br>'
    +'&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;dev/<br>'
    +'&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;uat/<br>'
    +'&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;prod/<br>'
    +'&nbsp;&nbsp;flux/<br>'
    +'&nbsp;&nbsp;&nbsp;&nbsp;app-kustomization.yaml<br>'
    +'</div>'
    +'<pre id="ace2-gitops-preview" class="ace2-preview">'+(_ace2.helm||_ace2.kustomize||_ace2.flux||'-- Generate to see preview --')+'</pre>';
}

/* ── STEP 11: OpenCenter Bundle ── */
function ace2DetailStep11() {
  var files=[
    'opencenter_import_manifest.json','business_system_modernization.yaml',
    'business_system_topology.json','flex_source_mapping.json',
    'app_capture_manifest.json','container_readiness_assessment.json',
    'image_build_plan.yaml','state_config_externalization.json',
    'externalization_plan.md','helm/','kustomize/','flux/','README_OpenCenter_Import.md'
  ];
  return '<div style="background:#fff;border:1px solid #e2e8f0;border-radius:8px;overflow:hidden;margin-bottom:14px;">'
    +'<div style="padding:8px 14px;background:#f8fafc;border-bottom:1px solid #e2e8f0;font-size:12px;font-weight:800;color:#0f172a;">Bundle Artifacts Checklist</div>'
    +files.map(function(f){ var ready=!!_ace2.bundle;return '<div class="ace2-artifact-row"><span style="font-family:monospace;font-size:12px;color:#334155;">'+f+'</span><span style="background:'+(ready?'#dcfce7':'#f1f5f9')+';color:'+(ready?'#16a34a':'#94a3b8')+';padding:2px 10px;border-radius:999px;font-size:10px;font-weight:700;">'+(ready?'Generated':'Pending')+'</span></div>'; }).join('')
    +'</div>'
    +'<div style="display:flex;flex-wrap:wrap;margin-bottom:12px;">'
    +'<button class="ace2-action-btn" onclick="ace2GenBundle()">&#9656; Generate OpenCenter Bundle</button>'
    +'<button class="ace2-action-sec" onclick="ace2DownloadArtifact(\'opencenter_import_manifest.json\')">&#11015; Download Bundle</button>'
    +'<button class="ace2-action-sec" onclick="ace2GenBundle();ace2SendToOpenCenter()">&#128640; Send to OpenCenter</button>'
    +'</div>'
    +'<pre id="ace2-bundle-preview" class="ace2-preview">'+(_ace2.bundle?JSON.stringify(_ace2.bundle,null,2):'-- Generate bundle to see manifest --')+'</pre>';
}

/* ── STEP 12: Send to OpenCenter GitOps ── */
function ace2DetailStep12() {
  var n=(_ace2.bs&&_ace2.bs.name||'app').toLowerCase().replace(/\s+/g,'-');
  return '<div style="display:flex;gap:6px;align-items:center;font-size:11px;background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:12px;margin-bottom:14px;flex-wrap:wrap;">'
    +'<span style="background:#dcfce7;color:#16a34a;padding:3px 10px;border-radius:999px;font-weight:700;">Import Bundle</span>&#8594;'
    +'<span style="background:#eef2ff;color:#4f46e5;padding:3px 10px;border-radius:999px;">Validate</span>&#8594;'
    +'<span style="background:#eef2ff;color:#4f46e5;padding:3px 10px;border-radius:999px;">Copy to Repo</span>&#8594;'
    +'<span style="background:#eef2ff;color:#4f46e5;padding:3px 10px;border-radius:999px;">Commit</span>&#8594;'
    +'<span style="background:#eef2ff;color:#4f46e5;padding:3px 10px;border-radius:999px;">Flux Reconcile</span>&#8594;'
    +'<span style="background:#ede9fe;color:#6d28d9;padding:3px 10px;border-radius:999px;font-weight:700;">Production K8s</span>'
    +'</div>'
    +'<div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:14px;">'
    +'<div style="background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:10px;"><div style="font-size:10px;font-weight:700;color:#64748b;text-transform:uppercase;margin-bottom:3px;">Target Cluster</div><div style="font-size:13px;font-weight:800;color:#0f172a;">flex-prod-k8s</div></div>'
    +'<div style="background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:10px;"><div style="font-size:10px;font-weight:700;color:#64748b;text-transform:uppercase;margin-bottom:3px;">Namespace</div><div style="font-size:13px;font-weight:800;color:#0f172a;">'+n+'</div></div>'
    +'<div style="background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:10px;grid-column:1/-1;"><div style="font-size:10px;font-weight:700;color:#64748b;text-transform:uppercase;margin-bottom:3px;">GitOps Repo Path</div><div style="font-size:12px;font-family:monospace;color:#0f172a;">applications/workloads/'+n+'</div></div>'
    +'</div>'
    +'<div style="display:flex;flex-wrap:wrap;margin-bottom:12px;">'
    +'<button class="ace2-action-btn" style="background:#16a34a;" onclick="ace2GenBundle();ace2SendToOpenCenter()">&#128640; Send to OpenCenter GitOps Stage</button>'
    +'<button class="ace2-action-sec" onclick="ace2GenBundle()">&#9656; Generate Commit Commands</button>'
    +'<button class="ace2-action-sec" onclick="ace2DownloadArtifact(\'opencenter_import_manifest.json\')">&#11015; Download Bundle</button>'
    +'</div>'
    +'<div id="ace2-send-status" style="font-size:12px;color:#16a34a;font-weight:700;"></div>';
}

/* ── Source / Method helpers ── */
window.ace2SelectSource = function(src) {
  _ace2.source = src;
  ace2SetStepStatus(1, 'ip');
  ace2RenderDetail(1);
  var sum = document.getElementById('ace2-sum-input');
  if(sum) sum.textContent = src==='a' ? 'FLEX Business System' : 'Single FLEX VM/DB';
  if(src==='a') setTimeout(ace2RefreshBSList, 100);
};

window.ace2ApplyMethod = function(method) {
  _ace2.captureMethod = method;
  var sum = document.getElementById('ace2-sum-method');
  if(sum) sum.textContent = method==='smart' ? 'Smart Snapshot' : 'Full Snapshot Compat';
  var banner = document.getElementById('ace2-compat-banner');
  if(banner) banner.style.display = method==='compat' ? 'block' : 'none';
  ace2SetStepStatus(2, 'ok');
  ace2RenderPipeline();
};

window.ace2SelectMethod = function(method) {
  if(method==='compat') {
    var box = document.getElementById('ace2-compat-confirm-box');
    if(box) box.style.display='block';
  } else {
    ace2ApplyMethod('smart');
  }
};
window.ace2ConfirmCompat = function() { _ace2.compatConfirmed=true; ace2ApplyMethod('compat'); var b=document.getElementById('ace2-compat-confirm-box'); if(b)b.style.display='none'; };
window.ace2CancelCompat = function() { var b=document.getElementById('ace2-compat-confirm-box'); if(b)b.style.display='none'; ace2ApplyMethod('smart'); };

/* ── Business Systems ── */
window.ace2RefreshBSList = function() {
  var list = document.getElementById('ace2-bs-list'); if(!list) return;
  try {
    var allSys = JSON.parse(localStorage.getItem('uatS1_systems')||'[]');
    /* Filter out systems the user has removed from scope */
    var sys = allSys.filter(function(s){ return _ace2.excluded.indexOf(s.id)<0; });
    if(!sys.length) {
      var hasExcluded = allSys.length > 0;
      list.innerHTML = '<div style="color:#94a3b8;font-size:12px;padding:12px;">'+(hasExcluded?'All systems removed from scope. <button onclick="_ace2.excluded=[];ace2RefreshBSList()" style="background:#eff6ff;color:#0369a1;border:1px solid #bfdbfe;border-radius:4px;padding:2px 8px;font-size:11px;cursor:pointer;">Restore All</button>':'No business systems. Create them in Migration Logs first.')+'</div>';
      return;
    }
    list.innerHTML = sys.map(function(s){
      return '<div onclick="ace2SelectBS(\''+s.id+'\')" id="ace2-bsc-'+s.id+'" style="border:1px solid #e2e8f0;border-radius:8px;padding:10px 12px;margin-bottom:8px;cursor:pointer;background:#fff;position:relative;">'
        +'<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:3px;">'
        +'<div style="font-weight:800;color:#0f172a;font-size:13px;">'+s.name+'</div>'
        +'<div style="display:flex;align-items:center;gap:6px;">'
        +'<span style="background:#dcfce7;color:#16a34a;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">Active</span>'
        +'<button onclick="event.stopPropagation();ace2DeleteBS(\''+s.id+'\')" style="background:#fee2e2;color:#dc2626;border:none;border-radius:4px;width:20px;height:20px;font-size:12px;font-weight:900;cursor:pointer;display:grid;place-items:center;line-height:1;padding:0;" title="Remove from conversion scope">&times;</button>'
        +'</div></div>'
        +'<div style="font-size:11px;color:#64748b;">'+(s.components||[]).length+' components</div></div>';
    }).join('');
  } catch(e) {}
  var ag=document.getElementById('ace2-arch-grid'), lg=document.getElementById('uatS1ArchList');
  if(ag&&lg&&lg.innerHTML.trim()) {
    ag.innerHTML=lg.innerHTML;
    ag.querySelectorAll('.uat-s1-arch-card').forEach(function(c){
      c.style.cursor='pointer';
      c.addEventListener('click',function(){
        ag.querySelectorAll('.uat-s1-arch-card').forEach(function(x){x.classList.remove('selected');}); c.classList.add('selected');
        var k=c.getAttribute('data-arch-key');
        if(typeof window.uatS1OpenModal==='function') window.uatS1OpenModal(null,k);
        else if(typeof window.uatS1SelectArchetype==='function') window.uatS1SelectArchetype(k);
      });
    });
  }
};

window.ace2DeleteBS = function(id) {
  /* Add to excluded list so it stays removed even after refresh */
  if(_ace2.excluded.indexOf(id)<0) _ace2.excluded.push(id);
  var card = document.getElementById('ace2-bsc-'+id);
  if(card) { card.style.opacity='0'; card.style.transition='opacity .2s'; setTimeout(function(){ card.remove(); },200); }
  if(_ace2.bs && _ace2.bs.id===id) {
    _ace2.bs=null; _ace2.components=[];
    var sec=document.getElementById('ace2-comp-section'); if(sec) sec.style.display='none';
    var si=document.getElementById('ace2-sum-input'); if(si) si.textContent='Not selected';
    var sc=document.getElementById('ace2-sum-comps'); if(sc) sc.textContent='0';
    ace2SetStepStatus(1,'ns'); ace2RenderPipeline();
  }
};

window.ace2DeleteAll = function() {
  if(!confirm('Remove all business systems from conversion scope? (Does not delete from Migration Log)')) return;
  try {
    var sys = JSON.parse(localStorage.getItem('uatS1_systems')||'[]');
    sys.forEach(function(s){ if(_ace2.excluded.indexOf(s.id)<0) _ace2.excluded.push(s.id); });
  } catch(e){}
  _ace2.bs=null; _ace2.components=[];
  var list=document.getElementById('ace2-bs-list'); if(list) list.innerHTML='<div style="color:#94a3b8;font-size:12px;padding:12px;">All systems removed from scope. Add a new system or use a template.</div>';
  var sec=document.getElementById('ace2-comp-section'); if(sec) sec.style.display='none';
  var si=document.getElementById('ace2-sum-input'); if(si) si.textContent='Not selected';
  var sc=document.getElementById('ace2-sum-comps'); if(sc) sc.textContent='0';
  ace2SetStepStatus(1,'ns'); ace2RenderPipeline();
};

window.ace2SelectBS = function(id) {
  document.querySelectorAll('[id^="ace2-bsc-"]').forEach(function(el){ el.style.borderColor='#e2e8f0'; el.style.background='#fff'; el.style.boxShadow='none'; });
  var c=document.getElementById('ace2-bsc-'+id); if(c){ c.style.borderColor='#38bdf8'; c.style.background='#e0f2fe'; c.style.boxShadow='0 0 0 3px rgba(56,189,248,.2)'; }
  try {
    var sys=JSON.parse(localStorage.getItem('uatS1_systems')||'[]');
    var bs=sys.find(function(s){return s.id===id;}); if(!bs) return;
    _ace2.bs=bs; _ace2.components=bs.components||[];
    var sum=document.getElementById('ace2-sum-input'); if(sum) sum.textContent=bs.name;
    var sc=document.getElementById('ace2-sum-comps'); if(sc) sc.textContent=_ace2.components.length+' components';
    ace2SetStepStatus(1,'ok'); ace2RenderDetail(1); ace2RenderPipeline();
  } catch(e){}
};

window.ace2LoadBS = function() { ace2RefreshBSList(); var first=document.querySelector('[id^="ace2-bsc-"]'); if(first) first.click(); };
window.ace2RunSingle = function() { var id=document.getElementById('ace2-vm-id'),type=document.getElementById('ace2-vm-type'); _ace2.components=[{name:(id&&id.value)||'flex-vm-01',type:(type&&type.value)||'vm',vmName:(id&&id.value)||'flex-vm-01',ports:['3000'],runtime:'nodejs'}]; ace2SetStepStatus(1,'ok'); ace2RenderPipeline(); };

/* ── Run & nav ── */
window.ace2RunStep = function() {
  var n=_ace2.step;
  ace2SetStepStatus(n,'ip');
  ace2RenderPipeline();
  if(n===5||n===6) { ace2RunDetection(); ace2SetStepStatus(n,'ok'); }
  else if(n===7||n===9) { ace2RunEngine(); ace2SetStepStatus(n,'ok'); }
  else if(n===11) { ace2GenBundle(); ace2SetStepStatus(n,'ok'); }
  else { setTimeout(function(){ ace2SetStepStatus(n,'ok'); ace2RenderPipeline(); }, 600); }
};
window.ace2Next = function() { if(_ace2.step<12) ace2SelectStep(_ace2.step+1); };
window.ace2Prev = function() { if(_ace2.step>1) ace2SelectStep(_ace2.step-1); };
window.ace2RunAll = function() { ace2RunEngine(); ace2GenYAML(); ace2GenHelm(); ace2GenKustomize(); ace2GenFlux(); ace2GenBundle(); [3,4,5,6,7,8,9,10,11].forEach(function(n){ace2SetStepStatus(n,'ok');}); ace2RenderPipeline(); ace2SelectStep(11); };

window.ace2SetStepStatus = function(n,st) { _ace2.stepStatus[n]=st; };

/* ── Engine functions ── */
window.ace2RunDetection = function() {
  _ace2.artifacts.detect=true;
  var out=document.getElementById('ace2-detect-out');
  if(out) out.textContent='[Smart Snapshot App Detection]\nRuntime: Node.js 20\nApp path: /opt/customer-api\nPorts: 3000\nStart: npm start\nConfig: /etc/customer-api/app.env\nSecrets: .env detected [WARNING]\nLogs: /var/log/customer-api\nDB dependency: postgres:5432\nRecommendation: CLOUD_NATIVE_READY with externalization';
};

window.ace2RunEngine = function() {
  if(!_ace2.components.length){ alert('Load FLEX components first.'); return; }
  _ace2.artifacts.yaml=true; _ace2.artifacts.dockerfile=true;
  ace2GenYAML();
  var isC=_ace2.captureMethod==='compat';
  var bb=document.getElementById('ace2-build-table');
  if(bb) bb.innerHTML=_ace2.components.filter(function(c){return (c.type||c.role||'').toLowerCase()!=='database';}).map(function(c){
    var role=(c.type||c.role||'backend').toLowerCase();
    var img=isC?'ubuntu:22.04':(role==='frontend'||role==='web'?'nginx:1.25-alpine':role==='api'?'node:20-alpine':'python:3.11-slim');
    return '<tr style="border-bottom:1px solid #f1f5f9;"><td style="padding:6px 10px;font-weight:600;font-size:12px;">'+c.name+'</td><td style="padding:6px 10px;color:#64748b;font-size:12px;">'+role+'</td><td style="padding:6px 10px;color:#0369a1;font-family:monospace;font-size:11px;">'+img+'</td><td style="padding:6px 10px;color:#64748b;font-size:11px;">npm start</td><td style="padding:6px 10px;color:#64748b;font-size:12px;">'+(c.ports&&c.ports[0]||'8080')+'</td><td style="padding:6px 10px;color:#64748b;font-size:11px;">/health</td><td style="padding:6px 10px;color:#64748b;font-size:11px;">500m/512Mi</td></tr>';
  }).join('');
};

window.ace2GenYAMLFor = function(c) {
  var role=(c.type||c.role||'backend').toLowerCase();
  var n=(c.name||'app').toLowerCase().replace(/\s+/g,'-').replace(/[^a-z0-9-]/g,'');
  var cm='# captureMethod: '+_ace2.captureMethod+'\n';
  if(role==='database'||role==='db') return cm+'# ExternalDB: '+n+' stays on FLEX\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: '+n+'-db-config\ndata:\n  host: "REPLACE_WITH_FLEX_DB_HOST"\n  port: "5432"\n---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: '+n+'-db-secret\ntype: Opaque\nstringData:\n  password: "REPLACE"\n';
  if(role==='worker'||role==='batch') return cm+'apiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: '+n+'\nspec:\n  schedule: "0 * * * *"\n  jobTemplate:\n    spec:\n      template:\n        spec:\n          containers:\n          - name: '+n+'\n            image: registry.example.com/'+n+':latest\n          restartPolicy: OnFailure\n';
  return cm+'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: '+n+'\n  annotations:\n    conversion.engine/captureMethod: '+_ace2.captureMethod+'\nspec:\n  replicas: 2\n  selector:\n    matchLabels:\n      app: '+n+'\n  template:\n    metadata:\n      labels:\n        app: '+n+'\n    spec:\n      containers:\n      - name: '+n+'\n        image: registry.example.com/'+n+':latest\n        ports:\n        - containerPort: '+(c.ports&&c.ports[0]||8080)+'\n---\napiVersion: v1\nkind: Service\nmetadata:\n  name: '+n+'\nspec:\n  selector:\n    app: '+n+'\n  ports:\n  - port: 80\n    targetPort: '+(c.ports&&c.ports[0]||8080)+'\n';
};

window.ace2GenYAML = function() {
  _ace2.yaml=_ace2.components.map(ace2GenYAMLFor).join('\n---\n');
  var el=document.getElementById('ace2-yaml-preview'); if(el) el.textContent=_ace2.yaml||'-- No components --';
  _ace2.artifacts.yaml=true;
};

window.ace2GenHelm = function() {
  var n=(_ace2.bs&&_ace2.bs.name||'app').toLowerCase().replace(/\s+/g,'-');
  _ace2.helm='# Chart.yaml\napiVersion: v2\nname: '+n+'\nversion: 1.0.0\nannotations:\n  captureMethod: '+_ace2.captureMethod+'\n\n# values.yaml\nreplicaCount: 2\nimage:\n  repository: registry.example.com/'+n+'\n  tag: latest\n';
  var el=document.getElementById('ace2-gitops-preview'); if(el) el.textContent=_ace2.helm;
  _ace2.artifacts.helm=true;
};

window.ace2GenKustomize = function() {
  _ace2.kustomize='# kustomization.yaml\napiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- namespace.yaml\n- deployment.yaml\n- service.yaml\n- configmap.yaml\n- ingress.yaml\noverlays: dev/ uat/ prod/\n';
  var el=document.getElementById('ace2-gitops-preview'); if(el) el.textContent=_ace2.kustomize;
  _ace2.artifacts.kustomize=true;
};

window.ace2GenFlux = function() {
  var n=(_ace2.bs&&_ace2.bs.name||'app').toLowerCase().replace(/\s+/g,'-');
  _ace2.flux='apiVersion: kustomize.toolkit.fluxcd.io/v1\nkind: Kustomization\nmetadata:\n  name: '+n+'\n  namespace: flux-system\nspec:\n  interval: 5m\n  path: "./applications/overlays/'+n+'"\n  prune: true\n  sourceRef:\n    kind: GitRepository\n    name: opencenter-gitops\n';
  var el=document.getElementById('ace2-gitops-preview'); if(el) el.textContent=_ace2.flux;
  _ace2.artifacts.flux=true;
};

window.ace2GenBundle = function() {
  if(!_ace2.components.length){ alert('Load FLEX components first.'); return; }
  ace2GenYAML(); ace2GenHelm(); ace2GenKustomize(); ace2GenFlux();
  var isC=_ace2.captureMethod==='compat';
  var warnings=[];
  _ace2.components.forEach(function(c){ var r=(c.type||c.role||'').toLowerCase(); if(r==='database') warnings.push(c.name+': ExternalDB'); if(!c.runtime) warnings.push(c.name+': Runtime inferred'); });
  if(isC) warnings.push('COMPATIBILITY CONTAINER — manual hardening required');
  _ace2.bundle={
    source:_ace2.source==='b'?'single_flex_vm':'flex_business_system',
    sourcePlatform:'flex', captureMethod:isC?'FULL_SNAPSHOT_COMPATIBILITY_CONTAINER':'SMART_SNAPSHOT_CAPTURE',
    customer:_ace2.bs&&_ace2.bs.customer||'', businessSystem:_ace2.bs&&_ace2.bs.name||'',
    cloudNativeStatus:isC?'COMPATIBILITY_CONTAINER_ONLY':'CLOUD_NATIVE_READY',
    conversionEngine:'apps_conversion_engine',
    workloads:_ace2.components.filter(function(c){return (c.type||c.role||'').toLowerCase()!=='database';}).map(function(c){return {name:c.name,kind:'Deployment'};}),
    externalServices:_ace2.components.filter(function(c){return (c.type||c.role||'').toLowerCase()==='database';}).map(function(c){return {name:c.name,type:'ExternalDB'};}),
    readiness:{status:warnings.length?'WARNING':'PASS', warnings:warnings}
  };
  var bp=document.getElementById('ace2-bundle-preview'); if(bp) bp.textContent=JSON.stringify(_ace2.bundle,null,2);
  var sb=document.getElementById('ace2-sum-bundle'); if(sb){sb.textContent='Generated ('+(warnings.length?'WARNING':'PASS')+')'; sb.style.color=warnings.length?'#d97706':'#16a34a';}
  Object.keys(_ace2.artifacts).forEach(function(k){_ace2.artifacts[k]=true;});
  localStorage.setItem('r6OpenCenterHandoffBundle', JSON.stringify(_ace2.bundle));
  ace2SetStepStatus(11,'ok'); ace2RenderPipeline();
};

window.ace2SendToOpenCenter = function() {
  ace2GenBundle();
  var st=document.getElementById('ace2-send-status');
  if(st) st.innerHTML='<span style="color:#16a34a;font-weight:700;">[OK] Bundle sent. Method: '+(_ace2.captureMethod==='compat'?'Full Snapshot Compat':'Smart Snapshot')+'</span>';
  ace2SetStepStatus(12,'ok'); ace2RenderPipeline();
  setTimeout(function(){ if(typeof openCenterImportFromR6==='function') openCenterImportFromR6(); },300);
  var s=document.querySelector('[data-sub="s2opencenter"]');
  if(s) setTimeout(function(){ s.click(); },500);
};

/* ── Utility ── */
window.ace2RCmd = function(cmd, outId) {
  var out=document.getElementById(outId); if(!out) return;
  out.textContent='$ '+cmd+'\n';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);
  es.onmessage=function(e){ if(e.data!=='[DONE]'){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;}else es.close(); };
  es.onerror=function(){ out.textContent+='[closed]\n'; es.close(); };
};
window.ace2DownloadArtifact=function(fn){ var src=fn.includes('manifest')||fn.includes('.json')?(_ace2.bundle?JSON.stringify(_ace2.bundle,null,2):'{}'):(_ace2.yaml||'-- no content --'); var a=document.createElement('a'); a.href='data:text/plain;charset=utf-8,'+encodeURIComponent(src); a.download=fn; a.click(); };
window.ace2DownloadEvidence=function(){ ace2DownloadArtifact('opencenter_import_manifest.json'); };

/* ── Auto-init ── */
document.addEventListener('click', function(e) {
  if(e.target.closest('[data-sub="s2ace"]')) setTimeout(ace2Init, 300);
});
document.addEventListener('DOMContentLoaded', function() {
  setTimeout(function() {
    var orig=window.uatS1SaveSystem;
    if(typeof orig==='function') window.uatS1SaveSystem=function(d){ orig.call(this,d); setTimeout(ace2RefreshBSList,150); };
  }, 1000);
});
