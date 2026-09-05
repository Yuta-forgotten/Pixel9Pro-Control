const fs = require('fs');
const path = require('path');

const root = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const html = fs.readFileSync(path.join(root, 'webroot', 'index.html'), 'utf8');
const webuiScripts = [...html.matchAll(/<script\s+src="([^"]+)"/g)]
  .map((match) => match[1].split('?')[0].replace(/^\//, ''));
const app = webuiScripts
  .map((scriptPath) => fs.readFileSync(path.join(root, 'webroot', scriptPath), 'utf8'))
  .join('\n');
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
const postMount = fs.readFileSync(path.join(root, 'post-mount.sh'), 'utf8');
const customize = fs.readFileSync(path.join(root, 'customize.sh'), 'utf8');
const service = fs.readFileSync(path.join(root, 'service.sh'), 'utf8');
const thermalLib = fs.readFileSync(path.join(root, 'scripts', 'thermal_profile.sh'), 'utf8');
const bgRestrictLib = fs.readFileSync(path.join(root, 'scripts', 'bg_restrict_lib.sh'), 'utf8');
const cpuProfileLib = fs.readFileSync(path.join(root, 'scripts', 'cpu_profile_lib.sh'), 'utf8');
const nrModeLib = fs.readFileSync(path.join(root, 'scripts', 'nr_mode_lib.sh'), 'utf8');
const cpuProfile = fs.readFileSync(path.join(root, 'scripts', 'cpu_profile.sh'), 'utf8');
const ownerArbiter = [
  'owner_arbiter.sh',
  'owner_arbiter_state_lib.sh',
  'owner_arbiter_observation_lib.sh',
  'owner_arbiter_external_lib.sh',
  'owner_arbiter_cpufreq_lib.sh'
].map((name) => fs.readFileSync(path.join(root, 'scripts', name), 'utf8')).join('\n');
const ntpCatalog = fs.readFileSync(path.join(root, 'config', 'ntp_servers.tsv'), 'utf8');
const runtimeDefaults = fs.readFileSync(path.join(root, 'scripts', 'runtime_defaults_lib.sh'), 'utf8');
const displayStateLib = fs.readFileSync(path.join(root, 'scripts', 'display_state_lib.sh'), 'utf8');
const schedulerDetectLib = fs.readFileSync(path.join(root, 'scripts', 'scheduler_detect_lib.sh'), 'utf8');
const schedulerBootLib = fs.readFileSync(path.join(root, 'scripts', 'scheduler_boot_mode_lib.sh'), 'utf8');
const schedulerOwnerLib = fs.readFileSync(path.join(root, 'scripts', 'scheduler_owner_lib.sh'), 'utf8');
const schedulerReconcile = fs.readFileSync(path.join(root, 'scripts', 'scheduler_reconcile.sh'), 'utf8');
const schedulerGuard = fs.readFileSync(path.join(root, 'scripts', 'scheduler_transition_guard_lib.sh'), 'utf8');
const basebandRoot = process.env.PIXEL9PRO_BASEBAND_ROOT
  ? path.resolve(process.env.PIXEL9PRO_BASEBAND_ROOT)
  : path.resolve(root, '..', 'pixel9pro_baseband_trial_module');
assert(fs.existsSync(basebandRoot), `standalone baseband source is missing: ${basebandRoot}`);
const basebandCustomize = fs.readFileSync(path.join(basebandRoot, 'customize.sh'), 'utf8');
const basebandManifest = fs.readFileSync(path.join(basebandRoot, 'config', 'baseband_devices.tsv'), 'utf8');
const moduleProp = fs.readFileSync(path.join(root, 'module.prop'), 'utf8');
const versionsProp = fs.readFileSync(path.join(root, 'versions.prop'), 'utf8');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const htmlContracts = [
  [/<div class="preference-group" id="external-scheduler-controls">/, 'scheduler control group must remain visible for independent health state'],
  [/<div class="ctrl-row" id="sched-owner-row" data-module-visible="ugt" hidden>/, 'UGT daily owner row must require UGT'],
  [/<div class="ctrl-row" id="scheduler-health-row">/, 'scheduler health row must be independent of optional UGT/fas-rs visibility'],
  [/<div class="ctrl-row" id="game-handoff-row" data-module-visible="fas" hidden>/, 'fas-rs handoff row must require fas-rs'],
  [/<div class="ctrl-row" id="owner-arbiter-row" data-module-visible="fas" hidden>/, 'fas-rs arbiter row must require fas-rs'],
  [/<article class="surface-card preference-card" id="baseband-card" data-module-visible="baseband" hidden>/, 'baseband card must default hidden'],
];
for (const [pattern, message] of htmlContracts) assert(pattern.test(html), message);

assert(app.includes("document.querySelectorAll('[data-module-visible]')"), 'generic optional-module visibility binding is missing');
assert(app.includes("baseband: requireFeature('network').isBasebandInstalled()"), 'baseband visibility must use the standalone module state');
assert(!app.includes("requireFeature('shell').getDeviceModel() === 'Pixel 9 Pro'"), 'baseband visibility must not use the display model as a SKU gate');
assert(app.includes('ugt: state.uperfDetected') && app.includes('fas: state.fasRsDetected'), 'UGT/fas-rs visibility must use independent detection flags');
assert(app.includes('if (!state.basebandInstalled && (!state.basebandState || !state.basebandState.installed))'), 'baseband detail fetch must be skipped only when the module state is absent');
for (const transitionCopy of [
  '正在提交下次启动模式；当前 boot 不会热启动或热停止 UGT。',
  '正在更新 fas-rs 接管策略并核对当前 owner，通常需要数秒。',
  '正在复读前台场景、owner 和关键调度节点，通常需要数秒。',
  '正在应用 profile 并复读关键调度节点，通常需要数秒。',
  '正在应用当前 profile 并复读调度状态，通常需要数秒。',
]) {
  assert(app.includes(transitionCopy), `current strategy transition copy is missing: ${transitionCopy}`);
}
assert(app.includes('function isCurrentStrategyBusy()'), 'current strategy controls must share one busy guard');
assert(app.includes('refs.gameHandoffToggleBtn.disabled = strategyBusy || !isVerifiedSchedulerBoot()'), 'game handoff must require a verified Pixel or UGT baseline');
assert(app.includes('refs.profilePolicyManualBtn.disabled = strategyBusy || !isVerifiedPixelBoot()'), 'profile policy must require a verified Pixel boot');

for (const phrase of ['日常推荐', '性能更积极', '适合日常', '日常常用', '温度控制最稳妥', '机身更凉']) {
  assert(!html.includes(phrase) && !app.includes(phrase), `thermal UI must not contain recommendation copy: ${phrase}`);
}

const thermalPresetStart = app.indexOf('const THERMAL_PRESETS = {');
const thermalPresetEnd = app.indexOf('\n};', thermalPresetStart);
assert(thermalPresetStart >= 0 && thermalPresetEnd > thermalPresetStart, 'thermal preset block is missing');
const thermalPresetBlock = app.slice(thermalPresetStart, thermalPresetEnd);
for (const [label, source, prefix] of [
  ['thermal', thermalLib, '_tp_'],
  ['BG', bgRestrictLib, '_bg_'],
  ['UECap', uecapProfile, '_uecap_'],
]) {
  const shellLocals = [...source.matchAll(/^\s*(_[A-Za-z0-9_]+)=/gm)].map((match) => match[1]);
  assert(shellLocals.every((name) => name.startsWith(prefix)), `${label} library has unscoped shell variables`);
  assert(!/^\s*(?:\.|source)\s+/m.test(source), `${label} leaf library must not source another library`);
}
assert(!app.includes('const THERMAL_OFFSETS') && !app.includes('THERMAL_DEFAULT_OFFSET'), 'thermal JS must not retain the offset allowlist or default');
assert(app.includes('const raw = data?.thermal_contract') && app.includes('state.contract.offsets.forEach((offset) =>'), 'thermal UI must render the backend contract order');
for (const offset of ['[-2]', '0', '2', '4', '6']) {
  assert(thermalPresetBlock.includes(`${offset}: {`), `thermal preset ${offset} is missing`);
}
assert(thermalCgi.includes('. "$THERMAL_LIB"'), 'thermal CGI must use the shared thermal library');
assert(thermalCgi.includes('parse_thermal_offset'), 'thermal CGI must strictly parse the JSON offset body');
assert(!thermalCgi.includes('sed \'s/.*"offset"'), 'thermal CGI must not use greedy offset extraction');
assert(thermalCgi.includes('vendor.thermal.config') && thermalCgi.includes('thermal_info_config_lpm.json'), 'thermal CGI must follow the HAL-selected config');
assert(customize.includes('vendor.thermal.config') && customize.includes('不支持的 Thermal HAL 配置'), 'installer must fail closed for unknown HAL config');
assert(customize.includes('LPM 是顶层增量配置') || customize.includes('LPM is a top-level overlay'), 'installer must preserve LPM include semantics');
assert(thermalCgi.includes('LPM includes the base config'), 'thermal CGI must mutate the included base config for LPM');
assert(!thermalCgi.includes('awk -v off='), 'thermal CGI must not duplicate the thermal transformer');
assert(customize.includes('. "$MODPATH/scripts/thermal_profile.sh"'), 'installer must use the shared thermal library');
assert(customize.includes('_ofs_vals="$THERMAL_ALLOWED_OFFSETS"') && customize.includes('"$_ofs_scan_value" = "$THERMAL_DEFAULT_OFFSET"'), 'installer must consume the shared thermal order and default');
assert(thermalLib.includes('THERMAL_ALLOWED_OFFSETS="-2 0 2 4 6"') && thermalLib.includes('thermal_print_ui_contract_json()') && thermalLib.includes('THERMAL_SHUTDOWN_SLOT=7'), 'shared thermal contract must expose five presets and preserve shutdown');
assert(thermalCgi.includes('"thermal_contract":') && app.includes('thermal_contract'), 'thermal CGI must expose the backend-owned UI contract');
assert(app.includes('const BG_RESTRICT_POLICY_PRESENTATION') && !app.includes('BG_RESTRICT_POLICY_ORDER') && !app.includes('BG_RESTRICT_DELAYS'), 'BG JS must retain presentation only');
assert(html.includes('id="bg-restrict-policy-select" aria-label="后台限制策略" disabled></select>')
  && html.includes('id="bg-restrict-delay-select" aria-label="休眠延时" disabled></select>'), 'BG HTML must wait for the backend contract instead of embedding behavior options');
assert(app.includes('const raw = data?.bg_contract') && service.includes('bg_default_seed_entry') && !customize.includes('com.ss.android.ugc.aweme|stop_after_leave|5'), 'BG policy, delay and seed defaults must come from the backend contract');
assert(uecapProfile.includes('UECAP_MODE_ORDER="balanced special universal"') && uecapProfile.includes('uecap_print_ui_contract_json()'), 'UECap runtime must own mode order and default');
assert(uecapProfile.includes('case "${0##*/}" in') && uecapProfile.includes('uecap_profile.sh) uecap_main "$@"'), 'sourcing UECap library must not dispatch CLI mutations');
assert(customize.includes('_UE_VALS=$(sh "$MODPATH/uecap_profile.sh" modes')
  && customize.includes('_ue_default=$(sh "$MODPATH/uecap_profile.sh" default')
  && customize.includes('_ue_default_found=1')
  && !customize.includes('_UE_VALS="balanced special universal"'), 'installer must fail closed while consuming the UECap CLI contract');
assert(uecapProfile.includes('*)\n            return 1'), 'UECap CLI must reject unknown commands');
assert(uecapCgi.includes('uecap_is_valid_mode "$mode"') && app.includes('const raw = data?.uecap_contract') && !app.includes('const UECAP_MODES'), 'UECap CGI and UI must consume the backend mode contract');
assert(uecapProfile.includes('uecap_print_ui_contract_json()') && app.includes("modeOrder.length !== 0 || defaultMode !== 'disabled'"), 'disabled UECap schema must be generated from the empty backend contract');

for (const host of ['ntp.aliyun.com', 'ntp.myhuaweicloud.com', 'ntp1.xiaomi.com', 'time.android.com']) {
  assert(ntpCatalog.includes(host), `NTP catalog is missing ${host}`);
  assert(!app.includes(`id: '${host}'`), `app.js must not duplicate NTP host ${host}`);
}
assert(ntpCgi.includes('ntp_config_validate') && service.includes('ntp_config_validate'), 'NTP consumers must validate the shared catalog');
assert(!app.includes('const SWAP_OPTIMIZED') && !swapCgi.includes('OPT_SWAPPINESS='), 'VM presets must come from vm_profile_lib.sh');
assert(swapCgi.includes('. "$VM_PROFILE_LIB"') && app.includes('data.zram_target'), 'VM CGI and UI must consume the shared VM contract');
assert(cpuProfile.includes('. "$CPU_PROFILE_LIB"') && ownerArbiter.includes('. "$MODDIR/scripts/cpu_profile_lib.sh"'), 'CPU apply and owner verification must share one profile contract');
assert(cpuProfile.includes('apply_profile_l2') && cpuProfile.includes('verify_profile_runtime'), 'CPU and L2 must be one verified profile transaction');
assert(!service.includes('cpu_profile.sh" enforce') && !service.includes('POWER_PROFILE_FILE'), 'service must not retain the legacy 15-second L2 writer or .power_profile SoT');
assert(ownerArbiter.includes('start_uperf()') && ownerArbiter.includes('stop_uperf()'), 'owner arbiter must support reversible UGT/fas-rs game leases');
assert(ownerArbiter.includes('libuperf.sh') && ownerArbiter.includes('uperf_start') && !/sh\s+[^\n]*initsvc\.sh/.test(ownerArbiter), 'UGT restore must call its lifecycle helper without replaying full boot initialization');
assert(!ownerArbiter.includes('UGT_EXCLUSIVE') && !ownerArbiter.includes('ugt_boot_exclusive_noop'), 'UGT must remain a restorable daily baseline instead of an exclusive no-handoff state');
assert(!ownerArbiter.includes('PIXEL_NORMAL'), 'legacy Pixel-only arbiter state must not bypass shared baseline no-op handling');
assert(ownerArbiter.includes('_oa_locked_mode=$(sbm_owner_to_mode "$_oa_locked_desired")'), 'post-lock owner validation must accept the verified mode for the persistent baseline');
assert(service.includes('[ "$SBM_EFFECTIVE_MODE" = "pixel" ] || [ "$SBM_EFFECTIVE_MODE" = "ugt" ]'), 'service must run the owner worker for both verified baselines');
assert(schedulerBootLib.includes('module "$_sbm_apd_action"') && schedulerBootLib.includes('pending_reboot_to_'), 'boot-mode contract must stage UGT through APatch and publish pending reboot');
assert(schedulerReconcile.includes('SBM_MAX_WRITE_ATTEMPTS') && schedulerReconcile.includes('sr_verify_profile_stable'), 'scheduler reconcile must bound writes and verify stability');
assert(schedulerGuard.includes('retry_budget_exhausted') && schedulerGuard.includes('STG_TERMINAL=yes'), 'scheduler transition guard must latch a final retry result');
assert(schedulerGuard.includes('STG_TERMINAL_FILE') && schedulerGuard.includes('stg_commit_terminal_bounded'), 'scheduler transition guard must preserve terminal success/failure through a fallback channel');
assert(service.includes('scheduler_reconcile.sh" health') && service.includes('SBM_HEALTH_INTERVAL_S'), 'service must run the independent low-frequency read-only health worker');
assert(app.includes('refs.schedulerHealthRow.hidden = false'), 'scheduler health UI must not be coupled to optional UGT visibility');
assert(app.includes('检查延后 · 调度切换中') && app.includes('检查延后 · 外部调度接管中'), 'deferred scheduler health must explain transition and external-owner states');
assert(schedulerOwnerLib.includes('SO_TRANSITION_LOCK_INIT_GRACE_S') && schedulerOwnerLib.includes('so_reclaim_transition_lock()'), 'owner lock contract must distinguish initialization grace from bounded stale reclaim');
assert(schedulerOwnerLib.includes('so_capture_current_process_id()') && schedulerOwnerLib.includes('SO_TRANSITION_LOCK_PID'), 'owner lock metadata must use the actual background worker PID instead of inherited $$');
assert(schedulerOwnerLib.includes('SO_BOOT_ID_PATH') && schedulerOwnerLib.includes('SO_TRANSITION_LOCK_BOOT_ID'), 'owner lock identity must include the current boot ID');
assert(schedulerOwnerLib.includes('"$SO_TRANSITION_LOCK_DIR/.pid_probe"') && schedulerOwnerLib.includes('so_reclaim_transition_lock()'), 'stale reclaim must remove the lock contract\'s interrupted PID probe');
assert(schedulerReconcile.includes('fas_rs_runtime_lease') && schedulerReconcile.includes('ugt_baseline_verified'), 'health must defer for fas-rs leases and verify the restored UGT baseline');
assert(schedulerReconcile.includes('health|status|boot|repair|retry) ;;'), 'scheduler reconcile actions must be classified before any writable migration');
const reconcileLockIndex = schedulerReconcile.indexOf('if ! so_acquire_transition_lock; then');
const reconcileMigrationIndex = schedulerReconcile.indexOf('so_migrate_state');
assert(reconcileLockIndex >= 0 && reconcileMigrationIndex > reconcileLockIndex, 'scheduler owner-state migration must run only after the transition lock is acquired');
assert(ownerArbiter.indexOf('so_migrate_state') > ownerArbiter.indexOf('case "$SCREEN_STATE"'), 'owner ticks must exit noninteractive states before any writable migration');
assert(schedulerReconcile.indexOf('if ! so_acquire_transition_lock; then') < schedulerReconcile.lastIndexOf('sr_prepare_generation "$_sr_mode" "$ACTION"'), 'boot and retry generation state must be created only after the shared transition lock');
assert(ownerArbiter.includes('_oa_locked_effective') && ownerArbiter.includes('decision_superseded'), 'owner arbiter must discard stale decisions after lock acquisition');
const ownerTerminalCall = ownerArbiter.indexOf('owner_guard_is_terminal "$_oa_prelock_guard_key"');
const ownerLockAfterTerminalCheck = ownerArbiter.indexOf('if ! so_acquire_transition_lock; then', ownerTerminalCall);
assert(ownerArbiter.includes('owner_guard_is_terminal()') && ownerTerminalCall >= 0 && ownerLockAfterTerminalCheck > ownerTerminalCall, 'terminal owner generations must stop before another transition-lock attempt');
assert(service.includes('_expected_policy') && service.includes('runtime_write_value_if_changed'), 'auto profile writes must recheck policy and skip unchanged state writes');
const applyProfileStart = service.indexOf('apply_profile_state()');
const applyProfileEnd = service.indexOf('\n}', applyProfileStart);
const applyProfileBody = service.slice(applyProfileStart, applyProfileEnd);
assert((service.match(/runtime_write_value_if_changed "\$PROFILE_AUTO_REASON_FILE"/g) || []).length === 1
  && (applyProfileBody.match(/runtime_write_value_if_changed "\$PROFILE_AUTO_REASON_FILE"/g) || []).length === 1
  && applyProfileBody.includes('profile_state_commit_active_reason "$_target" "$_reason"'), 'all profile reason writes must stay inside the shared profile transaction');
assert((service.match(/SO_TRANSITION_LOCK_MAX_ATTEMPTS=1/g) || []).length >= 2 && service.includes('export SO_TRANSITION_LOCK_MAX_ATTEMPTS SO_TRANSITION_LOCK_RETRY_SLEEP_S'), 'periodic owner and auto-profile decisions must fail fast instead of waiting with stale inputs');
assert(service.includes('STG_TERMINAL') && service.includes('_prelocked_profile') && service.includes('return 78'), 'terminal profile transitions must stop repeated service lock attempts until the key changes or is reset');
assert(service.includes('_sleep_until_worker_cycle') && service.includes('UNIFIED_SCREEN_WAKE_RECHECK_S'), 'unified worker must interrupt long Doze sleeps with a bounded read-only screen-wake recheck');
assert(profileCgi.includes('scheduler_transition_guard_lib.sh') && profileCgi.includes('reset_auto_profile_guard'), 'explicit profile requests must reset stale automatic retry state under the shared lock');
assert(profileCgi.includes('emit_profile_mutation_state()') && app.includes('function applyProfileMutationState(data)'), 'profile mutations must return and merge a compact verified state');
assert(profileCgi.includes('emit_profile_transition_state()') && profileCgi.includes('stg_load'), 'compact profile state must expose primary or fallback retry terminal state');
assert(app.includes('自动切档连续失败并已停止') && app.includes('state.profileTransition.terminal'), 'WebUI must show when automatic profile retries reached a failed terminal state');
assert(profileCgi.includes('if so_transition_lock_is_active; then') && profileCgi.includes('_health_status=deferred'), 'profile reads must expose transition-deferred health without racing the persisted health file');
const profileSchedulerLockStart = profileCgi.indexOf('acquire_profile_scheduler_lock()');
const profileSchedulerLockEnd = profileCgi.indexOf('\n}', profileSchedulerLockStart);
const profileSchedulerLockBody = profileCgi.slice(profileSchedulerLockStart, profileSchedulerLockEnd);
assert((profileCgi.match(/so_migrate_state/g) || []).length === 1 && profileSchedulerLockBody.indexOf('so_acquire_transition_lock') < profileSchedulerLockBody.indexOf('so_migrate_state'), 'profile GET must stay read-only and POST migration must run inside the scheduler lock');
const profilePostStart = profileCgi.indexOf('if [ "$REQUEST_METHOD" = "POST" ]');
const profilePostEnd = profileCgi.indexOf('elif [ "$REQUEST_METHOD" = "GET" ]', profilePostStart);
const profilePostBody = profileCgi.slice(profilePostStart, profilePostEnd);
assert(profilePostStart >= 0 && profilePostEnd > profilePostStart, 'profile POST branch is missing');
assert(profilePostBody.includes('emit_profile_mutation_state') && !profilePostBody.includes('emit_profile_state'), 'profile POST must not block terminal responses on full scheduler discovery');
assert(profilePostBody.includes('"accepted":true,"final":true') && profilePostBody.includes('"accepted":true,"final":false'), 'profile mutations must distinguish terminal completion from accepted pending work');
assert((app.match(/applyProfileMutationState\(data\)/g) || []).length >= 6, 'all profile mutation actions must merge compact state without clearing full discovery data');
const compactGetStart = profileCgi.indexOf("*'&compact=1&'*)");
const compactGetEnd = profileCgi.indexOf(';;', compactGetStart);
const compactGetBody = profileCgi.slice(compactGetStart, compactGetEnd);
assert(compactGetStart >= 0 && compactGetBody.includes('emit_profile_mutation_state'), 'profile GET must expose a compact read-only state path');
assert(compactGetBody.includes('emit_scheduler_boot_state') && compactGetBody.includes('emit_scheduler_health_state') && !compactGetBody.includes('emit_profile_state'), 'compact profile GET must refresh persisted boot and health state without full scheduler discovery');
assert((app.match(/\?compact=1/g) || []).length >= 2, 'initial and periodic profile reads must use the compact state path');
assert(app.includes('profileFullStateGeneration') && app.includes('generation !== profileFullStateGeneration'), 'stale background scheduler discovery must not overwrite a newer mutation response');
assert(app.includes('profileMutationStateRevision') && app.includes('newerMutationState') && app.includes('applyProfileMutationState(newerMutationState)'), 'full scheduler discovery must preserve a newer compact auto-profile response');
assert(app.includes('PROFILE_MUTATION_TIMEOUT_MS = 15000') && profileCgi.includes('PROFILE_REQUEST_LOCK_MAX_ATTEMPTS'), 'profile mutation timeout must cover the bounded CGI lock wait and verified write response');
const mutationApplyStart = app.indexOf('function applyProfileMutationState(data) {');
const mutationApplyEnd = app.indexOf('function renderProfileCards()', mutationApplyStart);
assert(mutationApplyStart >= 0 && mutationApplyEnd > mutationApplyStart, 'profile mutation state merger is missing');
const mutationApplySource = app.slice(mutationApplyStart, mutationApplyEnd).trim();
const mutationState = {
  currentProfile: 'balanced', manualProfile: 'balanced', profilePolicy: 'auto',
  schedOwner: 'pixel', schedEffectiveOwner: 'pixel', gameHandoffPolicy: 'fas_rs',
  autoReason: 'auto_balanced', uperfDetected: true, fasRsDetected: true,
  cpuContract: { sentinel: true },
  schedulerBoot: {
    targetMode: 'pixel', effectiveMode: 'pixel', phase: 'success', final: 'yes', ok: 'yes',
    result: 'active_pixel', reason: 'pixel_profile_verified', attempts: 1,
    rebootRequired: 'no', autoRepairUsed: 'no'
  }
};
const applyMutation = new Function('state', 'PROFILES', 'syncProfileUi', 'syncHeroDesc',
  `let latestProfileMutationState = null; let profileMutationStateRevision = 0; ${mutationApplySource}; return applyProfileMutationState;`)(
  mutationState, { balanced: {}, battery: {} }, () => {}, () => {}
);
applyMutation({
  profile: 'battery', manual_profile: 'battery', policy: 'manual', sched_owner: 'pixel',
  sched_effective_owner: 'pixel', game_handoff_policy: 'fas_rs', auto_reason: 'manual_selected'
});
assert(mutationState.currentProfile === 'battery' && mutationState.profilePolicy === 'manual', 'compact profile state must apply verified mutation fields');
assert(mutationState.uperfDetected === true && mutationState.fasRsDetected === true && mutationState.cpuContract.sentinel === true, 'compact profile state must preserve full scheduler discovery and CPU contract data');
applyMutation({ scheduler_boot: { phase: 'pending_reboot', final: 'no', attempts: 2 } });
assert(mutationState.schedulerBoot.phase === 'pending_reboot' && mutationState.schedulerBoot.attempts === 2, 'compact boot state must update returned fields');
assert(mutationState.schedulerBoot.targetMode === 'pixel' && mutationState.schedulerBoot.result === 'active_pixel', 'compact boot state must preserve omitted verified fields');
applyMutation({ scheduler_health: { status: 'deferred', reason: 'transition_in_progress', checked_epoch: '123' } });
assert(mutationState.schedulerHealth.status === 'deferred' && mutationState.schedulerHealth.reason === 'transition_in_progress', 'compact profile state must refresh persisted scheduler health');
applyMutation({ profile_transition: { key: 'profile:auto:balanced->battery', attempts: 3, terminal: 'yes', ok: 'no', result: 'failed_final' } });
assert(mutationState.profileTransition.terminal === 'yes' && mutationState.profileTransition.attempts === 3, 'compact profile state must expose the final automatic retry result');
const handoffStart = profileCgi.indexOf('if [ -n "$newhandoff" ]');
const handoffEnd = profileCgi.indexOf('\n    sbm_load_state', handoffStart);
const handoffBody = profileCgi.slice(handoffStart, handoffEnd);
assert(handoffBody.includes('acquire_profile_scheduler_lock') && handoffBody.includes('require_locked_verified_baseline') && handoffBody.includes('release_profile_scheduler_lock'), 'game handoff persistence must support both verified baselines under the shared scheduler lock');
assert(handoffBody.includes('.owner_mutation_guard') && handoffBody.includes('stg_reset') && handoffBody.includes('previous policy restored'), 'explicit game handoff changes must reset the owner terminal guard with rollback');
assert(handoffBody.includes('so_write_handoff_preference "$newhandoff" user') && handoffBody.includes('final":false'), 'game handoff must record explicit user intent and return pending when runtime reconciliation is busy');
assert(profileCgi.includes('SO_TRANSITION_LOCK_MAX_ATTEMPTS=1 SO_TRANSITION_LOCK_RETRY_SLEEP_S=0') && app.includes("data.accepted && data.final === false") && app.includes('等待调度状态同步'), 'explicit handoff reconciliation must fail fast on a busy shared lock and keep the UI pending');
const chooseCpuStart = customize.indexOf('choose_cpu_scheduling()');
const chooseCpuEnd = customize.indexOf('\n}\n', chooseCpuStart);
const chooseCpuBody = customize.slice(chooseCpuStart, chooseCpuEnd);
assert(chooseCpuBody.includes('UPERF_MODULE_ENABLED') && chooseCpuBody.includes('FAS_RS_MODULE_ENABLED') && chooseCpuBody.includes('installer_write "$GAME_HANDOFF_POLICY_FILE" fas_rs'), 'fresh UGT installs with fas-rs must enable the reversible game handoff contract');
assert(customize.includes('so_read_handoff_source') && customize.includes('so_write_handoff_preference "$_handoff_default" default'), 'upgrades must recover the fas-rs default without overriding a recorded user choice');
assert(schedulerBootLib.includes('sbm_commit_terminal_bounded') && schedulerBootLib.includes('SBM_TERMINAL_FILE'), 'scheduler terminal state must have bounded primary commits and a fallback channel');
assert(schedulerReconcile.includes('sr_publish_owner_transaction') && schedulerReconcile.includes('SR_OWNER_ROLLBACK_OK'), 'boot owner publication must be transactional and report rollback state');
assert(profileCgi.includes('scheduler_boot') && profileCgi.includes('sbm_stage_mode'), 'profile API must expose and stage boot-mode state');
assert(!ownerArbiter.includes('_oa_resp="16 40 200"'), 'owner arbiter must not duplicate CPU response triplets');
assert(!ownerArbiter.includes('command -v detect_'), 'owner arbiter must require its scheduler-detection contract');
assert((ownerArbiter.match(/detect_external_scheduler 2>\/dev\/null/g) || []).length === 1, 'owner arbiter must scan external schedulers once per tick');
assert(service.includes('display_state_read') && ownerArbiterCgi.includes('display_state_read') && customize.includes('scripts/display_state_lib.sh'), 'service, installer, and owner CGI must share the display-state contract');
assert(displayStateLib.includes('deviceidle get screen') && displayStateLib.includes('DRM enabled'), 'display-state contract must use DeviceIdle and document the DRM boundary');
assert(!/enabled\)\s+_[A-Za-z0-9_]*screen=["']?on/.test(service + ownerArbiterCgi), 'DRM enabled must never directly prove an interactive screen');
assert(schedulerDetectLib.includes('detect_external_scheduler_fresh()') && schedulerDetectLib.includes('scheduler_load_inventory()'), 'scheduler detection must separate fresh discovery from cached runtime refresh');
assert(schedulerDetectLib.includes('scheduler_fas_owner_lease_active()') && schedulerDetectLib.includes('resident_idle'), 'fas-rs detection must separate resident process state from an active game lease');
assert(profileCgi.includes('fas_rs_runtime_owner_active') && profileCgi.includes('fas_rs_runtime_target'), 'profile API must expose fas-rs residency and active lease separately');
assert(app.includes('function isFasRsResident()') && app.includes("state.fasRsRuntimeOwnerActive === 'yes'") && !app.includes("state.fasRsActive === 'yes' || state.fasRsProcessAlive === 'yes'"), 'WebUI must not treat a resident fas-rs process as active scheduler ownership');
assert(ownerArbiter.includes('cleanup_fas_started_by_transaction') && !ownerArbiter.includes('killall fas-rs'), 'owner arbiter may only clean a fas-rs process started by its own failed transaction');
assert(ownerArbiter.includes('fas_handoff_available()') && ownerArbiter.includes('GAME_SOURCE="fas_module_unavailable"'), 'owner arbiter must keep either baseline untouched when fas-rs is unavailable');
assert(ownerArbiter.includes('fas_payload_incomplete') && ownerArbiter.includes('failed_prepare_powercfg_router'), 'incomplete fas-rs payload or router preparation failure must stop before baseline mutation');
assert(ownerArbiter.includes('UPERF_START_LOCK_BOOT_ID') && ownerArbiter.includes('$UPERF_START_LOCK_DIR/boot_id'), 'UGT private start lock must bind PID/start ticks to the current boot');
assert(service.includes('detect_external_scheduler_fresh') && ownerArbiter.includes('SCHEDULER_INVENTORY_PATH'), 'service must build scheduler inventory and owner hot path must consume it');
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
assert(customize.includes('UECAP_EXTERNAL=1') && customize.includes('UECAP_DISABLED_REASON="device_external_stock"'), 'komodo installs must use the external/stock UECap policy');
assert(customize.includes('magisk_uecap_unavailable'), 'Magisk managed UECap state must be explicit');
assert(!customize.includes('uecap_unsupported_device') && !customize.includes('magisk_no_baseband'), 'retired UECap disable reasons must not remain in runtime installer logic');
assert(basebandCustomize.includes('config/baseband_devices.tsv') && basebandCustomize.includes('不要卸载 APatch Manager'), 'standalone baseband installer must use the dual-device manifest and preserve Manager upgrades');
const basebandRows = basebandManifest.split(/\r?\n/).filter((line) => line.trim() && !line.trim().startsWith('#'));
assert(basebandRows.length === 2 && basebandRows.every((line) => line.split('|').length === 7), 'standalone baseband manifest must contain exactly two seven-field rows');
assert(basebandRows.every((line) => line.split('|')[2] === 'external' && line.split('|').slice(3).every((value) => value === '')), 'standalone baseband manifest must not carry UECap payload metadata');
function listFilesRecursively(directory) {
  const result = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) result.push(...listFilesRecursively(fullPath));
    else result.push(fullPath);
  }
  return result;
}
assert(!listFilesRecursively(basebandRoot).some((entry) => entry.endsWith('.binarypb')), 'standalone baseband source must not contain UECap binarypb');
assert(!service.includes('# v4.'), 'service.sh must not contain a release changelog');
assert(!fs.existsSync(path.join(root, 'system.prop')), 'empty system.prop must not be packaged');
assert(moduleProp.includes('version=v4.5.07') && moduleProp.includes('versionCode=112'), 'release version must be v4.5.07 / 112');
for (const component of ['webui=4.5.06', 'scheduler=4.5.05', 'core=4.5.07']) {
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
assert(postMount.includes('uecap_apply_mode "$_uecap_post_mount_mode" pre_modem') && service.includes('uecap_pre_modem_receipt_is_current'), 'UECap must bind after MetaModule mount and verify the same-boot receipt before modem startup fallback');

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
