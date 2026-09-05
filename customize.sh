#!/system/bin/sh
# APatch/KernelSU/Magisk installer: detect the device/root implementation,
# migrate user state, collect first-install choices, and generate thermal JSON.

STOCK_XL="$MODPATH/system/vendor/etc/thermal_stock_xl.json"
STOCK_ACTIVE="$MODPATH/system/vendor/etc/thermal_stock.json"
OUT_JSON="$MODPATH/system/vendor/etc/thermal_info_config.json"
OFFSET_FILE="$MODPATH/.thermal_offset"
PROFILE_FILE="$MODPATH/.current_profile"
PROFILE_POLICY_FILE="$MODPATH/.profile_policy"
PROFILE_MANUAL_FILE="$MODPATH/.profile_manual"
SCHED_OWNER_FILE="$MODPATH/.cpu_sched_owner"
SCHED_OWNER_DESIRED_FILE="$MODPATH/.sched_owner_desired"
GAME_HANDOFF_POLICY_FILE="$MODPATH/.game_handoff_policy"
GAME_HANDOFF_SOURCE_FILE="$MODPATH/.game_handoff_source"
DEVICE_FILE="$MODPATH/.device_variant"

OLDDIR="/data/adb/modules/pixel9pro_control"

# Thermal HAL may select an LPM-specific top-level config at runtime.  The
# selected filename is authoritative; never generate a sibling file that HAL
# will ignore.  LPM stock is read-only from the current device vendor tree.
THERMAL_CONFIG_NAME=$(getprop vendor.thermal.config 2>/dev/null)
[ -n "$THERMAL_CONFIG_NAME" ] || THERMAL_CONFIG_NAME=thermal_info_config.json
case "$THERMAL_CONFIG_NAME" in
    thermal_info_config.json)
        ;;
    thermal_info_config_lpm.json)
        STOCK_ACTIVE="/vendor/etc/$THERMAL_CONFIG_NAME"
        OUT_JSON="$MODPATH/system/vendor/etc/$THERMAL_CONFIG_NAME"
        [ -r "$STOCK_ACTIVE" ] || {
            ui_print "  ✗ 当前 Thermal HAL 配置缺失: $THERMAL_CONFIG_NAME"
            exit 1
        }
        ;;
    *)
        ui_print "  ✗ 不支持的 Thermal HAL 配置: $THERMAL_CONFIG_NAME"
        exit 1
        ;;
esac

if [ ! -r "$MODPATH/scripts/scheduler_detect_lib.sh" ] \
    || ! . "$MODPATH/scripts/scheduler_detect_lib.sh"; then
    ui_print "  ✗ 缺少外部调度检测配置, 已中止安装"
    exit 1
fi
if [ ! -r "$MODPATH/scripts/scheduler_owner_lib.sh" ] \
    || ! . "$MODPATH/scripts/scheduler_owner_lib.sh"; then
    ui_print "  ✗ 缺少调度所有权配置, 已中止安装"
    exit 1
fi
if [ ! -r "$MODPATH/scripts/scheduler_boot_mode_lib.sh" ]; then
    ui_print "  ✗ 缺少调度启动模式配置, 已中止安装"
    exit 1
fi
if [ ! -r "$MODPATH/scripts/runtime_defaults_lib.sh" ]; then
    ui_print "  ✗ 缺少运行默认值配置, 已中止安装"
    exit 1
fi
. "$MODPATH/scripts/runtime_defaults_lib.sh" || exit 1
if [ ! -r "$MODPATH/scripts/display_state_lib.sh" ] \
    || ! . "$MODPATH/scripts/display_state_lib.sh"; then
    ui_print "  ✗ 缺少屏幕状态配置, 已中止安装"
    exit 1
fi

installer_write() {
    if runtime_write_value "$1" "$2"; then
        return 0
    fi
    ui_print "  ✗ 无法写入安装状态: ${1##*/}"
    exit 1
}
if [ ! -r "$MODPATH/scripts/thermal_profile.sh" ]; then
    ui_print "  ✗ 缺少温控配置库, 已中止安装"
    exit 1
fi
. "$MODPATH/scripts/thermal_profile.sh" || exit 1
NTP_CONFIG_FILE="$MODPATH/config/ntp_servers.tsv"
if [ ! -r "$MODPATH/scripts/ntp_config_lib.sh" ] || [ ! -r "$NTP_CONFIG_FILE" ]; then
    ui_print "  ✗ 缺少 NTP 配置, 已中止安装"
    exit 1
