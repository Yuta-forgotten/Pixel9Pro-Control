const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');

// The model consumes the same feature registry as the shipped WebUI. Canvas
// calls are recorded at the real view boundary; tests do not reimplement draw.
function harness() {
  const features = {};
  const strokes = [];
  const labels = [];
  const dashCalls = [];
  let dash = [];
  let currentPath = [];
  const saved = [];
  const context = {
    setTransform() {}, clearRect() { strokes.length = 0; labels.length = 0; dashCalls.length = 0; },
    setLineDash(value) { dash = Array.from(value); dashCalls.push(dash); },
    save() { saved.push({ dash, strokeStyle: this.strokeStyle }); },
    restore() { Object.assign(this, saved.pop()); dash = this.dash; },
    beginPath() { currentPath = []; },
    moveTo(x, y) { currentPath.push({ kind: 'move', x, y }); },
    lineTo(x, y) { currentPath.push({ kind: 'line', x, y }); },
    arc(x, y) { currentPath.push({ kind: 'point', x, y }); },
    fill() {},
    stroke() { strokes.push({ dash: dash.slice(), points: currentPath.slice(), color: this.strokeStyle }); },
    fillText(value, x, y) { labels.push({ value: String(value), x, y, align: this.textAlign }); }
  };
  class Element {
    constructor(tag) {
      this.tagName = tag; this.children = []; this.dataset = {}; this.attributes = {};
      this.style = {}; this.className = ''; this.textContent = ''; this.listeners = {};
      this.classList = {
        toggle: (name, force) => {
          const classes = new Set(this.className.split(' ').filter(Boolean));
          if (force) classes.add(name); else classes.delete(name);
          this.className = Array.from(classes).join(' ');
        }
      };
    }
    append(...children) { children.forEach((child) => this.appendChild(child)); }
    appendChild(child) { this.children.push(child); return child; }
    replaceChildren(...children) { this.children = []; this.append(...children); }
    setAttribute(name, value) { this.attributes[name] = String(value); }
    getAttribute(name) { return this.attributes[name] ?? null; }
    addEventListener(name, callback) { this.listeners[name] = callback; }
    focus() { this.focused = true; }
    click() { this.listeners.click?.(); }
    get options() { return this.children; }
    get childElementCount() { return this.children.length; }
    getBoundingClientRect() { return { width: 320, height: 210 }; }
    getContext() { return context; }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
    querySelectorAll(selector) {
      const matches = (node) => {
        if (selector.startsWith('.')) return node.className.split(' ').includes(selector.slice(1));
        if (selector.startsWith('[data-')) {
          const key = selector.slice(6, -1).replace(/-([a-z])/g, (_, char) => char.toUpperCase());
          return key in node.dataset;
        }
        if (selector === '[role="tab"]') return node.attributes.role === 'tab';
        return node.tagName === selector;
      };
      return this.children.flatMap((child) => [...(matches(child) ? [child] : []), ...child.querySelectorAll(selector)]);
    }
  }
  const sandbox = {
    registerFeature(name, value) { features[name] = value; },
    requireFeature(name) { if (!features[name]) throw new Error(`Missing feature ${name}`); return features[name]; },
    document: { documentElement: new Element('html'), createElement: (tag) => new Element(tag) },
    window: { devicePixelRatio: 3 },
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    THRESH_STOCK: 37
  };
  vm.createContext(sandbox);
  for (const file of ['analytics_model.js', 'analytics_view.js']) {
    vm.runInContext(fs.readFileSync(path.join(root, 'webroot', 'js', file), 'utf8'), sandbox, { filename: file });
  }
  const view = features.analyticsView.create({ onSource() {}, onRange() {}, onCustom() {}, onCapture() {}, onCaptureExport() {}, onExport() {} });
  const render = (source, stats) => features.analyticsView.update(view, { source, rangeId: '30', stats, status: '', summary: null, capture: null });
  return { model: features.analyticsModel, viewAPI: features.analyticsView, view, render, strokes, labels, dashCalls };
}

