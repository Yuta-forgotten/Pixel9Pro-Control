#!/system/bin/sh

# profile 持久状态的文件名、合法值与兜底读取统一由本契约维护。
PROFILE_STATE_HISTORY_MAX="${PROFILE_STATE_HISTORY_MAX:-500}"
case "$PROFILE_STATE_HISTORY_MAX" in ''|*[!0-9]*) PROFILE_STATE_HISTORY_MAX=500 ;; esac
[ "$PROFILE_STATE_HISTORY_MAX" -ge 1 ] 2>/dev/null && [ "$PROFILE_STATE_HISTORY_MAX" -le 5000 ] 2>/dev/null \
    || PROFILE_STATE_HISTORY_MAX=500

profile_state_init() {
    _ps_root="$1"
    [ -n "$_ps_root" ] || return 1
    PROFILE_FILE="$_ps_root/.current_profile"
    PROFILE_POLICY_FILE="$_ps_root/.profile_policy"
    PROFILE_MANUAL_FILE="$_ps_root/.profile_manual"
    PROFILE_AUTO_REASON_FILE="$_ps_root/.profile_auto_reason"
    PROFILE_HISTORY_FILE="$_ps_root/.profile_history"
}

profile_state_policy_is_valid() {
    case "$1" in
        manual|auto) return 0 ;;
        *) return 1 ;;
    esac
}

profile_state_read_profile() {
    _ps_path="$1"
    _ps_default="$2"
    _ps_value=$(cat "$_ps_path" 2>/dev/null | tr -d ' \n\r\t')
    if command -v cpu_profile_normalize_runtime >/dev/null 2>&1; then
        cpu_profile_normalize_runtime "$_ps_value" "$_ps_default"
    else
        printf '%s' "$_ps_default"
    fi
}

profile_state_read_active() {
    profile_state_read_profile "$PROFILE_FILE" "$1"
}

profile_state_read_manual() {
    profile_state_read_profile "$PROFILE_MANUAL_FILE" "$1"
}

profile_state_read_policy() {
    _ps_policy=$(cat "$PROFILE_POLICY_FILE" 2>/dev/null | tr -d ' \n\r\t')
    if profile_state_policy_is_valid "$_ps_policy"; then
        printf '%s' "$_ps_policy"
    else
        printf 'manual'
    fi
}

profile_state_reason_is_valid() {
    case "$1" in
        ''|*[!A-Za-z0-9_.:-]*) return 1 ;;
        *) return 0 ;;
    esac
}

profile_state_atomic_write() {
    command -v state_atomic_write >/dev/null 2>&1 \
        || . "${PROFILE_FILE%/*}/scripts/state_io_lib.sh" || return 1
    state_atomic_write "$1" "$2"
}
profile_state_restore_file() {
    _ps_restore_path="$1"
    _ps_restore_existed="$2"
    _ps_restore_value="$3"
    if [ "$_ps_restore_existed" = "1" ]; then
        profile_state_atomic_write "$_ps_restore_path" "$_ps_restore_value"
    else
        rm -f "$_ps_restore_path" 2>/dev/null \
            && [ ! -e "$_ps_restore_path" ]
    fi
}

profile_state_read_entry() {
    [ ! -L "$1" ] || return 1
    [ -e "$1" ] || return 0
    [ -f "$1" ] && cat "$1" 2>/dev/null
}

