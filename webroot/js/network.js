// NR、SIM、UECap、基带与 NTP 功能。
'use strict';
(() => {
const state = {
  basebandInstalled: false,
  basebandState: null,
  nrSwitch: 'off',
  nrContract: null,
  nrBusy: false,
  nrRecoveryPending: false,
  sim2AutoManage: 'off',
  idleIsolateMode: 'off',
  standbyGuardBusy: false,
  standbyDiag: null,
  uecapContract: null,
  uecapMode: 'unknown',
  uecapPolicy: 'disabled',
  uecapActiveMode: 'unknown',
  uecapBackend: '',
  uecapReinstallRequired: false,
  uecapBusy: false,
  uecapPendingMode: '',
  uecapVerifyState: 'idle',
  uecapVerifyMessage: '',
  uecapExpectedHash: '',
  uecapVerifyNonce: 0,
  ntpServer: '',
  ntpServers: [],
  ntpBusy: false,
  ntpAction: '',
  ntpRequestedServer: '',
  deviceClockTimer: null
};

const UECAP_REINSTALL_NOTICE = '请先卸载本模块并重启，再重新安装并选择所需配置';
// Include bounded Android IPC plus failure rollback; this is request patience,
// never a modal lifetime or a reason to prevent navigation.
const NETWORK_WRITE_TIMEOUT_MS = 30000;
const NETWORK_READ_TIMEOUTS = Object.freeze({
  nr: 12000,
  uecap: 30000,
  standby: 12000,
  baseband: 20000,
  ntp: 12000
});

const core = () => requireFeature('core');
const apiFetch = (...args) => core().apiFetch(...args);
const appendLog = (...args) => core().appendLog(...args);
const buildInfoRow = (...args) => core().buildInfoRow(...args);
const errorBlock = (...args) => core().errorBlock(...args);
const showToast = (...args) => core().showToast(...args);
const sleep = (...args) => core().sleep(...args);
const syncOptionalModuleUi = () => requireFeature('profile').syncOptionalModuleUi();

function formatDuration(seconds) {
  const value = Number(seconds);
  if (!Number.isFinite(value) || value < 0) return '—';
  if (value >= 3600) return `${Math.floor(value / 3600)}小时${Math.floor((value % 3600) / 60)}分`;
  if (value >= 60) return `${Math.floor(value / 60)}分${Math.floor(value % 60)}秒`;
  return `${Math.floor(value)}秒`;
}

function networkReadError(label, error, timeoutMs) {
  const code = error?.code || '';
  if (code === 'REQUEST_TIMEOUT') {
    return `${label}读取超时（${Math.ceil(timeoutMs / 1000)} 秒）。当前显示上次读取结果，请稍后刷新。`;
  }
  if (error?.status) return `${label}读取失败：${error.message || '服务未返回有效响应'}（${error.status}）`;
  return `${label}读取失败：${error?.message || '服务未返回有效响应'}`;
}

function networkStateText(value) {
  const labels = {
    yes: '已确认', no: '未确认', true: '是', false: '否', unknown: '状态未确认',
    missing: '无检查记录', none: '无', verified: '检查通过', unverified: '状态未确认',
    failed: '失败', pending: '处理中', disabled: '已关闭', enabled: '已开启',
    active: '已启用', modules: '已安装', modules_update: '待重启更新',
    candidate: '测试配置，验证未完成', confirmed_readback: '基带加载已确认',
    current_boot: '本次启动', current_check: '本次检查',
    current_boot_verified: '本次启动，检查通过', managed: '由模块管理',
    pre_modem_bind: '配置文件已就绪，基带加载状态未确认',
    modem_load_unconfirmed: '基带加载状态未确认',
    sa_observed: '已检测到 5G 独立组网', no_confirmed_nsa_cell: '5G 非独立组网连接未确认',
    previous_boot: '上次启动', stale: '记录已过期', historical: '历史记录',
    observed: '已检测到', not_observed: '未检测到', not_applicable: '不适用',
    not_required_magisk: 'Magisk 环境无需此项检查',
    effective_overlay_verified: '系统已使用模块配置',
    hybrid_mount: '重启后应用（Hybrid Mount）',
    metamodule_content: '模块镜像（MetaModule）'
  };
  return labels[String(value)] || (value ? `状态未确认（${value}）` : '状态未确认');
}

function buildNrSwitchDetail() {
  const contract = state.nrContract || {};
  const delay = Number.isFinite(contract.screenOffDelayS) ? contract.screenOffDelayS : null;
  const cooldown = Number.isFinite(contract.restoreCooldownS) ? contract.restoreCooldownS : null;
  const recheck = Number.isFinite(contract.lteRecheckS) ? contract.lteRecheckS : null;
  const lteMode = Number.isFinite(contract.lteMode) ? contract.lteMode : '未读取';
  const seconds = (value) => value === null ? '未读取' : `${value} 秒`;
  return `<b>息屏切换 4G</b><br><br>息屏达到 <b>${seconds(delay)}</b> 后，将主卡槽（slot 0）的首选网络模式设为 4G（LTE，模式值 ${lteMode}）。亮屏后恢复切换前的模式，副卡槽（slot 1）不变。<br><br><b>执行时间</b><br>息屏后延迟：${seconds(delay)}<br>恢复后最短间隔：${seconds(cooldown)}<br>4G 状态检查间隔：${seconds(recheck)}<br><br><b>暂停条件</b><br>热点开启、网络模式无效或无法保存原模式时，不执行切换。切换期间蜂窝数据可能短暂中断。`;
}
function renderNrSwitchRows(data) {
  state.nrRecoveryPending = data.nr_recovery_pending === true && data.nr_switch !== 'on';
  refs.nrSwitchRows.replaceChildren();
  const isOn = data.nr_switch === 'on';
  const slot0Raw = data.current_slot0 ?? String(data.current_mode || '').split(',')[0];
  const modeNum = String(slot0Raw).trim() === '' ? NaN : Number(slot0Raw);
  const settingLte = !Number.isNaN(modeNum) && modeNum < 23;
  const actualRat = String(data.actual_rat || '').toUpperCase();
  const actualKnown = actualRat && actualRat !== 'UNKNOWN';
  const actualLte = actualKnown && actualRat.includes('LTE') && !actualRat.includes('NR');
  const actualNr = actualKnown && actualRat.includes('NR');
  const modeLabel = actualKnown
    ? `${actualRat} · 首选模式 ${data.current_mode || '未读取'}`
    : (Number.isNaN(modeNum) ? (data.current_mode || '状态未确认') : (settingLte ? `已设置 4G（${data.current_mode}），连接状态未确认` : `已设置 5G（${data.current_mode}），连接状态未确认`));
  const rows = [
    { label: '功能状态', value: isOn ? '已开启' : '已关闭', cls: isOn ? 'good' : 'off' },
    { label: '当前网络模式', value: modeLabel, cls: actualLte || (!actualKnown && settingLte) ? 'warn' : actualNr ? 'good' : 'off' },
    { label: '亮屏后恢复模式', value: data.saved_nr_mode, cls: 'off' }
  ];
  rows.forEach((row) => refs.nrSwitchRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
  const delaySeconds = Number(data.screen_off_delay_s);
  const delayText = Number.isFinite(delaySeconds) ? formatDuration(delaySeconds) : '所设延迟';
  refs.nrSwitchDesc.textContent = isOn
    ? `已开启 · 息屏 ${delayText} 后切换为 4G，亮屏后恢复原网络模式。`
    : `开启后，息屏达到 ${delayText} 时切换为 4G，亮屏后恢复原网络模式。`;
  if (state.nrRecoveryPending) {
    refs.nrSwitchDesc.textContent = '功能已关闭，原网络模式尚未恢复。选择“重试恢复”可再次执行恢复。';
  }
  syncNrSwitchButton();
}

function syncNrSwitchButton() {
  const button = document.getElementById('nr-switch-toggle-btn');
  button.disabled = state.nrBusy;
  button.setAttribute('aria-busy', String(state.nrBusy));
  refs.nrSwitchToggleLabel.textContent = state.nrBusy ? '切换中…'
    : state.nrRecoveryPending ? '重试恢复' : state.nrSwitch === 'on' ? '关闭' : '开启';
}

function syncStandbyGuardButtons() {
  refs.sim2AutoToggleBtn.disabled = state.standbyGuardBusy;
  refs.idleIsolateToggleBtn.disabled = state.standbyGuardBusy;
}

function standbyWorkerModeLabel(mode) {
  if (mode === 'screen_on') return '亮屏记录';
  if (mode === 'deep_standby') return '息屏记录';
  if (mode === 'idle_isolate') return '后台策略暂停';
  return '未读取';
}

function standbyWorkerModeClass(mode) {
  if (mode === 'screen_on' || mode === 'deep_standby') return 'good';
  if (mode === 'idle_isolate') return 'warn';
  return 'off';
}

function formatStandbyTimestamp(value) {
  const ts = Number(value);
  if (!Number.isFinite(ts) || ts <= 0) return '—';
  return new Date(ts * 1000).toLocaleString();
}

function renderStandbyGuard(data) {
  const updatedAt = Number(data.diag_updated_at || data.diag_updated_epoch || 0);
  state.sim2AutoManage = data.sim2_auto_manage === 'on' ? 'on' : 'off';
  state.idleIsolateMode = typeof data.background_enabled === 'boolean'
    ? (data.background_enabled ? 'off' : 'on')
    : (data.idle_isolate_mode === 'on' ? 'on' : 'off');
  state.standbyDiag = {
    updatedAt: Number.isFinite(updatedAt) && updatedAt > 0 ? updatedAt : '',
    screen: data.diag_screen || 'unknown',
    workerMode: data.diag_worker_mode || 'unknown',
    nextSleepSecs: data.diag_next_sleep_secs || data.diag_next_sleep_sec || '',
    burstActive: data.diag_burst_active || '0',
    nrSwitch: data.diag_nr_switch || 'off',
    nrState: data.diag_nr_state || 'unknown',
    profilePolicy: data.diag_profile_policy || 'unknown',
    activeProfile: data.diag_active_profile || 'unknown',
    cycleCount: data.diag_cycle_count || '0',
    sleepMode: data.sleep_mode || 'unknown',
    sleepFailedDev: data.sleep_last_failed_dev || '',
    sleepFailedErrno: data.sleep_last_failed_errno || '',
    sleepFailedStep: data.sleep_last_failed_step || '',
    sleepErrorCode: data.sleep_error_code || 'SUSPEND_REASON_UNKNOWN',
    sleepErrorSeverity: data.sleep_error_severity || 'info',
    sleepErrorHuman: data.sleep_error_human || '休眠失败原因未确定，请查看本次启动的内核日志。',
  };

  const sim2On = state.sim2AutoManage === 'on';
  refs.sim2AutoToggleLabel.textContent = sim2On ? '关闭' : '开启';
  refs.sim2AutoDesc.textContent = sim2On
    ? '已开启。息屏时暂停空副卡槽的无线通信，亮屏或检测到副卡后恢复。'
    : '适用于仅使用一张 SIM 卡且副卡槽为空的设备。开启后，息屏时暂停空副卡槽的无线通信。';
  refs.sim2AutoRows.replaceChildren();
  [
    { label: '功能状态', value: sim2On ? '已开启' : '已关闭', cls: sim2On ? 'good' : 'off' },
    { label: '执行方式', value: sim2On ? '息屏时暂停空副卡槽通信' : '不调整副卡槽通信', cls: sim2On ? 'good' : 'off' },
    { label: '使用条件', value: '仅使用一张 SIM 卡，且副卡槽为空', cls: 'off' },
  ].forEach((row) => refs.sim2AutoRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));

  const isolateOn = state.idleIsolateMode === 'on';
  const workerState = data.background_state || 'unknown';
  const workerLabel = ({ running: '运行中', starting: '启动中', paused: '已停止', stopping: '正在停止，等待当前操作结束', stopped: '未启动', unknown: '状态未确认' })[workerState] || workerState;
  refs.idleIsolateToggleLabel.textContent = isolateOn ? '开启后台任务' : '关闭后台任务';
  refs.idleIsolateDesc.textContent = isolateOn
    ? `后台任务已关闭，温度记录和自动策略停止更新。进程状态：${workerLabel}。`
    : `后台任务已开启，温度记录和自动策略按设定间隔执行。进程状态：${workerLabel}。`;
  refs.idleIsolateRows.replaceChildren();
  [
    { label: '后台任务', value: isolateOn ? '已关闭，温度记录暂停' : '已开启', cls: isolateOn ? 'warn' : 'good' },
    { label: '后台进程', value: workerLabel, cls: data.final === false ? 'warn' : 'off' },
    { label: '临时参数恢复', value: data.background_cleanup === 'failed' ? '后台已停止，临时参数恢复失败。详情见运行记录' : data.background_cleanup === 'unconfirmed' ? '恢复结果未确认' : data.background_cleanup === 'ok' ? '已恢复' : '无本次停止记录', cls: ['failed', 'unconfirmed'].includes(data.background_cleanup) ? 'warn' : 'off' },
    { label: '温度记录', value: isolateOn ? '已暂停，历史记录仍可查看和导出' : '亮屏约每分钟、息屏约每 15 分钟记录一次；休眠期间不主动唤醒设备', cls: isolateOn ? 'off' : 'good' },
  ].forEach((row) => refs.idleIsolateRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));

  refs.standbyDiagRows.replaceChildren();
  if (!state.standbyDiag.updatedAt) {
    refs.standbyDiagRows.appendChild(buildInfoRow('检查结果', '等待后台任务完成首次检查', 'off'));
  } else {
    const nrLabel = state.standbyDiag.nrSwitch === 'on'
      ? (state.standbyDiag.nrState === 'lte' ? '自动切换已开启 · 当前 4G' : '自动切换已开启 · 当前 5G')
      : '自动切换已关闭';
    const profileLabel = `${state.standbyDiag.profilePolicy === 'auto' ? '自动' : state.standbyDiag.profilePolicy === 'manual' ? '手动' : '未确认'} / ${PROFILES[state.standbyDiag.activeProfile]?.name || '档位未确认'}`;
    [
      { label: '最近更新', value: formatStandbyTimestamp(state.standbyDiag.updatedAt), cls: 'off' },
      { label: '当前屏幕', value: state.standbyDiag.screen === 'on' ? '亮屏' : state.standbyDiag.screen === 'off' ? '息屏' : '未知', cls: state.standbyDiag.screen === 'on' ? 'good' : state.standbyDiag.screen === 'off' ? 'off' : 'warn' },
      { label: '记录方式', value: standbyWorkerModeLabel(state.standbyDiag.workerMode), cls: standbyWorkerModeClass(state.standbyDiag.workerMode) },
      { label: '距下次检查', value: state.standbyDiag.nextSleepSecs ? formatDuration(Number(state.standbyDiag.nextSleepSecs)) : '—', cls: 'off' },
      { label: '温度记录间隔', value: state.standbyDiag.screen === 'on' ? '亮屏约每分钟' : '息屏约每 15 分钟', cls: state.standbyDiag.screen === 'on' ? 'good' : 'off' },
      { label: '息屏切换 4G', value: nrLabel, cls: state.standbyDiag.nrState === 'lte' ? 'warn' : 'off' },
      { label: '调度状态', value: profileLabel, cls: 'off' },
      { label: '检查次数', value: state.standbyDiag.cycleCount || '0', cls: 'off' },
    ].forEach((row) => refs.standbyDiagRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
  }
  [
    { label: '内核休眠模式', value: state.standbyDiag.sleepMode === 'unknown' ? '状态未确认' : state.standbyDiag.sleepMode || '状态未确认', cls: 'off' },
    { label: '最近阻止休眠的设备', value: state.standbyDiag.sleepFailedDev || '暂无记录', cls: state.standbyDiag.sleepFailedDev ? 'warn' : 'off' },
    { label: '错误分类', value: state.standbyDiag.sleepErrorCode, cls: state.standbyDiag.sleepErrorSeverity === 'warning' ? 'warn' : 'off' },
    { label: '最近休眠失败原因', value: state.standbyDiag.sleepErrorHuman, cls: state.standbyDiag.sleepFailedDev ? 'warn' : 'off' },
  ].forEach((row) => refs.standbyDiagRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));

  syncStandbyGuardButtons();
}

function uecapLabel(mode) {
  if (UECAP_MODE_PRESENTATION[mode]) return UECAP_MODE_PRESENTATION[mode].name;
  if (mode === 'custom') return '系统或其他工具配置';
  if (mode === 'stock') return '系统配置';
  if (mode === 'disabled') return '当前不可用';
  return '配置未确认';
}

function updateUecapRuntimeGuard(data) {
  if (!data || typeof data !== 'object') return;
  const hasBackend = Object.prototype.hasOwnProperty.call(data, 'backend');
  const hasReinstall = Object.prototype.hasOwnProperty.call(data, 'reinstall_required');
  if (!hasBackend && !hasReinstall) return;
  if (hasBackend) {
    state.uecapBackend = typeof data.backend === 'string' ? data.backend : '';
    if (!hasReinstall) state.uecapReinstallRequired = false;
  }
  if (hasReinstall) {
    const requested = data.reinstall_required === true || data.reinstall_required === 'true';
    state.uecapReinstallRequired = requested && state.uecapBackend === 'metamodule_content';
  }
}

function applyUecapContract(data) {
  const raw = data?.uecap_contract;
  const modeOrder = Array.isArray(raw?.mode_order) ? raw.mode_order.filter((mode) => typeof mode === 'string') : [];
  const defaultMode = typeof raw?.default_mode === 'string' ? raw.default_mode : '';
  if (data?.disabled === true) {
    if (modeOrder.length !== 0 || defaultMode !== 'disabled') throw new Error('网络配置状态无效，无法切换');
    state.uecapContract = { modeOrder: [], defaultMode: 'disabled', disabled: true };
    return;
  }
  const valid = modeOrder.length > 0
    && new Set(modeOrder).size === modeOrder.length
    && modeOrder.every((mode) => UECAP_MODE_PRESENTATION[mode])
    && modeOrder.includes(defaultMode);
  if (!valid) throw new Error('网络配置选项不完整，无法切换');
  state.uecapContract = { modeOrder, defaultMode, disabled: false };
}

function getUecapModeHash(data, mode) {
  if (!data || !mode) return '';
  if (mode === 'stock') return data.target_hash || '';
  return data[`${mode}_hash`] || '';
}

function getUecapVerifyRow(data, requested, active) {
  if (state.uecapVerifyState === 'failed') {
    return {
      label: '配置文件校验',
      value: state.uecapVerifyMessage || '状态未确认，请刷新查看',
      cls: 'warn'
    };
  }

  if (state.uecapPendingMode) {
    const label = uecapLabel(state.uecapPendingMode);
    if (state.uecapVerifyState === 'switching') {
      return { label: '配置文件校验', value: `${label}：切换中`, cls: 'warn' };
    }
    if (state.uecapVerifyState === 'verifying') {
      return { label: '配置文件校验', value: `${label}：检查中`, cls: 'warn' };
    }
  }

  const expectedHash = getUecapModeHash(data, requested);
  const targetHash = data.target_hash || '';
  const bindingConfirmed = requested === active && Boolean(expectedHash) && expectedHash === targetHash;
  const receipt = data.runtime_receipt || {};
  const confirmed = bindingConfirmed && receipt.modem_load_state === 'confirmed_readback'
    && receipt.functional_state === 'verified' && ['current_boot', 'current_check'].includes(receipt.receipt_freshness);
  return {
    label: '配置文件校验',
    value: confirmed ? '文件校验通过，基带加载已确认' : bindingConfirmed ? '文件校验通过，基带加载状态未确认' : '状态未确认',
    cls: confirmed ? 'good' : 'warn'
  };
}

function renderUecapBtnGroup(activeMode) {
  const selectedMode = state.uecapPendingMode || activeMode;
  const modes = state.uecapContract?.modeOrder || [];
  const previous = Array.from(refs.uecapBtnGroup.querySelectorAll('.uecap-btn'));
  if (previous.map((button) => button.dataset.mode).join('|') !== modes.join('|')) refs.uecapBtnGroup.replaceChildren();
  const blocked = state.uecapReinstallRequired;
  refs.uecapBtnGroup.hidden = modes.length === 0;
  refs.uecapBtnGroup.setAttribute('aria-disabled', String(blocked));
  refs.uecapBtnGroup.setAttribute('role', 'group');
  refs.uecapBtnGroup.setAttribute('aria-label', '网络能力配置');
  modes.forEach((id) => {
    const presentation = UECAP_MODE_PRESENTATION[id];
    let btn = Array.from(refs.uecapBtnGroup.children).find((button) => button.dataset.mode === id);
    if (!btn) {
      btn = document.createElement('button');
      btn.dataset.mode = id;
      btn.addEventListener('click', () => setUecapMode(id));
      refs.uecapBtnGroup.appendChild(btn);
    }
    btn.type = 'button';
    const isSelected = id === selectedMode;
    const isPending = state.uecapBusy && id === state.uecapPendingMode;
    btn.className = `uecap-btn${isSelected ? ' active' : ''}${isPending ? ' pending' : ''}${isPending && state.uecapVerifyState === 'verifying' ? ' verifying' : ''}`;
    btn.dataset.mode = id;
    btn.textContent = isPending
      ? (state.uecapVerifyState === 'switching' ? '切换中…' : '检查中…')
      : presentation.name;
    btn.setAttribute('aria-pressed', String(isSelected));
    btn.setAttribute('aria-busy', String(isPending));
    btn.disabled = state.uecapBusy || blocked;
    btn.title = blocked ? UECAP_REINSTALL_NOTICE : '';
  });
}

function renderUecapRows(data) {
  updateUecapRuntimeGuard(data);
  applyUecapContract(data);
  const expandedGroups = new Set(Array.from(refs.uecapRows.querySelectorAll('details[open]')).map((group) => group.dataset.evidenceGroup));
  const receipt = data.runtime_receipt && typeof data.runtime_receipt === 'object'
    ? data.runtime_receipt : {};
  const disabled = Boolean(state.uecapContract.disabled);
  const requested = disabled
    ? (data.requested_mode || receipt.desired_profile || 'disabled')
    : (data.requested_mode || state.uecapMode || state.uecapContract.defaultMode);
  const active = data.active_mode || receipt.bound_profile || (disabled ? 'stock' : 'custom');
  state.uecapMode = requested;
  state.uecapPolicy = data.policy || data.runtime_policy || 'disabled';
  state.uecapActiveMode = active;
  const modeInfo = UECAP_MODE_PRESENTATION[requested];
  refs.uecapDesc.textContent = state.uecapReinstallRequired
    ? `当前安装方式需重新安装才能更改网络配置。${UECAP_REINSTALL_NOTICE}。`
    : disabled
      ? (data.disabled_message || '当前环境不支持修改网络能力配置，可查看配置和连接状态。')
      : state.uecapPendingMode
        ? `${uecapLabel(state.uecapPendingMode)}：切换请求已提交，正在检查结果。`
        : modeInfo ? `已保存配置：${modeInfo.name}。实际应用情况见下方状态。` : '选择网络能力配置后，可在下方查看实际应用情况。';
  renderUecapBtnGroup(disabled ? 'disabled' : requested);
  const verifyRow = disabled
    ? { label: '配置文件校验', value: `${networkStateText(data.contract_result)} · 只读`, cls: 'off' }
    : getUecapVerifyRow(data, requested, active);
  const reloadResult = receipt.reload_result === 'success'
    ? (receipt.modem_load_state === 'confirmed_readback' ? '基带已重新加载配置，检查通过' : '基带已接受加载请求，结果未确认')
    : receipt.reload_result === 'failed'
      ? '基带重新加载配置失败'
      : receipt.reload_result === 'unknown'
        ? '无运行检查记录'
        : '未执行';
  const nrRegistered = receipt.nr_registered === 'true' || receipt.nr_registered === true;
  const nrAvailable = receipt.nr_available === 'true' || receipt.nr_available === true;
  const nrBand = receipt.nr_band && receipt.nr_band !== 'unknown' ? ` / 频段 ${receipt.nr_band}` : '';
  const actualRat = String(receipt.actual_rat || 'unknown').toUpperCase();
  const observedRat = String(receipt.radio_observed_state || 'UNKNOWN').toUpperCase();
  const nsaStatus = String(receipt.nsa_status || (observedRat === 'NR_NSA' ? 'observed' : 'not_applicable'));
  const nsaReason = String(receipt.nsa_reason || (observedRat === 'NR_SA' ? 'sa_observed' : 'no_confirmed_nsa_cell'));
  const radioResult = observedRat === 'NR_SA' || actualRat === 'NR_SA'
    ? `5G 独立组网${nrBand}（无需 4G 锚点）`
    : observedRat === 'NR_NSA' || actualRat === 'NR_NSA'
      ? `5G 非独立组网${nrBand}（已检测到 4G 锚点）`
      : actualRat === 'LTE' || observedRat === 'LTE'
        ? '4G / LTE（仅表示当前连接，无法判断配置加载结果）'
        : nrRegistered
          ? `已注册 5G 网络${nrBand}`
          : nrAvailable
            ? `5G 网络可用，尚未注册${nrBand}`
            : '5G 连接状态未确认';
  const hasConfirmedModemLoad = receipt.modem_load_state === 'confirmed_readback';
  const isCurrentReceipt = receipt.receipt_freshness === 'current_boot';
  const changeMode = state.uecapReinstallRequired
    ? UECAP_REINSTALL_NOTICE
    : disabled ? '仅支持查看' : '支持立即切换';
  const rows = [
    { label: '设备型号', value: `${data.device || '未读取'} / ${data.device_label || '未读取'}`, cls: 'off' },
    { label: '机型支持范围', value: networkStateText(data.device_policy), cls: 'off' },
    { label: '配置应用方式', value: networkStateText(state.uecapBackend), cls: state.uecapReinstallRequired ? 'warn' : 'off' },
    { label: '切换方式', value: changeMode, cls: state.uecapReinstallRequired ? 'warn' : disabled ? 'off' : 'good' },
    { label: '当前管理策略', value: networkStateText(data.runtime_policy || data.policy), cls: disabled ? 'off' : 'good' },
    { label: '已保存配置', value: uecapLabel(requested), cls: requested === active ? 'good' : 'off' },
    { label: '当前配置文件', value: uecapLabel(active), cls: active === requested ? 'good' : 'warn' },
    verifyRow,
    { label: '基带加载状态', value: networkStateText(receipt.modem_load_state), cls: hasConfirmedModemLoad ? 'good' : 'warn' },
    { label: '基带已加载配置', value: receipt.modem_loaded_profile && UECAP_MODE_PRESENTATION[receipt.modem_loaded_profile] ? uecapLabel(receipt.modem_loaded_profile) : networkStateText(receipt.modem_loaded_profile), cls: 'off' },
    { label: '基带重新加载结果', value: reloadResult, cls: receipt.reload_result === 'failed' ? 'warn' : hasConfirmedModemLoad ? 'good' : 'off' },
    { label: '运行状态检查', value: networkStateText(receipt.functional_state), cls: receipt.functional_state === 'verified' ? 'good' : 'warn' },
    { label: '检查记录有效期', value: networkStateText(receipt.receipt_freshness || 'missing'), cls: isCurrentReceipt ? 'good' : 'warn' },
    { label: '配置文件与校验值', value: `${data.target_name || '未读取'} / ${(data.target_hash || '未读取').slice(0, 16)}`, cls: 'off' },
    { label: '配置来源版本', value: `${networkStateText(data.payload_state)} · ${data.payload_source_build || '未读取'}`, cls: data.payload_state === 'verified' ? 'good' : data.payload_state === 'candidate' ? 'warn' : 'off' },
    { label: '文件大小与校验值', value: `${data.payload_bytes || 0} 字节 / ${(data.payload_sha256 || '未读取').slice(0, 16)}`, cls: 'off' },
    { label: '实际网络连接', value: radioResult, cls: observedRat === 'NR_SA' || observedRat === 'NR_NSA' ? 'good' : 'off' },
    { label: '5G 独立组网（SA）', value: observedRat === 'NR_SA' ? '已检测到，无需 4G 锚点' : '未检测到', cls: observedRat === 'NR_SA' ? 'good' : 'off' },
    { label: '5G 非独立组网（NSA）', value: `${networkStateText(nsaStatus)} · ${networkStateText(nsaReason)}`, cls: nsaStatus === 'observed' ? 'good' : 'off' },
    { label: 'LTE / 4G', value: actualRat === 'LTE' || observedRat === 'LTE' ? '已检测到，仅表示当前连接' : '未检测到', cls: 'off' },
    { label: '4G 锚点（NSA 辅助连接）', value: networkStateText(receipt.lte_anchor), cls: 'off' },
    { label: '状态说明', value: data.reason || '未提供', cls: disabled ? 'off' : 'warn' },
  ];
  const summary = document.getElementById('uecap-summary');
  if (summary) summary.replaceChildren(...[
    { label: '已保存配置', value: uecapLabel(requested), cls: 'off' },
    { label: '当前配置文件', value: uecapLabel(active), cls: active === requested ? 'good' : 'warn' },
    verifyRow
  ].map((row) => buildInfoRow(row.label, row.value, row.cls)));
  const notice = document.getElementById('uecap-status-message');
  if (notice) {
    const unsafe = state.uecapReinstallRequired || disabled || state.uecapVerifyState === 'failed'
      || verifyRow.cls === 'warn' || receipt.functional_state === 'failed';
    notice.hidden = !unsafe;
    notice.textContent = state.uecapReinstallRequired ? UECAP_REINSTALL_NOTICE
      : disabled ? (data.disabled_message || '当前环境仅支持查看，无法切换配置。')
        : state.uecapVerifyState === 'failed' ? verifyRow.value
          : unsafe ? '状态未确认。请在“配置与无线诊断”中查看检查结果，再决定是否重试。' : '';
  }
  const groups = [
    { id: 'effective', title: '配置应用状态', help: '分别显示保存配置、系统文件和基带加载结果', labels: ['切换方式', '已保存配置', '当前配置文件', '配置文件校验', '基带加载状态', '基带已加载配置', '基带重新加载结果', '运行状态检查', '检查记录有效期'] },
    { id: 'radio', title: '网络连接', help: '显示当前连接方式，无法单独判断配置是否已加载', labels: ['实际网络连接', '5G 独立组网（SA）', '5G 非独立组网（NSA）', 'LTE / 4G', '4G 锚点（NSA 辅助连接）'] },
    { id: 'source', title: '设备与配置来源', help: '显示机型支持范围、配置来源和文件校验结果', labels: ['设备型号', '机型支持范围', '配置应用方式', '当前管理策略', '配置文件与校验值', '配置来源版本', '文件大小与校验值', '状态说明'] }
  ];
  const containers = groups.map((group) => {
    let details = refs.uecapRows.querySelector(`[data-evidence-group="${group.id}"]`);
    if (!details) {
      details = document.createElement('details'); details.className = 'disclosure compact'; details.dataset.evidenceGroup = group.id; details.open = expandedGroups.has(group.id);
      const head = document.createElement('summary'); head.className = 'disclosure-summary';
      const copy = document.createElement('span'); copy.className = 'disclosure-copy';
      const title = document.createElement('strong'); title.textContent = group.title;
      const help = document.createElement('small'); help.textContent = group.help;
      const chevron = document.createElement('span'); chevron.className = 'disclosure-chevron'; chevron.textContent = '›'; chevron.setAttribute('aria-hidden', 'true');
      copy.append(title, help); head.append(copy, chevron);
      const body = document.createElement('div'); body.className = 'disclosure-body data-list';
      details.append(head, body);
    }
    details.querySelector('.disclosure-body').replaceChildren(...rows.filter((row) => group.labels.includes(row.label)).map((row) => buildInfoRow(row.label, row.value, row.cls)));
    return details;
  });
  if (containers.some((container) => !container.isConnected)) refs.uecapRows.replaceChildren(...containers);
}

async function refreshNrSwitch({ readback = false } = {}) {
  try {
    const data = await apiFetch(API.nrSwitch, { timeoutMs: NETWORK_READ_TIMEOUTS.nr, dedupe: !readback, priority: readback ? 'interactive' : 'normal', scope: 'network.nr.read' });
    state.nrSwitch = data.nr_switch || 'off';
    state.nrContract = {
      screenOffDelayS: Number(data.screen_off_delay_s),
      restoreCooldownS: Number(data.restore_cooldown_s),
      lteRecheckS: Number(data.lte_recheck_s),
      lteMode: Number(data.lte_mode)
    };
    renderNrSwitchRows(data);
    return true;
  } catch (err) {
    if (requireFeature('core').isRequestCancelled?.(err)) return null;
    refs.nrSwitchRows.replaceChildren(); refs.nrSwitchRows.appendChild(errorBlock(networkReadError('息屏切换 4G', err, NETWORK_READ_TIMEOUTS.nr)));
    return false;
  }
}

async function refreshUecap() {
  try {
    const data = await apiFetch(API.uecap, { timeoutMs: NETWORK_READ_TIMEOUTS.uecap, priority: 'normal', scope: 'network.uecap.read' });
    updateUecapRuntimeGuard(data);
    applyUecapContract(data);
    state.uecapMode = data.requested_mode || state.uecapContract.defaultMode;
    state.uecapPolicy = data.policy || data.runtime_policy || 'disabled';
    state.uecapActiveMode = data.active_mode || (state.uecapContract.disabled ? 'stock' : 'custom');
    const expectedHash = getUecapModeHash(data, state.uecapMode);
    if (!state.uecapPendingMode && state.uecapVerifyState === 'failed' && state.uecapMode === state.uecapActiveMode && (!expectedHash || expectedHash === data.target_hash)) {
      state.uecapVerifyState = 'idle';
      state.uecapVerifyMessage = '';
    }
    renderUecapRows(data);
    return true;
  } catch (err) {
    if (requireFeature('core').isRequestCancelled?.(err)) return null;
    const message = networkReadError('网络能力配置', err, NETWORK_READ_TIMEOUTS.uecap);
    // A slow UECap inspection must not erase a previously verified contract or
    // remove the mode buttons. The backend remains authoritative; show the
    // stale-read notice and keep the last confirmed state visible.
    if (!state.uecapContract) {
      refs.uecapBtnGroup.replaceChildren();
      refs.uecapBtnGroup.hidden = true;
      refs.uecapRows.replaceChildren(); refs.uecapRows.appendChild(errorBlock(message));
    }
    const summary = document.getElementById('uecap-summary');
    if (summary) {
      summary.querySelectorAll('.badge').forEach((badge) => { badge.className = 'badge off'; });
      const result = summary.lastElementChild;
      if (result) result.replaceWith(buildInfoRow('配置文件校验', '本次读取失败，当前显示上次检查结果', 'warn'));
    }
    const notice = document.getElementById('uecap-status-message');
    if (notice) { notice.hidden = false; notice.textContent = `${message} 当前显示上次读取结果。`; }
    return false;
  }
}

async function refreshStandbyGuard() {
  try {
    const data = await apiFetch(API.standbyGuard, { timeoutMs: NETWORK_READ_TIMEOUTS.standby, priority: 'normal', scope: 'network.standby.read' });
    renderStandbyGuard(data);
    return true;
  } catch (err) {
    if (requireFeature('core').isRequestCancelled?.(err)) return null;
    const message = networkReadError('后台任务', err, NETWORK_READ_TIMEOUTS.standby);
    refs.sim2AutoRows.replaceChildren(); refs.sim2AutoRows.appendChild(errorBlock(message));
    refs.idleIsolateRows.replaceChildren(); refs.idleIsolateRows.appendChild(errorBlock(message));
    refs.standbyDiagRows.replaceChildren(); refs.standbyDiagRows.appendChild(errorBlock(message));
    return false;
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
      requestClass: 'lifecycle', timeoutMs: NETWORK_WRITE_TIMEOUT_MS, scope: 'network.standby'
    });
    if (data.ok) {
      const readback = await apiFetch(API.standbyGuard, { timeoutMs: NETWORK_READ_TIMEOUTS.standby, dedupe: false, priority: 'interactive', scope: 'network.standby.readback' });
      const mismatch = Object.keys(update).find((key) => String(readback?.[key] ?? '') !== String(update[key]));
      if (readback?.ok === false || mismatch) throw new Error(mismatch ? `实际设置与提交值不一致：${mismatch}` : (readback?.error || '实际状态读取失败'));
      renderStandbyGuard(readback);
      if (readback.final === false) {
        showToast('设置已保存，后台进程正在启动或停止。请刷新查看结果', 4500, 'warn');
        return;
      }
      showToast(successText);
      appendLog(logText, 'ok');
    } else {
      showToast(`操作失败：${data.error || '未提供错误详情'}`);
    }
  } catch (err) {
    if (!requireFeature('core').isRequestCancelled?.(err)) {
      const committed = err?.payload?.committed === true;
      // A failed cleanup can still leave a verified paused worker and saved
      // pause intent. Keep the next toggle aligned with that confirmed state.
      if (committed) renderStandbyGuard(err.payload);
      const message = err?.message || String(err);
      showToast(`${committed ? '设置已保存，后台进程状态未确认' : '操作失败'}：${message}`);
      appendLog(`后台任务设置失败：${message}`, 'err');
    }
  } finally {
    state.standbyGuardBusy = false;
    syncStandbyGuardButtons();
  }
}

