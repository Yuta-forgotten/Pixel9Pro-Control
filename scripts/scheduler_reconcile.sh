#!/system/bin/sh

# One-shot scheduler reconciliation. Mutation is bounded by both attempts and
# a deadline. Once a generation reaches success or failure, service ticks do
# not reopen it; only a new boot or explicit user retry may create a generation.

ACTION="${1:-boot}"
MODDIR="${2:-${0%/scripts/scheduler_reconcile.sh}}"
FAS_ROOT="${SCHEDULER_RECONCILE_FAS_ROOT:-/data/adb/fas_rs}"

for _sr_lib in runtime_defaults_lib.sh scheduler_owner_lib.sh scheduler_boot_mode_lib.sh scheduler_detect_lib.sh cpu_profile_lib.sh; do
    [ -r "$MODDIR/scripts/$_sr_lib" ] || { echo "scheduler_reconcile: missing $_sr_lib" >&2; exit 65; }
    . "$MODDIR/scripts/$_sr_lib" 2>/dev/null || exit 65
done

scheduler_owner_init "$MODDIR" "$FAS_ROOT"
sbm_init "$MODDIR" "$FAS_ROOT"
case "$ACTION" in
    health|status|boot|repair|retry) ;;
    *) echo "Usage: $0 [boot|health|repair|retry|status] [MODDIR]" >&2; exit 64 ;;
esac

sr_record_health() {
    SBM_HEALTH_BOOT_ID=$(sbm_boot_id)
    SBM_HEALTH_MODE="$1"
    SBM_HEALTH_STATUS="$2"
    SBM_HEALTH_REASON="$3"
    SBM_HEALTH_PROFILE=$(cat "$MODDIR/.current_profile" 2>/dev/null | tr -d ' \r\n\t')
    [ -n "$SBM_HEALTH_PROFILE" ] || SBM_HEALTH_PROFILE=unknown
    SBM_HEALTH_PROFILE_VERIFIED="${4:-unknown}"
    SBM_HEALTH_CPUFREQ_PERMISSIONS="${SBM_PROBE_CPUFREQ_PERMISSIONS:-unknown}"
    SBM_HEALTH_POWERHAL_FAILURES="${SBM_PROBE_POWERHAL_FAILURES:-unknown}"
    SBM_HEALTH_UGT_ROOTS="${SBM_PROBE_UGT_ROOTS:-0}"
    SBM_HEALTH_FAS_ALIVE="${SBM_PROBE_FAS_ALIVE:-no}"
    sbm_commit_health
}

sr_commit_terminal() {
    SBM_PHASE="$1"
    SBM_FINAL=yes
    SBM_OK="$2"
    SBM_RESULT="$3"
    SBM_REASON="$4"
    SBM_OBSERVED_BOOT_ID=$(sbm_boot_id)
    SBM_REBOOT_REQUIRED="$5"
    sbm_commit_terminal_bounded
}

sr_restore_file() {
    _sr_restore_path="$1"
    _sr_restore_existed="$2"
    _sr_restore_value="$3"
    if [ "$_sr_restore_existed" = "1" ]; then
        sbm_atomic_write "$_sr_restore_path" "$_sr_restore_value"
    else
        rm -f "$_sr_restore_path" 2>/dev/null
        [ ! -e "$_sr_restore_path" ]
    fi
}

sr_publish_write() {
    _sr_publish_path="$1"
    _sr_publish_value="$2"
    _sr_publish_step="$3"
    if [ "$SBM_TEST_MODE" = "1" ] \
        && [ "${SR_TEST_FAIL_PUBLISH_STEP:-}" = "$_sr_publish_step" ] \
        && [ -f "${SR_TEST_FAIL_PUBLISH_MARKER:-/nonexistent}" ]; then
        rm -f "$SR_TEST_FAIL_PUBLISH_MARKER" 2>/dev/null
        return 1
    fi
    sbm_atomic_write "$_sr_publish_path" "$_sr_publish_value"
}

