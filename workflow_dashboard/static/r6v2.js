(function(){
  var R6V2_STAGES = [
    {n:0,label:'Preflight',title:'Preflight Check',desc:'Verify required CLIs, credentials, GitOps repo, registry target and OpenCenter context before refactoring.'},
    {n:1,label:'Input',title:'Select Source Business Apps System',desc:'Import the complete FLEX business system: VMs, networks, volumes, endpoints, ports and dependencies.'},
    {n:2,label:'Discovery',title:'Verify Source Inventory',desc:'Confirm known FLEX VM/database inventory. For live VMs this is normally skipped because Stage 1 already has target IPs.'},
    {n:3,label:'Snapshot',title:'Select Snapshots',desc:'Offline/stopped path only: choose smart/full snapshots for application and volume capture.'},
    {n:4,label:'Mapping',title:'Map Snapshots to Components',desc:'Offline/stopped path only: bind captured snapshots and volumes to business-system components.'},
    {n:5,label:'Method',title:'Choose Capture Method',desc:'Pick smart snapshot or compatibility mode. Live VMs normally continue directly to scan/analysis.'},
    {n:6,label:'Scan',title:'Live Scan Running FLEX VMs',desc:'Collect runtime, service, port, file, writable-path and process evidence from running FLEX VMs.'},
    {n:7,label:'Classify',title:'Classify Components & Portability',desc:'Classify state, runtime, portability, licensing, machine identity and application/data boundaries.'},
    {n:8,label:'Transform',title:'Containerization Decision & Risk',desc:'Assign every component a target form: containerized, Kubernetes-native, operator-managed, VM, external, data migration, manual review or blocked.'},
    {n:9,label:'Build',title:'Build Images & VM Artifacts',desc:'Generate Dockerfiles, image plan, extraction scripts, build/push scripts and VM handoff definitions.'},
    {n:10,label:'GitOps',title:'Generate GitOps Manifests',desc:'Generate Kubernetes resources, Kustomize overlays, Flux Kustomization and platform requirement intent.'},
    {n:11,label:'Bundle',title:'Generate OpenCenter Bundle',desc:'Assemble the unified OpenCenter business-system bundle with Kubernetes and hybrid VM handoff artifacts.'},
    {n:12,label:'OpenCenter',title:'Deploy to OpenCenter',desc:'Import the bundle into OpenCenter/GitOps and prepare Flux reconciliation for the Kubernetes portion.'},
    {n:13,label:'Cutover+UAT',title:'Cutover & UAT Validation',desc:'Run app-level validation across containers, VMs, data paths and business flows before sign-off.'},
    {n:14,label:'Report',title:'Final Report & Day-2 Setup',desc:'Generate evidence, day-2 operations registration, drift/backup notes and rollback handoff.'}
  ];
  var R6V2_RESCAN = [2,3,4,5,6];
  var state = { systems: [], selected: null, run: null, bundle: null, current: 0, stageStatus: {} };

  function el(id){ return document.getElementById(id); }
  function val(id){ var x=el(id); return x ? x.value : ''; }
  function setText(id, text){ var x=el(id); if(x) x.textContent = text; }
  function esc(s){ return String(s == null ? '' : s).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];}); }
  function pill(text, color){
    return '<span class="r6v2-pill" style="background:'+color+'22;color:'+color+';">'+esc(text)+'</span>';
  }
  function out(msg){
    var box=el('r6v2-output');
    if(box){ box.textContent = msg; box.scrollTop = 0; }
  }
  function stageStatus(n){ return state.stageStatus[n] || 'ns'; }
  function markStage(n, status){
    state.stageStatus[n] = status || 'done';
    if(status === 'done' && n < 14) state.current = Math.max(state.current, n + 1);
    renderPipeline();
  }
  function markRange(nums, status){ nums.forEach(function(n){ state.stageStatus[n] = status || 'done'; }); renderPipeline(); }
  function statusText(s){ return s === 'done' ? 'Complete' : s === 'blocked' ? 'Blocked' : s === 'warn' ? 'Warning' : 'Not Started'; }
  function groupedStages(){
    var rows = [], grouped = false;
    R6V2_STAGES.forEach(function(st){
      if(R6V2_RESCAN.indexOf(st.n) >= 0){
        if(grouped) return;
        grouped = true;
        rows.push({n:2, nums:R6V2_RESCAN, label:'Refresh', title:'2-6. Refresh FLEX VM / DB List', desc:'Grouped offline discovery, snapshot, mapping, method and live scan path. Skipped by default for already-running FLEX VMs because Stage 1 supplies the known inventory.', grouped:true});
        return;
      }
      rows.push(st);
    });
    return rows;
  }
  function renderPipeline(){
    var progress = el('r6v2-progress'), grid = el('r6v2-stage-grid');
    if(!progress || !grid) return;
    progress.innerHTML = groupedStages().map(function(st){
      var nums = st.nums || [st.n];
      var stStatus = nums.some(function(n){ return stageStatus(n) === 'blocked'; }) ? 'blocked' : nums.every(function(n){ return stageStatus(n) === 'done'; }) ? 'done' : 'ns';
      var cur = nums.indexOf(state.current) >= 0;
      return '<button class="r6v2-step-chip '+(cur?'current ': '')+stStatus+'" onclick="r6v2GoStage('+st.n+')">'+esc(st.grouped ? '2-6 Refresh' : (st.n+'. '+st.label))+'</button>';
    }).join('');
    grid.innerHTML = groupedStages().map(function(st){
      var nums = st.nums || [st.n];
      var stStatus = nums.some(function(n){ return stageStatus(n) === 'blocked'; }) ? 'blocked' : nums.every(function(n){ return stageStatus(n) === 'done'; }) ? 'done' : 'ns';
      var cur = nums.indexOf(state.current) >= 0;
      return '<div class="r6v2-stage-card '+(cur?'current ': '')+stStatus+'" onclick="r6v2GoStage('+st.n+')">'
        +'<div class="r6v2-stage-top"><div class="r6v2-stage-num">'+esc(st.grouped ? '2-6' : st.n)+'</div><div class="r6v2-stage-title">'+esc(st.title)+'</div></div>'
        +'<div class="r6v2-stage-desc">'+esc(st.desc)+'</div>'
        +'<span class="r6v2-stage-state">'+statusText(stStatus)+'</span>'
        +'</div>';
    }).join('');
  }
  window.r6v2GoStage = function(n){ state.current = n; renderPipeline(); };
  window.r6v2ResetStages = function(){
    state.current = 0; state.stageStatus = {}; state.run = null; state.bundle = null;
    renderPipeline(); out('Pipeline reset. Select a system and run Stage 1 / Analyze.');
  };
  window.r6v2RunCurrentStage = function(){
    var n = state.current;
    if(n === 0){ markStage(0, 'done'); out('Preflight recorded. Configure registry/GitOps fields before bundle generation.'); return; }
    if(n === 1){ if(state.selected){ markStage(1, 'done'); markRange(R6V2_RESCAN, 'done'); out('Input accepted. Steps 2-6 marked complete/skipped for live FLEX inventory.'); } else out('Select a business system first.'); return; }
    if(R6V2_RESCAN.indexOf(n) >= 0){ markRange(R6V2_RESCAN, 'done'); state.current = 7; renderPipeline(); out('Refresh group completed/skipped. Continue to Classify.'); return; }
    if(n === 7 || n === 8){ window.r6v2Analyze(); return; }
    if(n === 9 || n === 10 || n === 11){ window.r6v2Generate(); return; }
    if(n === 12){ window.r6v2SendToOpenCenter(); markStage(12, 'done'); return; }
    markStage(n, 'done'); out('Stage '+n+' marked complete.');
  };

  window.r6v2Init = function(){
    var list = el('r6v2-system-list');
    if(!list) return;
    renderPipeline();
    try { state.systems = JSON.parse(localStorage.getItem('uatS1_systems') || '[]') || []; }
    catch(e){ state.systems = []; }
    if(!state.systems.length){
      list.innerHTML = '<div style="font-size:12px;color:#64748b;line-height:1.6;">No Stage 1 business systems found. Create or import one in Stage 1 first.</div>';
      return;
    }
    list.innerHTML = state.systems.map(function(s){
      var comps = (s.components || []).length;
      var active = state.selected && state.selected.id === s.id;
      return '<div class="r6v2-system'+(active?' active':'')+'" onclick="r6v2SelectSystem(\''+esc(s.id)+'\')">'
        +'<b>'+esc(s.name || 'Unnamed system')+'</b>'
        +'<span>'+comps+' components'+(s.region ? ' / '+esc(s.region) : '')+(s.criticality ? ' / '+esc(s.criticality) : '')+'</span>'
        +'</div>';
    }).join('');
  };

  window.r6v2SelectSystem = function(id){
    state.selected = state.systems.find(function(s){ return String(s.id) === String(id); }) || null;
    state.run = null; state.bundle = null;
    r6v2Init();
    setText('r6v2-selected-note', state.selected ? ('Selected: '+state.selected.name+'. Click Analyze Selected to create a backend run.') : 'Select a business system on the left.');
    setText('r6v2-m-components', state.selected ? ((state.selected.components || []).length) : 0);
    setText('r6v2-m-container', 0); setText('r6v2-m-vm', 0); setText('r6v2-m-blockers', 0); setText('r6v2-m-status', 'Selected');
    markStage(1, 'done');
    markRange(R6V2_RESCAN, 'done');
    var body=el('r6v2-decision-body'); if(body) body.innerHTML = '<tr><td colspan="6">No analysis yet.</td></tr>';
    var btn=el('r6v2-generate-btn'); if(btn) btn.disabled = true;
    out('Selected '+(state.selected && state.selected.name || 'system')+'.');
  };

  window.r6v2Analyze = function(){
    if(!state.selected){ out('Select a business system first.'); return; }
    out('Creating backend V2 analysis run...');
    fetch('/api/r6v2/analyze', {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({ businessSystem: state.selected })
    }).then(function(r){ return r.json(); }).then(function(d){
      if(!d || !d.ok){ out('Analysis failed: '+((d && d.error) || 'unknown error')); return; }
      state.run = d.run;
      localStorage.setItem('r6v2LatestRun', JSON.stringify(state.run));
      renderRun();
      markStage(7, 'done');
      markStage(8, state.run.status === 'BLOCKED' ? 'blocked' : 'done');
      out('Backend run '+state.run.runId+' created. Status: '+state.run.status+'.');
    }).catch(function(e){ out('Analysis failed: '+e); });
  };

  function renderRun(){
    var run = state.run || {};
    var summary = run.summary || {};
    setText('r6v2-m-components', summary.components || 0);
    setText('r6v2-m-container', summary.containerized || 0);
    setText('r6v2-m-vm', summary.vmOrExternal || 0);
    setText('r6v2-m-blockers', (run.blockers || []).length);
    setText('r6v2-m-status', run.status || 'Analyzed');
    var body = el('r6v2-decision-body');
    if(body){
      body.innerHTML = (run.components || []).map(function(c, idx){
        var stateColor = c.state === 'STATEFUL' ? '#dc2626' : c.state === 'STATELESS' ? '#16a34a' : '#d97706';
        var formColor = c.targetForm === 'CONTAINERIZED' || c.targetForm === 'PARTIALLY_CONTAINERIZED' ? '#16a34a'
          : c.targetForm === 'BLOCKED' ? '#dc2626' : c.targetForm.indexOf('VM') >= 0 ? '#2563eb' : '#7c3aed';
        var needsCmd = c.targetForm === 'CONTAINERIZED' || c.targetForm === 'PARTIALLY_CONTAINERIZED';
        var cmdInput = needsCmd
          ? '<input value="'+esc(c.startCommand || '')+'" placeholder="e.g. node server.js" onchange="r6v2SetStartCommand('+idx+', this.value)" style="width:220px;max-width:100%;height:30px;border:1px solid '+(c.startCommand ? '#cbd5e1' : '#fca5a5')+';border-radius:6px;padding:4px 7px;font-size:11px;font-family:monospace;">'
          : '<span style="font-size:11px;color:#94a3b8;">Not required</span>';
        return '<tr><td><strong>'+esc(c.name)+'</strong><br><span style="font-size:10px;color:#94a3b8;">'+esc(c.endpoint || '')+'</span></td>'
          +'<td>'+pill(c.state, stateColor)+'</td>'
          +'<td>'+pill(c.targetForm, formColor)+'</td>'
          +'<td>'+esc(c.runtime || '')+'</td>'
          +'<td>'+cmdInput+'</td>'
          +'<td><strong style="font-size:11px;color:#475569;">'+esc(c.requiredGate || '')+'</strong><br><span style="font-size:11px;color:#64748b;">'+esc(c.reason || '')+'</span></td></tr>';
      }).join('') || '<tr><td colspan="6">No components in run.</td></tr>';
    }
    var btn = el('r6v2-generate-btn');
    if(btn) btn.disabled = !!(run.blockers && run.blockers.length);
  }

  window.r6v2SetStartCommand = function(idx, value){
    if(!state.run || !state.run.components || !state.run.components[idx]) return;
    state.run.components[idx].startCommand = value || '';
    var name = state.run.components[idx].name;
    state.run.blockers = (state.run.blockers || []).filter(function(b){
      return String(b).indexOf(name + ': startCommand is missing') !== 0;
    });
    if(!value && (state.run.components[idx].targetForm === 'CONTAINERIZED' || state.run.components[idx].targetForm === 'PARTIALLY_CONTAINERIZED')){
      state.run.blockers.push(name + ': startCommand is missing; run live scan or set it manually before generating a production image.');
    }
    state.run.status = state.run.blockers.length ? 'BLOCKED' : 'READY_FOR_BUNDLE';
    localStorage.setItem('r6v2LatestRun', JSON.stringify(state.run));
    renderRun();
    markStage(8, state.run.blockers.length ? 'blocked' : 'done');
  };

  window.r6v2Generate = function(){
    if(!state.run){ out('Run analysis first.'); return; }
    out('Generating real backend OpenCenter bundle...');
    var payload = {
      run: state.run,
      org: val('r6v2-org') || 'rackspace-flex',
      cluster: val('r6v2-cluster') || 'flex-prod-k8s',
      region: val('r6v2-region') || 'iad3',
      auto_commit: val('r6v2-auto-commit') === 'true',
      registry: {
        type: val('r6v2-reg-type') || 'harbor',
        url: val('r6v2-reg-url'),
        project: val('r6v2-reg-project') || 'flex-apps'
      },
      source_vm: { user: val('r6v2-vm-user') || 'root' }
    };
    fetch('/api/r6v2/generate', {
      method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(payload)
    }).then(function(r){ return r.json(); }).then(function(d){
      if(!d || !d.ok){ out('Generation failed: '+((d && d.error) || 'unknown error')); return; }
      state.bundle = d;
      localStorage.setItem('r6v2LatestBundle', JSON.stringify(d));
      markStage(9, 'done');
      markStage(10, 'done');
      markStage(11, 'done');
      if(d.imported_to) markStage(12, 'done');
      out('Bundle generated:\n'+JSON.stringify({
        bundle_dir:d.bundle_dir, imported_to:d.imported_to, validation:d.bundle_validation,
        extract_cmd:d.extract_cmd, build_cmd:d.build_cmd, push_cmd:d.push_cmd
      }, null, 2));
    }).catch(function(e){ out('Generation failed: '+e); });
  };

  window.r6v2RunCmd = function(key){
    var d = state.bundle;
    if(!d){ try{ d = JSON.parse(localStorage.getItem('r6v2LatestBundle') || 'null'); }catch(e){} }
    if(!d || !d[key]){ out('Generate a backend bundle first.'); return; }
    var box = el('r6v2-output');
    box.textContent = '$ '+d[key]+'\n';
    var es = new EventSource('/api/stream/run-cmd?cmd='+encodeURIComponent(d[key]));
    es.onmessage = function(e){
      if(e.data === '[DONE]'){ es.close(); return; }
      box.textContent += e.data + '\n';
      box.scrollTop = box.scrollHeight;
    };
    es.onerror = function(){ box.textContent += '[stream closed]\n'; es.close(); };
  };

  window.r6v2SendToOpenCenter = function(){
    var d = state.bundle;
    if(!d){ try{ d = JSON.parse(localStorage.getItem('r6v2LatestBundle') || 'null'); }catch(e){} }
    if(!d){ out('Generate a backend bundle first.'); return; }
    var oc = {
      status:'ready_for_opencenter_import',
      sourceStage:'Refactor_Apps_Container_V2',
      businessSystemName:d.system || (state.run && state.run.businessSystemName) || '',
      targetCluster:(d.org || '') + '/' + (d.cluster || ''),
      bundlePath:d.bundle_dir,
      generatedAt:d.generated_at,
      backendBundle:d
    };
    localStorage.setItem('appsContainerRefactorOutput', JSON.stringify(oc));
    localStorage.setItem('r6OpenCenterHandoffBundle', JSON.stringify(oc));
    markStage(12, 'done');
    if(typeof openCenterImportFromR6 === 'function') setTimeout(openCenterImportFromR6, 150);
    if(typeof stage2OpenPath === 'function') setTimeout(function(){ stage2OpenPath('s2opencenter'); }, 250);
    out('Sent V2 backend bundle to OpenCenter import state.');
  };

  window.r6v2DownloadRun = function(){
    var run = state.run;
    if(!run){ try{ run = JSON.parse(localStorage.getItem('r6v2LatestRun') || 'null'); }catch(e){} }
    if(!run){ out('No V2 run to export yet.'); return; }
    var a=document.createElement('a');
    a.href=URL.createObjectURL(new Blob([JSON.stringify(run,null,2)],{type:'application/json'}));
    a.download='r6v2-run-'+(run.runId || Date.now())+'.json';
    a.click();
  };

  document.addEventListener('click', function(e){
    if(e.target.closest('[data-sub="s2r6v2"]')) setTimeout(window.r6v2Init, 120);
  });
})();
