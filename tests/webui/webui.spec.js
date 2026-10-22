const { test, expect } = require('@playwright/test');

const fs = require('fs');
const path = require('path');
const moduleProps = Object.fromEntries(fs.readFileSync(path.resolve(__dirname, '../../module.prop'), 'utf8').split(/\r?\n/).filter((line) => /^[a-zA-Z].*=/.test(line)).map((line) => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]));
const CURRENT_MODULE_VERSION = moduleProps.version;
const CURRENT_VERSION_CODE = moduleProps.versionCode;

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
  await page.waitForFunction((versionCode) => (
    localStorage.getItem('_modVC') === versionCode
    && sessionStorage.getItem('_reloaded') === null
  ), CURRENT_VERSION_CODE);
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
  await page.locator('#tab-home').click();
  await expect(page.locator('#swap-rows')).toContainText('mmd');
  await expect(page.locator('#swap-rows')).toContainText('已启用');
  await expect(page.locator('#profile-list .profile-option')).toHaveCount(4);

  for (const tab of ['home', 'tune', 'network', 'system']) {
    await page.locator(`#tab-${tab}`).click();
    await expect(page.locator(`#page-${tab}`)).toHaveClass(/active/);
    if (tab === 'tune') {
      await expect(page.locator('#thermal-list .thermal-option')).toHaveCount(5);
      expect(await page.locator('#thermal-list .thermal-option').evaluateAll((items) => items.map((item) => Number(item.dataset.offset)).filter(Number.isFinite))).toEqual([-2, 2, 4, 6]);
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
  await expect(page.locator('#modal-detail')).toHaveClass(/analytics-mode/);
  await expect(page.locator('#modal-detail')).toHaveClass(/open/);
  await expect(page.locator('.analytics-overview')).toBeVisible();
  await expect(page.locator('.analytics-hero-value')).toHaveText('39.1°C');
  await page.locator('[data-range="120"]').click();
  await expect(page.locator('.analytics-hero-badge')).toHaveText('2 小时');
  await page.locator('[data-thermal-sensor="battery"]').click();
  await expect(page.locator('.analytics-hero-kicker')).toHaveText('最近电池温度');
  await expect(page.locator('.analytics-hero-value')).toHaveText('34.2°C');
  await page.locator('#detail-close-x').click();
  await expect(page.locator('#modal-detail')).not.toHaveClass(/open/);

  await page.locator('#tab-home').click();
  await page.locator('#energy-btn').click();
  await expect(page.locator('#modal-detail')).toHaveClass(/analytics-mode/);
  await expect(page.locator('#modal-detail')).toHaveClass(/open/);
  await expect(page.locator('.analytics-overview')).toBeVisible();
  await expect(page.locator('.analytics-hero-value')).toHaveText('39.1°C');
  await page.locator('#detail-minimize-btn').click();
  await expect(page.locator('#modal-detail')).toHaveClass(/detail-minimized/);
  await page.locator('#detail-minimize-btn').click();
  await expect(page.locator('#modal-detail')).not.toHaveClass(/detail-minimized/);
  await page.locator('#detail-close-x').click();
  await expect(page.locator('#modal-detail')).not.toHaveClass(/open/);

  await expectNoHorizontalOverflow(page);
  await expectNoInvalidRenderedValues(page);
  expect(errors).toEqual([]);
});

