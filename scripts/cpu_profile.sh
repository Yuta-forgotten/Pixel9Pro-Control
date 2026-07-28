#!/system/bin/sh
# Pixel 9 Pro Tensor G4 CPU profile application.
# 用法: sh cpu_profile.sh [performance|balanced|battery|default|status|verify|enforce] [MODDIR] [force]
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
#   performance/default=1024 放开 boost; balanced/battery=0 抑制 per-task boost。
#
# verify/enforce 子命令均为只读验证。v4.5.03 起不再周期性写回
# vendor_sched；漂移由独立低频 health probe 报告，只有明确的新事务才写。
PROFILE="${1:-default}"
SCRIPT_DIR="${0%/*}"
MODDIR="${2:-${SCRIPT_DIR%/scripts}}"
FORCE_APPLY="${3:-}"

CPU_PROFILE_LIB="$MODDIR/scripts/cpu_profile_lib.sh"
if [ ! -r "$CPU_PROFILE_LIB" ] || ! . "$CPU_PROFILE_LIB"; then
    echo "cpu_profile: missing CPU profile contract" >&2
    exit 2
fi

CPU0="${CPU_PROFILE_CPU0_ROOT:-/sys/devices/system/cpu/cpu0/cpufreq}"
CPU4="${CPU_PROFILE_CPU4_ROOT:-/sys/devices/system/cpu/cpu4/cpufreq}"
CPU7="${CPU_PROFILE_CPU7_ROOT:-/sys/devices/system/cpu/cpu7/cpufreq}"
CPUSET_ROOT="${CPU_PROFILE_CPUSET_ROOT:-/dev/cpuset}"
VENDOR_SCHED="${CPU_PROFILE_VENDOR_SCHED_ROOT:-/proc/vendor_sched}"
UCLAMP_CAP_MIN="${CPU_PROFILE_UCLAMP_PATH:-/proc/sys/kernel/sched_util_clamp_min}"
SCHED_OWNER_FILE="$MODDIR/.cpu_sched_owner"

