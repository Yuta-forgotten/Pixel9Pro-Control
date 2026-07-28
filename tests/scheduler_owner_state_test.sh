#!/system/bin/sh

SOURCE_ROOT="${1:-/sdcard/Download/Pixel9Pro-Control-TestLab/candidate/control}"
TEST_ROOT="${2:-/sdcard/Download/Pixel9Pro-Control-TestLab/runtime/owner_test_$$}"
PASS=0
FAIL=0
TOTAL=0

ok() {
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    printf 'ok %s - %s\n' "$TOTAL" "$1"
}

not_ok() {
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    printf 'not ok %s - %s\n' "$TOTAL" "$1"
}

assert_eq() {
    _t_name="$1"
    _t_expected="$2"
    _t_actual="$3"
    if [ "$_t_expected" = "$_t_actual" ]; then
        ok "$_t_name"
    else
        not_ok "$_t_name expected=$_t_expected actual=$_t_actual"
    fi
}

assert_file() {
    _t_name="$1"
    _t_file="$2"
    if [ -f "$_t_file" ]; then ok "$_t_name"; else not_ok "$_t_name missing=$_t_file"; fi
}

assert_no_file() {
    _t_name="$1"
    _t_file="$2"
    if [ ! -f "$_t_file" ]; then ok "$_t_name"; else not_ok "$_t_name unexpected=$_t_file"; fi
}

state_value() {
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1 | tr -d '\r'
}

file_signature() {
    if [ -f "$1" ]; then cksum "$1" | awk '{print $1 ":" $2}'; else printf 'missing'; fi
}

new_fixture() {
    _t_name="$1"
    _t_desired="$2"
    _t_effective="$3"
    _t_handoff="$4"
    FIXTURE="$TEST_ROOT/$_t_name"
    MOD="$FIXTURE/mod"
    FAS="$FIXTURE/fas"
    mkdir -p "$MOD/scripts" "$FAS/.test_runtime" || exit 2
    cp "$SOURCE_ROOT/scripts/owner_arbiter.sh" "$MOD/scripts/owner_arbiter.sh" || exit 2
    cp "$SOURCE_ROOT/scripts/scheduler_owner_lib.sh" "$MOD/scripts/scheduler_owner_lib.sh" || exit 2
    cp "$SOURCE_ROOT/scripts/scheduler_detect_lib.sh" "$MOD/scripts/scheduler_detect_lib.sh" || exit 2
    cp "$SOURCE_ROOT/scripts/cpu_profile_lib.sh" "$MOD/scripts/cpu_profile_lib.sh" || exit 2
    printf '%s\n' \
        '#!/system/bin/sh' \
        '_root="${0%/*}/.."' \
        '_count=$(cat "$_root/.cpu_profile_calls" 2>/dev/null)' \
        'case "$_count" in ""|*[!0-9]*) _count=0 ;; esac' \
        'printf "%s\n" $((_count + 1)) > "$_root/.cpu_profile_calls"' \
        'rm -f "$_root/../fas/.test_runtime/pixel_baseline_drift"' \
        '[ ! -f "$_root/.fail_cpu_profile" ] || exit 1' \
        'exit 0' > "$MOD/scripts/cpu_profile.sh"
    printf '%s\n' "$_t_desired" > "$MOD/.sched_owner_desired"
    printf '%s\n' "$_t_effective" > "$MOD/.cpu_sched_owner"
    printf '%s\n' "$_t_handoff" > "$MOD/.game_handoff_policy"
    printf '%s\n' 'balanced' > "$MOD/.current_profile"
    printf '0\n' > "$FAS/uclamp_cap"
    cat > "$MOD/.scheduler_inventory" <<'EOF'
schema=1
uperf_detected=no
uperf_id=
uperf_name=
uperf_path=
uperf_source=
fas_detected=no
fas_id=
fas_name=
fas_path=
fas_source=
EOF
    cat > "$FAS/games.toml" <<'EOF'
[config]
scene_game_list = false
exclude_list = []

[game_list]
"com.example.game" = {}
EOF
}