sr_publish_owner_transaction() {
    _sr_new_owner="$1"
    _sr_new_fas_state="$2"
    SR_OWNER_ROLLBACK_OK=no
    SR_OLD_DESIRED_EXISTED=0
    SR_OLD_EFFECTIVE_EXISTED=0
    SR_OLD_FAS_EXISTED=0
    SR_OLD_DESIRED_VALUE=""
    SR_OLD_EFFECTIVE_VALUE=""
    SR_OLD_FAS_VALUE=""
    if [ -e "$SO_DESIRED_FILE" ]; then
        [ -f "$SO_DESIRED_FILE" ] || return 1
        SR_OLD_DESIRED_VALUE=$(cat "$SO_DESIRED_FILE" 2>/dev/null) || return 1
        SR_OLD_DESIRED_EXISTED=1
    fi
    if [ -e "$SO_EFFECTIVE_FILE" ]; then
        [ -f "$SO_EFFECTIVE_FILE" ] || return 1
        SR_OLD_EFFECTIVE_VALUE=$(cat "$SO_EFFECTIVE_FILE" 2>/dev/null) || return 1
        SR_OLD_EFFECTIVE_EXISTED=1
    fi
    if [ -e "$FAS_ROOT/.owner_state" ]; then
        [ -f "$FAS_ROOT/.owner_state" ] || return 1
        SR_OLD_FAS_VALUE=$(cat "$FAS_ROOT/.owner_state" 2>/dev/null) || return 1
        SR_OLD_FAS_EXISTED=1
    fi

    if sr_publish_write "$FAS_ROOT/.owner_state" "$_sr_new_fas_state" fas_owner \
        && sr_publish_write "$SO_DESIRED_FILE" "$_sr_new_owner" desired_owner \
        && sr_publish_write "$SO_EFFECTIVE_FILE" "$_sr_new_owner" effective_owner \
        && [ "$(cat "$FAS_ROOT/.owner_state" 2>/dev/null)" = "$_sr_new_fas_state" ] \
        && [ "$(so_read_desired_owner)" = "$_sr_new_owner" ] \
        && [ "$(so_read_effective_owner)" = "$_sr_new_owner" ]; then
        return 0
    fi

    _sr_owner_rollback=1
    sr_restore_file "$SO_EFFECTIVE_FILE" "$SR_OLD_EFFECTIVE_EXISTED" "$SR_OLD_EFFECTIVE_VALUE" || _sr_owner_rollback=0
    sr_restore_file "$SO_DESIRED_FILE" "$SR_OLD_DESIRED_EXISTED" "$SR_OLD_DESIRED_VALUE" || _sr_owner_rollback=0
    sr_restore_file "$FAS_ROOT/.owner_state" "$SR_OLD_FAS_EXISTED" "$SR_OLD_FAS_VALUE" || _sr_owner_rollback=0
    [ "$_sr_owner_rollback" -eq 1 ] && SR_OWNER_ROLLBACK_OK=yes
    return 1
}

sr_verify_profile_stable() {
    _sr_verify_deadline="$1"
    _sr_sample=1
    while [ "$_sr_sample" -le "$SBM_VERIFY_SAMPLES" ] 2>/dev/null; do
        _sr_verify_now=$(sbm_now)
        [ "$_sr_verify_now" -le "$_sr_verify_deadline" ] 2>/dev/null || return 1
        sh "$MODDIR/scripts/cpu_profile.sh" verify "$MODDIR" >/dev/null 2>&1 || return 1
        _sr_sample=$((_sr_sample + 1))
        if [ "$_sr_sample" -le "$SBM_VERIFY_SAMPLES" ] 2>/dev/null; then
            _sr_verify_now=$(sbm_now)
            _sr_verify_remaining=$((_sr_verify_deadline - _sr_verify_now))
            [ "$_sr_verify_remaining" -ge "$SBM_VERIFY_INTERVAL_S" ] 2>/dev/null || return 1
            sleep "$SBM_VERIFY_INTERVAL_S"
        fi
    done
    return 0
}

sr_apply_pixel_bounded() {
    _sr_profile=$(cat "$MODDIR/.current_profile" 2>/dev/null | tr -d ' \r\n\t')
    _sr_profile=$(cpu_profile_normalize_runtime "$_sr_profile" balanced)
    _sr_deadline=$(( $(sbm_now) + SBM_WRITE_DEADLINE_S ))
    SBM_ATTEMPTS=0
    while [ "$SBM_ATTEMPTS" -lt "$SBM_MAX_WRITE_ATTEMPTS" ] 2>/dev/null; do
        _sr_now=$(sbm_now)
        [ "$_sr_now" -le "$_sr_deadline" ] 2>/dev/null || break
        SBM_ATTEMPTS=$((SBM_ATTEMPTS + 1))
        SBM_PHASE=applying
        SBM_RESULT=applying_pixel_profile
        SBM_REASON="attempt_${SBM_ATTEMPTS}"
        sbm_commit_state >/dev/null 2>&1 || return 74
        if sh "$MODDIR/scripts/cpu_profile.sh" "$_sr_profile" "$MODDIR" force >/dev/null 2>&1 \
            && sr_verify_profile_stable "$_sr_deadline"; then
            return 0
        fi
        [ "$SBM_ATTEMPTS" -ge "$SBM_MAX_WRITE_ATTEMPTS" ] 2>/dev/null || sleep "$SBM_RETRY_SLEEP_S"
    done
    return 1
}

