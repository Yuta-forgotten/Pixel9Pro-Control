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
assert_dir() { if [ -d "$2" ]; then ok "$1"; else not_ok "$1 missing=$2"; fi; }
assert_no_dir() { if [ ! -d "$2" ]; then ok "$1"; else not_ok "$1 unexpected=$2"; fi; }
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
    printf 'boot-current\n' > "$FIXTURE/boot_id"
    _t_boot_mode=pixel
    [ "$_t_desired" = "external" ] && _t_boot_mode=ugt
    cat > "$MOD/.scheduler_boot_state" <<EOF
transition_id=test:$_t_name
target_mode=$_t_boot_mode
effective_mode=$_t_boot_mode
phase=success
final=yes
ok=yes
auto_repair_used=no
reboot_required=no
EOF
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
    run_tick_action apply-tick "$1" "${2:-on}"
}

run_worker_tick() {
    run_tick_action tick "$1" "${2:-on}"
}

run_tick_action() {
    _t_action="$1"; _t_focus="$2"; _t_screen="${3:-on}"
    OWNER_ARBITER_TEST_MODE=1 \
    OWNER_ARBITER_FAS_ROOT="$FAS" \
    OWNER_ARBITER_CPUFREQ_ROOT="$FAS/cpufreq" \
    OWNER_ARBITER_UCLAMP_CAP_PATH="$FAS/uclamp_cap" \
    OWNER_ARBITER_SCENE_PROFILE="$FAS/scene_games.xml" \
    OWNER_ARBITER_TEST_FOCUS_PKG="$_t_focus" \
    OWNER_ARBITER_TEST_UPERF_DETECTED="${TEST_UPERF_DETECTED:-yes}" \
    OWNER_ARBITER_TEST_UPERF_ENABLED="${TEST_UPERF_ENABLED:-yes}" \
    OWNER_ARBITER_TEST_FAS_DETECTED="${TEST_FAS_DETECTED:-yes}" \
    OWNER_ARBITER_TEST_FAS_ENABLED="${TEST_FAS_ENABLED:-yes}" \
    OWNER_ARBITER_TEST_THERMAL_COOLING_ACTIVE=no \
    OWNER_ARBITER_TEST_FOREGROUND_COUNTER_PATH="$FAS/.test_runtime/foreground_calls" \
    SCHEDULER_INVENTORY_PATH="$MOD/.scheduler_inventory" \
    SCHEDULER_MODULES_ROOT="$FIXTURE/modules" \
    SCHEDULER_MODULES_UPDATE_ROOT="$FIXTURE/modules_update" \
    SCHEDULER_FAS_RUNTIME_ROOT="$FAS" \
    SCHEDULER_FAS_MODE_PATH="$FIXTURE/fas_mode" \
    SCHEDULER_TEST_RUNTIME_ROOT="$FAS/.test_runtime" \
    SCHEDULER_TEST_MODE=1 \
    SO_BOOT_ID_PATH="$FIXTURE/boot_id" \
    SO_TRANSITION_LOCK_MAX_ATTEMPTS="${TEST_SO_TRANSITION_LOCK_MAX_ATTEMPTS:-1}" \
    SO_TRANSITION_LOCK_RETRY_SLEEP_S="${TEST_SO_TRANSITION_LOCK_RETRY_SLEEP_S:-0}" \
    SO_TRANSITION_LOCK_INIT_GRACE_S="${TEST_SO_TRANSITION_LOCK_INIT_GRACE_S:-5}" \
    STG_MAX_ATTEMPTS=3 STG_DEADLINE_S=30 \
    ARB_ENTER_DEBOUNCE_S=0 ARB_MIN_LEASE_S=0 ARB_PID_ABSENT_CONFIRM_S=0 ARB_EXIT_IDLE_AFTER_S=0 \
    ARB_CPUFREQ_RESTORE_SETTLE_S=0 \
    sh "$MOD/scripts/owner_arbiter.sh" "$_t_action" "$MOD" "$_t_screen"
}

mkdir -p "$TEST_ROOT" || exit 2
printf 'TAP version 13\n'

# UGT daily baseline -> fas-rs game lease -> the same UGT baseline.
new_fixture ugt_fas_roundtrip external external fas_rs
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
printf '1\n' > "$FAS/.test_runtime/uperf_count"
printf 'external:uperf:baseline\n' > "$FAS/.owner_state"
printf '1\n' > "$FAS/.test_runtime/require_cap_before_start_fas"
run_tick com.example.game
assert_eq 'UGT game enters fas-rs lease' FAS_LEASED_GAME "$(state_value "$FAS/.arbiter_state" state)"
assert_eq 'UGT lease preserves external effective owner' external "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'UGT process stops before fas-rs lease' "$FAS/.test_runtime/uperf_alive"
assert_file 'fas-rs starts for UGT game lease' "$FAS/.test_runtime/fas_alive"
assert_eq 'UGT game cap is ready before fas-rs starts' 1024 "$(cat "$FAS/.test_runtime/cap_at_fas_start")"
assert_eq 'UGT game lease opens full cap' 1024 "$(cat "$FAS/uclamp_cap")"
assert_eq 'UGT baseline owner is retained in state' external "$(state_value "$FAS/.arbiter_state" baseline_owner)"
assert_no_file 'UGT handoff never applies a Pixel profile' "$MOD/.cpu_profile_calls"
run_tick com.android.launcher
assert_eq 'UGT game exit restores external owner' external "$(cat "$MOD/.cpu_sched_owner")"
assert_file 'UGT game exit restores one UGT process' "$FAS/.test_runtime/uperf_alive"
assert_eq 'UGT game exit restores one UGT root' 1 "$(cat "$FAS/.test_runtime/uperf_count")"
assert_no_file 'UGT game exit stops the exact fas-rs lease process' "$FAS/.test_runtime/fas_alive"
assert_eq 'UGT game exit restores pre-lease cap' 0 "$(cat "$FAS/uclamp_cap")"
assert_eq 'UGT game exit restores baseline owner marker' external:uperf "$(cat "$FAS/.owner_state")"

