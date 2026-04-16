if (location.host !== '127.0.0.1:6210') {
  location.replace('http://127.0.0.1:6210');
}

'use strict';

const API = {
  profile: '/cgi-bin/profile.sh',
  status: '/cgi-bin/status.sh',
  info: '/cgi-bin/info.sh',
  thermal: '/cgi-bin/thermal.sh',
  thermalSet: '/cgi-bin/set_thermal.sh',
  reboot: '/cgi-bin/reboot.sh',
  optimize: '/cgi-bin/optimize.sh',
  swap: '/cgi-bin/swap.sh',
};

const STORAGE_THEME_KEY = 'pixel9pro_theme_mode';
const TAB_ORDER = ['home', 'perf', 'thermal', 'optim'];
const TAB_META = {
  home: '状态总览',
  perf: '性能调度',
  thermal: '温控管理',
  optim: '系统优化',
};
const CLUSTERS = [
  { label: 'Cluster 0 (小核 · cpu0-3)', maxHz: 1950000 },
  { label: 'Cluster 1 (中核 · cpu4-6)', maxHz: 2600000 },
  { label: 'Cluster 2 (大核 · cpu7)', maxHz: 3105000 },
];
const HOME_CPU_LABELS = ['小核', '中核', '大核'];
const TEMP_MIN = 25;
const TEMP_MAX = 60;
const THRESH_STOCK = 39;
const THRESH_MOD = 43;
const PULL_CIRC = 62.83;

const THEME_ICONS = {
  system: '<svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor"><path d="M4 5h16v10H4zm0 12h16v2H4z"/></svg>',
  light: '<svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor"><path d="M6.76 4.84l-1.8-1.79-1.41 1.41 1.79 1.8 1.42-1.42zM1 13h3v-2H1v2zm10-9h2V1h-2v3zm7.45 1.46l1.79-1.8-1.41-1.41-1.8 1.79 1.42 1.42zM17.24 19.16l1.8 1.79 1.41-1.41-1.79-1.8-1.42 1.42zM20 11v2h3v-2h-3zM11 20h2v3h-2v-3zm-7.45-2.54l-1.79 1.8 1.41 1.41 1.8-1.79-1.42-1.42zM12 6a6 6 0 100 12 6 6 0 000-12z"/></svg>',
  dark: '<svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor"><path d="M9.37 5.51A7 7 0 0018.49 14.63 9 9 0 119.37 5.51z"/></svg>',
};

const PROFILES = {
  game: {
    name: '游戏模式',
    summary: 'top-app 使用全核 0-7，响应 8/8/8ms，性能释放最积极。',
    desc: 'top-app: cpu0-7 全核 · 响应 8/8/8ms · 全核功耗较高',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M7 2v11h3v9l7-12h-4l4-8z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M7 2v11h3v9l7-12h-4l4-8z"/></svg>',
    modeClass: 'mode-game',
    detail: '<b>游戏模式</b><br><br><b>cpuset</b>: top-app → cpu0-7 全核<br><b>response_time</b>: 小核 8ms / 中核 8ms / 大核 8ms<br><br>游戏进程可使用全部核心，升频和降频都极快。由于全核高频功耗更高，建议在重负载和短时性能场景下使用。'
  },
  balanced: {
    name: '平衡模式',
    summary: '前台优先中大核，小核锁 820MHz，日常流畅与温度控制兼顾。',
    desc: '前台: cpu4-7 · 后台: cpu0-3 · 小核锁 820MHz · 中核 12ms · 大核 8ms',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z"/></svg>',
    modeClass: 'mode-balanced',
    detail: '<b>平衡模式</b><br><br><b>cpuset</b>: top-app → cpu4-7，background → cpu0-3<br><b>response_time</b>: 小核 200ms / 中核 12ms / 大核 8ms<br><br>通过拖慢小核升频时间把它稳定压在 820MHz，前台主要依赖中大核处理交互，日常体验与发热控制较均衡。'
  },
  light: {
    name: '轻度模式',
    summary: '核心分配与平衡相同，但中大核升频更慢，适合长时轻负载。',
    desc: '前台: cpu4-7 · 后台: cpu0-3 · 小核锁 820MHz · 中核 20ms · 大核 16ms',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M6.76 4.84l-1.8-1.79-1.41 1.41 1.79 1.8 1.42-1.42zM1 13h3v-2H1v2zm10-9h2V1h-2v3zm7.45 1.46l1.79-1.8-1.41-1.41-1.8 1.79 1.42 1.42zM17.24 19.16l1.8 1.79 1.41-1.41-1.79-1.8-1.42 1.42zM20 11v2h3v-2h-3zM11 20h2v3h-2v-3zm-7.45-2.54l-1.79 1.8 1.41 1.41 1.8-1.79-1.42-1.42zM12 6a6 6 0 100 12 6 6 0 000-12z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M6.76 4.84l-1.8-1.79-1.41 1.41 1.79 1.8 1.42-1.42zM1 13h3v-2H1v2zm10-9h2V1h-2v3zm7.45 1.46l1.79-1.8-1.41-1.41-1.8 1.79 1.42 1.42zM17.24 19.16l1.8 1.79 1.41-1.41-1.79-1.8-1.42 1.42zM20 11v2h3v-2h-3zM11 20h2v3h-2v-3zm-7.45-2.54l-1.79 1.8 1.41 1.41 1.8-1.79-1.42-1.42zM12 6a6 6 0 100 12 6 6 0 000-12z"/></svg>',
    modeClass: 'mode-light',
    detail: '<b>轻度模式</b><br><br><b>cpuset</b>: top-app → cpu4-7，background → cpu0-3<br><b>response_time</b>: 小核 200ms / 中核 20ms / 大核 16ms<br><br>和“平衡模式”一样保留核心分配，但中大核升频更保守，更适合阅读、社交和轻度视频场景。'
  },
  battery: {
    name: '省电模式',
    summary: '更保守的升频策略，适合低发热和续航优先场景。',
    desc: '前台: cpu4-7 · 小核锁 820MHz · 中核 40ms · 大核 30ms',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M15.67 4H14V2h-4v2H8.33C7.6 4 7 4.6 7 5.33v15.33C7 21.4 7.6 22 8.33 22h7.33c.74 0 1.34-.6 1.34-1.33V5.33C17 4.6 16.4 4 15.67 4zM11 19v-2H9l3-5 3 5h-2v2h-2z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M15.67 4H14V2h-4v2H8.33C7.6 4 7 4.6 7 5.33v15.33C7 21.4 7.6 22 8.33 22h7.33c.74 0 1.34-.6 1.34-1.33V5.33C17 4.6 16.4 4 15.67 4zM11 19v-2H9l3-5 3 5h-2v2h-2z"/></svg>',
    modeClass: 'mode-battery',
    detail: '<b>省电模式</b><br><br><b>cpuset</b>: top-app → cpu4-7，background → cpu0-3<br><b>response_time</b>: 小核 500ms / 中核 40ms / 大核 30ms<br><br>整体调度最保守，小核几乎维持最低频，中大核升频更慢，适合低发热和续航优先场景。'
  },
  stock: {
    name: '默认模式',
    summary: '恢复系统默认 cpuset 与 sched_pixel 响应参数。',
    desc: '恢复系统默认 cpuset 与调度参数',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M13 3C8.03 3 4 7.03 4 12H1l4 4 4-4H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.95-2.05l-1.41 1.41A8.96 8.96 0 0013 21c4.97 0 9-4.03 9-9s-4.03-9-9-9zm-1 5v5l4.25 2.52.77-1.28-3.52-2.09V8H12z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M13 3C8.03 3 4 7.03 4 12H1l4 4 4-4H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.95-2.05l-1.41 1.41A8.96 8.96 0 0013 21c4.97 0 9-4.03 9-9s-4.03-9-9-9zm-1 5v5l4.25 2.52.77-1.28-3.52-2.09V8H12z"/></svg>',
    modeClass: 'mode-stock',
    detail: '<b>默认模式</b><br><br><b>cpuset</b>: top-app → cpu0-7，foreground → cpu0-6<br><b>response_time</b>: 小核 16ms / 中核 64ms / 大核 200ms<br><br>恢复 Pixel 系统默认 sched_pixel 参数，让 Android 调度器按照出厂策略自主管理。'
  },
  unknown: {
    name: '未选择',
    summary: '前往“性能”页选择调度模式。',
    desc: '前往“性能”页选择调度模式',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M11 18h2v-2h-2v2zm1-16C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm0-14c-2.21 0-4 1.79-4 4h2c0-1.1.9-2 2-2s2 .9 2 2c0 2-3 1.75-3 5h2c0-2.25 3-2.5 3-5 0-2.21-1.79-4-4-4z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M11 18h2v-2h-2v2zm1-16C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm0-14c-2.21 0-4 1.79-4 4h2c0-1.1.9-2 2-2s2 .9 2 2c0 2-3 1.75-3 5h2c0-2.25 3-2.5 3-5 0-2.21-1.79-4-4-4z"/></svg>',
    modeClass: 'mode-unknown',
    detail: '当前还没有读取到有效模式，请稍后刷新或到“性能”页重新选择。'
  }
};

