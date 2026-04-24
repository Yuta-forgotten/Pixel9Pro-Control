#!/system/bin/sh

MODDIR="${PIXEL9PRO_MODDIR:-${MODDIR:-${0%/*}}}"
UECAP_MODE_FILE="${PIXEL9PRO_UECAP_MODE_FILE:-$MODDIR/.uecap_mode}"
UECAP_MANUAL_MODE_FILE="${PIXEL9PRO_UECAP_MANUAL_MODE_FILE:-$MODDIR/.uecap_manual_mode}"
UECAP_POLICY_FILE="${PIXEL9PRO_UECAP_POLICY_FILE:-$MODDIR/.uecap_policy}"
UECAP_REASON_FILE="${PIXEL9PRO_UECAP_REASON_FILE:-$MODDIR/.uecap_reason}"
UECAP_SWITCH_FILE="${PIXEL9PRO_UECAP_SWITCH_FILE:-$MODDIR/.uecap_last_switch}"
UECAP_LOGFILE="${PIXEL9PRO_UECAP_LOGFILE:-/data/local/tmp/pixel9pro_uecap.log}"
UECAP_TARGET="/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.binarypb"
UECAP_SPECIAL="$MODDIR/system/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.special.binarypb"
UECAP_BALANCED="$MODDIR/system/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.balanced.binarypb"
UECAP_UNIVERSAL="$MODDIR/system/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.universal.binarypb"

uecap_log_line() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$1" >> "$UECAP_LOGFILE"
}

uecap_hash() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

uecap_mode_label() {
    case "$1" in
        special|balanced|universal) echo "$1" ;;
        *) echo "unknown" ;;
    esac
}

uecap_current_mode() {
    _mode=$(cat "$UECAP_MODE_FILE" 2>/dev/null | tr -d ' \n\r')
    case "$_mode" in
        special|balanced|universal) echo "$_mode" ;;
        *) echo "balanced" ;;
    esac
}

uecap_current_manual_mode() {
    _mode=$(cat "$UECAP_MANUAL_MODE_FILE" 2>/dev/null | tr -d ' \n\r')
    case "$_mode" in
        special|balanced|universal) echo "$_mode" ;;
        *) echo "balanced" ;;
    esac
}

uecap_current_policy() {
    _policy=$(cat "$UECAP_POLICY_FILE" 2>/dev/null | tr -d ' \n\r')
    case "$_policy" in
        auto|manual) echo "$_policy" ;;
        *) echo "manual" ;;
    esac
}

uecap_current_reason() {
    cat "$UECAP_REASON_FILE" 2>/dev/null | tr -d '\n\r'
}

uecap_last_switch() {
    cat "$UECAP_SWITCH_FILE" 2>/dev/null | tr -d ' \n\r'
}

uecap_set_mode() {
    printf '%s' "$(uecap_mode_label "$1")" > "$UECAP_MODE_FILE"
}

uecap_set_manual_mode() {
    printf '%s' "$(uecap_mode_label "$1")" > "$UECAP_MANUAL_MODE_FILE"
}

uecap_set_policy() {
    case "$1" in
        auto|manual) printf '%s' "$1" > "$UECAP_POLICY_FILE" ;;
    esac
}

uecap_set_reason() {
    printf '%s' "$1" > "$UECAP_REASON_FILE"
}

uecap_set_switch_time() {
    printf '%s' "$1" > "$UECAP_SWITCH_FILE"
}

uecap_resolve_source() {
    case "$1" in
        universal) echo "$UECAP_UNIVERSAL" ;;
        special) echo "$UECAP_SPECIAL" ;;
        *) echo "$UECAP_BALANCED" ;;
    esac
}

uecap_reload_modem() {
    _reason="${1:-manual}"
    case "$_reason" in
        boot|boot_manual)
            uecap_log_line "skip modem reload (reason=$_reason, boot reads fresh)"
            return 0 ;;
    esac
    # restart-modem only cycles cellular radio, does NOT touch WiFi/BT
    # Much safer than airplane toggle which crashed the network stack (B29)
    nohup sh -c '
        cmd phone restart-modem 2>/dev/null
    ' >/dev/null 2>&1 &
    uecap_log_line "modem restart dispatched (reason=$_reason)"
}