# A duplicate UGT baseline is a health issue, not something the game worker
# normalizes while no lease transition is active.
printf '2\n' > "$FAS/.test_runtime/uperf_count"
run_tick com.example.game
assert_eq 'owner tick never normalizes duplicate UGT instances' 2 "$(cat "$FAS/.test_runtime/uperf_count")"

# Handoff disabled leaves the UGT daily baseline untouched.
new_fixture ugt_handoff_off external external off
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
printf '1\n' > "$FAS/.test_runtime/uperf_count"
printf 'external:uperf:baseline\n' > "$FAS/.owner_state"
run_tick com.example.game
assert_eq 'UGT handoff off keeps baseline state' BASELINE_NORMAL "$(state_value "$FAS/.arbiter_state" state)"
assert_file 'UGT handoff off keeps UGT running' "$FAS/.test_runtime/uperf_alive"
assert_no_file 'UGT handoff off does not start fas-rs' "$FAS/.test_runtime/fas_alive"

# A stale fas_rs preference must not stop either daily baseline after the
# module is disabled or removed.
new_fixture ugt_fas_unavailable external external fas_rs
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
printf '1\n' > "$FAS/.test_runtime/uperf_count"
printf 'external:uperf:baseline\n' > "$FAS/.owner_state"
TEST_FAS_ENABLED=no run_tick com.example.game
assert_eq 'unavailable fas-rs keeps UGT baseline state' BASELINE_NORMAL "$(state_value "$FAS/.arbiter_state" state)"
assert_file 'unavailable fas-rs never stops UGT' "$FAS/.test_runtime/uperf_alive"
assert_no_file 'unavailable fas-rs never starts a lease' "$FAS/.test_runtime/fas_alive"
assert_eq 'unavailable fas-rs preserves UGT cap' 0 "$(cat "$FAS/uclamp_cap")"

new_fixture pixel_fas_unavailable pixel pixel fas_rs
TEST_FAS_ENABLED=no run_tick com.example.game
assert_eq 'unavailable fas-rs keeps Pixel baseline state' BASELINE_NORMAL "$(state_value "$FAS/.arbiter_state" state)"
assert_eq 'unavailable fas-rs keeps Pixel owner' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'unavailable fas-rs never starts from Pixel' "$FAS/.test_runtime/fas_alive"
assert_no_file 'unavailable fas-rs never replays Pixel profile' "$MOD/.cpu_profile_calls"

# An enabled module with an incomplete handoff payload is also unavailable.
# Neither daily baseline may be stopped or rewritten in that state.
new_fixture ugt_fas_payload_incomplete external external fas_rs
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
printf '1\n' > "$FAS/.test_runtime/uperf_count"
printf 'external:uperf:baseline\n' > "$FAS/.owner_state"
touch "$FAS/.test_runtime/fas_payload_incomplete"
run_tick com.example.game
assert_file 'incomplete fas-rs payload keeps UGT running' "$FAS/.test_runtime/uperf_alive"
assert_no_file 'incomplete fas-rs payload never starts a UGT lease' "$FAS/.test_runtime/fas_alive"
assert_eq 'incomplete fas-rs payload preserves UGT cap' 0 "$(cat "$FAS/uclamp_cap")"

new_fixture pixel_fas_payload_incomplete pixel pixel fas_rs
touch "$FAS/.test_runtime/fas_payload_incomplete"
run_tick com.example.game
assert_eq 'incomplete fas-rs payload keeps Pixel owner' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'incomplete fas-rs payload never starts from Pixel' "$FAS/.test_runtime/fas_alive"
assert_no_file 'incomplete fas-rs payload never replays Pixel profile' "$MOD/.cpu_profile_calls"

# Entry failures restore the same UGT baseline and never leave a partial lease.
new_fixture ugt_stop_failure external external fas_rs
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
printf '1\n' > "$FAS/.test_runtime/uperf_count"
printf 'external:uperf:baseline\n' > "$FAS/.owner_state"
touch "$FAS/.test_runtime/fail_stop_uperf"
run_tick com.example.game >/dev/null 2>&1 || true
assert_file 'UGT stop failure leaves UGT running' "$FAS/.test_runtime/uperf_alive"
assert_no_file 'UGT stop failure never starts fas-rs' "$FAS/.test_runtime/fas_alive"
assert_eq 'UGT stop failure remains external' external "$(cat "$MOD/.cpu_sched_owner")"

