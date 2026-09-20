#!/system/bin/sh
# APatch/KernelSU/Magisk installer: detect the device/root implementation,
# migrate user state, collect first-install choices, and generate thermal JSON.

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
INSTALL_TRACE_FILE="$MODPATH/.install_trace"
install_trace() { printf '%s stage=%s rc=%s\n' "$(date +%s)" "$1" "${2:-0}" >> "$INSTALL_TRACE_FILE" 2>/dev/null || true; }
INSTALL_COMPLETE=0
INSTALL_STATE_READY=0
AUDIT_LOG_READY=0
installer_cleanup() {
    _installer_rc="$1"
    rm -f "${EVENT_FILE:-}" 2>/dev/null || true
    if [ "$INSTALL_COMPLETE" -eq 1 ] && [ "$_installer_rc" -eq 0 ]; then
        if command -v meta_module_finish_hook >/dev/null 2>&1; then
            meta_module_finish_hook success || ui_print "  ⚠ MetaModule hook backup cleanup failed"
        fi
        install_trace complete 0
    else
        if command -v meta_module_finish_hook >/dev/null 2>&1; then
            meta_module_finish_hook failed || ui_print "  ✗ MetaModule hook rollback failed"
        fi
        install_trace failed "$_installer_rc"
        [ "$AUDIT_LOG_READY" -eq 1 ] \
            && audit_log_event installer install failure "INSTALL_FAILED_${_installer_rc}" 0 >/dev/null 2>&1 \
            || true
        if [ "$INSTALL_STATE_READY" -eq 1 ]; then
            install_receipt_write failed failed "INSTALL_FAILED_${_installer_rc}" yes >/dev/null 2>&1 || true
        fi
    fi
}
trap 'installer_cleanup "$?"' EXIT
install_trace enter 0

# APD extraction can normalize executable ZIP entries to 0644. Restore
# runtime permissions explicitly before the module is activated.
chmod 755 "$MODPATH/service.sh" "$MODPATH/post-mount.sh" "$MODPATH/scripts/"*.sh "$MODPATH/webroot/cgi-bin/"*.sh 2>/dev/null || true

# Record the Thermal HAL selection without blocking system/disabled policy.
# Custom validates the selected filename immediately before generating overlay.
THERMAL_CONFIG_NAME=$(getprop vendor.thermal.config 2>/dev/null)
[ -n "$THERMAL_CONFIG_NAME" ] || THERMAL_CONFIG_NAME=thermal_info_config.json

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
if [ ! -r "$MODPATH/scripts/install_state_lib.sh" ] \
    || ! . "$MODPATH/scripts/install_state_lib.sh" \
    || ! install_state_init "$MODPATH"; then
    ui_print "  ✗ 缺少安装状态合同, 已中止安装"
    exit 1
fi
INSTALL_STATE_READY=1
if [ -r "$MODPATH/scripts/audit_log_lib.sh" ] \
    && . "$MODPATH/scripts/audit_log_lib.sh" \
    && audit_log_init "$MODPATH"; then
    AUDIT_LOG_READY=1
else
    ui_print "  ✗ 无法初始化隐私安全审计日志"
    exit 1
fi
if [ ! -r "$MODPATH/scripts/scheduler_capability_lib.sh" ] \
    || ! . "$MODPATH/scripts/scheduler_capability_lib.sh" \
    || ! scheduler_capability_init "$MODPATH"; then
    ui_print "  ✗ 缺少调度能力合同, 已中止安装"
    exit 1
fi
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
if [ ! -r "$MODPATH/scripts/thermal_policy_lib.sh" ] \
    || ! . "$MODPATH/scripts/thermal_policy_lib.sh" \
    || ! thermal_policy_init "$MODPATH"; then
    ui_print "  ✗ 缺少温控策略合同, 已中止安装"
    exit 1
fi
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
trap 'rm -f "$EVENT_FILE" 2>/dev/null; exit 130' INT
trap 'rm -f "$EVENT_FILE" 2>/dev/null; exit 143' TERM

_flush_keys() { timeout 1 getevent -qlc 1 >/dev/null 2>&1; }

