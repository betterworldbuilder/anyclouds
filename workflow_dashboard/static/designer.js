const state = {
  nodes: [],
  edges: [],
  selectedNodeId: null,
  selectedNodeIds: [],
  connectMode: false,
  connectFrom: null,
  drag: null,
  panDrag: null,
  panX: 0,
  panY: 0,
  suppressCanvasClick: false,
  zoom: 1,
};

const canvas = document.getElementById('canvas');
const scene = document.getElementById('scene');
const edgesSvg = document.getElementById('edges');
const propertiesPanel = document.getElementById('propertiesPanel');
const topologySelect = document.getElementById('topologySelect');
const scriptPreview = document.getElementById('scriptPreview');
const validationPreview = document.getElementById('validationPreview');
const planPreview = document.getElementById('planPreview');
const logBox = document.getElementById('logBox');
const connectModeBtn = document.getElementById('connectModeBtn');
const zoomLabel = document.getElementById('zoomLabel');
const openrcFileInput = document.getElementById('openrcFile');
const openrcSelect = document.getElementById('openrcSelect');
const openrcContentInput = document.getElementById('openrcContent');
const scriptFileInput = document.getElementById('scriptFile');

const DEFAULT_OPENRC_FILE = 'openrcpassnew.sh';
const DEFAULT_DEPLOY_SCRIPT_FILE = '1342314_tenant_deploy.sh';
const INFRA_SOURCE_MODES = {
  ospc: {
    title: 'Anycloud to FLEX Infrastructure Topology Builder and Deployer',
    subtitle: 'Clone discovered source topology onto FLEX, link resources, then generate or run the deployment script.',
    hint: 'Use the Stage 1 OSPC infra discovery deployment script, or import a live OpenStack project when credentials are available.',
    liveHint: 'Import uses FLEX/OpenStack OpenRC credentials and discovers resources currently in that project.',
    scriptHint: 'Paste the OSPC Stage 1 tenant deploy script to reconstruct networks, routers, security groups, load balancers, volumes, and VMs.',
    fileDefault: DEFAULT_DEPLOY_SCRIPT_FILE,
    filenameTag: 'ospc2flex',
  },
  flex2flex: {
    title: 'FLEX2FLEX Infrastructure Topology Builder and Deployer',
    subtitle: 'Discover an existing FLEX project or import its generated script, then clone the same infrastructure shape into the target FLEX region.',
    hint: 'Use FLEX source OpenRC for live discovery, then deploy with target FLEX OpenRC. Script import accepts the same OpenStack commands as OSPC2FLEX.',
    liveHint: 'Import From Project discovers the source FLEX project with OpenStack CLI, matching the OSPC infra discovery shape.',
    scriptHint: 'Paste a FLEX source topology/deploy script or generated OpenStack CLI script to build the same visual topology module.',
    fileDefault: 'flex2flex_topology_deploy.sh',
    filenameTag: 'flex2flex',
  },
  hyperflex: {
    title: 'HYPER FLEX Infrastructure Topology Builder and Deployer',
    subtitle: 'Adapt AWS, Azure, or GCP discovered infrastructure into FLEX topology, then generate or run the FLEX deployment script.',
    hint: 'Use hyperscaler discovery output from Stage 1, converted OpenStack-style script, or manually place nodes before FLEX deploy.',
    liveHint: 'Live OpenStack import is for FLEX/OpenStack sources. For AWS, Azure, or GCP, paste the converted discovery/deploy script or use manual topology nodes.',
    scriptHint: 'Paste hyperscaler-to-FLEX converted topology commands. The builder reuses the same OSPC2FLEX visual parser and deployment stages.',
    fileDefault: 'hyperflex_topology_deploy.sh',
    filenameTag: 'hyperflex',
  },
};

function currentInfraSourceMode() {
  const selectValue = document.getElementById('infraSourceMode')?.value || '';
  const queryValue = new URLSearchParams(window.location.search).get('source') || '';
  const mode = (selectValue || queryValue || 'ospc').toLowerCase();
  return INFRA_SOURCE_MODES[mode] ? mode : 'ospc';
}

function applyInfraSourceMode(modeArg) {
  const mode = INFRA_SOURCE_MODES[modeArg] ? modeArg : currentInfraSourceMode();
  const cfg = INFRA_SOURCE_MODES[mode];
  const select = document.getElementById('infraSourceMode');
  if (select) select.value = mode;
  const title = document.getElementById('designerTitle');
  const subtitle = document.getElementById('designerSubtitle');
  const sourceHint = document.getElementById('infraSourceHint');
  const liveHint = document.getElementById('importLiveHint');
  const scriptHint = document.getElementById('importScriptHint');
  if (title) title.textContent = cfg.title;
  if (subtitle) subtitle.textContent = cfg.subtitle;
  if (sourceHint) sourceHint.textContent = cfg.hint;
  if (liveHint) liveHint.textContent = cfg.liveHint;
  if (scriptHint) scriptHint.textContent = cfg.scriptHint;
  if (scriptFileInput && (!scriptFileInput.value.trim() || Object.values(INFRA_SOURCE_MODES).some((m) => scriptFileInput.value === m.fileDefault))) {
    scriptFileInput.value = cfg.fileDefault;
  }
}

function getOpenrcContentValue() {
  return openrcContentInput ? openrcContentInput.value : '';
}

function log(msg) {
  const ts = new Date().toLocaleTimeString();
  logBox.textContent += `\n[${ts}] ${msg}`;
  logBox.scrollTop = logBox.scrollHeight;
}

function appendRawLog(text) {
  const chunk = String(text || '').replaceAll('\r', '');
  if (!chunk) return;
  if (!logBox.textContent.endsWith('\n')) logBox.textContent += '\n';
  logBox.textContent += chunk;
  logBox.scrollTop = logBox.scrollHeight;
  updateActiveDeployPhaseFromText(chunk);
}

function downloadTextFile(filename, text) {
  const blob = new Blob([String(text || '')], { type: 'text/plain;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

function wireTextPaneActions(copyId, saveId, clearId, pane, defaultText, filename) {
  document.getElementById(copyId)?.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(pane?.textContent || '');
      log(`Copied ${filename}`);
    } catch (e) {
      log(`Copy failed: ${e.message}`);
    }
  });
  document.getElementById(saveId)?.addEventListener('click', () => {
    downloadTextFile(filename, pane?.textContent || '');
  });
  document.getElementById(clearId)?.addEventListener('click', () => {
    if (pane) pane.textContent = defaultText;
  });
}

wireTextPaneActions('copyScriptPreviewBtn', 'saveScriptPreviewBtn', 'clearScriptPreviewBtn', scriptPreview, 'No script generated yet.', 'generated-script.sh');
wireTextPaneActions('copyActivityLogBtn', 'saveActivityLogBtn', 'clearActivityLogBtn', logBox, 'Ready.', 'activity-log.txt');

