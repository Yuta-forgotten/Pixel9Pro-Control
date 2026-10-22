'use strict';
(() => {
  const RANGES = Object.freeze([
    { id: '30', minutes: 30, label: '30 分钟', shortLabel: '30 分' },
    { id: '120', minutes: 120, label: '2 小时', shortLabel: '2 小时' },
    { id: '480', minutes: 480, label: '8 小时', shortLabel: '8 小时' },
    { id: '1440', minutes: 1440, label: '1 天', shortLabel: '1 天' },
    { id: '4320', minutes: 4320, label: '3 天', shortLabel: '3 天' },
    { id: '10080', minutes: 10080, label: '7 天', shortLabel: '7 天' },
    { id: 'custom', minutes: 0, label: '自定义', shortLabel: '自定义' }
  ]);

  const number = (value) => {
    if (value === null || value === undefined || value === '') return null;
    const result = Number(value);
    return Number.isFinite(result) ? result : null;
  };

  function rangeFor(id) {
    return RANGES.find((item) => item.id === String(id)) || RANGES[0];
  }

  function normalizeThermal(payload) {
    const data = payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : {};
    const values = Array.isArray(payload) ? payload : (data.points || data.thermal || []);
    return values.map((item) => {
      if (Array.isArray(item)) {
        const ts = number(item[0]);
        const tempC = number(item[1]);
        if (ts === null || ts <= 0 || tempC === null) return null;
        return { ts, tempC: Math.abs(tempC) > 180 ? tempC / 1000 : tempC, sensor: 'module', expectedIntervalSec: 60 };
      }
      if (!item || typeof item !== 'object' || item.valid === false) return null;
      const ts = number(item.ts);
      const raw = number(item.temp_mc ?? item.temp_c ?? item.temp);
      const tempC = raw === null ? null : (item.temp_mc !== undefined || Math.abs(raw) > 180 ? raw / 1000 : raw);
      if (ts === null || ts <= 0 || tempC === null || tempC < -20 || tempC > 120) return null;
      const expected = number(item.expected_interval_sec);
      return {
        ts,
        tempC,
        sensor: item.sensor === 'battery' ? 'battery' : 'module',
        source: String(item.source || 'module'),
        screen: String(item.screen || 'unknown'),
        bootId: String(item.boot_id || ''),
        expectedIntervalSec: expected !== null && expected > 0 ? expected : (item.screen === 'on' ? 60 : 900),
        quality: String(item.quality || '')
      };
    }).filter(Boolean).sort((left, right) => left.ts - right.ts);
  }

  function clip(points, startTs, endTs) {
    const start = number(startTs);
    const end = number(endTs);
    return (Array.isArray(points) ? points : []).filter((point) => {
      const ts = number(point?.ts);
      return ts !== null && (start === null || ts >= start) && (end === null || ts <= end);
    });
  }

  function temperatureStats(points, options = {}) {
    const sorted = (Array.isArray(points) ? points : []).filter((point) => Number.isFinite(point?.tempC) && Number.isFinite(point?.ts)).slice().sort((a, b) => a.ts - b.ts);
    const startTs = number(options.startTs) ?? sorted[0]?.ts ?? null;
    const endTs = number(options.endTs) ?? sorted[sorted.length - 1]?.ts ?? null;
    const windowSec = startTs !== null && endTs !== null ? Math.max(0, endTs - startTs) : 0;
    const chartSegments = [];
    const gapRanges = [];
    let coverageSec = 0;
    let thresholdSec = 0;
    let previous = null;

    sorted.forEach((point) => {
      const chartPoint = { ts: point.ts, value: point.tempC };
      const expected = Math.max(60, number(point.expectedIntervalSec) || 60);
      if (!previous) {
        chartSegments.push([chartPoint]);
      } else {
        const delta = point.ts - previous.ts;
        const allowance = Math.max(expected, number(previous.expectedIntervalSec) || 60) * 2;
        if (delta > allowance || point.bootId !== previous.bootId) {
          gapRanges.push({ startTs: previous.ts + (number(previous.expectedIntervalSec) || 60), endTs: point.ts, reason: 'sample_gap' });
          chartSegments.push([chartPoint]);
        } else {
          chartSegments[chartSegments.length - 1].push(chartPoint);
          coverageSec += delta;
          if (previous.tempC >= 40 && point.tempC >= 40) thresholdSec += delta;
        }
      }
      previous = point;
    });

    coverageSec = Math.min(windowSec, coverageSec);
    const values = sorted.map((point) => point.tempC);
    const count = values.length;
    const sum = values.reduce((total, value) => total + value, 0);
    const gaps = Math.max(gapRanges.length, number(options.backendGapCount) || 0);
    return {
      startTs,
      endTs,
      current: count ? values[count - 1] : null,
      lastSampleTs: count ? sorted[count - 1].ts : null,
      min: count ? Math.min(...values) : null,
      max: count ? Math.max(...values) : null,
      avg: count ? sum / count : null,
      count,
      sampleCount: number(options.backendSampleCount) ?? count,
      validCount: number(options.backendValidSamples) ?? count,
      coverageSec,
      unknownSec: Math.max(0, windowSec - coverageSec),
      coveragePct: windowSec > 0 ? coverageSec / windowSec * 100 : 0,
      thresholdSec,
      gapRanges,
      gaps: gapRanges,
      gapCount: gaps,
      chartSegments,
      quality: gaps ? 'partial' : count ? 'available' : 'no_data',
      backendQuality: String(options.backendQuality || '')
    };
  }

  function formatDuration(seconds) {
    const value = number(seconds);
    if (value === null || value < 0) return '—';
    if (value >= 3600) return `${Math.floor(value / 3600)}小时${Math.floor(value % 3600 / 60)}分`;
    if (value >= 60) return `${Math.floor(value / 60)}分${Math.floor(value % 60)}秒`;
    return `${Math.floor(value)}秒`;
  }

  function exportHistory(payload, format) {
    if (!payload || payload.ok !== true || !Array.isArray(payload.points)) throw new Error('尚无可导出的历史响应');
    if (!['json', 'csv'].includes(format)) throw new Error('不支持的导出格式');
    const points = normalizeThermal(payload).filter((point) => point.sensor === payload.sensor);
    const stats = temperatureStats(points, {
      startTs: payload.start_ts, endTs: payload.end_ts, backendGapCount: payload.gap_count
    });
    const iso = (ts) => new Date(ts * 1000).toISOString();
    const metadata = {
      schema: 'pixel9pro.temperature_history.v1',
      exported_at_utc: new Date().toISOString(),
      sensor: payload.sensor,
      start_ts: payload.start_ts,
      end_ts: payload.end_ts,
      recording_enabled: payload.recording_enabled,
      recording_state: payload.recording_state,
      data_revision: payload.data_revision,
      units: { ts: 'unix_seconds', timestamp_utc: 'ISO-8601 UTC', temperature_c: 'celsius', gap_before_sec: 'seconds' },
      sampling: { screen_on_sec: 60, screen_off_sec: 900, suspend_may_delay: true },
      interpretation: 'Irregular point samples, not continuous monitoring. Gaps are unknown, not zero; average is a sample mean.',
      summary: { valid_samples: points.length, sample_mean_c: stats.avg, min_c: stats.min, max_c: stats.max, coverage_sec: stats.coverageSec, gap_count: stats.gapCount }
    };
    const rows = points.map((point, index) => {
      const previous = points[index - 1];
      const delta = previous ? point.ts - previous.ts : 0;
      const gap = previous && (delta > Math.max(previous.expectedIntervalSec, point.expectedIntervalSec) * 2 || previous.bootId !== point.bootId);
      return {
        ts: point.ts, timestamp_utc: iso(point.ts), temperature_c: point.tempC,
        sensor: point.sensor, source: point.source, screen: point.screen,
        expected_interval_sec: point.expectedIntervalSec,
        gap_before_sec: gap ? delta : 0, boot_id: point.bootId,
        quality: point.quality, valid: true
      };
    });
    const filename = `pixel9pro-temperature-${payload.sensor}-${payload.start_ts}-${payload.end_ts}.${format}`;
    if (format === 'json') {
      return { filename, mime: 'application/json;charset=utf-8', text: `${JSON.stringify({ ...metadata, points: rows }, null, 2)}\n` };
    }
    const columns = ['ts', 'timestamp_utc', 'temperature_c', 'sensor', 'source', 'screen', 'expected_interval_sec', 'gap_before_sec', 'boot_id', 'quality', 'valid', 'window_start_ts', 'window_end_ts', 'recording_enabled', 'recording_state'];
    const csv = (value) => {
      let text = value === undefined || value === null ? '' : String(value);
      if (typeof value === 'string' && /^[=+\-@\t\r]/.test(text)) text = `'${text}`;
      return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
    };
    const lines = rows.map((row) => columns.map((key) => csv(({
      window_start_ts: payload.start_ts, window_end_ts: payload.end_ts,
      recording_enabled: payload.recording_enabled, recording_state: payload.recording_state, ...row
    })[key])).join(','));
    return { filename, mime: 'text/csv;charset=utf-8', text: `${columns.join(',')}\r\n${lines.join('\r\n')}${lines.length ? '\r\n' : ''}` };
  }

  registerFeature('analyticsModel', {
    ranges: () => RANGES.map((item) => ({ ...item })),
    rangeFor,
    normalizeThermal,
    temperatureStats,
    clip,
    formatDuration,
    exportHistory
  });
})();
