// 温控档位、传感器状态与温度历史功能。
'use strict';
(() => {
const state = {
  contract: null,
  currentOffset: null,
  thermalBusy: false,
  thermalBadReads: 0,
  lastSkinTempC: null,
  thermalApplyBusy: false,
  sensorRefs: null,
  homeSensorRefs: null,
  thermalModal: { pending: null, prev: null },
  tempChart: { timer: null, draw: null, activeRange: 10, requestId: 0 }
};

const core = () => requireFeature('core');
const apiFetch = (...args) => core().apiFetch(...args);
const appendLog = (...args) => core().appendLog(...args);
const buildInfoRow = (...args) => core().buildInfoRow(...args);
const showToast = (...args) => core().showToast(...args);
const fmtDuration = (...args) => requireFeature('energy').formatDuration(...args);
const setStaticHtml = (...args) => requireFeature('ui').setStaticHtml(...args);
const pushModalState = (...args) => requireFeature('ui').pushModalState(...args);
const openRebootModal = (...args) => requireFeature('ui').openRebootModal(...args);
const stopEnergyDetailRefresh = () => requireFeature('energy').stop();

// 温度色阶 (单一真源): 青绿→黄→橙→红, 语义固定不交动态色 (doc 17 §11)
const TEMP_SCALE = [
  { max: 36, color: '#23a78c' }, // 凉爽
  { max: 40, color: '#4aa95f' }, // 正常
  { max: 44, color: '#bf8b16' }, // 偏热
  { max: 48, color: '#d97c34' }, // 热
  { color: '#c3472d' },          // 过热
];

function tempHex(t) {
  for (const stop of TEMP_SCALE) {
    if (stop.max === undefined || t < stop.max) return stop.color;
  }
  return TEMP_SCALE[TEMP_SCALE.length - 1].color;
}

function tempStatus(t) {
  const offset = Number(state.currentOffset);
  const modThresh = THRESH_STOCK + (Number.isFinite(offset) ? offset : 0);
  if (t < 36) return '凉爽';
  if (t < THRESH_STOCK) return '正常';
  if (t < modThresh) return '已高于原厂阈值，当前仍在放宽区间';
  if (t < modThresh + 4) return '系统已开始主动降温';
  if (t < 55) return '温度持续偏高，系统正在加强降温';
  return '温度过高，系统已严格限制性能';
}

function barPct(t) {
  return Math.min(Math.max((t - TEMP_MIN) / (TEMP_MAX - TEMP_MIN), 0), 1) * 100;
}

function positionMarkers() {
  const stockPct = barPct(THRESH_STOCK);
  refs.mkStock.style.left = `${stockPct}%`;
  refs.mkStockLbl.style.left = `${stockPct}%`;
  refs.mkStockLbl.textContent = `${THRESH_STOCK}°C 原厂`;
  if (!Number.isFinite(Number(state.currentOffset))) {
    refs.mkMod.style.display = 'none';
    refs.mkModLbl.style.display = 'none';
    return;
  }
  const modThresh = THRESH_STOCK + Number(state.currentOffset);
  const modPct = barPct(modThresh);
  refs.mkMod.style.left = `${modPct}%`;
  refs.mkModLbl.style.left = `${modPct}%`;
  refs.mkModLbl.textContent = state.currentOffset === 0 ? '' : `${modThresh}°C 当前`;
  refs.mkMod.style.display = state.currentOffset === 0 ? 'none' : '';
  refs.mkModLbl.style.display = state.currentOffset === 0 ? 'none' : '';
}

function formatThermalOffset(offset) {
  const value = Number(offset);
  if (!Number.isFinite(value) || value === 0) return '出厂口径';
  return `${value > 0 ? '+' : ''}${value}°C 已启用`;
}

function isThermalZoneValid(zone) {
  if (!zone || typeof zone.zone !== 'string') return false;
  const temp = Number(zone.temp);
  return Number.isFinite(temp) && temp >= 10000 && temp <= 85000;
}

async function readThermalZones({ fresh = false, clear = false } = {}) {
  const path = clear ? API.thermalClear : fresh ? API.thermalFresh : API.thermal;
  const options = { timeoutMs: fresh || clear ? 8000 : 3500 };
  if (clear) {
    options.method = 'POST';
    options.headers = { 'Content-Type': 'application/json' };
    options.body = JSON.stringify({ action: 'clear' });
  }
  const zones = await apiFetch(path, options);
  if (!Array.isArray(zones) || !zones.length) throw new Error('未读取到热区数据');
  const valid = zones.filter(isThermalZoneValid);
  const skin = valid.find((zone) => zone.zone === 'VIRTUAL-SKIN') || valid.find((zone) => zone.zone === 'SKIN');
  if (!skin) throw new Error('VIRTUAL-SKIN 未找到');
  const tempC = skin.temp / 1000;
  if (state.lastSkinTempC !== null && Math.abs(tempC - state.lastSkinTempC) >= 12 && !fresh && !clear) {
    throw new Error('缓存温度跳变，准备校准');
  }
  return valid;
}

function syncHeroDesc() {
  const parts = [];
  const preset = THERMAL_PRESETS[state.currentOffset];
  const scheduler = requireFeature('profile').getThermalContext();
  const swapMode = requireFeature('memory').getSwapMode();
  if (preset) parts.push(preset.name);
  if (scheduler.schedEffectiveOwner === 'external') parts.push(scheduler.hasExternalScheduler ? (scheduler.externalSchedulerActive ? '外部调度接管' : '外部调度未启用') : '调度停用');
  else if (scheduler.hasExternalScheduler) parts.push('覆盖外部调度');
  if (swapMode === 'optimized') parts.push('内存已优化');
  else if (swapMode === 'stock') parts.push('内存默认');
  refs.heroDesc.textContent = parts.join(' · ') || '正在读取配置…';
}

function syncThermalUi() {
  const preset = THERMAL_PRESETS[state.currentOffset];
  if (!preset) return;
  refs.topbarThermalChip.textContent = `温控 ${preset.name}`;
  refs.thermalCurrentName.textContent = preset.name;
  refs.thermalCurrentDesc.textContent = preset.summary;
  const label = formatThermalOffset(state.currentOffset);
  [refs.homeModBadge, refs.thModBadge].forEach((el) => {
    el.textContent = label;
    el.className = `badge ${state.currentOffset === 0 ? 'off' : 'default'}`;
  });
  document.querySelectorAll('.thermal-option').forEach((card) => {
    card.classList.toggle('selected', Number(card.dataset.offset) === state.currentOffset);
  });
  positionMarkers();
}

function renderThermalCards() {
  refs.thermalList.replaceChildren();
  if (!state.contract) return;
  state.contract.offsets.forEach((offset) => {
    const preset = THERMAL_PRESETS[offset];
    const card = document.createElement('article');
    card.className = 'profile-card thermal-option';
    card.dataset.offset = String(offset);
    card.tabIndex = 0;
    setStaticHtml(card, `
      <div class="profile-icon" aria-hidden="true">${preset.icon}</div>
      <div class="profile-copy">
        <div class="profile-name">${preset.name}</div>
        <div class="profile-desc">${preset.summary}</div>
      </div>
      <div class="profile-actions">
        <button class="card-info" type="button" data-action="thermal-detail" data-offset="${offset}" aria-label="查看${preset.name}详情">
          <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor"><path d="M11 17h2v-6h-2v6zm0-8h2V7h-2v2zm1-7C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2z"/></svg>
        </button>
        <div class="p-check" aria-hidden="true"><svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg></div>
      </div>`);
    card.addEventListener('click', (evt) => {
      if (evt.target.closest('[data-action="thermal-detail"]')) return;
      applyThermal(offset);
    });
    card.addEventListener('keydown', (evt) => {
      if (evt.key === 'Enter' || evt.key === ' ') {
        evt.preventDefault();
        applyThermal(offset);
      }
    });
    refs.thermalList.appendChild(card);
  });
}

function applyThermalContract(data) {
  const raw = data?.thermal_contract;
  const offsets = Array.isArray(raw?.offsets) ? raw.offsets.map(Number) : [];
  const defaultOffset = Number(raw?.default_offset);
  const uniqueOffsets = new Set(offsets);
  const valid = offsets.length > 0
    && uniqueOffsets.size === offsets.length
    && offsets.every((offset) => Number.isFinite(offset) && THERMAL_PRESETS[offset])
    && uniqueOffsets.has(defaultOffset);
  if (!valid) throw new Error('温控档位 contract 无效');
  state.contract = { offsets, defaultOffset };
}

function ensureSensorRefs(container, key, zones, className) {
  const signature = zones.map((zone) => zone.zone).join(',');
  if (state[key] && state[key].map((entry) => entry.zone).join(',') === signature) return state[key];
  container.replaceChildren();
  state[key] = zones.map((zone) => {
    const node = document.createElement('div');
    node.className = className;
    let label;
    let value;
    if (className === 'sensor-chip') {
      label = document.createElement('span');
      label.className = 'sensor-chip-label';
      value = document.createElement('span');
      value.className = 'sensor-chip-value';
    } else {
      label = document.createElement('span');
      value = document.createElement('span');
    }
    label.textContent = ZONE_LABELS[zone.zone] || zone.zone;
    node.append(label, value);
    container.appendChild(node);
    return { zone: zone.zone, value };
  });
  return state[key];
}

async function loadThermalPreset() {
  try {
    const data = await apiFetch(API.thermalSet);
    applyThermalContract(data);
    state.currentOffset = state.contract.offsets.includes(Number(data.offset))
      ? Number(data.offset)
      : state.contract.defaultOffset;
    renderThermalCards();
  } catch (_) {
    state.contract = null;
    state.currentOffset = null;
    refs.thermalList.replaceChildren();
  }
  syncThermalUi();
  syncHeroDesc();
}

async function refreshThermal() {
  if (state.thermalBusy) return;
  state.thermalBusy = true;
  try {
    let zones;
    try {
      zones = await readThermalZones();
    } catch (_) {
      state.thermalBadReads += 1;
      zones = await readThermalZones({ fresh: true });
    }
    if (state.thermalBadReads >= 2) {
      try { zones = await readThermalZones({ clear: true }); } catch (_) {}
    }
    const skin = zones.find((zone) => zone.zone === 'VIRTUAL-SKIN') || zones.find((zone) => zone.zone === 'SKIN');
    const secondary = zones.filter((zone) => zone !== skin && ['soc_therm', 'battery', 'charging_therm', 'btmspkr_therm'].includes(zone.zone));
    refs.homeThermalSkel.hidden = true;
    refs.homeThermalContent.hidden = false;
    refs.thermalSkel.hidden = true;
    refs.thermalContent.hidden = false;
    if (skin) {
      const tempC = skin.temp / 1000;
      state.lastSkinTempC = tempC;
      state.thermalBadReads = 0;
      const color = tempHex(tempC);
      refs.homeTempNum.textContent = tempC.toFixed(1);
      refs.homeTempNum.style.color = color;
      refs.homeTempStatus.textContent = tempStatus(tempC);
      refs.homeTempStatus.style.color = color;
      refs.tempNum.textContent = tempC.toFixed(1);
      refs.tempNum.style.color = color;
      refs.tempZone.textContent = ZONE_LABELS[skin.zone] || skin.zone;
      refs.tempStatus.textContent = tempStatus(tempC);
      refs.tempStatus.style.color = color;
      refs.tempFill.style.width = `${barPct(tempC)}%`;
      refs.tempFill.style.background = `linear-gradient(90deg,${color}88,${color})`;
    } else {
      refs.homeTempNum.textContent = '--';
      refs.homeTempStatus.textContent = 'VIRTUAL-SKIN 未找到';
      refs.tempNum.textContent = '--';
      refs.tempZone.textContent = 'VIRTUAL-SKIN';
      refs.tempStatus.textContent = '未找到热区，请确认已注册';
    }
    const homeRefs = ensureSensorRefs(refs.homeSensorList, 'homeSensorRefs', secondary, 'sensor-row');
    const gridRefs = ensureSensorRefs(refs.sensorGrid, 'sensorRefs', secondary, 'sensor-chip');
    secondary.forEach((zone, index) => {
      const tempC = zone.temp / 1000;
      const color = tempHex(tempC);
      homeRefs[index].value.textContent = `${tempC.toFixed(1)}°C`;
      homeRefs[index].value.style.color = color;
      gridRefs[index].value.textContent = `${tempC.toFixed(1)}°C`;
      gridRefs[index].value.style.color = color;
    });
  } catch (err) {
    refs.homeThermalSkel.hidden = true;
    refs.homeThermalContent.hidden = false;
    refs.thermalSkel.hidden = true;
    refs.thermalContent.hidden = false;
    refs.homeTempNum.textContent = '--';
    refs.homeTempStatus.textContent = err.message;
    refs.tempNum.textContent = '--';
    refs.tempStatus.textContent = err.message;
  } finally {
    state.thermalBusy = false;
  }
}

function getTempGapThresholdSec(data) {
  const deltas = [];
  for (let i = 1; i < data.length; i++) {
    const delta = data[i].ts - data[i - 1].ts;
    if (delta > 0) deltas.push(delta);
  }
  const sortedDeltas = deltas.sort((a, b) => a - b);
  const medianDelta = sortedDeltas.length ? sortedDeltas[Math.floor(sortedDeltas.length / 2)] : 15;
  return Math.max(90, medianDelta * 4);
}

function drawTempCanvas(canvas, data, options = {}) {
  if (!canvas || !data || data.length < 2) return null;
  const dpr = Math.min(Math.max(window.devicePixelRatio || 1, 1), 2);
  const w = Math.max(1, Math.round(canvas.getBoundingClientRect().width || canvas.offsetWidth || 380));
  const h = 200;
  const pixelWidth = Math.max(1, Math.round(w * dpr));
  const pixelHeight = Math.max(1, Math.round(h * dpr));
  if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) {
    canvas.width = pixelWidth;
    canvas.height = pixelHeight;
  }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  const pad = { top: 12, right: 8, bottom: 26, left: 38 };
  const plotW = w - pad.left - pad.right;
  const plotH = h - pad.top - pad.bottom;
  const temps = data.map((p) => p.temp);
  const realMin = Math.min(...temps);
  const realMax = Math.max(...temps);
  const avg = temps.reduce((a, b) => a + b, 0) / temps.length;
  let minT = realMin;
  let maxT = realMax;
  if (maxT - minT < 2) { minT -= 1; maxT += 1; } else { minT = Math.floor(minT); maxT = Math.ceil(maxT); }
  const isDark = document.documentElement.dataset.theme === 'dark';
  const gridColor = isDark ? 'rgba(224,227,225,0.10)' : 'rgba(23,29,27,0.10)';
  const labelColor = isDark ? 'rgba(224,227,225,0.55)' : 'rgba(23,29,27,0.52)';
  const strokeColor = isDark ? '#84dcc5' : '#006b57';
  const areaColor = isDark ? 'rgba(132,220,197,0.08)' : 'rgba(0,107,87,0.06)';
  const gridN = 4;
  ctx.strokeStyle = gridColor;
  ctx.lineWidth = 1;
  ctx.font = '11px system-ui,sans-serif';
  ctx.fillStyle = labelColor;
  ctx.textAlign = 'right';
  ctx.textBaseline = 'middle';
  for (let i = 0; i <= gridN; i++) {
    const y = pad.top + (plotH / gridN) * i;
    const t = maxT - ((maxT - minT) / gridN) * i;
    ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(w - pad.right, y); ctx.stroke();
    ctx.fillText(`${t.toFixed(0)}°`, pad.left - 4, y);
  }
  ctx.textBaseline = 'top';
  const xN = 4;
  const t0 = data[0].ts;
  const t1 = data[data.length - 1].ts;
  const timeSpan = t1 - t0 || 1;
  for (let i = 0; i <= xN; i++) {
    const x = pad.left + (plotW / xN) * i;
    const ts = t0 + (timeSpan / xN) * i;
    const d = new Date(ts * 1000);
    ctx.textAlign = i === 0 ? 'left' : i === xN ? 'right' : 'center';
    ctx.fillText(`${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`, x, h - pad.bottom + 6);
  }
  const gapThresholdSec = options.gapThresholdSec || getTempGapThresholdSec(data);
  const segments = [];
  const gaps = [];
  let segment = [data[0]];
  for (let i = 1; i < data.length; i++) {
    const previous = data[i - 1];
    const current = data[i];
    if ((current.ts - previous.ts) > gapThresholdSec) {
      segments.push(segment);
      gaps.push([previous, current]);
      segment = [current];
    } else {
      segment.push(current);
    }
  }
  if (segment.length) segments.push(segment);
  const sampleStep = Math.max(1, Math.ceil(data.length / Math.max(1, plotW)));
  const plotSegments = segments.map((points) => {
    if (sampleStep === 1 || points.length <= 2) return points;
    const sampled = points.filter((_, index) => index % sampleStep === 0);
    const last = points[points.length - 1];
    if (sampled[sampled.length - 1] !== last) sampled.push(last);
    return sampled;
  });

  const pointXY = (point) => ({
    x: pad.left + ((point.ts - t0) / timeSpan) * plotW,
    y: pad.top + ((maxT - point.temp) / (maxT - minT)) * plotH
  });
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  plotSegments.forEach((points) => {
    if (!points.length) return;
    const first = pointXY(points[0]);
    const last = pointXY(points[points.length - 1]);
    ctx.beginPath();
    ctx.moveTo(first.x, pad.top + plotH);
    ctx.lineTo(first.x, first.y);
    points.slice(1).forEach((point) => {
      const pos = pointXY(point);
      ctx.lineTo(pos.x, pos.y);
    });
    ctx.lineTo(last.x, pad.top + plotH);
    ctx.closePath();
    ctx.fillStyle = areaColor;
    ctx.fill();

    ctx.beginPath();
    points.forEach((point, index) => {
      const pos = pointXY(point);
      if (index === 0) ctx.moveTo(pos.x, pos.y);
      else ctx.lineTo(pos.x, pos.y);
    });
    ctx.strokeStyle = strokeColor;
    ctx.lineWidth = 2;
    ctx.stroke();
  });
  if (gaps.length) {
    ctx.save();
    ctx.setLineDash([6, 5]);
    ctx.strokeStyle = labelColor;
    ctx.lineWidth = 1.5;
    gaps.forEach(([from, to]) => {
      const start = pointXY(from);
      const end = pointXY(to);
      ctx.beginPath();
      ctx.moveTo(start.x, start.y);
      ctx.lineTo(end.x, end.y);
      ctx.stroke();
    });
    ctx.restore();
  }
  return { min: realMin, max: realMax, avg, count: data.length, gapCount: gaps.length, gapThresholdSec };
}

async function fetchTempHistory(minutes) {
  try {
    const data = await apiFetch(`${API.thermal}?history=1&minutes=${minutes}`, { timeoutMs: 6000 });
    if (!data || !data.points) return [];
    return data.points.map((p) => ({ ts: p[0], temp: p[1] / 1000 }));
  } catch (_) {
    return [];
  }
}

async function triggerThermalBurst(options = {}) {
  const auth = requireFeature('auth');
  if (!auth.hasToken()) {
    if (!options.prompt) return false;
    if (!(await auth.ensureToken())) return false;
  }
  try {
    await apiFetch(API.thermalBurst, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'start', duration_sec: 300 }),
      timeoutMs: 4000
    });
    return true;
  } catch (_) {
    return false;
  }
}

