// CPU profile、调度 owner 与临时游戏接管功能。
'use strict';
function buildProfileDetail(key) {
  const profile = PROFILES[key] || PROFILES.unknown;
  const contract = state.profile.cpuContract;
  const values = contract?.profiles?.[key];
  let html = `<b>${profile.name}</b><br><br>${profile.detail}`;
  if (!values || !contract) return `${html}<br><br>运行参数尚未读取。`;
  const response = Array.isArray(values.response_ms)
    ? values.response_ms.map((value) => `${value}ms`).join(' / ')
    : '内核 response_time_ms_nom（运行时复读）';
  html += `<br><br><b>cpuset</b>: top-app → cpu${escapeHtml(values.top_app_cpus || 'unknown')}，foreground → cpu${escapeHtml(contract.foreground_cpus || 'unknown')}，background → cpu${escapeHtml(contract.background_cpus || 'unknown')}`;
  html += `<br><b>response_time_ms</b>: ${escapeHtml(response)}`;
  html += `<br><b>sched_util_clamp_min</b>: ${Number.isFinite(values.uclamp_cap) ? values.uclamp_cap : 'unknown'}`;
  return html;
}

// 内存优化详情按 state.memory.swapData 实时生成: 数字取自当前值, 解释随取值自适应,
// 手动改参后重新打开即反映当前 ZRAM / VM 方案 (不再硬编码)
function boolValue(value) {
  return value === true || value === 'true' || value === 'yes' || value === 1 || value === '1';
}

function formatSchedValue(value, unit) {
  if (value === null || value === undefined || value === '' || value === 'N/A' || value === 'na') return 'N/A';
  return `${value}${unit}`;
}

function getUperfName() {
  return state.profile.uperfModuleName || state.profile.uperfModuleId || 'Uperf Game Turbo';
}

function getUperfStateText() {
  if (isUperfActive()) return '运行中';
  switch (state.profile.uperfModuleState) {
    case 'disabled': return '已禁用';
    case 'pending_update': return '待重启更新';
    case 'pending_remove': return '待重启移除';
    case 'active': return '已安装';
    default: return state.profile.uperfDetected ? '已安装' : '未检测到';
  }
}

function isUperfEnabled() {
  return state.profile.uperfDetected && state.profile.uperfModuleEnabled === 'yes';
}

function isUperfActive() {
  return state.profile.uperfDetected && (state.profile.uperfActive === 'yes' || state.profile.uperfProcessAlive === 'yes');
}

function getFasRsName() {
  return state.profile.fasRsModuleName || state.profile.fasRsModuleId || 'fas-rs';
}

function getFasRsStateText() {
  if (isFasRsRuntimeActive()) {
    return state.profile.fasRsRuntimeTarget ? `游戏接管中 · ${state.profile.fasRsRuntimeTarget}` : '游戏接管中';
  }
  if (isFasRsResident()) {
    return state.profile.fasRsMode ? `常驻待机 · ${state.profile.fasRsMode}` : '常驻待机';
  }
  switch (state.profile.fasRsRuntimeState || state.profile.fasRsModuleState) {
    case 'disabled_marker': return '已让权';
    case 'disabled': return '已禁用';
    case 'pending_update': return '待重启更新';
    case 'pending_remove': return '待重启移除';
    case 'stale_game_lease': return '游戏 lease 已失效';
    case 'stale_owner_state': return '运行标记待刷新';
    case 'module_enabled': return '模块启用';
    case 'runtime_present': return '运行目录存在';
    case 'active': return '已安装';
    default: return state.profile.fasRsDetected ? '已检测到' : '未检测到';
  }
}

function isFasRsEnabled() {
  return state.profile.fasRsDetected && (isFasRsResident() || state.profile.fasRsActive === 'yes' || state.profile.fasRsModuleEnabled === 'yes');
}

function isFasRsResident() {
  return state.profile.fasRsDetected && state.profile.fasRsProcessAlive === 'yes';
}

function isFasRsRuntimeActive() {
  return state.profile.fasRsDetected && (state.profile.fasRsRuntimeOwnerActive === 'yes' || state.profile.fasRsActive === 'yes');
}

function getExternalSchedulerName() {
  return state.profile.externalSchedulerName || state.profile.externalSchedulerId || (state.profile.fasRsDetected ? getFasRsName() : getUperfName());
}

function getEffectiveSchedulerName() {
  return state.profile.effectiveSchedulerName || getExternalSchedulerName();
}

function getEffectiveSchedulerModeText() {
  return state.profile.effectiveSchedulerMode ? ` · ${state.profile.effectiveSchedulerMode}` : '';
}

function hasExternalScheduler() {
  return state.profile.externalSchedulerDetected || state.profile.uperfDetected || state.profile.fasRsDetected;
}

function isExternalSchedulerActive() {
  return state.profile.externalSchedulerActive || isUperfActive() || isFasRsRuntimeActive();
}

function getExternalSchedulerStateText() {
  if (state.profile.externalSchedulerKind === 'fas_rs') return getFasRsStateText();
  if (state.profile.externalSchedulerKind === 'uperf') return getUperfStateText();
  if (state.profile.externalSchedulerKind === 'multiple') {
    return isExternalSchedulerActive() ? '多个外部调度器可用' : '检测到多个外部调度器';
  }
  switch (state.profile.externalSchedulerState) {
    case 'disabled': return '已禁用';
    case 'pending_update': return '待重启更新';
    case 'pending_remove': return '待重启移除';
    case 'active': return '已安装';
    case 'running': return '运行中';
    default: return hasExternalScheduler() ? '已检测到' : '未检测到';
  }
}