sr_prepare_generation() {
    _sr_mode="$1"
    _sr_kind="$2"
    _sr_now=$(sbm_now)
    SBM_TRANSITION_ID="$(sbm_boot_id):${_sr_now}:${_sr_mode}:${_sr_kind}"
    SBM_TARGET_MODE="$_sr_mode"
    SBM_EFFECTIVE_MODE=$(sbm_owner_to_mode "$(so_read_effective_owner)")
    SBM_PHASE=verifying
    SBM_FINAL=no
    SBM_OK=pending
    SBM_RESULT="verifying_${_sr_mode}"
    SBM_REASON="${_sr_kind}_generation"
    SBM_ATTEMPTS=0
    SBM_DEADLINE_EPOCH=$((_sr_now + SBM_WRITE_DEADLINE_S))
    SBM_STAGED_BOOT_ID=$(sbm_state_value "$SBM_STATE_FILE" staged_boot_id 2>/dev/null)
    SBM_OBSERVED_BOOT_ID=$(sbm_boot_id)
    SBM_PREVIOUS_DESIRED=$(so_read_desired_owner)
    SBM_PREVIOUS_MODULE_STATE=$(sbm_apd_module_state 2>/dev/null || printf unknown)
    [ "$_sr_kind" = "repair" ] && SBM_AUTO_REPAIR_USED=yes || SBM_AUTO_REPAIR_USED=no
    SBM_REBOOT_REQUIRED=no
    sbm_commit_state
}

sr_resolve_mode() {
    sbm_load_state
    _sr_current_boot=$(sbm_boot_id)
    if [ "$ACTION" = "boot" ] \
        && [ "$SBM_PHASE" = "pending_reboot" ] \
        && [ -n "$SBM_STAGED_BOOT_ID" ]; then
        if [ "$SBM_STAGED_BOOT_ID" = "$_sr_current_boot" ]; then
            printf '__same_boot_pending__'
        else
            printf '%s' "$SBM_TARGET_MODE"
        fi
        return 0
    fi
    if [ "$ACTION" = "boot" ] \
        && [ "$SBM_FINAL" = "yes" ] \
        && [ "$SBM_OBSERVED_BOOT_ID" = "$_sr_current_boot" ]; then
        case "$SBM_PHASE" in
            success) printf '__same_boot_success__' ;;
            failed|blocked) printf '__same_boot_failure__' ;;
            *) printf '__same_boot_success__' ;;
        esac
        return 0
    fi

    _sr_module_state=$(sbm_apd_module_state 2>/dev/null) || _sr_module_state=unknown
    case "$_sr_module_state" in
        enabled) printf 'ugt' ;;
        disabled|absent) printf 'pixel' ;;
        *) return 1 ;;
    esac
}

sr_health_snapshot() {
    printf '%s|%s|%s|%s|%s|%s' \
        "$(so_read_desired_owner)" \
        "$(so_read_effective_owner)" \
        "$(cat "$MODDIR/.current_profile" 2>/dev/null | tr -d ' \r\n\t')" \
        "$(sbm_state_value "$SBM_STATE_FILE" transition_id 2>/dev/null)" \
        "$(sbm_state_value "$SBM_STATE_FILE" phase 2>/dev/null)" \
        "$(sbm_state_value "$SBM_STATE_FILE" effective_mode 2>/dev/null)"
}

sr_health_verify_stable() {
    SR_HEALTH_DEFER_REASON=""
    if so_transition_lock_is_active; then
        SR_HEALTH_DEFER_REASON=transition_in_progress
        return 7
    fi
    _sr_health_before=$(sr_health_snapshot)
    _sr_health_verify_rc=0
    sh "$MODDIR/scripts/cpu_profile.sh" verify "$MODDIR" >/dev/null 2>&1 || _sr_health_verify_rc=$?
    _sr_health_after=$(sr_health_snapshot)
    if so_transition_lock_is_active; then
        SR_HEALTH_DEFER_REASON=transition_in_progress
        return 7
    fi
    if [ "$_sr_health_before" != "$_sr_health_after" ]; then
        SR_HEALTH_DEFER_REASON=state_changed_during_probe
        return 7
    fi
    [ "$_sr_health_verify_rc" -eq 0 ] && return 0
    return 5
}

