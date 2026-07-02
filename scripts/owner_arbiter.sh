#!/system/bin/sh
#
# Guarded owner arbiter.
# Default mode remains Phase A observation (dry-run): record the owner decision
# without changing sched owners or starting/stopping schedulers.
# Apply mode is enabled only by action "apply-tick"/"apply" or by creating
# /data/adb/fas_rs/.arbiter_apply.  Apply mode performs the narrow Phase B
# UGT<->fas-rs handoff for matched games and keeps one primary scheduler.

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

FAS_ROOT="/data/adb/fas_rs"
STATE_DIR="$FAS_ROOT"
if [ "$ACTION" != "status" ] && [ ! -d "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
fi

SCHED_OWNER_FILE="$MODDIR/.cpu_sched_owner"
ARB_DISABLE_FILE="$STATE_DIR/.arbiter_disable"
ARB_APPLY_FILE="$STATE_DIR/.arbiter_apply"
ARB_STATE_FILE="$STATE_DIR/.arbiter_state"
ARB_HISTORY_FILE="$STATE_DIR/.arbiter_history"
LEASE_GAME_LIST="$FAS_ROOT/.lease_game_list"
FAS_OWNER_FILE="$FAS_ROOT/.owner_state"
FAS_LOG_FILE="$FAS_ROOT/fas_log.txt"
POWERCFG_ENTRY="/data/powercfg.sh"
SCENE_PROFILE="/data/data/com.omarea.vtools/shared_prefs/games.xml"
UPERF_START_LOCK_DIR="$STATE_DIR/.uperf_start.lock"

ENTER_DEBOUNCE_S="${ARB_ENTER_DEBOUNCE_S:-3}"
MIN_LEASE_S="${ARB_MIN_LEASE_S:-420}"
PID_ABSENT_CONFIRM_S="${ARB_PID_ABSENT_CONFIRM_S:-8}"
EXIT_IDLE_AFTER_S="${ARB_EXIT_IDLE_AFTER_S:-90}"
ARB_HISTORY_MAX="${ARB_HISTORY_MAX:-500}"
APPLY_ENABLED="no"
APPLY_RESULT="dry-run"
UPERF_NORMALIZED="no"
if [ "$APPLY_REQUESTED" = "yes" ]; then
    APPLY_ENABLED="yes"
elif [ -f "$ARB_APPLY_FILE" ]; then
    _oa_apply_value=$(cat "$ARB_APPLY_FILE" 2>/dev/null | tr -d ' \r\n\t')
    case "$_oa_apply_value" in
        0|off|false|no) APPLY_ENABLED="no" ;;
        *) APPLY_ENABLED="yes" ;;
    esac
fi
if [ "$APPLY_ENABLED" = "yes" ]; then
    DRY_RUN_FLAG="0"
else
    DRY_RUN_FLAG="1"
fi

# Defaults if scheduler_detect_lib.sh is unavailable.
UPERF_DETECTED="no"
UPERF_MODULE_ENABLED="no"
FAS_RS_DETECTED="no"
FAS_RS_ACTIVE="no"
FAS_RS_PROCESS_ALIVE="no"
FAS_RS_OWNER_STATE=""
FAS_RS_MODE=""
FAS_RS_MODULE_PATH=""
UPERF_MODULE_PATH=""
EXTERNAL_SCHEDULER_DETECTED="no"
EXTERNAL_SCHEDULER_ACTIVE="no"
EXTERNAL_SCHEDULER_KIND=""

[ -f "$MODDIR/scripts/scheduler_detect_lib.sh" ] && . "$MODDIR/scripts/scheduler_detect_lib.sh" 2>/dev/null

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
    _oa_owner=$(cat "$SCHED_OWNER_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_oa_owner" in
        external) printf 'external' ;;
        *) printf 'pixel' ;;
    esac
}

