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

scheduler_owner_init "$MODDIR" "$FAS_ROOT"
sbm_init "$MODDIR" "$FAS_ROOT"

now_epoch() {
    date +%s 2>/dev/null || echo 0
}

num_or_zero() {
    case "$1" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$1" ;;
    esac
}

safe_field() {
    printf '%s' "$1" | tr '|\r\n' '___'
}

read_pixel_owner() {
    so_read_effective_owner
}

read_desired_owner() {
    so_read_desired_owner
}

read_game_handoff_policy() {
    so_read_handoff_policy
}

load_previous_state() {
    PREV_STATE=""
    PREV_TARGET_PKG=""
    PREV_TARGET_PID="0"
    PREV_CANDIDATE_SINCE="0"
    PREV_LEASE_START="0"
    PREV_LAST_FOREGROUND="0"
    PREV_PID_ABSENT_SINCE="0"
    PREV_BASELINE_OWNER=""
    PREV_DESIRED_OWNER=""
    PREV_HANDOFF_POLICY=""
    PREV_EFFECTIVE_OWNER=""
    PREV_PROPOSED_OWNER=""
    PREV_REASON=""
    PREV_APPLY_ENABLED=""
    PREV_APPLY_RESULT=""
    PREV_CPUFREQ_RESTORE_LEASE="0"
    PREV_CPUFREQ_RESTORE_EPOCH="0"
    PREV_BASELINE_UCLAMP_CAP="unknown"
    PREV_LEASE_FAS_PID="0"
    PREV_LEASE_FAS_START_TICKS="0"
    [ -s "$ARB_STATE_FILE" ] || return 0

    while IFS='=' read -r _oa_state_key _oa_state_value; do
        case "$_oa_state_key" in
            state) PREV_STATE="$_oa_state_value" ;;
            target_pkg) PREV_TARGET_PKG="$_oa_state_value" ;;
            target_pid) PREV_TARGET_PID="$_oa_state_value" ;;
            candidate_since) PREV_CANDIDATE_SINCE="$_oa_state_value" ;;
            lease_start) PREV_LEASE_START="$_oa_state_value" ;;
            last_foreground) PREV_LAST_FOREGROUND="$_oa_state_value" ;;
            pid_absent_since) PREV_PID_ABSENT_SINCE="$_oa_state_value" ;;
            baseline_owner) PREV_BASELINE_OWNER="$_oa_state_value" ;;
            desired_owner) PREV_DESIRED_OWNER="$_oa_state_value" ;;
            effective_owner) PREV_EFFECTIVE_OWNER="$_oa_state_value" ;;
            proposed_owner) PREV_PROPOSED_OWNER="$_oa_state_value" ;;
            reason) PREV_REASON="$_oa_state_value" ;;
            apply_enabled) PREV_APPLY_ENABLED="$_oa_state_value" ;;
            apply_result) PREV_APPLY_RESULT="$_oa_state_value" ;;
            game_handoff_policy) PREV_HANDOFF_POLICY="$_oa_state_value" ;;
            cpufreq_restore_lease) PREV_CPUFREQ_RESTORE_LEASE="$_oa_state_value" ;;
            cpufreq_restore_epoch) PREV_CPUFREQ_RESTORE_EPOCH="$_oa_state_value" ;;
            baseline_uclamp_cap) PREV_BASELINE_UCLAMP_CAP="$_oa_state_value" ;;
            lease_fas_pid) PREV_LEASE_FAS_PID="$_oa_state_value" ;;
            lease_fas_start_ticks) PREV_LEASE_FAS_START_TICKS="$_oa_state_value" ;;
        esac
    done < "$ARB_STATE_FILE"
}

first_word() {
    set -- $1
    printf '%s' "$1"
}

pkg_pids() {
    _oa_pkg="$1"
    [ -n "$_oa_pkg" ] || return 0

    _oa_pids=$(pidof "$_oa_pkg" 2>/dev/null)
    if [ -z "$_oa_pids" ]; then
        _oa_pids=$(ps -A 2>/dev/null | awk -v p="$_oa_pkg" '
            NR > 1 {
                name = $NF
                if (name == p || index(name, p ":") == 1) {
                    printf "%s ", $2
                }
            }
        ')
    fi
    printf '%s' "$_oa_pids" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g;s/^ //;s/ $//'
}

foreground_package_name() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        if [ -n "${OWNER_ARBITER_TEST_FOREGROUND_COUNTER_PATH:-}" ]; then
            _oa_focus_count=$(cat "$OWNER_ARBITER_TEST_FOREGROUND_COUNTER_PATH" 2>/dev/null | tr -d ' \r\n\t')
            case "$_oa_focus_count" in ''|*[!0-9]*) _oa_focus_count=0 ;; esac
            printf '%s\n' $((_oa_focus_count + 1)) > "$OWNER_ARBITER_TEST_FOREGROUND_COUNTER_PATH" 2>/dev/null || true
        fi
        printf '%s' "${OWNER_ARBITER_TEST_FOCUS_PKG:-com.android.launcher}"
        return
    fi
    # Android 17 may list Launcher before the real foreground app in
    # `dumpsys activity top` while `dumpsys window` still reports the focused
    # game correctly.  Prefer WindowManager focus and use ActivityTaskManager
    # only as a fallback.  Some transient overlays (NotificationShade,
    # keyguard/bouncer) can appear earlier in the window dump than mFocusedApp
    # and do not contain a package/activity pair; scan by priority and skip
    # unparsable lines instead of taking the first matching line globally.
    _oa_dump=$(dumpsys window 2>/dev/null)
    _oa_pkg=""
    for _oa_prefix in "mFocusedApp=" "mCurrentFocus=" "mFocusedWindow=" "topResumedActivity=" "ResumedActivity:"; do
        _oa_pkg=$(printf '%s\n' "$_oa_dump" | awk -v prefix="$_oa_prefix" '
            {
                line = $0
                sub(/^[ \t]+/, "", line)
                if (index(line, prefix) == 1) print line
            }
        ' | sed -n '
            s/.*[[:space:]]u[0-9][0-9]*[[:space:]]\([^/ }][^/ }]*\)\/.*/\1/p
            s/.*[[:space:]]\([A-Za-z0-9_.$][A-Za-z0-9_.$]*\)\/.*/\1/p
        ' | head -n 1)
        [ -n "$_oa_pkg" ] && break
    done
    if [ -z "$_oa_pkg" ]; then
        _oa_pkg=$(dumpsys activity top 2>/dev/null | sed -n 's/^  ACTIVITY \([^/ ][^/ ]*\)\/.*/\1/p' | head -n 1)
    fi
    printf '%s' "$_oa_pkg" | tr -d ' \r\n\t'
}

game_source_kind() {
    case "$1" in
        "$LEASE_GAME_LIST") printf 'lease_list' ;;
        "$SCENE_PROFILE") printf 'scene_games_xml' ;;
        *.toml) printf 'games_toml' ;;
        *) printf 'unknown' ;;
    esac
}

primary_games_toml_path() {
    for _oa_file in "$FAS_ROOT/games.toml"; do
        [ -s "$_oa_file" ] || continue
        printf '%s' "$_oa_file"
        return 0
    done

    case "$FAS_RS_MODULE_PATH" in
        /data/adb/modules/*)
            if [ -s "$FAS_RS_MODULE_PATH/games.toml" ]; then
                printf '%s' "$FAS_RS_MODULE_PATH/games.toml"
                return 0
            fi
            ;;
    esac

    if [ -s /data/adb/modules/fas_rs/games.toml ]; then
        printf '%s' /data/adb/modules/fas_rs/games.toml
        return 0
    fi

    return 1
}

package_in_lease_list() {
    _oa_pkg="$1"
    [ -n "$_oa_pkg" ] && [ -s "$LEASE_GAME_LIST" ] || return 1
    awk -v p="$_oa_pkg" '$0 == p { found = 1 } END { exit(found ? 0 : 1) }' "$LEASE_GAME_LIST" 2>/dev/null
}

package_in_games_toml() {
    _oa_pkg="$1"
    _oa_source="$2"
    [ -n "$_oa_pkg" ] && [ -s "$_oa_source" ] || return 1

    awk -v p="$_oa_pkg" '
        /^[[:space:]]*\[game_list\][[:space:]]*$/ { in_game = 1; next }
        /^[[:space:]]*\[/ { in_game = 0 }
        in_game && /^[[:space:]]*"/ {
            line = $0
            sub(/^[[:space:]]*"/, "", line)
            sub(/".*/, "", line)
            if (line == p) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$_oa_source" 2>/dev/null
}

