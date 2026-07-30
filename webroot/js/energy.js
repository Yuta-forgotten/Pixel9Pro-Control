// 功耗统计、分段详情与定时刷新功能。
'use strict';
function fmtDuration(sec) {
  const value = Number(sec);
  if (!Number.isFinite(value) || value < 0) return '—';
  if (value >= 3600) return `${Math.floor(value / 3600)}小时${Math.floor((value % 3600) / 60)}分`;
  if (value >= 60) return `${Math.floor(value / 60)}分${Math.floor(value % 60)}秒`;
  return `${Math.floor(value)}秒`;
}

function fmtDateTime(ts, withSeconds = false) {
  const value = Number(ts);
  if (!Number.isFinite(value) || value <= 0) return '—';
  const options = {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  };
  if (withSeconds) options.second = '2-digit';
  return new Intl.DateTimeFormat('zh-CN', options).format(new Date(value * 1000)).replace(/\//g, '-');
}

function fmtMah(value) {
  const num = Number(value);
  return Number.isFinite(num) ? `${num.toFixed(1)} mAh` : '—';
}

function fmtMahPerHour(value) {
  const num = Number(value);
  return Number.isFinite(num) ? `${num.toFixed(1)} mAh/h` : '—';
}

function fmtMilliwatt(value) {
  const num = Number(value);
  return Number.isFinite(num) ? `${num.toFixed(0)} mW` : '—';
}

function fmtTempC(value) {
  const num = Number(value);
  return Number.isFinite(num) ? `${num.toFixed(1)}°C` : '—';
}

function fmtSignedPercent(value) {
  const num = Number(value);
  if (!Number.isFinite(num)) return '—';
  return `${num > 0 ? '+' : ''}${num}%`;
}

function fmtPowerSource(source, externalPower = false) {
  switch (source) {
    case 'usb': return 'USB 接电';
    case 'wireless': return '无线接电';
    case 'dc': return 'DC 接电';
    case 'mains':
    case 'ac': return 'AC 接电';
    case 'battery': return '未接电';
    default: return externalPower ? `${source || '外接电源'} 在线` : '未接电';
  }
}

function fmtBatteryStatus(status, charge = {}) {
  const externalPower = charge.external_power_online === true;
  const sourceLabel = fmtPowerSource(charge.power_source, externalPower);
  switch (status) {
    case 'Charging': return '充电中';
    case 'Discharging': return '放电中';
    case 'Full': return '已充满';
    case 'Not charging': return externalPower ? `${sourceLabel}未充电` : '未充电';
    default: return status || '未知';
  }
}

function fmtSessionResetReason(reason) {
  switch (reason) {
    case 'charged_10m': return '连续充电 10 分钟后重新拔线';
    case 'full_replug': return '充满后重新拔线';
    case 'boot_init': return '模块首次初始化';
    default: return reason || '—';
  }
}

function fmtBatterystatsWindow(label) {
  if (!label) return '—';
  if (/Statistics since last charge/i.test(label)) return '自上次充满以来';
  if (/Daily stats/i.test(label)) return 'Daily stats';
  return label;
}

async function fetchEnergyDetailWithRetry() {
  let lastErr = new Error('功耗数据暂不可用');
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const result = await fetchEnergySystemDetail();
      if (result) return result;
      lastErr = new Error('功耗数据请求繁忙');
    } catch (err) {
      lastErr = err;
      const msg = String(err?.message || err || '');
      if (attempt === 0 && (/Failed to fetch/i.test(msg) || /request timeout/i.test(msg) || /HTTP 5\d\d/.test(msg))) {
        await sleep(450);
        continue;
      }
      break;
    }
  }
  try {
    const result = await fetchEnergyFastDetail();
    if (result) return result;
    lastErr = new Error('功耗数据请求繁忙');
  } catch (err) {
    lastErr = err;
  }
  throw lastErr;
}

async function fetchEnergyRequest(kind, path, timeoutMs) {
  if (state.energy.detail.requestKind) return null;
  const controller = new AbortController();
  state.energy.detail.requestKind = kind;
  state.energy.detail.requestController = controller;
  try {
    return await apiFetch(path, { timeoutMs, controller });
  } finally {
    if (state.energy.detail.requestController === controller) {
      state.energy.detail.requestController = null;
      state.energy.detail.requestKind = '';
    }
  }
}

async function fetchEnergyFastDetail() {
  return await fetchEnergyRequest('fast', API.energyFast, 3500);
}

async function fetchEnergySystemDetail() {
  return await fetchEnergyRequest('full', API.energy, 16000);
}

function isFullEnergyDetailData(d) {
  if (!d || d.fast === true) return false;
  const bs = d.batterystats_window || {};
  return Number.isFinite(Number(d.system_generated_at))
    || (bs && bs.model_quality && bs.model_quality !== 'fast_no_batterystats')
    || Number(d.cap) > 0
    || Number(d.drain) > 0
    || (Array.isArray(d.apps) && d.apps.length > 0);
}

