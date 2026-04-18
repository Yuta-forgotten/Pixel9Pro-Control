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
        *) echo "special" ;;
    esac
}

uecap_current_manual_mode() {
    _mode=$(cat "$UECAP_MANUAL_MODE_FILE" 2>/dev/null | tr -d ' \n\r')
    case "$_mode" in
        special|balanced|universal) echo "$_mode" ;;
        *) echo "special" ;;
    esac
}

uecap_current_policy() {
    _policy=$(cat "$UECAP_POLICY_FILE" 2>/dev/null | tr -d ' \n\r')
    case "$_policy" in
        auto|manual) echo "$_policy" ;;
        *) echo "auto" ;;
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

uecap_detect_active_mode() {
    _target_hash=$(uecap_hash "$UECAP_TARGET")
    _special_hash=$(uecap_hash "$UECAP_SPECIAL")
    _balanced_hash=$(uecap_hash "$UECAP_BALANCED")
    _universal_hash=$(uecap_hash "$UECAP_UNIVERSAL")

    if [ -n "$_target_hash" ] && [ "$_target_hash" = "$_special_hash" ]; then
        echo "special"
    elif [ -n "$_target_hash" ] && [ "$_target_hash" = "$_balanced_hash" ]; then
        echo "balanced"
    elif [ -n "$_target_hash" ] && [ "$_target_hash" = "$_universal_hash" ]; then
        echo "universal"
    else
        echo "custom"
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

    if mount --bind "$_source" "$UECAP_TARGET" >/dev/null 2>&1; then
        uecap_set_mode "$_mode"
        uecap_set_switch_time "$(date +%s 2>/dev/null || echo 0)"
        uecap_log_line "bind ok mode=$_mode hash=$(uecap_hash "$_source")"
        return 0
    fi

    _rc=$?
    uecap_log_line "bind failed mode=$_mode rc=$_rc"
    return "$_rc"
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
        uecap_apply_mode "${2:-$(uecap_current_mode)}"
        ;;
    status)
        uecap_print_status_json
        ;;
esac
