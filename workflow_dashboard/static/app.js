const logBox = document.getElementById('logBox');
const SCANNER_MODE = (window.OSFLEX_SCANNER_MODE || 'ospc').toLowerCase();
const SCANNER_PROVIDER = (window.OSFLEX_SCANNER_PROVIDER || 'aws').toLowerCase();
const validationFindingsCard = document.getElementById('validationFindingsCard');
const validationFindingsSummary = document.getElementById('validationFindingsSummary');
const validationFindingsSource = document.getElementById('validationFindingsSource');
const validationFindingsTable = document.getElementById('validationFindingsTable');

const summaryEls = {
  region: document.getElementById('sumRegion'),
  overview: document.getElementById('sumOverview'),
  flavorMap: document.getElementById('sumFlavorMap'),
  blockMap: document.getElementById('sumBlockMap'),
  lbMap: document.getElementById('sumLbMap'),
  net: document.getElementById('sumNet'),
  router: document.getElementById('sumRouter'),
  key: document.getElementById('sumKey'),
};

const logEntries = [];
let logFilter = 'all';

function shortFlexRegionValue(value) {
  const text = String(value || '').trim().toUpperCase();
  const match = text.match(/^([A-Z]{3})\d*$/);
  return match ? match[1] : text;
}

function currentFlex2FlexSourceRegion() {
  return document.getElementById('credSourceFlexRegion')?.value || localStorage.getItem('cred_source_flex_region') || 'DFW3';
}

function currentFlex2FlexTargetRegion() {
  return document.getElementById('credFlexRegion')?.value || localStorage.getItem('cred_flex_region') || 'IAD3';
}

function syncFlex2FlexTargetRegionControls() {
  if (SCANNER_MODE !== 'flex2flex') return;
  const mapTarget = document.getElementById('mapTargetRegion');
  if (mapTarget) {
    mapTarget.value = shortFlexRegionValue(currentFlex2FlexTargetRegion());
    mapTarget.dispatchEvent(new Event('input'));
  }
}

function log(msg) {
  const ts = new Date().toLocaleTimeString();
  const text = String(msg || '');
  const lower = text.toLowerCase();
  const level = lower.includes('error') || lower.includes('failed') || lower.includes('traceback')
    ? 'error'
    : (lower.includes('warn') || lower.includes('timed out') ? 'warn' : 'info');
  logEntries.push({ ts, text, level });
  renderLog();
}

function renderLog() {
  const rows = logEntries
    .filter((entry) => logFilter === 'all' || entry.level === logFilter)
    .map((entry) => `[${entry.ts}] [${entry.level.toUpperCase()}] ${entry.text}`);
  logBox.textContent = rows.join('\n') || 'No log entries for current filter.';
  logBox.scrollTop = logBox.scrollHeight;
}

function setStepStatus(chipId, state, label) {
  const chip = document.getElementById(chipId);
  if (!chip) return;
  chip.classList.remove('idle', 'running', 'success', 'failed');
  chip.classList.add(state);
  chip.textContent = label;
}

async function apiGet(url) {
  const res = await fetch(url);
  const text = await res.text();
  let data;
  try {
    data = text ? JSON.parse(text) : {};
  } catch (e) {
    throw new Error(`GET ${url} returned ${res.status} ${res.headers.get('content-type') || ''}: ${text.slice(0, 120)}`);
  }
  if (!res.ok) throw new Error(data.error || `GET ${url} failed`);
  return data;
}

async function apiPost(url, payload) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload || {}),
  });
  const text = await res.text();
  let data;
  try {
    data = text ? JSON.parse(text) : {};
  } catch (e) {
    throw new Error(`POST ${url} returned ${res.status} ${res.headers.get('content-type') || ''}: ${text.slice(0, 120)}`);
  }
  if (!res.ok) throw new Error(data.error || `POST ${url} failed`);
  return data;
}

async function withButtonBusy(buttonId, actionName, fn) {
  const btn = document.getElementById(buttonId);
  const originalText = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'IN PROGRESS - PLEASE WAIT...';
  log(`${actionName}: IN PROGRESS - PLEASE WAIT...`);
  try {
    await fn();
  } finally {
    btn.disabled = false;
    btn.textContent = originalText;
  }
}

function updateRunSummary() {
  if (!summaryEls.region || !document.getElementById('mapTargetRegion')) return;
  summaryEls.region.textContent = document.getElementById('mapTargetRegion').value || '-';
  summaryEls.overview.textContent = document.getElementById('mapInventory').value || '-';
  summaryEls.flavorMap.textContent = document.getElementById('depFlavorMap').value || '-';
  summaryEls.blockMap.textContent = document.getElementById('depBlockMap').value || '-';
  summaryEls.lbMap.textContent = document.getElementById('depLbMap').value || '-';
  const priv = document.getElementById('depPrivateNet').value || '-';
  const subnet = document.getElementById('depSubnetName').value || '-';
  summaryEls.net.textContent = `${priv} / ${subnet}`;
  summaryEls.router.textContent = document.getElementById('depRouterName').value || '-';
  summaryEls.key.textContent = document.getElementById('depKeyName').value || '-';
}

document.getElementById('credFlexRegion')?.addEventListener('change', syncFlex2FlexTargetRegionControls);
document.getElementById('credFlexRegion')?.addEventListener('input', syncFlex2FlexTargetRegionControls);
syncFlex2FlexTargetRegionControls();

function markInvalid(id, isInvalid) {
  const el = document.getElementById(id);
  if (!el) return;
  el.classList.toggle('input-invalid', Boolean(isInvalid));
}

function clearValidationMarks(ids) {
  ids.forEach((id) => markInvalid(id, false));
}