async function withButtonBusy(buttonId, actionName, fn) {
  const btn = document.getElementById(buttonId);
  if (!btn) {
    await fn();
    return;
  }
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

function nodeDisplayName(node) {
  return (node.props?.name || node.label || node.id || '').trim() || node.type;
}

function topologyLabel(node) {
  const text = nodeDisplayName(node);
  return text.length > 10 ? text.slice(0, 10) : text;
}

function isNodeMultiSelected(nodeId) {
  return state.selectedNodeIds.includes(nodeId);
}

function shortText(value, maxLen = 16) {
  const text = String(value || '').trim();
  if (!text) return '';
  if (text.length <= maxLen) return text;
  return `${text.slice(0, maxLen - 1)}…`;
}

function nodeMetaBadges(node) {
  const props = node?.props || {};
  const badges = [];
  if (node.type === 'volume') {
    const vType = shortText(props.volume_type || '', 18);
    const size = String(props.size_gb || '').trim();
    if (vType) badges.push(vType);
    if (size) badges.push(`${size} GB`);
  }
  return badges;
}

function instanceMetaHtml(node) {
  const props = node?.props || {};
  const flavor = String(props.flavor || '').trim();
  const authMode = String(props.auth_mode || '').trim().toLowerCase();
  const keyName = String(props.key_name || '').trim();
  const showKey = authMode !== 'windows_password' && keyName;
  const keyHtml = showKey
    ? `<div class="instance-key-chip">Key: ${escapeHtml(keyName)}</div>`
    : '';
  return { flavor, keyHtml, imageHtml: '' };
}

function defaultProps(type) {
  if (type === 'network') return { name: 'tenant-net' };
  if (type === 'subnet') return { name: 'tenant-subnet', cidr: '10.60.0.0/24', gateway_ip: '', dns_nameserver: '' };
  if (type === 'router') return { name: 'tenant-router', external_network: 'PUBLICNET' };
  if (type === 'security_group') {
    return {
      name: 'default-sg',
      rules_text: 'tcp 22 0.0.0.0/0\ntcp 80 0.0.0.0/0\ntcp 443 0.0.0.0/0',
    };
  }
  if (type === 'instance') {
    return {
      name: 'vm-1',
      flavor: 'gp.5.4.4',
      image: '',
      user_data: '',
      auth_mode: 'ssh_key',
      key_name: '',
      admin_user: 'Administrator',
      admin_password: '',
      needs_floating_ip: false,
      floating_network: 'PUBLICNET',
    };
  }
  if (type === 'volume') return { name: 'data-vol-1', size_gb: '50', volume_type: 'Performance' };
  if (type === 'load_balancer') {
    return {
      name: 'lb-1',
      provider: 'amphora',
      protocol: 'HTTP',
      listener_port: '80',
      member_port: '80',
      pool_algorithm: 'ROUND_ROBIN',
      needs_floating_ip: false,
      floating_network: 'PUBLICNET',
    };
  }
  return {};
}

function parseRules(text) {
  const rows = String(text || '').split('\n').map(r => r.trim()).filter(Boolean);
  const rules = [];
  for (const row of rows) {
    const parts = row.split(/\s+/);
    if (parts.length < 3) continue;
    rules.push({ protocol: parts[0], port: parts[1], remote_ip: parts.slice(2).join(' ') });
  }
  return rules;
}

function edgeTypeForPair(a, b) {
  const pair = [a.type, b.type].sort().join('|');
  if (pair === 'instance|volume') return 'attach';
  if (pair === 'network|router') return 'gateway';
  if (pair === 'router|subnet') return 'route';
  if (pair === 'instance|load_balancer') return 'member';
  if (pair === 'load_balancer|subnet') return 'member';
  return 'member';
}

function render() {
  scene.querySelectorAll('.node').forEach(n => n.remove());
  for (const node of state.nodes) {
    const el = document.createElement('div');
    const selectedClass = node.id === state.selectedNodeId ? ' selected' : '';
    const multiClass = isNodeMultiSelected(node.id) ? ' multi-selected' : '';
    el.className = `node ${node.type}${selectedClass}${multiClass}`;
    el.style.left = `${node.x}px`;
    el.style.top = `${node.y}px`;
    el.dataset.id = node.id;
    const fipBadge = (node.type === 'instance' || node.type === 'load_balancer') && node.props?.needs_floating_ip
      ? '<span class="node-badge">FIP</span>'
      : '';
    let metaHtml = '';
    const fullName = nodeDisplayName(node);
    const shortName = topologyLabel(node);
    let nameHtml = `<div class="name" title="${escapeHtml(fullName)}">${escapeHtml(shortName)}</div>`;
    if (node.type === 'instance') {
      const instanceMeta = instanceMetaHtml(node);
      const flavorHtml = instanceMeta.flavor
        ? `<span class="instance-flavor-chip">Flavor: ${escapeHtml(instanceMeta.flavor)}</span>`
        : '';
      nameHtml = `<div class="instance-name-row"><div class="name" title="${escapeHtml(fullName)}">${escapeHtml(shortName)}</div>${flavorHtml}</div>`;
      metaHtml = `${instanceMeta.keyHtml || ''}${instanceMeta.imageHtml || ''}`;
    } else {
      const metaBadges = nodeMetaBadges(node);
      metaHtml = metaBadges.length
        ? `<div class="node-meta">${metaBadges.map((t) => `<span class="node-meta-badge">${escapeHtml(t)}</span>`).join('')}</div>`
        : '';
    }
    el.innerHTML = `<div class="title-row"><div class="title">${node.type.replace('_', ' ')}</div>${fipBadge}</div>${nameHtml}${metaHtml}`;

    el.addEventListener('mousedown', (ev) => {
      if (ev.button !== 0) return;
      if (state.connectMode) return;
      ev.stopPropagation();
      ev.preventDefault();
      state.drag = { id: node.id, offsetX: ev.offsetX / state.zoom, offsetY: ev.offsetY / state.zoom };
      state.selectedNodeId = node.id;
    });

    el.addEventListener('click', (ev) => {
      ev.stopPropagation();
      if (state.connectMode) {
        if (!state.connectFrom) {
          state.connectFrom = node.id;
          log(`Connect from: ${nodeDisplayName(node)}`);
          return;
        }
        if (state.connectFrom !== node.id) {
          connectNodes(state.connectFrom, node.id);
        }
        state.connectFrom = null;
        return;
      }
      if (ev.metaKey || ev.ctrlKey || ev.shiftKey) {
        if (isNodeMultiSelected(node.id)) {
          state.selectedNodeIds = state.selectedNodeIds.filter((id) => id !== node.id);
        } else {
          state.selectedNodeIds = [...state.selectedNodeIds, node.id];
        }
        state.selectedNodeId = node.id;
        render();
        return;
      }
      state.selectedNodeIds = [];
      selectNode(node.id);
    });

    scene.appendChild(el);
  }

  renderEdges();
  renderProperties();
}

function renderEdges() {
  edgesSvg.innerHTML = '';
  const width = Math.max(1, Math.round(canvas.clientWidth / state.zoom));
  const height = Math.max(1, Math.round(canvas.clientHeight / state.zoom));
  const gridStep = Math.max(8, Math.round(20 * state.zoom));
  const gridOffsetX = ((state.panX % gridStep) + gridStep) % gridStep;
  const gridOffsetY = ((state.panY % gridStep) + gridStep) % gridStep;
  canvas.style.setProperty('--grid-step', `${gridStep}px`);
  canvas.style.setProperty('--grid-offset-x', `${gridOffsetX}px`);
  canvas.style.setProperty('--grid-offset-y', `${gridOffsetY}px`);
  scene.style.width = `${width}px`;
  scene.style.height = `${height}px`;
  scene.style.transform = `translate(${state.panX}px, ${state.panY}px) scale(${state.zoom})`;
  zoomLabel.textContent = `Zoom: ${Math.round(state.zoom * 100)}%`;
  const nodeEls = new Map(
    [...scene.querySelectorAll('.node')].map((el) => [el.dataset.id, el])
  );
  for (const edge of state.edges) {
    const aEl = nodeEls.get(edge.from);
    const bEl = nodeEls.get(edge.to);
    if (!aEl || !bEl) continue;

    const x1 = aEl.offsetLeft + (aEl.offsetWidth / 2);
    const y1 = aEl.offsetTop + (aEl.offsetHeight / 2);
    const x2 = bEl.offsetLeft + (bEl.offsetWidth / 2);
    const y2 = bEl.offsetTop + (bEl.offsetHeight / 2);

    const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
    line.setAttribute('x1', String(x1));
    line.setAttribute('y1', String(y1));
    line.setAttribute('x2', String(x2));
    line.setAttribute('y2', String(y2));
    const isAttach = edge.type === 'attach';
    const isBoot = edge.type === 'boot';
    line.setAttribute('stroke', isBoot ? '#f7b774' : '#f8de93');
    line.setAttribute('stroke-width', '2');
    line.setAttribute('stroke-dasharray', isAttach ? '6 5' : (isBoot ? '2 4' : '0'));
    edgesSvg.appendChild(line);

    const tx = (x1 + x2) / 2;
    const ty = (y1 + y2) / 2;
    const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    text.setAttribute('x', String(tx));
    text.setAttribute('y', String(ty - 4));
    text.setAttribute('fill', '#ffffff');
    text.setAttribute('font-size', '11');
    text.setAttribute('text-anchor', 'middle');
    text.textContent = edge.type;
    edgesSvg.appendChild(text);
  }

  edgesSvg.setAttribute('width', String(width));
  edgesSvg.setAttribute('height', String(height));
  edgesSvg.setAttribute('viewBox', `0 0 ${width} ${height}`);
}

function escapeHtml(text) {
  return String(text || '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function addNode(type) {
  const id = `${type}_${Date.now()}_${Math.floor(Math.random() * 1000)}`;
  const node = {
    id,
    type,
    label: `${type}-${state.nodes.filter(n => n.type === type).length + 1}`,
    x: 40 + (state.nodes.length % 4) * 160,
    y: 40 + (state.nodes.length % 3) * 100,
    props: defaultProps(type),
  };
  state.nodes.push(node);
  selectNode(id);
  render();
}

function selectNode(id) {
  state.selectedNodeId = id;
  state.selectedNodeIds = [];
  render();
}

function deleteSelectedNode() {
  const ids = new Set(state.selectedNodeIds);
  if (state.selectedNodeId) ids.add(state.selectedNodeId);
  if (!ids.size) return;
  state.nodes = state.nodes.filter(n => !ids.has(n.id));
  state.edges = state.edges.filter(e => !ids.has(e.from) && !ids.has(e.to));
  state.selectedNodeId = null;
  state.selectedNodeIds = [];
  render();
}

function disconnectSelectedNodes() {
  const ids = new Set(state.selectedNodeIds);
  if (state.selectedNodeId) ids.add(state.selectedNodeId);
  if (ids.size < 2) {
    log('Select at least 2 nodes to disconnect.');
    return;
  }

  const before = state.edges.length;
  state.edges = state.edges.filter((e) => !(ids.has(e.from) && ids.has(e.to)));
  const removed = before - state.edges.length;
  if (removed <= 0) {
    log('No connections found between selected nodes.');
    return;
  }
  render();
  log(`Removed ${removed} connection(s) between selected nodes.`);
}

function connectNodes(fromId, toId) {
  const from = state.nodes.find(n => n.id === fromId);
  const to = state.nodes.find(n => n.id === toId);
  if (!from || !to) return;

  const exists = state.edges.some((e) =>
    (e.from === fromId && e.to === toId) || (e.from === toId && e.to === fromId)
  );
  if (exists) {
    log('Connection already exists.');
    return;
  }

  const edgeType = edgeTypeForPair(from, to);
  state.edges.push({ from: fromId, to: toId, type: edgeType });
  log(`Connected ${nodeDisplayName(from)} -> ${nodeDisplayName(to)} (${edgeType})`);
  render();
}

function renderProperties() {
  const node = state.nodes.find(n => n.id === state.selectedNodeId);
  if (!node) {
    propertiesPanel.innerHTML = '<p class="hint">Select a node to edit its properties.</p>';
    return;
  }

  const rows = [];
  rows.push(field('label', 'Label', node.label || ''));
  rows.push(field('name', 'Resource Name', node.props?.name || ''));

  if (node.type === 'subnet') {
    rows.push(field('cidr', 'CIDR', node.props?.cidr || ''));
    rows.push(field('gateway_ip', 'Gateway IP', node.props?.gateway_ip || ''));
    rows.push(field('dns_nameserver', 'DNS Nameserver', node.props?.dns_nameserver || ''));
  }
  if (node.type === 'router') {
    rows.push(field('external_network', 'External Network', node.props?.external_network || 'PUBLICNET'));
  }
  if (node.type === 'security_group') {
    rows.push(textareaField('rules_text', 'Rules (protocol port remote_cidr per line)', node.props?.rules_text || ''));
  }
  if (node.type === 'instance') {
    const authMode = String(node.props?.auth_mode || '').trim() || 'ssh_key';
    rows.push(field('flavor', 'Flavor', node.props?.flavor || ''));
    rows.push(field('image', 'Image', node.props?.image || ''));
    rows.push(textareaField('user_data', 'Cloud-Init User Data (YAML, optional)', node.props?.user_data || ''));
    rows.push(selectField('auth_mode', 'Auth Mode', authMode, [
      ['ssh_key', 'Linux / SSH Key'],
      ['windows_password', 'Windows / Password'],
    ]));
    if (authMode === 'windows_password') {
      rows.push(field('admin_user', 'Admin User', node.props?.admin_user || 'Administrator'));
      rows.push(passwordField('admin_password', 'Admin Password', node.props?.admin_password || ''));
    } else {
      rows.push(field('key_name', 'Key Pair (required)', node.props?.key_name || ''));
    }
    rows.push(checkboxField('needs_floating_ip', 'Assign Floating IP', Boolean(node.props?.needs_floating_ip)));
    if (node.props?.needs_floating_ip) {
      rows.push(field('floating_network', 'Floating Network', node.props?.floating_network || 'PUBLICNET'));
    }
  }
  if (node.type === 'volume') {
    rows.push(field('size_gb', 'Size GB', node.props?.size_gb || '50'));
    rows.push(field('volume_type', 'Volume Type', node.props?.volume_type || 'Performance'));
  }
  if (node.type === 'load_balancer') {
    rows.push(field('provider', 'Provider (ovn/amphora)', node.props?.provider || 'amphora'));
    rows.push(field('protocol', 'Protocol (HTTP/HTTPS/TCP)', node.props?.protocol || 'HTTP'));
    rows.push(field('listener_port', 'Listener Port', node.props?.listener_port || '80'));
    rows.push(field('member_port', 'Member Port', node.props?.member_port || '80'));
    rows.push(field('pool_algorithm', 'Pool Algorithm', node.props?.pool_algorithm || 'ROUND_ROBIN'));
    rows.push(checkboxField('needs_floating_ip', 'Assign Floating IP', Boolean(node.props?.needs_floating_ip)));
    if (node.props?.needs_floating_ip) {
      rows.push(field('floating_network', 'Floating Network', node.props?.floating_network || 'PUBLICNET'));
    }
  }

  propertiesPanel.innerHTML = rows.join('');
  const bindPropInput = (input) => {
    const handler = () => {
      const key = input.getAttribute('data-prop');
      if (!key) return;
      const isCheckbox = input.getAttribute('type') === 'checkbox';
      const cursorStart = typeof input.selectionStart === 'number' ? input.selectionStart : null;
      const cursorEnd = typeof input.selectionEnd === 'number' ? input.selectionEnd : null;
      if (key === 'label') {
        node.label = input.value;
      } else {
        node.props = node.props || {};
        node.props[key] = isCheckbox ? input.checked : input.value;
        if (node.type === 'instance' && key === 'image') {
          const imageText = String(node.props.image || '').toLowerCase();
          if (!node.props.auth_mode) {
            node.props.auth_mode = imageText.includes('windows') ? 'windows_password' : 'ssh_key';
          }
        }
        if (node.type === 'instance' && key === 'auth_mode') {
          const mode = String(node.props.auth_mode || '').trim();
          if (mode === 'windows_password') {
            if (!node.props.admin_user) node.props.admin_user = 'Administrator';
          }
        }
      }
      if (node.type === 'security_group') {
        node.props.rules = parseRules(node.props.rules_text || '');
      }
      render();

      // Preserve typing focus/caret across re-renders of the properties panel.
      const next = [...propertiesPanel.querySelectorAll('[data-prop]')]
        .find((el) => el.getAttribute('data-prop') === key);
      if (!next) return;
      next.focus();
      if (!isCheckbox && cursorStart !== null && typeof next.setSelectionRange === 'function') {
        const max = String(next.value || '').length;
        const start = Math.min(cursorStart, max);
        const end = Math.min(cursorEnd ?? cursorStart, max);
        next.setSelectionRange(start, end);
      }
    };
    input.addEventListener('input', handler);
    input.addEventListener('change', handler);
  };
  propertiesPanel.querySelectorAll('[data-prop]').forEach(bindPropInput);
}

function field(key, label, value) {
  return `<label>${escapeHtml(label)}<input data-prop="${escapeHtml(key)}" value="${escapeHtml(value)}" /></label>`;
}

function textareaField(key, label, value) {
  return `<label>${escapeHtml(label)}<textarea data-prop="${escapeHtml(key)}">${escapeHtml(value)}</textarea></label>`;
}

function checkboxField(key, label, checked) {
  return `<label><input data-prop="${escapeHtml(key)}" type="checkbox" ${checked ? 'checked' : ''} /> ${escapeHtml(label)}</label>`;
}

function selectField(key, label, selected, options) {
  const opts = (options || []).map(([value, text]) => {
    const sel = String(value) === String(selected) ? 'selected' : '';
    return `<option value="${escapeHtml(value)}" ${sel}>${escapeHtml(text)}</option>`;
  }).join('');
  return `<label>${escapeHtml(label)}<select data-prop="${escapeHtml(key)}">${opts}</select></label>`;
}

function passwordField(key, label, value) {
  return `<label>${escapeHtml(label)}<input data-prop="${escapeHtml(key)}" type="password" value="${escapeHtml(value)}" /></label>`;
}

function currentTopology() {
  const nodes = state.nodes.map((n) => {
    const props = { ...(n.props || {}) };
    if (n.type === 'security_group') {
      props.rules = parseRules(props.rules_text || '');
    }
    return {
      id: n.id,
      type: n.type,
      label: n.label,
      x: n.x,
      y: n.y,
      props,
    };
  });
  const edges = state.edges.map((e) => ({ from: e.from, to: e.to, type: e.type }));
  return { nodes, edges };
}

function layoutPosition(layer, index, layerGap, indexGap, startX = 60, startY = 60) {
  return { x: startX + layer * layerGap, y: startY + index * indexGap };
}

function centerLayoutInCanvas() {
  if (!state.nodes.length) return;
  const nodeW = 140;
  const nodeH = 70;
  const logicalWidth = Math.max(200, Math.round(canvas.clientWidth / state.zoom));
  const logicalHeight = Math.max(200, Math.round(canvas.clientHeight / state.zoom));

  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const n of state.nodes) {
    minX = Math.min(minX, n.x);
    minY = Math.min(minY, n.y);
    maxX = Math.max(maxX, n.x + nodeW);
    maxY = Math.max(maxY, n.y + nodeH);
  }
  const contentW = Math.max(0, maxX - minX);
  const contentH = Math.max(0, maxY - minY);
  const targetMinX = Math.max(0, (logicalWidth - contentW) / 2);
  const targetMinY = Math.max(0, (logicalHeight - contentH) / 2);
  const shiftX = targetMinX - minX;
  const shiftY = targetMinY - minY;

  for (const n of state.nodes) {
    n.x += shiftX;
    n.y += shiftY;
    n.x = Math.max(0, Math.min(logicalWidth - nodeW, n.x));
    n.y = Math.max(0, Math.min(logicalHeight - nodeH, n.y));
  }
}

function fitTopologyToCanvas() {
  if (!state.nodes.length) return;
  const nodeW = 140;
  const nodeH = 70;
  const padding = 60;
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;

  for (const n of state.nodes) {
    minX = Math.min(minX, n.x);
    minY = Math.min(minY, n.y);
    maxX = Math.max(maxX, n.x + nodeW);
    maxY = Math.max(maxY, n.y + nodeH);
  }

  const contentW = Math.max(1, maxX - minX);
  const contentH = Math.max(1, maxY - minY);
  const availableW = Math.max(120, canvas.clientWidth - padding);
  const availableH = Math.max(120, canvas.clientHeight - padding);
  const targetZoom = Math.min(1.3, availableW / contentW, availableH / contentH);
  state.zoom = Math.max(0.45, Math.min(2, Math.round(targetZoom * 100) / 100));
}

function applySimpleAutoLayout(options = {}) {
  const autoFit = Boolean(options.autoFit);
  const typeOrder = ['network', 'subnet', 'router', 'load_balancer', 'instance', 'volume', 'security_group'];
  const columnByType = new Map(typeOrder.map((t, i) => [t, i]));
  const grouped = new Map(typeOrder.map((t) => [t, []]));

  for (const n of state.nodes) {
    const key = grouped.has(n.type) ? n.type : 'instance';
    grouped.get(key).push(n);
  }

  for (const [type, list] of grouped.entries()) {
    list.sort((a, b) => nodeDisplayName(a).localeCompare(nodeDisplayName(b)));
    const col = columnByType.get(type) ?? 0;
    for (let i = 0; i < list.length; i += 1) {
      const pos = layoutPosition(col, i, 170, 90);
      list[i].x = pos.x;
      list[i].y = pos.y;
    }
  }

  // Pull volumes closer to attached instances for readability.
  for (const edge of state.edges) {
    const a = state.nodes.find((n) => n.id === edge.from);
    const b = state.nodes.find((n) => n.id === edge.to);
    if (!a || !b) continue;
    const isAttach = edge.type === 'attach' || edge.type === 'boot';
    if (!isAttach) continue;
    const vol = a.type === 'volume' ? a : (b.type === 'volume' ? b : null);
    const inst = a.type === 'instance' ? a : (b.type === 'instance' ? b : null);
    if (!vol || !inst) continue;
    vol.x = Math.min(vol.x, inst.x + 150);
    vol.y = inst.y;
  }

  if (autoFit) fitTopologyToCanvas();
  centerLayoutInCanvas();
  render();
  log('Applied simple auto layout.');
}

function applySmartAutoLayout(options = {}) {
  const autoFit = Boolean(options.autoFit);
  if (!state.nodes.length) {
    render();
    return;
  }

  const preferredLayerByType = new Map([
    ['network', 0],
    ['subnet', 1],
    ['router', 2],
    ['load_balancer', 3],
    ['instance', 4],
    ['security_group', 5],
    ['volume', 6],
  ]);

  const nodeById = new Map(state.nodes.map((n) => [n.id, n]));
  const neighbors = new Map(state.nodes.map((n) => [n.id, new Set()]));
  for (const e of state.edges) {
    if (!neighbors.has(e.from) || !neighbors.has(e.to)) continue;
    neighbors.get(e.from).add(e.to);
    neighbors.get(e.to).add(e.from);
  }

  const layerById = new Map();
  for (const n of state.nodes) {
    const base = preferredLayerByType.get(n.type) ?? 4;
    layerById.set(n.id, base);
  }

  for (let pass = 0; pass < 6; pass += 1) {
    for (const n of state.nodes) {
      const base = preferredLayerByType.get(n.type) ?? 4;
      const neigh = [...(neighbors.get(n.id) || [])].map((id) => layerById.get(id)).filter((v) => typeof v === 'number');
      if (!neigh.length) continue;
      const avg = neigh.reduce((a, b) => a + b, 0) / neigh.length;
      const desired = Math.round((base * 0.6) + (avg * 0.4));
      layerById.set(n.id, Math.max(0, Math.min(8, desired)));
    }
  }

  const layers = new Map();
  for (const n of state.nodes) {
    const layer = layerById.get(n.id) ?? 0;
    if (!layers.has(layer)) layers.set(layer, []);
    layers.get(layer).push(n);
  }

  const sortedLayerKeys = [...layers.keys()].sort((a, b) => a - b);
  const instanceLbGroupById = new Map();
  for (const n of state.nodes) {
    if (n.type !== 'instance') continue;
    const lbNames = [];
    for (const e of state.edges) {
      if (e.type !== 'member') continue;
      const peerId = e.from === n.id ? e.to : (e.to === n.id ? e.from : '');
      if (!peerId) continue;
      const peer = nodeById.get(peerId);
      if (!peer || peer.type !== 'load_balancer') continue;
      lbNames.push(nodeDisplayName(peer));
    }
    lbNames.sort((a, b) => a.localeCompare(b));
    instanceLbGroupById.set(n.id, lbNames.join('|'));
  }

  const rankById = new Map();
  for (const layer of sortedLayerKeys) {
    const arr = layers.get(layer);
    arr.sort((a, b) => {
      if (a.type === 'instance' && b.type === 'instance') {
        const aGroup = instanceLbGroupById.get(a.id) || '';
        const bGroup = instanceLbGroupById.get(b.id) || '';
        const aGrouped = aGroup ? 0 : 1;
        const bGrouped = bGroup ? 0 : 1;
        if (aGrouped !== bGrouped) return aGrouped - bGrouped;
        if (aGroup !== bGroup) return aGroup.localeCompare(bGroup);
      }
      return nodeDisplayName(a).localeCompare(nodeDisplayName(b));
    });
    arr.forEach((n, i) => rankById.set(n.id, i));
  }

  // Barycenter ordering passes to reduce edge crossings.
  for (let iter = 0; iter < 4; iter += 1) {
    for (const layer of sortedLayerKeys) {
      const arr = layers.get(layer);
      arr.sort((a, b) => {
        if (a.type === 'instance' && b.type === 'instance') {
          const aGroup = instanceLbGroupById.get(a.id) || '';
          const bGroup = instanceLbGroupById.get(b.id) || '';
          const aGrouped = aGroup ? 0 : 1;
          const bGrouped = bGroup ? 0 : 1;
          if (aGrouped !== bGrouped) return aGrouped - bGrouped;
          if (aGroup !== bGroup) return aGroup.localeCompare(bGroup);
        }
        const aNeigh = [...(neighbors.get(a.id) || [])];
        const bNeigh = [...(neighbors.get(b.id) || [])];
        const aAvg = aNeigh.length ? aNeigh.reduce((sum, id) => sum + (rankById.get(id) ?? 0), 0) / aNeigh.length : (rankById.get(a.id) ?? 0);
        const bAvg = bNeigh.length ? bNeigh.reduce((sum, id) => sum + (rankById.get(id) ?? 0), 0) / bNeigh.length : (rankById.get(b.id) ?? 0);
        if (aAvg !== bAvg) return aAvg - bAvg;
        return nodeDisplayName(a).localeCompare(nodeDisplayName(b));
      });
      arr.forEach((n, i) => rankById.set(n.id, i));
    }
  }

  const xStart = 50;
  const yStart = 50;
  const layerGap = 180;
  const indexGap = 90;

  for (const layer of sortedLayerKeys) {
    const arr = layers.get(layer);
    let runningOffset = 0;
    let prevInstanceGroup = '';
    let prevWasInstance = false;
    for (let i = 0; i < arr.length; i += 1) {
      const node = arr[i];
      if (i > 0) {
        if (node.type === 'instance') {
          const group = instanceLbGroupById.get(node.id) || '';
          if (prevWasInstance) {
            if (group && group === prevInstanceGroup) runningOffset += 84;
            else if (!group && !prevInstanceGroup) runningOffset += 180;
            else runningOffset += 140;
          } else {
            runningOffset += 120;
          }
          prevInstanceGroup = group;
          prevWasInstance = true;
        } else {
          runningOffset += indexGap;
          prevWasInstance = false;
          prevInstanceGroup = '';
        }
      } else {
        prevWasInstance = node.type === 'instance';
        prevInstanceGroup = prevWasInstance ? (instanceLbGroupById.get(node.id) || '') : '';
      }

      const virtualIndex = runningOffset / indexGap;
      const pos = layoutPosition(layer, virtualIndex, layerGap, indexGap, xStart, yStart);
      node.x = pos.x;
      node.y = pos.y;
    }
  }

  // Relationship-aware nudges for readability.
  for (const e of state.edges) {
    const a = nodeById.get(e.from);
    const b = nodeById.get(e.to);
    if (!a || !b) continue;
    if (e.type === 'attach' || e.type === 'boot') {
      const vol = a.type === 'volume' ? a : (b.type === 'volume' ? b : null);
      const inst = a.type === 'instance' ? a : (b.type === 'instance' ? b : null);
      if (vol && inst) {
        vol.x = Math.max(vol.x, inst.x + 150);
        vol.y = inst.y;
      }
    }
    if (e.type === 'member') {
      const lb = a.type === 'load_balancer' ? a : (b.type === 'load_balancer' ? b : null);
      const inst = a.type === 'instance' ? a : (b.type === 'instance' ? b : null);
      if (lb && inst) {
        lb.x = Math.min(lb.x, inst.x - 150);
      }
    }
  }

  // Clamp to canvas bounds.
  const logicalWidth = Math.max(200, Math.round(canvas.clientWidth / state.zoom));
  const logicalHeight = Math.max(200, Math.round(canvas.clientHeight / state.zoom));
  for (const n of state.nodes) {
    n.x = Math.max(0, Math.min(logicalWidth - 140, n.x));
    n.y = Math.max(0, Math.min(logicalHeight - 70, n.y));
  }

  if (autoFit) fitTopologyToCanvas();
  centerLayoutInCanvas();
  render();
  log('Applied smart auto layout.');
}

async function apiGet(url) {
  const res = await fetch(url);
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || `GET ${url} failed`);
  return data;
}