fi
. "$MODPATH/scripts/ntp_config_lib.sh" || exit 1
if ! ntp_config_validate; then
    ui_print "  ✗ NTP 配置格式无效, 已中止安装"
    exit 1
fi

detect_root_impl() {
    if [ "${APATCH:-}" = "true" ] || [ -n "${APATCH_VER_CODE:-}" ] || [ -d /data/adb/ap ]; then
        echo "APatch"
    elif [ "${KSU:-}" = "true" ] || [ -n "${KSU_VER_CODE:-}" ] || [ -d /data/adb/ksu ]; then
        echo "KernelSU"
    elif [ -n "${MAGISK_VER_CODE:-}" ] || [ -n "${MAGISK_VER:-}" ] || [ -d /data/adb/magisk ]; then
        echo "Magisk"
    else
        echo "Unknown"
    fi
}

# ── Volume Key Functions ──
TMPDIR=${TMPDIR:-/dev/tmp}
mkdir -p "$TMPDIR" 2>/dev/null || {
    ui_print "  ✗ 无法创建安装临时目录"
    exit 1
}
EVENT_FILE="$TMPDIR/pixel9pro_control_events.$$"
trap 'rm -f "$EVENT_FILE" 2>/dev/null' EXIT
trap 'rm -f "$EVENT_FILE" 2>/dev/null; exit 130' INT
trap 'rm -f "$EVENT_FILE" 2>/dev/null; exit 143' TERM

_flush_keys() { timeout 1 getevent -qlc 1 >/dev/null 2>&1; }

chooseport() {
    _flush_keys
    while true; do
        /system/bin/getevent -lc 1 2>&1 | /system/bin/grep VOLUME | /system/bin/grep " DOWN" > "$EVENT_FILE"
        if /system/bin/grep -q VOLUME "$EVENT_FILE" 2>/dev/null; then
            /system/bin/grep -q VOLUMEUP "$EVENT_FILE" 2>/dev/null && return 0 || return 1
        fi
    done
}

choose_cpu_scheduling() {
    _sch_step="$1"
    detect_uperf_module 2>/dev/null || true
    detect_fas_rs_scheduler 2>/dev/null || true
    if [ "$UPERF_MODULE_ENABLED" = "yes" ]; then
        # UGT is the reboot-selected daily baseline.  If fas-rs is installed,
        # game leases temporarily stop UGT and restore the same UGT baseline.
        installer_write "$SCHED_OWNER_FILE" external
        installer_write "$SCHED_OWNER_DESIRED_FILE" external
        if [ "$FAS_RS_MODULE_ENABLED" = "yes" ]; then
            installer_write "$GAME_HANDOFF_POLICY_FILE" fas_rs
        else
            installer_write "$GAME_HANDOFF_POLICY_FILE" off
        fi
        installer_write "$GAME_HANDOFF_SOURCE_FILE" default
        installer_write "$MODPATH/.profile_auto_reason" external_scheduler
        ui_print "  $_sch_step CPU 调度: 检测到 ${UPERF_MODULE_NAME:-UGT}, 使用 UGT 日常基线"
        [ "$FAS_RS_MODULE_ENABLED" = "yes" ] \
            && ui_print "    fas-rs: 命中游戏时临时接管, 退出后恢复 UGT"
        ui_print ""
        return
    fi

    if [ "$FAS_RS_MODULE_ENABLED" = "yes" ]; then
        installer_write "$GAME_HANDOFF_POLICY_FILE" fas_rs
    else
        installer_write "$GAME_HANDOFF_POLICY_FILE" off
    fi
    installer_write "$GAME_HANDOFF_SOURCE_FILE" default

    # Without UGT there is no valid daily external baseline. fas-rs, when
    # present, remains a game-only temporary handoff.
    ui_print "  $_sch_step CPU 调度:"
    _SCH_VALS="balanced battery default auto"
    _SCH_LABEL_balanced="均衡 (本模块, 日常推荐)"
    _SCH_LABEL_battery="省电 (本模块)"
    _SCH_LABEL_default="系统默认 (本模块, 恢复内核默认 sched_pixel + 出厂 cpuset/cap)"
    _SCH_LABEL_auto="自动 (均衡↔省电, 按温度切换)"
    _sch_idx=0
    _sch_total=4
    while true; do
        _i=0; _sch_cur=""
        for _v in $_SCH_VALS; do
            if [ "$_i" -eq "$_sch_idx" ]; then _sch_cur=$_v; break; fi
            _i=$((_i + 1))
        done
        case "$_sch_cur" in
            balanced) _sch_label="$_SCH_LABEL_balanced" ;;
            battery) _sch_label="$_SCH_LABEL_battery" ;;
            default) _sch_label="$_SCH_LABEL_default" ;;
            auto) _sch_label="$_SCH_LABEL_auto" ;;
        esac
        ui_print "    > $_sch_label"
        if chooseport; then
            _sch_idx=$(( (_sch_idx + 1) % _sch_total ))
        else
            break
        fi
    done
    case "$_sch_cur" in
        auto)
            installer_write "$SCHED_OWNER_FILE" pixel
            installer_write "$SCHED_OWNER_DESIRED_FILE" pixel
            installer_write "$PROFILE_FILE" balanced
            installer_write "$PROFILE_MANUAL_FILE" balanced
            installer_write "$PROFILE_POLICY_FILE" auto
            installer_write "$MODPATH/.profile_auto_reason" auto_install
            ;;
        *)
            installer_write "$SCHED_OWNER_FILE" pixel
            installer_write "$SCHED_OWNER_DESIRED_FILE" pixel
            installer_write "$PROFILE_FILE" "$_sch_cur"
            installer_write "$PROFILE_MANUAL_FILE" "$_sch_cur"
            installer_write "$PROFILE_POLICY_FILE" manual
            installer_write "$MODPATH/.profile_auto_reason" manual_install
            ;;
    esac
    ui_print "    ✓ $_sch_label"
    ui_print ""
}

