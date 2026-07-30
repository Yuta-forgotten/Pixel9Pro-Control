#!/system/bin/sh

# cpufreq、uclamp 与 baseline 复读修复逻辑。

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
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ] && [ "${ARB_CPUFREQ_RESTORE_SETTLE_S:-}" = "0" ]; then
        _oa_settle_s=0
    else
        [ "$_oa_settle_s" -gt 0 ] 2>/dev/null || _oa_settle_s=2
    fi
    [ "$_oa_settle_s" -eq 0 ] 2>/dev/null || sleep "$_oa_settle_s"
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
        [ "$_oa_settle_s" -eq 0 ] 2>/dev/null || sleep 1
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

read_valid_pixel_profile() {
    profile_state_read_active balanced
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