async function apiPost(url, payload) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload || {}),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || `POST ${url} failed`);
  return data;
}

async function uploadDeploymentScriptFile() {
  const input = document.getElementById('scriptUploadFile');
  const file = input?.files?.[0];
  if (!file) {
    log('Choose a deployment script file first.');
    return;
  }
  const form = new FormData();
  form.append('file', file);
  const res = await fetch('/api/upload', { method: 'POST', body: form });
  const data = await res.json();
  if (!res.ok || !data.ok) throw new Error(data.error || 'Upload failed');
  const scriptFile = document.getElementById('scriptFile');
  const savedAs = data.saved_as || file.name;
  if (scriptFile) scriptFile.value = savedAs;
  localStorage.setItem('designer_last_deploy_script', savedAs);
  log(`Uploaded deployment script: ${savedAs}`);
}

async function refreshTopologies() {
  const data = await apiGet('/api/topology/list');
  const prev = topologySelect.value;
  topologySelect.innerHTML = '<option value="">-- select --</option>';
  for (const file of data.files || []) {
    const opt = document.createElement('option');
    opt.value = file;
    opt.textContent = file;
    topologySelect.appendChild(opt);
  }
  if ([...topologySelect.options].some(o => o.value === prev)) topologySelect.value = prev;
}

