#!/system/bin/sh
##############################################################
# service.sh v4.4.9 — 开机服务 (Doze 友好后台 + M3 WebUI)
# 执行时机：late_start（约启动后 8s），以 root 运行
# 流程: 等待启动 → 系统设置优化 → 内核参数 → 三层功耗优化 → CPU配置 → 统一后台 → WebUI
#
# v4.4.9 变更:
#   - WebUI 首次写操作通过 auth.sh 预填 token prompt, 按前辈要求优先易用性。
#   - standby_guard.sh 避免诊断文件同名变量覆盖真实 idle_isolate_mode。
#   - bg_restrict_lib.sh 修复 Android sh 下 pkg|policy|delay 解析为空。
#
# v4.4.8 变更:
#   - WebUI token 不再通过 info.sh GET 下发, 改为浏览器端手动配对, 收紧本机 App 攻击面。
#   - external 且未检测到启用中的 Uperf 时, boot/WebUI 做一次 balanced sanitize, 避免残留 cap=1024 / vendor_sched 高 boost。
#   - NR 息屏降级补齐 ap_br_wlan*/ap_br_softap* 热点桥接接口, 并从 preferred_network_mode 初始化 LTE/5G 状态。
#   - .profile_history 兼容旧 9 列记录, 启动时追加 10 列 sched_owner baseline。
#   - WebUI pid/lock 状态文件权限收紧。
#   - 后台应用限制改为按包策略, 首次默认仅预置抖音 "休眠"。
#
# v4.4.6 变更:
#   - WebUI token 改为每次 service 启动轮换, 缩短本机泄露后的可用窗口。
#   - L1 后台限制新增 .bg_restrict_baseline, 移除/关闭时按原 bucket/appops 恢复。
#   - .profile_history 追加 sched_owner 字段, 便于外部调度接管复盘。
#   - WebUI httpd 改用 pid 文件停止本模块实例, 避免端口粗匹配误杀。
#
# v4.4.5 变更:
#   - 新增外部调度接管模式: external 时跳过 response_time_ms / uclamp / cpuset / vendor_sched 写入
#
# v4.4.4 变更:
#   - balanced 低热日用底座: response_time_ms 16/24/160 -> 16/40/200, 保持 top-app 0-7 与 cap=0。
# v4.4.3 变更:
#   - 修复 WebUI 温度历史折线图: 打开后自动静默刷新, 关闭/返回时清理刷新器.
#
# v4.4.2 变更:
#   - 修复温度实时显示: thermalservice 只解析 Current temperatures from HAL, 缓存超过 30s 即重建.
#   - 修复 .profile_history 启动后不生成: boot baseline 写入 service_start, 并修正 response_time_ms 路径.
#
# v4.4.1 变更:
#   - 自动调度新增充电体感热闸: VIRTUAL-SKIN >= 41.0C 持续 120s 才压 battery,
#     <= 39.5C 持续 90s 才恢复 balanced; thermalservice severity>=2 仍立即收口.
#   - 新增 .profile_history 切档证据链, 记录 profile/reason/充电状态/VIRTUAL-SKIN/severity/cap/response.
#
# v4.4.0 变更:
#   - CPU 新增 performance 档 (替换 responsive): 进档 sched_util_clamp_min 0→1024 还 Google
#     出厂 uclamp.min 上限, 放开 ADPF/HBoost/fork/ExoPlayer 动态 boost (顺内核"还闸")
#   - sched_util_clamp_min 改为按档管理 (cpu_profile.sh), 移除 boot 阶段独立写 0
#   - 纠正旧机理: 它是 uclamp.min 系统级上限(cap), 非"虚假 100% util 信号"
#   - 老用户 responsive 配置自动迁移到 performance
#
# v4.3.27 变更:
#   - B42 fix: bg_restrict.sh remove_restrict() 增加 bucket 恢复 (v4.4.6 起优先按 baseline 原值恢复)
#   - B43 fix: standby_guard.sh SIM2 恢复从废弃 radio power 改为 set-sim-count 2
#   - B44 fix: customize.sh 升级迁移追加 .bg_restrict_list/.bg_restrict_enabled
#   - B45 fix: refreshBgRestrict() 轮询改为 GET 只读, 手动刷新才 POST refresh
#   - L1 注释移除未实现的 deviceidle whitelist 声明
#   - B46 fix: 屏幕检测从 legacy DRM dpms 改为 enabled 节点 (dpms 在 atomic driver 下不更新)
#
# v4.3.26 变更:
#   - L1 后台限制从硬编码包名改为配置文件驱动 (.bg_restrict_list + .bg_restrict_enabled)
#   - 新增 WebUI "后台应用限制" 卡片: 主开关 + 包名列表 + 实时 bucket/appops 状态 + 添加/移除
#   - 新增 CGI bg_restrict.sh: toggle/add/remove 三种 action
#   - 首次运行自动预置默认列表, 用户可通过 WebUI 自由增删
#
# v4.3.25 变更:
#   - 新增三层功耗方案 (L1-L3):
#     L1: 官方 API 后台限制 (persistent) — App Standby Bucket + AppOps + Freezer
#     L2: vendor_sched 后台 CPU 限制 (volatile, enforce 守护) — ug_bg_uclamp_max/ug_bg_group_throttle
#     L3: response_time_ms (volatile, boot-time only) — 已有, 由 cpu_profile.sh 管理
#   - cpu_profile.sh 新增 enforce 子命令: 只做 procfs 读写, 零 IPC, 零 wakelock
#   - worker 亮屏分支每周期调用 enforce, 保证 vendor_sched 参数不被 PowerHAL hint 覆盖
#   - [v4.3.28] 移除无效属性 vendor.powerhal.apf_enabled=false (Pixel 9 Pro PowerHAL 不识别)
#
# v4.3.21 变更:
#   - 修复 NR 降级 tethering 误判: wlan1/wlan2 (bcmdhd P2P 虚拟接口) 被误判为热点,
#     导致 _tether=1 永久阻止降级. 修复: 只检测 swlan0/ap0/softap0/rndis0/ncm0 且 operstate=up
#   - 回滚 v4.3.20 错误的 IRQ smp_affinity 方案 (stock 内核无 dhd_dpc, suspend 时被驱动重置)
#
# v4.3.20 变更:
#   - 修复 NR 降级 adaptive sleep bug: 等待期间 worker 从 600s 跳到 60s 间隔
#   - 新增 sched_util_clamp_min=0 (v4.4.0 已改为按档管理; 机理纠正见 cpu_profile.sh)
#   - 新增 apply_irq_affinity (后在 v4.3.21 回滚, 方案错误)
#
# v4.3.19 变更:
#   - SIM2 空槽省电彻底重写: 从 cmd phone radio power (临时关 radio, 会被框架恢复)
#     改为 cmd phone set-sim-count 1 (AOSP 官方 API, 持久化, 直接减少 Active modem count)
#   - 恢复 DSDS: SIM2 插入时自动 set-sim-count 2
#   - 移除 boot+120s/300s 重试 hack, 因为 set-sim-count 是持久化的不需要重试
#
# v4.3.17 变更:
#   - 新增待机隔离模式(.idle_isolate_mode)，用于过夜隔离 control 模块对 suspend 的干扰
#   - 新增 .standby_diag_state 低噪声诊断状态文件，记录 worker 当前分支与下次唤醒时间
#   - WebUI 优化页新增 SIM2 自动管理 / 待机隔离显式开关
#   - 待机隔离模式压过 thermal burst / LTE 轮询，确保息屏阶段维持 600s 最小唤醒路径
#   - 文档与版本基线同步到 v4.3.17
#
# v4.3.16 变更:
#   - 修复 deep sleep 0%: 息屏深度待机保护模式, 跳过 thermal/前台 profile 自动采样
#   - SIM2/IMS 自动管理默认关闭, 避免 modem 重注册导致 s5100/umts_dm0 持锁
#   - 120s 延迟复写移除 manage_sim2_radio, 减少 boot 阶段 radio IPC
#   - 息屏路径不再执行 cmd phone / settings put preferred_network_mode 以外的 radio 命令
#
# v4.3.15 变更:
#   - 新增慢切换自动调度策略: feed 类前台长亮屏保持 balanced，持续热平台时 balanced→battery
#   - 自动策略只在亮屏前台生效，息屏或温度回落后回到 balanced，避免高频来回切换
#   - 新增 .profile_policy / .profile_manual / .profile_auto_reason 状态文件
#
# v4.3.14 变更:
#   - CPU 轻载策略重构: light/battery 不再把 top-app 固定推到 4-7，也不再锁死小核 820MHz
#   - 平衡/轻度/省电三档改为更接近 Pixel 官方前台层级分工的 steady-state 方案
#
# v4.3.13 变更:
#   - 显式开启 Adaptive Connectivity (Google 官方 5G 节电机制)
#   - 显式确保 network_recommendations 不被其他模块关闭
#   - UECap 三档重命名: 国内频段/全面增强/Google 默认
#   - WebUI UE 能力说明精简
#
# v4.3.12 变更:
#   - SIM2 空槽省电改用 cmd phone radio power -s 1 off (B36 旧 API 无效)
#   - 同时关闭空槽 IMS (cmd phone ims disable -s 1) 消除 IMS 注册唤醒
#   - NR 降级修复 DSDS preferred_network_mode 逗号格式解析 (B37)
#   - 降级/恢复只改 slot 0，保留 slot 1 原值不丢失
#
# v4.3.11 变更:
#   - 修正 UECap 参数说明：universal=stock 等价副本，balanced=trial_minimal_cn_combo
#   - README / docs 技术参数口径同步到当前 payload hash/audit
#
# v4.3.10 变更:
#   - WebUI 中文文案整体重构：UE 能力配置、温控阈值、基带模块说明改为更自然的中文口径
#
# v4.3.9 变更:
#   - WebUI 固定四路 setInterval 改为单调度器，按当前 tab 计算下次唤醒时间
#   - 用户闲置 45 秒或弹窗打开时自动降频，减少前台页面无效轮询
#
# v4.3.8 变更:
#   - 功耗详情 CGI 增加短时缓存，减少重复解析 batterystats 带来的瞬时失败
#   - WebUI 功耗详情在网络错误时自动重试一次
#
# v4.3.7 变更:
#   - 新增低频电池采样与放电会话状态机，功耗详情明确区分“当前放电会话 / 今日累计 / batterystats 窗口”
#   - 温度历史短时窗口调整为 10 分钟 / 30 分钟，两者都显示曲线 + 统计
#
# v4.3.6 变更:
#   - WebUI 轮询按当前 tab 收口，避免前台停在无关页时继续刷新全部数据
#   - NR 已降级到 LTE 的息屏阶段改为较短复查周期，同时保持息屏热缓存低频更新
#
# v4.3.5 变更:
#   - WebUI UECap 切换后改为回读 active_mode/hash 校验
#   - 不再用“约 5 秒后生效”作为成功提示
#
# v4.3.4 变更:
#   - 恢复 balanced 为独立的 trial_minimal_cn_combo payload
#   - 避免 balanced/special 指向同一份 binarypb，保证三档真正分离
#
# v4.3.3 变更:
#   - boot 阶段 UECap 应用明确传入 boot_manual，避免开机误触发 modem restart
#   - SIM2 空槽管理不再写 global mobile_data，避免误伤主卡数据开关
#
# v4.3.2 变更:
#   - UECap 切换改为仅重启 cellular modem (cmd phone restart-modem)
#   - 禁止再用 airplane toggle，避免 Connectivity/系统服务级联崩溃
#
# v4.3.1 变更:
#   - SIM2 空槽自动关闭 radio instance (省 modem 搜网功耗)
#   - SIM2 插入时自动恢复 radio (统一循环亮屏周期检查)
#   - NR 息屏降级默认改为开启 (on)
#   - UECap 切换后触发 modem 重载
#
# v4.3.0 变更:
#   - 合并 4 个独立后台循环为 1 个统一工作循环 (Doze 友好)
#   - 移除 UECap 自动策略循环，改为纯手动三档切换
#   - 息屏 dumpsys 调用从 ~10/min 降至 ~0.1/min
#   - 新增温度突发录制 (thermal burst): 用户打开历史图表时 5s 间隔
#   - WiFi multicast: 仅在屏幕状态变化时切换，不轮询
#   - 息屏后 60s 首次检查 (NR 防抖)，之后 600s 长休眠
##############################################################
MODDIR="${0%/*}"
PORT=6210
HTTPD_PID_FILE="$MODDIR/.webui_httpd.pid"
TOKEN_FILE="$MODDIR/.webui_token"
THERMAL_CACHE="$MODDIR/.thermal_cache.json"
LOCKDIR_BASE="$MODDIR/.locks"
PROFILE_FILE="$MODDIR/.current_profile"
PROFILE_POLICY_FILE="$MODDIR/.profile_policy"
PROFILE_MANUAL_FILE="$MODDIR/.profile_manual"
PROFILE_AUTO_REASON_FILE="$MODDIR/.profile_auto_reason"
PROFILE_HISTORY_FILE="$MODDIR/.profile_history"
SCHED_OWNER_FILE="$MODDIR/.cpu_sched_owner"
SIM2_AUTO_FILE="$MODDIR/.sim2_auto_manage"
IDLE_ISOLATE_FILE="$MODDIR/.idle_isolate_mode"
STANDBY_DIAG_FILE="$MODDIR/.standby_diag_state"
POWER_PROFILE_FILE="$MODDIR/.power_profile"

