'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const scratch = path.join(root, 'tmp');
fs.mkdirSync(scratch, { recursive: true });
const testRoot = fs.mkdtempSync(path.join(scratch, 'thermal-history-contract-'));

function wslPath(value) {
  const result = spawnSync('wsl.exe', ['-e', 'wslpath', '-a', value], { encoding: 'utf8' });
  assert.equal(result.status, 0, `wslpath failed: ${result.stderr}`);
  return result.stdout.trim();
}

function quote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

function response(output, name) {
  const marker = `@@${name}\n`;
  const begin = output.indexOf(marker);
  assert.notEqual(begin, -1, `missing ${name} result`);
  const bodyStart = begin + marker.length;
  const next = output.indexOf('\n@@', bodyStart);
  const chunk = output.slice(bodyStart, next === -1 ? output.length : next);
  const jsonStart = chunk.search(/[\[{]/);
  assert.notEqual(jsonStart, -1, `${name} response has no JSON body`);
  return { raw: chunk, data: JSON.parse(chunk.slice(jsonStart).trim()) };
}

try {
  const command = `sh ${quote(wslPath(path.join(__dirname, 'thermal_history_contract_test.sh')))} ${quote(wslPath(root))} ${quote(wslPath(testRoot))}`;
  const result = spawnSync('wsl.exe', ['-e', 'sh', '-lc', command], { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  assert.equal(result.status, 0, `thermal CGI fixture failed:\n${result.stdout}\n${result.stderr}`);
  assert.equal(response(result.stdout, 'escape').data.value, 'quote"\\tab\tline\nnext\rend\n\n', 'shared JSON encoder preserves all controls and trailing newlines');

  const module = response(result.stdout, 'module').data;
  assert.equal(module.ok, true);
  assert.equal(module.sensor, 'module');
  assert.equal(module.raw_samples, 2);
  assert.equal(module.valid_samples, 2);
  assert.equal(module.points.length, 2);
  assert.equal(module.points[1].temp_mc, 41000);
  assert.equal(module.coverage_sec, 0);
  assert.equal(module.gap_count, 1);
  assert.equal(module.quality, 'partial');

  const battery = response(result.stdout, 'battery').data;
  assert.equal(battery.sensor, 'battery');
  assert.equal(battery.valid_samples, 1);
  assert.equal(battery.points[0].temp_mc, 33100);
  assert.equal(battery.points[0].screen, 'off');

  const empty = response(result.stdout, 'empty').data;
  assert.equal(empty.ok, true);
  assert.equal(empty.valid_samples, 0);
  assert.deepEqual(empty.points, []);
  assert.equal(empty.quality, 'no_data');

  const invalid = response(result.stdout, 'invalid');
  assert.match(invalid.raw, /400 Bad Request/);
  assert.equal(invalid.data.ok, false);

  const live = response(result.stdout, 'live').data;
  assert.equal(live.find((zone) => zone.zone === 'VIRTUAL-SKIN').temp, 39250);
  const afterLive = response(result.stdout, 'afterlive').data;
  assert.equal(afterLive.valid_samples, 3, 'foreground read writes once even without a service cycle');
  assert.equal(afterLive.points.filter((point) => point.temp_mc === 39250).length, 1, 'reused cache cannot create duplicate samples');
  const legacy = response(result.stdout, 'legacy').data;
  assert.equal(legacy.valid_samples, 1, 'legacy two-column history remains readable');
  assert.equal(legacy.points[0].temp_mc, 38500);
  const extended = response(result.stdout, 'legacy_extended').data;
  assert.equal(extended.valid_samples, 1, 'legacy column-11 interval is not a sensor');
  assert.equal(extended.points[0].expected_interval_sec, 300);
  const paused = response(result.stdout, 'paused').data;
  assert.equal(paused.recording_enabled, false);
  assert.equal(paused.recording_state, 'paused');
  assert.equal(paused.valid_samples, 1, 'paused recording does not hide existing history');

  const lifecycleCommand = `sh ${quote(wslPath(path.join(__dirname, 'background_tasks_contract_test.sh')))} ${quote(wslPath(root))} ${quote(wslPath(path.join(testRoot, 'lifecycle')))}`;
  const lifecycle = spawnSync('wsl.exe', ['-e', 'sh', '-lc', lifecycleCommand], { encoding: 'utf8', timeout: 40000, maxBuffer: 4 * 1024 * 1024 });
  assert.equal(lifecycle.status, 0, `lifecycle CGI fixture failed:\n${lifecycle.stdout}\n${lifecycle.stderr}`);
  for (const [name, enabled, workerState] of [['start', true, 'running'], ['stop', false, 'paused'], ['restart', true, 'running'], ['settled', false, 'paused'], ['writer_settled', false, 'paused']]) {
    const data = response(lifecycle.stdout, name).data;
    assert.equal(data.ok, true, name);
    assert.equal(data.background_enabled, enabled, name);
    assert.equal(data.background_state, workerState, name);
    assert.equal(data.final, true, name);
  }
  const pending = response(lifecycle.stdout, 'pending').data;
  assert.equal(pending.background_enabled, false);
  assert.equal(pending.background_state, 'stopping');
  assert.equal(pending.final, false);
  const failedStart = response(lifecycle.stdout, 'failed_start');
  assert.match(failedStart.raw, /500 Internal Server Error/);
  assert.equal(failedStart.data.ok, false);
  assert.match(failedStart.data.error, /previous state restored/);
  const cleanupFailure = response(lifecycle.stdout, 'cleanup_failed');
  assert.match(cleanupFailure.raw, /500 Internal Server Error/);
  assert.equal(cleanupFailure.data.committed, true);
  assert.equal(cleanupFailure.data.background_state, 'paused');
  assert.equal(cleanupFailure.data.background_cleanup, 'failed');
  assert.equal(cleanupFailure.data.background_enabled, false);
  const workerCommand = `sh ${quote(wslPath(path.join(__dirname, 'control_worker_contract_test.sh')))} ${quote(wslPath(root))} ${quote(wslPath(path.join(testRoot, 'worker')))}`;
  const worker = spawnSync('wsl.exe', ['-e', 'sh', '-lc', workerCommand], { encoding: 'utf8', timeout: 10000 });
  assert.equal(worker.status, 0, `production worker fixture failed:\n${worker.stdout}\n${worker.stderr}`);
  assert.match(worker.stdout, /Production worker off-screen sysfs/);

  process.stdout.write('Thermal history and master lifecycle CGI contracts passed.\n');
} finally {
  fs.rmSync(testRoot, { recursive: true, force: true });
}
