const fs = require('fs');
const path = require('path');

const root = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const html = fs.readFileSync(path.join(root, 'webroot', 'index.html'), 'utf8');
const app = fs.readFileSync(path.join(root, 'webroot', 'app.js'), 'utf8');
const profileCgi = fs.readFileSync(path.join(root, 'webroot', 'cgi-bin', 'profile.sh'), 'utf8');
const ownerArbiterCgi = fs.readFileSync(path.join(root, 'webroot', 'cgi-bin', 'owner_arbiter.sh'), 'utf8');
const thermalCgi = fs.readFileSync(path.join(root, 'webroot', 'cgi-bin', 'set_thermal.sh'), 'utf8');
const thermalReadCgi = fs.readFileSync(path.join(root, 'webroot', 'cgi-bin', 'thermal.sh'), 'utf8');
const rebootCgi = fs.readFileSync(path.join(root, 'webroot', 'cgi-bin', 'reboot.sh'), 'utf8');
const ntpCgi = fs.readFileSync(path.join(root, 'webroot', 'cgi-bin', 'ntp.sh'), 'utf8');
const swapCgi = fs.readFileSync(path.join(root, 'webroot', 'cgi-bin', 'swap.sh'), 'utf8');
const optimizeCgi = fs.readFileSync(path.join(root, 'webroot', 'cgi-bin', 'optimize.sh'), 'utf8');
const standbyCgi = fs.readFileSync(path.join(root, 'webroot', 'cgi-bin', 'standby_guard.sh'), 'utf8');
const nrCgi = fs.readFileSync(path.join(root, 'webroot', 'cgi-bin', 'nr_switch.sh'), 'utf8');
const commonCgi = fs.readFileSync(path.join(root, 'webroot', 'cgi-bin', '_common.sh'), 'utf8');
const uecapCgi = fs.readFileSync(path.join(root, 'webroot', 'cgi-bin', 'uecap.sh'), 'utf8');
const uecapProfile = fs.readFileSync(path.join(root, 'uecap_profile.sh'), 'utf8');
const customize = fs.readFileSync(path.join(root, 'customize.sh'), 'utf8');
const service = fs.readFileSync(path.join(root, 'service.sh'), 'utf8');
const thermalLib = fs.readFileSync(path.join(root, 'scripts', 'thermal_profile.sh'), 'utf8');
const cpuProfileLib = fs.readFileSync(path.join(root, 'scripts', 'cpu_profile_lib.sh'), 'utf8');
const nrModeLib = fs.readFileSync(path.join(root, 'scripts', 'nr_mode_lib.sh'), 'utf8');
const cpuProfile = fs.readFileSync(path.join(root, 'scripts', 'cpu_profile.sh'), 'utf8');
const ownerArbiter = fs.readFileSync(path.join(root, 'scripts', 'owner_arbiter.sh'), 'utf8');
const ntpCatalog = fs.readFileSync(path.join(root, 'config', 'ntp_servers.tsv'), 'utf8');
const runtimeDefaults = fs.readFileSync(path.join(root, 'scripts', 'runtime_defaults_lib.sh'), 'utf8');
const basebandCustomize = fs.readFileSync(path.join(root, 'modules', 'pixel9pro_baseband_trial', 'customize.sh'), 'utf8');
const moduleProp = fs.readFileSync(path.join(root, 'module.prop'), 'utf8');
const versionsProp = fs.readFileSync(path.join(root, 'versions.prop'), 'utf8');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const htmlContracts = [
  [/<div class="preference-group" id="external-scheduler-controls" data-module-visible="ugt\|fas" hidden>/, 'external scheduler group must default hidden'],
  [/<div class="ctrl-row" id="sched-owner-row" data-module-visible="ugt" hidden>/, 'UGT daily owner row must require UGT'],
  [/<div class="ctrl-row" id="game-handoff-row" data-module-visible="fas" hidden>/, 'fas-rs handoff row must require fas-rs'],
  [/<div class="ctrl-row" id="owner-arbiter-row" data-module-visible="fas" hidden>/, 'fas-rs arbiter row must require fas-rs'],
  [/<article class="surface-card preference-card" id="baseband-card" data-module-visible="baseband" hidden>/, 'baseband card must default hidden'],
];
for (const [pattern, message] of htmlContracts) assert(pattern.test(html), message);

