#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/check_baseband.sh
# GET -> 返回独立基带模块 (pixel9pro_baseband_trial) 安装状态与配置详情
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback
[ "$REQUEST_METHOD" = "GET" ] || json_error '405 Method Not Allowed' 'GET only'

json_headers

baseband_module_dir="/data/adb/modules/pixel9pro_baseband_trial"

if [ -d "$baseband_module_dir" ]; then
    installed="true"
    bb_version=$(grep '^version=' "$baseband_module_dir/module.prop" 2>/dev/null | cut -d= -f2 | tr -d '\r\n "\\')
    bb_versionCode=$(grep '^versionCode=' "$baseband_module_dir/module.prop" 2>/dev/null | cut -d= -f2 | tr -d '\r\n "\\')
    bb_desc=$(grep '^description=' "$baseband_module_dir/module.prop" 2>/dev/null | cut -d= -f2- | tr -d '\r\n"\\')

    # 5G/IMS props
    volte=$(getprop persist.dbg.volte_avail_ovr 2>/dev/null)
    wfc=$(getprop persist.dbg.wfc_avail_ovr 2>/dev/null)
    vt=$(getprop persist.dbg.vt_avail_ovr 2>/dev/null)

    # CarrierSettings overlay
    cs_dir="$baseband_module_dir/system/product/etc/CarrierSettings"
    if [ -d "$cs_dir" ]; then
        cs_count=$(ls "$cs_dir"/*.pb 2>/dev/null | wc -l)
        cs_installed="true"
    else
        cs_count=0
        cs_installed="false"
    fi

    # MCFG overlay
    mcfg_dir="$baseband_module_dir/system/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China"
    if [ -d "$mcfg_dir" ]; then
        mcfg_count=$(find "$mcfg_dir" -name 'mcfg_sw.mbn' 2>/dev/null | wc -l)
        mcfg_installed="true"
    else
        mcfg_count=0
        mcfg_installed="false"
    fi

    printf '{"installed":true,"version":"%s","version_code":"%s","description":"%s","props":{"volte_avail_ovr":"%s","wfc_avail_ovr":"%s","vt_avail_ovr":"%s"},"carrier_settings":{"installed":%s,"count":%d},"mcfg":{"installed":%s,"count":%d}}' \
        "$(json_escape "$bb_version")" \
        "$bb_versionCode" \
        "$(json_escape "$bb_desc")" \
        "$volte" "$wfc" "$vt" \
        "$cs_installed" "$cs_count" \
        "$mcfg_installed" "$mcfg_count"
else
    printf '{"installed":false,"version":"","version_code":"","description":"","props":{},"carrier_settings":{"installed":false,"count":0},"mcfg":{"installed":false,"count":0}}'
fi
