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

if [ "$REQUEST_METHOD" = "GET" ]; then
    json_headers
    enabled=$(cat "$STATE_FILE" 2>/dev/null || echo "off")
    saved_nr=$(cat "$NR_MODE_FILE" 2>/dev/null || echo "33")

    nr_key="preferred_network_mode1"
    current=$(settings get global "$nr_key" 2>/dev/null | tr -d ' \n\r')
    if [ -z "$current" ] || [ "$current" = "null" ]; then
        nr_key="preferred_network_mode"
        current=$(settings get global "$nr_key" 2>/dev/null | tr -d ' \n\r')
    fi

    printf '{"nr_switch":"%s","current_mode":"%s","saved_nr_mode":"%s"}' \
        "$enabled" "${current:-unknown}" "$saved_nr"

elif [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    json_headers
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null && [ "$CONTENT_LENGTH" -le 256 ]; then
        body=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
    fi
    current=$(cat "$STATE_FILE" 2>/dev/null || echo "off")
    if [ "$current" = "on" ]; then
        echo "off" > "$STATE_FILE"
        new="off"
    else
        echo "on" > "$STATE_FILE"
        new="on"
    fi
    printf '{"ok":true,"nr_switch":"%s"}' "$new"
else
    json_error '405 Method Not Allowed' 'GET or POST'
fi
