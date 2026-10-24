// 通用请求、轮询、导航和系统信息功能。
'use strict';
(() => {
const authState = { webuiToken: '', bootstrap: null, callbackId: 0, bootstrapAttempted: false, pairing: null };
const nativeCommands = new Map();
const requestHub = {
  active: 0,
  maxConcurrent: 3,
  maxQueued: 24,
  queue: [],
  pendingGets: new Map(),
  mutationScopes: new Set(),
  mutationResources: new Set(),
  activeJobs: new Set(),
  nextId: 0,
  completed: 0,
  rejected: 0
};
const REQUEST_POLICIES = Object.freeze({
  snapshot: Object.freeze({ timeoutMs: 8000, queueTimeoutMs: 12000, priority: 'background' }),
  thermalHistory: Object.freeze({ timeoutMs: 8000, queueTimeoutMs: 12000, priority: 'normal' }),
  thermalLive: Object.freeze({ timeoutMs: 14000, queueTimeoutMs: 12000, priority: 'normal' }),
  diagnostic: Object.freeze({ timeoutMs: 30000, queueTimeoutMs: 15000, priority: 'normal' }),
  mutation: Object.freeze({ timeoutMs: 30000, queueTimeoutMs: 15000, priority: 'interactive' }),
  lifecycle: Object.freeze({ timeoutMs: 45000, queueTimeoutMs: 15000, priority: 'interactive' })
});
const featureTasks = new Map();
let toastTimer = null;
let toastRemovalTimer = null;
let lastToast = { message: '', at: 0 };
const shellState = {
  currentTab: 'home',
  deviceModel: '',
  foregroundPaused: false,
  poller: {
    timer: null,
    running: false,
    inFlight: false,
    failures: { cpu: 0, thermal: 0, optim: 0, slow: 0 },
    lastInteractionAt: 0,
    lastRun: { cpu: 0, thermal: 0, optim: 0, slow: 0 }
  },
  pull: { y0: 0, active: false, dist: 0, busy: false }
};
function boolValue(value) {
  return value === true || value === 'true' || value === 'yes' || value === 1 || value === '1';
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[ch]));
}

function showToast(msg, dur = 2500, type = '') {
  if (!refs.toastWrap) return;
  const message = String(msg);
  if (lastToast.message === message && Date.now() - lastToast.at < 4000) return;
  lastToast = { message, at: Date.now() };
  clearTimeout(toastTimer);
  clearTimeout(toastRemovalTimer);
  // Keep transient feedback bounded so rapid taps cannot build an overlay wall.
  refs.toastWrap.querySelectorAll('.toast').forEach((toast) => toast.remove());
  const el = document.createElement('div');
  el.className = 'toast';
  if (!type && /失败|无效|错误|出错|超时/.test(msg)) type = 'err';
  if (type) el.classList.add(type);
  el.textContent = msg;
  refs.toastWrap.setAttribute('role', 'status');
  refs.toastWrap.setAttribute('aria-live', 'polite');
  refs.toastWrap.setAttribute('aria-atomic', 'true');
  refs.toastWrap.appendChild(el);
  requireFeature('ui').updateOverlayLayout();
  toastTimer = window.setTimeout(() => {
    toastTimer = null;
    el.classList.add('out');
    el.addEventListener('animationend', () => el.remove(), { once: true });
    toastRemovalTimer = window.setTimeout(() => { toastRemovalTimer = null; if (el.isConnected) el.remove(); }, 400);
  }, dur);
}

function errorBlock(msg) { return requireFeature('diagnostics').errorBlock(msg); }
function appendLog(...args) { return requireFeature('diagnostics').appendLog(...args); }
function clearLogs() { return requireFeature('diagnostics').clearLogs(); }

function setWebuiToken(token) {
  const clean = String(token || '').trim();
  if (!/^[A-Za-z0-9._:-]{8,128}$/.test(clean)) return false;
  authState.webuiToken = clean;
  try { sessionStorage.setItem(STORAGE_TOKEN_KEY, clean); } catch (_) { /* Keep the validated token usable for this page. */ }
  return true;
}

function clearWebuiToken() {
  authState.webuiToken = '';
  try { sessionStorage.removeItem(STORAGE_TOKEN_KEY); } catch (_) {}
  showConnectionError('连接已失效。可点“重新连接”，无需输入配对信息。');
}

function showConnectionError(message) {
  const panel = document.getElementById('webui-connection');
  const status = document.getElementById('webui-connection-status');
  if (status) status.textContent = message;
  if (panel) panel.hidden = false;
}

