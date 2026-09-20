#!/system/bin/sh

# Installer state and receipt contract. Persistent user intent is stored apart
# from transient boot/effective state so upgrades never inherit stale workers.

INSTALL_STATE_SCHEMA=1

install_state_init() {
    INSTALL_STATE_ROOT="$1"
    [ -n "$INSTALL_STATE_ROOT" ] || return 1
    INSTALL_STATE_SCHEMA_FILE="$INSTALL_STATE_ROOT/.state_schema"
    INSTALL_ROOT_FAMILY_FILE="$INSTALL_STATE_ROOT/.root_family"
    INSTALL_THERMAL_POLICY_FILE="$INSTALL_STATE_ROOT/.thermal_policy"
    INSTALL_SCHEDULER_MODE_FILE="$INSTALL_STATE_ROOT/.scheduler_mode"
    INSTALL_SCHEDULER_POLICY_FILE="$INSTALL_STATE_ROOT/.scheduler_policy"
    INSTALL_SCHEDULER_PROFILE_FILE="$INSTALL_STATE_ROOT/.scheduler_profile"
    INSTALL_SCHEDULER_CAPABILITY_FILE="$INSTALL_STATE_ROOT/.scheduler_capability"
    INSTALL_SCHEDULER_RECEIPT_FILE="$INSTALL_STATE_ROOT/.scheduler_capability_receipt"
    INSTALL_PAYLOAD_STATE_FILE="$INSTALL_STATE_ROOT/.payload_state"
    INSTALL_FEATURE_NR_FILE="$INSTALL_STATE_ROOT/.feature_nr"
    INSTALL_FEATURE_SIM2_FILE="$INSTALL_STATE_ROOT/.feature_sim2"
    INSTALL_FEATURE_VM_FILE="$INSTALL_STATE_ROOT/.feature_vm"
    INSTALL_FEATURE_POWER_EXPORT_FILE="$INSTALL_STATE_ROOT/.feature_power_export"
    INSTALL_RECEIPT_FILE="$INSTALL_STATE_ROOT/.install_receipt"
}

install_state_value_is_valid() {
    case "$1:$2" in
        state_schema:1) return 0 ;;
        root_family:apatch|root_family:kernelsu|root_family:magisk|root_family:unknown) return 0 ;;
        thermal_policy:system|thermal_policy:custom) return 0 ;;
        scheduler_mode:active|scheduler_mode:off|scheduler_mode:observe) return 0 ;;
        scheduler_policy:auto|scheduler_policy:manual) return 0 ;;
        scheduler_profile:balanced|scheduler_profile:battery|scheduler_profile:default|scheduler_profile:performance) return 0 ;;
        scheduler_capability:supported|scheduler_capability:partial|scheduler_capability:unsupported|scheduler_capability:unknown) return 0 ;;
        payload_state:verified|payload_state:stock|payload_state:candidate|payload_state:unverified) return 0 ;;
        feature_nr:on|feature_nr:off|feature_sim2:on|feature_sim2:off) return 0 ;;
        feature_vm:system|feature_vm:optimized|feature_vm:disabled) return 0 ;;
        feature_power_export:on|feature_power_export:off) return 0 ;;
        *) return 1 ;;
    esac
}

install_state_write() {
    _is_key="$1"
    _is_path="$2"
    _is_value="$3"
    install_state_value_is_valid "$_is_key" "$_is_value" || return 1
    if command -v runtime_write_value >/dev/null 2>&1; then
        runtime_write_value "$_is_path" "$_is_value"
        return $?
    fi
    _is_tmp="${_is_path}.tmp.$$"
    printf '%s' "$_is_value" > "$_is_tmp" 2>/dev/null \
        && mv "$_is_tmp" "$_is_path" 2>/dev/null \
        && [ "$(cat "$_is_path" 2>/dev/null)" = "$_is_value" ] && return 0
    rm -f "$_is_tmp" 2>/dev/null
    return 1
}

install_state_read() {
    _is_path="$1"
    _is_fallback="$2"
    _is_value=$(cat "$_is_path" 2>/dev/null | tr -d ' \r\n\t')
    [ -n "$_is_value" ] && printf '%s' "$_is_value" || printf '%s' "$_is_fallback"
}

install_state_safe_value() {
    printf '%s' "$1" | tr '\r\n=|' '    '
}

install_state_root_value() {
    case "$1" in
        APatch|apatch) printf 'apatch' ;;
        KernelSU|kernelsu) printf 'kernelsu' ;;
        Magisk|magisk) printf 'magisk' ;;
        *) printf 'unknown' ;;
    esac
}

