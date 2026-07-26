#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/optimize.sh
# GET → 返回功耗优化各项设置的当前状态 JSON
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback

DEFAULTS_LIB="$MODDIR/scripts/runtime_defaults_lib.sh"
[ -r "$DEFAULTS_LIB" ] && . "$DEFAULTS_LIB" \
    || json_error '500 Internal Server Error' 'runtime defaults contract not found'
[ "$REQUEST_METHOD" = "GET" ] || json_error '405 Method Not Allowed' 'GET only'
json_headers

mda=$(runtime_android_settings get global mobile_data_always_on 2>/dev/null | tr -d ' \n\r')
wscan=$(runtime_android_settings get global wifi_scan_always_enabled 2>/dev/null | tr -d ' \n\r')
bscan=$(runtime_android_settings get global ble_scan_always_enabled 2>/dev/null | tr -d ' \n\r')
adapt_global=$(runtime_android_settings get global adaptive_connectivity_enabled 2>/dev/null | tr -d ' \n\r')
adapt_legacy=$(runtime_android_settings get secure adaptive_connectivity_enabled 2>/dev/null | tr -d ' \n\r')
adapt_wifi=$(runtime_android_settings get secure adaptive_connectivity_wifi_enabled 2>/dev/null | tr -d ' \n\r')
netrec=$(runtime_android_settings get global network_recommendations_enabled 2>/dev/null | tr -d ' \n\r')
nearby=$(runtime_android_settings get global nearby_sharing_enabled 2>/dev/null | tr -d ' \n\r')

# Keep-5G 分支不再托管 VoWiFi / WFC，避免对 Wi-Fi Calling 造成确定性副作用。
wfc="unmanaged"

case "$adapt_global" in
    0|1) adapt="$adapt_global" ;;
    *)
        case "${adapt_legacy}:${adapt_wifi}" in
            0:0) adapt="0" ;;
            1:*|*:1) adapt="1" ;;
            *) adapt="${adapt_legacy:-$adapt_wifi}" ;;
        esac
        ;;
esac

# multicast: 检查 wlan0 接口标志位
mc="off"
ip link show wlan0 2>/dev/null | grep -q "MULTICAST" && mc="on"

# SIM2 automation uses the same default as service.sh and standby_guard.sh.
sim2_auto=$(cat "$MODDIR/.sim2_auto_manage" 2>/dev/null | tr -d ' \n\r')
case "$sim2_auto" in on|off) ;; *) sim2_auto="$SIM2_AUTO_DEFAULT" ;; esac

printf '{"mobile_data_always_on":"%s","wfc_ims_enabled":"%s","wifi_scan_always_enabled":"%s","ble_scan_always_enabled":"%s","adaptive_connectivity":"%s","network_recommendations":"%s","nearby_sharing":"%s","multicast":"%s","sim2_auto_manage":"%s"}' \
    "$(json_escape "$mda")" "$wfc" "$(json_escape "$wscan")" "$(json_escape "$bscan")" \
    "$(json_escape "$adapt")" "$(json_escape "$netrec")" "$(json_escape "$nearby")" "$mc" "$sim2_auto"
