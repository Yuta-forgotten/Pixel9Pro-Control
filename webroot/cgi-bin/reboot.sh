#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/reboot.sh
# POST → 延迟 1s 后重启设备（让响应先送出）
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback
require_json_post
require_token
_len="${CONTENT_LENGTH:-0}"
case "$_len" in ''|*[!0-9]*) _len=0 ;; esac
[ "$_len" -gt 0 ] 2>/dev/null || json_error '400 Bad Request' 'empty request body'
[ "$_len" -gt 256 ] 2>/dev/null && _len=256
body=$(dd bs=1 count="$_len" 2>/dev/null)
action=$(printf '%s' "$body" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')
confirm=$(printf '%s' "$body" | sed -n 's/.*"confirm"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')
[ "$action" = "reboot" ] && [ "$confirm" = "true" ] || json_error '400 Bad Request' 'missing reboot confirmation'
json_headers
printf '{"ok":true}'
sync
(sleep 1; reboot) &
