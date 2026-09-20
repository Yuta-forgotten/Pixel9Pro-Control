'use strict';
(() => {
  const state = {
    session: null,
    request: null,
    queue: Promise.resolve(),
    generation: 0
  };

  const core = () => requireFeature('core');
  const apiFetch = (...args) => core().apiFetch(...args);
  const endpoint = () => (globalThis.API && API.telemetry) || '/cgi-bin/telemetry.sh';

  function enqueue(task) {
    const generation = state.generation;
    const run = state.queue.then(async () => {
      if (generation !== state.generation) return null;
      const controller = new AbortController();
      state.request = controller;
      try {
        return await task(controller, generation);
      } finally {
        if (state.request === controller) state.request = null;
      }
    });
    state.queue = run.catch(() => {});
    return run;
  }

  function query(params) {
    const search = new URLSearchParams(params);
    return `${endpoint()}?${search.toString()}`;
  }

  async function status() {
    if (!requireFeature('auth').hasToken()) return { ok: false, error: 'missing WebUI token', session: state.session };
    const data = await enqueue((controller) => apiFetch(query({ action: 'status' }), { timeoutMs: 5000, controller }));
    if (data?.session) state.session = data.session;
    else if (data && Object.prototype.hasOwnProperty.call(data, 'session')) state.session = null;
    return data;
  }

  async function history({ sessionId = '', startTs = null, endTs = null, granularity = '' } = {}) {
    if (!requireFeature('auth').hasToken()) throw new Error('missing WebUI token');
    const params = { action: 'history' };
    if (sessionId) params.session_id = String(sessionId);
    if (Number.isFinite(Number(startTs))) params.start_ts = String(Math.floor(Number(startTs)));
    if (Number.isFinite(Number(endTs))) params.end_ts = String(Math.floor(Number(endTs)));
    if (granularity === 'hour' || granularity === 'minute') params.granularity = granularity;
    return enqueue((controller) => apiFetch(query(params), { timeoutMs: 8000, controller }));
  }

  async function start(durationSec = 0, maxBytes) {
    const duration = Number(durationSec);
    const body = {
      action: 'start',
      duration_sec: Number.isFinite(duration) && duration >= 0 ? Math.floor(duration) : 0
    };
    if (Number.isFinite(Number(maxBytes)) && Number(maxBytes) > 0) body.max_bytes = Math.floor(Number(maxBytes));
    const data = await enqueue((controller) => apiFetch(endpoint(), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body), timeoutMs: 8000, controller
    }));
    if (data?.session) state.session = data.session;
    return data;
  }

  async function stop(sessionId = '') {
    const body = { action: 'stop' };
    if (sessionId || state.session?.id) body.session_id = String(sessionId || state.session.id);
    const data = await enqueue((controller) => apiFetch(endpoint(), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body), timeoutMs: 8000, controller
    }));
    if (data?.session) state.session = data.session;
    return data;
  }

  async function exportSession(sessionId = '') {
    const body = { action: 'export' };
    if (sessionId || state.session?.id) body.session_id = String(sessionId || state.session.id);
    return enqueue((controller) => apiFetch(endpoint(), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body), timeoutMs: 12000, controller
    }));
  }

  function abort(reason = 'page-hidden') {
    state.generation += 1;
    if (state.request) state.request.abort(reason);
    state.request = null;
    state.queue = Promise.resolve();
  }

  registerFeature('capture', {
    status,
    history,
    start,
    stop,
    export: exportSession,
    abort,
    isBusy: () => Boolean(state.request),
    getSession: () => state.session
  });
})();
