/* OpenCenter Deployment Live Monitor — SSE-driven, read-only. */
(function () {
  'use strict';
  var body = document.body;
  var ORG = body.dataset.org, CLUSTER = body.dataset.cluster;
  var API = '/api/monitoring/deployment/' + ORG + '/' + CLUSTER;
  var MAX_LINES = 5000;
  var paused = false, es = null, lastSnapshot = null;
  var logEl = document.getElementById('mon-log');
  var allLines = [];

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  // ---------------------------------------------------------------- header
  document.getElementById('mon-open-cluster').href =
    '/opencenter/monitor/cluster/' + ORG + '/' + CLUSTER;

  fetch('/api/monitoring/clusters').then(function (r) { return r.json(); }).then(function (d) {
    var sel = $('mon-cluster-select');
    (d.pairs || []).forEach(function (p) {
      var opt = document.createElement('option');
      opt.value = p.org + '/' + p.cluster;
      opt.textContent = p.org + '/' + p.cluster;
      if (p.org === ORG && p.cluster === CLUSTER) opt.selected = true;
      sel.appendChild(opt);
    });
    sel.onchange = function () {
      location.href = '/opencenter/monitor/deployment/' + sel.value;
    };
  });

  // ------------------------------------------------------------- log panel
  function lineClass(line) {
    if (/\[BLOCKED\]|error|✗|fatal|failed/i.test(line)) return 'l-err';
    if (/warn/i.test(line)) return 'l-warn';
    if (/✓|complete|passed|succeeded|ok=/i.test(line)) return 'l-ok';
    if (/^\s*#|Refreshing state|Reading\.\.\./.test(line)) return 'l-dim';
    return '';
  }
  function lineTags(line) {
    var tags = [];
    if (/tofu|terraform|module\.|Creating|Creation complete|Still creating/i.test(line)) tags.push('tofu');
    if (/ansible|TASK \[|PLAY |ok=|kubespray/i.test(line)) tags.push('ansible');
    if (/kubectl|kubernetes|kubelet|node|pod/i.test(line)) tags.push('k8s');
    if (/flux|kustomization|helmrelease|gitrepository|calico|helm /i.test(line)) tags.push('flux');
    if (/error|✗|fatal|\[BLOCKED\]/i.test(line)) tags.push('error');
    else if (/warn/i.test(line)) tags.push('warning');
    else if (/step (started|completed)|→|✓|\[\d+\/\d+\]/.test(line)) tags.push('progress');
    return tags;
  }
  function appendLog(line) {
    allLines.push(line);
    if (allLines.length > MAX_LINES) allLines.splice(0, allLines.length - MAX_LINES);
    var filter = $('mon-log-filter').value;
    var search = $('mon-log-search').value.toLowerCase();
    var tags = lineTags(line);
    if (filter !== 'all' && tags.indexOf(filter) === -1) return;
    if (search && line.toLowerCase().indexOf(search) === -1) return;
    var div = document.createElement('div');
    div.className = lineClass(line);
    div.textContent = line;
    logEl.appendChild(div);
    while (logEl.childNodes.length > MAX_LINES) logEl.removeChild(logEl.firstChild);
    if (!paused) logEl.scrollTop = logEl.scrollHeight;
  }
  function rerenderLog() {
    logEl.innerHTML = '';
    var keep = allLines;
    allLines = [];
    keep.forEach(appendLog);
    allLines = keep;
  }
  $('mon-log-filter').onchange = rerenderLog;
  $('mon-log-search').oninput = rerenderLog;
  $('mon-log-download').onclick = function () {
    var blob = new Blob([allLines.join('\n')], { type: 'text/plain' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'deployment-' + ORG + '-' + CLUSTER + '.log';
    a.click();
  };
  $('mon-log-copy').onclick = function () {
    navigator.clipboard.writeText(logEl.textContent || '');
  };
  $('mon-pause').onclick = function () {
    paused = !paused;
    this.textContent = paused ? '▶ Resume' : '⏸ Pause';
    $('mon-pulse').className = 'mon-pulse' + (paused ? ' paused' : '');
  };
  $('mon-diag').onclick = function () {
    if (!lastSnapshot) return;
    var bundle = { snapshot: lastSnapshot, tail: allLines.slice(-300) };
    navigator.clipboard.writeText(JSON.stringify(bundle, null, 2));
    this.textContent = '✓ Copied';
    var self = this;
    setTimeout(function () { self.textContent = '📋 Copy diagnostic bundle'; }, 1500);
  };

  // ------------------------------------------------------------- rendering
  function badge(id, text, cls) {
    var el = $(id);
    el.textContent = text;
    el.className = 'mon-badge ' + (cls || '');
  }
  function fmtElapsed(sec) {
    sec = Math.floor(sec || 0);
    if (!sec) return '—';
    var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    return (h ? h + 'h' : '') + (m ? m + 'm' : '') + s + 's';
  }
  var STATUS_CLS = { RUNNING: 'run', SUCCEEDED: 'ok', FAILED: 'err', BLOCKED: 'err', WAITING: 'warn', IDLE: '' };

  function renderStages(snap) {
    var wrap = $('mon-pipeline');
    wrap.innerHTML = '';
    (snap.stages || []).forEach(function (st) {
      var div = document.createElement('div');
      div.className = 'mon-stage ' + st.status;
      div.innerHTML = '<div class="name">' + esc(st.title) + '</div>' +
        '<div class="st">' + esc(st.status) + '</div>' +
        (st.duration ? '<div class="dur">' + esc(st.duration) + '</div>' : '');
      div.onclick = function () {
        var det = $('mon-stage-detail');
        var text = st.title + ' — ' + st.status +
          (st.started_at ? '\nstarted: ' + st.started_at : '') +
          (st.duration ? '\nduration: ' + st.duration : '') +
          (st.message ? '\n' + st.message : '') +
          (st.recommendation ? '\nrecommendation: ' + st.recommendation : '');
        if (det.style.display === 'block' && det.dataset.stage === st.id) {
          det.style.display = 'none';
        } else {
          det.textContent = text;
          det.dataset.stage = st.id;
          det.style.display = 'block';
        }
      };
      wrap.appendChild(div);
    });
    $('mon-active-step').textContent = snap.active_step ? '▶ ' + snap.active_step : '';
  }

  function renderProc(snap) {
    var el = $('mon-proc');
    if (!snap.deployment_pid) {
      el.innerHTML = '<div class="mon-empty">no deployment process detected</div>';
      return;
    }
    var html = '<dl class="mon-kv">' +
      '<dt>PID</dt><dd>' + snap.deployment_pid + '</dd>' +
      '<dt>Started</dt><dd>' + esc(snap.start_time) + '</dd>' +
      '<dt>Elapsed</dt><dd>' + fmtElapsed(snap.elapsed_seconds) + '</dd></dl>';
    if (snap.duplicate_pids && snap.duplicate_pids.length > 1) {
      html += '<div class="mon-alert critical">CRITICAL — Multiple OpenCenter deployment processes ' +
        '(PIDs ' + snap.duplicate_pids.join(', ') + ') are modifying the same cluster. ' +
        'Do not start another deployment. Investigate manually before any process is stopped.</div>';
    }
    el.innerHTML = html;
  }

  function renderGitops(snap) {
    var g = snap.gitops_status || {};
    var el = $('mon-gitops');
    if (!g.available) { el.innerHTML = '<div class="mon-empty">GitOps repo not readable</div>'; return; }
    var commit = g.last_commit || {};
    el.innerHTML =
      '<dt>Branch</dt><dd>' + esc(g.branch || '—') + ' → ' + esc(g.upstream || '—') + '</dd>' +
      '<dt>Tree</dt><dd>' + (g.clean ? '<span class="mon-chip g">clean</span>'
        : '<span class="mon-chip a">dirty (' + (g.dirty_files || []).length + ' files)</span>') + '</dd>' +
      '<dt>Unpushed</dt><dd>' + (g.ahead || 0) + ' commit(s)</dd>' +
      '<dt>Last commit</dt><dd>' + esc(commit.sha || '—') + ' ' + esc(commit.subject || '') + '</dd>' +
      ((g.dirty_files || []).length
        ? '<dt>Dirty files</dt><dd style="font-size:10.5px;color:var(--mon-dim);">' +
          esc((g.dirty_files || []).slice(0, 8).join(', ')) + '</dd>'
        : '');
  }

  function renderTofu(snap) {
    var t = snap.infrastructure_status || {};
    var el = $('mon-tofu');
    var html = '<dl class="mon-kv">' +
      '<dt>Creating</dt><dd>' + (t.creating || []).length + '</dd>' +
      '<dt>Completed</dt><dd>' + (t.created || []).length + '</dd>' +
      '<dt>Destroying</dt><dd>' + (t.destroying || []).length + '</dd>' +
      (t.summary ? '<dt>Summary</dt><dd>' + esc(t.summary) + '</dd>' : '') +
      (t.lock ? '<dt>State lock</dt><dd class="mon-chip a">' + esc(t.lock) + '</dd>' : '') +
      '</dl>';
    if ((t.creating || []).length) {
      html += '<div style="margin-top:6px;font-size:10.5px;color:var(--mon-blue);">' +
        (t.creating || []).slice(0, 6).map(esc).join('<br>') + '</div>';
    }
    if ((t.errors || []).length) {
      html += '<div style="margin-top:6px;font-size:10.5px;color:var(--mon-red);">' +
        (t.errors || []).slice(-4).map(esc).join('<br>') + '</div>';
    }
    el.innerHTML = html;
  }

  function renderCloudInit(snap) {
    var c = snap.cloud_init_status || {}, a = snap.kubespray_status || {};
    $('mon-cloudinit').innerHTML =
      '<dt>Cloud-init</dt><dd>' + esc(c.status || 'unknown') + '</dd>' +
      '<dt>Attempts</dt><dd>' + (c.attempts || 0) + '</dd>' +
      (c.detail ? '<dt>Detail</dt><dd style="font-size:10.5px;">' + esc(c.detail) + '</dd>' : '');
    var recap = a.recap || {};
    var hosts = Object.keys(recap);
    var html = a.last_task
      ? '<div style="font-size:11px;"><span class="mon-chip x">TASK</span> ' + esc(a.last_task) + '</div>'
      : '<div class="mon-empty">no Ansible activity yet</div>';
    if (hosts.length) {
      html += '<table class="mon-table" style="margin-top:6px;"><tr><th>host</th><th>ok</th><th>chg</th><th>unreach</th><th>fail</th></tr>' +
        hosts.map(function (h) {
          var r = recap[h];
          return '<tr><td>' + esc(h) + '</td><td>' + r.ok + '</td><td>' + r.changed +
            '</td><td class="' + (r.unreachable ? 'l-err' : '') + '">' + r.unreachable +
            '</td><td class="' + (r.failed ? 'l-err' : '') + '">' + r.failed + '</td></tr>';
        }).join('') + '</table>';
    }
    $('mon-ansible').innerHTML = html;
  }

  function renderK8s(snap) {
    var k = snap.kubernetes_status || {};
    var el = $('mon-k8s');
    if (!k.available) {
      el.innerHTML = '<div class="mon-empty">' + esc(k.reason || 'not available yet — kubeconfig pending') + '</div>';
      return;
    }
    var pods = k.pods || {};
    el.innerHTML = '<dl class="mon-kv">' +
      '<dt>API</dt><dd><span class="mon-chip g">reachable</span></dd>' +
      '<dt>Nodes</dt><dd>' + k.nodes_ready + '/' + k.nodes_total + ' Ready</dd>' +
      '<dt>Pods running</dt><dd>' + (pods.running || 0) + '/' + (pods.total || 0) + '</dd>' +
      '<dt>Problems</dt><dd>' + ((pods.crashloop || 0) + (pods.imagepull || 0) + (pods.failed || 0)) + '</dd></dl>';
  }

  function renderErrors(snap) {
    var el = $('mon-errors');
    var errs = snap.errors || [];
    if (!errs.length) { el.innerHTML = '<div class="mon-empty">no classified failures</div>'; return; }
    el.innerHTML = errs.slice(-6).reverse().map(function (e) {
      return '<div style="border-bottom:1px solid var(--mon-border);padding:6px 0;">' +
        '<span class="mon-chip r">' + esc(e.category || 'unknown') + '</span> ' +
        '<span style="font-size:11.5px;font-weight:600;">' + esc(e.root_cause || '') + '</span>' +
        (e.evidence ? '<div style="font-size:10px;color:var(--mon-dim);margin-top:2px;">' + esc(e.evidence) + '</div>' : '') +
        (e.next_command ? '<div class="mon-cmd" style="margin-top:4px;">' + esc(e.next_command) + '</div>' : '') +
        (e.resumable && e.from_step
          ? '<div style="font-size:10px;color:var(--mon-green);margin-top:2px;">resumable — try --from-step ' + esc(e.from_step) + '</div>'
          : '') +
        '</div>';
    }).join('');
  }

  function renderSnapshot(snap) {
    lastSnapshot = snap;
    badge('mon-provider', (snap.provider || '—') + (snap.region ? ' · ' + snap.region : ''), '');
    badge('mon-status', snap.deployment_status, STATUS_CLS[snap.deployment_status] || '');
    badge('mon-pid', snap.deployment_pid ? 'PID ' + snap.deployment_pid : 'PID —',
      snap.deployment_pid ? 'run' : '');
    badge('mon-elapsed', 'elapsed ' + fmtElapsed(snap.elapsed_seconds), '');
    badge('mon-logname', snap.latest_log || 'no log yet', '');
    var crit = $('mon-critical');
    if (snap.deployment_status === 'BLOCKED' && (snap.duplicate_pids || []).length > 1) {
      crit.innerHTML = '<div class="mon-alert critical">CRITICAL — Multiple OpenCenter deployment processes are modifying the same cluster (PIDs ' +
        snap.duplicate_pids.join(', ') + '). Do not start another deployment.</div>';
    } else if (snap.deployment_status === 'RUNNING') {
      crit.innerHTML = '<div class="mon-alert warning">Deployment already active — do not start another deployment.</div>';
    } else {
      crit.innerHTML = '';
    }
    renderStages(snap);
    renderProc(snap);
    renderGitops(snap);
    renderTofu(snap);
    renderCloudInit(snap);
    renderK8s(snap);
    renderErrors(snap);
  }

  // ----------------------------------------------------- OpenStack VM card
  function pollInfra() {
    fetch(API + '/infrastructure').then(function (r) { return r.json(); }).then(function (d) {
      var infra = (d && d.infrastructure) || {};
      var el = $('mon-infra');
      if (!infra.available) {
        $('mon-infra-note').textContent = infra.reason || '';
        return;
      }
      var servers = infra.servers || [];
      if (!servers.length) {
        el.innerHTML = '<div class="mon-empty">no VMs found for this cluster yet</div>';
        return;
      }
      el.innerHTML = '<table class="mon-table"><tr><th>server</th><th>status</th><th>IPs</th><th>flavor</th><th>fault</th></tr>' +
        servers.map(function (s) {
          var cls = s.status === 'ACTIVE' ? 'g' : (s.status === 'ERROR' ? 'r' : 'a');
          return '<tr><td>' + esc(s.name) + '</td>' +
            '<td><span class="mon-dot ' + cls + '"></span>' + esc(s.status) + '</td>' +
            '<td style="font-size:10.5px;">' + esc((s.ips || []).join(', ')) + '</td>' +
            '<td>' + esc(s.flavor || '') + '</td>' +
            '<td class="l-err" style="font-size:10px;">' + esc(s.fault || '') + '</td></tr>';
        }).join('') + '</table>';
      $('mon-infra-note').textContent = 'refreshes every 5 s';
    }).catch(function () { /* transient — keep last render */ });
  }
  setInterval(pollInfra, 5000);
  pollInfra();

  // ----------------------------------------------------------------- SSE
  function connect() {
    es = new EventSource(API + '/stream');
    es.addEventListener('log', function (ev) {
      if (paused) return;
      try { appendLog(JSON.parse(ev.data).line); } catch (e) { /* skip */ }
    });
    es.addEventListener('snapshot', function (ev) {
      if (paused) return;
      try { renderSnapshot(JSON.parse(ev.data)); } catch (e) { /* skip */ }
    });
    es.addEventListener('status', function (ev) {
      try {
        var d = JSON.parse(ev.data);
        if (d.log) appendLog('--- switched to ' + d.log + ' ---');
      } catch (e) { /* skip */ }
    });
    es.onerror = function () {
      $('mon-pulse').className = 'mon-pulse dead';
      es.close();
      setTimeout(function () {
        $('mon-pulse').className = 'mon-pulse' + (paused ? ' paused' : '');
        connect();
      }, 4000);
    };
  }
  connect();
})();