function isValidCidr(cidr) {
  const text = String(cidr || '').trim();
  const m = text.match(/^(\d{1,3}\.){3}\d{1,3}\/(\d{1,2})$/);
  if (!m) return false;
  const [ip, prefixText] = text.split('/');
  const octets = ip.split('.').map((v) => Number(v));
  const prefix = Number(prefixText);
  if (octets.length !== 4 || octets.some((o) => Number.isNaN(o) || o < 0 || o > 255)) return false;
  if (Number.isNaN(prefix) || prefix < 0 || prefix > 32) return false;
  return true;
}

function fillSelect(id, files, predicate, autoPrefix) {
  const el = document.getElementById(id);
  if (!el) return;
  const prev = el.value;
  el.innerHTML = '';
  const empty = document.createElement('option');
  empty.value = '';
  empty.textContent = '-- select file --';
  el.appendChild(empty);

  files.filter(predicate).forEach((f) => {
    const opt = document.createElement('option');
    opt.value = f;
    opt.textContent = f;
    el.appendChild(opt);
  });

  if (prev && [...el.options].some(o => o.value === prev)) {
    el.value = prev;
  } else if (autoPrefix) {
    const match = [...el.options].find(o => o.value === autoPrefix);
    if (match) el.value = match.value;
  }
}

function renderFileList(files) {
  const ul = document.getElementById('fileList');
  ul.innerHTML = '';
  files.forEach((f) => {
    const li = document.createElement('li');
    li.textContent = f;
    ul.appendChild(li);
  });
}

async function refreshFiles() {
  const data = await apiGet('/api/files');
  const files = data.files || [];

  renderFileList(files);

  // Auto-select prefix from OSPC Account ID field
  const acctEl = document.getElementById('ovAccountId');
  const ap = acctEl && acctEl.value.trim() ? acctEl.value.trim() + '_' : '';
  const sourceFileMatch = (f) => {
    const n = String(f || '').toLowerCase();
    if (SCANNER_MODE === 'flex2flex') return n.startsWith('flex2flex_') || n.includes('_flex2flex_');
    if (SCANNER_MODE === 'hyperflex') return n.includes(`_${SCANNER_PROVIDER}_hyperflex_`);
    return !n.includes('flex2flex') && !n.includes('_hyperflex_');
  };
  const overviewMatch = f => sourceFileMatch(f) && f.endsWith('_overview.csv');
  const flavorMatch = f => sourceFileMatch(f) && (f.endsWith('_flavormap.csv') || f.includes('flavormap'));
  const blockMatch = f => sourceFileMatch(f) && (f.endsWith('_blockmap.csv') || f.includes('blockmap'));
  const lbMatch = f => sourceFileMatch(f) && (f.endsWith('_lbmap.csv') || f.includes('lbmap') || f.includes('lb_mapping'));
  const sourcePrefix = SCANNER_MODE === 'flex2flex' ? `flex2flex_${ap}` : (SCANNER_MODE === 'hyperflex' ? `${ap}${SCANNER_PROVIDER}_hyperflex_` : ap);

  fillSelect('admInventory', files, overviewMatch, sourcePrefix + 'overview.csv');
  fillSelect('mapInventory', files, overviewMatch, sourcePrefix + 'overview.csv');
  fillSelect('valFlavorMap', files, flavorMatch, sourcePrefix + 'flavormap.csv');
  fillSelect('valBlockMap', files, blockMatch, sourcePrefix + 'blockmap.csv');
  fillSelect('valLbMap', files, lbMatch, sourcePrefix + 'lbmap.csv');
  fillSelect('depFlavorMap', files, flavorMatch, sourcePrefix + 'flavormap.csv');
  fillSelect('depBlockMap', files, blockMatch, sourcePrefix + 'blockmap.csv');
  fillSelect('depLbMap', files, lbMatch, sourcePrefix + 'lbmap.csv');
  fillSelect('migInventory', files, overviewMatch, sourcePrefix + 'overview.csv');
  fillSelect('migFlavorMap', files, flavorMatch, sourcePrefix + 'flavormap.csv');
  fillSelect('migCustomList', files, f => f.endsWith('.csv'), '');
  
  const migStrategyEl = document.getElementById('migStrategy');
  const strat = migStrategyEl ? migStrategyEl.value : '';
  fillSelect('exeBashScript', files, f => f.endsWith('.sh') && (!strat || f.startsWith(`${strat}_`)));
  
  updateRunSummary();
}

const migUseCustomCsv = document.getElementById('migUseCustomCsv');
if (migUseCustomCsv) {
  migUseCustomCsv.addEventListener('change', () => {
    document.getElementById('migStandardInputGroup').style.display = migUseCustomCsv.checked ? 'none' : 'contents';
    document.getElementById('migCustomInputGroup').style.display = migUseCustomCsv.checked ? 'grid' : 'none';
  });
}

function showResult(action, data) {
  log(`${action}: rc=${data.return_code} ok=${data.ok}`);
  if (data.created && data.created.length) {
    log(`Created files: ${data.created.join(', ')}`);
  }
  if (data.log) {
    log('--- script output start ---');
    log(data.log);
    log('--- script output end ---');
  }
}

function renderDeployNextSteps(data) {
  if (!data || !data.ok) return;
  const created = Array.isArray(data.created) ? data.created : [];
  const scriptName = created.find(n => n.endsWith('.sh') && !n.endsWith('_rollback.sh'));
  if (scriptName) {
    fetch(`/api/file-content?name=${encodeURIComponent(scriptName)}`)
      .then(r => r.json())
      .then(d => {
        if (d.ok && d.content) {
          const ta = document.getElementById('scriptContent');
          if (ta) { ta.value = d.content; log(`Auto-pasted ${scriptName} into FLEX Deployment Script box.`); }
          const sf = document.getElementById('scriptFile');
          if (sf) sf.value = scriptName;
        }
      }).catch(() => {});
  }
}

