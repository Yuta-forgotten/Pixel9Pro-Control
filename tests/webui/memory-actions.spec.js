const { test, expect } = require('@playwright/test');
const pageErrors = new WeakMap();
test.beforeEach(async ({ page }) => {
  const errors = [];
  pageErrors.set(page, errors);
  page.on('pageerror', (error) => errors.push(error.message));
});
test.afterEach(async ({ page }) => { expect(pageErrors.get(page)).toEqual([]); });

// All writes terminate at these per-test host routes. The production DOM,
// handlers, request hub, forms and response rendering remain unchanged.
function gate() {
  let release;
  const promise = new Promise((resolve) => { release = resolve; });
  return { promise, release };
}

async function endpoint(page, name, initial = {}) {
  const api = { state: null, posts: [], post: null };
  await page.route(`**/cgi-bin/${name}.sh*`, async (route) => {
    if (route.request().method() === 'POST') {
      const body = route.request().postDataJSON();
      api.posts.push(body);
      await api.post(route, body);
      return;
    }
    if (!api.state) {
      const original = await route.fetch();
      api.state = { ...await original.json(), ...initial };
    }
    await route.fulfill({ json: api.state });
  });
  return api;
}

async function openSystem(page) {
  await page.goto('/');
  await expect(page.locator('#topbar-kicker')).toContainText('Pixel 9 Pro');
  await page.locator('#tab-system').click();
  await expect(page.locator('#swap-tune-btn')).toBeEnabled();
}

async function openMemory(page) {
  await openSystem(page);
  await page.locator('#swap-tune-btn').click();
  await expect(page.locator('#modal-swap-tune')).toHaveClass(/open/);
}

async function refreshMemoryThroughNavigation(page) {
  await page.locator('#swap-tune-close-x').click();
  await expect(page.locator('#modal-swap-tune')).not.toHaveClass(/open/);
  await page.locator('#tab-home').click();
  await page.locator('#tab-system').click();
}

async function disabledClickDoesNotPost(button, api, count) {
  await expect(button).toBeDisabled();
  await button.click({ force: true });
  expect(api.posts).toHaveLength(count);
}

test('ZRAM容量表单点击提交精确JSON；排队不伪完成，读到终态才解除禁用', async ({ page }) => {
  const api = await endpoint(page, 'swap');
  const held = gate();
  api.post = async (route) => {
    await held.promise;
    api.state = { ...api.state, zram_operation: { id: 'zram-online', phase: 'queued', pending: true } };
    await route.fulfill({ json: { ok: true, mode: 'queued', operation_id: 'zram-online' } });
  };
  await openMemory(page);
  const originalCapacity = await page.locator('#memory-current-capacity').textContent();
  await page.locator('#swap-zram-size-unit').selectOption('percent');
  await page.locator('#swap-zram-size-number').fill('55');
  await page.locator('#swap-zram-algorithm').selectOption('lz4');
  const apply = page.locator('#swap-zram-size-apply-btn');
  await apply.click();
  await expect.poll(() => api.posts.length).toBe(1);
  expect(api.posts[0]).toEqual({ mode: 'zram_online', capacity: '55', unit: 'percent', algorithm: 'lz4' });
  await expect(apply).toHaveText('操作进行中…');
  await expect(apply).toHaveAttribute('aria-busy', 'true');
  await disabledClickDoesNotPost(apply, api, 1);
  held.release();
  await expect(page.locator('#memory-modal-status')).toHaveText('正在应用');
  await expect(apply).toBeDisabled();
  await expect(page.locator('#memory-current-capacity')).toHaveText(originalCapacity);
  api.state = { ...api.state, zram_disksize: 9000000000, zram_algo: 'lz4',
    zram_operation: { id: 'zram-online', phase: 'success', pending: false, reason: 'temporary_until_reboot' } };
  await refreshMemoryThroughNavigation(page);
  await expect(page.locator('#memory-current-compressor')).toHaveText('lz4');
  await page.locator('#swap-tune-btn').click();
  await expect(apply).toBeEnabled();
  expect(api.posts).toHaveLength(1);
});