sr_health_only() {
    _sr_mode=$(sbm_owner_to_mode "$(so_read_desired_owner)")
    if so_transition_lock_is_active; then
        return 7
    fi

    # A valid fas-rs game lease temporarily replaces either daily baseline.
    # Health must not probe the idle Pixel/UGT contract while that lease owns
    # the runtime scheduler; simultaneous UGT+fas-rs processes remain a real
    # conflict and therefore continue into the normal blocked probe path.
    _sr_effective_owner=$(so_read_effective_owner)
    _sr_fas_owner_state=$(cat "$FAS_ROOT/.owner_state" 2>/dev/null | tr -d '\r\n')
    if sbm_fas_process_alive; then _sr_fas_alive=yes; else _sr_fas_alive=no; fi
    _sr_ugt_roots=$(sbm_uperf_root_instances)
    if [ "$_sr_effective_owner" = "external" ] \
        && [ "$_sr_ugt_roots" = "0" ] \
        && scheduler_fas_owner_lease_active "$_sr_fas_owner_state" "$_sr_fas_alive"; then
        SBM_PROBE_FAS_ALIVE="$_sr_fas_alive"
        SBM_PROBE_UGT_ROOTS="$_sr_ugt_roots"
        sr_record_health "$_sr_mode" deferred fas_rs_runtime_lease unknown
        return 7
    fi

    _sr_control_before=$(sr_health_snapshot)
    _sr_probe_rc=0
    sbm_probe_control_plane "$_sr_mode" || _sr_probe_rc=$?
    _sr_control_after=$(sr_health_snapshot)
    if so_transition_lock_is_active; then
        return 7
    fi
    if [ "$_sr_control_before" != "$_sr_control_after" ]; then
        return 7
    fi
    if [ "$_sr_probe_rc" -ne 0 ]; then
        sr_record_health "$_sr_mode" blocked "$SBM_PROBE_REASON" no >/dev/null 2>&1 || true
        return 6
    fi
    if [ "$_sr_mode" = "pixel" ]; then
        if [ "$_sr_effective_owner" != "pixel" ]; then
            _sr_external_reason=effective_owner_external
            sr_record_health pixel deferred "$_sr_external_reason" unknown
            return 7
        fi
        sr_health_verify_stable
        _sr_health_rc=$?
        case "$_sr_health_rc" in
            0)
                sr_record_health pixel healthy verified yes
                return 0
                ;;
            7)
                return 7
                ;;
        esac

        sleep "$SBM_HEALTH_RECHECK_DELAY_S"
        sr_health_verify_stable
        _sr_health_rc=$?
        case "$_sr_health_rc" in
            0)
                sr_record_health pixel healthy transient_mismatch_cleared yes
                return 0
                ;;
            7)
                return 7
                ;;
            *)
                sr_record_health pixel drift profile_contract_mismatch no
                return 5
                ;;
        esac
    fi
    sr_record_health ugt healthy ugt_baseline_verified unknown
    return 0
}

case "$ACTION" in
    status)
        cat "$SBM_STATE_FILE" 2>/dev/null
        cat "$SBM_TERMINAL_FILE" 2>/dev/null
        cat "$SBM_HEALTH_FILE" 2>/dev/null
        exit 0
        ;;
    health)
        sr_health_only
        exit $?
        ;;
    boot|repair|retry) ;;
    *) echo "Usage: $0 [boot|health|repair|retry|status] [MODDIR]" >&2; exit 64 ;;
esac

_sr_mode=$(sr_resolve_mode) || exit 66
case "$_sr_mode" in
    __same_boot_pending__|__same_boot_success__) exit 0 ;;
    __same_boot_failure__) exit 77 ;;
esac
if [ "$ACTION" = "repair" ]; then
    sbm_load_state
    [ "$_sr_mode" = "pixel" ] || exit 77
    [ "$SBM_AUTO_REPAIR_USED" != "yes" ] || exit 77
    [ "$SBM_PHASE" = "success" ] && [ "$SBM_EFFECTIVE_MODE" = "pixel" ] || exit 77
    [ "$(so_read_desired_owner)" = "pixel" ] && [ "$(so_read_effective_owner)" = "pixel" ] || exit 77
fi

if ! so_acquire_transition_lock; then
    exit 75
fi
trap 'so_release_transition_lock >/dev/null 2>&1 || true' EXIT
trap 'so_release_transition_lock >/dev/null 2>&1 || true; exit 130' INT
trap 'so_release_transition_lock >/dev/null 2>&1 || true; exit 143' TERM
so_migrate_state >/dev/null 2>&1 || exit 66

