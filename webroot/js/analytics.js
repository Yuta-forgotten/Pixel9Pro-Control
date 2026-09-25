'use strict';
(() => {
  const state = {
    open: false, source: 'thermal', rangeId: '30', customDays: 1, customGranularity: 'hour',
    view: null, cache: new Map(), rankCache: new Map(), requestId: 0, request: null,
    overviewRequest: null, rankRequest: null, rankGeneration: 0, timer: null,
    summary: null, ranking: { status: 'idle' }, rankRefreshRequested: false,
    historyFingerprint: '', activeKey: '', selectedBounds: null, lastCaptureStatus: '', detailsDue: true, lastDetailsAt: 0, observer: null, suspended: false
  };
  const core = () => requireFeature('core');
  const apiFetch = (...args) => core().apiFetch(...args);
  const showToast = (...args) => core().showToast(...args);
  const appendLog = (...args) => core().appendLog(...args);
  const isActive = () => core().isWebUiActive() && refs.detailModal?.classList.contains('open') && !refs.detailModal.classList.contains('detail-minimized');
  const model = () => requireFeature('analyticsModel');
  const capture = () => requireFeature('capture');
  const viewFeature = () => requireFeature('analyticsView');
  const endpoint = () => (globalThis.API && API.telemetry) || '/cgi-bin/telemetry.sh';

  function key() {
    return `${state.source}:${state.rangeId}:${state.customDays}:${state.customGranularity}:${effectiveGranularity()}`;
  }
  function query(path, params) {
    const search = new URLSearchParams(params);
    return `${path}${path.includes('?') ? '&' : '?'}${search.toString()}`;
  }
  function rangeBounds() {
    if (state.rangeId === 'custom') {
      const endTs = Math.floor(Date.now() / 1000);
      return { startTs: endTs - state.customDays * 86400, endTs, granularity: state.customGranularity };
    }
    const minutes = model().rangeFor(state.rangeId).minutes;
    const endTs = Math.floor(Date.now() / 1000);
    return { startTs: endTs - minutes * 60, endTs, granularity: effectiveGranularity() };
  }
  function effectiveGranularity() {
    if (state.rangeId === 'custom') return state.customGranularity;
    return model().rangeFor(state.rangeId).minutes <= 60 ? 'minute' : 'hour';
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
      return await apiFetch(path, { timeoutMs, controller });
    } finally {
      if (state[slot] === controller) state[slot] = null;
      if (slot === 'request' && requestId !== state.requestId) return null;
    }
  }
  function ensureView() {
    if (state.view) return state.view;
    state.view = viewFeature().create({
      onSource: (source) => { state.source = source; if (source !== 'thermal') stopBurst(); load(false); },
      onRange: (rangeId) => { state.rangeId = rangeId; if (rangeId === 'custom') { viewFeature().setCustomValues(state.view, state.customDays, state.customGranularity); viewFeature().promptCustom(state.view); return; } load(false); },
      onCustom: (days, granularity) => {
        const parsedDays = Math.floor(Number(days));
        if (!Number.isFinite(parsedDays) || parsedDays < 1 || parsedDays > 7 || !['hour', 'minute'].includes(granularity)) { showToast('自定义范围请选择 1–7 天，并选择小时或分钟粒度'); return; }
        state.customDays = parsedDays; state.customGranularity = granularity; state.rangeId = 'custom'; load(false);
      },
      onCapture: async (button, duration) => {
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
      onRefresh: async (button) => { button.disabled = true; state.rankRefreshRequested = true; state.detailsDue = true; await load(true, true); button.disabled = false; },
      onExport: (button) => exportRange(button)
    });
    return state.view;
  }
  function updateView(details = false) {
    if (!state.view) return;
    const session = capture().getSession();
    const cached = state.cache.get(key());
    if (!cached) return;
    const refreshDetails = details || state.detailsDue || !state.lastDetailsAt || (Date.now() - state.lastDetailsAt) >= 120000;
    viewFeature().update(state.view, { source: state.source, rangeId: state.rangeId, stats: cached.stats, status: cached.status, summary: state.summary, ranking: state.ranking, details: refreshDetails, capture: { session } });
    if (refreshDetails) { state.detailsDue = false; state.lastDetailsAt = Date.now(); }
  }
  function normalizeResponse(data, bounds) {
    const source = state.source;
    const windowMeta = data?.window || {};
    const sourceMeta = data?.meta || data?.sources?.[source] || {};
    const meta = { ...windowMeta, ...sourceMeta };
    const options = { ...bounds, granularity: meta.granularity || bounds.granularity, quality: meta.quality || '' };
    const annotate = (stats) => {
      stats.backendSampleCount = Number.isFinite(Number(meta.raw_samples ?? meta.samples ?? meta.sample_count)) ? Number(meta.raw_samples ?? meta.samples ?? meta.sample_count) : null;
      stats.backendValidSamples = Number.isFinite(Number(meta.valid_samples)) ? Number(meta.valid_samples) : null;
      stats.backendInvalidSamples = Number.isFinite(Number(meta.invalid_samples)) ? Number(meta.invalid_samples) : null;
      stats.backendGapCount = Number.isFinite(Number(meta.gap_count ?? meta.gaps)) ? Number(meta.gap_count ?? meta.gaps) : null;
      const coverage = Number(meta.coverage_ratio ?? meta.coverage);
      stats.backendCoverageRatio = Number.isFinite(coverage) ? (coverage > 1 ? coverage / 100 : coverage) : null;
      stats.backendQuality = String(meta.quality || '');
      stats.dataRevision = String(data?.data_revision ?? data?.history_revision ?? meta.data_revision ?? meta.history_revision ?? '');
      return stats;
    };
    if (source === 'thermal') {
      const points = model().clip(model().normalizeThermal(data), bounds.startTs, bounds.endTs);
      const stats = model().temperatureStats(points, options);
      return { stats: annotate(stats), status: stats.count < 2 ? '温度记录不足；亮屏采样才会写入温度历史。' : '' };
    }
    const points = model().clip(model().normalizePower(data), bounds.startTs, bounds.endTs);
    const stats = model().powerStats(points, options);
    return { stats: annotate(stats), status: stats.count < 2 || !stats.series.length ? '当前区间没有足够的有效放电数据；缺测不会补零。' : '' };
  }
  async function fetchSource(bounds) {
    const params = { action: 'history' };
    if (bounds.startTs !== null && Number.isFinite(Number(bounds.startTs))) params.start_ts = Math.floor(bounds.startTs);
    if (bounds.endTs !== null && Number.isFinite(Number(bounds.endTs))) params.end_ts = Math.floor(bounds.endTs);
    // The main history sheet represents the entire selected time range. A
    // recent manual capture must not hide service history from the same range.
    return capture().history({ startTs: params.start_ts, endTs: params.end_ts, granularity: bounds.granularity });
  }
  function rankKey(bounds, stats) {
    const windowId = state.rangeId === 'custom' ? `custom-${state.customDays}d` : `range-${state.rangeId}`;
    const step = bounds.granularity === 'hour' ? 3600 : bounds.granularity === 'minute' ? 60 : 1;
    const start = Math.floor(Number(bounds.startTs) / step) * step;
    const end = Math.floor(Number(bounds.endTs) / step) * step;
    return `${windowId}|${start}|${end}|${bounds.granularity || 'raw'}`;
  }
  function rankWindow(bounds, stats) {
    const windowLabel = state.rangeId === 'custom' ? `最近 ${state.customDays} 天` : model().rangeFor(state.rangeId).label;
    const ratio = Number.isFinite(Number(stats?.backendCoverageRatio)) ? Number(stats.backendCoverageRatio) * 100 : stats?.coveragePct;
    return { label: windowLabel, granularity: bounds.granularity, coveragePct: ratio, validSamples: stats?.backendValidSamples ?? stats?.validCount ?? stats?.count };
  }
  async function fetchEnergySummary(bounds, stats, forceRank = false, contextKey = state.activeKey) {
    if (state.source !== 'power') return;
    try {
      const fast = await request(API.energyFast, 4000, 'overviewRequest');
      if (!state.open || !isActive() || state.activeKey !== contextKey || state.source !== 'power') return;
      if (fast) { state.summary = fast; updateView(); }
    } catch (_) {
      // The real-time card remains usable when the fast summary is unavailable.
    }
    const cacheKey = rankKey(bounds, stats);
    const cached = state.rankCache.get(cacheKey);
    const window = rankWindow(bounds, stats);
    if (!state.open || !isActive() || state.activeKey !== contextKey || state.source !== 'power') return;
    if (!forceRank && cached) {
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
      if (!state.open || !isActive() || generation !== state.rankGeneration || state.source !== 'power' || !full) return;
      if (full.ok !== true) throw new Error(full.error || full.reason || '后台未返回有效排行');
      const rankCoverage = Number(full.coverage_ratio);
      const rankMeta = { label: `${new Date(bounds.startTs * 1000).toLocaleString()} — ${new Date(bounds.endTs * 1000).toLocaleString()}`, granularity: bounds.granularity, coveragePct: Number.isFinite(rankCoverage) ? (rankCoverage > 1 ? rankCoverage : rankCoverage * 100) : null, validSamples: full.valid_samples ?? null, gapCount: Array.isArray(full.gaps) ? full.gaps.length : null };
      const result = { status: full.status || 'ready', summary: full, window: rankMeta, cacheKey, updatedAt: Number(full.updated_at) > 0 ? Number(full.updated_at) * 1000 : Date.now(), revision: String(full.data_revision || '') };
      state.rankCache.set(cacheKey, result);
      state.ranking = result;
      updateView();
    } catch (err) {
      if (!state.open || !isActive() || generation !== state.rankGeneration || state.source !== 'power') return;
      state.ranking = { status: 'error', error: err?.message || String(err), window, cacheKey };
      updateView();
    }
  }
  async function load(force = false, forceRank = false) {
    if (!state.open || !isActive()) return;
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
    const bounds = state.selectedBounds;
    cancelSlot('request', 'new-history'); capture().abort('new-history'); state.requestId += 1; const requestId = state.requestId;
    const requestedRank = forceRank || state.rankRefreshRequested || selectionChanged;
    state.rankRefreshRequested = false;
    if (!force && state.cache.has(cacheKey)) {
      updateView();
      if (state.source === 'power') {
        fetchEnergySummary(bounds, state.cache.get(cacheKey).stats, requestedRank, cacheKey);
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
      schedule(); return;
    }
    if (!state.cache.has(cacheKey)) viewFeature().loading(view, state.source, state.rangeId);
    try {
      const data = await fetchSource(bounds); if (requestId !== state.requestId || !data) return;
      const normalized = normalizeResponse(data, bounds);
      state.cache.set(cacheKey, normalized); updateView();
      if (normalized.stats.count < 2) viewFeature().empty(view, state.source, state.rangeId, normalized.status);
      if (state.source === 'power') fetchEnergySummary(bounds, normalized.stats, requestedRank, cacheKey);
      if (state.source === 'power') {
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
      if (requestId !== state.requestId) return;
      viewFeature().error(view, state.source, state.rangeId, `读取失败：${err.message || err}`);
    }
    schedule();
  }
  function schedule(delay = state.source === 'thermal' ? 10000 : 30000) {
    if (state.timer) clearTimeout(state.timer); state.timer = null;
    if (!state.open || !isActive()) return;
    state.timer = window.setTimeout(() => { state.timer = null; load(true); }, delay);
  }
  async function exportRange(button) {
    button.disabled = true;
    try {
      const session = capture().getSession();
      if (session?.status === 'running' || session?.status === 'completed' || session?.status === 'stopped') {
        const data = await capture().export(session.id); showToast(data?.directory ? '记录已导出' : '导出已提交');
      } else if (state.rangeId !== 'custom') {
        const data = await apiFetch(API.historyExport, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'export', minutes: model().rangeFor(state.rangeId).minutes }), timeoutMs: 10000 });
        if (data?.ok) { showToast(`已保存 ${data.power_samples || 0} 个功耗点 / ${data.thermal_samples || 0} 个温度点`); appendLog('历史导出已保存（含温度）', 'ok'); }
      } else showToast('自定义区间请先开始一段记录，再导出完整文件');
    } catch (err) { showToast(`导出失败：${err.message || err}`); appendLog(String(err), 'err'); }
    button.disabled = false;
  }
  async function triggerBurst(options = {}) {
    if (!state.open || state.source !== 'thermal') return false;
    if (!requireFeature('auth').hasToken()) return false;
    try { await apiFetch(API.thermalBurst, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'start', duration_sec: 300 }), timeoutMs: 4000 }); return true; } catch (_) { return false; }
  }
  function stopBurst() { if (!requireFeature('auth').hasToken()) return; apiFetch(API.thermalBurst, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'stop' }), timeoutMs: 2500, keepalive: true }).catch(() => {}); }
  function open(source = 'thermal') {
    init();
    abort('analytics-open'); state.open = true; state.suspended = false; state.source = source; state.summary = null; state.detailsDue = true; const view = ensureView();
    refs.detailTitle.textContent = source === 'thermal' ? '温度与功耗历史' : '功耗与温度历史';
    refs.detailModal.classList.remove('energy-mode', 'history-mode', 'detail-minimized'); refs.detailModal.classList.add('analytics-mode', 'open');
    refs.detailMinimizeBtn?.setAttribute('aria-expanded', 'true');
    refs.detailMinimizeBtn?.setAttribute('aria-label', '缩小详情');
    requireFeature('ui').pushModalState('detail');
    const previousScroll = refs.detailBody.scrollTop; refs.detailBody.replaceChildren(view.root); refs.detailBody.scrollTop = previousScroll;
    if (source === 'thermal') triggerBurst({ prompt: false }); else stopBurst(); load(true);
  }
  function stop() { const active = state.open; state.open = false; state.suspended = true; abort('analytics-closed'); if (active) stopBurst(); }
  function suspend(reason) { if (state.suspended) return; state.suspended = true; abort(reason); if (state.open) stopBurst(); }
  function pause() { suspend('page-hidden'); }
  function minimize() { suspend('analytics-minimized'); }
  function resume() {
    if (!state.open || !isActive() || (!state.suspended && (state.request || state.overviewRequest || state.rankRequest || state.timer))) return;
    state.suspended = false;
    if (state.source === 'thermal') triggerBurst({ prompt: false });
    load(false);
  }
  function init() {
    if (state.observer || !refs.detailModal) return;
    document.addEventListener('webui-theme-changed', () => { if (state.open && isActive()) updateView(); });
    state.observer = new MutationObserver(() => { if (!state.open) return; if (refs.detailModal.classList.contains('detail-minimized')) minimize(); else if (isActive() && !state.request && !state.overviewRequest && !state.rankRequest && !state.timer) resume(); });
    state.observer.observe(refs.detailModal, { attributes: true, attributeFilter: ['class'] });
  }
  registerFeature('analytics', { init, open, stop, pause, minimize, resume, triggerBurst, schedule, isActive: () => state.open && isActive(), getState: () => ({ ...state, cache: undefined }) });
})();