package_excluded_by_games_toml() {
    _oa_pkg="$1"
    _oa_source="$2"
    [ -n "$_oa_pkg" ] && [ -s "$_oa_source" ] || return 1

    awk -v p="$_oa_pkg" '
        /^[[:space:]]*\[config\][[:space:]]*$/ { in_config = 1; next }
        /^[[:space:]]*\[/ { in_config = 0 }
        in_config && /^[[:space:]]*exclude_list[[:space:]]*=/ {
            line = $0
            sub(/^[^[]*\[/, "", line)
            sub(/\].*$/, "", line)
            n = split(line, items, ",")
            for (i = 1; i <= n; i++) {
                item = items[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
                gsub(/^"|"$/, "", item)
                if (item == p) found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$_oa_source" 2>/dev/null
}

scene_game_list_enabled_by_toml() {
    _oa_source="$1"
    [ -s "$_oa_source" ] || return 1

    awk '
        BEGIN { seen = 0; enabled = 1 }
        /^[[:space:]]*\[config\][[:space:]]*$/ { in_config = 1; next }
        /^[[:space:]]*\[/ { in_config = 0 }
        in_config && /^[[:space:]]*scene_game_list[[:space:]]*=/ {
            seen = 1
            line = $0
            sub(/^[^=]*=/, "", line)
            gsub(/[[:space:]]|"/, "", line)
            if (line == "false") enabled = 0
            else enabled = 1
        }
        END { exit(enabled ? 0 : 1) }
    ' "$_oa_source" 2>/dev/null
}

package_in_scene_profile() {
    _oa_pkg="$1"
    [ -n "$_oa_pkg" ] && [ -s "$SCENE_PROFILE" ] || return 1

    awk -v p="$_oa_pkg" '
        /<boolean/ && /value="true"/ {
            line = $0
            sub(/^.*name="/, "", line)
            sub(/".*$/, "", line)
            if (line == p) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$SCENE_PROFILE" 2>/dev/null
}

package_matches_fas_target() {
    _oa_pkg="$1"
    GAME_SOURCE="none"
    [ -n "$_oa_pkg" ] || return 1

    _oa_toml=$(primary_games_toml_path 2>/dev/null)

    if [ -n "$_oa_toml" ] && package_excluded_by_games_toml "$_oa_pkg" "$_oa_toml"; then
        GAME_SOURCE="$(game_source_kind "$_oa_toml"):exclude_list"
        return 1
    fi

    if package_in_lease_list "$_oa_pkg"; then
        GAME_SOURCE="$LEASE_GAME_LIST"
        return 0
    fi

    if [ -n "$_oa_toml" ] && package_in_games_toml "$_oa_pkg" "$_oa_toml"; then
        GAME_SOURCE="$_oa_toml"
        return 0
    fi

    if [ -n "$_oa_toml" ] && scene_game_list_enabled_by_toml "$_oa_toml" && package_in_scene_profile "$_oa_pkg"; then
        GAME_SOURCE="$SCENE_PROFILE"
        return 0
    fi

    if [ -n "$_oa_toml" ]; then
        GAME_SOURCE="$_oa_toml"
    fi
    return 1
}

fas_handoff_available() {
    [ "$FAS_RS_DETECTED" = "yes" ] || return 1
    [ "$FAS_RS_MODULE_ENABLED" = "yes" ] || return 1
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        [ ! -f "$TEST_RUNTIME_DIR/fas_payload_incomplete" ] || return 1
        return 0
    fi
    [ "$FAS_RS_MODULE_SOURCE" = "modules" ] || return 1
    [ "$(scheduler_module_state "$FAS_RS_MODULE_PATH" "$FAS_RS_MODULE_SOURCE")" = "active" ] || return 1
    [ -f "$FAS_RS_MODULE_PATH/fas-rs" ] || return 1
    [ -s "$FAS_RS_MODULE_PATH/games.toml" ] || return 1
    _oa_payload_router="$FAS_RS_MODULE_PATH/vtools/powercfg.sh"
    [ -s "$_oa_payload_router" ] || return 1
    grep -q '/data/adb/fas_rs/.owner_state' "$_oa_payload_router" 2>/dev/null || return 1
    sh -n "$_oa_payload_router" >/dev/null 2>&1 || return 1
    return 0
}

process_alive() {
    _oa_proc="$1"
    pidof "$_oa_proc" >/dev/null 2>&1 && return 0
    ps -A 2>/dev/null | grep -E "(^|[[:space:]])${_oa_proc}([[:space:]]|$)" | grep -v grep >/dev/null 2>&1
}

pid_alive() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$1" ]
}

process_start_ticks() {
    _oa_pid="$1"
    case "$_oa_pid" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        _oa_test_pid=$(cat "$TEST_RUNTIME_DIR/fas_pid" 2>/dev/null | tr -d ' \r\n\t')
        [ -n "$_oa_test_pid" ] || _oa_test_pid=4242
        [ "$_oa_pid" = "$_oa_test_pid" ] || return 1
        _oa_test_ticks=$(cat "$TEST_RUNTIME_DIR/fas_start_ticks" 2>/dev/null | tr -d ' \r\n\t')
        case "$_oa_test_ticks" in ''|*[!0-9]*) _oa_test_ticks=100 ;; esac
        printf '%s' "$_oa_test_ticks"
        return 0
    fi
    sed 's/^[^)]*) //' "/proc/$_oa_pid/stat" 2>/dev/null | awk '{print $20}'
}

uperf_process_alive() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        if [ -f "$TEST_RUNTIME_DIR/uperf_count" ]; then
            _oa_test_count=$(cat "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null | tr -d ' \r\n\t')
            case "$_oa_test_count" in ''|*[!0-9]*) return 1 ;; esac
            [ "$_oa_test_count" -gt 0 ] 2>/dev/null
            return
        fi
        [ -f "$TEST_RUNTIME_DIR/uperf_alive" ]
        return
    fi
    process_alive "uperf"
}

fas_process_alive() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        [ -f "$TEST_RUNTIME_DIR/fas_alive" ]
        return
    fi
    process_alive "fas-rs"
}

fas_process_pids() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        fas_process_alive || return 0
        _oa_test_pid=$(cat "$TEST_RUNTIME_DIR/fas_pid" 2>/dev/null | tr -d ' \r\n\t')
        [ -n "$_oa_test_pid" ] || _oa_test_pid=4242
        printf '%s' "$_oa_test_pid"
        return 0
    fi
    pidof fas-rs 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g;s/^ //;s/ $//'
}

fas_primary_pid() {
    _oa_pids=$(fas_process_pids)
    first_word "$_oa_pids"
}

fas_identity_matches() {
    _oa_pid="$1"
    _oa_start="$2"
    case "$_oa_pid:$_oa_start" in
        *[!0-9:]*|:*|*:) return 1 ;;
    esac
    fas_process_alive || return 1
    _oa_live_start=$(process_start_ticks "$_oa_pid")
    [ -n "$_oa_live_start" ] && [ "$_oa_live_start" = "$_oa_start" ]
}

fas_game_lease_target() {
    _oa_fas_owner=$(cat "$FAS_OWNER_FILE" 2>/dev/null | tr -d '\r\n')
    scheduler_fas_owner_target "$_oa_fas_owner"
}

fas_game_lease_active() {
    fas_process_alive || return 1
    fas_game_lease_target >/dev/null 2>&1
}

uperf_root_instance_count() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        if [ -f "$TEST_RUNTIME_DIR/uperf_count" ]; then
            _oa_test_count=$(cat "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null | tr -d ' \r\n\t')
            case "$_oa_test_count" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$_oa_test_count" ;; esac
            return
        fi
        [ -f "$TEST_RUNTIME_DIR/uperf_alive" ] && printf '1' || printf '0'
        return
    fi
    _oa_roots=0
    _oa_seen=0
    for _oa_pid in $(pidof uperf 2>/dev/null); do
        case "$_oa_pid" in
            ''|*[!0-9]*) continue ;;
        esac
        _oa_seen=1
        _oa_ppid=$(awk '/^PPid:/{print $2; exit}' "/proc/$_oa_pid/status" 2>/dev/null)
        [ "$_oa_ppid" = "1" ] && _oa_roots=$((_oa_roots + 1))
    done

    if [ "$_oa_seen" -eq 1 ] 2>/dev/null; then
        printf '%s' "$_oa_roots"
        return 0
    fi

    _oa_roots=$(ps -A 2>/dev/null | awk '
        NR > 1 && $NF == "uperf" {
            if ($3 == "1") roots++
        }
        END { print roots + 0 }
    ')
    case "$_oa_roots" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$_oa_roots" ;;
    esac
}

acquire_uperf_start_lock() {
    for _oa_i in 1 2 3 4 5; do
        if mkdir "$UPERF_START_LOCK_DIR" 2>/dev/null; then
            if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
                _oa_lock_start=1
            else
                _oa_lock_start=$(sed 's/^[^)]*) //' "/proc/$$/stat" 2>/dev/null | awk '{print $20}')
            fi
            _oa_lock_boot=$(so_current_boot_id 2>/dev/null)
            if [ -z "$_oa_lock_start" ] || [ -z "$_oa_lock_boot" ] \
                || ! printf '%s\n' "$$" > "$UPERF_START_LOCK_DIR/pid" 2>/dev/null \
                || ! printf '%s\n' "$_oa_lock_start" > "$UPERF_START_LOCK_DIR/start_ticks" 2>/dev/null \
                || ! printf '%s\n' "$_oa_lock_boot" > "$UPERF_START_LOCK_DIR/boot_id" 2>/dev/null; then
                rm -f "$UPERF_START_LOCK_DIR/pid" "$UPERF_START_LOCK_DIR/start_ticks" \
                    "$UPERF_START_LOCK_DIR/boot_id" 2>/dev/null
                rmdir "$UPERF_START_LOCK_DIR" 2>/dev/null
                return 1
            fi
            UPERF_START_LOCK_TICKS="$_oa_lock_start"
            UPERF_START_LOCK_BOOT_ID="$_oa_lock_boot"
            return 0
        fi

        _oa_lock_pid=$(cat "$UPERF_START_LOCK_DIR/pid" 2>/dev/null | tr -d ' \r\n\t')
        _oa_lock_start=$(cat "$UPERF_START_LOCK_DIR/start_ticks" 2>/dev/null | tr -d ' \r\n\t')
        _oa_lock_boot=$(cat "$UPERF_START_LOCK_DIR/boot_id" 2>/dev/null | tr -d ' \r\n\t')
        _oa_current_boot=$(so_current_boot_id 2>/dev/null)
        if [ "$OWNER_ARBITER_TEST_MODE" = "1" ] && pid_alive "$_oa_lock_pid"; then
            _oa_live_start=1
        else
            case "$_oa_lock_pid" in
                ''|*[!0-9]*) _oa_live_start="" ;;
                *) _oa_live_start=$(sed 's/^[^)]*) //' "/proc/$_oa_lock_pid/stat" 2>/dev/null | awk '{print $20}') ;;
            esac
        fi
        if [ -z "$_oa_current_boot" ] || [ "$_oa_lock_boot" != "$_oa_current_boot" ] \
            || ! pid_alive "$_oa_lock_pid" \
            || [ -z "$_oa_lock_start" ] || [ -z "$_oa_live_start" ] \
            || [ "$_oa_live_start" != "$_oa_lock_start" ]; then
            rm -f "$UPERF_START_LOCK_DIR/pid" "$UPERF_START_LOCK_DIR/start_ticks" \
                "$UPERF_START_LOCK_DIR/boot_id" 2>/dev/null
            rmdir "$UPERF_START_LOCK_DIR" 2>/dev/null || true
            continue
        fi
        sleep 1
    done
    return 1
}

release_uperf_start_lock() {
    _oa_lock_pid=$(cat "$UPERF_START_LOCK_DIR/pid" 2>/dev/null | tr -d ' \r\n\t')
    _oa_lock_start=$(cat "$UPERF_START_LOCK_DIR/start_ticks" 2>/dev/null | tr -d ' \r\n\t')
    _oa_lock_boot=$(cat "$UPERF_START_LOCK_DIR/boot_id" 2>/dev/null | tr -d ' \r\n\t')
    [ "$_oa_lock_pid" = "$$" ] \
        && [ -n "${UPERF_START_LOCK_TICKS:-}" ] \
        && [ "$_oa_lock_start" = "$UPERF_START_LOCK_TICKS" ] \
        && [ -n "${UPERF_START_LOCK_BOOT_ID:-}" ] \
        && [ "$_oa_lock_boot" = "$UPERF_START_LOCK_BOOT_ID" ] || return 0
    rm -f "$UPERF_START_LOCK_DIR/pid" "$UPERF_START_LOCK_DIR/start_ticks" \
        "$UPERF_START_LOCK_DIR/boot_id" 2>/dev/null
    rmdir "$UPERF_START_LOCK_DIR" 2>/dev/null || true
    UPERF_START_LOCK_TICKS=""
    UPERF_START_LOCK_BOOT_ID=""
}

normalize_uperf_instances() {
    _oa_roots=$(uperf_root_instance_count)
    [ "$_oa_roots" -gt 1 ] 2>/dev/null || return 0
    UPERF_NORMALIZED="yes"
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        printf '1\n' > "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null || return 1
        printf '1\n' > "$TEST_RUNTIME_DIR/uperf_alive" 2>/dev/null || return 1
        return 0
    fi
    killall uperf 2>/dev/null || true
    for _oa_i in 1 2 3 4 5; do
        sleep 1
        [ "$(uperf_root_instance_count)" -le 1 ] 2>/dev/null && return 0
    done
    return 2
}

uperf_storage_ready() {
    [ "$OWNER_ARBITER_TEST_MODE" = "1" ] && return 0
    [ "$(getprop sys.boot_completed 2>/dev/null | tr -d ' \r\n\t')" = "1" ] || return 1
    [ -d /sdcard/Android ] || [ -d /storage/emulated/0/Android ]
}

uperf_single_instance_stable() {
    for _oa_i in 1 2 3 4 5; do
        sleep 1
        uperf_process_alive || return 1
        _oa_roots=$(uperf_root_instance_count)
        [ "$_oa_roots" -le 1 ] 2>/dev/null || return 2
    done
    return 0
}

write_sched_owner() {
    _oa_target="$1"
    case "$_oa_target" in
        external|pixel) ;;
        *) return 1 ;;
    esac

    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ] \
        && [ -f "$TEST_RUNTIME_DIR/fail_write_sched_owner_once" ]; then
        rm -f "$TEST_RUNTIME_DIR/fail_write_sched_owner_once" 2>/dev/null
        return 1
    fi
    if [ "$(read_pixel_owner)" = "$_oa_target" ]; then
        return 0
    fi
    so_write_effective_owner "$_oa_target"
}

