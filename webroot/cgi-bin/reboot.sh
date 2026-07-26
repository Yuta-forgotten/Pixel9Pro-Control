#!/system/bin/sh
# Authenticated reboot request. The one-second delay lets the JSON response
# leave busybox httpd before Android starts rebooting.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback
require_json_post
require_token
read_json_body 256
body="$JSON_BODY"
action=$(printf '%s' "$body" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')
confirm=$(printf '%s' "$body" | sed -n 's/.*"confirm"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')
[ "$action" = "reboot" ] && [ "$confirm" = "true" ] || json_error '400 Bad Request' 'missing reboot confirmation'
acquire_lock "reboot"
json_headers
printf '{"ok":true}'
sync
(sleep 1; reboot || log -t pixel9pro_ctrl 'ERROR: WebUI reboot command failed') &
