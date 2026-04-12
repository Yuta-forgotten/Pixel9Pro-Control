#!/system/bin/sh
##############################################################
# service.sh — 开机服务：等待启动完成 → 应用 CPU 配置 → 启动 HTTP 服务器
# 执行时机：late_start（约启动后 8s），以 root 运行
##############################################################
MODDIR="${0%/*}"
PORT=6210

# ──────────────────────────────────────────────────────────
# 1. 等待系统完全启动
# ──────────────────────────────────────────────────────────
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
done
# 额外等待 PowerHAL 完成所有启动 hint（避免与 ACPM 冷启动序列冲突）
sleep 20

# ──────────────────────────────────────────────────────────
# 2. 应用上次保存的 CPU 调度方案
# ──────────────────────────────────────────────────────────
PROFILE=$(cat "$MODDIR/.current_profile" 2>/dev/null || echo 'balanced')
sh "$MODDIR/scripts/cpu_profile.sh" "$PROFILE" 2>/dev/null
log -t pixel9pro_ctrl "Auto-applied CPU profile: $PROFILE"

# ──────────────────────────────────────────────────────────
# 3. 启动 HTTP 控制台（busybox httpd，端口 8888）
# ──────────────────────────────────────────────────────────
BB=""
for _bb in /data/adb/ap/bin/busybox \
            /data/adb/magisk/busybox \
            /sbin/busybox; do
    [ -x "$_bb" ] && BB="$_bb" && break
done

if [ -n "$BB" ]; then
    chmod 755 "$MODDIR/webroot/cgi-bin/"* 2>/dev/null
    # 杀掉本模块上次留下的 httpd（避免重复启动），不动其他进程
    pkill -f "busybox httpd -p $PORT" 2>/dev/null
    sleep 1
    # 检查端口是否被占用
    if "$BB" nc -z 127.0.0.1 $PORT 2>/dev/null; then
        log -t pixel9pro_ctrl "WARNING: port $PORT already in use, WebUI not started"
    else
        "$BB" httpd -p $PORT -h "$MODDIR/webroot"
        log -t pixel9pro_ctrl "WebUI started: http://127.0.0.1:$PORT"
    fi
else
    log -t pixel9pro_ctrl "WARNING: busybox not found, WebUI unavailable"
fi