cpufreq_read_one() {
    [ -f "$1" ] || return 1
    head -n 1 "$1" 2>/dev/null | tr -d ' \r\n\t'
}

cpufreq_read_words() {
    [ -f "$1" ] || return 1
    head -n 1 "$1" 2>/dev/null | tr '\r\t' '  ' | sed 's/[[:space:]][[:space:]]*/ /g;s/^ //;s/ $//'
}

cpufreq_write_one() {
    [ -f "$1" ] || return 1
    printf '%s\n' "$2" > "$1" 2>/dev/null
}

cpufreq_choose_base_governor() {
    _oa_policy="$1"
    _oa_avail=$(cpufreq_read_words "$_oa_policy/scaling_available_governors")
    case " $_oa_avail " in
        *" sched_pixel "*) printf 'sched_pixel'; return 0 ;;
        *" schedutil "*) printf 'schedutil'; return 0 ;;
    esac
    return 1
}

policy_cpufreq_lowfreq_present() {
    _oa_policy="$1"
    [ -d "$_oa_policy" ] || return 1

    _oa_gov=$(cpufreq_read_one "$_oa_policy/scaling_governor")
    _oa_min=$(cpufreq_read_one "$_oa_policy/scaling_min_freq")
    _oa_max=$(cpufreq_read_one "$_oa_policy/scaling_max_freq")
    _oa_cpuinfo_max=$(cpufreq_read_one "$_oa_policy/cpuinfo_max_freq")

    case "$_oa_cpuinfo_max" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$_oa_gov" = "powersave" ]; then
        return 0
    fi
    case "$_oa_max" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$_oa_max" -lt "$_oa_cpuinfo_max" ] 2>/dev/null; then
                return 0
            fi
            ;;
    esac
    if [ -n "$_oa_min" ] && [ -n "$_oa_max" ] && [ "$_oa_min" = "$_oa_max" ] && [ "$_oa_max" != "$_oa_cpuinfo_max" ]; then
        return 0
    fi
    return 1
}

thermal_cpu_cooling_active() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        [ "${OWNER_ARBITER_TEST_THERMAL_COOLING_ACTIVE:-no}" = "yes" ]
        return
    fi
    for _oa_cdev in /sys/class/thermal/cooling_device*; do
        [ -d "$_oa_cdev" ] || continue
        _oa_type=$(cat "$_oa_cdev/type" 2>/dev/null | tr -d '\r')
        case "$_oa_type" in
            thermal-cpufreq-*|thermal-uclamp-*|*cpufreq*|*uclamp*)
                _oa_state=$(cat "$_oa_cdev/cur_state" 2>/dev/null | tr -d ' \r\n\t')
                case "$_oa_state" in
                    ''|*[!0-9]*) ;;
                    0) ;;
                    *) return 0 ;;
                esac
                ;;
        esac
    done
    return 1
}