const power = (ts, chargeUah, extra = {}) => ({ ts, chargeUah, currentUa: null, voltageUv: null, status: 'Discharging', screen: 'on', ...extra });
const thermal = (ts, tempC) => ({ ts, tempC });

test('nullable and malformed CGI readings remain missing evidence, never fabricated zeros', () => {
  const { model } = harness();
  const normalized = model.normalizePower({ power: [
    { ts: 1000, charge_uah: null, current_ua: null, voltage_uv: null, level_pct: 40, status: 'Discharging' },
    { ts: 1060, charge_uah: '', current_ua: false, voltage_uv: ' ', status: 'Discharging' },
    { ts: 1120, charge_uah: -1, current_ua: 'bad', voltage_uv: 0, status: 'Discharging' }
  ] });
  assert.equal(normalized.length, 3, 'missing samples remain interval barriers');
  normalized.forEach((point) => {
    assert.equal(point.chargeUah, null); assert.equal(point.currentUa, null); assert.equal(point.voltageUv, null);
  });
  const stats = model.powerStats(normalized);
  assert.equal(stats.series.length, 0); assert.equal(stats.avgMw, null); assert.equal(stats.consumedMah, null);
  assert.equal(stats.unknownSec, 120); assert.equal(stats.quality, 'no_data');
  assert.equal(model.formatDuration(null), '—');
  assert.equal(model.formatDuration(undefined), '—');
  assert.equal(model.formatDuration(''), '—');
});

test('temperature nulls preserve a break and do not add threshold time', () => {
  const { model } = harness();
  const normalized = model.normalizeThermal({ thermal: [
    { ts: 1000, virtual_skin_mc: 38000 }, { ts: 1060, virtual_skin_mc: null },
    { ts: 1120, virtual_skin_mc: 39000 }, { ts: 1180, virtual_skin_mc: 38000 }
  ] });
  assert.equal(normalized[1].tempC, null);
  const stats = model.temperatureStats(normalized);
  assert.equal(stats.count, 3); assert.equal(stats.sampleCount, 4);
  assert.equal(stats.coverageSec, 60); assert.equal(stats.unknownSec, 120); assert.equal(stats.thresholdSec, 60);
  assert.equal(stats.min, 38); assert.equal(stats.current, 38); assert.equal(stats.chartSegments.length, 2);
  assert.equal(stats.gapRanges[0].startTs, 1000); assert.equal(stats.gapRanges[0].endTs, 1120);
});

test('producer cadence is valid for 60s on-screen and 600s off-screen intervals', () => {
  const { model } = harness();
  const on = model.powerStats([power(1000, 5000000), power(1060, 4999000), power(1120, 4998000)]);
  assert.equal(on.coverageSec, 120); assert.equal(on.activeSec, 120); assert.equal(on.unknownSec, 0);
  assert.equal(on.avgMahPerHour, 60); assert.equal(on.consumedMah, 2); assert.equal(on.quality, 'good');
  assert.equal(on.seriesUnit, 'mAh/h'); assert.equal(on.gapRanges.length, 0);
  const off = model.powerStats([power(1000, 5000000, { screen: 'off' }), power(1600, 4999000, { screen: 'off' })]);
  assert.equal(off.coverageSec, 600); assert.equal(off.avgMahPerHour, 6); assert.equal(off.quality, 'good');
  const legacy = model.powerStats(model.normalizePower([[1000, 80, 5000000, 'Discharging'], [1600, 79, 4999000, 'Discharging']]));
  assert.equal(legacy.coverageSec, 600); assert.equal(legacy.quality, 'good');
});

test('explicit hourly granularity permits normal bucket cadence without inventing bucket averages', () => {
  const { model } = harness();
  const points = [power(3600, 5000000), power(7200, 4999000), power(10800, 4998000)];
  const stats = model.powerStats(points, { granularity: 'hour', startTs: 3600, endTs: 10800 });
  assert.equal(stats.coverageSec, 7200); assert.equal(stats.unknownSec, 0); assert.equal(stats.avgMahPerHour, 1);
  assert.equal(model.powerStats(points).coverageSec, 0, 'raw on-screen history must not infer hours as normal');
});