const THERMAL_PRESETS = {
  0: {
    name: '默认节流',
    summary: '恢复出厂 39°C 阈值。',
    detail: '<b>默认节流</b><br><br><b>VIRTUAL-SKIN 39°C</b> 开始节流。维持 Google 出厂阈值，保守但更容易在日常高温边缘频繁进出限频。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M13 3C8.03 3 4 7.03 4 12H1l4 4 4-4H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.95-2.05l-1.41 1.41A8.96 8.96 0 0013 21c4.97 0 9-4.03 9-9s-4.03-9-9-9z"/></svg>'
  },
  2: {
    name: '轻度节流',
    summary: 'VIRTUAL-SKIN 41°C 开始节流。',
    detail: '<b>轻度节流</b><br><br>在默认基础上整体上移 <b>+2°C</b>。适合减少日常温度波动区间的误触发，同时保留较明显的安全冗余。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M15 13.18V7c0-1.66-1.34-3-3-3S9 5.34 9 7v6.18C7.79 13.86 7 15.18 7 16.71 7 18.97 8.86 20.81 11.12 21H12c2.21 0 4-1.79 4-4 0-1.53-.79-2.85-2-3.82z"/></svg>'
  },
  4: {
    name: '常规节流',
    summary: '模块默认档位，VIRTUAL-SKIN 43°C 开始节流。',
    detail: '<b>常规节流（模块默认）</b><br><br>在默认基础上整体上移 <b>+4°C</b>，VIRTUAL-SKIN 43°C 才开始介入。兼顾性能释放与日常可控温度，是模块默认建议值。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M13.5.67s.74 2.65.74 4.8c0 2.06-1.35 3.73-3.41 3.73-2.07 0-3.63-1.67-3.63-3.73l.03-.36C5.21 7.51 4 10.62 4 14c0 4.42 3.58 8 8 8s8-3.58 8-8C20 8.61 17.41 3.8 13.5.67z"/></svg>'
  },
  6: {
    name: '激进节流',
    summary: 'VIRTUAL-SKIN 45°C 开始节流。',
    detail: '<b>激进节流</b><br><br>在默认基础上整体上移 <b>+6°C</b>，显著延迟限频介入。适合高负载短时冲刺，但机身体感温度会上升得更快。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z"/></svg>'
  }
};

const SWAP_DETAIL = '<b>ZRAM 算法: lz77eh (Emerald Hill 硬件加速)</b><br>Tensor G4 内置固定功能压缩引擎，压缩和解压由专用硬件完成，CPU 几乎不参与，适合高频换页场景。<br><br><b>ZRAM 大小: 11392MB (75% RAM)</b><br>原厂默认约为 50% RAM。模块将容量扩容到 11392MB，让更多后台匿名页驻留在 ZRAM 中。<br><br><b>swappiness: 100</b><br>降低匿名页被过度换出的激进程度，减少无效 swap-in / swap-out。<br><br><b>min_free_kbytes: 65536</b><br>提前唤醒 kswapd，减少 direct reclaim 带来的主线程阻塞。<br><br><b>vfs_cache_pressure: 60</b><br>保留更多 inode / dentry 缓存，有利于文件路径查询与应用启动。';

const ZONE_LABELS = {
  'VIRTUAL-SKIN': '机身温度',
  'SKIN': '机身温度',
  'soc_therm': 'CPU / SoC',
  'battery': '电池温度',
  'charging_therm': '充电 IC',
  'btmspkr_therm': '底部扬声器'
};

const OPT_ITEMS = [
  { key: 'mobile_data_always_on', label: '移动数据常开', hint: '避免蜂窝与 WiFi 双链路同时常驻待机。', good: '0' },
  { key: 'wfc_ims_enabled', label: 'VoWiFi 通话', hint: '减少 IWLAN 搜网与 IMS 常驻唤醒。', good: '0' },
  { key: 'wifi_scan_always_enabled', label: 'WiFi 后台扫描', hint: '避免熄屏后继续进行环境 WiFi 扫描。', good: '0' },
  { key: 'ble_scan_always_enabled', label: 'BLE 后台扫描', hint: '降低蓝牙扫描与附近设备发现频率。', good: '0' },
  { key: 'adaptive_connectivity', label: '自适应连接', hint: '减少蜂窝 / WiFi 自动切换判断。', good: '0' },
  { key: 'network_recommendations', label: '网络推荐', hint: '关闭后台网络评分和推荐广播。', good: '0' },
  { key: 'nearby_sharing', label: '附近共享', hint: '降低 Nearby Sharing 的持续扫描开销。', good: '0' },
  { key: 'multicast', label: 'WiFi Multicast', hint: '息屏时关闭组播，减少 WLAN 唤醒。', good: 'off' }
];