for (const action of [
  { title: '恢复原始交换区', button: '#memory-restore-zram', mode: 'zram_restore' },
  { title: '恢复原始参数', button: '#swap-toggle-btn', mode: 'restore_system' },
  { title: '恢复中断操作', button: '#memory-recover', mode: 'recover' },
]) {
  test(`${action.title}按钮仅提交对应动作，拒绝响应后控件可重试`, async ({ page }) => {
    const api = await endpoint(page, 'swap', action.mode === 'recover'
      ? { zram_operation: { id: 'interrupted', phase: 'unconfirmed', pending: false } } : {});
    const held = gate();
    api.post = async (route) => {
      await held.promise;
      await route.fulfill({ status: 409, json: { ok: false, error: 'fixture operation unavailable' } });
    };
    if (action.mode === 'restore_system') await openSystem(page);
    else await openMemory(page);
    const button = page.locator(action.button);
    await expect(button).toBeVisible();
    await button.click();
    await expect.poll(() => api.posts.length).toBe(1);
    expect(api.posts[0]).toEqual({ mode: action.mode });
    await disabledClickDoesNotPost(button, api, 1);
    held.release();
    await expect(page.locator('#toast-wrap')).toContainText('内存操作失败');
    await expect(button).toBeEnabled();
    if (action.mode === 'recover') {
      await expect(page.locator('#swap-zram-size-apply-btn')).toBeDisabled();
      await expect(button).toBeVisible();
    }
    expect(api.posts).toHaveLength(1);
  });
}

test('VM数字输入经真实表单提交；失败保留草稿，重试成功渲染后端实际值', async ({ page }) => {
  const api = await endpoint(page, 'swap');
  const held = gate();
  api.post = async (route, body) => {
    if (api.posts.length === 1) {
      await held.promise;
      await route.fulfill({ status: 500, json: { ok: false, error: 'fixture VM rollback complete' } });
    } else {
      api.state = { ...api.state, ...body, vm_effective_state: 'effective' };
      await route.fulfill({ json: { ok: true, state: api.state } });
    }
  };
  await openMemory(page);
  for (const [id, value] of Object.entries({ swappiness: '90', minfree: '70000', watermark: '150', vfs: '120' })) {
    await page.locator(`#swap-number-${id}`).fill(value);
  }
  const apply = page.locator('#swap-custom-apply-btn');
  await apply.click();
  await expect.poll(() => api.posts.length).toBe(1);
  const expected = { mode: 'custom', swappiness: 90, min_free_kbytes: 70000, watermark_scale_factor: 150, vfs_cache_pressure: 120 };
  expect(api.posts[0]).toEqual(expected);
  await disabledClickDoesNotPost(apply, api, 1);
  held.release();
  await expect(page.locator('#toast-wrap')).toContainText('内存操作失败');
  await expect(apply).toBeEnabled();
  await expect(page.locator('#swap-number-swappiness')).toHaveValue('90');
  await expect(page.locator('#swap-number-minfree')).toHaveValue('70000');
  await apply.click();
  await expect.poll(() => api.posts.length).toBe(2);
  expect(api.posts[1]).toEqual(expected);
  await expect(page.locator('#toast-wrap')).toContainText('VM 参数已应用');
  await expect(apply).toBeEnabled();
});

function bgOperation(action, phase, extra = {}) {
  return { id: `bg-${action}`, action, phase, pending: phase === 'queued' || phase === 'running',
    committed: phase === 'success', rollback: 'none', error_code: '', error: '', duration_ms: 1, ...extra };
}