run_tick() {
    _t_focus="$1"
    _t_screen="${2:-on}"
    OWNER_ARBITER_TEST_MODE=1 \
    OWNER_ARBITER_FAS_ROOT="$FAS" \
    OWNER_ARBITER_CPUFREQ_ROOT="$FAS/cpufreq" \
    OWNER_ARBITER_UCLAMP_CAP_PATH="${OWNER_ARBITER_UCLAMP_CAP_PATH:-$FAS/uclamp_cap}" \
    OWNER_ARBITER_POWERCFG_ENTRY="$FAS/powercfg.sh" \
    OWNER_ARBITER_SCENE_PROFILE="$FAS/scene_games.xml" \
    OWNER_ARBITER_TEST_FOCUS_PKG="$_t_focus" \
    OWNER_ARBITER_TEST_UPERF_ENABLED="${OWNER_ARBITER_TEST_UPERF_ENABLED:-yes}" \
    OWNER_ARBITER_TEST_THERMAL_COOLING_ACTIVE="${OWNER_ARBITER_TEST_THERMAL_COOLING_ACTIVE:-no}" \
    OWNER_ARBITER_TEST_FOREGROUND_COUNTER_PATH="$FAS/.test_runtime/foreground_calls" \
    SCHEDULER_INVENTORY_PATH="$MOD/.scheduler_inventory" \
    SCHEDULER_MODULES_ROOT="$FIXTURE/modules" \
    SCHEDULER_MODULES_UPDATE_ROOT="$FIXTURE/modules_update" \
    SCHEDULER_FAS_RUNTIME_ROOT="$FAS" \
    SCHEDULER_FAS_MODE_PATH="$FIXTURE/fas_mode" \
    SCHEDULER_TEST_RUNTIME_ROOT="$FAS/.test_runtime" \
    SCHEDULER_TEST_MODE=1 \
    SO_TRANSITION_LOCK_MAX_ATTEMPTS="${SO_TRANSITION_LOCK_MAX_ATTEMPTS:-1}" \
    ARB_ENTER_DEBOUNCE_S=0 \
    ARB_MIN_LEASE_S=0 \
    ARB_PID_ABSENT_CONFIRM_S=0 \
    ARB_EXIT_IDLE_AFTER_S=0 \
    ARB_CPUFREQ_RESTORE_SETTLE_S=0 \
    sh "$MOD/scripts/owner_arbiter.sh" apply-tick "$MOD" "$_t_screen"
}

mkdir -p "$TEST_ROOT" || exit 2
printf 'TAP version 13\n'

# Migration: the last explicit WebUI owner action wins over legacy effective.
MIG="$TEST_ROOT/migration"
mkdir -p "$MIG/mod" "$MIG/fas"
printf 'external\n' > "$MIG/mod/.cpu_sched_owner"
printf '%s\n' \
    '100,manual,external,battery,external_scheduler,0,0,0,0,na' \
    '101,manual,pixel,battery,pixel_scheduler,0,0,0,0,na' > "$MIG/mod/.profile_history"
printf '1\n' > "$MIG/fas/.arbiter_apply"
. "$SOURCE_ROOT/scripts/scheduler_owner_lib.sh"
scheduler_owner_init "$MIG/mod" "$MIG/fas"
so_migrate_state
assert_eq 'migration restores explicit Pixel intent' pixel "$(so_read_desired_owner)"
assert_eq 'migration preserves enabled fas-rs handoff' fas_rs "$(so_read_handoff_policy)"

# External UGT -> Pixel baseline.
new_fixture pixel_from_ugt pixel external fas_rs
printf '1024\n' > "$FAS/uclamp_cap"
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
run_tick com.android.launcher
assert_eq 'Pixel desired becomes effective' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'Pixel stops UGT' "$FAS/.test_runtime/uperf_alive"
assert_no_file 'Pixel stops fas-rs' "$FAS/.test_runtime/fas_alive"
assert_eq 'Pixel apply result verified' applied_pixel_idle "$(state_value "$FAS/.arbiter_state" apply_result)"
assert_eq 'Pixel balanced baseline clamps daily boost requests' 0 "$(cat "$FAS/uclamp_cap")"
assert_eq 'Pixel cap transition is verified' yes "$(state_value "$FAS/.arbiter_state" uclamp_cap_verified)"

# Pixel -> External UGT.
new_fixture external_from_pixel external pixel fas_rs
printf '1024\n' > "$FAS/uclamp_cap"
run_tick com.android.launcher
assert_eq 'External desired becomes effective' external "$(cat "$MOD/.cpu_sched_owner")"
assert_file 'External starts one UGT marker' "$FAS/.test_runtime/uperf_alive"
assert_eq 'External owner state is UGT' external:uperf "$(cat "$FAS/.owner_state")"
assert_eq 'UGT daily baseline clamps boost requests' 0 "$(cat "$FAS/uclamp_cap")"

