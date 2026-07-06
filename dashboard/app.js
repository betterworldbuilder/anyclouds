const els = {
  file: document.getElementById('csvFile'),
  fileMeta: document.getElementById('fileMeta'),
  controls: document.getElementById('controls'),
  search: document.getElementById('search'),
  groupBy: document.getElementById('groupBy'),
  groupValue: document.getElementById('groupValue'),
  toggleColumns: document.getElementById('toggleColumns'),
  exportFiltered: document.getElementById('exportFiltered'),
  toggleEditPrimary: document.getElementById('toggleEditPrimary'),
  exportEditedPrimary: document.getElementById('exportEditedPrimary'),
  saveEditedPrimary: document.getElementById('saveEditedPrimary'),
  columnPickerPanel: document.getElementById('columnPickerPanel'),
  columnPicker: document.getElementById('columnPicker'),
  summary: document.getElementById('summary'),
  ospcDetailTcoPanel: document.getElementById('ospcDetailTcoPanel'),
  aggregateTcoPanel: document.getElementById('aggregateTcoPanel'),
  componentTcoPanel: document.getElementById('componentTcoPanel'),
  sourceChartPanel: document.getElementById('sourceChartPanel'),
  sourceChartCount: document.getElementById('sourceChartCount'),
  sourcePie: document.getElementById('sourcePie'),
  sourceLegend: document.getElementById('sourceLegend'),
  table: document.getElementById('dataTable'),
  tablePanel: document.getElementById('tablePanel'),
  rowCount: document.getElementById('rowCount'),
  mapperFile: document.getElementById('mapperFile'),
  mapperMeta: document.getElementById('mapperMeta'),
  mapperSearch: document.getElementById('mapperSearch'),
  toggleMapperColumns: document.getElementById('toggleMapperColumns'),
  exportMapperFiltered: document.getElementById('exportMapperFiltered'),
  toggleEditMapper: document.getElementById('toggleEditMapper'),
  exportEditedMapper: document.getElementById('exportEditedMapper'),
  saveEditedMapper: document.getElementById('saveEditedMapper'),
  mapperColumnPickerPanel: document.getElementById('mapperColumnPickerPanel'),
  mapperColumnPicker: document.getElementById('mapperColumnPicker'),
  mapperSummary: document.getElementById('mapperSummary'),
  mapperTable: document.getElementById('mapperTable'),
  mapperTablePanel: document.getElementById('mapperTablePanel'),
  mapperRowCount: document.getElementById('mapperRowCount'),
  blockFile: document.getElementById('blockFile'),
  blockMeta: document.getElementById('blockMeta'),
  blockSearch: document.getElementById('blockSearch'),
  lbFile: document.getElementById('lbFile'),
  lbMeta: document.getElementById('lbMeta'),
  lbSearch: document.getElementById('lbSearch'),
  lbSummary: document.getElementById('lbSummary'),
  lbTable: document.getElementById('lbTable'),
  lbTablePanel: document.getElementById('lbTablePanel'),
  lbRowCount: document.getElementById('lbRowCount'),
  toggleEditBlock: document.getElementById('toggleEditBlock'),
  exportEditedBlock: document.getElementById('exportEditedBlock'),
  saveEditedBlock: document.getElementById('saveEditedBlock'),
  blockTable: document.getElementById('blockTable'),
  blockTablePanel: document.getElementById('blockTablePanel'),
  blockRowCount: document.getElementById('blockRowCount'),
  inventoryPanel: document.getElementById('inventoryPanel'),
  inventoryCount: document.getElementById('inventoryCount'),
  sourceFlavorTable: document.getElementById('sourceFlavorTable'),
  targetFlavorTable: document.getElementById('targetFlavorTable'),
  sourceFlavorTotal: document.getElementById('sourceFlavorTotal'),
  targetFlavorTotal: document.getElementById('targetFlavorTotal'),
  sourceRamTotal: document.getElementById('sourceRamTotal'),
  targetRamTotal: document.getElementById('targetRamTotal'),
  sourceVcpuTotal: document.getElementById('sourceVcpuTotal'),
  targetVcpuTotal: document.getElementById('targetVcpuTotal'),
  volumeInventoryTable: document.getElementById('volumeInventoryTable'),
  lbInventoryTable: document.getElementById('lbInventoryTable')
};

const state = {
  headers: [],
  rows: [],
  originalRows: [],
  filtered: [],
  visibleHeaders: [],
  mapperHeaders: [],
  mapperRows: [],
  originalMapperRows: [],
  mapperFiltered: [],
  mapperVisibleHeaders: [],
  blockHeaders: [],
  blockRows: [],
  originalBlockRows: [],
  blockFiltered: [],
  lbHeaders: [],
  lbRows: [],
  lbFiltered: [],
  primarySourceName: '',
  mapperSourceName: '',
  blockSourceName: '',
  lbSourceName: '',
  editModePrimary: false,
  editModeMapper: false,
  editModeBlock: false,
  ospcPriceMap: {},   // server_name -> monthly_cost_usd
  flexPriceMap: {},   // flavor_name -> hourly_rate_usd
  hasOspcPriceList: false,
  hasFlexPriceList: false,
};

// Expose state for the XLSX export button in index.html
window._dashState = state;

const sourceFlavorSpecs = {
  "2": { ram_mb: 512, vcpus: 1 },
  "3": { ram_mb: 1024, vcpus: 1 },
  "4": { ram_mb: 2048, vcpus: 2 },
  "5": { ram_mb: 4096, vcpus: 2 },
  "6": { ram_mb: 8192, vcpus: 4 },
  "7": { ram_mb: 15360, vcpus: 6 },
  "8": { ram_mb: 30720, vcpus: 8 },
  "compute1-15": { ram_mb: 15360, vcpus: 8 },
  "compute1-30": { ram_mb: 30720, vcpus: 16 },
  "compute1-4": { ram_mb: 3840, vcpus: 2 },
  "compute1-60": { ram_mb: 61440, vcpus: 32 },
  "compute1-8": { ram_mb: 7680, vcpus: 4 },
  "general1-1": { ram_mb: 1024, vcpus: 1 },
  "general1-2": { ram_mb: 2048, vcpus: 2 },
  "general1-4": { ram_mb: 4096, vcpus: 4 },
  "general1-8": { ram_mb: 8192, vcpus: 8 },
  "io1-120": { ram_mb: 122880, vcpus: 32 },
  "io1-15": { ram_mb: 15360, vcpus: 4 },
  "io1-30": { ram_mb: 30720, vcpus: 8 },
  "io1-60": { ram_mb: 61440, vcpus: 16 },
  "io1-90": { ram_mb: 92160, vcpus: 24 },
  "memory1-120": { ram_mb: 122880, vcpus: 16 },
  "memory1-15": { ram_mb: 15360, vcpus: 2 },
  "memory1-240": { ram_mb: 245760, vcpus: 32 },
  "memory1-30": { ram_mb: 30720, vcpus: 4 },
  "memory1-60": { ram_mb: 61440, vcpus: 8 },
  "onmetal-general2-large": { ram_mb: 131072, vcpus: 24 },
  "onmetal-general2-medium": { ram_mb: 65536, vcpus: 24 },
  "onmetal-general2-small": { ram_mb: 32768, vcpus: 12 },
  "onmetal-io2": { ram_mb: 131072, vcpus: 40 },
  "performance1-1": { ram_mb: 1024, vcpus: 1 },
  "performance1-2": { ram_mb: 2048, vcpus: 2 },
  "performance1-4": { ram_mb: 4096, vcpus: 4 },
  "performance1-8": { ram_mb: 8192, vcpus: 8 },
  "performance2-120": { ram_mb: 122880, vcpus: 32 },
  "performance2-15": { ram_mb: 15360, vcpus: 4 },
  "performance2-30": { ram_mb: 30720, vcpus: 8 },
  "performance2-60": { ram_mb: 61440, vcpus: 16 },
  "performance2-90": { ram_mb: 92160, vcpus: 24 }
};

const targetFlavorSpecs = {
  "mo.6.2.16": { ram_mb: 16384, vcpus: 2 },
  "gp.5.2.6": { ram_mb: 6144, vcpus: 2 },
  "gp.5.2.8": { ram_mb: 8192, vcpus: 2 },
  "mo.6.4.32": { ram_mb: 32768, vcpus: 4 },
  "mo.6.4.20": { ram_mb: 20480, vcpus: 4 },
  "gp.5.4.4": { ram_mb: 4096, vcpus: 4 },
  "gp.5.32.128": { ram_mb: 131072, vcpus: 32 },
  "gp.5.24.96": { ram_mb: 98304, vcpus: 24 },
  "gp.5.1.2": { ram_mb: 2048, vcpus: 1 },
  "mo.6.4.24": { ram_mb: 24576, vcpus: 4 },
  "gp.5.48.192": { ram_mb: 196608, vcpus: 48 },
  "gp.5.16.64": { ram_mb: 65536, vcpus: 16 },
  "gp.5.4.16": { ram_mb: 16384, vcpus: 4 },
  "gp.5.2.4": { ram_mb: 4096, vcpus: 2 },
  "mo.6.2.12": { ram_mb: 12288, vcpus: 2 },
  "gp.5.4.8": { ram_mb: 8192, vcpus: 4 },
  "gp.5.1.4": { ram_mb: 4096, vcpus: 1 },
  "gp.5.8.16": { ram_mb: 16384, vcpus: 8 },
  "gp.5.2.2": { ram_mb: 2048, vcpus: 2 },
  "gp.5.8.24": { ram_mb: 24576, vcpus: 8 },
  "mo.6.8.64": { ram_mb: 65536, vcpus: 8 },
  "gp.5.4.12": { ram_mb: 12288, vcpus: 4 },
  "gp.5.8.32": { ram_mb: 32768, vcpus: 8 }
};