chooseport() {
    _flush_keys
    # APD/automation often has no physical key event stream. Avoid spending
    # 30s per prompt there; retain the displayed default immediately.
    if [ "${PIXEL9PRO_NONINTERACTIVE:-0}" = "1" ] || [ ! -c /dev/input/event0 ]; then
        return 1
    fi
    # A visible bounded countdown prevents headless installs from hanging.
    # Timeout confirms the currently displayed safe default.
    _key_remaining=30
    while [ "$_key_remaining" -gt 0 ]; do
        case "$_key_remaining" in 30|20|10|5|4|3|2|1) ui_print "      剩余 ${_key_remaining} 秒" ;; esac
        : > "$EVENT_FILE" 2>/dev/null || return 1
        timeout 1 /system/bin/getevent -qlc 1 > "$EVENT_FILE" 2>/dev/null || true
        if /system/bin/grep -q VOLUME "$EVENT_FILE" 2>/dev/null \
            && /system/bin/grep -q " DOWN" "$EVENT_FILE" 2>/dev/null; then
            /system/bin/grep -q VOLUMEUP "$EVENT_FILE" 2>/dev/null && return 0
            return 1
        fi
        _key_remaining=$((_key_remaining - 1))
    done
    ui_print "    （30 秒未检测到音量键，保留当前默认值）"
    return 1
}

choose_cpu_scheduling() {
    _sch_step="$1"
    ui_print "  $_sch_step CPU 调度控制:"
    _scheduler_mode_vals="active off"
    _scheduler_mode_idx=0
    while true; do
        _i=0; _scheduler_mode=""
        for _v in $_scheduler_mode_vals; do
            if [ "$_i" -eq "$_scheduler_mode_idx" ]; then _scheduler_mode=$_v; break; fi
            _i=$((_i + 1))
        done
        case "$_scheduler_mode" in
            active) _scheduler_mode_label="启用本模块性能调度" ;;
            off) _scheduler_mode_label="不启用本模块调度 (停止全部调度写入)" ;;
        esac
        ui_print "    > $_scheduler_mode_label"
        if chooseport; then
            _scheduler_mode_idx=$(( (_scheduler_mode_idx + 1) % 2 ))
        else
            break
        fi
    done
    scheduler_mode_write "$_scheduler_mode" \
        || { ui_print "  ✗ 无法提交调度模式"; exit 1; }
    if [ "$_scheduler_mode" = off ]; then
        scheduler_capability_probe readonly \
            && scheduler_capability_commit \
            || { ui_print "  ✗ 无法记录调度关闭 receipt"; exit 1; }
        installer_write "$PROFILE_FILE" default
        installer_write "$PROFILE_MANUAL_FILE" default
        installer_write "$PROFILE_POLICY_FILE" manual
        installer_write "$MODPATH/.profile_auto_reason" scheduler_mode_off
        ui_print "    ✓ $_scheduler_mode_label"
        ui_print ""
        return
    fi

    if ! scheduler_capability_probe verify \
        || ! scheduler_capability_commit \
        || [ "$SCHED_CAPABILITY" != supported ]; then
        scheduler_mode_write off \
            || { ui_print "  ✗ 无法关闭不兼容调度控制面"; exit 1; }
        installer_write "$PROFILE_FILE" default
        installer_write "$PROFILE_MANUAL_FILE" default
        installer_write "$PROFILE_POLICY_FILE" manual
        installer_write "$MODPATH/.profile_auto_reason" scheduler_capability_off
        ui_print "  $_sch_step CPU 调度: 能力不完整，本模块调度已关闭"
        ui_print "    capability=${SCHED_CAPABILITY:-unknown}"
        ui_print ""
        return
    fi

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
export PIXEL9PRO_MODDIR="$MODPATH"
if [ ! -r "$MODPATH/uecap_profile.sh" ] \
    || ! . "$MODPATH/uecap_profile.sh"; then
    ui_print "  ✗ 缺少 UECap 运行合同, 已中止安装"
    exit 1
