const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const root = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const webroot = path.join(root, 'webroot');
const html = fs.readFileSync(path.join(webroot, 'index.html'), 'utf8');
const expectedScripts = [
  '/js/runtime.js?v=__WEBUI_VER__',
  '/js/theme.js?v=__WEBUI_VER__',
  '/js/ui.js?v=__WEBUI_VER__',
  '/js/common.js?v=__WEBUI_VER__',
  '/js/profile.js?v=__WEBUI_VER__',
  '/js/thermal.js?v=__WEBUI_VER__',
  '/js/memory.js?v=__WEBUI_VER__',
  '/js/network.js?v=__WEBUI_VER__',
  '/js/energy.js?v=__WEBUI_VER__',
  '/app.js?v=__WEBUI_VER__'
];
const scripts = [...html.matchAll(/<script\s+src="([^"]+)"/g)].map((match) => match[1]);

assert.deepStrictEqual(scripts, expectedScripts, 'WebUI 脚本路径或加载顺序发生漂移');
assert.strictEqual(new Set(scripts).size, scripts.length, 'WebUI 脚本不得重复加载');
assert.strictEqual(scripts.at(-1), '/app.js?v=__WEBUI_VER__', 'app.js 必须最后加载');

for (const source of scripts) {
  assert(source.endsWith('?v=__WEBUI_VER__'), `脚本缺少统一版本占位：${source}`);
  const relativePath = source.split('?')[0].replace(/^\//, '');
  const absolutePath = path.join(webroot, relativePath);
  assert(fs.existsSync(absolutePath), `脚本文件不存在：${relativePath}`);
  const parsed = spawnSync(process.execPath, ['--check', absolutePath], { encoding: 'utf8' });
  assert.strictEqual(parsed.status, 0, `脚本语法检查失败：${relativePath}\n${parsed.stderr}`);
}

const runtime = fs.readFileSync(path.join(webroot, 'js', 'runtime.js'), 'utf8');
const bootstrap = fs.readFileSync(path.join(webroot, 'app.js'), 'utf8');
assert(runtime.includes('function requireFeature(name)'), '功能注册表必须提供显式读取入口');
assert(!runtime.includes('const state ='), 'runtime.js 不得重新持有 feature state');
assert(!runtime.includes('Pixel9ProControl.state'), '运行时全局不得暴露 feature state');
assert(!/value:\s*Object\.freeze\(\{[\s\S]*?\bstate\s*,/.test(runtime), 'Pixel9ProControl 不得导出 state');

const privateStateContracts = {
  'theme.js': ['const state = {'],
  'ui.js': ['const state = {'],
  'common.js': ['const authState = {', 'const shellState = {'],
  'profile.js': ['const state = {'],
  'thermal.js': ['const state = {'],
  'memory.js': ['const state = {'],
  'network.js': ['const state = {'],
  'energy.js': ['const state = {']
};
for (const [file, markers] of Object.entries(privateStateContracts)) {
  const source = fs.readFileSync(path.join(webroot, 'js', file), 'utf8');
  assert(source.includes('(() => {'), `${file} 必须用私有 scope 隔离 feature state`);
  for (const marker of markers) assert(source.includes(marker), `${file} 缺少私有 state：${marker}`);
}
for (const feature of ['core', 'auth', 'shell', 'ui', 'theme', 'profile', 'thermal', 'memory', 'network', 'energy']) {
  assert(bootstrap.includes(`requireFeature('${feature}')`), `bootstrap 未声明功能依赖：${feature}`);
}
assert(bootstrap.includes("registerFeature('app'"), 'bootstrap 必须注册 poll coordinator API');

process.stdout.write(`WebUI 资源契约通过：${scripts.length} 个脚本\n`);