if [ "$ACTION" = "repair" ]; then
    sbm_load_state
    [ "$SBM_AUTO_REPAIR_USED" != "yes" ] || exit 77
    [ "$SBM_PHASE" = "success" ] && [ "$SBM_EFFECTIVE_MODE" = "pixel" ] || exit 77
    [ "$(so_read_desired_owner)" = "pixel" ] && [ "$(so_read_effective_owner)" = "pixel" ] || exit 77
    if ! sbm_probe_control_plane pixel; then
        sr_record_health pixel blocked "$SBM_PROBE_REASON" no >/dev/null 2>&1 || true
        exit 6
    fi
    if sh "$MODDIR/scripts/cpu_profile.sh" verify "$MODDIR" >/dev/null 2>&1; then
        sr_record_health pixel healthy repair_not_needed yes >/dev/null 2>&1 || true
        exit 0
    fi
    sr_prepare_generation pixel repair || exit 74
else
    _sr_locked_mode=$(sr_resolve_mode) || exit 66
    case "$_sr_locked_mode" in
        __same_boot_pending__|__same_boot_success__) exit 0 ;;
        __same_boot_failure__) exit 77 ;;
    esac
    _sr_mode="$_sr_locked_mode"
    sr_prepare_generation "$_sr_mode" "$ACTION" || exit 74
fi

if [ "$_sr_mode" = "ugt" ]; then
    _sr_check=1
    while [ "$_sr_check" -le "$SBM_BOOT_VERIFY_ATTEMPTS" ] 2>/dev/null; do
        if sbm_probe_control_plane ugt; then
            if ! sr_publish_owner_transaction external 'external:uperf:baseline'; then
                _sr_publish_reason=state_commit_failed:rollback_incomplete
                _sr_publish_result=failed_publish_ugt_effective_rollback_incomplete
                [ "$SR_OWNER_ROLLBACK_OK" = "yes" ] \
                    && _sr_publish_reason=state_commit_failed:rollback_complete \
                    && _sr_publish_result=failed_publish_ugt_effective_rolled_back
                sr_commit_terminal failed no "$_sr_publish_result" "$_sr_publish_reason" yes >/dev/null 2>&1 || true
                exit 1
            fi
            SBM_EFFECTIVE_MODE=ugt
            sr_record_health ugt healthy ugt_baseline_verified unknown >/dev/null 2>&1 || true
            sr_commit_terminal success yes active_ugt ugt_boot_verified no
            exit $?
        fi
        [ "$ACTION" = "boot" ] || break
        _sr_check=$((_sr_check + 1))
        [ "$_sr_check" -gt "$SBM_BOOT_VERIFY_ATTEMPTS" ] 2>/dev/null || sleep "$SBM_BOOT_VERIFY_INTERVAL_S"
    done
    sr_record_health ugt blocked "$SBM_PROBE_REASON" no >/dev/null 2>&1 || true
    sr_commit_terminal failed no failed_ugt_boot "$SBM_PROBE_REASON" yes >/dev/null 2>&1 || true
    exit 1
fi

if ! sbm_probe_control_plane pixel; then
    sr_record_health pixel blocked "$SBM_PROBE_REASON" no >/dev/null 2>&1 || true
    sr_commit_terminal blocked no blocked_external_residue "$SBM_PROBE_REASON" yes >/dev/null 2>&1 || true
    exit 6
fi

if sr_apply_pixel_bounded; then
    _sr_pixel_profile=$(cat "$MODDIR/.current_profile" 2>/dev/null | tr -d ' \r\n\t')
    if ! sr_publish_owner_transaction pixel "pixel:profile:$_sr_pixel_profile"; then
        _sr_publish_reason=state_commit_failed:rollback_incomplete
        _sr_publish_result=failed_publish_pixel_effective_rollback_incomplete
        [ "$SR_OWNER_ROLLBACK_OK" = "yes" ] \
            && _sr_publish_reason=state_commit_failed:rollback_complete \
            && _sr_publish_result=failed_publish_pixel_effective_rolled_back
        sr_commit_terminal failed no "$_sr_publish_result" "$_sr_publish_reason" yes >/dev/null 2>&1 || true
        exit 1
    fi
    SBM_EFFECTIVE_MODE=pixel
    sr_record_health pixel healthy verified yes >/dev/null 2>&1 || true
    sr_commit_terminal success yes active_pixel pixel_profile_verified no
    exit $?
fi

sr_record_health pixel drift profile_apply_exhausted no >/dev/null 2>&1 || true
sr_commit_terminal failed no failed_pixel_apply retry_budget_exhausted no >/dev/null 2>&1 || true
exit 1
