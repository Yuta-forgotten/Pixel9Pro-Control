'use strict';
(() => {
  const model = () => requireFeature('analyticsModel');
  const CHART_PAD = Object.freeze({ left: 46, right: 12, top: 22, bottom: 42 });
  const cssVar = (name, fallback) => getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback;

  const el = (tag, className = '', text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  function bindTabKeys(group) {
    group.addEventListener('keydown', (event) => {
      const tabs = Array.from(group.querySelectorAll('[role="tab"]'));
      const index = tabs.indexOf(event.target);
      if (index < 0 || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
      event.preventDefault();
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1
        : (index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
      tabs[next].focus();
      tabs[next].click();
    });
  }

  function create(callbacks) {
    const view = { callbacks, stats: null, sensor: 'module' };
    const root = el('div', 'analytics-overview');

    const sensorGroup = el('div', 'analytics-range analytics-sensor-range');
    sensorGroup.setAttribute('role', 'tablist');
    sensorGroup.setAttribute('aria-label', '温度传感器');
    [['module', '机身'], ['battery', '电池']].forEach(([sensor, label]) => {
      const button = el('button', 'analytics-range-btn', label);
      button.type = 'button';
      button.dataset.thermalSensor = sensor;
      button.setAttribute('role', 'tab');
      button.addEventListener('click', () => callbacks.onSensor(sensor));
      sensorGroup.appendChild(button);
    });
    bindTabKeys(sensorGroup);

    const rangeGroup = el('div', 'analytics-range');
    rangeGroup.setAttribute('role', 'tablist');
    rangeGroup.setAttribute('aria-label', '时间范围');
    model().ranges().forEach((range) => {
      const button = el('button', 'analytics-range-btn', range.shortLabel);
      button.type = 'button';
      button.dataset.range = range.id;
      button.setAttribute('role', 'tab');
      button.addEventListener('click', () => callbacks.onRange(range.id));
      rangeGroup.appendChild(button);
    });
    bindTabKeys(rangeGroup);

    const custom = el('div', 'analytics-custom-range');
    custom.hidden = true;
    const customWindow = document.createElement('select');
    customWindow.setAttribute('aria-label', '自定义时间范围');
    [['14400', '4 小时'], ['28800', '8 小时'], ['43200', '12 小时'], ['86400', '1 天'], ['259200', '3 天'], ['604800', '7 天']].forEach(([seconds, label]) => {
      const option = el('option', '', label);
      option.value = seconds;
      customWindow.appendChild(option);
    });
    const applyCustom = el('button', 'tiny-btn tonal', '应用');
    applyCustom.type = 'button';
    applyCustom.addEventListener('click', () => callbacks.onCustom(Number(customWindow.value)));
    custom.append(customWindow, applyCustom);

    const stateLine = el('div', 'analytics-status');
    stateLine.setAttribute('role', 'status');
    stateLine.hidden = true;

    const hero = el('section', 'analytics-hero');
    const heroHead = el('div', 'analytics-hero-head');
    const heroCopy = el('div', 'analytics-hero-copy');
    const heroKicker = el('div', 'analytics-hero-kicker');
    const heroValue = el('div', 'analytics-hero-value');
    const heroStatus = el('div', 'analytics-hero-status');
    heroCopy.append(heroKicker, heroValue, heroStatus);
    const heroBadge = el('span', 'analytics-hero-badge');
    heroHead.append(heroCopy, heroBadge);
    const summary = el('div', 'analytics-summary-grid');
    ['最低', '采样均值', '最高'].forEach((label) => {
      const item = el('div', 'analytics-summary-item');
      item.append(el('span', '', label), el('strong', '', '—'));
      summary.appendChild(item);
    });
    hero.append(heroHead, summary);

    const chartSection = el('section', 'analytics-section');
    const chartHead = el('div', 'analytics-section-head');
    chartHead.appendChild(el('div', 'analytics-section-title', '趋势图'));
    const chartCard = el('div', 'analytics-chart-card');
    const chartWrap = el('div', 'analytics-chart-wrap');
    const canvas = document.createElement('canvas');
    canvas.setAttribute('role', 'img');
    canvas.setAttribute('aria-label', '温度历史趋势图');
    canvas.tabIndex = 0;
    const tooltip = el('div', 'analytics-chart-tooltip');
    tooltip.hidden = true;
    tooltip.setAttribute('role', 'status');
    chartWrap.append(canvas, tooltip);
    const legend = el('div', 'analytics-chart-legend');
    chartCard.append(chartWrap, legend);
    chartSection.append(chartHead, chartCard);

    const refresh = el('button', 'tiny-btn tonal', '刷新');
    refresh.type = 'button';
    refresh.addEventListener('click', () => callbacks.onRefresh(refresh));
    chartHead.classList.add('analytics-chart-head');
    chartHead.appendChild(refresh);
    const exportPanel = el('details', 'disclosure compact analytics-export');
    const exportSummary = el('summary', 'disclosure-summary');
    const exportCopy = el('span', 'disclosure-copy');
    const exportScope = el('small', '', '当前传感器与时间区间');
    exportCopy.append(el('strong', '', '导出记录'), exportScope);
    const chevron = el('span', 'disclosure-chevron', '›');
    chevron.setAttribute('aria-hidden', 'true');
    exportSummary.append(exportCopy, chevron);
    const exportBody = el('div', 'disclosure-body');
    const formatLabel = el('label', 'analytics-export-label', '文件格式');
    formatLabel.htmlFor = 'analytics-export-format';
    const exportControls = el('div', 'analytics-export-controls');
    const exportFormat = document.createElement('select');
    exportFormat.id = 'analytics-export-format';
    exportFormat.setAttribute('aria-label', '温度历史导出格式');
    [['csv', 'CSV 表格'], ['json', 'JSON 数据']].forEach(([value, label]) => {
      const option = el('option', '', label);
      option.value = value;
      exportFormat.appendChild(option);
    });
    const exportButton = el('button', 'tiny-btn primary', '导出当前区间');
    exportButton.type = 'button';
    exportButton.disabled = true;
    exportButton.addEventListener('click', () => callbacks.onExport(exportFormat.value));
    exportControls.append(exportFormat, exportButton);
    exportBody.append(formatLabel, exportControls);
    exportPanel.append(exportSummary, exportBody);

    root.append(sensorGroup, rangeGroup, custom, stateLine, hero, chartSection, exportPanel);
    Object.assign(view, {
      root, sensorGroup, rangeGroup, custom, customWindow, stateLine, hero,
      heroKicker, heroValue, heroStatus, heroBadge,
      summary: Array.from(summary.children), canvas, tooltip, legend, refresh, exportFormat, exportButton, exportScope
    });
    canvas.addEventListener('pointermove', (event) => showNearestPoint(view, event.clientX));
    canvas.addEventListener('pointerleave', () => { tooltip.hidden = true; });
    return view;
  }

  function setActive(view, sensor, rangeId) {
    view.sensor = sensor;
    view.sensorGroup.querySelectorAll('[data-thermal-sensor]').forEach((button) => {
      const active = button.dataset.thermalSensor === sensor;
      button.classList.toggle('active', active);
      button.setAttribute('aria-selected', String(active));
      button.tabIndex = active ? 0 : -1;
    });
    view.rangeGroup.querySelectorAll('[data-range]').forEach((button) => {
      const active = button.dataset.range === String(rangeId);
      button.classList.toggle('active', active);
      button.setAttribute('aria-selected', String(active));
      button.tabIndex = active ? 0 : -1;
    });
    view.custom.hidden = rangeId !== 'custom';
    view.stateLine.className = 'analytics-status';
  }

  function draw(view, stats) {
    const canvas = view.canvas;
    const rect = canvas.getBoundingClientRect();
    const width = Math.max(180, Math.round(rect.width || 320));
    const height = Math.max(180, Math.round(rect.height || 220));
    const dpr = Math.min(2, Math.max(1, window.devicePixelRatio || 1));
    if (canvas.width !== Math.round(width * dpr) || canvas.height !== Math.round(height * dpr)) {
      canvas.width = Math.round(width * dpr);
      canvas.height = Math.round(height * dpr);
    }
    const context = canvas.getContext('2d');
    if (!context) return;
    context.setTransform(dpr, 0, 0, dpr, 0, 0);
    context.clearRect(0, 0, width, height);
    const segments = stats?.chartSegments || [];
    const points = segments.flat();
    const values = points.map((point) => point.value).filter(Number.isFinite);
    const start = Number(stats?.startTs);
    const end = Number(stats?.endTs);
    const span = Number.isFinite(start) && Number.isFinite(end) ? Math.max(1, end - start) : 1;
    const pad = CHART_PAD;
    const plotWidth = width - pad.left - pad.right;
    const plotHeight = height - pad.top - pad.bottom;
    const min = values.length ? Math.min(...values) : 0;
    const max = values.length ? Math.max(...values) : 1;
    const padding = min === max ? 0.5 : Math.max(0.3, (max - min) * 0.08);
    const low = min - padding;
    const high = max + padding;
    const x = (ts) => pad.left + Math.max(0, Math.min(1, (ts - start) / span)) * plotWidth;
    const y = (value) => pad.top + ((high - value) / (high - low)) * plotHeight;
    const grid = cssVar('--line', 'rgba(20,34,28,.1)');
    const muted = cssVar('--text-3', '#6b756f');
    const primary = cssVar('--primary', '#006b57');

    context.font = '12px system-ui, sans-serif';
    context.strokeStyle = grid;
    context.fillStyle = muted;
    for (let index = 0; index <= 3; index += 1) {
      const value = high - (high - low) * index / 3;
      const lineY = pad.top + plotHeight * index / 3;
      context.beginPath();
      context.moveTo(pad.left, lineY);
      context.lineTo(width - pad.right, lineY);
      context.stroke();
      context.textAlign = 'right';
      context.fillText(value.toFixed(1), pad.left - 6, lineY + 4);
    }
    context.textAlign = 'left';
    context.fillText('°C', pad.left, 13);

    if (!points.length || !Number.isFinite(start) || !Number.isFinite(end)) {
      context.textAlign = 'center';
      context.fillText('当前区间暂无温度记录', width / 2, height / 2);
      canvas.setAttribute('aria-label', '当前区间暂无温度记录');
      return;
    }

    const tickCount = width < 420 ? 3 : 5;
    context.strokeStyle = grid;
    context.fillStyle = muted;
    for (let index = 0; index < tickCount; index += 1) {
      const ts = start + span * index / (tickCount - 1);
      const tickX = x(ts);
      context.beginPath();
      context.moveTo(tickX, pad.top);
      context.lineTo(tickX, pad.top + plotHeight);
      context.stroke();
      context.textAlign = index === 0 ? 'left' : index === tickCount - 1 ? 'right' : 'center';
      const tickDate = new Date(ts * 1000);
      if (span >= 86400) context.fillText(tickDate.toLocaleDateString([], { month: '2-digit', day: '2-digit' }), tickX, height - 23);
      context.fillText(tickDate.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false }), tickX, height - 8);
    }

    context.strokeStyle = primary;
    context.fillStyle = primary;
    context.lineWidth = 2;
    context.lineJoin = 'round';
    context.lineCap = 'round';
    segments.forEach((segment) => {
      if (!segment.length) return;
      context.beginPath();
      segment.forEach((point, index) => {
        if (index === 0) context.moveTo(x(point.ts), y(point.value));
        else context.lineTo(x(point.ts), y(point.value));
      });
      if (segment.length === 1) {
        context.arc(x(segment[0].ts), y(segment[0].value), 2.5, 0, Math.PI * 2);
        context.fill();
      } else context.stroke();
    });
    if (stats.gapRanges?.length) {
      context.save();
      context.strokeStyle = muted;
      context.lineWidth = 2;
      context.setLineDash([6, 5]);
      stats.gapRanges.forEach((gap) => {
        context.beginPath();
        context.moveTo(x(gap.startTs), pad.top + plotHeight + 8);
        context.lineTo(x(gap.endTs), pad.top + plotHeight + 8);
        context.stroke();
      });
      context.restore();
      context.setLineDash([]);
    }
    canvas.setAttribute('aria-label', `温度趋势图，${stats.count} 个有效温度点`);
  }

  function showNearestPoint(view, clientX) {
    const stats = view.stats;
    const rect = view.canvas.getBoundingClientRect();
    const points = (stats?.chartSegments || []).flat();
    if (!points.length || !rect.width) return;
    const plotWidth = Math.max(1, rect.width - CHART_PAD.left - CHART_PAD.right);
    const ratio = Math.max(0, Math.min(1, (clientX - rect.left - CHART_PAD.left) / plotWidth));
    const target = stats.startTs + ratio * (stats.endTs - stats.startTs);
    const point = points.reduce((nearest, item) => !nearest || Math.abs(item.ts - target) < Math.abs(nearest.ts - target) ? item : nearest, null);
    if (!point) return;
    const date = new Date(point.ts * 1000);
    view.tooltip.textContent = `${date.toLocaleString([], { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })} · ${point.value.toFixed(1)}°C`;
    view.tooltip.hidden = false;
  }

  function update(view, payload) {
    const { sensor, rangeId, stats, status } = payload;
    view.stats = stats;
    view.exportButton.disabled = !payload.exportable;
    setActive(view, sensor, rangeId);
    view.stateLine.textContent = status || '';
    view.stateLine.hidden = !status;
    view.hero.classList.toggle('warn', Number(stats?.current) >= 40);
    view.heroKicker.textContent = sensor === 'battery' ? '最近电池温度' : '最近机身温度';
    view.heroValue.textContent = Number.isFinite(stats?.current) ? `${stats.current.toFixed(1)}°C` : '—';
    view.heroStatus.textContent = stats?.lastSampleTs
      ? `记录于 ${new Date(stats.lastSampleTs * 1000).toLocaleString([], { hour: '2-digit', minute: '2-digit' })}`
      : '—';
    view.heroBadge.textContent = model().rangeFor(rangeId).label;
    view.exportScope.textContent = `${sensor === 'battery' ? '电池' : '机身'} · ${model().rangeFor(rangeId).label}`;
    const values = [stats?.min, stats?.avg, stats?.max];
    view.summary.forEach((item, index) => {
      item.querySelector('strong').textContent = Number.isFinite(values[index]) ? `${values[index].toFixed(1)}°C` : '—';
    });
    view.legend.textContent = `${stats?.validCount ?? 0} 个有效点 · 覆盖 ${model().formatDuration(stats?.coverageSec)} · 间断 ${stats?.gapCount ?? 0}`;
    draw(view, stats);
  }

  function loading(view, sensor, rangeId, stats) {
    update(view, { sensor, rangeId, stats, status: '正在读取温度记录…' });
    view.legend.textContent = '正在读取';
  }

  function error(view, sensor, rangeId, stats, message) {
    update(view, { sensor, rangeId, stats, status: message || '温度历史读取失败' });
    view.stateLine.className = 'analytics-error';
  }

  registerFeature('analyticsView', { create, update, loading, error });
})();