function openTempChart() {
  stopTempChartRefresh();
  stopEnergyDetailRefresh();
  triggerThermalBurst({ prompt: false });
  refs.detailTitle.textContent = '温度历史';
  const ranges = [
    { min: 10, label: '10 分' },
    { min: 30, label: '30 分' },
    { min: 150, label: '2.5 小时' },
    { min: 720, label: '12 小时' },
  ];
  let active = 10;
  state.tempChart.activeRange = active;
  refs.detailModal.classList.remove('energy-mode');
  refs.detailModal.classList.add('history-mode');
  const root = document.createElement('div');
  root.className = 'history-overview';
  const intro = document.createElement('div');
  intro.className = 'section-intro';
  setStaticHtml(intro, '<div class="section-title">温度趋势</div><div class="section-sub">查看机身温度变化、峰值与阈值持续时间。</div>');
  const tabsEl = document.createElement('div');
  tabsEl.className = 'range-tabs history-range-tabs';
  const areaEl = document.createElement('div');
  areaEl.className = 'history-content';
  root.append(intro, tabsEl, areaEl);
  refs.detailBody.replaceChildren(root);
  let view = null;
  const createView = () => {
    areaEl.replaceChildren();
    const hero = document.createElement('section');
    hero.className = 'history-hero';
    const heroHead = document.createElement('div');
    heroHead.className = 'history-hero-head';
    const heroCopy = document.createElement('div');
    heroCopy.className = 'history-hero-copy';
    const currentLabel = document.createElement('div');
    currentLabel.className = 'history-hero-kicker';
    currentLabel.textContent = '当前温度';
    const currentValue = document.createElement('div');
    currentValue.className = 'history-hero-value';
    const currentStatus = document.createElement('div');
    currentStatus.className = 'history-hero-status';
    heroCopy.append(currentLabel, currentValue, currentStatus);
    const heroBadge = document.createElement('span');
    heroBadge.className = 'history-hero-badge';
    heroHead.append(heroCopy, heroBadge);
    const summaryGrid = document.createElement('div');
    summaryGrid.className = 'history-summary-grid';
    const summaryValues = [];
    ['最低', '平均', '最高'].forEach((label) => {
      const item = document.createElement('div');
      item.className = 'history-summary-item';
      const labelEl = document.createElement('span');
      labelEl.textContent = label;
      const valueEl = document.createElement('strong');
      item.append(labelEl, valueEl);
      summaryGrid.appendChild(item);
      summaryValues.push(valueEl);
    });
    hero.append(heroHead, summaryGrid);

    const chartCard = document.createElement('section');
    chartCard.className = 'history-chart-card';
    const chartWrap = document.createElement('div');
    chartWrap.className = 'chart-wrap';
    const canvas = document.createElement('canvas');
    canvas.style.cssText = 'display:block;width:100%;height:200px';
    canvas.setAttribute('role', 'img');
    canvas.setAttribute('aria-label', '机身温度趋势图');
    chartWrap.appendChild(canvas);
    const gapNote = document.createElement('div');
    gapNote.className = 'history-gap-note';
    gapNote.hidden = true;
    chartCard.append(chartWrap, gapNote);

    const details = document.createElement('details');
    details.className = 'disclosure';
    const detailsSummary = document.createElement('summary');
    detailsSummary.className = 'disclosure-summary';
    const detailsCopy = document.createElement('span');
    detailsCopy.className = 'disclosure-copy';
    const detailsTitle = document.createElement('strong');
    detailsTitle.textContent = '更多统计';
    const detailsMeta = document.createElement('small');
    detailsCopy.append(detailsTitle, detailsMeta);
    const chevron = document.createElement('span');
    chevron.className = 'disclosure-chevron';
    chevron.setAttribute('aria-hidden', 'true');
    chevron.textContent = '›';
    detailsSummary.append(detailsCopy, chevron);
    const detailsBody = document.createElement('div');
    detailsBody.className = 'disclosure-body';
    const statsList = document.createElement('div');
    statsList.className = 'data-list';
    const rangeRow = buildInfoRow('数据范围', '—');
    const samplesRow = buildInfoRow('采样点', '—');
    const thresholdRow = buildInfoRow('达到阈值', '—');
    statsList.append(rangeRow, samplesRow, thresholdRow);
    detailsBody.appendChild(statsList);
    details.append(detailsSummary, detailsBody);
    areaEl.append(hero, chartCard, details);
    return {
      hero,
      currentValue,
      currentStatus,
      heroBadge,
      summaryValues,
      canvas,
      gapNote,
      detailsMeta,
      rangeValue: rangeRow.querySelector('.data-val'),
      samplesValue: samplesRow.querySelector('.data-val'),
      thresholdKey: thresholdRow.querySelector('.data-key'),
      thresholdValue: thresholdRow.querySelector('.data-val')
    };
  };
  const draw = async (rangeMin, options = {}) => {
    const requestId = ++state.tempChart.requestId;
    active = rangeMin;
    state.tempChart.activeRange = rangeMin;
    const rangeLabel = ranges.find((r) => r.min === rangeMin)?.label || `${rangeMin} 分钟`;
    tabsEl.querySelectorAll('.range-btn').forEach((button) => button.classList.toggle('active', Number(button.dataset.range) === rangeMin));
    if (!options.silent && !view) setStaticHtml(areaEl, '<div class="energy-empty">正在读取温度记录…</div>');
    const data = await fetchTempHistory(rangeMin);
    if (requestId !== state.tempChart.requestId || state.tempChart.draw !== draw) return;
    if (!data || data.length < 2) {
      setStaticHtml(areaEl, '<div class="energy-empty">温度记录不足。保持页面运行一段时间后再查看。</div>');
      view = null;
      return;
    }
    const temps = data.map((p) => p.temp);
    const realMin = Math.min(...temps);
    const realMax = Math.max(...temps);
    const avg = temps.reduce((a, b) => a + b, 0) / temps.length;
    const current = data[data.length - 1].temp;
    const threshold = THRESH_STOCK + state.currentOffset;
    const gapThresholdSec = getTempGapThresholdSec(data);
    let highSec = 0;
    for (let i = 1; i < data.length; i++) {
      const delta = data[i].ts - data[i - 1].ts;
      if (delta <= gapThresholdSec && data[i - 1].temp >= threshold) highSec += delta;
    }
    const elapsed = data[data.length - 1].ts - data[0].ts;
    if (!view) view = createView();
    const tone = current >= threshold ? 'warn' : '';
    view.hero.className = `history-hero${tone ? ` ${tone}` : ''}`;
    view.currentValue.textContent = `${current.toFixed(1)}°C`;
    view.currentStatus.textContent = current >= threshold
      ? `已达到 ${threshold}°C 温控阈值`
      : `距离 ${threshold}°C 温控阈值 ${(threshold - current).toFixed(1)}°C`;
    view.heroBadge.textContent = rangeLabel;
    view.summaryValues[0].textContent = `${realMin.toFixed(1)}°C`;
    view.summaryValues[1].textContent = `${avg.toFixed(1)}°C`;
    view.summaryValues[2].textContent = `${realMax.toFixed(1)}°C`;
    const chartResult = drawTempCanvas(view.canvas, data, { gapThresholdSec });
    const gapCount = chartResult?.gapCount || 0;
    view.gapNote.hidden = gapCount === 0;
    view.gapNote.textContent = gapCount > 0 ? `虚线表示 ${gapCount} 段无连续采样区间` : '';
    view.detailsMeta.textContent = `${data.length} 个采样点 · 覆盖 ${fmtDuration(elapsed)}`;
    view.rangeValue.textContent = fmtDuration(elapsed);
    view.samplesValue.textContent = `${data.length} 个`;
    view.thresholdKey.textContent = `达到阈值（≥${threshold}°C）`;
    view.thresholdValue.className = `badge ${highSec > 60 ? 'warn' : 'good'}`;
    view.thresholdValue.textContent = fmtDuration(highSec);
  };
  ranges.forEach((r) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = `range-btn${r.min === active ? ' active' : ''}`;
    btn.dataset.range = String(r.min);
    btn.textContent = r.label;
    btn.addEventListener('click', () => {
      draw(r.min).catch(() => {}).then(() => scheduleTempChartRefresh());
    });
    tabsEl.appendChild(btn);
  });
  refs.detailModal.classList.add('open');
  pushModalState('detail');
  state.tempChart.draw = draw;
  window.setTimeout(() => {
    if (!refs.detailModal.classList.contains('open') || state.tempChart.draw !== draw) return;
    draw(active).catch(() => {}).then(() => scheduleTempChartRefresh());
  }, 80);
}

