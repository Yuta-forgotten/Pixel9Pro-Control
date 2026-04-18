#!/system/bin/sh
##############################################################
# service.sh v4.2.1 — 开机服务 (M3 WebUI + 热区缓存 + 温度历史 + 功耗统计)
# 执行时机：late_start（约启动后 8s），以 root 运行
# 流程: 等待启动 → 系统设置优化 → 内核参数 → CPU配置 → WiFi multicast → WebUI
#
# v3.2.1: 恢复背景图 + 新增轻度模式 + 长按查看模式详情
# v3.2.0 变更:
#   - 小核锁最低频策略 + WebUI优化 + APatch WebView适配
# v3.1.1 变更:
#   - WebUI文案修正(匹配sched_pixel+cpuset实际行为)
#   - CGI安全加固(CONTENT_LENGTH上限/reboot方法检查)
# v3.1 变更:
#   - 移除 app 后台限制 (不应该由模块决定)
#   - 新增 WiFi multicast 息屏控制 (参考 RMBD 模块)
#   - 新增 mobile_data_always_on 检查
#   - 内核参数优化保留
##############################################################
MODDIR="${0%/*}"
PORT=6210
TOKEN_FILE="$MODDIR/.webui_token"
THERMAL_CACHE="$MODDIR/.thermal_cache.json"
LOCKDIR_BASE="$MODDIR/.locks"

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

    # AOSP Settings/Settings app 显示 Adaptive Connectivity 会联动 WifiManager#setWifiScoringEnabled。
    # 关闭它不会改变 5G 注册状态，但可能影响 Wi-Fi/蜂窝自动切换与评分策略。
    # 兼容当前机型实测存在的双键位：旧键 adaptive_connectivity_enabled，新键 adaptive_connectivity_wifi_enabled。
    settings put secure adaptive_connectivity_enabled 0 2>/dev/null
    settings put secure adaptive_connectivity_wifi_enabled 0 2>/dev/null

    # Network recommendations 只影响 NetworkScoreService / recommendation provider，不改变 5G 能力。
    # 关闭后可能削弱系统对候选 Wi-Fi 的推荐与自动评分，因此仅在保 5G 待机分支里作为“可接受副作用”处理。
    settings put global network_recommendations_enabled 0 2>/dev/null
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
log -t pixel9pro_ctrl "v4.2.1: Applying keep-5G standby optimizations..."

# === Modem / 待机优化 (参考 Mori 帖子 + RMBD 模块) ===
# 开机时先应用 keep-5G 分支设置，再由后续延迟复写兜住开机后被系统回写的项目。
apply_keep5g_standby_settings
restore_ntp_server

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
    swapoff /dev/block/zram0 2>/dev/null
    echo 1 > /sys/block/zram0/reset 2>/dev/null
    echo "$TARGET_ALGO" > /sys/block/zram0/comp_algorithm 2>/dev/null
    echo "$TARGET_SIZE" > /sys/block/zram0/disksize 2>/dev/null
    mkswap /dev/block/zram0 >/dev/null 2>&1
    swapon /dev/block/zram0 2>/dev/null
    log -t pixel9pro_ctrl "ZRAM: $TARGET_ALGO $(($TARGET_SIZE / 1048576))MB ready"
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
        ;;
esac

log -t pixel9pro_ctrl "v4.2.1: Keep-5G standby settings applied (radio+kernel+swap+zram)"

# Android 17 / Pixel 组件在用户解锁后仍可能回写部分 secure/global key。
# 对保 5G 分支无直接负面影响的项做一次延迟复写，避免 adaptive connectivity /
# network recommendations 这类设置在 late_start 之后被拉回默认值。
(
    sleep 120
    apply_keep5g_standby_settings
    restore_ntp_server
    log -t pixel9pro_ctrl "Keep-5G standby settings re-applied after late boot"
) &

# ──────────────────────────────────────────────────────────
# 3. 应用 CPU 调度方案 (cpuset + sched_pixel 参数)
# ──────────────────────────────────────────────────────────
PROFILE=$(cat "$MODDIR/.current_profile" 2>/dev/null || echo 'light')
sh "$MODDIR/scripts/cpu_profile.sh" "$PROFILE" "$MODDIR" 2>/dev/null
log -t pixel9pro_ctrl "CPU profile: $PROFILE"

