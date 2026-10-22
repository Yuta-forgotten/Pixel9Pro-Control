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

async function setup(browser, viewport = { width: 390, height: 844 }, withToken = true, withMemory = false) {
  const context = await browser.newContext({ viewport, bypassCSP: true, reducedMotion: 'reduce' });
  const page = await context.newPage();
  page.on('pageerror', (error) => results.push({ error: error.message }));
  // Runtime pins its production origin. Intercept every request before it can
  // reach localhost; this test neither uses nor starts the shared mock server.
  await page.route('**/*', (route) => route.request().isNavigationRequest()
    ? route.fulfill({ contentType: 'text/html', body: documentHtml }) : route.abort());
  await page.goto('http://127.0.0.1:6210/');
  await page.addStyleTag({ content: styles.join('\n') });
  for (const file of ['runtime', 'ui', 'common', 'diagnostics', ...(withMemory ? ['memory'] : [])]) {
    await page.addScriptTag({ content: fs.readFileSync(path.join(webroot, 'js', `${file}.js`), 'utf8') });
  }
  await page.evaluate(({ withToken, withMemory }) => {
    window.testAnalytics = { stop: 0, minimize: 0, resume: 0 };
    registerFeature('analytics', {
      stop() { window.testAnalytics.stop += 1; },
      minimize() { window.testAnalytics.minimize += 1; },
      resume() { window.testAnalytics.resume += 1; }
    });
    registerFeature('thermal', { setPendingChange() {}, stopChart() {}, pauseChart() {}, scheduleChart() {} });
    registerFeature('profile', { getSchedulerBootTargetMode: () => 'pixel' });
    if (!withMemory) registerFeature('memory', {
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
    if (withToken) {
      sessionStorage.setItem(STORAGE_TOKEN_KEY, 'lifecycle-test-token');
      requireFeature('auth').initialize();
    }
  }, { withToken, withMemory });
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
    await test('request hub resolves shared request classes and explicit overrides', async () => {
      const { context, page } = await setup(browser);
      try {
        const policies = await page.evaluate(() => {
          const resolve = requireFeature('core').resolveRequestPolicy;
          return {
            snapshot: resolve(API.info),
            history: resolve(`${API.thermal}?history=1&minutes=30`),
            live: resolve(API.thermal),
            fresh: resolve(API.thermalFresh),
            diagnostic: resolve(API.uecap),
            baseband: resolve(API.checkBaseband),
            profile: resolve(API.profile),
            compact: resolve(`${API.profile}?compact=1`),
            mutation: resolve(API.thermalSet, { method: 'POST', body: '{"action":"stop"}' }),
            lifecycle: resolve(API.standbyGuard, { method: 'POST', requestClass: 'lifecycle' }),
            explicit: resolve(API.thermalFresh, { timeoutMs: 1234, queueTimeoutMs: 5678, priority: 'interactive' })
          };
        });
        for (const [key, requestClass] of Object.entries({ snapshot: 'snapshot', history: 'thermalHistory', live: 'thermalLive',
          fresh: 'thermalLive', diagnostic: 'diagnostic', baseband: 'diagnostic', profile: 'diagnostic', compact: 'snapshot',
          mutation: 'mutation', lifecycle: 'lifecycle' })) assert.equal(policies[key].requestClass, requestClass, key);
        assert.equal(policies.history.timeoutMs, 8000);
        assert.equal(policies.live.timeoutMs, 14000);
        assert.equal(policies.fresh.timeoutMs, 14000);
        assert.equal(policies.diagnostic.timeoutMs, 30000);
        assert.equal(policies.baseband.timeoutMs, 20000);
        assert.equal(policies.profile.timeoutMs, 60000);
        assert.equal(policies.compact.timeoutMs, 12000);
        assert.equal(policies.lifecycle.priority, 100);
        assert.equal(policies.explicit.timeoutMs, 1234);
        assert.equal(policies.explicit.queueTimeoutMs, 5678);
        assert.equal(policies.explicit.priority, 90);
      } finally { await context.close(); }
    });

    await test('request hub queue wait preserves a full bounded response body budget', async () => {
      const { context, page } = await setup(browser);
      try {
        await page.clock.install();
        await page.evaluate(() => {
          const core = requireFeature('core');
          for (let i = 0; i < 3; i += 1) core.apiFetch(`/held-${i}`, { timeoutMs: 5000, priority: 'interactive' }).catch(() => {});
          window.bodyResult = null;
          core.apiFetch(`${API.thermal}?history=1`, { timeoutMs: 1000, queueTimeoutMs: 2000 })
            .then((data) => { window.bodyResult = data; }, (error) => { window.bodyResult = { code: error.code }; });
        });
        assert.equal(await page.evaluate(() => requireFeature('core').requestHubState().queued), 1);
        await page.clock.runFor(750);
        await respond(page, { ok: true });
        await page.waitForFunction(() => window.testRequests.length === 4);
        await page.evaluate(() => {
          const entry = window.testRequests.at(-1);
          entry.done = true;
          entry.resolve({ ok: true, status: 200, text: () => new Promise((resolve, reject) => {
            window.finishBody = resolve;
            entry.options.signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
          }) });
        });
        await page.waitForFunction(() => typeof window.finishBody === 'function');
        await page.clock.runFor(400);
        assert.equal(await page.evaluate(() => window.bodyResult), null);
        assert.equal(await page.evaluate(() => window.testRequests.at(-1).aborted), false);
        await page.evaluate(() => window.finishBody('{"ok":true,"source":"history"}'));
        await page.waitForFunction(() => window.bodyResult?.ok === true);
        assert.deepEqual(await page.evaluate(() => window.bodyResult), { ok: true, source: 'history' });

        await page.evaluate(() => {
          window.stalledBodyResult = null;
          requireFeature('core').apiFetch('/stalled-body', { timeoutMs: 100 })
            .catch((error) => { window.stalledBodyResult = error.code; });
          const entry = window.testRequests.at(-1);
          entry.done = true;
          entry.resolve({ ok: true, status: 200, text: () => new Promise((resolve, reject) => {
            entry.options.signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
          }) });
        });
        await page.clock.runFor(101);
        await page.waitForFunction(() => window.stalledBodyResult !== null);
        assert.equal(await page.evaluate(() => window.stalledBodyResult), 'REQUEST_TIMEOUT');
      } finally { await context.close(); }
    });

    await test('request hub distinguishes queue timeout and queued or active cancellation', async () => {
      const { context, page } = await setup(browser);
      try {
        await page.clock.install();
        await page.evaluate(() => {
          const core = requireFeature('core');
          for (let i = 0; i < 3; i += 1) core.apiFetch(`/held-${i}`, { timeoutMs: 5000, priority: 'interactive' }).catch(() => {});
          window.queueResult = null;
          core.apiFetch('/queued-timeout', { timeoutMs: 1000, queueTimeoutMs: 100 })
            .catch((error) => { window.queueResult = { code: error.code, cancelled: core.isRequestCancelled(error) }; });
        });
        await page.clock.runFor(101);
        assert.deepEqual(await page.evaluate(() => window.queueResult), { code: 'REQUEST_QUEUE_TIMEOUT', cancelled: false });
        assert.equal(await page.evaluate(() => window.testRequests.length), 3);
        assert.equal(await page.evaluate(() => requireFeature('core').requestHubState().deduped), 3);
        const cancelled = await page.evaluate(async () => {
          const core = requireFeature('core');
          const controller = new AbortController();
          const result = core.apiFetch('/queued-cancel', { controller }).catch((error) => ({ code: error.code, cancelled: core.isRequestCancelled(error) }));
          controller.abort();
          return result;
        });
        assert.deepEqual(cancelled, { code: 'REQUEST_CANCELLED', cancelled: true });
        assert.equal(await page.evaluate(() => requireFeature('core').requestHubState().queued), 0);
        await respond(page, { ok: true });
        const active = await page.evaluate(async () => {
          const core = requireFeature('core');
          const controller = new AbortController();
          const result = core.apiFetch('/active-cancel', { controller }).catch((error) => ({ code: error.code, cancelled: core.isRequestCancelled(error) }));
          controller.abort();
          return result;
        });
        assert.deepEqual(active, { code: 'REQUEST_CANCELLED', cancelled: true });
        assert.equal(await page.evaluate(() => window.testRequests.at(-1).aborted), true);
        const preaborted = await page.evaluate(async () => {
          const controller = new AbortController();
          controller.abort('PAGE_HIDDEN');
          return requireFeature('core').apiFetch('/preaborted', { controller }).catch((error) => error.code);
        });
        assert.equal(preaborted, 'PAGE_HIDDEN');
        assert.equal(await page.evaluate(() => window.testRequests.length), 4);
        const custom = await page.evaluate(async () => {
          const core = requireFeature('core');
          const controller = new AbortController();
          controller.abort('thermal-history-minimized');
          return core.apiFetch('/custom-abort', { controller })
            .catch((error) => ({ code: error.code, cancelled: core.isRequestCancelled(error) }));
        });
        assert.deepEqual(custom, { code: 'thermal-history-minimized', cancelled: true });
      } finally { await context.close(); }
    });

    await test('request hub limits slow diagnostics while history and snapshots keep capacity', async () => {
      const { context, page } = await setup(browser);
      try {
        await page.evaluate(() => {
          const core = requireFeature('core');
          for (const endpoint of [API.uecap, API.checkBaseband, API.profile]) core.apiFetch(endpoint).catch(() => {});
        });
        assert.equal(await page.evaluate(() => window.testRequests.length), 1);
        assert.equal(await page.evaluate(() => requireFeature('core').requestHubState().queued), 2);
        await page.evaluate(() => {
          const core = requireFeature('core');
          core.apiFetch(API.thermalHistory).catch(() => {});
          core.apiFetch(API.info).catch(() => {});
        });
        assert.deepEqual(await page.evaluate(() => window.testRequests.map((entry) => entry.url)),
          ['/cgi-bin/uecap.sh', '/cgi-bin/thermal.sh?history=1', '/cgi-bin/info.sh']);
        assert.equal(await page.evaluate(() => requireFeature('core').requestHubState().active), 3);
        await respond(page, { ok: true });
        await page.waitForFunction(() => window.testRequests.length === 4);
        assert.equal(await page.evaluate(() => window.testRequests.at(-1).url), '/cgi-bin/check_baseband.sh');
        await respond(page, { ok: true, points: [] });
        await page.waitForFunction(() => requireFeature('core').requestHubState().active === 2);
        assert.equal(await page.evaluate(() => window.testRequests.length), 4);
        await page.evaluate(() => {
          requireFeature('core').apiFetch(API.thermalSet, { priority: 'interactive', scope: 'thermal.mutation.readback' }).catch(() => {});
        });
        assert.equal(await page.evaluate(() => window.testRequests.length), 5);
        assert.equal(await page.evaluate(() => window.testRequests.at(-1).url), '/cgi-bin/set_thermal.sh');
        assert.equal(await page.evaluate(() => requireFeature('core').requestHubState().active), 3);
        assert.equal(await page.evaluate(() => requireFeature('core').requestHubState().queued), 1);
      } finally { await context.close(); }
    });

    await test('request hub merges reads and serializes same resource writes without retry', async () => {
      const { context, page } = await setup(browser);
      try {
        assert.equal(await page.evaluate(() => {
          const core = requireFeature('core');
          const first = core.apiFetch(API.info);
          const second = core.apiFetch(API.info);
          first.catch(() => {});
          return first === second;
        }), true);
        assert.equal(await page.evaluate(() => window.testRequests.length), 1);
        await respond(page, { ok: true });
        await page.waitForFunction(() => requireFeature('core').requestHubState().active === 0);
        await page.evaluate(() => {
          const core = requireFeature('core');
          window.writeResults = [];
          for (const [query, scope] of [['?first=1', 'first'], ['?second=1', 'second']]) {
            core.apiFetch(`${API.standbyGuard}${query}`, { method: 'POST', body: '{}', requestClass: 'lifecycle', scope })
              .then((data) => window.writeResults.push(data), (error) => window.writeResults.push({ status: error.status }));
          }
        });
        assert.equal(await page.evaluate(() => window.testRequests.length), 2);
        assert.equal(await page.evaluate(() => requireFeature('core').requestHubState().queued), 1);
        assert.equal(await page.evaluate(() => 'requestClass' in window.testRequests.at(-1).options || 'scope' in window.testRequests.at(-1).options), false);
        await respond(page, { error: 'Write failed' }, 500);
        await page.waitForFunction(() => window.testRequests.length === 3);
        await respond(page, { ok: true });
        await page.waitForFunction(() => window.writeResults.length === 2 && requireFeature('core').requestHubState().active === 0);
        assert.deepEqual(await page.evaluate(() => window.writeResults), [{ status: 500 }, { ok: true }]);
        assert.equal(await page.evaluate(() => window.testRequests.filter((entry) => entry.method === 'POST').length), 2);
        await page.evaluate(() => {
          window.scopeResults = [];
          for (const endpoint of [API.ntp, API.nrSwitch]) {
            requireFeature('core').apiFetch(endpoint, { method: 'POST', body: '{}', scope: 'shared.settings' })
              .then((data) => window.scopeResults.push(data), () => {});
          }
        });
        assert.equal(await page.evaluate(() => window.testRequests.length), 4);
        assert.equal(await page.evaluate(() => requireFeature('core').requestHubState().queued), 1);
        await respond(page, { ok: true, scope: 1 });
        await page.waitForFunction(() => window.testRequests.length === 5);
        await respond(page, { ok: true, scope: 2 });
        await page.waitForFunction(() => window.scopeResults.length === 2 && requireFeature('core').requestHubState().active === 0);
        assert.deepEqual(await page.evaluate(() => window.scopeResults), [{ ok: true, scope: 1 }, { ok: true, scope: 2 }]);
      } finally { await context.close(); }
    });

    await test('request hub releases completed read deduplication before a consumer requests readback', async () => {
      const { context, page } = await setup(browser);
      try {
        await page.evaluate(() => {
          window.readbackResult = null;
          const core = requireFeature('core');
          core.apiFetch(API.info).then(async () => {
            window.readbackResult = await core.apiFetch(API.info);
          });
        });
        await respond(page, { generation: 1 });
        await page.waitForFunction(() => window.testRequests.length === 2 || window.readbackResult !== null);
        assert.equal(await page.evaluate(() => window.testRequests.length), 2);
        await respond(page, { generation: 2 });
        await page.waitForFunction(() => window.readbackResult !== null);
        assert.deepEqual(await page.evaluate(() => window.readbackResult), { generation: 2 });
      } finally { await context.close(); }
    });

    for (const outcome of ['cancel', 'timeout']) {
      await test(`request hub token ${outcome} does not prompt or dispatch a late mutation`, async () => {
        const { context, page } = await setup(browser, undefined, false);
        try {
          await page.clock.install();
          await page.evaluate((outcome) => {
            window.promptCount = 0;
            window.prompt = () => { window.promptCount += 1; return 'unexpected-late-token'; };
            window.tokenResult = null;
            const controller = new AbortController();
            requireFeature('core').apiFetch(API.standbyGuard, { method: 'POST', body: '{}', timeoutMs: 100, controller })
              .catch((error) => { window.tokenResult = error.code; });
            if (outcome === 'cancel') controller.abort();
          }, outcome);
          if (outcome === 'timeout') await page.clock.runFor(101);
          await page.waitForFunction(() => window.tokenResult !== null);
          assert.equal(await page.evaluate(() => window.tokenResult), outcome === 'cancel' ? 'REQUEST_CANCELLED' : 'REQUEST_TIMEOUT');
          await respond(page, { error: 'Auth unavailable' }, 500);
          await page.waitForFunction(() => requireFeature('core').requestHubState().active === 0);
          assert.equal(await page.evaluate(() => window.promptCount), 0);
          assert.equal(await page.evaluate(() => window.testRequests.filter((entry) => entry.method === 'POST').length), 0);
          assert.equal(await page.evaluate(() => requireFeature('auth').hasToken()), false);
        } finally { await context.close(); }
      });
    }

    await test('request hub invalidates a rejected token before parsing an HTML error body', async () => {
      const { context, page } = await setup(browser);
      try {
        await page.evaluate(() => {
          window.deniedResult = null;
          requireFeature('core').apiFetch(API.standbyGuard, { method: 'POST', body: '{}' })
            .catch((error) => { window.deniedResult = error.status; });
          const entry = window.testRequests.at(-1);
          entry.done = true;
          entry.resolve(new Response('<html>Forbidden</html>', { status: 403 }));
        });
        await page.waitForFunction(() => window.deniedResult !== null);
        assert.equal(await page.evaluate(() => window.deniedResult), 403);
        assert.equal(await page.evaluate(() => requireFeature('auth').hasToken()), false);
        assert.equal(await page.evaluate(() => window.testRequests.length), 1);
      } finally { await context.close(); }
    });

    await test('master background committed cleanup failure updates confirmed state without retrying POST', async () => {
      const { context, page } = await setup(browser);
      try {
        await page.addScriptTag({ content: fs.readFileSync(path.join(webroot, 'js', 'network.js'), 'utf8') });
        await page.evaluate(async () => {
          const initial = { background_enabled: true, background_state: 'running', final: true,
            idle_isolate_mode: 'off', sim2_auto_manage: 'off' };
          window.standbyPosts = [];
          window.fetch = async (url, options = {}) => {
            if (options.method === 'POST') {
              window.standbyPosts.push(JSON.parse(options.body));
              return new Response(JSON.stringify({ ...initial, ok: false, committed: true,
                background_enabled: false, background_state: 'paused', idle_isolate_mode: 'on',
                background_cleanup: 'failed', error: 'background stopped; temporary policy restoration failed; pause intent retained' }), { status: 500 });
            }
            const data = String(url).includes('standby_guard') ? initial
              : String(url).includes('ntp') ? { ntp_server: 'time.android.com', servers: [] } : {};
            return new Response(JSON.stringify(data), { status: 200 });
          };
          await requireFeature('network').refresh();
        });
        assert.equal(await page.locator('#idle-isolate-toggle-label').textContent(), '关闭后台任务');
        await page.evaluate(() => requireFeature('network').toggleIdleIsolateMode());
        assert.equal(await page.locator('#idle-isolate-toggle-label').textContent(), '开启后台任务');
        assert.match(await page.locator('#idle-isolate-desc').textContent(), /后台任务已关闭/);
        assert.match(await page.locator('#idle-isolate-rows').textContent(), /恢复失败/);
        assert.match(await page.locator('#toast-wrap').textContent(), /后台开关已保存.*HTTP 500/);
        assert.deepEqual(await page.evaluate(() => window.standbyPosts), [{ idle_isolate_mode: 'on' }]);
        await page.evaluate(() => requireFeature('network').toggleIdleIsolateMode());
        assert.deepEqual(await page.evaluate(() => window.standbyPosts), [{ idle_isolate_mode: 'on' }, { idle_isolate_mode: 'off' }]);
      } finally { await context.close(); }
    });

    await test('background restriction compact commit stays unconfirmed until a read-only refresh succeeds', async () => {
      const { context, page } = await setup(browser, undefined, true, true);
      try {
        await page.evaluate(async () => {
          window.bgPosts = [];
          window.failBgReadback = false;
          let enabled = 'on';
          window.fetch = async (url, options = {}) => {
            if (options.method === 'POST') {
              window.bgPosts.push(JSON.parse(options.body));
              enabled = 'off';
              window.failBgReadback = true;
              return new Response(JSON.stringify({ ok: true, committed: true, enabled }), { status: 200 });
            }
            if (window.failBgReadback) return new Response('{"ok":false,"error":"readback unavailable"}', { status: 503 });
            return new Response(JSON.stringify({ ok: true, enabled, packages: [], suggestions: [],
              bg_contract: { policy_order: ['stop_after_leave', 'bucket'], allowed_delays: [5], default_policy: 'stop_after_leave', default_delay: 5 } }), { status: 200 });
          };
          await requireFeature('memory').refreshRestrictions();
        });
        assert.equal(await page.locator('#bg-restrict-toggle-label').textContent(), '关闭');
        await page.evaluate(() => requireFeature('memory').toggleBgRestrict());
        assert.match(await page.locator('#bg-restrict-desc').textContent(), /已提交，回读未确认/);
        assert.match(await page.locator('#bg-restrict-rows').textContent(), /readback unavailable/);
        assert.doesNotMatch(await page.locator('#bg-restrict-rows').textContent(), /尚未添加应用/);
        assert.equal(await page.locator('#bg-restrict-toggle-btn').isDisabled(), true);
        assert.match(await page.locator('#toast-wrap').textContent(), /已提交，回读未确认/);
        assert.deepEqual(await page.evaluate(() => window.bgPosts), [{ action: 'toggle' }]);
        await page.evaluate(() => requireFeature('memory').forceRefreshBgRestrict());
        assert.deepEqual(await page.evaluate(() => window.bgPosts), [{ action: 'toggle' }]);
        await page.evaluate(async () => { window.failBgReadback = false; await requireFeature('memory').forceRefreshBgRestrict(); });
        assert.equal(await page.locator('#bg-restrict-toggle-btn').isEnabled(), true);
        assert.equal(await page.locator('#bg-restrict-toggle-label').textContent(), '开启');
        assert.doesNotMatch(await page.locator('#bg-restrict-desc').textContent(), /未确认/);
        assert.deepEqual(await page.evaluate(() => window.bgPosts), [{ action: 'toggle' }]);
      } finally { await context.close(); }
    });

    await test('hidden first load resumes data initialization once without rebinding the UI', async () => {
      const context = await browser.newContext({ bypassCSP: true });
      const page = await context.newPage();
      page.on('pageerror', (error) => results.push({ error: error.message }));
      try {
        await page.route('**/*', (route) => route.request().isNavigationRequest()
          ? route.fulfill({ contentType: 'text/html', body: documentHtml }) : route.abort());
        await page.goto('http://127.0.0.1:6210/');
        for (const file of ['runtime', 'ui', 'common', 'diagnostics']) {
          await page.addScriptTag({ content: fs.readFileSync(path.join(webroot, 'js', `${file}.js`), 'utf8') });
        }
        await page.clock.install();
        await page.evaluate(() => {
          window.initCounts = { profile: 0, thermal: 0, theme: 0, profileLoad: 0, thermalLoad: 0, profileRefresh: 0, thermalRefresh: 0 };
          window.initialContractLoaded = false;
          window.reviewVisible = false;
          Object.defineProperty(document, 'hidden', { configurable: true, get: () => !window.reviewVisible });
          Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => window.reviewVisible ? 'visible' : 'hidden' });
          sessionStorage.setItem(STORAGE_TOKEN_KEY, 'lifecycle-test-token');
          window.fetch = async () => new Response('{"model":"Pixel 9 Pro","module_version":"review"}');
          registerFeature('profile', {
            initialize() { window.initCounts.profile += 1; },
            load() { window.initCounts.profileLoad += 1; return new Promise((resolve) => { window.finishProfileLoad = () => { window.initialContractLoaded = true; resolve(true); }; }); },
            refresh() { window.initCounts.profileRefresh += 1; return Promise.resolve(true); },
            syncOptionalModuleUi() {}
          });
          registerFeature('thermal', {
            initialize() { window.initCounts.thermal += 1; },
            load() { window.initCounts.thermalLoad += 1; return Promise.resolve(true); },
            refresh() { window.initCounts.thermalRefresh += 1; return Promise.resolve(true); }, pause() {}
          });
          registerFeature('theme', { initialize() { window.initCounts.theme += 1; } });
          registerFeature('memory', { refresh: async () => true, refreshRestrictions: async () => true });
          registerFeature('network', { refresh: async () => true, setBasebandBackendState() {}, setBasebandInstalled() {}, syncDeviceClockForTab() {}, stopDeviceClock() {} });
          registerFeature('analytics', { pause() {}, isActive: () => false });
        });
        await page.addScriptTag({ content: fs.readFileSync(path.join(webroot, 'app.js'), 'utf8') });
        await page.evaluate(() => document.dispatchEvent(new Event('DOMContentLoaded', { bubbles: true })));
        assert.deepEqual(results.filter((item) => item.error), []);
        assert.equal(await page.evaluate(() => window.initCounts.profileLoad), 0);
        await page.evaluate(() => {
          window.reviewVisible = true;
          document.dispatchEvent(new Event('visibilitychange'));
          window.dispatchEvent(new Event('pageshow'));
        });
        await page.waitForFunction(() => typeof window.finishProfileLoad === 'function');
        assert.equal(await page.evaluate(() => window.initCounts.profileLoad), 1);
        await page.evaluate(() => window.finishProfileLoad());
        await page.waitForFunction(() => requireFeature('shell').isPolling());
        assert.equal(await page.evaluate(() => window.initialContractLoaded), true);
        assert.deepEqual(await page.evaluate(() => window.initCounts), { profile: 1, thermal: 1, theme: 1, profileLoad: 1, thermalLoad: 1, profileRefresh: 1, thermalRefresh: 1 });
        await page.evaluate(() => {
          window.reviewVisible = false;
          document.dispatchEvent(new Event('visibilitychange'));
          window.reviewVisible = true;
          document.dispatchEvent(new Event('visibilitychange'));
        });
        await page.waitForFunction(() => window.initCounts.profileRefresh === 2);
        assert.equal(await page.evaluate(() => window.initCounts.profileLoad), 1);
        assert.equal(await page.evaluate(() => window.initCounts.profile), 1);
      } finally { await context.close(); }
    });

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
