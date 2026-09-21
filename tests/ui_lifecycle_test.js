/* Isolated real-browser regression: production markup/styles/features, no CGI or device. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '..');
const webroot = path.join(root, 'webroot');
const html = fs.readFileSync(path.join(webroot, 'index.html'), 'utf8');
const styles = [...html.matchAll(/<link[^>]+href="([^"]+\.css)[^"]*"/g)]
  .map((match) => fs.readFileSync(path.join(webroot, match[1].replace(/^\//, '')), 'utf8'));
const documentHtml = html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '').replace(/<link[^>]+rel="stylesheet"[^>]*>/g, '');
const results = [];
const filter = process.env.PIXEL_UI_LIFECYCLE_FILTER || '';

async function setup(browser, viewport = { width: 390, height: 844 }) {
  const context = await browser.newContext({ viewport, bypassCSP: true, reducedMotion: 'reduce' });
  const page = await context.newPage();
  page.on('pageerror', (error) => results.push({ error: error.message }));
  // Runtime pins its production origin. Intercept every request before it can
  // reach localhost; this test neither uses nor starts the shared mock server.
  await page.route('**/*', (route) => route.request().isNavigationRequest()
    ? route.fulfill({ contentType: 'text/html', body: documentHtml }) : route.abort());
  await page.goto('http://127.0.0.1:6210/');
  await page.addStyleTag({ content: styles.join('\n') });
  for (const file of ['runtime', 'ui', 'common', 'diagnostics']) {
    await page.addScriptTag({ content: fs.readFileSync(path.join(webroot, 'js', `${file}.js`), 'utf8') });
  }
  await page.evaluate(() => {
    window.testAnalytics = { stop: 0, minimize: 0, resume: 0 };
    registerFeature('analytics', {
      stop() { window.testAnalytics.stop += 1; },
      minimize() { window.testAnalytics.minimize += 1; },
      resume() { window.testAnalytics.resume += 1; }
    });
    registerFeature('thermal', { setPendingChange() {}, stopChart() {}, pauseChart() {}, scheduleChart() {} });
    registerFeature('energy', { stop() {}, pause() {} });
    registerFeature('profile', { getSchedulerBootTargetMode: () => 'pixel' });
    registerFeature('memory', {
      closeSwapTuneModal() {
        refs.swapTuneModal.classList.remove('open');
        requireFeature('ui').popModalIfTop('swapTune');
      }
    });
    requireFeature('ui').initialize();
    const ui = requireFeature('ui');
    document.getElementById('theme-open-btn').addEventListener('click', ui.openThemeSheet);
    ['theme-close-btn', 'theme-close-x'].forEach((id) => document.getElementById(id)?.addEventListener('click', ui.closeThemeSheet));
    ['detail-close-btn', 'detail-close-x'].forEach((id) => document.getElementById(id).addEventListener('click', ui.closeDetailModal));
    document.getElementById('detail-minimize-btn').addEventListener('click', ui.toggleDetailMinimized);
    window.addEventListener('popstate', ui.handlePopState);
    window.testRequests = [];
    window.fetch = (url, options = {}) => new Promise((resolve, reject) => {
      const entry = { url: String(url), method: options.method || 'GET', options, resolve, reject, done: false, aborted: false };
      window.testRequests.push(entry);
      options.signal?.addEventListener('abort', () => {
        entry.aborted = true;
        entry.done = true;
        reject(new DOMException('Aborted', 'AbortError'));
      }, { once: true });
    });
    // The storage key is part of runtime's production token contract.
    sessionStorage.setItem(STORAGE_TOKEN_KEY, 'lifecycle-test-token');
    requireFeature('auth').initialize();
  });
  return { context, page };
}

async function respond(page, body, status = 200) {
  await page.waitForFunction(() => window.testRequests.some((entry) => !entry.done));
  await page.evaluate(({ body, status }) => {
    const entry = window.testRequests.find((item) => !item.done);
    entry.done = true;
    entry.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }));
  }, { body, status });
}

async function test(name, fn) {
  if (filter && !name.includes(filter)) return;
  await fn();
  results.push({ name, status: 'passed' });
  process.stdout.write(`PASS ${name}\n`);
}

