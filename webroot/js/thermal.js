// 温控档位、传感器状态与温度历史功能。
'use strict';
(() => {
const state = {
  contract: null,
  currentPolicy: 'unknown',
  currentOffset: null,
  thermalBusy: false,
  thermalReadRequest: null,
  lastSkinTempC: null,
  thermalApplyBusy: false,
  selectionPending: null,
  selectionModalDismissed: false,
  thermalCancelBusy: false,
  rebootBusy: false,
  mutationRevision: 0,
  verificationNotice: '',
  verificationExpected: null,
  contractReadError: '',
  thermalContractRequest: null,
  thermalContractRetryTimer: null,
  thermalContractRetryAttempts: 0,
  repairRequired: false,
  metamoduleActive: false,
  reinstallRequired: false,
  sensorRefs: null,
  homeSensorRefs: null,
  thermalModal: {
    pending: null,
    prev: null,
    pendingId: '',
    cancelSupported: false,
    rebootRequired: false,
    cancelReconcileNeeded: false,
    dismissedPendingId: ''
  }
};

const THERMAL_REQUEST_TIMEOUTS = Object.freeze({
  contract: 15000,
  mutation: 30000,
  readback: 15000
});

const THERMAL_REINSTALL_NOTICE = '修改需卸载模块、重启、重新安装并重新选择';
const THERMAL_REBOOT_NOTICE = '温控配置已保存，重启手机后应用；当前运行中的温控服务保持原状态。';

const THERMAL_POLICY_PRESETS = {
  system: {
    name: '不修改温控',
    summary: '保留系统温控配置，模块不修改温控阈值。',
    detail: '<p>沿用系统温控配置，模块不生成替代配置。</p><p>温控阈值和温控服务继续由系统管理。</p>',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M13 3C8.03 3 4 7.03 4 12H1l4 4 4-4H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.95-2.05l-1.41 1.41A8.96 8.96 0 0013 21c4.97 0 9-4.03 9-9s-4.03-9-9-9z"/></svg>',
  },
};

const core = () => requireFeature('core');
const apiFetch = (...args) => core().apiFetch(...args);
const isCancelled = (err) => core().isRequestCancelled?.(err) === true;
const appendLog = (...args) => core().appendLog(...args);
const showToast = (...args) => core().showToast(...args);
const setStaticHtml = (...args) => requireFeature('ui').setStaticHtml(...args);
const openRebootModal = (...args) => requireFeature('ui').openRebootModal(...args);

// 温度色阶 (单一真源): 青绿→黄→橙→红, 语义固定不交动态色 (doc 17 §11)
const TEMP_SCALE = [
  { max: 36, color: 'var(--temp-cool)' },
  { max: 40, color: 'var(--temp-normal)' },
  { max: 44, color: 'var(--temp-warm)' },
  { max: 48, color: 'var(--temp-hot)' },
  { color: 'var(--temp-danger)' },
];

function tempHex(t) {
  for (const stop of TEMP_SCALE) {
    if (stop.max === undefined || t < stop.max) return stop.color;
  }
  return TEMP_SCALE[TEMP_SCALE.length - 1].color;
}

function tempStatus() {
  return '当前传感器读数；温控介入由系统传感器和策略共同决定';
}

function barPct(t) {
  return Math.min(Math.max((t - TEMP_MIN) / (TEMP_MAX - TEMP_MIN), 0), 1) * 100;
}

function positionMarkers() {
  // An offset alone cannot establish a threshold for the displayed sensor.
  [refs.mkStock, refs.mkStockLbl, refs.mkMod, refs.mkModLbl].forEach((marker) => { marker.hidden = true; });
}

function formatThermalOffset(policy, offset) {
  if (policy === 'system') return '系统阈值';
  const value = Number(offset);
  if (!Number.isFinite(value) || value === 0) return '原厂阈值';
  return `当前阈值 ${value > 0 ? '+' : ''}${value}°C`;
}

function updateThermalRuntimeGuard(data) {
  if (!data || typeof data !== 'object') return;
  if (Object.prototype.hasOwnProperty.call(data, 'metamodule_active')) {
    state.metamoduleActive = data.metamodule_active === true || data.metamodule_active === 'true';
  }
  if (Object.prototype.hasOwnProperty.call(data, 'reinstall_required')) {
    state.reinstallRequired = data.reinstall_required === true || data.reinstall_required === 'true';
  }
}

function validThermalSelection(policy, offset) {
  if (!state.contract?.policies.includes(policy)) return false;
  if (offset === null || offset === '' || !Number.isFinite(Number(offset)) || !Number.isInteger(Number(offset))) return false;
  return policy !== 'custom' || state.contract.offsets.includes(Number(offset));
}

function matchesThermalExpectation(data, expectation) {
  return validThermalSelection(data?.policy, data?.offset)
    && data.policy === expectation.policy
    && (expectation.policy !== 'custom' || Number(data.offset) === Number(expectation.offset))
    && (expectation.pending === undefined || data.pending === expectation.pending);
}

function applyThermalState(data) {
  if (!validThermalSelection(data?.policy, data?.offset)) return false;
  state.currentPolicy = data.policy;
  state.currentOffset = Number(data.offset);
  state.repairRequired = data.repair_required === true;
  return true;
}

function setRebootError(message = '') {
  requireFeature('ui').setRebootError(message);
}

function pendingIdFrom(data) {
  const id = typeof data?.pending_id === 'string' ? data.pending_id.trim() : '';
  return id.length >= 1 && id.length <= 256 && !/[\r\n\t]/.test(id) ? id : '';
}

function updatePendingState(data, { open = true } = {}) {
  // Older non-Hybrid endpoints do not expose pending fields. Preserve their
  // existing flow instead of interpreting an omitted field as "no pending".
  if (!Object.prototype.hasOwnProperty.call(data || {}, 'pending')) return;
  const pending = data.pending === true || data.pending === 'true';
  const hadPending = Boolean(state.thermalModal.pendingId || state.thermalModal.pending);
  const pendingId = pendingIdFrom(data);
  if (pendingId && pendingId !== state.thermalModal.pendingId) {
    state.thermalModal.dismissedPendingId = '';
    state.thermalModal.cancelReconcileNeeded = false;
  }
  state.thermalModal.pendingId = pendingId;
  state.thermalModal.cancelSupported = pending && data.cancel_supported === true && Boolean(pendingId);
  state.thermalModal.rebootRequired = data.reboot_required !== false;
  if (!pending) {
    state.thermalModal.cancelReconcileNeeded = false;
    state.thermalModal.pending = null;
    state.thermalModal.prev = null;
    state.thermalModal.pendingId = '';
    state.thermalModal.cancelSupported = false;
    state.thermalModal.rebootRequired = false;
    if (hadPending && !state.thermalCancelBusy && refs.rebootModal?.classList.contains('open')
      && requireFeature('ui').getRebootContext?.() === 'thermal') {
      requireFeature('ui').closeRebootModal('', { force: true, silent: true });
    }
    return;
  }
  state.thermalModal.pending = {
    policy: data.policy,
    offset: Number(data.offset),
    pending_id: pendingId,
    cancel_supported: state.thermalModal.cancelSupported,
    reboot_required: state.thermalModal.rebootRequired
  };
  if (open && state.thermalModal.rebootRequired && pendingId !== state.thermalModal.dismissedPendingId
    && !refs.rebootModal.classList.contains('open')) {
    openRebootModal(state.thermalModal.pending, null);
  }
}

function isThermalZoneValid(zone) {
  if (!zone || typeof zone.zone !== 'string') return false;
  const temp = Number(zone.temp);
  return Number.isFinite(temp) && temp >= 10000 && temp <= 85000;
}

async function readThermalZones(controller) {
  // A normal read can legitimately rebuild the cache after the 60-second
  // worker tick. Keep enough time for one dumpsys without letting a stuck CGI
  // hold the UI indefinitely. All live paths share the same bounded policy.
  const options = {
    requestClass: 'thermalLive',
    controller,
    scope: 'thermal.read'
  };
  const zones = await apiFetch(API.thermal, options);
  if (!Array.isArray(zones) || !zones.length) throw new Error('未读取到热区数据');
  const valid = zones.filter(isThermalZoneValid);
  const skin = valid.find((zone) => zone.zone === 'VIRTUAL-SKIN') || valid.find((zone) => zone.zone === 'SKIN');
  if (!skin) throw new Error('VIRTUAL-SKIN 未找到');
  return valid;
}

function syncHeroDesc() {
  const parts = [];
  const visiblePolicy = state.selectionPending?.policy || state.currentPolicy;
  const visibleOffset = state.selectionPending?.offset ?? state.currentOffset;
  const preset = visiblePolicy === 'custom'
    ? THERMAL_PRESETS[visibleOffset]
    : THERMAL_POLICY_PRESETS[visiblePolicy];
  const scheduler = requireFeature('profile').getThermalContext();
  const swapMode = requireFeature('memory').getSwapMode();
  if (preset) parts.push(preset.name);
  if (scheduler.schedulerMode !== 'active') parts.push('本模块调度关闭');
  else if (scheduler.schedEffectiveOwner === 'external') parts.push(scheduler.hasExternalScheduler ? (scheduler.externalSchedulerActive ? '外部调度接管' : '外部调度未启用') : '调度停用');
  else if (scheduler.hasExternalScheduler) parts.push('覆盖外部调度');
  if (swapMode === 'optimized') parts.push('内存已优化');
  else if (swapMode === 'disabled') parts.push('VM 写入关闭');
  else if (swapMode === 'system') parts.push('内存系统默认');
  if (state.reinstallRequired) parts.push(THERMAL_REINSTALL_NOTICE);
  if (state.repairRequired) parts.push('温控状态需要修复，可发送 repair_system 后重启');
  if (state.selectionPending) parts.push('正在保存温控配置…');
  refs.heroDesc.textContent = parts.join(' · ') || '正在读取配置…';
}

function syncThermalUi() {
  const visiblePolicy = state.selectionPending?.policy || state.currentPolicy;
  const visibleOffset = state.selectionPending?.offset ?? state.currentOffset;
  const preset = visiblePolicy === 'custom'
    ? THERMAL_PRESETS[visibleOffset]
    : THERMAL_POLICY_PRESETS[visiblePolicy];
  if (!preset) {
    refs.thermalCurrentName.textContent = '温控状态未确认';
    refs.thermalCurrentDesc.textContent = state.contractReadError || '尚未取得有效策略，请刷新状态。';
    refs.topbarThermalChip.textContent = '温控 · 未确认';
    return;
  }
  refs.topbarThermalChip.textContent = `温控 ${preset.name}`;
  refs.thermalCurrentName.textContent = preset.name;
  refs.thermalCurrentDesc.textContent = state.reinstallRequired
    ? `${preset.summary} · ${THERMAL_REINSTALL_NOTICE}`
    : state.repairRequired
      ? `${preset.summary} · 温控状态需要修复并重启`
    : preset.summary;
  if (state.verificationNotice) refs.thermalCurrentDesc.textContent += ` · ${state.verificationNotice}`;
  if (state.contractReadError) refs.thermalCurrentDesc.textContent += ` · ${state.contractReadError}`;
  const label = formatThermalOffset(visiblePolicy, visibleOffset);
  [refs.homeModBadge, refs.thModBadge].forEach((el) => {
    el.textContent = label;
    el.className = `badge ${visiblePolicy !== 'custom' || visibleOffset === 0 ? 'off' : 'default'}`;
  });
  const pendingBlocked = Boolean(state.thermalModal.pendingId || state.thermalModal.pending);
  if (refs.thermalPendingBtn) {
    refs.thermalPendingBtn.hidden = !pendingBlocked && !state.thermalApplyBusy && !state.thermalCancelBusy;
    refs.thermalPendingBtn.textContent = state.thermalCancelBusy ? '查看撤销进度'
      : state.thermalApplyBusy ? '查看保存进度' : '查看待重启变更';
  }
  document.querySelectorAll('.thermal-option').forEach((card) => {
    const selected = card.dataset.policy === visiblePolicy
      && (visiblePolicy !== 'custom' || Number(card.dataset.offset) === Number(visibleOffset));
    card.classList.toggle('selected', selected);
    card.classList.toggle('disabled', state.reinstallRequired
      || (state.repairRequired && card.dataset.policy === 'custom') || pendingBlocked);
    const select = card.querySelector('.profile-select');
    select.disabled = state.reinstallRequired
      || (state.repairRequired && card.dataset.policy === 'custom')
      || state.thermalApplyBusy || pendingBlocked;
    select.setAttribute('aria-checked', String(selected));
    select.tabIndex = !select.disabled && selected ? 0 : -1;
  });
  const choices = Array.from(refs.thermalList.querySelectorAll('.profile-select:not(:disabled)'));
  if (!choices.some((choice) => choice.tabIndex === 0) && choices[0]) choices[0].tabIndex = 0;
  positionMarkers();
}

function renderThermalCards() {
  refs.thermalList.replaceChildren();
  refs.thermalList.setAttribute('role', 'radiogroup');
  refs.thermalList.setAttribute('aria-label', '温控档位');
  if (!state.contract) return;
  const appendCard = (policy, preset, offset = null) => {
    const card = document.createElement('article');
    card.className = `profile-card thermal-option${state.reinstallRequired || (state.repairRequired && policy === 'custom') || (state.thermalModal.pendingId || state.thermalModal.pending) ? ' disabled' : ''}`;
    card.dataset.policy = policy;
    if (offset !== null) card.dataset.offset = String(offset);
    const itemId = policy === 'system' ? 'system' : `offset-${offset}`;
    const detailAction = `<button class="card-info" type="button" data-action="thermal-detail" data-policy="${policy}" data-offset="${offset ?? ''}" aria-label="查看${preset.name}详情">说明</button>`;
    setStaticHtml(card, `
      <button class="profile-select" type="button" role="radio" aria-checked="false" aria-labelledby="thermal-name-${itemId}" aria-describedby="thermal-desc-${itemId}" ${state.reinstallRequired || (state.repairRequired && policy === 'custom') ? 'disabled' : ''}>
        <span class="profile-icon" aria-hidden="true">${preset.icon}</span>
        <span class="profile-copy">
          <span class="profile-name" id="thermal-name-${itemId}">${preset.name}</span>
          <span class="profile-desc" id="thermal-desc-${itemId}">${preset.summary}</span>
        </span>
        <span class="p-check" aria-hidden="true"><svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg></span>
      </button>${detailAction}`);
    const select = card.querySelector('.profile-select');
    select.addEventListener('click', () => {
      if (state.reinstallRequired) return;
      applyThermalSelection(policy, offset);
    });
    select.addEventListener('keydown', (evt) => {
      if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End'].includes(evt.key)) return;
      evt.preventDefault();
      const items = Array.from(refs.thermalList.querySelectorAll('.profile-select:not(:disabled)'));
      const step = ['ArrowLeft', 'ArrowUp'].includes(evt.key) ? -1 : 1;
      const index = evt.key === 'Home' ? 0 : evt.key === 'End' ? items.length - 1 : (items.indexOf(select) + step + items.length) % items.length;
      items[index]?.focus();
      items.forEach((item) => { item.tabIndex = item === items[index] ? 0 : -1; });
    });
    refs.thermalList.appendChild(card);
  };
  appendCard('system', THERMAL_POLICY_PRESETS.system);
  state.contract.offsets.forEach((offset) => {
    const preset = THERMAL_PRESETS[offset];
    appendCard('custom', { ...preset, summary: `自定义 ${offset > 0 ? '+' : ''}${offset}°C · ${preset.summary}` }, offset);
  });
}

function applyThermalContract(data) {
  const raw = data?.thermal_contract;
  const policies = Array.isArray(raw?.policies) ? raw.policies : [];
  const defaultPolicy = String(raw?.default_policy || '');
  const offsets = Array.isArray(raw?.offsets) ? raw.offsets.map(Number) : [];
  const defaultOffset = Number(raw?.default_offset);
  const uniqueOffsets = new Set(offsets);
  const valid = policies.length === 2
    && policies.join(',') === 'system,custom'
    && policies.includes(defaultPolicy)
    && offsets.length > 0
    && uniqueOffsets.size === offsets.length
    && offsets.every((offset) => Number.isFinite(offset) && THERMAL_PRESETS[offset])
    && uniqueOffsets.has(defaultOffset);
  if (!valid) throw new Error('服务返回的温控档位不完整，暂时无法修改');
  state.contract = { policies, defaultPolicy, offsets, defaultOffset };
}

function ensureSensorRefs(container, key, zones, className) {
  const signature = zones.map((zone) => zone.zone).join(',');
  if (state[key] && state[key].map((entry) => entry.zone).join(',') === signature) return state[key];
  container.replaceChildren();
  state[key] = zones.map((zone) => {
    const node = document.createElement('div');
    node.className = className;
    let label;
    let value;
    if (className === 'sensor-chip') {
      label = document.createElement('span');
      label.className = 'sensor-chip-label';
      value = document.createElement('span');
      value.className = 'sensor-chip-value';
    } else {
      label = document.createElement('span');
      value = document.createElement('span');
    }
    label.textContent = ZONE_LABELS[zone.zone] || zone.zone;
    node.append(label, value);
    container.appendChild(node);
    return { zone: zone.zone, value };
  });
  return state[key];
}

async function loadThermalPreset({ readback = false } = {}) {
  if (!readback && !core().isWebUiActive()) return null;
  if (readback) state.thermalContractRequest?.abort('REQUEST_SUPERSEDED');
  return core().runFeatureTask(readback ? 'thermal.contract.readback' : 'thermal.contract.load', async () => {
    let result = false;
    const revision = state.mutationRevision;
    const controller = new AbortController();
    if (!readback) state.thermalContractRequest = controller;
    try {
      const data = await apiFetch(API.thermalSet, { timeoutMs: THERMAL_REQUEST_TIMEOUTS.contract, controller, priority: readback ? 'interactive' : 'normal', scope: 'thermal.contract.read' });
      if (revision !== state.mutationRevision) return null;
      updateThermalRuntimeGuard(data);
      applyThermalContract(data);
      if (!applyThermalState(data)) throw new Error('温控实际策略无效，保留上次已确认状态');
      state.contractReadError = '';
      state.thermalContractRetryAttempts = 0;
      if (state.thermalContractRetryTimer) {
        clearTimeout(state.thermalContractRetryTimer);
        state.thermalContractRetryTimer = null;
      }
      updatePendingState(data);
      if (state.verificationExpected?.revision === state.mutationRevision
        && matchesThermalExpectation(data, state.verificationExpected)) {
        state.verificationExpected = null;
        state.verificationNotice = '';
      }
      renderThermalCards();
      result = true;
    } catch (err) {
      if (isCancelled(err) || revision !== state.mutationRevision) return null;
      state.contractReadError = `温控状态读取失败：${err.message || err}`;
      // A transient WebUI/CGI failure must not erase an already valid contract.
      // Retry a bounded number of times so a slow post-boot service does not
      // leave the thermal cards permanently blank until a full page reload.
      if (!readback && core().isWebUiActive()
        && !validThermalSelection(state.currentPolicy, state.currentOffset) && state.thermalContractRetryAttempts < 5) {
        state.thermalContractRetryAttempts += 1;
        if (!state.thermalContractRetryTimer) {
          state.thermalContractRetryTimer = window.setTimeout(() => {
            state.thermalContractRetryTimer = null;
            if (core().isWebUiActive()) void loadThermalPreset();
          }, 1500 * state.thermalContractRetryAttempts);
        }
      }
      result = false;
    } finally {
      if (state.thermalContractRequest === controller) state.thermalContractRequest = null;
    }
    syncThermalUi();
    syncHeroDesc();
    return result;
  });
}

async function refreshThermalTask() {
  if (!core().isWebUiActive()) return null;
  if (!state.contract && !state.thermalContractRetryTimer) void loadThermalPreset();
  state.thermalBusy = true;
  const controller = new AbortController();
  state.thermalReadRequest = controller;
  try {
    // A failed GET is not permission to clear state or repeat a HAL dump.
    const zones = await readThermalZones(controller);
    const skin = zones.find((zone) => zone.zone === 'VIRTUAL-SKIN') || zones.find((zone) => zone.zone === 'SKIN');
    const secondary = zones.filter((zone) => zone !== skin && ['soc_therm', 'battery', 'charging_therm', 'btmspkr_therm'].includes(zone.zone));
    refs.homeThermalSkel.hidden = true;
    refs.homeThermalContent.hidden = false;
    refs.thermalSkel.hidden = true;
    refs.thermalContent.hidden = false;
    if (skin) {
      const tempC = skin.temp / 1000;
      state.lastSkinTempC = tempC;
      const color = tempHex(tempC);
      refs.homeTempNum.textContent = tempC.toFixed(1);
      refs.homeTempNum.style.color = color;
      refs.homeTempStatus.textContent = tempStatus(tempC);
      refs.homeTempStatus.style.color = color;
      refs.tempNum.textContent = tempC.toFixed(1);
      refs.tempNum.style.color = color;
      refs.tempZone.textContent = ZONE_LABELS[skin.zone] || skin.zone;
      refs.tempStatus.textContent = tempStatus(tempC);
      refs.tempStatus.style.color = color;
      refs.tempFill.style.width = `${barPct(tempC)}%`;
      refs.tempFill.style.background = color;
    } else {
      refs.homeTempNum.textContent = '--';
      refs.homeTempStatus.textContent = 'VIRTUAL-SKIN 未找到';
      refs.tempNum.textContent = '--';
      refs.tempZone.textContent = 'VIRTUAL-SKIN';
      refs.tempStatus.textContent = '未找到热区，请确认已注册';
    }
    const homeRefs = ensureSensorRefs(refs.homeSensorList, 'homeSensorRefs', secondary, 'sensor-row');
    const gridRefs = ensureSensorRefs(refs.sensorGrid, 'sensorRefs', secondary, 'sensor-chip');
    secondary.forEach((zone, index) => {
      const tempC = zone.temp / 1000;
      const color = tempHex(tempC);
      homeRefs[index].value.textContent = `${tempC.toFixed(1)}°C`;
      homeRefs[index].value.style.color = color;
      gridRefs[index].value.textContent = `${tempC.toFixed(1)}°C`;
      gridRefs[index].value.style.color = color;
    });
    return true;
  } catch (err) {
    if (isCancelled(err)) return null;
    refs.homeThermalSkel.hidden = true;
    refs.homeThermalContent.hidden = false;
    refs.thermalSkel.hidden = true;
    refs.thermalContent.hidden = false;
    if (state.lastSkinTempC === null) {
      refs.homeTempNum.textContent = '--';
      refs.tempNum.textContent = '--';
    }
    const message = state.lastSkinTempC === null ? err.message : `读取失败，保留上次读数：${err.message}`;
    refs.homeTempStatus.textContent = message;
    refs.tempStatus.textContent = message;
    return false;
  } finally {
    state.thermalBusy = false;
    if (state.thermalReadRequest === controller) state.thermalReadRequest = null;
  }
}

async function refreshThermal() {
  return core().runFeatureTask('thermal.refresh', () => refreshThermalTask());
}

function reconcileThermalCommit(revision, expected) {
  // One supplementary read; a failure leaves an actionable note, never a
  // modal, repeated POST or automatic retry loop.
  const expectation = { ...expected, revision };
  state.verificationExpected = expectation;
  void apiFetch(API.thermalSet, {
    timeoutMs: THERMAL_REQUEST_TIMEOUTS.readback, priority: 'normal',
    scope: 'thermal.commit.readback', dedupe: false
  }).then((data) => {
    if (revision !== state.mutationRevision) return;
    if (!matchesThermalExpectation(data, expectation)) {
      throw new Error('当前状态与已提交目标不一致，请刷新确认');
    }
    applyThermalState(data);
    updatePendingState(data, { open: false });
    state.verificationNotice = '';
    state.verificationExpected = null;
    syncThermalUi();
    syncHeroDesc();
  }).catch((error) => {
    if (revision !== state.mutationRevision || state.verificationExpected !== expectation) return;
    state.verificationNotice = isCancelled(error)
      ? '操作已提交，状态待下次刷新确认'
      : '操作已提交，后台状态更新未完成；可刷新确认';
    syncThermalUi();
    if (!isCancelled(error)) appendLog(`${state.verificationNotice}：${error.message || error}`, 'warn');
  });
}

async function applyThermalSelection(policy, offset) {
  if (state.reinstallRequired || !state.contract?.policies.includes(policy) || state.thermalApplyBusy) return;
  if (state.repairRequired) {
    if (policy !== 'system') {
      showToast('当前温控配置需要修复，恢复系统配置并重启后才能选择自定义档位', 4200);
      return;
    }
    state.thermalApplyBusy = true;
    const revision = ++state.mutationRevision;
    state.verificationExpected = null;
    try {
      const data = await apiFetch(API.thermalSet, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'repair_system' }), timeoutMs: THERMAL_REQUEST_TIMEOUTS.mutation, priority: 'interactive', scope: 'thermal.mutation'
      });
      if (data?.ok !== true || data.repaired !== true) throw new Error(data?.error || '后端未接受修复');
      if (!applyThermalState(data)) throw new Error('修复已提交，但后端没有返回有效目标状态');
      updatePendingState(data, { open: false });
      state.verificationNotice = '修复已提交，后台更新状态中';
      showToast('温控修复已提交，重启后检查生效状态', 4200);
      reconcileThermalCommit(revision, { policy: 'system', pending: true });
    } catch (err) {
      showToast(`修复失败：${err?.message || '请重新安装模块'}`, 4200);
    } finally { state.thermalApplyBusy = false; syncThermalUi(); }
    return;
  }
  if (state.thermalModal.pendingId || state.thermalModal.pending) {
    showToast('已有待重启温控变更，请先撤销或重启后再选择。', 4200);
    return;
  }
  if (policy === 'custom' && !state.contract.offsets.includes(offset)) return;
  if (policy === state.currentPolicy && (policy !== 'custom' || offset === state.currentOffset)) return;
  const prev = { policy: state.currentPolicy, offset: state.currentOffset };
  const next = { policy };
  if (policy === 'custom') next.offset = offset;
  const selector = policy === 'custom'
    ? `[data-policy="custom"][data-offset="${offset}"]`
    : `[data-policy="${policy}"]`;
  const card = refs.thermalList.querySelector(selector);
  if (!card) return;
  state.thermalApplyBusy = true;
  const revision = ++state.mutationRevision;
  state.selectionModalDismissed = false;
  state.verificationExpected = null;
  state.verificationNotice = '';
  state.selectionPending = { policy, offset: policy === 'custom' ? Number(offset) : 0 };
  syncThermalUi();
  syncHeroDesc();
  card.classList.add('loading');
  const target = policy === 'custom' ? THERMAL_PRESETS[offset] : THERMAL_POLICY_PRESETS[policy];
  appendLog(`切换温控策略 ${target.name}…`, 'dim');
  refs.logCard.classList.add('open');
  showToast(`${target.name} 正在保存…`, 1400);
  openRebootModal({
    ...next,
    offset: policy === 'custom' ? Number(offset) : 0,
    pending_id: '',
    cancel_supported: false,
    reboot_required: true,
    saving: true
  }, prev);
  try {
    const data = await apiFetch(API.thermalSet, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(next), timeoutMs: THERMAL_REQUEST_TIMEOUTS.mutation, priority: 'interactive', scope: 'thermal.mutation' });
    if (data.ok && applyThermalState(data)) {
      state.selectionPending = null;
      state.verificationNotice = '操作已提交，后台更新状态中';
      updatePendingState(data, { open: false });
      syncThermalUi();
      syncHeroDesc();
      if (data.restarted) {
        showToast(`${target.name} · thermal 服务已重启`);
        appendLog(`${target.name} 已重启 thermal 服务`, 'ok');
      } else if (data.reboot_required) {
        appendLog(`${target.name} 已保存（重启后生效）`, 'warn');
        const hybridPending = data.reboot_required === true || data.pending === true;
        const pendingId = pendingIdFrom(data);
        state.thermalModal.prev = prev;
        state.thermalModal.pending = hybridPending ? {
          ...next,
          offset: Number(data.offset),
          pending_id: pendingId,
          cancel_supported: data.cancel_supported === true && Boolean(pendingId),
          reboot_required: true
        } : null;
        state.thermalModal.pendingId = pendingId;
        state.thermalModal.cancelSupported = data.cancel_supported === true && Boolean(pendingId);
        state.thermalModal.rebootRequired = hybridPending;
        state.thermalModal.cancelReconcileNeeded = false;
        if (!state.selectionModalDismissed && requireFeature('ui').getRebootContext() === 'thermal') {
          openRebootModal(state.thermalModal.pending, prev);
        } else state.thermalModal.dismissedPendingId = pendingId;
        showToast(THERMAL_REBOOT_NOTICE, 4200);
      } else {
        showToast(`${target.name} 已生效`);
        appendLog(`${target.name} 已生效`, 'ok');
      }
      reconcileThermalCommit(revision, next);
    } else {
      state.selectionPending = null;
      showToast(`切换失败：${data.error || '服务未返回有效的配置状态'}`);
      appendLog(data.error || '切换失败', 'err');
    }
  } catch (err) {
    state.selectionPending = null;
    if (refs.rebootModal.classList.contains('open') && requireFeature('ui').getRebootContext() === 'thermal') {
      requireFeature('ui').closeRebootModal('', { force: true, silent: true });
    }
    showToast(`请求失败：${err?.message || '服务未返回有效响应'}`);
    appendLog(String(err), 'err');
  } finally {
    state.selectionPending = null;
    card.classList.remove('loading');
    state.thermalApplyBusy = false;
    syncThermalUi();
    syncHeroDesc();
  }
}