new_fixture ugt_router_failure external external fas_rs
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
printf '1\n' > "$FAS/.test_runtime/uperf_count"
printf 'external:uperf:baseline\n' > "$FAS/.owner_state"
touch "$FAS/.test_runtime/fail_powercfg_router"
run_tick com.example.game >/dev/null 2>&1 || true
assert_file 'powercfg router failure leaves UGT running' "$FAS/.test_runtime/uperf_alive"
assert_no_file 'powercfg router failure occurs before fas-rs starts' "$FAS/.test_runtime/fas_alive"
assert_eq 'powercfg router failure preserves UGT cap' 0 "$(cat "$FAS/uclamp_cap")"

new_fixture pixel_router_failure pixel pixel fas_rs
touch "$FAS/.test_runtime/fail_powercfg_router"
run_tick com.example.game >/dev/null 2>&1 || true
assert_eq 'powercfg router failure leaves Pixel owner intact' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'Pixel router failure does not start fas-rs' "$FAS/.test_runtime/fas_alive"
assert_no_file 'Pixel router failure does not replay profile' "$MOD/.cpu_profile_calls"

new_fixture ugt_fas_start_failure external external fas_rs
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
printf '1\n' > "$FAS/.test_runtime/uperf_count"
printf 'external:uperf:baseline\n' > "$FAS/.owner_state"
touch "$FAS/.test_runtime/fail_start_fas"
run_tick com.example.game >/dev/null 2>&1 || true
assert_file 'UGT fas-rs start failure restores UGT' "$FAS/.test_runtime/uperf_alive"
assert_no_file 'UGT fas-rs start failure leaves no fas process' "$FAS/.test_runtime/fas_alive"
assert_eq 'UGT fas-rs start failure restores pre-lease cap' 0 "$(cat "$FAS/uclamp_cap")"
case "$(state_value "$FAS/.arbiter_state" apply_result)" in
    failed_start_fas_rs_fallback_ugt*) ok 'UGT fas-rs start failure reports UGT rollback' ;;
    *) not_ok 'UGT fas-rs start failure reports UGT rollback' ;;
esac

# If UGT cannot restart on exit, preserve a verified fas-rs lease instead of
# publishing a false UGT success state.
new_fixture ugt_restore_failure external external fas_rs
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
printf '1\n' > "$FAS/.test_runtime/uperf_count"
printf 'external:uperf:baseline\n' > "$FAS/.owner_state"
run_tick com.example.game || exit 2
touch "$FAS/.test_runtime/fail_start_uperf"
run_tick com.android.launcher >/dev/null 2>&1 || true
assert_no_file 'UGT restore failure does not publish a dead UGT process' "$FAS/.test_runtime/uperf_alive"
assert_file 'UGT restore failure re-establishes fas-rs lease' "$FAS/.test_runtime/fas_alive"
assert_eq 'UGT restore failure keeps external effective owner' external "$(cat "$MOD/.cpu_sched_owner")"
case "$(state_value "$FAS/.arbiter_state" apply_result)" in
    *_fallback_fas*) ok 'UGT restore failure reports fas-rs fallback' ;;
    *) not_ok "UGT restore failure reports fas-rs fallback actual=$(state_value "$FAS/.arbiter_state" apply_result)" ;;
esac

# A failure after the test-mode UGT alive marker is written must restore the
# pre-start state before the owner transaction falls back to the fas-rs lease.
new_fixture ugt_restore_partial_write_failure external external fas_rs
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
printf '1\n' > "$FAS/.test_runtime/uperf_count"
printf 'external:uperf:baseline\n' > "$FAS/.owner_state"
run_tick com.example.game || exit 2
touch "$FAS/.test_runtime/fail_write_uperf_count_once"
run_tick com.android.launcher >/dev/null 2>&1 || true
assert_no_file 'partial UGT start failure rolls back its alive marker' "$FAS/.test_runtime/uperf_alive"
assert_eq 'partial UGT start failure restores the pre-start root count' 0 "$(cat "$FAS/.test_runtime/uperf_count")"
assert_file 'partial UGT start failure re-establishes fas-rs lease' "$FAS/.test_runtime/fas_alive"
assert_no_dir 'partial UGT start failure releases its private lock' "$FAS/.uperf_start.lock"
case "$(state_value "$FAS/.arbiter_state" apply_result)" in
    *_fallback_fas*) ok 'partial UGT start failure reports fas-rs fallback' ;;
    *) not_ok 'partial UGT start failure reports fas-rs fallback' ;;
esac