install_state_sync_legacy() {
    _is_root=$(install_state_root_value "$1")
    install_state_write state_schema "$INSTALL_STATE_SCHEMA_FILE" "$INSTALL_STATE_SCHEMA" || return 1
    install_state_write root_family "$INSTALL_ROOT_FAMILY_FILE" "$_is_root" || return 1

    _is_thermal=$(install_state_read "$INSTALL_THERMAL_POLICY_FILE" custom)
    case "$_is_thermal" in system|custom) ;; disabled) _is_thermal=system ;; *) _is_thermal=custom ;; esac
    install_state_write thermal_policy "$INSTALL_THERMAL_POLICY_FILE" "$_is_thermal" || return 1

    _is_scheduler_mode=$(install_state_read "$INSTALL_SCHEDULER_MODE_FILE" active)
    install_state_value_is_valid scheduler_mode "$_is_scheduler_mode" || _is_scheduler_mode=active
    install_state_write scheduler_mode "$INSTALL_SCHEDULER_MODE_FILE" "$_is_scheduler_mode" || return 1
    _is_scheduler_policy=$(install_state_read "$INSTALL_STATE_ROOT/.profile_policy" manual)
    install_state_value_is_valid scheduler_policy "$_is_scheduler_policy" || _is_scheduler_policy=manual
    install_state_write scheduler_policy "$INSTALL_SCHEDULER_POLICY_FILE" "$_is_scheduler_policy" || return 1
    _is_scheduler_profile=$(install_state_read "$INSTALL_STATE_ROOT/.profile_manual" balanced)
    install_state_value_is_valid scheduler_profile "$_is_scheduler_profile" || _is_scheduler_profile=balanced
    install_state_write scheduler_profile "$INSTALL_SCHEDULER_PROFILE_FILE" "$_is_scheduler_profile" || return 1
    _is_scheduler_capability=$(install_state_read "$INSTALL_SCHEDULER_CAPABILITY_FILE" unknown)
    install_state_value_is_valid scheduler_capability "$_is_scheduler_capability" || _is_scheduler_capability=unknown
    install_state_write scheduler_capability "$INSTALL_SCHEDULER_CAPABILITY_FILE" "$_is_scheduler_capability" || return 1

    _is_uecap_policy=$(install_state_read "$INSTALL_STATE_ROOT/.uecap_policy" disabled)
    _is_uecap_mode=$(install_state_read "$INSTALL_STATE_ROOT/.uecap_manual_mode" disabled)
    case "$_is_uecap_policy:$_is_uecap_mode" in
        managed_profiles:*) _is_payload=verified ;;
        single_candidate:candidate) _is_payload=candidate ;;
        single_candidate:stock) _is_payload=stock ;;
        *) _is_payload=unverified ;;
    esac
    install_state_write payload_state "$INSTALL_PAYLOAD_STATE_FILE" "$_is_payload" || return 1

    _is_nr=$(install_state_read "$INSTALL_STATE_ROOT/.nr_screen_switch" off)
    install_state_value_is_valid feature_nr "$_is_nr" || _is_nr=off
    install_state_write feature_nr "$INSTALL_FEATURE_NR_FILE" "$_is_nr" || return 1
    _is_sim2=$(install_state_read "$INSTALL_STATE_ROOT/.sim2_auto_manage" on)
    install_state_value_is_valid feature_sim2 "$_is_sim2" || _is_sim2=on
    install_state_write feature_sim2 "$INSTALL_FEATURE_SIM2_FILE" "$_is_sim2" || return 1
    case "$(install_state_read "$INSTALL_STATE_ROOT/.swap_mode" optimized)" in
        stock) _is_vm=system ;;
        disabled) _is_vm=disabled ;;
        *) _is_vm=optimized ;;
    esac
    install_state_write feature_vm "$INSTALL_FEATURE_VM_FILE" "$_is_vm" || return 1
    install_state_write feature_power_export "$INSTALL_FEATURE_POWER_EXPORT_FILE" on || return 1
}