async function exportHistoryWindow(scope, button) {
  const oldText = button ? button.textContent : '';
  if (button) {
    button.disabled = true;
    button.textContent = '保存中...';
  }
  try {
    const body = scope === 'session'
      ? { action: 'export', mode: 'session', start_ts: WEBUI_SESSION_START_TS }
      : { action: 'export', minutes: scope };
    const data = await apiFetch(API.historyExport, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      timeoutMs: 10000
    });
    if (data && data.ok) {
      showToast(`已保存到 ${data.path}`, 4200);
      appendLog(`历史数据已保存: ${data.path}`, 'ok');
    } else {
      showToast(`保存失败：${data?.error || '未知错误'}`);
    }
  } catch (err) {
    if (!/missing WebUI token/i.test(String(err?.message || ''))) {
      showToast(`保存失败：${err.message || err}`);
    }
  } finally {
    if (button) {
      button.disabled = false;
      button.textContent = oldText;
    }
  }
}

function stopThermalBurst() {
  if (!requireFeature('auth').hasToken()) return;
  apiFetch(API.thermalBurst, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: 'stop' }),
    timeoutMs: 2500,
    keepalive: true
  }).catch(() => {});
}

async function applyThermal(offset) {
  if (!state.contract?.offsets.includes(offset) || offset === state.currentOffset || state.thermalApplyBusy) return;
  const prev = state.currentOffset;
  const card = refs.thermalList.querySelector(`[data-offset="${offset}"]`);
  if (!card) return;
  state.thermalApplyBusy = true;
  card.classList.add('loading');
  appendLog(`切换温控阈值 ${THERMAL_PRESETS[offset].name}…`, 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.thermalSet, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ offset }), timeoutMs: 8000 });
    if (data.ok) {
      state.currentOffset = offset;
      syncThermalUi();
      syncHeroDesc();
      if (data.restarted) {
        showToast(`${THERMAL_PRESETS[offset].name} · thermal 服务已重启`);
        appendLog(`${THERMAL_PRESETS[offset].name} 已重启 thermal 服务`, 'ok');
      } else {
        appendLog(`${THERMAL_PRESETS[offset].name} 已保存（重启后生效）`, 'warn');
        openRebootModal(offset, prev);
      }
    } else {
      showToast(`切换失败：${data.error || '未知'}`);
      appendLog(data.error || '切换失败', 'err');
    }
  } catch (err) {
    showToast('请求失败，检查服务是否运行');
    appendLog(String(err), 'err');
  } finally {
    card.classList.remove('loading');
    state.thermalApplyBusy = false;
  }
}

