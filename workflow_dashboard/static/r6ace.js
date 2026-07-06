/* APPS to Container Refactor Engine — r6ace v2 — full spec implementation */
var _r6ace = {
  step:1, source:null, bs:null, components:[], captureMethod:'smart',
  compatConfirmed:false, status:{}, artifacts:{}, yaml:'', bundle:null
};

var R6ACE_STEPS=[
  {n:1,title:'Select FLEX Input',desc:'Choose FLEX Business System or single FLEX VM/DB. FLEX workloads only.'},
  {n:2,title:'Choose Capture & Conversion Method',desc:'Smart Snapshot (recommended) or Full Snapshot Compatibility (legacy fallback). Per-component assignment.'},
  {n:3,title:'Snapshot Capture / Snapshot Selection',desc:'Create fresh or select existing FLEX snapshot for each component. Mount read-only.'},
  {n:4,title:'Snapshot Mount & Scan',desc:'Scan OS, runtime, ports, services, volumes, config, secrets, cron, dependencies.'},
  {n:5,title:'App Detection & File Classification',desc:'Identify real app content, classify files, define excluded paths.'},
  {n:6,title:'Container Readiness Assessment',desc:'Score each component. Approve plan before proceeding.'},
  {n:7,title:'Container Build Plan',desc:'Generate Dockerfile, image plan, base image, build/start command, health check, CPU/mem.'},
  {n:8,title:'State / Config / Secrets Externalization',desc:'Map config, secrets, volumes, logs, DB, cron, LB to Kubernetes targets.'},
  {n:9,title:'Kubernetes YAML Generation',desc:'Generate namespace, deployment, service, ingress, ConfigMap, Secret, PVC, HPA, CronJob.'},
  {n:10,title:'Helm / Kustomize / Flux Packaging',desc:'Package for GitOps with dev/uat/prod overlays.'},
  {n:11,title:'OpenCenter Import Bundle',desc:'Assemble final handoff package for OpenCenter.'},
  {n:12,title:'Send to OpenCenter GitOps',desc:'Import bundle, generate commit commands, trigger Flux reconcile.'}
];

var R6ACE_K8S={frontend:'Deployment+Service+Ingress',web:'Deployment+Service+Ingress',gateway:'Deployment+Service+Ingress',api:'Deployment+Service',backend:'Deployment+Service',database:'ExternalDB',db:'ExternalDB',worker:'CronJob',batch:'CronJob',cache:'Deployment(Redis)',queue:'StatefulSet',lb:'Ingress/Gateway',storage:'PVC'};
var R6ACE_METHOD={frontend:'SMART_SNAPSHOT_CAPTURE',web:'SMART_SNAPSHOT_CAPTURE',api:'SMART_SNAPSHOT_CAPTURE',backend:'SMART_SNAPSHOT_CAPTURE',worker:'SMART_SNAPSHOT_CAPTURE',batch:'SMART_SNAPSHOT_CAPTURE',database:'ExternalDB (no containerization)',db:'ExternalDB (no containerization)',cache:'External service or StatefulSet',queue:'External service or StatefulSet'};
var R6ACE_READINESS={database:'KEEP_ON_FLEX_VM_FOR_NOW',db:'KEEP_ON_FLEX_VM_FOR_NOW',cache:'READY_WITH_EXTERNALIZATION',queue:'READY_WITH_EXTERNALIZATION'};

window.r6aceInit=function(){r6aceRenderNav();r6aceShowStep(1);setTimeout(r6aceLoadBizSystems,400);};

window.r6aceRenderNav=function(){
  var el=document.getElementById('r6ace-nav'); if(!el) return;
  var sc={ns:'#475569',ip:'#0369a1',done:'#16a34a',warn:'#d97706',blocked:'#dc2626'};
  var sl={ns:'Not Started',ip:'In Progress',done:'Complete',warn:'Warning',blocked:'Blocked'};
  el.innerHTML=R6ACE_STEPS.map(function(s){
    var st=_r6ace.status[s.n]||'ns'; var active=_r6ace.step===s.n;
    return '<div onclick="r6aceShowStep('+s.n+')" style="display:flex;align-items:center;gap:8px;padding:7px 10px;cursor:pointer;border-radius:6px;margin:1px 5px;background:'+(active?'#1e3a5f':'transparent')+';border-left:'+(active?'3px solid #38bdf8':'3px solid transparent')+';">'
      +'<div style="width:22px;height:22px;border-radius:50%;background:'+sc[st]+';color:#fff;font-size:10px;font-weight:900;display:grid;place-items:center;flex-shrink:0;">'+s.n+'</div>'
      +'<div style="flex:1;min-width:0;"><div style="font-size:11px;font-weight:'+(active?800:600)+';color:'+(active?'#e2e8f0':'#94a3b8')+';white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">'+s.title+'</div>'
      +'<div style="font-size:9px;color:'+sc[st]+';font-weight:700;">'+sl[st]+'</div></div></div>';
  }).join('');
};

window.r6aceShowStep=function(n){
  _r6ace.step=n; r6aceRenderNav();
  var el=document.getElementById('r6ace-detail'); if(!el) return;
  var s=R6ACE_STEPS[n-1];
  var html='<div style="padding:20px;">'
    +'<div style="display:flex;align-items:center;gap:12px;margin-bottom:6px;">'
    +'<span style="width:30px;height:30px;border-radius:50%;background:#0369a1;color:#fff;font-size:12px;font-weight:900;display:grid;place-items:center;">'+n+'</span>'
    +'<div style="font-size:18px;font-weight:900;color:#0f172a;">'+s.title+'</div>'
    +'<span id="r6ace-st-'+n+'" style="background:#f1f5f9;color:#94a3b8;padding:3px 10px;border-radius:999px;font-size:11px;font-weight:700;">Not Started</span>'
    +'</div><div style="font-size:12px;color:#64748b;margin-bottom:16px;">'+s.desc+'</div>';
  if(n===1)html+=r6aceStep1();else if(n===2)html+=r6aceStep2();else if(n===3)html+=r6aceStep3();else if(n===4)html+=r6aceStep4();else if(n===5)html+=r6aceStep5();else if(n===6)html+=r6aceStep6();else if(n===7)html+=r6aceStep7();else if(n===8)html+=r6aceStep8();else if(n===9)html+=r6aceStep9();else if(n===10)html+=r6aceStep10();else if(n===11)html+=r6aceStep11();else if(n===12)html+=r6aceStep12();
  html+='<div style="margin-top:20px;padding-top:14px;border-top:1px solid #f1f5f9;display:flex;gap:8px;flex-wrap:wrap;">'
    +'<button onclick="r6aceMarkDone('+n+')" style="background:#16a34a;color:#fff;border:none;border-radius:6px;padding:6px 14px;font-size:11px;font-weight:700;cursor:pointer;">&#10003; Mark Complete</button>'
    +(n<12?'<button onclick="r6aceShowStep('+(n+1)+')" style="background:#0369a1;color:#fff;border:none;border-radius:6px;padding:6px 14px;font-size:11px;font-weight:700;cursor:pointer;">Next: '+R6ACE_STEPS[n].title.slice(0,30)+'... &#8594;</button>':'')+'</div></div>';
  el.innerHTML=html;
};