# Direct-boot storage deferral still restores the External daily cap even when
# UGT cannot start until credential-encrypted storage is ready.
new_fixture external_deferred external pixel fas_rs
printf '1024\n' > "$FAS/uclamp_cap"
printf '1\n' > "$FAS/.test_runtime/defer_start_uperf"
run_tick com.android.launcher
assert_eq 'deferred UGT keeps External effective' external "$(cat "$MOD/.cpu_sched_owner")"
assert_eq 'deferred UGT restores daily cap' 0 "$(cat "$FAS/uclamp_cap")"
assert_eq 'deferred UGT result is explicit' deferred_start_uperf_storage_locked "$(state_value "$FAS/.arbiter_state" apply_result)"

# Pixel -> fas-rs game lease -> Pixel.
new_fixture pixel_fas_roundtrip pixel pixel fas_rs
printf 'auto\n' > "$MOD/.profile_policy"
run_tick com.example.game
assert_eq 'Pixel game enters fas-rs lease' FAS_LEASED_GAME "$(state_value "$FAS/.arbiter_state" state)"
assert_eq 'fas-rs lease uses external effective owner' external "$(cat "$MOD/.cpu_sched_owner")"
assert_file 'fas-rs starts for Pixel game' "$FAS/.test_runtime/fas_alive"
assert_no_file 'UGT stays stopped during Pixel game' "$FAS/.test_runtime/uperf_alive"
assert_eq 'Pixel game lease restores full boost cap' 1024 "$(cat "$FAS/uclamp_cap")"
assert_eq 'Pixel game cap is verified' yes "$(state_value "$FAS/.arbiter_state" uclamp_cap_verified)"
run_tick com.android.launcher off
assert_eq 'screen-off preserves active fas-rs lease' FAS_LEASED_GAME "$(state_value "$FAS/.arbiter_state" state)"
assert_file 'screen-off keeps fas-rs process' "$FAS/.test_runtime/fas_alive"
run_tick com.android.launcher
assert_eq 'Pixel game exit restores Pixel' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'fas-rs stops after Pixel game exit' "$FAS/.test_runtime/fas_alive"
assert_eq 'owner transitions preserve auto policy' auto "$(cat "$MOD/.profile_policy")"
assert_eq 'Pixel game exit restores daily cap' 0 "$(cat "$FAS/uclamp_cap")"

# External UGT -> fas-rs game lease -> UGT.
new_fixture external_fas_roundtrip external external fas_rs
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
printf '1\n' > "$FAS/.test_runtime/require_cap_before_start_fas"
run_tick com.example.game
assert_no_file 'UGT stops during External game lease' "$FAS/.test_runtime/uperf_alive"
assert_file 'fas-rs starts during External game lease' "$FAS/.test_runtime/fas_alive"
assert_eq 'External game cap is ready before fas-rs starts' 1024 "$(cat "$FAS/.test_runtime/cap_at_fas_start")"
assert_eq 'External game lease restores full boost cap' 1024 "$(cat "$FAS/uclamp_cap")"
run_tick com.android.launcher
assert_eq 'External game exit restores External' external "$(cat "$MOD/.cpu_sched_owner")"
assert_file 'External game exit restores UGT' "$FAS/.test_runtime/uperf_alive"
assert_eq 'External game exit restores daily cap' 0 "$(cat "$FAS/uclamp_cap")"

# Repeated External reconciliation normalizes duplicate UGT roots to one.
new_fixture duplicate_ugt external external fas_rs
printf '2\n' > "$FAS/.test_runtime/uperf_count"
run_tick com.android.launcher
assert_eq 'duplicate UGT roots normalize to one' 1 "$(cat "$FAS/.test_runtime/uperf_count")"
assert_eq 'duplicate UGT normalization is reported' applied_uperf_idle_normalized "$(state_value "$FAS/.arbiter_state" apply_result)"
run_tick com.android.launcher
assert_eq 'repeated External reconcile stays single-instance' 1 "$(cat "$FAS/.test_runtime/uperf_count")"

# Handoff disabled: matched game stays on the desired baseline.
new_fixture handoff_off pixel pixel off
run_tick com.example.game
assert_eq 'handoff off keeps normal state' PIXEL_NORMAL "$(state_value "$FAS/.arbiter_state" state)"
assert_eq 'handoff off keeps Pixel effective' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'handoff off does not start fas-rs' "$FAS/.test_runtime/fas_alive"
assert_eq 'handoff off keeps daily cap' 0 "$(cat "$FAS/uclamp_cap")"

# fas-rs start failure rolls back to the desired Pixel baseline.
new_fixture fas_failure pixel pixel fas_rs
printf '1\n' > "$FAS/.test_runtime/fail_start_fas"
if run_tick com.example.game; then
    not_ok 'fas-rs failure returns nonzero'