report_optional_module_inventory() {
    detect_uperf_module 2>/dev/null || true
    detect_fas_rs_scheduler 2>/dev/null || true

    _baseband_state="未检测到"
    for _bb_dir in /data/adb/modules/pixel9pro_baseband_trial /data/adb/modules_update/pixel9pro_baseband_trial; do
        [ -d "$_bb_dir" ] || continue
        _baseband_state="已检测到"
        break
    done

    if [ "$UPERF_DETECTED" = "yes" ]; then
        _ugt_report="已检测到"
    else
        _ugt_report="未检测到"
    fi
    if [ "$FAS_RS_DETECTED" = "yes" ]; then
        _fas_report="已检测到"
    else
        _fas_report="未检测到"
    fi

    ui_print "  可选模块检测（仅报告当前状态）:"
    ui_print "    UGT: $_ugt_report"
    ui_print "    fas-rs: $_fas_report"
    ui_print "    Pixel 9 Pro 基带模块: $_baseband_state"
    ui_print "    不下载、不推荐或引导安装其他模块"
    ui_print ""
}

device=$(getprop ro.product.device 2>/dev/null | tr -d ' \n\r\t')
[ -n "$device" ] || device=$(getprop ro.build.product 2>/dev/null | tr -d ' \n\r\t')
[ -n "$device" ] || device=$(getprop ro.product.vendor.device 2>/dev/null | tr -d ' \n\r\t')
ROOT_IMPL=$(detect_root_impl)
# 安装横幅版本动态取自 module.prop (发行总版本 SoT), 不硬编码; 组件版本见 versions.prop
MOD_VER=$(grep '^version=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2 | tr -d '\r\n "\\')

ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print "  Pixel 9 Pro 温控调度控制台"
ui_print "  ${MOD_VER:-(version 见 module.prop)}"
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print "  Root: $ROOT_IMPL"

if [ "$ROOT_IMPL" = "Unknown" ]; then
    ui_print "  ✗ 无法识别 APatch / KernelSU / Magisk 安装环境"
    exit 1
fi

if [ "$ROOT_IMPL" = "KernelSU" ]; then
    ui_print "  ⚠ KSU 下需先安装 metamodule"
    ui_print "    (meta-overlayfs / Hybrid Mount)"
    ui_print ""
fi

UECAP_DISABLED=0
UECAP_DISABLED_REASON=""
UECAP_EXTERNAL=0
case "$device" in
    komodo)
        ui_print "  机型: Pixel 9 Pro XL (komodo)"
        if [ -f "$STOCK_XL" ]; then
            if cp "$STOCK_XL" "$STOCK_ACTIVE" 2>/dev/null; then
                ui_print "  ✓ Pro XL 温控配置"
            else
                ui_print "  ✗ XL 配置复制失败, 已中止安装"
                exit 1
            fi
        else
            ui_print "  ✗ XL 温控 stock 配置缺失, 已中止安装"
            exit 1
        fi
        # komodo is supported by the device contract, but UECap remains owned
        # by the device's external/stock path. Keep the runtime script for
        # read-only status reporting; only remove the embedded caiman payload.
        UECAP_EXTERNAL=1
        UECAP_DISABLED_REASON="device_external_stock"
        installer_write "$DEVICE_FILE" komodo
        ;;
    caiman)
        ui_print "  机型: Pixel 9 Pro (caiman)"
        ui_print "  ✓ Pro 默认温控配置"
        installer_write "$DEVICE_FILE" caiman
        ;;
    *)
        ui_print "  ✗ 不支持的设备: ${device:-unknown}"
        ui_print "    仅允许 Pixel 9 Pro (caiman) / Pro XL (komodo)"
        exit 1
        ;;
