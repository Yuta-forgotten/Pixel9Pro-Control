'use strict';
const { test, expect } = require('@playwright/test');
const fs = require('node:fs/promises');

const pageErrors = new WeakMap();
test.beforeEach(async ({ page }) => {
  const errors = [];
  pageErrors.set(page, errors);
  page.on('pageerror', (error) => errors.push(error.message));
});
test.afterEach(async ({ page }) => { expect(pageErrors.get(page)).toEqual([]); });

function gate() {
  let release;
  return { promise: new Promise((resolve) => { release = resolve; }), release: () => release() };
}

async function openPage(page) {
  await page.goto('/');
  await expect(page.locator('#topbar-kicker')).toContainText('Pixel 9 Pro');
}

const dnsCases = [
  { name: 'success', status: 200, payload: { ok: true, completed: true, action: 'clear', scope: 'system', total_networks: 2, cleared_networks: 2 }, text: '系统 DNS 缓存已清理' },
  { name: 'partial', status: 500, payload: { ok: false, completed: false, action: 'clear', scope: 'system', result_unconfirmed: false, total_networks: 2, cleared_networks: 1, error: 'fixture network disappeared' }, text: '部分 DNS 缓存已清理：操作失败，详细原因见运行记录' },
  { name: 'unconfirmed', status: 500, payload: { ok: false, completed: false, action: 'clear', scope: 'system', result_unconfirmed: true, total_networks: 2, cleared_networks: 1, error: 'fixture reply missing' }, text: '部分 DNS 缓存已清理，其余结果未确认。' }
];

for (const scenario of dnsCases) {
  test(`DNS ${scenario.name}：真实按钮防重复并按清理回执表达结果`, async ({ page }, testInfo) => {
    const held = gate();
    const posts = [];
    await page.route('**/cgi-bin/dns_cache.sh*', async (route) => {
      expect(route.request().method()).toBe('POST');
      posts.push(route.request().postDataJSON());
      await held.promise;
      await route.fulfill({ status: scenario.status, json: scenario.payload });
    });
    await openPage(page);
    await page.locator('#tab-network').click();
    const button = page.locator('#dns-cache-clear-btn');
    await expect(button).toHaveText('清理缓存');
    try {
      await button.click();
      await expect.poll(() => posts.length).toBe(1);
      expect(posts[0]).toEqual({ action: 'clear' });
      await expect(button).toBeDisabled();
      await expect(button).toHaveAttribute('aria-busy', 'true');
      await expect(button).toHaveText('清理中…');
      await button.dispatchEvent('click');
      expect(posts).toHaveLength(1);
    } finally { held.release(); }
    await expect(page.locator('#dns-cache-status')).toHaveText(scenario.text);
    await expect(button).toBeEnabled();
    await expect(button).toHaveAttribute('aria-busy', 'false');
    await expect(button).toHaveText('清理缓存');
    await expect(page.locator('#dns-cache-status')).not.toContainText(/网络已恢复|移动数据已恢复|修复成功/);
    await expect(page.locator('#dns-cache-scope')).toContainText('不更改网络设置');
    if (scenario.name === 'partial') await expect(page.locator('#log-inner')).toContainText('fixture network disappeared');
    expect(posts).toHaveLength(1);
    if (scenario.name === 'success') {
      await page.screenshot({ path: testInfo.outputPath(`dns-${testInfo.project.name}.png`), fullPage: true });
    }
  });
}

function auditLine(index, schema = 2) {
  return `schema=${schema} ts=${1700000000 + index} boot_id=fixture module_version=v4 root_family=apatch device=caiman phase=dns operation=flush result=success reason_code=DNS_CACHE_FLUSHED duration_ms=12`;
}