else
    ok 'fas-rs failure returns nonzero'
fi
assert_eq 'fas-rs failure rolls back Pixel effective' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_eq 'fas-rs failure records Pixel fallback' failed_start_fas_rs_fallback_pixel "$(state_value "$FAS/.arbiter_state" apply_result)"
assert_no_file 'fas-rs failure leaves no fas process' "$FAS/.test_runtime/fas_alive"
assert_eq 'fas-rs start failure restores Pixel daily cap' 0 "$(cat "$FAS/uclamp_cap")"

# A game lease is invalid if cap=1024 cannot be written and verified. Roll back
# to the desired Pixel baseline instead of leaving a partial fas-rs takeover.
new_fixture fas_uclamp_failure pixel pixel fas_rs
rm -f "$FAS/uclamp_cap"
mkdir -p "$FAS/uclamp_cap"
OWNER_ARBITER_UCLAMP_CAP_PATH="$FAS/uclamp_cap" run_tick com.example.game
_cap_failure_rc=$?
if [ "$_cap_failure_rc" -ne 0 ]; then
    ok 'fas-rs cap failure returns nonzero'
else
    not_ok 'fas-rs cap failure returns nonzero'
fi
assert_eq 'fas-rs cap failure rolls back Pixel effective' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'fas-rs cap failure stops partial fas process' "$FAS/.test_runtime/fas_alive"
assert_eq 'fas-rs cap failure records incomplete fallback' failed_verify_fas_rs_game_uclamp_cap_fallback_incomplete "$(state_value "$FAS/.arbiter_state" apply_result)"
assert_eq 'fas-rs cap failure remains unverified' no "$(state_value "$FAS/.arbiter_state" uclamp_cap_verified)"

# UGT must not start on top of a stale Pixel/battery cpuset. If the required
# default-profile preparation fails, keep Pixel effective and expose that the
# fallback could not reapply the same broken profile path.
new_fixture external_default_failure external pixel off
touch "$MOD/.fail_cpu_profile"
run_tick com.android.launcher
_default_failure_rc=$?
if [ "$_default_failure_rc" -ne 0 ]; then ok 'UGT baseline preparation failure returns nonzero'; else not_ok 'UGT baseline preparation failure returns nonzero'; fi
assert_eq 'UGT preparation failure keeps Pixel effective' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'UGT preparation failure does not start UGT' "$FAS/.test_runtime/uperf_alive"
assert_eq 'UGT preparation failure reports incomplete fallback' failed_prepare_uperf_default_profile_fallback_pixel_incomplete "$(state_value "$FAS/.arbiter_state" apply_result)"

# ThermalHAL cooling blocks cpufreq repair without blocking the owner lease.
new_fixture thermal_gate pixel pixel fas_rs
mkdir -p "$FAS/cpufreq/policy0"
printf 'powersave\n' > "$FAS/cpufreq/policy0/scaling_governor"
printf '300000\n' > "$FAS/cpufreq/policy0/scaling_min_freq"
printf '300000\n' > "$FAS/cpufreq/policy0/scaling_max_freq"
printf '300000\n' > "$FAS/cpufreq/policy0/cpuinfo_min_freq"
printf '1950000\n' > "$FAS/cpufreq/policy0/cpuinfo_max_freq"
printf 'powersave sched_pixel\n' > "$FAS/cpufreq/policy0/scaling_available_governors"
OWNER_ARBITER_TEST_THERMAL_COOLING_ACTIVE=yes run_tick com.example.game
assert_eq 'ThermalHAL gate keeps fas-rs lease active' FAS_LEASED_GAME "$(state_value "$FAS/.arbiter_state" state)"
assert_eq 'ThermalHAL gate is recorded' yes "$(state_value "$FAS/.arbiter_state" cpufreq_thermal_cooling_active)"
assert_eq 'ThermalHAL gate skips cpufreq restore' yes "$(state_value "$FAS/.arbiter_state" cpufreq_restore_skipped)"
assert_eq 'ThermalHAL gate leaves governor untouched' powersave "$(cat "$FAS/cpufreq/policy0/scaling_governor")"

# A stale transition lock is reclaimed; it cannot permanently block owner repair.
new_fixture stale_transition_lock pixel external off
mkdir -p "$FAS/.owner_transition.lock"
printf '999999\n' > "$FAS/.owner_transition.lock/pid"
printf '0\n' > "$FAS/.owner_transition.lock/start_ticks"
run_tick com.android.launcher
assert_eq 'stale transition lock is recovered' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'stale transition lock directory is released' "$FAS/.owner_transition.lock/pid"