async function cancelThermalChange() {
  refs.rebootModal.classList.remove('open');
  try {
    await apiFetch(API.thermalSet, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ offset: state.thermalModal.prev }), timeoutMs: 8000 });
    state.currentOffset = state.thermalModal.prev;
    syncThermalUi();
    syncHeroDesc();
    showToast('已撤销，恢复原档位');
  } catch (_) {
    showToast('撤销失败，请手动重新选择');
  }
}

async function rebootDevice() {
  refs.rebootModal.classList.remove('open');
  showToast('正在重启设备…');
  try {
    await apiFetch(API.reboot, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'reboot', confirm: true }),
      timeoutMs: 8000
    });
  } catch (_) {}
}

async function cancelPendingRebootChange() {
  if (requireFeature('ui').getRebootContext() === 'scheduler') {
    await requireFeature('profile').cancelSchedulerChange();
  } else {
    await cancelThermalChange();
  }
}

function stopTempChartRefresh() {
  const wasActive = Boolean(state.tempChart.draw);
  if (state.tempChart.timer) {
    clearTimeout(state.tempChart.timer);
    state.tempChart.timer = null;
  }
  state.tempChart.draw = null;
  state.tempChart.requestId += 1;
  if (wasActive) stopThermalBurst();
}

function pauseTempChartRefresh() {
  const wasActive = Boolean(state.tempChart.draw);
  if (state.tempChart.timer) {
    clearTimeout(state.tempChart.timer);
    state.tempChart.timer = null;
  }
  state.tempChart.requestId += 1;
  if (wasActive) stopThermalBurst();
}

