/* Global, versioned cache for stage/page outputs. Loaded into every HTML page. */
(function () {
  'use strict';
  if (window.__osflexStageOutputCacheInstalled) return;
  window.__osflexStageOutputCacheInstalled = true;

  const DB_NAME = 'osflex_stage_output_cache';
  const STORE = 'outputs';
  const DB_VERSION = 1;
  const MAX_ENTRIES = 750;
  const MAX_VALUE_BYTES = 750000;
  const OUTPUT_HINT = /(^|[-_])(output|result|results|log|logs|terminal|report|evidence|console|status)([-_]|$)/i;
  const SELECTOR = '[data-stage-output],output,pre,textarea[readonly],[role="log"],[aria-live]';
  let dbPromise;
  let saveTimer;
  const dirty = new Set();

  function openDb() {
    if (!dbPromise) {
      dbPromise = new Promise(function (resolve, reject) {
        const req = indexedDB.open(DB_NAME, DB_VERSION);
        req.onupgradeneeded = function () {
          const db = req.result;
          if (!db.objectStoreNames.contains(STORE)) {
            const store = db.createObjectStore(STORE, { keyPath: 'key' });
            store.createIndex('updatedAt', 'updatedAt');
          }
        };
        req.onsuccess = function () { resolve(req.result); };
        req.onerror = function () { reject(req.error); };
      });
    }
    return dbPromise;
  }

  function requestResult(req) {
    return new Promise(function (resolve, reject) {
      req.onsuccess = function () { resolve(req.result); };
      req.onerror = function () { reject(req.error); };
    });
  }

  function pageScope() {
    return location.pathname + location.search.replace(/([?&])v=[^&]*/g, '$1').replace(/[?&]$/, '');
  }

  function stageScope(el) {
    const stage = el.closest('[data-stage],.panel[id],section[id]');
    return stage ? (stage.getAttribute('data-stage') || stage.id || 'page') : 'page';
  }

  function stableElementKey(el) {
    const explicit = el.getAttribute('data-stage-output');
    if (explicit && explicit !== 'true') return explicit;
    if (el.id) return 'id:' + el.id;
    if (el.getAttribute('name')) return 'name:' + el.getAttribute('name');
    const parts = [];
    let node = el;
    while (node && node !== document.body && parts.length < 6) {
      let part = node.tagName.toLowerCase();
      if (node.id) { parts.unshift('#' + node.id); break; }
      const siblings = node.parentElement
        ? Array.from(node.parentElement.children).filter(function (n) { return n.tagName === node.tagName; })
        : [];
      if (siblings.length > 1) part += ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')';
      parts.unshift(part);
      node = node.parentElement;
    }
    return 'path:' + parts.join('>');
  }

  function isOutput(el) {
    if (!(el instanceof Element) || el.closest('[data-no-output-cache="1"]')) return false;
    if (el.matches(SELECTOR)) return true;
    return Boolean(el.id && OUTPUT_HINT.test(el.id)) ||
      Array.from(el.classList || []).some(function (name) { return OUTPUT_HINT.test(name); });
  }

  function recordFor(el) {
    let mode = el.getAttribute('data-stage-output-mode');
    if (!mode) mode = /^(PRE|OUTPUT|TEXTAREA)$/.test(el.tagName) ? 'text' : 'html';
    const value = mode === 'text'
      ? (el.tagName === 'TEXTAREA' ? el.value : el.textContent)
      : el.innerHTML;
    if (!value || value === 'Ready.' || new Blob([value]).size > MAX_VALUE_BYTES) return null;
    return {
      key: pageScope() + '|' + stageScope(el) + '|' + stableElementKey(el),
      page: pageScope(), stage: stageScope(el), element: stableElementKey(el),
      mode: mode, value: value, updatedAt: Date.now()
    };
  }

  function putRecords(records) {
    if (!records.length) return Promise.resolve();
    return openDb().then(function (db) {
      const tx = db.transaction(STORE, 'readwrite');
      const store = tx.objectStore(STORE);
      records.forEach(function (record) { store.put(record); });
      return new Promise(function (resolve) {
        tx.oncomplete = resolve; tx.onerror = resolve; tx.onabort = resolve;
      });
    }).then(prune).catch(function () {});
  }

  function flush() {
    saveTimer = null;
    const records = [];
    dirty.forEach(function (el) {
      if (el.isConnected && isOutput(el)) {
        const record = recordFor(el);
        if (record) records.push(record);
      }
    });
    dirty.clear();
    return putRecords(records);
  }

  function queue(el) {
    const output = el && (isOutput(el) ? el : el.closest && el.closest(SELECTOR));
    if (!output || output.dataset.outputCacheRestoring === '1') return;
    dirty.add(output);
    clearTimeout(saveTimer);
    saveTimer = setTimeout(flush, 250);
  }

  function prune() {
    return openDb().then(function (db) {
      const tx = db.transaction(STORE, 'readwrite');
      const store = tx.objectStore(STORE);
      return requestResult(store.count()).then(function (count) {
        let remove = Math.max(0, count - MAX_ENTRIES);
        if (!remove) return;
        const cursor = store.index('updatedAt').openCursor();
        cursor.onsuccess = function () {
          const row = cursor.result;
          if (row && remove-- > 0) { row.delete(); row.continue(); }
        };
      });
    }).catch(function () {});
  }

  function outputElements(root) {
    const found = [];
    if (root instanceof Element && isOutput(root)) found.push(root);
    if (root && root.querySelectorAll) {
      root.querySelectorAll(SELECTOR + ',[id],[class]').forEach(function (el) {
        if (isOutput(el)) found.push(el);
      });
    }
    return Array.from(new Set(found));
  }

  function restore(root) {
    const elements = outputElements(root || document);
    if (!elements.length) return Promise.resolve(0);
    return openDb().then(function (db) {
      const store = db.transaction(STORE, 'readonly').objectStore(STORE);
      return Promise.all(elements.map(function (el) {
        const key = pageScope() + '|' + stageScope(el) + '|' + stableElementKey(el);
        return requestResult(store.get(key)).then(function (record) {
          if (!record || !record.value) return 0;
          el.dataset.outputCacheRestoring = '1';
          if (record.mode === 'text') {
            if (el.tagName === 'TEXTAREA') el.value = record.value;
            else el.textContent = record.value;
          } else {
            el.innerHTML = record.value;
          }
          delete el.dataset.outputCacheRestoring;
          el.dispatchEvent(new CustomEvent('osflex:output-restored', { bubbles: true, detail: record }));
          return 1;
        });
      }));
    }).then(function (rows) {
      return rows.reduce(function (sum, n) { return sum + n; }, 0);
    }).catch(function () { return 0; });
  }

  function clear(scope) {
    return openDb().then(function (db) {
      const tx = db.transaction(STORE, 'readwrite');
      const store = tx.objectStore(STORE);
      if (!scope) return requestResult(store.clear());
      return requestResult(store.getAllKeys()).then(function (keys) {
        keys.filter(function (key) { return String(key).startsWith(scope); })
          .forEach(function (key) { store.delete(key); });
      });
    });
  }

  function install() {
    restore(document);
    const observer = new MutationObserver(function (mutations) {
      mutations.forEach(function (mutation) {
        queue(mutation.target.nodeType === 3 ? mutation.target.parentElement : mutation.target);
        mutation.addedNodes.forEach(function (node) {
          if (node.nodeType === 1) restore(node);
        });
      });
    });
    observer.observe(document.body, { subtree: true, childList: true, characterData: true });
    document.addEventListener('input', function (event) { queue(event.target); }, true);
    document.addEventListener('change', function (event) { queue(event.target); }, true);
    window.addEventListener('pagehide', flush);
  }

  window.OSFlexStageOutputCache = {
    restore: restore, flush: flush, clear: clear, version: DB_VERSION
  };
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, { once: true });
  } else {
    install();
  }
})();
