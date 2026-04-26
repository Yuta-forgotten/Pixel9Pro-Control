#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/info.sh
# GET → 返回设备型号、Android 版本、模块 versionCode、基带模块状态
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback
[ "$REQUEST_METHOD" = "GET" ] || json_error '405 Method Not Allowed' 'GET only'
json_headers

model=$(getprop ro.product.model         2>/dev/null)
version=$(getprop ro.build.version.release 2>/dev/null)
moddir="$MODDIR"
vc=$(grep '^versionCode=' "$moddir/module.prop" 2>/dev/null \
     | cut -d= -f2 | tr -d '\r\n "\\')
mv=$(grep '^version=' "$moddir/module.prop" 2>/dev/null \
     | cut -d= -f2 | tr -d '\r\n "\\')

# WebUI httpd 进程 RSS (CGI 的父进程即 httpd)
httpd_rss=$(awk '/^VmRSS/{print $2}' "/proc/$PPID/status" 2>/dev/null)
token=$(read_webui_token)

# 内存信息 (KB)
mem_total=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
mem_avail=$(awk '/^MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
swap_total=$(awk '/^SwapTotal/{print $2}' /proc/meminfo 2>/dev/null)
swap_free=$(awk '/^SwapFree/{print $2}' /proc/meminfo 2>/dev/null)

# 内核版本
kernel=$(uname -r 2>/dev/null)

# 运行时间
uptime_sec=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)

# 检测基带模块安装状态
baseband_module_dir="/data/adb/modules/pixel9pro_baseband_trial"
if [ -d "$baseband_module_dir" ]; then
    baseband_installed="true"
    baseband_version=$(grep '^version=' "$baseband_module_dir/module.prop" 2>/dev/null | cut -d= -f2 | tr -d '\r\n "\\')
else
    baseband_installed="false"
    baseband_version=""
fi

printf '{"model":"%s","version":"%s","version_code":"%s","module_version":"%s","httpd_rss_kb":%s,"webui_token":"%s","baseband_installed":%s,"baseband_version":"%s","mem_total_kb":%s,"mem_avail_kb":%s,"swap_total_kb":%s,"swap_free_kb":%s,"kernel":"%s","uptime_sec":%s}' \
    "$(json_escape "$model")" "$(json_escape "$version")" "$vc" "$mv" "${httpd_rss:-0}" "$(json_escape "$token")" "$baseband_installed" "$(json_escape "$baseband_version")" \
    "${mem_total:-0}" "${mem_avail:-0}" "${swap_total:-0}" "${swap_free:-0}" "$(json_escape "${kernel:-}")" "${uptime_sec:-0}"

