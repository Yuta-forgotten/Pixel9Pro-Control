if (location.host !== '127.0.0.1:6210') {
  location.replace('http://127.0.0.1:6210');
}

'use strict';

const API = {
  profile: '/cgi-bin/profile.sh',
  status: '/cgi-bin/status.sh',
  info: '/cgi-bin/info.sh',
  thermal: '/cgi-bin/thermal.sh',
  thermalHistory: '/cgi-bin/thermal.sh?history=1',
  thermalFresh: '/cgi-bin/thermal.sh?fresh=1',
  thermalClear: '/cgi-bin/thermal.sh?clear=1&fresh=1',
  thermalSet: '/cgi-bin/set_thermal.sh',
  reboot: '/cgi-bin/reboot.sh',
  swap: '/cgi-bin/swap.sh',
  theme: '/cgi-bin/theme.sh',
  nrSwitch: '/cgi-bin/nr_switch.sh',
  uecap: '/cgi-bin/uecap.sh',
  thermalBurst: '/cgi-bin/thermal_burst.sh',
  ntp: '/cgi-bin/ntp.sh',
  energy: '/cgi-bin/energy.sh',
  energyFast: '/cgi-bin/energy.sh?fast=1',
  historyExport: '/cgi-bin/history_export.sh',
  auth: '/cgi-bin/auth.sh',
  checkBaseband: '/cgi-bin/check_baseband.sh',
  standbyGuard: '/cgi-bin/standby_guard.sh',
  bgRestrict: '/cgi-bin/bg_restrict.sh',
  ownerArbiter: '/cgi-bin/owner_arbiter.sh',
};

const STORAGE_THEME_KEY = 'pixel9pro_theme_mode';
const STORAGE_TOKEN_KEY = 'pixel9pro_webui_token';
const STORAGE_PALETTE_KEY = 'pixel9pro_palette';
const STORAGE_PALETTE_CUSTOM_KEY = 'pixel9pro_palette_custom';
// 预设主题色种子 (清新耐看); default 不派生, 用 :root 默认清新青绿。seed 也作色板圆点色。
const PALETTES = [
  { name: 'default', label: '青绿', seed: '#1c8c74' },
  { name: 'sky', label: '天青', seed: '#1f93b0' },
  { name: 'ocean', label: '雾蓝', seed: '#4f7fcf' },
  { name: 'lavender', label: '暮紫', seed: '#7d6bd6' },
  { name: 'rose', label: '樱粉', seed: '#cf6188' },
  { name: 'amber', label: '暖橙', seed: '#c47b39' },
  { name: 'sage', label: '苔绿', seed: '#6a9442' },
];
// 主题色覆盖的 CSS 变量: 强调三色(primary/secondary/tertiary) + 状态正向/信息 + 中性表面/背景。
// 不含 --warn(琥珀)/--danger(红) 语义固定、--text/--line 中性文本边框、温度色阶。
const PALETTE_VARS = [
  '--primary', '--on-primary', '--primary-container', '--on-primary-container',
  '--secondary-container', '--secondary-ink',
  '--tertiary', '--tertiary-container', '--on-tertiary-container',
  '--success', '--success-container', '--info', '--info-container',
  '--sc-lowest', '--sc-low', '--sc', '--sc-high', '--sc-highest',
  '--bg', '--bg-canvas',
];
const WEBUI_SESSION_START_TS = Math.floor(Date.now() / 1000);
const TAB_ORDER = ['home', 'tune', 'network', 'system'];
const TAB_META = {
  home: '状态总览',
  tune: '性能与温控',
  network: '网络',
  system: '系统',
};
const CLUSTERS = [
  { label: '小核 · cpu0-3', maxHz: 1950000 },
  { label: '中核 · cpu4-6', maxHz: 2600000 },
  { label: '大核 · cpu7', maxHz: 3105000 },
];
const HOME_CPU_LABELS = ['小核', '中核', '大核'];
const PACKAGE_ALIASES = Object.freeze({
  'com.android.chrome': 'Chrome',
  'com.google.android.apps.chrome': 'Chrome',
  'com.google.android.apps.nexuslauncher': 'Pixel Launcher',
  'com.android.systemui': '系统界面',
  'com.android.settings': '系统设置',
  'com.android.vending': 'Google Play 商店',
  'com.google.android.gms': 'Google Play 服务',
  'com.google.android.gsf': 'Google 服务框架',
  'com.google.android.googlequicksearchbox': 'Google',
  'com.google.android.youtube': 'YouTube',
  'com.google.android.apps.youtube.music': 'YouTube Music',
  'com.google.android.apps.photos': 'Google 相册',
  'com.google.android.apps.maps': 'Google 地图',
  'com.google.android.GoogleCamera': 'Pixel 相机',
  'com.google.android.dialer': '电话',
  'com.google.android.apps.messaging': '信息',
  'com.google.android.apps.wellbeing': '数字健康',
  'com.google.android.webview': 'Android System WebView',
  'com.tencent.mm': '微信',
  'com.tencent.mobileqq': 'QQ',
  'com.ss.android.ugc.aweme': '抖音',
  'com.zhiliaoapp.musically': 'TikTok',
  'com.bilibili.app.in': '哔哩哔哩',
  'tv.danmaku.bili': '哔哩哔哩',
  'org.telegram.messenger': 'Telegram',
  'com.instagram.android': 'Instagram',
  'com.whatsapp': 'WhatsApp',
  'com.spotify.music': 'Spotify',
  'com.example.piliplus': 'PiliPlus',
  'com.gtxfury.flyclash.smart': 'FlyClash',
  'com.radolyn.ayugram': 'AyuGram'
});
const TEMP_MIN = 25;
const TEMP_MAX = 60;
const THRESH_STOCK = 37;
const THRESH_MOD_DEFAULT = 4;

const THEME_ICONS = {
  system: '<svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor"><path d="M4 5h16v10H4zm0 12h16v2H4z"/></svg>',
  light: '<svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor"><path d="M6.76 4.84l-1.8-1.79-1.41 1.41 1.79 1.8 1.42-1.42zM1 13h3v-2H1v2zm10-9h2V1h-2v3zm7.45 1.46l1.79-1.8-1.41-1.41-1.8 1.79 1.42 1.42zM17.24 19.16l1.8 1.79 1.41-1.41-1.79-1.8-1.42 1.42zM20 11v2h3v-2h-3zM11 20h2v3h-2v-3zm-7.45-2.54l-1.79 1.8 1.41 1.41 1.8-1.79-1.42-1.42zM12 6a6 6 0 100 12 6 6 0 000-12z"/></svg>',
  dark: '<svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor"><path d="M9.37 5.51A7 7 0 0018.49 14.63 9 9 0 119.37 5.51z"/></svg>',
};

const PROFILES = {
  performance: {
    name: '性能优先',
    summary: '放开内核动态 boost 上限，并让中大核更早介入的手动性能档。',
    desc: '中大核更早介入，适合短时高负载。温升也会更快。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M7 2v11h3v9l7-12h-4l4-8z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M7 2v11h3v9l7-12h-4l4-8z"/></svg>',
    modeClass: 'mode-game',
    detail: '<b>性能优先</b><br><br><b>cpuset</b>: top-app → cpu0-7，background → cpu0-3<br><b>response_time</b>: 小核 12ms / 中核 20ms / 大核 80ms<br><b>sched_util_clamp_min</b>: 0 → 1024（恢复 Google 出厂 uclamp.min 上限，允许 ADPF/HBoost/fork/ExoPlayer 动态 boost 发挥作用）<br><br>这是手动性能档：中大核更早补位，前台峰值响应更强。代价是温升更快；自动策略只在均衡和省电之间切换，手动锁定性能优先时不会自动拉回。'
  },
  balanced: {
    name: '均衡',
    summary: '兼顾前台响应与日常功耗，适合作为常用档位。',
    desc: '保留全核调度能力，同时控制不必要的升频。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z"/></svg>',
    modeClass: 'mode-balanced',
    detail: '<b>均衡</b><br><br><b>cpuset</b>: top-app → cpu0-7，background → cpu0-3<br><b>response_time_ms</b>: 16 / 40 / 200（小 / 中 / 大核）<br><b>sched_util_clamp_min</b>: 0（抑制 per-task boost）<br><br>中等升频速率，top-app 可用全核，X4 升频节奏最慢（200ms）。'
  },
  battery: {
    name: '省电',
    summary: '减少大核参与并放缓升频，降低轻中负载功耗。',
    desc: '优先使用小中核，适合待机与轻度使用。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M15.67 4H14V2h-4v2H8.33C7.6 4 7 4.6 7 5.33v15.33C7 21.4 7.6 22 8.33 22h7.33c.74 0 1.34-.6 1.34-1.33V5.33C17 4.6 16.4 4 15.67 4zM11 19v-2H9l3-5 3 5h-2v2h-2z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M15.67 4H14V2h-4v2H8.33C7.6 4 7 4.6 7 5.33v15.33C7 21.4 7.6 22 8.33 22h7.33c.74 0 1.34-.6 1.34-1.33V5.33C17 4.6 16.4 4 15.67 4zM11 19v-2H9l3-5 3 5h-2v2h-2z"/></svg>',
    modeClass: 'mode-battery',
    detail: '<b>省电</b><br><br><b>cpuset</b>: top-app → cpu0-6，background → cpu0-3<br><b>response_time_ms</b>: 32 / 96 / 200（小 / 中 / 大核）<br><b>sched_util_clamp_min</b>: 0（抑制 per-task boost）<br><br>升频速率最慢；top-app 限制在 cpu0-6，前台常规调度不含大核 X4。'
  },
  default: {
    name: '系统默认',
    summary: '恢复 Google 内核原厂调度，不再应用模块性能策略。',
    desc: '使用系统原厂核心分配与升频节奏。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M13 3C8.03 3 4 7.03 4 12H1l4 4 4-4H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.95-2.05l-1.41 1.41A8.96 8.96 0 0013 21c4.97 0 9-4.03 9-9s-4.03-9-9-9zm-1 5v5l4.25 2.52.77-1.28-3.52-2.09V8H12z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M13 3C8.03 3 4 7.03 4 12H1l4 4 4-4H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.95-2.05l-1.41 1.41A8.96 8.96 0 0013 21c4.97 0 9-4.03 9-9s-4.03-9-9-9zm-1 5v5l4.25 2.52.77-1.28-3.52-2.09V8H12z"/></svg>',
    modeClass: 'mode-stock',
    detail: '<b>系统默认</b><br><br><b>cpuset</b>: top-app → cpu0-7，background → cpu0-3（出厂值）<br><b>response_time_ms</b>: 回写内核只读节点 response_time_ms_nom（本机实测 9 / 52 / 165，随内核版本自适应）<br><b>sched_util_clamp_min</b>: 1024（出厂上限，不压制 boost）<br><br>恢复内核出厂升频节奏与 uclamp/cpuset；balanced/battery 才把 cap 压成 0 省电，本档不压制。不进自动策略。'
  },
  unknown: {
    name: '未选择',
    summary: '尚未读取到有效调度模式，请稍后刷新。',
    desc: '尚未读取到有效调度模式，请稍后刷新。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M11 18h2v-2h-2v2zm1-16C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm0-14c-2.21 0-4 1.79-4 4h2c0-1.1.9-2 2-2s2 .9 2 2c0 2-3 1.75-3 5h2c0-2.25 3-2.5 3-5 0-2.21-1.79-4-4-4z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M11 18h2v-2h-2v2zm1-16C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm0-14c-2.21 0-4 1.79-4 4h2c0-1.1.9-2 2-2s2 .9 2 2c0 2-3 1.75-3 5h2c0-2.25 3-2.5 3-5 0-2.21-1.79-4-4-4z"/></svg>',
    modeClass: 'mode-unknown',
    detail: '当前还没有读取到有效模式，请稍后刷新或到“性能”页重新选择。'
  }
};

const THERMAL_PRESETS = {
  [-2]: {
    name: '睡和放宽',
    summary: '比原厂提前 2°C 介入，机身更凉。',
    detail: '<b>睡和放宽</b><br><br>出厂 -2°C，最早 35°C 介入。<br><br>HINT 35°C / VIRTUAL-SKIN 37°C / CPU-HIGH 39°C。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M9.37 5.51A7 7 0 0018.49 14.63 9 9 0 119.37 5.51z"/></svg>'
  },
  0: {
    name: '躺和放宽',
    summary: '保持原厂阈值，温度控制最稳妥。',
    detail: '<b>躺和放宽</b><br><br>出厂 0°C，最早 37°C 介入。<br><br>HINT 37°C / VIRTUAL-SKIN 39°C / CPU-HIGH 41°C。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M13 3C8.03 3 4 7.03 4 12H1l4 4 4-4H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.95-2.05l-1.41 1.41A8.96 8.96 0 0013 21c4.97 0 9-4.03 9-9s-4.03-9-9-9z"/></svg>'
  },
  2: {
    name: '轻度放宽',
    summary: '比原厂晚 2°C 介入，轻度释放性能。',
    detail: '<b>轻度放宽</b><br><br>出厂 +2°C，最早 39°C 介入。<br><br>HINT 39°C / VIRTUAL-SKIN 41°C / CPU-HIGH 43°C。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M15 13.18V7c0-1.66-1.34-3-3-3S9 5.34 9 7v6.18C7.79 13.86 7 15.18 7 16.71 7 18.97 8.86 20.81 11.12 21H12c2.21 0 4-1.79 4-4 0-1.53-.79-2.85-2-3.82z"/></svg>'
  },
  4: {
    name: '坐和放宽',
    summary: '比原厂晚 4°C 介入，日常推荐。',
    detail: '<b>坐和放宽（模块默认）</b><br><br>出厂 +4°C，最早 41°C 介入。<br><br>HINT 41°C / VIRTUAL-SKIN 43°C / CPU-HIGH 45°C。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M13.5.67s.74 2.65.74 4.8c0 2.06-1.35 3.73-3.41 3.73-2.07 0-3.63-1.67-3.63-3.73l.03-.36C5.21 7.51 4 10.62 4 14c0 4.42 3.58 8 8 8s8-3.58 8-8C20 8.61 17.41 3.8 13.5.67z"/></svg>'
  },
  6: {
    name: '站和放宽',
    summary: '比原厂晚 6°C 介入，性能更积极。',
    detail: '<b>站和放宽</b><br><br>出厂 +6°C，最早 43°C 介入。<br><br>HINT 43°C / VIRTUAL-SKIN 45°C / CPU-HIGH 47°C。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z"/></svg>'
  }
};

// 内存优化详情按 state.swapData 实时生成: 数字取自当前值, 解释随取值自适应,
// 手动改参后重新打开即反映当前 ZRAM / VM 方案 (不再硬编码)
function describeSwappiness(v) {
  if (v <= 20) return '几乎不主动换出匿名页，ZRAM 基本闲置，仅在物理内存吃紧时才回收。';
  if (v <= 60) return '偏保守换页，多数匿名页留在物理内存，偏向前台零 swap 抖动。';
  if (v <= 110) return '平衡换页，配合硬件压缩减少无效 swap-in / swap-out，兼顾后台驻留与前台响应。';
  if (v <= 160) return '较积极换出匿名页到 ZRAM、尽量保留文件缓存（含原厂 150 取向）。';
  return '极度倾向换出匿名页，后台驻留能力最强，但热数据换入可能增多。';
}
function describeMinFree(kb) {
  if (kb <= 32768) return '空闲底线低（接近原厂 ~27MB），可用内存最大，但突发分配更易触发 direct reclaim 卡顿。';
  if (kb <= 65536) return '空闲底线偏低，可用内存较多，回收启动相对靠后。';
  if (kb <= 131072) return '中高空闲底线，kswapd 较早唤醒，direct reclaim 与 allocstall 明显减少。';
  if (kb <= 196608) return '空闲底线高，回收很早介入、突发分配几乎不卡，代价是预留内存增多。';
  return '空闲底线很高，适合重后台实验；日常使用偏浪费内存。';
}
function describeWatermark(v) {
  if (v <= 60) return '水位间距小（接近原厂 50），回收较晚触发，内存利用更满但突发峰值时更易吃紧。';
  if (v <= 150) return '中等水位间距，回收节奏适中。';
  if (v <= 300) return 'low/high 水位间距大，后台回收更早介入、单次回收更多，利于压制突发内存峰值，略增后台 CPU。';
  return '水位间距很大，回收非常积极，churn 与后台 CPU 上升，仅适合重后台场景。';
}
function describeVfs(v) {
  if (v <= 50) return '强烈保留 inode / dentry 缓存，文件路径查询与冷启动最快，但元数据占用内存更多。';
  if (v <= 80) return '倾向保留较多文件缓存元数据，利于应用启动。';
  if (v <= 120) return '常规回收力度（接近原厂 100），缓存与内存平衡。';
  if (v <= 160) return '较积极回收文件缓存元数据，省内存但路径查询 / 启动可能变慢。';
  return '激进回收 inode / dentry 缓存，最省内存但文件操作明显变慢。';
}
function swapModeIntro(mode) {
  if (mode === 'optimized') return '<b>当前方案：模块默认</b><br>面向 Pixel 9 Pro 日常使用与 Tensor G4 低热取向的一组平衡 VM 参数。';
  if (mode === 'stock') return '<b>当前方案：原厂</b><br>已恢复 Google 出厂 VM 参数，模块不再干预内存回收节奏。';
  return '<b>当前方案：自定义</b><br>以下为基于你手动设定值的实时分析；应用后以 custom 模式随下次开机恢复。';
}
function buildSwapDetail(data) {
  const d = data || { ...SWAP_OPTIMIZED, mode: 'optimized', zram_algo: 'lz77eh', zram_disksize: 11945377792, stock_zram_size: 0 };
  const isEH = d.zram_algo === 'lz77eh';
  const sizeGB = (d.zram_disksize / 1073741824).toFixed(1);
  const totalRam = d.stock_zram_size > 0 ? d.stock_zram_size * 2 : 0;
  const ramPct = totalRam > 0 ? ` (约 ${Math.round((d.zram_disksize / totalRam) * 100)}% RAM)` : '';
  const wsf = d.watermark_scale_factor || 0;
  const algoBlock = isEH
    ? '<b>ZRAM 算法: lz77eh (Emerald Hill 硬件加速)</b><br>Tensor G4 内置固定功能压缩引擎，压缩和解压由专用硬件完成，CPU 几乎不参与，适合高频换页场景。'
    : `<b>ZRAM 算法: ${d.zram_algo}</b><br>当前非硬件加速算法，重启后模块会自动切换为 lz77eh。`;
  const sizeBlock = `<b>ZRAM 大小: ${sizeGB}GB${ramPct}</b><br>原厂默认约为 50% RAM；模块扩容后让更多后台匿名页驻留在 ZRAM 中。`;
  return [
    swapModeIntro(d.mode),
    algoBlock,
    sizeBlock,
    `<b>swappiness: ${d.swappiness}</b><br>${describeSwappiness(d.swappiness)}`,
    `<b>min_free_kbytes: ${d.min_free_kbytes}（≈${Math.round(d.min_free_kbytes / 1024)}MB）</b><br>${describeMinFree(d.min_free_kbytes)}`,
    `<b>watermark_scale_factor: ${wsf}</b><br>${describeWatermark(wsf)}`,
    `<b>vfs_cache_pressure: ${d.vfs_cache_pressure}</b><br>${describeVfs(d.vfs_cache_pressure)}`
  ].join('<br><br>');
}
const SWAP_OPTIMIZED = { swappiness: 100, min_free_kbytes: 131072, watermark_scale_factor: 200, vfs_cache_pressure: 60 };
const SWAP_STOCK = { swappiness: 150, min_free_kbytes: 27386, watermark_scale_factor: 50, vfs_cache_pressure: 100 };
const SWAP_LIMITS = {
  swappiness: { min: 0, max: 200, step: 5 },
  min_free_kbytes: { min: 16384, max: 262144, step: 8192 },
  watermark_scale_factor: { min: 10, max: 500, step: 10 },
  vfs_cache_pressure: { min: 10, max: 200, step: 5 }
};

const NR_SWITCH_DETAIL = '<b>NR 息屏降级 (Screen-Off LTE Switch)</b><br><br>开启后，息屏超过 <b>300 秒</b> 时网络模式从 5G NR 切换到 LTE，降低调制解调器射频功耗。亮屏时恢复 5G/NR 模式，<b>5GA / 5G CA 能力完全保留</b>。<br><br><b>防抖机制</b><br>- 息屏后等待 300 秒再切换，快速亮屏不会触发<br>- 恢复 NR 后冷却 10 分钟，避免频繁亮灭导致来回切换<br>- 已降 LTE 后每 300 秒低频复查，减少打断 deep suspend<br><br><b>原理</b><br>NR_SA Band 41 (100MHz) 射频功耗远高于 LTE 20MHz。息屏时降级为 LTE 可使调制解调器进入更深低功耗态，预期节省 30-50% 蜂窝待机功耗。<br><br><b>注意</b><br>- 切换期间可能有 1-2 秒网络短暂中断<br>- 开启热点时自动跳过降级，保障共享连接<br>- 息屏下载或后台大流量时可关闭此功能<br>- 功能状态即时生效，无需重启';

const UECAP_MODES = [
  { id: 'balanced', name: '国内频段', desc: '原厂 +25 组中国 NR 组合 · 推荐' },
  { id: 'special', name: '全面增强', desc: '原厂 +52 组全球 NR 组合' },
  { id: 'universal', name: 'Google 默认', desc: '原厂能力表 · 不做任何修改' },
];

const UECAP_DETAIL = '<b>UE 网络能力配置</b><br><br>UECap 告诉基站”手机支持哪些载波组合”，基站据此分配频段。<b>不直接影响功耗</b>——功耗取决于信号强度和 modem 活跃时间。<br><br><b>国内频段</b>（推荐）<br>原厂 +25 组中国 NR 组合（n28 / n41 / n79），只增不删。<br><br><b>全面增强</b><br>原厂 +52 组全球 NR 组合，含国际 n78 / EN-DC。国内多出的组合基本用不到。<br><br><b>Google 默认</b><br>原厂能力表，不做任何修改。<br><br>切换只重启蜂窝 modem，不影响 Wi-Fi / 蓝牙。';
const BASEBAND_DETAIL = '<b>基带配置模块 (pixel9pro_baseband_trial)</b><br><br><b>提供内容</b><br>- 5G / IMS 属性：VoLTE、Wi-Fi Calling 开关<br>- CarrierSettings：运营商配置覆盖<br>- China MCFG：移动 / 联通 / 电信相关 modem 配置<br><br><b>不包含</b><br>- UECap binarypb 管理（由 pixel9pro_control 负责）<br>- 温控、CPU 调度、ZRAM 和 WebUI';
const UECAP_VERIFY_INTERVAL_MS = 1500;
const UECAP_VERIFY_TIMEOUT_MS = 15000;
const WEBUI_IDLE_MS = 45000;
const POLL_MIN_DELAY_MS = 900;
const TEMP_CHART_REFRESH_MS = 10000;
const ENERGY_DETAIL_REFRESH_MS = 10000;
const ENERGY_SYSTEM_REFRESH_FALLBACK_MS = 60000;
const ENERGY_SYSTEM_REFRESH_MARGIN_MS = 2000;
const POLL_INTERVALS = {
  cpu: { home: 5000, perf: 4000, relaxedHome: 12000, relaxedPerf: 9000 },
  thermal: { home: 12000, thermal: 10000, relaxedHome: 24000, relaxedThermal: 20000 },
  optim: { home: 45000, optim: 30000, relaxedHome: 120000, relaxedOptim: 90000 },
  slow: { home: 90000, optim: 75000, relaxedHome: 180000, relaxedOptim: 150000 },
};

const NTP_SERVERS = [
  { id: 'ntp.aliyun.com', name: '阿里云', desc: '阿里云公共 NTP 服务' },
  { id: 'ntp.myhuaweicloud.com', name: '华为云', desc: '华为云 NTP 服务' },
  { id: 'ntp1.xiaomi.com', name: '小米', desc: '小米 NTP 服务' },
  { id: 'time.android.com', name: 'Google 默认', desc: 'Pixel 出厂默认 NTP 服务器' },
];