restore_policy_cpufreq_floor() {
    _oa_policy="$1"
    [ -d "$_oa_policy" ] || return 0

    _oa_gov=$(cpufreq_read_one "$_oa_policy/scaling_governor")
    _oa_min=$(cpufreq_read_one "$_oa_policy/scaling_min_freq")
    _oa_max=$(cpufreq_read_one "$_oa_policy/scaling_max_freq")
    _oa_cpuinfo_max=$(cpufreq_read_one "$_oa_policy/cpuinfo_max_freq")
    _oa_cpuinfo_min=$(cpufreq_read_one "$_oa_policy/cpuinfo_min_freq")

    case "$_oa_cpuinfo_max" in ''|*[!0-9]*) return 0 ;; esac
    case "$_oa_cpuinfo_min" in ''|*[!0-9]*) _oa_cpuinfo_min="" ;; esac

    _oa_locked_low="no"
    case "$_oa_max" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$_oa_max" -lt "$_oa_cpuinfo_max" ] 2>/dev/null; then
                _oa_locked_low="yes"
            fi
            ;;
    esac
    if [ -n "$_oa_min" ] && [ -n "$_oa_max" ] && [ "$_oa_min" = "$_oa_max" ] && [ "$_oa_max" != "$_oa_cpuinfo_max" ]; then
        _oa_locked_low="yes"
    fi
    [ "$_oa_gov" = "powersave" ] && _oa_locked_low="yes"
    [ "$_oa_locked_low" = "yes" ] || return 0

    _oa_base_gov=""
    if _oa_base_gov=$(cpufreq_choose_base_governor "$_oa_policy"); then
        # Open the policy floor/ceiling before and after switching governor.
        # UGT / Scene powersave residue often leaves min=max at a low OPP;
        # writing only max is not enough because the next writer can keep the
        # policy locked at the stale floor.  Reset min first, then max, then
        # governor, then repeat min/max as one guarded transaction.
        [ -n "$_oa_cpuinfo_min" ] && cpufreq_write_one "$_oa_policy/scaling_min_freq" "$_oa_cpuinfo_min" || true
        cpufreq_write_one "$_oa_policy/scaling_max_freq" "$_oa_cpuinfo_max" || true
        cpufreq_write_one "$_oa_policy/scaling_governor" "$_oa_base_gov" || true
    fi
    [ -n "$_oa_cpuinfo_min" ] && cpufreq_write_one "$_oa_policy/scaling_min_freq" "$_oa_cpuinfo_min" || true
    cpufreq_write_one "$_oa_policy/scaling_max_freq" "$_oa_cpuinfo_max" || true
    CPUFREQ_RESTORED="yes"

    # Some Android 17/Pixel paths accept the write and are then overwritten by
    # PowerHAL/Scene within the next tick. Verify after a short settle window.
    _oa_settle_s=$(num_or_zero "$CPUFREQ_RESTORE_SETTLE_S")
    [ "$_oa_settle_s" -gt 0 ] 2>/dev/null || _oa_settle_s=2
    sleep "$_oa_settle_s"
    _oa_new_gov=$(cpufreq_read_one "$_oa_policy/scaling_governor")
    _oa_new_min=$(cpufreq_read_one "$_oa_policy/scaling_min_freq")
    _oa_new_max=$(cpufreq_read_one "$_oa_policy/scaling_max_freq")
    if [ "$_oa_new_gov" != "powersave" ] && [ "$_oa_new_max" = "$_oa_cpuinfo_max" ] && { [ -z "$_oa_cpuinfo_min" ] || [ "$_oa_new_min" = "$_oa_cpuinfo_min" ] || [ "$_oa_new_min" -lt "$_oa_new_max" ] 2>/dev/null; }; then
        CPUFREQ_RESTORE_VERIFIED="yes"
        log -t pixel9pro_ctrl "owner_arbiter: verified ${_oa_policy##*/} cpufreq restore from gov=$_oa_gov min=$_oa_min max=$_oa_max to gov=$_oa_new_gov min=$_oa_new_min max=$_oa_new_max for $CPUFREQ_RESTORE_CONTEXT"
    else
        # One guarded second pass catches the common case where the first max
        # write only unlocks the policy after the governor changes.  Do not
        # loop here; repeated overwrites are evidence of an external writer.
        cpufreq_write_one "$_oa_policy/scaling_max_freq" "$_oa_cpuinfo_max" || true
        if [ -n "$_oa_base_gov" ]; then
            cpufreq_write_one "$_oa_policy/scaling_governor" "$_oa_base_gov" || true
        fi
        [ -n "$_oa_cpuinfo_min" ] && cpufreq_write_one "$_oa_policy/scaling_min_freq" "$_oa_cpuinfo_min" || true
        cpufreq_write_one "$_oa_policy/scaling_max_freq" "$_oa_cpuinfo_max" || true
        sleep 1
        _oa_retry_gov=$(cpufreq_read_one "$_oa_policy/scaling_governor")
        _oa_retry_min=$(cpufreq_read_one "$_oa_policy/scaling_min_freq")
        _oa_retry_max=$(cpufreq_read_one "$_oa_policy/scaling_max_freq")
        if [ "$_oa_retry_gov" != "powersave" ] && [ "$_oa_retry_max" = "$_oa_cpuinfo_max" ] && { [ -z "$_oa_cpuinfo_min" ] || [ "$_oa_retry_min" = "$_oa_cpuinfo_min" ] || [ "$_oa_retry_min" -lt "$_oa_retry_max" ] 2>/dev/null; }; then
            CPUFREQ_RESTORE_VERIFIED="yes"
            log -t pixel9pro_ctrl "owner_arbiter: verified ${_oa_policy##*/} cpufreq restore on retry from gov=$_oa_gov min=$_oa_min max=$_oa_max first_after gov=$_oa_new_gov min=$_oa_new_min max=$_oa_new_max final gov=$_oa_retry_gov min=$_oa_retry_min max=$_oa_retry_max for $CPUFREQ_RESTORE_CONTEXT"
        else
            CPUFREQ_RESTORE_FAILED="yes"
            log -t pixel9pro_ctrl "owner_arbiter: cpufreq restore not effective on ${_oa_policy##*/}; before gov=$_oa_gov min=$_oa_min max=$_oa_max requested_gov=${_oa_base_gov:-unchanged} requested_max=$_oa_cpuinfo_max first_after gov=$_oa_new_gov min=$_oa_new_min max=$_oa_new_max retry_after gov=$_oa_retry_gov min=$_oa_retry_min max=$_oa_retry_max"
        fi
    fi
}

restore_scheduler_cpufreq_floor() {
    # UGT/Scene can leave powersave governor and min=max at a low OPP. Repair
    # that residue only during a guarded owner handoff and never fight active
    # ThermalHAL cooling.
    _oa_restore_context="${1:-fas_rs}"
    case "$_oa_restore_context" in
        fas_rs)
            [ "$NEW_STATE" = "FAS_LEASED_GAME" ] || [ "$NEW_STATE" = "EXIT_HOLD" ] || return 0
            [ -n "$NEW_TARGET_PKG" ] || return 0
            _oa_restore_lease=$(num_or_zero "$NEW_LEASE_START")
            CPUFREQ_RESTORE_CONTEXT="fas-rs lease"
            ;;
        pixel)
            [ "$DESIRED_OWNER" = "pixel" ] || return 0
            _oa_restore_lease=0
            CPUFREQ_RESTORE_CONTEXT="Pixel baseline"
            ;;
        *) return 1 ;;
    esac
    _oa_lowfreq_seen="no"
    for _oa_policy in "$CPUFREQ_ROOT"/policy*; do
        if policy_cpufreq_lowfreq_present "$_oa_policy"; then
            _oa_lowfreq_seen="yes"
        fi
    done
    CPUFREQ_LOWFREQ_PRESENT="$_oa_lowfreq_seen"
    [ "$_oa_lowfreq_seen" = "yes" ] || return 0

    if thermal_cpu_cooling_active; then
        CPUFREQ_THERMAL_COOLING_ACTIVE="yes"
        CPUFREQ_RESTORE_SKIPPED="yes"
        CPUFREQ_RESTORE_LEASE="$_oa_restore_lease"
        CPUFREQ_RESTORE_EPOCH="$PREV_CPUFREQ_RESTORE_EPOCH"
        log -t pixel9pro_ctrl "owner_arbiter: skip cpufreq restore for $CPUFREQ_RESTORE_CONTEXT; ThermalHAL CPU cooling active"
        return 0
    fi

    _oa_retry_s=$(num_or_zero "$CPUFREQ_RESTORE_RETRY_S")
    [ "$_oa_retry_s" -gt 0 ] 2>/dev/null || _oa_retry_s=30
    if [ "$PREV_CPUFREQ_RESTORE_EPOCH" -gt 0 ] 2>/dev/null; then
        _oa_since_restore=$((NOW - PREV_CPUFREQ_RESTORE_EPOCH))
    else
        _oa_since_restore=$_oa_retry_s
    fi
    # A new fas-rs lease is the critical handoff window.  Do not let an old
    # idle-owner restore timestamp suppress the first game restore attempt;
    # otherwise UGT powersave residue can survive into WZRY and block X4.
    if [ "$_oa_restore_lease" -gt 0 ] 2>/dev/null && [ "$_oa_restore_lease" != "$PREV_CPUFREQ_RESTORE_LEASE" ]; then
        _oa_since_restore=$_oa_retry_s
    fi
    if [ "$_oa_since_restore" -lt "$_oa_retry_s" ] 2>/dev/null; then
        CPUFREQ_RESTORE_SKIPPED="yes"
        CPUFREQ_RESTORE_LEASE="$_oa_restore_lease"
        CPUFREQ_RESTORE_EPOCH="$PREV_CPUFREQ_RESTORE_EPOCH"
        return 0
    fi

    for _oa_policy in "$CPUFREQ_ROOT"/policy*; do
        restore_policy_cpufreq_floor "$_oa_policy"
    done

    if [ "$CPUFREQ_RESTORED" = "yes" ]; then
        CPUFREQ_RESTORE_LEASE="$_oa_restore_lease"
        CPUFREQ_RESTORE_EPOCH="$NOW"
    fi
}

