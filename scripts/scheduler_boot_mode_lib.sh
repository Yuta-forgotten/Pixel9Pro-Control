#!/system/bin/sh

# Reboot-selected daily baseline contract. UGT may mutate persistent sysfs
# runtime state during its boot service, so Pixel <-> UGT baseline changes are
# staged through the root manager and become effective only after a reboot.
# This does not prohibit a bounded fas-rs game lease inside either verified
# baseline; that runtime lease is owned by owner_arbiter.sh.

SBM_SCHEMA=1
SBM_MAX_WRITE_ATTEMPTS="${SBM_MAX_WRITE_ATTEMPTS:-3}"
SBM_WRITE_DEADLINE_S="${SBM_WRITE_DEADLINE_S:-30}"
SBM_RETRY_SLEEP_S="${SBM_RETRY_SLEEP_S:-2}"
SBM_VERIFY_SAMPLES="${SBM_VERIFY_SAMPLES:-3}"
SBM_VERIFY_INTERVAL_S="${SBM_VERIFY_INTERVAL_S:-5}"
SBM_BOOT_VERIFY_ATTEMPTS="${SBM_BOOT_VERIFY_ATTEMPTS:-9}"
SBM_BOOT_VERIFY_INTERVAL_S="${SBM_BOOT_VERIFY_INTERVAL_S:-10}"
SBM_HEALTH_INTERVAL_S="${SBM_HEALTH_INTERVAL_S:-300}"
SBM_HEALTH_RECHECK_DELAY_S="${SBM_HEALTH_RECHECK_DELAY_S:-2}"
SBM_STATE_COMMIT_ATTEMPTS="${SBM_STATE_COMMIT_ATTEMPTS:-3}"
SBM_STATE_COMMIT_RETRY_SLEEP_S="${SBM_STATE_COMMIT_RETRY_SLEEP_S:-1}"
SBM_LOGCAT_MAX_LINES="${SBM_LOGCAT_MAX_LINES:-2000}"
SBM_EXPECTED_CPUFREQ_MODE="${SBM_EXPECTED_CPUFREQ_MODE:-664}"
SBM_EXPECTED_CPUFREQ_UID="${SBM_EXPECTED_CPUFREQ_UID:-1000}"
SBM_EXPECTED_CPUFREQ_GID="${SBM_EXPECTED_CPUFREQ_GID:-1000}"

sbm_init() {
    SBM_MODDIR="${1:-/data/adb/modules/pixel9pro_control}"
    SBM_STATE_ROOT="${2:-/data/adb/fas_rs}"
    SBM_STATE_FILE="${SBM_STATE_FILE:-$SBM_MODDIR/.scheduler_boot_state}"
    SBM_TERMINAL_FILE="${SBM_TERMINAL_FILE:-$SBM_MODDIR/.scheduler_terminal_state}"
    SBM_HEALTH_FILE="${SBM_HEALTH_FILE:-$SBM_MODDIR/.scheduler_health_state}"
    SBM_APD_BIN="${SBM_APD_BIN:-/data/adb/ap/bin/apd}"
    SBM_UPERF_ID="${SBM_UPERF_ID:-uperf}"
    SBM_MODULES_ROOT="${SBM_MODULES_ROOT:-/data/adb/modules}"
    SBM_MODULES_UPDATE_ROOT="${SBM_MODULES_UPDATE_ROOT:-/data/adb/modules_update}"
    SBM_BOOT_ID_PATH="${SBM_BOOT_ID_PATH:-/proc/sys/kernel/random/boot_id}"
    SBM_CPUFREQ_ROOT="${SBM_CPUFREQ_ROOT:-/sys/devices/system/cpu/cpufreq}"
    SBM_LOGCAT_BIN="${SBM_LOGCAT_BIN:-/system/bin/logcat}"
    SBM_TEST_MODE="${SBM_TEST_MODE:-0}"
}

sbm_now() {
    if [ -n "${SBM_TEST_NOW:-}" ]; then
        printf '%s' "$SBM_TEST_NOW"
    else
        date +%s 2>/dev/null || printf '0'
    fi
}

sbm_boot_id() {
    _sbm_boot=$(cat "$SBM_BOOT_ID_PATH" 2>/dev/null | tr -d ' \r\n\t')
    [ -n "$_sbm_boot" ] || _sbm_boot=unknown
    printf '%s' "$_sbm_boot"
}