esac
ui_print ""

# Magisk Magic Mount 与 modem cbd 的早期 mmap 存在已验证的启动 race。
# 只有 caiman 的 managed UECap 覆盖在 Magisk 下需要移除运行脚本；komodo
# 保留 read-only external runtime，不把设备原生 stock 错报为不支持。
if [ "$ROOT_IMPL" = "Magisk" ] && [ "$UECAP_EXTERNAL" -eq 0 ]; then
    UECAP_DISABLED=1
    UECAP_DISABLED_REASON="magisk_uecap_unavailable"
fi
if [ "$UECAP_EXTERNAL" -eq 1 ]; then
    ui_print "  ✓ Pro XL UECap 使用设备原生 / external stock"
    rm -f "$MODPATH/system/vendor/firmware/uecapconfig/"* 2>/dev/null \
        || { ui_print "  ✗ 无法移除不适用于 komodo 的内置 UECap payload"; exit 1; }
    rmdir "$MODPATH/system/vendor/firmware/uecapconfig" 2>/dev/null || true
    rmdir "$MODPATH/system/vendor/firmware" 2>/dev/null || true
    [ -f "$MODPATH/uecap_profile.sh" ] \
        || { ui_print "  ✗ external UECap runtime script unexpectedly missing"; exit 1; }
    ui_print "    保留 UECap runtime，仅提供 stock 状态展示，不提供三档写入"
    ui_print ""
elif [ "$UECAP_DISABLED" -eq 1 ]; then
    ui_print "  ⚠ Magisk 下自动停用 caiman UECap 管理"
    ui_print "    reason: $UECAP_DISABLED_REASON"
    ui_print "    (规避 Magic Mount × modem cbd 启动 race)"
    rm -f "$MODPATH/system/vendor/firmware/uecapconfig/"* 2>/dev/null \
        || { ui_print "  ✗ 无法移除不兼容的 UECap payload"; exit 1; }
    rmdir "$MODPATH/system/vendor/firmware/uecapconfig" 2>/dev/null || true
    rmdir "$MODPATH/system/vendor/firmware" 2>/dev/null || true
    rm -f "$MODPATH/uecap_profile.sh" 2>/dev/null \
        || { ui_print "  ✗ 无法移除 UECap 运行脚本"; exit 1; }
    [ ! -e "$MODPATH/uecap_profile.sh" ] \
        || { ui_print "  ✗ UECap 运行脚本仍存在, 已中止安装"; exit 1; }
    ui_print ""
fi