test('温度历史区间与传感器切换有记录、有曲线且读取失败后可恢复', async ({ page }, testInfo) => {
  const errors = [];
  const requests = [];
  page.on('pageerror', (error) => errors.push(error.message));
  page.on('request', (request) => requests.push(request.url()));
  await page.goto('/');
  await waitForWebuiReady(page);
  await page.locator('#home-temp-chart-btn').click();
  await expect(page.locator('#detail-title')).toHaveText('温度历史');
  await expect(page.locator('.analytics-hero-value')).toHaveText('39.1°C');
  await expect(page.locator('.analytics-chart-legend')).toContainText('3 个有效点');
  await page.locator('[data-range="120"]').click();
  await expect(page.locator('.analytics-hero-badge')).toHaveText('2 小时');
  await expect(page.locator('.analytics-hero-value')).toHaveText('39.1°C');
  const chartPixels = await page.locator('.analytics-chart-wrap canvas').evaluate((canvas) => {
    const context = canvas.getContext('2d');
    const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
    const sample = document.createElement('canvas').getContext('2d');
    sample.fillStyle = getComputedStyle(document.documentElement).getPropertyValue('--primary').trim();
    sample.fillRect(0, 0, 1, 1);
    const color = sample.getImageData(0, 0, 1, 1).data;
    let matches = 0;
    for (let offset = 0; offset < pixels.length; offset += 4) {
      if (pixels[offset + 3] > 220 && Math.abs(pixels[offset] - color[0]) < 5
        && Math.abs(pixels[offset + 1] - color[1]) < 5 && Math.abs(pixels[offset + 2] - color[2]) < 5) matches += 1;
    }
    return matches;
  });
  expect(chartPixels).toBeGreaterThan(10);
  await page.screenshot({ path: testInfo.outputPath('thermal-history-2h.png'), fullPage: true });
  await page.locator('[data-thermal-sensor="battery"]').click();
  await expect(page.locator('.analytics-hero-value')).toHaveText('34.2°C');
  await expect(page.locator('.analytics-hero-kicker')).toHaveText('最近电池温度');
  await page.locator('[data-range="custom"]').click();
  await expect(page.locator('.analytics-custom-range')).toBeVisible();
  await page.locator('.analytics-custom-range select').selectOption('14400');
  await page.locator('.analytics-custom-range button').click();
  await expect(page.locator('.analytics-hero-badge')).toHaveText('自定义');
  await expect(page.locator('.analytics-hero-value')).toHaveText('34.2°C');

  // Download exactly the displayed window, without another collection request.
  await page.locator('.analytics-export summary').click();
  await page.screenshot({ path: testInfo.outputPath('thermal-history-export.png'), fullPage: true });
  await expect(page.getByRole('button', { name: '导出当前区间' })).toBeEnabled();
  const beforeExport = requests.filter((url) => url.includes('history=1')).length;
  await page.getByLabel('温度历史导出格式').selectOption('json');
  const jsonDownloadPromise = page.waitForEvent('download');
  await page.getByRole('button', { name: '导出当前区间' }).click();
  const jsonDownload = await jsonDownloadPromise;
  const jsonFile = testInfo.outputPath('temperature-export.json');
  await jsonDownload.saveAs(jsonFile);
  const exported = JSON.parse(fs.readFileSync(jsonFile, 'utf8'));
  expect(exported.schema).toBe('pixel9pro.temperature_history.v1');
  expect(exported.sensor).toBe('battery');
  expect(exported.points).toHaveLength(3);
  expect(exported.points[2].temperature_c).toBe(34.2);
  expect(exported.points[2].timestamp_utc).toMatch(/Z$/);
  await page.getByLabel('温度历史导出格式').selectOption('csv');
  const csvDownloadPromise = page.waitForEvent('download');
  await page.getByRole('button', { name: '导出当前区间' }).click();
  const csvDownload = await csvDownloadPromise;
  const csvFile = testInfo.outputPath('temperature-export.csv');
  await csvDownload.saveAs(csvFile);
  expect(fs.readFileSync(csvFile, 'utf8').trim().split('\r\n')).toHaveLength(4);
  expect(requests.filter((url) => url.includes('history=1'))).toHaveLength(beforeExport);
  await page.locator('.analytics-export summary').click();

  await page.route('**/cgi-bin/thermal.sh?history=1&**', (route) => route.fulfill({
    status: 503, contentType: 'application/json', body: JSON.stringify({ ok: false, error: 'fixture read failed' })
  }));
  await page.locator('[data-range="30"]').click();
  await expect(page.locator('.analytics-error')).toContainText('温度历史读取失败');
  await expect(page.getByRole('button', { name: '刷新', exact: true })).toBeEnabled();
  await expect(page.locator('.analytics-export button')).toBeDisabled();
  await page.unroute('**/cgi-bin/thermal.sh?history=1&**');
  await page.getByRole('button', { name: '刷新', exact: true }).click();
  await expect(page.locator('.analytics-hero-value')).toHaveText('34.2°C');
  await expect(page.getByRole('button', { name: '刷新', exact: true })).toBeEnabled();
  await page.route('**/cgi-bin/thermal.sh?history=1&**', async (route) => {
    const original = await route.fetch();
    const data = await original.json();
    await route.fulfill({ json: { ...data, recording_enabled: false, recording_state: 'paused' } });
  });
  await page.getByRole('button', { name: '刷新', exact: true }).click();
  await expect(page.locator('.analytics-status')).toContainText('后台总开关已关闭');
  await expect(page.locator('.analytics-hero-value')).toHaveText('34.2°C');
  await expect(page.locator('.analytics-export button')).toBeEnabled();
  await expect(page.locator('.toast')).toHaveCount(0);
  await page.screenshot({ path: testInfo.outputPath('thermal-history-paused.png'), fullPage: true });
  await page.locator('.analytics-export summary').scrollIntoViewIfNeeded();
  await page.screenshot({ path: testInfo.outputPath('thermal-history-controls.png'), fullPage: true });
  expect(requests.some((url) => /cgi-bin\/(energy|telemetry|power_rank|system_history|thermal_burst|history_policy)\.sh/.test(url))).toBe(false);
  expect(errors).toEqual([]);
  await expectNoHorizontalOverflow(page);
});