test('long power gap creates separate interval traces and does not consume the missing counter difference', () => {
  const { model } = harness();
  const stats = model.powerStats([power(1000, 5000000), power(1060, 4999000), power(2200, 4900000), power(2260, 4899000)]);
  assert.equal(stats.chartSegments.length, 2); assert.equal(stats.series.length, 2);
  assert.equal(stats.chartSegments[0].at(-1).ts, 1060); assert.equal(stats.chartSegments[1][0].ts, 2200);
  assert.equal(stats.consumedMah, 2); assert.equal(stats.activeSec, 120); assert.equal(stats.unknownSec, 1140);
  assert.equal(stats.gapRanges[0].startTs, 1060); assert.equal(stats.gapRanges[0].endTs, 2200);
  assert.equal(stats.quality, 'partial');
});

test('two-point long pause remains missing for both thermal and power', () => {
  const { model } = harness();
  const temp = model.temperatureStats([thermal(1000, 38), thermal(8200, 40)]);
  assert.equal(temp.thresholdSec, 0); assert.equal(temp.coverageSec, 0); assert.equal(temp.unknownSec, 7200);
  assert.equal(temp.chartSegments.length, 2);
  const stats = model.powerStats([power(1000, 5000000, { screen: 'unknown' }), power(8200, 4999000, { screen: 'unknown' })]);
  assert.equal(stats.series.length, 0); assert.equal(stats.consumedMah, null); assert.equal(stats.unknownSec, 7200);
});

test('missing middle power reading cannot be bridged even within normal cadence', () => {
  const { model } = harness();
  const normalized = model.normalizePower({ power: [
    { ts: 1000, charge_uah: 5000000, status: 'Discharging', screen: 'on' },
    { ts: 1060, charge_uah: null, current_ua: null, voltage_uv: null, status: 'Discharging', screen: 'on' },
    { ts: 1120, charge_uah: 4998000, status: 'Discharging', screen: 'on' },
    { ts: 1180, charge_uah: 4997000, status: 'Discharging', screen: 'on' }
  ] });
  const stats = model.powerStats(normalized);
  assert.equal(stats.activeSec, 60); assert.equal(stats.unknownSec, 120); assert.equal(stats.consumedMah, 1);
  assert.equal(stats.chartSegments[0][0].ts, 1120);
});

test('charging transitions and unknown status never become discharge or join surrounding runs', () => {
  const { model } = harness();
  const stats = model.powerStats([
    power(1000, 5000000), power(1060, 4999000),
    power(1120, 4998000, { status: 'Charging' }), power(1180, 4999000, { status: 'Charging' }),
    power(1240, 4998000), power(1300, 4997000)
  ]);
  assert.equal(stats.consumedMah, 2); assert.equal(stats.activeSec, 120); assert.equal(stats.nonDischargeSec, 60);
  assert.equal(stats.unknownSec, 120); assert.equal(stats.chartSegments.length, 2);
  assert.equal(stats.quality, 'partial');
  const unknown = model.powerStats([power(1000, 5000000, { status: '' }), power(1060, 4999000, { status: '' })]);
  assert.equal(unknown.consumedMah, null); assert.equal(unknown.unknownSec, 60);
});

test('counter/current measurements have separate units and a single chart never mixes them', () => {
  const { model } = harness();
  const sensors = { currentUa: -1000000, voltageUv: 4000000 };
  const stats = model.powerStats([
    power(1000, 5000000, sensors), power(1060, 4999000, sensors),
    power(1120, null, sensors), power(1180, null, sensors)
  ]);
  assert.equal(stats.avgMw, 4000); assert.equal(stats.measuredSec, 180);
  assert.equal(stats.avgMahPerHour, 60); assert.equal(stats.activeSec, 60);
  assert.equal(stats.seriesUnit, 'mAh/h'); assert.equal(stats.series.length, 1);
  assert.equal(stats.series[0].value, 60); assert.equal(stats.unknownSec, 120);
  const current = model.powerStats([power(1000, null, sensors), power(1060, null, sensors)]);
  assert.equal(current.seriesUnit, 'mW'); assert.equal(current.series[0].value, 4000);
  assert.equal(current.consumedMah, null); assert.equal(current.avgMahPerHour, null);
});

