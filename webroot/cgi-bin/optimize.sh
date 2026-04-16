#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/optimize.sh
# GET → 返回功耗优化各项设置的当前状态 JSON
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback
[ "$REQUEST_METHOD" = "GET" ] || json_error '405 Method Not Allowed' 'GET only'
json_headers

mda=$(settings get global mobile_data_always_on 2>/dev/null | tr -d ' \n\r')
wfc=$(settings get global wfc_ims_enabled 2>/dev/null | tr -d ' \n\r')
wscan=$(settings get global wifi_scan_always_enabled 2>/dev/null | tr -d ' \n\r')
bscan=$(settings get global ble_scan_always_enabled 2>/dev/null | tr -d ' \n\r')
adapt=$(settings get secure adaptive_connectivity_enabled 2>/dev/null | tr -d ' \n\r')
netrec=$(settings get global network_recommendations_enabled 2>/dev/null | tr -d ' \n\r')
nearby=$(settings get global nearby_sharing_enabled 2>/dev/null | tr -d ' \n\r')

# multicast: 检查 wlan0 接口标志位
mc="off"
ip link show wlan0 2>/dev/null | grep -q "MULTICAST" && mc="on"

printf '{"mobile_data_always_on":"%s","wfc_ims_enabled":"%s","wifi_scan_always_enabled":"%s","ble_scan_always_enabled":"%s","adaptive_connectivity":"%s","network_recommendations":"%s","nearby_sharing":"%s","multicast":"%s"}' \
    "$mda" "$wfc" "$wscan" "$bscan" "$adapt" "$netrec" "$nearby" "$mc"