function escapeHtml(text) {
  return String(text || '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function renderValidationFindings(data) {
  const findings = Array.isArray(data.validation_findings) ? data.validation_findings : [];
  const summary = data.validation_summary || {};
  if (!findings.length) {
    validationFindingsCard.style.display = 'none';
    validationFindingsTable.innerHTML = '';
    validationFindingsSummary.textContent = '';
    validationFindingsSource.textContent = '';
    return;
  }

  const err = Number(summary.ERROR || 0);
  const warn = Number(summary.WARN || 0);
  const info = Number(summary.INFO || 0);
  validationFindingsSummary.textContent = `Errors: ${err} | Warnings: ${warn} | Info: ${info}`;
  const reportPath = data.validation_report_path || '(unknown)';
  const flavorMap = data.validation_flavor_mapping || '(unknown)';
  const blockMap = data.validation_block_mapping || '(unknown)';
  const lbMap = data.validation_lb_mapping || '(none)';
  validationFindingsSource.textContent = `Report: ${reportPath} | Flavor Map: ${flavorMap} | Block Map: ${blockMap} | LB Map: ${lbMap}`;

  const rows = findings.map((f) => {
    const sev = (f.severity || '').toUpperCase();
    const sevClass = sev === 'ERROR' ? 'sev-error' : (sev === 'WARN' ? 'sev-warn' : 'sev-info');
    return `<tr>
      <td><span class="sev-pill ${sevClass}">${escapeHtml(sev)}</span></td>
      <td>${escapeHtml(f.code)}</td>
      <td>${escapeHtml(f.scope)}</td>
      <td>${escapeHtml(f.message)}</td>
    </tr>`;
  }).join('');

  validationFindingsTable.innerHTML = `
    <thead>
      <tr>
        <th>Severity</th>
        <th>Code</th>
        <th>Scope</th>
        <th>Message</th>
      </tr>
    </thead>
    <tbody>${rows}</tbody>
  `;
  validationFindingsCard.style.display = 'block';
}

const refreshBtn = document.getElementById('refreshFilesBtn');
if (refreshBtn) refreshBtn.addEventListener('click', async () => {
  try {
    await refreshFiles();
    log('File list refreshed.');
  } catch (e) {
    log(`Error refreshing files: ${e.message}`);
  }
});

const uploadBtn = document.getElementById('uploadBtn');
if (uploadBtn) uploadBtn.addEventListener('click', async () => {
  const input = document.getElementById('uploadFile');
  if (!input.files || !input.files.length) {
    log('Select a file to upload first.');
    return;
  }
  const fd = new FormData();
  fd.append('file', input.files[0]);
  try {
    const res = await fetch('/api/upload', { method: 'POST', body: fd });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Upload failed');
    log(`Uploaded: ${data.saved_as}`);
    await refreshFiles();
  } catch (e) {
    log(`Upload error: ${e.message}`);
  }
});

// ── SG Rule Card Renderer + FLEX Import ────────────────────────────────────
window._sgGroupsCache = {};

async function renderSGRules() {
  const card = document.getElementById('sgRulesCard');
  const container = document.getElementById('sgRulesContainer');
  const countChip = document.getElementById('sgRulesCount');
  if (!card || !container) return;

  const ovSelect = document.getElementById('mapInventory') || document.getElementById('admInventory');
  const csvName = ovSelect ? ovSelect.value : '';
  if (!csvName) { card.style.display = 'none'; return; }

  try {
    const res = await fetch(`/api/files/read?name=${encodeURIComponent(csvName)}`);
    if (!res.ok) { card.style.display = 'none'; return; }
    const csvText = await res.text();
    const lines = csvText.split('\n').filter(l => l.trim());
    if (lines.length < 2) { card.style.display = 'none'; return; }
    const headers = lines[0].split(',').map(h => h.trim().replace(/^"|"$/g, ''));
    const parseRow = (line) => {
      const vals = []; let cur = '', inQ = false;
      for (const ch of line) {
        if (ch === '"') { inQ = !inQ; continue; }
        if (ch === ',' && !inQ) { vals.push(cur.trim()); cur = ''; continue; }
        cur += ch;
      }
      vals.push(cur.trim());
      const obj = {}; headers.forEach((h,i) => obj[h] = vals[i]||'');
      return obj;
    };
    const allRows  = lines.slice(1).map(parseRow);
    const sgGroups = {};
    const sgParents = allRows.filter(r => r.service_type === 'security_group');
    const sgRules   = allRows.filter(r => r.service_type === 'security_group_rule');

    sgParents.forEach(sg => {
      let detail = {};
      try { detail = JSON.parse(sg.details_json || '{}'); } catch(_) {}
      sgGroups[sg.resource_id] = {
        id: sg.resource_id, name: sg.name || 'Unnamed SG',
        region: sg.region || '', description: detail.description || '', rules: []
      };
    });

    sgRules.forEach(rule => {
      const sgId = rule.network_id || rule.security_group_id || '';
      if (!sgGroups[sgId]) sgGroups[sgId] = { id:sgId, name:rule.name||'Unknown', region:rule.region||'', description:'', rules:[] };
      let d = {};
      try { d = JSON.parse(rule.details_json || '{}'); } catch(_) {}
      sgGroups[sgId].rules.push({
        id: rule.resource_id,
        direction: d.direction || 'ingress',
        ethertype: d.ethertype || '',
        protocol:  d.protocol  || '',
        portMin:   d.port_range_min  != null ? String(d.port_range_min)  : '',
        portMax:   d.port_range_max  != null ? String(d.port_range_max)  : '',
        cidr:      d.remote_ip_prefix || rule.cidr || '',
      });
    });

    window._sgGroupsCache = sgGroups;

    const sgIds = Object.keys(sgGroups);
    const totalRules = sgRules.length;
    if (!sgIds.length) { card.style.display = 'none'; return; }

    const inTotal = sgRules.filter(r => { try{return (JSON.parse(r.details_json||'{}').direction||'ingress')==='ingress';}catch(_){return true;} }).length;
    countChip.textContent = `${sgIds.length} groups · ${totalRules} rules (↓${inTotal} in / ↑${totalRules-inTotal} out)`;
    countChip.className = 'status-chip success';
    container.innerHTML = '';

    sgIds.forEach(sgId => {
      const sg = sgGroups[sgId];
      const ingress = sg.rules.filter(r => (r.direction||'ingress')==='ingress');
      const egress  = sg.rules.filter(r => r.direction==='egress');

      const ruleRows = (rules) => rules.map(r => {
        const proto = (r.protocol||'Any').toUpperCase();
        const port  = r.portMin ? (r.portMin===r.portMax ? r.portMin : `${r.portMin}\u2013${r.portMax}`) : 'Any';
        const cidr  = r.cidr || 'Any';
        const dir   = (r.direction||'ingress').toLowerCase();
        return `<div class="sg-rule">
          <div class="sg-rule-row">
            <span class="sg-pill ${dir==='egress'?'egress':'ingress'}">${dir.toUpperCase()}</span>
            <span class="sg-arrow">${dir==='egress'?'&#8594;':'&#8592;'}</span>
            <span class="sg-pill proto">${escapeHtml(proto)}</span>
            <span class="sg-pill port">:${escapeHtml(port)}</span>
            <span class="sg-pill cidr">&#8853; ${escapeHtml(cidr)}</span>
            ${r.ethertype?`<span class="sg-pill ether">${escapeHtml(r.ethertype)}</span>`:''}
          </div>
        </div>`;
      }).join('');

      const allRulesHtml = ruleRows([...ingress,...egress]) ||
        '<div style="color:#616e88;padding:8px;font-size:.85rem">No rules defined</div>';

      const div = document.createElement('div');
      div.className = 'sg-card';
      const safeId = JSON.stringify(sgId);
      div.innerHTML = `
        <div class="sg-card-header" onclick="const g=this.nextElementSibling;const o=g.style.display!=='none';g.style.display=o?'none':'grid';this.querySelector('.sg-toggle').classList.toggle('open',!o)">
          <h3>&#128737;&#65039; ${escapeHtml(sg.name)}</h3>
          ${sg.region?`<span class="sg-badge">${escapeHtml(sg.region.toUpperCase())}</span>`:''}
          <span class="sg-badge" style="background:rgba(163,190,140,.15);color:#a3be8c">&#8595;${ingress.length} in</span>
          <span class="sg-badge" style="background:rgba(208,135,112,.15);color:#d08770">&#8593;${egress.length} out</span>
          <span class="sg-badge">${sg.rules.length} total</span>
          <button class="btn" style="margin-left:auto;padding:3px 12px;font-size:.75rem;background:linear-gradient(135deg,#2e3440,#3b4252);border:1px solid rgba(136,192,208,.3)"
            onclick="event.stopPropagation();importOneSGToFlex(${safeId})">&#11014; Import to FLEX</button>
          <span class="sg-toggle open">&#9654;</span>
        </div>
        ${sg.description?`<div style="color:#8a90a0;font-size:.8rem;margin-bottom:6px">${escapeHtml(sg.description)}</div>`:''}
        <div class="sg-rules-grid" style="display:grid">${allRulesHtml}</div>
      `;
      container.appendChild(div);
    });

    card.style.display = '';
  } catch(e) {
    log(`SG render error: ${e.message}`);
    card.style.display = 'none';
  }
}

// ── SG → FLEX Import helpers ─────────────────────────────────────────────────
function buildSGImportScript(sgIds) {
  const groups = window._sgGroupsCache || {};
  const ids = sgIds || Object.keys(groups);
  const L = ['#!/usr/bin/env bash', 'set -uo pipefail', ''];
  ids.forEach(id => {
    const sg = groups[id]; if(!sg) return;
    const n   = sg.name.replace(/'/g, "'\\\\''")
    const desc = (sg.description || `Imported from OSPC ${sg.region}`).replace(/'/g, "'\\\\''");
    L.push(`# ── SG: ${sg.name}`);
    L.push(`if openstack security group show '${n}' >/dev/null 2>&1; then`);
    L.push(`  echo 'SG exists, skipping: ${n}'`);
    L.push(`else`);
    L.push(`  openstack security group create --description '${desc}' '${n}'`);
    sg.rules.forEach(r => {
      const dir   = r.direction || 'ingress';
      const proto = r.protocol  || 'any';
      const cidr  = r.cidr      || '0.0.0.0/0';
      let cmd = `  openstack security group rule create --${dir} --protocol ${proto} --remote-ip ${cidr}`;
      if (r.portMin && r.portMax) cmd += ` --dst-port ${r.portMin}:${r.portMax}`;
      cmd += ` '${n}' || true`;
      L.push(cmd);
    });
    L.push('fi\n');
  });
  return L.join('\n');
}

async function importOneSGToFlex(sgId) {
  await runSGImport(buildSGImportScript([sgId]), `"${(window._sgGroupsCache[sgId]||{}).name||sgId}"`);
}
async function importAllSGsToFlex() {
  await runSGImport(buildSGImportScript(null), 'ALL Security Groups');
}
async function runSGImport(script, label) {
  const chip = document.getElementById('sgImportStatus');
  if(chip){chip.textContent=`Importing ${label}…`;chip.className='status-chip running';}
  log(`⬆ Sending SG import to FLEX: ${label}`);
  try {
    const data = await apiPost('/api/flex/import-sgs', {script});
    const ok = data.ok || data.return_code===0;
    if(chip){chip.textContent=ok?`✅ Done`:`❌ Failed`;chip.className=`status-chip ${ok?'success':'failed'}`;}
    showResult(`SG Import: ${label}`, data);
  } catch(e) {
    if(chip){chip.textContent='❌ Error';chip.className='status-chip failed';}
    log(`SG Import error: ${e.message}`);
  }
}




const runOverviewBtn = document.getElementById('runOverviewBtn');
if (runOverviewBtn) runOverviewBtn.addEventListener('click', async () => {
  clearValidationMarks(['ovUsername', 'ovApiKey', 'ovAccountId']);
  const username = document.getElementById('ovUsername').value.trim();
  const apiKey = document.getElementById('ovApiKey').value.trim();
  const accountId = document.getElementById('ovAccountId').value.trim();
  const flexAuthUrl = SCANNER_MODE === 'flex2flex'
    ? (document.getElementById('credSourceFlexAuthUrl')?.value || localStorage.getItem('cred_source_flex_auth_url') || '')
    : (localStorage.getItem('cred_flex_auth_url') || document.getElementById('credFlexAuthUrl')?.value || '');
  const flexDomain = SCANNER_MODE === 'flex2flex'
    ? (document.getElementById('credSourceFlexDomain')?.value || localStorage.getItem('cred_source_flex_domain') || 'rackspace_cloud_domain')
    : (localStorage.getItem('cred_flex_domain') || document.getElementById('credFlexDomain')?.value || 'rackspace_cloud_domain');
  if (!username || !apiKey || !accountId || (SCANNER_MODE === 'flex2flex' && !flexAuthUrl.trim())) {
    markInvalid('ovUsername', !username);
    markInvalid('ovApiKey', !apiKey);
    markInvalid('ovAccountId', !accountId);
    log(SCANNER_MODE === 'flex2flex'
      ? 'FLEX Auth URL, username, password, and project ID are required.'
      : (SCANNER_MODE === 'hyperflex' ? 'Hyperscaler account/access ID, secret/key, and account/project ID are required.' : 'Username, API Key, and Account ID are required.'));
    setStepStatus('statusOverview', 'failed', 'Failed');
    return;
  }
  setStepStatus('statusOverview', 'running', 'Running');
  const overviewAction = SCANNER_MODE === 'flex2flex' ? 'flex2flex_overview' : (SCANNER_MODE === 'hyperflex' ? `${SCANNER_PROVIDER}_hyperflex_overview` : 'account_overview.py');
  await withButtonBusy('runOverviewBtn', overviewAction, async () => {
    try {
      const regionSelect = document.getElementById('ovRegionSelect');
      const selectedRegions = SCANNER_MODE === 'flex2flex'
        ? [currentFlex2FlexSourceRegion()]
        : (regionSelect
        ? Array.from(regionSelect.selectedOptions).map(opt => opt.value).filter(Boolean)
        : Array.from(document.querySelectorAll('input[name="ovRegions"]:checked')).map(cb => cb.value));
      const payload = {
        username,
        api_key: apiKey,
        password: apiKey,
        account_id: accountId,
        project_id: accountId,
        auth_url: flexAuthUrl,
        domain: flexDomain,
        regions: selectedRegions.join(','),
      };
      payload.provider = SCANNER_PROVIDER;
      const overviewEndpoint = SCANNER_MODE === 'flex2flex'
        ? '/api/run/flex2flex-overview'
        : (SCANNER_MODE === 'hyperflex' ? '/api/run/hyperflex-overview' : '/api/run/account-overview');
      const data = await apiPost(overviewEndpoint, payload);
      showResult(overviewAction, data);
      setStepStatus('statusOverview', data.ok ? 'success' : 'failed', data.ok ? 'Success' : 'Failed');
      
      if (data.ok) {
        try {
          const tData = await apiPost('/api/tracker/stage1_update', {});
          if (tData.ok) {
            log(`CRM Tracker Updated: ${tData.vms} VMs, ${tData.vols} Vols, ${tData.dbs} DBs.`);
          }
        } catch (te) {
          log(`Warning: Failed to update CRM Tracker - ${te.message}`);
        }
      }
      await refreshFiles();
      await renderSGRules();
    } catch (e) {
      log(`Run error: ${e.message}`);
      setStepStatus('statusOverview', 'failed', 'Failed');
    }
  });
});

const runAdmOptCBtn = document.getElementById('runAdmOptCBtn');
if (runAdmOptCBtn) runAdmOptCBtn.addEventListener('click', async () => {
  clearValidationMarks(['admInventory']);
  const overviewCsv = document.getElementById('admInventory').value.trim();
  if (!overviewCsv) {
    markInvalid('admInventory', true);
    log('Overview CSV is required for App Dependency Mapping.');
    setStepStatus('statusAppDeps', 'failed', 'Failed');
    return;
  }
  setStepStatus('statusAppDeps', 'running', 'Running');
  await withButtonBusy('runAdmOptCBtn', 'generate_app_dependency_map.py (C)', async () => {
    try {
      const data = await apiPost('/api/run/generate-app-dependencies', {
        overview_csv: overviewCsv,
        mode: 'inference'
      });
      showResult('ADM [Option C: Inference]', data);
      setStepStatus('statusAppDeps', data.ok ? 'success' : 'failed', data.ok ? 'Success' : 'Failed');
      await refreshFiles();
    } catch (e) {
      log(`Run error: ${e.message}`);
      setStepStatus('statusAppDeps', 'failed', 'Failed');
    }
  });
});

const runAdmOptABtn = document.getElementById('runAdmOptABtn');
if (runAdmOptABtn) runAdmOptABtn.addEventListener('click', async () => {
  clearValidationMarks(['admInventory']);
  const overviewCsv = document.getElementById('admInventory').value.trim();
  if (!overviewCsv) {
    markInvalid('admInventory', true);
    log('Overview CSV is required for App Dependency Mapping.');
    setStepStatus('statusAppDeps', 'failed', 'Failed');
    return;
  }
  setStepStatus('statusAppDeps', 'running', 'Running');
  await withButtonBusy('runAdmOptABtn', 'generate_app_dependency_map.py (A)', async () => {
    try {
      const data = await apiPost('/api/run/generate-app-dependencies', {
        overview_csv: overviewCsv,
        mode: 'active'
      });
      showResult('ADM [Option A: Active Scan]', data);
      setStepStatus('statusAppDeps', data.ok ? 'success' : 'failed', data.ok ? 'Success' : 'Failed');
      await refreshFiles();
    } catch (e) {
      log(`Run error: ${e.message}`);
      setStepStatus('statusAppDeps', 'failed', 'Failed');
    }
  });
});

const runMapperBtn = document.getElementById('runMapperBtn');
if (runMapperBtn) runMapperBtn.addEventListener('click', async () => {
  clearValidationMarks(['mapTargetRegion', 'mapInventory']);
  syncFlex2FlexTargetRegionControls();
  const targetRegion = (SCANNER_MODE === 'flex2flex'
    ? shortFlexRegionValue(currentFlex2FlexTargetRegion())
    : document.getElementById('mapTargetRegion').value).trim();
  const overviewCsv = document.getElementById('mapInventory').value.trim();
  if (!targetRegion) {
    markInvalid('mapTargetRegion', true);
    log('Deployment Region is required for flavor mapping.');
    setStepStatus('statusMapper', 'failed', 'Failed');
    return;
  }
  if (!overviewCsv) {
    markInvalid('mapInventory', true);
    log('Overview CSV is required for flavor mapping.');
    setStepStatus('statusMapper', 'failed', 'Failed');
    return;
  }
  setStepStatus('statusMapper', 'running', 'Running');
  const mapperAction = SCANNER_MODE === 'flex2flex' ? 'flex2flex_flavor_mapper' : (SCANNER_MODE === 'hyperflex' ? `${SCANNER_PROVIDER}_hyperflex_mapper` : 'flavor_mapper.py');
  await withButtonBusy('runMapperBtn', mapperAction, async () => {
    try {
      const mapperEndpoint = SCANNER_MODE === 'flex2flex'
        ? '/api/run/flex2flex-flavor-mapper'
        : (SCANNER_MODE === 'hyperflex' ? '/api/run/hyperflex-flavor-mapper' : '/api/run/flavor-mapper');
      const data = await apiPost(mapperEndpoint, {
        inventory: overviewCsv,
        include_database_instances_as_servers: document.getElementById('mapIncludeDbAsServers').checked,
        include_floating_ips: document.getElementById('mapIncludeFloatingIps').checked,
        target_region: targetRegion,
        source_region: SCANNER_MODE === 'flex2flex' ? currentFlex2FlexSourceRegion() : '',
        provider: SCANNER_PROVIDER,
      });
      showResult(mapperAction, data);
      setStepStatus('statusMapper', data.ok ? 'success' : 'failed', data.ok ? 'Success' : 'Failed');
      await refreshFiles();
    } catch (e) {
      log(`Run error: ${e.message}`);
      setStepStatus('statusMapper', 'failed', 'Failed');
    }
  });
});

const runValidateBtn = document.getElementById('runValidateBtn');
if (runValidateBtn) runValidateBtn.addEventListener('click', async () => {
  clearValidationMarks(['valFlavorMap', 'valBlockMap']);
  const flavorMap = document.getElementById('valFlavorMap').value.trim();
  const blockMap = document.getElementById('valBlockMap').value.trim();
  if (!flavorMap || !blockMap) {
    markInvalid('valFlavorMap', !flavorMap);
    markInvalid('valBlockMap', !blockMap);
    log('Flavor Map CSV and Block Map CSV are required for validation.');
    setStepStatus('statusValidate', 'failed', 'Failed');
    return;
  }
  setStepStatus('statusValidate', 'running', 'Running');
  await withButtonBusy('runValidateBtn', 'validate_migration_inputs.py', async () => {
    try {
      const data = await apiPost('/api/run/validate', {
        flavor_mapping: flavorMap,
        block_storage_mapping: blockMap,
        lb_mapping: document.getElementById('valLbMap').value,
      });
      showResult('validate_migration_inputs.py', data);
      renderValidationFindings(data);
      setStepStatus('statusValidate', data.ok ? 'success' : 'failed', data.ok ? 'Success' : 'Failed');
      await refreshFiles();
    } catch (e) {
      log(`Run error: ${e.message}`);
      validationFindingsCard.style.display = 'none';
      validationFindingsSource.textContent = '';
      setStepStatus('statusValidate', 'failed', 'Failed');
    }
  });
});

const runDeployGenBtn = document.getElementById('runDeployGenBtn');
if (runDeployGenBtn) runDeployGenBtn.addEventListener('click', async () => {
  clearValidationMarks(['depFlavorMap', 'depPrivateNet', 'depSubnetName', 'depSubnetCidr', 'depRouterName', 'depPublicNet']);
  const depFlavorMap = document.getElementById('depFlavorMap').value.trim();
  const keyName = document.getElementById('depKeyName').value.trim();
  const sshPubKey = document.getElementById('depSshPubKey').value.trim();
  const publicNet = document.getElementById('depPublicNet').value.trim();
  const privateNet = document.getElementById('depPrivateNet').value.trim();
  const subnetName = document.getElementById('depSubnetName').value.trim();
  const subnetCidr = document.getElementById('depSubnetCidr').value.trim();
  const routerName = document.getElementById('depRouterName').value.trim();
  const windowsAdminUser = document.getElementById('depWindowsAdminUser').value.trim() || 'Administrator';
  const windowsPasswordLength = Number(document.getElementById('depWindowsPasswordLength').value || '14');
  const generateWindowsPasswords = document.getElementById('depGenerateWindowsPasswords').checked;
  let hasError = false;
  if (!depFlavorMap) { markInvalid('depFlavorMap', true); hasError = true; }
  if (!publicNet) { markInvalid('depPublicNet', true); hasError = true; }
  if (!privateNet) { markInvalid('depPrivateNet', true); hasError = true; }
  if (!subnetName) { markInvalid('depSubnetName', true); hasError = true; }
  if (!routerName) { markInvalid('depRouterName', true); hasError = true; }
  if (!isValidCidr(subnetCidr)) { markInvalid('depSubnetCidr', true); hasError = true; }
  if (hasError) {
    log('Deploy generation requires flavor map, network names, router name, and a valid subnet CIDR.');
    setStepStatus('statusDeployGen', 'failed', 'Failed');
    return;
  }
  setStepStatus('statusDeployGen', 'running', 'Running');
  await withButtonBusy('runDeployGenBtn', 'generate_project_deploy_script.py', async () => {
    try {
      const data = await apiPost('/api/run/generate-deploy', {
        flavor_mapping: depFlavorMap,
        block_storage_mapping: document.getElementById('depBlockMap').value,
        lb_mapping: document.getElementById('depLbMap').value,
        public_network: publicNet,
        private_network: privateNet,
        subnet_name: subnetName,
        subnet_cidr: subnetCidr,
        router_name: routerName,
        security_group: document.getElementById('depSecGroup').value,
        volume_type: document.getElementById('depVolumeType').value,
        key_name: keyName,
        ssh_pub_key: sshPubKey,
        generate_windows_passwords: generateWindowsPasswords,
        windows_password_length: windowsPasswordLength,
        windows_admin_user: windowsAdminUser,
        source_region: '',
        target_region: '',
        output_prefix: document.getElementById('depOutputPrefix').value,
        fail_fast: document.getElementById('depFailFast').checked,
      });
      showResult('generate_project_deploy_script.py', data);
      renderDeployNextSteps(data);
      setStepStatus('statusDeployGen', data.ok ? 'success' : 'failed', data.ok ? 'Success' : 'Failed');
      await refreshFiles();
    } catch (e) {
      log(`Run error: ${e.message}`);
      renderDeployNextSteps({ ok: false });
      setStepStatus('statusDeployGen', 'failed', 'Failed');
    }
  });
});

const runMigrateGenBtn = document.getElementById('runMigrateGenBtn');
if (runMigrateGenBtn) runMigrateGenBtn.addEventListener('click', async () => {
  clearValidationMarks(['migInventory', 'migFlavorMap', 'migCustomList']);
  
  const strategy = document.getElementById('migStrategy').value.trim() || 'direct';
  const useCustomCsv = document.getElementById('migUseCustomCsv').checked;
  
  let payload = { strategy, use_custom_csv: useCustomCsv };

  if (useCustomCsv) {
    const customList = document.getElementById('migCustomList').value.trim();
    if (!customList) {
      markInvalid('migCustomList', true);
      log('Custom Data Migration CSV is required when bypassing Stage 1.');
      setStepStatus('statusMigrateGen', 'failed', 'Failed');
      return;
    }
    payload.custom_csv = customList;
  } else {
    const inventory = document.getElementById('migInventory').value.trim();
    const flavorMap = document.getElementById('migFlavorMap').value.trim();
    if (!inventory || !flavorMap) {
      markInvalid('migInventory', !inventory);
      markInvalid('migFlavorMap', !flavorMap);
      log('Overview CSV and Flavor Map CSV are required for data migration script generation.');
      setStepStatus('statusMigrateGen', 'failed', 'Failed');
      return;
    }
    payload.inventory = inventory;
    payload.flavor_mapping = flavorMap;
  }

  setStepStatus('statusMigrateGen', 'running', 'Running');
  await withButtonBusy('runMigrateGenBtn', 'generate_data_migration_script.py', async () => {
    try {
      const data = await apiPost('/api/run/generate-data-migration', payload);
      showResult('generate_data_migration_script.py', data);
      setStepStatus('statusMigrateGen', data.ok ? 'success' : 'failed', data.ok ? 'Success' : 'Failed');
      await refreshFiles();
    } catch (e) {
      log(`Run error: ${e.message}`);
      setStepStatus('statusMigrateGen', 'failed', 'Failed');
    }
  });
});

const runExecuteBashBtn = document.getElementById('runExecuteBashBtn');
const stopExecuteBashBtn = document.getElementById('stopExecuteBashBtn');
let _activeJobId = null;

if (stopExecuteBashBtn) stopExecuteBashBtn.addEventListener('click', async () => {
  if (!_activeJobId) return;
  stopExecuteBashBtn.disabled = true;
  stopExecuteBashBtn.textContent = '⏳ Stopping...';
  try {
    await fetch('/api/run/stop-script', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ job_id: _activeJobId }),
    });
    log(`[WARN] Execution stopped by user (job: ${_activeJobId}).`);
    setStepStatus('statusExecuteBash', 'failed', 'Stopped');
  } catch (e) {
    log(`[ERROR] Failed to send stop signal: ${e.message}`);
  } finally {
    _activeJobId = null;
    stopExecuteBashBtn.style.display = 'none';
    stopExecuteBashBtn.disabled = false;
    stopExecuteBashBtn.textContent = '⏹ Stop Execution';
    // Immediately restore the Execute button — don't wait for SSE onerror to bubble through withButtonBusy
    if (runExecuteBashBtn) {
      runExecuteBashBtn.disabled = false;
      runExecuteBashBtn.textContent = 'Execute Migration Script';
    }
  }
});