sbm_safe_field() {
    printf '%s' "$1" | tr '=|\r\n' '____'
}

sbm_state_value() {
    [ -s "$1" ] || return 1
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1 | tr -d '\r'
}

sbm_atomic_write() {
    _sbm_file="$1"
    _sbm_value="$2"
    [ -n "$_sbm_file" ] && [ ! -d "$_sbm_file" ] || return 1
    _sbm_tmp="${_sbm_file}.tmp.$$"
    if printf '%s' "$_sbm_value" > "$_sbm_tmp" 2>/dev/null \
        && mv "$_sbm_tmp" "$_sbm_file" 2>/dev/null \
        && [ "$(cat "$_sbm_file" 2>/dev/null)" = "$_sbm_value" ]; then
        return 0
    fi
    rm -f "$_sbm_tmp" 2>/dev/null
    return 1
}

sbm_owner_to_mode() {
    case "$1" in external) printf 'ugt' ;; *) printf 'pixel' ;; esac
}

sbm_mode_to_owner() {
    case "$1" in ugt) printf 'external' ;; pixel) printf 'pixel' ;; *) return 1 ;; esac
}

sbm_load_state() {
    SBM_TRANSITION_ID=$(sbm_state_value "$SBM_STATE_FILE" transition_id 2>/dev/null)
    SBM_TARGET_MODE=$(sbm_state_value "$SBM_STATE_FILE" target_mode 2>/dev/null)
    SBM_EFFECTIVE_MODE=$(sbm_state_value "$SBM_STATE_FILE" effective_mode 2>/dev/null)
    SBM_PHASE=$(sbm_state_value "$SBM_STATE_FILE" phase 2>/dev/null)
    SBM_FINAL=$(sbm_state_value "$SBM_STATE_FILE" final 2>/dev/null)
    SBM_OK=$(sbm_state_value "$SBM_STATE_FILE" ok 2>/dev/null)
    SBM_RESULT=$(sbm_state_value "$SBM_STATE_FILE" result 2>/dev/null)
    SBM_REASON=$(sbm_state_value "$SBM_STATE_FILE" reason 2>/dev/null)
    SBM_ATTEMPTS=$(sbm_state_value "$SBM_STATE_FILE" attempts 2>/dev/null)
    SBM_DEADLINE_EPOCH=$(sbm_state_value "$SBM_STATE_FILE" deadline_epoch 2>/dev/null)
    SBM_STAGED_BOOT_ID=$(sbm_state_value "$SBM_STATE_FILE" staged_boot_id 2>/dev/null)
    SBM_OBSERVED_BOOT_ID=$(sbm_state_value "$SBM_STATE_FILE" observed_boot_id 2>/dev/null)
    SBM_PREVIOUS_DESIRED=$(sbm_state_value "$SBM_STATE_FILE" previous_desired 2>/dev/null)
    SBM_PREVIOUS_MODULE_STATE=$(sbm_state_value "$SBM_STATE_FILE" previous_module_state 2>/dev/null)
    SBM_AUTO_REPAIR_USED=$(sbm_state_value "$SBM_STATE_FILE" auto_repair_used 2>/dev/null)
    SBM_REBOOT_REQUIRED=$(sbm_state_value "$SBM_STATE_FILE" reboot_required 2>/dev/null)
    case "$SBM_TARGET_MODE" in pixel|ugt) ;; *) SBM_TARGET_MODE=pixel ;; esac
    case "$SBM_EFFECTIVE_MODE" in pixel|ugt|unknown) ;; *) SBM_EFFECTIVE_MODE=unknown ;; esac
    case "$SBM_FINAL" in yes|no) ;; *) SBM_FINAL=no ;; esac
    case "$SBM_OK" in yes|no|pending) ;; *) SBM_OK=no ;; esac
    case "$SBM_ATTEMPTS" in ''|*[!0-9]*) SBM_ATTEMPTS=0 ;; esac
    case "$SBM_AUTO_REPAIR_USED" in yes|no) ;; *) SBM_AUTO_REPAIR_USED=no ;; esac
    case "$SBM_REBOOT_REQUIRED" in yes|no) ;; *) SBM_REBOOT_REQUIRED=no ;; esac

    _sbm_terminal_transition=$(sbm_state_value "$SBM_TERMINAL_FILE" transition_id 2>/dev/null)
    _sbm_terminal_phase=$(sbm_state_value "$SBM_TERMINAL_FILE" phase 2>/dev/null)
    _sbm_terminal_boot=$(sbm_state_value "$SBM_TERMINAL_FILE" observed_boot_id 2>/dev/null)
    _sbm_use_terminal=no
    case "$_sbm_terminal_phase" in success|failed|blocked)
        if [ -n "$_sbm_terminal_transition" ] \
            && { [ "$_sbm_terminal_transition" = "$SBM_TRANSITION_ID" ] \
                || { [ -z "$SBM_TRANSITION_ID" ] && [ "$_sbm_terminal_boot" = "$(sbm_boot_id)" ]; }; }; then
            _sbm_use_terminal=yes
        fi
        ;;
    esac
    if [ "$_sbm_use_terminal" = "yes" ]; then
        SBM_TRANSITION_ID="$_sbm_terminal_transition"
        SBM_TARGET_MODE=$(sbm_state_value "$SBM_TERMINAL_FILE" target_mode 2>/dev/null)
        SBM_EFFECTIVE_MODE=$(sbm_state_value "$SBM_TERMINAL_FILE" effective_mode 2>/dev/null)
        SBM_PHASE="$_sbm_terminal_phase"
        SBM_FINAL=$(sbm_state_value "$SBM_TERMINAL_FILE" final 2>/dev/null)
        SBM_OK=$(sbm_state_value "$SBM_TERMINAL_FILE" ok 2>/dev/null)
        SBM_RESULT=$(sbm_state_value "$SBM_TERMINAL_FILE" result 2>/dev/null)
        SBM_REASON=$(sbm_state_value "$SBM_TERMINAL_FILE" reason 2>/dev/null)
        SBM_ATTEMPTS=$(sbm_state_value "$SBM_TERMINAL_FILE" attempts 2>/dev/null)
        SBM_DEADLINE_EPOCH=$(sbm_state_value "$SBM_TERMINAL_FILE" deadline_epoch 2>/dev/null)
        SBM_STAGED_BOOT_ID=$(sbm_state_value "$SBM_TERMINAL_FILE" staged_boot_id 2>/dev/null)
        SBM_OBSERVED_BOOT_ID="$_sbm_terminal_boot"
        SBM_PREVIOUS_DESIRED=$(sbm_state_value "$SBM_TERMINAL_FILE" previous_desired 2>/dev/null)
        SBM_PREVIOUS_MODULE_STATE=$(sbm_state_value "$SBM_TERMINAL_FILE" previous_module_state 2>/dev/null)
        SBM_AUTO_REPAIR_USED=$(sbm_state_value "$SBM_TERMINAL_FILE" auto_repair_used 2>/dev/null)
        SBM_REBOOT_REQUIRED=$(sbm_state_value "$SBM_TERMINAL_FILE" reboot_required 2>/dev/null)
    fi
}

