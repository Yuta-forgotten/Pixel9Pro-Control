// ZRAM、VM 参数与后台应用限制功能。
'use strict';
(() => {
const state = {
  swapMode: 'unknown',
  featureVm: 'system',
  swapData: null,
  swapBusy: false,
  swapLoading: false,
  zramDraft: null,
  zramDraftBound: false,
  bgContract: null,
  bgRestrictEnabled: 'on',
  bgRestrictBusy: false,
  bgRestrictSuggestions: []
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

function describeSwappiness(v) {
  if (v <= 20) return '低换页倾向；匿名页优先留在物理内存。';
  if (v <= 60) return '保守换页；仅在内存压力上升时使用 ZRAM。';
  if (v <= 110) return '平衡换页；兼顾前台响应与后台驻留。';
  if (v <= 160) return '积极换页；优先保留文件缓存，增加匿名页进入 ZRAM 的机会。';
  return '高换页倾向；后台驻留优先，页面换入频率可能增加。';
}
function describeMinFree(kb) {
  if (kb <= 32768) return '低空闲内存阈值；可用内存较多，但突发分配更易触发 direct reclaim。';
  if (kb <= 65536) return '偏低阈值；回收启动较晚，可用内存较多。';
  if (kb <= 131072) return '中高阈值；提前唤醒 kswapd，降低 direct reclaim 概率。';
  if (kb <= 196608) return '高阈值；更早启动回收，代价是预留内存增加。';
  return '极高阈值；优先保证分配余量，实际可用内存减少。';
}
function describeWatermark(v) {
  if (v <= 60) return '小水位间距；回收较晚，内存利用率较高。';
  if (v <= 150) return '中等水位间距；回收节奏居中。';
  if (v <= 300) return '大水位间距；提前启动回收，降低突发内存压力。';
  return '极大水位间距；回收更积极，可能增加后台 CPU。';
}
function describeVfs(v) {
  if (v <= 50) return '低回收倾向；保留 inode/dentry 缓存，减少路径查询开销。';
  if (v <= 80) return '偏低回收倾向；优先保留文件元数据缓存。';
  if (v <= 120) return '中等回收倾向；缓存占用与回收开销平衡。';
  if (v <= 160) return '偏高回收倾向；降低缓存占用，增加路径重建开销。';
  return '高回收倾向；优先释放 inode/dentry 缓存。';
}
function swapModeIntro(mode) {
  if (mode === 'optimized') return '<b>策略：模块优化</b><br>写入模块候选 VM 参数；ZRAM 容量独立提交。active swap 存在时仅支持待重启生效。';
  if (mode === 'system') return '<b>策略：系统观察</b><br>仅读取平台 VM/ZRAM 状态，不写入 sysctl、mmd 属性或容量请求。';
  if (mode === 'disabled') return '<b>策略：模块写入关闭</b><br>停止模块 VM/ZRAM 写入，仅保留状态读取。';
  if (mode === 'stock') return '<b>策略：系统观察</b><br>旧 stock 状态已映射为 system，不提交模块容量请求。';
  return '<b>策略：自定义</b><br>写入手动指定的四项 VM 参数；ZRAM 容量独立管理。';
}

function finiteNumber(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function formatEffectiveBytes(value) {
  const bytes = finiteNumber(value);
  return bytes > 0 ? fmtBytes(bytes) : '未读回';
}

function vmModeLabel(mode) {
  switch (mode) {
    case 'optimized': return 'optimized（模块 VM）';
    case 'custom': return 'custom（模块 VM）';
    case 'disabled': return 'disabled（只读观察）';
    case 'stock': return 'system（兼容旧 stock，只读观察）';
    case 'system': return 'system（只读观察）';
    default: return 'unknown（未读回）';
  }
}

function activeSwapState(data) {
  const swapKb = finiteNumber(data?.zram_swap_kb);
  const totalKb = finiteNumber(data?.swap_total_kb);
  const activeState = data?.zram_active_state || (data?.zram_active === true ? 'active' : 'unknown');
  // Presence of zram0 in /proc/swaps is authoritative; unknown must not be
  // presented as inactive because that could authorize an online setup.
  const active = activeState === 'active';
  if (activeState === 'unknown') return { active: false, text: 'active swap 状态未读回', used: fmtBytes(swapKb * 1024) };
  if (!active) return { active: false, text: '未接入 active swap', used: fmtBytes(swapKb * 1024) };
  const totalText = totalKb > 0 ? ` / ${fmtBytes(totalKb * 1024)}` : '';
  return {
    active: true,
    text: `已接入 active swap（logical used ${fmtBytes(swapKb * 1024)}${totalText}）`,
    used: fmtBytes(swapKb * 1024)
  };
}

function zramRequestState(data) {
  const featureVm = data?.feature_vm || data?.mode || 'system';
  const supported = featureVm === 'optimized' && data?.zram_target_supported === true;
  const requested = String(data?.zram_size_requested || '').trim();
  const targetBytes = finiteNumber(data?.zram_target_current_bytes);
  if (!supported) {
    return { supported: false, requested: '未设置（模块不写）', targetBytes, pending: false };
  }
  if (!requested) {
    return { supported: true, requested: '未设置', targetBytes, pending: false };
  }
  const pending = data?.zram_reboot_required === true || data?.zram_restore_pending === true;
  return { supported: true, requested, targetBytes, pending };
}

function zramTransactionPending(data) {
  const phase = String(data?.zram_transaction_phase || 'none');
  const reason = String(data?.zram_pending_reason || 'none');
  return reason === 'transaction_active'
    || reason === 'journal_degraded'
    || ['staged', 'requested', 'degraded', 'orphaned'].includes(phase)
    || (data?.zram_reconcile === 'active' && ['requested', 'effective', 'staged'].includes(phase));
}

function zramReadbackKnown(data) {
  return Boolean(data)
    && data.vm_policy_ready === true
    && data.zram_active_state !== 'unknown'
    && Number.isFinite(Number(data.zram_disksize))
    && Number(data.zram_disksize) > 0;
}

function vmReadbackKnown(data) {
  return Boolean(data)
    && data.vm_policy_ready === true
    && Number.isFinite(Number(data.swappiness))
    && Number.isFinite(Number(data.min_free_kbytes)) && Number(data.min_free_kbytes) > 0
    && Number.isFinite(Number(data.watermark_scale_factor)) && Number(data.watermark_scale_factor) > 0
    && Number.isFinite(Number(data.vfs_cache_pressure)) && Number(data.vfs_cache_pressure) > 0;
}

function splitZramRequest(raw) {
  const value = String(raw || '').trim();
  if (!value) return null;
  if (value.endsWith('%')) {
    const percent = Number(value.slice(0, -1));
    return Number.isFinite(percent) ? { value: String(percent), unit: 'percent' } : null;
  }
  const bytes = Number(value);
  if (!Number.isFinite(bytes) || bytes <= 0) return null;
  return { value: String(Math.round((bytes / 1000000) * 100) / 100), unit: 'mb' };
}

function readZramDraft() {
  const input = refs.swapZramSizeNumber;
  const unit = refs.swapZramSizeUnit?.value === 'percent' ? 'percent' : 'mb';
  const value = String(input?.value || '').trim();
  if (!value) return null;
  return { value, unit };
}

function writeZramDraft(draft) {
  if (!refs.swapZramSizeNumber || !refs.swapZramSizeUnit || !draft) return;
  refs.swapZramSizeNumber.value = String(draft.value ?? '');
  refs.swapZramSizeUnit.value = draft.unit === 'percent' ? 'percent' : 'mb';
}

function bindZramDraft() {
  if (state.zramDraftBound || !refs.swapZramSizeNumber || !refs.swapZramSizeUnit) return;
  const sync = () => { state.zramDraft = readZramDraft(); };
  refs.swapZramSizeNumber.addEventListener('input', sync);
  refs.swapZramSizeUnit.addEventListener('change', sync);
  state.zramDraftBound = true;
}

function zramDraftToBackendValue(draft) {
  if (!draft) return '';
  if (draft.unit === 'percent') return `${draft.value}%`;
  const mb = Number(draft.value);
  if (!Number.isFinite(mb)) return '';
  return String(Math.round(mb * 1000000 / 4096) * 4096);
}

function updateZramUnitUi(data) {
  const input = refs.swapZramSizeNumber;
  const unit = refs.swapZramSizeUnit;
  if (!input || !unit) return;
  const selected = unit.value === 'percent' ? 'percent' : 'mb';
  if (selected === 'percent') {
    input.min = '10'; input.max = '100'; input.step = '1';
    input.placeholder = '10–100';
  } else {
    const limits = data?.zram_input_limits?.mb || { min: 1024, max: 16384, step: 1 };
    input.min = String(limits.min);
    input.max = String(limits.max);
    input.step = String(limits.step);
    input.placeholder = 'MB';
  }
}

function syncZramRequestControl(data = state.swapData) {
  const button = refs.swapZramSizeApply;
  if (!button) return;
  const policyReady = data?.vm_policy_ready !== false;
  const allowed = policyReady && data?.feature_vm === 'optimized' && data?.zram_target_supported === true;
  const pending = zramTransactionPending(data);
  const busy = state.swapBusy;
  button.disabled = busy || !allowed || pending;
  button.setAttribute('aria-busy', String(busy));
  button.textContent = busy ? '应用中…' : '应用请求';
  button.title = pending ? '已有容量事务待处理，请先重启或等待 backend reconcile' : '';
}

function buildSwapDetail(data) {
  if (!data) return '尚未读取到 ZRAM / VM 状态，请稍后刷新。';
  const d = data;
  const target = d.zram_target || {};
  const isEH = Boolean(d.zram_algo && target.algorithm && d.zram_algo === target.algorithm);
  const vmMode = d.mode || d.feature_vm || 'unknown';
  const disksize = finiteNumber(d.zram_disksize);
  const memUsedBytes = finiteNumber(d.zram_mem_used_bytes);
  const totalRam = finiteNumber(d.stock_zram_size) * 2;
  const ramPct = totalRam > 0 && disksize > 0 ? ` (约 ${Math.round((disksize / totalRam) * 100)}% RAM)` : '';
  const wsf = finiteNumber(d.watermark_scale_factor);
  const currentAlgorithm = escapeHtml(d.zram_algo || 'unknown');
  const targetAlgorithm = escapeHtml(target.algorithm || 'unknown');
  const owner = escapeHtml(d.zram_owner || 'unknown');
  const swap = activeSwapState(d);
  const request = zramRequestState(d);
  const algoBlock = isEH
    ? `<b>ZRAM 算法：${targetAlgorithm}（Emerald Hill 硬件加速）</b><br>由平台硬件压缩引擎提供。`
    : `<b>ZRAM 算法：${currentAlgorithm}</b><br>由平台决定；system 策略不强制修改。`;
  const targetSize = request.targetBytes > 0 ? `，约 ${fmtBytes(request.targetBytes)}` : '';
  const requestBlock = request.supported
    ? `模块容量请求：${escapeHtml(request.requested)}${targetSize}（${request.pending ? '待重启，当前有效容量未对齐' : zramReadbackKnown(d) ? '当前有效容量已读回' : '有效容量未知'}）`
    : '模块容量请求：未设置（system/disabled 仅观察平台状态）';
  const sizeBlock = `<b>当前有效容量（effective disksize）：${formatEffectiveBytes(disksize)}${ramPct}</b><br>管理者：${owner}；${swap.text}。<br>物理 ZRAM 内存成本：${formatEffectiveBytes(memUsedBytes)}。<br>${requestBlock}。`;
  return [
    `<b>VM 策略: ${escapeHtml(vmModeLabel(vmMode))}</b><br>${swapModeIntro(vmMode)}`,
    algoBlock,
    sizeBlock,
    `<b>swappiness = ${finiteNumber(d.swappiness)}</b><br>${describeSwappiness(finiteNumber(d.swappiness))}`,
    `<b>min_free_kbytes = ${finiteNumber(d.min_free_kbytes)}（约 ${Math.round(finiteNumber(d.min_free_kbytes) / 1024)} MB）</b><br>${describeMinFree(finiteNumber(d.min_free_kbytes))}`,
    `<b>watermark_scale_factor = ${wsf}</b><br>${describeWatermark(wsf)}`,
    `<b>vfs_cache_pressure = ${finiteNumber(d.vfs_cache_pressure)}</b><br>${describeVfs(finiteNumber(d.vfs_cache_pressure))}`
  ].join('<br><br>');
}
function clampSwapValue(key, raw) {
  const input = refs.swapTuneInputs[key];
  const contractLimit = state.swapData?.limits?.[key];
  const limit = contractLimit || { min: Number(input.min), max: Number(input.max) };
  let value = Number(raw);
  if (!Number.isFinite(value)) value = Number(state.swapData?.optimized?.[key] ?? input.min);
  return Math.min(limit.max, Math.max(limit.min, Math.round(value)));
}

// 用滑块吸附后的实际 value 算填充百分比, 让填充轨道与 thumb 位置严格一致
function updateSwapFill(key) {
  const el = refs.swapTuneInputs[key];
  const limit = state.swapData?.limits?.[key] || { min: Number(el.min), max: Number(el.max) };
  const pct = ((Number(el.value) - limit.min) / (limit.max - limit.min)) * 100;
  el.style.setProperty('--fill', `${Math.max(0, Math.min(100, pct))}%`);
}

function setSwapTuneValues(values) {
  if (!values) return;
  SWAP_KEYS.forEach((key) => {
    const value = clampSwapValue(key, values && values[key]);
    refs.swapTuneInputs[key].value = String(value);
    refs.swapTuneNumbers[key].value = String(value);
    refs.swapTuneValues[key].textContent = String(value);
    updateSwapFill(key);
  });
}

function getSwapTuneValues() {
  const values = {};
  SWAP_KEYS.forEach((key) => {
    values[key] = clampSwapValue(key, refs.swapTuneNumbers[key].value);
  });
  return values;
}

function syncSwapTuneField(key, raw) {
  const value = clampSwapValue(key, raw);
  refs.swapTuneInputs[key].value = String(value);
  refs.swapTuneNumbers[key].value = String(value);
  refs.swapTuneValues[key].textContent = String(value);
  updateSwapFill(key);
}

function openSwapTuneModal() {
  const current = state.swapData;
  if (!current?.limits || !current?.optimized || !current?.stock) {
    showToast('VM 参数尚未读取，请稍后重试');
    refreshSwap();
    return;
  }
  setSwapTuneValues({
    swappiness: current.swappiness,
    min_free_kbytes: current.min_free_kbytes,
    watermark_scale_factor: current.watermark_scale_factor,
    vfs_cache_pressure: current.vfs_cache_pressure
  });
  bindZramDraft();
  if (!state.zramDraft && current.feature_vm === 'optimized' && current.zram_target_supported === true) {
    state.zramDraft = splitZramRequest(current.zram_size_requested);
  }
  if (state.zramDraft) writeZramDraft(state.zramDraft);
  updateZramUnitUi(current);
  refs.swapTuneModal.classList.add('open');
  pushModalState('swapTune');
  queueNextPoll(computeNextPollDelay());
}

function closeSwapTuneModal() {
  refs.swapTuneModal.classList.remove('open');
  popModalIfTop('swapTune');
  queueNextPoll(POLL_MIN_DELAY_MS);
}

function renderSwapCard(data) {
  refs.swapRows.replaceChildren();
  const origBytes = finiteNumber(data.zram_orig_bytes);
  const comprBytes = finiteNumber(data.zram_compr_bytes);
  const memUsedBytes = finiteNumber(data.zram_mem_used_bytes);
  const ratio = origBytes > 0 ? ((comprBytes / origBytes) * 100).toFixed(1) : '—';
  const target = data.zram_target || {};
  const optimized = data.optimized || {};
  const stock = data.stock || {};
  const isEH = Boolean(data.zram_algo && target.algorithm && data.zram_algo === target.algorithm);
  const disksize = finiteNumber(data.zram_disksize);
  const zramOwner = String(data.zram_owner || 'unknown');
  const swap = activeSwapState(data);
  const request = zramRequestState(data);
  const mode = data.mode || data.feature_vm || 'unknown';
  const transactionPending = zramTransactionPending(data);
  const effectiveReadbackKnown = zramReadbackKnown(data);
  const targetSize = request.targetBytes > 0 ? `，约 ${fmtBytes(request.targetBytes)}` : '';
  const policyText = request.supported
    ? `${request.requested}${targetSize} · ${request.pending ? '待重启（pending_reboot）' : effectiveReadbackKnown ? '已读回' : '读回未知'}`
    : '未设置（system/disabled 只观察）';
  const reconcileText = data.zram_reconcile === 'restored'
    ? '已恢复模块写入前的 owner 请求'
    : data.zram_reconcile === 'effective'
      ? (effectiveReadbackKnown ? '在线 readback 已确认当前有效' : '历史 receipt 标记 effective，当前容量未读回')
      : data.zram_reconcile === 'committed'
        ? (effectiveReadbackKnown ? '跨 boot readback 已确认当前有效' : '历史 receipt 标记 committed，当前容量未读回')
    : data.zram_reconcile === 'external_changed'
      ? '检测到平台配置已变化，未覆盖外部请求'
      : '无模块请求事务';
  const restoreText = data.zram_restore_pending === true
    ? '已恢复请求，等待重启让 effective 容量对齐'
    : '无需等待 ZRAM 恢复';
  const transactionPhase = String(data.zram_transaction_phase || 'none');
  const transactionText = {
    staged: '请求已暂存，等待安全完成',
    requested: '等待容量读回',
    effective: effectiveReadbackKnown ? '当前 active 与容量已读回' : '已记录在线生效，但当前容量未读回',
    committed: effectiveReadbackKnown ? '跨重启后容量已读回' : '已跨重启记录，但当前容量未读回',
    canceled: '已取消，保留平台请求',
    external_changed: '平台请求已变化，模块未覆盖',
    orphaned: '事务不完整或跨重启无法确认',
    degraded: '读回凭据不完整',
    historical: '上一 boot 的历史记录，仅供参考'
  }[transactionPhase] || '无活动事务';
  const pendingReason = String(data.zram_pending_reason || 'none');
  const pendingReasonText = {
    transaction_active: '容量事务处理中',
    journal_degraded: '事务凭据不完整',
    restore_pending_reboot: '恢复请求等待重启',
    effective_size_pending_reboot: '当前容量等待重启对齐'
  }[pendingReason] || (pendingReason === 'none' ? '无' : pendingReason);
  const zramEffectiveState = String(data.zram_effective_state || 'unknown');
  const vmEffectiveState = String(data.vm_effective_state || 'unknown');
  const mmdText = `aconfig=${data.mmd_enabled_aconfig || 'unknown'} / zram=${data.mmd_zram_enabled || 'unknown'} / setup=${data.mmd_setup_complete || 'unknown'}`;
  const ownerHint = data.feature_vm === 'optimized'
    ? '模块 VM 已启用；ZRAM 仅接受显式请求'
    : '系统默认观察模式；模块不写 VM/ZRAM';
  refs.swapDesc.textContent = isEH
    ? `Emerald Hill 硬件压缩 · 压缩率 ${ratio}% · 实占 ${fmtBytes(memUsedBytes)} · ${ownerHint}`
    : `算法 ${data.zram_algo || 'unknown'} · ${ownerHint}`;
  const rows = [
    { label: 'VM 策略', value: vmModeLabel(mode), cls: mode === 'optimized' || mode === 'custom' ? 'good' : 'off' },
    { label: 'Swap 接入状态', value: swap.text, cls: swap.active ? 'good' : 'off' },
    { label: '逻辑 Swap 已用', value: swap.used, cls: swap.active ? 'good' : 'off' },
    { label: 'ZRAM 管理者', value: zramOwner, cls: zramOwner === 'mmd' ? 'good' : 'warn' },
    { label: '平台 mmd 状态', value: mmdText, cls: zramOwner === 'mmd' ? 'good' : 'warn' },
    { label: '平台容量请求', value: `${data.mmd_requested_size || '未设置'} · ${data.mmd_requested_algorithm || '未设置'}`, cls: 'off' },
    { label: '压缩算法', value: isEH ? '硬件加速' : (data.zram_algo || 'unknown'), cls: isEH && swap.active ? 'good' : 'warn' },
    { label: '当前有效容量', value: formatEffectiveBytes(disksize), cls: disksize > 0 ? 'good' : 'off' },
    { label: '物理 ZRAM 内存成本', value: formatEffectiveBytes(memUsedBytes), cls: memUsedBytes > 0 ? 'good' : 'off' },
    { label: '模块容量请求', value: policyText, cls: request.pending ? 'warn' : request.supported && request.requested !== '未设置' ? 'good' : 'off' },
    { label: '容量生效状态', value: zramEffectiveState === 'pending_reboot' ? '待重启' : zramEffectiveState === 'effective' && effectiveReadbackKnown ? '当前有效' : '未知，尚未确认', cls: zramEffectiveState === 'pending_reboot' ? 'warn' : zramEffectiveState === 'effective' && effectiveReadbackKnown ? 'good' : 'warn' },
    { label: '容量事务', value: `${transactionText} · ${reconcileText}`, cls: transactionPending || ['orphaned', 'degraded'].includes(transactionPhase) ? 'warn' : (effectiveReadbackKnown && (transactionPhase === 'effective' || transactionPhase === 'committed')) ? 'good' : 'off' },
    { label: '待处理原因', value: pendingReasonText, cls: pendingReason === 'none' ? 'off' : 'warn' },
    { label: '容量恢复状态', value: data.zram_restore_pending === true ? '已恢复请求，等待重启对齐' : '无需等待恢复', cls: data.zram_restore_pending === true ? 'warn' : 'good' },
    { label: 'VM 参数读回', value: vmEffectiveState === 'pending_reboot' || data.vm_reboot_required ? '待重启后恢复平台基线' : vmEffectiveState === 'effective' && vmReadbackKnown(data) ? '四项参数已读回' : '未知，尚未确认', cls: vmEffectiveState === 'pending_reboot' || data.vm_reboot_required ? 'warn' : vmEffectiveState === 'effective' && vmReadbackKnown(data) ? 'good' : 'warn' },
    { label: '换页倾向（swappiness）', value: String(finiteNumber(data.swappiness)), cls: data.swappiness === optimized.swappiness ? 'good' : data.swappiness === stock.swappiness ? 'warn' : 'off' },
    { label: '空闲内存底线（min_free_kbytes）', value: String(finiteNumber(data.min_free_kbytes)), cls: data.min_free_kbytes === optimized.min_free_kbytes ? 'good' : data.min_free_kbytes === stock.min_free_kbytes ? 'warn' : 'off' },
    { label: '水位间距（watermark_scale_factor）', value: String(finiteNumber(data.watermark_scale_factor)), cls: data.watermark_scale_factor === optimized.watermark_scale_factor ? 'good' : data.watermark_scale_factor === stock.watermark_scale_factor ? 'warn' : 'off' },
    { label: '文件缓存回收（vfs_cache_pressure）', value: String(finiteNumber(data.vfs_cache_pressure)), cls: data.vfs_cache_pressure === optimized.vfs_cache_pressure ? 'good' : data.vfs_cache_pressure === stock.vfs_cache_pressure ? 'warn' : 'off' }
  ];
  rows.forEach((row) => refs.swapRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
}


async function refreshSwap(force = false) {
  const refreshKey = force ? `memory.swap.refresh.force.${Date.now()}` : 'memory.swap.refresh';
  return requireFeature('core').runFeatureTask(refreshKey, async () => {
    state.swapLoading = true;
    bindZramDraft();
    try {
      const data = await apiFetch(API.swap, { timeoutMs: 6000, priority: force ? 'interactive' : 'normal', dedupe: !force, scope: force ? `memory.swap.readback.${Date.now()}` : 'memory.swap.read' });
    state.swapMode = data.mode || 'custom';
    state.featureVm = ['system', 'optimized', 'disabled'].includes(data.feature_vm) ? data.feature_vm : 'system';
    state.swapData = data;
    const policyReady = data.vm_policy_ready !== false;
    if (refs.swapToggleButton) refs.swapToggleButton.disabled = !policyReady;
    if (refs.swapTuneButton) refs.swapTuneButton.disabled = !policyReady;
    if (refs.swapZramSizeNumber) {
      const limits = data.zram_size_limits || {};
      const zramRequestAllowed = policyReady && data.feature_vm === 'optimized' && data.zram_target_supported === true;
      const transactionPending = zramTransactionPending(data);
      const zramCanEdit = zramRequestAllowed && !transactionPending;
      refs.swapZramSizeNumber.disabled = !zramCanEdit;
      if (refs.swapZramSizeUnit) refs.swapZramSizeUnit.disabled = !zramCanEdit;
      syncZramRequestControl(data);
      const requested = String(data.zram_size_requested || '').trim();
      const keepDraft = Boolean(state.zramDraft)
        && refs.swapTuneModal?.classList.contains('open')
        && !transactionPending;
      if (!keepDraft || transactionPending) {
        state.zramDraft = zramRequestAllowed ? splitZramRequest(requested) : null;
        writeZramDraft(state.zramDraft || { value: '', unit: 'mb' });
      }
      updateZramUnitUi(data);
    }
    SWAP_KEYS.forEach((key) => {
      const limit = data.limits?.[key];
      if (!limit) return;
      refs.swapTuneInputs[key].min = String(limit.min);
      refs.swapTuneInputs[key].max = String(limit.max);
      refs.swapTuneInputs[key].step = String(limit.step);
      refs.swapTuneNumbers[key].min = String(limit.min);
      refs.swapTuneNumbers[key].max = String(limit.max);
      refs.swapTuneNumbers[key].step = String(limit.step);
    });
    refs.swapToggleLabel.textContent = state.featureVm === 'optimized' ? '使用系统默认' : '启用模块候选';
    renderSwapCard(data);
    const disksize = finiteNumber(data.zram_disksize);
    const origBytes = finiteNumber(data.zram_orig_bytes);
    const comprBytes = finiteNumber(data.zram_compr_bytes);
    const zramPct = disksize > 0 ? ((origBytes / disksize) * 100).toFixed(0) : '0';
    refs.rtZramUsage.textContent = `${zramPct}%`;
    if (refs.rtZramUsageDetail) refs.rtZramUsageDetail.textContent = `${fmtBytes(origBytes)} / ${formatEffectiveBytes(disksize)} 逻辑 / 容量`;
    refs.rtRatio.textContent = origBytes > 0 ? `${((comprBytes / origBytes) * 100).toFixed(1)}% → 实占 ${fmtBytes(finiteNumber(data.zram_mem_used_bytes))}` : '—';
    syncHeroDesc();
      return true;
    } catch (err) {
      state.swapLoading = false;
      if (requireFeature('core').isRequestCancelled?.(err)) return null;
      refs.swapRows.replaceChildren(); refs.swapRows.appendChild(errorBlock('获取失败：' + err.message));
      return false;
    } finally { state.swapLoading = false; }
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
    refs.bgRestrictPkgHint.textContent = '名称来自统一识别目录；仍可手动输入未收录包名。';
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

function applyBgContract(data) {
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
  if (!valid) throw new Error('后台限制 contract 无效');

  const previousPolicy = refs.bgRestrictPolicySelect?.value;
  const previousDelay = Number(refs.bgRestrictDelaySelect?.value);
  state.bgContract = { policyOrder, delays, defaultPolicy, defaultDelay };

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
  if (!policySelect || !delaySelect) return;
  delaySelect.disabled = state.bgRestrictBusy || policySelect.value !== 'stop_after_leave';
}

function syncBgRestrictControls() {
  const busy = state.bgRestrictBusy || !state.bgContract;
  if (refs.bgRestrictToggleBtn) refs.bgRestrictToggleBtn.disabled = busy;
  if (refs.bgRestrictAddBtn) refs.bgRestrictAddBtn.disabled = busy;
  if (refs.bgRestrictPkgInput) refs.bgRestrictPkgInput.disabled = busy;
  if (refs.bgRestrictPolicySelect) refs.bgRestrictPolicySelect.disabled = busy;
  if (refs.bgRestrictDelaySelect) syncBgDelayControl(refs.bgRestrictPolicySelect, refs.bgRestrictDelaySelect);
  document.querySelectorAll('#bg-restrict-rows .bg-policy-row').forEach((row) => {
    const policySelect = row.querySelector('.bg-policy-select');
    const delaySelect = row.querySelector('.bg-delay-select');
    const saveBtn = row.querySelector('.bg-policy-save');
    const removeBtn = row.querySelector('.bg-policy-remove');
    if (policySelect) policySelect.disabled = busy;
    if (delaySelect) syncBgDelayControl(policySelect, delaySelect);
    if (saveBtn) saveBtn.disabled = busy;
    if (removeBtn) removeBtn.disabled = busy;
  });
}

function bgRestrictStatus(pkg, bucket, opBg, opAny, policy, enabled, runtime = {}) {
  if (!enabled) return { text: '已关闭', cls: 'off' };
  const bucketText = String(bucket || '').toLowerCase();
  const bgMode = String(opBg || '').toLowerCase();
  const anyMode = String(opAny || '').toLowerCase();
  const stopState = String(runtime.stopState || '');
  const rareOrLower = bucketText === '40' || bucketText === 'rare' || bucketText === '45' || bucketText === 'restricted';
  const restricted = bucketText === '45' || bucketText === 'restricted';
  const bgIgnored = bgMode === 'ignore';
  const anyIgnored = anyMode === 'ignore';
  switch (policy) {
    case 'bucket':
      return rareOrLower ? { text: '已降优先级', cls: 'good' } : { text: '未生效，点刷新重试', cls: 'err' };
    case 'block_services':
      if (restricted && bgIgnored) return { text: '已禁后台服务', cls: 'good' };
      if (restricted || bgIgnored) return { text: '部分生效', cls: 'warn' };
      return { text: '未生效，点刷新重试', cls: 'err' };
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
      return { text: '未生效，点刷新重试', cls: 'err' };
    case 'block_all':
    default:
      if (restricted && bgIgnored && anyIgnored) return { text: '已禁后台活动', cls: 'good' };
      if (restricted || bgIgnored || anyIgnored) return { text: '部分生效', cls: 'warn' };
      return { text: '未生效，点刷新重试', cls: 'err' };
  }
}

function renderBgRestrict(data) {
  applyBgContract(data);
  state.bgRestrictEnabled = data.enabled === 'on' ? 'on' : 'off';
  const on = state.bgRestrictEnabled === 'on';
  refs.bgRestrictToggleLabel.textContent = on ? '关闭' : '开启';
  refs.bgRestrictDesc.textContent = on
    ? '已开启：应用离开前台后，将按所选策略限制后台活动。'
    : '已关闭：应用列表保留，后台设置已恢复。';
  refs.bgRestrictRows.replaceChildren();
  const packages = Array.isArray(data.packages) ? data.packages : [];
  renderBgRestrictSuggestions(data.suggestions, packages);
  if (packages.length === 0) {
    refs.bgRestrictRows.appendChild(buildInfoRow('应用列表', '尚未添加应用', 'off'));
    syncBgRestrictControls();
    return;
  }
  packages.forEach((p) => {
    const policy = normalizeBgPolicy(p.policy);
    const delay = normalizeBgDelay(p.delay);
    const meta = BG_RESTRICT_POLICY_PRESENTATION[policy];
    const opBg = p.op_bg || '';
    const opAny = p.op_any || p.appops || '';
    const stopState = String(p.stop_state || '');
    const st = bgRestrictStatus(p.pkg, p.bucket, opBg, opAny, policy, on, { stopState });
    const row = document.createElement('div');
    row.className = 'data-row bg-policy-row';

    const main = document.createElement('div');
    main.className = 'bg-policy-main';
    const title = document.createElement('div');
    title.className = 'bg-policy-title';
    const displayName = friendlyPackageLabel(p.pkg, p.label);
    title.textContent = displayName;
    const detail = document.createElement('div');
    detail.className = 'bg-policy-detail';
    const stopStateText = {
      pending: '倒计时进行中',
      force_stopped: '当前已休眠',
      relaunched: '系统已重新启动应用',
      untracked: '首次离开前台后开始计时'
    }[stopState] || '';
    const packagePrefix = displayName !== p.pkg ? `${p.pkg} · ` : '';
    detail.textContent = policy === 'stop_after_leave'
      ? `${packagePrefix}${meta.label} · ${delay}分钟${stopStateText ? ` · ${stopStateText}` : ''}`
      : `${packagePrefix}${meta.label}`;
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
    const policySelect = createBgPolicySelect(policy);
    const delaySelect = createBgDelaySelect(delay);
    policySelect.addEventListener('change', () => syncBgDelayControl(policySelect, delaySelect));
    const saveBtn = document.createElement('button');
    saveBtn.className = 'tiny-btn primary bg-policy-save';
    saveBtn.type = 'button';
    saveBtn.textContent = '保存';
    saveBtn.addEventListener('click', () => bgRestrictUpdate(p.pkg, policySelect.value, delaySelect.value));
    const rmBtn = document.createElement('button');
    rmBtn.className = 'tiny-btn bg-policy-remove';
    rmBtn.type = 'button';
    rmBtn.textContent = '移除';
    rmBtn.addEventListener('click', () => bgRestrictRemove(p.pkg));
    controls.appendChild(policySelect);
    controls.appendChild(delaySelect);
    controls.appendChild(saveBtn);
    controls.appendChild(rmBtn);

    row.appendChild(main);
    row.appendChild(statusWrap);
    row.appendChild(controls);
    refs.bgRestrictRows.appendChild(row);
  });
  syncBgRestrictControls();
}

async function refreshBgRestrict() {
  return requireFeature('core').runFeatureTask('memory.bgRestrict.refresh', async () => {
    try {
      const data = await apiFetch(API.bgRestrict, { timeoutMs: 8000, priority: 'normal', scope: 'memory.bgRestrict.read' });
    renderBgRestrict(data);
      return true;
    } catch (err) {
      if (requireFeature('core').isRequestCancelled?.(err)) return null;
      syncBgRestrictControls();
      refs.bgRestrictRows.replaceChildren();
      refs.bgRestrictRows.appendChild(errorBlock('获取失败：' + err.message));
      return false;
    }
  });
}

async function forceRefreshBgRestrict() {
  try {
    const data = await apiFetch(API.bgRestrict, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'refresh' }),
      timeoutMs: 10000, priority: 'interactive', scope: 'memory.bgRestrict'
    });
    if (data.ok) {
      const readback = await apiFetch(API.bgRestrict, { timeoutMs: 8000, priority: 'interactive', scope: 'memory.bgRestrict.readback' });
      if (readback?.ok === false) throw new Error(readback.error || '后台限制状态回读失败');
      renderBgRestrict(readback);
      showToast('已重新应用后台策略');
    } else {
      const fallback = await apiFetch(API.bgRestrict, { timeoutMs: 8000, priority: 'normal', scope: 'memory.bgRestrict.read' });
      renderBgRestrict(fallback);
    }
  } catch (err) {
    syncBgRestrictControls();
    refs.bgRestrictRows.replaceChildren();
    refs.bgRestrictRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

async function bgRestrictAction(body, successText) {
  if (state.bgRestrictBusy) return;
  state.bgRestrictBusy = true;
  syncBgRestrictControls();
  let nextData = null;
  let ok = false;
  try {
    const data = await apiFetch(API.bgRestrict, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      timeoutMs: 10000, priority: 'interactive', scope: 'memory.bgRestrict'
    });
    if (data.ok) {
      nextData = await apiFetch(API.bgRestrict, { timeoutMs: 8000, priority: 'interactive', scope: 'memory.bgRestrict.readback' });
      if (nextData?.ok === false) throw new Error(nextData.error || '后台限制状态回读失败');
      ok = true;
      showToast(successText);
    } else {
      showToast(`操作失败：${data.error || '未知'}`);
    }
  } catch (e) {
    showToast('请求失败：' + e.message);
  } finally {
    state.bgRestrictBusy = false;
    if (nextData) renderBgRestrict(nextData);
    syncBgRestrictControls();
  }
  return ok;
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
  const ok = await bgRestrictAction(
    { action: 'add', package: pkg, policy, delay },
    `已添加 ${friendlyPackageLabel(pkg, suggestion?.label)}`
  );
  if (ok) {
    refs.bgRestrictPkgInput.value = '';
    syncBgPackageHint();
  }
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

function vmReadbackMatches(data, expectedMode, expectedValues = null) {
  if (!data || data.ok === false || data.vm_policy_ready === false) return false;
  const expectedFeature = expectedMode === 'optimized' || expectedMode === 'custom' ? 'optimized' : expectedMode;
  if (data.feature_vm !== expectedFeature) return false;
  if (!expectedValues) return true;
  return SWAP_KEYS.every((key) => finiteNumber(data[key], NaN) === finiteNumber(expectedValues[key], NaN));
}

function zramRequestReadbackMatches(data, requested) {
  if (!data || data.ok === false || data.vm_policy_ready === false) return false;
  if (data.feature_vm !== 'optimized' || data.zram_target_supported !== true) return false;
  if (data.zram_alias_supported === true && data.zram_alias_readback_ok !== true) return false;
  if (String(data.zram_size_requested || '').trim() !== requested) return false;
  const targetBytes = finiteNumber(data.zram_target_current_bytes);
  if (!targetBytes) return false;
  const pending = data.zram_effective_state === 'pending_reboot'
    || data.zram_reboot_required === true
    || data.zram_transaction_phase === 'requested'
    || data.zram_transaction_phase === 'staged';
  return pending
    ? finiteNumber(data.zram_disksize) > 0
    : finiteNumber(data.zram_disksize) === targetBytes;
}

function optimizedCandidateReadbackMatches(data) {
  return vmReadbackMatches(data, 'optimized', data?.optimized || null);
}

async function toggleSwapMode() {
  if (state.swapBusy) return;
  state.swapBusy = true;
  const newMode = state.featureVm === 'optimized' ? 'system' : 'optimized';
  appendLog(newMode === 'optimized' ? '正在应用模块 VM 优化…' : '正在切换系统默认观察模式…', 'dim');
  try {
    const mutation = await apiFetch(API.swap, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mode: newMode }), timeoutMs: 8000, priority: 'interactive', scope: 'memory.swap' });
    if (mutation?.ok === false) throw new Error(mutation.error || 'VM mutation 未确认');
    const refreshed = await refreshSwap(true);
    const data = state.swapData;
    if (!refreshed || !vmReadbackMatches(data, newMode)
      || (newMode === 'optimized' && !optimizedCandidateReadbackMatches(data))) {
      throw new Error('VM 请求已返回，但 GET readback 未确认目标模式或四项候选参数');
    }
    const vmPending = data.vm_reboot_required === true;
    showToast(newMode === 'optimized'
      ? '已应用模块优化 VM 参数'
      : (vmPending ? '已切换系统默认；重启后恢复系统 VM，ZRAM 保持平台原值' : '已切换系统默认观察模式，未修改 ZRAM'));
    appendLog(newMode === 'optimized'
      ? 'VM 模块优化已应用'
      : (vmPending ? '系统默认模式已保存，等待重启恢复 VM；ZRAM 未写入' : '系统默认观察模式已启用，ZRAM 未写入'), 'ok');
  } catch (err) {
    showToast(`请求失败：${err?.message || '未知错误'}`);
    appendLog(`VM 设置失败：${err?.message || '未知错误'}`, 'err');
  } finally {
    state.swapBusy = false;
  }
}

async function applySwapCustom() {
  if (state.swapBusy) return;
  state.swapBusy = true;
  appendLog('正在提交自定义 VM 参数…', 'dim');
  const values = getSwapTuneValues();
  closeSwapTuneModal();
  showToast('参数已提交，正在读取确认…');
  try {
    const mutation = await apiFetch(API.swap, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode: 'custom', ...values }),
      timeoutMs: 8000, priority: 'interactive', scope: 'memory.swap'
    });
    if (mutation?.ok === false) throw new Error(mutation.error || 'VM mutation 未确认');
    appendLog('自定义 VM 参数已提交，等待 GET readback', 'dim');
    await confirmCustomVmReadback(values);
  } catch (err) {
    showToast(`请求失败：${err.message || '未知错误'}`);
    appendLog(`Swap 自定义参数失败：${err.message || '未知错误'}`, 'err');
  } finally {
    state.swapBusy = false;
  }
}

async function confirmCustomVmReadback(values) {
  try {
    const refreshed = await refreshSwap(true);
    const data = state.swapData;
    if (!refreshed || !vmReadbackMatches(data, 'custom', values)) {
      showToast('参数已提交，但 GET readback 尚未确认');
      appendLog('自定义 VM 参数等待 readback，未宣称已生效', 'warn');
      return false;
    }
    showToast('自定义 VM 参数已读回确认');
    appendLog('自定义 VM 参数已读回确认', 'ok');
    return true;
  } catch (err) {
    appendLog(`自定义 VM readback 失败：${err?.message || '未知错误'}`, 'warn');
    return false;
  }
}

async function applyZramSizeRequest() {
  if (state.featureVm !== 'optimized' || state.swapData?.zram_target_supported !== true) {
    showToast('系统默认模式不修改 ZRAM；请先启用模块 VM 优化');
    return;
  }
  if (zramTransactionPending(state.swapData)) {
    showToast('已有 ZRAM 容量事务待处理，请先重启或等待 backend reconcile');
    return;
  }
  const value = String(refs.swapZramSizeNumber?.value || '').trim();
  const unit = refs.swapZramSizeUnit?.value === 'percent' ? 'percent' : 'mb';
  const draft = { value, unit };
  const numericValue = Number(value);
  const limits = state.swapData?.zram_size_limits || {};
  const inputLimits = state.swapData?.zram_input_limits?.mb || { min: 1024, max: 16384 };
  const minMb = Number(inputLimits.min);
  const maxMb = Number(inputLimits.max);
  if (!/^(?:[0-9]+(?:\.[0-9]+)?)$/.test(value)
    || !Number.isFinite(numericValue)
    || (unit === 'percent' && (!Number.isInteger(numericValue) || numericValue < 10 || numericValue > 100))
    || (unit === 'mb' && (numericValue < minMb || numericValue > maxMb))) {
    showToast(unit === 'percent' ? '百分比必须为 10–100 的整数' : `容量必须在 ${minMb}–${maxMb} MB 范围内`);
    refs.swapZramSizeNumber?.focus();
    return;
  }
  state.zramDraft = draft;
  const backendValue = zramDraftToBackendValue(draft);
  if (!backendValue) { showToast('容量草稿无效'); return; }
  if (state.swapBusy) return;
  state.swapBusy = true;
  syncZramRequestControl();
  appendLog(`正在提交 ZRAM 容量请求：${value} ${unit === 'percent' ? '%' : 'MB'}`, 'dim');
  try {
    const data = await apiFetch(API.swap, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mode: 'zram_size', capacity: value, unit }), timeoutMs: 8000, priority: 'interactive', scope: 'memory.swap' });
    if (!data || data.ok === false) throw new Error(data?.error || 'backend mutation 未确认');
    showToast('容量请求已提交，正在读取确认…');
    appendLog(`ZRAM 容量请求已提交，等待 GET readback：${value} ${unit === 'percent' ? '%' : 'MB'}`, 'dim');
    await confirmZramReadback(backendValue, value, unit);
  } catch (err) {
    showToast(`ZRAM 容量请求失败：${err.message || '未知错误'}`);
    appendLog(`ZRAM 容量请求失败：${err.message || '未知错误'}`, 'err');
  } finally {
    state.swapBusy = false;
    syncZramRequestControl();
  }
}