test('温度读取失败不隐式清缓存，页面隐藏不继续自动读取', async ({ page }) => {
  await page.goto('/');
  await waitForWebuiReady(page);
  await page.evaluate(() => requireFeature('shell').stopPolling());
  const previous = await page.locator('#home-temp-num').textContent();
  const calls = [];
  await page.route('**/cgi-bin/thermal.sh**', (route) => {
    calls.push({ url: route.request().url(), method: route.request().method() });
    return route.fulfill({ status: 503, contentType: 'application/json', body: JSON.stringify({ ok: false, error: 'fixture sensors unavailable' }) });
  });
  const results = await page.evaluate(async () => [await requireFeature('thermal').refresh(), await requireFeature('thermal').refresh()]);
  expect(results).toEqual([false, false]);
  expect(calls).toHaveLength(2);
  expect(calls.every((call) => call.method === 'GET' && !call.url.includes('fresh='))).toBe(true);
  await expect(page.locator('#home-temp-num')).toHaveText(previous);
  await expect(page.locator('#home-temp-status')).toContainText('保留上次读数');
  await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => true });
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  expect(await page.evaluate(() => requireFeature('thermal').refresh())).toBe(null);
  expect(calls).toHaveLength(2);
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

test('基带状态、UECap ownership 与无线观察结果保持分层', async ({ page }) => {
  await page.goto('/');
  await waitForWebuiReady(page);
  await page.locator('#tab-network').click();

  await expect(page.locator('#baseband-card')).toBeVisible();
  await expect(page.locator('#uecap-btn-group .uecap-btn')).toHaveCount(3);
  await expect(page.locator('#baseband-rows')).toContainText('本次启动已验证');
  await expect(page.locator('#uecap-rows')).toContainText('NR SA');
  await expect(page.locator('#uecap-rows')).toContainText('不要求 EN-DC');
  await expectNoHorizontalOverflow(page);
  await expectNoInvalidRenderedValues(page);
});