test('real unchanged counters can prove zero while missing counters cannot', () => {
  const { model } = harness();
  const zero = model.powerStats([power(1000, 5000000), power(1060, 5000000)]);
  assert.equal(zero.consumedMah, 0); assert.equal(zero.avgMahPerHour, 0); assert.equal(zero.quality, 'good');
  const missing = model.powerStats([power(1000, null), power(1060, null)]);
  assert.equal(missing.consumedMah, null); assert.equal(missing.avgMahPerHour, null);
});

test('counter reset invalidates counter totals but retains independently measured current', () => {
  const { model } = harness();
  const sensors = { currentUa: -1000000, voltageUv: 4000000 };
  const stats = model.powerStats([power(1000, 4000000, sensors), power(1060, 6000000, sensors), power(1120, 5999000, sensors)]);
  assert.equal(stats.quality, 'reset_or_mismatch'); assert.equal(stats.consumedMah, null); assert.equal(stats.avgMahPerHour, null);
  assert.equal(stats.activeSec, 0); assert.equal(stats.avgMw, 4000); assert.equal(stats.seriesUnit, 'mW');
  const sessionReset = model.powerStats([power(1000, 5000000), power(1060, 4999000)], { quality: 'reset_or_mismatch' });
  assert.equal(sessionReset.consumedMah, null); assert.equal(sessionReset.series.length, 0);
});

test('window clipping accounts for boundary uncertainty and never imports an outside counter difference', () => {
  const { model } = harness();
  const stats = model.powerStats([power(900, 5100000), power(1060, 5000000), power(1120, 4999000), power(1200, 4900000)], { startTs: 1000, endTs: 1180 });
  assert.equal(stats.startTs, 1000); assert.equal(stats.endTs, 1180);
  assert.equal(stats.count, 2); assert.equal(stats.consumedMah, 1); assert.equal(stats.coverageSec, 60);
  assert.equal(stats.unknownSec, 120); assert.equal(stats.gapRanges.length, 2);
  const empty = model.temperatureStats([], { startTs: 1000, endTs: 1180 });
  assert.equal(empty.current, null); assert.equal(empty.min, null); assert.equal(empty.avg, null);
  assert.equal(empty.unknownSec, 180); assert.equal(empty.quality, 'no_data');
});

test('unsorted duplicate timestamps are coalesced without zero-interval division', () => {
  const { model } = harness();
  const stats = model.powerStats([power(1120, 4998000), power(1000, 5000000), power(1060, 4999500), power(1060, 4999000), { ts: null }]);
  assert.equal(stats.count, 3); assert.equal(stats.avgMahPerHour, 60); assert.equal(stats.consumedMah, 2);
  stats.series.forEach((point) => assert(Number.isFinite(point.value)));
});

test('real view issues dashed gap strokes and solid interval strokes without crossing the gap', () => {
  const h = harness();
  const stats = h.model.powerStats([power(1000, 5000000), power(1060, 4999000), power(2200, 4900000), power(2260, 4899000)]);
  h.render('power', stats);
  assert(h.dashCalls.some((value) => value[0] === 6 && value[1] === 5));
  const dashed = h.strokes.filter((stroke) => stroke.dash.length);
  const data = h.strokes.filter((stroke) => stroke.color === '#006b57');
  assert.equal(dashed.length, 1); assert.equal(data.length, 2);
  assert(data.every((stroke) => stroke.dash.length === 0));
  assert(data[0].points.at(-1).x < data[1].points[0].x);
  assert(dashed[0].points[0].x >= data[0].points.at(-1).x);
  assert(dashed[0].points.at(-1).x <= data[1].points[0].x);
  assert(h.view.canvas.attributes['aria-label'].includes('未知 19分0秒'));
  assert.equal(h.view.canvas.width, 640, 'DPR remains capped at 2');
});