async function toggleSim2AutoManage() {
  const next = state.sim2AutoManage === 'on' ? 'off' : 'on';
  await setStandbyGuard(
    { sim2_auto_manage: next },
    next === 'on' ? '空副卡槽省电已开启' : '空副卡槽省电已关闭',
    next === 'on' ? '空副卡槽省电：已开启' : '空副卡槽省电：已关闭'
  );
}

async function toggleIdleIsolateMode() {
  const next = state.idleIsolateMode === 'on' ? 'off' : 'on';
  await setStandbyGuard(
    { idle_isolate_mode: next },
     next === 'on' ? '模块后台任务已关闭（含温度记录）' : '模块后台任务已开启',
     next === 'on' ? '后台任务：已关闭' : '后台任务：已开启'
  );
}

// ── 后台应用限制 ─────────────────────────────────────────
async function verifyUecapSwitch(mode, expectedHash, initialData) {
  const nonce = ++state.uecapVerifyNonce;
  const label = UECAP_MODE_PRESENTATION[mode]?.name || mode;
  const deadline = Date.now() + UECAP_VERIFY_TIMEOUT_MS;
  let lastData = initialData;
  let lastErr = '';
  const finishIfConfirmed = (data) => {
    const confirmedHash = expectedHash || getUecapModeHash(data, mode);
    if (data.requested_mode !== mode || data.active_mode !== mode
      || !confirmedHash || data.target_hash !== confirmedHash) return false;
    state.uecapBusy = false;
    state.uecapPendingMode = '';
    state.uecapExpectedHash = '';
    state.uecapVerifyState = 'idle';
    state.uecapVerifyMessage = '';
    renderUecapRows(data);
    showToast(`系统配置文件已更新：${label}`);
    appendLog(`网络能力配置文件校验通过：${label}`, 'ok');
    return true;
  };

  // POST already returns the locked file readback. Do not hold the controls
  // for a fixed sleep and another GET when that receipt proves this result.
  if (finishIfConfirmed(initialData)) return;

  state.uecapPendingMode = mode;
  state.uecapExpectedHash = expectedHash || '';
  state.uecapVerifyState = 'switching';
  renderUecapRows(lastData);

  while (state.uecapVerifyNonce === nonce && Date.now() < deadline && core().isWebUiActive()) {
    state.uecapVerifyState = 'verifying';
    if (lastData) renderUecapRows(lastData);

    try {
      const data = await apiFetch(API.uecap, { timeoutMs: Math.min(NETWORK_READ_TIMEOUTS.uecap, Math.max(1, deadline - Date.now())), dedupe: false, priority: 'normal', scope: 'network.uecap.read' });
      if (state.uecapVerifyNonce !== nonce) return;
      lastData = data;
      state.uecapMode = data.requested_mode || mode;
      state.uecapActiveMode = data.active_mode || 'custom';
      renderUecapRows(data);

      if (finishIfConfirmed(data)) return;
    } catch (err) {
      if (requireFeature('core').isRequestCancelled?.(err)) {
        lastErr = '检查已暂停，请刷新查看结果';
        break;
      }
      lastErr = err.message || '请求失败';
    }

    await sleep(UECAP_VERIFY_INTERVAL_MS);
  }

  if (state.uecapVerifyNonce !== nonce) return;
  if (!core().isWebUiActive()) lastErr = '页面已进入后台，检查已暂停；返回后请刷新';

  state.uecapBusy = false;
  state.uecapPendingMode = '';
  state.uecapExpectedHash = '';
  state.uecapVerifyState = 'failed';
  state.uecapVerifyMessage = lastErr
    ? `状态未确认（${lastErr}）`
    : `检查超时（${Math.round(UECAP_VERIFY_TIMEOUT_MS / 1000)} 秒），请刷新查看结果`;

  if (lastData) renderUecapRows(lastData);
  showToast(`${label}切换请求已提交，${state.uecapVerifyMessage}`, 4200, 'warn');
  appendLog(`网络能力配置状态未确认：${label}`, 'warn');
}