state_get() {
    [ -s "$ARB_STATE_FILE" ] || return 0
    sed -n "s/^$1=//p" "$ARB_STATE_FILE" 2>/dev/null | head -n 1 | tr -d '\r'
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
    # Android 17 may list Launcher before the real foreground app in
    # `dumpsys activity top` while `dumpsys window` still reports the focused
    # game correctly.  Prefer WindowManager focus and use ActivityTaskManager
    # only as a fallback.
    _oa_dump=$(dumpsys window 2>/dev/null)
    _oa_line=$(printf '%s\n' "$_oa_dump" | sed -n '
        /^[[:space:]]*mFocusedApp=/p
        /^[[:space:]]*topResumedActivity=/p
        /^[[:space:]]*ResumedActivity:/p
        /^[[:space:]]*mCurrentFocus=/p
        /^[[:space:]]*mFocusedWindow=/p
    ' | head -n 1)
    _oa_pkg=$(printf '%s\n' "$_oa_line" | sed -n 's/.*[[:space:]]u[0-9][0-9]*[[:space:]]\([^/ }][^/ }]*\)\/.*/\1/p' | head -n 1)
    if [ -z "$_oa_pkg" ]; then
        _oa_pkg=$(printf '%s\n' "$_oa_line" | sed -n 's/.*[[:space:]]\([A-Za-z0-9_.$][A-Za-z0-9_.$]*\)\/.*/\1/p' | head -n 1)
    fi
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

process_alive() {
    _oa_proc="$1"
    pidof "$_oa_proc" >/dev/null 2>&1 && return 0
    ps -A 2>/dev/null | grep -E "(^|[[:space:]])${_oa_proc}([[:space:]]|$)" | grep -v grep >/dev/null 2>&1
}

pid_alive() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -d "/proc/$1" ]
}

uperf_process_alive() {
    process_alive "uperf"
}

fas_process_alive() {
    process_alive "fas-rs"
}

acquire_uperf_start_lock() {
    _oa_lock_now=$(now_epoch)
    for _oa_i in 1 2 3 4 5; do
        if mkdir "$UPERF_START_LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" > "$UPERF_START_LOCK_DIR/pid" 2>/dev/null || true
            printf '%s\n' "$_oa_lock_now" > "$UPERF_START_LOCK_DIR/epoch" 2>/dev/null || true
            return 0
        fi

        _oa_lock_pid=$(cat "$UPERF_START_LOCK_DIR/pid" 2>/dev/null | tr -d ' \r\n\t')
        _oa_lock_epoch=$(num_or_zero "$(cat "$UPERF_START_LOCK_DIR/epoch" 2>/dev/null)")
        _oa_lock_age=$((_oa_lock_now - _oa_lock_epoch))
        _oa_lock_stale="no"
        if ! pid_alive "$_oa_lock_pid"; then
            _oa_lock_stale="yes"
        elif [ "$_oa_lock_age" -gt 30 ] 2>/dev/null; then
            _oa_lock_stale="yes"
        fi

        if [ "$_oa_lock_stale" = "yes" ]; then
            rm -f "$UPERF_START_LOCK_DIR/pid" "$UPERF_START_LOCK_DIR/epoch" 2>/dev/null || true
            rmdir "$UPERF_START_LOCK_DIR" 2>/dev/null || true
            continue
        fi
        sleep 1
        _oa_lock_now=$(now_epoch)
    done
    return 1
}

release_uperf_start_lock() {
    _oa_lock_pid=$(cat "$UPERF_START_LOCK_DIR/pid" 2>/dev/null | tr -d ' \r\n\t')
    [ "$_oa_lock_pid" = "$$" ] || return 0
    rm -f "$UPERF_START_LOCK_DIR/pid" "$UPERF_START_LOCK_DIR/epoch" 2>/dev/null || true
    rmdir "$UPERF_START_LOCK_DIR" 2>/dev/null || true
}

