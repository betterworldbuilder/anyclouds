/* APPS to Container Refactor Engine v4 */
var R6P={current:0,status:{},bs:null,components:[],captureMethod:'smart',compatConfirmed:false,yaml:'',bundle:null,artifacts:{},preflight:{},continueBlocked:true,creds:{cloud:{status:'not_configured',authUrl:'',region:'',credId:'',projectId:''},opencenter:{status:'not_configured',clusterRef:'rackspace-flex/flex-prod-k8s',gitDir:''},gitops:{status:'not_configured',localPath:'',branch:'main',method:'existing'}}};
var R6P_TOOLS=[
  {name:'git',        req:true,  note:'GitOps commit',           manual:false},
  {name:'curl',       req:true,  note:'CLI installers',          manual:false},
  {name:'jq',         req:true,  note:'JSON parsing',            manual:false},
  {name:'kubectl',    req:true,  note:'Cluster validation',      manual:false},
  {name:'flux',       req:true,  note:'Flux reconcile',          manual:false},
  {name:'openstack',  req:true,  note:'Cloud API / token test',  manual:false},
  {name:'opencenter', req:true,  note:'Cluster metadata',        manual:true},
  {name:'helm',       req:false, note:'Helm chart validation',   manual:false},
  {name:'yq',         req:false, note:'YAML processing',         manual:false},
  {name:'kustomize',  req:false, note:'Kustomize validation',    manual:false}
];
var R6P_STEPS=[{n:0,label:'Preflight',title:'Preflight Requirements Check',desc:'Verify CLI tools, credentials, and GitOps access before running the refactor workflow.'},{n:1,label:'Input',title:'Select FLEX Business System / App Input',desc:'Select a migrated FLEX Business System or a single FLEX VM / DB. Only FLEX workloads are accepted.'},{n:2,label:'Discovery',title:'Discover FLEX Snapshots (offline components only)',desc:'Not needed for live FLEX VMs - their target IP and volumes are already known from Step 1. Only used to capture an offline/stopped component.'},{n:3,label:'Snapshot',title:'Select Snapshot / Volume Snapshot (offline components only)',desc:'Select snapshots for Smart Snapshot or Full Snapshot capture. Skip for live FLEX VMs.'},{n:4,label:'Mapping',title:'Map Snapshot to Business System Component (offline components only)',desc:'Link selected snapshots to business system components. Skip for live FLEX VMs.'},{n:5,label:'Method',title:'Choose Capture and Conversion Method (offline components only)',desc:'Smart Snapshot (recommended) or Full Snapshot Compatibility (legacy fallback). Skip for live FLEX VMs.'},{n:6,label:'Scan',title:'Live Scan (FLEX VM already running)',desc:'Scan the already-running FLEX VM directly over SSH using its known target IP - OS, runtime, ports, services, files.'},{n:7,label:'Classify',title:'App Detection and File Classification',desc:'Identify real application content and classify all files.'},{n:8,label:'Readiness',title:'Container Readiness Assessment',desc:'Score each component: CLOUD_NATIVE_READY, READY_WITH_EXTERNALIZATION, KEEP_ON_FLEX, BLOCKED.'},{n:9,label:'Build',title:'Container Build Plan',desc:'Generate Dockerfile, image plan, base image, build/start command, health check, CPU/memory.'},{n:10,label:'GitOps',title:'Kubernetes YAML / Helm / Kustomize / Flux',desc:'Generate all Kubernetes and GitOps artifacts.'},{n:11,label:'Bundle',title:'OpenCenter Import Bundle',desc:'Assemble the final OpenCenter-ready application bundle.'},{n:12,label:'OpenCenter',title:'Send to OpenCenter GitOps',desc:'Import bundle, generate commit commands, trigger Flux reconciliation.'},
{n:13,label:'Data+Validate',title:'Data Migration, App Validation & Cutover',desc:'Per-component data migration commands, live app-level validation (HTTP/DB), and a cutover checklist with real DNS/LB commands.'},
{n:14,label:'Report',title:'Post-Migration Report',desc:'Generate the customer migration evidence report: source/target mapping, decisions, validation results, downloadable as JSON/Markdown.'}];
var R6P_MAX_STEP=Math.max.apply(null,R6P_STEPS.map(function(s){return s.n;}));

window.r6pInit=function(){r6pRenderProgress();r6pRenderStages();r6pGoTo(0);setTimeout(r6pLoadBiz,350);setTimeout(r6pLoadCredCache,200);setTimeout(r6pLoadCredsServer,250);};

/* Server-side credential persistence - survives incognito/browser reset/different browsers.
   localStorage stays as a fast local mirror; the server file is the source of truth. */
window.r6pSaveCredsServer=function(){
  var v=function(id){var el=document.getElementById(id);return el?el.value:'';};
  var payload={
    cloud:{authUrl:v('r6p-c-authurl'),authType:v('r6p-c-authtype'),username:v('r6p-c-username'),
      password:v('r6p-c-password'),credId:v('r6p-c-credid'),secret:v('r6p-c-secret'),
      proj:v('r6p-c-proj'),domain:v('r6p-c-domain'),region:v('r6p-c-region')},
    gitops:{repo:v('r6p-git-repo'),branch:v('r6p-git-branch'),auth:v('r6p-git-auth'),
      sshkey:v('r6p-git-sshkey'),localdir:v('r6p-git-localdir'),token:v('r6p-git-token')}
  };
  fetch('/api/r6/save-creds',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)}).catch(function(){});
};
window.r6pLoadCredsServer=function(){
  fetch('/api/r6/load-creds').then(function(r){return r.json();}).then(function(d){
    if(!d||!d.ok||!d.data)return;
    var c=d.data.cloud||{},g=d.data.gitops||{};
    var set=function(id,val){if(!val)return;var el=document.getElementById(id);if(el&&!el.value)el.value=val;};
    set('r6p-c-authurl',c.authUrl);set('r6p-c-username',c.username);set('r6p-c-password',c.password);
    set('r6p-c-credid',c.credId);set('r6p-c-secret',c.secret);set('r6p-c-proj',c.proj);
    set('r6p-c-domain',c.domain);
    if(c.authType){var dt=document.getElementById('r6p-c-authtype');if(dt){dt.value=c.authType;r6pAuthTypeChange(c.authType);}}
    if(c.region){var rs=document.getElementById('r6p-c-region');if(rs)rs.value=c.region;}
    set('r6p-git-repo',g.repo);set('r6p-git-branch',g.branch);set('r6p-git-sshkey',g.sshkey);
    set('r6p-git-token',g.token);
    if(g.auth){var ga=document.getElementById('r6p-git-auth');if(ga){ga.value=g.auth;if(typeof r6pGitAuthToggle==='function')r6pGitAuthToggle();}}
    if(g.localdir&&typeof r6pLooksLikeGitDir==='function'&&r6pLooksLikeGitDir(g.localdir)){
      set('r6p-git-localdir',g.localdir);R6P.creds.opencenter.gitDir=g.localdir;
    } else if(typeof r6pAutoDetectGitDir==='function'){ r6pAutoDetectGitDir(); }
    if(typeof r6pRefreshCloudBadge==='function')setTimeout(r6pRefreshCloudBadge,0);
    var b=document.getElementById('r6p-git-badge');
    if(b&&g.repo){b.textContent='Configured';b.style.color='#15803d';}
  }).catch(function(){});
};
window.r6aceInit=window.r6pInit;

var R6P_RESCAN_GROUP=[2,3,4,5,6];
window.r6pRenderProgress=function(){
  var el=document.getElementById('r6p-progress-inner');if(!el)return;
  var shown=R6P_STEPS.filter(function(s){return R6P_RESCAN_GROUP.indexOf(s.n)<0||s.n===R6P_RESCAN_GROUP[0];});
  el.innerHTML=shown.map(function(s,i){
    if(s.n===R6P_RESCAN_GROUP[0]){
      var grpCur=R6P_RESCAN_GROUP.indexOf(R6P.current)>=0;
      return (i>0?'<span class="r6p-arrow">&gt;</span>':'')+'<span class="r6p-step'+(grpCur?' current':'')+'" onclick="r6pGoTo(2)">2-6. Refresh (skip)</span>';
    }
    var st=R6P.status[s.n]||'ns',isCur=R6P.current===s.n,cls=isCur?'current':st;
    return (i>0?'<span class="r6p-arrow">&gt;</span>':'')+'<span class="r6p-step '+cls+'" onclick="r6pGoTo('+s.n+')">'+s.n+'. '+s.label+'</span>';
  }).join('');
};

window.r6pRenderStages=function(){
  var el=document.getElementById('r6p-stages');if(!el)return;
  el.innerHTML=R6P_STEPS.map(function(s){
    if(R6P_RESCAN_GROUP.indexOf(s.n)>=0&&s.n!==R6P_RESCAN_GROUP[0])return '';
    if(s.n===R6P_RESCAN_GROUP[0]){
      var grpOpen=R6P_RESCAN_GROUP.indexOf(R6P.current)>=0;
      var grpBody=R6P_RESCAN_GROUP.map(function(gn){
        var gs=R6P_STEPS.filter(function(x){return x.n===gn;})[0];
        return '<div style="border-top:1px solid #e2e8f0;padding-top:12px;margin-top:12px;">'
          +'<div style="font-weight:800;font-size:12px;color:#334155;margin-bottom:2px;">'+gn+'. '+gs.title+'</div>'
          +'<div style="font-size:11px;color:#94a3b8;margin-bottom:8px;">'+gs.desc+'</div>'
          +r6pContent(gn)+'</div>';
      }).join('');
      return '<div id="r6p-stage-'+R6P_RESCAN_GROUP[0]+'" class="r6p-stage'+(grpOpen?' current':'')+'">'
        +'<div class="r6p-stage-hd" onclick="r6pToggleRescanGroup()" style="cursor:pointer;">'
        +'<div class="r6p-stage-num">&#8635;</div>'
        +'<div class="r6p-stage-info"><div class="r6p-stage-title">Refresh FLEX VM / DB List</div><div class="r6p-stage-desc">Snapshot discovery + live scan, steps 2-6. Not needed by default - the target IP/volume is already known from the selected Business System. Expand only to refresh a component’s data.</div></div>'
        +'<span class="r6p-stage-badge" style="background:#f1f5f9;color:#64748b;">SKIP by Default</span>'
        +'<span id="r6p-rescan-chevron" style="margin-left:10px;font-size:14px;color:#94a3b8;transition:transform .15s;'+(grpOpen?'transform:rotate(90deg);':'')+'">&#9654;</span>'
        +'</div>'
        +'<div class="r6p-stage-body'+(grpOpen?' open':'')+'" id="r6p-body-'+R6P_RESCAN_GROUP[0]+'"><div class="r6p-stage-body-inner">'+grpBody+'</div></div>'
        +'</div>';
    }
    var st=R6P.status[s.n]||'ns',isCur=R6P.current===s.n;
    var bstyle=isCur?'background:#eff6ff;color:#0369a1;':st==='done'?'background:#dcfce7;color:#16a34a;':st==='warn'?'background:#fef3c7;color:#d97706;':st==='blocked'?'background:#fee2e2;color:#dc2626;':'background:#f1f5f9;color:#94a3b8;';
    var btxt=isCur?'Current':st==='done'?'Complete':st==='warn'?'Warning':st==='blocked'?'Blocked':'Not Started';
    var ccls='r6p-stage'+(isCur?' current':st!=='ns'?' '+st:'');
    return '<div id="r6p-stage-'+s.n+'" class="'+ccls+'">'
      +'<div class="r6p-stage-hd" onclick="r6pGoTo('+s.n+')">'
      +'<div class="r6p-stage-num">'+s.n+'</div>'
      +'<div class="r6p-stage-info"><div class="r6p-stage-title">'+s.title+'</div><div class="r6p-stage-desc">'+s.desc+'</div></div>'
      +'<span class="r6p-stage-badge" id="r6p-stage-badge-'+s.n+'" style="'+bstyle+'">'+btxt+'</span>'
      +'</div>'
      +'<div class="r6p-stage-body" id="r6p-body-'+s.n+'"><div class="r6p-stage-body-inner">'+r6pContent(s.n)+'</div></div>'
      +'</div>';
  }).join('');
};

window.r6pToggleRescanGroup=function(){
  var b=document.getElementById('r6p-body-'+R6P_RESCAN_GROUP[0]);
  var card=document.getElementById('r6p-stage-'+R6P_RESCAN_GROUP[0]);
  var chev=document.getElementById('r6p-rescan-chevron');
  if(!b||!card)return;
  var willOpen=!b.classList.contains('open');
  if(willOpen){
    b.classList.add('open');card.className='r6p-stage current';
    if(chev)chev.style.transform='rotate(90deg)';
  } else {
    b.classList.remove('open');card.className='r6p-stage';
    if(chev)chev.style.transform='';
  }
};
window.r6pGoTo=function(n){
  R6P.current=n;
  R6P_STEPS.forEach(function(s){
    var b=document.getElementById('r6p-body-'+s.n),card=document.getElementById('r6p-stage-'+s.n);
    if(!b||!card)return;
    if(s.n===n){setTimeout(function(){b.classList.add('open');card.className='r6p-stage current';card.scrollIntoView({behavior:'smooth',block:'nearest'});},40);}
    else{b.classList.remove('open');var st=R6P.status[s.n]||'ns';card.className='r6p-stage'+(st!=='ns'?' '+st:'');}
  });
  r6pRenderProgress();
  if(n===1){setTimeout(r6pLoadBiz,200);}
};

function r6pFoot(n,extra){var nextN=(n===1)?7:n+1;return '<div class="r6p-stage-footer">'+(extra||'')+'<button class="r6p-btn success" onclick="r6pMarkDone('+n+')">Mark Complete</button>'+(n<R6P_MAX_STEP?'<button class="r6p-btn primary" onclick="r6pGoTo('+nextN+')">Continue</button>':'')+'</div>';}

/* Real migration-mode decision engine (Stage 4-5): evaluates each component against
   name/type signals and, if available, the Step 2-6 live scan output. */
window.r6pDecideMigrationMode=function(c){
  var name=(c.name||'').toLowerCase();
  var type=(c.type||c.role||'').toLowerCase();
  var isDb=type==='database'||type==='db'||/\b(db|database|sql|mysql|postgres|mongo|redis)\b/.test(name);
  var isWindows=/win|windows/.test(name)||/win|windows/.test(type);
  var scan=R6P.depScan&&R6P.depScan[c.name];
  var appFileCount=0;
  if(scan&&scan.rawLog){var m=scan.rawLog.split('\n').filter(function(l){return l.indexOf('/')===0;});appFileCount=m.length;}
  var siblingHasDb=(R6P.components||[]).some(function(x){var t=(x.type||x.role||'').toLowerCase();return x.name!==c.name&&(t==='database'||t==='db');});

  if(isWindows){
    return {name:c.name,workloadType:'Legacy Windows app',status:'COMPATIBILITY_CONTAINER_ONLY',
      reason:'Windows workloads are not cloud-native containerizable by this engine yet.',
      method:'Rehost VM first, containerize later only if possible'};
  }
  if(isDb){
    return {name:c.name,workloadType:'Database',status:'KEEP_ON_FLEX_VM_FOR_NOW',
      reason:'Stateful database - keep external, do not bake into a container image.',
      method:'Split app and DB, migrate DB separately (dump/restore or replication)'};
  }
  if(!scan){
    return {name:c.name,workloadType:'Unscanned application',status:'READY_WITH_EXTERNALIZATION',
      reason:'No live scan run yet (Step 2-6) - assuming stateless until scanned.',
      method:'Containerize and deploy via OpenCenter GitOps (run live scan to confirm)'};
  }
  if(appFileCount>200){
    return {name:c.name,workloadType:'Complex monolith',status:'READY_WITH_EXTERNALIZATION',
      reason:appFileCount+' files found under app paths - large/complex codebase.',
      method:'Smart snapshot/app capture, then staged refactor'};
  }
  if(appFileCount>20){
    return {name:c.name,workloadType:'App with local files',status:'READY_WITH_EXTERNALIZATION',
      reason:appFileCount+' files found under app paths - needs persistent storage.',
      method:'Containerize + migrate data to PVC/object storage'};
  }
  if(siblingHasDb){
    return {name:c.name,workloadType:'App tier (DB is a sibling component)',status:'CLOUD_NATIVE_READY',
      reason:'Stateless app tier; database is handled as a separate component.',
      method:'Containerize and deploy via OpenCenter GitOps'};
  }
  return {name:c.name,workloadType:'Simple stateless web app',status:'CLOUD_NATIVE_READY',
    reason:appFileCount+' files found under app paths - lightweight, no local DB detected.',
    method:'Containerize and deploy via OpenCenter GitOps'};
};
function r6pCmd(id,cmd){var cid='r6p-cmd-'+id,oid='r6p-out-'+id;return '<div class="r6p-cmd-box" id="'+cid+'">'+cmd.replace(/</g,'&lt;').replace(/>/g,'&gt;')+'</div><div style="display:flex;gap:5px;margin-bottom:8px;"><button onclick="navigator.clipboard&&navigator.clipboard.writeText(document.getElementById(\''+cid+'\').textContent)" style="background:#f1f5f9;color:#475569;border:1px solid #e2e8f0;border-radius:4px;padding:3px 10px;font-size:10px;cursor:pointer;">Copy</button><button onclick="r6pRunCmd(\''+cid+'\',\''+oid+'\')" style="background:#eff6ff;color:#0369a1;border:1px solid #bfdbfe;border-radius:4px;padding:3px 10px;font-size:10px;font-weight:700;cursor:pointer;">Run</button><button onclick="var e=document.getElementById(\''+oid+'\');e.style.display=e.style.display===\'none\'?\'block\':\'none\'" style="background:#f1f5f9;color:#64748b;border:1px solid #e2e8f0;border-radius:4px;padding:3px 10px;font-size:10px;cursor:pointer;">Log</button></div><div id="'+oid+'" class="r6p-terminal" style="display:none;">$ waiting...</div>';}

