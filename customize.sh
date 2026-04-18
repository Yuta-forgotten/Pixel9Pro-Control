#!/system/bin/sh
##############################################################
# customize.sh v4.2.1 — 安装时配置 (APatch / Magisk)
# 检测机型 → 刷入对应温控配置 → 应用已保存的偏移量
##############################################################

STOCK_PRO="$MODPATH/system/vendor/etc/thermal_stock.json"
STOCK_XL="$MODPATH/system/vendor/etc/thermal_stock_xl.json"
STOCK_ACTIVE="$MODPATH/system/vendor/etc/thermal_stock.json"
OUT_JSON="$MODPATH/system/vendor/etc/thermal_info_config.json"
OFFSET_FILE="$MODPATH/.thermal_offset"
PROFILE_FILE="$MODPATH/.current_profile"
DEVICE_FILE="$MODPATH/.device_variant"

device=$(getprop ro.product.device 2>/dev/null)

ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print "  Pixel 9 Pro 温控调度控制台"
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

case "$device" in
    komodo)
        ui_print "  机型: Pixel 9 Pro XL (komodo)"
        ui_print ""
        if [ -f "$STOCK_XL" ]; then
            cp "$STOCK_XL" "$STOCK_ACTIVE"
            ui_print "  ✓ 已刷入 Pro XL 专用温控配置"
        else
            ui_print "  ✗ 未找到 XL 温控配置, 使用 Pro 配置"
        fi
        echo "komodo" > "$DEVICE_FILE"
        ;;
    caiman)
        ui_print "  机型: Pixel 9 Pro (caiman)"
        ui_print ""
        ui_print "  ✓ 使用 Pro 默认温控配置"
        echo "caiman" > "$DEVICE_FILE"
        ;;
    *)
        ui_print "  机型: $device (未知)"
        ui_print "  ⚠ 非 Pro/Pro XL, 使用 Pro 配置"
        echo "$device" > "$DEVICE_FILE"
        ;;
esac

# 功能列表
ui_print ""
ui_print "  可用功能:"
ui_print "    • 温控阈值调整 (4 档)"
ui_print "    • CPU 调度模式 (5 模式)"
ui_print "    • ZRAM lz77eh 硬件加速"
ui_print "    • 保 5G 待机优化"
ui_print "    • NR 息屏降级"
ui_print "    • NTP 服务器选择"
ui_print "    • Material 3 WebUI"
ui_print ""

# 保留已有配置或设默认值
[ -f "$OFFSET_FILE" ] || echo '4' > "$OFFSET_FILE"
[ -f "$PROFILE_FILE" ] || echo 'balanced' > "$PROFILE_FILE"

# 读取保存的偏移量并应用到 thermal_info_config.json
offset=$(cat "$OFFSET_FILE" 2>/dev/null | tr -d ' \n\r\t')
case "$offset" in
    0|2|4|6) ;;
    *) offset="4" ;;
esac

awk -v off="$offset" '
/"Name":/ {
    n = $0
    sub(/.*"Name": *"/, "", n)
    sub(/".*/, "", n)
    cur = n
    tgt = (cur == "VIRTUAL-SKIN" || cur == "VIRTUAL-SKIN-HINT" || cur == "VIRTUAL-SKIN-SOC" || cur == "VIRTUAL-SKIN-CPU-LIGHT-ODPM" || cur == "VIRTUAL-SKIN-CPU-MID" || cur == "VIRTUAL-SKIN-CPU-ODPM" || cur == "VIRTUAL-SKIN-CPU-HIGH" || cur == "VIRTUAL-SKIN-GPU")
}
tgt && /"HotThreshold":/ {
    line = $0
    bs = index(line, "[")
    prefix = substr(line, 1, bs - 1)
    rest   = substr(line, bs + 1)
    be     = index(rest, "]")
    inner  = substr(rest, 1, be - 1)
    suffix = substr(rest, be)
    n_v = split(inner, vals, ", ")
    result = ""
    for (i = 1; i <= n_v; i++) {
        v = vals[i]
        if (v != "\"NAN\"") {
            v = sprintf("%.1f", v + off + 0)
        }
        result = result (i > 1 ? ", " : "") v
    }
    print prefix "[" result suffix
    next
}
{ print }
' "$STOCK_ACTIVE" > "$OUT_JSON"

if [ ! -s "$OUT_JSON" ]; then
    cp "$STOCK_ACTIVE" "$OUT_JSON"
    ui_print "  ⚠ 偏移量应用失败, 使用原始配置"
fi

ui_print "  温控偏移: +${offset}°C"
ui_print ""
ui_print "  安装完成, 重启生效"
ui_print "  WebUI: http://127.0.0.1:6210"
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
