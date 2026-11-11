'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../webroot');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8')
  .replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '').replace(/<link[^>]+rel="stylesheet"[^>]*>/g, '');

async function setup(browser) {
  const page = await browser.newPage({ bypassCSP: true });
  await page.route('**/*', (route) => route.fulfill({ contentType: 'text/html', body: html }));
  await page.goto('http://127.0.0.1:6210/');
  for (const name of ['runtime', 'ui', 'memory']) {
    await page.addScriptTag({ content: fs.readFileSync(path.join(root, 'js', `${name}.js`), 'utf8') });
  }
  await page.evaluate(async () => {
    const s = window.draftTest = { policy: 'bucket', operation: { id: '', phase: 'none', pending: false }, posts: [] };
    registerFeature('thermal', { syncHeroDesc() {} });
    registerFeature('core', {
      runFeatureTask: (key, task) => task(), showToast() {}, appendLog() {}, queueNextPoll() {},
      isWebUiActive: () => true, isRequestCancelled: () => false, buildInfoRow: () => document.createElement('div'),
      async apiFetch(url, options = {}) {
        if (options.method === 'POST') {
          s.posts.push(JSON.parse(options.body));
          s.operation = { id: `operation-${s.posts.length}`, phase: 'queued', pending: true, committed: false, rollback: 'none', error: '' };
          return { ok: true, accepted: true, final: false, operation: { ...s.operation } };
        }
        if (s.operation.pending) return { ok: true, state_pending: true, operation: { ...s.operation } };
        const data = { ok: true, enabled: 'on', packages: [{ pkg: 'com.example.test', label: 'Test', policy: s.policy, delay: 5,
          bucket: 'rare', op_bg: 'ignore', op_any: 'ignore', stop_state: 'pending', runtime_freshness: 'last_verified' }],
          suggestions: [], bg_contract: { policy_order: ['bucket', 'stop_after_leave', 'block_all'], allowed_delays: [5, 10],
            default_policy: 'bucket', default_delay: 5 }, operation: { ...s.operation } };
        if (s.invalidPackages === 'missing') delete data.packages;
        if (s.invalidPackages === 'malformed') data.packages = {};
        return data;
      }
    });
    requireFeature('ui').initialize();
    await requireFeature('memory').refreshRestrictions();
    s.select = document.querySelector('#bg-restrict-rows .bg-policy-select');
    s.row = document.querySelector('#bg-restrict-rows .bg-policy-row');
    s.change = (policy) => { s.select.value = policy; s.select.dispatchEvent(new Event('change')); };
    s.change('stop_after_leave');
    document.querySelector('#bg-restrict-rows .bg-policy-save').click();
  });
  await page.waitForFunction(() => draftTest.operation.pending && document.querySelector('#bg-restrict-toggle-label').textContent === '等待确认');
  return page;
}

async function finish(page, phase) {
  await page.evaluate(async (phase) => {
    draftTest.policy = phase === 'success' ? 'stop_after_leave' : 'bucket';
    draftTest.operation = { ...draftTest.operation, phase, pending: false, committed: phase === 'success',
      rollback: phase === 'failed' ? 'complete' : 'none', error: phase === 'failed' ? 'fixture apply failed' : '' };
    await requireFeature('memory').forceRefreshBgRestrict();
  }, phase);
}

const scenarios = [
  ['pending edit back to the original value remains an unsaved draft', async (page) => {
    await page.evaluate(() => draftTest.change('bucket'));
    await finish(page, 'success');
    assert.equal(await page.locator('.bg-policy-row .bg-policy-select').inputValue(), 'bucket');
    assert.equal(await page.locator('.bg-policy-save').isEnabled(), true);
    assert.match(await page.locator('.bg-policy-detail').textContent(), /延时休眠/);
    assert.match(await page.locator('.bg-policy-status').textContent(), /等待休眠/);
  }],
  ['pending edit to a third value remains an unsaved draft', async (page) => {
    await page.evaluate(() => draftTest.change('block_all'));
    await finish(page, 'success');
    assert.equal(await page.locator('.bg-policy-row .bg-policy-select').inputValue(), 'block_all');
    assert.equal(await page.locator('.bg-policy-save').isEnabled(), true);
  }],
  ['a preserved row compares later edits with the latest confirmed baseline', async (page) => {
    await page.evaluate(() => draftTest.change('block_all'));
    await finish(page, 'success');
    assert.equal(await page.evaluate(() => draftTest.row === document.querySelector('.bg-policy-row')), true);
    assert.equal(await page.evaluate(() => draftTest.select === document.querySelector('.bg-policy-row .bg-policy-select')), true);
    await page.evaluate(() => draftTest.change('stop_after_leave'));
    assert.equal(await page.locator('.bg-policy-save').isDisabled(), true, 'confirmed choice is no longer dirty');
    await page.evaluate(() => draftTest.change('bucket'));
    assert.equal(await page.locator('.bg-policy-save').isEnabled(), true, 'original pre-transaction choice is now a new edit');
  }],
  ['failed update preserves the submitted draft and later pending edits', async (page) => {
    await page.evaluate(() => draftTest.change('block_all'));
    await finish(page, 'failed');
    assert.equal(await page.locator('.bg-policy-row .bg-policy-select').inputValue(), 'block_all');
    assert.equal(await page.locator('.bg-policy-save').isEnabled(), true);
    assert.match(await page.locator('#bg-restrict-desc').textContent(), /fixture apply failed/);
  }],
  ['failed update without further editing retains its submitted draft', async (page) => {
    await finish(page, 'failed');
    assert.equal(await page.locator('.bg-policy-row .bg-policy-select').inputValue(), 'stop_after_leave');
    assert.equal(await page.locator('.bg-policy-save').isEnabled(), true);
  }],
  ['successful update clears only the matching submitted draft', async (page) => {
    await finish(page, 'success');
    assert.equal(await page.locator('.bg-policy-row .bg-policy-select').inputValue(), 'stop_after_leave');
    assert.equal(await page.locator('.bg-policy-save').isDisabled(), true);
  }],
  ...['missing', 'malformed'].map((invalidPackages) => [
    `${invalidPackages} packages reports an error without replacing the last list`, async (page) => {
      await page.evaluate((kind) => { draftTest.invalidPackages = kind; }, invalidPackages);
      await finish(page, 'success');
      assert.equal(await page.locator('.bg-policy-row').count(), 1);
      assert.doesNotMatch(await page.locator('#bg-restrict-rows').textContent(), /尚未添加应用/);
      assert.match(await page.locator('#bg-restrict-desc').textContent(), /缺少有效的应用列表/);
      assert.equal(await page.locator('.bg-policy-save').isDisabled(), true);
      assert.equal(await page.locator('#bg-restrict-toggle-btn').isDisabled(), true);
    }
  ])
];

(async () => {
  const browser = await chromium.launch({ headless: true,
    ...(process.env.PIXEL_CHROME_PATH ? { executablePath: process.env.PIXEL_CHROME_PATH } : {}) });
  let failed = 0;
  try {
    for (const [name, run] of scenarios) {
      const page = await setup(browser);
      try { await run(page); assert.equal(await page.evaluate(() => draftTest.posts.length), 1); console.log(`PASS ${name}`); }
      catch (error) { failed += 1; console.error(`FAIL ${name}: ${error.message}`); }
      finally { await page.context().close(); }
    }
  } finally { await browser.close(); }
  console.log(JSON.stringify({ total: scenarios.length, passed: scenarios.length - failed, failed }));
  process.exitCode = failed ? 1 : 0;
})().catch((error) => { console.error(error); process.exitCode = 1; });
