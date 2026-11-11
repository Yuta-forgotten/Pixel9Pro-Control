'use strict';
(() => {

// 兼容入口：具体功能由 webroot/js 下的领域脚本注册并实现。
const appFeatures = Object.freeze({
  core: requireFeature('core'),
  auth: requireFeature('auth'),
  shell: requireFeature('shell'),
  ui: requireFeature('ui'),
  diagnostics: requireFeature('diagnostics'),
  analytics: requireFeature('analytics'),
  theme: requireFeature('theme'),
  profile: requireFeature('profile'),
  thermal: requireFeature('thermal'),
  memory: requireFeature('memory'),
  network: requireFeature('network')
});
const $ = appFeatures.ui.getElement;
const openDetail = appFeatures.ui.openDetail;
const showToast = appFeatures.core.showToast;
let fullRefreshPromise = null;
let profileLoaded = false;
const dataTasks = {
  info: ['系统信息', () => appFeatures.shell.loadInfo()],
  profile: ['调度配置', () => appFeatures.profile.load()],
  cpu: ['CPU', () => appFeatures.profile.refresh()],
  thermalConfig: ['温控配置', () => appFeatures.thermal.load()],
  thermal: ['温度', () => appFeatures.thermal.refresh()],
  memory: ['内存', () => appFeatures.memory.refresh()],
  restrictions: ['后台限制', () => appFeatures.memory.refreshRestrictions()],
  network: ['网络设置', () => appFeatures.network.refresh()],
  diagnostics: ['网络诊断', () => appFeatures.network.refreshDiagnostics()]
};
const tabData = {
  home: ['info', 'cpu', 'thermalConfig', 'thermal', 'memory', 'network'],
  tune: ['cpu', 'thermalConfig', 'thermal'],
  network: ['info', 'network', 'diagnostics'],
  system: ['info', 'memory', 'restrictions', 'network']
};

function refreshComponents(keys) {
  return Promise.all(keys.map((key) => appFeatures.core.runFeatureTask(`app.component.${key}`, async () => {
    const result = await dataTasks[key][1]();
    if (key === 'profile' && result === true) profileLoaded = true;
    return result;
  })));
}

async function doFullRefresh() {
  if (!appFeatures.core.isWebUiActive()) return null;
  if (fullRefreshPromise) return fullRefreshPromise;
  fullRefreshPromise = (async () => {
    const refreshButton = $('refresh-all-btn');
    refreshButton.disabled = true;
    showToast('正在刷新…', 1000);
    const keys = Object.keys(dataTasks);
    const results = await refreshComponents(keys);
    if (!appFeatures.core.isWebUiActive()) return;
    const failures = keys.filter((key, index) => results[index] === false)
      .map((key) => `${dataTasks[key][0]}：未获取有效状态`);
    failures.forEach((message) => appFeatures.core.appendLog(`刷新失败：${message}`, 'err'));
    appFeatures.core.markPollFresh(['cpu', 'thermal', 'optim', 'slow']);
    appFeatures.core.queueNextPoll(appFeatures.core.computeNextPollDelay());
    showToast(failures.length ? '刷新完成，部分状态读取失败' : '已刷新');
  })().finally(() => {
    $('refresh-all-btn').disabled = false;
    fullRefreshPromise = null;
  });
  return fullRefreshPromise;
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
  if (!appFeatures.core.isWebUiActive()) return Promise.resolve();
  const tab = appFeatures.shell.getCurrentTab();
  // A new page starts its own reads immediately; shared components keep one
  // in-flight task instead of joining the previous page's entire refresh.
  return appFeatures.core.runFeatureTask(`app.tab.${tab}`, () => {
    const keys = [...tabData[tab]];
    if (!profileLoaded && (tab === 'home' || tab === 'tune')) keys.push('profile');
    const pollKeys = { home: ['cpu', 'thermal', 'optim', 'slow'], tune: ['cpu', 'thermal'],
      network: ['slow'], system: ['optim', 'slow'] };
    appFeatures.core.markPollFresh(pollKeys[tab]);
    return refreshComponents(keys);
  }).finally(() => {
    appFeatures.core.queueNextPoll(appFeatures.core.computeNextPollDelay());
  });
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
  appFeatures.core.pauseReadRequests();
  appFeatures.analytics.pause();
  appFeatures.thermal.pause();
  appFeatures.network.stopDeviceClock();
}

async function resumeForegroundWork() {
  if (document.visibilityState !== 'visible' || document.hidden) return;
  const wasPaused = appFeatures.shell.isForegroundPaused();
  appFeatures.shell.setForegroundPaused(false);
  if (!wasPaused && appFeatures.shell.isPolling()) return;
  appFeatures.shell.setLastInteractionAt(Date.now());
  if (!appFeatures.core.isWebUiActive()) return;
  void refreshCurrentTabData();
  startPolling();
  appFeatures.network.syncDeviceClockForTab();
  if (appFeatures.analytics.isActive()) appFeatures.analytics.resume();
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
  $('swap-detail-btn').addEventListener('click', () => openDetail('内存参数说明', appFeatures.memory.buildSwapDetail(appFeatures.memory.getSwapData())));
  $('swap-tune-btn').addEventListener('click', appFeatures.memory.openSwapTuneModal);
  $('swap-tune-close-btn').addEventListener('click', appFeatures.memory.closeSwapTuneModal);
  $('swap-tune-close-x').addEventListener('click', appFeatures.memory.closeSwapTuneModal);
  $('swap-custom-apply-btn').addEventListener('click', appFeatures.memory.applySwapCustom);
  $('swap-zram-size-apply-btn').addEventListener('click', appFeatures.memory.applyZramSizeRequest);
  $('memory-boot-save').addEventListener('click', appFeatures.memory.saveMemoryBoot);
  $('memory-auto-apply').addEventListener('change', appFeatures.memory.toggleMemoryAuto);
  $('memory-restore-zram').addEventListener('click', appFeatures.memory.restoreZram);
  $('memory-recover').addEventListener('click', appFeatures.memory.recoverMemory);
  $('memory-preset-apply').addEventListener('click', appFeatures.memory.applyModulePreset);
  $('memory-preset-fill').addEventListener('click', appFeatures.memory.fillModulePreset);
  $('swap-preset-optimized').addEventListener('click', () => appFeatures.memory.setSwapTuneValues(appFeatures.memory.getSwapData()?.stock));
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
  $('nr-switch-detail-btn').addEventListener('click', () => openDetail('息屏切换 4G', appFeatures.network.buildNrSwitchDetail()));
  $('uecap-detail-btn').addEventListener('click', () => openDetail('网络能力配置说明', UECAP_DETAIL));
  $('baseband-detail-btn').addEventListener('click', () => openDetail('基带模块说明', BASEBAND_DETAIL));
  $('baseband-refresh-btn').addEventListener('click', appFeatures.network.refreshBaseband);
  $('ntp-sync-btn').addEventListener('click', appFeatures.network.syncNtp);
  $('temp-chart-btn').addEventListener('click', () => appFeatures.analytics.open('thermal'));
  $('energy-btn').addEventListener('click', () => appFeatures.analytics.open('thermal'));
  $('log-toggle').addEventListener('click', () => {
    refs.logCard.classList.toggle('open');
    $('log-toggle').setAttribute('aria-expanded', String(refs.logCard.classList.contains('open')));
  });
  $('log-clear-btn').addEventListener('click', appFeatures.core.clearLogs);
  $('log-audit-btn').addEventListener('click', appFeatures.diagnostics.openAuditLog);
  $('theme-close-btn').addEventListener('click', appFeatures.ui.closeThemeSheet);
  $('theme-close-x').addEventListener('click', appFeatures.ui.closeThemeSheet);
  $('detail-close-btn').addEventListener('click', appFeatures.ui.closeDetailModal);
  $('detail-close-x').addEventListener('click', appFeatures.ui.closeDetailModal);
  $('detail-minimize-btn').addEventListener('click', appFeatures.ui.toggleDetailMinimized);
  $('reboot-now-btn').addEventListener('click', appFeatures.thermal.rebootDevice);
  $('reboot-later-btn').addEventListener('click', appFeatures.ui.closeRebootModal);
  $('reboot-close-x').addEventListener('click', appFeatures.ui.closeRebootModal);
  $('reboot-cancel-btn').addEventListener('click', appFeatures.thermal.cancelPendingRebootChange);
  $('thermal-pending-btn').addEventListener('click', appFeatures.thermal.openPendingChange);
  $('open-cpu-detail-btn').addEventListener('click', () => {
    const detailState = appFeatures.profile.getCpuDetailState();
    const contract = detailState.cpuContract;
    const profileContract = contract?.profiles?.[detailState.currentProfile];
    const foreground = contract?.foreground_cpus || contract?.cpusets?.foreground?.cpus || 'unknown';
    const background = contract?.background_cpus || contract?.cpusets?.background?.cpus || 'unknown';
    const systemBackground = contract?.system_background_cpus || contract?.cpusets?.system_background?.cpus || background;
    const cpuSet = profileContract && contract
      ? `当前前台应用（top-app）：cpu${profileContract.top_app_cpus}\n普通前台进程（foreground）：cpu${foreground}，由系统管理\n后台应用（background）：cpu${background}\n系统后台进程（system-background）：cpu${systemBackground}`
      : '运行参数尚未读取';
    let html = `<b>当前模式</b><br>${(PROFILES[detailState.currentProfile] || PROFILES.unknown).name}<br><br>`;
    html += detailState.schedOwner === 'external'
      ? `<b>CPU 核心分配</b><br>${appFeatures.core.escapeHtml(appFeatures.profile.getSchedulerStatusText())}`
      : `<b>CPU 核心分配（cpuset）</b><br>${appFeatures.core.escapeHtml(cpuSet).replace(/\n/g, '<br>')}`;
    if (detailState.lastClusters && detailState.lastClusters.length) {
      detailState.lastClusters.forEach((cluster, index) => {
        const maxHz = Number.isFinite(cluster.max) && cluster.max > 0 ? cluster.max : 0;
        html += `<br><br><b>${CLUSTERS[index]?.label || `Cluster ${index}`}</b><br>`;
        html += `当前频率：${cluster.cur ? `${(cluster.cur / 1000).toFixed(0)} MHz` : '—'} / 当前上限：${maxHz ? `${(maxHz / 1000).toFixed(0)} MHz` : '—'}<br>`;
        const respText = typeof cluster.resp_ms_text === 'string' ? cluster.resp_ms_text : cluster.resp_ms;
        const downText = typeof cluster.down_us_text === 'string' ? cluster.down_us_text : cluster.down_us;
        html += `响应时间：${appFeatures.core.escapeHtml(appFeatures.profile.formatSchedValue(respText, 'ms'))} · 降频间隔：${appFeatures.core.escapeHtml(appFeatures.profile.formatSchedValue(downText, 'µs'))}<br>`;
        html += `调频器：${appFeatures.core.escapeHtml(cluster.gov || '—')}`;
      });
    } else html += '<br><br>未获取 CPU 频率数据，请刷新。';
    if (contract) {
      html += '<br><br><b>参数管理范围</b><br>本模块设置前台应用核心、响应时间、任务性能请求上限及厂商调度参数；普通前台进程的核心分配由系统管理。频率上下限仍受系统温控、电源管理和其他调度工具影响。';
      html += `<br><b>检查方式</b>：应用后检查一次，之后每 ${Number(contract.health_interval_s) || 300} 秒读取状态；发现系统修改参数时仅记录，不反复覆盖。`;
    }
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
      const preset = detailBtn.dataset.policy === 'system'
        ? appFeatures.thermal.getSystemPreset()
        : THERMAL_PRESETS[Number(detailBtn.dataset.offset)];
      openDetail(preset.name, preset.detail || preset.summary);
    }
  });
  window.addEventListener('popstate', appFeatures.ui.handlePopState);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden || document.visibilityState !== 'visible') pauseForegroundWork();
    else resumeForegroundWork();
  });
  window.addEventListener('pagehide', pauseForegroundWork);
  window.addEventListener('pageshow', resumeForegroundWork);
  document.addEventListener('freeze', pauseForegroundWork);
  document.addEventListener('resume', resumeForegroundWork);
}