function getSchedulerStatusText() {
  const boot = state.profile.schedulerBoot;
  if (boot.phase === 'pending_reboot') return `等待重启到${boot.targetMode === 'ugt' ? ' UGT 日常调度' : ' Pixel'}模式`;
  if (boot.phase === 'blocked' || boot.phase === 'failed') return `调度切换失败 · ${boot.reason || boot.result || '状态未通过验证'}`;
  if (boot.phase === 'verifying' || boot.phase === 'applying') return `正在验证 ${boot.targetMode === 'ugt' ? 'UGT' : 'Pixel'} 启动模式`;
  if (boot.phase === 'success' && boot.effectiveMode === 'ugt') return 'UGT 日常调度模式 · 已验证';
  if (boot.phase === 'success' && boot.effectiveMode === 'pixel') return 'Pixel 调度模式 · 已验证';
  const name = getEffectiveSchedulerName();
  const desired = state.profile.schedOwner === 'external' ? 'UGT 启动模式' : 'Pixel 启动模式';
  if (state.profile.schedEffectiveOwner === 'external') {
    if (!hasExternalScheduler()) return `${desired} · 当前无外部调度器运行`;
    const lease = state.profile.effectiveSchedulerKind === 'fas_rs' && (state.profile.arbiterState === 'FAS_LEASED_GAME' || state.profile.arbiterState === 'EXIT_HOLD');
    const current = isExternalSchedulerActive() ? `${name} 接管${getEffectiveSchedulerModeText()}` : `${name} ${getExternalSchedulerStateText()}`;
    return `${desired} · 当前 ${current}${lease ? '（游戏临时接管）' : ''}`;
  }
  return state.profile.schedOwner === 'external' ? 'UGT 模式等待重启验证' : 'Pixel 调度模式 · 当前 Pixel9Pro-Control';
}

function getSchedulerToggleText() {
  if (state.profile.schedOwnerBusy) return '切换中…';
  if (state.profile.schedulerBoot.phase === 'pending_reboot') return '取消切换';
  return state.profile.schedulerBoot.effectiveMode === 'ugt' ? '切换到 Pixel' : '切换到 UGT';
}

function isVerifiedPixelBoot() {
  return state.profile.schedulerBoot.phase === 'success' && state.profile.schedulerBoot.effectiveMode === 'pixel';
}

function isVerifiedSchedulerBoot() {
  return state.profile.schedulerBoot.phase === 'success'
    && (state.profile.schedulerBoot.effectiveMode === 'pixel' || state.profile.schedulerBoot.effectiveMode === 'ugt');
}

function isCurrentStrategyBusy() {
  return state.profile.profileApplyBusy
    || state.profile.profilePolicyBusy
    || state.profile.schedOwnerBusy
    || state.profile.gameHandoffBusy
    || state.profile.ownerArbiterBusy
    || state.profile.schedulerRetryBusy;
}

function getSchedulerExternalDesc() {
  const name = getEffectiveSchedulerName();
  if (hasExternalScheduler()) {
    const owner = isExternalSchedulerActive() ? `CPU 调度交给 ${name}${getEffectiveSchedulerModeText()}` : `检测到 ${name} (${getExternalSchedulerStateText()})`;
    return `${owner}；本模块 profile / policy 仅保留显示与让权状态，不写 CPU 调度节点。`;
  }
  return '未检测到启用中的外部调度器；本模块保持让权状态，不再周期性写 CPU 调度节点。';
}

function getSchedulerPixelDesc() {
  if (state.profile.uperfDetected && state.profile.fasRsDetected) {
    return `当前日常调度由本模块管理；${getUperfName()} 未接管，fas-rs 仅按游戏策略临时接管。`;
  }
  if (state.profile.uperfDetected) {
    return `检测到 ${getUperfName()}，当前日常调度由本模块管理。`;
  }
  if (state.profile.fasRsDetected) {
    return 'fas-rs 进程常驻待机，仅在有效游戏 lease 内接管；当前日常调度由本模块管理。';
  }
  return '当前由本模块管理 CPU 调度。';
}

function syncOptionalModuleUi() {
  const available = {
    ugt: state.profile.uperfDetected,
    fas: state.profile.fasRsDetected,
    baseband: state.network.basebandInstalled && state.shell.deviceModel === 'Pixel 9 Pro',
  };
  document.querySelectorAll('[data-module-visible]').forEach((element) => {
    const keys = String(element.dataset.moduleVisible || '').split('|').filter(Boolean);
    element.hidden = !keys.some((key) => available[key]);
  });
  if (refs.externalSchedulerHelp) {
    if (available.ugt && available.fas) {
      refs.externalSchedulerHelp.textContent = ' 已检测到 UGT 与 fas-rs：Pixel/UGT 是重启后选择的日常基线；fas-rs 命中游戏时临时接管，退出后恢复同一基线。';
    } else if (available.ugt) {
      refs.externalSchedulerHelp.textContent = ' 已检测到 UGT；Pixel 与 UGT 为重启后生效的日常基线选择。';
    } else if (available.fas) {
      refs.externalSchedulerHelp.textContent = ' 已检测到 fas-rs；进程可常驻待机，命中游戏并建立有效 lease 后才接管。';
    } else {
      refs.externalSchedulerHelp.textContent = '';
    }
  }
}