async function refreshOpenrcFiles() {
  if (!openrcSelect) return;
  const data = await apiGet('/api/topology/openrc-files');
  const previous = openrcSelect.value;
  const cached = localStorage.getItem('designer_last_good_openrc') || '';
  openrcSelect.innerHTML = '<option value="">-- select detected OpenRC --</option>';
  for (const file of data.files || []) {
    const opt = document.createElement('option');
    opt.value = file;
    opt.textContent = file;
    openrcSelect.appendChild(opt);
  }
  if (cached && [...openrcSelect.options].some((o) => o.value === cached)) {
    openrcSelect.value = cached;
    if (openrcFileInput) openrcFileInput.value = cached;
  } else if ([...openrcSelect.options].some((o) => o.value === previous)) {
    openrcSelect.value = previous;
    if (openrcFileInput && previous) openrcFileInput.value = previous;
  } else if ([...openrcSelect.options].some((o) => o.value === DEFAULT_OPENRC_FILE)) {
    openrcSelect.value = DEFAULT_OPENRC_FILE;
    if (openrcFileInput) openrcFileInput.value = DEFAULT_OPENRC_FILE;
  } else if (openrcFileInput && !openrcFileInput.value.trim()) {
    openrcFileInput.value = DEFAULT_OPENRC_FILE;
  }
}

