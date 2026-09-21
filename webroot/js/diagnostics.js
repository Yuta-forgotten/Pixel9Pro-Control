// 运行记录、错误面板与诊断摘要；与请求/轮询公共层分离。
'use strict';
(() => {
  const state = { entries: [], maxEntries: 40, auditSession: null, auditClearPending: false };

  function errorBlock(msg) {
    const el = document.createElement('div');
    el.className = 'error-panel';
    el.setAttribute('role', 'alert');
    const title = document.createElement('strong');
    title.textContent = '读取失败';
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
      if (refs.logMeta) refs.logMeta.textContent = '本次会话 · 最多保留 40 条';
      return;
    }
    state.entries.forEach((entry) => {
      const row = document.createElement('div');
      row.className = `log-entry${entry.type ? ` log-${entry.type}` : ''}`;
      const time = document.createElement('time'); time.textContent = entry.ts.toLocaleTimeString();
      const copy = document.createElement('span'); copy.textContent = entry.text;
      row.append(time, copy);
      if (entry.type === 'err' && entry.detail) {
        const details = document.createElement('details');
        const summary = document.createElement('summary'); summary.textContent = '查看完整报错';
        const pre = document.createElement('pre'); pre.textContent = entry.detail;
        details.append(summary, pre); row.appendChild(details);
      }
      refs.logInner.appendChild(row);
    });
    const last = state.entries[state.entries.length - 1];
    if (refs.logPreview) refs.logPreview.textContent = `${last.type === 'err' ? '失败' : last.type === 'warn' ? '需注意' : '最近'} · ${last.text}`;
    if (refs.logMeta) {
      const errors = state.entries.filter((entry) => entry.type === 'err').length;
      refs.logMeta.textContent = `本次会话 · ${state.entries.length} 条${errors ? ` · ${errors} 条失败` : ''}`;
    }
    refs.logInner.scrollTop = refs.logInner.scrollHeight;
  }

  function appendLog(text, type = '', detail = '') {
    state.entries.push({
      ts: new Date(), text: String(text ?? '—'), type: String(type || ''),
      detail: String(detail || (type === 'err' ? text : ''))
    });
    if (state.entries.length > state.maxEntries) state.entries.splice(0, state.entries.length - state.maxEntries);
    renderLogs();
  }

  function clearLogs() {
    state.entries.length = 0;
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

  function renderAuditLines(session, lines, emptyText = '暂无后台审计记录。') {
    if (!isCurrentAudit(session)) return;
    session.lines = lines;
    const content = document.createElement(lines.length ? 'pre' : 'p');
    content.className = lines.length ? 'audit-log-pre' : 'energy-empty';
    content.textContent = lines.length ? lines.join('\n') : emptyText;
    session.content.replaceChildren(content);
  }

  function validateAuditLines(data) {
    if (data?.ok !== true || !Array.isArray(data.lines)) throw new Error('后台未返回有效审计记录');
    return data.lines.map((line) => String(line));
  }

  async function readAudit(session) {
    if (!isCurrentAudit(session) || session.busy || state.auditClearPending) return;
    const controller = new AbortController();
    session.controller = controller;
    setAuditBusy(session, true);
    setAuditStatus(session, '正在读取后台审计记录…');
    try {
      const data = await requireFeature('core').apiFetch(`${API.auditLog}?limit=80`, { timeoutMs: 5000, controller });
      if (!isCurrentAudit(session)) return;
      const lines = validateAuditLines(data);
      renderAuditLines(session, lines);
      setAuditStatus(session, `已读取 ${lines.length} 条记录。`);
    } catch (err) {
      if (!isCurrentAudit(session)) return;
      if (controller.signal.aborted && !requireFeature('core').isWebUiActive()) {
        setAuditStatus(session, '读取已暂停。返回后可点“刷新记录”继续。');
        return;
      }
      setAuditStatus(session, `后台日志读取失败：${err.message || err}。可点“刷新记录”重试。`, true);
      appendLog(`后台日志读取失败：${err.message || err}`, 'err');
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
    setAuditStatus(session, '正在准备可用审计记录…');
    try {
      const data = await requireFeature('core').apiFetch(`${API.auditLog}?all=1&limit=2000`, { timeoutMs: 5000, controller });
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
      setAuditStatus(session, `已导出后台可用的 ${lines.length} 条审计记录。`);
      requireFeature('core').showToast('后台审计记录已导出');
    } catch (err) {
      if (isCurrentAudit(session)) {
        const paused = controller.signal.aborted && !requireFeature('core').isWebUiActive();
        setAuditStatus(session, paused ? '导出准备已暂停。返回后可重新导出。' : `导出失败：${err.message || err}。可重新导出。`, !paused);
      }
    } finally {
      if (session.controller === controller) session.controller = null;
      setAuditBusy(session, false);
    }
  }

  async function clearAudit(session) {
    if (!isCurrentAudit(session) || session.busy || state.auditClearPending) return;
    if (!window.confirm('确认清理模块后台审计记录？此操作不可撤销，本页操作记录不会受影响。')) return;
    state.auditClearPending = true;
    setAuditBusy(session, true);
    setAuditStatus(session, '正在清理并重新读取后台审计记录…');
    let committed = false;
    try {
      // A dispatched write may finish after close. Keep its global busy guard;
      // never abort/retry it automatically or let it update another detail.
      const data = await requireFeature('core').apiFetch(API.auditLog, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'clear' }), timeoutMs: 5000
      });
      if (data?.ok !== true || data.action !== 'clear') throw new Error(data?.error || '后台未确认清理结果');
      committed = true;
      renderAuditLines(session, [], '清理请求已成功，正在回读后台记录…');
      const readback = await requireFeature('core').apiFetch(`${API.auditLog}?limit=80`, { timeoutMs: 5000 });
      const lines = validateAuditLines(readback);
      if (isCurrentAudit(session)) {
        renderAuditLines(session, lines);
        setAuditStatus(session, lines.length
          ? `已清理并回读；后台当前有 ${lines.length} 条新记录。`
          : '后台审计记录已清理，回读确认当前为空。');
        requireFeature('core').showToast('后台审计记录已清理并回读');
      }
      appendLog('后台审计记录已清理并回读', 'ok');
    } catch (err) {
      const message = committed
        ? `清理已提交，但回读失败：${err.message || err}。旧记录已隐藏，请刷新确认。`
        : `清理结果未确认：${err.message || err}。请先刷新记录核对，再决定是否重试。`;
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
    requireFeature('ui').openDetail('后台审计日志',
      '<div class="detail-content" id="audit-log-view">'
      + '<p>显示模块后台的脱敏事件。本页操作记录与后台审计记录分别保存。</p>'
      + '<div class="audit-log-actions"><button class="tiny-btn tonal" id="audit-log-refresh" type="button">刷新记录</button>'
      + '<button class="tiny-btn tonal" id="audit-log-export" type="button">导出记录</button>'
      + '<button class="tiny-btn danger-btn" id="audit-log-clear" type="button">清理后台记录</button></div>'
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
      setAuditStatus(session, '正在确认先前的清理结果…');
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

  registerFeature('diagnostics', { errorBlock, appendLog, clearLogs, openAuditLog });
})();