install_receipt_write() {
    _is_phase="$1"
    _is_result="$2"
    _is_reason="$3"
    _is_reboot="$4"
    case "$_is_phase:$_is_result:$_is_reboot" in
        *[!A-Za-z0-9_.:-]*) return 1 ;;
        *:yes|*:no) ;;
        *) return 1 ;;
    esac
    case "$_is_reason" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac
    _is_tmp="${INSTALL_RECEIPT_FILE}.tmp.$$"
    {
        printf 'schema=%s\n' "$INSTALL_STATE_SCHEMA"
        printf 'updated_at=%s\n' "$(date +%s 2>/dev/null || printf '0')"
        printf 'phase=%s\n' "$(install_state_safe_value "$_is_phase")"
        printf 'result=%s\n' "$(install_state_safe_value "$_is_result")"
        printf 'reason_code=%s\n' "$(install_state_safe_value "$_is_reason")"
        printf 'device=%s\n' "$(install_state_safe_value "$(install_state_read "$INSTALL_STATE_ROOT/.device_variant" unknown)")"
        printf 'root_family=%s\n' "$(install_state_safe_value "$(install_state_read "$INSTALL_ROOT_FAMILY_FILE" unknown)")"
        printf 'thermal_policy=%s\n' "$(install_state_safe_value "$(install_state_read "$INSTALL_THERMAL_POLICY_FILE" system)")"
        printf 'scheduler_mode=%s\n' "$(install_state_safe_value "$(install_state_read "$INSTALL_SCHEDULER_MODE_FILE" off)")"
        printf 'scheduler_policy=%s\n' "$(install_state_safe_value "$(install_state_read "$INSTALL_SCHEDULER_POLICY_FILE" manual)")"
        printf 'scheduler_profile=%s\n' "$(install_state_safe_value "$(install_state_read "$INSTALL_SCHEDULER_PROFILE_FILE" default)")"
        printf 'scheduler_capability=%s\n' "$(install_state_safe_value "$(install_state_read "$INSTALL_SCHEDULER_CAPABILITY_FILE" unknown)")"
        printf 'uecap_policy=%s\n' "$(install_state_safe_value "$(install_state_read "$INSTALL_STATE_ROOT/.uecap_policy" disabled)")"
        printf 'uecap_mode=%s\n' "$(install_state_safe_value "$(install_state_read "$INSTALL_STATE_ROOT/.uecap_manual_mode" disabled)")"
        printf 'payload_state=%s\n' "$(install_state_safe_value "$(install_state_read "$INSTALL_PAYLOAD_STATE_FILE" unverified)")"
        printf 'feature_nr=%s\n' "$(install_state_safe_value "$(install_state_read "$INSTALL_FEATURE_NR_FILE" off)")"
        printf 'feature_sim2=%s\n' "$(install_state_safe_value "$(install_state_read "$INSTALL_FEATURE_SIM2_FILE" on)")"
        printf 'feature_vm=%s\n' "$(install_state_safe_value "$(install_state_read "$INSTALL_FEATURE_VM_FILE" system)")"
        printf 'feature_power_export=%s\n' "$(install_state_safe_value "$(install_state_read "$INSTALL_FEATURE_POWER_EXPORT_FILE" on)")"
        printf 'reboot_required=%s\n' "$_is_reboot"
    } > "$_is_tmp" 2>/dev/null \
        && mv "$_is_tmp" "$INSTALL_RECEIPT_FILE" 2>/dev/null \
        && chmod 600 "$INSTALL_RECEIPT_FILE" 2>/dev/null \
        && [ -f "$INSTALL_RECEIPT_FILE" ] && return 0
    rm -f "$_is_tmp" 2>/dev/null
    return 1
}

install_state_print_summary() {
    ui_print "  最终配置摘要:"
    ui_print "    设备: $(install_state_read "$INSTALL_STATE_ROOT/.device_variant" unknown)"
    ui_print "    Root: $(install_state_read "$INSTALL_ROOT_FAMILY_FILE" unknown)"
    ui_print "    温控: $(install_state_read "$INSTALL_THERMAL_POLICY_FILE" system)"
    ui_print "    调度: $(install_state_read "$INSTALL_SCHEDULER_MODE_FILE" off) / $(install_state_read "$INSTALL_SCHEDULER_POLICY_FILE" manual) / $(install_state_read "$INSTALL_SCHEDULER_PROFILE_FILE" default)"
    ui_print "    UECap: $(install_state_read "$INSTALL_STATE_ROOT/.uecap_policy" disabled) / $(install_state_read "$INSTALL_STATE_ROOT/.uecap_manual_mode" disabled)"
    ui_print "    NR/SIM2/VM: $(install_state_read "$INSTALL_FEATURE_NR_FILE" off) / $(install_state_read "$INSTALL_FEATURE_SIM2_FILE" on) / $(install_state_read "$INSTALL_FEATURE_VM_FILE" system)"
    ui_print ""
}
