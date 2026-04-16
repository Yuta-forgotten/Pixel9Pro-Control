#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/profile.sh
# GET  → 返回当前 profile JSON
# POST → 切换 profile（body: {"profile":"game|balanced|battery"}）
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback

if [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "profile"
    len="${CONTENT_LENGTH:-0}"
    [ "$len" -gt 512 ] 2>/dev/null && len=512
    body=$(dd bs=1 count="$len" 2>/dev/null)
    newprof=$(printf '%s' "$body" | sed 's/.*"profile"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/')
    case "$newprof" in
        game|balanced|light|battery|stock)
            sh "$MODDIR/scripts/cpu_profile.sh" "$newprof" 2>/dev/null
            printf '%s' "$newprof" > "$MODDIR/.current_profile"
            json_headers
            printf '{"ok":true,"profile":"%s"}\n' "$newprof"
            ;;
        *)
            json_error '400 Bad Request' 'invalid profile'
            ;;
    esac
elif [ "$REQUEST_METHOD" = "GET" ]; then
    prof=$(cat "$MODDIR/.current_profile" 2>/dev/null | tr -d ' \n\r\t')
    case "$prof" in
        game|balanced|light|battery|stock) ;;
        *) prof="balanced" ;;
    esac
    json_headers
    printf '{"profile":"%s"}\n' "$prof"
else
    json_error '405 Method Not Allowed' 'GET or POST only'
fi