sbm_state_payload() {
    _sbm_now=$(sbm_now)
    printf '%s\n' \
        "schema=$SBM_SCHEMA" \
        "transition_id=$(sbm_safe_field "$SBM_TRANSITION_ID")" \
        "target_mode=$(sbm_safe_field "$SBM_TARGET_MODE")" \
        "effective_mode=$(sbm_safe_field "$SBM_EFFECTIVE_MODE")" \
        "phase=$(sbm_safe_field "$SBM_PHASE")" \
        "final=$(sbm_safe_field "$SBM_FINAL")" \
        "ok=$(sbm_safe_field "$SBM_OK")" \
        "result=$(sbm_safe_field "$SBM_RESULT")" \
        "reason=$(sbm_safe_field "$SBM_REASON")" \
        "attempts=$(sbm_safe_field "$SBM_ATTEMPTS")" \
        "deadline_epoch=$(sbm_safe_field "$SBM_DEADLINE_EPOCH")" \
        "staged_boot_id=$(sbm_safe_field "$SBM_STAGED_BOOT_ID")" \
        "observed_boot_id=$(sbm_safe_field "$SBM_OBSERVED_BOOT_ID")" \
        "previous_desired=$(sbm_safe_field "$SBM_PREVIOUS_DESIRED")" \
        "previous_module_state=$(sbm_safe_field "$SBM_PREVIOUS_MODULE_STATE")" \
        "auto_repair_used=$(sbm_safe_field "$SBM_AUTO_REPAIR_USED")" \
        "reboot_required=$(sbm_safe_field "$SBM_REBOOT_REQUIRED")" \
        "updated_epoch=$_sbm_now"
}

