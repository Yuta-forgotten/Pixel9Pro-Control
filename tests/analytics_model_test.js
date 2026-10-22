'use strict';
const assert = require('node:assert/strict');

let analyticsModel;
global.registerFeature = (name, value) => {
  if (name === 'analyticsModel') analyticsModel = value;
};
require('../webroot/js/analytics_model.js');

const ranges = analyticsModel.ranges();
assert.equal(ranges[0].label, '30 分钟');
assert.equal(analyticsModel.rangeFor('120').minutes, 120);
assert.equal(analyticsModel.rangeFor('missing').id, '30');

const normalized = analyticsModel.normalizeThermal({
  points: [
    { ts: 1060, temp_mc: 39200, sensor: 'module', screen: 'on', expected_interval_sec: 60, valid: true },
    { ts: 1000, temp_mc: 37000, sensor: 'module', screen: 'on', expected_interval_sec: 60, valid: true },
    { ts: 1090, temp_mc: 33100, sensor: 'battery', screen: 'off', expected_interval_sec: 900, valid: true },
    { ts: 1120, temp_mc: 0, sensor: 'module', valid: false }
  ]
});
assert.deepEqual(normalized.map((point) => point.ts), [1000, 1060, 1090]);
assert.equal(normalized[0].tempC, 37);
assert.equal(normalized[2].sensor, 'battery');
assert.equal(analyticsModel.normalizeThermal([[1000, 39000]])[0].tempC, 39);

const modulePoints = normalized.filter((point) => point.sensor === 'module');
const stats = analyticsModel.temperatureStats(modulePoints, {
  startTs: 1000,
  endTs: 1180,
  backendSampleCount: 3,
  backendValidSamples: 2,
  backendGapCount: 0
});
assert.equal(stats.count, 2);
assert.equal(stats.sampleCount, 3);
assert.equal(stats.validCount, 2);
assert.equal(stats.min, 37);
assert.equal(stats.max, 39.2);
assert.equal(stats.avg, 38.1);
assert.equal(stats.current, 39.2);
assert.equal(stats.coverageSec, 60);
assert.equal(stats.unknownSec, 120);
assert.equal(stats.chartSegments.length, 1);

const gapped = analyticsModel.temperatureStats([
  { ts: 1000, tempC: 38, expectedIntervalSec: 60 },
  { ts: 1300, tempC: 40, expectedIntervalSec: 60 }
], { startTs: 1000, endTs: 1600 });
assert.equal(gapped.gapCount, 1);
assert.equal(gapped.chartSegments.length, 2);
assert.equal(gapped.quality, 'partial');

assert.equal(analyticsModel.clip(normalized, 1000, 1060).length, 2);
assert.equal(analyticsModel.formatDuration(3661), '1小时1分');
assert.equal(analyticsModel.formatDuration(30), '30秒');
assert.equal(analyticsModel.temperatureStats([], { startTs: 1000, endTs: 1180 }).count, 0);
const exportPayload = {
  ok: true, sensor: 'module', start_ts: 1000, end_ts: 1600,
  recording_enabled: false, recording_state: 'paused', data_revision: 'test:module:1000:1600',
  points: [
    { ts: 1000, temp_mc: 38000, sensor: 'module', source: 'sysfs', screen: 'on', boot_id: 'boot-a', expected_interval_sec: 60, quality: 'ok' },
    { ts: 1300, temp_mc: 39000, sensor: 'module', source: '=invalid', screen: 'on', boot_id: 'boot-a', expected_interval_sec: 60, quality: 'ok' }
  ]
};
const exportedJson = analyticsModel.exportHistory(exportPayload, 'json');
const document = JSON.parse(exportedJson.text);
assert.equal(document.schema, 'pixel9pro.temperature_history.v1');
assert.equal(document.points[0].timestamp_utc, '1970-01-01T00:16:40.000Z');
assert.equal(document.points[1].temperature_c, 39);
assert.equal(document.points[1].gap_before_sec, 300);
assert.equal(document.recording_enabled, false);
assert.equal(document.sampling.suspend_may_delay, true);
assert.equal(document.summary.sample_mean_c, 38.5);
const exportedCsv = analyticsModel.exportHistory(exportPayload, 'csv');
assert.equal(exportedCsv.text.trim().split('\r\n').length, 3);
assert.match(exportedCsv.text, /timestamp_utc,temperature_c,sensor/);
assert.match(exportedCsv.text, /'=invalid/, 'CSV must neutralize formula-like text');
assert.throws(() => analyticsModel.exportHistory(exportPayload, 'xml'));
assert.match(analyticsModel.exportHistory({ ...exportPayload, points: [] }, 'csv').text, /^ts,/);

process.stdout.write('Temperature history model contract passed.\n');