# A private UGT start lock is scoped to one boot. A live PID from a prior boot
# cannot block restoration after the fas-rs lease exits.
new_fixture ugt_cross_boot_start_lock external external fas_rs
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
printf '1\n' > "$FAS/.test_runtime/uperf_count"
printf 'external:uperf:baseline\n' > "$FAS/.owner_state"
run_tick com.example.game || exit 2
mkdir -p "$FAS/.uperf_start.lock" || exit 2
printf '%s\n' "$$" > "$FAS/.uperf_start.lock/pid"
printf '1\n' > "$FAS/.uperf_start.lock/start_ticks"
printf 'boot-previous\n' > "$FAS/.uperf_start.lock/boot_id"
run_tick com.android.launcher || exit 2
assert_file 'cross-boot UGT start lock is reclaimed and UGT restores' "$FAS/.test_runtime/uperf_alive"
assert_no_dir 'cross-boot UGT start lock does not survive restore' "$FAS/.uperf_start.lock"

# If router preparation fails while exiting a UGT lease, preserve the exact
# fas-rs lease instead of publishing a dead UGT baseline.
new_fixture ugt_exit_router_failure external external fas_rs
printf '1\n' > "$FAS/.test_runtime/uperf_alive"
printf '1\n' > "$FAS/.test_runtime/uperf_count"
printf 'external:uperf:baseline\n' > "$FAS/.owner_state"
run_tick com.example.game || exit 2
touch "$FAS/.test_runtime/fail_powercfg_router"
run_tick com.android.launcher >/dev/null 2>&1 || true
assert_no_file 'UGT exit router failure does not publish UGT' "$FAS/.test_runtime/uperf_alive"
assert_file 'UGT exit router failure preserves fas-rs lease' "$FAS/.test_runtime/fas_alive"
case "$(state_value "$FAS/.arbiter_state" apply_result)" in
    *_fallback_fas*) ok 'UGT exit router failure reports fas-rs rollback' ;;
    *) not_ok 'UGT exit router failure reports fas-rs rollback' ;;
esac

# Pixel -> fas-rs lease -> Pixel remains supported.
new_fixture pixel_fas_roundtrip pixel pixel fas_rs
printf '1\n' > "$FAS/.test_runtime/fas_alive"
printf 'fas-rs:running\n' > "$FAS/.owner_state"
run_tick com.example.game
assert_eq 'Pixel game enters fas-rs lease' FAS_LEASED_GAME "$(state_value "$FAS/.arbiter_state" state)"
assert_eq 'fas-rs lease publishes external effective owner' external "$(cat "$MOD/.cpu_sched_owner")"
assert_file 'resident fas-rs remains available for matched game' "$FAS/.test_runtime/fas_alive"
assert_no_file 'resident fas-rs is not restarted for a lease' "$FAS/.test_runtime/fas_start_calls"
assert_no_file 'UGT stays absent in Pixel mode' "$FAS/.test_runtime/uperf_alive"
assert_eq 'fas-rs lease opens full cap' 1024 "$(cat "$FAS/uclamp_cap")"
run_tick com.android.launcher
assert_eq 'game exit restores Pixel owner' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_file 'game exit keeps fas-rs resident' "$FAS/.test_runtime/fas_alive"
assert_eq 'game exit restores Pixel cap' 0 "$(cat "$FAS/uclamp_cap")"

# If the boot service process is missing, one lease transaction may recover it.
# Later Pixel-idle transitions keep that recovered process resident.
new_fixture pixel_fas_recovery pixel pixel fas_rs
run_tick com.example.game
assert_eq 'missing fas-rs is started once for the game lease' 1 "$(cat "$FAS/.test_runtime/fas_start_calls")"
assert_file 'recovered fas-rs process reaches the lease' "$FAS/.test_runtime/fas_alive"
run_tick com.android.launcher
assert_file 'recovered fas-rs remains resident after game exit' "$FAS/.test_runtime/fas_alive"
assert_eq 'recovered fas-rs exit restores Pixel owner' pixel "$(cat "$MOD/.cpu_sched_owner")"

# Publication rollback only cleans up a process created by that transaction.
new_fixture fas_publish_failure_new_process pixel pixel fas_rs
touch "$FAS/.test_runtime/fail_write_sched_owner_once"
run_tick com.example.game >/dev/null 2>&1 || true
assert_eq 'failed lease publication restores Pixel owner' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'failed lease publication cleans its new fas-rs process' "$FAS/.test_runtime/fas_alive"

new_fixture fas_publish_failure_resident pixel pixel fas_rs
printf '1\n' > "$FAS/.test_runtime/fas_alive"
printf 'fas-rs:running\n' > "$FAS/.owner_state"
touch "$FAS/.test_runtime/fail_write_sched_owner_once"
run_tick com.example.game >/dev/null 2>&1 || true
assert_eq 'resident publication failure restores Pixel owner' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_file 'resident publication failure never kills boot fas-rs' "$FAS/.test_runtime/fas_alive"

# Handoff disabled leaves the Pixel baseline untouched.
new_fixture handoff_off pixel pixel off
printf '1\n' > "$FAS/.test_runtime/fas_alive"
printf 'fas-rs:running\n' > "$FAS/.owner_state"
run_tick com.example.game
assert_eq 'handoff off keeps Pixel state' BASELINE_NORMAL "$(state_value "$FAS/.arbiter_state" state)"
assert_eq 'handoff off keeps Pixel owner' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_file 'handoff off keeps fas-rs resident without a lease' "$FAS/.test_runtime/fas_alive"
assert_no_file 'handoff off does not restart resident fas-rs' "$FAS/.test_runtime/fas_start_calls"

