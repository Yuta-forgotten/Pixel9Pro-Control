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
    case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
    case "$min" in ''|*[!0-9]*) min=0 ;; esac
    case "$max" in ''|*[!0-9]*) max=0 ;; esac
    sched_dir="$p/sched_pixel"
    if [ -d "$sched_dir" ]; then
        sched_pixel_available=true
    else
        sched_pixel_available=false
    fi
    resp_path="$sched_dir/response_time_ms"
    if [ -r "$resp_path" ]; then
        resp_text=$(cat "$resp_path" 2>/dev/null | tr -d ' \n\r\t')
        resp_available=true
    else
        resp_text="N/A"
        resp_available=false
    fi
    case "$resp_text" in ''|*[!0-9]*) resp=0; [ -n "$resp_text" ] || resp_text="N/A" ;; *) resp=$resp_text ;; esac
    down_path="$sched_dir/down_rate_limit_us"
    if [ -r "$down_path" ]; then
        down_text=$(cat "$down_path" 2>/dev/null | tr -d ' \n\r\t')
        down_available=true
    else
        down_text="N/A"
        down_available=false
    fi
    case "$down_text" in ''|*[!0-9]*) down=0; [ -n "$down_text" ] || down_text="N/A" ;; *) down=$down_text ;; esac
    out="${out}${sep}{\"cpu\":${cpu},\"cur\":${cur},\"min\":${min},\"max\":${max},\"gov\":\"$(json_escape "$gov")\",\"resp_ms\":${resp},\"down_us\":${down},\"sched_pixel_available\":${sched_pixel_available},\"resp_ms_available\":${resp_available},\"resp_ms_text\":\"$(json_escape "$resp_text")\",\"down_us_available\":${down_available},\"down_us_text\":\"$(json_escape "$down_text")\"}"
    sep=","
done
printf '%s]' "$out"
