#!/system/bin/sh
##############################################################
# service.sh v4.3.12 — 开机服务 (Doze 友好后台 + M3 WebUI)
# 执行时机：late_start（约启动后 8s），以 root 运行
# 流程: 等待启动 → 系统设置优化 → 内核参数 → CPU配置 → 统一后台 → WebUI
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
TOKEN_FILE="$MODDIR/.webui_token"
THERMAL_CACHE="$MODDIR/.thermal_cache.json"
LOCKDIR_BASE="$MODDIR/.locks"

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

    # adaptive_connectivity / network_recommendations 系统默认已是开启，无需模块管理。
}

manage_sim2_radio() {
    _sim2_state=$(getprop gsm.sim.state 2>/dev/null | sed 's/.*,//')
    case "$_sim2_state" in
        ABSENT|NOT_READY|PIN_REQUIRED|PUK_REQUIRED|PERM_DISABLED)
            _prev_sim2=$(cat "$MODDIR/.sim2_radio_off" 2>/dev/null)
            if [ "$_prev_sim2" != "disabled" ]; then
                cmd phone radio power -s 1 off 2>/dev/null
                cmd phone ims disable -s 1 2>/dev/null
                echo "disabled" > "$MODDIR/.sim2_radio_off"
                log -t pixel9pro_ctrl "SIM2=$_sim2_state: slot 1 radio+ims powered down"
            fi
            ;;
        LOADED|READY)
            _prev_sim2=$(cat "$MODDIR/.sim2_radio_off" 2>/dev/null)
            if [ "$_prev_sim2" = "disabled" ]; then
                cmd phone radio power -s 1 on 2>/dev/null
                cmd phone ims enable -s 1 2>/dev/null
                echo "enabled" > "$MODDIR/.sim2_radio_off"
                log -t pixel9pro_ctrl "SIM2=$_sim2_state: slot 1 radio+ims re-enabled"
            fi
            ;;
    esac
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
if [ ! -s "$TOKEN_FILE" ]; then
    token=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ -n "$token" ] || token="$(date +%s 2>/dev/null)_$$"
    printf '%s' "$token" > "$TOKEN_FILE"
fi
chmod 600 "$TOKEN_FILE" 2>/dev/null

export PIXEL9PRO_MODDIR="$MODDIR"
export PIXEL9PRO_WEBUI_PORT="$PORT"
export PIXEL9PRO_WEBUI_TOKEN_FILE="$TOKEN_FILE"
export PIXEL9PRO_THERMAL_CACHE="$THERMAL_CACHE"
export PIXEL9PRO_LOCKDIR_BASE="$LOCKDIR_BASE"

# ──────────────────────────────────────────────────────────
# 2. 系统设置优化 (保 5G 分支)
# ──────────────────────────────────────────────────────────
log -t pixel9pro_ctrl "v4.3.12[$ROOT_IMPL]: applying keep-5G standby optimizations..."

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
dumpsys wifi disable-multicast 2>/dev/null
ip link set wlan0 multicast off 2>/dev/null

# === 内核 I/O 参数优化 ===
echo 3000 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null
echo 50 > /proc/sys/vm/dirty_ratio 2>/dev/null
echo 20 > /proc/sys/vm/dirty_background_ratio 2>/dev/null

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

log -t pixel9pro_ctrl "v4.3.12[$ROOT_IMPL]: keep-5G standby settings applied (radio+kernel+swap+zram)"

# 延迟复写：NTP 服务器和扫描类设置可能在用户解锁后被系统回写。
(
    sleep 120
    apply_keep5g_standby_settings
    restore_ntp_server
    manage_sim2_radio
    log -t pixel9pro_ctrl "Standby settings re-applied after late boot"
) &