const BG_RESTRICT_POLICY_ORDER = ['stop_after_leave', 'block_all', 'block_services', 'bucket'];
const BG_RESTRICT_POLICIES = {
  stop_after_leave: {
    label: '休眠',
    desc: '离开前台后按所选延时停止后台进程，并降低后台优先级。'
  },
  block_all: {
    label: '禁止后台活动',
    desc: '限制后台服务、自启动式后台运行、jobs、alarms 与后台网络配额，推送和同步风险较高。'
  },
  block_services: {
    label: '禁止后台服务',
    desc: '禁止后台服务继续运行，保留一部分 jobs、alarms 和推送处理空间。'
  },
  bucket: {
    label: '降低后台优先级',
    desc: '只降低 App Standby Bucket，减少后台执行机会，适合先观察通知与同步影响。'
  }
};
const BG_RESTRICT_DELAYS = [3, 5, 10];

const ZONE_LABELS = {
  'VIRTUAL-SKIN': '机身温度',
  'SKIN': '机身温度',
  'soc_therm': 'CPU / SoC',
  'battery': '电池温度',
  'charging_therm': '充电 IC',
  'btmspkr_therm': '底部扬声器'
};

const refs = {};
const state = {
  currentTab: 'home',
  currentProfile: 'unknown',
  manualProfile: 'balanced',
  profilePolicy: 'manual',
  schedOwner: 'pixel',
  uperfDetected: false,
  uperfModuleId: '',
  uperfModuleName: '',
  uperfModulePath: '',
  uperfModuleSource: '',
  uperfModuleState: '',
  uperfModuleEnabled: 'no',
  uperfProcessAlive: 'no',
  uperfActive: 'no',
  fasRsDetected: false,
  fasRsModuleId: '',
  fasRsModuleName: '',
  fasRsModulePath: '',
  fasRsModuleSource: '',
  fasRsModuleState: '',
  fasRsModuleEnabled: 'no',
  fasRsOwnerState: '',
  fasRsMode: '',
  fasRsProcessAlive: 'no',
  fasRsRuntimeState: '',
  fasRsActive: 'no',
  externalSchedulerDetected: false,
  externalSchedulerActive: false,
  externalSchedulerId: '',
  externalSchedulerName: '',
  externalSchedulerKind: '',
  externalSchedulerPath: '',
  externalSchedulerSource: '',
  externalSchedulerState: '',
  externalSchedulerEnabled: 'no',
  effectiveSchedulerOwner: 'pixel',
  effectiveSchedulerName: 'Pixel9Pro-Control',
  effectiveSchedulerKind: 'pixel',
  effectiveSchedulerMode: '',
  profileSurface: 'authoritative',
  profileSurfaceStale: false,
  profileSurfaceNote: '',
  autoReason: '',
  currentOffset: 4,
  swapMode: 'unknown',
  swapData: null,
  themeMode: 'system',
  paletteName: 'default',
  paletteCustom: '#3aa6c2',
  webuiToken: '',
  cpuBusy: false,
  profilePolicyBusy: false,
  schedOwnerBusy: false,
  ownerArbiterBusy: false,
  thermalBusy: false,
  thermalBadReads: 0,
  lastSkinTempC: null,
  thermalApplyBusy: false,
  swapBusy: false,
  swapLoading: false,
  nrSwitch: 'off',
  nrBusy: false,
  sim2AutoManage: 'off',
  idleIsolateMode: 'off',
  standbyGuardBusy: false,
  bgRestrictEnabled: 'on',
  bgRestrictBusy: false,
  standbyDiag: null,
  uecapMode: 'unknown',
  uecapActiveMode: 'unknown',
  uecapBusy: false,
  uecapPendingMode: '',
  uecapVerifyState: 'idle',
  uecapVerifyMessage: '',
  uecapExpectedHash: '',
  uecapVerifyNonce: 0,
  ntpServer: 'time.android.com',
  ntpBusy: false,
  deviceClockTimer: null,
  foregroundPaused: false,
  cpuRows: null,
  homeCpuRows: null,
  sensorRefs: null,
  homeSensorRefs: null,
  poller: {
    timer: null,
    running: false,
    lastInteractionAt: 0,
    lastRun: { cpu: 0, thermal: 0, optim: 0, slow: 0 }
  },
  lastClusters: null,
  pull: { y0: 0, active: false, dist: 0, busy: false },
  thermalModal: { pending: 4, prev: 4 },
  tempChart: {
    timer: null,
    draw: null,
    activeRange: 10,
    requestId: 0
  },
  energyDetail: {
    timer: null,
    fullTimer: null,
    requestId: 0,
    requestKind: '',
    requestController: null,
    fullData: null,
    liveData: null,
    activeWindowMinutes: 30,
    openSections: Object.create(null),
    renderSignature: ''
  }
};

function $(id){ return document.getElementById(id); }

function initRefs() {
  refs.topbarSubtitle = $('topbar-subtitle');
  refs.topbarKicker = $('topbar-kicker');
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
  refs.rtMemAvail = $('rt-mem-avail');
  refs.rtMemTotal = $('rt-mem-total');
  refs.rtSwapFree = $('rt-swap-free');
  refs.rtUptime = $('rt-uptime');
  refs.infoModel = $('info-model');
  refs.infoAndroid = $('info-android');
  refs.infoKernel = $('info-kernel');
  refs.infoModule = $('info-module');
  refs.logCard = $('log-card');
  refs.logInner = $('log-inner');
  refs.perfCurrentName = $('perf-current-name');
  refs.perfCurrentDesc = $('perf-current-desc');
  refs.perfPolicyDesc = $('perf-policy-desc');
  refs.profilePolicyManualBtn = $('profile-policy-manual-btn');
  refs.profilePolicyAutoBtn = $('profile-policy-auto-btn');
  refs.schedOwnerLabel = $('sched-owner-label');
  refs.schedOwnerToggleBtn = $('sched-owner-toggle-btn');
  refs.schedOwnerToggleLabel = $('sched-owner-toggle-label');
  refs.ownerArbiterRow = $('owner-arbiter-row');
  refs.ownerArbiterLabel = $('owner-arbiter-label');
  refs.ownerArbiterTickBtn = $('owner-arbiter-tick-btn');
  refs.ownerArbiterTickLabel = $('owner-arbiter-tick-label');
  refs.cpuRows = $('cpu-rows');
  refs.profileList = $('profile-list');
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
  refs.swapDesc = $('swap-desc');
  refs.swapToggleLabel = $('swap-toggle-label');
  refs.swapRows = $('swap-rows');
  refs.swapTuneModal = $('modal-swap-tune');
  refs.swapTuneInputs = {
    swappiness: $('swap-input-swappiness'),
    min_free_kbytes: $('swap-input-minfree'),
    watermark_scale_factor: $('swap-input-watermark'),
    vfs_cache_pressure: $('swap-input-vfs')
  };
  refs.swapTuneNumbers = {
    swappiness: $('swap-number-swappiness'),
    min_free_kbytes: $('swap-number-minfree'),
    watermark_scale_factor: $('swap-number-watermark'),
    vfs_cache_pressure: $('swap-number-vfs')
  };
  refs.swapTuneValues = {
    swappiness: $('swap-value-swappiness'),
    min_free_kbytes: $('swap-value-minfree'),
    watermark_scale_factor: $('swap-value-watermark'),
    vfs_cache_pressure: $('swap-value-vfs')
  };
  refs.nrSwitchDesc = $('nr-switch-desc');
  refs.sim2AutoDesc = $('sim2-auto-desc');
  refs.sim2AutoToggleBtn = $('sim2-auto-toggle-btn');
  refs.sim2AutoToggleLabel = $('sim2-auto-toggle-label');
  refs.sim2AutoRows = $('sim2-auto-rows');
  refs.idleIsolateDesc = $('idle-isolate-desc');
  refs.idleIsolateToggleBtn = $('idle-isolate-toggle-btn');
  refs.idleIsolateToggleLabel = $('idle-isolate-toggle-label');
  refs.idleIsolateRows = $('idle-isolate-rows');
  refs.standbyDiagRows = $('standby-diag-rows');
  refs.bgRestrictDesc = $('bg-restrict-desc');
  refs.bgRestrictToggleBtn = $('bg-restrict-toggle-btn');
  refs.bgRestrictToggleLabel = $('bg-restrict-toggle-label');
  refs.bgRestrictRows = $('bg-restrict-rows');
  refs.bgRestrictAddBtn = $('bg-restrict-add-btn');
  refs.bgRestrictPkgInput = $('bg-restrict-pkg-input');
  refs.bgRestrictPolicySelect = $('bg-restrict-policy-select');
  refs.bgRestrictDelaySelect = $('bg-restrict-delay-select');
  refs.nrSwitchToggleLabel = $('nr-switch-toggle-label');
  refs.nrSwitchRows = $('nr-switch-rows');
  refs.uecapDesc = $('uecap-desc');
  refs.uecapBtnGroup = $('uecap-btn-group');
  refs.uecapRows = $('uecap-rows');
  refs.basebandDesc = $('baseband-desc');
  refs.basebandRows = $('baseband-rows');
  refs.ntpDesc = $('ntp-desc');
  refs.ntpSyncLabel = $('ntp-sync-label');
  refs.ntpServerList = $('ntp-server-list');
  refs.ntpInfoRows = $('ntp-info-rows');
  refs.themeModal = $('modal-theme');
  refs.themeChoices = Array.from(document.querySelectorAll('[data-theme-option]'));
  refs.rebootModal = $('modal-reboot');
  refs.detailModal = $('modal-detail');
  refs.detailTitle = $('detail-title');
  refs.detailBody = $('detail-body');
  refs.toastWrap = $('toast-wrap');
  refs.pullInd = $('pull-ind');
  refs.pullText = $('pull-text');
  refs.tabPages = $('tab-pages');
  refs.topbar = document.querySelector('.topbar');
}

function setStaticHtml(target, html) {
  const doc = new DOMParser().parseFromString(String(html || ''), 'text/html');
  target.replaceChildren(...Array.from(doc.body.childNodes).map((node) => document.importNode(node, true)));
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
  document.querySelector('meta[name="theme-color"]').setAttribute('content', resolved === 'dark' ? '#191c1b' : '#eceeec');
  setStaticHtml(refs.themeBtnIcon, THEME_ICONS[state.themeMode] || THEME_ICONS.system);
  refs.topbarThemeChip.textContent = getThemeLabel(state.themeMode);
  refs.themeChoices.forEach((choice) => {
    choice.classList.toggle('selected', choice.dataset.themeOption === state.themeMode);
  });
  document.querySelectorAll('[data-seg-theme]').forEach((b) => {
    b.classList.toggle('active', b.dataset.segTheme === state.themeMode);
  });
}

function applyTheme(mode, persist = true) {
  state.themeMode = mode;
  if (persist) { localStorage.setItem(STORAGE_THEME_KEY, mode); saveThemeToServer(); }
  syncThemeUi();
  // 自定义/预设主题色在明暗下取色不同, 切换模式时按新明暗重新派生
  if (state.paletteName && state.paletteName !== 'default') applyPalette(state.paletteName, false);
}

function initTheme() {
  applyTheme(localStorage.getItem(STORAGE_THEME_KEY) || 'system', false);
  const mq = window.matchMedia('(prefers-color-scheme: dark)');
  const handle = () => { if (state.themeMode === 'system') { syncThemeUi(); if (state.paletteName !== 'default') applyPalette(state.paletteName, false); } };
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
    const vars = deriveTheme(seed, getResolvedTheme(state.themeMode) === 'dark');
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
    setStaticHtml(btn, '<span class="swatch-check" aria-hidden="true"><svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg></span>');
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
  apiFetch(API.theme, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ mode: state.themeMode, palette: state.paletteName, custom: state.paletteCustom }),
    timeoutMs: 5000
  }).catch(() => {});
}

// 仅当 localStorage 完全无主题记录 (新装 / WebView 被清) 时, 回读服务端兜底并应用
async function restoreThemeFromServerIfNeeded() {
  if (localStorage.getItem(STORAGE_THEME_KEY) || localStorage.getItem(STORAGE_PALETTE_KEY) || localStorage.getItem(STORAGE_PALETTE_CUSTOM_KEY)) return;
  try {
    const data = await apiFetch(API.theme, { timeoutMs: 5000 });
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

function pushModalState(name) {
  history.pushState({ modal: name }, '');
}

function popModalIfTop(name) {
  if (history.state && history.state.modal === name) history.back();
}

function openThemeSheet(){
  refs.themeModal.classList.add('open');
  pushModalState('theme');
  queueNextPoll(computeNextPollDelay());
}
function closeThemeSheet(){
  refs.themeModal.classList.remove('open');
  popModalIfTop('theme');
  queueNextPoll(POLL_MIN_DELAY_MS);
}

function openRebootModal(pending, prev) {
  state.thermalModal.pending = pending;
  state.thermalModal.prev = prev;
  refs.rebootModal.classList.add('open');
  pushModalState('reboot');
  queueNextPoll(computeNextPollDelay());
}

function closeRebootModal() {
  refs.rebootModal.classList.remove('open');
  popModalIfTop('reboot');
  queueNextPoll(POLL_MIN_DELAY_MS);
  showToast('已保存，重启手机后生效');
}

function openDetail(title, html) {
  stopTempChartRefresh();
  stopEnergyDetailRefresh();
  refs.detailModal.classList.remove('energy-mode');
  refs.detailModal.classList.remove('history-mode');
  refs.detailTitle.textContent = title;
  setStaticHtml(refs.detailBody, html);
  refs.detailModal.classList.add('open');
  pushModalState('detail');
  queueNextPoll(computeNextPollDelay());
}

function closeDetailModal(){
  stopTempChartRefresh();
  stopEnergyDetailRefresh();
  refs.detailModal.classList.remove('open');
  refs.detailModal.classList.remove('energy-mode');
  refs.detailModal.classList.remove('history-mode');
  popModalIfTop('detail');
  queueNextPoll(POLL_MIN_DELAY_MS);
}

// 仅夹取 [min,max] 并取整, 不吸附 step —— 预设/手输需保留 27386 等非整步原厂值;
// step 吸附交给滑块 (<input type=range step>) 的原生行为
function clampSwapValue(key, raw) {
  const limit = SWAP_LIMITS[key];
  let value = Number(raw);
  if (!Number.isFinite(value)) value = SWAP_OPTIMIZED[key];
  return Math.min(limit.max, Math.max(limit.min, Math.round(value)));
}

// 用滑块吸附后的实际 value 算填充百分比, 让填充轨道与 thumb 位置严格一致
function updateSwapFill(key) {
  const el = refs.swapTuneInputs[key];
  const limit = SWAP_LIMITS[key];
  const pct = ((Number(el.value) - limit.min) / (limit.max - limit.min)) * 100;
  el.style.setProperty('--fill', `${Math.max(0, Math.min(100, pct))}%`);
}

function setSwapTuneValues(values) {
  Object.keys(SWAP_LIMITS).forEach((key) => {
    const value = clampSwapValue(key, values && values[key]);
    refs.swapTuneInputs[key].value = String(value);
    refs.swapTuneNumbers[key].value = String(value);
    refs.swapTuneValues[key].textContent = String(value);
    updateSwapFill(key);
  });
}

function getSwapTuneValues() {
  const values = {};
  Object.keys(SWAP_LIMITS).forEach((key) => {
    values[key] = clampSwapValue(key, refs.swapTuneNumbers[key].value);
  });
  return values;
}

function syncSwapTuneField(key, raw) {
  const value = clampSwapValue(key, raw);
  refs.swapTuneInputs[key].value = String(value);
  refs.swapTuneNumbers[key].value = String(value);
  refs.swapTuneValues[key].textContent = String(value);
  updateSwapFill(key);
}

function openSwapTuneModal() {
  const current = state.swapData || SWAP_OPTIMIZED;
  setSwapTuneValues({
    swappiness: current.swappiness,
    min_free_kbytes: current.min_free_kbytes,
    watermark_scale_factor: current.watermark_scale_factor,
    vfs_cache_pressure: current.vfs_cache_pressure
  });
  refs.swapTuneModal.classList.add('open');
  pushModalState('swapTune');
  queueNextPoll(computeNextPollDelay());
}

function closeSwapTuneModal() {
  refs.swapTuneModal.classList.remove('open');
  popModalIfTop('swapTune');
  queueNextPoll(POLL_MIN_DELAY_MS);
}

function stopTempChartRefresh() {
  const wasActive = Boolean(state.tempChart.draw);
  if (state.tempChart.timer) {
    clearTimeout(state.tempChart.timer);
    state.tempChart.timer = null;
  }
  state.tempChart.draw = null;
  state.tempChart.requestId += 1;
  if (wasActive) stopThermalBurst();
}

function pauseTempChartRefresh() {
  const wasActive = Boolean(state.tempChart.draw);
  if (state.tempChart.timer) {
    clearTimeout(state.tempChart.timer);
    state.tempChart.timer = null;
  }
  state.tempChart.requestId += 1;
  if (wasActive) stopThermalBurst();
}

function abortEnergyDetailRequest(reason = 'page-hidden') {
  if (state.energyDetail.requestController) {
    state.energyDetail.requestController.abort(reason);
    state.energyDetail.requestController = null;
  }
  state.energyDetail.requestKind = '';
}

function stopEnergyDetailRefresh() {
  if (state.energyDetail.timer) {
    clearTimeout(state.energyDetail.timer);
    state.energyDetail.timer = null;
  }
  if (state.energyDetail.fullTimer) {
    clearTimeout(state.energyDetail.fullTimer);
    state.energyDetail.fullTimer = null;
  }
  abortEnergyDetailRequest('detail-closed');
  state.energyDetail.requestId += 1;
  state.energyDetail.renderSignature = '';
}

function pauseEnergyDetailRefresh() {
  if (state.energyDetail.timer) {
    clearTimeout(state.energyDetail.timer);
    state.energyDetail.timer = null;
  }
  if (state.energyDetail.fullTimer) {
    clearTimeout(state.energyDetail.fullTimer);
    state.energyDetail.fullTimer = null;
  }
  abortEnergyDetailRequest('page-hidden');
  state.energyDetail.requestId += 1;
}

function scheduleTempChartRefresh(delay = TEMP_CHART_REFRESH_MS) {
  if (state.tempChart.timer) clearTimeout(state.tempChart.timer);
  if (!isWebUiActive() || !refs.detailModal.classList.contains('open') || !state.tempChart.draw) return;
  state.tempChart.timer = window.setTimeout(async () => {
    state.tempChart.timer = null;
    if (!isWebUiActive() || !refs.detailModal.classList.contains('open') || !state.tempChart.draw) return;
    try {
      await state.tempChart.draw(state.tempChart.activeRange, { silent: true });
    } catch (_) {}
    scheduleTempChartRefresh();
  }, delay);
}

function errorBlock(msg) {
  const el = document.createElement('div');
  el.className = 'note-body';
  el.style.cssText = 'color:var(--danger)';
  el.textContent = msg;
  return el;
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;'
  }[ch]));
}

function showToast(msg, dur = 2500, type = '') {
  const el = document.createElement('div');
  el.className = 'toast';
  // 显式 type 优先; 否则对明确失败措辞自动上 err 状态色 (成功/中性保持沉稳反白)
  if (!type && /失败|无效|错误|出错|超时/.test(msg)) type = 'err';
  if (type) el.classList.add(type);
  el.textContent = msg;
  refs.toastWrap.appendChild(el);
  window.setTimeout(() => {
    el.classList.add('out');
    el.addEventListener('animationend', () => el.remove(), { once: true });
    window.setTimeout(() => { if (el.isConnected) el.remove(); }, 400);
  }, dur);
}

function appendLog(text, type = '') {
  if (refs.logInner.querySelector('.log-dim:only-child')) refs.logInner.replaceChildren();
  const row = document.createElement('div');
  if (type) row.className = `log-${type}`;
  row.textContent = `[${new Date().toLocaleTimeString()}] ${text}`;
  refs.logInner.appendChild(row);
  while (refs.logInner.childNodes.length > 30) refs.logInner.removeChild(refs.logInner.firstChild);
  refs.logInner.scrollTop = refs.logInner.scrollHeight;
}

function setWebuiToken(token) {
  const clean = String(token || '').trim();
  if (!/^[A-Za-z0-9._:-]{8,128}$/.test(clean)) return false;
  state.webuiToken = clean;
  sessionStorage.setItem(STORAGE_TOKEN_KEY, clean);
  return true;
}

function clearWebuiToken() {
  state.webuiToken = '';
  sessionStorage.removeItem(STORAGE_TOKEN_KEY);
}

