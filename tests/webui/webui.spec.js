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