sbm_commit_state() {
    if [ "$SBM_TEST_MODE" = "1" ] \
        && [ -n "${SBM_TEST_FAIL_COMMIT_PHASE:-}" ] \
        && [ "$SBM_PHASE" = "$SBM_TEST_FAIL_COMMIT_PHASE" ] \
        && [ -f "${SBM_TEST_FAIL_COMMIT_MARKER:-/nonexistent}" ]; then
        rm -f "$SBM_TEST_FAIL_COMMIT_MARKER" 2>/dev/null
        return 1
    fi
    if [ "$SBM_TEST_MODE" = "1" ] \
        && [ -n "${SBM_TEST_FAIL_COMMIT_ALWAYS_PHASE:-}" ] \
        && [ "$SBM_PHASE" = "$SBM_TEST_FAIL_COMMIT_ALWAYS_PHASE" ]; then
        return 1
    fi
    _sbm_payload=$(sbm_state_payload)
    sbm_atomic_write "$SBM_STATE_FILE" "$_sbm_payload" || return 1
    [ "$(sbm_state_value "$SBM_STATE_FILE" transition_id 2>/dev/null)" = "$SBM_TRANSITION_ID" ] \
        && [ "$(sbm_state_value "$SBM_STATE_FILE" phase 2>/dev/null)" = "$SBM_PHASE" ]
}

sbm_commit_terminal_fallback() {
    case "$SBM_PHASE:$SBM_FINAL" in success:yes|failed:yes|blocked:yes) ;; *) return 64 ;; esac
    _sbm_terminal_payload=$(sbm_state_payload)
    _sbm_terminal_payload=$(printf '%s\n%s' "$_sbm_terminal_payload" 'fallback=yes')
    sbm_atomic_write "$SBM_TERMINAL_FILE" "$_sbm_terminal_payload" || return 1
    [ "$(sbm_state_value "$SBM_TERMINAL_FILE" transition_id 2>/dev/null)" = "$SBM_TRANSITION_ID" ] \
        && [ "$(sbm_state_value "$SBM_TERMINAL_FILE" phase 2>/dev/null)" = "$SBM_PHASE" ]
}

sbm_commit_terminal_bounded() {
    _sbm_terminal_attempt=1
    while [ "$_sbm_terminal_attempt" -le "$SBM_STATE_COMMIT_ATTEMPTS" ] 2>/dev/null; do
        if sbm_commit_state; then
            rm -f "$SBM_TERMINAL_FILE" 2>/dev/null
            return 0
        fi
        _sbm_terminal_attempt=$((_sbm_terminal_attempt + 1))
        [ "$_sbm_terminal_attempt" -gt "$SBM_STATE_COMMIT_ATTEMPTS" ] 2>/dev/null \
            || sleep "$SBM_STATE_COMMIT_RETRY_SLEEP_S"
    done
    sbm_commit_terminal_fallback
}

sbm_commit_health() {
    _sbm_now=$(sbm_now)
    _sbm_health_payload=$(printf '%s\n' \
        "schema=$SBM_SCHEMA" \
        "boot_id=$(sbm_safe_field "$SBM_HEALTH_BOOT_ID")" \
        "mode=$(sbm_safe_field "$SBM_HEALTH_MODE")" \
        "status=$(sbm_safe_field "$SBM_HEALTH_STATUS")" \
        "reason=$(sbm_safe_field "$SBM_HEALTH_REASON")" \
        "profile=$(sbm_safe_field "$SBM_HEALTH_PROFILE")" \
        "profile_verified=$(sbm_safe_field "$SBM_HEALTH_PROFILE_VERIFIED")" \
        "cpufreq_permissions=$(sbm_safe_field "$SBM_HEALTH_CPUFREQ_PERMISSIONS")" \
        "powerhal_failures=$(sbm_safe_field "$SBM_HEALTH_POWERHAL_FAILURES")" \
        "ugt_root_instances=$(sbm_safe_field "$SBM_HEALTH_UGT_ROOTS")" \
        "fas_process_alive=$(sbm_safe_field "$SBM_HEALTH_FAS_ALIVE")" \
        "checked_epoch=$_sbm_now")
    sbm_atomic_write "$SBM_HEALTH_FILE" "$_sbm_health_payload"
}

