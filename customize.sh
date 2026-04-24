#!/system/bin/sh
##############################################################
# customize.sh v4.3.15 — 安装时配置 (APatch / KernelSU / Magisk)
# 检测机型 → 迁移旧设置 → 音量键选择功能 → 温控配置
##############################################################

STOCK_PRO="$MODPATH/system/vendor/etc/thermal_stock.json"
STOCK_XL="$MODPATH/system/vendor/etc/thermal_stock_xl.json"
STOCK_ACTIVE="$MODPATH/system/vendor/etc/thermal_stock.json"
OUT_JSON="$MODPATH/system/vendor/etc/thermal_info_config.json"
OFFSET_FILE="$MODPATH/.thermal_offset"
PROFILE_FILE="$MODPATH/.current_profile"
PROFILE_POLICY_FILE="$MODPATH/.profile_policy"
PROFILE_MANUAL_FILE="$MODPATH/.profile_manual"
DEVICE_FILE="$MODPATH/.device_variant"

OLDDIR="/data/adb/modules/pixel9pro_control"

detect_root_impl() {
    if [ "${APATCH:-}" = "true" ] || [ -d /data/adb/ap ]; then
        echo "APatch"
    elif [ "${KSU:-}" = "true" ] || [ -d /data/adb/ksu ]; then
        echo "KernelSU"
    elif [ -d /data/adb/magisk ]; then
        echo "Magisk"
    else
        echo "Unknown"
    fi
}

# ── Volume Key Functions ──
TMPDIR=${TMPDIR:-/dev/tmp}
mkdir -p "$TMPDIR" 2>/dev/null

_flush_keys() { timeout 1 getevent -qlc 1 >/dev/null 2>&1; }

chooseport() {
    _flush_keys
    while true; do
        /system/bin/getevent -lc 1 2>&1 | /system/bin/grep VOLUME | /system/bin/grep " DOWN" > "$TMPDIR/events"
        if cat "$TMPDIR/events" 2>/dev/null | /system/bin/grep -q VOLUME; then
            cat "$TMPDIR/events" 2>/dev/null | /system/bin/grep -q VOLUMEUP && return 0 || return 1
        fi
    done
}

device=$(getprop ro.product.device 2>/dev/null)
ROOT_IMPL=$(detect_root_impl)

ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print "  Pixel 9 Pro 温控调度控制台"
ui_print "  v4.3.15"
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print "  Root: $ROOT_IMPL"

if [ "$ROOT_IMPL" = "KernelSU" ]; then
    ui_print "  ⚠ KSU 下需先安装 metamodule"
    ui_print "    (meta-overlayfs / Hybrid Mount)"
    ui_print ""
fi

case "$device" in
    komodo)
        ui_print "  机型: Pixel 9 Pro XL (komodo)"
        if [ -f "$STOCK_XL" ]; then
            cp "$STOCK_XL" "$STOCK_ACTIVE"
            ui_print "  ✓ Pro XL 温控配置"
        else
            ui_print "  ✗ XL 配置缺失, 用 Pro 配置"
        fi
        echo "komodo" > "$DEVICE_FILE"
        ;;
    caiman)
        ui_print "  机型: Pixel 9 Pro (caiman)"
        ui_print "  ✓ Pro 默认温控配置"
        echo "caiman" > "$DEVICE_FILE"
        ;;
    *)
        ui_print "  机型: $device (未知)"
        ui_print "  ⚠ 非 Pro/Pro XL, 使用 Pro 配置"
        echo "$device" > "$DEVICE_FILE"
        ;;
esac
ui_print ""

# ── 设置迁移: 从旧模块目录复制用户配置 ──
_is_upgrade=0
if [ -d "$OLDDIR" ] && [ -f "$OLDDIR/module.prop" ]; then
    _is_upgrade=1
    ui_print "  检测到已有配置, 正在迁移..."
    for _sf in .thermal_offset .current_profile .profile_policy .profile_manual .profile_auto_reason .nr_screen_switch \
               .swap_mode .ntp_server .uecap_mode .uecap_manual_mode \
               .uecap_policy .uecap_reason .sim2_radio_off \
               .nr_saved_mode .webui_token; do
        if [ -f "$OLDDIR/$_sf" ]; then
            cp "$OLDDIR/$_sf" "$MODPATH/$_sf" 2>/dev/null
        fi
    done
    ui_print "  ✓ 已迁移用户配置"
    ui_print ""
fi

