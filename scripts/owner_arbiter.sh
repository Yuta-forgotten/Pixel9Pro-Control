#!/system/bin/sh
#
# Phase A owner arbiter (dry-run).
# Observes Pixel9Pro-Control / UGT / fas-rs ownership inputs and records the
# owner decision that would be taken by a future guarded arbiter.  This script
# intentionally does not change .cpu_sched_owner, start/stop uperf, start/stop
# fas-rs, or write kernel/system tuning nodes.

ACTION="${1:-tick}"
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
ARB_STATE_FILE="$STATE_DIR/.arbiter_state"
ARB_HISTORY_FILE="$STATE_DIR/.arbiter_history"
LEASE_GAME_LIST="$FAS_ROOT/.lease_game_list"

ENTER_DEBOUNCE_S="${ARB_ENTER_DEBOUNCE_S:-3}"
MIN_LEASE_S="${ARB_MIN_LEASE_S:-420}"
PID_ABSENT_CONFIRM_S="${ARB_PID_ABSENT_CONFIRM_S:-8}"
EXIT_IDLE_AFTER_S="${ARB_EXIT_IDLE_AFTER_S:-90}"
ARB_HISTORY_MAX="${ARB_HISTORY_MAX:-500}"

# Defaults if scheduler_detect_lib.sh is unavailable.
UPERF_DETECTED="no"
UPERF_MODULE_ENABLED="no"
FAS_RS_DETECTED="no"
FAS_RS_ACTIVE="no"
FAS_RS_PROCESS_ALIVE="no"
FAS_RS_OWNER_STATE=""
FAS_RS_MODE=""
FAS_RS_MODULE_PATH=""
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
    _oa_pkg=$(dumpsys activity top 2>/dev/null | sed -n 's/^  ACTIVITY \([^/ ][^/ ]*\)\/.*/\1/p' | head -n 1)
    if [ -z "$_oa_pkg" ]; then
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
    fi
    printf '%s' "$_oa_pkg" | tr -d ' \r\n\t'
}

game_source_path() {
    if [ -s "$LEASE_GAME_LIST" ]; then
        printf '%s' "$LEASE_GAME_LIST"
        return 0
    fi

    for _oa_file in \
        "$FAS_ROOT/games.toml" \
        "$FAS_RS_MODULE_PATH/games.toml" \
        /data/adb/modules_update/fas_rs/games.toml \
        /data/adb/modules/fas_rs/games.toml; do
        [ -s "$_oa_file" ] || continue
        printf '%s' "$_oa_file"
        return 0
    done
    return 1
}

game_source_kind() {
    case "$1" in
        "$LEASE_GAME_LIST") printf 'lease_list' ;;
        *.toml) printf 'games_toml' ;;
        *) printf 'unknown' ;;
    esac
}

package_in_game_source() {
    _oa_pkg="$1"
    _oa_source="$2"
    [ -n "$_oa_pkg" ] && [ -s "$_oa_source" ] || return 1

    case "$(game_source_kind "$_oa_source")" in
        lease_list)
            awk -v p="$_oa_pkg" '$0 == p { found = 1 } END { exit(found ? 0 : 1) }' "$_oa_source" 2>/dev/null
            ;;
        games_toml)
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
            ;;
        *)
            return 1
            ;;
    esac
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
        printf 'dry_run=1\n'
    } > "$_oa_tmp" 2>/dev/null && mv "$_oa_tmp" "$ARB_STATE_FILE" 2>/dev/null
}

append_history() {
    if [ ! -s "$ARB_HISTORY_FILE" ]; then
        printf '%s\n' 'epoch|screen|state|focus_pkg|focus_pid|target_pkg|target_pid|game_match|game_source|pixel_owner|proposed_owner|reason|ugt_detected|ugt_enabled|fas_detected|fas_active|fas_alive|fas_owner_state|fas_mode|external_kind|external_active|dry_run' > "$ARB_HISTORY_FILE" 2>/dev/null
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|1\n' \
        "$NOW" "$(safe_field "$SCREEN_STATE")" "$(safe_field "$NEW_STATE")" \
        "$(safe_field "$FOCUS_PKG")" "$(safe_field "$FOCUS_PID")" \
        "$(safe_field "$NEW_TARGET_PKG")" "$(safe_field "$NEW_TARGET_PID")" \
        "$GAME_MATCH" "$(safe_field "$GAME_SOURCE")" "$CURRENT_OWNER" "$PROPOSED_OWNER" \
        "$(safe_field "$REASON")" "$UPERF_DETECTED" "$UPERF_MODULE_ENABLED" \
        "$FAS_RS_DETECTED" "$FAS_RS_ACTIVE" "$FAS_RS_PROCESS_ALIVE" \
        "$(safe_field "$FAS_RS_OWNER_STATE")" "$(safe_field "$FAS_RS_MODE")" \
        "$(safe_field "$EXTERNAL_SCHEDULER_KIND")" "$EXTERNAL_SCHEDULER_ACTIVE" \
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

GAME_SOURCE=$(game_source_path 2>/dev/null)
[ -n "$GAME_SOURCE" ] || GAME_SOURCE="none"
if [ "$GAME_SOURCE" != "none" ] && package_in_game_source "$FOCUS_PKG" "$GAME_SOURCE"; then
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

write_state
append_history
exit 0