function timestampForScriptName() {
  const d = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}_${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

function buildTopologyScriptName() {
  const rawAccountId = (document.getElementById('scriptAccountId')?.value || '').trim();
  const accountId = rawAccountId.replace(/[^0-9a-zA-Z_-]/g, '') || 'account';
  const mode = currentInfraSourceMode();
  const tag = INFRA_SOURCE_MODES[mode]?.filenameTag || 'topology';
  return `${accountId}_${tag}_topology_deploy_${timestampForScriptName()}.sh`;
}

function renderValidation(data) {
  const summary = data?.validation_summary || { ERROR: 0, WARN: 0, INFO: 0 };
  const findings = Array.isArray(data?.validation_findings) ? data.validation_findings : [];
  const head = [
    `ok=${summary.ERROR === 0}`,
    `errors=${summary.ERROR || 0}`,
    `warnings=${summary.WARN || 0}`,
    `info=${summary.INFO || 0}`,
  ].join(' | ');
  const lines = [head];
  for (const f of findings) {
    lines.push(`[${f.severity}] ${f.code} :: ${f.scope} :: ${f.message}`);
  }
  validationPreview.textContent = lines.join('\n');
}

function renderPlan(actions) {
  if (!Array.isArray(actions) || !actions.length) {
    planPreview.textContent = 'No planned actions.';
    return;
  }
  const lines = actions.map((a) =>
    `${a.step}. [${a.resource}] ${a.name} :: ${a.action}\n   ${a.command}`
  );
  planPreview.textContent = lines.join('\n');
}

canvas.addEventListener('click', () => {
  if (state.suppressCanvasClick) {
    state.suppressCanvasClick = false;
    return;
  }
  if (!state.connectMode) {
    state.selectedNodeId = null;
    state.selectedNodeIds = [];
    render();
  }
});

canvas.addEventListener('mousedown', (ev) => {
  if (ev.button !== 0) return;
  if (state.connectMode) return;
  state.panDrag = {
    startX: ev.clientX,
    startY: ev.clientY,
    originX: state.panX,
    originY: state.panY,
  };
});

document.addEventListener('mousemove', (ev) => {
  if (state.drag) {
    const node = state.nodes.find(n => n.id === state.drag.id);
    if (!node) return;
    const rect = canvas.getBoundingClientRect();
    const logicalWidth = canvas.clientWidth / state.zoom;
    const logicalHeight = canvas.clientHeight / state.zoom;
    const logicalX = (ev.clientX - rect.left - state.panX) / state.zoom;
    const logicalY = (ev.clientY - rect.top - state.panY) / state.zoom;
    node.x = Math.max(0, Math.min(logicalWidth - 140, logicalX - state.drag.offsetX));
    node.y = Math.max(0, Math.min(logicalHeight - 70, logicalY - state.drag.offsetY));
    render();
    return;
  }
  if (state.panDrag) {
    const dx = ev.clientX - state.panDrag.startX;
    const dy = ev.clientY - state.panDrag.startY;
    state.panX = state.panDrag.originX + dx;
    state.panY = state.panDrag.originY + dy;
    if (Math.abs(dx) > 2 || Math.abs(dy) > 2) {
      state.suppressCanvasClick = true;
    }
    renderEdges();
  }
});

document.addEventListener('mouseup', () => {
  state.drag = null;
  state.panDrag = null;
});

document.querySelectorAll('[data-add]').forEach((btn) => {
  btn.addEventListener('click', () => addNode(btn.getAttribute('data-add')));
});

connectModeBtn.addEventListener('click', () => {
  state.connectMode = !state.connectMode;
  state.connectFrom = null;
  connectModeBtn.classList.toggle('active', state.connectMode);
  connectModeBtn.textContent = state.connectMode ? 'Connecting (Click Nodes)' : 'Connect Nodes';
});

document.getElementById('deleteNodeBtn').addEventListener('click', deleteSelectedNode);
document.getElementById('disconnectBtn').addEventListener('click', disconnectSelectedNodes);

document.getElementById('clearBtn').addEventListener('click', () => {
  state.nodes = [];
  state.edges = [];
  state.selectedNodeId = null;
  state.selectedNodeIds = [];
  render();
});

document.getElementById('zoomInBtn').addEventListener('click', () => {
  state.zoom = Math.min(2, Math.round((state.zoom + 0.1) * 10) / 10);
  renderEdges();
});

document.getElementById('zoomOutBtn').addEventListener('click', () => {
  state.zoom = Math.max(0.5, Math.round((state.zoom - 0.1) * 10) / 10);
  renderEdges();
});

document.getElementById('zoomResetBtn').addEventListener('click', () => {
  state.zoom = 1;
  renderEdges();
});

document.getElementById('autoLayoutBtn').addEventListener('click', () => {
  applySimpleAutoLayout({ autoFit: false });
});

document.getElementById('smartLayoutBtn').addEventListener('click', () => {
  applySmartAutoLayout({ autoFit: false });
});

document.getElementById('saveTopologyBtn').addEventListener('click', async () => {
  const name = document.getElementById('topologyName').value.trim();
  if (!name) {
    log('Provide a topology name first.');
    return;
  }
  try {
    const data = await apiPost('/api/topology/save', { name, topology: currentTopology() });
    log(`Saved: ${data.saved_as}`);
    await refreshTopologies();
  } catch (e) {
    log(`Save failed: ${e.message}`);
  }
});

if (openrcSelect) {
  openrcSelect.addEventListener('change', () => {
    if (!openrcFileInput) return;
    const selected = (openrcSelect.value || '').trim();
    if (!selected) return;
    openrcFileInput.value = selected;
    log(`OpenRC file selected: ${selected}`);
  });
}

document.getElementById('refreshOpenrcBtn')?.addEventListener('click', async () => {
  try {
    await refreshOpenrcFiles();
    log('Refreshed OpenRC file list.');
  } catch (e) {
    log(`OpenRC list refresh failed: ${e.message}`);
  }
});

document.getElementById('loadTopologyBtn').addEventListener('click', async () => {
  const file = topologySelect.value;
  if (!file) {
    log('Select a saved topology first.');
    return;
  }
  try {
    const data = await apiGet(`/api/topology/load?file=${encodeURIComponent(file)}`);
    state.nodes = Array.isArray(data.topology?.nodes) ? data.topology.nodes : [];
    state.edges = Array.isArray(data.topology?.edges) ? data.topology.edges : [];
    state.selectedNodeId = null;
    state.selectedNodeIds = [];
    render();
    log(`Loaded topology: ${file}`);
  } catch (e) {
    log(`Load failed: ${e.message}`);
  }
});

document.getElementById('generateScriptBtn').addEventListener('click', async () => {
  try {
    const phases = [];
    if (document.getElementById('phaseNet')?.checked)        phases.push("net");
    if (document.getElementById('phaseLbScaffold')?.checked) phases.push("lb_scaffold");
    if (document.getElementById('phaseVolCreate')?.checked)  phases.push("vol_create");
    if (document.getElementById('phaseVm')?.checked)         phases.push("vm");
    if (document.getElementById('phaseVolAttach')?.checked)  phases.push("vol_attach");
    if (document.getElementById('phaseLbMembers')?.checked)  phases.push("lb_members");

    const data = await apiPost('/api/topology/generate-script', {
      topology: currentTopology(),
      script_name: buildTopologyScriptName(),
      phases: phases,
    });
    scriptPreview.textContent = data.script_content || '';
    log(`Generated script: ${data.script_path} (nodes=${data.node_count}, edges=${data.edge_count})`);
  } catch (e) {
    log(`Generate failed: ${e.message}`);
  }
});

document.getElementById('validateBtn').addEventListener('click', async () => {
  try {
    const data = await apiPost('/api/topology/validate', {
      topology: currentTopology(),
    });
    renderValidation(data);
    log(`Validation complete: ok=${data.ok}`);
  } catch (e) {
    log(`Validation failed: ${e.message}`);
  }
});

document.getElementById('planBtn').addEventListener('click', async () => {
  try {
    const data = await apiPost('/api/topology/plan', {
      topology: currentTopology(),
    });
    renderValidation(data);
    renderPlan(data.planned_actions || []);
    scriptPreview.textContent = data.script_preview || '';
    log(`Plan generated: actions=${(data.planned_actions || []).length} ok=${data.ok}`);
  } catch (e) {
    log(`Plan failed: ${e.message}`);
  }
});

document.getElementById('importLiveBtn').addEventListener('click', async () => {
  await withButtonBusy('importLiveBtn', 'Import from project', async () => {
    try {
      const data = await apiPost('/api/topology/import-live', {
        openrc_file: document.getElementById('openrcFile').value,
        openrc_content: getOpenrcContentValue(),
        auth_secret: document.getElementById('authSecret').value,
      });
      state.nodes = Array.isArray(data.topology?.nodes) ? data.topology.nodes : [];
      state.edges = Array.isArray(data.topology?.edges) ? data.topology.edges : [];
      state.selectedNodeId = null;
      state.selectedNodeIds = [];
      applySmartAutoLayout({ autoFit: true });
      log(`Imported live topology: nodes=${data.node_count} edges=${data.edge_count}`);
    } catch (e) {
      log(`Import failed: ${e.message}`);
    }
  });
});

document.getElementById('importScriptBtn').addEventListener('click', async () => {
  await withButtonBusy('importScriptBtn', 'Import from script', async () => {
    try {
      const data = await apiPost('/api/topology/import-script', {
        script_file: document.getElementById('scriptFile').value,
        script_content: document.getElementById('scriptContent').value,
      });
      const usedScript = (document.getElementById('scriptFile')?.value || '').trim();
      if (usedScript) localStorage.setItem('designer_last_deploy_script', usedScript);
      state.nodes = Array.isArray(data.topology?.nodes) ? data.topology.nodes : [];
      state.edges = Array.isArray(data.topology?.edges) ? data.topology.edges : [];
      state.selectedNodeId = null;
      state.selectedNodeIds = [];
      applySmartAutoLayout({ autoFit: true });
      const notes = Array.isArray(data.parse_notes) ? data.parse_notes.join(' | ') : '';
      log(`Imported script topology: nodes=${data.node_count} edges=${data.edge_count}${notes ? ` | ${notes}` : ''}`);
    } catch (e) {
      log(`Script import failed: ${e.message}`);
    }
  });
});

document.getElementById('scriptUploadFile')?.addEventListener('change', async () => {
  try {
    await uploadDeploymentScriptFile();
  } catch (e) {
    log(`Script upload failed: ${e.message}`);
  }
});

document.getElementById('uploadScriptBtn')?.addEventListener('click', async () => {
  try {
    await uploadDeploymentScriptFile();
  } catch (e) {
    log(`Script upload failed: ${e.message}`);
  }
});

// ── Track current deploy job so Stop can kill it ─────────────────────────────
let currentDeployJobId = null;

const stopDeployBtn  = document.getElementById('stopDeployBtn');
const rollbackBtn    = document.getElementById('rollbackBtn');

function setDeployRunning(running) {
  const deployBtn = document.getElementById('deployBtn');
  if (running) {
    if (stopDeployBtn) stopDeployBtn.style.display = '';
    if (deployBtn) deployBtn.disabled = true;
    if (rollbackBtn) rollbackBtn.disabled = true;
  } else {
    if (stopDeployBtn) stopDeployBtn.style.display = 'none';
    if (deployBtn) deployBtn.disabled = false;
    if (rollbackBtn) rollbackBtn.disabled = false;
  }
}

document.getElementById('deployBtn').addEventListener('click', async () => {
  await withButtonBusy('deployBtn', 'Deploy topology', async () => {
    log('Submitting topology deploy request...');
    try {
      const phases = [];
      if (document.getElementById('phaseNet')?.checked)       phases.push("net");
      if (document.getElementById('phaseLbScaffold')?.checked) phases.push("lb_scaffold");
      if (document.getElementById('phaseVolCreate')?.checked)  phases.push("vol_create");
      if (document.getElementById('phaseVm')?.checked)         phases.push("vm");
      if (document.getElementById('phaseVolAttach')?.checked)  phases.push("vol_attach");
      if (document.getElementById('phaseLbMembers')?.checked)  phases.push("lb_members");

      const data = await apiPost('/api/topology/deploy-async', {
        topology: currentTopology(),
        script_name: buildTopologyScriptName(),
        script_file: document.getElementById('scriptFile')?.value || '',
        script_content: document.getElementById('scriptContent')?.value || '',
        openrc_file: document.getElementById('openrcFile').value,
        openrc_content: getOpenrcContentValue(),
        auth_secret: document.getElementById('authSecret').value,
        fail_fast: document.getElementById('failFast').checked,
        phases: phases,
      });
      scriptPreview.textContent = data.script_content || scriptPreview.textContent;
      const jobId = (data.job_id || '').trim();
      if (!jobId) {
        throw new Error('Deploy job did not return a job_id.');
      }
      currentDeployJobId = jobId;
      setDeployRunning(true);
      log(`Deploy job started: ${jobId}`);

      let seen = 0;
      let finished = false;
      const startTs = Date.now();
      while (!finished) {
        await new Promise((resolve) => setTimeout(resolve, 1200));
        const status = await apiGet(`/api/topology/deploy-status?job_id=${encodeURIComponent(jobId)}`);
        const fullLog = String(status.log || '');
        if (fullLog.length > seen) {
          appendRawLog(fullLog.slice(seen));
          seen = fullLog.length;
        }
        if (status.complete) {
          finished = true;
          if (status.ok) {
            const usedOpenrc = (document.getElementById('openrcFile')?.value || '').trim();
            if (usedOpenrc) localStorage.setItem('designer_last_good_openrc', usedOpenrc);
          }
          log(`Deploy complete: ok=${status.ok} rc=${status.return_code} script=${status.script_path || data.script_path}`);
          break;
        }
        if ((Date.now() - startTs) > (120 * 60 * 1000)) {
          throw new Error('Timed out waiting for deploy status updates.');
        }
      }
    } catch (e) {
      log(`Deploy failed: ${e.message}`);
    } finally {
      setDeployRunning(false);
      setActiveDeployPhase('');
      currentDeployJobId = null;
    }
  });
});

// ── Stop Deployment ───────────────────────────────────────────────────────────
if (stopDeployBtn) {
  stopDeployBtn.addEventListener('click', async () => {
    if (!currentDeployJobId) {
      log('No active deployment to stop.');
      return;
    }
    if (!confirm('⏹ Stop the running deployment now?\n\nIn-flight OpenStack API calls may complete, but no new resources will be created.')) return;
    try {
      stopDeployBtn.disabled = true;
      stopDeployBtn.textContent = 'Stopping…';
      const data = await apiPost('/api/topology/stop-deploy', { job_id: currentDeployJobId });
      if (data.ok) {
        log(`[STOP] ${data.message || 'Deployment stopped by user.'}`);
      } else {
        log(`[STOP] Failed: ${data.error}`);
      }
    } catch (e) {
      log(`[STOP] Error: ${e.message}`);
    } finally {
      stopDeployBtn.textContent = '⏹ Stop Deployment';
      stopDeployBtn.disabled = false;
    }
  });
}

// ── Rollback Modal ────────────────────────────────────────────────────────────
function showRollbackModal(onConfirm) {
  const modal = document.getElementById('rollbackModal');
  const scriptLabel = document.getElementById('rollbackModalScriptName');
  if (!modal) { onConfirm(); return; }  // fallback: run immediately

  // Try to show what rollback script will be used
  fetch('/api/topology/latest-rollback-name')
    .then(r => r.ok ? r.json() : {})
    .then(d => {
      if (scriptLabel) scriptLabel.textContent = d.name
        ? `Script to run: ${d.name}  (${d.steps || '?'} delete steps)`
        : 'No rollback script found yet — run a deployment first.';
      const lbl = document.getElementById('lastRollbackLabel');
      if (lbl && d.name) lbl.textContent = `Last rollback script: ${d.name}`;
    }).catch(() => {});

  modal.style.display = 'flex';
  document.body.style.overflow = 'hidden';

  const doConfirm = () => { hideRollbackModal(); onConfirm(); };
  const doCancel  = () => hideRollbackModal();

  document.getElementById('rollbackModalConfirm').onclick = doConfirm;
  document.getElementById('rollbackModalCancel').onclick  = doCancel;
  modal.onclick = (e) => { if (e.target === modal) doCancel(); };
}
function hideRollbackModal() {
  const modal = document.getElementById('rollbackModal');
  if (modal) modal.style.display = 'none';
  document.body.style.overflow = '';
}
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') hideRollbackModal();
});