# ──────────────────────────────────────────────────────────
# 3. 应用 CPU 调度方案 (cpuset + sched_pixel 参数)
# ──────────────────────────────────────────────────────────
PROFILE=$(cat "$MODDIR/.current_profile" 2>/dev/null || echo 'balanced')
sh "$MODDIR/scripts/cpu_profile.sh" "$PROFILE" "$MODDIR" 2>/dev/null
log -t pixel9pro_ctrl "CPU profile: $PROFILE"

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

    _write_power_session() {
        _ps_start="$1"
        _ps_level="$2"
        _ps_charge="$3"
        _ps_reason="$4"
        {
            printf 'start_ts=%s\n' "$_ps_start"
            printf 'start_level=%s\n' "$_ps_level"
            printf 'start_charge_uah=%s\n' "${_ps_charge:-0}"
            printf 'reset_reason=%s\n' "$_ps_reason"
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

    _mc_state=""
    _nr_state="5g"
    _nr_off_since=0
    _nr_restored=0
    _prev_screen=""
    _just_off=0
    _hist_count=0
    _sim2_check_count=0
    _NR_DELAY=60
    _NR_COOLDOWN=600
    _NR_LTE=9
    _NR_LTE_POLL=60
    _THERMAL_OFF_INTERVAL=600
    _last_off_thermal=0
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

    while true; do
        _now=$(date +%s 2>/dev/null || echo 0)

        # --- Single screen state check per cycle ---
        _scr=$(dumpsys display 2>/dev/null | grep "mScreenState=" | head -1 | sed 's/.*mScreenState=//' | tr -d ' ')
        [ -z "$_scr" ] && _scr=$(dumpsys power 2>/dev/null | grep "mWakefulness=" | head -1 | sed 's/.*mWakefulness=//' | tr -d ' ')
        case "$_scr" in
            OFF|Dozing|Asleep) _screen="off" ;;
            *) _screen="on" ;;
        esac

        # --- WiFi multicast: state-transition only ---
        if [ "$_screen" != "$_mc_state" ]; then
            if [ "$_screen" = "off" ]; then
                ip link set wlan0 multicast off 2>/dev/null
                dumpsys wifi disable-multicast 2>/dev/null
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
        if [ "$_screen" = "on" ]; then
            _sim2_check_count=$((_sim2_check_count + 1))
            if [ "$_sim2_check_count" -ge 10 ]; then
                manage_sim2_radio
                _sim2_check_count=0
            fi
        fi

        # --- NR screen-off switch ---
        _nr_enabled=$(cat "$NR_SWITCH_FILE" 2>/dev/null)
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
                    _tether=0
                    for _tif in swlan0 wlan1 wlan2 ap0 rndis0 ncm0; do
                        [ -d "/sys/class/net/$_tif" ] && _tether=1 && break
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

        # --- Thermal cache + history ---
        _burst_until=$(cat "$THERMAL_BURST_FILE" 2>/dev/null | tr -d ' \n\r')
        _burst_active=0
        if [ -n "$_burst_until" ] && [ "$_burst_until" -gt "$_now" ] 2>/dev/null; then
            _burst_active=1
        fi

        _do_thermal=0
        if [ "$_screen" = "on" ] || [ "$_burst_active" -eq 1 ]; then
            _do_thermal=1
        elif [ "$_last_off_thermal" -eq 0 ] || [ $((_now - _last_off_thermal)) -ge "$_THERMAL_OFF_INTERVAL" ]; then
            _do_thermal=1
        fi

        if [ "$_do_thermal" -eq 1 ]; then
            _json=$(build_thermal_json 2>/dev/null)
            if [ -n "$_json" ] && [ "$_json" != "[]" ]; then
                printf '%s' "$_json" > "${THERMAL_CACHE}.tmp"
                mv "${THERMAL_CACHE}.tmp" "$THERMAL_CACHE"

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
                rm -f "${THERMAL_CACHE}.tmp"
            fi

            if [ "$_screen" = "off" ]; then
                _last_off_thermal=$_now
            fi
        fi

        _track_power_window

        # --- Adaptive sleep ---
        if [ "$_screen" = "on" ]; then
            sleep 15
        elif [ "$_just_off" -eq 1 ]; then
            _just_off=0
            sleep 60
        elif [ "$_burst_active" -eq 1 ]; then
            sleep 5
        elif [ "$_nr_state" = "lte" ]; then
            sleep "$_NR_LTE_POLL"
        else
            sleep 600
        fi
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
    pkill -f "httpd -p .*${PORT}" 2>/dev/null
    sleep 1
    if "$BB" nc -z 127.0.0.1 $PORT 2>/dev/null; then
        log -t pixel9pro_ctrl "WARNING: port $PORT already in use"
    else
        "$BB" httpd -p "127.0.0.1:$PORT" -h "$MODDIR/webroot"
        log -t pixel9pro_ctrl "WebUI(loopback)[$ROOT_IMPL]: http://127.0.0.1:$PORT"
    fi
else
    log -t pixel9pro_ctrl "WARNING[$ROOT_IMPL]: busybox not found"
fi
