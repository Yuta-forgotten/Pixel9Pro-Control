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

is_nr_mode_raw() {
    case "$1" in
        ''|null|*[!0-9,-]*|*,*,*) return 1 ;;
        *,*)
            _first=${1%%,*}
            _rest=${1#*,}
            case "$_first" in ''|*[!0-9-]*) return 1 ;; esac
            case "$_rest" in ''|*[!0-9,-]*) return 1 ;; esac
            ;;
        *) ;;
    esac
    return 0
}

read_saved_nr_mode() {
    _saved=$(cat "$NR_MODE_FILE" 2>/dev/null | tr -d ' \n\r\t')
    if is_nr_mode_raw "$_saved"; then
        printf '%s' "$_saved"
    else
        printf '33'
        printf '%s' '33' > "$NR_MODE_FILE" 2>/dev/null || true
    fi
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
    saved_nr=$(read_saved_nr_mode)

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
    _len="${CONTENT_LENGTH:-0}"
    case "$_len" in ''|*[!0-9]*) _len=0 ;; esac
    [ "$_len" -gt 0 ] 2>/dev/null || json_error '400 Bad Request' 'empty request body'
    [ "$_len" -gt 256 ] 2>/dev/null && _len=256
    body=$(dd bs=1 count="$_len" 2>/dev/null)
    action=$(printf '%s' "$body" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')
    requested=$(printf '%s' "$body" | sed -n 's/.*"enabled"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
    current=$(cat "$STATE_FILE" 2>/dev/null || echo "on")
    case "$current" in on|off) ;; *) current="on" ;; esac
    case "$action" in
        toggle) [ "$current" = "on" ] && new="off" || new="on" ;;
        set) case "$requested" in on|off) new="$requested" ;; *) json_error '400 Bad Request' 'invalid enabled' ;; esac ;;
        *) json_error '400 Bad Request' 'invalid action' ;;
    esac
    echo "$new" > "$STATE_FILE"
    if [ "$new" = "off" ]; then
        saved_nr=$(read_saved_nr_mode)
        detect_nr_key
        settings put global "$_nr_key" "$saved_nr" 2>/dev/null
    fi
    json_headers
    printf '{"ok":true,"nr_switch":"%s"}' "$new"
else
    json_error '405 Method Not Allowed' 'GET or POST'
fi
