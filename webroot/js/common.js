// 通用请求、轮询、导航和系统信息功能。
'use strict';
(() => {
const authState = { webuiToken: '' };
const shellState = {
  currentTab: 'home',
  deviceModel: '',
  foregroundPaused: false,
  poller: {
    timer: null,
    running: false,
    lastInteractionAt: 0,
    lastRun: { cpu: 0, thermal: 0, optim: 0, slow: 0 }
  },
  pull: { y0: 0, active: false, dist: 0, busy: false }
};

function boolValue(value) {
  return value === true || value === 'true' || value === 'yes' || value === 1 || value === '1';
}

function errorBlock(msg) {
  const el = document.createElement('div');
  el.className = 'note-body';
  el.style.cssText = 'color:var(--danger)';
  el.textContent = msg;
  return el;
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;'
  }[ch]));
}

function showToast(msg, dur = 2500, type = '') {
  const el = document.createElement('div');
  el.className = 'toast';
  // 显式 type 优先; 否则对明确失败措辞自动上 err 状态色 (成功/中性保持沉稳反白)
  if (!type && /失败|无效|错误|出错|超时/.test(msg)) type = 'err';
  if (type) el.classList.add(type);
  el.textContent = msg;
  refs.toastWrap.appendChild(el);
  window.setTimeout(() => {
    el.classList.add('out');
    el.addEventListener('animationend', () => el.remove(), { once: true });
    window.setTimeout(() => { if (el.isConnected) el.remove(); }, 400);
  }, dur);
}

function appendLog(text, type = '') {
  if (refs.logInner.querySelector('.log-dim:only-child')) refs.logInner.replaceChildren();
  const row = document.createElement('div');
  if (type) row.className = `log-${type}`;
  row.textContent = `[${new Date().toLocaleTimeString()}] ${text}`;
  refs.logInner.appendChild(row);
  while (refs.logInner.childNodes.length > 30) refs.logInner.removeChild(refs.logInner.firstChild);
  refs.logInner.scrollTop = refs.logInner.scrollHeight;
}

function setWebuiToken(token) {
  const clean = String(token || '').trim();
  if (!/^[A-Za-z0-9._:-]{8,128}$/.test(clean)) return false;
  authState.webuiToken = clean;
  sessionStorage.setItem(STORAGE_TOKEN_KEY, clean);
  return true;
}

function clearWebuiToken() {
  authState.webuiToken = '';
  sessionStorage.removeItem(STORAGE_TOKEN_KEY);
}