async function confirmZramReadback(requested, displayValue, unit) {
  try {
    const refreshed = await refreshSwap(true);
    const readback = state.swapData;
    if (!refreshed || !zramRequestReadbackMatches(readback, requested)) {
      showToast('容量请求已提交，但 GET readback 尚未确认');
      appendLog('ZRAM 容量请求等待 readback，未宣称已生效', 'warn');
      return false;
    }
    const pending = readback.zram_reboot_required === true || readback.zram_restore_pending === true;
    showToast(pending ? 'ZRAM 请求已读回，等待重启' : 'ZRAM 请求已读回，当前有效容量已对齐');
    appendLog(`ZRAM 容量请求已读回：${displayValue} ${unit === 'percent' ? '%' : 'MB'}${pending ? '（待重启）' : '（当前有效）'}`, 'ok');
    return true;
  } catch (err) {
    appendLog(`ZRAM readback 失败：${err?.message || '未知错误'}`, 'warn');
    return false;
  }
}

registerFeature('memory', {
  refresh: refreshSwap,
  refreshRestrictions: refreshBgRestrict,
  isRefreshing: () => state.swapLoading,
  getSwapMode: () => state.featureVm,
  getSwapData: () => state.swapData,
  friendlyPackageLabel,
  buildSwapDetail,
  openSwapTuneModal,
  closeSwapTuneModal,
  applySwapCustom,
  applyZramSizeRequest,
  setSwapTuneValues,
  syncSwapTuneField,
  toggleSwapMode,
  toggleBgRestrict,
  bgRestrictAdd,
  syncBgPackageHint,
  syncBgRestrictControls,
  forceRefreshBgRestrict
});
})();
