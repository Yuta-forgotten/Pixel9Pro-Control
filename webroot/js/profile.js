// CPU profile、调度 owner 与临时游戏接管功能。
'use strict';
(() => {
const state = {
  currentProfile: 'unknown',
  schedulerMode: 'active',
  schedulerCapability: 'unknown',
  schedulerCapabilityReason: '',
  manualProfile: 'balanced',
  profilePolicy: 'manual',
  schedOwner: 'pixel',
  schedEffectiveOwner: 'pixel',
  gameHandoffPolicy: 'off',
  arbiterState: '',
  arbiterApplyResult: '',
  arbiterReason: '',
  uperfDetected: false,
  uperfModuleId: '',
  uperfModuleName: '',
  uperfModulePath: '',
  uperfModuleSource: '',
  uperfModuleState: '',
  uperfModuleEnabled: 'no',
  uperfProcessAlive: 'no',
  uperfActive: 'no',
  fasRsDetected: false,
  fasRsModuleId: '',
  fasRsModuleName: '',
  fasRsModulePath: '',
  fasRsModuleSource: '',
  fasRsModuleState: '',
  fasRsModuleEnabled: 'no',
  fasRsOwnerState: '',
  fasRsMode: '',
  fasRsProcessAlive: 'no',
  fasRsRuntimeState: '',
  fasRsRuntimeOwnerActive: 'no',
  fasRsRuntimeTarget: '',
  fasRsActive: 'no',
  externalSchedulerDetected: false,
  externalSchedulerActive: false,
  externalSchedulerId: '',
  externalSchedulerName: '',
  externalSchedulerKind: '',
  externalSchedulerPath: '',
  externalSchedulerSource: '',
  externalSchedulerState: '',
  externalSchedulerEnabled: 'no',
  effectiveSchedulerOwner: 'pixel',
  effectiveSchedulerName: 'Pixel9Pro-Control',
  effectiveSchedulerKind: 'pixel',
  effectiveSchedulerMode: '',
  profileSurface: 'authoritative',
  profileSurfaceStale: false,
  profileSurfaceNote: '',
  cpuContract: null,
  schedulerBoot: {
    targetMode: 'pixel', effectiveMode: 'unknown', phase: '', final: 'no', ok: 'pending',
    result: '', reason: '', attempts: 0, rebootRequired: 'no', autoRepairUsed: 'no'
  },
  schedulerHealth: { status: '', reason: '', checkedEpoch: '', profileVerified: '', cpufreqPermissions: '', powerhalFailures: '' },
  profileTransition: { key: '', attempts: 0, firstEpoch: '', deadlineEpoch: '', terminal: 'no', ok: 'pending', result: '' },
  autoReason: '',
  cpuBusy: false,
  profileApplyBusy: false,
  profilePolicyBusy: false,
  schedOwnerBusy: false,
  gameHandoffBusy: false,
  ownerArbiterBusy: false,
  schedulerRetryBusy: false,
  schedulerOperation: { id: '', kind: '', phase: 'none', pending: false, resultCode: 0 },
  cpuRows: null,
  homeCpuRows: null,
  lastClusters: null
};

const SCHEDULER_READ_TIMEOUTS = Object.freeze({
  cpu: 10000,
  compact: 12000,
  owner: 20000,
  full: 60000
});

const core = () => requireFeature('core');
const apiFetch = (...args) => core().apiFetch(...args);
const isCancelled = (err) => core().isRequestCancelled?.(err) === true;
const appendLog = (...args) => core().appendLog(...args);
const escapeHtml = (...args) => core().escapeHtml(...args);
const showToast = (...args) => core().showToast(...args);
const setStaticHtml = (...args) => requireFeature('ui').setStaticHtml(...args);
const openRebootModal = (...args) => requireFeature('ui').openRebootModal(...args);
const syncHeroDesc = () => requireFeature('thermal').syncHeroDesc();

function buildProfileDetail(key) {
  const profile = PROFILES[key] || PROFILES.unknown;
  if (key === 'off') return `<p>${profile.desc}</p><p>关闭后停止本模块的调度写入。重新启用需按安装向导选择，并完成重启后的状态核对。</p>`;
  const contract = state.cpuContract;
  const values = contract?.profiles?.[key];
  let html = `<b>${profile.name}</b><br><br>${profile.detail}`;
  if (!values || !contract) return `${html}<br><br>运行参数尚未读取。`;
  const response = Array.isArray(values.response_ms)
    ? values.response_ms.map((value) => `${value}ms`).join(' / ')
    : '内核 response_time_ms_nom（运行时复读）';
  const foreground = contract.foreground_cpus || contract.cpusets?.foreground?.cpus || 'unknown';
  const background = contract.background_cpus || contract.cpusets?.background?.cpus || 'unknown';
  const systemBackground = contract.system_background_cpus || contract.cpusets?.system_background?.cpus || background;
  html += `<br><br><b>CPU 核心分配（cpuset）</b><br>当前前台应用：cpu${escapeHtml(values.top_app_cpus || '未确认')}<br>后台应用：cpu${escapeHtml(background)}<br>系统后台进程：cpu${escapeHtml(systemBackground)}`;
  html += `<br>普通前台进程：cpu${escapeHtml(foreground)}，由系统管理`;
  html += `<br><b>小核 / 中核 / 大核响应时间</b>：${escapeHtml(response)}`;
  html += `<br><b>任务性能请求上限（sched_util_clamp_min）</b>：${Number.isFinite(values.uclamp_cap) ? values.uclamp_cap : '尚未读取'}`;
  html += `<br><b>参数检查方式</b>：应用后检查一次，之后每 ${Number(contract.health_interval_s) || 300} 秒读取状态；发现系统修改参数时仅记录，不反复覆盖`;
  return html;
}

// 共享布尔值兼容 CGI 的 true/yes/1 表达；profile state 仍只保留在本模块私有 scope。
function boolValue(value) {
  return value === true || value === 'true' || value === 'yes' || value === 1 || value === '1';
}

function formatSchedValue(value, unit) {
  if (value === null || value === undefined || value === '' || value === 'N/A' || value === 'na') return 'N/A';
  return `${value}${unit}`;
}

function getUperfName() {
  return state.uperfModuleName || state.uperfModuleId || 'Uperf Game Turbo';
}

function getUperfStateText() {
  if (isUperfActive()) return '运行中';
  switch (state.uperfModuleState) {
    case 'disabled': return '已禁用';
    case 'pending_update': return '待重启更新';
    case 'pending_remove': return '待重启移除';
    case 'active': return '已安装';
    default: return state.uperfDetected ? '已安装' : '未检测到';
  }
}

function isUperfEnabled() {
  return state.uperfDetected && state.uperfModuleEnabled === 'yes';
}

function isUperfActive() {
  return state.uperfDetected && (state.uperfActive === 'yes' || state.uperfProcessAlive === 'yes');
}

function getFasRsName() {
  return state.fasRsModuleName || state.fasRsModuleId || 'fas-rs';
}

function getFasRsStateText() {
  if (isFasRsRuntimeActive()) {
    return state.fasRsRuntimeTarget ? `游戏接管中 · ${state.fasRsRuntimeTarget}` : '游戏接管中';
  }
  if (isFasRsResident()) {
    return state.fasRsMode ? `常驻待机 · ${state.fasRsMode}` : '常驻待机';
  }
  switch (state.fasRsRuntimeState || state.fasRsModuleState) {
    case 'disabled_marker': return '已让权';
    case 'disabled': return '已禁用';
    case 'pending_update': return '待重启更新';
    case 'pending_remove': return '待重启移除';
    case 'stale_game_lease': return '游戏接管记录已失效';
    case 'stale_owner_state': return '运行标记待刷新';
    case 'module_enabled': return '已启用，尚未确认进程状态';
    case 'runtime_present': return '检测到运行接口，尚未确认接管';
    case 'active': return '已安装';
    default: return state.fasRsDetected ? '已检测到' : '未检测到';
  }
}

function isFasRsEnabled() {
  return state.fasRsDetected && (isFasRsResident() || state.fasRsActive === 'yes' || state.fasRsModuleEnabled === 'yes');
}

function isFasRsResident() {
  return state.fasRsDetected && state.fasRsProcessAlive === 'yes';
}

function isFasRsRuntimeActive() {
  return state.fasRsDetected && (state.fasRsRuntimeOwnerActive === 'yes' || state.fasRsActive === 'yes');
}

function getExternalSchedulerName() {
  return state.externalSchedulerName || state.externalSchedulerId || (state.fasRsDetected ? getFasRsName() : getUperfName());
}

function getEffectiveSchedulerName() {
  return state.effectiveSchedulerName || getExternalSchedulerName();
}

function getEffectiveSchedulerModeText() {
  return state.effectiveSchedulerMode ? ` · ${state.effectiveSchedulerMode}` : '';
}

function hasExternalScheduler() {
  return state.externalSchedulerDetected || state.uperfDetected || state.fasRsDetected;
}

function isExternalSchedulerActive() {
  return state.externalSchedulerActive || isUperfActive() || isFasRsRuntimeActive();
}

function getExternalSchedulerStateText() {
  if (state.externalSchedulerKind === 'fas_rs') return getFasRsStateText();
  if (state.externalSchedulerKind === 'uperf') return getUperfStateText();
  if (state.externalSchedulerKind === 'multiple') {
    return isExternalSchedulerActive() ? '多个外部调度器可用' : '检测到多个外部调度器';
  }
  switch (state.externalSchedulerState) {
    case 'disabled': return '已禁用';
    case 'pending_update': return '待重启更新';
    case 'pending_remove': return '待重启移除';
    case 'active': return '已安装';
    case 'running': return '运行中';
    default: return hasExternalScheduler() ? '已检测到' : '未检测到';
  }
}

function getSchedulerStatusText() {
  if (state.schedulerMode !== 'active') return '本模块性能调度已关闭 · 仅保留只读状态';
  const boot = state.schedulerBoot;
  if (boot.phase === 'pending_reboot') return `等待重启到${boot.targetMode === 'ugt' ? ' UGT 日常调度' : ' Pixel'}模式`;
  if (boot.phase === 'blocked' || boot.phase === 'failed') return '启动验证未通过，可查看运行记录后重新验证';
  if (boot.phase === 'verifying' || boot.phase === 'applying') return `正在验证 ${boot.targetMode === 'ugt' ? 'UGT' : 'Pixel'} 启动模式`;
  if (boot.phase === 'success' && boot.effectiveMode === 'ugt') return 'UGT 日常调度模式 · 已验证';
  if (boot.phase === 'success' && boot.effectiveMode === 'pixel') return 'Pixel 调度模式 · 已验证';
  const name = getEffectiveSchedulerName();
  const desired = state.schedOwner === 'external' ? 'UGT 启动模式' : 'Pixel 启动模式';
  if (state.schedEffectiveOwner === 'external') {
    if (!hasExternalScheduler()) return `${desired} · 当前无外部调度器运行`;
    const lease = state.effectiveSchedulerKind === 'fas_rs' && (state.arbiterState === 'FAS_LEASED_GAME' || state.arbiterState === 'EXIT_HOLD');
    const current = isExternalSchedulerActive() ? `${name} 接管${getEffectiveSchedulerModeText()}` : `${name} ${getExternalSchedulerStateText()}`;
    return `${desired} · 当前 ${current}${lease ? '（游戏临时接管）' : ''}`;
  }
  return state.schedOwner === 'external' ? 'UGT 模式等待重启验证' : 'Pixel 调度模式 · 当前 Pixel9Pro-Control';
}

function getSchedulerToggleText() {
  if (state.schedOwnerBusy) return '切换中…';
  if (state.schedulerBoot.phase === 'pending_reboot') return '取消切换';
  return state.schedulerBoot.effectiveMode === 'ugt' ? '切换到 Pixel' : '切换到 UGT';
}

function isVerifiedPixelBoot() {
  return state.schedulerMode === 'active'
    && state.schedulerBoot.phase === 'success' && state.schedulerBoot.effectiveMode === 'pixel';
}

function isVerifiedSchedulerBoot() {
  return state.schedulerMode === 'active' && state.schedulerBoot.phase === 'success'
    && (state.schedulerBoot.effectiveMode === 'pixel' || state.schedulerBoot.effectiveMode === 'ugt');
}

function isCurrentStrategyBusy() {
  return state.schedulerOperation.pending || state.profileApplyBusy
    || state.profilePolicyBusy
    || state.schedOwnerBusy
    || state.gameHandoffBusy
    || state.ownerArbiterBusy
    || state.schedulerRetryBusy;
}

function getSchedulerExternalDesc() {
  const name = getEffectiveSchedulerName();
  if (hasExternalScheduler()) {
    const owner = isExternalSchedulerActive() ? `CPU 调度交给 ${name}${getEffectiveSchedulerModeText()}` : `检测到 ${name} (${getExternalSchedulerStateText()})`;
    return `${owner}；本模块的性能档位与自动切档已暂停，避免同时修改 CPU 调度参数。`;
  }
  return '未检测到启用中的外部调度器；本模块保持让权状态，不再周期性写 CPU 调度节点。';
}

function getSchedulerPixelDesc() {
  if (state.uperfDetected && state.fasRsDetected) {
    return `当前日常调度由本模块管理；${getUperfName()} 未接管，fas-rs 仅按游戏策略临时接管。`;
  }
  if (state.uperfDetected) {
    return `检测到 ${getUperfName()}，当前日常调度由本模块管理。`;
  }
  if (state.fasRsDetected) {
    return '日常调度由本模块管理；开启游戏自动接管后，fas-rs 在识别到已配置的游戏时临时接管。';
  }
  return '当前由本模块管理 CPU 调度。';
}

function syncOptionalModuleUi() {
  const available = {
    ugt: state.uperfDetected,
    fas: state.fasRsDetected,
    // The standalone baseband module is device-scoped (caiman/komodo).  Its
    // visibility must not depend on the Control UECap policy or display name.
    baseband: requireFeature('network').isBasebandInstalled(),
  };
  document.querySelectorAll('[data-module-visible]').forEach((element) => {
    const keys = String(element.dataset.moduleVisible || '').split('|').filter(Boolean);
    element.hidden = !keys.some((key) => available[key]);
  });
  if (refs.externalSchedulerHelp) {
    if (available.ugt && available.fas) {
      refs.externalSchedulerHelp.textContent = ' 日常调度可选择 Pixel 或 UGT，切换需重启。开启游戏自动接管后，fas-rs 在识别到已配置的游戏时临时接管，退出后恢复原来的日常调度。';
    } else if (available.ugt) {
      refs.externalSchedulerHelp.textContent = ' 已检测到 UGT；日常调度可选择 Pixel 或 UGT，切换需重启。';
    } else if (available.fas) {
      refs.externalSchedulerHelp.textContent = ' 已检测到 fas-rs；开启游戏自动接管后，在识别到已配置的游戏时临时接管。进程运行中不代表游戏调度已接管。';
    } else {
      refs.externalSchedulerHelp.textContent = '';
    }
  }
}

function syncOwnerArbiterUi() {
  syncOptionalModuleUi();
  const strategyBusy = isCurrentStrategyBusy();
  if (refs.gameHandoffRow) {
    const available = state.fasRsDetected;
    refs.gameHandoffRow.hidden = !available;
    if (available) {
      const enabled = state.gameHandoffPolicy === 'fas_rs';
      refs.gameHandoffLabel.textContent = enabled
        ? (isFasRsRuntimeActive() ? '已开启 · fas-rs 正在接管游戏，退出后恢复日常调度' : '已开启 · 识别到已配置的游戏时，由 fas-rs 临时接管')
        : canCheckGameHandoff() ? '已关闭 · 仍有游戏接管记录，等待恢复日常调度'
          : '已关闭 · 游戏沿用日常调度；开启后允许 fas-rs 临时接管';
      refs.gameHandoffToggleBtn.disabled = state.schedulerMode !== 'active' || strategyBusy || !isVerifiedSchedulerBoot();
      refs.gameHandoffToggleBtn.className = `tiny-btn${enabled ? ' tonal' : ''}`;
      refs.gameHandoffToggleLabel.textContent = state.gameHandoffBusy ? '保存中…' : (enabled ? '关闭' : '开启');
      refs.gameHandoffToggleBtn.title = !isVerifiedSchedulerBoot() ? '日常调度完成启动验证后可修改此设置' : '';
    }
  }
  if (refs.schedulerHealthRow) {
    refs.schedulerHealthRow.hidden = false;
    const health = state.schedulerHealth;
    refs.schedulerHealthLabel.textContent = health.status === 'healthy'
      ? '所选配置与运行状态一致'
      : health.status === 'drift' ? '检测到调度参数变化，当前仅记录，不重复覆盖'
        : health.status === 'blocked' ? '检测到调度状态冲突，检查已暂停'
          : health.status === 'deferred'
            ? (health.reason === 'fas_rs_runtime_lease' || health.reason === 'effective_owner_external'
              ? '检查延后 · 外部调度接管中'
              : '检查延后 · 调度切换中')
            : '等待健康检查';
    refs.schedulerRetryBtn.disabled = state.schedulerMode !== 'active' || strategyBusy || state.schedulerRetryBusy || !['failed', 'blocked'].includes(state.schedulerBoot.phase);
    refs.schedulerRetryLabel.textContent = state.schedulerRetryBusy ? '验证中…' : '重新验证';
  }
  if (!refs.ownerArbiterRow) return;
  const available = state.fasRsDetected;
  refs.ownerArbiterRow.hidden = !available;
  if (!available) return;
  const active = getFasRsStateText();
  refs.ownerArbiterLabel.textContent = state.ownerArbiterBusy
    ? '正在检查调度接管状态…'
    : state.schedulerMode !== 'active' ? '本模块调度已关闭，接管检查不可用'
      : !canCheckGameHandoff() ? '游戏自动接管已关闭，当前没有待处理的游戏接管记录'
        : `fas-rs ${active || '已检测到'}；检查会按当前游戏状态协调接管与恢复`;
  refs.ownerArbiterTickBtn.disabled = state.schedulerMode !== 'active' || strategyBusy || !canCheckGameHandoff();
  refs.ownerArbiterTickLabel.textContent = state.ownerArbiterBusy ? '检查中…' : !canCheckGameHandoff() ? '无需检查' : '立即检查';
}

function canCheckGameHandoff() {
  // Match the CGI prerequisite, including an outstanding lease after disabling.
  return state.gameHandoffPolicy === 'fas_rs' || state.fasRsOwnerState.includes('fas-rs:game:');
}

function syncCurrentStrategyTransitionCopy() {
  let title = '';
  let detail = '';
  if (state.schedOwnerBusy) {
    title = '正在保存日常调度选择';
    detail = '正在保存下次启动使用的调度模式，重启后生效。';
  } else if (state.gameHandoffBusy) {
    title = '正在切换游戏接管';
    detail = '正在保存 fas-rs 游戏接管设置并确认当前调度状态。';
  } else if (state.ownerArbiterBusy) {
    title = '正在检查游戏接管状态';
    detail = '正在检查当前游戏、调度归属和运行参数，并协调接管或恢复。';
  } else if (state.profileApplyBusy) {
    title = '正在切换性能模式';
    detail = '正在应用所选档位，并检查实际调度参数。';
  } else if (state.profilePolicyBusy) {
    title = '正在切换自动 / 手动';
    detail = '正在保存切档方式，并检查当前性能档位。';
  }
  if (!title) return;
  refs.perfCurrentName.textContent = title;
  refs.perfCurrentDesc.textContent = detail;
  refs.perfPolicyDesc.textContent = '完成前请勿重复操作；温控与系统安全保护保持生效。';
}

function syncProfileChoiceSemantics() {
  const policyDetail = document.getElementById('perf-policy-detail');
  if (policyDetail) policyDetail.textContent = refs.perfPolicyDesc.textContent;
  if (state.schedulerMode === 'active' && state.schedEffectiveOwner !== 'external'
      && !isCurrentStrategyBusy() && !['pending_reboot', 'verifying', 'applying'].includes(state.schedulerBoot.phase)
      && !(state.profileTransition.terminal === 'yes' && state.profileTransition.ok === 'no')) {
    refs.perfPolicyDesc.textContent = state.profilePolicy === 'auto'
      ? '自动在均衡与省电之间调整，详细策略可展开查看。'
      : '手动保持当前档位，切换与恢复规则可展开查看。';
  }
  const cards = Array.from(refs.profileList.querySelectorAll('.profile-option'));
  const focusCard = cards.find((card) => card.classList.contains('selected') && !card.classList.contains('disabled'))
    || cards.find((card) => !card.classList.contains('disabled'));
  cards.forEach((card) => {
    const select = card.querySelector('.profile-select');
    if (!select) return;
    select.disabled = card.classList.contains('disabled');
    select.setAttribute('aria-checked', String(card.classList.contains('selected')));
    select.tabIndex = card === focusCard ? 0 : -1;
    card.removeAttribute('aria-checked');
    card.removeAttribute('aria-disabled');
  });
  [refs.profilePolicyManualBtn, refs.profilePolicyAutoBtn].forEach((button) => {
    button.setAttribute('aria-pressed', String(button.classList.contains('active')));
  });
}

function syncProfileUi() {
  const profile = PROFILES[state.currentProfile] || PROFILES.unknown;
  const isAuto = state.profilePolicy === 'auto';
  const isExternal = state.schedEffectiveOwner === 'external';
  const effectiveName = getEffectiveSchedulerName();
  const schedulerPending = ['pending_reboot', 'verifying', 'applying'].includes(state.schedulerBoot.phase);
  const strategyBusy = isCurrentStrategyBusy() || schedulerPending;
  if (state.schedulerMode !== 'active') {
    const off = PROFILES.off;
    refs.topbarProfileChip.textContent = '调度关闭';
    refs.perfCurrentName.textContent = off.name;
    refs.perfCurrentDesc.textContent = off.desc;
    refs.perfPolicyDesc.textContent = state.schedulerCapability === 'supported'
      ? '重新启用需在模块安装向导中选择调度功能，重启后生效。'
      : '尚未确认当前内核支持本模块调度，调度参数修改已停用。';
    refs.profilePolicyManualBtn.className = 'seg-btn';
    refs.profilePolicyAutoBtn.className = 'seg-btn';
    refs.profilePolicyManualBtn.disabled = true;
    refs.profilePolicyAutoBtn.disabled = true;
    refs.schedOwnerLabel.textContent = getSchedulerStatusText();
    refs.schedOwnerToggleBtn.disabled = true;
    refs.schedOwnerToggleLabel.textContent = '调度已关闭';
    refs.hero.className = `hero-card ${off.modeClass}`;
    setStaticHtml(refs.heroIcon, off.hero);
    refs.heroMode.textContent = off.name;
    document.querySelectorAll('.profile-option').forEach((card) => {
      const isOff = card.dataset.profile === 'off';
      card.classList.toggle('selected', isOff);
      card.classList.toggle('disabled', !isOff);
      card.setAttribute('aria-disabled', isOff ? 'false' : 'true');
    });
    syncProfileChoiceSemantics();
    syncOwnerArbiterUi();
    return;
  }
  if (isExternal) {
    refs.topbarProfileChip.textContent = hasExternalScheduler() ? (isExternalSchedulerActive() ? `${effectiveName} 接管` : '外部调度未启用') : '调度让权';
    refs.perfCurrentName.textContent = hasExternalScheduler()
      ? (isExternalSchedulerActive() ? `${effectiveName} 接管${getEffectiveSchedulerModeText()}` : `${effectiveName} ${getExternalSchedulerStateText()}`)
      : '本模块让权中';
    refs.perfCurrentDesc.textContent = getSchedulerExternalDesc();
    refs.perfPolicyDesc.textContent = hasExternalScheduler()
      ? '本模块不覆盖 CPU 调度；手动、自动和模式卡片已暂停。'
      : '未检测到启用中的外部调度器；手动、自动和模式卡片已暂停，本模块只保留让权状态。';
    refs.profilePolicyManualBtn.className = 'seg-btn';
    refs.profilePolicyAutoBtn.className = 'seg-btn';
    refs.profilePolicyManualBtn.disabled = true;
    refs.profilePolicyAutoBtn.disabled = true;
    refs.schedOwnerLabel.textContent = getSchedulerStatusText();
    refs.schedOwnerToggleBtn.className = 'tiny-btn primary';
    refs.schedOwnerToggleBtn.disabled = isCurrentStrategyBusy() || !state.uperfDetected;
    refs.schedOwnerToggleLabel.textContent = getSchedulerToggleText();
    refs.hero.className = 'hero-card mode-game';
    setStaticHtml(refs.heroIcon, PROFILES.performance.hero);
    refs.heroMode.textContent = hasExternalScheduler() ? (isExternalSchedulerActive() ? `${effectiveName} 接管` : '外部调度未启用') : '调度停用';
    document.querySelectorAll('.profile-option').forEach((card) => {
      card.classList.remove('selected');
      card.classList.toggle('disabled', card.dataset.profile !== 'off');
      card.setAttribute('aria-disabled', card.dataset.profile === 'off' ? 'false' : 'true');
    });
    syncCurrentStrategyTransitionCopy();
    syncProfileChoiceSemantics();
    syncOwnerArbiterUi();
    return;
  }
  refs.topbarProfileChip.textContent = isAuto ? `${profile.name} · 自动` : profile.name;
  refs.perfCurrentName.textContent = isAuto ? `${profile.name} · 自动` : profile.name;
  const autoTransitionFailed = isAuto && state.profileTransition.terminal === 'yes' && state.profileTransition.ok === 'no';
  refs.perfCurrentDesc.textContent = isAuto
    ? (autoTransitionFailed ? `${profile.desc} · 自动切档已停止` : `${profile.desc} · ${describeAutoReason(state.autoReason)}`)
    : profile.desc;
  const pixelPolicyDesc = isAuto
    ? (autoTransitionFailed
      ? '自动切档连续失败并已停止；切到手动档后可重新启用自动。'
       : `自动模式在均衡与省电之间切换，当前状态：${describeAutoReason(state.autoReason)}。系统更改调度参数后，本模块仅记录变化。选择下方档位会转为手动。`)
    : `手动模式保持「${profile.name}」。自动模式根据温度与系统温控状态，在均衡和省电之间切换。`;
  refs.perfPolicyDesc.textContent = hasExternalScheduler() ? `${pixelPolicyDesc} ${getSchedulerPixelDesc()}` : pixelPolicyDesc;
  refs.profilePolicyManualBtn.className = `seg-btn${!isAuto ? ' active' : ''}`;
  refs.profilePolicyAutoBtn.className = `seg-btn${isAuto ? ' active' : ''}`;
  refs.profilePolicyManualBtn.disabled = strategyBusy || !isVerifiedPixelBoot();
  refs.profilePolicyAutoBtn.disabled = strategyBusy || !isVerifiedPixelBoot();
  refs.schedOwnerLabel.textContent = getSchedulerStatusText();
  refs.schedOwnerToggleBtn.className = 'tiny-btn';
  refs.schedOwnerToggleBtn.disabled = isCurrentStrategyBusy() || !state.uperfDetected;
  refs.schedOwnerToggleLabel.textContent = getSchedulerToggleText();
  refs.hero.className = `hero-card ${profile.modeClass}`;
  setStaticHtml(refs.heroIcon, profile.hero);
  refs.heroMode.textContent = isAuto ? `${profile.name} · 自动` : profile.name;
  document.querySelectorAll('.profile-option').forEach((card) => {
    const isOff = card.dataset.profile === 'off';
    const disabled = !isOff && (strategyBusy || !isVerifiedPixelBoot());
    card.classList.toggle('disabled', disabled);
    card.setAttribute('aria-disabled', disabled ? 'true' : 'false');
    const selected = card.dataset.profile === state.currentProfile;
    card.classList.toggle('selected', selected);
    card.setAttribute('aria-checked', String(selected));
  });
  syncCurrentStrategyTransitionCopy();
  syncProfileChoiceSemantics();
  syncOwnerArbiterUi();
}

function describeAutoReason(reason) {
  switch (reason) {
    case 'auto_balanced': return '自动均衡运行中';
    case 'steady_hot_guard': return '温度持续偏高，已切换省电';
    case 'hot_cooldown': return '温度已回落，恢复均衡';
    case 'screen_off_reset': return '已息屏，恢复均衡';
    case 'deep_standby_reset': return '深度待机，恢复均衡';
    case 'charging_no_throttle': return '充电状态未触发省电条件，保持均衡';
    case 'charging_thermal_mitigation': return '充电时系统温控介入，已切换省电';
    case 'charging_comfort_hot': return '充电时温度达到切换条件，已切换省电';
    case 'charging_comfort_cooldown': return '充电温度回落，恢复均衡';
    case 'auto_enabled': return '已启用自动调度';
    case 'manual_policy': return '切回手动';
    case 'manual_selected': return '手动指定模式';
    case 'external_scheduler': return '外部调度让权';
    case 'external_no_scheduler_sanitized': return '外部调度让权';
    default: return '自动调度运行中';
  }
}

function applySchedulerOperation(data) {
  const operation = data?.scheduler_operation;
  if (!operation || typeof operation !== 'object') return;
  state.schedulerOperation = {
    id: String(operation.id || ''), kind: String(operation.kind || ''),
    phase: String(operation.phase || 'none'), pending: operation.pending === true,
    resultCode: Number(operation.result_code) || 0
  };
  const notice = document.getElementById('scheduler-operation-notice');
  if (!notice || !state.schedulerOperation.id) return;
  notice.hidden = false;
  const label = ({ retry: '调度验证', handoff: '游戏接管设置', tick: '接管状态检查' })[state.schedulerOperation.kind] || '调度操作';
  notice.textContent = state.schedulerOperation.pending
    ? `${label}已接受，后台正在处理；可以切换页面，稍后刷新查看结果。`
    : state.schedulerOperation.phase === 'success' ? `${label}已完成。`
      : state.schedulerOperation.phase === 'deferred' ? `${label}已延后，亮屏且其他调度操作完成后可重试。`
        : `${label}尚未确认完成，请刷新查看当前状态。错误代码：${state.schedulerOperation.resultCode}。`;
}

function applyProfileState(data) {
  applySchedulerOperation(data);
  state.schedulerMode = ['active', 'off', 'observe'].includes(data.scheduler_mode) ? data.scheduler_mode : 'active';
  state.schedulerCapability = ['supported', 'partial', 'unsupported', 'unknown'].includes(data.scheduler_capability)
    ? data.scheduler_capability : 'unknown';
  state.schedulerCapabilityReason = typeof data.scheduler_capability_reason === 'string' ? data.scheduler_capability_reason : '';
  state.currentProfile = PROFILES[data.profile] ? data.profile : 'unknown';
  state.manualProfile = PROFILES[data.manual_profile] ? data.manual_profile : state.currentProfile;
  state.profilePolicy = data.policy === 'auto' ? 'auto' : 'manual';
  state.schedOwner = data.sched_owner === 'external' ? 'external' : 'pixel';
  state.schedEffectiveOwner = data.sched_effective_owner === 'external' ? 'external' : 'pixel';
  state.gameHandoffPolicy = data.game_handoff_policy === 'fas_rs' ? 'fas_rs' : 'off';
  state.arbiterState = typeof data.arbiter_state === 'string' ? data.arbiter_state : '';
  state.arbiterApplyResult = typeof data.arbiter_apply_result === 'string' ? data.arbiter_apply_result : '';
  state.arbiterReason = typeof data.arbiter_reason === 'string' ? data.arbiter_reason : '';
  state.uperfDetected = boolValue(data.uperf_detected);
  state.uperfModuleId = typeof data.uperf_module_id === 'string' ? data.uperf_module_id : '';
  state.uperfModuleName = typeof data.uperf_module_name === 'string' ? data.uperf_module_name : '';
  state.uperfModulePath = typeof data.uperf_module_path === 'string' ? data.uperf_module_path : '';
  state.uperfModuleSource = typeof data.uperf_module_source === 'string' ? data.uperf_module_source : '';
  state.uperfModuleState = typeof data.uperf_module_state === 'string' ? data.uperf_module_state : '';
  state.uperfModuleEnabled = typeof data.uperf_module_enabled === 'string' ? data.uperf_module_enabled : 'no';
  state.uperfProcessAlive = typeof data.uperf_process_alive === 'string' ? data.uperf_process_alive : 'no';
  state.uperfActive = typeof data.uperf_active === 'string' ? data.uperf_active : 'no';
  state.fasRsDetected = boolValue(data.fas_rs_detected);
  state.fasRsModuleId = typeof data.fas_rs_module_id === 'string' ? data.fas_rs_module_id : '';
  state.fasRsModuleName = typeof data.fas_rs_module_name === 'string' ? data.fas_rs_module_name : '';
  state.fasRsModulePath = typeof data.fas_rs_module_path === 'string' ? data.fas_rs_module_path : '';
  state.fasRsModuleSource = typeof data.fas_rs_module_source === 'string' ? data.fas_rs_module_source : '';
  state.fasRsModuleState = typeof data.fas_rs_module_state === 'string' ? data.fas_rs_module_state : '';
  state.fasRsModuleEnabled = typeof data.fas_rs_module_enabled === 'string' ? data.fas_rs_module_enabled : 'no';
  state.fasRsOwnerState = typeof data.fas_rs_owner_state === 'string' ? data.fas_rs_owner_state : '';
  state.fasRsMode = typeof data.fas_rs_mode === 'string' ? data.fas_rs_mode : '';
  state.fasRsProcessAlive = typeof data.fas_rs_process_alive === 'string' ? data.fas_rs_process_alive : 'no';
  state.fasRsRuntimeState = typeof data.fas_rs_runtime_state === 'string' ? data.fas_rs_runtime_state : '';
  state.fasRsRuntimeOwnerActive = typeof data.fas_rs_runtime_owner_active === 'string' ? data.fas_rs_runtime_owner_active : 'no';
  state.fasRsRuntimeTarget = typeof data.fas_rs_runtime_target === 'string' ? data.fas_rs_runtime_target : '';
  state.fasRsActive = typeof data.fas_rs_active === 'string' ? data.fas_rs_active : 'no';
  state.externalSchedulerDetected = boolValue(data.external_scheduler_detected);
  state.externalSchedulerActive = boolValue(data.external_scheduler_active);
  state.externalSchedulerId = typeof data.external_scheduler_id === 'string' ? data.external_scheduler_id : '';
  state.externalSchedulerName = typeof data.external_scheduler_name === 'string' ? data.external_scheduler_name : '';
  state.externalSchedulerKind = typeof data.external_scheduler_kind === 'string' ? data.external_scheduler_kind : '';
  state.externalSchedulerPath = typeof data.external_scheduler_path === 'string' ? data.external_scheduler_path : '';
  state.externalSchedulerSource = typeof data.external_scheduler_source === 'string' ? data.external_scheduler_source : '';
  state.externalSchedulerState = typeof data.external_scheduler_state === 'string' ? data.external_scheduler_state : '';
  state.externalSchedulerEnabled = typeof data.external_scheduler_enabled === 'string' ? data.external_scheduler_enabled : 'no';
  state.effectiveSchedulerOwner = typeof data.effective_scheduler_owner === 'string' ? data.effective_scheduler_owner : 'pixel';
  state.effectiveSchedulerName = typeof data.effective_scheduler_name === 'string' ? data.effective_scheduler_name : '';
  state.effectiveSchedulerKind = typeof data.effective_scheduler_kind === 'string' ? data.effective_scheduler_kind : '';
  state.effectiveSchedulerMode = typeof data.effective_scheduler_mode === 'string' ? data.effective_scheduler_mode : '';
  state.profileSurface = typeof data.profile_surface === 'string' ? data.profile_surface : 'authoritative';
  state.profileSurfaceStale = boolValue(data.profile_surface_stale);
  state.profileSurfaceNote = typeof data.profile_surface_note === 'string' ? data.profile_surface_note : '';
  if (data.cpu_contract && typeof data.cpu_contract === 'object' && data.cpu_contract.profiles) {
    state.cpuContract = data.cpu_contract;
  }
  if (data.scheduler_boot && typeof data.scheduler_boot === 'object') {
    state.schedulerBoot = {
      targetMode: data.scheduler_boot.target_mode === 'ugt' ? 'ugt' : 'pixel',
      effectiveMode: ['pixel', 'ugt'].includes(data.scheduler_boot.effective_mode) ? data.scheduler_boot.effective_mode : 'unknown',
      phase: typeof data.scheduler_boot.phase === 'string' ? data.scheduler_boot.phase : '',
      final: typeof data.scheduler_boot.final === 'string' ? data.scheduler_boot.final : 'no',
      ok: typeof data.scheduler_boot.ok === 'string' ? data.scheduler_boot.ok : 'pending',
      result: typeof data.scheduler_boot.result === 'string' ? data.scheduler_boot.result : '',
      reason: typeof data.scheduler_boot.reason === 'string' ? data.scheduler_boot.reason : '',
      attempts: Number(data.scheduler_boot.attempts) || 0,
      rebootRequired: typeof data.scheduler_boot.reboot_required === 'string' ? data.scheduler_boot.reboot_required : 'no',
      autoRepairUsed: typeof data.scheduler_boot.auto_repair_used === 'string' ? data.scheduler_boot.auto_repair_used : 'no'
    };
  }
  if (data.scheduler_health && typeof data.scheduler_health === 'object') {
    state.schedulerHealth = {
      status: data.scheduler_health.status || '', reason: data.scheduler_health.reason || '',
      checkedEpoch: data.scheduler_health.checked_epoch || '', profileVerified: data.scheduler_health.profile_verified || '',
      cpufreqPermissions: data.scheduler_health.cpufreq_permissions || '', powerhalFailures: data.scheduler_health.powerhal_failures || ''
    };
  }
  if (data.profile_transition && typeof data.profile_transition === 'object') {
    state.profileTransition = {
      key: data.profile_transition.key || '', attempts: Number(data.profile_transition.attempts) || 0,
      firstEpoch: data.profile_transition.first_epoch || '', deadlineEpoch: data.profile_transition.deadline_epoch || '',
      terminal: data.profile_transition.terminal || 'no', ok: data.profile_transition.ok || 'pending',
      result: data.profile_transition.result || ''
    };
  }
  state.autoReason = typeof data.auto_reason === 'string' ? data.auto_reason : '';
  syncProfileUi();
  syncHeroDesc();
}

function applyProfileMutationState(data) {
  applySchedulerOperation(data);
  latestProfileMutationState = data;
  profileMutationStateRevision += 1;
  if (['active', 'off', 'observe'].includes(data.scheduler_mode)) state.schedulerMode = data.scheduler_mode;
  if (['supported', 'partial', 'unsupported', 'unknown'].includes(data.scheduler_capability)) {
    state.schedulerCapability = data.scheduler_capability;
  }
  if (PROFILES[data.profile]) state.currentProfile = data.profile;
  if (PROFILES[data.manual_profile]) state.manualProfile = data.manual_profile;
  if (data.policy === 'auto' || data.policy === 'manual') state.profilePolicy = data.policy;
  if (data.sched_owner === 'external' || data.sched_owner === 'pixel') state.schedOwner = data.sched_owner;
  if (data.sched_effective_owner === 'external' || data.sched_effective_owner === 'pixel') {
    state.schedEffectiveOwner = data.sched_effective_owner;
  }
  if (data.game_handoff_policy === 'fas_rs' || data.game_handoff_policy === 'off') {
    state.gameHandoffPolicy = data.game_handoff_policy;
  }
  if (typeof data.arbiter_state === 'string') state.arbiterState = data.arbiter_state;
  if (typeof data.arbiter_apply_result === 'string') state.arbiterApplyResult = data.arbiter_apply_result;
  if (typeof data.arbiter_reason === 'string') state.arbiterReason = data.arbiter_reason;
  if (typeof data.auto_reason === 'string') state.autoReason = data.auto_reason;
  if (data.scheduler_boot && typeof data.scheduler_boot === 'object') {
    const boot = data.scheduler_boot;
    state.schedulerBoot = {
      ...state.schedulerBoot,
      ...(typeof boot.target_mode === 'string' ? { targetMode: boot.target_mode === 'ugt' ? 'ugt' : 'pixel' } : {}),
      ...(typeof boot.effective_mode === 'string'
        ? { effectiveMode: ['pixel', 'ugt'].includes(boot.effective_mode) ? boot.effective_mode : 'unknown' }
        : {}),
      ...(typeof boot.phase === 'string' ? { phase: boot.phase } : {}),
      ...(typeof boot.final === 'string' ? { final: boot.final } : {}),
      ...(typeof boot.ok === 'string' ? { ok: boot.ok } : {}),
      ...(typeof boot.result === 'string' ? { result: boot.result } : {}),
      ...(typeof boot.reason === 'string' ? { reason: boot.reason } : {}),
      ...(boot.attempts !== undefined ? { attempts: Number(boot.attempts) || 0 } : {}),
      ...(typeof boot.reboot_required === 'string' ? { rebootRequired: boot.reboot_required } : {}),
      ...(typeof boot.auto_repair_used === 'string' ? { autoRepairUsed: boot.auto_repair_used } : {})
    };
  }
  if (data.scheduler_health && typeof data.scheduler_health === 'object') {
    state.schedulerHealth = {
      status: data.scheduler_health.status || '', reason: data.scheduler_health.reason || '',
      checkedEpoch: data.scheduler_health.checked_epoch || '', profileVerified: data.scheduler_health.profile_verified || '',
      cpufreqPermissions: data.scheduler_health.cpufreq_permissions || '', powerhalFailures: data.scheduler_health.powerhal_failures || ''
    };
  }
  if (data.profile_transition && typeof data.profile_transition === 'object') {
    state.profileTransition = {
      key: data.profile_transition.key || '', attempts: Number(data.profile_transition.attempts) || 0,
      firstEpoch: data.profile_transition.first_epoch || '', deadlineEpoch: data.profile_transition.deadline_epoch || '',
      terminal: data.profile_transition.terminal || 'no', ok: data.profile_transition.ok || 'pending',
      result: data.profile_transition.result || ''
    };
  }
  syncProfileUi();
  syncHeroDesc();
}

function renderProfileCards() {
  refs.profileList.replaceChildren();
  refs.profileList.setAttribute('role', 'radiogroup');
  refs.profileList.setAttribute('aria-label', '性能模式');
  ['battery', 'balanced', 'default', 'off'].forEach((key) => {
    const p = PROFILES[key];
    const card = document.createElement('article');
    card.className = 'profile-card profile-option';
    card.dataset.profile = key;
    const detailAction = `
        <button class="card-info" type="button" data-action="profile-detail" data-profile="${key}" aria-label="查看${p.name}详情">
          说明
        </button>`;
    setStaticHtml(card, `
      <button class="profile-select" type="button" role="radio" aria-checked="${key === state.currentProfile}" aria-labelledby="profile-name-${key}" aria-describedby="profile-desc-${key}">
        <span class="profile-icon" aria-hidden="true">${p.icon}</span>
        <span class="profile-copy">
          <span class="profile-name" id="profile-name-${key}">${p.name}</span>
          <span class="profile-desc" id="profile-desc-${key}">${p.summary}</span>
        </span>
        <span class="p-check" aria-hidden="true"><svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg></span>
      </button>${detailAction}`);
    const select = card.querySelector('.profile-select');
    select.addEventListener('click', () => {
      if (card.classList.contains('disabled')) return;
      if (key === 'off') setSchedulerMode('off');
      else applyProfile(key);
    });
    select.addEventListener('keydown', (evt) => {
      if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End'].includes(evt.key)) return;
      evt.preventDefault();
      const items = Array.from(refs.profileList.querySelectorAll('.profile-select:not(:disabled)'));
      const step = ['ArrowLeft', 'ArrowUp'].includes(evt.key) ? -1 : 1;
      const index = evt.key === 'Home' ? 0 : evt.key === 'End' ? items.length - 1 : (items.indexOf(select) + step + items.length) % items.length;
      items[index]?.focus();
      // Arrows explore choices; Enter/Space explicitly commits device changes.
      items.forEach((item) => { item.tabIndex = item === items[index] ? 0 : -1; });
    });
    refs.profileList.appendChild(card);
  });
  syncProfileChoiceSemantics();
}

function ensureHomeCpuRows(clusters) {
  if (state.homeCpuRows && state.homeCpuRows.length === clusters.length) return;
  refs.homeCpuRows.replaceChildren();
  state.homeCpuRows = clusters.map((cluster, index) => {
    const row = document.createElement('div');
    row.className = 'home-cpu-row';
    const label = document.createElement('span');
    label.className = 'home-cpu-label';
    label.textContent = HOME_CPU_LABELS[index] || `C${index}`;
    const bar = document.createElement('div');
    bar.className = 'home-cpu-bar';
    const fill = document.createElement('div');
    fill.className = 'home-cpu-fill';
    bar.appendChild(fill);
    const freq = document.createElement('span');
    freq.className = 'home-cpu-freq';
    row.append(label, bar, freq);
    refs.homeCpuRows.appendChild(row);
    return { fill, freq };
  });
}

function ensurePerfCpuRows(clusters) {
  if (state.cpuRows && state.cpuRows.length === clusters.length) return;
  refs.cpuRows.replaceChildren();
  state.cpuRows = clusters.map((cluster, index) => {
    const row = document.createElement('div');
    row.className = 'cpu-row';
    const head = document.createElement('div');
    head.className = 'cpu-row-head';
    const label = document.createElement('span');
    label.className = 'cpu-label';
    label.textContent = CLUSTERS[index]?.label || `cpu${cluster.cpu}`;
    const freq = document.createElement('span');
    freq.className = 'cpu-freq';
    const current = document.createElement('b');
    const max = document.createElement('span');
    freq.append(current, max);
    head.append(label, freq);
    const track = document.createElement('div');
    track.className = 'cpu-bar-track';
    const fill = document.createElement('div');
    fill.className = 'cpu-bar-fill';
    track.appendChild(fill);
    const params = document.createElement('div');
    params.className = 'cpu-params';
    row.append(head, track, params);
    refs.cpuRows.appendChild(row);
    return { current, max, fill, params };
  });
}

let profileFullStateGeneration = 0;
let profileMutationStateRevision = 0;
let latestProfileMutationState = null;

function invalidateFullProfileStateRefresh() {
  profileFullStateGeneration += 1;
}

function refreshFullProfileState() {
  const generation = ++profileFullStateGeneration;
  const mutationRevision = profileMutationStateRevision;
  return apiFetch(API.profile, { timeoutMs: SCHEDULER_READ_TIMEOUTS.full, priority: 'background', scope: 'profile.full.read' })
    .then((fullState) => {
      if (generation !== profileFullStateGeneration) return false;
      const newerMutationState = mutationRevision !== profileMutationStateRevision
        ? latestProfileMutationState
        : null;
      applyProfileState(fullState);
      if (newerMutationState) applyProfileMutationState(newerMutationState);
      return true;
    })
    .catch((err) => isCancelled(err) ? null : false);
}

async function confirmProfileMutation(expected) {
  const data = await apiFetch(`${API.profile}?compact=1`, { timeoutMs: SCHEDULER_READ_TIMEOUTS.compact, dedupe: false, priority: 'interactive', scope: 'profile.mutation.readback' });
  if (!data || data.ok === false) return false;
  applyProfileMutationState(data);
  const confirmed = typeof expected === 'function' ? expected() : true;
  if (confirmed) void refreshFullProfileState();
  return confirmed;
}

function reconcileProfileCommit(expected, message) {
  const revision = profileMutationStateRevision;
  const notice = document.getElementById('profile-operation-notice');
  if (notice) { notice.hidden = false; notice.textContent = `${message}，正在后台补充读取。`; }
  void apiFetch(`${API.profile}?compact=1`, { timeoutMs: SCHEDULER_READ_TIMEOUTS.compact,
    dedupe: false, priority: 'normal', scope: 'profile.commit.readback' })
    .then((readback) => {
      if (revision !== profileMutationStateRevision) return;
      if (!readback || readback.ok === false) throw new Error('状态响应无效');
      applyProfileMutationState(readback);
      const confirmed = expected();
      if (notice) notice.textContent = confirmed ? message : `${message}；当前状态未对齐，请刷新核对。`;
    })
    .catch((error) => {
      if (revision === profileMutationStateRevision && notice) notice.textContent = `${message}；补充读取${isCancelled(error) ? '已暂停' : '失败'}，可刷新核对。`;
    });
}

async function loadSavedProfile() {
  try {
    const revision = profileMutationStateRevision;
    const data = await apiFetch(`${API.profile}?compact=1`, { timeoutMs: SCHEDULER_READ_TIMEOUTS.compact, priority: 'normal', scope: 'profile.read' });
    if (revision === profileMutationStateRevision) applyProfileMutationState(data);
    void refreshFullProfileState();
    return true;
  } catch (err) {
    if (isCancelled(err)) return null;
    state.currentProfile = 'unknown';
    state.schedulerMode = 'off';
    state.schedulerCapability = 'unknown';
    state.schedulerCapabilityReason = 'state_unavailable';
    state.manualProfile = 'balanced';
    state.profilePolicy = 'manual';
    state.schedOwner = 'pixel';
    state.schedEffectiveOwner = 'pixel';
    state.gameHandoffPolicy = 'off';
    state.arbiterState = '';
    state.arbiterApplyResult = '';
    state.arbiterReason = '';
    state.uperfDetected = false;
    state.uperfModuleId = '';
    state.uperfModuleName = '';
    state.uperfModulePath = '';
    state.uperfModuleSource = '';
    state.uperfModuleState = '';
    state.uperfModuleEnabled = 'no';
    state.uperfProcessAlive = 'no';
    state.uperfActive = 'no';
    state.fasRsDetected = false;
    state.fasRsModuleId = '';
    state.fasRsModuleName = '';
    state.fasRsModulePath = '';
    state.fasRsModuleSource = '';
    state.fasRsModuleState = '';
    state.fasRsModuleEnabled = 'no';
    state.fasRsOwnerState = '';
    state.fasRsMode = '';
    state.fasRsProcessAlive = 'no';
    state.fasRsRuntimeState = '';
    state.fasRsRuntimeOwnerActive = 'no';
    state.fasRsRuntimeTarget = '';
    state.fasRsActive = 'no';
    state.externalSchedulerDetected = false;
    state.externalSchedulerActive = false;
    state.externalSchedulerId = '';
    state.externalSchedulerName = '';
    state.externalSchedulerKind = '';
    state.externalSchedulerPath = '';
    state.externalSchedulerSource = '';
    state.externalSchedulerState = '';
    state.externalSchedulerEnabled = 'no';
    state.effectiveSchedulerOwner = 'pixel';
    state.effectiveSchedulerName = 'Pixel9Pro-Control';
    state.effectiveSchedulerKind = 'pixel';
    state.effectiveSchedulerMode = '';
    state.profileSurface = 'authoritative';
    state.profileSurfaceStale = false;
    state.profileSurfaceNote = '';
    state.autoReason = '';
    syncProfileUi();
    syncHeroDesc();
    return false;
  }
}

async function refreshCpuTask() {
  state.cpuBusy = true;
  if (refs.refreshBtn) refs.refreshBtn.disabled = true;
  try {
    const clusters = await apiFetch(API.status, { timeoutMs: SCHEDULER_READ_TIMEOUTS.cpu, priority: 'normal', scope: 'profile.cpu.read' });
    state.lastClusters = clusters;
    ensurePerfCpuRows(clusters);
    ensureHomeCpuRows(clusters);
    clusters.forEach((cluster, index) => {
      const perf = state.cpuRows[index];
      const home = state.homeCpuRows[index];
      const maxHz = Number.isFinite(cluster.max) && cluster.max > 0 ? cluster.max : null;
      const current = Number.isFinite(cluster.cur) && cluster.cur > 0 ? cluster.cur : null;
      const scale = maxHz && current ? Math.min(current / maxHz, 1) : 0;
      perf.current.textContent = current ? `${(current / 1000).toFixed(0)} MHz` : '—';
      perf.max.textContent = maxHz ? ` / ${(maxHz / 1000).toFixed(0)} MHz` : ' / —';
      perf.fill.style.transform = `scaleX(${scale.toFixed(3)})`;
      const respText = typeof cluster.resp_ms_text === 'string' ? cluster.resp_ms_text : cluster.resp_ms;
      const downText = typeof cluster.down_us_text === 'string' ? cluster.down_us_text : cluster.down_us;
      perf.params.textContent = `响应 ${formatSchedValue(respText, 'ms')} · 降频间隔 ${formatSchedValue(downText, 'µs')} · 调频器 ${cluster.gov}`;
      home.freq.textContent = current ? `${(current / 1000).toFixed(0)} MHz` : '—';
      home.fill.style.transform = `scaleX(${scale.toFixed(3)})`;
    });
    const mutationRevision = profileMutationStateRevision;
    try {
      const profileData = await apiFetch(`${API.profile}?compact=1`, { timeoutMs: SCHEDULER_READ_TIMEOUTS.compact, priority: 'background', scope: 'profile.read' });
      if (mutationRevision === profileMutationStateRevision) applyProfileMutationState(profileData);
    } catch (err) { if (!isCancelled(err)) {} }
    return true;
  } catch (err) {
    if (isCancelled(err)) return null;
    state.cpuRows = null;
    state.homeCpuRows = null;
    const el = document.createElement('div');
    el.className = 'error-panel';
    const title = document.createElement('strong');
    title.textContent = '获取频率失败';
    const detail = document.createElement('pre');
    detail.textContent = err.message;
    el.append(title, detail);
    refs.cpuRows.replaceChildren();
    refs.cpuRows.appendChild(el);
    appendLog(`CPU 频率读取失败：${err.message}`, 'err');
    return false;
  } finally {
    if (refs.refreshBtn) refs.refreshBtn.disabled = false;
    state.cpuBusy = false;
  }
}

async function refreshCpu() {
  return core().runFeatureTask('profile.cpu.refresh', () => refreshCpuTask());
}

async function applyProfile(profile) {
  if (state.schedulerMode !== 'active') {
    showToast('本模块性能调度已关闭；重新启用请通过模块安装向导');
    return;
  }
  if (state.schedOwner === 'external') {
    showToast(hasExternalScheduler() ? getSchedulerStatusText() : '本模块调度未启用');
    appendLog(hasExternalScheduler()
      ? `${getSchedulerStatusText()}，未切换本模块 profile`
      : '本模块 CPU 调度未启用，未切换 profile', 'warn');
    return;
  }
  if (profile === state.currentProfile || isCurrentStrategyBusy()) return;
  const prevPolicy = state.profilePolicy;
  const card = refs.profileList.querySelector(`[data-profile="${profile}"]`);
  if (!card) return;
  state.profileApplyBusy = true;
  invalidateFullProfileStateRefresh();
  syncProfileUi();
  card.classList.add('loading');
  appendLog(`切换到 ${PROFILES[profile].name}…`, 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.profile, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ profile }), timeoutMs: PROFILE_MUTATION_TIMEOUT_MS, priority: 'interactive', scope: 'profile.mutation' });
    if (data.ok) {
      applyProfileMutationState(data);
      if (data.final !== true || data.profile !== profile) throw new Error('后端未确认目标档位提交');
      reconcileProfileCommit(() => state.currentProfile === profile, `已保存：${PROFILES[profile].name}`);
      const forcedManual = prevPolicy === 'auto' && data.policy === 'manual';
      showToast(forcedManual ? `已切回手动：${PROFILES[profile].name}` : `切换至：${PROFILES[profile].name}`);
      appendLog(forcedManual ? `自动已退出，手动切到 ${PROFILES[profile].name}` : `${PROFILES[profile].name} 已应用`, 'ok');
      refreshCpu();
    } else {
      showToast(`切换失败：${data.error || '未知'}`);
      appendLog(data.error || '切换失败', 'err');
    }
  } catch (err) {
    showToast(`请求失败：${err?.message || '服务未返回有效响应'}`);
    appendLog(String(err), 'err');
  } finally {
    card.classList.remove('loading');
    state.profileApplyBusy = false;
    syncProfileUi();
  }
}

