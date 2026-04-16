#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/status.sh
# GET → 返回三个 CPU 簇的频率状态 JSON
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback
[ "$REQUEST_METHOD" = "GET" ] || json_error '405 Method Not Allowed' 'GET only'
json_headers

out="["
sep=""
for cpu in 0 4 7; do
    p="/sys/devices/system/cpu/cpu${cpu}/cpufreq"
    cur=$(cat "$p/scaling_cur_freq"  2>/dev/null || echo 0)
    min=$(cat "$p/scaling_min_freq"  2>/dev/null || echo 0)
    max=$(cat "$p/scaling_max_freq"  2>/dev/null || echo 0)
    gov=$(cat "$p/scaling_governor"  2>/dev/null || echo "unknown")
    resp=$(cat "$p/sched_pixel/response_time_ms"   2>/dev/null || echo 0)
    down=$(cat "$p/sched_pixel/down_rate_limit_us" 2>/dev/null || echo 0)
    out="${out}${sep}{\"cpu\":${cpu},\"cur\":${cur},\"min\":${min},\"max\":${max},\"gov\":\"${gov}\",\"resp_ms\":${resp},\"down_us\":${down}}"
    sep=","
done
printf '%s]' "$out"
