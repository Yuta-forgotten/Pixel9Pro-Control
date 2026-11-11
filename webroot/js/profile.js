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
  if (key === 'off') return `<p>${profile.desc}</p><p>如需重新启用，请在模块安装向导中选择调度功能，重启后检查生效状态。</p>`;
  const contract = state.cpuContract;
  const values = contract?.profiles?.[key];
  let html = `<b>${profile.name}</b><br><br>${profile.detail}`;
  if (!values || !contract) return `${html}<br><br>运行参数尚未读取。`;
  const response = Array.isArray(values.response_ms)
    ? values.response_ms.map((value) => `${value}ms`).join(' / ')
    : '使用内核标称响应时间，具体数值尚未获取';
  const foreground = contract.foreground_cpus || contract.cpusets?.foreground?.cpus || '未获取';
  const background = contract.background_cpus || contract.cpusets?.background?.cpus || '未获取';
  const systemBackground = contract.system_background_cpus || contract.cpusets?.system_background?.cpus || background;
  html += `<br><br><b>CPU 核心分配（cpuset）</b><br>前台应用核心：${escapeHtml(values.top_app_cpus || '未获取')}<br>后台应用核心：${escapeHtml(background)}<br>系统后台进程核心：${escapeHtml(systemBackground)}`;
  html += `<br>普通前台进程：${escapeHtml(foreground)}，由系统管理`;
  html += `<br><b>小核 / 中核 / 大核响应时间</b>：${escapeHtml(response)}`;
  html += `<br><b>任务性能请求上限（sched_util_clamp_min）</b>：${Number.isFinite(values.uclamp_cap) ? values.uclamp_cap : '尚未读取'}`;
  html += `<br><b>状态检查</b>：应用后立即检查，之后每 ${Number(contract.health_interval_s) || 300} 秒读取一次。系统后续修改参数时，模块记录差异，不自动重新应用。`;
  return html;
}

// 共享布尔值兼容 CGI 的 true/yes/1 表达；profile state 仍只保留在本模块私有 scope。
function boolValue(value) {
  return value === true || value === 'true' || value === 'yes' || value === 1 || value === '1';
}

function formatSchedValue(value, unit) {
  if (value === null || value === undefined || value === '' || value === 'N/A' || value === 'na') return '未提供';
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
    return state.fasRsMode ? `进程运行，未接管游戏 · ${state.fasRsMode}` : '进程运行，未接管游戏';
  }
  switch (state.fasRsRuntimeState || state.fasRsModuleState) {
    case 'disabled_marker': return '已暂停';
    case 'disabled': return '已禁用';
    case 'pending_update': return '待重启更新';
    case 'pending_remove': return '待重启移除';
    case 'stale_game_lease': return '游戏接管记录已失效';
    case 'stale_owner_state': return '运行记录已过期';
    case 'module_enabled': return '已启用，尚未确认进程状态';
    case 'runtime_present': return '运行状态已检测，接管状态未确认';
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
    return isExternalSchedulerActive() ? '已检测到多个外部调度器，当前有调度程序运行' : '已检测到多个外部调度器';
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
  if (state.schedulerMode !== 'active') return '模块调度已关闭，仅显示运行状态';
  const boot = state.schedulerBoot;
  if (boot.phase === 'pending_reboot') return `${boot.targetMode === 'ugt' ? 'UGT' : 'Pixel'} 基础调度已保存，重启后生效`;
  if (boot.phase === 'blocked' || boot.phase === 'failed') return '启动检查失败，请查看运行记录后重新检查';
  if (boot.phase === 'verifying' || boot.phase === 'applying') return `正在检查 ${boot.targetMode === 'ugt' ? 'UGT' : 'Pixel'} 基础调度`;
  if (boot.phase === 'success' && boot.effectiveMode === 'ugt') return 'UGT 基础调度 · 已生效';
  if (boot.phase === 'success' && boot.effectiveMode === 'pixel') return 'Pixel 基础调度 · 已生效';
  const name = getEffectiveSchedulerName();
  const desired = state.schedOwner === 'external' ? '启动选择：UGT' : '启动选择：Pixel';
  if (state.schedEffectiveOwner === 'external') {
    if (!hasExternalScheduler()) return `${desired} · 当前无外部调度器运行`;
    const lease = state.effectiveSchedulerKind === 'fas_rs' && (state.arbiterState === 'FAS_LEASED_GAME' || state.arbiterState === 'EXIT_HOLD');
    const current = isExternalSchedulerActive() ? `${name} 接管${getEffectiveSchedulerModeText()}` : `${name} ${getExternalSchedulerStateText()}`;
    return `${desired} · 当前 ${current}${lease ? '（游戏临时接管）' : ''}`;
  }
  return state.schedOwner === 'external' ? 'UGT 基础调度待重启检查' : '当前由 Pixel9Pro-Control 管理基础调度';
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
    const owner = isExternalSchedulerActive() ? `当前由 ${name} 管理 CPU 调度${getEffectiveSchedulerModeText()}` : `已检测到 ${name}（${getExternalSchedulerStateText()}）`;
    return `${owner}。本模块的性能档位设置与自动切换已暂停。`;
  }
  return '当前未检测到运行中的外部调度器，本模块调度仍保持暂停。';
}

