'use strict';
(() => {
  // Pure transforms for the shared history sheet. No DOM or request state lives here.
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

  // CGI deliberately emits null for unavailable sensors. Number(null), an
  // empty string or a boolean must never turn missing evidence into a zero.
  const finite = (value) => {
    if (typeof value !== 'number' && typeof value !== 'string') return null;
    if (typeof value === 'string' && !value.trim()) return null;
    return Number.isFinite(Number(value)) ? Number(value) : null;
  };
  const sortPoints = (points) => {
    const byTime = new Map();
    (Array.isArray(points) ? points : []).forEach((point) => {
      if (!point || typeof point !== 'object') return;
      const ts = finite(point.ts);
      if (ts === null || ts <= 0) return;
      // A timestamp alone is not a sample identity: the same second can occur
      // in two sessions after a reboot or service restart. Keep those records
      // separate so a cross-session window cannot silently lose evidence.
      const identity = [point.bootId || point.boot_id || '', point.sessionId || point.session_id || '', ts].join('|');
      byTime.set(identity, { ...point, ts });
    });
    return Array.from(byTime.values()).sort((a, b) => a.ts - b.ts);
  };
  const validTemperature = (value) => {
    const number = finite(value);
    return number !== null && number > -20 && number < 120 ? number : null;
  };
  const nonnegative = (value) => {
    const number = finite(value);
    return number !== null && number >= 0 ? number : null;
  };
  const sameSession = (left, right) => {
    const leftId = [left?.bootId, left?.sessionId].filter(Boolean).join('|');
    const rightId = [right?.bootId, right?.sessionId].filter(Boolean).join('|');
    return !leftId || !rightId || leftId === rightId;
  };

  function rangeFor(id) {
    return RANGES.find((range) => range.id === String(id)) || RANGES[1];
  }

  function normalizeThermal(payload) {
    const envelope = payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : {};
    const source = Array.isArray(payload) ? payload : (payload?.points || payload?.thermal);
    const defaultBootId = envelope.boot_id || envelope.bootId || '';
    const defaultSessionId = envelope.session_id || envelope.sessionId || '';
    const defaultSource = envelope.source || 'thermal';
    const mapped = (Array.isArray(source) ? source : []).map((point) => {
      if (Array.isArray(point)) {
        const raw = finite(point[1]);
        return { ts: point[0], tempC: raw === null ? null : validTemperature(raw / 1000), bootId: defaultBootId, sessionId: defaultSessionId, source: defaultSource, valid: raw !== null };
      }
      if (!point || typeof point !== 'object') return null;
      const hasMc = 'virtual_skin_mc' in point || 'temp_mc' in point;
      const raw = finite('virtual_skin_mc' in point ? point.virtual_skin_mc : 'temp_mc' in point ? point.temp_mc : point.temp ?? point.value);
      const value = raw === null ? null : (hasMc || raw > 200 ? raw / 1000 : raw);
      const fieldValid = point.thermal_valid === false || point.thermal_valid === 0 ? false : point.thermal_valid === true || point.thermal_valid === 1 ? true : null;
      const valid = fieldValid === false || point.valid === false || point.valid === 0 ? false : fieldValid === true ? validTemperature(value) !== null : validTemperature(value) !== null;
      return { ts: point.ts, tempC: valid ? validTemperature(value) : null, screen: point.screen || 'unknown', bootId: point.boot_id || point.bootId || defaultBootId, sessionId: point.session_id || point.sessionId || defaultSessionId, source: point.source || defaultSource, valid, quality: String(point.quality || point.sample_quality || '') };
    });
    // Keep timestamped missing readings: filtering them out joins the valid
    // points on either side and overstates threshold duration and coverage.
    return sortPoints(mapped);
  }

  function normalizePower(payload) {
    const envelope = payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : {};
    const source = Array.isArray(payload) ? payload : payload?.power;
    const defaultBootId = envelope.boot_id || envelope.bootId || '';
    const defaultSessionId = envelope.session_id || envelope.sessionId || '';
    const defaultSource = envelope.source || 'power';
    const mapped = (Array.isArray(source) ? source : []).map((point) => {
      if (Array.isArray(point)) return { ts: point[0], screen: 'unknown', levelPct: finite(point[1]), chargeUah: nonnegative(point[2]), currentUa: null, voltageUv: null, status: String(point[3] || ''), bootId: defaultBootId, sessionId: defaultSessionId, source: defaultSource, valid: finite(point[2]) !== null };
      if (!point || typeof point !== 'object') return null;
      const voltage = finite(point.voltage_uv);
      const chargeUah = nonnegative('charge_uah' in point ? point.charge_uah : point.charge);
      const currentUa = finite(point.current_ua);
      const fieldValid = point.power_valid === false || point.power_valid === 0 ? false : point.power_valid === true || point.power_valid === 1 ? true : null;
      const valid = fieldValid === false || point.valid === false || point.valid === 0 ? false : fieldValid === true ? (chargeUah !== null || (currentUa !== null && voltage !== null && voltage > 0)) : (chargeUah !== null || (currentUa !== null && voltage !== null && voltage > 0));
      return {
        ts: point.ts,
        screen: point.screen || 'unknown',
        levelPct: finite(point.level_pct ?? point.level),
        chargeUah,
        currentUa,
        voltageUv: voltage !== null && voltage > 0 ? voltage : null,
        status: String(point.status || point.charge_status || ''),
        quality: String(point.quality || point.sample_quality || ''),
        bootId: point.boot_id || point.bootId || defaultBootId,
        sessionId: point.session_id || point.sessionId || defaultSessionId,
        source: point.source || defaultSource,
        valid
      };
    });
    return sortPoints(mapped);
  }

  function cadence(points, source) {
    const deltas = [];
    for (let i = 1; i < points.length; i += 1) {
      const delta = points[i].ts - points[i - 1].ts;
      if (delta > 0) deltas.push(delta);
    }
    deltas.sort((a, b) => a - b);
    // Cap an inferred cadence by the producer contract, so a two-point long
    // pause cannot define itself as normal. Legacy power can sample every 600s.
    const maximum = source === 'power' ? 600 : 60;
    return Math.min(maximum, deltas.length ? deltas[Math.floor((deltas.length - 1) / 2)] : maximum);
  }

  function gapThreshold(previous, source, typical, options) {
    // telemetry_worker.sh sleeps 60s on-screen and 600s off-screen. History CGI
    // returns one actual reading per requested bucket, not a bucket average.
    const bucket = options.granularity === 'hour' ? 3600 : options.granularity === 'minute' ? 60 : 0;
    const interval = previous?.screen === 'on' ? 60 : previous?.screen === 'off' ? 600 : typical;
    // One missing bucket must become an explicit gap. A four-bucket tolerance
    // hid hours of absent data behind a seemingly continuous trace.
    return Math.max(source === 'power' ? 180 : 90, Math.max(bucket, interval) * 2);
  }

  function windowFor(points, options) {
    const startTs = finite(options.startTs) ?? points[0]?.ts ?? null;
    const endTs = finite(options.endTs) ?? points[points.length - 1]?.ts ?? null;
    return { startTs, endTs, elapsedSec: startTs !== null && endTs !== null ? Math.max(0, endTs - startTs) : 0 };
  }

  function addGap(gaps, startTs, endTs, reason) {
    if (endTs <= startTs) return;
    const last = gaps[gaps.length - 1];
    if (last && last.endTs === startTs && last.reason === reason) last.endTs = endTs;
    else gaps.push({ startTs, endTs, reason });
  }

  function boundaryGaps(points, window, gaps) {
    if (window.startTs === null || window.endTs === null) return;
    if (!points.length) addGap(gaps, window.startTs, window.endTs, 'missing');
    else {
      if (window.startTs < points[0].ts) gaps.unshift({ startTs: window.startTs, endTs: points[0].ts, reason: 'missing' });
      addGap(gaps, points[points.length - 1].ts, window.endTs, 'missing');
    }
  }

  function temperatureStats(points, options = {}) {
    const sorted = sortPoints(clip(points, options.startTs, options.endTs)).map((point) => ({ ...point, tempC: validTemperature(point.tempC) }));
    const window = windowFor(sorted, options);
    const typical = cadence(sorted, 'thermal');
    const valid = sorted.filter((point) => point.tempC !== null);
    const values = valid.map((point) => point.tempC);
    const runs = [];
    const gapRanges = [];
    let run = [];
    let coverageSec = 0;
    let thresholdSec = 0;
    const thresholdValue = finite(globalThis.THRESH_STOCK) ?? 37;
    sorted.forEach((point, index) => {
      const previous = sorted[index - 1];
      if (previous) {
        const delta = point.ts - previous.ts;
        const continuous = sameSession(previous, point) && delta <= gapThreshold(previous, 'thermal', typical, options) && previous.tempC !== null && point.tempC !== null;
        if (continuous) {
          coverageSec += delta;
          if (previous.tempC >= thresholdValue) thresholdSec += delta;
        } else {
          addGap(gapRanges, previous.ts, point.ts, sameSession(previous, point) ? 'missing' : 'session_changed');
          if (run.length) runs.push(run);
          run = [];
        }
      }
      if (point.tempC !== null) run.push(point);
    });
    if (run.length) runs.push(run);
    boundaryGaps(sorted, window, gapRanges);
    const validCount = valid.length;
    const missingCount = Math.max(0, sorted.length - validCount);
    return {
      ...window, points: sorted, runs, gapRanges,
      gaps: gapRanges.map((gap) => [{ ts: gap.startTs }, { ts: gap.endTs }]),
      chartSegments: runs.map((segment) => segment.map((point) => ({ ts: point.ts, value: point.tempC }))),
      seriesUnit: '°C', count: validCount, validCount, missingCount, sampleCount: sorted.length,
      gapThresholdSec: gapThreshold(null, 'thermal', typical, options),
      coverageSec, unknownSec: Math.max(0, window.elapsedSec - coverageSec),
      lastSampleTs: valid[valid.length - 1]?.ts ?? null,
      current: values.length ? values[values.length - 1] : null,
      min: values.length ? Math.min(...values) : null,
      max: values.length ? Math.max(...values) : null,
      avg: values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : null,
      thresholdSec,
      coveragePct: window.elapsedSec > 0 ? Math.min(100, (coverageSec / window.elapsedSec) * 100) : 0,
      quality: !values.length ? 'no_data' : coverageSec > 0 ? (gapRanges.length ? 'partial' : 'good') : 'insufficient'
    };
  }

  function powerStats(points, options = {}) {
    const sorted = sortPoints(clip(points, options.startTs, options.endTs));
    const window = windowFor(sorted, options);
    const typical = cadence(sorted, 'power');
    const intervals = [];
    let consumedUah = 0;
    let activeSec = 0;
    let measuredMw = 0;
    let measuredSec = 0;
    let nonDischargeSec = 0;
    let resetDetected = /reset|mismatch/i.test(String(options.quality || '')) || sorted.some((point) => /reset|mismatch/i.test(String(point.quality || '')));
    const hasCounter = (point) => point.valid !== false && Number.isFinite(point.chargeUah) && point.chargeUah >= 0;
    const hasCurrent = (point) => point.valid !== false && Number.isFinite(point.currentUa) && Number.isFinite(point.voltageUv) && point.voltageUv > 0;
    for (let i = 1; i < sorted.length; i += 1) {
      const previous = sorted[i - 1];
      const point = sorted[i];
      const deltaSec = point.ts - previous.ts;
      const interval = { startTs: previous.ts, endTs: point.ts, counterRate: null, mw: null, reason: '' };
      intervals.push(interval);
      if (!sameSession(previous, point)) { interval.reason = 'session_changed'; continue; }
      if (deltaSec > gapThreshold(previous, 'power', typical, options)) { interval.reason = 'missing'; continue; }
      const beforeStatus = String(previous.status || '').trim().toLowerCase();
      const afterStatus = String(point.status || '').trim().toLowerCase();
      if (beforeStatus !== afterStatus) { interval.reason = 'state_change'; continue; }
      if (beforeStatus !== 'discharging') {
        interval.reason = ['charging', 'full', 'not charging'].includes(beforeStatus) ? 'not_discharging' : 'unknown_state';
        if (interval.reason === 'not_discharging') nonDischargeSec += deltaSec;
        continue;
      }
      if (hasCounter(previous) && hasCounter(point)) {
        const deltaUah = previous.chargeUah - point.chargeUah;
        // A counter increase while both samples say Discharging is not negative
        // consumption; reset/mismatch evidence invalidates the counter summary.
        if (deltaUah < 0) resetDetected = true;
        else if (!/reset|mismatch/i.test(String(point.quality || ''))) {
          interval.counterRate = (deltaUah / 1000) * 3600 / deltaSec;
          consumedUah += deltaUah;
          activeSec += deltaSec;
        }
      }
      if (hasCurrent(previous) && hasCurrent(point)) {
        const mw = Math.abs(previous.currentUa * previous.voltageUv) / 1e9;
        if (Number.isFinite(mw) && mw >= 0) {
          interval.mw = mw;
          measuredMw += mw * deltaSec;
          measuredSec += deltaSec;
        }
      }
    }
    const avgMahPerHour = !resetDetected && activeSec > 0 ? (consumedUah / 1000) * 3600 / activeSec : null;
    const avgMw = measuredSec > 0 ? measuredMw / measuredSec : null;
    // A chart has one physical unit. Counter and current evidence can coexist in
    // the summary, but mAh/h and mW must never alternate on one unlabeled axis.
    const seriesUnit = avgMahPerHour !== null ? 'mAh/h' : 'mW';
    const field = seriesUnit === 'mAh/h' ? 'counterRate' : 'mw';
    const series = [];
    const chartSegments = [];
    const gapRanges = [];
    let segment = [];
    let coverageSec = 0;
    intervals.forEach((interval) => {
      const value = interval[field];
      if (Number.isFinite(value)) {
        // Counter differences describe their full measured interval. A step
        // trace avoids pretending they are instantaneous endpoint readings.
        segment.push({ ts: interval.startTs, value }, { ts: interval.endTs, value });
        series.push({ ts: interval.endTs, startTs: interval.startTs, value, unit: seriesUnit });
        coverageSec += interval.endTs - interval.startTs;
      } else {
        if (segment.length) chartSegments.push(segment);
        segment = [];
        addGap(gapRanges, interval.startTs, interval.endTs, interval.reason || 'missing_measurement');
      }
    });
    if (segment.length) chartSegments.push(segment);
    boundaryGaps(sorted, window, gapRanges);
    const count = sorted.filter((point) => point.valid !== false && (hasCounter(point) || hasCurrent(point))).length;
    const validCount = count;
    const missingCount = Math.max(0, sorted.length - validCount);
    return {
      ...window, points: sorted, series, seriesUnit, chartSegments, gapRanges,
      gaps: gapRanges.map((gap) => [{ ts: gap.startTs }, { ts: gap.endTs }]),
      gapThresholdSec: gapThreshold(null, 'power', typical, options),
      count, validCount, missingCount, sampleCount: sorted.length, coverageSec, nonDischargeSec,
      unknownSec: Math.max(0, window.elapsedSec - coverageSec - nonDischargeSec),
      consumedMah: !resetDetected && activeSec > 0 ? consumedUah / 1000 : null,
      avgMahPerHour, avgMw, activeSec: resetDetected ? 0 : activeSec, measuredSec,
      coveragePct: window.elapsedSec > 0 ? Math.min(100, (coverageSec / window.elapsedSec) * 100) : 0,
      quality: resetDetected ? 'reset_or_mismatch' : !count ? 'no_data' : coverageSec > 0 ? (gapRanges.length ? 'partial' : 'good') : 'insufficient'
    };
  }

  function clip(points, startTs, endTs) {
    const start = finite(startTs);
    const end = finite(endTs);
    return (Array.isArray(points) ? points : []).filter((point) => {
      const ts = finite(point?.ts);
      return ts !== null && ts > 0 && (start === null || ts >= start) && (end === null || ts <= end);
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
      const value = finite(sec);
      if (value === null || value < 0) return '—';
      if (value >= 3600) return `${Math.floor(value / 3600)}小时${Math.floor((value % 3600) / 60)}分`;
      if (value >= 60) return `${Math.floor(value / 60)}分${Math.floor(value % 60)}秒`;
      return `${Math.floor(value)}秒`;
    }
  });
})();