function loadWebuiTokenFromSession() {
  const fromHash = new URLSearchParams(location.hash.replace(/^#/, '')).get('token');
  if (fromHash && setWebuiToken(fromHash)) {
    history.replaceState(null, '', `${location.pathname}${location.search}`);
    return;
  }
  const saved = sessionStorage.getItem(STORAGE_TOKEN_KEY);
  if (saved) setWebuiToken(saved);
}

async function fetchWebuiTokenForPrompt() {
  try {
    const data = await apiFetch(API.auth, { timeoutMs: 4000 });
    const token = String(data?.token || '').trim();
    return /^[A-Za-z0-9._:-]{8,128}$/.test(token) ? token : '';
  } catch (_) {
    return '';
  }
}

async function ensureWebuiToken() {
  if (state.webuiToken) return true;
  // auth.sh 经 loopback 自由提供 token（能 POST 必能 GET），读到即静默采用，不弹窗。
  const serverToken = await fetchWebuiTokenForPrompt();
  if (serverToken && setWebuiToken(serverToken)) return true;
  // 仅当 auth.sh 取不到 token 时（token 文件缺失/服务异常）才回退手动输入。
  const message = '无法自动读取 WebUI token，请手动输入\n\n获取方式: root shell 执行\ncat /data/adb/modules/pixel9pro_control/.webui_token\n\n也可打开 http://127.0.0.1:6210/#token=<token> 完成会话配对';
  const token = window.prompt(message, '');
  if (!setWebuiToken(token)) {
    showToast('缺少或无效的 WebUI token');
    return false;
  }
  return true;
}

// 会话无 token 时后台静默预取（auth.sh loopback），使首个写操作零延迟、零弹窗。
function prefetchWebuiToken() {
  fetchWebuiTokenForPrompt()
    .then((t) => { if (t && !state.webuiToken) setWebuiToken(t); })
    .catch(() => {});
}

async function apiFetch(path, opts = {}) {
  const controller = opts.controller || new AbortController();
  const timeoutMs = opts.timeoutMs || 8000;
  const timeoutId = window.setTimeout(() => controller.abort(), timeoutMs);
  const headers = { ...(opts.headers || {}) };
  const method = (opts.method || 'GET').toUpperCase();
  if (method !== 'GET') {
    if (!(await ensureWebuiToken())) throw new Error('missing WebUI token');
    headers['X-PIXEL9PRO-TOKEN'] = state.webuiToken;
  } else if (state.webuiToken) {
    headers['X-PIXEL9PRO-TOKEN'] = state.webuiToken;
  }
  const request = { cache: 'no-store', ...opts, headers, signal: controller.signal };
  delete request.timeoutMs;
  delete request.controller;
  let response;
  try {
    response = await fetch(path, request);
  } catch (err) {
    if (err && err.name === 'AbortError') {
      throw new Error(typeof controller.signal.reason === 'string' ? 'request cancelled' : 'request timeout');
    }
    throw err;
  } finally {
    clearTimeout(timeoutId);
  }
  if (!response.ok) {
    if (response.status === 403 && method !== 'GET') clearWebuiToken();
    throw new Error(response.status === 403 ? 'WebUI token 无效或已过期' : `HTTP ${response.status}`);
  }
  return response.json();
}

function sleep(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function noteUserActivity() {
  state.poller.lastInteractionAt = Date.now();
  if (isWebUiActive() && state.poller.running) queueNextPoll(POLL_MIN_DELAY_MS);
}

function isWebUiActive() {
  return document.visibilityState === 'visible' && !document.hidden && !state.foregroundPaused;
}

function isAnyModalOpen() {
  return Boolean(
    (refs.detailModal && refs.detailModal.classList.contains('open'))
    || (refs.swapTuneModal && refs.swapTuneModal.classList.contains('open'))
    || (refs.themeModal && refs.themeModal.classList.contains('open'))
    || (refs.rebootModal && refs.rebootModal.classList.contains('open'))
  );
}

function isPollingRelaxed() {
  return isAnyModalOpen() || (Date.now() - state.poller.lastInteractionAt) >= WEBUI_IDLE_MS;
}

function getPollInterval(key) {
  const relaxed = isPollingRelaxed();
  switch (key) {
    case 'cpu':
      if (state.currentTab === 'tune') return relaxed ? POLL_INTERVALS.cpu.relaxedPerf : POLL_INTERVALS.cpu.perf;
      if (state.currentTab === 'home') return relaxed ? POLL_INTERVALS.cpu.relaxedHome : POLL_INTERVALS.cpu.home;
      return 0;
    case 'thermal':
      if (state.currentTab === 'tune') return relaxed ? POLL_INTERVALS.thermal.relaxedThermal : POLL_INTERVALS.thermal.thermal;
      if (state.currentTab === 'home') return relaxed ? POLL_INTERVALS.thermal.relaxedHome : POLL_INTERVALS.thermal.home;
      return 0;
    case 'optim':
      if (state.currentTab === 'system') return relaxed ? POLL_INTERVALS.optim.relaxedOptim : POLL_INTERVALS.optim.optim;
      if (state.currentTab === 'home') return relaxed ? POLL_INTERVALS.optim.relaxedHome : POLL_INTERVALS.optim.home;
      return 0;
    case 'slow':
      if (state.currentTab === 'network' || state.currentTab === 'system') return relaxed ? POLL_INTERVALS.slow.relaxedOptim : POLL_INTERVALS.slow.optim;
      if (state.currentTab === 'home') return relaxed ? POLL_INTERVALS.slow.relaxedHome : POLL_INTERVALS.slow.home;
      return 0;
    default:
      return 0;
  }
}

function markPollFresh(keys, at = Date.now()) {
  keys.forEach((key) => { state.poller.lastRun[key] = at; });
}

function computeNextPollDelay(now = Date.now()) {
  const delays = [];
  ['cpu', 'thermal', 'optim', 'slow'].forEach((key) => {
    const interval = getPollInterval(key);
    if (!interval) return;
    delays.push(Math.max(interval - (now - state.poller.lastRun[key]), POLL_MIN_DELAY_MS));
  });
  return delays.length ? Math.min(...delays) : POLL_INTERVALS.slow.relaxedHome;
}

function queueNextPoll(delayMs = POLL_MIN_DELAY_MS) {
  clearTimeout(state.poller.timer);
  state.poller.timer = null;
  if (!state.poller.running || !isWebUiActive()) return;
  state.poller.timer = window.setTimeout(runPollCycle, Math.max(delayMs, POLL_MIN_DELAY_MS));
}

async function runPollCycle() {
  if (!state.poller.running || !isWebUiActive()) return;
  const now = Date.now();
  const jobs = [];

  if (shouldPollCpu() && !state.cpuBusy && (now - state.poller.lastRun.cpu) >= getPollInterval('cpu')) {
    jobs.push({ key: 'cpu', run: () => refreshCpu() });
  }
  if (shouldPollThermal() && !state.thermalBusy && (now - state.poller.lastRun.thermal) >= getPollInterval('thermal')) {
    jobs.push({ key: 'thermal', run: () => refreshThermal() });
  }
  if (shouldPollOptim() && !state.swapLoading && (now - state.poller.lastRun.optim) >= getPollInterval('optim')) {
    jobs.push({ key: 'optim', run: () => refreshSwap() });
  }
  if (shouldPollSlow() && (now - state.poller.lastRun.slow) >= getPollInterval('slow')) {
    jobs.push({
      key: 'slow',
      run: () => Promise.allSettled([refreshNrSwitch(), refreshUecap(), refreshBaseband(), refreshNtp(), refreshStandbyGuard(), refreshBgRestrict(), loadInfo()])
    });
  }

  if (jobs.length) {
    markPollFresh(jobs.map((job) => job.key), now);
    await Promise.allSettled(jobs.map((job) => job.run()));
  }

  queueNextPoll(computeNextPollDelay());
}

let _topbarRafPending = false;
function syncTopbar() {
  if (_topbarRafPending) return;
  _topbarRafPending = true;
  requestAnimationFrame(() => {
    _topbarRafPending = false;
    const page = document.querySelector('.tab-page.active');
    const top = page ? page.scrollTop : 0;
    const compact = refs.topbar.classList.contains('compact');
    // 滞回阈值, 避免临界反复切换; compact 仅控制浅阴影, 不再收缩高度
    if (!compact && top > 24) refs.topbar.classList.add('compact');
    else if (compact && top < 8) refs.topbar.classList.remove('compact');
  });
}

function bindTopbarScroll() {
  document.querySelectorAll('.tab-page').forEach((page) => {
    page.addEventListener('scroll', syncTopbar, { passive: true });
  });
}

function switchTab(tab) {
  if (tab === state.currentTab) return;
  state.currentTab = tab;
  document.querySelectorAll('.tab-page').forEach((page) => page.classList.toggle('active', page.dataset.tab === tab));
  document.querySelectorAll('.tab-item').forEach((item) => item.classList.toggle('active', item.dataset.tab === tab));
  refs.topbarSubtitle.textContent = TAB_META[tab] || '控制台';
  syncTopbar();
  noteUserActivity();
  syncDeviceClockForTab();
  refreshCurrentTabData();
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
  const TRIGGER = 90;
  const hide = () => {
    refs.pullInd.style.transform = 'translateY(-100%)';
    refs.pullInd.classList.remove('active', 'spinning');
  };
  // 顶部锚定刷新条: 按下拉距离从 -100% 滑到 0, 文字态随阈值变化 (非漂浮圆盘)
  const show = (dy) => {
    const p = Math.min(dy / TRIGGER, 1);
    refs.pullInd.style.transform = `translateY(${(-100 + p * 100).toFixed(1)}%)`;
    refs.pullText.textContent = dy >= TRIGGER ? '释放刷新' : '下拉刷新';
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
        if (evt.cancelable) evt.preventDefault();
      } else {
        state.pull.active = false;
        hide();
      }
    }, { passive: false });
    page.addEventListener('touchend', async () => {
      if (!state.pull.active) return;
      state.pull.active = false;
      if (state.pull.dist > TRIGGER && !state.pull.busy) {
        state.pull.busy = true;
        refs.pullInd.classList.add('active', 'spinning');
        refs.pullInd.style.transform = 'translateY(0)';
        refs.pullText.textContent = '正在刷新';
        await doFullRefresh();
        refs.pullText.textContent = '已完成';
        await sleep(400);
        state.pull.busy = false;
      }
      hide();
    }, { passive: true });
  });
}

// 温度色阶 (单一真源): 青绿→黄→橙→红, 语义固定不交动态色 (doc 17 §11)
const TEMP_SCALE = [
  { max: 36, color: '#23a78c' }, // 凉爽
  { max: 40, color: '#4aa95f' }, // 正常
  { max: 44, color: '#bf8b16' }, // 偏热
  { max: 48, color: '#d97c34' }, // 热
  { color: '#c3472d' },          // 过热
];

function tempHex(t) {
  for (const stop of TEMP_SCALE) {
    if (stop.max === undefined || t < stop.max) return stop.color;
  }
  return TEMP_SCALE[TEMP_SCALE.length - 1].color;
}

function tempStatus(t) {
  const modThresh = THRESH_STOCK + (state.currentOffset ?? THRESH_MOD_DEFAULT);
  if (t < 36) return '凉爽';
  if (t < THRESH_STOCK) return '正常';
  if (t < modThresh) return '已高于原厂阈值，当前仍在放宽区间';
  if (t < modThresh + 4) return '系统已开始主动降温';
  if (t < 55) return '温度持续偏高，系统正在加强降温';
  return '温度过高，系统已严格限制性能';
}

function barPct(t) {
  return Math.min(Math.max((t - TEMP_MIN) / (TEMP_MAX - TEMP_MIN), 0), 1) * 100;
}

function positionMarkers() {
  const modThresh = THRESH_STOCK + (state.currentOffset ?? THRESH_MOD_DEFAULT);
  const stockPct = barPct(THRESH_STOCK);
  const modPct = barPct(modThresh);
  refs.mkStock.style.left = `${stockPct}%`;
  refs.mkStockLbl.style.left = `${stockPct}%`;
  refs.mkStockLbl.textContent = `${THRESH_STOCK}°C 原厂`;
  refs.mkMod.style.left = `${modPct}%`;
  refs.mkModLbl.style.left = `${modPct}%`;
  refs.mkModLbl.textContent = state.currentOffset === 0 ? '' : `${modThresh}°C 当前`;
  refs.mkMod.style.display = state.currentOffset === 0 ? 'none' : '';
  refs.mkModLbl.style.display = state.currentOffset === 0 ? 'none' : '';
}

function formatThermalOffset(offset) {
  const value = Number(offset);
  if (!Number.isFinite(value) || value === 0) return '出厂口径';
  return `${value > 0 ? '+' : ''}${value}°C 已启用`;
}

function isThermalZoneValid(zone) {
  if (!zone || typeof zone.zone !== 'string') return false;
  const temp = Number(zone.temp);
  return Number.isFinite(temp) && temp >= 10000 && temp <= 85000;
}

async function readThermalZones({ fresh = false, clear = false } = {}) {
  const path = clear ? API.thermalClear : fresh ? API.thermalFresh : API.thermal;
  const zones = await apiFetch(path, { timeoutMs: fresh || clear ? 8000 : 3500 });
  if (!Array.isArray(zones) || !zones.length) throw new Error('未读取到热区数据');
  const valid = zones.filter(isThermalZoneValid);
  const skin = valid.find((zone) => zone.zone === 'VIRTUAL-SKIN') || valid.find((zone) => zone.zone === 'SKIN');
  if (!skin) throw new Error('VIRTUAL-SKIN 未找到');
  const tempC = skin.temp / 1000;
  if (state.lastSkinTempC !== null && Math.abs(tempC - state.lastSkinTempC) >= 12 && !fresh && !clear) {
    throw new Error('缓存温度跳变，准备校准');
  }
  return valid;
}

function boolValue(value) {
  return value === true || value === 'true' || value === 'yes' || value === 1 || value === '1';
}

function formatSchedValue(value, unit) {
  if (value === null || value === undefined || value === '' || value === 'N/A' || value === 'na') return 'N/A';
  return `${value}${unit}`;
}

function getUperfName() {
  return state.uperfModuleName || state.uperfModuleId || 'Uperf Game Turbo';
}

function getUperfStateText() {
  if (isUperfActive()) return '运行中';
  switch (state.uperfModuleState) {
    case 'disabled': return '已禁用';
    case 'pending_update': return '待重启更新';
    case 'pending_remove': return '待重启移除';
    case 'active': return '已安装';
    default: return state.uperfDetected ? '已安装' : '未检测到';
  }
}

function isUperfEnabled() {
  return state.uperfDetected && state.uperfModuleEnabled === 'yes';
}

function isUperfActive() {
  return state.uperfDetected && (state.uperfActive === 'yes' || state.uperfProcessAlive === 'yes');
}

function getFasRsName() {
  return state.fasRsModuleName || state.fasRsModuleId || 'fas-rs';
}

function getFasRsStateText() {
  switch (state.fasRsRuntimeState || state.fasRsModuleState) {
    case 'disabled_marker': return '已让权';
    case 'disabled': return '已禁用';
    case 'pending_update': return '待重启更新';
    case 'pending_remove': return '待重启移除';
    case 'running': return state.fasRsMode ? `运行中 · ${state.fasRsMode}` : '运行中';
    case 'module_enabled': return '模块启用';
    case 'runtime_present': return '运行目录存在';
    case 'active': return '已安装';
    default: return state.fasRsDetected ? '已检测到' : '未检测到';
  }
}

function isFasRsEnabled() {
  return state.fasRsDetected && (state.fasRsActive === 'yes' || state.fasRsModuleEnabled === 'yes');
}

function isFasRsRuntimeActive() {
  return state.fasRsDetected && (state.fasRsActive === 'yes' || state.fasRsProcessAlive === 'yes');
}

function getExternalSchedulerName() {
  return state.externalSchedulerName || state.externalSchedulerId || (state.fasRsDetected ? getFasRsName() : getUperfName());
}

function getEffectiveSchedulerName() {
  return state.effectiveSchedulerName || getExternalSchedulerName();
}

function getEffectiveSchedulerModeText() {
  return state.effectiveSchedulerMode ? ` · ${state.effectiveSchedulerMode}` : '';
}

function hasExternalScheduler() {
  return state.externalSchedulerDetected || state.uperfDetected || state.fasRsDetected;
}

function isExternalSchedulerActive() {
  return state.externalSchedulerActive || isUperfActive() || isFasRsRuntimeActive();
}

function getExternalSchedulerStateText() {
  if (state.externalSchedulerKind === 'fas_rs') return getFasRsStateText();
  if (state.externalSchedulerKind === 'uperf') return getUperfStateText();
  if (state.externalSchedulerKind === 'multiple') {
    return isExternalSchedulerActive() ? '多个外部调度器可用' : '检测到多个外部调度器';
  }
  switch (state.externalSchedulerState) {
    case 'disabled': return '已禁用';
    case 'pending_update': return '待重启更新';
    case 'pending_remove': return '待重启移除';
    case 'active': return '已安装';
    case 'running': return '运行中';
    default: return hasExternalScheduler() ? '已检测到' : '未检测到';
  }
}

function getSchedulerStatusText() {
  const name = getEffectiveSchedulerName();
  if (state.schedOwner === 'external') {
    if (!hasExternalScheduler()) return '调度让权 · 等待外部调度';
    return isExternalSchedulerActive() ? `${name} 接管${getEffectiveSchedulerModeText()} (${getExternalSchedulerStateText()})` : `${name} ${getExternalSchedulerStateText()}`;
  }
  return hasExternalScheduler() ? `本模块覆盖 ${name}` : 'Pixel 温控模块';
}

function getSchedulerToggleText() {
  if (state.schedOwnerBusy) return '切换中…';
  if (state.schedOwner === 'external') {
    return hasExternalScheduler() ? '本模块覆盖接管' : '启用本模块调度';
  }
  return hasExternalScheduler() ? '不覆盖外部调度' : '停用本模块调度';
}

function getSchedulerExternalDesc() {
  const name = getEffectiveSchedulerName();
  if (hasExternalScheduler()) {
    const owner = isExternalSchedulerActive() ? `CPU 调度交给 ${name}${getEffectiveSchedulerModeText()}` : `检测到 ${name} (${getExternalSchedulerStateText()})`;
    return `${owner}；本模块 profile / policy 仅保留显示与让权状态，不写 CPU 调度节点。`;
  }
  return '未检测到启用中的外部调度器；本模块保持让权状态，不再周期性写 CPU 调度节点。';
}

function getSchedulerPixelDesc() {
  const name = getExternalSchedulerName();
  if (hasExternalScheduler()) {
    return `检测到 ${name}，当前由本模块覆盖接管 CPU 调度。`;
  }
  return '未检测到 UGT / fas-rs 外部调度器，当前由本模块管理 CPU 调度。';
}

function syncOwnerArbiterUi() {
  if (!refs.ownerArbiterRow) return;
  const available = state.fasRsDetected;
  refs.ownerArbiterRow.hidden = !available;
  if (!available) return;
  const active = state.fasRsOwnerState || state.fasRsMode || getFasRsStateText();
  refs.ownerArbiterLabel.textContent = state.ownerArbiterBusy
    ? '正在检查调度接管状态…'
    : `fas-rs ${active || '已检测到'}，可立即检查接管状态`;
  refs.ownerArbiterTickBtn.disabled = state.ownerArbiterBusy;
  refs.ownerArbiterTickLabel.textContent = state.ownerArbiterBusy ? '检查中…' : '立即检查';
}

function syncProfileUi() {
  const profile = PROFILES[state.currentProfile] || PROFILES.unknown;
  const isAuto = state.profilePolicy === 'auto';
  const isExternal = state.schedOwner === 'external';
  const effectiveName = getEffectiveSchedulerName();
  if (isExternal) {
    refs.topbarProfileChip.textContent = hasExternalScheduler() ? (isExternalSchedulerActive() ? `${effectiveName} 接管` : '外部调度未启用') : '调度让权';
    refs.perfCurrentName.textContent = hasExternalScheduler()
      ? (isExternalSchedulerActive() ? `${effectiveName} 接管${getEffectiveSchedulerModeText()}` : `${effectiveName} ${getExternalSchedulerStateText()}`)
      : '本模块让权中';
    refs.perfCurrentDesc.textContent = getSchedulerExternalDesc();
    refs.perfPolicyDesc.textContent = hasExternalScheduler()
      ? '本模块不覆盖 CPU 调度；手动、自动和模式卡片已暂停。'
      : '未检测到启用中的外部调度器；手动、自动和模式卡片已暂停，本模块只保留让权状态。';
    refs.profilePolicyManualBtn.className = 'seg-btn';
    refs.profilePolicyAutoBtn.className = 'seg-btn';
    refs.profilePolicyManualBtn.disabled = true;
    refs.profilePolicyAutoBtn.disabled = true;
    refs.schedOwnerLabel.textContent = getSchedulerStatusText();
    refs.schedOwnerToggleBtn.className = 'tiny-btn primary';
    refs.schedOwnerToggleBtn.disabled = state.schedOwnerBusy;
    refs.schedOwnerToggleLabel.textContent = getSchedulerToggleText();
    refs.hero.className = 'hero-card mode-game';
    setStaticHtml(refs.heroIcon, PROFILES.performance.hero);
    refs.heroMode.textContent = hasExternalScheduler() ? (isExternalSchedulerActive() ? `${effectiveName} 接管` : '外部调度未启用') : '调度停用';
    document.querySelectorAll('.profile-option').forEach((card) => {
      card.classList.remove('selected');
      card.classList.add('disabled');
    });
    syncOwnerArbiterUi();
    return;
  }
  refs.topbarProfileChip.textContent = isAuto ? `${profile.name} · 自动` : profile.name;
  refs.perfCurrentName.textContent = isAuto ? `${profile.name} · 自动` : profile.name;
  refs.perfCurrentDesc.textContent = isAuto ? `${profile.desc} · ${describeAutoReason(state.autoReason)}` : profile.desc;
  const pixelPolicyDesc = isAuto
    ? `自动模式：按“${describeAutoReason(state.autoReason)}”在均衡与省电间切换；点击模式卡片转为手动。`
    : `手动模式：固定为「${profile.name}」；切换为自动后，仅在温度持续偏高时收口至省电。`;
  refs.perfPolicyDesc.textContent = hasExternalScheduler() ? `${pixelPolicyDesc} ${getSchedulerPixelDesc()}` : pixelPolicyDesc;
  refs.profilePolicyManualBtn.className = `seg-btn${!isAuto ? ' active' : ''}`;
  refs.profilePolicyAutoBtn.className = `seg-btn${isAuto ? ' active' : ''}`;
  refs.profilePolicyManualBtn.disabled = state.profilePolicyBusy;
  refs.profilePolicyAutoBtn.disabled = state.profilePolicyBusy;
  refs.schedOwnerLabel.textContent = getSchedulerStatusText();
  refs.schedOwnerToggleBtn.className = 'tiny-btn';
  refs.schedOwnerToggleBtn.disabled = state.schedOwnerBusy;
  refs.schedOwnerToggleLabel.textContent = getSchedulerToggleText();
  refs.hero.className = `hero-card ${profile.modeClass}`;
  setStaticHtml(refs.heroIcon, profile.hero);
  refs.heroMode.textContent = isAuto ? `${profile.name} · 自动` : profile.name;
  document.querySelectorAll('.profile-option').forEach((card) => {
    card.classList.remove('disabled');
    card.classList.toggle('selected', card.dataset.profile === state.currentProfile);
  });
  syncOwnerArbiterUi();
}

function describeAutoReason(reason) {
  switch (reason) {
    case 'auto_balanced': return '自动均衡运行中';
    case 'steady_hot_guard': return '持续热平台，已压到省电';
    case 'hot_cooldown': return '热平台已回落，恢复均衡';
    case 'screen_off_reset': return '已息屏，恢复均衡';
    case 'deep_standby_reset': return '深度待机，恢复均衡';
    case 'charging_no_throttle': return '充电温度舒适，保持均衡';
    case 'charging_thermal_mitigation': return '充电温控介入，已压到省电';
    case 'charging_comfort_hot': return '充电体感偏热，已压到省电';
    case 'charging_comfort_cooldown': return '充电温度回落，恢复均衡';
    case 'auto_enabled': return '已启用自动调度';
    case 'manual_policy': return '切回手动';
    case 'manual_selected': return '手动指定模式';
    case 'external_scheduler': return '外部调度让权';
    case 'external_no_scheduler_sanitized': return '外部调度让权';
    default: return '自动调度运行中';
  }
}

function applyProfileState(data) {
  state.currentProfile = PROFILES[data.profile] ? data.profile : 'unknown';
  state.manualProfile = PROFILES[data.manual_profile] ? data.manual_profile : state.currentProfile;
  state.profilePolicy = data.policy === 'auto' ? 'auto' : 'manual';
  state.schedOwner = data.sched_owner === 'external' ? 'external' : 'pixel';
  state.uperfDetected = boolValue(data.uperf_detected);
  state.uperfModuleId = typeof data.uperf_module_id === 'string' ? data.uperf_module_id : '';
  state.uperfModuleName = typeof data.uperf_module_name === 'string' ? data.uperf_module_name : '';
  state.uperfModulePath = typeof data.uperf_module_path === 'string' ? data.uperf_module_path : '';
  state.uperfModuleSource = typeof data.uperf_module_source === 'string' ? data.uperf_module_source : '';
  state.uperfModuleState = typeof data.uperf_module_state === 'string' ? data.uperf_module_state : '';
  state.uperfModuleEnabled = typeof data.uperf_module_enabled === 'string' ? data.uperf_module_enabled : 'no';
  state.uperfProcessAlive = typeof data.uperf_process_alive === 'string' ? data.uperf_process_alive : 'no';
  state.uperfActive = typeof data.uperf_active === 'string' ? data.uperf_active : 'no';
  state.fasRsDetected = boolValue(data.fas_rs_detected);
  state.fasRsModuleId = typeof data.fas_rs_module_id === 'string' ? data.fas_rs_module_id : '';
  state.fasRsModuleName = typeof data.fas_rs_module_name === 'string' ? data.fas_rs_module_name : '';
  state.fasRsModulePath = typeof data.fas_rs_module_path === 'string' ? data.fas_rs_module_path : '';
  state.fasRsModuleSource = typeof data.fas_rs_module_source === 'string' ? data.fas_rs_module_source : '';
  state.fasRsModuleState = typeof data.fas_rs_module_state === 'string' ? data.fas_rs_module_state : '';
  state.fasRsModuleEnabled = typeof data.fas_rs_module_enabled === 'string' ? data.fas_rs_module_enabled : 'no';
  state.fasRsOwnerState = typeof data.fas_rs_owner_state === 'string' ? data.fas_rs_owner_state : '';
  state.fasRsMode = typeof data.fas_rs_mode === 'string' ? data.fas_rs_mode : '';
  state.fasRsProcessAlive = typeof data.fas_rs_process_alive === 'string' ? data.fas_rs_process_alive : 'no';
  state.fasRsRuntimeState = typeof data.fas_rs_runtime_state === 'string' ? data.fas_rs_runtime_state : '';
  state.fasRsActive = typeof data.fas_rs_active === 'string' ? data.fas_rs_active : 'no';
  state.externalSchedulerDetected = boolValue(data.external_scheduler_detected);
  state.externalSchedulerActive = boolValue(data.external_scheduler_active);
  state.externalSchedulerId = typeof data.external_scheduler_id === 'string' ? data.external_scheduler_id : '';
  state.externalSchedulerName = typeof data.external_scheduler_name === 'string' ? data.external_scheduler_name : '';
  state.externalSchedulerKind = typeof data.external_scheduler_kind === 'string' ? data.external_scheduler_kind : '';
  state.externalSchedulerPath = typeof data.external_scheduler_path === 'string' ? data.external_scheduler_path : '';
  state.externalSchedulerSource = typeof data.external_scheduler_source === 'string' ? data.external_scheduler_source : '';
  state.externalSchedulerState = typeof data.external_scheduler_state === 'string' ? data.external_scheduler_state : '';
  state.externalSchedulerEnabled = typeof data.external_scheduler_enabled === 'string' ? data.external_scheduler_enabled : 'no';
  state.effectiveSchedulerOwner = typeof data.effective_scheduler_owner === 'string' ? data.effective_scheduler_owner : 'pixel';
  state.effectiveSchedulerName = typeof data.effective_scheduler_name === 'string' ? data.effective_scheduler_name : '';
  state.effectiveSchedulerKind = typeof data.effective_scheduler_kind === 'string' ? data.effective_scheduler_kind : '';
  state.effectiveSchedulerMode = typeof data.effective_scheduler_mode === 'string' ? data.effective_scheduler_mode : '';
  state.profileSurface = typeof data.profile_surface === 'string' ? data.profile_surface : 'authoritative';
  state.profileSurfaceStale = boolValue(data.profile_surface_stale);
  state.profileSurfaceNote = typeof data.profile_surface_note === 'string' ? data.profile_surface_note : '';
  state.autoReason = typeof data.auto_reason === 'string' ? data.auto_reason : '';
  syncProfileUi();
  syncHeroDesc();
}