function syncOwnerArbiterUi() {
  syncOptionalModuleUi();
  const strategyBusy = isCurrentStrategyBusy();
  if (refs.gameHandoffRow) {
    const available = state.profile.fasRsDetected;
    refs.gameHandoffRow.hidden = !available;
    if (available) {
      const enabled = state.profile.gameHandoffPolicy === 'fas_rs';
      refs.gameHandoffLabel.textContent = enabled
        ? 'fas-rs 常驻待机；命中游戏时建立 lease，退出后恢复日常选择'
        : 'fas-rs 游戏临时接管已关闭';
      refs.gameHandoffToggleBtn.disabled = strategyBusy || !isVerifiedSchedulerBoot();
      refs.gameHandoffToggleBtn.className = `tiny-btn${enabled ? ' tonal' : ''}`;
      refs.gameHandoffToggleLabel.textContent = state.profile.gameHandoffBusy ? '切换中…' : (enabled ? '关闭' : '启用');
    }
  }
  if (refs.schedulerHealthRow) {
    refs.schedulerHealthRow.hidden = false;
    const health = state.profile.schedulerHealth;
    refs.schedulerHealthLabel.textContent = health.status === 'healthy'
      ? '控制面健康'
      : health.status === 'drift' ? `检测到漂移 · ${health.reason || 'profile 不一致'}`
        : health.status === 'blocked' ? `已阻断 · ${health.reason || '外部残留'}`
          : health.status === 'deferred'
            ? (health.reason === 'fas_rs_runtime_lease' || health.reason === 'effective_owner_external'
              ? '检查延后 · 外部调度接管中'
              : '检查延后 · 调度切换中')
            : '等待健康检查';
    refs.schedulerRetryBtn.disabled = strategyBusy || state.profile.schedulerRetryBusy || !['failed', 'blocked'].includes(state.profile.schedulerBoot.phase);
    refs.schedulerRetryLabel.textContent = state.profile.schedulerRetryBusy ? '验证中…' : '重新验证';
  }
  if (!refs.ownerArbiterRow) return;
  const available = state.profile.fasRsDetected;
  refs.ownerArbiterRow.hidden = !available;
  if (!available) return;
  const active = getFasRsStateText();
  refs.ownerArbiterLabel.textContent = state.profile.ownerArbiterBusy
    ? '正在检查调度接管状态…'
    : `fas-rs ${active || '已检测到'}；常驻进程不等于调度接管`;
  refs.ownerArbiterTickBtn.disabled = strategyBusy;
  refs.ownerArbiterTickLabel.textContent = state.profile.ownerArbiterBusy ? '检查中…' : '立即检查';
}

function syncCurrentStrategyTransitionCopy() {
  let title = '';
  let detail = '';
  if (state.profile.schedOwnerBusy) {
    title = '正在切换调度接管';
    detail = '正在提交下次启动模式；当前 boot 不会热启动或热停止 UGT。';
  } else if (state.profile.gameHandoffBusy) {
    title = '正在切换游戏接管';
    detail = '正在更新 fas-rs 接管策略并核对当前 owner，通常需要数秒。';
  } else if (state.profile.ownerArbiterBusy) {
    title = '正在检查调度协调';
    detail = '正在复读前台场景、owner 和关键调度节点，通常需要数秒。';
  } else if (state.profile.profileApplyBusy) {
    title = '正在切换性能模式';
    detail = '正在应用 profile 并复读关键调度节点，通常需要数秒。';
  } else if (state.profile.profilePolicyBusy) {
    title = '正在切换自动 / 手动';
    detail = '正在应用当前 profile 并复读调度状态，通常需要数秒。';
  }
  if (!title) return;
  refs.perfCurrentName.textContent = title;
  refs.perfCurrentDesc.textContent = detail;
  refs.perfPolicyDesc.textContent = '完成前请勿重复操作；温控与系统安全保护保持生效。';
}

function syncProfileUi() {
  const profile = PROFILES[state.profile.currentProfile] || PROFILES.unknown;
  const isAuto = state.profile.profilePolicy === 'auto';
  const isExternal = state.profile.schedEffectiveOwner === 'external';
  const effectiveName = getEffectiveSchedulerName();
  const schedulerPending = ['pending_reboot', 'verifying', 'applying'].includes(state.profile.schedulerBoot.phase);
  const strategyBusy = isCurrentStrategyBusy() || schedulerPending;
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
    refs.schedOwnerToggleBtn.disabled = isCurrentStrategyBusy() || !state.profile.uperfDetected;
    refs.schedOwnerToggleLabel.textContent = getSchedulerToggleText();
    refs.hero.className = 'hero-card mode-game';
    setStaticHtml(refs.heroIcon, PROFILES.performance.hero);
    refs.heroMode.textContent = hasExternalScheduler() ? (isExternalSchedulerActive() ? `${effectiveName} 接管` : '外部调度未启用') : '调度停用';
    document.querySelectorAll('.profile-option').forEach((card) => {
      card.classList.remove('selected');
      card.classList.add('disabled');
    });
    syncCurrentStrategyTransitionCopy();
    syncOwnerArbiterUi();
    return;
  }
  refs.topbarProfileChip.textContent = isAuto ? `${profile.name} · 自动` : profile.name;
  refs.perfCurrentName.textContent = isAuto ? `${profile.name} · 自动` : profile.name;
  const autoTransitionFailed = isAuto && state.profile.profileTransition.terminal === 'yes' && state.profile.profileTransition.ok === 'no';
  refs.perfCurrentDesc.textContent = isAuto
    ? (autoTransitionFailed ? `${profile.desc} · 自动切档已停止` : `${profile.desc} · ${describeAutoReason(state.profile.autoReason)}`)
    : profile.desc;
  const pixelPolicyDesc = isAuto
    ? (autoTransitionFailed
      ? '自动切档连续失败并已停止；切到手动档后可重新启用自动。'
      : `自动模式：按“${describeAutoReason(state.profile.autoReason)}”在均衡与省电间切换；点击模式卡片转为手动。`)
    : `手动模式：固定为「${profile.name}」；切换为自动后，仅在温度持续偏高时收口至省电。`;
  refs.perfPolicyDesc.textContent = hasExternalScheduler() ? `${pixelPolicyDesc} ${getSchedulerPixelDesc()}` : pixelPolicyDesc;
  refs.profilePolicyManualBtn.className = `seg-btn${!isAuto ? ' active' : ''}`;
  refs.profilePolicyAutoBtn.className = `seg-btn${isAuto ? ' active' : ''}`;
  refs.profilePolicyManualBtn.disabled = strategyBusy || !isVerifiedPixelBoot();
  refs.profilePolicyAutoBtn.disabled = strategyBusy || !isVerifiedPixelBoot();
  refs.schedOwnerLabel.textContent = getSchedulerStatusText();
  refs.schedOwnerToggleBtn.className = 'tiny-btn';
  refs.schedOwnerToggleBtn.disabled = isCurrentStrategyBusy() || !state.profile.uperfDetected;
  refs.schedOwnerToggleLabel.textContent = getSchedulerToggleText();
  refs.hero.className = `hero-card ${profile.modeClass}`;
  setStaticHtml(refs.heroIcon, profile.hero);
  refs.heroMode.textContent = isAuto ? `${profile.name} · 自动` : profile.name;
  document.querySelectorAll('.profile-option').forEach((card) => {
    card.classList.toggle('disabled', strategyBusy || !isVerifiedPixelBoot());
    card.classList.toggle('selected', card.dataset.profile === state.profile.currentProfile);
  });
  syncCurrentStrategyTransitionCopy();
  syncOwnerArbiterUi();
}

