'use strict';
const { test, expect } = require('@playwright/test');

// Every device-writing endpoint used here is intercepted. Only the existing
// local mock server supplies initial GET fixtures and static production assets.
async function setup(page, overrides = {}) {
  const baseline = await (await page.request.get('/cgi-bin/profile.sh')).json();
  const state = {
    ...baseline, scheduler_mode: 'active', scheduler_capability: 'supported',
    policy: 'manual', sched_owner: 'pixel', sched_effective_owner: 'pixel',
    game_handoff_policy: 'fas_rs', scheduler_operation: { id: '', kind: '', phase: 'none', pending: false, result_code: 0 },
    ...overrides
  };
  const calls = [];
  let releasePost;
  let nextResponse;
  let failReadback = false;
  const route = async (request) => {
    const method = request.request().method();
    if (method === 'GET') {
      return failReadback
        ? request.fulfill({ status: 503, json: { ok: false, error: 'fixture readback unavailable' } })
        : request.fulfill({ json: state });
    }
    calls.push({ endpoint: new URL(request.request().url()).pathname, body: request.request().postDataJSON() });
    await new Promise((resolve) => { releasePost = resolve; });
    await request.fulfill(nextResponse);
  };
  await page.route('**/cgi-bin/profile.sh*', route);
  await page.route('**/cgi-bin/owner_arbiter.sh*', route);
  await page.route('**/cgi-bin/reboot.sh*', route);
  await page.goto('/');
  await page.locator('#tab-tune').click();
  await expect(page.locator('#profile-policy-auto-btn')).toBeEnabled();
  return {
    state, calls,
    failReadback() { failReadback = true; },
    async reply(payload, status = 200) {
      await expect.poll(() => typeof releasePost).toBe('function');
      nextResponse = { status, json: payload };
      const resolve = releasePost; releasePost = null; resolve();
    }
  };
}

async function clickAndHold(page, harness, selector, body, feedback, feedbackSelector = selector) {
  await page.locator(selector).click();
  await expect.poll(() => harness.calls.length).toBe(1);
  expect(harness.calls[0].body).toEqual(body);
  await expect(page.locator(selector)).toBeDisabled();
  if (feedback) await expect(page.locator(feedbackSelector)).toContainText(feedback);
  await page.locator(selector).evaluate((button) => { button.click(); button.click(); });
  expect(harness.calls).toHaveLength(1);
  await page.locator('#tab-network').click();
  await expect(page.locator('#page-network')).toHaveClass(/active/);
  await page.locator('#tab-tune').click();
  expect(harness.calls).toHaveLength(1);
}

async function refreshProfileViaNavigation(page) {
  await page.locator('#tab-network').click();
  await page.locator('#tab-tune').click();
}

for (const policy of ['auto', 'manual']) {
  for (const outcome of ['success', 'failure']) {
    test(`调度方式 ${policy} ${outcome}：真实点击即时反馈、单次提交、导航和回读`, async ({ page }) => {
      const before = policy === 'auto' ? 'manual' : 'auto';
      const h = await setup(page, { policy: before });
      const selector = `#profile-policy-${policy}-btn`;
      await clickAndHold(page, h, selector, { policy }, '正在切换调度方式', '#perf-current-name');
      if (outcome === 'success') {
        h.state.policy = policy;
        await h.reply({ ...h.state, ok: true, final: true });
      } else await h.reply({ ok: false, error: 'fixture policy rejected' }, 500);
      await expect(page.locator(selector)).toBeEnabled();
      await expect(page.locator(`#profile-policy-${outcome === 'success' ? policy : before}-btn`)).toHaveAttribute('aria-pressed', 'true');
      expect(h.calls).toHaveLength(1);
      if (outcome === 'failure') await expect(page.locator('#toast-wrap')).toContainText('请求失败');
    });
  }
}

