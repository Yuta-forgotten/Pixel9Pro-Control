// NR、SIM、UECap、基带与 NTP 功能。
'use strict';
function buildNrSwitchDetail() {
  const contract = state.network.nrContract || {};
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
  refs.sim2AutoToggleBtn.disabled = state.network.standbyGuardBusy;
  refs.idleIsolateToggleBtn.disabled = state.network.standbyGuardBusy;
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
  state.network.sim2AutoManage = data.sim2_auto_manage === 'on' ? 'on' : 'off';
  state.network.idleIsolateMode = data.idle_isolate_mode === 'on' ? 'on' : 'off';
  state.network.standbyDiag = {
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

  const sim2On = state.network.sim2AutoManage === 'on';
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

  const isolateOn = state.network.idleIsolateMode === 'on';
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
  if (!state.network.standbyDiag.updatedAt) {
    refs.standbyDiagRows.appendChild(buildInfoRow('状态文件', '等待后台 worker 首次写入', 'off'));
  } else {
    const nrLabel = state.network.standbyDiag.nrSwitch === 'on'
      ? (state.network.standbyDiag.nrState === 'lte' ? 'NR 管理开启 / 当前 LTE' : 'NR 管理开启 / 当前 5G')
      : 'NR 管理关闭';
    const profileLabel = `${state.network.standbyDiag.profilePolicy === 'auto' ? '自动' : '手动'} / ${state.network.standbyDiag.activeProfile || 'unknown'}`;
    [
      { label: '最近更新', value: formatStandbyTimestamp(state.network.standbyDiag.updatedAt), cls: 'off' },
      { label: '当前屏幕', value: state.network.standbyDiag.screen === 'on' ? '亮屏' : state.network.standbyDiag.screen === 'off' ? '息屏' : '未知', cls: state.network.standbyDiag.screen === 'on' ? 'warn' : 'good' },
      { label: 'worker 分支', value: standbyWorkerModeLabel(state.network.standbyDiag.workerMode), cls: standbyWorkerModeClass(state.network.standbyDiag.workerMode) },
      { label: '下次复查', value: state.network.standbyDiag.nextSleepSecs ? `${state.network.standbyDiag.nextSleepSecs}s` : '—', cls: 'off' },
      { label: 'NR 状态', value: nrLabel, cls: state.network.standbyDiag.nrState === 'lte' ? 'warn' : 'off' },
      { label: '调度状态', value: profileLabel, cls: 'off' },
      { label: '循环计数', value: state.network.standbyDiag.cycleCount || '0', cls: 'off' },
    ].forEach((row) => refs.standbyDiagRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
  }

  syncStandbyGuardButtons();
}

function uecapLabel(mode) {
  if (mode === 'balanced') return '国内频段';
  if (mode === 'special') return '全面增强';
  if (mode === 'universal') return 'Google 默认';
  if (mode === 'custom') return '系统原生 / 第三方';
  return '未知';
}

function getUecapModeHash(data, mode) {
  if (!data || !mode) return '';
  return data[`${mode}_hash`] || '';
}

function getUecapVerifyRow(data, requested, active) {
  if (state.network.uecapVerifyState === 'failed') {
    return {
      label: '配置校验',
      value: state.network.uecapVerifyMessage || '未在时限内确认，请手动刷新复查',
      cls: 'warn'
    };
  }

  if (state.network.uecapPendingMode) {
    const label = uecapLabel(state.network.uecapPendingMode);
    if (state.network.uecapVerifyState === 'switching') {
      return { label: '配置校验', value: `${label}：切换中`, cls: 'warn' };
    }
    if (state.network.uecapVerifyState === 'verifying') {
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
  const selectedMode = state.network.uecapPendingMode || activeMode;
  refs.uecapBtnGroup.replaceChildren();
  UECAP_MODES.forEach((m) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    const isSelected = m.id === selectedMode;
    const isPending = state.network.uecapBusy && m.id === state.network.uecapPendingMode;
    btn.className = `uecap-btn${isSelected ? ' active' : ''}${isPending ? ' pending' : ''}${isPending && state.network.uecapVerifyState === 'verifying' ? ' verifying' : ''}`;
    btn.dataset.mode = m.id;
    btn.textContent = isPending
      ? (state.network.uecapVerifyState === 'switching' ? '切换中...' : '校验中...')
      : m.name;
    btn.disabled = state.network.uecapBusy;
    btn.addEventListener('click', () => setUecapMode(m.id));
    refs.uecapBtnGroup.appendChild(btn);
  });
}

function renderUecapRows(data) {
  refs.uecapRows.replaceChildren();
  const requested = data.requested_mode || state.network.uecapMode || 'special';
  const active = data.active_mode || 'custom';
  state.network.uecapMode = requested;
  state.network.uecapActiveMode = active;
  const modeInfo = UECAP_MODES.find((m) => m.id === requested);
  refs.uecapDesc.textContent = state.network.uecapPendingMode
    ? `${uecapLabel(state.network.uecapPendingMode)}：已提交切换，正在校验当前配置。`
    : modeInfo ? `${modeInfo.desc} · 切换后自动校验配置是否生效。` : '选择 UE 能力配置，切换后会自动校验是否生效。';
  renderUecapBtnGroup(requested);
  const verifyRow = getUecapVerifyRow(data, requested, active);
  const rows = [
    { label: '已选配置', value: uecapLabel(requested), cls: requested === active ? 'good' : 'off' },
    { label: '当前配置', value: uecapLabel(active), cls: active === requested ? 'good' : 'warn' },
    verifyRow,
    { label: '配置摘要', value: (data.target_hash || 'unknown').slice(0, 12), cls: 'off' },
  ];
  rows.forEach((row) => refs.uecapRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
}

async function refreshNrSwitch() {
  try {
    const data = await apiFetch(API.nrSwitch, { timeoutMs: 6000 });
    state.network.nrSwitch = data.nr_switch || 'off';
    state.network.nrContract = {
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
    state.network.uecapMode = data.requested_mode || 'special';
    state.network.uecapActiveMode = data.active_mode || 'custom';
    const expectedHash = getUecapModeHash(data, state.network.uecapMode);
    if (!state.network.uecapPendingMode && state.network.uecapVerifyState === 'failed' && state.network.uecapMode === state.network.uecapActiveMode && (!expectedHash || expectedHash === data.target_hash)) {
      state.network.uecapVerifyState = 'idle';
      state.network.uecapVerifyMessage = '';
    }
    renderUecapRows(data);
  } catch (err) {
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
  if (state.network.standbyGuardBusy) return;
  state.network.standbyGuardBusy = true;
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
    state.network.standbyGuardBusy = false;
    syncStandbyGuardButtons();
  }
}

async function toggleSim2AutoManage() {
  const next = state.network.sim2AutoManage === 'on' ? 'off' : 'on';
  await setStandbyGuard(
    { sim2_auto_manage: next },
    next === 'on' ? 'SIM2 自动管理已开启' : 'SIM2 自动管理已关闭',
    next === 'on' ? 'SIM2 自动管理: 开启' : 'SIM2 自动管理: 关闭'
  );
}

async function toggleIdleIsolateMode() {
  const next = state.network.idleIsolateMode === 'on' ? 'off' : 'on';
  await setStandbyGuard(
    { idle_isolate_mode: next },
    next === 'on' ? '待机隔离模式已开启' : '待机隔离模式已关闭',
    next === 'on' ? '待机隔离模式: 开启' : '待机隔离模式: 关闭'
  );
}

// ── 后台应用限制 ─────────────────────────────────────────
async function verifyUecapSwitch(mode, expectedHash, initialData) {
  const nonce = ++state.network.uecapVerifyNonce;
  const label = UECAP_MODES.find((m) => m.id === mode)?.name || mode;
  const deadline = Date.now() + UECAP_VERIFY_TIMEOUT_MS;
  let lastData = initialData || null;
  let lastErr = '';

  state.network.uecapPendingMode = mode;
  state.network.uecapExpectedHash = expectedHash || '';
  state.network.uecapVerifyState = 'switching';
  renderUecapRows(lastData || {
    requested_mode: mode,
    active_mode: state.network.uecapActiveMode || 'custom',
    target_hash: expectedHash || 'unknown'
  });

  await sleep(1800);

  while (state.network.uecapVerifyNonce === nonce && Date.now() < deadline) {
    state.network.uecapVerifyState = 'verifying';
    if (lastData) renderUecapRows(lastData);

    try {
      const data = await apiFetch(API.uecap, { timeoutMs: 6000 });
      lastData = data;
      state.network.uecapMode = data.requested_mode || mode;
      state.network.uecapActiveMode = data.active_mode || 'custom';
      renderUecapRows(data);

      const confirmedHash = expectedHash || getUecapModeHash(data, mode);
      const confirmed = data.requested_mode === mode
        && data.active_mode === mode
        && (!confirmedHash || data.target_hash === confirmedHash);

      if (confirmed) {
        state.network.uecapBusy = false;
        state.network.uecapPendingMode = '';
        state.network.uecapExpectedHash = '';
        state.network.uecapVerifyState = 'idle';
        state.network.uecapVerifyMessage = '';
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

  if (state.network.uecapVerifyNonce !== nonce) return;

  state.network.uecapBusy = false;
  state.network.uecapPendingMode = '';
  state.network.uecapExpectedHash = '';
  state.network.uecapVerifyState = 'failed';
  state.network.uecapVerifyMessage = lastErr
    ? `15 秒内未确认（${lastErr}）`
    : '15 秒内未确认，请手动刷新复查';

  if (lastData) renderUecapRows(lastData);
  showToast(`${label} 已提交切换，但 15 秒内未完成校验，请手动刷新复查`, 4200);
  appendLog(`UE 配置待复查: ${label}`, 'warn');
}

async function toggleNrSwitch() {
  if (state.network.nrBusy) return;
  state.network.nrBusy = true;
  try {
    const data = await apiFetch(API.nrSwitch, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'toggle' }), timeoutMs: 8000 });
    if (data.ok) {
      state.network.nrSwitch = data.nr_switch;
      showToast(data.nr_switch === 'on' ? 'NR 息屏降级已开启' : 'NR 息屏降级已关闭');
      appendLog(data.nr_switch === 'on' ? 'NR 息屏降级: 开启' : 'NR 息屏降级: 关闭', 'ok');
      refreshNrSwitch();
    } else {
      showToast('操作失败');
    }
  } catch (_) {
    showToast('请求失败');
  } finally {
    state.network.nrBusy = false;
  }
}

async function setUecapMode(mode) {
  if (state.network.uecapBusy || (mode === state.network.uecapMode && state.network.uecapVerifyState !== 'failed')) return;
  const label = UECAP_MODES.find((m) => m.id === mode)?.name || mode;
  state.network.uecapBusy = true;
  state.network.uecapPendingMode = mode;
  state.network.uecapVerifyState = 'switching';
  state.network.uecapVerifyMessage = `${label}：正在提交切换`;
  renderUecapRows({
    requested_mode: state.network.uecapMode || mode,
    active_mode: state.network.uecapActiveMode || 'custom',
    target_hash: state.network.uecapExpectedHash || 'unknown'
  });
  try {
    const data = await apiFetch(API.uecap, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ policy: 'manual', mode }),
      timeoutMs: 12000
    });
    if (data.ok) {
      state.network.uecapMode = data.requested_mode || mode;
      state.network.uecapActiveMode = data.active_mode || state.network.uecapActiveMode || 'custom';
      const expectedHash = getUecapModeHash(data, mode) || data.target_hash || '';
      state.network.uecapExpectedHash = expectedHash;
      state.network.uecapVerifyState = data.reloading ? 'switching' : 'verifying';
      renderUecapRows(data);
      showToast(`${label}：已提交切换，正在校验配置`, 2600);
      appendLog(`UE 配置已提交: ${label}，等待校验结果`, 'ok');
      await verifyUecapSwitch(mode, expectedHash, data);
    } else if (data.applied) {
      state.network.uecapMode = data.requested_mode || mode;
      state.network.uecapActiveMode = data.active_mode || mode;
      state.network.uecapBusy = false;
      state.network.uecapPendingMode = '';
      state.network.uecapExpectedHash = '';
      state.network.uecapVerifyState = 'failed';
      state.network.uecapVerifyMessage = data.error || '配置已切换，但 modem 未完成重载';
      renderUecapRows(data);
      showToast(state.network.uecapVerifyMessage, 4200);
      appendLog(`UE 配置已写入但重载失败: ${label}`, 'warn');
    } else {
      showToast(`切换失败：${data.error || '未知'}`);
      state.network.uecapBusy = false;
      state.network.uecapPendingMode = '';
      state.network.uecapExpectedHash = '';
      state.network.uecapVerifyState = 'failed';
      state.network.uecapVerifyMessage = data.error || '提交失败';
      await refreshUecap();
    }
  } catch (_) {
    showToast('请求失败');
    state.network.uecapBusy = false;
    state.network.uecapPendingMode = '';
    state.network.uecapExpectedHash = '';
    state.network.uecapVerifyState = 'failed';
    state.network.uecapVerifyMessage = '请求失败，请重试';
    await refreshUecap();
  }
}

function renderBasebandRows(data) {
  refs.basebandRows.replaceChildren();
  if (!data.installed) {
    state.network.basebandInstalled = false;
    syncOptionalModuleUi();
    return;
  }
  state.network.basebandInstalled = true;
  syncOptionalModuleUi();
  refs.basebandDesc.textContent = `已安装 ${data.version || ''}，可提供 CarrierSettings、MCFG 和 IMS 相关配置。`;
  const props = data.props || {};
  const cs = data.carrier_settings || {};
  const mcfg = data.mcfg || {};
  const rows = [
    { label: '安装状态', value: '已安装', cls: 'good' },
    { label: '版本', value: data.version || '未知', cls: 'off' },
    { label: 'VoLTE', value: props.volte_avail_ovr === '1' ? '已启用' : '未启用', cls: props.volte_avail_ovr === '1' ? 'good' : 'warn' },
    { label: 'Wi-Fi Calling', value: props.wfc_avail_ovr === '1' ? '已启用' : '未启用', cls: props.wfc_avail_ovr === '1' ? 'good' : 'warn' },
    { label: '运营商配置', value: cs.installed ? `${cs.count} 项` : '未安装', cls: cs.installed ? 'good' : 'off' },
    { label: '国内 MCFG', value: mcfg.installed ? `${mcfg.count} 个 mbn` : '未安装', cls: mcfg.installed ? 'good' : 'off' },
  ];
  rows.forEach((row) => refs.basebandRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
}

async function refreshBaseband() {
  if (!state.network.basebandInstalled) {
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
  if (!isWebUiActive() || state.shell.currentTab !== 'system') return;
  if (state.network.deviceClockTimer) return;
  const pad = (n) => String(n).padStart(2, '0');
  const tick = () => {
    const el = document.getElementById('ntp-device-time');
    if (!el || !isWebUiActive() || state.shell.currentTab !== 'system') return;
    // WebView 运行在本机, new Date() 即设备实时时钟; 每秒走字, 不再依赖 CGI 快照
    const d = new Date();
    el.textContent = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  };
  tick();
  state.network.deviceClockTimer = window.setInterval(tick, 1000);
}

function stopDeviceClock() {
  if (!state.network.deviceClockTimer) return;
  clearInterval(state.network.deviceClockTimer);
  state.network.deviceClockTimer = null;
}

function syncDeviceClockForTab() {
  if (isWebUiActive() && state.shell.currentTab === 'system') startDeviceClock();
  else stopDeviceClock();
}

function renderNtpCard(data) {
  refs.ntpServerList.replaceChildren();
  const servers = Array.isArray(data.servers)
    ? data.servers.filter((server) => server && server.id && server.name)
    : state.network.ntpServers;
  if (!servers.length) {
    refs.ntpServerList.appendChild(errorBlock('NTP 服务器配置为空'));
    return;
  }
  state.network.ntpServers = servers;
  const current = data.ntp_server || data.default_server || servers[0].id;
  state.network.ntpServer = current;
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
  if (state.network.ntpBusy || server === state.network.ntpServer) return;
  state.network.ntpBusy = true;
  try {
    const data = await apiFetch(API.ntp, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ server }),
      timeoutMs: 10000
    });
    if (data.ok) {
      const label = state.network.ntpServers.find((s) => s.id === server)?.name || server;
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
    state.network.ntpBusy = false;
  }
}

async function syncNtp() {
  if (state.network.ntpBusy) return;
  state.network.ntpBusy = true;
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
    state.network.ntpBusy = false;
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
  syncDeviceClockForTab
});