async function cancelThermalChange() {
  if (state.thermalCancelBusy) return;
  const pendingId = state.thermalModal.pendingId;
  if (!pendingId || !state.thermalModal.cancelSupported) {
    showToast('当前没有可验证的温控待变更。', 4200);
    return;
  }
  const revision = ++state.mutationRevision;
  state.verificationExpected = null;
  state.thermalCancelBusy = true;
  state.thermalModal.dismissedPendingId = pendingId;
  showToast('正在撤销温控修改…', 1800);
  requireFeature('ui').setRebootBusy(true);
  setRebootError('');
  const confirmReadback = async () => {
    const readback = await apiFetch(API.thermalSet, {
      timeoutMs: THERMAL_REQUEST_TIMEOUTS.readback, priority: 'interactive',
      scope: 'thermal.contract.readback', dedupe: false
    });
    if (revision !== state.mutationRevision) return true;
    if (!validThermalSelection(readback?.policy, readback?.offset)
      || typeof readback.pending !== 'boolean') throw new Error('温控回读没有有效策略或待变更状态');
    if (readback.pending || pendingIdFrom(readback)) {
      if (pendingIdFrom(readback) !== pendingId) throw new Error('状态显示了不同的待变更，请刷新后操作');
      return false;
    }
    applyThermalState(readback);
    updatePendingState(readback, { open: false });
    state.thermalModal.cancelReconcileNeeded = false;
    state.thermalModal.dismissedPendingId = '';
    state.verificationNotice = '';
    state.verificationExpected = null;
    if (refs.rebootModal.classList.contains('open') && requireFeature('ui').getRebootContext() === 'thermal') {
      requireFeature('ui').closeRebootModal('', { force: true, silent: true });
    }
    syncThermalUi();
    syncHeroDesc();
    appendLog('温控撤销已由独立回读确认', 'ok');
    return true;
  };
  try {
    // A lost response may follow a committed cancellation. Reconcile before
    // another POST so retrying a readback never repeats the mutation.
    if (state.thermalModal.cancelReconcileNeeded && await confirmReadback()) return;
    const data = await apiFetch(API.thermalSet, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'cancel_pending', pending_id: pendingId }), timeoutMs: THERMAL_REQUEST_TIMEOUTS.mutation, priority: 'interactive', scope: 'thermal.mutation'
    });
    if (data?.ok !== true || data.canceled !== true || data.pending === true
      || data.reboot_required === true || !validThermalSelection(data.policy, data.offset)) {
      throw new Error(data?.error || '后端未确认撤销');
    }
    // The backend already verified the source/marker restoration under its
    // mutation lock. Dismiss now; effective-path verification is supplementary
    // background work and must not extend the user's modal wait.
    applyThermalState(data);
    updatePendingState(data, { open: false });
    state.verificationNotice = '撤销已提交，后台更新状态中';
    syncThermalUi();
    syncHeroDesc();
    if (requireFeature('ui').getRebootContext() === 'thermal') {
      requireFeature('ui').closeRebootModal('已撤销本次温控修改', { force: true });
    } else showToast('已撤销本次温控修改');
    reconcileThermalCommit(revision, { policy: data.policy, offset: data.offset, pending: false });
  } catch (err) {
    state.thermalModal.dismissedPendingId = pendingId;
    state.thermalModal.cancelReconcileNeeded = true;
    const message = `撤销未确认：${err?.message || '请刷新状态后重试'}；重试将先读取当前状态`;
    state.verificationNotice = message;
    syncThermalUi();
    if (requireFeature('ui').getRebootContext() === 'thermal') setRebootError(message);
    showToast(message, 4200);
  } finally {
    state.thermalCancelBusy = false;
    if (requireFeature('ui').getRebootContext() === 'thermal') requireFeature('ui').setRebootBusy(false);
  }
}

