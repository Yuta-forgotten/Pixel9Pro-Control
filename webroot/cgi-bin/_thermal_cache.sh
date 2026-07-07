#!/system/bin/sh
##############################################################
# _thermal_cache.sh — 热区 JSON 构建函数库
# 由 service.sh 后台任务周期调用写缓存, 由 thermal.sh 回退时直接调用
# 不作为独立 CGI 运行, 不做请求边界校验
##############################################################

build_thermal_json() {
    out="["
    sep=""
    seen=""

    append_zone() {
        _tz_name="$1"
        _tz_temp="$2"
        case "$_tz_temp" in
            ''|*[!0-9-]*) return ;;
        esac
        case "$seen" in *"|${_tz_name}|"*) return ;; esac
        out="${out}${sep}{\"zone\":\"${_tz_name}\",\"temp\":${_tz_temp}}"
        sep=","
        seen="${seen}|${_tz_name}|"
    }

    _thermal_dump=$(dumpsys thermalservice 2>/dev/null)
    _hal_pairs=$(printf '%s\n' "$_thermal_dump" | awk '
        /Current temperatures from HAL:/ { in_current = 1; next }
        /Current cooling devices from HAL:/ { if (in_current) exit }
        in_current && /Temperature\{mValue=/ { print; next }
        !in_current && /Temperature\{mValue=/ { print }
    ' | awk '
        {
            name = ""; val = ""
            if (match($0, /mName=[^,}]*/)) name = substr($0, RSTART + 6, RLENGTH - 6)
            if (match($0, /mValue=[-0-9.]+/)) val = substr($0, RSTART + 7, RLENGTH - 7)
            if (name != "" && val ~ /^-?[0-9.]+$/) printf "%s %d\n", name, val * 1000
        }
    ')

    for name in VIRTUAL-SKIN soc_therm charging_therm btmspkr_therm battery; do
        _mc=$(printf '%s\n' "$_hal_pairs" | awk -v n="$name" '$1 == n { v = $2 } END { if (v != "") print v }')
        [ -n "$_mc" ] || continue
        append_zone "$name" "$_mc"
    done

    WANT="soc_therm charging_therm btmspkr_therm"
    for zone_dir in /sys/class/thermal/thermal_zone*; do
        [ -f "$zone_dir/type" ] || continue
        type=$(cat "$zone_dir/type" 2>/dev/null)
        case "$seen" in *"|${type}|"*) continue ;; esac
        found=0
        for t in $WANT; do [ "$type" = "$t" ] && found=1 && break; done
        [ $found -eq 0 ] && continue
        temp=$(cat "$zone_dir/temp" 2>/dev/null || echo 0)
        append_zone "$type" "$temp"
    done

    bat_raw=$(cat /sys/class/power_supply/battery/temp 2>/dev/null | tr -d ' \n\r')
    if [ -n "$bat_raw" ] && [ "$bat_raw" != "0" ]; then
        bat_mc=$(awk -v r="$bat_raw" 'BEGIN{printf "%d", r * 100}')
        append_zone "battery" "$bat_mc"
    fi

    printf '%s]' "$out"
}