uperf_root_instance_count() {
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

normalize_uperf_instances() {
    _oa_roots=$(uperf_root_instance_count)
    if [ "$_oa_roots" -le 1 ] 2>/dev/null; then
        return 0
    fi

    UPERF_NORMALIZED="yes"
    killall uperf 2>/dev/null || true
    for _oa_i in 1 2 3 4 5; do
        sleep 1
        _oa_roots=$(uperf_root_instance_count)
        if [ "$_oa_roots" -le 1 ] 2>/dev/null; then
            return 0
        fi
    done
    return 2
}

uperf_storage_ready() {
    [ "$(getprop sys.boot_completed 2>/dev/null | tr -d ' \r\n\t')" = "1" ] || return 1
    [ -d /sdcard/Android ] || [ -d /storage/emulated/0/Android ]
}

uperf_single_instance_stable() {
    # UGT's own boot service may resume immediately after credential storage is
    # unlocked, while owner_arbiter can also be restoring UGT.  Do not return on
    # the first `uperf` PID; wait a short settle window and reject duplicate
    # root instances so the caller can normalize and retry.
    for _oa_i in 1 2 3 4 5; do
        sleep 1
        uperf_process_alive || return 1
        _oa_roots=$(uperf_root_instance_count)
        if [ "$_oa_roots" -gt 1 ] 2>/dev/null; then
            return 2
        fi
    done
    return 0
}

write_sched_owner() {
    _oa_target="$1"
    case "$_oa_target" in
        external|pixel) ;;
        *) return 1 ;;
    esac

    if [ "$(read_pixel_owner)" = "$_oa_target" ]; then
        return 0
    fi
    printf '%s\n' "$_oa_target" > "$SCHED_OWNER_FILE" 2>/dev/null
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
            /data/adb/modules/*)
                [ -d "$_oa_path" ] || _oa_path="/data/adb/modules/uperf"
                ;;
            *)
                _oa_path="/data/adb/modules/uperf"
                ;;
        esac
    fi
    printf '%s' "$_oa_path"
}

ensure_powercfg_router() {
    _oa_fas_mod=$(resolve_fas_module_path)
    _oa_router="$_oa_fas_mod/vtools/powercfg.sh"
    [ -f "$_oa_router" ] || return 0

    if [ -f "$POWERCFG_ENTRY" ] && grep -q '/data/adb/fas_rs/.owner_state' "$POWERCFG_ENTRY" 2>/dev/null; then
        return 0
    fi

    cp -f "$_oa_router" "$POWERCFG_ENTRY" 2>/dev/null || return 1
    chmod 0755 "$POWERCFG_ENTRY" 2>/dev/null || true
    return 0
}

stop_uperf() {
    if ! uperf_process_alive; then
        return 0
    fi
    killall uperf 2>/dev/null || true
    for _oa_i in 1 2 3 4 5; do
        uperf_process_alive || return 0
        sleep 1
    done
    return 1
}

start_uperf() {
    if ! uperf_storage_ready; then
        return 3
    fi

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
            if [ "$_oa_stable" -eq 2 ]; then
                normalize_uperf_instances >/dev/null 2>&1 || true
            fi
        elif [ "$_oa_norm" -eq 2 ]; then
            release_uperf_start_lock
            return 1
        fi
    fi

    _oa_uperf_mod=$(resolve_uperf_module_path)
    if [ ! -f "$_oa_uperf_mod/script/initsvc.sh" ]; then
        release_uperf_start_lock
        return 1
    fi

    _oa_start_attempt=1
    while [ "$_oa_start_attempt" -le 2 ] 2>/dev/null; do
        sh "$_oa_uperf_mod/script/initsvc.sh" >/dev/null 2>&1 &
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

stop_fas_rs() {
    if ! fas_process_alive; then
        return 0
    fi
    killall fas-rs 2>/dev/null || true
    for _oa_i in 1 2 3 4 5; do
        fas_process_alive || return 0
        sleep 1
    done
    return 1
}

start_fas_rs() {
    if fas_process_alive; then
        return 0
    fi

    _oa_fas_mod=$(resolve_fas_module_path)
    _oa_fas_bin="$_oa_fas_mod/fas-rs"
    [ -f "$_oa_fas_bin" ] || return 1

    _oa_fas_std_conf="$_oa_fas_mod/games.toml"
    [ -s "$FAS_ROOT/games.toml" ] || return 1
    [ -s "$_oa_fas_std_conf" ] || return 1

    mkdir -p "$FAS_ROOT" 2>/dev/null || true
    printf '%s\n' "fas-rs:starting-arbiter" > "$FAS_OWNER_FILE" 2>/dev/null || true
    RUST_BACKTRACE=1 nohup "$_oa_fas_bin" run "$_oa_fas_std_conf" >>"$FAS_LOG_FILE" 2>&1 &
    for _oa_i in 1 2 3 4 5; do
        sleep 1
        fas_process_alive && return 0
    done
    return 1
}

apply_owner_decision() {
    if [ "$APPLY_ENABLED" != "yes" ]; then
        APPLY_RESULT="dry-run"
        return 0
    fi

    ensure_powercfg_router || APPLY_RESULT="warn_powercfg_router_failed"

    case "$NEW_STATE" in
        FAS_LEASED_GAME|EXIT_HOLD)
            if ! write_sched_owner external; then
                APPLY_RESULT="failed_write_external_owner"
                return 1
            fi
            if ! stop_uperf; then
                APPLY_RESULT="failed_stop_uperf"
                return 1
            fi
            if ! start_fas_rs; then
                APPLY_RESULT="failed_start_fas_rs"
                if [ "$UPERF_MODULE_ENABLED" = "yes" ]; then
                    start_uperf >/dev/null 2>&1 || true
                    printf '%s\n' "fallback:fas_start_failed" > "$FAS_OWNER_FILE" 2>/dev/null || true
                fi
                return 1
            fi
            [ -n "$NEW_TARGET_PKG" ] && printf '%s\n' "fas-rs:game:$NEW_TARGET_PKG" > "$FAS_OWNER_FILE" 2>/dev/null || true
            APPLY_RESULT="applied_fas_rs_game"
            ;;
        PIXEL_NORMAL)
            if [ "$NEW_BASELINE_OWNER" = "external" ] || { [ "$CURRENT_OWNER" = "external" ] && [ "$UPERF_MODULE_ENABLED" = "yes" ]; }; then
                if ! write_sched_owner external; then
                    APPLY_RESULT="failed_write_external_owner"
                    return 1
                fi
                if [ "$UPERF_MODULE_ENABLED" = "yes" ]; then
                    stop_fas_rs >/dev/null 2>&1 || true
                    start_uperf
                    _oa_start_uperf_rc=$?
                    if [ "$_oa_start_uperf_rc" -ne 0 ]; then
                        if [ "$_oa_start_uperf_rc" -eq 3 ]; then
                            APPLY_RESULT="deferred_start_uperf_storage_locked"
                            printf '%s\n' "external:uperf" > "$FAS_OWNER_FILE" 2>/dev/null || true
                            return 0
                        fi
                        APPLY_RESULT="failed_start_uperf"
                        return 1
                    fi
                    ensure_powercfg_router >/dev/null 2>&1 || true
                    printf '%s\n' "external:uperf" > "$FAS_OWNER_FILE" 2>/dev/null || true
                    _oa_uperf_roots=$(uperf_root_instance_count)
                    if [ "$_oa_uperf_roots" -gt 1 ] 2>/dev/null; then
                        normalize_uperf_instances >/dev/null 2>&1 || true
                        start_uperf >/dev/null 2>&1
                        _oa_restart_uperf_rc=$?
                        if [ "$_oa_restart_uperf_rc" -ne 0 ]; then
                            APPLY_RESULT="failed_normalize_uperf_duplicates"
                            return 1
                        fi
                        _oa_uperf_roots=$(uperf_root_instance_count)
                        if [ "$_oa_uperf_roots" -gt 1 ] 2>/dev/null; then
                            APPLY_RESULT="failed_normalize_uperf_duplicates"
                            return 1
                        fi
                        APPLY_RESULT="applied_uperf_idle_normalized"
                    elif [ "$UPERF_NORMALIZED" = "yes" ]; then
                        APPLY_RESULT="applied_uperf_idle_normalized"
                    else
                        APPLY_RESULT="applied_uperf_idle"
                    fi
                else
                    APPLY_RESULT="applied_external_idle"
                fi
            else
                if ! write_sched_owner pixel; then
                    APPLY_RESULT="failed_write_pixel_owner"
                    return 1
                fi
                APPLY_RESULT="applied_pixel_idle"
            fi
            ;;
        *)
            APPLY_RESULT="apply_noop:$NEW_STATE"
            ;;
    esac
    return 0
}

write_state() {
    _oa_tmp="${ARB_STATE_FILE}.$$"
    {
        printf 'state=%s\n' "$NEW_STATE"
        printf 'target_pkg=%s\n' "$NEW_TARGET_PKG"
        printf 'target_pid=%s\n' "$NEW_TARGET_PID"
        printf 'candidate_since=%s\n' "$NEW_CANDIDATE_SINCE"
        printf 'lease_start=%s\n' "$NEW_LEASE_START"
        printf 'last_foreground=%s\n' "$NEW_LAST_FOREGROUND"
        printf 'pid_absent_since=%s\n' "$NEW_PID_ABSENT_SINCE"
        printf 'baseline_owner=%s\n' "$NEW_BASELINE_OWNER"
        printf 'updated_epoch=%s\n' "$NOW"
        printf 'proposed_owner=%s\n' "$PROPOSED_OWNER"
        printf 'reason=%s\n' "$REASON"
        printf 'apply_enabled=%s\n' "$APPLY_ENABLED"
        printf 'apply_result=%s\n' "$APPLY_RESULT"
        printf 'uperf_root_instances=%s\n' "$(uperf_root_instance_count)"
        printf 'uperf_normalized=%s\n' "$UPERF_NORMALIZED"
        printf 'dry_run=%s\n' "$DRY_RUN_FLAG"
    } > "$_oa_tmp" 2>/dev/null && mv "$_oa_tmp" "$ARB_STATE_FILE" 2>/dev/null
}

append_history() {
    if [ ! -s "$ARB_HISTORY_FILE" ]; then
        printf '%s\n' 'epoch|screen|state|focus_pkg|focus_pid|target_pkg|target_pid|game_match|game_source|pixel_owner|proposed_owner|reason|ugt_detected|ugt_enabled|fas_detected|fas_active|fas_alive|fas_owner_state|fas_mode|external_kind|external_active|apply_enabled|apply_result|dry_run' > "$ARB_HISTORY_FILE" 2>/dev/null
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$NOW" "$(safe_field "$SCREEN_STATE")" "$(safe_field "$NEW_STATE")" \
        "$(safe_field "$FOCUS_PKG")" "$(safe_field "$FOCUS_PID")" \
        "$(safe_field "$NEW_TARGET_PKG")" "$(safe_field "$NEW_TARGET_PID")" \
        "$GAME_MATCH" "$(safe_field "$GAME_SOURCE")" "$CURRENT_OWNER" "$PROPOSED_OWNER" \
        "$(safe_field "$REASON")" "$UPERF_DETECTED" "$UPERF_MODULE_ENABLED" \
        "$FAS_RS_DETECTED" "$FAS_RS_ACTIVE" "$FAS_RS_PROCESS_ALIVE" \
        "$(safe_field "$FAS_RS_OWNER_STATE")" "$(safe_field "$FAS_RS_MODE")" \
        "$(safe_field "$EXTERNAL_SCHEDULER_KIND")" "$EXTERNAL_SCHEDULER_ACTIVE" \
        "$APPLY_ENABLED" "$(safe_field "$APPLY_RESULT")" "$DRY_RUN_FLAG" \
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
PREV_STATE=$(state_get state)
PREV_TARGET_PKG=$(state_get target_pkg)
PREV_TARGET_PID=$(state_get target_pid)
PREV_CANDIDATE_SINCE=$(num_or_zero "$(state_get candidate_since)")
PREV_LEASE_START=$(num_or_zero "$(state_get lease_start)")
PREV_LAST_FOREGROUND=$(num_or_zero "$(state_get last_foreground)")
PREV_PID_ABSENT_SINCE=$(num_or_zero "$(state_get pid_absent_since)")
PREV_BASELINE_OWNER=$(state_get baseline_owner)
case "$PREV_BASELINE_OWNER" in external|pixel) ;; *) PREV_BASELINE_OWNER="$CURRENT_OWNER" ;; esac

NEW_STATE="PIXEL_NORMAL"
NEW_TARGET_PKG=""
NEW_TARGET_PID="0"
NEW_CANDIDATE_SINCE="0"
NEW_LEASE_START="0"
NEW_LAST_FOREGROUND="0"
NEW_PID_ABSENT_SINCE="0"
NEW_BASELINE_OWNER="$PREV_BASELINE_OWNER"
PROPOSED_OWNER="$CURRENT_OWNER"
REASON="no_target_focus"
FOCUS_PKG=""
FOCUS_PIDS=""
FOCUS_PID="0"
GAME_SOURCE="none"
GAME_MATCH="no"

if [ -f "$ARB_DISABLE_FILE" ]; then
    NEW_STATE="ARB_DISABLED"
    NEW_TARGET_PKG="$PREV_TARGET_PKG"
    NEW_TARGET_PID="$PREV_TARGET_PID"
    NEW_CANDIDATE_SINCE="$PREV_CANDIDATE_SINCE"
    NEW_LEASE_START="$PREV_LEASE_START"
    NEW_LAST_FOREGROUND="$PREV_LAST_FOREGROUND"
    NEW_PID_ABSENT_SINCE="$PREV_PID_ABSENT_SINCE"
    PROPOSED_OWNER="$CURRENT_OWNER"
    REASON="arbiter_disabled"
    write_state
    append_history
    exit 0
elif [ "$SCREEN_STATE" != "on" ] && [ "$SCREEN_STATE" != "unknown" ]; then
    NEW_STATE="${PREV_STATE:-PIXEL_NORMAL}"
    NEW_TARGET_PKG="$PREV_TARGET_PKG"
    NEW_TARGET_PID="$PREV_TARGET_PID"
    NEW_CANDIDATE_SINCE="$PREV_CANDIDATE_SINCE"
    NEW_LEASE_START="$PREV_LEASE_START"
    NEW_LAST_FOREGROUND="$PREV_LAST_FOREGROUND"
    NEW_PID_ABSENT_SINCE="$PREV_PID_ABSENT_SINCE"
    PROPOSED_OWNER="$CURRENT_OWNER"
    REASON="screen_off_noop"
    write_state
    append_history
    exit 0
fi

if command -v detect_uperf_module >/dev/null 2>&1; then
    detect_uperf_module 2>/dev/null
fi
if command -v detect_fas_rs_scheduler >/dev/null 2>&1; then
    detect_fas_rs_scheduler 2>/dev/null
fi
if command -v detect_external_scheduler >/dev/null 2>&1; then
    detect_external_scheduler 2>/dev/null
fi

FOCUS_PKG=$(foreground_package_name)
FOCUS_PIDS=$(pkg_pids "$FOCUS_PKG")
FOCUS_PID=$(first_word "$FOCUS_PIDS")
[ -n "$FOCUS_PID" ] || FOCUS_PID="0"

if package_matches_fas_target "$FOCUS_PKG"; then
    GAME_MATCH="yes"
fi

if [ "$GAME_MATCH" = "yes" ]; then
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
        else
            NEW_LEASE_START="$NOW"
            NEW_BASELINE_OWNER="$CURRENT_OWNER"
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
            NEW_STATE="PIXEL_NORMAL"
            NEW_TARGET_PKG=""
            NEW_TARGET_PID="0"
            NEW_CANDIDATE_SINCE="0"
            NEW_LEASE_START="0"
            NEW_LAST_FOREGROUND="0"
            NEW_PID_ABSENT_SINCE="0"
            PROPOSED_OWNER="$NEW_BASELINE_OWNER"
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
            NEW_STATE="PIXEL_NORMAL"
            NEW_TARGET_PKG=""
            NEW_TARGET_PID="0"
            NEW_CANDIDATE_SINCE="0"
            NEW_LEASE_START="0"
            NEW_LAST_FOREGROUND="0"
            NEW_PID_ABSENT_SINCE="0"
            PROPOSED_OWNER="$NEW_BASELINE_OWNER"
            REASON="exit_idle_expired"
        fi
    fi
fi

apply_owner_decision >/dev/null 2>&1 || true
write_state
append_history
exit 0