# ── 首次安装: 音量键功能选择 ──
if [ "$_is_upgrade" -eq 0 ]; then
    ui_print "  首次安装 — 配置向导"
    ui_print "  [音量+] = 下一项  [音量-] = 确认"
    ui_print ""

    # --- 温控偏移 ---
    ui_print "  ① 温控偏移:"
    _OFS_LIST="0 2 4 6"
    _OFS_LABEL_0="+0C (原始)"
    _OFS_LABEL_2="+2C (保守)"
    _OFS_LABEL_4="+4C (日常推荐)"
    _OFS_LABEL_6="+6C (性能)"
    _ofs_idx=2
    _ofs_vals="0 2 4 6"
    set -- $_ofs_vals
    _ofs_total=$#
    while true; do
        shift $((_ofs_idx)) 2>/dev/null || true
        set -- $_ofs_vals
        _i=0; _ofs_cur=""
        for _v in $_ofs_vals; do
            if [ "$_i" -eq "$_ofs_idx" ]; then _ofs_cur=$_v; break; fi
            _i=$((_i + 1))
        done
        eval "_ofs_label=\"\$_OFS_LABEL_${_ofs_cur}\""
        ui_print "    > $_ofs_label"
        if chooseport; then
            _ofs_idx=$(( (_ofs_idx + 1) % _ofs_total ))
        else
            break
        fi
    done
    echo "$_ofs_cur" > "$OFFSET_FILE"
    ui_print "    ✓ $_ofs_label"
    ui_print ""

    # --- CPU 调度 ---
    ui_print "  ② CPU 调度:"
    _CPU_VALS="battery light balanced default responsive"
    _CPU_LABEL_battery="省电"
    _CPU_LABEL_light="长亮屏"
    _CPU_LABEL_balanced="均衡手动"
    _CPU_LABEL_default="默认 (自动基线)"
    _CPU_LABEL_responsive="响应优先"
    _cpu_idx=3
    _cpu_total=5
    while true; do
        _i=0; _cpu_cur=""
        for _v in $_CPU_VALS; do
            if [ "$_i" -eq "$_cpu_idx" ]; then _cpu_cur=$_v; break; fi
            _i=$((_i + 1))
        done
        eval "_cpu_label=\"\$_CPU_LABEL_${_cpu_cur}\""
        ui_print "    > $_cpu_label"
        if chooseport; then
            _cpu_idx=$(( (_cpu_idx + 1) % _cpu_total ))
        else
            break
        fi
    done
    echo "$_cpu_cur" > "$PROFILE_FILE"
    echo "$_cpu_cur" > "$PROFILE_MANUAL_FILE"
    echo "manual" > "$PROFILE_POLICY_FILE"
    echo "manual_install" > "$MODPATH/.profile_auto_reason"
    ui_print "    ✓ $_cpu_label"
    ui_print ""

    # --- UECap 网络能力 ---
    ui_print "  ③ 网络能力配置:"
    _UE_VALS="balanced special universal"
    _UE_LABEL_balanced="国内频段 (推荐)"
    _UE_LABEL_special="全面增强"
    _UE_LABEL_universal="Google 默认"
    _ue_idx=0
    _ue_total=3
    while true; do
        _i=0; _ue_cur=""
        for _v in $_UE_VALS; do
            if [ "$_i" -eq "$_ue_idx" ]; then _ue_cur=$_v; break; fi
            _i=$((_i + 1))
        done
        eval "_ue_label=\"\$_UE_LABEL_${_ue_cur}\""
        ui_print "    > $_ue_label"
        if chooseport; then
            _ue_idx=$(( (_ue_idx + 1) % _ue_total ))
        else
            break
        fi
    done
    echo "$_ue_cur" > "$MODPATH/.uecap_manual_mode"
    echo "$_ue_cur" > "$MODPATH/.uecap_mode"
    echo "manual" > "$MODPATH/.uecap_policy"
    ui_print "    ✓ $_ue_label"
    ui_print ""

    # --- NR 息屏降级 ---
    ui_print "  ④ NR 息屏降级 (息屏自动切 LTE 省电):"
    ui_print "    [音量+] = 关闭  [音量-] = 开启"
    if chooseport; then
        echo "off" > "$MODPATH/.nr_screen_switch"
        ui_print "    ✓ 关闭"
    else
        echo "on" > "$MODPATH/.nr_screen_switch"
        ui_print "    ✓ 开启"
    fi
    ui_print ""

    # --- NTP ---
    ui_print "  ⑤ NTP 服务器:"
    _NTP_VALS="ntp.aliyun.com ntp1.xiaomi.com ntp.myhuaweicloud.com time.android.com"
    _NTP_LABEL_0="阿里云 (推荐)"
    _NTP_LABEL_1="小米"
    _NTP_LABEL_2="华为云"
    _NTP_LABEL_3="Google (默认)"
    _ntp_idx=0
    _ntp_total=4
    while true; do
        _i=0; _ntp_cur=""
        for _v in $_NTP_VALS; do
            if [ "$_i" -eq "$_ntp_idx" ]; then _ntp_cur=$_v; break; fi
            _i=$((_i + 1))
        done
        case "$_ntp_idx" in
            0) _ntp_label="$_NTP_LABEL_0" ;;
            1) _ntp_label="$_NTP_LABEL_1" ;;
            2) _ntp_label="$_NTP_LABEL_2" ;;
            3) _ntp_label="$_NTP_LABEL_3" ;;
        esac
        ui_print "    > $_ntp_label"
        if chooseport; then
            _ntp_idx=$(( (_ntp_idx + 1) % _ntp_total ))
        else
            break
        fi
    done
    echo "$_ntp_cur" > "$MODPATH/.ntp_server"
    ui_print "    ✓ $_ntp_label"
    ui_print ""

    # --- ZRAM 保持默认 (lz77eh + 11392MB) ---
    echo "optimized" > "$MODPATH/.swap_mode"

