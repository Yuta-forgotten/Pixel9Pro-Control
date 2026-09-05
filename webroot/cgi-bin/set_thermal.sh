#!/system/bin/sh

# GET returns the active thermal offset. POST accepts -2/0/+2/+4/+6, rebuilds
# config from the device stock baseline, persists the offset, and attempts one
# verified Thermal HAL restart. The shared library owns threshold selection,
# offset translation, SHUTDOWN preservation, and monotonicity validation.

. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback

OFFSET_FILE="$MODDIR/.thermal_offset"
STOCK_JSON="$MODDIR/system/vendor/etc/thermal_stock.json"
OUT_JSON="$MODDIR/system/vendor/etc/thermal_info_config.json"
THERMAL_LIB="$MODDIR/scripts/thermal_profile.sh"

[ -r "$THERMAL_LIB" ] \
    || json_error '500 Internal Server Error' 'thermal profile library not found'
. "$THERMAL_LIB" \
    || json_error '500 Internal Server Error' 'thermal profile library failed to load'

thermal_service_getprop() {
    _thermal_bin="/system/bin/getprop"
    [ "${PIXEL9PRO_CGI_TEST_MODE:-0}" = "1" ] \
        && _thermal_bin="${PIXEL9PRO_ANDROID_GETPROP:-getprop}"
    "$_thermal_bin" "$@"
}

thermal_service_stop() {
    _thermal_bin="/system/bin/stop"
    [ "${PIXEL9PRO_CGI_TEST_MODE:-0}" = "1" ] \
        && _thermal_bin="${PIXEL9PRO_ANDROID_STOP:-stop}"
    "$_thermal_bin" "$@"
}

thermal_service_start() {
    _thermal_bin="/system/bin/start"
    [ "${PIXEL9PRO_CGI_TEST_MODE:-0}" = "1" ] \
        && _thermal_bin="${PIXEL9PRO_ANDROID_START:-start}"
    "$_thermal_bin" "$@"
}

thermal_service_log() {
    _thermal_bin="/system/bin/log"
    [ "${PIXEL9PRO_CGI_TEST_MODE:-0}" = "1" ] \
        && _thermal_bin="${PIXEL9PRO_ANDROID_LOG:-log}"
    "$_thermal_bin" "$@"
}

ensure_thermal_service_running() {
    _thermal_service="$1"
    for _thermal_attempt in 1 2; do
        thermal_service_start "$_thermal_service" 2>/dev/null || true
        sleep 1
        [ "$(thermal_service_getprop "init.svc.$_thermal_service" 2>/dev/null)" = "running" ] \
            && return 0
    done
    return 1
}

parse_thermal_offset() {
    # Accept one unambiguous JSON object only.  The CGI contract intentionally
    # does not depend on jq/python being present on the device.
    printf '%s\n' "$1" | awk '
        BEGIN { value = "" }
        /^[[:space:]]*\{[[:space:]]*"offset"[[:space:]]*:[[:space:]]*-?[0-9]+[[:space:]]*\}[[:space:]]*$/ {
            line = $0
            sub(/^[[:space:]]*\{[[:space:]]*"offset"[[:space:]]*:[[:space:]]*/, "", line)
            sub(/[[:space:]]*\}[[:space:]]*$/, "", line)
            value = line
        }
        END {
            if (value != "") print value
            else exit 1
        }
    '
}

rollback_thermal_change() {
    THERMAL_ROLLBACK_RESULT="incomplete"
    _rollback_config_ok=0
    _rollback_state_ok=0
    if mv "$_rollback" "$OUT_JSON" 2>/dev/null \
        && [ "$(sha256sum "$OUT_JSON" 2>/dev/null | awk '{print $1}')" = "$_rollback_hash" ]; then
        _rollback_config_ok=1
    fi
    if cgi_restore_file "$OFFSET_FILE" "$_offset_existed" "$_offset_old"; then
        _rollback_state_ok=1
    fi
    case "$_rollback_config_ok:$_rollback_state_ok" in
        1:1) THERMAL_ROLLBACK_RESULT="complete"; return 0 ;;
        1:0) THERMAL_ROLLBACK_RESULT="state_incomplete" ;;
        0:1) THERMAL_ROLLBACK_RESULT="config_incomplete" ;;
        *) THERMAL_ROLLBACK_RESULT="config_and_state_incomplete" ;;
    esac
    return 1
}