function loadWebuiTokenFromSession() {
  const fromHash = new URLSearchParams(location.hash.replace(/^#/, '')).get('token');
  if (fromHash && setWebuiToken(fromHash)) {
    history.replaceState(null, '', `${location.pathname}${location.search}`);
    return;
  }
  const saved = sessionStorage.getItem(STORAGE_TOKEN_KEY);
  if (saved) setWebuiToken(saved);
}

async function fetchWebuiTokenForPrompt() {
  try {
    const data = await apiFetch(API.auth, { timeoutMs: 4000 });
    const token = String(data?.token || '').trim();
    return /^[A-Za-z0-9._:-]{8,128}$/.test(token) ? token : '';
  } catch (_) {
    return '';
  }
}

async function ensureWebuiToken() {
  if (authState.webuiToken) return true;
  // auth.sh 经 loopback 自由提供 token（能 POST 必能 GET），读到即静默采用，不弹窗。
  const serverToken = await fetchWebuiTokenForPrompt();
  if (serverToken && setWebuiToken(serverToken)) return true;
  // 仅当 auth.sh 取不到 token 时（token 文件缺失/服务异常）才回退手动输入。
  const message = '无法自动读取 WebUI token，请手动输入\n\n获取方式: root shell 执行\ncat /data/adb/modules/pixel9pro_control/.webui_token\n\n也可打开 http://127.0.0.1:6210/#token=<token> 完成会话配对';
  const token = window.prompt(message, '');
  if (!setWebuiToken(token)) {
    showToast('缺少或无效的 WebUI token');
    return false;
  }
  return true;
}

// 会话无 token 时后台静默预取（auth.sh loopback），使首个写操作零延迟、零弹窗。
function prefetchWebuiToken() {
  fetchWebuiTokenForPrompt()
    .then((t) => { if (t && !authState.webuiToken) setWebuiToken(t); })
    .catch(() => {});
}

async function apiFetch(path, opts = {}) {
  const controller = opts.controller || new AbortController();
  const timeoutMs = opts.timeoutMs || 8000;
  const timeoutId = window.setTimeout(() => controller.abort(), timeoutMs);
  const headers = { ...(opts.headers || {}) };
  const method = (opts.method || 'GET').toUpperCase();
  if (method !== 'GET') {
    if (!(await ensureWebuiToken())) throw new Error('missing WebUI token');
    headers['X-PIXEL9PRO-TOKEN'] = authState.webuiToken;
  } else if (authState.webuiToken) {
    headers['X-PIXEL9PRO-TOKEN'] = authState.webuiToken;
  }
  const request = { cache: 'no-store', ...opts, headers, signal: controller.signal };
  delete request.timeoutMs;
  delete request.controller;
  let response;
  try {
    response = await fetch(path, request);
  } catch (err) {
    if (err && err.name === 'AbortError') {
      throw new Error(typeof controller.signal.reason === 'string' ? 'request cancelled' : 'request timeout');
    }
    throw err;
  } finally {
    clearTimeout(timeoutId);
  }
  if (!response.ok) {
    if (response.status === 403 && method !== 'GET') clearWebuiToken();
    throw new Error(response.status === 403 ? 'WebUI token 无效或已过期' : `HTTP ${response.status}`);
  }
  return response.json();
}

function sleep(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function noteUserActivity() {
  shellState.poller.lastInteractionAt = Date.now();
  if (isWebUiActive() && shellState.poller.running) queueNextPoll(POLL_MIN_DELAY_MS);
}

function isWebUiActive() {
  return document.visibilityState === 'visible' && !document.hidden && !shellState.foregroundPaused;
}

function isAnyModalOpen() {
  return Boolean(
    (refs.detailModal && refs.detailModal.classList.contains('open'))
    || (refs.swapTuneModal && refs.swapTuneModal.classList.contains('open'))
    || (refs.themeModal && refs.themeModal.classList.contains('open'))
    || (refs.rebootModal && refs.rebootModal.classList.contains('open'))
  );
}

function isPollingRelaxed() {
  return isAnyModalOpen() || (Date.now() - shellState.poller.lastInteractionAt) >= WEBUI_IDLE_MS;
}

function getPollInterval(key) {
  const relaxed = isPollingRelaxed();
  switch (key) {
    case 'cpu':
      if (shellState.currentTab === 'tune') return relaxed ? POLL_INTERVALS.cpu.relaxedPerf : POLL_INTERVALS.cpu.perf;
      if (shellState.currentTab === 'home') return relaxed ? POLL_INTERVALS.cpu.relaxedHome : POLL_INTERVALS.cpu.home;
      return 0;
    case 'thermal':
      if (shellState.currentTab === 'tune') return relaxed ? POLL_INTERVALS.thermal.relaxedThermal : POLL_INTERVALS.thermal.thermal;
      if (shellState.currentTab === 'home') return relaxed ? POLL_INTERVALS.thermal.relaxedHome : POLL_INTERVALS.thermal.home;
      return 0;
    case 'optim':
      if (shellState.currentTab === 'system') return relaxed ? POLL_INTERVALS.optim.relaxedOptim : POLL_INTERVALS.optim.optim;
      if (shellState.currentTab === 'home') return relaxed ? POLL_INTERVALS.optim.relaxedHome : POLL_INTERVALS.optim.home;
      return 0;
    case 'slow':
      if (shellState.currentTab === 'network' || shellState.currentTab === 'system') return relaxed ? POLL_INTERVALS.slow.relaxedOptim : POLL_INTERVALS.slow.optim;
      if (shellState.currentTab === 'home') return relaxed ? POLL_INTERVALS.slow.relaxedHome : POLL_INTERVALS.slow.home;
      return 0;
    default:
      return 0;
  }
}

function markPollFresh(keys, at = Date.now()) {
  keys.forEach((key) => { shellState.poller.lastRun[key] = at; });
}

function computeNextPollDelay(now = Date.now()) {
  const delays = [];
  ['cpu', 'thermal', 'optim', 'slow'].forEach((key) => {
    const interval = getPollInterval(key);
    if (!interval) return;
    delays.push(Math.max(interval - (now - shellState.poller.lastRun[key]), POLL_MIN_DELAY_MS));
  });
  return delays.length ? Math.min(...delays) : POLL_INTERVALS.slow.relaxedHome;
}

function queueNextPoll(delayMs = POLL_MIN_DELAY_MS) {
  clearTimeout(shellState.poller.timer);
  shellState.poller.timer = null;
  if (!shellState.poller.running || !isWebUiActive()) return;
  shellState.poller.timer = window.setTimeout(runPollCycle, Math.max(delayMs, POLL_MIN_DELAY_MS));
}

async function runPollCycle() {
  if (!shellState.poller.running || !isWebUiActive()) return;
  const now = Date.now();
  const jobs = [];
  const app = requireFeature('app');
  const profile = requireFeature('profile');
  const thermal = requireFeature('thermal');
  const memory = requireFeature('memory');
  const network = requireFeature('network');

  if (app.shouldPollCpu() && !profile.isRefreshing() && (now - shellState.poller.lastRun.cpu) >= getPollInterval('cpu')) {
    jobs.push({ key: 'cpu', run: () => profile.refresh() });
  }
  if (app.shouldPollThermal() && !thermal.isRefreshing() && (now - shellState.poller.lastRun.thermal) >= getPollInterval('thermal')) {
    jobs.push({ key: 'thermal', run: () => thermal.refresh() });
  }
  if (app.shouldPollOptim() && !memory.isRefreshing() && (now - shellState.poller.lastRun.optim) >= getPollInterval('optim')) {
    jobs.push({ key: 'optim', run: () => memory.refresh() });
  }
  if (app.shouldPollSlow() && (now - shellState.poller.lastRun.slow) >= getPollInterval('slow')) {
    jobs.push({
      key: 'slow',
      run: () => Promise.allSettled([network.refresh(), memory.refreshRestrictions(), loadInfo()])
    });
  }

  if (jobs.length) {
    markPollFresh(jobs.map((job) => job.key), now);
    await Promise.allSettled(jobs.map((job) => job.run()));
  }

  queueNextPoll(computeNextPollDelay());
}

let _topbarRafPending = false;
function syncTopbar() {
  if (_topbarRafPending) return;
  _topbarRafPending = true;
  requestAnimationFrame(() => {
    _topbarRafPending = false;
    const page = document.querySelector('.tab-page.active');
    const top = page ? page.scrollTop : 0;
    const compact = refs.topbar.classList.contains('compact');
    // 滞回阈值, 避免临界反复切换; compact 仅控制浅阴影, 不再收缩高度
    if (!compact && top > 24) refs.topbar.classList.add('compact');
    else if (compact && top < 8) refs.topbar.classList.remove('compact');
  });
}

function bindTopbarScroll() {
  document.querySelectorAll('.tab-page').forEach((page) => {
    page.addEventListener('scroll', syncTopbar, { passive: true });
  });
}

function switchTab(tab) {
  if (tab === shellState.currentTab) return;
  shellState.currentTab = tab;
  document.querySelectorAll('.tab-page').forEach((page) => page.classList.toggle('active', page.dataset.tab === tab));
  document.querySelectorAll('.tab-item').forEach((item) => item.classList.toggle('active', item.dataset.tab === tab));
  refs.topbarSubtitle.textContent = TAB_META[tab] || '控制台';
  syncTopbar();
  noteUserActivity();
  requireFeature('network').syncDeviceClockForTab();
  requireFeature('app').refreshCurrentTabData();
}

function getSwipeTargetTab(deltaX, deltaY) {
  const absX = Math.abs(deltaX);
  const absY = Math.abs(deltaY);
  if (absX < 60 || absX <= absY * 1.5) return '';
  const nextIndex = TAB_ORDER.indexOf(shellState.currentTab) + (deltaX < 0 ? 1 : -1);
  if (nextIndex < 0 || nextIndex >= TAB_ORDER.length) return '';
  return TAB_ORDER[nextIndex];
}

function bindTabSwipe() {
  let gesture = null;
  const findTouch = (list, id) => {
    for (let i = 0; i < list.length; i += 1) if (list[i].identifier === id) return list[i];
    return null;
  };
  refs.tabPages.addEventListener('touchstart', (evt) => {
    if (evt.touches.length !== 1) return;
    if (document.querySelector('.modal-wrap.open')) return;
    const page = evt.target.closest('.tab-page');
    if (!page || !page.classList.contains('active')) return;
    const touch = evt.touches[0];
    gesture = { id: touch.identifier, startX: touch.clientX, startY: touch.clientY, lastX: touch.clientX, lastY: touch.clientY, horizontal: null };
  }, { passive: true });
  refs.tabPages.addEventListener('touchmove', (evt) => {
    if (!gesture) return;
    const touch = findTouch(evt.touches, gesture.id) || findTouch(evt.changedTouches, gesture.id);
    if (!touch) return;
    gesture.lastX = touch.clientX;
    gesture.lastY = touch.clientY;
    const deltaX = touch.clientX - gesture.startX;
    const deltaY = touch.clientY - gesture.startY;
    if (gesture.horizontal === null) {
      if (Math.abs(deltaX) < 12 && Math.abs(deltaY) < 12) return;
      gesture.horizontal = Math.abs(deltaX) > Math.abs(deltaY) * 1.15;
    }
    if (gesture.horizontal && evt.cancelable) evt.preventDefault();
  }, { passive: false });
  const finish = () => {
    if (!gesture) return;
    const target = getSwipeTargetTab(gesture.lastX - gesture.startX, gesture.lastY - gesture.startY);
    gesture = null;
    if (target) switchTab(target);
  };
  refs.tabPages.addEventListener('touchend', finish, { passive: true });
  refs.tabPages.addEventListener('touchcancel', () => { gesture = null; }, { passive: true });
}

function bindPullToRefresh() {
  const TRIGGER = 90;
  const hide = () => {
    refs.pullInd.style.transform = 'translateY(-100%)';
    refs.pullInd.classList.remove('active', 'spinning');
  };
  // 顶部锚定刷新条: 按下拉距离从 -100% 滑到 0, 文字态随阈值变化 (非漂浮圆盘)
  const show = (dy) => {
    const p = Math.min(dy / TRIGGER, 1);
    refs.pullInd.style.transform = `translateY(${(-100 + p * 100).toFixed(1)}%)`;
    refs.pullText.textContent = dy >= TRIGGER ? '释放刷新' : '下拉刷新';
  };

  document.querySelectorAll('.tab-page').forEach((page) => {
    page.addEventListener('touchstart', (evt) => {
      if (shellState.pull.busy || evt.touches.length !== 1) return;
      if (page.scrollTop <= 0) {
        shellState.pull.y0 = evt.touches[0].clientY;
        shellState.pull.active = true;
        shellState.pull.dist = 0;
      }
    }, { passive: true });
    page.addEventListener('touchmove', (evt) => {
      if (!shellState.pull.active) return;
      const dy = evt.touches[0].clientY - shellState.pull.y0;
      if (page.scrollTop > 0) {
        shellState.pull.active = false;
        hide();
        return;
      }
      if (dy > 0) {
        shellState.pull.dist = dy;
        refs.pullInd.classList.add('active');
        show(dy);
        if (evt.cancelable) evt.preventDefault();
      } else {
        shellState.pull.active = false;
        hide();
      }
    }, { passive: false });
    page.addEventListener('touchend', async () => {
      if (!shellState.pull.active) return;
      shellState.pull.active = false;
      if (shellState.pull.dist > TRIGGER && !shellState.pull.busy) {
        shellState.pull.busy = true;
        refs.pullInd.classList.add('active', 'spinning');
        refs.pullInd.style.transform = 'translateY(0)';
        refs.pullText.textContent = '正在刷新';
        await requireFeature('app').fullRefresh();
        refs.pullText.textContent = '已完成';
        await sleep(400);
        shellState.pull.busy = false;
      }
      hide();
    }, { passive: true });
  });
}

function buildInfoRow(label, value, badgeClass = '') {
  const row = document.createElement('div');
  row.className = 'data-row';
  const key = document.createElement('span');
  key.className = 'data-key';
  key.textContent = label;
  const val = document.createElement('span');
  val.className = badgeClass ? `badge ${badgeClass}` : 'data-val';
  val.textContent = value;
  row.appendChild(key);
  row.appendChild(val);
  return row;
}

function fmtBytes(bytes) {
  const value = Number(bytes);
  if (value <= 0) return '0';
  if (value < 1048576) return `${(value / 1024).toFixed(0)}KB`;
  if (value < 1073741824) return `${(value / 1048576).toFixed(0)}MB`;
  return `${(value / 1073741824).toFixed(2)}GB`;
}

async function loadInfo() {
  try {
    const data = await apiFetch(API.info);
    const deviceModel = data.model || '—';
    const network = requireFeature('network');
    const profile = requireFeature('profile');
    const hadBaseband = network.isBasebandInstalled();
    shellState.deviceModel = deviceModel;
    network.setBasebandInstalled(boolValue(data.baseband_installed));
    profile.syncOptionalModuleUi();
    refs.infoModel.textContent = deviceModel;
    refs.infoAndroid.textContent = data.version ? `Android ${data.version}` : '—';
    refs.infoKernel.textContent = data.kernel || '—';
    refs.infoModule.textContent = data.module_version || '—';
    refs.topbarKicker.textContent = data.module_version
      ? `${deviceModel} · UI ${data.module_version}`
      : `${deviceModel} · UI`;
    if (network.isBasebandInstalled() && !hadBaseband) network.refreshBaseband();
    refs.rtWebuiMem.textContent = data.httpd_rss_kb
      ? data.httpd_rss_kb < 1024 ? `${data.httpd_rss_kb}KB` : `${(data.httpd_rss_kb / 1024).toFixed(1)}MB`
      : '—';
    // 内存与系统信息 → loadInfo 写入, refreshSwap 写入 ZRAM 部分
    const fmtKB = (kb) => {
      if (!kb || kb <= 0) return '—';
      return kb >= 1048576 ? `${(kb / 1048576).toFixed(1)}GB` : kb >= 1024 ? `${(kb / 1024).toFixed(0)}MB` : `${kb}KB`;
    };
    if (data.mem_total_kb > 0) refs.rtMemTotal.textContent = fmtKB(data.mem_total_kb);
    if (data.mem_avail_kb > 0) refs.rtMemAvail.textContent = fmtKB(data.mem_avail_kb);
    if (data.swap_free_kb > 0 || data.swap_total_kb > 0) {
      refs.rtSwapFree.textContent = `${fmtKB(data.swap_free_kb)} / ${fmtKB(data.swap_total_kb)}`;
    }
    if (data.uptime_sec > 0) {
      const h = Math.floor(data.uptime_sec / 3600);
      const m = Math.floor((data.uptime_sec % 3600) / 60);
      refs.rtUptime.textContent = h > 0 ? `${h}小时${m}分` : `${m}分钟`;
    }
    const vc = data.version_code || '';
    if (vc && localStorage.getItem('_modVC') !== vc) {
      localStorage.setItem('_modVC', vc);
      if (!sessionStorage.getItem('_reloaded')) {
        sessionStorage.setItem('_reloaded', '1');
        location.reload();
        return;
      }
    }
    sessionStorage.removeItem('_reloaded');
  } catch (_) {}
}

registerFeature('auth', {
  initialize() {
    loadWebuiTokenFromSession();
    if (!authState.webuiToken) prefetchWebuiToken();
  },
  ensureToken: ensureWebuiToken,
  hasToken: () => Boolean(authState.webuiToken)
});

registerFeature('shell', {
  initializeInteractions() {
    bindTabSwipe();
    bindPullToRefresh();
    bindTopbarScroll();
  },
  loadInfo,
  getCurrentTab: () => shellState.currentTab,
  getDeviceModel: () => shellState.deviceModel,
  isForegroundPaused: () => shellState.foregroundPaused,
  setForegroundPaused(value) { shellState.foregroundPaused = Boolean(value); },
  setLastInteractionAt(value) { shellState.poller.lastInteractionAt = value; },
  isPolling: () => shellState.poller.running,
  startPolling() {
    if (shellState.poller.running) return;
    shellState.poller.running = true;
    queueNextPoll(computeNextPollDelay());
  },
  stopPolling() {
    shellState.poller.running = false;
    clearTimeout(shellState.poller.timer);
    shellState.poller.timer = null;
  }
});

registerFeature('core', {
  apiFetch,
  appendLog,
  boolValue,
  buildInfoRow,
  computeNextPollDelay,
  errorBlock,
  escapeHtml,
  fmtBytes,
  isWebUiActive,
  markPollFresh,
  noteUserActivity,
  queueNextPoll,
  showToast,
  sleep,
  switchTab
});
})();

