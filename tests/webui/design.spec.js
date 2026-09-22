const { test, expect } = require('@playwright/test');

async function ready(page) {
  await page.goto('/');
  await expect(page.locator('#topbar-kicker')).toContainText('Pixel 9 Pro');
  await expect(page.locator('#profile-list .profile-select')).toHaveCount(4);
  await expect(page.locator('#thermal-list .profile-select')).toHaveCount(5);
}

const THERMAL_CONTRACT = {
  policies: ['system', 'custom'],
  default_policy: 'system',
  offsets: [-2, 2, 4, 6],
  default_offset: 2
};

function fixtureState(model) {
  const state = {
    ok: true,
    policy: model.policy,
    offset: model.offset,
    thermal_contract: THERMAL_CONTRACT,
    mount_backend: model.hybrid ? 'hybrid_mount' : 'metamodule_content',
    metamodule_active: true,
    reinstall_required: false
  };
  if (model.hybrid) {
    state.pending = model.pending;
    state.pending_id = model.pending ? model.pendingId : '';
    state.cancel_supported = true;
    state.reboot_required = model.pending;
  }
  return state;
}

async function installThermalFixture(page, { policy = 'system', offset = 2, pending = false, hybrid = true } = {}) {
  const model = {
    policy,
    offset,
    pending,
    pendingId: pending ? 'fixture-pending-001' : '',
    hybrid,
    previous: null,
    cancelMode: 'success',
    readbackFail: false,
    requests: []
  };
  await page.route('**/cgi-bin/set_thermal.sh', async (route) => {
    const request = route.request();
    if (request.method() === 'GET') {
      if (model.readbackFail) {
        model.readbackFail = false;
        return route.fulfill({ status: 503, json: { ok: false, error: 'readback unavailable' } });
      }
      return route.fulfill({ json: fixtureState(model) });
    }
    const body = request.postDataJSON() || {};
    model.requests.push(body);
    if (!model.hybrid && model.pending && !body.action && body.policy) {
      model.policy = body.policy;
      model.offset = body.policy === 'custom' ? Number(body.offset) : model.offset;
      model.pending = false;
      model.previous = null;
      return route.fulfill({ json: { ok: true, policy: model.policy, offset: model.offset, restarted: false, reboot_required: false } });
    }
    if (body.action === 'cancel_pending') {
      if (body.pending_id !== model.pendingId) {
        return route.fulfill({ status: 409, json: { ok: false, error: 'pending_id 不匹配' } });
      }
      if (model.cancelMode === 'delay-failure') {
        await new Promise((resolve) => setTimeout(resolve, 250));
        return route.fulfill({ status: 503, json: { ok: false, error: 'cancel backend unavailable' } });
      }
      if (model.cancelMode === 'incomplete') {
        return route.fulfill({ json: {
          ok: true, canceled: true, pending: true, pending_id: model.pendingId,
          reboot_required: true, policy: model.policy, offset: model.offset
        } });
      }
      const restored = model.previous || { policy: 'system', offset: 2 };
      model.policy = restored.policy;
      model.offset = restored.offset;
      model.pending = false;
      model.pendingId = '';
      model.previous = null;
      return route.fulfill({ json: { ...fixtureState(model), ok: true, canceled: true, pending: false, pending_id: '', reboot_required: false } });
    }
    if (body.policy !== 'system' && body.policy !== 'custom') {
      return route.fulfill({ status: 400, json: { ok: false, error: 'invalid policy' } });
    }
    model.previous = { policy: model.policy, offset: model.offset };
    model.policy = body.policy;
    model.offset = body.policy === 'custom' ? Number(body.offset) : model.offset;
    model.pending = true;
    model.pendingId = 'fixture-pending-001';
    return route.fulfill({ json: { ...fixtureState(model), ok: true, restarted: false, reboot_required: true, effective_state: 'pending_reboot' } });
  });
  await ready(page);
  await page.locator('#tab-tune').click();
  return model;
}

async function layoutIssues(page) {
  return page.evaluate(() => {
    const width = document.documentElement.clientWidth;
    const visible = el => {
      if (el.closest('[inert],[hidden],.modal-wrap:not(.open)')) return false;
      const rect = el.getBoundingClientRect(), style = getComputedStyle(el);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
    };
    return [...document.querySelectorAll('button,summary,input:not([type=hidden]),select,canvas')].filter(visible).flatMap(el => {
      const r = el.getBoundingClientRect(), label = el.id || el.className;
      const issues = [];
      if (r.left < -1 || r.right > width + 1) issues.push({ label, issue: 'horizontal overflow', rect: r.toJSON() });
      if (el.tagName !== 'CANVAS' && (r.width < 47.5 || r.height < 47.5)) issues.push({ label, issue: 'target below 48', rect: r.toJSON() });
      return issues;
    });
  });
}