function describeAutoReason(reason) {
  switch (reason) {
    case 'auto_balanced': return '自动均衡运行中';
    case 'steady_hot_guard': return '持续热平台，已压到省电';
    case 'hot_cooldown': return '热平台已回落，恢复均衡';
    case 'screen_off_reset': return '已息屏，恢复均衡';
    case 'deep_standby_reset': return '深度待机，恢复均衡';
    case 'charging_no_throttle': return '充电温度舒适，保持均衡';
    case 'charging_thermal_mitigation': return '充电温控介入，已压到省电';
    case 'charging_comfort_hot': return '充电体感偏热，已压到省电';
    case 'charging_comfort_cooldown': return '充电温度回落，恢复均衡';
    case 'auto_enabled': return '已启用自动调度';
    case 'manual_policy': return '切回手动';
    case 'manual_selected': return '手动指定模式';
    case 'external_scheduler': return '外部调度让权';
    case 'external_no_scheduler_sanitized': return '外部调度让权';
    default: return '自动调度运行中';
  }
}

function applyProfileState(data) {
  state.profile.currentProfile = PROFILES[data.profile] ? data.profile : 'unknown';
  state.profile.manualProfile = PROFILES[data.manual_profile] ? data.manual_profile : state.profile.currentProfile;
  state.profile.profilePolicy = data.policy === 'auto' ? 'auto' : 'manual';
  state.profile.schedOwner = data.sched_owner === 'external' ? 'external' : 'pixel';
  state.profile.schedEffectiveOwner = data.sched_effective_owner === 'external' ? 'external' : 'pixel';
  state.profile.gameHandoffPolicy = data.game_handoff_policy === 'fas_rs' ? 'fas_rs' : 'off';
  state.profile.arbiterState = typeof data.arbiter_state === 'string' ? data.arbiter_state : '';
  state.profile.arbiterApplyResult = typeof data.arbiter_apply_result === 'string' ? data.arbiter_apply_result : '';
  state.profile.arbiterReason = typeof data.arbiter_reason === 'string' ? data.arbiter_reason : '';
  state.profile.uperfDetected = boolValue(data.uperf_detected);
  state.profile.uperfModuleId = typeof data.uperf_module_id === 'string' ? data.uperf_module_id : '';
  state.profile.uperfModuleName = typeof data.uperf_module_name === 'string' ? data.uperf_module_name : '';
  state.profile.uperfModulePath = typeof data.uperf_module_path === 'string' ? data.uperf_module_path : '';
  state.profile.uperfModuleSource = typeof data.uperf_module_source === 'string' ? data.uperf_module_source : '';
  state.profile.uperfModuleState = typeof data.uperf_module_state === 'string' ? data.uperf_module_state : '';
  state.profile.uperfModuleEnabled = typeof data.uperf_module_enabled === 'string' ? data.uperf_module_enabled : 'no';
  state.profile.uperfProcessAlive = typeof data.uperf_process_alive === 'string' ? data.uperf_process_alive : 'no';
  state.profile.uperfActive = typeof data.uperf_active === 'string' ? data.uperf_active : 'no';
  state.profile.fasRsDetected = boolValue(data.fas_rs_detected);
  state.profile.fasRsModuleId = typeof data.fas_rs_module_id === 'string' ? data.fas_rs_module_id : '';
  state.profile.fasRsModuleName = typeof data.fas_rs_module_name === 'string' ? data.fas_rs_module_name : '';
  state.profile.fasRsModulePath = typeof data.fas_rs_module_path === 'string' ? data.fas_rs_module_path : '';
  state.profile.fasRsModuleSource = typeof data.fas_rs_module_source === 'string' ? data.fas_rs_module_source : '';
  state.profile.fasRsModuleState = typeof data.fas_rs_module_state === 'string' ? data.fas_rs_module_state : '';
  state.profile.fasRsModuleEnabled = typeof data.fas_rs_module_enabled === 'string' ? data.fas_rs_module_enabled : 'no';
  state.profile.fasRsOwnerState = typeof data.fas_rs_owner_state === 'string' ? data.fas_rs_owner_state : '';
  state.profile.fasRsMode = typeof data.fas_rs_mode === 'string' ? data.fas_rs_mode : '';
  state.profile.fasRsProcessAlive = typeof data.fas_rs_process_alive === 'string' ? data.fas_rs_process_alive : 'no';
  state.profile.fasRsRuntimeState = typeof data.fas_rs_runtime_state === 'string' ? data.fas_rs_runtime_state : '';
  state.profile.fasRsRuntimeOwnerActive = typeof data.fas_rs_runtime_owner_active === 'string' ? data.fas_rs_runtime_owner_active : 'no';
  state.profile.fasRsRuntimeTarget = typeof data.fas_rs_runtime_target === 'string' ? data.fas_rs_runtime_target : '';
  state.profile.fasRsActive = typeof data.fas_rs_active === 'string' ? data.fas_rs_active : 'no';
  state.profile.externalSchedulerDetected = boolValue(data.external_scheduler_detected);
  state.profile.externalSchedulerActive = boolValue(data.external_scheduler_active);
  state.profile.externalSchedulerId = typeof data.external_scheduler_id === 'string' ? data.external_scheduler_id : '';
  state.profile.externalSchedulerName = typeof data.external_scheduler_name === 'string' ? data.external_scheduler_name : '';
  state.profile.externalSchedulerKind = typeof data.external_scheduler_kind === 'string' ? data.external_scheduler_kind : '';
  state.profile.externalSchedulerPath = typeof data.external_scheduler_path === 'string' ? data.external_scheduler_path : '';
  state.profile.externalSchedulerSource = typeof data.external_scheduler_source === 'string' ? data.external_scheduler_source : '';
  state.profile.externalSchedulerState = typeof data.external_scheduler_state === 'string' ? data.external_scheduler_state : '';
  state.profile.externalSchedulerEnabled = typeof data.external_scheduler_enabled === 'string' ? data.external_scheduler_enabled : 'no';
  state.profile.effectiveSchedulerOwner = typeof data.effective_scheduler_owner === 'string' ? data.effective_scheduler_owner : 'pixel';
  state.profile.effectiveSchedulerName = typeof data.effective_scheduler_name === 'string' ? data.effective_scheduler_name : '';
  state.profile.effectiveSchedulerKind = typeof data.effective_scheduler_kind === 'string' ? data.effective_scheduler_kind : '';
  state.profile.effectiveSchedulerMode = typeof data.effective_scheduler_mode === 'string' ? data.effective_scheduler_mode : '';
  state.profile.profileSurface = typeof data.profile_surface === 'string' ? data.profile_surface : 'authoritative';
  state.profile.profileSurfaceStale = boolValue(data.profile_surface_stale);
  state.profile.profileSurfaceNote = typeof data.profile_surface_note === 'string' ? data.profile_surface_note : '';
  if (data.cpu_contract && typeof data.cpu_contract === 'object' && data.cpu_contract.profiles) {
    state.profile.cpuContract = data.cpu_contract;
  }
  if (data.scheduler_boot && typeof data.scheduler_boot === 'object') {
    state.profile.schedulerBoot = {
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
    state.profile.schedulerHealth = {
      status: data.scheduler_health.status || '', reason: data.scheduler_health.reason || '',
      checkedEpoch: data.scheduler_health.checked_epoch || '', profileVerified: data.scheduler_health.profile_verified || '',
      cpufreqPermissions: data.scheduler_health.cpufreq_permissions || '', powerhalFailures: data.scheduler_health.powerhal_failures || ''
    };
  }
  if (data.profile_transition && typeof data.profile_transition === 'object') {
    state.profile.profileTransition = {
      key: data.profile_transition.key || '', attempts: Number(data.profile_transition.attempts) || 0,
      firstEpoch: data.profile_transition.first_epoch || '', deadlineEpoch: data.profile_transition.deadline_epoch || '',
      terminal: data.profile_transition.terminal || 'no', ok: data.profile_transition.ok || 'pending',
      result: data.profile_transition.result || ''
    };
  }
  state.profile.autoReason = typeof data.auto_reason === 'string' ? data.auto_reason : '';
  syncProfileUi();
  syncHeroDesc();
}

function applyProfileMutationState(data) {
  latestProfileMutationState = data;
  profileMutationStateRevision += 1;
  if (PROFILES[data.profile]) state.profile.currentProfile = data.profile;
  if (PROFILES[data.manual_profile]) state.profile.manualProfile = data.manual_profile;
  if (data.policy === 'auto' || data.policy === 'manual') state.profile.profilePolicy = data.policy;
  if (data.sched_owner === 'external' || data.sched_owner === 'pixel') state.profile.schedOwner = data.sched_owner;
  if (data.sched_effective_owner === 'external' || data.sched_effective_owner === 'pixel') {
    state.profile.schedEffectiveOwner = data.sched_effective_owner;
  }
  if (data.game_handoff_policy === 'fas_rs' || data.game_handoff_policy === 'off') {
    state.profile.gameHandoffPolicy = data.game_handoff_policy;
  }
  if (typeof data.arbiter_state === 'string') state.profile.arbiterState = data.arbiter_state;
  if (typeof data.arbiter_apply_result === 'string') state.profile.arbiterApplyResult = data.arbiter_apply_result;
  if (typeof data.arbiter_reason === 'string') state.profile.arbiterReason = data.arbiter_reason;
  if (typeof data.auto_reason === 'string') state.profile.autoReason = data.auto_reason;
  if (data.scheduler_boot && typeof data.scheduler_boot === 'object') {
    const boot = data.scheduler_boot;
    state.profile.schedulerBoot = {
      ...state.profile.schedulerBoot,
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
    state.profile.schedulerHealth = {
      status: data.scheduler_health.status || '', reason: data.scheduler_health.reason || '',
      checkedEpoch: data.scheduler_health.checked_epoch || '', profileVerified: data.scheduler_health.profile_verified || '',
      cpufreqPermissions: data.scheduler_health.cpufreq_permissions || '', powerhalFailures: data.scheduler_health.powerhal_failures || ''
    };
  }
  if (data.profile_transition && typeof data.profile_transition === 'object') {
    state.profile.profileTransition = {
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
  ['battery', 'balanced', 'default'].forEach((key) => {
    const p = PROFILES[key];
    const card = document.createElement('article');
    card.className = 'profile-card profile-option';
    card.dataset.profile = key;
    card.tabIndex = 0;
    setStaticHtml(card, `
      <div class="profile-icon" aria-hidden="true">${p.icon}</div>
      <div class="profile-copy">
        <div class="profile-name">${p.name}</div>
        <div class="profile-desc">${p.summary}</div>
      </div>
      <div class="profile-actions">
        <button class="card-info" type="button" data-action="profile-detail" data-profile="${key}" aria-label="查看${p.name}详情">
          <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor"><path d="M11 17h2v-6h-2v6zm0-8h2V7h-2v2zm1-7C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2z"/></svg>
        </button>
        <div class="p-check" aria-hidden="true"><svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg></div>
      </div>`);
    card.addEventListener('click', (evt) => {
      if (evt.target.closest('[data-action="profile-detail"]')) return;
      applyProfile(key);
    });
    card.addEventListener('keydown', (evt) => {
      if (evt.key === 'Enter' || evt.key === ' ') {
        evt.preventDefault();
        applyProfile(key);
      }
    });
    refs.profileList.appendChild(card);
  });
}

function ensureHomeCpuRows(clusters) {
  if (state.profile.homeCpuRows && state.profile.homeCpuRows.length === clusters.length) return;
  refs.homeCpuRows.replaceChildren();
  state.profile.homeCpuRows = clusters.map((cluster, index) => {
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
    return { fill, freq, maxHz: CLUSTERS[index]?.maxHz || 3105000 };
  });
}

function ensurePerfCpuRows(clusters) {
  if (state.profile.cpuRows && state.profile.cpuRows.length === clusters.length) return;
  refs.cpuRows.replaceChildren();
  state.profile.cpuRows = clusters.map((cluster, index) => {
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
    return { current, max, fill, params, maxHz: CLUSTERS[index]?.maxHz || 3105000 };
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
  return apiFetch(API.profile, { timeoutMs: 45000 })
    .then((fullState) => {
      if (generation !== profileFullStateGeneration) return false;
      const newerMutationState = mutationRevision !== profileMutationStateRevision
        ? latestProfileMutationState
        : null;
      applyProfileState(fullState);
      if (newerMutationState) applyProfileMutationState(newerMutationState);
      return true;
    })
    .catch(() => false);
}

async function loadSavedProfile() {
  try {
    const data = await apiFetch(`${API.profile}?compact=1`, { timeoutMs: 8000 });
    applyProfileMutationState(data);
    void refreshFullProfileState();
  } catch (_) {
    state.profile.currentProfile = 'unknown';
    state.profile.manualProfile = 'balanced';
    state.profile.profilePolicy = 'manual';
    state.profile.schedOwner = 'pixel';
    state.profile.schedEffectiveOwner = 'pixel';
    state.profile.gameHandoffPolicy = 'off';
    state.profile.arbiterState = '';
    state.profile.arbiterApplyResult = '';
    state.profile.arbiterReason = '';
    state.profile.uperfDetected = false;
    state.profile.uperfModuleId = '';
    state.profile.uperfModuleName = '';
    state.profile.uperfModulePath = '';
    state.profile.uperfModuleSource = '';
    state.profile.uperfModuleState = '';
    state.profile.uperfModuleEnabled = 'no';
    state.profile.uperfProcessAlive = 'no';
    state.profile.uperfActive = 'no';
    state.profile.fasRsDetected = false;
    state.profile.fasRsModuleId = '';
    state.profile.fasRsModuleName = '';
    state.profile.fasRsModulePath = '';
    state.profile.fasRsModuleSource = '';
    state.profile.fasRsModuleState = '';
    state.profile.fasRsModuleEnabled = 'no';
    state.profile.fasRsOwnerState = '';
    state.profile.fasRsMode = '';
    state.profile.fasRsProcessAlive = 'no';
    state.profile.fasRsRuntimeState = '';
    state.profile.fasRsRuntimeOwnerActive = 'no';
    state.profile.fasRsRuntimeTarget = '';
    state.profile.fasRsActive = 'no';
    state.profile.externalSchedulerDetected = false;
    state.profile.externalSchedulerActive = false;
    state.profile.externalSchedulerId = '';
    state.profile.externalSchedulerName = '';
    state.profile.externalSchedulerKind = '';
    state.profile.externalSchedulerPath = '';
    state.profile.externalSchedulerSource = '';
    state.profile.externalSchedulerState = '';
    state.profile.externalSchedulerEnabled = 'no';
    state.profile.effectiveSchedulerOwner = 'pixel';
    state.profile.effectiveSchedulerName = 'Pixel9Pro-Control';
    state.profile.effectiveSchedulerKind = 'pixel';
    state.profile.effectiveSchedulerMode = '';
    state.profile.profileSurface = 'authoritative';
    state.profile.profileSurfaceStale = false;
    state.profile.profileSurfaceNote = '';
    state.profile.autoReason = '';
    syncProfileUi();
    syncHeroDesc();
  }
}

async function refreshCpu() {
  if (state.profile.cpuBusy) return;
  state.profile.cpuBusy = true;
  if (refs.refreshBtn) refs.refreshBtn.disabled = true;
  try {
    const clusters = await apiFetch(API.status, { timeoutMs: 6000 });
    state.profile.lastClusters = clusters;
    ensurePerfCpuRows(clusters);
    ensureHomeCpuRows(clusters);
    clusters.forEach((cluster, index) => {
      const perf = state.profile.cpuRows[index];
      const home = state.profile.homeCpuRows[index];
      const maxHz = cluster.max > 0 ? cluster.max : perf.maxHz;
      perf.current.textContent = !cluster.cur || Number.isNaN(cluster.cur) ? '—' : `${(cluster.cur / 1000).toFixed(0)} MHz`;
      perf.max.textContent = ` / ${(maxHz / 1000).toFixed(0)} MHz`;
      perf.fill.style.transform = `scaleX(${Math.min(cluster.cur / maxHz, 1).toFixed(3)})`;
      const respText = typeof cluster.resp_ms_text === 'string' ? cluster.resp_ms_text : cluster.resp_ms;
      const downText = typeof cluster.down_us_text === 'string' ? cluster.down_us_text : cluster.down_us;
      perf.params.textContent = `resp=${formatSchedValue(respText, 'ms')} · down=${formatSchedValue(downText, 'µs')} · gov=${cluster.gov}`;
      home.freq.textContent = !cluster.cur || Number.isNaN(cluster.cur) ? '—' : `${(cluster.cur / 1000).toFixed(0)} MHz`;
      home.fill.style.transform = `scaleX(${!cluster.cur ? 0 : Math.min(cluster.cur / maxHz, 1).toFixed(3)})`;
    });
    try {
      const profileData = await apiFetch(`${API.profile}?compact=1`, { timeoutMs: 8000 });
      applyProfileMutationState(profileData);
    } catch (_) {}
  } catch (err) {
    state.profile.cpuRows = null;
    state.profile.homeCpuRows = null;
    const el = document.createElement('div');
    el.className = 'note-body';
    el.style.color = 'var(--danger)';
    el.textContent = '获取频率失败：' + err.message;
    refs.cpuRows.replaceChildren();
    refs.cpuRows.appendChild(el);
  } finally {
    if (refs.refreshBtn) refs.refreshBtn.disabled = false;
    state.profile.cpuBusy = false;
  }
}

async function applyProfile(profile) {
  if (state.profile.schedOwner === 'external') {
    showToast(hasExternalScheduler() ? getSchedulerStatusText() : '本模块调度未启用');
    appendLog(hasExternalScheduler()
      ? `${getSchedulerStatusText()}，未切换本模块 profile`
      : '本模块 CPU 调度未启用，未切换 profile', 'warn');
    return;
  }
  if (profile === state.profile.currentProfile || state.profile.cpuBusy || isCurrentStrategyBusy()) return;
  const prevPolicy = state.profile.profilePolicy;
  const card = refs.profileList.querySelector(`[data-profile="${profile}"]`);
  if (!card) return;
  state.profile.profileApplyBusy = true;
  invalidateFullProfileStateRefresh();
  syncProfileUi();
  card.classList.add('loading');
  appendLog(`切换到 ${PROFILES[profile].name}…`, 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.profile, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ profile }), timeoutMs: PROFILE_MUTATION_TIMEOUT_MS });
    if (data.ok) {
      applyProfileMutationState(data);
      const forcedManual = prevPolicy === 'auto' && data.policy === 'manual';
      showToast(forcedManual ? `已切回手动：${PROFILES[profile].name}` : `切换至：${PROFILES[profile].name}`);
      appendLog(forcedManual ? `自动已退出，手动切到 ${PROFILES[profile].name}` : `${PROFILES[profile].name} 已应用`, 'ok');
      refreshCpu();
    } else {
      showToast(`切换失败：${data.error || '未知'}`);
      appendLog(data.error || '切换失败', 'err');
    }
  } catch (err) {
    showToast('请求失败，检查服务是否运行');
    appendLog(String(err), 'err');
  } finally {
    card.classList.remove('loading');
    state.profile.profileApplyBusy = false;
    syncProfileUi();
    void refreshFullProfileState();
  }
}

async function setProfilePolicy(policy) {
  if (state.profile.schedOwner === 'external') {
    showToast(hasExternalScheduler() ? getSchedulerStatusText() : '本模块调度未启用');
    appendLog(hasExternalScheduler()
      ? `${getSchedulerStatusText()}，自动/手动策略暂停`
      : '本模块 CPU 调度未启用，自动/手动策略暂停', 'warn');
    return;
  }
  if (state.profile.profilePolicy === policy || isCurrentStrategyBusy()) return;
  state.profile.profilePolicyBusy = true;
  invalidateFullProfileStateRefresh();
  syncProfileUi();
  appendLog(policy === 'auto' ? '启用自动调度…' : '切回手动调度…', 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.profile, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ policy }),
      timeoutMs: PROFILE_MUTATION_TIMEOUT_MS
    });
    if (data.ok) {
      applyProfileMutationState(data);
      showToast(policy === 'auto' ? '已启用自动调度' : `已切回手动：${PROFILES[state.profile.currentProfile].name}`);
      appendLog(policy === 'auto'
        ? `自动调度已启用：${describeAutoReason(state.profile.autoReason)}`
        : `已切回手动：${PROFILES[state.profile.currentProfile].name}`, 'ok');
      refreshCpu();
    } else {
      showToast(`切换失败：${data.error || '未知'}`);
      appendLog(data.error || '切换失败', 'err');
    }
  } catch (err) {
    showToast('请求失败，检查服务是否运行');
    appendLog(String(err), 'err');
  } finally {
    state.profile.profilePolicyBusy = false;
    syncProfileUi();
    void refreshFullProfileState();
  }
}