async function setSchedulerMode(mode) {
  if (isCurrentStrategyBusy() || mode === state.schedulerMode) return;
  state.profileApplyBusy = true;
  invalidateFullProfileStateRefresh();
  syncProfileUi();
  const body = { scheduler_mode: mode };
  try {
    const data = await apiFetch(API.profile, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body), timeoutMs: 25000, priority: 'interactive', scope: 'profile.mutation'
    });
    if (data.ok) {
      applyProfileMutationState(data);
      if (data.final !== true || data.scheduler_mode !== mode) throw new Error('后端未确认调度模式提交');
      reconcileProfileCommit(() => state.schedulerMode === mode, '调度模式已保存');
      const label = '本模块性能调度已关闭';
      showToast(data.reboot_required ? `${label}，重启后完成切换` : label);
      appendLog(`${label} · ${data.cleanup_result || 'state_committed'}`, data.reboot_required ? 'warn' : 'ok');
    } else {
      showToast(`调度模式切换失败：${data.error || '未知'}`);
    }
  } catch (err) {
    showToast(`调度模式切换失败：${err.message || err}`);
    appendLog(String(err), 'err');
  } finally {
    state.profileApplyBusy = false;
    syncProfileUi();
  }
}

async function setProfilePolicy(policy) {
  if (state.schedulerMode !== 'active') {
    showToast('本模块性能调度已关闭');
    return;
  }
  if (state.schedOwner === 'external') {
    showToast(hasExternalScheduler() ? getSchedulerStatusText() : '本模块调度未启用');
    appendLog(hasExternalScheduler()
      ? `${getSchedulerStatusText()}，自动/手动策略暂停`
      : '本模块 CPU 调度未启用，自动/手动策略暂停', 'warn');
    return;
  }
  if (state.profilePolicy === policy || isCurrentStrategyBusy()) return;
  state.profilePolicyBusy = true;
  invalidateFullProfileStateRefresh();
  syncProfileUi();
  appendLog(policy === 'auto' ? '启用自动调度…' : '切回手动调度…', 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.profile, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ policy }),
      timeoutMs: PROFILE_MUTATION_TIMEOUT_MS, priority: 'interactive', scope: 'profile.mutation'
    });
    if (data.ok) {
      applyProfileMutationState(data);
      if (data.final !== true || data.policy !== policy) throw new Error('后端未确认策略提交');
      reconcileProfileCommit(() => state.profilePolicy === policy, policy === 'auto' ? '自动策略已保存' : '手动策略已保存');
      showToast(policy === 'auto' ? '已启用自动调度' : `已切回手动：${PROFILES[state.currentProfile].name}`);
      appendLog(policy === 'auto'
        ? `自动调度已启用：${describeAutoReason(state.autoReason)}`
        : `已切回手动：${PROFILES[state.currentProfile].name}`, 'ok');
      refreshCpu();
    } else {
      showToast(`切换失败：${data.error || '未知'}`);
      appendLog(data.error || '切换失败', 'err');
    }
  } catch (err) {
    showToast(`请求失败：${err?.message || '服务未返回有效响应'}`);
    appendLog(String(err), 'err');
  } finally {
    state.profilePolicyBusy = false;
    syncProfileUi();
  }
}