test('后台限制添加与移除从按钮到JSON，接受后保留原列表直到终态', async ({ page }) => {
  const api = await endpoint(page, 'bg_restrict', { enabled: 'on', packages: [], recovery_required: false,
    operation: bgOperation('', 'none') });
  let confirmed;
  let held = gate();
  api.post = async (route, body) => {
    await held.promise;
    api.state = { ok: true, state_pending: true, operation: bgOperation(body.action, 'running') };
    await route.fulfill({ json: { ok: true, accepted: true, final: false, operation: bgOperation(body.action, 'queued') } });
  };
  await openSystem(page);
  await expect(page.locator('#bg-restrict-add-btn')).toBeEnabled();
  confirmed = { ...api.state };
  await page.locator('#bg-restrict-pkg-input').fill('com.example.button');
  await page.locator('#bg-restrict-policy-select').selectOption('stop_after_leave');
  await page.locator('#bg-restrict-delay-select').selectOption('10');
  const add = page.locator('#bg-restrict-add-btn');
  await add.click();
  await expect.poll(() => api.posts.length).toBe(1);
  expect(api.posts[0]).toEqual({ action: 'add', package: 'com.example.button', policy: 'stop_after_leave', delay: 10 });
  await expect(add).toHaveText('添加中…');
  await disabledClickDoesNotPost(add, api, 1);
  held.release();
  await expect(page.locator('#bg-restrict-desc')).toContainText('正在后台执行');
  await expect(add).toBeDisabled();
  await expect(page.locator('#bg-restrict-pkg-input')).toHaveValue('com.example.button');
  await expect(page.locator('[data-package="com.example.button"]')).toHaveCount(0);
  const pkg = { pkg: 'com.example.button', label: 'Fixture', policy: 'stop_after_leave', delay: '10',
    bucket: '45', op_bg: 'ignore', op_any: 'ignore', stop_state: 'untracked' };
  api.state = { ...confirmed, packages: [pkg], operation: bgOperation('add', 'success') };
  await page.locator('#bg-restrict-refresh-btn').click();
  const row = page.locator('[data-package="com.example.button"]');
  await expect(row).toHaveCount(1);
  await expect(page.locator('#bg-restrict-pkg-input')).toHaveValue('');
  held = gate();
  const remove = row.locator('.bg-policy-remove');
  await remove.click();
  await expect.poll(() => api.posts.length).toBe(2);
  expect(api.posts[1]).toEqual({ action: 'remove', package: 'com.example.button' });
  await expect(remove).toHaveText('移除中…');
  await disabledClickDoesNotPost(remove, api, 2);
  held.release();
  await expect.poll(() => api.state.operation.action).toBe('remove');
  await expect(page.locator('#bg-restrict-desc')).toContainText('正在后台执行');
  await expect(row).toHaveCount(1);
  await expect(remove).toBeDisabled();
  api.state = { ...confirmed, packages: [], operation: bgOperation('remove', 'success') };
  await page.locator('#bg-restrict-refresh-btn').click();
  await expect(row).toHaveCount(0);
  await expect(add).toBeEnabled();
  expect(api.posts).toHaveLength(2);
});

test('后台限制添加失败保留包名和选项并恢复重试控件', async ({ page }) => {
  const api = await endpoint(page, 'bg_restrict', { enabled: 'on', packages: [], recovery_required: false,
    operation: bgOperation('', 'none') });
  api.post = async (route) => {
    await route.fulfill({ status: 400, json: { ok: false, error: 'fixture invalid package', error_code: 'BG_INVALID_PACKAGE' } });
  };
  await openSystem(page);
  const add = page.locator('#bg-restrict-add-btn');
  await expect(add).toBeEnabled();
  await page.locator('#bg-restrict-pkg-input').fill('com.example.retained');
  await page.locator('#bg-restrict-policy-select').selectOption('bucket');
  await add.click();
  await expect.poll(() => api.posts.length).toBe(1);
  await expect(page.locator('#toast-wrap')).toContainText('请求未完成');
  await expect(page.locator('#bg-restrict-pkg-input')).toHaveValue('com.example.retained');
  await expect(page.locator('#bg-restrict-policy-select')).toHaveValue('bucket');
  await expect(add).toBeEnabled();
});

test('SIM2自动管理按钮禁重发且以独立GET验证状态，失败保留原开关', async ({ page }) => {
  const api = await endpoint(page, 'standby_guard', { sim2_auto_manage: 'on', final: true });
  let held = gate();
  api.post = async (route, body) => {
    await held.promise;
    if (api.posts.length === 1) {
      await route.fulfill({ status: 500, json: { ok: false, error: 'fixture SIM2 rollback complete' } });
    } else {
      api.state = { ...api.state, ...body };
      await route.fulfill({ json: { ok: true, ...body } });
    }
  };
  await page.goto('/');
  await expect(page.locator('#topbar-kicker')).toContainText('Pixel 9 Pro');
  await page.locator('#tab-network').click();
  const toggle = page.locator('#sim2-auto-toggle-btn');
  await expect(page.locator('#sim2-auto-toggle-label')).toHaveText('关闭');
  await toggle.click();
  await expect.poll(() => api.posts.length).toBe(1);
  expect(api.posts[0]).toEqual({ sim2_auto_manage: 'off' });
  await disabledClickDoesNotPost(toggle, api, 1);
  held.release();
  await expect(page.locator('#toast-wrap')).toContainText('操作失败');
  await expect(toggle).toBeEnabled();
  await expect(page.locator('#sim2-auto-toggle-label')).toHaveText('关闭');
  held = gate();
  await toggle.click();
  await expect.poll(() => api.posts.length).toBe(2);
  expect(api.posts[1]).toEqual({ sim2_auto_manage: 'off' });
  held.release();
  await expect(page.locator('#sim2-auto-toggle-label')).toHaveText('开启');
  await expect(toggle).toBeEnabled();
});
