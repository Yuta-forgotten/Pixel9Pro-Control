// 运行记录、错误面板与诊断摘要；与请求/轮询公共层分离。
'use strict';
(() => {
  const LOG_STORAGE_KEY = 'pixel9pro_runtime_log_v2';
  const state = { entries: [], maxEntries: 80, persistenceAvailable: true, auditSession: null, auditClearPending: false, lastPersistAt: 0 };
  const logText = (value, limit) => String(value ?? '').slice(0, limit);
  const logType = (value) => ['err', 'warn', 'ok', 'dim'].includes(value) ? value : '';

  function loadStoredLogs() {
    try {
      const raw = JSON.parse(localStorage.getItem(LOG_STORAGE_KEY) || '[]');
      if (!Array.isArray(raw)) return;
      state.entries = raw.filter((entry) => entry && typeof entry === 'object'
        && Number.isFinite(Number(entry.ts)) && Number(entry.ts) > 0
        && !Number.isNaN(new Date(Number(entry.ts)).getTime()))
        .slice(-state.maxEntries).map((entry) => ({
          ts: new Date(Number(entry.ts)), text: logText(entry.text || '—', 1024),
          type: logType(entry.type), detail: logText(entry.detail, 8192),
          count: Math.min(1000000, Math.max(1, Number(entry.count) || 1))
        }));
    } catch (_) { state.entries = []; state.persistenceAvailable = false; }
  }

  function persistLogs() {
    try {
      localStorage.setItem(LOG_STORAGE_KEY, JSON.stringify(state.entries.map((entry) => ({
        ts: entry.ts.getTime(), text: entry.text, type: entry.type, detail: entry.detail, count: entry.count || 1
      }))));
      state.persistenceAvailable = true;
      state.lastPersistAt = Date.now();
    } catch (_) { state.persistenceAvailable = false; }
  }

  function errorBlock(msg) {
    const el = document.createElement('div');
    el.className = 'error-panel';
    el.setAttribute('role', 'alert');
    const title = document.createElement('strong');
    title.textContent = '数据读取失败';
    const detail = document.createElement('pre');
    detail.textContent = String(msg || '未知错误');
    el.append(title, detail);
    return el;
  }

  function renderLogs() {
    if (!refs.logInner) return;
    refs.logInner.replaceChildren();
    if (!state.entries.length) {
      const empty = document.createElement('span');
      empty.className = 'log-dim'; empty.textContent = '等待操作…';
      refs.logInner.appendChild(empty);
      if (refs.logPreview) refs.logPreview.textContent = '暂无操作';
      if (refs.logMeta) refs.logMeta.textContent = state.persistenceAvailable ? '本页操作记录 · 最多 80 条' : '本页操作记录 · 关闭页面后可能丢失';
      return;
    }
    state.entries.forEach((entry) => {
      const row = document.createElement('div');
      row.className = `log-entry${entry.type ? ` log-${entry.type}` : ''}`;
      const time = document.createElement('time'); time.textContent = entry.ts.toLocaleTimeString();
      time.dateTime = entry.ts.toISOString(); time.title = entry.ts.toLocaleString();
      const copy = document.createElement('span'); copy.textContent = entry.text + (entry.count > 1 ? `（重复 ${entry.count} 次）` : '');
      row.append(time, copy);
      if (entry.type === 'err' && entry.detail) {
        const details = document.createElement('details');
        const summary = document.createElement('summary'); summary.textContent = '查看错误详情';
        const pre = document.createElement('pre'); pre.textContent = entry.detail;
        details.append(summary, pre); row.appendChild(details);
      }
      refs.logInner.appendChild(row);
    });
    const last = state.entries[state.entries.length - 1];
    if (refs.logPreview) refs.logPreview.textContent = `${last.type === 'err' ? '失败' : last.type === 'warn' ? '提示' : '最近'} · ${last.text}`;
    if (refs.logMeta) {
      const errors = state.entries.filter((entry) => entry.type === 'err').length;
      refs.logMeta.textContent = `${state.persistenceAvailable ? '本页操作记录' : '本页操作记录 · 未保存至浏览器'} · ${state.entries.length} 条${errors ? ` · ${errors} 条失败` : ''}`;
    }
    refs.logInner.scrollTop = refs.logInner.scrollHeight;
  }

  function appendLog(text, type = '', detail = '') {
    const last = state.entries[state.entries.length - 1];
    const normalizedText = logText(text ?? '—', 1024);
    const normalizedType = logType(type);
    if (last && ['err', 'warn'].includes(normalizedType) && last.type === normalizedType
      && last.text === normalizedText && Date.now() - last.ts.getTime() < 60000) {
      last.count = Math.min(1000000, (last.count || 1) + 1);
      last.ts = new Date();
      if (Date.now() - state.lastPersistAt > 30000) persistLogs();
      renderLogs();
      return;
    }
    state.entries.push({
      ts: new Date(), text: normalizedText, type: normalizedType, count: 1,
      detail: logText(detail || (type === 'err' ? text : ''), 8192)
    });
    if (state.entries.length > state.maxEntries) state.entries.splice(0, state.entries.length - state.maxEntries);
    persistLogs();
    renderLogs();
  }

  function clearLogs() {
    state.entries.length = 0;
    persistLogs();
    renderLogs();
    refs.logCard?.classList.remove('open');
    refs.logToggle?.setAttribute('aria-expanded', 'false');
  }

  function isCurrentAudit(session) {
    return state.auditSession === session && session.root.isConnected
      && requireFeature('ui').isDetailSessionActive(session.id);
  }

  function setAuditStatus(session, message, error = false) {
    if (!isCurrentAudit(session)) return;
    session.status.setAttribute('role', error ? 'alert' : 'status');
    session.status.className = error ? 'audit-log-status error-panel' : 'audit-log-status';
    session.status.textContent = message;
  }

  function setAuditBusy(session, busy) {
    session.busy = busy;
    if (!isCurrentAudit(session)) return;
    session.root.setAttribute('aria-busy', String(busy));
    session.refresh.disabled = busy || state.auditClearPending;
    session.export.disabled = busy || state.auditClearPending;
    session.clear.disabled = busy || state.auditClearPending;
  }

  function renderAuditLines(session, lines, emptyText = '暂无模块运行日志。') {
    if (!isCurrentAudit(session)) return;
    session.lines = lines;
    const content = document.createElement(lines.length ? 'pre' : 'p');
    content.className = lines.length ? 'audit-log-pre' : 'energy-empty';
    content.textContent = lines.length ? lines.join('\n') : emptyText;
    session.content.replaceChildren(content);
  }

  function validateAuditLines(data) {
    if (data?.ok !== true || !Array.isArray(data.lines)) throw new Error('未获取有效的模块运行日志');
    return data.lines.map((line) => String(line));
  }

  async function readAudit(session) {
    if (!isCurrentAudit(session) || session.busy || state.auditClearPending) return;
    const controller = new AbortController();
    session.controller = controller;
    setAuditBusy(session, true);
    setAuditStatus(session, '正在读取模块运行日志…');
    try {
      const data = await requireFeature('core').apiFetch(`${API.auditLog}?limit=80`, { timeoutMs: 5000, controller, priority: 'interactive', scope: 'diagnostics.audit.read' });
      if (!isCurrentAudit(session)) return;
      const lines = validateAuditLines(data);
      renderAuditLines(session, lines);
      setAuditStatus(session, `已读取 ${lines.length} 条记录。`);
    } catch (err) {
      if (!isCurrentAudit(session)) return;
      if (requireFeature('core').isRequestCancelled?.(err) || (controller.signal.aborted && !requireFeature('core').isWebUiActive())) {
        setAuditStatus(session, '日志读取已暂停，返回页面后可刷新。');
        return;
      }
      setAuditStatus(session, `模块日志读取失败：${err.message || err}。请刷新重试。`, true);
      appendLog(`模块日志读取失败：${err.message || err}`, 'err');
    } finally {
      if (session.controller === controller) session.controller = null;
      setAuditBusy(session, false);
    }
  }

  async function exportAudit(session) {
    if (!isCurrentAudit(session) || session.busy || state.auditClearPending) return;
    const controller = new AbortController();
    session.controller = controller;
    setAuditBusy(session, true);
    setAuditStatus(session, '正在准备导出模块日志…');
    try {
      const data = await requireFeature('core').apiFetch(`${API.auditLog}?all=1&limit=2000`, { timeoutMs: 5000, controller, priority: 'interactive', scope: 'diagnostics.audit.read' });
      if (!isCurrentAudit(session)) return;
      const lines = validateAuditLines(data);
      const blob = new Blob([lines.join('\n') + '\n'], { type: 'text/plain;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = 'pixel9pro-audit-log.txt';
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      window.setTimeout(() => URL.revokeObjectURL(url), 1000);
      setAuditStatus(session, `已导出 ${lines.length} 条模块运行日志。`);
      requireFeature('core').showToast('模块运行日志已导出');
    } catch (err) {
      if (isCurrentAudit(session)) {
        const paused = requireFeature('core').isRequestCancelled?.(err) || (controller.signal.aborted && !requireFeature('core').isWebUiActive());
        setAuditStatus(session, paused ? '日志导出已暂停，返回页面后可重试。' : `导出失败：${err.message || err}。可重新导出。`, !paused);
      }
    } finally {
      if (session.controller === controller) session.controller = null;
      setAuditBusy(session, false);
    }
  }

  async function clearAudit(session) {
    if (!isCurrentAudit(session) || session.busy || state.auditClearPending) return;
    if (!window.confirm('确认清空模块运行日志？此操作不可撤销；本页操作记录保留。')) return;
    state.auditClearPending = true;
    setAuditBusy(session, true);
    setAuditStatus(session, '正在清空模块运行日志…');
    let committed = false;
    try {
      // A dispatched write may finish after close. Keep its global busy guard;
      // never abort/retry it automatically or let it update another detail.
      const data = await requireFeature('core').apiFetch(API.auditLog, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'clear' }), timeoutMs: 5000, priority: 'interactive', scope: 'diagnostics.audit'
      });
      if (data?.ok !== true || data.action !== 'clear') throw new Error(data?.error || '模块未确认日志清空结果');
      committed = true;
      renderAuditLines(session, [], '日志已清空，正在确认结果…');
      const readback = await requireFeature('core').apiFetch(`${API.auditLog}?limit=80`, { timeoutMs: 5000, priority: 'normal', scope: 'diagnostics.audit.read' });
      const lines = validateAuditLines(readback);
      if (isCurrentAudit(session)) {
        renderAuditLines(session, lines);
        setAuditStatus(session, lines.length
          ? `旧日志已清空，当前新增 ${lines.length} 条记录。`
          : '模块运行日志已清空，当前无记录。');
        requireFeature('core').showToast('模块运行日志已清空并确认');
      }
      appendLog('模块运行日志已清空并确认', 'ok');
    } catch (err) {
      const message = committed
        ? `清空请求已提交，但结果读取失败：${err.message || err}。请刷新确认。`
        : `清空结果未确认：${err.message || err}。请先刷新日志，再重试。`;
      setAuditStatus(session, message, true);
      appendLog(message, 'err');
    } finally {
      state.auditClearPending = false;
      setAuditBusy(session, false);
      const current = state.auditSession;
      if (current && current !== session && isCurrentAudit(current)) readAudit(current);
    }
  }

  async function openAuditLog() {
    if (state.auditSession && isCurrentAudit(state.auditSession)) return;
    requireFeature('ui').openDetail('模块运行日志',
      '<div class="detail-content" id="audit-log-view">'
      + '<p>记录模块后台运行事件。本页操作记录单独保存。</p>'
      + '<div class="audit-log-actions"><button class="tiny-btn tonal" id="audit-log-refresh" type="button">刷新记录</button>'
      + '<button class="tiny-btn tonal" id="audit-log-export" type="button">导出记录</button>'
      + '<button class="tiny-btn danger-btn" id="audit-log-clear" type="button">清空模块日志</button></div>'
      + '<p class="audit-log-status" id="audit-log-status" role="status"></p>'
      + '<div id="audit-log-content"></div></div>');
    const session = {
      id: requireFeature('ui').getDetailSession(), root: document.getElementById('audit-log-view'),
      status: document.getElementById('audit-log-status'), content: document.getElementById('audit-log-content'),
      refresh: document.getElementById('audit-log-refresh'), export: document.getElementById('audit-log-export'),
      clear: document.getElementById('audit-log-clear'), lines: [], busy: false, controller: null
    };
    state.auditSession = session;
    session.refresh.addEventListener('click', () => readAudit(session));
    session.export.addEventListener('click', () => exportAudit(session));
    session.clear.addEventListener('click', () => clearAudit(session));
    if (state.auditClearPending) {
      setAuditBusy(session, false);
      setAuditStatus(session, '正在确认上次日志清空结果…');
      return;
    }
    await readAudit(session);
  }

  document.addEventListener('pixel:detail-session', () => {
    const session = state.auditSession;
    if (!session) return;
    session.controller?.abort('audit-detail-closed');
    state.auditSession = null;
  });
  const pauseAuditRead = () => state.auditSession?.controller?.abort('audit-page-hidden');
  document.addEventListener('visibilitychange', () => { if (document.hidden) pauseAuditRead(); });
  document.addEventListener('freeze', pauseAuditRead);
  window.addEventListener('pagehide', pauseAuditRead);

  loadStoredLogs();
  registerFeature('diagnostics', { initialize: renderLogs, errorBlock, appendLog, clearLogs, openAuditLog });
})();
