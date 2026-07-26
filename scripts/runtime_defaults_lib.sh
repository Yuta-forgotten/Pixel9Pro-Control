#!/system/bin/sh

# Persistent setting defaults shared by installer, boot service, and CGI.

SIM2_AUTO_DEFAULT="on"
IDLE_ISOLATE_DEFAULT="off"
NR_SCREEN_SWITCH_DEFAULT="off"
NR_SAVED_MODE_DEFAULT="33"
NR_SCREEN_OFF_DELAY_S=300
NR_RESTORE_COOLDOWN_S=600
NR_LTE_RECHECK_S=300
NR_LTE_MODE=9
VM_MODE_DEFAULT="optimized"

runtime_write_value() {
    _runtime_path="$1"
    _runtime_value="$2"
    [ -n "$_runtime_path" ] && [ ! -d "$_runtime_path" ] || return 1
    _runtime_tmp="${_runtime_path}.tmp.$$"
    if printf '%s' "$_runtime_value" > "$_runtime_tmp" 2>/dev/null \
        && mv "$_runtime_tmp" "$_runtime_path" 2>/dev/null \
        && [ -f "$_runtime_path" ]; then
        _runtime_written=$(cat "$_runtime_path" 2>/dev/null)
        [ "$_runtime_written" = "$_runtime_value" ] && return 0
    fi
    rm -f "$_runtime_tmp" 2>/dev/null
    return 1
}

runtime_read_onoff() {
    _runtime_value=$(cat "$1" 2>/dev/null | tr -d ' \n\r\t')
    case "$_runtime_value" in
        on|off) printf '%s' "$_runtime_value" ;;
        *) printf '%s' "$2" ;;
    esac
}

# Device binaries use fixed Android paths. Local fixtures may replace them only
# under explicit test mode, which avoids Windows cmd.exe command resolution.
runtime_android_settings() {
    _runtime_bin="/system/bin/settings"
    if [ "${PIXEL9PRO_CGI_TEST_MODE:-0}" = "1" ]; then
        _runtime_bin="${PIXEL9PRO_ANDROID_SETTINGS:-settings}"
    fi
    "$_runtime_bin" "$@"
}

runtime_android_cmd() {
    _runtime_bin="/system/bin/cmd"
    if [ "${PIXEL9PRO_CGI_TEST_MODE:-0}" = "1" ]; then
        _runtime_bin="${PIXEL9PRO_ANDROID_CMD:-cmd}"
    fi
    "$_runtime_bin" "$@"
}

# set-sim-count has no reliable readback on this build. Commit the marker only
# after Telephony accepts the command; if marker persistence fails, restore the
# previous modem count and expose whether that rollback also failed.
runtime_set_sim_count_state() {
    _runtime_sim2_marker="$1"
    _runtime_sim2_target_count="$2"
    _runtime_sim2_target_state="$3"
    _runtime_sim2_rollback_count="$4"
    SIM2_TRANSACTION_RESULT="invalid"
    case "$_runtime_sim2_target_count:$_runtime_sim2_rollback_count" in
        1:2|2:1) ;;
        *) return 1 ;;
    esac
    case "$_runtime_sim2_target_state" in enabled|disabled) ;; *) return 1 ;; esac

    if ! runtime_android_cmd phone set-sim-count "$_runtime_sim2_target_count" 2>/dev/null; then
        SIM2_TRANSACTION_RESULT="command_failed"
        return 1
    fi
    if runtime_write_value "$_runtime_sim2_marker" "$_runtime_sim2_target_state"; then
        SIM2_TRANSACTION_RESULT="applied"
        return 0
    fi
    if runtime_android_cmd phone set-sim-count "$_runtime_sim2_rollback_count" 2>/dev/null; then
        SIM2_TRANSACTION_RESULT="state_failed_rolled_back"
        return 1
    fi
    SIM2_TRANSACTION_RESULT="state_failed_rollback_incomplete"
    return 2
}
