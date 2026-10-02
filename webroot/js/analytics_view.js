'use strict';
(() => {
  const model = () => requireFeature('analyticsModel');
  const cssVar = (name, fallback) => getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback;
  const el = (tag, cls, text) => {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const row = (label, value, cls = '') => {
    const node = el('div', 'data-row');
    node.append(el('span', 'data-key', label), el('span', cls || 'data-val', value == null ? '—' : String(value)));
    return node;
  };

  function create(callbacks) {
    const view = { callbacks, canvas: null, stats: null, source: 'thermal' };
    const root = el('div', 'analytics-overview');
    const intro = el('div', 'analytics-intro');
    intro.append(el('div', 'analytics-section-title', '历史趋势'), el('div', 'analytics-section-desc', '模块采样与 Android 系统 BatteryStats 分开显示；缺测保留为空，不把两种口径相加。'));
    const source = el('div', 'analytics-range');
    source.setAttribute('role', 'tablist'); source.setAttribute('aria-label', '数据类型');
    ['thermal', 'power', 'system'].forEach((kind) => {
      const label = kind === 'thermal' ? '温度' : kind === 'system' ? '系统统计耗电' : '模块监测耗电';
      const button = el('button', 'analytics-range-btn', label);
      button.type = 'button'; button.dataset.analyticsSource = kind; button.setAttribute('role', 'tab'); button.setAttribute('aria-selected', String(kind === 'thermal')); button.tabIndex = kind === 'thermal' ? 0 : -1;
      button.addEventListener('click', () => callbacks.onSource(kind));
      source.appendChild(button);
    });
    const bindTabKeys = (group) => group.addEventListener('keydown', (event) => {
      const tabs = Array.from(group.querySelectorAll('[role="tab"]'));
      const index = tabs.indexOf(event.target);
      if (index < 0 || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
      event.preventDefault();
      const rtl = getComputedStyle(group).direction === 'rtl';
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (index + ((event.key === 'ArrowRight') !== rtl ? 1 : -1) + tabs.length) % tabs.length;
      tabs[next].focus(); tabs[next].click();
    });
    bindTabKeys(source);
    const sensor = el('div', 'analytics-range analytics-sensor-range');
    sensor.setAttribute('role', 'tablist'); sensor.setAttribute('aria-label', '温度传感器');
    [['module', '机身温度'], ['battery', '系统电池温度']].forEach(([id, label]) => {
      const button = el('button', 'analytics-range-btn', label); button.type = 'button'; button.dataset.analyticsSensor = id; button.setAttribute('role', 'tab'); button.setAttribute('aria-selected', String(id === 'module')); button.tabIndex = id === 'module' ? 0 : -1; button.addEventListener('click', () => callbacks.onThermalSensor?.(id)); sensor.appendChild(button);
    });
    bindTabKeys(sensor);
    const range = el('div', 'analytics-range');
    range.setAttribute('role', 'tablist'); range.setAttribute('aria-label', '统计区间');
    model().ranges().forEach((item) => {
      const button = el('button', 'analytics-range-btn', item.shortLabel || item.label);
      button.type = 'button'; button.dataset.analyticsRange = item.id; button.setAttribute('role', 'tab'); button.setAttribute('aria-selected', String(item.id === '30')); button.tabIndex = item.id === '30' ? 0 : -1;
      button.addEventListener('click', () => callbacks.onRange(item.id));
      range.appendChild(button);
    });
    bindTabKeys(range);
    const custom = el('div', 'analytics-custom-range');
    const days = document.createElement('select'); days.setAttribute('aria-label', '自定义时间窗');
    [['14400', '4 小时'], ['28800', '8 小时'], ['43200', '12 小时'], ['86400', '1 天'], ['259200', '3 天'], ['604800', '7 天']].forEach(([value, label]) => { const option = el('option', '', label); option.value = value; days.appendChild(option); });
    const granularity = document.createElement('select'); granularity.setAttribute('aria-label', '采样粒度');
    granularity.append(el('option', '', '按小时'), el('option', '', '按分钟'));
    granularity.options[0].value = 'hour'; granularity.options[1].value = 'minute';
    const apply = el('button', 'tiny-btn tonal', '应用范围'); apply.type = 'button';
    apply.addEventListener('click', () => callbacks.onCustom(days.value, granularity.value));
    const daysField = el('label', 'analytics-custom-field'); daysField.append(el('span', 'analytics-section-desc', '时间窗'), days);
    const granularityField = el('label', 'analytics-custom-field'); granularityField.append(el('span', 'analytics-section-desc', '精细度'), granularity);
    custom.append(daysField, granularityField, apply);
    const stateLine = el('div', 'analytics-status'); stateLine.setAttribute('role', 'status');
    const hero = el('section', 'analytics-hero');
    const heroHead = el('div', 'analytics-hero-head');
    const heroCopy = el('div', 'analytics-hero-copy');
    heroCopy.append(el('div', 'analytics-hero-kicker'), el('div', 'analytics-hero-value'), el('div', 'analytics-hero-status'));
    heroHead.append(heroCopy, el('span', 'analytics-hero-badge'));
    const summary = el('div', 'analytics-summary-grid');
    ['最低', '平均', '最高'].forEach((label) => { const item = el('div', 'analytics-summary-item'); item.append(el('span', '', label), el('strong', '', '—')); summary.append(item); });
    hero.append(heroHead, summary);
    const chartSection = el('section', 'analytics-section');
    const chartHead = el('div', 'analytics-section-head');
    chartHead.append(el('div', 'analytics-section-title', '趋势图'), el('div', 'analytics-section-desc', '实线表示有效采样；时间轴下方的虚线标记缺测或非放电时段，不补画趋势。'));
    const chartCard = el('div', 'analytics-chart-card');
    const chartWrap = el('div', 'analytics-chart-wrap');
    const canvas = document.createElement('canvas');
    canvas.setAttribute('role', 'img'); canvas.setAttribute('aria-label', '历史趋势图'); canvas.tabIndex = 0;
    const tooltip = el('div', 'analytics-chart-tooltip'); tooltip.hidden = true; tooltip.setAttribute('role', 'status');
    chartWrap.appendChild(canvas); chartWrap.appendChild(tooltip); chartCard.appendChild(chartWrap);
    const legend = el('div', 'analytics-chart-legend'); chartCard.appendChild(legend);
    const quality = el('div', 'analytics-status'); quality.setAttribute('role', 'status'); quality.hidden = true; chartCard.appendChild(quality);
    chartSection.append(chartHead, chartCard);
    const more = document.createElement('details'); more.className = 'analytics-disclosure';
    const moreSummary = el('summary', 'analytics-disclosure-summary');
    const moreCopy = el('span', 'analytics-disclosure-copy'); moreCopy.append(el('strong', '', '更多统计'), el('small', '', '采样覆盖、差分口径与阈值时长 · 区间切换或主动刷新立即更新，自动慢更新约 2 分钟'));
    moreSummary.append(moreCopy, el('span', 'analytics-disclosure-chevron', '›'));
    const moreBody = el('div', 'analytics-disclosure-body'); more.append(moreSummary, moreBody);
    const capture = el('section', 'analytics-capture-card');
    const captureState = el('div', 'analytics-capture-state', '未开始记录');
    const captureControls = el('div', 'analytics-actions');
    const duration = document.createElement('select'); duration.setAttribute('aria-label', '临时诊断时长');
    [['1800', '30 分钟'], ['7200', '2 小时'], ['28800', '8 小时'], ['0', '手动结束']].forEach(([value, label]) => { const option = el('option', '', label); option.value = value; duration.appendChild(option); });
    const captureBtn = el('button', 'tiny-btn primary', '开始记录'); captureBtn.type = 'button';
    captureBtn.addEventListener('click', () => callbacks.onCapture(captureBtn, Number(duration.value) || 0));
    const captureExport = el('button', 'tiny-btn tonal', '导出记录'); captureExport.type = 'button';
    captureExport.addEventListener('click', () => callbacks.onCaptureExport(captureExport));
    captureControls.append(duration, captureBtn, captureExport);
    capture.append(el('div', 'analytics-section-title', '临时诊断记录'), el('div', 'analytics-section-desc', '只用于一次临时诊断会话，不会改变后台历史策略。息屏与 Doze 期间允许真实缺测，不补零、不伪造连续曲线。'), captureState, captureControls);
    const policy = el('section', 'analytics-policy-card');
    const policyTitle = el('div', 'analytics-section-title', '后台记录与存储');
    const policyDesc = el('div', 'analytics-section-desc', '控制 Android 系统历史、模块低频记录与历史空间。息屏不主动调用 BatteryStats，“息屏缺测判定”只决定缺测间隔如何标记。关闭后停止后台采样和周期分析；前台读取与独占临时诊断仍可用。温控控制本身不受影响。');
    const policyFields = el('div', 'analytics-policy-fields');
    const enabledField = el('label', 'analytics-policy-toggle');
    const enabled = document.createElement('input'); enabled.type = 'checkbox'; enabled.checked = true; enabled.setAttribute('aria-label', '启用后台历史记录');
    enabledField.append(enabled, el('span', 'analytics-section-desc', '后台记录（关闭后停止周期采样；前台读取和临时诊断仍可用）'));
    policyFields.appendChild(enabledField);
    const makeSelect = (label, values, suffix) => { const select = document.createElement('select'); select.setAttribute('aria-label', label); values.forEach((value) => { const option = el('option', '', `${value}${suffix}`); option.value = String(value); select.appendChild(option); }); const field = el('label', 'analytics-custom-field'); field.append(el('span', 'analytics-section-desc', label), select); policyFields.appendChild(field); return select; };
    const retention = makeSelect('保留时间', [1, 3, 7], ' 天');
    const cap = makeSelect('空间上限', [8, 16, 32], ' MiB');
    const onInterval = makeSelect('亮屏系统历史', [5, 15, 30, 60], ' 分钟');
    const offInterval = makeSelect('息屏缺测判定', [15, 30, 60, 120], ' 分钟');
    const policyActions = el('div', 'analytics-actions'); const policyButton = el('button', 'tiny-btn tonal', '应用设置'); policyButton.type = 'button'; policyButton.disabled = true; policyButton.addEventListener('click', () => callbacks.onPolicy?.(policyButton, { analytics_enabled: enabled.checked, retention_days: retention.value, max_bytes: Number(cap.value) * 1048576, module_interval_on_sec: 60, module_interval_off_sec: 900, system_interval_on_sec: Math.max(300, Number(onInterval.value) * 60), system_interval_off_sec: Math.max(900, Number(offInterval.value) * 60) })); policyActions.appendChild(policyButton);
    [enabled, retention, cap, onInterval, offInterval].forEach((field) => field.addEventListener('change', () => { view.policy && (view.policy.dirty = true); policyButton.disabled = false; }));
    const policyState = el('div', 'analytics-policy-state', '等待读取后台策略'); policy.append(policyTitle, policyDesc, policyFields, policyActions, policyState);
    const actions = el('div', 'analytics-export-actions analytics-actions');
    const refresh = el('button', 'tiny-btn tonal', '刷新数据'); refresh.type = 'button';
    refresh.addEventListener('click', () => callbacks.onRefresh?.(refresh)); actions.appendChild(refresh);
    const exportWindow = el('button', 'tiny-btn tonal', '导出当前区间'); exportWindow.type = 'button';
    exportWindow.addEventListener('click', () => callbacks.onExport(exportWindow)); actions.appendChild(exportWindow);
    root.append(intro, source, sensor, range, custom, stateLine, hero, chartSection, more, capture, policy, actions);
    view.root = root; view.sourceGroup = source; view.sensorGroup = sensor; view.rangeGroup = range; view.custom = custom; view.customWindow = days; view.customGranularity = granularity; view.stateLine = stateLine; view.hero = hero;
    view.heroKicker = heroHead.querySelector('.analytics-hero-kicker'); view.heroValue = heroHead.querySelector('.analytics-hero-value'); view.heroStatus = heroHead.querySelector('.analytics-hero-status'); view.heroBadge = heroHead.querySelector('.analytics-hero-badge'); view.summary = Array.from(summary.children); view.canvas = canvas; view.tooltip = tooltip; view.legend = legend; view.quality = quality; view.moreBody = moreBody; view.captureState = captureState; view.captureBtn = captureBtn; view.captureExport = captureExport; view.duration = duration; view.refresh = refresh; view.exportWindow = exportWindow; view.policy = { enabled, retention, cap, onInterval, offInterval, button: policyButton, state: policyState, dirty: false };
    const showPoint = (point, source) => {
      if (!point) { tooltip.hidden = true; return; }
      const date = new Date(point.ts * 1000);
      const value = Number.isFinite(Number(point.value)) ? Number(point.value).toFixed(source === 'thermal' ? 1 : 2) : '—';
      tooltip.textContent = `${date.toLocaleString([], { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })} · ${value}${source === 'thermal' ? ' °C' : ` ${view.stats?.seriesUnit || 'mAh/h'}`}`;
      tooltip.hidden = false;
    };
    const nearestPoint = (clientX) => {
      const rect = canvas.getBoundingClientRect(); const ratio = rect.width ? (clientX - rect.left) / rect.width : 0; const points = (view.stats?.chartSegments || []).flat();
      return points.reduce((best, point) => !best || Math.abs((point.ts - (view.stats.startTs + ratio * (view.stats.endTs - view.stats.startTs)))) < Math.abs(best.ts - (view.stats.startTs + ratio * (view.stats.endTs - view.stats.startTs))) ? point : best, null);
    };
    canvas.addEventListener('pointermove', (event) => showPoint(nearestPoint(event.clientX), view.source));
    canvas.addEventListener('pointerleave', () => { tooltip.hidden = true; });
    canvas.addEventListener('focus', () => { const first = view.stats?.chartSegments?.flat()?.[0]; showPoint(first, view.source); });
    canvas.addEventListener('keydown', (event) => { if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return; const points = view.stats?.chartSegments?.flat() || []; if (!points.length) return; event.preventDefault(); const current = points.findIndex((point) => tooltip.textContent.startsWith(new Date(point.ts * 1000).toLocaleString([], { month: '2-digit', day: '2-digit' }))); const next = Math.max(0, Math.min(points.length - 1, (current < 0 ? 0 : current) + (event.key === 'ArrowRight' ? 1 : -1))); showPoint(points[next], view.source); });
    return view;
  }

  function setActive(view, source, rangeId, thermalSensor = 'module') {
    view.source = source;
    view.stateLine.className = 'analytics-status';
    view.sourceGroup.querySelectorAll('[data-analytics-source]').forEach((node) => { const active = node.dataset.analyticsSource === source; node.classList.toggle('active', active); node.setAttribute('aria-selected', String(active)); node.tabIndex = active ? 0 : -1; });
    view.sensorGroup.hidden = source !== 'thermal'; view.sensorGroup.querySelectorAll('[data-analytics-sensor]').forEach((node) => { const active = node.dataset.analyticsSensor === thermalSensor; node.classList.toggle('active', active); node.setAttribute('aria-selected', String(active)); node.tabIndex = active ? 0 : -1; });
    view.rangeGroup.querySelectorAll('[data-analytics-range]').forEach((node) => { const active = node.dataset.analyticsRange === String(rangeId); node.classList.toggle('active', active); node.setAttribute('aria-selected', String(active)); node.tabIndex = active ? 0 : -1; });
    view.custom.hidden = String(rangeId) !== 'custom';
  }

  function setCustomValues(view, durationSec, granularity) {
    const value = Number(durationSec) || 86400;
    view.customWindow.value = String(Math.min(604800, Math.max(14400, value)));
    view.customGranularity.value = granularity === 'minute' ? 'minute' : 'hour';
  }

  function promptCustom(view) {
    setActive(view, view.source, 'custom');
    view.stateLine.hidden = false;
    view.stateLine.textContent = '选择最近时间窗和采样精细度后应用';
  }

  function relativeTime(ts) {
    const date = new Date(Number(ts) * 1000);
    if (!Number.isFinite(date.getTime())) return '—';
    const days = Math.max(0, Math.floor((Date.now() - date.getTime()) / 86400000));
    const dayLabel = days === 0 ? '今天' : days === 1 ? '昨天' : days + '天前';
    return dayLabel + ' ' + date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }

  function packageLabel(app) {
    try {
      return requireFeature('memory').friendlyPackageLabel(app.pkg, app.label);
    } catch (_) {
      return String(app.label || app.pkg || '未知应用');
    }
  }

  function rankList(items, type) {
    const list = el('div', 'analytics-rank-list');
    const max = Math.max(...items.map((item) => Number(item.value) || 0), 1);
    items.forEach((item, index) => {
      const rowNode = el('div', 'analytics-rank-row');
      const marker = el('span', 'analytics-rank-index', String(index + 1));
      const copy = el('div', 'analytics-rank-copy');
      copy.append(el('strong', '', item.label), el('small', '', item.subtitle || (type === 'app' ? '系统模型估算' : '系统分项')));
      const value = el('div', 'analytics-rank-value', Number(item.value).toFixed(1) + ' mAh');
      const bar = el('div', 'analytics-rank-bar');
      const fill = el('span'); fill.style.width = Math.max(4, Math.min(100, (Number(item.value) / max) * 100)) + '%';
      bar.appendChild(fill); rowNode.append(marker, copy, value, bar); list.appendChild(rowNode);
    });
    return list;
  }

  function appendPowerAttribution(body, summary, ranking) {
    const disclosure = document.createElement('details'); disclosure.className = 'analytics-disclosure';
    const disclosureSummary = el('summary', 'analytics-disclosure-summary');
    const disclosureCopy = el('span', 'analytics-disclosure-copy'); disclosureCopy.append(el('strong', '', '软件耗电排行'), el('small', '', '只在展开时读取；显示真实观测区间与归因证据状态'));
    disclosureSummary.append(disclosureCopy, el('span', 'analytics-disclosure-chevron', '›'));
    const content = el('div', 'analytics-disclosure-body'); disclosure.append(disclosureSummary, content); body.appendChild(disclosure); body = content;
    body.append(el('div', 'analytics-section-desc', '排行按当前时间窗读取同一 boot 的 BatteryStats 累计差分；跨窗口基线会单独标注，证据不足时不会伪造当前窗口耗电。'));
    const rankState = ranking || { status: 'idle' };
    if (rankState.status === 'loading') {
      body.appendChild(el('div', 'analytics-loading-card', '正在读取当前窗口的功耗排行…'));
      return;
    }
    if (rankState.status === 'error') {
      body.appendChild(el('div', 'analytics-error', `功耗排行请求失败：${rankState.error || '后台暂时不可用'}。趋势数据仍可用。`));
      return;
    }
    if (rankState.status === 'unavailable') {
      const reason = rankState.summary?.reason || 'need_two_same_identity_snapshots';
      const text = {
        need_two_snapshots: '当前还没有两份可比较的归因快照；保持亮屏使用约 10 分钟后再刷新。',
        need_two_same_identity_snapshots: '当前时间窗缺少同一 boot 的连续归因快照；跨 boot 或间断数据不会冒充排行。',
        interval_too_long: '最近两份快照间隔过长；下一份亮屏快照完成后再刷新。',
        feature_disabled: '后台归因采样已关闭；前台仍可读取已有 ledger，开启后台后才会产生新快照。'
      }[reason] || `当前窗口暂无可证明归因（${reason}）。`;
      body.appendChild(el('div', 'analytics-status warn', text));
      return;
    }
    summary = rankState.summary || summary;
    const hasFull = summary && (Array.isArray(summary.apps) || Array.isArray(summary.components));
    if (!hasFull) {
      body.appendChild(el('div', 'analytics-empty', '当前时间窗暂无可用系统归因；趋势数据仍可用。'));
      return;
    }
    const apps = (Array.isArray(summary.apps) ? summary.apps : [])
      .map((app) => ({ value: Number(app.mah), label: packageLabel(app), subtitle: [app.pkg, app.category, app.uid || (Number.isFinite(Number(app.uid_num)) ? 'UID ' + app.uid_num : '')].filter(Boolean).join(' · ') }))
      .filter((app) => Number.isFinite(app.value) && app.value > 0)
      .sort((a, b) => b.value - a.value);
    const components = Array.isArray(summary.components) ? summary.components.map((item) => ({ label: item.label || item.key || '系统分项', value: Number(item.mah) })) : [
      ['CPU 分项', summary.cpu], ['亮屏分项', summary.scron], ['息屏分项', summary.scroff],
      ['Wi‑Fi 分项', summary.wifi], ['唤醒锁', summary.wakelock]
    ].map(([label, value]) => ({ label, value: Number(value) }))
      .filter((item) => Number.isFinite(item.value) && item.value > 0)
      .sort((a, b) => b.value - a.value);
    const groups = el('div', 'analytics-breakdown');
    const appGroup = el('section', 'analytics-breakdown-group');
    appGroup.appendChild(el('div', 'analytics-group-title', apps.length ? 'Top ' + Math.min(5, apps.length) + ' 软件' : '软件耗电'));
    appGroup.appendChild(apps.length ? rankList(apps.slice(0, 5), 'app') : el('div', 'analytics-empty', '暂无软件归因'));
    const systemGroup = el('section', 'analytics-breakdown-group');
    systemGroup.appendChild(el('div', 'analytics-group-title', '系统分项'));
    systemGroup.appendChild(components.length ? rankList(components.slice(0, 5), 'system') : el('div', 'analytics-empty', '暂无系统分项'));
    groups.append(appGroup, systemGroup); body.appendChild(groups);
    const windowMeta = rankState.window || {};
    const metaText = [
      windowMeta.label ? `时间窗 ${windowMeta.label}` : '',
      windowMeta.granularity ? `粒度 ${windowMeta.granularity === 'minute' ? '分钟' : '小时'}` : '',
      rankState.status === 'partial' || rankState.summary?.window_proven === false ? `归因状态 ${rankState.summary?.attribution_state || 'baseline_clipped'}${rankState.summary?.reason ? `：${rankState.summary.reason}` : ''}` : '',
      windowMeta.attributionState && !windowMeta.windowProven ? `基线：${windowMeta.attributionState}（仅作参考）` : '',
      Number.isFinite(Number(windowMeta.coveragePct)) ? `覆盖率 ${Number(windowMeta.coveragePct).toFixed(1)}%` : '',
      Number.isFinite(Number(windowMeta.validSamples)) ? `有效样本 ${Number(windowMeta.validSamples)}` : '',
      Number.isFinite(Number(windowMeta.gapCount)) && windowMeta.gapCount ? `间断 ${Number(windowMeta.gapCount)} 段` : '',
      rankState.updatedAt ? `更新时间 ${new Date(rankState.updatedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}` : ''
    ].filter(Boolean).join(' · ');
    if (metaText) body.appendChild(el('div', 'analytics-note', metaText));
    const values = [['系统估算总耗电', summary.total_mah ?? summary.drain], ['当前统计窗口', summary.bat_time || rankState.window?.label]];
    const list = el('div', 'data-list');
    values.forEach(([label, value]) => { if (value !== null && value !== undefined && value !== '') list.appendChild(row(label, label === '系统估算总耗电' ? value + ' mAh' : value)); });
    if (list.childElementCount) body.appendChild(list);
  }

  function draw(view, source, stats) {
    const canvas = view.canvas;
    if (!canvas || !stats) return;
    const rect = canvas.getBoundingClientRect();
    const width = Math.max(120, Math.round(rect.width || 320));
    const height = Math.max(180, Math.round(rect.height || 210));
    const dpr = Math.min(2, Math.max(1, window.devicePixelRatio || 1));
    if (canvas.width !== Math.round(width * dpr) || canvas.height !== Math.round(height * dpr)) { canvas.width = Math.round(width * dpr); canvas.height = Math.round(height * dpr); }
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, width, height); ctx.setLineDash([]);
    const segments = (stats.chartSegments || []).map((segment) => segment.filter((point) => Number.isFinite(point.ts) && Number.isFinite(point.value))).filter((segment) => segment.length);
    const values = segments.flat().map((point) => point.value);
    const unit = source === 'thermal' ? '°C' : stats.seriesUnit || 'mAh/h';
    const gapRanges = (stats.gapRanges || []).filter((gap) => Number.isFinite(gap.startTs) && Number.isFinite(gap.endTs) && gap.endTs > gap.startTs);
    const trendLabel = source === 'thermal' ? '温度' : source === 'system' ? 'Android 系统耗电' : '模块放电';
    canvas.setAttribute('aria-label', `${trendLabel}趋势图，单位 ${unit}；${stats.count || 0} 个有效采样点，有效覆盖 ${model().formatDuration(stats.coverageSec)}，未知 ${model().formatDuration(stats.unknownSec)}${gapRanges.length ? `，${gapRanges.length} 段间断以时间轴虚线标记` : ''}。`);
    if (!Number.isFinite(stats.startTs) || !Number.isFinite(stats.endTs)) return;
    const spanSec = Math.max(1, stats.endTs - stats.startTs);
    const dayCrossing = new Date(stats.startTs * 1000).toDateString() !== new Date(stats.endTs * 1000).toDateString();
    const showDates = dayCrossing || spanSec >= 86400;
    const pad = { left: 46, right: 12, top: 26, bottom: showDates ? 58 : 42 }; const plotW = width - pad.left - pad.right; const plotH = height - pad.top - pad.bottom;
    const orderedValues = values.slice().sort((a, b) => a - b);
    const percentile = (ratio) => orderedValues.length ? orderedValues[Math.min(orderedValues.length - 1, Math.floor((orderedValues.length - 1) * ratio))] : 0;
    const min = values.length ? Math.min(...values) : 0; const max = values.length ? Math.max(...values) : 1;
    const robustLo = orderedValues.length > 4 ? percentile(0.05) : min;
    const robustHi = orderedValues.length > 4 ? percentile(0.95) : max;
    const baseLo = source === 'thermal' ? Math.min(min, robustLo) : Math.min(min, robustLo);
    const baseHi = source === 'thermal' ? Math.max(max, robustHi) : Math.max(max, robustHi);
    const padding = source === 'thermal' ? 1 : Math.max(1, Math.abs(baseHi || baseLo) * 0.2);
    let lo = baseLo === baseHi ? baseLo - padding : baseLo; let hi = baseLo === baseHi ? baseHi + padding : baseHi;
    if (source !== 'thermal' && lo < 0 && hi > 0) { const zeroPad = Math.max(Math.abs(lo), Math.abs(hi)) * 0.08; lo -= zeroPad; hi += zeroPad; }
    const span = Math.max(1, stats.endTs - stats.startTs);
    const x = (ts) => pad.left + Math.max(0, Math.min(1, (ts - stats.startTs) / span)) * plotW;
    const xy = (p) => ({ x: x(p.ts), y: pad.top + ((hi - Math.max(lo, Math.min(hi, p.value))) / (hi - lo)) * plotH });
    const grid = cssVar('--line', 'rgba(20,34,28,.1)'); const muted = cssVar('--text-3', '#6b756f'); const primary = cssVar('--primary', '#006b57');
    ctx.strokeStyle = grid; ctx.lineWidth = 1; ctx.fillStyle = muted; ctx.font = '12px system-ui, sans-serif'; ctx.textAlign = 'left';
    ctx.fillText(unit, pad.left, 14);
    if (values.length) {
      ctx.textAlign = 'right';
      for (let i = 0; i <= 3; i += 1) {
        const y = pad.top + (plotH * i) / 3; const rawValue = hi - ((hi - lo) * i) / 3;
        const displayValue = Math.abs(rawValue) < 0.05 ? 0 : rawValue;
        ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(width - pad.right, y); ctx.stroke();
        ctx.fillText(displayValue.toFixed(source === 'thermal' ? 1 : 0), pad.left - 6, y + 4);
      }
      if (source !== 'thermal' && lo < 0 && hi > 0) {
        const zeroY = pad.top + (hi / (hi - lo)) * plotH;
        ctx.strokeStyle = muted; ctx.setLineDash([4, 4]); ctx.beginPath(); ctx.moveTo(pad.left, zeroY); ctx.lineTo(width - pad.right, zeroY); ctx.stroke(); ctx.setLineDash([]);
      }
    } else {
      ctx.textAlign = 'center';
      ctx.fillText(source === 'thermal' ? '当前区间没有有效温度' : source === 'system' ? '当前区间没有足够系统快照' : '当前区间没有可计算的放电数据', width / 2, height / 2);
    }
    const timeLabel = (ts) => new Date(ts * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    const dateLabel = (ts) => new Date(ts * 1000).toLocaleDateString([], { month: '2-digit', day: '2-digit' });
    // Always render intermediate ticks. Endpoint-only labels made a dense
    // minute/hour series look empty and hid gaps between the endpoints.
    const tickCount = Math.max(4, Math.min(6, Math.floor(plotW / 64) + 1));
    const ticks = Array.from({ length: tickCount }, (_, index) => ({ ts: stats.startTs + (spanSec * index) / (tickCount - 1), index }));
    ctx.save();
    ctx.strokeStyle = grid; ctx.lineWidth = 1; ctx.setLineDash([2, 4]);
    ticks.forEach((tick) => {
      const tickX = x(tick.ts);
      ctx.beginPath(); ctx.moveTo(tickX, pad.top); ctx.lineTo(tickX, pad.top + plotH); ctx.stroke();
    });
    ctx.restore();
    ticks.forEach((tick) => {
      const tickX = x(tick.ts);
      ctx.textAlign = tick.index === 0 ? 'left' : tick.index === ticks.length - 1 ? 'right' : 'center';
      ctx.fillText(timeLabel(tick.ts), tickX, height - 8);
      if (showDates) ctx.fillText(dateLabel(tick.ts), tickX, height - 23);
    });
    ctx.strokeStyle = primary; ctx.fillStyle = primary; ctx.lineWidth = 2; ctx.lineJoin = 'round'; ctx.lineCap = 'round';
    segments.forEach((segment) => {
      ctx.setLineDash([]); ctx.beginPath();
      segment.forEach((point, index) => { const pos = xy(point); if (index === 0) ctx.moveTo(pos.x, pos.y); else ctx.lineTo(pos.x, pos.y); });
      if (segment.length === 1) { const pos = xy(segment[0]); ctx.arc(pos.x, pos.y, 2.5, 0, Math.PI * 2); ctx.fill(); }
      else ctx.stroke();
    });
    // Missing intervals are a separate timeline mark, never an interpolated
    // value. Keeping this below the grid prevents a solid gridline hiding dashes.
    if (gapRanges.length) {
      ctx.save(); ctx.strokeStyle = muted; ctx.lineWidth = 2; ctx.setLineDash([6, 5]);
      gapRanges.forEach((gap) => { ctx.beginPath(); ctx.moveTo(x(gap.startTs), pad.top + plotH + 10); ctx.lineTo(x(gap.endTs), pad.top + plotH + 10); ctx.stroke(); });
      ctx.restore(); ctx.setLineDash([]);
    }
  }

  function update(view, payload) {
    const { source, thermalSensor = 'module', rangeId, stats, status, summary, ranking, capture } = payload;
    const refreshDetails = payload.details !== false;
    setActive(view, source, rangeId, thermalSensor); view.stats = stats;
    view.hero.classList.toggle('warn', source === 'thermal' ? Number(stats?.current) >= 37 : ['partial', 'partial_window', 'reset_or_mismatch', 'insufficient_samples', 'no_coverage'].includes(stats?.backendQuality || stats?.quality));
    view.stateLine.textContent = status || '';
    view.stateLine.hidden = !status;
    const isThermal = source === 'thermal';
    const isSystem = source === 'system';
    view.heroKicker.textContent = isThermal ? (thermalSensor === 'battery' ? '系统电池温度' : '模块机身温度') : isSystem ? '系统统计平均耗电' : '模块监测平均耗电';
    view.heroValue.textContent = isThermal ? (Number.isFinite(stats?.current) ? `${stats.current.toFixed(1)}°C` : '—') : (Number.isFinite(stats?.avgMahPerHour) ? `${stats.avgMahPerHour.toFixed(1)} mAh/h` : Number.isFinite(stats?.avgMw) ? `${stats.avgMw.toFixed(0)} mW` : '—');
    view.heroStatus.textContent = isThermal ? (stats?.lastSampleTs ? `采样于 ${relativeTime(stats.lastSampleTs)} · 达到阈值 ${model().formatDuration(stats.thresholdSec)}` : '当前区间没有有效温度') : isSystem ? 'Android 原生 battery counter 历史；按真实 power_rates 统计，息屏与 Doze 缺测保留为未知' : (stats?.quality === 'good' ? '由模块电荷计差分或硬件电流电压计算' : stats?.quality === 'reset_or_mismatch' ? '电荷计重置或不一致；电荷差分停用，独立电流测量保留' : stats?.quality === 'partial' ? '仅统计有效区间；间断、息屏与非放电时段不计入平均值' : '有效功耗证据不足，未将电量百分比当成功耗');
    view.heroBadge.textContent = model().rangeFor(rangeId).label;
    const values = isThermal ? [stats?.min, stats?.avg, stats?.max] : [stats?.consumedMah, stats?.avgMahPerHour, stats?.avgMw];
    const labels = isThermal ? ['最低', '平均', '最高'] : ['实际耗电', '平均放电', '平均功率'];
    const suffixes = isThermal ? ['°C', '°C', '°C'] : [' mAh', ' mAh/h', ' mW'];
    view.summary.forEach((item, index) => { item.querySelector('span').textContent = labels[index]; item.querySelector('strong').textContent = Number.isFinite(values[index]) ? `${values[index].toFixed(1)}${suffixes[index]}` : '—'; });
    const backendCount = Number.isFinite(Number(stats?.backendSampleCount)) ? `后台记录 ${Number(stats.backendSampleCount)}` : `后台记录 ${stats?.sampleCount || 0}`;
    view.legend.textContent = `${backendCount} · 图表点 ${stats?.sampleCount || 0} · 有效 ${stats?.validCount ?? stats?.count ?? 0} · 有效覆盖 ${model().formatDuration(stats?.coverageSec)} · 未知 ${model().formatDuration(stats?.unknownSec)}${stats?.nonDischargeSec ? ` · 非放电 ${model().formatDuration(stats.nonDischargeSec)}` : ''}${stats?.gaps?.length ? ` · ${stats.gaps.length} 段间断` : ''}`;
    if (!isThermal) view.legend.textContent += ` · 曲线单位 ${stats?.seriesUnit || 'mAh/h'}（区间平均）`;
    if (refreshDetails) {
      view.moreBody.replaceChildren();
      const qualityLabel = { good: '有效区间连续', partial: '存在间断或缺测', reset_or_mismatch: '电荷计重置或不一致', insufficient: '证据不足', no_data: '没有有效数据' };
      const backendCoverage = Number.isFinite(Number(stats?.backendCoverageRatio)) ? Number(stats.backendCoverageRatio) * 100 : null;
      const coverageValue = backendCoverage === null ? stats?.coveragePct : backendCoverage;
      const invalidCount = Number.isFinite(Number(stats?.backendInvalidSamples)) ? Number(stats.backendInvalidSamples) : Number(stats?.missingCount || 0);
      const qualityText = `${qualityLabel[stats?.backendQuality] || qualityLabel[stats?.quality] || '数据质量未知'} · 覆盖率 ${Number.isFinite(Number(coverageValue)) ? Number(coverageValue).toFixed(1) + '%' : '—'}${invalidCount ? ` · 缺失/无效 ${invalidCount}` : ''}${Number.isFinite(Number(stats?.backendGapCount)) && stats.backendGapCount ? ` · 间断 ${stats.backendGapCount} 段` : ''}`;
      view.quality.textContent = qualityText;
      const qualityState = stats?.backendQuality || stats?.quality;
      view.quality.className = `analytics-status ${['good', 'complete_window', 'usable_window'].includes(qualityState) ? 'good' : ['no_data', 'no_coverage'].includes(qualityState) ? 'err' : 'warn'}`;
      view.quality.hidden = false;
      view.moreBody.append(row('数据范围', stats?.startTs && stats?.endTs ? relativeTime(stats.startTs) + ' — ' + relativeTime(stats.endTs) : '—'), row('后台记录数', stats?.backendSampleCount ?? stats?.sampleCount), row('后台有效记录', stats?.backendValidSamples ?? stats?.validCount ?? stats?.count), row('后台无效记录', stats?.backendInvalidSamples ?? stats?.missingCount), row('有效采样点', stats?.count), row('曲线有效覆盖', model().formatDuration(stats?.coverageSec)), row('曲线未知时长', model().formatDuration(stats?.unknownSec)));
      if (isThermal) {
        view.moreBody.append(row('温控阈值累计', model().formatDuration(stats?.thresholdSec)), row('温度传感器', thermalSensor === 'battery' ? '系统电池温度' : '模块机身温度'));
      }
      else {
        if (source === 'system') view.moreBody.append(row('数据口径', 'Android 原生 battery counter（硬件电荷计）与 power_rates；软件 UID 排行另标为模型估算'));
        view.moreBody.append(row('可证明放电', Number.isFinite(stats?.consumedMah) ? stats.consumedMah.toFixed(2) + ' mAh' : '—'), row('有效电荷差分时长', model().formatDuration(stats?.activeSec)), row('有效电流测量时长', model().formatDuration(stats?.measuredSec)), row('非放电时长', model().formatDuration(stats?.nonDischargeSec)), row('数据质量', qualityLabel[stats?.quality] || '未知'));
        if (source === 'system') {
          const totals = stats?.screenTotals || {}; const collection = stats?.collection || {}; const battery = stats?.batteryLevel;
          const onMah = totals.on_mah ?? totals.screen_on_mah; const offMah = totals.off_mah ?? totals.screen_off_mah; const onSec = totals.on_sec ?? totals.screen_on_sec; const offSec = totals.off_sec ?? totals.screen_off_sec;
          view.moreBody.append(row('亮屏/息屏耗电', `${onMah ?? '—'} / ${offMah ?? '—'} mAh`), row('亮屏/息屏区间', `${onSec ? model().formatDuration(onSec) : '—'} / ${offSec ? model().formatDuration(offSec) : '—'}`), row('屏幕/Doze 区段', stats?.screenSegments?.length ?? '—'), row('电量水平', battery == null ? '—' : `${battery}%`), row('最后采集', collection.last_success_ts ? relativeTime(collection.last_success_ts) : '—'), row('采集阶段', collection.phase || '—'));
        }
      }
      appendPowerAttribution(view.moreBody, summary, ranking);
      const policy = stats?.policy;
      if (policy && view.policy) {
        const enabled = policy.analytics_enabled !== false && policy.analytics_enabled !== 0 && policy.analytics_enabled !== 'false' && policy.analytics_enabled !== '0';
        if (!view.policy.dirty) {
          view.policy.enabled.checked = enabled;
          if (policy.retention_days != null) view.policy.retention.value = String(policy.retention_days);
          if (policy.max_bytes != null) view.policy.cap.value = String(Math.max(8, Math.min(32, Math.round(Number(policy.max_bytes) / 1048576))));
          if (policy.system_interval_on_sec != null) view.policy.onInterval.value = String(Math.max(5, Math.min(60, Math.round(Number(policy.system_interval_on_sec) / 60))));
          if (policy.system_interval_off_sec != null) view.policy.offInterval.value = String(Math.max(15, Math.min(120, Math.round(Number(policy.system_interval_off_sec) / 60))));
        }
        view.policy.button.disabled = !view.policy.dirty;
        [view.policy.retention, view.policy.cap, view.policy.onInterval, view.policy.offInterval].forEach((field) => { field.disabled = !enabled && !view.policy.dirty; });
        view.policy.state.textContent = enabled
          ? `${policy.phase || 'effective'} · 已开启 · 保留 ${policy.retention_days ?? '—'} 天 · 上限 ${policy.max_bytes ? Math.round(Number(policy.max_bytes) / 1048576) : '—'} MiB${view.policy.dirty ? ' · 有未保存修改' : ''}`
          : `${policy.phase || 'effective'} · 已关闭 · 不写入历史、不运行系统归因${view.policy.dirty ? ' · 有未保存修改' : ''}`;
      }
    }
    draw(view, source, stats);
    if (capture) { view.captureState.textContent = capture.session ? `${capture.session.status || '运行中'} · ${capture.session.sample_count || 0} 个采样点` : '未开始记录'; view.captureBtn.textContent = capture.session?.status === 'running' ? '结束记录' : '开始记录'; view.captureExport.disabled = !capture.session || capture.session.status === 'running'; }
  }

  function loading(view, source, rangeId, thermalSensor = 'module') {
    // A source/range switch must not leave an old curve under the new heading.
    const stats = source === 'thermal' ? model().temperatureStats([]) : model().powerStats([]);
    update(view, { source, thermalSensor, rangeId, stats, status: '正在读取采样…', summary: null, capture: null });
    view.legend.textContent = '等待当前区间的真实采样';
  }
  function empty(view, source, rangeId, message, thermalSensor = 'module') { setActive(view, source, rangeId, thermalSensor); view.stateLine.hidden = false; view.stateLine.textContent = message || '当前时段没有足够采样'; }
  function error(view, source, rangeId, message, thermalSensor = 'module') { setActive(view, source, rangeId, thermalSensor); view.stateLine.hidden = false; view.stateLine.className = 'analytics-error'; view.stateLine.textContent = message || '读取失败'; }

  registerFeature('analyticsView', { create, update, loading, empty, error, setCustomValues, promptCustom });
})();