# ──────────────────────────────────────────────────────────
# 4. WiFi multicast 息屏自动关闭 (参考 RMBD_screen_aware)
#    息屏时关闭 multicast 减少 WiFi radio 唤醒
#    息屏 sleep 15s, 亮屏 sleep 5s — 减少无意义唤醒
# ──────────────────────────────────────────────────────────
(
    WLAN_IF="wlan0"
    LAST_STATE=""
    while true; do
        SCREEN=$(dumpsys display 2>/dev/null | grep "mScreenState=" | head -1 | sed 's/.*mScreenState=//' | tr -d ' ')
        [ -z "$SCREEN" ] && SCREEN=$(dumpsys power 2>/dev/null | grep "mWakefulness=" | head -1 | sed 's/.*mWakefulness=//' | tr -d ' ')

        case "$SCREEN" in
            OFF|Dozing|Asleep)
                if [ "$LAST_STATE" != "off" ]; then
                    ip link set "$WLAN_IF" multicast off 2>/dev/null
                    dumpsys wifi disable-multicast 2>/dev/null
                    LAST_STATE="off"
                fi
                sleep 15
                ;;
            *)
                if [ "$LAST_STATE" != "on" ]; then
                    ip link set "$WLAN_IF" multicast on 2>/dev/null
                    LAST_STATE="on"
                fi
                sleep 5
                ;;
        esac
    done
) &
log -t pixel9pro_ctrl "WiFi multicast screen-aware started"

# ──────────────────────────────────────────────────────────
# 4.2 NR 息屏降级 (息屏 → LTE, 亮屏 → 恢复 5G/NR)
#     防抖: 息屏满 60s 后切 LTE; 恢复 NR 后 120s 冷却期不切
#     默认关闭，需通过 WebUI 手动开启
# ──────────────────────────────────────────────────────────
NR_SWITCH_FILE="$MODDIR/.nr_screen_switch"
NR_MODE_FILE="$MODDIR/.nr_saved_mode"
[ -f "$NR_SWITCH_FILE" ] || echo "off" > "$NR_SWITCH_FILE"
(
    _nr_key="preferred_network_mode1"
    _v=$(settings get global preferred_network_mode1 2>/dev/null | tr -d ' \n\r')
    if [ -z "$_v" ] || [ "$_v" = "null" ]; then
        _nr_key="preferred_network_mode"
    fi

    _cur=$(settings get global "$_nr_key" 2>/dev/null | tr -d ' \n\r')
    if [ -n "$_cur" ] && [ "$_cur" != "null" ] && [ "$_cur" -ge 23 ] 2>/dev/null; then
        echo "$_cur" > "$NR_MODE_FILE"
    elif [ ! -s "$NR_MODE_FILE" ]; then
        echo "33" > "$NR_MODE_FILE"
    fi

    _state="5g"
    _off_since=0
    _nr_restored=0
    _DELAY=60
    _COOLDOWN=600
    _LTE=9

    while true; do
        _enabled=$(cat "$NR_SWITCH_FILE" 2>/dev/null)
        _now=$(date +%s 2>/dev/null || echo 0)

        if [ "$_enabled" != "on" ]; then
            if [ "$_state" = "lte" ]; then
                settings put global "$_nr_key" "$(cat "$NR_MODE_FILE" 2>/dev/null || echo 33)" 2>/dev/null
                _state="5g"
                _nr_restored=$_now
                log -t pixel9pro_ctrl "NR switch: disabled, restored NR"
            fi
            _off_since=0
            sleep 15
            continue
        fi

        _scr=$(dumpsys display 2>/dev/null | grep "mScreenState=" | head -1 | sed 's/.*mScreenState=//' | tr -d ' ')
        [ -z "$_scr" ] && _scr=$(dumpsys power 2>/dev/null | grep "mWakefulness=" | head -1 | sed 's/.*mWakefulness=//' | tr -d ' ')

        case "$_scr" in
            OFF|Dozing|Asleep)
                if [ "$_state" = "5g" ]; then
                    [ "$_off_since" -eq 0 ] && _off_since=$_now
                    _elapsed=$((_now - _off_since))
                    _since_nr=$((_now - _nr_restored))
                    if [ "$_elapsed" -ge "$_DELAY" ] && [ "$_since_nr" -ge "$_COOLDOWN" ]; then
                        _tether=0
                        for _tif in swlan0 wlan1 wlan2 ap0 rndis0 ncm0; do
                            [ -d "/sys/class/net/$_tif" ] && _tether=1 && break
                        done
                        if [ "$_tether" -eq 0 ]; then
                            _cur=$(settings get global "$_nr_key" 2>/dev/null | tr -d ' \n\r')
                            [ -n "$_cur" ] && [ "$_cur" != "null" ] && [ "$_cur" -ge 23 ] 2>/dev/null && echo "$_cur" > "$NR_MODE_FILE"
                            settings put global "$_nr_key" "$_LTE" 2>/dev/null
                            _state="lte"
                            log -t pixel9pro_ctrl "NR switch: off ${_elapsed}s, switched to LTE"
                        fi
                    fi
                fi
                sleep 15
                ;;
            *)
                _off_since=0
                if [ "$_state" = "lte" ]; then
                    settings put global "$_nr_key" "$(cat "$NR_MODE_FILE" 2>/dev/null || echo 33)" 2>/dev/null
                    _state="5g"
                    _nr_restored=$_now
                    log -t pixel9pro_ctrl "NR switch: screen on, restored NR"
                fi
                sleep 5
                ;;
        esac
    done
) &
log -t pixel9pro_ctrl "NR screen-aware switch initialized (default: off)"

