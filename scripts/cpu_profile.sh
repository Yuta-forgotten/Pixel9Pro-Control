#!/system/bin/sh
# ============================================================
# Pixel 9 Pro — Tensor G4 CPU 场景调度切换 v4.4.0
# 用法: sh cpu_profile.sh [performance|balanced|battery|default|status|enforce] [MODDIR] [force]
#
# 核心原理:
#   - 不写 scaling_max_freq / scaling_min_freq (会被 thermal HAL 覆盖)
#   - 通过 sched_pixel response_time_ms 控制升频节奏, cpuset 路由 top-app/background
#   - performance 档额外把 sched_util_clamp_min 0→1024, 还 Google 出厂 uclamp.min 上限,
#     放开 ADPF/HBoost/fork/ExoPlayer 等内核动态 boost (顺内核"还闸", 非用户态"抢闸")
#   - 不写 vendor ug_fg_uclamp_min (实测在 per-task effmin 不可见、不可验证, 见 01_cpu)
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
#
# sched_util_clamp_min (Linux 5.x mainline, /proc/sys/kernel/):
#   它是 uclamp.min 的"系统级上限(cap)" — 限制任务可请求的最大 uclamp.min,
#   不是"给任务发 util 信号"(内核文档 sched-util-clamp)。出厂 1024。
#   performance=1024 放开 boost; 其它档=0 抑制走 per-task 请求路径的 boost。
#
# enforce 子命令:
#   校验 vendor_sched 参数是否被 PowerHAL hint 覆盖, 仅在偏差时写回
#   只做 procfs 读写 (cat + echo), 零 IPC, 零 wakelock
#   亮屏时由 worker 每 15s 调用一次, 参数正确时无输出无日志
# ============================================================

PROFILE="${1:-default}"
MODDIR="${2:-${0%/scripts/*}}"
FORCE_APPLY="${3:-}"

CPU0="/sys/devices/system/cpu/cpu0/cpufreq"
CPU4="/sys/devices/system/cpu/cpu4/cpufreq"
CPU7="/sys/devices/system/cpu/cpu7/cpufreq"
VENDOR_SCHED="/proc/vendor_sched"
UCLAMP_CAP_MIN="/proc/sys/kernel/sched_util_clamp_min"
POWER_PROFILE_FILE="$MODDIR/.power_profile"
SCHED_OWNER_FILE="$MODDIR/.cpu_sched_owner"

write_if_exists() { [ -f "$1" ] && echo "$2" > "$1" 2>/dev/null; }
cpuset_write()    { [ -f "/dev/cpuset/$1/cpus" ] && echo "$2" > "/dev/cpuset/$1/cpus" 2>/dev/null; }

read_sched_owner() {
    _owner=$(cat "$SCHED_OWNER_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_owner" in
        external) printf 'external' ;;
        *)        printf 'pixel' ;;
    esac
}

apply_sched_pixel() {
    # $1-3: response_time_ms  (小核 / 中核 / 大核)
    write_if_exists "$CPU0/sched_pixel/response_time_ms"   "$1"
    write_if_exists "$CPU4/sched_pixel/response_time_ms"   "$2"
    write_if_exists "$CPU7/sched_pixel/response_time_ms"   "$3"
}

apply_uclamp_cap() {
    # $1: sched_util_clamp_min — uclamp.min 系统级上限(cap)。
    #   performance=1024 还 Google 出厂上限放开动态 boost; 其它档=0。
    #   volatile, 不被 PowerHAL/Thermal 覆盖 (无需 enforce 守护)。
    write_if_exists "$UCLAMP_CAP_MIN" "$1"
}

SCHED_OWNER=$(read_sched_owner)
if [ "$SCHED_OWNER" = "external" ]; then
    case "$PROFILE" in
        status) ;;
        *)
            if [ "$FORCE_APPLY" != "force" ]; then
                log -t pixel9pro_ctrl "CPU: skip $PROFILE, scheduler owner=external"
                exit 0
            fi
            log -t pixel9pro_ctrl "CPU: force apply $PROFILE while scheduler owner=external"
            ;;
    esac
fi