async function init() {
  if (!WEBUI_NATIVE_TRANSPORT && location.host !== '127.0.0.1:6210') return;
  const bootAt = Date.now();
  appFeatures.ui.initialize();
  const pairing = appFeatures.auth.initialize();
  appFeatures.theme.initialize();
  appFeatures.profile.initialize();
  appFeatures.thermal.initialize();
  bindStaticEvents();
  appFeatures.shell.initializeInteractions();
  appFeatures.shell.setForegroundPaused(document.hidden || document.visibilityState !== 'visible');
  refs.topbarSubtitle.textContent = TAB_META[appFeatures.shell.getCurrentTab()];
  appFeatures.shell.setLastInteractionAt(bootAt);
  appFeatures.core.markPollFresh(['cpu', 'thermal', 'optim', 'slow'], bootAt);
  window.addEventListener('pixel9pro:paired', () => {
    void appFeatures.theme.restoreFromServer();
    void resumeForegroundWork();
  });
  if (await pairing) {
    void appFeatures.theme.restoreFromServer();
    startPolling();
    await refreshCurrentTabData();
  }
}

registerFeature('app', {
  fullRefresh: doFullRefresh,
  refreshCurrentTabData,
  isFullRefreshActive: () => Boolean(fullRefreshPromise),
  shouldPollCpu,
  shouldPollThermal,
  shouldPollOptim,
  shouldPollSlow
});
window.addEventListener('DOMContentLoaded', init);
})();