fi
if [ "$ROOT_IMPL" = "APatch" ] || [ "$ROOT_IMPL" = "KernelSU" ]; then
    if ! uecap_active_metamodule; then
        ui_print "  ✗ APatch/KernelSU 安装必须先启用并重启 MetaModule"
        exit 1
    fi
    _meta_target=$(uecap_meta_target 2>/dev/null) || {
        ui_print "  ✗ 无法解析活动 MetaModule target"
        exit 1
    }
    mountpoint -q "$_meta_target/mnt" 2>/dev/null || {
        ui_print "  ✗ MetaModule content image 未挂载，拒绝继续安装"
        exit 1
    }
    if [ ! -r "$MODPATH/scripts/metamodule_compat.sh" ] \
        || ! . "$MODPATH/scripts/metamodule_compat.sh"; then
        ui_print "  ✗ 当前 MetaModule hook 未通过 context contract，拒绝安装"
        ui_print "    需要支持 canonical SELinux context 的 MetaModule"
        exit 1
    fi
    if uecap_meta_content_exists; then
        ui_print "  ✗ 检测到旧 Control content image；必须先卸载旧 Control、重启，再安装本包"
        exit 1
    fi
fi
case "$device" in
    komodo)
        ui_print "  机型: Pixel 9 Pro XL (komodo)"
        ui_print "  ✓ Pro XL 温控使用运行时 vendor 基线"
        ui_print "  ✓ Pro XL UECap 默认 stock，可显式选择单文件 candidate"
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
install_state_write root_family "$INSTALL_ROOT_FAMILY_FILE" "$(install_state_root_value "$ROOT_IMPL")" \
    || { ui_print "  ✗ 无法写入 Root 状态"; exit 1; }
ui_print ""

# Magisk Magic Mount 与 modem cbd 的早期 mmap 存在已验证的启动 race。
# staging payload 可保留在模块私有目录，但 Magisk 不执行任何 UECap bind。
if [ "$ROOT_IMPL" = "Magisk" ]; then
    UECAP_DISABLED=1
    UECAP_DISABLED_REASON="magisk_uecap_unavailable"
elif { [ "$ROOT_IMPL" = "APatch" ] || [ "$ROOT_IMPL" = "KernelSU" ]; } \
    && [ "$UECAP_RUNTIME_POLICY" != "managed_profiles" ] \
    && [ "$UECAP_RUNTIME_POLICY" != "single_candidate" ]; then
    UECAP_DISABLED=1
    UECAP_DISABLED_REASON="${UECAP_STATUS_REASON:-metamodule_required}"
fi
if [ "$UECAP_DISABLED" -eq 1 ]; then
    case "$UECAP_DISABLED_REASON" in
        magisk_uecap_unavailable)
            ui_print "  ⚠ Magisk 下自动停用 UECap 激活"
            ;;
        metamodule_required)
            ui_print "  ⚠ APatch/KernelSU 未检测到活动 MetaModule，UECap 保持 stock"
            ;;
    esac
    ui_print "    reason: $UECAP_DISABLED_REASON"
    [ "$UECAP_DISABLED_REASON" != magisk_uecap_unavailable ] \
        || ui_print "    (规避 Magic Mount × modem cbd 启动 race)"
    ui_print ""
fi

# ── 设置迁移: 从旧模块目录复制用户配置 ──
_is_upgrade=0
if [ -d "$OLDDIR" ] && [ -f "$OLDDIR/module.prop" ]; then
    _is_upgrade=1
    ui_print "  检测到已有配置, 正在迁移..."
    _migration_failed=0
    for _sf in .thermal_offset .thermal_policy .current_profile .profile_policy .profile_manual .profile_auto_reason .profile_history .nr_screen_switch \
               .sim2_auto_manage .idle_isolate_mode \
               .swap_mode .swap_custom .ntp_server .uecap_manual_mode \
               .uecap_policy .uecap_reason .webui_theme \
               .bg_restrict_list .bg_restrict_enabled .bg_restrict_baseline .sched_owner_desired .game_handoff_policy .game_handoff_source \
               .uecap_content_image .uecap_backend \
               .scheduler_mode .scheduler_policy .scheduler_profile \
               .feature_nr .feature_sim2 .feature_vm .feature_power_export .state_schema \
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