function getSchedulerPixelDesc() {
  if (state.uperfDetected && state.fasRsDetected) {
    return `当前由本模块管理基础调度，${getUperfName()} 未接管。fas-rs 仅在游戏策略生效时临时接管。`;
  }
  if (state.uperfDetected) {
    return `已检测到 ${getUperfName()}，当前仍由本模块管理基础调度。`;
  }
  if (state.fasRsDetected) {
    return '当前由本模块管理基础调度。开启游戏自动接管后，fas-rs 将在已配置的游戏运行时临时接管。';
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
      refs.externalSchedulerHelp.textContent = '基础调度可选择 Pixel 或 UGT，切换后需重启。fas-rs 可在已配置的游戏运行时临时接管，退出游戏后恢复所选基础调度。';
    } else if (available.ugt) {
      refs.externalSchedulerHelp.textContent = '已检测到 UGT。基础调度可选择 Pixel 或 UGT，切换后需重启。';
    } else if (available.fas) {
      refs.externalSchedulerHelp.textContent = '已检测到 fas-rs。开启游戏自动接管后，fas-rs 将在已配置的游戏运行时临时接管；单独检测到进程运行，尚不能确认游戏接管已生效。';
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
        ? (isFasRsRuntimeActive() ? '已开启 · fas-rs 正在管理游戏调度，退出后恢复基础调度' : '已开启 · 已配置的游戏运行时由 fas-rs 临时接管')
        : canCheckGameHandoff() ? '已关闭 · 正在等待恢复基础调度'
          : '已关闭 · 游戏继续使用所选基础调度';
      refs.gameHandoffToggleBtn.disabled = state.schedulerMode !== 'active' || strategyBusy || !isVerifiedSchedulerBoot();
      refs.gameHandoffToggleBtn.className = `tiny-btn${enabled ? ' tonal' : ''}`;
      refs.gameHandoffToggleLabel.textContent = state.gameHandoffBusy ? '保存中…' : (enabled ? '关闭' : '开启');
      refs.gameHandoffToggleBtn.title = !isVerifiedSchedulerBoot() ? '基础调度通过启动检查后可修改此设置' : '';
    }
  }
  if (refs.schedulerHealthRow) {
    refs.schedulerHealthRow.hidden = false;
    const health = state.schedulerHealth;
    refs.schedulerHealthLabel.textContent = health.status === 'healthy'
      ? '实际运行参数与所选配置一致'
      : health.status === 'drift' ? '实际运行参数与所选配置存在差异'
        : health.status === 'blocked' ? '检测到调度状态冲突，检查已暂停'
          : health.status === 'deferred'
            ? (health.reason === 'fas_rs_runtime_lease' || health.reason === 'effective_owner_external'
              ? '检查延后 · 外部调度接管中'
              : '检查延后 · 调度切换中')
            : '等待运行状态检查';
    refs.schedulerRetryBtn.disabled = state.schedulerMode !== 'active' || strategyBusy || state.schedulerRetryBusy || !['failed', 'blocked'].includes(state.schedulerBoot.phase);
    refs.schedulerRetryLabel.textContent = state.schedulerRetryBusy ? '检查中…' : '重新检查';
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
        : `fas-rs：${active || '已检测到'}。检查后将根据当前游戏状态处理接管或恢复。`;
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
    title = '正在保存基础调度';
    detail = '正在保存下次启动使用的调度模式，重启后生效。';
  } else if (state.gameHandoffBusy) {
    title = '正在切换游戏接管';
    detail = '正在保存 fas-rs 游戏接管设置并确认当前调度状态。';
  } else if (state.ownerArbiterBusy) {
    title = '正在检查游戏接管状态';
    detail = '正在检查当前游戏、调度程序与运行参数，并处理接管或恢复。';
  } else if (state.profileApplyBusy) {
    title = '正在切换性能模式';
    detail = '正在应用所选档位，并检查实际调度参数。';
  } else if (state.profilePolicyBusy) {
    title = '正在切换调度方式';
    detail = '正在保存自动或手动设置，并检查当前性能档位。';
  }
  if (!title) return;
  refs.perfCurrentName.textContent = title;
  refs.perfCurrentDesc.textContent = detail;
  refs.perfPolicyDesc.textContent = '操作进行中，相关控件暂时不可用。系统温控保护继续生效。';
}