const refs = {};
const state = {
  currentTab: 'home',
  currentProfile: 'unknown',
  currentOffset: 4,
  swapMode: 'unknown',
  themeMode: 'system',
  webuiToken: '',
  cpuBusy: false,
  thermalBusy: false,
  swapBusy: false,
  swapLoading: false,
  optLoading: false,
  cpuRows: null,
  homeCpuRows: null,
  sensorRefs: null,
  homeSensorRefs: null,
  timers: { cpu: null, thermal: null, swap: null },
  lastClusters: null,
  pull: { y0: 0, active: false, dist: 0, busy: false },
  thermalModal: { pending: 4, prev: 4 }
};

function $(id){ return document.getElementById(id); }

function initRefs() {
  refs.topbarSubtitle = $('topbar-subtitle');
  refs.topbarProfileChip = $('topbar-profile-chip');
  refs.topbarThermalChip = $('topbar-thermal-chip');
  refs.topbarThemeChip = $('topbar-theme-chip');
  refs.themeBtnIcon = $('theme-btn-icon');
  refs.hero = $('hero');
  refs.heroIcon = $('hero-icon');
  refs.heroMode = $('hero-mode');
  refs.heroDesc = $('hero-desc');
  refs.homeModBadge = $('home-mod-badge');
  refs.homeTempNum = $('home-temp-num');
  refs.homeTempStatus = $('home-temp-status');
  refs.homeSensorList = $('home-sensor-list');
  refs.homeThermalSkel = $('home-thermal-skel');
  refs.homeThermalContent = $('home-thermal-content');
  refs.homeCpuRows = $('home-cpu-rows');
  refs.rtZramUsage = $('rt-zram-usage');
  refs.rtRatio = $('rt-ratio');
  refs.rtWebuiMem = $('rt-webui-mem');
  refs.rtPower = $('rt-power');
  refs.homePowerBadge = $('home-power-badge');
  refs.infoModel = $('info-model');
  refs.infoAndroid = $('info-android');
  refs.infoModule = $('info-module');
  refs.logCard = $('log-card');
  refs.logInner = $('log-inner');
  refs.perfCurrentName = $('perf-current-name');
  refs.perfCurrentDesc = $('perf-current-desc');
  refs.cpuRows = $('cpu-rows');
  refs.profileList = $('profile-list');
  refs.refreshBtn = $('refresh-cpu-btn');
  refs.thermalCurrentName = $('thermal-current-name');
  refs.thermalCurrentDesc = $('thermal-current-desc');
  refs.thModBadge = $('th-mod-badge');
  refs.thermalSkel = $('thermal-skel');
  refs.thermalContent = $('thermal-content');
  refs.tempNum = $('temp-num');
  refs.tempZone = $('temp-zone');
  refs.tempStatus = $('temp-status');
  refs.tempFill = $('temp-fill');
  refs.sensorGrid = $('sensor-grid');
  refs.thermalList = $('thermal-list');
  refs.mkStock = $('mk-stock');
  refs.mkStockLbl = $('mk-stock-lbl');
  refs.mkMod = $('mk-mod');
  refs.mkModLbl = $('mk-mod-lbl');
  refs.appearanceModeLabel = $('appearance-mode-label');
  refs.appearanceModeDesc = $('appearance-mode-desc');
  refs.swapDesc = $('swap-desc');
  refs.swapToggleLabel = $('swap-toggle-label');
  refs.swapRows = $('swap-rows');
  refs.optRows = $('opt-rows');
  refs.optRefreshLabel = $('opt-refresh-label');
  refs.themeModal = $('modal-theme');
  refs.themeChoices = Array.from(document.querySelectorAll('[data-theme-option]'));
  refs.rebootModal = $('modal-reboot');
  refs.detailModal = $('modal-detail');
  refs.detailTitle = $('detail-title');
  refs.detailBody = $('detail-body');
  refs.toastWrap = $('toast-wrap');
  refs.pullInd = $('pull-ind');
  refs.pullArc = refs.pullInd.querySelector('.pull-arc');
  refs.tabPages = $('tab-pages');
}

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
  const resolved = getResolvedTheme(state.themeMode);
  document.documentElement.dataset.theme = resolved;
  document.querySelector('meta[name="theme-color"]').setAttribute('content', resolved === 'dark' ? '#111714' : '#eef4f0');
  refs.themeBtnIcon.innerHTML = THEME_ICONS[state.themeMode] || THEME_ICONS.system;
  refs.topbarThemeChip.textContent = getThemeLabel(state.themeMode);
  refs.appearanceModeLabel.textContent = getThemeLabel(state.themeMode);
  refs.appearanceModeDesc.textContent = state.themeMode === 'system'
    ? '按系统或 WebView 当前配色自动切换。'
    : state.themeMode === 'dark'
      ? '已固定为深色模式，适合夜间和低照度环境。'
      : '已固定为浅色模式，适合白天和强光环境。';
  refs.themeChoices.forEach((choice) => {
    choice.classList.toggle('selected', choice.dataset.themeOption === state.themeMode);
  });
}

function applyTheme(mode, persist = true) {
  state.themeMode = mode;
  if (persist) localStorage.setItem(STORAGE_THEME_KEY, mode);
  syncThemeUi();
}

function initTheme() {
  applyTheme(localStorage.getItem(STORAGE_THEME_KEY) || 'system', false);
  const mq = window.matchMedia('(prefers-color-scheme: dark)');
  const handle = () => { if (state.themeMode === 'system') syncThemeUi(); };
  if (mq.addEventListener) mq.addEventListener('change', handle);
  else mq.addListener(handle);
}

function openThemeSheet(){ refs.themeModal.classList.add('open'); }
function closeThemeSheet(){ refs.themeModal.classList.remove('open'); }

function openRebootModal(pending, prev) {
  state.thermalModal.pending = pending;
  state.thermalModal.prev = prev;
  refs.rebootModal.classList.add('open');
}

function closeRebootModal() {
  refs.rebootModal.classList.remove('open');
  showToast('已保存，重启手机后生效');
}

function openDetail(title, html) {
  refs.detailTitle.textContent = title;
  refs.detailBody.innerHTML = html;
  refs.detailModal.classList.add('open');
}

function closeDetailModal(){ refs.detailModal.classList.remove('open'); }

function showToast(msg, dur = 2500) {
  const el = document.createElement('div');
  el.className = 'toast';
  el.textContent = msg;
  refs.toastWrap.appendChild(el);
  window.setTimeout(() => {
    el.classList.add('out');
    el.addEventListener('animationend', () => el.remove(), { once: true });
    window.setTimeout(() => { if (el.isConnected) el.remove(); }, 400);
  }, dur);
}

function appendLog(text, type = '') {
  if (refs.logInner.querySelector('.log-dim:only-child')) refs.logInner.innerHTML = '';
  const row = document.createElement('div');
  if (type) row.className = `log-${type}`;
  row.textContent = `[${new Date().toLocaleTimeString()}] ${text}`;
  refs.logInner.appendChild(row);
  while (refs.logInner.childNodes.length > 30) refs.logInner.removeChild(refs.logInner.firstChild);
  refs.logInner.scrollTop = refs.logInner.scrollHeight;
}