// ── Roll Back ─────────────────────────────────────────────────────────────────
async function executeRollback() {
  await withButtonBusy('rollbackBtn', 'Rollback', async () => {
    log('Starting rollback of last deployment...');
    try {
      const data = await apiPost('/api/topology/rollback', {
        openrc_file: document.getElementById('openrcFile').value,
        openrc_content: getOpenrcContentValue(),
        auth_secret: document.getElementById('authSecret').value,
      });
      if (!data.ok) throw new Error(data.error || 'Rollback request failed.');
      const jobId = data.job_id;
      log(`Rollback job started: ${jobId}  (script: ${data.rollback_script})`);
      const lbl = document.getElementById('lastRollbackLabel');
      if (lbl) lbl.textContent = `Last rollback script: ${data.rollback_script}`;

      let seen = 0;
      const startTs = Date.now();
      while (true) {
        await new Promise(r => setTimeout(r, 1200));
        const status = await apiGet(`/api/topology/deploy-status?job_id=${encodeURIComponent(jobId)}`);
        const fullLog = String(status.log || '');
        if (fullLog.length > seen) { appendRawLog(fullLog.slice(seen)); seen = fullLog.length; }
        if (status.complete) {
          log(`Rollback complete: ok=${status.ok}  rc=${status.return_code}`);
          break;
        }
        if ((Date.now() - startTs) > (60 * 60 * 1000)) {
          throw new Error('Rollback timed out after 60 minutes.');
        }
      }
    } catch (e) {
      log(`Rollback failed: ${e.message}`);
    }
  });
}

