const { test, expect } = require('@playwright/test');

async function ready(page) {
  await page.goto('/');
  await expect(page.locator('#topbar-kicker')).toContainText('Pixel 9 Pro');
  await expect(page.locator('#profile-list .profile-select')).toHaveCount(4);
  await expect(page.locator('#thermal-list .profile-select')).toHaveCount(5);
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