(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.PIXEL_CHROME_PATH ? { executablePath: process.env.PIXEL_CHROME_PATH } : {}) });
  try {
    await test('closed dialogs stay out of focus; Tab/Escape restore the opener', async () => {
      const { context, page } = await setup(browser);
      try {
        assert.equal(await page.locator('.modal-wrap[inert]').count(), 4);
        await page.locator('#theme-open-btn').click();
        await page.waitForFunction(() => document.querySelector('#modal-theme').getAttribute('aria-modal') === 'true');
        assert.equal(await page.locator('.app-shell').evaluate((el) => el.inert), true);
        for (let i = 0; i < 12; i += 1) {
          await page.keyboard.press(i % 3 === 0 ? 'Shift+Tab' : 'Tab');
          assert.equal(await page.evaluate(() => document.querySelector('#modal-theme').contains(document.activeElement)), true);
        }
        await page.keyboard.press('Escape');
        await page.waitForFunction(() => document.querySelector('#modal-theme').inert);
        assert.equal(await page.evaluate(() => document.activeElement.id), 'theme-open-btn');
        assert.equal(await page.locator('.app-shell').evaluate((el) => el.inert), false);
        await page.locator('#detail-close-btn').evaluate((el) => el.focus());
        assert.notEqual(await page.evaluate(() => document.activeElement.id), 'detail-close-btn');
      } finally { await context.close(); }
    });

    await test('Back closes only the top dialog and rapid reopen retains a history entry', async () => {
      const { context, page } = await setup(browser);
      try {
        await page.locator('#theme-open-btn').click();
        await page.evaluate(() => requireFeature('ui').openDetail('嵌套详情', '<button>测试动作</button>'));
        await page.evaluate(() => history.back());
        await page.waitForFunction(() => !document.querySelector('#modal-detail').classList.contains('open'));
        assert.equal(await page.locator('#modal-theme').getAttribute('aria-modal'), 'true');
        await page.keyboard.press('Escape');
        await page.waitForFunction(() => history.state?.modal !== 'theme');
        await page.evaluate(() => {
          const ui = requireFeature('ui');
          ui.openDetail('第一次', '<button>第一次</button>');
          ui.closeDetailModal();
          ui.openDetail('第二次', '<button>第二次</button>');
        });
        await page.waitForTimeout(100);
        assert.equal(await page.evaluate(() => history.state?.modal), 'detail');
        assert.equal(await page.locator('#modal-detail').getAttribute('aria-modal'), 'true');
        await page.evaluate(() => history.back());
        await page.waitForFunction(() => !document.querySelector('#modal-detail').classList.contains('open'));
      } finally { await context.close(); }
    });

    for (const [width, scale] of [[320, 1], [320, 2], [427, 1]]) {
      await test(`paused dock / toast / navigation do not overlap at ${width}px and ${scale * 100}% text`, async () => {
        const { context, page } = await setup(browser, { width, height: 900 });
        try {
          await page.evaluate((scale) => {
            document.documentElement.style.fontSize = `${scale * 100}%`;
            const ui = requireFeature('ui');
            ui.openDetail('温度与功耗历史', '<button id="hidden-detail-action">隐藏后的动作</button>');
            refs.detailModal.classList.add('analytics-mode');
          }, scale);
          await page.locator('#detail-minimize-btn').click();
          await page.waitForTimeout(120);
          const geometry = await page.evaluate(() => {
            const rect = (selector) => document.querySelector(selector).getBoundingClientRect().toJSON();
            return { dock: rect('#modal-detail .modal-sheet'), toast: rect('#toast-wrap .toast'), nav: rect('.bottom-nav'),
              modal: document.querySelector('#modal-detail').getAttribute('aria-modal'), role: document.querySelector('#modal-detail').getAttribute('role'),
              shellInert: document.querySelector('.app-shell').inert, calls: window.testAnalytics,
              hiddenBody: document.querySelector('#modal-detail .modal-sheet-body').inert };
          });
          assert.equal(geometry.modal, null);
          assert.equal(geometry.role, 'region');
          assert.equal(geometry.shellInert, false);
          assert.equal(geometry.hiddenBody, true);
          assert.equal(geometry.calls.minimize, 1);
          assert.ok(geometry.toast.bottom <= geometry.dock.top - 8, JSON.stringify(geometry));
          assert.ok(geometry.dock.bottom <= geometry.nav.top - 8, JSON.stringify(geometry));
          assert.ok(geometry.dock.left >= 0 && geometry.dock.right <= width, JSON.stringify(geometry));
          await page.locator('#hidden-detail-action').evaluate((el) => el.focus());
          assert.notEqual(await page.evaluate(() => document.activeElement.id), 'hidden-detail-action');
          await page.locator('#detail-minimize-btn').click();
          assert.equal(await page.locator('#modal-detail').getAttribute('aria-modal'), 'true');
          assert.equal(await page.evaluate(() => window.testAnalytics.resume), 1);
          assert.equal(await page.locator('#detail-close-btn').isVisible(), true);
          await page.locator('#detail-close-x').click();
        } finally { await context.close(); }
      });
    }

    await test('audit opens once, clear is single-flight and refresh removes stale lines', async () => {
      const { context, page } = await setup(browser);
      try {
        await page.evaluate(() => { requireFeature('diagnostics').openAuditLog(); requireFeature('diagnostics').openAuditLog(); });
        assert.equal(await page.evaluate(() => window.testRequests.length), 1);
        await respond(page, { ok: true, lines: ['old-record'] });
        await page.waitForFunction(() => document.querySelector('#audit-log-content').textContent.includes('old-record'));
        page.on('dialog', (dialog) => dialog.accept());
        await page.locator('#audit-log-clear').click();
        await page.locator('#audit-log-clear').evaluate((el) => el.click());
        assert.equal(await page.evaluate(() => window.testRequests.filter((entry) => entry.method === 'POST').length), 1);
        await respond(page, { ok: true, action: 'clear' });
        await page.waitForFunction(() => !document.querySelector('#audit-log-content').textContent.includes('old-record'));
        await respond(page, { ok: true, lines: [] });
        await page.waitForFunction(() => document.querySelector('#audit-log-status').textContent.includes('回读确认当前为空'));
        assert.equal(await page.locator('#audit-log-clear').isEnabled(), true);
        assert.equal(await page.locator('#audit-log-clear').count(), 1);
      } finally { await context.close(); }
    });

    await test('audit errors persist inline and a late read cannot replace another detail', async () => {
      const { context, page } = await setup(browser);
      try {
        await page.evaluate(() => { requireFeature('diagnostics').openAuditLog(); });
        await respond(page, { error: 'Read blocked' }, 500);
        await page.waitForFunction(() => document.querySelector('#audit-log-status').classList.contains('error-panel'));
        assert.match(await page.locator('#audit-log-status').textContent(), /刷新记录/);
        await page.locator('#audit-log-refresh').click();
        await page.evaluate(() => requireFeature('ui').openDetail('其它详情', '<p id="other-detail">必须保留</p>'));
        await page.waitForFunction(() => window.testRequests.at(-1).aborted);
        assert.equal(await page.locator('#other-detail').textContent(), '必须保留');
        assert.equal(await page.locator('#audit-log-view').count(), 0);
      } finally { await context.close(); }
    });

    await test('clear readback failure hides old records and remains actionable', async () => {
      const { context, page } = await setup(browser);
      try {
        await page.evaluate(() => { requireFeature('diagnostics').openAuditLog(); });
        await respond(page, { ok: true, lines: ['stale-before-clear'] });
        await page.waitForFunction(() => !document.querySelector('#audit-log-clear').disabled);
        page.on('dialog', (dialog) => dialog.accept());
        await page.locator('#audit-log-clear').click();
        await respond(page, { ok: true, action: 'clear' });
        await respond(page, { error: 'Readback unavailable' }, 500);
        await page.waitForFunction(() => document.querySelector('#audit-log-status').classList.contains('error-panel'));
        assert.match(await page.locator('#audit-log-status').textContent(), /清理已提交.*回读失败/);
        assert.doesNotMatch(await page.locator('#audit-log-content').textContent(), /stale-before-clear/);
        assert.equal(await page.locator('#audit-log-refresh').isEnabled(), true);
      } finally { await context.close(); }
    });

    await test('a dispatched clear survives close without updating a different detail', async () => {
      const { context, page } = await setup(browser);
      try {
        await page.evaluate(() => { requireFeature('diagnostics').openAuditLog(); });
        await respond(page, { ok: true, lines: ['old-session'] });
        await page.waitForFunction(() => !document.querySelector('#audit-log-clear').disabled);
        page.on('dialog', (dialog) => dialog.accept());
        await page.locator('#audit-log-clear').click();
        await page.evaluate(() => requireFeature('ui').openDetail('其它详情', '<p id="preserved-detail">保持此详情</p>'));
        await respond(page, { ok: true, action: 'clear' });
        await respond(page, { ok: true, lines: [] });
        assert.equal(await page.locator('#preserved-detail').textContent(), '保持此详情');
        assert.equal(await page.locator('#audit-log-content').count(), 0);
        assert.equal(await page.locator('#toast-wrap').textContent(), '');
        assert.equal(await page.evaluate(() => window.testRequests.filter((entry) => entry.method === 'POST').length), 1);
      } finally { await context.close(); }
    });

    await test('audit reopening during a dispatched clear waits for its readback', async () => {
      const { context, page } = await setup(browser);
      try {
        await page.evaluate(() => { requireFeature('diagnostics').openAuditLog(); });
        await respond(page, { ok: true, lines: ['old-session'] });
        await page.waitForFunction(() => !document.querySelector('#audit-log-clear').disabled);
        page.on('dialog', (dialog) => dialog.accept());
        await page.locator('#audit-log-clear').click();
        await page.evaluate(() => {
          requireFeature('ui').closeDetailModal();
          requireFeature('diagnostics').openAuditLog();
        });
        assert.match(await page.locator('#audit-log-status').textContent(), /先前的清理结果/);
        assert.equal(await page.locator('#audit-log-clear').isDisabled(), true);
        assert.equal(await page.evaluate(() => window.testRequests.length), 2);
        await respond(page, { ok: true, action: 'clear' });
        await respond(page, { ok: true, lines: [] });
        await respond(page, { ok: true, lines: ['new-session-record'] });
        await page.waitForFunction(() => document.querySelector('#audit-log-content').textContent.includes('new-session-record'));
        assert.equal(await page.locator('#audit-log-clear').isEnabled(), true);
      } finally { await context.close(); }
    });
    assert.equal(results.filter((item) => item.error).length, 0, JSON.stringify(results.filter((item) => item.error)));
    process.stdout.write(`UI lifecycle browser checks passed: ${results.length}\n`);
  } finally { await browser.close(); }
})().catch((error) => { process.stderr.write(`${error.stack}\n`); process.exitCode = 1; });