test('四页在暗色、200%文字与RTL下保留48点击框和可读布局', async ({ page }) => {
  await ready(page);
  await page.evaluate(() => { document.documentElement.style.fontSize = '200%'; document.documentElement.dir = 'rtl'; requireFeature('theme').applyTheme('dark', false); });
  for (const tab of ['home','tune','network','system']) {
    await page.locator('#tab-' + tab).click();
    await expect(page.locator('#page-' + tab)).toHaveClass(/active/);
    await expect.poll(() => layoutIssues(page)).toEqual([]);
    expect(await page.locator('.tab-pages').evaluate(el => el.clientHeight)).toBeGreaterThan(90);
  }
});

test('档位选择与说明是独立控件，键盘打开说明不提交写入', async ({ page }) => {
  const writes=[];
  page.on('request',req=>{if(req.method()==='POST' && /\/(profile|set_thermal)\.sh/.test(req.url()))writes.push(req.url());});
  await ready(page); await page.locator('#tab-tune').click();
  await expect(page.locator('#profile-list .card-info')).toHaveCount(4);
  await expect(page.locator('#thermal-list .card-info')).toHaveCount(5);
  expect(await page.locator('.profile-card button button').count()).toBe(0);
  for(const selector of ['#profile-list .card-info','#thermal-list .card-info']) {
    const button=page.locator(selector).first(); await button.focus(); await button.press('Enter');
    await expect(page.locator('#modal-detail')).toHaveClass(/open/);
    await expect(page.locator('#detail-close-btn')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(button).toBeFocused();
  }
  expect(writes).toEqual([]);
  await expect(page.locator('#profile-list .profile-select[aria-checked=true]')).toHaveCount(1);
  await expect(page.locator('#thermal-list .profile-select[aria-checked=true]')).toHaveCount(1);
});

test('温控取消失败时必须保持弹窗，禁止关闭和重启并允许重试', async ({ page }) => {
  const model = await installThermalFixture(page);
  model.cancelMode = 'delay-failure';
  await page.locator('[data-policy="custom"][data-offset="4"] .profile-select').click();
  await expect(page.locator('#modal-reboot')).toHaveClass(/open/);
  const cancelRequest = page.locator('#reboot-cancel-btn').click();
  await page.waitForFunction(() => document.querySelector('#reboot-cancel-btn').disabled);
  await expect(page.locator('#reboot-now-btn')).toBeDisabled();
  await expect(page.locator('#reboot-later-btn')).toBeDisabled();
  await expect(page.locator('#reboot-close-x')).toBeDisabled();
  await page.keyboard.press('Escape');
  await expect(page.locator('#modal-reboot')).toHaveClass(/open/);
  await cancelRequest;
  await expect(page.locator('#modal-reboot')).toHaveClass(/open/);
  await expect(page.locator('#reboot-cancel-error')).toContainText('撤销未确认');
  await expect(page.locator('#reboot-cancel-error')).toBeVisible();
  await expect(page.locator('#reboot-now-btn')).toBeEnabled();
  model.cancelMode = 'success';
  await page.locator('#reboot-cancel-btn').click();
  await expect(page.locator('#modal-reboot')).not.toHaveClass(/open/);
  await expect(page.locator('#toast-wrap')).toContainText('已撤销本次温控修改');
  expect(model.requests.filter((request) => request.action === 'cancel_pending')[0].pending_id).toBe('fixture-pending-001');
});

test('system、custom、自定义切换的 pending 均使用后端 id 并恢复原状态', async ({ page }) => {
  const cases = [
    { initial: { policy: 'system', offset: 2 }, target: '[data-policy="custom"][data-offset="4"]' },
    { initial: { policy: 'custom', offset: 2 }, target: '[data-policy="custom"][data-offset="6"]' },
    { initial: { policy: 'custom', offset: 4 }, target: '[data-policy="system"]' }
  ];
  for (const item of cases) {
    const context = await page.context().browser().newContext({ viewport: { width: 390, height: 844 } });
    const isolated = await context.newPage();
    try {
      const model = await installThermalFixture(isolated, item.initial);
      await isolated.locator(item.target + ' .profile-select').click();
      await expect(isolated.locator('#modal-reboot')).toHaveClass(/open/);
      await isolated.locator('#reboot-cancel-btn').click();
      await expect(isolated.locator('#modal-reboot')).not.toHaveClass(/open/);
      expect(model.pending).toBe(false);
      expect(model.policy).toBe(item.initial.policy);
      expect(model.offset).toBe(item.initial.offset);
      expect(model.requests.at(-1)).toMatchObject({ action: 'cancel_pending', pending_id: 'fixture-pending-001' });
    } finally {
      await context.close();
    }
  }
});

test('页面重载后可打开并取消仍然存在的 pending，异常成功响应不会关闭弹窗', async ({ page }) => {
  const model = await installThermalFixture(page, { policy: 'system', offset: 2 });
  await page.locator('[data-policy="custom"][data-offset="4"] .profile-select').click();
  await expect(page.locator('#modal-reboot')).toHaveClass(/open/);
  await page.reload();
  await expect(page.locator('#thermal-list .profile-select')).toHaveCount(5);
  await expect(page.locator('#modal-reboot')).toHaveClass(/open/);
  model.cancelMode = 'incomplete';
  await page.locator('#reboot-cancel-btn').click();
  await expect(page.locator('#modal-reboot')).toHaveClass(/open/);
  await expect(page.locator('#reboot-cancel-error')).toContainText('撤销未确认');
  model.cancelMode = 'success';
  await page.locator('#reboot-cancel-btn').click();
  await expect(page.locator('#modal-reboot')).not.toHaveClass(/open/);
});

test('非 Hybrid 后端继续用旧状态回写取消，不发送 cancel_pending', async ({ page }) => {
  const model = await installThermalFixture(page, { policy: 'system', offset: 2, hybrid: false });
  await page.locator('[data-policy="custom"][data-offset="4"] .profile-select').click();
  await expect(page.locator('#modal-reboot')).toHaveClass(/open/);
  await page.locator('#reboot-cancel-btn').click();
  await expect(page.locator('#modal-reboot')).not.toHaveClass(/open/);
  expect(model.requests.at(-1)).toEqual({ policy: 'system', offset: 2 });
});

test('取消提交后复读超时，重试先 reconcile 而不是重复写入', async ({ page }) => {
  const model = await installThermalFixture(page, { policy: 'system', offset: 2 });
  await page.locator('[data-policy="custom"][data-offset="4"] .profile-select').click();
  await expect(page.locator('#modal-reboot')).toHaveClass(/open/);
  model.readbackFail = true;
  await page.locator('#reboot-cancel-btn').click();
  await expect(page.locator('#modal-reboot')).toHaveClass(/open/);
  await expect(page.locator('#reboot-cancel-error')).toContainText('撤销未确认');
  await page.locator('#reboot-cancel-btn').click();
  await expect(page.locator('#modal-reboot')).not.toHaveClass(/open/);
  expect(model.requests.filter((request) => request.action === 'cancel_pending')).toHaveLength(1);
});

test('UE能力只展示摘要，技术字段分组展开并保留用户的展开状态', async ({ page }) => {
  await ready(page); await page.locator('#tab-network').click();
  await expect(page.locator('#uecap-summary > .data-row')).toHaveCount(3);
  await expect(page.locator('#uecap-summary')).not.toContainText(/Payload|NSA|Device policy/);
  await expect(page.locator('#uecap-diagnostics')).not.toHaveAttribute('open','');
  await page.locator('#uecap-diagnostics > summary').click();
  await expect(page.locator('#uecap-rows > details')).toHaveCount(3);
  const radio=page.locator('[data-evidence-group=radio]');
  await radio.locator('summary').click();
  await expect(radio).toContainText('NSA');
  const selected=await page.locator('.uecap-btn[aria-pressed=true]').getAttribute('data-mode');
  await radio.locator('summary').focus();
  await page.evaluate(()=>requireFeature('network').refresh());
  await expect(page.locator('[data-evidence-group=radio] > summary')).toBeFocused();
  await expect(page.locator('[data-evidence-group=radio]')).toHaveAttribute('open','');
  await expect(page.locator('.uecap-btn[aria-pressed=true]')).toHaveAttribute('data-mode',selected);
});

test('UE读取失败或运行证据未知时首屏不伪报已确认', async ({ page }) => {
  await page.route('**/cgi-bin/uecap.sh',async route=>{
    const response=await route.fetch(),data=await response.json();
    data.runtime_receipt={...data.runtime_receipt,modem_load_state:'confirmed_readback',functional_state:'verified',receipt_freshness:'current_boot'};
    await route.fulfill({json:data});
  });
  await ready(page);await page.locator('#tab-network').click();
  await expect(page.locator('#uecap-summary')).toContainText('已确认');
  await page.route('**/cgi-bin/uecap.sh',route=>route.fulfill({status:503,json:{ok:false,error:'fixture unavailable'}}));
  await page.evaluate(()=>requireFeature('network').refresh());
  await expect(page.locator('#uecap-summary')).not.toContainText('已确认');
  await expect(page.locator('#uecap-status-message')).toBeVisible();
  await expect(page.locator('#uecap-status-message')).toContainText('过期');
  await page.unroute('**/cgi-bin/uecap.sh');
  await page.route('**/cgi-bin/uecap.sh',async route=>{
    const response=await route.fetch(),data=await response.json();
    data.runtime_receipt={...data.runtime_receipt,modem_load_state:'unknown',functional_state:'unknown',receipt_freshness:'missing'};
    await route.fulfill({json:data});
  });
  await page.evaluate(()=>requireFeature('network').refresh());
  await expect(page.locator('#uecap-summary')).toContainText('运行态待确认');
  await expect(page.locator('#uecap-status-message')).toBeVisible();
});

test('320短窗与200%文字仍有可滚动主内容', async ({ page }) => {
  await ready(page);await page.setViewportSize({width:320,height:360});
  await page.evaluate(()=>{document.documentElement.style.fontSize='200%';});
  expect(await page.locator('.tab-pages').evaluate(el=>el.clientHeight)).toBeGreaterThanOrEqual(90);
  await expect.poll(()=>layoutIssues(page)).toEqual([]);
  await page.locator('#tab-system').click();
  await expect(page.locator('#page-system')).toHaveClass(/active/);
});

test('普通与历史详情关闭统一，缩小Dock与Toast和底栏互不遮盖', async ({ page }) => {
  await ready(page); await page.locator('#tab-network').click(); await page.locator('#uecap-detail-btn').click();
  await expect(page.locator('#detail-close-x')).toBeVisible(); await expect(page.locator('#detail-close-btn')).toBeVisible();
  await page.locator('#detail-close-btn').click();
  await page.locator('#tab-home').click(); await page.locator('#energy-btn').click();
  await expect(page.locator('.analytics-chart-card canvas')).toBeVisible();
  await expect(page.locator('#detail-close-btn')).toBeVisible();
  await page.locator('#detail-minimize-btn').click();
  await expect(page.locator('#modal-detail')).toHaveClass(/detail-minimized/);
  await expect(page.locator('#detail-body')).not.toBeVisible();
  await expect(page.locator('.app-shell')).not.toHaveAttribute('inert','');
  await page.evaluate(()=>requireFeature('core').showToast('这是用于检测避让的提示。',5000));
  await expect.poll(async()=>page.evaluate(()=>{
    const dock=document.querySelector('#modal-detail .modal-sheet').getBoundingClientRect();
    const nav=document.querySelector('.bottom-nav').getBoundingClientRect();
    const toast=document.querySelector('#toast-wrap').getBoundingClientRect();
    return {dockAboveNav:dock.bottom<=nav.top,toastAboveDock:toast.bottom<=dock.top-4,toastVisible:toast.top>=0};
  })).toEqual({dockAboveNav:true,toastAboveDock:true,toastVisible:true});
  const paused=await page.evaluate(()=>requireFeature('analytics').getState());
  expect(paused.timer).toBeNull();expect(paused.request).toBeNull();
  await page.locator('#detail-minimize-btn').click();
  await expect(page.locator('#detail-close-btn')).toBeVisible();
  await page.locator('#detail-close-x').click();
  await expect(page.locator('#energy-btn')).toBeFocused();
});

test('模态焦点受约束、关闭后隐藏控件不可聚焦且返回导航正确', async ({ page }) => {
  await ready(page); await page.locator('#theme-open-btn').click();
  await expect(page.locator('#modal-theme')).toHaveAttribute('aria-hidden','false');
  await expect(page.locator('.app-shell')).toHaveAttribute('inert','');
  await page.locator('#theme-close-btn').focus();await page.keyboard.press('Tab');
  expect(await page.evaluate(()=>Boolean(document.activeElement.closest('#modal-theme')))).toBe(true);
  await page.keyboard.press('Escape');
  await expect(page.locator('#theme-open-btn')).toBeFocused();
  await expect(page.locator('#modal-theme')).toHaveAttribute('inert','');
  await page.locator('#theme-open-btn').click();await page.goBack();
  await expect(page.locator('#modal-theme')).not.toHaveClass(/open/);
  await expect(page.locator('.app-shell')).not.toHaveAttribute('inert','');
});

test('后台日志只在详情清理，成功回读并清除陈旧内容', async ({ page }) => {
  let lines=['2026-09-21 action=check result=ok'];let reads=0;let writes=0;
  await page.route('**/cgi-bin/audit_log.sh*',async route=>{
    if(route.request().method()==='POST'){writes++;lines=[];await route.fulfill({json:{ok:true,action:'clear'}});}
    else {reads++;await route.fulfill({json:{ok:true,lines}});}
  });
  page.on('dialog',dialog=>dialog.accept());
  await ready(page);await page.locator('#log-toggle').click();
  await expect(page.locator('#log-clear-btn')).toHaveText('清空本页记录');
  await page.locator('#log-audit-btn').click();
  await expect(page.locator('#audit-log-clear')).toHaveCount(1);
  await expect(page.locator('#detail-body')).toContainText('action=check');
  await page.locator('#audit-log-clear').click();
  await expect(page.locator('#detail-body')).not.toContainText('action=check');
  expect(writes).toBe(1);expect(reads).toBeGreaterThanOrEqual(2);
});

test('真实Canvas缺口为虚线，连续功耗段保持实线，切源不复用旧图', async ({ page },testInfo) => {
  await page.addInitScript(()=>{
    window.__chartStrokes=[];
    const original=CanvasRenderingContext2D.prototype.stroke;
    CanvasRenderingContext2D.prototype.stroke=function(...args){window.__chartStrokes.push({id:this.canvas.id,dash:this.getLineDash()});return original.apply(this,args);};
  });
  await ready(page);await page.locator('#energy-btn').click();
  await expect(page.locator('.analytics-chart-legend')).toContainText('间断');
  await expect.poll(()=>page.evaluate(()=>window.__chartStrokes.some(stroke=>stroke.dash.join(',')==='6,5'))).toBe(true);
  expect(await page.evaluate(()=>window.__chartStrokes.some(stroke=>stroke.dash.length===0))).toBe(true);
  await page.locator('#modal-detail .modal-sheet-body').screenshot({path:testInfo.outputPath('power-gap.png')});
  await page.locator('[data-analytics-source=thermal]').click();
  await expect(page.locator('.analytics-hero-kicker')).toContainText('温度');
  await expect(page.locator('body')).not.toContainText(/NaN|undefined/);
});

test('默认与自定义主题实际配对达到对比要求，reduce取消空间动效', async ({ page }) => {
  await ready(page);
  const results=await page.evaluate(()=>{
    const rgb=s=>s.startsWith('#')?[1,3,5].map(i=>parseInt(s.slice(i,i+2),16)):s.match(/[\d.]+/g).slice(0,3).map(Number);
    const lum=c=>{const v=rgb(c).map(n=>{n/=255;return n<=.04045?n/12.92:((n+.055)/1.055)**2.4;});return v[0]*.2126+v[1]*.7152+v[2]*.0722;};
    const ratio=(a,b)=>(Math.max(lum(a),lum(b))+.05)/(Math.min(lum(a),lum(b))+.05);
    const out=[];
    for(const mode of ['light','dark'])for(const palette of ['default','sky','ocean','lavender','rose','amber','sage']){
      requireFeature('theme').applyTheme(mode,false);requireFeature('theme').applyPalette(palette,false);
      const style=getComputedStyle(document.documentElement),value=k=>style.getPropertyValue(k).trim();
      for(const [fg,bg] of [['--on-primary','--primary'],['--on-primary-container','--primary-container'],['--secondary-ink','--secondary-container'],['--text-2','--surface'],['--text-3','--surface'],['--warn','--warn-container'],['--success','--success-container'],['--info','--info-container']])out.push({mode,palette,fg,bg,ratio:ratio(value(fg),value(bg))});
    }
    return out.filter(result=>result.ratio<4.5);
  });
  expect(results).toEqual([]);
  await page.emulateMedia({reducedMotion:'reduce'});
  await page.locator('#theme-open-btn').click();
  const motion=await page.locator('#modal-theme .modal-sheet').evaluate(el=>({animation:getComputedStyle(el).animationName,duration:getComputedStyle(el).transitionDuration}));
  expect(motion.animation).toBe('none');expect(motion.duration.split(',').every(v=>parseFloat(v)===0)).toBe(true);
});
