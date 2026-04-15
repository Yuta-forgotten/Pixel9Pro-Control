#!/system/bin/sh
##############################################################
# service.sh v3.1 — 开机服务
# 执行时机：late_start（约启动后 8s），以 root 运行
# 流程: 等待启动 → 系统设置优化 → 内核参数 → CPU配置 → WiFi multicast → WebUI
#
# v3.1 变更:
#   - 移除 app 后台限制 (不应该由模块决定)
#   - 新增 WiFi multicast 息屏控制 (参考 RMBD 模块)
#   - 新增 mobile_data_always_on 检查
#   - 内核参数优化保留
##############################################################
MODDIR="${0%/*}"
PORT=6210

# ──────────────────────────────────────────────────────────
# 1. 等待系统完全启动
# ──────────────────────────────────────────────────────────
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
done
sleep 20

# ──────────────────────────────────────────────────────────
# 2. 系统设置优化 (不影响用户体验的项)
# ──────────────────────────────────────────────────────────
log -t pixel9pro_ctrl "v3.1: Applying system optimizations..."

# 确保 mobile_data_always_on 关闭 (modem 休眠关键)
settings put global mobile_data_always_on 0 2>/dev/null

# 关闭附近共享 (减少 BLE/WiFi 扫描, 来自 RMBD 模块)
settings put global nearby_sharing_enabled 0 2>/dev/null
settings put secure nearby_sharing_slice_enabled 0 2>/dev/null

# 内核 I/O 参数优化
echo 3000 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null
echo 50 > /proc/sys/vm/dirty_ratio 2>/dev/null
echo 20 > /proc/sys/vm/dirty_background_ratio 2>/dev/null

log -t pixel9pro_ctrl "v3.1: System optimizations applied"

# ──────────────────────────────────────────────────────────
# 3. 应用 CPU 调度方案 (cpuset + sched_pixel 参数)
# ──────────────────────────────────────────────────────────
PROFILE=$(cat "$MODDIR/.current_profile" 2>/dev/null || echo 'balanced')
sh "$MODDIR/scripts/cpu_profile.sh" "$PROFILE" 2>/dev/null
log -t pixel9pro_ctrl "CPU profile: $PROFILE"

# ──────────────────────────────────────────────────────────
# 4. WiFi multicast 息屏自动关闭 (参考 RMBD_screen_aware)
#    息屏时关闭 multicast 减少 WiFi radio 唤醒
# ──────────────────────────────────────────────────────────
(
    WLAN_IF="wlan0"
    LAST_STATE=""
    while true; do
        # 读取屏幕状态
        SCREEN=$(dumpsys display 2>/dev/null | grep "mScreenState=" | head -1 | sed 's/.*mScreenState=//' | tr -d ' ')
        if [ -z "$SCREEN" ]; then
            SCREEN=$(dumpsys power 2>/dev/null | grep "mWakefulness=" | head -1 | sed 's/.*mWakefulness=//' | tr -d ' ')
        fi

        case "$SCREEN" in
            OFF|Dozing|Asleep)
                if [ "$LAST_STATE" != "off" ]; then
                    ip link set "$WLAN_IF" multicast off 2>/dev/null
                    dumpsys wifi disable-multicast 2>/dev/null
                    LAST_STATE="off"
                fi
                ;;
            *)
                if [ "$LAST_STATE" != "on" ]; then
                    ip link set "$WLAN_IF" multicast on 2>/dev/null
                    LAST_STATE="on"
                fi
                ;;
        esac
        sleep 5
    done
) &
log -t pixel9pro_ctrl "WiFi multicast screen-aware started"

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
    pkill -f "busybox httpd -p $PORT" 2>/dev/null
    sleep 1
    if "$BB" nc -z 127.0.0.1 $PORT 2>/dev/null; then
        log -t pixel9pro_ctrl "WARNING: port $PORT already in use"
    else
        "$BB" httpd -p $PORT -h "$MODDIR/webroot"
        log -t pixel9pro_ctrl "WebUI: http://127.0.0.1:$PORT"
    fi
else
    log -t pixel9pro_ctrl "WARNING: busybox not found"
fi
