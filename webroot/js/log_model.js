'use strict';
(() => {
  const SCHEMA = 'pixel9pro.logs.v1';
  const TEXT_HEADER = '# pixel9pro.logs.v1';
  const LIMITS = Object.freeze({ maxBytes: 8 * 1024 * 1024, maxLines: 50000, maxEntries: 50000 });
  const LEVELS = ['error', 'warning', 'success', 'info'];
  const RESULT_LEVELS = new Map([
    ['success', 'success'], ['ok', 'success'], ['failure', 'error'], ['failed', 'error'],
    ['error', 'error'], ['partial', 'warning'], ['warning', 'warning'], ['skipped', 'info'],
    ['skip', 'info'], ['pending', 'info'], ['started', 'info'], ['accepted', 'info']
  ]);

  function inputError(message) {
    return new Error(`日志格式错误：${message}`);
  }

  function timestamp(value) {
    return value === null || (Number.isSafeInteger(value) && value >= 0 && !Number.isNaN(new Date(value).getTime()));
  }

  function integer(value, maximum = Number.MAX_SAFE_INTEGER) {
    return Number.isSafeInteger(value) && value >= 0 && value <= maximum;
  }

  function invalidAudit(raw, code, message, unsupported) {
    return {
      ts: null, level: unsupported ? 'warning' : 'error', source: 'module', phase: 'parse',
      operation: 'audit.parse', result: unsupported ? 'unsupported' : 'invalid', code, message,
      detail: raw, durationMs: null, count: 1
    };
  }

  function parseAudit(lines) {
    if (!Array.isArray(lines) || lines.length > LIMITS.maxLines) throw inputError('模块日志必须是至多 50000 行的数组');
    let invalidCount = 0;
    let unsupportedCount = 0;
    const entries = lines.map((raw, index) => {
      if (typeof raw !== 'string' || raw.length > 65536) throw inputError(`第 ${index + 1} 行不是有效文本或超过 65536 字符`);
      const fields = new Map();
      let malformed = raw.trim() === '';
      raw.trim().split(/\s+/).forEach((token) => {
        const match = /^([a-z][a-z0-9_]*)=(\S+)$/.exec(token);
        if (!match || fields.has(match[1])) malformed = true;
        else fields.set(match[1], match[2]);
      });
      const schema = fields.get('schema');
      if (schema && !/^\d{1,9}$/.test(schema)) malformed = true;
      if (!malformed && schema && schema !== '2') {
        unsupportedCount += 1;
        return invalidAudit(raw, 'AUDIT_SCHEMA_UNSUPPORTED', `不支持的模块日志 schema=${schema}`, true);
      }
      const required = ['ts', 'phase', 'operation', 'result', 'reason_code', 'duration_ms'];
      if (schema !== '2' || required.some((key) => !fields.has(key))) malformed = true;
      if (['phase', 'operation', 'result', 'reason_code'].some((key) => (fields.get(key) || '').length > 256)) malformed = true;
      const seconds = fields.get('ts');
      const duration = fields.get('duration_ms');
      if (!/^\d+$/.test(seconds || '') || !timestamp(Number(seconds) * 1000)
        || !/^\d+$/.test(duration || '') || !integer(Number(duration))) malformed = true;
      if (malformed) {
        invalidCount += 1;
        return invalidAudit(raw, 'AUDIT_LINE_INVALID', `第 ${index + 1} 行不完整或字段无效`, false);
      }
      const result = fields.get('result');
      const operation = fields.get('operation');
      const code = fields.get('reason_code');
      return {
        ts: Number(seconds) * 1000, level: RESULT_LEVELS.get(result) || 'warning', source: 'module',
        phase: fields.get('phase'), operation, result, code,
        message: `${operation} · ${result} · ${code}`, detail: raw,
        durationMs: Number(duration), count: 1
      };
    });
    return { entries, invalidCount, unsupportedCount };
  }

  function stats(entries) {
    const levels = { error: 0, warning: 0, success: 0, info: 0 };
    const operations = new Map();
    const errors = new Map();
    let eventCount = 0;
    let start = null;
    let end = null;
    let sampleCount = 0;
    let totalMs = 0;
    let maxMs = null;
    entries.forEach((entry) => {
      eventCount += entry.count;
      levels[entry.level] += entry.count;
      const operation = operations.get(entry.operation) || { operation: entry.operation, count: 0, errorCount: 0 };
      operation.count += entry.count;
      if (entry.level === 'error') {
        operation.errorCount += entry.count;
        errors.set(entry.code, (errors.get(entry.code) || 0) + entry.count);
      }
      operations.set(entry.operation, operation);
      const first = entry.firstTs ?? entry.ts;
      const last = entry.lastTs ?? entry.ts;
      if (first !== null) start = start === null ? first : Math.min(start, first);
      if (last !== null) end = end === null ? last : Math.max(end, last);
      if (entry.durationMs !== null) {
        // A coalesced entry keeps one observed duration, not every occurrence's duration.
        sampleCount += 1;
        totalMs += entry.durationMs;
        maxMs = maxMs === null ? entry.durationMs : Math.max(maxMs, entry.durationMs);
      }
    });
    const byCount = (a, b) => b.count - a.count;
    return {
      recordCount: entries.length, eventCount, levels,
      operations: Array.from(operations.values()).sort(byCount),
      errors: Array.from(errors, ([code, count]) => ({ code, count })).sort(byCount),
      timeRange: { start, end },
      duration: { sampleCount, totalMs, averageMs: sampleCount ? totalMs / sampleCount : null, maxMs,
        unmeasuredEventCount: eventCount - sampleCount }
    };
  }

  // JSON and TXT enter here once. Internal stats/export consume the normalized contract.
  function validateEntry(value, index) {
    const prefix = `第 ${index + 1} 条记录`;
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw inputError(`${prefix}不是对象`);
    if (!timestamp(value.ts) || !LEVELS.includes(value.level) || !['page', 'module'].includes(value.source)
      || !integer(value.count, 1000000) || value.count < 1
      || !(value.durationMs === null || integer(value.durationMs))) {
      throw inputError(`${prefix}的时间、级别、来源、次数或耗时无效`);
    }
    const entry = { ts: value.ts, level: value.level, source: value.source };
    const stringLimits = { phase: 256, operation: 256, result: 256, code: 256, message: 4096, detail: 65536 };
    Object.entries(stringLimits).forEach(([key, maximum]) => {
      if (typeof value[key] !== 'string' || value[key].length > maximum) throw inputError(`${prefix}的 ${key} 必须是至多 ${maximum} 字符的文本`);
      entry[key] = value[key];
    });
    entry.durationMs = value.durationMs;
    entry.count = value.count;
    ['firstTs', 'lastTs'].forEach((key) => {
      if (Object.hasOwn(value, key)) {
        if (!timestamp(value[key])) throw inputError(`${prefix}的 ${key} 无效`);
        entry[key] = value[key];
      }
    });
    const first = entry.firstTs ?? entry.ts;
    const last = entry.lastTs ?? entry.ts;
    if (first !== null && last !== null && first > last) throw inputError(`${prefix}的时间范围倒置`);
    return entry;
  }

  function validateSnapshot(value) {
    if (!value || typeof value !== 'object' || Array.isArray(value) || value.schema !== SCHEMA) throw inputError(`只支持 ${SCHEMA}`);
    if (!Array.isArray(value.entries) || value.entries.length > LIMITS.maxEntries) throw inputError('记录数超过 50000 或 entries 不是数组');
    if (!timestamp(value.exportedAt) || !['module', 'page', 'import'].includes(value.source)
      || typeof value.truncated !== 'boolean' || !integer(value.invalidCount) || !integer(value.unsupportedCount)) {
      throw inputError('快照来源、导出时间、截断或解析统计无效');
    }
    if (!value.range || !timestamp(value.range.start) || !timestamp(value.range.end)
      || (value.range.start !== null && value.range.end !== null && value.range.start > value.range.end)) {
      throw inputError('快照时间范围无效');
    }
    if (value.originalSource !== undefined && !['module', 'page', 'import'].includes(value.originalSource)) throw inputError('原快照来源无效');
    if (value.importedAt !== undefined && (!timestamp(value.importedAt) || value.importedAt === null)) throw inputError('导入时间无效');
    const entries = value.entries.map(validateEntry);
    const invalidCount = entries.filter((entry) => entry.operation === 'audit.parse' && entry.code === 'AUDIT_LINE_INVALID').length;
    const unsupportedCount = entries.filter((entry) => entry.operation === 'audit.parse' && entry.code === 'AUDIT_SCHEMA_UNSUPPORTED').length;
    if (value.invalidCount !== invalidCount || value.unsupportedCount !== unsupportedCount) throw inputError('解析统计与记录内容不一致');
    const observed = stats(entries).timeRange;
    if ((observed.start !== null && (value.range.start === null || value.range.start > observed.start))
      || (observed.end !== null && (value.range.end === null || value.range.end < observed.end))) throw inputError('快照时间范围未包含记录时间');
    return {
      schema: SCHEMA, exportedAt: value.exportedAt, source: 'import', originalSource: value.originalSource || value.source,
      importedAt: Date.now(), completeness: 'unverified',
      range: { start: value.range.start, end: value.range.end }, truncated: value.truncated,
      invalidCount, unsupportedCount, entries
    };
  }

  function parseJson(text) {
    try { return JSON.parse(text); }
    catch (_) { throw inputError('JSON 不完整或语法无效'); }
  }

  function parseImport(text, fileName = '') {
    if (typeof text !== 'string') throw inputError('文件内容不是文本');
    if (new TextEncoder().encode(text).byteLength > LIMITS.maxBytes) throw inputError('文件超过 8 MiB');
    const content = text.replace(/^\uFEFF/, '');
    // JSON whitespace is not a record boundary; validate entries after parsing.
    if (/\.json$/i.test(fileName) || /^\s*[\[{]/.test(content)) return validateSnapshot(parseJson(content));
    const lines = content.split(/\r?\n/);
    if (lines[lines.length - 1] === '') lines.pop();
    if (lines[0] === TEXT_HEADER) {
      if (lines.length - 2 > LIMITS.maxEntries) throw inputError('记录数超过 50000');
      const metadata = parseJson(lines[1] || '');
      return validateSnapshot({ ...metadata, entries: lines.slice(2).map(parseJson) });
    }
    if (lines.length > LIMITS.maxLines) throw inputError('文件超过 50000 行');
    const parsed = parseAudit(lines);
    return {
      schema: SCHEMA, exportedAt: null, importedAt: Date.now(), source: 'import', originalSource: 'module',
      completeness: 'unverified',
      range: stats(parsed.entries).timeRange, truncated: false,
      invalidCount: parsed.invalidCount, unsupportedCount: parsed.unsupportedCount, entries: parsed.entries
    };
  }

  function exportJson(snapshot) {
    return JSON.stringify(snapshot, null, 2) + '\n';
  }

  function exportText(snapshot) {
    const { entries, ...metadata } = snapshot;
    // Each entry keeps the original audit line in detail, including unknown/invalid lines.
    return [TEXT_HEADER, JSON.stringify(metadata), ...entries.map((entry) => JSON.stringify(entry))].join('\n') + '\n';
  }

  registerFeature('logModel', { schema: SCHEMA, limits: LIMITS, parseAudit, stats, parseImport, exportJson, exportText });
})();