else
    # 升级模式: 确保必要的默认值存在
    [ -f "$OFFSET_FILE" ] || echo '4' > "$OFFSET_FILE"
    [ -f "$PROFILE_FILE" ] || echo 'default' > "$PROFILE_FILE"
    [ -f "$PROFILE_MANUAL_FILE" ] || cp "$PROFILE_FILE" "$PROFILE_MANUAL_FILE" 2>/dev/null || echo 'default' > "$PROFILE_MANUAL_FILE"
    [ -f "$PROFILE_POLICY_FILE" ] || echo 'auto' > "$PROFILE_POLICY_FILE"
    [ -f "$MODPATH/.profile_auto_reason" ] || echo 'auto_enabled' > "$MODPATH/.profile_auto_reason"
    [ -f "$MODPATH/.uecap_manual_mode" ] || echo 'balanced' > "$MODPATH/.uecap_manual_mode"
    [ -f "$MODPATH/.uecap_mode" ] || echo 'balanced' > "$MODPATH/.uecap_mode"
    [ -f "$MODPATH/.uecap_policy" ] || echo 'manual' > "$MODPATH/.uecap_policy"
    [ -f "$MODPATH/.nr_screen_switch" ] || echo 'off' > "$MODPATH/.nr_screen_switch"
    [ -f "$MODPATH/.swap_mode" ] || echo 'optimized' > "$MODPATH/.swap_mode"
    [ -f "$MODPATH/.ntp_server" ] || echo 'ntp.aliyun.com' > "$MODPATH/.ntp_server"
fi

# ── 应用温控偏移到 thermal_info_config.json ──
offset=$(cat "$OFFSET_FILE" 2>/dev/null | tr -d ' \n\r\t')
case "$offset" in
    0|2|4|6) ;;
    *) offset="4" ;;
esac

awk -v off="$offset" '
/"Name":/ {
    n = $0
    sub(/.*"Name": *"/, "", n)
    sub(/".*/, "", n)
    cur = n
    tgt = (cur == "VIRTUAL-SKIN" || cur == "VIRTUAL-SKIN-HINT" || cur == "VIRTUAL-SKIN-SOC" || cur == "VIRTUAL-SKIN-CPU-LIGHT-ODPM" || cur == "VIRTUAL-SKIN-CPU-MID" || cur == "VIRTUAL-SKIN-CPU-ODPM" || cur == "VIRTUAL-SKIN-CPU-HIGH" || cur == "VIRTUAL-SKIN-GPU")
}
tgt && /"HotThreshold":/ {
    line = $0
    bs = index(line, "[")
    prefix = substr(line, 1, bs - 1)
    rest   = substr(line, bs + 1)
    be     = index(rest, "]")
    inner  = substr(rest, 1, be - 1)
    suffix = substr(rest, be)
    n_v = split(inner, vals, ", ")
    result = ""
    for (i = 1; i <= n_v; i++) {
        v = vals[i]
        if (v != "\"NAN\"") {
            v = sprintf("%.1f", v + off + 0)
        }
        result = result (i > 1 ? ", " : "") v
    }
    print prefix "[" result suffix
    next
}
{ print }
' "$STOCK_ACTIVE" > "$OUT_JSON"

if [ ! -s "$OUT_JSON" ]; then
    cp "$STOCK_ACTIVE" "$OUT_JSON"
    ui_print "  ⚠ 偏移量应用失败, 使用原始配置"
fi

ui_print "  温控偏移: +${offset}°C"
ui_print ""
ui_print "  安装完成, 重启生效"
ui_print "  WebUI: http://127.0.0.1:6210"
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
