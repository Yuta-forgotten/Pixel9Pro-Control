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
wscan=$(settings get global wifi_scan_always_enabled 2>/dev/null | tr -d ' \n\r')
bscan=$(settings get global ble_scan_always_enabled 2>/dev/null | tr -d ' \n\r')
adapt_legacy=$(settings get secure adaptive_connectivity_enabled 2>/dev/null | tr -d ' \n\r')
adapt_wifi=$(settings get secure adaptive_connectivity_wifi_enabled 2>/dev/null | tr -d ' \n\r')
netrec=$(settings get global network_recommendations_enabled 2>/dev/null | tr -d ' \n\r')
nearby=$(settings get global nearby_sharing_enabled 2>/dev/null | tr -d ' \n\r')

# Keep-5G 分支不再托管 VoWiFi / WFC，避免对 Wi-Fi Calling 造成确定性副作用。
wfc="unmanaged"

case "${adapt_legacy}:${adapt_wifi}" in
    0:0) adapt="0" ;;
    1:*|*:1) adapt="1" ;;
    *) adapt="${adapt_legacy:-$adapt_wifi}" ;;
esac

# multicast: 检查 wlan0 接口标志位
mc="off"
ip link show wlan0 2>/dev/null | grep -q "MULTICAST" && mc="on"

# SIM2 自动管理状态 (v4.3.16: 默认关闭)
sim2_auto=$(cat "$MODDIR/.sim2_auto_manage" 2>/dev/null | tr -d ' \n\r')
[ -z "$sim2_auto" ] && sim2_auto="off"

printf '{"mobile_data_always_on":"%s","wfc_ims_enabled":"%s","wifi_scan_always_enabled":"%s","ble_scan_always_enabled":"%s","adaptive_connectivity":"%s","network_recommendations":"%s","nearby_sharing":"%s","multicast":"%s","sim2_auto_manage":"%s"}' \
    "$mda" "$wfc" "$wscan" "$bscan" "$adapt" "$netrec" "$nearby" "$mc" "$sim2_auto"