if [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "thermal"

    read_json_body 512
    body="$JSON_BODY"
    offset=$(parse_thermal_offset "$body") || \
        json_error '400 Bad Request' 'invalid JSON body; expected {"offset":-2|0|2|4|6}'

    thermal_is_valid_offset "$offset" \
        || json_error '400 Bad Request' "invalid offset: $offset"
    [ -f "$STOCK_JSON" ] \
        || json_error '500 Internal Server Error' 'stock json not found'

    _candidate="${OUT_JSON}.candidate.$$"
    _rollback="${OUT_JSON}.rollback.$$"
    _offset_existed=0
    [ -e "$OFFSET_FILE" ] && _offset_existed=1
    _offset_old=$(cat "$OFFSET_FILE" 2>/dev/null)
    thermal_generate_config "$STOCK_JSON" "$_candidate" "$offset" \
        || json_error '500 Internal Server Error' 'thermal config generation failed'
    cp "$OUT_JSON" "$_rollback" 2>/dev/null || {
        rm -f "$_candidate" 2>/dev/null
        json_error '500 Internal Server Error' 'thermal rollback snapshot failed'
    }
    _rollback_hash=$(sha256sum "$_rollback" 2>/dev/null | awk '{print $1}')
    [ -n "$_rollback_hash" ] || {
        rm -f "$_candidate" "$_rollback" 2>/dev/null
        json_error '500 Internal Server Error' 'thermal rollback snapshot verification failed'
    }
    if ! mv "$_candidate" "$OUT_JSON" 2>/dev/null; then
        rm -f "$_candidate" "$_rollback" 2>/dev/null
        json_error '500 Internal Server Error' 'thermal config commit failed'
    fi
    if ! cgi_atomic_write "$OFFSET_FILE" "$offset"; then
        if rollback_thermal_change; then
            json_error '500 Internal Server Error' 'thermal offset persistence failed; previous config restored'
        fi
        json_error '500 Internal Server Error' "thermal offset persistence failed; rollback incomplete ($THERMAL_ROLLBACK_RESULT)"
    fi

    restarted=false
    for svc in vendor.thermal-hal vendor.thermal-hal-2-0 thermal-hal-2-0 thermalserviced; do
        [ "$(thermal_service_getprop "init.svc.$svc" 2>/dev/null)" = "running" ] || continue
        if thermal_service_stop "$svc" 2>/dev/null; then
            sleep 1
            if ensure_thermal_service_running "$svc"; then
                restarted=true
                thermal_service_log -t pixel9pro_ctrl "Thermal service restarted: $svc (offset=${offset}C)"
            else
                thermal_service_log -t pixel9pro_ctrl "ERROR: thermal service did not return to running: $svc"
                _thermal_rollback_ok=0
                rollback_thermal_change && _thermal_rollback_ok=1
                _thermal_service_recovered=0
                ensure_thermal_service_running "$svc" && _thermal_service_recovered=1
                if [ "$_thermal_rollback_ok" -eq 1 ] && [ "$_thermal_service_recovered" -eq 1 ]; then
                    json_error '500 Internal Server Error' 'thermal restart failed; previous config restored'
                fi
                if [ "$_thermal_rollback_ok" -eq 1 ]; then
                    json_error '500 Internal Server Error' 'thermal restart failed; previous config restored but service recovery failed'
                fi
                json_error '500 Internal Server Error' "thermal restart failed; rollback incomplete ($THERMAL_ROLLBACK_RESULT)"
            fi
        else
            if rollback_thermal_change; then
                json_error '500 Internal Server Error' 'thermal service stop failed; previous config restored'
            fi
            json_error '500 Internal Server Error' "thermal service stop failed; rollback incomplete ($THERMAL_ROLLBACK_RESULT)"
        fi
        break
    done

    rm -f "$_rollback" 2>/dev/null

    json_headers
    printf '{"ok":true,"offset":%s,"restarted":%s,"thermal_contract":' "$offset" "$restarted"
    thermal_print_ui_contract_json
    printf '}\n'
elif [ "$REQUEST_METHOD" = "GET" ]; then
    offset=$(cat "$OFFSET_FILE" 2>/dev/null | tr -d ' \n\r\t')
    offset=$(thermal_normalize_offset "$offset" "$THERMAL_DEFAULT_OFFSET")
    json_headers
    printf '{"offset":%s,"thermal_contract":' "$offset"
    thermal_print_ui_contract_json
    printf '}\n'
else
    json_error '405 Method Not Allowed' 'GET or POST only'
fi