# ── 设置迁移: 从旧模块目录复制用户配置 ──
_is_upgrade=0
if [ -d "$OLDDIR" ] && [ -f "$OLDDIR/module.prop" ]; then
    _is_upgrade=1
    ui_print "  检测到已有配置, 正在迁移..."
    _migration_failed=0
    for _sf in .thermal_offset .current_profile .profile_policy .profile_manual .profile_auto_reason .profile_history .nr_screen_switch \
               .sim2_auto_manage .idle_isolate_mode \
               .swap_mode .swap_custom .ntp_server .uecap_mode .uecap_manual_mode \
               .uecap_policy .uecap_reason .sim2_radio_off \
               .nr_saved_mode .webui_theme \
               .bg_restrict_list .bg_restrict_enabled .bg_restrict_baseline .cpu_sched_owner .sched_owner_desired .game_handoff_policy .game_handoff_source \
               .thermal_history .power_history .power_session; do
        if [ -f "$OLDDIR/$_sf" ]; then
            cp "$OLDDIR/$_sf" "$MODPATH/$_sf" 2>/dev/null \
                && [ -f "$MODPATH/$_sf" ] || _migration_failed=1
        fi
    done
    if [ "$_migration_failed" -ne 0 ]; then
        ui_print "  ✗ 用户配置迁移不完整, 已中止安装"
        exit 1
    fi
    ui_print "  ✓ 已迁移用户配置"
    # Retired light/responsive/performance selections migrate to the current
    # balanced daily baseline. default remains a selectable stock profile.
    _profile_migrated=0
    for _mf in "$MODPATH/.current_profile" "$MODPATH/.profile_manual"; do
        [ -f "$_mf" ] || continue
        case "$(cat "$_mf" 2>/dev/null | tr -d ' \n\r\t')" in
            light|responsive|performance)
                installer_write "$_mf" balanced
                _profile_migrated=1
                ;;
        esac
    done
    [ "$_profile_migrated" -eq 1 ] && ui_print "  ✓ 旧性能档已并入均衡 (省电/均衡/系统默认 三档可在 WebUI 选择)"
    ui_print ""
fi

