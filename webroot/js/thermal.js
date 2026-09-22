// 温控档位、传感器状态与温度历史功能。
'use strict';
(() => {
const state = {
  contract: null,
  currentPolicy: 'unknown',
  currentOffset: null,
  thermalBusy: false,
  thermalBadReads: 0,
  lastSkinTempC: null,
  thermalApplyBusy: false,
  thermalCancelBusy: false,
  thermalContractRetryTimer: null,
  thermalContractRetryAttempts: 0,
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
    cancelReconcileNeeded: false
  }
};

const THERMAL_REINSTALL_NOTICE = '更改配置需卸载本模块、重启后重新安装并在向导选择';

const THERMAL_POLICY_PRESETS = {
  system: {
    name: '不修改温控',
    summary: '沿用系统温控，不应用额外调整。',
    detail: '<p>本模块不添加温控覆盖，保留当前系统 Thermal HAL 配置。</p><p>切换后是否需要重启由后端能力决定；界面分别显示已保存、等待重启和实际生效状态。</p>',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M13 3C8.03 3 4 7.03 4 12H1l4 4 4-4H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.95-2.05l-1.41 1.41A8.96 8.96 0 0013 21c4.97 0 9-4.03 9-9s-4.03-9-9-9z"/></svg>',
  },
};

const core = () => requireFeature('core');
const apiFetch = (...args) => core().apiFetch(...args);
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

function tempStatus(t) {
  const offset = state.currentPolicy === 'custom' ? Number(state.currentOffset) : 0;
  const modThresh = THRESH_STOCK + (Number.isFinite(offset) ? offset : 0);
  if (t < 36) return '凉爽';
  if (t < THRESH_STOCK) return '正常';
  if (t < modThresh) return '已高于原厂阈值，当前仍在放宽区间';
  if (t < modThresh + 4) return '系统已开始主动降温';
  if (t < 55) return '温度持续偏高，系统正在加强降温';
  return '温度过高，系统已严格限制性能';
}

function barPct(t) {
  return Math.min(Math.max((t - TEMP_MIN) / (TEMP_MAX - TEMP_MIN), 0), 1) * 100;
}

function positionMarkers() {
  const stockPct = barPct(THRESH_STOCK);
  refs.mkStock.style.left = `${stockPct}%`;
  refs.mkStockLbl.style.left = `${stockPct}%`;
  refs.mkStockLbl.textContent = `${THRESH_STOCK}°C 原厂`;
  if (state.currentPolicy !== 'custom' || !Number.isFinite(Number(state.currentOffset))) {
    refs.mkMod.style.display = 'none';
    refs.mkModLbl.style.display = 'none';
    return;
  }
  const modThresh = THRESH_STOCK + Number(state.currentOffset);
  const modPct = barPct(modThresh);
  refs.mkMod.style.left = `${modPct}%`;
  refs.mkModLbl.style.left = `${modPct}%`;
  refs.mkModLbl.textContent = state.currentOffset === 0 ? '' : `${modThresh}°C 当前`;
  refs.mkMod.style.display = state.currentOffset === 0 ? 'none' : '';
  refs.mkModLbl.style.display = state.currentOffset === 0 ? 'none' : '';
}

function formatThermalOffset(policy, offset) {
  if (policy === 'system') return '系统配置';
  const value = Number(offset);
  if (!Number.isFinite(value) || value === 0) return '出厂口径';
  return `${value > 0 ? '+' : ''}${value}°C 已启用`;
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
  return policy !== 'custom' || state.contract.offsets.includes(Number(offset));
}

function applyThermalState(data) {
  if (!validThermalSelection(data?.policy, data?.offset)) return false;
  state.currentPolicy = data.policy;
  state.currentOffset = Number(data.offset);
  return true;
}

function pendingIdFrom(data) {
  const id = typeof data?.pending_id === 'string' ? data.pending_id.trim() : '';
  return id.length >= 1 && id.length <= 256 && !/[\r\n\t]/.test(id) ? id : '';
}

function setRebootError(message = '') {
  requireFeature('ui').setRebootError(message);
}

function updatePendingState(data, { open = true } = {}) {
  // Older non-Hybrid endpoints do not expose pending fields. Preserve their
  // existing flow instead of interpreting an omitted field as "no pending".
  if (!Object.prototype.hasOwnProperty.call(data || {}, 'pending')) return;
  const pending = data.pending === true || data.pending === 'true';
  const hadPending = Boolean(state.thermalModal.pendingId || state.thermalModal.pending);
  const pendingId = pendingIdFrom(data);
  state.thermalModal.pendingId = pendingId;
  state.thermalModal.cancelSupported = data.cancel_supported !== false;
  state.thermalModal.rebootRequired = data.reboot_required !== false;
  state.thermalModal.cancelReconcileNeeded = false;
  if (!pending) {
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
  if (open && state.thermalModal.rebootRequired && pendingId
    && !refs.rebootModal.classList.contains('open')) {
    openRebootModal(state.thermalModal.pending, null);
  }
}

function isThermalZoneValid(zone) {
  if (!zone || typeof zone.zone !== 'string') return false;
  const temp = Number(zone.temp);
  return Number.isFinite(temp) && temp >= 10000 && temp <= 85000;
}

async function readThermalZones({ fresh = false, clear = false } = {}) {
  const path = clear ? API.thermalClear : fresh ? API.thermalFresh : API.thermal;
  const options = { timeoutMs: fresh || clear ? 8000 : 3500 };
  if (clear) {
    options.method = 'POST';
    options.headers = { 'Content-Type': 'application/json' };
    options.body = JSON.stringify({ action: 'clear' });
  }
  const zones = await apiFetch(path, options);
  if (!Array.isArray(zones) || !zones.length) throw new Error('未读取到热区数据');
  const valid = zones.filter(isThermalZoneValid);
  const skin = valid.find((zone) => zone.zone === 'VIRTUAL-SKIN') || valid.find((zone) => zone.zone === 'SKIN');
  if (!skin) throw new Error('VIRTUAL-SKIN 未找到');
  const tempC = skin.temp / 1000;
  if (state.lastSkinTempC !== null && Math.abs(tempC - state.lastSkinTempC) >= 12 && !fresh && !clear) {
    throw new Error('缓存温度跳变，准备校准');
  }
  return valid;
}

function syncHeroDesc() {
  const parts = [];
  const preset = state.currentPolicy === 'custom'
    ? THERMAL_PRESETS[state.currentOffset]
    : THERMAL_POLICY_PRESETS[state.currentPolicy];
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
  refs.heroDesc.textContent = parts.join(' · ') || '正在读取配置…';
}

function syncThermalUi() {
  const preset = state.currentPolicy === 'custom'
    ? THERMAL_PRESETS[state.currentOffset]
    : THERMAL_POLICY_PRESETS[state.currentPolicy];
  if (!preset) return;
  refs.topbarThermalChip.textContent = `温控 ${preset.name}`;
  refs.thermalCurrentName.textContent = preset.name;
  refs.thermalCurrentDesc.textContent = state.reinstallRequired
    ? `${preset.summary} · ${THERMAL_REINSTALL_NOTICE}`
    : preset.summary;
  const label = formatThermalOffset(state.currentPolicy, state.currentOffset);
  [refs.homeModBadge, refs.thModBadge].forEach((el) => {
    el.textContent = label;
    el.className = `badge ${state.currentPolicy !== 'custom' || state.currentOffset === 0 ? 'off' : 'default'}`;
  });
  document.querySelectorAll('.thermal-option').forEach((card) => {
    const selected = card.dataset.policy === state.currentPolicy
      && (state.currentPolicy !== 'custom' || Number(card.dataset.offset) === state.currentOffset);
    card.classList.toggle('selected', selected);
    card.classList.toggle('disabled', state.reinstallRequired);
    const select = card.querySelector('.profile-select');
    select.disabled = state.reinstallRequired || state.thermalApplyBusy;
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
    card.className = `profile-card thermal-option${state.reinstallRequired ? ' disabled' : ''}`;
    card.dataset.policy = policy;
    if (offset !== null) card.dataset.offset = String(offset);
    const itemId = policy === 'system' ? 'system' : `offset-${offset}`;
    const detailAction = `<button class="card-info" type="button" data-action="thermal-detail" data-policy="${policy}" data-offset="${offset ?? ''}" aria-label="查看${preset.name}详情">说明</button>`;
    setStaticHtml(card, `
      <button class="profile-select" type="button" role="radio" aria-checked="false" aria-labelledby="thermal-name-${itemId}" aria-describedby="thermal-desc-${itemId}" ${state.reinstallRequired ? 'disabled' : ''}>
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
    appendCard('custom', { ...preset, summary: `自定义 · ${preset.summary}` }, offset);
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
  if (!valid) throw new Error('温控档位 contract 无效');
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

async function loadThermalPreset() {
  try {
    const data = await apiFetch(API.thermalSet);
    updateThermalRuntimeGuard(data);
    applyThermalContract(data);
    state.thermalContractRetryAttempts = 0;
    if (state.thermalContractRetryTimer) {
      clearTimeout(state.thermalContractRetryTimer);
      state.thermalContractRetryTimer = null;
    }
    state.currentPolicy = state.contract.policies.includes(data.policy)
      ? data.policy
      : state.contract.defaultPolicy;
    state.currentOffset = state.contract.offsets.includes(Number(data.offset))
      ? Number(data.offset)
      : state.contract.defaultOffset;
    updatePendingState(data);
    renderThermalCards();
  } catch (_) {
    // A transient WebUI/CGI failure must not erase an already valid contract.
    // Retry a bounded number of times so a slow post-boot service does not
    // leave the thermal cards permanently blank until a full page reload.
    if (!state.contract && state.thermalContractRetryAttempts < 5) {
      state.thermalContractRetryAttempts += 1;
      if (!state.thermalContractRetryTimer) {
        state.thermalContractRetryTimer = window.setTimeout(() => {
          state.thermalContractRetryTimer = null;
          void loadThermalPreset();
        }, 1500 * state.thermalContractRetryAttempts);
      }
    }
  }
  syncThermalUi();
  syncHeroDesc();
}

async function refreshThermal() {
  if (!state.contract && !state.thermalContractRetryTimer) void loadThermalPreset();
  if (state.thermalBusy) return;
  state.thermalBusy = true;
  try {
    let zones;
    try {
      zones = await readThermalZones();
    } catch (_) {
      state.thermalBadReads += 1;
      zones = await readThermalZones({ fresh: true });
    }
    if (state.thermalBadReads >= 2) {
      try { zones = await readThermalZones({ clear: true }); } catch (_) {}
    }
    const skin = zones.find((zone) => zone.zone === 'VIRTUAL-SKIN') || zones.find((zone) => zone.zone === 'SKIN');
    const secondary = zones.filter((zone) => zone !== skin && ['soc_therm', 'battery', 'charging_therm', 'btmspkr_therm'].includes(zone.zone));
    refs.homeThermalSkel.hidden = true;
    refs.homeThermalContent.hidden = false;
    refs.thermalSkel.hidden = true;
    refs.thermalContent.hidden = false;
    if (skin) {
      const tempC = skin.temp / 1000;
      state.lastSkinTempC = tempC;
      state.thermalBadReads = 0;
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
  } catch (err) {
    refs.homeThermalSkel.hidden = true;
    refs.homeThermalContent.hidden = false;
    refs.thermalSkel.hidden = true;
    refs.thermalContent.hidden = false;
    refs.homeTempNum.textContent = '--';
    refs.homeTempStatus.textContent = err.message;
    refs.tempNum.textContent = '--';
    refs.tempStatus.textContent = err.message;
  } finally {
    state.thermalBusy = false;
  }
}

async function applyThermalSelection(policy, offset) {
  if (state.reinstallRequired || !state.contract?.policies.includes(policy) || state.thermalApplyBusy) return;
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
  syncThermalUi();
  card.classList.add('loading');
  const target = policy === 'custom' ? THERMAL_PRESETS[offset] : THERMAL_POLICY_PRESETS[policy];
  appendLog(`切换温控策略 ${target.name}…`, 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.thermalSet, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(next), timeoutMs: 8000 });
    if (data.ok && applyThermalState(data)) {
      updatePendingState(data, { open: false });
      syncThermalUi();
      syncHeroDesc();
      if (data.restarted) {
        showToast(`${target.name} · thermal 服务已重启`);
        appendLog(`${target.name} 已重启 thermal 服务`, 'ok');
      } else if (data.reboot_required) {
        appendLog(`${target.name} 已保存（重启后生效）`, 'warn');
        const pendingId = pendingIdFrom(data);
        const hybridPending = data.mount_backend === 'hybrid_mount'
          || data.pending === true || Boolean(pendingId);
        state.thermalModal.prev = prev;
        state.thermalModal.pending = hybridPending ? {
          ...next,
          offset: Number(data.offset),
          pending_id: pendingId,
          cancel_supported: data.cancel_supported !== false,
          reboot_required: true
        } : null;
        state.thermalModal.pendingId = hybridPending ? pendingId : '';
        state.thermalModal.cancelSupported = hybridPending && data.cancel_supported !== false;
        state.thermalModal.rebootRequired = hybridPending;
        state.thermalModal.cancelReconcileNeeded = false;
        openRebootModal(state.thermalModal.pending, prev);
      } else {
        showToast(`${target.name} 已生效`);
        appendLog(`${target.name} 已生效`, 'ok');
      }
    } else {
      showToast(`切换失败：${data.error || '后端返回了无效状态'}`);
      appendLog(data.error || '切换失败', 'err');
    }
  } catch (err) {
    showToast('请求失败，检查服务是否运行');
    appendLog(String(err), 'err');
  } finally {
    card.classList.remove('loading');
    state.thermalApplyBusy = false;
    syncThermalUi();
  }
}

async function cancelThermalChange() {
  if (state.thermalCancelBusy) return;
  if (state.reinstallRequired) {
    showToast(THERMAL_REINSTALL_NOTICE, 4200);
    return;
  }
  const pendingId = state.thermalModal.pendingId;
  const previous = state.thermalModal.prev;
  if (!pendingId && state.thermalModal.pending?.reboot_required) {
    setRebootError('后端未返回可验证的 pending_id，拒绝发送旧状态覆盖；请刷新状态后重试。');
    showToast('撤销状态缺少 pending_id');
    return;
  }
  if (!pendingId && !previous) {
    setRebootError('当前页面没有可验证的待重启温控变更，请先刷新状态。');
    showToast('未找到可撤销的温控变更');
    return;
  }
  if (!state.thermalModal.cancelSupported && pendingId) {
    setRebootError('当前后端不支持撤销此待重启变更，请先完成重启或刷新状态。');
    showToast('当前后端不支持撤销');
    return;
  }
  state.thermalCancelBusy = true;
  requireFeature('ui').setRebootBusy(true);
  setRebootError('');
  let pendingMutationAttempted = false;

  const finishConfirmedCancellation = (data) => {
    if (!validThermalSelection(data.policy, data.offset)) {
      throw new Error('后端返回了无效的恢复档位');
    }
    applyThermalState(data);
    updatePendingState(data, { open: false });
    state.thermalModal.cancelReconcileNeeded = false;
    syncThermalUi();
    syncHeroDesc();
    requireFeature('ui').closeRebootModal('已撤销本次温控修改', { force: true });
    appendLog('已撤销温控 pending 变更，重启不会应用新挡位', 'ok');
  };

  try {
    if (pendingId && state.thermalModal.cancelReconcileNeeded) {
      // A prior response or readback was uncertain. Reconcile first so a
      // successful cancellation is not retried as a new mutation (409).
      const reconciled = await apiFetch(API.thermalSet, { timeoutMs: 8000 });
      if (reconciled?.pending === false && reconciled?.pending_id === ''
        && reconciled?.reboot_required === false) {
        finishConfirmedCancellation(reconciled);
        return;
      }
      if (reconciled?.pending !== true || pendingIdFrom(reconciled) !== pendingId) {
        throw new Error('状态复读显示了不同的温控 pending 变更');
      }
      state.thermalModal.cancelReconcileNeeded = false;
    }
    const body = pendingId
      ? { action: 'cancel_pending', pending_id: pendingId }
      : previous;
    pendingMutationAttempted = Boolean(pendingId);
    const data = await apiFetch(API.thermalSet, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body), timeoutMs: 8000
    });
    if (pendingId) {
      if (data?.ok !== true || data.canceled !== true || data.pending !== false
        || data.pending_id !== '' || data.reboot_required !== false || !validThermalSelection(data.policy, data.offset)) {
        throw new Error(data?.error || '后端返回的撤销状态不完整');
      }
      const readback = await apiFetch(API.thermalSet, { timeoutMs: 8000 });
      if (readback?.pending !== false || readback?.pending_id !== ''
        || !validThermalSelection(readback.policy, readback.offset)
        || readback.policy !== data.policy || Number(readback.offset) !== Number(data.offset)) {
        throw new Error('撤销已提交，但状态复读仍显示待重启变更');
      }
      finishConfirmedCancellation(readback);
      return;
    } else {
      if (data?.ok !== true || !validThermalSelection(data.policy, data.offset)) {
        throw new Error(data?.error || '后端未确认撤销');
      }
      finishConfirmedCancellation(data);
      return;
    }
  } catch (err) {
    if (pendingMutationAttempted || pendingId) state.thermalModal.cancelReconcileNeeded = true;
    const uncertain = /timeout|超时|cancelled|取消/.test(String(err?.message || ''));
    const message = uncertain
      ? '撤销请求未确认，状态未知；请勿重启，保持此提示并重试。'
      : `撤销未确认：${err?.message || '后端拒绝了撤销请求'}`;
    setRebootError(message);
    showToast(message);
    appendLog(`撤销温控未确认：${err.message || err}`, 'err');
  } finally {
    state.thermalCancelBusy = false;
    requireFeature('ui').setRebootBusy(false);
  }
}

async function rebootDevice() {
  if (state.thermalCancelBusy) return;
  refs.rebootModal.classList.remove('open');
  showToast('正在重启设备…');
  try {
    await apiFetch(API.reboot, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'reboot', confirm: true }),
      timeoutMs: 8000
    });
  } catch (_) {}
}

async function cancelPendingRebootChange() {
  if (requireFeature('ui').getRebootContext() === 'scheduler') {
    await requireFeature('profile').cancelSchedulerChange();
  } else {
    await cancelThermalChange();
  }
}

const analytics = () => requireFeature('analytics');
function openTempChart() { analytics().open('thermal'); }
function triggerThermalBurst(options = {}) { return analytics().triggerBurst(options); }
function stopTempChartRefresh() { analytics().stop(); }
function pauseTempChartRefresh() { analytics().pause(); }
function scheduleTempChartRefresh(delay = TEMP_CHART_REFRESH_MS) { analytics().schedule(delay); }

registerFeature('thermal', {
  initialize() { refs.thermalList.replaceChildren(); },
  load: loadThermalPreset,
  refresh: refreshThermal,
  pause: pauseTempChartRefresh,
  positionMarkers,
  isRefreshing: () => state.thermalBusy,
  syncHeroDesc,
  getSystemPreset: () => THERMAL_POLICY_PRESETS.system,
  openChart: openTempChart,
  triggerBurst: triggerThermalBurst,
  rebootDevice,
  cancelPendingRebootChange,
  setPendingChange(pending, prev) {
    state.thermalModal.pending = pending;
    state.thermalModal.prev = prev;
    state.thermalModal.pendingId = pendingIdFrom(pending);
    state.thermalModal.cancelSupported = Boolean(state.thermalModal.pendingId)
      && pending?.cancel_supported !== false;
    state.thermalModal.rebootRequired = Boolean(state.thermalModal.pendingId)
      && pending?.reboot_required !== false;
    state.thermalModal.cancelReconcileNeeded = false;
  },
  isCancelBusy: () => state.thermalCancelBusy,
  isChartActive: () => analytics().isActive(),
  stopChart: stopTempChartRefresh,
  pauseChart: pauseTempChartRefresh,
  scheduleChart: scheduleTempChartRefresh
});
})();
