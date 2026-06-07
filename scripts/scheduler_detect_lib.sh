#!/system/bin/sh
# Shared scheduler ownership helpers.
# Detects Uperf Game Turbo without suggesting installation.

UPERF_DETECTED="no"
UPERF_MODULE_ID=""
UPERF_MODULE_NAME=""
UPERF_MODULE_PATH=""
UPERF_MODULE_SOURCE=""
UPERF_MODULE_STATE=""
UPERF_MODULE_ENABLED="no"

reset_uperf_detection() {
    UPERF_DETECTED="no"
    UPERF_MODULE_ID=""
    UPERF_MODULE_NAME=""
    UPERF_MODULE_PATH=""
    UPERF_MODULE_SOURCE=""
    UPERF_MODULE_STATE=""
    UPERF_MODULE_ENABLED="no"
}

read_module_prop_value() {
    _sd_key="$1"
    _sd_prop="$2"
    sed -n "s/^${_sd_key}=//p" "$_sd_prop" 2>/dev/null | head -n 1 | tr -d '\r'
}

is_uperf_module_prop() {
    _sd_prop="$1"
    _sd_id=$(read_module_prop_value id "$_sd_prop")
    _sd_name=$(read_module_prop_value name "$_sd_prop")
    _sd_desc=$(read_module_prop_value description "$_sd_prop")
    [ "$_sd_id" = "uperf" ] && return 0

    _sd_text=$(printf '%s\n%s\n%s\n' "$_sd_id" "$_sd_name" "$_sd_desc" | tr '[:upper:]' '[:lower:]')
    printf '%s' "$_sd_text" | grep -q 'uperf' || return 1
    printf '%s' "$_sd_text" | grep -q 'game turbo' || return 1
    return 0
}

detect_uperf_module() {
    reset_uperf_detection

    for _sd_prop in /data/adb/modules_update/*/module.prop /data/adb/modules/*/module.prop; do
        [ -f "$_sd_prop" ] || continue
        is_uperf_module_prop "$_sd_prop" || continue

        UPERF_DETECTED="yes"
        UPERF_MODULE_PATH="${_sd_prop%/module.prop}"
        UPERF_MODULE_ID=$(read_module_prop_value id "$_sd_prop")
        UPERF_MODULE_NAME=$(read_module_prop_value name "$_sd_prop")
        [ -n "$UPERF_MODULE_ID" ] || UPERF_MODULE_ID="${UPERF_MODULE_PATH##*/}"
        [ -n "$UPERF_MODULE_NAME" ] || UPERF_MODULE_NAME="$UPERF_MODULE_ID"

        case "$UPERF_MODULE_PATH" in
            /data/adb/modules_update/*) UPERF_MODULE_SOURCE="modules_update" ;;
            *)                          UPERF_MODULE_SOURCE="modules" ;;
        esac

        if [ -f "$UPERF_MODULE_PATH/remove" ]; then
            UPERF_MODULE_STATE="pending_remove"
            UPERF_MODULE_ENABLED="no"
        elif [ -f "$UPERF_MODULE_PATH/disable" ]; then
            UPERF_MODULE_STATE="disabled"
            UPERF_MODULE_ENABLED="no"
        elif [ "$UPERF_MODULE_SOURCE" = "modules_update" ]; then
            UPERF_MODULE_STATE="pending_update"
            UPERF_MODULE_ENABLED="yes"
        else
            UPERF_MODULE_STATE="active"
            UPERF_MODULE_ENABLED="yes"
        fi
        return 0
    done

    return 1
}
