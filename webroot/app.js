'use strict';
(() => {

// 兼容入口：具体功能由 webroot/js 下的领域脚本注册并实现。
const appFeatures = Object.freeze({
  core: requireFeature('core'),
  auth: requireFeature('auth'),
  shell: requireFeature('shell'),
  ui: requireFeature('ui'),
  theme: requireFeature('theme'),
  profile: requireFeature('profile'),
  thermal: requireFeature('thermal'),
  memory: requireFeature('memory'),
  network: requireFeature('network'),
  energy: requireFeature('energy')
});
const $ = appFeatures.ui.getElement;
const openDetail = appFeatures.ui.openDetail;
const showToast = appFeatures.core.showToast;

async function doFullRefresh() {
  showToast('正在刷新…', 1000);
  await Promise.all([
    appFeatures.profile.refresh(),
    appFeatures.thermal.refresh(),
    appFeatures.memory.refresh()
  ]);
  await Promise.allSettled([
    appFeatures.network.refresh(),
    appFeatures.memory.refreshRestrictions(),
    appFeatures.shell.loadInfo()
  ]);
  appFeatures.core.markPollFresh(['cpu', 'thermal', 'optim', 'slow']);
  appFeatures.core.queueNextPoll(appFeatures.core.computeNextPollDelay());
  showToast('已刷新');
}

function shouldPollCpu() {
  const tab = appFeatures.shell.getCurrentTab();
  return appFeatures.core.isWebUiActive() && (tab === 'home' || tab === 'tune');
}

function shouldPollThermal() {
  const tab = appFeatures.shell.getCurrentTab();
  return appFeatures.core.isWebUiActive() && (tab === 'home' || tab === 'tune');
}

function shouldPollOptim() {
  const tab = appFeatures.shell.getCurrentTab();
  return appFeatures.core.isWebUiActive() && (tab === 'home' || tab === 'system');
}

function shouldPollSlow() {
  const tab = appFeatures.shell.getCurrentTab();
  return appFeatures.core.isWebUiActive() && (tab === 'home' || tab === 'network' || tab === 'system');
}

function refreshCurrentTabData() {
  if (!appFeatures.core.isWebUiActive()) return;
  const now = Date.now();
  const tab = appFeatures.shell.getCurrentTab();
  if (tab === 'home') {
    appFeatures.core.markPollFresh(['cpu', 'thermal', 'optim', 'slow'], now);
    appFeatures.profile.refresh();
    appFeatures.thermal.refresh();
    appFeatures.memory.refresh();
    appFeatures.network.refresh();
    appFeatures.shell.loadInfo();
    appFeatures.core.queueNextPoll(appFeatures.core.computeNextPollDelay(now));
    return;
  }
  if (tab === 'tune') {
    appFeatures.core.markPollFresh(['cpu', 'thermal'], now);
    appFeatures.profile.refresh();
    appFeatures.thermal.refresh();
    appFeatures.core.queueNextPoll(appFeatures.core.computeNextPollDelay(now));
    return;
  }
  if (tab === 'network') {
    appFeatures.core.markPollFresh(['slow'], now);
    appFeatures.network.refresh();
    appFeatures.shell.loadInfo();
    appFeatures.core.queueNextPoll(appFeatures.core.computeNextPollDelay(now));
    return;
  }
  if (tab === 'system') {
    appFeatures.core.markPollFresh(['optim', 'slow'], now);
    appFeatures.memory.refresh();
    appFeatures.memory.refreshRestrictions();
    appFeatures.network.refresh();
    appFeatures.shell.loadInfo();
    appFeatures.core.queueNextPoll(appFeatures.core.computeNextPollDelay(now));
  }
}

function startPolling() {
  appFeatures.shell.startPolling();
}

function stopPolling() {
  appFeatures.shell.stopPolling();
}

function pauseForegroundWork() {
  if (appFeatures.shell.isForegroundPaused()) return;
  appFeatures.shell.setForegroundPaused(true);
  stopPolling();
  appFeatures.thermal.pause();
  appFeatures.energy.pause();
  appFeatures.network.stopDeviceClock();
}

function resumeForegroundWork() {
  if (document.visibilityState !== 'visible' || document.hidden) return;
  const wasPaused = appFeatures.shell.isForegroundPaused();
  appFeatures.shell.setForegroundPaused(false);
  if (!wasPaused && appFeatures.shell.isPolling()) return;
  appFeatures.shell.setLastInteractionAt(Date.now());
  refreshCurrentTabData();
  startPolling();
  appFeatures.network.syncDeviceClockForTab();
  if (refs.detailModal?.classList.contains('history-mode') && appFeatures.thermal.isChartActive()) {
    appFeatures.thermal.triggerBurst({ prompt: false });
    appFeatures.thermal.scheduleChart(250);
  }
  if (refs.detailModal?.classList.contains('energy-mode')) {
    appFeatures.energy.scheduleDetail(250);
    appFeatures.energy.scheduleSystem(800);
  }
}

function bindStaticEvents() {
  window.addEventListener('pointerdown', appFeatures.core.noteUserActivity, { passive: true });
  document.addEventListener('keydown', appFeatures.core.noteUserActivity);
  document.querySelectorAll('.tab-item').forEach((button) => button.addEventListener('click', () => appFeatures.core.switchTab(button.dataset.tab)));
  document.querySelectorAll('[data-theme-option]').forEach((button) => {
    button.addEventListener('click', () => {
      appFeatures.theme.applyTheme(button.dataset.themeOption, true);
      appFeatures.ui.closeThemeSheet();
      showToast(`已切换为${appFeatures.theme.getThemeLabel(button.dataset.themeOption)}`);
    });
  });
  document.querySelectorAll('[data-seg-theme]').forEach((button) => {
    button.addEventListener('click', () => {
      appFeatures.theme.applyTheme(button.dataset.segTheme, true);
      showToast(`已切换为${appFeatures.theme.getThemeLabel(button.dataset.segTheme)}`);
    });
  });
  const swatchRow = $('swatch-row');
  if (swatchRow) swatchRow.addEventListener('click', (evt) => {
    const sw = evt.target.closest('.swatch');
    if (!sw) return;
    appFeatures.theme.applyPalette(sw.dataset.palette, true);
    const p = PALETTES.find((x) => x.name === sw.dataset.palette);
    showToast(`主题色：${p ? p.label : '已应用'}`);
  });
  $('palette-hex-apply').addEventListener('click', appFeatures.theme.applyCustomHex);
  $('palette-hex-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') appFeatures.theme.applyCustomHex(); });
  $('theme-open-btn').addEventListener('click', appFeatures.ui.openThemeSheet);
  $('refresh-all-btn').addEventListener('click', doFullRefresh);
  $('sched-owner-toggle-btn').addEventListener('click', appFeatures.profile.toggleSchedOwner);
  $('scheduler-retry-btn').addEventListener('click', appFeatures.profile.retrySchedulerValidation);
  $('game-handoff-toggle-btn').addEventListener('click', appFeatures.profile.toggleGameHandoff);
  $('owner-arbiter-tick-btn').addEventListener('click', appFeatures.profile.triggerOwnerArbiter);
  $('swap-toggle-btn').addEventListener('click', appFeatures.memory.toggleSwapMode);
  $('swap-detail-btn').addEventListener('click', () => openDetail('内存优化详情', appFeatures.memory.buildSwapDetail(appFeatures.memory.getSwapData())));
  $('swap-tune-btn').addEventListener('click', appFeatures.memory.openSwapTuneModal);
  $('swap-tune-close-btn').addEventListener('click', appFeatures.memory.closeSwapTuneModal);
  $('swap-tune-close-x').addEventListener('click', appFeatures.memory.closeSwapTuneModal);
  $('swap-custom-apply-btn').addEventListener('click', appFeatures.memory.applySwapCustom);
  $('swap-preset-optimized').addEventListener('click', () => appFeatures.memory.setSwapTuneValues(appFeatures.memory.getSwapData()?.optimized));
  $('swap-preset-stock').addEventListener('click', () => appFeatures.memory.setSwapTuneValues(appFeatures.memory.getSwapData()?.stock));
  SWAP_KEYS.forEach((key) => {
    refs.swapTuneInputs[key].addEventListener('input', (evt) => appFeatures.memory.syncSwapTuneField(key, evt.target.value));
    refs.swapTuneNumbers[key].addEventListener('change', (evt) => appFeatures.memory.syncSwapTuneField(key, evt.target.value));
    refs.swapTuneNumbers[key].addEventListener('keydown', (evt) => {
      if (evt.key === 'Enter') {
        evt.preventDefault();
        appFeatures.memory.syncSwapTuneField(key, evt.target.value);
      }
    });
  });
  $('nr-switch-toggle-btn').addEventListener('click', appFeatures.network.toggleNrSwitch);
  $('sim2-auto-toggle-btn').addEventListener('click', appFeatures.network.toggleSim2AutoManage);
  $('idle-isolate-toggle-btn').addEventListener('click', appFeatures.network.toggleIdleIsolateMode);
  $('bg-restrict-toggle-btn').addEventListener('click', appFeatures.memory.toggleBgRestrict);
  $('bg-restrict-add-btn').addEventListener('click', appFeatures.memory.bgRestrictAdd);
  $('bg-restrict-pkg-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') appFeatures.memory.bgRestrictAdd(); });
  $('bg-restrict-pkg-input').addEventListener('input', appFeatures.memory.syncBgPackageHint);
  $('bg-restrict-policy-select').addEventListener('change', appFeatures.memory.syncBgRestrictControls);
  $('bg-restrict-refresh-btn').addEventListener('click', appFeatures.memory.forceRefreshBgRestrict);
  $('nr-switch-detail-btn').addEventListener('click', () => openDetail('NR 息屏降级详情', appFeatures.network.buildNrSwitchDetail()));
  $('uecap-detail-btn').addEventListener('click', () => openDetail('UE 网络能力配置', UECAP_DETAIL));
  $('baseband-detail-btn').addEventListener('click', () => openDetail('基带模块说明', BASEBAND_DETAIL));
  $('baseband-refresh-btn').addEventListener('click', appFeatures.network.refreshBaseband);
  $('ntp-sync-btn').addEventListener('click', appFeatures.network.syncNtp);
  $('temp-chart-btn').addEventListener('click', appFeatures.thermal.openChart);
  $('energy-btn').addEventListener('click', appFeatures.energy.open);
  $('home-temp-chart-btn').addEventListener('click', appFeatures.thermal.openChart);
  $('log-toggle').addEventListener('click', () => refs.logCard.classList.toggle('open'));
  $('theme-close-btn').addEventListener('click', appFeatures.ui.closeThemeSheet);
  $('detail-close-btn').addEventListener('click', appFeatures.ui.closeDetailModal);
  $('detail-close-x').addEventListener('click', appFeatures.ui.closeDetailModal);
  $('reboot-now-btn').addEventListener('click', appFeatures.thermal.rebootDevice);
  $('reboot-later-btn').addEventListener('click', appFeatures.ui.closeRebootModal);
  $('reboot-cancel-btn').addEventListener('click', appFeatures.thermal.cancelPendingRebootChange);
  $('open-cpu-detail-btn').addEventListener('click', () => {
    const detailState = appFeatures.profile.getCpuDetailState();
    const contract = detailState.cpuContract;
    const profileContract = contract?.profiles?.[detailState.currentProfile];
    const cpuSet = profileContract && contract
      ? `top-app: cpu${profileContract.top_app_cpus}\nforeground: cpu${contract.foreground_cpus}\nbackground: cpu${contract.background_cpus}`
      : '运行参数尚未读取';
    let html = `<b>当前模式</b><br>${(PROFILES[detailState.currentProfile] || PROFILES.unknown).name}<br><br>`;
    html += detailState.schedOwner === 'external'
      ? `<b>cpuset 分配</b><br>${appFeatures.core.escapeHtml(appFeatures.profile.getSchedulerStatusText())}`
      : `<b>cpuset 分配</b><br>${appFeatures.core.escapeHtml(cpuSet).replace(/\n/g, '<br>')}`;
    if (detailState.lastClusters && detailState.lastClusters.length) {
      detailState.lastClusters.forEach((cluster, index) => {
        const maxHz = cluster.max > 0 ? cluster.max : (CLUSTERS[index]?.maxHz || 0);
        html += `<br><br><b>${CLUSTERS[index]?.label || `Cluster ${index}`}</b><br>`;
        html += `cur: ${cluster.cur ? `${(cluster.cur / 1000).toFixed(0)} MHz` : '—'} / max: ${maxHz ? `${(maxHz / 1000).toFixed(0)} MHz` : '—'}<br>`;
        const respText = typeof cluster.resp_ms_text === 'string' ? cluster.resp_ms_text : cluster.resp_ms;
        const downText = typeof cluster.down_us_text === 'string' ? cluster.down_us_text : cluster.down_us;
        html += `resp_time: ${appFeatures.core.escapeHtml(appFeatures.profile.formatSchedValue(respText, 'ms'))} · down_rate: ${appFeatures.core.escapeHtml(appFeatures.profile.formatSchedValue(downText, 'µs'))}<br>`;
        html += `governor: ${appFeatures.core.escapeHtml(cluster.gov || '—')}`;
      });
    } else html += '<br><br>暂无频率快照，请先刷新一次。';
    openDetail('CPU 调度参数详情', html);
  });
  refs.detailModal.querySelector('.modal-bg').addEventListener('click', appFeatures.ui.closeDetailModal);
  refs.swapTuneModal.querySelector('.modal-bg').addEventListener('click', appFeatures.memory.closeSwapTuneModal);
  refs.themeModal.querySelector('.modal-bg').addEventListener('click', appFeatures.ui.closeThemeSheet);
  refs.profileList.addEventListener('click', (evt) => {
    const detailBtn = evt.target.closest('[data-action="profile-detail"]');
    if (detailBtn) openDetail(PROFILES[detailBtn.dataset.profile].name, appFeatures.profile.buildProfileDetail(detailBtn.dataset.profile));
  });
  refs.profilePolicyManualBtn.addEventListener('click', () => appFeatures.profile.setProfilePolicy('manual'));
  refs.profilePolicyAutoBtn.addEventListener('click', () => appFeatures.profile.setProfilePolicy('auto'));
  refs.thermalList.addEventListener('click', (evt) => {
    const detailBtn = evt.target.closest('[data-action="thermal-detail"]');
    if (detailBtn) {
      const offset = Number(detailBtn.dataset.offset);
      openDetail(THERMAL_PRESETS[offset].name, THERMAL_PRESETS[offset].detail);
    }
  });
  window.addEventListener('popstate', (evt) => {
    const s = evt.state;
    if (refs.detailModal.classList.contains('open')) {
      appFeatures.thermal.stopChart();
      appFeatures.energy.stop();
      refs.detailModal.classList.remove('open', 'energy-mode', 'history-mode');
      return;
    }
    if (refs.swapTuneModal.classList.contains('open')) { refs.swapTuneModal.classList.remove('open'); appFeatures.core.queueNextPoll(POLL_MIN_DELAY_MS); return; }
    if (refs.themeModal.classList.contains('open')) { refs.themeModal.classList.remove('open'); return; }
    if (refs.rebootModal.classList.contains('open')) { refs.rebootModal.classList.remove('open'); return; }
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden || document.visibilityState !== 'visible') pauseForegroundWork();
    else resumeForegroundWork();
  });
  window.addEventListener('pagehide', pauseForegroundWork);
  window.addEventListener('pageshow', resumeForegroundWork);
  document.addEventListener('freeze', pauseForegroundWork);
  document.addEventListener('resume', resumeForegroundWork);
}

