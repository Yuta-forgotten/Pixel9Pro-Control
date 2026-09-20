'use strict';
(() => {
  // Pure transforms for the shared history sheet. No DOM or request state lives here.
  const RANGES = Object.freeze([
    { id: '15', minutes: 15, label: '15 分钟', shortLabel: '15 分' },
    { id: '30', minutes: 30, label: '30 分钟', shortLabel: '30 分' },
    { id: '60', minutes: 60, label: '60 分钟', shortLabel: '60 分' },
    { id: '720', minutes: 720, label: '12 小时', shortLabel: '12 小时' },
    { id: 'custom', minutes: 0, label: '自定义', shortLabel: '自定义' }
  ]);

  const finite = (value) => Number.isFinite(Number(value)) ? Number(value) : null;
  const sortPoints = (points) => (Array.isArray(points) ? points : [])
    .map((point) => ({ ...point, ts: finite(point.ts) }))
    .filter((point) => point.ts !== null && point.ts > 0)
    .sort((a, b) => a.ts - b.ts);

  function rangeFor(id) {
    return RANGES.find((range) => range.id === String(id)) || RANGES[1];
  }

  function normalizeThermal(payload) {
    const source = Array.isArray(payload) ? payload : (payload?.points || payload?.thermal);
    const mapped = (Array.isArray(source) ? source : []).map((point) => {
      if (Array.isArray(point)) return { ts: point[0], tempC: Number(point[1]) / 1000 };
      const raw = point.virtual_skin_mc ?? point.temp_mc ?? point.temp ?? point.value;
      const value = Number(raw);
      return { ts: point.ts, tempC: value > 200 ? value / 1000 : value };
    }).filter((point) => Number.isFinite(Number(point.ts)) && Number.isFinite(point.tempC) && point.tempC > -20 && point.tempC < 120);
    return sortPoints(mapped);
  }

  function normalizePower(payload) {
    const source = Array.isArray(payload) ? payload : payload?.power;
    const mapped = (Array.isArray(source) ? source : []).map((point) => {
      if (Array.isArray(point)) return { ts: point[0], levelPct: finite(point[1]), chargeUah: finite(point[2]), status: String(point[3] || '') };
      return {
        ts: point.ts,
        screen: point.screen || 'unknown',
        levelPct: finite(point.level_pct ?? point.level),
        chargeUah: finite(point.charge_uah ?? point.charge),
        currentUa: finite(point.current_ua),
        voltageUv: finite(point.voltage_uv),
        status: String(point.status || ''),
        quality: String(point.quality || point.sample_quality || '')
      };
    });
    return sortPoints(mapped).filter((point) => point.chargeUah !== null || (point.currentUa !== null && point.voltageUv !== null));
  }

  function gapThreshold(points, minimum = 90, multiplier = 4) {
    const deltas = [];
    for (let i = 1; i < points.length; i += 1) {
      const delta = points[i].ts - points[i - 1].ts;
      if (delta > 0) deltas.push(delta);
    }
    deltas.sort((a, b) => a - b);
    const median = deltas.length ? deltas[Math.floor(deltas.length / 2)] : minimum;
    // A two-point window must still reveal a long pause; using the only large
    // delta as its own baseline would incorrectly turn the gap into continuity.
    const typical = deltas.length <= 2 ? Math.min(...deltas, minimum) : median;
    return Math.max(minimum, typical * multiplier);
  }

  function segments(points, threshold) {
    const out = [];
    const gaps = [];
    let segment = [];
    points.forEach((point, index) => {
      if (index > 0 && point.ts - points[index - 1].ts > threshold) {
        if (segment.length) out.push(segment);
        gaps.push([points[index - 1], point]);
        segment = [];
      }
      segment.push(point);
    });
    if (segment.length) out.push(segment);
    return { segments: out, gaps, threshold };
  }

  function temperatureStats(points) {
    const sorted = sortPoints(points);
    if (!sorted.length) return { points: [], count: 0, coverageSec: 0, gaps: [], quality: 'no_data' };
    const { segments: runs, gaps, threshold } = segments(sorted, gapThreshold(sorted));
    const values = sorted.map((point) => point.tempC).filter(Number.isFinite);
    const current = values[values.length - 1];
    const min = Math.min(...values);
    const max = Math.max(...values);
    const avg = values.reduce((sum, value) => sum + value, 0) / values.length;
    let thresholdSec = 0;
    const thresholdValue = Number.isFinite(Number(globalThis.THRESH_STOCK)) ? Number(globalThis.THRESH_STOCK) : 37;
    sorted.slice(1).forEach((point, index) => {
      const previous = sorted[index];
      const delta = point.ts - previous.ts;
      if (delta <= threshold && previous.tempC >= thresholdValue) thresholdSec += delta;
    });
    return {
      points: sorted,
      runs,
      gaps,
      gapThresholdSec: threshold,
      count: sorted.length,
      startTs: sorted[0].ts,
      endTs: sorted[sorted.length - 1].ts,
      coverageSec: Math.max(0, sorted[sorted.length - 1].ts - sorted[0].ts),
      current, min, avg, max, thresholdSec,
      quality: values.length >= 2 ? (gaps.length ? 'partial' : 'good') : 'insufficient'
    };
  }

  function powerStats(points) {
    const sorted = sortPoints(points);
    if (!sorted.length) return { points: [], series: [], count: 0, quality: 'no_data' };
    const threshold = gapThreshold(sorted, 180, 4);
    const series = [];
    const gaps = [];
    let consumedUah = 0;
    let activeSec = 0;
    let measuredMw = 0;
    let measuredSec = 0;
    for (let i = 1; i < sorted.length; i += 1) {
      const previous = sorted[i - 1];
      const point = sorted[i];
      const deltaSec = point.ts - previous.ts;
      if (deltaSec <= 0) continue;
      if (deltaSec > threshold) {
        gaps.push([previous, point]);
        continue;
      }
      if (Number.isFinite(previous.chargeUah) && Number.isFinite(point.chargeUah)) {
        const deltaUah = previous.chargeUah - point.chargeUah;
        // Only positive charge-counter drops prove discharge. Charge gain is not
        // silently turned into negative consumption.
        if (deltaUah > 0 && previous.status !== 'Charging' && point.status !== 'Charging') {
          consumedUah += deltaUah;
          activeSec += deltaSec;
        }
      }
      if (Number.isFinite(previous.currentUa) && Number.isFinite(previous.voltageUv)) {
        const mw = Math.abs(previous.currentUa * previous.voltageUv) / 1e9;
        if (Number.isFinite(mw) && mw >= 0) {
          measuredMw += mw * deltaSec;
          measuredSec += deltaSec;
        }
      }
      let chargeSeriesAdded = false;
      if (Number.isFinite(point.chargeUah) && Number.isFinite(previous.chargeUah)) {
        const net = previous.chargeUah - point.chargeUah;
        if (net > 0 && previous.status !== 'Charging' && point.status !== 'Charging') {
          series.push({ ts: point.ts, value: (net / 1000) * 3600 / deltaSec, unit: 'mAh/h' });
          chargeSeriesAdded = true;
        }
      }
      if (!chargeSeriesAdded && Number.isFinite(previous.currentUa) && Number.isFinite(previous.voltageUv)) {
        series.push({ ts: point.ts, value: Math.abs(previous.currentUa * previous.voltageUv) / 1e9, unit: 'mW' });
      }
    }
    const avgMahPerHour = activeSec > 0 ? (consumedUah / 1000) * 3600 / activeSec : null;
    const avgMw = measuredSec > 0 ? measuredMw / measuredSec : null;
    const resetDetected = sorted.some((point) => /reset|mismatch/i.test(String(point.quality || '')));
    return {
      points: sorted,
      series,
      gaps,
      gapThresholdSec: threshold,
      count: sorted.length,
      startTs: sorted[0].ts,
      endTs: sorted[sorted.length - 1].ts,
      coverageSec: Math.max(0, sorted[sorted.length - 1].ts - sorted[0].ts),
      consumedMah: resetDetected ? null : (consumedUah > 0 ? consumedUah / 1000 : null),
      avgMahPerHour: resetDetected ? null : avgMahPerHour,
      avgMw,
      activeSec,
      quality: resetDetected ? 'reset_or_mismatch' : (consumedUah > 0 || avgMw !== null ? (gaps.length ? 'partial' : 'good') : 'insufficient')
    };
  }

  function clip(points, startTs, endTs) {
    const start = finite(startTs);
    const end = finite(endTs);
    return (Array.isArray(points) ? points : []).filter((point) => {
      const ts = Number(point.ts);
      return Number.isFinite(ts) && (start === null || ts >= start) && (end === null || ts <= end);
    });
  }

  registerFeature('analyticsModel', {
    ranges: () => RANGES.map((range) => ({ ...range })),
    rangeFor,
    normalizeThermal,
    normalizePower,
    temperatureStats,
    powerStats,
    clip,
    formatDuration(sec) {
      const value = Number(sec);
      if (!Number.isFinite(value) || value < 0) return '—';
      if (value >= 3600) return `${Math.floor(value / 3600)}小时${Math.floor((value % 3600) / 60)}分`;
      if (value >= 60) return `${Math.floor(value / 60)}分${Math.floor(value % 60)}秒`;
      return `${Math.floor(value)}秒`;
    }
  });
})();