if (runExecuteBashBtn) runExecuteBashBtn.addEventListener('click', async () => {
  clearValidationMarks(['exeBashScript']);
  const scriptName = document.getElementById('exeBashScript').value.trim();
  if (!scriptName) {
    markInvalid('exeBashScript', true);
    log('A migration shell script must be selected to execute.');
    setStepStatus('statusExecuteBash', 'failed', 'Failed');
    return;
  }
  setStepStatus('statusExecuteBash', 'running', 'Running');
  await withButtonBusy('runExecuteBashBtn', scriptName, async () => {
    log(`${scriptName}: IN PROGRESS - STREAMING...`);

    // Generate a unique job ID for this execution run
    const jobId = crypto.randomUUID ? crypto.randomUUID() : Date.now().toString(36);
    _activeJobId = jobId;
    if (stopExecuteBashBtn) stopExecuteBashBtn.style.display = '';

    const ok = await new Promise((resolve) => {
      const url = `/api/stream/execute-bash?script=${encodeURIComponent(scriptName)}&job_id=${encodeURIComponent(jobId)}`;
      const es = new EventSource(url);
      let finalRc = 1;

      es.onmessage = (e) => {
        if (e.data.startsWith('[DONE]')) {
          es.close();
          const parts = e.data.split('rc=');
          if (parts.length > 1) {
            const rest = parts[1];
            finalRc = parseInt(rest, 10);
            // Extract log filename if provided: "rc=0 log=my_script_execution.log"
            const logMatch = rest.match(/log=([^\s]+)/);
            if (logMatch) {
              const logName = logMatch[1];
              const reportCard = document.getElementById('migrationReportCard');
              const reportLink = document.getElementById('downloadReportLink');
              const reportFilenameSpan = document.getElementById('reportFilename');
              if (reportCard && reportLink) {
                reportLink.href = `/api/run/migration-report?log=${encodeURIComponent(logName)}`;
                if (reportFilenameSpan) {
                  const rptName = logName.replace('_execution.log', '_migration_report.xlsx');
                  reportFilenameSpan.textContent = rptName;
                }
                reportCard.style.display = '';
              }
            }
          }
          resolve(finalRc === 0);
        } else {
          log(e.data);
        }
      };

      es.onerror = () => {
        es.close();
        log(`[ERROR] SSE connection lost or server error.`);
        resolve(false);
      };
    });

    _activeJobId = null;
    if (stopExecuteBashBtn) stopExecuteBashBtn.style.display = 'none';
    log(`[INFO] ${scriptName}: rc=${ok ? 0 : 1} ok=${ok}`);
    setStepStatus('statusExecuteBash', ok ? 'success' : 'failed', ok ? 'Success' : 'Failed');
    await refreshFiles();
  });
});

