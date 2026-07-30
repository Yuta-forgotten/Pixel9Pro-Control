// ZRAM、VM 参数与后台应用限制功能。
'use strict';
function describeSwappiness(v) {
  if (v <= 20) return '几乎不主动换出匿名页，ZRAM 基本闲置，仅在物理内存吃紧时才回收。';
  if (v <= 60) return '偏保守换页，多数匿名页留在物理内存，偏向前台零 swap 抖动。';
  if (v <= 110) return '平衡换页，配合硬件压缩减少无效 swap-in / swap-out，兼顾后台驻留与前台响应。';
  if (v <= 160) return '较积极换出匿名页到 ZRAM、尽量保留文件缓存（含原厂 150 取向）。';
  return '极度倾向换出匿名页，后台驻留能力最强，但热数据换入可能增多。';
}
function describeMinFree(kb) {
  if (kb <= 32768) return '空闲底线低（接近原厂 ~27MB），可用内存最大，但突发分配更易触发 direct reclaim 卡顿。';
  if (kb <= 65536) return '空闲底线偏低，可用内存较多，回收启动相对靠后。';
  if (kb <= 131072) return '中高空闲底线，kswapd 较早唤醒，direct reclaim 与 allocstall 明显减少。';
  if (kb <= 196608) return '空闲底线高，回收很早介入、突发分配几乎不卡，代价是预留内存增多。';
  return '空闲底线很高，适合重后台实验；日常使用偏浪费内存。';
}
function describeWatermark(v) {
  if (v <= 60) return '水位间距小（接近原厂 50），回收较晚触发，内存利用更满但突发峰值时更易吃紧。';
  if (v <= 150) return '中等水位间距，回收节奏适中。';
  if (v <= 300) return 'low/high 水位间距大，后台回收更早介入、单次回收更多，利于压制突发内存峰值，略增后台 CPU。';
  return '水位间距很大，回收非常积极，churn 与后台 CPU 上升，仅适合重后台场景。';
}
function describeVfs(v) {
  if (v <= 50) return '强烈保留 inode / dentry 缓存，文件路径查询与冷启动最快，但元数据占用内存更多。';
  if (v <= 80) return '倾向保留较多文件缓存元数据，利于应用启动。';
  if (v <= 120) return '常规回收力度（接近原厂 100），缓存与内存平衡。';
  if (v <= 160) return '较积极回收文件缓存元数据，省内存但路径查询 / 启动可能变慢。';
  return '激进回收 inode / dentry 缓存，最省内存但文件操作明显变慢。';
}
function swapModeIntro(mode) {
  if (mode === 'optimized') return '<b>当前方案：模块默认</b><br>面向 Pixel 9 Pro 日常使用与 Tensor G4 低热取向的一组平衡 VM 参数。';
  if (mode === 'stock') return '<b>当前方案：原厂</b><br>已恢复 Google 出厂 VM 参数，模块不再干预内存回收节奏。';
  return '<b>当前方案：自定义</b><br>以下为基于你手动设定值的实时分析；应用后以 custom 模式随下次开机恢复。';
}
function buildSwapDetail(data) {
  if (!data) return '尚未读取到 ZRAM / VM 状态，请稍后刷新。';
  const d = data;
  const target = d.zram_target || {};
  const isEH = d.zram_algo === target.algorithm;
  const sizeGB = (d.zram_disksize / 1073741824).toFixed(1);
  const totalRam = d.stock_zram_size > 0 ? d.stock_zram_size * 2 : 0;
  const ramPct = totalRam > 0 ? ` (约 ${Math.round((d.zram_disksize / totalRam) * 100)}% RAM)` : '';
  const wsf = d.watermark_scale_factor || 0;
  const currentAlgorithm = escapeHtml(d.zram_algo || 'unknown');
  const targetAlgorithm = escapeHtml(target.algorithm || 'unknown');
  const algoBlock = isEH
    ? `<b>ZRAM 算法: ${targetAlgorithm} (Emerald Hill 硬件加速)</b><br>Tensor G4 内置固定功能压缩引擎，适合高频换页场景。`
    : `<b>ZRAM 算法: ${currentAlgorithm}</b><br>当前未达到模块目标 ${targetAlgorithm}；开机服务会尝试恢复。`;
  const sizeBlock = `<b>ZRAM 大小: ${sizeGB}GB${ramPct}</b><br>原厂默认约为 50% RAM；模块扩容后让更多后台匿名页驻留在 ZRAM 中。`;
  return [
    swapModeIntro(d.mode),
    algoBlock,
    sizeBlock,
    `<b>swappiness: ${d.swappiness}</b><br>${describeSwappiness(d.swappiness)}`,
    `<b>min_free_kbytes: ${d.min_free_kbytes}（≈${Math.round(d.min_free_kbytes / 1024)}MB）</b><br>${describeMinFree(d.min_free_kbytes)}`,
    `<b>watermark_scale_factor: ${wsf}</b><br>${describeWatermark(wsf)}`,
    `<b>vfs_cache_pressure: ${d.vfs_cache_pressure}</b><br>${describeVfs(d.vfs_cache_pressure)}`
  ].join('<br><br>');
}
function clampSwapValue(key, raw) {
  const input = refs.swapTuneInputs[key];
  const contractLimit = state.memory.swapData?.limits?.[key];
  const limit = contractLimit || { min: Number(input.min), max: Number(input.max) };
  let value = Number(raw);
  if (!Number.isFinite(value)) value = Number(state.memory.swapData?.optimized?.[key] ?? input.min);
  return Math.min(limit.max, Math.max(limit.min, Math.round(value)));
}

