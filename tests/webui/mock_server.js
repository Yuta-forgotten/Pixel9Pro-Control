const fs = require('fs');
const http = require('http');
const path = require('path');

const root = path.resolve(__dirname, '..', '..', 'webroot');
const host = '127.0.0.1';
const port = 6210;
const token = 'pixel-test-token';

const CURRENT_MODULE_VERSION = 'v4.5.07';
const CURRENT_VERSION_CODE = '112';

const runtime = {
  profile: 'balanced',
  manualProfile: 'balanced',
  policy: 'manual',
  offset: 4,
  swapMode: 'optimized',
  nrSwitch: 'off',
  uecapMode: 'balanced',
  sim2Auto: 'on',
  idleIsolate: 'off',
  bgEnabled: 'on',
  ntpServer: 'time.android.com',
};

const cpuContract = {
  foreground_cpus: '0-6',
  background_cpus: '0-3',
  profiles: {
    performance: { response_ms: [12, 20, 80], uclamp_cap: 1024, top_app_cpus: '0-7' },
    balanced: { response_ms: [16, 40, 200], uclamp_cap: 0, top_app_cpus: '0-7' },
    battery: { response_ms: [28, 80, 320], uclamp_cap: 0, top_app_cpus: '0-6' },
    default: { response_ms: null, uclamp_cap: 1024, top_app_cpus: '0-7' },
  },
};

function json(res, body, status = 200) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Length': Buffer.byteLength(payload),
  });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > 4096) reject(new Error('request body too large'));
    });
    req.on('end', () => {
      if (!raw) return resolve({});
      try { resolve(JSON.parse(raw)); } catch (error) { reject(error); }
    });
    req.on('error', reject);
  });
}

function profileState(extra = {}) {
  return {
    ok: true,
    accepted: true,
    final: true,
    profile: runtime.profile,
    manual_profile: runtime.manualProfile,
    policy: runtime.policy,
    sched_owner: 'pixel',
    sched_effective_owner: 'pixel',
    game_handoff_policy: 'fas_rs',
    arbiter_state: 'BASELINE_NORMAL',
    arbiter_apply_result: 'stable_pixel_noop',
    arbiter_reason: 'no_target_focus',
    auto_reason: 'manual_selected',
    uperf_detected: true,
    uperf_module_name: 'Uperf Game Turbo',
    uperf_module_enabled: 'no',
    uperf_process_alive: 'no',
    uperf_active: 'no',
    fas_rs_detected: true,
    fas_rs_module_name: 'fas-rs',
    fas_rs_module_enabled: 'yes',
    fas_rs_process_alive: 'yes',
    fas_rs_runtime_state: 'resident_idle',
    fas_rs_runtime_owner_active: 'no',
    fas_rs_runtime_target: '',
    fas_rs_active: 'no',
    external_scheduler_detected: true,
    external_scheduler_active: false,
    external_scheduler_name: 'Uperf Game Turbo',
    external_scheduler_kind: 'uperf',
    effective_scheduler_owner: 'pixel',
    effective_scheduler_name: 'Pixel9Pro-Control',
    effective_scheduler_kind: 'pixel',
    profile_surface: 'authoritative',
    profile_surface_stale: false,
    profile_surface_note: '',
    cpu_contract: cpuContract,
    scheduler_boot: {
      target_mode: 'pixel', effective_mode: 'pixel', phase: 'success', final: 'yes', ok: 'yes',
      result: 'active_pixel', reason: 'pixel_profile_verified', attempts: 1,
      reboot_required: 'no', auto_repair_used: 'no',
    },
    scheduler_health: {
      status: 'healthy', reason: 'verified', checked_epoch: String(Math.floor(Date.now() / 1000)),
      profile_verified: 'yes', cpufreq_permissions: 'ok', powerhal_failures: '0',
    },
    profile_transition: { key: '', attempts: 0, terminal: 'no', ok: 'pending', result: '' },
    ...extra,
  };
}

