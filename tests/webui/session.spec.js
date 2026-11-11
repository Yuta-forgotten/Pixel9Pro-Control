const { test, expect } = require('@playwright/test');

test('调度完整读取失败明确提示，恢复后清除对应错误而不抹掉操作反馈', async ({ page }) => {
  let failFullRead = true;
  let fullReads = 0;
  await page.route('**/cgi-bin/profile.sh*', (route) => {
    if (new URL(route.request().url()).searchParams.has('compact')) return route.continue();
    fullReads += 1;
    return failFullRead ? route.fulfill({ status: 503, json: { ok: false, error: 'fixture full read failed' } }) : route.continue();
  });
  await page.goto('/');
  await expect(page.locator('#profile-operation-notice')).toContainText('调度完整配置读取失败');
  failFullRead = false;
  await page.evaluate(() => requireFeature('profile').load());
  await expect(page.locator('#profile-operation-notice')).toHaveText('');
  await expect(page.locator('#profile-operation-notice')).toBeHidden();
  const before = fullReads;
  await page.evaluate(async () => {
    const notice = document.getElementById('profile-operation-notice');
    delete notice.dataset.readFailure; notice.hidden = false; notice.textContent = 'fixture 操作反馈待确认';
    await requireFeature('profile').load();
  });
  await expect.poll(() => fullReads).toBe(before + 1);
  await expect(page.locator('#profile-operation-notice')).toHaveText('fixture 操作反馈待确认');
});

test('随机查询参数不隔离模块状态、审计日志和浏览器操作记录', async ({ page, context }) => {
  const auditLines = ['module-audit-shared-across-urls'];
  await context.route('**/cgi-bin/audit_log.sh*', (route) => route.fulfill({
    json: { ok: true, lines: auditLines },
  }));
  await context.addInitScript(() => {
    window.tokenBeforeInitialization = sessionStorage.getItem('pixel9pro_webui_token');
  });
  await page.goto('/?cache=first');
  await expect(page.locator('#topbar-kicker')).toContainText('Pixel 9 Pro');
  await page.evaluate(async () => {
    requireFeature('core').appendLog('query-storage-regression', 'ok');
    await requireFeature('core').apiFetch(API.standbyGuard, {
      method: 'POST', body: JSON.stringify({ idle_isolate_mode: 'on' }),
    });
  });
  const token = await page.evaluate(() => sessionStorage.getItem('pixel9pro_webui_token'));
  expect(token).toBeTruthy();

  await page.goto('/?cache=second');
  await expect(page.locator('#topbar-kicker')).toContainText('Pixel 9 Pro');
  expect(await page.evaluate(() => window.tokenBeforeInitialization)).toBe(token);
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('pixel9pro_runtime_log_v2'))
    .some((entry) => entry.text === 'query-storage-regression'))).toBe(true);
  expect(await page.evaluate(async () => (await requireFeature('core').apiFetch(API.standbyGuard)).background_enabled)).toBe(false);
  expect(await page.evaluate(async () => (await requireFeature('core').apiFetch(API.auditLog)).lines)).toEqual(auditLines);

  const otherPage = await context.newPage();
  await otherPage.goto('/?cache=third');
  await expect(otherPage.locator('#topbar-kicker')).toContainText('Pixel 9 Pro');
  expect(await otherPage.evaluate(() => window.tokenBeforeInitialization)).toBeNull();
  expect(await otherPage.evaluate(() => sessionStorage.getItem('pixel9pro_webui_token'))).toBe(token);
  expect(await otherPage.evaluate(() => JSON.parse(localStorage.getItem('pixel9pro_runtime_log_v2'))
    .some((entry) => entry.text === 'query-storage-regression'))).toBe(true);
  expect(await otherPage.evaluate(async () => (await requireFeature('core').apiFetch(API.standbyGuard)).background_enabled)).toBe(false);
  expect(await otherPage.evaluate(async () => (await requireFeature('core').apiFetch(API.auditLog)).lines)).toEqual(auditLines);
  await page.evaluate(() => requireFeature('core').appendLog('interleaved-log-A', 'ok'));
  await otherPage.evaluate(() => requireFeature('core').appendLog('interleaved-log-B', 'ok'));
  const sharedEntries = await page.evaluate(() => JSON.parse(localStorage.getItem('pixel9pro_runtime_log_v2')).map((entry) => entry.text));
  expect(sharedEntries).toContain('interleaved-log-A');
  expect(sharedEntries).toContain('interleaved-log-B');
  await expect.poll(() => page.evaluate(() => refs.logInner.textContent)).toContain('interleaved-log-B');
  await expect.poll(() => otherPage.evaluate(() => refs.logInner.textContent)).toContain('interleaved-log-A');
  await otherPage.evaluate(() => requireFeature('core').apiFetch(API.standbyGuard, {
    method: 'POST', body: JSON.stringify({ idle_isolate_mode: 'off' }),
  }));
  await otherPage.close();
});