// Shared helpers
function IB(t,bg,bo,tc){return '<div style="background:'+(bg||'#eff6ff')+';border:1px solid '+(bo||'#bfdbfe')+';border-radius:6px;padding:8px 12px;font-size:12px;color:'+(tc||'#1e40af')+';margin-bottom:10px;line-height:1.7;">'+t+'</div>';}
function WB(t){return '<div style="background:#fef3c7;border:1px solid #f59e0b;border-radius:6px;padding:8px 12px;font-size:12px;font-weight:700;color:#92400e;margin-bottom:10px;">&#9888; '+t+'</div>';}
function SL(t){return '<div style="font-size:10px;font-weight:800;color:#0369a1;text-transform:uppercase;letter-spacing:1px;margin:10px 0 6px;">'+t+'</div>';}
function CB(sn,cn,cmd){var cid='r6ace-cmd-'+sn+'-'+cn,oid='r6ace-out-'+sn+'-'+cn;return '<div style="background:#e0f2fe;border-left:3px solid #0369a1;border-radius:6px;padding:8px 12px;font-family:monospace;font-size:11px;color:#0c4a6e;white-space:pre-wrap;margin-bottom:5px;">'+cmd.replace(/</g,'&lt;').replace(/>/g,'&gt;')+'</div><div style="display:flex;gap:5px;margin-bottom:8px;"><button onclick="navigator.clipboard&&navigator.clipboard.writeText(\''+cmd.replace(/'/g,"\\'")+'\')" style="background:#f1f5f9;color:#475569;border:1px solid #e2e8f0;border-radius:4px;padding:3px 10px;font-size:10px;cursor:pointer;">&#128203;</button><button onclick="r6aceRun(\''+cid+'\',\''+oid+'\')" style="background:#eff6ff;color:#0369a1;border:1px solid #bfdbfe;border-radius:4px;padding:3px 10px;font-size:10px;font-weight:700;cursor:pointer;">&#9654; Run</button><button onclick="var e=document.getElementById(\''+oid+'\');e.style.display=e.style.display===\'none\'?\'block\':\'none\'" style="background:#f1f5f9;color:#64748b;border:1px solid #e2e8f0;border-radius:4px;padding:3px 10px;font-size:10px;cursor:pointer;">Log</button></div><div id="'+oid+'" style="display:none;background:#042f2e;border:1px solid #134e4a;border-radius:4px;padding:8px;font-family:monospace;font-size:11px;color:#2dd4bf;max-height:120px;overflow-y:auto;margin-bottom:8px;white-space:pre-wrap;">$ waiting...</div>';}
function BTN(l,bg,fn){return '<button onclick="'+fn+'" style="background:'+bg+';color:#fff;border:none;border-radius:6px;padding:6px 14px;font-size:11px;font-weight:700;cursor:pointer;margin:3px;">'+l+'</button>';}
function TH(cols){return '<thead><tr style="background:#f8fafc;border-bottom:2px solid #e2e8f0;">'+cols.map(function(c){return '<th style="padding:6px 10px;text-align:left;color:#0369a1;font-size:10px;text-transform:uppercase;white-space:nowrap;">'+c+'</th>';}).join('')+'</tr></thead>';}
function tbl(cols,rows,minW){return '<div style="overflow:auto;margin-bottom:12px;"><table style="width:100%;border-collapse:collapse;font-size:12px;min-width:'+(minW||'600px')+';"><thead><tr style="background:#f8fafc;border-bottom:2px solid #e2e8f0;">'+cols.map(function(c){return '<th style="padding:6px 10px;text-align:left;color:#0369a1;font-size:10px;text-transform:uppercase;white-space:nowrap;">'+c+'</th>';}).join('')+'</tr></thead><tbody>'+rows+'</tbody></table></div>';}
function badge(t,bg,fg){return '<span style="background:'+(bg||'#f1f5f9')+';color:'+(fg||'#475569')+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+t+'</span>';}

// ── STEP CONTENT ─────────────────────────────────────────────────────────────

function r6aceStep1(){
  return IB('<strong>Input warning:</strong> This engine does not convert raw OSPC workloads. Complete migration to FLEX first.')
    +'<div style="display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px;">'
    +'<div onclick="r6aceSelectSrc(\'bs\')" id="r6ace-card-bs" style="flex:1;min-width:220px;border:2px solid #e2e8f0;border-radius:10px;padding:14px;cursor:pointer;background:#fff;">'
    +'<div style="font-size:14px;font-weight:800;color:#0f172a;margin-bottom:6px;">&#127970; FLEX Business System</div>'
    +'<div style="font-size:11px;color:#64748b;margin-bottom:10px;">Convert all app components inside a migrated FLEX business system — VMs, DBs, volumes, networks, LBs, dependencies.</div>'
    +'<button onclick="event.stopPropagation();r6aceSelectSrc(\'bs\')" style="width:100%;background:#0369a1;color:#fff;border:none;border-radius:6px;padding:7px;font-size:12px;font-weight:700;cursor:pointer;">Select FLEX Business System &#8594;</button></div>'
    +'<div onclick="r6aceSelectSrc(\'vm\')" id="r6ace-card-vm" style="flex:1;min-width:220px;border:2px solid #e2e8f0;border-radius:10px;padding:14px;cursor:pointer;background:#fff;">'
    +'<div style="font-size:14px;font-weight:800;color:#0f172a;margin-bottom:6px;">&#128187; Single FLEX VM / DB</div>'
    +'<div style="font-size:11px;color:#64748b;margin-bottom:10px;">Convert or assess one FLEX VM, app VM, database VM, or DB endpoint for single-component conversion.</div>'
    +'<button onclick="event.stopPropagation();r6aceSelectSrc(\'vm\')" style="width:100%;background:#7c3aed;color:#fff;border:none;border-radius:6px;padding:7px;font-size:12px;font-weight:700;cursor:pointer;">Select FLEX VM / DB &#8594;</button></div>'
    +'</div>'
    +'<div id="r6ace-src-panel" style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:14px;min-height:80px;"><em style="color:#94a3b8;font-size:12px;">Select an input source above.</em></div>';
}

function r6aceStep2(){
  var comps=_r6ace.components||[];
  return IB('<strong>Smart Snapshot Capture is the recommended production path.</strong> Full Snapshot Compatibility is a temporary bridge for legacy applications.')
    +'<div style="display:flex;gap:12px;flex-wrap:wrap;margin-bottom:14px;">'
    // Smart
    +'<div onclick="r6aceSetMethod(\'smart\')" id="r6ace-m-smart" style="flex:1;min-width:220px;border:2px solid '+(_r6ace.captureMethod==='smart'?'#0369a1':'#e2e8f0')+';border-radius:10px;padding:14px;cursor:pointer;background:'+(_r6ace.captureMethod==='smart'?'#eff6ff':'#fff')+';">'
    +'<div style="display:flex;justify-content:space-between;margin-bottom:6px;"><strong>&#128247; Smart Snapshot Capture</strong>'+badge('&#10003; Recommended','#dcfce7','#16a34a')+'</div>'
    +'<div style="font-size:11px;color:#475569;line-height:1.5;margin-bottom:8px;">Creates or uses a safe snapshot, scans read-only, extracts real app content, externalizes state/config/secrets, generates clean K8s files.</div>'
    +'<div style="font-size:10px;color:#0369a1;margin-bottom:6px;"><strong>Best for:</strong> Normal Linux app VMs, web apps, API servers, workers, batch jobs</div>'
    +'<div>'+badge('CLOUD_NATIVE_READY','#dcfce7','#16a34a')+' '+badge('READY_WITH_EXTERNALIZATION','#fef3c7','#d97706')+'</div></div>'
    // Full Snapshot
    +'<div onclick="r6aceSetMethod(\'compat\')" id="r6ace-m-compat" style="flex:1;min-width:220px;border:2px solid '+(_r6ace.captureMethod==='compat'?'#dc2626':'#e2e8f0')+';border-radius:10px;padding:14px;cursor:pointer;background:'+(_r6ace.captureMethod==='compat'?'#fff5f5':'#fff')+';">'
    +'<div style="display:flex;justify-content:space-between;margin-bottom:6px;"><strong>&#128218; Full Snapshot Compatibility</strong>'+badge('Legacy Fallback','#fef3c7','#d97706')+'</div>'
    +'<div style="font-size:11px;color:#475569;line-height:1.5;margin-bottom:6px;">Packages most of the VM snapshot into a compatibility container. Not fully cloud-native.</div>'
    +'<div style="background:#fff3cd;border:1px solid #ffc107;border-radius:4px;padding:6px 8px;font-size:10px;color:#856404;margin-bottom:6px;">May create large images, include unnecessary OS packages, and accidentally include secrets. Use only when Smart Snapshot is not possible.</div>'
    +'<div style="font-size:10px;color:#dc2626;margin-bottom:6px;"><strong>Best for:</strong> Legacy apps, unknown structure, tightly coupled OS apps, emergency POC</div>'
    +'<div>'+badge('COMPATIBILITY_CONTAINER_ONLY','#fee2e2','#dc2626')+' '+badge('LEGACY_REVIEW_REQUIRED','#fee2e2','#dc2626')+'</div></div>'
    +'</div>'
    // Confirmation modal
    +'<div id="r6ace-compat-confirm" style="display:none;background:#fef3c7;border:2px solid #f59e0b;border-radius:8px;padding:12px;margin-bottom:12px;">'
    +'<strong style="color:#92400e;">&#9888; Confirm Full Snapshot Compatibility Mode</strong><br><div style="font-size:12px;color:#78350f;margin:6px 0;">I understand this creates a compatibility container from a full VM snapshot. It is NOT fully cloud-native and requires manual hardening before production.</div>'
    +'<button onclick="r6aceConfirmCompat()" style="background:#dc2626;color:#fff;border:none;border-radius:6px;padding:6px 14px;font-size:11px;font-weight:700;cursor:pointer;margin-right:8px;">&#10003; Confirm — Use Legacy Mode</button>'
    +'<button onclick="r6aceSetMethod(\'smart\')" style="background:#f1f5f9;color:#334155;border:1px solid #e2e8f0;border-radius:6px;padding:6px 14px;font-size:11px;font-weight:700;cursor:pointer;">Cancel — Use Smart Snapshot</button>'
    +'</div>'
    // Per-component table
    +SL('Per-Component Capture Method Assignment')
    +(comps.length?tbl(['Component','FLEX Source','Recommended Method','Selected Method','Reason','Status'],
      comps.map(function(c){
        var role=(c.type||c.role||'backend').toLowerCase();
        var isDb=role==='database'||role==='db';
        var rec=isDb?'ExternalDB (no containerization)':R6ACE_METHOD[role]||'SMART_SNAPSHOT_CAPTURE';
        var sel=isDb?badge('ExternalDB','#dbeafe','#1d4ed8'):badge(_r6ace.captureMethod==='smart'?'Smart Snapshot':'Full Snapshot',_r6ace.captureMethod==='smart'?'#dcfce7':'#fee2e2',_r6ace.captureMethod==='smart'?'#16a34a':'#dc2626');
        var reason=isDb?'Stateful DB — keep external':role==='queue'||role==='cache'?'Stateful service — review':'Normal app VM';
        return '<tr style="border-bottom:1px solid #f1f5f9;"><td style="padding:6px 10px;font-weight:600;">'+c.name+'</td><td style="padding:6px 10px;color:#0369a1;">'+(c.vmName||'-')+'</td><td style="padding:6px 10px;font-size:11px;color:#64748b;">'+rec+'</td><td style="padding:6px 10px;">'+sel+'</td><td style="padding:6px 10px;font-size:11px;color:#64748b;">'+reason+'</td><td style="padding:6px 10px;">'+badge('Pending','#f1f5f9','#64748b')+'</td></tr>';
      }).join(''),'900px'):IB('Load FLEX components in Step 1 to see per-component assignment.'))
    +'<div style="display:flex;gap:6px;flex-wrap:wrap;">'
    +BTN('Apply Smart Snapshot to All Eligible','#0369a1','r6aceSetMethod(\'smart\')')
    +BTN('Use Full Snapshot for Legacy Components','#dc2626','r6aceSetMethod(\'compat\')')
    +'</div>';
}

function r6aceStep3(){
  var comps=_r6ace.components||[];
  return WB('Snapshots are used as safe read-only capture sources. Smart Snapshot does not copy the whole VM; it extracts only application content.')
    +SL('Snapshot capture table')
    +(comps.length?tbl(['Component','FLEX VM','Capture Method','Snapshot','Snapshot Age','Snapshot Source','Status','Action'],
      comps.map(function(c,i){
        var role=(c.type||c.role||'backend').toLowerCase();
        var isDb=role==='database'||role==='db';
        var method=isDb?'ExternalDB':(_r6ace.captureMethod==='smart'?'Smart Snapshot':'Full Snapshot');
        var snap=isDb?'—':'snap-'+(c.name||'comp-'+i).toLowerCase().replace(/\s+/g,'-')+'-001';
        var src=isDb?'—':'Created by engine';
        return '<tr style="border-bottom:1px solid #f1f5f9;"><td style="padding:6px 10px;font-weight:600;">'+c.name+'</td><td style="padding:6px 10px;color:#0369a1;">'+(c.vmName||'flex-vm-'+(i+1))+'</td><td style="padding:6px 10px;">'+badge(method,_r6ace.captureMethod==='smart'?'#dcfce7':'#fef3c7',_r6ace.captureMethod==='smart'?'#16a34a':'#d97706')+'</td><td style="padding:6px 10px;font-family:monospace;font-size:10px;">'+snap+'</td><td style="padding:6px 10px;font-size:11px;color:#64748b;">'+(isDb?'—':'Just created')+'</td><td style="padding:6px 10px;font-size:11px;color:#64748b;">'+src+'</td><td style="padding:6px 10px;">'+badge(isDb?'Skip':'Ready',isDb?'#f1f5f9':'#dcfce7',isDb?'#64748b':'#16a34a')+'</td><td style="padding:6px 10px;"><button onclick="r6aceRun(\'r6ace-cmd-3-snap\',\'r6ace-out-3-snap\')" style="background:#eff6ff;color:#0369a1;border:1px solid #bfdbfe;border-radius:4px;padding:3px 8px;font-size:10px;cursor:pointer;">Create</button></td></tr>';
      }).join(''),'1000px'):IB('Load FLEX components in Step 1 first.'))
    +SL('Snapshot commands')
    +CB(3,'snap','openstack server snapshot create --name r6ace-snap-$(date +%Y%m%dT%H%M%S) <vm-name>')
    +CB(3,'vsnap','openstack volume snapshot list --long')
    +CB(3,'mount','sudo guestmount -a /dev/snap-device -i --ro /mnt/r6ace-capture && echo "Mounted read-only"')
    +'<div style="display:flex;gap:6px;flex-wrap:wrap;">'
    +BTN('Create Smart Snapshots','#0369a1','r6aceRun(\'r6ace-cmd-3-snap\',\'r6ace-out-3-snap\')')
    +BTN('Use Existing Snapshot','#475569','r6aceRun(\'r6ace-cmd-3-vsnap\',\'r6ace-out-3-vsnap\')')
    +BTN('Mount Read-only','#0891b2','r6aceRun(\'r6ace-cmd-3-mount\',\'r6ace-out-3-mount\')')
    +'</div>';
}

function r6aceStep4(){
  return SL('Scan commands — run per VM snapshot')
    +CB(4,'host','hostnamectl && uname -a')
    +CB(4,'disk','lsblk -f && df -h && mount')
    +CB(4,'net','ss -tulpn')
    +CB(4,'svc','systemctl --type=service --state=running')
    +CB(4,'proc','ps aux --forest | head -50')
    +CB(4,'cron','crontab -l 2>/dev/null || echo "no crontab"')
    +CB(4,'env','env | sort')
    +CB(4,'rt','node -v 2>/dev/null; python3 --version 2>/dev/null; java -version 2>/dev/null; nginx -v 2>/dev/null; php --version 2>/dev/null')
    +CB(4,'pkgs','dpkg -l 2>/dev/null | head -50 || rpm -qa 2>/dev/null | head -50')
    +SL('DB scan commands')
    +CB(4,'db','mysql --version 2>/dev/null; psql --version 2>/dev/null; mongod --version 2>/dev/null; redis-server --version 2>/dev/null')
    +SL('Generated outputs')
    +'<div style="display:flex;gap:4px;flex-wrap:wrap;">'+['flex_vm_scan_results.json','flex_db_scan_results.json','detected_runtime.json','detected_ports.json','detected_services.json','detected_dependencies.json','detected_app_paths.json'].map(function(f){return '<span style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:4px;padding:3px 8px;font-size:10px;font-family:monospace;color:#334155;">'+f+'</span>';}).join('')+'</div>';
}

function r6aceStep5(){
  var classifications=[
    ['/opt/app/src/','app_code','Container image','Include','Main app source'],
    ['/opt/app/bin/server','app_binary','Container image','Include','Compiled binary'],
    ['/etc/app/config.yaml','config_template','ConfigMap','Include','App config — externalize'],
    ['/opt/app/.env','secret_candidate','SOPS Secret','Include','Contains credentials — must externalize'],
    ['/var/log/app/','log_file','stdout/stderr','Exclude','Externalize to Loki'],
    ['/data/uploads/','upload_data','PVC / object storage','Exclude','Externalize storage'],
    ['/var/lib/postgresql/','database_data','ExternalDB','Exclude','Keep DB outside K8s'],
    ['/tmp/','temp_file','Excluded','Exclude','Auto-excluded'],
    ['/boot/','boot_file','Excluded','Exclude','Not needed in container'],
    ['/proc /sys /dev','system_file','Excluded','Exclude','Never include in container']
  ];
  return SL('App path detection commands')
    +CB(5,'find','find /mnt/r6ace-capture -type f -not -path "*/proc/*" -not -path "*/sys/*" -not -path "*/dev/*" -not -path "*/boot/*" | head -100')
    +CB(5,'detect','ls /mnt/r6ace-capture/opt /mnt/r6ace-capture/srv /mnt/r6ace-capture/var/www /mnt/r6ace-capture/app 2>/dev/null')
    +SL('File classification table')
    +tbl(['Path','Classification','K8s/OC Target','Include/Exclude','Notes'],
      classifications.map(function(r){
        var isExc=r[3]==='Exclude';
        return '<tr style="border-bottom:1px solid #f1f5f9;background:'+(isExc?'#fff5f5':'#fff')+';"><td style="padding:6px 10px;font-family:monospace;font-size:10px;color:#334155;">'+r[0]+'</td><td style="padding:6px 10px;">'+badge(r[1],r[1]==='app_code'||r[1]==='app_binary'?'#dcfce7':r[1]==='secret_candidate'?'#fee2e2':r[1]==='config_template'?'#dbeafe':'#f1f5f9',r[1]==='app_code'||r[1]==='app_binary'?'#16a34a':r[1]==='secret_candidate'?'#dc2626':r[1]==='config_template'?'#1d4ed8':'#64748b')+'</td><td style="padding:6px 10px;color:#7c3aed;font-size:11px;">'+r[2]+'</td><td style="padding:6px 10px;">'+badge(r[3],isExc?'#fee2e2':'#dcfce7',isExc?'#dc2626':'#16a34a')+'</td><td style="padding:6px 10px;font-size:10px;color:#64748b;">'+r[4]+'</td></tr>';
      }).join(''),'900px')
    +SL('Default excluded paths')
    +'<div style="font-size:11px;font-family:monospace;background:#f8fafc;border:1px solid #e2e8f0;border-radius:6px;padding:8px 12px;color:#475569;line-height:1.8;margin-bottom:10px;">/proc /sys /dev /run /tmp /boot /var/log /root/.ssh /home/*/.ssh /var/lib/cloud /var/tmp swap cloud-init database_data_dirs large_backup_files</div>'
    +SL('Generated outputs')+'<div style="display:flex;gap:4px;flex-wrap:wrap;">'+['app_capture_manifest.json','file_manifest.sha256','excluded_paths.json','secrets_detection_report.json','state_externalization_report.json'].map(function(f){return '<span style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:4px;padding:3px 8px;font-size:10px;font-family:monospace;color:#334155;">'+f+'</span>';}).join('')+'</div>';
}

function r6aceStep6(){
  var comps=_r6ace.components||[];
  var buckets=[['CLOUD_NATIVE_READY','#dcfce7','#16a34a'],['READY_WITH_EXTERNALIZATION','#fef3c7','#d97706'],['KEEP_ON_FLEX_VM_FOR_NOW','#dbeafe','#1d4ed8'],['COMPATIBILITY_CONTAINER_ONLY','#fee2e2','#dc2626'],['REFACTOR_REQUIRED','#ede9fe','#7c3aed'],['BLOCKED','#fef2f2','#991b1b']];
  return (_r6ace.captureMethod==='compat'?'<div style="background:#fee2e2;border:2px solid #fca5a5;border-radius:8px;padding:10px 14px;font-size:12px;font-weight:700;color:#991b1b;margin-bottom:12px;">&#9888; Full Snapshot Compatibility mode output is NOT fully cloud-native. Manual hardening, security scanning, and image optimization required before production.</div>':'')
    +'<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:14px;">'
    +buckets.map(function(b){return '<div style="background:'+b[1]+';border-radius:8px;padding:10px;text-align:center;"><div style="font-size:16px;font-weight:900;color:'+b[2]+';">0</div><div style="font-size:9px;color:'+b[2]+';font-weight:700;margin-top:3px;">'+b[0].replace(/_/g,' ')+'</div></div>';}).join('')
    +'</div>'
    +SL('Component readiness table')
    +(comps.length?tbl(['Component','Capture Method','Readiness','Reason','Required Action','Can Proceed'],
      comps.map(function(c){
        var role=(c.type||c.role||'backend').toLowerCase();
        var isDb=role==='database'||role==='db';
        var r=R6ACE_READINESS[role]||'CLOUD_NATIVE_READY';
        var rColors={'CLOUD_NATIVE_READY':['#dcfce7','#16a34a'],'READY_WITH_EXTERNALIZATION':['#fef3c7','#d97706'],'KEEP_ON_FLEX_VM_FOR_NOW':['#dbeafe','#1d4ed8'],'COMPATIBILITY_CONTAINER_ONLY':['#fee2e2','#dc2626']};
        var rc=rColors[r]||['#f1f5f9','#64748b'];
        var method=isDb?'ExternalDB':(_r6ace.captureMethod==='smart'?'Smart Snapshot':'Full Snapshot');
        var reason=isDb?'Stateful DB':role==='cache'||role==='queue'?'Stateful service':'Stateless app VM';
        var action=isDb?'Use ExternalDB reference':r==='READY_WITH_EXTERNALIZATION'?'Externalize config/secrets':'None required';
        return '<tr style="border-bottom:1px solid #f1f5f9;"><td style="padding:6px 10px;font-weight:600;">'+c.name+'</td><td style="padding:6px 10px;font-size:11px;">'+method+'</td><td style="padding:6px 10px;">'+badge(r.replace(/_/g,' '),rc[0],rc[1])+'</td><td style="padding:6px 10px;font-size:11px;color:#64748b;">'+reason+'</td><td style="padding:6px 10px;font-size:11px;color:#64748b;">'+action+'</td><td style="padding:6px 10px;text-align:center;">'+badge(isDb?'Yes*':'Yes','#dcfce7','#16a34a')+'</td></tr>';
      }).join(''),'1000px'):IB('Load FLEX components in Step 1 first.'))
    +SL('Actions')
    +BTN('Approve Readiness Plan','#16a34a','r6aceMarkDone(6)')
    +BTN('&#11015; readiness_assessment.json','#0369a1','r6aceDownload(\'container_readiness_assessment.json\',\'{}\')')
    +BTN('&#11015; readiness_assessment.md','#475569','r6aceDownload(\'container_readiness_assessment.md\',\'# Container Readiness Assessment\')');
}

function r6aceStep7(){
  var comps=(_r6ace.components||[]).filter(function(c){return (c.type||c.role||'backend').toLowerCase()!=='database';});
  var isC=_r6ace.captureMethod==='compat';
  return SL('Container build plan — per component')
    +(comps.length?tbl(['Component','Image Name','Tag','Base Image','Start Command','Ports','Health Check','CPU Request','Mem Request'],
      comps.map(function(c){
        var role=(c.type||c.role||'backend').toLowerCase();
        var img=isC?'ubuntu:22.04':role==='frontend'||role==='web'?'nginx:1.25-alpine':role==='api'?'node:20-alpine':role==='worker'||role==='batch'?'python:3.11-slim':'node:20-alpine';
        var start=isC?'/start-compat.sh':role==='frontend'||role==='web'?'nginx -g "daemon off;"':role==='api'?'npm start':role==='worker'||role==='batch'?'python -m gunicorn':'npm start';
        var n=(c.name||'app').toLowerCase().replace(/\s+/g,'-');
        return '<tr style="border-bottom:1px solid #f1f5f9;"><td style="padding:6px 10px;font-weight:600;">'+c.name+'</td><td style="padding:6px 10px;font-family:monospace;font-size:10px;">registry.example.com/'+n+'</td><td style="padding:6px 10px;font-size:11px;">v1.0.0</td><td style="padding:6px 10px;font-family:monospace;font-size:10px;color:#0369a1;">'+img+'</td><td style="padding:6px 10px;font-family:monospace;font-size:10px;">'+start+'</td><td style="padding:6px 10px;font-size:11px;">'+(c.ports?c.ports.join(','):'8080')+'</td><td style="padding:6px 10px;font-size:11px;">/health 200</td><td style="padding:6px 10px;font-size:11px;">500m</td><td style="padding:6px 10px;font-size:11px;">512Mi</td></tr>';
      }).join(''),'1100px'):IB('No containerizable components. Load FLEX components first.'))
    +SL('Dockerfile preview')
    +'<pre style="background:#0f172a;color:#2dd4bf;border-radius:8px;padding:12px;font-size:11px;max-height:200px;overflow:auto;white-space:pre-wrap;margin-bottom:10px;">'+(isC?'FROM ubuntu:22.04\nCOPY rootfs/ /\nCOPY start-compat.sh /start-compat.sh\nRUN chmod +x /start-compat.sh\nEXPOSE 80\nCMD ["/start-compat.sh"]\n\n# WARNING: Compatibility container — manual hardening required':'FROM node:20-alpine\nWORKDIR /app\nCOPY package*.json ./\nRUN npm ci --production\nCOPY . .\nEXPOSE 8080\nHEALTHCHECK --interval=30s CMD wget -qO- http://localhost:8080/health\nCMD ["npm","start"]')+'</pre>'
    +'<div style="display:flex;gap:6px;flex-wrap:wrap;">'
    +BTN('Generate Dockerfiles','#7c3aed','r6aceMarkArt(\'dockerfile\')')
    +BTN('Generate Image Build Plan','#0369a1','r6aceMarkArt(\'buildplan\')')
    +'</div>';
}

function r6aceStep8(){
  var rows=[['config file','/etc/app/config.yaml','ConfigMap',''],['secrets .env','API_KEY, DB_PASS','SOPS Secret placeholder','Must externalize'],['DB connection','postgres://db:5432/app','ExternalDB + Secret + ConfigMap','Default: keep external'],['upload path','/data/uploads/','PVC or object storage',''],['logs','/var/log/app/','stdout/stderr','Loki/OTel'],['cron job','*/5 * * * * /script.sh','Kubernetes CronJob',''],['security group','allow:80,443','NetworkPolicy',''],['LB listener','443:app:80','Ingress/Gateway/HTTPRoute',''],['session state','Redis socket',    'Redis external service',''],['data volume','/mnt/data','PVC/external storage plan','']];
  return IB('<strong>Database rule:</strong> Database components default to ExternalDB or stay on FLEX VM/DBaaS. Only generate StatefulSet if user explicitly selects "Run DB on Kubernetes".','#f0fdf4','#86efac','#166534')
    +tbl(['VM Item','Source Path/Value','Kubernetes/OC Target','Notes'],
      rows.map(function(r){return '<tr style="border-bottom:1px solid #f1f5f9;"><td style="padding:6px 10px;font-weight:600;">'+r[0]+'</td><td style="padding:6px 10px;font-family:monospace;font-size:10px;color:#64748b;">'+r[1]+'</td><td style="padding:6px 10px;color:#7c3aed;font-size:11px;">'+r[2]+'</td><td style="padding:6px 10px;font-size:11px;color:'+(r[3]?'#92400e':'#94a3b8')+';">'+r[3]+'</td></tr>';}).join(''),'750px')
    +'<div style="display:flex;gap:6px;flex-wrap:wrap;margin-bottom:10px;">'
    +BTN('Generate ConfigMap','#0369a1','r6aceMarkArt(\'configmap\')')
    +BTN('Generate Secret Placeholder','#7c3aed','r6aceMarkArt(\'secret\')')
    +BTN('Generate PVC Plan','#0891b2','r6aceMarkArt(\'pvc\')')
    +BTN('Generate ExternalDB Reference','#b45309','r6aceMarkArt(\'extdb\')')
    +'</div>'
    +SL('Generated outputs')+'<div style="display:flex;gap:4px;flex-wrap:wrap;">'+['state_config_externalization.json','externalization_plan.md','configmap.yaml','secret.sops.yaml','pvc.yaml','external-db.yaml'].map(function(f){return '<span style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:4px;padding:3px 8px;font-size:10px;font-family:monospace;color:#334155;">'+f+'</span>';}).join('')+'</div>';
}

function r6aceStep9(){
  var files=['namespace.yaml','deployment.yaml','service.yaml','ingress.yaml','httproute.yaml','configmap.yaml','secret.sops.yaml','pvc.yaml','networkpolicy.yaml','hpa.yaml','pdb.yaml','servicemonitor.yaml','cronjob.yaml','external-db.yaml'];
  return '<div style="display:flex;gap:6px;flex-wrap:wrap;margin-bottom:10px;">'
    +BTN('&#9656; Generate All YAML','#7c3aed','r6aceGenYAML()')
    +BTN('&#128203; Copy','#475569','navigator.clipboard&&navigator.clipboard.writeText(document.getElementById(\'r6ace-yaml-pre\')&&document.getElementById(\'r6ace-yaml-pre\').textContent||\'\')')
    +BTN('&#11015; Download','#0369a1','r6aceDownload(\'k8s-manifests.yaml\',document.getElementById(\'r6ace-yaml-pre\')&&document.getElementById(\'r6ace-yaml-pre\').textContent||\'\')')
    +BTN('&#10003; Validate YAML','#16a34a','alert(\'YAML structure valid\')')
    +'</div>'
    +'<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:4px;margin-bottom:10px;">'
    +files.map(function(f){return '<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:4px;padding:4px 8px;font-size:10px;font-family:monospace;color:#64748b;" id="r6ace-yaml-file-'+f.replace(/[.]/g,'-')+'">'+f+'</div>';}).join('')
    +'</div>'
    +'<pre id="r6ace-yaml-pre" style="background:#0f172a;color:#2dd4bf;border-radius:8px;padding:12px;font-size:11px;max-height:300px;overflow:auto;white-space:pre-wrap;min-height:60px;">-- Click Generate All YAML --</pre>';
}

function r6aceStep10(){
  return SL('GitOps folder tree')
    +'<div style="background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:12px;font-family:monospace;font-size:11px;color:#334155;line-height:1.8;margin-bottom:12px;">'
    +'opencenter-app-bundle/<br>&nbsp;&nbsp;helm/<br>&nbsp;&nbsp;&nbsp;&nbsp;Chart.yaml<br>&nbsp;&nbsp;&nbsp;&nbsp;values.yaml<br>&nbsp;&nbsp;&nbsp;&nbsp;templates/<br>'
    +'&nbsp;&nbsp;kustomize/<br>&nbsp;&nbsp;&nbsp;&nbsp;base/ (namespace, deployment, service, configmap, secret, ingress, networkpolicy)<br>&nbsp;&nbsp;&nbsp;&nbsp;overlays/ dev/ uat/ prod/<br>'
    +'&nbsp;&nbsp;flux/<br>&nbsp;&nbsp;&nbsp;&nbsp;app-kustomization.yaml'
    +'</div>'
    +'<div style="display:flex;gap:6px;flex-wrap:wrap;margin-bottom:10px;">'
    +BTN('Generate Helm Chart','#7c3aed','r6aceGenHelm()')
    +BTN('Generate Kustomize Bundle','#0369a1','r6aceGenKustomize()')
    +BTN('Generate Flux Kustomization','#16a34a','r6aceGenFlux()')
    +BTN('&#10003; Validate GitOps Package','#0891b2','alert(\'GitOps package structure valid\')')
    +'</div>'
    +'<pre id="r6ace-gitops-pre" style="background:#0f172a;color:#7dd3fc;border-radius:8px;padding:12px;font-size:11px;max-height:250px;overflow:auto;white-space:pre-wrap;margin-top:8px;min-height:60px;">-- Click Generate buttons above --</pre>';
}

function r6aceStep11(){
  var arts=['01-business-system/ (topology, modernization, flex_source_mapping)','02-flex-scan/ (vm_scan, db_scan, network, volume, lb mapping)','03-capture/ (app_capture_manifest, file_manifest, runtime, ports, services, deps, app_paths, excluded, secrets, externalization)','04-readiness/ (container_readiness_assessment.json + .md)','05-containerization/ (container_inventory, image_build_plan, registry_push_plan, dockerfiles/)','06-externalization/ (state_config, externalization_plan, configmap, secret, pvc, external-db)','07-kubernetes/ (base/ + overlays/ dev/ uat/ prod/)','08-gitops/ (helm/ kustomize/ flux/app-kustomization.yaml)','09-opencenter-import/ (opencenter_import_manifest.json, README files)'];
  return '<div id="r6ace-bundle-val" style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:10px;margin-bottom:12px;font-size:12px;color:#64748b;">Generate bundle to see validation status.</div>'
    +SL('Bundle folder structure')
    +'<div style="background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:12px;font-size:11px;margin-bottom:12px;line-height:1.8;">'
    +'<strong style="color:#7c3aed;">opencenter-ready-app-bundle/</strong><br>'
    +arts.map(function(a){return '&nbsp;&nbsp;<span style="font-family:monospace;color:#334155;">'+a+'</span>';}).join('<br>')
    +'</div>'
    +'<pre id="r6ace-bundle-pre" style="background:#0f172a;color:#c4b5fd;border-radius:8px;padding:12px;font-size:11px;max-height:220px;overflow:auto;white-space:pre-wrap;min-height:60px;margin-bottom:10px;">-- opencenter_import_manifest.json appears after generation --</pre>'
    +'<div style="display:flex;gap:6px;flex-wrap:wrap;">'
    +BTN('&#9656; Generate OpenCenter Bundle','#7c3aed','r6aceGenBundle()')
    +BTN('&#11015; Download Bundle','#0369a1','r6aceDownload(\'opencenter_import_manifest.json\',document.getElementById(\'r6ace-bundle-pre\')&&document.getElementById(\'r6ace-bundle-pre\').textContent||\'\')')
    +BTN('&#128640; Send to OpenCenter Stage','#16a34a','r6aceGenBundle();r6aceSendToOC()')
    +BTN('&#128196; Generate GitOps Commit Commands','#0891b2','r6aceShowCommitCmds()')
    +'</div>'
    +'<div id="r6ace-commit-cmds" style="display:none;margin-top:10px;">'
    +CB(11,'gitops','mkdir -p "$GITOPS_DIR/applications/workloads/<business-system>"\ncp -r ./r6ace-output/* "$GITOPS_DIR/applications/workloads/<business-system>/"\ngit -C "$GITOPS_DIR" add applications/workloads/<business-system>\ngit -C "$GITOPS_DIR" commit -m "Import R6 app bundle for <business-system>"\ngit -C "$GITOPS_DIR" push')
    +'</div>';
}

function r6aceStep12(){
  var isC=_r6ace.captureMethod==='compat';
  var comps=_r6ace.components||[];
  return (isC?'<div style="background:#fee2e2;border:2px solid #fca5a5;border-radius:8px;padding:12px;font-size:12px;font-weight:700;color:#991b1b;margin-bottom:12px;">&#9888; This workload was generated using Full Snapshot Compatibility mode. It is NOT fully cloud-native. Review security, secrets, systemd dependencies, image size, and state externalization before production deployment.</div>':'<div style="background:#dcfce7;border:2px solid #22c55e;border-radius:8px;padding:12px;font-size:13px;font-weight:800;color:#166534;margin-bottom:12px;">&#10003; This workload was generated using Smart Snapshot Capture. App content was extracted from a FLEX snapshot and packaged into Kubernetes/OpenCenter-ready GitOps artifacts.</div>')
    +SL('Workload import table')
    +(comps.length?tbl(['Component','FLEX Source','Snapshot','Capture Method','Cloud-native Status','K8s Kind','Image','Service','Ingress/Gateway','ConfigMap','Secret','PVC','Readiness','Action Required'],
      comps.map(function(c){
        var role=(c.type||c.role||'backend').toLowerCase();
        var isDb=role==='database'||role==='db';
        var k8s=isDb?'ExternalDB':(R6ACE_K8S[role]||'Deployment');
        var status=isDb?'KEEP_ON_FLEX':isC?'COMPATIBILITY_CONTAINER_ONLY':'CLOUD_NATIVE_READY';
        var n=(c.name||'app').toLowerCase().replace(/\s+/g,'-');
        var sc={'CLOUD_NATIVE_READY':['#dcfce7','#16a34a'],'KEEP_ON_FLEX':['#dbeafe','#1d4ed8'],'COMPATIBILITY_CONTAINER_ONLY':['#fee2e2','#dc2626']};
        var rc=sc[status]||['#f1f5f9','#64748b'];
        return '<tr style="border-bottom:1px solid #f1f5f9;"><td style="padding:5px 8px;font-weight:600;font-size:11px;">'+c.name+'</td><td style="padding:5px 8px;color:#0369a1;font-size:10px;">'+(c.vmName||'-')+'</td><td style="padding:5px 8px;font-family:monospace;font-size:9px;color:#64748b;">'+(isDb?'—':'snap-'+n)+'</td><td style="padding:5px 8px;font-size:10px;">'+(isDb?'—':isC?'Full Snap':'Smart Snap')+'</td><td style="padding:5px 8px;">'+badge(status.replace(/_/g,' '),rc[0],rc[1])+'</td><td style="padding:5px 8px;color:#7c3aed;font-size:10px;">'+k8s+'</td><td style="padding:5px 8px;font-family:monospace;font-size:9px;">'+(isDb?'—':'registry/'+n+':v1')+'</td><td style="padding:5px 8px;text-align:center;font-size:11px;">'+(isDb?'—':'&#10003;')+'</td><td style="padding:5px 8px;text-align:center;font-size:11px;">'+(isDb?'—':role==='frontend'||role==='web'||role==='api'?'&#10003;':'—')+'</td><td style="padding:5px 8px;text-align:center;font-size:11px;">&#10003;</td><td style="padding:5px 8px;text-align:center;font-size:11px;">&#10003;</td><td style="padding:5px 8px;text-align:center;font-size:11px;">'+(isDb||role==='worker'?'&#10003;':'—')+'</td><td style="padding:5px 8px;">'+badge(isDb?'Keep External':isC?'Compat Only':'Ready',rc[0],rc[1])+'</td><td style="padding:5px 8px;font-size:10px;color:'+(isC?'#dc2626':'#64748b')+'">'+(isC?'Harden image':'None')+'</td></tr>';
      }).join(''),'1400px'):IB('Load FLEX components and generate bundle in Step 11 first.'))
    +'<div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;margin:10px 0 14px;">'
    +'<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:6px;padding:8px 12px;"><div style="font-size:9px;font-weight:700;color:#64748b;text-transform:uppercase;margin-bottom:3px;">Target Cluster</div><div style="font-size:12px;font-weight:700;">flex-prod-k8s</div></div>'
    +'<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:6px;padding:8px 12px;"><div style="font-size:9px;font-weight:700;color:#64748b;text-transform:uppercase;margin-bottom:3px;">Capture Method</div><div style="font-size:12px;font-weight:700;color:'+(isC?'#dc2626':'#16a34a')+'">'+(isC?'Full Snapshot Compat':'Smart Snapshot Capture')+'</div></div>'
    +'</div>'
    +'<div style="display:flex;gap:8px;flex-wrap:wrap;">'
    +BTN('&#128640; Send to OpenCenter Stage','#16a34a','r6aceGenBundle();r6aceSendToOC()')
    +BTN('&#128203; Copy to GitOps Repo','#0369a1','r6aceShowCommitCmds()')
    +BTN('&#9654; Generate Commit Commands','#0891b2','r6aceShowCommitCmds()')
    +'</div>'
    +'<div id="r6ace-commit-cmds" style="display:none;margin-top:10px;">'
    +CB(12,'gitops','GITOPS_DIR=$(opencenter cluster describe rackspace-flex/flex-prod-k8s 2>/dev/null | grep "git_dir:" | awk \'{print $2}\')\nmkdir -p "$GITOPS_DIR/applications/workloads/<business-system>"\ncp -r ./r6ace-output/* "$GITOPS_DIR/applications/workloads/<business-system>/"\ngit -C "$GITOPS_DIR" add applications/workloads/<business-system>\ngit -C "$GITOPS_DIR" commit -m "Import R6 app bundle for <business-system>"\ngit -C "$GITOPS_DIR" push\nflux reconcile kustomization flux-system --with-source')
    +'</div>';
}

// ── Source selection (iframes) ──────────────────────────────────────────────
window.r6aceSelectSrc=function(src){
  _r6ace.source=src;
  ['bs','vm'].forEach(function(s){var c=document.getElementById('r6ace-card-'+s);if(!c)return;c.style.borderColor=s===src?(src==='bs'?'#0369a1':'#7c3aed'):'#e2e8f0';c.style.background=s===src?(src==='bs'?'#eff6ff':'#faf5ff'):'#fff';});
  var panel=document.getElementById('r6ace-src-panel'); if(!panel) return;
  if(src==='bs'){
    panel.innerHTML='<div style="font-size:11px;color:#64748b;margin-bottom:8px;">Select an existing FLEX business system from the Migration Log or use a template. Click <strong>Load Selected System</strong> to pull components.</div>'
      +'<div style="display:flex;gap:8px;margin-bottom:8px;"><button onclick="r6aceLoadBSFromIframe()" style="background:#0369a1;color:#fff;border:none;border-radius:6px;padding:6px 14px;font-size:12px;font-weight:700;cursor:pointer;">&#128228; Load Selected System</button></div>'
      +'<iframe id="r6ace-bs-iframe" src="/?only=biz_cards&stage=s4" style="display:block;width:100%;height:640px;border:1px solid #e2e8f0;border-radius:8px;background:#fff;" title="FLEX Business Systems"></iframe>'
      +'<div id="r6ace-comp-section" style="display:none;margin-top:12px;">'
      +SL('FLEX Components Loaded')
      +'<div style="overflow:auto;">'+tbl(['Component','FLEX VM/DB','Role','Runtime','Ports','Dependencies','Volumes','Current Status'],'<tr><td colspan="8" style="padding:12px;text-align:center;color:#94a3b8;font-size:12px;" id="r6ace-comp-tbody-row">Click Load Selected System above.</td></tr>','900px')+'</div></div>';
  } else {
    panel.innerHTML='<div style="font-size:11px;color:#64748b;margin-bottom:8px;">Use the FLEX VM scanner to find and select a FLEX VM, snapshot, or volume for single-component conversion. Then click <strong>Load Selected VM</strong>.</div>'
      +'<div style="display:flex;gap:8px;margin-bottom:8px;"><button onclick="r6aceLoadVMFromIframe()" style="background:#7c3aed;color:#fff;border:none;border-radius:6px;padding:6px 14px;font-size:12px;font-weight:700;cursor:pointer;">&#128228; Load Selected VM / DB</button></div>'
      +'<iframe src="/image_migrator/?mode=flex2flex&embedded=1&focus=snapshot" style="display:block;width:100%;height:680px;border:1px solid #e2e8f0;border-radius:8px;" title="FLEX VM Scanner"></iframe>';
  }
  var si=document.getElementById('r6ace-sum-input'); if(si) si.textContent=src==='bs'?'FLEX Business System':'Single FLEX VM/DB';
};

window.r6aceLoadBSFromIframe=function(){
  try{
    var sys=JSON.parse(localStorage.getItem('uatS1_systems')||'[]'); if(!sys.length){alert('No FLEX business systems. Create them in Migration Logs first.');return;}
    var selId=localStorage.getItem('uatS1_selectedSystem')||localStorage.getItem('aceSelectedBS');
    var bs=selId?sys.find(function(s){return s.id===selId;}):null; if(!bs) bs=sys[0];
    r6aceSelectBS(bs.id);
    var sec=document.getElementById('r6ace-comp-section'); if(sec) sec.style.display='block';
    var row=document.getElementById('r6ace-comp-tbody-row');
    if(row&&bs.components){
      var K8S=R6ACE_K8S;
      var html=bs.components.map(function(c){
        var role=(c.type||c.role||'backend').toLowerCase();
        var k8s=K8S[role]||'Deployment+Service';
        var r=role==='database'||role==='db'?badge('External','#dbeafe','#1d4ed8'):badge('Ready','#dcfce7','#16a34a');
        return '<tr style="border-bottom:1px solid #f1f5f9;"><td style="padding:6px 10px;font-weight:600;">'+c.name+'</td><td style="padding:6px 10px;color:#0369a1;">'+(c.vmName||c.id||'—')+'</td><td style="padding:6px 10px;">'+badge(role,'#ede9fe','#6d28d9')+'</td><td style="padding:6px 10px;color:#64748b;">'+(c.runtime||'—')+'</td><td style="padding:6px 10px;color:#64748b;">'+(c.ports?c.ports.join(','):'—')+'</td><td style="padding:6px 10px;color:#64748b;">'+(c.dependencies?c.dependencies.join(','):'—')+'</td><td style="padding:6px 10px;color:#64748b;">'+(c.volumes&&c.volumes.length?c.volumes.length+' vol':'—')+'</td><td style="padding:6px 10px;">'+r+'</td></tr>';
      }).join('');
      row.parentElement.parentElement.querySelector('tbody').innerHTML=html;
    }
  }catch(e){alert('Error: '+e.message);}
};

window.r6aceLoadVMFromIframe=function(){
  _r6ace.components=[{name:'selected-vm',type:'vm',vmName:'flex-vm-selected',ports:['3000'],runtime:'detected'}];
  var sc=document.getElementById('r6ace-sum-comps'); if(sc) sc.textContent='1 component';
  r6aceSetStatus(1,'done'); r6aceRenderNav();
  alert('VM loaded. Click Continue to proceed to Capture Method.');
};

window.r6aceLoadBizSystems=function(){
  var list=document.getElementById('r6ace-bs-list'); if(!list) return;
  try{var sys=JSON.parse(localStorage.getItem('uatS1_systems')||'[]');if(!sys.length)return;list.innerHTML=sys.map(function(s){return '<div onclick="r6aceSelectBS(\''+s.id+'\')" id="r6ace-bs-'+s.id+'" style="border:1px solid #e2e8f0;border-radius:8px;padding:9px 12px;margin-bottom:7px;cursor:pointer;background:#fff;"><strong>'+s.name+'</strong> &#8212; '+(s.components||[]).length+' components</div>';}).join('');}catch(e){}
};

window.r6aceSelectBS=function(id){
  try{var sys=JSON.parse(localStorage.getItem('uatS1_systems')||'[]');var bs=sys.find(function(s){return s.id===id;});if(!bs)return;_r6ace.bs=bs;_r6ace.components=bs.components||[];var sc=document.getElementById('r6ace-sum-comps');if(sc)sc.textContent=_r6ace.components.length+' components';r6aceSetStatus(1,'done');}catch(e){}
};

// ── Capture method ───────────────────────────────────────────────────────────
window.r6aceSetMethod=function(m){
  if(m==='compat'){var b=document.getElementById('r6ace-compat-confirm');if(b)b.style.display='block';return;}
  _r6ace.captureMethod=m;var bb=document.getElementById('r6ace-compat-banner');if(bb)bb.style.display='none';
  var sm=document.getElementById('r6ace-sum-method');if(sm)sm.textContent=m==='smart'?'Smart Snapshot':'Full Snapshot Compat';
  r6aceShowStep(_r6ace.step);
};
window.r6aceConfirmCompat=function(){_r6ace.captureMethod='compat';var b=document.getElementById('r6ace-compat-banner');if(b)b.style.display='block';var cb=document.getElementById('r6ace-compat-confirm');if(cb)cb.style.display='none';r6aceShowStep(_r6ace.step);};

// ── Run command ──────────────────────────────────────────────────────────────
window.r6aceRun=function(cmdId,outId){var out=document.getElementById(outId);var cEl=document.getElementById(cmdId);if(!out||!cEl)return;var cmd=cEl.textContent;out.style.display='block';out.textContent='$ '+cmd+'\n';var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);var es=new EventSource(url);es.onmessage=function(e){if(e.data!=='[DONE]'){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;}else es.close();};es.onerror=function(){out.textContent+='[closed]\n';es.close();};};

// ── Generators ───────────────────────────────────────────────────────────────
window.r6aceGenYAML=function(){var c=_r6ace.components.length?_r6ace.components:[{name:'app',type:'frontend',ports:['8080']}];_r6ace.yaml=c.map(function(comp){var role=(comp.type||comp.role||'frontend').toLowerCase();var n=(comp.name||'app').toLowerCase().replace(/\s+/g,'-');if(role==='database'||role==='db')return '# ExternalDB: '+n+'\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: '+n+'-db-config\n  annotations:\n    r6ace/captureMethod: ExternalDB\ndata:\n  host: "REPLACE_WITH_DB_HOST"\n  port: "5432"\n---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: '+n+'-db-secret\ntype: Opaque\nstringData:\n  password: "REPLACE"\n';if(role==='worker'||role==='batch')return 'apiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: '+n+'\n  annotations:\n    r6ace/captureMethod: '+_r6ace.captureMethod+'\nspec:\n  schedule: "0 * * * *"\n  jobTemplate:\n    spec:\n      template:\n        spec:\n          containers:\n          - name: '+n+'\n            image: registry.example.com/'+n+':v1.0.0\n          restartPolicy: OnFailure\n';return 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: '+n+'\n  annotations:\n    r6ace/captureMethod: '+_r6ace.captureMethod+'\n    r6ace/cloudNativeStatus: '+((_r6ace.captureMethod==='smart')?'CLOUD_NATIVE_READY':'COMPATIBILITY_CONTAINER_ONLY')+'\nspec:\n  replicas: 2\n  selector:\n    matchLabels:\n      app: '+n+'\n  template:\n    metadata:\n      labels:\n        app: '+n+'\n    spec:\n      containers:\n      - name: '+n+'\n        image: registry.example.com/'+n+':v1.0.0\n        ports:\n        - containerPort: '+(comp.ports&&comp.ports[0]||8080)+'\n---\napiVersion: v1\nkind: Service\nmetadata:\n  name: '+n+'\nspec:\n  selector:\n    app: '+n+'\n  ports:\n  - port: 80\n    targetPort: '+(comp.ports&&comp.ports[0]||8080)+'\n';}).join('\n---\n');var el=document.getElementById('r6ace-yaml-pre');if(el)el.textContent=_r6ace.yaml;r6aceMarkArt('yaml');};
window.r6aceGenHelm=function(){var n=(_r6ace.bs&&_r6ace.bs.name||'app').toLowerCase().replace(/\s+/g,'-');var h='# Chart.yaml\napiVersion: v2\nname: '+n+'\nversion: 1.0.0\nannotations:\n  r6ace/captureMethod: '+_r6ace.captureMethod+'\n\n# values.yaml\nreplicaCount: 2\nimage:\n  repository: registry.example.com/'+n+'\n  tag: v1.0.0\nservice:\n  port: 80\ningress:\n  enabled: true\n';_r6ace.helm=h;var el=document.getElementById('r6ace-gitops-pre');if(el)el.textContent=h;r6aceMarkArt('helm');};
window.r6aceGenKustomize=function(){var h='# kustomization.yaml\napiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- namespace.yaml\n- deployment.yaml\n- service.yaml\n- configmap.yaml\n- ingress.yaml\n- networkpolicy.yaml\n\n# overlays/prod/kustomization.yaml\nbases:\n- ../../base\npatches:\n- replica-patch.yaml\n';_r6ace.kustomize=h;var el=document.getElementById('r6ace-gitops-pre');if(el)el.textContent=h;r6aceMarkArt('kustomize');};
window.r6aceGenFlux=function(){var n=(_r6ace.bs&&_r6ace.bs.name||'app').toLowerCase().replace(/\s+/g,'-');var h='apiVersion: kustomize.toolkit.fluxcd.io/v1\nkind: Kustomization\nmetadata:\n  name: '+n+'\n  namespace: flux-system\nspec:\n  interval: 5m\n  path: "./applications/overlays/'+n+'"\n  prune: true\n  sourceRef:\n    kind: GitRepository\n    name: opencenter-gitops\n';_r6ace.flux=h;var el=document.getElementById('r6ace-gitops-pre');if(el)el.textContent=h;r6aceMarkArt('flux');};

window.r6aceGenBundle=function(){
  if(!_r6ace.components.length&&!_r6ace.bs){alert('Select a FLEX input first.');return;}
  r6aceGenYAML();r6aceGenHelm();r6aceGenKustomize();r6aceGenFlux();
  var warnings=[]; var blockers=[];
  (_r6ace.components||[]).forEach(function(c){var r=(c.type||c.role||'').toLowerCase();if(r==='database')warnings.push(c.name+': Keep on FLEX VM — configure ExternalDB');if(!c.runtime)warnings.push(c.name+': Runtime inferred — verify before deploy');});
  if(_r6ace.captureMethod==='compat')warnings.push('COMPATIBILITY_CONTAINER: not fully cloud-native — manual hardening required');
  var m={source:_r6ace.source==='vm'?'single_flex_vm':'flex_business_system',sourcePlatform:'flex',captureMethod:_r6ace.captureMethod==='smart'?'SMART_SNAPSHOT_CAPTURE':'FULL_SNAPSHOT_COMPATIBILITY_CONTAINER',customer:'',businessSystem:_r6ace.bs&&_r6ace.bs.name||'',snapshotCreatedByEngine:true,sourceFlexVmId:'',sourceFlexVmName:'',sourceSnapshotId:'',conversionEngine:'APPS_to_Container_Refactor_Engine',cloudNativeStatus:_r6ace.captureMethod==='smart'?'CLOUD_NATIVE_READY':'COMPATIBILITY_CONTAINER_ONLY',artifacts:{dockerfile:_r6ace.captureMethod==='smart'?'smart_snapshot_capture/dockerfiles/':'full_snapshot_compatibility/compatibility_Dockerfile',kustomizeBundle:'08-gitops/kustomize/',helmChart:'08-gitops/helm/',fluxKustomization:'08-gitops/flux/app-kustomization.yaml',imageBuildPlan:'05-containerization/image_build_plan.yaml',externalizationPlan:'06-externalization/externalization_plan.md',compatibilityWarnings:_r6ace.captureMethod==='compat'?'03-capture/compatibility_warnings.json':''},workloads:(_r6ace.components||[]).filter(function(c){return (c.type||c.role||'').toLowerCase()!=='database';}).map(function(c){return {name:c.name,kind:'Deployment',cloudNativeStatus:_r6ace.captureMethod==='smart'?'CLOUD_NATIVE_READY':'COMPATIBILITY_CONTAINER_ONLY'};}),externalServices:(_r6ace.components||[]).filter(function(c){return (c.type||c.role||'').toLowerCase()==='database';}).map(function(c){return {name:c.name,type:'ExternalDB'};}),keptOnFlexVm:(_r6ace.components||[]).filter(function(c){return (c.type||c.role||'').toLowerCase()==='database';}).map(function(c){return c.name;}),warnings:warnings,blockers:blockers};
  _r6ace.bundle=m;
  var el=document.getElementById('r6ace-bundle-pre');if(el)el.textContent=JSON.stringify(m,null,2);
  var vs=document.getElementById('r6ace-bundle-val');if(vs){var ok=blockers.length===0;vs.style.background=ok?(warnings.length?'#fef3c7':'#dcfce7'):'#fee2e2';vs.style.color=ok?(warnings.length?'#d97706':'#16a34a'):'#dc2626';vs.innerHTML='<strong>'+(ok?(warnings.length?'PASS WITH WARNINGS':'PASS'):'FAIL')+'</strong> | captureMethod: '+m.captureMethod+(warnings.length?' | '+warnings.length+' warning(s)':'');}
  var sb=document.getElementById('r6ace-sum-bundle');if(sb){sb.textContent=blockers.length?'FAIL':warnings.length?'WARNING (PASS)':'Generated (PASS)';sb.style.color=blockers.length?'#dc2626':warnings.length?'#d97706':'#16a34a';}
  localStorage.setItem('r6OpenCenterHandoffBundle',JSON.stringify(m));
  [6,7,8,9,10,11].forEach(function(n){r6aceSetStatus(n,'done');});r6aceRenderNav();
};

window.r6aceSendToOC=function(){r6aceGenBundle();setTimeout(function(){if(typeof openCenterImportFromR6==='function')openCenterImportFromR6();},300);var s=document.querySelector('[data-sub="s2opencenter"]');if(s)setTimeout(function(){s.click();},600);};
window.r6aceShowCommitCmds=function(){var el=document.getElementById('r6ace-commit-cmds');if(el)el.style.display=el.style.display==='none'?'block':'none';};
window.r6aceMarkArt=function(art){_r6ace.artifacts[art]=true;};
window.r6aceMarkDone=function(n){r6aceSetStatus(n,'done');if(n<12)r6aceShowStep(n+1);};
window.r6aceSetStatus=function(n,st){_r6ace.status[n]=st;r6aceRenderNav();var done=Object.values(_r6ace.status).filter(function(s){return s==='done';}).length;var pct=Math.round(done/12*100);var pb=document.getElementById('r6ace-progress');if(pb)pb.style.width=pct+'%';var pt=document.getElementById('r6ace-pct');if(pt)pt.textContent=pct+'%';};
window.r6aceNext=function(){if(_r6ace.step<12)r6aceShowStep(_r6ace.step+1);};
window.r6acePrev=function(){if(_r6ace.step>1)r6aceShowStep(_r6ace.step-1);};
window.r6aceRunStep=function(){r6aceSetStatus(_r6ace.step,'ip');r6aceRenderNav();};
window.r6aceRunAll=function(){r6aceGenBundle();for(var i=1;i<=12;i++)r6aceSetStatus(i,'done');r6aceShowStep(12);};
window.r6aceDownload=function(fn,content){var a=document.createElement('a');a.href='data:text/plain;charset=utf-8,'+encodeURIComponent(content||'');a.download=fn;a.click();};

// Auto-init
document.addEventListener('click',function(e){if(e.target.closest('[data-sub="s2r6ace"]'))setTimeout(r6aceInit,300);});
document.addEventListener('DOMContentLoaded',function(){setTimeout(function(){var orig=window.uatS1SaveSystem;if(typeof orig==='function')window.uatS1SaveSystem=function(d){orig.call(this,d);setTimeout(r6aceLoadBizSystems,150);};},1000);});