function swapState() {
  const optimized = { swappiness: 100, min_free_kbytes: 131072, watermark_scale_factor: 200, vfs_cache_pressure: 60 };
  const stock = { swappiness: 150, min_free_kbytes: 27386, watermark_scale_factor: 50, vfs_cache_pressure: 100 };
  const active = runtime.swapMode === 'stock' ? stock : optimized;
  return {
    ok: true,
    mode: runtime.swapMode,
    zram_algo: 'lz77eh',
    zram_disksize: 8153489408,
    zram_active: true,
    zram_swap_kb: 7962388,
    swap_total_kb: 7962388,
    zram_owner: 'mmd',
    zram_target_supported: false,
    zram_orig_bytes: 5368709120,
    zram_compr_bytes: 2147483648,
    zram_mem_used_bytes: 2415919104,
    zram_target: { algorithm: 'lz77eh', size_bytes: 11945377792, policy: 'mmd_owned_on_supported_builds' },
    optimized,
    stock,
    stock_zram_size: 8589934592,
    ...active,
  };
}

function thermalZones() {
  return [
    { zone: 'VIRTUAL-SKIN', temp: 36500 },
    { zone: 'soc_therm', temp: 40200 },
    { zone: 'battery', temp: 33100 },
    { zone: 'charging_therm', temp: 34200 },
  ];
}

function basebandStatus(extra = {}) {
  return {
    installed: true,
    enabled: true,
    runtime_verified: true,
    module_dir: '/data/adb/modules/pixel9pro_baseband_trial',
    module_dir_state: 'active',
    module_state: 'enabled',
    source: 'active',
    root_impl: 'APatch',
    version: 'v1.1.0-rc3',
    version_code: '112',
    description: 'fixture baseband',
    runtime_status: 'PASS',
    mount_observed: 'yes',
    effective_overlay_verified: 'yes',
    source_contract_verified: 'yes',
    content_image_verified: 'yes',
    migration_state: 'effective_overlay_verified',
    source_path: '/data/adb/modules/pixel9pro_baseband_trial/system',
    effective_path: '/product,/vendor',
    content_image: '/data/adb/metamodule/mnt/content.img',
    source_hash: 'source-hash-0123456789abcdef0123456789abcdef',
    effective_hash: 'effective-hash-0123456789abcdef0123456789abcdef',
    content_image_hash: 'content-hash-0123456789abcdef0123456789abcdef',
    source_tree_hash: 'source-tree-hash-0123456789abcdef0123456789abcdef',
    content_tree_hash: 'content-tree-hash-0123456789abcdef0123456789abcdef',
    effective_contract_hash: 'effective-contract-hash-0123456789abcdef0123456789abcdef',
    clean_reinstall_required: false,
    pending_update: false,
    pending_update_dir: '',
    runtime_receipt_freshness: 'current_check',
    prior_receipt_freshness: 'current_boot_verified',
    current_runtime_check_freshness: 'current_check',
    boot_id: 'test-boot',
    errors: 'none',
    carrier_settings: { installed: true, count: 3210, carrier_list_sha256: 'carrier-hash' },
    mcfg: { installed: true, count: 5 },
    props: { volte_avail_ovr: '1', wfc_avail_ovr: '1', vt_avail_ovr: '1', apns_conf_sha256: 'apn-hash' },
    ...extra,
  };
}

function uecapState(extra = {}) {
  return {
    ok: true,
    device: 'caiman',
    device_label: 'Pixel 9 Pro',
    device_policy: 'managed',
    contract_result: 'valid',
    runtime_policy: 'managed',
    policy: 'manual',
    requested_mode: runtime.uecapMode,
    manual_mode: runtime.uecapMode,
    active_mode: runtime.uecapMode,
    reason: 'managed_runtime',
    disabled: false,
    disabled_message: '',
    last_switch: '0',
    target_name: 'PLATFORM_9055801516233416490.binarypb',
    target_hash: `${runtime.uecapMode}-hash`,
    special_hash: 'special-hash',
    balanced_hash: 'balanced-hash',
    universal_hash: 'universal-hash',
    uecap_contract: { mode_order: ['balanced', 'special', 'universal'], default_mode: 'balanced' },
    runtime_receipt: {
      schema: 3,
      boot_id: 'test-boot',
      updated_at: '0',
      reason: 'pre_modem',
      apply_result: 'applied',
      reload_dispatched: false,
      reload_result: 'not_required_pre_modem',
      effective_state: 'pre_modem_bind',
      bind_status: 'verified',
      device: 'caiman',
      device_policy: 'managed',
      desired_profile: runtime.uecapMode,
      bound_profile: runtime.uecapMode,
      modem_load_state: 'pre_modem_bind',
      modem_loaded_profile: 'unknown',
      radio_observed_state: 'NR_SA',
      functional_state: 'modem_load_unconfirmed',
      receipt_freshness: 'current_boot',
      actual_rat: 'NR_SA',
      nr_available: 'true',
      endc_available: 'not_applicable',
      nr_registered: 'true',
      nr_band: 'n41',
      nr_arfcn: '0',
      nr_frequency_range: 'FR1',
      lte_anchor: 'not_applicable',
      nsa_status: 'not_applicable',
      nsa_reason: 'sa_observed',
    },
    ...extra,
  };
}

