'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const controllerSource = fs.readFileSync(path.join(root, 'webroot/js/diagnostics.js'), 'utf8');
const modelSource = fs.readFileSync(path.join(root, 'webroot/js/log_model.js'), 'utf8');
const KEY = 'pixel9pro_runtime_log_v3';
const OLD_KEY = 'pixel9pro_runtime_log_v2';
const ID = 'a'.repeat(64);
const flush = () => new Promise((resolve) => setImmediate(resolve));
const deferred = () => { let resolve; let reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };

class Element {
  constructor(tag = 'div') {
    this.tagName = tag; this.children = []; this.events = new Map(); this.attributes = new Map(); this.isConnected = true;
    this.textContent = ''; this.value = ''; this.hidden = false; this.disabled = false; this.open = false;
    this.classList = { add() {}, remove() {} };
  }
  appendChild(child) { child.remove(); child.parent = this; this.children.push(child); return child; }
  insertBefore(child, target) { if (!target) return this.appendChild(child); child.remove(); child.parent = this; this.children.splice(this.children.indexOf(target), 0, child); return child; }
  append(...children) { children.forEach((child) => this.appendChild(child)); }
  replaceChildren(...children) { this.children.forEach((child) => { child.parent = null; }); this.children = []; this.append(...children); }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((child) => child !== this); this.parent = null; }
  setAttribute(key, value) { this.attributes.set(key, value); }
  addEventListener(type, fn) { if (!this.events.has(type)) this.events.set(type, []); this.events.get(type).push(fn); }
  async emit(type, event = {}) { for (const fn of this.events.get(type) || []) await fn(event); }
  click() { if (this.onClick) this.onClick(); return this.emit('click'); }
}

function page(offset = 0, total = 1, id = ID) {
  const count = Math.min(500, total - offset);
  return { ok: true, schema: 2, source: 'structured_audit', limit: 500, offset, total_lines: total,
    snapshot_id: id, lines: Array.from({ length: count }, (_, i) =>
      `schema=2 ts=${1700000000 + offset + i} phase=cgi operation=dns_cache_clear result=${i % 2 ? 'success' : 'failure'} reason_code=${i % 2 ? 'cleared' : 'DNS_TIMEOUT'} duration_ms=4`),
    complete: offset + count === total, truncated: offset + count !== total,
    next_offset: offset + count === total ? null : offset + count, rotated: false };
}