install_trace migration 0
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

    # --- 温控策略: system 是零覆盖安全默认；custom 才生成 overlay。 ---
    ui_print "  ① 温控策略:"
    _thermal_policy_vals="$THERMAL_ALLOWED_POLICIES"
    _thermal_policy_idx=0
    _thermal_policy_total=2
    while true; do
        _i=0; _thermal_policy=""
        for _v in $_thermal_policy_vals; do
            if [ "$_i" -eq "$_thermal_policy_idx" ]; then _thermal_policy=$_v; break; fi
            _i=$((_i + 1))
        done
        case "$_thermal_policy" in
            system) _thermal_policy_label="不修改温控 (推荐，不添加配置)" ;;
            custom) _thermal_policy_label="自定义温控偏移" ;;
        esac
        ui_print "    > $_thermal_policy_label"
        if chooseport; then
            _thermal_policy_idx=$(( (_thermal_policy_idx + 1) % _thermal_policy_total ))
        else
            break
        fi
    done
    installer_write "$MODPATH/.thermal_policy" "$_thermal_policy"
    ui_print "    ✓ $_thermal_policy_label"
    ui_print ""

    # --- custom 只选择真正改变阈值的 -2 / +2 / +4 / +6°C。 ---
    _ofs_idx=0
    _ofs_vals="$THERMAL_UI_OFFSETS"
    _ofs_scan_idx=0
    for _ofs_scan_value in $_ofs_vals; do
        if [ "$_ofs_scan_value" = "$THERMAL_DEFAULT_OFFSET" ]; then
            _ofs_idx=$_ofs_scan_idx
            break
        fi
        _ofs_scan_idx=$((_ofs_scan_idx + 1))
    done
    set -- $_ofs_vals
    _ofs_total=$#
    _ofs_cur="$THERMAL_DEFAULT_OFFSET"
    if [ "$_thermal_policy" = custom ]; then
        ui_print "  ①a 自定义温控偏移:"
        while true; do
            _i=0; _ofs_cur=""
            for _v in $_ofs_vals; do
                if [ "$_i" -eq "$_ofs_idx" ]; then _ofs_cur=$_v; break; fi
                _i=$((_i + 1))
            done
            case "$_ofs_cur" in
                -2) _ofs_label="-2°C (提前介入)" ;;
                2)  _ofs_label="+2°C (轻度放宽)" ;;
                4)  _ofs_label="+4°C (日常放宽)" ;;
                6)  _ofs_label="+6°C (最大放宽)" ;;
            esac
            ui_print "    > $_ofs_label"
            if chooseport; then
                _ofs_idx=$(( (_ofs_idx + 1) % _ofs_total ))
            else
                break
            fi
        done
        ui_print "    ✓ $_ofs_label"
        ui_print ""
    fi
    installer_write "$OFFSET_FILE" "$_ofs_cur"

    # --- CPU 调度 (外部调度接管 / 本模块均衡·省电 / 自动) ---
    choose_cpu_scheduling "②"


    # --- UECap 网络能力 ---
    if [ "$UECAP_DISABLED" -eq 1 ]; then
        ui_print "  ③ 网络能力配置: 跳过 (当前 root 不提供 managed UECap)"
        installer_write "$MODPATH/.uecap_manual_mode" disabled
        installer_write "$MODPATH/.uecap_mode" disabled
        installer_write "$MODPATH/.uecap_policy" disabled
        installer_write "$MODPATH/.uecap_reason" "$UECAP_DISABLED_REASON"
        ui_print ""
    else
    ui_print "  ③ 网络能力配置:"
    sh "$MODPATH/uecap_profile.sh" validate >/dev/null 2>&1 \
        || { ui_print "  ✗ 当前 SKU 的 UECap payload/hash 合同无效"; exit 1; }
    _UE_VALS=$(sh "$MODPATH/uecap_profile.sh" modes 2>/dev/null) \
        || { ui_print "  ✗ 无法读取 UECap mode contract"; exit 1; }
    _ue_default=$(sh "$MODPATH/uecap_profile.sh" default 2>/dev/null) \
        || { ui_print "  ✗ 无法读取 UECap default contract"; exit 1; }
    _ue_policy=$(sh "$MODPATH/uecap_profile.sh" policy 2>/dev/null) \
        || { ui_print "  ✗ 无法读取 UECap policy contract"; exit 1; }
    _UE_LABEL_balanced="国内频段 (推荐)"
    _UE_LABEL_special="全面增强"
    _UE_LABEL_universal="Google 默认"
    _UE_LABEL_stock="保持 XL 系统原生 (默认)"
    _UE_LABEL_candidate="XL 单文件 candidate (测试，未完成实机验证)"
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
            stock) _ue_label="$_UE_LABEL_stock" ;;
            candidate) _ue_label="$_UE_LABEL_candidate" ;;
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
    installer_write "$MODPATH/.uecap_policy" "$_ue_policy"
    installer_write "$MODPATH/.uecap_reason" install_choice
    ui_print "    ✓ $_ue_label"
    ui_print ""
    fi

    # --- NR 息屏降级 ---
    ui_print "  ④ NR 息屏降级 (息屏自动切 LTE 省电):"
    _nr_vals="off on"
    _nr_idx=0
    while true; do
        _i=0; _nr_choice=""
        for _v in $_nr_vals; do
            if [ "$_i" -eq "$_nr_idx" ]; then _nr_choice=$_v; break; fi
            _i=$((_i + 1))
        done
        [ "$_nr_choice" = on ] && _nr_label="开启" || _nr_label="关闭 (安全默认)"
        ui_print "    > $_nr_label"
        if chooseport; then _nr_idx=$(( (_nr_idx + 1) % 2 )); else break; fi
    done
    installer_write "$MODPATH/.nr_screen_switch" "$_nr_choice"
    ui_print "    ✓ $_nr_label"
    ui_print ""

    # --- SIM2 空槽管理 ---
    ui_print "  ⑤ SIM2 空槽管理:"
    _sim2_vals="on off"
    _sim2_idx=0
    while true; do
        _i=0; _sim2_choice=""
        for _v in $_sim2_vals; do
            if [ "$_i" -eq "$_sim2_idx" ]; then _sim2_choice=$_v; break; fi
            _i=$((_i + 1))
        done
        [ "$_sim2_choice" = on ] && _sim2_label="开启 (空槽自动管理)" || _sim2_label="关闭"
        ui_print "    > $_sim2_label"
        if chooseport; then _sim2_idx=$(( (_sim2_idx + 1) % 2 )); else break; fi
    done
    installer_write "$MODPATH/.sim2_auto_manage" "$_sim2_choice"
    ui_print "    ✓ $_sim2_label"
    ui_print ""

    # --- VM/ZRAM 策略 ---
    ui_print "  ⑥ VM/ZRAM 策略:"
    _vm_vals="system optimized disabled"
    _vm_idx=0
    while true; do
        _i=0; _vm_choice=""
        for _v in $_vm_vals; do
            if [ "$_i" -eq "$_vm_idx" ]; then _vm_choice=$_v; break; fi
            _i=$((_i + 1))
        done
        case "$_vm_choice" in
            system) _vm_label="系统默认 (推荐，不写 VM/ZRAM)" ;;
            optimized) _vm_label="模块优化" ;;
            disabled) _vm_label="禁用本模块 VM/ZRAM 写入" ;;
        esac
        ui_print "    > $_vm_label"
        if chooseport; then _vm_idx=$(( (_vm_idx + 1) % 3 )); else break; fi
    done
    case "$_vm_choice" in system) _swap_choice=stock ;; *) _swap_choice="$_vm_choice" ;; esac
    installer_write "$MODPATH/.swap_mode" "$_swap_choice"
    install_state_write feature_vm "$INSTALL_FEATURE_VM_FILE" "$_vm_choice" \
        || { ui_print "  ✗ 无法提交 VM feature 状态"; exit 1; }
    ui_print "    ✓ $_vm_label"
    ui_print ""

    # --- NTP ---
    ui_print "  ⑦ NTP 服务器:"
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
    # Root/SKU 变化时只迁移仍属于当前设备合同的 desired mode。
    if [ "$UECAP_DISABLED" -eq 1 ]; then
        installer_write "$MODPATH/.uecap_manual_mode" disabled
        installer_write "$MODPATH/.uecap_mode" disabled
        installer_write "$MODPATH/.uecap_policy" disabled
        installer_write "$MODPATH/.uecap_reason" "$UECAP_DISABLED_REASON"
    else
        sh "$MODPATH/uecap_profile.sh" validate >/dev/null 2>&1 \
            || { ui_print "  ✗ 当前 SKU 的 UECap payload/hash 合同无效"; exit 1; }
        _UE_VALS=$(sh "$MODPATH/uecap_profile.sh" modes 2>/dev/null) \
            || { ui_print "  ✗ 无法读取 UECap mode contract"; exit 1; }
        _ue_default=$(sh "$MODPATH/uecap_profile.sh" default 2>/dev/null) \
            || { ui_print "  ✗ 无法读取 UECap default contract"; exit 1; }
        _ue_policy=$(sh "$MODPATH/uecap_profile.sh" policy 2>/dev/null) \
            || { ui_print "  ✗ 无法读取 UECap policy contract"; exit 1; }
        _ue_migrated=$(cat "$MODPATH/.uecap_manual_mode" 2>/dev/null | tr -d ' \r\n\t')
        _ue_migrated_valid=0
        for _ue_allowed in $_UE_VALS; do
            [ "$_ue_allowed" = "$_ue_migrated" ] && _ue_migrated_valid=1 && break
        done
        [ "$_ue_migrated_valid" -eq 1 ] || _ue_migrated="$_ue_default"
        installer_write "$MODPATH/.uecap_manual_mode" "$_ue_migrated"
        installer_write "$MODPATH/.uecap_mode" "$_ue_migrated"
        installer_write "$MODPATH/.uecap_policy" "$_ue_policy"
        installer_write "$MODPATH/.uecap_reason" upgrade_migrated
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