async function apiFetch(path, opts = {}) {
  const controller = new AbortController();
  const timeoutMs = opts.timeoutMs || 8000;
  const timeoutId = window.setTimeout(() => controller.abort(), timeoutMs);
  const headers = { ...(opts.headers || {}) };
  if (state.webuiToken) headers['X-PIXEL9PRO-TOKEN'] = state.webuiToken;
  const request = { cache: 'no-store', ...opts, headers, signal: controller.signal };
  delete request.timeoutMs;
  let response;
  try {
    response = await fetch(path, request);
  } catch (err) {
    if (err && err.name === 'AbortError') throw new Error('request timeout');
    throw err;
  } finally {
    clearTimeout(timeoutId);
  }
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

function switchTab(tab) {
  if (tab === state.currentTab) return;
  state.currentTab = tab;
  document.querySelectorAll('.tab-page').forEach((page) => page.classList.toggle('active', page.dataset.tab === tab));
  document.querySelectorAll('.tab-item').forEach((item) => item.classList.toggle('active', item.dataset.tab === tab));
  refs.topbarSubtitle.textContent = TAB_META[tab] || '控制台';
}

function getSwipeTargetTab(deltaX, deltaY) {
  const absX = Math.abs(deltaX);
  const absY = Math.abs(deltaY);
  if (absX < 60 || absX <= absY * 1.5) return '';
  const nextIndex = TAB_ORDER.indexOf(state.currentTab) + (deltaX < 0 ? 1 : -1);
  if (nextIndex < 0 || nextIndex >= TAB_ORDER.length) return '';
  return TAB_ORDER[nextIndex];
}

function bindTabSwipe() {
  let gesture = null;
  const findTouch = (list, id) => {
    for (let i = 0; i < list.length; i += 1) if (list[i].identifier === id) return list[i];
    return null;
  };
  refs.tabPages.addEventListener('touchstart', (evt) => {
    if (evt.touches.length !== 1) return;
    if (document.querySelector('.modal-wrap.open')) return;
    const page = evt.target.closest('.tab-page');
    if (!page || !page.classList.contains('active')) return;
    const touch = evt.touches[0];
    gesture = { id: touch.identifier, startX: touch.clientX, startY: touch.clientY, lastX: touch.clientX, lastY: touch.clientY, horizontal: null };
  }, { passive: true });
  refs.tabPages.addEventListener('touchmove', (evt) => {
    if (!gesture) return;
    const touch = findTouch(evt.touches, gesture.id) || findTouch(evt.changedTouches, gesture.id);
    if (!touch) return;
    gesture.lastX = touch.clientX;
    gesture.lastY = touch.clientY;
    const deltaX = touch.clientX - gesture.startX;
    const deltaY = touch.clientY - gesture.startY;
    if (gesture.horizontal === null) {
      if (Math.abs(deltaX) < 12 && Math.abs(deltaY) < 12) return;
      gesture.horizontal = Math.abs(deltaX) > Math.abs(deltaY) * 1.15;
    }
    if (gesture.horizontal && evt.cancelable) evt.preventDefault();
  }, { passive: false });
  const finish = () => {
    if (!gesture) return;
    const target = getSwipeTargetTab(gesture.lastX - gesture.startX, gesture.lastY - gesture.startY);
    gesture = null;
    if (target) switchTab(target);
  };
  refs.tabPages.addEventListener('touchend', finish, { passive: true });
  refs.tabPages.addEventListener('touchcancel', () => { gesture = null; }, { passive: true });
}

function bindPullToRefresh() {
  const hide = () => {
    refs.pullInd.style.transform = 'translateX(-50%) translateY(-52px)';
    refs.pullInd.classList.remove('active', 'spinning');
    refs.pullArc.style.strokeDashoffset = PULL_CIRC;
  };
  const show = (y) => {
    refs.pullInd.style.transform = `translateX(-50%) translateY(${Math.min(y * 0.4, 16)}px)`;
  };
  const setArc = (p) => {
    refs.pullArc.style.strokeDashoffset = PULL_CIRC * (1 - p * 0.85);
  };

  document.querySelectorAll('.tab-page').forEach((page) => {
    page.addEventListener('touchstart', (evt) => {
      if (state.pull.busy || evt.touches.length !== 1) return;
      if (page.scrollTop <= 0) {
        state.pull.y0 = evt.touches[0].clientY;
        state.pull.active = true;
        state.pull.dist = 0;
      }
    }, { passive: true });
    page.addEventListener('touchmove', (evt) => {
      if (!state.pull.active) return;
      const dy = evt.touches[0].clientY - state.pull.y0;
      if (page.scrollTop > 0) {
        state.pull.active = false;
        hide();
        return;
      }
      if (dy > 0) {
        state.pull.dist = dy;
        refs.pullInd.classList.add('active');
        show(dy);
        setArc(Math.min(dy / 90, 1));
        if (evt.cancelable) evt.preventDefault();
      } else {
        state.pull.active = false;
        hide();
      }
    }, { passive: false });
    page.addEventListener('touchend', async () => {
      if (!state.pull.active) return;
      state.pull.active = false;
      if (state.pull.dist > 90 && !state.pull.busy) {
        state.pull.busy = true;
        refs.pullInd.classList.add('spinning');
        setArc(1);
        show(40);
        await doFullRefresh();
        state.pull.busy = false;
      }
      hide();
    }, { passive: true });
  });
}

function tempHex(t) {
  if (t < 36) return '#23a78c';
  if (t < 40) return '#4aa95f';
  if (t < 44) return '#bf8b16';
  if (t < 48) return '#d97c34';
  return '#c3472d';
}

function tempStatus(t) {
  if (t < 36) return '凉爽';
  if (t < 39) return '正常';
  if (t < 43) return '已超出原始阈值，延迟节流策略生效中';
  if (t < 47) return '系统已开始限频降温';
  if (t < 50) return '持续高温，深度节流中';
  return '设备过热，严重节流';
}

function barPct(t) {
  return Math.min(Math.max((t - TEMP_MIN) / (TEMP_MAX - TEMP_MIN), 0), 1) * 100;
}

function positionMarkers() {
  const stockPct = barPct(THRESH_STOCK);
  const modPct = barPct(THRESH_MOD);
  refs.mkStock.style.left = `${stockPct}%`;
  refs.mkStockLbl.style.left = `${stockPct}%`;
  refs.mkMod.style.left = `${modPct}%`;
  refs.mkModLbl.style.left = `${modPct}%`;
}

function syncProfileUi() {
  const profile = PROFILES[state.currentProfile] || PROFILES.unknown;
  refs.topbarProfileChip.textContent = profile.name;
  refs.perfCurrentName.textContent = profile.name;
  refs.perfCurrentDesc.textContent = profile.desc;
  refs.hero.className = `hero-card ${profile.modeClass}`;
  refs.heroIcon.innerHTML = profile.hero;
  refs.heroMode.textContent = profile.name;
}

function syncHeroDesc() {
  const parts = [];
  const preset = THERMAL_PRESETS[state.currentOffset];
  if (preset) parts.push(preset.name);
  if (state.swapMode === 'optimized') parts.push('VM 已优化');
  else if (state.swapMode === 'stock') parts.push('VM 默认');
  refs.heroDesc.textContent = parts.join(' · ') || '读取中…';
}

function syncThermalUi() {
  const preset = THERMAL_PRESETS[state.currentOffset] || THERMAL_PRESETS[4];
  refs.topbarThermalChip.textContent = state.currentOffset === 0 ? '默认节流' : `温控 ${preset.name}`;
  refs.thermalCurrentName.textContent = preset.name;
  refs.thermalCurrentDesc.textContent = preset.summary;
  const label = state.currentOffset === 0 ? '默认节流' : `+${state.currentOffset}°C 激活`;
  [refs.homeModBadge, refs.thModBadge].forEach((el) => {
    el.textContent = label;
    el.className = `badge ${state.currentOffset === 0 ? 'off' : 'default'}`;
  });
  document.querySelectorAll('.thermal-option').forEach((card) => {
    card.classList.toggle('selected', Number(card.dataset.offset) === state.currentOffset);
  });
}

function renderProfileCards() {
  refs.profileList.innerHTML = '';
  ['game', 'balanced', 'light', 'battery', 'stock'].forEach((key) => {
    const p = PROFILES[key];
    const card = document.createElement('article');
    card.className = 'profile-card profile-option';
    card.dataset.profile = key;
    card.tabIndex = 0;
    card.innerHTML = `
      <div class="profile-icon" aria-hidden="true">${p.icon}</div>
      <div class="profile-copy">
        <div class="profile-name">${p.name}</div>
        <div class="profile-desc">${p.summary}</div>
      </div>
      <div class="profile-actions">
        <button class="card-info" type="button" data-action="profile-detail" data-profile="${key}" aria-label="查看${p.name}详情">
          <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor"><path d="M11 17h2v-6h-2v6zm0-8h2V7h-2v2zm1-7C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2z"/></svg>
        </button>
        <div class="p-check" aria-hidden="true"><svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg></div>
      </div>`;
    card.addEventListener('click', (evt) => {
      if (evt.target.closest('[data-action="profile-detail"]')) return;
      applyProfile(key);
    });
    card.addEventListener('keydown', (evt) => {
      if (evt.key === 'Enter' || evt.key === ' ') {
        evt.preventDefault();
        applyProfile(key);
      }
    });
    refs.profileList.appendChild(card);
  });
}

function renderThermalCards() {
  refs.thermalList.innerHTML = '';
  [0, 2, 4, 6].forEach((offset) => {
    const preset = THERMAL_PRESETS[offset];
    const card = document.createElement('article');
    card.className = 'profile-card thermal-option';
    card.dataset.offset = String(offset);
    card.tabIndex = 0;
    card.innerHTML = `
      <div class="profile-icon" aria-hidden="true">${preset.icon}</div>
      <div class="profile-copy">
        <div class="profile-name">${preset.name}</div>
        <div class="profile-desc">${preset.summary}</div>
      </div>
      <div class="profile-actions">
        <button class="card-info" type="button" data-action="thermal-detail" data-offset="${offset}" aria-label="查看${preset.name}详情">
          <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor"><path d="M11 17h2v-6h-2v6zm0-8h2V7h-2v2zm1-7C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2z"/></svg>
        </button>
        <div class="p-check" aria-hidden="true"><svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg></div>
      </div>`;
    card.addEventListener('click', (evt) => {
      if (evt.target.closest('[data-action="thermal-detail"]')) return;
      applyThermal(offset);
    });
    card.addEventListener('keydown', (evt) => {
      if (evt.key === 'Enter' || evt.key === ' ') {
        evt.preventDefault();
        applyThermal(offset);
      }
    });
    refs.thermalList.appendChild(card);
  });
}

function buildInfoRow(label, value, badgeClass = '') {
  const row = document.createElement('div');
  row.className = 'data-row';
  const key = document.createElement('span');
  key.className = 'data-key';
  key.textContent = label;
  const val = document.createElement('span');
  val.className = badgeClass ? `badge ${badgeClass}` : 'data-val';
  val.textContent = value;
  row.appendChild(key);
  row.appendChild(val);
  return row;
}

function fmtBytes(bytes) {
  const value = Number(bytes);
  if (value <= 0) return '0';
  if (value < 1048576) return `${(value / 1024).toFixed(0)}KB`;
  if (value < 1073741824) return `${(value / 1048576).toFixed(0)}MB`;
  return `${(value / 1073741824).toFixed(2)}GB`;
}

function renderSwapCard(data) {
  refs.swapRows.innerHTML = '';
  const ratio = data.zram_orig_bytes > 0 ? ((data.zram_compr_bytes / data.zram_orig_bytes) * 100).toFixed(1) : '—';
  const isEH = data.zram_algo === 'lz77eh';
  const sizeGB = (data.zram_disksize / 1073741824).toFixed(1);
  refs.swapDesc.textContent = isEH
    ? `Emerald Hill 硬件压缩 · 压缩率 ${ratio}% · 实占 ${fmtBytes(data.zram_mem_used_bytes)}`
    : `算法 ${data.zram_algo} · 重启后自动切换为 lz77eh`;
  const rows = [
    { label: 'ZRAM 算法', value: isEH ? '硬件加速' : data.zram_algo, cls: isEH ? 'good' : 'warn' },
    { label: 'ZRAM 大小', value: `${sizeGB}GB`, cls: Math.abs(data.zram_disksize - 11945377792) < 536870912 ? 'good' : 'off' },
    { label: 'swappiness', value: String(data.swappiness), cls: data.swappiness === 100 ? 'good' : data.swappiness === 150 ? 'warn' : 'off' },
    { label: 'min_free_kbytes', value: String(data.min_free_kbytes), cls: data.min_free_kbytes === 65536 ? 'good' : data.min_free_kbytes === 27386 ? 'warn' : 'off' },
    { label: 'vfs_cache_pressure', value: String(data.vfs_cache_pressure), cls: data.vfs_cache_pressure === 60 ? 'good' : data.vfs_cache_pressure === 100 ? 'warn' : 'off' }
  ];
  rows.forEach((row) => refs.swapRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
}

function renderOptimizeRows(data) {
  refs.optRows.innerHTML = '';
  OPT_ITEMS.forEach((item) => {
    const value = data[item.key] || 'null';
    const stateSpec = value === item.good
      ? { cls: 'good', text: '已关闭' }
      : (value === '1' || value === 'on')
        ? { cls: 'warn', text: '已开启' }
        : { cls: 'off', text: '未设置' };
    const row = document.createElement('div');
    row.className = 'opt-item';
    row.innerHTML = `
      <div class="opt-item-head">
        <div class="opt-label">${item.label}</div>
        <span class="badge ${stateSpec.cls}">${stateSpec.text}</span>
      </div>
      <div class="opt-meta">${item.hint}</div>`;
    refs.optRows.appendChild(row);
  });
  const goodCount = OPT_ITEMS.filter((item) => data[item.key] === item.good).length;
  refs.rtPower.textContent = `${goodCount}/${OPT_ITEMS.length} 项已优化`;
  refs.homePowerBadge.textContent = `${goodCount}/${OPT_ITEMS.length}`;
  refs.homePowerBadge.className = `badge ${goodCount === OPT_ITEMS.length ? 'good' : 'off'}`;
}

function ensureHomeCpuRows(clusters) {
  if (state.homeCpuRows && state.homeCpuRows.length === clusters.length) return;
  refs.homeCpuRows.innerHTML = '';
  state.homeCpuRows = clusters.map((cluster, index) => {
    const row = document.createElement('div');
    row.className = 'home-cpu-row';
    const label = document.createElement('span');
    label.className = 'home-cpu-label';
    label.textContent = HOME_CPU_LABELS[index] || `C${index}`;
    const bar = document.createElement('div');
    bar.className = 'home-cpu-bar';
    const fill = document.createElement('div');
    fill.className = 'home-cpu-fill';
    bar.appendChild(fill);
    const freq = document.createElement('span');
    freq.className = 'home-cpu-freq';
    row.append(label, bar, freq);
    refs.homeCpuRows.appendChild(row);
    return { fill, freq, maxHz: CLUSTERS[index]?.maxHz || 3105000 };
  });
}

function ensurePerfCpuRows(clusters) {
  if (state.cpuRows && state.cpuRows.length === clusters.length) return;
  refs.cpuRows.innerHTML = '';
  state.cpuRows = clusters.map((cluster, index) => {
    const row = document.createElement('div');
    row.className = 'cpu-row';
    const head = document.createElement('div');
    head.className = 'cpu-row-head';
    const label = document.createElement('span');
    label.className = 'cpu-label';
    label.textContent = CLUSTERS[index]?.label || `cpu${cluster.cpu}`;
    const freq = document.createElement('span');
    freq.className = 'cpu-freq';
    const current = document.createElement('b');
    const max = document.createElement('span');
    freq.append(current, max);
    head.append(label, freq);
    const track = document.createElement('div');
    track.className = 'cpu-bar-track';
    const fill = document.createElement('div');
    fill.className = 'cpu-bar-fill';
    track.appendChild(fill);
    const params = document.createElement('div');
    params.className = 'cpu-params';
    row.append(head, track, params);
    refs.cpuRows.appendChild(row);
    return { current, max, fill, params, maxHz: CLUSTERS[index]?.maxHz || 3105000 };
  });
}

function ensureSensorRefs(container, key, zones, className) {
  const signature = zones.map((zone) => zone.zone).join(',');
  if (state[key] && state[key].map((entry) => entry.zone).join(',') === signature) return state[key];
  container.innerHTML = '';
  state[key] = zones.map((zone) => {
    const node = document.createElement('div');
    node.className = className;
    let label;
    let value;
    if (className === 'sensor-chip') {
      label = document.createElement('span');
      label.className = 'sensor-chip-label';
      value = document.createElement('span');
      value.className = 'sensor-chip-value';
    } else {
      label = document.createElement('span');
      value = document.createElement('span');
    }
    label.textContent = ZONE_LABELS[zone.zone] || zone.zone;
    node.append(label, value);
    container.appendChild(node);
    return { zone: zone.zone, value };
  });
  return state[key];
}

async function loadInfo() {
  try {
    const data = await apiFetch(API.info);
    refs.infoModel.textContent = data.model || 'Pixel 9 Pro';
    refs.infoAndroid.textContent = data.version ? `Android ${data.version}` : '—';
    refs.infoModule.textContent = data.module_version || '—';
    refs.rtWebuiMem.textContent = data.httpd_rss_kb
      ? data.httpd_rss_kb < 1024 ? `${data.httpd_rss_kb}KB` : `${(data.httpd_rss_kb / 1024).toFixed(1)}MB`
      : '—';
    if (data.webui_token) state.webuiToken = data.webui_token;
    const vc = data.version_code || '';
    if (vc && localStorage.getItem('_modVC') !== vc) {
      localStorage.setItem('_modVC', vc);
      if (!sessionStorage.getItem('_reloaded')) {
        sessionStorage.setItem('_reloaded', '1');
        location.reload();
        return;
      }
    }
    sessionStorage.removeItem('_reloaded');
  } catch (_) {}
}

async function loadSavedProfile() {
  try {
    const data = await apiFetch(API.profile);
    state.currentProfile = PROFILES[data.profile] ? data.profile : 'unknown';
  } catch (_) {
    state.currentProfile = 'unknown';
  }
  syncProfileUi();
  syncHeroDesc();
  document.querySelectorAll('.profile-option').forEach((card) => card.classList.toggle('selected', card.dataset.profile === state.currentProfile));
}

async function loadThermalPreset() {
  try {
    const data = await apiFetch(API.thermalSet);
    state.currentOffset = [0, 2, 4, 6].includes(data.offset) ? data.offset : 4;
  } catch (_) {
    state.currentOffset = 4;
  }
  syncThermalUi();
  syncHeroDesc();
}

async function refreshCpu() {
  if (state.cpuBusy) return;
  state.cpuBusy = true;
  refs.refreshBtn.disabled = true;
  try {
    const clusters = await apiFetch(API.status, { timeoutMs: 6000 });
    state.lastClusters = clusters;
    ensurePerfCpuRows(clusters);
    ensureHomeCpuRows(clusters);
    clusters.forEach((cluster, index) => {
      const perf = state.cpuRows[index];
      const home = state.homeCpuRows[index];
      const maxHz = cluster.max > 0 ? cluster.max : perf.maxHz;
      perf.current.textContent = !cluster.cur || Number.isNaN(cluster.cur) ? '—' : `${(cluster.cur / 1000).toFixed(0)} MHz`;
      perf.max.textContent = ` / ${(maxHz / 1000).toFixed(0)} MHz`;
      perf.fill.style.transform = `scaleX(${Math.min(cluster.cur / maxHz, 1).toFixed(3)})`;
      perf.params.textContent = `resp=${cluster.resp_ms}ms · down=${cluster.down_us}µs · gov=${cluster.gov}`;
      home.freq.textContent = !cluster.cur || Number.isNaN(cluster.cur) ? '—' : `${(cluster.cur / 1000).toFixed(0)} MHz`;
      home.fill.style.transform = `scaleX(${!cluster.cur ? 0 : Math.min(cluster.cur / maxHz, 1).toFixed(3)})`;
    });
  } catch (err) {
    refs.cpuRows.innerHTML = `<div class="note-body" style="color:var(--danger)">获取频率失败：${err.message}</div>`;
  } finally {
    refs.refreshBtn.disabled = false;
    state.cpuBusy = false;
  }
}

async function refreshThermal() {
  if (state.thermalBusy) return;
  state.thermalBusy = true;
  try {
    const zones = await apiFetch(API.thermal, { timeoutMs: 6000 });
    if (!zones || !zones.length) throw new Error('未读取到热区数据');
    const skin = zones.find((zone) => zone.zone === 'VIRTUAL-SKIN') || zones.find((zone) => zone.zone === 'SKIN');
    const secondary = zones.filter((zone) => zone !== skin && ['soc_therm', 'battery', 'charging_therm', 'btmspkr_therm'].includes(zone.zone));
    refs.homeThermalSkel.hidden = true;
    refs.homeThermalContent.hidden = false;
    refs.thermalSkel.hidden = true;
    refs.thermalContent.hidden = false;
    if (skin) {
      const tempC = skin.temp / 1000;
      const color = tempHex(tempC);
      refs.homeTempNum.textContent = tempC.toFixed(1);
      refs.homeTempNum.style.color = color;
      refs.homeTempStatus.textContent = tempStatus(tempC);
      refs.homeTempStatus.style.color = color;
      refs.tempNum.textContent = tempC.toFixed(1);
      refs.tempNum.style.color = color;
      refs.tempNum.style.textShadow = `0 0 24px ${color}55`;
      refs.tempZone.textContent = ZONE_LABELS[skin.zone] || skin.zone;
      refs.tempStatus.textContent = tempStatus(tempC);
      refs.tempStatus.style.color = color;
      refs.tempFill.style.width = `${barPct(tempC)}%`;
      refs.tempFill.style.background = `linear-gradient(90deg,${color}88,${color})`;
    } else {
      refs.homeTempNum.textContent = '--';
      refs.homeTempStatus.textContent = 'VIRTUAL-SKIN 未找到';
      refs.tempNum.textContent = '--';
      refs.tempZone.textContent = 'VIRTUAL-SKIN';
      refs.tempStatus.textContent = '未找到热区，请确认已注册';
    }
    const homeRefs = ensureSensorRefs(refs.homeSensorList, 'homeSensorRefs', secondary, 'sensor-row');
    const gridRefs = ensureSensorRefs(refs.sensorGrid, 'sensorRefs', secondary, 'sensor-chip');
    secondary.forEach((zone, index) => {
      const tempC = zone.temp / 1000;
      const color = tempHex(tempC);
      homeRefs[index].value.textContent = `${tempC.toFixed(1)}°C`;
      homeRefs[index].value.style.color = color;
      gridRefs[index].value.textContent = `${tempC.toFixed(1)}°C`;
      gridRefs[index].value.style.color = color;
    });
  } catch (err) {
    refs.homeThermalSkel.hidden = true;
    refs.homeThermalContent.hidden = false;
    refs.thermalSkel.hidden = true;
    refs.thermalContent.hidden = false;
    refs.homeTempNum.textContent = '--';
    refs.homeTempStatus.textContent = err.message;
    refs.tempNum.textContent = '--';
    refs.tempStatus.textContent = err.message;
  } finally {
    state.thermalBusy = false;
  }
}

async function refreshSwap() {
  if (state.swapLoading) return;
  state.swapLoading = true;
  try {
    const data = await apiFetch(API.swap, { timeoutMs: 6000 });
    state.swapMode = data.mode || 'custom';
    refs.swapToggleLabel.textContent = state.swapMode === 'optimized' ? '恢复默认' : '应用优化';
    renderSwapCard(data);
    refs.rtZramUsage.textContent = `${data.zram_disksize > 0 ? ((data.zram_orig_bytes / data.zram_disksize) * 100).toFixed(0) : '0'}% (${fmtBytes(data.zram_orig_bytes)} / ${(data.zram_disksize / 1073741824).toFixed(1)}GB)`;
    refs.rtRatio.textContent = data.zram_orig_bytes > 0 ? `${((data.zram_compr_bytes / data.zram_orig_bytes) * 100).toFixed(1)}% → 实占 ${fmtBytes(data.zram_mem_used_bytes)}` : '—';
    syncHeroDesc();
  } catch (err) {
    refs.swapRows.innerHTML = `<div class="note-body" style="color:var(--danger)">获取失败：${err.message}</div>`;
  } finally {
    state.swapLoading = false;
  }
}

async function refreshOptimize() {
  if (state.optLoading) return;
  state.optLoading = true;
  refs.optRefreshLabel.textContent = '读取中…';
  try {
    const data = await apiFetch(API.optimize, { timeoutMs: 6000 });
    renderOptimizeRows(data);
  } catch (err) {
    refs.optRows.innerHTML = `<div class="opt-item"><div class="opt-label" style="color:var(--danger)">获取失败</div><div class="opt-meta">${err.message}</div></div>`;
  } finally {
    refs.optRefreshLabel.textContent = '刷新';
    state.optLoading = false;
  }
}

async function applyProfile(profile) {
  if (profile === state.currentProfile || state.cpuBusy) return;
  const card = refs.profileList.querySelector(`[data-profile="${profile}"]`);
  card.classList.add('loading');
  appendLog(`切换到 ${PROFILES[profile].name}…`, 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.profile, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ profile }), timeoutMs: 8000 });
    if (data.ok) {
      state.currentProfile = profile;
      syncProfileUi();
      syncHeroDesc();
      document.querySelectorAll('.profile-option').forEach((el) => el.classList.toggle('selected', el.dataset.profile === profile));
      showToast(`切换至：${PROFILES[profile].name}`);
      appendLog(`${PROFILES[profile].name} 已应用`, 'ok');
      refreshCpu();
    } else {
      showToast(`切换失败：${data.error || '未知'}`);
      appendLog(data.error || '切换失败', 'err');
    }
  } catch (err) {
    showToast('请求失败，检查服务是否运行');
    appendLog(String(err), 'err');
  } finally {
    card.classList.remove('loading');
  }
}

