#!/system/bin/sh
##############################################################
# service.sh v4.0.0 — 开机服务 (M3 WebUI + 热区缓存)
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
# 2. 系统设置优化 (不影响用户体验的项)
# ──────────────────────────────────────────────────────────
log -t pixel9pro_ctrl "v4.0.0: Applying system optimizations..."

# === Modem 功耗优化 (参考 Mori 帖子 + RMBD 模块) ===
# 确保 mobile_data_always_on 关闭 (modem 休眠关键)
settings put global mobile_data_always_on 0 2>/dev/null

# 关闭 VoWiFi / WiFi Calling (IWLAN 持续搜索注册是 modem 唤醒源)
# 中国广电走 NR SA VoLTE 通话, 不需要 VoWiFi
# 如需恢复: settings put global wfc_ims_enabled 1
settings put global wfc_ims_enabled 0 2>/dev/null

# 开机时先全局关闭 WiFi multicast (RMBD 基础策略)
# 后续由 screen-aware 循环在亮屏时恢复
dumpsys wifi disable-multicast 2>/dev/null
ip link set wlan0 multicast off 2>/dev/null

# === 射频扫描优化 ===
# 关闭附近共享 (减少 BLE/WiFi 扫描, 来自 RMBD 模块)
settings put global nearby_sharing_enabled 0 2>/dev/null
settings put secure nearby_sharing_slice_enabled 0 2>/dev/null

# 确保 WiFi/BLE 后台扫描关闭
settings put global wifi_scan_always_enabled 0 2>/dev/null
settings put global ble_scan_always_enabled 0 2>/dev/null

# 关闭自适应连接 (Pixel 特有, 频繁切换 WiFi/蜂窝增加 modem 活动)
settings put secure adaptive_connectivity_enabled 0 2>/dev/null

# 关闭网络推荐 (减少后台网络评分/切换)
settings put global network_recommendations_enabled 0 2>/dev/null

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

# === Swap / 内存回收调优 (即时生效) ===
# swappiness: 150→100, 减少无效换页(stock 150 在16GB设备上43%页面被无谓换出又换回)
echo 100 > /proc/sys/vm/swappiness 2>/dev/null
# min_free_kbytes: 27MB→64MB, 提前唤醒 kswapd 减少 direct reclaim 和 allocstall
echo 65536 > /proc/sys/vm/min_free_kbytes 2>/dev/null
# vfs_cache_pressure: 100→60, 保留更多 dentry/inode 缓存加速文件路径查找
echo 60 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null

log -t pixel9pro_ctrl "v4.0.0: System optimizations applied (modem+radio+kernel+swap+zram)"

# ──────────────────────────────────────────────────────────
# 3. 应用 CPU 调度方案 (cpuset + sched_pixel 参数)
# ──────────────────────────────────────────────────────────
PROFILE=$(cat "$MODDIR/.current_profile" 2>/dev/null || echo 'light')
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
# 4.1 热区缓存后台任务
#     busybox httpd 单线程，避免每个 CGI 都同步执行 dumpsys
# ──────────────────────────────────────────────────────────
(
    . "$MODDIR/webroot/cgi-bin/_thermal_cache.sh"
    while true; do
        build_thermal_json > "${THERMAL_CACHE}.tmp" 2>/dev/null
        if [ -s "${THERMAL_CACHE}.tmp" ]; then
            mv "${THERMAL_CACHE}.tmp" "$THERMAL_CACHE"
        else
            rm -f "${THERMAL_CACHE}.tmp"
        fi
        sleep 5
    done
) &
log -t pixel9pro_ctrl "Thermal cache task started"

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
