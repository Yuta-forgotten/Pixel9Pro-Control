#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/check_baseband.sh
# GET -> 返回独立基带模块 (pixel9pro_baseband_trial) 是否安装
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback
[ "$REQUEST_METHOD" = "GET" ] || json_error '405 Method Not Allowed' 'GET only'

json_headers

# 检查基带模块是否安装
baseband_module_dir="/data/adb/modules/pixel9pro_baseband_trial"
if [ -d "$baseband_module_dir" ]; then
    # 尝试读取基带模块的版本信息
    baseband_version=$(grep '^version=' "$baseband_module_dir/module.prop" 2>/dev/null | cut -d= -f2 | tr -d '\r\n "\\')
    baseband_versionCode=$(grep '^versionCode=' "$baseband_module_dir/module.prop" 2>/dev/null | cut -d= -f2 | tr -d '\r\n "\\')
    installed="true"
else
    baseband_version=""
    baseband_versionCode=""
    installed="false"
fi

printf '{"installed":%s,"version":"%s","version_code":"%s"}' \
    "$installed" \
    "$(json_escape "$baseband_version")" \
    "$baseband_versionCode"