sbm_apd_module_state() {
    if [ "$SBM_TEST_MODE" = "1" ]; then
        _sbm_apd_json=$(sh "$SBM_APD_BIN" module list 2>/dev/null) || return 2
    elif [ -x "$SBM_APD_BIN" ]; then
        _sbm_apd_json=$("$SBM_APD_BIN" module list 2>/dev/null) || return 2
    else
        _sbm_module_path="$SBM_MODULES_ROOT/$SBM_UPERF_ID"
        [ -d "$_sbm_module_path" ] || _sbm_module_path="$SBM_MODULES_UPDATE_ROOT/$SBM_UPERF_ID"
        [ -d "$_sbm_module_path" ] || { printf 'absent'; return 0; }
        if [ -f "$_sbm_module_path/remove" ]; then
            printf 'absent'
        elif [ -f "$_sbm_module_path/disable" ]; then
            printf 'disabled'
        else
            printf 'enabled'
        fi
        return 0
    fi
    _sbm_apd_state=$(printf '%s' "$_sbm_apd_json" | tr -d '\000\r\n' | awk -v id="$SBM_UPERF_ID" '
        BEGIN { RS = "}," }
        index($0, "\"id\": \"" id "\"") {
            found = 1
            if (index($0, "\"remove\": \"true\"")) print "absent"
            else if (index($0, "\"enabled\": \"true\"")) print "enabled"
            else if (index($0, "\"enabled\": \"false\"")) print "disabled"
            else exit 4
            exit
        }
        END { if (!found) exit 3 }
    ' 2>/dev/null)
    _sbm_apd_rc=$?
    [ "$_sbm_apd_rc" -eq 0 ] || return "$_sbm_apd_rc"
    case "$_sbm_apd_state" in enabled|disabled|absent) printf '%s' "$_sbm_apd_state" ;; *) return 4 ;; esac
}

sbm_can_stage_module_state() {
    [ "$SBM_TEST_MODE" = "1" ] || [ -x "$SBM_APD_BIN" ]
}

sbm_apd_set_state() {
    _sbm_target_state="$1"
    case "$_sbm_target_state" in enabled) _sbm_apd_action=enable ;; disabled) _sbm_apd_action=disable ;; *) return 1 ;; esac
    if [ "$SBM_TEST_MODE" = "1" ]; then
        sh "$SBM_APD_BIN" module "$_sbm_apd_action" "$SBM_UPERF_ID" >/dev/null 2>&1
    else
        [ -x "$SBM_APD_BIN" ] || return 2
        "$SBM_APD_BIN" module "$_sbm_apd_action" "$SBM_UPERF_ID" >/dev/null 2>&1
    fi
}

sbm_apply_module_state_bounded() {
    _sbm_target_state="$1"
    _sbm_deadline=$(( $(sbm_now) + SBM_WRITE_DEADLINE_S ))
    SBM_ATTEMPTS=0
    while [ "$SBM_ATTEMPTS" -lt "$SBM_MAX_WRITE_ATTEMPTS" ] 2>/dev/null; do
        _sbm_now=$(sbm_now)
        [ "$_sbm_now" -le "$_sbm_deadline" ] 2>/dev/null || break
        _sbm_actual=$(sbm_apd_module_state 2>/dev/null)
        if [ "$_sbm_actual" = "$_sbm_target_state" ] \
            || { [ "$_sbm_target_state" = "disabled" ] && [ "$_sbm_actual" = "absent" ]; }; then
            return 0
        fi
        SBM_ATTEMPTS=$((SBM_ATTEMPTS + 1))
        sbm_apd_set_state "$_sbm_target_state" >/dev/null 2>&1 || true
        _sbm_actual=$(sbm_apd_module_state 2>/dev/null)
        if [ "$_sbm_actual" = "$_sbm_target_state" ] \
            || { [ "$_sbm_target_state" = "disabled" ] && [ "$_sbm_actual" = "absent" ]; }; then
            return 0
        fi
        [ "$SBM_ATTEMPTS" -ge "$SBM_MAX_WRITE_ATTEMPTS" ] 2>/dev/null || sleep "$SBM_RETRY_SLEEP_S"
    done
    return 1
}