# ── 首次安装: 音量键功能选择 ──
if [ "$_is_upgrade" -eq 0 ]; then
    report_optional_module_inventory
    ui_print "  首次安装 — 配置向导"
    ui_print "  [音量+] = 下一项  [音量-] = 确认"
    ui_print ""

    # --- 温控阈值: 现行五档 -2 / 0 / +2 / +4 / +6°C ---
    ui_print "  ① 温控偏移:"
    _ofs_idx=0
    _ofs_scan_idx=0
    _ofs_vals="$THERMAL_ALLOWED_OFFSETS"
    for _ofs_scan_value in $_ofs_vals; do
        if [ "$_ofs_scan_value" = "$THERMAL_DEFAULT_OFFSET" ]; then
            _ofs_idx=$_ofs_scan_idx
            break
        fi
        _ofs_scan_idx=$((_ofs_scan_idx + 1))
    done
    set -- $_ofs_vals
    _ofs_total=$#
    while true; do
        _i=0; _ofs_cur=""
        for _v in $_ofs_vals; do
            if [ "$_i" -eq "$_ofs_idx" ]; then _ofs_cur=$_v; break; fi
            _i=$((_i + 1))
        done
        case "$_ofs_cur" in
            -2) _ofs_label="-2°C (提前介入)" ;;
            0)  _ofs_label="0°C (原厂阈值)" ;;
            2)  _ofs_label="+2°C (轻度放宽)" ;;
            4)  _ofs_label="+4°C (日常放宽, 模块默认)" ;;
            6)  _ofs_label="+6°C (最大放宽)" ;;
        esac
        ui_print "    > $_ofs_label"
        if chooseport; then
            _ofs_idx=$(( (_ofs_idx + 1) % _ofs_total ))
        else
            break
        fi
    done
    installer_write "$OFFSET_FILE" "$_ofs_cur"
    ui_print "    ✓ $_ofs_label"
    ui_print ""

    # --- CPU 调度 (外部调度接管 / 本模块均衡·省电 / 自动) ---
    choose_cpu_scheduling "②"


    # --- UECap 网络能力 ---
    if [ "$UECAP_EXTERNAL" -eq 1 ]; then
        ui_print "  ③ 网络能力配置: 跳过 (Pixel 9 Pro XL 使用设备原生 UECap)"
        installer_write "$MODPATH/.uecap_manual_mode" stock
        installer_write "$MODPATH/.uecap_mode" stock
        installer_write "$MODPATH/.uecap_policy" external
        installer_write "$MODPATH/.uecap_reason" device_external_stock
        ui_print ""
    elif [ "$UECAP_DISABLED" -eq 1 ]; then
        ui_print "  ③ 网络能力配置: 跳过 (当前 root 不提供 managed UECap)"
        installer_write "$MODPATH/.uecap_manual_mode" disabled
        installer_write "$MODPATH/.uecap_mode" disabled
        installer_write "$MODPATH/.uecap_policy" disabled
        installer_write "$MODPATH/.uecap_reason" "$UECAP_DISABLED_REASON"
        ui_print ""
    else
    ui_print "  ③ 网络能力配置:"
    _UE_VALS=$(sh "$MODPATH/uecap_profile.sh" modes 2>/dev/null) \
        || { ui_print "  ✗ 无法读取 UECap mode contract"; exit 1; }
    _ue_default=$(sh "$MODPATH/uecap_profile.sh" default 2>/dev/null) \
        || { ui_print "  ✗ 无法读取 UECap default contract"; exit 1; }
    _UE_LABEL_balanced="国内频段 (推荐)"
    _UE_LABEL_special="全面增强"
    _UE_LABEL_universal="Google 默认"
    _ue_idx=0
    _ue_total=0
    _ue_scan_idx=0
    _ue_default_found=0
    for _ue_scan_value in $_UE_VALS; do
        if [ "$_ue_scan_value" = "$_ue_default" ]; then
            _ue_idx=$_ue_scan_idx
            _ue_default_found=1
        fi
        _ue_scan_idx=$((_ue_scan_idx + 1))
        _ue_total=$((_ue_total + 1))
    done
    [ "$_ue_total" -gt 0 ] \
        || { ui_print "  ✗ UECap mode contract 为空"; exit 1; }
    [ "$_ue_default_found" -eq 1 ] \
        || { ui_print "  ✗ UECap default 不在 mode contract 中"; exit 1; }
    while true; do
        _i=0; _ue_cur=""
        for _v in $_UE_VALS; do
            if [ "$_i" -eq "$_ue_idx" ]; then _ue_cur=$_v; break; fi
            _i=$((_i + 1))
        done
        case "$_ue_cur" in
            balanced) _ue_label="$_UE_LABEL_balanced" ;;
            special) _ue_label="$_UE_LABEL_special" ;;
            universal) _ue_label="$_UE_LABEL_universal" ;;
        esac
        ui_print "    > $_ue_label"
        if chooseport; then
            _ue_idx=$(( (_ue_idx + 1) % _ue_total ))
        else
            break
        fi
    done
    installer_write "$MODPATH/.uecap_manual_mode" "$_ue_cur"
    installer_write "$MODPATH/.uecap_mode" "$_ue_cur"
    installer_write "$MODPATH/.uecap_policy" manual
    ui_print "    ✓ $_ue_label"
    ui_print ""
    fi

    # --- NR 息屏降级 ---
    ui_print "  ④ NR 息屏降级 (息屏自动切 LTE 省电):"
    ui_print "    [音量+] = 关闭  [音量-] = 开启"
    if chooseport; then
        installer_write "$MODPATH/.nr_screen_switch" off
        ui_print "    ✓ 关闭"
    else
        installer_write "$MODPATH/.nr_screen_switch" on
        ui_print "    ✓ 开启"
    fi
    ui_print ""

    # --- NTP ---
    ui_print "  ⑤ NTP 服务器:"
    _NTP_VALS=$(ntp_server_hosts)
    set -- $_NTP_VALS
    _ntp_idx=0
    _ntp_total=$#
    [ "$_ntp_total" -gt 0 ] 2>/dev/null || exit 1
    while true; do
        _i=0; _ntp_cur=""
        for _v in $_NTP_VALS; do
            if [ "$_i" -eq "$_ntp_idx" ]; then _ntp_cur=$_v; break; fi
            _i=$((_i + 1))
        done
        _ntp_label=$(ntp_server_label "$_ntp_cur")
        ui_print "    > $_ntp_label"
        if chooseport; then
            _ntp_idx=$(( (_ntp_idx + 1) % _ntp_total ))
        else
            break
        fi
    done
    installer_write "$MODPATH/.ntp_server" "$_ntp_cur"
    ui_print "    ✓ $_ntp_label"
    ui_print ""

    # --- ZRAM / VM 使用共享 contract 的模块默认值 ---
    installer_write "$MODPATH/.swap_mode" "$VM_MODE_DEFAULT"