. "$MODDIR/scripts/bg_restrict_lib.sh" 2>/dev/null
[ -f "$MODDIR/scripts/scheduler_detect_lib.sh" ] && . "$MODDIR/scripts/scheduler_detect_lib.sh" 2>/dev/null

detect_root_impl() {
    if [ "${APATCH:-}" = "true" ] || [ -d /data/adb/ap ]; then
        echo "apatch"
    elif [ "${KSU:-}" = "true" ] || [ -d /data/adb/ksu ]; then
        echo "kernelsu"
    elif [ -d /data/adb/magisk ]; then
        echo "magisk"
    else
        echo "unknown"
    fi
}

ROOT_IMPL=$(detect_root_impl)

find_webui_httpd_pid() {
    for _pid in $(pidof httpd 2>/dev/null) $(pidof busybox 2>/dev/null); do
        case "$_pid" in ''|*[!0-9]*) continue ;; esac
        _cmd=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
        case "$_cmd" in
            *httpd*"$MODDIR/webroot"*|*httpd*"127.0.0.1:$PORT"*|*httpd*":$PORT"*)
                printf '%s' "$_pid"
                return 0
                ;;
        esac
    done
    return 1
}

stop_webui_httpd() {
    _pid=$(cat "$HTTPD_PID_FILE" 2>/dev/null | tr -d ' \n\r\t')
    if [ -n "$_pid" ] && [ -r "/proc/$_pid/cmdline" ]; then
        _cmd=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
        case "$_cmd" in
            *httpd*"$MODDIR/webroot"*|*httpd*"127.0.0.1:$PORT"*|*httpd*":$PORT"*)
                kill "$_pid" 2>/dev/null
                rm -f "$HTTPD_PID_FILE" 2>/dev/null
                return 0
                ;;
        esac
    fi

    _pid=$(find_webui_httpd_pid)
    if [ -n "$_pid" ]; then
        kill "$_pid" 2>/dev/null
    fi
    rm -f "$HTTPD_PID_FILE" 2>/dev/null
}

record_webui_httpd_pid() {
    _pid=$(find_webui_httpd_pid)
    if [ -n "$_pid" ]; then
        printf '%s\n' "$_pid" > "$HTTPD_PID_FILE" 2>/dev/null
        chmod 600 "$HTTPD_PID_FILE" 2>/dev/null
    fi
}

read_onoff_file() {
    _flag_value=$(cat "$1" 2>/dev/null | tr -d ' \n\r\t')
    case "$_flag_value" in
        on|off) printf '%s' "$_flag_value" ;;
        *) printf '%s' "$2" ;;
    esac
}

restore_ntp_server() {
    NTP_SAVE="$MODDIR/.ntp_server"
    if [ -s "$NTP_SAVE" ]; then
        _saved=$(cat "$NTP_SAVE" 2>/dev/null | tr -d ' \n\r')
        case "$_saved" in
            ntp.aliyun.com|ntp.myhuaweicloud.com|ntp1.xiaomi.com|time.android.com)
                settings put global ntp_server "$_saved" 2>/dev/null
                log -t pixel9pro_ctrl "NTP server restored: $_saved"
                ;;
        esac
    fi
}

apply_uecap_profile() {
    if [ -f "$MODDIR/uecap_profile.sh" ]; then
        . "$MODDIR/uecap_profile.sh"
        uecap_set_policy manual
        [ -f "$UECAP_MANUAL_MODE_FILE" ] || uecap_set_manual_mode balanced
        [ -f "$UECAP_MODE_FILE" ] || uecap_set_mode balanced
        _mode=$(uecap_current_manual_mode)
        if uecap_apply_mode "$_mode" "boot_manual" 2>/dev/null; then
            uecap_set_reason boot_manual
            log -t pixel9pro_ctrl "UECap profile applied: $_mode (manual)"
        else
            log -t pixel9pro_ctrl "WARNING: failed to apply UECap profile: $_mode"
        fi
    fi
}

apply_keep5g_standby_settings() {
    # 保留 5G / 5GA / CA 能力时，仍然建议关闭 mobile_data_always_on。
    # AOSP 定义表明该项仅用于在 Wi-Fi 等高优先级网络存在时，让蜂窝数据链路继续常驻以加快切换。
    # 关闭它不会取消 NR 注册或 CA 能力，但在 Wi-Fi -> 蜂窝回切时可能带来轻微时延。
    settings put global mobile_data_always_on 0 2>/dev/null

    # keep-5G 分支显式不强制关闭 VoWiFi / WFC。
    # AOSP 中 wfc_ims_enabled 是 Wi-Fi Calling 用户开关；强制关闭会明确影响室内弱覆盖场景的通话连续性。
    # 该项对 5G/5GA/CA 能力本身没有收益，因此本版暂停托管。

    # 扫描与 Nearby 相关项对 5G 能力本身无直接影响，仅减少息屏扫描和发现流量。
    settings put global nearby_sharing_enabled 0 2>/dev/null
    settings put secure nearby_sharing_slice_enabled 0 2>/dev/null
    settings put global wifi_scan_always_enabled 0 2>/dev/null
    settings put global ble_scan_always_enabled 0 2>/dev/null

    # adaptive_connectivity: Google 官方背书的 5G 节电机制。
    # 开启后，系统在 app 不需要高速时自动从 NR 回退到 LTE，降低 modem 空闲功耗。
    # 来源: https://support.google.com/pixelphone/answer/2819583
    settings put global adaptive_connectivity_enabled 1 2>/dev/null

    # network_recommendations: 系统默认已是开启，显式确保不被其他模块关闭。
    settings put global network_recommendations_enabled 1 2>/dev/null
}