test('komodo external/stock 不显示 UECap 写入，但保留独立基带卡和证据', async ({ page }) => {
  await page.route('**/cgi-bin/info.sh', (route) => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      model: 'Pixel 9 Pro XL', version: '17', kernel: '6.1-test', module_version: CURRENT_MODULE_VERSION,
      version_code: CURRENT_VERSION_CODE, httpd_rss_kb: 1240, mem_total_kb: 16384000,
      mem_avail_kb: 9216000, swap_total_kb: 11665408, swap_free_kb: 10321920, uptime_sec: 34567,
      baseband_installed: true, baseband_enabled: true, baseband_runtime_verified: true,
      baseband_version: 'v1.1.0-rc3', baseband_status: {
        installed: true, enabled: true, runtime_verified: true, source: 'active', module_state: 'enabled',
        version: 'v1.1.0-rc3', runtime_status: 'PASS', effective_overlay_verified: 'yes',
        source_contract_verified: 'yes', content_image_verified: 'yes', mount_observed: 'yes',
        migration_state: 'effective_overlay_verified', source_path: '/data/adb/modules/pixel9pro_baseband_trial/system',
        effective_path: '/product,/vendor', content_image: '/data/adb/metamodule/mnt/content.img',
         source_hash: 'source-hash', source_contract_hash: 'source-contract-hash', effective_hash: 'effective-hash', effective_contract_hash: 'effective-contract-hash', content_image_hash: 'content-hash', content_contract_hash: 'content-contract-hash', effective_contract_verified: 'yes', effective_extra_files_allowed: 'yes',
        clean_reinstall_required: false, pending_update: false, pending_update_dir: '',
        runtime_receipt_freshness: 'current_check', prior_receipt_freshness: 'current_boot_verified',
        current_runtime_check_freshness: 'current_check', boot_id: 'test-boot', errors: 'none',
        carrier_settings: { installed: true, count: 3210, carrier_list_sha256: 'carrier-hash' },
        mcfg: { installed: true, count: 5 },
        props: { volte_avail_ovr: '1', wfc_avail_ovr: '1', vt_avail_ovr: '1', apns_conf_sha256: 'apn-hash' },
      },
    }),
  }));
  await page.route('**/cgi-bin/uecap.sh', (route) => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      ok: true, device: 'komodo', device_label: 'Pixel 9 Pro XL', device_policy: 'external',
      contract_result: 'valid', runtime_policy: 'external', policy: 'external', requested_mode: 'disabled',
      manual_mode: 'disabled', active_mode: 'stock', reason: 'device_external_stock', disabled: true,
      disabled_message: 'komodo 使用设备原生 UECap；Control 仅展示状态，不写入 XL payload。',
      target_name: 'PLATFORM_6287228797510365516.binarypb', target_hash: 'stock-hash',
      uecap_contract: { mode_order: [], default_mode: 'disabled' },
      runtime_receipt: {
        schema: 3, device: 'komodo', device_policy: 'external', bound_profile: 'stock', desired_profile: 'disabled',
        modem_load_state: 'not_managed', modem_loaded_profile: 'unknown', functional_state: 'external_or_disabled',
        receipt_freshness: 'missing', actual_rat: 'LTE', radio_observed_state: 'LTE',
        nsa_status: 'not_applicable', nsa_reason: 'no_confirmed_nsa_cell', lte_anchor: 'unknown',
      },
    }),
  }));

  await page.goto('/');
  await waitForWebuiReady(page);
  await page.locator('#tab-network').click();
  await expect(page.locator('#baseband-card')).toBeVisible();
  await expect(page.locator('#uecap-btn-group')).toBeHidden();
  await expect(page.locator('#uecap-rows')).toContainText('device_external_stock');
  await expect(page.locator('#uecap-rows')).toContainText('PLATFORM_6287228797510365516.binarypb');
  await expect(page.locator('#baseband-rows')).toContainText('3210');
  await expectNoHorizontalOverflow(page);
  await expectNoInvalidRenderedValues(page);
});

test('Magisk UECap disabled 不隐藏 standalone baseband，且 LTE 不被判为 Control 失败', async ({ page }) => {
  await page.route('**/cgi-bin/uecap.sh', (route) => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      ok: true, device: 'caiman', device_label: 'Pixel 9 Pro', device_policy: 'managed',
      contract_result: 'valid', runtime_policy: 'disabled', policy: 'disabled', requested_mode: 'disabled',
      manual_mode: 'disabled', active_mode: 'stock', reason: 'magisk_uecap_unavailable', disabled: true,
      disabled_message: 'Magisk managed UECap 不可用；以下只展示设备、modem 和无线观察结果。',
      target_name: 'PLATFORM_9055801516233416490.binarypb', target_hash: 'stock-hash',
      uecap_contract: { mode_order: [], default_mode: 'disabled' },
      runtime_receipt: {
        schema: 3, device: 'caiman', device_policy: 'managed', bound_profile: 'stock', desired_profile: 'disabled',
        modem_load_state: 'not_managed', modem_loaded_profile: 'unknown', functional_state: 'external_or_disabled',
        receipt_freshness: 'missing', actual_rat: 'LTE', radio_observed_state: 'LTE',
        nsa_status: 'not_applicable', nsa_reason: 'no_confirmed_nsa_cell', lte_anchor: 'unknown',
      },
    }),
  }));
  await page.goto('/');
  await waitForWebuiReady(page);
  await page.locator('#tab-network').click();
  await expect(page.locator('#uecap-btn-group')).toBeHidden();
  await expect(page.locator('#uecap-rows')).toContainText('magisk_uecap_unavailable');
  await expect(page.locator('#uecap-rows')).toContainText('LTE / 4G');
  await expect(page.locator('#uecap-rows')).toContainText('当前无线观察结果，不代表 UECap 失败');
  await expect(page.locator('#baseband-card')).toBeVisible();
  await expectNoHorizontalOverflow(page);
  await expectNoInvalidRenderedValues(page);
});

