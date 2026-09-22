// DOM 引用、弹窗与前台刷新生命周期功能。
'use strict';
(() => {
const state = {
  rebootContext: 'thermal', modalRecords: new Map(), modalStack: [],
  modalObserver: null, resizeObserver: null, detailSession: 0,
  historyBacks: 0, deferredHistoryModal: '', handlingPopState: false, layoutFrame: 0
};

function $(id){ return document.getElementById(id); }

function initRefs() {
  refs.topbarSubtitle = $('topbar-subtitle');
  refs.topbarKicker = $('topbar-kicker');
  refs.topbarProfileChip = $('topbar-profile-chip');
  refs.topbarThermalChip = $('topbar-thermal-chip');
  refs.topbarThemeChip = $('topbar-theme-chip');
  refs.themeBtnIcon = $('theme-btn-icon');
  refs.hero = $('hero');
  refs.heroIcon = $('hero-icon');
  refs.heroMode = $('hero-mode');
  refs.heroDesc = $('hero-desc');
  refs.homeModBadge = $('home-mod-badge');
  refs.homeTempNum = $('home-temp-num');
  refs.homeTempStatus = $('home-temp-status');
  refs.homeSensorList = $('home-sensor-list');
  refs.homeThermalSkel = $('home-thermal-skel');
  refs.homeThermalContent = $('home-thermal-content');
  refs.homeCpuRows = $('home-cpu-rows');
  refs.rtZramUsage = $('rt-zram-usage');
  refs.rtRatio = $('rt-ratio');
  refs.rtWebuiMem = $('rt-webui-mem');
  refs.rtMemAvail = $('rt-mem-avail');
  refs.rtMemTotal = $('rt-mem-total');
  refs.rtSwapFree = $('rt-swap-free');
  refs.rtUptime = $('rt-uptime');
  refs.infoModel = $('info-model');
  refs.infoAndroid = $('info-android');
  refs.infoKernel = $('info-kernel');
  refs.infoModule = $('info-module');
  refs.logCard = $('log-card');
  refs.logInner = $('log-inner');
  refs.logToggle = $('log-toggle');
  refs.logPreview = $('log-preview');
  refs.logMeta = $('log-meta');
  refs.logClearBtn = $('log-clear-btn');
  refs.perfCurrentName = $('perf-current-name');
  refs.perfCurrentDesc = $('perf-current-desc');
  refs.perfPolicyDesc = $('perf-policy-desc');
  refs.profilePolicyManualBtn = $('profile-policy-manual-btn');
  refs.profilePolicyAutoBtn = $('profile-policy-auto-btn');
  refs.externalSchedulerControls = $('external-scheduler-controls');
  refs.schedOwnerRow = $('sched-owner-row');
  refs.schedOwnerLabel = $('sched-owner-label');
  refs.schedOwnerToggleBtn = $('sched-owner-toggle-btn');
  refs.schedOwnerToggleLabel = $('sched-owner-toggle-label');
  refs.gameHandoffRow = $('game-handoff-row');
  refs.gameHandoffLabel = $('game-handoff-label');
  refs.gameHandoffToggleBtn = $('game-handoff-toggle-btn');
  refs.gameHandoffToggleLabel = $('game-handoff-toggle-label');
  refs.ownerArbiterRow = $('owner-arbiter-row');
  refs.ownerArbiterLabel = $('owner-arbiter-label');
  refs.ownerArbiterTickBtn = $('owner-arbiter-tick-btn');
  refs.ownerArbiterTickLabel = $('owner-arbiter-tick-label');
  refs.externalSchedulerHelp = $('external-scheduler-help');
  refs.cpuRows = $('cpu-rows');
  refs.profileList = $('profile-list');
  refs.thermalCurrentName = $('thermal-current-name');
  refs.thermalCurrentDesc = $('thermal-current-desc');
  refs.thModBadge = $('th-mod-badge');
  refs.thermalSkel = $('thermal-skel');
  refs.thermalContent = $('thermal-content');
  refs.tempNum = $('temp-num');
  refs.tempZone = $('temp-zone');
  refs.tempStatus = $('temp-status');
  refs.tempFill = $('temp-fill');
  refs.sensorGrid = $('sensor-grid');
  refs.thermalList = $('thermal-list');
  refs.mkStock = $('mk-stock');
  refs.mkStockLbl = $('mk-stock-lbl');
  refs.mkMod = $('mk-mod');
  refs.mkModLbl = $('mk-mod-lbl');
  refs.swapDesc = $('swap-desc');
  refs.swapToggleLabel = $('swap-toggle-label');
  refs.swapRows = $('swap-rows');
  refs.swapTuneModal = $('modal-swap-tune');
  refs.swapZramSizeNumber = $('swap-zram-size-number');
  refs.swapZramSizeApply = $('swap-zram-size-apply-btn');
  refs.swapTuneInputs = {
    swappiness: $('swap-input-swappiness'),
    min_free_kbytes: $('swap-input-minfree'),
    watermark_scale_factor: $('swap-input-watermark'),
    vfs_cache_pressure: $('swap-input-vfs')
  };
  refs.swapTuneNumbers = {
    swappiness: $('swap-number-swappiness'),
    min_free_kbytes: $('swap-number-minfree'),
    watermark_scale_factor: $('swap-number-watermark'),
    vfs_cache_pressure: $('swap-number-vfs')
  };
  refs.swapTuneValues = {
    swappiness: $('swap-value-swappiness'),
    min_free_kbytes: $('swap-value-minfree'),
    watermark_scale_factor: $('swap-value-watermark'),
    vfs_cache_pressure: $('swap-value-vfs')
  };
  refs.nrSwitchDesc = $('nr-switch-desc');
  refs.sim2AutoDesc = $('sim2-auto-desc');
  refs.sim2AutoToggleBtn = $('sim2-auto-toggle-btn');
  refs.sim2AutoToggleLabel = $('sim2-auto-toggle-label');
  refs.sim2AutoRows = $('sim2-auto-rows');
  refs.idleIsolateDesc = $('idle-isolate-desc');
  refs.idleIsolateToggleBtn = $('idle-isolate-toggle-btn');
  refs.idleIsolateToggleLabel = $('idle-isolate-toggle-label');
  refs.idleIsolateRows = $('idle-isolate-rows');
  refs.standbyDiagRows = $('standby-diag-rows');
  refs.bgRestrictDesc = $('bg-restrict-desc');
  refs.bgRestrictToggleBtn = $('bg-restrict-toggle-btn');
  refs.bgRestrictToggleLabel = $('bg-restrict-toggle-label');
  refs.bgRestrictRows = $('bg-restrict-rows');
  refs.bgRestrictAddBtn = $('bg-restrict-add-btn');
  refs.bgRestrictPkgInput = $('bg-restrict-pkg-input');
  refs.bgRestrictPkgSuggestions = $('bg-restrict-pkg-suggestions');
  refs.bgRestrictPkgHint = $('bg-restrict-pkg-hint');
  refs.bgRestrictPolicySelect = $('bg-restrict-policy-select');
  refs.bgRestrictDelaySelect = $('bg-restrict-delay-select');
  refs.nrSwitchToggleLabel = $('nr-switch-toggle-label');
  refs.nrSwitchRows = $('nr-switch-rows');
  refs.uecapDesc = $('uecap-desc');
  refs.uecapBtnGroup = $('uecap-btn-group');
  refs.uecapRows = $('uecap-rows');
  refs.basebandCard = $('baseband-card');
  refs.basebandDesc = $('baseband-desc');
  refs.basebandRows = $('baseband-rows');
  refs.ntpDesc = $('ntp-desc');
  refs.ntpSyncLabel = $('ntp-sync-label');
  refs.ntpServerList = $('ntp-server-list');
  refs.ntpInfoRows = $('ntp-info-rows');
  refs.themeModal = $('modal-theme');
  refs.themeChoices = Array.from(document.querySelectorAll('[data-theme-option]'));
  refs.rebootModal = $('modal-reboot');
  refs.rebootModalTitle = $('reboot-modal-title');
  refs.rebootModalDesc = $('reboot-modal-desc');
  refs.rebootCancelError = $('reboot-cancel-error');
  refs.rebootNowBtn = $('reboot-now-btn');
  refs.rebootLaterBtn = $('reboot-later-btn');
  refs.rebootCloseBtn = $('reboot-close-x');
  refs.rebootCancelBtn = $('reboot-cancel-btn');
  refs.schedulerHealthRow = $('scheduler-health-row');
  refs.schedulerHealthLabel = $('scheduler-health-label');
  refs.schedulerRetryBtn = $('scheduler-retry-btn');
  refs.schedulerRetryLabel = $('scheduler-retry-label');
  refs.detailModal = $('modal-detail');
  refs.detailTitle = $('detail-title');
  refs.detailBody = $('detail-body');
  refs.detailMinimizeBtn = $('detail-minimize-btn');
  refs.toastWrap = $('toast-wrap');
  refs.pullInd = $('pull-ind');
  refs.pullText = $('pull-text');
  refs.tabPages = $('tab-pages');
  refs.topbar = document.querySelector('.topbar');
  initializeModalLifecycle();
}

function setStaticHtml(target, html) {
  // Trusted project markup only. Escape every runtime/API value before it is
  // interpolated, or build the node with textContent instead.
  const doc = new DOMParser().parseFromString(String(html || ''), 'text/html');
  target.replaceChildren(...Array.from(doc.body.childNodes).map((node) => document.importNode(node, true)));
}

function invalidateDetailSession() {
  state.detailSession += 1;
  document.dispatchEvent(new CustomEvent('pixel:detail-session', { detail: { session: state.detailSession } }));
}

function activeModalRecord() {
  return [...state.modalStack].reverse().map((name) => state.modalRecords.get(name))
    .find((record) => record.el.classList.contains('open') && !record.el.classList.contains('detail-minimized'));
}

function focusElement(element) {
  if (!element?.isConnected || element.closest('[inert]')) return false;
  if (!element.getClientRects().length) return false;
  element.focus({ preventScroll: true });
  return document.activeElement === element;
}

function focusModal(record) {
  const title = record.el.querySelector('.modal-s-title');
  if (title) title.tabIndex = -1;
  if (!focusElement(title)) focusElement(record.el);
}

function restoreModalFocus(record) {
  if (focusElement(record.returnFocus)) return;
  const active = activeModalRecord();
  if (active) focusModal(active);
  else focusElement(document.querySelector('.nav-item.active, .nav-btn.active, #theme-open-btn'));
}

function updateOverlayLayout() {
  state.layoutFrame = 0;
  const root = document.documentElement;
  const nav = document.querySelector('.bottom-nav');
  const navHeight = nav ? Math.ceil(nav.getBoundingClientRect().height) : 0;
  const dock = refs.detailModal?.classList.contains('open') && refs.detailModal.classList.contains('detail-minimized');
  const dockSheet = dock ? refs.detailModal.querySelector('.modal-sheet') : null;
  const dockHeight = dockSheet ? Math.ceil(dockSheet.getBoundingClientRect().height) : 0;
  root.style.setProperty('--bottom-nav-occupied', `${navHeight}px`);
  root.style.setProperty('--bottom-nav-height', `${navHeight}px`);
  root.style.setProperty('--detail-dock-height', `${dockHeight}px`);
  root.style.setProperty('--detail-dock-occupied', dockHeight ? `${dockHeight + 12}px` : '0px');
  const footer = activeModalRecord()?.el.querySelector('.modal-sheet > .modal-actions');
  root.style.setProperty('--modal-footer-occupied', `${footer ? Math.ceil(footer.getBoundingClientRect().height) : 0}px`);
  const viewport = window.visualViewport;
  const keyboardInset = viewport ? Math.max(0, window.innerHeight - viewport.height - viewport.offsetTop) : 0;
  root.style.setProperty('--keyboard-inset', `${Math.round(keyboardInset)}px`);
}

function requestOverlayLayout() {
  if (!state.layoutFrame) state.layoutFrame = window.requestAnimationFrame(updateOverlayLayout);
}

// One coordinator also covers feature entry points that add .open directly.
// Inert takes effect immediately; CSS exit animation is never a lifecycle gate.
function syncModalState() {
  let restore = null;
  let focus = null;
  state.modalRecords.forEach((record, name) => {
    const opened = record.el.classList.contains('open');
    const minimized = opened && record.el.classList.contains('detail-minimized');
    if (opened && !record.opened) {
      record.returnFocus = document.activeElement;
      state.modalStack = state.modalStack.filter((item) => item !== name);
      state.modalStack.push(name);
      focus = record;
    } else if (!opened && record.opened) {
      state.modalStack = state.modalStack.filter((item) => item !== name);
      restore = record;
      if (name === 'detail') invalidateDetailSession();
    } else if (opened && minimized !== record.minimized) {
      if (minimized) restore = record;
      else focus = record;
    }
    record.opened = opened;
    record.minimized = minimized;
  });
  const active = activeModalRecord();
  const shell = document.querySelector('.app-shell');
  if (shell) shell.inert = Boolean(active);
  document.body.classList.toggle('has-modal', Boolean(active));
  state.modalRecords.forEach((record) => {
    const exposed = record.opened && (!active || record === active);
    record.el.inert = !exposed;
    record.el.setAttribute('role', record.minimized ? 'region' : 'dialog');
    if (record === active) record.el.setAttribute('aria-modal', 'true');
    else record.el.removeAttribute('aria-modal');
    record.el.style.zIndex = record === active ? 'var(--z-modal, 150)' : record.minimized ? 'var(--z-dock, 110)' : '';
    if (record.name === 'detail') {
      record.el.querySelectorAll('.modal-sheet-body, .modal-actions').forEach((body) => { body.inert = record.minimized; });
    }
  });
  if (focus && focus === active) focusModal(focus);
  else if (restore) restoreModalFocus(restore);
  state.modalRecords.forEach((record) => record.el.setAttribute('aria-hidden', String(record.el.inert)));
  updateOverlayLayout();
}

function closeTopModal() {
  const record = activeModalRecord() || state.modalRecords.get(state.modalStack.at(-1));
  if (!record) return false;
  let closed = true;
  if (record.name === 'detail') closeDetailModal();
  else if (record.name === 'theme') closeThemeSheet();
  else if (record.name === 'reboot') closed = closeRebootModal();
  else if (record.name === 'swapTune') requireFeature('memory').closeSwapTuneModal();
  if (!closed) return false;
  syncModalState();
  return true;
}

function handlePopState() {
  if (state.historyBacks > 0) {
    state.historyBacks -= 1;
    if (!state.historyBacks && state.deferredHistoryModal) {
      const name = state.deferredHistoryModal;
      state.deferredHistoryModal = '';
      if (state.modalRecords.get(name)?.opened) history.pushState({ modal: name }, '');
    }
    return;
  }
  const active = activeModalRecord();
  if (active?.name === 'reboot' && state.rebootContext === 'thermal'
    && requireFeature('thermal').isCancelBusy?.()) {
    // Do not let Back dismiss a modal while the cancellation transaction is
    // in flight. Restore the history entry so a late response can be retried.
    history.pushState({ modal: 'reboot' }, '');
    return;
  }
  state.handlingPopState = true;
  try { closeTopModal(); } finally { state.handlingPopState = false; }
}

function handleModalKeydown(event) {
  if (event.key === 'Escape') {
    if (closeTopModal()) { event.preventDefault(); event.stopPropagation(); }
    return;
  }
  const active = activeModalRecord();
  if (event.key !== 'Tab' || !active) return;
  const focusable = [...active.el.querySelectorAll('button, a[href], input, select, textarea, summary, [tabindex]')]
    .filter((el) => !el.disabled && el.tabIndex >= 0 && !el.closest('[inert]')
      && el.getClientRects().length && getComputedStyle(el).visibility !== 'hidden');
  if (!focusable.length) { event.preventDefault(); focusModal(active); return; }
  const index = focusable.indexOf(document.activeElement);
  if (index < 0 || (!event.shiftKey && index === focusable.length - 1) || (event.shiftKey && index === 0)) {
    event.preventDefault();
    focusElement(event.shiftKey ? focusable.at(-1) : focusable[0]);
  }
}

function initializeModalLifecycle() {
  if (state.modalObserver) return;
  [['theme', refs.themeModal], ['reboot', refs.rebootModal], ['detail', refs.detailModal], ['swapTune', refs.swapTuneModal]]
    .forEach(([name, el]) => {
      if (!el) return;
      el.tabIndex = -1;
      state.modalRecords.set(name, { name, el, opened: false, minimized: false, returnFocus: null });
    });
  state.modalObserver = new MutationObserver(syncModalState);
  state.modalRecords.forEach(({ el }) => state.modalObserver.observe(el, { attributes: true, attributeFilter: ['class'] }));
  if (typeof ResizeObserver === 'function') {
    state.resizeObserver = new ResizeObserver(requestOverlayLayout);
    [document.querySelector('.bottom-nav'), ...document.querySelectorAll('.modal-sheet, .modal-sheet > .modal-actions')]
      .filter(Boolean).forEach((el) => state.resizeObserver.observe(el));
  }
  document.addEventListener('keydown', handleModalKeydown);
  document.addEventListener('focusin', (event) => {
    const active = activeModalRecord();
    if (active && !active.el.contains(event.target)) focusModal(active);
  });
  window.addEventListener('resize', requestOverlayLayout, { passive: true });
  window.visualViewport?.addEventListener('resize', requestOverlayLayout, { passive: true });
  window.visualViewport?.addEventListener('scroll', requestOverlayLayout, { passive: true });
  syncModalState();
}

function pushModalState(name) {
  if (name === 'detail') invalidateDetailSession();
  if (state.historyBacks) state.deferredHistoryModal = name;
  else if (history.state?.modal !== name) history.pushState({ modal: name }, '');
  syncModalState();
  const record = state.modalRecords.get(name);
  if (record && record === activeModalRecord()) focusModal(record);
}

function popModalIfTop(name) {
  syncModalState();
  if (state.deferredHistoryModal === name) state.deferredHistoryModal = '';
  if (!state.handlingPopState && history.state?.modal === name && !state.historyBacks) {
    state.historyBacks += 1;
    history.back();
  }
}

function openThemeSheet(){
  refs.themeModal.classList.add('open');
  pushModalState('theme');
  const core = requireFeature('core');
  core.queueNextPoll(core.computeNextPollDelay());
}
function closeThemeSheet(){
  refs.themeModal.classList.remove('open');
  popModalIfTop('theme');
  requireFeature('core').queueNextPoll(POLL_MIN_DELAY_MS);
}

function setRebootBusy(busy) {
  const disabled = Boolean(busy);
  [refs.rebootNowBtn, refs.rebootLaterBtn, refs.rebootCloseBtn, refs.rebootCancelBtn]
    .filter(Boolean).forEach((button) => { button.disabled = disabled; });
  refs.rebootModal?.classList.toggle('cancel-pending', disabled);
}

function setRebootError(message = '') {
  if (!refs.rebootCancelError) return;
  refs.rebootCancelError.textContent = String(message || '');
  refs.rebootCancelError.hidden = !message;
}

function openRebootModal(pending, prev, context = 'thermal') {
  state.rebootContext = context;
  if (context === 'thermal') requireFeature('thermal').setPendingChange(pending, prev);
  setRebootBusy(false);
  setRebootError('');
  if (context === 'scheduler') {
    const target = requireFeature('profile').getSchedulerBootTargetMode() === 'ugt' ? 'UGT 日常调度模式' : 'Pixel 调度模式';
    refs.rebootModalTitle.textContent = `切换到${target}`;
    refs.rebootModalDesc.textContent = `启动状态已提交。重启后才会进入${target}并完成最终验证。`;
  } else {
    refs.rebootModalTitle.textContent = '温控策略等待重启';
    refs.rebootModalDesc.textContent = '温控策略已保存；当前 overlay 需要在重启后完成最终切换和复读。';
  }
  refs.rebootModal.classList.add('open');
  pushModalState('reboot');
  const core = requireFeature('core');
  core.queueNextPoll(core.computeNextPollDelay());
}

function closeRebootModal(message = '', options = {}) {
  const normalizedMessage = typeof message === 'string' ? message : '';
  const normalizedOptions = options && typeof options === 'object' ? options : {};
  if (!normalizedOptions.force && state.rebootContext === 'thermal'
    && requireFeature('thermal').isCancelBusy?.()) return false;
  refs.rebootModal.classList.remove('open');
  popModalIfTop('reboot');
  const core = requireFeature('core');
  core.queueNextPoll(POLL_MIN_DELAY_MS);
  setRebootBusy(false);
  setRebootError('');
  if (!normalizedOptions.silent) {
    core.showToast(normalizedMessage || (state.rebootContext === 'scheduler' ? '切换已提交，重启后验证' : '策略已保存，重启后验证'));
  }
  return true;
}

function openDetail(title, html) {
  requireFeature('analytics').stop();
  refs.detailModal.classList.remove('energy-mode');
  refs.detailModal.classList.remove('history-mode');
  refs.detailModal.classList.remove('analytics-mode');
  refs.detailModal.classList.remove('detail-minimized');
  refs.detailMinimizeBtn?.setAttribute('aria-expanded', 'true');
  refs.detailMinimizeBtn?.setAttribute('aria-label', '缩小详情');
  refs.detailTitle.textContent = title;
  setStaticHtml(refs.detailBody, html);
  refs.detailModal.classList.add('open');
  pushModalState('detail');
  const core = requireFeature('core');
  core.queueNextPoll(core.computeNextPollDelay());
}

function toggleDetailMinimized() {
  if (!refs.detailModal.classList.contains('energy-mode') && !refs.detailModal.classList.contains('history-mode') && !refs.detailModal.classList.contains('analytics-mode')) return;
  const minimized = refs.detailModal.classList.toggle('detail-minimized');
  refs.detailMinimizeBtn?.setAttribute('aria-expanded', String(!minimized));
  refs.detailMinimizeBtn?.setAttribute('aria-label', minimized ? '展开详情' : '缩小详情');
  if (minimized) requireFeature('analytics').minimize();
  syncModalState();
  if (!minimized) requireFeature('analytics').resume();
  requireFeature('core').showToast(minimized ? '详情已缩小，刷新已暂停' : '详情已展开', 1800);
}

function closeDetailModal(){
  requireFeature('analytics').stop();
  refs.detailModal.classList.remove('open');
  refs.detailModal.classList.remove('energy-mode');
  refs.detailModal.classList.remove('history-mode');
  refs.detailModal.classList.remove('analytics-mode');
  refs.detailModal.classList.remove('detail-minimized');
  refs.detailMinimizeBtn?.setAttribute('aria-expanded', 'true');
  refs.detailMinimizeBtn?.setAttribute('aria-label', '缩小详情');
  popModalIfTop('detail');
  requireFeature('core').queueNextPoll(POLL_MIN_DELAY_MS);
}

// 仅夹取 [min,max] 并取整, 不吸附 step —— 预设/手输需保留 27386 等非整步原厂值;
// step 吸附交给滑块 (<input type=range step>) 的原生行为
function stopTempChartRefresh() {
  requireFeature('thermal').stopChart();
}

function pauseTempChartRefresh() {
  requireFeature('thermal').pauseChart();
}

function stopEnergyDetailRefresh() {
  requireFeature('energy').stop();
}

function pauseEnergyDetailRefresh() {
  requireFeature('energy').pause();
}

function scheduleTempChartRefresh(delay = TEMP_CHART_REFRESH_MS) {
  requireFeature('thermal').scheduleChart(delay);
}

registerFeature('ui', {
  initialize: initRefs,
  pauseTemperature: pauseTempChartRefresh,
  pauseEnergy: pauseEnergyDetailRefresh,
  getElement: $,
  setStaticHtml,
  pushModalState,
  popModalIfTop,
  handlePopState,
  syncModalState,
  updateOverlayLayout,
  getDetailSession: () => state.detailSession,
  isDetailSessionActive: (session) => session === state.detailSession && refs.detailModal?.classList.contains('open'),
  openThemeSheet,
  closeThemeSheet,
  openRebootModal,
  closeRebootModal,
  setRebootBusy,
  setRebootError,
  openDetail,
  toggleDetailMinimized,
  closeDetailModal,
  stopTemperature: stopTempChartRefresh,
  stopEnergy: stopEnergyDetailRefresh,
  scheduleTemperature: scheduleTempChartRefresh,
  getRebootContext: () => state.rebootContext
});
})();