function bindIf(el, event, handler) {
  if (el) el.addEventListener(event, handler);
}

bindIf(els.file, 'change', e => onFileSelect(e, false));
bindIf(els.file, 'click', () => { els.file.value = ''; });
bindIf(els.search, 'input', applyFilters);
bindIf(els.groupBy, 'change', onGroupByChange);
bindIf(els.groupValue, 'change', applyFilters);
bindIf(els.toggleColumns, 'click', () => togglePanel(els.columnPickerPanel));
bindIf(els.exportFiltered, 'click', exportPrimaryFiltered);
bindIf(els.toggleEditPrimary, 'click', () => toggleEditMode('primary'));
bindIf(els.exportEditedPrimary, 'click', exportPrimaryEdited);
bindIf(els.saveEditedPrimary, 'click', savePrimaryEdited);

bindIf(els.mapperFile, 'change', e => onFileSelect(e, true));
bindIf(els.mapperFile, 'click', () => { els.mapperFile.value = ''; });
bindIf(els.mapperSearch, 'input', applyMapperFilters);
bindIf(els.toggleMapperColumns, 'click', () => togglePanel(els.mapperColumnPickerPanel));
bindIf(els.exportMapperFiltered, 'click', exportMapperFiltered);
bindIf(els.toggleEditMapper, 'click', () => toggleEditMode('mapper'));
bindIf(els.exportEditedMapper, 'click', exportMapperEdited);
bindIf(els.saveEditedMapper, 'click', saveMapperEdited);
// Price list handlers
const ospcPriceFileEl = document.getElementById('ospcPriceFile');
const flexPriceFileEl = document.getElementById('flexPriceFile');
const ospcPriceMeta   = document.getElementById('ospcPriceMeta');
const flexPriceMeta   = document.getElementById('flexPriceMeta');

function parsePriceListCsv(text, nameKeys, costKeys) {
  const parsed = parseCSV(text);
  const map = {};
  for (const row of parsed.rows) {
    const name = (nameKeys.map(k => row[k]).find(v => v) || '').trim().toLowerCase();
    const cost = parseFloat((costKeys.map(k => row[k]).find(v => v) || '').replace(/[^0-9.]/g, ''));
    if (name && !isNaN(cost) && cost > 0) map[name] = cost;
  }
  return map;
}

if (ospcPriceFileEl) {
  ospcPriceFileEl.addEventListener('change', e => {
    const file = e.target.files[0]; if (!file) return;
    const reader = new FileReader();
    reader.onload = ev => {
      state.ospcPriceMap = parsePriceListCsv(ev.target.result,
        ['server_name','name','instance','vm_name'],
        ['monthly_cost_usd','monthly_cost','cost_monthly','cost_per_month','hourly_rate','hourly_cost']
      );
      state.hasOspcPriceList = Object.keys(state.ospcPriceMap).length > 0;
      ospcPriceMeta.textContent = `${file.name} (${Object.keys(state.ospcPriceMap).length} entries)`;
      if (state.mapperRows.length) renderMapperSummary(state.mapperRows);
      renderInventoryTcoPanels();
    };
    reader.readAsText(file);
  });
}

if (flexPriceFileEl) {
  flexPriceFileEl.addEventListener('change', e => {
    const file = e.target.files[0]; if (!file) return;
    const reader = new FileReader();
    reader.onload = ev => {
      state.flexPriceMap = parsePriceListCsv(ev.target.result,
        ['flavor_name','name','flavor','target_flavor','instance_type'],
        ['hourly_rate','cost_per_hour','hourly_cost','hourly_rate_usd','monthly_cost_usd','monthly_cost']
      );
      state.hasFlexPriceList = Object.keys(state.flexPriceMap).length > 0;
      flexPriceMeta.textContent = `${file.name} (${Object.keys(state.flexPriceMap).length} entries)`;
      if (state.mapperRows.length) renderMapperSummary(state.mapperRows);
      renderInventoryTcoPanels();
    };
    reader.readAsText(file);
  });
}

bindIf(els.blockFile, 'change', e => onFileSelect(e, 'block'));
bindIf(els.blockFile, 'click', () => { els.blockFile.value = ''; });
bindIf(els.blockSearch, 'input', applyBlockFilters);
bindIf(els.lbFile, 'change', e => onFileSelect(e, 'lb'));
bindIf(els.lbFile, 'click', () => { els.lbFile.value = ''; });
bindIf(els.lbSearch, 'input', applyLbFilters);
bindIf(els.toggleEditBlock, 'click', () => toggleEditMode('block'));
bindIf(els.exportEditedBlock, 'click', exportBlockEdited);
bindIf(els.saveEditedBlock, 'click', saveBlockEdited);

[els.table, els.mapperTable, els.blockTable, els.lbTable].filter(Boolean).forEach(tableEl => {
  tableEl.addEventListener('focusout', onEditableCellFocusOut);
  tableEl.addEventListener('keydown', onEditableCellKeyDown);
});

function togglePanel(panel) {
  panel.classList.toggle('hidden');
}

function onFileSelect(e, mode) {
  const [file] = e.target.files;
  if (!file) return;

  const isMapper = mode === true;
  const isBlock = mode === 'block';
  const isLb = mode === 'lb';
  const meta = isMapper ? els.mapperMeta : (isBlock ? els.blockMeta : (isLb ? els.lbMeta : els.fileMeta));
  meta.textContent = `Loading ${file.name}...`;

  const reader = new FileReader();
  reader.onload = () => {
    try {
      const parsed = parseCSV(String(reader.result || ''));
      if (!parsed.headers.length) throw new Error('No columns found in CSV.');

      if (isMapper) {
        state.mapperSourceName = file.name;
        state.mapperHeaders = parsed.headers;
        state.mapperRows = parsed.rows;
        state.originalMapperRows = parsed.rows.map(r => ({ ...r }));
        state.mapperFiltered = parsed.rows;
        state.mapperVisibleHeaders = [...parsed.headers];
        meta.textContent = `${file.name} loaded (${parsed.rows.length.toLocaleString()} rows)`;

        renderColumnPicker(true);
        renderMapperSummary(parsed.rows);
        renderMapperTable(parsed.rows);
        renderFlavorInventory(parsed.rows);
        renderInventoryTcoPanels();

        els.mapperSummary.classList.remove('hidden');
        els.mapperTablePanel.classList.remove('hidden');
        els.inventoryPanel.classList.remove('hidden');
      } else if (isBlock) {
        state.blockSourceName = file.name;
        state.blockHeaders = parsed.headers;
        state.blockRows = parsed.rows;
        state.originalBlockRows = parsed.rows.map(r => ({ ...r }));
        state.blockFiltered = parsed.rows;
        meta.textContent = `${file.name} loaded (${parsed.rows.length.toLocaleString()} rows)`;

        renderBlockTable(parsed.rows);
        els.blockTablePanel.classList.remove('hidden');
        if (state.mapperRows.length) {
          renderFlavorInventory(state.mapperFiltered);
        }
        renderInventoryTcoPanels();
      } else if (isLb) {
        state.lbSourceName = file.name;
        state.lbHeaders = parsed.headers;
        state.lbRows = parsed.rows;
        state.lbFiltered = parsed.rows;
        meta.textContent = `${file.name} loaded (${parsed.rows.length.toLocaleString()} rows)`;

        renderLbSummary(parsed.rows);
        renderLbTable(parsed.rows);
        renderLoadBalancerInventorySummary(parsed.rows);
        renderInventoryTcoPanels();
        els.lbSummary.classList.remove('hidden');
        els.lbTablePanel.classList.remove('hidden');
      } else {
        state.primarySourceName = file.name;
        state.headers = parsed.headers;
        state.rows = parsed.rows;
        state.originalRows = parsed.rows.map(r => ({ ...r }));
        state.filtered = parsed.rows;
        state.visibleHeaders = [...parsed.headers];
        meta.textContent = `${file.name} loaded (${parsed.rows.length.toLocaleString()} rows)`;

        initControls();
        renderColumnPicker(false);
        applyFilters();
        if (state.mapperRows.length) {
          renderFlavorInventory(state.mapperFiltered);
        }
        renderInventoryTcoPanels();
      }
    } catch (err) {
      meta.textContent = `Could not parse file: ${err.message}`;
      if (isMapper) {
        els.mapperSummary.classList.add('hidden');
        els.mapperTablePanel.classList.add('hidden');
        els.inventoryPanel.classList.add('hidden');
      } else if (isBlock) {
        els.blockTablePanel.classList.add('hidden');
      } else if (isLb) {
        els.lbSummary.classList.add('hidden');
        els.lbTablePanel.classList.add('hidden');
      } else {
        els.controls.classList.add('hidden');
        els.summary.classList.add('hidden');
        els.sourceChartPanel.classList.add('hidden');
        els.tablePanel.classList.add('hidden');
      }
    }
  };
  reader.readAsText(file);
}

