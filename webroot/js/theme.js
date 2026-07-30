// 主题模式与调色盘功能。
'use strict';
(() => {
const state = {
  mode: 'system',
  paletteName: 'default',
  paletteCustom: '#3aa6c2'
};
const showToast = (...args) => requireFeature('core').showToast(...args);

function getResolvedTheme(mode) {
  if (mode === 'light' || mode === 'dark') return mode;
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

function getThemeLabel(mode) {
  if (mode === 'light') return '浅色模式';
  if (mode === 'dark') return '深色模式';
  return '跟随系统';
}

function syncThemeUi() {
  const resolved = getResolvedTheme(state.mode);
  document.documentElement.dataset.theme = resolved;
  document.querySelector('meta[name="theme-color"]').setAttribute('content', resolved === 'dark' ? '#191c1b' : '#eceeec');
  requireFeature('ui').setStaticHtml(refs.themeBtnIcon, THEME_ICONS[state.mode] || THEME_ICONS.system);
  refs.topbarThemeChip.textContent = `界面 · ${getThemeLabel(state.mode)}`;
  refs.themeChoices.forEach((choice) => {
    choice.classList.toggle('selected', choice.dataset.themeOption === state.mode);
  });
  document.querySelectorAll('[data-seg-theme]').forEach((b) => {
    b.classList.toggle('active', b.dataset.segTheme === state.mode);
  });
}

function applyTheme(mode, persist = true) {
  state.mode = mode;
  if (persist) { localStorage.setItem(STORAGE_THEME_KEY, mode); saveThemeToServer(); }
  syncThemeUi();
  // 自定义/预设主题色在明暗下取色不同, 切换模式时按新明暗重新派生
  if (state.paletteName && state.paletteName !== 'default') applyPalette(state.paletteName, false);
}

function initTheme() {
  applyTheme(localStorage.getItem(STORAGE_THEME_KEY) || 'system', false);
  const mq = window.matchMedia('(prefers-color-scheme: dark)');
  const handle = () => { if (state.mode === 'system') { syncThemeUi(); if (state.paletteName !== 'default') applyPalette(state.paletteName, false); } };
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
  const s = rgb.map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
  return 0.2126 * s[0] + 0.7152 * s[1] + 0.0722 * s[2];
}
function onColorFor(rgb) { return relLum(rgb) > 0.45 ? [20, 26, 24] : [255, 255, 255]; }

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

// 由种子色派生一整套协调色 (M3E 风格: primary/secondary/tertiary 三色 + 状态正向/信息 + 中性表面随种子轻染)。
// 仅预设(非 default)与自定义时调用; warn(琥珀)/danger(红)/温度色阶保持固定语义, 保证告警一眼可辨。
function deriveTheme(seedHex, isDark) {
  const [h, s0] = hexToHsl(seedHex);
  const s = Math.max(0.35, Math.min(0.92, s0));
  const th = h + 55; // tertiary 旋转色相, 形成第三主题色
  const out = {};
  if (!isDark) {
    const primary = hslToRgb(h, s, 0.36);
    out['--primary'] = rgbToHex(primary);
    out['--on-primary'] = rgbToHex(onColorFor(primary));
    out['--primary-container'] = hslHex(h, s * 0.55, 0.88);
    out['--on-primary-container'] = hslHex(h, s, 0.15);
    out['--secondary-container'] = hslHex(h, s * 0.28, 0.90);
    out['--secondary-ink'] = hslHex(h, s * 0.5, 0.20);
    out['--tertiary'] = hslHex(th, s * 0.6, 0.36);
    out['--tertiary-container'] = hslHex(th, s * 0.5, 0.87);
    out['--on-tertiary-container'] = hslHex(th, s * 0.6, 0.15);
    out['--success'] = hslHex(th, s * 0.6, 0.32);
    out['--success-container'] = hslHex(th, s * 0.45, 0.88);
    out['--info'] = hslHex(h, s * 0.55, 0.38);
    out['--info-container'] = hslHex(h, s * 0.4, 0.90);
    out['--sc-lowest'] = hslHex(h, s * 0.10, 0.995);
    out['--sc-low'] = hslHex(h, s * 0.14, 0.965);
    out['--sc'] = hslHex(h, s * 0.16, 0.935);
    out['--sc-high'] = hslHex(h, s * 0.16, 0.905);
    out['--sc-highest'] = hslHex(h, s * 0.16, 0.875);
    out['--bg'] = hslHex(h, s * 0.18, 0.975);
    out['--bg-canvas'] = `linear-gradient(180deg,${hslHex(h, s * 0.20, 0.975)} 0%,${hslHex(h, s * 0.14, 0.955)} 52%,${hslHex(h, s * 0.10, 0.965)} 100%)`;
  } else {
    const primary = hslToRgb(h, Math.min(s, 0.72), 0.72);
    out['--primary'] = rgbToHex(primary);
    out['--on-primary'] = rgbToHex(onColorFor(primary));
    out['--primary-container'] = hslHex(h, s * 0.65, 0.27);
    out['--on-primary-container'] = hslHex(h, s * 0.5, 0.86);
    out['--secondary-container'] = hslHex(h, s * 0.28, 0.26);
    out['--secondary-ink'] = hslHex(h, s * 0.3, 0.85);
    out['--tertiary'] = hslHex(th, Math.min(s, 0.6), 0.72);
    out['--tertiary-container'] = hslHex(th, s * 0.5, 0.26);
    out['--on-tertiary-container'] = hslHex(th, s * 0.45, 0.86);
    out['--success'] = hslHex(th, s * 0.5, 0.70);
    out['--success-container'] = hslHex(th, s * 0.45, 0.22);
    out['--info'] = hslHex(h, s * 0.5, 0.72);
    out['--info-container'] = hslHex(h, s * 0.45, 0.24);
    out['--sc-lowest'] = hslHex(h, s * 0.20, 0.065);
    out['--sc-low'] = hslHex(h, s * 0.18, 0.105);
    out['--sc'] = hslHex(h, s * 0.18, 0.125);
    out['--sc-high'] = hslHex(h, s * 0.18, 0.16);
    out['--sc-highest'] = hslHex(h, s * 0.18, 0.20);
    out['--bg'] = hslHex(h, s * 0.22, 0.075);
    out['--bg-canvas'] = `linear-gradient(180deg,${hslHex(h, s * 0.24, 0.075)} 0%,${hslHex(h, s * 0.18, 0.065)} 52%,${hslHex(h, s * 0.14, 0.085)} 100%)`;
  }
  return out;
}

function isValidHex(v) { return typeof v === 'string' && /^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(v.trim()); }
function normalizeHex(v) {
  let h = String(v).trim().replace('#', '');
  if (h.length === 3) h = h.split('').map((c) => c + c).join('');
  return '#' + h.toLowerCase();
}

function applyPalette(name, persist = true) {
  state.paletteName = name;
  if (persist) { localStorage.setItem(STORAGE_PALETTE_KEY, name); saveThemeToServer(); }
  const root = document.documentElement;
  let seed = null;
  if (name === 'custom') seed = state.paletteCustom;
  else { const p = PALETTES.find((x) => x.name === name); if (p && p.name !== 'default') seed = p.seed; }
  if (!seed || !isValidHex(seed)) {
    PALETTE_VARS.forEach((v) => root.style.removeProperty(v)); // 默认: 全部回退 :root 清新青绿
  } else {
    const vars = deriveTheme(seed, getResolvedTheme(state.mode) === 'dark');
    PALETTE_VARS.forEach((v) => { if (vars[v] != null) root.style.setProperty(v, vars[v]); });
  }
  syncPaletteUi();
}

function syncPaletteUi() {
  document.querySelectorAll('#swatch-row .swatch').forEach((b) => {
    b.classList.toggle('active', b.dataset.palette === state.paletteName);
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
  localStorage.setItem(STORAGE_PALETTE_CUSTOM_KEY, hex);
  applyPalette('custom', true);
  showToast('已应用自定义主题色');
}

function initPalette() {
  const savedCustom = localStorage.getItem(STORAGE_PALETTE_CUSTOM_KEY);
  state.paletteCustom = isValidHex(savedCustom) ? normalizeHex(savedCustom) : '#3aa6c2';
  applyPalette(localStorage.getItem(STORAGE_PALETTE_KEY) || 'default', false);
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
  if (localStorage.getItem(STORAGE_THEME_KEY) || localStorage.getItem(STORAGE_PALETTE_KEY) || localStorage.getItem(STORAGE_PALETTE_CUSTOM_KEY)) return;
  try {
    const data = await requireFeature('core').apiFetch(API.theme, { timeoutMs: 5000 });
    if (!data) return;
    if (data.custom && isValidHex(data.custom)) {
      state.paletteCustom = normalizeHex(data.custom);
      localStorage.setItem(STORAGE_PALETTE_CUSTOM_KEY, state.paletteCustom);
    }
    if (data.mode && data.mode !== 'system') {
      localStorage.setItem(STORAGE_THEME_KEY, data.mode);
      applyTheme(data.mode, false);
    }
    if (data.palette && data.palette !== 'default') {
      localStorage.setItem(STORAGE_PALETTE_KEY, data.palette);
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

