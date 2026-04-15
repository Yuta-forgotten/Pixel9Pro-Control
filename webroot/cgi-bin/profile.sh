#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/profile.sh
# GET  → 返回当前 profile JSON
# POST → 切换 profile（body: {"profile":"game|balanced|battery"}）
##############################################################
MODDIR="/data/adb/modules/pixel9pro_control"

if [ "$REQUEST_METHOD" = "POST" ]; then
    len="${CONTENT_LENGTH:-0}"
    [ "$len" -gt 512 ] 2>/dev/null && len=512
    body=$(dd bs=1 count="$len" 2>/dev/null)
    newprof=$(printf '%s' "$body" | sed 's/.*"profile"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/')
    case "$newprof" in
        game|balanced|battery|stock)
            sh "$MODDIR/scripts/cpu_profile.sh" "$newprof" 2>/dev/null
            printf '%s' "$newprof" > "$MODDIR/.current_profile"
            printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n{"ok":true,"profile":"%s"}\n' "$newprof"
            ;;
        *)
            printf 'Status: 400 Bad Request\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n{"ok":false,"error":"invalid profile"}\n'
            ;;
    esac
else
    prof=$(cat "$MODDIR/.current_profile" 2>/dev/null | tr -d ' \n\r\t')
    case "$prof" in
        game|balanced|battery|stock) ;;
        *) prof="balanced" ;;
    esac
    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n{"profile":"%s"}\n' "$prof"
fi