async function applyThermal(offset) {
  if (offset === state.currentOffset || state.thermalBusy) return;
  const prev = state.currentOffset;
  const card = refs.thermalList.querySelector(`[data-offset="${offset}"]`);
  card.classList.add('loading');
  appendLog(`切换温控档位 ${THERMAL_PRESETS[offset].name}…`, 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.thermalSet, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ offset }), timeoutMs: 8000 });
    if (data.ok) {
      state.currentOffset = offset;
      syncThermalUi();
      syncHeroDesc();
      if (data.restarted) {
        showToast(`${THERMAL_PRESETS[offset].name} · thermal 服务已重启`);
        appendLog(`${THERMAL_PRESETS[offset].name} 已重启 thermal 服务`, 'ok');
      } else {
        appendLog(`${THERMAL_PRESETS[offset].name} 已保存（需重启生效）`, 'warn');
        openRebootModal(offset, prev);
      }
    } else {
      showToast(`切换失败：${data.error || '未知'}`);
      appendLog(data.error || '切换失败', 'err');
    }
  } catch (err) {
    showToast('请求失败，检查服务是否运行');
    appendLog(String(err), 'err');
  } finally {
    card.classList.remove('loading');
  }
}

async function cancelThermalChange() {
  refs.rebootModal.classList.remove('open');
  try {
    await apiFetch(API.thermalSet, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ offset: state.thermalModal.prev }), timeoutMs: 8000 });
    state.currentOffset = state.thermalModal.prev;
    syncThermalUi();
    syncHeroDesc();
    showToast('已撤销，恢复原档位');
  } catch (_) {
    showToast('撤销失败，请手动重新选择');
  }
}

