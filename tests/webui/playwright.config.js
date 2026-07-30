const fs = require('fs');
const path = require('path');
const { defineConfig } = require('@playwright/test');

const repoRoot = path.resolve(__dirname, '..', '..');
const projectRoot = path.resolve(repoRoot, '..');
const runtimeRoot = process.env.PIXEL_PLAYWRIGHT_RUNTIME
  || 'F:\\Environment\\BrowserRuntimes\\Playwright';
const artifactRoot = process.env.PIXEL_WEBUI_ARTIFACT_DIR
  || path.join(projectRoot, 'work', 'pixel9pro_control_webui_playwright');

function resolveChromiumExecutable() {
  if (!fs.existsSync(runtimeRoot)) {
    throw new Error(`Playwright runtime not found: ${runtimeRoot}`);
  }
  const revisions = fs.readdirSync(runtimeRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && /^chromium-\d+$/.test(entry.name))
    .map((entry) => entry.name)
    .sort((a, b) => Number(b.split('-')[1]) - Number(a.split('-')[1]));
  const suffixes = [
    path.join('chrome-win64', 'chrome.exe'),
    path.join('chrome-win', 'chrome.exe'),
  ];
  for (const revision of revisions) {
    for (const suffix of suffixes) {
      const executable = path.join(runtimeRoot, revision, suffix);
      if (fs.existsSync(executable)) return executable;
    }
  }
  throw new Error(`Chromium executable not found under ${runtimeRoot}`);
}

module.exports = defineConfig({
  testDir: __dirname,
  testMatch: 'webui.spec.js',
  timeout: 30_000,
  expect: { timeout: 8_000 },
  fullyParallel: false,
  workers: 1,
  reporter: [['list'], ['html', { outputFolder: path.join(artifactRoot, 'report'), open: 'never' }]],
  outputDir: path.join(artifactRoot, 'results'),
  webServer: {
    command: 'node tests/webui/mock_server.js',
    cwd: repoRoot,
    url: 'http://127.0.0.1:6210/cgi-bin/status.sh',
    timeout: 15_000,
    reuseExistingServer: false,
  },
  use: {
    baseURL: 'http://127.0.0.1:6210',
    browserName: 'chromium',
    launchOptions: { executablePath: resolveChromiumExecutable() },
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },
  projects: [
    { name: 'desktop-1440', use: { viewport: { width: 1440, height: 1000 } } },
    { name: 'mobile-320', use: { viewport: { width: 320, height: 720 }, isMobile: true, hasTouch: true } },
    { name: 'mobile-390', use: { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true } },
    { name: 'pixel-427', use: { viewport: { width: 427, height: 900 }, isMobile: true, hasTouch: true } },
  ],
});