function syncHeroDesc() {
  const parts = [];
  const preset = THERMAL_PRESETS[state.currentOffset];
  if (preset) parts.push(preset.name);
  if (state.schedOwner === 'external') parts.push(hasExternalScheduler() ? (isExternalSchedulerActive() ? '外部调度接管' : '外部调度未启用') : '调度停用');
  else if (hasExternalScheduler()) parts.push('覆盖外部调度');
  if (state.swapMode === 'optimized') parts.push('内存已优化');
  else if (state.swapMode === 'stock') parts.push('内存默认');
  refs.heroDesc.textContent = parts.join(' · ') || '正在读取配置…';
}

function syncThermalUi() {
  const preset = THERMAL_PRESETS[state.currentOffset] || THERMAL_PRESETS[4];
  refs.topbarThermalChip.textContent = `温控 ${preset.name}`;
  refs.thermalCurrentName.textContent = preset.name;
  refs.thermalCurrentDesc.textContent = preset.summary;
  const label = formatThermalOffset(state.currentOffset);
  [refs.homeModBadge, refs.thModBadge].forEach((el) => {
    el.textContent = label;
    el.className = `badge ${state.currentOffset === 0 ? 'off' : 'default'}`;
  });
  document.querySelectorAll('.thermal-option').forEach((card) => {
    card.classList.toggle('selected', Number(card.dataset.offset) === state.currentOffset);
  });
  positionMarkers();
}