async function rebootDevice() {
  refs.rebootModal.classList.remove('open');
  showToast('正在重启设备…');
  try { await apiFetch(API.reboot, { method: 'POST', timeoutMs: 8000 }); } catch (_) {}
}

async function toggleSwapMode() {
  if (state.swapBusy) return;
  state.swapBusy = true;
  const newMode = state.swapMode === 'optimized' ? 'stock' : 'optimized';
  try {
    const data = await apiFetch(API.swap, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mode: newMode }), timeoutMs: 8000 });
    if (data.ok) {
      showToast(newMode === 'optimized' ? 'VM 参数已优化（即时生效）' : '已恢复默认 VM 参数');
      appendLog(newMode === 'optimized' ? 'Swap 优化参数已应用' : 'Swap 已恢复默认', 'ok');
      refreshSwap();
    } else {
      showToast(`操作失败：${data.error || '未知'}`);
    }
  } catch (_) {
    showToast('请求失败');
  } finally {
    state.swapBusy = false;
  }
}

async function doFullRefresh() {
  showToast('正在刷新…', 1000);
  await Promise.all([refreshCpu(), refreshThermal(), refreshSwap()]);
  refreshOptimize();
  loadInfo();
  showToast('已刷新');
}

function startPolling() {
  if (state.timers.cpu) return;
  state.timers.cpu = window.setInterval(refreshCpu, 3000);
  state.timers.thermal = window.setInterval(refreshThermal, 8000);
  state.timers.swap = window.setInterval(refreshSwap, 30000);
}

