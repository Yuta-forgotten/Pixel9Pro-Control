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
    intro.append(el('div', 'analytics-section-title', '历史趋势'), el('div', 'analytics-section-desc', '选择温度或功耗，按时段查看真实采样与覆盖质量。'));
    const source = el('div', 'analytics-range');
    source.setAttribute('role', 'tablist'); source.setAttribute('aria-label', '数据类型');
    ['thermal', 'power'].forEach((kind) => {
      const button = el('button', 'analytics-range-btn', kind === 'thermal' ? '温度' : '功耗');
      button.type = 'button'; button.dataset.analyticsSource = kind; button.setAttribute('role', 'tab'); button.setAttribute('aria-selected', String(kind === 'thermal')); button.tabIndex = kind === 'thermal' ? 0 : -1;
      button.addEventListener('click', () => callbacks.onSource(kind));
      source.appendChild(button);
    });
    const range = el('div', 'analytics-range');
    range.setAttribute('role', 'tablist'); range.setAttribute('aria-label', '统计区间');
    model().ranges().forEach((item) => {
      const button = el('button', 'analytics-range-btn', item.shortLabel || item.label);
      button.type = 'button'; button.dataset.analyticsRange = item.id; button.setAttribute('role', 'tab'); button.setAttribute('aria-selected', String(item.id === '30')); button.tabIndex = item.id === '30' ? 0 : -1;
      button.addEventListener('click', () => callbacks.onRange(item.id));
      range.appendChild(button);
    });
    const custom = el('div', 'analytics-custom-range');
    const days = document.createElement('select'); days.setAttribute('aria-label', '最近天数');
    for (let value = 1; value <= 7; value += 1) days.appendChild(el('option', '', String(value) + ' 天'));
    const granularity = document.createElement('select'); granularity.setAttribute('aria-label', '采样粒度');
    granularity.append(el('option', '', '按小时'), el('option', '', '按分钟'));
    granularity.options[0].value = 'hour'; granularity.options[1].value = 'minute';
    const apply = el('button', 'tiny-btn tonal', '应用范围'); apply.type = 'button';
    apply.addEventListener('click', () => callbacks.onCustom(days.value, granularity.value));
    const daysField = el('label', 'analytics-custom-field'); daysField.append(el('span', 'analytics-section-desc', '最近'), days);
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
    chartHead.append(el('div', 'analytics-section-title', '趋势图'), el('div', 'analytics-section-desc', '连续采样用实线，缺测区间用虚线表示。'));
    const chartCard = el('div', 'analytics-chart-card');
    const chartWrap = el('div', 'analytics-chart-wrap');
    const canvas = document.createElement('canvas');
    canvas.setAttribute('role', 'img'); canvas.setAttribute('aria-label', '历史趋势图');
    chartWrap.appendChild(canvas); chartCard.appendChild(chartWrap);
    const legend = el('div', 'analytics-chart-legend'); chartCard.appendChild(legend);
    chartSection.append(chartHead, chartCard);
    const more = document.createElement('details'); more.className = 'analytics-disclosure';
    const moreSummary = el('summary', 'analytics-disclosure-summary');
    const moreCopy = el('span', 'analytics-disclosure-copy'); moreCopy.append(el('strong', '', '更多统计'), el('small', '', '采样覆盖、差分口径与阈值时长'));
    moreSummary.append(moreCopy, el('span', 'analytics-disclosure-chevron', '›'));
    const moreBody = el('div', 'analytics-disclosure-body'); more.append(moreSummary, moreBody);
    const capture = el('section', 'analytics-capture-card');
    const captureState = el('div', 'analytics-capture-state', '未开始记录');
    const captureControls = el('div', 'analytics-actions');
    const duration = document.createElement('input'); duration.type = 'number'; duration.min = '0'; duration.max = '86400'; duration.step = '60'; duration.value = '0'; duration.placeholder = '0 = 手动结束'; duration.setAttribute('aria-label', '记录时长（秒）');
    const captureBtn = el('button', 'tiny-btn primary', '开始记录'); captureBtn.type = 'button';
    captureBtn.addEventListener('click', () => callbacks.onCapture(captureBtn, Number(duration.value) || 0));
    const captureExport = el('button', 'tiny-btn tonal', '导出记录'); captureExport.type = 'button';
    captureExport.addEventListener('click', () => callbacks.onCaptureExport(captureExport));
    captureControls.append(duration, captureBtn, captureExport);
    capture.append(el('div', 'analytics-section-title', '低功耗记录'), el('div', 'analytics-section-desc', '后台按设备采样策略记录时间戳、功耗、温度、屏幕状态、Top 进程与 ODPM；息屏温度缺测会保留为空。'), captureState, captureControls);
    const actions = el('div', 'analytics-export-actions analytics-actions');
    const exportWindow = el('button', 'tiny-btn tonal', '导出当前区间'); exportWindow.type = 'button';
    exportWindow.addEventListener('click', () => callbacks.onExport(exportWindow)); actions.appendChild(exportWindow);
    root.append(intro, source, range, custom, stateLine, hero, chartSection, more, capture, actions);
    view.root = root; view.sourceGroup = source; view.rangeGroup = range; view.custom = custom; view.customDays = days; view.customGranularity = granularity; view.stateLine = stateLine; view.hero = hero;
    view.heroKicker = heroHead.querySelector('.analytics-hero-kicker'); view.heroValue = heroHead.querySelector('.analytics-hero-value'); view.heroStatus = heroHead.querySelector('.analytics-hero-status'); view.heroBadge = heroHead.querySelector('.analytics-hero-badge'); view.summary = Array.from(summary.children); view.canvas = canvas; view.legend = legend; view.moreBody = moreBody; view.captureState = captureState; view.captureBtn = captureBtn; view.captureExport = captureExport; view.duration = duration; view.exportWindow = exportWindow;
    return view;
  }

  function setActive(view, source, rangeId) {
    view.source = source;
    view.stateLine.className = 'analytics-status';
    view.sourceGroup.querySelectorAll('[data-analytics-source]').forEach((node) => { const active = node.dataset.analyticsSource === source; node.classList.toggle('active', active); node.setAttribute('aria-selected', String(active)); node.tabIndex = active ? 0 : -1; });
    view.rangeGroup.querySelectorAll('[data-analytics-range]').forEach((node) => { const active = node.dataset.analyticsRange === String(rangeId); node.classList.toggle('active', active); node.setAttribute('aria-selected', String(active)); node.tabIndex = active ? 0 : -1; });
    view.custom.hidden = String(rangeId) !== 'custom';
  }

  function setCustomValues(view, days, granularity) {
    view.customDays.value = String(Math.min(7, Math.max(1, Number(days) || 1)));
    view.customGranularity.value = granularity === 'minute' ? 'minute' : 'hour';
  }

  function promptCustom(view) {
    setActive(view, view.source, 'custom');
    view.stateLine.hidden = false;
    view.stateLine.textContent = '选择最近天数和采样精细度后应用';
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

  function appendPowerAttribution(body, summary) {
    body.append(el('div', 'analytics-section-title', '软件耗电排行'), el('div', 'analytics-section-desc', '来自当前 batterystats 窗口；仅展示有正向耗电归因的项目。'));
    const hasFull = summary && (Number(summary.system_generated_at) > 0 || summary.fast !== true);
    if (!hasFull) {
      body.appendChild(el('div', 'analytics-empty', '系统归因正在后台更新，趋势数据不受影响。'));
      return;
    }
    const apps = (Array.isArray(summary.apps) ? summary.apps : [])
      .map((app) => ({ value: Number(app.mah), label: packageLabel(app), subtitle: [app.pkg, app.category, app.uid || (Number.isFinite(Number(app.uid_num)) ? 'UID ' + app.uid_num : '')].filter(Boolean).join(' · ') }))
      .filter((app) => Number.isFinite(app.value) && app.value > 0)
      .sort((a, b) => b.value - a.value);
    const components = [
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
    const values = [['系统估算总耗电', summary.drain], ['当前统计窗口', summary.bat_time]];
    const list = el('div', 'data-list');
    values.forEach(([label, value]) => { if (value !== null && value !== undefined && value !== '') list.appendChild(row(label, label === '系统估算总耗电' ? value + ' mAh' : value)); });
    if (list.childElementCount) body.appendChild(list);
  }

  function draw(view, source, stats) {
    const canvas = view.canvas;
    if (!canvas || !stats) return;
    const width = Math.max(240, Math.round(canvas.getBoundingClientRect().width || 320));
    const height = 210;
    const dpr = Math.min(2, Math.max(1, window.devicePixelRatio || 1));
    if (canvas.width !== Math.round(width * dpr) || canvas.height !== Math.round(height * dpr)) { canvas.width = Math.round(width * dpr); canvas.height = Math.round(height * dpr); }
    const ctx = canvas.getContext('2d'); ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, width, height);
    const points = source === 'thermal' ? stats.points.map((p) => ({ ts: p.ts, value: p.tempC })) : stats.series;
    if (points.length < 2) return;
    const pad = { left: 42, right: 10, top: 12, bottom: 28 }; const plotW = width - pad.left - pad.right; const plotH = height - pad.top - pad.bottom;
    const values = points.map((p) => Number(p.value)).filter(Number.isFinite);
    if (values.length < 2) return;
    const min = Math.min(...values); const max = Math.max(...values);
    const padding = source === 'thermal' ? 1 : Math.max(1, Math.abs(max || min) * 0.2);
    const lo = min === max ? min - padding : min; const hi = min === max ? max + padding : max; const span = Math.max(1, points[points.length - 1].ts - points[0].ts);
    const xy = (p) => ({ x: pad.left + ((p.ts - points[0].ts) / span) * plotW, y: pad.top + ((hi - p.value) / (hi - lo)) * plotH });
    const grid = cssVar('--line', 'rgba(20,34,28,.1)'); const muted = cssVar('--text-3', '#6b756f'); const primary = cssVar('--primary', '#006b57');
    ctx.strokeStyle = grid; ctx.lineWidth = 1; ctx.fillStyle = muted; ctx.font = '10px sans-serif'; ctx.textAlign = 'right';
    for (let i = 0; i <= 3; i += 1) {
      const y = pad.top + (plotH * i) / 3; const rawValue = hi - ((hi - lo) * i) / 3;
      const displayValue = Math.abs(rawValue) < 0.05 ? 0 : rawValue;
      ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(width - pad.right, y); ctx.stroke();
      ctx.fillText(displayValue.toFixed(source === 'thermal' ? 1 : 0) + (source === 'thermal' ? '°' : ''), pad.left - 5, y + 3);
    }
    ctx.textAlign = 'left'; ctx.fillText(new Date(points[0].ts * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }), pad.left, height - 8); ctx.textAlign = 'right'; ctx.fillText(new Date(points[points.length - 1].ts * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }), width - pad.right, height - 8);
    const gapSet = new Set((stats.gaps || []).map((gap) => `${gap[0].ts}:${gap[1].ts}`)); ctx.strokeStyle = primary; ctx.lineWidth = 2; ctx.lineJoin = 'round'; ctx.lineCap = 'round';
    let segment = [points[0]];
    const flush = (items, dashed = false) => { if (items.length < 2) return; ctx.save(); ctx.setLineDash(dashed ? [6, 5] : []); ctx.beginPath(); items.forEach((point, index) => { const pos = xy(point); if (index === 0) ctx.moveTo(pos.x, pos.y); else ctx.lineTo(pos.x, pos.y); }); ctx.stroke(); ctx.restore(); };
    for (let i = 1; i < points.length; i += 1) { const key = `${points[i - 1].ts}:${points[i].ts}`; if (gapSet.has(key)) { flush(segment); flush([points[i - 1], points[i]], true); segment = []; } segment.push(points[i]); }
    flush(segment);
  }

  function update(view, payload) {
    const { source, rangeId, stats, status, summary, capture } = payload;
    setActive(view, source, rangeId); view.stats = stats;
    view.hero.classList.toggle('warn', source === 'thermal' ? Number(stats?.current) >= 37 : stats?.quality === 'partial' || stats?.quality === 'reset_or_mismatch');
    view.stateLine.textContent = status || '';
    view.stateLine.hidden = !status;
    const isThermal = source === 'thermal';
    view.heroKicker.textContent = isThermal ? '当前温度' : '平均放电功耗';
    view.heroValue.textContent = isThermal ? (Number.isFinite(stats?.current) ? `${stats.current.toFixed(1)}°C` : '—') : (Number.isFinite(stats?.avgMahPerHour) ? `${stats.avgMahPerHour.toFixed(1)} mAh/h` : Number.isFinite(stats?.avgMw) ? `${stats.avgMw.toFixed(0)} mW` : '—');
    view.heroStatus.textContent = isThermal ? (Number.isFinite(stats?.thresholdSec) ? `达到阈值 ${model().formatDuration(stats.thresholdSec)}` : '阈值持续时间不可用') : (stats?.quality === 'good' ? '由电荷计差分或硬件电流电压计算' : stats?.quality === 'reset_or_mismatch' ? '检测到电荷计重置或窗口不一致，暂不作平均功耗结论' : '有效功耗证据不足，未将电量百分比当成功耗');
    view.heroBadge.textContent = model().rangeFor(rangeId).label;
    const values = isThermal ? [stats?.min, stats?.avg, stats?.max] : [stats?.consumedMah, stats?.avgMahPerHour, stats?.avgMw];
    const labels = isThermal ? ['最低', '平均', '最高'] : ['实际耗电', '平均放电', '平均功率'];
    const suffixes = isThermal ? ['°C', '°C', '°C'] : [' mAh', ' mAh/h', ' mW'];
    view.summary.forEach((item, index) => { item.querySelector('span').textContent = labels[index]; item.querySelector('strong').textContent = Number.isFinite(values[index]) ? `${values[index].toFixed(1)}${suffixes[index]}` : '—'; });
    view.legend.textContent = !isThermal && (!stats?.series || stats.series.length < 2)
      ? '暂无有效功耗差分，等待下一次采样'
      : stats?.count ? `${stats.count} 个采样点 · 覆盖 ${model().formatDuration(stats.coverageSec)}${stats.gaps?.length ? ` · ${stats.gaps.length} 段缺测` : ''}` : '暂无足够采样点';
    view.moreBody.replaceChildren();
    if (isThermal) view.moreBody.append(row('数据范围', stats?.startTs && stats?.endTs ? relativeTime(stats.startTs) + ' — ' + relativeTime(stats.endTs) : '—'), row('采样点', stats?.count), row('温控阈值累计', model().formatDuration(stats?.thresholdSec)));
    else {
      view.moreBody.append(row('有效采样点', stats?.count), row('可证明放电', Number.isFinite(stats?.consumedMah) ? stats.consumedMah.toFixed(2) + ' mAh' : '—'), row('有效差分时长', model().formatDuration(stats?.activeSec)), row('数据质量', stats?.quality));
      appendPowerAttribution(view.moreBody, summary);
    }
    draw(view, source, stats);
    if (capture) { view.captureState.textContent = capture.session ? `${capture.session.status || '运行中'} · ${capture.session.sample_count || 0} 个采样点` : '未开始记录'; view.captureBtn.textContent = capture.session?.status === 'running' ? '结束记录' : '开始记录'; view.captureExport.disabled = !capture.session || capture.session.status === 'running'; }
  }

  function loading(view, source, rangeId) { setActive(view, source, rangeId); view.stateLine.hidden = false; view.stateLine.textContent = '正在读取采样…'; view.heroValue.textContent = '—'; view.legend.textContent = '趋势图将在后台原位加载'; }
  function empty(view, source, rangeId, message) { setActive(view, source, rangeId); view.stateLine.hidden = false; view.stateLine.textContent = message || '当前时段没有足够采样'; view.legend.textContent = '暂无可绘制数据'; }
  function error(view, source, rangeId, message) { setActive(view, source, rangeId); view.stateLine.hidden = false; view.stateLine.className = 'analytics-error'; view.stateLine.textContent = message || '读取失败'; }

  registerFeature('analyticsView', { create, update, loading, empty, error, setCustomValues, promptCustom });
})();