sbm_fail_stage_with_rollback() {
    _sbm_failure_result="$1"
    _sbm_failure_reason="$2"
    _sbm_reboot_after_rollback="${3:-no}"
    _sbm_primary_attempts="$SBM_ATTEMPTS"
    _sbm_rollback_ok=no
    case "$SBM_PREVIOUS_MODULE_STATE" in
        enabled|disabled)
            sbm_apply_module_state_bounded "$SBM_PREVIOUS_MODULE_STATE" \
                && _sbm_rollback_ok=yes
            ;;
    esac
    SBM_ATTEMPTS="$_sbm_primary_attempts"
    SBM_PHASE=failed
    SBM_FINAL=yes
    SBM_OK=no
    if [ "$_sbm_rollback_ok" = "yes" ]; then
        SBM_RESULT="${_sbm_failure_result}_rolled_back"
        SBM_REASON="${_sbm_failure_reason}:rollback_complete"
        SBM_REBOOT_REQUIRED="$_sbm_reboot_after_rollback"
    else
        SBM_RESULT="${_sbm_failure_result}_rollback_incomplete"
        SBM_REASON="${_sbm_failure_reason}:rollback_incomplete"
        SBM_REBOOT_REQUIRED=yes
    fi
    SBM_OBSERVED_BOOT_ID=$(sbm_boot_id)
    sbm_commit_terminal_bounded >/dev/null 2>&1 || true
    [ "$_sbm_rollback_ok" = "yes" ]
}

sbm_stage_mode() {
    _sbm_target_mode="$1"
    _sbm_target_owner=$(sbm_mode_to_owner "$_sbm_target_mode") || return 64
    sbm_load_state
    _sbm_current_boot=$(sbm_boot_id)
    if [ "$SBM_PHASE" = "pending_reboot" ] \
        && [ "$SBM_STAGED_BOOT_ID" = "$_sbm_current_boot" ]; then
        [ "$SBM_TARGET_MODE" = "$_sbm_target_mode" ] && return 0
        return 81
    fi
    if [ "$SBM_PHASE" = "success" ] \
        && [ "$SBM_EFFECTIVE_MODE" = "$_sbm_target_mode" ] \
        && [ "$SBM_OBSERVED_BOOT_ID" = "$_sbm_current_boot" ]; then
        return 79
    fi
    _sbm_target_module=disabled
    [ "$_sbm_target_mode" = "ugt" ] && _sbm_target_module=enabled
    sbm_can_stage_module_state || return 69
    _sbm_old_desired=$(so_read_desired_owner)
    _sbm_old_module=$(sbm_apd_module_state 2>/dev/null) || _sbm_old_module=unknown
    if [ "$_sbm_target_mode" = "ugt" ] && [ "$_sbm_old_module" = "absent" ]; then
        return 66
    fi

    _sbm_now=$(sbm_now)
    SBM_TRANSITION_ID="$(sbm_boot_id):${_sbm_now}:${_sbm_target_mode}"
    SBM_TARGET_MODE="$_sbm_target_mode"
    SBM_EFFECTIVE_MODE=$(sbm_owner_to_mode "$(so_read_effective_owner)")
    SBM_PHASE=staging
    SBM_FINAL=no
    SBM_OK=pending
    SBM_RESULT=staging_apatch_module
    SBM_REASON=user_request
    SBM_ATTEMPTS=0
    SBM_DEADLINE_EPOCH=$((_sbm_now + SBM_WRITE_DEADLINE_S))
    SBM_STAGED_BOOT_ID=$(sbm_boot_id)
    SBM_OBSERVED_BOOT_ID="$SBM_STAGED_BOOT_ID"
    SBM_PREVIOUS_DESIRED="$_sbm_old_desired"
    SBM_PREVIOUS_MODULE_STATE="$_sbm_old_module"
    SBM_AUTO_REPAIR_USED=no
    SBM_REBOOT_REQUIRED=yes
    sbm_commit_state || return 74

    if ! sbm_apply_module_state_bounded "$_sbm_target_module"; then
        sbm_fail_stage_with_rollback failed_stage_module_state apatch_state_mismatch no >/dev/null 2>&1 || true
        return 1
    fi

    # Root-manager enable/disable is expected to be next-boot only. If UGT
    # nevertheless starts in this boot, immediately stage disable again and
    # require a clean reboot; stopping the process cannot undo its sysfs writes.
    if [ "$_sbm_target_mode" = "ugt" ] && [ "$(sbm_uperf_root_instances)" != "0" ]; then
        sbm_fail_stage_with_rollback failed_ugt_hot_activation runtime_started_before_reboot yes >/dev/null 2>&1 || true
        return 1
    fi

    SBM_PHASE=pending_reboot
    SBM_FINAL=no
    SBM_OK=pending
    SBM_RESULT="pending_reboot_to_${_sbm_target_mode}"
    SBM_REASON=module_state_staged
    SBM_REBOOT_REQUIRED=yes
    if sbm_commit_state; then
        return 0
    fi
    sbm_fail_stage_with_rollback failed_stage_state_commit state_commit_failed no >/dev/null 2>&1 || true
    return 74
}