# A stable Pixel drift is delegated to the low-frequency health worker and is
# never repaired by the 5-second owner tick.
new_fixture pixel_drift pixel pixel fas_rs
printf '1\n' > "$FAS/.test_runtime/fas_alive"
printf 'fas-rs:running\n' > "$FAS/.owner_state"
touch "$FAS/.test_runtime/pixel_baseline_drift"
run_tick com.android.launcher >/dev/null 2>&1
assert_no_file 'owner tick does not replay profile for stable Pixel drift' "$MOD/.cpu_profile_calls"
assert_eq 'Pixel drift is reported to health worker' profile_drift_health_required "$(state_value "$FAS/.arbiter_state" apply_result)"
_t_drift_state_sig=$(file_signature "$FAS/.arbiter_state")
_t_drift_history_sig=$(file_signature "$FAS/.arbiter_history")
sleep 1
run_tick com.android.launcher >/dev/null 2>&1
assert_no_file 'repeated owner tick remains mutation-free' "$MOD/.cpu_profile_calls"
assert_eq 'repeated Pixel drift does not rewrite arbiter state' "$_t_drift_state_sig" "$(file_signature "$FAS/.arbiter_state")"
assert_eq 'repeated Pixel drift does not append history' "$_t_drift_history_sig" "$(file_signature "$FAS/.arbiter_history")"

# A failed fas-rs transition gets three attempts in the same generation, then
# latches and stops all further mutation attempts.
new_fixture fas_failure pixel pixel fas_rs
touch "$FAS/.test_runtime/fail_start_fas"
run_tick com.example.game >/dev/null 2>&1 || true
run_tick com.example.game >/dev/null 2>&1 || true
run_tick com.example.game >/dev/null 2>&1 || true
_t_guard_attempts=$(state_value "$FAS/.owner_mutation_guard" attempts)
case "$_t_guard_attempts" in
    1|2|3) ok 'owner retry guard reaches terminal within three attempts or 30 seconds' ;;
    *) not_ok 'owner retry guard reaches terminal within three attempts or 30 seconds' ;;
esac
assert_eq 'owner retry guard publishes terminal failure' yes "$(state_value "$FAS/.owner_mutation_guard" terminal)"
_t_guard_sig=$(file_signature "$FAS/.owner_mutation_guard")
_t_latched_state_sig=$(file_signature "$FAS/.arbiter_state")
_t_latched_history_sig=$(file_signature "$FAS/.arbiter_history")
sleep 1
run_tick com.example.game >/dev/null 2>&1 || true
assert_eq 'latched owner failure does not reopen generation' "$_t_guard_sig" "$(file_signature "$FAS/.owner_mutation_guard")"
assert_eq 'latched owner failure does not reacquire and rewrite state' "$_t_latched_state_sig" "$(file_signature "$FAS/.arbiter_state")"
assert_eq 'latched owner failure does not append history' "$_t_latched_history_sig" "$(file_signature "$FAS/.arbiter_history")"
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
rm -f "$MOD/.sched_owner_desired" "$MOD/.cpu_sched_owner" "$MOD/.game_handoff_policy"
run_tick com.example.game off
assert_no_file 'noninteractive ticks do not migrate desired owner state' "$MOD/.sched_owner_desired"
assert_no_file 'noninteractive ticks do not migrate effective owner state' "$MOD/.cpu_sched_owner"
assert_no_file 'noninteractive ticks do not migrate handoff state' "$MOD/.game_handoff_policy"

# Disabled observation is committed once and remains stable on later ticks.
new_fixture disabled_noop pixel pixel off
touch "$FAS/.arbiter_disable"
run_tick com.android.launcher >/dev/null 2>&1
assert_eq 'disabled arbiter publishes its initial observation' 0 "$?"
_t_disabled_state_sig=$(file_signature "$FAS/.arbiter_state")
_t_disabled_history_sig=$(file_signature "$FAS/.arbiter_history")
sleep 1
run_tick com.android.launcher >/dev/null 2>&1
assert_eq 'stable disabled arbiter exits as a no-op' 0 "$?"
assert_eq 'stable disabled arbiter does not rewrite state' "$_t_disabled_state_sig" "$(file_signature "$FAS/.arbiter_state")"
assert_eq 'stable disabled arbiter does not append history' "$_t_disabled_history_sig" "$(file_signature "$FAS/.arbiter_history")"

# Live transition lock prevents a concurrent mutation.
new_fixture busy_transition pixel external off
mkdir -p "$FAS/.owner_transition.lock"
printf '%s\n' "$$" > "$FAS/.owner_transition.lock/pid"
_t_parent_start=$(sed 's/^.*) //' "/proc/$$/stat" | awk '{print $20}')
printf '%s\n' "$_t_parent_start" > "$FAS/.owner_transition.lock/start_ticks"
printf 'boot-current\n' > "$FAS/.owner_transition.lock/boot_id"
run_tick com.android.launcher >/dev/null 2>&1
assert_eq 'live transition lock returns busy' 75 "$?"
assert_no_file 'busy transition prevents profile mutation' "$MOD/.cpu_profile_calls"
assert_no_file 'busy transition does not overwrite arbiter state' "$FAS/.arbiter_state"
assert_no_file 'busy transition does not append owner history' "$FAS/.arbiter_history"

