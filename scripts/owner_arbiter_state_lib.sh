#!/system/bin/sh

# owner arbiter 的状态读取、持久化与 retry guard。

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
