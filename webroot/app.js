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
  thermalSet: '/cgi-bin/set_thermal.sh',
  reboot: '/cgi-bin/reboot.sh',
  swap: '/cgi-bin/swap.sh',
  nrSwitch: '/cgi-bin/nr_switch.sh',
  uecap: '/cgi-bin/uecap.sh',
  thermalBurst: '/cgi-bin/thermal_burst.sh',
  ntp: '/cgi-bin/ntp.sh',
  energy: '/cgi-bin/energy.sh',
  checkBaseband: '/cgi-bin/check_baseband.sh',
  standbyGuard: '/cgi-bin/standby_guard.sh',
};

const STORAGE_THEME_KEY = 'pixel9pro_theme_mode';
const TAB_ORDER = ['home', 'perf', 'thermal', 'optim'];
const TAB_META = {
  home: '状态总览',
  perf: '性能调度',
  thermal: '温控阈值',
  optim: '连接与优化',
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
  responsive: {
    name: '响应优先',
    summary: '最明显的手动高响应档，保留全核并让中核/大核更早介入。',
    desc: '前台: cpu0-7 · 小核 12ms · 中核 24ms · 大核 80ms',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M7 2v11h3v9l7-12h-4l4-8z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M7 2v11h3v9l7-12h-4l4-8z"/></svg>',
    modeClass: 'mode-game',
    detail: '<b>响应优先</b><br><br><b>cpuset</b>: top-app → cpu0-7，background → cpu0-3<br><b>response_time</b>: 小核 12ms / 中核 24ms / 大核 80ms<br><br>这是现在最明显的手动高响应档。它不是“极限性能模式”，而是保留全核调度并让中核、大核更早补位，用更直接的交互提速感和自动/默认模式拉开差异。'
  },
  balanced: {
    name: '均衡手动',
    summary: '保留全核可调度，但明显放慢 X4，适合作为稳定的手动主力档。',
    desc: '前台: cpu0-7 · 小核 16ms · 中核 40ms · 大核 160ms',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z"/></svg>',
    modeClass: 'mode-balanced',
    detail: '<b>均衡手动</b><br><br><b>cpuset</b>: top-app → cpu0-7，background → cpu0-3<br><b>response_time</b>: 小核 16ms / 中核 40ms / 大核 160ms<br><br>这是推荐的手动主力档：保留全核弹性，但显著放慢 X4 常态介入，让系统更稳、更均衡。适合不想交给自动控制、又不追求最高响应的人。'
  },
  light: {
    name: '长亮屏',
    summary: '前台限制在 0-6，直接避免 X4 常态介入，适合社交和短视频长亮屏。',
    desc: '前台: cpu0-6 · 小核 24ms · 中核 64ms · 大核 200ms',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M6.76 4.84l-1.8-1.79-1.41 1.41 1.79 1.8 1.42-1.42zM1 13h3v-2H1v2zm10-9h2V1h-2v3zm7.45 1.46l1.79-1.8-1.41-1.41-1.8 1.79 1.42 1.42zM17.24 19.16l1.8 1.79 1.41-1.41-1.79-1.8-1.42 1.42zM20 11v2h3v-2h-3zM11 20h2v3h-2v-3zm-7.45-2.54l-1.79 1.8 1.41 1.41 1.8-1.79-1.42-1.42zM12 6a6 6 0 100 12 6 6 0 000-12z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M6.76 4.84l-1.8-1.79-1.41 1.41 1.79 1.8 1.42-1.42zM1 13h3v-2H1v2zm10-9h2V1h-2v3zm7.45 1.46l1.79-1.8-1.41-1.41-1.8 1.79 1.42 1.42zM17.24 19.16l1.8 1.79 1.41-1.41-1.79-1.8-1.42 1.42zM20 11v2h3v-2h-3zM11 20h2v3h-2v-3zm-7.45-2.54l-1.79 1.8 1.41 1.41 1.8-1.79-1.42-1.42zM12 6a6 6 0 100 12 6 6 0 000-12z"/></svg>',
    modeClass: 'mode-light',
    detail: '<b>长亮屏</b><br><br><b>cpuset</b>: top-app → cpu0-6，background → cpu0-3<br><b>response_time</b>: 小核 24ms / 中核 64ms / 大核 200ms<br><br>这是面向阅读、社交、短视频 steady-state 负载的低温方案：不再把小核锁死在 820MHz，也不再让前台默认挤到中大核，而是让小核低频浮动承接持续杂务，中核按需补位，X4 基本不参与。'
  },
  battery: {
    name: '省电模式',
    summary: '在长亮屏基础上继续放慢小中核升频，优先把前台温度压下来。',
    desc: '前台: cpu0-6 · 小核 32ms · 中核 96ms · 大核 200ms',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M15.67 4H14V2h-4v2H8.33C7.6 4 7 4.6 7 5.33v15.33C7 21.4 7.6 22 8.33 22h7.33c.74 0 1.34-.6 1.34-1.33V5.33C17 4.6 16.4 4 15.67 4zM11 19v-2H9l3-5 3 5h-2v2h-2z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M15.67 4H14V2h-4v2H8.33C7.6 4 7 4.6 7 5.33v15.33C7 21.4 7.6 22 8.33 22h7.33c.74 0 1.34-.6 1.34-1.33V5.33C17 4.6 16.4 4 15.67 4zM11 19v-2H9l3-5 3 5h-2v2h-2z"/></svg>',
    modeClass: 'mode-battery',
    detail: '<b>省电模式</b><br><br><b>cpuset</b>: top-app → cpu0-6，background → cpu0-3<br><b>response_time</b>: 小核 32ms / 中核 96ms / 大核 200ms<br><br>相比长亮屏模式进一步放慢小核和中核的升频，继续把 X4 排除在前台之外。适合明确以低发热和续航优先的长时间前台场景。'
  },
  default: {
    name: '默认模式',
    summary: '恢复系统默认 cpuset 与 sched_pixel 响应参数，也是自动模式的默认底座。',
    desc: '前台: cpu0-7 · 小核 16ms · 中核 64ms · 大核 200ms',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M13 3C8.03 3 4 7.03 4 12H1l4 4 4-4H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.95-2.05l-1.41 1.41A8.96 8.96 0 0013 21c4.97 0 9-4.03 9-9s-4.03-9-9-9zm-1 5v5l4.25 2.52.77-1.28-3.52-2.09V8H12z"/></svg>',
    hero: '<svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M13 3C8.03 3 4 7.03 4 12H1l4 4 4-4H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.95-2.05l-1.41 1.41A8.96 8.96 0 0013 21c4.97 0 9-4.03 9-9s-4.03-9-9-9zm-1 5v5l4.25 2.52.77-1.28-3.52-2.09V8H12z"/></svg>',
    modeClass: 'mode-stock',
    detail: '<b>默认模式</b><br><br><b>cpuset</b>: top-app → cpu0-7，foreground → cpu0-6<br><b>response_time</b>: 小核 16ms / 中核 64ms / 大核 200ms<br><br>这是 Pixel 系统默认 sched_pixel 参数，也是自动模式启动时的底座。它不是主动性能优化档，而是“最标准、最容易判断自动收口效果”的对照组。'
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
    name: '出厂阈值',
    summary: '恢复出厂 39°C 介入点。',
    detail: '<b>出厂阈值</b><br><br><b>VIRTUAL-SKIN 39°C</b> 开始介入。保持 Google 出厂温控口径，保守但更容易在日常高温边缘频繁触发降温。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M13 3C8.03 3 4 7.03 4 12H1l4 4 4-4H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.95-2.05l-1.41 1.41A8.96 8.96 0 0013 21c4.97 0 9-4.03 9-9s-4.03-9-9-9z"/></svg>'
  },
  2: {
    name: '轻度放宽',
    summary: 'VIRTUAL-SKIN 41°C 开始介入。',
    detail: '<b>轻度放宽</b><br><br>在出厂基础上整体上移 <b>+2°C</b>。适合减少日常温度波动带来的频繁触发，同时保留较明显的安全余量。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M15 13.18V7c0-1.66-1.34-3-3-3S9 5.34 9 7v6.18C7.79 13.86 7 15.18 7 16.71 7 18.97 8.86 20.81 11.12 21H12c2.21 0 4-1.79 4-4 0-1.53-.79-2.85-2-3.82z"/></svg>'
  },
  4: {
    name: '日常推荐',
    summary: '模块默认档，VIRTUAL-SKIN 43°C 开始介入。',
    detail: '<b>日常推荐（模块默认）</b><br><br>在出厂基础上整体上移 <b>+4°C</b>，VIRTUAL-SKIN 43°C 才开始介入。兼顾性能表现、机身温度和日常稳定性，是模块默认档位。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M13.5.67s.74 2.65.74 4.8c0 2.06-1.35 3.73-3.41 3.73-2.07 0-3.63-1.67-3.63-3.73l.03-.36C5.21 7.51 4 10.62 4 14c0 4.42 3.58 8 8 8s8-3.58 8-8C20 8.61 17.41 3.8 13.5.67z"/></svg>'
  },
  6: {
    name: '性能优先',
    summary: 'VIRTUAL-SKIN 45°C 开始介入。',
    detail: '<b>性能优先</b><br><br>在出厂基础上整体上移 <b>+6°C</b>，显著延后系统降温介入。适合短时高负载冲刺，但机身体感温度会更快上升。',
    icon: '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z"/></svg>'
  }
};

