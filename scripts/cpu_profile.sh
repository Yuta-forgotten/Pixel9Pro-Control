#!/system/bin/sh
# ============================================================
# Pixel 9 Pro — Tensor G4 CPU 场景调度切换 v4.3.21
# 用法: sh cpu_profile.sh [responsive|balanced|battery|default|status]
#
# 核心原理:
#   - 不再写 scaling_max_freq / scaling_min_freq (会被 thermal HAL 覆盖)
#   - 通过 sched_pixel 参数控制频率行为, cpuset 路由 top-app/background
#   - foreground cpuset 由 system_server 框架层管理, 固定为 0-6, 不可覆盖
#   - 当前目标不是“造一个极限性能模式”，而是把不同前台场景拉开成更清晰的可感知方案
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

PROFILE="${1:-default}"
MODDIR="${2:-${0%/scripts/*}}"

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

case "$PROFILE" in

    responsive)
        # ── 响应优先 ─────────────────────────────────────────
        apply_sched_pixel 12 20 80
        cpuset_write “top-app”           “0-7”
        cpuset_write “foreground”        “0-6”
        cpuset_write “background”        “0-3”
        cpuset_write “system-background” “0-3”
        log -t pixel9pro_ctrl “CPU: RESPONSIVE [top-app→0-7, response 12/20/80ms]”
        ;;

    balanced)
        # ── 均衡模式 ─────────────────────────────────────────
        # 小核 16ms 保持 955-1197MHz 高效区间, 中核 24ms 比 stock 更积极补位
        # X4 以 160ms 做突发吸收器, 不常态介入
        apply_sched_pixel 16 24 160
        cpuset_write "top-app"           "0-7"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: BALANCED [top-app→0-7, response 16/24/160ms]"
        ;;

    battery)
        # ── 省电模式 ─────────────────────────────────────────
        apply_sched_pixel 32 96 200
        cpuset_write "top-app"           "0-6"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: BATTERY [top-app→0-6, response 32/96/200ms]"
        ;;

    default)
        # ── 默认模式 / 自动默认底座 ─────────────────────────
        apply_sched_pixel 16 64 200
        cpuset_write "top-app"           "0-7"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: DEFAULT"
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
        echo "Usage: $0 [responsive|balanced|battery|default|status]"
        exit 1
        ;;
esac