function renderProfileCards() {
  refs.profileList.replaceChildren();
  ['battery', 'balanced', 'default'].forEach((key) => {
    const p = PROFILES[key];
    const card = document.createElement('article');
    card.className = 'profile-card profile-option';
    card.dataset.profile = key;
    card.tabIndex = 0;
    setStaticHtml(card, `
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
      </div>`);
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
  refs.thermalList.replaceChildren();
  [-2, 0, 2, 4, 6].forEach((offset) => {
    const preset = THERMAL_PRESETS[offset];
    const card = document.createElement('article');
    card.className = 'profile-card thermal-option';
    card.dataset.offset = String(offset);
    card.tabIndex = 0;
    setStaticHtml(card, `
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
      </div>`);
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
  refs.swapRows.replaceChildren();
  const ratio = data.zram_orig_bytes > 0 ? ((data.zram_compr_bytes / data.zram_orig_bytes) * 100).toFixed(1) : '—';
  const isEH = data.zram_algo === 'lz77eh';
  const sizeGB = (data.zram_disksize / 1073741824).toFixed(1);
  refs.swapDesc.textContent = isEH
    ? `Emerald Hill 硬件压缩 · 压缩率 ${ratio}% · 实占 ${fmtBytes(data.zram_mem_used_bytes)}`
    : `算法 ${data.zram_algo} · 重启后自动切换为 lz77eh`;
  const rows = [
    { label: 'ZRAM 算法', value: isEH ? '硬件加速' : data.zram_algo, cls: isEH ? 'good' : 'warn' },
    { label: 'ZRAM 大小', value: `${sizeGB}GB`, cls: Math.abs(data.zram_disksize - 11945377792) < 536870912 ? 'good' : 'off' },
    { label: 'swappiness', value: String(data.swappiness), cls: data.swappiness === SWAP_OPTIMIZED.swappiness ? 'good' : data.swappiness === SWAP_STOCK.swappiness ? 'warn' : 'off' },
    { label: 'min_free_kbytes', value: String(data.min_free_kbytes), cls: data.min_free_kbytes === SWAP_OPTIMIZED.min_free_kbytes ? 'good' : data.min_free_kbytes === SWAP_STOCK.min_free_kbytes ? 'warn' : 'off' },
    { label: 'watermark_scale_factor', value: String(data.watermark_scale_factor || 0), cls: data.watermark_scale_factor === SWAP_OPTIMIZED.watermark_scale_factor ? 'good' : data.watermark_scale_factor === SWAP_STOCK.watermark_scale_factor ? 'warn' : 'off' },
    { label: 'vfs_cache_pressure', value: String(data.vfs_cache_pressure), cls: data.vfs_cache_pressure === SWAP_OPTIMIZED.vfs_cache_pressure ? 'good' : data.vfs_cache_pressure === SWAP_STOCK.vfs_cache_pressure ? 'warn' : 'off' }
  ];
  rows.forEach((row) => refs.swapRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
}


function ensureHomeCpuRows(clusters) {
  if (state.homeCpuRows && state.homeCpuRows.length === clusters.length) return;
  refs.homeCpuRows.replaceChildren();
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
  refs.cpuRows.replaceChildren();
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
  container.replaceChildren();
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
    const deviceModel = data.model || '—';
    refs.infoModel.textContent = deviceModel;
    refs.infoAndroid.textContent = data.version ? `Android ${data.version}` : '—';
    refs.infoKernel.textContent = data.kernel || '—';
    refs.infoModule.textContent = data.module_version || '—';
    refs.topbarKicker.textContent = data.module_version
      ? `${deviceModel} · UI ${data.module_version}`
      : `${deviceModel} · UI`;
    const basebandCard = $('baseband-card');
    if (basebandCard) basebandCard.hidden = deviceModel !== 'Pixel 9 Pro';
    refs.rtWebuiMem.textContent = data.httpd_rss_kb
      ? data.httpd_rss_kb < 1024 ? `${data.httpd_rss_kb}KB` : `${(data.httpd_rss_kb / 1024).toFixed(1)}MB`
      : '—';
    // 内存与系统信息 → loadInfo 写入, refreshSwap 写入 ZRAM 部分
    const fmtKB = (kb) => {
      if (!kb || kb <= 0) return '—';
      return kb >= 1048576 ? `${(kb / 1048576).toFixed(1)}GB` : kb >= 1024 ? `${(kb / 1024).toFixed(0)}MB` : `${kb}KB`;
    };
    if (data.mem_total_kb > 0) refs.rtMemTotal.textContent = fmtKB(data.mem_total_kb);
    if (data.mem_avail_kb > 0) refs.rtMemAvail.textContent = fmtKB(data.mem_avail_kb);
    if (data.swap_free_kb > 0 || data.swap_total_kb > 0) {
      refs.rtSwapFree.textContent = `${fmtKB(data.swap_free_kb)} / ${fmtKB(data.swap_total_kb)}`;
    }
    if (data.uptime_sec > 0) {
      const h = Math.floor(data.uptime_sec / 3600);
      const m = Math.floor((data.uptime_sec % 3600) / 60);
      refs.rtUptime.textContent = h > 0 ? `${h}小时${m}分` : `${m}分钟`;
    }
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
    applyProfileState(data);
  } catch (_) {
    state.currentProfile = 'unknown';
    state.manualProfile = 'balanced';
    state.profilePolicy = 'manual';
    state.schedOwner = 'pixel';
    state.uperfDetected = false;
    state.uperfModuleId = '';
    state.uperfModuleName = '';
    state.uperfModulePath = '';
    state.uperfModuleSource = '';
    state.uperfModuleState = '';
    state.uperfModuleEnabled = 'no';
    state.uperfProcessAlive = 'no';
    state.uperfActive = 'no';
    state.fasRsDetected = false;
    state.fasRsModuleId = '';
    state.fasRsModuleName = '';
    state.fasRsModulePath = '';
    state.fasRsModuleSource = '';
    state.fasRsModuleState = '';
    state.fasRsModuleEnabled = 'no';
    state.fasRsOwnerState = '';
    state.fasRsMode = '';
    state.fasRsProcessAlive = 'no';
    state.fasRsRuntimeState = '';
    state.fasRsActive = 'no';
    state.externalSchedulerDetected = false;
    state.externalSchedulerActive = false;
    state.externalSchedulerId = '';
    state.externalSchedulerName = '';
    state.externalSchedulerKind = '';
    state.externalSchedulerPath = '';
    state.externalSchedulerSource = '';
    state.externalSchedulerState = '';
    state.externalSchedulerEnabled = 'no';
    state.effectiveSchedulerOwner = 'pixel';
    state.effectiveSchedulerName = 'Pixel9Pro-Control';
    state.effectiveSchedulerKind = 'pixel';
    state.effectiveSchedulerMode = '';
    state.profileSurface = 'authoritative';
    state.profileSurfaceStale = false;
    state.profileSurfaceNote = '';
    state.autoReason = '';
    syncProfileUi();
    syncHeroDesc();
  }
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
  if (refs.refreshBtn) refs.refreshBtn.disabled = true;
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
      const respText = typeof cluster.resp_ms_text === 'string' ? cluster.resp_ms_text : cluster.resp_ms;
      const downText = typeof cluster.down_us_text === 'string' ? cluster.down_us_text : cluster.down_us;
      perf.params.textContent = `resp=${formatSchedValue(respText, 'ms')} · down=${formatSchedValue(downText, 'µs')} · gov=${cluster.gov}`;
      home.freq.textContent = !cluster.cur || Number.isNaN(cluster.cur) ? '—' : `${(cluster.cur / 1000).toFixed(0)} MHz`;
      home.fill.style.transform = `scaleX(${!cluster.cur ? 0 : Math.min(cluster.cur / maxHz, 1).toFixed(3)})`;
    });
    try {
      const profileData = await apiFetch(API.profile, { timeoutMs: 4000 });
      applyProfileState(profileData);
    } catch (_) {}
  } catch (err) {
    state.cpuRows = null;
    state.homeCpuRows = null;
    const el = document.createElement('div');
    el.className = 'note-body';
    el.style.color = 'var(--danger)';
    el.textContent = '获取频率失败：' + err.message;
    refs.cpuRows.replaceChildren();
    refs.cpuRows.appendChild(el);
  } finally {
    if (refs.refreshBtn) refs.refreshBtn.disabled = false;
    state.cpuBusy = false;
  }
}

async function refreshThermal() {
  if (state.thermalBusy) return;
  state.thermalBusy = true;
  try {
    let zones;
    try {
      zones = await readThermalZones();
    } catch (_) {
      state.thermalBadReads += 1;
      zones = await readThermalZones({ fresh: true });
    }
    if (state.thermalBadReads >= 2) {
      try { zones = await readThermalZones({ clear: true }); } catch (_) {}
    }
    const skin = zones.find((zone) => zone.zone === 'VIRTUAL-SKIN') || zones.find((zone) => zone.zone === 'SKIN');
    const secondary = zones.filter((zone) => zone !== skin && ['soc_therm', 'battery', 'charging_therm', 'btmspkr_therm'].includes(zone.zone));
    refs.homeThermalSkel.hidden = true;
    refs.homeThermalContent.hidden = false;
    refs.thermalSkel.hidden = true;
    refs.thermalContent.hidden = false;
    if (skin) {
      const tempC = skin.temp / 1000;
      state.lastSkinTempC = tempC;
      state.thermalBadReads = 0;
      const color = tempHex(tempC);
      refs.homeTempNum.textContent = tempC.toFixed(1);
      refs.homeTempNum.style.color = color;
      refs.homeTempStatus.textContent = tempStatus(tempC);
      refs.homeTempStatus.style.color = color;
      refs.tempNum.textContent = tempC.toFixed(1);
      refs.tempNum.style.color = color;
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
    state.swapData = data;
    refs.swapToggleLabel.textContent = state.swapMode === 'optimized' ? '恢复原厂' : '应用模块默认';
    renderSwapCard(data);
    refs.rtZramUsage.textContent = `${data.zram_disksize > 0 ? ((data.zram_orig_bytes / data.zram_disksize) * 100).toFixed(0) : '0'}% (${fmtBytes(data.zram_orig_bytes)} / ${(data.zram_disksize / 1073741824).toFixed(1)}GB)`;
    refs.rtRatio.textContent = data.zram_orig_bytes > 0 ? `${((data.zram_compr_bytes / data.zram_orig_bytes) * 100).toFixed(1)}% → 实占 ${fmtBytes(data.zram_mem_used_bytes)}` : '—';
    syncHeroDesc();
  } catch (err) {
    refs.swapRows.replaceChildren(); refs.swapRows.appendChild(errorBlock('获取失败：' + err.message));
  } finally {
    state.swapLoading = false;
  }
}


function renderNrSwitchRows(data) {
  refs.nrSwitchRows.replaceChildren();
  const isOn = data.nr_switch === 'on';
  const slot0Raw = data.current_slot0 || String(data.current_mode || '').split(',')[0];
  const modeNum = Number(slot0Raw);
  const settingLte = !Number.isNaN(modeNum) && modeNum < 23;
  const actualRat = String(data.actual_rat || '').toUpperCase();
  const actualKnown = actualRat && actualRat !== 'UNKNOWN';
  const actualLte = actualKnown && actualRat.includes('LTE') && !actualRat.includes('NR');
  const actualNr = actualKnown && actualRat.includes('NR');
  const modeLabel = actualKnown
    ? `${actualRat} · setting ${data.current_mode || 'unknown'}`
    : (Number.isNaN(modeNum) ? (data.current_mode || 'unknown') : (settingLte ? `LTE setting (${data.current_mode})` : `NR setting (${data.current_mode})`));
  const rows = [
    { label: '功能状态', value: isOn ? '已开启' : '已关闭', cls: isOn ? 'good' : 'off' },
    { label: '当前网络模式', value: modeLabel, cls: actualLte || (!actualKnown && settingLte) ? 'warn' : actualNr ? 'good' : 'off' },
    { label: '恢复用 NR 模式值', value: data.saved_nr_mode, cls: 'off' }
  ];
  rows.forEach((row) => refs.nrSwitchRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
  refs.nrSwitchToggleLabel.textContent = isOn ? '关闭' : '开启';
  refs.nrSwitchDesc.textContent = isOn
    ? '已开启：息屏后切换至 LTE，亮屏自动恢复 5G。'
    : '息屏 5 分钟后切换至 LTE，亮屏自动恢复。';
}

function syncStandbyGuardButtons() {
  refs.sim2AutoToggleBtn.disabled = state.standbyGuardBusy;
  refs.idleIsolateToggleBtn.disabled = state.standbyGuardBusy;
}

function standbyWorkerModeLabel(mode) {
  if (mode === 'screen_on') return '亮屏全量';
  if (mode === 'thermal_burst') return '温度突发';
  if (mode === 'deep_standby') return '深待机';
  if (mode === 'idle_isolate') return '待机隔离';
  return '未知';
}

function standbyWorkerModeClass(mode) {
  if (mode === 'screen_on' || mode === 'deep_standby') return 'good';
  if (mode === 'thermal_burst' || mode === 'idle_isolate') return 'warn';
  return 'off';
}

function formatStandbyTimestamp(value) {
  const ts = Number(value);
  if (!Number.isFinite(ts) || ts <= 0) return '—';
  return new Date(ts * 1000).toLocaleString();
}

function renderStandbyGuard(data) {
  state.sim2AutoManage = data.sim2_auto_manage === 'on' ? 'on' : 'off';
  state.idleIsolateMode = data.idle_isolate_mode === 'on' ? 'on' : 'off';
  state.standbyDiag = {
    updatedAt: data.diag_updated_at || '',
    screen: data.diag_screen || 'unknown',
    workerMode: data.diag_worker_mode || 'unknown',
    nextSleepSecs: data.diag_next_sleep_secs || '',
    burstActive: data.diag_burst_active || '0',
    nrSwitch: data.diag_nr_switch || 'off',
    nrState: data.diag_nr_state || 'unknown',
    profilePolicy: data.diag_profile_policy || 'unknown',
    activeProfile: data.diag_active_profile || 'unknown',
    cycleCount: data.diag_cycle_count || '0',
  };

  const sim2On = state.sim2AutoManage === 'on';
  refs.sim2AutoToggleLabel.textContent = sim2On ? '关闭' : '开启';
  refs.sim2AutoDesc.textContent = sim2On
    ? '已开启：息屏时停用空槽实例，亮屏或插入 SIM2 后自动恢复。'
    : '单卡设备可在息屏时停用空槽实例。双卡设备请保持关闭。';
  refs.sim2AutoRows.replaceChildren();
  [
    { label: '功能状态', value: sim2On ? '已开启' : '已关闭', cls: sim2On ? 'good' : 'off' },
    { label: '实现方式', value: sim2On ? 'set-sim-count 1（减少 Active modem 实例）' : '不操作 modem 实例数', cls: sim2On ? 'good' : 'off' },
    { label: '适用场景', value: sim2On ? '单卡用户 · 副卡槽为空' : '双卡用户 · 两张 SIM 都在使用', cls: 'off' },
  ].forEach((row) => refs.sim2AutoRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));

  const isolateOn = state.idleIsolateMode === 'on';
  refs.idleIsolateToggleLabel.textContent = isolateOn ? '关闭' : '开启';
  refs.idleIsolateDesc.textContent = isolateOn
    ? '已开启：息屏优化已暂停，仅保留最低限度的状态检查。'
    : '暂停模块的息屏优化，用于判断待机异常是否由模块引起。';
  refs.idleIsolateRows.replaceChildren();
  [
    { label: '功能状态', value: isolateOn ? '已开启' : '已关闭', cls: isolateOn ? 'warn' : 'off' },
    { label: '息屏行为', value: isolateOn ? '仅保留 600s 最小唤醒路径，其余全部暂停' : '常规待机 worker 正常运行', cls: isolateOn ? 'warn' : 'good' },
    { label: '使用建议', value: isolateOn ? '仅用于一晚隔离测试，验证后请关闭' : '日常使用保持关闭', cls: 'off' },
  ].forEach((row) => refs.idleIsolateRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));

  refs.standbyDiagRows.replaceChildren();
  if (!state.standbyDiag.updatedAt) {
    refs.standbyDiagRows.appendChild(buildInfoRow('状态文件', '等待后台 worker 首次写入', 'off'));
  } else {
    const nrLabel = state.standbyDiag.nrSwitch === 'on'
      ? (state.standbyDiag.nrState === 'lte' ? 'NR 管理开启 / 当前 LTE' : 'NR 管理开启 / 当前 5G')
      : 'NR 管理关闭';
    const profileLabel = `${state.standbyDiag.profilePolicy === 'auto' ? '自动' : '手动'} / ${state.standbyDiag.activeProfile || 'unknown'}`;
    [
      { label: '最近更新', value: formatStandbyTimestamp(state.standbyDiag.updatedAt), cls: 'off' },
      { label: '当前屏幕', value: state.standbyDiag.screen === 'on' ? '亮屏' : state.standbyDiag.screen === 'off' ? '息屏' : '未知', cls: state.standbyDiag.screen === 'on' ? 'warn' : 'good' },
      { label: 'worker 分支', value: standbyWorkerModeLabel(state.standbyDiag.workerMode), cls: standbyWorkerModeClass(state.standbyDiag.workerMode) },
      { label: '下次复查', value: state.standbyDiag.nextSleepSecs ? `${state.standbyDiag.nextSleepSecs}s` : '—', cls: 'off' },
      { label: 'NR 状态', value: nrLabel, cls: state.standbyDiag.nrState === 'lte' ? 'warn' : 'off' },
      { label: '调度状态', value: profileLabel, cls: 'off' },
      { label: '循环计数', value: state.standbyDiag.cycleCount || '0', cls: 'off' },
    ].forEach((row) => refs.standbyDiagRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
  }

  syncStandbyGuardButtons();
}

function uecapLabel(mode) {
  if (mode === 'balanced') return '国内频段';
  if (mode === 'special') return '全面增强';
  if (mode === 'universal') return 'Google 默认';
  if (mode === 'custom') return '系统原生 / 第三方';
  return '未知';
}

function getUecapModeHash(data, mode) {
  if (!data || !mode) return '';
  return data[`${mode}_hash`] || '';
}

function getUecapVerifyRow(data, requested, active) {
  if (state.uecapVerifyState === 'failed') {
    return {
      label: '配置校验',
      value: state.uecapVerifyMessage || '未在时限内确认，请手动刷新复查',
      cls: 'warn'
    };
  }

  if (state.uecapPendingMode) {
    const label = uecapLabel(state.uecapPendingMode);
    if (state.uecapVerifyState === 'switching') {
      return { label: '配置校验', value: `${label}：切换中`, cls: 'warn' };
    }
    if (state.uecapVerifyState === 'verifying') {
      return { label: '配置校验', value: `${label}：正在校验配置`, cls: 'warn' };
    }
  }

  const expectedHash = getUecapModeHash(data, requested);
  const targetHash = data.target_hash || '';
  const confirmed = requested === active && (!expectedHash || expectedHash === targetHash);
  return {
    label: '配置校验',
    value: confirmed ? '已确认' : '待确认',
    cls: confirmed ? 'good' : 'warn'
  };
}

function renderUecapBtnGroup(activeMode) {
  const selectedMode = state.uecapPendingMode || activeMode;
  refs.uecapBtnGroup.replaceChildren();
  UECAP_MODES.forEach((m) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    const isSelected = m.id === selectedMode;
    const isPending = state.uecapBusy && m.id === state.uecapPendingMode;
    btn.className = `uecap-btn${isSelected ? ' active' : ''}${isPending ? ' pending' : ''}${isPending && state.uecapVerifyState === 'verifying' ? ' verifying' : ''}`;
    btn.dataset.mode = m.id;
    btn.textContent = isPending
      ? (state.uecapVerifyState === 'switching' ? '切换中...' : '校验中...')
      : m.name;
    btn.disabled = state.uecapBusy;
    btn.addEventListener('click', () => setUecapMode(m.id));
    refs.uecapBtnGroup.appendChild(btn);
  });
}

function renderUecapRows(data) {
  refs.uecapRows.replaceChildren();
  const requested = data.requested_mode || state.uecapMode || 'special';
  const active = data.active_mode || 'custom';
  state.uecapMode = requested;
  state.uecapActiveMode = active;
  const modeInfo = UECAP_MODES.find((m) => m.id === requested);
  refs.uecapDesc.textContent = state.uecapPendingMode
    ? `${uecapLabel(state.uecapPendingMode)}：已提交切换，正在校验当前配置。`
    : modeInfo ? `${modeInfo.desc} · 切换后自动校验配置是否生效。` : '选择 UE 能力配置，切换后会自动校验是否生效。';
  renderUecapBtnGroup(requested);
  const verifyRow = getUecapVerifyRow(data, requested, active);
  const rows = [
    { label: '已选配置', value: uecapLabel(requested), cls: requested === active ? 'good' : 'off' },
    { label: '当前配置', value: uecapLabel(active), cls: active === requested ? 'good' : 'warn' },
    verifyRow,
    { label: '配置摘要', value: (data.target_hash || 'unknown').slice(0, 12), cls: 'off' },
  ];
  rows.forEach((row) => refs.uecapRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
}

async function refreshNrSwitch() {
  try {
    const data = await apiFetch(API.nrSwitch, { timeoutMs: 6000 });
    state.nrSwitch = data.nr_switch || 'off';
    renderNrSwitchRows(data);
  } catch (err) {
    refs.nrSwitchRows.replaceChildren(); refs.nrSwitchRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

async function refreshUecap() {
  try {
    const data = await apiFetch(API.uecap, { timeoutMs: 6000 });
    state.uecapMode = data.requested_mode || 'special';
    state.uecapActiveMode = data.active_mode || 'custom';
    const expectedHash = getUecapModeHash(data, state.uecapMode);
    if (!state.uecapPendingMode && state.uecapVerifyState === 'failed' && state.uecapMode === state.uecapActiveMode && (!expectedHash || expectedHash === data.target_hash)) {
      state.uecapVerifyState = 'idle';
      state.uecapVerifyMessage = '';
    }
    renderUecapRows(data);
  } catch (err) {
    refs.uecapRows.replaceChildren(); refs.uecapRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

async function refreshStandbyGuard() {
  try {
    const data = await apiFetch(API.standbyGuard, { timeoutMs: 6000 });
    renderStandbyGuard(data);
  } catch (err) {
    refs.sim2AutoRows.replaceChildren(); refs.sim2AutoRows.appendChild(errorBlock('获取失败：' + err.message));
    refs.idleIsolateRows.replaceChildren(); refs.idleIsolateRows.appendChild(errorBlock('获取失败：' + err.message));
    refs.standbyDiagRows.replaceChildren(); refs.standbyDiagRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

async function setStandbyGuard(update, successText, logText) {
  if (state.standbyGuardBusy) return;
  state.standbyGuardBusy = true;
  syncStandbyGuardButtons();
  try {
    const data = await apiFetch(API.standbyGuard, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(update),
      timeoutMs: 8000
    });
    if (data.ok) {
      renderStandbyGuard(data);
      showToast(successText);
      appendLog(logText, 'ok');
    } else {
      showToast(`操作失败：${data.error || '未知'}`);
    }
  } catch (_) {
    showToast('请求失败');
  } finally {
    state.standbyGuardBusy = false;
    syncStandbyGuardButtons();
  }
}

async function toggleSim2AutoManage() {
  const next = state.sim2AutoManage === 'on' ? 'off' : 'on';
  await setStandbyGuard(
    { sim2_auto_manage: next },
    next === 'on' ? 'SIM2 自动管理已开启' : 'SIM2 自动管理已关闭',
    next === 'on' ? 'SIM2 自动管理: 开启' : 'SIM2 自动管理: 关闭'
  );
}

async function toggleIdleIsolateMode() {
  const next = state.idleIsolateMode === 'on' ? 'off' : 'on';
  await setStandbyGuard(
    { idle_isolate_mode: next },
    next === 'on' ? '待机隔离模式已开启' : '待机隔离模式已关闭',
    next === 'on' ? '待机隔离模式: 开启' : '待机隔离模式: 关闭'
  );
}

// ── 后台应用限制 ─────────────────────────────────────────
function friendlyPackageLabel(pkg, suppliedLabel = '') {
  const name = String(suppliedLabel || '').trim();
  const packageName = String(pkg || '').trim();
  if (name) return name;
  if (PACKAGE_ALIASES[packageName]) return PACKAGE_ALIASES[packageName];
  if (packageName === 'android (root)' || packageName === 'android') return 'Android 系统核心';
  if (packageName === 'android (system)') return 'Android 系统服务';
  if (packageName === 'android (radio)' || packageName === 'android.radio') return '电话与基带服务';
  if (packageName === 'android.bluetooth') return '蓝牙系统服务';
  if (packageName === 'android.media') return '媒体系统服务';
  if (packageName === 'android.shell') return 'ADB / Shell';
  if (/^u\d+[ai]\d+$/.test(packageName)) return '已卸载或未知应用';
  if (packageName.includes(', ')) return '共享 UID 应用';
  if (!packageName) return '已卸载或未知应用';
  return packageName;
}

function normalizeBgPolicy(policy) {
  return BG_RESTRICT_POLICIES[policy] ? policy : 'block_all';
}

function normalizeBgDelay(delay) {
  const value = Number(delay);
  return BG_RESTRICT_DELAYS.includes(value) ? value : 5;
}

function createBgPolicySelect(value) {
  const select = document.createElement('select');
  select.className = 'bg-policy-select';
  BG_RESTRICT_POLICY_ORDER.forEach((id) => {
    const opt = document.createElement('option');
    opt.value = id;
    opt.textContent = BG_RESTRICT_POLICIES[id].label;
    opt.selected = id === value;
    select.appendChild(opt);
  });
  return select;
}

function createBgDelaySelect(value) {
  const select = document.createElement('select');
  select.className = 'bg-delay-select';
  BG_RESTRICT_DELAYS.forEach((min) => {
    const opt = document.createElement('option');
    opt.value = String(min);
    opt.textContent = `${min}分钟`;
    opt.selected = min === value;
    select.appendChild(opt);
  });
  return select;
}

function syncBgDelayControl(policySelect, delaySelect) {
  if (!policySelect || !delaySelect) return;
  delaySelect.disabled = state.bgRestrictBusy || policySelect.value !== 'stop_after_leave';
}

function syncBgRestrictControls() {
  const busy = state.bgRestrictBusy;
  if (refs.bgRestrictToggleBtn) refs.bgRestrictToggleBtn.disabled = busy;
  if (refs.bgRestrictAddBtn) refs.bgRestrictAddBtn.disabled = busy;
  if (refs.bgRestrictPolicySelect) refs.bgRestrictPolicySelect.disabled = busy;
  if (refs.bgRestrictDelaySelect) syncBgDelayControl(refs.bgRestrictPolicySelect, refs.bgRestrictDelaySelect);
  document.querySelectorAll('#bg-restrict-rows .bg-policy-row').forEach((row) => {
    const policySelect = row.querySelector('.bg-policy-select');
    const delaySelect = row.querySelector('.bg-delay-select');
    const saveBtn = row.querySelector('.bg-policy-save');
    const removeBtn = row.querySelector('.bg-policy-remove');
    if (policySelect) policySelect.disabled = busy;
    if (delaySelect) syncBgDelayControl(policySelect, delaySelect);
    if (saveBtn) saveBtn.disabled = busy;
    if (removeBtn) removeBtn.disabled = busy;
  });
}

function bgRestrictStatus(pkg, bucket, opBg, opAny, policy, enabled, runtime = {}) {
  if (!enabled) return { text: '已关闭', cls: 'off' };
  const bucketText = String(bucket || '').toLowerCase();
  const bgMode = String(opBg || '').toLowerCase();
  const anyMode = String(opAny || '').toLowerCase();
  const stopState = String(runtime.stopState || '');
  const rareOrLower = bucketText === '40' || bucketText === 'rare' || bucketText === '45' || bucketText === 'restricted';
  const restricted = bucketText === '45' || bucketText === 'restricted';
  const bgIgnored = bgMode === 'ignore';
  const anyIgnored = anyMode === 'ignore';
  switch (policy) {
    case 'bucket':
      return rareOrLower ? { text: '已降优先级', cls: 'good' } : { text: '未生效，点刷新重试', cls: 'err' };
    case 'block_services':
      if (restricted && bgIgnored) return { text: '已禁后台服务', cls: 'good' };
      if (restricted || bgIgnored) return { text: '部分生效', cls: 'warn' };
      return { text: '未生效，点刷新重试', cls: 'err' };
    case 'stop_after_leave':
      if (stopState === 'force_stopped') {
        return restricted && bgIgnored && anyIgnored
          ? { text: '已休眠', cls: 'good' }
          : { text: '已休眠，设置有变化', cls: 'warn' };
      }
      if (stopState === 'pending') {
        return rareOrLower && bgIgnored && anyIgnored
          ? { text: '等待休眠', cls: 'good' }
          : { text: '等待中，部分生效', cls: 'warn' };
      }
      if (stopState === 'relaunched') return { text: '已重新启动', cls: 'warn' };
      if (restricted && bgIgnored && anyIgnored) return { text: '限制已生效，待触发', cls: 'good' };
      if (rareOrLower && bgIgnored && anyIgnored) return { text: '后台限制已生效', cls: 'warn' };
      if (restricted || bgIgnored || anyIgnored) return { text: '部分生效', cls: 'warn' };
      return { text: '未生效，点刷新重试', cls: 'err' };
    case 'block_all':
    default:
      if (restricted && bgIgnored && anyIgnored) return { text: '已禁后台活动', cls: 'good' };
      if (restricted || bgIgnored || anyIgnored) return { text: '部分生效', cls: 'warn' };
      return { text: '未生效，点刷新重试', cls: 'err' };
  }
}

function renderBgRestrict(data) {
  state.bgRestrictEnabled = data.enabled === 'on' ? 'on' : 'off';
  const on = state.bgRestrictEnabled === 'on';
  refs.bgRestrictToggleLabel.textContent = on ? '关闭' : '开启';
  refs.bgRestrictDesc.textContent = on
    ? '已开启：应用离开前台后，将按所选策略限制后台活动。'
    : '已关闭：应用列表保留，后台设置已恢复。';
  refs.bgRestrictRows.replaceChildren();
  const packages = Array.isArray(data.packages) ? data.packages : [];
  if (packages.length === 0) {
    refs.bgRestrictRows.appendChild(buildInfoRow('应用列表', '尚未添加应用', 'off'));
    syncBgRestrictControls();
    return;
  }
  packages.forEach((p) => {
    const policy = normalizeBgPolicy(p.policy);
    const delay = normalizeBgDelay(p.delay);
    const meta = BG_RESTRICT_POLICIES[policy];
    const opBg = p.op_bg || '';
    const opAny = p.op_any || p.appops || '';
    const stopState = String(p.stop_state || '');
    const st = bgRestrictStatus(p.pkg, p.bucket, opBg, opAny, policy, on, { stopState });
    const row = document.createElement('div');
    row.className = 'data-row bg-policy-row';

    const main = document.createElement('div');
    main.className = 'bg-policy-main';
    const title = document.createElement('div');
    title.className = 'bg-policy-title';
    const displayName = friendlyPackageLabel(p.pkg);
    title.textContent = displayName;
    const detail = document.createElement('div');
    detail.className = 'bg-policy-detail';
    const stopStateText = {
      pending: '倒计时进行中',
      force_stopped: '当前已休眠',
      relaunched: '系统已重新启动应用',
      untracked: '首次离开前台后开始计时'
    }[stopState] || '';
    const packagePrefix = displayName !== p.pkg ? `${p.pkg} · ` : '';
    detail.textContent = policy === 'stop_after_leave'
      ? `${packagePrefix}${meta.label} · ${delay}分钟${stopStateText ? ` · ${stopStateText}` : ''}`
      : `${packagePrefix}${meta.label}`;
    main.appendChild(title);
    main.appendChild(detail);

    const badge = document.createElement('span');
    badge.className = `badge ${st.cls}`;
    badge.textContent = st.text;
    const statusWrap = document.createElement('div');
    statusWrap.className = 'bg-policy-status';
    statusWrap.appendChild(badge);

    const controls = document.createElement('div');
    controls.className = 'bg-policy-controls';
    const policySelect = createBgPolicySelect(policy);
    const delaySelect = createBgDelaySelect(delay);
    policySelect.addEventListener('change', () => syncBgDelayControl(policySelect, delaySelect));
    const saveBtn = document.createElement('button');
    saveBtn.className = 'tiny-btn primary bg-policy-save';
    saveBtn.type = 'button';
    saveBtn.textContent = '保存';
    saveBtn.addEventListener('click', () => bgRestrictUpdate(p.pkg, policySelect.value, delaySelect.value));
    const rmBtn = document.createElement('button');
    rmBtn.className = 'tiny-btn bg-policy-remove';
    rmBtn.type = 'button';
    rmBtn.textContent = '移除';
    rmBtn.addEventListener('click', () => bgRestrictRemove(p.pkg));
    controls.appendChild(policySelect);
    controls.appendChild(delaySelect);
    controls.appendChild(saveBtn);
    controls.appendChild(rmBtn);

    row.appendChild(main);
    row.appendChild(statusWrap);
    row.appendChild(controls);
    refs.bgRestrictRows.appendChild(row);
  });
  syncBgRestrictControls();
}

async function refreshBgRestrict() {
  try {
    const data = await apiFetch(API.bgRestrict, { timeoutMs: 8000 });
    renderBgRestrict(data);
  } catch (err) {
    refs.bgRestrictRows.replaceChildren();
    refs.bgRestrictRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

async function forceRefreshBgRestrict() {
  try {
    const data = await apiFetch(API.bgRestrict, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'refresh' }),
      timeoutMs: 10000
    });
    if (data.ok) {
      renderBgRestrict(data);
      showToast('已重新应用后台策略');
    } else {
      const fallback = await apiFetch(API.bgRestrict, { timeoutMs: 8000 });
      renderBgRestrict(fallback);
    }
  } catch (err) {
    refs.bgRestrictRows.replaceChildren();
    refs.bgRestrictRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

async function bgRestrictAction(body, successText) {
  if (state.bgRestrictBusy) return;
  state.bgRestrictBusy = true;
  syncBgRestrictControls();
  let nextData = null;
  let ok = false;
  try {
    const data = await apiFetch(API.bgRestrict, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      timeoutMs: 10000
    });
    if (data.ok) {
      nextData = data;
      ok = true;
      showToast(successText);
    } else {
      showToast(`操作失败：${data.error || '未知'}`);
    }
  } catch (e) {
    showToast('请求失败：' + e.message);
  } finally {
    state.bgRestrictBusy = false;
    if (nextData) renderBgRestrict(nextData);
    syncBgRestrictControls();
  }
  return ok;
}

async function toggleBgRestrict() {
  const next = state.bgRestrictEnabled === 'on' ? 'off' : 'on';
  await bgRestrictAction({ action: 'toggle' }, next === 'on' ? '后台限制已开启' : '后台限制已关闭');
}

async function bgRestrictAdd() {
  const pkg = (refs.bgRestrictPkgInput.value || '').trim();
  if (!pkg || !/^[a-zA-Z][a-zA-Z0-9._]*$/.test(pkg)) {
    showToast('请输入有效的包名 (如 com.example.app)');
    return;
  }
  const policy = normalizeBgPolicy(refs.bgRestrictPolicySelect.value);
  const delay = normalizeBgDelay(refs.bgRestrictDelaySelect.value);
  const ok = await bgRestrictAction({ action: 'add', package: pkg, policy, delay }, `已添加 ${pkg}`);
  if (ok) refs.bgRestrictPkgInput.value = '';
}

async function bgRestrictUpdate(pkg, policy, delay) {
  await bgRestrictAction(
    { action: 'update', package: pkg, policy: normalizeBgPolicy(policy), delay: normalizeBgDelay(delay) },
    `已更新 ${pkg}`
  );
}

async function bgRestrictRemove(pkg) {
  await bgRestrictAction({ action: 'remove', package: pkg }, `已移除 ${pkg}`);
}

async function verifyUecapSwitch(mode, expectedHash, initialData) {
  const nonce = ++state.uecapVerifyNonce;
  const label = UECAP_MODES.find((m) => m.id === mode)?.name || mode;
  const deadline = Date.now() + UECAP_VERIFY_TIMEOUT_MS;
  let lastData = initialData || null;
  let lastErr = '';

  state.uecapPendingMode = mode;
  state.uecapExpectedHash = expectedHash || '';
  state.uecapVerifyState = 'switching';
  renderUecapRows(lastData || {
    requested_mode: mode,
    active_mode: state.uecapActiveMode || 'custom',
    target_hash: expectedHash || 'unknown'
  });

  await sleep(1800);

  while (state.uecapVerifyNonce === nonce && Date.now() < deadline) {
    state.uecapVerifyState = 'verifying';
    if (lastData) renderUecapRows(lastData);

    try {
      const data = await apiFetch(API.uecap, { timeoutMs: 6000 });
      lastData = data;
      state.uecapMode = data.requested_mode || mode;
      state.uecapActiveMode = data.active_mode || 'custom';
      renderUecapRows(data);

      const confirmedHash = expectedHash || getUecapModeHash(data, mode);
      const confirmed = data.requested_mode === mode
        && data.active_mode === mode
        && (!confirmedHash || data.target_hash === confirmedHash);

      if (confirmed) {
        state.uecapBusy = false;
        state.uecapPendingMode = '';
        state.uecapExpectedHash = '';
        state.uecapVerifyState = 'idle';
        state.uecapVerifyMessage = '';
        renderUecapRows(data);
        showToast(`UE 能力配置已切换为 ${label}`);
        appendLog(`UE 配置已确认: ${label}`, 'ok');
        return;
      }
    } catch (err) {
      lastErr = err.message || 'request failed';
    }

    await sleep(UECAP_VERIFY_INTERVAL_MS);
  }

  if (state.uecapVerifyNonce !== nonce) return;

  state.uecapBusy = false;
  state.uecapPendingMode = '';
  state.uecapExpectedHash = '';
  state.uecapVerifyState = 'failed';
  state.uecapVerifyMessage = lastErr
    ? `15 秒内未确认（${lastErr}）`
    : '15 秒内未确认，请手动刷新复查';

  if (lastData) renderUecapRows(lastData);
  showToast(`${label} 已提交切换，但 15 秒内未完成校验，请手动刷新复查`, 4200);
  appendLog(`UE 配置待复查: ${label}`, 'warn');
}

async function toggleNrSwitch() {
  if (state.nrBusy) return;
  state.nrBusy = true;
  try {
    const data = await apiFetch(API.nrSwitch, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'toggle' }), timeoutMs: 8000 });
    if (data.ok) {
      state.nrSwitch = data.nr_switch;
      showToast(data.nr_switch === 'on' ? 'NR 息屏降级已开启' : 'NR 息屏降级已关闭');
      appendLog(data.nr_switch === 'on' ? 'NR 息屏降级: 开启' : 'NR 息屏降级: 关闭', 'ok');
      refreshNrSwitch();
    } else {
      showToast('操作失败');
    }
  } catch (_) {
    showToast('请求失败');
  } finally {
    state.nrBusy = false;
  }
}

async function setUecapMode(mode) {
  if (state.uecapBusy || (mode === state.uecapMode && state.uecapVerifyState !== 'failed')) return;
  const label = UECAP_MODES.find((m) => m.id === mode)?.name || mode;
  state.uecapBusy = true;
  state.uecapPendingMode = mode;
  state.uecapVerifyState = 'switching';
  state.uecapVerifyMessage = `${label}：正在提交切换`;
  renderUecapRows({
    requested_mode: state.uecapMode || mode,
    active_mode: state.uecapActiveMode || 'custom',
    target_hash: state.uecapExpectedHash || 'unknown'
  });
  try {
    const data = await apiFetch(API.uecap, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ policy: 'manual', mode }),
      timeoutMs: 12000
    });
    if (data.ok) {
      state.uecapMode = data.requested_mode || mode;
      state.uecapActiveMode = data.active_mode || state.uecapActiveMode || 'custom';
      const expectedHash = getUecapModeHash(data, mode) || data.target_hash || '';
      state.uecapExpectedHash = expectedHash;
      state.uecapVerifyState = data.reloading ? 'switching' : 'verifying';
      renderUecapRows(data);
      showToast(`${label}：已提交切换，正在校验配置`, 2600);
      appendLog(`UE 配置已提交: ${label}，等待校验结果`, 'ok');
      await verifyUecapSwitch(mode, expectedHash, data);
    } else {
      showToast(`切换失败：${data.error || '未知'}`);
      state.uecapBusy = false;
      state.uecapPendingMode = '';
      state.uecapExpectedHash = '';
      state.uecapVerifyState = 'failed';
      state.uecapVerifyMessage = data.error || '提交失败';
      await refreshUecap();
    }
  } catch (_) {
    showToast('请求失败');
    state.uecapBusy = false;
    state.uecapPendingMode = '';
    state.uecapExpectedHash = '';
    state.uecapVerifyState = 'failed';
    state.uecapVerifyMessage = '请求失败，请重试';
    await refreshUecap();
  }
}

function renderBasebandRows(data) {
  refs.basebandRows.replaceChildren();
  if (!data.installed) {
    refs.basebandDesc.textContent = '未检测到独立基带模块，当前运营商配置和 MCFG 使用系统默认。';
    refs.basebandRows.appendChild(buildInfoRow('安装状态', '未安装', 'off'));
    return;
  }
  refs.basebandDesc.textContent = `已安装 ${data.version || ''}，可提供 CarrierSettings、MCFG 和 IMS 相关配置。`;
  const props = data.props || {};
  const cs = data.carrier_settings || {};
  const mcfg = data.mcfg || {};
  const rows = [
    { label: '安装状态', value: '已安装', cls: 'good' },
    { label: '版本', value: data.version || '未知', cls: 'off' },
    { label: 'VoLTE', value: props.volte_avail_ovr === '1' ? '已启用' : '未启用', cls: props.volte_avail_ovr === '1' ? 'good' : 'warn' },
    { label: 'Wi-Fi Calling', value: props.wfc_avail_ovr === '1' ? '已启用' : '未启用', cls: props.wfc_avail_ovr === '1' ? 'good' : 'warn' },
    { label: '运营商配置', value: cs.installed ? `${cs.count} 项` : '未安装', cls: cs.installed ? 'good' : 'off' },
    { label: '国内 MCFG', value: mcfg.installed ? `${mcfg.count} 个 mbn` : '未安装', cls: mcfg.installed ? 'good' : 'off' },
  ];
  rows.forEach((row) => refs.basebandRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
}

async function refreshBaseband() {
  try {
    const data = await apiFetch(API.checkBaseband, { timeoutMs: 6000 });
    renderBasebandRows(data);
  } catch (err) {
    refs.basebandRows.replaceChildren(); refs.basebandRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

function startDeviceClock() {
  if (!isWebUiActive() || state.currentTab !== 'system') return;
  if (state.deviceClockTimer) return;
  const pad = (n) => String(n).padStart(2, '0');
  const tick = () => {
    const el = document.getElementById('ntp-device-time');
    if (!el || !isWebUiActive() || state.currentTab !== 'system') return;
    // WebView 运行在本机, new Date() 即设备实时时钟; 每秒走字, 不再依赖 CGI 快照
    const d = new Date();
    el.textContent = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  };
  tick();
  state.deviceClockTimer = window.setInterval(tick, 1000);
}

function stopDeviceClock() {
  if (!state.deviceClockTimer) return;
  clearInterval(state.deviceClockTimer);
  state.deviceClockTimer = null;
}

function syncDeviceClockForTab() {
  if (isWebUiActive() && state.currentTab === 'system') startDeviceClock();
  else stopDeviceClock();
}

function renderNtpCard(data) {
  refs.ntpServerList.replaceChildren();
  const current = data.ntp_server || 'time.android.com';
  state.ntpServer = current;
  NTP_SERVERS.forEach((srv) => {
    const card = document.createElement('div');
    card.className = `opt-item${srv.id === current ? ' ntp-selected' : ''}`;
    card.style.cursor = 'pointer';
    setStaticHtml(card, `
      <div class="opt-item-head">
        <div class="opt-label">${srv.name}</div>
        <span class="badge ${srv.id === current ? 'good' : 'off'}">${srv.id === current ? '当前' : '切换'}</span>
      </div>
      <div class="opt-meta">${srv.id} · ${srv.desc}</div>`);
    card.addEventListener('click', () => setNtpServer(srv.id));
    refs.ntpServerList.appendChild(card);
  });
  refs.ntpInfoRows.replaceChildren();
  const deviceTimeRow = buildInfoRow('设备时间', '—', '');
  const deviceTimeVal = deviceTimeRow.querySelector('.data-val');
  if (deviceTimeVal) deviceTimeVal.id = 'ntp-device-time';
  refs.ntpInfoRows.appendChild(deviceTimeRow);
  refs.ntpInfoRows.appendChild(buildInfoRow('自动同步', data.auto_time === '1' ? '已开启' : '已关闭', data.auto_time === '1' ? 'good' : 'warn'));
  startDeviceClock();
  const ntpLabel = NTP_SERVERS.find((s) => s.id === current)?.name || current;
  refs.ntpDesc.textContent = `当前: ${ntpLabel} (${current})`;
}

async function refreshNtp() {
  try {
    const data = await apiFetch(API.ntp, { timeoutMs: 6000 });
    renderNtpCard(data);
  } catch (err) {
    refs.ntpServerList.replaceChildren(); refs.ntpServerList.appendChild(errorBlock('获取失败：' + err.message));
  }
}

async function setNtpServer(server) {
  if (state.ntpBusy || server === state.ntpServer) return;
  state.ntpBusy = true;
  try {
    const data = await apiFetch(API.ntp, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ server }),
      timeoutMs: 10000
    });
    if (data.ok) {
      const label = NTP_SERVERS.find((s) => s.id === server)?.name || server;
      showToast(`NTP 已切换为 ${label} 并同步`);
      appendLog(`NTP: ${server}`, 'ok');
      refreshNtp();
    } else {
      showToast(`切换失败：${data.error || '未知'}`);
    }
  } catch (_) {
    showToast('请求失败');
  } finally {
    state.ntpBusy = false;
  }
}

async function syncNtp() {
  if (state.ntpBusy) return;
  state.ntpBusy = true;
  refs.ntpSyncLabel.textContent = '同步中…';
  try {
    const data = await apiFetch(API.ntp, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'sync' }),
      timeoutMs: 10000
    });
    if (data.ok) {
      showToast('时间已同步');
      appendLog(`NTP 同步完成: ${data.device_time}`, 'ok');
      refreshNtp();
    } else {
      showToast('同步失败');
    }
  } catch (_) {
    showToast('同步请求失败');
  } finally {
    refs.ntpSyncLabel.textContent = '立即同步';
    state.ntpBusy = false;
  }
}

function getTempGapThresholdSec(data) {
  const deltas = [];
  for (let i = 1; i < data.length; i++) {
    const delta = data[i].ts - data[i - 1].ts;
    if (delta > 0) deltas.push(delta);
  }
  const sortedDeltas = deltas.sort((a, b) => a - b);
  const medianDelta = sortedDeltas.length ? sortedDeltas[Math.floor(sortedDeltas.length / 2)] : 15;
  return Math.max(90, medianDelta * 4);
}