async function toggleSchedOwner() {
  if (isCurrentStrategyBusy()) return;
  if (state.schedulerBoot.phase === 'pending_reboot') {
    await cancelSchedulerChange();
    return;
  }
  const nextOwner = state.schedulerBoot.effectiveMode === 'ugt' ? 'pixel' : 'external';
  state.schedOwnerBusy = true;
  invalidateFullProfileStateRefresh();
  syncProfileUi();
  const actionText = nextOwner === 'external'
    ? '提交 UGT 日常调度模式…'
    : '提交 Pixel 调度启动模式…';
  appendLog(actionText, 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.profile, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sched_owner: nextOwner }),
      timeoutMs: 25000, priority: 'interactive', scope: 'profile.mutation'
    });
    if (typeof data.sched_owner === 'string') applyProfileMutationState(data);
    if (data.ok && data.final === false) {
      showToast('启动模式已提交，重启后验证');
      appendLog(nextOwner === 'external'
        ? 'UGT 已设为下次启动日常基线；当前 boot 不启动 UGT'
        : 'UGT 已设为下次启动禁用；重启后验证 Pixel 控制面', 'warn');
      openRebootModal(null, null, 'scheduler');
    } else {
      const detail = data.scheduler_boot?.reason || data.error || '启动状态提交失败';
      showToast(`切换未完成：${detail}`);
      appendLog(`启动模式未提交：${detail}`, 'err');
    }
  } catch (err) {
    showToast(`请求失败：${err?.message || '服务未返回有效响应'}`);
    appendLog(String(err), 'err');
  } finally {
    state.schedOwnerBusy = false;
    syncProfileUi();
    void refreshFullProfileState();
  }
}