restore_fas_rs_cpufreq_floor() {
    restore_scheduler_cpufreq_floor fas_rs
}

restore_pixel_cpufreq_floor() {
    restore_scheduler_cpufreq_floor pixel
}

resolve_fas_module_path() {
    _oa_path="$FAS_RS_MODULE_PATH"
    case "$_oa_path" in
        ""|*";"*) _oa_path="/data/adb/modules/fas_rs" ;;
    esac
    if [ -f /data/adb/modules/fas_rs/fas-rs ]; then
        _oa_path="/data/adb/modules/fas_rs"
    else
        case "$_oa_path" in
            /data/adb/modules/*)
                [ -f "$_oa_path/fas-rs" ] || _oa_path="/data/adb/modules/fas_rs"
                ;;
            *)
                _oa_path="/data/adb/modules/fas_rs"
                ;;
        esac
    fi
    printf '%s' "$_oa_path"
}

resolve_uperf_module_path() {
    _oa_path="$UPERF_MODULE_PATH"
    case "$_oa_path" in
        ""|*";"*) _oa_path="/data/adb/modules/uperf" ;;
    esac
    if [ -d /data/adb/modules/uperf ]; then
        _oa_path="/data/adb/modules/uperf"
    else
        case "$_oa_path" in
            /data/adb/modules/*) [ -d "$_oa_path" ] || _oa_path="/data/adb/modules/uperf" ;;
            *) _oa_path="/data/adb/modules/uperf" ;;
        esac
    fi
    printf '%s' "$_oa_path"
}

ensure_powercfg_router() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        mkdir -p "$TEST_RUNTIME_DIR" 2>/dev/null || return 1
        _oa_router_calls=$(cat "$TEST_RUNTIME_DIR/powercfg_router_calls" 2>/dev/null | tr -d ' \r\n\t')
        case "$_oa_router_calls" in ''|*[!0-9]*) _oa_router_calls=0 ;; esac
        printf '%s\n' $((_oa_router_calls + 1)) > "$TEST_RUNTIME_DIR/powercfg_router_calls" 2>/dev/null || return 1
        [ ! -f "$TEST_RUNTIME_DIR/fail_powercfg_router" ] || return 1
        printf 'ready\n' > "$TEST_RUNTIME_DIR/powercfg_router_ready" 2>/dev/null || return 1
        return 0
    fi
    _oa_fas_mod=$(resolve_fas_module_path)
    _oa_router="$_oa_fas_mod/vtools/powercfg.sh"
    [ -s "$_oa_router" ] || return 1
    grep -q '/data/adb/fas_rs/.owner_state' "$_oa_router" 2>/dev/null || return 1
    sh -n "$_oa_router" >/dev/null 2>&1 || return 1
    _oa_router_hash=$(sha256sum "$_oa_router" 2>/dev/null | awk '{print $1}')
    case "$_oa_router_hash" in ''|*[!0-9a-fA-F]*) return 1 ;; esac

    case "$POWERCFG_ENTRY_EXECUTABLE_REQUIRED" in
        yes|no) ;;
        *) return 1 ;;
    esac

    _oa_entry_hash=$(sha256sum "$POWERCFG_ENTRY" 2>/dev/null | awk '{print $1}')
    if [ "$_oa_entry_hash" = "$_oa_router_hash" ]; then
        if [ "$POWERCFG_ENTRY_EXECUTABLE_REQUIRED" = "no" ] || [ -x "$POWERCFG_ENTRY" ]; then
            return 0
        fi
    fi

    [ ! -e "$POWERCFG_ENTRY" ] || [ -f "$POWERCFG_ENTRY" ] || return 1
    _oa_router_tmp="${POWERCFG_ENTRY}.pixel9pro_control.$$"
    _oa_router_backup="${POWERCFG_ENTRY}.pixel9pro_control.prev.$$"
    _oa_router_old_existed=no
    _oa_router_old_hash=""
    _oa_router_old_mode=""
    if [ -f "$POWERCFG_ENTRY" ]; then
        _oa_router_old_existed=yes
        _oa_router_old_hash=$(sha256sum "$POWERCFG_ENTRY" 2>/dev/null | awk '{print $1}')
        _oa_router_old_mode=$(stat -c '%a' "$POWERCFG_ENTRY" 2>/dev/null | tr -d ' \r\n\t')
        case "$_oa_router_old_hash:$_oa_router_old_mode" in
            *[!0-9a-fA-F:]*|:*|*:) return 1 ;;
        esac
        cp -p "$POWERCFG_ENTRY" "$_oa_router_backup" 2>/dev/null || return 1
    fi

    _oa_router_installed=no
    if cp "$_oa_router" "$_oa_router_tmp" 2>/dev/null \
        && { [ "$POWERCFG_ENTRY_EXECUTABLE_REQUIRED" = "no" ] || chmod 0755 "$_oa_router_tmp" 2>/dev/null; } \
        && { [ "$POWERCFG_ENTRY_EXECUTABLE_REQUIRED" = "no" ] || [ -x "$_oa_router_tmp" ]; } \
        && sh -n "$_oa_router_tmp" >/dev/null 2>&1 \
        && [ "$(sha256sum "$_oa_router_tmp" 2>/dev/null | awk '{print $1}')" = "$_oa_router_hash" ] \
        && mv -f "$_oa_router_tmp" "$POWERCFG_ENTRY" 2>/dev/null \
        && { [ "$POWERCFG_ENTRY_EXECUTABLE_REQUIRED" = "no" ] || [ -x "$POWERCFG_ENTRY" ]; } \
        && [ "$(sha256sum "$POWERCFG_ENTRY" 2>/dev/null | awk '{print $1}')" = "$_oa_router_hash" ]; then
        _oa_router_installed=yes
    fi

    if [ "$_oa_router_installed" = "yes" ]; then
        rm -f "$_oa_router_backup" 2>/dev/null
        return 0
    fi

    rm -f "$_oa_router_tmp" 2>/dev/null
    _oa_router_rollback_ok=no
    if [ "$_oa_router_old_existed" = "yes" ]; then
        if mv -f "$_oa_router_backup" "$POWERCFG_ENTRY" 2>/dev/null \
            && chmod "$_oa_router_old_mode" "$POWERCFG_ENTRY" 2>/dev/null \
            && [ "$(sha256sum "$POWERCFG_ENTRY" 2>/dev/null | awk '{print $1}')" = "$_oa_router_old_hash" ]; then
            _oa_router_rollback_ok=yes
        fi
    else
        rm -f "$POWERCFG_ENTRY" 2>/dev/null
        [ ! -e "$POWERCFG_ENTRY" ] && _oa_router_rollback_ok=yes
    fi
    rm -f "$_oa_router_backup" 2>/dev/null
    [ "$_oa_router_rollback_ok" = "yes" ] || APPLY_RESULT="failed_powercfg_router_rollback_incomplete"
    return 1
}

stop_uperf() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        mkdir -p "$TEST_RUNTIME_DIR" 2>/dev/null || return 1
        [ -f "$TEST_RUNTIME_DIR/fail_stop_uperf" ] && return 1
        rm -f "$TEST_RUNTIME_DIR/uperf_alive" 2>/dev/null
        [ -f "$TEST_RUNTIME_DIR/uperf_count" ] && printf '0\n' > "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null
        return 0
    fi
    uperf_process_alive || return 0
    killall uperf 2>/dev/null || true
    for _oa_i in 1 2 3 4 5; do
        uperf_process_alive || return 0
        sleep 1
    done
    return 1
}

start_uperf() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        mkdir -p "$TEST_RUNTIME_DIR" 2>/dev/null || return 1
        acquire_uperf_start_lock || return 1
        if [ -f "$TEST_RUNTIME_DIR/fail_start_uperf" ]; then
            release_uperf_start_lock
            return 1
        fi
        if [ -f "$TEST_RUNTIME_DIR/defer_start_uperf" ]; then
            release_uperf_start_lock
            return 3
        fi
        _oa_test_alive_before=no
        [ -f "$TEST_RUNTIME_DIR/uperf_alive" ] && _oa_test_alive_before=yes
        _oa_test_count_file_before=no
        [ -f "$TEST_RUNTIME_DIR/uperf_count" ] && _oa_test_count_file_before=yes
        _oa_test_count=$(cat "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null | tr -d ' \r\n\t')
        case "$_oa_test_count" in ''|*[!0-9]*) _oa_test_count=0 ;; esac
        _oa_test_normalized_before="$UPERF_NORMALIZED"
        [ "$_oa_test_count" -gt 1 ] 2>/dev/null && UPERF_NORMALIZED="yes"
        if ! printf '1\n' > "$TEST_RUNTIME_DIR/uperf_alive" 2>/dev/null; then
            release_uperf_start_lock
            return 1
        fi
        _oa_test_count_write_ok=yes
        if [ -f "$TEST_RUNTIME_DIR/fail_write_uperf_count_once" ]; then
            rm -f "$TEST_RUNTIME_DIR/fail_write_uperf_count_once" 2>/dev/null
            _oa_test_count_write_ok=no
        elif [ "$_oa_test_count_file_before" = "yes" ] \
            && ! printf '1\n' > "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null; then
            _oa_test_count_write_ok=no
        fi
        if [ "$_oa_test_count_write_ok" != "yes" ]; then
            if [ "$_oa_test_alive_before" = "yes" ]; then
                printf '1\n' > "$TEST_RUNTIME_DIR/uperf_alive" 2>/dev/null || true
            else
                rm -f "$TEST_RUNTIME_DIR/uperf_alive" 2>/dev/null
            fi
            if [ "$_oa_test_count_file_before" = "yes" ]; then
                printf '%s\n' "$_oa_test_count" > "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null || true
            else
                rm -f "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null
            fi
            UPERF_NORMALIZED="$_oa_test_normalized_before"
            release_uperf_start_lock
            return 1
        fi
        release_uperf_start_lock
        return 0
    fi
    uperf_storage_ready || return 3

    if ! acquire_uperf_start_lock; then
        for _oa_i in 1 2 3 4 5 6 7 8; do
            sleep 1
            if uperf_process_alive; then
                _oa_roots=$(uperf_root_instance_count)
                if [ "$_oa_roots" -le 1 ] 2>/dev/null; then
                    uperf_single_instance_stable
                    _oa_stable=$?
                    [ "$_oa_stable" -eq 0 ] && return 0
                    [ "$_oa_stable" -eq 2 ] && break
                else
                    break
                fi
            fi
        done
        acquire_uperf_start_lock || return 1
    fi

    if uperf_process_alive; then
        normalize_uperf_instances
        _oa_norm=$?
        if [ "$_oa_norm" -eq 0 ]; then
            uperf_single_instance_stable
            _oa_stable=$?
            if [ "$_oa_stable" -eq 0 ]; then
                release_uperf_start_lock
                return 0
            fi
            [ "$_oa_stable" -eq 2 ] && normalize_uperf_instances >/dev/null 2>&1 || true
        elif [ "$_oa_norm" -eq 2 ]; then
            release_uperf_start_lock
            return 1
        fi
    fi

    _oa_uperf_mod=$(resolve_uperf_module_path)
    _oa_uperf_lib="$_oa_uperf_mod/script/libuperf.sh"
    if [ ! -f "$_oa_uperf_lib" ]; then
        release_uperf_start_lock
        return 1
    fi

    _oa_start_attempt=1
    while [ "$_oa_start_attempt" -le 2 ] 2>/dev/null; do
        # Runtime restore only calls UGT's process lifecycle helper.  Replaying
        # initsvc.sh would also rerun platform_special/miui_migt/powercfg_once
        # and append another router entry on every game exit.
        sh -c '. "$0"; uperf_start' "$_oa_uperf_lib" >/dev/null 2>&1 &
        for _oa_i in 1 2 3 4 5 6 7 8; do
            sleep 1
            if uperf_process_alive; then
                uperf_single_instance_stable
                _oa_stable=$?
                if [ "$_oa_stable" -eq 0 ]; then
                    release_uperf_start_lock
                    return 0
                elif [ "$_oa_stable" -eq 2 ]; then
                    normalize_uperf_instances >/dev/null 2>&1 || true
                    break
                else
                    release_uperf_start_lock
                    return 1
                fi
            fi
        done
        _oa_start_attempt=$((_oa_start_attempt + 1))
    done
    release_uperf_start_lock
    return 1
}

fas_pid_is_ours() {
    _oa_pid="$1"
    _oa_start="$2"
    fas_identity_matches "$_oa_pid" "$_oa_start" || return 1
    [ "$OWNER_ARBITER_TEST_MODE" = "1" ] && return 0
    _oa_comm=$(cat "/proc/$_oa_pid/comm" 2>/dev/null | tr -d ' \r\n\t')
    [ "$_oa_comm" = "fas-rs" ]
}

cleanup_fas_started_by_transaction() {
    [ "$FAS_STARTED_BY_TRANSACTION" = "yes" ] || return 0
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        fas_pid_is_ours "$FAS_STARTED_PID" "$FAS_STARTED_START_TICKS" || return 0
        rm -f "$TEST_RUNTIME_DIR/fas_alive" "$TEST_RUNTIME_DIR/fas_pid" \
            "$TEST_RUNTIME_DIR/fas_start_ticks" 2>/dev/null
        FAS_STARTED_BY_TRANSACTION="no"
        FAS_STARTED_PID=""
        FAS_STARTED_START_TICKS=""
        return
    fi
    if ! fas_pid_is_ours "$FAS_STARTED_PID" "$FAS_STARTED_START_TICKS"; then
        FAS_STARTED_BY_TRANSACTION="no"
        FAS_STARTED_PID=""
        FAS_STARTED_START_TICKS=""
        return 0
    fi
    kill "$FAS_STARTED_PID" 2>/dev/null || return 1
    for _oa_i in 1 2 3 4 5; do
        if ! fas_pid_is_ours "$FAS_STARTED_PID" "$FAS_STARTED_START_TICKS"; then
            FAS_STARTED_BY_TRANSACTION="no"
            FAS_STARTED_PID=""
            FAS_STARTED_START_TICKS=""
            return 0
        fi
        sleep 1
    done
    return 1
}

stop_fas_lease_instance() {
    _oa_pid="$1"
    _oa_start="$2"
    if ! fas_identity_matches "$_oa_pid" "$_oa_start"; then
        fas_process_alive && return 2
        return 0
    fi
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        [ -f "$TEST_RUNTIME_DIR/fail_stop_fas" ] && return 1
        rm -f "$TEST_RUNTIME_DIR/fas_alive" "$TEST_RUNTIME_DIR/fas_pid" \
            "$TEST_RUNTIME_DIR/fas_start_ticks" 2>/dev/null
        fas_process_alive && return 1
        return 0
    fi
    kill "$_oa_pid" 2>/dev/null || return 1
    for _oa_i in 1 2 3 4 5; do
        if ! fas_identity_matches "$_oa_pid" "$_oa_start"; then
            fas_process_alive && return 2
            return 0
        fi
        sleep 1
    done
    return 1
}

start_fas_rs() {
    if fas_process_alive; then
        return 0
    fi
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        mkdir -p "$TEST_RUNTIME_DIR" 2>/dev/null || return 1
        [ -f "$TEST_RUNTIME_DIR/fail_start_fas" ] && return 1
        _oa_start_count=$(cat "$TEST_RUNTIME_DIR/fas_start_calls" 2>/dev/null | tr -d ' \r\n\t')
        case "$_oa_start_count" in ''|*[!0-9]*) _oa_start_count=0 ;; esac
        printf '%s\n' $((_oa_start_count + 1)) > "$TEST_RUNTIME_DIR/fas_start_calls" 2>/dev/null || return 1
        if [ -f "$TEST_RUNTIME_DIR/require_cap_before_start_fas" ]; then
            _oa_test_cap=$(cat "$UCLAMP_CAP_PATH" 2>/dev/null | tr -d ' \r\n\t')
            printf '%s\n' "$_oa_test_cap" > "$TEST_RUNTIME_DIR/cap_at_fas_start" 2>/dev/null
            [ "$_oa_test_cap" = "$CPU_PROFILE_FULL_CAP" ] || return 1
        fi
        printf '1\n' > "$TEST_RUNTIME_DIR/fas_alive" 2>/dev/null || return 1
        printf '4242\n' > "$TEST_RUNTIME_DIR/fas_pid" 2>/dev/null || return 1
        printf '100\n' > "$TEST_RUNTIME_DIR/fas_start_ticks" 2>/dev/null || return 1
        FAS_STARTED_BY_TRANSACTION="yes"
        FAS_STARTED_PID="4242"
        FAS_STARTED_START_TICKS="100"
        return
    fi

    _oa_fas_mod=$(resolve_fas_module_path)
    _oa_fas_bin="$_oa_fas_mod/fas-rs"
    [ -f "$_oa_fas_bin" ] || return 1

    _oa_fas_std_conf="$_oa_fas_mod/games.toml"
    [ -s "$FAS_ROOT/games.toml" ] || return 1
    [ -s "$_oa_fas_std_conf" ] || return 1

    mkdir -p "$FAS_ROOT" 2>/dev/null || return 1
    write_fas_owner_state "fas-rs:starting-arbiter" || return 1
    RUST_BACKTRACE=1 nohup "$_oa_fas_bin" run "$_oa_fas_std_conf" >>"$FAS_LOG_FILE" 2>&1 &
    _oa_spawn_pid=$!
    case "$_oa_spawn_pid" in ''|*[!0-9]*) return 1 ;; esac
    FAS_STARTED_BY_TRANSACTION="yes"
    FAS_STARTED_PID="$_oa_spawn_pid"
    FAS_STARTED_START_TICKS=$(process_start_ticks "$_oa_spawn_pid")
    case "$FAS_STARTED_START_TICKS" in ''|*[!0-9]*) return 1 ;; esac
    for _oa_i in 1 2 3 4 5; do
        sleep 1
        fas_pid_is_ours "$FAS_STARTED_PID" "$FAS_STARTED_START_TICKS" && return 0
    done
    return 1
}

read_valid_pixel_profile() {
    _oa_profile=$(cat "$PROFILE_FILE" 2>/dev/null | tr -d ' \n\r\t')
    cpu_profile_normalize_runtime "$_oa_profile" balanced
}

apply_current_pixel_profile() {
    _oa_profile=$(read_valid_pixel_profile)
    [ -f "$MODDIR/scripts/cpu_profile.sh" ] || return 1
    sh "$MODDIR/scripts/cpu_profile.sh" "$_oa_profile" "$MODDIR" force >/dev/null 2>&1
}

read_uclamp_cap() {
    _oa_cap=$(cat "$UCLAMP_CAP_PATH" 2>/dev/null | tr -d ' \n\r\t')
    case "$_oa_cap" in
        ''|*[!0-9]*) printf 'unknown' ;;
        *) printf '%s' "$_oa_cap" ;;
    esac
}

expected_pixel_uclamp_cap() {
    cpu_profile_uclamp_cap "$(read_valid_pixel_profile)"
}

verify_uclamp_cap() {
    _oa_expected_cap="$1"
    UCLAMP_CAP_EXPECTED="$_oa_expected_cap"
    UCLAMP_CAP_CURRENT=$(read_uclamp_cap)
    if [ "$UCLAMP_CAP_CURRENT" = "$_oa_expected_cap" ]; then
        UCLAMP_CAP_VERIFIED="yes"
        return 0
    fi
    UCLAMP_CAP_VERIFIED="no"
    return 1
}

apply_uclamp_cap() {
    # sched_util_clamp_min caps task uclamp.min requests. It does not replace
    # ThermalHAL's independent uclamp.max cooling path, which remains untouched.
    _oa_expected_cap="$1"
    UCLAMP_CAP_EXPECTED="$_oa_expected_cap"
    if verify_uclamp_cap "$_oa_expected_cap"; then
        return 0
    fi
    [ -e "$UCLAMP_CAP_PATH" ] || return 1
    printf '%s\n' "$_oa_expected_cap" > "$UCLAMP_CAP_PATH" 2>/dev/null || return 1
    verify_uclamp_cap "$_oa_expected_cap"
}

refresh_uclamp_state() {
    UCLAMP_CAP_CURRENT=$(read_uclamp_cap)
    if [ "$UCLAMP_CAP_EXPECTED" = "unknown" ]; then
        case "$NEW_STATE" in
            FAS_LEASED_GAME|EXIT_HOLD)
                UCLAMP_CAP_EXPECTED="$CPU_PROFILE_FULL_CAP"
                ;;
            BASELINE_NORMAL|GAME_CANDIDATE)
                if [ "$NEW_BASELINE_OWNER" = "external" ]; then
                    UCLAMP_CAP_EXPECTED="ugt_owned"
                else
                    UCLAMP_CAP_EXPECTED=$(expected_pixel_uclamp_cap)
                fi
                ;;
        esac
    fi
    case "$UCLAMP_CAP_EXPECTED" in
        ''|*[!0-9]*) UCLAMP_CAP_VERIFIED="unknown" ;;
        *)
            if [ "$UCLAMP_CAP_CURRENT" = "$UCLAMP_CAP_EXPECTED" ]; then
                UCLAMP_CAP_VERIFIED="yes"
            else
                UCLAMP_CAP_VERIFIED="no"
            fi
            ;;
    esac
}

verify_pixel_baseline() {
    [ "$(read_pixel_owner)" = "pixel" ] || return 1
    uperf_process_alive && return 1
    fas_game_lease_target >/dev/null 2>&1 && return 1

    _oa_profile=$(read_valid_pixel_profile)
    _oa_expected_cap=$(cpu_profile_uclamp_cap "$_oa_profile") || return 1
    [ "$(read_uclamp_cap)" = "$_oa_expected_cap" ] || return 1
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        [ ! -f "$TEST_RUNTIME_DIR/pixel_baseline_drift" ]
        return
    fi
    _oa_expected_top=$(cpu_profile_top_app_cpus "$_oa_profile") || return 1
    _oa_resp=$(cpu_profile_response_triplet "$_oa_profile") || return 1

    _oa_top=$(cat /dev/cpuset/top-app/cpus 2>/dev/null | tr -d ' \n\r\t')
    [ "$_oa_top" = "$_oa_expected_top" ] || return 1

    if [ -n "$_oa_resp" ]; then
        set -- $_oa_resp
        for _oa_cpu in 0 4 7; do
            _oa_expected="$1"
            shift
            _oa_resp_file="/sys/devices/system/cpu/cpu${_oa_cpu}/cpufreq/sched_pixel/response_time_ms"
            [ -f "$_oa_resp_file" ] || return 1
            [ "$(cat "$_oa_resp_file" 2>/dev/null | tr -d ' \n\r\t')" = "$_oa_expected" ] || return 1
        done
    fi
    return 0
}

uclamp_cap_is_valid() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 0 ] 2>/dev/null && [ "$1" -le 1024 ] 2>/dev/null
}

capture_ugt_baseline_cap() {
    _oa_cap=$(read_uclamp_cap)
    uclamp_cap_is_valid "$_oa_cap" || return 1
    NEW_BASELINE_UCLAMP_CAP="$_oa_cap"
    return 0
}

verify_ugt_baseline() {
    _oa_expected_cap="${1:-unknown}"
    [ "$(read_pixel_owner)" = "external" ] || return 1
    [ "$UPERF_MODULE_ENABLED" = "yes" ] || return 1
    uperf_process_alive || return 1
    [ "$(uperf_root_instance_count)" -eq 1 ] 2>/dev/null || return 1
    fas_process_alive && return 1
    _oa_external_state=$(cat "$FAS_OWNER_FILE" 2>/dev/null | tr -d '\r\n')
    case "$_oa_external_state" in external:uperf|external:uperf:*) ;; *) return 1 ;; esac
    if uclamp_cap_is_valid "$_oa_expected_cap"; then
        [ "$(read_uclamp_cap)" = "$_oa_expected_cap" ] || return 1
    fi
    return 0
}

verify_fas_baseline() {
    [ "$(read_pixel_owner)" = "external" ] || return 1
    uperf_process_alive && return 1
    fas_process_alive || return 1
    [ "$(read_uclamp_cap)" = "$CPU_PROFILE_FULL_CAP" ] || return 1
    [ -n "$NEW_TARGET_PKG" ] || return 1
    [ "$(cat "$FAS_OWNER_FILE" 2>/dev/null | tr -d '\r\n')" = "fas-rs:game:$NEW_TARGET_PKG" ] || return 1
    if [ "$NEW_BASELINE_OWNER" = "external" ]; then
        fas_identity_matches "$NEW_LEASE_FAS_PID" "$NEW_LEASE_FAS_START_TICKS" || return 1
    fi
    return 0
}

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

owner_guard_begin() {
    _oa_guard_key="$1"
    stg_init "$FAS_ROOT/.owner_mutation_guard"
    _oa_guard_now=$(now_epoch)
    _oa_guard_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \r\n\t')
    [ -n "$_oa_guard_boot" ] || _oa_guard_boot=unknown
    stg_begin_attempt "$_oa_guard_key" "$_oa_guard_boot" "$_oa_guard_now"
    _oa_guard_rc=$?
    if [ "$_oa_guard_rc" -ne 0 ]; then
        if [ "$_oa_guard_rc" -eq 74 ]; then
            APPLY_RESULT="failed_owner_guard_attempt_commit"
        else
            stg_load
            APPLY_RESULT="transition_latched:${STG_RESULT:-retry_budget_exhausted}"
        fi
        return 1
    fi
    APPLY_MUTATION_GUARD_ACTIVE=yes
    return 0
}

owner_guard_is_terminal() {
    _oa_guard_key="$1"
    stg_init "$FAS_ROOT/.owner_mutation_guard"
    stg_load
    _oa_guard_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \r\n\t')
    [ -n "$_oa_guard_boot" ] || _oa_guard_boot=unknown
    [ "$STG_TERMINAL" = "yes" ] \
        && [ "$STG_OK" = "no" ] \
        && [ "$STG_KEY" = "$_oa_guard_key" ] \
        && [ "$STG_BOOT_ID" = "$_oa_guard_boot" ]
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

state_snapshot_matches() {
    [ -s "$ARB_STATE_FILE" ] || return 1
    [ "$NEW_STATE" = "$PREV_STATE" ] \
        && [ "$NEW_TARGET_PKG" = "$PREV_TARGET_PKG" ] \
        && [ "$NEW_TARGET_PID" = "$PREV_TARGET_PID" ] \
        && [ "$NEW_CANDIDATE_SINCE" = "$PREV_CANDIDATE_SINCE" ] \
        && [ "$NEW_LEASE_START" = "$PREV_LEASE_START" ] \
        && [ "$NEW_LAST_FOREGROUND" = "$PREV_LAST_FOREGROUND" ] \
        && [ "$NEW_PID_ABSENT_SINCE" = "$PREV_PID_ABSENT_SINCE" ] \
        && [ "$NEW_BASELINE_OWNER" = "$PREV_BASELINE_OWNER" ] \
        && [ "$NEW_BASELINE_UCLAMP_CAP" = "$PREV_BASELINE_UCLAMP_CAP" ] \
        && [ "$NEW_LEASE_FAS_PID" = "$PREV_LEASE_FAS_PID" ] \
        && [ "$NEW_LEASE_FAS_START_TICKS" = "$PREV_LEASE_FAS_START_TICKS" ] \
        && [ "$DESIRED_OWNER" = "$PREV_DESIRED_OWNER" ] \
        && [ "$CURRENT_OWNER" = "$PREV_EFFECTIVE_OWNER" ] \
        && [ "$PROPOSED_OWNER" = "$PREV_PROPOSED_OWNER" ] \
        && [ "$REASON" = "$PREV_REASON" ] \
        && [ "$APPLY_ENABLED" = "$PREV_APPLY_ENABLED" ] \
        && [ "$APPLY_RESULT" = "$PREV_APPLY_RESULT" ] \
        && [ "$HANDOFF_POLICY" = "$PREV_HANDOFF_POLICY" ]
}

write_state() {
    refresh_uclamp_state
    _oa_tmp="${ARB_STATE_FILE}.$$"
    [ ! -d "$ARB_STATE_FILE" ] || return 1
    {
        printf 'state=%s\n' "$NEW_STATE"
        printf 'target_pkg=%s\n' "$NEW_TARGET_PKG"
        printf 'target_pid=%s\n' "$NEW_TARGET_PID"
        printf 'candidate_since=%s\n' "$NEW_CANDIDATE_SINCE"
        printf 'lease_start=%s\n' "$NEW_LEASE_START"
        printf 'last_foreground=%s\n' "$NEW_LAST_FOREGROUND"
        printf 'pid_absent_since=%s\n' "$NEW_PID_ABSENT_SINCE"
        printf 'baseline_owner=%s\n' "$NEW_BASELINE_OWNER"
        printf 'baseline_uclamp_cap=%s\n' "$NEW_BASELINE_UCLAMP_CAP"
        printf 'lease_fas_pid=%s\n' "$NEW_LEASE_FAS_PID"
        printf 'lease_fas_start_ticks=%s\n' "$NEW_LEASE_FAS_START_TICKS"
        printf 'desired_owner=%s\n' "$DESIRED_OWNER"
        printf 'effective_owner=%s\n' "$(read_pixel_owner)"
        printf 'game_handoff_policy=%s\n' "$HANDOFF_POLICY"
        printf 'updated_epoch=%s\n' "$NOW"
        printf 'proposed_owner=%s\n' "$PROPOSED_OWNER"
        printf 'reason=%s\n' "$REASON"
        printf 'apply_enabled=%s\n' "$APPLY_ENABLED"
        printf 'apply_result=%s\n' "$APPLY_RESULT"
        printf 'uperf_root_instances=%s\n' "$(uperf_root_instance_count)"
        printf 'uperf_normalized=%s\n' "$UPERF_NORMALIZED"
        printf 'cpufreq_lowfreq_present=%s\n' "$CPUFREQ_LOWFREQ_PRESENT"
        printf 'cpufreq_thermal_cooling_active=%s\n' "$CPUFREQ_THERMAL_COOLING_ACTIVE"
        printf 'cpufreq_restored=%s\n' "$CPUFREQ_RESTORED"
        printf 'cpufreq_restore_verified=%s\n' "$CPUFREQ_RESTORE_VERIFIED"
        printf 'cpufreq_restore_failed=%s\n' "$CPUFREQ_RESTORE_FAILED"
        printf 'cpufreq_restore_skipped=%s\n' "$CPUFREQ_RESTORE_SKIPPED"
        printf 'cpufreq_restore_lease=%s\n' "$CPUFREQ_RESTORE_LEASE"
        printf 'cpufreq_restore_epoch=%s\n' "$CPUFREQ_RESTORE_EPOCH"
        printf 'uclamp_cap_path=%s\n' "$UCLAMP_CAP_PATH"
        printf 'uclamp_cap_current=%s\n' "$UCLAMP_CAP_CURRENT"
        printf 'uclamp_cap_expected=%s\n' "$UCLAMP_CAP_EXPECTED"
        printf 'uclamp_cap_verified=%s\n' "$UCLAMP_CAP_VERIFIED"
        printf 'dry_run=%s\n' "$DRY_RUN_FLAG"
    } > "$_oa_tmp" 2>/dev/null \
        && mv "$_oa_tmp" "$ARB_STATE_FILE" 2>/dev/null \
        && [ -f "$ARB_STATE_FILE" ] && return 0
    rm -f "$_oa_tmp" 2>/dev/null
    return 1
}

append_history() {
    if [ ! -s "$ARB_HISTORY_FILE" ]; then
        printf '%s\n' 'epoch|screen|state|focus_pkg|focus_pid|target_pkg|target_pid|game_match|game_source|effective_owner_before|proposed_owner|reason|ugt_detected|ugt_enabled|fas_detected|fas_active|fas_alive|fas_owner_state|fas_mode|external_kind|external_active|apply_enabled|apply_result|cpufreq_lowfreq_present|cpufreq_thermal_cooling_active|cpufreq_restored|cpufreq_restore_verified|cpufreq_restore_failed|cpufreq_restore_skipped|cpufreq_restore_lease|cpufreq_restore_epoch|dry_run|desired_owner|effective_owner_after|game_handoff_policy|uclamp_cap_current|uclamp_cap_expected|uclamp_cap_verified' > "$ARB_HISTORY_FILE" 2>/dev/null
    elif ! head -n 1 "$ARB_HISTORY_FILE" 2>/dev/null | grep -q 'cpufreq_restore_epoch'; then
        printf '%s\n' '# schema_update: cpufreq_restore fields appended to rows after this marker' >> "$ARB_HISTORY_FILE" 2>/dev/null
    fi
    if ! head -n 1 "$ARB_HISTORY_FILE" 2>/dev/null | grep -q 'desired_owner' && ! grep -q '^# schema_update: desired_owner fields appended' "$ARB_HISTORY_FILE" 2>/dev/null; then
        printf '%s\n' '# schema_update: desired_owner fields appended to rows after this marker' >> "$ARB_HISTORY_FILE" 2>/dev/null
    fi
    if ! head -n 1 "$ARB_HISTORY_FILE" 2>/dev/null | grep -q 'uclamp_cap_current' && ! grep -q '^# schema_update: uclamp cap fields appended' "$ARB_HISTORY_FILE" 2>/dev/null; then
        printf '%s\n' '# schema_update: uclamp cap fields appended to rows after this marker' >> "$ARB_HISTORY_FILE" 2>/dev/null
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$NOW" "$(safe_field "$SCREEN_STATE")" "$(safe_field "$NEW_STATE")" \
        "$(safe_field "$FOCUS_PKG")" "$(safe_field "$FOCUS_PID")" \
        "$(safe_field "$NEW_TARGET_PKG")" "$(safe_field "$NEW_TARGET_PID")" \
        "$GAME_MATCH" "$(safe_field "$GAME_SOURCE")" "$CURRENT_OWNER" "$PROPOSED_OWNER" \
        "$(safe_field "$REASON")" "$UPERF_DETECTED" "$UPERF_MODULE_ENABLED" \
        "$FAS_RS_DETECTED" "$FAS_RS_ACTIVE" "$FAS_RS_PROCESS_ALIVE" \
        "$(safe_field "$FAS_RS_OWNER_STATE")" "$(safe_field "$FAS_RS_MODE")" \
        "$(safe_field "$EXTERNAL_SCHEDULER_KIND")" "$EXTERNAL_SCHEDULER_ACTIVE" \
        "$APPLY_ENABLED" "$(safe_field "$APPLY_RESULT")" "$CPUFREQ_LOWFREQ_PRESENT" "$CPUFREQ_THERMAL_COOLING_ACTIVE" "$CPUFREQ_RESTORED" "$CPUFREQ_RESTORE_VERIFIED" "$CPUFREQ_RESTORE_FAILED" "$CPUFREQ_RESTORE_SKIPPED" "$CPUFREQ_RESTORE_LEASE" "$CPUFREQ_RESTORE_EPOCH" "$DRY_RUN_FLAG" \
        "$DESIRED_OWNER" "$(read_pixel_owner)" "$HANDOFF_POLICY" "$UCLAMP_CAP_CURRENT" "$UCLAMP_CAP_EXPECTED" "$UCLAMP_CAP_VERIFIED" \
        >> "$ARB_HISTORY_FILE" 2>/dev/null

    _oa_lines=$(wc -l < "$ARB_HISTORY_FILE" 2>/dev/null)
    case "$_oa_lines" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$_oa_lines" -gt "$ARB_HISTORY_MAX" ] 2>/dev/null; then
        _oa_trim=$((_oa_lines - ARB_HISTORY_MAX))
        _oa_end=$((_oa_trim + 1))
        [ "$_oa_end" -ge 2 ] && sed -i "2,${_oa_end}d" "$ARB_HISTORY_FILE" 2>/dev/null
    fi
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
