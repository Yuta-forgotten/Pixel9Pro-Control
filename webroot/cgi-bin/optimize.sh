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

# Read each Android namespace once. Check the actual command, not a trailing
# text filter: a Binder timeout must not become a successful empty snapshot.
global_settings=$(runtime_android_settings list global 2>/dev/null) \
    || json_error '503 Service Unavailable' 'cannot read global Android settings'
secure_settings=$(runtime_android_settings list secure 2>/dev/null) \
    || json_error '503 Service Unavailable' 'cannot read secure Android settings'
# settings get returns the literal "null" for an absent key.
mda=null; adapt_global=null; adapt_legacy=null; adapt_wifi=null; netrec=null; nearby=null
while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
        mobile_data_always_on) mda="$value" ;;
        adaptive_connectivity_enabled) adapt_global="$value" ;;
        network_recommendations_enabled) netrec="$value" ;;
        nearby_sharing_enabled) nearby="$value" ;;
    esac
done <<EOF
$global_settings
EOF
while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
        adaptive_connectivity_enabled) adapt_legacy="$value" ;;
        adaptive_connectivity_wifi_enabled) adapt_wifi="$value" ;;
    esac
done <<EOF
$secure_settings
EOF

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

json_headers
printf '{"mobile_data_always_on":"%s","adaptive_connectivity":"%s","network_recommendations":"%s","nearby_sharing":"%s","multicast":"%s","sim2_auto_manage":"%s"}' \
    "$(json_escape "$mda")" \
    "$(json_escape "$adapt")" "$(json_escape "$netrec")" "$(json_escape "$nearby")" "$mc" "$sim2_auto"
