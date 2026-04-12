#!/system/bin/sh
# customize.sh — 极简风格（参照 v6/v7 reference 结构）
# 不用 APatch 框架函数（ui_print/set_perm_recursive）
# ZIP 里 .sh 文件已设 exec bit，无需再 chmod
echo "pixel9pro_control v2.3 installed on $(date)" > /data/adb/control_mod.log

# Phase 3: 初始化温控档位文件（升级安装时保留用户上次选择）
# $MODPATH 由 APatch/KernelSU 框架注入，指向 /data/adb/modules/pixel9pro_control/
[ -f "$MODPATH/.thermal_offset" ] || echo '4' > "$MODPATH/.thermal_offset"
