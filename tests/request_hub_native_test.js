'use strict';
// Production Request Hub with the manager's asynchronous spawn boundary controlled.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const runtime = fs.readFileSync(path.join(root, 'webroot/js/runtime.js'), 'utf8');
const API = vm.runInNewContext(`(${runtime.match(/const API = (\{[\s\S]*?\n\});/)[1]})`);
const source = fs.readFileSync(path.join(root, 'webroot/js/common.js'), 'utf8');
const flush = () => new Promise((resolve) => setImmediate(resolve));

async function setup() {
  const features = { diagnostics: { appendLog() {} } };
  const commands = [];
  const context = {
    API, WEBUI_NATIVE_TRANSPORT: true, STORAGE_TOKEN_KEY: 'test-token',
    URL, URLSearchParams, TextEncoder, Response, AbortController, setTimeout, clearTimeout,
    location: { href: 'https://module.local/index.html', hash: '', pathname: '/', search: '' },
    sessionStorage: { getItem: () => 'test-session-token', setItem() {}, removeItem() {} },
    document: { hidden: false, visibilityState: 'visible', getElementById: () => null },
    registerFeature: (name, value) => { features[name] = value; },
    requireFeature: (name) => features[name],
    ksu: { spawn(command, args, options, callback) { commands.push({ command, callback }); } }
  };
  context.window = context;
  vm.runInNewContext(source, context, { filename: 'common.js' });
  function reply(index, payload = { ok: true }) {
    const receiver = context[commands[index].callback];
    receiver.stdout.emit('data', `Content-Type: application/json\n\n${JSON.stringify(payload)}`);
    receiver.emit('exit', 0);
  }
  const auth = features.auth.initialize();
  reply(0, { paired: true });
  assert.equal(await auth, true);
  commands.length = 0;
  return { core: features.core, commands, reply };
}

async function run() {
  {
    const { core, commands, reply } = await setup();
    const reads = [API.status, API.info, API.swap].map((url) => core.apiFetch(url).catch((e) => e.code));
    assert.equal(commands.length, 3);
    core.pauseReadRequests();
    assert.deepEqual(await Promise.all(reads), ['PAGE_HIDDEN', 'PAGE_HIDDEN', 'PAGE_HIDDEN']);
    let result;
    const write = core.apiFetch(API.thermalSet, { method: 'POST', body: '{}', timeoutMs: 1000 })
      .then(() => { result = 'ok'; }, (error) => { result = error.code; });
    await flush();
    assert.equal(result, undefined, 'a cancelled observation must not make the next click fail NATIVE_BUSY');
    assert.equal(commands.length, 3, 'the actual three native processes still own their slots');
    reply(0);
    await flush();
    assert.equal(commands.length, 4, 'native exit dispatches the waiting click without a retry');
    reply(3);
    await write;
    assert.equal(result, 'ok');
    reply(1); reply(2);
    console.log('PASS cancelled native reads retain real process slots and wake queued clicks');
  }
  {
    const { core, commands, reply } = await setup();
    const write = core.apiFetch(API.swap, { method: 'POST', body: '{}', timeoutMs: 20 })
      .catch((error) => error.code);
    assert.equal(await write, 'REQUEST_TIMEOUT');
    const read = core.apiFetch(API.swap);
    await flush();
    assert.equal(commands.length, 1, 'readback cannot overtake a timed-out but still running mutation');
    reply(0);
    await flush();
    assert.equal(commands.length, 2);
    reply(1, { ok: true, committed: true });
    assert.equal((await read).committed, true);
    assert.equal(commands.filter((entry) => entry.command.includes("REQUEST_METHOD='POST'")).length, 1);
    console.log('PASS native mutation fencing survives observer timeout without replay');
  }
  {
    const { core, commands, reply } = await setup();
    const write = core.apiFetch(API.ownerArbiter, { method: 'POST', body: '{}', timeoutMs: 20 })
      .catch((error) => error.code);
    assert.equal(await write, 'REQUEST_TIMEOUT');
    const read = core.apiFetch(`${API.profile}?compact=1`);
    const cpu = core.apiFetch(API.status);
    await flush();
    assert.equal(commands.length, 1, 'scheduler endpoints share the same resource fence');
    reply(0);
    await flush();
    assert.equal(commands.length, 3);
    reply(1); reply(2);
    await Promise.all([read, cpu]);
    console.log('PASS scheduler command and snapshot endpoints share a mutation fence');
  }
  {
    const { core, commands, reply } = await setup();
    const first = core.apiFetch(API.uecap).catch((error) => error.code);
    core.pauseReadRequests();
    assert.equal(await first, 'PAGE_HIDDEN');
    const next = core.apiFetch(API.checkBaseband);
    const fast = core.apiFetch(API.info);
    await flush();
    assert.equal(commands.length, 2, 'abandoned diagnostic keeps its lane, but not the snapshot lane');
    assert(commands[1].command.includes('info.sh'));
    reply(0);
    await flush();
    assert.equal(commands.length, 3);
    reply(1); reply(2);
    await Promise.all([next, fast]);
    console.log('PASS cancelled native diagnostics retain their lane until exit');
  }
  {
    const { core, commands, reply } = await setup();
    const active = [API.info, API.swap, API.ntp].map((url) => core.apiFetch(url));
    const background = core.apiFetch(API.theme, { priority: 'background' });
    const normal = core.apiFetch(API.nrSwitch, { priority: 'normal' });
    const interactive = core.apiFetch(API.theme, { priority: 'interactive' });
    assert.equal(interactive, background, 'a queued shared GET remains a single request');
    reply(0);
    await flush();
    assert(commands[3].command.includes('theme.sh'), 'a user click promotes the shared queued read');
    reply(1); reply(2); reply(3);
    await flush();
    reply(4);
    await Promise.all([...active, background, normal]);
    console.log('PASS interactive reads promote queued shared requests without duplication');
  }
  {
    const { core } = await setup();
    let calls = 0;
    const first = core.runFeatureTask('snapshot', () => { calls += 1; return true; });
    const second = core.runFeatureTask('snapshot', () => { calls += 1; return false; });
    assert.equal(first, second);
    await first;
    await core.runFeatureTask('snapshot', () => { calls += 1; });
    assert.equal(calls, 2, 'a consumer starts a fresh feature task after completion');
    await assert.rejects(core.runFeatureTask('bug', () => { throw new TypeError('internal bug'); }), /internal bug/);
    console.log('PASS shared feature tasks deduplicate and propagate internal errors');
  }
}
run().catch((error) => { console.error(error); process.exitCode = 1; });