async function rebootDevice() {
  if (state.thermalCancelBusy || state.rebootBusy || requireFeature('profile').isBusy()) return;
  state.rebootBusy = true;
  const context = requireFeature('ui').getRebootContext();
  requireFeature('ui').setRebootBusy(true);
  setRebootError('');
  showToast('正在提交重启请求…');
  try {
    const data = await apiFetch(API.reboot, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'reboot', confirm: true }),
      timeoutMs: 8000, priority: 'interactive', scope: 'device.reboot'
    });
    if (data?.ok !== true) throw new Error(data?.error || '后端未接受重启请求');
    if (requireFeature('ui').getRebootContext() === context) requireFeature('ui').closeRebootModal('', { force: true, silent: true });
    showToast('重启请求已接受，等待设备重启');
    appendLog('重启请求已接受；实际启动状态需重启后确认', 'warn');
  } catch (err) {
    const message = `重启请求未确认：${err?.message || err}；请核对设备状态后再决定是否重试`;
    if (requireFeature('ui').getRebootContext() === context) setRebootError(message);
    showToast(message, 5000, 'err');
    appendLog(message, 'err');
  } finally {
    state.rebootBusy = false;
    if (requireFeature('ui').getRebootContext() === context) requireFeature('ui').setRebootBusy(false);
  }
}

