const fs = require('fs');
const path = require('path');

const root = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const html = fs.readFileSync(path.join(root, 'webroot', 'index.html'), 'utf8');
const app = fs.readFileSync(path.join(root, 'webroot', 'app.js'), 'utf8');
const profileCgi = fs.readFileSync(path.join(root, 'webroot', 'cgi-bin', 'profile.sh'), 'utf8');
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
for (const transitionCopy of [
  '正在停止旧调度器、恢复 CPU 基线并复读关键节点，通常需要数秒。',
  '正在更新 fas-rs 接管策略并核对当前 owner，通常需要数秒。',
  '正在复读前台场景、owner 和关键调度节点，通常需要数秒。',
  '正在应用 profile 并复读关键调度节点，通常需要数秒。',
  '正在应用当前 profile 并复读调度状态，通常需要数秒。',
]) {
  assert(app.includes(transitionCopy), `current strategy transition copy is missing: ${transitionCopy}`);
}
assert(app.includes('function isCurrentStrategyBusy()'), 'current strategy controls must share one busy guard');
assert(app.includes('refs.gameHandoffToggleBtn.disabled = strategyBusy'), 'game handoff must be locked during any strategy transition');
assert(app.includes('refs.profilePolicyManualBtn.disabled = strategyBusy'), 'profile policy must be locked during any strategy transition');

for (const phrase of ['日常推荐', '性能更积极', '适合日常', '日常常用', '温度控制最稳妥', '机身更凉']) {
  assert(!html.includes(phrase) && !app.includes(phrase), `thermal UI must not contain recommendation copy: ${phrase}`);
}

const emitProfileStart = profileCgi.indexOf('emit_profile_state()');
const emitProfileEnd = profileCgi.indexOf('\n}\n', emitProfileStart);
assert(emitProfileStart >= 0 && emitProfileEnd > emitProfileStart, 'profile state emitter is missing');
const emitProfileBody = profileCgi.slice(emitProfileStart, emitProfileEnd);
assert(emitProfileBody.includes('detect_external_scheduler'), 'profile state emitter must detect optional schedulers');
assert(!emitProfileBody.includes('detect_uperf_module'), 'profile state emitter must not scan UGT twice');

const inventoryStart = customize.indexOf('report_optional_module_inventory()');
const inventoryEnd = customize.indexOf('\n}\n', inventoryStart);
assert(inventoryStart >= 0 && inventoryEnd > inventoryStart, 'first-install optional-module inventory is missing');
const inventoryBody = customize.slice(inventoryStart, inventoryEnd);
assert(inventoryBody.includes('UGT:') && inventoryBody.includes('fas-rs:') && inventoryBody.includes('Pixel 9 Pro 基带模块:'), 'installer inventory must report all optional modules independently');
assert(!/https?:\/\//.test(inventoryBody), 'installer inventory must not contain installation links');
assert(customize.includes('if [ "$_is_upgrade" -eq 0 ]; then\n    report_optional_module_inventory'), 'inventory must run on first install');

console.log('optional module UI/install contracts OK');