for (const [name, receipt] of [
  ['NR NSA', { actual_rat: 'NR_NSA', radio_observed_state: 'NR_NSA', nsa_status: 'observed', nsa_reason: 'nr_nsa_observed', nr_band: 'n78', lte_anchor: 'observed_or_unknown' }],
  ['unknown radio', { actual_rat: 'UNKNOWN', radio_observed_state: 'UNKNOWN', nsa_status: 'not_applicable', nsa_reason: 'no_confirmed_nsa_cell', nr_band: 'unknown', lte_anchor: 'unknown' }],
]) {
  test(`UECap 无线分类：${name}`, async ({ page }) => {
    await page.route('**/cgi-bin/uecap.sh', (route) => route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        ok: true, device: 'caiman', device_label: 'Pixel 9 Pro', device_policy: 'managed',
        contract_result: 'valid', runtime_policy: 'managed', policy: 'manual', requested_mode: 'balanced',
        manual_mode: 'balanced', active_mode: 'balanced', reason: 'managed_runtime', disabled: false,
        target_name: 'PLATFORM_9055801516233416490.binarypb', target_hash: 'balanced-hash',
        balanced_hash: 'balanced-hash', special_hash: 'special-hash', universal_hash: 'universal-hash',
        uecap_contract: { mode_order: ['balanced', 'special', 'universal'], default_mode: 'balanced' },
        runtime_receipt: {
          schema: 3, device: 'caiman', device_policy: 'managed', bound_profile: 'balanced', desired_profile: 'balanced',
          modem_load_state: 'confirmed_readback', modem_loaded_profile: 'balanced', functional_state: 'verified',
          receipt_freshness: 'current_boot', ...receipt,
        },
      }),
    }));
    await page.goto('/');
    await waitForWebuiReady(page);
    await page.locator('#tab-network').click();
    if (name === 'NR NSA') {
      await expect(page.locator('#uecap-rows')).toContainText('NR NSA');
      await expect(page.locator('#uecap-rows')).toContainText('nr_nsa_observed');
    } else {
      await expect(page.locator('#uecap-rows')).toContainText('尚无可确认的 NR 无线状态');
      await expect(page.locator('#uecap-rows')).toContainText('no_confirmed_nsa_cell');
    }
    await expectNoHorizontalOverflow(page);
    await expectNoInvalidRenderedValues(page);
  });
}

test('stale receipt 与 effective overlay 失败明确要求 clean reinstall', async ({ page }) => {
  await page.route('**/cgi-bin/check_baseband.sh', (route) => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      installed: true, enabled: true, runtime_verified: false, source: 'active', module_state: 'enabled',
      version: 'v1.1.0-rc3', runtime_status: 'FAIL', mount_observed: 'unknown', effective_overlay_verified: 'no',
      source_contract_verified: 'yes', content_image_verified: 'no', migration_state: 'failed',
      source_path: '/data/adb/modules/pixel9pro_baseband_trial/system', effective_path: '/product,/vendor',
      content_image: 'missing', source_hash: 'source-hash', effective_hash: 'unknown', content_image_hash: 'unknown',
      source_tree_hash: 'source-tree-hash', content_tree_hash: 'unknown', effective_contract_hash: 'unknown',
      clean_reinstall_required: true, pending_update: false, pending_update_dir: '',
      runtime_receipt_freshness: 'stale_or_unverified', prior_receipt_freshness: 'cross_boot',
      current_runtime_check_freshness: 'failed', boot_id: 'test-boot', errors: 'content_image_missing,effective_overlay_failed',
      carrier_settings: { installed: true, count: 3210, carrier_list_sha256: 'carrier-hash' },
      mcfg: { installed: true, count: 5 },
      props: { volte_avail_ovr: '1', wfc_avail_ovr: '1', vt_avail_ovr: '1', apns_conf_sha256: 'apn-hash' },
    }),
  }));
  await page.goto('/');
  await waitForWebuiReady(page);
  await page.locator('#tab-network').click();
  await expect(page.locator('#baseband-rows')).toContainText('需要卸载、重启、重装、再重启');
  await expect(page.locator('#baseband-rows')).toContainText('stale_or_unverified');
  await expect(page.locator('#baseband-rows')).toContainText('content_image_missing');
  await expectNoHorizontalOverflow(page);
  await expectNoInvalidRenderedValues(page);
});
