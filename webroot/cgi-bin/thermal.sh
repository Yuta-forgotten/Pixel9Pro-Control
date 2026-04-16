#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/thermal.sh
# GET → 返回关键热区温度 JSON
# 优先读取 service.sh 生成的热区缓存，缺失时再回退实时采集
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_thermal_cache.sh"

require_loopback
[ "$REQUEST_METHOD" = "GET" ] || json_error '405 Method Not Allowed' 'GET only'
json_headers

if [ -s "$THERMAL_CACHE" ]; then
    cat "$THERMAL_CACHE"
    exit 0
fi

build_thermal_json