async function toggleNrSwitch() {
  if (state.nrBusy) return;
  state.nrBusy = true;
  syncNrSwitchButton();
  try {
    const request = state.nrRecoveryPending ? { action: 'set', enabled: 'off' } : { action: 'toggle' };
    const data = await apiFetch(API.nrSwitch, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(request), timeoutMs: NETWORK_WRITE_TIMEOUT_MS, priority: 'interactive', scope: 'network.nr' });
    if (data.ok) {
      state.nrRecoveryPending = false;
      state.nrSwitch = data.nr_switch;
      const readback = await refreshNrSwitch({ readback: true });
      if (!readback || state.nrSwitch !== data.nr_switch) {
        showToast('设置已提交，息屏切换 4G 的实际状态未确认');
        appendLog('息屏切换 4G：设置已提交，实际状态未确认', 'warn');
      } else {
        showToast(data.nr_switch === 'on' ? '息屏切换 4G 已开启' : '息屏切换 4G 已关闭');
        appendLog(data.nr_switch === 'on' ? '息屏切换 4G：已开启' : '息屏切换 4G：已关闭', 'ok');
      }
    } else {
      showToast('操作失败');
    }
  } catch (err) {
    if (err?.payload?.committed && err.payload.nr_switch === 'off') {
      state.nrRecoveryPending = true;
      state.nrSwitch = 'off';
      refs.nrSwitchDesc.textContent = '自动切换已关闭，原网络模式恢复结果未确认。请刷新查看结果。';
    }
    const message = err?.message || String(err);
    if (!requireFeature('core').isRequestCancelled?.(err)) showToast(`请求失败：${message}`);
    appendLog(`息屏切换 4G 请求失败：${message}`, 'err');
  } finally {
    state.nrBusy = false;
    syncNrSwitchButton();
  }
}