async function validatePairing() {
  if (!authState.webuiToken) return false;
  try {
    const result = await rawApiFetch(API.auth, { timeoutMs: 6000 });
    if (result.paired !== true) throw new Error('配对未确认');
    const panel = document.getElementById('webui-connection');
    if (panel) panel.hidden = true;
    return true;
  } catch (_) {
    clearWebuiToken();
    return false;
  }
}

function loadWebuiTokenFromSession() {
  const fromHash = new URLSearchParams(location.hash.replace(/^#/, '')).get('token');
  if (fromHash && setWebuiToken(fromHash)) {
    history.replaceState(null, '', `${location.pathname}${location.search}`);
    return;
  }
  let saved = '';
  try { saved = sessionStorage.getItem(STORAGE_TOKEN_KEY); } catch (_) {}
  if (saved) setWebuiToken(saved);
}

async function readManagerToken() {
  if (authState.bootstrap) return authState.bootstrap;
  if (authState.bootstrapAttempted) return '';
  authState.bootstrapAttempted = true;
  // KernelSU and APatch expose this asynchronous API only inside their
  // trusted module WebView. A normal loopback client cannot use the bridge.
  const bridge = window.ksu;
  if (!bridge || typeof bridge.spawn !== 'function') return '';
  authState.bootstrap = nativeRunCommand('cat /data/adb/modules/pixel9pro_control/.webui_token', { timeoutMs: 4000, maxBytes: 256 })
    .then(({ code, stdout }) => code === 0 ? stdout.trim() : '').catch(() => '');
  try { return await authState.bootstrap; } finally { authState.bootstrap = null; }
}

async function browserAutoSession() {
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort('REQUEST_TIMEOUT'), 8000);
  try {
    const response = await fetch(API.auth, {
      method: 'POST', cache: 'no-store', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', 'X-PIXEL9PRO-BOOTSTRAP': '1' },
      body: JSON.stringify({ action: 'bootstrap' }), signal: controller.signal
    });
    const text = await response.text();
    if (text.length > 4096) throw new Error('自动连接响应无效');
    const data = JSON.parse(text);
    if (!response.ok || data?.paired !== true || !setWebuiToken(data.token)) {
      throw new Error(data?.error || '自动连接未完成，请重试');
    }
    return true;
  } finally { clearTimeout(timer); }
}

function connectAutomatically({ retry = false } = {}) {
  if (authState.pairing) return authState.pairing;
  authState.pairing = (async () => {
    try {
      if (authState.webuiToken && await validatePairing()) return true;
      if (WEBUI_NATIVE_TRANSPORT) {
        if (retry) authState.bootstrapAttempted = false;
        const token = await readManagerToken();
        if (!token || !setWebuiToken(token) || !await validatePairing()) throw new Error('管理器连接未完成，请重试');
      } else await browserAutoSession();
      const panel = document.getElementById('webui-connection');
      if (panel) panel.hidden = true;
      return true;
    } catch (error) {
      authState.webuiToken = '';
      try { sessionStorage.removeItem(STORAGE_TOKEN_KEY); } catch (_) {}
      const detail = String(error?.message || '');
      showConnectionError(error?.name === 'AbortError' ? '自动连接超时，可点击“重新连接”。'
        : /[\u4e00-\u9fff]/.test(detail) ? `自动连接未完成：${detail}`
          : '自动连接未完成，可点击“重新连接”或从 Root 管理器打开 WebUI。');
      return false;
    }
  })().finally(() => { authState.pairing = null; });
  return authState.pairing;
}

async function ensureWebuiToken(signal) {
  if (signal?.aborted) throw requestAbortError(signal);
  if (authState.webuiToken) return true;
  const connected = await connectAutomatically();
  if (signal?.aborted) throw requestAbortError(signal);
  return connected;
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'"'"'`)}'`;
}

function nativeRunCommand(command, { signal, timeoutMs, maxBytes = 4 * 1024 * 1024 }) {
  // APatch exec(...callback) still calls Job.exec synchronously inside the
  // JavaScript bridge. spawn enqueues and returns, keeping close/navigation
  // available while the bounded CGI finishes in its own root shell.
  if (typeof window.ksu?.spawn !== 'function') return Promise.reject(new Error('管理器缺少异步 spawn 接口，请更新管理器后重试'));
  const now = Date.now();
  if (nativeCommands.size >= 3) {
    const error = new Error('管理器仍有未完成命令，请稍后手动刷新');
    error.code = 'NATIVE_BUSY'; error.cancelled = true;
    return Promise.reject(error);
  }
  const commandId = `${now}_${authState.callbackId++}`;
  nativeCommands.set(commandId, true);
  return new Promise((resolve, reject) => {
    const callback = `pixel9pro_job_${Date.now()}_${authState.callbackId++}`;
    let settled = false;
    let stdout = '';
    let stderr = '';
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
      if (nativeCommands.has(commandId)) {
        // A cancelled view does not kill an accepted transaction. Retain only
        // a tiny exit listener, discard output and keep the real native slot
        // occupied until it exits. At most three such listeners can exist.
        stdout = ''; stderr = '';
        window[callback] = {
          stdout: { emit() {} }, stderr: { emit() {} },
          emit(event) {
            if (event === 'exit' || event === 'error') { nativeCommands.delete(commandId); delete window[callback]; }
          }
        };
      } else delete window[callback];
      if (error) reject(error); else resolve(value);
    };
    const onAbort = () => finish(requestAbortError(signal));
    const timer = window.setTimeout(() => finish(requestAbortError(null, 'REQUEST_TIMEOUT')), timeoutMs);
    if (signal?.aborted) { nativeCommands.delete(commandId); onAbort(); return; }
    signal?.addEventListener('abort', onAbort, { once: true });
    window[callback] = {
      stdout: { emit: (event, chunk) => {
        if (event !== 'data' || settled) return;
        stdout += `${String(chunk || '')}\n`;
        if (stdout.length > maxBytes) finish(new Error('模块接口响应过大'));
      } },
      stderr: { emit: (event, chunk) => { if (event === 'data' && stderr.length < 2048) stderr += String(chunk || '').slice(0, 2048 - stderr.length); } },
      emit: (event, value) => {
        if (event === 'exit') { nativeCommands.delete(commandId); finish(null, { code: Number(value), stdout, stderr }); }
        else if (event === 'error') { nativeCommands.delete(commandId); finish(new Error('管理器命令执行失败')); }
      }
    };
    try { window.ksu.spawn(command, '[]', '{}', callback); } catch (error) { nativeCommands.delete(commandId); finish(error); }
  });
}

