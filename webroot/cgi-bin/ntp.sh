#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/ntp.sh
# GET  -> 当前 NTP 服务器 + 设备时间
# POST -> 切换 NTP 服务器 + 立即同步
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback

NTP_SAVE="$MODDIR/.ntp_server"

normalize_ntp_server() {
    case "$1" in
        ntp.aliyun.com|ntp.myhuaweicloud.com|ntp1.xiaomi.com|time.android.com) printf '%s' "$1" ;;
        *) printf 'time.android.com' ;;
    esac
}

if [ "$REQUEST_METHOD" = "GET" ]; then
    json_headers
    server=$(settings get global ntp_server 2>/dev/null | tr -d ' \n\r')
    [ -z "$server" ] || [ "$server" = "null" ] && server="time.android.com"
    server=$(normalize_ntp_server "$server")
    auto_time=$(settings get global auto_time 2>/dev/null | tr -d ' \n\r')
    dev_time=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    printf '{"ntp_server":"%s","auto_time":"%s","device_time":"%s"}' \
        "$(json_escape "$server")" "$(json_escape "${auto_time:-1}")" "$(json_escape "$dev_time")"

elif [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "ntp"
    body=""
    _len="${CONTENT_LENGTH:-0}"
    case "$_len" in ''|*[!0-9]*) _len=0 ;; esac
    [ "$_len" -gt 0 ] 2>/dev/null || json_error '400 Bad Request' 'empty request body'
    [ "$_len" -gt 512 ] 2>/dev/null && _len=512
    body=$(dd bs=1 count="$_len" 2>/dev/null)

    # Extract server value: {"server":"ntp.aliyun.com"} or {"action":"sync"}
    action=$(printf '%s' "$body" | sed -n 's/.*"action" *: *"\([^"]*\)".*/\1/p')
    server=$(printf '%s' "$body" | sed -n 's/.*"server" *: *"\([^"]*\)".*/\1/p')

    if [ "$action" = "sync" ]; then
        cmd network_time_update_service force_refresh >/dev/null 2>&1
        dev_time=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
        json_headers
        printf '{"ok":true,"action":"sync","device_time":"%s"}' "$(json_escape "$dev_time")"
    elif [ -n "$server" ]; then
        case "$server" in
            ntp.aliyun.com|ntp.myhuaweicloud.com|ntp1.xiaomi.com|time.android.com)
                settings put global ntp_server "$server" 2>/dev/null
                echo "$server" > "$NTP_SAVE"
                cmd network_time_update_service force_refresh >/dev/null 2>&1
                sleep 1
                dev_time=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
                json_headers
                printf '{"ok":true,"ntp_server":"%s","device_time":"%s"}' "$(json_escape "$server")" "$(json_escape "$dev_time")"
                ;;
            *)
                json_error '400 Bad Request' 'unsupported server'
                ;;
        esac
    else
        json_error '400 Bad Request' 'missing server or action'
    fi
else
    json_error '405 Method Not Allowed' 'GET or POST'
fi