assert(app.includes("document.querySelectorAll('[data-module-visible]')"), 'generic optional-module visibility binding is missing');
assert(app.includes('baseband: state.basebandInstalled && state.deviceModel === \'Pixel 9 Pro\''), 'baseband visibility must require the supported device and installed module');
assert(app.includes('ugt: state.uperfDetected') && app.includes('fas: state.fasRsDetected'), 'UGT/fas-rs visibility must use independent detection flags');
assert(app.includes('if (!state.basebandInstalled)'), 'baseband detail fetch must be skipped when the module is absent');
for (const transitionCopy of [
  '正在停止旧调度器、恢复 CPU 基线并复读关键节点，通常需要数秒。',
  '正在更新 fas-rs 接管策略并核对当前 owner，通常需要数秒。',
  '正在复读前台场景、owner 和关键调度节点，通常需要数秒。',
  '正在应用 profile 并复读关键调度节点，通常需要数秒。',
  '正在应用当前 profile 并复读调度状态，通常需要数秒。',
]) {
  assert(app.includes(transitionCopy), `current strategy transition copy is missing: ${transitionCopy}`);
}
assert(app.includes('function isCurrentStrategyBusy()'), 'current strategy controls must share one busy guard');
assert(app.includes('refs.gameHandoffToggleBtn.disabled = strategyBusy'), 'game handoff must be locked during any strategy transition');
assert(app.includes('refs.profilePolicyManualBtn.disabled = strategyBusy'), 'profile policy must be locked during any strategy transition');

for (const phrase of ['日常推荐', '性能更积极', '适合日常', '日常常用', '温度控制最稳妥', '机身更凉']) {
  assert(!html.includes(phrase) && !app.includes(phrase), `thermal UI must not contain recommendation copy: ${phrase}`);
}

const thermalPresetStart = app.indexOf('const THERMAL_PRESETS = {');
const thermalPresetEnd = app.indexOf('\n};', thermalPresetStart);
assert(thermalPresetStart >= 0 && thermalPresetEnd > thermalPresetStart, 'thermal preset block is missing');
const thermalPresetBlock = app.slice(thermalPresetStart, thermalPresetEnd);
assert(app.includes('const THERMAL_OFFSETS = Object.freeze([-2, 0, 2, 4, 6])'), 'thermal UI must define all five current presets once');
assert(app.includes('THERMAL_OFFSETS.forEach((offset) =>'), 'thermal UI must render the shared preset list');
assert(app.includes('THERMAL_OFFSETS.includes(data.offset) ? data.offset : THERMAL_DEFAULT_OFFSET'), 'thermal UI must accept -2 and use the named default');
for (const offset of ['[-2]', '0', '2', '4', '6']) {
  assert(thermalPresetBlock.includes(`${offset}: {`), `thermal preset ${offset} is missing`);
}
assert(thermalCgi.includes('. "$THERMAL_LIB"'), 'thermal CGI must use the shared thermal library');
assert(!thermalCgi.includes('awk -v off='), 'thermal CGI must not duplicate the thermal transformer');
assert(customize.includes('. "$MODPATH/scripts/thermal_profile.sh"'), 'installer must use the shared thermal library');
assert(customize.includes('_ofs_vals="-2 0 2 4 6"'), 'installer must expose all five current thermal offsets');
assert(thermalLib.includes('-2|0|2|4|6') && thermalLib.includes('THERMAL_SHUTDOWN_SLOT=7'), 'shared thermal contract must expose five presets and preserve shutdown');

