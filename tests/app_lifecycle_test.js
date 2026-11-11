'use strict';
// Exercise the production app coordinator with real markup and controlled domain reads.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const webroot = path.resolve(__dirname, '../webroot');
const html = fs.readFileSync(path.join(webroot, 'index.html'), 'utf8')
  .replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '').replace(/<link[^>]+rel="stylesheet"[^>]*>/g, '');
const cases = [];
function test(name, run) { cases.push({ name, run }); }

async function setup(browser, { boot = false, hold = [], tab = 'home' } = {}) {
  const context = await browser.newContext({ bypassCSP: true });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.route('**/*', (route) => route.request().isNavigationRequest()
    ? route.fulfill({ contentType: 'text/html', body: html }) : route.abort());
  await page.goto('http://127.0.0.1:6210/');
  for (const name of ['runtime', 'ui']) {
    await page.addScriptTag({ content: fs.readFileSync(path.join(webroot, 'js', `${name}.js`), 'utf8') });
  }
  await page.evaluate(({ hold, tab }) => {
    const noop = () => {};
    window.lifecycle = { calls: [], held: new Set(hold), pending: [], tab, paused: false, polling: false, hidden: false };
    const s = window.lifecycle;
    Object.defineProperty(document, 'hidden', { get: () => s.hidden });
    Object.defineProperty(document, 'visibilityState', { get: () => s.hidden ? 'hidden' : 'visible' });
    const tasks = new Map();
    const read = (name) => {
      s.calls.push(name);
      if (s.held.has(name)) return new Promise((resolve) => s.pending.push({ name, resolve }));
      return Promise.resolve(true);
    };
    s.finish = (name, value = true) => {
      s.held.delete(name);
      s.pending.filter((item) => item.name === name).forEach((item) => item.resolve(value));
      s.pending = s.pending.filter((item) => item.name !== name);
    };
    registerFeature('core', {
      isWebUiActive: () => !s.hidden && !s.paused, showToast: noop, appendLog: noop,
      markPollFresh: noop, queueNextPoll: noop, computeNextPollDelay: () => 5000,
      noteUserActivity: noop, clearLogs: noop,
      runFeatureTask(key, task) {
        if (tasks.has(key)) return tasks.get(key);
        const promise = Promise.resolve().then(task).finally(() => tasks.delete(key));
        tasks.set(key, promise);
        return promise;
      },
      pauseReadRequests() {
        s.pending.splice(0).forEach((item) => item.resolve(null));
      },
      switchTab(next) { s.tab = next; return requireFeature('app').refreshCurrentTabData(); }
    });
    registerFeature('auth', { initialize: () => Promise.resolve(true) });
    registerFeature('shell', {
      getCurrentTab: () => s.tab, loadInfo: () => read('info'), initializeInteractions: noop,
      setForegroundPaused: (value) => { s.paused = value; }, isForegroundPaused: () => s.paused,
      setLastInteractionAt: noop, isPolling: () => s.polling,
      startPolling: () => { s.polling = true; }, stopPolling: () => { s.polling = false; }
    });
    registerFeature('theme', { initialize: noop, restoreFromServer: noop });
    registerFeature('profile', { initialize: noop, load: () => read('profile'), refresh: () => read('cpu') });
    registerFeature('thermal', { initialize: noop, load: () => read('contract'), refresh: () => read('thermal'), pause: noop });
    registerFeature('memory', { refresh: () => read('memory'), refreshRestrictions: () => read('restrictions') });
    registerFeature('network', { refresh: () => read('network'), refreshDiagnostics: () => read('diagnostics'),
      stopDeviceClock: noop, syncDeviceClockForTab: noop });
    registerFeature('analytics', { isActive: () => false, pause: noop });
    registerFeature('diagnostics', {});
    requireFeature('ui').initialize();
  }, { hold, tab });
  await page.addScriptTag({ content: fs.readFileSync(path.join(webroot, 'app.js'), 'utf8') });
  if (boot) await page.evaluate(() => window.dispatchEvent(new Event('DOMContentLoaded')));
  return { context, page, errors };
}

