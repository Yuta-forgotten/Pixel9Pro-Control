#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/reboot.sh
# POST → 延迟 1s 后重启设备（让响应先送出）
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback
require_json_post
require_token
json_headers
printf '{"ok":true}'
sync
(sleep 1; reboot) &
