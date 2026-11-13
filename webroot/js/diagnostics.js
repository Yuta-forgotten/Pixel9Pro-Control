// 有界页面记录、关键摘要与只读日志查看器；通信和解析分别由共享层负责。
'use strict';
(() => {
  const LOG_STORAGE_KEY = 'pixel9pro_runtime_log_v3';
  const LEGACY_STORAGE_KEY = 'pixel9pro_runtime_log_v2';
  const LEVELS = { err: 'error', warn: 'warning', ok: 'success', dim: 'info', '': 'info' };
  const LEVEL_LABELS = { error: '错误', warning: '提示', success: '成功', info: '信息' };
  const LEVEL_CLASSES = { error: 'err', warning: 'warn', success: 'ok', info: 'dim' };
  const state = { entries: [], summaries: [], clearedAt: 0, dirty: false, persistTimer: null,
    persistenceAvailable: true, auditSession: null, auditClearPending: false, rows: new Map(), sequence: 0, logInitialized: false };
  const instance = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 9)}`;
  const text = (value, limit = 1024) => String(value ?? '').slice(0, limit);
  const model = () => requireFeature('logModel');
  const core = () => requireFeature('core');
  const timeText = (ts) => ts === null ? '时间未知' : new Date(ts).toLocaleString();

  function normalizeSummary(entry) {
    if (!entry || typeof entry !== 'object' || typeof entry.id !== 'string' || entry.id.length > 128
      || !Number.isSafeInteger(entry.ts) || entry.ts <= 0 || Number.isNaN(new Date(entry.ts).getTime())
      || !Object.hasOwn(LEVEL_LABELS, entry.level)) return null;
    const firstTs = Number.isSafeInteger(entry.firstTs) && entry.firstTs > 0 && entry.firstTs <= entry.ts ? entry.firstTs : entry.ts;
    return { id: entry.id, ts: entry.ts, firstTs, lastTs: entry.ts, level: entry.level, source: 'page',
      phase: text(entry.phase, 256), operation: text(entry.operation, 256), result: text(entry.result, 256),
      code: text(entry.code, 256), message: text(entry.message), detail: '',
      durationMs: Number.isSafeInteger(entry.durationMs) && entry.durationMs >= 0 ? entry.durationMs : null,
      count: Number.isSafeInteger(entry.count) && entry.count > 0 ? Math.min(entry.count, 1000000) : 1 };
  }

  function readSummaryStore(raw) {
    if (!raw) return { clearedAt: 0, entries: [] };
    const data = JSON.parse(raw);
    if (data?.schema !== 3 || !Array.isArray(data.entries) || data.entries.length > 32
      || !Number.isSafeInteger(data.clearedAt) || data.clearedAt < 0) throw new Error('浏览器日志摘要格式无效');
    return { clearedAt: data.clearedAt, entries: data.entries.map(normalizeSummary).filter(Boolean) };
  }

  function mergeSummaries(incoming) {
    state.clearedAt = Math.max(state.clearedAt, incoming.clearedAt);
    const merged = new Map();
    [...incoming.entries, ...state.summaries].forEach((entry) => {
      if (entry.ts <= state.clearedAt) return;
      const previous = merged.get(entry.id);
      if (!previous || entry.ts >= previous.ts) merged.set(entry.id, entry);
    });
    state.summaries = [...merged.values()].sort((a, b) => a.ts - b.ts).slice(-32);
    const memory = new Map(state.entries.filter((entry) => entry.ts > state.clearedAt).map((entry) => [entry.id, entry]));
    state.summaries.forEach((entry) => {
      const previous = memory.get(entry.id);
      if (!previous) memory.set(entry.id, { ...entry });
      else if (entry.ts > previous.ts) memory.set(entry.id, { ...entry, detail: previous.detail });
    });
    state.entries = [...memory.values()].sort((a, b) => a.ts - b.ts).slice(-200);
  }

  function flushSummaries() {
    clearTimeout(state.persistTimer); state.persistTimer = null;
    if (!state.dirty) return;
    try {
      mergeSummaries(readSummaryStore(localStorage.getItem(LOG_STORAGE_KEY)));
      // Detailed payloads never enter the persistent summary store.
      const entries = state.summaries.map(({ detail, ...entry }) => entry);
      localStorage.setItem(LOG_STORAGE_KEY, JSON.stringify({ schema: 3, clearedAt: state.clearedAt, entries }));
      state.dirty = false; state.persistenceAvailable = true;
    } catch (_) { state.persistenceAvailable = false; }
  }

  function scheduleSummaryWrite() {
    state.dirty = true;
    if (state.persistTimer === null) state.persistTimer = window.setTimeout(flushSummaries, 15000);
  }

  function loadStoredLogs() {
    try {
      const current = localStorage.getItem(LOG_STORAGE_KEY);
      if (current !== null) mergeSummaries(readSummaryStore(current));
      else {
        const legacy = JSON.parse(localStorage.getItem(LEGACY_STORAGE_KEY) || '[]');
        if (!Array.isArray(legacy)) throw new Error('旧日志格式无效');
        const entries = legacy.filter((entry) => entry && ['err', 'ok'].includes(entry.type)).slice(-32)
          .map((entry, index) => normalizeSummary({ id: `legacy-${entry.ts}-${index}`, ts: Number(entry.ts),
            message: entry.text, level: LEVELS[entry.type], count: Number(entry.count) || 1, phase: 'page',
            operation: 'legacy', code: '', result: entry.type === 'err' ? 'failure' : 'success' })).filter(Boolean);
        mergeSummaries({ clearedAt: 0, entries });
        if (entries.length) scheduleSummaryWrite();
      }
    } catch (_) { state.persistenceAvailable = false; }
  }

  function errorBlock(message) {
    const el = document.createElement('div'); el.className = 'error-panel'; el.setAttribute('role', 'alert');
    const title = document.createElement('strong'); title.textContent = '数据读取失败';
    const detail = document.createElement('pre'); detail.textContent = String(message || '未知错误');
    el.append(title, detail); return el;
  }

  function createLogRow() {
    const row = document.createElement('div'); const time = document.createElement('time');
    const copy = document.createElement('span'); const details = document.createElement('details');
    const summary = document.createElement('summary'); summary.textContent = '查看详情';
    const pre = document.createElement('pre'); details.append(summary, pre); row.append(time, copy, details);
    return { row, time, copy, details, pre };
  }

  function updateLogRow(nodes, entry) {
    nodes.row.className = `log-entry log-${LEVEL_CLASSES[entry.level]}`;
    nodes.time.textContent = entry.ts === null ? '时间未知' : new Date(entry.ts).toLocaleTimeString();
    nodes.time.dateTime = entry.ts === null ? '' : new Date(entry.ts).toISOString(); nodes.time.title = timeText(entry.ts);
    nodes.copy.textContent = `${entry.message}${entry.count > 1 ? `（${entry.count} 次）` : ''}`;
    nodes.details.hidden = !entry.detail; nodes.pre.textContent = entry.detail;
  }

  function renderLogs() {
    if (!refs.logInner || document.hidden) return;
    if (!state.logInitialized) { refs.logInner.replaceChildren(); state.logInitialized = true; }
    const keep = new Set();
    state.entries.forEach((entry, index) => {
      keep.add(entry.id);
      let nodes = state.rows.get(entry.id);
      if (!nodes) { nodes = createLogRow(); state.rows.set(entry.id, nodes); }
      updateLogRow(nodes, entry);
      if (refs.logInner.children[index] !== nodes.row) refs.logInner.insertBefore(nodes.row, refs.logInner.children[index] || null);
    });
    state.rows.forEach((nodes, id) => { if (!keep.has(id)) { nodes.row.remove(); state.rows.delete(id); } });
    const last = state.entries[state.entries.length - 1];
    if (refs.logPreview) refs.logPreview.textContent = last ? `${LEVEL_LABELS[last.level]} · ${last.message}` : '暂无操作';
    if (refs.logMeta) refs.logMeta.textContent = `本页 ${state.entries.length} 条 · 关键摘要 ${state.summaries.length}/32${state.persistenceAvailable ? '' : ' · 摘要未保存'}`;
  }

  function appendLog(message, type = '', detail = '', metadata = {}) {
    const now = Math.max(Date.now(), state.clearedAt + 1); const level = LEVELS[type] || 'info'; const normalized = text(message || '—');
    const operation = text(metadata.operation || 'page', 256); const code = text(metadata.code, 256);
    const previous = [...state.entries].reverse().find((entry) => entry.level === level && entry.message === normalized
      && entry.operation === operation && entry.code === code && now - entry.ts < 60000);
    const entry = previous || { id: `${instance}-${++state.sequence}`, firstTs: now, count: 0 };
    Object.assign(entry, { ts: now, lastTs: now, level, source: 'page', phase: text(metadata.phase || 'page', 256), operation,
      result: level === 'error' ? 'failure' : level === 'success' ? 'success' : level === 'warning' ? 'warning' : 'info',
      code, message: normalized, detail: text(detail || (type === 'err' ? message : ''), 8192),
      durationMs: Number.isSafeInteger(metadata.durationMs) && metadata.durationMs >= 0 ? metadata.durationMs : null,
      count: Math.min(entry.count + 1, 1000000) });
    state.entries = state.entries.filter((item) => item !== entry); state.entries.push(entry); state.entries = state.entries.slice(-200);
    const persistent = metadata.persistent === true || (metadata.persistent !== false && ['error', 'success'].includes(level));
    if (persistent && !previous) {
      state.summaries = state.summaries.filter((item) => item.id !== entry.id);
      state.summaries.push({ ...entry, detail: '' }); state.summaries = state.summaries.slice(-32); scheduleSummaryWrite();
    }
    renderLogs();
    const session = state.auditSession;
    if (session && isCurrentAudit(session) && session.source.value === 'page') { session.snapshot = pageSnapshot(); renderViewer(session); }
  }

  function clearLogs() {
    state.entries = []; state.summaries = []; state.clearedAt = Date.now(); state.dirty = true;
    flushSummaries(); renderLogs();
    const session = state.auditSession;
    if (session && isCurrentAudit(session) && session.source.value === 'page') { session.snapshot = pageSnapshot(); renderViewer(session); }
  }

  function snapshot(source, entries, extra = {}) {
    return { schema: 'pixel9pro.logs.v1', exportedAt: Date.now(), source, range: model().stats(entries).timeRange,
      truncated: false, invalidCount: 0, unsupportedCount: 0, entries, ...extra };
  }
  function pageSnapshot() { return snapshot('page', state.entries.map((entry) => ({ ...entry })), { truncated: true }); }
  function isCurrentAudit(session) {
    return state.auditSession === session && session.root.isConnected && requireFeature('ui').isDetailSessionActive(session.id);
  }
  function currentAction(session, revision) { return isCurrentAudit(session) && session.revision === revision; }

  function setStatus(session, message, error = false) {
    if (!isCurrentAudit(session)) return;
    session.status.setAttribute('role', error ? 'alert' : 'status');
    session.status.className = error ? 'audit-log-status error-panel' : 'audit-log-status'; session.status.textContent = message;
  }
  function setBusy(session, busy) {
    session.busy = busy;
    if (!isCurrentAudit(session)) return;
    session.root.setAttribute('aria-busy', String(busy));
    session.refresh.disabled = busy || session.source.value === 'import' || state.auditClearPending;
    session.export.disabled = busy || !session.snapshot || state.auditClearPending;
    session.import.disabled = busy;
    session.clear.disabled = busy || session.source.value !== 'module' || state.auditClearPending;
    session.next.disabled = busy || !session.page?.truncated || session.source.value !== 'module';
  }
  function beginAction(session) {
    session.controller?.abort('audit-action-replaced'); session.controller = new AbortController();
    session.revision += 1; setBusy(session, true); return session.revision;
  }

  function renderViewer(session) {
    if (!isCurrentAudit(session) || document.hidden) return;
    const all = session.snapshot?.entries || []; const keyword = session.search.value.trim().toLocaleLowerCase();
    const entries = all.filter((entry) => (!session.level.value || entry.level === session.level.value)
      && (!keyword || [entry.message, entry.operation, entry.code, entry.detail].some((part) => part.toLocaleLowerCase().includes(keyword))));
    const summary = model().stats(entries);
    const sourceText = session.source.value === 'page' ? '本页内存记录及关键摘要，不代表全部历史'
      : session.source.value === 'import' ? '导入快照 · 仅在本页查看，来源完整性未验证'
        : !session.snapshot ? '尚未读取模块日志'
          : `已读取 ${all.length}/${session.page?.total_lines ?? all.length} 条${session.snapshot.truncated ? ' · 当前样本' : ' · 当前快照完整'}`;
    session.summary.textContent = `${sourceText}。当前筛选：${summary.recordCount} 条记录，${summary.eventCount} 次事件；错误 ${summary.levels.error}，提示 ${summary.levels.warning}，成功 ${summary.levels.success}，信息 ${summary.levels.info}。`;
    session.range.textContent = summary.timeRange.start === null ? '时间范围：无有效时间'
      : `时间范围：${timeText(summary.timeRange.start)} — ${timeText(summary.timeRange.end)}`;
    const problems = summary.errors.slice(0, 5).map((item) => `${item.code || '未分类'} ${item.count} 次`).join('；');
    session.problems.textContent = `问题分类：${problems || '无错误记录'}${session.snapshot?.invalidCount ? `；无法解析 ${session.snapshot.invalidCount} 条` : ''}${session.snapshot?.unsupportedCount ? `；不支持的格式 ${session.snapshot.unsupportedCount} 条` : ''}`;
    const operations = summary.operations.slice(0, 5).map((item) => `${item.operation || '未分类'} ${item.count} 次`).join('；');
    session.operations.textContent = `操作统计：${operations || '暂无记录'}${summary.duration.sampleCount ? `；耗时样本 ${summary.duration.sampleCount} 条，平均 ${Math.round(summary.duration.averageMs)} 毫秒，最长 ${summary.duration.maxMs} 毫秒` : ''}`;
    const visible = entries.slice(0, session.visibleCount); const keep = new Set();
    visible.forEach((entry, index) => {
      const id = entry.id || `${session.source.value}:${index}:${entry.ts}`; keep.add(id);
      let nodes = session.rows.get(id);
      if (!nodes) { nodes = createLogRow(); session.rows.set(id, nodes); }
      updateLogRow(nodes, entry);
      if (session.content.children[index] !== nodes.row) session.content.insertBefore(nodes.row, session.content.children[index] || null);
    });
    session.rows.forEach((nodes, id) => { if (!keep.has(id)) { nodes.row.remove(); session.rows.delete(id); } });
    session.more.hidden = visible.length >= entries.length; session.more.textContent = `显示更多（${visible.length}/${entries.length}）`;
    session.next.hidden = session.source.value !== 'module' || !session.page?.truncated; setBusy(session, session.busy);
  }

  function validatePage(data, offset, expectedId = null, expectedTotal = null) {
    if (data?.ok !== true || data.schema !== 2 || data.source !== 'structured_audit'
      || !Array.isArray(data.lines) || data.lines.length > 500 || data.lines.some((line) => typeof line !== 'string')
      || data.offset !== offset || !Number.isSafeInteger(data.total_lines) || data.total_lines < 0
      || typeof data.snapshot_id !== 'string' || !/^[0-9a-f]{64}$/.test(data.snapshot_id)
      || (expectedId !== null && data.snapshot_id !== expectedId) || (expectedTotal !== null && data.total_lines !== expectedTotal)
      || typeof data.complete !== 'boolean' || typeof data.truncated !== 'boolean' || data.complete === data.truncated
      || offset + data.lines.length > data.total_lines
      || (data.complete ? data.next_offset !== null || offset + data.lines.length !== data.total_lines
        : data.lines.length === 0 || data.next_offset !== offset + data.lines.length || data.next_offset >= data.total_lines)) {
      throw new Error('模块日志分页结果无效，未合并记录');
    }
    return data;
  }
  async function fetchPage(session, offset = 0, id = null, total = null) {
    const query = `all=1&limit=500&offset=${offset}${id ? `&snapshot_id=${encodeURIComponent(id)}` : ''}`;
    const data = await core().apiFetch(`${API.auditLog}?${query}`, { timeoutMs: 10000, controller: session.controller,
      requestClass: 'diagnostic', priority: 'interactive', scope: 'diagnostics.audit.read', dedupe: false });
    return validatePage(data, offset, id, total);
  }
  function actionError(session, revision, error, label) {
    if (!currentAction(session, revision)) return;
    const changed = error?.payload?.error_code === 'AUDIT_SNAPSHOT_CHANGED';
    const message = changed ? '日志已更新，本次读取未合并。请重新刷新或导出。'
      : core().isRequestCancelled?.(error) ? '读取已暂停，可重新操作。' : `${label}：${error?.message || error}`;
    setStatus(session, message, !core().isRequestCancelled?.(error));
    appendLog(message, 'warn', '', { persistent: false, operation: 'logs.read', code: error?.payload?.error_code || '' });
  }

  async function readAudit(session, more = false) {
    if (!isCurrentAudit(session) || session.busy || state.auditClearPending) return;
    if (session.source.value === 'page') { session.snapshot = pageSnapshot(); renderViewer(session); return; }
    if (session.source.value !== 'module') return;
    const revision = beginAction(session); setStatus(session, '正在读取模块日志…');
    try {
      const previous = more ? session.page : null;
      const page = await fetchPage(session, previous?.next_offset || 0, previous?.snapshot_id || null, previous?.total_lines ?? null);
      if (!currentAction(session, revision)) return;
      const parsed = model().parseAudit(page.lines);
      const entries = previous ? [...session.snapshot.entries, ...parsed.entries] : parsed.entries;
      if (entries.length > model().limits.maxEntries) throw new Error('日志数量超过本页查看上限');
      session.snapshot = snapshot('module', entries, { truncated: page.truncated,
        invalidCount: parsed.invalidCount + (previous ? session.snapshot.invalidCount : 0),
        unsupportedCount: parsed.unsupportedCount + (previous ? session.snapshot.unsupportedCount : 0) });
      session.page = page; renderViewer(session);
      setStatus(session, `已读取 ${entries.length} 条${page.truncated ? '，可继续读取或导出完整快照' : '，当前快照已完整读取'}。`);
    } catch (error) { actionError(session, revision, error, '日志读取失败'); }
    finally { if (currentAction(session, revision)) { session.controller = null; setBusy(session, false); } }
  }

  async function exportAudit(session) {
    if (!isCurrentAudit(session) || session.busy || !session.snapshot || state.auditClearPending) return;
    const revision = beginAction(session); setStatus(session, '正在生成导出文件…');
    try {
      let output = session.source.value === 'page' ? pageSnapshot() : session.snapshot;
      if (session.source.value === 'module') {
        let page = await fetchPage(session);
        if (!currentAction(session, revision)) return;
        if (page.total_lines > model().limits.maxLines) throw new Error('日志数量超过单次导出上限');
        const lines = [...page.lines]; let bytes = new TextEncoder().encode(page.lines.join('\n')).length;
        while (!page.complete) {
          page = await fetchPage(session, page.next_offset, page.snapshot_id, page.total_lines);
          if (!currentAction(session, revision)) return;
          bytes += new TextEncoder().encode(page.lines.join('\n')).length + 1;
          if (bytes > model().limits.maxBytes) throw new Error('日志超过单次导出大小上限');
          lines.push(...page.lines); setStatus(session, `正在读取完整日志：${lines.length}/${page.total_lines} 条…`);
        }
        const parsed = model().parseAudit(lines); output = snapshot('module', parsed.entries, parsed);
      }
      const format = session.format.value;
      const serialized = format === 'json' ? model().exportJson(output) : model().exportText(output);
      if (new TextEncoder().encode(serialized).length > model().limits.maxBytes) throw new Error('导出文件超过大小上限');
      const url = URL.createObjectURL(new Blob([serialized], { type: format === 'json' ? 'application/json;charset=utf-8' : 'text/plain;charset=utf-8' }));
      const anchor = document.createElement('a'); anchor.href = url;
      anchor.download = `pixel9pro-${session.source.value}-logs.${format === 'json' ? 'json' : 'txt'}`;
      document.body.appendChild(anchor); anchor.click(); anchor.remove(); window.setTimeout(() => URL.revokeObjectURL(url), 1000);
      setStatus(session, `已生成 ${output.entries.length} 条记录的导出文件，并发起下载。`); core().showToast('日志文件已生成');
    } catch (error) { actionError(session, revision, error, '导出失败'); }
    finally { if (currentAction(session, revision)) { session.controller = null; setBusy(session, false); } }
  }

  async function importLogs(session, file) {
    if (!file || !isCurrentAudit(session) || session.busy) return;
    const revision = beginAction(session); setStatus(session, '正在读取导入文件…');
    try {
      if (file.size > model().limits.maxBytes) throw new Error('日志文件不能超过 8 MiB');
      const content = await file.text();
      if (!currentAction(session, revision)) return;
      session.imported = model().parseImport(content, file.name);
      session.source.value = 'import'; session.snapshot = session.imported; session.page = null; session.visibleCount = 100;
      renderViewer(session); setStatus(session, '已载入只读快照，不会写入模块或本页运行记录。');
    } catch (error) { actionError(session, revision, error, '导入失败'); }
    finally { if (currentAction(session, revision)) { session.file.value = ''; session.controller = null; setBusy(session, false); } }
  }

  async function clearAudit(session) {
    if (!isCurrentAudit(session) || session.busy || state.auditClearPending || session.source.value !== 'module') return;
    if (!window.confirm('确认清空模块日志？此操作不可撤销，本页记录和导入快照保留。')) return;
    state.auditClearPending = true; const revision = beginAction(session); setStatus(session, '正在清空模块日志…');
    let committed = false;
    try {
      const data = await core().apiFetch(API.auditLog, { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'clear' }), requestClass: 'mutation', timeoutMs: 10000, priority: 'interactive', scope: 'diagnostics.audit' });
      if (data?.ok !== true || data.action !== 'clear') throw new Error('模块未确认清空结果');
      committed = true;
      appendLog('模块日志已清空', 'ok', '', { operation: 'logs.clear' });
      if (currentAction(session, revision)) { session.snapshot = null; session.page = null; renderViewer(session); setStatus(session, '模块日志已清空。'); }
    } catch (error) {
      if (currentAction(session, revision)) setStatus(session, `清空结果未确认：${error.message || error}。请先刷新查看。`, true);
      appendLog('模块日志清空结果未确认', 'err', error.message || String(error), { operation: 'logs.clear' });
    } finally {
      state.auditClearPending = false;
      if (currentAction(session, revision)) {
        session.controller = null; setBusy(session, false);
        if (committed && core().isWebUiActive()) await readAudit(session);
      } else if (state.auditSession && isCurrentAudit(state.auditSession)) {
        setBusy(state.auditSession, state.auditSession.busy);
      }
    }
  }

  function selectSource(session) {
    session.controller?.abort('audit-source-changed'); session.revision += 1; session.controller = null;
    session.page = null; session.visibleCount = 100; session.busy = false;
    session.snapshot = session.source.value === 'page' ? pageSnapshot() : session.source.value === 'import' ? session.imported : null;
    renderViewer(session); setBusy(session, false);
    if (session.source.value === 'module') void readAudit(session);
    else setStatus(session, session.source.value === 'import' && !session.imported ? '请选择日志文件导入。' : '筛选与统计仅针对当前记录范围。');
  }

  async function openAuditLog() {
    if (state.auditSession && isCurrentAudit(state.auditSession)) return;
    requireFeature('ui').openDetail('日志', '<div class="detail-content" id="audit-log-view">'
      + '<p>仅保留少量关键摘要。详细记录在本页内存中，关闭页面后不再保留。</p>'
      + '<div class="audit-log-actions"><label>来源 <select id="audit-log-source"><option value="page">本页记录</option><option value="module" selected>模块日志</option><option value="import">导入快照</option></select></label>'
      + '<button class="tiny-btn tonal" id="audit-log-refresh" type="button">刷新</button><button class="tiny-btn tonal" id="audit-log-import" type="button">导入</button>'
      + '<input id="audit-log-file" type="file" accept=".json,.txt,application/json,text/plain" hidden>'
      + '<label>格式 <select id="audit-log-format"><option value="json">JSON</option><option value="txt">TXT</option></select></label>'
      + '<button class="tiny-btn tonal" id="audit-log-export" type="button">导出</button><button class="tiny-btn danger-btn" id="audit-log-clear" type="button">清空模块日志</button></div>'
      + '<div class="audit-log-actions"><label>级别 <select id="audit-log-level"><option value="">全部</option><option value="error">错误</option><option value="warning">提示</option><option value="success">成功</option><option value="info">信息</option></select></label>'
      + '<label>查找 <input id="audit-log-search" type="search" maxlength="256" placeholder="搜索记录"></label></div>'
      + '<p id="audit-log-summary"></p><p id="audit-log-range"></p><p id="audit-log-problems"></p><p id="audit-log-operations"></p>'
      + '<p class="audit-log-status" id="audit-log-status" role="status" aria-live="polite"></p><div id="audit-log-content"></div>'
      + '<div class="audit-log-actions"><button class="tiny-btn tonal" id="audit-log-more" type="button" hidden>显示更多</button><button class="tiny-btn tonal" id="audit-log-next" type="button" hidden>读取更多</button></div></div>');
    const session = { id: requireFeature('ui').getDetailSession(), root: document.getElementById('audit-log-view'),
      revision: 0, busy: false, controller: null, snapshot: null, imported: null, page: null, visibleCount: 100, rows: new Map() };
    ['source', 'refresh', 'import', 'file', 'format', 'export', 'clear', 'level', 'search', 'summary', 'range', 'problems', 'operations', 'status', 'content', 'more', 'next']
      .forEach((name) => { session[name] = document.getElementById(`audit-log-${name}`); });
    state.auditSession = session;
    session.source.addEventListener('change', () => selectSource(session));
    session.refresh.addEventListener('click', () => readAudit(session)); session.export.addEventListener('click', () => exportAudit(session));
    session.clear.addEventListener('click', () => clearAudit(session)); session.import.addEventListener('click', () => session.file.click());
    session.file.addEventListener('change', () => importLogs(session, session.file.files[0]));
    [session.level, session.search].forEach((control) => control.addEventListener('input', () => { session.visibleCount = 100; renderViewer(session); }));
    session.more.addEventListener('click', () => { session.visibleCount += 100; renderViewer(session); });
    session.next.addEventListener('click', () => readAudit(session, true)); renderViewer(session);
    if (state.auditClearPending) setStatus(session, '上次清空操作尚未结束，请稍后刷新。'); else await readAudit(session);
  }

  document.addEventListener('pixel:detail-session', () => { state.auditSession?.controller?.abort('audit-detail-closed'); state.auditSession = null; });
  function pause() {
    flushSummaries(); const session = state.auditSession;
    if (!session || state.auditClearPending) return;
    session.controller?.abort('audit-page-hidden'); session.revision += 1; session.controller = null;
    setBusy(session, false); setStatus(session, '日志读取已暂停，可手动刷新。');
  }
  document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); else { renderLogs(); if (state.auditSession) renderViewer(state.auditSession); } });
  document.addEventListener('freeze', pause); window.addEventListener('pagehide', pause);
  window.addEventListener('storage', (event) => {
    if (event.key !== LOG_STORAGE_KEY && event.key !== null) return;
    try { mergeSummaries(readSummaryStore(event.key === null ? null : event.newValue)); state.persistenceAvailable = true; }
    catch (_) { state.persistenceAvailable = false; }
    renderLogs();
  });
  loadStoredLogs();
  registerFeature('diagnostics', { initialize: renderLogs, errorBlock, appendLog, clearLogs, openAuditLog });
})();