profile_state_commit() {
    _ps_new_active="$1"
    _ps_new_manual="$2"
    _ps_new_policy="$3"
    _ps_new_reason="$4"
    PROFILE_STATE_COMMIT_RESULT="invalid"
    PROFILE_STATE_ROLLBACK_RESULT="not_needed"

    command -v cpu_profile_is_valid >/dev/null 2>&1 \
        && cpu_profile_is_valid "$_ps_new_active" \
        && cpu_profile_is_valid "$_ps_new_manual" \
        && profile_state_policy_is_valid "$_ps_new_policy" \
        && profile_state_reason_is_valid "$_ps_new_reason" || return 1

    _ps_active_existed=0; [ -e "$PROFILE_FILE" ] && _ps_active_existed=1
    _ps_manual_existed=0; [ -e "$PROFILE_MANUAL_FILE" ] && _ps_manual_existed=1
    _ps_policy_existed=0; [ -e "$PROFILE_POLICY_FILE" ] && _ps_policy_existed=1
    _ps_reason_existed=0; [ -e "$PROFILE_AUTO_REASON_FILE" ] && _ps_reason_existed=1
    PROFILE_STATE_COMMIT_RESULT=entry_read_failed
    _ps_old_active=$(profile_state_read_entry "$PROFILE_FILE") || return 1
    _ps_old_manual=$(profile_state_read_entry "$PROFILE_MANUAL_FILE") || return 1
    _ps_old_policy=$(profile_state_read_entry "$PROFILE_POLICY_FILE") || return 1
    _ps_old_reason=$(profile_state_read_entry "$PROFILE_AUTO_REASON_FILE") || return 1

    if profile_state_atomic_write "$PROFILE_FILE" "$_ps_new_active" \
        && profile_state_atomic_write "$PROFILE_MANUAL_FILE" "$_ps_new_manual" \
        && profile_state_atomic_write "$PROFILE_POLICY_FILE" "$_ps_new_policy" \
        && profile_state_atomic_write "$PROFILE_AUTO_REASON_FILE" "$_ps_new_reason"; then
        PROFILE_STATE_COMMIT_RESULT="committed"
        return 0
    fi

    _ps_restore_failed=0
    profile_state_restore_file "$PROFILE_FILE" "$_ps_active_existed" "$_ps_old_active" || _ps_restore_failed=1
    profile_state_restore_file "$PROFILE_MANUAL_FILE" "$_ps_manual_existed" "$_ps_old_manual" || _ps_restore_failed=1
    profile_state_restore_file "$PROFILE_POLICY_FILE" "$_ps_policy_existed" "$_ps_old_policy" || _ps_restore_failed=1
    profile_state_restore_file "$PROFILE_AUTO_REASON_FILE" "$_ps_reason_existed" "$_ps_old_reason" || _ps_restore_failed=1
    if [ "$_ps_restore_failed" -eq 0 ]; then
        PROFILE_STATE_ROLLBACK_RESULT="complete"
    else
        PROFILE_STATE_ROLLBACK_RESULT="incomplete"
    fi
    PROFILE_STATE_COMMIT_RESULT="failed"
    return 1
}

profile_state_commit_active_reason() {
    _ps_new_active="$1"
    _ps_new_reason="$2"
    PROFILE_STATE_COMMIT_RESULT="invalid"
    PROFILE_STATE_ROLLBACK_RESULT="not_needed"

    command -v cpu_profile_is_valid >/dev/null 2>&1 \
        && cpu_profile_is_valid "$_ps_new_active" \
        && profile_state_reason_is_valid "$_ps_new_reason" || return 1

    _ps_active_existed=0; [ -e "$PROFILE_FILE" ] && _ps_active_existed=1
    _ps_reason_existed=0; [ -e "$PROFILE_AUTO_REASON_FILE" ] && _ps_reason_existed=1
    PROFILE_STATE_COMMIT_RESULT=entry_read_failed
    _ps_old_active=$(profile_state_read_entry "$PROFILE_FILE") || return 1
    _ps_old_reason=$(profile_state_read_entry "$PROFILE_AUTO_REASON_FILE") || return 1

    if profile_state_atomic_write "$PROFILE_FILE" "$_ps_new_active" \
        && profile_state_atomic_write "$PROFILE_AUTO_REASON_FILE" "$_ps_new_reason"; then
        PROFILE_STATE_COMMIT_RESULT="committed"
        return 0
    fi

    _ps_restore_failed=0
    profile_state_restore_file "$PROFILE_FILE" "$_ps_active_existed" "$_ps_old_active" || _ps_restore_failed=1
    profile_state_restore_file "$PROFILE_AUTO_REASON_FILE" "$_ps_reason_existed" "$_ps_old_reason" || _ps_restore_failed=1
    if [ "$_ps_restore_failed" -eq 0 ]; then
        PROFILE_STATE_ROLLBACK_RESULT="complete"
    else
        PROFILE_STATE_ROLLBACK_RESULT="incomplete"
    fi
    PROFILE_STATE_COMMIT_RESULT="failed"
    return 1
}

profile_state_safe_csv_field() {
    printf '%s' "$1" | tr ',\r\n' '___'
}

