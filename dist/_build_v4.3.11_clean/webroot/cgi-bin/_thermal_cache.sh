#!/system/bin/sh
##############################################################
# _thermal_cache.sh — 热区 JSON 构建函数库
# 由 service.sh 后台任务周期调用写缓存, 由 thermal.sh 回退时直接调用
# 不作为独立 CGI 运行, 不做请求边界校验
##############################################################

build_thermal_json() {
    out="["
    sep=""

    vs_line=$(dumpsys thermalservice 2>/dev/null | grep 'Temperature{mValue=' | grep 'mType=3' | grep 'mName=VIRTUAL-SKIN,' | tail -1)
    if [ -n "$vs_line" ]; then
        vs_c=$(printf '%s' "$vs_line" | sed 's/.*mValue=\([0-9.]*\).*/\1/')
        vs_mc=$(printf '%s' "$vs_c" | awk '{printf "%d", $1 * 1000}')
        out="${out}${sep}{\"zone\":\"VIRTUAL-SKIN\",\"temp\":${vs_mc}}"
        sep=","
    fi

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

    bat_raw=$(cat /sys/class/power_supply/battery/temp 2>/dev/null | tr -d ' \n\r')
    if [ -n "$bat_raw" ] && [ "$bat_raw" != "0" ]; then
        bat_mc=$(awk -v r="$bat_raw" 'BEGIN{printf "%d", r * 100}')
        out="${out}${sep}{\"zone\":\"battery\",\"temp\":${bat_mc}}"
        sep=","
    fi

    printf '%s]' "$out"
}