function scheduleTempChartRefresh(delay = TEMP_CHART_REFRESH_MS) {
  if (state.tempChart.timer) clearTimeout(state.tempChart.timer);
  if (!core().isWebUiActive() || !refs.detailModal.classList.contains('open') || !state.tempChart.draw) return;
  state.tempChart.timer = window.setTimeout(async () => {
    state.tempChart.timer = null;
    if (!core().isWebUiActive() || !refs.detailModal.classList.contains('open') || !state.tempChart.draw) return;
    try {
      await state.tempChart.draw(state.tempChart.activeRange, { silent: true });
    } catch (_) {}
    scheduleTempChartRefresh();
  }, delay);
}

registerFeature('thermal', {
  initialize() { refs.thermalList.replaceChildren(); },
  load: loadThermalPreset,
  refresh: refreshThermal,
  pause: pauseTempChartRefresh,
  positionMarkers,
  isRefreshing: () => state.thermalBusy,
  syncHeroDesc,
  openChart: openTempChart,
  triggerBurst: triggerThermalBurst,
  rebootDevice,
  cancelPendingRebootChange,
  exportHistoryWindow,
  setPendingChange(pending, prev) {
    state.thermalModal.pending = pending;
    state.thermalModal.prev = prev;
  },
  isChartActive: () => Boolean(state.tempChart.draw),
  stopChart: stopTempChartRefresh,
  pauseChart: pauseTempChartRefresh,
  scheduleChart: scheduleTempChartRefresh
});
})();