const SWAP_DETAIL = '<b>ZRAM 算法: lz77eh (Emerald Hill 硬件加速)</b><br>Tensor G4 内置固定功能压缩引擎，压缩和解压由专用硬件完成，CPU 几乎不参与，适合高频换页场景。<br><br><b>ZRAM 大小: 11392MB (75% RAM)</b><br>原厂默认约为 50% RAM。模块将容量扩容到 11392MB，让更多后台匿名页驻留在 ZRAM 中。<br><br><b>swappiness: 100</b><br>降低匿名页被过度换出的激进程度，减少无效 swap-in / swap-out。<br><br><b>min_free_kbytes: 65536</b><br>提前唤醒 kswapd，减少 direct reclaim 带来的主线程阻塞。<br><br><b>vfs_cache_pressure: 60</b><br>保留更多 inode / dentry 缓存，有利于文件路径查询与应用启动。';

const NR_SWITCH_DETAIL = '<b>NR 息屏降级 (Screen-Off LTE Switch)</b><br><br>开启后，息屏超过 <b>60 秒</b> 时网络模式从 5G NR 切换到 LTE，降低调制解调器射频功耗。亮屏时立即恢复 5G/NR 模式，<b>5GA / 5G CA 能力完全保留</b>。<br><br><b>防抖机制</b><br>- 息屏后等待 60 秒再切换，快速亮屏不会触发<br>- 恢复 NR 后冷却 10 分钟，避免频繁亮灭导致来回切换<br><br><b>原理</b><br>NR_SA Band 41 (100MHz) 射频功耗远高于 LTE 20MHz。息屏时降级为 LTE 可使调制解调器进入更深低功耗态，预期节省 30-50% 蜂窝待机功耗。<br><br><b>注意</b><br>- 切换期间可能有 1-2 秒网络短暂中断<br>- 开启热点时自动跳过降级，保障共享连接<br>- 息屏下载或后台大流量时可关闭此功能<br>- 功能状态即时生效，无需重启';

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
  autoReason: '',
  currentOffset: 4,
  swapMode: 'unknown',
  themeMode: 'system',
  webuiToken: '',
  cpuBusy: false,
  profilePolicyBusy: false,
  thermalBusy: false,
  swapBusy: false,
  swapLoading: false,
  nrSwitch: 'off',
  nrBusy: false,
  sim2AutoManage: 'off',
  idleIsolateMode: 'off',
  standbyGuardBusy: false,
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
  thermalModal: { pending: 4, prev: 4 }
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
  refs.infoModel = $('info-model');
  refs.infoAndroid = $('info-android');
  refs.infoModule = $('info-module');
  refs.logCard = $('log-card');
  refs.logInner = $('log-inner');
  refs.perfCurrentName = $('perf-current-name');
  refs.perfCurrentDesc = $('perf-current-desc');
  refs.perfPolicyDesc = $('perf-policy-desc');
  refs.profilePolicyManualBtn = $('profile-policy-manual-btn');
  refs.profilePolicyAutoBtn = $('profile-policy-auto-btn');
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
  refs.pullArc = refs.pullInd.querySelector('.pull-arc');
  refs.tabPages = $('tab-pages');
  refs.topbar = document.querySelector('.topbar');
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
  refs.detailTitle.textContent = title;
  refs.detailBody.innerHTML = html;
  refs.detailModal.classList.add('open');
  pushModalState('detail');
  queueNextPoll(computeNextPollDelay());
}

