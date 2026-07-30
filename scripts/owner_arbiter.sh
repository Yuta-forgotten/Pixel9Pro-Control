#!/system/bin/sh
#
# Guarded scheduler-owner arbiter. A plain tick records the decision only;
# apply-tick/apply performs verified baseline/fas-rs transitions. Pixel/UGT
# baseline selection is reboot-only; inside a verified boot, fas-rs may take a
# temporary game lease and then restore the same baseline.

ACTION="${1:-tick}"
APPLY_REQUESTED="no"
case "$ACTION" in
    apply|apply-tick)
        ACTION="tick"
        APPLY_REQUESTED="yes"
        ;;
esac
MODDIR_ARG="$2"
SCREEN_STATE="${3:-unknown}"

SCRIPT_DIR="${0%/*}"
case "$SCRIPT_DIR" in
    "$0") SCRIPT_DIR="." ;;
esac

if [ -n "$MODDIR_ARG" ]; then
    MODDIR="$MODDIR_ARG"
else
    MODDIR="${SCRIPT_DIR%/scripts}"
    [ -n "$MODDIR" ] || MODDIR="/data/adb/modules/pixel9pro_control"
fi

FAS_ROOT="${OWNER_ARBITER_FAS_ROOT:-/data/adb/fas_rs}"
STATE_DIR="$FAS_ROOT"
OWNER_ARBITER_TEST_MODE="${OWNER_ARBITER_TEST_MODE:-0}"
if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
    case "$STATE_DIR" in
        /sdcard/Download/Pixel9Pro-Control-TestLab/runtime/* \
        |/tmp/pixel9pro_*/fas \
        |/tmp/pixel9pro_*/*/fas) ;;
        *) echo "owner_arbiter: unsafe test root" >&2; exit 64 ;;
    esac
fi
TEST_RUNTIME_DIR="$STATE_DIR/.test_runtime"
if [ "$ACTION" != "status" ] && [ ! -d "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || exit 66
fi

SCHED_OWNER_FILE="$MODDIR/.cpu_sched_owner"
SCHED_OWNER_DESIRED_FILE="$MODDIR/.sched_owner_desired"
GAME_HANDOFF_POLICY_FILE="$MODDIR/.game_handoff_policy"
PROFILE_FILE="$MODDIR/.current_profile"
ARB_DISABLE_FILE="$STATE_DIR/.arbiter_disable"
ARB_APPLY_FILE="$STATE_DIR/.arbiter_apply"
ARB_STATE_FILE="$STATE_DIR/.arbiter_state"
ARB_HISTORY_FILE="$STATE_DIR/.arbiter_history"
LEASE_GAME_LIST="$FAS_ROOT/.lease_game_list"
FAS_OWNER_FILE="$FAS_ROOT/.owner_state"
FAS_LOG_FILE="$FAS_ROOT/fas_log.txt"
POWERCFG_ENTRY="${OWNER_ARBITER_POWERCFG_ENTRY:-/data/powercfg.sh}"
POWERCFG_ENTRY_EXECUTABLE_REQUIRED="${OWNER_ARBITER_POWERCFG_ENTRY_EXECUTABLE_REQUIRED:-yes}"
SCENE_PROFILE="${OWNER_ARBITER_SCENE_PROFILE:-/data/data/com.omarea.vtools/shared_prefs/games.xml}"
UPERF_START_LOCK_DIR="$STATE_DIR/.uperf_start.lock"
CPUFREQ_ROOT="${OWNER_ARBITER_CPUFREQ_ROOT:-/sys/devices/system/cpu/cpufreq}"
UCLAMP_CAP_PATH="${OWNER_ARBITER_UCLAMP_CAP_PATH:-/proc/sys/kernel/sched_util_clamp_min}"
SCHEDULER_INVENTORY_PATH="${SCHEDULER_INVENTORY_PATH:-$MODDIR/.scheduler_inventory}"
SCHEDULER_FAS_RUNTIME_ROOT="${SCHEDULER_FAS_RUNTIME_ROOT:-$FAS_ROOT}"
if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
    case "$STATE_DIR" in
        /tmp/*)
            _oa_test_parent="${STATE_DIR%/fas}"
            case "$MODDIR:$CPUFREQ_ROOT:$UCLAMP_CAP_PATH" in
                "$_oa_test_parent"/mod:"$STATE_DIR"/*:"$STATE_DIR"/*) ;;
                *) echo "owner_arbiter: unsafe test fixture paths" >&2; exit 64 ;;
            esac
            ;;
    esac
fi

write_fas_owner_state() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ] \
        && [ -f "$TEST_RUNTIME_DIR/fail_write_fas_owner_once" ]; then
        rm -f "$TEST_RUNTIME_DIR/fail_write_fas_owner_once" 2>/dev/null
        return 1
    fi
    so_atomic_write "$FAS_OWNER_FILE" "$1"
}

ENTER_DEBOUNCE_S="${ARB_ENTER_DEBOUNCE_S:-3}"
MIN_LEASE_S="${ARB_MIN_LEASE_S:-420}"
PID_ABSENT_CONFIRM_S="${ARB_PID_ABSENT_CONFIRM_S:-8}"
EXIT_IDLE_AFTER_S="${ARB_EXIT_IDLE_AFTER_S:-90}"
ARB_HISTORY_MAX="${ARB_HISTORY_MAX:-500}"
CPUFREQ_RESTORE_RETRY_S="${ARB_CPUFREQ_RESTORE_RETRY_S:-30}"
CPUFREQ_RESTORE_SETTLE_S="${ARB_CPUFREQ_RESTORE_SETTLE_S:-2}"
APPLY_ENABLED="no"
APPLY_RESULT="dry-run"
UPERF_NORMALIZED="no"
CPUFREQ_LOWFREQ_PRESENT="no"
CPUFREQ_THERMAL_COOLING_ACTIVE="no"
CPUFREQ_RESTORED="no"
CPUFREQ_RESTORE_VERIFIED="no"
CPUFREQ_RESTORE_FAILED="no"
CPUFREQ_RESTORE_SKIPPED="no"
CPUFREQ_RESTORE_LEASE="0"
CPUFREQ_RESTORE_EPOCH="0"
CPUFREQ_RESTORE_CONTEXT="scheduler_handoff"
UCLAMP_CAP_CURRENT="unknown"
UCLAMP_CAP_EXPECTED="unknown"
UCLAMP_CAP_VERIFIED="unknown"
FAS_STARTED_BY_TRANSACTION="no"
FAS_STARTED_PID=""
FAS_STARTED_START_TICKS=""

read_runtime_apply_enabled() {
    [ -f "$ARB_APPLY_FILE" ] || { printf 'no'; return 0; }
    _oa_apply_value=$(cat "$ARB_APPLY_FILE" 2>/dev/null | tr -d ' \r\n\t')
    case "$_oa_apply_value" in
        0|off|false|no) printf 'no' ;;
        *) printf 'yes' ;;
    esac
}

if [ "$APPLY_REQUESTED" = "yes" ]; then
    APPLY_ENABLED="yes"
elif [ "$(read_runtime_apply_enabled)" = "yes" ]; then
    APPLY_ENABLED="yes"
fi
if [ "$APPLY_ENABLED" = "yes" ]; then
    DRY_RUN_FLAG="0"
else
    DRY_RUN_FLAG="1"
fi

if [ ! -r "$MODDIR/scripts/scheduler_detect_lib.sh" ] \
    || ! . "$MODDIR/scripts/scheduler_detect_lib.sh" 2>/dev/null; then
    echo "owner_arbiter: missing scheduler-detection contract" >&2
    exit 65
fi
if [ ! -r "$MODDIR/scripts/scheduler_owner_lib.sh" ] \
    || ! . "$MODDIR/scripts/scheduler_owner_lib.sh" 2>/dev/null; then
    echo "owner_arbiter: missing scheduler-owner contract" >&2
    exit 65
fi
if [ ! -r "$MODDIR/scripts/cpu_profile_lib.sh" ] \
    || ! . "$MODDIR/scripts/cpu_profile_lib.sh" 2>/dev/null; then
    echo "owner_arbiter: missing CPU profile contract" >&2
    exit 65
fi
if [ ! -r "$MODDIR/scripts/scheduler_boot_mode_lib.sh" ] \
    || ! . "$MODDIR/scripts/scheduler_boot_mode_lib.sh" 2>/dev/null; then
    echo "owner_arbiter: missing scheduler boot-mode contract" >&2
    exit 65
fi
if [ ! -r "$MODDIR/scripts/scheduler_transition_guard_lib.sh" ] \
    || ! . "$MODDIR/scripts/scheduler_transition_guard_lib.sh" 2>/dev/null; then
    echo "owner_arbiter: missing scheduler transition guard" >&2
    exit 65
fi
for _oa_contract in \
    profile_state_lib.sh foreground_app_lib.sh owner_arbiter_state_lib.sh \
    owner_arbiter_observation_lib.sh owner_arbiter_external_lib.sh owner_arbiter_cpufreq_lib.sh; do
    if [ ! -r "$MODDIR/scripts/$_oa_contract" ] \
        || ! . "$MODDIR/scripts/$_oa_contract" 2>/dev/null; then
        echo "owner_arbiter: missing internal contract $_oa_contract" >&2
        exit 65
    fi
done
profile_state_init "$MODDIR" || {
    echo "owner_arbiter: profile state initialization failed" >&2
    exit 65
}

scheduler_owner_init "$MODDIR" "$FAS_ROOT"
sbm_init "$MODDIR" "$FAS_ROOT"

apply_pixel_baseline() {
    if uperf_process_alive; then
        APPLY_RESULT="blocked_uperf_residue_for_pixel"
        return 1
    fi
    restore_pixel_cpufreq_floor
    if ! apply_current_pixel_profile; then
        APPLY_RESULT="failed_apply_pixel_profile"
        return 1
    fi
    _oa_pixel_cap=$(expected_pixel_uclamp_cap)
    if ! apply_uclamp_cap "$_oa_pixel_cap"; then
        APPLY_RESULT="failed_verify_pixel_uclamp_cap"
        return 1
    fi
    if ! write_sched_owner pixel; then
        APPLY_RESULT="failed_write_pixel_owner"
        return 1
    fi

    _oa_profile=$(read_valid_pixel_profile)
    if ! write_fas_owner_state "pixel:profile:$_oa_profile"; then
        APPLY_RESULT="failed_write_fas_owner_state"
        return 1
    fi
    NEW_STATE="BASELINE_NORMAL"
    NEW_TARGET_PKG=""
    NEW_TARGET_PID="0"
    NEW_CANDIDATE_SINCE="0"
    NEW_LEASE_START="0"
    NEW_LAST_FOREGROUND="0"
    NEW_PID_ABSENT_SINCE="0"
    NEW_BASELINE_OWNER="pixel"
    NEW_BASELINE_UCLAMP_CAP="$_oa_pixel_cap"
    NEW_LEASE_FAS_PID="0"
    NEW_LEASE_FAS_START_TICKS="0"
    if [ "$CPUFREQ_THERMAL_COOLING_ACTIVE" = "yes" ]; then
        APPLY_RESULT="deferred_pixel_cpufreq_thermal_cooling"
        return 0
    fi
    if [ "$CPUFREQ_RESTORE_FAILED" = "yes" ]; then
        APPLY_RESULT="failed_pixel_cpufreq_restore"
        return 1
    fi
    if ! verify_pixel_baseline; then
        APPLY_RESULT="failed_verify_pixel_baseline"
        return 1
    fi
    if [ "$CPUFREQ_RESTORE_VERIFIED" = "yes" ]; then
        APPLY_RESULT="applied_pixel_idle_cpufreq_verified"
    elif [ "$CPUFREQ_RESTORED" = "yes" ]; then
        APPLY_RESULT="applied_pixel_idle_cpufreq_restored"
    else
        APPLY_RESULT="applied_pixel_idle"
    fi
    return 0
}

start_and_publish_ugt_baseline() {
    _oa_expected_cap="$1"
    uclamp_cap_is_valid "$_oa_expected_cap" || return 1
    ensure_powercfg_router || return 1
    # Restore the exact pre-lease cap while no scheduler process is active,
    # then hand control to UGT.  Once uperf is live, Control does not keep
    # rewriting the cap or fight UGT's own mode policy.
    if ! apply_uclamp_cap "$_oa_expected_cap"; then
        return 1
    fi
    start_uperf || return $?
    write_sched_owner external || return 1
    write_fas_owner_state "external:uperf" || return 1
    verify_ugt_baseline unknown
}

record_current_fas_lease_identity() {
    _oa_pid=$(fas_primary_pid)
    case "$_oa_pid" in ''|*[!0-9]*) return 1 ;; esac
    _oa_start=$(process_start_ticks "$_oa_pid")
    case "$_oa_start" in ''|*[!0-9]*) return 1 ;; esac
    fas_identity_matches "$_oa_pid" "$_oa_start" || return 1
    NEW_LEASE_FAS_PID="$_oa_pid"
    NEW_LEASE_FAS_START_TICKS="$_oa_start"
    return 0
}

rollback_to_fas_lease() {
    _oa_reason="$1"
    _oa_pkg="$2"
    stop_uperf >/dev/null 2>&1 || true
    restore_fas_rs_cpufreq_floor
    if [ "$CPUFREQ_RESTORE_FAILED" = "yes" ] \
        || ! apply_uclamp_cap "$CPU_PROFILE_FULL_CAP" \
        || ! start_fas_rs \
        || ! record_current_fas_lease_identity \
        || ! write_sched_owner external \
        || ! write_fas_owner_state "fas-rs:game:$_oa_pkg"; then
        APPLY_RESULT="${_oa_reason}_fallback_incomplete"
        return 1
    fi
    NEW_STATE="EXIT_HOLD"
    NEW_TARGET_PKG="$_oa_pkg"
    [ -n "$NEW_TARGET_PID" ] || NEW_TARGET_PID="0"
    [ "$NEW_LEASE_START" -gt 0 ] 2>/dev/null || NEW_LEASE_START="$NOW"
    [ "$NEW_LAST_FOREGROUND" -gt 0 ] 2>/dev/null || NEW_LAST_FOREGROUND="$NOW"
    NEW_BASELINE_OWNER="external"
    APPLY_RESULT="${_oa_reason}_fallback_fas"
    return 1
}

apply_ugt_baseline() {
    _oa_restore_pkg="$PREV_TARGET_PKG"
    [ -n "$_oa_restore_pkg" ] || _oa_restore_pkg="$NEW_TARGET_PKG"
    _oa_saved_cap="$NEW_BASELINE_UCLAMP_CAP"
    uclamp_cap_is_valid "$_oa_saved_cap" || {
        APPLY_RESULT="failed_missing_ugt_baseline_cap"
        return 1
    }

    stop_fas_lease_instance "$NEW_LEASE_FAS_PID" "$NEW_LEASE_FAS_START_TICKS"
    _oa_stop_fas_rc=$?
    if [ "$_oa_stop_fas_rc" -ne 0 ]; then
        if [ "$_oa_stop_fas_rc" -eq 2 ]; then
            APPLY_RESULT="failed_stop_exact_fas_lease_conflict"
        else
            APPLY_RESULT="failed_stop_exact_fas_lease"
        fi
        return 1
    fi

    if ! start_and_publish_ugt_baseline "$_oa_saved_cap"; then
        _oa_ugt_restore_result="failed_restore_ugt_baseline"
        stop_uperf >/dev/null 2>&1 || true
        rollback_to_fas_lease "$_oa_ugt_restore_result" "$_oa_restore_pkg"
        return $?
    fi

    NEW_STATE="BASELINE_NORMAL"
    NEW_TARGET_PKG=""
    NEW_TARGET_PID="0"
    NEW_CANDIDATE_SINCE="0"
    NEW_LEASE_START="0"
    NEW_LAST_FOREGROUND="0"
    NEW_PID_ABSENT_SINCE="0"
    NEW_BASELINE_OWNER="external"
    NEW_LEASE_FAS_PID="0"
    NEW_LEASE_FAS_START_TICKS="0"
    APPLY_RESULT="applied_ugt_idle_restored"
    return 0
}

restore_ugt_after_failed_entry() {
    _oa_restore_reason="$1"
    _oa_restore_pkg="$2"
    cleanup_fas_started_by_transaction >/dev/null 2>&1 || true
    if fas_process_alive; then
        rollback_to_fas_lease "${_oa_restore_reason}_ugt_restore_blocked" "$_oa_restore_pkg"
        return $?
    fi
    if start_and_publish_ugt_baseline "$NEW_BASELINE_UCLAMP_CAP"; then
        NEW_STATE="BASELINE_NORMAL"
        NEW_TARGET_PKG=""
        NEW_TARGET_PID="0"
        NEW_CANDIDATE_SINCE="0"
        NEW_LEASE_START="0"
        NEW_LAST_FOREGROUND="0"
        NEW_PID_ABSENT_SINCE="0"
        NEW_BASELINE_OWNER="external"
        NEW_LEASE_FAS_PID="0"
        NEW_LEASE_FAS_START_TICKS="0"
        APPLY_RESULT="${_oa_restore_reason}_fallback_ugt"
        return 1
    fi
    stop_uperf >/dev/null 2>&1 || true
    rollback_to_fas_lease "${_oa_restore_reason}_ugt_restore_failed" "$_oa_restore_pkg"
    return $?
}

restore_desired_baseline_after_failure() {
    _oa_restore_reason="$1"
    _oa_restore_pkg="${2:-$NEW_TARGET_PKG}"
    if [ "$NEW_BASELINE_OWNER" = "external" ]; then
        restore_ugt_after_failed_entry "$_oa_restore_reason" "$_oa_restore_pkg"
        return $?
    fi
    cleanup_fas_started_by_transaction >/dev/null 2>&1 || true
    if apply_pixel_baseline >/dev/null 2>&1; then
        APPLY_RESULT="${_oa_restore_reason}_fallback_pixel"
    else
        APPLY_RESULT="${_oa_restore_reason}_fallback_incomplete"
    fi
    return 1
}

apply_owner_decision() {
    APPLY_STABLE_NOOP="no"
    APPLY_MUTATION_GUARD_ACTIVE="no"
    if [ "$APPLY_ENABLED" != "yes" ]; then
        APPLY_RESULT="dry-run"
        return 0
    fi

    case "$NEW_STATE" in
        FAS_LEASED_GAME|EXIT_HOLD)
            if verify_fas_baseline; then
                APPLY_RESULT="stable_fas_noop"
                APPLY_STABLE_NOOP="yes"
                return 0
            fi

            if [ "$NEW_BASELINE_OWNER" = "external" ]; then
                case "$PREV_STATE" in
                    FAS_LEASED_GAME|EXIT_HOLD)
                        if ! fas_identity_matches "$NEW_LEASE_FAS_PID" "$NEW_LEASE_FAS_START_TICKS"; then
                            APPLY_RESULT="failed_fas_lease_identity_mismatch"
                            return 1
                        fi
                        ;;
                    *)
                        verify_ugt_baseline unknown || {
                            APPLY_RESULT="ugt_baseline_drift_health_required"
                            APPLY_STABLE_NOOP="yes"
                            return 1
                        }
                        capture_ugt_baseline_cap || {
                            APPLY_RESULT="failed_capture_ugt_baseline_cap"
                            return 1
                        }
                        ;;
                esac
            elif uperf_process_alive; then
                APPLY_RESULT="blocked_uperf_residue_for_fas"
                APPLY_STABLE_NOOP="yes"
                return 1
            fi

            owner_guard_begin "fas:${NEW_BASELINE_OWNER}:${NEW_TARGET_PKG}" || return 1
            if ! ensure_powercfg_router; then
                APPLY_RESULT="failed_prepare_powercfg_router"
                return 1
            fi
            if [ "$NEW_BASELINE_OWNER" = "external" ] \
                && [ "$PREV_STATE" != "FAS_LEASED_GAME" ] \
                && [ "$PREV_STATE" != "EXIT_HOLD" ]; then
                if ! stop_uperf; then
                    APPLY_RESULT="failed_stop_ugt_for_fas"
                    return 1
                fi
                uperf_process_alive && {
                    APPLY_RESULT="failed_verify_ugt_stopped_for_fas"
                    return 1
                }
            fi

            # Finish the runtime preflight before fas-rs can publish its game
            # owner.  UGT may leave a powersave governor behind, and exposing
            # fas-rs:game while cap is still 0 creates a false-active window.
            restore_fas_rs_cpufreq_floor
            if [ "$CPUFREQ_RESTORE_FAILED" = "yes" ]; then
                _oa_failed_result="failed_restore_fas_rs_cpufreq"
                write_fas_owner_state "fallback:fas_cpufreq_restore_failed:$DESIRED_OWNER" >/dev/null 2>&1 || true
                restore_desired_baseline_after_failure "$_oa_failed_result"
                return $?
            fi
            if ! apply_uclamp_cap "$CPU_PROFILE_FULL_CAP"; then
                _oa_failed_result="failed_verify_fas_rs_game_uclamp_cap"
                write_fas_owner_state "fallback:fas_uclamp_failed:$DESIRED_OWNER" >/dev/null 2>&1 || true
                restore_desired_baseline_after_failure "$_oa_failed_result"
                return $?
            fi
            if ! start_fas_rs; then
                _oa_failed_result="failed_start_fas_rs"
                write_fas_owner_state "fallback:fas_start_failed:$DESIRED_OWNER" >/dev/null 2>&1 || true
                restore_desired_baseline_after_failure "$_oa_failed_result" "$NEW_TARGET_PKG"
                return $?
            fi
            if [ "$NEW_BASELINE_OWNER" = "external" ] \
                && ! record_current_fas_lease_identity; then
                restore_desired_baseline_after_failure "failed_capture_fas_lease_identity" "$NEW_TARGET_PKG"
                return $?
            fi
            if ! write_sched_owner external; then
                restore_desired_baseline_after_failure "failed_write_external_owner" "$NEW_TARGET_PKG"
                return $?
            fi
            if [ -z "$NEW_TARGET_PKG" ] \
                || ! write_fas_owner_state "fas-rs:game:$NEW_TARGET_PKG"; then
                restore_desired_baseline_after_failure "failed_write_fas_owner_state" "$NEW_TARGET_PKG"
                return $?
            fi
            if ! verify_fas_baseline; then
                restore_desired_baseline_after_failure "failed_verify_fas_rs_game" "$NEW_TARGET_PKG"
                return $?
            fi
            if [ "$CPUFREQ_RESTORE_VERIFIED" = "yes" ]; then
                APPLY_RESULT="applied_fas_rs_game_cpufreq_verified"
            elif [ "$CPUFREQ_RESTORED" = "yes" ]; then
                APPLY_RESULT="applied_fas_rs_game_cpufreq_restored"
            elif [ "$CPUFREQ_RESTORE_SKIPPED" = "yes" ]; then
                APPLY_RESULT="applied_fas_rs_game_cpufreq_restore_skipped"
            else
                APPLY_RESULT="applied_fas_rs_game"
            fi
            ;;
        BASELINE_NORMAL)
            case "$NEW_BASELINE_OWNER" in
                external)
                    if verify_ugt_baseline unknown; then
                        APPLY_RESULT="stable_ugt_noop"
                        APPLY_STABLE_NOOP="yes"
                    elif [ "$PREV_STATE" = "FAS_LEASED_GAME" ] \
                        || [ "$PREV_STATE" = "EXIT_HOLD" ] \
                        || fas_game_lease_active; then
                        owner_guard_begin "baseline:external:${NEW_BASELINE_UCLAMP_CAP}" || return 1
                        apply_ugt_baseline || return 1
                    else
                        APPLY_RESULT="ugt_baseline_drift_health_required"
                        APPLY_STABLE_NOOP="yes"
                        return 1
                    fi
                    ;;
                pixel)
                    if verify_pixel_baseline; then
                        APPLY_RESULT="stable_pixel_noop"
                        APPLY_STABLE_NOOP="yes"
                    else
                        if [ "$(read_pixel_owner)" = "pixel" ] \
                            && ! fas_game_lease_active; then
                            APPLY_RESULT="profile_drift_health_required"
                            APPLY_STABLE_NOOP="yes"
                            return 1
                        fi
                        owner_guard_begin "baseline:pixel:$(read_valid_pixel_profile)" || return 1
                        apply_pixel_baseline || return 1
                    fi
                    ;;
                *) APPLY_RESULT="failed_invalid_desired_owner"; return 1 ;;
            esac
            ;;
        *)
            APPLY_RESULT="apply_noop:$NEW_STATE"
            ;;
    esac
    return 0
}

if [ "$ACTION" = "status" ]; then
    cat "$ARB_STATE_FILE" 2>/dev/null
    tail -n 5 "$ARB_HISTORY_FILE" 2>/dev/null
    exit 0
fi

NOW=$(now_epoch)
CURRENT_OWNER=$(read_pixel_owner)
DESIRED_OWNER=$(read_desired_owner)
HANDOFF_POLICY=$(read_game_handoff_policy)
load_previous_state
PREV_TARGET_PID=$(num_or_zero "$PREV_TARGET_PID")
PREV_CANDIDATE_SINCE=$(num_or_zero "$PREV_CANDIDATE_SINCE")
PREV_LEASE_START=$(num_or_zero "$PREV_LEASE_START")
PREV_LAST_FOREGROUND=$(num_or_zero "$PREV_LAST_FOREGROUND")
PREV_PID_ABSENT_SINCE=$(num_or_zero "$PREV_PID_ABSENT_SINCE")
PREV_CPUFREQ_RESTORE_LEASE=$(num_or_zero "$PREV_CPUFREQ_RESTORE_LEASE")
PREV_CPUFREQ_RESTORE_EPOCH=$(num_or_zero "$PREV_CPUFREQ_RESTORE_EPOCH")
PREV_LEASE_FAS_PID=$(num_or_zero "$PREV_LEASE_FAS_PID")
PREV_LEASE_FAS_START_TICKS=$(num_or_zero "$PREV_LEASE_FAS_START_TICKS")
case "$PREV_BASELINE_OWNER" in external|pixel) ;; *) PREV_BASELINE_OWNER="$DESIRED_OWNER" ;; esac
uclamp_cap_is_valid "$PREV_BASELINE_UCLAMP_CAP" || PREV_BASELINE_UCLAMP_CAP="unknown"

NEW_STATE="BASELINE_NORMAL"
NEW_TARGET_PKG=""
NEW_TARGET_PID="0"
NEW_CANDIDATE_SINCE="0"
NEW_LEASE_START="0"
NEW_LAST_FOREGROUND="0"
NEW_PID_ABSENT_SINCE="0"
NEW_BASELINE_OWNER="$DESIRED_OWNER"
if [ "$PREV_BASELINE_OWNER" = "$DESIRED_OWNER" ] \
    && uclamp_cap_is_valid "$PREV_BASELINE_UCLAMP_CAP"; then
    NEW_BASELINE_UCLAMP_CAP="$PREV_BASELINE_UCLAMP_CAP"
elif [ "$DESIRED_OWNER" = "external" ]; then
    NEW_BASELINE_UCLAMP_CAP=$(read_uclamp_cap)
else
    NEW_BASELINE_UCLAMP_CAP=$(expected_pixel_uclamp_cap)
fi
uclamp_cap_is_valid "$NEW_BASELINE_UCLAMP_CAP" || NEW_BASELINE_UCLAMP_CAP="unknown"
NEW_LEASE_FAS_PID="$PREV_LEASE_FAS_PID"
NEW_LEASE_FAS_START_TICKS="$PREV_LEASE_FAS_START_TICKS"
PROPOSED_OWNER="$DESIRED_OWNER"
REASON="no_target_focus"
FOCUS_PKG=""
FOCUS_PIDS=""
FOCUS_PID="0"
GAME_SOURCE="none"
GAME_MATCH="no"

case "$SCREEN_STATE" in
    on) ;;
    *)
        printf '%s\n' "screen_${SCREEN_STATE}_noop"
        exit 0
        ;;
esac

if [ -f "$ARB_DISABLE_FILE" ]; then
    NEW_STATE="ARB_DISABLED"
    NEW_TARGET_PKG="$PREV_TARGET_PKG"
    NEW_TARGET_PID="$PREV_TARGET_PID"
    NEW_CANDIDATE_SINCE="$PREV_CANDIDATE_SINCE"
    NEW_LEASE_START="$PREV_LEASE_START"
    NEW_LAST_FOREGROUND="$PREV_LAST_FOREGROUND"
    NEW_PID_ABSENT_SINCE="$PREV_PID_ABSENT_SINCE"
    NEW_BASELINE_OWNER="$PREV_BASELINE_OWNER"
    NEW_BASELINE_UCLAMP_CAP="$PREV_BASELINE_UCLAMP_CAP"
    NEW_LEASE_FAS_PID="$PREV_LEASE_FAS_PID"
    NEW_LEASE_FAS_START_TICKS="$PREV_LEASE_FAS_START_TICKS"
    PROPOSED_OWNER="$CURRENT_OWNER"
    REASON="arbiter_disabled"
    APPLY_RESULT="arbiter_disabled_noop"
    state_snapshot_matches && exit 0
    if ! so_acquire_transition_lock; then
        exit 75
    fi
    trap 'so_release_transition_lock >/dev/null 2>&1 || true' EXIT
    trap 'so_release_transition_lock >/dev/null 2>&1 || true; exit 130' INT
    trap 'so_release_transition_lock >/dev/null 2>&1 || true; exit 143' TERM
    [ -f "$ARB_DISABLE_FILE" ] || exit 0
    sbm_load_state
    _oa_disabled_mode=$(sbm_owner_to_mode "$DESIRED_OWNER")
    [ "$SBM_PHASE" = "success" ] && [ "$SBM_EFFECTIVE_MODE" = "$_oa_disabled_mode" ] || exit 0
    so_migrate_state >/dev/null 2>&1 || exit 66
    _oa_disabled_desired=$(read_desired_owner)
    _oa_disabled_effective=$(read_pixel_owner)
    _oa_disabled_handoff=$(read_game_handoff_policy)
    [ "$_oa_disabled_desired" = "$DESIRED_OWNER" ] \
        && [ "$_oa_disabled_effective" = "$CURRENT_OWNER" ] \
        && [ "$_oa_disabled_handoff" = "$HANDOFF_POLICY" ] || exit 0
    write_state || exit 74
    append_history
    so_release_transition_lock >/dev/null 2>&1 || true
    trap - EXIT INT TERM
    exit 0
fi

# One pass populates UGT, fas-rs, and the selected external scheduler. No
# external scheduler is a valid state, so a no-match return does not abort.
detect_external_scheduler 2>/dev/null
_oa_detect_rc=$?
if [ "$_oa_detect_rc" -gt 1 ] 2>/dev/null; then
    printf '%s\n' "scheduler_inventory_${SCHEDULER_INVENTORY_STATUS}_noop"
    exit 78
fi
if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
    UPERF_DETECTED="${OWNER_ARBITER_TEST_UPERF_DETECTED:-yes}"
    UPERF_MODULE_ENABLED="${OWNER_ARBITER_TEST_UPERF_ENABLED:-yes}"
    FAS_RS_DETECTED="${OWNER_ARBITER_TEST_FAS_DETECTED:-yes}"
    FAS_RS_MODULE_ENABLED="${OWNER_ARBITER_TEST_FAS_ENABLED:-yes}"
    FAS_RS_PROCESS_ALIVE="no"
    FAS_RS_ACTIVE="no"
    EXTERNAL_SCHEDULER_DETECTED="yes"
    EXTERNAL_SCHEDULER_ACTIVE="no"
    EXTERNAL_SCHEDULER_KIND="test"
fi

sbm_load_state
_oa_verified_mode=$(sbm_owner_to_mode "$DESIRED_OWNER")
if [ "$SBM_PHASE" != "success" ] || [ "$SBM_EFFECTIVE_MODE" != "$_oa_verified_mode" ]; then
    printf '%s\n' "scheduler_boot_${SBM_PHASE:-unknown}_${SBM_EFFECTIVE_MODE:-unknown}_noop"
    exit 0
fi

FOCUS_PKG=$(foreground_package_name)
FOCUS_PIDS=$(pkg_pids "$FOCUS_PKG")
FOCUS_PID=$(first_word "$FOCUS_PIDS")
[ -n "$FOCUS_PID" ] || FOCUS_PID="0"

if [ "$HANDOFF_POLICY" = "fas_rs" ]; then
    if fas_handoff_available; then
        package_matches_fas_target "$FOCUS_PKG" && GAME_MATCH="yes"
    else
        GAME_SOURCE="fas_module_unavailable"
    fi
else
    GAME_SOURCE="handoff_off"
fi

if [ "$HANDOFF_POLICY" != "fas_rs" ] && { [ "$PREV_STATE" = "FAS_LEASED_GAME" ] || [ "$PREV_STATE" = "EXIT_HOLD" ] || [ "$PREV_STATE" = "GAME_CANDIDATE" ]; }; then
    NEW_STATE="BASELINE_NORMAL"
    NEW_BASELINE_OWNER="$PREV_BASELINE_OWNER"
    NEW_BASELINE_UCLAMP_CAP="$PREV_BASELINE_UCLAMP_CAP"
    PROPOSED_OWNER="$PREV_BASELINE_OWNER"
    REASON="game_handoff_disabled"
elif [ "$GAME_MATCH" = "yes" ]; then
    NEW_TARGET_PKG="$FOCUS_PKG"
    NEW_TARGET_PID="$FOCUS_PID"
    NEW_LAST_FOREGROUND="$NOW"
    NEW_PID_ABSENT_SINCE="0"

    if [ "$PREV_TARGET_PKG" = "$FOCUS_PKG" ] && [ "$PREV_CANDIDATE_SINCE" -gt 0 ] 2>/dev/null; then
        NEW_CANDIDATE_SINCE="$PREV_CANDIDATE_SINCE"
    else
        NEW_CANDIDATE_SINCE="$NOW"
    fi

    _oa_candidate_elapsed=$((NOW - NEW_CANDIDATE_SINCE))
    if [ "$_oa_candidate_elapsed" -ge "$ENTER_DEBOUNCE_S" ] 2>/dev/null; then
        NEW_STATE="FAS_LEASED_GAME"
        if [ "$PREV_TARGET_PKG" = "$FOCUS_PKG" ] && [ "$PREV_LEASE_START" -gt 0 ] 2>/dev/null; then
            NEW_LEASE_START="$PREV_LEASE_START"
            NEW_BASELINE_OWNER="$PREV_BASELINE_OWNER"
            NEW_BASELINE_UCLAMP_CAP="$PREV_BASELINE_UCLAMP_CAP"
        else
            NEW_LEASE_START="$NOW"
            NEW_BASELINE_OWNER="$DESIRED_OWNER"
        fi
        PROPOSED_OWNER="external"
        REASON="target_game_debounced"
    else
        NEW_STATE="GAME_CANDIDATE"
        NEW_LEASE_START="$PREV_LEASE_START"
        PROPOSED_OWNER="$CURRENT_OWNER"
        REASON="enter_debounce"
    fi
elif [ -n "$PREV_TARGET_PKG" ] && { [ "$PREV_STATE" = "FAS_LEASED_GAME" ] || [ "$PREV_STATE" = "EXIT_HOLD" ]; }; then
    NEW_TARGET_PKG="$PREV_TARGET_PKG"
    NEW_CANDIDATE_SINCE="$PREV_CANDIDATE_SINCE"
    NEW_LEASE_START="$PREV_LEASE_START"
    NEW_LAST_FOREGROUND="$PREV_LAST_FOREGROUND"
    [ "$NEW_LEASE_START" -gt 0 ] 2>/dev/null || NEW_LEASE_START="$NOW"
    _oa_target_pids=$(pkg_pids "$PREV_TARGET_PKG")
    _oa_target_pid=$(first_word "$_oa_target_pids")
    [ -n "$_oa_target_pid" ] || _oa_target_pid="0"
    NEW_TARGET_PID="$_oa_target_pid"

    if [ -z "$_oa_target_pids" ]; then
        if [ "$PREV_PID_ABSENT_SINCE" -gt 0 ] 2>/dev/null; then
            NEW_PID_ABSENT_SINCE="$PREV_PID_ABSENT_SINCE"
        else
            NEW_PID_ABSENT_SINCE="$NOW"
        fi
        _oa_absent_elapsed=$((NOW - NEW_PID_ABSENT_SINCE))
        if [ "$_oa_absent_elapsed" -ge "$PID_ABSENT_CONFIRM_S" ] 2>/dev/null; then
            NEW_STATE="BASELINE_NORMAL"
            NEW_BASELINE_OWNER="$PREV_BASELINE_OWNER"
            NEW_BASELINE_UCLAMP_CAP="$PREV_BASELINE_UCLAMP_CAP"
            PROPOSED_OWNER="$PREV_BASELINE_OWNER"
            REASON="target_pid_absent"
        else
            NEW_STATE="EXIT_HOLD"
            PROPOSED_OWNER="external"
            REASON="pid_absent_confirming"
        fi
    else
        NEW_PID_ABSENT_SINCE="0"
        _oa_lease_elapsed=$((NOW - NEW_LEASE_START))
        _oa_idle_elapsed=$((NOW - NEW_LAST_FOREGROUND))
        if [ "$_oa_lease_elapsed" -lt "$MIN_LEASE_S" ] 2>/dev/null; then
            NEW_STATE="EXIT_HOLD"
            PROPOSED_OWNER="external"
            REASON="min_lease_hold"
        elif [ "$_oa_idle_elapsed" -lt "$EXIT_IDLE_AFTER_S" ] 2>/dev/null; then
            NEW_STATE="EXIT_HOLD"
            PROPOSED_OWNER="external"
            REASON="recent_foreground_hold"
        else
            NEW_STATE="BASELINE_NORMAL"
            NEW_BASELINE_OWNER="$PREV_BASELINE_OWNER"
            NEW_BASELINE_UCLAMP_CAP="$PREV_BASELINE_UCLAMP_CAP"
            PROPOSED_OWNER="$PREV_BASELINE_OWNER"
            REASON="exit_idle_expired"
        fi
    fi
fi

if [ "$APPLY_ENABLED" = "yes" ]; then
    case "$NEW_STATE" in
        FAS_LEASED_GAME|EXIT_HOLD)
            if verify_fas_baseline; then
                APPLY_RESULT="stable_fas_noop"
                APPLY_STABLE_NOOP="yes"
                state_snapshot_matches && exit 0
            elif uperf_process_alive; then
                APPLY_RESULT="blocked_uperf_residue_for_fas"
                APPLY_STABLE_NOOP="yes"
                state_snapshot_matches && exit 0
            fi
            ;;
        BASELINE_NORMAL)
            if [ "$DESIRED_OWNER" = "pixel" ]; then
                if verify_pixel_baseline; then
                    APPLY_RESULT="stable_pixel_noop"
                    APPLY_STABLE_NOOP="yes"
                    state_snapshot_matches && exit 0
                elif [ "$CURRENT_OWNER" = "pixel" ] \
                    && ! uperf_process_alive && ! fas_game_lease_active; then
                    APPLY_RESULT="profile_drift_health_required"
                    APPLY_STABLE_NOOP="yes"
                    state_snapshot_matches && exit 0
                fi
            fi
            ;;
    esac
fi

_oa_prelock_guard_key=""
case "$NEW_STATE" in
    FAS_LEASED_GAME|EXIT_HOLD)
        _oa_prelock_guard_key="fas:${NEW_BASELINE_OWNER}:${NEW_TARGET_PKG}"
        ;;
    BASELINE_NORMAL)
        case "$NEW_BASELINE_OWNER" in
            external)
                if [ "$PREV_STATE" = "FAS_LEASED_GAME" ] \
                    || [ "$PREV_STATE" = "EXIT_HOLD" ] \
                    || fas_game_lease_active; then
                    _oa_prelock_guard_key="baseline:external:${NEW_BASELINE_UCLAMP_CAP}"
                fi
                ;;
            pixel)
                if [ "$CURRENT_OWNER" != "pixel" ] \
                    || fas_game_lease_target >/dev/null 2>&1; then
                    _oa_prelock_guard_key="baseline:pixel:$(read_valid_pixel_profile)"
                fi
                ;;
        esac
        ;;
esac
if [ -n "$_oa_prelock_guard_key" ] \
    && owner_guard_is_terminal "$_oa_prelock_guard_key"; then
    exit 78
fi

_oa_transition_lock_acquired=0
if [ "$APPLY_ENABLED" = "yes" ]; then
    if ! so_acquire_transition_lock; then
        APPLY_RESULT="transition_busy"
        exit 75
    fi
    _oa_transition_lock_acquired=1
    trap 'so_release_transition_lock >/dev/null 2>&1 || true' EXIT
    trap 'so_release_transition_lock >/dev/null 2>&1 || true; exit 130' INT
    trap 'so_release_transition_lock >/dev/null 2>&1 || true; exit 143' TERM

    so_migrate_state >/dev/null 2>&1 || exit 66
    sbm_load_state
    _oa_locked_desired=$(read_desired_owner)
    _oa_locked_effective=$(read_pixel_owner)
    _oa_locked_handoff=$(read_game_handoff_policy)
    _oa_locked_mode=$(sbm_owner_to_mode "$_oa_locked_desired")
    if [ "$SBM_PHASE" != "success" ] || [ "$SBM_EFFECTIVE_MODE" != "$_oa_locked_mode" ] \
        || [ "$_oa_locked_desired" != "$DESIRED_OWNER" ] \
        || [ "$_oa_locked_effective" != "$CURRENT_OWNER" ] \
        || [ "$_oa_locked_handoff" != "$HANDOFF_POLICY" ] \
        || { [ "$APPLY_REQUESTED" != "yes" ] && [ "$(read_runtime_apply_enabled)" != "yes" ]; } \
        || [ -f "$ARB_DISABLE_FILE" ]; then
        APPLY_RESULT=decision_superseded
        so_release_transition_lock >/dev/null 2>&1 || true
        trap - EXIT INT TERM
        exit 0
    fi
fi

_oa_apply_rc=0
apply_owner_decision >/dev/null 2>&1 || _oa_apply_rc=$?
if [ "$APPLY_MUTATION_GUARD_ACTIVE" = "yes" ]; then
    if [ "$_oa_apply_rc" -eq 0 ]; then
        stg_record_success "$APPLY_RESULT" >/dev/null 2>&1 \
            || { APPLY_RESULT="failed_owner_guard_success_commit"; _oa_apply_rc=74; }
    else
        _oa_guard_now=$(now_epoch)
        _oa_guard_commit_rc=0
        stg_record_failure "$_oa_guard_now" "$APPLY_RESULT" >/dev/null 2>&1 \
            || _oa_guard_commit_rc=$?
        if [ "$_oa_guard_commit_rc" -eq 74 ]; then
            APPLY_RESULT="${APPLY_RESULT}_guard_terminal_unavailable"
            _oa_apply_rc=74
        else
            stg_load
            if [ "$STG_TERMINAL" = "yes" ]; then
                APPLY_RESULT="${APPLY_RESULT}_latched"
            fi
        fi
    fi
fi
if [ "$APPLY_STABLE_NOOP" = "yes" ] && state_snapshot_matches; then
    if [ "$_oa_transition_lock_acquired" -eq 1 ]; then
        so_release_transition_lock >/dev/null 2>&1 || true
    fi
    trap - EXIT INT TERM
    exit 0
fi
if ! write_state; then
    log -t pixel9pro_ctrl "ERROR: owner arbiter state commit failed"
    _oa_apply_rc=74
fi
append_history
if [ "$_oa_transition_lock_acquired" -eq 1 ]; then
    so_release_transition_lock >/dev/null 2>&1 || true
fi
trap - EXIT INT TERM
exit "$_oa_apply_rc"
