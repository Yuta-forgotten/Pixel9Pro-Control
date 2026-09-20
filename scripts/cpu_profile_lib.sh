#!/system/bin/sh

# Pixel CPU profile contract shared by profile application, boot restore, owner
# verification, service auto policy, and the WebUI. Tuned values live here; the
# stock response remains a runtime read from response_time_ms_nom in
# cpu_profile.sh.
#
# Important ownership boundary:
#   - foreground/cpus is written by Android framework/system_server. It is an
#     observation only; this module must never snapshot, write, rollback, or use
#     it as a profile-success condition.
#   - top-app, response_time_ms, sched_util_clamp_min, and vendor_sched L2 are
#     volatile best-effort controls. A profile transaction writes and reads them
#     back once; PowerHAL/Scene/framework may legitimately write them later.
#   - background/system-background are the module transaction controls.
#   - scaling_min/max_freq belongs to ThermalHAL/PowerHAL/Scene and is never a
#     daily-use control here.

CPU_PROFILE_FULL_CAP=1024
CPU_PROFILE_ECO_CAP=0
CPU_PROFILE_FOREGROUND_OBSERVED_CPUS="0-6"
# Compatibility name for older presentation callers. This is deliberately an
# observed value, not a writable profile target.
CPU_PROFILE_FOREGROUND_CPUS="$CPU_PROFILE_FOREGROUND_OBSERVED_CPUS"
CPU_PROFILE_BACKGROUND_CPUS="0-3"
CPU_PROFILE_SYSTEM_BACKGROUND_CPUS="0-3"

CPU_PROFILE_WRITEBACK_POLICY="apply_verify_once_then_observe"
CPU_PROFILE_HEALTH_INTERVAL_S=300

# Automatic daily thermal guard. Values are milli-degrees Celsius and seconds;
# the service consumes these names directly so there is one source of truth.
CPU_PROFILE_AUTO_DISCHARGE_HOT_TEMP_MC=38800
CPU_PROFILE_AUTO_DISCHARGE_HOT_HOLD_S=60
CPU_PROFILE_AUTO_DISCHARGE_COOL_TEMP_MC=37500
CPU_PROFILE_AUTO_DISCHARGE_COOL_HOLD_S=120
CPU_PROFILE_AUTO_CHARGING_THERMAL_STATUS_MIN=2
CPU_PROFILE_AUTO_CHARGING_HOT_TEMP_MC=39800
CPU_PROFILE_AUTO_CHARGING_HOT_HOLD_S=60
CPU_PROFILE_AUTO_CHARGING_COOL_TEMP_MC=37500
CPU_PROFILE_AUTO_CHARGING_COOL_HOLD_S=120

cpu_profile_is_valid() {
    case "$1" in
        performance|balanced|battery|default) return 0 ;;
        *) return 1 ;;
    esac
}

cpu_profile_normalize_runtime() {
    _cpu_profile_value="$1"
    _cpu_profile_fallback="${2:-balanced}"
    case "$_cpu_profile_value" in
        light) _cpu_profile_value="balanced" ;;
        responsive) _cpu_profile_value="performance" ;;
    esac
    cpu_profile_is_valid "$_cpu_profile_fallback" || _cpu_profile_fallback="balanced"
    if cpu_profile_is_valid "$_cpu_profile_value"; then
        printf '%s' "$_cpu_profile_value"
    else
        printf '%s' "$_cpu_profile_fallback"
    fi
}

cpu_profile_response_triplet() {
    case "$1" in
        performance) printf '12 20 80' ;;
        balanced) printf '16 64 240' ;;
        battery) printf '16 96 320' ;;
        default) return 0 ;;
        *) return 1 ;;
    esac
}

cpu_profile_uclamp_cap() {
    case "$1" in
        performance|default) printf '%s' "$CPU_PROFILE_FULL_CAP" ;;
        balanced|battery) printf '%s' "$CPU_PROFILE_ECO_CAP" ;;
        *) return 1 ;;
    esac
}

cpu_profile_top_app_cpus() {
    case "$1" in
        performance|default) printf '0-7' ;;
        balanced|battery) printf '0-6' ;;
        *) return 1 ;;
    esac
}

cpu_profile_foreground_observed_cpus() {
    printf '%s' "$CPU_PROFILE_FOREGROUND_OBSERVED_CPUS"
}

cpu_profile_background_cpus() {
    printf '%s' "$CPU_PROFILE_BACKGROUND_CPUS"
}

cpu_profile_system_background_cpus() {
    printf '%s' "$CPU_PROFILE_SYSTEM_BACKGROUND_CPUS"
}

cpu_profile_owner() {
    case "$1" in
        foreground_cpus) printf 'framework' ;;
        top_app_cpus|response_time_ms|sched_util_clamp_min|vendor_sched_l2) printf 'pixel_best_effort' ;;
        background_cpus|system_background_cpus) printf 'pixel_transaction' ;;
        scaling_min_max_freq) printf 'thermal_powerhal_scene' ;;
        *) return 1 ;;
    esac
}