test('调度方式已确认提交不被失败的补读改成持续等待', async ({ page }) => {
  const h = await setup(page);
  await clickAndHold(page, h, '#profile-policy-auto-btn', { policy: 'auto' }, '正在切换调度方式', '#perf-current-name');
  h.state.policy = 'auto';
  h.failReadback();
  await h.reply({ ...h.state, ok: true, final: true });
  await expect(page.locator('#profile-policy-auto-btn')).toBeEnabled();
  await expect(page.locator('#profile-policy-auto-btn')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#profile-operation-notice')).toContainText(/失败|未确认/);
  expect(h.calls).toHaveLength(1);
});

for (const outcome of ['success', 'failure']) {
  test(`基础调度切换 ${outcome}：保存与生效分开，失败释放按钮`, async ({ page }) => {
    const h = await setup(page);
    await clickAndHold(page, h, '#sched-owner-toggle-btn', { sched_owner: 'external' }, '切换中');
    if (outcome === 'success') {
      h.state.sched_owner = 'external';
      h.state.scheduler_boot = { ...h.state.scheduler_boot, target_mode: 'ugt', phase: 'pending_reboot', final: 'no', ok: 'pending', reboot_required: 'yes' };
      await h.reply({ ...h.state, ok: true, final: false, reboot_required: true });
      await expect(page.locator('#modal-reboot')).toHaveClass(/open/);
      await expect(page.locator('#sched-owner-label')).toContainText('重启后生效');
      expect(await page.evaluate(() => requireFeature('profile').getThermalContext().schedEffectiveOwner)).toBe('pixel');
      await page.locator('#reboot-later-btn').click();
      await expect(page.locator('#modal-reboot')).not.toHaveClass(/open/);
      await expect(page.locator('#sched-owner-toggle-btn')).toContainText('取消切换');
    } else {
      await h.reply({ ok: false, error: 'fixture owner rejected' }, 500);
      await expect(page.locator('#modal-reboot')).not.toHaveClass(/open/);
      await expect(page.locator('#sched-owner-toggle-btn')).toContainText('切换到 UGT');
    }
    await expect(page.locator('#sched-owner-toggle-btn')).toBeEnabled();
    expect(h.calls).toHaveLength(1);
  });
}

const asyncActions = [
  { name: '重新检查', selector: '#scheduler-retry-btn', body: { scheduler_action: 'retry' }, kind: 'retry', feedback: '检查中' },
  { name: '游戏自动接管', selector: '#game-handoff-toggle-btn', body: { game_handoff: 'off' }, kind: 'handoff', feedback: '保存中' },
  { name: '立即检查游戏接管', selector: '#owner-arbiter-tick-btn', body: { action: 'tick' }, kind: 'tick', feedback: '检查中' }
];
for (const action of asyncActions) {
  for (const outcome of ['success', 'failed']) {
    test(`${action.name} accepted→${outcome}：不重复提交，终态来自GET`, async ({ page }) => {
      const h = await setup(page);
      if (action.kind === 'retry') {
        h.state.scheduler_boot = { ...h.state.scheduler_boot, phase: 'failed', final: 'yes', ok: 'no' };
        await page.evaluate(() => requireFeature('profile').load());
      }
      await clickAndHold(page, h, action.selector, action.body, action.feedback);
      h.state.scheduler_operation = { id: `fixture-${action.kind}`, kind: action.kind, phase: 'queued', pending: true, result_code: 0 };
      if (action.kind === 'handoff') h.state.game_handoff_policy = 'off';
      await h.reply({ ...h.state, ok: true, accepted: true, final: false });
      await expect(page.locator('#scheduler-operation-notice')).toContainText('正在后台执行');
      await expect(page.locator(action.selector)).toBeDisabled();
      await page.locator(action.selector).evaluate((button) => button.click());
      expect(h.calls).toHaveLength(1);
      h.state.scheduler_operation = { ...h.state.scheduler_operation, phase: outcome, pending: false, result_code: outcome === 'failed' ? 17 : 0 };
      if (action.kind === 'retry') h.state.scheduler_boot = { ...h.state.scheduler_boot, phase: outcome === 'success' ? 'success' : 'failed', final: 'yes', ok: outcome === 'success' ? 'yes' : 'no' };
      await refreshProfileViaNavigation(page);
      await expect(page.locator('#scheduler-operation-notice')).toContainText(outcome === 'success' ? '已完成' : '错误代码：17');
      expect(await page.evaluate(() => requireFeature('profile').isBusy())).toBe(false);
      if (action.kind === 'retry' && outcome === 'success') await expect(page.locator(action.selector)).toBeDisabled();
      else await expect(page.locator(action.selector)).toBeEnabled();
      expect(h.calls).toHaveLength(1);
    });
  }
}

for (const outcome of ['accepted', 'failure']) {
  test(`重启按钮 ${outcome}：仅拦截模拟请求，关闭不重发`, async ({ page }) => {
    const h = await setup(page);
    // Opening the UI is local only; the actual button follows production thermal.rebootDevice.
    await page.evaluate(() => requireFeature('ui').openRebootModal(null, null, 'scheduler'));
    await page.locator('#reboot-now-btn').click();
    await expect.poll(() => h.calls.length).toBe(1);
    expect(h.calls[0]).toEqual({ endpoint: '/cgi-bin/reboot.sh', body: { action: 'reboot', confirm: true } });
    await expect(page.locator('#reboot-now-btn')).toBeDisabled();
    await page.locator('#reboot-now-btn').evaluate((button) => button.click());
    if (outcome === 'accepted') {
      await page.locator('#reboot-later-btn').click();
      await expect(page.locator('#modal-reboot')).not.toHaveClass(/open/);
      await h.reply({ ok: true });
      await expect(page.locator('#toast-wrap')).toContainText('重启请求已受理');
      await expect(page.locator('#modal-reboot')).not.toHaveClass(/open/);
    } else {
      await h.reply({ ok: false, error: 'fixture reboot rejected' }, 500);
      await expect(page.locator('#reboot-now-btn')).toBeEnabled();
      await expect(page.locator('#reboot-cancel-error')).toContainText('重启请求未确认');
    }
    expect(h.calls).toHaveLength(1);
  });
}