case "$PROFILE" in

    performance)
        # [v4.4.11] 已退出 WebUI 用户档: 面板仅余 balanced/battery, 更强性能改由 UPG 外部调度接管。
        #   本段保留仅作 force/CLI 内部基线, 自动策略永不进入。
        # ── 性能优先 (顺内核还闸) ─────────────────────────────
        # 核心: sched_util_clamp_min 0→1024, 还 Google 出厂 uclamp.min 上限,
        #   放开 ADPF/HBoost/fork/ExoPlayer 等内核动态 boost (都走 uclamp.min 路径)。
        # response 12/20/80: 中大核更早补位; X4 是否上场仍由 PowerHAL HBoost/EAS 决定,
        #   不由 response_time_ms 主导 (logs/2026-04-26_dex2oat_responsive_x4_analysis.txt)。
        # 手动专用, 自动策略禁止进入 (见 service.sh slow auto policy)。
        # 发热提示: 放开 boost 后温升更快, 自动温控收口只在 balanced↔battery 生效。
        apply_sched_pixel 12 20 80
        apply_uclamp_cap 1024
        cpuset_write "top-app"           "0-7"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: PERFORMANCE [cap=1024, response 12/20/80ms]"
        ;;

    balanced)
        # ── 均衡模式 ─────────────────────────────────────────
        # v4.4.4 低热日用底座:
        # 小核 16ms 保持高效区间, 避免旧 light 的低频高占用。
        # 中核 40ms 介于旧 balanced(24ms) 与 default(64ms) 之间, 减少视频/feed 稳态补偿升频。
        # X4 200ms 作为更晚的 burst 兜底, 不做持续负载主力。cap=0 (省电基线, 非性能档)。
        apply_sched_pixel 16 40 200
        apply_uclamp_cap 0
        cpuset_write "top-app"           "0-7"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: BALANCED [top-app→0-7, response 16/40/200ms]"
        ;;

    battery)
        # ── 省电模式 ─────────────────────────────────────────
        apply_sched_pixel 32 96 200
        apply_uclamp_cap 0
        cpuset_write "top-app"           "0-6"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: BATTERY [top-app→0-6, response 32/96/200ms]"
        ;;

    default)
        # [v4.4.11] 已退出 WebUI 用户档: 仅作开机/CLI 内部安全基线 (WebUI 与自动策略不再选用)。
        # ── 默认模式 / 自动默认底座 ─────────────────────────
        apply_sched_pixel 16 64 200
        apply_uclamp_cap 0
        cpuset_write "top-app"           "0-7"
        cpuset_write "foreground"        "0-6"
        cpuset_write "background"        "0-3"
        cpuset_write "system-background" "0-3"
        log -t pixel9pro_ctrl "CPU: DEFAULT"
        ;;

    status)
        echo "=== 调度所有权 ==="
        printf "cpu_sched_owner=%s  (pixel=本模块 / external=外部模块接管)\n" "$SCHED_OWNER"
        echo ""
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
        echo "=== uclamp cap ==="
        printf "sched_util_clamp_min=%s  (performance=1024 / 其它=0)\n" \
            "$(cat $UCLAMP_CAP_MIN 2>/dev/null || echo N/A)"
        echo ""
        echo "=== cpuset ==="
        for set in top-app foreground background system-background; do
            printf "%-18s %s\n" "$set" "$(cat /dev/cpuset/$set/cpus 2>/dev/null)"
        done
        echo ""
        echo "=== Thermal ==="
        dumpsys thermalservice 2>/dev/null | grep "Thermal Status:" | head -1
        ;;

    enforce)
        # ── vendor_sched 参数守护 ───────────────────────────────
        # 只做 procfs 读写, 参数正确时零开销
        # 注: sched_util_clamp_min 不被 PowerHAL 覆盖, 不在此守护 (由各档切换时管理)
        _pp=$(cat "$POWER_PROFILE_FILE" 2>/dev/null | tr -d ' \n\r')
        case "$_pp" in
            battery) _target_bg_uclamp=150; _target_bg_throttle=80 ;;
            *)       _target_bg_uclamp=200; _target_bg_throttle=100 ;;
        esac
        _cur_uclamp=$(cat "$VENDOR_SCHED/ug_bg_uclamp_max" 2>/dev/null | tr -d ' \n\r')
        _cur_throttle=$(cat "$VENDOR_SCHED/ug_bg_group_throttle" 2>/dev/null | tr -d ' \n\r')
        _fixed=0
        if [ "$_cur_uclamp" != "$_target_bg_uclamp" ]; then
            echo "$_target_bg_uclamp" > "$VENDOR_SCHED/ug_bg_uclamp_max" 2>/dev/null
            _fixed=1
        fi
        if [ "$_cur_throttle" != "$_target_bg_throttle" ]; then
            echo "$_target_bg_throttle" > "$VENDOR_SCHED/ug_bg_group_throttle" 2>/dev/null
            _fixed=1
        fi
        [ "$_fixed" -eq 1 ] && log -t pixel9pro_ctrl "L2 enforce: restored bg_uclamp=$_target_bg_uclamp bg_throttle=$_target_bg_throttle"
        ;;

    *)
        echo "Usage: $0 [performance|balanced|battery|default|status|enforce]"
        exit 1
        ;;
esac