window.r6pContent=function(n){
  if(n===0)return r6pStage0();
  if(n===1)return '<div class="r6p-warn-box">Only FLEX workloads can be converted here. Complete migration to FLEX first.</div><div class="uat-s1-biz-grid"><div><div style="font-weight:800;font-size:15px;color:#0f172a;margin-bottom:12px;">Business Systems <span style="font-size:11px;color:#64748b;font-weight:400;">from FLEX Migration Log</span></div><div id="r6p-biz-list" style="min-height:180px;"></div>'
    +'</div><div class="uat-s1-arch-selector"><div class="uat-s1-arch-head"><div class="uat-s1-arch-title">Business System Templates</div><span class="uat-s1-arch-badge">10 Templates</span></div><p class="uat-s1-arch-desc">Templates define structure only. Conversion requires real FLEX VM/DB mapping.</p><div class="uat-s1-template-pane active"><div id="r6p-arch-grid" class="uat-s1-arch-grid"></div></div></div></div>'+r6pFoot(1,'<button class="r6p-btn secondary" onclick="r6pLoadBiz()">Refresh FLEX Inventory</button>');
  if(n===2||n===3||n===4||n===5){
    var skipMsg={2:'Discover FLEX Snapshots',3:'Select Snapshot / Volume Snapshot',4:'Map Snapshot to Business System Component',5:'Choose Capture and Conversion Method'}[n];
    return '<div class="r6p-info-box" style="background:#f0fdf4;border-color:#bbf7d0;">'
      +'<strong>Not required for this business system.</strong> Its components already have a live FLEX target IP and attached volume '
      +'(captured when the Business System was set up in Step 1) - there is nothing to snapshot or map here.'
      +'</div>'
      +'<div style="font-size:12px;color:#64748b;margin-bottom:14px;">"'+skipMsg+'" only applies when a component is offline/stopped and can only be reached via a snapshot. '
      +'<a href="#" onclick="var e=document.getElementById(\'r6p-legacy-snap-'+n+'\');if(e)e.style.display=e.style.display===\'none\'?\'block\':\'none\';return false;">Use snapshot capture for an offline component instead &rarr;</a></div>'
      +'<div id="r6p-legacy-snap-'+n+'" style="display:none;margin-bottom:14px;"><iframe src="/image_migrator/?mode=flex2flex&embedded=1&focus=snapshot" style="width:100%;height:500px;border:1px solid #e2e8f0;border-radius:10px;display:block;"></iframe></div>'
      +r6pFoot(n);
  }
  if(n===6){
    var comps6=(R6P.components||[]).filter(function(c){return c.tgt;});
    var opts6=comps6.length?comps6.map(function(c,i){return '<option value="'+i+'">'+c.name+' ('+c.tgt+')</option>';}).join(''):'<option value="">No components with a FLEX target IP - select a Business System in Step 1</option>';
    return '<div class="r6p-info-box">Live scan over SSH against the FLEX VM already backing this component - no snapshot needed, it is already running with its real volumes attached.</div>'
      +'<div style="display:flex;gap:10px;flex-wrap:wrap;align-items:flex-end;margin-bottom:14px;">'
      +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Component</label><select id="r6p-scan-comp" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;min-width:260px;">'+opts6+'</select></div>'
      +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">SSH User</label><input id="r6p-scan-user" value="root" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:100px;"></div>'
      +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">SSH Key Path</label><input id="r6p-scan-key" value="~/.ssh/id_rsa" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:160px;"></div>'
      +'<button class="r6p-btn primary" onclick="r6pRunLiveScan()" style="padding:8px 16px;font-size:12px;">&#9654; Run Live Scan</button>'
      +'<button class="r6p-btn secondary" onclick="r6pExportDepScan()" style="padding:8px 16px;font-size:12px;">&#11015; Export app_dependency_report.json</button>'
      +'</div>'
      +'<div id="r6p-scan-out" class="r6p-terminal" style="display:none;max-height:260px;"></div>'
      +r6pFoot(6);
  }
  if(n===7){var rows7=[
      ['app_code','Container image','Include','Your actual application code (binaries, scripts, compiled assets). This is what gets COPYed into the Dockerfile.'],
      ['config_template','ConfigMap','Include','Non-secret config files (*.conf, *.yaml, *.ini, env templates). Becomes a Kubernetes ConfigMap, mounted into the pod.'],
      ['secret_candidate','SOPS Secret','Include','Files that look like they hold credentials (passwords, API keys, certs). SOPS-encrypted and turned into a Kubernetes Secret - never baked into the image.'],
      ['log_file','stdout/stderr','Exclude','Application log files. Containers should log to stdout/stderr instead - these are left behind, not copied.'],
      ['database_data','ExternalDB','Exclude','Actual database files/data directories. Databases stay external (RDS/managed DB) - never baked into a container image.'],
      ['excluded_file','Excluded','Exclude','OS/system files, caches, temp files - not part of the application, always left out.']
    ];
    var comps7=(R6P.components||[]).filter(function(c){return c.tgt;});
    var opts7=comps7.length?comps7.map(function(c,i){return '<option value="'+i+'">'+c.name+' ('+c.tgt+')</option>';}).join(''):'<option value="">No components with a FLEX target IP - select a Business System in Step 1</option>';
    return '<div class="r6p-info-box">Identify real application content. Classify files into app content, config, secrets, logs, data, and excluded system files.</div>'
      +'<div style="display:flex;gap:10px;flex-wrap:wrap;align-items:flex-end;margin-bottom:14px;">'
      +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Component</label><select id="r6p-classify-comp" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;min-width:260px;">'+opts7+'</select></div>'
      +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">SSH User</label><input id="r6p-classify-user" value="root" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:100px;"></div>'
      +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">SSH Key Path</label><input id="r6p-classify-key" value="~/.ssh/id_rsa" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:160px;"></div>'
      +'<button class="r6p-btn primary" onclick="r6pRunClassify()" style="padding:8px 16px;font-size:12px;">&#9654; Check</button>'
      +'</div>'
      +'<div style="overflow-x:auto;margin-bottom:14px;"><table class="r6p-table"><thead><tr><th>Classification</th><th>K8s Target</th><th>What This Means</th><th>Include/Exclude</th><th>Files Found</th></tr></thead><tbody>'
      +rows7.map(function(r){return '<tr><td style="font-weight:600;">'+r[0]+'</td><td style="color:#7c3aed;font-size:11px;">'+r[1]+'</td><td style="color:#64748b;font-size:11px;max-width:280px;">'+r[3]+'</td><td><span style="background:'+(r[2]==='Include'?'#dcfce7':'#fee2e2')+';color:'+(r[2]==='Include'?'#16a34a':'#dc2626')+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+r[2]+'</span></td><td id="r6p-classify-count-'+r[0]+'" style="font-size:11px;color:#94a3b8;">Not checked</td></tr>';}).join('')
      +'</tbody></table></div>'
      +'<div id="r6p-classify-out" class="r6p-terminal" style="display:none;max-height:220px;"></div>'
      +r6pFoot(7);}
  if(n===8){var comps8=R6P.components&&R6P.components.length?R6P.components:[];
    if(!comps8.length)return '<div class="r6p-warn-box">No components selected. Go back to Step 1 and select a Business System or standalone VM/DB.</div>'+r6pFoot(8);
    var decisions=comps8.map(function(c){return r6pDecideMigrationMode(c);});
    var counts={CLOUD_NATIVE_READY:0,READY_WITH_EXTERNALIZATION:0,KEEP_ON_FLEX_VM_FOR_NOW:0,COMPATIBILITY_CONTAINER_ONLY:0,BLOCKED:0};
    decisions.forEach(function(d){counts[d.status]=(counts[d.status]||0)+1;});
    var tiles=[['CLOUD_NATIVE_READY','#dcfce7','#16a34a'],['READY_WITH_EXTERNALIZATION','#fef3c7','#d97706'],['KEEP_ON_FLEX_VM_FOR_NOW','#dbeafe','#1d4ed8'],['COMPATIBILITY_CONTAINER_ONLY','#faf5ff','#7c3aed'],['BLOCKED','#fee2e2','#dc2626']];
    var allCanProceed=decisions.every(function(d){return d.status!=='BLOCKED';});
    return '<div class="r6p-info-box">Migration mode decision engine - evaluates each component'+"'"+'s type, OS, and (if run) Step 2-6 live scan results to recommend rehost vs. containerize.</div>'
      +'<div style="display:grid;grid-template-columns:repeat(5,1fr);gap:8px;margin-bottom:14px;">'
      +tiles.map(function(b){return '<div style="background:'+b[1]+';border-radius:8px;padding:10px;text-align:center;"><div style="font-size:16px;font-weight:900;color:'+b[2]+';">'+(counts[b[0]]||0)+'</div><div style="font-size:9px;color:'+b[2]+';font-weight:700;margin-top:2px;">'+b[0].replace(/_/g,' ')+'</div></div>';}).join('')
      +'</div><div style="overflow-x:auto;"><table class="r6p-table"><thead><tr><th>Component</th><th>Workload Type</th><th>Readiness</th><th>Reason</th><th>Recommended Method</th><th>Can Proceed</th></tr></thead><tbody>'
      +decisions.map(function(d){var rc={CLOUD_NATIVE_READY:['#dcfce7','#16a34a'],READY_WITH_EXTERNALIZATION:['#fef3c7','#d97706'],KEEP_ON_FLEX_VM_FOR_NOW:['#dbeafe','#1d4ed8'],COMPATIBILITY_CONTAINER_ONLY:['#faf5ff','#7c3aed'],BLOCKED:['#fee2e2','#dc2626']}[d.status];
        return '<tr><td style="font-weight:600;">'+d.name+'</td><td style="font-size:11px;color:#64748b;">'+d.workloadType+'</td><td><span style="background:'+rc[0]+';color:'+rc[1]+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+d.status.replace(/_/g,' ')+'</span></td><td style="font-size:11px;color:#64748b;max-width:220px;">'+d.reason+'</td><td style="font-size:11px;color:#0369a1;font-weight:700;">'+d.method+'</td><td><span style="background:'+(d.status==='BLOCKED'?'#fee2e2':'#dcfce7')+';color:'+(d.status==='BLOCKED'?'#dc2626':'#16a34a')+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+(d.status==='BLOCKED'?'No':'Yes')+'</span></td></tr>';}).join('')
      +'</tbody></table></div>'
      +(allCanProceed?'':'<div class="r6p-warn-box" style="margin-top:10px;">One or more components are BLOCKED - resolve before approving.</div>')
      +r6pFoot(8,'<button class="r6p-btn success" onclick="r6pMarkDone(8)"'+(allCanProceed?'':' disabled')+'>Approve Readiness Plan</button>');}
  if(n===9)return '<div class="r6p-info-box">Generates a real per-component Dockerfile, extract_assets.sh (pulls app files from the live FLEX VM), build_and_push.sh, and a SOPS-encrypted registry pull secret - the same engine used by Ship to OpenCenter.</div>'
    +'<div style="display:flex;gap:10px;flex-wrap:wrap;align-items:flex-end;margin-bottom:14px;">'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Registry</label><select id="r6p-build-regtype" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;"><option value="harbor" selected>Harbor (in-cluster)</option><option value="dockerhub">Docker Hub</option><option value="ecr">AWS ECR</option><option value="gcp">GCP Artifact Registry</option><option value="custom">Custom URL</option></select></div>'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Registry URL (optional)</label><input id="r6p-build-regurl" placeholder="registry.example.com" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:200px;"></div>'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Project</label><input id="r6p-build-project" value="flex-apps" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:120px;"></div>'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Registry User</label><input id="r6p-build-reguser" placeholder="admin" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:100px;"></div>'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Registry Password</label><input id="r6p-build-regpass" type="password" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:120px;"></div>'
    +'<button class="r6p-btn primary" onclick="r6pGenRealDockerfiles()" style="padding:8px 16px;font-size:12px;">&#9654; Generate Dockerfiles + Build Plan</button>'
    +'</div>'
    +'<div id="r6p-build-status" style="font-size:12px;font-weight:600;color:#64748b;margin-bottom:10px;line-height:1.7;"></div>'
    +r6pFoot(9);
  if(n===10)return '<div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px;"><button class="r6p-btn primary" onclick="r6pGenYAML()">Generate All YAML</button><button class="r6p-btn secondary" onclick="r6pGenHelm()">Helm Chart</button><button class="r6p-btn secondary" onclick="r6pGenKustomize()">Kustomize</button><button class="r6p-btn secondary" onclick="r6pGenFlux()">Flux</button></div><pre id="r6p-yaml-preview" style="background:#0f172a;color:#2dd4bf;border-radius:8px;padding:14px;font-size:11px;max-height:280px;overflow:auto;white-space:pre-wrap;min-height:60px;margin-bottom:14px;">-- Click Generate All YAML --</pre>'+r6pFoot(10);
  if(n===11)return '<div id="r6p-bundle-status" style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:10px;margin-bottom:12px;font-size:12px;color:#64748b;">Generate bundle to see status.</div><pre id="r6p-bundle-preview" style="background:#0f172a;color:#c4b5fd;border-radius:8px;padding:14px;font-size:11px;max-height:220px;overflow:auto;white-space:pre-wrap;min-height:60px;margin-bottom:12px;">-- Generate bundle to see manifest --</pre>'+r6pFoot(11,'<button class="r6p-btn primary" onclick="r6pGenBundle()">Generate OpenCenter Bundle</button><button class="r6p-btn secondary" onclick="r6pDownloadBundle()">Download</button>');
  if(n===12){
    var isC=R6P.captureMethod==='compat';
    var bsName=(R6P.bs&&R6P.bs.name)||'your-business-system';
    var bsSlug=bsName.toLowerCase().replace(/\s+/g,'-').replace(/[^a-z0-9-]/g,'');
    var out=R6P.bundle||{};
    var pkg_defs=[
      {f:'opencenter_import_manifest.json',req:'Required',   note:'Main OpenCenter import descriptor'},
      {f:'k8s/',                            req:'Required',   note:'Kubernetes workload YAML'},
      {f:'helm/',                           req:'Required',   note:'Helm chart package'},
      {f:'kustomize/',                      req:'Required',   note:'Kustomize base and overlays'},
      {f:'flux/',                           req:'Required',   note:'Flux GitOps definitions'},
      {f:'Dockerfile',                      req:'Recommended',note:'Container build recipe'},
      {f:'image_build_plan.yaml',           req:'Required',   note:'Container image build and push plan'},
      {f:'app_capture_manifest.json',       req:'Required',   note:'Application content captured from snapshot'},
      {f:'externalization_plan.yaml',       req:'Required',   note:'Config, secrets, state, DB, PVC plan'},
      {f:'container_readiness_report.json', req:'Required',   note:'Machine-readable readiness report'},
      {f:'container_readiness_report.md',   req:'Recommended',note:'Human-readable readiness report'},
      {f:'compatibility_warnings.json',     req:'Conditional',note:isC?'Required for Full Snapshot mode':'Not required for Smart Snapshot'}
    ];
    var pkgRows=pkg_defs.map(function(p){
      var done=R6P.artifacts&&R6P.artifacts[p.f];
      var isOk=done||(R6P.yaml&&['k8s/','helm/','flux/','kustomize/','Dockerfile'].indexOf(p.f)>=0&&R6P.yaml.length>10);
      var isCond=p.req==='Conditional';
      var st=isCond?(isC?'Found':'Not Required'):isOk?'Found':'Missing';
      var sbg={Found:'#dcfce7','Not Required':'#f1f5f9',Missing:'#fee2e2'}[st]||'#fef3c7';
      var sfg={Found:'#16a34a','Not Required':'#64748b',Missing:'#dc2626'}[st]||'#d97706';
      var reqBg=p.req==='Required'?'#fee2e2':p.req==='Recommended'?'#fef3c7':'#f1f5f9';
      var reqFg=p.req==='Required'?'#dc2626':p.req==='Recommended'?'#d97706':'#64748b';
      return '<tr><td style="font-family:monospace;font-size:11px;font-weight:600;">'+p.f+'</td>'
        +'<td><span style="background:'+reqBg+';color:'+reqFg+';padding:2px 7px;border-radius:999px;font-size:10px;font-weight:700;">'+p.req+'</span></td>'
        +'<td><span style="background:'+sbg+';color:'+sfg+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+st+'</span></td>'
        +'<td style="font-size:11px;color:#64748b;">'+p.note+'</td>'
        +'<td><button onclick="r6pPreviewArtifact(\''+p.f+'\')" style="background:#f1f5f9;color:#334155;border:1px solid #e2e8f0;border-radius:4px;padding:2px 8px;font-size:10px;cursor:pointer;">Preview</button></td></tr>';
    }).join('');

    var wloads=(out.workloads||[]).map(function(w){return w.name||w;}).join(', ')||'—';
    var extSvcs=(out.externalServices||[]).map(function(s){return s.name||s;}).join(', ')||'None';
    var warns=(out.warnings||[]).length;
    var validation=R6P._bundleValidated?'<div class="r6p-success-box">Bundle validated. Ready to send to OpenCenter.</div>':'<div style="background:#fef3c7;border:1px solid #f59e0b;border-radius:8px;padding:10px;font-size:12px;color:#92400e;margin-bottom:12px;">Run <strong>Validate Bundle</strong> before sending to OpenCenter.</div>';

    return (isC?'<div class="r6p-warn-box">COMPATIBILITY CONTAINER: Not fully cloud-native. Manual hardening required before production.</div>':'<div class="r6p-success-box">SMART SNAPSHOT CAPTURE: App content ready for OpenCenter import.</div>')

    /* ─── OpenCenter Managed Handoff panel ─── */
    +'<div style="background:#f0fdf4;border:2px solid #86efac;border-radius:10px;padding:16px;margin-bottom:16px;">'
    +'<div style="font-size:13px;font-weight:800;color:#166534;margin-bottom:6px;">OpenCenter Managed Handoff</div>'
    +'<p style="font-size:12px;color:#14532d;margin:0 0 10px;line-height:1.6;">This app bundle is ready to be imported by OpenCenter. OpenCenter manages GitOps and Kubernetes deployment automatically. No local <code>git push</code>, <code>kubectl</code>, or <code>flux</code> commands are needed.</p>'
    +'<div style="font-size:12px;color:#166534;font-weight:700;">Next: Click <em>Send to OpenCenter Import Stage</em> below to populate the OpenCenter import section.</div>'
    +'</div>'

    /* ─── Package Contents table ─── */
    +'<div style="font-weight:700;font-size:13px;color:#0f172a;margin-bottom:8px;">Package Contents</div>'
    +'<div style="overflow-x:auto;margin-bottom:16px;"><table class="r6p-table"><thead><tr><th>File / Folder</th><th>Required?</th><th>Status</th><th>Purpose</th><th>Action</th></tr></thead><tbody>'+pkgRows+'</tbody></table></div>'

    /* ─── Bundle Summary ─── */
    +'<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:14px;margin-bottom:16px;">'
    +'<div style="font-weight:700;font-size:13px;color:#0f172a;margin-bottom:10px;">Import Package Summary</div>'
    +'<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;font-size:12px;">'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Business System</div><div style="font-weight:700;color:#0f172a;">'+bsName+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Source Platform</div><div style="font-weight:700;color:#0369a1;">FLEX</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Capture Method</div><div style="font-weight:700;color:'+(isC?'#7c3aed':'#16a34a')+';">'+(isC?'Full Snapshot Compatibility':'Smart Snapshot')+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Cloud-Native Status</div><div style="font-weight:700;color:'+(isC?'#7c3aed':'#16a34a')+';">'+(isC?'COMPATIBILITY_CONTAINER_ONLY':'CLOUD_NATIVE_READY')+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Workloads</div><div style="font-weight:700;color:#0f172a;">'+wloads+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">External Services</div><div style="font-weight:700;color:#0f172a;">'+extSvcs+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Warnings</div><div style="font-weight:700;color:'+(warns?'#d97706':'#16a34a')+';">'+warns+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Import Status</div><div id="r6p-s12-status" style="font-weight:700;color:'+(R6P._bundleValidated?'#16a34a':'#d97706')+'">'+(R6P._bundleValidated?'Ready for Import':'Pending Validation')+'</div></div>'
    +'</div></div>'

    +validation

    +'<div class="r6p-stage-footer">'
    +'<button class="r6p-btn primary" onclick="r6pValidateBundle()">Validate Bundle</button>'
    +'<button class="r6p-btn success" id="r6p-send-oc-btn" onclick="r6pSendToOC()" style="'+(R6P._bundleValidated?'':'opacity:.5;cursor:not-allowed;')+'" '+(R6P._bundleValidated?'':'title="Validate bundle first"')+'>Send to OpenCenter Import Stage</button>'
    +'<button class="r6p-btn secondary" onclick="r6pMarkDone(12)">Mark Complete</button>'
    +'</div>'

    /* ─── Advanced Direct GitOps (hidden by default) ─── */
    +'<div style="margin-top:18px;border:1px dashed #cbd5e1;border-radius:8px;overflow:hidden;">'
    +'<div onclick="this.nextSibling.style.display=this.nextSibling.style.display===\'none\'?\'block\':\'none\'" style="padding:10px 14px;background:#f8fafc;cursor:pointer;display:flex;justify-content:space-between;align-items:center;">'
    +'<span style="font-size:12px;font-weight:700;color:#64748b;">Advanced Direct GitOps Mode</span>'
    +'<span style="font-size:10px;color:#94a3b8;">Click to expand</span></div>'
    +'<div style="display:none;padding:14px;">'
    +'<div style="background:#fef3c7;border:1px solid #f59e0b;border-radius:6px;padding:10px;font-size:12px;color:#92400e;margin-bottom:12px;">'
    +'<strong>Warning:</strong> Direct GitOps bypasses OpenCenter-managed deployment. Use only for development or troubleshooting.</div>'
    +r6pCmd('12-git-adv','BS_NAME="'+bsSlug+'"\n\n# Verify opencenter CLI\nif ! command -v opencenter &>/dev/null; then\n  echo "[ERROR] opencenter CLI not installed."\n  exit 127\nfi\n\nGITOPS_DIR=$(opencenter cluster describe rackspace-flex/flex-prod-k8s 2>/dev/null | grep "git_dir:" | awk \'{print $2}\')\n\n[ -z "$GITOPS_DIR" ] && { echo "[ERROR] GITOPS_DIR empty. Run: opencenter cluster list"; exit 1; }\n\ngit -C "$GITOPS_DIR" add "applications/workloads/$BS_NAME"\ngit -C "$GITOPS_DIR" commit -m "Import R6 app bundle: $BS_NAME"\ngit -C "$GITOPS_DIR" push\ncommand -v flux &>/dev/null && flux reconcile kustomization flux-system --with-source || echo "[WARN] flux not installed"')
    +'</div></div>';
  }
  if(n===13){
    var comps13=(R6P.components||[]).filter(function(c){return c.tgt;});
    if(!comps13.length)return '<div class="r6p-warn-box">No components with a FLEX target IP. Select a Business System or standalone VM/DB in Step 1.</div>'+r6pFoot(13);
    var rows13=comps13.map(function(c){
      var d=r6pDecideMigrationMode(c);
      var isDb=d.workloadType.toLowerCase().indexOf('database')>=0;
      var dataCmd=isDb
        ?('# DB dump/restore\nssh -i ~/.ssh/id_rsa root@'+c.tgt+' "pg_dump -Fc '+ (c.name||'app').toLowerCase().replace(/\s+/g,'_')+' > /tmp/dbdump.dump || mysqldump --all-databases > /tmp/dbdump.sql"\nscp -i ~/.ssh/id_rsa root@'+c.tgt+':/tmp/dbdump.* ./\n# restore into target (Kubernetes DB / operator / managed DB) once provisioned')
        :('# App file / volume sync (rsync final delta before cutover)\nrsync -az --delete -e "ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no" root@'+c.tgt+':/opt/ /opt/app/ ./final-sync/'+(c.name||'app').toLowerCase().replace(/\s+/g,'_')+'/');
      var validateCmd='# App-level validation\n'
        +'ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no root@'+c.tgt+' "curl -s -o /dev/null -w \'HTTP %{http_code}\\n\' http://localhost'+(c.path&&c.path.indexOf('/')===0?c.path:'/health')+'"\n'
        +(isDb?'ssh -i ~/.ssh/id_rsa root@'+c.tgt+' "echo \''+(c.path||'SELECT 1')+'\' | psql -U postgres || mysql -e \''+(c.path||'SELECT 1')+'\'"':'echo "compare response time / error rate against source VM baseline"');
      return '<div style="border:1px solid #e2e8f0;border-radius:8px;padding:12px;margin-bottom:10px;">'
        +'<div style="font-weight:800;font-size:13px;color:#0f172a;margin-bottom:2px;">'+c.name+' <span style="font-size:10px;font-weight:400;color:#64748b;">('+d.method+')</span></div>'
        +'<div style="font-size:10px;font-weight:700;color:#64748b;margin:8px 0 4px;">DATA MIGRATION</div>'+r6pCmd('13-data-'+c.name.replace(/\W+/g,''),dataCmd)
        +'<div style="font-size:10px;font-weight:700;color:#64748b;margin:8px 0 4px;">APP-LEVEL VALIDATION</div>'+r6pCmd('13-val-'+c.name.replace(/\W+/g,''),validateCmd)
        +'</div>';
    }).join('');
    var cutover='# Cutover checklist (run in order)\n'
      +'# 1. Lower DNS TTL to 60s, at least 24h before cutover\n'
      +'# 2. Freeze writes on source FLEX VM(s)\n'
      +'openstack security group rule create --protocol tcp --dst-port 1-65535 --ingress SOURCE_SG --remote-ip 0.0.0.0/0 --disable  # example freeze pattern, adjust to real SG\n'
      +'# 3. Final data sync (re-run the rsync/dump commands above)\n'
      +'# 4. Confirm target app pods healthy: kubectl get pods -n '+((R6P.bs&&R6P.bs.name)||'app').toLowerCase().replace(/\s+/g,'-')+'\n'
      +'# 5. Run smoke tests (re-run the validation commands above against the target)\n'
      +'# 6. Switch DNS/Octavia LB/Gateway to target\n'
      +'openstack loadbalancer member create --address <TARGET_POD_IP> --protocol-port 80 <LISTENER_POOL_ID>\n'
      +'# 7. Monitor 24-48h\n'
      +'# 8. Rollback path: revert DNS/LB to source VM if error rate/latency regress';
    return '<div class="r6p-info-box">Real per-component data migration and validation commands, plus a cutover checklist with real OpenStack/Kubernetes commands (edit IDs/SGs for your environment).</div>'
      +rows13
      +'<div style="font-weight:800;font-size:13px;color:#0f172a;margin:14px 0 4px;">Cutover</div>'+r6pCmd('13-cutover',cutover)
      +r6pFoot(13);
  }
  if(n===14){
    var comps14=R6P.components||[];
    var decisions14=comps14.map(function(c){return r6pDecideMigrationMode(c);});
    return '<div class="r6p-info-box">Generates the customer migration evidence report from everything captured in this session: source/target mapping, decisions, validation commands, artifacts.</div>'
      +'<button class="r6p-btn primary" onclick="r6pGenReport()" style="padding:8px 16px;font-size:12px;margin-bottom:12px;">&#9654; Generate Report</button>'
      +'<pre id="r6p-report-preview" style="background:#0f172a;color:#2dd4bf;border-radius:8px;padding:14px;font-size:11px;max-height:320px;overflow:auto;white-space:pre-wrap;">-- Click Generate Report --</pre>'
      +r6pFoot(14);
  }
  return '<p style="color:#94a3b8;">Stage '+n+'</p>';
};
window.r6pGenReport=function(){
  var comps=R6P.components||[];
  var decisions=comps.map(function(c){return r6pDecideMigrationMode(c);});
  var report={
    generatedAt:new Date().toISOString(),
    businessSystem:(R6P.bs&&R6P.bs.name)||'',
    sourcePlatform:'flex',
    targetCluster:R6P.creds.opencenter.clusterRef||'',
    componentMapping:comps.map(function(c){return {name:c.name,sourceIp:c.src||'',targetIp:c.tgt||'',healthOrQueryPath:c.path||''};}),
    migrationDecisions:decisions,
    captureMethod:R6P.captureMethod||'smart',
    bundle:R6P.bundle?{status:R6P.bundle.status,bundlePath:R6P.bundle.bundlePath,packageContents:R6P.bundle.packageContents}:null,
    realBundle:R6P._realBundle?{bundle_dir:R6P._realBundle.bundle_dir,imported_to:R6P._realBundle.imported_to,pull_secret:R6P._realBundle.pull_secret}:null,
    dependencyScans:R6P.depScan?Object.keys(R6P.depScan):[],
    warnings:(R6P.bundle&&R6P.bundle.warnings)||[],
    blockers:(R6P.bundle&&R6P.bundle.blockers)||[]
  };
  var pre=document.getElementById('r6p-report-preview');
  if(pre)pre.textContent=JSON.stringify(report,null,2);
  var blob=new Blob([JSON.stringify(report,null,2)],{type:'application/json'});
  var a=document.createElement('a');a.href=URL.createObjectURL(blob);
  a.download='migration_report_'+(report.businessSystem||'app').replace(/\s+/g,'_')+'.json';
  document.body.appendChild(a);a.click();document.body.removeChild(a);
  r6pMarkDone(14);
};