manage_sim2_radio() {
    # SIM2 空槽省电: 通过 AOSP 官方 API 切换 DSDS ↔ 单 SIM 模式。
    #
    # 旧方案 (v4.3.1~v4.3.18): cmd phone radio power -s 1 off
    #   问题: 只是临时关闭 radio，telephony 框架仍维护 2 个 modem 实例，
    #   会在 boot/网络变化/IMS 注册等事件后自动恢复 radio，导致空槽 modem 重新搜网。
    #
    # 新方案 (v4.3.19): cmd phone set-sim-count 1
    #   调用 TelephonyManager.switchMultiSimConfig()，AOSP 官方持久化 API。
    #   效果: Active modem count 从 2 降到 1，persist.radio.multisim.config 从 dsds 变为空，
    #   第二个 modem 实例被框架彻底释放，不存在"被恢复"的问题。
    #   恢复: cmd phone set-sim-count 2 即可恢复 DSDS。
    #
    # 参考:
    #   - DroidWin: https://droidwin.com/how-to-disable-dual-sim-dual-standby-on-pixel-devices/
    #   - XDA: https://xdaforums.com/t/disable-multi-sim-feature-to-reduce-battery-drain.3057352/
    #   - AOSP: TelephonyShellCommand.handleSetSimCount → TelephonyManager.switchMultiSimConfig
    #   - 设备验证: persist.vendor.radio.multisim_switch_support=true (Pixel 9 Pro 官方支持)

    _sim2_auto=$(read_onoff_file "$SIM2_AUTO_FILE" 'on')

    if [ "$_sim2_auto" != "on" ]; then
        # 用户显式关闭自动管理: 恢复 DSDS 双 modem
        if [ "$(cat "$MODDIR/.sim2_radio_off" 2>/dev/null)" = "disabled" ]; then
            cmd phone set-sim-count 2 2>/dev/null
            printf 'enabled' > "$MODDIR/.sim2_radio_off"
            log -t pixel9pro_ctrl "SIM2 auto-manage off: restored DSDS (set-sim-count 2)"
        fi
        return 0
    fi

    _sim2_state=$(getprop gsm.sim.state 2>/dev/null | sed 's/.*,//')
    case "$_sim2_state" in
        ABSENT|NOT_READY|PIN_REQUIRED|PUK_REQUIRED|PERM_DISABLED)
            if [ "$(cat "$MODDIR/.sim2_radio_off" 2>/dev/null)" != "disabled" ]; then
                cmd phone set-sim-count 1 2>/dev/null
                printf 'disabled' > "$MODDIR/.sim2_radio_off"
                log -t pixel9pro_ctrl "SIM2=$_sim2_state: switched to single SIM (set-sim-count 1)"
            fi
            ;;
        LOADED|READY)
            if [ "$(cat "$MODDIR/.sim2_radio_off" 2>/dev/null)" = "disabled" ]; then
                cmd phone set-sim-count 2 2>/dev/null
                printf 'enabled' > "$MODDIR/.sim2_radio_off"
                log -t pixel9pro_ctrl "SIM2=$_sim2_state: restored DSDS (set-sim-count 2)"
            fi
            ;;
    esac
}

# ── 三层功耗方案: 参数定义 ──────────────────────────────
# Power profile: balanced (默认) / battery (省电)
# L1 (persistent): App Standby Bucket + AppOps + Freezer
# L2 (volatile): vendor_sched 后台 CPU 限制
# L3 (volatile, boot-time): response_time_ms (由 cpu_profile.sh 管理)
#
# AOSP 验证:
#   - App Standby Bucket: UsageStatsService 持久化到 app_idle_stats.xml, 重启后保留
#     am set-standby-bucket 设置 reason=FORCED_BY_USER, 只有用户交互才会提升
#   - AppOps: 持久化到 appops.xml, 系统不会自动回退
#   - vendor_sched: /proc/vendor_sched/ 纯 RAM, PowerHAL 在 hint 时可能覆盖
#
# 注: 旧版 L3 "APF touch boost" (vendor.powerhal.apf_enabled=false) 已在 v4.3.28 移除,
#     Pixel 9 Pro PowerHAL 不识别该属性, INTERACTION hint 未配置且零次触发 (2026-05-03 验证)

VENDOR_SCHED="/proc/vendor_sched"

_power_profile_params() {
    # 根据 power profile 返回参数 (balanced / battery)
    # 格式: bg_uclamp_max bg_group_throttle
    _pp=$(cat "$POWER_PROFILE_FILE" 2>/dev/null | tr -d ' \n\r')
    case "$_pp" in
        battery) echo "150 80" ;;
        *)       echo "200 100" ;;
    esac
}

apply_l1_persistent_limits() {
    # L1: 官方 API 后台限制 — persistent, 从配置文件读取包名策略
    # 文件: .bg_restrict_list (pkg|policy|delay_min), .bg_restrict_enabled (on/off)
    #       .bg_restrict_baseline (限制前 bucket/appops 原值)
    BG_ENABLED_FILE="$MODDIR/.bg_restrict_enabled"
    BG_LIST_FILE="$MODDIR/.bg_restrict_list"
    BG_BASELINE_FILE="$MODDIR/.bg_restrict_baseline"
    BG_STOP_STATE_FILE="$MODDIR/.bg_restrict_stop_state"

    [ -f "$BG_ENABLED_FILE" ] || printf 'on' > "$BG_ENABLED_FILE"
    if [ ! -e "$BG_LIST_FILE" ]; then
        # 首次运行: 只预置抖音。文件存在但为空时表示用户已清空列表，不再重置默认包名。
        cat > "$BG_LIST_FILE" <<'DEFLIST'
com.ss.android.ugc.aweme|stop_after_leave|5
DEFLIST
    fi
    rm -f "$BG_STOP_STATE_FILE" 2>/dev/null

    _bg_enabled=$(cat "$BG_ENABLED_FILE" 2>/dev/null | tr -d ' \n\r\t')
    if [ "$_bg_enabled" != "on" ]; then
        log -t pixel9pro_ctrl "L1: bg restrict disabled by user, skip"
        return 0
    fi

    _count=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        bg_parse_entry "$_line"
        [ -z "$_bg_pkg" ] && continue
        case "$_bg_pkg" in \#*) continue ;; esac
        bg_apply_policy "$_bg_pkg" "$_bg_policy"
        _count=$((_count + 1))
    done < "$BG_LIST_FILE"

    # Cached App Freezer: 确保开启 (cgroup v2 freeze, 缓存进程零 CPU)
    settings put global cached_apps_freezer_enabled 1 2>/dev/null

    log -t pixel9pro_ctrl "L1: bg restrict applied to $_count packages, freezer=1"
}

apply_l2_vendor_sched() {
    # L2: vendor_sched 后台 CPU 限制 — volatile, 需要 enforce 守护
    _params=$(_power_profile_params)
    _bg_uclamp=$(echo "$_params" | cut -d' ' -f1)
    _bg_throttle=$(echo "$_params" | cut -d' ' -f2)
    echo "$_bg_uclamp" > "$VENDOR_SCHED/ug_bg_uclamp_max" 2>/dev/null
    echo "$_bg_throttle" > "$VENDOR_SCHED/ug_bg_group_throttle" 2>/dev/null
    log -t pixel9pro_ctrl "L2: vendor_sched bg_uclamp_max=$_bg_uclamp bg_throttle=$_bg_throttle"
}

# [已移除] apply_l3_apf — v4.3.28 移除
# vendor.powerhal.apf_enabled 在 Pixel 9 Pro 上无效:
#   PowerHAL 二进制不含 apf 字符串, INTERACTION hint 未配置
#   Pixel 9 Pro 使用 HBoost + ADPF 机制替代旧 INTERACTION hint

valid_profile() {
    case "$1" in
        performance|balanced|battery|default) return 0 ;;
        *) return 1 ;;
    esac
}

valid_profile_policy() {
    case "$1" in
        manual|auto) return 0 ;;
        *) return 1 ;;
    esac
}

read_valid_profile() {
    _profile_path="$1"
    _profile_default="$2"
    _profile_value=$(cat "$_profile_path" 2>/dev/null | tr -d ' \n\r\t')
    # v4.3.22: light 已删除, 映射到 balanced
    [ "$_profile_value" = "light" ] && _profile_value="balanced"
    # v4.4.0: responsive 改名 performance (加 cap 管理), 旧值映射
    [ "$_profile_value" = "responsive" ] && _profile_value="performance"
    if valid_profile "$_profile_value"; then
        printf '%s' "$_profile_value"
    else
        printf '%s' "$_profile_default"
    fi
}

read_valid_profile_policy() {
    _policy_value=$(cat "$PROFILE_POLICY_FILE" 2>/dev/null | tr -d ' \n\r\t')
    if valid_profile_policy "$_policy_value"; then
        printf '%s' "$_policy_value"
    else
        printf 'manual'
    fi
}

read_valid_sched_owner() {
    _owner_value=$(cat "$SCHED_OWNER_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_owner_value" in
        external) printf 'external' ;;
        *)        printf 'pixel' ;;
    esac
}

append_profile_history() {
    _ph_profile="$1"
    _ph_reason="$2"
    _ph_epoch="${_now:-}"
    case "$_ph_epoch" in
        ''|*[!0-9]*) _ph_epoch=$(date +%s 2>/dev/null || echo 0) ;;
    esac
    _ph_policy=$(read_valid_profile_policy)
    _ph_owner=$(read_valid_sched_owner)
    _ph_charging="${_p_is_charging:-0}"
    case "$_ph_charging" in
        1) ;;
        *) _ph_charging=0 ;;
    esac
    _ph_vs="${_vs_temp:-}"
    case "$_ph_vs" in
        ''|*[!0-9]*) _ph_vs=0 ;;
    esac
    _ph_sev="${_sev:-}"
    case "$_ph_sev" in
        ''|*[!0-9]*) _ph_sev=-1 ;;
    esac
    _ph_cap=$(cat /proc/sys/kernel/sched_util_clamp_min 2>/dev/null | tr -d ' \n\r\t')
    case "$_ph_cap" in
        ''|*[!0-9]*) _ph_cap=-1 ;;
    esac
    _ph_resp0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/sched_pixel/response_time_ms 2>/dev/null | tr -d ' \n\r\t')
    _ph_resp4=$(cat /sys/devices/system/cpu/cpu4/cpufreq/sched_pixel/response_time_ms 2>/dev/null | tr -d ' \n\r\t')
    _ph_resp7=$(cat /sys/devices/system/cpu/cpu7/cpufreq/sched_pixel/response_time_ms 2>/dev/null | tr -d ' \n\r\t')
    [ -n "$_ph_resp0" ] || _ph_resp0="na"
    [ -n "$_ph_resp4" ] || _ph_resp4="na"
    [ -n "$_ph_resp7" ] || _ph_resp7="na"
    _ph_response="${_ph_resp0}/${_ph_resp4}/${_ph_resp7}"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$_ph_epoch" "$_ph_policy" "$_ph_owner" "$_ph_profile" "$_ph_reason" \
        "$_ph_charging" "$_ph_vs" "$_ph_sev" "$_ph_cap" "$_ph_response" \
        >> "$PROFILE_HISTORY_FILE" 2>/dev/null

    _ph_lines=$(wc -l < "$PROFILE_HISTORY_FILE" 2>/dev/null)
    if [ "${_ph_lines:-0}" -gt 500 ] 2>/dev/null; then
        _ph_trim=$((_ph_lines - 500))
        sed -i "1,${_ph_trim}d" "$PROFILE_HISTORY_FILE" 2>/dev/null
    fi
}