function mergeEnergyDetailData(liveData, fullData) {
  const live = liveData || {};
  const full = fullData || {};
  const system = Object.keys(full).length ? full : (isFullEnergyDetailData(live) ? live : {});
  const merged = { ...full, ...live };
  ['cap', 'drain', 'scroff', 'scron', 'bat_time', 'screen', 'cpu', 'cell', 'wifi', 'wakelock'].forEach((key) => {
    if (Object.prototype.hasOwnProperty.call(system, key)) merged[key] = system[key];
  });
  ['system_generated_at', 'system_cache_age_sec', 'system_cache_stale', 'cache_ttl_sec'].forEach((key) => {
    if (Object.prototype.hasOwnProperty.call(system, key)) merged[key] = system[key];
  });
  if (Array.isArray(system.apps)) merged.apps = system.apps;
  else if (!Array.isArray(merged.apps)) merged.apps = [];
  if (system.batterystats_window) merged.batterystats_window = system.batterystats_window;
  merged._using_fast_live = live.fast === true;
  merged._has_full_system = Object.keys(system).length > 0;
  merged._live_generated_at = live.live_generated_at || live.generated_at || merged.live_generated_at || merged.generated_at || null;
  merged._system_generated_at = system.system_generated_at || system.generated_at || null;
  return merged;
}

function getEnergySystemAgeSeconds(data, liveGeneratedAt, systemGeneratedAt) {
  const rawBackendAge = data?.system_cache_age_sec;
  const backendAge = rawBackendAge == null || rawBackendAge === '' ? NaN : Number(rawBackendAge);
  const liveTs = liveGeneratedAt == null || liveGeneratedAt === '' ? NaN : Number(liveGeneratedAt);
  const systemTs = systemGeneratedAt == null || systemGeneratedAt === '' ? NaN : Number(systemGeneratedAt);
  const derivedAge = Number.isFinite(liveTs) && Number.isFinite(systemTs) && liveTs >= systemTs
    ? liveTs - systemTs
    : NaN;
  const candidates = [backendAge, derivedAge].filter((value) => Number.isFinite(value) && value >= 0);
  return candidates.length ? Math.max(...candidates) : null;
}

function getEnergySystemRefreshDelay(data = state.energy.detail.fullData) {
  const ttlSec = Number(data?.cache_ttl_sec);
  if (!Number.isFinite(ttlSec) || ttlSec <= 0) return ENERGY_SYSTEM_REFRESH_FALLBACK_MS;
  const rawAge = data?.system_cache_age_sec;
  const ageSec = rawAge == null || rawAge === '' ? 0 : Math.max(0, Number(rawAge) || 0);
  const remainingSec = Math.max(0, ttlSec - ageSec);
  return Math.max(ENERGY_DETAIL_REFRESH_MS * 2, Math.round(remainingSec * 1000) + ENERGY_SYSTEM_REFRESH_MARGIN_MS);
}

function getEnergyRenderSignature(data) {
  const ignored = new Set([
    'generated_at', 'live_generated_at', '_live_generated_at',
    'system_cache_age_sec'
  ]);
  return `${state.energy.detail.activeWindowMinutes}|${JSON.stringify(data, (key, value) => (
    ignored.has(key) ? undefined : value
  ))}`;
}

function reconcileStableDom(current, next) {
  if (!current || !next) return;
  if (current.nodeType !== next.nodeType || current.nodeName !== next.nodeName) {
    current.replaceWith(next);
    return;
  }
  if (current.nodeType === Node.TEXT_NODE) {
    if (current.nodeValue !== next.nodeValue) current.nodeValue = next.nodeValue;
    return;
  }
  const currentAttrs = Array.from(current.attributes || []);
  const nextAttrs = Array.from(next.attributes || []);
  currentAttrs.forEach((attr) => {
    if (!next.hasAttribute(attr.name)) current.removeAttribute(attr.name);
  });
  nextAttrs.forEach((attr) => {
    if (current.getAttribute(attr.name) !== attr.value) current.setAttribute(attr.name, attr.value);
  });
  if (current instanceof HTMLDetailsElement && next instanceof HTMLDetailsElement) current.open = next.open;
  if (current instanceof HTMLButtonElement && next instanceof HTMLButtonElement) current.disabled = next.disabled;

  const currentChildren = Array.from(current.childNodes);
  const nextChildren = Array.from(next.childNodes);
  const shared = Math.min(currentChildren.length, nextChildren.length);
  for (let i = 0; i < shared; i++) reconcileStableDom(currentChildren[i], nextChildren[i]);
  for (let i = currentChildren.length - 1; i >= nextChildren.length; i--) currentChildren[i].remove();
  for (let i = shared; i < nextChildren.length; i++) current.appendChild(nextChildren[i]);
}

