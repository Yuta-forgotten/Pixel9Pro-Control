'use strict';
(() => {
  const state = {
    open: false, source: 'thermal', rangeId: '30', customDays: 1, customGranularity: 'hour',
    view: null, cache: new Map(), requestId: 0, request: null, timer: null,
    summary: null, observer: null
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
    return `${state.source}:${state.rangeId}:${state.customDays}:${state.customGranularity}`;
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
    return { startTs: endTs - minutes * 60, endTs, granularity: '' };
  }
  function abort(reason = 'analytics-replaced') {
    state.requestId += 1;
    if (state.request) state.request.abort(reason);
    state.request = null;
    capture().abort(reason);
    if (state.timer) { clearTimeout(state.timer); state.timer = null; }
  }
  async function request(path, timeoutMs = 8000) {
    const requestId = state.requestId;
    const controller = new AbortController();
    state.request = controller;
    try {
      return await apiFetch(path, { timeoutMs, controller });
    } finally {
      if (state.request === controller) state.request = null;
      if (requestId !== state.requestId) return null;
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
          await capture().status(); updateView();
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
      onExport: (button) => exportRange(button)
    });
    return state.view;
  }
  function updateView() {
    if (!state.view) return;
    const session = capture().getSession();
    const cached = state.cache.get(key());
    if (!cached) return;
    viewFeature().update(state.view, { source: state.source, rangeId: state.rangeId, stats: cached.stats, status: cached.status, summary: state.summary, capture: { session } });
  }
  function normalizeResponse(data, bounds) {
    const source = state.source;
    if (source === 'thermal') {
      const points = model().clip(model().normalizeThermal(data), bounds.startTs, bounds.endTs);
      return { stats: model().temperatureStats(points), status: points.length < 2 ? '温度记录不足；亮屏采样才会写入温度历史。' : '' };
    }
    const points = model().clip(model().normalizePower(data), bounds.startTs, bounds.endTs);
    return { stats: model().powerStats(points), status: points.length < 2 ? '功耗记录不足；电量百分比不会被当成功耗。' : '' };
  }
  async function fetchSource(bounds) {
    const params = { action: 'history' };
    if (bounds.startTs !== null && Number.isFinite(Number(bounds.startTs))) params.start_ts = Math.floor(bounds.startTs);
    if (bounds.endTs !== null && Number.isFinite(Number(bounds.endTs))) params.end_ts = Math.floor(bounds.endTs);
    const session = capture().getSession(); if (session?.id) params.session_id = session.id;
    return capture().history({ sessionId: params.session_id, startTs: params.start_ts, endTs: params.end_ts, granularity: bounds.granularity });
  }
  async function fetchEnergySummary() {
    if (state.source !== 'power') return;
    try {
      const fast = await request(API.energyFast, 4000); if (fast) { state.summary = fast; updateView(); }
      const full = await request(API.energy, 16000); if (full) { state.summary = full; updateView(); }
    } catch (_) { /* trend remains usable when system batterystats is slow */ }
  }
  async function load(force = false) {
    if (!state.open || !isActive()) return;
    const view = ensureView(); const bounds = rangeBounds(); const cacheKey = key();
    abort('new-range'); state.requestId += 1; const requestId = state.requestId;
    if (!force && state.cache.has(cacheKey)) { updateView(); schedule(); return; }
    if (!state.cache.has(cacheKey)) viewFeature().loading(view, state.source, state.rangeId);
    try {
      const data = await fetchSource(bounds); if (requestId !== state.requestId || !data) return;
      const normalized = normalizeResponse(data, bounds); state.cache.set(cacheKey, normalized); updateView();
      if (normalized.stats.count < 2) viewFeature().empty(view, state.source, state.rangeId, normalized.status);
      if (state.source === 'power') fetchEnergySummary();
      if (state.source === 'thermal') capture().status().catch(() => {}).then(() => updateView());
    } catch (err) {
      if (requestId !== state.requestId) return;
      viewFeature().error(view, state.source, state.rangeId, `读取失败：${err.message || err}`);
    }
    schedule();
  }
  function schedule(delay = 10000) {
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
    abort('analytics-open'); state.open = true; state.source = source; state.summary = null; const view = ensureView();
    refs.detailTitle.textContent = source === 'thermal' ? '温度与功耗历史' : '功耗与温度历史';
    refs.detailModal.classList.remove('energy-mode', 'history-mode'); refs.detailModal.classList.add('analytics-mode', 'open');
    requireFeature('ui').pushModalState('detail');
    const previousScroll = refs.detailBody.scrollTop; refs.detailBody.replaceChildren(view.root); refs.detailBody.scrollTop = previousScroll;
    if (source === 'thermal') triggerBurst({ prompt: false }); else stopBurst(); load(true);
  }
  function stop() { state.open = false; abort('analytics-closed'); stopBurst(); }
  function pause() { abort('page-hidden'); stopBurst(); }
  function minimize() { if (state.timer) { clearTimeout(state.timer); state.timer = null; } stopBurst(); }
  function resume() { if (!state.open || !isActive()) return; if (state.source === 'thermal') triggerBurst({ prompt: false }); load(false); }
  function init() {
    if (state.observer || !refs.detailModal) return;
    state.observer = new MutationObserver(() => { if (!state.open) return; if (refs.detailModal.classList.contains('detail-minimized')) minimize(); else if (isActive() && !state.request && !state.timer) resume(); });
    state.observer.observe(refs.detailModal, { attributes: true, attributeFilter: ['class'] });
  }
  registerFeature('analytics', { init, open, stop, pause, minimize, resume, triggerBurst, schedule, isActive: () => state.open && isActive(), getState: () => ({ ...state, cache: undefined }) });
})();