cpu_profile_auto_value() {
    case "$1" in
        discharge_hot_temp_mc) printf '%s' "$CPU_PROFILE_AUTO_DISCHARGE_HOT_TEMP_MC" ;;
        discharge_hot_hold_s) printf '%s' "$CPU_PROFILE_AUTO_DISCHARGE_HOT_HOLD_S" ;;
        discharge_cool_temp_mc) printf '%s' "$CPU_PROFILE_AUTO_DISCHARGE_COOL_TEMP_MC" ;;
        discharge_cool_hold_s) printf '%s' "$CPU_PROFILE_AUTO_DISCHARGE_COOL_HOLD_S" ;;
        charging_thermal_status_min) printf '%s' "$CPU_PROFILE_AUTO_CHARGING_THERMAL_STATUS_MIN" ;;
        charging_hot_temp_mc) printf '%s' "$CPU_PROFILE_AUTO_CHARGING_HOT_TEMP_MC" ;;
        charging_hot_hold_s) printf '%s' "$CPU_PROFILE_AUTO_CHARGING_HOT_HOLD_S" ;;
        charging_cool_temp_mc) printf '%s' "$CPU_PROFILE_AUTO_CHARGING_COOL_TEMP_MC" ;;
        charging_cool_hold_s) printf '%s' "$CPU_PROFILE_AUTO_CHARGING_COOL_HOLD_S" ;;
        *) return 1 ;;
    esac
}

cpu_profile_l2_params() {
    case "$1" in
        battery) printf '150 80' ;;
        default) printf '1024 308' ;;
        performance|balanced) printf '200 100' ;;
        *) return 1 ;;
    esac
}

# Compatibility alias for older callers. New code must derive L2 from the
# effective CPU profile instead of reading the retired .power_profile file.
cpu_power_profile_l2_params() {
    cpu_profile_l2_params "$1"
}

cpu_profile_contract_json() {
    _cpu_contract_first=1
    printf '{"schema":2,"full_cap":%s,"eco_cap":%s,"foreground_cpus":"%s","background_cpus":"%s","system_background_cpus":"%s",' \
        "$CPU_PROFILE_FULL_CAP" "$CPU_PROFILE_ECO_CAP" \
        "$CPU_PROFILE_FOREGROUND_OBSERVED_CPUS" "$CPU_PROFILE_BACKGROUND_CPUS" "$CPU_PROFILE_SYSTEM_BACKGROUND_CPUS"
    printf '"ownership":{"foreground_cpus":"%s","top_app_cpus":"%s","background_cpus":"%s","system_background_cpus":"%s","response_time_ms":"%s","sched_util_clamp_min":"%s","vendor_sched_l2":"%s","scaling_min_max_freq":"%s"},' \
        "$(cpu_profile_owner foreground_cpus)" "$(cpu_profile_owner top_app_cpus)" \
        "$(cpu_profile_owner background_cpus)" "$(cpu_profile_owner system_background_cpus)" \
        "$(cpu_profile_owner response_time_ms)" "$(cpu_profile_owner sched_util_clamp_min)" \
        "$(cpu_profile_owner vendor_sched_l2)" "$(cpu_profile_owner scaling_min_max_freq)"
    printf '"writeback_policy":"%s","health_interval_s":%s,"auto":{"profiles":["balanced","battery"],"discharge":{"hot_temp_mc":%s,"hot_hold_s":%s,"cool_temp_mc":%s,"cool_hold_s":%s},"charging":{"thermal_status_min":%s,"hot_temp_mc":%s,"hot_hold_s":%s,"cool_temp_mc":%s,"cool_hold_s":%s}},"profiles":{' \
        "$CPU_PROFILE_WRITEBACK_POLICY" "$CPU_PROFILE_HEALTH_INTERVAL_S" \
        "$CPU_PROFILE_AUTO_DISCHARGE_HOT_TEMP_MC" "$CPU_PROFILE_AUTO_DISCHARGE_HOT_HOLD_S" \
        "$CPU_PROFILE_AUTO_DISCHARGE_COOL_TEMP_MC" "$CPU_PROFILE_AUTO_DISCHARGE_COOL_HOLD_S" \
        "$CPU_PROFILE_AUTO_CHARGING_THERMAL_STATUS_MIN" "$CPU_PROFILE_AUTO_CHARGING_HOT_TEMP_MC" \
        "$CPU_PROFILE_AUTO_CHARGING_HOT_HOLD_S" "$CPU_PROFILE_AUTO_CHARGING_COOL_TEMP_MC" \
        "$CPU_PROFILE_AUTO_CHARGING_COOL_HOLD_S"
    for _cpu_contract_profile in performance balanced battery default; do
        [ "$_cpu_contract_first" -eq 1 ] || printf ','
        _cpu_contract_first=0
        _cpu_contract_cap=$(cpu_profile_uclamp_cap "$_cpu_contract_profile") || return 1
        _cpu_contract_top=$(cpu_profile_top_app_cpus "$_cpu_contract_profile") || return 1
        _cpu_contract_response=$(cpu_profile_response_triplet "$_cpu_contract_profile") || return 1
        if [ -n "$_cpu_contract_response" ]; then
            set -- $_cpu_contract_response
            [ "$#" -eq 3 ] || return 1
            _cpu_contract_response_json="[$1,$2,$3]"
        else
            _cpu_contract_response_json="null"
        fi
        _cpu_contract_l2=$(cpu_profile_l2_params "$_cpu_contract_profile") || return 1
        set -- $_cpu_contract_l2
        [ "$#" -eq 2 ] || return 1
        printf '"%s":{"response_ms":%s,"uclamp_cap":%s,"top_app_cpus":"%s","bg_uclamp_max":%s,"bg_group_throttle":%s}' \
            "$_cpu_contract_profile" "$_cpu_contract_response_json" \
            "$_cpu_contract_cap" "$_cpu_contract_top" "$1" "$2"
    done
    printf '}}'
}