for (const host of ['ntp.aliyun.com', 'ntp.myhuaweicloud.com', 'ntp1.xiaomi.com', 'time.android.com']) {
  assert(ntpCatalog.includes(host), `NTP catalog is missing ${host}`);
  assert(!app.includes(`id: '${host}'`), `app.js must not duplicate NTP host ${host}`);
}
assert(ntpCgi.includes('ntp_config_validate') && service.includes('ntp_config_validate'), 'NTP consumers must validate the shared catalog');
assert(!app.includes('const SWAP_OPTIMIZED') && !swapCgi.includes('OPT_SWAPPINESS='), 'VM presets must come from vm_profile_lib.sh');
assert(swapCgi.includes('. "$VM_PROFILE_LIB"') && app.includes('data.zram_target'), 'VM CGI and UI must consume the shared VM contract');
assert(cpuProfile.includes('. "$CPU_PROFILE_LIB"') && ownerArbiter.includes('. "$MODDIR/scripts/cpu_profile_lib.sh"'), 'CPU apply and owner verification must share one profile contract');
assert(!ownerArbiter.includes('_oa_resp="16 40 200"'), 'owner arbiter must not duplicate CPU response triplets');
assert(!ownerArbiter.includes('command -v detect_'), 'owner arbiter must require its scheduler-detection contract');
assert((ownerArbiter.match(/detect_external_scheduler 2>\/dev\/null/g) || []).length === 1, 'owner arbiter must scan external schedulers once per tick');
assert(profileCgi.includes('cpu_profile_contract_json') && app.includes('state.cpuContract'), 'WebUI CPU values must come from the backend profile contract');
assert(cpuProfileLib.includes('cpu_profile_contract_json()'), 'CPU profile library must serialize its runtime contract');
assert(runtimeDefaults.includes('SIM2_AUTO_DEFAULT="on"'), 'SIM2 default must be defined by the runtime defaults contract');
assert(optimizeCgi.includes('sim2_auto="$SIM2_AUTO_DEFAULT"') && standbyCgi.includes('"$SIM2_AUTO_DEFAULT"'), 'SIM2 CGI defaults must consume the shared contract');
assert(nrCgi.includes('"$NR_SCREEN_SWITCH_DEFAULT"') && !nrCgi.includes('echo "on"'), 'NR CGI default must consume the shared contract');
assert(service.includes('scripts/nr_mode_lib.sh') && nrCgi.includes('scripts/nr_mode_lib.sh'), 'service and NR CGI must share the NR mode contract');
assert(nrModeLib.includes('nr_mode_write_verified()') && nrModeLib.includes('nr_mode_save_current()'), 'NR contract must verify writes and persist a restore mode');
assert(nrCgi.includes('"screen_off_delay_s"') && app.includes('state.nrContract'), 'WebUI NR timing must come from the backend runtime contract');
assert(!app.includes('30-50%'), 'NR detail must not promise an unverified fixed power-saving percentage');
assert(customize.includes('不支持的设备') && customize.includes('XL 温控 stock 配置缺失'), 'installer must reject unknown devices and missing XL stock data');
assert(customize.includes('UECAP_DISABLED_REASON="uecap_unsupported_device"'), 'XL installs must disable the caiman-only UECap payload');
assert(basebandCustomize.includes('[ "$device" != "caiman" ]'), 'baseband submodule must reject non-caiman devices');
assert(!service.includes('# v4.'), 'service.sh must not contain a release changelog');
assert(!fs.existsSync(path.join(root, 'system.prop')), 'empty system.prop must not be packaged');
assert(moduleProp.includes('version=v4.5.01') && moduleProp.includes('versionCode=106'), 'release version must be v4.5.01 / 106');
for (const component of ['webui=4.5.01', 'scheduler=4.5.01', 'core=4.5.01']) {
  assert(versionsProp.includes(component), `component version is stale: ${component}`);
}
assert(commonCgi.includes("'413 Payload Too Large'") && commonCgi.includes('JSON object required'), 'all write CGI must share bounded JSON-object parsing');
for (const cgi of [profileCgi, thermalCgi, ntpCgi, swapCgi, standbyCgi, nrCgi, uecapCgi]) {
  assert(cgi.includes('read_json_body '), 'write CGI must consume the shared JSON body reader');
}
assert(ownerArbiterCgi.includes('read_json_body 128') && ownerArbiterCgi.includes('invalid owner arbiter action'), 'manual owner tick must validate its JSON action');
assert(rebootCgi.includes('acquire_lock "reboot"'), 'reboot requests must be serialized after confirmation');
assert(thermalReadCgi.includes('acquire_lock "thermal_cache"'), 'thermal cache clears must use a mutation lock');
assert(thermalReadCgi.includes('[ ! -e "$THERMAL_CACHE" ]'), 'thermal cache deletion must be verified');
assert(!thermalReadCgi.includes('*clear=1*'), 'GET must not mutate the thermal cache');
assert(app.includes("options.method = 'POST'") && app.includes("JSON.stringify({ action: 'clear' })"), 'thermal cache clear must use authenticated POST');
assert(!uecapCgi.includes('auto|manual') && !uecapCgi.includes('toggle_mode()'), 'UECap CGI must not retain the retired auto/toggle branches');
assert(!uecapProfile.includes('auto|manual'), 'UECap runtime contract must remain manual-only');

const emitProfileStart = profileCgi.indexOf('emit_profile_state()');
const emitProfileEnd = profileCgi.indexOf('\n}\n', emitProfileStart);
assert(emitProfileStart >= 0 && emitProfileEnd > emitProfileStart, 'profile state emitter is missing');
const emitProfileBody = profileCgi.slice(emitProfileStart, emitProfileEnd);
assert(emitProfileBody.includes('detect_external_scheduler'), 'profile state emitter must detect optional schedulers');
assert(!emitProfileBody.includes('detect_uperf_module'), 'profile state emitter must not scan UGT twice');

const inventoryStart = customize.indexOf('report_optional_module_inventory()');
const inventoryEnd = customize.indexOf('\n}\n', inventoryStart);
assert(inventoryStart >= 0 && inventoryEnd > inventoryStart, 'first-install optional-module inventory is missing');
const inventoryBody = customize.slice(inventoryStart, inventoryEnd);
assert(inventoryBody.includes('UGT:') && inventoryBody.includes('fas-rs:') && inventoryBody.includes('Pixel 9 Pro 基带模块:'), 'installer inventory must report all optional modules independently');
assert(!/https?:\/\//.test(inventoryBody), 'installer inventory must not contain installation links');
assert(customize.includes('if [ "$_is_upgrade" -eq 0 ]; then\n    report_optional_module_inventory'), 'inventory must run on first install');

console.log('optional module UI/install contracts OK');