profile_history_has_owner_field() {
    [ -s "$PROFILE_HISTORY_FILE" ] || return 1
    _ph_last=$(tail -n 1 "$PROFILE_HISTORY_FILE" 2>/dev/null)
    _ph_cols=$(printf '%s\n' "$_ph_last" | awk -F',' '{print NF}')
    [ "${_ph_cols:-0}" -ge 10 ] 2>/dev/null
}

ensure_profile_history_baseline() {
    profile_history_has_owner_field && return 0
    _ph_saved_now="${_now:-}"
    _now=$(date +%s 2>/dev/null || echo 0)
    _p_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null | tr -d '\r')
    _p_status=$(printf '%s' "$_p_status" | sed 's/[[:space:]]*$//')
    case "$_p_status" in
        Charging|Full) _p_is_charging=1 ;;
        *) _p_is_charging=0 ;;
    esac
    . "$MODDIR/webroot/cgi-bin/_thermal_cache.sh" 2>/dev/null
    if command -v build_thermal_json >/dev/null 2>&1; then
        _ph_json=$(build_thermal_json 2>/dev/null)
        if [ -n "$_ph_json" ] && [ "$_ph_json" != "[]" ]; then
            _ph_tmp="${THERMAL_CACHE}.$$.$_now.tmp"
            printf '%s' "$_ph_json" > "$_ph_tmp" 2>/dev/null
            mv "$_ph_tmp" "$THERMAL_CACHE" 2>/dev/null
        fi
    fi
    _vs_temp=$(sed -n 's/.*VIRTUAL-SKIN","temp":\([0-9]*\).*/\1/p' "$THERMAL_CACHE" 2>/dev/null | head -1)
    case "$_vs_temp" in
        ''|*[!0-9]*) _vs_temp=0 ;;
    esac
    _sev=$(dumpsys thermalservice 2>/dev/null | grep "Thermal Status:" | head -1 | sed 's/.*Thermal Status:[[:space:]]*//' | tr -d ' \n\r')
    case "$_sev" in ''|*[!0-9]*) _sev=0 ;; esac
    append_profile_history "$(read_valid_profile "$PROFILE_FILE" 'default')" "service_start"
    _now="$_ph_saved_now"
}

profile_lock_acquire() {
    _plock="$LOCKDIR_BASE/profile.lock"
    mkdir -p "$LOCKDIR_BASE" 2>/dev/null
    if mkdir "$_plock" 2>/dev/null; then
        echo "$$" > "$_plock/pid" 2>/dev/null
        return 0
    fi
    _lock_pid=$(cat "$_plock/pid" 2>/dev/null)
    if [ -z "$_lock_pid" ] || ! kill -0 "$_lock_pid" 2>/dev/null; then
        rm -f "$_plock/pid" 2>/dev/null
        rmdir "$_plock" 2>/dev/null
        if mkdir "$_plock" 2>/dev/null; then
            echo "$$" > "$_plock/pid" 2>/dev/null
            return 0
        fi
    fi
    return 1
}

profile_lock_release() {
    _plock="$LOCKDIR_BASE/profile.lock"
    rm -f "$_plock/pid" 2>/dev/null
    rmdir "$_plock" 2>/dev/null
}

apply_profile_state() {
    _target="$1"
    _reason="$2"

    valid_profile "$_target" || return 1

    if [ "$(read_valid_sched_owner)" = "external" ]; then
        log -t pixel9pro_ctrl "CPU profile skipped: scheduler owner=external ($_target/$_reason)"
        return 0
    fi

    if ! profile_lock_acquire; then
        log -t pixel9pro_ctrl "CPU profile busy, skip auto switch -> $_target ($_reason)"
        return 1
    fi

    _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$_target" "$MODDIR" 2>/dev/null)
    _rc=$?

    if [ "$_rc" -eq 0 ]; then
        printf '%s' "$_target" > "$PROFILE_FILE"
        printf '%s' "$_reason" > "$PROFILE_AUTO_REASON_FILE"
        append_profile_history "$_target" "$_reason"
        log -t pixel9pro_ctrl "CPU profile applied: $_target ($_reason)"
        profile_lock_release
        return 0
    fi

    log -t pixel9pro_ctrl "WARNING: failed to apply CPU profile $_target ($_reason): ${_result:-unknown}"
    profile_lock_release
    return 1
}

scheduler_external_active() {
    if command -v detect_uperf_module >/dev/null 2>&1; then
        detect_uperf_module 2>/dev/null
        [ "$UPERF_DETECTED" = "yes" ] && [ "$UPERF_MODULE_ENABLED" = "yes" ] && return 0
    fi
    return 1
}

sanitize_external_without_scheduler() {
    [ "$(read_valid_sched_owner)" = "external" ] || return 0
    scheduler_external_active && return 0

    echo 200 > "$VENDOR_SCHED/ug_bg_uclamp_max" 2>/dev/null
    echo 100 > "$VENDOR_SCHED/ug_bg_group_throttle" 2>/dev/null
    if sh "$MODDIR/scripts/cpu_profile.sh" balanced "$MODDIR" force 2>/dev/null; then
        printf '%s' 'balanced' > "$PROFILE_FILE"
        printf '%s' 'external_no_scheduler_sanitized' > "$PROFILE_AUTO_REASON_FILE"
        append_profile_history "balanced" "external_no_scheduler_sanitized"
        log -t pixel9pro_ctrl "CPU external without active Uperf: sanitized to balanced baseline"
        return 0
    fi

    log -t pixel9pro_ctrl "WARNING: CPU external without active Uperf, sanitize failed"
    return 1
}

foreground_package_name() {
    _pkg=$(dumpsys activity top 2>/dev/null | grep '^  ACTIVITY ' | head -1 | sed 's/.*ACTIVITY \([^/ ][^/ ]*\)\/.*/\1/')
    if [ -z "$_pkg" ]; then
        _pkg=$(dumpsys window 2>/dev/null | grep 'mCurrentFocus' | head -1 | sed 's/.* \([^/ ][^/ ]*\)\/.*/\1/')
    fi
    printf '%s' "$_pkg" | tr -d ' \r\n'
}

# ──────────────────────────────────────────────────────────
# 1. 等待系统完全启动
# ──────────────────────────────────────────────────────────
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
done
sleep 20

# ──────────────────────────────────────────────────────────
# 1.1 WebUI 安全: token 生成 + 环境变量导出
# ──────────────────────────────────────────────────────────
mkdir -p "$LOCKDIR_BASE" 2>/dev/null
chmod 700 "$LOCKDIR_BASE" 2>/dev/null
token=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ -n "$token" ] || token="$(date +%s 2>/dev/null)_$$"
printf '%s' "$token" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE" 2>/dev/null

export PIXEL9PRO_MODDIR="$MODDIR"
export PIXEL9PRO_WEBUI_PORT="$PORT"
export PIXEL9PRO_WEBUI_TOKEN_FILE="$TOKEN_FILE"
export PIXEL9PRO_THERMAL_CACHE="$THERMAL_CACHE"
export PIXEL9PRO_LOCKDIR_BASE="$LOCKDIR_BASE"

# ──────────────────────────────────────────────────────────
# 2. 系统设置优化 (保 5G 分支)
# ──────────────────────────────────────────────────────────
# SIM2 自动管理: 默认 on。空槽 radio 全天消耗 800-1000 mAh，无任何收益。
# 若文件因热更新丢失，但 .sim2_radio_off 记录曾 disabled → 说明用户之前开过，恢复为 on。
# 若两个文件都不存在（首次运行）→ 默认 on，让功能立即生效。
if [ ! -f "$SIM2_AUTO_FILE" ]; then
    printf 'on' > "$SIM2_AUTO_FILE"
fi
[ -f "$IDLE_ISOLATE_FILE" ] || printf 'off' > "$IDLE_ISOLATE_FILE"

log -t pixel9pro_ctrl "v4.4.9[$ROOT_IMPL]: applying keep-5G standby optimizations..."

# === UECap 档位 (纯手动三档) ===
# special: global special，stock +52 组增强组合
# balanced: trial_minimal_cn_combo，stock +25 组中国 n28/n41/n79 组合
# universal: stock 等价副本
apply_uecap_profile

# === Modem / 待机优化 (参考 Mori 帖子 + RMBD 模块) ===
# 开机时先应用 keep-5G 分支设置，再由后续延迟复写兜住开机后被系统回写的项目。
apply_keep5g_standby_settings
restore_ntp_server

# === SIM2 空槽省电: 关闭空卡槽的 radio instance ===
manage_sim2_radio

# 开机时先全局关闭 WiFi multicast (RMBD 基础策略)
# 后续由 screen-aware 循环在亮屏时恢复
# [v4.3.28] 移除 dumpsys wifi disable-multicast:
#   WifiShellCommand 不含 disable-multicast 子命令 (AOSP 源码验证),
#   dumpsys wifi disable-multicast 仅触发 dump 输出, 不改变多播状态。
#   实际控制由 ip link set wlan0 multicast off 完成 (移除接口 MULTICAST 标志)。
ip link set wlan0 multicast off 2>/dev/null

# === 内核 I/O 参数优化 ===
echo 3000 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null
echo 50 > /proc/sys/vm/dirty_ratio 2>/dev/null
echo 20 > /proc/sys/vm/dirty_background_ratio 2>/dev/null