async function refreshDeferredInitData() {
  appFeatures.core.markPollFresh(['optim', 'slow']);
  await Promise.allSettled([
    appFeatures.memory.refresh(),
    appFeatures.memory.refreshRestrictions(),
    appFeatures.network.refresh()
  ]);
  appFeatures.core.queueNextPoll(appFeatures.core.computeNextPollDelay());
}

async function init() {
  const bootAt = Date.now();
  appFeatures.ui.initialize();
  appFeatures.auth.initialize();
  appFeatures.theme.initialize();
  appFeatures.profile.initialize();
  appFeatures.thermal.initialize();
  bindStaticEvents();
  appFeatures.shell.initializeInteractions();
  appFeatures.shell.setForegroundPaused(document.hidden || document.visibilityState !== 'visible');
  refs.topbarSubtitle.textContent = TAB_META[appFeatures.shell.getCurrentTab()];
  appFeatures.thermal.positionMarkers();
  appFeatures.shell.setLastInteractionAt(bootAt);
  appFeatures.core.markPollFresh(['cpu', 'thermal', 'optim', 'slow'], bootAt);
  await appFeatures.shell.loadInfo();
  await Promise.all([appFeatures.profile.load(), appFeatures.thermal.load()]);
  await appFeatures.profile.refresh();
  await appFeatures.thermal.refresh();
  appFeatures.core.markPollFresh(['cpu', 'thermal']);
  window.setTimeout(() => {
    if (appFeatures.core.isWebUiActive()) refreshDeferredInitData();
  }, 1000);
  if (appFeatures.core.isWebUiActive()) startPolling();
}

registerFeature('app', {
  fullRefresh: doFullRefresh,
  refreshCurrentTabData,
  shouldPollCpu,
  shouldPollThermal,
  shouldPollOptim,
  shouldPollSlow
});
window.addEventListener('DOMContentLoaded', init);
})();