if (rollbackBtn) {
  rollbackBtn.addEventListener('click', () => showRollbackModal(executeRollback));
}

// ── Phase Select All / None ───────────────────────────────────────────────────
const PHASE_IDS = ['phaseNet','phaseLbScaffold','phaseVolCreate','phaseVm','phaseVolAttach','phaseLbMembers'];
const DEPLOY_PHASE_BY_NUMBER = {
  1: 'phaseNet',
  2: 'phaseLbScaffold',
  3: 'phaseVolCreate',
  4: 'phaseVm',
  5: 'phaseVolAttach',
  6: 'phaseLbMembers',
};

function setActiveDeployPhase(phaseId) {
  PHASE_IDS.forEach((id) => {
    const input = document.getElementById(id);
    input?.closest('label')?.classList.toggle('phase-active', id === phaseId);
  });
}

function updateActiveDeployPhaseFromText(text) {
  const chunk = String(text || '');
  const matches = [...chunk.matchAll(/PHASE\s+([1-6])\b/gi)];
  if (matches.length) {
    const phaseNumber = Number(matches[matches.length - 1][1]);
    setActiveDeployPhase(DEPLOY_PHASE_BY_NUMBER[phaseNumber] || '');
    return;
  }
  if (/Ensuring tenant network resources|network create|subnet create|router create/i.test(chunk)) setActiveDeployPhase('phaseNet');
  else if (/loadbalancer create|listener create|pool create/i.test(chunk)) setActiveDeployPhase('phaseLbScaffold');
  else if (/volume create/i.test(chunk)) setActiveDeployPhase('phaseVolCreate');
  else if (/Executing deployment steps|Creating server|server create/i.test(chunk)) setActiveDeployPhase('phaseVm');
  else if (/volume attach|Attaching volume/i.test(chunk)) setActiveDeployPhase('phaseVolAttach');
  else if (/member create|LB member|pool member/i.test(chunk)) setActiveDeployPhase('phaseLbMembers');
}