# External without an enabled UGT stays external-none and never falls to Pixel.
new_fixture external_none external pixel off
OWNER_ARBITER_TEST_UPERF_ENABLED=no run_tick com.android.launcher
assert_eq 'external-none preserves External effective' external "$(cat "$MOD/.cpu_sched_owner")"
assert_eq 'external-none reports no scheduler' external:none "$(cat "$FAS/.owner_state")"
assert_no_file 'external-none does not start UGT' "$FAS/.test_runtime/uperf_alive"

# Stable Pixel ticks are observations only: no profile replay, state rewrite,
# or history append. A single injected drift is repaired once.
new_fixture stable_pixel pixel pixel off
run_tick com.android.launcher
_stable_state_sig=$(file_signature "$FAS/.arbiter_state")
_stable_history_sig=$(file_signature "$FAS/.arbiter_history")
_t_i=0
while [ "$_t_i" -lt 10 ]; do
    run_tick com.android.launcher || not_ok 'stable Pixel tick succeeds'
    _t_i=$((_t_i + 1))
done
assert_no_file 'stable Pixel does not replay cpu_profile' "$MOD/.cpu_profile_calls"
assert_eq 'stable Pixel preserves arbiter state content' "$_stable_state_sig" "$(file_signature "$FAS/.arbiter_state")"
assert_eq 'stable Pixel preserves arbiter history content' "$_stable_history_sig" "$(file_signature "$FAS/.arbiter_history")"

touch "$FAS/.test_runtime/pixel_baseline_drift"
run_tick com.android.launcher
assert_eq 'one Pixel drift triggers one profile repair' 1 "$(cat "$MOD/.cpu_profile_calls")"
_drift_history_sig=$(file_signature "$FAS/.arbiter_history")
run_tick com.android.launcher
assert_eq 'repaired Pixel baseline stays no-op' 1 "$(cat "$MOD/.cpu_profile_calls")"
assert_eq 'post-repair stable tick does not append history' "$_drift_history_sig" "$(file_signature "$FAS/.arbiter_history")"

# Noninteractive states must exit before scheduler discovery, foreground IPC,
# transition locking, or CPU mutation.
new_fixture noninteractive pixel pixel fas_rs
run_tick com.example.game off
run_tick com.example.game doze
run_tick com.example.game unknown
assert_no_file 'noninteractive ticks skip foreground detection' "$FAS/.test_runtime/foreground_calls"
assert_no_file 'noninteractive ticks skip cpu_profile mutation' "$MOD/.cpu_profile_calls"
assert_no_file 'noninteractive ticks do not create arbiter state' "$FAS/.arbiter_state"
assert_no_file 'noninteractive ticks do not append arbiter history' "$FAS/.arbiter_history"

# A fully reconciled External baseline is also a stable observation.
new_fixture stable_external external external off
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
printf 'external:uperf\n' > "$FAS/.owner_state"
run_tick com.android.launcher
_external_state_sig=$(file_signature "$FAS/.arbiter_state")
_external_history_sig=$(file_signature "$FAS/.arbiter_history")
run_tick com.android.launcher
assert_no_file 'stable External does not replay cpu_profile' "$MOD/.cpu_profile_calls"
assert_eq 'stable External preserves arbiter state' "$_external_state_sig" "$(file_signature "$FAS/.arbiter_state")"
assert_eq 'stable External preserves arbiter history' "$_external_history_sig" "$(file_signature "$FAS/.arbiter_history")"

# A live transition lock blocks mutation; stale-lock recovery is covered above.
new_fixture busy_transition_lock pixel external off
mkdir -p "$FAS/.owner_transition.lock"
printf '%s\n' "$$" > "$FAS/.owner_transition.lock/pid"
_t_parent_start=$(sed 's/^.*) //' "/proc/$$/stat" | awk '{print $20}')
printf '%s\n' "$_t_parent_start" > "$FAS/.owner_transition.lock/start_ticks"
if run_tick com.android.launcher; then _t_busy_rc=0; else _t_busy_rc=$?; fi
assert_eq 'live transition lock returns busy' 75 "$_t_busy_rc"
assert_no_file 'busy transition lock prevents profile mutation' "$MOD/.cpu_profile_calls"

printf '1..%s\n' "$TOTAL"
printf '# pass=%s fail=%s root=%s\n' "$PASS" "$FAIL" "$TEST_ROOT"
[ "$FAIL" -eq 0 ]
