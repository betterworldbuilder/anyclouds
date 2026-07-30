/* Behavioral smoke test for the ocqs/ocqp kind-aware command generation in _panel_s2_opencenter.html */
const fs = require('fs');

const store = {};
global.localStorage = {
  getItem: k => (k in store ? store[k] : null),
  setItem: (k, v) => { store[k] = String(v); },
  removeItem: k => { delete store[k]; }
};
global.sessionStorage = global.localStorage;
function fakeEl(id) {
  return {
    id, style: {}, value: '', textContent: '', innerHTML: '', placeholder: '', href: '', className: '',
    checked: false, disabled: false, files: [],
    classList: { _s: new Set(), add(c){this._s.add(c);}, remove(c){this._s.delete(c);}, toggle(){}, contains(c){return this._s.has(c);} },
    querySelector: () => null, querySelectorAll: () => [], appendChild: () => {}, setAttribute: () => {},
    remove: () => {}, click: () => {}, scrollIntoView: () => {}, insertAdjacentHTML: () => {},
    addEventListener: () => {}, focus: () => {}, select: () => {},
    parentNode: { removeChild: () => {}, insertBefore: () => {} }, nextSibling: null,
    options: [], selectedIndex: 0
  };
}
const els = {};
global.document = {
  getElementById: id => { if (!(id in els)) els[id] = fakeEl(id); return els[id]; },
  querySelector: () => null, querySelectorAll: () => [],
  createElement: () => fakeEl('tmp'), body: { appendChild: () => {} },
  addEventListener: () => {}, head: { appendChild: () => {} }
};
global.window = global;
global.window.addEventListener = () => {};
global.alert = () => {};
global.confirm = () => true;
global.navigator = { clipboard: { writeText: () => Promise.resolve() } };
global.EventSource = function(){ this.close=()=>{}; this.onmessage=null; this.onerror=null; };
global.MutationObserver = function(){ this.observe=()=>{}; this.disconnect=()=>{}; };
global.fetch = () => Promise.resolve({ json: () => Promise.resolve({ok:true, clusters:[]}) });
global.FileReader = function(){ this.readAsText=()=>{}; };
global.FormData = function(){ this.append=()=>{}; };
global.Blob = function(){};
global.URL = { createObjectURL: () => 'blob:' };
global.setInterval = () => 0;

const html = fs.readFileSync('/home/dzoan/cloudmax/workflow_dashboard/templates/partials/_panel_s2_opencenter.html', 'utf8');
const blocks = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi)].map(m => m[1]);
let loaded = 0, loadErrs = [];
for (const b of blocks) {
  try { (0, eval)(b); loaded++; }
  catch (e) { loadErrs.push(e.message); }
}
console.log('blocks loaded:', loaded + '/' + blocks.length, loadErrs.length ? ('(load errors: ' + loadErrs.join(' | ') + ')') : '');

let fails = 0;
const check = (name, cond) => { console.log((cond ? 'PASS' : 'FAIL') + ' - ' + name); if (!cond) fails++; };
const txt = id => document.getElementById(id).textContent;

/* ── ocqs band in kind mode ── */
document.getElementById('ocqs-provider').value = 'kind';
try { ocqsUpdate(); } catch (e) { console.log('ocqsUpdate threw: ' + e.message); fails++; }
check('ocqs cmd-2 init has --type kind', txt('ocqs-cmd-2').includes('--type kind'));
check('ocqs cmd-6 validate has NO git preflight in kind', !txt('ocqs-cmd-6').includes('ls-remote'));
check('ocqs cmd-7 generate has --force in kind', txt('ocqs-cmd-7').includes('--force'));
check('ocqs cmd-8 kind: push handled by deploy', txt('ocqs-cmd-8').includes('gitea status'));
check('ocqs cmd-9 deploy has --container-runtime docker', txt('ocqs-cmd-9').includes('--container-runtime docker'));
check('ocqs kind box visible', document.getElementById('ocqs-kind-box').style.display === 'block');
check('ocqs kind K3 wires gitea token provider', txt('ocqs-cmd-kind-git').includes('auth.token.provider=gitea'));
check('ocqs full flow is kind flow', txt('ocqs-full-flow').includes('KIND LOCAL FULL FLOW'));
check('ocqs yaml preview provider kind', txt('ocqs-yaml-preview').includes('provider: "kind"'));
try { ocqsReqCheck(); } catch (e) { console.log('ocqsReqCheck threw: ' + e.message); fails++; }
check('ocqs req credid Optional in kind', document.getElementById('ocqs-req-credid').textContent === 'Optional');
check('ocqs req region Optional in kind', document.getElementById('ocqs-req-region').textContent === 'Optional');

/* ── ocqs band back to openstack ── */
document.getElementById('ocqs-provider').value = 'openstack';
try { ocqsUpdate(); } catch (e) { console.log('ocqsUpdate threw: ' + e.message); fails++; }
check('ocqs cmd-2 init has NO --type kind in openstack', !txt('ocqs-cmd-2').includes('--type kind'));
check('ocqs cmd-9 openstack uses opentofu path', txt('ocqs-cmd-9').includes('--from-step opentofu-init'));
check('ocqs kind box hidden', document.getElementById('ocqs-kind-box').style.display === 'none');
try { ocqsReqCheck(); } catch (e) {}
check('ocqs req region required again in openstack', document.getElementById('ocqs-req-region').textContent !== 'Optional');

/* ── ocqp band in kind mode ── */
document.getElementById('ocqp-provider').value = 'kind';
try { ocqpUpdate(); } catch (e) { console.log('ocqpUpdate threw: ' + e.message); fails++; }
check('ocqp cmd-2 init has --type kind', txt('ocqp-cmd-2').includes('--type kind'));
check('ocqp cmd-9 deploy has --container-runtime docker', txt('ocqp-cmd-9').includes('--container-runtime docker'));
check('ocqp kind box visible', document.getElementById('ocqp-kind-box').style.display === 'block');
check('ocqp full flow is kind flow', txt('ocqp-full-flow').includes('KIND LOCAL FULL FLOW'));
try { ocqpReqCheck(); } catch (e) { console.log('ocqpReqCheck threw: ' + e.message); fails++; }
check('ocqp req credsec Optional in kind', document.getElementById('ocqp-req-credsec').textContent === 'Optional');

/* ── chooser function sync (no r6ace loaded → fallback path) ── */
document.getElementById('ocqs-provider').value = 'openstack';
document.getElementById('ocqp-provider').value = 'openstack';
try { ocqsSetProvider('kind'); } catch (e) { console.log('ocqsSetProvider threw: ' + e.message); fails++; }
check('ocqsSetProvider sets ocqs select', document.getElementById('ocqs-provider').value === 'kind');
check('ocqsSetProvider fallback syncs ocqp select', document.getElementById('ocqp-provider').value === 'kind');
check('ocqsSetProvider persists r6ace_deploy_target', store['r6ace_deploy_target'] === 'kind');

console.log(fails ? ('\n' + fails + ' FAILURES') : '\nALL PANEL SMOKE TESTS PASSED');
process.exit(fails ? 1 : 0);