if [ "$UECAP_DISABLED" -eq 0 ] \
    && [ "$UECAP_BACKEND" = "metamodule_content" ]; then
    _stage_mode=$(cat "$MODPATH/.uecap_mode" 2>/dev/null | tr -d ' \r\n\t')
    PIXEL9PRO_MODDIR="$MODPATH" sh "$MODPATH/uecap_profile.sh" stage "$_stage_mode"
    _stage_rc=$?
    if [ "$_stage_rc" -eq 2 ]; then
        ui_print "  ✗ 检测到旧 MetaModule content image；必须先卸载旧 Control、重启，再安装本包"
        exit 1
    elif [ "$_stage_rc" -ne 0 ]; then
        ui_print "  ✗ 无法将 UECap 写入 MetaModule content image staging"
        exit 1
    fi
    ui_print "  UECap: $_stage_mode 已写入 MetaModule content image staging，重启后复读有效 /vendor"
fi

_offset_raw=$(cat "$OFFSET_FILE" 2>/dev/null | tr -d ' \n\r\t')
offset=$(thermal_normalize_offset "$_offset_raw" "$THERMAL_DEFAULT_OFFSET")
installer_write "$OFFSET_FILE" "$offset"

# Split persistent user intent from the effective runtime owner.  For upgrades
# from v4.4.38 and older, prefer the last explicit WebUI owner action because
# the legacy arbiter could overwrite .cpu_sched_owner after that action.
if [ "$_is_upgrade" -eq 1 ]; then
    scheduler_capability_enforce_mode readonly >/dev/null 2>&1 \
        || scheduler_mode_write off >/dev/null 2>&1 \
        || { ui_print "  ✗ 无法 fail closed 调度模式"; exit 1; }