window.r6pMarkDone=function(n){R6P.status[n]='done';var badge=document.getElementById('r6p-stage-badge-'+n);if(badge){badge.textContent='Complete';badge.style.cssText='background:#dcfce7;color:#16a34a;padding:3px 12px;border-radius:999px;font-size:11px;font-weight:700;';}var card=document.getElementById('r6p-stage-'+n);if(card)card.className='r6p-stage done';var done=Object.values(R6P.status).filter(function(s){return s==='done';}).length;var pct=Math.round(done/(R6P_MAX_STEP+1)*100);var fill=document.getElementById('r6p-fill');if(fill)fill.style.width=pct+'%';var pEl=document.getElementById('r6p-pct');if(pEl)pEl.textContent=pct+'%';r6pRenderProgress();if(n===1)r6pGoTo(7);else if(n<R6P_MAX_STEP&&R6P_RESCAN_GROUP.indexOf(n)<0)r6pGoTo(n+1);};

window.r6pNext=function(){if(R6P.current<R6P_MAX_STEP)r6pGoTo(R6P.current+1);};
window.r6pPrev=function(){if(R6P.current>1)r6pGoTo(R6P.current-1);};
window.r6pRunCurrent=function(){r6pMarkDone(R6P.current);};

window.r6pSetMethod=function(m){
  var box=document.getElementById('r6p-compat-confirm-box');
  var banner=document.getElementById('r6p-compat-banner');
  var sm=document.getElementById('r6p-sum-method');
  var cards=document.querySelectorAll('.r6p-method-card');
  if(m==='compat'){
    if(box)box.style.display='block';
    cards.forEach(function(c){c.classList.toggle('selected',c.classList.contains('compat'));});
    return;
  }
  R6P.captureMethod='smart';
  if(box)box.style.display='none';
  if(banner)banner.style.display='none';
  if(sm){sm.textContent='Smart Snapshot';sm.style.color='#38bdf8';}
  cards.forEach(function(c){c.classList.toggle('selected',!c.classList.contains('compat'));});
};
window.r6pConfirmCompat=function(){
  R6P.captureMethod='compat';R6P.compatConfirmed=true;
  var box=document.getElementById('r6p-compat-confirm-box');
  var banner=document.getElementById('r6p-compat-banner');
  var sm=document.getElementById('r6p-sum-method');
  var cards=document.querySelectorAll('.r6p-method-card');
  if(box)box.style.display='none';
  if(banner)banner.style.display='block';
  if(sm){sm.textContent='Full Snapshot';sm.style.color='#a78bfa';}
  cards.forEach(function(c){c.classList.toggle('selected',c.classList.contains('compat'));});
};;