# A decision made before waiting on the shared lock is discarded when the
# handoff policy changes before the lock becomes available.
new_fixture superseded_decision pixel pixel fas_rs
sleep 2 &
_t_holder_pid=$!
mkdir -p "$FAS/.owner_transition.lock"
printf '%s\n' "$_t_holder_pid" > "$FAS/.owner_transition.lock/pid"
_t_holder_start=$(sed 's/^.*) //' "/proc/$_t_holder_pid/stat" | awk '{print $20}')
printf '%s\n' "$_t_holder_start" > "$FAS/.owner_transition.lock/start_ticks"
printf 'boot-current\n' > "$FAS/.owner_transition.lock/boot_id"
printf '%s\n' "$(date +%s)" > "$FAS/.owner_transition.lock/epoch"
TEST_SO_TRANSITION_LOCK_MAX_ATTEMPTS=5 TEST_SO_TRANSITION_LOCK_RETRY_SLEEP_S=1 \
    run_tick com.example.game >/dev/null 2>&1 &
_t_tick_pid=$!
sleep 1
printf 'off\n' > "$MOD/.game_handoff_policy"
wait "$_t_holder_pid" >/dev/null 2>&1 || true
wait "$_t_tick_pid"
assert_eq 'superseded owner decision exits as a no-op' 0 "$?"
assert_eq 'superseded owner decision preserves the current owner' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'superseded owner decision does not start fas-rs' "$FAS/.test_runtime/fas_alive"
assert_no_file 'superseded owner decision does not replay Pixel profile' "$MOD/.cpu_profile_calls"

printf 'fas_rs\n' > "$MOD/.game_handoff_policy"
sleep 2 &
_t_holder_pid=$!
mkdir -p "$FAS/.owner_transition.lock"
printf '%s\n' "$_t_holder_pid" > "$FAS/.owner_transition.lock/pid"
_t_holder_start=$(sed 's/^.*) //' "/proc/$_t_holder_pid/stat" | awk '{print $20}')
printf '%s\n' "$_t_holder_start" > "$FAS/.owner_transition.lock/start_ticks"
printf 'boot-current\n' > "$FAS/.owner_transition.lock/boot_id"
printf '%s\n' "$(date +%s)" > "$FAS/.owner_transition.lock/epoch"
TEST_SO_TRANSITION_LOCK_MAX_ATTEMPTS=5 TEST_SO_TRANSITION_LOCK_RETRY_SLEEP_S=1 \
    run_tick com.example.game >/dev/null 2>&1 &
_t_tick_pid=$!
sleep 1
printf 'external\n' > "$MOD/.cpu_sched_owner"
wait "$_t_holder_pid" >/dev/null 2>&1 || true
wait "$_t_tick_pid"
assert_eq 'effective-owner supersession exits as a no-op' 0 "$?"
assert_no_file 'effective-owner supersession does not start fas-rs' "$FAS/.test_runtime/fas_alive"
assert_no_file 'effective-owner supersession does not replay Pixel profile' "$MOD/.cpu_profile_calls"

# The periodic service tick also rechecks its runtime apply switch after lock
# acquisition. Shadow tests can therefore quiesce it without a stale tick
# applying nodes after .arbiter_apply has been disabled.
new_fixture superseded_apply pixel pixel fas_rs
printf '1\n' > "$FAS/.arbiter_apply"
sleep 2 &
_t_holder_pid=$!
mkdir -p "$FAS/.owner_transition.lock"
printf '%s\n' "$_t_holder_pid" > "$FAS/.owner_transition.lock/pid"
_t_holder_start=$(sed 's/^.*) //' "/proc/$_t_holder_pid/stat" | awk '{print $20}')
printf '%s\n' "$_t_holder_start" > "$FAS/.owner_transition.lock/start_ticks"
printf 'boot-current\n' > "$FAS/.owner_transition.lock/boot_id"
printf '%s\n' "$(date +%s)" > "$FAS/.owner_transition.lock/epoch"
TEST_SO_TRANSITION_LOCK_MAX_ATTEMPTS=5 TEST_SO_TRANSITION_LOCK_RETRY_SLEEP_S=1 \
    run_worker_tick com.example.game >/dev/null 2>&1 &
_t_tick_pid=$!
sleep 1
printf '0\n' > "$FAS/.arbiter_apply"
wait "$_t_holder_pid" >/dev/null 2>&1 || true
wait "$_t_tick_pid"
assert_eq 'disabled runtime apply supersedes the waiting worker tick' 0 "$?"
assert_eq 'superseded worker tick preserves the current owner' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_no_file 'superseded worker tick does not start fas-rs' "$FAS/.test_runtime/fas_alive"
assert_no_file 'superseded worker tick does not replay Pixel profile' "$MOD/.cpu_profile_calls"