function drawTempCanvas(canvas, data, options = {}) {
  if (!canvas || !data || data.length < 2) return null;
  const dpr = Math.min(Math.max(window.devicePixelRatio || 1, 1), 2);
  const w = Math.max(1, Math.round(canvas.getBoundingClientRect().width || canvas.offsetWidth || 380));
  const h = 200;
  const pixelWidth = Math.max(1, Math.round(w * dpr));
  const pixelHeight = Math.max(1, Math.round(h * dpr));
  if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) {
    canvas.width = pixelWidth;
    canvas.height = pixelHeight;
  }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  const pad = { top: 12, right: 8, bottom: 26, left: 38 };
  const plotW = w - pad.left - pad.right;
  const plotH = h - pad.top - pad.bottom;
  const temps = data.map((p) => p.temp);
  const realMin = Math.min(...temps);
  const realMax = Math.max(...temps);
  const avg = temps.reduce((a, b) => a + b, 0) / temps.length;
  let minT = realMin;
  let maxT = realMax;
  if (maxT - minT < 2) { minT -= 1; maxT += 1; } else { minT = Math.floor(minT); maxT = Math.ceil(maxT); }
  const isDark = document.documentElement.dataset.theme === 'dark';
  const gridColor = isDark ? 'rgba(224,227,225,0.10)' : 'rgba(23,29,27,0.10)';
  const labelColor = isDark ? 'rgba(224,227,225,0.55)' : 'rgba(23,29,27,0.52)';
  const strokeColor = isDark ? '#84dcc5' : '#006b57';
  const areaColor = isDark ? 'rgba(132,220,197,0.08)' : 'rgba(0,107,87,0.06)';
  const gridN = 4;
  ctx.strokeStyle = gridColor;
  ctx.lineWidth = 1;
  ctx.font = '11px system-ui,sans-serif';
  ctx.fillStyle = labelColor;
  ctx.textAlign = 'right';
  ctx.textBaseline = 'middle';
  for (let i = 0; i <= gridN; i++) {
    const y = pad.top + (plotH / gridN) * i;
    const t = maxT - ((maxT - minT) / gridN) * i;
    ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(w - pad.right, y); ctx.stroke();
    ctx.fillText(`${t.toFixed(0)}°`, pad.left - 4, y);
  }
  ctx.textBaseline = 'top';
  const xN = 4;
  const t0 = data[0].ts;
  const t1 = data[data.length - 1].ts;
  const timeSpan = t1 - t0 || 1;
  for (let i = 0; i <= xN; i++) {
    const x = pad.left + (plotW / xN) * i;
    const ts = t0 + (timeSpan / xN) * i;
    const d = new Date(ts * 1000);
    ctx.textAlign = i === 0 ? 'left' : i === xN ? 'right' : 'center';
    ctx.fillText(`${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`, x, h - pad.bottom + 6);
  }
  const gapThresholdSec = options.gapThresholdSec || getTempGapThresholdSec(data);
  const segments = [];
  const gaps = [];
  let segment = [data[0]];
  for (let i = 1; i < data.length; i++) {
    const previous = data[i - 1];
    const current = data[i];
    if ((current.ts - previous.ts) > gapThresholdSec) {
      segments.push(segment);
      gaps.push([previous, current]);
      segment = [current];
    } else {
      segment.push(current);
    }
  }
  if (segment.length) segments.push(segment);
  const sampleStep = Math.max(1, Math.ceil(data.length / Math.max(1, plotW)));
  const plotSegments = segments.map((points) => {
    if (sampleStep === 1 || points.length <= 2) return points;
    const sampled = points.filter((_, index) => index % sampleStep === 0);
    const last = points[points.length - 1];
    if (sampled[sampled.length - 1] !== last) sampled.push(last);
    return sampled;
  });

  const pointXY = (point) => ({
    x: pad.left + ((point.ts - t0) / timeSpan) * plotW,
    y: pad.top + ((maxT - point.temp) / (maxT - minT)) * plotH
  });
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  plotSegments.forEach((points) => {
    if (!points.length) return;
    const first = pointXY(points[0]);
    const last = pointXY(points[points.length - 1]);
    ctx.beginPath();
    ctx.moveTo(first.x, pad.top + plotH);
    ctx.lineTo(first.x, first.y);
    points.slice(1).forEach((point) => {
      const pos = pointXY(point);
      ctx.lineTo(pos.x, pos.y);
    });
    ctx.lineTo(last.x, pad.top + plotH);
    ctx.closePath();
    ctx.fillStyle = areaColor;
    ctx.fill();

    ctx.beginPath();
    points.forEach((point, index) => {
      const pos = pointXY(point);
      if (index === 0) ctx.moveTo(pos.x, pos.y);
      else ctx.lineTo(pos.x, pos.y);
    });
    ctx.strokeStyle = strokeColor;
    ctx.lineWidth = 2;
    ctx.stroke();
  });
  if (gaps.length) {
    ctx.save();
    ctx.setLineDash([6, 5]);
    ctx.strokeStyle = labelColor;
    ctx.lineWidth = 1.5;
    gaps.forEach(([from, to]) => {
      const start = pointXY(from);
      const end = pointXY(to);
      ctx.beginPath();
      ctx.moveTo(start.x, start.y);
      ctx.lineTo(end.x, end.y);
      ctx.stroke();
    });
    ctx.restore();
  }
  return { min: realMin, max: realMax, avg, count: data.length, gapCount: gaps.length, gapThresholdSec };
}

function fmtDuration(sec) {
  const value = Number(sec);
  if (!Number.isFinite(value) || value < 0) return '—';
  if (value >= 3600) return `${Math.floor(value / 3600)}小时${Math.floor((value % 3600) / 60)}分`;
  if (value >= 60) return `${Math.floor(value / 60)}分${Math.floor(value % 60)}秒`;
  return `${Math.floor(value)}秒`;
}

function fmtDateTime(ts, withSeconds = false) {
  const value = Number(ts);
  if (!Number.isFinite(value) || value <= 0) return '—';
  const options = {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  };
  if (withSeconds) options.second = '2-digit';
  return new Intl.DateTimeFormat('zh-CN', options).format(new Date(value * 1000)).replace(/\//g, '-');
}

function fmtMah(value) {
  const num = Number(value);
  return Number.isFinite(num) ? `${num.toFixed(1)} mAh` : '—';
}

function fmtMahPerHour(value) {
  const num = Number(value);
  return Number.isFinite(num) ? `${num.toFixed(1)} mAh/h` : '—';
}

function fmtMilliwatt(value) {
  const num = Number(value);
  return Number.isFinite(num) ? `${num.toFixed(0)} mW` : '—';
}

function fmtTempC(value) {
  const num = Number(value);
  return Number.isFinite(num) ? `${num.toFixed(1)}°C` : '—';
}

function fmtSignedPercent(value) {
  const num = Number(value);
  if (!Number.isFinite(num)) return '—';
  return `${num > 0 ? '+' : ''}${num}%`;
}

function fmtPowerSource(source, externalPower = false) {
  switch (source) {
    case 'usb': return 'USB 接电';
    case 'wireless': return '无线接电';
    case 'dc': return 'DC 接电';
    case 'mains':
    case 'ac': return 'AC 接电';
    case 'battery': return '未接电';
    default: return externalPower ? `${source || '外接电源'} 在线` : '未接电';
  }
}

function fmtBatteryStatus(status, charge = {}) {
  const externalPower = charge.external_power_online === true;
  const sourceLabel = fmtPowerSource(charge.power_source, externalPower);
  switch (status) {
    case 'Charging': return '充电中';
    case 'Discharging': return '放电中';
    case 'Full': return '已充满';
    case 'Not charging': return externalPower ? `${sourceLabel}未充电` : '未充电';
    default: return status || '未知';
  }
}

function fmtSessionResetReason(reason) {
  switch (reason) {
    case 'charged_10m': return '连续充电 10 分钟后重新拔线';
    case 'full_replug': return '充满后重新拔线';
    case 'boot_init': return '模块首次初始化';
    default: return reason || '—';
  }
}

function fmtBatterystatsWindow(label) {
  if (!label) return '—';
  if (/Statistics since last charge/i.test(label)) return '自上次充满以来';
  if (/Daily stats/i.test(label)) return 'Daily stats';
  return label;
}

async function fetchEnergyDetailWithRetry() {
  let lastErr = new Error('功耗数据暂不可用');
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const result = await fetchEnergySystemDetail();
      if (result) return result;
      lastErr = new Error('功耗数据请求繁忙');
    } catch (err) {
      lastErr = err;
      const msg = String(err?.message || err || '');
      if (attempt === 0 && (/Failed to fetch/i.test(msg) || /request timeout/i.test(msg) || /HTTP 5\d\d/.test(msg))) {
        await sleep(450);
        continue;
      }
      break;
    }
  }
  try {
    const result = await fetchEnergyFastDetail();
    if (result) return result;
    lastErr = new Error('功耗数据请求繁忙');
  } catch (err) {
    lastErr = err;
  }
  throw lastErr;
}

async function fetchEnergyRequest(kind, path, timeoutMs) {
  if (state.energyDetail.requestKind) return null;
  const controller = new AbortController();
  state.energyDetail.requestKind = kind;
  state.energyDetail.requestController = controller;
  try {
    return await apiFetch(path, { timeoutMs, controller });
  } finally {
    if (state.energyDetail.requestController === controller) {
      state.energyDetail.requestController = null;
      state.energyDetail.requestKind = '';
    }
  }
}

async function fetchEnergyFastDetail() {
  return await fetchEnergyRequest('fast', API.energyFast, 3500);
}

async function fetchEnergySystemDetail() {
  return await fetchEnergyRequest('full', API.energy, 16000);
}

async function fetchTempHistory(minutes) {
  try {
    const data = await apiFetch(`${API.thermal}?history=1&minutes=${minutes}`, { timeoutMs: 6000 });
    if (!data || !data.points) return [];
    return data.points.map((p) => ({ ts: p[0], temp: p[1] / 1000 }));
  } catch (_) {
    return [];
  }
}

async function triggerThermalBurst(options = {}) {
  if (!state.webuiToken) {
    if (!options.prompt) return false;
    if (!(await ensureWebuiToken())) return false;
  }
  try {
    await apiFetch(API.thermalBurst, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'start', duration_sec: 300 }),
      timeoutMs: 4000
    });
    return true;
  } catch (_) {
    return false;
  }
}

function openTempChart() {
  stopTempChartRefresh();
  stopEnergyDetailRefresh();
  triggerThermalBurst({ prompt: false });
  refs.detailTitle.textContent = '温度历史';
  const ranges = [
    { min: 10, label: '10 分' },
    { min: 30, label: '30 分' },
    { min: 150, label: '2.5 小时' },
    { min: 720, label: '12 小时' },
  ];
  let active = 10;
  state.tempChart.activeRange = active;
  refs.detailModal.classList.remove('energy-mode');
  refs.detailModal.classList.add('history-mode');
  const root = document.createElement('div');
  root.className = 'history-overview';
  const intro = document.createElement('div');
  intro.className = 'section-intro';
  setStaticHtml(intro, '<div class="section-title">温度趋势</div><div class="section-sub">查看机身温度变化、峰值与阈值持续时间。</div>');
  const tabsEl = document.createElement('div');
  tabsEl.className = 'range-tabs history-range-tabs';
  const areaEl = document.createElement('div');
  areaEl.className = 'history-content';
  root.append(intro, tabsEl, areaEl);
  refs.detailBody.replaceChildren(root);
  let view = null;
  const createView = () => {
    areaEl.replaceChildren();
    const hero = document.createElement('section');
    hero.className = 'history-hero';
    const heroHead = document.createElement('div');
    heroHead.className = 'history-hero-head';
    const heroCopy = document.createElement('div');
    heroCopy.className = 'history-hero-copy';
    const currentLabel = document.createElement('div');
    currentLabel.className = 'history-hero-kicker';
    currentLabel.textContent = '当前温度';
    const currentValue = document.createElement('div');
    currentValue.className = 'history-hero-value';
    const currentStatus = document.createElement('div');
    currentStatus.className = 'history-hero-status';
    heroCopy.append(currentLabel, currentValue, currentStatus);
    const heroBadge = document.createElement('span');
    heroBadge.className = 'history-hero-badge';
    heroHead.append(heroCopy, heroBadge);
    const summaryGrid = document.createElement('div');
    summaryGrid.className = 'history-summary-grid';
    const summaryValues = [];
    ['最低', '平均', '最高'].forEach((label) => {
      const item = document.createElement('div');
      item.className = 'history-summary-item';
      const labelEl = document.createElement('span');
      labelEl.textContent = label;
      const valueEl = document.createElement('strong');
      item.append(labelEl, valueEl);
      summaryGrid.appendChild(item);
      summaryValues.push(valueEl);
    });
    hero.append(heroHead, summaryGrid);

    const chartCard = document.createElement('section');
    chartCard.className = 'history-chart-card';
    const chartWrap = document.createElement('div');
    chartWrap.className = 'chart-wrap';
    const canvas = document.createElement('canvas');
    canvas.style.cssText = 'display:block;width:100%;height:200px';
    canvas.setAttribute('role', 'img');
    canvas.setAttribute('aria-label', '机身温度趋势图');
    chartWrap.appendChild(canvas);
    const gapNote = document.createElement('div');
    gapNote.className = 'history-gap-note';
    gapNote.hidden = true;
    chartCard.append(chartWrap, gapNote);

    const details = document.createElement('details');
    details.className = 'disclosure';
    const detailsSummary = document.createElement('summary');
    detailsSummary.className = 'disclosure-summary';
    const detailsCopy = document.createElement('span');
    detailsCopy.className = 'disclosure-copy';
    const detailsTitle = document.createElement('strong');
    detailsTitle.textContent = '更多统计';
    const detailsMeta = document.createElement('small');
    detailsCopy.append(detailsTitle, detailsMeta);
    const chevron = document.createElement('span');
    chevron.className = 'disclosure-chevron';
    chevron.setAttribute('aria-hidden', 'true');
    chevron.textContent = '›';
    detailsSummary.append(detailsCopy, chevron);
    const detailsBody = document.createElement('div');
    detailsBody.className = 'disclosure-body';
    const statsList = document.createElement('div');
    statsList.className = 'data-list';
    const rangeRow = buildInfoRow('数据范围', '—');
    const samplesRow = buildInfoRow('采样点', '—');
    const thresholdRow = buildInfoRow('达到阈值', '—');
    statsList.append(rangeRow, samplesRow, thresholdRow);
    detailsBody.appendChild(statsList);
    details.append(detailsSummary, detailsBody);
    areaEl.append(hero, chartCard, details);
    return {
      hero,
      currentValue,
      currentStatus,
      heroBadge,
      summaryValues,
      canvas,
      gapNote,
      detailsMeta,
      rangeValue: rangeRow.querySelector('.data-val'),
      samplesValue: samplesRow.querySelector('.data-val'),
      thresholdKey: thresholdRow.querySelector('.data-key'),
      thresholdValue: thresholdRow.querySelector('.data-val')
    };
  };
  const draw = async (rangeMin, options = {}) => {
    const requestId = ++state.tempChart.requestId;
    active = rangeMin;
    state.tempChart.activeRange = rangeMin;
    const rangeLabel = ranges.find((r) => r.min === rangeMin)?.label || `${rangeMin} 分钟`;
    tabsEl.querySelectorAll('.range-btn').forEach((button) => button.classList.toggle('active', Number(button.dataset.range) === rangeMin));
    if (!options.silent && !view) setStaticHtml(areaEl, '<div class="energy-empty">正在读取温度记录…</div>');
    const data = await fetchTempHistory(rangeMin);
    if (requestId !== state.tempChart.requestId || state.tempChart.draw !== draw) return;
    if (!data || data.length < 2) {
      setStaticHtml(areaEl, '<div class="energy-empty">温度记录不足。保持页面运行一段时间后再查看。</div>');
      view = null;
      return;
    }
    const temps = data.map((p) => p.temp);
    const realMin = Math.min(...temps);
    const realMax = Math.max(...temps);
    const avg = temps.reduce((a, b) => a + b, 0) / temps.length;
    const current = data[data.length - 1].temp;
    const threshold = THRESH_STOCK + state.currentOffset;
    const gapThresholdSec = getTempGapThresholdSec(data);
    let highSec = 0;
    for (let i = 1; i < data.length; i++) {
      const delta = data[i].ts - data[i - 1].ts;
      if (delta <= gapThresholdSec && data[i - 1].temp >= threshold) highSec += delta;
    }
    const elapsed = data[data.length - 1].ts - data[0].ts;
    if (!view) view = createView();
    const tone = current >= threshold ? 'warn' : '';
    view.hero.className = `history-hero${tone ? ` ${tone}` : ''}`;
    view.currentValue.textContent = `${current.toFixed(1)}°C`;
    view.currentStatus.textContent = current >= threshold
      ? `已达到 ${threshold}°C 温控阈值`
      : `距离 ${threshold}°C 温控阈值 ${(threshold - current).toFixed(1)}°C`;
    view.heroBadge.textContent = rangeLabel;
    view.summaryValues[0].textContent = `${realMin.toFixed(1)}°C`;
    view.summaryValues[1].textContent = `${avg.toFixed(1)}°C`;
    view.summaryValues[2].textContent = `${realMax.toFixed(1)}°C`;
    const chartResult = drawTempCanvas(view.canvas, data, { gapThresholdSec });
    const gapCount = chartResult?.gapCount || 0;
    view.gapNote.hidden = gapCount === 0;
    view.gapNote.textContent = gapCount > 0 ? `虚线表示 ${gapCount} 段无连续采样区间` : '';
    view.detailsMeta.textContent = `${data.length} 个采样点 · 覆盖 ${fmtDuration(elapsed)}`;
    view.rangeValue.textContent = fmtDuration(elapsed);
    view.samplesValue.textContent = `${data.length} 个`;
    view.thresholdKey.textContent = `达到阈值（≥${threshold}°C）`;
    view.thresholdValue.className = `badge ${highSec > 60 ? 'warn' : 'good'}`;
    view.thresholdValue.textContent = fmtDuration(highSec);
  };
  ranges.forEach((r) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = `range-btn${r.min === active ? ' active' : ''}`;
    btn.dataset.range = String(r.min);
    btn.textContent = r.label;
    btn.addEventListener('click', () => {
      draw(r.min).catch(() => {}).then(() => scheduleTempChartRefresh());
    });
    tabsEl.appendChild(btn);
  });
  refs.detailModal.classList.add('open');
  pushModalState('detail');
  state.tempChart.draw = draw;
  window.setTimeout(() => {
    if (!refs.detailModal.classList.contains('open') || state.tempChart.draw !== draw) return;
    draw(active).catch(() => {}).then(() => scheduleTempChartRefresh());
  }, 80);
}

async function exportHistoryWindow(scope, button) {
  const oldText = button ? button.textContent : '';
  if (button) {
    button.disabled = true;
    button.textContent = '保存中...';
  }
  try {
    const body = scope === 'session'
      ? { action: 'export', mode: 'session', start_ts: WEBUI_SESSION_START_TS }
      : { action: 'export', minutes: scope };
    const data = await apiFetch(API.historyExport, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      timeoutMs: 10000
    });
    if (data && data.ok) {
      showToast(`已保存到 ${data.path}`, 4200);
      appendLog(`历史数据已保存: ${data.path}`, 'ok');
    } else {
      showToast(`保存失败：${data?.error || '未知错误'}`);
    }
  } catch (err) {
    if (!/missing WebUI token/i.test(String(err?.message || ''))) {
      showToast(`保存失败：${err.message || err}`);
    }
  } finally {
    if (button) {
      button.disabled = false;
      button.textContent = oldText;
    }
  }
}

function stopThermalBurst() {
  if (!state.webuiToken) return;
  apiFetch(API.thermalBurst, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: 'stop' }),
    timeoutMs: 2500,
    keepalive: true
  }).catch(() => {});
}

function isFullEnergyDetailData(d) {
  if (!d || d.fast === true) return false;
  const bs = d.batterystats_window || {};
  return Number.isFinite(Number(d.system_generated_at))
    || (bs && bs.model_quality && bs.model_quality !== 'fast_no_batterystats')
    || Number(d.cap) > 0
    || Number(d.drain) > 0
    || (Array.isArray(d.apps) && d.apps.length > 0);
}

function mergeEnergyDetailData(liveData, fullData) {
  const live = liveData || {};
  const full = fullData || {};
  const system = Object.keys(full).length ? full : (isFullEnergyDetailData(live) ? live : {});
  const merged = { ...full, ...live };
  ['cap', 'drain', 'scroff', 'scron', 'bat_time', 'screen', 'cpu', 'cell', 'wifi', 'wakelock'].forEach((key) => {
    if (Object.prototype.hasOwnProperty.call(system, key)) merged[key] = system[key];
  });
  ['system_generated_at', 'system_cache_age_sec', 'system_cache_stale', 'cache_ttl_sec'].forEach((key) => {
    if (Object.prototype.hasOwnProperty.call(system, key)) merged[key] = system[key];
  });
  if (Array.isArray(system.apps)) merged.apps = system.apps;
  else if (!Array.isArray(merged.apps)) merged.apps = [];
  if (system.batterystats_window) merged.batterystats_window = system.batterystats_window;
  merged._using_fast_live = live.fast === true;
  merged._has_full_system = Object.keys(system).length > 0;
  merged._live_generated_at = live.live_generated_at || live.generated_at || merged.live_generated_at || merged.generated_at || null;
  merged._system_generated_at = system.system_generated_at || system.generated_at || null;
  return merged;
}

function getEnergySystemAgeSeconds(data, liveGeneratedAt, systemGeneratedAt) {
  const rawBackendAge = data?.system_cache_age_sec;
  const backendAge = rawBackendAge == null || rawBackendAge === '' ? NaN : Number(rawBackendAge);
  const liveTs = liveGeneratedAt == null || liveGeneratedAt === '' ? NaN : Number(liveGeneratedAt);
  const systemTs = systemGeneratedAt == null || systemGeneratedAt === '' ? NaN : Number(systemGeneratedAt);
  const derivedAge = Number.isFinite(liveTs) && Number.isFinite(systemTs) && liveTs >= systemTs
    ? liveTs - systemTs
    : NaN;
  const candidates = [backendAge, derivedAge].filter((value) => Number.isFinite(value) && value >= 0);
  return candidates.length ? Math.max(...candidates) : null;
}

function getEnergySystemRefreshDelay(data = state.energyDetail.fullData) {
  const ttlSec = Number(data?.cache_ttl_sec);
  if (!Number.isFinite(ttlSec) || ttlSec <= 0) return ENERGY_SYSTEM_REFRESH_FALLBACK_MS;
  const rawAge = data?.system_cache_age_sec;
  const ageSec = rawAge == null || rawAge === '' ? 0 : Math.max(0, Number(rawAge) || 0);
  const remainingSec = Math.max(0, ttlSec - ageSec);
  return Math.max(ENERGY_DETAIL_REFRESH_MS * 2, Math.round(remainingSec * 1000) + ENERGY_SYSTEM_REFRESH_MARGIN_MS);
}

function getEnergyRenderSignature(data) {
  const ignored = new Set([
    'generated_at', 'live_generated_at', '_live_generated_at',
    'system_cache_age_sec'
  ]);
  return `${state.energyDetail.activeWindowMinutes}|${JSON.stringify(data, (key, value) => (
    ignored.has(key) ? undefined : value
  ))}`;
}

function reconcileStableDom(current, next) {
  if (!current || !next) return;
  if (current.nodeType !== next.nodeType || current.nodeName !== next.nodeName) {
    current.replaceWith(next);
    return;
  }
  if (current.nodeType === Node.TEXT_NODE) {
    if (current.nodeValue !== next.nodeValue) current.nodeValue = next.nodeValue;
    return;
  }
  const currentAttrs = Array.from(current.attributes || []);
  const nextAttrs = Array.from(next.attributes || []);
  currentAttrs.forEach((attr) => {
    if (!next.hasAttribute(attr.name)) current.removeAttribute(attr.name);
  });
  nextAttrs.forEach((attr) => {
    if (current.getAttribute(attr.name) !== attr.value) current.setAttribute(attr.name, attr.value);
  });
  if (current instanceof HTMLDetailsElement && next instanceof HTMLDetailsElement) current.open = next.open;
  if (current instanceof HTMLButtonElement && next instanceof HTMLButtonElement) current.disabled = next.disabled;

  const currentChildren = Array.from(current.childNodes);
  const nextChildren = Array.from(next.childNodes);
  const shared = Math.min(currentChildren.length, nextChildren.length);
  for (let i = 0; i < shared; i++) reconcileStableDom(currentChildren[i], nextChildren[i]);
  for (let i = currentChildren.length - 1; i >= nextChildren.length; i--) currentChildren[i].remove();
  for (let i = shared; i < nextChildren.length; i++) current.appendChild(nextChildren[i]);
}