# ──────────────────────────────────────────────────────────
# 4.1 热区缓存后台任务 + 温度历史持久化 (屏幕感知)
#     busybox httpd 单线程，避免每个 CGI 都同步执行 dumpsys
#     亮屏 5s / 息屏 60s 采集温度，同时追加到 .thermal_history (CSV)
#     历史文件格式: epoch_sec,temp_millideg (VIRTUAL-SKIN)
#     保留最近 8640 条 ≈ 12 小时
# ──────────────────────────────────────────────────────────
THERMAL_HISTORY="$MODDIR/.thermal_history"
THERMAL_HISTORY_MAX=8640
(
    . "$MODDIR/webroot/cgi-bin/_thermal_cache.sh"
    _hist_count=0
    while true; do
        _json=$(build_thermal_json 2>/dev/null)
        if [ -n "$_json" ] && [ "$_json" != "[]" ]; then
            printf '%s' "$_json" > "${THERMAL_CACHE}.tmp"
            mv "${THERMAL_CACHE}.tmp" "$THERMAL_CACHE"

            _vs_temp=$(printf '%s' "$_json" | sed 's/.*VIRTUAL-SKIN","temp":\([0-9]*\).*/\1/')
            if [ -n "$_vs_temp" ] && [ "$_vs_temp" != "$_json" ]; then
                printf '%s,%s\n' "$(date +%s)" "$_vs_temp" >> "$THERMAL_HISTORY"
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
        _scr=$(dumpsys display 2>/dev/null | grep "mScreenState=" | head -1 | sed 's/.*mScreenState=//' | tr -d ' ')
        [ -z "$_scr" ] && _scr=$(dumpsys power 2>/dev/null | grep "mWakefulness=" | head -1 | sed 's/.*mWakefulness=//' | tr -d ' ')
        case "$_scr" in
            OFF|Dozing|Asleep) sleep 60 ;;
            *) sleep 5 ;;
        esac
    done
) &
log -t pixel9pro_ctrl "Thermal cache + history task started (screen-aware)"

# ──────────────────────────────────────────────────────────
# 5. 启动 HTTP 控制台
# ──────────────────────────────────────────────────────────
BB=""
for _bb in /data/adb/ap/bin/busybox \
            /data/adb/magisk/busybox \
            /sbin/busybox; do
    [ -x "$_bb" ] && BB="$_bb" && break
done

if [ -n "$BB" ]; then
    chmod 755 "$MODDIR/webroot/cgi-bin/"* 2>/dev/null
    pkill -f "httpd -p .*${PORT}" 2>/dev/null
    sleep 1
    if "$BB" nc -z 127.0.0.1 $PORT 2>/dev/null; then
        log -t pixel9pro_ctrl "WARNING: port $PORT already in use"
    else
        "$BB" httpd -p "127.0.0.1:$PORT" -h "$MODDIR/webroot"
        log -t pixel9pro_ctrl "WebUI(loopback): http://127.0.0.1:$PORT"
    fi
else
    log -t pixel9pro_ctrl "WARNING: busybox not found"
fi
