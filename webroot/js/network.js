// NR、SIM、UECap、基带与 NTP 功能。
'use strict';
(() => {
const state = {
  basebandInstalled: false,
  basebandState: null,
  nrSwitch: 'off',
  nrContract: null,
  nrBusy: false,
  sim2AutoManage: 'off',
  idleIsolateMode: 'off',
  standbyGuardBusy: false,
  standbyDiag: null,
  uecapContract: null,
  uecapMode: 'unknown',
  uecapActiveMode: 'unknown',
  uecapBusy: false,
  uecapPendingMode: '',
  uecapVerifyState: 'idle',
  uecapVerifyMessage: '',
  uecapExpectedHash: '',
  uecapVerifyNonce: 0,
  ntpServer: '',
  ntpServers: [],
  ntpBusy: false,
  deviceClockTimer: null
};

const core = () => requireFeature('core');
const apiFetch = (...args) => core().apiFetch(...args);
const appendLog = (...args) => core().appendLog(...args);
const buildInfoRow = (...args) => core().buildInfoRow(...args);
const errorBlock = (...args) => core().errorBlock(...args);
const showToast = (...args) => core().showToast(...args);
const sleep = (...args) => core().sleep(...args);
const syncOptionalModuleUi = () => requireFeature('profile').syncOptionalModuleUi();

function buildNrSwitchDetail() {
  const contract = state.nrContract || {};
  const delay = Number.isFinite(contract.screenOffDelayS) ? contract.screenOffDelayS : null;
  const cooldown = Number.isFinite(contract.restoreCooldownS) ? contract.restoreCooldownS : null;
  const recheck = Number.isFinite(contract.lteRecheckS) ? contract.lteRecheckS : null;
  const lteMode = Number.isFinite(contract.lteMode) ? contract.lteMode : 'unknown';
  const seconds = (value) => value === null ? '运行参数尚未读取' : `${value} 秒`;
  return `<b>NR 息屏降级 (Screen-Off LTE Switch)</b><br><br>开启后，息屏超过 <b>${seconds(delay)}</b> 时只把 DSDS slot 0 从 NR-capable mode 切到 LTE mode ${lteMode}；亮屏时恢复已保存的完整 mode，slot 1 保持不变。<br><br><b>防抖机制</b><br>- 息屏延迟：${seconds(delay)}<br>- NR 恢复冷却：${seconds(cooldown)}<br>- LTE 状态复查：${seconds(recheck)}<br>- 当前 mode 无效或恢复值无法持久化时不执行降级<br><br><b>边界</b><br>该功能减少息屏期间维持 NR 射频链路的机会，实际收益取决于信号、驻网、后台流量和运营商网络，不能用固定百分比承诺。开启热点时自动跳过；切换时可能短暂中断蜂窝数据。`;
}
function renderNrSwitchRows(data) {
  refs.nrSwitchRows.replaceChildren();
  const isOn = data.nr_switch === 'on';
  const slot0Raw = data.current_slot0 || String(data.current_mode || '').split(',')[0];
  const modeNum = Number(slot0Raw);
  const settingLte = !Number.isNaN(modeNum) && modeNum < 23;
  const actualRat = String(data.actual_rat || '').toUpperCase();
  const actualKnown = actualRat && actualRat !== 'UNKNOWN';
  const actualLte = actualKnown && actualRat.includes('LTE') && !actualRat.includes('NR');
  const actualNr = actualKnown && actualRat.includes('NR');
  const modeLabel = actualKnown
    ? `${actualRat} · setting ${data.current_mode || 'unknown'}`
    : (Number.isNaN(modeNum) ? (data.current_mode || 'unknown') : (settingLte ? `LTE setting (${data.current_mode})` : `NR setting (${data.current_mode})`));
  const rows = [
    { label: '功能状态', value: isOn ? '已开启' : '已关闭', cls: isOn ? 'good' : 'off' },
    { label: '当前网络模式', value: modeLabel, cls: actualLte || (!actualKnown && settingLte) ? 'warn' : actualNr ? 'good' : 'off' },
    { label: '恢复用 NR 模式值', value: data.saved_nr_mode, cls: 'off' }
  ];
  rows.forEach((row) => refs.nrSwitchRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
  refs.nrSwitchToggleLabel.textContent = isOn ? '关闭' : '开启';
  const delaySeconds = Number(data.screen_off_delay_s);
  const delayText = Number.isFinite(delaySeconds) ? formatDuration(delaySeconds) : '设定延迟';
  refs.nrSwitchDesc.textContent = isOn
    ? `已开启：息屏 ${delayText} 后切换至 LTE，亮屏自动恢复 5G。`
    : `息屏 ${delayText} 后切换至 LTE，亮屏自动恢复。`;
}

function syncStandbyGuardButtons() {
  refs.sim2AutoToggleBtn.disabled = state.standbyGuardBusy;
  refs.idleIsolateToggleBtn.disabled = state.standbyGuardBusy;
}

function standbyWorkerModeLabel(mode) {
  if (mode === 'screen_on') return '亮屏全量';
  if (mode === 'thermal_burst') return '温度突发';
  if (mode === 'deep_standby') return '深待机';
  if (mode === 'idle_isolate') return '待机隔离';
  return '未知';
}

function standbyWorkerModeClass(mode) {
  if (mode === 'screen_on' || mode === 'deep_standby') return 'good';
  if (mode === 'thermal_burst' || mode === 'idle_isolate') return 'warn';
  return 'off';
}

function formatStandbyTimestamp(value) {
  const ts = Number(value);
  if (!Number.isFinite(ts) || ts <= 0) return '—';
  return new Date(ts * 1000).toLocaleString();
}

function renderStandbyGuard(data) {
  state.sim2AutoManage = data.sim2_auto_manage === 'on' ? 'on' : 'off';
  state.idleIsolateMode = data.idle_isolate_mode === 'on' ? 'on' : 'off';
  state.standbyDiag = {
    updatedAt: data.diag_updated_at || '',
    screen: data.diag_screen || 'unknown',
    workerMode: data.diag_worker_mode || 'unknown',
    nextSleepSecs: data.diag_next_sleep_secs || '',
    burstActive: data.diag_burst_active || '0',
    nrSwitch: data.diag_nr_switch || 'off',
    nrState: data.diag_nr_state || 'unknown',
    profilePolicy: data.diag_profile_policy || 'unknown',
    activeProfile: data.diag_active_profile || 'unknown',
    cycleCount: data.diag_cycle_count || '0',
  };

  const sim2On = state.sim2AutoManage === 'on';
  refs.sim2AutoToggleLabel.textContent = sim2On ? '关闭' : '开启';
  refs.sim2AutoDesc.textContent = sim2On
    ? '已开启：息屏时停用空槽实例，亮屏或插入 SIM2 后自动恢复。'
    : '单卡设备可在息屏时停用空槽实例。双卡设备请保持关闭。';
  refs.sim2AutoRows.replaceChildren();
  [
    { label: '功能状态', value: sim2On ? '已开启' : '已关闭', cls: sim2On ? 'good' : 'off' },
    { label: '实现方式', value: sim2On ? 'set-sim-count 1（减少 Active modem 实例）' : '不操作 modem 实例数', cls: sim2On ? 'good' : 'off' },
    { label: '适用场景', value: sim2On ? '单卡用户 · 副卡槽为空' : '双卡用户 · 两张 SIM 都在使用', cls: 'off' },
  ].forEach((row) => refs.sim2AutoRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));

  const isolateOn = state.idleIsolateMode === 'on';
  refs.idleIsolateToggleLabel.textContent = isolateOn ? '关闭' : '开启';
  refs.idleIsolateDesc.textContent = isolateOn
    ? '已开启：息屏优化已暂停，仅保留最低限度的状态检查。'
    : '暂停模块的息屏优化，用于判断待机异常是否由模块引起。';
  refs.idleIsolateRows.replaceChildren();
  [
    { label: '功能状态', value: isolateOn ? '已开启' : '已关闭', cls: isolateOn ? 'warn' : 'off' },
    { label: '息屏行为', value: isolateOn ? '仅保留 600s 最小唤醒路径，其余全部暂停' : '常规待机 worker 正常运行', cls: isolateOn ? 'warn' : 'good' },
    { label: '使用建议', value: isolateOn ? '仅用于一晚隔离测试，验证后请关闭' : '日常使用保持关闭', cls: 'off' },
  ].forEach((row) => refs.idleIsolateRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));

  refs.standbyDiagRows.replaceChildren();
  if (!state.standbyDiag.updatedAt) {
    refs.standbyDiagRows.appendChild(buildInfoRow('状态文件', '等待后台 worker 首次写入', 'off'));
  } else {
    const nrLabel = state.standbyDiag.nrSwitch === 'on'
      ? (state.standbyDiag.nrState === 'lte' ? 'NR 管理开启 / 当前 LTE' : 'NR 管理开启 / 当前 5G')
      : 'NR 管理关闭';
    const profileLabel = `${state.standbyDiag.profilePolicy === 'auto' ? '自动' : '手动'} / ${state.standbyDiag.activeProfile || 'unknown'}`;
    [
      { label: '最近更新', value: formatStandbyTimestamp(state.standbyDiag.updatedAt), cls: 'off' },
      { label: '当前屏幕', value: state.standbyDiag.screen === 'on' ? '亮屏' : state.standbyDiag.screen === 'off' ? '息屏' : '未知', cls: state.standbyDiag.screen === 'on' ? 'warn' : 'good' },
      { label: 'worker 分支', value: standbyWorkerModeLabel(state.standbyDiag.workerMode), cls: standbyWorkerModeClass(state.standbyDiag.workerMode) },
      { label: '下次复查', value: state.standbyDiag.nextSleepSecs ? `${state.standbyDiag.nextSleepSecs}s` : '—', cls: 'off' },
      { label: 'NR 状态', value: nrLabel, cls: state.standbyDiag.nrState === 'lte' ? 'warn' : 'off' },
      { label: '调度状态', value: profileLabel, cls: 'off' },
      { label: '循环计数', value: state.standbyDiag.cycleCount || '0', cls: 'off' },
    ].forEach((row) => refs.standbyDiagRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
  }

  syncStandbyGuardButtons();
}

function uecapLabel(mode) {
  if (UECAP_MODE_PRESENTATION[mode]) return UECAP_MODE_PRESENTATION[mode].name;
  if (mode === 'custom') return '系统原生 / 第三方';
  if (mode === 'stock') return '系统原生';
  if (mode === 'disabled') return '当前不可用';
  return '未知';
}

function applyUecapContract(data) {
  const raw = data?.uecap_contract;
  const modeOrder = Array.isArray(raw?.mode_order) ? raw.mode_order.filter((mode) => typeof mode === 'string') : [];
  const defaultMode = typeof raw?.default_mode === 'string' ? raw.default_mode : '';
  if (data?.disabled === true) {
    if (modeOrder.length !== 0 || defaultMode !== 'disabled') throw new Error('UECap disabled contract 无效');
    state.uecapContract = { modeOrder: [], defaultMode: 'disabled', disabled: true };
    return;
  }
  const valid = modeOrder.length > 0
    && new Set(modeOrder).size === modeOrder.length
    && modeOrder.every((mode) => UECAP_MODE_PRESENTATION[mode])
    && modeOrder.includes(defaultMode);
  if (!valid) throw new Error('UECap mode contract 无效');
  state.uecapContract = { modeOrder, defaultMode, disabled: false };
}

function getUecapModeHash(data, mode) {
  if (!data || !mode) return '';
  return data[`${mode}_hash`] || '';
}

function getUecapVerifyRow(data, requested, active) {
  if (state.uecapVerifyState === 'failed') {
    return {
      label: '配置校验',
      value: state.uecapVerifyMessage || '未在时限内确认，请手动刷新复查',
      cls: 'warn'
    };
  }

  if (state.uecapPendingMode) {
    const label = uecapLabel(state.uecapPendingMode);
    if (state.uecapVerifyState === 'switching') {
      return { label: '配置校验', value: `${label}：切换中`, cls: 'warn' };
    }
    if (state.uecapVerifyState === 'verifying') {
      return { label: '配置校验', value: `${label}：正在校验配置`, cls: 'warn' };
    }
  }

  const expectedHash = getUecapModeHash(data, requested);
  const targetHash = data.target_hash || '';
  const confirmed = requested === active && (!expectedHash || expectedHash === targetHash);
  return {
    label: '配置校验',
    value: confirmed ? '已确认' : '待确认',
    cls: confirmed ? 'good' : 'warn'
  };
}

function renderUecapBtnGroup(activeMode) {
  const selectedMode = state.uecapPendingMode || activeMode;
  refs.uecapBtnGroup.replaceChildren();
  const modes = state.uecapContract?.modeOrder || [];
  refs.uecapBtnGroup.hidden = modes.length === 0;
  modes.forEach((id) => {
    const presentation = UECAP_MODE_PRESENTATION[id];
    const btn = document.createElement('button');
    btn.type = 'button';
    const isSelected = id === selectedMode;
    const isPending = state.uecapBusy && id === state.uecapPendingMode;
    btn.className = `uecap-btn${isSelected ? ' active' : ''}${isPending ? ' pending' : ''}${isPending && state.uecapVerifyState === 'verifying' ? ' verifying' : ''}`;
    btn.dataset.mode = id;
    btn.textContent = isPending
      ? (state.uecapVerifyState === 'switching' ? '切换中...' : '校验中...')
      : presentation.name;
    btn.disabled = state.uecapBusy;
    btn.addEventListener('click', () => setUecapMode(id));
    refs.uecapBtnGroup.appendChild(btn);
  });
}

function renderUecapRows(data) {
  applyUecapContract(data);
  refs.uecapRows.replaceChildren();
  const receipt = data.runtime_receipt && typeof data.runtime_receipt === 'object'
    ? data.runtime_receipt : {};
  const disabled = Boolean(state.uecapContract.disabled);
  const requested = disabled
    ? (data.requested_mode || receipt.desired_profile || 'disabled')
    : (data.requested_mode || state.uecapMode || state.uecapContract.defaultMode);
  const active = data.active_mode || receipt.bound_profile || (disabled ? 'stock' : 'custom');
  state.uecapMode = requested;
  state.uecapActiveMode = active;
  const modeInfo = UECAP_MODE_PRESENTATION[requested];
  refs.uecapDesc.textContent = disabled
    ? (data.disabled_message || '当前安装环境不提供 UECap 配置写入；以下只展示设备、modem 和无线观察结果。')
    : state.uecapPendingMode
      ? `${uecapLabel(state.uecapPendingMode)}：已提交切换，正在校验当前配置。`
      : modeInfo ? `${modeInfo.desc} · 切换后自动校验配置是否生效。` : '选择 UE 能力配置，切换后会自动校验是否生效。';
  renderUecapBtnGroup(disabled ? 'disabled' : requested);
  const verifyRow = disabled
    ? { label: '配置校验', value: `${data.contract_result || 'unknown'} · 只读`, cls: 'off' }
    : getUecapVerifyRow(data, requested, active);
  const reloadResult = receipt.reload_result === 'success'
    ? (receipt.modem_load_state === 'confirmed_readback' ? 'modem 已重载并完成读回' : 'modem 重载已接受，尚未确认实际加载')
    : receipt.reload_result === 'failed'
      ? 'modem 重载失败'
      : receipt.reload_result === 'unknown'
        ? '尚无运行收据'
        : '未执行';
  const nrRegistered = receipt.nr_registered === 'true' || receipt.nr_registered === true;
  const nrAvailable = receipt.nr_available === 'true' || receipt.nr_available === true;
  const nrBand = receipt.nr_band && receipt.nr_band !== 'unknown' ? ` / band ${receipt.nr_band}` : '';
  const actualRat = String(receipt.actual_rat || 'unknown').toUpperCase();
  const observedRat = String(receipt.radio_observed_state || 'UNKNOWN').toUpperCase();
  const nsaStatus = String(receipt.nsa_status || (observedRat === 'NR_NSA' ? 'observed' : 'not_applicable'));
  const nsaReason = String(receipt.nsa_reason || (observedRat === 'NR_SA' ? 'sa_observed' : 'no_confirmed_nsa_cell'));
  const radioResult = observedRat === 'NR_SA' || actualRat === 'NR_SA'
    ? `NR SA${nrBand}（不要求 EN-DC）`
    : observedRat === 'NR_NSA' || actualRat === 'NR_NSA'
      ? `NR NSA${nrBand}（已观测 EN-DC/LTE anchor）`
      : actualRat === 'LTE' || observedRat === 'LTE'
        ? 'LTE / 4G（当前无线观察结果，不代表 UECap 失败）'
        : nrRegistered
          ? `NR 已注册${nrBand}`
          : nrAvailable
            ? `NR 可用但当前未注册${nrBand}`
            : '尚无可确认的 NR 无线状态';
  const hasConfirmedModemLoad = receipt.modem_load_state === 'confirmed_readback';
  const isCurrentReceipt = receipt.receipt_freshness === 'current_boot';
  const rows = [
    { label: 'Device / SKU', value: `${data.device || 'unknown'} / ${data.device_label || 'unknown'}`, cls: 'off' },
    { label: 'Device policy', value: data.device_policy || 'unknown', cls: 'off' },
    { label: 'Runtime policy', value: data.runtime_policy || data.policy || 'unknown', cls: disabled ? 'off' : 'good' },
    { label: '已选配置', value: uecapLabel(requested), cls: requested === active ? 'good' : 'off' },
    { label: '当前绑定', value: uecapLabel(active), cls: active === requested ? 'good' : 'warn' },
    verifyRow,
    { label: 'Modem load state', value: receipt.modem_load_state || 'unknown', cls: hasConfirmedModemLoad ? 'good' : 'warn' },
    { label: 'Modem loaded profile', value: receipt.modem_loaded_profile || 'unknown', cls: 'off' },
    { label: 'Modem 时序', value: reloadResult, cls: receipt.reload_result === 'failed' ? 'warn' : hasConfirmedModemLoad ? 'good' : 'off' },
    { label: 'Functional state', value: receipt.functional_state || 'unknown', cls: receipt.functional_state === 'verified' ? 'good' : 'warn' },
    { label: 'Receipt freshness', value: receipt.receipt_freshness || 'missing', cls: isCurrentReceipt ? 'good' : 'warn' },
    { label: 'Target', value: `${data.target_name || 'unknown'} / ${(data.target_hash || 'unknown').slice(0, 16)}`, cls: 'off' },
    { label: '实际无线', value: radioResult, cls: observedRat === 'NR_SA' || observedRat === 'NR_NSA' ? 'good' : 'off' },
    { label: 'SA', value: observedRat === 'NR_SA' ? 'observed · 不要求 EN-DC' : 'not observed', cls: observedRat === 'NR_SA' ? 'good' : 'off' },
    { label: 'NSA', value: `${nsaStatus} · ${nsaReason}`, cls: nsaStatus === 'observed' ? 'good' : 'off' },
    { label: 'LTE / 4G', value: actualRat === 'LTE' || observedRat === 'LTE' ? 'observed · 仅表示当前驻网' : 'not observed', cls: 'off' },
    { label: 'LTE anchor', value: receipt.lte_anchor || 'unknown', cls: 'off' },
    { label: '原因', value: data.reason || 'unknown', cls: disabled ? 'off' : 'warn' },
  ];
  rows.forEach((row) => refs.uecapRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
}

async function refreshNrSwitch() {
  try {
    const data = await apiFetch(API.nrSwitch, { timeoutMs: 6000 });
    state.nrSwitch = data.nr_switch || 'off';
    state.nrContract = {
      screenOffDelayS: Number(data.screen_off_delay_s),
      restoreCooldownS: Number(data.restore_cooldown_s),
      lteRecheckS: Number(data.lte_recheck_s),
      lteMode: Number(data.lte_mode)
    };
    renderNrSwitchRows(data);
  } catch (err) {
    refs.nrSwitchRows.replaceChildren(); refs.nrSwitchRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

async function refreshUecap() {
  try {
    const data = await apiFetch(API.uecap, { timeoutMs: 6000 });
    applyUecapContract(data);
    state.uecapMode = data.requested_mode || state.uecapContract.defaultMode;
    state.uecapActiveMode = data.active_mode || (state.uecapContract.disabled ? 'stock' : 'custom');
    const expectedHash = getUecapModeHash(data, state.uecapMode);
    if (!state.uecapPendingMode && state.uecapVerifyState === 'failed' && state.uecapMode === state.uecapActiveMode && (!expectedHash || expectedHash === data.target_hash)) {
      state.uecapVerifyState = 'idle';
      state.uecapVerifyMessage = '';
    }
    renderUecapRows(data);
  } catch (err) {
    state.uecapContract = null;
    refs.uecapBtnGroup.replaceChildren();
    refs.uecapBtnGroup.hidden = true;
    refs.uecapRows.replaceChildren(); refs.uecapRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

async function refreshStandbyGuard() {
  try {
    const data = await apiFetch(API.standbyGuard, { timeoutMs: 6000 });
    renderStandbyGuard(data);
  } catch (err) {
    refs.sim2AutoRows.replaceChildren(); refs.sim2AutoRows.appendChild(errorBlock('获取失败：' + err.message));
    refs.idleIsolateRows.replaceChildren(); refs.idleIsolateRows.appendChild(errorBlock('获取失败：' + err.message));
    refs.standbyDiagRows.replaceChildren(); refs.standbyDiagRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

async function setStandbyGuard(update, successText, logText) {
  if (state.standbyGuardBusy) return;
  state.standbyGuardBusy = true;
  syncStandbyGuardButtons();
  try {
    const data = await apiFetch(API.standbyGuard, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(update),
      timeoutMs: 8000
    });
    if (data.ok) {
      renderStandbyGuard(data);
      showToast(successText);
      appendLog(logText, 'ok');
    } else {
      showToast(`操作失败：${data.error || '未知'}`);
    }
  } catch (_) {
    showToast('请求失败');
  } finally {
    state.standbyGuardBusy = false;
    syncStandbyGuardButtons();
  }
}

async function toggleSim2AutoManage() {
  const next = state.sim2AutoManage === 'on' ? 'off' : 'on';
  await setStandbyGuard(
    { sim2_auto_manage: next },
    next === 'on' ? 'SIM2 自动管理已开启' : 'SIM2 自动管理已关闭',
    next === 'on' ? 'SIM2 自动管理: 开启' : 'SIM2 自动管理: 关闭'
  );
}

async function toggleIdleIsolateMode() {
  const next = state.idleIsolateMode === 'on' ? 'off' : 'on';
  await setStandbyGuard(
    { idle_isolate_mode: next },
    next === 'on' ? '待机隔离模式已开启' : '待机隔离模式已关闭',
    next === 'on' ? '待机隔离模式: 开启' : '待机隔离模式: 关闭'
  );
}

// ── 后台应用限制 ─────────────────────────────────────────
async function verifyUecapSwitch(mode, expectedHash, initialData) {
  const nonce = ++state.uecapVerifyNonce;
  const label = UECAP_MODE_PRESENTATION[mode]?.name || mode;
  const deadline = Date.now() + UECAP_VERIFY_TIMEOUT_MS;
  let lastData = initialData || null;
  let lastErr = '';

  state.uecapPendingMode = mode;
  state.uecapExpectedHash = expectedHash || '';
  state.uecapVerifyState = 'switching';
  renderUecapRows(lastData || {
    requested_mode: mode,
    active_mode: state.uecapActiveMode || 'custom',
    target_hash: expectedHash || 'unknown'
  });

  await sleep(1800);

  while (state.uecapVerifyNonce === nonce && Date.now() < deadline) {
    state.uecapVerifyState = 'verifying';
    if (lastData) renderUecapRows(lastData);

    try {
      const data = await apiFetch(API.uecap, { timeoutMs: 6000 });
      lastData = data;
      state.uecapMode = data.requested_mode || mode;
      state.uecapActiveMode = data.active_mode || 'custom';
      renderUecapRows(data);

      const confirmedHash = expectedHash || getUecapModeHash(data, mode);
      const confirmed = data.requested_mode === mode
        && data.active_mode === mode
        && (!confirmedHash || data.target_hash === confirmedHash);

      if (confirmed) {
        state.uecapBusy = false;
        state.uecapPendingMode = '';
        state.uecapExpectedHash = '';
        state.uecapVerifyState = 'idle';
        state.uecapVerifyMessage = '';
        renderUecapRows(data);
        showToast(`UE 能力配置已切换为 ${label}`);
        appendLog(`UE 配置已确认: ${label}`, 'ok');
        return;
      }
    } catch (err) {
      lastErr = err.message || 'request failed';
    }

    await sleep(UECAP_VERIFY_INTERVAL_MS);
  }

  if (state.uecapVerifyNonce !== nonce) return;

  state.uecapBusy = false;
  state.uecapPendingMode = '';
  state.uecapExpectedHash = '';
  state.uecapVerifyState = 'failed';
  state.uecapVerifyMessage = lastErr
    ? `15 秒内未确认（${lastErr}）`
    : '15 秒内未确认，请手动刷新复查';

  if (lastData) renderUecapRows(lastData);
  showToast(`${label} 已提交切换，但 15 秒内未完成校验，请手动刷新复查`, 4200);
  appendLog(`UE 配置待复查: ${label}`, 'warn');
}

async function toggleNrSwitch() {
  if (state.nrBusy) return;
  state.nrBusy = true;
  try {
    const data = await apiFetch(API.nrSwitch, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'toggle' }), timeoutMs: 8000 });
    if (data.ok) {
      state.nrSwitch = data.nr_switch;
      showToast(data.nr_switch === 'on' ? 'NR 息屏降级已开启' : 'NR 息屏降级已关闭');
      appendLog(data.nr_switch === 'on' ? 'NR 息屏降级: 开启' : 'NR 息屏降级: 关闭', 'ok');
      refreshNrSwitch();
    } else {
      showToast('操作失败');
    }
  } catch (_) {
    showToast('请求失败');
  } finally {
    state.nrBusy = false;
  }
}

async function setUecapMode(mode) {
  if (!state.uecapContract?.modeOrder.includes(mode)
    || state.uecapBusy
    || (mode === state.uecapMode && state.uecapVerifyState !== 'failed')) return;
  const label = UECAP_MODE_PRESENTATION[mode]?.name || mode;
  state.uecapBusy = true;
  state.uecapPendingMode = mode;
  state.uecapVerifyState = 'switching';
  state.uecapVerifyMessage = `${label}：正在提交切换`;
  renderUecapRows({
    requested_mode: state.uecapMode || mode,
    active_mode: state.uecapActiveMode || 'custom',
    target_hash: state.uecapExpectedHash || 'unknown'
  });
  try {
    const data = await apiFetch(API.uecap, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ policy: 'manual', mode }),
      timeoutMs: 12000
    });
    if (data.ok) {
      state.uecapMode = data.requested_mode || mode;
      state.uecapActiveMode = data.active_mode || state.uecapActiveMode || 'custom';
      const expectedHash = getUecapModeHash(data, mode) || data.target_hash || '';
      state.uecapExpectedHash = expectedHash;
      state.uecapVerifyState = data.reloading ? 'switching' : 'verifying';
      renderUecapRows(data);
      showToast(`${label}：已提交切换，正在校验配置`, 2600);
      appendLog(`UE 配置已提交: ${label}，等待校验结果`, 'ok');
      await verifyUecapSwitch(mode, expectedHash, data);
    } else if (data.applied) {
      state.uecapMode = data.requested_mode || mode;
      state.uecapActiveMode = data.active_mode || mode;
      state.uecapBusy = false;
      state.uecapPendingMode = '';
      state.uecapExpectedHash = '';
      state.uecapVerifyState = 'failed';
      state.uecapVerifyMessage = data.error || '配置已切换，但 modem 未完成重载';
      renderUecapRows(data);
      showToast(state.uecapVerifyMessage, 4200);
      appendLog(`UE 配置已写入但重载失败: ${label}`, 'warn');
    } else {
      showToast(`切换失败：${data.error || '未知'}`);
      state.uecapBusy = false;
      state.uecapPendingMode = '';
      state.uecapExpectedHash = '';
      state.uecapVerifyState = 'failed';
      state.uecapVerifyMessage = data.error || '提交失败';
      await refreshUecap();
    }
  } catch (_) {
    showToast('请求失败');
    state.uecapBusy = false;
    state.uecapPendingMode = '';
    state.uecapExpectedHash = '';
    state.uecapVerifyState = 'failed';
    state.uecapVerifyMessage = '请求失败，请重试';
    await refreshUecap();
  }
}

function renderBasebandRows(data) {
  refs.basebandRows.replaceChildren();
  if (!data.installed) {
    state.basebandInstalled = false;
    state.basebandState = data;
    syncOptionalModuleUi();
    return;
  }
  state.basebandInstalled = true;
  state.basebandState = data;
  syncOptionalModuleUi();
  const runtimeVerified = data.runtime_verified === true;
  const moduleState = data.module_state || (data.enabled ? 'enabled' : 'disabled');
  refs.basebandDesc.textContent = runtimeVerified
    ? `已安装 ${data.version || ''}，本次启动已验证 effective overlay。`
    : `已安装 ${data.version || ''}，但本次启动尚未确认 effective overlay；请先完成重启或按提示重新安装。`;
  const props = data.props || {};
  const cs = data.carrier_settings || {};
  const mcfg = data.mcfg || {};
  const freshness = data.runtime_receipt_freshness || 'missing';
  const rows = [
    { label: '模块目录', value: `${data.source || 'unknown'} / ${moduleState}`, cls: data.enabled ? 'good' : 'warn' },
    { label: '运行验证', value: runtimeVerified ? '本次启动已验证' : '目录存在，但尚未验证生效', cls: runtimeVerified ? 'good' : 'warn' },
    { label: '版本', value: data.version || '未知', cls: 'off' },
    { label: '状态合同', value: `schema ${data.status_schema || 0}`, cls: Number(data.status_schema) === 3 ? 'good' : 'warn' },
    { label: '挂载观察', value: data.mount_observed || 'unknown', cls: data.mount_observed === 'yes' || data.mount_observed === 'not_required_magisk' ? 'good' : 'warn' },
    { label: 'Effective overlay', value: data.effective_overlay_verified || 'unknown', cls: data.effective_overlay_verified === 'yes' ? 'good' : 'warn' },
    { label: '迁移状态', value: data.migration_state || 'unknown', cls: data.migration_state === 'effective_overlay_verified' ? 'good' : 'warn' },
    { label: 'Source / effective', value: `${data.source_path || 'unknown'} → ${data.effective_path || 'unknown'}`, cls: 'off' },
    { label: 'Source contract', value: `${data.source_contract_verified || 'no'} / ${(data.source_contract_hash || data.source_hash || 'unknown').slice(0, 12)}`, cls: data.source_contract_verified === 'yes' ? 'good' : 'warn' },
    { label: 'Content contract', value: `${data.content_image_verified || 'unknown'} / ${(data.content_contract_hash || data.content_image_hash || 'unknown').slice(0, 12)}`, cls: data.content_image_verified === 'yes' || data.content_image_verified === 'not_required_magisk' ? 'good' : 'warn' },
    { label: 'Effective contract', value: `${data.effective_contract_verified || 'no'} / ${(data.effective_contract_hash || data.effective_hash || 'unknown').slice(0, 12)}`, cls: data.effective_contract_verified === 'yes' ? 'good' : 'warn' },
    { label: 'Effective extra files', value: data.effective_extra_files_allowed || 'unknown', cls: data.effective_extra_files_allowed === 'yes' ? 'off' : 'warn' },
    { label: 'Receipt', value: `${freshness} / prior ${data.prior_receipt_freshness || 'missing'}`, cls: freshness === 'current_check' ? 'good' : 'warn' },
    { label: 'Clean reinstall', value: data.clean_reinstall_required ? '需要卸载、重启、重装、再重启' : '不需要', cls: data.clean_reinstall_required ? 'warn' : 'good' },
    { label: '错误摘要', value: data.errors || 'none', cls: data.errors && data.errors !== 'none' ? 'warn' : 'off' },
    { label: 'VoLTE', value: props.volte_avail_ovr === '1' ? '已启用' : '未启用', cls: props.volte_avail_ovr === '1' ? 'good' : 'warn' },
    { label: 'Wi-Fi Calling', value: props.wfc_avail_ovr === '1' ? '已启用' : '未启用', cls: props.wfc_avail_ovr === '1' ? 'good' : 'warn' },
    { label: '运营商配置', value: cs.installed ? `${cs.count} 项` : '未安装', cls: cs.installed ? 'good' : 'off' },
    { label: '国内 MCFG', value: mcfg.installed ? `${mcfg.count} 个 mbn` : '未安装', cls: mcfg.installed ? 'good' : 'off' },
  ];
  rows.forEach((row) => refs.basebandRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
}

async function refreshBaseband() {
  if (!state.basebandInstalled && (!state.basebandState || !state.basebandState.installed)) {
    syncOptionalModuleUi();
    return;
  }
  try {
    const data = await apiFetch(API.checkBaseband, { timeoutMs: 6000 });
    renderBasebandRows(data);
  } catch (err) {
    refs.basebandRows.replaceChildren(); refs.basebandRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

function startDeviceClock() {
  if (!core().isWebUiActive() || requireFeature('shell').getCurrentTab() !== 'system') return;
  if (state.deviceClockTimer) return;
  const pad = (n) => String(n).padStart(2, '0');
  const tick = () => {
    const el = document.getElementById('ntp-device-time');
    if (!el || !core().isWebUiActive() || requireFeature('shell').getCurrentTab() !== 'system') return;
    // WebView 运行在本机, new Date() 即设备实时时钟; 每秒走字, 不再依赖 CGI 快照
    const d = new Date();
    el.textContent = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  };
  tick();
  state.deviceClockTimer = window.setInterval(tick, 1000);
}

function stopDeviceClock() {
  if (!state.deviceClockTimer) return;
  clearInterval(state.deviceClockTimer);
  state.deviceClockTimer = null;
}

function syncDeviceClockForTab() {
  if (core().isWebUiActive() && requireFeature('shell').getCurrentTab() === 'system') startDeviceClock();
  else stopDeviceClock();
}

function renderNtpCard(data) {
  refs.ntpServerList.replaceChildren();
  const servers = Array.isArray(data.servers)
    ? data.servers.filter((server) => server && server.id && server.name)
    : state.ntpServers;
  if (!servers.length) {
    refs.ntpServerList.appendChild(errorBlock('NTP 服务器配置为空'));
    return;
  }
  state.ntpServers = servers;
  const current = data.ntp_server || data.default_server || servers[0].id;
  state.ntpServer = current;
  servers.forEach((srv) => {
    const card = document.createElement('div');
    card.className = `opt-item${srv.id === current ? ' ntp-selected' : ''}`;
    card.style.cursor = 'pointer';
    const head = document.createElement('div');
    head.className = 'opt-item-head';
    const label = document.createElement('div');
    label.className = 'opt-label';
    label.textContent = srv.name;
    const badge = document.createElement('span');
    badge.className = `badge ${srv.id === current ? 'good' : 'off'}`;
    badge.textContent = srv.id === current ? '当前' : '切换';
    const meta = document.createElement('div');
    meta.className = 'opt-meta';
    meta.textContent = `${srv.id} · ${srv.desc}`;
    head.append(label, badge);
    card.append(head, meta);
    card.addEventListener('click', () => setNtpServer(srv.id));
    refs.ntpServerList.appendChild(card);
  });
  refs.ntpInfoRows.replaceChildren();
  const deviceTimeRow = buildInfoRow('设备时间', '—', '');
  const deviceTimeVal = deviceTimeRow.querySelector('.data-val');
  if (deviceTimeVal) deviceTimeVal.id = 'ntp-device-time';
  refs.ntpInfoRows.appendChild(deviceTimeRow);
  refs.ntpInfoRows.appendChild(buildInfoRow('自动同步', data.auto_time === '1' ? '已开启' : '已关闭', data.auto_time === '1' ? 'good' : 'warn'));
  startDeviceClock();
  const ntpLabel = servers.find((s) => s.id === current)?.name || current;
  refs.ntpDesc.textContent = `当前: ${ntpLabel} (${current})`;
}

async function refreshNtp() {
  try {
    const data = await apiFetch(API.ntp, { timeoutMs: 6000 });
    renderNtpCard(data);
  } catch (err) {
    refs.ntpServerList.replaceChildren(); refs.ntpServerList.appendChild(errorBlock('获取失败：' + err.message));
  }
}

async function setNtpServer(server) {
  if (state.ntpBusy || server === state.ntpServer) return;
  state.ntpBusy = true;
  try {
    const data = await apiFetch(API.ntp, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ server }),
      timeoutMs: 10000
    });
    if (data.ok) {
      const label = state.ntpServers.find((s) => s.id === server)?.name || server;
      if (data.refreshed === false) {
        showToast(`NTP 已切换为 ${label}，即时同步未完成`);
        appendLog(`NTP: ${server}（即时同步未完成）`, 'warn');
      } else {
        showToast(`NTP 已切换为 ${label} 并同步`);
        appendLog(`NTP: ${server}`, 'ok');
      }
      refreshNtp();
    } else {
      showToast(`切换失败：${data.error || '未知'}`);
    }
  } catch (_) {
    showToast('请求失败');
  } finally {
    state.ntpBusy = false;
  }
}

async function syncNtp() {
  if (state.ntpBusy) return;
  state.ntpBusy = true;
  refs.ntpSyncLabel.textContent = '同步中…';
  try {
    const data = await apiFetch(API.ntp, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'sync' }),
      timeoutMs: 10000
    });
    if (data.ok) {
      showToast('时间已同步');
      appendLog(`NTP 同步完成: ${data.device_time}`, 'ok');
      refreshNtp();
    } else {
      showToast('同步失败');
    }
  } catch (_) {
    showToast('同步请求失败');
  } finally {
    refs.ntpSyncLabel.textContent = '立即同步';
    state.ntpBusy = false;
  }
}

registerFeature('network', {
  async refresh() {
    await Promise.allSettled([
      refreshNrSwitch(),
      refreshUecap(),
      refreshBaseband(),
      refreshNtp(),
      refreshStandbyGuard()
    ]);
  },
  stopDeviceClock,
  syncDeviceClockForTab,
  buildNrSwitchDetail,
  toggleNrSwitch,
  toggleSim2AutoManage,
  toggleIdleIsolateMode,
  refreshBaseband,
  syncNtp,
  isBasebandInstalled: () => state.basebandInstalled,
  setBasebandInstalled(value) { state.basebandInstalled = Boolean(value); },
  setBasebandBackendState(value) {
    state.basebandState = value || null;
    state.basebandInstalled = Boolean(value && value.installed);
  },
});
})();