// A manager WebView stays on its trusted module assets. Never navigate a
// root-enabled WebView to an unauthenticated loopback HTTP server. Only fixed
// CGI entry points are executable; request data is shell-quoted separately.
function nativeApiFetch(path, request) {
  const url = new URL(path, 'http://127.0.0.1:6210');
  const allowed = new Set(Object.values(API).map((value) => new URL(value, url).pathname));
  if (!allowed.has(url.pathname) || !/^\/cgi-bin\/[A-Za-z0-9_.-]+[.]sh$/.test(url.pathname)) {
    return Promise.reject(new Error('不允许的模块接口'));
  }
  const method = (request.method || 'GET').toUpperCase();
  if (!['GET', 'POST'].includes(method)) return Promise.reject(new Error('不支持的请求方法'));
  const body = method === 'POST' ? String(request.body || '') : '';
  const bytes = new TextEncoder().encode(body).length;
  if (bytes > 4096) return Promise.reject(new Error('请求正文过大'));
  const token = String(request.headers['X-PIXEL9PRO-TOKEN'] || '');
  const fields = {
    REMOTE_ADDR: '127.0.0.1', REQUEST_METHOD: method,
    HTTP_X_PIXEL9PRO_TOKEN: token, QUERY_STRING: url.search.slice(1),
    CONTENT_TYPE: method === 'POST' ? 'application/json' : '', CONTENT_LENGTH: String(bytes)
  };
  const environment = Object.entries(fields).map(([key, value]) => `${key}=${shellQuote(value)}`).join(' ');
  const program = `/system/bin/sh /data/adb/modules/pixel9pro_control/scripts/cgi_dispatch.sh ${shellQuote(url.pathname.split('/').pop())}`;
  const command = `printf '%s' ${shellQuote(body)} | env ${environment} ${program}`;
  return nativeRunCommand(command, { signal: request.signal, timeoutMs: request.timeoutMs }).then(({ code: errno, stdout }) => {
      const output = String(stdout || '');
      const separator = /\r?\n\r?\n/.exec(output);
      if (!separator) throw new Error(`模块接口未返回有效响应（退出码 ${Number(errno)}）`);
      const headers = output.slice(0, separator.index);
      const statusMatch = /^Status:\s*(\d{3})/im.exec(headers);
      const status = statusMatch ? Number(statusMatch[1]) : Number(errno) === 0 ? 200 : 500;
      const payload = output.slice(separator.index + separator[0].length);
      return new Response(payload, { status, headers: { 'Content-Type': 'application/json' } });
  });
}