function renderEnergyDetail(input, options = {}) {
  try {
    const d = mergeEnergyDetailData(input, options.fullData || state.energy.detail.fullData);
    const text = (v) => v == null || v === '' ? '—' : String(v);
    const el = (tag, className = '', content = '') => {
      const node = document.createElement(tag);
      if (className) node.className = className;
      if (content !== '') node.textContent = content;
      return node;
    };
    const row = (k, v, cls) => { const r = document.createElement('div'); r.className = 'data-row'; const sk = document.createElement('span'); sk.className = 'data-key'; sk.textContent = k; const sv = document.createElement('span'); sv.className = cls || 'data-val'; sv.textContent = v; r.appendChild(sk); r.appendChild(sv); return r; };
    const sectionHead = (title, desc = '') => {
      const head = el('div', 'energy-section-head');
      head.appendChild(el('div', 'energy-section-title', title));
      if (desc) head.appendChild(el('div', 'energy-section-desc', desc));
      return head;
    };
    const disclosure = (key, title, summary, body) => {
      const details = el('details', 'energy-disclosure');
      details.open = state.energy.detail.openSections[key] === true;
      const trigger = el('summary', 'energy-disclosure-summary');
      const copy = el('span', 'energy-disclosure-copy');
      copy.append(el('strong', '', title), el('small', '', summary));
      trigger.append(copy, el('span', 'energy-disclosure-chevron', '›'));
      details.append(trigger, body);
      details.addEventListener('toggle', () => {
        state.energy.detail.openSections[key] = details.open;
      });
      return details;
    };
    const scope = d.scope || {};
    const today = d.today || {};
    const charge = d.charge_state || {};
    const bs = d.batterystats_window || {};
    const qualityLabel = (q) => {
      switch (q) {
        case 'pure_discharge': return '纯放电';
        case 'charging_endpoint': return '接电中';
        case 'mixed_charge_discharge': return '混合充放电';
        case 'session_window_mismatch': return '统计窗口不一致';
        case 'insufficient_samples': return '采样不足';
        case 'partial_window': return '覆盖不足';
        case 'no_discharge_delta': return '暂无放电变化';
        case 'no_data': return '无数据';
        default: return '未知';
      }
    };
    const qualityTone = (q) => q === 'pure_discharge' ? 'good' : (q === 'no_data' || q === 'insufficient_samples' || q === 'no_discharge_delta' ? 'off' : 'warn');
    const qualityBadge = (q) => `badge ${qualityTone(q)}`;
    const comparable = scope.comparable_to_batterystats === true;
    const externalPower = charge.external_power_online === true;
    const chargeLike = charge.is_charging_like === true
      || charge.status === 'Charging'
      || charge.status === 'Full'
      || (charge.status === 'Not charging' && externalPower);
    const powerSourceLabel = fmtPowerSource(charge.power_source, externalPower);
    const chargeStatusLabel = fmtBatteryStatus(charge.status, charge);
    const radioUntrusted = /untrusted|high/i.test(String(bs.model_quality || ''));
    const modelQualityLabel = (q) => {
      switch (q) {
        case 'total_ok_radio_model_untrusted': return '总账可用，蜂窝估算不可信';
        case 'total_ok_radio_model_reference': return '总账可用，蜂窝估算仅供参考';
        case 'fast_no_batterystats': return '系统分项正在加载';
        case 'no_system_snapshot': return '系统统计不可用';
        default: return '未知';
      }
    };
    const odpm = d.odpm_modem || {};
    const odpmValue = odpm.total_mah != null
      ? `${text(odpm.total_mah)} mAh · 当前会话变化量`
      : '暂无有效变化量';
    const liveGeneratedAt = d._live_generated_at || d.generated_at;
    const systemGeneratedAt = d._system_generated_at || null;
    const liveRefreshLabel = fmtDateTime(liveGeneratedAt, true);
    const systemSnapshot = d._has_full_system ? fmtDateTime(systemGeneratedAt, true) : '系统统计尚未加载';
    const systemCacheAgeSec = getEnergySystemAgeSeconds(d, liveGeneratedAt, systemGeneratedAt);
    const systemCacheAge = systemCacheAgeSec == null ? '—' : `${Math.floor(systemCacheAgeSec)} 秒前`;
    const cacheTtlSec = Number(d.cache_ttl_sec);
    const systemCacheExpired = Number.isFinite(cacheTtlSec) && cacheTtlSec > 0
      && systemCacheAgeSec != null && systemCacheAgeSec > cacheTtlSec;
    const systemCacheWarn = !d._has_full_system || d.system_cache_stale === true || systemCacheExpired;
    const systemCacheState = !d._has_full_system
      ? '正在加载'
      : (d.system_cache_stale === true ? '使用较早数据' : (systemCacheExpired ? '正在更新' : '正常'));
    const windows = Array.isArray(d.history_windows) ? d.history_windows : [];
    const windowView = (win) => {
      if (!win) return null;
      const min = Number(win.minutes);
      const p = win.power || {};
      const t = win.thermal || {};
        const pSamples = Number(p.effective_samples ?? p.samples ?? 0);
        const tSamples = Number(t.samples || 0);
        const expectedSec = Number.isFinite(Number(p.expected_elapsed_sec))
          ? Number(p.expected_elapsed_sec)
          : min * 60;
        const coverageSec = Number.isFinite(Number(p.coverage_elapsed_sec))
          ? Number(p.coverage_elapsed_sec)
          : Number(p.elapsed_sec || 0);
        const rawCoverageRatio = Number(p.coverage_ratio);
        const coverageRatio = Number.isFinite(rawCoverageRatio)
          ? Math.max(0, Math.min(1, rawCoverageRatio))
          : (expectedSec > 0 ? Math.max(0, Math.min(1, coverageSec / expectedSec)) : 0);
        const coveragePercent = Math.round(coverageRatio * 100);
        const hasTrustedAverage = typeof p.trusted_for_average === 'boolean';
        const trustedAverage = hasTrustedAverage
          ? p.trusted_for_average
          : (p.quality === 'pure_discharge' && coverageRatio >= 0.8 && pSamples >= 2);
        let value = '';
        let detail = '';
        if (trustedAverage) {
          value = fmtMilliwatt(p.avg_discharge_mw);
          detail = `${fmtMahPerHour(p.avg_discharge_mah_per_h)} · 实际放电 ${fmtMah(p.discharge_mah)}`;
        } else if (p.quality === 'mixed_charge_discharge') {
          value = '混合收支';
          detail = `放电 ${fmtMah(p.discharge_mah)} · 回充 ${fmtMah(p.charge_mah)}`;
        } else if (p.quality === 'charging_endpoint') {
          value = '当前接电';
          detail = `放电 ${fmtMah(p.discharge_mah)} · 回充 ${fmtMah(p.charge_mah)}`;
        } else if (p.quality === 'partial_window') {
          value = '覆盖不足';
          detail = '覆盖未达到 80%，暂不显示平均功耗';
        } else if (p.quality === 'no_discharge_delta') {
          value = '暂无变化';
          detail = '电荷计未观察到可用放电差值';
        } else {
          value = pSamples >= 2 ? qualityLabel(p.quality) : '采样不足';
          detail = '等待更多有效电荷计样本';
        }
        const net = Number(p.net_discharge_mah);
        const netText = Number.isFinite(net)
          ? (net >= 0 ? `净放电 ${fmtMah(net)}` : `净回充 ${fmtMah(Math.abs(net))}`)
          : '净收支 —';
        const startsAtWindow = Number.isFinite(Number(p.window_start_ts))
          && Number.isFinite(Number(p.start_ts))
          && Number(p.window_start_ts) <= Number(p.start_ts);
        const baselineText = p.baseline_used === true
          ? '起点已补齐'
          : (startsAtWindow ? '起点样本完整' : '起点样本不足');
        return {
          min, p, t, pSamples, tSamples, expectedSec, coverageSec, coveragePercent,
          trustedAverage, tone: trustedAverage ? 'good' : qualityTone(p.quality), value, detail,
          netText, baselineText
        };
    };
    const views = windows.map(windowView).filter(Boolean);
    if (!views.some((view) => view.min === state.energy.detail.activeWindowMinutes) && views.length) {
      state.energy.detail.activeWindowMinutes = views.find((view) => view.min === 30)?.min || views[0].min;
    }
    const activeView = views.find((view) => view.min === state.energy.detail.activeWindowMinutes) || null;
    const renderSignature = getEnergyRenderSignature(d);
    const existingRoot = refs.detailBody.firstElementChild;
    if (state.energy.detail.renderSignature === renderSignature && existingRoot?.classList.contains('energy-overview')) return;
    const root = el('div', 'energy-overview');

    const usedMah = Number(scope.used_mah);
    const batteryLevel = Number(charge.level);
    const hero = el('section', `energy-hero${chargeLike ? ' warn' : ''}`);
    const heroCopy = el('div', 'energy-hero-copy');
    const heroTop = el('div', 'energy-hero-top');
    heroTop.append(el('span', 'energy-hero-kicker', '当前放电会话'), el('span', qualityBadge(scope.quality), qualityLabel(scope.quality)));
    const heroValue = el('div', 'energy-hero-value');
    heroValue.append(el('strong', '', Number.isFinite(usedMah) ? usedMah.toFixed(1) : '—'), el('span', '', 'mAh'));
    const levelChange = Number.isFinite(Number(scope.level_start)) && Number.isFinite(Number(scope.level_now))
      ? `${scope.level_start}% → ${scope.level_now}%`
      : '电量变化 —';
    heroCopy.append(heroTop, heroValue, el('div', 'energy-hero-meta', `${fmtDuration(scope.elapsed_sec)} · ${levelChange} · ${chargeStatusLabel}`));
    const levelRing = el('div', 'energy-level-ring');
    levelRing.style.setProperty('--energy-level', `${Math.max(0, Math.min(100, Number.isFinite(batteryLevel) ? batteryLevel : 0))}%`);
    levelRing.append(el('strong', '', Number.isFinite(batteryLevel) ? `${batteryLevel}%` : '—'), el('small', '', powerSourceLabel));
    hero.append(heroCopy, levelRing);
    root.appendChild(hero);

    if (activeView && activeView.p.quality !== 'pure_discharge') {
      const warningMap = {
        mixed_charge_discharge: '窗口内同时发生充电和放电，仅显示实际收支。',
        charging_endpoint: `当前为${powerSourceLabel}，短窗口仅显示充放电收支。`,
        partial_window: '窗口覆盖不足 80%，暂不显示平均功耗。',
        insufficient_samples: '有效采样点不足，暂时只显示基础状态。',
        no_discharge_delta: '电荷计暂未观察到放电差值，等待下一批采样。',
        no_data: '暂未获得短窗口数据。'
      };
      const alert = el('div', `energy-alert ${activeView.tone}`);
      alert.setAttribute('role', 'status');
      alert.append(el('span', 'energy-alert-icon', '!'), el('span', '', warningMap[activeView.p.quality] || text(scope.warning)));
      root.appendChild(alert);
    }

    const trend = el('section', 'energy-section');
    trend.appendChild(sectionHead('最近趋势', '选择时间范围查看功耗与温度。'));
    const rangeTabs = el('div', 'energy-range-tabs');
    rangeTabs.setAttribute('role', 'group');
    rangeTabs.setAttribute('aria-label', '功耗统计窗口');
    views.forEach((view) => {
      const button = el('button', `energy-range-btn ${view.tone}${view.min === state.energy.detail.activeWindowMinutes ? ' active' : ''}`, `${view.min} 分钟`);
      button.type = 'button';
      button.setAttribute('aria-pressed', view.min === state.energy.detail.activeWindowMinutes ? 'true' : 'false');
      button.addEventListener('click', () => {
        state.energy.detail.activeWindowMinutes = view.min;
        renderEnergyDetail(state.energy.detail.liveData || input, { fullData: state.energy.detail.fullData });
      });
      rangeTabs.appendChild(button);
    });
    trend.appendChild(rangeTabs);
    if (activeView) {
      const focus = el('article', `energy-window-focus ${activeView.tone}`);
      const focusHead = el('div', 'energy-window-focus-head');
      const focusTitle = el('div', 'energy-window-focus-title');
      focusTitle.append(el('span', '', activeView.trustedAverage ? '平均放电功耗' : qualityLabel(activeView.p.quality)), el('strong', '', activeView.value));
      focusHead.append(focusTitle, el('span', qualityBadge(activeView.p.quality), qualityLabel(activeView.p.quality)));
      focus.append(focusHead, el('div', 'energy-window-focus-desc', activeView.detail));
      const miniGrid = el('div', 'energy-window-mini-grid');
      [
        ['实际放电', fmtMah(activeView.p.discharge_mah)],
        ['回充', fmtMah(activeView.p.charge_mah)],
        ['温度', activeView.tSamples >= 2 ? `${fmtTempC(activeView.t.temp_avg_c)} / ${fmtTempC(activeView.t.temp_max_c)}` : '—']
      ].forEach(([label, value]) => {
        const item = el('div', 'energy-window-mini');
        item.append(el('span', '', label), el('strong', '', value));
        miniGrid.appendChild(item);
      });
      focus.appendChild(miniGrid);
      const coverage = el('div', 'energy-coverage');
      const coverageCopy = el('div', 'energy-coverage-copy');
      coverageCopy.append(el('span', '', `覆盖 ${fmtDuration(activeView.coverageSec)} / ${fmtDuration(activeView.expectedSec)}`), el('strong', '', `${activeView.coveragePercent}%`));
      const bar = el('div', 'energy-coverage-bar');
      const fill = el('span');
      fill.style.width = `${activeView.coveragePercent}%`;
      bar.appendChild(fill);
      coverage.append(coverageCopy, bar, el('div', 'energy-window-footnote', `${activeView.netText} · ${activeView.pSamples} 个有效点 · ${activeView.baselineText}`));
      focus.appendChild(coverage);
      trend.appendChild(focus);
    } else {
      trend.appendChild(el('div', 'energy-empty', '暂无短窗口数据'));
    }
    root.appendChild(trend);

    const daily = el('section', 'energy-section');
    daily.appendChild(sectionHead('今日收支', `${fmtDuration(today.elapsed_sec)} · ${Number.isFinite(Number(today.samples)) ? today.samples : 0} 个采样点`));
    const dailyGrid = el('div', 'energy-daily-grid');
    [
      ['放电', fmtMah(today.discharge_mah), ''],
      ['回充', fmtMah(today.charge_mah), Number(today.charge_mah) > 0 ? 'warn' : ''],
      ['净电量', fmtSignedPercent(today.net_level_delta), Number(today.net_level_delta) < 0 ? 'primary' : '']
    ].forEach(([label, value, tone]) => {
      const item = el('div', `energy-daily-item ${tone}`);
      item.append(el('span', '', label), el('strong', '', value));
      dailyGrid.appendChild(item);
    });
    daily.appendChild(dailyGrid);
    root.appendChild(daily);

    const rankList = (items, type) => {
      const list = el('div', 'energy-rank-list');
      const max = Math.max(...items.map((item) => Number(item.value) || 0), 1);
      items.forEach((item, index) => {
        const itemRow = el('div', 'energy-rank-row');
        const marker = el('span', 'energy-rank-index', String(index + 1));
        const copy = el('div', 'energy-rank-copy');
        copy.append(el('strong', '', item.label), el('small', '', item.subtitle || (type === 'app' ? '系统模型估算' : '系统分项')));
        const value = el('div', 'energy-rank-value', fmtMah(item.value));
        const bar = el('div', 'energy-rank-bar');
        const fill = el('span');
        fill.style.width = `${Math.max(4, Math.min(100, ((Number(item.value) || 0) / max) * 100))}%`;
        bar.appendChild(fill);
        itemRow.append(marker, copy, value, bar);
        list.appendChild(itemRow);
      });
      return list;
    };
    const packageLabel = (app) => {
      const pkg = String(app.pkg || '');
      return friendlyPackageLabel(pkg, app.label);
    };
    const apps = Array.isArray(d.apps) ? d.apps.map((app) => {
      const pkg = String(app.pkg || '');
      const category = String(app.category || '');
      const legacyUid = /^u\d+[ai]\d+$/.test(pkg) ? pkg : '';
      const uid = String(app.uid || legacyUid || (Number.isFinite(Number(app.uid_num)) ? `UID ${app.uid_num}` : 'UID 未知'));
      const displayPkg = legacyUid ? '' : pkg;
      const subtitle = displayPkg
        ? [displayPkg, category, uid].filter(Boolean).join(' · ')
        : [uid, category, '未找到当前安装包'].filter(Boolean).join(' · ');
      return { label: packageLabel(app), subtitle, value: Number(app.mah) || 0 };
    }).filter((app) => app.value > 0) : [];
    const components = [
      { label: '屏幕', value: Number(d.screen) || 0 },
      { label: 'CPU', value: Number(d.cpu) || 0 },
      { label: 'Wi-Fi', value: Number(d.wifi) || 0 },
      { label: '唤醒锁', value: Number(d.wakelock) || 0 }
    ].filter((item) => item.value > 0).sort((a, b) => b.value - a.value);
    const attribution = el('section', 'energy-section');
    attribution.appendChild(sectionHead('耗电构成', d._has_full_system ? `系统统计更新于 ${systemCacheAge}` : '正在加载系统统计'));
    if (d._has_full_system) {
      const groups = el('div', 'energy-attribution-grid');
      const appGroup = el('div', 'energy-attribution-group');
      appGroup.appendChild(el('div', 'energy-group-title', '耗电应用'));
      appGroup.appendChild(apps.length ? rankList(apps.slice(0, 3), 'app') : el('div', 'energy-empty compact', '暂无应用归因'));
      const systemGroup = el('div', 'energy-attribution-group');
      systemGroup.appendChild(el('div', 'energy-group-title', '系统分项'));
      systemGroup.appendChild(components.length ? rankList(components.slice(0, 4), 'system') : el('div', 'energy-empty compact', '暂无系统分项'));
      groups.append(appGroup, systemGroup);
      attribution.appendChild(groups);
    } else {
      attribution.appendChild(el('div', 'energy-loading-card', '正在加载系统分项和应用排行。'));
    }
    const modemNote = el('div', `energy-modem-note ${odpm.total_mah != null ? 'good' : 'off'}`);
    modemNote.append(el('strong', '', '蜂窝'), el('span', '', odpm.total_mah != null ? odpmValue : '蜂窝数据暂不可用；系统模型偏差较大，已从排行中排除。'));
    attribution.appendChild(modemNote);
    root.appendChild(attribution);

    const technical = el('section', 'energy-section energy-technical');
    technical.appendChild(sectionHead('更多统计', '查看数据口径、系统模型和历史导出。'));
    const scopeBody = el('div', 'energy-disclosure-body');
    const scopeList = el('div', 'data-list');
    scopeList.append(
      row('默认口径', '当前放电会话', 'badge good'),
      row('数据质量', qualityLabel(scope.quality), qualityBadge(scope.quality)),
      row('当前状态', chargeStatusLabel, chargeLike ? 'badge warn' : 'badge off'),
      row('外接电源', powerSourceLabel, externalPower ? 'badge warn' : 'badge good'),
      row('会话开始', fmtDateTime(scope.start_ts)),
      row('最近重置原因', fmtSessionResetReason(scope.reset_reason)),
      row('重置规则', text(scope.reset_rule)),
      row('口径提示', scope.quality === 'charging_endpoint' ? `当前为${powerSourceLabel}，不代表此前待机状态` : qualityLabel(scope.quality)),
      row('今日起点', fmtDateTime(today.start_ts)),
      row('今日首个样本', fmtDateTime(today.window_start_ts)),
      row('轻量刷新时间', liveRefreshLabel, d._using_fast_live ? 'badge good' : 'badge off')
    );
    scopeBody.appendChild(scopeList);
    technical.appendChild(disclosure('scope', '数据口径', `${qualityLabel(scope.quality)} · ${chargeStatusLabel}`, scopeBody));

    const systemBody = el('div', 'energy-disclosure-body');
    const systemList = el('div', 'data-list');
    systemList.append(
      row('系统窗口', fmtBatterystatsWindow(bs.window_label)),
      row('统计窗口', comparable ? '一致，可比较' : '不一致或未知', comparable ? 'badge good' : 'badge warn'),
      row('模型质量', modelQualityLabel(bs.model_quality), radioUntrusted ? 'badge warn' : 'badge off'),
      row('系统统计时间', systemSnapshot, d._has_full_system ? 'data-val' : 'badge warn'),
      row('数据更新时间', systemCacheAge, systemCacheWarn ? 'badge warn' : 'badge off'),
      row('数据状态', systemCacheState, systemCacheWarn ? 'badge warn' : 'badge good'),
      row('刷新周期', Number.isFinite(Number(d.cache_ttl_sec)) ? `${d.cache_ttl_sec} 秒` : '—'),
      row('电池容量', `${text(d.cap)} mAh`),
      row('预估耗电', `${text(d.drain)} mAh`),
      row('亮屏耗电', `${text(d.scron)} mAh`),
      row('息屏耗电', `${text(d.scroff)} mAh`),
      row('屏幕', `${text(d.screen)} mAh`),
      row('CPU', `${text(d.cpu)} mAh`),
      row('Wi-Fi', `${text(d.wifi)} mAh`),
      row('唤醒锁', `${text(d.wakelock)} mAh`),
      row('蜂窝硬件计量 (ODPM)', odpmValue, odpm.total_mah != null ? 'data-val' : 'badge off'),
      row('蜂窝系统估算', `${text(d.cell)} mAh · 仅供参考`, radioUntrusted ? 'badge warn' : 'badge off'),
      row('蜂窝说明', text(bs.radio_note))
    );
    systemBody.appendChild(systemList);
    if (apps.length) {
      systemBody.appendChild(el('div', 'energy-group-title detail', `全部应用归因 Top ${apps.length}`));
      systemBody.appendChild(rankList(apps, 'app'));
    }
    technical.appendChild(disclosure('system', '系统耗电估算', d._has_full_system ? `${text(d.drain)} mAh · ${systemCacheAge}` : '正在加载', systemBody));

    const exportBody = el('div', 'energy-disclosure-body');
    exportBody.appendChild(el('p', 'energy-export-note', '将指定窗口的功耗与温度原始 CSV 保存到 /sdcard/Download；“本次窗口”从打开当前页面时开始。'));
    const exportWrap = el('div', 'energy-export-actions');
    [15, 30, 60].forEach((min) => {
      const btn = el('button', 'tiny-btn', `保存 ${min} 分钟`);
      btn.type = 'button';
      btn.addEventListener('click', () => exportHistoryWindow(min, btn));
      exportWrap.appendChild(btn);
    });
    const sessionBtn = el('button', 'tiny-btn', '保存本次窗口');
    sessionBtn.type = 'button';
    sessionBtn.addEventListener('click', () => exportHistoryWindow('session', sessionBtn));
    exportWrap.appendChild(sessionBtn);
    exportBody.appendChild(exportWrap);
    technical.appendChild(disclosure('export', '历史与导出', '导出 15/30/60 分钟或本次窗口 CSV', exportBody));
    root.appendChild(technical);

    if (existingRoot?.classList.contains('energy-overview')) reconcileStableDom(existingRoot, root);
    else refs.detailBody.replaceChildren(root);
    state.energy.detail.renderSignature = renderSignature;
  } catch (err) {
    state.energy.detail.renderSignature = '';
    refs.detailBody.replaceChildren(); refs.detailBody.appendChild(errorBlock(err.message));
  }
}