else
    # 升级模式: 确保必要的默认值存在
    [ -f "$OFFSET_FILE" ] || installer_write "$OFFSET_FILE" "$THERMAL_DEFAULT_OFFSET"
    [ -f "$PROFILE_FILE" ] || installer_write "$PROFILE_FILE" balanced
    if [ ! -f "$PROFILE_MANUAL_FILE" ]; then
        _profile_for_manual=$(cat "$PROFILE_FILE" 2>/dev/null | tr -d ' \n\r\t')
        case "$_profile_for_manual" in balanced|battery|default) ;;
            *) _profile_for_manual=balanced ;;
        esac
        installer_write "$PROFILE_MANUAL_FILE" "$_profile_for_manual"
    fi
    [ -f "$PROFILE_POLICY_FILE" ] || installer_write "$PROFILE_POLICY_FILE" manual
    if [ ! -f "$SCHED_OWNER_FILE" ]; then
        detect_uperf_module 2>/dev/null || true
        if [ "$UPERF_MODULE_ENABLED" = "yes" ]; then
            installer_write "$SCHED_OWNER_FILE" external
            installer_write "$MODPATH/.profile_auto_reason" external_scheduler
            ui_print "  新增设置: 检测到 ${UPERF_MODULE_NAME:-UGT}, CPU 日常调度默认交其接管"
        else
            installer_write "$SCHED_OWNER_FILE" pixel
            ui_print "  新增设置: CPU 调度默认本模块 (可在 WebUI 调整)"
        fi
    else
        _sched_owner=$(cat "$SCHED_OWNER_FILE" 2>/dev/null | tr -d ' \n\r\t')
        case "$_sched_owner" in
            pixel|external) ;;
            *) installer_write "$SCHED_OWNER_FILE" pixel ;;
        esac
    fi
    if [ ! -f "$GAME_HANDOFF_POLICY_FILE" ]; then
        detect_fas_rs_scheduler 2>/dev/null || true
        if [ "$FAS_RS_MODULE_ENABLED" = "yes" ]; then
            installer_write "$GAME_HANDOFF_POLICY_FILE" fas_rs
        else
            installer_write "$GAME_HANDOFF_POLICY_FILE" off
        fi
    fi
    [ -f "$MODPATH/.profile_auto_reason" ] || installer_write "$MODPATH/.profile_auto_reason" manual_policy
    if [ "$UECAP_EXTERNAL" -eq 1 ]; then
        installer_write "$MODPATH/.uecap_manual_mode" stock
        installer_write "$MODPATH/.uecap_mode" stock
        installer_write "$MODPATH/.uecap_policy" external
        installer_write "$MODPATH/.uecap_reason" device_external_stock
    elif [ "$UECAP_DISABLED" -eq 0 ]; then
        _ue_default=$(sh "$MODPATH/uecap_profile.sh" default 2>/dev/null) \
            || { ui_print "  ✗ 无法读取 UECap default contract"; exit 1; }
        [ -f "$MODPATH/.uecap_manual_mode" ] || installer_write "$MODPATH/.uecap_manual_mode" "$_ue_default"
        [ -f "$MODPATH/.uecap_mode" ] || installer_write "$MODPATH/.uecap_mode" "$_ue_default"
        [ -f "$MODPATH/.uecap_policy" ] || installer_write "$MODPATH/.uecap_policy" manual
    fi
    # 不兼容的 root/设备升级时覆盖旧 UECap 状态，避免迁移出不可用档位。
    if [ "$UECAP_EXTERNAL" -eq 1 ]; then
        installer_write "$MODPATH/.uecap_manual_mode" stock
        installer_write "$MODPATH/.uecap_mode" stock
        installer_write "$MODPATH/.uecap_policy" external
        installer_write "$MODPATH/.uecap_reason" device_external_stock
    elif [ "$UECAP_DISABLED" -eq 1 ]; then
        installer_write "$MODPATH/.uecap_manual_mode" disabled
        installer_write "$MODPATH/.uecap_mode" disabled
        installer_write "$MODPATH/.uecap_policy" disabled
        installer_write "$MODPATH/.uecap_reason" "$UECAP_DISABLED_REASON"
    else
        # UECap has no automatic policy. Normalize any retired automatic state so
        # service/WebUI never need to carry the retired branch.
        installer_write "$MODPATH/.uecap_policy" manual
    fi
    [ -f "$MODPATH/.nr_screen_switch" ] || installer_write "$MODPATH/.nr_screen_switch" "$NR_SCREEN_SWITCH_DEFAULT"
    [ -f "$MODPATH/.sim2_auto_manage" ] || installer_write "$MODPATH/.sim2_auto_manage" "$SIM2_AUTO_DEFAULT"
    [ -f "$MODPATH/.idle_isolate_mode" ] || installer_write "$MODPATH/.idle_isolate_mode" "$IDLE_ISOLATE_DEFAULT"
    [ -f "$MODPATH/.swap_mode" ] || installer_write "$MODPATH/.swap_mode" "$VM_MODE_DEFAULT"
    if [ ! -f "$MODPATH/.ntp_server" ]; then
        _ntp_default=$(ntp_server_default) || exit 1
        installer_write "$MODPATH/.ntp_server" "$_ntp_default"
    fi