async function rawApiFetch(path, opts = {}) {
  const controller = opts.controller || new AbortController();
  const timeoutMs = opts.timeoutMs;
  const deadlineAt = Date.now() + timeoutMs;
  const timeoutId = window.setTimeout(() => controller.abort('REQUEST_TIMEOUT'), timeoutMs);
  const headers = { ...(opts.headers || {}) };
  const method = (opts.method || 'GET').toUpperCase();
  try {
    if (method !== 'GET') {
      if (!authState.webuiToken) throw new Error('连接尚未建立，请重新连接 WebUI');
      headers['X-PIXEL9PRO-TOKEN'] = authState.webuiToken;
    } else if (authState.webuiToken) {
      headers['X-PIXEL9PRO-TOKEN'] = authState.webuiToken;
    }
    const request = { cache: 'no-store', ...opts, headers, signal: controller.signal };
    delete request.timeoutMs;
    delete request.controller;
    delete request._tokenReady;
    const response = WEBUI_NATIVE_TRANSPORT
      ? await nativeApiFetch(path, { ...request, timeoutMs })
      : await fetch(path, request);
    if (response.status === 403
      && authState.webuiToken === headers['X-PIXEL9PRO-TOKEN']) clearWebuiToken();
    // Keep the same AbortController active while the CGI body is consumed.
    // BusyBox httpd can send headers before a slow shell/awk pipeline finishes;
    // clearing the timer at that point would permanently occupy a Request Hub
    // slot and make unrelated UI requests appear to load forever.
    const bodyText = await response.text();
    if (controller.signal.aborted) throw requestAbortError(controller.signal);
    let payload = null;
    try { payload = bodyText ? JSON.parse(bodyText) : null; } catch (_) {
      if (Date.now() >= deadlineAt) throw requestAbortError(null, 'REQUEST_TIMEOUT');
      const formatError = new Error('服务返回了无法识别的数据，请刷新后重试');
      formatError.status = response.status;
      formatError.detail = bodyText.slice(0, 240);
      throw formatError;
    }
    // JSON.parse is synchronous: check elapsed time before publishing its result.
    if (Date.now() >= deadlineAt) throw requestAbortError(null, 'REQUEST_TIMEOUT');
    if (!response.ok) {
      const detail = payload?.error || payload?.message || (payload ? JSON.stringify(payload) : '接口未返回错误详情');
      const knownDetail = {
        '未开启游戏移交且没有有效 lease，owner arbiter 不运行': '游戏自动接管已关闭，当前没有待处理的接管状态，无需检查',
        '未检测到 fas-rs，owner 手动唤醒不可用': '未检测到 fas-rs，无法检查游戏接管状态',
        'scheduler operation already running or could not start': '接管检查未启动，可能有其他调度操作尚未完成，请刷新确认',
        'invalid token': '连接验证已失效，请重新连接 WebUI',
        'missing server token': '连接验证信息尚未就绪，请重新连接 WebUI'
      }[detail];
      const statusMessage = {
        400: '提交内容无效，请检查设置后重试',
        403: '连接验证未通过，请重新连接 WebUI',
        404: '当前模块缺少此功能接口，请检查已安装版本',
        409: '当前状态不满足操作条件，请刷新确认',
        429: '操作过于频繁，请稍候再试',
        500: '服务处理失败，请查看运行记录',
        503: '服务暂不可用，请稍后刷新'
      }[response.status] || '服务未完成请求，请查看运行记录';
      const error = new Error(knownDetail || (/[\u4e00-\u9fff]/.test(detail) ? detail : statusMessage));
      error.status = response.status;
      error.detail = detail;
      error.payload = payload;
      appendLog(`服务请求未完成（HTTP ${response.status}）：${detail}`, 'err');
      throw error;
    }
    if (payload === null || typeof payload !== 'object') {
      const formatError = new Error('服务未返回有效数据，请稍后刷新');
      formatError.status = response.status;
      throw formatError;
    }
    return payload;
  } catch (err) {
    if (err && (err.name === 'AbortError' || controller.signal.aborted)) {
      throw requestAbortError(controller.signal);
    }
    throw err;
  } finally {
    clearTimeout(timeoutId);
  }
}

function cancelReadRequests(reason, matches) {
  [...requestHub.queue].forEach((job) => {
    if (job.mutation || !matches(job)) return;
    rejectQueuedRequest(job, requestAbortError(null, reason));
  });
  requestHub.activeJobs.forEach((job) => {
    if (!job.mutation && matches(job)) {
      if (job.key && requestHub.pendingGets.get(job.key) === job.promise) requestHub.pendingGets.delete(job.key);
      job.controller.abort(reason);
    }
  });
}

function cancelBackgroundRequests(resource) {
  cancelReadRequests('REQUEST_SUPERSEDED', (job) => job.resource === resource || (job.priority < 90 && job.supersedeAllowed));
}

function pauseReadRequests() {
  // Token discovery can belong to an explicitly requested write, which must
  // retain its completion path when the WebView leaves the foreground.
  cancelReadRequests('PAGE_HIDDEN', (job) => job.resource !== API.auth);
}