function scheduleEnergyDetailRefresh(delay = ENERGY_DETAIL_REFRESH_MS) {
  if (state.energy.detail.timer) clearTimeout(state.energy.detail.timer);
  if (!isWebUiActive() || !refs.detailModal.classList.contains('open')) return;
  const requestId = state.energy.detail.requestId;
  state.energy.detail.timer = window.setTimeout(async () => {
    state.energy.detail.timer = null;
    if (!isWebUiActive() || !refs.detailModal.classList.contains('open') || requestId !== state.energy.detail.requestId) return;
    if (state.energy.detail.requestKind) {
      scheduleEnergyDetailRefresh(POLL_MIN_DELAY_MS);
      return;
    }
    try {
      const live = await fetchEnergyFastDetail();
      if (!live || requestId !== state.energy.detail.requestId) return;
      if (isFullEnergyDetailData(live)) state.energy.detail.fullData = live;
      else state.energy.detail.liveData = live;
      renderEnergyDetail(live, { fullData: state.energy.detail.fullData });
    } catch (_) {}
    if (isWebUiActive() && refs.detailModal.classList.contains('open') && requestId === state.energy.detail.requestId) {
      scheduleEnergyDetailRefresh();
    }
  }, delay);
}

function scheduleEnergySystemRefresh(delay = getEnergySystemRefreshDelay()) {
  if (state.energy.detail.fullTimer) clearTimeout(state.energy.detail.fullTimer);
  if (!isWebUiActive() || !refs.detailModal.classList.contains('open')) return;
  const requestId = state.energy.detail.requestId;
  state.energy.detail.fullTimer = window.setTimeout(async () => {
    state.energy.detail.fullTimer = null;
    if (!isWebUiActive() || !refs.detailModal.classList.contains('open') || requestId !== state.energy.detail.requestId) return;
    if (state.energy.detail.requestKind) {
      scheduleEnergySystemRefresh(POLL_MIN_DELAY_MS);
      return;
    }
    try {
      const full = await fetchEnergySystemDetail();
      if (!full || requestId !== state.energy.detail.requestId) return;
      if (isFullEnergyDetailData(full)) {
        state.energy.detail.fullData = full;
        state.energy.detail.liveData = full;
        renderEnergyDetail(full, { fullData: state.energy.detail.fullData });
      }
    } catch (_) {}
    if (isWebUiActive() && refs.detailModal.classList.contains('open') && requestId === state.energy.detail.requestId) {
      scheduleEnergySystemRefresh();
    }
  }, delay);
}

