#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/info.sh
# GET → 返回设备型号、Android 版本、模块 versionCode、基带模块状态
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
. "$MODDIR/webroot/cgi-bin/_baseband_status.sh"

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

# 内存信息 (KB)
mem_total=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
mem_avail=$(awk '/^MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
swap_total=$(awk '/^SwapTotal/{print $2}' /proc/meminfo 2>/dev/null)
swap_free=$(awk '/^SwapFree/{print $2}' /proc/meminfo 2>/dev/null)

# 内核版本
kernel=$(uname -r 2>/dev/null)

# 运行时间
uptime_sec=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)
case "$vc" in ''|*[!0-9]*) vc=0 ;; esac
case "$httpd_rss" in ''|*[!0-9]*) httpd_rss=0 ;; esac
case "$mem_total" in ''|*[!0-9]*) mem_total=0 ;; esac
case "$mem_avail" in ''|*[!0-9]*) mem_avail=0 ;; esac
case "$swap_total" in ''|*[!0-9]*) swap_total=0 ;; esac
case "$swap_free" in ''|*[!0-9]*) swap_free=0 ;; esac
case "$uptime_sec" in ''|*[!0-9]*) uptime_sec=0 ;; esac

# 检测基带模块状态。installed 只代表模块目录存在，runtime_verified 才代表
# 当前 active 模块在本次启动已经完成 source/content/effective/receipt 校验。
baseband_status_select_module >/dev/null 2>&1 || true
baseband_module_dir="$BASEBAND_STATUS_DIR"
if [ -n "$baseband_module_dir" ]; then
    baseband_installed="true"
    baseband_version="$BASEBAND_STATUS_PROP_VERSION"
else
    baseband_installed="false"
    baseband_version=""
fi
baseband_status_json=$(baseband_status_emit_json)
# Command substitution runs in a subshell, so use the emitted authoritative
# object for the summary field instead of relying on the helper's global state.
baseband_runtime_verified=$(printf '%s' "$baseband_status_json" \
    | sed -n 's/.*"runtime_verified":\(true\|false\).*/\1/p' | head -n 1)
[ "$baseband_runtime_verified" = true ] || baseband_runtime_verified=false

# 组件版本 (versions.prop, 组件级版本 SoT; 缺失时为空)
versions_file="$moddir/versions.prop"
webui_ver=$(grep '^webui=' "$versions_file" 2>/dev/null | cut -d= -f2 | tr -d '\r\n "\\')
sched_ver=$(grep '^scheduler=' "$versions_file" 2>/dev/null | cut -d= -f2 | tr -d '\r\n "\\')
core_ver=$(grep '^core=' "$versions_file" 2>/dev/null | cut -d= -f2 | tr -d '\r\n "\\')

printf '{"model":"%s","version":"%s","version_code":"%s","module_version":"%s","httpd_rss_kb":%s,"auth_required":true,"baseband_installed":%s,"baseband_enabled":%s,"baseband_runtime_verified":%s,"baseband_version":"%s","baseband_status":%s,"mem_total_kb":%s,"mem_avail_kb":%s,"swap_total_kb":%s,"swap_free_kb":%s,"kernel":"%s","uptime_sec":%s,"webui_version":"%s","scheduler_version":"%s","core_version":"%s"}' \
    "$(json_escape "$model")" "$(json_escape "$version")" "$vc" "$(json_escape "$mv")" "$httpd_rss" "$baseband_installed" \
    "$(baseband_status_bool "$BASEBAND_STATUS_ENABLED")" "$BASEBAND_STATUS_RUNTIME_VERIFIED" "$(json_escape "$baseband_version")" "$baseband_status_json" \
    "$mem_total" "$mem_avail" "$swap_total" "$swap_free" "$(json_escape "${kernel:-}")" "$uptime_sec" \
    "$(json_escape "$webui_ver")" "$(json_escape "$sched_ver")" "$(json_escape "$core_ver")"