// 用滑块吸附后的实际 value 算填充百分比, 让填充轨道与 thumb 位置严格一致
function updateSwapFill(key) {
  const el = refs.swapTuneInputs[key];
  const limit = state.memory.swapData?.limits?.[key] || { min: Number(el.min), max: Number(el.max) };
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
  const current = state.memory.swapData;
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
  const ratio = data.zram_orig_bytes > 0 ? ((data.zram_compr_bytes / data.zram_orig_bytes) * 100).toFixed(1) : '—';
  const target = data.zram_target || {};
  const optimized = data.optimized || {};
  const stock = data.stock || {};
  const isEH = data.zram_algo === target.algorithm;
  const sizeGB = (data.zram_disksize / 1073741824).toFixed(1);
  refs.swapDesc.textContent = isEH
    ? `Emerald Hill 硬件压缩 · 压缩率 ${ratio}% · 实占 ${fmtBytes(data.zram_mem_used_bytes)}`
    : `算法 ${data.zram_algo} · 目标 ${target.algorithm || 'unknown'}`;
  const rows = [
    { label: 'ZRAM 算法', value: isEH ? '硬件加速' : data.zram_algo, cls: isEH ? 'good' : 'warn' },
    { label: 'ZRAM 大小', value: `${sizeGB}GB`, cls: data.zram_disksize === target.size_bytes ? 'good' : 'off' },
    { label: 'swappiness', value: String(data.swappiness), cls: data.swappiness === optimized.swappiness ? 'good' : data.swappiness === stock.swappiness ? 'warn' : 'off' },
    { label: 'min_free_kbytes', value: String(data.min_free_kbytes), cls: data.min_free_kbytes === optimized.min_free_kbytes ? 'good' : data.min_free_kbytes === stock.min_free_kbytes ? 'warn' : 'off' },
    { label: 'watermark_scale_factor', value: String(data.watermark_scale_factor || 0), cls: data.watermark_scale_factor === optimized.watermark_scale_factor ? 'good' : data.watermark_scale_factor === stock.watermark_scale_factor ? 'warn' : 'off' },
    { label: 'vfs_cache_pressure', value: String(data.vfs_cache_pressure), cls: data.vfs_cache_pressure === optimized.vfs_cache_pressure ? 'good' : data.vfs_cache_pressure === stock.vfs_cache_pressure ? 'warn' : 'off' }
  ];
  rows.forEach((row) => refs.swapRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
}


async function refreshSwap() {
  if (state.memory.swapLoading) return;
  state.memory.swapLoading = true;
  try {
    const data = await apiFetch(API.swap, { timeoutMs: 6000 });
    state.memory.swapMode = data.mode || 'custom';
    state.memory.swapData = data;
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
    refs.swapToggleLabel.textContent = state.memory.swapMode === 'optimized' ? '恢复原厂' : '应用模块默认';
    renderSwapCard(data);
    refs.rtZramUsage.textContent = `${data.zram_disksize > 0 ? ((data.zram_orig_bytes / data.zram_disksize) * 100).toFixed(0) : '0'}% (${fmtBytes(data.zram_orig_bytes)} / ${(data.zram_disksize / 1073741824).toFixed(1)}GB)`;
    refs.rtRatio.textContent = data.zram_orig_bytes > 0 ? `${((data.zram_compr_bytes / data.zram_orig_bytes) * 100).toFixed(1)}% → 实占 ${fmtBytes(data.zram_mem_used_bytes)}` : '—';
    syncHeroDesc();
  } catch (err) {
    refs.swapRows.replaceChildren(); refs.swapRows.appendChild(errorBlock('获取失败：' + err.message));
  } finally {
    state.memory.swapLoading = false;
  }
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
  state.memory.bgRestrictSuggestions = (Array.isArray(suggestions) ? suggestions : [])
    .filter((item) => item && item.pkg && !active.has(String(item.pkg)))
    .sort((a, b) => String(a.label || a.pkg).localeCompare(String(b.label || b.pkg), 'zh-CN'));
  if (!refs.bgRestrictPkgSuggestions) return;
  refs.bgRestrictPkgSuggestions.replaceChildren();
  state.memory.bgRestrictSuggestions.forEach((item) => {
    const option = document.createElement('option');
    const caution = item.restriction_tier === 'caution' ? ' · 谨慎限制' : '';
    option.value = String(item.pkg);
    option.label = `${item.label || item.pkg}${item.category ? ` · ${item.category}` : ''}${caution}`;
    option.textContent = option.label;
    refs.bgRestrictPkgSuggestions.appendChild(option);
  });
  refs.bgRestrictPkgInput.placeholder = state.memory.bgRestrictSuggestions.length
    ? '输入包名或选择本机常用应用'
    : 'com.example.app';
  syncBgPackageHint();
}

function syncBgPackageHint() {
  if (!refs.bgRestrictPkgHint || !refs.bgRestrictPkgInput) return;
  const pkg = String(refs.bgRestrictPkgInput.value || '').trim();
  const suggestion = state.memory.bgRestrictSuggestions.find((item) => item.pkg === pkg);
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
  return BG_RESTRICT_POLICIES[policy] ? policy : 'block_all';
}

function normalizeBgDelay(delay) {
  const value = Number(delay);
  return BG_RESTRICT_DELAYS.includes(value) ? value : 5;
}

function createBgPolicySelect(value) {
  const select = document.createElement('select');
  select.className = 'bg-policy-select';
  BG_RESTRICT_POLICY_ORDER.forEach((id) => {
    const opt = document.createElement('option');
    opt.value = id;
    opt.textContent = BG_RESTRICT_POLICIES[id].label;
    opt.selected = id === value;
    select.appendChild(opt);
  });
  return select;
}

function createBgDelaySelect(value) {
  const select = document.createElement('select');
  select.className = 'bg-delay-select';
  BG_RESTRICT_DELAYS.forEach((min) => {
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
  delaySelect.disabled = state.memory.bgRestrictBusy || policySelect.value !== 'stop_after_leave';
}

function syncBgRestrictControls() {
  const busy = state.memory.bgRestrictBusy;
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
  state.memory.bgRestrictEnabled = data.enabled === 'on' ? 'on' : 'off';
  const on = state.memory.bgRestrictEnabled === 'on';
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
    const meta = BG_RESTRICT_POLICIES[policy];
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
  try {
    const data = await apiFetch(API.bgRestrict, { timeoutMs: 8000 });
    renderBgRestrict(data);
  } catch (err) {
    refs.bgRestrictRows.replaceChildren();
    refs.bgRestrictRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

async function forceRefreshBgRestrict() {
  try {
    const data = await apiFetch(API.bgRestrict, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'refresh' }),
      timeoutMs: 10000
    });
    if (data.ok) {
      renderBgRestrict(data);
      showToast('已重新应用后台策略');
    } else {
      const fallback = await apiFetch(API.bgRestrict, { timeoutMs: 8000 });
      renderBgRestrict(fallback);
    }
  } catch (err) {
    refs.bgRestrictRows.replaceChildren();
    refs.bgRestrictRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

async function bgRestrictAction(body, successText) {
  if (state.memory.bgRestrictBusy) return;
  state.memory.bgRestrictBusy = true;
  syncBgRestrictControls();
  let nextData = null;
  let ok = false;
  try {
    const data = await apiFetch(API.bgRestrict, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      timeoutMs: 10000
    });
    if (data.ok) {
      nextData = data;
      ok = true;
      showToast(successText);
    } else {
      showToast(`操作失败：${data.error || '未知'}`);
    }
  } catch (e) {
    showToast('请求失败：' + e.message);
  } finally {
    state.memory.bgRestrictBusy = false;
    if (nextData) renderBgRestrict(nextData);
    syncBgRestrictControls();
  }
  return ok;
}

async function toggleBgRestrict() {
  const next = state.memory.bgRestrictEnabled === 'on' ? 'off' : 'on';
  await bgRestrictAction({ action: 'toggle' }, next === 'on' ? '后台限制已开启' : '后台限制已关闭');
}

async function bgRestrictAdd() {
  const pkg = (refs.bgRestrictPkgInput.value || '').trim();
  if (!pkg || !/^[a-zA-Z][a-zA-Z0-9._]*$/.test(pkg)) {
    showToast('请输入有效的包名 (如 com.example.app)');
    return;
  }
  const policy = normalizeBgPolicy(refs.bgRestrictPolicySelect.value);
  const delay = normalizeBgDelay(refs.bgRestrictDelaySelect.value);
  const suggestion = state.memory.bgRestrictSuggestions.find((item) => item.pkg === pkg);
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
  await bgRestrictAction(
    { action: 'update', package: pkg, policy: normalizeBgPolicy(policy), delay: normalizeBgDelay(delay) },
    `已更新 ${pkg}`
  );
}

async function bgRestrictRemove(pkg) {
  await bgRestrictAction({ action: 'remove', package: pkg }, `已移除 ${pkg}`);
}

async function toggleSwapMode() {
  if (state.memory.swapBusy) return;
  state.memory.swapBusy = true;
  const newMode = state.memory.swapMode === 'optimized' ? 'stock' : 'optimized';
  try {
    const data = await apiFetch(API.swap, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mode: newMode }), timeoutMs: 8000 });
    state.memory.swapMode = data.mode || newMode;
    state.memory.swapData = data;
    showToast(newMode === 'optimized' ? '已应用模块默认 VM 参数' : '已恢复原厂 VM 参数');
    appendLog(newMode === 'optimized' ? 'Swap 模块默认已应用' : 'Swap 已恢复原厂', 'ok');
    renderSwapCard(data);
    refreshSwap();
  } catch (_) {
    showToast('请求失败');
  } finally {
    state.memory.swapBusy = false;
  }
}

async function applySwapCustom() {
  if (state.memory.swapBusy) return;
  state.memory.swapBusy = true;
  const values = getSwapTuneValues();
  try {
    const data = await apiFetch(API.swap, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode: 'custom', ...values }),
      timeoutMs: 8000
    });
    state.memory.swapMode = data.mode || 'custom';
    state.memory.swapData = data;
    showToast('自定义 VM 参数已应用');
    appendLog('Swap 自定义参数已应用', 'ok');
    renderSwapCard(data);
    closeSwapTuneModal();
    refreshSwap();
  } catch (err) {
    showToast(`请求失败：${err.message || '未知错误'}`);
  } finally {
    state.memory.swapBusy = false;
  }
}

registerFeature('memory', {
  refresh: refreshSwap,
  refreshRestrictions: refreshBgRestrict
});

