'use strict';
const assert = require('node:assert/strict');

let model;
global.registerFeature = (name, value) => {
  if (name === 'logModel') model = value;
};
require('../webroot/js/log_model.js');

const line = 'schema=2 ts=1700000000 boot_id=boot-a module_version=v1 root_family=apatch device=caiman phase=dns operation=flush result=success reason_code=DNS_CACHE_FLUSHED duration_ms=12';
const parsed = model.parseAudit([line]);
assert.equal(parsed.entries[0].ts, 1700000000000);
assert.equal(parsed.entries[0].level, 'success');
assert.equal(parsed.entries[0].durationMs, 12);
assert.equal(parsed.entries[0].detail, line);
assert.equal(parsed.invalidCount, 0);
assert.equal(parsed.unsupportedCount, 0);

const broken = line.replace('duration_ms=12', 'duration_ms=');
const unknown = line.replace('schema=2', 'schema=17');
const mixed = model.parseAudit([line, broken, unknown, line.replace('schema=2', 'schema=1'), line + ' ts=7']);
assert.equal(mixed.entries.length, 5);
assert.equal(mixed.invalidCount, 2);
assert.equal(mixed.unsupportedCount, 2);
assert.equal(mixed.entries[1].ts, null);
assert.equal(mixed.entries[1].level, 'error');
assert.equal(mixed.entries[1].detail, broken);
assert.equal(mixed.entries[2].level, 'warning');
assert.equal(mixed.entries[2].detail, unknown);
assert.equal(model.parseAudit([line.replace('result=success', 'result=mystery')]).entries[0].level, 'warning');
assert.equal(model.parseAudit([line.replace('ts=1700000000', 'ts=NaN')]).invalidCount, 1);
assert.equal(model.parseAudit([line.replace('duration_ms=12', 'duration_ms=-1')]).invalidCount, 1);
assert.equal(model.parseAudit([line.replace('schema=2', 'schema=not-a-version')]).invalidCount, 1);
assert.equal(model.parseAudit([line.replace('operation=flush', `operation=${'x'.repeat(257)}`)]).invalidCount, 1);
assert.equal(model.parseAudit(['']).invalidCount, 1);
assert.throws(() => model.parseAudit([null]), /第 1 行/);

const repeated = [
  { ...parsed.entries[0], count: 3, firstTs: 1000, lastTs: 3000, ts: 3000 },
  { ...parsed.entries[0], level: 'error', result: 'failed', code: 'DNS_FAILED', count: 2, ts: 4000, durationMs: 30 },
  { ...mixed.entries[2], count: 4 }
];
const before = JSON.stringify(repeated);
const summary = model.stats(repeated);
assert.equal(summary.recordCount, 3);
assert.equal(summary.eventCount, 9);
assert.deepEqual(summary.levels, { error: 2, warning: 4, success: 3, info: 0 });
assert.deepEqual(summary.timeRange, { start: 1000, end: 4000 });
assert.equal(summary.operations.find((item) => item.operation === 'flush').count, 5);
assert.deepEqual(summary.errors, [{ code: 'DNS_FAILED', count: 2 }]);
assert.deepEqual(summary.duration, { sampleCount: 2, totalMs: 42, averageMs: 21, maxMs: 30, unmeasuredEventCount: 7 });
assert.equal(JSON.stringify(repeated), before, 'stats must not change source entries');
assert.deepEqual(model.stats([]).timeRange, { start: null, end: null });
assert.equal(model.stats([]).duration.averageMs, null);

