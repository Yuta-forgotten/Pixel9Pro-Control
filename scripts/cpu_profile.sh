#!/system/bin/sh
# ============================================================
# Pixel 9 Pro — Tensor G4 CPU 场景调度切换 v4.3.14
# 用法: sh cpu_profile.sh [game|balanced|light|battery|stock|status]
#
# 核心原理:
#   - 不再写 scaling_max_freq / scaling_min_freq (会被 thermal HAL 覆盖)
#   - 通过 sched_pixel 参数控制频率行为, cpuset 路由 top-app/background
#   - foreground cpuset 由 system_server 框架层管理, 固定为 0-6, 不可覆盖
#   - v4.3.14 起，light/battery 不再把 top-app 固定推到 4-7，也不再把小核锁死在 820MHz
#     目标是让小核承担 steady-state 前台杂务，中核按需补位，大核尽量慢介入
#
# Tensor G4 拓扑：
#   cpu0-3  Cortex-A520 (小核)  820-1950 MHz
#   cpu4-6  Cortex-A720 (中核)  357-2600 MHz
#   cpu7    Cortex-X4   (大核)  700-3105 MHz
#
# sched_pixel 参数说明 (源码: cpufreq_gov.c):
#   response_time_ms: 越大 → 升频越慢 → 自然趴在低频
#   down_rate_limit_us: 由内核根据 response_time_ms 自动计算, 不可独立写入
# ============================================================

PROFILE="${1:-balanced}"
MODDIR="${2:-${0%/scripts/*}}"
GAME_TEMP_LIMIT=41000

CPU0="/sys/devices/system/cpu/cpu0/cpufreq"
CPU4="/sys/devices/system/cpu/cpu4/cpufreq"
CPU7="/sys/devices/system/cpu/cpu7/cpufreq"

write_if_exists() { [ -f "$1" ] && echo "$2" > "$1" 2>/dev/null; }
cpuset_write()    { [ -f "/dev/cpuset/$1/cpus" ] && echo "$2" > "/dev/cpuset/$1/cpus" 2>/dev/null; }

apply_sched_pixel() {
    # $1-3: response_time_ms  (小核 / 中核 / 大核)
    write_if_exists "$CPU0/sched_pixel/response_time_ms"   "$1"
    write_if_exists "$CPU4/sched_pixel/response_time_ms"   "$2"
    write_if_exists "$CPU7/sched_pixel/response_time_ms"   "$3"
}

get_skin_temp() {
    _cache="$MODDIR/.thermal_cache.json"
    if [ -s "$_cache" ]; then
        sed 's/.*VIRTUAL-SKIN","temp":\([0-9]*\).*/\1/' "$_cache" 2>/dev/null
    else
        dumpsys thermalservice 2>/dev/null | grep 'mName=VIRTUAL-SKIN,' | head -1 | sed 's/.*mValue=\([0-9.]*\).*/\1/' | awk '{printf "%d", $1*1000}'
    fi
}

case "$PROFILE" in

    game)
        # ── 游戏模式 ─────────────────────────────────────────
        # 温度门控: VIRTUAL-SKIN ≥ 41°C 时拒绝切换, 返回错误
        _skin=$(get_skin_temp)
        if [ -n "$_skin" ] && [ "$_skin" -ge "$GAME_TEMP_LIMIT" ] 2>/dev/null; then
            _t_c=$(awk "BEGIN{printf \"%.1f\", $_skin/1000}")
            log -t pixel9pro_ctrl "CPU: GAME blocked — VIRTUAL-SKIN ${_t_c}°C >= $(awk "BEGIN{printf \"%.0f\", $GAME_TEMP_LIMIT/1000}")°C"
            echo "BLOCKED:${_skin}"
            exit 1
        fi
        # top-app → 全核 0-7
        # 小核 8ms 全力, 中核 8ms, 大核 12ms (给 PID 控制器回旋余���, 避免 uclamp 激进降频)
        apply_sched_pixel 8 8 12
        cpuset_write "top-app"           "0-7"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: GAME [top-app→0-7, response 8/8/12ms, temp_gate=${_skin:-?}]"
        ;;

    balanced)
        # ── 平衡模式 ─────────────────────────────────────────
        # 保留 top-app 全核可调度，避免 steady-state 负载全挤到中核。
        # 相比 stock，适度加快中核响应，但明显放慢大核，优先让小/中核消化日常前台。
        apply_sched_pixel 16 40 160
        cpuset_write "top-app"           "0-7"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: BALANCED [top-app→0-7, response 16/40/160ms]"
        ;;

    light)
        # ── 轻度模式 ─────────────────────────────────────────
        # 面向阅读/社交/短视频这类长时间亮屏 steady-state 负载。
        # 让 top-app 停留在 0-6，直接避免 X4 常态介入；
        # 小核允许低频浮动，不再锁死 820MHz，减少“小核满载 + 中核补偿”的反效果。
        apply_sched_pixel 24 64 200
        cpuset_write "top-app"           "0-6"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: LIGHT [top-app→0-6, response 24/64/200ms]"
        ;;

    battery)
        # ── 省电模式 ─────────────────────────────────────────
        # 在 light 基础上进一步放慢小/中核升频，并继续禁用 X4。
        # 用于明确把长时间前台温度压下去，而不是追求交互峰值。
        apply_sched_pixel 32 96 200
        cpuset_write "top-app"           "0-6"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: BATTERY [top-app→0-6, response 32/96/200ms]"
        ;;

    stock)
        # ── Google 原版 ──────────────────────────────────────
        apply_sched_pixel 16 64 200
        cpuset_write "top-app"           "0-7"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: STOCK"
        ;;

    status)
        echo "=== CPU 频率 ==="
        for cpu in 0 4 7; do
            path="/sys/devices/system/cpu/cpu${cpu}/cpufreq"
            printf "cpu%d: cur=%s  min=%s  max=%s  gov=%s\n" \
                "$cpu" \
                "$(cat $path/scaling_cur_freq  2>/dev/null || echo N/A)" \
                "$(cat $path/scaling_min_freq  2>/dev/null || echo N/A)" \
                "$(cat $path/scaling_max_freq  2>/dev/null || echo N/A)" \
                "$(cat $path/scaling_governor  2>/dev/null || echo N/A)"
        done
        echo ""
        echo "=== sched_pixel 参数 ==="
        for cpu in 0 4 7; do
            path="/sys/devices/system/cpu/cpu${cpu}/cpufreq/sched_pixel"
            printf "cpu%d: response=%sms  down_rate=%sus\n" \
                "$cpu" \
                "$(cat $path/response_time_ms  2>/dev/null || echo N/A)" \
                "$(cat $path/down_rate_limit_us 2>/dev/null || echo N/A)"
        done
        echo ""
        echo "=== cpuset ==="
        for set in top-app foreground background system-background; do
            printf "%-18s %s\n" "$set" "$(cat /dev/cpuset/$set/cpus 2>/dev/null)"
        done
        echo ""
        echo "=== Thermal ==="
        dumpsys thermalservice 2>/dev/null | grep "Thermal Status:" | head -1
        ;;

    *)
        echo "Usage: $0 [game|balanced|light|battery|stock|status]"
        exit 1
        ;;
esac