uecap_detect_active_mode() {
    _target_hash=$(uecap_hash "$UECAP_TARGET")
    [ -z "$_target_hash" ] && { echo "custom"; return; }

    # Prefer the recorded mode if its hash matches — avoids ambiguity
    # when multiple tiers share the same binarypb
    _req=$(uecap_current_mode)
    _req_src=$(uecap_resolve_source "$_req")
    _req_hash=$(uecap_hash "$_req_src")
    if [ "$_target_hash" = "$_req_hash" ]; then
        echo "$_req"
        return
    fi

    _special_hash=$(uecap_hash "$UECAP_SPECIAL")
    _balanced_hash=$(uecap_hash "$UECAP_BALANCED")
    _universal_hash=$(uecap_hash "$UECAP_UNIVERSAL")

    if [ "$_target_hash" = "$_special_hash" ]; then echo "special"
    elif [ "$_target_hash" = "$_balanced_hash" ]; then echo "balanced"
    elif [ "$_target_hash" = "$_universal_hash" ]; then echo "universal"
    else echo "custom"
    fi
}

uecap_apply_mode() {
    _mode=$(uecap_mode_label "$1")
    [ "$_mode" != "unknown" ] || return 1

    _source=$(uecap_resolve_source "$_mode")
    [ -f "$_source" ] || {
        uecap_log_line "source missing: $_source"
        return 1
    }
    [ -e "$UECAP_TARGET" ] || {
        uecap_log_line "target missing: $UECAP_TARGET"
        return 1
    }

    _target_ctx=$(ls -Zd "$UECAP_TARGET" 2>/dev/null | awk '{print $1}')
    [ -n "$_target_ctx" ] && chcon "$_target_ctx" "$_source" 2>/dev/null

    if mount | grep -F " on $UECAP_TARGET " >/dev/null 2>&1; then
        umount "$UECAP_TARGET" 2>/dev/null
    fi

    mount --bind "$_source" "$UECAP_TARGET" >/dev/null 2>&1 || {
        uecap_log_line "bind failed mode=$_mode"
        return 1
    }

    uecap_set_mode "$_mode"
    uecap_set_switch_time "$(date +%s 2>/dev/null || echo 0)"
    uecap_log_line "bind ok mode=$_mode hash=$(uecap_hash "$_source")"
    uecap_reload_modem "${2:-manual}"
    return 0
}

uecap_print_status_json() {
    _requested=$(uecap_current_mode)
    _policy=$(uecap_current_policy)
    _manual=$(uecap_current_manual_mode)
    _reason=$(uecap_current_reason)
    _active=$(uecap_detect_active_mode)
    _target_hash=$(uecap_hash "$UECAP_TARGET")
    _special_hash=$(uecap_hash "$UECAP_SPECIAL")
    _balanced_hash=$(uecap_hash "$UECAP_BALANCED")
    _universal_hash=$(uecap_hash "$UECAP_UNIVERSAL")
    _last_switch=$(uecap_last_switch)

    printf '{"policy":"%s","requested_mode":"%s","manual_mode":"%s","active_mode":"%s","reason":"%s","last_switch":"%s","target_hash":"%s","special_hash":"%s","balanced_hash":"%s","universal_hash":"%s"}' \
        "$_policy" "$_requested" "$_manual" "$_active" "${_reason:-unknown}" "${_last_switch:-0}" \
        "${_target_hash:-unknown}" "${_special_hash:-unknown}" "${_balanced_hash:-unknown}" "${_universal_hash:-unknown}"
}

case "$1" in
    apply)
        _mode=$(uecap_mode_label "${2:-$(uecap_current_mode)}")
        [ "$_mode" = "unknown" ] && exit 1
        uecap_set_manual_mode "$_mode"
        uecap_apply_mode "$_mode"
        ;;
    status)
        uecap_print_status_json
        ;;
esac
