#!/system/bin/sh

SOURCE_ROOT="${1:-/sdcard/Download/Pixel9Pro-Control-TestLab/candidate/control}"
TEST_ROOT="${2:-/sdcard/Download/Pixel9Pro-Control-TestLab/runtime/owner_test_$$}"
PASS=0
FAIL=0
TOTAL=0

ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$TOTAL" "$1"; }
not_ok() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$TOTAL" "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 expected=$2 actual=$3"; fi; }
assert_file() { if [ -f "$2" ]; then ok "$1"; else not_ok "$1 missing=$2"; fi; }
assert_no_file() { if [ ! -f "$2" ]; then ok "$1"; else not_ok "$1 unexpected=$2"; fi; }
state_value() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1 | tr -d '\r'; }
file_signature() { if [ -f "$1" ]; then cksum "$1" | awk '{print $1 ":" $2}'; else printf missing; fi; }

new_fixture() {
    _t_name="$1"; _t_desired="$2"; _t_effective="$3"; _t_handoff="$4"
    FIXTURE="$TEST_ROOT/$_t_name"
    MOD="$FIXTURE/mod"
    FAS="$FIXTURE/fas"
    mkdir -p "$MOD/scripts" "$FAS/.test_runtime" || exit 2
    for _t_script in owner_arbiter.sh scheduler_owner_lib.sh scheduler_detect_lib.sh cpu_profile_lib.sh scheduler_boot_mode_lib.sh scheduler_transition_guard_lib.sh; do
        cp "$SOURCE_ROOT/scripts/$_t_script" "$MOD/scripts/" || exit 2
    done
    cat > "$MOD/scripts/cpu_profile.sh" <<'EOF'
#!/system/bin/sh
_root="${0%/*}/.."
_count=$(cat "$_root/.cpu_profile_calls" 2>/dev/null); case "$_count" in ''|*[!0-9]*) _count=0 ;; esac
printf '%s\n' $((_count + 1)) > "$_root/.cpu_profile_calls"
rm -f "$_root/../fas/.test_runtime/pixel_baseline_drift"
[ ! -f "$_root/.fail_cpu_profile" ] || exit 1
exit 0
EOF
    printf '%s\n' "$_t_desired" > "$MOD/.sched_owner_desired"
    printf '%s\n' "$_t_effective" > "$MOD/.cpu_sched_owner"
    printf '%s\n' "$_t_handoff" > "$MOD/.game_handoff_policy"
    printf 'balanced\n' > "$MOD/.current_profile"
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
    _t_focus="$1"; _t_screen="${2:-on}"
    OWNER_ARBITER_TEST_MODE=1 \
    OWNER_ARBITER_FAS_ROOT="$FAS" \
    OWNER_ARBITER_CPUFREQ_ROOT="$FAS/cpufreq" \
    OWNER_ARBITER_UCLAMP_CAP_PATH="$FAS/uclamp_cap" \
    OWNER_ARBITER_SCENE_PROFILE="$FAS/scene_games.xml" \
    OWNER_ARBITER_TEST_FOCUS_PKG="$_t_focus" \
    OWNER_ARBITER_TEST_UPERF_DETECTED=yes \
    OWNER_ARBITER_TEST_UPERF_ENABLED=yes \
    OWNER_ARBITER_TEST_FAS_DETECTED=yes \
    OWNER_ARBITER_TEST_FAS_ENABLED=yes \
    OWNER_ARBITER_TEST_THERMAL_COOLING_ACTIVE=no \
    OWNER_ARBITER_TEST_FOREGROUND_COUNTER_PATH="$FAS/.test_runtime/foreground_calls" \
    SCHEDULER_INVENTORY_PATH="$MOD/.scheduler_inventory" \
    SCHEDULER_MODULES_ROOT="$FIXTURE/modules" \
    SCHEDULER_MODULES_UPDATE_ROOT="$FIXTURE/modules_update" \
    SCHEDULER_FAS_RUNTIME_ROOT="$FAS" \
    SCHEDULER_FAS_MODE_PATH="$FIXTURE/fas_mode" \
    SCHEDULER_TEST_RUNTIME_ROOT="$FAS/.test_runtime" \
    SCHEDULER_TEST_MODE=1 \
    SO_TRANSITION_LOCK_MAX_ATTEMPTS=1 \
    STG_MAX_ATTEMPTS=3 STG_DEADLINE_S=30 \
    ARB_ENTER_DEBOUNCE_S=0 ARB_MIN_LEASE_S=0 ARB_PID_ABSENT_CONFIRM_S=0 ARB_EXIT_IDLE_AFTER_S=0 \
    ARB_CPUFREQ_RESTORE_SETTLE_S=0 \
    sh "$MOD/scripts/owner_arbiter.sh" apply-tick "$MOD" "$_t_screen"
}

mkdir -p "$TEST_ROOT" || exit 2
printf 'TAP version 13\n'