function setup({ initial = new Map(), respond = async () => page() } = {}) {
  const features = {}; const nodes = new Map(); const windows = new Map(); const events = new Map();
  const storage = new Map(initial); const writes = []; const timers = new Map(); const downloads = []; const blobs = [];
  const requests = []; let sessionId = 0; let clock = 1700000000000; let timerId = 0;
  const document = {
    hidden: false, visibilityState: 'visible', body: new Element('body'),
    getElementById: (id) => nodes.get(id),
    createElement(tag) { const node = new Element(tag); if (tag === 'a') node.onClick = () => downloads.push(node.download); return node; },
    addEventListener(type, fn) { if (!events.has(type)) events.set(type, []); events.get(type).push(fn); },
    dispatchEvent(event) { for (const fn of events.get(event.type) || []) fn(event); }
  };
  const refs = { logInner: new Element(), logPreview: new Element(), logMeta: new Element() };
  features.core = {
    async apiFetch(url, options) { requests.push({ url, options }); return respond(url, options); },
    isWebUiActive: () => !document.hidden,
    isRequestCancelled: (error) => error?.cancelled === true,
    showToast() {}
  };
  features.ui = {
    openDetail(title, html) {
      document.dispatchEvent({ type: 'pixel:detail-session' });
      if (nodes.has('audit-log-view')) nodes.get('audit-log-view').isConnected = false;
      sessionId += 1;
      for (const match of html.matchAll(/<([a-z]+)[^>]*\bid="([^"]+)"[^>]*>/g)) nodes.set(match[2], new Element(match[1]));
      nodes.get('audit-log-source').value = 'module'; nodes.get('audit-log-format').value = 'json';
    },
    getDetailSession: () => sessionId,
    isDetailSessionActive: (id) => sessionId === id
  };
  class Clock extends Date { static now() { return clock; } }
  const context = {
    document, refs, API: { auditLog: '/cgi-bin/audit_log.sh' }, Date: Clock, Blob, TextEncoder, AbortController,
    URL: { createObjectURL(blob) { blobs.push(blob); return 'blob:test'; }, revokeObjectURL() {} },
    localStorage: { getItem: (key) => storage.has(key) ? storage.get(key) : null,
      setItem(key, value) { storage.set(key, value); writes.push({ key, value }); } },
    setTimeout(fn, ms) { const id = ++timerId; timers.set(id, { fn, ms }); return id; },
    clearTimeout(id) { timers.delete(id); },
    addEventListener(type, fn) { if (!windows.has(type)) windows.set(type, []); windows.get(type).push(fn); },
    confirm: () => true, registerFeature(name, value) { features[name] = value; }, requireFeature: (name) => features[name]
  };
  context.window = context;
  vm.runInNewContext(modelSource, context, { filename: 'log_model.js' });
  vm.runInNewContext(controllerSource, context, { filename: 'diagnostics.js' });
  features.diagnostics.initialize();
  return { features, nodes, refs, storage, writes, timers, downloads, blobs, requests, document,
    advance(ms) { clock += ms; },
    windowEvent(type, event = {}) { for (const fn of windows.get(type) || []) fn(event); },
    runPersist() { for (const [id, timer] of [...timers]) if (timer.ms === 15000) { timers.delete(id); timer.fn(); } },
    close() { document.dispatchEvent({ type: 'pixel:detail-session' }); sessionId += 1; }
  };
}

test('verbose logs stay in memory; critical summaries batch and never serialize details', () => {
  const h = setup();
  for (let i = 0; i < 230; i++) h.features.diagnostics.appendLog(`read ${i}`, 'dim', 'verbose detail');
  assert.equal(h.writes.length, 0);
  assert.equal(h.refs.logInner.children.length, 200);
  h.windowEvent('pagehide');
  assert.equal(h.writes.length, 0, 'ordinary read and exit have no persistence write');
  h.features.diagnostics.appendLog('失败', 'err', 'private detailed payload', { code: 'E_TEST', operation: 'test' });
  const row = h.refs.logInner.children.at(-1); row.children[2].open = true;
  h.advance(1);
  h.features.diagnostics.appendLog('失败', 'err', 'private detailed payload', { code: 'E_TEST', operation: 'test' });
  assert.equal(h.refs.logInner.children.at(-1), row);
  assert.equal(row.children[2].open, true);
  assert.equal(h.writes.length, 0);
  assert.equal([...h.timers.values()].filter((item) => item.ms === 15000).length, 1);
  h.runPersist();
  const stored = JSON.parse(h.storage.get(KEY));
  assert.equal(stored.entries.length, 1); assert.equal(stored.entries[0].count, 1);
  assert.match(row.children[1].textContent, /2 次/);
  assert.ok(!h.storage.get(KEY).includes('private detailed payload'));
  assert.ok(!Object.hasOwn(stored.entries[0], 'detail'));
  for (let i = 0; i < 40; i++) { h.advance(1); h.features.diagnostics.appendLog(`done ${i}`, 'ok', 'not stored'); }
  h.runPersist(); assert.equal(JSON.parse(h.storage.get(KEY)).entries.length, 32);
});

