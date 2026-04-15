#!/system/bin/sh
# customize.sh v3.2.1
echo "pixel9pro_control v3.2.1 installed on $(date)" > /data/adb/control_mod.log

# 保留用户上次选择的温控档位和CPU配置
[ -f "$MODPATH/.thermal_offset" ] || echo '4' > "$MODPATH/.thermal_offset"
[ -f "$MODPATH/.current_profile" ] || echo 'balanced' > "$MODPATH/.current_profile"