function renderEnergyDetail(input, options = {}) {
  try {
    const d = mergeEnergyDetailData(input, options.fullData || state.energyDetail.fullData);
    const text = (v) => v == null || v === '' ? '—' : String(v);
    const el = (tag, className = '', content = '') => {
      const node = document.createElement(tag);
      if (className) node.className = className;
      if (content !== '') node.textContent = content;
      return node;
    };
    const row = (k, v, cls) => { const r = document.createElement('div'); r.className = 'data-row'; const sk = document.createElement('span'); sk.className = 'data-key'; sk.textContent = k; const sv = document.createElement('span'); sv.className = cls || 'data-val'; sv.textContent = v; r.appendChild(sk); r.appendChild(sv); return r; };
    const sectionHead = (title, desc = '') => {
      const head = el('div', 'energy-section-head');
      head.appendChild(el('div', 'energy-section-title', title));
      if (desc) head.appendChild(el('div', 'energy-section-desc', desc));
      return head;
    };
    const disclosure = (key, title, summary, body) => {
      const details = el('details', 'energy-disclosure');
      details.open = state.energyDetail.openSections[key] === true;
      const trigger = el('summary', 'energy-disclosure-summary');
      const copy = el('span', 'energy-disclosure-copy');
      copy.append(el('strong', '', title), el('small', '', summary));
      trigger.append(copy, el('span', 'energy-disclosure-chevron', '›'));
      details.append(trigger, body);
      details.addEventListener('toggle', () => {
        state.energyDetail.openSections[key] = details.open;
      });
      return details;
    };
    const scope = d.scope || {};
    const today = d.today || {};
    const charge = d.charge_state || {};
    const bs = d.batterystats_window || {};
    const qualityLabel = (q) => {
      switch (q) {
        case 'pure_discharge': return '纯放电';
        case 'charging_endpoint': return '接电中';
        case 'mixed_charge_discharge': return '混合充放电';
        case 'session_window_mismatch': return '统计窗口不一致';
        case 'insufficient_samples': return '采样不足';
        case 'partial_window': return '覆盖不足';
        case 'no_discharge_delta': return '暂无放电变化';
        case 'no_data': return '无数据';
        default: return '未知';
      }
    };
    const qualityTone = (q) => q === 'pure_discharge' ? 'good' : (q === 'no_data' || q === 'insufficient_samples' || q === 'no_discharge_delta' ? 'off' : 'warn');
    const qualityBadge = (q) => `badge ${qualityTone(q)}`;
    const comparable = scope.comparable_to_batterystats === true;
    const externalPower = charge.external_power_online === true;
    const chargeLike = charge.is_charging_like === true
      || charge.status === 'Charging'
      || charge.status === 'Full'
      || (charge.status === 'Not charging' && externalPower);
    const powerSourceLabel = fmtPowerSource(charge.power_source, externalPower);
    const chargeStatusLabel = fmtBatteryStatus(charge.status, charge);
    const radioUntrusted = /untrusted|high/i.test(String(bs.model_quality || ''));
    const modelQualityLabel = (q) => {
      switch (q) {
        case 'total_ok_radio_model_untrusted': return '总账可用，蜂窝估算不可信';
        case 'total_ok_radio_model_reference': return '总账可用，蜂窝估算仅供参考';
        case 'fast_no_batterystats': return '系统分项正在加载';
        case 'no_system_snapshot': return '系统统计不可用';
        default: return '未知';
      }
    };
    const odpm = d.odpm_modem || {};
    const odpmValue = odpm.total_mah != null
      ? `${text(odpm.total_mah)} mAh · 当前会话变化量`
      : '暂无有效变化量';
    const liveGeneratedAt = d._live_generated_at || d.generated_at;
    const systemGeneratedAt = d._system_generated_at || null;
    const liveRefreshLabel = fmtDateTime(liveGeneratedAt, true);
    const systemSnapshot = d._has_full_system ? fmtDateTime(systemGeneratedAt, true) : '系统统计尚未加载';
    const systemCacheAgeSec = getEnergySystemAgeSeconds(d, liveGeneratedAt, systemGeneratedAt);
    const systemCacheAge = systemCacheAgeSec == null ? '—' : `${Math.floor(systemCacheAgeSec)} 秒前`;
    const cacheTtlSec = Number(d.cache_ttl_sec);
    const systemCacheExpired = Number.isFinite(cacheTtlSec) && cacheTtlSec > 0
      && systemCacheAgeSec != null && systemCacheAgeSec > cacheTtlSec;
    const systemCacheWarn = !d._has_full_system || d.system_cache_stale === true || systemCacheExpired;
    const systemCacheState = !d._has_full_system
      ? '正在加载'
      : (d.system_cache_stale === true ? '使用较早数据' : (systemCacheExpired ? '正在更新' : '正常'));
    const windows = Array.isArray(d.history_windows) ? d.history_windows : [];
    const windowView = (win) => {
      if (!win) return null;
      const min = Number(win.minutes);
      const p = win.power || {};
      const t = win.thermal || {};
        const pSamples = Number(p.effective_samples ?? p.samples ?? 0);
        const tSamples = Number(t.samples || 0);
        const expectedSec = Number.isFinite(Number(p.expected_elapsed_sec))
          ? Number(p.expected_elapsed_sec)
          : min * 60;
        const coverageSec = Number.isFinite(Number(p.coverage_elapsed_sec))
          ? Number(p.coverage_elapsed_sec)
          : Number(p.elapsed_sec || 0);
        const rawCoverageRatio = Number(p.coverage_ratio);
        const coverageRatio = Number.isFinite(rawCoverageRatio)
          ? Math.max(0, Math.min(1, rawCoverageRatio))
          : (expectedSec > 0 ? Math.max(0, Math.min(1, coverageSec / expectedSec)) : 0);
        const coveragePercent = Math.round(coverageRatio * 100);
        const hasTrustedAverage = typeof p.trusted_for_average === 'boolean';
        const trustedAverage = hasTrustedAverage
          ? p.trusted_for_average
          : (p.quality === 'pure_discharge' && coverageRatio >= 0.8 && pSamples >= 2);
        let value = '';
        let detail = '';
        if (trustedAverage) {
          value = fmtMilliwatt(p.avg_discharge_mw);
          detail = `${fmtMahPerHour(p.avg_discharge_mah_per_h)} · 实际放电 ${fmtMah(p.discharge_mah)}`;
        } else if (p.quality === 'mixed_charge_discharge') {
          value = '混合收支';
          detail = `放电 ${fmtMah(p.discharge_mah)} · 回充 ${fmtMah(p.charge_mah)}`;
        } else if (p.quality === 'charging_endpoint') {
          value = '当前接电';
          detail = `放电 ${fmtMah(p.discharge_mah)} · 回充 ${fmtMah(p.charge_mah)}`;
        } else if (p.quality === 'partial_window') {
          value = '覆盖不足';
          detail = '覆盖未达到 80%，暂不显示平均功耗';
        } else if (p.quality === 'no_discharge_delta') {
          value = '暂无变化';
          detail = '电荷计未观察到可用放电差值';
        } else {
          value = pSamples >= 2 ? qualityLabel(p.quality) : '采样不足';
          detail = '等待更多有效电荷计样本';
        }
        const net = Number(p.net_discharge_mah);
        const netText = Number.isFinite(net)
          ? (net >= 0 ? `净放电 ${fmtMah(net)}` : `净回充 ${fmtMah(Math.abs(net))}`)
          : '净收支 —';
        const startsAtWindow = Number.isFinite(Number(p.window_start_ts))
          && Number.isFinite(Number(p.start_ts))
          && Number(p.window_start_ts) <= Number(p.start_ts);
        const baselineText = p.baseline_used === true
          ? '起点已补齐'
          : (startsAtWindow ? '起点样本完整' : '起点样本不足');
        return {
          min, p, t, pSamples, tSamples, expectedSec, coverageSec, coveragePercent,
          trustedAverage, tone: trustedAverage ? 'good' : qualityTone(p.quality), value, detail,
          netText, baselineText
        };
    };
    const views = windows.map(windowView).filter(Boolean);
    if (!views.some((view) => view.min === state.energyDetail.activeWindowMinutes) && views.length) {
      state.energyDetail.activeWindowMinutes = views.find((view) => view.min === 30)?.min || views[0].min;
    }
    const activeView = views.find((view) => view.min === state.energyDetail.activeWindowMinutes) || null;
    const renderSignature = getEnergyRenderSignature(d);
    const existingRoot = refs.detailBody.firstElementChild;
    if (state.energyDetail.renderSignature === renderSignature && existingRoot?.classList.contains('energy-overview')) return;
    const root = el('div', 'energy-overview');

    const usedMah = Number(scope.used_mah);
    const batteryLevel = Number(charge.level);
    const hero = el('section', `energy-hero${chargeLike ? ' warn' : ''}`);
    const heroCopy = el('div', 'energy-hero-copy');
    const heroTop = el('div', 'energy-hero-top');
    heroTop.append(el('span', 'energy-hero-kicker', '当前放电会话'), el('span', qualityBadge(scope.quality), qualityLabel(scope.quality)));
    const heroValue = el('div', 'energy-hero-value');
    heroValue.append(el('strong', '', Number.isFinite(usedMah) ? usedMah.toFixed(1) : '—'), el('span', '', 'mAh'));
    const levelChange = Number.isFinite(Number(scope.level_start)) && Number.isFinite(Number(scope.level_now))
      ? `${scope.level_start}% → ${scope.level_now}%`
      : '电量变化 —';
    heroCopy.append(heroTop, heroValue, el('div', 'energy-hero-meta', `${fmtDuration(scope.elapsed_sec)} · ${levelChange} · ${chargeStatusLabel}`));
    const levelRing = el('div', 'energy-level-ring');
    levelRing.style.setProperty('--energy-level', `${Math.max(0, Math.min(100, Number.isFinite(batteryLevel) ? batteryLevel : 0))}%`);
    levelRing.append(el('strong', '', Number.isFinite(batteryLevel) ? `${batteryLevel}%` : '—'), el('small', '', powerSourceLabel));
    hero.append(heroCopy, levelRing);
    root.appendChild(hero);

    if (activeView && activeView.p.quality !== 'pure_discharge') {
      const warningMap = {
        mixed_charge_discharge: '窗口内同时发生充电和放电，仅显示实际收支。',
        charging_endpoint: `当前为${powerSourceLabel}，短窗口仅显示充放电收支。`,
        partial_window: '窗口覆盖不足 80%，暂不显示平均功耗。',
        insufficient_samples: '有效采样点不足，暂时只显示基础状态。',
        no_discharge_delta: '电荷计暂未观察到放电差值，等待下一批采样。',
        no_data: '暂未获得短窗口数据。'
      };
      const alert = el('div', `energy-alert ${activeView.tone}`);
      alert.setAttribute('role', 'status');
      alert.append(el('span', 'energy-alert-icon', '!'), el('span', '', warningMap[activeView.p.quality] || text(scope.warning)));
      root.appendChild(alert);
    }

    const trend = el('section', 'energy-section');
    trend.appendChild(sectionHead('最近趋势', '选择时间范围查看功耗与温度。'));
    const rangeTabs = el('div', 'energy-range-tabs');
    rangeTabs.setAttribute('role', 'group');
    rangeTabs.setAttribute('aria-label', '功耗统计窗口');
    views.forEach((view) => {
      const button = el('button', `energy-range-btn ${view.tone}${view.min === state.energyDetail.activeWindowMinutes ? ' active' : ''}`, `${view.min} 分钟`);
      button.type = 'button';
      button.setAttribute('aria-pressed', view.min === state.energyDetail.activeWindowMinutes ? 'true' : 'false');
      button.addEventListener('click', () => {
        state.energyDetail.activeWindowMinutes = view.min;
        renderEnergyDetail(state.energyDetail.liveData || input, { fullData: state.energyDetail.fullData });
      });
      rangeTabs.appendChild(button);
    });
    trend.appendChild(rangeTabs);
    if (activeView) {
      const focus = el('article', `energy-window-focus ${activeView.tone}`);
      const focusHead = el('div', 'energy-window-focus-head');
      const focusTitle = el('div', 'energy-window-focus-title');
      focusTitle.append(el('span', '', activeView.trustedAverage ? '平均放电功耗' : qualityLabel(activeView.p.quality)), el('strong', '', activeView.value));
      focusHead.append(focusTitle, el('span', qualityBadge(activeView.p.quality), qualityLabel(activeView.p.quality)));
      focus.append(focusHead, el('div', 'energy-window-focus-desc', activeView.detail));
      const miniGrid = el('div', 'energy-window-mini-grid');
      [
        ['实际放电', fmtMah(activeView.p.discharge_mah)],
        ['回充', fmtMah(activeView.p.charge_mah)],
        ['温度', activeView.tSamples >= 2 ? `${fmtTempC(activeView.t.temp_avg_c)} / ${fmtTempC(activeView.t.temp_max_c)}` : '—']
      ].forEach(([label, value]) => {
        const item = el('div', 'energy-window-mini');
        item.append(el('span', '', label), el('strong', '', value));
        miniGrid.appendChild(item);
      });
      focus.appendChild(miniGrid);
      const coverage = el('div', 'energy-coverage');
      const coverageCopy = el('div', 'energy-coverage-copy');
      coverageCopy.append(el('span', '', `覆盖 ${fmtDuration(activeView.coverageSec)} / ${fmtDuration(activeView.expectedSec)}`), el('strong', '', `${activeView.coveragePercent}%`));
      const bar = el('div', 'energy-coverage-bar');
      const fill = el('span');
      fill.style.width = `${activeView.coveragePercent}%`;
      bar.appendChild(fill);
      coverage.append(coverageCopy, bar, el('div', 'energy-window-footnote', `${activeView.netText} · ${activeView.pSamples} 个有效点 · ${activeView.baselineText}`));
      focus.appendChild(coverage);
      trend.appendChild(focus);
    } else {
      trend.appendChild(el('div', 'energy-empty', '暂无短窗口数据'));
    }
    root.appendChild(trend);

    const daily = el('section', 'energy-section');
    daily.appendChild(sectionHead('今日收支', `${fmtDuration(today.elapsed_sec)} · ${Number.isFinite(Number(today.samples)) ? today.samples : 0} 个采样点`));
    const dailyGrid = el('div', 'energy-daily-grid');
    [
      ['放电', fmtMah(today.discharge_mah), ''],
      ['回充', fmtMah(today.charge_mah), Number(today.charge_mah) > 0 ? 'warn' : ''],
      ['净电量', fmtSignedPercent(today.net_level_delta), Number(today.net_level_delta) < 0 ? 'primary' : '']
    ].forEach(([label, value, tone]) => {
      const item = el('div', `energy-daily-item ${tone}`);
      item.append(el('span', '', label), el('strong', '', value));
      dailyGrid.appendChild(item);
    });
    daily.appendChild(dailyGrid);
    root.appendChild(daily);

    const rankList = (items, type) => {
      const list = el('div', 'energy-rank-list');
      const max = Math.max(...items.map((item) => Number(item.value) || 0), 1);
      items.forEach((item, index) => {
        const itemRow = el('div', 'energy-rank-row');
        const marker = el('span', 'energy-rank-index', String(index + 1));
        const copy = el('div', 'energy-rank-copy');
        copy.append(el('strong', '', item.label), el('small', '', item.subtitle || (type === 'app' ? '系统模型估算' : '系统分项')));
        const value = el('div', 'energy-rank-value', fmtMah(item.value));
        const bar = el('div', 'energy-rank-bar');
        const fill = el('span');
        fill.style.width = `${Math.max(4, Math.min(100, ((Number(item.value) || 0) / max) * 100))}%`;
        bar.appendChild(fill);
        itemRow.append(marker, copy, value, bar);
        list.appendChild(itemRow);
      });
      return list;
    };
    const packageLabel = (app) => {
      const pkg = String(app.pkg || '');
      return friendlyPackageLabel(pkg, app.label);
    };
    const apps = Array.isArray(d.apps) ? d.apps.map((app) => {
      const pkg = String(app.pkg || '');
      const legacyUid = /^u\d+[ai]\d+$/.test(pkg) ? pkg : '';
      const uid = String(app.uid || legacyUid || (Number.isFinite(Number(app.uid_num)) ? `UID ${app.uid_num}` : 'UID 未知'));
      const displayPkg = legacyUid ? '' : pkg;
      const subtitle = displayPkg ? `${displayPkg} · ${uid}` : `${uid} · 未找到当前安装包`;
      return { label: packageLabel(app), subtitle, value: Number(app.mah) || 0 };
    }).filter((app) => app.value > 0) : [];
    const components = [
      { label: '屏幕', value: Number(d.screen) || 0 },
      { label: 'CPU', value: Number(d.cpu) || 0 },
      { label: 'Wi-Fi', value: Number(d.wifi) || 0 },
      { label: '唤醒锁', value: Number(d.wakelock) || 0 }
    ].filter((item) => item.value > 0).sort((a, b) => b.value - a.value);
    const attribution = el('section', 'energy-section');
    attribution.appendChild(sectionHead('耗电构成', d._has_full_system ? `系统统计更新于 ${systemCacheAge}` : '正在加载系统统计'));
    if (d._has_full_system) {
      const groups = el('div', 'energy-attribution-grid');
      const appGroup = el('div', 'energy-attribution-group');
      appGroup.appendChild(el('div', 'energy-group-title', '耗电应用'));
      appGroup.appendChild(apps.length ? rankList(apps.slice(0, 3), 'app') : el('div', 'energy-empty compact', '暂无应用归因'));
      const systemGroup = el('div', 'energy-attribution-group');
      systemGroup.appendChild(el('div', 'energy-group-title', '系统分项'));
      systemGroup.appendChild(components.length ? rankList(components.slice(0, 4), 'system') : el('div', 'energy-empty compact', '暂无系统分项'));
      groups.append(appGroup, systemGroup);
      attribution.appendChild(groups);
    } else {
      attribution.appendChild(el('div', 'energy-loading-card', '正在加载系统分项和应用排行。'));
    }
    const modemNote = el('div', `energy-modem-note ${odpm.total_mah != null ? 'good' : 'off'}`);
    modemNote.append(el('strong', '', '蜂窝'), el('span', '', odpm.total_mah != null ? odpmValue : '蜂窝数据暂不可用；系统模型偏差较大，已从排行中排除。'));
    attribution.appendChild(modemNote);
    root.appendChild(attribution);

    const technical = el('section', 'energy-section energy-technical');
    technical.appendChild(sectionHead('更多统计', '查看数据口径、系统模型和历史导出。'));
    const scopeBody = el('div', 'energy-disclosure-body');
    const scopeList = el('div', 'data-list');
    scopeList.append(
      row('默认口径', '当前放电会话', 'badge good'),
      row('数据质量', qualityLabel(scope.quality), qualityBadge(scope.quality)),
      row('当前状态', chargeStatusLabel, chargeLike ? 'badge warn' : 'badge off'),
      row('外接电源', powerSourceLabel, externalPower ? 'badge warn' : 'badge good'),
      row('会话开始', fmtDateTime(scope.start_ts)),
      row('最近重置原因', fmtSessionResetReason(scope.reset_reason)),
      row('重置规则', text(scope.reset_rule)),
      row('口径提示', scope.quality === 'charging_endpoint' ? `当前为${powerSourceLabel}，不代表此前待机状态` : qualityLabel(scope.quality)),
      row('今日起点', fmtDateTime(today.start_ts)),
      row('今日首个样本', fmtDateTime(today.window_start_ts)),
      row('轻量刷新时间', liveRefreshLabel, d._using_fast_live ? 'badge good' : 'badge off')
    );
    scopeBody.appendChild(scopeList);
    technical.appendChild(disclosure('scope', '数据口径', `${qualityLabel(scope.quality)} · ${chargeStatusLabel}`, scopeBody));

    const systemBody = el('div', 'energy-disclosure-body');
    const systemList = el('div', 'data-list');
    systemList.append(
      row('系统窗口', fmtBatterystatsWindow(bs.window_label)),
      row('统计窗口', comparable ? '一致，可比较' : '不一致或未知', comparable ? 'badge good' : 'badge warn'),
      row('模型质量', modelQualityLabel(bs.model_quality), radioUntrusted ? 'badge warn' : 'badge off'),
      row('系统统计时间', systemSnapshot, d._has_full_system ? 'data-val' : 'badge warn'),
      row('数据更新时间', systemCacheAge, systemCacheWarn ? 'badge warn' : 'badge off'),
      row('数据状态', systemCacheState, systemCacheWarn ? 'badge warn' : 'badge good'),
      row('刷新周期', Number.isFinite(Number(d.cache_ttl_sec)) ? `${d.cache_ttl_sec} 秒` : '—'),
      row('电池容量', `${text(d.cap)} mAh`),
      row('预估耗电', `${text(d.drain)} mAh`),
      row('亮屏耗电', `${text(d.scron)} mAh`),
      row('息屏耗电', `${text(d.scroff)} mAh`),
      row('屏幕', `${text(d.screen)} mAh`),
      row('CPU', `${text(d.cpu)} mAh`),
      row('Wi-Fi', `${text(d.wifi)} mAh`),
      row('唤醒锁', `${text(d.wakelock)} mAh`),
      row('蜂窝硬件计量 (ODPM)', odpmValue, odpm.total_mah != null ? 'data-val' : 'badge off'),
      row('蜂窝系统估算', `${text(d.cell)} mAh · 仅供参考`, radioUntrusted ? 'badge warn' : 'badge off'),
      row('蜂窝说明', text(bs.radio_note))
    );
    systemBody.appendChild(systemList);
    if (apps.length) {
      systemBody.appendChild(el('div', 'energy-group-title detail', `全部应用归因 Top ${apps.length}`));
      systemBody.appendChild(rankList(apps, 'app'));
    }
    technical.appendChild(disclosure('system', '系统耗电估算', d._has_full_system ? `${text(d.drain)} mAh · ${systemCacheAge}` : '正在加载', systemBody));

    const exportBody = el('div', 'energy-disclosure-body');
    exportBody.appendChild(el('p', 'energy-export-note', '将指定窗口的功耗与温度原始 CSV 保存到 /sdcard/Download；“本次窗口”从打开当前页面时开始。'));
    const exportWrap = el('div', 'energy-export-actions');
    [15, 30, 60].forEach((min) => {
      const btn = el('button', 'tiny-btn', `保存 ${min} 分钟`);
      btn.type = 'button';
      btn.addEventListener('click', () => exportHistoryWindow(min, btn));
      exportWrap.appendChild(btn);
    });
    const sessionBtn = el('button', 'tiny-btn', '保存本次窗口');
    sessionBtn.type = 'button';
    sessionBtn.addEventListener('click', () => exportHistoryWindow('session', sessionBtn));
    exportWrap.appendChild(sessionBtn);
    exportBody.appendChild(exportWrap);
    technical.appendChild(disclosure('export', '历史与导出', '导出 15/30/60 分钟或本次窗口 CSV', exportBody));
    root.appendChild(technical);

    if (existingRoot?.classList.contains('energy-overview')) reconcileStableDom(existingRoot, root);
    else refs.detailBody.replaceChildren(root);
    state.energyDetail.renderSignature = renderSignature;
  } catch (err) {
    state.energyDetail.renderSignature = '';
    refs.detailBody.replaceChildren(); refs.detailBody.appendChild(errorBlock(err.message));
  }
}

function scheduleEnergyDetailRefresh(delay = ENERGY_DETAIL_REFRESH_MS) {
  if (state.energyDetail.timer) clearTimeout(state.energyDetail.timer);
  if (!isWebUiActive() || !refs.detailModal.classList.contains('open')) return;
  const requestId = state.energyDetail.requestId;
  state.energyDetail.timer = window.setTimeout(async () => {
    state.energyDetail.timer = null;
    if (!isWebUiActive() || !refs.detailModal.classList.contains('open') || requestId !== state.energyDetail.requestId) return;
    if (state.energyDetail.requestKind) {
      scheduleEnergyDetailRefresh(POLL_MIN_DELAY_MS);
      return;
    }
    try {
      const live = await fetchEnergyFastDetail();
      if (!live || requestId !== state.energyDetail.requestId) return;
      if (isFullEnergyDetailData(live)) state.energyDetail.fullData = live;
      else state.energyDetail.liveData = live;
      renderEnergyDetail(live, { fullData: state.energyDetail.fullData });
    } catch (_) {}
    if (isWebUiActive() && refs.detailModal.classList.contains('open') && requestId === state.energyDetail.requestId) {
      scheduleEnergyDetailRefresh();
    }
  }, delay);
}

