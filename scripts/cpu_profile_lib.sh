#!/system/bin/sh

# Pixel CPU profile contract shared by profile application, boot restore, and
# owner verification. Tuned values live here; the stock response remains a
# runtime read from response_time_ms_nom in cpu_profile.sh.

CPU_PROFILE_FULL_CAP=1024
CPU_PROFILE_ECO_CAP=0
CPU_PROFILE_FOREGROUND_CPUS="0-6"
CPU_PROFILE_BACKGROUND_CPUS="0-3"

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
        balanced) printf '16 40 200' ;;
        battery) printf '32 96 200' ;;
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
        battery) printf '0-6' ;;
        performance|balanced|default) printf '0-7' ;;
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
    printf '{"full_cap":%s,"eco_cap":%s,"foreground_cpus":"%s","background_cpus":"%s","profiles":{' \
        "$CPU_PROFILE_FULL_CAP" "$CPU_PROFILE_ECO_CAP" \
        "$CPU_PROFILE_FOREGROUND_CPUS" "$CPU_PROFILE_BACKGROUND_CPUS"
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