async function auditEndpoint(page, count = 1001, options = {}) {
  const requests = [];
  const writes = [];
  const snapshotId = 'a'.repeat(64);
  await page.route('**/cgi-bin/audit_log.sh*', async (route) => {
    if (route.request().method() !== 'GET') {
      writes.push(route.request().postDataJSON());
      await route.fulfill({ status: 400, json: { ok: false, error: 'No audit writes are expected in these tests' } });
      return;
    }
    const query = new URL(route.request().url()).searchParams;
    const limit = Number(query.get('limit') || 40);
    const offset = Number(query.get('offset') || 0);
    const all = query.get('all') === '1';
    requests.push({ limit, offset, all, snapshotId: query.get('snapshot_id') });
    if (options.changed && all && offset > 0) {
      await route.fulfill({ status: 409, json: { ok: false, error_code: 'AUDIT_SNAPSHOT_CHANGED', error: '日志已变化，请重新开始读取或导出' } });
      return;
    }
    const end = Math.min(count, offset + limit);
    const lines = Array.from({ length: end - offset }, (_, index) => auditLine(offset + index));
    await route.fulfill({ json: {
      ok: true, schema: 2, source: 'structured_audit', lines, limit, rotated: true,
      total_lines: count, offset, next_offset: end < count ? end : null,
      complete: end === count, truncated: end < count, snapshot_id: snapshotId
    } });
  });
  return { requests, writes, snapshotId };
}

async function openLogs(page) {
  await openPage(page);
  await page.locator('#log-toggle').click();
  await page.locator('#log-audit-btn').click();
  await expect(page.locator('#audit-log-view')).toBeVisible();
  await expect(page.locator('#audit-log-refresh')).toBeEnabled();
}

async function readDownload(download) {
  return fs.readFile(await download.path(), 'utf8');
}

test('日志JSON/TXT导入是独立只读快照，保留未知格式且内容作为纯文本', async ({ page }, testInfo) => {
  const api = await auditEndpoint(page, 2);
  await openLogs(page);
  const marker = '<img src=x onerror="window.logImportExecuted=true">';
  const imported = {
    schema: 'pixel9pro.logs.v1', exportedAt: 1700000010000, source: 'page',
    range: { start: 1700000000000, end: 1700000000000 }, truncated: false, invalidCount: 0, unsupportedCount: 0,
    entries: [{ ts: 1700000000000, level: 'error', source: 'page', phase: 'request', operation: 'import-fixture',
      result: 'failed', code: 'IMPORT_FIXTURE', message: marker, detail: 'import-only-detail-marker', durationMs: null, count: 1 }]
  };
  await page.locator('#audit-log-file').setInputFiles({ name: 'fixture.json', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify(imported)) });
  await expect(page.locator('#audit-log-source')).toHaveValue('import');
  await expect(page.locator('#audit-log-content')).toContainText(marker);
  await expect(page.locator('#audit-log-clear')).toBeDisabled();
  expect(await page.evaluate(() => window.logImportExecuted)).toBeUndefined();
  await expect(page.locator('#audit-log-view img')).toHaveCount(0);
  expect(api.writes).toHaveLength(0);
  await page.locator('#audit-log-source').selectOption('page');
  await expect(page.locator('#audit-log-content')).not.toContainText(marker);
  const text = [auditLine(0), 'schema=2 ts=1700000001 phase=dns', auditLine(2, 99)].join('\n');
  await page.locator('#audit-log-file').setInputFiles({ name: 'module.txt', mimeType: 'text/plain', buffer: Buffer.from(text) });
  await expect(page.locator('#audit-log-source')).toHaveValue('import');
  await expect(page.locator('#audit-log-content')).toContainText('不支持的模块日志 schema=99');
  await expect(page.locator('#audit-log-content')).toContainText('不完整或字段无效');
  await expect(page.locator('#audit-log-problems')).toContainText('无法解析 1 条');
  await expect(page.locator('#audit-log-problems')).toContainText('不支持的格式 1 条');
  await expect(page.locator('#audit-log-clear')).toBeDisabled();
  await page.locator('#audit-log-format').selectOption('txt');
  const textDownload = page.waitForEvent('download');
  await page.locator('#audit-log-export').click();
  const savedText = await readDownload(await textDownload);
  expect(savedText).toContain('# pixel9pro.logs.v1');
  expect(savedText).toContain('schema=99');
  await page.locator('#audit-log-file').setInputFiles({ name: 'roundtrip.txt', mimeType: 'text/plain', buffer: Buffer.from(savedText) });
  await expect(page.locator('#audit-log-status')).toContainText('已载入只读快照');
  await expect(page.locator('#audit-log-problems')).toContainText('无法解析 1 条');
  expect(api.writes).toHaveLength(0);
  const storage = await page.evaluate(() => localStorage.getItem('pixel9pro_runtime_log_v3') || '');
  expect(storage).not.toContain('import-only-detail-marker');
  expect(storage).not.toContain(marker);
  if (testInfo.project.name === 'mobile-320') {
    const dimensions = await page.evaluate(() => ({ width: innerWidth, scroll: document.documentElement.scrollWidth }));
    expect(dimensions.scroll).toBeLessThanOrEqual(dimensions.width + 1);
  }
  await page.screenshot({ path: testInfo.outputPath(`logs-import-${testInfo.project.name}.png`), fullPage: true });
});