profile_state_append_history() (
    . "${PROFILE_FILE%/*}/scripts/state_io_lib.sh" || exit 1
    _ps_history_lock="${PROFILE_HISTORY_FILE}.lock"
    state_lock_acquire "$_ps_history_lock" 10 || exit 75
    _ps_hist_tmp=''; _ps_hist_trimmed=''
    trap 'rm -f "$_ps_hist_tmp" "$_ps_hist_trimmed"; state_lock_release "$_ps_history_lock" >/dev/null 2>&1' EXIT
    state_read_entry "$PROFILE_HISTORY_FILE" >/dev/null || exit 1
    _ps_hist_tmp=$(mktemp "${PROFILE_HISTORY_FILE}.append.XXXXXX") || exit 1
    _ps_hist_trimmed=$(mktemp "${PROFILE_HISTORY_FILE}.trim.XXXXXX") || exit 1
    if [ -e "$PROFILE_HISTORY_FILE" ]; then cat "$PROFILE_HISTORY_FILE" > "$_ps_hist_tmp" || exit 1; fi
    _ps_hist_profile="$1"
    _ps_hist_reason="$2"
    _ps_hist_epoch="$3"
    _ps_hist_policy="$4"
    _ps_hist_owner="$5"
    _ps_hist_charging="$6"
    _ps_hist_vs="$7"
    _ps_hist_sev="$8"
    _ps_hist_cap="$9"
    shift 9
    _ps_hist_response="$1"

    case "$_ps_hist_epoch" in ''|*[!0-9]*) return 1 ;; esac
    profile_state_policy_is_valid "$_ps_hist_policy" || return 1
    case "$_ps_hist_charging" in 0|1) ;; *) return 1 ;; esac
    case "$_ps_hist_vs" in ''|*[!0-9]*) return 1 ;; esac
    case "$_ps_hist_sev" in -1|0|1|2|3|4|5|6) ;; *) return 1 ;; esac
    case "$_ps_hist_cap" in -1|*[!0-9]*) [ "$_ps_hist_cap" = "-1" ] || return 1 ;; esac
    [ -n "$_ps_hist_response" ] || return 1

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$_ps_hist_epoch" \
        "$(profile_state_safe_csv_field "$_ps_hist_policy")" \
        "$(profile_state_safe_csv_field "$_ps_hist_owner")" \
        "$(profile_state_safe_csv_field "$_ps_hist_profile")" \
        "$(profile_state_safe_csv_field "$_ps_hist_reason")" \
        "$_ps_hist_charging" "$_ps_hist_vs" "$_ps_hist_sev" "$_ps_hist_cap" \
        "$(profile_state_safe_csv_field "$_ps_hist_response")" \
        >> "$_ps_hist_tmp" 2>/dev/null || exit 1

    tail -n "$PROFILE_STATE_HISTORY_MAX" "$_ps_hist_tmp" > "$_ps_hist_trimmed" \
        && state_atomic_from_file "$PROFILE_HISTORY_FILE" "$_ps_hist_trimmed"
)

profile_state_read_uclamp_cap() {
    _ps_cap=$(cat /proc/sys/kernel/sched_util_clamp_min 2>/dev/null | tr -d ' \n\r\t')
    case "$_ps_cap" in ''|*[!0-9]*) printf '%s' -1 ;; *) printf '%s' "$_ps_cap" ;; esac
}

profile_state_read_response_triplet() {
    _ps_resp0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/sched_pixel/response_time_ms 2>/dev/null | tr -d ' \n\r\t')
    _ps_resp4=$(cat /sys/devices/system/cpu/cpu4/cpufreq/sched_pixel/response_time_ms 2>/dev/null | tr -d ' \n\r\t')
    _ps_resp7=$(cat /sys/devices/system/cpu/cpu7/cpufreq/sched_pixel/response_time_ms 2>/dev/null | tr -d ' \n\r\t')
    [ -n "$_ps_resp0" ] || _ps_resp0="na"
    [ -n "$_ps_resp4" ] || _ps_resp4="na"
    [ -n "$_ps_resp7" ] || _ps_resp7="na"
    printf '%s/%s/%s' "$_ps_resp0" "$_ps_resp4" "$_ps_resp7"
}

profile_state_append_observation() {
    profile_state_append_history "$1" "$2" "$3" "$(profile_state_read_policy)" \
        "$4" "$5" "$6" "$7" "$(profile_state_read_uclamp_cap)" \
        "$(profile_state_read_response_triplet)"
}

profile_state_history_has_owner_field() {
    [ -s "$PROFILE_HISTORY_FILE" ] || return 1
    _ps_hist_last=$(tail -n 1 "$PROFILE_HISTORY_FILE" 2>/dev/null)
    _ps_hist_cols=$(printf '%s\n' "$_ps_hist_last" | awk -F',' '{print NF}')
    [ "${_ps_hist_cols:-0}" -ge 10 ] 2>/dev/null
}

profile_state_history_last() {
    tail -n 1 "$PROFILE_HISTORY_FILE" 2>/dev/null | tr -d '\r'
}
