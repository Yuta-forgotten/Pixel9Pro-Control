#!/system/bin/sh
# ============================================================
# Pixel 9 Pro — Tensor G4 CPU 场景调度切换 v3.2.2
# 用法: sh cpu_profile.sh [game|balanced|light|battery|stock|status]
#
# 核心原理 (基于内核源码分析 + Sun_Dream 的方法):
#   - 不再写 scaling_max_freq / scaling_min_freq (会被 thermal HAL 覆盖)
#   - 通过 sched_pixel 参数控制频率行为, cpuset 路由 top-app/background
#   - 小核"锁最低频"通过 response_time=200ms+ 实现
#   - foreground cpuset 由 system_server 框架层管理, 固定为 0-6, 不可覆盖
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
        # ── 平衡模式 (Sun_Dream 思路) ────────────────────────
        # top-app(正在操作的App) → 中+大核 4-7
        # 小核 response_time=200ms → 锁死最低频 820MHz (即使foreground含小核也不会被调度)
        # 中核 12ms → 日常流畅, 大核 8ms → 重载响应
        apply_sched_pixel 200 12 8
        cpuset_write "top-app"           "4-7"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: BALANCED [top-app→4-7, 小核response 200ms锁最低频]"
        ;;

    light)
        # ── 轻度模式 ─────────────────────────────────────────
        # cpuset 同平衡模式, 但中大核升频更保守
        # 小核 200ms 锁最低频, 中核 20ms, 大核 16ms
        # 适合长时间亮屏轻度使用 (阅读/社交/视频)
        apply_sched_pixel 200 20 16
        cpuset_write "top-app"           "4-7"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: LIGHT [top-app→4-7, 小核response 200ms锁最低频, 中核20ms, 大核16ms]"
        ;;

    battery)
        # ── 省电模式 ─────────────────────────────────────────
        # 小核: response_time=500ms, 完全锁最低频 820MHz
        # 中核: response_time=40ms, 保守升频
        # 大核: response_time=30ms, 保守升频
        apply_sched_pixel 500 40 30
        cpuset_write "top-app"           "4-7"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: BATTERY [top-app→4-7, 小核500ms锁最低频]"
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