async function openEnergyDetail() {
  stopTempChartRefresh();
  stopEnergyDetailRefresh();
  state.energy.detail.fullData = null;
  state.energy.detail.liveData = null;
  state.energy.detail.renderSignature = '';
  const requestId = state.energy.detail.requestId;
  refs.detailTitle.textContent = '功耗统计';
  setStaticHtml(refs.detailBody, '<div style="text-align:center;color:var(--text-3);padding:24px 0;font-size:13px">正在加载功耗数据…</div>');
  refs.detailModal.classList.remove('history-mode');
  refs.detailModal.classList.add('energy-mode');
  refs.detailModal.classList.add('open');
  pushModalState('detail');
  queueNextPoll(computeNextPollDelay());
  try {
    const live = await fetchEnergyFastDetail();
    if (requestId !== state.energy.detail.requestId) return;
    state.energy.detail.liveData = live;
    renderEnergyDetail(live, { fullData: state.energy.detail.fullData });
    scheduleEnergyDetailRefresh();
    scheduleEnergySystemRefresh(350);
  } catch (err) {
    if (requestId !== state.energy.detail.requestId) return;
    try {
      const initial = await fetchEnergyDetailWithRetry();
      if (requestId !== state.energy.detail.requestId) return;
      if (isFullEnergyDetailData(initial)) {
        state.energy.detail.fullData = initial;
        state.energy.detail.liveData = initial;
      } else {
        state.energy.detail.liveData = initial;
      }
      renderEnergyDetail(initial, { fullData: state.energy.detail.fullData });
      scheduleEnergyDetailRefresh(350);
      scheduleEnergySystemRefresh();
    } catch (fallbackErr) {
      if (requestId !== state.energy.detail.requestId) return;
      refs.detailBody.replaceChildren();
      refs.detailBody.appendChild(errorBlock(fallbackErr.message || err.message));
    }
  }
}

registerFeature('energy', {
  open: openEnergyDetail,
  pause: pauseEnergyDetailRefresh,
  scheduleDetail: scheduleEnergyDetailRefresh,
  scheduleSystem: scheduleEnergySystemRefresh
});