async function cancelSchedulerChange() {
  if (isCurrentStrategyBusy()) return;
  state.schedOwnerBusy = true;
  invalidateFullProfileStateRefresh();
  syncProfileUi();
  const notice = document.getElementById('scheduler-operation-notice');
  if (requireFeature('ui').getRebootContext() === 'scheduler') requireFeature('ui').setRebootBusy(true);
  if (notice) { notice.hidden = false; notice.textContent = '正在提交取消请求，可以关闭弹窗或切换页面。'; }
  try {
    const data = await apiFetch(API.profile, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ scheduler_action: 'cancel_pending' }), timeoutMs: 25000, priority: 'interactive', scope: 'profile.mutation'
    });
    if (data.scheduler_boot) applyProfileMutationState(data);
    if (data.ok) {
      if (state.schedulerBoot.final !== 'yes' || state.schedulerBoot.phase !== 'success') throw new Error('取消回执未确认终态，请刷新核对');
      if (requireFeature('ui').getRebootContext() === 'scheduler') {
        requireFeature('ui').closeRebootModal('', { force: true, silent: true });
      }
      showToast('已取消待重启切换');
      appendLog('调度启动模式已恢复到本次 boot 的状态', 'ok');
      if (notice) notice.textContent = '取消已提交并由后端确认，正在后台补充读取。';
      const revision = profileMutationStateRevision;
      void apiFetch(`${API.profile}?compact=1`, { timeoutMs: SCHEDULER_READ_TIMEOUTS.compact, dedupe: false, priority: 'normal', scope: 'profile.cancel.readback' })
        .then((readback) => {
          if (revision !== profileMutationStateRevision) return;
          applyProfileMutationState(readback);
          const confirmed = state.schedulerBoot.final === 'yes' && state.schedulerBoot.phase === 'success';
          if (notice) notice.textContent = confirmed ? '已取消待重启切换。' : '取消已提交，后续状态未确认；可刷新核对。';
        })
        .catch((error) => {
          if (revision === profileMutationStateRevision && notice) notice.textContent = `取消已提交，补充读取${isCancelled(error) ? '已暂停' : '失败'}；可刷新核对，不会重新提交。`;
        });
    } else {
      showToast(`取消失败：${data.error || data.scheduler_boot?.reason || '未知'}`);
      appendLog(data.error || '取消待重启切换失败', 'err');
    }
  } catch (err) {
    if (notice) notice.textContent = `取消请求未确认：${err?.message || '服务未返回有效响应'}。请先刷新核对。`;
    if (requireFeature('ui').getRebootContext() === 'scheduler') requireFeature('ui').setRebootError(notice?.textContent || String(err));
    showToast(`请求失败：${err?.message || '服务未返回有效响应'}`);
    appendLog(String(err), 'err');
  } finally {
    state.schedOwnerBusy = false;
    if (requireFeature('ui').getRebootContext() === 'scheduler') requireFeature('ui').setRebootBusy(false);
    syncProfileUi();
    void refreshFullProfileState();
  }
}

