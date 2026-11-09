'use strict';
// Exercise the actual exported memory feature and its real HTML control IDs.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'webroot/index.html'), 'utf8');
const source = fs.readFileSync(path.join(root, 'webroot/js/memory.js'), 'utf8');
const app = fs.readFileSync(path.join(root, 'webroot/app.js'), 'utf8');
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]);
assert.equal(new Set(ids).size, ids.length, 'HTML IDs must be unique');
class Element {
  constructor() { this.value = ''; this.disabled = false; this.checked = false; this.textContent = ''; this.children = []; this.style = { setProperty() {} }; this.classes = new Set(); this.classList = { add: (v) => this.classes.add(v), remove: (v) => this.classes.delete(v), contains: (v) => this.classes.has(v) }; }
  addEventListener() {}
  setAttribute() {}
  replaceChildren(...items) { this.children = items; }
}
const elements = new Map(ids.map((id) => [id, new Element()]));
function el(id) { assert(elements.has(id), `Missing real HTML control: ${id}`); return elements.get(id); }
const keys = ['swappiness', 'min_free_kbytes', 'watermark_scale_factor', 'vfs_cache_pressure'];
const suffixes = ['swappiness', 'minfree', 'watermark', 'vfs'];
const refs = { swapRows: el('swap-rows'), swapDesc: el('swap-desc'), swapTuneModal: el('modal-swap-tune'),
  swapTuneButton: el('swap-tune-btn'), swapToggleButton: el('swap-toggle-btn'), swapToggleLabel: el('swap-toggle-label'),
  swapZramSizeNumber: el('swap-zram-size-number'), swapZramSizeUnit: el('swap-zram-size-unit'), swapZramSizeApply: el('swap-zram-size-apply-btn'),
  rtZramUsage: el('rt-zram-usage'), rtZramUsageDetail: el('rt-zram-usage-detail'), rtRatio: el('rt-ratio'),
  swapTuneInputs: {}, swapTuneNumbers: {}, swapTuneValues: {} };
keys.forEach((key, i) => { refs.swapTuneInputs[key] = el(`swap-input-${suffixes[i]}`); refs.swapTuneNumbers[key] = el(`swap-number-${suffixes[i]}`); refs.swapTuneValues[key] = el(`swap-value-${suffixes[i]}`); });
const stock = { swappiness: 60, min_free_kbytes: 27386, watermark_scale_factor: 200, vfs_cache_pressure: 100 };
const preset = { size: '50%', algorithm: 'lz77eh', swappiness: 80, min_free_kbytes: 65536, watermark_scale_factor: 200, vfs_cache_pressure: 100 };
const data = { ...stock, mode: 'system', feature_vm: 'system', vm_policy_ready: true, vm_effective_state: 'observed', stock, module_preset: preset,
  zram_algo: 'lz77eh', zram_active_state: 'active', zram_disksize: 9799225344, zram_page_size: 4096,
  mmd_requested_size: '60%', zram_platform_persistent_size: '60%', zram_swap_size_kb: 9569552, zram_swap_kb: 1024,
  zram_algorithms: ['lz77eh', 'lz4'], zram_online_supported: true, zram_operation: { phase: 'none', pending: false },
  memory_boot: { auto_apply: false, vm_enabled: false }, limits: Object.fromEntries(keys.map((key) => [key, { min: key === 'min_free_kbytes' ? 1024 : 0, max: key === 'min_free_kbytes' ? 318985 : 3000, step: 1 }])),
  zram_input_limits: { mb: { min: 0.01, max: 32000 }, percent: { min: 1, max: 200 } } };
const requests = [];
const core = { apiFetch: async (url, options = {}) => { if (options.method === 'POST') { const request = JSON.parse(options.body); requests.push(request); if (request.mode === 'boot_save') { if (request.auto_apply) data.memory_boot.auto_apply = request.auto_apply === 'on'; else data.memory_boot = { ...data.memory_boot, size: `${request.capacity}%`, algorithm: request.algorithm }; } return { ok: true, state: structuredClone(data), ...(request.mode === 'preset' ? { operation_id: 'fixture-operation' } : {}) }; } return structuredClone(data); },
  runFeatureTask: (key, fn) => fn(), appendLog() {}, showToast() {}, buildInfoRow: (label, value) => ({ label, value }),
  fmtBytes: (n) => String(n), escapeHtml: String, queueNextPoll() {}, computeNextPollDelay() { return 1000; }, errorBlock: String };
let feature;
const context = { document: { getElementById: el, createElement: () => new Element() }, refs, SWAP_KEYS: keys,
  API: { swap: '/cgi-bin/swap.sh' }, POLL_MIN_DELAY_MS: 1000,
  requireFeature: (name) => name === 'core' ? core : { pushModalState() {}, popModalIfTop() {}, syncHeroDesc() {} },
  registerFeature: (name, value) => { if (name === 'memory') feature = value; } };
vm.runInNewContext(source, context, { filename: 'memory.js' });
(async () => {
  assert.equal(await feature.refresh(true), true);
  feature.openSwapTuneModal();
  assert.equal(el('swap-zram-size-number').value, '60');
  feature.fillModulePreset();
  assert.equal(el('swap-zram-size-number').value, '50', 'fill uses module preset, not the current 60% request');
  assert.equal(el('swap-zram-algorithm').value, 'lz77eh');
  keys.forEach((key) => assert.equal(Number(refs.swapTuneNumbers[key].value), preset[key]));
  await feature.applyModulePreset();
  assert.equal(requests.at(-1).mode, 'preset', 'apply uses the backend module preset route');
  assert(app.includes("memory-preset-fill').addEventListener('click', appFeatures.memory.fillModulePreset)"));
  assert(app.includes("memory-preset-apply').addEventListener('click', appFeatures.memory.applyModulePreset)"));
  await feature.saveMemoryBoot();
  assert.equal(requests.at(-1).capacity, '50');
  assert.equal('auto_apply' in requests.at(-1), false, 'save must not turn on automatic application');
  assert.equal(data.memory_boot.auto_apply, false);
  el('memory-auto-apply').checked = true;
  await feature.toggleMemoryAuto();
  assert.deepEqual(requests.at(-1), { mode: 'boot_save', auto_apply: 'on' }, 'toggle only changes the switch');
  feature.setSwapTuneValues(stock);
  assert.equal(Number(refs.swapTuneNumbers.swappiness.value), 60, 'system values remain a distinct action');
  console.log(JSON.stringify({ ok: true, assertions: 16, checks: ['HTML bindings', 'preset fill/apply consistency', 'boot save/toggle separation', 'system values remain separate'] }));
})().catch((error) => { console.error(error); process.exitCode = 1; });
