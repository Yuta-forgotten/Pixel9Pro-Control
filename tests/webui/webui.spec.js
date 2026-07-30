const { test, expect } = require('@playwright/test');

async function expectNoHorizontalOverflow(page) {
  const result = await page.evaluate(() => {
    const viewport = document.documentElement.clientWidth;
    const offenders = [...document.querySelectorAll('button, a, input, select, canvas')]
      .filter((element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden'
          && rect.width > 0 && rect.height > 0
          && (rect.left < -1 || rect.right > viewport + 1);
      })
      .map((element) => ({
        tag: element.tagName,
        id: element.id,
        cls: element.className,
        rect: element.getBoundingClientRect().toJSON(),
      }));
    return { viewport, scrollWidth: document.documentElement.scrollWidth, offenders };
  });
  expect(result.scrollWidth, JSON.stringify(result)).toBeLessThanOrEqual(result.viewport + 1);
  expect(result.offenders, JSON.stringify(result)).toEqual([]);
}

async function expectNoInvalidRenderedValues(page) {
  await expect(page.locator('body')).not.toContainText(/NaN|undefined/);
}

async function waitForWebuiReady(page) {
  await expect(page.locator('#topbar-kicker')).toContainText('Pixel 9 Pro');
  await page.waitForFunction(() => (
    localStorage.getItem('_modVC') === '110'
    && sessionStorage.getItem('_reloaded') === null
  ));
}

test('所有主导航页无浏览器错误和横向溢出', async ({ page }, testInfo) => {
  const browserMessages = [];
  page.on('console', (message) => {
    if (message.type() === 'error' || message.type() === 'warning') {
      browserMessages.push(`${message.type()}: ${message.text()}`);
    }
  });
  page.on('pageerror', (error) => browserMessages.push(`pageerror: ${error.message}`));

  await page.goto('/');
  await waitForWebuiReady(page);
  await expect(page.locator('#profile-list .profile-option')).toHaveCount(3);

  for (const tab of ['home', 'tune', 'network', 'system']) {
    await page.locator(`#tab-${tab}`).click();
    await expect(page.locator(`#page-${tab}`)).toHaveClass(/active/);
    if (tab === 'tune') {
      await expect(page.locator('#thermal-list .thermal-option')).toHaveCount(5);
      expect(await page.locator('#thermal-list .thermal-option').evaluateAll((items) => items.map((item) => Number(item.dataset.offset)))).toEqual([-2, 0, 2, 4, 6]);
    }
    if (tab === 'network') {
      await expect(page.locator('#uecap-btn-group .uecap-btn')).toHaveCount(3);
      expect(await page.locator('#uecap-btn-group .uecap-btn').evaluateAll((items) => items.map((item) => item.dataset.mode))).toEqual(['balanced', 'special', 'universal']);
    }
    if (tab === 'system') {
      await expect(page.locator('#bg-restrict-policy-select option')).toHaveCount(4);
      expect(await page.locator('#bg-restrict-policy-select option').evaluateAll((items) => items.map((item) => item.value))).toEqual(['stop_after_leave', 'block_all', 'block_services', 'bucket']);
      expect(await page.locator('#bg-restrict-delay-select option').evaluateAll((items) => items.map((item) => Number(item.value)))).toEqual([3, 5, 10]);
      await expect(page.locator('#bg-restrict-policy-select')).toHaveValue('stop_after_leave');
      await expect(page.locator('#bg-restrict-delay-select')).toHaveValue('5');
    }
    await expectNoHorizontalOverflow(page);
    await expectNoInvalidRenderedValues(page);
    await page.screenshot({ path: testInfo.outputPath(`${tab}.png`), fullPage: true });
  }

  expect(browserMessages).toEqual([]);
});

test('性能、温控与详情交互保持可用', async ({ page }) => {
  const errors = [];
  page.on('console', (message) => { if (message.type() === 'error') errors.push(message.text()); });
  page.on('pageerror', (error) => errors.push(error.message));

  await page.goto('/');
  await waitForWebuiReady(page);
  await page.locator('#tab-tune').click();
  await page.locator('#profile-list > [data-profile="battery"]').click();
  await expect(page.locator('#profile-list > [data-profile="battery"]')).toHaveClass(/selected/);

  await page.locator('#thermal-list > [data-offset="2"]').click();
  await expect(page.locator('#thermal-list > [data-offset="2"]')).toHaveClass(/selected/);

  await page.locator('#temp-chart-btn').click();
  await expect(page.locator('#modal-detail')).toHaveClass(/history-mode/);
  await expect(page.locator('#modal-detail')).toHaveClass(/open/);
  await page.locator('#detail-close-x').click();
  await expect(page.locator('#modal-detail')).not.toHaveClass(/open/);

  await page.locator('#tab-home').click();
  await page.locator('#energy-btn').click();
  await expect(page.locator('#modal-detail')).toHaveClass(/energy-mode/);
  await expect(page.locator('#modal-detail')).toHaveClass(/open/);
  await page.locator('#detail-close-x').click();
  await expect(page.locator('#modal-detail')).not.toHaveClass(/open/);

  await expectNoHorizontalOverflow(page);
  await expectNoInvalidRenderedValues(page);
  expect(errors).toEqual([]);
});

test('缺失 backend UI contract 时可变选项保持关闭', async ({ page }) => {
  await page.route('**/cgi-bin/set_thermal.sh', (route) => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ offset: 4 }),
  }));
  await page.route('**/cgi-bin/uecap.sh', (route) => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      ok: true,
      policy: 'manual',
      requested_mode: 'balanced',
      active_mode: 'balanced',
    }),
  }));
  await page.route('**/cgi-bin/bg_restrict.sh', (route) => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ ok: true, enabled: 'on', packages: [] }),
  }));

  await page.goto('/');
  await waitForWebuiReady(page);

  await page.locator('#tab-tune').click();
  await expect(page.locator('#thermal-list .thermal-option')).toHaveCount(0);

  await page.locator('#tab-network').click();
  await expect(page.locator('#uecap-btn-group .uecap-btn')).toHaveCount(0);
  await expect(page.locator('#uecap-btn-group')).toBeHidden();
  await expect(page.locator('#uecap-rows')).toContainText('UECap mode contract 无效');

  await page.locator('#tab-system').click();
  await expect(page.locator('#bg-restrict-policy-select option')).toHaveCount(0);
  await expect(page.locator('#bg-restrict-delay-select option')).toHaveCount(0);
  await expect(page.locator('#bg-restrict-policy-select')).toBeDisabled();
  await expect(page.locator('#bg-restrict-delay-select')).toBeDisabled();
  await expect(page.locator('#bg-restrict-rows')).toContainText('后台限制 contract 无效');
});