async function retrySchedulerValidation() {
  if (isCurrentStrategyBusy()) return;
  state.schedulerRetryBusy = true;
  invalidateFullProfileStateRefresh();
  syncProfileUi();
  try {
    const data = await apiFetch(API.profile, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ scheduler_action: 'retry' }), timeoutMs: 45000, priority: 'interactive', scope: 'profile.mutation'
    });
    if (data.scheduler_boot || data.scheduler_operation) applyProfileMutationState(data);
    if (data.accepted && data.final === false) {
      showToast('验证任务已接受，后台继续处理');
      appendLog('调度验证已转为一次性后台任务，可离开页面', 'dim');
    } else if (data.ok) {
      if (!await confirmProfileMutation(() => state.schedulerBoot.final === 'yes')) throw new Error('验证请求已提交，尚未确认最终调度状态');
      showToast('调度启动状态验证通过');
      appendLog(`调度终态：${data.scheduler_boot?.result || 'success'}`, 'ok');
    } else {
      showToast(`验证失败：${data.scheduler_boot?.reason || data.error || '未知'}`);
      appendLog(`调度终态失败：${data.scheduler_boot?.result || data.error || 'unknown'}`, 'err');
    }
  } catch (err) {
    showToast(`请求失败：${err?.message || '服务未返回有效响应'}`);
    appendLog(String(err), 'err');
  } finally {
    state.schedulerRetryBusy = false;
    syncProfileUi();
    void refreshFullProfileState();
  }
}

