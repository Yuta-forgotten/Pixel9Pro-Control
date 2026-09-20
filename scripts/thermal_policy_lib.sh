#!/system/bin/sh

# Thermal policy boundary shared by installer and CGI. Stock snapshots live in
# module-private payloads/ and never appear as vendor overlay entries.

THERMAL_POLICY_DEFAULT=system

thermal_policy_init() {
    THERMAL_POLICY_ROOT="$1"
    [ -n "$THERMAL_POLICY_ROOT" ] || return 1
    THERMAL_POLICY_FILE="$THERMAL_POLICY_ROOT/.thermal_policy"
    THERMAL_OFFSET_FILE="$THERMAL_POLICY_ROOT/.thermal_offset"
    THERMAL_OVERLAY_FILE="$THERMAL_POLICY_ROOT/system/vendor/etc/thermal_info_config.json"
}

thermal_policy_is_valid() {
    case "$1" in system|custom) return 0 ;; *) return 1 ;; esac
}

thermal_policy_read() {
    _tpl_value=$(cat "$THERMAL_POLICY_FILE" 2>/dev/null | tr -d ' \r\n\t')
    thermal_policy_is_valid "$_tpl_value" && printf '%s' "$_tpl_value" || printf '%s' "$THERMAL_POLICY_DEFAULT"
}

thermal_policy_snapshot_path() {
    case "$1" in caiman|komodo) ;; *) return 1 ;; esac
    printf '%s/payloads/thermal/%s/stock.json' "$THERMAL_POLICY_ROOT" "$1"
}

thermal_policy_validate_stock() {
    _tpl_source="$1"
    [ -r "$_tpl_source" ] || return 1
    _tpl_validation="${TMPDIR:-/dev/tmp}/pixel9pro_thermal_validate.$$"
    thermal_generate_config "$_tpl_source" "$_tpl_validation" 0 >/dev/null 2>&1
    _tpl_rc=$?
    rm -f "$_tpl_validation" 2>/dev/null
    return "$_tpl_rc"
}

thermal_policy_capture_stock() {
    _tpl_source="$1"
    _tpl_target="$2"
    thermal_policy_validate_stock "$_tpl_source" || return 1
    mkdir -p "${_tpl_target%/*}" 2>/dev/null || return 1
    _tpl_tmp="${_tpl_target}.tmp.$$"
    cp "$_tpl_source" "$_tpl_tmp" 2>/dev/null \
        && thermal_policy_validate_stock "$_tpl_tmp" \
        && mv "$_tpl_tmp" "$_tpl_target" 2>/dev/null \
        && chmod 600 "$_tpl_target" 2>/dev/null \
        && [ -f "$_tpl_target" ] && return 0
    rm -f "$_tpl_tmp" 2>/dev/null
    return 1
}

thermal_policy_prepare_snapshot() {
    _tpl_device="$1"
    _tpl_old_root="$2"
    _tpl_allow_vendor="$3"
    _tpl_target=$(thermal_policy_snapshot_path "$_tpl_device") || return 1
    if thermal_policy_validate_stock "$_tpl_target"; then
        return 0
    fi

    _tpl_legacy_name=thermal_stock.json
    [ "$_tpl_device" = komodo ] && _tpl_legacy_name=thermal_stock_xl.json
    for _tpl_candidate in \
        "$_tpl_old_root/payloads/thermal/$_tpl_device/stock.json" \
        "$_tpl_old_root/system/vendor/etc/$_tpl_legacy_name"; do
        [ -n "$_tpl_old_root" ] && thermal_policy_capture_stock "$_tpl_candidate" "$_tpl_target" && return 0
    done
    if [ "$_tpl_allow_vendor" = yes ]; then
        thermal_policy_capture_stock /vendor/etc/thermal_info_config.json "$_tpl_target" && return 0
    fi
    return 1
}

thermal_policy_remove_overlay() {
    rm -f "$THERMAL_OVERLAY_FILE" 2>/dev/null || return 1
    rmdir "$THERMAL_POLICY_ROOT/system/vendor/etc" 2>/dev/null || true
    rmdir "$THERMAL_POLICY_ROOT/system/vendor" 2>/dev/null || true
    return 0
}
