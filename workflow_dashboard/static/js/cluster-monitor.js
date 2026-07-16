/* OpenCenter Cluster Operations Monitor — SSE-driven, read-only. */
(function () {
  'use strict';
  var body = document.body;
  var ORG = body.dataset.org, CLUSTER = body.dataset.cluster;
  var API = '/api/monitoring/cluster/' + ORG + '/' + CLUSTER;
  var paused = false, es = null, lastSnap = null;

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }
  function chip(ok, textOk, textBad) {
    return ok ? '<span class="mon-chip g">' + (textOk || 'ready') + '</span>'
              : '<span class="mon-chip r">' + (textBad || 'not ready') + '</span>';
  }

  document.getElementById('mon-open-deploy').href =
    '/opencenter/monitor/deployment/' + ORG + '/' + CLUSTER;

  fetch('/api/monitoring/clusters').then(function (r) { return r.json(); }).then(function (d) {
    var sel = $('mon-cluster-select');
    (d.pairs || []).forEach(function (p) {
      var opt = document.createElement('option');
      opt.value = p.org + '/' + p.cluster;
      opt.textContent = p.org + '/' + p.cluster;
      if (p.org === ORG && p.cluster === CLUSTER) opt.selected = true;
      sel.appendChild(opt);
    });
    sel.onchange = function () { location.href = '/opencenter/monitor/cluster/' + sel.value; };
  });

  $('mon-pause').onclick = function () {
    paused = !paused;
    this.textContent = paused ? '▶ Resume' : '⏸ Pause';
    $('mon-pulse').className = 'mon-pulse' + (paused ? ' paused' : '');
  };
  $('mon-diag').onclick = function () {
    if (lastSnap) navigator.clipboard.writeText(JSON.stringify(lastSnap, null, 2));
  };

  function render(snap) {
    lastSnap = snap;
    var provider = $('mon-provider');
    provider.textContent = (snap.provider || '—') + (snap.region ? ' · ' + snap.region : '');

    if (!snap.available) {
      $('mon-api').textContent = 'API unavailable';
      $('mon-api').className = 'mon-badge err';
      $('mon-alerts').innerHTML =
        '<div class="mon-alert warning">' + esc(snap.reason || 'cluster not available yet') + '</div>';
      return;
    }
    $('mon-api').textContent = 'API healthy';
    $('mon-api').className = 'mon-badge ok';

    var score = snap.health_score || 0;
    var scoreEl = $('mon-score');
    scoreEl.textContent = score;
    scoreEl.className = 'mon-score ' + (score >= 85 ? 'g' : score >= 60 ? 'a' : 'r');
    $('mon-score-note').textContent = 'nodes · pods · flux · services';

    var cp = snap.control_plane || {}, wk = snap.workers || {}, pods = snap.pods || {};
    $('mon-cp').innerHTML = '<dt>Ready</dt><dd>' + (cp.ready || 0) + '/' + (cp.total || 0) + '</dd>';
    $('mon-wk').innerHTML = '<dt>Ready</dt><dd>' + (wk.ready || 0) + '/' + (wk.total || 0) + '</dd>';
    $('mon-podsum').innerHTML =
      '<dt>Running</dt><dd>' + (pods.running || 0) + '/' + (pods.total || 0) + '</dd>' +
      '<dt>Problems</dt><dd>' + ((pods.crashloop || 0) + (pods.imagepull || 0) + (pods.failed || 0)) + '</dd>' +
      '<dt>Restarts</dt><dd>' + (pods.restarts || 0) + '</dd>';

    $('mon-alerts').innerHTML = (snap.active_alerts || []).map(function (a) {
      return '<div class="mon-alert ' + (a.severity === 'critical' ? 'critical' : 'warning') + '">' +
        esc(a.message) + '</div>';
    }).join('');

    // topology
    $('mon-topo').innerHTML = (snap.nodes || []).map(function (n) {
      return '<div class="mon-node ' + (n.ready ? 'ready' : 'notready') + '">' +
        '<div class="nn">' + esc(n.name) + ' <span class="mon-chip ' + (n.ready ? 'g' : 'r') + '">' +
        (n.ready ? 'Ready' : 'NotReady') + '</span></div>' +
        '<div class="nd">' + esc(n.role) + ' · ' + esc(n.kubelet_version) + '</div>' +
        '<div class="nd">' + esc(n.internal_ip) + (n.external_ip ? ' / ' + esc(n.external_ip) : '') + '</div>' +
        '<div class="nd">cpu ' + esc(n.cpu) + ' · mem ' + esc(n.memory) + '</div>' +
        '<div class="nd">' + esc(n.os_image) + '</div></div>';
    }).join('') || '<div class="mon-empty">no nodes reported</div>';

    // service matrix
    $('mon-services').innerHTML = (snap.platform_services || []).map(function (s) {
      var state = !s.installed ? '<span class="mon-chip x">not installed</span>'
        : s.healthy ? '<span class="mon-chip g">healthy</span>'
        : '<span class="mon-chip r">degraded</span>';
      var detail = (s.workloads || []).map(function (w) {
        return w.name + ' ' + w.ready + '/' + w.desired;
      }).join(', ');
      return '<div class="mon-svc"><div class="sn">' + esc(s.title) + '</div>' +
        '<div class="sd">' + esc(s.namespace) + '</div>' + state +
        (detail ? '<div class="sd" style="margin-top:2px;">' + esc(detail) + '</div>' : '') + '</div>';
    }).join('');

    // flux
    function fluxBlock(title, rows) {
      var bad = rows.filter(function (r) { return !r.ready && !r.suspended; });
      var html = '<div style="margin-bottom:6px;"><b style="font-size:11px;">' + title + '</b> ' +
        '<span class="mon-chip ' + (bad.length ? 'r' : 'g') + '">' +
        (rows.length - bad.length) + '/' + rows.length + ' ready</span></div>';
      if (bad.length) {
        html += bad.slice(0, 4).map(function (r) {
          return '<div style="font-size:10.5px;color:var(--mon-red);">' + esc(r.namespace + '/' + r.name) +
            ': ' + esc((r.message || '').slice(0, 90)) + '</div>';
        }).join('');
      }
      return html;
    }
    $('mon-flux').innerHTML =
      fluxBlock('Sources', snap.flux_sources || []) +
      fluxBlock('Kustomizations', snap.flux_kustomizations || []) +
      fluxBlock('HelmReleases', snap.helm_releases || []);

    // workloads detail
    var byNs = pods.by_namespace || {};
    var nsRows = Object.keys(byNs).sort(function (a, b) { return byNs[b] - byNs[a]; }).slice(0, 8);
    $('mon-workloads').innerHTML =
      '<dl class="mon-kv">' +
      '<dt>Pending</dt><dd>' + (pods.pending || 0) + '</dd>' +
      '<dt>Failed</dt><dd>' + (pods.failed || 0) + '</dd>' +
      '<dt>CrashLoop</dt><dd>' + (pods.crashloop || 0) + '</dd>' +
      '<dt>ImagePull</dt><dd>' + (pods.imagepull || 0) + '</dd></dl>' +
      (nsRows.length ? '<div style="margin-top:6px;font-size:10.5px;color:var(--mon-dim);">' +
        nsRows.map(function (ns) { return esc(ns) + ': ' + byNs[ns]; }).join(' · ') + '</div>' : '') +
      ((pods.top_restarting || []).length
        ? '<div style="margin-top:6px;font-size:10.5px;">restarts: ' +
          pods.top_restarting.slice(0, 4).map(function (p) {
            return esc(p.namespace + '/' + p.pod) + ' (' + p.restarts + ')';
          }).join(', ') + '</div>' : '');

    // network
    $('mon-network').innerHTML =
      ((snap.gateways || []).length
        ? snap.gateways.map(function (g) {
            return '<div style="font-size:11px;"><b>' + esc(g.namespace + '/' + g.name) + '</b> (' +
              esc(g.class) + ', ' + g.listeners + ' listeners) ' +
              esc((g.addresses || []).join(', ')) + '</div>';
          }).join('')
        : '<div class="mon-empty">no gateways</div>') +
      ((snap.services || []).length
        ? '<div style="margin-top:6px;font-size:10.5px;color:var(--mon-dim);">LoadBalancers: ' +
          snap.services.map(function (s) {
            return esc(s.namespace + '/' + s.name) + ' → ' + esc((s.external_ips || []).join(',') || 'pending');
          }).join(' · ') + '</div>' : '') +
      ((snap.floating_ips || []).length
        ? '<div style="margin-top:6px;font-size:10.5px;color:var(--mon-dim);">Floating IPs: ' +
          snap.floating_ips.length + ' allocated</div>' : '');

    // storage
    var pvcs = snap.pvcs || [];
    var bound = pvcs.filter(function (p) { return p.phase === 'Bound'; }).length;
    $('mon-storage').innerHTML =
      '<dl class="mon-kv"><dt>PVCs bound</dt><dd>' + bound + '/' + pvcs.length + '</dd>' +
      '<dt>StorageClasses</dt><dd>' + (snap.storage_classes || []).map(function (sc) {
        return esc(sc.name) + (sc.default ? '*' : '');
      }).join(', ') + '</dd></dl>' +
      (pvcs.filter(function (p) { return p.phase !== 'Bound'; }).slice(0, 4).map(function (p) {
        return '<div style="font-size:10.5px;color:var(--mon-amber);">' +
          esc(p.namespace + '/' + p.name) + ': ' + esc(p.phase) + '</div>';
      }).join(''));

    // certificates
    var certs = snap.certificates || [];
    $('mon-certs').innerHTML = certs.length
      ? certs.slice(0, 10).map(function (c) {
          return '<div style="font-size:11px;">' + chip(c.ready) + ' ' +
            esc(c.namespace + '/' + c.name) +
            (c.not_after ? ' <span style="color:var(--mon-dim);font-size:10px;">exp ' +
              esc(String(c.not_after).slice(0, 10)) + '</span>' : '') + '</div>';
        }).join('')
      : '<div class="mon-empty">no certificates reported</div>';

    // quota
    var quotas = snap.quotas || {};
    var qNames = Object.keys(quotas).filter(function (k) {
      return ['instances', 'cores', 'ram', 'ports', 'security-groups', 'security-group-rules',
              'floating-ips', 'routers', 'networks', 'volumes', 'gigabytes'].indexOf(k) !== -1;
    });
    $('mon-quota').innerHTML =
      ((snap.infrastructure || {}).servers || []).length
        ? '<div style="font-size:10.5px;margin-bottom:6px;">VMs: ' +
          snap.infrastructure.servers.map(function (s) {
            var cls = s.status === 'ACTIVE' ? 'g' : 'r';
            return '<span class="mon-dot ' + cls + '"></span>' + esc(s.name.replace(CLUSTER + '-', ''));
          }).join(' ') + '</div>'
        : '';
    $('mon-quota').innerHTML += qNames.length
      ? '<table class="mon-table">' + qNames.map(function (k) {
          var q = quotas[k];
          var cls = q.alert === 'critical' ? 'r' : q.alert === 'warning' ? 'a' : q.alert ? 'a' : 'g';
          return '<tr><td>' + esc(k) + '</td><td>' + q.used + '/' + q.limit + '</td>' +
            '<td><span class="mon-chip ' + cls + '">' + Math.round(q.ratio * 100) + '%</span></td></tr>';
        }).join('') + '</table>'
      : '<div class="mon-empty">quota data not available</div>';

    // security
    $('mon-security').innerHTML =
      '<dl class="mon-kv">' +
      '<dt>Cluster secgroups</dt><dd>' + (snap.security_groups || []).length + '</dd>' +
      '<dt>Certificates ready</dt><dd>' + certs.filter(function (c) { return c.ready; }).length +
      '/' + certs.length + '</dd></dl>';

    renderEvents();
    $('mon-gitrev').textContent = 'rev ' + (((snap.flux_sources || [])[0] || {}).revision || '—').slice(0, 24);
  }

  function renderEvents() {
    if (!lastSnap) return;
    var typeFilter = $('mon-ev-source').value;
    var search = $('mon-ev-search').value.toLowerCase();
    var rows = (lastSnap.recent_events || []).filter(function (e) {
      if (typeFilter !== 'all' && e.type !== typeFilter) return false;
      if (search && (e.namespace + e.object + e.reason + e.message).toLowerCase().indexOf(search) === -1) return false;
      return true;
    });
    $('mon-events').innerHTML = rows.length
      ? '<table class="mon-table"><tr><th>time</th><th>ns</th><th>object</th><th>reason</th><th>message</th><th>#</th></tr>' +
        rows.map(function (e) {
          return '<tr><td style="white-space:nowrap;">' + esc(String(e.last_seen).replace('T', ' ').slice(0, 19)) + '</td>' +
            '<td>' + esc(e.namespace) + '</td><td>' + esc(e.object) + '</td>' +
            '<td class="' + (e.type === 'Warning' ? 'l-warn' : '') + '">' + esc(e.reason) + '</td>' +
            '<td style="font-size:10.5px;">' + esc(e.message) + '</td><td>' + e.count + '</td></tr>';
        }).join('') + '</table>'
      : '<div class="mon-empty">no matching events</div>';
  }
  $('mon-ev-source').onchange = renderEvents;
  $('mon-ev-search').oninput = renderEvents;

  function connect() {
    es = new EventSource(API + '/stream');
    es.addEventListener('snapshot', function (ev) {
      if (paused) return;
      try { render(JSON.parse(ev.data)); } catch (e) { /* skip */ }
    });
    es.onerror = function () {
      $('mon-pulse').className = 'mon-pulse dead';
      es.close();
      setTimeout(function () {
        $('mon-pulse').className = 'mon-pulse' + (paused ? ' paused' : '');
        connect();
      }, 5000);
    };
  }
  connect();
})();
