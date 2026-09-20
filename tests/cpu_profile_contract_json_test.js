'use strict';

const assert = require('assert');
const path = require('path');
const { spawnSync } = require('child_process');

const root = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const command = '. ./scripts/cpu_profile_lib.sh; cpu_profile_contract_json';
const result = spawnSync('bash', ['-c', command], {
  cwd: root,
  encoding: 'utf8',
  env: { ...process.env, MSYS_NO_PATHCONV: '1' },
});

assert.strictEqual(result.status, 0, `CPU contract shell serializer failed: ${result.stderr}`);
assert(result.stdout.trim().startsWith('{'), 'CPU contract serializer must emit a JSON object');

let contract;
assert.doesNotThrow(() => {
  contract = JSON.parse(result.stdout.trim());
}, 'CPU contract serializer must emit valid JSON');

assert.strictEqual(contract.schema, 2, 'CPU contract schema must be version 2');
assert.strictEqual(contract.full_cap, 1024, 'full uclamp cap must be numeric 1024');
assert.strictEqual(contract.eco_cap, 0, 'eco uclamp cap must be numeric 0');
assert.strictEqual(contract.foreground_cpus, '0-6', 'foreground observation must expose the current stock topology');
assert.strictEqual(contract.background_cpus, '0-3', 'background cpuset must be exported');
assert.strictEqual(contract.system_background_cpus, '0-3', 'system-background cpuset must be exported');

assert.deepStrictEqual(contract.ownership, {
  foreground_cpus: 'framework',
  top_app_cpus: 'pixel_best_effort',
  background_cpus: 'pixel_transaction',
  system_background_cpus: 'pixel_transaction',
  response_time_ms: 'pixel_best_effort',
  sched_util_clamp_min: 'pixel_best_effort',
  vendor_sched_l2: 'pixel_best_effort',
  scaling_min_max_freq: 'thermal_powerhal_scene',
}, 'CPU contract ownership must remain explicit and structured');
assert.strictEqual(contract.writeback_policy, 'apply_verify_once_then_observe');
assert.strictEqual(contract.health_interval_s, 300);

assert.deepStrictEqual(contract.auto.profiles, ['balanced', 'battery']);
assert.deepStrictEqual(contract.auto.discharge, {
  hot_temp_mc: 38800,
  hot_hold_s: 60,
  cool_temp_mc: 37500,
  cool_hold_s: 120,
});
assert.deepStrictEqual(contract.auto.charging, {
  thermal_status_min: 2,
  hot_temp_mc: 39800,
  hot_hold_s: 60,
  cool_temp_mc: 37500,
  cool_hold_s: 120,
});

assert.deepStrictEqual(contract.profiles.performance, {
  response_ms: [12, 20, 80],
  uclamp_cap: 1024,
  top_app_cpus: '0-7',
  bg_uclamp_max: 200,
  bg_group_throttle: 100,
});
assert.deepStrictEqual(contract.profiles.balanced, {
  response_ms: [16, 64, 240],
  uclamp_cap: 0,
  top_app_cpus: '0-6',
  bg_uclamp_max: 200,
  bg_group_throttle: 100,
});
assert.deepStrictEqual(contract.profiles.battery, {
  response_ms: [16, 96, 320],
  uclamp_cap: 0,
  top_app_cpus: '0-6',
  bg_uclamp_max: 150,
  bg_group_throttle: 80,
});
assert.deepStrictEqual(contract.profiles.default, {
  response_ms: null,
  uclamp_cap: 1024,
  top_app_cpus: '0-7',
  bg_uclamp_max: 1024,
  bg_group_throttle: 308,
});

process.stdout.write('CPU profile JSON contract passed: parsed fields and types\n');