['admInventory', 'mapTargetRegion', 'mapInventory', 'depFlavorMap', 'depBlockMap', 'depLbMap', 'depPrivateNet', 'depSubnetName', 'depRouterName', 'depKeyName', 'migInventory', 'migFlavorMap', 'exeBashScript'].forEach((id) => {
  const el = document.getElementById(id);
  if (!el) return;
  el.addEventListener('change', updateRunSummary);
  el.addEventListener('input', updateRunSummary);
});

['ovUsername', 'ovApiKey', 'ovAccountId', 'admInventory', 'mapTargetRegion', 'mapInventory', 'valFlavorMap', 'valBlockMap', 'depFlavorMap', 'depKeyName', 'depPrivateNet', 'depSubnetName', 'depSubnetCidr', 'depRouterName', 'depPublicNet', 'migInventory', 'migFlavorMap', 'exeBashScript'].forEach((id) => {
  const el = document.getElementById(id);
  if (!el) return;
  const clear = () => markInvalid(id, false);
  el.addEventListener('input', clear);
  el.addEventListener('change', clear);
});

[['logFilterAll', 'all'], ['logFilterInfo', 'info'], ['logFilterWarn', 'warn'], ['logFilterError', 'error']].forEach(([id, level]) => {
  const btn = document.getElementById(id);
  if (!btn) return;
  btn.addEventListener('click', () => {
    logFilter = level;
    ['logFilterAll', 'logFilterInfo', 'logFilterWarn', 'logFilterError'].forEach((otherId) => {
      const otherBtn = document.getElementById(otherId);
      if (otherBtn) otherBtn.classList.toggle('active', otherId === id);
    });
    renderLog();
  });
});

const clearLogBtn = document.getElementById('clearLogBtn');
if (clearLogBtn) clearLogBtn.addEventListener('click', () => {
  logEntries.length = 0;
  renderLog();
});

const copyLogBtn = document.getElementById('copyLogBtn');
if (copyLogBtn) copyLogBtn.addEventListener('click', async () => {
  const payload = logBox.textContent || '';
  try {
    await navigator.clipboard.writeText(payload);
    log('Activity log copied to clipboard.');
  } catch (_) {
    log('Could not copy log to clipboard in this browser.');
  }
});

const migStrategyElListener = document.getElementById('migStrategy');
if (migStrategyElListener) migStrategyElListener.addEventListener('change', refreshFiles);

// Re-populate all dropdowns when Account ID changes
const _ovAcct = document.getElementById('ovAccountId');
if (_ovAcct) {
  _ovAcct.addEventListener('change', () => refreshFiles());
  _ovAcct.addEventListener('blur', () => refreshFiles());
}

logEntries.length = 0;
refreshFiles().then(() => {
  updateRunSummary();
  renderSGRules();
  log('Loaded files.');
}).catch((e) => log(`Startup error: ${e.message}`));