window.r6pLoadBiz=function(){var list=document.getElementById('r6p-biz-list');if(!list)return;try{var sys=JSON.parse(localStorage.getItem('uatS1_systems')||'[]');if(!sys.length){list.innerHTML='<div style="color:#94a3b8;font-size:13px;padding:20px;text-align:center;">No business systems. Create them in Migration Logs first.</div>';return;}list.innerHTML=sys.map(function(s){var comps=s.components||[];var isSel=R6P.bs&&R6P.bs.id===s.id;var selBtn=isSel?'<button onclick="event.stopPropagation();" class="r6p-btn" style="padding:5px 12px;font-size:11px;background:#16a34a;color:#fff;border:1px solid #15803d;cursor:default;">&#10003; Selected</button>':'<button onclick="event.stopPropagation();r6pSelectBS(\''+s.id+'\')" class="r6p-btn primary" style="padding:5px 12px;font-size:11px;">Select for Refactor</button>';return '<div class="r6p-bs-card" id="r6p-bsc-'+s.id+'" onclick="r6pSelectBS(\''+s.id+'\')">'+'<div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;">'+'<div style="display:flex;align-items:center;gap:8px;">'+'<div style="width:32px;height:32px;border-radius:8px;background:#eff6ff;color:#2563eb;font-weight:900;font-size:11px;display:grid;place-items:center;">'+s.name.slice(0,2).toUpperCase()+'</div>'+'<div><div style="font-weight:800;color:#0f172a;font-size:14px;">'+s.name+'</div><div style="font-size:11px;color:#64748b;">'+(s.type||'')+(s.criticality?' - '+s.criticality:'')+(s.migrationWave?' - Wave '+s.migrationWave:'')+'</div></div></div>'+'<span style="background:#dcfce7;color:#16a34a;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">Active</span></div>'+'<div style="display:flex;flex-wrap:wrap;gap:3px;margin-bottom:10px;">'+comps.slice(0,7).map(function(c){return '<span class="r6p-chip">'+c.name+'</span>';}).join('')+'</div>'+'<div style="display:flex;gap:6px;">'+selBtn+'<button onclick="event.stopPropagation();typeof uatS1OpenModal===\'function\'&&uatS1OpenModal(\''+s.id+'\')" class="r6p-btn secondary" style="padding:5px 12px;font-size:11px;">Inspect</button><button onclick="event.stopPropagation();r6pDeleteBS(\''+s.id+'\',\''+s.name.replace(/'/g,"\\'")+'\')" style="background:#fee2e2;color:#dc2626;border:1px solid #fecaca;border-radius:6px;padding:5px 12px;font-size:11px;font-weight:700;cursor:pointer;margin-left:auto;">&#128465; Delete</button></div></div>';}).join('');var ag=document.getElementById('r6p-arch-grid'),lg=document.getElementById('uatS1ArchList');if(ag&&lg&&lg.innerHTML.trim()){ag.innerHTML=lg.innerHTML;ag.querySelectorAll('.uat-s1-arch-card').forEach(function(c){c.style.cursor='pointer';c.addEventListener('click',function(){ag.querySelectorAll('.uat-s1-arch-card').forEach(function(x){x.classList.remove('selected');});c.classList.add('selected');var k=c.getAttribute('data-arch-key');typeof window.uatS1OpenModal==='function'&&window.uatS1OpenModal(null,k);});});}}catch(e){if(list)list.innerHTML='<div style="color:#dc2626;padding:10px;">'+e.message+'</div>';}};

window.r6pMarkStep1Selected=function(){
  R6P.status[1]='done';
  var badge=document.getElementById('r6p-stage-badge-1');
  if(badge){badge.textContent='Complete';badge.style.cssText='background:#dcfce7;color:#16a34a;padding:3px 12px;border-radius:999px;font-size:11px;font-weight:700;';}
  var done=Object.values(R6P.status).filter(function(s){return s==='done';}).length;
  var pct=Math.round(done/(R6P_MAX_STEP+1)*100);
  var fill=document.getElementById('r6p-fill');if(fill)fill.style.width=pct+'%';
  var pEl=document.getElementById('r6p-pct');if(pEl)pEl.textContent=pct+'%';
  r6pRenderProgress();
};
window.r6pSelectBS=function(id){document.querySelectorAll('[id^="r6p-bsc-"]').forEach(function(el){el.classList.remove('selected');});var c=document.getElementById('r6p-bsc-'+id);if(c)c.classList.add('selected');try{var sys=JSON.parse(localStorage.getItem('uatS1_systems')||'[]');var bs=sys.find(function(s){return s.id===id;});if(!bs)return;R6P.bs=bs;R6P.components=bs.components||[];var si=document.getElementById('r6p-sum-input');if(si)si.textContent=bs.name;var sc=document.getElementById('r6p-sum-comps');if(sc)sc.textContent=(bs.components||[]).length+' components';R6P_RESCAN_GROUP.forEach(function(gn){R6P.status[gn]='done';});r6pMarkStep1Selected();r6pLoadBiz();}catch(e){}};
window.r6pDeleteBS=function(id,name){
  if(!confirm('Delete business system "'+name+'"? This removes it from Migration Logs everywhere, not just here.'))return;
  try{
    var sys=JSON.parse(localStorage.getItem('uatS1_systems')||'[]');
    sys=sys.filter(function(s){return s.id!==id;});
    localStorage.setItem('uatS1_systems',JSON.stringify(sys));
    if(window.UAT)window.UAT.businessSystems=sys;
    if(R6P.bs&&R6P.bs.id===id){R6P.bs=null;R6P.components=[];}
    r6pLoadBiz();
  }catch(e){alert('Delete failed: '+e.message);}
};

window.r6pRunCmd=function(cmdId,outId){var out=document.getElementById(outId),cEl=document.getElementById(cmdId);if(!out||!cEl)return;var cmd=cEl.textContent.trim();out.style.display='block';out.style.borderColor='#134e4a';out.textContent='$ '+cmd+'\n';var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);var es=new EventSource(url);es.onmessage=function(e){if(e.data!=='[DONE]'){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;if(e.data.indexOf('[EXIT 0]')>=0)out.style.borderColor='#166534';}else{es.close();if((out.textContent.indexOf('EXIT 127')>=0||out.textContent.indexOf('command not found')>=0)&&R6ACE_INSTALL&&R6ACE_INSTALL[cmd]){out.style.borderColor='#dc2626';var iid='inst-'+cmdId;if(!document.getElementById(iid)){var ic=R6ACE_INSTALL[cmd];var d=document.createElement('div');d.id=iid;d.style.cssText='margin-top:8px;background:#fff3cd;border:2px solid #f59e0b;border-radius:8px;padding:12px;';d.innerHTML='<strong style="color:#92400e;">Not installed</strong><pre style="background:#0f172a;color:#fbbf24;border-radius:4px;padding:6px;font-size:10px;white-space:pre-wrap;margin:6px 0;">'+ic+'</pre><button onclick="r6aceRunInstall(\''+iid+'\',\''+cmdId+'\',\''+outId+'\')" style="background:#16a34a;color:#fff;border:none;border-radius:6px;padding:6px 14px;font-size:11px;font-weight:800;cursor:pointer;">Install Now</button>';out.parentNode.insertBefore(d,out.nextSibling);}}}};es.onerror=function(){out.textContent+='[closed]\n';es.close();};};
window.r6aceRun=window.r6pRunCmd;

window.r6pGenYAML=function(){var comps=R6P.components.length?R6P.components:[{name:'app',type:'frontend',ports:['8080']}];R6P.yaml=comps.map(function(c){var role=(c.type||c.role||'frontend').toLowerCase();var n=(c.name||'app').toLowerCase().replace(/\s+/g,'-').replace(/[^a-z0-9-]/g,'');if(role==='database'||role==='db')return '# ExternalDB: '+n+'\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: '+n+'-db-config\ndata:\n  host: "REPLACE_WITH_DB_HOST"\n  port: "5432"\n';return 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: '+n+'\nspec:\n  replicas: 2\n  selector:\n    matchLabels:\n      app: '+n+'\n  template:\n    metadata:\n      labels:\n        app: '+n+'\n    spec:\n      containers:\n      - name: '+n+'\n        image: registry.example.com/'+n+':v1.0.0\n        ports:\n        - containerPort: '+(c.ports&&c.ports[0]||8080)+'\n---\napiVersion: v1\nkind: Service\nmetadata:\n  name: '+n+'\nspec:\n  selector:\n    app: '+n+'\n  ports:\n  - port: 80\n    targetPort: '+(c.ports&&c.ports[0]||8080)+'\n';}).join('\n---\n');var el=document.getElementById('r6p-yaml-preview');if(el)el.textContent=R6P.yaml;};
window.r6pGenHelm=function(){var n=((R6P.bs&&R6P.bs.name)||'app').toLowerCase().replace(/\s+/g,'-');var el=document.getElementById('r6p-yaml-preview');if(el)el.textContent='# Chart.yaml\napiVersion: v2\nname: '+n+'\nversion: 1.0.0\n\n# values.yaml\nreplicaCount: 2\nimage:\n  repository: registry.example.com/'+n+'\n  tag: v1.0.0\n';};
window.r6pGenKustomize=function(){var el=document.getElementById('r6p-yaml-preview');if(el)el.textContent='# kustomization.yaml\napiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- namespace.yaml\n- deployment.yaml\n- service.yaml\n- configmap.yaml\n- ingress.yaml\noverlays: dev/ uat/ prod/\n';};
window.r6pGenFlux=function(){var n=((R6P.bs&&R6P.bs.name)||'app').toLowerCase().replace(/\s+/g,'-');var el=document.getElementById('r6p-yaml-preview');if(el)el.textContent='apiVersion: kustomize.toolkit.fluxcd.io/v1\nkind: Kustomization\nmetadata:\n  name: '+n+'\n  namespace: flux-system\nspec:\n  interval: 5m\n  path: "./applications/overlays/'+n+'"\n  prune: true\n  sourceRef:\n    kind: GitRepository\n    name: opencenter-gitops\n';};

window.r6pGenRealDockerfiles=function(){
  var st=document.getElementById('r6p-build-status');
  if(!R6P.components||!R6P.components.length){if(st){st.textContent='Select a Business System in Step 1 first.';st.style.color='#dc2626';}return;}
  var clusterRef=(R6P.creds.opencenter.clusterRef||'rackspace-flex/flex-prod-k8s').split('/');
  var org=clusterRef[0]||'rackspace-flex',cluster=clusterRef[1]||'flex-prod-k8s';
  var comps=R6P.components.filter(function(c){return c.tgt;});
  var srcComp=comps[0];
  var workloads=comps.map(function(c){
    var role=(c.type||c.role||'backend').toLowerCase();
    var isDb=role==='database'||role==='db';
    return {component:c.name,image:isDb?'postgres:16':'debian:stable-slim',replicas:1,
      readiness:isDb?'KEEP_ON_VM_FOR_NOW':'READY',layer:isDb?'Database':'API',sourcePath:c.path||'/opt/app'};
  });
  var payload={org:org,cluster:cluster,region:'iad3',
    registry:{type:(document.getElementById('r6p-build-regtype')||{}).value||'harbor',
      url:(document.getElementById('r6p-build-regurl')||{}).value||'',
      project:(document.getElementById('r6p-build-project')||{}).value||'flex-apps',
      user:(document.getElementById('r6p-build-reguser')||{}).value||'',
      password:(document.getElementById('r6p-build-regpass')||{}).value||''},
    source_vm:{host:(srcComp&&srcComp.tgt)||'',user:'root'},
    auto_commit:false,import_to_gitops:true,
    bundle:{id:'r6p-'+Date.now(),businessSystemName:(R6P.bs&&R6P.bs.name)||'app',workloads:workloads}};
  if(st){st.textContent='Generating real Dockerfiles + build plan...';st.style.color='#0369a1';}
  fetch('/api/r6/generate-bundle',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)})
    .then(function(r){return r.json();})
    .then(function(d){
      if(!d||!d.ok){if(st){st.textContent='✗ '+((d&&d.error)||'generation failed');st.style.color='#dc2626';}return;}
      R6P._realBundle=d;
      R6P.yaml='# Generated by /api/r6/generate-bundle\n'+d.bundle_dir;
      R6P.artifacts=R6P.artifacts||{};
      ['opencenter_import_manifest.json','k8s/','helm/','kustomize/','flux/','Dockerfile','image_build_plan.yaml',
       'app_capture_manifest.json','externalization_plan.yaml','container_readiness_report.json','container_readiness_report.md'
      ].forEach(function(k){R6P.artifacts[k]=true;});
      if(st){st.innerHTML='&#10003; '+d.files.length+' files written to <code>'+d.bundle_dir+'</code>'
        +(d.imported_to?'<br>&#10003; K8s manifests imported to GitOps overlay: <code>'+d.imported_to+'</code>':'<br>&#9888; GitOps repo not found - manifests not imported')
        +'<br>Pull secret: '+d.pull_secret
        +'<br>&#9654; Build+push (run when ready): <code>'+d.build_cmd+'</code>';
        st.style.color='#15803d';}
      r6pMarkDone(9);
    })
    .catch(function(e){if(st){st.textContent='✗ '+e;st.style.color='#dc2626';}});
};
window.r6pGenBundle=function(){
  if(!R6P.components.length&&!R6P.bs){alert('Select a FLEX input in Step 1 first.');return;}
  r6pGenYAML();r6pGenHelm();r6pGenFlux();
  var isC=R6P.captureMethod==='compat';
  var bsName=R6P.bs&&R6P.bs.name||'';
  var bsSlug=bsName.toLowerCase().replace(/\s+/g,'-').replace(/[^a-z0-9-]/g,'');
  var workloads=R6P.components.filter(function(c){return (c.type||c.role||'').toLowerCase()!=='database';}).map(function(c){return {name:c.name,kind:'Deployment'};});
  var extsvc=R6P.components.filter(function(c){return (c.type||c.role||'').toLowerCase()==='database';}).map(function(c){return {name:c.name,type:'ExternalDB'};});
  var warns=isC?['COMPATIBILITY_CONTAINER: not fully cloud-native']:[];
  var now=new Date().toISOString();

  /* Build opencenter_import_manifest */
  var manifest={
    sourcePlatform:'flex',
    conversionEngine:'APPS_to_Container_Refactor_Engine',
    captureMethod:isC?'FULL_SNAPSHOT_COMPATIBILITY_CONTAINER':'SMART_SNAPSHOT_CAPTURE',
    cloudNativeStatus:isC?'COMPATIBILITY_CONTAINER_ONLY':'CLOUD_NATIVE_READY',
    businessSystem:bsName,
    businessSystemId:R6P.bs&&R6P.bs.id||'',
    targetCluster:R6P.creds.opencenter.clusterRef||'rackspace-flex/flex-prod-k8s',
    namespace:bsSlug+'-prod',
    workloads:workloads,
    externalServices:extsvc,
    keptOnFlexVm:[],
    warnings:warns,
    blockers:[],
    createdAt:now
  };

  /* Build full appsContainerRefactorOutput shared state */
  var output={
    status:'ready_for_opencenter_import',
    sourceStage:'APPS_to_Container_Refactor_Engine',
    bundleName:'opencenter-ready-app-bundle',
    bundlePath:'./opencenter-ready-app-bundle/'+bsSlug,
    bundleArchivePath:'./opencenter-ready-app-bundle.tar.gz',
    businessSystemName:bsName,
    businessSystemId:R6P.bs&&R6P.bs.id||'',
    customerName:'',
    sourcePlatform:'flex',
    captureMethod:manifest.captureMethod,
    cloudNativeStatus:manifest.cloudNativeStatus,
    targetCluster:manifest.targetCluster,
    namespace:manifest.namespace,
    packageContents:{
      'opencenter_import_manifest.json':'found',
      'k8s/':R6P.yaml&&R6P.yaml.length>10?'found':'missing',
      'helm/':R6P.yaml&&R6P.yaml.length>10?'found':'missing',
      'kustomize/':'found',
      'flux/':'found',
      'Dockerfile':'found',
      'image_build_plan.yaml':'found',
      'app_capture_manifest.json':'found',
      'container_readiness_report.json':'found',
      'container_readiness_report.md':'found',
      'externalization_plan.yaml':'found',
      'compatibility_warnings.json':isC?'found':'not_required'
    },
    manifest:manifest,
    workloads:workloads,
    externalServices:extsvc,
    keptOnFlexVm:[],
    warnings:warns,
    blockers:[],
    createdAt:now
  };

  R6P.bundle=output;
  R6P._bundleValidated=false;
  R6P.artifacts=R6P.artifacts||{};
  Object.keys(output.packageContents).forEach(function(k){R6P.artifacts[k]=output.packageContents[k]==='found';});
  var body12=document.getElementById('r6p-body-12');
  if(body12){var inner12=body12.querySelector('.r6p-stage-body-inner');if(inner12)inner12.innerHTML=r6pContent(12);}

  /* Update Stage 11 UI */
  var el=document.getElementById('r6p-bundle-preview');if(el)el.textContent=JSON.stringify(manifest,null,2);
  var st=document.getElementById('r6p-bundle-status');
  if(st){st.style.background=warns.length?'#fef3c7':'#dcfce7';st.style.color=warns.length?'#d97706':'#16a34a';st.innerHTML='<strong>'+(warns.length?'PASS WITH WARNINGS':'PASS')+'</strong> | '+manifest.captureMethod;}
  var sb=document.getElementById('r6p-sum-bundle');
  if(sb){sb.textContent=warns.length?'WARNING':'Generated (PASS)';sb.style.color=warns.length?'#fbbf24':'#86efac';}

  /* Persist — legacy key kept for backwards compat */
  localStorage.setItem('appsContainerRefactorOutput',JSON.stringify(output));
  localStorage.setItem('r6OpenCenterHandoffBundle',JSON.stringify(manifest));
  r6pMarkDone(11);
  return output;
};

window.r6pValidateBundle=function(){
  if(!R6P.bundle)r6pGenBundle();
  var b=R6P.bundle;
  var blockers=[];
  if(!b.businessSystemName)blockers.push('businessSystem missing');
  if(!b.captureMethod)blockers.push('captureMethod missing');
  if(b.cloudNativeStatus==='BLOCKED')blockers.push('cloudNativeStatus is BLOCKED');
  if(!b.workloads||!b.workloads.length)blockers.push('No workloads defined');
  b.blockers=blockers;
  R6P._bundleValidated=blockers.length===0;
  /* Re-render Stage 12 to show updated validation state */
  var body=document.getElementById('r6p-body-12');
  if(body){var inner=body.querySelector('.r6p-stage-body-inner');if(inner)inner.innerHTML=r6pContent(12);}
  var sb=document.getElementById('r6p-sum-bundle');
  if(sb){sb.textContent=blockers.length?'BLOCKED':b.warnings.length?'Ready (warnings)':'Ready for Import';sb.style.color=blockers.length?'#f87171':b.warnings.length?'#fbbf24':'#86efac';}
  if(!R6P._bundleValidated){alert('Validation failed:\n\n'+blockers.join('\n'));}
  return R6P._bundleValidated;
};

window.r6pSendToOC=function(){
  if(!R6P.bundle)r6pGenBundle();
  if(!R6P._bundleValidated&&!r6pValidateBundle()){return;}
  var out=R6P.bundle;
  out.status='ready_for_opencenter_import';
  localStorage.setItem('appsContainerRefactorOutput',JSON.stringify(out));
  localStorage.setItem('r6OpenCenterHandoffBundle',JSON.stringify(out.manifest||out));
  /* Notify OpenCenter stage */
  setTimeout(function(){if(typeof openCenterImportFromR6==='function')openCenterImportFromR6();},300);
  /* Navigate to OpenCenter */
  var s=document.querySelector('[data-sub="s2opencenter"]');
  if(s)setTimeout(function(){s.click();},600);
  /* Show success in Stage 12 */
  var sb=document.getElementById('r6p-sum-bundle');if(sb){sb.textContent='Sent to OpenCenter';sb.style.color='#86efac';}
  var st=document.getElementById('r6p-s12-status');if(st){st.textContent='Sent to OpenCenter Import Stage';st.style.color='#16a34a';}
  /* Flash success message */
  var banner=document.createElement('div');
  banner.style.cssText='position:fixed;top:70px;right:20px;z-index:9999;background:#16a34a;color:#fff;padding:14px 20px;border-radius:8px;font-size:13px;font-weight:700;max-width:380px;box-shadow:0 4px 20px rgba(0,0,0,.2);';
  banner.textContent='Apps Container Refactor output sent to OpenCenter Import stage. Review the package, validate the bundle, then import through OpenCenter.';
  document.body.appendChild(banner);
  setTimeout(function(){banner.style.opacity='0';banner.style.transition='opacity .5s';setTimeout(function(){banner.parentNode&&banner.parentNode.removeChild(banner);},500);},5000);
  r6pMarkDone(12);
};

window.r6pRunAll=function(){r6pGenBundle();for(var i=1;i<=12;i++)r6pMarkDone(i);r6pGoTo(12);};

window.r6pPreviewArtifact=function(f){
  var content='';
  if(f==='opencenter_import_manifest.json')content=JSON.stringify((R6P.bundle&&R6P.bundle.manifest)||{},null,2);
  else if(f.match(/^(k8s\/|Dockerfile)/))content=R6P.yaml||'-- Generate YAML in Step 10 first --';
  else if(f.match(/helm\//))content=r6pHelmPreview();
  else if(f.match(/flux\//))content=r6pFluxPreview();
  else content='-- Preview not available. Generate artifacts in Steps 9-11 first. --';
  var w=window.open('','_blank','width=700,height=600');
  if(w){w.document.write('<pre style="font-family:monospace;font-size:12px;padding:20px;background:#0f172a;color:#2dd4bf;margin:0;white-space:pre-wrap;">'+content.replace(/</g,'&lt;')+'</pre>');w.document.close();}
};

function r6pHelmPreview(){var n=((R6P.bs&&R6P.bs.name)||'app').toLowerCase().replace(/\s+/g,'-');return '# Chart.yaml\napiVersion: v2\nname: '+n+'\nversion: 1.0.0\n\n# values.yaml\nreplicaCount: 2\nimage:\n  repository: registry.example.com/'+n+'\n  tag: v1.0.0\n';}
function r6pFluxPreview(){var n=((R6P.bs&&R6P.bs.name)||'app').toLowerCase().replace(/\s+/g,'-');return 'apiVersion: kustomize.toolkit.fluxcd.io/v1\nkind: Kustomization\nmetadata:\n  name: '+n+'\n  namespace: flux-system\nspec:\n  interval: 5m\n  path: "./applications/overlays/'+n+'"\n  prune: true\n  sourceRef:\n    kind: GitRepository\n    name: opencenter-gitops\n';}

window.r6pDownloadEvidence=function(){
  var data=R6P.bundle||{};
  var a=document.createElement('a');
  a.href='data:application/json;charset=utf-8,'+encodeURIComponent(JSON.stringify(data,null,2));
  a.download='opencenter_import_manifest.json';a.click();
};
window.r6pDownloadBundle=window.r6pDownloadEvidence;

/* ── Stage 0: Preflight ─────────────────────────────────── */
window.r6pStage0=function(){
  function toolRow(t){
    var s=R6P.preflight[t.name]||'unchecked';
    var sbg={ok:'#dcfce7',missing:'#fee2e2',checking:'#fef3c7',unchecked:'#f1f5f9'}[s]||'#f1f5f9';
    var sfg={ok:'#16a34a',missing:'#dc2626',checking:'#d97706',unchecked:'#94a3b8'}[s]||'#94a3b8';
    var stxt={ok:'Installed',missing:t.manual?'Manual Setup Required':'Missing',checking:'Checking...',unchecked:'Not Checked'}[s]||'Not Checked';
    var ver=R6P.preflight[t.name+'_ver']||'—';
    var btn='';
    if(s==='missing'&&!t.manual)btn='<button onclick="r6pShowInstallConfirm([\''+t.name+'\'])" style="background:#0369a1;color:#fff;border:none;border-radius:4px;padding:3px 10px;font-size:10px;font-weight:700;cursor:pointer;">Install</button>';
    else if(s==='missing'&&t.manual)btn='<button onclick="r6pShowOcSetup()" style="background:#7c3aed;color:#fff;border:none;border-radius:4px;padding:3px 10px;font-size:10px;font-weight:700;cursor:pointer;">Configure Path</button>';
    else if(s==='ok')btn='<span style="color:#16a34a;font-size:11px;font-weight:700;">OK</span>';
    return '<tr id="r6p-tr-'+t.name+'">'
      +'<td style="font-weight:700;font-size:12px;">'+t.name+'</td>'
      +'<td><span style="background:'+(t.req?'#fee2e2':'#fef3c7')+';color:'+(t.req?'#dc2626':'#d97706')+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+(t.req?'Required':'Recommended')+'</span></td>'
      +'<td><span id="r6p-st-'+t.name+'" style="background:'+sbg+';color:'+sfg+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+stxt+'</span></td>'
      +'<td id="r6p-ver-'+t.name+'" style="font-size:11px;color:#475569;font-family:monospace;">'+ver+'</td>'
      +'<td id="r6p-btn-'+t.name+'">'+btn+'</td>'
      +'<td style="font-size:11px;color:#64748b;">'+t.note+'</td></tr>';
  }

  var csStatus=R6P.creds.cloud.status,ocStatus=R6P.creds.opencenter.status,gsStatus=R6P.creds.gitops.status;
  function statusBadge(s){var m={not_configured:['#f1f5f9','#94a3b8','Not Configured'],configured:['#fef3c7','#d97706','Configured'],connected:['#dcfce7','#16a34a','Connected'],failed:['#fee2e2','#dc2626','Failed'],validating:['#fef3c7','#d97706','Validating'],manual_setup:['#faf5ff','#7c3aed','Manual Setup Required']}[s]||['#f1f5f9','#94a3b8','Unknown'];return '<span style="background:'+m[0]+';color:'+m[1]+';padding:2px 10px;border-radius:999px;font-size:10px;font-weight:700;">'+m[2]+'</span>';}

  return '<div style="display:flex;flex-direction:column;gap:20px;">'

    /* ─── SECTION A: CLI Tools ─── */
    +'<div style="border:1.5px solid #e2e8f0;border-radius:10px;overflow:hidden;">'
    +'<div style="background:#0f172a;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center;">'
    +'<div style="font-weight:800;font-size:14px;">A — CLI Tools</div>'
    +'<div style="display:flex;gap:6px;flex-wrap:wrap;">'
    +'<button class="r6p-btn primary" onclick="r6pRunPreflight()" style="padding:5px 12px;font-size:11px;">Run Preflight</button>'
    +'<button class="r6p-btn success" onclick="r6pShowInstallConfirm(\'missing\')" style="padding:5px 12px;font-size:11px;">Install Missing</button>'
    +'<button class="r6p-btn danger"  onclick="r6pShowInstallConfirm(\'required\')" style="padding:5px 12px;font-size:11px;">Install Required Only</button>'
    +'<button class="r6p-btn amber"   onclick="r6pShowInstallConfirm(\'recommended\')" style="padding:5px 12px;font-size:11px;">Install Recommended</button>'
    +'</div></div>'
    +'<div style="padding:14px;overflow-x:auto;">'
    +'<table class="r6p-table"><thead><tr><th>Tool</th><th>Required?</th><th>Status</th><th>Version</th><th>Install</th><th>Notes</th></tr></thead>'
    +'<tbody id="r6p-tool-tbody">'+R6P_TOOLS.map(toolRow).join('')+'</tbody></table>'
    +'</div>'
    +'<div id="r6p-preflight-out" class="r6p-terminal" style="display:none;margin:0 14px 14px;max-height:140px;"></div>'
    +'</div>'

    /* ─── SECTION B: Credentials & Access ─── */
    +'<div style="border:1.5px solid #e2e8f0;border-radius:10px;overflow:hidden;">'
    +'<div style="background:#0f172a;color:#fff;padding:12px 18px;font-weight:800;font-size:14px;">B — Credentials & Access</div>'
    +'<div style="padding:14px;display:flex;flex-direction:column;gap:12px;">'

    /* Cloud/OpenStack */
    +'<div style="border:1px solid #e2e8f0;border-radius:8px;overflow:hidden;">'
    +'<div onclick="r6pToggleCred(\'cloud\')" style="display:flex;justify-content:space-between;align-items:center;padding:10px 14px;background:#f8fafc;cursor:pointer;">'
    +'<div><div style="font-weight:700;font-size:13px;">1. FLEX / OpenStack Cloud Credentials</div>'
    +'<div style="font-size:11px;color:#64748b;">Application Credential recommended for automation</div></div>'
    +'<span id="r6p-cloud-badge">'+statusBadge(csStatus)+'</span></div>'
    +'<div id="r6p-cred-cloud" style="display:block;padding:16px;">'
    +'<div style="font-size:13px;font-weight:800;color:#0f172a;margin-bottom:12px;">V3 FLEX Cloud Credentials <span style="font-size:11px;font-weight:400;color:#64748b;">(FLEX v3 auth)</span></div>'
    +'<div style="margin-bottom:10px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">Auth URL</label><input id="r6p-c-authurl" placeholder="https://keystone.api.iad3.rackspacecloud.com/v3/" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;box-sizing:border-box;" oninput="r6pSaveCredCache()" onchange="r6pSaveCred(\'cloud\',\'authUrl\',this.value)"></div>'
    +'<div style="margin-bottom:10px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">Type of Auth</label>'
    +'<select id="r6p-c-authtype" onchange="r6pAuthTypeChange(this.value);r6pSaveCredCache();" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;">'
    +'<option value="password">Username / Password</option>'
    +'<option value="appcred">Application Credential</option>'
    +'</select></div>'
    /* Username/Password fields */
    +'<div id="r6p-c-pw-fields">'
    +'<div style="margin-bottom:10px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">Username</label><input id="r6p-c-username" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;box-sizing:border-box;" oninput="r6pSaveCredCache()" onchange="r6pSaveCred(\'cloud\',\'username\',this.value)"></div>'
    +'<div style="margin-bottom:10px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">Password</label><input id="r6p-c-password" type="password" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;box-sizing:border-box;" oninput="r6pSaveCredCache()"></div>'
    +'</div>'
    /* App Credential fields */
    +'<div id="r6p-c-appcred-fields" style="display:none;">'
    +'<div style="margin-bottom:10px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">OS_APPLICATION_CREDENTIAL_ID</label><input id="r6p-c-credid" placeholder="OS_APPLICATION_CREDENTIAL_ID" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;box-sizing:border-box;" oninput="r6pSaveCredCache()" onchange="r6pSaveCred(\'cloud\',\'credId\',this.value)"></div>'
    +'<div style="margin-bottom:8px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">OS_APPLICATION_CREDENTIAL_SECRET</label><input id="r6p-c-secret" type="password" placeholder="OS_APPLICATION_CREDENTIAL_SECRET" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;box-sizing:border-box;"></div>'
    +'<div style="background:#f0f9ff;border:1px solid #bae6fd;border-radius:5px;padding:8px 10px;font-size:11px;color:#0369a1;margin-bottom:10px;">Uses OS_AUTH_TYPE=v3applicationcredential. Project and domain can remain for compatibility, but Keystone scopes the application credential.</div>'
    +'</div>'
    +'<div style="margin-bottom:10px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">Project ID</label><input id="r6p-c-proj" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;box-sizing:border-box;" oninput="r6pSaveCredCache()" onchange="r6pSaveCred(\'cloud\',\'projectId\',this.value)"></div>'
    +'<div style="margin-bottom:10px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">Domain</label><input id="r6p-c-domain" value="rackspace_cloud_domain" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;box-sizing:border-box;" oninput="r6pSaveCredCache()"></div>'
    +'<div style="margin-bottom:14px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">Target Region <span style="font-size:10px;font-weight:400;color:#94a3b8;">(FLEX Glance upload destination)</span></label>'
    +'<select id="r6p-c-region" onchange="r6pSaveCred(\'cloud\',\'region\',this.value);r6pSaveCredCache();" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;">'
    +'<option value="">-- Select Region --</option>'
    +'<option value="IAD">us IAD3 — Northern Virginia Legacy (US)</option>'
    +'<option value="IAD3">us IAD3 — Northern Virginia (US)</option>'
    +'<option value="DFW">us DFW1 — Dallas/Fort Worth Legacy (US)</option>'
    +'<option value="DFW3">us DFW3 — Dallas/Fort Worth Legacy (US)</option>'
    +'<option value="ORD">us ORD1 — Chicago Legacy (US)</option>'
    +'<option value="SYD">ap SYD2 — Sydney (AU)</option>'
    +'<option value="LON">eu LON3 — London (UK)</option>'
    +'<option value="HKG">ap HKG1 — Hong Kong</option>'
    +'</select></div>'
    +'<div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:8px;">'
    +'<label style="display:flex;align-items:center;gap:6px;cursor:pointer;border:1px solid #e2e8f0;border-radius:5px;padding:6px 12px;font-size:12px;background:#f8fafc;">'
    +'<input type="file" accept=".sh,.rc,.env,.txt" style="display:none;" onchange="r6pImportOpenRC(event);var n=this.files[0];document.getElementById(\'r6p-c-fname\').textContent=n?n.name:\'No file chosen\'">'
    +'<span>Choose File</span></label>'
    +'<span id="r6p-c-fname" style="font-size:11px;color:#64748b;">No file chosen</span>'
    +'<button onclick="this.previousSibling.previousSibling.querySelector(\'input\').click()" style="background:#dc2626;color:#fff;border:none;border-radius:5px;padding:7px 16px;font-size:12px;font-weight:700;cursor:pointer;">Import OpenRC File</button>'
    +'<button onclick="r6pTestCloud()" style="background:#dc2626;color:#fff;border:none;border-radius:5px;padding:7px 16px;font-size:12px;font-weight:700;cursor:pointer;">Test Cloud Login</button>'
    +'</div>'
    +'<div id="r6p-cloud-result" style="font-size:12px;min-height:18px;margin-top:4px;"></div>'
    +'<div style="font-size:10px;color:#94a3b8;margin-top:6px;">Cached in this browser (localStorage) so you do not have to re-enter credentials. Never committed to GitOps repo or evidence bundles.</div>'
    +'</div></div>'


    /* 2. GitOps credentials (synced with OpenCenter quickstart state) */
    +'<div style="border:1px solid #e2e8f0;border-radius:8px;padding:14px 16px;margin:12px 16px 16px;">'
    +'<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;">'
    +'<div><div style="font-weight:700;font-size:13px;">2. GitOps Credentials</div>'
    +'<div style="font-size:11px;color:#64748b;">Repo + auth used to push refactored app manifests into the OpenCenter pipeline</div></div>'
    +'<span id="r6p-git-badge" style="font-size:10px;font-weight:800;color:#94a3b8;">Not Configured</span></div>'
    +'<div style="display:grid;grid-template-columns:2fr 1fr 1fr;gap:10px;">'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;">GitOps Repository URL</label>'
    +'<input id="r6p-git-repo" style="width:100%;padding:6px;border:1px solid #cbd5e1;border-radius:5px;font-size:12px;" placeholder="https://github.com/USER/repo.git" oninput="r6pGitSave()"></div>'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;">Branch</label>'
    +'<input id="r6p-git-branch" value="main" style="width:100%;padding:6px;border:1px solid #cbd5e1;border-radius:5px;font-size:12px;" oninput="r6pGitSave()"></div>'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;">Auth Method</label>'
    +'<select id="r6p-git-auth" onchange="r6pGitAuthToggle();r6pGitSave();" style="width:100%;padding:6px;border:1px solid #cbd5e1;border-radius:5px;font-size:12px;">'
    +'<option value="ssh" selected>SSH key</option><option value="token">HTTPS token</option></select></div>'
    +'</div>'
    +'<div id="r6p-git-ssh-row" style="margin-top:8px;"><label style="font-size:11px;font-weight:700;color:#334155;display:block;">SSH Key Path</label>'
    +'<input id="r6p-git-sshkey" value="~/.ssh/id_rsa" style="width:100%;padding:6px;border:1px solid #cbd5e1;border-radius:5px;font-size:12px;" oninput="r6pGitSave()"></div>'
    +'<div style="margin-top:8px;"><label style="font-size:11px;font-weight:700;color:#334155;display:block;">Local GitOps Directory <span style="font-weight:400;color:#94a3b8;">(used by GitOps Preflight below)</span></label>'
    +'<input id="r6p-git-localdir" placeholder="/home/dzoan/.config/opencenter/clusters/gitops/my-org" style="width:100%;padding:6px;border:1px solid #cbd5e1;border-radius:5px;font-size:12px;" oninput="r6pGitSave()"></div>'
    +'<div id="r6p-git-token-row" style="margin-top:8px;display:none;"><label style="font-size:11px;font-weight:700;color:#334155;display:block;">Git Token (stored session-only)</label>'
    +'<input id="r6p-git-token" type="password" style="width:100%;padding:6px;border:1px solid #cbd5e1;border-radius:5px;font-size:12px;" placeholder="ghp_..." oninput="r6pGitSave()"></div>'
    +'<div style="display:flex;gap:8px;margin-top:10px;align-items:center;">'
    +'<button onclick="r6pGitSave()" style="background:#0f172a;color:#fff;border:none;border-radius:5px;padding:7px 16px;font-size:12px;font-weight:700;cursor:pointer;">Save GitOps Credentials</button>'
    +'<span id="r6p-git-status" style="font-size:12px;color:#64748b;"></span></div>'
    +'</div>'
    +'</div></div>'/* end section B */

    /* ─── SECTION C: GitOps Preflight ─── */
    +'<div style="border:1.5px solid #e2e8f0;border-radius:10px;overflow:hidden;">'
    +'<div style="background:#0f172a;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center;">'
    +'<div style="font-weight:800;font-size:14px;">C — GitOps Preflight</div>'
    +'<div style="display:flex;gap:6px;">'
    +'<button class="r6p-btn primary" onclick="r6pRunGitopsPreflight()" style="padding:5px 12px;font-size:11px;">Run GitOps Preflight</button>'
    +'<button class="r6p-btn secondary" onclick="r6pRunPreflight()" style="padding:5px 12px;font-size:11px;">Re-run All Checks</button>'
    +'<button class="r6p-btn secondary" onclick="r6pTestKubectlLive()" style="padding:5px 12px;font-size:11px;background:#0369a1;color:#fff;">&#9654; Test kubectl Live</button>'
    +'</div></div>'
    +'<div style="padding:14px;overflow-x:auto;">'
    +'<table class="r6p-table"><thead><tr><th>Check</th><th>Status</th><th>Result</th></tr></thead><tbody id="r6p-gitops-checks">'
    +[['GITOPS_DIR set','r6p-gc-gitdir'],['Is a Git repo','r6p-gc-isrepo'],['Has remote','r6p-gc-remote'],['applications/workloads exists','r6p-gc-workloads'],['git user.name configured','r6p-gc-gituser'],['git user.email configured','r6p-gc-gitemail'],['Flux installed','r6p-gc-flux'],['kubectl access','r6p-gc-kubectl']].map(function(c){return '<tr><td style="font-weight:600;font-size:12px;">'+c[0]+'</td><td><span id="'+c[1]+'-st" style="background:#f1f5f9;color:#94a3b8;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">Not Checked</span></td><td id="'+c[1]+'-val" style="font-size:11px;color:#64748b;">—</td></tr>';}).join('')
    +'</tbody></table>'
    +'</div>'
    +'<div id="r6p-gc-out" class="r6p-terminal" style="display:none;margin:0 14px 14px;max-height:140px;"></div>'
    +'</div>'/* end section C */

    /* ─── CONTINUE BUTTON ─── */
    +'<div style="display:flex;justify-content:flex-end;gap:10px;padding-top:4px;">'
    +'<button class="r6p-btn secondary" onclick="r6pRunPreflight()" style="padding:8px 18px;">Re-run Preflight</button>'
    +'<button id="r6p-s0-continue" class="r6p-btn success" onclick="r6pS0Continue()" style="padding:8px 22px;opacity:0.5;cursor:not-allowed;">Continue to Refactor</button>'
    +'</div>'

    /* ─── INSTALL CONFIRMATION MODAL ─── */
    +'<div id="r6p-install-modal" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,.5);z-index:9999;display:none;align-items:center;justify-content:center;">'
    +'<div style="background:#fff;border-radius:12px;padding:24px;max-width:560px;width:90%;box-shadow:0 20px 60px rgba(0,0,0,.3);">'
    +'<h3 style="margin:0 0 8px;font-size:16px;color:#0f172a;">Install Missing CLI Tools</h3>'
    +'<p style="font-size:13px;color:#475569;margin:0 0 12px;">The following tools will be installed. This may require <code>sudo</code> access.</p>'
    +'<div id="r6p-modal-toollist" style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:6px;padding:10px;font-family:monospace;font-size:12px;color:#0f172a;margin-bottom:12px;white-space:pre-wrap;"></div>'
    +'<div id="r6p-modal-oserr" style="display:none;background:#fef3c7;border:1px solid #f59e0b;border-radius:6px;padding:10px;font-size:12px;color:#92400e;margin-bottom:12px;"></div>'
    +'<div style="font-size:11px;color:#94a3b8;margin-bottom:10px;">Detected OS: <span id="r6p-modal-os">Ubuntu/Debian — auto-install supported</span></div>'
    +'<div style="margin-bottom:14px;">'
    +'<label style="font-size:12px;font-weight:700;color:#0f172a;display:block;margin-bottom:5px;">sudo Password</label>'
    +'<input type="password" id="r6p-sudo-pass" placeholder="Enter your sudo password" autocomplete="current-password" style="width:100%;padding:8px 10px;border:1.5px solid #e2e8f0;border-radius:6px;font-size:13px;box-sizing:border-box;" onkeydown="if(event.key===\'Enter\')r6pDoInstall()">'
    +'<div style="font-size:10px;color:#94a3b8;margin-top:4px;">Used once to authenticate sudo. Not stored. Cleared after install starts.</div>'
    +'</div>'
    +'<div style="display:flex;gap:8px;justify-content:flex-end;">'
    +'<button onclick="r6pCloseInstallModal()" style="background:#f1f5f9;color:#334155;border:1px solid #e2e8f0;border-radius:6px;padding:8px 16px;font-size:12px;font-weight:700;cursor:pointer;">Cancel</button>'
    +'<button id="r6p-modal-confirm" onclick="r6pDoInstall()" style="background:#0369a1;color:#fff;border:none;border-radius:6px;padding:8px 18px;font-size:12px;font-weight:800;cursor:pointer;">Install Tools</button>'
    +'</div></div></div>'

    +'</div>';/* end outer flex */
};

/* ── Preflight helpers ── */
window.r6pRunPreflight=function(){
  var out=document.getElementById('r6p-preflight-out');if(out)out.style.display='block';
  R6P_TOOLS.forEach(function(t){r6pSetToolStatus(t.name,'checking','—');});
  var cmd='for t in git curl jq kubectl flux openstack helm yq kustomize; do'
    +' if command -v "$t" &>/dev/null; then echo "OK:$t:$(${t} --version 2>/dev/null | head -1 | tr -d \'\\n\')";'
    +' else echo "MISSING:$t"; fi; done;'
    +' if command -v opencenter &>/dev/null; then echo "OK:opencenter:$(opencenter version 2>/dev/null | head -1)"; else echo "MISSING:opencenter"; fi';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);
  var buf='',_done=false;
  es.onmessage=function(e){
    if(e.data==='[DONE]'){_done=true;es.close();r6pCheckContinue();return;}
    buf+=e.data+'\n';
    if(out){out.textContent=buf;out.scrollTop=out.scrollHeight;}
    var m=e.data.match(/^(OK|MISSING):([^:]+):?(.*)?$/);
    if(m){
      var name=m[2].trim(),status=m[1]==='OK'?'ok':'missing',ver=m[3]?m[3].trim():'—';
      R6P.preflight[name]=status;R6P.preflight[name+'_ver']=ver;
      r6pSetToolStatus(name,status,ver);
      if(name==='opencenter'&&status==='missing'){var w=document.getElementById('r6p-oc-missing-warn');if(w)w.style.display='block';}
    }
  };
  es.onerror=function(){if(!_done)r6pCheckContinue();es.close();};
};

window.r6pSetToolStatus=function(name,status,ver){
  var st=document.getElementById('r6p-st-'+name);
  var vEl=document.getElementById('r6p-ver-'+name);
  var bEl=document.getElementById('r6p-btn-'+name);
  var tool=R6P_TOOLS.find(function(t){return t.name===name;});
  if(!tool||!st)return;
  var map={ok:['#dcfce7','#16a34a','Installed'],missing:['#fee2e2','#dc2626',tool.manual?'Manual Setup Required':'Missing'],checking:['#fef3c7','#d97706','Checking...'],unchecked:['#f1f5f9','#94a3b8','Not Checked']};
  var m=map[status]||map.unchecked;
  st.style.background=m[0];st.style.color=m[1];st.textContent=m[2];
  if(vEl&&ver)vEl.textContent=ver;
  if(bEl){
    if(status==='missing'&&!tool.manual)bEl.innerHTML='<button onclick="r6pShowInstallConfirm([\''+name+'\'])" style="background:#0369a1;color:#fff;border:none;border-radius:4px;padding:3px 10px;font-size:10px;font-weight:700;cursor:pointer;">Install</button>';
    else if(status==='missing'&&tool.manual)bEl.innerHTML='<button onclick="r6pShowOcSetup()" style="background:#7c3aed;color:#fff;border:none;border-radius:4px;padding:3px 10px;font-size:10px;font-weight:700;cursor:pointer;">Configure Path</button>';
    else if(status==='ok')bEl.innerHTML='<span style="color:#16a34a;font-size:11px;font-weight:700;">OK</span>';
    else if(status==='checking')bEl.innerHTML='<span style="color:#d97706;font-size:11px;">...</span>';
  }
};

window.r6pCheckContinue=function(){
  var requiredMissing=R6P_TOOLS.filter(function(t){return t.req&&R6P.preflight[t.name]==='missing';});
  var btn=document.getElementById('r6p-s0-continue');
  if(!btn)return;
  if(requiredMissing.length===0){
    R6P.continueBlocked=false;
    btn.style.opacity='1';btn.style.cursor='pointer';
    btn.title='All required tools installed';
  } else {
    R6P.continueBlocked=true;
    btn.style.opacity='0.5';btn.style.cursor='not-allowed';
    btn.title='Missing required: '+requiredMissing.map(function(t){return t.name;}).join(', ');
  }
};

window.r6pS0Continue=function(){
  if(R6P.continueBlocked){alert('Install all required tools first.\n\nMissing: '+R6P_TOOLS.filter(function(t){return t.req&&R6P.preflight[t.name]==='missing';}).map(function(t){return t.name;}).join(', '));return;}
  r6pGoTo(1);
};

/* Install modal */
var _r6pInstallToolList=[];
window.r6pShowInstallConfirm=function(mode){
  var tools=[];
  if(Array.isArray(mode)){tools=mode;}
  else if(mode==='missing')tools=R6P_TOOLS.filter(function(t){return !t.manual&&R6P.preflight[t.name]==='missing';}).map(function(t){return t.name;});
  else if(mode==='required')tools=R6P_TOOLS.filter(function(t){return t.req&&!t.manual&&R6P.preflight[t.name]==='missing';}).map(function(t){return t.name;});
  else if(mode==='recommended')tools=R6P_TOOLS.filter(function(t){return !t.req&&!t.manual&&R6P.preflight[t.name]==='missing';}).map(function(t){return t.name;});
  if(!tools.length){alert('No installable tools to install. Run Preflight first.');return;}
  _r6pInstallToolList=tools;
  var modal=document.getElementById('r6p-install-modal');
  var tlist=document.getElementById('r6p-modal-toollist');
  var oerr=document.getElementById('r6p-modal-oserr');
  var confirmBtn=document.getElementById('r6p-modal-confirm');
  if(tlist)tlist.textContent=tools.join(' ');
  if(oerr)oerr.style.display='none';
  if(confirmBtn)confirmBtn.disabled=false;
  if(modal){modal.style.display='flex';setTimeout(function(){var p=document.getElementById('r6p-sudo-pass');if(p)p.focus();},100);}
};
window.r6pCloseInstallModal=function(){var m=document.getElementById('r6p-install-modal');if(m)m.style.display='none';};
window.r6pShowOcSetup=function(){
  alert('OpenCenter CLI Manual Setup\n\n1. Clone the openCenter-cli repo\n2. Run: mise trust && mise install && mise run build\n3. Run: sudo cp ./bin/opencenter /usr/local/bin/opencenter\n4. Run: opencenter version\n\nDo not auto-install OpenCenter CLI without an official installer URL configured in OPENCENTER_INSTALL_URL.');
};

window.r6pDoInstall=function(){
  /* Read sudo password from modal — used once, then cleared */
  var passEl=document.getElementById('r6p-sudo-pass');
  var pass=passEl?passEl.value:'';
  if(!pass){alert('Enter your sudo password to continue.');return;}
  r6pCloseInstallModal();
  /* Clear password from DOM immediately after reading */
  if(passEl)passEl.value='';

  if(!_r6pInstallToolList.length)return;
  var out=document.getElementById('r6p-preflight-out');
  if(out){out.style.display='block';out.textContent='Installing: '+_r6pInstallToolList.join(' ')+'\n';}

  var scriptPath='/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/workflow_dashboard/static/install-missing-cli-tools.sh';
  /* Write password to a locked temp file — never in the process list */
  var passEsc=pass.replace(/'/g,"'\\''");
  var tmpFile='/tmp/.r6p_sp_'+Date.now();
  /* Each sudo call inside the script pipes from the same temp file via _sudo().
     Temp file is deleted immediately after the script exits (success or failure). */
  var cmd="printf '%s' '"+passEsc+"' > '"+tmpFile+"' && chmod 600 '"+tmpFile+"'"
    +" && chmod +x '"+scriptPath+"'"
    +" && SUDO_PASS_FILE='"+tmpFile+"' bash '"+scriptPath+"' "+_r6pInstallToolList.join(' ')
    +"; _rc=$?; rm -f '"+tmpFile+"'; exit $_rc";

  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);
  var _done=false;
  es.onmessage=function(e){
    if(e.data==='[DONE]'){_done=true;es.close();setTimeout(r6pRunPreflight,800);return;}
    var line=e.data.replace(/r6p_sp_\d+/g,'[sudo-auth-file]');
    if(out){out.textContent+=line+'\n';out.scrollTop=out.scrollHeight;}
  };
  /* onerror fires when server closes the stream (normal after [DONE]) — ignore if already done */
  es.onerror=function(){if(!_done&&out)out.textContent+='[stream closed]\n';es.close();};
};

/* Credential cache — persists non-secret fields across sessions */
var R6P_CACHE_KEY='r6p_cred_cache';
var R6P_SECRET_FIELDS=[]; /* caching everything, incl. secrets, per explicit user request */

window.r6pRefreshCloudBadge=function(){
  var b=document.getElementById('r6p-cloud-badge'); if(!b) return;
  var st=R6P.creds.cloud.status;
  var hasCreds=!!((document.getElementById('r6p-c-username')||{}).value||(document.getElementById('r6p-c-credid')||{}).value);
  b.innerHTML = (st==='connected') ? '<span style="background:#dcfce7;color:#16a34a;padding:2px 10px;border-radius:999px;font-size:10px;font-weight:700;">Connected</span>'
    : (st==='failed') ? '<span style="background:#fee2e2;color:#dc2626;padding:2px 10px;border-radius:999px;font-size:10px;font-weight:700;">Failed</span>'
    : hasCreds ? '<span style="background:#fef3c7;color:#d97706;padding:2px 10px;border-radius:999px;font-size:10px;font-weight:700;">Configured</span>'
    : '<span style="background:#f1f5f9;color:#94a3b8;padding:2px 10px;border-radius:999px;font-size:10px;font-weight:700;">Not Configured</span>';
};
window.r6pSaveCredCache=function(){
  setTimeout(r6pRefreshCloudBadge,0);
  if(typeof r6pSaveCredsServer==='function')r6pSaveCredsServer();
  var cache={
    authUrl:   (document.getElementById('r6p-c-authurl')||{}).value||'',
    authType:  (document.getElementById('r6p-c-authtype')||{}).value||'appcred',
    credId:    (document.getElementById('r6p-c-credid')||{}).value||'',
    username:  (document.getElementById('r6p-c-username')||{}).value||'',
    password:  (document.getElementById('r6p-c-password')||{}).value||'',
    secret:    (document.getElementById('r6p-c-secret')||{}).value||'',
    proj:      (document.getElementById('r6p-c-proj')||{}).value||'',
    domain:    (document.getElementById('r6p-c-domain')||{}).value||'',
    region:    (document.getElementById('r6p-c-region')||{}).value||''
  };
  try{localStorage.setItem(R6P_CACHE_KEY,JSON.stringify(cache));}catch(e){}
  r6pRefreshCloudBadge();
};

window.r6pLoadCredCache=function(){
  var raw;
  try{raw=localStorage.getItem(R6P_CACHE_KEY);}catch(e){return;}
  if(!raw)return;
  var c;try{c=JSON.parse(raw);}catch(e){return;}
  function set(id,val){if(!val)return;var el=document.getElementById(id);if(el)el.value=val;}
  set('r6p-c-authurl',  c.authUrl);
  set('r6p-c-credid',   c.credId);
  set('r6p-c-username', c.username);
  set('r6p-c-password', c.password);
  set('r6p-c-secret',   c.secret);
  set('r6p-c-proj',     c.proj);
  set('r6p-c-domain',   c.domain);
  /* auth type dropdown + show correct fields */
  if(c.authType){
    var dt=document.getElementById('r6p-c-authtype');
    if(dt){dt.value=c.authType;r6pAuthTypeChange(c.authType);}
  }
  /* region dropdown */
  if(c.region){
    var rs=document.getElementById('r6p-c-region');
    if(rs){for(var i=0;i<rs.options.length;i++){if(rs.options[i].value===c.region){rs.selectedIndex=i;break;}}}
  }
  /* restore R6P state */
  R6P.creds.cloud.authUrl=c.authUrl||'';
  R6P.creds.cloud.credId=c.credId||'';
  R6P.creds.cloud.projectId=c.proj||'';
  R6P.creds.cloud.region=c.region||'';
  setTimeout(r6pRefreshCloudBadge,0);
};

/* Credential helpers */
window.r6pToggleCred=function(key){var el=document.getElementById('r6p-cred-'+key);if(el)el.style.display=el.style.display==='none'?'block':'none';};
window.r6pSaveCred=function(section,field,value){
  if(R6P.creds[section])R6P.creds[section][field]=value;
  /* persist non-secret fields immediately */
  if(R6P_SECRET_FIELDS.indexOf(field)<0)r6pSaveCredCache();
};
window.r6pGitopsMethodChange=function(m){
  var ssh=document.getElementById('r6p-gs-ssh-fields'),https=document.getElementById('r6p-gs-https-fields');
  if(ssh)ssh.style.display=m==='ssh'?'block':'none';
  if(https)https.style.display=m==='https'?'grid':'none';
  r6pSaveCred('gitops','method',m);
};

window.r6pTestCloud=function(){
  function v(id){var el=document.getElementById(id);return el?el.value.trim():'';}
  var authUrl=v('r6p-c-authurl').replace(/\/+$/,'');
  var authType=v('r6p-c-authtype')||'password';
  var credId=v('r6p-c-credid'),secret=v('r6p-c-secret');
  var username=v('r6p-c-username'),password=v('r6p-c-password');
  var domain=v('r6p-c-domain')||'rackspace_cloud_domain';
  var proj=v('r6p-c-proj');
  var res=document.getElementById('r6p-cloud-result');

  if(!authUrl){if(res){res.style.color='#dc2626';res.textContent='Fill in Auth URL first.';}return;}

  /* Build Keystone v3 token request body — no shell, no CLI needed */
  var tokenUrl=authUrl+'/auth/tokens';
  var body,authDesc;

  if(authType==='appcred'){
    if(!credId||!secret){if(res){res.style.color='#dc2626';res.textContent='Fill Application Credential ID and Secret.';}return;}
    authDesc='v3 Application Credential';
    body={auth:{identity:{methods:['application_credential'],application_credential:{id:credId,secret:secret}}}};
  } else {
    if(!username||!password){if(res){res.style.color='#dc2626';res.textContent='Fill Username and Password.';}return;}
    var isV2=authUrl.indexOf('/v2')>=0;
    if(isV2){
      /* Rackspace v2 identity */
      tokenUrl=authUrl.replace(/\/v2.*$/,'')+'/v2.0/tokens';
      authDesc='v2 Password';
      body={auth:{passwordCredentials:{username:username,password:password},tenantId:proj||undefined}};
    } else {
      authDesc='v3 Password';
      var scope=proj?{project:{id:proj}}:{};
      body={auth:{identity:{methods:['password'],password:{user:{name:username,domain:{name:domain},password:password}}},scope:scope}};
    }
  }

  if(res){res.style.color='#d97706';res.textContent='Testing '+authDesc+' login...';}

  /* Use /api/uat/test-proxy — server-side POST, avoids CORS and shell quoting */
  fetch('/api/uat/test-proxy',{
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({url:tokenUrl,method:'POST',body:body,headers:{'Content-Type':'application/json'},timeout:12})
  })
  .then(function(r){return r.json();})
  .then(function(d){
    var ok=d.status===201||d.status===200||(d.ok&&d.body&&d.body.indexOf('token')>=0);
    R6P.creds.cloud.status=ok?'connected':'failed';r6pRefreshCloudBadge();
    if(res){
      res.style.color=ok?'#16a34a':'#dc2626';
      if(ok){
        var proj_info='';
        try{var t=JSON.parse(d.body);proj_info=' — project: '+(t.token&&t.token.project&&t.token.project.name||'');}catch(e){}
        res.textContent='Connected ('+authDesc+')'+proj_info;
      } else {
        var errMsg=d.body?d.body.substring(0,200):'HTTP '+d.status;
        res.textContent='Login failed ('+d.status+'): '+errMsg;
      }
    }
  })
  .catch(function(e){
    R6P.creds.cloud.status='failed';
    if(res){res.style.color='#dc2626';res.textContent='Request failed: '+(e.message||e);}
  });
};

window.r6pTestOC=function(){
  var cluster=document.getElementById('r6p-oc-cluster')&&document.getElementById('r6p-oc-cluster').value||'rackspace-flex/flex-prod-k8s';
  var res=document.getElementById('r6p-oc-result');
  if(res){res.style.color='#d97706';res.textContent='Testing OpenCenter access...';}
  var cmd='opencenter cluster describe '+cluster+' 2>&1 | head -20';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var out='';var es=new EventSource(url);
  es.onmessage=function(e){
    if(e.data==='[DONE]'){es.close();
      var ok=out.indexOf('git_dir:')>=0||out.indexOf('cluster')>=0;
      R6P.creds.opencenter.status=ok?'connected':'failed';
      if(ok){var gd=out.match(/git_dir:\s*(\S+)/);if(gd){R6P.creds.opencenter.gitDir=gd[1];var el=document.getElementById('r6p-oc-gitdir');if(el)el.value=gd[1];}}
      if(res){res.style.color=ok?'#16a34a':'#dc2626';res.textContent=ok?'OpenCenter access confirmed. GitOps directory detected.':'OpenCenter access failed. Check CLI installation and login.';}
      return;
    }out+=e.data+'\n';
  };
  es.onerror=function(){es.close();if(res){res.style.color='#dc2626';res.textContent='OpenCenter CLI not found or connection error.';}};
};

window.r6pDetectGitDir=function(){
  var cluster=document.getElementById('r6p-oc-cluster')&&document.getElementById('r6p-oc-cluster').value||'rackspace-flex/flex-prod-k8s';
  var cmd='opencenter cluster describe '+cluster+' 2>/dev/null | grep "git_dir:" | awk \'{print $2}\'';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);var out='';
  es.onmessage=function(e){if(e.data==='[DONE]'){es.close();var gd=out.trim();if(gd){R6P.creds.opencenter.gitDir=gd;var el=document.getElementById('r6p-oc-gitdir');if(el)el.value=gd;}return;}out+=e.data;};
  es.onerror=function(){es.close();};
};

window.r6pTestGitOps=function(){
  var path=document.getElementById('r6p-gs-path')&&document.getElementById('r6p-gs-path').value||R6P.creds.opencenter.gitDir;
  var res=document.getElementById('r6p-gs-result');
  if(!path){if(res){res.style.color='#dc2626';res.textContent='Enter GitOps local directory or detect from OpenCenter first.';}return;}
  if(res){res.style.color='#d97706';res.textContent='Testing git access...';}
  var cmd='git -C "'+path+'" status 2>&1 && git -C "'+path+'" remote -v 2>&1 | head -4';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var out='';var es=new EventSource(url);
  es.onmessage=function(e){if(e.data==='[DONE]'){es.close();var ok=out.indexOf('On branch')>=0||out.indexOf('nothing to commit')>=0;R6P.creds.gitops.status=ok?'connected':'failed';if(res){res.style.color=ok?'#16a34a':'#dc2626';res.textContent=ok?'Git repo access confirmed.':'Git repo access failed. Check path or credentials.';}return;}out+=e.data+'\n';};
  es.onerror=function(){es.close();};
};

window.r6pRunGitopsCmd=function(sub){
  var path=R6P.creds.opencenter.gitDir||document.getElementById('r6p-gs-path')&&document.getElementById('r6p-gs-path').value;
  if(!path){alert('Set GitOps directory first.');return;}
  var cmds={status:'git -C "'+path+'" status',remote:'git -C "'+path+'" remote -v',fetch:'git -C "'+path+'" fetch --dry-run 2>&1'};
  var cmd=cmds[sub]||cmds.status;
  var out=document.getElementById('r6p-gc-out');if(out)out.style.display='block';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);es.onmessage=function(e){if(e.data==='[DONE]'){es.close();return;}if(out){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;}};
  es.onerror=function(){es.close();};
};

function r6pGCSet(id,ok,val){var st=document.getElementById(id+'-st'),v=document.getElementById(id+'-val');if(st){st.style.background=ok?'#dcfce7':'#fee2e2';st.style.color=ok?'#16a34a':'#dc2626';st.textContent=ok?'Pass':'Fail';}if(v)v.textContent=val||'—';}

window.r6pRunGitopsPreflight=function(){
  var gitDir=R6P.creds.opencenter.gitDir||document.getElementById('r6p-gs-path')&&document.getElementById('r6p-gs-path').value;
  var out=document.getElementById('r6p-gc-out');if(out){out.style.display='block';out.textContent='';}
  var cmd='GD="'+(gitDir||'')+'"\n'
    +'[ -n "$GD" ] && [ -d "$GD" ] && echo "GITDIR:ok:$GD" || echo "GITDIR:fail:'+(gitDir?'not a real directory - '+gitDir:'empty')+'"\n'
    +'[ -n "$GD" ] && [ -d "$GD" ] && git -C "$GD" rev-parse --git-dir &>/dev/null && echo "ISREPO:ok" || echo "ISREPO:fail"\n'
    +'[ -n "$GD" ] && [ -d "$GD" ] && git -C "$GD" remote -v 2>/dev/null | grep -q fetch && echo "REMOTE:ok:$(git -C $GD remote get-url origin 2>/dev/null)" || echo "REMOTE:fail"\n'
    +'[ -n "$GD" ] && [ -d "$GD" ] && { [ -d "$GD/applications/overlays" ] || [ -d "$GD/applications/workloads" ]; } && echo "WORKLOADS:ok" || echo "WORKLOADS:fail:applications/overlays missing"\n'
    +'git config --global user.name &>/dev/null && echo "GITNAME:ok:$(git config --global user.name)" || echo "GITNAME:fail:not set"\n'
    +'git config --global user.email &>/dev/null && echo "GITEMAIL:ok:$(git config --global user.email)" || echo "GITEMAIL:fail:not set"\n'
    +'command -v flux &>/dev/null && echo "FLUX:ok:$(flux --version 2>/dev/null | head -1)" || echo "FLUX:fail:not installed"\n'
    +'CLN=$(opencenter cluster describe --output yaml 2>/dev/null | awk -F": " \'/^\\s*cluster_name:/{print $2; exit}\')\n'
    +'KCFG=""\n'
    +'[ -n "$GD" ] && [ -n "$CLN" ] && [ -f "$GD/infrastructure/clusters/$CLN/kubeconfig.yaml" ] && KCFG="$GD/infrastructure/clusters/$CLN/kubeconfig.yaml"\n'
    +'[ -z "$KCFG" ] && [ -n "$GD" ] && [ -d "$GD" ] && KCFG=$(find "$GD/infrastructure/clusters" -maxdepth 2 -name kubeconfig.yaml 2>/dev/null | head -1)\n'
    +'[ -n "$KCFG" ] && export KUBECONFIG="$KCFG"\n'
    +'if [ -z "$KCFG" ]; then echo "KUBECTL:fail:no kubeconfig found under \\$GD/infrastructure/clusters"\n'
    +'elif ! command -v kubectl &>/dev/null; then echo "KUBECTL:fail:kubectl not installed"\n'
    +'elif kubectl cluster-info 2>/dev/null | head -1 | grep -qi "running\\|is running at"; then echo "KUBECTL:ok:$KCFG"\n'
    +'else echo "KUBECTL:fail:cluster unreachable via $KCFG"; fi';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);
  es.onmessage=function(e){
    if(e.data==='[DONE]'){es.close();r6pCheckContinue();return;}
    if(out){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;}
    var m=e.data.match(/^(GITDIR|ISREPO|REMOTE|WORKLOADS|GITNAME|GITEMAIL|FLUX|KUBECTL):(ok|fail):?(.*)?$/);
    if(!m)return;
    var key=m[1],ok=m[2]==='ok',val=m[3]||'';
    var map={GITDIR:'r6p-gc-gitdir',ISREPO:'r6p-gc-isrepo',REMOTE:'r6p-gc-remote',WORKLOADS:'r6p-gc-workloads',GITNAME:'r6p-gc-gituser',GITEMAIL:'r6p-gc-gitemail',FLUX:'r6p-gc-flux',KUBECTL:'r6p-gc-kubectl'};
    if(map[key])r6pGCSet(map[key],ok,val);
  };
  es.onerror=function(){es.close();};
};

window.r6pTestKubectlLive=function(){
  var gitDir=R6P.creds.opencenter.gitDir||document.getElementById('r6p-git-localdir')&&document.getElementById('r6p-git-localdir').value;
  var out=document.getElementById('r6p-gc-out');if(out){out.style.display='block';out.textContent='';}
  var cmd='GD="'+(gitDir||'')+'"\n'
    +'CLN=$(opencenter cluster describe --output yaml 2>/dev/null | awk -F": " \'/^[[:space:]]*cluster_name:/{print $2; exit}\')\n'
    +'KCFG=""\n'
    +'[ -n "$GD" ] && [ -n "$CLN" ] && [ -f "$GD/infrastructure/clusters/$CLN/kubeconfig.yaml" ] && KCFG="$GD/infrastructure/clusters/$CLN/kubeconfig.yaml"\n'
    +'[ -z "$KCFG" ] && [ -n "$GD" ] && [ -d "$GD" ] && KCFG=$(find "$GD/infrastructure/clusters" -maxdepth 2 -name kubeconfig.yaml 2>/dev/null | head -1)\n'
    +'if [ -z "$KCFG" ]; then echo "No kubeconfig found yet for cluster \'$CLN\' under $GD/infrastructure/clusters - cluster is likely still bootstrapping."\n'
    +'else\n'
    +'  export KUBECONFIG="$KCFG"\n'
    +'  echo "== Using kubeconfig: $KCFG =="\n'
    +'  echo "== kubectl cluster-info =="\n'
    +'  timeout 10 kubectl cluster-info 2>&1\n'
    +'  echo "== kubectl get nodes -o wide =="\n'
    +'  timeout 10 kubectl get nodes -o wide 2>&1\n'
    +'fi';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);
  es.onmessage=function(e){
    if(e.data==='[DONE]'||e.data.indexOf('[EXIT')===0){es.close();return;}
    if(out){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;}
  };
  es.onerror=function(){es.close();if(out)out.textContent+='[stream error]\n';};
};

window.r6pRunLiveScan=function(){
  var sel=document.getElementById('r6p-scan-comp');
  var idx=sel?sel.value:'';
  var comps6=(R6P.components||[]).filter(function(c){return c.tgt;});
  var comp=comps6[idx];
  var out=document.getElementById('r6p-scan-out');
  if(!comp){if(out){out.style.display='block';out.textContent='Select a component with a FLEX target IP first (choose a Business System in Step 1).';}return;}
  var user=(document.getElementById('r6p-scan-user')||{}).value||'root';
  var key=(document.getElementById('r6p-scan-key')||{}).value||'~/.ssh/id_rsa';
  var ip=comp.tgt;
  var sshBase='ssh -i '+key+' -o StrictHostKeyChecking=no -o ConnectTimeout=8 '+user+'@'+ip+' ';
  var cmd='echo "== Guest dependency scan: '+comp.name+' ('+ip+') =="\n'
    +'echo "-- hostnamectl / uname --"\n'+sshBase+'"hostnamectl 2>/dev/null; uname -a"\n'
    +'echo "-- open ports --"\n'+sshBase+'"ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null"\n'
    +'echo "-- running services --"\n'+sshBase+'"systemctl --type=service --state=running 2>/dev/null | head -30"\n'
    +'echo "-- top processes --"\n'+sshBase+'"ps aux --sort=-%mem 2>/dev/null | head -30"\n'
    +'echo "-- disk usage (df -h) --"\n'+sshBase+'"df -h 2>/dev/null"\n'
    +'echo "-- block devices (lsblk) --"\n'+sshBase+'"lsblk 2>/dev/null"\n'
    +'echo "-- mounts (/etc/fstab) --"\n'+sshBase+'"cat /etc/fstab 2>/dev/null"\n'
    +'echo "-- cron jobs --"\n'+sshBase+'"crontab -l 2>/dev/null; ls /etc/cron.d/ 2>/dev/null"\n'
    +'echo "-- known app/db config files --"\n'+sshBase+'"find /etc -maxdepth 3 -type f 2>/dev/null | grep -E \'nginx|apache|mysql|postgres|mongo|redis|env\' | head -30"\n'
    +'echo "-- app paths (non-system files) --"\n'+sshBase+'"find /opt /srv /var/www /home -maxdepth 4 -type f 2>/dev/null | grep -vE \'\\.cache|\\.log$\' | head -50"';
  if(out){out.style.display='block';out.textContent='';}
  R6P.depScan=R6P.depScan||{};
  R6P.depScan[comp.name]={ip:ip,startedAt:new Date().toISOString(),rawLog:''};
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);
  es.onmessage=function(e){
    if(e.data==='[DONE]'||e.data.indexOf('[EXIT')===0){es.close();return;}
    if(out){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;}
    R6P.depScan[comp.name].rawLog+=e.data+'\n';
  };
  es.onerror=function(){es.close();if(out)out.textContent+='[stream error]\n';};
};
window.r6pExportDepScan=function(){
  var sel=document.getElementById('r6p-scan-comp');
  var comps6=(R6P.components||[]).filter(function(c){return c.tgt;});
  var comp=comps6[sel?sel.value:''];
  if(!comp||!R6P.depScan||!R6P.depScan[comp.name]){alert('Run the live scan first.');return;}
  var report={component:comp.name,ip:comp.tgt,scannedAt:R6P.depScan[comp.name].startedAt,raw:R6P.depScan[comp.name].rawLog};
  var blob=new Blob([JSON.stringify(report,null,2)],{type:'application/json'});
  var a=document.createElement('a');a.href=URL.createObjectURL(blob);
  a.download='app_dependency_report_'+comp.name.replace(/\s+/g,'_')+'.json';
  document.body.appendChild(a);a.click();document.body.removeChild(a);
};

window.r6pRunClassify=function(){
  var sel=document.getElementById('r6p-classify-comp');
  var idx=sel?sel.value:'';
  var comps7=(R6P.components||[]).filter(function(c){return c.tgt;});
  var comp=comps7[idx];
  var out=document.getElementById('r6p-classify-out');
  if(!comp){if(out){out.style.display='block';out.textContent='Select a component with a FLEX target IP first (choose a Business System in Step 1).';}return;}
  var user=(document.getElementById('r6p-classify-user')||{}).value||'root';
  var key=(document.getElementById('r6p-classify-key')||{}).value||'~/.ssh/id_rsa';
  var ip=comp.tgt;
  ['app_code','config_template','secret_candidate','log_file','database_data','excluded_file'].forEach(function(k){
    var el=document.getElementById('r6p-classify-count-'+k);if(el){el.textContent='Checking...';el.style.color='#0369a1';}
  });
  var tmpf='/tmp/r6_classify_'+Date.now()+'.txt';
  var cmd='ssh -i '+key+' -o StrictHostKeyChecking=no -o ConnectTimeout=8 '+user+'@'+ip+' "find /opt /srv /var/www /home -maxdepth 6 -type f 2>/dev/null" > '+tmpf+' 2>&1\n'
    +'app=0; cfg=0; sec=0; log=0; db=0; exc=0\n'
    +'while IFS= read -r f; do\n'
    +'  case "$f" in\n'
    +'    *.log|*/log/*) log=$((log+1));;\n'
    +'    *.pem|*.key|*id_rsa*|*.crt|*secret*|*.env) sec=$((sec+1));;\n'
    +'    *.conf|*.yaml|*.yml|*.ini|*.cfg|*.properties) cfg=$((cfg+1));;\n'
    +'    */var/lib/mysql/*|*/var/lib/postgresql/*|*.sql|*.sqlite|*.db) db=$((db+1));;\n'
    +'    *.tmp|*.cache|*~|*.bak) exc=$((exc+1));;\n'
    +'    *) app=$((app+1));;\n'
    +'  esac\n'
    +'done < '+tmpf+'\n'
    +'echo "CLASSIFY:app_code:$app"\n'
    +'echo "CLASSIFY:config_template:$cfg"\n'
    +'echo "CLASSIFY:secret_candidate:$sec"\n'
    +'echo "CLASSIFY:log_file:$log"\n'
    +'echo "CLASSIFY:database_data:$db"\n'
    +'echo "CLASSIFY:excluded_file:$exc"\n'
    +'rm -f '+tmpf;
  if(out){out.style.display='block';out.textContent='$ Checking '+comp.name+' ('+ip+')...\n';}
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);
  es.onmessage=function(e){
    if(e.data==='[DONE]'||e.data.indexOf('[EXIT')===0){es.close();return;}
    if(out){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;}
    var m=e.data.match(/^CLASSIFY:([a-z_]+):(\d+)$/);
    if(m){var el=document.getElementById('r6p-classify-count-'+m[1]);if(el){el.textContent=m[2]+' file'+(m[2]==='1'?'':'s');el.style.color=m[2]==='0'?'#94a3b8':'#0f172a';el.style.fontWeight='700';}}
  };
  es.onerror=function(){es.close();if(out)out.textContent+='[stream error]\n';};
};

function shellescape(s){return "'"+s.replace(/'/g,"'\\''")+"'";}

/* ── OpenCenter Stage 2 import override ── */
window.openCenterImportFromR6=function(){
  /* Read new state first, fall back to legacy key */
  var raw=localStorage.getItem('appsContainerRefactorOutput')||localStorage.getItem('r6OpenCenterHandoffBundle');
  if(!raw){
    var badge=document.getElementById('clf-st-2');
    if(badge){badge.textContent='Awaiting Bundle';badge.className='ocqs-status ocqs-s-idle';}
    return;
  }
  var data;
  try{data=JSON.parse(raw);}catch(e){console.error('openCenterImportFromR6: invalid JSON',e);return;}

  /* Normalise — handle both new appsContainerRefactorOutput and old bundle format */
  var bsName=data.businessSystemName||data.businessSystem||'Unknown';
  var captureMethod=data.captureMethod||'SMART_SNAPSHOT_CAPTURE';
  var cloudStatus=data.cloudNativeStatus||data.importStatus||'CLOUD_NATIVE_READY';
  var cluster=data.targetCluster||'rackspace-flex/flex-prod-k8s';
  var ns=data.namespace||bsName.toLowerCase().replace(/\s+/g,'-')+'-prod';
  var workloads=data.workloads||[];
  var extSvc=data.externalServices||[];
  var warns=(data.warnings||[]).length;
  var blockers=(data.blockers||[]).length;
  var pkgContents=data.packageContents||{};
  var isCompat=captureMethod==='FULL_SNAPSHOT_COMPATIBILITY_CONTAINER';
  var isBlocked=blockers>0||cloudStatus==='BLOCKED';

  /* Update status badge on Step 2 card */
  var st2=document.getElementById('clf-st-2');
  if(st2){st2.textContent=isBlocked?'Blocked':'Ready to Validate';st2.className='ocqs-status '+(isBlocked?'ocqs-s-failed':'ocqs-s-running');}

  /* Update main pane status badge */
  var pst=document.getElementById('s2opencenter-status');
  if(pst){pst.textContent=isBlocked?'Blocked — Fix R6 issues':'R6 Bundle Ready';pst.className='gov-status-badge '+(isBlocked?'status-failed':'status-running');}

  /* Build package contents table */
  var pkgDefs=[
    {f:'opencenter_import_manifest.json',req:'Required'},
    {f:'k8s/',req:'Required'},{f:'helm/',req:'Required'},{f:'kustomize/',req:'Required'},{f:'flux/',req:'Required'},
    {f:'Dockerfile',req:'Recommended'},{f:'image_build_plan.yaml',req:'Required'},{f:'app_capture_manifest.json',req:'Required'},
    {f:'externalization_plan.yaml',req:'Required'},{f:'container_readiness_report.json',req:'Required'},
    {f:'container_readiness_report.md',req:'Recommended'},{f:'compatibility_warnings.json',req:'Conditional'}
  ];
  var pkgTable='<table style="width:100%;border-collapse:collapse;font-size:11px;">'
    +'<thead><tr style="background:#f8fafc;"><th style="padding:6px 10px;text-align:left;border-bottom:2px solid #e2e8f0;color:#0369a1;font-size:10px;text-transform:uppercase;">File/Folder</th>'
    +'<th style="padding:6px 10px;text-align:left;border-bottom:2px solid #e2e8f0;color:#0369a1;font-size:10px;text-transform:uppercase;">Required?</th>'
    +'<th style="padding:6px 10px;text-align:left;border-bottom:2px solid #e2e8f0;color:#0369a1;font-size:10px;text-transform:uppercase;">Status</th>'
    +'</tr></thead><tbody>';
  pkgDefs.forEach(function(p){
    var isCond=p.req==='Conditional';
    var raw_st=pkgContents[p.f]||(isCond?(isCompat?'found':'not_required'):'missing');
    var stMap={'found':['#dcfce7','#16a34a','Found'],'missing':['#fee2e2','#dc2626','Missing'],'not_required':['#f1f5f9','#64748b','Not Required'],'warning':['#fef3c7','#d97706','Warning']};
    var st=stMap[raw_st]||stMap.missing;
    var reqBg=p.req==='Required'?'#fee2e2':p.req==='Recommended'?'#fef3c7':'#f1f5f9';
    var reqFg=p.req==='Required'?'#dc2626':p.req==='Recommended'?'#d97706':'#64748b';
    pkgTable+='<tr style="border-bottom:1px solid #f1f5f9;">'
      +'<td style="padding:5px 10px;font-family:monospace;font-weight:600;">'+p.f+'</td>'
      +'<td style="padding:5px 10px;"><span style="background:'+reqBg+';color:'+reqFg+';padding:2px 7px;border-radius:999px;font-size:10px;font-weight:700;">'+p.req+'</span></td>'
      +'<td style="padding:5px 10px;"><span style="background:'+st[0]+';color:'+st[1]+';padding:2px 7px;border-radius:999px;font-size:10px;font-weight:700;">'+st[2]+'</span></td></tr>';
  });
  pkgTable+='</tbody></table>';

  /* Build summary panel */
  var summaryHTML='<div style="background:#f0fdf4;border:1.5px solid #86efac;border-radius:8px;padding:14px;margin-bottom:12px;">'
    +'<div style="font-size:12px;font-weight:800;color:#166534;margin-bottom:8px;">Imported from Apps Container Refactor Engine</div>'
    +'<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;font-size:12px;">'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Business System</div><div style="font-weight:700;color:#0f172a;">'+bsName+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Source Platform</div><div style="font-weight:700;color:#0369a1;">FLEX</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Capture Method</div><div style="font-weight:700;color:'+(isCompat?'#7c3aed':'#16a34a')+';">'+(isCompat?'Full Snapshot':'Smart Snapshot')+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Cloud-Native Status</div><div style="font-weight:700;color:'+(isCompat?'#7c3aed':'#16a34a')+';">'+cloudStatus.replace(/_/g,' ')+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Target Cluster</div><div style="font-weight:700;color:#0f172a;font-size:11px;">'+cluster+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Namespace</div><div style="font-weight:700;color:#0f172a;">'+ns+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Workloads</div><div style="font-weight:700;">'+workloads.map(function(w){return w.name||w;}).join(', ')||'—'+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">External Services</div><div style="font-weight:700;">'+extSvc.map(function(s){return s.name||s;}).join(', ')||'None'+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Import Status</div><div style="font-weight:700;color:'+(isBlocked?'#dc2626':'#16a34a')+'">'+(isBlocked?'BLOCKED — fix R6 issues':'Ready to Validate')+'</div></div>'
    +(warns?'<div style="grid-column:1/-1;"><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Warnings</div><div style="color:#d97706;font-weight:700;">'+warns+' warning'+(warns!==1?'s':'')+'</div></div>':'')
    +'</div></div>';

  /* Inject into Stage 2 card — replace the "Accepted package contents" static grid */
  var step2=document.getElementById('clf-step-2');
  if(step2){
    var existing=document.getElementById('r6p-oc-import-panel');
    if(existing)existing.remove();
    var panel=document.createElement('div');
    panel.id='r6p-oc-import-panel';
    panel.style.cssText='margin:0 0 12px;';
    panel.innerHTML=summaryHTML
      +'<div style="font-size:10px;font-weight:800;color:#0369a1;text-transform:uppercase;letter-spacing:1px;margin:10px 0 6px;">Package Contents Validation</div>'
      +pkgTable
      +'<div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:12px;">'
      +'<button onclick="openCenterValidateImport()" style="background:#0369a1;color:#fff;border:none;border-radius:6px;padding:7px 14px;font-size:12px;font-weight:700;cursor:pointer;">Validate Package</button>'
      +(isBlocked?'<button disabled style="background:#f1f5f9;color:#94a3b8;border:1px solid #e2e8f0;border-radius:6px;padding:7px 14px;font-size:12px;font-weight:700;cursor:not-allowed;" title="Fix R6 blockers first">Send to OpenCenter — Blocked</button>'
        :'<button onclick="openCenterMockGenerate()" style="background:#16a34a;color:#fff;border:none;border-radius:6px;padding:7px 14px;font-size:12px;font-weight:700;cursor:pointer;">Send to OpenCenter</button>')
      +'</div>';
    var uploadDiv=step2.querySelector('[style*="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px;"]');
    if(uploadDiv)uploadDiv.parentNode.insertBefore(panel,uploadDiv.nextSibling);
    else step2.appendChild(panel);
  }

  /* Update legacy oc-import-status box if it exists */
  var legacyBox=document.getElementById('oc-import-status');
  if(legacyBox){legacyBox.innerHTML='<strong style="color:#16a34a;">Imported from Apps Container Refactor Engine</strong> — '+bsName+' — '+cloudStatus.replace(/_/g,' ');}

  /* Persist merged state */
  data.importedAt=new Date().toISOString();
  data.source='APPS_to_Container_Refactor_Engine';
  localStorage.setItem('openCenterImportState',JSON.stringify(data));
};

/* Auto-init: MutationObserver fires when pane becomes visible */
(function(){
  function tryInit(){var p=document.getElementById('s2r6ace-pane');if(p&&p.style.display!=='none'&&!p.getAttribute('data-r6p-init')){p.setAttribute('data-r6p-init','1');r6pInit();}}
  var pane=document.getElementById('s2r6ace-pane');
  if(pane){new MutationObserver(function(){tryInit();}).observe(pane,{attributes:true,attributeFilter:['style']});}
  document.addEventListener('click',function(e){if(e.target.closest('[data-sub="s2r6ace"]'))setTimeout(tryInit,300);});
  var orig=window.activateSub;if(typeof orig==='function'){window.activateSub=function(panes,id){orig(panes,id);if(id==='s2r6ace')setTimeout(tryInit,150);};}
  setTimeout(tryInit,500);
})();

/* OpenRC parser — handles v2 password, v3 password, v3 app credential */
function r6pParseOpenRC(text){
  var vars={};
  text.split('\n').forEach(function(line){
    /* strip comments */
    line=line.replace(/#.*/,'').trim();
    var m=line.match(/^(?:export\s+)?([A-Z0-9_]+)\s*=\s*["']?([^"'\n]*)["']?\s*$/);
    if(m)vars[m[1]]=m[2].trim();
  });
  /* variable expansion */
  Object.keys(vars).forEach(function(k){
    vars[k]=vars[k].replace(/\$\{?([A-Z0-9_]+)\}?/g,function(_,v){return vars[v]||'';});
  });
  /* detect auth type */
  var authType=(vars.OS_AUTH_TYPE||'').toLowerCase();
  var isAppCred=authType==='v3applicationcredential'||!!vars.OS_APPLICATION_CREDENTIAL_ID;
  var isV2=(!vars.OS_IDENTITY_API_VERSION||vars.OS_IDENTITY_API_VERSION==='2'||vars.OS_IDENTITY_API_VERSION==='2.0')&&!isAppCred;
  return {vars:vars,isAppCred:isAppCred,isV2:isV2};
}

/* Fill Stage 0 r6p-c-* credential fields */
window.r6pImportOpenRC=function(evt){
  var file=evt.target.files[0];if(!file)return;
  var reader=new FileReader();
  reader.onload=function(e){
    var p=r6pParseOpenRC(e.target.result);
    var v=p.vars;
    function set(id,val){var el=document.getElementById(id);if(el&&val!=null&&val!=='')el.value=val;}

    set('r6p-c-authurl', v.OS_AUTH_URL);
    set('r6p-c-region',  v.OS_REGION_NAME);
    set('r6p-c-proj',    v.OS_PROJECT_ID||v.OS_TENANT_ID||v.OS_PROJECT_NAME);

    /* show username/password fields if v2/password auth detected */
    var pwRow=document.getElementById('r6p-c-pw-row');
    var dt=document.getElementById('r6p-c-authtype');
    if(p.isAppCred){
      if(dt){dt.value='appcred';r6pAuthTypeChange('appcred');}
      set('r6p-c-credid',  v.OS_APPLICATION_CREDENTIAL_ID);
      set('r6p-c-secret',  v.OS_APPLICATION_CREDENTIAL_SECRET);
      r6pShowCredResult('cloud','Detected: v3 Application Credential. Fields populated.','#16a34a');
    } else {
      if(dt){dt.value='password';r6pAuthTypeChange('password');}
      set('r6p-c-username',v.OS_USERNAME);
      set('r6p-c-password',v.OS_PASSWORD);
      set('r6p-c-domain',  v.OS_USER_DOMAIN_NAME||v.OS_PROJECT_DOMAIN_NAME||'rackspace_cloud_domain');
      var authVer=p.isV2?'v2 Password':'v3 Password';
      r6pShowCredResult('cloud','Detected: '+authVer+'. Fields populated. Consider an Application Credential for automation.','#d97706');
    }
    /* set region dropdown if detected */
    var reg=v.OS_REGION_NAME;
    if(reg){var rs=document.getElementById('r6p-c-region');if(rs){for(var i=0;i<rs.options.length;i++){if(rs.options[i].value===reg){rs.selectedIndex=i;break;}}}}

    /* save to R6P state (no secret stored) */
    R6P.creds.cloud.authUrl=v.OS_AUTH_URL||'';
    R6P.creds.cloud.region=v.OS_REGION_NAME||'';
    R6P.creds.cloud.projectId=v.OS_PROJECT_ID||v.OS_TENANT_ID||'';
    R6P.creds.cloud.credId=v.OS_APPLICATION_CREDENTIAL_ID||'';
    R6P.creds.cloud.status='configured';
    /* persist non-secret fields */
    r6pSaveCredCache();
    /* also fill clf-* and ocqs-* for OpenCenter stage */
    r6pFillClfFields(v,p.isAppCred);
  };
  reader.readAsText(file);
};

function r6pFillClfFields(v,isAppCred){
  function set(id,val){var el=document.getElementById(id);if(el&&val)el.value=val;}
  set('clf-auth-url',v.OS_AUTH_URL);
  set('clf-region',v.OS_REGION_NAME);
  set('clf-proj',v.OS_PROJECT_ID||v.OS_TENANT_ID);
  set('clf-domain',v.OS_USER_DOMAIN_NAME||v.OS_PROJECT_DOMAIN_NAME);
  if(isAppCred){set('clf-cred-id',v.OS_APPLICATION_CREDENTIAL_ID);set('clf-cred-sec',v.OS_APPLICATION_CREDENTIAL_SECRET);}
  else{set('clf-username',v.OS_USERNAME);set('clf-password',v.OS_PASSWORD);}
  set('ocqs-authUrl',v.OS_AUTH_URL);set('ocqs-region',v.OS_REGION_NAME);
  if(typeof ocqsUpdate==='function')ocqsUpdate();
}

window.r6pAuthTypeChange=function(val){
  var pw=document.getElementById('r6p-c-pw-fields');
  var ac=document.getElementById('r6p-c-appcred-fields');
  if(pw)pw.style.display=val==='appcred'?'none':'block';
  if(ac)ac.style.display=val==='appcred'?'block':'none';
};

function r6pShowCredResult(block,msg,color){
  var el=document.getElementById('r6p-'+block+'-result');
  if(el){el.textContent=msg;el.style.color=color;}
}

/* Legacy clfImportOpenRC — kept for OpenCenter stage buttons */
window.clfImportOpenRC=function(evt){
  var file=evt&&evt.target&&evt.target.files[0];if(!file)return;
  var reader=new FileReader();
  reader.onload=function(e){
    var p=r6pParseOpenRC(e.target.result);
    r6pFillClfFields(p.vars,p.isAppCred);
  };
  reader.readAsText(file);
};

/* Install button map */
var R6ACE_INSTALL={'opencenter version':'git clone https://github.com/opencenter-cloud/openCenter-cli.git && cd openCenter-cli && mise trust && mise install && mise run build && sudo cp ./bin/opencenter /usr/local/bin/opencenter && opencenter version','kubectl version --client':'curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && kubectl version --client','opentofu version':'curl -sSLo /tmp/opentofu.zip https://github.com/opentofu/opentofu/releases/download/v1.8.0/tofu_1.8.0_linux_amd64.zip && cd /tmp && unzip -o opentofu.zip && sudo mv tofu /usr/local/bin/opentofu && opentofu version','flux --version || true':'curl -s https://fluxcd.io/install.sh | sudo bash && flux --version','git --version':'sudo apt-get update && sudo apt-get install -y git','curl --version':'sudo apt-get update && sudo apt-get install -y curl','jq --version':'sudo apt-get update && sudo apt-get install -y jq','helm version':'curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash','yq --version':'sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq && yq --version','kustomize version':'curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash && sudo mv kustomize /usr/local/bin/kustomize && kustomize version'};
window.r6aceRunInstall=function(did,cmdId,outId){var d=document.getElementById(did);if(d)d.remove();var out=document.getElementById(outId),cEl=document.getElementById(cmdId);if(!out||!cEl)return;var cmd=cEl.textContent.trim();var ic=R6ACE_INSTALL[cmd];if(!ic)return;out.textContent='Installing...\n';out.style.borderColor='#134e4a';var url='/api/stream/run-cmd?cmd='+encodeURIComponent(ic);var es=new EventSource(url);es.onmessage=function(e){if(e.data!=='[DONE]'){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;}else{es.close();setTimeout(function(){r6pRunCmd(cmdId,outId);},500);}};es.onerror=function(){out.textContent+='[install error]\n';es.close();};};

/* GitOps credentials card: two-way sync with the OpenCenter quickstart state */
window.r6pGitAuthToggle = function(){
  var a = (document.getElementById('r6p-git-auth')||{}).value || 'ssh';
  var sr = document.getElementById('r6p-git-ssh-row'), tr = document.getElementById('r6p-git-token-row');
  if (sr) sr.style.display = (a === 'ssh') ? '' : 'none';
  if (tr) tr.style.display = (a === 'token') ? '' : 'none';
};
window.r6pLooksLikeGitDir = function(s){
  if (!s || s.indexOf('/') !== 0) return false;
  /* reject bare UUIDs / non-path values that have leaked into this field before */
  if (/^\/?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s)) return false;
  return true;
};
window.r6pGitLoad = function(){
  try {
    var st = JSON.parse(localStorage.getItem('ocqs_state') || '{}');
    var set = function(id, v){ var el = document.getElementById(id); if (el && v) el.value = v; };
    set('r6p-git-repo', st.gitRepo); set('r6p-git-branch', st.gitBranch);
    set('r6p-git-sshkey', st.sshKey); set('r6p-git-token', st.tokVal);
    if (st.gitopsFolder && r6pLooksLikeGitDir(st.gitopsFolder)) {
      set('r6p-git-localdir', st.gitopsFolder);
      R6P.creds.opencenter.gitDir = st.gitopsFolder;
    } else {
      if (st.gitopsFolder) { try { st.gitopsFolder = ''; localStorage.setItem('ocqs_state', JSON.stringify(st)); } catch(e){} }
      var badEl = document.getElementById('r6p-git-localdir'); if (badEl) badEl.value = '';
      if (typeof r6pAutoDetectGitDir === 'function') { r6pAutoDetectGitDir(); }
    }
    var sel = document.getElementById('r6p-git-auth');
    if (sel && st.gitAuth) sel.value = st.gitAuth;
    r6pGitAuthToggle();
    var b = document.getElementById('r6p-git-badge');
    if (b && st.gitRepo){ b.textContent = 'Configured'; b.style.color = '#15803d'; }
  } catch(e){}
};
window.r6pAutoDetectGitDir = function(){
  var cmd = 'opencenter cluster describe --output yaml 2>/dev/null | awk -F": " \'/^git_dir:/{print $2; exit}\'';
  var es = new EventSource('/api/stream/run-cmd?cmd=' + encodeURIComponent(cmd));
  var out = '';
  es.onmessage = function(e){
    if (e.data === '[DONE]' || e.data.indexOf('[EXIT') === 0){
      es.close();
      var dir = out.trim();
      if (dir && typeof r6pLooksLikeGitDir === 'function' && r6pLooksLikeGitDir(dir)){
        var el = document.getElementById('r6p-git-localdir');
        /* CLI-detected value is authoritative - overwrite any stale/bad cached value */
        if (el) el.value = dir;
        R6P.creds.opencenter.gitDir = dir;
        if (typeof r6pGitSave === 'function') r6pGitSave();
      }
      return;
    }
    out += e.data;
  };
  es.onerror = function(){ es.close(); };
};
window.r6pGitSave = function(){
  if (typeof r6pSaveCredsServer === 'function') r6pSaveCredsServer();
  var v = function(id){ var el = document.getElementById(id); return el ? el.value.trim() : ''; };
  var st = {};
  try { st = JSON.parse(localStorage.getItem('ocqs_state') || '{}'); } catch(e){}
  st.gitRepo = v('r6p-git-repo'); st.gitBranch = v('r6p-git-branch') || 'main';
  st.gitAuth = v('r6p-git-auth') || 'ssh'; st.sshKey = v('r6p-git-sshkey') || '~/.ssh/id_rsa';
  if (v('r6p-git-token')) st.tokVal = v('r6p-git-token');
  var localDir = v('r6p-git-localdir');
  if (localDir) { st.gitopsFolder = localDir; R6P.creds.opencenter.gitDir = localDir; }
  try { localStorage.setItem('ocqs_state', JSON.stringify(st)); } catch(e){}
  var stEl = document.getElementById('r6p-git-status');
  if (stEl){
    if (!st.gitRepo){ stEl.textContent = '\u2717 repository URL required'; stEl.style.color = '#dc2626'; return; }
    stEl.textContent = '\u2713 saved - shared with OpenCenter quickstart (Stage 2)'; stEl.style.color = '#15803d';
  }
  var b = document.getElementById('r6p-git-badge');
  if (b){ b.textContent = st.gitRepo ? 'Configured' : 'Not Configured'; b.style.color = st.gitRepo ? '#15803d' : '#94a3b8'; }
};
setTimeout(function(){ if (document.getElementById('r6p-git-repo')) r6pGitLoad(); }, 400);
