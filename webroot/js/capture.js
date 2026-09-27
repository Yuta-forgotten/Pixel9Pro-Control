'use strict';
(() => {
  const state = { session: null, getControllers: new Set() };

  const core = () => requireFeature('core');
  const apiFetch = (...args) => core().apiFetch(...args);
  const endpoint = () => (globalThis.API && API.telemetry) || '/cgi-bin/telemetry.sh';

  function isCancelled(err) { return core().isRequestCancelled?.(err) === true; }

  async function get(path, timeoutMs, dedupeKey = path) {
    if (!requireFeature('auth').hasToken()) return { ok: false, error: 'missing WebUI token', session: state.session };
    const controller = new AbortController();
    state.getControllers.add(controller);
    try {
      return await apiFetch(path, {
        timeoutMs, controller, priority: 'normal', scope: 'analytics.capture.read',
        dedupe: true, dedupeKey
      });
    } finally { state.getControllers.delete(controller); }
  }

  function query(params) {
    const search = new URLSearchParams(params);
    return `${endpoint()}?${search.toString()}`;
  }

  async function status() {
    if (!requireFeature('auth').hasToken()) return { ok: false, error: 'missing WebUI token', session: state.session };
    try {
      const path = query({ action: 'status' });
      const data = await get(path, 5000, path);
      if (data?.session) state.session = data.session;
      else if (data && Object.prototype.hasOwnProperty.call(data, 'session')) state.session = null;
      return data;
    } catch (err) { if (isCancelled(err)) return null; throw err; }
  }

  async function history({ sessionId = '', startTs = null, endTs = null, granularity = '' } = {}) {
    if (!requireFeature('auth').hasToken()) throw new Error('missing WebUI token');
    const params = { action: 'history' };
    if (sessionId) params.session_id = String(sessionId);
    if (Number.isFinite(Number(startTs))) params.start_ts = String(Math.floor(Number(startTs)));
    if (Number.isFinite(Number(endTs))) params.end_ts = String(Math.floor(Number(endTs)));
    if (granularity === 'hour' || granularity === 'minute') params.granularity = granularity;
    const path = query(params);
    try { return await get(path, 8000, path); }
    catch (err) { if (isCancelled(err)) return null; throw err; }
  }

  async function mutate(body, timeoutMs) {
    return apiFetch(endpoint(), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body), timeoutMs, priority: 'interactive', scope: 'analytics.capture'
    });
  }

  async function start(durationSec = 0, maxBytes) {
    const duration = Number(durationSec);
    const body = {
      action: 'start',
      duration_sec: Number.isFinite(duration) && duration >= 0 ? Math.floor(duration) : 0
    };
    if (Number.isFinite(Number(maxBytes)) && Number(maxBytes) > 0) body.max_bytes = Math.floor(Number(maxBytes));
    const data = await mutate(body, 8000);
    if (data?.session) state.session = data.session;
    return data;
  }

  async function stop(sessionId = '') {
    const body = { action: 'stop' };
    if (sessionId || state.session?.id) body.session_id = String(sessionId || state.session.id);
    const data = await mutate(body, 8000);
    if (data?.session) state.session = data.session;
    return data;
  }

  async function exportSession(sessionId = '') {
    const body = { action: 'export' };
    if (sessionId || state.session?.id) body.session_id = String(sessionId || state.session.id);
    return mutate(body, 12000);
  }

  function abort(reason = 'page-hidden') {
    state.getControllers.forEach((controller) => controller.abort(reason));
    state.getControllers.clear();
  }

  registerFeature('capture', {
    status,
    history,
    start,
    stop,
    export: exportSession,
    abort,
    isBusy: () => state.getControllers.size > 0,
    getSession: () => state.session
  });
})();
