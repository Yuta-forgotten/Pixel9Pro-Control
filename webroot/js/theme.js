// 主题模式与调色盘功能。
'use strict';
(() => {
const state = {
  mode: 'system',
  paletteName: 'default',
  paletteCustom: '#3aa6c2'
};
const showToast = (...args) => requireFeature('core').showToast(...args);
const readPreference = (key) => { try { return localStorage.getItem(key); } catch (_) { return null; } };
const writePreference = (key, value) => { try { localStorage.setItem(key, value); } catch (_) { /* Session preference remains usable. */ } };

function getResolvedTheme(mode) {
  if (mode === 'light' || mode === 'dark') return mode;
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

function getThemeLabel(mode) {
  if (mode === 'light') return '浅色模式';
  if (mode === 'dark') return '深色模式';
  return '跟随系统';
}

function normalizeThemeMode(mode) {
  return mode === 'light' || mode === 'dark' || mode === 'system' ? mode : 'system';
}

function syncThemeUi() {
  const resolved = getResolvedTheme(state.mode);
  document.documentElement.dataset.theme = resolved;
  document.querySelector('meta[name="theme-color"]').setAttribute('content', resolved === 'dark' ? '#191c1b' : '#eceeec');
  requireFeature('ui').setStaticHtml(refs.themeBtnIcon, THEME_ICONS[state.mode] || THEME_ICONS.system);
  refs.topbarThemeChip.textContent = `界面 · ${getThemeLabel(state.mode)}`;
  refs.themeChoices.forEach((choice) => {
    const selected = choice.dataset.themeOption === state.mode;
    choice.classList.toggle('selected', selected);
    choice.setAttribute('aria-pressed', String(selected));
  });
  document.querySelectorAll('[data-seg-theme]').forEach((b) => {
    const selected = b.dataset.segTheme === state.mode;
    b.classList.toggle('active', selected);
    b.setAttribute('aria-pressed', String(selected));
  });
}

function applyTheme(mode, persist = true) {
  state.mode = normalizeThemeMode(mode);
  if (persist) { writePreference(STORAGE_THEME_KEY, state.mode); saveThemeToServer(); }
  syncThemeUi();
  // 自定义/预设主题色在明暗下取色不同, 切换模式时按新明暗重新派生
  if (state.paletteName && state.paletteName !== 'default') applyPalette(state.paletteName, false);
  document.dispatchEvent(new Event('webui-theme-changed'));
}

function initTheme() {
  applyTheme(readPreference(STORAGE_THEME_KEY) || 'system', false);
  const mq = window.matchMedia('(prefers-color-scheme: dark)');
  const handle = () => { if (state.mode === 'system') applyTheme('system', false); };
  if (mq.addEventListener) mq.addEventListener('change', handle);
  else mq.addListener(handle);
}

// ── 调色盘 (主题色) ──────────────────────────────────────────
// 只驱动"可调强调角色" --primary 家族; 背景/语义/温度色保持中性固定 (M3: 非全局可调)。
function hexToRgb(h) {
  let s = String(h).trim().replace('#', '');
  if (s.length === 3) s = s.split('').map((c) => c + c).join('');
  const n = parseInt(s, 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}
function rgbToHex(rgb) {
  return '#' + rgb.map((v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0')).join('');
}
function relLum(rgb) {
  const s = rgb.map((v) => { v /= 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
  return 0.2126 * s[0] + 0.7152 * s[1] + 0.0722 * s[2];
}
function contrast(a, b) { const x = relLum(a), y = relLum(b); return (Math.max(x, y) + .05) / (Math.min(x, y) + .05); }
function onColorFor(rgb) { return contrast(rgb, [0, 0, 0]) >= contrast(rgb, [255, 255, 255]) ? [0, 0, 0] : [255, 255, 255]; }
function readableAccent(rgb, isDark) {
  const surface = hexToRgb(isDark ? '#333735' : '#dce0dd');
  let result = rgb.map(Math.round);
  const end = isDark ? 255 : 0;
  for (let step = 0; step < 100 && contrast(result, surface) < 4.5; step += 1) {
    result = result.map((value) => Math.round(value + (end - value) * .08));
  }
  return result;
}

function hexToHsl(hex) {
  const [r, g, b] = hexToRgb(hex).map((v) => v / 255);
  const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
  let h = 0; const l = (max + min) / 2;
  const s = d === 0 ? 0 : (l > 0.5 ? d / (2 - max - min) : d / (max + min));
  if (d !== 0) {
    if (max === r) h = (g - b) / d + (g < b ? 6 : 0);
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h *= 60;
  }
  return [h, s, l];
}
function hslToRgb(h, s, l) {
  h = ((h % 360) + 360) % 360;
  s = Math.max(0, Math.min(1, s));
  l = Math.max(0, Math.min(1, l));
  const c = (1 - Math.abs(2 * l - 1)) * s, x = c * (1 - Math.abs((h / 60) % 2 - 1)), m = l - c / 2;
  let r, g, b;
  if (h < 60) { r = c; g = x; b = 0; }
  else if (h < 120) { r = x; g = c; b = 0; }
  else if (h < 180) { r = 0; g = c; b = x; }
  else if (h < 240) { r = 0; g = x; b = c; }
  else if (h < 300) { r = x; g = 0; b = c; }
  else { r = c; g = 0; b = x; }
  return [(r + m) * 255, (g + m) * 255, (b + m) * 255];
}
function hslHex(h, s, l) { return rgbToHex(hslToRgb(h, s, l)); }

// Local accent approximation, not an MCU dynamic-color implementation.
// Operational colors and neutral surfaces stay fixed; every generated pair is checked.
function deriveTheme(seedHex, isDark) {
  const [h, s0] = hexToHsl(seedHex);
  const s = Math.max(.35, Math.min(.92, s0));
  const primary = readableAccent(hslToRgb(h, Math.min(s, .72), isDark ? .72 : .36), isDark);
  const tertiary = readableAccent(hslToRgb(h + 55, Math.min(s, .6), isDark ? .72 : .36), isDark);
  const container = hslToRgb(h, s * .55, isDark ? .22 : .9);
  const secondary = hslToRgb(h, s * .28, isDark ? .25 : .9);
  const tertiaryContainer = hslToRgb(h + 55, s * .45, isDark ? .22 : .9);
  return {
    '--primary': rgbToHex(primary),
    '--on-primary': rgbToHex(onColorFor(primary)),
    '--primary-container': rgbToHex(container),
    '--on-primary-container': rgbToHex(onColorFor(container)),
    '--secondary-container': rgbToHex(secondary),
    '--secondary-ink': rgbToHex(onColorFor(secondary)),
    '--tertiary': rgbToHex(tertiary),
    '--tertiary-container': rgbToHex(tertiaryContainer),
    '--on-tertiary-container': rgbToHex(onColorFor(tertiaryContainer))
  };
}

function isValidHex(v) { return typeof v === 'string' && /^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(v.trim()); }
function normalizeHex(v) {
  let h = String(v).trim().replace('#', '');
  if (h.length === 3) h = h.split('').map((c) => c + c).join('');
  return '#' + h.toLowerCase();
}

function applyPalette(name, persist = true) {
  state.paletteName = name;
  if (persist) { writePreference(STORAGE_PALETTE_KEY, name); saveThemeToServer(); }
  const root = document.documentElement;
  let seed = null;
  if (name === 'custom') seed = state.paletteCustom;
  else { const p = PALETTES.find((x) => x.name === name); if (p && p.name !== 'default') seed = p.seed; }
  PALETTE_VARS.forEach((v) => root.style.removeProperty(v));
  if (seed && isValidHex(seed)) {
    const vars = deriveTheme(seed, getResolvedTheme(state.mode) === 'dark');
    PALETTE_VARS.forEach((v) => { if (vars[v] != null) root.style.setProperty(v, vars[v]); });
  }
  syncPaletteUi();
  document.dispatchEvent(new Event('webui-theme-changed'));
}

function syncPaletteUi() {
  document.querySelectorAll('#swatch-row .swatch').forEach((b) => {
    const selected = b.dataset.palette === state.paletteName;
    b.classList.toggle('active', selected);
    b.setAttribute('aria-pressed', String(selected));
  });
  const preview = document.getElementById('palette-custom-preview');
  if (preview) {
    preview.style.background = state.paletteCustom;
    preview.classList.toggle('active', state.paletteName === 'custom');
  }
  const input = document.getElementById('palette-hex-input');
  if (input && document.activeElement !== input) {
    input.value = state.paletteName === 'custom' ? state.paletteCustom : '';
  }
}

function renderPaletteSwatches() {
  const row = document.getElementById('swatch-row');
  if (!row) return;
  row.replaceChildren();
  PALETTES.forEach((p) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'swatch';
    btn.dataset.palette = p.name;
    btn.style.setProperty('--swatch', p.seed);
    btn.setAttribute('aria-label', `主题色 ${p.label}`);
    btn.setAttribute('aria-pressed', String(p.name === state.paletteName));
    btn.title = p.label;
    requireFeature('ui').setStaticHtml(btn, '<span class="swatch-check" aria-hidden="true"><svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg></span>');
    row.appendChild(btn);
  });
}

function applyCustomHex() {
  const input = document.getElementById('palette-hex-input');
  if (!input) return;
  const raw = (input.value || '').trim();
  if (!isValidHex(raw)) { showToast('请输入有效颜色，如 #3aa6c2', 2600, 'err'); return; }
  const hex = normalizeHex(raw);
  state.paletteCustom = hex;
  writePreference(STORAGE_PALETTE_CUSTOM_KEY, hex);
  applyPalette('custom', true);
  showToast('已应用自定义主题色');
}

function initPalette() {
  const savedCustom = readPreference(STORAGE_PALETTE_CUSTOM_KEY);
  state.paletteCustom = isValidHex(savedCustom) ? normalizeHex(savedCustom) : '#3aa6c2';
  applyPalette(readPreference(STORAGE_PALETTE_KEY) || 'default', false);
}

// 服务端兜底: localStorage 为主存储, 此处仅在每次改主题时静默备份到 $MODDIR/.webui_theme,
// 配合 customize.sh 迁移, 即使 WebView 清数据或模块更新也能回读 (失败静默, 不打扰用户)
function saveThemeToServer() {
  requireFeature('core').apiFetch(API.theme, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ mode: state.mode, palette: state.paletteName, custom: state.paletteCustom }),
    timeoutMs: 5000
  }).catch(() => {});
}

// 仅当 localStorage 完全无主题记录 (新装 / WebView 被清) 时, 回读服务端兜底并应用
async function restoreThemeFromServerIfNeeded() {
  if (readPreference(STORAGE_THEME_KEY) || readPreference(STORAGE_PALETTE_KEY) || readPreference(STORAGE_PALETTE_CUSTOM_KEY)) return;
  try {
    const data = await requireFeature('core').apiFetch(API.theme, { timeoutMs: 5000 });
    if (!data) return;
    if (data.custom && isValidHex(data.custom)) {
      state.paletteCustom = normalizeHex(data.custom);
      writePreference(STORAGE_PALETTE_CUSTOM_KEY, state.paletteCustom);
    }
    if (data.mode && data.mode !== 'system') {
      writePreference(STORAGE_THEME_KEY, data.mode);
      applyTheme(data.mode, false);
    }
    if (data.palette && data.palette !== 'default') {
      writePreference(STORAGE_PALETTE_KEY, data.palette);
      applyPalette(data.palette, false);
    }
  } catch (_) {}
}

registerFeature('theme', {
  initialize() {
    initTheme();
    renderPaletteSwatches();
    initPalette();
    void restoreThemeFromServerIfNeeded();
  },
  applyCustomHex,
  applyPalette,
  applyTheme,
  getThemeLabel
});
})();