function requestHubKey(path, opts, method) {
  if (method !== 'GET' || opts.dedupe === false || opts.controller) return '';
  return String(opts.dedupeKey || path);
}

function requestPriority(value, method) {
  if (Number.isFinite(Number(value))) return Number(value);
  if (value === 'interactive') return method === 'GET' ? 90 : 100;
  if (value === 'normal') return 50;
  if (value === 'background') return 10;
  return method === 'GET' ? 10 : 100;
}

function positiveTimeout(value, fallback) {
  const timeout = Number(value);
  return Number.isFinite(timeout) && timeout > 0 ? timeout : fallback;
}

function resolveRequestPolicy(path, opts = {}) {
  const method = (opts.method || 'GET').toUpperCase();
  const url = new URL(path, location.href);
  const resource = url.pathname;
  let requestClass = method === 'GET' ? 'snapshot' : 'mutation';
  let defaults = {};
  if (method === 'GET') {
    if (resource === API.thermal) {
      requestClass = url.searchParams.get('history') === '1' ? 'thermalHistory' : 'thermalLive';
    } else if (resource === API.uecap || resource === API.checkBaseband || resource === API.thermalSet
      || (resource === API.profile && url.searchParams.get('compact') !== '1')) {
      requestClass = 'diagnostic';
      if (resource === API.checkBaseband) defaults.timeoutMs = 20000;
      if (resource === API.thermalSet) defaults.timeoutMs = 15000;
      if (resource === API.profile) defaults = { timeoutMs: 60000, priority: 'background' };
    } else if ([API.nrSwitch, API.ntp, API.standbyGuard, API.profile].includes(resource)) {
      defaults.timeoutMs = 12000;
    } else if (resource === API.status) defaults.timeoutMs = 10000;
    else if (resource === API.auth) defaults.timeoutMs = 4000;
    else if (resource === API.theme) defaults.timeoutMs = 5000;
    else if (resource === API.swap) defaults.timeoutMs = 6000;
  } else if (String(opts.scope || '').includes('lifecycle')) requestClass = 'lifecycle';
  if (Object.prototype.hasOwnProperty.call(REQUEST_POLICIES, opts.requestClass)) {
    requestClass = opts.requestClass;
    defaults = {};
  }
  const policy = { ...REQUEST_POLICIES[requestClass], ...defaults };
  return {
    requestClass,
    resource,
    timeoutMs: positiveTimeout(opts.timeoutMs, policy.timeoutMs),
    queueTimeoutMs: positiveTimeout(opts.queueTimeoutMs, policy.queueTimeoutMs),
    priority: requestPriority(opts.priority ?? policy.priority, method)
  };
}

function requestAbortError(signal, fallback = 'REQUEST_CANCELLED') {
  const code = typeof signal?.reason === 'string' ? signal.reason : fallback;
  const error = new Error(code === 'REQUEST_TIMEOUT' ? '请求超时' : '请求已取消');
  error.code = code;
  error.cancelled = code !== 'REQUEST_TIMEOUT';
  return error;
}

function clearQueueWait(job) {
  if (job.queueTimer) window.clearTimeout(job.queueTimer);
  job.signal.removeEventListener('abort', job.onQueuedAbort);
}

function rejectQueuedRequest(job, error) {
  const index = requestHub.queue.indexOf(job);
  if (index < 0) return;
  requestHub.queue.splice(index, 1);
  clearQueueWait(job);
  if (job.key && requestHub.pendingGets.get(job.key) === job.promise) requestHub.pendingGets.delete(job.key);
  job.reject(error);
  requestHub.rejected += 1;
}

function queuedRequestTimeout(job) {
  const error = new Error('请求排队超时，请稍后重试');
  error.code = 'REQUEST_QUEUE_TIMEOUT';
  rejectQueuedRequest(job, error);
  pumpRequestHub();
}

function isLimitedDiagnostic(job) {
  return !job.mutation && job.requestClass === 'diagnostic' && job.priority < 90;
}

