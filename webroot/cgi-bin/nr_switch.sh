#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/nr_switch.sh
# GET  -> NR 息屏降级开关状态 + 当前网络模式
# POST -> 切换开关 on <-> off
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback

STATE_FILE="$MODDIR/.nr_screen_switch"
NR_MODE_FILE="$MODDIR/.nr_saved_mode"

nr_slot0_val() {
    case "$1" in
        *,*) printf '%s' "${1%%,*}" ;;
        *) printf '%s' "$1" ;;
    esac
}

detect_nr_key() {
    _nr_key="preferred_network_mode1"
    _current=$(settings get global "$_nr_key" 2>/dev/null | tr -d ' \n\r')
    if [ -z "$_current" ] || [ "$_current" = "null" ]; then
        _nr_key="preferred_network_mode"
        _current=$(settings get global "$_nr_key" 2>/dev/null | tr -d ' \n\r')
    fi
}

read_actual_rat() {
    dumpsys telephony.registry 2>/dev/null \
        | sed -n 's/.*mTelephonyDisplayInfo=TelephonyDisplayInfo {network=\([^,} ]*\).*/\1/p' \
        | head -n 1
}

if [ "$REQUEST_METHOD" = "GET" ]; then
    json_headers
    enabled=$(cat "$STATE_FILE" 2>/dev/null || echo "on")
    saved_nr=$(cat "$NR_MODE_FILE" 2>/dev/null || echo "33")

    detect_nr_key
    current="$_current"
    slot0=$(nr_slot0_val "$current")
    actual_rat=$(read_actual_rat)
    [ -n "$actual_rat" ] || actual_rat="unknown"

    printf '{"nr_switch":"%s","current_mode":"%s","current_slot0":"%s","actual_rat":"%s","saved_nr_mode":"%s"}' \
        "$enabled" "${current:-unknown}" "$(json_escape "${slot0:-unknown}")" "$(json_escape "$actual_rat")" "$saved_nr"

elif [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "nr_switch"
    json_headers
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null && [ "$CONTENT_LENGTH" -le 256 ]; then
        body=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
    fi
    current=$(cat "$STATE_FILE" 2>/dev/null || echo "on")
    if [ "$current" = "on" ]; then
        echo "off" > "$STATE_FILE"
        new="off"
        saved_nr=$(cat "$NR_MODE_FILE" 2>/dev/null | tr -d ' \n\r')
        [ -n "$saved_nr" ] || saved_nr="33"
        detect_nr_key
        settings put global "$_nr_key" "$saved_nr" 2>/dev/null
    else
        echo "on" > "$STATE_FILE"
        new="on"
    fi
    printf '{"ok":true,"nr_switch":"%s"}' "$new"
else
    json_error '405 Method Not Allowed' 'GET or POST'
fi
