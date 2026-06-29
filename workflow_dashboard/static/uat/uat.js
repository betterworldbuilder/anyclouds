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
    _persistScopeToStorage();
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
    // Always re-read scope from localStorage so scope card changes take effect immediately
    var wl  = {};
    try { wl = JSON.parse(localStorage.getItem('uat_workload_scope') || 'null') || {}; } catch(e) { wl = UAT.workloadScope || {}; }
    var hasDB = wl.hasDatabase === true;

    // FIX modal user-dismissals (Fixed / Not Relevant per issue key)
    var fixDismissed = {};
    try { fixDismissed = JSON.parse(localStorage.getItem('uat_fix_dismissed') || '{}'); } catch(e) {}

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
    // Live service comparison: use explicit breakdown if available (set by svcCompareRun)
    if (svcRan && sc.matched !== undefined) {
      svcAcceptable = (sc.matched || 0) + (sc.expectedAbsent || 0) + (sc.expectedFlexOnly || 0);
    }

    // Performance — live metrics from uatSetPerfMetrics, fallback to saved API status
    var perfMetrics = UAT.performance.metrics || [];

    // Read user decisions for performance metrics (set via dropdown in Step 3 perf table)
    var perfUserDecisions = {};
    try { perfUserDecisions = JSON.parse(localStorage.getItem('uat_perf_user_decisions') || '{}'); } catch(e) {}

    // Merge user decisions with system assessment badges to get effective state per metric
    var effectivePerfMetrics = perfMetrics.map(function(m) {
      var ud = perfUserDecisions[m.key] || 'Pending';
      var eff = m.badge; // system assessment
      if (ud === 'Pass')                eff = 'PASS';
      else if (ud === 'Fail')           eff = 'FAIL';
      else if (ud === 'Accept Risk')    eff = 'WARN';
      else if (ud === 'Not Applicable') eff = 'OUT OF SCOPE';
      if (fixDismissed['perf:' + m.key]) eff = 'OUT OF SCOPE'; // FIX modal override
      // 'Pending' keeps the system badge
      return Object.assign({}, m, { effectiveBadge: eff, userDecision: ud });
    });

    var perfPasses = 0, perfFails = 0, perfWarns = 0, perfInfos = 0, perfNTs = 0, perfOOS = 0;
    var pendingCritical = 0; // FAIL/REVIEW metrics still awaiting user decision
    effectivePerfMetrics.forEach(function(m) {
      if (m.effectiveBadge === 'PASS') perfPasses++;
      else if (m.effectiveBadge === 'FAIL') perfFails++;
      else if (m.effectiveBadge === 'WARN' || m.effectiveBadge === 'REVIEW') perfWarns++;
      else if (m.effectiveBadge === 'INFO') perfInfos++;
      else if (m.effectiveBadge === 'NOT TESTED') perfNTs++;
      else if (m.effectiveBadge === 'OUT OF SCOPE') perfOOS++;
      // Count metrics that need a user decision (system says FAIL/REVIEW, user hasn't decided)
      if ((m.badge === 'FAIL' || m.badge === 'REVIEW') && m.userDecision === 'Pending') pendingCritical++;
    });
    var perfMeasured = perfPasses + perfFails + perfWarns;

    // Effective overall: user-resolved failures trump system assessment
    var perfOverall = '';
    if (perfFails > 0)         perfOverall = 'FAIL';
    else if (pendingCritical > 0) perfOverall = 'PENDING';
    else if (perfWarns > 0)    perfOverall = 'WARN';
    else if (perfMeasured > 0) perfOverall = 'PASS';
    // Fallback to saved API status if no live metrics
    if (!perfOverall) perfOverall = UAT.performance.overall_status ||
      (r.performance_status === 'Pass' ? 'PASS' : r.performance_status === 'Fail' ? 'FAIL' : '');

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
        // Pass when no effective FAIL and no pending decisions on critical metrics.
        // WARN/Accept Risk = "pass with conditions" — does not block cutover.
        pass: perfFails === 0 && pendingCritical === 0 &&
              (perfMeasured > 0 || (!perfOverall && r.performance_status && r.performance_status !== 'Fail')),
        detail: (function() {
          if (perfMeasured === 0) return 'Status: ' + (r.performance_status || 'Not yet run');
          var parts = [perfPasses + ' of ' + perfMeasured + ' metrics OK'];
          if (pendingCritical > 0) parts.push(pendingCritical + ' awaiting your decision (see Step 3 dropdowns)');
          if (perfFails > 0)       parts.push(perfFails + ' confirmed fail');
          if (perfWarns > 0)       parts.push(perfWarns + ' warn/accepted risk');
          if (perfInfos > 0)       parts.push(perfInfos + ' informational');
          if (perfNTs   > 0)       parts.push(perfNTs  + ' not tested');
          if (perfOOS   > 0)       parts.push(perfOOS  + ' out of scope');
          return parts.join(' · ');
        })(),
        source: 'Step 3 — SSH Performance Test (live) · Resolved by Your Decision dropdowns',
        fix: pendingCritical > 0
          ? 'Go to Step 3 — Performance Validation. Set Your Decision on all flagged metrics (Pass / Fail / Accept Risk).'
          : perfFails > 0
          ? 'Go to Step 3. Review FAIL metrics. Override with "Pass" if acceptable, "Accept Risk" for accepted deviation, or "Fail" to block cutover.'
          : 'Go to Step 3 — Performance Validation. Run SSH Tests first.',
        decisionImpact: (perfFails > 0 || pendingCritical > 0) ? 'Blocks cutover until decisions are set' : 'Supports cutover' },
    ];

    // Apply FIX modal dismissals to checks and service lists
    checks.forEach(function(c) {
      var dk = fixDismissed['check:' + c.key];
      if (dk === 'fixed')        c.pass = true;
      if (dk === 'not_relevant') c.outOfScope = true;
    });
    svcHardBlocks = svcHardBlocks.filter(function(s){ return !fixDismissed['svc_hard:' + s.service]; });
    svcReviewGaps = svcReviewGaps.filter(function(s){ return !fixDismissed['svc_gap:'  + s.service]; });
    svcWarnings   = svcWarnings.filter(function(s){   return !fixDismissed['svc_warn:' + s.service]; });

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

    // Decision: checklist failures, hard service blocks, confirmed perf failures,
    //           or metrics with pending user decisions → NOT READY.
    //           review gaps / warnings only → READY WITH CONDITIONS.
    var notReady      = blocking > 0 || svcHardBlocks.length > 0 || perfFails > 0 || pendingCritical > 0;
    var readyWithCond = !notReady && (svcReviewGaps.length > 0 || svcWarnings.length > 0 || perfWarns > 0);
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

    // Performance evidence — shows both system assessment and user decision
    var perfEvidence = effectivePerfMetrics.map(function(m) {
      var typeMap = { PASS:'pass', FAIL:'fail', WARN:'warning', REVIEW:'warning', INFO:'info', PENDING:'warning', 'NOT TESTED':'nt', 'OUT OF SCOPE':'oos' };
      var udNote = m.userDecision !== 'Pending' ? ' [Your decision: ' + m.userDecision + ']' : (m.badge !== m.effectiveBadge ? '' : '');
      return { type: typeMap[m.effectiveBadge] || 'info',
               text: m.label + ': ' + m.effectiveBadge + (m.text && m.text !== '—' ? ' (' + m.text + ')' : '') + udNote + '.' };
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
      pendingCritical: pendingCritical,
      perfMetrics: effectivePerfMetrics,
      goodNews: goodNews, blockingItems: blockingItems, reviewItems: reviewItems, oosItems: oosItems,
      nextActions: nextActions, svcEvidence: svcEvidence, perfEvidence: perfEvidence, hasDB: hasDB,
    };
  }

  function renderSummary() {
    var a = calculateUatReadinessAnalysis();
    var fd = window._uatFlavorData || null;
    _ud_scopeCard();
    _ud_hero(a);
    _ud_gauge(a);
    _ud_kpi(a);
    _ud_flow(a);
    _ud_why(a);
    _ud_perfChart(a, fd);
    _ud_vmChart(a, fd);
    _ud_tcoChart(a, fd);
    _ud_svcHealth(a);
    _ud_perfSummary(a);
    _ud_dbStatus(a);
    _ud_cta(a);
    _ud_footer();
  }

  function _ud_scopeCard() {
    var el = $('uat-scope-card-container');
    if (!el) return;

    var wl = {};
    try { wl = JSON.parse(localStorage.getItem('uat_workload_scope') || 'null') || {}; } catch(e) {}

    var appType   = wl.appType  || 'web';
    var dbType    = wl.dbType   || 'none';
    var hasHTTP   = wl.hasHTTP  !== false || appType === 'web' || appType === 'api' || appType === 'mixed';
    var hasAPI    = wl.hasAPI   !== false || appType === 'api' || appType === 'mixed';
    var hasDB     = wl.hasDatabase === true;
    var hasNet    = wl.hasNetwork !== false;

    var appTypeLabels = {
      web:'Web Application', api:'API / Microservice', db:'Database-Only',
      mixed:'Mixed (Web + API + DB)', batch:'Batch / Background Jobs', other:'Other'
    };
    var appLabel = appTypeLabels[appType] || appType;

    function chip(active, label, color) {
      var bg      = active ? color + '15' : '#f1f5f9';
      var border  = active ? color : '#e2e8f0';
      var txtClr  = active ? color : '#94a3b8';
      var icon    = active ? '&#10003;' : '&#8212;';
      return '<span style="display:inline-flex;align-items:center;gap:4px;padding:3px 10px;border-radius:20px;border:1px solid '+border+';background:'+bg+';color:'+txtClr+';font-size:11px;font-weight:600;">'
           + '<span style="font-size:11px;">'+icon+'</span> '+label+'</span>';
    }

    var dbChip = hasDB
      ? chip(true, 'DB (' + (dbType !== 'none' ? dbType : 'any') + ')', '#7c3aed')
      : chip(false, 'DB', '#7c3aed');

    var editBtn = '<button onclick="var el=document.getElementById(\'uat-s3-scope\');if(el){el.style.display=el.style.display===\'none\'?\'block\':\'none\';}" '
      + 'style="margin-left:auto;font-size:11px;font-weight:600;padding:4px 12px;border-radius:6px;border:1px solid #e2e8f0;background:#fff;color:#64748b;cursor:pointer;">'
      + '<i class="fas fa-pen" style="font-size:10px;margin-right:4px;"></i>Edit Scope</button>';

    var pairs = UAT.scope || [];
    var serverCount = pairs.length;
    var srvChip = '<span style="display:inline-flex;align-items:center;gap:4px;padding:3px 10px;border-radius:20px;border:1px solid '+(serverCount?'#2563eb':'#e2e8f0')+';background:'+(serverCount?'#eff6ff':'#f8fafc')+';color:'+(serverCount?'#1d4ed8':'#94a3b8')+';font-size:11px;font-weight:600;">'
      + (serverCount ? '&#10003; ' : '— ') + serverCount + ' Server Pair' + (serverCount !== 1 ? 's' : '') + '</span>';

    el.innerHTML = '<div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:10px 14px;background:#fff;border:1px solid #e2e8f0;border-radius:8px;box-shadow:0 1px 2px rgba(0,0,0,.04);">'
      + '<span style="font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.05em;color:#64748b;margin-right:4px;">UAT SCOPE</span>'
      + '<span style="font-size:12px;font-weight:600;color:#1e293b;padding:3px 10px;border-radius:20px;background:#eff6ff;border:1px solid #bfdbfe;color:#1d4ed8;">'+esc(appLabel)+'</span>'
      + chip(hasHTTP, 'HTTP', '#0ea5e9')
      + chip(hasAPI,  'API',  '#0891b2')
      + dbChip
      + chip(hasNet,  'Network', '#16a34a')
      + srvChip
      + editBtn
      + '</div>';
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
    if (!$('uat-scope-body')) return;
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
    _persistScopeToStorage();
    renderScope();
    await refreshReadiness();
    setMessage('UAT scope saved to outputs/uat/uat_scope.csv.');
  }

  function _persistScopeToStorage() {
    try {
      var rows = (UAT.scope || []).map(function(r) {
        return {
          name:       r.business_system_name || '',
          type:       r.system_type || '',
          source_ip:  r.source_host || '',
          target_ip:  r.target_ip || r.ssh_host || r.target_host || '',
        };
      }).filter(function(r) { return r.source_ip || r.target_ip; });
      localStorage.setItem('osflex_uat_scope', JSON.stringify(rows));
      localStorage.setItem('osflex_uat_scope_ts', new Date().toISOString());
    } catch(_) {}
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
    renderSummary();
  }

  // (old renderReadiness body removed — replaced by _render* helpers below)
  function __renderReadiness_old__() { /* removed */ if(false) {
    var a = calculateUatReadinessAnalysis();
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

    // ── WHY THIS DECISION? panel — grouped into 5 lanes ─────────────────────
    // Pending user decisions (performance metrics with no decision yet)
    var whyPendingItems = [];
    if (a.pendingCritical > 0)
      whyPendingItems.push('Performance has ' + a.pendingCritical + ' metric(s) awaiting your decision — go to Step 3 and set Your Decision dropdowns.');
    a.inScopeChecks.filter(function(c){ return !c.pass && c.notTested; }).forEach(function(c) {
      whyPendingItems.push(c.label + ' not yet run — ' + (c.fix || 'run the test to proceed.'));
    });

    function whySection(title, color, borderColor, items, emptyMsg) {
      return '<div>'
        + '<div style="font-size:10px;font-weight:700;color:' + color + ';text-transform:uppercase;letter-spacing:.05em;margin-bottom:5px;padding-bottom:3px;border-bottom:1px solid ' + borderColor + ';">' + title + '</div>'
        + (items.length
          ? items.map(function(s){ return '<div style="font-size:11px;color:' + color + ';padding:1px 0;line-height:1.5;">' + esc(s) + '</div>'; }).join('')
          : '<div style="font-size:11px;color:#94a3b8;">' + emptyMsg + '</div>')
        + '</div>';
    }

    var whyPanel = '<div style="background:#f8fafc;border-top:1px solid #e2e8f0;">'
      + '<div style="padding:8px 14px 4px;font-size:10px;font-weight:800;color:#475569;text-transform:uppercase;letter-spacing:.08em;">Why This Decision?</div>'
      + '<div style="padding:0 14px 12px;display:grid;grid-template-columns:1fr 1fr 1fr 1fr;gap:10px;">'
      + whySection('✗ Real Blockers',          '#b91c1c', '#fee2e2',
          a.blockingItems.map(function(s){ return '✗ ' + s; }),
          'No blockers — all required checks pass.')
      + whySection('⏳ Pending Decisions',      '#b45309', '#fef3c7',
          whyPendingItems.map(function(s){ return '⏳ ' + s; }),
          'No pending decisions.')
      + whySection('⚠ Needs Review',           '#b45309', '#fef3c7',
          a.reviewItems.map(function(s){ return '⚠ ' + s; }),
          'Nothing needs review.')
      + '<div>'
        + '<div style="font-size:10px;font-weight:700;color:#15803d;text-transform:uppercase;letter-spacing:.05em;margin-bottom:5px;padding-bottom:3px;border-bottom:1px solid #dcfce7;">✓ Positive Evidence</div>'
        + (a.goodNews.length
          ? a.goodNews.map(function(s){ return '<div style="font-size:11px;color:#15803d;padding:1px 0;line-height:1.5;">✓ ' + esc(s) + '</div>'; }).join('')
          : '<div style="font-size:11px;color:#94a3b8;">No items passing yet.</div>')
        + '<div style="font-size:10px;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:.05em;margin-top:10px;margin-bottom:5px;padding-bottom:3px;border-bottom:1px solid #e2e8f0;">— Out of Scope</div>'
        + (a.oosItems.length
          ? a.oosItems.map(function(o){ return '<div style="font-size:11px;color:#94a3b8;padding:1px 0;">— ' + esc(o.label) + '<div style="font-size:10px;color:#b0b8c4;margin-left:8px;line-height:1.4;">' + esc(o.detail) + '</div></div>'; }).join('')
          : '<div style="font-size:11px;color:#94a3b8;">No checks excluded.</div>')
        + '</div>'
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
        var dimLabel = c.outOfScope ? 'OUT OF SCOPE' : 'NOT TESTED';
        var dimColor = c.outOfScope ? '#94a3b8' : '#64748b';
        return '<tr style="border-bottom:1px solid #f1f5f9;background:#f8fafc;">'
          + '<td style="padding:9px 12px;text-align:center;vertical-align:top;width:32px;"><span style="font-size:13px;color:#94a3b8;">—</span></td>'
          + '<td style="padding:9px 12px;vertical-align:top;">'
          + '<div style="font-weight:600;font-size:12px;color:#94a3b8;">' + esc(c.label) + '</div>'
          + '<div style="font-size:11px;color:#94a3b8;margin-top:1px;">' + esc(c.detail) + '</div>'
          + '<div style="font-size:11px;color:#64748b;margin-top:2px;">Source: ' + esc(c.source) + '</div>'
          + (!c.outOfScope && c.fix ? '<div style="font-size:11px;color:#92400e;margin-top:3px;">→ ' + esc(c.fix) + '</div>' : '')
          + '</td>'
          + '<td style="padding:9px 12px;text-align:right;vertical-align:top;white-space:nowrap;"><span style="font-size:10px;font-weight:700;color:' + dimColor + ';letter-spacing:.04em;">' + dimLabel + '</span></td>'
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
      + '<div style="padding:14px 16px;background:' + overallBg + ';border-bottom:1px solid ' + overallBorder + ';">'
      + '<div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;">'
      + '<div style="font-size:26px;font-weight:900;color:' + overallColor + ';line-height:1;">' + decisionIcon + '</div>'
      + '<div style="flex:1;min-width:0;">'
      + '<div style="font-size:14px;font-weight:800;color:' + overallColor + ';letter-spacing:.03em;">' + esc(decisionText) + '</div>'
      + '<div style="font-size:11px;color:#475569;margin-top:2px;">'
        + a.passed + '/' + a.total + ' checks passed · ' + a.pct + '% readiness · '
        + a.blocking + ' blocker(s) · ' + a.svcReviewGaps.length + ' service gap(s) for review'
      + '</div>'
      + '</div></div>'
      // System evidence strip
      + '<div style="margin-top:10px;display:flex;flex-wrap:wrap;gap:6px;">'
      + '<span style="font-size:10px;font-weight:700;color:#475569;padding:3px 0;text-transform:uppercase;letter-spacing:.05em;">System evidence:</span>'
      + (a.openCriticalIssues === 0 ? '<span style="font-size:11px;color:#15803d;background:#f0fdf4;border:1px solid #86efac;padding:2px 8px;border-radius:4px;">✓ No critical issues</span>' : '')
      + (a.svcRan && a.svcAcceptable > 0 ? '<span style="font-size:11px;color:#15803d;background:#f0fdf4;border:1px solid #86efac;padding:2px 8px;border-radius:4px;">✓ ' + a.svcAcceptable + '/' + a.svcTotal + ' services OK</span>' : '')
      + (a.perfMeasured > 0 ? '<span style="font-size:11px;color:' + (a.perfFails > 0 ? '#dc2626' : '#475569') + ';background:' + (a.perfFails > 0 ? '#fef2f2' : '#f8fafc') + ';border:1px solid ' + (a.perfFails > 0 ? '#fca5a5' : '#e2e8f0') + ';padding:2px 8px;border-radius:4px;">' + (a.perfFails > 0 ? '✗' : 'ℹ') + ' Performance: system ' + (a.perfOverall || 'assessed') + '</span>' : '')
      + (a.svcReviewGaps.length > 0 ? '<span style="font-size:11px;color:#b45309;background:#fffbeb;border:1px solid #fde68a;padding:2px 8px;border-radius:4px;">⚠ ' + a.svcReviewGaps.length + ' service(s) need review</span>' : '')
      + (a.svcWarnings.length > 0 ? '<span style="font-size:11px;color:#b45309;background:#fffbeb;border:1px solid #fde68a;padding:2px 8px;border-radius:4px;">~ ' + a.svcWarnings.length + ' extra FLEX service(s) to verify</span>' : '')
      + '</div>'
      // Pending user decisions strip (only shown when there are pending items)
      + (a.pendingCritical > 0 || (a.blocking > 0)
        ? '<div style="margin-top:8px;display:flex;flex-wrap:wrap;gap:6px;">'
          + '<span style="font-size:10px;font-weight:700;color:#b91c1c;padding:3px 0;text-transform:uppercase;letter-spacing:.05em;">User decisions required:</span>'
          + (a.pendingCritical > 0 ? '<span style="font-size:11px;color:#b45309;background:#fffbeb;border:1px solid #fde68a;padding:2px 8px;border-radius:4px;">⏳ ' + a.pendingCritical + ' perf metric(s) — go to Step 3 dropdowns</span>' : '')
          + a.inScopeChecks.filter(function(c){ return !c.pass && !c.notTested; }).map(function(c) {
              return '<span style="font-size:11px;color:#dc2626;background:#fef2f2;border:1px solid #fca5a5;padding:2px 8px;border-radius:4px;">⛔ ' + esc(c.label) + ' incomplete</span>';
            }).join('')
          + '</div>'
        : '')
      + '</div>'

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
  } } // end if(false) + end __renderReadiness_old__

  // ── Dashboard render helpers ──────────────────────────────────────────────

  function _esc(v) { return String(v ?? '').replace(/[&<>"']/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }

  // Decision language mapping
  function _decisionLabel(d) {
    if (d === 'READY') return 'READY FOR CUT OVER';
    if (d === 'READY WITH CONDITIONS') return 'READY WITH CONDITIONS';
    return 'NEED REVIEW BEFORE CUT OVER';
  }

  function _badgePill(text, cls) {
    return '<span class="uat-badge-pill uat-badge-' + cls + '">' + _esc(text) + '</span>';
  }

  function _dashBtn(label, cls, onclick) {
    return '<button class="uat-dash-btn' + (cls?' '+cls:'') + '" onclick="' + onclick + '">' + _esc(label) + '</button>';
  }

  // ── Helper ────────────────────────────────────────────────────────────────
  function _udE(id) { return document.getElementById(id); }
  function _udEsc(v) {
    return String(v == null ? '' : v).replace(/[&<>"']/g, function(c){
      return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];
    });
  }
  function _udFmt(n) {
    n = parseFloat(n) || 0;
    if (n >= 1000) return '$' + (n/1000).toFixed(1) + 'K';
    return '$' + n.toLocaleString();
  }

  // S1: Status Banner
  function _ud_hero(a) {
    var el = _udE('uat-s1-hero');
    if (!el) return;
    var isNotReady = a.cutoverDecision !== 'READY' && a.cutoverDecision !== 'READY WITH CONDITIONS';
    var isCond     = a.cutoverDecision === 'READY WITH CONDITIONS';
    var decColor   = isNotReady ? '#dc2626' : isCond ? '#d97706' : '#16a34a';
    var decIcon    = isNotReady ? '✕' : isCond ? '!' : '✓';
    var decLabel   = isNotReady ? 'NEED REVIEW BEFORE CUT OVER'
                   : isCond    ? 'READY WITH CONDITIONS'
                   :             'READY FOR CUTOVER';
    var reason = a.blockingItems.length ? a.blockingItems[0] : a.reviewItems.length ? a.reviewItems[0] : 'All key checks are complete.';
    var goodNews = [];
    if (a.perfFails === 0 && a.perfMeasured > 0) goodNews.push('Performance passed');
    if (a.openCriticalIssues === 0) goodNews.push('no critical issues');
    if (!a.hasDB) goodNews.push('DB is out of scope');
    if (a.svcAcceptable > 0 && a.svcRan) goodNews.push(a.svcAcceptable + ' services acceptable');
    // KPI chips
    var chipDefs = [
      { val: a.passed + '/' + a.total, lbl: 'checks passed', color: '#16a34a' },
      { val: a.blocking,               lbl: 'blocker',        color: '#dc2626' },
      { val: a.svcReviewGaps.length,   lbl: 'needs review',   color: '#d97706' },
      { val: a.svcWarnings.length,     lbl: 'warnings',       color: '#f59e0b' },
      { val: a.checks.filter(function(c){return c.outOfScope;}).length, lbl: 'out of scope', color: '#6b7280' },
    ];
    el.innerHTML = '<div style="display:grid;grid-template-columns:minmax(210px,1fr) minmax(280px,1.45fr) auto;align-items:center;gap:12px;">'
      // Left: Status icon + label
      + '<div style="display:flex;align-items:center;gap:12px;min-width:0;">'
      + '<div style="width:36px;height:36px;border-radius:50%;background:' + decColor + ';color:#fff;display:flex;align-items:center;justify-content:center;font-size:18px;font-weight:900;flex-shrink:0;">' + decIcon + '</div>'
      + '<div style="font-size:18px;font-weight:900;color:' + decColor + ';letter-spacing:0;line-height:1.08;min-width:0;">' + _udEsc(decLabel) + '</div>'
      + '</div>'
      // Center: Reason + good news
      + '<div style="padding:0 16px;border-left:1px solid #fecaca;border-right:1px solid #fecaca;min-width:0;">'
      + '<div style="font-size:11px;margin-bottom:2px;line-height:1.35;">'
      + '<span style="font-weight:700;color:#374151;">Main reason: </span><span style="color:#dc2626;font-weight:600;">' + _udEsc(reason) + '</span>'
      + '</div>'
      + (goodNews.length ? '<div style="font-size:11px;color:#4b5563;line-height:1.35;"><span style="font-weight:700;color:#374151;">Good news: </span>' + _udEsc(goodNews.join(', ') + '.') + '</div>' : '')
      + '</div>'
      // Right: KPI chips
      + '<div style="display:flex;align-items:stretch;justify-content:flex-end;min-width:0;">'
      + chipDefs.map(function(c, i) {
          return '<div style="padding:4px 10px;text-align:center;' + (i>0?'border-left:1px solid #fecaca;':'') + '">'
            + '<div style="font-size:16px;font-weight:900;color:' + c.color + ';line-height:1;">' + _udEsc(String(c.val)) + '</div>'
            + '<div style="font-size:9px;color:#6b7280;margin-top:3px;white-space:nowrap;">' + _udEsc(c.lbl) + '</div>'
            + '</div>';
        }).join('')
      + '</div>'
      + '</div>';
  }

  // S2a: Score gauge SVG
  function _ud_gauge(a) {
    var el = _udE('uat-gauge-wrap');
    if (!el) return;
    var pct = a.pct || 0;
    var R = 46, cx = 60, cy = 62;
    var arc = Math.PI * R;
    var offset = arc * (1 - pct/100);
    var col = pct >= 80 ? '#16a34a' : pct >= 50 ? '#d97706' : '#2563eb';
    el.innerHTML = '<svg width="122" height="68" viewBox="0 0 122 68" style="display:block;">'
      + '<path d="M14 62 A' + R + ' ' + R + ' 0 0 1 108 62" fill="none" stroke="#e5e7eb" stroke-width="10" stroke-linecap="round"/>'
      + '<path d="M14 62 A' + R + ' ' + R + ' 0 0 1 108 62" fill="none" stroke="' + col + '" stroke-width="10" stroke-linecap="round"'
      + ' stroke-dasharray="' + arc.toFixed(1) + '" stroke-dashoffset="' + offset.toFixed(1) + '"/>'
      + '<text x="61" y="54" text-anchor="middle" font-size="21" font-weight="900" fill="' + col + '">' + pct + '%</text>'
      + '<text x="61" y="66" text-anchor="middle" font-size="9" fill="#9ca3af">' + a.passed + '/' + a.total + ' passed</text>'
      + '</svg>';
  }

  // S2b: KPI Cards
  function _ud_kpi(a) {
    var el = _udE('uat-summary-grid');
    if (!el) return;
    var sysPerfVal = a.perfFails > 0 ? 'FAIL' : a.pendingCritical > 0 ? 'PEND' : a.perfOverall || (a.perfMeasured > 0 ? 'PASS' : '—');
    var sysPerfSub = a.pendingCritical > 0 ? 'User pending' : a.perfFails > 0 ? 'Fix required' : 'All key metrics OK';
    var sysPerfCol = a.perfFails > 0 ? '#dc2626' : a.pendingCritical > 0 ? '#d97706' : '#16a34a';
    var oosCount = a.checks.filter(function(c){return c.outOfScope;}).length;
    var cards = [
      { icon:'✓', lbl:'Passed Checks',     val: a.passed,              sub: 'of ' + a.total,    col: a.passed > 0 ? '#16a34a' : '#6b7280' },
      { icon:'!', lbl:'Real Blockers',     val: a.blocking,            sub: 'Needs action',      col: a.blocking > 0 ? '#dc2626' : '#16a34a' },
      { icon:'○', lbl:'Needs Review',      val: a.svcReviewGaps.length,sub: 'Services',          col: a.svcReviewGaps.length > 0 ? '#d97706' : '#16a34a' },
      { icon:'△', lbl:'Warnings',          val: a.svcWarnings.length,  sub: 'Extra services',    col: a.svcWarnings.length > 0 ? '#f59e0b' : '#16a34a' },
      { icon:'⊖',  lbl:'Out of Scope',     val: oosCount,              sub: 'Check',             col: '#6b7280' },
      { icon:'↗', lbl:'Performance',      val: sysPerfVal,            sub: 'System assessment', col: sysPerfCol, big: true },
      { icon:'◇',  lbl:'Open Critical Issues', val: a.openCriticalIssues, sub: 'Issues',         col: a.openCriticalIssues > 0 ? '#dc2626' : '#1e293b' },
    ];
    el.innerHTML = cards.map(function(c) {
      var fontSize = c.big ? '20px' : '28px';
      return '<div class="ud-kpi">'
        + '<div style="display:flex;align-items:center;gap:6px;margin-bottom:6px;">'
        + '<span style="font-size:14px;">' + c.icon + '</span>'
        + '<span class="ud-kpi-label">' + _udEsc(c.lbl) + '</span>'
        + '</div>'
        + '<div class="ud-kpi-val" style="font-size:' + fontSize + ';color:' + c.col + ';">' + _udEsc(String(c.val)) + '</div>'
        + '<div class="ud-kpi-sub">' + _udEsc(c.sub) + '</div>'
        + '</div>';
    }).join('');
  }

  // S3: Logic Flow Strip
  function _ud_flow(a) {
    var el = _udE('uat-flow-strip');
    if (!el) return;
    var wl = {};
    try { wl = JSON.parse(localStorage.getItem('uat_workload_scope') || 'null') || {}; } catch(e) {}
    var appLabels = {web:'Web App',api:'API',db:'DB-Only',mixed:'Mixed',batch:'Batch',other:'Other'};
    var appLabel = appLabels[wl.appType || 'web'] || 'Web App';
    var scopeTags = [appLabel];
    if (wl.hasHTTP !== false) scopeTags.push('HTTP');
    if (wl.hasAPI !== false)  scopeTags.push('API');
    if (wl.hasNetwork !== false) scopeTags.push('Network');
    var dbLabel = wl.hasDatabase === true ? (wl.dbType || 'DB') : 'DB: Out of Scope';

    var notTested = a.checks.filter(function(c){return c.notTested && !c.outOfScope;}).length;
    var perfSt  = a.perfFails > 0 ? 'fail' : a.pendingCritical > 0 ? 'warn' : (a.perfMeasured > 0 ? 'pass' : 'nt');
    var decSt   = a.cutoverDecision === 'READY' ? 'pass' : 'fail';
    var svcSt   = a.svcReviewGaps.length > 0 ? 'warn' : 'pass';

    function stColors(st) {
      if (st==='pass') return { bg:'#f0fdf4', border:'#bbf7d0', title:'#16a34a', tag:'#16a34a', tagBg:'#dcfce7' };
      if (st==='fail') return { bg:'#fef2f2', border:'#fecaca', title:'#dc2626', tag:'#dc2626', tagBg:'#fee2e2' };
      if (st==='warn') return { bg:'#fffbeb', border:'#fde68a', title:'#d97706', tag:'#d97706', tagBg:'#fef3c7' };
      return { bg:'#f9fafb', border:'#e5e7eb', title:'#6b7280', tag:'#6b7280', tagBg:'#f3f4f6' };
    }

    function makeTag(text, color, bg) {
      return '<span class="ud-flow-tag" style="color:'+color+';background:'+bg+';">'+_udEsc(text)+'</span>';
    }
    var nodeIcons = { Scope:'⊕', Checks:'☑', Services:'○', Performance:'↗', Decision:'◇' };
    function node(st, title, lines) {
      var c = stColors(st);
      return '<div class="ud-flow-node" style="background:'+c.bg+';border-color:'+c.border+';">'
        + '<div class="ud-flow-node-title"><span>'+( nodeIcons[title]||'')+'</span><span style="color:'+c.title+';">'+_udEsc(title)+'</span></div>'
        + lines + '</div>';
    }
    function arrow() { return '<div class="ud-flow-arrow">→</div>'; }

    var scopeNode = node('pass', 'Scope',
      scopeTags.map(function(t){ return makeTag(t,'#2563eb','#eff6ff'); }).join('')
      + '<div style="font-size:10px;color:#6b7280;margin-top:4px;">'+_udEsc(dbLabel)+'</div>');

    var checksSt = a.blocking > 0 ? 'fail' : notTested > 0 ? 'warn' : 'pass';
    var checksNode = node(checksSt, 'Checks',
      '<div style="font-size:11px;display:flex;flex-direction:column;gap:2px;">'
      + '<span style="color:#16a34a;font-weight:700;">✓ ' + a.passed + ' passed</span>'
      + (notTested ? '<span style="color:#6b7280;">○ ' + notTested + ' not tested</span>' : '')
      + (a.blocking ? '<span style="color:#dc2626;font-weight:700;">✗ ' + a.blocking + ' blocker</span>' : '')
      + '</div>');

    var svcNode = node(svcSt, 'Services',
      '<div style="font-size:11px;display:flex;flex-direction:column;gap:2px;">'
      + (a.svcRan ? '<span style="color:#16a34a;font-weight:700;">✓ ' + a.svcAcceptable + ' OK</span>'
        + (a.svcReviewGaps.length ? '<span style="color:#d97706;">● ' + a.svcReviewGaps.length + ' review</span>' : '')
        + (a.svcWarnings.length ? '<span style="color:#f59e0b;">● ' + a.svcWarnings.length + ' warnings</span>' : '')
        : '<span style="color:#9ca3af;">Not yet run</span>')
      + '</div>');

    var perfLabel = a.perfFails > 0 ? 'FAIL' : a.pendingCritical > 0 ? 'PENDING' : (a.perfMeasured > 0 ? 'PASS' : '—');
    var perfSub   = a.perfFails > 0 ? 'Fix required' : a.pendingCritical > 0 ? 'User decisions pending' : 'All key metrics OK';
    var perfNode  = node(perfSt, 'Performance',
      '<div style="font-size:16px;font-weight:900;color:' + (perfSt === 'pass' ? '#16a34a' : perfSt === 'fail' ? '#dc2626' : '#d97706') + ';">' + perfLabel + '</div>'
      + '<div style="font-size:10px;color:#6b7280;">' + _udEsc(perfSub) + '</div>');

    var decLabel = a.cutoverDecision === 'READY' ? 'PASS' : 'FIX';
    var decSub   = a.cutoverDecision === 'READY' ? 'Proceed with cutover' : 'Resolve blockers to proceed';
    var decNode   = node(decSt, 'Decision',
      '<div style="font-size:16px;font-weight:900;color:' + (decSt === 'pass' ? '#16a34a' : '#dc2626') + ';">' + decLabel + '</div>'
      + '<div style="font-size:10px;color:#6b7280;">' + _udEsc(decSub) + '</div>');

    el.innerHTML = scopeNode + arrow() + checksNode + arrow() + svcNode + arrow() + perfNode + arrow() + decNode;
  }

  // S4: Why 4-col
  function _ud_why(a) {
    var el = _udE('uat-s4-why-actions');
    if (!el) return;

    function makeCol(title, iconColor, borderColor, bgColor, items, extra) {
      return '<div class="ud-why-col" style="border:1px solid ' + borderColor + ';background:' + bgColor + ';border-radius:10px;padding:14px 16px;box-shadow:0 1px 3px rgba(0,0,0,.05);">'
        + '<div class="ud-why-title" style="color:' + iconColor + ';border-bottom:1px solid ' + borderColor + ';padding-bottom:8px;margin-bottom:10px;">' + title + '</div>'
        + items.map(function(it) {
            return '<div class="ud-why-item"><span class="ud-why-item-main">• ' + _udEsc(it.main) + '</span>'
              + (it.sub ? '<div class="ud-why-item-sub" style="padding-left:12px;">' + _udEsc(it.sub) + '</div>' : '')
              + '</div>';
          }).join('')
        + (extra || '')
        + '</div>';
    }

    // Col 1: Blockers
    var blockItems = a.blockingItems.slice(0,3).map(function(s) { return { main: s, sub: '' }; });
    a.checks.forEach(function(c) { if (!c.pass && !c.outOfScope && !c.notTested && c.fix) {
      var bi = blockItems.find(function(b){ return b.main === c.label || b.main.indexOf(c.label) >= 0; });
      if (bi) bi.sub = c.fix.split('.')[0];
    }});
    if (!blockItems.length) blockItems = [{ main: 'No blocking issues found', sub: '' }];

    // Col 2: Review
    var reviewItems = a.svcReviewGaps.slice(0,3).map(function(s) { return { main: s.service || s, sub: '' }; });
    if (a.reviewItems.length && !reviewItems.length) reviewItems = a.reviewItems.slice(0,3).map(function(s){ return {main:s,sub:''}; });
    var moreWarnings = a.svcWarnings.length > 0 ? '<div style="margin-top:6px;font-size:11px;color:#d97706;font-weight:700;cursor:pointer;">+ ' + a.svcWarnings.length + ' more warnings to verify</div>' : '';

    // Col 3: Good news
    var goodItems = [];
    if (a.openCriticalIssues === 0) goodItems.push({ main: 'No open critical issues', sub: '' });
    if (a.perfFails === 0 && a.perfMeasured > 0) goodItems.push({ main: 'Performance validation passed', sub: '' });
    if (!a.hasDB) goodItems.push({ main: 'Database is out of scope', sub: '' });
    if (a.svcAcceptable > 0 && a.svcRan) goodItems.push({ main: a.svcAcceptable + ' services are acceptable', sub: '' });
    if (!goodItems.length) goodItems = [{ main: 'Run checks to populate', sub: '' }];

    // Col 4: Action queue
    var actions = a.nextActions.slice(0, 5);
    var numColors = ['#dc2626','#d97706','#d97706','#d97706','#f59e0b'];
    var actionHtml = '<div class="ud-why-col" style="border:1px solid #bfdbfe;background:#fff;border-radius:10px;padding:14px 16px;box-shadow:0 1px 3px rgba(0,0,0,.05);">'
      + '<div class="ud-why-title" style="color:#1e40af;border-bottom:1px solid #bfdbfe;padding-bottom:8px;margin-bottom:10px;">□ Action queue</div>'
      + actions.map(function(act, i) {
          var numCol = numColors[i] || '#6b7280';
          var isBlock = act.impact && act.impact.toLowerCase().indexOf('block') >= 0;
          var isWarn  = i >= 4;
          var tagTxt  = isBlock ? 'Blocker' : isWarn ? 'Warning' : 'Review';
          var tagBg   = isBlock ? '#fef2f2' : '#fffbeb';
          var tagBdr  = isBlock ? '#fecaca' : '#fde68a';
          var tagCol  = isBlock ? '#dc2626' : isWarn ? '#f59e0b' : '#d97706';
          return '<div class="ud-action-row">'
            + '<div class="ud-action-num" style="background:' + numCol + ';color:#fff;">' + (i+1) + '</div>'
            + '<div class="ud-action-label">' + _udEsc(act.title.length > 28 ? act.title.slice(0,28) + '..' : act.title) + '</div>'
            + '<span class="ud-action-tag" style="background:' + tagBg + ';color:' + tagCol + ';border:1px solid ' + tagBdr + ';">' + tagTxt + '</span>'
            + '<span class="ud-action-arrow">›</span>'
            + '</div>';
        }).join('')
      + '</div>';

    el.innerHTML = makeCol('⊖ What blocks cutover', '#dc2626', '#fecaca', '#fef2f2', blockItems)
      + makeCol('⊕ What needs review',  '#d97706', '#fde68a', '#fffbeb', reviewItems, moreWarnings)
      + makeCol('✓ What looks good',    '#16a34a', '#bbf7d0', '#f0fdf4', goodItems)
      + actionHtml;
  }

  // S5a: Performance Comparison Chart
  function _ud_perfChart(a, fd) {
    var el = _udE('uat-perf-chart');
    if (!el) return;
    var metrics = [
      { label:'CPU Usage',    src: 65, tgt: 42 },
      { label:'Memory Usage', src: 78, tgt: 55 },
      { label:'Disk I/O',     src: 45, tgt: 38 },
      { label:'Network',      src: 82, tgt: 75 },
      { label:'Latency',      src: 120, tgt: 85 },
    ];
    var maxV = metrics.reduce(function(m,r){ return Math.max(m, r.src, r.tgt); }, 1);
    el.innerHTML = '<div style="font-size:12px;font-weight:700;color:#374151;margin-bottom:8px;">Performance Comparison <span style="font-size:10px;color:#9ca3af;font-weight:400;">(Source vs Clone/Target)</span></div>'
      + '<div style="display:flex;gap:12px;font-size:10px;margin-bottom:8px;">'
      + '<span style="display:flex;align-items:center;gap:4px;"><span style="display:inline-block;width:10px;height:10px;background:#3b82f6;border-radius:2px;"></span>Source Server</span>'
      + '<span style="display:flex;align-items:center;gap:4px;"><span style="display:inline-block;width:10px;height:10px;background:#22c55e;border-radius:2px;"></span>Clone Server</span>'
      + '</div>'
      + metrics.map(function(m) {
          var sp = Math.round(m.src/maxV*100), tp = Math.round(m.tgt/maxV*100);
          return '<div class="ud-chart-row">'
            + '<div class="ud-chart-label">' + _udEsc(m.label) + '</div>'
            + '<div class="ud-chart-bars">'
            + '<div class="ud-bar-line"><div class="ud-bar-track"><div class="ud-bar-fill-blue" style="width:' + sp + '%;"></div></div><div class="ud-bar-val">' + m.src + '</div></div>'
            + '<div class="ud-bar-line"><div class="ud-bar-track"><div class="ud-bar-fill-green" style="width:' + tp + '%;"></div></div><div class="ud-bar-val">' + m.tgt + '</div></div>'
            + '</div></div>';
        }).join('')
      + '<div style="display:flex;justify-content:space-between;padding-left:90px;font-size:9px;color:#9ca3af;margin-top:6px;border-top:1px solid #f3f4f6;padding-top:4px;">'
      + [0, Math.round(maxV/3), Math.round(maxV*2/3), maxV].map(function(v){ return '<span>'+v+'</span>'; }).join('')
      + '</div>'
      + '<div style="text-align:center;font-size:10px;color:#9ca3af;padding-left:90px;margin-top:2px;">Utilization (%)</div>';
  }

  // S5b: VM Size Chart
  function _ud_vmChart(a, fd) {
    var el = _udE('uat-vm-chart');
    if (!el) return;
    var vm = fd ? fd.vmData : { srcVcpu:16, tgtVcpu:16, srcRam:64, tgtRam:64, srcDisk:1000, tgtDisk:1000 };
    var metrics = [
      { label:'vCPU (cores)', src: vm.srcVcpu || 16, tgt: vm.tgtVcpu || 16 },
      { label:'RAM (GB)',     src: vm.srcRam  || 64,  tgt: vm.tgtRam  || 64 },
      { label:'Storage (GB)', src: vm.srcDisk || 1000,tgt: vm.tgtDisk || 1000 },
    ];
    var maxV = metrics.reduce(function(m,r){ return Math.max(m, r.src, r.tgt); }, 1);
    function flavorPills(items, color) {
      items = Array.isArray(items) ? items : [];
      if (!items.length) return '<span style="color:#9ca3af;">No flavor map loaded</span>';
      return items.slice(0, 3).map(function(item) {
        var name = item && item.name ? String(item.name) : '';
        var count = item && item.count ? Number(item.count) : 0;
        var label = name.length > 24 ? name.slice(0, 23) + '..' : name;
        return '<span title="' + _udEsc(name + (count ? ' (' + count + ' VM' + (count === 1 ? '' : 's') + ')' : '')) + '" style="display:inline-flex;align-items:center;gap:3px;max-width:132px;padding:1px 5px;border-radius:999px;border:1px solid ' + color + '33;background:' + color + '12;color:' + color + ';font-size:8px;font-weight:700;line-height:1.25;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">'
          + _udEsc(label) + (count ? '<span style="opacity:.72;">x' + count + '</span>' : '') + '</span>';
      }).join('');
    }
    function pairText(items) {
      items = Array.isArray(items) ? items : [];
      if (!items.length) return '';
      var top = items[0] || {};
      var text = String(top.name || '').replace(' -> ', ' -> ');
      if (text.length > 58) text = text.slice(0, 57) + '..';
      return '<div style="display:flex;align-items:center;gap:5px;min-width:0;font-size:8px;color:#6b7280;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;" title="' + _udEsc(String(top.name || '')) + '">'
        + '<span style="font-weight:800;color:#1e40af;">Top map</span>'
        + '<span style="overflow:hidden;text-overflow:ellipsis;">' + _udEsc(text) + (top.count ? ' x' + top.count : '') + '</span>'
        + '</div>';
    }
    el.innerHTML = '<div style="font-size:12px;font-weight:700;color:#374151;margin-bottom:8px;">VM Size / Resource Comparison</div>'
      + '<div style="display:flex;gap:12px;font-size:10px;margin-bottom:8px;">'
      + '<span style="display:flex;align-items:center;gap:4px;"><span style="display:inline-block;width:10px;height:10px;background:#3b82f6;border-radius:2px;"></span>Source</span>'
      + '<span style="display:flex;align-items:center;gap:4px;"><span style="display:inline-block;width:10px;height:10px;background:#22c55e;border-radius:2px;"></span>Target (Clone)</span>'
      + (fd && fd.vmData.rows ? '<span style="font-size:9px;color:#9ca3af;">Avg of ' + fd.vmData.rows + ' VMs</span>' : '')
      + '</div>'
      + metrics.map(function(m) {
          var sp = Math.round(m.src/maxV*100), tp = Math.round(m.tgt/maxV*100);
          return '<div class="ud-chart-row">'
            + '<div class="ud-chart-label">' + _udEsc(m.label) + '</div>'
            + '<div class="ud-chart-bars">'
            + '<div class="ud-bar-line"><div class="ud-bar-track"><div class="ud-bar-fill-blue" style="width:'+sp+'%;"></div></div><div class="ud-bar-val">'+m.src+'</div></div>'
            + '<div class="ud-bar-line"><div class="ud-bar-track"><div class="ud-bar-fill-green" style="width:'+tp+'%;"></div></div><div class="ud-bar-val">'+m.tgt+'</div></div>'
            + '</div></div>';
        }).join('')
      + '<div style="display:flex;justify-content:space-between;padding-left:90px;font-size:9px;color:#9ca3af;margin-top:6px;border-top:1px solid #f3f4f6;padding-top:4px;">'
      + [0, Math.round(maxV/3), Math.round(maxV*2/3), maxV].map(function(v){ return '<span>'+v.toLocaleString()+'</span>'; }).join('')
      + '</div>'
      + '<div style="text-align:center;font-size:10px;color:#9ca3af;padding-left:90px;margin-top:2px;">Capacity</div>'
      + '<div style="margin-top:7px;padding-top:6px;border-top:1px solid #eef2ff;display:grid;gap:4px;min-width:0;">'
      + '<div style="display:flex;align-items:center;gap:5px;min-width:0;"><span style="width:46px;font-size:8px;font-weight:800;color:#3b82f6;text-transform:uppercase;">Source</span><div style="display:flex;gap:4px;min-width:0;overflow:hidden;">' + flavorPills(vm.sourceFlavors, '#3b82f6') + '</div></div>'
      + '<div style="display:flex;align-items:center;gap:5px;min-width:0;"><span style="width:46px;font-size:8px;font-weight:800;color:#16a34a;text-transform:uppercase;">Target</span><div style="display:flex;gap:4px;min-width:0;overflow:hidden;">' + flavorPills(vm.targetFlavors, '#16a34a') + '</div></div>'
      + pairText(vm.flavorPairs)
      + '</div>';
  }

  // S5c: TCO Chart
  function _ud_tcoChart(a, fd) {
    var el = _udE('uat-tco-chart');
    if (!el) return;
    var tco = fd ? fd.tcoData : { srcMonthly:24800, tgtMonthly:18300, savings:6500, savingsPct:'26.2' };
    // Apply price list overrides if uploaded
    var pl = window._uatPriceListState || {};
    if (pl.ospcMonthly > 0) { tco = Object.assign({}, tco); tco.srcMonthly = pl.ospcMonthly; }
    if (pl.flexMonthly > 0) { tco = Object.assign({}, tco); tco.tgtMonthly = pl.flexMonthly; }
    tco.savings    = tco.srcMonthly - tco.tgtMonthly;
    tco.savingsPct = tco.srcMonthly > 0 ? (tco.savings / tco.srcMonthly * 100).toFixed(1) : '0.0';
    var maxVal = Math.max(tco.srcMonthly, tco.tgtMonthly, 1);
    var yMax = Math.ceil(maxVal/5000)*5000 + 5000;
    var bars = [
      { val: tco.srcMonthly, col:'#3b82f6', lbl:'Source Monthly Cost' },
      { val: tco.tgtMonthly, col:'#22c55e', lbl:'Target Monthly Cost' },
      { val: tco.savings,    col:'#8b5cf6', lbl:'Monthly Savings' },
    ];
    var chartH = 58;
    var yLabels = [yMax, Math.round(yMax*0.8), Math.round(yMax*0.6), Math.round(yMax*0.4), Math.round(yMax*0.2), 0];
    var savingsGood = tco.savings > 0;
    var savPct = parseFloat(tco.savingsPct) || 0;
    el.innerHTML = '<div style="font-size:12px;font-weight:700;color:#374151;margin-bottom:12px;line-height:1.15;">TCO Cost Estimation (Monthly)</div>'
      + '<div style="display:flex;gap:8px;align-items:flex-end;clear:both;">'
      // Y-axis
      + '<div style="display:flex;flex-direction:column;justify-content:space-between;height:' + (chartH + 20) + 'px;text-align:right;padding-bottom:20px;">'
      + yLabels.map(function(v){ return '<div style="font-size:9px;color:#9ca3af;">'+_udFmt(v)+'</div>'; }).join('')
      + '</div>'
      // Bars
      + '<div style="display:flex;align-items:flex-end;gap:8px;height:' + (chartH + 20) + 'px;">'
      + bars.map(function(b) {
          var h = Math.max(4, Math.round(b.val/yMax * chartH));
          return '<div style="display:flex;flex-direction:column;align-items:center;gap:3px;">'
            + '<div style="font-size:9px;font-weight:700;color:' + b.col + ';">$' + (b.val/1000).toFixed(1) + 'K</div>'
            + '<div style="width:34px;height:' + h + 'px;background:' + b.col + ';border-radius:4px 4px 0 0;"></div>'
            + '<div style="font-size:9px;color:#6b7280;text-align:center;max-width:56px;line-height:1.2;">' + _udEsc(b.lbl) + '</div>'
            + '</div>';
        }).join('')
      + '</div>'
      // Savings card
      + '<div style="flex:1;min-width:0;">'
      + '<div style="background:#f0fdf4;border:1px solid #bbf7d0;border-radius:8px;padding:8px 10px;">'
      + '<div style="font-size:9px;color:#6b7280;margin-bottom:1px;">Estimated Monthly Savings</div>'
      + '<div style="font-size:20px;font-weight:900;color:' + (savingsGood?'#16a34a':'#dc2626') + ';">$' + tco.savings.toLocaleString() + '</div>'
      + '<div style="font-size:10px;color:#6b7280;margin-top:1px;">' + Math.abs(savPct).toFixed(1) + '% ' + (savingsGood?'lower':'higher') + ' than source</div>'
      + '<div style="font-size:10px;font-weight:700;color:' + (savingsGood?'#16a34a':'#dc2626') + ';margin-top:4px;">' + (savingsGood?'Good Opportunity':'Review Pricing') + '</div>'
      + '</div></div>'
      + '</div>'
      // Price list upload controls
      + '<div style="margin-top:10px;padding-top:10px;border-top:1px solid #e5e7eb;display:flex;flex-wrap:wrap;gap:8px;align-items:center;">'
      + '<button onclick="document.getElementById(\'uat-ospc-price-input\').click()" style="font-size:10px;font-weight:700;padding:4px 10px;border:1px solid #94a3b8;border-radius:6px;background:#f8fafc;color:#374151;cursor:pointer;">⬆ OSPC Price List</button>'
      + '<span style="font-size:10px;color:#64748b;">' + _udEsc((pl.ospcMeta || 'No file loaded')) + '</span>'
      + '<button onclick="document.getElementById(\'uat-flex-price-input\').click()" style="font-size:10px;font-weight:700;padding:4px 10px;border:1px solid #94a3b8;border-radius:6px;background:#f8fafc;color:#374151;cursor:pointer;margin-left:8px;">⬆ FLEX Price List</button>'
      + '<span style="font-size:10px;color:#64748b;">' + _udEsc((pl.flexMeta || 'No file loaded')) + '</span>'
      + (!pl.ospcMonthly ? '<div style="width:100%;margin-top:4px;font-size:10px;color:#f59e0b;display:flex;align-items:center;gap:4px;"><span>⚠</span><span>If no FLEX price list is present, OSPC is assumed <strong>2.45× more expensive</strong> than FLEX.</span></div>' : '')
      + '</div>';
  }

  // S6a: Service Health
  function _ud_svcHealth(a) {
    var el = _udE('uat-svc-health');
    if (!el) return;
    var ok   = a.svcAcceptable || 0;
    var rev  = a.svcReviewGaps.length;
    var warn = a.svcWarnings.length;
    var crit = a.svcHardBlocks.length;
    var total = a.svcTotal || (ok + rev + warn + crit);
    var okPct   = total > 0 ? ok  /total*100 : 0;
    var revPct  = total > 0 ? rev /total*100 : 0;
    var warnPct = total > 0 ? warn/total*100 : 0;
    var critPct = total > 0 ? crit/total*100 : 0;
    el.innerHTML = '<div style="font-size:12px;font-weight:700;color:#374151;margin-bottom:8px;">Service Health</div>'
      + '<div class="ud-svc-counts">'
      + '<span class="ud-svc-stat"><span style="color:#16a34a;">'+ok+'</span> <span style="color:#6b7280;font-weight:400;">OK</span></span>'
      + '<span class="ud-svc-stat"><span style="color:#d97706;">'+rev+'</span> <span style="color:#6b7280;font-weight:400;">Review</span></span>'
      + '<span class="ud-svc-stat"><span style="color:#f59e0b;">'+warn+'</span> <span style="color:#6b7280;font-weight:400;">Warnings</span></span>'
      + '<span class="ud-svc-stat"><span style="color:#dc2626;">'+crit+'</span> <span style="color:#6b7280;font-weight:400;">Critical</span></span>'
      + '</div>'
      + '<div class="ud-seg-bar"><div class="ud-seg-ok" style="width:'+okPct.toFixed(1)+'%;"></div><div class="ud-seg-rev" style="width:'+revPct.toFixed(1)+'%;"></div><div class="ud-seg-warn" style="width:'+warnPct.toFixed(1)+'%;"></div><div class="ud-seg-crit" style="width:'+critPct.toFixed(1)+'%;"></div></div>'
      + '<div style="font-size:10px;color:#9ca3af;">' + total + ' total services</div>'
      + (!a.svcRan ? '<div style="font-size:10px;color:#d97706;margin-top:6px;">Run Step 2 — Service Comparison for live data</div>' : '');
  }

  // S6b: Performance Summary
  function _ud_perfSummary(a) {
    var el = _udE('uat-perf-summary');
    if (!el) return;
    var lbl   = a.perfFails > 0 ? 'FAIL' : a.pendingCritical > 0 ? 'PENDING' : (a.perfMeasured > 0 ? 'PASS' : '—');
    var col   = a.perfFails > 0 ? '#dc2626' : a.pendingCritical > 0 ? '#d97706' : '#16a34a';
    var sub   = a.perfFails > 0 ? 'Metrics exceeded threshold' : a.pendingCritical > 0 ? 'User decisions pending' : 'All key metrics within threshold';
    var wave = '<svg width="72" height="20" viewBox="0 0 72 20" style="margin-top:4px;">'
      + '<polyline points="0,15 9,7 18,13 27,4 36,11 45,6 54,14 63,5 72,10" fill="none" stroke="' + col + '" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'
      + '</svg>';
    el.innerHTML = '<div style="font-size:12px;font-weight:700;color:#374151;margin-bottom:4px;">Performance Summary</div>'
      + '<div style="font-size:24px;font-weight:900;color:' + col + ';margin:2px 0;">' + lbl + '</div>'
      + '<div style="font-size:10px;color:#6b7280;">' + _udEsc(sub) + '</div>'
      + wave;
  }

  // S6c: Database Status
  function _ud_dbStatus(a) {
    var el = _udE('uat-db-status');
    if (!el) return;
    var wl = {};
    try { wl = JSON.parse(localStorage.getItem('uat_workload_scope')||'null')||{}; } catch(e) {}
    var hasDB   = wl.hasDatabase === true;
    var dbType  = hasDB ? (wl.dbType || 'DB') : null;
    var dbLabel = hasDB ? 'IN SCOPE' : 'OUT OF SCOPE';
    var dbCol   = hasDB ? '#2563eb' : '#6b7280';
    var dbSub   = hasDB ? ('Validating ' + (dbType||'database') + ' components') : 'No database component selected';
    el.innerHTML = '<div style="font-size:12px;font-weight:700;color:#374151;margin-bottom:4px;">Database Status</div>'
      + '<div style="font-size:20px;font-weight:900;color:' + dbCol + ';margin:6px 0;letter-spacing:.01em;">' + _udEsc(dbLabel) + '</div>'
      + '<div style="font-size:11px;color:#6b7280;">' + _udEsc(dbSub) + '</div>';
  }

  // S6d: CTA Buttons (side by side, PASS + FIX)
  function _ud_cta(a) {
    var el = _udE('uat-cta-buttons');
    if (!el) return;
    var passStyle = 'display:flex;flex-direction:row;align-items:center;gap:12px;padding:12px 20px;border:none;border-radius:8px;cursor:pointer;font-family:inherit;text-align:left;flex:1;background:#16a34a;color:#fff;';
    var fixStyle  = 'display:flex;flex-direction:row;align-items:center;gap:12px;padding:12px 20px;border:none;border-radius:8px;cursor:pointer;font-family:inherit;text-align:left;flex:1;background:#dc2626;color:#fff;';
    var icStyle   = 'width:32px;height:32px;border-radius:50%;background:rgba(255,255,255,.25);display:flex;align-items:center;justify-content:center;flex-shrink:0;font-size:16px;color:#fff;font-weight:900;';
    var txtStyle  = 'display:flex;flex-direction:column;gap:1px;';
    var mainStyle = 'font-size:20px;font-weight:900;letter-spacing:.02em;color:#fff;line-height:1.1;';
    var subStyle  = 'font-size:8px;color:rgba(255,255,255,.88);line-height:1.3;white-space:nowrap;';
    el.innerHTML =
      '<button class="ud-cta-pass" style="' + passStyle + '" onclick="uatPassWithRiskCheck()">'
      + '<div style="' + icStyle + '">✓</div>'
      + '<div style="' + txtStyle + '"><div style="' + mainStyle + '">PASS</div><div style="' + subStyle + '">Proceed with cutover</div></div>'
      + '</button>'
      + '<button class="ud-cta-fix" style="' + fixStyle + '" onclick="uatFocusActions()">'
      + '<div style="' + icStyle + '">!</div>'
      + '<div style="' + txtStyle + '"><div style="' + mainStyle + '">FIX</div><div style="' + subStyle + '">Resolve blockers and re-run readiness</div></div>'
      + '</button>';
  }

  function _ud_footer() {
    var el = _udE('uat-footer');
    if (!el) return;
    var now = new Date();
    var ts = now.toLocaleString('en-US', {month:'short',day:'numeric',year:'numeric',hour:'numeric',minute:'2-digit'});
    el.innerHTML = 'Last updated: ' + ts + '  ↺ Auto-refresh: ON <span style="color:#22c55e;">●</span>';
  }

  // Tab switcher for S9
  window.uatS9Tab = function(tab) {
    var content = document.getElementById('uat-s9-content');
    if (content && window._uatS9Data) content.innerHTML = window._uatS9Data[tab] || '';
    ['perf','vm','tco'].forEach(function(t) {
      var btn = document.getElementById('uat-s9-tab-' + t);
      if (btn) btn.classList.toggle('uat-tab-btn--active', t === tab);
    });
  };

  // PASS with risk check
  window.uatPassWithRiskCheck = function() {
    var a = calculateUatReadinessAnalysis();
    if (a.blocking > 0) {
      var reason = prompt('There are ' + a.blocking + ' unresolved blocker(s).\n\nTo accept risk and proceed, enter your reason:');
      if (!reason) return;
      var owner = prompt('Approver name:');
      if (!owner) return;
      alert('Risk accepted by ' + owner + '. Final decision: READY WITH CONDITIONS.\n\nRecord this in your change management system before cutover.');
    } else {
      alert('All required checks passed or accepted. Proceed with cutover.\n\nExport the UAT Report as evidence before cutover.');
    }
  };

  // FIX button — opens blocker modal with fix commands + Fixed / Not Relevant actions
  window.uatFocusActions = function() {
    var a = calculateUatReadinessAnalysis();
    var dismissed = {};
    try { dismissed = JSON.parse(localStorage.getItem('uat_fix_dismissed') || '{}'); } catch(e) {}

    // ── Build issue list from live analysis ───────────────────────────────
    var issues = [];

    // Check-based blockers (items that are incomplete and not yet dismissed)
    a.checks.forEach(function(c) {
      if (c.outOfScope || c.pass) return;
      if (dismissed['check:' + c.key]) return;
      var fixCmds = {
        app_health:    'curl -s -o /dev/null -w "%{http_code}" http://FLEX_IP/health',
        data_validation: 'diff <(ssh ospc-vm "md5sum /data/*.db | sort") <(ssh flex-vm "md5sum /data/*.db | sort")',
        database_validation: 'mysql -h FLEX_DB_HOST -u root -p -e "SELECT 1; SHOW DATABASES;"',
        reports_outputs: null,
        critical_systems: null,
        critical_issues: null,
        performance: null,
      };
      issues.push({
        key:      'check:' + c.key,
        severity: 'block',
        title:    c.label,
        detail:   c.detail,
        source:   c.source,
        fix:      c.fix,
        fixCmd:   fixCmds[c.key] || null,
        impact:   c.decisionImpact,
      });
    });

    // Service hard blocks
    a.svcHardBlocks.forEach(function(s) {
      if (dismissed['svc_hard:' + s.service]) return;
      issues.push({
        key:     'svc_hard:' + s.service,
        severity:'block',
        title:   s.service + ' — missing on FLEX',
        detail:  'Critical service not running on FLEX target.',
        source:  'Step 2 — Service Comparison',
        fix:     'Start and enable the service on the FLEX VM.',
        fixCmd:  'ssh flex-vm "sudo systemctl start ' + s.service + ' && sudo systemctl enable ' + s.service + '"',
        impact:  'Blocks cutover',
      });
    });

    // Service review gaps
    a.svcReviewGaps.forEach(function(s) {
      if (dismissed['svc_gap:' + s.service]) return;
      issues.push({
        key:     'svc_gap:' + s.service,
        severity:'review',
        title:   s.service + ' — needs review',
        detail:  'Present on OSPC source but missing on FLEX target.',
        source:  'Step 2 — Service Comparison',
        fix:     'Start the service on FLEX, or mark Not Relevant if it is expected to be absent.',
        fixCmd:  'ssh flex-vm "sudo systemctl status ' + s.service + ' 2>/dev/null || sudo systemctl start ' + s.service + '"',
        impact:  'Must be accepted before cutover',
      });
    });

    // Service warnings (extra on FLEX)
    a.svcWarnings.forEach(function(s) {
      if (dismissed['svc_warn:' + s.service]) return;
      issues.push({
        key:     'svc_warn:' + s.service,
        severity:'warn',
        title:   s.service + ' — extra on FLEX',
        detail:  'Running on FLEX but not found on OSPC source.',
        source:  'Step 2 — Service Comparison',
        fix:     'Confirm this is expected from the FLEX base image. Stop it if unexpected.',
        fixCmd:  'ssh flex-vm "sudo systemctl status ' + s.service + '"',
        impact:  'Warning only — does not block if accepted',
      });
    });

    // Performance blockers
    a.perfMetrics.forEach(function(m) {
      if (dismissed['perf:' + m.key]) return;
      var needsAction = m.effectiveBadge === 'FAIL' || (m.badge === 'REVIEW' && m.userDecision === 'Pending');
      if (!needsAction) return;
      issues.push({
        key:     'perf:' + m.key,
        severity: m.effectiveBadge === 'FAIL' ? 'block' : 'review',
        title:   'Performance: ' + m.label + ' — ' + m.effectiveBadge,
        detail:  m.text && m.text !== '—' ? m.text : 'Metric exceeded threshold or awaiting decision.',
        source:  'Step 3 — Performance Validation',
        fix:     'Go to Step 3. Set Your Decision for this metric (Pass / Fail / Accept Risk).',
        fixCmd:  null,
        impact:  'Blocks cutover until decision is set',
      });
    });

    // Dismissed items list (for the Undo section)
    var dismissedList = Object.keys(dismissed).map(function(k) {
      return { key: k, action: dismissed[k] };
    });

    // ── Render modal ───────────────────────────────────────────────────────
    var existing = document.getElementById('uat-fix-modal-overlay');
    if (existing) existing.remove();

    function sev(s) {
      if (s === 'block')  return { bg:'#fef2f2', border:'#fca5a5', badge:'BLOCKS CUTOVER',   badgeBg:'#dc2626' };
      if (s === 'review') return { bg:'#fffbeb', border:'#fde68a', badge:'NEEDS REVIEW',      badgeBg:'#d97706' };
      return                     { bg:'#fefce8', border:'#fef08a', badge:'WARNING',            badgeBg:'#ca8a04' };
    }

    function issueCard(issue) {
      var s = sev(issue.severity);
      var e = _udEsc;
      var cmdBlock = issue.fixCmd
        ? '<div style="margin:8px 0 0;background:#1e293b;border-radius:6px;padding:8px 12px;display:flex;align-items:center;gap:8px;">'
          + '<code style="flex:1;font-size:11px;color:#e2e8f0;font-family:monospace;white-space:pre-wrap;word-break:break-all;">' + e(issue.fixCmd) + '</code>'
          + '<button onclick="(function(){var t=document.createElement(\'textarea\');t.value=\'' + e(issue.fixCmd).replace(/'/g,"\\'") + '\';document.body.appendChild(t);t.select();document.execCommand(\'copy\');document.body.removeChild(t);this.textContent=\'Copied!\';setTimeout(function(){this.textContent=\'Copy\';}.bind(this),1500);}).call(this)" '
          + 'style="flex-shrink:0;font-size:10px;font-weight:700;padding:3px 10px;border:1px solid #475569;border-radius:4px;background:#334155;color:#e2e8f0;cursor:pointer;">Copy</button>'
          + '</div>'
        : '';
      return '<div style="background:' + s.bg + ';border:1px solid ' + s.border + ';border-radius:8px;padding:12px 14px;margin-bottom:10px;">'
        + '<div style="display:flex;align-items:flex-start;gap:10px;flex-wrap:wrap;">'
        + '<span style="font-size:10px;font-weight:800;background:' + s.badgeBg + ';color:#fff;padding:2px 8px;border-radius:4px;white-space:nowrap;flex-shrink:0;">' + s.badge + '</span>'
        + '<div style="flex:1;min-width:200px;">'
        + '<div style="font-size:13px;font-weight:700;color:#1e293b;margin-bottom:2px;">' + e(issue.title) + '</div>'
        + '<div style="font-size:11px;color:#475569;margin-bottom:2px;">' + e(issue.detail) + '</div>'
        + (issue.source ? '<div style="font-size:10px;color:#94a3b8;">Source: ' + e(issue.source) + '</div>' : '')
        + '</div>'
        + '</div>'
        + '<div style="margin-top:8px;font-size:11px;color:#374151;background:rgba(0,0,0,.04);border-radius:5px;padding:7px 10px;">'
        + '<strong>Fix:</strong> ' + e(issue.fix)
        + '</div>'
        + cmdBlock
        + '<div style="margin-top:10px;display:flex;gap:8px;">'
        + '<button onclick="uatFixDismiss(\'' + e(issue.key) + '\',\'fixed\')" style="font-size:11px;font-weight:700;padding:5px 14px;border:none;border-radius:6px;background:#16a34a;color:#fff;cursor:pointer;">✓ Fixed</button>'
        + '<button onclick="uatFixDismiss(\'' + e(issue.key) + '\',\'not_relevant\')" style="font-size:11px;font-weight:700;padding:5px 14px;border:1px solid #94a3b8;border-radius:6px;background:#f8fafc;color:#374151;cursor:pointer;">~ Not Relevant</button>'
        + '</div>'
        + '</div>';
    }

    var noIssues = issues.length === 0;
    var issuesHtml = noIssues
      ? '<div style="text-align:center;padding:32px 0;">'
        + '<div style="font-size:40px;">✓</div>'
        + '<div style="font-size:16px;font-weight:800;color:#16a34a;margin-top:8px;">No active blockers</div>'
        + '<div style="font-size:12px;color:#6b7280;margin-top:4px;">All issues resolved or accepted. You can proceed with cutover.</div>'
        + '</div>'
      : issues.map(issueCard).join('');

    var dismissedHtml = '';
    if (dismissedList.length) {
      dismissedHtml = '<details style="margin-top:16px;">'
        + '<summary style="font-size:11px;font-weight:700;color:#6b7280;cursor:pointer;padding:6px 0;">Previously dismissed (' + dismissedList.length + ') — click to expand / undo</summary>'
        + '<div style="margin-top:8px;display:flex;flex-direction:column;gap:6px;">'
        + dismissedList.map(function(d) {
            var actionLabel = d.action === 'fixed' ? '✓ Fixed' : '~ Not Relevant';
            var actionColor = d.action === 'fixed' ? '#16a34a' : '#6b7280';
            return '<div style="display:flex;align-items:center;gap:10px;padding:7px 10px;background:#f8fafc;border:1px solid #e2e8f0;border-radius:6px;">'
              + '<span style="flex:1;font-size:11px;color:#374151;">' + _udEsc(d.key.replace(/^[^:]+:/,'')) + '</span>'
              + '<span style="font-size:10px;font-weight:700;color:' + actionColor + ';">' + actionLabel + '</span>'
              + '<button onclick="uatFixUndo(\'' + _udEsc(d.key) + '\')" style="font-size:10px;font-weight:700;padding:3px 10px;border:1px solid #94a3b8;border-radius:4px;background:#fff;color:#374151;cursor:pointer;">Undo</button>'
              + '</div>';
          }).join('')
        + '</div></details>';
    }

    var overlay = document.createElement('div');
    overlay.id = 'uat-fix-modal-overlay';
    overlay.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(15,23,42,.55);display:flex;align-items:flex-start;justify-content:center;padding:32px 16px;overflow-y:auto;';
    overlay.innerHTML =
      '<div style="background:#fff;border-radius:12px;width:100%;max-width:680px;box-shadow:0 25px 60px rgba(0,0,0,.25);overflow:hidden;">'
      // Header
      + '<div style="background:#1e293b;padding:16px 20px;display:flex;align-items:center;gap:12px;">'
      + '<div style="width:32px;height:32px;border-radius:50%;background:#dc2626;display:flex;align-items:center;justify-content:center;font-size:16px;font-weight:900;color:#fff;flex-shrink:0;">!</div>'
      + '<div style="flex:1;">'
      + '<div style="font-size:15px;font-weight:900;color:#fff;">FIX BLOCKERS</div>'
      + '<div style="font-size:11px;color:#94a3b8;">' + (noIssues ? 'All clear — no active blockers' : issues.length + ' issue' + (issues.length > 1 ? 's' : '') + ' require action before cutover') + '</div>'
      + '</div>'
      + '<button onclick="if(typeof window.uatRerenderReadiness===\'function\')window.uatRerenderReadiness();this.textContent=\'↻ Done\'" style="font-size:11px;font-weight:700;padding:5px 12px;border:1px solid #475569;border-radius:6px;background:#334155;color:#e2e8f0;cursor:pointer;margin-right:8px;">↻ Re-run</button>'
      + '<button onclick="document.getElementById(\'uat-fix-modal-overlay\').remove()" style="font-size:18px;line-height:1;background:none;border:none;color:#94a3b8;cursor:pointer;padding:4px;">×</button>'
      + '</div>'
      // Body
      + '<div style="padding:20px;">'
      + issuesHtml
      + dismissedHtml
      + '</div>'
      // Footer
      + '<div style="padding:14px 20px;border-top:1px solid #e2e8f0;display:flex;justify-content:flex-end;gap:8px;">'
      + '<button onclick="document.getElementById(\'uat-fix-modal-overlay\').remove()" style="font-size:12px;font-weight:700;padding:7px 20px;border:1px solid #e2e8f0;border-radius:6px;background:#f8fafc;color:#374151;cursor:pointer;">Close</button>'
      + '</div>'
      + '</div>';

    document.body.appendChild(overlay);
    // Close on backdrop click
    overlay.addEventListener('click', function(e) { if (e.target === overlay) overlay.remove(); });
  };

  // Dismiss an issue from the FIX modal (Fixed or Not Relevant)
  window.uatFixDismiss = function(key, action) {
    var dismissed = {};
    try { dismissed = JSON.parse(localStorage.getItem('uat_fix_dismissed') || '{}'); } catch(e) {}
    dismissed[key] = action;
    try { localStorage.setItem('uat_fix_dismissed', JSON.stringify(dismissed)); } catch(e) {}
    if (typeof window.uatRerenderReadiness === 'function') window.uatRerenderReadiness();
    // Re-open modal with updated state
    window.uatFocusActions();
  };

  // Undo a dismissal
  window.uatFixUndo = function(key) {
    var dismissed = {};
    try { dismissed = JSON.parse(localStorage.getItem('uat_fix_dismissed') || '{}'); } catch(e) {}
    delete dismissed[key];
    try { localStorage.setItem('uat_fix_dismissed', JSON.stringify(dismissed)); } catch(e) {}
    if (typeof window.uatRerenderReadiness === 'function') window.uatRerenderReadiness();
    window.uatFocusActions();
  };

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
  window._uatFlavorData = window._uatFlavorData || null;

  window.uatLoadFlavorData = async function() {
    try {
      const res = await fetch('/api/uat/flavor-summary', {cache: 'no-store'});
      const data = await res.json();
      if (!res.ok || !data.ok || !data.vmData) throw new Error(data.error || 'Flavor summary unavailable');
      const vmData = data.vmData;
      const tgtMonthly = Number(vmData.targetMonthly || 0);
      const srcMonthly = tgtMonthly > 0 ? tgtMonthly * 2.5 : 24800;
      const savings = srcMonthly - (tgtMonthly || 18300);
      window._uatFlavorData = {
        vmData: vmData,
        tcoData: {
          srcMonthly: Math.round(srcMonthly),
          tgtMonthly: Math.round(tgtMonthly || 18300),
          savings: Math.round(savings),
          savingsPct: srcMonthly > 0 ? (savings / srcMonthly * 100).toFixed(1) : '0.0',
        },
      };
      try {
        var ts = new Date().toISOString();
        localStorage.setItem('osflex_uat_flavor_data', JSON.stringify(window._uatFlavorData));
        localStorage.setItem('osflex_uat_flavor_ts', ts);
      } catch(_) {}
      if (typeof window.uatRerenderReadiness === 'function') window.uatRerenderReadiness();
      return window._uatFlavorData;
    } catch (e) {
      window._uatFlavorData = window._uatFlavorData || {
        vmData: { srcVcpu:16, tgtVcpu:16, srcRam:64, tgtRam:64, srcDisk:1000, tgtDisk:1000, rows:0, sourceFlavors:[], targetFlavors:[], flavorPairs:[] },
        tcoData: { srcMonthly:24800, tgtMonthly:18300, savings:6500, savingsPct:'26.2' },
      };
      if (typeof window.uatRerenderReadiness === 'function') window.uatRerenderReadiness();
      return window._uatFlavorData;
    }
  };

  function hideGlobalThemeForUat() {
    if (document.body) document.body.classList.add('uat-dashboard-active');
    const theme = document.getElementById('top-theme-dropdown');
    if (theme) theme.style.setProperty('display', 'none', 'important');
  }

  window.uatSetMode = function(mode, silent) {
    hideGlobalThemeForUat();
    mode = mode === 'detailed' ? 'detailed' : 'compact';
    ['compact', 'detailed'].forEach(function(m) {
      const btn = document.getElementById('uat-mode-' + m);
      if (btn) btn.classList.toggle('ud-mode-btn--on', m === mode);
    });
    const content = document.getElementById('uat-content');
    if (content) content.setAttribute('data-uat-mode', mode);
    const msg = document.getElementById('uat-message');
    if (mode === 'detailed') {
      if (content) {
        content.querySelectorAll('[data-uat-step]').forEach(function(panel) { panel.style.display = ''; });
        content.scrollTo({ top: 0, behavior: silent ? 'auto' : 'smooth' });
      }
      if (msg) msg.style.display = '';
    } else if (typeof window.uatNavTo === 'function') {
      window.uatNavTo(1, true);
    }
    if (!silent) {
      try { localStorage.setItem('uatMode', mode); } catch(e) {}
    }
  };

  window.uatNavTo = function(step, instant) {
    hideGlobalThemeForUat();
    const content = document.getElementById('uat-content');
    if (!content) return;
    step = Number(step) || 1;
    /* Update topbar title to match selected step */
    var _TITLES = {
      1: ['Step 1 — Server Targets',        'Define business systems, standalone servers, and databases'],
      2: ['Step 2 — Service Comparison',    'OSPC → FLEX service-by-service comparison and validation'],
      3: ['Step 3 — Performance Validation','Performance benchmarks and baseline comparison'],
      4: ['Step 4 — Issues Tracker',        'Issue tracking, risk assessment and remediation'],
      5: ['Step 5 — Cutover Readiness',     'Post-migration acceptance testing summary and decision']
    };
    var _t = _TITLES[step] || _TITLES[5];
    var _th = document.getElementById('uat-tb-title');
    var _ts = document.getElementById('uat-tb-sub');
    if (_th) _th.textContent = _t[0];
    if (_ts) _ts.textContent = _t[1];
    content.setAttribute('data-uat-mode', 'compact');
    ['compact', 'detailed'].forEach(function(m) {
      const btn = document.getElementById('uat-mode-' + m);
      if (btn) btn.classList.toggle('ud-mode-btn--on', m === 'compact');
    });
    content.querySelectorAll('[data-uat-step]').forEach(function(panel) {
      panel.style.display = Number(panel.getAttribute('data-uat-step')) === step ? '' : 'none';
    });
    const msg = document.getElementById('uat-message');
    if (msg) msg.style.display = step === 5 ? 'none' : '';
    document.querySelectorAll('#uat-sidebar .udsb-item').forEach(function(btn, idx) {
      const isReport = idx > 4;
      btn.classList.toggle('udsb-active', !isReport && idx === step - 1);
    });
    const target = content.querySelector('[data-uat-step="' + step + '"]');
    if (!target) return;
    let top = 0, el = target;
    while (el && el !== content) {
      top += el.offsetTop || 0;
      el = el.offsetParent;
    }
    content.scrollTo({ top: Math.max(0, top - 10), behavior: instant ? 'auto' : 'smooth' });
  };

  document.addEventListener('DOMContentLoaded', () => {
    if ($('uat-console')) {
      setTimeout(function() { window.uatSetMode('compact', true); }, 0);
      window.uatLoadFlavorData().catch(function() {});
      loadUAT().then(() => { const m=$('uat-message'); if(m) m.style.display='none'; }).catch(err => setMessage(err.message, false));
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
            .then(function(data) { UAT.scope = data.rows; _persistScopeToStorage(); })
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
            .then(function(data) { UAT.scope = data.rows; _persistScopeToStorage(); })
            .catch(function() {});
        }, 800);
      }
    });
  })();
})();