# === uclamp.min cap (sched_util_clamp_min) 现由 cpu_profile.sh 按档管理 ===
# 纠正旧机理: 它是 uclamp.min 的"系统级上限(cap)", 不是"虚假 100% util 信号"
#   (内核文档 sched-util-clamp; 出厂 1024 仅是允许的最大请求值, 不主动抬 util)。
# v4.4.0 起不在 boot 独立写: performance=1024(还 Google 动态 boost) / 其它档=0,
#   由 cpu_profile.sh 各分支成对管理; 下方第 3 节的 cpu_profile.sh 调用会按当前档写好 cap。

# === ZRAM 配置 (Emerald Hill 硬件加速 + 扩容) ===
# 原厂出厂: persist.vendor.zram_comp_algorithm 默认为 lz4, ZRAM 大小 50% RAM ≈ 8GB.
# init.rc 代码兜底默认是 lz77eh (Emerald Hill 硬件), 但出厂 persist 属性覆盖为 lz4.
# 本模块统一配置: 算法 lz77eh (硬件加速, 压缩率更优, CPU 零开销) + 大小 11392MB.
#
# persist 属性确保后续重启时 init.rc 直接使用 lz77eh, 减少 swapoff 次数.
setprop persist.vendor.zram_comp_algorithm lz77eh 2>/dev/null

# 目标: lz77eh + 11392MB (11945377792 bytes)
TARGET_ALGO="lz77eh"
TARGET_SIZE="11945377792"

CURRENT_ALGO=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | sed 's/.*\[\(.*\)\].*/\1/')
CURRENT_SIZE=$(cat /sys/block/zram0/disksize 2>/dev/null)

if [ "$CURRENT_ALGO" != "$TARGET_ALGO" ] || [ "$CURRENT_SIZE" != "$TARGET_SIZE" ]; then
    log -t pixel9pro_ctrl "ZRAM reconfigure: ${CURRENT_ALGO}/${CURRENT_SIZE} -> ${TARGET_ALGO}/${TARGET_SIZE}"
    if swapoff /dev/block/zram0 2>/dev/null; then
        echo 1 > /sys/block/zram0/reset 2>/dev/null
        echo "$TARGET_ALGO" > /sys/block/zram0/comp_algorithm 2>/dev/null
        echo "$TARGET_SIZE" > /sys/block/zram0/disksize 2>/dev/null
        mkswap /dev/block/zram0 >/dev/null 2>&1
        swapon /dev/block/zram0 2>/dev/null
        log -t pixel9pro_ctrl "ZRAM: $TARGET_ALGO $(($TARGET_SIZE / 1048576))MB ready"
    else
        log -t pixel9pro_ctrl "ZRAM: swapoff failed (heavy usage?), keeping current config"
    fi
else
    log -t pixel9pro_ctrl "ZRAM: already $TARGET_ALGO $(($TARGET_SIZE / 1048576))MB, skip"
fi

# === Swap / 内存回收调优 (按上次用户选择恢复) ===
SWAP_MODE=$(cat "$MODDIR/.swap_mode" 2>/dev/null | tr -d ' \n\r')
case "$SWAP_MODE" in
    stock)
        echo 150 > /proc/sys/vm/swappiness 2>/dev/null
        echo 27386 > /proc/sys/vm/min_free_kbytes 2>/dev/null
        echo 100 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null
        log -t pixel9pro_ctrl "Swap: restored stock VM params"
        ;;
    *)
        echo 100 > /proc/sys/vm/swappiness 2>/dev/null
        echo 65536 > /proc/sys/vm/min_free_kbytes 2>/dev/null
        echo 60 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null
        [ -s "$MODDIR/.swap_mode" ] || echo "optimized" > "$MODDIR/.swap_mode"
        ;;
esac

log -t pixel9pro_ctrl "v4.4.9[$ROOT_IMPL]: keep-5G standby settings applied (radio+kernel+swap+zram)"

# ──────────────────────────────────────────────────────────
# 2.5 三层功耗优化 (L1-L2, boot 阶段一次性应用)
#     L3 (response_time_ms) 由后续 cpu_profile.sh 管理
# ──────────────────────────────────────────────────────────
[ -f "$POWER_PROFILE_FILE" ] || printf 'balanced' > "$POWER_PROFILE_FILE"
[ -f "$SCHED_OWNER_FILE" ] || printf 'pixel' > "$SCHED_OWNER_FILE"
sanitize_external_without_scheduler
apply_l1_persistent_limits
if [ "$(read_valid_sched_owner)" = "external" ]; then
    log -t pixel9pro_ctrl "L2: skipped, scheduler owner=external"
else
    apply_l2_vendor_sched
fi

# 延迟复写：NTP 服务器和扫描类设置可能在用户解锁后被系统回写。
(
    sleep 120
    apply_keep5g_standby_settings
    restore_ntp_server
    log -t pixel9pro_ctrl "Standby settings re-applied after late boot"
) &

# ──────────────────────────────────────────────────────────
# 3. 应用 CPU 调度方案 (cpuset + sched_pixel 参数)
# ──────────────────────────────────────────────────────────
PROFILE=$(read_valid_profile "$PROFILE_FILE" 'default')
[ -f "$PROFILE_MANUAL_FILE" ] || printf '%s' "$PROFILE" > "$PROFILE_MANUAL_FILE"
[ -f "$PROFILE_POLICY_FILE" ] || printf 'manual' > "$PROFILE_POLICY_FILE"
[ -f "$PROFILE_AUTO_REASON_FILE" ] || printf 'manual_policy' > "$PROFILE_AUTO_REASON_FILE"
if [ "$(read_valid_sched_owner)" = "external" ]; then
    log -t pixel9pro_ctrl "CPU profile skipped: scheduler owner=external"
else
    sh "$MODDIR/scripts/cpu_profile.sh" "$PROFILE" "$MODDIR" 2>/dev/null
    log -t pixel9pro_ctrl "CPU profile: $PROFILE"
fi
ensure_profile_history_baseline

# ──────────────────────────────────────────────────────────
# 4. 统一后台工作循环 (Doze 友好)
#    合并原 4 个独立循环为 1 个，每周期只调用 1 次 dumpsys display
#    亮屏 15s / 息屏首次 60s (NR防抖) / 息屏后续 600s / 突发 5s
#    若已降到 LTE, 改为较短复查周期，避免亮屏后长期停留 LTE
#    WiFi multicast: 仅在屏幕状态变化时切换，不轮询
#    NR 降级: 集成防抖，仅在开启时生效
#    温度历史: 每周期记录，息屏 600s 一次 (突发时 5s)
#    UECap 自动策略: 已移除 (v4.3.0 改为纯手动三档)
# ──────────────────────────────────────────────────────────
NR_SWITCH_FILE="$MODDIR/.nr_screen_switch"
NR_MODE_FILE="$MODDIR/.nr_saved_mode"
THERMAL_HISTORY="$MODDIR/.thermal_history"
THERMAL_HISTORY_MAX=8640
THERMAL_BURST_FILE="$MODDIR/.thermal_burst_until"
POWER_HISTORY="$MODDIR/.power_history"
POWER_HISTORY_MAX=20160
POWER_SESSION_FILE="$MODDIR/.power_session"

[ -f "$NR_SWITCH_FILE" ] || echo "off" > "$NR_SWITCH_FILE"

_nr_slot0_val() {
    case "$1" in
        *,*) printf '%s' "${1%%,*}" ;;
        *) printf '%s' "$1" ;;
    esac
}

_nr_replace_slot0() {
    case "$1" in
        *,*) printf '%s,%s' "$2" "${1#*,}" ;;
        *) printf '%s' "$2" ;;
    esac
}

is_nr_mode_value() {
    _val=$(_nr_slot0_val "$1")
    case "$_val" in
        ''|null) return 1 ;;
        *[!0-9-]*) return 1 ;;
    esac
    [ "$_val" -ge 23 ] 2>/dev/null
}