function pumpRequestHub() {
  while (requestHub.active < requestHub.maxConcurrent && requestHub.queue.length) {
    requestHub.queue.sort((left, right) => right.priority - left.priority || left.id - right.id);
    // Slow automatic diagnostics share one slot; snapshots/history can use the
    // other two. Explicit interactive readback keeps its existing admission.
    const diagnosticBusy = [...requestHub.activeJobs].some(isLimitedDiagnostic);
    const jobIndex = requestHub.queue.findIndex((candidate) =>
      (!diagnosticBusy || !isLimitedDiagnostic(candidate))
      && !requestHub.queue.some((pending) => pending.mutation && pending.id < candidate.id
        && (pending.resource === candidate.resource || (candidate.mutation && pending.scope === candidate.scope)))
      && (candidate.mutation
        ? (!requestHub.mutationScopes.has(candidate.scope) && !requestHub.mutationResources.has(candidate.resource))
        : !requestHub.mutationResources.has(candidate.resource)));
    if (jobIndex < 0) break;
    const [job] = requestHub.queue.splice(jobIndex, 1);
    clearQueueWait(job);
    // Dispatch starts a fresh network/body deadline; queue patience is separate.
    if (job.signal?.aborted) {
      requestHub.rejected += 1;
      if (job.key && requestHub.pendingGets.get(job.key) === job.promise) requestHub.pendingGets.delete(job.key);
      job.reject(requestAbortError(job.signal));
      continue;
    }
    requestHub.active += 1;
    if (job.mutation) {
      requestHub.mutationScopes.add(job.scope);
      requestHub.mutationResources.add(job.resource);
    }
    requestHub.activeJobs.add(job);
    const finish = (settle, result) => {
      requestHub.active -= 1;
      requestHub.completed += 1;
      requestHub.activeJobs.delete(job);
      if (job.mutation) {
        requestHub.mutationScopes.delete(job.scope);
        requestHub.mutationResources.delete(job.resource);
      }
      if (job.key && requestHub.pendingGets.get(job.key) === job.promise) requestHub.pendingGets.delete(job.key);
      // A consumer's immediate follow-up GET must see a fresh request, not the
      // completed promise that would survive until a later finally microtask.
      settle(result);
      pumpRequestHub();
    };
    rawApiFetch(job.path, job.options).then(
      (payload) => finish(job.resolve, payload),
      (error) => finish(job.reject, error)
    );
  }
}

function apiFetch(path, opts = {}) {
  const method = (opts.method || 'GET').toUpperCase();
  const policy = resolveRequestPolicy(path, opts);
  if (method === 'GET' && !authState.webuiToken) {
    const error = new Error('连接尚未建立，数据读取已暂停');
    error.code = 'AUTH_REQUIRED';
    error.cancelled = true;
    return Promise.reject(error);
  }
  if (opts.controller?.signal.aborted) return Promise.reject(requestAbortError(opts.controller.signal));
  if (method !== 'GET' && opts._tokenReady !== true && !authState.webuiToken) {
    const controller = opts.controller || new AbortController();
    let timeoutId;
    let onAbort;
    const token = new Promise((resolve, reject) => {
      onAbort = () => reject(requestAbortError(controller.signal));
      controller.signal.addEventListener('abort', onAbort, { once: true });
      timeoutId = window.setTimeout(() => controller.abort('REQUEST_TIMEOUT'), policy.timeoutMs);
      ensureWebuiToken(controller.signal).then(resolve, reject);
    });
    return token
      .finally(() => {
        window.clearTimeout(timeoutId);
        controller.signal.removeEventListener('abort', onAbort);
      })
      .then((ready) => {
        if (!ready) throw new Error('连接尚未建立，请重新连接 WebUI');
        return apiFetch(path, { ...opts, controller, _tokenReady: true });
      });
  }
  const key = requestHubKey(path, opts, method);
  if (key) {
    const existing = requestHub.pendingGets.get(key);
    if (existing) return existing;
  }
  if (requestHub.queue.length >= requestHub.maxQueued) {
    const error = new Error('请求繁忙，请等待当前操作完成后重试');
    error.code = 'REQUEST_QUEUE_FULL';
    return Promise.reject(error);
  }
  const options = { ...opts, timeoutMs: policy.timeoutMs };
  delete options.priority;
  delete options.dedupe;
  delete options.dedupeKey;
  delete options.queueTimeoutMs;
  delete options.requestClass;
  delete options.scope;
  const priority = policy.priority;
  const mutation = method !== 'GET';
  const controller = options.controller || new AbortController();
  options.controller = controller;
  let resolveJob;
  let rejectJob;
  const promise = new Promise((resolve, reject) => {
    resolveJob = resolve;
    rejectJob = reject;
  });
  const job = {
    id: requestHub.nextId++, path, options, priority, key, mutation,
    requestClass: policy.requestClass,
    scope: String(opts.scope || policy.resource),
    resource: policy.resource,
    controller,
    supersedeAllowed: !opts.controller,
    signal: controller.signal,
    promise, resolve: resolveJob, reject: rejectJob,
    queueTimer: null, onQueuedAbort: null
  };
  if (key) requestHub.pendingGets.set(key, promise);
  requestHub.queue.push(job);
  job.queueTimer = window.setTimeout(() => queuedRequestTimeout(job), policy.queueTimeoutMs);
  job.onQueuedAbort = () => {
    rejectQueuedRequest(job, requestAbortError(job.signal));
    pumpRequestHub();
  };
  job.signal.addEventListener('abort', job.onQueuedAbort, { once: true });
  if (mutation) cancelBackgroundRequests(policy.resource);
  pumpRequestHub();
  return promise;
}

