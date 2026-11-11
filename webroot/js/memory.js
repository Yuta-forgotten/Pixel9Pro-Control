// Explicit memory controls and background application restrictions.
'use strict';
(() => {
const state = {
  swapMode: 'system', featureVm: 'system', swapData: null,
  swapBusy: false, swapLoading: false, swapRevision: 0, zramDraft: null, zramDraftBound: false,
  zramOperationId: '', zramOperationPhase: '',
  bgContract: null, bgRestrictEnabled: 'on', bgRestrictBusy: false,
  bgRestrictReadbackPending: false, bgRecoveryRequired: false, bgRestrictSuggestions: [],
  bgRevision: 0, bgAction: null, bgDrafts: new Map(),
  bgOperation: null, bgObserveUntil: 0, bgSuccessText: '', bgSubmittedId: ''
};
const core = () => requireFeature('core');
const apiFetch = (...args) => core().apiFetch(...args);
const appendLog = (...args) => core().appendLog(...args);
const buildInfoRow = (...args) => core().buildInfoRow(...args);
const computeNextPollDelay = (...args) => core().computeNextPollDelay(...args);
const errorBlock = (...args) => core().errorBlock(...args);
const escapeHtml = (...args) => core().escapeHtml(...args);
const fmtBytes = (...args) => core().fmtBytes(...args);
const queueNextPoll = (...args) => core().queueNextPoll(...args);
const showToast = (...args) => core().showToast(...args);
const pushModalState = (...args) => requireFeature('ui').pushModalState(...args);
const popModalIfTop = (...args) => requireFeature('ui').popModalIfTop(...args);
const syncHeroDesc = () => requireFeature('thermal').syncHeroDesc();
const control = (id) => document.getElementById(id);
const numeric = (v) => v !== null && v !== '' && Number.isFinite(Number(v));
const finiteNumber = (v, fallback = 0) => numeric(v) ? Number(v) : fallback;
const formatEffectiveBytes = (v) => numeric(v) && Number(v) > 0 ? fmtBytes(Number(v)) : '未读回';

function vmModeLabel(mode) { return mode === 'preset' ? '模块预设' : mode === 'custom' ? '自定义参数' : '系统参数'; }
function onlineZramPhase(operation) {
  const labels = { queued: '已排队', preflight: '复查资源与系统服务', stopping_mmd: '协调系统内存服务',
    swapoff: '交换页换回 RAM', rebuilding: '重新配置交换区', verifying: '读取实际结果',
    rollback: '恢复原交换区', success: '已应用，重启后失效', failed: '未完成', deferred: '执行条件改变，已暂缓',
    rollback_complete: '失败后已恢复原设置', rollback_incomplete: '恢复未完成，请执行恢复',
    unconfirmed: '任务中断，请执行恢复', external_changed: '实际设置已被其他工具修改', historical: '上次启动的记录' };
  return labels[operation?.phase] || '无待处理任务';
}
function onlineZramReason(data) {
  if (data?.zram_online_supported) return '可在线应用；换回页面和重建可能暂时影响响应';
  const reasons = { platform_setup_unavailable: 'API 或系统初始化接口不支持', unsupported_swap_layout: '当前交换区布局不支持在线重建',
    writeback_history_present: '本次启动已有回写历史；平台没有配额迁移接口，请保存开机设置',
    memory_pressure: '内存压力较高，暂时无法重建交换区',
    insufficient_swapoff_headroom: `换回所需余量约 ${formatEffectiveBytes(data?.zram_swapoff_required_bytes)}，可用 ${formatEffectiveBytes(data?.zram_mem_available_bytes)}` };
  return reasons[data?.zram_online_reason] || '尚未读取执行条件';
}
function memoryOperationReason(code) {
  const labels = {
    explicit_online_request: '等待执行', checking_memory_and_owner: '正在检查内存和系统服务',
    coordinating_platform_owner: '正在暂停交换区维护', draining_swap: '正在将交换页载入内存',
    platform_setup: '正在重建交换区', checking_swap_and_daemon: '正在检查交换区和系统服务',
    temporary_until_reboot: '当前配置已生效', original_parameters_applied: '原始参数已恢复',
    insufficient_swapoff_headroom: '可用内存不足，未执行重建', memory_pressure: '内存压力较高，未执行重建',
    memory_pressure_changed: '执行前内存压力发生变化，操作已停止', headroom_changed: '执行前可用内存不足，操作已停止',
    external_runtime_owner_changed: '其他工具已修改当前参数，操作已停止',
    external_persistent_request_changed: '其他工具已修改启动参数，操作已停止',
    mmd_stop_failed: '无法暂停系统内存服务', swapoff_failed: '交换区未能停用，未执行重建',
    platform_setup_failed: '系统初始化交换区失败', final_readback_failed: '实际参数与目标不一致',
    vm_preset_failed: 'VM 参数应用失败', vm_restore_failed: '原始 VM 参数恢复失败',
    original_source_read_failed: '原始配置读取失败', worker_interrupted: '配置任务意外中断',
    runtime_owner_changed: '当前参数已被其他工具修改'
  };
  return labels[code] || '';
}
function operationBusy(data = state.swapData) { return data?.zram_operation?.pending === true; }
function recoveryNeeded(data = state.swapData) { return ['unconfirmed', 'rollback_incomplete'].includes(data?.zram_operation?.phase); }

function splitZramRequest(raw) {
  const value = String(raw || '');
  if (value.endsWith('%')) return { value: value.slice(0, -1), unit: 'percent' };
  if (numeric(value) && Number(value) > 0) return { value: String(Number((Number(value) / 1000000).toFixed(2))), unit: 'mb' };
  return { value: '', unit: 'mb' };
}
function readZramDraft() {
  return { value: String(refs.swapZramSizeNumber.value).trim(), unit: refs.swapZramSizeUnit.value,
    algorithm: control('swap-zram-algorithm').value };
}
function bindZramDraft() {
  if (state.zramDraftBound) return;
  [refs.swapZramSizeNumber, refs.swapZramSizeUnit, control('swap-zram-algorithm')].forEach((el) => {
    el.addEventListener('input', () => { state.zramDraft = readZramDraft(); updateZramUnitUi(state.swapData); });
  });
  state.zramDraftBound = true;
}
function updateZramUnitUi(data) {
  const input = refs.swapZramSizeNumber;
  const limits = data?.zram_input_limits;
  if (!limits) return;
  const unit = refs.swapZramSizeUnit.value;
  const range = unit === 'percent' ? limits.percent : limits.mb;
  const multiplier = unit === 'mib' ? 1000000 / 1048576 : 1;
  input.min = String(Number(range.min) * multiplier);
  input.max = String(Number(range.max) * multiplier);
  input.step = unit === 'percent' ? '1' : '0.01';
}
function syncZramRequestControl(data = state.swapData) {
  const ready = data?.vm_policy_ready === true;
  const busy = state.swapBusy || operationBusy(data);
  refs.swapTuneButton.disabled = !ready;
  refs.swapToggleButton.disabled = !ready || busy || recoveryNeeded(data);
  refs.swapZramSizeApply.disabled = busy || !ready || data?.zram_online_supported !== true || recoveryNeeded(data);
  refs.swapZramSizeApply.textContent = busy ? '操作进行中…' : '应用交换区设置';
  refs.swapZramSizeApply.setAttribute('aria-busy', String(busy));
  control('swap-custom-apply-btn').disabled = busy || !ready || recoveryNeeded(data);
  control('memory-boot-save').disabled = state.swapBusy || !ready;
  control('memory-auto-apply').disabled = state.swapBusy || !ready;
  control('memory-restore-zram').disabled = busy || !ready || data?.zram_online_supported !== true;
  control('memory-recover').hidden = !recoveryNeeded(data);
  control('memory-recover').disabled = busy || !ready;
  control('swap-preset-optimized').disabled = !data?.stock;
  control('swap-zram-size-help').textContent = onlineZramReason(data);
  control('memory-preset-apply').disabled = busy || !ready || !data?.module_preset || data?.zram_online_supported !== true || recoveryNeeded(data);
  control('memory-preset-fill').disabled = !data?.module_preset;
}
function clampSwapValue(key, raw) {
  const limit = state.swapData?.limits?.[key];
  const value = Number(raw);
  return Math.min(limit.max, Math.max(limit.min, Number.isFinite(value) ? Math.round(value) : limit.min));
}
function updateSwapFill(key) {
  const input = refs.swapTuneInputs[key];
  const limit = state.swapData.limits[key];
  input.style.setProperty('--fill', `${Math.max(0, Math.min(100, (Number(input.value) - limit.min) * 100 / (limit.max - limit.min)))}%`);
}
function setSwapTuneValues(values) {
  if (!values) return;
  SWAP_KEYS.forEach((key) => {
    if (!numeric(values[key])) return;
    const value = clampSwapValue(key, values[key]);
    refs.swapTuneInputs[key].value = String(value);
    refs.swapTuneNumbers[key].value = String(value);
    refs.swapTuneValues[key].textContent = String(value);
    updateSwapFill(key);
  });
}
function syncSwapTuneField(key, raw) { setSwapTuneValues({ [key]: raw }); }
function getSwapTuneValues() {
  return Object.fromEntries(SWAP_KEYS.map((key) => [key, clampSwapValue(key, refs.swapTuneNumbers[key].value)]));
}
function openSwapTuneModal() {
  const data = state.swapData;
  if (!data?.limits) { showToast('请等待内存状态读回'); return; }
  setSwapTuneValues(data);
  bindZramDraft();
  const select = control('swap-zram-algorithm');
  select.replaceChildren(...(data.zram_algorithms || []).map((algorithm) => {
    const option = document.createElement('option'); option.value = algorithm; option.textContent = algorithm; return option;
  }));
  if (!state.zramDraft) state.zramDraft = { ...splitZramRequest(data.mmd_requested_size || data.zram_disksize), algorithm: data.zram_algo };
  refs.swapZramSizeNumber.value = state.zramDraft.value;
  refs.swapZramSizeUnit.value = state.zramDraft.unit;
  select.value = state.zramDraft.algorithm;
  control('memory-auto-apply').checked = data.memory_boot?.auto_apply === true;
  control('memory-boot-vm').checked = data.memory_boot?.vm_enabled === true;
  updateZramUnitUi(data); syncZramRequestControl(data);
  refs.swapTuneModal.classList.add('open'); pushModalState('swapTune');
  queueNextPoll(computeNextPollDelay());
}
function closeSwapTuneModal() {
  state.zramDraft = readZramDraft();
  refs.swapTuneModal.classList.remove('open'); popModalIfTop('swapTune'); queueNextPoll(POLL_MIN_DELAY_MS);
}
function buildSwapDetail(data) {
  if (!data) return '内存状态尚未读取';
  return `<b>立即应用与启动参数</b><br>“应用”修改当前运行参数，重启后按启动配置处理。“保存参数”仅更新启动参数，“开机自动应用”决定是否在启动时应用。<br><br><b>执行条件</b><br>${escapeHtml(onlineZramReason(data))}<br><br><b>参数含义</b><br>swappiness 表示换页与文件页回收的相对成本；min_free_kbytes 为分配保留水位；watermark_scale_factor 调节后台回收水位间距；vfs_cache_pressure 控制目录和 inode 缓存回收。合法范围不代表任意组合都有性能收益。<br><br><b>容量与页大小</b><br>逻辑容量不是等量预留 RAM；实际物理占用单独显示。内核页大小为 ${escapeHtml(String(data.zram_page_size))} bytes，不能由模块任意修改。主压缩算法遵循本机支持列表及页大小限制。<br><br><b>系统维护</b><br>Android mmd 继续管理原有回写、重压缩和进程预取。模块没有周期维护或循环写参数。`;
}
function renderSwapCard(data) {
  const boot = data.memory_boot || {};
  const op = data.zram_operation || {};
  const active = data.zram_active_state === 'active';
  const errors = [data.zram_failed_reads, data.zram_failed_writes, data.zram_invalid_io];
  const rows = [
    ['当前内存配置', vmModeLabel(data.mode)],
    ['模块预设', data.module_preset ? `${data.module_preset.size} / ${data.module_preset.algorithm} · VM ${SWAP_KEYS.map((key) => data.module_preset[key]).join(' / ')}` : '原始配置尚未读取'],
    ['VM 参数状态', data.vm_effective_state === 'drifted' ? `存在差异：${(data.vm_drift_fields || []).map((key) => ({ swappiness: '换页倾向', min_free_kbytes: '最低空闲余量', watermark_scale_factor: '回收水位间距', vfs_cache_pressure: '文件元数据回收' })[key] || key).join('、')}` : data.vm_effective_state === 'effective' ? '当前参数与应用目标一致' : '由系统管理'],
    ['系统内存服务', `${data.zram_owner || '未知'} / ${data.mmd_service || '未知'} / API ${data.android_sdk || '未知'}`],
    ['交换区状态', active ? `已启用 · ${fmtBytes(finiteNumber(data.zram_swap_size_kb) * 1024)}` : data.zram_active_state || '未知'],
    ['实际容量 / 压缩算法', `${formatEffectiveBytes(data.zram_disksize)} / ${data.zram_algo || '未知'}`],
    ['已用交换空间', fmtBytes(finiteNumber(data.zram_swap_kb) * 1024)],
    ['压缩前数据量 / 实际内存占用', `${formatEffectiveBytes(data.zram_orig_bytes)} / ${formatEffectiveBytes(data.zram_mem_used_bytes)}`],
    ['当前容量请求 / 持久覆盖', `${data.mmd_requested_size || '未设置'} / ${data.zram_platform_persistent_size || '平台默认'}`],
    ['原始容量 / 算法', `${data.original_size || '读取中'} / ${data.original_algorithm || '读取中'}`],
    ['配置任务', `${onlineZramPhase(op)}${memoryOperationReason(op.reason) ? ` · ${memoryOperationReason(op.reason)}` : ''}`],
    ['在线条件', onlineZramReason(data)],
    ['开机自动应用', `${boot.auto_apply ? '开启' : '关闭'}${boot.pending_reboot ? ' · 下一次启动更新' : ''}`],
    ['启动容量 / 压缩算法', `${boot.size || '沿用平台'} / ${boot.algorithm || '沿用平台'}`],
    ['启动 VM 参数', boot.vm_enabled ? '随开机配置应用' : '使用系统值'],
    ['页大小', formatEffectiveBytes(data.zram_page_size)],
    ['读 / 写 / 对齐错误', errors.map((v) => v == null ? '未知' : String(v)).join(' / ')]
  ];
  SWAP_KEYS.forEach((key) => rows.push([key, data[key] == null ? '未读回' : String(data[key])]));
  refs.swapRows.replaceChildren(...rows.map(([label, value]) => buildInfoRow(label, value, 'off')));
  control('memory-live-status').textContent = active ? '交换区已启用' : '状态未确认';
  control('memory-modal-status').textContent = operationBusy(data) ? '正在应用' : '已连接';
  control('memory-current-capacity').textContent = formatEffectiveBytes(data.zram_disksize);
  control('memory-current-compressor').textContent = data.zram_algo || '—';
  control('memory-current-physical').textContent = formatEffectiveBytes(data.zram_mem_used_bytes);
  control('memory-current-swap').textContent = `${fmtBytes(finiteNumber(data.zram_swap_kb) * 1024)} / ${fmtBytes(finiteNumber(data.zram_swap_size_kb) * 1024)}`;
  const preset = data.module_preset;
  control('memory-preset-summary').textContent = preset ? `${preset.size} RAM · ${preset.algorithm}\n换页倾向 ${preset.swappiness} · 最低空闲余量 ${Math.round(preset.min_free_kbytes / 1024)} MiB · 回收水位 ${preset.watermark_scale_factor}` : '正在核对本机预设';
  refs.swapDesc.textContent = `${data.zram_algo || '未知算法'} · 实际占用 ${formatEffectiveBytes(data.zram_mem_used_bytes)} · ${active ? '交换区已启用' : '交换区未确认'}`;
  control('memory-boot-summary').textContent = boot.size || boot.algorithm ? `启动参数：${boot.size || '系统容量'} · ${boot.algorithm || '系统算法'}。${boot.vm_enabled ? '包含 VM 参数。' : 'VM 使用系统值。'}${boot.auto_apply ? '已启用开机自动应用。' : '开机自动应用已关闭。'}` : '尚未保存启动参数。';
}
function acceptSwapData(data) {
  state.swapData = data; state.swapMode = data.mode; state.featureVm = data.feature_vm;

  SWAP_KEYS.forEach((key) => {
    const limit = data.limits[key];
    [refs.swapTuneInputs[key], refs.swapTuneNumbers[key]].forEach((el) => {
      el.min = String(limit.min); el.max = String(limit.max); el.step = '1';
    });
  });
  refs.swapToggleLabel.textContent = '恢复原始参数';
  renderSwapCard(data); syncZramRequestControl(data);
  const original = finiteNumber(data.zram_orig_bytes), size = finiteNumber(data.zram_disksize);
  refs.rtZramUsage.textContent = size > 0 ? `${Math.round(original * 100 / size)}%` : '—';
  if (refs.rtZramUsageDetail) refs.rtZramUsageDetail.textContent = `压缩驻留 ${fmtBytes(original)} / 逻辑容量 ${formatEffectiveBytes(size)}`;
  refs.rtRatio.textContent = original > 0 ? `${(finiteNumber(data.zram_compr_bytes) * 100 / original).toFixed(1)}% → 实占 ${formatEffectiveBytes(data.zram_mem_used_bytes)}` : '—';
  const op = data.zram_operation;
  if (op?.id === state.zramOperationId && op.phase !== state.zramOperationPhase) {
    appendLog(`ZRAM：${onlineZramPhase(op)}`, op.phase === 'success' ? 'ok' : 'dim'); state.zramOperationPhase = op.phase;
  }
  syncHeroDesc();
}

async function refreshSwap(force = false) {
  if (state.swapBusy && !force) return null;
  const revision = state.swapRevision;
  return core().runFeatureTask(`memory.swap.refresh.${revision}.${force}`, async () => {
    state.swapLoading = true;
    let data;
    try {
      data = await apiFetch(API.swap, { timeoutMs: 8000, priority: force ? 'interactive' : 'normal', dedupe: !force, scope: 'memory.read' });
    } catch (err) {
      if (core().isRequestCancelled(err) || revision !== state.swapRevision) return null;
      refs.swapDesc.textContent = `内存状态读取失败：${err.message}`;
      control('memory-live-status').textContent = state.swapData ? '显示上次状态' : '读取失败';
      refs.swapRows.replaceChildren(errorBlock(`内存读取失败：${err.message}`)); return false;
    } finally { state.swapLoading = false; }
    if (revision !== state.swapRevision) return null;
    acceptSwapData(data);
    return true;
  });
}

function friendlyPackageLabel(pkg, suppliedLabel = '') {
  const name = String(suppliedLabel || '').trim();
  const packageName = String(pkg || '').trim();
  if (name) return name;
  if (/^u\d+[ai]\d+$/.test(packageName)) return '已卸载或未知应用';
  if (packageName.includes(', ')) return '共享 UID 应用';
  if (!packageName) return '已卸载或未知应用';
  return packageName;
}

function renderBgRestrictSuggestions(suggestions, activePackages) {
  const active = new Set(activePackages.map((item) => String(item.pkg || '')));
  state.bgRestrictSuggestions = (Array.isArray(suggestions) ? suggestions : [])
    .filter((item) => item && item.pkg && !active.has(String(item.pkg)))
    .sort((a, b) => String(a.label || a.pkg).localeCompare(String(b.label || b.pkg), 'zh-CN'));
  if (!refs.bgRestrictPkgSuggestions) return;
  refs.bgRestrictPkgSuggestions.replaceChildren();
  state.bgRestrictSuggestions.forEach((item) => {
    const option = document.createElement('option');
    const caution = item.restriction_tier === 'caution' ? ' · 谨慎限制' : '';
    option.value = String(item.pkg);
    option.label = `${item.label || item.pkg}${item.category ? ` · ${item.category}` : ''}${caution}`;
    option.textContent = option.label;
    refs.bgRestrictPkgSuggestions.appendChild(option);
  });
  refs.bgRestrictPkgInput.placeholder = state.bgRestrictSuggestions.length
    ? '输入包名或选择本机常用应用'
    : 'com.example.app';
  syncBgPackageHint();
}

function syncBgPackageHint() {
  if (!refs.bgRestrictPkgHint || !refs.bgRestrictPkgInput) return;
  const pkg = String(refs.bgRestrictPkgInput.value || '').trim();
  const suggestion = state.bgRestrictSuggestions.find((item) => item.pkg === pkg);
  if (!pkg) {
    refs.bgRestrictPkgHint.textContent = '可选择已识别的应用，也可手动输入完整包名。';
    refs.bgRestrictPkgHint.className = 'bg-package-hint';
    return;
  }
  if (!suggestion) {
    refs.bgRestrictPkgHint.textContent = '未在常用目录中识别，将按当前包名添加。';
    refs.bgRestrictPkgHint.className = 'bg-package-hint';
    return;
  }
  const caution = suggestion.restriction_tier === 'caution';
  refs.bgRestrictPkgHint.textContent = caution
    ? `${suggestion.label} · ${suggestion.category || '常用应用'}；限制后可能影响通知、连接或穿戴同步。`
    : `${suggestion.label} · ${suggestion.category || '常用应用'}`;
  refs.bgRestrictPkgHint.className = `bg-package-hint${caution ? ' warn' : ''}`;
}

function normalizeBgPolicy(policy) {
  if (!state.bgContract) return '';
  return state.bgContract.policyOrder.includes(policy) ? policy : state.bgContract.defaultPolicy;
}

function normalizeBgDelay(delay) {
  if (!state.bgContract) return null;
  const value = Number(delay);
  return state.bgContract.delays.includes(value) ? value : state.bgContract.defaultDelay;
}

function parseBgContract(data) {
  const raw = data?.bg_contract;
  const policyOrder = Array.isArray(raw?.policy_order) ? raw.policy_order.filter((id) => typeof id === 'string') : [];
  const delays = Array.isArray(raw?.allowed_delays) ? raw.allowed_delays.map(Number) : [];
  const defaultPolicy = typeof raw?.default_policy === 'string' ? raw.default_policy : '';
  const defaultDelay = Number(raw?.default_delay);
  const valid = policyOrder.length > 0
    && new Set(policyOrder).size === policyOrder.length
    && policyOrder.every((id) => BG_RESTRICT_POLICY_PRESENTATION[id])
    && delays.length > 0
    && new Set(delays).size === delays.length
    && delays.every((delay) => Number.isInteger(delay) && delay > 0)
    && policyOrder.includes(defaultPolicy)
    && delays.includes(defaultDelay);
  if (!valid) {
    const error = new Error('服务返回的后台限制选项不完整，暂时无法修改');
    error.code = 'BG_CONTRACT_INVALID';
    throw error;
  }
  return { policyOrder, delays, defaultPolicy, defaultDelay };
}

function applyBgContract(contract) {
  const { policyOrder, delays, defaultPolicy, defaultDelay } = contract;
  const previousPolicy = refs.bgRestrictPolicySelect?.value;
  const previousDelay = Number(refs.bgRestrictDelaySelect?.value);
  state.bgContract = contract;

  refs.bgRestrictPolicySelect.replaceChildren();
  policyOrder.forEach((id) => {
    const option = document.createElement('option');
    option.value = id;
    option.textContent = BG_RESTRICT_POLICY_PRESENTATION[id].label;
    refs.bgRestrictPolicySelect.appendChild(option);
  });
  refs.bgRestrictPolicySelect.value = policyOrder.includes(previousPolicy) ? previousPolicy : defaultPolicy;

  refs.bgRestrictDelaySelect.replaceChildren();
  delays.forEach((delay) => {
    const option = document.createElement('option');
    option.value = String(delay);
    option.textContent = `${delay}分钟`;
    refs.bgRestrictDelaySelect.appendChild(option);
  });
  refs.bgRestrictDelaySelect.value = delays.includes(previousDelay) ? String(previousDelay) : String(defaultDelay);
}

function createBgPolicySelect(value) {
  const select = document.createElement('select');
  select.className = 'bg-policy-select';
  state.bgContract.policyOrder.forEach((id) => {
    const opt = document.createElement('option');
    opt.value = id;
    opt.textContent = BG_RESTRICT_POLICY_PRESENTATION[id].label;
    opt.selected = id === value;
    select.appendChild(opt);
  });
  return select;
}

function createBgDelaySelect(value) {
  const select = document.createElement('select');
  select.className = 'bg-delay-select';
  state.bgContract.delays.forEach((min) => {
    const opt = document.createElement('option');
    opt.value = String(min);
    opt.textContent = `${min}分钟`;
    opt.selected = min === value;
    select.appendChild(opt);
  });
  return select;
}

function syncBgDelayControl(policySelect, delaySelect) {
  delaySelect.disabled = policySelect.value !== 'stop_after_leave';
}

function syncBgRestrictControls() {
  const busy = state.bgRestrictBusy || state.bgRestrictReadbackPending || state.bgRecoveryRequired || !state.bgContract;
  if (refs.bgRestrictToggleBtn) refs.bgRestrictToggleBtn.disabled = busy;
  if (refs.bgRestrictAddBtn) refs.bgRestrictAddBtn.disabled = busy;
  if (refs.bgRestrictPkgInput) refs.bgRestrictPkgInput.disabled = !state.bgContract;
  if (refs.bgRestrictPolicySelect) refs.bgRestrictPolicySelect.disabled = !state.bgContract;
  if (refs.bgRestrictDelaySelect) syncBgDelayControl(refs.bgRestrictPolicySelect, refs.bgRestrictDelaySelect);
  if (refs.bgRestrictRefreshBtn) refs.bgRestrictRefreshBtn.disabled = state.bgRestrictBusy;
  document.querySelectorAll('#bg-restrict-rows .bg-policy-row').forEach((row) => {
    const policySelect = row.querySelector('.bg-policy-select');
    const delaySelect = row.querySelector('.bg-delay-select');
    const saveBtn = row.querySelector('.bg-policy-save');
    const removeBtn = row.querySelector('.bg-policy-remove');
    if (policySelect) policySelect.disabled = false;
    if (delaySelect) syncBgDelayControl(policySelect, delaySelect);
    const saving = state.bgRestrictBusy && state.bgAction.package === row.dataset.package;
    const dirty = state.bgDrafts.has(row.dataset.package);
    if (saveBtn) {
      saveBtn.disabled = busy || !dirty;
      saveBtn.textContent = saving && state.bgAction.action === 'update' ? '保存中…' : dirty ? '保存修改' : '已保存';
    }
    if (removeBtn) {
      removeBtn.disabled = busy;
      removeBtn.textContent = saving && state.bgAction.action === 'remove' ? '移除中…' : '移除';
    }
  });
  refs.bgRestrictAddBtn.textContent = state.bgRestrictBusy && state.bgAction.action === 'add' ? '添加中…' : '添加应用';
  refs.bgRestrictToggleLabel.textContent = state.bgRestrictBusy && state.bgAction.action === 'toggle'
    ? '切换中…' : state.bgRestrictReadbackPending ? '等待确认'
      : !state.bgContract ? '读取中…' : state.bgRestrictEnabled === 'on' ? '关闭' : '开启';
}

function bgRestrictStatus(pkg, bucket, opBg, opAny, policy, enabled, runtime = {}) {
  if (!enabled) return { text: '已关闭', cls: 'off' };
  const bucketText = String(bucket || '').toLowerCase();
  const bgMode = String(opBg || '').toLowerCase();
  const anyMode = String(opAny || '').toLowerCase();
  const stopState = String(runtime.stopState || '');
  if (stopState === 'failed') return { text: '停止未确认', cls: 'warn' };
  const rareOrLower = bucketText === '40' || bucketText === 'rare' || bucketText === '45' || bucketText === 'restricted';
  const restricted = bucketText === '45' || bucketText === 'restricted';
  const bgIgnored = bgMode === 'ignore';
  const anyIgnored = anyMode === 'ignore';
  switch (policy) {
    case 'bucket':
      return rareOrLower ? { text: '已降优先级', cls: 'good' } : { text: '尚未生效，请刷新状态', cls: 'err' };
    case 'block_services':
      if (restricted && bgIgnored) return { text: '已禁后台服务', cls: 'good' };
      if (restricted || bgIgnored) return { text: '部分生效', cls: 'warn' };
      return { text: '尚未生效，请刷新状态', cls: 'err' };
    case 'stop_after_leave':
      if (stopState === 'force_stopped') {
        return restricted && bgIgnored && anyIgnored
          ? { text: '已休眠', cls: 'good' }
          : { text: '已休眠，设置有变化', cls: 'warn' };
      }
      if (stopState === 'pending') {
        return rareOrLower && bgIgnored && anyIgnored
          ? { text: '等待休眠', cls: 'good' }
          : { text: '等待中，部分生效', cls: 'warn' };
      }
      if (stopState === 'relaunched') return { text: '已重新启动', cls: 'warn' };
      if (restricted && bgIgnored && anyIgnored) return { text: '限制已生效，待触发', cls: 'good' };
      if (rareOrLower && bgIgnored && anyIgnored) return { text: '后台限制已生效', cls: 'warn' };
      if (restricted || bgIgnored || anyIgnored) return { text: '部分生效', cls: 'warn' };
      return { text: '尚未生效，请刷新状态', cls: 'err' };
    case 'block_all':
    default:
      if (restricted && bgIgnored && anyIgnored) return { text: '后台活动已限制', cls: 'good' };
      if (restricted || bgIgnored || anyIgnored) return { text: '部分生效', cls: 'warn' };
      return { text: '尚未生效，请刷新状态', cls: 'err' };
  }
}

function renderBgRestrict(data, contract) {
  applyBgContract(contract);
  state.bgRestrictReadbackPending = false;
  state.bgRecoveryRequired = data.recovery_required === true;
  state.bgRestrictEnabled = data.enabled === 'on' ? 'on' : 'off';
  const on = state.bgRestrictEnabled === 'on';
  refs.bgRestrictToggleLabel.textContent = on ? '关闭' : '开启';
  refs.bgRestrictDesc.textContent = on
    ? '已开启：应用离开前台后，将按所选策略限制后台活动。'
    : '后台限制已关闭，应用原有设置已恢复。';
    if (state.bgRecoveryRequired) refs.bgRestrictDesc.textContent = '上次修改未完成。选择“恢复原设置”可撤销该次修改。';
  if (refs.bgRestrictRefreshBtn) refs.bgRestrictRefreshBtn.textContent = state.bgRecoveryRequired ? '恢复原设置' : '刷新';
  const packages = data.packages;
  renderBgRestrictSuggestions(data.suggestions, packages);
  if (packages.length === 0) {
    refs.bgRestrictRows.replaceChildren(buildInfoRow('应用列表', '尚未添加应用', 'off'));
    syncBgRestrictControls();
    return;
  }
  const existingRows = new Map([...refs.bgRestrictRows.children].map((row) => [row.dataset.package, row]));
  const rows = packages.map((p) => {
    const policy = normalizeBgPolicy(p.policy);
    const delay = normalizeBgDelay(p.delay);
    const existing = existingRows.get(p.pkg);
    if (existing) {
      existing.dataset.confirmedPolicy = policy;
      existing.dataset.confirmedDelay = String(delay);
    }
    const meta = BG_RESTRICT_POLICY_PRESENTATION[policy];
    const opBg = p.op_bg || '';
    const opAny = p.op_any || p.appops || '';
    const stopState = String(p.stop_state || '');
    const st = bgRestrictStatus(p.pkg, p.bucket, opBg, opAny, policy, on, { stopState });
    if (on) {
      if (p.runtime_freshness === 'last_verified') {
        st.text = `上次确认：${st.text}`;
        st.cls = st.cls === 'err' ? 'warn' : 'off';
      } else { st.text = '配置已保存，实际状态尚未确认'; st.cls = 'warn'; }
    }
    const displayName = friendlyPackageLabel(p.pkg, p.label);
    const stopStateText = {
      pending: '等待设定延时结束',
      force_stopped: '进程已停止',
      last_verified_stopped: '上次已确认停止，当前状态未读取',
      failed: '停止未确认，回到前台后才重新计时',
      relaunched: '系统已重新启动应用',
      untracked: '首次离开前台后开始计时'
    }[stopState] || '';
    const packagePrefix = displayName !== p.pkg ? `${p.pkg} · ` : '';
    const detailText = policy === 'stop_after_leave'
      ? `${packagePrefix}${meta.label} · ${delay}分钟${stopStateText ? ` · ${stopStateText}` : ''}`
      : `${packagePrefix}${meta.label}`;
    if (existing && (state.bgDrafts.has(p.pkg)
      || (existing.contains(document.activeElement) && document.activeElement.matches('select, input')))) {
      existing.querySelector('.bg-policy-title').textContent = displayName;
      existing.querySelector('.bg-policy-detail').textContent = detailText;
      const badge = existing.querySelector('.badge');
      badge.textContent = st.text;
      badge.className = `badge ${st.cls}`;
      return existing;
    }
    const row = document.createElement('div');
    row.className = 'data-row bg-policy-row';
    row.dataset.package = p.pkg;
    row.dataset.confirmedPolicy = policy;
    row.dataset.confirmedDelay = String(delay);
    const main = document.createElement('div');
    main.className = 'bg-policy-main';
    const title = document.createElement('div');
    title.className = 'bg-policy-title';
    title.textContent = displayName;
    const detail = document.createElement('div');
    detail.className = 'bg-policy-detail';
    detail.textContent = detailText;
    main.appendChild(title);
    main.appendChild(detail);

    const badge = document.createElement('span');
    badge.className = `badge ${st.cls}`;
    badge.textContent = st.text;
    const statusWrap = document.createElement('div');
    statusWrap.className = 'bg-policy-status';
    statusWrap.appendChild(badge);

    const controls = document.createElement('div');
    controls.className = 'bg-policy-controls';
    const draft = state.bgDrafts.get(p.pkg);
    const policySelect = createBgPolicySelect(draft ? draft.policy : policy);
    const delaySelect = createBgDelaySelect(draft ? draft.delay : delay);
    const rememberDraft = () => {
      const next = { policy: policySelect.value, delay: Number(delaySelect.value) };
      if (!state.bgRestrictBusy && !state.bgRestrictReadbackPending && next.policy === row.dataset.confirmedPolicy
        && next.delay === Number(row.dataset.confirmedDelay)) state.bgDrafts.delete(p.pkg);
      else state.bgDrafts.set(p.pkg, next);
      syncBgRestrictControls();
    };
    policySelect.addEventListener('change', rememberDraft);
    delaySelect.addEventListener('change', rememberDraft);
    const saveBtn = document.createElement('button');
    saveBtn.className = 'tiny-btn primary bg-policy-save';
    saveBtn.type = 'button';
    saveBtn.textContent = '保存修改';
    saveBtn.addEventListener('click', () => bgRestrictUpdate(p.pkg, policySelect.value, delaySelect.value));
    const rmBtn = document.createElement('button');
    rmBtn.className = 'tiny-btn bg-policy-remove';
    rmBtn.type = 'button';
    rmBtn.textContent = '移除';
    rmBtn.addEventListener('click', () => bgRestrictRemove(p.pkg));
    const policyField = document.createElement('label');
    policyField.className = 'bg-field';
    const policyLabel = document.createElement('span'); policyLabel.textContent = '限制方式';
    policyField.append(policyLabel, policySelect);
    const delayField = document.createElement('label');
    delayField.className = 'bg-field';
    const delayLabel = document.createElement('span'); delayLabel.textContent = '离开前台后';
    delayField.append(delayLabel, delaySelect);
    const actions = document.createElement('div'); actions.className = 'bg-row-actions';
    actions.append(saveBtn, rmBtn);
    controls.appendChild(policyField);
    controls.appendChild(delayField);
    controls.appendChild(actions);

    row.appendChild(main);
    row.appendChild(statusWrap);
    row.appendChild(controls);
    return row;
  });
  [...refs.bgRestrictRows.children].filter((row) => !rows.includes(row)).forEach((row) => row.remove());
  rows.forEach((row, index) => {
    if (refs.bgRestrictRows.children[index] !== row) refs.bgRestrictRows.insertBefore(row, refs.bgRestrictRows.children[index] || null);
  });
  syncBgRestrictControls();
}

function showBgReadbackPending(detail = '') {
  const message = `后台限制请求结果未确认${detail ? `：${detail}。请刷新检查，勿重复提交。` : '，正在读取当前状态…'}`;
  state.bgRestrictReadbackPending = true;
  refs.bgRestrictToggleLabel.textContent = '等待确认';
  refs.bgRestrictDesc.textContent = message;
  syncBgRestrictControls();
}

function showBgOperation(operation) {
  if (state.bgOperation?.id !== operation.id && operation.pending) state.bgObserveUntil = Date.now() + 120000;
  state.bgOperation = operation;
  state.bgRestrictReadbackPending = true;
  state.bgRecoveryRequired = operation.phase === 'unconfirmed' || operation.rollback === 'incomplete';
  refs.bgRestrictRefreshBtn.textContent = state.bgRecoveryRequired ? '恢复原设置' : '刷新';
  refs.bgRestrictDesc.textContent = operation.pending
    ? `后台限制${operation.phase === 'queued' ? '正在等待执行' : '正在后台执行'}。可继续编辑，执行结束后再提交。`
    : `后台限制任务未完成：${operation.error}。请选择“恢复原设置”。`;
  syncBgRestrictControls();
}

function shouldObserveRestrictions() {
  if (!state.bgOperation?.pending || !core().isWebUiActive()) return false;
  if (Date.now() < state.bgObserveUntil) return true;
  refs.bgRestrictDesc.textContent = '后台限制仍在处理或结果尚未确认，自动观察已暂停。请刷新查看进度，不会重复提交。';
  return false;
}

async function refreshBgRestrict({ readback = false } = {}) {
  if (state.bgRestrictBusy && !readback) return null;
  const revision = state.bgRevision;
  return core().runFeatureTask(`memory.bgRestrict.${revision}.${readback}`, async () => {
    let data;
    let contract;
    try {
      data = await apiFetch(API.bgRestrict, { timeoutMs: 8000, dedupe: !readback,
        priority: readback ? 'interactive' : 'normal', scope: readback ? 'memory.bgRestrict.readback' : 'memory.bgRestrict.read' });
      if (data?.ok === false) throw new Error(data.error || '后台限制状态读取失败');
      if (!data.operation || typeof data.operation.pending !== 'boolean') throw new Error('后台限制状态缺少有效的任务回执');
      if (!data.state_pending) {
        if (!Array.isArray(data.packages)) {
          const error = new Error('后台限制状态缺少有效的应用列表，请刷新重试');
          error.code = 'BG_PACKAGES_INVALID';
          throw error;
        }
        contract = parseBgContract(data);
      }
    } catch (err) {
      if (core().isRequestCancelled(err) || revision !== state.bgRevision) return null;
      if (err.code === 'BG_CONTRACT_INVALID') state.bgContract = null;
      if (err.code === 'BG_PACKAGES_INVALID') state.bgRestrictReadbackPending = true;
      if (state.bgRestrictReadbackPending) {
        showBgReadbackPending(err.message);
        return false;
      }
      syncBgRestrictControls();
      refs.bgRestrictDesc.textContent = `后台限制状态读取失败：${err.message}。请刷新重试。`;
      if (!state.bgContract) refs.bgRestrictRows.replaceChildren(errorBlock(refs.bgRestrictDesc.textContent));
      return false;
    }
    if (revision !== state.bgRevision) return null;
    if (data.state_pending) {
      showBgOperation(data.operation);
      return true;
    }
    const completed = state.bgOperation?.id === data.operation.id && state.bgOperation.pending;
    state.bgOperation = data.operation;
    state.bgObserveUntil = 0;
    const submitted = data.operation.id === state.bgSubmittedId;
    if (completed && data.operation.phase === 'success' && submitted) {
      const draft = state.bgDrafts.get(state.bgAction.package);
      if (state.bgAction.action === 'remove' || (draft && draft.policy === state.bgAction.policy && draft.delay === state.bgAction.delay)) {
        state.bgDrafts.delete(state.bgAction.package);
      }
      if (state.bgAction.action === 'add' && refs.bgRestrictPkgInput.value.trim() === state.bgAction.package) {
        refs.bgRestrictPkgInput.value = '';
      }
    }
    renderBgRestrict(data, contract);
    if (data.operation.phase === 'failed') {
      refs.bgRestrictDesc.textContent = `后台限制操作未完成：${data.operation.error}。${data.operation.rollback === 'complete' ? '已恢复操作前的设置。' : '请查看恢复状态。'}`;
      if (completed) showToast(refs.bgRestrictDesc.textContent);
    } else if (completed && data.operation.phase === 'success') {
      showToast(submitted ? state.bgSuccessText : '后台限制操作已完成');
    }
    return true;
  });
}

async function forceRefreshBgRestrict() {
  if (state.bgRecoveryRequired) return bgRestrictAction({ action: 'recover' }, '已恢复请求前的后台策略');
  if (state.bgOperation?.pending) state.bgObserveUntil = Date.now() + 120000;
  return refreshBgRestrict({ readback: true });
}

async function bgRestrictAction(body, successText) {
  if (state.bgRecoveryRequired && body.action !== 'recover') return false;
  if (state.bgRestrictBusy || (state.bgRestrictReadbackPending && body.action !== 'recover')) return false;
  state.bgRestrictBusy = true;
  state.bgRevision += 1;
  state.bgAction = body;
  syncBgRestrictControls();
  try {
    const data = await apiFetch(API.bgRestrict, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      timeoutMs: 10000, priority: 'interactive', scope: 'memory.bgRestrict'
    });
    if (data.ok !== true || data.accepted !== true || data.final !== false) throw new Error('后台限制请求未返回有效的任务回执');
    if (!data.operation || typeof data.operation.pending !== 'boolean') throw new Error('后台限制请求缺少有效的任务回执');
    state.bgSubmittedId = data.operation.id;
    state.bgSuccessText = successText;
    showBgOperation(data.operation);
    showToast('后台限制操作已开始，正在后台处理');
    queueNextPoll(2000);
    void refreshBgRestrict({ readback: true });
    return true;
  } catch (e) {
    const unknown = !e.status && !['REQUEST_QUEUE_TIMEOUT', 'REQUEST_QUEUE_FULL', 'AUTH_REQUIRED', 'NATIVE_BUSY'].includes(e.code);
    if (unknown) showBgReadbackPending(e.message);
    showToast(`${unknown ? '请求结果未确认，请刷新检查' : '请求未完成'}：${e.message}`);
    return false;
  } finally {
    state.bgRestrictBusy = false;
    syncBgRestrictControls();
  }
}

async function toggleBgRestrict() {
  const next = state.bgRestrictEnabled === 'on' ? 'off' : 'on';
  await bgRestrictAction({ action: 'toggle' }, next === 'on' ? '后台限制已开启' : '后台限制已关闭');
}

async function bgRestrictAdd() {
  if (!state.bgContract) return;
  const pkg = (refs.bgRestrictPkgInput.value || '').trim();
  if (!pkg || !/^[a-zA-Z][a-zA-Z0-9._]*$/.test(pkg)) {
    showToast('请输入有效的包名 (如 com.example.app)');
    return;
  }
  const policy = normalizeBgPolicy(refs.bgRestrictPolicySelect.value);
  const delay = normalizeBgDelay(refs.bgRestrictDelaySelect.value);
  const suggestion = state.bgRestrictSuggestions.find((item) => item.pkg === pkg);
  return bgRestrictAction(
    { action: 'add', package: pkg, policy, delay },
    `已添加 ${friendlyPackageLabel(pkg, suggestion?.label)}`
  );
}

async function bgRestrictUpdate(pkg, policy, delay) {
  if (!state.bgContract) return;
  await bgRestrictAction(
    { action: 'update', package: pkg, policy: normalizeBgPolicy(policy), delay: normalizeBgDelay(delay) },
    `已更新 ${pkg}`
  );
}

async function bgRestrictRemove(pkg) {
  await bgRestrictAction({ action: 'remove', package: pkg }, `已移除 ${pkg}`);
}

async function memoryMutation(payload, success) {
  if (state.swapBusy) return null;
  state.swapRevision += 1;
  state.swapBusy = true; syncZramRequestControl();
  showToast('正在提交内存设置…');
  try {
    const result = await apiFetch(API.swap, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload), timeoutMs: 10000, priority: 'interactive', scope: 'memory.swap' });
    if (result?.ok !== true) throw new Error(result?.error || '实际结果未确认');
    if (result.operation_id) { state.zramOperationId = result.operation_id; state.zramOperationPhase = 'queued'; }
    if (result.state) acceptSwapData(result.state);
    else {
      if (result.operation_id && state.swapData) {
        state.swapData.zram_operation = { id: result.operation_id, phase: 'queued', pending: true };
        renderSwapCard(state.swapData);
      }
      refreshSwap(true);
    }
    showToast(success); appendLog(success, result.operation_id ? 'dim' : 'ok'); return result;
  } catch (err) {
    showToast(`内存操作失败：${err.message || '未知错误'}`); appendLog(`内存操作失败：${err.message}`, 'err'); return null;
  } finally { state.swapBusy = false; syncZramRequestControl(); }
}
async function toggleSwapMode() { await memoryMutation({ mode: 'restore_system' }, '正在恢复原始参数'); }
async function applyModulePreset() { await memoryMutation({ mode: 'preset' }, '正在应用模块预设'); }
function fillModulePreset() {
  const preset = state.swapData?.module_preset;
  if (!preset) return;
  setSwapTuneValues(preset);
  state.zramDraft = { ...splitZramRequest(preset.size), algorithm: preset.algorithm };
  refs.swapZramSizeNumber.value = state.zramDraft.value;
  refs.swapZramSizeUnit.value = state.zramDraft.unit;
  control('swap-zram-algorithm').value = preset.algorithm;
  updateZramUnitUi(state.swapData);
}
async function applySwapCustom() {
  const values = getSwapTuneValues();
  const result = await memoryMutation({ mode: 'custom', ...values }, 'VM 参数已应用');
  if (result && !SWAP_KEYS.every((key) => Number(state.swapData[key]) === values[key])) showToast('参数已提交，但实际值随后发生变化，请查看差异');
}
function capacityPayload() {
  const draft = readZramDraft();
  const value = Number(draft.value);
  if (!/^[0-9]+(?:\.[0-9]{1,2})?$/.test(draft.value) || !Number.isFinite(value)) throw new Error('容量格式无效，最多两位小数');
  if (draft.unit === 'percent' && !Number.isInteger(value)) throw new Error('百分比必须是整数');
  state.zramDraft = draft;
  return { capacity: draft.value, unit: draft.unit, algorithm: draft.algorithm };
}
async function applyZramSizeRequest() {
  try {
    await memoryMutation({ mode: 'zram_online', ...capacityPayload() }, '正在应用交换区设置，可在运行详情查看进度');
  } catch (err) { showToast(err.message); }
}
async function saveMemoryBoot() {
  try {
    await memoryMutation({ mode: 'boot_save', ...capacityPayload(), vm_enabled: control('memory-boot-vm').checked ? 'on' : 'off',
      ...getSwapTuneValues() }, '启动参数已保存');
  } catch (err) { showToast(err.message); }
}
async function toggleMemoryAuto() {
  const next = control('memory-auto-apply').checked;
  const result = await memoryMutation({ mode: 'boot_save', auto_apply: next ? 'on' : 'off' },
    next ? '开机自动应用已开启，下次启动生效' : '开机自动应用已关闭，当前参数保持不变');
  if (!result) control('memory-auto-apply').checked = !next;
}
async function restoreZram() { await memoryMutation({ mode: 'zram_restore' }, '正在恢复原始交换区'); }
async function recoverMemory() { await memoryMutation({ mode: 'recover' }, '恢复任务已提交'); }

registerFeature('memory', {
  refresh: refreshSwap, refreshRestrictions: refreshBgRestrict,
  shouldObserveRestrictions,
  isRefreshing: () => state.swapLoading,
  getSwapMode: () => state.featureVm, getSwapData: () => state.swapData,
  friendlyPackageLabel, buildSwapDetail, openSwapTuneModal, closeSwapTuneModal,
  applySwapCustom, applyZramSizeRequest, saveMemoryBoot, toggleMemoryAuto, restoreZram, recoverMemory,
  applyModulePreset, fillModulePreset,
  setSwapTuneValues, syncSwapTuneField, toggleSwapMode, toggleBgRestrict, bgRestrictAdd,
  syncBgPackageHint, syncBgRestrictControls, forceRefreshBgRestrict
});
})();
