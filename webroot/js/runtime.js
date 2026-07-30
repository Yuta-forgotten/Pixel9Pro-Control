// WebUI 运行时常量、DOM 引用与功能注册表；加载顺序由 index.html 统一约束。
'use strict';

if (location.host !== '127.0.0.1:6210') {
  location.replace('http://127.0.0.1:6210');
}

const API = {
  profile: '/cgi-bin/profile.sh',
  status: '/cgi-bin/status.sh',
  info: '/cgi-bin/info.sh',
  thermal: '/cgi-bin/thermal.sh',
  thermalHistory: '/cgi-bin/thermal.sh?history=1',
  thermalFresh: '/cgi-bin/thermal.sh?fresh=1',
  thermalClear: '/cgi-bin/thermal.sh',
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
    detail: '这是内部手动性能基线：中大核更早补位，前台峰值响应更强。代价是温升更快；自动策略不会进入此档。'
  },
  balanced: {
    name: '均衡',
    summary: '兼顾前台响应与日常功耗，适合作为常用档位。',
    desc: '保留全核调度能力，同时控制不必要的升频。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z"/></svg>',
    modeClass: 'mode-balanced',
    detail: '日常均衡基线：保留全核调度能力，同时抑制不必要的 per-task boost。'
  },
  battery: {
    name: '省电',
    summary: '减少大核参与并放缓升频，降低轻中负载功耗。',
    desc: '优先使用小中核，适合待机与轻度使用。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M15.67 4H14V2h-4v2H8.33C7.6 4 7 4.6 7 5.33v15.33C7 21.4 7.6 22 8.33 22h7.33c.74 0 1.34-.6 1.34-1.33V5.33C17 4.6 16.4 4 15.67 4zM11 19v-2H9l3-5 3 5h-2v2h-2z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M15.67 4H14V2h-4v2H8.33C7.6 4 7 4.6 7 5.33v15.33C7 21.4 7.6 22 8.33 22h7.33c.74 0 1.34-.6 1.34-1.33V5.33C17 4.6 16.4 4 15.67 4zM11 19v-2H9l3-5 3 5h-2v2h-2z"/></svg>',
    modeClass: 'mode-battery',
    detail: '日常省电基线：放缓升频并让 top-app 避开大核 X4，降低轻中负载功耗。'
  },
  default: {
    name: '系统默认',
    summary: '恢复 Google 内核原厂调度，不再应用模块性能策略。',
    desc: '使用系统原厂核心分配与升频节奏。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M13 3C8.03 3 4 7.03 4 12H1l4 4 4-4H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.95-2.05l-1.41 1.41A8.96 8.96 0 0013 21c4.97 0 9-4.03 9-9s-4.03-9-9-9zm-1 5v5l4.25 2.52.77-1.28-3.52-2.09V8H12z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M13 3C8.03 3 4 7.03 4 12H1l4 4 4-4H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.95-2.05l-1.41 1.41A8.96 8.96 0 0013 21c4.97 0 9-4.03 9-9s-4.03-9-9-9zm-1 5v5l4.25 2.52.77-1.28-3.52-2.09V8H12z"/></svg>',
    modeClass: 'mode-stock',
    detail: '恢复内核当前提供的 response_time_ms_nom、出厂 cpuset 与完整 boost 上限；具体数值由运行态 contract 提供。'
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
    name: '提前介入',
    summary: '出厂 -2°C；HINT 35°C，VIRTUAL-SKIN 37°C。',
    detail: '<b>提前介入</b><br><br>比出厂提前 2°C，最早 35°C 介入。<br><br>HINT 35°C / VIRTUAL-SKIN 37°C / CPU-HIGH 39°C；数值型 SHUTDOWN 仍保持出厂 55/59°C。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M9.37 5.51A7 7 0 0018.49 14.63 9 9 0 119.37 5.51z"/></svg>'
  },
  0: {
    name: '原厂阈值',
    summary: '出厂 0°C；HINT 37°C，VIRTUAL-SKIN 39°C。',
    detail: '<b>原厂阈值</b><br><br>不平移前置阈值，最早 37°C 介入。<br><br>HINT 37°C / VIRTUAL-SKIN 39°C / CPU-HIGH 41°C；数值型 SHUTDOWN 保持出厂 55/59°C。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M13 3C8.03 3 4 7.03 4 12H1l4 4 4-4H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.95-2.05l-1.41 1.41A8.96 8.96 0 0013 21c4.97 0 9-4.03 9-9s-4.03-9-9-9z"/></svg>'
  },
  2: {
    name: '轻度放宽',
    summary: '出厂 +2°C；HINT 39°C，VIRTUAL-SKIN 41°C。',
    detail: '<b>轻度放宽</b><br><br>出厂 +2°C；39°C 是最早 HINT 介入点，不是机身硬限温。<br><br>HINT 39°C / VIRTUAL-SKIN 41°C / CPU-HIGH 43°C。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M15 13.18V7c0-1.66-1.34-3-3-3S9 5.34 9 7v6.18C7.79 13.86 7 15.18 7 16.71 7 18.97 8.86 20.81 11.12 21H12c2.21 0 4-1.79 4-4 0-1.53-.79-2.85-2-3.82z"/></svg>'
  },
  4: {
    name: '日常放宽',
    summary: '出厂 +4°C；HINT 41°C，VIRTUAL-SKIN 43°C。',
    detail: '<b>日常放宽（模块默认）</b><br><br>前置阈值目标 +4°C，最早 41°C 介入。<br><br>HINT 41°C / VIRTUAL-SKIN 43°C / CPU-HIGH 45°C；靠近 55/59°C SHUTDOWN 时会向前限幅，保持至少 0.5°C 间隔。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M13.5.67s.74 2.65.74 4.8c0 2.06-1.35 3.73-3.41 3.73-2.07 0-3.63-1.67-3.63-3.73l.03-.36C5.21 7.51 4 10.62 4 14c0 4.42 3.58 8 8 8s8-3.58 8-8C20 8.61 17.41 3.8 13.5.67z"/></svg>'
  },
  6: {
    name: '最大放宽',
    summary: '出厂 +6°C；HINT 43°C，VIRTUAL-SKIN 45°C。',
    detail: '<b>最大放宽</b><br><br>前置阈值目标 +6°C，最早 43°C 介入。<br><br>HINT 43°C / VIRTUAL-SKIN 45°C / CPU-HIGH 47°C；靠近 55/59°C SHUTDOWN 时会向前限幅，不会整体推高最后安全阈值。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z"/></svg>'
  }
};
const THERMAL_OFFSETS = Object.freeze([-2, 0, 2, 4, 6]);
const THERMAL_DEFAULT_OFFSET = 4;

