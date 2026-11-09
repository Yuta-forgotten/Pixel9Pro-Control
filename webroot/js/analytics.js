'use strict';
(() => {
  const state = {
    open: false,
    suspended: false,
    sensor: 'module',
    rangeId: '30',
    customSeconds: 86400,
    view: null,
    request: null,
    requestId: 0,
    timer: null,
    observer: null,
    payload: null
  };

  const core = () => requireFeature('core');
  const model = () => requireFeature('analyticsModel');
  const viewFeature = () => requireFeature('analyticsView');
  const apiFetch = (...args) => core().apiFetch(...args);
  const cancelled = (error) => core().isRequestCancelled?.(error) === true;
  const isActive = () => core().isWebUiActive() && refs.detailModal?.classList.contains('open') && !refs.detailModal.classList.contains('detail-minimized');

  function rangeBounds() {
    const endTs = Math.floor(Date.now() / 1000);
    const seconds = state.rangeId === 'custom'
      ? state.customSeconds
      : model().rangeFor(state.rangeId).minutes * 60;
    return { startTs: endTs - seconds, endTs };
  }

  function historyUrl(bounds) {
    const path = API.thermalHistory || '/cgi-bin/thermal.sh?history=1';
    const separator = path.includes('?') ? '&' : '?';
    const params = new URLSearchParams({
      sensor: state.sensor,
      start_ts: String(bounds.startTs),
      end_ts: String(bounds.endTs)
    });
    return `${path}${separator}${params.toString()}`;
  }

  function cancelRequest(reason) {
    state.requestId += 1;
    state.request?.abort(reason);
    state.request = null;
  }

  function clearTimer() {
    if (state.timer) clearTimeout(state.timer);
    state.timer = null;
  }

  function ensureView() {
    if (state.view) return state.view;
    state.view = viewFeature().create({
      onSensor(sensor) {
        state.sensor = sensor;
        load();
      },
      onRange(rangeId) {
        if (rangeId === 'custom') {
          cancelRequest('thermal-history-custom');
          clearTimer();
          state.payload = null;
          state.view.exportButton.disabled = true;
          state.view.custom.hidden = false;
          state.view.customWindow.value = String(state.customSeconds);
          state.view.customWindow.focus();
          return;
        }
        state.rangeId = rangeId;
        load();
      },
      onCustom(seconds) {
        const value = Math.floor(Number(seconds));
        if (!Number.isFinite(value) || value < 14400 || value > 604800) return;
        state.customSeconds = value;
        state.rangeId = 'custom';
        load();
      },
      onRefresh(button) {
        button.disabled = true;
        load().finally(() => { button.disabled = false; });
      },
      onExport(format) {
        if (!state.payload || !isActive()) return;
        try {
          const file = model().exportHistory(state.payload, format);
          const url = URL.createObjectURL(new Blob([file.text], { type: file.mime }));
          const anchor = document.createElement('a');
          anchor.href = url;
          anchor.download = file.filename;
          document.body.appendChild(anchor);
          anchor.click();
          anchor.remove();
          setTimeout(() => URL.revokeObjectURL(url), 1000);
          core().showToast('所选传感器与时间范围的温度记录已导出');
        } catch (error) {
          core().showToast(`导出失败：${error.message || error}`);
        }
      }
    });
    return state.view;
  }

  function emptyStats(bounds) {
    return model().temperatureStats([], { ...bounds });
  }

  function schedule() {
    clearTimer();
    if (!state.open || state.suspended) return;
    state.timer = setTimeout(() => {
      state.timer = null;
      load();
    }, 60000);
  }

  async function load() {
    if (!state.open || state.suspended || !isActive()) return;
    cancelRequest('thermal-history-replaced');
    clearTimer();
    const requestId = state.requestId;
    const controller = new AbortController();
    state.request = controller;
    const bounds = rangeBounds();
    const view = ensureView();
    state.payload = null;
    viewFeature().loading(view, state.sensor, state.rangeId, emptyStats(bounds));

    try {
      const data = await apiFetch(historyUrl(bounds), {
        requestClass: 'thermalHistory',
        controller,
        priority: 'normal',
        scope: 'thermal.history.read'
      });
      if (requestId !== state.requestId || !state.open) return;
      if (!data || data.ok !== true || !Array.isArray(data.points) || data.sensor !== state.sensor) {
        throw new Error(data?.error || data?.reason || '温度历史数据无效');
      }
      const points = model().clip(
        model().normalizeThermal(data).filter((point) => point.sensor === state.sensor),
        bounds.startTs,
        bounds.endTs
      );
      const stats = model().temperatureStats(points, {
        ...bounds,
        backendSampleCount: data.raw_samples,
        backendValidSamples: data.valid_samples,
        backendGapCount: data.gap_count,
        backendQuality: data.quality
      });
      const sensorName = state.sensor === 'battery' ? '电池' : '机身';
      const historyStatus = stats.count === 0
        ? `所选时间范围内暂无${sensorName}温度记录`
        : (stats.gapCount > 0 ? `存在 ${stats.gapCount} 段记录间断` : '');
      const recordingStatus = data.recording_enabled === false
        ? '模块后台任务已关闭，温度记录已暂停。现有记录仍可查看和导出。'
        : data.recording_state === 'stopped' ? '温度记录任务未运行，当前显示已保存记录。'
          : data.recording_state === 'starting' ? '温度记录任务正在启动，当前显示已保存记录。' : '';
      const status = [recordingStatus, historyStatus].filter(Boolean).join(' ');
      state.payload = data;
      viewFeature().update(view, { sensor: state.sensor, rangeId: state.rangeId, stats, status, exportable: true });
    } catch (error) {
      if (!cancelled(error) && requestId === state.requestId) {
        viewFeature().error(view, state.sensor, state.rangeId, emptyStats(bounds), `温度历史读取失败：${error.message || error}`);
      }
    } finally {
      if (state.request === controller) state.request = null;
      if (requestId === state.requestId) schedule();
    }
  }

  function open() {
    init();
    cancelRequest('thermal-history-open');
    state.open = true;
    state.suspended = false;
    state.sensor = 'module';
    const view = ensureView();
    refs.detailTitle.textContent = '温度历史';
    refs.detailModal.classList.remove('energy-mode', 'history-mode', 'detail-minimized');
    refs.detailModal.classList.add('analytics-mode', 'open');
    refs.detailMinimizeBtn?.setAttribute('aria-expanded', 'true');
    refs.detailMinimizeBtn?.setAttribute('aria-label', '最小化详情');
    requireFeature('ui').pushModalState('detail');
    const previousScroll = refs.detailBody.scrollTop;
    refs.detailBody.replaceChildren(view.root);
    refs.detailBody.scrollTop = previousScroll;
    load();
  }

  function suspend(reason) {
    if (state.suspended) return;
    state.suspended = true;
    cancelRequest(reason);
    clearTimer();
  }

  function resume() {
    if (!state.open || !isActive() || !state.suspended) return;
    state.suspended = false;
    load();
  }

  function init() {
    if (state.observer || !refs.detailModal) return;
    state.observer = new MutationObserver(() => {
      if (!state.open) return;
      if (refs.detailModal.classList.contains('detail-minimized')) suspend('thermal-history-minimized');
      else if (isActive() && state.suspended) resume();
    });
    state.observer.observe(refs.detailModal, { attributes: true, attributeFilter: ['class'] });
  }

  function stop() {
    state.open = false;
    state.suspended = true;
    cancelRequest('thermal-history-closed');
    clearTimer();
  }

  registerFeature('analytics', {
    init,
    open,
    stop,
    pause: () => suspend('page-hidden'),
    minimize: () => suspend('thermal-history-minimized'),
    resume,
    isActive: () => state.open && isActive(),
    getState: () => ({ ...state, request: undefined, view: undefined, observer: undefined })
  });
})();