function parseCSV(raw) {
  const rows = [];
  const out = [];
  let cur = '';
  let inQuotes = false;

  for (let i = 0; i < raw.length; i += 1) {
    const ch = raw[i];
    const next = raw[i + 1];

    if (ch === '"') {
      if (inQuotes && next === '"') {
        cur += '"';
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }

    if (!inQuotes && (ch === '\n' || ch === '\r')) {
      if (ch === '\r' && next === '\n') i += 1;
      out.push(cur);
      cur = '';
      rows.push(out.splice(0));
      continue;
    }

    if (!inQuotes && ch === ',') {
      out.push(cur);
      cur = '';
      continue;
    }

    cur += ch;
  }

  if (cur.length > 0 || out.length > 0) {
    out.push(cur);
    rows.push(out.splice(0));
  }

  const cleaned = rows.filter(r => r.some(v => v !== ''));
  if (!cleaned.length) return { headers: [], rows: [] };

  const headers = cleaned[0].map(h => h.trim());
  const data = cleaned.slice(1).map(r => {
    const obj = {};
    headers.forEach((h, idx) => {
      obj[h] = (r[idx] || '').trim();
    });
    return obj;
  });

  return { headers, rows: data };
}

function initControls() {
  const groupCandidates = ['service_type', 'region', 'source_flavor_id', 'target_flavor_name'];
  const options = ['(none)', ...groupCandidates.filter(c => state.headers.includes(c))];
  els.groupBy.innerHTML = options.map(v => `<option value="${v}">${v}</option>`).join('');
  els.groupValue.innerHTML = '<option value="(all)">(all)</option>';
  els.controls.classList.remove('hidden');
  els.summary.classList.remove('hidden');
  els.tablePanel.classList.remove('hidden');
}

function renderColumnPicker(isMapper) {
  const headers = isMapper ? state.mapperHeaders : state.headers;
  const visible = isMapper ? state.mapperVisibleHeaders : state.visibleHeaders;
  const mount = isMapper ? els.mapperColumnPicker : els.columnPicker;

  mount.innerHTML = headers.map(h => {
    const checked = visible.includes(h) ? 'checked' : '';
    const id = `${isMapper ? 'm' : 'p'}_${slug(h)}`;
    return `<label class="column-item" for="${id}"><input id="${id}" type="checkbox" data-col="${escapeHtml(h)}" ${checked} />${escapeHtml(h)}</label>`;
  }).join('');

  mount.querySelectorAll('input[type="checkbox"]').forEach(input => {
    input.addEventListener('change', () => {
      const col = input.getAttribute('data-col') || '';
      if (isMapper) {
        state.mapperVisibleHeaders = updateVisibleSet(state.mapperVisibleHeaders, headers, col, input.checked);
        renderMapperTable(state.mapperFiltered);
      } else {
        state.visibleHeaders = updateVisibleSet(state.visibleHeaders, headers, col, input.checked);
        renderTable(state.filtered, state.visibleHeaders, els.table, els.rowCount);
      }
    });
  });
}

function updateVisibleSet(currentVisible, allHeaders, column, checked) {
  let next = [...currentVisible];
  if (checked) {
    if (!next.includes(column)) next.push(column);
  } else {
    next = next.filter(h => h !== column);
  }
  if (next.length === 0 && allHeaders.length > 0) return [allHeaders[0]];
  return allHeaders.filter(h => next.includes(h));
}

function onGroupByChange() {
  const key = els.groupBy.value;
  if (key === '(none)') {
    els.groupValue.innerHTML = '<option value="(all)">(all)</option>';
    applyFilters();
    return;
  }
  const uniq = [...new Set(state.rows.map(r => r[key] || '').filter(Boolean))].sort((a, b) => a.localeCompare(b));
  els.groupValue.innerHTML = ['<option value="(all)">(all)</option>', ...uniq.map(v => `<option value="${escapeHtml(v)}">${escapeHtml(v)}</option>`)].join('');
  applyFilters();
}

function applyFilters() {
  const q = (els.search.value || '').toLowerCase();
  const key = els.groupBy.value;
  const groupVal = els.groupValue.value;

  let rows = state.rows;
  if (key && key !== '(none)' && groupVal && groupVal !== '(all)') {
    rows = rows.filter(r => (r[key] || '') === groupVal);
  }
  if (q) {
    rows = rows.filter(r => state.visibleHeaders.some(h => String(r[h] || '').toLowerCase().includes(q)));
  }

  state.filtered = rows;
  renderSummary(rows, state.headers, els.summary);
  renderSourceInventoryChart(rows, state.headers);
  renderTable(rows, state.visibleHeaders, els.table, els.rowCount);
  if (state.mapperRows.length) {
    renderFlavorInventory(state.mapperFiltered);
  }
  renderInventoryTcoPanels();
}

function applyMapperFilters() {
  const q = (els.mapperSearch.value || '').toLowerCase();
  let rows = state.mapperRows;
  if (q) {
    rows = rows.filter(r => state.mapperVisibleHeaders.some(h => String(r[h] || '').toLowerCase().includes(q)));
  }
  state.mapperFiltered = rows;
  renderMapperSummary(rows);
  renderMapperTable(rows);
  renderFlavorInventory(rows);
  renderInventoryTcoPanels();
}

function applyBlockFilters() {
  const q = (els.blockSearch.value || '').toLowerCase();
  let rows = state.blockRows;
  if (q) {
    rows = rows.filter(r => state.blockHeaders.some(h => String(r[h] || '').toLowerCase().includes(q)));
  }
  state.blockFiltered = rows;
  renderBlockTable(rows);
  if (state.mapperRows.length) {
    renderFlavorInventory(state.mapperFiltered);
  }
  renderInventoryTcoPanels();
}

function applyLbFilters() {
  const q = (els.lbSearch.value || '').toLowerCase();
  let rows = state.lbRows;
  if (q) {
    rows = rows.filter(r => state.lbHeaders.some(h => String(r[h] || '').toLowerCase().includes(q)));
  }
  state.lbFiltered = rows;
  renderLbSummary(rows);
  renderLbTable(rows);
  renderLoadBalancerInventorySummary(rows);
  renderInventoryTcoPanels();
}

function renderMapperSummary(rows) {
  renderSummary(rows, state.mapperHeaders, els.mapperSummary);
}

function renderLbSummary(rows) {
  if (!rows.length) {
    els.lbSummary.innerHTML = [card('LB Rows', '0')].join('');
    return;
  }

  const lbNameKey = state.lbHeaders.includes('load_balancer_name') ? 'load_balancer_name' : '';
  const protocolKey = state.lbHeaders.includes('target_protocol') ? 'target_protocol' : '';
  const includeMemberKey = state.lbHeaders.includes('member_include_in_deploy') ? 'member_include_in_deploy' : '';
  const memberIpKey = state.lbHeaders.includes('source_member_ip') ? 'source_member_ip' : '';
  const matchNoteKey = state.lbHeaders.includes('member_match_note') ? 'member_match_note' : '';

  const lbCount = lbNameKey ? Object.keys(countBy(rows, lbNameKey)).filter(k => k !== '(blank)').length : 0;
  const protocolCounts = protocolKey ? countBy(rows, protocolKey) : {};
  const nodeCount = memberIpKey ? rows.filter(r => String(r[memberIpKey] || '').trim() !== '').length : 0;
  const mappedNodes = rows.filter(r => {
    const note = String(r[matchNoteKey] || '').toLowerCase();
    return note.includes('matched');
  }).length;
  const includeMembers = rows.filter(r => isTruthy(String(r[includeMemberKey] || ''))).length;
  const topProtocol = topEntry(protocolCounts);

  const cards = [
    card('LB Rows', rows.length.toLocaleString()),
    card('LBs To Create', lbCount.toLocaleString()),
    card('Node Rows', nodeCount.toLocaleString()),
    card('Included Nodes', includeMembers.toLocaleString()),
    card('Matched Nodes', mappedNodes.toLocaleString())
  ];
  if (topProtocol) {
    cards.push(card('Top Protocol', `${topProtocol.key} (${topProtocol.value})`));
  }
  els.lbSummary.innerHTML = cards.join('');
}

function renderSourceInventoryChart(rows, headers) {
  if (!headers.includes('service_type')) {
    els.sourceChartPanel.classList.add('hidden');
    return;
  }

  const entries = Object.entries(countBy(rows, 'service_type'))
    .filter(([k]) => k && k !== '(blank)')
    .sort((a, b) => b[1] - a[1]);
  const total = entries.reduce((sum, [, c]) => sum + c, 0);
  if (!total) {
    els.sourceChartPanel.classList.add('hidden');
    return;
  }

  const palette = ['#1b9e77', '#d95f02', '#7570b3', '#e7298a', '#66a61e', '#e6ab02', '#a6761d', '#1f78b4', '#b15928', '#6a3d9a'];
  let startDeg = 0;
  const gradientParts = [];
  const legendRows = [];

  entries.forEach(([name, count], idx) => {
    const pct = (count / total) * 100;
    const span = (pct / 100) * 360;
    const endDeg = startDeg + span;
    const color = palette[idx % palette.length];
    gradientParts.push(`${color} ${startDeg.toFixed(2)}deg ${endDeg.toFixed(2)}deg`);
    legendRows.push(`<div class="legend-row"><span class="legend-swatch" style="background:${color}"></span><span>${escapeHtml(name)}</span><span class="legend-count">${count.toLocaleString()} (${pct.toFixed(1)}%)</span></div>`);
    startDeg = endDeg;
  });

  els.sourcePie.style.background = `conic-gradient(${gradientParts.join(',')})`;
  els.sourceLegend.innerHTML = legendRows.join('');
  els.sourceChartCount.textContent = `${total.toLocaleString()} resources`;
  els.sourceChartPanel.classList.remove('hidden');
}

function renderSummary(rows, headers, summaryEl) {
  const cards = [card('Rows', rows.length.toLocaleString())];

  if (headers.includes('service_type')) {
    const counts = countBy(rows, 'service_type');
    cards.push(card('Service Types', Object.keys(counts).length));
    const top = topEntry(counts);
    if (top) cards.push(card('Top Service', `${top.key} (${top.value})`));
  }

  if (headers.includes('region')) {
    cards.push(card('Regions', Object.keys(countBy(rows, 'region')).length));
  }

  // ── Compute & Storage resource totals (overview CSV) ─────────────────────
  const _snapCompute = { servers: 0, active: 0, pct: 0, vcpus: 0, ramGb: 0 };
  const _snapStorage = { totalGb: 0, vols: 0, inUse: 0, pct: 0 };

  if (headers.includes('service_type') && headers.includes('flavor_id')) {
    const serverRows  = rows.filter(r => r.service_type === 'cloud_server');
    const activeServers = serverRows.filter(r => (r.status || '').toUpperCase() === 'ACTIVE');
    let totalVcpus = 0, totalRamGb = 0;
    serverRows.forEach(r => {
      const f = sourceFlavorSpecs[(r.flavor_id || '').trim().toLowerCase()];
      if (f) { totalVcpus += f.vcpus; totalRamGb += f.ram_mb / 1024; }
    });
    if (serverRows.length > 0) {
      const computePct = Math.round((activeServers.length / serverRows.length) * 100);
      cards.push(card('Compute Servers', serverRows.length.toLocaleString()));
      cards.push(card('Active Utilization', computePct + '% (' + activeServers.length + ' active)'));
      if (totalVcpus > 0)  cards.push(card('Total vCPUs', totalVcpus.toLocaleString()));
      if (totalRamGb > 0)  cards.push(card('Total RAM', totalRamGb >= 1024 ? (totalRamGb / 1024).toFixed(1) + ' TB' : Math.round(totalRamGb) + ' GB'));
      _snapCompute.servers = serverRows.length;
      _snapCompute.active  = activeServers.length;
      _snapCompute.pct     = computePct;
      _snapCompute.vcpus   = totalVcpus;
      _snapCompute.ramGb   = totalRamGb;
    }
  }

  if (headers.includes('size_gb')) {
    const volRows    = rows.filter(r => r.service_type === 'block_storage_volume' && parseFloat(r.size_gb) > 0);
    const inUseVols  = volRows.filter(r => (r.status || '').toLowerCase() === 'in-use');
    const totalGb    = volRows.reduce((s, r) => s + (parseFloat(r.size_gb) || 0), 0);
    if (volRows.length > 0) {
      const storagePct = Math.round((inUseVols.length / volRows.length) * 100);
      const sizeLabel  = totalGb >= 1024 ? (totalGb / 1024).toFixed(1) + ' TB' : Math.round(totalGb) + ' GB';
      cards.push(card('Total Storage', sizeLabel + ' (' + volRows.length + ' vols)'));
      cards.push(card('Storage Utilization', storagePct + '% in-use'));
      _snapStorage.totalGb = totalGb;
      _snapStorage.vols    = volRows.length;
      _snapStorage.inUse   = inUseVols.length;
      _snapStorage.pct     = storagePct;
    }
  }

  // Persist stats so Performance Gain panel in parent can read them
  try {
    sessionStorage.setItem('discovery_infra_snapshot', JSON.stringify({
      compute: _snapCompute, storage: _snapStorage, ts: Date.now()
    }));
  } catch(e) {}
  // ─────────────────────────────────────────────────────────────────────────

  if (headers.includes('target_flavor_name')) {
    cards.push(card('Mapped Targets', rows.filter(r => r.target_flavor_name).length.toLocaleString()));
  }

  if (headers.includes('source_flavor_id')) {
    cards.push(card('Source Flavors', rows.filter(r => r.source_flavor_id).length.toLocaleString()));
  }

  // Show price list upload panel whenever flavormap is loaded
  const pricePanel = document.getElementById('pricelist-upload-panel');
  if (pricePanel) { pricePanel.style.display = 'flex'; pricePanel.classList.remove('hidden'); }

  // Update 2.45x note visibility based on whether OSPC price list is loaded
  const assumptionNote = document.getElementById('tco-assumption-note');
  if (assumptionNote) assumptionNote.style.display = state.hasOspcPriceList ? 'none' : 'flex';

  summaryEl.innerHTML = cards.join('');
  if (summaryEl === els.summary) renderInventoryTcoPanels();
}

const regionalTcoMatrix = {
  IAD: [
    ['general1-1', 'gp.0.2.2', 68.80, 28.08],
    ['general1-2', 'gp.0.2.2', 77.62, 28.08],
    ['compute1-4', 'gp.0.2.4', 86.44, 35.28],
    ['general1-4', 'gp.0.4.4', 151.70, 61.92],
    ['compute1-8', 'gp.0.4.8', 186.98, 76.32],
    ['compute1-30', 'gp.0.16.64', 200.00, 398.16]
  ],
  DFW: [
    ['general1-1', 'gp.5.2.2', 68.80, 28.08],
    ['general1-2', 'gp.5.2.2', 77.62, 28.08],
    ['compute1-4', 'gp.5.2.4', 86.44, 35.28],
    ['general1-4', 'gp.5.4.4', 151.70, 61.92],
    ['compute1-8', 'gp.5.4.8', 186.98, 76.32],
    ['compute1-30', 'gp.5.16.64', 200.00, 398.16]
  ],
  SJC: [
    ['general1-1', 'gp.0.2.2', 68.80, 28.08],
    ['general1-2', 'gp.0.2.2', 77.62, 28.08],
    ['compute1-4', 'gp.0.2.4', 86.44, 35.28],
    ['general1-4', 'gp.0.4.4', 151.70, 61.92],
    ['compute1-8', 'gp.0.4.8', 186.98, 76.32],
    ['compute1-30', 'gp.0.16.64', 200.00, 398.16]
  ]
};

function renderInventoryTcoPanels() {
  if (!els.ospcDetailTcoPanel || !els.aggregateTcoPanel || !els.componentTcoPanel) return;
  const rows = buildTcoRows();
  if (!rows.length) {
    [els.ospcDetailTcoPanel, els.aggregateTcoPanel, els.componentTcoPanel].forEach(el => el.classList.add('hidden'));
    return;
  }
  renderOspcDetailTco(rows);
  renderOspcPerComponent(rows);
  renderAggregateTco(rows);
  renderComponentTco(rows);
}

function buildTcoRows() {
  const out = [];
  const seen = new Set();
  const sourceRows = state.mapperRows.length ? state.mapperRows : state.filtered;

  for (const row of sourceRows) {
    const resourceType = field(row, ['source_resource_type', 'service_type', 'resource_type']);
    if (resourceType && !/cloud_server|server|instance/i.test(resourceType)) continue;
    const name = field(row, ['server_name', 'source_server_name', 'target_server_name', 'name', 'instance_name']) || 'Unnamed VM';
    const id = field(row, ['server_id', 'source_server_id', 'id', 'instance_id']);
    const key = `vm:${id || name}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const sourceFlavor = field(row, ['source_flavor_id', 'flavor_id', 'source_flavor_name', 'flavor_name']);
    const targetRegion = normalizeRegion(field(row, ['target_region', 'region']));
    const matrix = lookupRegionalFlavor(sourceFlavor, targetRegion);
    const flexCsvMonthly = moneyNumber(field(row, ['target_monthly_cost_min_usd', 'target_monthly_cost', 'flex_monthly_cost_usd']));
    const ospcCsvMonthly = moneyNumber(field(row, ['source_monthly_cost_usd', 'source_monthly_cost', 'TCO_OSPC_Monthly', 'TCO_OSPC_Estimate']));
    const flexMonthly = moneyNumber(state.flexPriceMap[String(field(row, ['target_flavor_name', 'target_flavor_id']) || '').toLowerCase()]) || flexCsvMonthly || matrix?.flexMonthly || 0;
    const ospcMonthly = ospcCsvMonthly || lookupOspcPriceByName(row) || matrix?.ospcMonthly || (flexMonthly ? flexMonthly * 2.45 : 0);
    const targetFlavor = matrix?.flexFlavor || field(row, ['target_flavor_name', 'target_flavor_id', 'flex_flavor']) || 'FLEX equivalent';
    out.push(tcoRow({
      type: classifyComponent(row, name),
      name,
      id,
      sourceFlavor: sourceFlavor || 'unknown',
      targetFlavor,
      ospcMonthly,
      flexMonthly,
      basis: matrix ? `${targetRegion} price matrix` : (ospcCsvMonthly || flexCsvMonthly ? 'CSV cost fields' : 'estimated from FLEX baseline')
    }));
  }

  const volumeRows = state.blockRows.length
    ? state.blockRows
    : (state.rows || []).filter(r => String(r.service_type || '').trim() === 'block_storage_volume');
  for (const row of volumeRows) {
    const id = field(row, ['volume_id', 'id', 'source_volume_id']);
    const name = field(row, ['volume_name', 'name', 'display_name']) || id || 'Block volume';
    const key = `vol:${id || name}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const sizeGb = moneyNumber(field(row, ['volume_size_gb', 'size_gb', 'boot_from_volume_size_gb'])) || 0;
    const ospcMonthly = moneyNumber(field(row, ['source_monthly_cost_usd', 'source_monthly_cost'])) || sizeGb * 0.10;
    const flexMonthly = moneyNumber(field(row, ['target_monthly_cost_usd', 'target_monthly_cost'])) || sizeGb * 0.06;
    out.push(tcoRow({
      type: 'Block Volume',
      name,
      id,
      sourceFlavor: `${formatNumber(sizeGb)} GB OSPC Cinder`,
      targetFlavor: `${formatNumber(sizeGb)} GB FLEX Cinder`,
      ospcMonthly,
      flexMonthly,
      basis: sizeGb ? 'storage estimate by scanned GB' : 'storage estimate'
    }));
  }

  const lbSeen = new Set();
  for (const row of state.lbRows || []) {
    const id = field(row, ['load_balancer_id', 'lb_id']);
    const name = field(row, ['load_balancer_name', 'name']) || id || 'Load balancer';
    const key = id || name;
    if (lbSeen.has(key)) continue;
    lbSeen.add(key);
    out.push(tcoRow({
      type: 'Load Balancer',
      name,
      id,
      sourceFlavor: 'OSPC LB',
      targetFlavor: 'FLEX Octavia LB',
      ospcMonthly: 25,
      flexMonthly: 20,
      basis: 'LB monthly estimate'
    }));
  }

  return out.filter(r => r.ospcMonthly > 0 || r.flexMonthly > 0);
}

function tcoRow(row) {
  const savings = row.ospcMonthly - row.flexMonthly;
  return {
    ...row,
    savings,
    oneYear: savings * 12,
    threeYear: savings * 36,
    fiveYear: savings * 60
  };
}

function renderOspcDetailTco(rows) {
  const totals = sumTco(rows);
  const byType = groupTco(rows, 'type');
  els.ospcDetailTcoPanel.innerHTML = `
    <div class="tco-title-row">
      <div>
        <p class="tco-kicker">TCO SAVING WITH FLEX</p>
        <h2>Current OSPC infrastructure monthly baseline</h2>
        <p class="meta">Calculated from scanned servers, DB-like instances, volumes, and load balancers. VM prices use the same regional OSPC/FLEX matrix from the Why/Who/What page.</p>
      </div>
      <span class="tco-badge">${rows.length.toLocaleString()} priced components</span>
    </div>
    <div class="tco-kpi-grid">
      ${tcoKpi('OSPC / Day', money(totals.ospcMonthly / 30), 'danger')}
      ${tcoKpi('OSPC / Month', money(totals.ospcMonthly), 'danger')}
      ${tcoKpi('OSPC / Year', money(totals.ospcMonthly * 12), 'danger')}
      ${tcoKpi('Compute + DB', money(sumByTypes(rows, ['VM / Compute', 'DB Instance'])), 'blue')}
      ${tcoKpi('Storage', money(sumByTypes(rows, ['Block Volume'])), 'green')}
      ${tcoKpi('Network / LB', money(sumByTypes(rows, ['Load Balancer'])), 'orange')}
    </div>
    <div class="tco-table-wrap">
      <table class="tco-table">
        <thead><tr><th>Scanned Component Type</th><th>Count</th><th>OSPC / Month</th><th>OSPC / Day</th><th>Annualized OSPC Cost</th></tr></thead>
        <tbody>${byType.map(r => `<tr><td>${escapeHtml(r.type)}</td><td>${r.count}</td><td class="cost-danger">${money(r.ospcMonthly)}</td><td>${money(r.ospcMonthly / 30)}</td><td>${money(r.ospcMonthly * 12)}</td></tr>`).join('')}</tbody>
      </table>
    </div>
  `;
  els.ospcDetailTcoPanel.classList.remove('hidden');
}

function renderAggregateTco(rows) {
  const totals = sumTco(rows);
  const reduction = totals.ospcMonthly ? Math.round((totals.savings / totals.ospcMonthly) * 100) : 0;
  els.aggregateTcoPanel.innerHTML = `
    <div class="tco-comparison-shell">
      <div class="tco-comparison-head">
        <h2>TCO Comparison & Projected Savings</h2>
        <span class="tco-green-pill">↓ ${reduction}% Cost Reduction</span>
      </div>
      <div class="tco-table-wrap flush">
        <table class="tco-table tco-comparison-table">
          <thead><tr><th>Environment</th><th>Min Est. Daily Cost</th><th>Min Est. Monthly Cost</th><th>Annualized Cost</th></tr></thead>
          <tbody>
            <tr><td><span class="env-dot red"></span>Legacy OSPC current scanned infra</td><td>${money(totals.ospcMonthly / 30)}</td><td class="cost-danger">${money(totals.ospcMonthly)}</td><td>${money(totals.ospcMonthly * 12)}</td></tr>
            <tr><td><span class="env-dot green"></span>Target FLEX equivalent</td><td>${money(totals.flexMonthly / 30)}</td><td class="cost-good">${money(totals.flexMonthly)}</td><td>${money(totals.flexMonthly * 12)}</td></tr>
          </tbody>
          <tfoot><tr><td>Projected Platform Savings</td><td>${money(totals.savings)}/mo</td><td colspan="2">${money(totals.savings * 12)}/yr</td></tr></tfoot>
        </table>
      </div>
    </div>
  `;
  els.aggregateTcoPanel.classList.remove('hidden');
}

function renderOspcPerComponent(rows) {
  const el = document.getElementById('ospcPerCompPanel'); if(!el) return;
  const typeColors = {'VM / Compute':'#3b82f6','DB Instance':'#7c3aed','Block Volume':'#0891b2','Load Balancer':'#d97706'};
  let totalMo = 0;
  const rowsHtml = rows.map(r => {
    const mo = r.ospcMonthly || 0; totalMo += mo;
    const tc = typeColors[r.type] || '#3b82f6';
    return `<tr><td style="font-weight:600;color:#1e293b;">${escapeHtml(r.name||r.type)}</td><td><span style="background:${tc}22;color:${tc};padding:2px 8px;border-radius:4px;font-size:10px;font-weight:700;">${escapeHtml(r.type)}</span></td><td style="font-family:monospace;font-size:11px;color:#64748b;">${r.sourceFlavor&&r.sourceFlavor!=='-'?escapeHtml(r.sourceFlavor):'—'}</td><td style="color:#64748b;">${r.region||'IAD'}</td><td style="text-align:right;font-weight:700;color:#dc2626;">${money(mo)}</td><td style="text-align:right;color:#64748b;">$${(mo/30).toFixed(2)}</td><td style="text-align:right;color:#374151;">${money(mo*12)}</td><td style="text-align:right;color:#374151;">${money(mo*36)}</td></tr>`;
  }).join('');
  el.innerHTML = `<div class="tco-title-row"><div><p class="tco-kicker">DETAILED OSPC TCO — PER SCANNED COMPONENT</p><h2>Full OSPC cost breakdown for each scanned component</h2><p class="meta">Each VM, DB instance, block volume, and load balancer with individual monthly and annualized OSPC cost.</p></div><button onclick="(function(){var rows=Array.from(document.querySelectorAll('#ospcPerCompPanel tbody tr'));var csv='Component,Type,Flavor/Size,Region,OSPC/Month,OSPC/Day,1-Year OSPC,3-Year OSPC\\n'+rows.map(function(r){return Array.from(r.querySelectorAll('td')).map(function(c){return '\"'+c.textContent.trim().replace(/\"/g,'\"\"')+'\"';}).join(',');}).join('\\n');var a=document.createElement('a');a.href='data:text/csv;charset=utf-8,'+encodeURIComponent(csv);a.download='OSPC_Component_TCO.csv';a.click();})()" class="btn" style="background:#b23a3a;color:#fff;font-weight:700;white-space:nowrap;">&#11015; Export CSV</button></div><div class="tco-table-wrap"><table class="tco-table"><thead><tr><th>Component</th><th>Type</th><th>Flavor / Size</th><th>Region</th><th style="text-align:right;">OSPC / Month</th><th style="text-align:right;">OSPC / Day</th><th style="text-align:right;">1-Year OSPC</th><th style="text-align:right;">3-Year OSPC</th></tr></thead><tbody>${rowsHtml}</tbody><tfoot><tr style="font-weight:800;background:#f8fafc;"><td colspan="4" style="font-weight:800;color:#1e293b;">TOTAL</td><td style="text-align:right;font-weight:900;color:#dc2626;">${money(totalMo)}</td><td style="text-align:right;color:#dc2626;">$${(totalMo/30).toFixed(2)}</td><td style="text-align:right;font-weight:900;color:#1e293b;">${money(totalMo*12)}</td><td style="text-align:right;font-weight:900;color:#1e293b;">${money(totalMo*36)}</td></tr></tfoot></table></div>`;
  el.classList.remove('hidden');
}

function renderComponentTco(rows) {
  els.componentTcoPanel.innerHTML = `
    <div class="tco-title-row">
      <div>
        <p class="tco-kicker">COMPONENT-LEVEL OSPC → FLEX TCO</p>
        <h2>Detailed OSPC versus FLEX comparison for each scanned component</h2>
      </div>
    </div>
    <div class="tco-table-wrap component-scroll">
      <table class="tco-table tco-component-table">
        <thead>
          <tr><th>Component</th><th>Source Name</th><th>Source ID</th><th>OSPC Flavor / Size</th><th>FLEX Equivalent</th><th>OSPC / Month</th><th>FLEX / Month</th><th>Monthly Saving</th><th>1-Year Saving</th><th>3-Year Saving</th><th>5-Year Saving</th><th>Basis</th></tr>
        </thead>
        <tbody>${rows.map(r => {
          const cls = r.savings >= 0 ? 'cost-good' : 'cost-danger';
          return `<tr>
            <td>${escapeHtml(r.type)}</td>
            <td>${escapeHtml(r.name)}</td>
            <td>${escapeHtml(r.id || '-')}</td>
            <td>${escapeHtml(r.sourceFlavor)}</td>
            <td>${escapeHtml(r.targetFlavor)}</td>
            <td class="cost-danger">${money(r.ospcMonthly)}</td>
            <td class="cost-good">${money(r.flexMonthly)}</td>
            <td class="${cls}">${money(r.savings)}</td>
            <td class="${cls}">${money(r.oneYear)}</td>
            <td class="${cls}">${money(r.threeYear)}</td>
            <td class="${cls}">${money(r.fiveYear)}</td>
            <td>${escapeHtml(r.basis)}</td>
          </tr>`;
        }).join('')}</tbody>
      </table>
    </div>
  `;
  els.componentTcoPanel.classList.remove('hidden');
}

function tcoKpi(label, value, tone) {
  return `<div class="tco-kpi ${tone || ''}"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`;
}

function groupTco(rows, key) {
  const map = {};
  rows.forEach(r => {
    const k = r[key] || 'Other';
    if (!map[k]) map[k] = { type: k, count: 0, ospcMonthly: 0, flexMonthly: 0, savings: 0 };
    map[k].count += 1;
    map[k].ospcMonthly += r.ospcMonthly;
    map[k].flexMonthly += r.flexMonthly;
    map[k].savings += r.savings;
  });
  return Object.values(map).sort((a, b) => b.ospcMonthly - a.ospcMonthly);
}

function sumTco(rows) {
  return rows.reduce((acc, r) => {
    acc.ospcMonthly += r.ospcMonthly;
    acc.flexMonthly += r.flexMonthly;
    acc.savings += r.savings;
    return acc;
  }, { ospcMonthly: 0, flexMonthly: 0, savings: 0 });
}

function sumByTypes(rows, types) {
  return rows.filter(r => types.includes(r.type)).reduce((sum, r) => sum + r.ospcMonthly, 0);
}

function lookupRegionalFlavor(sourceFlavor, region) {
  const key = normalizeFlavor(sourceFlavor);
  const matrix = regionalTcoMatrix[region] || regionalTcoMatrix.IAD;
  const hit = matrix.find(r => normalizeFlavor(r[0]) === key);
  return hit ? { sourceFlavor: hit[0], flexFlavor: hit[1], ospcMonthly: hit[2], flexMonthly: hit[3] } : null;
}

function lookupOspcPriceByName(row) {
  if (!state.hasOspcPriceList) return 0;
  const name = String(field(row, ['server_name', 'source_server_name', 'name', 'instance', 'vm_name']) || '').trim().toLowerCase();
  return name ? moneyNumber(state.ospcPriceMap[name]) : 0;
}

function normalizeRegion(region) {
  const value = String(region || '').trim().toUpperCase();
  if (value.startsWith('DFW')) return 'DFW';
  if (value.startsWith('SJC')) return 'SJC';
  return 'IAD';
}

function normalizeFlavor(flavor) {
  return String(flavor || '').trim().toLowerCase().replace(/\s+/g, '');
}

function classifyComponent(row, fallbackName) {
  const text = [field(row, ['source_resource_type', 'service_type', 'role', 'component']), fallbackName, field(row, ['source_image_name', 'image', 'detected_services'])].join(' ').toLowerCase();
  if (/db|database|mysql|maria|postgres|mongo|sql/.test(text)) return 'DB Instance';
  if (/load.?balancer|haproxy|\blb\b/.test(text)) return 'Load Balancer';
  return 'VM / Compute';
}

function field(row, keys) {
  for (const key of keys) {
    const value = row?.[key];
    if (value !== undefined && value !== null && String(value).trim() !== '') return String(value).trim();
  }
  return '';
}

function moneyNumber(value) {
  if (value === undefined || value === null || value === '') return 0;
  if (typeof value === 'number') return Number.isFinite(value) ? value : 0;
  const text = String(value).trim();
  if (!text) return 0;
  const negative = /^\(.*\)$/.test(text) || /^-/.test(text);
  const n = Number(text.replace(/[$,\s()]/g, ''));
  if (Number.isNaN(n)) return 0;
  return negative ? -Math.abs(n) : n;
}

function money(value) {
  const n = Number(value) || 0;
  const abs = Math.abs(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return n < 0 ? `-$${abs}` : `$${abs}`;
}

function renderMapperTable(rows) {
  renderTableWithOptions(rows, state.mapperVisibleHeaders, els.mapperTable, els.mapperRowCount, { tableType: 'mapper', editable: state.editModeMapper });
}

function renderFlavorInventory(rows) {
  const sourceCounts = sortCounts(countBySourceFlavor(rows));
  const targetCounts = sortCounts(countBy(rows, 'target_flavor_name'));
  const sourceTotal = sourceCounts.reduce((sum, [, c]) => sum + c, 0);
  const targetTotal = targetCounts.reduce((sum, [, c]) => sum + c, 0);

  els.inventoryCount.textContent = `Combined total: ${rows.length.toLocaleString()} rows`;
  els.sourceFlavorTable.innerHTML = renderSimpleCountTable(sourceCounts, 'Source Flavor');
  els.targetFlavorTable.innerHTML = renderSimpleCountTable(targetCounts, 'Target Flavor');
  els.sourceFlavorTotal.textContent = `Total: ${sourceTotal.toLocaleString()}`;
  els.targetFlavorTotal.textContent = `Total: ${targetTotal.toLocaleString()}`;

  const sourceRamMbTotal = sumNumericWithFallback(rows, 'source_ram_mb', 'source_flavor_id', sourceFlavorSpecs, 'ram_mb');
  const targetRamMbTotal = sumNumericWithFallback(rows, 'target_ram_mb', 'target_flavor_name', targetFlavorSpecs, 'ram_mb');
  const sourceVcpuTotal = sumNumericWithFallback(rows, 'source_vcpus', 'source_flavor_id', sourceFlavorSpecs, 'vcpus');
  const targetVcpuTotal = sumNumericWithFallback(rows, 'target_vcpus', 'target_flavor_name', targetFlavorSpecs, 'vcpus');

  els.sourceRamTotal.textContent = formatNumber(sourceRamMbTotal / 1024);
  els.targetRamTotal.textContent = formatNumber(targetRamMbTotal / 1024);
  els.sourceVcpuTotal.textContent = formatNumber(sourceVcpuTotal);
  els.targetVcpuTotal.textContent = formatNumber(targetVcpuTotal);

  renderVolumeInventorySummary(rows);
  renderLoadBalancerInventorySummary(state.lbFiltered || []);
}

function renderVolumeInventorySummary(mapperRows) {
  const fromBlock = aggregateVolumeSummaryFromBlockRows(state.blockFiltered || []);
  const source = fromBlock || aggregateSourceVolumeInfo(state.rows || []);
  const destination = fromBlock ? fromBlock.destination : aggregateDestinationVolumeInfo(mapperRows || [], source.byServer);

  const tableRows = [
    ['Volume Count', source.count, destination.count],
    ['Total Size (GB)', source.sizeGb, destination.sizeGb],
  ];

  const head = '<thead><tr><th>Metric</th><th>Source</th><th>Expected Destination</th></tr></thead>';
  const body = '<tbody>' + tableRows.map(r => `<tr><td>${escapeHtml(String(r[0]))}</td><td>${formatNumber(r[1])}</td><td>${formatNumber(r[2])}</td></tr>`).join('') + '</tbody>';
  els.volumeInventoryTable.innerHTML = head + body;
}

function renderLoadBalancerInventorySummary(lbRows) {
  if (!els.lbInventoryTable) return;
  const rows = Array.isArray(lbRows) ? lbRows : [];
  if (!rows.length) {
    const head = '<thead><tr><th>Metric</th><th>Count</th></tr></thead>';
    const body = '<tbody><tr><td>No LB mapping rows loaded</td><td>0</td></tr></tbody>';
    els.lbInventoryTable.innerHTML = head + body;
    return;
  }

  const unique = values => Object.keys(values).filter(k => k && k !== '(blank)');
  const lbById = countBy(rows, 'load_balancer_id');
  const lbByName = countBy(rows, 'load_balancer_name');
  const sourceLbCount = unique(lbById).length || unique(lbByName).length;
  const plannedLbCount = unique(lbByName).length || unique(lbById).length;

  const memberRows = rows.filter(r => String(r.source_member_ip || r.source_server_id || '').trim() !== '');
  const includedMembers = rows.filter(r => isTruthy(String(r.member_include_in_deploy || '')));

  const metrics = [
    ['Source LBs Found', sourceLbCount],
    ['Planned Octavia LBs', plannedLbCount],
    ['Source Member Rows', memberRows.length],
    ['Planned Member Adds', includedMembers.length],
  ];

  const head = '<thead><tr><th>Metric</th><th>Count</th></tr></thead>';
  const body = '<tbody>' + metrics
    .map(([k, v]) => `<tr><td>${escapeHtml(String(k))}</td><td>${escapeHtml(String(v))}</td></tr>`)
    .join('') + '</tbody>';
  els.lbInventoryTable.innerHTML = head + body;
}

function aggregateVolumeSummaryFromBlockRows(blockRows) {
  if (!blockRows || blockRows.length === 0) return null;
  const hasVolumeRole = blockRows.some(r => (r.volume_role || '').trim() !== '');
  if (!hasVolumeRole) return null;

  let sourceCount = 0;
  let sourceSize = 0;
  let destCount = 0;
  let destSize = 0;
  for (const r of blockRows) {
    const size = Number(r.volume_size_gb || 0) || 0;
    sourceCount += 1;
    sourceSize += size;

    const role = (r.volume_role || '').trim().toLowerCase();
    const action = (r.target_action || '').trim().toLowerCase();
    if (role === 'data') {
      destCount += 1;
      destSize += size;
    } else if (role === 'boot') {
      if (action === 'boot_from_volume') {
        destCount += 1;
        const bootSize = Number(r.boot_from_volume_size_gb || 0) || size;
        destSize += bootSize;
      }
    }
  }

  return {
    count: sourceCount,
    sizeGb: sourceSize,
    destination: { count: destCount, sizeGb: destSize },
    byServer: {}
  };
}

function aggregateSourceVolumeInfo(accountRows) {
  const byServer = {};
  let count = 0;
  let sizeGb = 0;

  for (const row of accountRows) {
    if ((row.service_type || '') !== 'block_storage_volume') continue;
    if ((row.status || '').toLowerCase() !== 'in-use') continue;

    const attachments = parseAttachmentField(row.attachments || '');
    const volumeSize = Number(row.size_gb || 0) || 0;
    for (const a of attachments) {
      const serverId = String(a.server_id || a.serverId || a.server || '').trim();
      if (!serverId) continue;
      const sourceDevice = String(a.device || '').trim();
      const rec = {
        sizeGb: volumeSize,
        sourceDevice,
        isBoot: sourceDevice.toLowerCase() === '/dev/xvda' || sourceDevice.toLowerCase() === '/dev/vda'
      };
      if (!byServer[serverId]) byServer[serverId] = [];
      byServer[serverId].push(rec);
      count += 1;
      sizeGb += volumeSize;
    }
  }

  return { count, sizeGb, byServer };
}

function aggregateDestinationVolumeInfo(mapperRows, sourceByServer) {
  let count = 0;
  let sizeGb = 0;

  for (const row of mapperRows) {
    const serverId = String(row.server_id || '').trim();
    const bootStrategy = String(row.boot_strategy || '').trim();

    if (bootStrategy === 'boot_from_volume') {
      count += 1;
      sizeGb += Number(row.boot_from_volume_size_gb || 0) || 0;
    } else if (bootStrategy === 'boot_from_volume_required_by_target_flavor') {
      count += 1;
      sizeGb += Number(row.boot_volume_source_size_gb || 0) || 0;
    }

    const sourceVols = sourceByServer[serverId] || [];
    for (const v of sourceVols) {
      if (v.isBoot) continue;
      count += 1;
      sizeGb += Number(v.sizeGb || 0) || 0;
    }
  }

  return { count, sizeGb };
}

function parseAttachmentField(raw) {
  const text = String(raw || '').trim();
  if (!text) return [];

  try {
    const parsed = JSON.parse(text);
    return Array.isArray(parsed) ? parsed : [];
  } catch (_) {}

  try {
    const normalized = text
      .replace(/\bNone\b/g, 'null')
      .replace(/\bTrue\b/g, 'true')
      .replace(/\bFalse\b/g, 'false')
      .replace(/'/g, '"');
    const parsed = JSON.parse(normalized);
    return Array.isArray(parsed) ? parsed : [];
  } catch (_) {
    return [];
  }
}

function countBySourceFlavor(rows) {
  return rows.reduce((acc, r) => {
    const name = (r.source_flavor_name || '').trim();
    const id = (r.source_flavor_id || '').trim();
    const val = name || id || '(blank)';
    acc[val] = (acc[val] || 0) + 1;
    return acc;
  }, {});
}

function renderTable(rows, headers, tableEl, countEl) {
  return renderTableWithOptions(rows, headers, tableEl, countEl, { tableType: 'primary', editable: state.editModePrimary });
}

function renderTableWithOptions(rows, headers, tableEl, countEl, options = {}) {
  const tableType = options.tableType || 'primary';
  const editable = Boolean(options.editable);
  const baseRows = getBaseRowsForTable(tableType);
  const indexMap = new Map(baseRows.map((row, idx) => [row, idx]));
  const safeHeaders = headers.length ? headers : [];
  countEl.textContent = `${rows.length.toLocaleString()} rows`;
  const head = `<thead><tr>${safeHeaders.map(h => `<th>${escapeHtml(h)}</th>`).join('')}</tr></thead>`;
  const body = `<tbody>${rows.map(r => {
    const rowIndex = indexMap.has(r) ? indexMap.get(r) : -1;
    const rowClass = getRowClass(r, tableType);
    return `<tr class="${rowClass}">${safeHeaders.map(h => {
      const value = r[h] || '';
      if (!editable) return `<td>${escapeHtml(value)}</td>`;
      const editedClass = rowIndex >= 0 && isCellEdited(tableType, rowIndex, h, value) ? ' edited-cell' : '';
      return `<td class="editable-cell${editedClass}" contenteditable="true" data-table="${tableType}" data-row-index="${rowIndex}" data-col="${escapeHtml(h)}">${escapeHtml(value)}</td>`;
    }).join('')}</tr>`;
  }).join('')}</tbody>`;
  tableEl.innerHTML = head + body;
}

function renderBlockTable(rows) {
  renderTableWithOptions(rows, state.blockHeaders, els.blockTable, els.blockRowCount, { tableType: 'block', editable: state.editModeBlock });
}

function renderLbTable(rows) {
  renderTableWithOptions(rows, state.lbHeaders, els.lbTable, els.lbRowCount, { tableType: 'lb', editable: false });
}

function toggleEditMode(tableType) {
  if (tableType === 'primary') {
    state.editModePrimary = !state.editModePrimary;
    updateEditButton(els.toggleEditPrimary, state.editModePrimary);
    renderTableWithOptions(state.filtered, state.visibleHeaders, els.table, els.rowCount, { tableType: 'primary', editable: state.editModePrimary });
    return;
  }
  if (tableType === 'mapper') {
    state.editModeMapper = !state.editModeMapper;
    updateEditButton(els.toggleEditMapper, state.editModeMapper);
    renderMapperTable(state.mapperFiltered);
    return;
  }
  if (tableType === 'block') {
    state.editModeBlock = !state.editModeBlock;
    updateEditButton(els.toggleEditBlock, state.editModeBlock);
    renderBlockTable(state.blockFiltered);
  }
}

function updateEditButton(btn, enabled) {
  if (!btn) return;
  btn.textContent = enabled ? 'Disable Edit Mode' : 'Enable Edit Mode';
  btn.classList.toggle('active-edit', enabled);
}

function getBaseRowsForTable(tableType) {
  if (tableType === 'mapper') return state.mapperRows;
  if (tableType === 'block') return state.blockRows;
  if (tableType === 'lb') return state.lbRows;
  return state.rows;
}

function getOriginalRowsForTable(tableType) {
  if (tableType === 'mapper') return state.originalMapperRows;
  if (tableType === 'block') return state.originalBlockRows;
  return state.originalRows;
}

function isCellEdited(tableType, rowIndex, col, currentValue) {
  const originalRows = getOriginalRowsForTable(tableType);
  if (rowIndex < 0 || rowIndex >= originalRows.length) return false;
  const originalValue = originalRows[rowIndex]?.[col] || '';
  return String(currentValue || '') !== String(originalValue || '');
}

function onEditableCellKeyDown(e) {
  const target = e.target;
  if (!(target instanceof HTMLElement)) return;
  if (!target.classList.contains('editable-cell')) return;
  if (e.key === 'Enter') {
    e.preventDefault();
    target.blur();
  }
}

function onEditableCellFocusOut(e) {
  const target = e.target;
  if (!(target instanceof HTMLElement)) return;
  if (!target.classList.contains('editable-cell')) return;

  const tableType = target.getAttribute('data-table') || 'primary';
  const col = target.getAttribute('data-col') || '';
  const rowIndex = Number(target.getAttribute('data-row-index') || '-1');
  if (!col || Number.isNaN(rowIndex) || rowIndex < 0) return;

  const baseRows = getBaseRowsForTable(tableType);
  if (rowIndex >= baseRows.length) return;

  const newValue = (target.textContent || '').trim();
  const oldValue = String(baseRows[rowIndex]?.[col] || '');
  if (newValue === oldValue) return;

  baseRows[rowIndex][col] = newValue;
  refreshAfterEdit(tableType);
}

function refreshAfterEdit(tableType) {
  if (tableType === 'mapper') {
    applyMapperFilters();
    return;
  }
  if (tableType === 'block') {
    applyBlockFilters();
    return;
  }
  applyFilters();
}

function getRowClass(row, tableType = 'primary') {
  const classes = [];
  const hasTargetCol = Object.prototype.hasOwnProperty.call(row, 'target_flavor_name');
  const hasRateCol = Object.prototype.hasOwnProperty.call(row, 'target_hourly_rate_usd');
  const hasImageCol = Object.prototype.hasOwnProperty.call(row, 'recommended_target_image_name');

  if (hasTargetCol && !String(row.target_flavor_name || '').trim()) classes.push('row-missing-target');
  if (hasTargetCol && String(row.target_flavor_name || '').trim() && hasRateCol && !String(row.target_hourly_rate_usd || '').trim()) classes.push('row-missing-price');
  if (tableType === 'mapper' && hasImageCol && !String(row.recommended_target_image_name || '').trim()) classes.push('row-missing-image');

  return classes.join(' ');
}

function exportPrimaryFiltered() {
  if (!state.filtered.length) return;
  downloadCsv(`dashboard_filtered_${timestampString()}.csv`, state.visibleHeaders, state.filtered);
}

function exportPrimaryEdited() {
  if (!state.rows.length) return;
  downloadCsv(`overview_edited_${timestampString()}.csv`, state.headers, state.rows);
}

async function savePrimaryEdited() {
  await saveEditedToServer(state.primarySourceName, state.headers, state.rows, 'overview');
}

function exportMapperFiltered() {
  if (!state.mapperFiltered.length) return;
  downloadCsv(`mapper_filtered_${timestampString()}.csv`, state.mapperVisibleHeaders, state.mapperFiltered);
}

function exportMapperEdited() {
  if (!state.mapperRows.length) return;
  downloadCsv(`mapper_edited_${timestampString()}.csv`, state.mapperHeaders, state.mapperRows);
}

async function saveMapperEdited() {
  await saveEditedToServer(state.mapperSourceName, state.mapperHeaders, state.mapperRows, 'mapper');
}

function exportBlockEdited() {
  if (!state.blockRows.length) return;
  downloadCsv(`block_edited_${timestampString()}.csv`, state.blockHeaders, state.blockRows);
}

async function saveBlockEdited() {
  await saveEditedToServer(state.blockSourceName, state.blockHeaders, state.blockRows, 'block');
}

function downloadCsv(filename, headers, rows) {
  const cols = headers.length ? headers : [];
  const lines = [cols.map(csvEscape).join(',')];
  rows.forEach(row => {
    lines.push(cols.map(h => csvEscape(row[h] || '')).join(','));
  });
  const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.style.display = 'none';
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

function buildCsvText(headers, rows) {
  const cols = headers.length ? headers : [];
  const lines = [cols.map(csvEscape).join(',')];
  rows.forEach(row => {
    lines.push(cols.map(h => csvEscape(row[h] || '')).join(','));
  });
  return lines.join('\n');
}

async function saveEditedToServer(sourceName, headers, rows, label) {
  if (!sourceName) {
    window.alert(`No ${label} source filename is known yet. Load the CSV first.`);
    return;
  }
  if (!rows.length) {
    window.alert(`No ${label} rows to save.`);
    return;
  }
  const csvText = buildCsvText(headers, rows);
  try {
    const res = await fetch('/api/save-csv', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ target_name: sourceName, content: csvText })
    });
    const data = await res.json();
    if (!res.ok || !data.ok) throw new Error(data.error || 'Save failed');
    window.alert(`Saved: ${data.saved_path}`);
  } catch (err) {
    window.alert(`Save failed: ${err.message}`);
  }
}

function csvEscape(value) {
  const str = String(value);
  if (str.includes(',') || str.includes('"') || str.includes('\n') || str.includes('\r')) {
    return `"${str.replaceAll('"', '""')}"`;
  }
  return str;
}

function timestampString() {
  const d = new Date();
  const pad = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}_${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

function countBy(rows, key) {
  return rows.reduce((acc, r) => {
    const val = (r[key] || '').trim() || '(blank)';
    acc[val] = (acc[val] || 0) + 1;
    return acc;
  }, {});
}

function sortCounts(map) {
  return Object.entries(map).sort((a, b) => (b[1] - a[1]) || a[0].localeCompare(b[0]));
}

function renderSimpleCountTable(entries, label) {
  const head = `<thead><tr><th>${escapeHtml(label)}</th><th>Count</th></tr></thead>`;
  const body = `<tbody>${entries.map(([name, count]) => `<tr><td>${escapeHtml(name)}</td><td>${count}</td></tr>`).join('')}</tbody>`;
  return head + body;
}

function topEntry(map) {
  const entries = Object.entries(map);
  if (!entries.length) return null;
  entries.sort((a, b) => b[1] - a[1]);
  return { key: entries[0][0], value: entries[0][1] };
}

function sumCurrency(rows, key) {
  let total = 0;
  for (const row of rows) {
    const n = Number(row[key]);
    if (!Number.isNaN(n)) total += n;
  }
  return total;
}

function sumNumeric(rows, key) {
  let total = 0;
  for (const row of rows) {
    const n = Number(row[key]);
    if (!Number.isNaN(n)) total += n;
  }
  return total;
}

function sumNumericWithFallback(rows, numericKey, lookupKey, specMap, specField) {
  let total = 0;
  for (const row of rows) {
    const direct = Number(row[numericKey]);
    if (!Number.isNaN(direct) && direct > 0) {
      total += direct;
      continue;
    }
    const lookup = String(row[lookupKey] || '').trim();
    if (!lookup) {
      continue;
    }
    const spec = specMap[lookup];
    if (spec && typeof spec[specField] === 'number') {
      total += spec[specField];
    }
  }
  return total;
}

function formatNumber(value) {
  const rounded = Math.round((Number(value) || 0) * 100) / 100;
  return rounded.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

function isTruthy(value) {
  return ['1', 'true', 'yes', 'y', 'on'].includes(String(value || '').trim().toLowerCase());
}

function card(label, value) {
  return `<article class="card"><div class="label">${escapeHtml(String(label))}</div><div class="value">${escapeHtml(String(value))}</div></article>`;
}

function slug(input) {
  return String(input).toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
}

function escapeHtml(input) {
  return String(input)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}


// --- Auto-load server-side CSVs based on account ID ---
async function loadServerCsv(filename, mode) {
  try {
    const cacheKey = 'csv_cache:' + filename;
    let csvText = sessionStorage.getItem(cacheKey);
    if (!csvText) {
      const safeName = filename.replace(/^uploads\//, '');
      const res = await fetch(`/api/dashboard/csv-content/${encodeURIComponent(safeName)}`);
      if (!res.ok) return;
      csvText = await res.text();
      if (!csvText || !csvText.trim()) return;
      try { sessionStorage.setItem(cacheKey, csvText); } catch (_) {}
    }
    const parsed = parseCSV(csvText);
    if (!parsed.headers.length) return;

    const isMapper = mode === true;
    const isBlock = mode === 'block';
    const isLb = mode === 'lb';
    const meta = isMapper ? els.mapperMeta : (isBlock ? els.blockMeta : (isLb ? els.lbMeta : els.fileMeta));

    if (isMapper) {
      state.mapperSourceName = filename;
      state.mapperHeaders = parsed.headers;
      state.mapperRows = parsed.rows;
      state.originalMapperRows = parsed.rows.map(r => ({ ...r }));
      state.mapperFiltered = parsed.rows;
      state.mapperVisibleHeaders = [...parsed.headers];
      meta.textContent = `${filename} loaded (${parsed.rows.length.toLocaleString()} rows)`;
      renderColumnPicker(true); renderMapperSummary(parsed.rows);
      renderMapperTable(parsed.rows); renderFlavorInventory(parsed.rows);
      els.mapperSummary.classList.remove('hidden'); els.mapperTablePanel.classList.remove('hidden');
      els.inventoryPanel.classList.remove('hidden');
    } else if (isBlock) {
      state.blockSourceName = filename;
      state.blockHeaders = parsed.headers;
      state.blockRows = parsed.rows;
      state.originalBlockRows = parsed.rows.map(r => ({ ...r }));
      state.blockFiltered = parsed.rows;
      meta.textContent = `${filename} loaded (${parsed.rows.length.toLocaleString()} rows)`;
      if (typeof renderBlockTable === 'function') renderBlockTable(parsed.rows);
      if (els.blockTablePanel) els.blockTablePanel.classList.remove('hidden');
    } else if (isLb) {
      state.lbSourceName = filename;
      state.lbHeaders = parsed.headers;
      state.lbRows = parsed.rows;
      state.originalLbRows = parsed.rows.map(r => ({ ...r }));
      state.lbFiltered = parsed.rows;
      meta.textContent = `${filename} loaded (${parsed.rows.length.toLocaleString()} rows)`;
      if (typeof renderLbTable === 'function') renderLbTable(parsed.rows);
      if (els.lbTablePanel) els.lbTablePanel.classList.remove('hidden');
    } else {
      state.sourceName = filename;
      state.headers = parsed.headers;
      state.rows = parsed.rows;
      state.originalRows = parsed.rows.map(r => ({ ...r }));
      state.filtered = parsed.rows;
      state.visibleHeaders = [...parsed.headers];
      meta.textContent = `${filename} loaded (${parsed.rows.length.toLocaleString()} rows)`;
      renderColumnPicker(false);
      renderTable(parsed.rows);
      renderSummary(parsed.rows);
      els.controls.classList.remove('hidden'); els.tablePanel.classList.remove('hidden');
      els.summary.classList.remove('hidden');
    }
  } catch (e) { console.warn('Auto-load failed:', e); }
}

// Auto-detect account ID and load matching CSVs from server uploads
(async function autoLoadCsvs() {
  try {
    const res = await fetch('/api/files');
    if (!res.ok) return;
    const data = await res.json();
    const files = Array.isArray(data) ? data : (data.files || []);
    if (!files.length) return;

    // Find account ID prefix from overview file
    const ovFile = files.find(f => f.endsWith('_overview.csv') && !f.includes('/'));
    if (!ovFile) return;
    const prefix = ovFile.split('_')[0];

    // Exact prefix match, or fall back to first matching file of that type
    const pick = (suffix) =>
      files.find(f => f === prefix + suffix) ||
      files.find(f => f.endsWith(suffix) && !f.includes('flex2flex') && !f.includes('/'));

    const overview  = pick('_overview.csv');
    const flavormap = pick('_flavormap.csv');
    const blockmap  = pick('_blockmap.csv');
    const lbmap     = pick('_lbmap.csv');

    if (overview)  await loadServerCsv(overview,  false);
    if (flavormap) await loadServerCsv(flavormap, true);
    if (blockmap)  await loadServerCsv(blockmap,  'block');
    if (lbmap)     await loadServerCsv(lbmap,     'lb');
  } catch (e) { console.warn('Auto-load error:', e); }
})();