function energyState(fast) {
  const now = Math.floor(Date.now() / 1000);
  return {
    ok: true,
    fast,
    generated_at: now,
    freshness_seconds: 0,
    window_minutes: 30,
    session: { start_epoch: now - 900, duration_sec: 900, discharge_mah: 18.4, rate_mah_per_h: 73.6 },
    battery: { level: 78, status: 'Discharging', voltage_mv: 3910, current_ma: -420, power_mw: 1642, temp_c: 33.1 },
    power_source: { source: 'battery', external_power: false },
    thermal: { current_c: 36.5, max_c: 38.2, samples: 18 },
    top_consumers: [
      { label: 'Screen', mah: 7.2 },
      { label: 'CPU', mah: 5.8 },
      { label: 'Wi-Fi', mah: 2.1 },
    ],
    system: fast ? undefined : { batterystats_age_seconds: 10, procstats_age_seconds: 12 },
  };
}

async function handleApi(req, res, url) {
  const pathname = url.pathname;
  const body = req.method === 'POST' ? await readBody(req) : {};
  if (req.method === 'POST' && req.headers['x-pixel9pro-token'] !== token) {
    return json(res, { ok: false, error: 'invalid token' }, 403);
  }
  switch (pathname) {
    case '/cgi-bin/status.sh': return json(res, { ok: true, service: 'mock' });
    case '/cgi-bin/auth.sh': return json(res, { token });
    case '/cgi-bin/info.sh': return json(res, {
      model: 'Pixel 9 Pro', version: '17', android: '17', kernel: '6.1-test', module_version: CURRENT_MODULE_VERSION,
      version_code: CURRENT_VERSION_CODE, httpd_rss_kb: 1240, mem_total_kb: 16384000,
      mem_avail_kb: 9216000, swap_total_kb: 11665408, swap_free_kb: 10321920,
      uptime_sec: 34567, baseband_installed: true, baseband_enabled: true,
      baseband_runtime_verified: true, baseband_version: 'v1.1.0-rc3', baseband_status: basebandStatus(),
    });
    case '/cgi-bin/profile.sh':
      if (body.profile) runtime.profile = runtime.manualProfile = body.profile;
      if (body.policy) runtime.policy = body.policy;
      return json(res, profileState());
    case '/cgi-bin/thermal.sh':
      if (url.searchParams.get('history') === '1') {
        const now = Math.floor(Date.now() / 1000);
        return json(res, { points: [[now - 600, 35100], [now - 300, 36200], [now, 36500]] });
      }
      return json(res, thermalZones());
    case '/cgi-bin/set_thermal.sh':
      if (Number.isFinite(body.offset)) runtime.offset = body.offset;
      return json(res, req.method === 'POST'
        ? { ok: true, offset: runtime.offset, restarted: true, thermal_contract: { offsets: [-2, 0, 2, 4, 6], default_offset: 4 } }
        : { offset: runtime.offset, thermal_contract: { offsets: [-2, 0, 2, 4, 6], default_offset: 4 } });
    case '/cgi-bin/swap.sh':
      if (body.mode) runtime.swapMode = body.mode;
      return json(res, swapState());
    case '/cgi-bin/nr_switch.sh':
      if (body.action === 'toggle') runtime.nrSwitch = runtime.nrSwitch === 'on' ? 'off' : 'on';
      return json(res, {
        ok: true, enabled: runtime.nrSwitch, current_mode: '33', current_slot0: '33', actual_rat: 'NR SA',
        saved_nr_mode: '33', screen_off_delay_s: 300, restore_cooldown_s: 600,
        lte_recheck_s: 300, lte_mode: 9,
      });
    case '/cgi-bin/uecap.sh':
      if (body.mode) runtime.uecapMode = body.mode;
      return json(res, uecapState());
    case '/cgi-bin/check_baseband.sh': return json(res, basebandStatus());
    case '/cgi-bin/standby_guard.sh':
      if (body.sim2_auto_manage) runtime.sim2Auto = body.sim2_auto_manage;
      if (body.idle_isolate_mode) runtime.idleIsolate = body.idle_isolate_mode;
      return json(res, {
        ok: true, sim2_auto_manage: runtime.sim2Auto, idle_isolate_mode: runtime.idleIsolate,
        diag_worker_mode: 'screen_on', diag_next_sleep_sec: 15, diag_updated_epoch: Math.floor(Date.now() / 1000),
        diag_profile_policy: runtime.policy, diag_active_profile: runtime.profile,
      });
    case '/cgi-bin/bg_restrict.sh':
      if (body.action === 'toggle') runtime.bgEnabled = runtime.bgEnabled === 'on' ? 'off' : 'on';
      return json(res, {
        ok: true, enabled: runtime.bgEnabled, entries: [],
        bg_contract: {
          policy_order: ['stop_after_leave', 'block_all', 'block_services', 'bucket'],
          allowed_delays: [3, 5, 10], default_policy: 'stop_after_leave', default_delay: 5,
        },
        suggestions: [{ package: 'com.ss.android.ugc.aweme', label: 'Douyin', policy: 'stop_after_leave', delay_min: 5 }],
      });
    case '/cgi-bin/ntp.sh':
      if (body.server) runtime.ntpServer = body.server;
      return json(res, {
        ok: true, server: runtime.ntpServer, current: runtime.ntpServer, last_sync: Math.floor(Date.now() / 1000),
        servers: [
          { host: 'time.android.com', label: 'Android', region: 'global', default: true },
          { host: 'ntp.aliyun.com', label: 'Aliyun', region: 'cn', default: false },
        ],
      });
    case '/cgi-bin/energy.sh': return json(res, energyState(url.searchParams.get('fast') === '1'));
    case '/cgi-bin/thermal_burst.sh': return json(res, { ok: true, active: body.action !== 'stop' });
    case '/cgi-bin/history_export.sh': return json(res, { ok: true, path: '/sdcard/Download/pixel9pro-control-test.csv' });
    case '/cgi-bin/owner_arbiter.sh': return json(res, profileState());
    case '/cgi-bin/theme.sh': return json(res, req.method === 'POST' ? { ok: true } : { mode: 'system', palette: 'default', custom: '#3aa6c2' });
    case '/cgi-bin/reboot.sh': return json(res, { ok: true });
    default: return json(res, { ok: false, error: `unhandled mock route: ${pathname}` }, 404);
  }
}

function serveStatic(res, pathname) {
  const relative = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
  const resolved = path.resolve(root, relative);
  if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) {
    return json(res, { ok: false, error: 'invalid path' }, 400);
  }
  if (!fs.existsSync(resolved) || !fs.statSync(resolved).isFile()) {
    return json(res, { ok: false, error: 'not found' }, 404);
  }
  const ext = path.extname(resolved).toLowerCase();
  const type = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8' }[ext]
    || 'application/octet-stream';
  let data = fs.readFileSync(resolved);
  if (ext === '.html') data = Buffer.from(data.toString('utf8').replaceAll('__WEBUI_VER__', 'test'));
  res.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-store', 'Content-Length': data.length });
  res.end(data);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${host}:${port}`);
    if (url.pathname === '/favicon.ico') {
      res.writeHead(204, { 'Cache-Control': 'no-store' });
      res.end();
    } else if (url.pathname.startsWith('/cgi-bin/')) await handleApi(req, res, url);
    else serveStatic(res, url.pathname);
  } catch (error) {
    json(res, { ok: false, error: error.message }, 500);
  }
});

server.listen(port, host, () => process.stdout.write(`mock WebUI listening on http://${host}:${port}\n`));

function shutdown() {
  server.close(() => process.exit(0));
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