test('initial components start independently of a held system-info read', async (browser) => {
  const { context, page, errors } = await setup(browser, { boot: true, hold: ['info'] });
  try {
    await page.waitForFunction(() => lifecycle.calls.includes('info'));
    const calls = await page.evaluate(() => lifecycle.calls);
    for (const key of ['profile', 'contract', 'cpu', 'thermal', 'memory', 'network']) assert(calls.includes(key), `${key} blocked by info`);
    assert(!calls.includes('diagnostics'), 'home initialization must not run modem diagnostics');
    assert.deepEqual(errors, []);
  } finally { await context.close(); }
});

test('rapid tab switching starts the new page while the old page is loading', async (browser) => {
  const { context, page } = await setup(browser, { hold: ['cpu'] });
  try {
    await page.evaluate(() => { void requireFeature('app').refreshCurrentTabData(); });
    await page.waitForFunction(() => lifecycle.calls.includes('cpu'));
    await page.evaluate(() => { lifecycle.tab = 'system'; void requireFeature('app').refreshCurrentTabData(); });
    assert((await page.evaluate(() => lifecycle.calls)).includes('restrictions'), 'system page refresh was lost behind home');
  } finally { await context.close(); }
});

test('overlapping page and full refreshes share each in-flight component', async (browser) => {
  const { context, page } = await setup(browser, { hold: ['cpu', 'memory'] });
  try {
    await page.evaluate(() => { void requireFeature('app').refreshCurrentTabData(); });
    await page.waitForFunction(() => lifecycle.calls.includes('cpu'));
    await page.evaluate(() => { lifecycle.tab = 'system'; void requireFeature('app').refreshCurrentTabData(); void requireFeature('app').fullRefresh(); });
    const calls = await page.evaluate(() => lifecycle.calls);
    assert.equal(calls.filter((name) => name === 'cpu').length, 1);
    assert.equal(calls.filter((name) => name === 'memory').length, 1);
    assert(calls.includes('diagnostics'), 'full refresh must include diagnostics without waiting on CPU');
  } finally { await context.close(); }
});

test('resuming after cancellation reloads unfinished current-page components', async (browser) => {
  const { context, page, errors } = await setup(browser, { boot: true, hold: ['cpu'] });
  try {
    await page.waitForFunction(() => lifecycle.calls.includes('cpu'));
    await page.evaluate(() => { lifecycle.hidden = true; document.dispatchEvent(new Event('visibilitychange')); });
    await page.evaluate(() => { lifecycle.held.delete('cpu'); lifecycle.hidden = false; document.dispatchEvent(new Event('visibilitychange')); });
    await page.waitForFunction(() => lifecycle.calls.filter((name) => name === 'cpu').length === 2);
    assert.deepEqual(errors, []);
  } finally { await context.close(); }
});

test('network diagnostics do not gate fast reads on a newly selected page', async (browser) => {
  const { context, page } = await setup(browser, { tab: 'network', hold: ['diagnostics'] });
  try {
    await page.evaluate(() => { void requireFeature('app').refreshCurrentTabData(); });
    await page.waitForFunction(() => lifecycle.calls.includes('network'));
    assert((await page.evaluate(() => lifecycle.calls)).includes('diagnostics'));
    await page.evaluate(() => { lifecycle.tab = 'system'; void requireFeature('app').refreshCurrentTabData(); });
    assert((await page.evaluate(() => lifecycle.calls)).includes('memory'));
  } finally { await context.close(); }
});

(async () => {
  const browser = await chromium.launch({ headless: true,
    ...(process.env.PIXEL_CHROME_PATH ? { executablePath: process.env.PIXEL_CHROME_PATH } : {}) });
  let failed = 0;
  try {
    for (const { name, run } of cases) {
      try { await run(browser); console.log(`PASS ${name}`); }
      catch (error) { failed += 1; console.error(`FAIL ${name}: ${error.message}`); }
    }
  } finally { await browser.close(); }
  console.log(JSON.stringify({ total: cases.length, passed: cases.length - failed, failed }));
  process.exitCode = failed ? 1 : 0;
})().catch((error) => { console.error(error); process.exitCode = 1; });
