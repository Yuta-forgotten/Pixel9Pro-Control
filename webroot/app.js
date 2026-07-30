'use strict';

// 兼容入口：具体功能由 webroot/js 下的领域脚本注册并实现。
const appFeatures = Object.freeze({
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
  markPollFresh(['cpu', 'thermal', 'optim', 'slow']);
  queueNextPoll(computeNextPollDelay());
  showToast('已刷新');
}

function shouldPollCpu() {
  return isWebUiActive() && (state.shell.currentTab === 'home' || state.shell.currentTab === 'tune');
}

function shouldPollThermal() {
  return isWebUiActive() && (state.shell.currentTab === 'home' || state.shell.currentTab === 'tune');
}

function shouldPollOptim() {
  return isWebUiActive() && (state.shell.currentTab === 'home' || state.shell.currentTab === 'system');
}

function shouldPollSlow() {
  return isWebUiActive() && (state.shell.currentTab === 'home' || state.shell.currentTab === 'network' || state.shell.currentTab === 'system');
}

function refreshCurrentTabData() {
  if (!isWebUiActive()) return;
  const now = Date.now();
  if (state.shell.currentTab === 'home') {
    markPollFresh(['cpu', 'thermal', 'optim', 'slow'], now);
    appFeatures.profile.refresh();
    appFeatures.thermal.refresh();
    appFeatures.memory.refresh();
    appFeatures.network.refresh();
    appFeatures.shell.loadInfo();
    queueNextPoll(computeNextPollDelay(now));
    return;
  }
  if (state.shell.currentTab === 'tune') {
    markPollFresh(['cpu', 'thermal'], now);
    appFeatures.profile.refresh();
    appFeatures.thermal.refresh();
    queueNextPoll(computeNextPollDelay(now));
    return;
  }
  if (state.shell.currentTab === 'network') {
    markPollFresh(['slow'], now);
    appFeatures.network.refresh();
    appFeatures.shell.loadInfo();
    queueNextPoll(computeNextPollDelay(now));
    return;
  }
  if (state.shell.currentTab === 'system') {
    markPollFresh(['optim', 'slow'], now);
    appFeatures.memory.refresh();
    appFeatures.memory.refreshRestrictions();
    appFeatures.network.refresh();
    appFeatures.shell.loadInfo();
    queueNextPoll(computeNextPollDelay(now));
  }
}

function startPolling() {
  if (state.shell.poller.running) return;
  state.shell.poller.running = true;
  queueNextPoll(computeNextPollDelay());
}

function stopPolling() {
  state.shell.poller.running = false;
  clearTimeout(state.shell.poller.timer);
  state.shell.poller.timer = null;
}

function pauseForegroundWork() {
  if (state.shell.foregroundPaused) return;
  state.shell.foregroundPaused = true;
  stopPolling();
  appFeatures.thermal.pause();
  appFeatures.energy.pause();
  appFeatures.network.stopDeviceClock();
}

function resumeForegroundWork() {
  if (document.visibilityState !== 'visible' || document.hidden) return;
  const wasPaused = state.shell.foregroundPaused;
  state.shell.foregroundPaused = false;
  if (!wasPaused && state.shell.poller.running) return;
  state.shell.poller.lastInteractionAt = Date.now();
  refreshCurrentTabData();
  startPolling();
  appFeatures.network.syncDeviceClockForTab();
  if (refs.detailModal?.classList.contains('history-mode') && state.thermal.tempChart.draw) {
    triggerThermalBurst({ prompt: false });
    scheduleTempChartRefresh(250);
  }
  if (refs.detailModal?.classList.contains('energy-mode')) {
    appFeatures.energy.scheduleDetail(250);
    appFeatures.energy.scheduleSystem(800);
  }
}

function bindStaticEvents() {
  window.addEventListener('pointerdown', noteUserActivity, { passive: true });
  document.addEventListener('keydown', noteUserActivity);
  document.querySelectorAll('.tab-item').forEach((button) => button.addEventListener('click', () => switchTab(button.dataset.tab)));
  document.querySelectorAll('[data-theme-option]').forEach((button) => {
    button.addEventListener('click', () => {
      applyTheme(button.dataset.themeOption, true);
      closeThemeSheet();
      showToast(`已切换为${getThemeLabel(button.dataset.themeOption)}`);
    });
  });
  document.querySelectorAll('[data-seg-theme]').forEach((button) => {
    button.addEventListener('click', () => {
      applyTheme(button.dataset.segTheme, true);
      showToast(`已切换为${getThemeLabel(button.dataset.segTheme)}`);
    });
  });
  const swatchRow = $('swatch-row');
  if (swatchRow) swatchRow.addEventListener('click', (evt) => {
    const sw = evt.target.closest('.swatch');
    if (!sw) return;
    applyPalette(sw.dataset.palette, true);
    const p = PALETTES.find((x) => x.name === sw.dataset.palette);
    showToast(`主题色：${p ? p.label : '已应用'}`);
  });
  $('palette-hex-apply').addEventListener('click', applyCustomHex);
  $('palette-hex-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') applyCustomHex(); });
  $('theme-open-btn').addEventListener('click', openThemeSheet);
  $('refresh-all-btn').addEventListener('click', doFullRefresh);
  $('sched-owner-toggle-btn').addEventListener('click', toggleSchedOwner);
  $('scheduler-retry-btn').addEventListener('click', retrySchedulerValidation);
  $('game-handoff-toggle-btn').addEventListener('click', toggleGameHandoff);
  $('owner-arbiter-tick-btn').addEventListener('click', triggerOwnerArbiter);
  $('swap-toggle-btn').addEventListener('click', toggleSwapMode);
  $('swap-detail-btn').addEventListener('click', () => openDetail('内存优化详情', buildSwapDetail(state.memory.swapData)));
  $('swap-tune-btn').addEventListener('click', openSwapTuneModal);
  $('swap-tune-close-btn').addEventListener('click', closeSwapTuneModal);
  $('swap-tune-close-x').addEventListener('click', closeSwapTuneModal);
  $('swap-custom-apply-btn').addEventListener('click', applySwapCustom);
  $('swap-preset-optimized').addEventListener('click', () => setSwapTuneValues(state.memory.swapData?.optimized));
  $('swap-preset-stock').addEventListener('click', () => setSwapTuneValues(state.memory.swapData?.stock));
  SWAP_KEYS.forEach((key) => {
    refs.swapTuneInputs[key].addEventListener('input', (evt) => syncSwapTuneField(key, evt.target.value));
    refs.swapTuneNumbers[key].addEventListener('change', (evt) => syncSwapTuneField(key, evt.target.value));
    refs.swapTuneNumbers[key].addEventListener('keydown', (evt) => {
      if (evt.key === 'Enter') {
        evt.preventDefault();
        syncSwapTuneField(key, evt.target.value);
      }
    });
  });
  $('nr-switch-toggle-btn').addEventListener('click', toggleNrSwitch);
  $('sim2-auto-toggle-btn').addEventListener('click', toggleSim2AutoManage);
  $('idle-isolate-toggle-btn').addEventListener('click', toggleIdleIsolateMode);
  $('bg-restrict-toggle-btn').addEventListener('click', toggleBgRestrict);
  $('bg-restrict-add-btn').addEventListener('click', bgRestrictAdd);
  $('bg-restrict-pkg-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') bgRestrictAdd(); });
  $('bg-restrict-pkg-input').addEventListener('input', syncBgPackageHint);
  $('bg-restrict-policy-select').addEventListener('change', syncBgRestrictControls);
  $('bg-restrict-refresh-btn').addEventListener('click', forceRefreshBgRestrict);
  $('nr-switch-detail-btn').addEventListener('click', () => openDetail('NR 息屏降级详情', buildNrSwitchDetail()));
  $('uecap-detail-btn').addEventListener('click', () => openDetail('UE 网络能力配置', UECAP_DETAIL));
  $('baseband-detail-btn').addEventListener('click', () => openDetail('基带模块说明', BASEBAND_DETAIL));
  $('baseband-refresh-btn').addEventListener('click', refreshBaseband);
  $('ntp-sync-btn').addEventListener('click', syncNtp);
  $('temp-chart-btn').addEventListener('click', openTempChart);
  $('energy-btn').addEventListener('click', openEnergyDetail);
  $('home-temp-chart-btn').addEventListener('click', openTempChart);
  $('log-toggle').addEventListener('click', () => refs.logCard.classList.toggle('open'));
  $('theme-close-btn').addEventListener('click', closeThemeSheet);
  $('detail-close-btn').addEventListener('click', closeDetailModal);
  $('detail-close-x').addEventListener('click', closeDetailModal);
  $('reboot-now-btn').addEventListener('click', rebootDevice);
  $('reboot-later-btn').addEventListener('click', closeRebootModal);
  $('reboot-cancel-btn').addEventListener('click', cancelPendingRebootChange);
  $('open-cpu-detail-btn').addEventListener('click', () => {
    const contract = state.profile.cpuContract;
    const profileContract = contract?.profiles?.[state.profile.currentProfile];
    const cpuSet = profileContract && contract
      ? `top-app: cpu${profileContract.top_app_cpus}\nforeground: cpu${contract.foreground_cpus}\nbackground: cpu${contract.background_cpus}`
      : '运行参数尚未读取';
    let html = `<b>当前模式</b><br>${(PROFILES[state.profile.currentProfile] || PROFILES.unknown).name}<br><br>`;
    html += state.profile.schedOwner === 'external'
      ? `<b>cpuset 分配</b><br>${escapeHtml(getSchedulerStatusText())}`
      : `<b>cpuset 分配</b><br>${escapeHtml(cpuSet).replace(/\n/g, '<br>')}`;
    if (state.profile.lastClusters && state.profile.lastClusters.length) {
      state.profile.lastClusters.forEach((cluster, index) => {
        const maxHz = cluster.max > 0 ? cluster.max : (CLUSTERS[index]?.maxHz || 0);
        html += `<br><br><b>${CLUSTERS[index]?.label || `Cluster ${index}`}</b><br>`;
        html += `cur: ${cluster.cur ? `${(cluster.cur / 1000).toFixed(0)} MHz` : '—'} / max: ${maxHz ? `${(maxHz / 1000).toFixed(0)} MHz` : '—'}<br>`;
        const respText = typeof cluster.resp_ms_text === 'string' ? cluster.resp_ms_text : cluster.resp_ms;
        const downText = typeof cluster.down_us_text === 'string' ? cluster.down_us_text : cluster.down_us;
        html += `resp_time: ${escapeHtml(formatSchedValue(respText, 'ms'))} · down_rate: ${escapeHtml(formatSchedValue(downText, 'µs'))}<br>`;
        html += `governor: ${escapeHtml(cluster.gov || '—')}`;
      });
    } else html += '<br><br>暂无频率快照，请先刷新一次。';
    openDetail('CPU 调度参数详情', html);
  });
  refs.detailModal.querySelector('.modal-bg').addEventListener('click', closeDetailModal);
  refs.swapTuneModal.querySelector('.modal-bg').addEventListener('click', closeSwapTuneModal);
  refs.themeModal.querySelector('.modal-bg').addEventListener('click', closeThemeSheet);
  refs.profileList.addEventListener('click', (evt) => {
    const detailBtn = evt.target.closest('[data-action="profile-detail"]');
    if (detailBtn) openDetail(PROFILES[detailBtn.dataset.profile].name, buildProfileDetail(detailBtn.dataset.profile));
  });
  refs.profilePolicyManualBtn.addEventListener('click', () => setProfilePolicy('manual'));
  refs.profilePolicyAutoBtn.addEventListener('click', () => setProfilePolicy('auto'));
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
      stopTempChartRefresh();
      stopEnergyDetailRefresh();
      refs.detailModal.classList.remove('open', 'energy-mode', 'history-mode');
      return;
    }
    if (refs.swapTuneModal.classList.contains('open')) { refs.swapTuneModal.classList.remove('open'); queueNextPoll(POLL_MIN_DELAY_MS); return; }
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
  markPollFresh(['optim', 'slow']);
  await Promise.allSettled([
    appFeatures.memory.refresh(),
    appFeatures.memory.refreshRestrictions(),
    appFeatures.network.refresh()
  ]);
  queueNextPoll(computeNextPollDelay());
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
  state.shell.foregroundPaused = document.hidden || document.visibilityState !== 'visible';
  refs.topbarSubtitle.textContent = TAB_META[state.shell.currentTab];
  appFeatures.thermal.positionMarkers();
  state.shell.poller.lastInteractionAt = bootAt;
  markPollFresh(['cpu', 'thermal', 'optim', 'slow'], bootAt);
  await appFeatures.shell.loadInfo();
  await Promise.all([appFeatures.profile.load(), appFeatures.thermal.load()]);
  await appFeatures.profile.refresh();
  await appFeatures.thermal.refresh();
  markPollFresh(['cpu', 'thermal']);
  window.setTimeout(() => {
    if (isWebUiActive()) refreshDeferredInitData();
  }, 1000);
  if (isWebUiActive()) startPolling();
}

window.addEventListener('DOMContentLoaded', init);