test('模块日志完整导出以500条分页固定快照，JSON保留范围与完整性元数据', async ({ page }) => {
  const api = await auditEndpoint(page);
  await openLogs(page);
  api.requests.length = 0;
  await page.locator('#audit-log-format').selectOption('json');
  const downloaded = page.waitForEvent('download');
  await page.locator('#audit-log-export').click();
  const output = JSON.parse(await readDownload(await downloaded));
  expect(output.schema).toBe('pixel9pro.logs.v1');
  expect(output.source).toBe('module');
  expect(output.entries).toHaveLength(1001);
  expect(output.truncated).toBe(false);
  expect(output.invalidCount).toBe(0);
  expect(output.unsupportedCount).toBe(0);
  expect(output.range).toEqual({ start: 1700000000000, end: 1700001000000 });
  const pages = api.requests.filter((request) => request.all && request.limit === 500);
  expect(pages.map((request) => request.offset)).toEqual([0, 500, 1000]);
  expect(pages.slice(1).every((request) => request.snapshotId === api.snapshotId)).toBe(true);
  await expect(page.locator('#audit-log-status')).toContainText(/生成|下载/);
  expect(api.writes).toHaveLength(0);
});

test('模块日志分页中409必须中止导出，不将前页伪装成完整文件', async ({ page }) => {
  const api = await auditEndpoint(page, 1001, { changed: true });
  const downloads = [];
  page.on('download', (download) => downloads.push(download));
  await openLogs(page);
  api.requests.length = 0;
  await page.locator('#audit-log-format').selectOption('json');
  await page.locator('#audit-log-export').click();
  await expect(page.locator('#audit-log-status')).toContainText(/日志已更新|日志已变化/);
  await expect(page.locator('#audit-log-export')).toBeEnabled();
  expect(api.requests.filter((request) => request.all && request.limit === 500).map((request) => request.offset)).toEqual([0, 500]);
  expect(downloads).toHaveLength(0);
  await expect(page.locator('#audit-log-status')).not.toContainText(/完整导出|已生成|已发起下载/);
  expect(api.writes).toHaveLength(0);
});

test('浏览器仅持久化关键摘要，页面离开后不保存detail或普通轮询记录', async ({ page }) => {
  await auditEndpoint(page, 2);
  await openPage(page);
  await page.evaluate(() => {
    requireFeature('core').appendLog('fixture-key-result', 'err', 'fixture-private-detail-never-persist');
    requireFeature('core').appendLog('fixture-ordinary-poll', 'dim', 'fixture-ordinary-detail');
  });
  await page.reload();
  await expect(page.locator('#topbar-kicker')).toContainText('Pixel 9 Pro');
  const raw = await page.evaluate(() => localStorage.getItem('pixel9pro_runtime_log_v3'));
  expect(raw).not.toBeNull();
  const stored = JSON.parse(raw);
  expect(stored.schema).toBe(3);
  expect(stored.entries.length).toBeLessThanOrEqual(32);
  expect(raw).toContain('fixture-key-result');
  expect(raw).not.toContain('fixture-private-detail-never-persist');
  expect(raw).not.toContain('fixture-ordinary-poll');
  expect(raw).not.toContain('fixture-ordinary-detail');
  expect(stored.entries.every((entry) => !Object.hasOwn(entry, 'detail'))).toBe(true);
});
