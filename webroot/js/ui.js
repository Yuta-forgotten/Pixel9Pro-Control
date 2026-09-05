// DOM 引用、弹窗与前台刷新生命周期功能。
'use strict';
(() => {
const state = { rebootContext: 'thermal' };

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
  refs.schedulerHealthRow = $('scheduler-health-row');
  refs.schedulerHealthLabel = $('scheduler-health-label');
  refs.schedulerRetryBtn = $('scheduler-retry-btn');
  refs.schedulerRetryLabel = $('scheduler-retry-label');
  refs.detailModal = $('modal-detail');
  refs.detailTitle = $('detail-title');
  refs.detailBody = $('detail-body');
  refs.toastWrap = $('toast-wrap');
  refs.pullInd = $('pull-ind');
  refs.pullText = $('pull-text');
  refs.tabPages = $('tab-pages');
  refs.topbar = document.querySelector('.topbar');
}

function setStaticHtml(target, html) {
  // Trusted project markup only. Escape every runtime/API value before it is
  // interpolated, or build the node with textContent instead.
  const doc = new DOMParser().parseFromString(String(html || ''), 'text/html');
  target.replaceChildren(...Array.from(doc.body.childNodes).map((node) => document.importNode(node, true)));
}

function pushModalState(name) {
  history.pushState({ modal: name }, '');
}

function popModalIfTop(name) {
  if (history.state && history.state.modal === name) history.back();
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

function openRebootModal(pending, prev, context = 'thermal') {
  state.rebootContext = context;
  if (context === 'thermal') requireFeature('thermal').setPendingChange(pending, prev);
  if (context === 'scheduler') {
    const target = requireFeature('profile').getSchedulerBootTargetMode() === 'ugt' ? 'UGT 日常调度模式' : 'Pixel 调度模式';
    refs.rebootModalTitle.textContent = `切换到${target}`;
    refs.rebootModalDesc.textContent = `启动状态已提交。重启后才会进入${target}并完成最终验证。`;
  } else {
    refs.rebootModalTitle.textContent = '温控服务未能自动重启';
    refs.rebootModalDesc.textContent = '温控阈值已保存，但当前无法在线重启 thermal 服务。重启手机后新配置才会生效。';
  }
  refs.rebootModal.classList.add('open');
  pushModalState('reboot');
  const core = requireFeature('core');
  core.queueNextPoll(core.computeNextPollDelay());
}

function closeRebootModal() {
  refs.rebootModal.classList.remove('open');
  popModalIfTop('reboot');
  const core = requireFeature('core');
  core.queueNextPoll(POLL_MIN_DELAY_MS);
  core.showToast(state.rebootContext === 'scheduler' ? '切换已提交，重启后验证' : '已保存，重启手机后生效');
}

function openDetail(title, html) {
  stopTempChartRefresh();
  stopEnergyDetailRefresh();
  refs.detailModal.classList.remove('energy-mode');
  refs.detailModal.classList.remove('history-mode');
  refs.detailTitle.textContent = title;
  setStaticHtml(refs.detailBody, html);
  refs.detailModal.classList.add('open');
  pushModalState('detail');
  const core = requireFeature('core');
  core.queueNextPoll(core.computeNextPollDelay());
}

function closeDetailModal(){
  stopTempChartRefresh();
  stopEnergyDetailRefresh();
  refs.detailModal.classList.remove('open');
  refs.detailModal.classList.remove('energy-mode');
  refs.detailModal.classList.remove('history-mode');
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
  openThemeSheet,
  closeThemeSheet,
  openRebootModal,
  closeRebootModal,
  openDetail,
  closeDetailModal,
  stopTemperature: stopTempChartRefresh,
  stopEnergy: stopEnergyDetailRefresh,
  scheduleTemperature: scheduleTempChartRefresh,
  getRebootContext: () => state.rebootContext
});
})();