async function toggleSchedOwner() {
  if (isCurrentStrategyBusy()) return;
  if (state.profile.schedulerBoot.phase === 'pending_reboot') {
    await cancelSchedulerChange();
    return;
  }
  const nextOwner = state.profile.schedulerBoot.effectiveMode === 'ugt' ? 'pixel' : 'external';
  state.profile.schedOwnerBusy = true;
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
      timeoutMs: 25000
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
    showToast('请求失败，检查服务是否运行');
    appendLog(String(err), 'err');
  } finally {
    state.profile.schedOwnerBusy = false;
    syncProfileUi();
    void refreshFullProfileState();
  }
}

async function cancelSchedulerChange() {
  if (isCurrentStrategyBusy()) return;
  state.profile.schedOwnerBusy = true;
  invalidateFullProfileStateRefresh();
  syncProfileUi();
  try {
    const data = await apiFetch(API.profile, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ scheduler_action: 'cancel_pending' }), timeoutMs: 25000
    });
    if (data.scheduler_boot) applyProfileMutationState(data);
    if (data.ok) {
      refs.rebootModal.classList.remove('open');
      showToast('已取消待重启切换');
      appendLog('调度启动模式已恢复到本次 boot 的状态', 'ok');
    } else {
      showToast(`取消失败：${data.error || data.scheduler_boot?.reason || '未知'}`);
      appendLog(data.error || '取消待重启切换失败', 'err');
    }
  } catch (err) {
    showToast('请求失败，检查服务是否运行');
    appendLog(String(err), 'err');
  } finally {
    state.profile.schedOwnerBusy = false;
    syncProfileUi();
    void refreshFullProfileState();
  }
}