fi
scheduler_owner_init "$MODPATH" "/data/adb/fas_rs"
if ! scheduler_mode_is_active; then
    ui_print "  CPU 调度: 本模块已关闭，不迁移或创建 owner/worker 状态"
elif so_migrate_state; then
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
if ! install_state_sync_legacy "$ROOT_IMPL"; then
    ui_print "  ✗ 无法提交功能状态合同, 已中止安装"
    exit 1
fi
install_state_print_summary
if [ "$_is_upgrade" -eq 0 ]; then
    ui_print "  最终提交: [音量+] = 取消  [音量-] = 确认"
    if chooseport; then
        ui_print "  已取消安装"
        exit 130
    fi
    ui_print "  ✓ 已确认最终配置"
    ui_print ""
fi

INSTALL_REASON_CODE=INSTALL_COMMITTED
THERMAL_POLICY=$(thermal_policy_read)
stage_vendor_context() {
    _stage_file="$1"
    _stage_ref="${2:-/vendor/etc/thermal_info_config.json}"
    [ -f "$_stage_file" ] || return 1
    [ -e "$_stage_ref" ] || return 1
    chcon --reference=/vendor "$MODPATH/system/vendor" 2>/dev/null || return 1
    chcon --reference=/vendor/etc "${_stage_file%/*}" 2>/dev/null || return 1
    chcon --reference="$_stage_ref" "$_stage_file" 2>/dev/null || return 1
    [ "$(ls -Zd "$_stage_file" 2>/dev/null | awk '{print $1}')" = \
        "$(ls -Zd "$_stage_ref" 2>/dev/null | awk '{print $1}')" ]
}
case "$THERMAL_POLICY" in
    custom)
        _thermal_config_supported=yes
        case "$THERMAL_CONFIG_NAME" in
            thermal_info_config.json) ;;
            thermal_info_config_lpm.json)
                [ -r "/vendor/etc/$THERMAL_CONFIG_NAME" ] || _thermal_config_supported=no
                ;;
            *) _thermal_config_supported=no ;;
        esac
        _thermal_allow_vendor=yes
        if [ "$_is_upgrade" -eq 1 ]; then
            _old_thermal_policy=$(cat "$OLDDIR/.thermal_policy" 2>/dev/null | tr -d ' \r\n\t')
            case "$_old_thermal_policy" in system|disabled) ;; *) _thermal_allow_vendor=no ;; esac
        fi
        STOCK_ACTIVE=$(thermal_policy_snapshot_path "$device") \
            || { ui_print "  ✗ 无法确定温控 stock 路径"; exit 1; }
        if [ "$_thermal_config_supported" = yes ] \
            && thermal_policy_prepare_snapshot "$device" "$OLDDIR" "$_thermal_allow_vendor" \
            && mkdir -p "${OUT_JSON%/*}" 2>/dev/null \
            && thermal_generate_config "$STOCK_ACTIVE" "$OUT_JSON" "$offset"; then
            if stage_vendor_context "$OUT_JSON"; then
                ui_print "  温控: custom $(thermal_format_offset "$offset")"
            else
                thermal_policy_remove_overlay || exit 1
                [ ! -e "$OUT_JSON" ] || exit 1
                installer_write "$MODPATH/.thermal_policy" system
                offset=0
                installer_write "$OFFSET_FILE" 0
                INSTALL_REASON_CODE=THERMAL_CONTEXT_FALLBACK_SYSTEM
                ui_print "  ⚠ 温控 overlay context 无法验证，已 fail closed 到系统默认"
            fi
        else
            thermal_policy_remove_overlay || exit 1
            installer_write "$MODPATH/.thermal_policy" system
            offset=0
            installer_write "$OFFSET_FILE" 0
            INSTALL_REASON_CODE=THERMAL_CUSTOM_FALLBACK_SYSTEM
            ui_print "  ⚠ 自定义温控基线不可验证，已 fail closed 到系统默认"
        fi
        ;;
    system)
        thermal_policy_remove_overlay \
            || { ui_print "  ✗ 无法移除温控 overlay"; exit 1; }
        ui_print "  温控: $THERMAL_POLICY (不创建 vendor overlay)"
        ;;
    *)
        ui_print "  ✗ 非法温控策略"
        exit 1
        ;;
esac

if [ "$ROOT_IMPL" = APatch ] || [ "$ROOT_IMPL" = KernelSU ]; then
    meta_module_prepare_hook "$_meta_target" || {
        ui_print "  ✗ MetaModule hook 未通过版本/hash 合同，拒绝安装"
        exit 1
    }
fi

install_receipt_write committed success "$INSTALL_REASON_CODE" yes \
    || { ui_print "  ✗ 无法写入安装 receipt, 已中止安装"; exit 1; }
audit_log_event installer install success "$INSTALL_REASON_CODE" 0 \
    || { ui_print "  ✗ 无法写入安装审计日志, 已中止安装"; exit 1; }

ui_print ""
ui_print "  安装完成, 重启生效"
ui_print "  WebUI: http://127.0.0.1:6210"
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
INSTALL_COMPLETE=1