(
    . "$MODDIR/webroot/cgi-bin/_thermal_cache.sh"

    _cleanup_nr() {
        if [ "$_nr_state" = "lte" ] && [ -n "$_nr_key" ]; then
            settings put global "$_nr_key" "$(cat "$NR_MODE_FILE" 2>/dev/null || echo 33)" 2>/dev/null
            log -t pixel9pro_ctrl "NR switch: worker exit, restored NR"
        fi
    }
    trap '_cleanup_nr' EXIT TERM HUP

    _write_standby_diag_state() {
        {
            printf 'updated_at=%s\n' "$1"
            printf 'screen=%s\n' "$2"
            printf 'worker_mode=%s\n' "$3"
            printf 'next_sleep_secs=%s\n' "$4"
            printf 'burst_active=%s\n' "$5"
            printf 'nr_switch=%s\n' "$6"
            printf 'nr_state=%s\n' "$7"
            printf 'profile_policy=%s\n' "$8"
            printf 'active_profile=%s\n' "$9"
            printf 'idle_isolate=%s\n' "${10}"
            printf 'sim2_auto_manage=%s\n' "${11}"
            printf 'cycle_count=%s\n' "${12}"
        } > "${STANDBY_DIAG_FILE}.tmp"
        mv "${STANDBY_DIAG_FILE}.tmp" "$STANDBY_DIAG_FILE"
    }

    _read_odpm_uws() {
        # Read ODPM cumulative energy (µWs) for modem rails
        # VSYS_PWR_MODEM: iio:device0 CH9, VSYS_PWR_RFFE: iio:device1 CH11
        _odpm_modem=0; _odpm_rffe=0
        _d0=$(cat /sys/bus/iio/devices/iio:device0/energy_value 2>/dev/null)
        _d1=$(cat /sys/bus/iio/devices/iio:device1/energy_value 2>/dev/null)
        _odpm_modem=$(printf '%s' "$_d0" | sed -n 's/.*VSYS_PWR_MODEM\], *\([0-9]*\).*/\1/p')
        _odpm_rffe=$(printf '%s' "$_d1" | sed -n 's/.*VSYS_PWR_RFFE\], *\([0-9]*\).*/\1/p')
        [ -z "$_odpm_modem" ] && _odpm_modem=0
        [ -z "$_odpm_rffe" ] && _odpm_rffe=0
    }

    _write_power_session() {
        _ps_start="$1"
        _ps_level="$2"
        _ps_charge="$3"
        _ps_reason="$4"
        _read_odpm_uws
        {
            printf 'start_ts=%s\n' "$_ps_start"
            printf 'start_level=%s\n' "$_ps_level"
            printf 'start_charge_uah=%s\n' "${_ps_charge:-0}"
            printf 'reset_reason=%s\n' "$_ps_reason"
            printf 'odpm_modem_uws=%s\n' "$_odpm_modem"
            printf 'odpm_rffe_uws=%s\n' "$_odpm_rffe"
        } > "${POWER_SESSION_FILE}.tmp"
        mv "${POWER_SESSION_FILE}.tmp" "$POWER_SESSION_FILE"
    }

    _trim_power_history_if_needed() {
        _power_hist_count=$((_power_hist_count + 1))
        if [ "$_power_hist_count" -ge 240 ]; then
            _lines=$(wc -l < "$POWER_HISTORY" 2>/dev/null)
            if [ "${_lines:-0}" -gt "$POWER_HISTORY_MAX" ]; then
                _trim=$((_lines - POWER_HISTORY_MAX))
                sed -i "1,${_trim}d" "$POWER_HISTORY" 2>/dev/null
            fi
            _power_hist_count=0
        fi
    }

    _track_power_window() {
        _p_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null | tr -d '\r')
        _p_status=$(printf '%s' "$_p_status" | sed 's/[[:space:]]*$//')
        _p_level=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null | tr -d ' \n\r')
        _p_charge=$(cat /sys/class/power_supply/battery/charge_counter 2>/dev/null | tr -d ' \n\r')

        case "$_p_level" in
            ''|*[!0-9]*) return ;;
        esac
        case "$_p_charge" in
            ''|*[!0-9-]*) _p_charge=0 ;;
        esac

        _p_is_charging=0
        case "$_p_status" in
            Charging|Full) _p_is_charging=1 ;;
        esac

        if [ "$_p_is_charging" -eq 1 ]; then
            if [ "$_power_prev_is_charging" -ne 1 ]; then
                _power_charge_since=$_now
                _power_charge_start_level=$_p_level
                _power_charge_seen_full=0
                _power_reset_armed=0
            elif [ "$_power_charge_since" -eq 0 ]; then
                _power_charge_since=$_now
            fi

            [ "$_p_status" = "Full" ] && _power_charge_seen_full=1

            if [ "$_power_charge_since" -gt 0 ] && [ $((_now - _power_charge_since)) -ge 600 ]; then
                if [ "$_p_status" = "Full" ] || [ "$_p_level" -gt "$_power_charge_start_level" ]; then
                    _power_reset_armed=1
                fi
            fi
        else
            if [ ! -s "$POWER_SESSION_FILE" ]; then
                _write_power_session "$_now" "$_p_level" "$_p_charge" "boot_init"
            elif [ "$_power_prev_is_charging" -eq 1 ] && [ "$_power_reset_armed" -eq 1 ]; then
                _reason="charged_10m"
                [ "$_power_charge_seen_full" -eq 1 ] && _reason="full_replug"
                _write_power_session "$_now" "$_p_level" "$_p_charge" "$_reason"
                log -t pixel9pro_ctrl "Power session reset: ${_reason}, level=${_p_level}"
            fi
            _power_charge_since=0
            _power_charge_start_level=$_p_level
            _power_charge_seen_full=0
            _power_reset_armed=0
        fi

        _power_interval=$_POWER_SAMPLE_INTERVAL_OFF
        [ "$_screen" = "on" ] && _power_interval=$_POWER_SAMPLE_INTERVAL_ON
        _should_sample=0
        if [ "$_power_last_sample" -eq 0 ] || [ $((_now - _power_last_sample)) -ge "$_power_interval" ]; then
            _should_sample=1
        fi
        [ "$_p_status" != "$_power_last_status" ] && _should_sample=1
        [ "$_p_level" != "$_power_last_level" ] && _should_sample=1

        if [ "$_should_sample" -eq 1 ]; then
            printf '%s,%s,%s,%s\n' "$_now" "$_p_level" "$_p_charge" "$_p_status" >> "$POWER_HISTORY"
            _trim_power_history_if_needed
            _power_last_sample=$_now
        fi

        _power_last_status="$_p_status"
        _power_last_level="$_p_level"
        _power_last_charge="$_p_charge"
        _power_prev_is_charging=$_p_is_charging
    }

    _bg_stop_state_get() {
        _bg_stop_pkg="$1"
        _bg_stop_since=0
        _bg_stop_done=0
        [ -s "$BG_STOP_STATE_FILE" ] || return 0
        _bg_stop_line=$(awk -F'|' -v p="$_bg_stop_pkg" '$1 == p { print; exit }' "$BG_STOP_STATE_FILE" 2>/dev/null)
        [ -n "$_bg_stop_line" ] || return 0
        _old_ifs="$IFS"
        IFS='|'
        set -- $_bg_stop_line
        IFS="$_old_ifs"
        case "$2" in ''|*[!0-9]*) _bg_stop_since=0 ;; *) _bg_stop_since="$2" ;; esac
        case "$3" in 1) _bg_stop_done=1 ;; *) _bg_stop_done=0 ;; esac
    }

    _bg_stop_state_set() {
        _bg_stop_pkg="$1"
        _bg_stop_since="$2"
        _bg_stop_done="$3"
        mkdir -p "${BG_STOP_STATE_FILE%/*}" 2>/dev/null
        awk -F'|' -v p="$_bg_stop_pkg" '$1 != p' "$BG_STOP_STATE_FILE" > "${BG_STOP_STATE_FILE}.tmp" 2>/dev/null
        printf '%s|%s|%s\n' "$_bg_stop_pkg" "$_bg_stop_since" "$_bg_stop_done" >> "${BG_STOP_STATE_FILE}.tmp"
        mv "${BG_STOP_STATE_FILE}.tmp" "$BG_STOP_STATE_FILE" 2>/dev/null
    }

    _enforce_stop_after_leave() {
        _bg_stop_next_due=0
        [ "$(bg_read_enabled)" = "on" ] || return 0
        [ "${_screen_off_isolate:-0}" -eq 1 ] 2>/dev/null && return 0
        [ -s "$BG_LIST_FILE" ] || return 0

        _fg_pkg=""
        if [ "$_screen" = "on" ] || [ "${_just_off:-0}" -eq 1 ] 2>/dev/null; then
            _fg_pkg=$(foreground_package_name)
        fi

        while IFS= read -r _line || [ -n "$_line" ]; do
            bg_parse_entry "$_line"
            [ -z "$_bg_pkg" ] && continue
            case "$_bg_pkg" in \#*) continue ;; esac
            [ "$_bg_policy" = "stop_after_leave" ] || continue

            if [ -n "$_fg_pkg" ] && [ "$_fg_pkg" = "$_bg_pkg" ]; then
                _bg_stop_state_set "$_bg_pkg" "$_now" 0
                continue
            fi

            _bg_stop_state_get "$_bg_pkg"
            if [ "$_bg_stop_since" -eq 0 ] 2>/dev/null; then
                continue
            fi

            _delay_sec=$((_bg_delay * 60))
            _elapsed=$((_now - _bg_stop_since))
            if [ "$_elapsed" -ge "$_delay_sec" ] 2>/dev/null; then
                if [ "$_bg_stop_done" -ne 1 ]; then
                    am force-stop "$_bg_pkg" 2>/dev/null
                    _bg_stop_state_set "$_bg_pkg" "$_now" 1
                    log -t pixel9pro_ctrl "L1: force-stopped $_bg_pkg after ${_bg_delay}m away from foreground"
                fi
            else
                _due=$((_delay_sec - _elapsed))
                [ "$_due" -lt 15 ] 2>/dev/null && _due=15
                if [ "$_bg_stop_next_due" -eq 0 ] || [ "$_due" -lt "$_bg_stop_next_due" ]; then
                    _bg_stop_next_due=$_due
                fi
            fi
        done < "$BG_LIST_FILE"
    }

    # NR key detection
    _nr_key="preferred_network_mode1"
    _v=$(settings get global preferred_network_mode1 2>/dev/null | tr -d ' \n\r')
    if [ -z "$_v" ] || [ "$_v" = "null" ]; then
        _nr_key="preferred_network_mode"
    fi
    _cur=$(settings get global "$_nr_key" 2>/dev/null | tr -d ' \n\r')
    if is_nr_mode_value "$_cur"; then
        echo "$_cur" > "$NR_MODE_FILE"
    elif [ ! -s "$NR_MODE_FILE" ]; then
        echo "33" > "$NR_MODE_FILE"
    fi

    _NR_LTE=9
    _mc_state=""
    _cur_slot0=$(_nr_slot0_val "$_cur")
    case "$_cur_slot0" in
        ''|null|*[!0-9-]*) _nr_state="5g" ;;
        *)
            if [ "$_cur_slot0" -lt "$_NR_LTE" ] 2>/dev/null || [ "$_cur_slot0" -eq "$_NR_LTE" ] 2>/dev/null; then
                _nr_state="lte"
            else
                _nr_state="5g"
            fi
            ;;
    esac
    _nr_off_since=0
    _nr_restored=0
    _prev_screen=""
    _just_off=0
    _hist_count=0
    _sim2_check_count=0
    # _NR_DELAY: 屏幕熄灭后多久才切到 LTE-only。
    # 60s 会让短时间锁屏(口袋亮灭/查看消息)反复触发 modem 重注册,
    # 每次 attach/detach 持 s5100_wake_lock ~1-2s。300s 防抖,只在真待机时切。
    _NR_DELAY=300
    _NR_COOLDOWN=600
    # _NR_LTE_POLL: 切换到 LTE 后,worker 多久醒一次检查屏幕状态。
    # 60s 节奏会让 alarmtimer.4.auto 与 suspend 流程挤兑(实测 71 次 failed_suspend)。
    # 300s 把 wakeup 密度降到 12 次/h,给 kernel 真正的 deep suspend 窗口。
    # 代价:屏幕点亮后 NR 恢复最多滞后 5 分钟(用户体感可接受,RIL 数据通道不受影响)。
    _NR_LTE_POLL=300
    _POWER_SAMPLE_INTERVAL_ON=60
    _POWER_SAMPLE_INTERVAL_OFF=600
    _power_last_sample=0
    _power_last_status=""
    _power_last_level=-1
    _power_last_charge=0
    _power_prev_is_charging=0
    _power_charge_since=0
    _power_charge_start_level=0
    _power_charge_seen_full=0
    _power_reset_armed=0
    _power_hist_count=0
    _AUTO_BATTERY_TEMP=40800
    _AUTO_BATTERY_HOLD=90
    _AUTO_BALANCED_COOL_TEMP=40400
    _AUTO_BALANCED_COOL_HOLD=60
    _AUTO_CHARGING_SEV=2
    _AUTO_CHARGING_COMFORT_TEMP=41000
    _AUTO_CHARGING_COMFORT_HOLD=120
    _AUTO_CHARGING_COMFORT_COOL_TEMP=39500
    _AUTO_CHARGING_COMFORT_COOL_HOLD=90
    _auto_hot_since=0
    _auto_cool_since=0
    _auto_charge_hot_since=0
    _auto_charge_cool_since=0
    _active_profile=$(read_valid_profile "$PROFILE_FILE" 'default')
    _cycle_count=0
    _idle_isolate_prev=""

    while true; do
        _now=$(date +%s 2>/dev/null || echo 0)
        _cycle_count=$((_cycle_count + 1))
        _sched_owner=$(read_valid_sched_owner)

        # --- Single screen state check per cycle (sysfs first, IPC-free) ---
        # DRM dpms 是 legacy 属性，仅在 full modeset 时更新 (drm_atomic_helper.c)。
        # Exynos DECON 走 self-refresh 路径不触发 modeset → dpms 永远停在 Off。
        # enabled 检查 encoder 连接状态，每次 atomic commit 无条件更新，可靠。
        _drm_en=$(cat /sys/class/drm/card0-DSI-1/enabled 2>/dev/null)
        case "$_drm_en" in
            enabled) _screen="on" ;;
            disabled) _screen="off" ;;
            *)
                # sysfs 路径异常或早期 boot 阶段：降级到原 IPC 路径
                _scr=$(dumpsys display 2>/dev/null | grep "mScreenState=" | head -1 | sed 's/.*mScreenState=//' | tr -d ' ')
                [ -z "$_scr" ] && _scr=$(dumpsys power 2>/dev/null | grep "mWakefulness=" | head -1 | sed 's/.*mWakefulness=//' | tr -d ' ')
                case "$_scr" in
                    OFF|Dozing|Asleep) _screen="off" ;;
                    *) _screen="on" ;;
                esac
                ;;
        esac
        _idle_isolate=$(read_onoff_file "$IDLE_ISOLATE_FILE" 'off')
        _sim2_auto=$(read_onoff_file "$SIM2_AUTO_FILE" 'on')
        _screen_off_isolate=0
        if [ "$_idle_isolate" = "on" ] && [ "$_screen" = "off" ]; then
            _screen_off_isolate=1
        fi

        if [ "$_idle_isolate" != "$_idle_isolate_prev" ]; then
            log -t pixel9pro_ctrl "Idle isolate: $_idle_isolate"
            _idle_isolate_prev="$_idle_isolate"
        fi

        # --- WiFi multicast: state-transition only ---
        if [ "$_screen" != "$_mc_state" ]; then
            if [ "$_screen" = "off" ]; then
                ip link set wlan0 multicast off 2>/dev/null
            else
                ip link set wlan0 multicast on 2>/dev/null
            fi
            _mc_state="$_screen"
        fi

        # --- Screen transition tracking ---
        if [ "$_screen" = "off" ] && [ "$_prev_screen" = "on" ]; then
            _just_off=1
        elif [ "$_screen" = "on" ] && [ "$_prev_screen" = "off" ]; then
            _just_off=0
        fi
        _prev_screen="$_screen"

        # --- SIM2 radio management (check every ~10 on-screen cycles) ---
        # 只在亮屏时检查: 息屏期间任何 telephony IPC 都会唤醒 modem 打断 kernel suspend。
        # boot 阶段的关闭由 boot+20s / boot+120s / boot+300s 三次一次性尝试保证。
        if [ "$_screen" = "on" ] && [ "$_idle_isolate" != "on" ]; then
            _sim2_check_count=$((_sim2_check_count + 1))
            if [ "$_sim2_check_count" -ge 10 ]; then
                manage_sim2_radio
                _sim2_check_count=0
            fi
        fi

        # --- L2 enforce: 亮屏时每周期校验 vendor_sched 参数 ---
        # 只做 procfs 读写, 零 IPC, 零 wakelock. 参数正确时无操作。
        if [ "$_screen" = "on" ] && [ "$_sched_owner" != "external" ]; then
            sh "$MODDIR/scripts/cpu_profile.sh" enforce "$MODDIR" 2>/dev/null
        fi

        # --- NR screen-off switch ---
        _nr_enabled=$(read_onoff_file "$NR_SWITCH_FILE" 'off')
        if [ "$_screen_off_isolate" -eq 1 ]; then
            _nr_off_since=0
        else
            if [ "$_nr_enabled" != "on" ]; then
                if [ "$_nr_state" = "lte" ]; then
                    settings put global "$_nr_key" "$(cat "$NR_MODE_FILE" 2>/dev/null || echo 33)" 2>/dev/null
                    _nr_state="5g"
                    _nr_restored=$_now
                    log -t pixel9pro_ctrl "NR switch: disabled, restored NR"
                fi
                _nr_off_since=0
            elif [ "$_screen" = "off" ]; then
                if [ "$_nr_state" = "5g" ]; then
                    [ "$_nr_off_since" -eq 0 ] && _nr_off_since=$_now
                    _elapsed=$((_now - _nr_off_since))
                    _since_nr=$((_now - _nr_restored))
                    if [ "$_elapsed" -ge "$_NR_DELAY" ] && [ "$_since_nr" -ge "$_NR_COOLDOWN" ]; then
                        # tethering 检测: 只检查真正的热点/USB 接口是否 UP。
                        # wlan1/wlan2 是 bcmdhd P2P 虚拟接口, Wi-Fi 开启时就存在(state DOWN),
                        # 不代表 tethering。Android 17 Pixel 热点常见桥接接口是 ap_br_wlan*。
                        _tether=0
                        for _tif in swlan0 ap0 softap0 rndis0 ncm0 /sys/class/net/ap_br_wlan* /sys/class/net/ap_br_softap*; do
                            case "$_tif" in /sys/class/net/*) _tif="${_tif##*/}" ;; esac
                            if [ -d "/sys/class/net/$_tif" ]; then
                                _tif_state=$(cat "/sys/class/net/$_tif/operstate" 2>/dev/null)
                                [ "$_tif_state" = "up" ] && _tether=1 && break
                            fi
                        done
                        if [ "$_tether" -eq 0 ]; then
                            _cur=$(settings get global "$_nr_key" 2>/dev/null | tr -d ' \n\r')
                            if is_nr_mode_value "$_cur"; then
                                echo "$_cur" > "$NR_MODE_FILE"
                            fi
                            _lte_val=$(_nr_replace_slot0 "$_cur" "$_NR_LTE")
                            settings put global "$_nr_key" "$_lte_val" 2>/dev/null
                            _nr_state="lte"
                            log -t pixel9pro_ctrl "NR switch: off ${_elapsed}s, switched to LTE ($_lte_val)"
                        fi
                    fi
                fi
            else
                _nr_off_since=0
                if [ "$_nr_state" = "lte" ]; then
                    settings put global "$_nr_key" "$(cat "$NR_MODE_FILE" 2>/dev/null || echo 33)" 2>/dev/null
                    _nr_state="5g"
                    _nr_restored=$_now
                    log -t pixel9pro_ctrl "NR switch: screen on, restored NR"
                fi
            fi
        fi

        # --- Thermal cache + history ---
        # v4.3.16: 息屏深度待机保护 — 跳过 thermal 与前台自动调度采样,
        # 保留 power tracking，避免能耗统计与充电会话重置失真.
        _burst_until=$(cat "$THERMAL_BURST_FILE" 2>/dev/null | tr -d ' \n\r')
        _burst_active=0
        if [ -n "$_burst_until" ] && [ "$_burst_until" -gt "$_now" ] 2>/dev/null; then
            _burst_active=1
        fi
        _burst_effective=$_burst_active
        [ "$_screen_off_isolate" -eq 1 ] && _burst_effective=0

        _worker_mode="deep_standby"
        _vs_temp=""
        if [ "$_screen" = "on" ] || [ "$_burst_effective" -eq 1 ]; then
            _worker_mode="screen_on"
            [ "$_screen" != "on" ] && _worker_mode="thermal_burst"
            # --- 亮屏 / burst: 执行 thermal 更新 ---
            _json=$(build_thermal_json 2>/dev/null)
            if [ -n "$_json" ] && [ "$_json" != "[]" ]; then
                _thermal_tmp="${THERMAL_CACHE}.$$.$_now.tmp"
                printf '%s' "$_json" > "$_thermal_tmp"
                mv "$_thermal_tmp" "$THERMAL_CACHE"

                _vs_temp=$(printf '%s' "$_json" | sed 's/.*VIRTUAL-SKIN","temp":\([0-9]*\).*/\1/')
                if [ -n "$_vs_temp" ] && [ "$_vs_temp" != "$_json" ]; then
                    printf '%s,%s\n' "$_now" "$_vs_temp" >> "$THERMAL_HISTORY"
                    _hist_count=$((_hist_count + 1))
                    if [ "$_hist_count" -ge 360 ]; then
                        _lines=$(wc -l < "$THERMAL_HISTORY" 2>/dev/null)
                        if [ "${_lines:-0}" -gt "$THERMAL_HISTORY_MAX" ]; then
                            _trim=$((_lines - THERMAL_HISTORY_MAX))
                            sed -i "1,${_trim}d" "$THERMAL_HISTORY" 2>/dev/null
                        fi
                        _hist_count=0
                    fi
                fi
            else
                rm -f "${THERMAL_CACHE}.$$.$_now.tmp"
            fi
        fi

        if [ "$_screen_off_isolate" -eq 1 ]; then
            _worker_mode="idle_isolate"
            _auto_hot_since=0
            _auto_cool_since=0
            _auto_charge_hot_since=0
            _auto_charge_cool_since=0
        else
            _track_power_window
            if [ -z "$_vs_temp" ] && [ "$_screen" = "on" ]; then
                _vs_temp=$(sed -n 's/.*VIRTUAL-SKIN","temp":\([0-9]*\).*/\1/p' "$THERMAL_CACHE" 2>/dev/null | head -1)
                case "$_vs_temp" in
                    ''|*[!0-9]*) _vs_temp="" ;;
                esac
            fi

            # --- Slow auto profile policy ---
            _profile_policy=$(read_valid_profile_policy)
            _manual_profile=$(read_valid_profile "$PROFILE_MANUAL_FILE" 'balanced')
            _target_profile=""
            _target_reason=""
            _sev=""

            if [ "$_sched_owner" = "external" ]; then
                _auto_hot_since=0
                _auto_cool_since=0
                _auto_charge_hot_since=0
                _auto_charge_cool_since=0
                printf '%s' 'external_scheduler' > "$PROFILE_AUTO_REASON_FILE"
            elif [ "$_profile_policy" = "manual" ]; then
                _auto_hot_since=0
                _auto_cool_since=0
                _auto_charge_hot_since=0
                _auto_charge_cool_since=0
                if [ "$_screen" = "on" ] && [ "$_active_profile" != "$_manual_profile" ]; then
                    if apply_profile_state "$_manual_profile" "manual_policy"; then
                        _active_profile="$_manual_profile"
                    fi
                fi
            elif [ "$_screen" = "on" ]; then
                if [ "${_p_is_charging:-0}" -eq 1 ] 2>/dev/null; then
                    # 充电态: ADB/线充会抬高壳温, 单看系统 severity 反应偏晚。
                    # 因此拆成两道闸: severity>=MODERATE 立即收口; VIRTUAL-SKIN 体感热只慢切换。
                    _auto_hot_since=0
                    _auto_cool_since=0
                    _sev=$(dumpsys thermalservice 2>/dev/null | grep "Thermal Status:" | head -1 | sed 's/.*Thermal Status:[[:space:]]*//' | tr -d ' \n\r')
                    case "$_sev" in ''|*[!0-9]*) _sev=0 ;; esac
                    if [ "$_sev" -ge "$_AUTO_CHARGING_SEV" ] 2>/dev/null; then
                        _auto_charge_cool_since=0
                        _target_profile="battery"
                        _target_reason="charging_thermal_mitigation"
                    else
                        if [ -n "$_vs_temp" ] && [ "$_vs_temp" -ge "$_AUTO_CHARGING_COMFORT_TEMP" ] 2>/dev/null; then
                            [ "$_auto_charge_hot_since" -eq 0 ] && _auto_charge_hot_since=$_now
                            _auto_charge_cool_since=0
                        elif [ -n "$_vs_temp" ] && [ "$_vs_temp" -le "$_AUTO_CHARGING_COMFORT_COOL_TEMP" ] 2>/dev/null; then
                            [ "$_auto_charge_cool_since" -eq 0 ] && _auto_charge_cool_since=$_now
                            _auto_charge_hot_since=0
                        else
                            _auto_charge_hot_since=0
                            _auto_charge_cool_since=0
                        fi

                        if [ "$_active_profile" = "battery" ] && [ "$_auto_charge_cool_since" -gt 0 ] && [ $((_now - _auto_charge_cool_since)) -ge "$_AUTO_CHARGING_COMFORT_COOL_HOLD" ]; then
                            _target_profile="balanced"
                            _target_reason="charging_comfort_cooldown"
                        elif [ "$_active_profile" = "battery" ]; then
                            _target_profile="battery"
                            _target_reason="charging_comfort_hot"
                        elif [ "$_auto_charge_hot_since" -gt 0 ] && [ $((_now - _auto_charge_hot_since)) -ge "$_AUTO_CHARGING_COMFORT_HOLD" ]; then
                            _target_profile="battery"
                            _target_reason="charging_comfort_hot"
                        else
                            _target_profile="balanced"
                            _target_reason="charging_no_throttle"
                        fi
                    fi
                else
                    # 放电态: 原有 40.8C/90s 软收口 (VIRTUAL-SKIN)
                    _auto_charge_hot_since=0
                    _auto_charge_cool_since=0
                    if [ -n "$_vs_temp" ] && [ "$_vs_temp" -ge "$_AUTO_BATTERY_TEMP" ] 2>/dev/null; then
                        [ "$_auto_hot_since" -eq 0 ] && _auto_hot_since=$_now
                        _auto_cool_since=0
                    elif [ -n "$_vs_temp" ] && [ "$_vs_temp" -le "$_AUTO_BALANCED_COOL_TEMP" ] 2>/dev/null; then
                        [ "$_auto_cool_since" -eq 0 ] && _auto_cool_since=$_now
                        _auto_hot_since=0
                    else
                        _auto_hot_since=0
                        _auto_cool_since=0
                    fi

                    if [ "$_active_profile" = "battery" ] && [ "$_auto_cool_since" -gt 0 ] && [ $((_now - _auto_cool_since)) -ge "$_AUTO_BALANCED_COOL_HOLD" ]; then
                        _target_profile="balanced"
                        _target_reason="hot_cooldown"
                    elif [ "$_auto_hot_since" -gt 0 ] && [ $((_now - _auto_hot_since)) -ge "$_AUTO_BATTERY_HOLD" ]; then
                        _target_profile="battery"
                        _target_reason="steady_hot_guard"
                    else
                        _target_profile="balanced"
                        _target_reason="auto_balanced"
                    fi
                fi

                if [ -n "$_target_profile" ]; then
                    if [ "$_active_profile" != "$_target_profile" ]; then
                        if apply_profile_state "$_target_profile" "$_target_reason"; then
                            _active_profile="$_target_profile"
                        fi
                    else
                        printf '%s' "$_target_reason" > "$PROFILE_AUTO_REASON_FILE"
                    fi
                fi
            else
                # --- 息屏深度待机: 不做前台探测 / 自动调度 ---
                if [ "$_active_profile" != "balanced" ]; then
                    if apply_profile_state "balanced" "deep_standby_reset"; then
                        _active_profile="balanced"
                    fi
                elif [ "$_just_off" -eq 1 ]; then
                    printf '%s' 'deep_standby_reset' > "$PROFILE_AUTO_REASON_FILE"
                fi
                _auto_hot_since=0
                _auto_cool_since=0
                _auto_charge_hot_since=0
                _auto_charge_cool_since=0
            fi
        fi

        _enforce_stop_after_leave

        # --- Adaptive sleep ---
        if [ "$_screen" = "on" ]; then
            _next_sleep_secs=15
        elif [ "$_screen_off_isolate" -eq 1 ]; then
            _just_off=0
            _next_sleep_secs=600
        elif [ "$_just_off" -eq 1 ]; then
            _just_off=0
            _next_sleep_secs=60
        elif [ "$_burst_effective" -eq 1 ]; then
            _next_sleep_secs=5
        elif [ "$_nr_state" = "lte" ]; then
            _next_sleep_secs=$_NR_LTE_POLL
        elif [ "$_nr_enabled" = "on" ] && [ "$_nr_off_since" -gt 0 ] 2>/dev/null; then
            _next_sleep_secs=60
        else
            _next_sleep_secs=600
        fi
        if [ "${_bg_stop_next_due:-0}" -gt 0 ] 2>/dev/null && [ "$_bg_stop_next_due" -lt "$_next_sleep_secs" ] 2>/dev/null; then
            _next_sleep_secs="$_bg_stop_next_due"
        fi
        _diag_profile_policy=$(read_valid_profile_policy)
        _write_standby_diag_state "$_now" "$_screen" "$_worker_mode" "$_next_sleep_secs" "$_burst_effective" "$_nr_enabled" "$_nr_state" "$_diag_profile_policy" "$_active_profile" "$_idle_isolate" "$_sim2_auto" "$_cycle_count"
        sleep "$_next_sleep_secs"
    done
) &
log -t pixel9pro_ctrl "Unified background worker started (Doze-friendly)"