if [ "${CPU_PROFILE_TEST_MODE:-0}" = "1" ]; then
    case "$CPU0:$CPU4:$CPU7:$CPUSET_ROOT:$VENDOR_SCHED:$UCLAMP_CAP_MIN" in
        /sdcard/Download/Pixel9Pro-Control-TestLab/runtime/*|/tmp/pixel9pro_* ) ;;
        *) echo "cpu_profile: unsafe test fixture paths" >&2; exit 64 ;;
    esac
fi

write_required_value() {
    [ -e "$1" ] || return 1
    if [ "${CPU_PROFILE_TEST_MODE:-0}" = "1" ] \
        && [ -n "${CPU_PROFILE_FAIL_ONCE_PATH:-}" ] \
        && [ "$1" = "$CPU_PROFILE_FAIL_ONCE_PATH" ] \
        && [ -f "${CPU_PROFILE_FAIL_ONCE_MARKER:-}" ]; then
        rm -f "$CPU_PROFILE_FAIL_ONCE_MARKER" 2>/dev/null
        return 1
    fi
    printf '%s\n' "$2" > "$1" 2>/dev/null || return 1
    _cpu_written=$(cat "$1" 2>/dev/null | tr -d ' \n\r\t')
    [ "$_cpu_written" = "$2" ]
}

write_if_exists() {
    [ -e "$1" ] || return 0
    write_required_value "$1" "$2"
}
cpuset_write() {
    write_required_value "$CPUSET_ROOT/$1/cpus" "$2"
}

apply_profile_l2() {
    _cpu_l2=$(cpu_profile_l2_params "$1") || return 1
    set -- $_cpu_l2
    [ "$#" -eq 2 ] || return 1
    write_required_value "$VENDOR_SCHED/ug_bg_uclamp_max" "$1" \
        && write_required_value "$VENDOR_SCHED/ug_bg_group_throttle" "$2"
}

# 系统默认档专用: 从只读 response_time_ms_nom 读取出厂节奏，再写入可调
# response_time_ms；不会尝试写 nominal 节点。
# 设备实测(2026-06-16 caiman): nom 为只读常量 (-r--r--r--) 9/52/165; 新切 sched_pixel 时
#   response_time_ms 即等于 nom, 故 nom 就是出厂节奏; 原厂 init 全程不写 response_time_ms。
# 读不到 nom(非 sched_pixel governor, 如 UGT 切 powersave)时**跳过写入** —— 此时
#   response_time_ms 节点本就不存在、写入是 no-op, 不写任何硬编码猜测值(不再"想当然硬编码默认")。
apply_one_nominal() {
    # $1: cpufreq 目录
    _nom=$(cat "$1/sched_pixel/response_time_ms_nom" 2>/dev/null | tr -d ' \n\r\t')
    case "$_nom" in
        ''|*[!0-9]*) return 0 ;;
    esac
    write_if_exists "$1/sched_pixel/response_time_ms" "$_nom"
}
apply_sched_pixel_nominal() {
    apply_one_nominal "$CPU0" \
        && apply_one_nominal "$CPU4" \
        && apply_one_nominal "$CPU7"
}

read_sched_owner() {
    _owner=$(cat "$SCHED_OWNER_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_owner" in
        external) printf 'external' ;;
        *)        printf 'pixel' ;;
    esac
}

apply_sched_pixel() {
    # $1-3: response_time_ms  (小核 / 中核 / 大核)
    write_required_value "$CPU0/sched_pixel/response_time_ms" "$1" \
        && write_required_value "$CPU4/sched_pixel/response_time_ms" "$2" \
        && write_required_value "$CPU7/sched_pixel/response_time_ms" "$3"
}

apply_uclamp_cap() {
    # $1: sched_util_clamp_min — uclamp.min 系统级上限(cap)。
    #   performance/系统默认(default)=1024 (出厂上限, 放开 ADPF/HBoost/fork/ExoPlayer 动态 boost);
    #   balanced/battery=0 (抑制走 per-task 请求路径的 boost, 省电)。出厂默认=1024。
    #   volatile, 不被 PowerHAL/Thermal 覆盖 (无需 enforce 守护)。
    write_required_value "$UCLAMP_CAP_MIN" "$1"
}

apply_profile_cpus() {
    _cpu_top=$(cpu_profile_top_app_cpus "$1") || return 1
    cpuset_write "top-app" "$_cpu_top" \
        && cpuset_write "foreground" "$CPU_PROFILE_FOREGROUND_CPUS" \
        && cpuset_write "background" "$CPU_PROFILE_BACKGROUND_CPUS" \
        && cpuset_write "system-background" "$CPU_PROFILE_BACKGROUND_CPUS"
}

apply_static_profile_contract() {
    _cpu_profile="$1"
    _cpu_response=$(cpu_profile_response_triplet "$_cpu_profile") || return 1
    _cpu_cap=$(cpu_profile_uclamp_cap "$_cpu_profile") || return 1
    set -- $_cpu_response
    [ "$#" -eq 3 ] || return 1
    apply_sched_pixel "$1" "$2" "$3" \
        && apply_uclamp_cap "$_cpu_cap" \
        && apply_profile_cpus "$_cpu_profile" \
        && apply_profile_l2 "$_cpu_profile"
}

snapshot_cpu_runtime() {
    _cpu_resp0_path="$CPU0/sched_pixel/response_time_ms"
    _cpu_resp4_path="$CPU4/sched_pixel/response_time_ms"
    _cpu_resp7_path="$CPU7/sched_pixel/response_time_ms"
    _cpu_resp0_existed=0; [ -e "$_cpu_resp0_path" ] && _cpu_resp0_existed=1
    _cpu_resp4_existed=0; [ -e "$_cpu_resp4_path" ] && _cpu_resp4_existed=1
    _cpu_resp7_existed=0; [ -e "$_cpu_resp7_path" ] && _cpu_resp7_existed=1
    _cpu_old_resp0=$(cat "$_cpu_resp0_path" 2>/dev/null | tr -d ' \n\r\t')
    _cpu_old_resp4=$(cat "$_cpu_resp4_path" 2>/dev/null | tr -d ' \n\r\t')
    _cpu_old_resp7=$(cat "$_cpu_resp7_path" 2>/dev/null | tr -d ' \n\r\t')
    _cpu_old_cap=$(cat "$UCLAMP_CAP_MIN" 2>/dev/null | tr -d ' \n\r\t')
    _cpu_old_top=$(cat "$CPUSET_ROOT/top-app/cpus" 2>/dev/null | tr -d ' \n\r\t')
    _cpu_old_fg=$(cat "$CPUSET_ROOT/foreground/cpus" 2>/dev/null | tr -d ' \n\r\t')
    _cpu_old_bg=$(cat "$CPUSET_ROOT/background/cpus" 2>/dev/null | tr -d ' \n\r\t')
    _cpu_old_sysbg=$(cat "$CPUSET_ROOT/system-background/cpus" 2>/dev/null | tr -d ' \n\r\t')
    _cpu_old_bg_uclamp=$(cat "$VENDOR_SCHED/ug_bg_uclamp_max" 2>/dev/null | tr -d ' \n\r\t')
    _cpu_old_bg_throttle=$(cat "$VENDOR_SCHED/ug_bg_group_throttle" 2>/dev/null | tr -d ' \n\r\t')
    { [ "$_cpu_resp0_existed" -eq 0 ] || [ -n "$_cpu_old_resp0" ]; } \
        && { [ "$_cpu_resp4_existed" -eq 0 ] || [ -n "$_cpu_old_resp4" ]; } \
        && { [ "$_cpu_resp7_existed" -eq 0 ] || [ -n "$_cpu_old_resp7" ]; } \
        && [ -n "$_cpu_old_cap" ] && [ -n "$_cpu_old_top" ] \
        && [ -n "$_cpu_old_fg" ] && [ -n "$_cpu_old_bg" ] \
        && [ -n "$_cpu_old_sysbg" ] && [ -n "$_cpu_old_bg_uclamp" ] \
        && [ -n "$_cpu_old_bg_throttle" ]
}

restore_cpu_runtime() {
    _cpu_restore_failed=0
    [ "$_cpu_resp0_existed" -eq 0 ] || write_required_value "$_cpu_resp0_path" "$_cpu_old_resp0" || _cpu_restore_failed=1
    [ "$_cpu_resp4_existed" -eq 0 ] || write_required_value "$_cpu_resp4_path" "$_cpu_old_resp4" || _cpu_restore_failed=1
    [ "$_cpu_resp7_existed" -eq 0 ] || write_required_value "$_cpu_resp7_path" "$_cpu_old_resp7" || _cpu_restore_failed=1
    write_required_value "$UCLAMP_CAP_MIN" "$_cpu_old_cap" || _cpu_restore_failed=1
    cpuset_write top-app "$_cpu_old_top" || _cpu_restore_failed=1
    cpuset_write foreground "$_cpu_old_fg" || _cpu_restore_failed=1
    cpuset_write background "$_cpu_old_bg" || _cpu_restore_failed=1
    cpuset_write system-background "$_cpu_old_sysbg" || _cpu_restore_failed=1
    write_required_value "$VENDOR_SCHED/ug_bg_uclamp_max" "$_cpu_old_bg_uclamp" || _cpu_restore_failed=1
    write_required_value "$VENDOR_SCHED/ug_bg_group_throttle" "$_cpu_old_bg_throttle" || _cpu_restore_failed=1
    [ "$_cpu_restore_failed" -eq 0 ]
}

verify_profile_runtime() {
    _cpu_verify_profile="$1"
    _cpu_expected_cap=$(cpu_profile_uclamp_cap "$_cpu_verify_profile") || return 1
    _cpu_expected_top=$(cpu_profile_top_app_cpus "$_cpu_verify_profile") || return 1
    _cpu_expected_l2=$(cpu_profile_l2_params "$_cpu_verify_profile") || return 1
    [ "$(cat "$UCLAMP_CAP_MIN" 2>/dev/null | tr -d ' \n\r\t')" = "$_cpu_expected_cap" ] || return 1
    [ "$(cat "$CPUSET_ROOT/top-app/cpus" 2>/dev/null | tr -d ' \n\r\t')" = "$_cpu_expected_top" ] || return 1
    [ "$(cat "$CPUSET_ROOT/foreground/cpus" 2>/dev/null | tr -d ' \n\r\t')" = "$CPU_PROFILE_FOREGROUND_CPUS" ] || return 1
    [ "$(cat "$CPUSET_ROOT/background/cpus" 2>/dev/null | tr -d ' \n\r\t')" = "$CPU_PROFILE_BACKGROUND_CPUS" ] || return 1
    [ "$(cat "$CPUSET_ROOT/system-background/cpus" 2>/dev/null | tr -d ' \n\r\t')" = "$CPU_PROFILE_BACKGROUND_CPUS" ] || return 1
    set -- $_cpu_expected_l2
    [ "$(cat "$VENDOR_SCHED/ug_bg_uclamp_max" 2>/dev/null | tr -d ' \n\r\t')" = "$1" ] || return 1
    [ "$(cat "$VENDOR_SCHED/ug_bg_group_throttle" 2>/dev/null | tr -d ' \n\r\t')" = "$2" ] || return 1

    _cpu_expected_response=$(cpu_profile_response_triplet "$_cpu_verify_profile") || return 1
    if [ -n "$_cpu_expected_response" ]; then
        set -- $_cpu_expected_response
        for _cpu_verify_root in "$CPU0" "$CPU4" "$CPU7"; do
            [ "$(cat "$_cpu_verify_root/sched_pixel/response_time_ms" 2>/dev/null | tr -d ' \n\r\t')" = "$1" ] || return 1
            shift
        done
    else
        for _cpu_verify_root in "$CPU0" "$CPU4" "$CPU7"; do
            _cpu_verify_nom=$(cat "$_cpu_verify_root/sched_pixel/response_time_ms_nom" 2>/dev/null | tr -d ' \n\r\t')
            [ -n "$_cpu_verify_nom" ] || return 1
            [ "$(cat "$_cpu_verify_root/sched_pixel/response_time_ms" 2>/dev/null | tr -d ' \n\r\t')" = "$_cpu_verify_nom" ] || return 1
        done
    fi
    return 0
}

profile_apply_failed() {
    if restore_cpu_runtime; then
        log -t pixel9pro_ctrl "ERROR: CPU profile apply failed and runtime was restored: $PROFILE"
        echo "FAILED_ROLLED_BACK:$PROFILE"
        exit 3
    fi
    log -t pixel9pro_ctrl "ERROR: CPU profile apply failed and rollback was incomplete: $PROFILE"
    echo "FAILED_ROLLBACK_INCOMPLETE:$PROFILE"
    exit 4
}

SCHED_OWNER=$(read_sched_owner)
if [ "$SCHED_OWNER" = "external" ]; then
    case "$PROFILE" in
        status|verify|enforce) ;;
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
    performance|balanced|battery|default)
        snapshot_cpu_runtime || {
            log -t pixel9pro_ctrl "ERROR: cannot snapshot CPU runtime before applying $PROFILE"
            echo "FAILED_SNAPSHOT:$PROFILE"
            exit 3
        }
        ;;
esac

case "$PROFILE" in

    performance)
        # Internal/CLI baseline only; WebUI and auto policy do not enter it.
        # Full cap restores ADPF/HBoost requests. response_time_ms changes ramp
        # timing but does not by itself force X4 participation.
        apply_static_profile_contract performance || profile_apply_failed
        verify_profile_runtime performance || profile_apply_failed
        log -t pixel9pro_ctrl "CPU: PERFORMANCE [cap=$CPU_PROFILE_FULL_CAP, response $(cpu_profile_response_triplet performance)ms]"
        ;;

    balanced)
        # Daily low-heat baseline: all CPUs remain eligible for top-app, while
        # the middle/prime clusters ramp later and per-task boost is capped.
        apply_static_profile_contract balanced || profile_apply_failed
        verify_profile_runtime balanced || profile_apply_failed
        log -t pixel9pro_ctrl "CPU: BALANCED [top-app=$(cpu_profile_top_app_cpus balanced), response $(cpu_profile_response_triplet balanced)ms]"
        ;;

    battery)
        apply_static_profile_contract battery || profile_apply_failed
        verify_profile_runtime battery || profile_apply_failed
        log -t pixel9pro_ctrl "CPU: BATTERY [top-app=$(cpu_profile_top_app_cpus battery), response $(cpu_profile_response_triplet battery)ms]"
        ;;

    default)
        # Stock response is read from the kernel's read-only nominal nodes; it
        # is deliberately not copied into the shared tuned-value contract.
        # cap=1024 is SCHED_CAPACITY_SCALE, while cpusets match factory init.
        apply_sched_pixel_nominal || profile_apply_failed
        apply_uclamp_cap "$(cpu_profile_uclamp_cap default)" || profile_apply_failed
        apply_profile_cpus default || profile_apply_failed
        apply_profile_l2 default || profile_apply_failed
        verify_profile_runtime default || profile_apply_failed
        log -t pixel9pro_ctrl "CPU: DEFAULT (system stock: response=nom, cap=$CPU_PROFILE_FULL_CAP)"
        ;;

    verify|enforce)
        _cpu_verify_target="${CPU_PROFILE_VERIFY_TARGET:-}"
        [ -n "$_cpu_verify_target" ] \
            || _cpu_verify_target=$(cat "$MODDIR/.current_profile" 2>/dev/null | tr -d ' \n\r\t')
        _cpu_verify_target=$(cpu_profile_normalize_runtime "$_cpu_verify_target" balanced)
        if verify_profile_runtime "$_cpu_verify_target"; then
            printf 'VERIFIED:%s\n' "$_cpu_verify_target"
            exit 0
        fi
        printf 'DRIFT:%s\n' "$_cpu_verify_target"
        exit 5
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
                "$(cat "$path/scaling_cur_freq"  2>/dev/null || echo N/A)" \
                "$(cat "$path/scaling_min_freq"  2>/dev/null || echo N/A)" \
                "$(cat "$path/scaling_max_freq"  2>/dev/null || echo N/A)" \
                "$(cat "$path/scaling_governor"  2>/dev/null || echo N/A)"
        done
        echo ""
        echo "=== sched_pixel 参数 ==="
        for cpu in 0 4 7; do
            path="/sys/devices/system/cpu/cpu${cpu}/cpufreq/sched_pixel"
            printf "cpu%d: response=%sms  down_rate=%sus\n" \
                "$cpu" \
                "$(cat "$path/response_time_ms"  2>/dev/null || echo N/A)" \
                "$(cat "$path/down_rate_limit_us" 2>/dev/null || echo N/A)"
        done
        echo ""
        echo "=== uclamp cap ==="
        printf "sched_util_clamp_min=%s  (performance/default=%s / balanced/battery=%s)\n" \
            "$(cat $UCLAMP_CAP_MIN 2>/dev/null || echo N/A)" \
            "$CPU_PROFILE_FULL_CAP" "$CPU_PROFILE_ECO_CAP"
        echo ""
        echo "=== cpuset ==="
        for set in top-app foreground background system-background; do
            printf "%-18s %s\n" "$set" "$(cat "$CPUSET_ROOT/$set/cpus" 2>/dev/null)"
        done
        echo ""
        echo "=== Thermal ==="
        dumpsys thermalservice 2>/dev/null | grep "Thermal Status:" | head -1
        ;;

    *)
        echo "Usage: $0 [performance|balanced|battery|default|status|verify|enforce]"
        exit 1
        ;;
esac
