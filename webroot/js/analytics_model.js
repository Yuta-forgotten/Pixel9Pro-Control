'use strict';
(() => {
  const RANGES = Object.freeze([
    { id: '15', minutes: 15, label: '15 分钟', shortLabel: '15 分' },
    { id: '30', minutes: 30, label: '30 分钟', shortLabel: '30 分' },
    { id: '60', minutes: 60, label: '60 分钟', shortLabel: '60 分' },
    { id: '720', minutes: 720, label: '12 小时', shortLabel: '12 小时' },
    { id: '1440', minutes: 1440, label: '1 天', shortLabel: '1 天' },
    { id: '4320', minutes: 4320, label: '3 天', shortLabel: '3 天' },
    { id: '10080', minutes: 10080, label: '7 天', shortLabel: '7 天' },
    { id: 'custom', minutes: 0, label: '自定义', shortLabel: '自定义' }
  ]);
  const number = (value) => {
    if (value === null || value === undefined || value === '' || (typeof value !== 'number' && typeof value !== 'string')) return null;
    const result = Number(value);
    return Number.isFinite(result) ? result : null;
  };
  const positive = (value) => { const result = number(value); return result !== null && result >= 0 ? result : null; };
  const temperature = (value, milli = false) => {
    const result = number(value);
    const celsius = result === null ? null : (milli || Math.abs(result) > 180 ? result / 1000 : result);
    return celsius !== null && celsius > -20 && celsius < 120 ? celsius : null;
  };
  const identity = (point, fallback = '') => {
    const values = [point.segment_id ?? point.segmentId, point.boot_id ?? point.bootId, point.session_id ?? point.sessionId].filter((value) => value !== null && value !== undefined && value !== '');
    return values.length ? values.join('|') : String(fallback || '');
  };
  const metaIdentity = (meta) => identity(meta, '');
  const sort = (points) => (Array.isArray(points) ? points : []).filter(Boolean).map((point) => ({ ...point, ts: number(point.ts) })).filter((point) => point.ts !== null && point.ts > 0).sort((a, b) => a.ts - b.ts);
  const sameSegment = (left, right) => {
    const leftId = String(left?.segmentId || '');
    const rightId = String(right?.segmentId || '');
    return (!leftId && !rightId) || leftId === rightId;
  };
  const envelope = (payload) => payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : {};
  function rangeFor(id) { return RANGES.find((item) => item.id === String(id)) || RANGES[1]; }

  function normalizeThermal(payload) {
    const meta = envelope(payload); const source = Array.isArray(payload) ? payload : (payload?.thermal || payload?.points || []);
    const fallbackSegment = metaIdentity(meta); const fallbackSource = meta.source || 'module';
    return sort(source.map((point) => {
      if (Array.isArray(point)) return { ts: point[0], tempC: temperature(point[1], true), sensor: fallbackSource === 'system' ? 'battery' : 'module', source: fallbackSource, segmentId: fallbackSegment };
      if (!point || typeof point !== 'object') return null;
      const sourceName = String(point.source || fallbackSource); const system = sourceName === 'android' || sourceName === 'system' || point.sensor === 'battery' || 'battery_mc' in point;
      const raw = system ? (point.battery_mc ?? point.battery_temp_mc ?? point.temp_mc ?? point.temp) : (point.virtual_skin_mc ?? point.temp_mc ?? point.temp ?? point.value);
      const value = temperature(raw, 'battery_mc' in point || 'battery_temp_mc' in point || 'temp_mc' in point || 'virtual_skin_mc' in point);
      return { ts: point.ts, tempC: point.valid === false ? null : value, sensor: system ? 'battery' : 'module', source: sourceName, screen: point.screen || 'unknown', segmentId: identity(point, fallbackSegment), quality: String(point.quality || point.sample_quality || '') };
    }));
  }

  function normalizePower(payload) {
    const meta = envelope(payload); const fallbackSegment = metaIdentity(meta);
    const source = Array.isArray(payload) ? payload : (Array.isArray(payload?.power_rates) && payload.power_rates.length ? payload.power_rates : payload?.power || []); const explicitRates = !Array.isArray(payload) && Array.isArray(payload?.power_rates) && payload.power_rates.length > 0;
    return sort(source.map((point) => {
      if (Array.isArray(point)) return { ts: point[0], startTs: null, endTs: number(point[0]), intervalSec: null, levelPct: number(point[1]), chargeUah: positive(point[2]), currentUa: null, voltageUv: null, rateMahH: null, mah: null, screen: 'unknown', status: String(point[3] || ''), source: 'module', segmentId: fallbackSegment, valid: positive(point[2]) !== null, explicitRate: false };
      if (!point || typeof point !== 'object') return null;
      const requestedStart = number(point.start_ts ?? point.startTs ?? point.ts_start); const endTs = number(point.end_ts ?? point.endTs ?? point.ts ?? point.timestamp); const intervalSec = positive(point.interval_sec) ?? (requestedStart !== null && endTs !== null ? Math.max(0, endTs - requestedStart) : null); const startTs = requestedStart ?? (endTs !== null && intervalSec !== null ? endTs - intervalSec : null);
      const rate = number(point.rate_mah_h ?? point.rateMahH ?? point.system_rate_mah_h); const mah = positive(point.mah ?? point.system_mah); const chargeUah = positive(point.charge_uah ?? point.charge); const currentUa = number(point.current_ua); const voltageUv = positive(point.voltage_uv); const explicit = explicitRates || startTs !== null && endTs !== null && (rate !== null || mah !== null); const valid = point.valid === false || point.power_valid === false ? false : explicit ? (rate !== null || mah !== null) : (chargeUah !== null || (currentUa !== null && voltageUv !== null && voltageUv > 0));
      return { ts: endTs, startTs, endTs, intervalSec, levelPct: number(point.level_pct ?? point.level), chargeUah, currentUa, voltageUv: voltageUv !== null && voltageUv > 0 ? voltageUv : null, rateMahH: rate, mah, screen: point.screen || 'unknown', status: String(point.status || point.charge_status || ''), source: point.source || (explicit ? 'android' : 'module'), segmentId: identity(point, fallbackSegment), quality: String(point.quality || point.sample_quality || ''), valid, explicitRate: explicit };
    }));
  }
  function explicitGaps(payload) { const list = envelope(payload).gaps; return (Array.isArray(list) ? list : []).map((gap) => { const start = gap && typeof gap === 'object' && !Array.isArray(gap) ? gap.start_ts ?? gap.startTs : Array.isArray(gap) ? gap[0]?.ts ?? gap[0] : null; const end = gap && typeof gap === 'object' && !Array.isArray(gap) ? gap.end_ts ?? gap.endTs : Array.isArray(gap) ? gap[1]?.ts ?? gap[1] : null; return { startTs: number(start), endTs: number(end), reason: String(gap?.reason || 'backend_gap'), segmentId: String(gap?.segment_id ?? gap?.segmentId ?? '') }; }).filter((gap) => gap.startTs !== null && gap.endTs !== null && gap.endTs > gap.startTs); }
  function clip(points, startTs, endTs, intervalAware = false) { const start = number(startTs); const end = number(endTs); return (Array.isArray(points) ? points : []).filter((point) => { const from = intervalAware && point.startTs !== null ? number(point.startTs) : number(point.ts); const to = intervalAware && point.endTs !== null ? number(point.endTs) : number(point.ts); return from !== null && to !== null && to >= from && (start === null || from >= start) && (end === null || to <= end); }); }
  function addGap(list, startTs, endTs, reason, segmentId = '') { if (!(endTs > startTs)) return; const previous = list[list.length - 1]; if (previous && previous.endTs >= startTs && previous.reason === reason) previous.endTs = Math.max(previous.endTs, endTs); else list.push({ startTs, endTs, reason, segmentId }); }
  function windowFor(points, options) { const startTs = number(options.startTs) ?? points[0]?.ts ?? null; const endTs = number(options.endTs) ?? points[points.length - 1]?.ts ?? null; return { startTs, endTs, elapsedSec: startTs !== null && endTs !== null ? Math.max(0, endTs - startTs) : 0 }; }
  function backendGapRanges(options, window) { return (Array.isArray(options.backendGaps) ? options.backendGaps : []).map((gap) => ({ ...gap, startTs: Math.max(window.startTs ?? gap.startTs, gap.startTs), endTs: Math.min(window.endTs ?? gap.endTs, gap.endTs) })).filter((gap) => gap.endTs > gap.startTs); }

  function temperatureStats(points, options = {}) {
    const sorted = sort(clip(points, options.startTs, options.endTs)); const window = windowFor(sorted, options); const gaps = backendGapRanges(options, window); const valid = sorted.filter((point) => temperature(point.tempC) !== null); const runs = []; let run = []; let coverageSec = 0; let thresholdSec = 0; const threshold = number(globalThis.THRESH_STOCK) ?? 37;
    sorted.forEach((point, index) => { const previous = sorted[index - 1]; const value = temperature(point.tempC); if (previous) { const delta = point.ts - previous.ts; const explicit = gaps.some((gap) => gap.startTs < point.ts && gap.endTs > previous.ts); const reason = !sameSegment(previous, point) ? 'session_changed' : delta > 1800 ? 'missing' : previous.tempC === null || value === null ? 'missing_measurement' : explicit ? 'backend_gap' : ''; const blocked = Boolean(reason); if (!blocked) { coverageSec += delta; if (previous.tempC >= threshold) thresholdSec += delta; } else { if (!explicit) addGap(gaps, previous.ts, point.ts, reason, point.segmentId); if (run.length) { runs.push(run); run = []; } } } if (value !== null) run.push({ ...point, tempC: value }); }); if (run.length) runs.push(run);
    const values = valid.map((point) => temperature(point.tempC));
    const min = values.reduce((current, value) => Math.min(current, value), Infinity);
    const max = values.reduce((current, value) => Math.max(current, value), -Infinity);
    const last = valid.length ? valid[valid.length - 1] : null;
    return { ...window, points: sorted, runs, gapRanges: gaps, gaps: gaps.map((gap) => [{ ts: gap.startTs }, { ts: gap.endTs }]), chartSegments: runs.map((segment) => segment.map((point) => ({ ts: point.ts, value: point.tempC }))), seriesUnit: '°C', count: valid.length, validCount: valid.length, missingCount: sorted.length - valid.length, sampleCount: sorted.length, coverageSec, unknownSec: Math.max(0, window.elapsedSec - coverageSec), lastSampleTs: last ? last.ts : null, current: values.length ? values[values.length - 1] : null, min: values.length ? min : null, max: values.length ? max : null, avg: values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : null, thresholdSec, coveragePct: window.elapsedSec ? Math.min(100, coverageSec * 100 / window.elapsedSec) : 0, quality: values.length ? (gaps.length ? 'partial' : 'good') : 'no_data' };
  }
  function coalesceRates(points) { const sorted = points.filter((point) => point.explicitRate && point.startTs !== null && point.endTs !== null && point.endTs > point.startTs && point.valid !== false).sort((a, b) => a.startTs - b.startTs); const result = []; sorted.forEach((point) => { const previous = result.length ? result[result.length - 1] : null; const mah = point.mah ?? (point.rateMahH * point.intervalSec / 3600); if (previous && previous.endTs === point.startTs && previous.segmentId === point.segmentId && previous.screen === point.screen && previous.quality === point.quality) { previous.mah += mah; previous.endTs = point.endTs; previous.intervalSec = previous.endTs - previous.startTs; previous.rateMahH = previous.mah * 3600 / previous.intervalSec; } else result.push({ ...point, mah, rateMahH: point.rateMahH ?? mah * 3600 / point.intervalSec }); }); return result; }
  function powerStats(points, options = {}) {
    const nativeRates = coalesceRates(points); const window = windowFor(points, options); const backendGaps = backendGapRanges(options, window); const rates = nativeRates.length ? clip(nativeRates, window.startTs, window.endTs, true) : [];
    if (rates.length) { const consumedMah = rates.reduce((sum, rate) => sum + Math.max(0, rate.mah), 0); const coverageSec = rates.reduce((sum, rate) => sum + rate.intervalSec, 0); const chartSegments = rates.map((rate) => [{ ts: rate.startTs, value: rate.rateMahH }, { ts: rate.endTs, value: rate.rateMahH }]); const screenSegments = []; rates.forEach((rate) => { const previous = screenSegments.length ? screenSegments[screenSegments.length - 1] : null; if (previous && previous.screen === rate.screen && previous.endTs === rate.startTs) previous.endTs = rate.endTs; else screenSegments.push({ startTs: rate.startTs, endTs: rate.endTs, screen: rate.screen }); }); const gaps = backendGaps.slice(); const hasGap = (start, end) => gaps.some((gap) => gap.startTs < end && gap.endTs > start); rates.slice(1).forEach((rate, index) => { const previous = rates[index]; if (rate.startTs > previous.endTs && !hasGap(previous.endTs, rate.startTs)) addGap(gaps, previous.endTs, rate.startTs, 'missing', rate.segmentId); if (rate.segmentId !== previous.segmentId && !hasGap(previous.endTs, rate.startTs)) addGap(gaps, previous.endTs, rate.startTs, 'session_changed', rate.segmentId); }); return { ...window, points, series: rates.map((rate) => ({ ts: rate.endTs, startTs: rate.startTs, value: rate.rateMahH, unit: 'mAh/h', screen: rate.screen })), chartSegments, screenSegments, gapRanges: gaps, gaps: gaps.map((gap) => [{ ts: gap.startTs }, { ts: gap.endTs }]), seriesUnit: 'mAh/h', count: rates.length, validCount: rates.length, missingCount: Math.max(0, points.length - rates.length), sampleCount: points.length, coverageSec, unknownSec: Math.max(0, window.elapsedSec - coverageSec), nonDischargeSec: 0, consumedMah, avgMahPerHour: coverageSec ? consumedMah * 3600 / coverageSec : null, avgMw: null, activeSec: coverageSec, measuredSec: 0, coveragePct: window.elapsedSec ? Math.min(100, coverageSec * 100 / window.elapsedSec) : 0, quality: gaps.length ? 'partial' : 'good', native: true }; }
    if (options.native) return { ...window, points, series: [], chartSegments: [], gapRanges: backendGaps, gaps: backendGaps.map((gap) => [{ ts: gap.startTs }, { ts: gap.endTs }]), seriesUnit: 'mAh/h', count: 0, validCount: 0, missingCount: points.length, sampleCount: points.length, coverageSec: 0, unknownSec: window.elapsedSec, nonDischargeSec: 0, consumedMah: null, avgMahPerHour: null, avgMw: null, activeSec: 0, measuredSec: 0, coveragePct: 0, quality: 'no_data', native: true };
    const sorted = sort(clip(points, options.startTs, options.endTs));
    const intervals = [];
    let consumedUah = 0;
    let activeSec = 0;
    let measuredMw = 0;
    let measuredSec = 0;
    let nonDischargeSec = 0;
    let resetDetected = /reset|mismatch/i.test(String(options.quality || ''));
    const gaps = backendGaps.slice();
    for (let index = 1; index < sorted.length; index += 1) {
      const previous = sorted[index - 1];
      const point = sorted[index];
      const delta = point.ts - previous.ts;
      const interval = { startTs: previous.ts, endTs: point.ts, counterRate: null, mw: null, reason: '' };
      intervals.push(interval);
      const previousStatus = String(previous.status || '').trim().toLowerCase();
      const pointStatus = String(point.status || '').trim().toLowerCase();
      const coveredByGap = gaps.some((gap) => gap.startTs < point.ts && gap.endTs > previous.ts);
      if (!sameSegment(previous, point) || delta > 1800 || coveredByGap) { interval.reason = !sameSegment(previous, point) ? 'session_changed' : 'missing'; continue; }
      if (previous.valid === false || point.valid === false) { interval.reason = 'invalid_sample'; continue; }
      if (previousStatus !== pointStatus) { interval.reason = 'state_change'; continue; }
      if (previousStatus !== 'discharging') { interval.reason = 'not_discharging'; nonDischargeSec += delta; continue; }
      if (previous.chargeUah !== null && point.chargeUah !== null) {
        const deltaUah = previous.chargeUah - point.chargeUah;
        if (deltaUah < 0) { resetDetected = true; interval.reason = 'counter_reset'; }
        else if (!resetDetected) { interval.counterRate = deltaUah * 3.6 / delta; consumedUah += deltaUah; activeSec += delta; }
      }
      if (previous.currentUa !== null && previous.voltageUv !== null && point.currentUa !== null && point.voltageUv !== null) {
        interval.mw = Math.abs(previous.currentUa * previous.voltageUv) / 1e9;
        measuredMw += interval.mw * delta;
        measuredSec += delta;
      }
    }
    const seriesUnit = activeSec && !resetDetected ? 'mAh/h' : 'mW';
    const field = seriesUnit === 'mAh/h' ? 'counterRate' : 'mw';
    const chartSegments = [];
    const series = [];
    let segment = [];
    let coverageSec = 0;
    intervals.forEach((interval) => {
      if (Number.isFinite(interval[field])) {
        segment.push({ ts: interval.startTs, value: interval[field] }, { ts: interval.endTs, value: interval[field] });
        series.push({ ts: interval.endTs, startTs: interval.startTs, value: interval[field], unit: seriesUnit });
        coverageSec += interval.endTs - interval.startTs;
      } else {
        if (segment.length) chartSegments.push(segment);
        segment = [];
        addGap(gaps, interval.startTs, interval.endTs, interval.reason || 'missing');
      }
    });
    if (segment.length) chartSegments.push(segment);
    const count = sorted.filter((point) => point.valid !== false && (point.chargeUah !== null || point.currentUa !== null)).length;
    const consumedMah = activeSec && !resetDetected ? consumedUah / 1000 : null;
    return { ...window, points: sorted, series, chartSegments, gapRanges: gaps, gaps: gaps.map((gap) => [{ ts: gap.startTs }, { ts: gap.endTs }]), seriesUnit, count, validCount: count, missingCount: Math.max(0, sorted.length - count), sampleCount: sorted.length, coverageSec, nonDischargeSec, unknownSec: Math.max(0, window.elapsedSec - coverageSec - nonDischargeSec), consumedMah, avgMahPerHour: activeSec && !resetDetected ? consumedMah * 3600 / activeSec : null, avgMw: measuredSec ? measuredMw / measuredSec : null, activeSec: resetDetected ? 0 : activeSec, measuredSec, coveragePct: window.elapsedSec ? Math.min(100, coverageSec * 100 / window.elapsedSec) : 0, quality: resetDetected ? 'reset_or_mismatch' : count ? (gaps.length ? 'partial' : 'good') : 'no_data', native: false };
  }
  registerFeature('analyticsModel', { ranges: () => RANGES.map((item) => ({ ...item })), rangeFor, normalizeThermal, normalizePower, explicitGaps, temperatureStats, powerStats, clip, formatDuration(sec) { const value = number(sec); if (value === null || value < 0) return '—'; if (value >= 3600) return `${Math.floor(value / 3600)}小时${Math.floor(value % 3600 / 60)}分`; if (value >= 60) return `${Math.floor(value / 60)}分${Math.floor(value % 60)}秒`; return `${Math.floor(value)}秒`; } });
})();
