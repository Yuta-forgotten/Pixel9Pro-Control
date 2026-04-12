#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/thermal.sh
# GET → 返回关键热区温度 JSON
# VIRTUAL-SKIN: 来自 dumpsys thermalservice（单位 °C → ×1000 = mC）
# 其余传感器: 来自 sysfs（单位已是 mC）
##############################################################
printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

out="["
sep=""

# ── VIRTUAL-SKIN via thermalservice ──────────────────────────
# 格式: Temperature{mValue=29.485527, mType=3, mName=VIRTUAL-SKIN, mStatus=0}
vs_line=$(dumpsys thermalservice 2>/dev/null | grep 'Temperature{mValue=' | grep 'mType=3' | grep 'mName=VIRTUAL-SKIN,' | tail -1)
if [ -n "$vs_line" ]; then
    vs_c=$(printf '%s' "$vs_line" | sed 's/.*mValue=\([0-9.]*\).*/\1/')
    vs_mc=$(printf '%s' "$vs_c" | awk '{printf "%d", $1 * 1000}')
    out="${out}${sep}{\"zone\":\"VIRTUAL-SKIN\",\"temp\":${vs_mc}}"
    sep=","
fi

# ── Physical zones via sysfs ─────────────────────────────────
# quiet_therm 是内部 NTC 参考传感器，不代表环境温度，不采集
WANT="soc_therm charging_therm btmspkr_therm"
seen=""
for zone_dir in /sys/class/thermal/thermal_zone*; do
    [ -f "$zone_dir/type" ] || continue
    type=$(cat "$zone_dir/type" 2>/dev/null)
    case "$seen" in *"|${type}|"*) continue ;; esac
    found=0
    for t in $WANT; do [ "$type" = "$t" ] && found=1 && break; done
    [ $found -eq 0 ] && continue
    temp=$(cat "$zone_dir/temp" 2>/dev/null || echo 0)
    out="${out}${sep}{\"zone\":\"${type}\",\"temp\":${temp}}"
    sep=","
    seen="${seen}|${type}|"
done

# ── Battery temperature via power_supply ──────────────────────
# /sys/class/power_supply/battery/temp 单位为 0.1°C
# 换算为毫摄氏度：×100（与 sysfs 热区单位统一，前端÷1000 显示）
bat_raw=$(cat /sys/class/power_supply/battery/temp 2>/dev/null | tr -d ' \n\r')
if [ -n "$bat_raw" ] && [ "$bat_raw" != "0" ]; then
    bat_mc=$(awk "BEGIN{printf \"%d\", $bat_raw * 100}")
    out="${out}${sep}{\"zone\":\"battery\",\"temp\":${bat_mc}}"
    sep=","
fi

printf '%s]' "$out"
