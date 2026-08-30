const { test, expect } = require('@playwright/test');

const CURRENT_MODULE_VERSION = 'v4.5.07';
const CURRENT_VERSION_CODE = '112';

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
        source_hash: 'source-hash', effective_hash: 'effective-hash', content_image_hash: 'content-hash',
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
        schema: 2, device: 'komodo', device_policy: 'external', bound_profile: 'stock', desired_profile: 'disabled',
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
        schema: 2, device: 'caiman', device_policy: 'managed', bound_profile: 'stock', desired_profile: 'disabled',
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
          schema: 2, device: 'caiman', device_policy: 'managed', bound_profile: 'balanced', desired_profile: 'balanced',
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