const snapshot = {
  schema: model.schema, exportedAt: 1700000100000, source: 'module',
  range: { start: 1000, end: 4000 }, truncated: true,
  invalidCount: 0, unsupportedCount: 1, entries: repeated
};
const original = JSON.stringify(snapshot);
for (const [format, exportFn] of [['json', model.exportJson], ['txt', model.exportText]]) {
  const exported = exportFn(snapshot);
  const imported = model.parseImport(exported, `logs.${format}`);
  assert.equal(imported.source, 'import');
  assert.equal(imported.originalSource, 'module');
  assert.equal(imported.truncated, true);
  assert.equal(imported.invalidCount, 0);
  assert.equal(imported.unsupportedCount, 1);
  assert.equal(imported.completeness, 'unverified');
  assert.deepEqual(imported.range, snapshot.range);
  assert.deepEqual(imported.entries, repeated);
  imported.entries[0].message = 'changed';
  assert.equal(JSON.stringify(snapshot), original, 'import/export must not mutate source snapshot');
}
const rawImport = model.parseImport(`${line}\r\n${broken}\r\n${unknown}\r\n`, 'module.txt');
assert.equal(rawImport.entries.length, 3);
assert.equal(rawImport.invalidCount, 1);
assert.equal(rawImport.unsupportedCount, 1);
assert.equal(rawImport.entries[2].detail, unknown);
assert.equal(rawImport.exportedAt, null);
assert.equal(typeof rawImport.importedAt, 'number');
assert.equal(model.parseImport('\uFEFF' + line, 'module.txt').entries[0].level, 'success');
assert.equal(model.parseImport('', 'empty.txt').entries.length, 0);
const brokenExport = { ...snapshot, range: model.stats(mixed.entries).timeRange, entries: mixed.entries, invalidCount: mixed.invalidCount, unsupportedCount: mixed.unsupportedCount };
assert.deepEqual(model.parseImport(model.exportJson(brokenExport), 'broken-roundtrip.json').entries, mixed.entries);
assert.throws(() => model.parseImport('{', 'bad.json'), /JSON 不完整/);
assert.throws(() => model.parseImport(JSON.stringify({ ...snapshot, schema: 'pixel9pro.logs.v2' }), 'bad.json'), /只支持/);
assert.throws(() => model.parseImport(JSON.stringify({ ...snapshot, truncated: 'false' }), 'bad.json'), /截断/);
assert.throws(() => model.parseImport(JSON.stringify({ ...snapshot, range: { start: 4, end: 1 } }), 'bad.json'), /时间范围/);
assert.throws(() => model.parseImport(JSON.stringify({ ...snapshot, range: { start: 2000, end: 4000 } }), 'bad.json'), /未包含/);
assert.throws(() => model.parseImport(JSON.stringify({ ...snapshot, invalidCount: 10 }), 'bad.json'), /统计与记录/);
assert.throws(() => model.parseImport(JSON.stringify({ ...snapshot, entries: [{ ...repeated[0], count: 0 }] }), 'bad.json'), /次数/);
assert.throws(() => model.parseImport(JSON.stringify({ ...snapshot, entries: [{ ...repeated[0], level: 'ok' }] }), 'bad.json'), /级别/);
assert.throws(() => model.parseImport(JSON.stringify({ ...snapshot, entries: [{ ...repeated[0], ts: '1700' }] }), 'bad.json'), /时间/);
assert.throws(() => model.parseImport(JSON.stringify({ ...snapshot, entries: [{ ...repeated[0], message: {} }] }), 'bad.json'), /message/);
assert.throws(() => model.parseImport(JSON.stringify({ ...snapshot, entries: [{ ...repeated[0], firstTs: 4001 }] }), 'bad.json'), /倒置/);
assert.throws(() => model.parseImport('x'.repeat(model.limits.maxBytes + 1), 'large.txt'), /8 MiB/);
assert.throws(() => model.parseImport('中'.repeat(Math.floor(model.limits.maxBytes / 3) + 1), 'large.txt'), /8 MiB/);
assert.throws(() => model.parseImport('\n'.repeat(model.limits.maxLines + 1), 'lines.txt'), /50000 行/);

const manyEntries = Array.from({ length: 4000 }, (_, index) => ({ ...parsed.entries[0], ts: 1700000000000 + index }));
const manySnapshot = { ...snapshot, range: model.stats(manyEntries).timeRange, invalidCount: 0, unsupportedCount: 0, entries: manyEntries };
const prettyJson = model.exportJson(manySnapshot);
assert.ok(prettyJson.split('\n').length > model.limits.maxLines, 'fixture crosses the old pretty-JSON line limit');
assert.ok(new TextEncoder().encode(prettyJson).byteLength < model.limits.maxBytes);
assert.deepEqual(model.parseImport(prettyJson, 'complete.json').entries, manyEntries);

const compactEntry = { ts: 0, level: 'info', source: 'page', phase: '', operation: '', result: '', code: '', message: '', detail: '', durationMs: null, count: 1 };
const fullTextSnapshot = { ...snapshot, range: { start: 0, end: 0 }, invalidCount: 0, unsupportedCount: 0,
  entries: Array(model.limits.maxEntries).fill(compactEntry) };
const fullText = model.exportText(fullTextSnapshot);
assert.ok(new TextEncoder().encode(fullText).byteLength < model.limits.maxBytes);
assert.equal(fullText.trimEnd().split('\n').length, model.limits.maxEntries + 2, 'TXT header and metadata are not records');
assert.equal(model.parseImport(fullText, 'complete.txt').entries.length, model.limits.maxEntries);
assert.throws(() => model.parseImport(fullText + JSON.stringify(compactEntry) + '\n', 'oversized.txt'), /记录数超过 50000/);
assert.throws(() => model.parseImport(JSON.stringify({ ...fullTextSnapshot, entries: [...fullTextSnapshot.entries, compactEntry] }), 'oversized.json'), /记录数超过 50000/);

const xss = '<img src=x onerror="global.compromised=true">';
const untrusted = { ...snapshot, range: model.stats(parsed.entries).timeRange, invalidCount: 0, unsupportedCount: 0,
  entries: [{ ...parsed.entries[0], message: xss, detail: '<script>global.compromised=true</script>' }] };
const inert = model.parseImport(model.exportJson(untrusted), 'xss.json');
assert.equal(inert.entries[0].message, xss);
assert.equal(global.compromised, undefined, 'model treats imported content as text, never executes it');
assert.equal(model.parseImport(model.exportText(inert), 'xss.txt').entries[0].detail, untrusted.entries[0].detail);

process.stdout.write('Log model parsing, statistics, import/export and input-boundary tests passed.\n');