# Read-only lock checks distinguish fresh initialization from stale metadata.
new_fixture lock_contract pixel pixel off
. "$MOD/scripts/scheduler_owner_lib.sh" || exit 2
SO_BOOT_ID_PATH="$FIXTURE/boot_id"
scheduler_owner_init "$MOD" "$FAS"

rm -f "$SO_DESIRED_FILE" "$SO_EFFECTIVE_FILE" "$SO_HANDOFF_FILE" "$SO_HANDOFF_SOURCE_FILE"
SO_HANDOFF_FILE="$FIXTURE/missing_parent/handoff"
so_migrate_state >/dev/null 2>&1
assert_eq 'partial owner migration fails closed' 1 "$?"
assert_no_file 'failed owner migration rolls back desired state' "$SO_DESIRED_FILE"
assert_no_file 'failed owner migration rolls back effective state' "$SO_EFFECTIVE_FILE"
assert_no_file 'failed owner migration rolls back handoff source' "$SO_HANDOFF_SOURCE_FILE"
assert_eq 'failed owner migration reports complete rollback' yes "$SO_MIGRATION_ROLLBACK_OK"
scheduler_owner_init "$MOD" "$FAS"
printf 'pixel\n' > "$SO_DESIRED_FILE"
printf 'pixel\n' > "$SO_EFFECTIVE_FILE"
printf 'off\n' > "$SO_HANDOFF_FILE"
printf 'user\n' > "$SO_HANDOFF_SOURCE_FILE"

so_write_handoff_preference fas_rs default
assert_eq 'handoff preference transaction writes policy' fas_rs "$(so_read_handoff_policy)"
assert_eq 'handoff preference transaction writes source' default "$(so_read_handoff_source)"

mkdir -p "$FAS/.owner_transition.lock"
so_transition_lock_is_active >/dev/null 2>&1
assert_eq 'fresh metadata-free lock is treated as initializing' 0 "$?"
assert_dir 'read-only active check preserves the lock directory' "$FAS/.owner_transition.lock"
rmdir "$FAS/.owner_transition.lock" || exit 2

mkdir -p "$FAS/.owner_transition.lock"
printf '1\n' > "$FAS/.owner_transition.lock/epoch"
so_transition_lock_is_active >/dev/null 2>&1
assert_eq 'expired incomplete lock is not active' 1 "$?"
assert_dir 'read-only stale check does not reclaim the lock' "$FAS/.owner_transition.lock"
SO_TRANSITION_LOCK_MAX_ATTEMPTS=1 SO_TRANSITION_LOCK_RETRY_SLEEP_S=0 \
    so_acquire_transition_lock
assert_eq 'mutation path reclaims an expired incomplete lock' 0 "$?"
so_release_transition_lock
assert_no_dir 'released reclaimed lock leaves no directory' "$FAS/.owner_transition.lock"

mkdir -p "$FAS/.owner_transition.lock"
printf '999999\n' > "$FAS/.owner_transition.lock/pid"
printf '1\n' > "$FAS/.owner_transition.lock/start_ticks"
printf 'boot-current\n' > "$FAS/.owner_transition.lock/boot_id"
printf '1\n' > "$FAS/.owner_transition.lock/epoch"
so_transition_lock_is_active >/dev/null 2>&1
assert_eq 'complete lock with a dead owner is stale' 1 "$?"
assert_dir 'read-only dead-owner check preserves the stale lock' "$FAS/.owner_transition.lock"
SO_TRANSITION_LOCK_MAX_ATTEMPTS=1 SO_TRANSITION_LOCK_RETRY_SLEEP_S=0 \
    so_acquire_transition_lock
assert_eq 'mutation path reclaims a dead-owner lock' 0 "$?"
so_release_transition_lock
assert_no_dir 'dead-owner lock is removed after release' "$FAS/.owner_transition.lock"

mkdir -p "$FAS/.owner_transition.lock"
printf '%s\n' "$$" > "$FAS/.owner_transition.lock/pid"
_t_current_start=$(sed 's/^.*) //' "/proc/$$/stat" | awk '{print $20}')
printf '%s\n' "$_t_current_start" > "$FAS/.owner_transition.lock/start_ticks"
printf 'boot-previous\n' > "$FAS/.owner_transition.lock/boot_id"
printf '%s\n' "$(date +%s)" > "$FAS/.owner_transition.lock/epoch"
so_transition_lock_is_active >/dev/null 2>&1
assert_eq 'cross-boot PID reuse is treated as stale' 1 "$?"
SO_TRANSITION_LOCK_MAX_ATTEMPTS=1 SO_TRANSITION_LOCK_RETRY_SLEEP_S=0 \
    so_acquire_transition_lock
assert_eq 'mutation path reclaims a cross-boot lock' 0 "$?"
so_release_transition_lock
assert_no_dir 'cross-boot lock is removed after release' "$FAS/.owner_transition.lock"