function requestHubState() {
  return {
    active: requestHub.active,
    queued: requestHub.queue.length,
    deduped: requestHub.pendingGets.size,
    completed: requestHub.completed,
    rejected: requestHub.rejected
  };
}

function runFeatureTask(key, task) {
  if (featureTasks.has(key)) return featureTasks.get(key);
  let promise;
  try {
    promise = Promise.resolve(task());
  } catch (error) {
    promise = Promise.reject(error);
  }
  featureTasks.set(key, promise);
  promise.finally(() => {
    if (featureTasks.get(key) === promise) featureTasks.delete(key);
  }).catch(() => {});
  return promise;
}

function isRequestCancelled(error) {
  return error?.cancelled === true || ['REQUEST_CANCELLED', 'REQUEST_SUPERSEDED', 'PAGE_HIDDEN'].includes(error?.code);
}

function sleep(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function noteUserActivity() {
  shellState.poller.lastInteractionAt = Date.now();
  if (isWebUiActive() && shellState.poller.running) queueNextPoll(POLL_MIN_DELAY_MS);
}

function isWebUiActive() {
  return Boolean(authState.webuiToken) && document.visibilityState === 'visible' && !document.hidden && !shellState.foregroundPaused;
}

function isAnyModalOpen() {
  return Boolean(document.querySelector('.modal-wrap.open:not(.detail-minimized)'));
}

function isPollingRelaxed() {
  return isAnyModalOpen() || (Date.now() - shellState.poller.lastInteractionAt) >= WEBUI_IDLE_MS;
}

function getPollInterval(key) {
  const base = getBasePollInterval(key);
  return base ? Math.min(Math.max(base, base * (2 ** shellState.poller.failures[key])), Math.max(base, 60000)) : 0;
}

function getBasePollInterval(key) {
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
  if (!shellState.poller.running || !isWebUiActive() || shellState.poller.inFlight) return;
  const now = Date.now();
  const app = requireFeature('app');
  if (app.isFullRefreshActive?.()) {
    queueNextPoll(3000);
    return;
  }
  shellState.poller.inFlight = true;
  const jobs = [];
  const profile = requireFeature('profile');
  const thermal = requireFeature('thermal');
  const memory = requireFeature('memory');
  const network = requireFeature('network');
  try {
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
        run: async () => {
          const networkResult = await network.refresh();
          if (!isWebUiActive()) return;
          const memoryResult = await memory.refreshRestrictions();
          if (!isWebUiActive()) return;
          const infoResult = await loadInfo();
          return networkResult !== false && memoryResult !== false && infoResult !== false;
        }
      });
    }

    if (jobs.length) {
      markPollFresh(jobs.map((job) => job.key), now);
      // Keep the single CGI listener from serving several expensive dumpsys
      // requests at once. A failed job is handled by its feature and does not
      // block the other scheduled jobs.
      const outcomes = await Promise.allSettled(jobs.map((job) => job.run()));
      outcomes.forEach((outcome, index) => {
        const key = jobs[index].key;
        if (outcome.status === 'rejected' && isRequestCancelled(outcome.reason)) return;
        if (outcome.status === 'fulfilled' && outcome.value === null) return;
        shellState.poller.failures[key] = outcome.status === 'rejected' || outcome.value === false
          ? Math.min(4, shellState.poller.failures[key] + 1) : 0;
      });
    }
  } finally {
    shellState.poller.inFlight = false;
    queueNextPoll(computeNextPollDelay());
  }
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
  document.querySelectorAll('.tab-item').forEach((item) => {
    const selected = item.dataset.tab === tab;
    item.classList.toggle('active', selected);
    if (selected) item.setAttribute('aria-current', 'page');
    else item.removeAttribute('aria-current');
  });
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
    if (isAnyModalOpen()) return;
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
  if (!Number.isFinite(value)) return '—';
  if (value <= 0) return '0';
  if (value < 1048576) return `${(value / 1024).toFixed(0)}KB`;
  if (value < 1073741824) return `${(value / 1048576).toFixed(0)}MB`;
  return `${(value / 1073741824).toFixed(2)}GB`;
}

