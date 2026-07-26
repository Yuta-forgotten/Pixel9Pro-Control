const fs = require('fs');
const path = require('path');

const root = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const html = fs.readFileSync(path.join(root, 'webroot', 'index.html'), 'utf8');
const app = fs.readFileSync(path.join(root, 'webroot', 'app.js'), 'utf8');
const customize = fs.readFileSync(path.join(root, 'customize.sh'), 'utf8');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const htmlContracts = [
  [/<div class="preference-group" id="external-scheduler-controls" data-module-visible="ugt\|fas" hidden>/, 'external scheduler group must default hidden'],
  [/<div class="ctrl-row" id="sched-owner-row" data-module-visible="ugt" hidden>/, 'UGT daily owner row must require UGT'],
  [/<div class="ctrl-row" id="game-handoff-row" data-module-visible="fas" hidden>/, 'fas-rs handoff row must require fas-rs'],
  [/<div class="ctrl-row" id="owner-arbiter-row" data-module-visible="fas" hidden>/, 'fas-rs arbiter row must require fas-rs'],
  [/<article class="surface-card preference-card" id="baseband-card" data-module-visible="baseband" hidden>/, 'baseband card must default hidden'],
];
for (const [pattern, message] of htmlContracts) assert(pattern.test(html), message);

assert(app.includes("document.querySelectorAll('[data-module-visible]')"), 'generic optional-module visibility binding is missing');
assert(app.includes('baseband: state.basebandInstalled && state.deviceModel === \'Pixel 9 Pro\''), 'baseband visibility must require the supported device and installed module');
assert(app.includes('ugt: state.uperfDetected') && app.includes('fas: state.fasRsDetected'), 'UGT/fas-rs visibility must use independent detection flags');
assert(app.includes('if (!state.basebandInstalled)'), 'baseband detail fetch must be skipped when the module is absent');

const inventoryStart = customize.indexOf('report_optional_module_inventory()');
const inventoryEnd = customize.indexOf('\n}\n', inventoryStart);
assert(inventoryStart >= 0 && inventoryEnd > inventoryStart, 'first-install optional-module inventory is missing');
const inventoryBody = customize.slice(inventoryStart, inventoryEnd);
assert(inventoryBody.includes('UGT:') && inventoryBody.includes('fas-rs:') && inventoryBody.includes('Pixel 9 Pro 基带模块:'), 'installer inventory must report all optional modules independently');
assert(!/https?:\/\//.test(inventoryBody), 'installer inventory must not contain installation links');
assert(customize.includes('if [ "$_is_upgrade" -eq 0 ]; then\n    report_optional_module_inventory'), 'inventory must run on first install');

console.log('optional module UI/install contracts OK');