function syncProfileChoiceSemantics() {
  const policyDetail = document.getElementById('perf-policy-detail');
  if (policyDetail) policyDetail.textContent = refs.perfPolicyDesc.textContent;
  if (state.schedulerMode === 'active' && state.schedEffectiveOwner !== 'external'
      && !isCurrentStrategyBusy() && !['pending_reboot', 'verifying', 'applying'].includes(state.schedulerBoot.phase)
      && !(state.profileTransition.terminal === 'yes' && state.profileTransition.ok === 'no')) {
    refs.perfPolicyDesc.textContent = state.profilePolicy === 'auto'
      ? '根据温度与系统温控状态，自动切换均衡或省电档位。'
      : '保持手动选择的性能档位。';
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
    refs.topbarProfileChip.textContent = '模块调度已关闭';
    refs.perfCurrentName.textContent = off.name;
    refs.perfCurrentDesc.textContent = off.desc;
    refs.perfPolicyDesc.textContent = state.schedulerCapability === 'supported'
      ? '重新启用需在模块安装向导中选择调度功能，重启后生效。'
      : '当前内核的调度支持状态未确认，参数修改功能不可用。';
    refs.profilePolicyManualBtn.className = 'seg-btn';
    refs.profilePolicyAutoBtn.className = 'seg-btn';
    refs.profilePolicyManualBtn.disabled = true;
    refs.profilePolicyAutoBtn.disabled = true;
    refs.schedOwnerLabel.textContent = getSchedulerStatusText();
    refs.schedOwnerToggleBtn.disabled = true;
    refs.schedOwnerToggleLabel.textContent = '模块调度已关闭';
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
    refs.topbarProfileChip.textContent = hasExternalScheduler() ? (isExternalSchedulerActive() ? `${effectiveName} 接管` : '外部调度未运行') : '模块调度已暂停';
    refs.perfCurrentName.textContent = hasExternalScheduler()
      ? (isExternalSchedulerActive() ? `${effectiveName} 接管${getEffectiveSchedulerModeText()}` : `${effectiveName} ${getExternalSchedulerStateText()}`)
      : '模块调度已暂停';
    refs.perfCurrentDesc.textContent = getSchedulerExternalDesc();
    refs.perfPolicyDesc.textContent = hasExternalScheduler()
      ? 'CPU 调度由外部程序管理，本模块的档位设置与自动切换暂不可用。'
      : '未检测到运行中的外部调度器，本模块的档位设置与自动切换仍保持暂停。';
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
    refs.heroMode.textContent = hasExternalScheduler() ? (isExternalSchedulerActive() ? `${effectiveName} 接管` : '外部调度未运行') : '模块调度已暂停';
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
    ? (autoTransitionFailed ? `${profile.desc} · 自动切换已停止` : `${profile.desc} · ${describeAutoReason(state.autoReason)}`)
    : profile.desc;
  const pixelPolicyDesc = isAuto
    ? (autoTransitionFailed
      ? '自动切换连续失败，已停止。选择手动档位后可重新开启自动。'
       : `自动切换范围为均衡和省电，当前状态：${describeAutoReason(state.autoReason)}。选择下方档位后将改为手动；系统后续修改参数时，模块仅记录差异。`)
    : `当前保持手动选择的「${profile.name}」。开启自动后，将根据温度与系统温控状态切换均衡或省电档位。`;
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
    case 'auto_balanced': return '自动模式 · 均衡';
    case 'steady_hot_guard': return '温度持续偏高，已切换省电';
    case 'hot_cooldown': return '温度已回落，恢复均衡';
    case 'screen_off_reset': return '已息屏，恢复均衡';
    case 'deep_standby_reset': return '深度待机，恢复均衡';
    case 'charging_no_throttle': return '充电中，未达到省电切换条件，保持均衡';
    case 'charging_thermal_mitigation': return '充电时系统温控介入，已切换省电';
    case 'charging_comfort_hot': return '充电时温度达到切换条件，已切换省电';
    case 'charging_comfort_cooldown': return '充电温度回落，恢复均衡';
    case 'auto_enabled': return '已开启自动调度';
    case 'manual_policy': return '已切换为手动';
    case 'manual_selected': return '使用手动选择的档位';
    case 'external_scheduler': return '外部程序管理调度';
    case 'external_no_scheduler_sanitized': return '模块调度已暂停';
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
  const label = ({ retry: '调度检查', handoff: '游戏接管设置', tick: '游戏接管检查' })[state.schedulerOperation.kind] || '调度操作';
  notice.textContent = state.schedulerOperation.pending
    ? `${label}正在后台执行，切换页面不会中断操作。`
    : state.schedulerOperation.phase === 'success' ? `${label}已完成。`
      : state.schedulerOperation.phase === 'deferred' ? `${label}已暂缓，请在亮屏且其他调度操作完成后重试。`
        : `${label}结果未确认，请刷新状态。错误代码：${state.schedulerOperation.resultCode}。`;
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

function profileReadNotice(kind, error) {
  const notice = document.getElementById('profile-operation-notice');
  if (error) {
    notice.dataset.readFailure = kind;
    notice.hidden = false;
    notice.textContent = `调度${kind === 'full' ? '完整配置' : '状态'}读取失败：${error.message}`;
    appendLog(notice.textContent, 'err');
  } else if (notice.dataset.readFailure === kind) {
    delete notice.dataset.readFailure;
    notice.hidden = true;
    notice.textContent = '';
  }
}

async function refreshFullProfileState() {
  const generation = ++profileFullStateGeneration;
  const mutationRevision = profileMutationStateRevision;
  let fullState;
  try {
    fullState = await apiFetch(API.profile, { timeoutMs: SCHEDULER_READ_TIMEOUTS.full, priority: 'background', scope: 'profile.full.read' });
  } catch (error) {
    if (isCancelled(error) || generation !== profileFullStateGeneration) return null;
    profileReadNotice('full', error);
    return false;
  }
  if (generation !== profileFullStateGeneration) return null;
  const newerMutationState = mutationRevision !== profileMutationStateRevision ? latestProfileMutationState : null;
  applyProfileState(fullState);
  if (newerMutationState) applyProfileMutationState(newerMutationState);
  profileReadNotice('full');
  return true;
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
  delete notice.dataset.readFailure;
  notice.hidden = false;
  notice.textContent = `${message}，正在更新运行状态。`;
  void apiFetch(`${API.profile}?compact=1`, { timeoutMs: SCHEDULER_READ_TIMEOUTS.compact,
    dedupe: false, priority: 'normal', scope: 'profile.commit.readback' })
    .then((readback) => {
      if (revision !== profileMutationStateRevision) return;
      if (!readback || readback.ok === false) throw new Error('状态响应无效');
      applyProfileMutationState(readback);
      const confirmed = expected();
      if (notice) notice.textContent = confirmed ? message : `${message}，实际状态尚未确认，请刷新检查。`;
    })
    .catch((error) => {
      if (revision === profileMutationStateRevision && notice) notice.textContent = `${message}，状态更新${isCancelled(error) ? '已暂停' : '失败'}，请刷新检查。`;
    });
}

function refreshProfileState() {
  return core().runFeatureTask('profile.state.read', async () => {
    const revision = profileMutationStateRevision;
    let data;
    try {
      data = await apiFetch(`${API.profile}?compact=1`, { timeoutMs: SCHEDULER_READ_TIMEOUTS.compact, priority: 'normal', scope: 'profile.read' });
    } catch (error) {
      if (isCancelled(error)) return null;
      profileReadNotice('compact', error);
      return false;
    }
    if (revision === profileMutationStateRevision) applyProfileMutationState(data);
    profileReadNotice('compact');
    return true;
  });
}

async function loadSavedProfile() {
  const result = await refreshProfileState();
  if (result === true) void refreshFullProfileState();
  return result;
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
    return true;
  } catch (err) {
    if (isCancelled(err)) return null;
    state.cpuRows = null;
    state.homeCpuRows = null;
    const el = document.createElement('div');
    el.className = 'error-panel';
    const title = document.createElement('strong');
    title.textContent = 'CPU 频率读取失败';
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
  return core().runFeatureTask('profile.cpu.refresh', async () => {
    const results = await Promise.all([refreshCpuTask(), refreshProfileState()]);
    if (results.includes(false)) return false;
    return results.every((result) => result === null) ? null : true;
  });
}

async function applyProfile(profile) {
  if (state.schedulerMode !== 'active') {
    showToast('本模块性能调度已关闭；重新启用请通过模块安装向导');
    return;
  }
  if (state.schedOwner === 'external') {
    showToast(hasExternalScheduler() ? getSchedulerStatusText() : '本模块调度未启用');
    appendLog(hasExternalScheduler()
      ? `${getSchedulerStatusText()}，性能档位未切换`
      : '模块 CPU 调度未启用，性能档位未切换', 'warn');
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
      if (data.final !== true || data.profile !== profile) throw new Error('服务尚未确认所选性能档位');
      reconcileProfileCommit(() => state.currentProfile === profile, `已保存：${PROFILES[profile].name}`);
      const forcedManual = prevPolicy === 'auto' && data.policy === 'manual';
      showToast(forcedManual ? `已切换为手动：${PROFILES[profile].name}` : `已应用：${PROFILES[profile].name}`);
      appendLog(forcedManual ? `已关闭自动切换，应用手动档位「${PROFILES[profile].name}」` : `${PROFILES[profile].name} 已应用`, 'ok');
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
      if (data.final !== true || data.scheduler_mode !== mode) throw new Error('服务尚未确认所选调度模式');
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
      ? `${getSchedulerStatusText()}，调度方式未切换`
      : '模块 CPU 调度未启用，调度方式未切换', 'warn');
    return;
  }
  if (state.profilePolicy === policy || isCurrentStrategyBusy()) return;
  state.profilePolicyBusy = true;
  invalidateFullProfileStateRefresh();
  syncProfileUi();
  appendLog(policy === 'auto' ? '正在开启自动调度…' : '正在切换为手动调度…', 'dim');
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
      if (data.final !== true || data.policy !== policy) throw new Error('服务尚未确认所选调度方式');
      reconcileProfileCommit(() => state.profilePolicy === policy, policy === 'auto' ? '自动调度设置已保存' : '手动调度设置已保存');
      showToast(policy === 'auto' ? '已开启自动调度' : `已切换为手动：${PROFILES[state.currentProfile].name}`);
      appendLog(policy === 'auto'
        ? `自动调度已启用：${describeAutoReason(state.autoReason)}`
        : `已切换为手动：${PROFILES[state.currentProfile].name}`, 'ok');
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
    ? '正在保存 UGT 基础调度…'
    : '正在保存 Pixel 基础调度…';
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
      showToast('基础调度已保存，重启后生效');
      appendLog(nextOwner === 'external'
        ? '下次启动使用 UGT 基础调度，当前运行状态未改变'
        : '下次启动使用 Pixel 基础调度，重启后检查生效状态', 'warn');
      openRebootModal(null, null, 'scheduler');
    } else {
      const detail = data.scheduler_boot?.reason || data.error || '基础调度保存失败';
      showToast(`切换未完成：${detail}`);
      appendLog(`基础调度未保存：${detail}`, 'err');
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
  if (notice) { notice.hidden = false; notice.textContent = '正在取消待重启的调度切换，关闭提示不会中断操作。'; }
  try {
    const data = await apiFetch(API.profile, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ scheduler_action: 'cancel_pending' }), timeoutMs: 25000, priority: 'interactive', scope: 'profile.mutation'
    });
    if (data.scheduler_boot) applyProfileMutationState(data);
    if (data.ok) {
      if (state.schedulerBoot.final !== 'yes' || state.schedulerBoot.phase !== 'success') throw new Error('取消结果未确认，请刷新状态');
      if (requireFeature('ui').getRebootContext() === 'scheduler') {
        requireFeature('ui').closeRebootModal('', { force: true, silent: true });
      }
      showToast('已取消待重启切换');
      appendLog('已恢复本次启动使用的基础调度选择', 'ok');
      if (notice) notice.textContent = '待重启切换已取消，正在更新运行状态。';
      const revision = profileMutationStateRevision;
      void apiFetch(`${API.profile}?compact=1`, { timeoutMs: SCHEDULER_READ_TIMEOUTS.compact, dedupe: false, priority: 'normal', scope: 'profile.cancel.readback' })
        .then((readback) => {
          if (revision !== profileMutationStateRevision) return;
          applyProfileMutationState(readback);
          const confirmed = state.schedulerBoot.final === 'yes' && state.schedulerBoot.phase === 'success';
          if (notice) notice.textContent = confirmed ? '已取消待重启切换。' : '取消请求已处理，最新状态未确认，请刷新检查。';
        })
        .catch((error) => {
          if (revision === profileMutationStateRevision && notice) notice.textContent = `取消请求已处理，状态更新${isCancelled(error) ? '已暂停' : '失败'}。请刷新检查，无需重复取消。`;
        });
    } else {
      showToast(`取消失败：${data.error || data.scheduler_boot?.reason || '未知'}`);
      appendLog(data.error || '取消待重启切换失败', 'err');
    }
  } catch (err) {
    if (notice) notice.textContent = `取消结果未确认：${err?.message || '服务未返回有效响应'}。请刷新状态后再操作。`;
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
      showToast('调度检查已开始，将在后台继续执行');
      appendLog('调度检查正在后台执行，切换页面不会中断', 'dim');
    } else if (data.ok) {
      if (!await confirmProfileMutation(() => state.schedulerBoot.final === 'yes')) throw new Error('调度检查已提交，结果尚未确认');
      showToast('调度启动检查通过');
      appendLog(`调度检查结果：${data.scheduler_boot?.result || '已通过'}`, 'ok');
    } else {
      showToast(`调度检查失败：${data.scheduler_boot?.reason || data.error || '原因未提供'}`);
      appendLog(`调度检查失败：${data.scheduler_boot?.result || data.error || '原因未提供'}`, 'err');
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
      showToast('游戏接管设置已保存，运行状态正在更新');
      appendLog(data.pending_reason || '其他调度操作正在执行，游戏接管设置将在后台继续处理', 'warn');
    } else if (data.ok) {
      reconcileProfileCommit(() => state.gameHandoffPolicy === nextPolicy, '游戏自动接管设置已保存');
      showToast(nextPolicy === 'fas_rs' ? 'fas-rs 游戏接管已启用' : 'fas-rs 游戏接管已关闭');
      appendLog(nextPolicy === 'fas_rs'
        ? '已开启 fas-rs 游戏临时接管，退出游戏后恢复基础调度'
        : '已关闭游戏临时接管，继续使用所选基础调度', 'ok');
      await refreshCpu();
    } else {
      const detail = data.arbiter_apply_result || data.error || '实际调度状态未确认';
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
    showToast('游戏自动接管已关闭，无待处理的接管记录');
    syncOwnerArbiterUi();
    return;
  }
  state.ownerArbiterBusy = true;
  syncProfileUi();
  appendLog('正在检查游戏临时接管状态…', 'dim');
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
      showToast('游戏接管检查已开始，结果将在后台更新');
      appendLog('游戏接管检查正在后台执行', 'dim');
    } else if (data.ok) {
      showToast('调度状态已更新');
      appendLog('游戏接管状态已更新', 'ok');
      await loadSavedProfile();
      await refreshCpu();
    } else {
      showToast(`检查失败：${data.error || '未知'}`);
      appendLog(data.error || '游戏接管状态检查失败', 'err');
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