test('repeated critical events change only memory after the first summary flush', () => {
  const h = setup();
  h.features.diagnostics.appendLog('重复错误', 'err', 'first detail', { code: 'E_REPEAT', operation: 'read' });
  h.runPersist();
  const saved = h.storage.get(KEY); const writes = h.writes.length;
  for (let i = 0; i < 5; i++) {
    h.advance(16000);
    h.features.diagnostics.appendLog('重复错误', 'err', `detail ${i}`, { code: 'E_REPEAT', operation: 'read' });
    h.runPersist();
    assert.equal([...h.timers.values()].filter((timer) => timer.ms === 15000).length, 0);
    assert.equal(h.writes.length, writes);
  }
  assert.match(h.refs.logInner.children.at(-1).children[1].textContent, /6 次/);
  h.windowEvent('pagehide');
  assert.equal(h.writes.length, writes); assert.equal(h.storage.get(KEY), saved);
  h.advance(1); h.features.diagnostics.appendLog('另一项操作', 'ok'); h.runPersist();
  const original = JSON.parse(h.storage.get(KEY)).entries.find((entry) => entry.code === 'E_REPEAT');
  assert.equal(original.count, 1, 'an unrelated new summary must not persist the in-memory repeat count');
  assert.ok(!Object.hasOwn(original, 'detail'));
});

test('legacy migration is summary-only and preserves the old key; cross-tab updates retain memory details', () => {
  const old = JSON.stringify([{ ts: 1699999999999, text: 'legacy failure', type: 'err', detail: 'legacy private detail', count: 2 }]);
  const h = setup({ initial: new Map([[OLD_KEY, old]]) });
  assert.equal(h.writes.length, 0); h.runPersist();
  assert.equal(h.storage.get(OLD_KEY), old); assert.ok(!h.storage.get(KEY).includes('legacy private detail'));
  h.features.diagnostics.appendLog('new failure', 'err', 'live-only-detail'); h.runPersist();
  const incoming = JSON.parse(h.storage.get(KEY));
  incoming.entries.at(-1).ts += 10; incoming.entries.at(-1).count += 1;
  h.windowEvent('storage', { key: KEY, newValue: JSON.stringify(incoming) });
  assert.equal(h.refs.logInner.children.at(-1).children[2].children[1].textContent, 'live-only-detail');
  const writeCount = h.writes.length; h.windowEvent('pagehide'); assert.equal(h.writes.length, writeCount);
  h.features.diagnostics.clearLogs(); h.features.diagnostics.appendLog('after clear', 'ok'); h.runPersist();
  assert.equal(JSON.parse(h.storage.get(KEY)).entries.at(-1).message, 'after clear');
});

test('viewer filters count events and full export walks one immutable snapshot', async () => {
  const h = setup({ respond: async (url) => page(Number(new URL(url, 'http://localhost').searchParams.get('offset')), 1001) });
  await h.features.diagnostics.openAuditLog();
  assert.equal(h.nodes.get('audit-log-content').children.length, 100);
  assert.match(h.nodes.get('audit-log-summary').textContent, /500\/1001.*当前样本/);
  h.nodes.get('audit-log-level').value = 'error'; await h.nodes.get('audit-log-level').emit('input');
  assert.match(h.nodes.get('audit-log-summary').textContent, /250 条记录，250 次事件/);
  await h.nodes.get('audit-log-more').click(); assert.equal(h.nodes.get('audit-log-content').children.length, 200);
  await h.nodes.get('audit-log-export').click();
  const requested = h.requests.slice(1).map((request) => new URL(request.url, 'http://localhost').searchParams);
  assert.deepEqual(requested.map((query) => Number(query.get('offset'))), [0, 500, 1000]);
  assert.equal(requested[0].get('snapshot_id'), null);
  assert.equal(requested[1].get('snapshot_id'), ID); assert.equal(requested[2].get('snapshot_id'), ID);
  assert.equal(h.downloads.length, 1);
  const exported = JSON.parse(await h.blobs[0].text()); assert.equal(exported.entries.length, 1001);
  assert.equal(exported.truncated, false);
  assert.match(h.nodes.get('audit-log-status').textContent, /已生成.*发起下载/);
});

