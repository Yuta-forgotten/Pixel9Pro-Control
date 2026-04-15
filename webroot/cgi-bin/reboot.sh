#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/reboot.sh
# POST → 延迟 1s 后重启设备（让响应先送出）
##############################################################
if [ "$REQUEST_METHOD" != "POST" ]; then
    printf 'Status: 405 Method Not Allowed\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    printf '{"ok":false,"error":"POST only"}\n'
    exit 0
fi
printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
printf '{"ok":true}'
sync
(sleep 1; reboot) &