async function cancelPendingRebootChange() {
  if (requireFeature('ui').getRebootContext() === 'scheduler') {
    await requireFeature('profile').cancelSchedulerChange();
  } else await cancelThermalChange();
}

registerFeature('thermal', {
  initialize() { refs.thermalList.replaceChildren(); },
  load: loadThermalPreset,
  refresh: refreshThermal,
  pause() {
    state.thermalReadRequest?.abort('PAGE_HIDDEN');
    state.thermalContractRequest?.abort('PAGE_HIDDEN');
    if (state.thermalContractRetryTimer) clearTimeout(state.thermalContractRetryTimer);
    state.thermalContractRetryTimer = null;
  },
  positionMarkers,
  isRefreshing: () => state.thermalBusy,
  syncHeroDesc,
  getSystemPreset: () => THERMAL_POLICY_PRESETS.system,
  rebootDevice,
  cancelPendingRebootChange,
  openPendingChange() {
    if (!state.thermalModal.pending && !state.thermalApplyBusy && !state.thermalCancelBusy) return;
    state.selectionModalDismissed = false;
    openRebootModal(state.thermalModal.pending, state.thermalModal.prev);
    requireFeature('ui').setRebootBusy(state.thermalApplyBusy || state.thermalCancelBusy || state.rebootBusy);
    if (state.verificationNotice.includes('未确认')) setRebootError(state.verificationNotice);
  },
  setPendingChange(pending, prev) {
    const changed = state.thermalModal.pendingId !== pendingIdFrom(pending);
    state.thermalModal.pending = pending;
    state.thermalModal.prev = prev;
    state.thermalModal.pendingId = pendingIdFrom(pending);
    state.thermalModal.cancelSupported = Boolean(state.thermalModal.pendingId)
      && pending?.cancel_supported === true;
    state.thermalModal.rebootRequired = pending?.reboot_required === true;
    if (changed) state.thermalModal.cancelReconcileNeeded = false;
    state.thermalModal.dismissedPendingId = '';
  },
  dismissPendingModal() {
    if (state.thermalApplyBusy || state.thermalCancelBusy) state.selectionModalDismissed = true;
    state.thermalModal.dismissedPendingId = state.thermalModal.pendingId || '';
  },
  isCancelBusy: () => state.thermalCancelBusy,
  isChartActive: () => requireFeature('analytics').isActive(),
});
})();
