#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/info.sh
# GET → 返回设备型号、Android 版本、模块 versionCode、webui_token
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback
[ "$REQUEST_METHOD" = "GET" ] || json_error '405 Method Not Allowed' 'GET only'
json_headers

model=$(getprop ro.product.model         2>/dev/null | tr -d '\n"\\')
version=$(getprop ro.build.version.release 2>/dev/null | tr -d '\n"\\')

vc=$(grep '^versionCode=' "$MODDIR/module.prop" 2>/dev/null \
     | cut -d= -f2 | tr -d '\r\n "\\')
mv=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null \
     | cut -d= -f2 | tr -d '\r\n "\\')

# WebUI httpd 进程 RSS (CGI 的父进程即 httpd)
httpd_rss=$(awk '/^VmRSS/{print $2}' "/proc/$PPID/status" 2>/dev/null)

# Token 供前端后续写操作使用
token="$(read_webui_token)"

printf '{"model":"%s","version":"%s","version_code":"%s","module_version":"%s","httpd_rss_kb":%s,"webui_token":"%s"}' \
    "$(json_escape "$model")" "$(json_escape "$version")" "$vc" "$mv" "${httpd_rss:-0}" "$token"
