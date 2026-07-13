(function () {
  'use strict';

  var selector = [
    '.r6p-terminal', '.r6v2-terminal', '.crt-terminal',
    '.jh-terminal-free', '.jh-terminal-ip', '.migration-terminal-shell',
    '.migration-terminal-body', '.nbd-terminal-body', '.cutmob-terminal',
    '.fsm-terminal-output', '[id$="-log-output"]', '[data-terminal-output]'
  ].join(',');
  var sequence = 0;

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      var area = document.createElement('textarea');
      area.value = text;
      area.setAttribute('readonly', '');
      area.style.cssText = 'position:fixed;left:-9999px;top:0;';
      document.body.appendChild(area);
      area.select();
      try {
        if (!document.execCommand('copy')) throw new Error('copy command rejected');
        resolve();
      } catch (error) {
        reject(error);
      } finally {
        area.remove();
      }
    });
  }

  function terminalText(terminal) {
    if ('value' in terminal && /^(TEXTAREA|INPUT)$/.test(terminal.tagName)) return terminal.value || '';
    return terminal.innerText || terminal.textContent || '';
  }

  function syncButton(terminal, button) {
    button.style.display = terminal.hidden || terminal.style.display === 'none' ? 'none' : 'inline-flex';
  }

  function attach(terminal) {
    if (!terminal || terminal.nodeType !== 1 || terminal.dataset.copyLogReady === 'true') return;
    if (/^(INPUT|SELECT)$/.test(terminal.tagName)) return;
    terminal.dataset.copyLogReady = 'true';
    if (!terminal.id) terminal.id = 'migration-log-output-' + (++sequence);

    var button = document.createElement('button');
    button.type = 'button';
    button.className = 'migration-copy-log-btn';
    button.setAttribute('aria-label', 'Copy terminal log');
    button.dataset.copyLogFor = terminal.id;
    button.textContent = 'Copy Log';
    button.addEventListener('click', function () {
      var original = button.textContent;
      copyText(terminalText(terminal)).then(function () {
        button.textContent = 'Copied';
        button.classList.add('copied');
      }).catch(function () {
        button.textContent = 'Copy failed';
      }).finally(function () {
        window.setTimeout(function () {
          button.textContent = original;
          button.classList.remove('copied');
        }, 1600);
      });
    });
    terminal.parentNode.insertBefore(button, terminal);
    syncButton(terminal, button);

    new MutationObserver(function () { syncButton(terminal, button); }).observe(terminal, {
      attributes: true, attributeFilter: ['style', 'class', 'hidden']
    });
  }

  function scan(root) {
    if (!root || root.nodeType !== 1 && root.nodeType !== 9) return;
    if (root.matches && root.matches(selector)) attach(root);
    if (root.querySelectorAll) root.querySelectorAll(selector).forEach(attach);
  }

  function start() {
    var style = document.createElement('style');
    style.textContent = '.migration-copy-log-btn{display:inline-flex;align-items:center;gap:4px;margin:4px 0 5px auto;padding:4px 10px;border:1px solid #94a3b8;border-radius:5px;background:#f8fafc;color:#334155;font:700 11px/1.2 sans-serif;cursor:pointer}.migration-copy-log-btn:hover{background:#e2e8f0}.migration-copy-log-btn.copied{border-color:#16a34a;background:#dcfce7;color:#166534}';
    document.head.appendChild(style);
    scan(document);
    new MutationObserver(function (records) {
      records.forEach(function (record) {
        record.addedNodes.forEach(scan);
      });
    }).observe(document.body, {childList: true, subtree: true});
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