function closeDetailModal(){
  refs.detailModal.classList.remove('open');
  popModalIfTop('detail');
  queueNextPoll(POLL_MIN_DELAY_MS);
}

function errorBlock(msg) {
  const el = document.createElement('div');
  el.className = 'note-body';
  el.style.cssText = 'color:var(--danger)';
  el.textContent = msg;
  return el;
}

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

function sleep(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function noteUserActivity() {
  state.poller.lastInteractionAt = Date.now();
  if (!document.hidden && state.poller.running) queueNextPoll(POLL_MIN_DELAY_MS);
}

function isAnyModalOpen() {
  return Boolean(
    (refs.detailModal && refs.detailModal.classList.contains('open'))
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
      if (state.currentTab === 'perf') return relaxed ? POLL_INTERVALS.cpu.relaxedPerf : POLL_INTERVALS.cpu.perf;
      if (state.currentTab === 'home') return relaxed ? POLL_INTERVALS.cpu.relaxedHome : POLL_INTERVALS.cpu.home;
      return 0;
    case 'thermal':
      if (state.currentTab === 'thermal') return relaxed ? POLL_INTERVALS.thermal.relaxedThermal : POLL_INTERVALS.thermal.thermal;
      if (state.currentTab === 'home') return relaxed ? POLL_INTERVALS.thermal.relaxedHome : POLL_INTERVALS.thermal.home;
      return 0;
    case 'optim':
      if (state.currentTab === 'optim') return relaxed ? POLL_INTERVALS.optim.relaxedOptim : POLL_INTERVALS.optim.optim;
      if (state.currentTab === 'home') return relaxed ? POLL_INTERVALS.optim.relaxedHome : POLL_INTERVALS.optim.home;
      return 0;
    case 'slow':
      if (state.currentTab === 'optim') return relaxed ? POLL_INTERVALS.slow.relaxedOptim : POLL_INTERVALS.slow.optim;
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
  if (!state.poller.running || document.hidden) return;
  state.poller.timer = window.setTimeout(runPollCycle, Math.max(delayMs, POLL_MIN_DELAY_MS));
}

async function runPollCycle() {
  if (!state.poller.running || document.hidden) return;
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
  if (shouldPollOptim() && (now - state.poller.lastRun.slow) >= getPollInterval('slow')) {
    jobs.push({
      key: 'slow',
      run: () => Promise.allSettled([refreshNrSwitch(), refreshUecap(), refreshBaseband(), refreshNtp(), refreshStandbyGuard(), loadInfo()])
    });
  }

  if (jobs.length) {
    markPollFresh(jobs.map((job) => job.key), now);
    await Promise.allSettled(jobs.map((job) => job.run()));
  }

  queueNextPoll(computeNextPollDelay());
}

function syncTopbar() {
  const page = document.querySelector('.tab-page.active');
  refs.topbar.classList.toggle('compact', page && page.scrollTop > 40);
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
  if (t < 43) return '已高于原厂阈值，当前仍在放宽区间';
  if (t < 47) return '系统已开始主动降温';
  if (t < 50) return '温度持续偏高，系统正在加强降温';
  return '温度过高，系统已严格限制性能';
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
  const isAuto = state.profilePolicy === 'auto';
  refs.topbarProfileChip.textContent = isAuto ? `${profile.name} · 自动` : profile.name;
  refs.perfCurrentName.textContent = isAuto ? `${profile.name} · 自动` : profile.name;
  refs.perfCurrentDesc.textContent = isAuto ? `${profile.desc} · ${describeAutoReason(state.autoReason)}` : profile.desc;
  refs.perfPolicyDesc.textContent = isAuto
    ? `自动模式已启用：当前按“${describeAutoReason(state.autoReason)}”运行，手动点卡片会退出自动。`
    : `手动模式：当前固定为“${profile.name}”。切到自动后，长亮屏 steady-state 前台会按 balanced → light → battery 慢切换。`;
  refs.profilePolicyManualBtn.className = `tiny-btn${!isAuto ? ' primary' : ''}`;
  refs.profilePolicyAutoBtn.className = `tiny-btn${isAuto ? ' primary' : ''}`;
  refs.profilePolicyManualBtn.disabled = state.profilePolicyBusy;
  refs.profilePolicyAutoBtn.disabled = state.profilePolicyBusy;
  refs.hero.className = `hero-card ${profile.modeClass}`;
  refs.heroIcon.innerHTML = profile.hero;
  refs.heroMode.textContent = isAuto ? `${profile.name} · 自动` : profile.name;
  document.querySelectorAll('.profile-option').forEach((card) => card.classList.toggle('selected', card.dataset.profile === state.currentProfile));
}

function describeAutoReason(reason) {
  switch (reason) {
    case 'steady_screen_warmup': return '长亮屏预热阶段，保持平衡';
    case 'steady_screen_hold': return '长亮屏 steady-state，已切轻度';
    case 'steady_hot_guard': return '持续热平台，已压到省电';
    case 'hot_cooldown': return '热平台已回落，恢复轻度';
    case 'nonsteady_reset': return '已退出长亮屏场景，恢复平衡';
    case 'screen_off_reset': return '已息屏，恢复平衡';
    case 'auto_enabled': return '已启用自动调度';
    case 'manual_policy': return '切回手动';
    case 'manual_selected': return '手动指定模式';
    default: return '自动调度运行中';
  }
}

function applyProfileState(data) {
  state.currentProfile = PROFILES[data.profile] ? data.profile : 'unknown';
  state.manualProfile = PROFILES[data.manual_profile] ? data.manual_profile : state.currentProfile;
  state.profilePolicy = data.policy === 'auto' ? 'auto' : 'manual';
  state.autoReason = typeof data.auto_reason === 'string' ? data.auto_reason : '';
  syncProfileUi();
  syncHeroDesc();
}

function syncHeroDesc() {
  const parts = [];
  const preset = THERMAL_PRESETS[state.currentOffset];
  if (preset) parts.push(preset.name);
  if (state.swapMode === 'optimized') parts.push('内存已优化');
  else if (state.swapMode === 'stock') parts.push('内存默认');
  refs.heroDesc.textContent = parts.join(' · ') || '正在读取配置…';
}

function syncThermalUi() {
  const preset = THERMAL_PRESETS[state.currentOffset] || THERMAL_PRESETS[4];
  refs.topbarThermalChip.textContent = state.currentOffset === 0 ? '出厂阈值' : `温控 ${preset.name}`;
  refs.thermalCurrentName.textContent = preset.name;
  refs.thermalCurrentDesc.textContent = preset.summary;
  const label = state.currentOffset === 0 ? '出厂阈值' : `+${state.currentOffset}°C 已启用`;
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
  ['responsive', 'balanced', 'light', 'battery', 'default'].forEach((key) => {
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
    const deviceModel = data.model || '—';
    refs.infoModel.textContent = deviceModel;
    refs.infoAndroid.textContent = data.version ? `Android ${data.version}` : '—';
    refs.infoModule.textContent = data.module_version || '—';
    refs.topbarKicker.textContent = data.module_version
      ? `${deviceModel} · UI ${data.module_version}`
      : `${deviceModel} · UI`;
    const basebandCard = $('baseband-card');
    if (basebandCard) basebandCard.hidden = deviceModel !== 'Pixel 9 Pro';
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
    applyProfileState(data);
  } catch (_) {
    state.currentProfile = 'unknown';
    state.manualProfile = 'balanced';
    state.profilePolicy = 'manual';
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
    refs.cpuRows.innerHTML = '';
    refs.cpuRows.appendChild(el);
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
    refs.swapRows.innerHTML = ''; refs.swapRows.appendChild(errorBlock('获取失败：' + err.message));
  } finally {
    state.swapLoading = false;
  }
}


function renderNrSwitchRows(data) {
  refs.nrSwitchRows.innerHTML = '';
  const isOn = data.nr_switch === 'on';
  const modeNum = Number(data.current_mode);
  const isLte = !Number.isNaN(modeNum) && modeNum < 23;
  const modeLabel = Number.isNaN(modeNum) ? data.current_mode : (isLte ? `LTE (${data.current_mode})` : `NR (${data.current_mode})`);
  const rows = [
    { label: '功能状态', value: isOn ? '已开启' : '已关闭', cls: isOn ? 'good' : 'off' },
    { label: '当前网络模式', value: modeLabel, cls: isLte ? 'warn' : 'good' },
    { label: '恢复用 NR 模式值', value: data.saved_nr_mode, cls: 'off' }
  ];
  rows.forEach((row) => refs.nrSwitchRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));
  refs.nrSwitchToggleLabel.textContent = isOn ? '关闭' : '开启';
  refs.nrSwitchDesc.textContent = isOn
    ? '已开启：灭屏 5 分钟后切到 LTE，亮屏自动恢复 NR（最多滞后 5 分钟）'
    : '灭屏超过 5 分钟后切到 LTE，亮屏自动恢复；热点开启时不降级。';
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
    ? '已开启：仅在副卡槽确实为空、且你接受自动 radio / IMS 写入时才建议保留。'
    : '默认关闭：完全不触发 SIM2 radio / IMS 自动写入，待机排障更稳。';
  refs.sim2AutoRows.innerHTML = '';
  [
    { label: '功能状态', value: sim2On ? '已开启' : '已关闭', cls: sim2On ? 'good' : 'off' },
    { label: '当前策略', value: sim2On ? '仅在空槽时操作 slot 1 radio / ims' : '完全跳过 SIM2 radio / ims 写入', cls: sim2On ? 'warn' : 'good' },
    { label: '推荐用途', value: sim2On ? '确有副卡槽空置节电需求' : '默认保守基线 / 过夜排障优先', cls: 'off' },
  ].forEach((row) => refs.sim2AutoRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));

  const isolateOn = state.idleIsolateMode === 'on';
  refs.idleIsolateToggleLabel.textContent = isolateOn ? '关闭' : '开启';
  refs.idleIsolateDesc.textContent = isolateOn
    ? '已开启：息屏阶段暂停 NR 降级、SIM2 管理、功耗采样、thermal burst 和自动调度，只保留最小 worker 路径。'
    : '默认关闭：沿用常规待机 worker。过夜诊断怀疑 control 模块挡 suspend 时，再临时开启。';
  refs.idleIsolateRows.innerHTML = '';
  [
    { label: '功能状态', value: isolateOn ? '已开启' : '已关闭', cls: isolateOn ? 'warn' : 'off' },
    { label: '息屏阶段', value: isolateOn ? '暂停 NR / SIM2 / thermal burst / power / auto profile 待机干预' : '常规待机路径生效', cls: isolateOn ? 'warn' : 'good' },
    { label: '使用建议', value: isolateOn ? '仅用于一晚隔离测试，验证后记得关闭' : '日常使用保持关闭', cls: 'off' },
  ].forEach((row) => refs.idleIsolateRows.appendChild(buildInfoRow(row.label, row.value, row.cls)));

  refs.standbyDiagRows.innerHTML = '';
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
  refs.uecapBtnGroup.innerHTML = '';
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
  refs.uecapRows.innerHTML = '';
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
    refs.nrSwitchRows.innerHTML = ''; refs.nrSwitchRows.appendChild(errorBlock('获取失败：' + err.message));
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
    refs.uecapRows.innerHTML = ''; refs.uecapRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

async function refreshStandbyGuard() {
  try {
    const data = await apiFetch(API.standbyGuard, { timeoutMs: 6000 });
    renderStandbyGuard(data);
  } catch (err) {
    refs.sim2AutoRows.innerHTML = ''; refs.sim2AutoRows.appendChild(errorBlock('获取失败：' + err.message));
    refs.idleIsolateRows.innerHTML = ''; refs.idleIsolateRows.appendChild(errorBlock('获取失败：' + err.message));
    refs.standbyDiagRows.innerHTML = ''; refs.standbyDiagRows.appendChild(errorBlock('获取失败：' + err.message));
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
    const data = await apiFetch(API.nrSwitch, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}', timeoutMs: 8000 });
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
  refs.basebandRows.innerHTML = '';
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
    refs.basebandRows.innerHTML = ''; refs.basebandRows.appendChild(errorBlock('获取失败：' + err.message));
  }
}

function renderNtpCard(data) {
  refs.ntpServerList.innerHTML = '';
  const current = data.ntp_server || 'time.android.com';
  state.ntpServer = current;
  NTP_SERVERS.forEach((srv) => {
    const card = document.createElement('div');
    card.className = `opt-item${srv.id === current ? ' ntp-selected' : ''}`;
    card.style.cursor = 'pointer';
    card.innerHTML = `
      <div class="opt-item-head">
        <div class="opt-label">${srv.name}</div>
        <span class="badge ${srv.id === current ? 'good' : 'off'}">${srv.id === current ? '当前' : '切换'}</span>
      </div>
      <div class="opt-meta">${srv.id} · ${srv.desc}</div>`;
    card.addEventListener('click', () => setNtpServer(srv.id));
    refs.ntpServerList.appendChild(card);
  });
  refs.ntpInfoRows.innerHTML = '';
  refs.ntpInfoRows.appendChild(buildInfoRow('设备时间', data.device_time || '—', ''));
  refs.ntpInfoRows.appendChild(buildInfoRow('自动同步', data.auto_time === '1' ? '已开启' : '已关闭', data.auto_time === '1' ? 'good' : 'warn'));
  const ntpLabel = NTP_SERVERS.find((s) => s.id === current)?.name || current;
  refs.ntpDesc.textContent = `当前: ${ntpLabel} (${current})`;
}

async function refreshNtp() {
  try {
    const data = await apiFetch(API.ntp, { timeoutMs: 6000 });
    renderNtpCard(data);
  } catch (err) {
    refs.ntpServerList.innerHTML = ''; refs.ntpServerList.appendChild(errorBlock('获取失败：' + err.message));
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

function drawTempCanvas(container, data) {
  if (!data || data.length < 2) {
    container.innerHTML = '<div style="text-align:center;color:var(--text-3);padding:24px 0;font-size:13px">数据采集中，后台每 5 秒记录一次</div>';
    return null;
  }
  container.innerHTML = '';
  const canvas = document.createElement('canvas');
  canvas.style.cssText = 'display:block;width:100%;height:200px';
  container.appendChild(canvas);
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.offsetWidth || 380;
  const h = 200;
  canvas.width = w * dpr;
  canvas.height = h * dpr;
  const ctx = canvas.getContext('2d');
  ctx.scale(dpr, dpr);
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
  const gridColor = isDark ? 'rgba(234,243,238,0.10)' : 'rgba(20,34,28,0.10)';
  const labelColor = isDark ? 'rgba(238,245,241,0.54)' : 'rgba(20,32,28,0.50)';
  const strokeColor = isDark ? '#83e8ce' : '#006b57';
  const areaColor = isDark ? 'rgba(131,232,206,0.08)' : 'rgba(0,107,87,0.06)';
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
  ctx.textAlign = 'center';
  ctx.textBaseline = 'top';
  const xN = 4;
  const t0 = data[0].ts;
  const t1 = data[data.length - 1].ts;
  const timeSpan = t1 - t0 || 1;
  for (let i = 0; i <= xN; i++) {
    const x = pad.left + (plotW / xN) * i;
    const ts = t0 + (timeSpan / xN) * i;
    const d = new Date(ts * 1000);
    ctx.fillText(`${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`, x, h - pad.bottom + 6);
  }
  let plotData = data;
  if (data.length > plotW) {
    const step = Math.ceil(data.length / plotW);
    plotData = data.filter((_, i) => i % step === 0 || i === data.length - 1);
  }
  ctx.beginPath();
  plotData.forEach((p, i) => {
    const x = pad.left + ((p.ts - t0) / timeSpan) * plotW;
    const y = pad.top + ((maxT - p.temp) / (maxT - minT)) * plotH;
    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  });
  ctx.strokeStyle = strokeColor;
  ctx.lineWidth = 2;
  ctx.lineJoin = 'round';
  ctx.stroke();
  ctx.lineTo(pad.left + ((plotData[plotData.length - 1].ts - t0) / timeSpan) * plotW, pad.top + plotH);
  ctx.lineTo(pad.left + ((plotData[0].ts - t0) / timeSpan) * plotW, pad.top + plotH);
  ctx.closePath();
  ctx.fillStyle = areaColor;
  ctx.fill();
  return { min: realMin, max: realMax, avg, count: data.length };
}

function fmtDuration(sec) {
  const value = Number(sec);
  if (!Number.isFinite(value) || value < 0) return '—';
  if (value >= 3600) return `${Math.floor(value / 3600)}小时${Math.floor((value % 3600) / 60)}分`;
  if (value >= 60) return `${Math.floor(value / 60)}分${Math.floor(value % 60)}秒`;
  return `${Math.floor(value)}秒`;
}

function fmtDateTime(ts) {
  const value = Number(ts);
  if (!Number.isFinite(value) || value <= 0) return '—';
  return new Intl.DateTimeFormat('zh-CN', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(new Date(value * 1000)).replace(/\//g, '-');
}

function fmtMah(value) {
  const num = Number(value);
  return Number.isFinite(num) ? `${num.toFixed(1)} mAh` : '—';
}

function fmtSignedPercent(value) {
  const num = Number(value);
  if (!Number.isFinite(num)) return '—';
  return `${num > 0 ? '+' : ''}${num}%`;
}

function fmtBatteryStatus(status) {
  switch (status) {
    case 'Charging': return '充电中';
    case 'Discharging': return '放电中';
    case 'Full': return '已充满';
    case 'Not charging': return '未充电';
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
  let lastErr;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      return await apiFetch(API.energy, { timeoutMs: 16000 });
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
  throw lastErr;
}

function renderHistoryStats(statsEl, data, result) {
  if (!result || !data.length) { statsEl.innerHTML = ''; return; }
  const threshold = THRESH_STOCK + state.currentOffset;
  let highSec = 0;
  for (let i = 1; i < data.length; i++) {
    if (data[i - 1].temp >= threshold) highSec += data[i].ts - data[i - 1].ts;
  }
  const elapsed = data[data.length - 1].ts - data[0].ts;
  statsEl.innerHTML = '';
  const rows = [
    { label: '数据范围', value: fmtDuration(elapsed) },
    { label: '采样点', value: `${data.length} 个` },
    { label: '最高温度', value: `${result.max.toFixed(1)}°C`, cls: result.max >= threshold ? 'warn' : 'good' },
    { label: '最低温度', value: `${result.min.toFixed(1)}°C`, cls: 'good' },
    { label: '平均温度', value: `${result.avg.toFixed(1)}°C` },
    { label: `高于阈值时长 (≥${threshold}°C)`, value: fmtDuration(highSec), cls: highSec > 60 ? 'warn' : 'good' },
  ];
  rows.forEach((row) => statsEl.appendChild(buildInfoRow(row.label, row.value, row.cls || '')));
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

async function triggerThermalBurst() {
  try {
    await apiFetch(API.thermalBurst, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
      timeoutMs: 4000
    });
  } catch (_) {}
}

function openTempChart() {
  triggerThermalBurst();
  refs.detailTitle.textContent = '温度历史';
  const ranges = [
    { min: 10, label: '10分钟', chart: true },
    { min: 30, label: '30分钟', chart: true },
    { min: 150, label: '2.5h', chart: false },
    { min: 720, label: '12h', chart: false },
  ];
  let active = 10;
  refs.detailBody.innerHTML =
    '<div class="chart-range-chips" id="chart-ranges"></div>' +
    '<div id="chart-area"></div>';
  const chipsEl = document.getElementById('chart-ranges');
  const areaEl = document.getElementById('chart-area');
  const draw = async (rangeMin) => {
    active = rangeMin;
    const isChart = ranges.find((r) => r.min === rangeMin)?.chart;
    chipsEl.querySelectorAll('.chart-chip').forEach((b) => b.classList.toggle('active', Number(b.dataset.range) === rangeMin));
    areaEl.innerHTML = '<div style="text-align:center;color:var(--text-3);padding:24px 0;font-size:13px">加载中…</div>';
    const data = await fetchTempHistory(rangeMin);
    if (!data || data.length < 2) {
      areaEl.innerHTML = '<div style="text-align:center;color:var(--text-3);padding:24px 0;font-size:13px">数据不足，等待短时采样继续积累</div>';
      return;
    }
    const temps = data.map((p) => p.temp);
    const realMin = Math.min(...temps);
    const realMax = Math.max(...temps);
    const avg = temps.reduce((a, b) => a + b, 0) / temps.length;
    const threshold = THRESH_STOCK + state.currentOffset;
    let highSec = 0;
    for (let i = 1; i < data.length; i++) {
      if (data[i - 1].temp >= threshold) highSec += data[i].ts - data[i - 1].ts;
    }
    const elapsed = data[data.length - 1].ts - data[0].ts;
    areaEl.innerHTML = '';
    if (isChart) {
      const chartWrap = document.createElement('div');
      chartWrap.className = 'chart-wrap';
      areaEl.appendChild(chartWrap);
      drawTempCanvas(chartWrap, data);
      const summary = document.createElement('div');
      summary.className = 'chart-stats';
      summary.innerHTML = `<span>最低 ${realMin.toFixed(1)}°C</span><span>平均 ${avg.toFixed(1)}°C</span><span>最高 ${realMax.toFixed(1)}°C</span>`;
      areaEl.appendChild(summary);
    }
    const statsWrap = document.createElement('div');
    statsWrap.style.cssText = isChart ? 'margin-top:16px;padding-top:12px;border-top:1px solid var(--line)' : '';
    const heading = document.createElement('div');
    heading.style.cssText = 'font-size:12px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:var(--text-3);margin-bottom:10px';
    heading.textContent = isChart ? '统计' : '温度统计';
    statsWrap.appendChild(heading);
    const statsList = document.createElement('div');
    statsList.className = 'data-list';
    const rows = [
      { label: '最高温度', value: `${realMax.toFixed(1)}°C`, cls: realMax >= threshold ? 'warn' : 'good' },
      { label: '最低温度', value: `${realMin.toFixed(1)}°C`, cls: 'good' },
      { label: '平均温度', value: `${avg.toFixed(1)}°C`, cls: avg >= threshold ? 'warn' : '' },
      { label: `高于阈值时长 (≥${threshold}°C)`, value: fmtDuration(highSec), cls: highSec > 60 ? 'warn' : 'good' },
      { label: '数据范围', value: fmtDuration(elapsed) },
      { label: '采样点', value: `${data.length} 个` },
    ];
    rows.forEach((row) => statsList.appendChild(buildInfoRow(row.label, row.value, row.cls || '')));
    statsWrap.appendChild(statsList);
    areaEl.appendChild(statsWrap);
  };
  ranges.forEach((r) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = `chart-chip${r.min === active ? ' active' : ''}`;
    btn.dataset.range = String(r.min);
    btn.textContent = r.label;
    btn.addEventListener('click', () => draw(r.min));
    chipsEl.appendChild(btn);
  });
  refs.detailModal.classList.add('open');
  window.setTimeout(() => draw(active), 80);
}

async function openEnergyDetail() {
  refs.detailTitle.textContent = '功耗统计';
  refs.detailBody.innerHTML = '<div style="text-align:center;color:var(--text-3);padding:24px 0;font-size:13px">正在分析 batterystats，约需 2-3 秒…</div>';
  refs.detailModal.classList.add('open');
  try {
    const d = await fetchEnergyDetailWithRetry();
    const esc = (v) => v == null || v === '' ? '—' : String(v);
    const frag = document.createDocumentFragment();
    const heading = (txt, desc = '') => {
      const h = document.createElement('div');
      h.style.cssText = 'margin:16px 0 10px;padding-top:12px;border-top:1px solid var(--line)';
      const b = document.createElement('b');
      b.textContent = txt;
      h.appendChild(b);
      if (desc) {
        const p = document.createElement('div');
        p.style.cssText = 'margin-top:6px;font-size:12px;line-height:18px;color:var(--text-3)';
        p.textContent = desc;
        h.appendChild(p);
      }
      return h;
    };
    const row = (k, v, cls) => { const r = document.createElement('div'); r.className = 'data-row'; const sk = document.createElement('span'); sk.className = 'data-key'; sk.textContent = k; const sv = document.createElement('span'); sv.className = cls || 'data-val'; sv.textContent = v; r.appendChild(sk); r.appendChild(sv); return r; };
    const scope = d.scope || {};
    const today = d.today || {};
    const charge = d.charge_state || {};
    const bs = d.batterystats_window || {};

    const intro = document.createElement('div');
    intro.style.cssText = 'margin-bottom:14px;font-size:13px;line-height:20px;color:var(--text-2)';
    intro.textContent = '默认按“当前放电会话”看范围；系统分项和应用排行仍来自 Android batterystats 当前窗口。';
    frag.appendChild(intro);

    frag.appendChild(heading('统计范围', '当前会话由模块维护，避免把长期 batterystats 累计误当成这一次切换后的结果。'));
    const list0 = document.createElement('div'); list0.className = 'data-list';
    list0.appendChild(row('默认口径', '当前放电会话', 'badge good'));
    list0.appendChild(row('当前状态', fmtBatteryStatus(charge.status), /Charging|Full/.test(charge.status || '') ? 'badge warn' : 'badge off'));
    list0.appendChild(row('会话开始', fmtDateTime(scope.start_ts)));
    list0.appendChild(row('已持续', fmtDuration(scope.elapsed_sec)));
    list0.appendChild(row('电量变化', Number.isFinite(Number(scope.level_start)) && Number.isFinite(Number(scope.level_now))
      ? `${scope.level_start}% → ${scope.level_now}% (消耗 ${Number(scope.level_drop || 0)}%)`
      : '—'));
    list0.appendChild(row('观测放电', fmtMah(scope.used_mah)));
    list0.appendChild(row('最近重置原因', fmtSessionResetReason(scope.reset_reason)));
    list0.appendChild(row('重置规则', esc(scope.reset_rule)));
    frag.appendChild(list0);

    frag.appendChild(heading('今日累计', '基于模块低频采样汇总，适合看今天到目前为止的大致收支。'));
    const listToday = document.createElement('div'); listToday.className = 'data-list';
    listToday.appendChild(row('今日起点', fmtDateTime(today.start_ts)));
    listToday.appendChild(row('首个样本', fmtDateTime(today.window_start_ts)));
    listToday.appendChild(row('观察时长', fmtDuration(today.elapsed_sec)));
    listToday.appendChild(row('采样点', Number.isFinite(Number(today.samples)) ? `${today.samples} 个` : '0 个'));
    listToday.appendChild(row('今日放电', fmtMah(today.discharge_mah)));
    listToday.appendChild(row('今日回充', fmtMah(today.charge_mah)));
    listToday.appendChild(row('净电量变化', fmtSignedPercent(today.net_level_delta), Number(today.net_level_delta) < 0 ? 'badge warn' : 'badge good'));
    frag.appendChild(listToday);

    frag.appendChild(heading('Android batterystats', esc(bs.note)));
    const listBs = document.createElement('div'); listBs.className = 'data-list';
    listBs.appendChild(row('系统窗口', fmtBatterystatsWindow(bs.window_label)));
    listBs.appendChild(row('Daily stats', esc(bs.daily_label)));
    listBs.appendChild(row('在电池上时长', esc(bs.time_on_battery || d.bat_time)));
    listBs.appendChild(row('快照时间', fmtDateTime(d.generated_at)));
    listBs.appendChild(row('缓存有效期', Number.isFinite(Number(d.cache_ttl_sec)) ? `${d.cache_ttl_sec} 秒` : '—'));
    frag.appendChild(listBs);

    frag.appendChild(heading('Android 功耗估算', '下面这些系统分项和 Top 应用，都来自上面的 batterystats 窗口。'));
    const list1 = document.createElement('div'); list1.className = 'data-list';
    list1.appendChild(row('当前电量', Number.isFinite(Number(charge.level)) ? `${charge.level}%` : '—'));
    list1.appendChild(row('电池容量', esc(d.cap) + ' mAh'));
    list1.appendChild(row('预估耗电', esc(d.drain) + ' mAh'));
    list1.appendChild(row('亮屏耗电', esc(d.scron) + ' mAh'));
    list1.appendChild(row('息屏耗电', esc(d.scroff) + ' mAh'));
    list1.appendChild(row('系统统计时长', esc(d.bat_time)));
    frag.appendChild(list1);
    frag.appendChild(heading('系统分项 (mAh)'));
    const list2 = document.createElement('div'); list2.className = 'data-list';
    list2.appendChild(row('屏幕', esc(d.screen)));
    list2.appendChild(row('CPU', esc(d.cpu)));
    list2.appendChild(row('蜂窝', esc(d.cell)));
    list2.appendChild(row('WiFi', esc(d.wifi)));
    list2.appendChild(row('唤醒锁', esc(d.wakelock)));
    frag.appendChild(list2);
    if (d.apps && d.apps.length) {
      frag.appendChild(heading('高耗电应用 Top ' + d.apps.length));
      const list3 = document.createElement('div'); list3.className = 'data-list';
      d.apps.forEach((app, i) => {
        const name = String(app.pkg || '').length > 30 ? String(app.pkg).slice(0, 28) + '…' : String(app.pkg || '');
        list3.appendChild(row((i + 1) + '. ' + name, esc(app.mah) + ' mAh', 'badge ' + (app.mah > 200 ? 'warn' : 'off')));
      });
      frag.appendChild(list3);
    }
    refs.detailBody.innerHTML = '';
    refs.detailBody.appendChild(frag);
  } catch (err) {
    refs.detailBody.innerHTML = ''; refs.detailBody.appendChild(errorBlock(err.message));
  }
}

async function applyProfile(profile) {
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

async function applyThermal(offset) {
  if (offset === state.currentOffset || state.thermalBusy) return;
  const prev = state.currentOffset;
  const card = refs.thermalList.querySelector(`[data-offset="${offset}"]`);
  if (!card) return;
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
  await Promise.allSettled([refreshNrSwitch(), refreshUecap(), refreshBaseband(), refreshNtp(), refreshStandbyGuard(), loadInfo()]);
  markPollFresh(['cpu', 'thermal', 'optim', 'slow']);
  queueNextPoll(computeNextPollDelay());
  showToast('已刷新');
}

function shouldPollCpu() {
  return !document.hidden && (state.currentTab === 'home' || state.currentTab === 'perf');
}

function shouldPollThermal() {
  return !document.hidden && (state.currentTab === 'home' || state.currentTab === 'thermal');
}

function shouldPollOptim() {
  return !document.hidden && (state.currentTab === 'home' || state.currentTab === 'optim');
}

function refreshCurrentTabData() {
  if (document.hidden) return;
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
  if (state.currentTab === 'perf') {
    markPollFresh(['cpu'], now);
    refreshCpu();
    queueNextPoll(computeNextPollDelay(now));
    return;
  }
  if (state.currentTab === 'thermal') {
    markPollFresh(['thermal'], now);
    refreshThermal();
    queueNextPoll(computeNextPollDelay(now));
    return;
  }
  if (state.currentTab === 'optim') {
    markPollFresh(['optim', 'slow'], now);
    refreshSwap();
    refreshNrSwitch();
    refreshUecap();
    refreshBaseband();
    refreshNtp();
    refreshStandbyGuard();
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
  $('theme-open-btn').addEventListener('click', openThemeSheet);
  $('theme-open-btn-2').addEventListener('click', openThemeSheet);
  $('refresh-all-btn').addEventListener('click', doFullRefresh);
  $('refresh-cpu-btn').addEventListener('click', refreshCpu);
  $('swap-toggle-btn').addEventListener('click', toggleSwapMode);
  $('swap-detail-btn').addEventListener('click', () => openDetail('内存优化详情', SWAP_DETAIL));
  $('nr-switch-toggle-btn').addEventListener('click', toggleNrSwitch);
  $('sim2-auto-toggle-btn').addEventListener('click', toggleSim2AutoManage);
  $('idle-isolate-toggle-btn').addEventListener('click', toggleIdleIsolateMode);
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
  $('reboot-now-btn').addEventListener('click', rebootDevice);
  $('reboot-later-btn').addEventListener('click', closeRebootModal);
  $('reboot-cancel-btn').addEventListener('click', cancelThermalChange);
  $('open-cpu-detail-btn').addEventListener('click', () => {
    const cpuSet = {
      responsive: 'top-app: cpu0-7\nforeground: cpu0-6\nbackground: cpu0-3',
      balanced: 'top-app: cpu0-7\nforeground: cpu0-6\nbackground: cpu0-3',
      light: 'top-app: cpu0-6\nforeground: cpu0-6\nbackground: cpu0-3',
      battery: 'top-app: cpu0-6\nforeground: cpu0-6\nbackground: cpu0-3',
      default: 'top-app: cpu0-7\nforeground: cpu0-6\nbackground: cpu0-3'
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
    if (refs.detailModal.classList.contains('open')) { refs.detailModal.classList.remove('open'); return; }
    if (refs.themeModal.classList.contains('open')) { refs.themeModal.classList.remove('open'); return; }
    if (refs.rebootModal.classList.contains('open')) { refs.rebootModal.classList.remove('open'); return; }
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) stopPolling();
    else {
      state.poller.lastInteractionAt = Date.now();
      refreshCurrentTabData();
      startPolling();
    }
  });
}

async function refreshDeferredInitData() {
  markPollFresh(['optim', 'slow']);
  await Promise.allSettled([refreshSwap(), refreshNrSwitch(), refreshUecap(), refreshBaseband(), refreshNtp(), refreshStandbyGuard()]);
  queueNextPoll(computeNextPollDelay());
}

async function init() {
  const bootAt = Date.now();
  initRefs();
  initTheme();
  renderProfileCards();
  renderThermalCards();
  bindStaticEvents();
  bindTabSwipe();
  bindPullToRefresh();
  bindTopbarScroll();
  refs.topbarSubtitle.textContent = TAB_META[state.currentTab];
  positionMarkers();
  state.poller.lastInteractionAt = bootAt;
  markPollFresh(['cpu', 'thermal', 'optim', 'slow'], bootAt);
  await loadInfo();
  await Promise.all([loadSavedProfile(), loadThermalPreset()]);
  await refreshCpu();
  await refreshThermal();
  markPollFresh(['cpu', 'thermal']);
  window.setTimeout(refreshDeferredInitData, 1000);
  startPolling();
}

window.addEventListener('DOMContentLoaded', init);