async function setUecapMode(mode) {
  if (!state.uecapContract?.modeOrder.includes(mode)
    || state.uecapReinstallRequired
    || state.uecapBusy
    || (mode === state.uecapMode && state.uecapVerifyState !== 'failed')) return;
  const label = UECAP_MODE_PRESENTATION[mode]?.name || mode;
  state.uecapBusy = true;
  state.uecapPendingMode = mode;
  state.uecapVerifyState = 'switching';
  state.uecapVerifyMessage = `${label}：正在提交切换请求`;
  renderUecapRows({
    policy: state.uecapPolicy,
    disabled: false,
    backend: state.uecapBackend,
    reinstall_required: state.uecapReinstallRequired,
    uecap_contract: { mode_order: state.uecapContract.modeOrder, default_mode: state.uecapContract.defaultMode },
    requested_mode: state.uecapMode || mode,
    active_mode: state.uecapActiveMode || 'custom',
    target_hash: state.uecapExpectedHash || 'unknown'
  });
  try {
    const data = await apiFetch(API.uecap, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ policy: state.uecapPolicy, mode }),
      timeoutMs: NETWORK_READ_TIMEOUTS.uecap, priority: 'interactive', scope: 'network.uecap'
    });
    if (data.ok) {
      state.uecapMode = data.requested_mode || mode;
      state.uecapActiveMode = data.active_mode || state.uecapActiveMode || 'custom';
      if (data.reboot_required) {
        state.uecapBusy = false;
        state.uecapPendingMode = '';
        state.uecapExpectedHash = '';
        state.uecapVerifyState = 'idle';
        renderUecapRows(data);
        showToast(`${label}已保存，待重启应用`, 4200);
        appendLog(`网络能力配置已保存，待重启：${label}`, 'warn');
        return;
      }
      const expectedHash = getUecapModeHash(data, mode) || data.target_hash || '';
      state.uecapExpectedHash = expectedHash;
      state.uecapVerifyState = data.reloading ? 'switching' : 'verifying';
      renderUecapRows(data);
      showToast(`${label}切换请求已提交，正在检查结果`, 2600);
      appendLog(`网络能力配置切换请求已提交：${label}，等待检查结果`, 'ok');
      await verifyUecapSwitch(mode, expectedHash, data);
    } else if (data.applied) {
      state.uecapMode = data.requested_mode || mode;
      state.uecapActiveMode = data.active_mode || mode;
      state.uecapBusy = false;
      state.uecapPendingMode = '';
      state.uecapExpectedHash = '';
      state.uecapVerifyState = 'failed';
      state.uecapVerifyMessage = data.error || '系统配置文件已更新，基带重新加载尚未完成';
      renderUecapRows(data);
      showToast(state.uecapVerifyMessage, 4200);
      appendLog(`网络能力配置文件已更新，基带重新加载失败：${label}`, 'warn');
    } else {
      showToast(`切换失败：${data.error || '未提供错误详情'}`);
      state.uecapBusy = false;
      state.uecapPendingMode = '';
      state.uecapExpectedHash = '';
      state.uecapVerifyState = 'failed';
      state.uecapVerifyMessage = data.error || '切换请求提交失败';
      await refreshUecap();
    }
  } catch (err) {
    const message = err?.message || String(err);
    const payload = err?.payload;
    if (payload?.applied) {
      state.uecapMode = payload.requested_mode || mode;
      state.uecapActiveMode = payload.active_mode || mode;
      state.uecapVerifyState = 'failed';
      state.uecapVerifyMessage = payload.error || '系统配置文件已更新，基带重新加载尚未完成';
      renderUecapRows(payload);
      showToast(state.uecapVerifyMessage, 4200);
      appendLog(`网络能力配置文件已更新，基带重新加载失败：${label}`, 'warn');
      state.uecapBusy = false;
      state.uecapPendingMode = '';
      state.uecapExpectedHash = '';
      return;
    }
    if (!requireFeature('core').isRequestCancelled?.(err)) showToast(`请求失败：${message}`);
    appendLog(`网络能力配置请求失败：${message}`, 'err');
    state.uecapBusy = false;
    state.uecapPendingMode = '';
    state.uecapExpectedHash = '';
    state.uecapVerifyState = 'failed';
    state.uecapVerifyMessage = '请求失败，状态未确认。请先刷新查看结果';
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
    ? `已安装 ${data.version || ''}，本次启动已生效。`
    : `已安装 ${data.version || ''}，生效状态未确认。请查看模块状态和检查结果。`;
  const props = data.props || {};
  const cs = data.carrier_settings || {};
  const mcfg = data.mcfg || {};
  const freshness = data.runtime_receipt_freshness || 'missing';
  const rows = [
    { label: '安装状态', value: `${networkStateText(data.source)} / ${networkStateText(moduleState)}`, cls: data.enabled ? 'good' : 'warn' },
    { label: '运行状态', value: runtimeVerified ? '本次启动已生效' : '已检测到安装文件，生效状态未确认', cls: runtimeVerified ? 'good' : 'warn' },
    { label: '版本', value: data.version || '未知', cls: 'off' },
    { label: '状态接口版本', value: `版本 ${data.status_schema || 0}`, cls: Number(data.status_schema) === 3 ? 'good' : 'warn' },
    { label: '配置挂载', value: networkStateText(data.mount_observed), cls: data.mount_observed === 'yes' || data.mount_observed === 'not_required_magisk' ? 'good' : 'warn' },
    { label: '系统配置检查', value: networkStateText(data.effective_overlay_verified), cls: data.effective_overlay_verified === 'yes' ? 'good' : 'warn' },
    { label: '配置应用状态', value: networkStateText(data.migration_state), cls: data.migration_state === 'effective_overlay_verified' ? 'good' : 'warn' },
    { label: '模块文件 → 系统位置', value: `${data.source_path || '未读取'} → ${data.effective_path || '未读取'}`, cls: 'off' },
    { label: '模块文件校验', value: `${networkStateText(data.source_contract_verified || 'no')} / ${(data.source_contract_hash || data.source_hash || '未读取').slice(0, 12)}`, cls: data.source_contract_verified === 'yes' ? 'good' : 'warn' },
    { label: '模块镜像校验', value: `${networkStateText(data.content_image_verified)} / ${(data.content_contract_hash || data.content_image_hash || '未读取').slice(0, 12)}`, cls: data.content_image_verified === 'yes' || data.content_image_verified === 'not_required_magisk' ? 'good' : 'warn' },
    { label: '系统文件校验', value: `${networkStateText(data.effective_contract_verified || 'no')} / ${(data.effective_contract_hash || data.effective_hash || '未读取').slice(0, 12)}`, cls: data.effective_contract_verified === 'yes' ? 'good' : 'warn' },
    { label: '额外配置文件', value: networkStateText(data.effective_extra_files_allowed), cls: data.effective_extra_files_allowed === 'yes' ? 'off' : 'warn' },
    { label: '检查记录', value: `${networkStateText(freshness)} / 前次：${networkStateText(data.prior_receipt_freshness || 'missing')}`, cls: freshness === 'current_check' ? 'good' : 'warn' },
    { label: '完整重装', value: data.clean_reinstall_required ? '需要：卸载 → 重启 → 安装 → 重启' : '不需要', cls: data.clean_reinstall_required ? 'warn' : 'good' },
    { label: '错误摘要', value: data.errors && data.errors !== 'none' ? data.errors : '无', cls: data.errors && data.errors !== 'none' ? 'warn' : 'off' },
    { label: 'VoLTE', value: props.volte_avail_ovr === '1' ? '已启用' : '未启用', cls: props.volte_avail_ovr === '1' ? 'good' : 'warn' },
    { label: 'Wi-Fi Calling', value: props.wfc_avail_ovr === '1' ? '已启用' : '未启用', cls: props.wfc_avail_ovr === '1' ? 'good' : 'warn' },
    { label: '运营商配置', value: cs.installed ? `${cs.count} 项` : '未安装', cls: cs.installed ? 'good' : 'off' },
    { label: '国内运营商 MCFG', value: mcfg.installed ? `${mcfg.count} 个 MBN 文件` : '未安装', cls: mcfg.installed ? 'good' : 'off' },
  ];
  rows.forEach((row) => refs.basebandRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
}

async function refreshBasebandTask() {
  if (!state.basebandInstalled && (!state.basebandState || !state.basebandState.installed)) {
    syncOptionalModuleUi();
    return true;
  }
  try {
      const data = await apiFetch(API.checkBaseband, { timeoutMs: NETWORK_READ_TIMEOUTS.baseband, priority: 'normal', scope: 'network.baseband.read' });
    renderBasebandRows(data);
    return true;
  } catch (err) {
    if (requireFeature('core').isRequestCancelled?.(err)) return null;
    const status = Number(err?.status || 0);
    const detail = err?.detail || err?.message || '未提供错误详情';
    const reason = status === 404
      ? '基带状态接口不可用，请检查模块是否已启用、安装文件是否完整。'
      : status === 503
        ? '模块正在启动，请稍后刷新。'
        : '详细错误见运行记录。';
    const message = status === 0 && err?.code === 'REQUEST_TIMEOUT'
      ? networkReadError('基带配置', err, NETWORK_READ_TIMEOUTS.baseband)
      : `基带配置读取失败（HTTP ${status || '状态未返回'}）：${detail}\n${reason}`;
    refs.basebandRows.replaceChildren(); refs.basebandRows.appendChild(errorBlock(message));
    appendLog(message, 'err');
    return false;
  }
}

let basebandLastRefreshAt = 0;
async function refreshBaseband() {
  return requireFeature('core').runFeatureTask('network.baseband.refresh', async () => {
    // common.loadInfo may ask for the baseband receipt immediately after the
    // network page refresh. Reuse a fresh authoritative read instead of
    // issuing the same binder/mount inspection twice.
    if (Date.now() - basebandLastRefreshAt < 3000) return true;
    const result = await refreshBasebandTask();
    if (result === true) basebandLastRefreshAt = Date.now();
    return result;
  });
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
  refs.ntpServerList.setAttribute('role', 'radiogroup');
  refs.ntpServerList.setAttribute('aria-label', 'NTP 服务器');
  const servers = Array.isArray(data.servers)
    ? data.servers.map((server) => ({
      ...server,
      id: server?.id || server?.host || '',
      name: server?.name || server?.label || server?.host || '',
      desc: server?.desc || server?.region || ''
    })).filter((server) => server.id)
    : state.ntpServers;
  if (!servers.length) {
    refs.ntpServerList.appendChild(errorBlock('未提供可选 NTP 服务器'));
    return;
  }
  state.ntpServers = servers;
  // Empty is an authoritative unset system value, not permission to select
  // the module catalog default or suppress the user's first explicit choice.
  const current = String(data.ntp_server ?? data.current ?? data.server ?? '');
  const managed = data.ntp_server_allowed !== false && servers.some((server) => server.id === current);
  state.ntpServer = current;
  servers.forEach((srv) => {
    const card = document.createElement('button');
    card.type = 'button';
    card.dataset.server = srv.id;
    card.setAttribute('role', 'radio');
    card.setAttribute('aria-checked', String(srv.id === current));
    card.className = `opt-item${srv.id === current ? ' ntp-selected' : ''}`;
    card.setAttribute('aria-label', `${srv.name || srv.id}，${srv.id === current ? '当前服务器' : '使用此服务器'}`);
    const head = document.createElement('div');
    head.className = 'opt-item-head';
    const label = document.createElement('div');
    label.className = 'opt-label';
    label.textContent = srv.name || srv.id;
    const badge = document.createElement('span');
    badge.className = `badge ${srv.id === current ? 'good' : 'off'}`;
    badge.textContent = srv.id === current ? '当前使用' : '选择';
    const meta = document.createElement('div');
    meta.className = 'opt-meta';
    meta.textContent = `${srv.id} · ${srv.desc || '系统提供的时间同步服务器'}`;
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
  if (!managed) refs.ntpInfoRows.appendChild(buildInfoRow('当前服务器', data.ntp_server_source === 'system_default'
    ? '由系统管理，未指定服务器' : current ? `${current}（自定义服务器）` : '配置未读取', 'warn'));
  const autoTime = String(data.auto_time);
  refs.ntpInfoRows.appendChild(buildInfoRow('系统自动校时', autoTime === '1' ? '已开启' : autoTime === '0' ? '已关闭' : '状态未确认', autoTime === '1' ? 'good' : 'warn'));
  startDeviceClock();
  const ntpLabel = servers.find((s) => s.id === current)?.name || current;
  refs.ntpDesc.textContent = data.ntp_server_source === 'system_default'
    ? '当前由系统管理时间服务器。选择下方服务器后，将保存为指定服务器。'
    : managed ? `当前服务器：${ntpLabel}（${current}）` : `当前服务器：${current || '未读取'}。选择下方服务器可更改。`;
  syncNtpControls();
}

function syncNtpControls() {
  const syncButton = document.getElementById('ntp-sync-btn');
  syncButton.disabled = state.ntpBusy;
  syncButton.setAttribute('aria-busy', String(state.ntpBusy));
  refs.ntpSyncLabel.textContent = state.ntpBusy ? state.ntpAction === 'sync' ? '同步中…' : '切换中…' : '立即同步';
  refs.ntpServerList.querySelectorAll('button[data-server]').forEach((card) => {
    const submitting = state.ntpBusy && state.ntpAction === 'server' && card.dataset.server === state.ntpRequestedServer;
    card.disabled = state.ntpBusy;
    card.setAttribute('aria-busy', String(submitting));
    card.querySelector('.badge').textContent = submitting ? '提交中…' : card.dataset.server === state.ntpServer ? '当前使用' : '选择';
  });
}

async function refreshNtp({ readback = false } = {}) {
  try {
    const data = await apiFetch(API.ntp, { timeoutMs: NETWORK_READ_TIMEOUTS.ntp, dedupe: !readback, priority: readback ? 'interactive' : 'normal', scope: 'network.ntp.read' });
    renderNtpCard(data);
    return true;
  } catch (err) {
    if (requireFeature('core').isRequestCancelled?.(err)) return null;
    refs.ntpServerList.replaceChildren(); refs.ntpServerList.appendChild(errorBlock('时间同步设置读取失败：' + err.message));
    return false;
  }
}

async function setNtpServer(server) {
  if (state.ntpBusy || server === state.ntpServer) return;
  state.ntpBusy = true;
  state.ntpAction = 'server';
  state.ntpRequestedServer = server;
  syncNtpControls();
  refs.ntpDesc.textContent = '正在保存时间服务器…';
  try {
    const data = await apiFetch(API.ntp, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ server }),
      timeoutMs: NETWORK_WRITE_TIMEOUT_MS, priority: 'interactive', scope: 'network.ntp'
    });
    if (data.ok) {
      const label = state.ntpServers.find((s) => s.id === server)?.name || server;
      const readback = await refreshNtp({ readback: true });
      if (!readback || state.ntpServer !== server) {
        refs.ntpDesc.textContent = '服务器设置已提交，实际配置尚未确认。请刷新检查。';
        showToast(`服务器设置已提交，${label} 的实际配置未确认`);
        appendLog(`NTP 服务器设置已提交，实际配置未确认：${server}`, 'warn');
      } else if (data.refreshed === false) {
        showToast(`服务器已切换为 ${label}，立即校时未完成`);
        appendLog(`NTP 服务器已切换，立即校时未完成：${server}`, 'warn');
      } else {
        showToast(`服务器已切换为 ${label}，校时请求已接受`);
        appendLog(`NTP 服务器已切换，系统已接受校时请求：${server}`, 'ok');
      }
    } else {
      refs.ntpDesc.textContent = `服务器设置未完成：${data.error || '未提供错误详情'}`;
      showToast(`服务器切换失败：${data.error || '未提供错误详情'}`);
    }
  } catch (err) {
    if (!requireFeature('core').isRequestCancelled?.(err)) {
      const message = err?.message || String(err);
      refs.ntpDesc.textContent = `服务器设置请求未完成：${message}`;
      showToast(`服务器切换失败：${message}`);
      appendLog(`NTP 切换失败：${message}`, 'err');
    }
  } finally {
    state.ntpBusy = false;
    state.ntpAction = '';
    state.ntpRequestedServer = '';
    syncNtpControls();
  }
}