test('normal chart never uses dashed stroke, and a two-point all-gap window still does', () => {
  const h = harness();
  h.render('power', h.model.powerStats([power(1000, 5000000), power(1060, 4999000), power(1120, 4998000)]));
  assert(h.strokes.every((stroke) => stroke.dash.length === 0));
  assert(h.dashCalls.every((value) => value.length === 0));
  h.render('power', h.model.powerStats([power(1000, 5000000), power(8200, 4900000)]));
  assert(h.strokes.some((stroke) => stroke.dash.length));
  assert(!h.strokes.some((stroke) => stroke.color === '#006b57'));
});

test('chart and summary show finite labels, complete window endpoints and readable units', () => {
  const h = harness();
  const stats = h.model.temperatureStats([thermal(1060, 38), thermal(1120, 39)], { startTs: 1000, endTs: 1180 });
  h.render('thermal', stats);
  const endpoints = h.labels.filter((item) => item.y === 202);
  assert.equal(endpoints.length, 2); assert.equal(endpoints[0].align, 'left'); assert.equal(endpoints[1].align, 'right');
  assert.equal(endpoints[0].value, new Date(1000000).toLocaleString([], { hour: '2-digit', minute: '2-digit' }));
  assert.equal(endpoints[1].value, new Date(1180000).toLocaleString([], { hour: '2-digit', minute: '2-digit' }));
  assert(h.labels.some((item) => item.value === '°C'));
  assert(h.labels.every((item) => !/NaN|undefined|Infinity|Invalid Date/.test(item.value) && Number.isFinite(item.x) && Number.isFinite(item.y)));
  assert(!/NaN|undefined/.test(h.view.legend.textContent + h.view.heroValue.textContent));
  h.render('thermal', h.model.temperatureStats([], { startTs: 1000, endTs: 1180 }));
  assert.equal(h.view.heroValue.textContent, '—');
  assert(h.view.summary.every((item) => item.querySelector('strong').textContent === '—'));
});

test('custom day options submit numeric values rather than translated display labels', () => {
  const { view, viewAPI } = harness();
  assert.deepEqual(view.customDays.options.map((option) => option.value), ['1', '2', '3', '4', '5', '6', '7']);
  viewAPI.setCustomValues(view, 3, 'minute');
  assert.equal(view.customDays.value, '3'); assert.equal(view.customGranularity.value, 'minute');
});

test('keyboard navigation reaches source/range tabs and loading clears the previous source chart', () => {
  const h = harness();
  const groups = [h.view.sourceGroup, h.view.rangeGroup];
  groups.forEach((group) => {
    let prevented = false;
    group.listeners.keydown({ target: group.children[0], key: 'ArrowRight', preventDefault() { prevented = true; } });
    assert(prevented); assert(group.children[1].focused);
  });
  h.render('power', h.model.powerStats([power(1000, 5000000), power(1060, 4999000)]));
  assert(h.strokes.length > 0);
  h.viewAPI.loading(h.view, 'thermal', '60');
  assert.equal(h.strokes.length, 0); assert.equal(h.view.heroValue.textContent, '—');
  assert(h.view.heroKicker.textContent.includes('温度'));
  assert(!h.view.legend.textContent.includes('mAh'));
});

test('multiday endpoints split date and time so a narrow chart preserves both labels', () => {
  const h = harness();
  h.render('thermal', h.model.temperatureStats([thermal(1000, 38), thermal(865000, 39)]));
  assert.equal(h.labels.filter((label) => label.y === 202).length, 2);
  assert.equal(h.labels.filter((label) => label.y === 187).length, 2);
  const dash = h.strokes.find((stroke) => stroke.dash.length);
  assert(dash.points[0].y < 175, 'gap mark must not overlap the date text');
});