function scheduleEnergySystemRefresh(delay = getEnergySystemRefreshDelay()) {
  if (state.energyDetail.fullTimer) clearTimeout(state.energyDetail.fullTimer);
  if (!isWebUiActive() || !refs.detailModal.classList.contains('open')) return;
  const requestId = state.energyDetail.requestId;
  state.energyDetail.fullTimer = window.setTimeout(async () => {
    state.energyDetail.fullTimer = null;
    if (!isWebUiActive() || !refs.detailModal.classList.contains('open') || requestId !== state.energyDetail.requestId) return;
    if (state.energyDetail.requestKind) {
      scheduleEnergySystemRefresh(POLL_MIN_DELAY_MS);
      return;
    }
    try {
      const full = await fetchEnergySystemDetail();
      if (!full || requestId !== state.energyDetail.requestId) return;
      if (isFullEnergyDetailData(full)) {
        state.energyDetail.fullData = full;
        state.energyDetail.liveData = full;
        renderEnergyDetail(full, { fullData: state.energyDetail.fullData });
      }
    } catch (_) {}
    if (isWebUiActive() && refs.detailModal.classList.contains('open') && requestId === state.energyDetail.requestId) {
      scheduleEnergySystemRefresh();
    }
  }, delay);
}

async function openEnergyDetail() {
  stopTempChartRefresh();
  stopEnergyDetailRefresh();
  state.energyDetail.fullData = null;
  state.energyDetail.liveData = null;
  state.energyDetail.renderSignature = '';
  const requestId = state.energyDetail.requestId;
  refs.detailTitle.textContent = '功耗统计';
  setStaticHtml(refs.detailBody, '<div style="text-align:center;color:var(--text-3);padding:24px 0;font-size:13px">正在加载功耗数据…</div>');
  refs.detailModal.classList.remove('history-mode');
  refs.detailModal.classList.add('energy-mode');
  refs.detailModal.classList.add('open');
  pushModalState('detail');
  queueNextPoll(computeNextPollDelay());
  try {
    const live = await fetchEnergyFastDetail();
    if (requestId !== state.energyDetail.requestId) return;
    state.energyDetail.liveData = live;
    renderEnergyDetail(live, { fullData: state.energyDetail.fullData });
    scheduleEnergyDetailRefresh();
    scheduleEnergySystemRefresh(350);
  } catch (err) {
    if (requestId !== state.energyDetail.requestId) return;
    try {
      const initial = await fetchEnergyDetailWithRetry();
      if (requestId !== state.energyDetail.requestId) return;
      if (isFullEnergyDetailData(initial)) {
        state.energyDetail.fullData = initial;
        state.energyDetail.liveData = initial;
      } else {
        state.energyDetail.liveData = initial;
      }
      renderEnergyDetail(initial, { fullData: state.energyDetail.fullData });
      scheduleEnergyDetailRefresh(350);
      scheduleEnergySystemRefresh();
    } catch (fallbackErr) {
      if (requestId !== state.energyDetail.requestId) return;
      refs.detailBody.replaceChildren();
      refs.detailBody.appendChild(errorBlock(fallbackErr.message || err.message));
    }
  }
}

async function applyProfile(profile) {
  if (state.schedOwner === 'external') {
    showToast(hasExternalScheduler() ? getSchedulerStatusText() : '本模块调度未启用');
    appendLog(hasExternalScheduler()
      ? `${getSchedulerStatusText()}，未切换本模块 profile`
      : '本模块 CPU 调度未启用，未切换 profile', 'warn');
    return;
  }
  if (profile === state.currentProfile || state.cpuBusy) return;
  const prevPolicy = state.profilePolicy;
  const card = refs.profileList.querySelector(`[data-profile="${profile}"]`);
  if (!card) return;
  card.classList.add('loading');
  appendLog(`切换到 ${PROFILES[profile].name}…`, 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.profile, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ profile }), timeoutMs: 8000 });
    if (data.ok) {
      applyProfileState(data);
      const forcedManual = prevPolicy === 'auto' && data.policy === 'manual';
      showToast(forcedManual ? `已切回手动：${PROFILES[profile].name}` : `切换至：${PROFILES[profile].name}`);
      appendLog(forcedManual ? `自动已退出，手动切到 ${PROFILES[profile].name}` : `${PROFILES[profile].name} 已应用`, 'ok');
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

async function setProfilePolicy(policy) {
  if (state.schedOwner === 'external') {
    showToast(hasExternalScheduler() ? getSchedulerStatusText() : '本模块调度未启用');
    appendLog(hasExternalScheduler()
      ? `${getSchedulerStatusText()}，自动/手动策略暂停`
      : '本模块 CPU 调度未启用，自动/手动策略暂停', 'warn');
    return;
  }
  if (state.profilePolicy === policy || state.profilePolicyBusy) return;
  state.profilePolicyBusy = true;
  syncProfileUi();
  appendLog(policy === 'auto' ? '启用自动调度…' : '切回手动调度…', 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.profile, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ policy }),
      timeoutMs: 8000
    });
    if (data.ok) {
      applyProfileState(data);
      showToast(policy === 'auto' ? '已启用自动调度' : `已切回手动：${PROFILES[state.currentProfile].name}`);
      appendLog(policy === 'auto'
        ? `自动调度已启用：${describeAutoReason(state.autoReason)}`
        : `已切回手动：${PROFILES[state.currentProfile].name}`, 'ok');
      refreshCpu();
    } else {
      showToast(`切换失败：${data.error || '未知'}`);
      appendLog(data.error || '切换失败', 'err');
    }
  } catch (err) {
    showToast('请求失败，检查服务是否运行');
    appendLog(String(err), 'err');
  } finally {
    state.profilePolicyBusy = false;
    syncProfileUi();
  }
}

async function toggleSchedOwner() {
  if (state.schedOwnerBusy) return;
  const nextOwner = state.schedOwner === 'external' ? 'pixel' : 'external';
  state.schedOwnerBusy = true;
  syncProfileUi();
  const actionText = nextOwner === 'external'
    ? (hasExternalScheduler() ? '不覆盖外部调度，交出 CPU 调度…' : '停用本模块 CPU 调度…')
    : (hasExternalScheduler() ? '本模块覆盖接管 CPU 调度…' : '启用本模块 CPU 调度…');
  appendLog(actionText, 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.profile, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sched_owner: nextOwner }),
      timeoutMs: 8000
    });
    if (data.ok) {
      applyProfileState(data);
      showToast(nextOwner === 'external'
        ? (hasExternalScheduler() ? '已不覆盖外部调度' : '已停用本模块调度')
        : (hasExternalScheduler() ? '本模块已覆盖接管' : '已启用本模块调度'));
      appendLog(nextOwner === 'external'
        ? (hasExternalScheduler()
          ? `不覆盖 ${getExternalSchedulerName()}：本模块停止写 CPU 调度节点`
          : '本模块 CPU 调度已停用：保留系统/外部调度现状')
        : `本模块调度已启用：${PROFILES[state.currentProfile].name}`, 'ok');
      refreshCpu();
    } else {
      showToast(`切换失败：${data.error || '未知'}`);
      appendLog(data.error || '切换失败', 'err');
    }
  } catch (err) {
    showToast('请求失败，检查服务是否运行');
    appendLog(String(err), 'err');
  } finally {
    state.schedOwnerBusy = false;
    syncProfileUi();
  }
}

async function triggerOwnerArbiter() {
  if (state.ownerArbiterBusy || !state.fasRsDetected) return;
  state.ownerArbiterBusy = true;
  syncOwnerArbiterUi();
  appendLog('正在检查外部调度接管状态…', 'dim');
  refs.logCard.classList.add('open');
  try {
    const data = await apiFetch(API.ownerArbiter, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'tick' }),
      timeoutMs: 10000
    });
    if (data.ok) {
      showToast('调度状态已更新');
      appendLog('外部调度接管状态已更新', 'ok');
      await loadSavedProfile();
      await refreshCpu();
    } else {
      showToast(`检查失败：${data.error || '未知'}`);
      appendLog(data.error || '外部调度状态检查失败', 'err');
    }
  } catch (err) {
    showToast('请求失败，检查 WebUI 服务');
    appendLog(String(err), 'err');
  } finally {
    state.ownerArbiterBusy = false;
    syncOwnerArbiterUi();
  }
}

async function applyThermal(offset) {
  if (offset === state.currentOffset || state.thermalApplyBusy) return;
  const prev = state.currentOffset;
  const card = refs.thermalList.querySelector(`[data-offset="${offset}"]`);
  if (!card) return;
  state.thermalApplyBusy = true;
  card.classList.add('loading');
  appendLog(`切换温控阈值 ${THERMAL_PRESETS[offset].name}…`, 'dim');
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
        appendLog(`${THERMAL_PRESETS[offset].name} 已保存（重启后生效）`, 'warn');
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
    state.thermalApplyBusy = false;
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
  try {
    await apiFetch(API.reboot, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'reboot', confirm: true }),
      timeoutMs: 8000
    });
  } catch (_) {}
}

async function toggleSwapMode() {
  if (state.swapBusy) return;
  state.swapBusy = true;
  const newMode = state.swapMode === 'optimized' ? 'stock' : 'optimized';
  try {
    const data = await apiFetch(API.swap, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mode: newMode }), timeoutMs: 8000 });
    state.swapMode = data.mode || newMode;
    state.swapData = data;
    showToast(newMode === 'optimized' ? '已应用模块默认 VM 参数' : '已恢复原厂 VM 参数');
    appendLog(newMode === 'optimized' ? 'Swap 模块默认已应用' : 'Swap 已恢复原厂', 'ok');
    renderSwapCard(data);
    refreshSwap();
  } catch (_) {
    showToast('请求失败');
  } finally {
    state.swapBusy = false;
  }
}

async function applySwapCustom() {
  if (state.swapBusy) return;
  state.swapBusy = true;
  const values = getSwapTuneValues();
  try {
    const data = await apiFetch(API.swap, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode: 'custom', ...values }),
      timeoutMs: 8000
    });
    state.swapMode = data.mode || 'custom';
    state.swapData = data;
    showToast('自定义 VM 参数已应用');
    appendLog('Swap 自定义参数已应用', 'ok');
    renderSwapCard(data);
    closeSwapTuneModal();
    refreshSwap();
  } catch (err) {
    showToast(`请求失败：${err.message || '未知错误'}`);
  } finally {
    state.swapBusy = false;
  }
}

async function doFullRefresh() {
  showToast('正在刷新…', 1000);
  await Promise.all([refreshCpu(), refreshThermal(), refreshSwap()]);
  await Promise.allSettled([refreshNrSwitch(), refreshUecap(), refreshBaseband(), refreshNtp(), refreshStandbyGuard(), refreshBgRestrict(), loadInfo()]);
  markPollFresh(['cpu', 'thermal', 'optim', 'slow']);
  queueNextPoll(computeNextPollDelay());
  showToast('已刷新');
}

function shouldPollCpu() {
  return isWebUiActive() && (state.currentTab === 'home' || state.currentTab === 'tune');
}

function shouldPollThermal() {
  return isWebUiActive() && (state.currentTab === 'home' || state.currentTab === 'tune');
}

function shouldPollOptim() {
  return isWebUiActive() && (state.currentTab === 'home' || state.currentTab === 'system');
}

function shouldPollSlow() {
  return isWebUiActive() && (state.currentTab === 'home' || state.currentTab === 'network' || state.currentTab === 'system');
}

function refreshCurrentTabData() {
  if (!isWebUiActive()) return;
  const now = Date.now();
  if (state.currentTab === 'home') {
    markPollFresh(['cpu', 'thermal', 'optim', 'slow'], now);
    refreshCpu();
    refreshThermal();
    refreshSwap();
    refreshNrSwitch();
    refreshUecap();
    refreshBaseband();
    refreshNtp();
    refreshStandbyGuard();
    loadInfo();
    queueNextPoll(computeNextPollDelay(now));
    return;
  }
  if (state.currentTab === 'tune') {
    markPollFresh(['cpu', 'thermal'], now);
    refreshCpu();
    refreshThermal();
    queueNextPoll(computeNextPollDelay(now));
    return;
  }
  if (state.currentTab === 'network') {
    markPollFresh(['slow'], now);
    refreshNrSwitch();
    refreshUecap();
    refreshBaseband();
    refreshStandbyGuard();
    loadInfo();
    queueNextPoll(computeNextPollDelay(now));
    return;
  }
  if (state.currentTab === 'system') {
    markPollFresh(['optim', 'slow'], now);
    refreshSwap();
    refreshBgRestrict();
    refreshStandbyGuard();
    refreshNtp();
    loadInfo();
    queueNextPoll(computeNextPollDelay(now));
  }
}

function startPolling() {
  if (state.poller.running) return;
  state.poller.running = true;
  queueNextPoll(computeNextPollDelay());
}

function stopPolling() {
  state.poller.running = false;
  clearTimeout(state.poller.timer);
  state.poller.timer = null;
}

function pauseForegroundWork() {
  if (state.foregroundPaused) return;
  state.foregroundPaused = true;
  stopPolling();
  pauseTempChartRefresh();
  pauseEnergyDetailRefresh();
  stopDeviceClock();
}

function resumeForegroundWork() {
  if (document.visibilityState !== 'visible' || document.hidden) return;
  const wasPaused = state.foregroundPaused;
  state.foregroundPaused = false;
  if (!wasPaused && state.poller.running) return;
  state.poller.lastInteractionAt = Date.now();
  refreshCurrentTabData();
  startPolling();
  syncDeviceClockForTab();
  if (refs.detailModal?.classList.contains('history-mode') && state.tempChart.draw) {
    triggerThermalBurst({ prompt: false });
    scheduleTempChartRefresh(250);
  }
  if (refs.detailModal?.classList.contains('energy-mode')) {
    scheduleEnergyDetailRefresh(250);
    scheduleEnergySystemRefresh(800);
  }
}

function bindStaticEvents() {
  window.addEventListener('pointerdown', noteUserActivity, { passive: true });
  document.addEventListener('keydown', noteUserActivity);
  document.querySelectorAll('.tab-item').forEach((button) => button.addEventListener('click', () => switchTab(button.dataset.tab)));
  document.querySelectorAll('[data-theme-option]').forEach((button) => {
    button.addEventListener('click', () => {
      applyTheme(button.dataset.themeOption, true);
      closeThemeSheet();
      showToast(`已切换为${getThemeLabel(button.dataset.themeOption)}`);
    });
  });
  document.querySelectorAll('[data-seg-theme]').forEach((button) => {
    button.addEventListener('click', () => {
      applyTheme(button.dataset.segTheme, true);
      showToast(`已切换为${getThemeLabel(button.dataset.segTheme)}`);
    });
  });
  const swatchRow = $('swatch-row');
  if (swatchRow) swatchRow.addEventListener('click', (evt) => {
    const sw = evt.target.closest('.swatch');
    if (!sw) return;
    applyPalette(sw.dataset.palette, true);
    const p = PALETTES.find((x) => x.name === sw.dataset.palette);
    showToast(`主题色：${p ? p.label : '已应用'}`);
  });
  $('palette-hex-apply').addEventListener('click', applyCustomHex);
  $('palette-hex-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') applyCustomHex(); });
  $('theme-open-btn').addEventListener('click', openThemeSheet);
  $('refresh-all-btn').addEventListener('click', doFullRefresh);
  $('sched-owner-toggle-btn').addEventListener('click', toggleSchedOwner);
  $('owner-arbiter-tick-btn').addEventListener('click', triggerOwnerArbiter);
  $('swap-toggle-btn').addEventListener('click', toggleSwapMode);
  $('swap-detail-btn').addEventListener('click', () => openDetail('内存优化详情', buildSwapDetail(state.swapData)));
  $('swap-tune-btn').addEventListener('click', openSwapTuneModal);
  $('swap-tune-close-btn').addEventListener('click', closeSwapTuneModal);
  $('swap-tune-close-x').addEventListener('click', closeSwapTuneModal);
  $('swap-custom-apply-btn').addEventListener('click', applySwapCustom);
  $('swap-preset-optimized').addEventListener('click', () => setSwapTuneValues(SWAP_OPTIMIZED));
  $('swap-preset-stock').addEventListener('click', () => setSwapTuneValues(SWAP_STOCK));
  Object.keys(SWAP_LIMITS).forEach((key) => {
    refs.swapTuneInputs[key].addEventListener('input', (evt) => syncSwapTuneField(key, evt.target.value));
    refs.swapTuneNumbers[key].addEventListener('change', (evt) => syncSwapTuneField(key, evt.target.value));
    refs.swapTuneNumbers[key].addEventListener('keydown', (evt) => {
      if (evt.key === 'Enter') {
        evt.preventDefault();
        syncSwapTuneField(key, evt.target.value);
      }
    });
  });
  $('nr-switch-toggle-btn').addEventListener('click', toggleNrSwitch);
  $('sim2-auto-toggle-btn').addEventListener('click', toggleSim2AutoManage);
  $('idle-isolate-toggle-btn').addEventListener('click', toggleIdleIsolateMode);
  $('bg-restrict-toggle-btn').addEventListener('click', toggleBgRestrict);
  $('bg-restrict-add-btn').addEventListener('click', bgRestrictAdd);
  $('bg-restrict-pkg-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') bgRestrictAdd(); });
  $('bg-restrict-policy-select').addEventListener('change', syncBgRestrictControls);
  $('bg-restrict-refresh-btn').addEventListener('click', forceRefreshBgRestrict);
  $('nr-switch-detail-btn').addEventListener('click', () => openDetail('NR 息屏降级详情', NR_SWITCH_DETAIL));
  $('uecap-detail-btn').addEventListener('click', () => openDetail('UE 网络能力配置', UECAP_DETAIL));
  $('baseband-detail-btn').addEventListener('click', () => openDetail('基带模块说明', BASEBAND_DETAIL));
  $('baseband-refresh-btn').addEventListener('click', refreshBaseband);
  $('ntp-sync-btn').addEventListener('click', syncNtp);
  $('temp-chart-btn').addEventListener('click', openTempChart);
  $('energy-btn').addEventListener('click', openEnergyDetail);
  $('home-temp-chart-btn').addEventListener('click', openTempChart);
  $('log-toggle').addEventListener('click', () => refs.logCard.classList.toggle('open'));
  $('theme-close-btn').addEventListener('click', closeThemeSheet);
  $('detail-close-btn').addEventListener('click', closeDetailModal);
  $('detail-close-x').addEventListener('click', closeDetailModal);
  $('reboot-now-btn').addEventListener('click', rebootDevice);
  $('reboot-later-btn').addEventListener('click', closeRebootModal);
  $('reboot-cancel-btn').addEventListener('click', cancelThermalChange);
  $('open-cpu-detail-btn').addEventListener('click', () => {
    const cpuSet = {
      performance: 'top-app: cpu0-7\nforeground: cpu0-6\nbackground: cpu0-3',
      balanced: 'top-app: cpu0-7\nforeground: cpu0-6\nbackground: cpu0-3',
      battery: 'top-app: cpu0-6\nforeground: cpu0-6\nbackground: cpu0-3',
      default: 'top-app: cpu0-7\nforeground: cpu0-6\nbackground: cpu0-3'
    };
    let html = `<b>当前模式</b><br>${(PROFILES[state.currentProfile] || PROFILES.unknown).name}<br><br>`;
    html += state.schedOwner === 'external'
      ? `<b>cpuset 分配</b><br>${escapeHtml(getSchedulerStatusText())}`
      : `<b>cpuset 分配</b><br>${(cpuSet[state.currentProfile] || '未设置').replace(/\n/g, '<br>')}`;
    if (state.lastClusters && state.lastClusters.length) {
      state.lastClusters.forEach((cluster, index) => {
        const maxHz = cluster.max > 0 ? cluster.max : (CLUSTERS[index]?.maxHz || 0);
        html += `<br><br><b>${CLUSTERS[index]?.label || `Cluster ${index}`}</b><br>`;
        html += `cur: ${cluster.cur ? `${(cluster.cur / 1000).toFixed(0)} MHz` : '—'} / max: ${maxHz ? `${(maxHz / 1000).toFixed(0)} MHz` : '—'}<br>`;
        const respText = typeof cluster.resp_ms_text === 'string' ? cluster.resp_ms_text : cluster.resp_ms;
        const downText = typeof cluster.down_us_text === 'string' ? cluster.down_us_text : cluster.down_us;
        html += `resp_time: ${formatSchedValue(respText, 'ms')} · down_rate: ${formatSchedValue(downText, 'µs')}<br>`;
        html += `governor: ${cluster.gov || '—'}`;
      });
    } else html += '<br><br>暂无频率快照，请先刷新一次。';
    openDetail('CPU 调度参数详情', html);
  });
  refs.detailModal.querySelector('.modal-bg').addEventListener('click', closeDetailModal);
  refs.swapTuneModal.querySelector('.modal-bg').addEventListener('click', closeSwapTuneModal);
  refs.themeModal.querySelector('.modal-bg').addEventListener('click', closeThemeSheet);
  refs.profileList.addEventListener('click', (evt) => {
    const detailBtn = evt.target.closest('[data-action="profile-detail"]');
    if (detailBtn) openDetail(PROFILES[detailBtn.dataset.profile].name, PROFILES[detailBtn.dataset.profile].detail);
  });
  refs.profilePolicyManualBtn.addEventListener('click', () => setProfilePolicy('manual'));
  refs.profilePolicyAutoBtn.addEventListener('click', () => setProfilePolicy('auto'));
  refs.thermalList.addEventListener('click', (evt) => {
    const detailBtn = evt.target.closest('[data-action="thermal-detail"]');
    if (detailBtn) {
      const offset = Number(detailBtn.dataset.offset);
      openDetail(THERMAL_PRESETS[offset].name, THERMAL_PRESETS[offset].detail);
    }
  });
  window.addEventListener('popstate', (evt) => {
    const s = evt.state;
    if (refs.detailModal.classList.contains('open')) {
      stopTempChartRefresh();
      stopEnergyDetailRefresh();
      refs.detailModal.classList.remove('open', 'energy-mode', 'history-mode');
      return;
    }
    if (refs.swapTuneModal.classList.contains('open')) { refs.swapTuneModal.classList.remove('open'); queueNextPoll(POLL_MIN_DELAY_MS); return; }
    if (refs.themeModal.classList.contains('open')) { refs.themeModal.classList.remove('open'); return; }
    if (refs.rebootModal.classList.contains('open')) { refs.rebootModal.classList.remove('open'); return; }
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden || document.visibilityState !== 'visible') pauseForegroundWork();
    else resumeForegroundWork();
  });
  window.addEventListener('pagehide', pauseForegroundWork);
  window.addEventListener('pageshow', resumeForegroundWork);
  document.addEventListener('freeze', pauseForegroundWork);
  document.addEventListener('resume', resumeForegroundWork);
}

async function refreshDeferredInitData() {
  markPollFresh(['optim', 'slow']);
  await Promise.allSettled([refreshSwap(), refreshNrSwitch(), refreshUecap(), refreshBaseband(), refreshNtp(), refreshStandbyGuard(), refreshBgRestrict()]);
  queueNextPoll(computeNextPollDelay());
}

async function init() {
  const bootAt = Date.now();
  initRefs();
  loadWebuiTokenFromSession();
  if (!state.webuiToken) prefetchWebuiToken();
  initTheme();
  renderPaletteSwatches();
  initPalette();
  restoreThemeFromServerIfNeeded();
  renderProfileCards();
  renderThermalCards();
  bindStaticEvents();
  bindTabSwipe();
  bindPullToRefresh();
  bindTopbarScroll();
  state.foregroundPaused = document.hidden || document.visibilityState !== 'visible';
  refs.topbarSubtitle.textContent = TAB_META[state.currentTab];
  positionMarkers();
  state.poller.lastInteractionAt = bootAt;
  markPollFresh(['cpu', 'thermal', 'optim', 'slow'], bootAt);
  await loadInfo();
  await Promise.all([loadSavedProfile(), loadThermalPreset()]);
  await refreshCpu();
  await refreshThermal();
  markPollFresh(['cpu', 'thermal']);
  window.setTimeout(() => {
    if (isWebUiActive()) refreshDeferredInitData();
  }, 1000);
  if (isWebUiActive()) startPolling();
}

window.addEventListener('DOMContentLoaded', init);
