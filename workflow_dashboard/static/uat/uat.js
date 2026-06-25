(function () {
  const UAT = {
    artifacts: [],
    scope: [],
    checklist: [],
    performance: {},
    issues: [],
    readiness: {},
    command_runs: [],
    log_findings: [],
    // Live service comparison state — populated by svcCompareRun() in combined.html
    serviceComparison: { ran: false, rows: [], blockingGaps: [], warnings: [], acceptable: 0, total: 0 },
    // Workload scope — drives which checks are required and which metrics are in scope
    workloadScope: (function() {
      try { return JSON.parse(localStorage.getItem('uat_workload_scope') || 'null') || {}; } catch(e) { return {}; }
    })(),
  };

  const $ = (id) => document.getElementById(id);
  const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[ch]));
  const slug = (value) => String(value || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  const BADGE_ST = {
    pass:    'background:#16a34a;color:#fff;border:1px solid #15803d',
    ready:   'background:#16a34a;color:#fff;border:1px solid #15803d',
    loaded:  'background:#16a34a;color:#fff;border:1px solid #15803d',
    fail:    'background:#dc2626;color:#fff;border:1px solid #b91c1c',
    failed:  'background:#dc2626;color:#fff;border:1px solid #b91c1c',
    invalid: 'background:#dc2626;color:#fff;border:1px solid #b91c1c',
    blocked: 'background:#dc2626;color:#fff;border:1px solid #b91c1c',
    missing: 'background:#d97706;color:#fff;border:1px solid #b45309',
    review:  'background:#d97706;color:#fff;border:1px solid #b45309',
    testing: 'background:#d97706;color:#fff;border:1px solid #b45309',
    accepted:'background:#d97706;color:#fff;border:1px solid #b45309',
  };
  const badge = (value) => {
    const cls = slug(value);
    const st = BADGE_ST[cls] || 'background:#475569;color:#fff;border:1px solid #374151';
    return `<span class="uat-badge ${cls}" style="${st}">${esc(value)}</span>`;
  };

  async function api(path, options = {}) {
    const res = await fetch(path, {
      headers: {'Content-Type': 'application/json', ...(options.headers || {})},
      ...options,
    });
    const data = await res.json();
    if (!res.ok || data.ok === false) throw new Error(data.error || `Request failed: ${path}`);
    return data;
  }

  function setMessage(text, good = true) {
    const el = $('uat-message');
    if (!el) return;
    el.textContent = text;
    el.style.color = good ? '#86efac' : '#fecaca';
  }

  async function loadUAT() {
    const data = await api('/api/uat/state');
    Object.assign(UAT, data);
    renderAll();
  }

  function renderAll() {
    renderSummary();
    renderArtifacts();
    renderScope();
    renderChecklist();
    renderPerformance();
    renderIssues();
    renderFindings();
    renderRuns();
    renderReadiness();
  }

  // ── Core decision engine ──────────────────────────────────────────────────

  function calculateUatReadinessAnalysis() {
    var r   = UAT.readiness || {};
    var rt  = r.required_tests || {};
    var sc  = UAT.serviceComparison || {};
    var wl  = UAT.workloadScope || {};
    var hasDB = wl.hasDatabase === true;

    // Service analysis — prefer live data (set by uatSetServiceComparison), fallback to API
    var svcRan       = sc.ran || false;
    var svcRows      = sc.rows || [];
    var svcReviewGaps = (sc.reviewGaps  || []).slice(); // criticalMissing — needs review/accept
    var svcWarnings   = (sc.warnings    || []).slice(); // reviewExtra — verify before cutover
    var svcHardBlocks = (sc.blockingGaps || []).slice(); // true hard failures (typically empty)
    var svcAcceptable = sc.acceptable || 0;
    var svcTotal      = sc.total > 0 ? sc.total : (r.service_total || 0);

    // API fallback when service compare hasn't been run this session
    if (!svcRan && r.service_total > 0) {
      var apiItems = r.service_review_items || [];
      if (r.service_needs_review > 0 && svcReviewGaps.length === 0) {
        apiItems.forEach(function(item) {
          svcReviewGaps.push({ service: typeof item === 'string' ? item : item.name || 'Unknown', status: 'Review Needed' });
        });
      }
      svcAcceptable = (r.service_matched || 0) + (r.service_absent_expected || 0) + (r.service_flex_only || 0);
    }

    // Performance — live metrics from uatSetPerfMetrics, fallback to saved API status
    var perfMetrics = UAT.performance.metrics || [];
    var perfOverall = UAT.performance.overall_status ||
      (r.performance_status === 'Pass' ? 'PASS' : r.performance_status === 'Fail' ? 'FAIL' : '');
    var perfPasses = 0, perfFails = 0, perfWarns = 0, perfInfos = 0, perfNTs = 0, perfOOS = 0;
    perfMetrics.forEach(function(m) {
      if (m.badge === 'PASS') perfPasses++;
      else if (m.badge === 'FAIL') perfFails++;
      else if (m.badge === 'WARN') perfWarns++;
      else if (m.badge === 'INFO') perfInfos++;
      else if (m.badge === 'NOT TESTED') perfNTs++;
      else if (m.badge === 'OUT OF SCOPE') perfOOS++;
    });
    var perfMeasured = perfPasses + perfFails + perfWarns;
    if (!perfOverall && perfMeasured > 0)
      perfOverall = perfFails > 0 ? 'FAIL' : perfWarns > 0 ? 'WARN' : 'PASS';

    var openCriticalIssues = r.critical_open_issues || 0;

    // Scope-aware check definitions — database_validation is OOS when no DB selected
    var checks = [
      { key:'critical_systems', label:'Critical Systems Tested', outOfScope:false,
        linkedTest: null,
        pass: !!r.critical_systems_tested,
        detail: (r.critical_systems || 0) + ' critical server(s) in scope',
        source: 'Step 1 — Server Targets · Status column',
        fix: 'Set Status = Passed for each critical server in Step 1 after UAT is complete.',
        decisionImpact: 'Blocks cutover' },

      { key:'critical_issues', label:'No Open Critical Issues', outOfScope:false,
        linkedTest: null,
        pass: openCriticalIssues === 0,
        detail: openCriticalIssues + ' critical open issue(s)',
        source: 'Step 4 — Issues Tracker',
        fix: 'Resolve all Critical-severity issues in Step 4 — Issues Tracker.',
        decisionImpact: 'Blocks cutover' },

      { key:'data_validation', label:'Data Validation', outOfScope:false,
        linkedTest: 'data_comparison',
        pass: !!rt.data_validation,
        detail: 'Checklist item: data_comparison',
        source: 'Step 4 — SSH Command Checklist',
        fix: 'Run the data_comparison checklist test and mark it Passed.',
        decisionImpact: 'Blocks cutover' },

      { key:'app_health', label:'App Health Check', outOfScope:false,
        linkedTest: 'application_health',
        pass: !!rt.app_health,
        detail: 'Checklist item: application_health',
        source: 'Step 2 — Post-Migration Health Validation',
        fix: 'Run Health Check on the target server and mark application_health Passed.',
        decisionImpact: 'Blocks cutover' },

      { key:'database_validation', label:'Database Validation', outOfScope:!hasDB,
        linkedTest: 'database_validation',
        pass: hasDB ? !!rt.database_validation : null,
        detail: hasDB ? 'Checklist item: database_validation'
                      : 'No database component selected — DB Connect 0/0 is NOT a validation result.',
        source: 'Step 4 — DB validation checklist · DB Connect 0/0 = NOT TESTED',
        fix: 'Run DB connectivity and query test on the target server and attach evidence.',
        decisionImpact: hasDB ? 'Blocks cutover' : 'No impact — out of scope' },

      { key:'reports_outputs', label:'Reports & Outputs', outOfScope:false,
        linkedTest: 'reports_outputs',
        pass: !!rt.reports_outputs,
        detail: 'Checklist item: reports_outputs',
        source: 'Step 4 — Reports/output validation checklist',
        fix: 'Verify application reports generate correctly on FLEX, then mark reports_outputs Passed.',
        decisionImpact: 'Blocks cutover' },

      { key:'performance', label:'Performance', outOfScope:false,
        pass: perfOverall === 'PASS' || perfOverall === 'WARN' ||
              (!perfOverall && r.performance_status && r.performance_status !== 'Fail'),
        detail: perfMeasured > 0
          ? perfPasses + ' of ' + perfMeasured + ' measured metrics OK'
            + (perfInfos > 0 ? ' · ' + perfInfos + ' informational' : '')
            + (perfNTs  > 0 ? ' · ' + perfNTs  + ' not tested'     : '')
            + (perfOOS  > 0 ? ' · ' + perfOOS  + ' out of scope'   : '')
          : 'Status: ' + (r.performance_status || 'Not yet run'),
        source: 'Step 3 — SSH Performance Test (live)',
        fix: 'Go to Step 3 — Performance Validation. Run SSH Tests and review failing metrics.',
        decisionImpact: perfOverall === 'FAIL' ? 'Blocks cutover' : 'Supports cutover' },
    ];

    // Mark checks as notTested if linkedTest has no command runs at all
    var runTestKeys = {};
    (UAT.command_runs || []).forEach(function(run) {
      runTestKeys[run.linked_test || ''] = true;
    });
    checks.forEach(function(c) {
      c.notTested = (!c.pass && !!c.linkedTest && !runTestKeys[c.linkedTest]);
    });

    var inScopeChecks = checks.filter(function(c){ return !c.outOfScope; });
    var passed   = inScopeChecks.filter(function(c){ return c.pass;  }).length;
    var total    = inScopeChecks.length;
    var blocking = inScopeChecks.filter(function(c){ return !c.pass && !c.notTested; }).length;
    var pct      = total > 0 ? Math.round(passed / total * 100) : 0;

    // Decision: checklist failures OR hard service blocks → NOT READY
    //           review gaps / warnings only → READY WITH CONDITIONS
    var notReady      = blocking > 0 || svcHardBlocks.length > 0 || perfOverall === 'FAIL';
    var readyWithCond = !notReady && (svcReviewGaps.length > 0 || svcWarnings.length > 0);
    var isReady       = !notReady && !readyWithCond;
    var cutoverDecision = isReady ? 'READY' : readyWithCond ? 'READY WITH CONDITIONS' : 'NOT READY';

    // Good news (for "Why" panel)
    var goodNews = [];
    inScopeChecks.filter(function(c){ return c.pass; }).forEach(function(c) {
      if (c.key === 'performance') goodNews.push('Performance validation passed (' + (perfOverall || 'PASS') + ').');
      else if (c.key === 'critical_issues') goodNews.push('No open critical issues are recorded.');
      else goodNews.push(c.label + ' is complete.');
    });
    if (svcRan && svcReviewGaps.length === 0 && svcHardBlocks.length === 0 && svcTotal > 0)
      goodNews.push('No critical service gaps found.');
    if (svcRan && svcAcceptable > 0)
      goodNews.push(svcAcceptable + ' service(s) are acceptable or expected platform differences.');

    // Blocking items (notTested excluded — they don't block)
    var blockingItems = [];
    inScopeChecks.filter(function(c){ return !c.pass && !c.notTested; }).forEach(function(c) {
      if (c.key === 'performance') blockingItems.push('Performance is ' + (perfOverall || 'REVIEW') + ' — check Step 3 for failing metrics.');
      else blockingItems.push(c.label + ' check is incomplete.');
    });
    svcHardBlocks.forEach(function(s) {
      blockingItems.push(s.service + ' is critically missing on FLEX.');
    });

    // Review / warning items (separate from blockers)
    var reviewItems = [];
    svcReviewGaps.forEach(function(s) {
      reviewItems.push(s.service + ' is missing on FLEX — needs review or acceptance before cutover.');
    });
    svcWarnings.forEach(function(s) {
      reviewItems.push(s.service + ' is extra on FLEX — verify whether it should exist.');
    });
    var dbMetric = perfMetrics.find(function(m){ return m.key === 'db_ms'; });
    if (hasDB && dbMetric && dbMetric.badge === 'NOT TESTED')
      reviewItems.push('DB Connect shows 0/0 — this is NOT TESTED, not a passed DB validation. Run a real DB query test.');
    if (perfWarns > 0)
      reviewItems.push(perfWarns + ' performance metric(s) slightly elevated (within the +15% acceptable threshold).');

    // Out-of-scope items for "Why" panel
    var oosItems = [];
    checks.filter(function(c){ return c.outOfScope; }).forEach(function(c) {
      oosItems.push({ label: c.label, detail: c.detail });
    });
    if (!hasDB) {
      oosItems.push({ label: 'DB Connect (metric)', detail: 'No database selected — DB Connect metric is not evaluated.' });
    }

    // Next actions — dynamically generated from actual blockers/gaps only
    var nextActions = [];
    svcHardBlocks.forEach(function(s) {
      nextActions.push({ title: 'Fix ' + s.service, impact: 'Blocks cutover.',
        action: 'Start this service on FLEX or accept as a known difference with owner approval.' });
    });
    svcReviewGaps.forEach(function(s) {
      nextActions.push({ title: 'Review ' + s.service, impact: 'Must be accepted before cutover.',
        action: 'Check if this service is required on FLEX. Start it, or accept as a known difference with owner approval.' });
    });
    svcWarnings.forEach(function(s) {
      nextActions.push({ title: 'Verify ' + s.service, impact: 'Warning — does not block if accepted.',
        action: 'Confirm whether this service is expected from the FLEX base image. Accept or remove per policy.' });
    });
    inScopeChecks.filter(function(c){ return !c.pass && !c.notTested; }).forEach(function(c) {
      nextActions.push({ title: 'Complete ' + c.label, impact: c.decisionImpact, action: c.fix });
    });
    nextActions.push({ title: 'Re-run Cutover Readiness', impact: 'Final decision refresh.',
      action: 'Refresh after all failed checks are resolved or accepted.' });

    // Service comparison evidence
    var svcEvidence = [];
    if (svcRan) {
      if (svcAcceptable > 0)
        svcEvidence.push({ type:'pass', text: svcAcceptable + ' service(s) match or are expected platform differences.' });
      svcReviewGaps.forEach(function(s) {
        svcEvidence.push({ type:'warning', text: s.service + ': ' + s.status + ' — needs review or acceptance.' });
      });
      svcHardBlocks.forEach(function(s) {
        svcEvidence.push({ type:'fail', text: s.service + ': ' + s.status + ' — blocks cutover.' });
      });
      svcWarnings.forEach(function(s) {
        svcEvidence.push({ type:'info', text: s.service + ': extra on FLEX — verify before cutover.' });
      });
    } else {
      svcEvidence.push({ type:'info', text: 'Service comparison not yet run. Go to Step 2 and click Compare Services.' });
    }

    // Performance evidence
    var perfEvidence = perfMetrics.map(function(m) {
      var typeMap = { PASS:'pass', FAIL:'fail', WARN:'warning', INFO:'info', 'NOT TESTED':'nt', 'OUT OF SCOPE':'oos' };
      return { type: typeMap[m.badge] || 'info',
               text: m.label + ': ' + m.badge + (m.text && m.text !== '—' ? ' (' + m.text + ')' : '') + '.' };
    });

    return {
      checks: checks, inScopeChecks: inScopeChecks,
      passed: passed, total: total, blocking: blocking, pct: pct,
      cutoverDecision: cutoverDecision, isReady: isReady, readyWithCond: readyWithCond,
      openCriticalIssues: openCriticalIssues,
      svcTotal: svcTotal, svcReviewGaps: svcReviewGaps, svcWarnings: svcWarnings,
      svcHardBlocks: svcHardBlocks, svcAcceptable: svcAcceptable, svcRan: svcRan, svcRows: svcRows,
      perfOverall: perfOverall, perfPasses: perfPasses, perfFails: perfFails, perfWarns: perfWarns,
      perfInfos: perfInfos, perfNTs: perfNTs, perfOOS: perfOOS, perfMeasured: perfMeasured,
      perfMetrics: perfMetrics,
      goodNews: goodNews, blockingItems: blockingItems, reviewItems: reviewItems, oosItems: oosItems,
      nextActions: nextActions, svcEvidence: svcEvidence, perfEvidence: perfEvidence, hasDB: hasDB,
    };
  }

  function renderSummary() {
    if (!$('uat-summary-grid')) return;
    var a = calculateUatReadinessAnalysis();

    var decisionColor = a.cutoverDecision === 'READY' ? '#15803d'
                      : a.cutoverDecision === 'READY WITH CONDITIONS' ? '#b45309' : '#b91c1c';
    var scoreColor    = a.pct >= 80 ? '#15803d' : a.pct >= 50 ? '#b45309' : '#b91c1c';
    var perfColor     = a.perfOverall === 'PASS' ? '#15803d' : a.perfOverall === 'WARN' ? '#b45309'
                      : a.perfOverall === 'FAIL' ? '#b91c1c' : '#64748b';
    var svcEquiv      = a.svcTotal > 0 ? a.svcAcceptable + ' / ' + a.svcTotal : '—';
    var oosCount      = a.checks.filter(function(c){ return c.outOfScope; }).length;
    var reviewCount   = a.svcReviewGaps.length;

    var warnCount  = a.svcWarnings.length;
    var blockCount = a.svcHardBlocks.length;

    var stats = [
      { label:'Cutover Decision',      value: a.cutoverDecision,           color: decisionColor },
      { label:'Readiness Score',       value: a.pct + '%',                 color: scoreColor },
      { label:'Passed Checks',         value: a.passed + ' / ' + a.total, color: '#1e293b' },
      { label:'Blocking Checks',       value: a.blocking,                  color: a.blocking > 0 ? '#b91c1c' : '#15803d' },
      { label:'Service Review Gaps',   value: reviewCount,                  color: reviewCount > 0 ? '#b45309' : '#15803d' },
      { label:'Service Blocking Gaps', value: blockCount,                   color: blockCount > 0 ? '#b91c1c' : '#15803d' },
      { label:'Service Warnings',      value: warnCount,                    color: warnCount > 0  ? '#b45309' : '#15803d' },
      { label:'Out of Scope',          value: oosCount,                     color: '#64748b' },
      { label:'Service Equivalence',   value: svcEquiv,                     color: '#1e293b' },
      { label:'Performance',           value: a.perfOverall || '—',         color: perfColor },
      { label:'Open Critical Issues',  value: a.openCriticalIssues,         color: a.openCriticalIssues > 0 ? '#b91c1c' : '#15803d' },
    ];

    $('uat-summary-grid').innerHTML = stats.map(function(s) {
      return '<div style="padding:9px 11px;background:#ffffff;border:1px solid #e2e8f0;border-radius:7px;min-width:90px;">'
        + '<div style="color:#64748b;font-size:10px;text-transform:uppercase;letter-spacing:.08em;font-weight:600;">' + esc(s.label) + '</div>'
        + '<div style="color:' + s.color + ';font-size:17px;font-weight:800;margin-top:4px;line-height:1;">' + esc(String(s.value)) + '</div>'
        + '</div>';
    }).join('');
  }

  function renderArtifacts() {
    if (!$('uat-artifacts-body')) return;
    $('uat-artifacts-body').innerHTML = UAT.artifacts.map((a, i) => `
      <tr>
        <td>${esc(a.stage)}</td>
        <td><strong>${esc(a.filename)}</strong><div class="uat-note">${esc(a.kind)} · ${Number(a.size_bytes || 0).toLocaleString()} bytes</div></td>
        <td>${badge(a.status)}</td>
        <td>${esc(a.warning || 'Ready')}</td>
        <td>
          <button class="uat-btn" onclick="uatViewArtifact(${i})">View</button>
          ${a.download_url ? `<a class="uat-btn" href="${esc(a.download_url)}">Download</a>` : ''}
          <button class="uat-btn" onclick="uatValidateArtifacts()">Validate</button>
        </td>
      </tr>
    `).join('');
  }

  window.uatViewArtifact = function (index) {
    const artifact = UAT.artifacts[index];
    const box = $('uat-artifact-preview');
    if (!artifact) return;
    box.classList.remove('uat-hidden');
    box.textContent = `${artifact.stage}/${artifact.filename}\nSTATUS: ${artifact.status}\n\n${typeof artifact.preview === 'string' ? artifact.preview : JSON.stringify(artifact.preview, null, 2)}`;
  };

  window.uatValidateArtifacts = async function () {
    await loadUAT();
    setMessage('Artifact validation refreshed.');
  };

  function scopeSelect(value, options) {
    return `<select class="uat-select">${options.map(o => `<option${o === value ? ' selected' : ''}>${esc(o)}</option>`).join('')}</select>`;
  }

  function renderScope() {
    renderExecutionSystems();
    $('uat-scope-body').innerHTML = UAT.scope.map((row, i) => {
      const isDB = row.system_type === 'DB';
      const dbEngineCell = isDB
        ? scopeSelect(row.db_engine || 'mysql', ['mysql', 'postgresql'])
        : `<span style="color:#94a3b8;font-size:11px;">—</span><input type="hidden" value="">`;
      const actionBtns = isDB
        ? `<div style="display:flex;flex-direction:column;gap:4px;">
             <button class="uat-btn uat-btn-danger" onclick="uatDeleteScope(${i})">Delete</button>
             <button class="uat-btn" onclick="uatCompareDB(${i})" style="font-size:10px;padding:3px 8px;background:#0e7490;border-color:#0891b2;">Compare DB</button>
           </div>`
        : `<button class="uat-btn uat-btn-danger" onclick="uatDeleteScope(${i})">Delete</button>`;
      return `
        <tr data-row="${i}">
          <td>${scopeSelect(row.system_type, ['App', 'DB'])}</td>
          <td><input class="uat-input" value="${esc(row.business_system_name)}"></td>
          <td>${scopeSelect(row.tier, ['Backend', 'Frontend', 'Database', 'Batch', 'External Integration'])}</td>
          <td><input class="uat-input" value="${esc(row.source_host)}"></td>
          <td><input class="uat-input" value="${esc(row.target_ip || row.target_host)}"></td>
          <td><input class="uat-input" value="${esc(row.ssh_user || 'ubuntu')}"></td>
          <td><input class="uat-input" value="${esc(row.ssh_key_path || '')}"></td>
          <td><input class="uat-input" value="${esc(row.ssh_port || '22')}"></td>
          <td><input class="uat-input" value="${esc(row.app_port || '')}" placeholder="e.g. 8080"></td>
          <td><input class="uat-input" value="${esc(row.db_port || '')}" placeholder="e.g. 5432"></td>
          <td>${dbEngineCell}</td>
          <td>${scopeSelect(row.criticality, ['Critical', 'Secondary', 'Low'])}</td>
          <td><input class="uat-input" value="${esc(row.owner)}"></td>
          <td>${scopeSelect(row.uat_status, ['Not Started', 'Testing', 'Passed', 'Failed', 'Blocked'])}</td>
          <td>${actionBtns}</td>
        </tr>`;
    }).join('');
    if (typeof window.syncStep2FromScope === 'function') window.syncStep2FromScope();
  }

  // readScopeTable reads ALL fields from the rendered rows — must match renderScope column order
  // The hidden fields in the add-form keep the data model intact; rendered table uses compact columns

  function readScopeTable() {
    const rows = [];
    document.querySelectorAll('#uat-scope-body tr').forEach((tr, i) => {
      const fields = tr.querySelectorAll('input, select, textarea');
      const prev = UAT.scope[i] || {};
      rows.push({
        system_id:            prev.system_id || `scope-${String(i + 1).padStart(3, '0')}`,
        system_type:          fields[0].value,
        business_system_name: fields[1].value,
        tier:                 fields[2].value,
        source_host:          fields[3].value,
        target_ip:            fields[4].value,
        target_host:          fields[4].value,
        ssh_user:             fields[5].value,
        ssh_key_path:         fields[6].value,
        ssh_port:             fields[7].value,
        app_port:             fields[8].value,
        db_port:              fields[9].value,
        db_engine:            fields[10] ? fields[10].value : (prev.db_engine || ''),
        criticality:          fields[11].value,
        owner:                fields[12].value,
        uat_status:           fields[13].value,
        db_user:              prev.db_user || '',
        db_password:          prev.db_password || '',
        execution_mode:       'ssh',
        ssh_host:             fields[4].value,
        dependencies:         prev.dependencies || '',
        notes:                prev.notes || '',
      });
    });
    UAT.scope = rows;
    return rows;
  }

  window.uatShowScopeForm = function () {
    $('uat-scope-form').classList.toggle('uat-hidden');
  };

  window.uatAddScope = async function () {
    const form = $('uat-scope-form');
    const data = Object.fromEntries(Array.from(form.querySelectorAll('[name]')).map(el => [el.name, el.value]));
    data.system_id = `scope-${Date.now()}`;
    UAT.scope.push(data);
    form.querySelectorAll('input, textarea').forEach(el => el.value = '');
    form.classList.add('uat-hidden');
    await saveScope();
  };

  window.uatInjectScope = async function (entry) {
    // Skip if an entry with the same source_host already exists
    const exists = UAT.scope.some(function(r) {
      return r.source_host === entry.source_host && r.ssh_host === entry.ssh_host;
    });
    if (exists) { setMessage('Scope entry already exists for ' + entry.source_host + ' → ' + entry.ssh_host + '.'); return; }
    entry.system_id = 'scope-' + Date.now();
    UAT.scope.push(entry);
    await saveScope();
    setMessage('Scope auto-populated from Service Comparison: ' + entry.source_host + ' → ' + entry.ssh_host);
  };

  window.uatDeleteScope = async function (index) {
    readScopeTable();
    UAT.scope.splice(index, 1);
    await saveScope();
  };

  // ── DB Compare — global entry point (finds first DB scope row) ───────────────
  window.uatCompareDbGlobal = function () {
    readScopeTable();
    const idx = UAT.scope.findIndex(r => r.system_type === 'DB');
    if (idx < 0) {
      alert('No DB entry in Step 1 — Server Targets.\nAdd a row with Type = DB first.');
      return;
    }
    window.uatCompareDB(idx);
  };

  // ── DB Compare ───────────────────────────────────────────────────────────────
  window.uatCompareDB = function (rowIndex) {
    readScopeTable();
    const row = UAT.scope[rowIndex];
    if (!row) return;
    const modal = document.getElementById('db-compare-modal');
    if (!modal) return;
    const engine = row.db_engine || 'mysql';
    const defaultUser = engine === 'postgresql' ? 'postgres' : 'root';
    modal.style.display = 'flex';
    modal.innerHTML = `
      <div style="background:#1e293b;border-radius:12px;padding:24px;max-width:1060px;width:100%;color:#e2e8f0;margin:auto;">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:16px;">
          <div style="font-size:16px;font-weight:700;color:#f8fafc;">Compare DB — ${esc(row.business_system_name)}</div>
          <button onclick="document.getElementById('db-compare-modal').style.display='none'" style="background:#374151;border:none;color:#9ca3af;font-size:18px;cursor:pointer;border-radius:6px;padding:4px 10px;">×</button>
        </div>
        <div style="font-size:12px;color:#94a3b8;margin-bottom:14px;">
          Source: <strong style="color:#7dd3fc;">${esc(row.source_host)}</strong> &nbsp;→&nbsp;
          Target: <strong style="color:#86efac;">${esc(row.target_ip || row.target_host)}</strong> &nbsp;·&nbsp;
          Engine: <strong style="color:#fde68a;">${esc(engine)}</strong> · Port: ${esc(row.db_port || (engine === 'postgresql' ? '5432' : '3306'))}
        </div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:14px;">
          <label style="font-size:12px;display:flex;flex-direction:column;gap:4px;">DB User
            <input id="dbc-db-user" class="uat-input" value="${esc(row.db_user || defaultUser)}" placeholder="${esc(defaultUser)}">
          </label>
          <label style="font-size:12px;display:flex;flex-direction:column;gap:4px;">DB Password
            <input id="dbc-db-pass" class="uat-input" type="password" value="${esc(row.db_password || '')}" placeholder="leave blank if none">
          </label>
        </div>
        <div style="display:flex;gap:10px;align-items:center;">
          <button class="uat-btn" id="dbc-run-btn" onclick="uatRunDbCompare(${rowIndex})"
            style="background:#0e7490;border-color:#0891b2;font-weight:700;">Run DB Comparison</button>
          <span id="dbc-status" style="font-size:12px;color:#94a3b8;"></span>
        </div>
        <div id="dbc-results" style="margin-top:16px;max-height:calc(100vh - 260px);overflow-y:auto;"></div>
      </div>`;
  };

  window.uatRunDbCompare = async function (rowIndex) {
    readScopeTable();
    const row = UAT.scope[rowIndex];
    if (!row) return;
    const dbUser = (document.getElementById('dbc-db-user') || {}).value || '';
    const dbPass = (document.getElementById('dbc-db-pass') || {}).value || '';
    const statusEl = document.getElementById('dbc-status');
    const resultsEl = document.getElementById('dbc-results');
    const runBtn = document.getElementById('dbc-run-btn');
    if (statusEl) statusEl.innerHTML = '<span style="color:#fbbf24;">⟳ Connecting to both servers…</span>';
    if (runBtn) runBtn.disabled = true;
    if (resultsEl) resultsEl.innerHTML = '';
    try {
      const res = await api('/api/uat/compare-db', {
        method: 'POST',
        body: JSON.stringify({
          source_host:  row.source_host,
          target_host:  row.target_ip || row.target_host,
          ssh_user:     row.ssh_user || 'ubuntu',
          ssh_key_path: row.ssh_key_path || '~/.ssh/id_rsa',
          ssh_port:     row.ssh_port || 22,
          db_port:      row.db_port || '',
          db_engine:    row.db_engine || 'mysql',
          db_user:      dbUser,
          db_password:  dbPass,
        }),
      });
      if (statusEl) statusEl.innerHTML = '<span style="color:#86efac;">✓ Done</span>';
      if (resultsEl) resultsEl.innerHTML = buildDbCompareHtml(res, row);
    } catch (err) {
      if (statusEl) statusEl.innerHTML = `<span style="color:#fca5a5;">Error: ${esc(err.message)}</span>`;
    } finally {
      if (runBtn) runBtn.disabled = false;
    }
  };

  function buildDbCompareHtml(res, row) {
    const src = res.source || {};
    const tgt = res.target || {};
    const srcDbs = (src.databases || []).map(d => d.name);
    const tgtDbs = (tgt.databases || []).map(d => d.name);
    const allDbs = [...new Set([...srcDbs, ...tgtDbs])].sort();

    function sideHeader(label, color, ip, data) {
      if (data.error && !data.databases.length) {
        return `<div style="padding:10px;background:#1f1f2e;border-radius:8px;border:1px solid #374151;">
          <div style="font-size:11px;font-weight:700;color:${color};margin-bottom:6px;">${label} (${esc(ip)})</div>
          <div style="font-size:11px;color:#fca5a5;">✗ ${esc(data.error)}</div></div>`;
      }
      return '';
    }

    const srcErr = sideHeader('OSPC SOURCE', '#7dd3fc', row.source_host, src);
    const tgtErr = sideHeader('FLEX TARGET', '#86efac', row.target_ip || row.target_host, tgt);
    if (srcErr || tgtErr) {
      return `<div style="display:flex;flex-direction:column;gap:10px;">${srcErr}${tgtErr}</div>`;
    }

    let html = '';

    // Summary bar
    const srcDbSet = new Set(srcDbs);
    const tgtDbSet = new Set(tgtDbs);
    const matchDbs = allDbs.filter(d => srcDbSet.has(d) && tgtDbSet.has(d));
    const missDbs  = allDbs.filter(d => srcDbSet.has(d) && !tgtDbSet.has(d));
    const extraDbs = allDbs.filter(d => !srcDbSet.has(d) && tgtDbSet.has(d));

    html += `<div style="display:flex;gap:8px;margin-bottom:12px;flex-wrap:wrap;">
      <span style="padding:3px 10px;border-radius:999px;font-size:11px;font-weight:700;background:#16a34a;color:#fff;">✓ Match: ${matchDbs.length}</span>
      ${missDbs.length ? `<span style="padding:3px 10px;border-radius:999px;font-size:11px;font-weight:700;background:#dc2626;color:#fff;">✗ Missing on FLEX: ${missDbs.length}</span>` : ''}
      ${extraDbs.length ? `<span style="padding:3px 10px;border-radius:999px;font-size:11px;font-weight:700;background:#d97706;color:#fff;">+ Extra on FLEX: ${extraDbs.length}</span>` : ''}
    </div>`;

    // Per-database detail
    allDbs.forEach(dbName => {
      const srcDb = (src.databases || []).find(d => d.name === dbName);
      const tgtDb = (tgt.databases || []).find(d => d.name === dbName);
      const onBoth = srcDb && tgtDb;
      const borderColor = !srcDb ? '#d97706' : !tgtDb ? '#dc2626' : '#334155';
      const srcTables = srcDb ? (srcDb.tables || []).map(t => t.name) : [];
      const tgtTables = tgtDb ? (tgtDb.tables || []).map(t => t.name) : [];
      const allTbls = [...new Set([...srcTables, ...tgtTables])].sort();

      html += `<details style="margin-bottom:8px;border:1px solid ${borderColor};border-radius:8px;overflow:hidden;" open>
        <summary style="cursor:pointer;padding:8px 12px;background:#0f172a;font-size:13px;font-weight:700;color:#e2e8f0;list-style:none;display:flex;align-items:center;gap:8px;">
          <span>🗄 ${esc(dbName)}</span>
          ${!srcDb ? '<span style="font-size:10px;color:#d97706;">OSPC only</span>' : ''}
          ${!tgtDb ? '<span style="font-size:10px;color:#dc2626;">Missing on FLEX</span>' : ''}
          ${onBoth ? `<span style="font-size:10px;color:#94a3b8;">${srcTables.length} src / ${tgtTables.length} tgt tables</span>` : ''}
        </summary>
        <div style="padding:10px;background:#111827;">`;

      if (!srcDb) {
        html += `<div style="font-size:11px;color:#fbbf24;margin-bottom:6px;">⚠ Database only exists on FLEX target — not on OSPC source.</div>`;
      } else if (!tgtDb) {
        html += `<div style="font-size:11px;color:#fca5a5;margin-bottom:6px;">✗ Database missing on FLEX target.</div>`;
      }

      if (srcDb && srcDb.error && !srcDb.tables.length) {
        html += `<div style="font-size:11px;color:#fca5a5;">OSPC error: ${esc(srcDb.error)}</div>`;
      }
      if (tgtDb && tgtDb.error && !tgtDb.tables.length) {
        html += `<div style="font-size:11px;color:#fca5a5;">FLEX error: ${esc(tgtDb.error)}</div>`;
      }

      if (allTbls.length) {
        allTbls.forEach(tblName => {
          const srcTbl = srcDb ? (srcDb.tables || []).find(t => t.name === tblName) : null;
          const tgtTbl = tgtDb ? (tgtDb.tables || []).find(t => t.name === tblName) : null;
          const tblBorder = !srcTbl ? '#d97706' : !tgtTbl ? '#dc2626' : '#1e3a5f';
          html += `<details style="margin-bottom:6px;border:1px solid ${tblBorder};border-radius:6px;overflow:hidden;">
            <summary style="cursor:pointer;padding:5px 10px;background:#1e293b;font-size:12px;font-weight:600;color:#cbd5e1;list-style:none;display:flex;align-items:center;gap:6px;">
              📋 ${esc(tblName)}
              ${!srcTbl ? '<span style="font-size:10px;color:#d97706;">FLEX only</span>' : ''}
              ${!tgtTbl ? '<span style="font-size:10px;color:#dc2626;">Missing on FLEX</span>' : ''}
            </summary>
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:0;border-top:1px solid #374151;">
              <div style="padding:8px 10px;border-right:1px solid #374151;">
                <div style="font-size:10px;font-weight:700;color:#7dd3fc;margin-bottom:4px;">OSPC SOURCE — ${esc(row.source_host)}</div>
                ${srcTbl ? (srcTbl.error ? `<div style="font-size:11px;color:#fca5a5;">${esc(srcTbl.error)}</div>` :
                  `<pre style="margin:0;font-size:10px;color:#94a3b8;white-space:pre-wrap;word-break:break-all;max-height:200px;overflow-y:auto;">${esc(srcTbl.sample_rows || '(no rows)')}</pre>`)
                  : '<div style="font-size:11px;color:#6b7280;font-style:italic;">Not present</div>'}
              </div>
              <div style="padding:8px 10px;">
                <div style="font-size:10px;font-weight:700;color:#86efac;margin-bottom:4px;">FLEX TARGET — ${esc(row.target_ip || row.target_host)}</div>
                ${tgtTbl ? (tgtTbl.error ? `<div style="font-size:11px;color:#fca5a5;">${esc(tgtTbl.error)}</div>` :
                  `<pre style="margin:0;font-size:10px;color:#94a3b8;white-space:pre-wrap;word-break:break-all;max-height:200px;overflow-y:auto;">${esc(tgtTbl.sample_rows || '(no rows)')}</pre>`)
                  : '<div style="font-size:11px;color:#6b7280;font-style:italic;">Not present</div>'}
              </div>
            </div>
          </details>`;
        });
      }

      html += `</div></details>`;
    });

    if (!allDbs.length) {
      html += `<div style="font-size:12px;color:#94a3b8;font-style:italic;text-align:center;padding:20px;">No user databases found on either server.</div>`;
    }
    return html;
  }

  async function saveScope() {
    const data = await api('/api/uat/scope', {method: 'POST', body: JSON.stringify({rows: UAT.scope})});
    UAT.scope = data.rows;
    renderScope();
    await refreshReadiness();
    setMessage('UAT scope saved to outputs/uat/uat_scope.csv.');
  }

  window.uatSaveScope = async function () {
    readScopeTable();
    await saveScope();
  };

  function renderChecklist() {
    if (!$('uat-checklist-body')) return;
    $('uat-checklist-body').innerHTML = UAT.checklist.map((row, i) => `
      <tr data-row="${i}">
        <td><input type="checkbox" class="uat-run-select"></td>
        <td><input type="checkbox" ${row.checked ? 'checked' : ''}></td>
        <td><strong>${esc(row.category)}</strong><div class="uat-note">${esc(row.task_name)}</div></td>
        <td>${esc(row.description)}</td>
        <td>
          <textarea class="uat-textarea uat-command">${esc(row.command)}</textarea>
          <div class="uat-actions" style="margin-top:6px;">
            <button class="uat-btn" onclick="uatRunChecklistCommand(${i})">Run Test</button>
            <button class="uat-btn" onclick="uatCopyCommand(${i})">Copy Command</button>
            <button class="uat-btn" onclick="uatSaveSingleResult(${i})">Save Result</button>
            <button class="uat-btn" onclick="uatAttachChecklistIssue(${i})">Attach to Issue</button>
          </div>
        </td>
        <td>
          <select class="uat-select">
            ${['Not Started', 'Testing', 'Passed', 'Failed', 'Blocked'].map(s => `<option${s === row.status ? ' selected' : ''}>${s}</option>`).join('')}
          </select>
        </td>
        <td><textarea class="uat-textarea">${esc(row.actual_result)}</textarea></td>
        <td><input class="uat-input" value="${esc(row.owner)}"></td>
        <td>
          <select class="uat-select">
            ${['Low', 'Medium', 'High', 'Critical'].map(s => `<option${s === row.severity_if_failed ? ' selected' : ''}>${s}</option>`).join('')}
          </select>
        </td>
        <td><textarea class="uat-textarea">${esc(row.evidence)}</textarea></td>
      </tr>
    `).join('');
  }

  function readChecklistTable() {
    document.querySelectorAll('#uat-checklist-body tr').forEach((tr, i) => {
      const checked = tr.querySelectorAll('input[type="checkbox"]')[1].checked;
      const textareas = tr.querySelectorAll('textarea');
      const selects = tr.querySelectorAll('select');
      const owner = tr.querySelector('input.uat-input').value;
      UAT.checklist[i] = {
        ...UAT.checklist[i],
        checked,
        command: textareas[0].value,
        status: selects[0].value,
        actual_result: textareas[1].value,
        owner,
        severity_if_failed: selects[1].value,
        evidence: textareas[2].value,
      };
    });
    return UAT.checklist;
  }

  window.uatCopyCommand = async function (index) {
    const cmd = document.querySelectorAll('#uat-checklist-body tr')[index]?.querySelector('textarea')?.value || '';
    await navigator.clipboard.writeText(cmd);
    setMessage('Command copied.');
  };

  window.uatSaveChecklist = async function () {
    readChecklistTable();
    await api('/api/uat/checklist', {method: 'POST', body: JSON.stringify({rows: UAT.checklist})});
    await refreshReadiness();
    setMessage('Checklist saved to outputs/uat/uat_checklist.json.');
  };

  function renderExecutionSystems() {
    const el = $('uat-exec-system');
    if (!el) return;
    el.innerHTML = '<option value="">No linked system</option>' + UAT.scope.map((row, i) => {
      const label = `${row.business_system_name || row.target_host || row.target_ip || 'system'} (${row.execution_mode || 'local'})`;
      return `<option value="${i}">${esc(label)}</option>`;
    }).join('');
  }

  function selectedSystem() {
    const idx = $('uat-exec-system')?.value;
    if (idx === '' || idx == null) return {};
    return UAT.scope[Number(idx)] || {};
  }

  function executionPayloadFor(row, command) {
    const system = selectedSystem();
    const mode = $('uat-exec-mode')?.value || system.execution_mode || 'local';
    return {
      command,
      linked_system: system.business_system_name || system.target_host || '',
      linked_test: row.category || row.id || '',
      execution_mode: mode,
      ssh_user: system.ssh_user || 'ubuntu',
      ssh_host: system.ssh_host || system.target_ip || '',
      ssh_key_path: system.ssh_key_path || '',
      ssh_port: system.ssh_port || 22,
      timeout: $('uat-timeout')?.value || 30,
      confirmed: true,
    };
  }

  window.uatRunChecklistCommand = async function (index) {
    readChecklistTable();
    const row = UAT.checklist[index];
    if (!row || !confirm(`Run UAT command for ${row.category}?`)) return;
    const data = await api('/api/uat/run-command', {method: 'POST', body: JSON.stringify(executionPayloadFor(row, row.command))});
    UAT.command_runs.push(data.run);
    row.actual_result = [data.run.stdout, data.run.stderr, data.run.error].filter(Boolean).join('\n');
    row.status = data.run.status === 'Passed' ? 'Passed' : 'Failed';
    row.checked = data.run.status === 'Passed';
    renderChecklist();
    renderRuns();
    await uatSaveChecklist();
    setMessage(`Run completed: ${data.run.status}`);
  };

  window.uatRunSelectedTests = async function () {
    readChecklistTable();
    const selected = Array.from(document.querySelectorAll('#uat-checklist-body tr')).map((tr, i) => tr.querySelector('.uat-run-select')?.checked ? UAT.checklist[i] : null).filter(Boolean);
    await runBatch(selected);
  };

  window.uatRunAllSafeTests = async function () {
    readChecklistTable();
    await runBatch(UAT.checklist);
  };

  async function runBatch(rows) {
    if (!rows.length) return setMessage('No tests selected.', false);
    if (!confirm(`Run ${rows.length} UAT test command(s)?`)) return;
    const commands = rows.map(row => ({...executionPayloadFor(row, row.command), id: row.id, severity_if_failed: row.severity_if_failed}));
    const data = await api('/api/uat/run-batch', {
      method: 'POST',
      body: JSON.stringify({
        commands,
        confirmed: true,
        stop_on_critical_failure: $('uat-stop-critical')?.checked || false,
      })
    });
    UAT.command_runs.push(...data.runs);
    data.runs.forEach(run => {
      const row = UAT.checklist.find(item => item.category === run.linked_test || item.id === run.linked_test);
      if (row) {
        row.actual_result = [run.stdout, run.stderr, run.error].filter(Boolean).join('\n');
        row.status = run.status === 'Passed' ? 'Passed' : 'Failed';
        row.checked = run.status === 'Passed';
      }
    });
    renderChecklist();
    renderRuns();
    await uatSaveChecklist();
    setMessage(`Batch completed: ${data.runs.length} run(s).`);
  }

  window.uatSaveSingleResult = async function () {
    readChecklistTable();
    await uatSaveChecklist();
  };

  window.uatAttachChecklistIssue = async function (index) {
    readChecklistTable();
    const row = UAT.checklist[index];
    UAT.issues.push({
      issue_id: `UAT-${String(UAT.issues.length + 1).padStart(3, '0')}`,
      linked_system: selectedSystem().business_system_name || '',
      linked_test: row.category,
      severity: row.severity_if_failed || 'Medium',
      owner: row.owner || '',
      status: 'Open',
      description: `${row.category}: ${row.actual_result || 'Manual issue created from checklist.'}`,
      evidence: row.evidence || row.command,
      created_at: '',
      updated_at: '',
    });
    renderIssues();
    await saveIssues();
  };

  function renderPerformance() {
    if (!$('uat-performance-grid')) return;
    const perf = UAT.performance;

    const groups = [
      { label: '⚡ HTTP Performance', accent: '#93c5fd', rows: [
        { label: 'Avg Response (ms)',  src: 'ospc_avg_response_ms',        tgt: 'flex_avg_response_ms',          thresh: 15 },
        { label: 'P95 Response (ms)',  src: 'ospc_p95_ms',                 tgt: 'flex_p95_ms',                   thresh: 15 },
        { label: 'API Error Rate %',   src: 'api_error_rate_percent',      tgt: 'api_error_rate_percent_target', thresh: 1, absVal: true },
      ]},
      { label: '🖥 System Resources', accent: '#86efac', rows: [
        { label: 'CPU Load (1-min)',   src: 'cpu_load_source',             tgt: 'cpu_load_target',               thresh: 30 },
        { label: 'Memory Usage %',     src: 'mem_pct_source',              tgt: 'mem_pct_target',                thresh: 15 },
        { label: 'I/O Wait %',         src: 'iowait_source',               tgt: 'iowait_target',                 thresh: 15 },
      ]},
      { label: '🌐 Network',          accent: '#fde68a', rows: [
        { label: 'Latency (ms)',        src: 'network_latency_ms',          tgt: 'network_latency_ms_target',     thresh: 20 },
        { label: 'Active Sessions',     src: 'active_sessions_tested',      tgt: 'active_sessions_tested_target', thresh: null },
        { label: 'Upload Mbps',         src: 'upload_mbps',                 tgt: 'upload_mbps_target',            thresh: null },
        { label: 'Download Mbps',       src: 'download_mbps',               tgt: 'download_mbps_target',          thresh: null },
      ]},
      { label: '🗄 Database',          accent: '#c4b5fd', rows: [
        { label: 'DB Connect (ms)',     src: 'db_avg_query_ms',             tgt: 'db_avg_query_ms_target',        thresh: 20 },
      ]},
    ];

    function calcDelta(r) {
      const sv = parseFloat(perf[r.src]), tv = parseFloat(perf[r.tgt]);
      const hasS = !isNaN(sv) && perf[r.src] !== '' && perf[r.src] != null;
      const hasT = !isNaN(tv) && perf[r.tgt] !== '' && perf[r.tgt] != null;
      if (!hasS && !hasT) return { text: '—', color: '#475569', status: '', sc: '' };
      if (r.absVal) {
        const mx = Math.max(hasS ? sv : 0, hasT ? tv : 0);
        if (mx === 0)   return { text: '0%',             color: '#86efac', status: 'PASS', sc: '#86efac' };
        if (mx > 5)     return { text: mx.toFixed(1)+'%', color: '#fecaca', status: 'FAIL', sc: '#fecaca' };
        if (mx > 1)     return { text: mx.toFixed(1)+'%', color: '#fde68a', status: 'WARN', sc: '#fde68a' };
        return           { text: mx.toFixed(1)+'%',        color: '#86efac', status: 'PASS', sc: '#86efac' };
      }
      if (!hasS || !hasT || sv === 0) return { text: '—', color: '#475569', status: '', sc: '' };
      const d = (tv - sv) / sv * 100;
      const sign = d > 0 ? '+' : '';
      const txt = sign + d.toFixed(1) + '%';
      if (r.thresh === null) return { text: txt, color: '#94a3b8', status: '', sc: '' };
      const a = Math.abs(d);
      if (a <= r.thresh * 0.5)  return { text: txt, color: '#86efac', status: 'PASS', sc: '#86efac' };
      if (a <= r.thresh)         return { text: txt, color: '#fde68a', status: 'WARN', sc: '#fde68a' };
      return                      { text: txt, color: '#fecaca', status: 'FAIL', sc: '#fecaca' };
    }

    function valCell(name, val) {
      const v = (val == null || val === '') ? '' : val;
      return `<td style="padding:5px 8px;"><input class="uat-input" name="${name}" value="${esc(v)}" style="text-align:right;min-width:120px;background:rgba(15,25,60,0.6);border-color:rgba(148,163,184,0.15);color:#e2e8f0;"></td>`;
    }

    const tbody = groups.map(g => {
      const hdr = `<tr><td colspan="5" style="padding:5px 10px 4px;background:rgba(15,30,80,0.7);color:${g.accent};font-size:10px;font-weight:800;text-transform:uppercase;letter-spacing:.09em;">${g.label}</td></tr>`;
      const rows = g.rows.map(r => {
        const d = calcDelta(r);
        const badge = d.status
          ? `<span style="display:inline-block;padding:2px 9px;border-radius:999px;font-size:10px;font-weight:800;letter-spacing:.04em;color:${d.sc};background:${d.sc}20;border:1px solid ${d.sc}55;">${d.status}</span>`
          : `<span style="color:#475569;font-size:12px;">—</span>`;
        return `<tr style="border-bottom:1px solid rgba(148,163,184,0.07);">
          <td style="padding:7px 10px;color:#cbd5e1;font-size:12px;white-space:nowrap;">${esc(r.label)}</td>
          ${valCell(r.src, perf[r.src])}
          ${valCell(r.tgt, perf[r.tgt])}
          <td style="padding:7px 10px;text-align:center;font-weight:700;font-size:12px;color:${d.color};white-space:nowrap;">${d.text}</td>
          <td style="padding:7px 10px;text-align:center;">${badge}</td>
        </tr>`;
      }).join('');
      return hdr + rows;
    }).join('');

    $('uat-performance-grid').innerHTML = `
      <div class="uat-table-wrap" style="grid-column:1/-1;">
        <table class="uat-table" style="min-width:unset;border-collapse:collapse;">
          <thead>
            <tr style="background:rgba(10,20,60,0.9);">
              <th style="width:190px;color:#bfdbfe;text-align:left;">METRIC</th>
              <th style="color:#93c5fd;text-align:center;min-width:160px;">SOURCE SERVER</th>
              <th style="color:#86efac;text-align:center;min-width:160px;">TARGET SERVER</th>
              <th style="width:90px;color:#e2e8f0;text-align:center;">DELTA</th>
              <th style="width:90px;color:#e2e8f0;text-align:center;">STATUS</th>
            </tr>
          </thead>
          <tbody>${tbody}</tbody>
        </table>
      </div>
      <div style="grid-column:1/-1;margin-top:10px;display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px;padding:10px;background:rgba(15,30,80,0.4);border-radius:8px;border:1px solid rgba(148,163,184,0.1);">
        <label style="color:#bfdbfe;font-size:11px;text-transform:uppercase;letter-spacing:.05em;display:flex;flex-direction:column;gap:4px;">Target Concurrent Users<input class="uat-input" name="target_concurrent_users" value="${esc(perf.target_concurrent_users||'')}"></label>
        <label style="color:#bfdbfe;font-size:11px;text-transform:uppercase;letter-spacing:.05em;display:flex;flex-direction:column;gap:4px;">Peak Users Tested<input class="uat-input" name="peak_concurrent_users_tested" value="${esc(perf.peak_concurrent_users_tested||'')}"></label>
        <label style="color:#bfdbfe;font-size:11px;text-transform:uppercase;letter-spacing:.05em;display:flex;flex-direction:column;gap:4px;">Mobile Lag Status<select class="uat-select" name="mobile_lag_status">${['Pass','Review','Failed'].map(s=>`<option${s===(perf.mobile_lag_status||'Pass')?' selected':''}>${s}</option>`).join('')}</select></label>
      </div>
    `;

    const avg = perf.delta_avg_response_percent;
    const p95v = perf.delta_p95_percent;
    if (!$('uat-performance-status')) return;
    $('uat-performance-status').innerHTML = `
      <div class="uat-stat"><div class="uat-stat-label">Avg Response Delta</div><div class="uat-stat-value">${avg == null ? '—' : avg.toFixed(1)+'%'}</div></div>
      <div class="uat-stat"><div class="uat-stat-label">P95 Delta</div><div class="uat-stat-value">${p95v == null ? '—' : p95v.toFixed(1)+'%'}</div></div>
      <div class="uat-stat"><div class="uat-stat-label">Performance Status</div><div class="uat-stat-value">${badge(perf.overall_performance_status || 'Review')}</div></div>
    `;
  }

  function readPerformanceForm() {
    return UAT.performance;
  }

  window.uatSavePerformance = async function () {
    const data = await api('/api/uat/performance', {method: 'POST', body: JSON.stringify({performance: readPerformanceForm()})});
    UAT.performance = data.performance;
    renderPerformance();
    await refreshReadiness();
    setMessage('Performance saved to outputs/uat/uat_performance.json.');
  };

  function renderIssues() {
    if (!$('uat-issues-body')) return;
    $('uat-issues-body').innerHTML = UAT.issues.map((row, i) => `
      <tr data-row="${i}">
        <td><input class="uat-input" value="${esc(row.issue_id)}"></td>
        <td><input class="uat-input" value="${esc(row.linked_system)}"></td>
        <td><input class="uat-input" value="${esc(row.linked_test)}"></td>
        <td><select class="uat-select">${['Low', 'Medium', 'High', 'Critical'].map(s => `<option${s === row.severity ? ' selected' : ''}>${s}</option>`).join('')}</select></td>
        <td><input class="uat-input" value="${esc(row.owner)}"></td>
        <td><select class="uat-select">${['Open', 'Investigating', 'Fixed', 'Accepted Risk'].map(s => `<option${s === row.status ? ' selected' : ''}>${s}</option>`).join('')}</select></td>
        <td><textarea class="uat-textarea">${esc(row.description)}</textarea></td>
        <td><textarea class="uat-textarea">${esc(row.evidence)}</textarea></td>
        <td><button class="uat-btn uat-btn-danger" onclick="uatDeleteIssue(${i})">Delete</button></td>
      </tr>
    `).join('');
  }

  function readIssuesTable() {
    document.querySelectorAll('#uat-issues-body tr').forEach((tr, i) => {
      const inputs = tr.querySelectorAll('input');
      const selects = tr.querySelectorAll('select');
      const textareas = tr.querySelectorAll('textarea');
      UAT.issues[i] = {
        ...UAT.issues[i],
        issue_id: inputs[0].value,
        linked_system: inputs[1].value,
        linked_test: inputs[2].value,
        severity: selects[0].value,
        owner: inputs[3].value,
        status: selects[1].value,
        description: textareas[0].value,
        evidence: textareas[1].value,
      };
    });
    return UAT.issues;
  }

  window.uatAddIssue = function () {
    UAT.issues.push({
      issue_id: `UAT-${String(UAT.issues.length + 1).padStart(3, '0')}`,
      linked_system: '',
      linked_test: '',
      severity: 'Medium',
      owner: '',
      status: 'Open',
      description: '',
      evidence: '',
      created_at: '',
      updated_at: '',
    });
    renderIssues();
  };

  window.uatDeleteIssue = async function (index) {
    readIssuesTable();
    UAT.issues.splice(index, 1);
    await saveIssues();
  };

  async function saveIssues() {
    const data = await api('/api/uat/issues', {method: 'POST', body: JSON.stringify({rows: UAT.issues})});
    UAT.issues = data.rows;
    renderIssues();
    await refreshReadiness();
    setMessage('Issues saved to outputs/uat/uat_issues.csv.');
  }

  window.uatSaveIssues = async function () {
    readIssuesTable();
    await saveIssues();
  };

  function renderReadiness() {
    if (!$('uat-readiness-panel')) return;
    var a = calculateUatReadinessAnalysis();

    // Decision banner colors
    var overallColor  = a.cutoverDecision === 'READY' ? '#15803d' : a.cutoverDecision === 'READY WITH CONDITIONS' ? '#b45309' : '#b91c1c';
    var overallBg     = a.cutoverDecision === 'READY' ? '#f0fdf4' : a.cutoverDecision === 'READY WITH CONDITIONS' ? '#fffbeb' : '#fef2f2';
    var overallBorder = a.cutoverDecision === 'READY' ? '#86efac' : a.cutoverDecision === 'READY WITH CONDITIONS' ? '#fde68a' : '#fecaca';
    var decisionText  = 'UAT RESULT: ' + a.cutoverDecision + ' FOR CUTOVER';
    var decisionIcon  = a.cutoverDecision === 'READY' ? '✓' : a.cutoverDecision === 'READY WITH CONDITIONS' ? '⚠' : '✗';

    // Evidence row helper
    var evColor = { pass:'#15803d', fail:'#b91c1c', warning:'#b45309', info:'#475569', nt:'#64748b', oos:'#94a3b8' };
    var evIcon  = { pass:'✓', fail:'✗', warning:'⚠', info:'ℹ', nt:'○', oos:'—' };
    function evRow(e) {
      var c = evColor[e.type] || '#475569';
      var i = evIcon[e.type] || '·';
      return '<div style="font-size:11px;color:' + c + ';padding:2px 0;line-height:1.5;">' + i + ' ' + esc(e.text) + '</div>';
    }

    // ── WHY THIS DECISION? panel ─────────────────────────────────────────────
    var whyBlockHtml = a.blockingItems.length
      ? a.blockingItems.map(function(s){ return evRow({type:'fail', text:s}); }).join('')
      : '<div style="font-size:11px;color:#15803d;">Nothing blocking — all checks pass.</div>';
    var whyReviewHtml = a.reviewItems.length
      ? a.reviewItems.map(function(s){ return evRow({type:'warning', text:s}); }).join('')
      : '<div style="font-size:11px;color:#64748b;">Nothing needs review.</div>';
    var whyGoodHtml = a.goodNews.length
      ? a.goodNews.map(function(s){ return evRow({type:'pass', text:s}); }).join('')
      : '<div style="font-size:11px;color:#64748b;">No items passing yet.</div>';
    var whyOosHtml = a.oosItems.length
      ? a.oosItems.map(function(o){ return evRow({type:'oos', text:o.label + ' — ' + o.detail}); }).join('')
      : '<div style="font-size:11px;color:#64748b;">No checks excluded.</div>';

    var whyPanel = '<div style="background:#f8fafc;border-top:1px solid #e2e8f0;">'
      + '<div style="padding:8px 14px 4px;font-size:10px;font-weight:800;color:#475569;text-transform:uppercase;letter-spacing:.08em;">Why This Decision?</div>'
      + '<div style="padding:0 14px 12px;display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px;">'
      + '<div>'
        + '<div style="font-size:10px;font-weight:700;color:#b91c1c;text-transform:uppercase;letter-spacing:.05em;margin-bottom:5px;padding-bottom:3px;border-bottom:1px solid #fee2e2;">Blocking</div>'
        + whyBlockHtml + '</div>'
      + '<div>'
        + '<div style="font-size:10px;font-weight:700;color:#b45309;text-transform:uppercase;letter-spacing:.05em;margin-bottom:5px;padding-bottom:3px;border-bottom:1px solid #fef3c7;">Needs Review / Warnings</div>'
        + whyReviewHtml
        + '<div style="font-size:10px;font-weight:700;color:#15803d;text-transform:uppercase;letter-spacing:.05em;margin-bottom:5px;margin-top:10px;padding-bottom:3px;border-bottom:1px solid #dcfce7;">Positive Evidence</div>'
        + whyGoodHtml + '</div>'
      + '<div>'
        + '<div style="font-size:10px;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:.05em;margin-bottom:5px;padding-bottom:3px;border-bottom:1px solid #e2e8f0;">Out of Scope</div>'
        + whyOosHtml + '</div>'
      + '</div>';

    // Service evidence sub-row
    if (a.svcEvidence.length > 0) {
      var svcEvidenceHtml = a.svcEvidence.map(evRow).join('');
      var svcEvidenceLabel = a.svcRan ? 'Step 2 Service Comparison · Live' : 'Step 2 Service Comparison · Not yet run';
      whyPanel += '<div style="margin:0 14px 10px;padding:8px 12px;background:#ffffff;border:1px solid #e2e8f0;border-radius:6px;">'
        + '<div style="font-size:10px;font-weight:700;color:#475569;text-transform:uppercase;letter-spacing:.05em;margin-bottom:4px;">' + svcEvidenceLabel + '</div>'
        + svcEvidenceHtml + '</div>';
    }

    // Performance evidence sub-row (only when live metrics exist)
    if (a.perfMetrics.length > 0) {
      var perfEvidenceHtml = a.perfEvidence.map(evRow).join('');
      whyPanel += '<div style="margin:0 14px 12px;padding:8px 12px;background:#ffffff;border:1px solid #e2e8f0;border-radius:6px;">'
        + '<div style="font-size:10px;font-weight:700;color:#475569;text-transform:uppercase;letter-spacing:.05em;margin-bottom:4px;">Step 3 SSH Performance Test · Live</div>'
        + perfEvidenceHtml + '</div>';
    }

    whyPanel += '</div>';

    // ── THREE-COLUMN: Good / Blocking / Needs Review ──────────────────────────
    var reviewWarnItems = [];
    a.svcReviewGaps.forEach(function(s){ reviewWarnItems.push('⚠ ' + s.service + ' — needs review'); });
    a.svcWarnings.forEach(function(s){ reviewWarnItems.push('~ ' + s.service + ' — verify'); });

    var threeCol = '<div style="display:grid;grid-template-columns:1fr 1fr 1fr;border-bottom:1px solid #e2e8f0;">'
      + '<div style="padding:12px 14px;border-right:1px solid #e2e8f0;">'
        + '<div style="font-size:10px;font-weight:800;color:#15803d;text-transform:uppercase;letter-spacing:.08em;margin-bottom:6px;">Passed / Good</div>'
        + (a.goodNews.length
          ? a.goodNews.map(function(n){ return '<div style="font-size:11px;color:#15803d;padding:1px 0;">✓ ' + esc(n) + '</div>'; }).join('')
          : '<div style="font-size:11px;color:#64748b;">No items passing yet.</div>')
        + '</div>'
      + '<div style="padding:12px 14px;border-right:1px solid #e2e8f0;">'
        + '<div style="font-size:10px;font-weight:800;color:#b91c1c;text-transform:uppercase;letter-spacing:.08em;margin-bottom:6px;">Blocking (' + a.blocking + ')</div>'
        + (a.blockingItems.length
          ? a.blockingItems.map(function(n){ return '<div style="font-size:11px;color:#b91c1c;padding:1px 0;">✗ ' + esc(n) + '</div>'; }).join('')
          : '<div style="font-size:11px;color:#15803d;">No blockers.</div>')
        + '</div>'
      + '<div style="padding:12px 14px;">'
        + '<div style="font-size:10px;font-weight:800;color:#b45309;text-transform:uppercase;letter-spacing:.08em;margin-bottom:6px;">Needs Review (' + (a.svcReviewGaps.length + a.svcWarnings.length) + ')</div>'
        + (reviewWarnItems.length
          ? reviewWarnItems.map(function(n){ return '<div style="font-size:11px;color:#b45309;padding:1px 0;">' + esc(n) + '</div>'; }).join('')
          : '<div style="font-size:11px;color:#64748b;">Nothing needs review.</div>')
        + '</div>'
      + '</div>';

    // ── NEXT STEPS ────────────────────────────────────────────────────────────
    var nextStepsHtml = '<div style="padding:12px 14px;background:#f8fafc;border-bottom:1px solid #e2e8f0;">'
      + '<div style="font-size:10px;font-weight:800;color:#475569;text-transform:uppercase;letter-spacing:.08em;margin-bottom:5px;">Next Steps</div>'
      + '<ol style="margin:0;padding-left:18px;font-size:11px;color:#334155;line-height:1.9;">'
      + a.nextActions.map(function(action) {
          return '<li><strong>' + esc(action.title) + '</strong> — ' + esc(action.action)
            + ' <span style="color:#94a3b8;">(' + esc(action.impact) + ')</span></li>';
        }).join('')
      + '</ol></div>';

    // ── SCOPE-AWARE CHECKS TABLE ──────────────────────────────────────────────
    // Pre-index command runs by linked_test for O(1) lookup
    var runsByTest = {};
    (UAT.command_runs || []).forEach(function(run) {
      var t = run.linked_test || '';
      if (!runsByTest[t]) runsByTest[t] = [];
      runsByTest[t].push(run);
    });

    var checkRows = a.checks.map(function(c) {
      if (c.outOfScope || c.notTested) {
        return '<tr style="border-bottom:1px solid #f1f5f9;background:#f8fafc;">'
          + '<td style="padding:9px 12px;text-align:center;vertical-align:top;width:32px;"><span style="font-size:13px;color:#94a3b8;">—</span></td>'
          + '<td style="padding:9px 12px;vertical-align:top;">'
          + '<div style="font-weight:600;font-size:12px;color:#94a3b8;">' + esc(c.label) + '</div>'
          + '<div style="font-size:11px;color:#94a3b8;margin-top:1px;">' + esc(c.detail) + '</div>'
          + '<div style="font-size:11px;color:#64748b;margin-top:2px;">Source: ' + esc(c.source) + '</div>'
          + '</td>'
          + '<td style="padding:9px 12px;text-align:right;vertical-align:top;white-space:nowrap;"><span style="font-size:10px;font-weight:700;color:#94a3b8;letter-spacing:.04em;">OUT OF SCOPE</span></td>'
          + '</tr>';
      }
      var color = c.pass ? '#15803d' : '#b91c1c';

      // Find the last failed command run for this check
      var failedRunHtml = '';
      if (!c.pass && c.linkedTest) {
        var runs = runsByTest[c.linkedTest] || [];
        // Last run overall for this test
        var lastRun = runs.length ? runs[runs.length - 1] : null;
        // Prefer a genuinely failed run
        var failedRun = null;
        for (var ri = runs.length - 1; ri >= 0; ri--) {
          if (runs[ri].status === 'Failed' || runs[ri].status === 'Timeout' || runs[ri].status === 'Blocked') {
            failedRun = runs[ri];
            break;
          }
        }
        var displayRun = failedRun || lastRun;
        if (displayRun) {
          var runStatus = displayRun.status || 'Unknown';
          var runCmd    = displayRun.command || '';
          var runErr    = (displayRun.stderr || displayRun.error || '').trim();
          var runOut    = (displayRun.stdout || '').trim();
          var runAt     = displayRun.started_at || '';
          var errText   = runErr || runOut || '(no output captured)';
          // Truncate long output
          if (errText.length > 400) errText = errText.slice(0, 400) + '…';
          var statusColor = runStatus === 'Passed' ? '#15803d' : '#b91c1c';
          failedRunHtml = '<div style="margin-top:6px;background:#1e1e2e;border:1px solid #374151;border-radius:6px;overflow:hidden;">'
            + '<div style="display:flex;align-items:center;gap:8px;padding:5px 10px;background:#111827;border-bottom:1px solid #374151;">'
            + '<span style="font-size:10px;font-weight:700;color:#94a3b8;text-transform:uppercase;letter-spacing:.05em;">Last run</span>'
            + '<span style="font-size:10px;font-weight:800;color:' + statusColor + ';">' + esc(runStatus) + '</span>'
            + (runAt ? '<span style="font-size:10px;color:#4b5563;margin-left:auto;">' + esc(runAt) + '</span>' : '')
            + '</div>'
            + '<div style="padding:6px 10px;font-family:\'JetBrains Mono\',monospace;font-size:11px;">'
            + '<div style="color:#7dd3fc;margin-bottom:3px;">$ ' + esc(runCmd) + '</div>'
            + '<div style="color:#fca5a5;white-space:pre-wrap;word-break:break-all;">' + esc(errText) + '</div>'
            + '</div></div>';
        } else {
          failedRunHtml = '<div style="margin-top:5px;font-size:11px;color:#94a3b8;font-style:italic;">No command run recorded for this test yet.</div>';
        }
      }

      return '<tr style="border-bottom:1px solid #f1f5f9;background:#ffffff;" onmouseenter="this.style.background=\'#f8fafc\'" onmouseleave="this.style.background=\'#ffffff\'">'
        + '<td style="padding:9px 12px;text-align:center;vertical-align:top;width:32px;">'
        + '<span style="font-size:15px;font-weight:900;color:' + color + ';">' + (c.pass ? '✓' : '✗') + '</span></td>'
        + '<td style="padding:9px 12px;vertical-align:top;">'
        + '<div style="font-weight:600;font-size:12px;color:#1e293b;">' + esc(c.label) + '</div>'
        + '<div style="font-size:11px;color:#64748b;margin-top:1px;">' + esc(c.detail) + '</div>'
        + '<div style="font-size:11px;color:#94a3b8;margin-top:2px;">Source: ' + esc(c.source) + '</div>'
        + (!c.pass ? '<div style="font-size:11px;color:#92400e;margin-top:3px;">→ ' + esc(c.fix) + '</div>' : '')
        + failedRunHtml
        + '</td>'
        + '<td style="padding:9px 12px;text-align:right;vertical-align:top;white-space:nowrap;">' + badge(c.pass ? 'pass' : 'fail') + '</td>'
        + '</tr>';
    }).join('');

    // ── LIVE SERVICE COMPARISON DETAIL ────────────────────────────────────────
    var svcHtml = '';
    if (a.svcRan && a.svcTotal > 0) {
      var hasGaps = a.svcReviewGaps.length > 0;
      var sc2 = hasGaps ? '#b45309' : '#15803d';
      var sb2 = hasGaps ? '#fffbeb' : '#f0fdf4';
      var sbd2 = hasGaps ? '#fde68a' : '#86efac';
      var catRows = [
        { label:'Acceptable / Matching', count: a.svcAcceptable,       status:'Pass',   note:'Matched, expected absent on FLEX, or expected FLEX-only service' },
        { label:'Needs Review',          count: a.svcReviewGaps.length, status: hasGaps ? 'Review' : 'Pass', note:'Not a known platform difference — verify before cutover' },
        { label:'Service Warnings',      count: a.svcWarnings.length,   status: a.svcWarnings.length > 0 ? 'Warn' : 'Pass', note:'Extra on FLEX — verify whether expected' },
      ].map(function(c) {
        var cc = c.status === 'Pass' ? '#15803d' : '#b45309';
        var cb = c.status === 'Pass' ? '#f0fdf4'  : '#fffbeb';
        return '<tr style="border-bottom:1px solid #f1f5f9;background:#ffffff;">'
          + '<td style="padding:7px 12px;color:#1e293b;font-size:12px;">' + esc(c.label) + '</td>'
          + '<td style="padding:7px 12px;text-align:center;font-weight:700;color:#1e293b;font-size:13px;">' + c.count + '</td>'
          + '<td style="padding:7px 12px;text-align:center;"><span style="display:inline-block;padding:2px 9px;border-radius:999px;font-size:10px;font-weight:800;color:' + cc + ';background:' + cb + ';border:1px solid ' + cc + '44;">' + esc(c.status) + '</span></td>'
          + '<td style="padding:7px 12px;color:#64748b;font-size:11px;">' + esc(c.note) + '</td>'
          + '</tr>';
      }).join('');

      var reviewCards = a.svcReviewGaps.map(function(item, idx) {
        var svcId = 'svc-review-card-' + idx;
        var svcEsc = esc(item.service).replace(/'/g, '\\x27');
        return '<div id="' + svcId + '" style="margin-top:10px;padding:12px 14px;background:#fffbeb;border:1px solid #fde68a;border-radius:8px;">'
          + '<div style="display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:6px;margin-bottom:6px;">'
          + '<div style="font-weight:700;font-size:13px;color:#92400e;">' + esc(item.service) + '</div>'
          + '<span style="display:inline-block;padding:2px 9px;border-radius:999px;font-size:10px;font-weight:800;color:#b45309;background:#fffbeb;border:1px solid #fde68a;">Needs Review</span>'
          + '</div>'
          + '<div style="font-size:12px;color:#334155;margin-bottom:2px;">' + esc(item.status) + '</div>'
          + '<div style="font-size:11px;color:#64748b;margin-bottom:6px;">Not a known hypervisor/platform difference. Verify if this service should run on FLEX, or accept with owner approval.</div>'
          + '<div id="' + svcId + '-status" style="font-size:11px;min-height:14px;margin-bottom:4px;"></div>'
          + '<div style="display:flex;gap:6px;flex-wrap:wrap;margin-top:6px;">'
          + '<button class="uat-btn" style="font-size:11px;padding:4px 10px;" onclick="svcServiceAction(\'' + svcEsc + '\',\'start\',\'' + svcId + '\')">Start Service</button>'
          + '<button class="uat-btn" style="font-size:11px;padding:4px 10px;" onclick="svcServiceAction(\'' + svcEsc + '\',\'accept\',\'' + svcId + '\')">Accept as Known Difference</button>'
          + '<button class="uat-btn" style="font-size:11px;padding:4px 10px;" onclick="svcServiceAction(\'' + svcEsc + '\',\'issue\',\'' + svcId + '\')">Open Issue</button>'
          + '</div></div>';
      }).join('');

      var warningCards = a.svcWarnings.map(function(item) {
        return '<div style="margin-top:6px;padding:10px 14px;background:#fffbeb;border:1px solid #fbbf24;border-radius:8px;">'
          + '<div style="display:flex;align-items:center;justify-content:space-between;gap:6px;margin-bottom:4px;">'
          + '<div style="font-weight:600;font-size:12px;color:#92400e;">' + esc(item.service) + '</div>'
          + '<span style="display:inline-block;padding:2px 9px;border-radius:999px;font-size:10px;font-weight:800;color:#b45309;background:#fffbeb;border:1px solid #fbbf24;">Extra on FLEX — Verify</span>'
          + '</div>'
          + '<div style="font-size:11px;color:#64748b;">Confirm whether this extra service is expected from the FLEX base image. Accept or remove per your deployment policy.</div>'
          + '</div>';
      }).join('');

      svcHtml = '<div style="background:#ffffff;border:1px solid #e2e8f0;border-radius:10px;overflow:hidden;">'
        + '<div style="display:flex;align-items:center;justify-content:space-between;padding:10px 14px;background:' + sb2 + ';border-bottom:1px solid ' + sbd2 + ';flex-wrap:wrap;gap:6px;">'
        + '<div style="font-size:12px;font-weight:800;color:' + sc2 + ';letter-spacing:.04em;">SERVICE COMPARISON: ' + esc(hasGaps ? 'REVIEW NEEDED' : 'PASS') + ' <span style="font-weight:400;font-size:11px;color:#475569;">· Live from Step 2</span></div>'
        + '<div style="font-size:11px;color:#475569;">' + a.svcTotal + ' OSPC services · ' + a.svcAcceptable + ' acceptable</div>'
        + '</div>'
        + '<div style="overflow-x:auto;"><table style="width:100%;border-collapse:collapse;font-size:12px;">'
        + '<thead><tr style="background:#f8fafc;">'
        + '<th style="padding:7px 12px;text-align:left;color:#475569;font-size:10px;text-transform:uppercase;letter-spacing:.06em;border-bottom:1px solid #e2e8f0;font-weight:600;">Category</th>'
        + '<th style="padding:7px 12px;text-align:center;color:#475569;font-size:10px;text-transform:uppercase;letter-spacing:.06em;border-bottom:1px solid #e2e8f0;font-weight:600;">Count</th>'
        + '<th style="padding:7px 12px;text-align:center;color:#475569;font-size:10px;text-transform:uppercase;letter-spacing:.06em;border-bottom:1px solid #e2e8f0;font-weight:600;">Status</th>'
        + '<th style="padding:7px 12px;text-align:left;color:#475569;font-size:10px;text-transform:uppercase;letter-spacing:.06em;border-bottom:1px solid #e2e8f0;font-weight:600;">Note</th>'
        + '</tr></thead><tbody>' + catRows + '</tbody></table></div>'
        + (reviewCards || warningCards ? '<div style="padding:12px 14px;">' + reviewCards + warningCards + '</div>' : '')
        + '</div>';
    } else if (!a.svcRan) {
      svcHtml = '<div style="padding:12px 14px;background:#fffbeb;border:1px solid #fde68a;border-radius:8px;font-size:12px;color:#92400e;">'
        + '<strong>⚠ Service Comparison not run this session.</strong> Go to Step 2 — Service Comparison and click <strong>Compare Services</strong> to populate live service data here. Step 5 will update automatically.'
        + '</div>';
    }

    $('uat-readiness-panel').innerHTML =
      '<div style="background:#ffffff;border-radius:10px;overflow:hidden;border:1px solid #e2e8f0;">'

      // Decision banner
      + '<div style="display:flex;align-items:center;gap:12px;padding:14px 16px;background:' + overallBg + ';border-bottom:1px solid ' + overallBorder + ';">'
      + '<div style="font-size:26px;font-weight:900;color:' + overallColor + ';line-height:1;">' + decisionIcon + '</div>'
      + '<div style="flex:1;min-width:0;">'
      + '<div style="font-size:14px;font-weight:800;color:' + overallColor + ';letter-spacing:.03em;">' + esc(decisionText) + '</div>'
      + '<div style="font-size:11px;color:#475569;margin-top:2px;">'
        + a.passed + '/' + a.total + ' checks passed · ' + a.pct + '% readiness score'
        + ' · ' + a.blocking + ' blocker(s) · ' + a.svcReviewGaps.length + ' service gap(s) needing review'
      + '</div></div></div>'

      // Three-column: Good / Blocking / Review
      + threeCol

      // Why this decision
      + whyPanel

      // Next steps
      + nextStepsHtml

      // Checks table
      + '<table style="width:100%;border-collapse:collapse;background:#ffffff;">'
      + '<thead><tr style="background:#f8fafc;">'
      + '<th style="padding:7px 12px;text-align:center;color:#475569;font-size:10px;text-transform:uppercase;letter-spacing:.06em;border-bottom:1px solid #e2e8f0;font-weight:600;width:32px;"></th>'
      + '<th style="padding:7px 12px;text-align:left;color:#475569;font-size:10px;text-transform:uppercase;letter-spacing:.06em;border-bottom:1px solid #e2e8f0;font-weight:600;">Check · Evidence Source</th>'
      + '<th style="padding:7px 12px;text-align:right;color:#475569;font-size:10px;text-transform:uppercase;letter-spacing:.06em;border-bottom:1px solid #e2e8f0;font-weight:600;width:90px;">Result</th>'
      + '</tr></thead><tbody>' + checkRows + '</tbody></table>'

      + '</div>'
      + (svcHtml ? '<div style="margin-top:12px;">' + svcHtml + '</div>' : '');
  }

  // ── Live data injection from combined.html ───────────────────────────────
  // Called by svcCompareRun() after service classification
  window.uatSetServiceComparison = function(data) {
    UAT.serviceComparison = Object.assign(UAT.serviceComparison || {}, data);
    renderSummary();
    renderReadiness();
  };

  // Called by buildPerfTable() after computing overall status
  window.uatSetPerfMetrics = function(metrics, overall) {
    UAT.performance.metrics = metrics;
    UAT.performance.overall_status = overall;
    renderSummary();
    renderReadiness();
  };

  // General re-render trigger (called after any live data update)
  window.uatRerenderReadiness = function() { renderSummary(); renderReadiness(); };

  function renderRuns() {
    if (!$('uat-runs-body')) return;
    const rows = (UAT.command_runs || []).slice(-100).reverse();
    $('uat-runs-body').innerHTML = rows.map(run => `
      <tr>
        <td>${esc(run.started_at)}</td>
        <td>${esc(run.linked_system)}</td>
        <td>${esc(run.linked_test)}</td>
        <td>${esc(run.execution_mode)}</td>
        <td>${badge(run.status)}</td>
        <td>${esc(run.exit_code)}</td>
        <td>${esc(run.duration_seconds)}</td>
        <td><pre class="uat-preview" style="max-height:90px;">${esc(run.command)}</pre></td>
        <td><pre class="uat-preview" style="max-height:120px;">${esc([run.stdout, run.stderr, run.error].filter(Boolean).join('\\n'))}</pre></td>
      </tr>
    `).join('');
  }

  function renderFindings() {
    if (!$('uat-findings-body')) return;
    const rows = UAT.log_findings || [];
    $('uat-findings-body').innerHTML = rows.map((finding, i) => `
      <tr>
        <td>${esc(finding.timestamp)}</td>
        <td>${esc(finding.source_file)}</td>
        <td>${esc(finding.stage)}</td>
        <td>${badge(finding.severity)}</td>
        <td>${esc(finding.category)}</td>
        <td>${esc(finding.linked_system)}</td>
        <td>${esc(finding.message)}</td>
        <td><strong>${esc(finding.suggested_uat_test)}</strong><pre class="uat-preview" style="max-height:100px;">${esc(finding.suggested_command)}</pre></td>
        <td>
          <button class="uat-btn" onclick="uatFindingAction(${i}, 'Create Issue')">Create Issue</button>
          <button class="uat-btn" onclick="uatRunFindingTest(${i})">Run Suggested Test</button>
          <button class="uat-btn" onclick="uatFindingAction(${i}, 'Accepted')">Accepted</button>
          <button class="uat-btn" onclick="uatFindingAction(${i}, 'False Positive')">False Positive</button>
          <div class="uat-note">${esc(finding.status || 'Open')}</div>
        </td>
      </tr>
    `).join('');
  }

  window.uatRefreshFindings = async function (force) {
    const data = await api(`/api/uat/log-findings${force ? '?force=1' : ''}`);
    UAT.log_findings = data.findings;
    renderFindings();
    setMessage('Migration logs rescanned.');
  };

  window.uatFindingAction = async function (index, action) {
    const finding = UAT.log_findings[index];
    if (!finding) return;
    const data = await api('/api/uat/log-findings/action', {method: 'POST', body: JSON.stringify({finding_id: finding.finding_id, action})});
    UAT.log_findings = data.findings;
    UAT.issues = data.issues || UAT.issues;
    renderFindings();
    renderIssues();
    setMessage(`Finding updated: ${action}`);
  };

  window.uatRunFindingTest = async function (index) {
    const finding = UAT.log_findings[index];
    if (!finding || !confirm(`Run suggested test for ${finding.finding_id}?`)) return;
    const data = await api('/api/uat/run-command', {
      method: 'POST',
      body: JSON.stringify(executionPayloadFor({category: finding.suggested_uat_test}, finding.suggested_command)),
    });
    UAT.command_runs.push(data.run);
    renderRuns();
    setMessage(`Suggested test completed: ${data.run.status}`);
  };

  async function refreshReadiness() {
    const data = await api('/api/uat/state');
    UAT.readiness = data.readiness;
    renderSummary();
    renderReadiness();
  }

  window.uatExportReports = async function () {
    readScopeTable();
    readChecklistTable();
    readPerformanceForm();
    readIssuesTable();
    const data = await api('/api/uat/export', {
      method: 'POST',
      body: JSON.stringify({
        scope: UAT.scope,
        checklist: UAT.checklist,
        performance: UAT.performance,
        issues: UAT.issues,
      }),
    });
    UAT.readiness = data.readiness;
    renderReadiness();
    const links = Object.entries(data.reports || {}).map(([name, url]) => `<a class="uat-btn" href="${esc(url)}">${esc(name)}</a>`).join(' ');
    if ($('uat-export-links')) $('uat-export-links').innerHTML = links;
    setMessage('UAT reports exported to outputs/uat/.');
  };

  // ── Service review card actions ──────────────────────────────────────────
  window.svcServiceAction = async function(serviceName, action, cardId) {
    var statusEl = document.getElementById(cardId + '-status');
    function setStatus(msg, color) {
      if (statusEl) statusEl.innerHTML = '<span style="color:' + (color||'#374151') + ';font-weight:600;font-size:11px;">' + msg + '</span>';
    }

    if (action === 'accept') {
      // Remove the card from view and update serviceComparison state
      var card = document.getElementById(cardId);
      if (card) card.style.display = 'none';
      if (UAT.serviceComparison && UAT.serviceComparison.reviewGaps) {
        UAT.serviceComparison.reviewGaps = (UAT.serviceComparison.reviewGaps || []).filter(function(g) { return g.service !== serviceName; });
      }
      if (UAT.serviceComparison && UAT.serviceComparison.rows) {
        UAT.serviceComparison.rows = (UAT.serviceComparison.rows || []).map(function(r) {
          return r.service === serviceName ? Object.assign({}, r, {status: 'accepted_difference'}) : r;
        });
      }
      setStatus('✓ Accepted as known difference', '#15803d');
      setMessage('Accepted "' + serviceName + '" as a known platform difference.');
      return;
    }

    if (action === 'issue') {
      var desc = 'Service missing on FLEX — Not a known platform difference: ' + serviceName;
      var issue = {
        issue_id: 'SVC-' + serviceName.replace(/[^a-z0-9]/gi, '-').toUpperCase(),
        linked_system: serviceName,
        linked_test: 'service-comparison',
        severity: 'High',
        owner: '',
        status: 'Open',
        description: desc,
        evidence: 'Detected via live service comparison (Step 2).',
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };
      UAT.issues = UAT.issues || [];
      // Avoid duplicates
      if (!UAT.issues.find(function(i) { return i.issue_id === issue.issue_id; })) {
        UAT.issues.push(issue);
        renderIssues();
      }
      try {
        await api('/api/uat/issues', {method: 'POST', body: JSON.stringify({issues: UAT.issues})});
      } catch(e) { /* non-blocking */ }
      setStatus('⚠ Issue opened: ' + issue.issue_id, '#b45309');
      setMessage('Issue created for "' + serviceName + '" — visible in Issues table below.');
      return;
    }

    if (action === 'start') {
      var tgtIp   = (document.getElementById('svc-target-ip')  || {}).value || '';
      var sshUser = (document.getElementById('svc-ssh-user')    || {}).value || 'ubuntu';
      var sshKey  = (document.getElementById('svc-ssh-key')     || {}).value || '~/.ssh/id_rsa';
      var sshPort = (document.getElementById('svc-ssh-port')    || {}).value || '22';
      if (!tgtIp) {
        setStatus('Enter Target FLEX IP in Step 2 first.', '#dc2626');
        return;
      }
      setStatus('▲ Starting ' + serviceName + ' on ' + tgtIp + '...', '#f59e0b');
      try {
        var result = await api('/api/uat/run-command', {
          method: 'POST',
          body: JSON.stringify({
            command: 'sudo systemctl start ' + serviceName + ' && sudo systemctl is-active ' + serviceName,
            linked_system: serviceName,
            linked_test: 'start-service',
            execution_mode: 'ssh',
            ssh_user: sshUser,
            ssh_host: tgtIp,
            ssh_key_path: sshKey,
            ssh_port: parseInt(sshPort, 10) || 22,
            timeout: 30,
            confirmed: true,
          })
        });
        UAT.command_runs = UAT.command_runs || [];
        UAT.command_runs.push(result.run);
        renderRuns();
        var ok = result.run.status === 'Passed';
        setStatus(ok ? '✓ Service started successfully' : '✗ Start failed: ' + (result.run.stderr || result.run.error || result.run.stdout || 'see command history'), ok ? '#15803d' : '#dc2626');
        setMessage((ok ? '✓ Started ' : '✗ Failed to start ') + serviceName + ' on ' + tgtIp);
      } catch(e) {
        setStatus('✗ Error: ' + e.message, '#dc2626');
      }
    }
  };

  // ── Full client-side CSV export ───────────────────────────────────────────
  window.uatDownloadFullCsv = function() {
    readScopeTable();
    readChecklistTable();
    readPerformanceForm();
    readIssuesTable();

    var ts   = new Date().toISOString().slice(0, 19).replace('T', ' ');
    var sc   = UAT.serviceComparison || {};
    var perf = UAT.performance || {};
    var readinessStatus = (UAT.readiness || {}).status || 'Not Evaluated';
    var readinessBg  = readinessStatus === 'Ready' ? '#1b5e20' : readinessStatus === 'Ready with Conditions' ? '#e65100' : '#b71c1c';

    // ── helpers ──────────────────────────────────────────────────────────────
    function h(s) { return String(s == null ? '' : s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

    function sectionHeader(title, color, cols) {
      return '<tr><td colspan="' + cols + '" style="background:' + color + ';color:#fff;font-size:13px;font-weight:700;padding:8px 12px;letter-spacing:.04em;border:1px solid ' + color + ';">' + h(title) + '</td></tr>';
    }
    function colHeader(cells, bg) {
      bg = bg || '#1565c0';
      return '<tr>' + cells.map(function(c){
        return '<td style="background:' + bg + ';color:#fff;font-weight:700;font-size:11px;padding:6px 10px;border:1px solid #0d47a1;white-space:nowrap;">' + h(c) + '</td>';
      }).join('') + '</tr>';
    }
    function statusBadge(s) {
      var map = {
        'match':               'background:#c8e6c9;color:#1b5e20;border:1px solid #a5d6a7',
        'missing_on_target':   'background:#ffcdd2;color:#b71c1c;border:1px solid #ef9a9a',
        'extra_on_target':     'background:#fff9c4;color:#f57f17;border:1px solid #fff176',
        'accepted_difference': 'background:#eeeeee;color:#616161;border:1px solid #bdbdbd',
        'passed':  'background:#c8e6c9;color:#1b5e20;border:1px solid #a5d6a7',
        'pass':    'background:#c8e6c9;color:#1b5e20;border:1px solid #a5d6a7',
        'failed':  'background:#ffcdd2;color:#b71c1c;border:1px solid #ef9a9a',
        'fail':    'background:#ffcdd2;color:#b71c1c;border:1px solid #ef9a9a',
        'not started': 'background:#e3f2fd;color:#1565c0;border:1px solid #90caf9',
        'in progress': 'background:#fff8e1;color:#f57f17;border:1px solid #ffe082',
        'blocked': 'background:#ffcdd2;color:#b71c1c;border:1px solid #ef9a9a',
        'open':    'background:#fff9c4;color:#f57f17;border:1px solid #fff176',
        'resolved':'background:#c8e6c9;color:#1b5e20;border:1px solid #a5d6a7',
        'critical':'background:#d32f2f;color:#fff;border:1px solid #b71c1c',
        'high':    'background:#ff7043;color:#fff;border:1px solid #e64a19',
        'medium':  'background:#fff9c4;color:#f57f17;border:1px solid #ffe082',
        'low':     'background:#c8e6c9;color:#1b5e20;border:1px solid #a5d6a7',
      };
      var key = String(s || '').toLowerCase();
      var st  = map[key] || 'background:#f5f5f5;color:#424242;border:1px solid #e0e0e0';
      return '<span style="display:inline-block;padding:2px 8px;border-radius:10px;font-size:10px;font-weight:700;' + st + '">' + h(s) + '</span>';
    }
    function cell(v, extraStyle) {
      return '<td style="padding:5px 10px;border:1px solid #e0e0e0;font-size:11px;vertical-align:middle;' + (extraStyle||'') + '">' + h(v) + '</td>';
    }
    function badgeCell(v) {
      return '<td style="padding:5px 8px;border:1px solid #e0e0e0;text-align:center;vertical-align:middle;">' + statusBadge(v) + '</td>';
    }
    function spacer(cols) {
      return '<tr><td colspan="' + cols + '" style="height:14px;background:#f5f5f5;border:none;"></td></tr>';
    }

    // ── Row background by status ──────────────────────────────────────────────
    function svcRowBg(status) {
      if (status === 'missing_on_target')   return '#fff5f5';
      if (status === 'extra_on_target')     return '#fffde7';
      if (status === 'accepted_difference') return '#fafafa';
      return '#f1f8e9';
    }
    function checklistRowBg(status) {
      var s = String(status || '').toLowerCase();
      if (s === 'passed' || s === 'pass') return '#f1f8e9';
      if (s === 'failed' || s === 'fail') return '#fff5f5';
      if (s === 'blocked')                return '#fff5f5';
      if (s === 'in progress')            return '#fffde7';
      return '#ffffff';
    }
    function issueRowBg(severity) {
      var s = String(severity || '').toLowerCase();
      if (s === 'critical') return '#ffebee';
      if (s === 'high')     return '#fff3e0';
      if (s === 'medium')   return '#fffde7';
      return '#f9fbe7';
    }

    // ── Build HTML ────────────────────────────────────────────────────────────
    var rows = [];

    // ── TITLE HEADER ──
    rows.push('<tr><td colspan="8" style="background:#0d2137;color:#fff;font-size:18px;font-weight:800;padding:16px 20px;letter-spacing:.03em;border:none;">UAT Full Report — OSPC &rarr; FLEX</td></tr>');
    rows.push('<tr>'
      + '<td style="background:#132d46;color:#90caf9;font-size:11px;font-weight:600;padding:6px 20px;border:none;">Generated: ' + h(ts) + '</td>'
      + '<td colspan="3" style="background:#132d46;color:#90caf9;font-size:11px;font-weight:600;padding:6px 20px;border:none;">Readiness Status: '
      + '<span style="background:' + readinessBg + ';color:#fff;padding:2px 10px;border-radius:10px;font-weight:800;">' + h(readinessStatus) + '</span></td>'
      + '<td colspan="4" style="background:#132d46;border:none;"></td>'
      + '</tr>');
    rows.push(spacer(8));

    // ── SECTION 1: Service Comparison ──
    rows.push(sectionHeader('1.  Service Comparison', '#1565c0', 8));
    rows.push(colHeader(['Service', 'On Source (OSPC)', 'On Target (FLEX)', 'Status', 'Notes'], '#1976d2'));
    var svcRows = sc.rows || [];
    if (svcRows.length) {
      svcRows.forEach(function(r) {
        var notes = r.status === 'missing_on_target'   ? 'Missing on FLEX — needs review'
                  : r.status === 'extra_on_target'     ? 'Extra on FLEX — verify'
                  : r.status === 'accepted_difference' ? 'Accepted as known difference'
                  : '';
        var bg = svcRowBg(r.status);
        rows.push('<tr style="background:' + bg + ';">'
          + cell(r.service, 'font-weight:600;')
          + badgeCell(r.on_source ? 'Yes' : 'No')
          + badgeCell(r.on_target ? 'Yes' : 'No')
          + badgeCell(r.status || '')
          + cell(notes)
          + '<td colspan="3" style="border:none;background:' + bg + ';"></td>'
          + '</tr>');
      });
    } else {
      rows.push('<tr><td colspan="8" style="color:#9e9e9e;font-style:italic;padding:8px 12px;border:1px solid #e0e0e0;">No service comparison data — run Step 2 first.</td></tr>');
    }
    rows.push(spacer(8));

    // ── SECTION 2: UAT Checklist ──
    rows.push(sectionHeader('2.  UAT Checklist', '#4527a0', 8));
    rows.push(colHeader(['Category', 'Status', 'Owner', 'Severity if Failed', 'Actual Result', 'Notes'], '#512da8'));
    if ((UAT.checklist || []).length) {
      UAT.checklist.forEach(function(r) {
        var bg = checklistRowBg(r.status);
        rows.push('<tr style="background:' + bg + ';">'
          + cell(r.category, 'font-weight:600;')
          + badgeCell(r.status)
          + cell(r.owner)
          + badgeCell(r.severity_if_failed)
          + cell(r.actual_result)
          + cell(r.notes)
          + '<td colspan="2" style="border:none;background:' + bg + ';"></td>'
          + '</tr>');
      });
    } else {
      rows.push('<tr><td colspan="8" style="color:#9e9e9e;font-style:italic;padding:8px 12px;border:1px solid #e0e0e0;">No checklist data.</td></tr>');
    }
    rows.push(spacer(8));

    // ── SECTION 3: Scope — Systems Under Test ──
    rows.push(sectionHeader('3.  Scope — Systems Under Test', '#1b5e20', 8));
    rows.push(colHeader(['System ID', 'Type', 'Business System Name', 'Tier', 'Source Host', 'Target Host', 'Target IP', 'UAT Status'], '#2e7d32'));
    if ((UAT.scope || []).length) {
      UAT.scope.forEach(function(r) {
        var isReady = String(r.uat_status || '').toLowerCase() === 'passed' || String(r.uat_status || '').toLowerCase() === 'ready';
        var bg = isReady ? '#f1f8e9' : '#ffffff';
        rows.push('<tr style="background:' + bg + ';">'
          + cell(r.system_id, 'font-family:monospace;font-size:11px;')
          + badgeCell(r.system_type)
          + cell(r.business_system_name, 'font-weight:600;')
          + cell(r.tier)
          + cell(r.source_host, 'font-family:monospace;font-size:10px;')
          + cell(r.target_host, 'font-family:monospace;font-size:10px;')
          + cell(r.target_ip, 'font-family:monospace;font-size:10px;')
          + badgeCell(r.uat_status)
          + '</tr>');
      });
    } else {
      rows.push('<tr><td colspan="8" style="color:#9e9e9e;font-style:italic;padding:8px 12px;border:1px solid #e0e0e0;">No scope data.</td></tr>');
    }
    rows.push(spacer(8));

    // ── SECTION 4: Issues ──
    rows.push(sectionHeader('4.  Issues', '#b71c1c', 8));
    rows.push(colHeader(['Issue ID', 'Linked System', 'Severity', 'Status', 'Owner', 'Description', 'Evidence', 'Created'], '#c62828'));
    if ((UAT.issues || []).length) {
      UAT.issues.forEach(function(r) {
        var bg = issueRowBg(r.severity);
        rows.push('<tr style="background:' + bg + ';">'
          + cell(r.issue_id, 'font-family:monospace;font-size:10px;font-weight:700;')
          + cell(r.linked_system)
          + badgeCell(r.severity)
          + badgeCell(r.status)
          + cell(r.owner)
          + cell(r.description)
          + cell(r.evidence, 'font-size:10px;color:#616161;')
          + cell(r.created_at, 'font-size:10px;color:#616161;')
          + '</tr>');
      });
    } else {
      rows.push('<tr><td colspan="8" style="color:#9e9e9e;font-style:italic;padding:8px 12px;border:1px solid #e0e0e0;">No issues recorded.</td></tr>');
    }
    rows.push(spacer(8));

    // ── SECTION 5: Performance Metrics ──
    rows.push(sectionHeader('5.  Performance Metrics', '#e65100', 8));
    rows.push(colHeader(['Metric', 'OSPC (Source)', 'FLEX (Target)', 'Delta', 'Status'], '#ef6c00'));
    var perfDefs = [
      ['Avg Response ms',   'ospc_avg_response_ms',  'flex_avg_response_ms',  '%'],
      ['P95 ms',            'ospc_p95_ms',            'flex_p95_ms',           '%'],
      ['API Error Rate %',  'api_error_rate_percent', '',                      ''],
      ['Network Latency ms','network_latency_ms',     '',                      ''],
      ['DB Avg Query ms',   'db_avg_query_ms',        '',                      ''],
      ['Upload Mbps',       'upload_mbps',            '',                      ''],
      ['Download Mbps',     'download_mbps',          '',                      ''],
    ];
    perfDefs.forEach(function(pd) {
      var ospcVal = perf[pd[1]];
      var flexVal = perf[pd[2]] || '';
      if (ospcVal == null && flexVal === '') return;
      var delta = '', deltaStyle = '';
      if (ospcVal && flexVal && !isNaN(parseFloat(ospcVal)) && !isNaN(parseFloat(flexVal))) {
        var d = ((parseFloat(flexVal) - parseFloat(ospcVal)) / parseFloat(ospcVal) * 100).toFixed(1);
        delta = (d > 0 ? '+' : '') + d + '%';
        deltaStyle = parseFloat(d) > 15 ? 'color:#b71c1c;font-weight:700;' : parseFloat(d) < -5 ? 'color:#1b5e20;font-weight:700;' : 'color:#424242;';
      }
      rows.push('<tr style="background:#fff8f0;">'
        + cell(pd[0], 'font-weight:600;')
        + cell(ospcVal || '—', 'text-align:right;font-family:monospace;')
        + cell(flexVal || '—', 'text-align:right;font-family:monospace;')
        + cell(delta, 'text-align:right;font-family:monospace;' + deltaStyle)
        + badgeCell(parseFloat(delta) > 15 ? 'fail' : (ospcVal ? 'pass' : ''))
        + '<td colspan="3" style="border:none;background:#fff8f0;"></td>'
        + '</tr>');
    });
    // Overall performance status
    var overallPerf = perf.overall_performance_status || perf.overall_status || '';
    if (overallPerf) {
      rows.push('<tr style="background:#fff3e0;"><td style="padding:5px 10px;border:1px solid #e0e0e0;font-weight:700;font-size:11px;">Overall Performance Status</td><td colspan="2" style="border:1px solid #e0e0e0;"></td>'
        + '<td colspan="2" style="border:1px solid #e0e0e0;">' + statusBadge(overallPerf) + '</td>'
        + '<td colspan="3" style="border:none;background:#fff3e0;"></td></tr>');
    }
    rows.push(spacer(8));

    // ── Assemble full HTML ────────────────────────────────────────────────────
    var html = '<!DOCTYPE html>\n<html>\n<head>\n<meta charset="UTF-8">\n'
      + '<style>\n'
      + 'body{font-family:Calibri,Arial,sans-serif;font-size:11px;margin:0;padding:0;}\n'
      + 'table{border-collapse:collapse;width:100%;}\n'
      + 'tr:hover td{filter:brightness(0.97);}\n'
      + '</style>\n'
      + '</head>\n<body>\n'
      + '<table>\n' + rows.join('\n') + '\n</table>\n'
      + '</body>\n</html>';

    var blob = new Blob([html], {type: 'application/vnd.ms-excel;charset=UTF-8'});
    var url  = URL.createObjectURL(blob);
    var a    = document.createElement('a');
    a.href   = url;
    a.download = 'uat_full_report_' + new Date().toISOString().slice(0,10) + '.xls';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    setMessage('UAT full report downloaded as Excel file.');
  };

  window.CloudJumperUAT = {load: loadUAT};
  window.uatRenderPerformance = renderPerformance;
  document.addEventListener('DOMContentLoaded', () => {
    if ($('uat-console')) {
      loadUAT().catch(err => setMessage(err.message, false));
    }
  });

  // Auto-save scope table on any input/change, debounced 800ms
  (function() {
    let _scopeTimer = null;
    document.addEventListener('input', function(e) {
      const tbody = $('uat-scope-body');
      if (tbody && tbody.contains(e.target)) {
        clearTimeout(_scopeTimer);
        _scopeTimer = setTimeout(function() {
          readScopeTable();
          api('/api/uat/scope', {method: 'POST', body: JSON.stringify({rows: UAT.scope})})
            .then(function(data) { UAT.scope = data.rows; })
            .catch(function() {});
        }, 800);
      }
    });
    document.addEventListener('change', function(e) {
      const tbody = $('uat-scope-body');
      if (tbody && tbody.contains(e.target)) {
        clearTimeout(_scopeTimer);
        _scopeTimer = setTimeout(function() {
          readScopeTable();
          api('/api/uat/scope', {method: 'POST', body: JSON.stringify({rows: UAT.scope})})
            .then(function(data) { UAT.scope = data.rows; })
            .catch(function() {});
        }, 800);
      }
    });
  })();
})();
