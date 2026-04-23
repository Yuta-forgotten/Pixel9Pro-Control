#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/thermal_burst.sh
# GET  -> 返回当前温度突发录制状态
# POST -> 启动 5 分钟突发录制 (5s 间隔)
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

BURST_FILE="$MODDIR/.thermal_burst_until"

require_loopback

case "$REQUEST_METHOD" in
    GET)
        json_headers
        _until=$(cat "$BURST_FILE" 2>/dev/null | tr -d ' \n\r')
        _now=$(date +%s 2>/dev/null || echo 0)
        _active=false
        [ -n "$_until" ] && [ "$_until" -gt "$_now" ] 2>/dev/null && _active=true
        printf '{"ok":true,"burst_active":%s,"burst_until":"%s"}\n' "$_active" "${_until:-0}"
        ;;
    POST)
        require_json_post
        require_token
        _now=$(date +%s 2>/dev/null || echo 0)
        _until=$((_now + 300))
        printf '%s' "$_until" > "$BURST_FILE"
        json_headers
        printf '{"ok":true,"burst_active":true,"burst_until":"%s"}\n' "$_until"
        ;;
    *)
        json_error '405 Method Not Allowed' 'GET or POST only'
        ;;
esac
