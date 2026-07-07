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
        _len="${CONTENT_LENGTH:-0}"
        case "$_len" in ''|*[!0-9]*) _len=0 ;; esac
        [ "$_len" -gt 0 ] 2>/dev/null || json_error '400 Bad Request' 'empty request body'
        [ "$_len" -gt 256 ] 2>/dev/null && _len=256
        _body=$(dd bs=1 count="$_len" 2>/dev/null)
        _action=$(printf '%s' "$_body" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')
        _duration=$(printf '%s' "$_body" | sed -n 's/.*"duration_sec"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
        [ "$_action" = "start" ] || json_error '400 Bad Request' 'invalid action'
        [ -n "$_duration" ] || _duration=300
        case "$_duration" in 60|120|300|600) ;; *) json_error '400 Bad Request' 'invalid duration_sec' ;; esac
        _now=$(date +%s 2>/dev/null || echo 0)
        _until=$((_now + _duration))
        printf '%s' "$_until" > "$BURST_FILE"
        json_headers
        printf '{"ok":true,"burst_active":true,"burst_until":"%s","duration_sec":%s}\n' "$_until" "$_duration"
        ;;
    *)
        json_error '405 Method Not Allowed' 'GET or POST only'
        ;;
esac
