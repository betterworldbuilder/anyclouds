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
  };

  const $ = (id) => document.getElementById(id);
  const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[ch]));
  const slug = (value) => String(value || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  const badge = (value) => `<span class="uat-badge ${slug(value)}">${esc(value)}</span>`;

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

  function renderSummary() {
    const loaded = UAT.artifacts.filter(a => a.status === 'Loaded').length;
    const missing = UAT.artifacts.filter(a => a.status === 'Missing').length;
    const invalid = UAT.artifacts.filter(a => a.status === 'Invalid').length;
    const critical = UAT.scope.filter(s => s.criticality === 'Critical').length;
    $('uat-summary-grid').innerHTML = [
      ['Artifacts Loaded', loaded],
      ['Missing', missing],
      ['Invalid', invalid],
      ['Systems In Scope', UAT.scope.length],
      ['Critical Systems', critical],
      ['Readiness', UAT.readiness.status || 'Not Ready'],
    ].map(([label, value]) => `
      <div class="uat-stat">
        <div class="uat-stat-label">${esc(label)}</div>
        <div class="uat-stat-value">${esc(value)}</div>
      </div>
    `).join('');
  }

  function renderArtifacts() {
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
    $('uat-scope-body').innerHTML = UAT.scope.map((row, i) => `
      <tr data-row="${i}">
        <td>${scopeSelect(row.system_type, ['App', 'DB'])}</td>
        <td><input class="uat-input" value="${esc(row.business_system_name)}"></td>
        <td>${scopeSelect(row.tier, ['Frontend', 'Backend', 'Database', 'Batch', 'External Integration'])}</td>
        <td><input class="uat-input" value="${esc(row.source_host)}"></td>
        <td><input class="uat-input" value="${esc(row.target_host)}"></td>
        <td><input class="uat-input" value="${esc(row.target_ip)}"></td>
        <td><input class="uat-input" value="${esc(row.owner)}"></td>
        <td><input class="uat-input" value="${esc(row.dependencies)}"></td>
        <td>${scopeSelect(row.criticality, ['Critical', 'Secondary', 'Low'])}</td>
        <td>${scopeSelect(row.uat_status, ['Not Started', 'Testing', 'Passed', 'Failed', 'Blocked'])}</td>
        <td>${scopeSelect(row.execution_mode, ['local', 'ssh'])}</td>
        <td><input class="uat-input" value="${esc(row.ssh_user || 'ubuntu')}"></td>
        <td><input class="uat-input" value="${esc(row.ssh_host || row.target_ip || '')}"></td>
        <td><input class="uat-input" value="${esc(row.ssh_key_path || '')}"></td>
        <td><input class="uat-input" value="${esc(row.ssh_port || '22')}"></td>
        <td><textarea class="uat-textarea">${esc(row.notes)}</textarea></td>
        <td><button class="uat-btn uat-btn-danger" onclick="uatDeleteScope(${i})">Delete</button></td>
      </tr>
    `).join('');
  }

  function readScopeTable() {
    const rows = [];
    document.querySelectorAll('#uat-scope-body tr').forEach((tr, i) => {
      const fields = tr.querySelectorAll('input, select, textarea');
      rows.push({
        system_id: UAT.scope[i]?.system_id || `scope-${String(i + 1).padStart(3, '0')}`,
        system_type: fields[0].value,
        business_system_name: fields[1].value,
        tier: fields[2].value,
        source_host: fields[3].value,
        target_host: fields[4].value,
        target_ip: fields[5].value,
        owner: fields[6].value,
        dependencies: fields[7].value,
        criticality: fields[8].value,
        uat_status: fields[9].value,
        execution_mode: fields[10].value,
        ssh_user: fields[11].value,
        ssh_host: fields[12].value,
        ssh_key_path: fields[13].value,
        ssh_port: fields[14].value,
        notes: fields[15].value,
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

  window.uatDeleteScope = async function (index) {
    readScopeTable();
    UAT.scope.splice(index, 1);
    await saveScope();
  };

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
    const fields = [
      'ospc_avg_response_ms', 'flex_avg_response_ms', 'ospc_p95_ms', 'flex_p95_ms',
      'target_concurrent_users', 'peak_concurrent_users_tested', 'active_sessions_tested',
      'api_error_rate_percent', 'db_avg_query_ms', 'report_generation_seconds',
      'mobile_app_load_seconds', 'mobile_tap_response_ms', 'network_latency_ms',
      'upload_mbps', 'download_mbps',
    ];
    $('uat-performance-grid').innerHTML = fields.map(field => `
      <label>${esc(field.replaceAll('_', ' '))}
        <input class="uat-input" name="${esc(field)}" value="${esc(UAT.performance[field])}">
      </label>
    `).join('') + `
      <label>mobile lag status
        <select class="uat-select" name="mobile_lag_status">
          ${['Pass', 'Review', 'Failed'].map(s => `<option${s === UAT.performance.mobile_lag_status ? ' selected' : ''}>${s}</option>`).join('')}
        </select>
      </label>
    `;
    const avg = UAT.performance.delta_avg_response_percent;
    const p95 = UAT.performance.delta_p95_percent;
    $('uat-performance-status').innerHTML = `
      <div class="uat-stat"><div class="uat-stat-label">Avg response delta</div><div class="uat-stat-value">${avg == null ? '—' : avg.toFixed(1) + '%'}</div></div>
      <div class="uat-stat"><div class="uat-stat-label">P95 delta</div><div class="uat-stat-value">${p95 == null ? '—' : p95.toFixed(1) + '%'}</div></div>
      <div class="uat-stat"><div class="uat-stat-label">Performance Status</div><div class="uat-stat-value">${badge(UAT.performance.overall_performance_status || 'Review')}</div></div>
    `;
  }

  function readPerformanceForm() {
    const data = {};
    document.querySelectorAll('#uat-performance-grid [name]').forEach(el => data[el.name] = el.value);
    UAT.performance = {...UAT.performance, ...data};
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
    const r = UAT.readiness || {};
    $('uat-readiness-panel').innerHTML = `
      <div class="uat-readiness">
        <div>${badge(r.status || 'Not Ready')}</div>
        <div class="uat-note">Critical systems: ${esc(r.critical_systems || 0)} · Critical open issues: ${esc(r.critical_open_issues || 0)} · Performance: ${esc(r.performance_status || 'Review')}</div>
        ${(r.blockers || []).length ? `<ul class="uat-blockers">${r.blockers.map(b => `<li>${esc(b)}</li>`).join('')}</ul>` : '<div class="uat-note">No blocking rules currently triggered.</div>'}
      </div>
    `;
  }

  function renderRuns() {
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
    $('uat-export-links').innerHTML = links;
    setMessage('UAT reports exported to outputs/uat/.');
  };

  window.CloudJumperUAT = {load: loadUAT};
  document.addEventListener('DOMContentLoaded', () => {
    if ($('uat-console')) {
      loadUAT().catch(err => setMessage(err.message, false));
    }
  });
})();