async function retrySchedulerValidation() {
  if (isCurrentStrategyBusy()) return;
  state.profile.schedulerRetryBusy = true;
  invalidateFullProfileStateRefresh();
  syncProfileUi();
  try {
    const data = await apiFetch(API.profile, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ scheduler_action: 'retry' }), timeoutMs: 45000
    });
    if (data.scheduler_boot) applyProfileMutationState(data);
    if (data.ok) {
      showToast('调度控制面验证通过');
      appendLog(`调度终态：${data.scheduler_boot?.result || 'success'}`, 'ok');
    } else {
      showToast(`验证失败：${data.scheduler_boot?.reason || data.error || '未知'}`);
      appendLog(`调度终态失败：${data.scheduler_boot?.result || data.error || 'unknown'}`, 'err');
    }
  } catch (err) {
    showToast('请求失败，检查服务是否运行');
    appendLog(String(err), 'err');
  } finally {
    state.profile.schedulerRetryBusy = false;
    syncProfileUi();
    void refreshFullProfileState();
  }
}

async function toggleGameHandoff() {
  if (isCurrentStrategyBusy() || !state.profile.fasRsDetected || !isVerifiedSchedulerBoot()) return;
  const nextPolicy = state.profile.gameHandoffPolicy === 'fas_rs' ? 'off' : 'fas_rs';
  state.profile.gameHandoffBusy = true;
  invalidateFullProfileStateRefresh();
  syncProfileUi();
  appendLog(nextPolicy === 'fas_rs' ? '启用 fas-rs 游戏临时接管…' : '关闭 fas-rs 游戏临时接管…', 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.profile, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ game_handoff: nextPolicy }),
      timeoutMs: 45000
    });
    if (typeof data.game_handoff_policy === 'string') applyProfileMutationState(data);
    if (data.accepted && data.final === false) {
      showToast('接管偏好已保存，等待调度状态同步');
      appendLog(data.pending_reason || '共享调度事务正在执行，后台将继续同步', 'warn');
    } else if (data.ok) {
      showToast(nextPolicy === 'fas_rs' ? 'fas-rs 游戏接管已启用' : 'fas-rs 游戏接管已关闭');
      appendLog(nextPolicy === 'fas_rs'
        ? 'fas-rs 保持常驻待机；命中游戏并建立有效 lease 后临时接管'
        : '游戏场景保持日常调度选择', 'ok');
      await refreshCpu();
    } else {
      const detail = data.arbiter_apply_result || data.error || '状态复读未通过';
      showToast(`切换未完成：${detail}`);
      appendLog(detail, 'err');
    }
  } catch (err) {
    showToast('请求失败，检查服务是否运行');
    appendLog(String(err), 'err');
  } finally {
    state.profile.gameHandoffBusy = false;
    syncProfileUi();
    void refreshFullProfileState();
  }
}

async function triggerOwnerArbiter() {
  if (isCurrentStrategyBusy() || !state.profile.fasRsDetected) return;
  state.profile.ownerArbiterBusy = true;
  syncProfileUi();
  appendLog('正在检查外部调度接管状态…', 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.ownerArbiter, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'tick' }),
      timeoutMs: 10000
    });
    if (data.ok) {
      showToast('调度状态已更新');
      appendLog('外部调度接管状态已更新', 'ok');
      await loadSavedProfile();
      await refreshCpu();
    } else {
      showToast(`检查失败：${data.error || '未知'}`);
      appendLog(data.error || '外部调度状态检查失败', 'err');
    }
  } catch (err) {
    showToast('请求失败，检查 WebUI 服务');
    appendLog(String(err), 'err');
  } finally {
    state.profile.ownerArbiterBusy = false;
    syncProfileUi();
  }
}

registerFeature('profile', {
  initialize: renderProfileCards,
  load: loadSavedProfile,
  refresh: refreshCpu
});