# ──────────────────────────────────────────────────────────
# 5. 启动 HTTP 控制台
# ──────────────────────────────────────────────────────────
BB=""
for _bb in /data/adb/ap/bin/busybox \
            /data/adb/ksu/bin/busybox \
            /data/adb/magisk/busybox \
            /sbin/busybox; do
    [ -x "$_bb" ] && BB="$_bb" && break
done

if [ -z "$BB" ]; then
    _bb=$(command -v busybox 2>/dev/null)
    [ -n "$_bb" ] && [ -x "$_bb" ] && BB="$_bb"
fi

if [ -n "$BB" ]; then
    chmod 755 "$MODDIR/webroot/cgi-bin/"* 2>/dev/null
    stop_webui_httpd
    sleep 1
    if "$BB" nc -z 127.0.0.1 $PORT 2>/dev/null; then
        log -t pixel9pro_ctrl "WARNING: port $PORT already in use"
    else
        "$BB" httpd -p "127.0.0.1:$PORT" -h "$MODDIR/webroot"
        record_webui_httpd_pid
        log -t pixel9pro_ctrl "WebUI(loopback)[$ROOT_IMPL]: http://127.0.0.1:$PORT"
    fi
else
    log -t pixel9pro_ctrl "WARNING[$ROOT_IMPL]: busybox not found"
fi
