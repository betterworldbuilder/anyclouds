/* Behavioral smoke test for the Where-to-Deploy wiring in r6ace.js (no browser). */
const fs = require('fs');

/* ── minimal DOM/localStorage stubs ── */
const store = {};
global.localStorage = {
  getItem: k => (k in store ? store[k] : null),
  setItem: (k, v) => { store[k] = String(v); },
  removeItem: k => { delete store[k]; }
};
function fakeEl(id) {
  return {
    id, style: {}, value: '', textContent: '', innerHTML: '',
    classList: { _s: new Set(), add(c){this._s.add(c);}, remove(c){this._s.delete(c);}, toggle(c,f){f?this._s.add(c):this._s.delete(c);}, contains(c){return this._s.has(c);} },
    querySelector: () => null, appendChild: () => {}, setAttribute: () => {},
    remove: () => {}, click: () => {}, scrollIntoView: () => {}, insertAdjacentHTML: () => {},
    parentNode: { removeChild: () => {}, insertBefore: () => {} }, nextSibling: null
  };
}
const els = {};
global.document = {
  getElementById: id => { if (!(id in els)) els[id] = fakeEl(id); return els[id]; },
  querySelector: () => null, querySelectorAll: () => [],
  createElement: () => fakeEl('tmp'), body: { appendChild: () => {} },
  addEventListener: () => {}
};
global.window = global;
global.alert = () => {};
global.navigator = { clipboard: null };
global.EventSource = function(){ this.close=()=>{}; };
global.MutationObserver = function(){ this.observe=()=>{}; this.disconnect=()=>{}; };
global.fetch = () => Promise.resolve({ json: () => Promise.resolve({}) });

/* provider selects exist before load */
document.getElementById('ocqs-provider').value = 'openstack';
document.getElementById('ocqp-provider').value = 'openstack';

let fails = 0;
const check = (name, cond) => { console.log((cond ? 'PASS' : 'FAIL') + ' - ' + name); if (!cond) fails++; };

/* ── load the real engine ── */
eval(fs.readFileSync('/home/dzoan/cloudmax/workflow_dashboard/static/r6ace.js', 'utf8'));

check('default deployTarget is openstack', R6P.deployTarget === 'openstack');

/* ── MockBank demo system preloaded into Stage 1 ── */
const systems = JSON.parse(store['uatS1_systems'] || '[]');
const demo = systems.find(s => s.id === 'bs-mockbank-demo');
check('MockBank demo system seeded into uatS1_systems', !!demo);
check('demo has 3 components (frontend/api/db)', !!demo && demo.components.length === 3);
check('demo db component is stateful (persistentPath set)',
  !!demo && demo.components.some(c => c.name === 'bank-db' && /postgresql/.test(c.persistentPath)));
check('demo has dependency map (frontend->api->db)', !!demo && demo.dependencies.length === 2);
check('demo auto-selected when nothing remembered', store['r6p_selected_business_system_id'] === 'bs-mockbank-demo');
r6pSyncSelectedBusinessSystem(true);
check('sync picks up demo as active business system', R6P.bs && R6P.bs.id === 'bs-mockbank-demo');
check('sync loads demo components', R6P.components.length === 3);
/* deletion respected: seeded flag prevents resurrect on next load */
check('seeded flag set (no resurrect after delete)', store['r6p_mockbank_demo_seeded'] === '1');

const osTool = R6P_TOOLS.find(t => t.name === 'openstack');
const dockerTool = R6P_TOOLS.find(t => t.name === 'docker');
const kindTool = R6P_TOOLS.find(t => t.name === 'kind');
check('openstack tool required in openstack mode', r6pToolReq(osTool) === true);
check('docker tool NOT required in openstack mode', r6pToolReq(dockerTool) === false);

/* switch to kind */
r6pSetDeployTarget('kind');
check('deployTarget switched to kind', R6P.deployTarget === 'kind');
check('localStorage r6ace_deploy_target = kind', store['r6ace_deploy_target'] === 'kind');
check('ocqs provider select synced to kind', document.getElementById('ocqs-provider').value === 'kind');
check('ocqp provider select synced to kind', document.getElementById('ocqp-provider').value === 'kind');
check('ocqs_state.provider = kind', JSON.parse(store['ocqs_state'] || '{}').provider === 'kind');
check('ocqp_state.provider = kind', JSON.parse(store['ocqp_state'] || '{}').provider === 'kind');
check('openstack tool NOT required in kind mode', r6pToolReq(osTool) === false);
check('docker tool required in kind mode', r6pToolReq(dockerTool) === true);
check('kind tool required in kind mode', r6pToolReq(kindTool) === true);

/* stage 12 platform box adapts */
const kindBox = r6pPlatformDeployBox();
check('stage12 kind box has --type kind', kindBox.indexOf('--type kind') >= 0);
check('stage12 kind box has --container-runtime docker', kindBox.indexOf('--container-runtime docker') >= 0);
check('stage12 kind box has gitea up', kindBox.indexOf('local gitea up') >= 0);

/* bundle carries deployTarget */
R6P.bs = { name: 'Demo Bank System', id: 'bs-1' };
R6P.components = [{ name: 'web-frontend', type: 'frontend', tgt: '10.0.0.5' }];
try { r6pGenBundle(); } catch (e) { console.log('genBundle threw: ' + e.message); }
check('bundle.deployTarget = kind', R6P.bundle && R6P.bundle.deployTarget === 'kind');
check('manifest stored with deployTarget', JSON.parse(store['r6OpenCenterHandoffBundle'] || '{}').deployTarget === 'kind');
check('output stored with deployTarget', JSON.parse(store['appsContainerRefactorOutput'] || '{}').deployTarget === 'kind');

/* import override adopts target: flip selects back to openstack, then import */
document.getElementById('ocqs-provider').value = 'openstack';
document.getElementById('ocqp-provider').value = 'openstack';
openCenterImportFromR6();
check('import sets ocqs provider from bundle', document.getElementById('ocqs-provider').value === 'kind');
check('import sets ocqp provider from bundle', document.getElementById('ocqp-provider').value === 'kind');

/* switch back to openstack */
r6pSetDeployTarget('openstack');
const osBox = r6pPlatformDeployBox();
check('deployTarget back to openstack', R6P.deployTarget === 'openstack');
check('stage12 openstack box has secrets sync', osBox.indexOf('secrets sync') >= 0);
check('stage12 openstack box has cluster deploy', osBox.indexOf('opencenter cluster deploy') >= 0);
check('ocqs select synced back to openstack', document.getElementById('ocqs-provider').value === 'openstack');

/* kind-mode guard on production auto-deploy */
r6pSetDeployTarget('kind');
r6pAutoDeployToOpenCenter();
const stEl = document.getElementById('r6p-auto-deploy-status');
check('auto-deploy blocked in kind mode', /Kind \(local\)/.test(stEl.textContent));

console.log(fails ? ('\n' + fails + ' FAILURES') : '\nALL SMOKE TESTS PASSED');
process.exit(fails ? 1 : 0);