sbm_cancel_pending() {
    sbm_load_state
    [ "$SBM_PHASE" = "pending_reboot" ] || return 65
    [ "$SBM_STAGED_BOOT_ID" = "$(sbm_boot_id)" ] || return 66
    case "$SBM_PREVIOUS_MODULE_STATE" in enabled|disabled) ;; *) return 67 ;; esac
    case "$SBM_PREVIOUS_DESIRED" in pixel|external) ;; *) SBM_PREVIOUS_DESIRED=$(so_read_desired_owner) ;; esac

    if sbm_apply_module_state_bounded "$SBM_PREVIOUS_MODULE_STATE"; then
        SBM_TARGET_MODE=$(sbm_owner_to_mode "$SBM_PREVIOUS_DESIRED")
        SBM_EFFECTIVE_MODE=$(sbm_owner_to_mode "$(so_read_effective_owner)")
        SBM_PHASE=success
        SBM_FINAL=yes
        SBM_OK=yes
        SBM_RESULT="cancelled_pending_reboot_active_${SBM_EFFECTIVE_MODE}"
        SBM_REASON=user_cancelled
        SBM_REBOOT_REQUIRED=no
        SBM_OBSERVED_BOOT_ID=$(sbm_boot_id)
        sbm_commit_terminal_bounded
        return $?
    fi

    SBM_PHASE=failed
    SBM_FINAL=yes
    SBM_OK=no
    SBM_RESULT=failed_cancel_rollback_incomplete
    SBM_REASON=rollback_incomplete
    SBM_REBOOT_REQUIRED=yes
    sbm_commit_terminal_bounded >/dev/null 2>&1 || true
    return 1
}

sbm_uperf_root_instances() {
    if [ "$SBM_TEST_MODE" = "1" ]; then
        _sbm_count=$(cat "${SBM_TEST_UPERF_COUNT_FILE:-}" 2>/dev/null | tr -d ' \r\n\t')
        case "$_sbm_count" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$_sbm_count" ;; esac
        return
    fi
    _sbm_roots=0
    for _sbm_pid in $(pidof uperf 2>/dev/null); do
        case "$_sbm_pid" in ''|*[!0-9]*) continue ;; esac
        _sbm_ppid=$(awk '/^PPid:/{print $2; exit}' "/proc/$_sbm_pid/status" 2>/dev/null)
        [ "$_sbm_ppid" = "1" ] && _sbm_roots=$((_sbm_roots + 1))
    done
    printf '%s' "$_sbm_roots"
}

sbm_fas_process_alive() {
    if [ "$SBM_TEST_MODE" = "1" ]; then
        [ -f "${SBM_TEST_FAS_ALIVE_FILE:-/nonexistent}" ]
    else
        pidof fas-rs >/dev/null 2>&1
    fi
}