fi

_offset_raw=$(cat "$OFFSET_FILE" 2>/dev/null | tr -d ' \n\r\t')
offset=$(thermal_normalize_offset "$_offset_raw" "$THERMAL_DEFAULT_OFFSET")
installer_write "$OFFSET_FILE" "$offset"

# Split persistent user intent from the effective runtime owner.  For upgrades
# from v4.4.38 and older, prefer the last explicit WebUI owner action because
# the legacy arbiter could overwrite .cpu_sched_owner after that action.
scheduler_owner_init "$MODPATH" "/data/adb/fas_rs"
if so_migrate_state; then
    detect_uperf_module 2>/dev/null || true
    detect_fas_rs_scheduler 2>/dev/null || true
    _handoff_source=$(so_read_handoff_source)
    if [ "$_handoff_source" != "user" ]; then
        _handoff_default=off
        [ "$FAS_RS_MODULE_ENABLED" = "yes" ] && _handoff_default=fas_rs
        if ! so_write_handoff_preference "$_handoff_default" default; then
            ui_print "  ✗ 无法提交游戏接管默认值, 已中止安装"
            exit 1
        fi
    fi
    if [ "$UPERF_MODULE_ENABLED" = "yes" ]; then
        installer_write "$SCHED_OWNER_DESIRED_FILE" external
        installer_write "$SCHED_OWNER_FILE" external
        ui_print "  CPU 启动模式: UGT 日常基线 (重启后验证), 游戏接管: $(so_read_handoff_policy)"
    else
        installer_write "$SCHED_OWNER_DESIRED_FILE" pixel
        installer_write "$SCHED_OWNER_FILE" pixel
        ui_print "  CPU 启动模式: Pixel (重启后验证), 游戏接管: $(so_read_handoff_policy)"
    fi
else
    if [ ! -f "$SCHED_OWNER_DESIRED_FILE" ]; then
        _desired_fallback=$(cat "$SCHED_OWNER_FILE" 2>/dev/null | tr -d ' \n\r\t')
        case "$_desired_fallback" in pixel|external) ;;
            *) _desired_fallback=pixel ;;
        esac
        installer_write "$SCHED_OWNER_DESIRED_FILE" "$_desired_fallback"
    fi
    [ -f "$GAME_HANDOFF_POLICY_FILE" ] || installer_write "$GAME_HANDOFF_POLICY_FILE" off
    [ -f "$GAME_HANDOFF_SOURCE_FILE" ] || installer_write "$GAME_HANDOFF_SOURCE_FILE" legacy
    ui_print "  ⚠ CPU 调度状态迁移失败, 已使用安全兼容值"
fi

# 从当前机型 stock 基线生成配置; 失败时同步回退文件与状态。
if ! thermal_generate_config "$STOCK_ACTIVE" "$OUT_JSON" "$offset"; then
    if ! cp "$STOCK_ACTIVE" "$OUT_JSON" 2>/dev/null; then
        ui_print "  ✗ 温控配置生成失败, 已中止安装"
        exit 1
    fi
    offset=0
    installer_write "$OFFSET_FILE" 0
    ui_print "  ⚠ 温控配置生成失败, 已回退到出厂阈值"
fi

ui_print "  温控偏移: $(thermal_format_offset "$offset")"
ui_print ""
ui_print "  安装完成, 重启生效"
ui_print "  WebUI: http://127.0.0.1:6210"
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