async function loadInfoInternal() {
  try {
    const data = await apiFetch(API.info);
    if (Array.isArray(data) || data.ok === false) throw new Error(data.error || '系统信息响应无效');
    const deviceModel = data.model || '—';
    const network = requireFeature('network');
    const profile = requireFeature('profile');
    shellState.deviceModel = deviceModel;
    network.setBasebandInstalled(boolValue(data.baseband_installed));
    network.setBasebandBackendState(data.baseband_status || {
      installed: boolValue(data.baseband_installed),
      enabled: boolValue(data.baseband_enabled),
      runtime_verified: boolValue(data.baseband_runtime_verified),
      version: data.baseband_version || ''
    });
    profile.syncOptionalModuleUi();
    refs.infoModel.textContent = deviceModel;
    refs.infoAndroid.textContent = data.version ? `Android ${data.version}` : '—';
    refs.infoKernel.textContent = data.kernel || '—';
    refs.infoModule.textContent = data.module_version || '—';
    refs.topbarKicker.textContent = data.module_version
      ? `${deviceModel} · UI ${data.module_version}`
      : `${deviceModel} · UI`;
    refs.rtWebuiMem.textContent = data.httpd_rss_kb
      ? data.httpd_rss_kb < 1024 ? `${data.httpd_rss_kb}KB` : `${(data.httpd_rss_kb / 1024).toFixed(1)}MB`
      : '—';
    // 内存与系统信息 → loadInfo 写入, refreshSwap 写入 ZRAM 部分
    const fmtKB = (kb) => {
      if (!kb || kb <= 0) return '—';
      return kb >= 1048576 ? `${(kb / 1048576).toFixed(1)}GB` : kb >= 1024 ? `${(kb / 1024).toFixed(0)}MB` : `${kb}KB`;
    };
    if (data.mem_total_kb > 0) refs.rtMemTotal.textContent = fmtKB(data.mem_total_kb);
    if (data.mem_avail_kb > 0) {
      refs.rtMemAvail.textContent = fmtKB(data.mem_avail_kb);
      if (refs.rtMemAvailDetail) {
        const availablePct = data.mem_total_kb > 0 ? Math.round((data.mem_avail_kb / data.mem_total_kb) * 100) : 0;
        refs.rtMemAvailDetail.textContent = availablePct > 0 ? `约 ${availablePct}% 可用` : '当前可用量';
      }
    }
    if (data.swap_free_kb > 0 || data.swap_total_kb > 0) {
      refs.rtSwapFree.textContent = `${fmtKB(data.swap_free_kb)} / ${fmtKB(data.swap_total_kb)}`;
    }
    if (data.uptime_sec > 0) {
      const h = Math.floor(data.uptime_sec / 3600);
      const m = Math.floor((data.uptime_sec % 3600) / 60);
      refs.rtUptime.textContent = h > 0 ? `${h}小时${m}分` : `${m}分钟`;
      if (refs.rtUptimeDetail) refs.rtUptimeDetail.textContent = '设备启动后';
    }
    const vc = data.version_code || '';
    try {
      if (vc && localStorage.getItem('_modVC') !== vc) {
        localStorage.setItem('_modVC', vc);
      // Version discovery is informational. Never force location.reload() from
      // a background poll: it destroys pending reboot/rollback confirmation
      // and is unnecessary because a new page load gets the current assets.
        sessionStorage.removeItem('_reloaded');
      }
    } catch (_) { /* Version cache must not invalidate authoritative system info. */ }
    return true;
  } catch (err) {
    if (isRequestCancelled(err)) return null;
    appendLog(`系统信息读取失败：${err?.message || err}`, 'err');
    return false;
  }
}

let loadInfoPromise = null;
async function loadInfo() {
  if (loadInfoPromise) return loadInfoPromise;
  loadInfoPromise = loadInfoInternal();
  try { return await loadInfoPromise; }
  finally { loadInfoPromise = null; }
}

registerFeature('auth', {
  async initialize() {
    const retry = document.getElementById('webui-connection-retry');
    retry?.addEventListener('click', async () => {
      if (authState.pairing) return;
      retry.disabled = true;
      try {
        if (await connectAutomatically({ retry: true })) window.dispatchEvent(new Event('pixel9pro:paired'));
      } finally { retry.disabled = false; }
    });
    loadWebuiTokenFromSession();
    return connectAutomatically();
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
  isPollCycleBusy: () => shellState.poller.inFlight,
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
  clearLogs,
  boolValue,
  buildInfoRow,
  computeNextPollDelay,
  errorBlock,
  escapeHtml,
  fmtBytes,
  isWebUiActive,
  markPollFresh,
  noteUserActivity,
  pauseReadRequests,
  queueNextPoll,
  requestHubState,
  resolveRequestPolicy,
  runFeatureTask,
  isRequestCancelled,
  showToast,
  sleep,
  switchTab
});
})();