async function toggleGameHandoff() {
  if (isCurrentStrategyBusy() || !state.fasRsDetected || !isVerifiedSchedulerBoot()) return;
  const nextPolicy = state.gameHandoffPolicy === 'fas_rs' ? 'off' : 'fas_rs';
  state.gameHandoffBusy = true;
  invalidateFullProfileStateRefresh();
  syncProfileUi();
  appendLog(nextPolicy === 'fas_rs' ? '启用 fas-rs 游戏临时接管…' : '关闭 fas-rs 游戏临时接管…', 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.profile, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ game_handoff: nextPolicy }),
      timeoutMs: 45000, priority: 'interactive', scope: 'profile.mutation'
    });
    if (typeof data.game_handoff_policy === 'string') applyProfileMutationState(data);
    if (data.accepted && data.final === false) {
      showToast('接管偏好已保存，等待调度状态同步');
      appendLog(data.pending_reason || '共享调度事务正在执行，后台将继续同步', 'warn');
    } else if (data.ok) {
      reconcileProfileCommit(() => state.gameHandoffPolicy === nextPolicy, '游戏自动接管设置已保存');
      showToast(nextPolicy === 'fas_rs' ? 'fas-rs 游戏接管已启用' : 'fas-rs 游戏接管已关闭');
      appendLog(nextPolicy === 'fas_rs'
        ? 'fas-rs 已获准在识别到已配置的游戏时临时接管，退出后恢复日常调度'
        : '游戏场景保持日常调度选择', 'ok');
      await refreshCpu();
    } else {
      const detail = data.arbiter_apply_result || data.error || '状态复读未通过';
      showToast(`切换未完成：${detail}`);
      appendLog(detail, 'err');
    }
  } catch (err) {
    showToast(`请求失败：${err?.message || '服务未返回有效响应'}`);
    appendLog(String(err), 'err');
  } finally {
    state.gameHandoffBusy = false;
    syncProfileUi();
  }
}

