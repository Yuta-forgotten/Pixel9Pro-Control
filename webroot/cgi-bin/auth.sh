#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/auth.sh
# GET -> 返回当前 WebUI token，用于本机会话弹窗预填
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback
[ "$REQUEST_METHOD" = "GET" ] || json_error '405 Method Not Allowed' 'GET only'

token="$(read_webui_token)"
[ -n "$token" ] || json_error '503 Service Unavailable' 'missing server token'

json_headers
printf '{"ok":true,"token":"%s","token_len":%s}\n' "$(json_escape "$token")" "${#token}"