const SWAP_KEYS = ['swappiness', 'min_free_kbytes', 'watermark_scale_factor', 'vfs_cache_pressure'];


const UECAP_MODES = [
  { id: 'balanced', name: '国内频段', desc: '原厂 +25 组中国 NR 组合 · 推荐' },
  { id: 'special', name: '全面增强', desc: '原厂 +52 组全球 NR 组合' },
  { id: 'universal', name: 'Google 默认', desc: '原厂能力表 · 不做任何修改' },
];

const UECAP_DETAIL = '<b>UE 网络能力配置</b><br><br>UECap 告诉基站”手机支持哪些载波组合”，基站据此分配频段。<b>不直接影响功耗</b>——功耗取决于信号强度和 modem 活跃时间。<br><br><b>国内频段</b>（推荐）<br>原厂 +25 组中国 NR 组合（n28 / n41 / n79），只增不删。<br><br><b>全面增强</b><br>原厂 +52 组全球 NR 组合，含国际 n78 / EN-DC。国内多出的组合基本用不到。<br><br><b>Google 默认</b><br>原厂能力表，不做任何修改。<br><br>切换只重启蜂窝 modem，不影响 Wi-Fi / 蓝牙。';
const BASEBAND_DETAIL = '<b>基带配置模块 (pixel9pro_baseband_trial)</b><br><br><b>提供内容</b><br>- 5G / IMS 属性：VoLTE、Wi-Fi Calling 开关<br>- CarrierSettings：运营商配置覆盖<br>- China MCFG：移动 / 联通 / 电信相关 modem 配置<br><br><b>不包含</b><br>- UECap binarypb 管理（由 pixel9pro_control 负责）<br>- 温控、CPU 调度、ZRAM 和 WebUI';
const UECAP_VERIFY_INTERVAL_MS = 1500;
const UECAP_VERIFY_TIMEOUT_MS = 15000;
const PROFILE_MUTATION_TIMEOUT_MS = 15000;
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

const featureRegistry = new Map();

function registerFeature(name, api) {
  if (!name || !api || featureRegistry.has(name)) {
    throw new Error(`WebUI 功能注册失败：${name || 'unknown'}`);
  }
  featureRegistry.set(name, Object.freeze({ ...api }));
}

function requireFeature(name) {
  const feature = featureRegistry.get(name);
  if (!feature) throw new Error(`WebUI 功能未加载：${name}`);
  return feature;
}

function listFeatures() {
  return [...featureRegistry.keys()];
}

Object.defineProperty(window, 'Pixel9ProControl', {
  configurable: false,
  enumerable: false,
  writable: false,
  value: Object.freeze({
    features: Object.freeze({ get: requireFeature, names: listFeatures })
  })
});

