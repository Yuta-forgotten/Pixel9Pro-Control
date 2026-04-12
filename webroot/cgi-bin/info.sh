#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/info.sh
# GET → 返回设备型号、Android 版本、模块 versionCode
##############################################################
printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

model=$(getprop ro.product.model         2>/dev/null | tr -d '\n"\\')
version=$(getprop ro.build.version.release 2>/dev/null | tr -d '\n"\\')

# busybox httpd CGI 下 $0 不含完整路径，直接使用固定模块目录（与其他 CGI 脚本一致）
moddir="/data/adb/modules/pixel9pro_control"
vc=$(grep '^versionCode=' "$moddir/module.prop" 2>/dev/null \
     | cut -d= -f2 | tr -d '\r\n "\\')
mv=$(grep '^version=' "$moddir/module.prop" 2>/dev/null \
     | cut -d= -f2 | tr -d '\r\n "\\')

printf '{"model":"%s","version":"%s","version_code":"%s","module_version":"%s"}' \
    "$model" "$version" "$vc" "$mv"