async function syncNtp() {
  if (state.ntpBusy) return;
  state.ntpBusy = true;
  state.ntpAction = 'sync';
  syncNtpControls();
  try {
    const data = await apiFetch(API.ntp, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'sync' }),
      timeoutMs: NETWORK_WRITE_TIMEOUT_MS, priority: 'interactive', scope: 'network.ntp'
    });
    if (data.ok) {
      const readback = await refreshNtp({ readback: true });
      if (!readback) {
        showToast('校时请求已提交，实际状态未确认');
        appendLog('NTP 校时请求已提交，实际状态未确认', 'warn');
      } else {
        showToast('系统已接受校时请求');
        appendLog(`校时请求已接受，设备当前时间：${data.device_time}`, 'ok');
      }
    } else {
      showToast('同步失败');
    }
  } catch (err) {
    if (!requireFeature('core').isRequestCancelled?.(err)) {
      const message = err?.message || String(err);
      showToast(`同步请求失败：${message}`);
      appendLog(`NTP 同步失败：${message}`, 'err');
    }
  } finally {
    state.ntpBusy = false;
    state.ntpAction = '';
    syncNtpControls();
  }
}

registerFeature('network', {
  async refresh() {
    if (!core().isWebUiActive()) return null;
    return requireFeature('core').runFeatureTask('network.refresh', async () => {
      const results = await Promise.all([
        refreshNrSwitch(), refreshNtp(), refreshStandbyGuard()
      ]);
      if (results.some((result) => result === false)) return false;
      return results.every((result) => result === null) ? null : true;
    });
  },
  refreshDiagnostics() {
    if (!core().isWebUiActive()) return Promise.resolve(null);
    return core().runFeatureTask('network.diagnostics', async () => {
      const results = await Promise.all([
        refreshUecap(), refreshBaseband()
      ]);
      if (results.some((result) => result === false)) return false;
      return results.every((result) => result === null) ? null : true;
    });
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