document.getElementById('phaseSelectAll')?.addEventListener('click', () => {
  PHASE_IDS.forEach(id => { const el = document.getElementById(id); if (el) el.checked = true; });
});
document.getElementById('phaseSelectNone')?.addEventListener('click', () => {
  PHASE_IDS.forEach(id => { const el = document.getElementById(id); if (el) el.checked = false; });
});

refreshTopologies().catch((e) => log(`Topology list load failed: ${e.message}`));
refreshOpenrcFiles().catch((e) => log(`OpenRC list load failed: ${e.message}`));
if (openrcFileInput && !openrcFileInput.value.trim()) {
  openrcFileInput.value = DEFAULT_OPENRC_FILE;
}
if (scriptFileInput) {
  const cachedScript = localStorage.getItem('designer_last_deploy_script') || '';
  if (cachedScript || !scriptFileInput.value.trim() || scriptFileInput.value === DEFAULT_DEPLOY_SCRIPT_FILE) {
    scriptFileInput.value = cachedScript || DEFAULT_DEPLOY_SCRIPT_FILE;
  }
}
const infraSourceModeSelect = document.getElementById('infraSourceMode');
if (infraSourceModeSelect) {
  infraSourceModeSelect.addEventListener('change', () => applyInfraSourceMode(infraSourceModeSelect.value));
}
applyInfraSourceMode(currentInfraSourceMode());
const canvasResizeObserver = new ResizeObserver(() => renderEdges());
canvasResizeObserver.observe(canvas);
window.addEventListener('resize', () => renderEdges());
render();
