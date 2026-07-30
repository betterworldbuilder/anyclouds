/* Behavioral smoke test for AI SWITCH Migration Log -> Palantir workflow wiring. */
const fs = require('fs');

const migrationSystems = [
  {
    id: 'payments',
    name: 'Payments Platform',
    archetype: 'api',
    criticality: 'Critical',
    region: 'IAD3',
    sensitivity: 'high',
    vms: [{ id: 'vm-1' }, { id: 'vm-2' }],
    components: [
      { name: 'payments-api', type: 'API Server', runtime: 'Python' },
      { name: 'payments-db', type: 'Database', runtime: 'PostgreSQL' }
    ]
  }
];

const store = { uatS1_systems: JSON.stringify(migrationSystems) };
global.localStorage = {
  getItem: key => (key in store ? store[key] : null),
  setItem: (key, value) => { store[key] = String(value); },
  removeItem: key => { delete store[key]; }
};

function fakeElement(id) {
  return {
    id,
    style: {},
    value: '',
    textContent: '',
    innerHTML: '',
    checked: false,
    files: [],
    children: [],
    className: '',
    appendChild(child) { this.children.push(child); },
    setAttribute(name, value) { this[name] = String(value); },
    getAttribute(name) { return this[name] || ''; },
    querySelectorAll() { return []; },
    querySelector() { return null; },
    addEventListener() {},
    scrollIntoView() {},
    click() {},
    classList: { add() {}, remove() {}, toggle() {} }
  };
}

const elements = {};
global.document = {
  readyState: 'loading',
  getElementById(id) {
    if (!elements[id]) elements[id] = fakeElement(id);
    return elements[id];
  },
  createElement() { return fakeElement('created'); },
  addEventListener() {},
  querySelectorAll() { return []; },
  body: { appendChild() {} }
};
global.window = global;
global.window.addEventListener = () => {};
global.navigator = { clipboard: { writeText: () => Promise.resolve() } };
global.Blob = function Blob() {};
global.URL = { createObjectURL: () => 'blob:smoke' };
global.fetch = () => Promise.resolve({ json: () => Promise.resolve({}) });

let adopted = null;
let migrationEditorMounts = 0;
global.saiAdoptUseSystem = system => { adopted = system; };
global.saiMountBusinessSystems = () => { migrationEditorMounts += 1; };

const source = fs.readFileSync(
  '/home/dzoan/cloudmax/workflow_dashboard/templates/_ai_powerup_js.html',
  'utf8'
).replace(/^\s*<script>\s*/, '').replace(/<\/script>\s*$/, '');
eval(source);

let failures = 0;
function check(label, condition) {
  console.log((condition ? 'PASS' : 'FAIL') + ' - ' + label);
  if (!condition) failures += 1;
}

initStage9();
check('Migration Log is the primary source', saiState.systems.length === 1);
check('VM inventory is counted', saiState.systems[0].vms === 2);
check('component objects are preserved', saiState.systems[0].components[0].runtime === 'Python');
check('component names are available to cards and plans',
  saiState.systems[0].componentNames.join(',') === 'payments-api,payments-db');
check('data types are inferred from real components',
  saiState.systems[0].dataTypes.includes('database') && saiState.systems[0].dataTypes.includes('APIs'));
check('real systems do not fall back to demos', !saiState.systems[0].isDemo);
check('first Migration Log system is preselected on initial load',
  saiState.selectedSystemId === 'payments');
check('initial load pre-wires the system to AI adoption', adopted && adopted.id === 'payments');
check('Migration Log editor is mounted automatically', migrationEditorMounts === 1);
check('preloaded editor replaces the simple grid',
  elements['sai-systems-grid'].style.display === 'none' &&
  elements['sai-fsm-uat-engine-host'].style.display === 'block');

selectAISystem(saiState.systems[0]);
check('selection is persisted by business-system id', saiState.selectedSystemId === 'payments');
check('selection is pushed into the AI adoption workflow', adopted && adopted.id === 'payments');
check('AI workflow receives declared components', adopted && adopted.components.length === 2);
check('selected sensitivity follows the Migration Log record', saiState.selectedSensitivity === 'high');
check('saved AI SWITCH state keeps the selected system',
  JSON.parse(store[SAI_KEY]).selectedSystemId === 'payments');

console.log(failures ? `\n${failures} FAILURES` : '\nALL AI POWER UP SMOKE TESTS PASSED');
process.exit(failures ? 1 : 0);