async function triggerOwnerArbiter() {
  if (isCurrentStrategyBusy() || !state.fasRsDetected) return;
  if (!canCheckGameHandoff()) {
    showToast('游戏自动接管已关闭，当前无需检查');
    syncOwnerArbiterUi();
    return;
  }
  state.ownerArbiterBusy = true;
  syncProfileUi();
  appendLog('正在检查外部调度接管状态…', 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.ownerArbiter, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'tick' }),
      timeoutMs: SCHEDULER_READ_TIMEOUTS.owner, priority: 'interactive', scope: 'profile.owner'
    });
    if (data.scheduler_operation) applySchedulerOperation(data);
    if (data.accepted && data.final === false) {
      showToast('接管检查已开始，完成后可刷新查看结果');
      appendLog('接管状态检查已交由后台处理', 'dim');
    } else if (data.ok) {
      showToast('调度状态已更新');
      appendLog('外部调度接管状态已更新', 'ok');
      await loadSavedProfile();
      await refreshCpu();
    } else {
      showToast(`检查失败：${data.error || '未知'}`);
      appendLog(data.error || '外部调度状态检查失败', 'err');
    }
  } catch (err) {
    showToast(`检查未完成：${err?.message || '服务未返回有效响应'}`);
    appendLog(String(err), 'err');
  } finally {
    state.ownerArbiterBusy = false;
    syncProfileUi();
    void loadSavedProfile();
  }
}

registerFeature('profile', {
  initialize: renderProfileCards,
  load: loadSavedProfile,
  refresh: refreshCpu,
  isRefreshing: () => state.cpuBusy,
  isBusy: isCurrentStrategyBusy,
  syncOptionalModuleUi,
  getSchedulerBootTargetMode: () => state.schedulerBoot.targetMode,
  getThermalContext: () => ({
    schedulerMode: state.schedulerMode,
    schedEffectiveOwner: state.schedEffectiveOwner,
    hasExternalScheduler: hasExternalScheduler(),
    externalSchedulerActive: isExternalSchedulerActive()
  }),
  getCpuDetailState: () => ({
    currentProfile: state.currentProfile,
    cpuContract: state.cpuContract,
    schedOwner: state.schedOwner,
    lastClusters: state.lastClusters
  }),
  buildProfileDetail,
  formatSchedValue,
  getSchedulerStatusText,
  setProfilePolicy,
  toggleSchedOwner,
  retrySchedulerValidation,
  toggleGameHandoff,
  triggerOwnerArbiter,
  cancelSchedulerChange
});
})();