test('changed snapshots and malformed pages fail visibly without downloads or retry', async () => {
  let changed = false;
  const h = setup({ respond: async (url) => {
    const offset = Number(new URL(url, 'http://localhost').searchParams.get('offset'));
    if (changed && offset) throw Object.assign(new Error('changed'), { payload: { error_code: 'AUDIT_SNAPSHOT_CHANGED' } });
    return page(offset, 1001);
  } });
  await h.features.diagnostics.openAuditLog(); changed = true;
  await h.nodes.get('audit-log-export').click();
  assert.equal(h.requests.length, 3); assert.equal(h.downloads.length, 0);
  assert.match(h.nodes.get('audit-log-status').textContent, /日志已更新/);
  const malformed = setup({ respond: async () => ({ ...page(), next_offset: 0 }) });
  await malformed.features.diagnostics.openAuditLog();
  assert.match(malformed.nodes.get('audit-log-status').textContent, /分页结果无效/);
  assert.equal(malformed.nodes.get('audit-log-export').disabled, true);
});

test('imports are isolated, bounded, and cannot publish after source changes or close', async () => {
  const h = setup(); await h.features.diagnostics.openAuditLog();
  const delayed = deferred();
  h.nodes.get('audit-log-file').files = [{ name: 'logs.txt', size: 20, text: () => delayed.promise }];
  const importing = h.nodes.get('audit-log-file').emit('change'); await flush();
  h.nodes.get('audit-log-source').value = 'page'; await h.nodes.get('audit-log-source').emit('change');
  delayed.resolve(page().lines[0]); await importing;
  assert.equal(h.nodes.get('audit-log-source').value, 'page');
  assert.equal(h.refs.logInner.children.length, 0);
  h.nodes.get('audit-log-file').files = [{ name: 'logs.txt', size: 30, text: async () => page().lines[0] }];
  const priorRequests = h.requests.length; await h.nodes.get('audit-log-file').emit('change');
  assert.equal(h.nodes.get('audit-log-source').value, 'import'); assert.equal(h.requests.length, priorRequests);
  assert.equal(h.nodes.get('audit-log-clear').disabled, true); assert.equal(h.refs.logInner.children.length, 0);
  h.windowEvent('pagehide'); assert.equal(h.writes.length, 0);
  const oversized = setup(); await oversized.features.diagnostics.openAuditLog();
  oversized.nodes.get('audit-log-file').files = [{ name: 'huge.json', size: 9 * 1024 * 1024, text: () => { throw new Error('must not read'); } }];
  await oversized.nodes.get('audit-log-file').emit('change');
  assert.match(oversized.nodes.get('audit-log-status').textContent, /8 MiB/);
});

test('closed sessions discard late exports and committed clears do not schedule hidden readback', async () => {
  let next = null;
  const h = setup({ respond: async (url, options) => next ? next.promise : options.method === 'POST' ? { ok: true, action: 'clear' } : page() });
  await h.features.diagnostics.openAuditLog(); next = deferred();
  const exporting = h.nodes.get('audit-log-export').click(); await flush(); h.close(); next.resolve(page()); await exporting;
  assert.equal(h.downloads.length, 0);
  next = null; await h.features.diagnostics.openAuditLog(); next = deferred();
  const clearing = h.nodes.get('audit-log-clear').click(); await flush();
  const calls = h.requests.length; h.close(); next.resolve({ ok: true, action: 'clear' }); await clearing;
  assert.equal(h.requests.length, calls);
  assert.match(h.refs.logPreview.textContent, /模块日志已清空/);
});

test('a newly opened viewer is usable when an older clear finishes without fetching into it', async () => {
  const pending = deferred(); let block = false;
  const h = setup({ respond: async (url, options) => block && options.method === 'POST' ? pending.promise : page() });
  await h.features.diagnostics.openAuditLog(); block = true;
  const clearing = h.nodes.get('audit-log-clear').click(); await flush(); h.close();
  await h.features.diagnostics.openAuditLog();
  assert.equal(h.nodes.get('audit-log-refresh').disabled, true);
  const calls = h.requests.length; pending.resolve({ ok: true, action: 'clear' }); await clearing;
  assert.equal(h.requests.length, calls);
  assert.equal(h.nodes.get('audit-log-refresh').disabled, false);
});
