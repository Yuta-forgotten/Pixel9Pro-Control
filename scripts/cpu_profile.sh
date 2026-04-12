#!/system/bin/sh
# ============================================================
# Pixel 9 Pro — Tensor G4 CPU 场景调度切换
# 用法: sh cpu_profile.sh [game|balanced|battery|status]
#
# Tensor G4 拓扑：
#   cpu0-3  Cortex-A520 (小核)  OPP 上限 1950 MHz
#   cpu4-6  Cortex-A720 (中核)  OPP 上限 2600 MHz
#   cpu7    Cortex-X4   (大核)  OPP 上限 3105 MHz
#
# 【注意】只能在 boot_completed=1 之后调用
# 不写 min_freq，避免 ACPM 冷启动保护
# ============================================================

PROFILE="${1:-balanced}"

CPU0="/sys/devices/system/cpu/cpu0/cpufreq"
CPU4="/sys/devices/system/cpu/cpu4/cpufreq"
CPU7="/sys/devices/system/cpu/cpu7/cpufreq"

write_if_exists() { [ -f "$1" ] && echo "$2" > "$1" 2>/dev/null; }
cpuset_write()    { [ -f "/dev/cpuset/$1/cpus" ] && echo "$2" > "/dev/cpuset/$1/cpus" 2>/dev/null; }

apply_params() {
    # $1-3: response_time_ms  (小核 / 中核 / 大核)
    # $4-6: down_rate_limit_us (小核 / 中核 / 大核)
    write_if_exists "$CPU0/sched_pixel/response_time_ms"   "$1"
    write_if_exists "$CPU4/sched_pixel/response_time_ms"   "$2"
    write_if_exists "$CPU7/sched_pixel/response_time_ms"   "$3"
    write_if_exists "$CPU0/sched_pixel/down_rate_limit_us" "$4"
    write_if_exists "$CPU4/sched_pixel/down_rate_limit_us" "$5"
    write_if_exists "$CPU7/sched_pixel/down_rate_limit_us" "$6"
}

case "$PROFILE" in

    game)
        # ── 游戏模式 ─────────────────────────────────────────
        # 全核解锁：小核≤1950 / 中核≤2600 / 大核≤3105 MHz
        # 升频极灵敏，帧率优先，所有线程均可调度到任意核心
        apply_params 11 54 175  500 500 500
        write_if_exists "$CPU0/scaling_max_freq" "9999999"   # 小核 → OPP 上限 1950 MHz
        write_if_exists "$CPU4/scaling_max_freq" "9999999"   # 中核 → OPP 上限 2600 MHz
        write_if_exists "$CPU7/scaling_max_freq" "9999999"   # 大核 → OPP 上限 3105 MHz
        cpuset_write "top-app"           "0-7"  # 全核可用
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU profile: GAME  [小核≤1950 / 中核≤2600 / 大核≤3105 MHz]"
        ;;

    balanced)
        # ── 平衡模式 ─────────────────────────────────────────
        # 小核限速 1548 MHz，中大核全速
        # 前台 App (top-app) 独享 cpu4-7，后台任务限在小核
        # foreground 覆盖 cpu0-6，保证前台服务线程仍有中核可用
        apply_params 15 65 185  2000 3000 3000
        write_if_exists "$CPU0/scaling_max_freq" "1548000"   # 小核上限 1548 MHz
        write_if_exists "$CPU4/scaling_max_freq" "9999999"   # 中核全速
        write_if_exists "$CPU7/scaling_max_freq" "9999999"   # 大核全速
        cpuset_write "top-app"           "4-7"  # 前台 App 独享中大核
        cpuset_write "foreground"        "0-6"  # 前台服务可用小核+中核
        cpuset_write "background"        "0-3"  # 后台任务限小核
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU profile: BALANCED  [小核≤1548 / 中核≤2600 / 大核≤3105 MHz]"
        ;;

    battery)
        # ── 省电模式 ─────────────────────────────────────────
        # 三簇均限频，显著降低峰值功耗
        # 小核≤1200 / 中核≤1795 / 大核≤1885 MHz
        # X4 大核从 3105→1885 MHz，省去约 40% 的大核峰值功耗
        # down_rate_limit 偏小：负载下降时快速回落，减少无效功耗
        apply_params 20 80 200  500 800 1000
        write_if_exists "$CPU0/scaling_max_freq" "1200000"   # 小核上限 1200 MHz
        write_if_exists "$CPU4/scaling_max_freq" "1795000"   # 中核上限 1795 MHz
        write_if_exists "$CPU7/scaling_max_freq" "1885000"   # 大核上限 1885 MHz
        cpuset_write "top-app"           "4-7"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU profile: BATTERY  [小核≤1200 / 中核≤1795 / 大核≤1885 MHz]"
        ;;

    stock)
        # ── Google 原版调度 ───────────────────────────────────
        # 移除所有频率上限，恢复 Android 默认 cpuset 分配
        apply_params 16 64 200  1000 2000 3000
        write_if_exists "$CPU0/scaling_max_freq" "9999999"
        write_if_exists "$CPU4/scaling_max_freq" "9999999"
        write_if_exists "$CPU7/scaling_max_freq" "9999999"
        cpuset_write "top-app"           "0-7"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU profile: STOCK  [恢复系统默认，频率不限]"
        ;;

    status)
        # ── 调试子命令（WebUI 不调用，仅用于 adb shell 排查）────
        echo "=== CPU 当前状态 ==="
        for cpu in 0 4 7; do
            path="/sys/devices/system/cpu/cpu${cpu}/cpufreq"
            printf "cpu%d: cur=%s  min=%s  max=%s  gov=%s\n" \
                "$cpu" \
                "$(cat $path/scaling_cur_freq  2>/dev/null || echo N/A)" \
                "$(cat $path/scaling_min_freq  2>/dev/null || echo N/A)" \
                "$(cat $path/scaling_max_freq  2>/dev/null || echo N/A)" \
                "$(cat $path/scaling_governor  2>/dev/null || echo N/A)"
        done
        ;;

    *)
        echo "Usage: $0 [game|balanced|battery|status]"
        exit 1
        ;;
esac