function stopPolling() {
  clearInterval(state.timers.cpu);
  clearInterval(state.timers.thermal);
  clearInterval(state.timers.swap);
  state.timers.cpu = state.timers.thermal = state.timers.swap = null;
}

function bindStaticEvents() {
  document.querySelectorAll('.tab-item').forEach((button) => button.addEventListener('click', () => switchTab(button.dataset.tab)));
  document.querySelectorAll('[data-theme-option]').forEach((button) => {
    button.addEventListener('click', () => {
      applyTheme(button.dataset.themeOption, true);
      closeThemeSheet();
      showToast(`已切换为${getThemeLabel(button.dataset.themeOption)}`);
    });
  });
  $('theme-open-btn').addEventListener('click', openThemeSheet);
  $('theme-open-btn-2').addEventListener('click', openThemeSheet);
  $('refresh-all-btn').addEventListener('click', doFullRefresh);
  $('refresh-cpu-btn').addEventListener('click', refreshCpu);
  $('swap-toggle-btn').addEventListener('click', toggleSwapMode);
  $('swap-detail-btn').addEventListener('click', () => openDetail('内存优化详情', SWAP_DETAIL));
  $('opt-refresh-btn').addEventListener('click', refreshOptimize);
  $('log-toggle').addEventListener('click', () => refs.logCard.classList.toggle('open'));
  $('theme-close-btn').addEventListener('click', closeThemeSheet);
  $('detail-close-btn').addEventListener('click', closeDetailModal);
  $('reboot-now-btn').addEventListener('click', rebootDevice);
  $('reboot-later-btn').addEventListener('click', closeRebootModal);
  $('reboot-cancel-btn').addEventListener('click', cancelThermalChange);
  $('open-cpu-detail-btn').addEventListener('click', () => {
    const cpuSet = {
      game: 'top-app: cpu0-7 全核\nforeground: cpu0-6\nbackground: cpu0-3',
      balanced: 'top-app: cpu4-7\nforeground: cpu0-6\nbackground: cpu0-3',
      light: 'top-app: cpu4-7\nforeground: cpu0-6\nbackground: cpu0-3',
      battery: 'top-app: cpu4-7\nforeground: cpu0-6\nbackground: cpu0-3',
      stock: 'top-app: cpu0-7\nforeground: cpu0-6\nbackground: cpu0-3'
    };
    let html = `<b>当前模式</b><br>${(PROFILES[state.currentProfile] || PROFILES.unknown).name}<br><br>`;
    html += `<b>cpuset 分配</b><br>${(cpuSet[state.currentProfile] || '未设置').replace(/\n/g, '<br>')}`;
    if (state.lastClusters && state.lastClusters.length) {
      state.lastClusters.forEach((cluster, index) => {
        const maxHz = cluster.max > 0 ? cluster.max : (CLUSTERS[index]?.maxHz || 0);
        html += `<br><br><b>${CLUSTERS[index]?.label || `Cluster ${index}`}</b><br>`;
        html += `cur: ${cluster.cur ? `${(cluster.cur / 1000).toFixed(0)} MHz` : '—'} / max: ${maxHz ? `${(maxHz / 1000).toFixed(0)} MHz` : '—'}<br>`;
        html += `resp_time: ${cluster.resp_ms ?? '—'}ms · down_rate: ${cluster.down_us ?? '—'}µs<br>`;
        html += `governor: ${cluster.gov || '—'}`;
      });
    } else html += '<br><br>暂无频率快照，请先刷新一次。';
    openDetail('CPU 调度参数详情', html);
  });
  refs.detailModal.querySelector('.modal-bg').addEventListener('click', closeDetailModal);
  refs.themeModal.querySelector('.modal-bg').addEventListener('click', closeThemeSheet);
  refs.profileList.addEventListener('click', (evt) => {
    const detailBtn = evt.target.closest('[data-action="profile-detail"]');
    if (detailBtn) openDetail(PROFILES[detailBtn.dataset.profile].name, PROFILES[detailBtn.dataset.profile].detail);
  });
  refs.thermalList.addEventListener('click', (evt) => {
    const detailBtn = evt.target.closest('[data-action="thermal-detail"]');
    if (detailBtn) {
      const offset = Number(detailBtn.dataset.offset);
      openDetail(THERMAL_PRESETS[offset].name, THERMAL_PRESETS[offset].detail);
    }
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) stopPolling();
    else {
      refreshCpu();
      refreshThermal();
      startPolling();
    }
  });
}

async function init() {
  initRefs();
  initTheme();
  renderProfileCards();
  renderThermalCards();
  bindStaticEvents();
  bindTabSwipe();
  bindPullToRefresh();
  refs.topbarSubtitle.textContent = TAB_META[state.currentTab];
  positionMarkers();
  await loadInfo();
  await Promise.all([loadSavedProfile(), loadThermalPreset()]);
  await refreshCpu();
  await refreshThermal();
  window.setTimeout(refreshOptimize, 1000);
  window.setTimeout(refreshSwap, 1400);
  startPolling();
}

window.addEventListener('DOMContentLoaded', init);