mkdir -p "$FAS/.owner_transition.lock"
printf '1\n' > "$FAS/.owner_transition.lock/epoch"
printf 'stale-probe\n' > "$FAS/.owner_transition.lock/.pid_probe"
SO_TRANSITION_LOCK_MAX_ATTEMPTS=1 SO_TRANSITION_LOCK_RETRY_SLEEP_S=0 \
    so_acquire_transition_lock
assert_eq 'mutation path reclaims its own stale PID probe' 0 "$?"
so_release_transition_lock
assert_no_dir 'stale PID probe does not wedge the lock' "$FAS/.owner_transition.lock"

(
    _t_pid_probe="$FAS/pid_probe"
    sh -c 'printf "%s" "$PPID"' > "$_t_pid_probe"
    _t_actual_pid=$(cat "$_t_pid_probe")
    rm -f "$_t_pid_probe"
    SO_TRANSITION_LOCK_MAX_ATTEMPTS=1 SO_TRANSITION_LOCK_RETRY_SLEEP_S=0 \
        so_acquire_transition_lock
    _t_subshell_rc=$?
    _t_lock_pid=$(cat "$FAS/.owner_transition.lock/pid" 2>/dev/null)
    printf '%s|%s|%s\n' "$_t_actual_pid" "$_t_lock_pid" "$_t_subshell_rc" > "$FAS/subshell_lock_result"
    [ "$_t_subshell_rc" -eq 0 ] && [ "$_t_lock_pid" = "$_t_actual_pid" ] || exit 1
    so_release_transition_lock
)
assert_eq 'background subshell lock records its actual process PID' 0 "$?"
_t_subshell_actual=$(cut -d'|' -f1 "$FAS/subshell_lock_result")
_t_subshell_lock=$(cut -d'|' -f2 "$FAS/subshell_lock_result")
assert_eq 'background subshell PID matches lock metadata' "$_t_subshell_actual" "$_t_subshell_lock"
assert_no_dir 'background subshell releases only its own lock' "$FAS/.owner_transition.lock"

# APatch service workers run under BusyBox ash.  Exercise the same shell so a
# pipeline/subshell PID regression cannot pass the regular toybox fixture.
if [ -x /data/adb/ap/bin/busybox ]; then
    _t_busybox_script="$TEST_ROOT/busybox_lock_probe.sh"
    cat > "$_t_busybox_script" <<'EOF'
#!/system/bin/sh
_bb_mod="$1"
_bb_fas="$2"
. "$_bb_mod/scripts/scheduler_owner_lib.sh" || exit 2
scheduler_owner_init "$_bb_mod" "$_bb_fas"
(
    _bb_probe="$_bb_fas/busybox_pid_probe"
    sh -c 'printf "%s" "$PPID"' > "$_bb_probe" || exit 3
    _bb_actual=$(cat "$_bb_probe")
    rm -f "$_bb_probe"
    SO_TRANSITION_LOCK_MAX_ATTEMPTS=1 SO_TRANSITION_LOCK_RETRY_SLEEP_S=0 \
        so_acquire_transition_lock || exit 4
    _bb_lock=$(cat "$SO_TRANSITION_LOCK_DIR/pid" 2>/dev/null)
    printf '%s|%s\n' "$_bb_actual" "$_bb_lock" > "$_bb_fas/busybox_lock_result"
    [ "$_bb_actual" = "$_bb_lock" ] || exit 5
    so_release_transition_lock
)
EOF
    /data/adb/ap/bin/busybox sh "$_t_busybox_script" "$MOD" "$FAS"
    assert_eq 'BusyBox background worker lock probe succeeds' 0 "$?"
    _t_busybox_actual=$(cut -d'|' -f1 "$FAS/busybox_lock_result" 2>/dev/null)
    _t_busybox_lock=$(cut -d'|' -f2 "$FAS/busybox_lock_result" 2>/dev/null)
    assert_eq 'BusyBox PID matches lock metadata' "$_t_busybox_actual" "$_t_busybox_lock"
    assert_no_dir 'BusyBox worker releases its transition lock' "$FAS/.owner_transition.lock"
else
    ok 'BusyBox background worker lock probe skipped outside APatch'
fi

mkdir -p "$FAS/.owner_transition.lock"
printf '1\n' > "$FAS/.owner_transition.lock/epoch"
printf 'keep\n' > "$FAS/.owner_transition.lock/unexpected"
SO_TRANSITION_LOCK_MAX_ATTEMPTS=1 SO_TRANSITION_LOCK_RETRY_SLEEP_S=0 \
    so_acquire_transition_lock >/dev/null 2>&1
assert_eq 'unreclaimable stale lock returns busy within the retry budget' 1 "$?"
assert_file 'unreclaimable stale lock is left intact' "$FAS/.owner_transition.lock/unexpected"
rm -f "$FAS/.owner_transition.lock/unexpected" "$FAS/.owner_transition.lock/epoch"
rmdir "$FAS/.owner_transition.lock" || exit 2

printf '1..%s\n' "$TOTAL"
printf '# pass=%s fail=%s root=%s\n' "$PASS" "$FAIL" "$TEST_ROOT"
[ "$FAIL" -eq 0 ]
