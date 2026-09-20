// 运行记录、错误面板与诊断摘要；与请求/轮询公共层分离。
'use strict';
(() => {
  const state = { entries: [], maxEntries: 40 };

  function errorBlock(msg) {
    const el = document.createElement('div');
    el.className = 'error-panel';
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

  async function openAuditLog() {
    try {
      const data = await requireFeature('core').apiFetch(`${API.auditLog}?limit=80`, { timeoutMs: 5000 });
      const lines = Array.isArray(data?.lines) ? data.lines : [];
      const body = lines.length
        ? `<pre class="audit-log-pre">${requireFeature('core').escapeHtml(lines.join('\n'))}</pre>`
        : '<div class="energy-empty">暂无后台审计记录。</div>';
      requireFeature('ui').openDetail('后台审计日志', `<div class="detail-content"><p>仅显示已脱敏的结构化事件；原始请求、路径和设备隐私不会进入 WebUI。</p>${body}</div>`);
    } catch (err) {
      requireFeature('core').showToast(`后台日志读取失败：${err.message || err}`);
      appendLog(`后台日志读取失败：${err.message || err}`, 'err');
    }
  }

  registerFeature('diagnostics', { errorBlock, appendLog, clearLogs, openAuditLog });
})();