sbm_cpufreq_permissions_ok() {
    if [ "$SBM_TEST_MODE" = "1" ] && [ -n "${SBM_TEST_CPUFREQ_PERMISSION_FILE:-}" ]; then
        [ "$(cat "$SBM_TEST_CPUFREQ_PERMISSION_FILE" 2>/dev/null | tr -d ' \r\n\t')" = "ok" ]
        return
    fi
    SBM_PERMISSION_MISMATCH=""
    for _sbm_policy in policy0 policy4 policy7; do
        for _sbm_node in scaling_min_freq scaling_max_freq; do
            _sbm_path="$SBM_CPUFREQ_ROOT/$_sbm_policy/$_sbm_node"
            [ -e "$_sbm_path" ] || { SBM_PERMISSION_MISMATCH="missing:${_sbm_policy}/${_sbm_node}"; return 1; }
            _sbm_stat=$(stat -c '%a:%u:%g' "$_sbm_path" 2>/dev/null | tr -d ' \r\n\t')
            _sbm_expected="$SBM_EXPECTED_CPUFREQ_MODE:$SBM_EXPECTED_CPUFREQ_UID:$SBM_EXPECTED_CPUFREQ_GID"
            [ "$_sbm_stat" = "$_sbm_expected" ] \
                || { SBM_PERMISSION_MISMATCH="${_sbm_policy}/${_sbm_node}:${_sbm_stat:-unreadable}"; return 1; }
        done
    done
    return 0
}

sbm_powerhal_failure_count() {
    if [ "$SBM_TEST_MODE" = "1" ]; then
        _sbm_failures=$(cat "${SBM_TEST_POWERHAL_FAILURE_FILE:-}" 2>/dev/null | tr -d ' \r\n\t')
        case "$_sbm_failures" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$_sbm_failures" ;; esac
        return
    fi
    [ -x "$SBM_LOGCAT_BIN" ] || { printf 'unknown'; return; }
    "$SBM_LOGCAT_BIN" -b all -d -t "$SBM_LOGCAT_MAX_LINES" -v brief 2>/dev/null | awk '
        /Failed to write to node/ && /hal_power_default|power-service|libperfmgr/ { failures++ }
        /hal_power_default/ && /dac_override/ { failures++ }
        END { print failures + 0 }
    '
}

sbm_probe_control_plane() {
    _sbm_mode="$1"
    SBM_PROBE_REASON=healthy
    SBM_PROBE_MODULE_STATE=$(sbm_apd_module_state 2>/dev/null) || SBM_PROBE_MODULE_STATE=unknown
    SBM_PROBE_UGT_ROOTS=$(sbm_uperf_root_instances)
    if sbm_fas_process_alive; then SBM_PROBE_FAS_ALIVE=yes; else SBM_PROBE_FAS_ALIVE=no; fi
    SBM_PROBE_POWERHAL_FAILURES=$(sbm_powerhal_failure_count)
    SBM_PROBE_CPUFREQ_PERMISSIONS=unknown

    case "$_sbm_mode" in
        pixel)
            case "$SBM_PROBE_MODULE_STATE" in disabled|absent) ;; *) SBM_PROBE_REASON=ugt_module_enabled; return 1 ;; esac
            [ "$SBM_PROBE_UGT_ROOTS" = "0" ] || { SBM_PROBE_REASON=ugt_process_residue; return 1; }
            if sbm_cpufreq_permissions_ok; then
                SBM_PROBE_CPUFREQ_PERMISSIONS=ok
            else
                SBM_PROBE_CPUFREQ_PERMISSIONS="mismatch:${SBM_PERMISSION_MISMATCH:-unknown}"
                SBM_PROBE_REASON=cpufreq_permission_mismatch
                return 1
            fi
            case "$SBM_PROBE_POWERHAL_FAILURES" in
                0) ;;
                unknown) SBM_PROBE_REASON=powerhal_log_unavailable; return 1 ;;
                *) SBM_PROBE_REASON=powerhal_write_failure; return 1 ;;
            esac
            ;;
        ugt)
            [ "$SBM_PROBE_MODULE_STATE" = "enabled" ] || { SBM_PROBE_REASON=ugt_module_disabled; return 1; }
            [ "$SBM_PROBE_UGT_ROOTS" = "1" ] || { SBM_PROBE_REASON=ugt_instance_count_mismatch; return 1; }
            [ "$SBM_PROBE_FAS_ALIVE" = "no" ] || { SBM_PROBE_REASON=fas_conflict_in_ugt_mode; return 1; }
            ;;
        *) SBM_PROBE_REASON=invalid_mode; return 1 ;;
    esac
    return 0
}
