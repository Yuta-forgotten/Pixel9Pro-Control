'use strict';
(() => {
  const state = {
    open: false, source: 'thermal', thermalSensor: 'module', rangeId: '30', customSeconds: 86400, customDays: 1, customGranularity: 'hour',
    view: null, cache: new Map(), rankCache: new Map(), requestId: 0, request: null,
    overviewRequest: null, rankRequest: null, rankGeneration: 0, timer: null,
    summary: null, ranking: { status: 'idle' }, rankRefreshRequested: false, policy: null,
    historyFingerprint: '', activeKey: '', selectedBounds: null, lastCaptureStatus: '', detailsDue: true, lastDetailsAt: 0, observer: null, suspended: false, initialLoadPending: false
  };
  const core = () => requireFeature('core');
  const apiFetch = (...args) => core().apiFetch(...args);
  const isCancelled = (err) => core().isRequestCancelled?.(err) === true;
  const showToast = (...args) => core().showToast(...args);
  const appendLog = (...args) => core().appendLog(...args);
  const isActive = () => core().isWebUiActive() && refs.detailModal?.classList.contains('open') && !refs.detailModal.classList.contains('detail-minimized');
  const isPowerSource = () => state.source === 'power' || state.source === 'system';
  const model = () => requireFeature('analyticsModel');
  const capture = () => requireFeature('capture');
  const captureBusy = () => capture().isBusy?.() === true;
  const viewFeature = () => requireFeature('analyticsView');
  const endpoint = () => (globalThis.API && API.telemetry) || '/cgi-bin/telemetry.sh';
  const revisionBase = (value) => {
    const text = String(value || '').trim();
    if (!text || text === 'none' || text === 'empty' || text === 'unknown') return '';
    return text.split(':').slice(0, 3).join(':');
  };

  function key() {
    return `${state.source}:${state.thermalSensor}:${state.rangeId}:${state.customSeconds}:${state.customGranularity}:${effectiveGranularity()}`;
  }
  function query(path, params) {
    const search = new URLSearchParams(params);
    return `${path}${path.includes('?') ? '&' : '?'}${search.toString()}`;
  }
  function rangeBounds() {
    if (state.rangeId === 'custom') {
      const endTs = Math.floor(Date.now() / 1000);
      return { startTs: endTs - state.customSeconds, endTs, granularity: state.source === 'system' ? 'raw' : state.customGranularity };
    }
    const minutes = model().rangeFor(state.rangeId).minutes;
    const endTs = Math.floor(Date.now() / 1000);
    return { startTs: endTs - minutes * 60, endTs, granularity: state.source === 'system' ? 'raw' : effectiveGranularity() };
  }
  function effectiveGranularity() {
    if (state.rangeId === 'custom') return state.customGranularity;
    return model().rangeFor(state.rangeId).minutes <= 480 ? 'minute' : 'hour';
  }
  function policyEnabled() {
    if (!state.policy) return false;
    const value = state.policy?.analytics_enabled;
    return value !== false && value !== 0 && value !== 'false' && value !== '0';
  }
  function disabledStats() {
    const stats = state.source === 'thermal' ? model().temperatureStats([]) : model().powerStats([]);
    stats.policy = state.policy;
    return stats;
  }
  async function loadPolicy() {
    if (!API.historyPolicy) return null;
    try {
      const data = await apiFetch(API.historyPolicy, { method: 'GET', timeoutMs: 8000, priority: 'interactive', scope: 'analytics.policy.read' });
      if (data?.ok === false) throw new Error(data.error || data.reason || '后台策略读取失败');
      state.policy = { ...(data.policy || data), phase: data.phase || data.policy?.phase || data.phase };
      updateView(true);
      return state.policy;
    } catch (err) {
      state.policy = null;
      showToast(`后台记录策略读取失败：${err.message || err}`);
      return null;
    }
  }
  function cancelSlot(slot, reason) {
    const controller = state[slot];
    if (controller) controller.abort(reason);
    state[slot] = null;
  }
  function abort(reason = 'analytics-replaced') {
    state.requestId += 1;
    cancelSlot('request', reason); cancelSlot('overviewRequest', reason); cancelSlot('rankRequest', reason);
    state.rankGeneration += 1;
    capture().abort(reason);
    if (state.timer) { clearTimeout(state.timer); state.timer = null; }
  }
  async function request(path, timeoutMs = 8000, slot = 'request') {
    const requestId = state.requestId;
    const controller = new AbortController();
    cancelSlot(slot, 'request-replaced'); state[slot] = controller;
    try {
      return await apiFetch(path, { timeoutMs, controller, priority: slot === 'rankRequest' ? 'background' : 'normal', scope: `analytics.${slot}` });
    } finally {
      if (state[slot] === controller) state[slot] = null;
      if (slot === 'request' && requestId !== state.requestId) return null;
    }
  }
  function ensureView() {
    if (state.view) return state.view;
    state.view = viewFeature().create({
      onSource: (source) => { state.source = source; if (source !== 'thermal' || state.thermalSensor !== 'module') stopBurst(); load(false); },
      onThermalSensor: (sensor) => { state.thermalSensor = sensor; if (state.source === 'thermal' && sensor === 'module') triggerBurst({ prompt: false }); else stopBurst(); load(false); },
      onRange: (rangeId) => { state.rangeId = rangeId; if (rangeId === 'custom') { viewFeature().setCustomValues(state.view, state.customSeconds, state.customGranularity); viewFeature().promptCustom(state.view); return; } load(false); },
      onCustom: (days, granularity) => {
        const parsedSeconds = Math.floor(Number(days));
        if (!Number.isFinite(parsedSeconds) || parsedSeconds < 14400 || parsedSeconds > 604800 || !['hour', 'minute'].includes(granularity)) { showToast('自定义范围请选择 4 小时至 7 天，并选择小时或分钟粒度'); return; }
        state.customSeconds = parsedSeconds; state.customDays = Math.max(1, Math.ceil(parsedSeconds / 86400)); state.customGranularity = granularity; state.rangeId = 'custom'; load(false);
      },
      onCapture: async (button, duration) => {
        if (policyEnabled()) { showToast('后台观测正在运行；请先暂停后台观测，再启动临时诊断'); return; }
        button.disabled = true;
        try {
          const active = capture().getSession();
          if (active?.status === 'running') {
            await capture().stop(active.id); appendLog('低功耗记录已结束，正在刷新状态', 'ok');
          } else {
            const data = await capture().start(duration); if (data?.session) appendLog(`低功耗记录已开始（${duration ? `${duration} 秒` : '手动结束'}）`, 'ok');
          }
          await capture().status(); state.rankRefreshRequested = active?.status === 'running'; state.detailsDue = true; load(true, active?.status === 'running');
        } catch (err) { showToast(`记录操作失败：${err.message || err}`); appendLog(String(err), 'err'); }
        button.disabled = false;
      },
      onCaptureExport: async (button) => {
        const session = capture().getSession(); if (!session) { showToast('没有可导出的记录会话'); return; }
        button.disabled = true;
        try { const data = await capture().export(session.id); showToast(data?.directory ? '记录已导出' : '导出已提交'); appendLog(`记录导出完成：${data?.directory || '后台目录'}`, 'ok'); }
        catch (err) { showToast(`记录导出失败：${err.message || err}`); appendLog(String(err), 'err'); }
        button.disabled = false;
      },
      onRefresh: async (button) => {
        button.disabled = true;
        state.rankRefreshRequested = true;
        state.detailsDue = true;
        try {
          await load(true, true);
        } finally {
          // A timeout or an aborted range switch must never leave the manual
          // refresh control latched until the page is reloaded.
          button.disabled = false;
        }
      },
      onExport: (button) => exportRange(button),
      onPolicy: (button, policy) => savePolicy(button, policy)
    });
    return state.view;
  }
  function updateView(details = false) {
    if (!state.view) return;
    const session = capture().getSession();
    const cached = state.cache.get(key());
    if (!cached) return;
    const refreshDetails = details || state.detailsDue || !state.lastDetailsAt || (Date.now() - state.lastDetailsAt) >= 120000;
    viewFeature().update(state.view, { source: state.source, thermalSensor: state.thermalSensor, rangeId: state.rangeId, stats: cached.stats, status: cached.status, summary: state.summary, ranking: state.ranking, details: refreshDetails, capture: { session } });
    if (refreshDetails) { state.detailsDue = false; state.lastDetailsAt = Date.now(); }
  }
  function normalizeResponse(data, bounds) {
    const source = state.source;
    const finiteMeta = (value) => value === null || value === undefined || value === '' || (typeof value !== 'number' && typeof value !== 'string') ? null : Number.isFinite(Number(value)) ? Number(value) : null;
    const windowMeta = data?.window || {};
    const sourceKey = source === 'system' ? 'power' : source === 'thermal' && state.thermalSensor === 'battery' ? 'thermal' : source;
    const sourceMeta = data?.sources?.[sourceKey] || data?.meta || {};
    const meta = { ...windowMeta, ...sourceMeta };
    const options = { ...bounds, granularity: meta.granularity || bounds.granularity, quality: meta.quality || '', native: source === 'system', backendGaps: model().explicitGaps(data) };
    const annotate = (stats) => {
      stats.backendSampleCount = finiteMeta(meta.raw_samples ?? meta.samples ?? meta.sample_count);
      stats.backendValidSamples = finiteMeta(meta.valid_samples);
      stats.backendInvalidSamples = finiteMeta(meta.invalid_samples);
      stats.backendGapCount = finiteMeta(meta.gap_count) ?? (Array.isArray(meta.gaps) ? meta.gaps.length : null);
      const coverage = finiteMeta(meta.coverage_ratio ?? meta.coverage);
      stats.backendCoverageRatio = coverage === null ? null : (coverage > 1 ? coverage / 100 : coverage);
      stats.backendQuality = String(meta.quality || '');
      stats.backendStatus = String(data?.status || '');
      stats.backendReason = String(data?.reason || meta.reason || '');
      stats.dataRevision = revisionBase(data?.data_revision ?? data?.history_revision ?? meta.data_revision ?? meta.history_revision ?? '');
      stats.rankRevision = revisionBase(data?.rank_revision ?? data?.power_rank_revision ?? '');
      stats.historySource = source === 'system' || state.thermalSensor === 'battery' ? 'android' : 'module';
      stats.collection = data?.collection || null; stats.policy = data?.policy || null; stats.window = data?.window || null; stats.screenTotals = data?.screen_totals || data?.screenTotals || null; stats.batteryLevel = data?.battery_level || data?.batteryLevel || null;
      return stats;
    };
    if (source === 'thermal') {
      const points = model().clip(model().normalizeThermal(data).filter((point) => point.sensor === (state.thermalSensor === 'battery' ? 'battery' : 'module')), bounds.startTs, bounds.endTs);
      const stats = model().temperatureStats(points, options);
      return { stats: annotate(stats), status: data?.status === 'disabled' ? '后台历史记录已关闭；温控控制仍可继续工作。' : stats.count < 2 ? (state.thermalSensor === 'battery' ? '系统电池温度记录不足；缺测保持为空。' : '模块机身温度记录不足；息屏/待机期间缺测保持为空。') : '' };
    }
    const points = model().clip(model().normalizePower(data), bounds.startTs, bounds.endTs, true);
    const stats = model().powerStats(points, options);
    return { stats: annotate(stats), status: data?.status === 'disabled' ? '后台历史记录已关闭；重新打开后才会生成系统归因。' : stats.count < 2 || !stats.series.length ? '当前区间没有足够的有效放电数据；缺测不会补零。' : '' };
  }
  async function fetchSource(bounds) {
    const params = { action: 'history' };
    if (bounds.startTs !== null && Number.isFinite(Number(bounds.startTs))) params.start_ts = Math.floor(bounds.startTs);
    if (bounds.endTs !== null && Number.isFinite(Number(bounds.endTs))) params.end_ts = Math.floor(bounds.endTs);
    // The main history sheet represents the entire selected time range. A
    // recent manual capture must not hide service history from the same range.
    if (state.source === 'system' || (state.source === 'thermal' && state.thermalSensor === 'battery')) {
      return request(query(API.systemHistory || '/cgi-bin/system_history.sh', { start_ts: params.start_ts, end_ts: params.end_ts, granularity: bounds.granularity, dataset: 'system' }), 12000, 'request');
    }
    if (state.source === 'thermal' && state.thermalSensor === 'module' && !policyEnabled()) {
      return request(query(API.thermal || '/cgi-bin/thermal.sh', { fresh: 1 }), 8000, 'request');
    }
    return capture().history({ startTs: params.start_ts, endTs: params.end_ts, granularity: bounds.granularity });
  }
  function rankKey(bounds, stats) {
    const windowId = state.rangeId === 'custom' ? `custom-${state.customSeconds}s` : `range-${state.rangeId}`;
    const step = bounds.granularity === 'hour' ? 3600 : bounds.granularity === 'minute' ? 60 : 1;
    const start = Math.floor(Number(bounds.startTs) / step) * step;
    const end = Math.floor(Number(bounds.endTs) / step) * step;
    return `${state.source}|${windowId}|${start}|${end}|${bounds.granularity || 'raw'}`;
  }
  function rankWindow(bounds, stats) {
    const windowLabel = state.rangeId === 'custom' ? `最近 ${model().formatDuration(state.customSeconds)}` : model().rangeFor(state.rangeId).label;
    const ratio = Number.isFinite(Number(stats?.backendCoverageRatio)) ? Number(stats.backendCoverageRatio) * 100 : stats?.coveragePct;
    return { label: windowLabel, granularity: bounds.granularity, coveragePct: ratio, validSamples: stats?.backendValidSamples ?? stats?.validCount ?? stats?.count };
  }
  async function fetchEnergySummary(bounds, stats, forceRank = false, contextKey = state.activeKey) {
    // Android system history is already the selected source. Its bounds use
    // `raw`, which is intentionally not a software-attribution ranking input.
    // Do not send raw granularity to power_rank.sh (that endpoint accepts only
    // minute/hour) and do not show a false software ranking on this tab.
    if (state.source === 'system') return;
    if (state.source === 'power') {
      try {
        const fast = await request(API.energyFast, 4000, 'overviewRequest');
        if (!state.open || !isActive() || state.activeKey !== contextKey || !isPowerSource()) return;
        if (fast) { state.summary = fast; updateView(); }
      } catch (_) {
        // The real-time card remains usable when the fast summary is unavailable.
      }
    }
    const cacheKey = rankKey(bounds, stats);
    const cached = state.rankCache.get(cacheKey);
    const window = rankWindow(bounds, stats);
    if (!state.open || !isActive() || state.activeKey !== contextKey) return;
    const revisionChanged = state.source === 'system' && cached && stats?.rankRevision && cached.revision && String(stats.rankRevision) !== String(cached.revision);
    const cacheExpired = cached && cached.updatedAt && Date.now() - cached.updatedAt >= 120000;
    const retryableUnavailable = cached && ['unavailable', 'error'].includes(cached.status) && (cacheExpired || revisionChanged);
    if (!forceRank && cached && !revisionChanged && !cacheExpired && !retryableUnavailable) {
      state.ranking = { ...cached, window, updatedAt: cached.updatedAt || Date.now() };
      updateView();
      return;
    }
    cancelSlot('rankRequest', 'ranking-replaced');
    const generation = ++state.rankGeneration;
    state.ranking = { status: 'loading', window, cacheKey };
    updateView();
    try {
      const full = await request(query(API.powerRank || '/cgi-bin/power_rank.sh', { start_ts: bounds.startTs, end_ts: bounds.endTs, granularity: bounds.granularity }), 16000, 'rankRequest');
      if (!state.open || !isActive() || generation !== state.rankGeneration || !full) return;
      if (full.ok !== true) throw new Error(full.error || full.reason || '后台未返回有效排行');
      const rankCoverage = Number(full.coverage_ratio);
      const rankMeta = { label: `${new Date(bounds.startTs * 1000).toLocaleString()} — ${new Date(bounds.endTs * 1000).toLocaleString()}`, granularity: bounds.granularity, coveragePct: Number.isFinite(rankCoverage) ? (rankCoverage > 1 ? rankCoverage : rankCoverage * 100) : null, validSamples: full.valid_samples ?? null, gapCount: Array.isArray(full.gaps) ? full.gaps.length : null, reason: full.reason || '', attributionState: full.attribution_state || '', windowProven: full.window_proven !== false };
      const result = { status: full.status || 'ready', summary: full, window: rankMeta, cacheKey, updatedAt: Number(full.updated_at) > 0 ? Number(full.updated_at) * 1000 : Date.now(), revision: revisionBase(full.data_revision) };
      state.rankCache.set(cacheKey, result);
      state.ranking = result;
      updateView();
    } catch (err) {
      if (!state.open || !isActive() || generation !== state.rankGeneration) return;
      state.ranking = { status: 'error', error: err?.message || String(err), window, cacheKey };
      updateView();
    }
  }
  async function load(force = false, forceRank = false) {
    if (!state.open || !isActive() || state.initialLoadPending) return null;
    const view = ensureView(); const cacheKey = key(); const requestedBounds = rangeBounds();
    const selectionChanged = state.activeKey !== cacheKey;
    if (selectionChanged) {
      state.activeKey = cacheKey; state.summary = null; state.rankRefreshRequested = false;
      state.selectedBounds = requestedBounds;
      state.detailsDue = true;
      cancelSlot('overviewRequest', 'range-changed'); cancelSlot('rankRequest', 'range-changed'); state.rankGeneration += 1;
      state.ranking = { status: 'idle' };
    }
    // A periodic refresh updates the selected range's history without moving
    // its anchor. Only a new selection or an explicit user refresh changes the
    // ranking window; this prevents a rolling end timestamp from defeating the
    // ranking cache every ten seconds.
    if (selectionChanged || forceRank || !state.selectedBounds) state.selectedBounds = requestedBounds;
    const historyBounds = requestedBounds;
    const rankBounds = state.selectedBounds;
    cancelSlot('request', 'new-history'); capture().abort('new-history'); state.requestId += 1; const requestId = state.requestId;
    const requestedRank = forceRank || state.rankRefreshRequested || selectionChanged;
    state.rankRefreshRequested = false;
    if (!force && state.cache.has(cacheKey)) {
      updateView();
      {
        fetchEnergySummary(rankBounds, state.cache.get(cacheKey).stats, requestedRank, cacheKey);
        const previousCaptureStatus = state.lastCaptureStatus;
        capture().status().then((captureData) => {
          const currentCaptureStatus = captureData?.session?.status || '';
          state.lastCaptureStatus = currentCaptureStatus;
          if (previousCaptureStatus === 'running' && ['completed', 'stopped', 'failed'].includes(currentCaptureStatus)) {
            state.rankRefreshRequested = true;
            load(true, true);
          } else updateView();
        }).catch(() => {});
      }
      schedule(); return true;
    }
    if (!state.cache.has(cacheKey)) viewFeature().loading(view, state.source, state.rangeId, state.thermalSensor);
    try {
      const data = await fetchSource(historyBounds);
      if (requestId !== state.requestId) return null;
      if (!data) {
        viewFeature().error(view, state.source, state.rangeId, '读取未返回数据；请刷新当前区间', state.thermalSensor);
        return false;
      }
      if (data.ok === false) throw new Error(data.error || data.reason || '历史接口返回失败');
      const normalized = normalizeResponse(data, historyBounds);
      state.cache.set(cacheKey, normalized); updateView();
      if (normalized.stats.count < 2) viewFeature().empty(view, state.source, state.rangeId, normalized.status, state.thermalSensor);
      fetchEnergySummary(rankBounds, normalized.stats, requestedRank, cacheKey);
      if (isPowerSource()) {
        const previousCaptureStatus = state.lastCaptureStatus;
        capture().status().then((captureData) => {
          const currentCaptureStatus = captureData?.session?.status || '';
          state.lastCaptureStatus = currentCaptureStatus;
          if (previousCaptureStatus === 'running' && ['completed', 'stopped', 'failed'].includes(currentCaptureStatus)) {
            state.rankRefreshRequested = true;
            load(true, true);
          } else updateView();
        }).catch(() => {});
      }
      if (state.source === 'thermal') capture().status().catch(() => {}).then(() => updateView());
    } catch (err) {
      if (requestId !== state.requestId) return null;
      if (isCancelled(err)) {
        viewFeature().error(view, state.source, state.rangeId, '读取已暂停；当前请求已取消，请重新读取', state.thermalSensor);
        return false;
      }
      viewFeature().error(view, state.source, state.rangeId, `读取失败：${err.message || err}`, state.thermalSensor);
      return false;
    }
    schedule();
    return true;
  }
  function schedule(delay = state.source === 'thermal' ? TEMP_CHART_REFRESH_MS : state.source === 'system' ? 60000 : 30000) {
    if (state.timer) clearTimeout(state.timer); state.timer = null;
    if (!state.open || !isActive()) return;
    state.timer = window.setTimeout(() => { state.timer = null; void load(true); }, delay);
  }
  async function exportRange(button) {
    button.disabled = true;
    try {
      const bounds = rangeBounds(); const dataset = state.source === 'system' || (state.source === 'thermal' && state.thermalSensor === 'battery') ? 'system' : 'module';
      const data = await apiFetch(API.historyExport, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'export', mode: 'window', dataset, start_ts: bounds.startTs, end_ts: bounds.endTs, granularity: bounds.granularity }), timeoutMs: 10000, priority: 'interactive', scope: 'analytics.export' });
      if (data?.ok !== false) { showToast(data?.path ? `已导出当前区间：${data.path}` : '当前区间导出已提交'); appendLog(`历史区间导出完成（${dataset}）`, 'ok'); }
    } catch (err) { showToast(`导出失败：${err.message || err}`); appendLog(String(err), 'err'); }
    button.disabled = false;
  }
  async function savePolicy(button, policy) {
    if (!API.historyPolicy) { showToast('后台未提供历史策略接口'); return; }
    button.disabled = true;
    try {
      const body = { action: 'configure', analytics_enabled: policy.analytics_enabled === true, retention_days: Number(policy.retention_days), max_bytes: Number(policy.max_bytes), module_interval_on_sec: 60, module_interval_off_sec: Math.max(900, Number(policy.module_interval_off_sec) || 900), system_interval_on_sec: Math.max(300, Number(policy.system_interval_on_sec)), system_interval_off_sec: Math.max(900, Number(policy.system_interval_off_sec) || 900) };
      const result = await apiFetch(API.historyPolicy, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), timeoutMs: 8000, priority: 'interactive', scope: 'analytics.policy' });
      if (result?.ok === false) throw new Error(result.error || result.reason || '策略未生效');
      const readback = await apiFetch(API.historyPolicy, { method: 'GET', timeoutMs: 8000, priority: 'interactive', scope: 'analytics.policy.readback' });
      if (readback?.ok === false || (!readback?.policy && !readback?.phase)) throw new Error(readback?.error || readback?.reason || '后台未返回策略 readback');
      const applied = { ...(readback.policy || readback), phase: readback.phase || readback.policy?.phase || result?.phase || result?.policy?.phase };
      const phase = applied.phase || result?.phase || result?.policy?.phase || 'staged';
      state.policy = applied; if (state.view?.policy) state.view.policy.dirty = false;
      showToast(phase === 'effective' ? '后台记录设置已生效' : `后台记录设置已保存（${phase}）`); state.detailsDue = true; await load(true, true);
    } catch (err) { showToast(`策略保存失败：${err.message || err}`); } finally { button.disabled = false; }
  }
  async function triggerBurst(options = {}) {
    if (!state.open || state.source !== 'thermal' || !policyEnabled()) return false;
    if (!requireFeature('auth').hasToken()) return false;
    try { await apiFetch(API.thermalBurst, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'start', duration_sec: 300 }), timeoutMs: 4000, priority: 'interactive', scope: 'analytics.burst' }); return true; } catch (err) { return isCancelled(err) ? null : false; }
  }
  function stopBurst() { if (!requireFeature('auth').hasToken()) return; apiFetch(API.thermalBurst, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'stop' }), timeoutMs: 2500, keepalive: true, priority: 'background', scope: 'analytics.burst' }).catch(() => {}); }
  function open(source = 'thermal') {
    init();
    abort('analytics-open'); state.open = true; state.suspended = false; state.initialLoadPending = true; state.source = source; state.summary = null; state.detailsDue = true; const view = ensureView();
    refs.detailTitle.textContent = source === 'thermal' ? '温度与功耗历史' : '功耗与温度历史';
    refs.detailModal.classList.remove('energy-mode', 'history-mode', 'detail-minimized'); refs.detailModal.classList.add('analytics-mode', 'open');
    refs.detailMinimizeBtn?.setAttribute('aria-expanded', 'true');
    refs.detailMinimizeBtn?.setAttribute('aria-label', '缩小详情');
    requireFeature('ui').pushModalState('detail');
    const previousScroll = refs.detailBody.scrollTop; refs.detailBody.replaceChildren(view.root); refs.detailBody.scrollTop = previousScroll;
    stopBurst();
    loadPolicy().then(() => {
      if (!state.open) return;
      state.initialLoadPending = false;
      if (policyEnabled() && source === 'thermal' && state.thermalSensor === 'module') triggerBurst({ prompt: false });
      return load(true);
    }).catch((err) => {
      if (!state.open) return;
      state.initialLoadPending = false;
      viewFeature().error(view, source, state.rangeId, `初始化读取失败：${err?.message || err}`, state.thermalSensor);
    });
  }
  function stop() { const active = state.open; state.open = false; state.suspended = true; state.initialLoadPending = false; abort('analytics-closed'); if (active) stopBurst(); }
  function suspend(reason) { if (state.suspended) return; state.suspended = true; abort(reason); if (state.open) stopBurst(); }
  function pause() { suspend('page-hidden'); }
  function minimize() { suspend('analytics-minimized'); }
  function resume() {
    if (!state.open || !isActive() || state.initialLoadPending || (!state.suspended && (state.request || state.overviewRequest || state.rankRequest || state.timer || captureBusy()))) return;
    state.suspended = false;
    if (state.source === 'thermal' && state.thermalSensor === 'module') triggerBurst({ prompt: false });
    load(false);
  }
  function init() {
    if (state.observer || !refs.detailModal) return;
    document.addEventListener('webui-theme-changed', () => { if (state.open && isActive()) updateView(); });
    state.observer = new MutationObserver(() => { if (!state.open) return; if (refs.detailModal.classList.contains('detail-minimized')) minimize(); else if (!state.initialLoadPending && isActive() && !state.request && !state.overviewRequest && !state.rankRequest && !state.timer && !captureBusy()) resume(); });
    state.observer.observe(refs.detailModal, { attributes: true, attributeFilter: ['class'] });
  }
  registerFeature('analytics', { init, open, stop, pause, minimize, resume, triggerBurst, schedule, isActive: () => state.open && isActive(), getState: () => ({ ...state, cache: undefined }) });
})();