# UGT mode is observation-only even when a game matches.
new_fixture ugt_exclusive external external fas_rs
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
run_tick com.example.game
assert_eq 'UGT mode remains boot exclusive' UGT_EXCLUSIVE "$(state_value "$FAS/.arbiter_state" state)"
assert_eq 'UGT tick is explicit no-op' ugt_boot_exclusive_noop "$(state_value "$FAS/.arbiter_state" apply_result)"
assert_file 'UGT process is never hot-stopped' "$FAS/.test_runtime/uperf_alive"
assert_no_file 'UGT mode never starts fas-rs' "$FAS/.test_runtime/fas_alive"
assert_no_file 'UGT mode never applies Pixel profile' "$MOD/.cpu_profile_calls"

printf '2\n' > "$FAS/.test_runtime/uperf_count"
run_tick com.example.game
assert_eq 'owner tick never normalizes duplicate UGT instances' 2 "$(cat "$FAS/.test_runtime/uperf_count")"

# Pixel -> fas-rs lease -> Pixel remains supported.
new_fixture pixel_fas_roundtrip pixel pixel fas_rs
run_tick com.example.game
assert_eq 'Pixel game enters fas-rs lease' FAS_LEASED_GAME "$(state_value "$FAS/.arbiter_state" state)"
assert_eq 'fas-rs lease publishes external effective owner' external "$(cat "$MOD/.cpu_sched_owner")"
assert_file 'fas-rs process starts for matched game' "$FAS/.test_runtime/fas_alive"
assert_no_file 'UGT stays absent in Pixel mode' "$FAS/.test_runtime/uperf_alive"
assert_eq 'fas-rs lease opens full cap' 1024 "$(cat "$FAS/uclamp_cap")"
run_tick com.android.launcher
assert_eq 'game exit restores Pixel owner' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'game exit stops fas-rs' "$FAS/.test_runtime/fas_alive"
assert_eq 'game exit restores Pixel cap' 0 "$(cat "$FAS/uclamp_cap")"

# Handoff disabled leaves the Pixel baseline untouched.
new_fixture handoff_off pixel pixel off
run_tick com.example.game
assert_eq 'handoff off keeps Pixel state' PIXEL_NORMAL "$(state_value "$FAS/.arbiter_state" state)"
assert_eq 'handoff off keeps Pixel owner' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'handoff off does not start fas-rs' "$FAS/.test_runtime/fas_alive"

# A stable Pixel drift is delegated to the low-frequency health worker and is
# never repaired by the 5-second owner tick.
new_fixture pixel_drift pixel pixel fas_rs
touch "$FAS/.test_runtime/pixel_baseline_drift"
run_tick com.android.launcher >/dev/null 2>&1
assert_no_file 'owner tick does not replay profile for stable Pixel drift' "$MOD/.cpu_profile_calls"
assert_eq 'Pixel drift is reported to health worker' profile_drift_health_required "$(state_value "$FAS/.arbiter_state" apply_result)"
run_tick com.android.launcher >/dev/null 2>&1
assert_no_file 'repeated owner tick remains mutation-free' "$MOD/.cpu_profile_calls"

# A failed fas-rs transition gets three attempts in the same generation, then
# latches and stops all further mutation attempts.
new_fixture fas_failure pixel pixel fas_rs
touch "$FAS/.test_runtime/fail_start_fas"
run_tick com.example.game >/dev/null 2>&1 || true
run_tick com.example.game >/dev/null 2>&1 || true
run_tick com.example.game >/dev/null 2>&1 || true
assert_eq 'owner retry guard records three attempts' 3 "$(state_value "$FAS/.owner_mutation_guard" attempts)"
_t_guard_sig=$(file_signature "$FAS/.owner_mutation_guard")
run_tick com.example.game >/dev/null 2>&1 || true
assert_eq 'latched owner failure does not reopen generation' "$_t_guard_sig" "$(file_signature "$FAS/.owner_mutation_guard")"
case "$(state_value "$FAS/.arbiter_state" apply_result)" in
    transition_latched:*|*_latched) ok 'latched owner result is explicit' ;;
    *) not_ok 'latched owner result is explicit' ;;
esac

# Noninteractive ticks exit before discovery, foreground IPC, locks, or writes.
new_fixture noninteractive pixel pixel fas_rs
run_tick com.example.game off
run_tick com.example.game doze
run_tick com.example.game unknown
assert_no_file 'noninteractive ticks skip foreground detection' "$FAS/.test_runtime/foreground_calls"
assert_no_file 'noninteractive ticks skip CPU mutation' "$MOD/.cpu_profile_calls"
assert_no_file 'noninteractive ticks do not create arbiter state' "$FAS/.arbiter_state"

# Live transition lock prevents a concurrent mutation.
new_fixture busy_transition pixel external off
mkdir -p "$FAS/.owner_transition.lock"
printf '%s\n' "$$" > "$FAS/.owner_transition.lock/pid"
_t_parent_start=$(sed 's/^.*) //' "/proc/$$/stat" | awk '{print $20}')
printf '%s\n' "$_t_parent_start" > "$FAS/.owner_transition.lock/start_ticks"
run_tick com.android.launcher >/dev/null 2>&1
assert_eq 'live transition lock returns busy' 75 "$?"
assert_no_file 'busy transition prevents profile mutation' "$MOD/.cpu_profile_calls"

printf '1..%s\n' "$TOTAL"
printf '# pass=%s fail=%s root=%s\n' "$PASS" "$FAIL" "$TEST_ROOT"
[ "$FAIL" -eq 0 ]
