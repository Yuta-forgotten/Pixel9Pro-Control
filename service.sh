#!/system/bin/sh

# Pixel 9 Pro Control late_start service.
# Waits for boot, restores persisted modem/VM/CPU policy, then starts the
# WebUI and the screen-aware standby workers. Versions come from module.prop
# and versions.prop; release history belongs in git, not this runtime file.

MODDIR="${0%/*}"
SERVICE_MODE="${1:-boot}"
case "$SERVICE_MODE" in boot|--background-worker) ;; *) exit 64 ;; esac
. "$MODDIR/scripts/background_tasks_lib.sh" || exit 1
[ "$SERVICE_MODE" != --background-worker ] || background_tasks_enabled || exit 0
PORT=6210
SERVICE_START_FILE="$MODDIR/.service_started"
HTTPD_PID_FILE="$MODDIR/.webui_httpd.pid"
TOKEN_FILE="$MODDIR/.webui_token"
THERMAL_CACHE="$MODDIR/.thermal_cache.json"
LOCKDIR_BASE="$MODDIR/.locks"
ZRAM_STATE_FILE="$MODDIR/.zram_state"
ZRAM_RESTORE_PENDING_FILE="$MODDIR/.zram_restore_pending"
VM_POLICY_READY_FILE="$MODDIR/.vm_policy_ready"
VM_REBOOT_BOOT_FILE="$MODDIR/.vm_reboot_boot_id"
SCHED_OWNER_FILE="$MODDIR/.cpu_sched_owner"
SCHED_OWNER_DESIRED_FILE="$MODDIR/.sched_owner_desired"
GAME_HANDOFF_POLICY_FILE="$MODDIR/.game_handoff_policy"
SIM2_AUTO_FILE="$MODDIR/.sim2_auto_manage"
IDLE_ISOLATE_FILE="$MODDIR/.idle_isolate_mode"
STANDBY_DIAG_FILE="$MODDIR/.standby_diag_state"
SCHEDULER_INVENTORY_PATH="$MODDIR/.scheduler_inventory"
SERVICE_LOCK_DIR="$MODDIR/.service_lock"
[ "$SERVICE_MODE" != --background-worker ] || SERVICE_LOCK_DIR="$MODDIR/.background_worker.lock"
SERVICE_BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')"
service_uptime() {
    _svc_up=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)
    case "$_svc_up" in ''|*[!0-9]*) _svc_up=0 ;; esac
    printf '%s' "$_svc_up"
}

service_start_ticks() {
    sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'
}

service_singleton_or_exit() {
    if mkdir "$SERVICE_LOCK_DIR" 2>/dev/null; then
        module_lock_write_owner "$SERVICE_LOCK_DIR" \
            || { rm -f "$SERVICE_LOCK_DIR/owner"; rmdir "$SERVICE_LOCK_DIR" 2>/dev/null; exit 1; }
        trap 'rm -f "$SERVICE_LOCK_DIR/owner" 2>/dev/null; rmdir "$SERVICE_LOCK_DIR" 2>/dev/null' EXIT
        return 0
    fi
    _service_wait=0
    while [ ! -s "$SERVICE_LOCK_DIR/owner" ] && [ "$_service_wait" -lt 3 ]; do
        sleep 1
        _service_wait=$((_service_wait + 1))
    done
    if [ ! -s "$SERVICE_LOCK_DIR/owner" ]; then
        rmdir "$SERVICE_LOCK_DIR" 2>/dev/null || exit 0
        service_singleton_or_exit
        return $?
    fi
    if module_lock_owner_alive "$SERVICE_LOCK_DIR"; then
        exit 0
    fi
    rm -f "$SERVICE_LOCK_DIR/owner" "$SERVICE_LOCK_DIR/stopping" 2>/dev/null || true
    rmdir "$SERVICE_LOCK_DIR" 2>/dev/null || exit 0
    mkdir "$SERVICE_LOCK_DIR" 2>/dev/null || exit 0
    module_lock_write_owner "$SERVICE_LOCK_DIR" \
        || { rm -f "$SERVICE_LOCK_DIR/owner"; rmdir "$SERVICE_LOCK_DIR" 2>/dev/null; exit 1; }
    trap 'rm -f "$SERVICE_LOCK_DIR/owner" 2>/dev/null; rmdir "$SERVICE_LOCK_DIR" 2>/dev/null' EXIT
}

service_singleton_or_exit

# Persist an early entry marker before loading optional contracts.  A missing
# marker distinguishes "service never launched" from a later ZRAM failure.
if [ "$SERVICE_MODE" = boot ]; then
    printf 'epoch=%s\npid=%s\n' "$(date +%s)" "$$" > "$SERVICE_START_FILE" 2>/dev/null || true
fi
log -t pixel9pro_ctrl "service entry moddir=$MODDIR pid=$$"

[ -r "$MODDIR/scripts/runtime_defaults_lib.sh" ] \
    && . "$MODDIR/scripts/runtime_defaults_lib.sh" 2>/dev/null \
    || { log -t pixel9pro_ctrl "ERROR: runtime defaults contract missing"; exit 1; }
# The WebUI may start before slow modem work, but VM/ZRAM mutations remain
# closed until the policy state has been normalized and readied below.
[ "$SERVICE_MODE" != boot ] || runtime_write_value "$VM_POLICY_READY_FILE" false >/dev/null 2>&1 || true
[ -r "$MODDIR/scripts/display_state_lib.sh" ] \
    && . "$MODDIR/scripts/display_state_lib.sh" 2>/dev/null \
    || { log -t pixel9pro_ctrl "ERROR: display state contract missing"; exit 1; }
[ -r "$MODDIR/scripts/foreground_app_lib.sh" ] \
    && . "$MODDIR/scripts/foreground_app_lib.sh" 2>/dev/null \
    || { log -t pixel9pro_ctrl "ERROR: foreground app contract missing"; exit 1; }
[ -r "$MODDIR/scripts/nr_mode_lib.sh" ] \
    && . "$MODDIR/scripts/nr_mode_lib.sh" 2>/dev/null \
    || { log -t pixel9pro_ctrl "ERROR: NR mode contract missing"; exit 1; }

settings() {
    runtime_android_settings "$@"
}

cmd() {
    runtime_android_cmd "$@"
}
[ -r "$MODDIR/scripts/bg_restrict_lib.sh" ] \
    && . "$MODDIR/scripts/bg_restrict_lib.sh" 2>/dev/null \
    || { log -t pixel9pro_ctrl "ERROR: background restriction contract missing"; exit 1; }
[ -r "$MODDIR/scripts/scheduler_detect_lib.sh" ] \
    && . "$MODDIR/scripts/scheduler_detect_lib.sh" 2>/dev/null \
    || { log -t pixel9pro_ctrl "ERROR: scheduler detection contract missing"; exit 1; }
[ -r "$MODDIR/scripts/scheduler_owner_lib.sh" ] \
    && . "$MODDIR/scripts/scheduler_owner_lib.sh" 2>/dev/null \
    || { log -t pixel9pro_ctrl "ERROR: scheduler owner contract missing"; exit 1; }
[ -r "$MODDIR/scripts/scheduler_boot_mode_lib.sh" ] \
    && . "$MODDIR/scripts/scheduler_boot_mode_lib.sh" 2>/dev/null \
    || { log -t pixel9pro_ctrl "ERROR: scheduler boot-mode contract missing"; exit 1; }
[ -r "$MODDIR/scripts/scheduler_transition_guard_lib.sh" ] \
    && . "$MODDIR/scripts/scheduler_transition_guard_lib.sh" 2>/dev/null \
    || { log -t pixel9pro_ctrl "ERROR: scheduler transition guard missing"; exit 1; }
CPU_PROFILE_AVAILABLE=0
if [ -r "$MODDIR/scripts/cpu_profile_lib.sh" ]; then
    . "$MODDIR/scripts/cpu_profile_lib.sh" 2>/dev/null && CPU_PROFILE_AVAILABLE=1
fi
[ -r "$MODDIR/scripts/profile_state_lib.sh" ] \
    && . "$MODDIR/scripts/profile_state_lib.sh" 2>/dev/null \
    && profile_state_init "$MODDIR" \
    || { log -t pixel9pro_ctrl "ERROR: profile state contract missing"; exit 1; }
NTP_CONFIG_FILE="$MODDIR/config/ntp_servers.tsv"
NTP_CONFIG_AVAILABLE=0
if [ -r "$MODDIR/scripts/ntp_config_lib.sh" ] && [ -r "$NTP_CONFIG_FILE" ]; then
    if . "$MODDIR/scripts/ntp_config_lib.sh" 2>/dev/null && ntp_config_validate; then
        NTP_CONFIG_AVAILABLE=1
    fi
fi
VM_PROFILE_AVAILABLE=0
if [ -r "$MODDIR/scripts/vm_profile_lib.sh" ]; then
    . "$MODDIR/scripts/vm_profile_lib.sh" 2>/dev/null && VM_PROFILE_AVAILABLE=1
fi
scheduler_owner_init "$MODDIR" "/data/adb/fas_rs"
sbm_init "$MODDIR" "/data/adb/fas_rs"

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
# 发行总版本动态取自 module.prop (不硬编码); 组件版本见 versions.prop
MOD_VER=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2 | tr -d '\r\n "\\')
[ -n "$MOD_VER" ] || MOD_VER="dev"

find_webui_httpd_pid() {
    for _pid in $(pidof httpd 2>/dev/null) $(pidof busybox 2>/dev/null); do
        case "$_pid" in ''|*[!0-9]*) continue ;; esac
        _cmd=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
        case "$_cmd" in
            *httpd*"$MODDIR/webroot"*)
                printf '%s' "$_pid"
                return 0
                ;;
        esac
    done
    return 1
}

stop_webui_httpd() {
    _pid=$(cat "$HTTPD_PID_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_pid" in ''|*[!0-9]*) _pid="" ;; esac
    if [ -n "$_pid" ] && [ -r "/proc/$_pid/cmdline" ]; then
        _cmd=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
        case "$_cmd" in
            *httpd*"$MODDIR/webroot"*)
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
        runtime_write_value "$HTTPD_PID_FILE" "$_pid" \
            && chmod 600 "$HTTPD_PID_FILE" 2>/dev/null \
            && return 0
    fi
    return 1
}

start_webui_httpd() {
    _webui_bb=""
    for _webui_candidate in /data/adb/ap/bin/busybox \
                /data/adb/ksu/bin/busybox \
                /data/adb/magisk/busybox \
                /sbin/busybox; do
        [ -x "$_webui_candidate" ] && _webui_bb="$_webui_candidate" && break
    done
    if [ -z "$_webui_bb" ]; then
        _webui_candidate=$(command -v busybox 2>/dev/null)
        [ -x "$_webui_candidate" ] && _webui_bb="$_webui_candidate"
    fi
    [ -n "$_webui_bb" ] || {
        log -t pixel9pro_ctrl "ERROR[$ROOT_IMPL]: busybox not found; WebUI unavailable"
        return 1
    }
    chmod 755 "$MODDIR/webroot/cgi-bin/"* 2>/dev/null || true
    stop_webui_httpd
    for _webui_attempt in 1 2 3; do
        if "$_webui_bb" nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
            log -t pixel9pro_ctrl "WebUI port $PORT already in use; preserving existing listener"
            return 0
        fi
        "$_webui_bb" httpd -p "127.0.0.1:$PORT" -h "$MODDIR/webroot" >/dev/null 2>&1 || true
        for _webui_probe in 1 2 3 4 5; do
            if record_webui_httpd_pid; then
                log -t pixel9pro_ctrl "WebUI(loopback)[$ROOT_IMPL]: http://127.0.0.1:$PORT pid=$(cat "$HTTPD_PID_FILE" 2>/dev/null)"
                return 0
            fi
            sleep 1
        done
        stop_webui_httpd
    done
    log -t pixel9pro_ctrl "ERROR[$ROOT_IMPL]: WebUI httpd failed after bounded retries"
    return 1
}

read_onoff_file() {
    runtime_read_onoff "$1" "$2"
}

restore_ntp_server() {
    [ "$NTP_CONFIG_AVAILABLE" -eq 1 ] || return 0
    NTP_SAVE="$MODDIR/.ntp_server"
    if [ -s "$NTP_SAVE" ]; then
        _saved=$(cat "$NTP_SAVE" 2>/dev/null | tr -d ' \n\r')
        _saved_normalized=$(ntp_server_normalize "$_saved" 2>/dev/null) || return 0
        if [ "$_saved" != "$_saved_normalized" ]; then
            runtime_write_value "$NTP_SAVE" "$_saved_normalized" 2>/dev/null || return 0
        fi
        if settings put global ntp_server "$_saved_normalized" 2>/dev/null \
            && [ "$(settings get global ntp_server 2>/dev/null | tr -d ' \n\r')" = "$_saved_normalized" ]; then
            log -t pixel9pro_ctrl "NTP server restored: $_saved_normalized"
        else
            log -t pixel9pro_ctrl "WARNING: failed to restore NTP server: $_saved_normalized"
        fi
    fi
}

apply_uecap_profile() {
    if [ -f "$MODDIR/uecap_profile.sh" ]; then
        . "$MODDIR/uecap_profile.sh"
        _mode=$(uecap_current_manual_mode)
        if uecap_pre_modem_receipt_is_current "$_mode"; then
            _source=$(uecap_resolve_source "$_mode")
            UECAP_RELOAD_DISPATCHED=false
            UECAP_RELOAD_RESULT="not_required_pre_modem"
            uecap_write_runtime_receipt "$_mode" "$(uecap_hash "$_source")" \
                "$(uecap_hash "$UECAP_TARGET")" pre_modem applied pre_modem_observed \
                >/dev/null 2>&1 || log -t pixel9pro_ctrl "WARNING: failed to refresh UECap pre-modem receipt"
            log -t pixel9pro_ctrl "UECap bind receipt refreshed: $_mode; modem load remains unconfirmed, actual_rat=$(uecap_receipt_get actual_rat 2>/dev/null || echo unknown), nr_registered=$(uecap_receipt_get nr_registered 2>/dev/null || echo unknown)"
            return 0
        fi
        if [ "$UECAP_BACKEND" = hybrid_mount ] || [ "$UECAP_BACKEND" = metamodule_content ]; then
            log -t pixel9pro_ctrl "UECap source/effective receipt is not current; no runtime mount or bind will be attempted"
            return 0
        fi
        if uecap_apply_mode "$_mode" "boot_manual" 2>/dev/null; then
            log -t pixel9pro_ctrl "UECap profile applied: $_mode (manual), modem_reload=${UECAP_RELOAD_RESULT:-unknown}, actual_rat=$(uecap_receipt_get actual_rat 2>/dev/null || echo unknown), nr_registered=$(uecap_receipt_get nr_registered 2>/dev/null || echo unknown)"
        else
            log -t pixel9pro_ctrl "WARNING: failed to apply UECap profile: $_mode result=${UECAP_APPLY_RESULT:-unknown}, modem_reload=${UECAP_RELOAD_RESULT:-unknown}"
        fi
    fi
}

apply_keep5g_standby_settings() {
    _standby_failed=0
    # 保留 5G / 5GA / CA 能力时，仍然建议关闭 mobile_data_always_on。
    # AOSP 定义表明该项仅用于在 Wi-Fi 等高优先级网络存在时，让蜂窝数据链路继续常驻以加快切换。
    # 关闭它不会取消 NR 注册或 CA 能力，但在 Wi-Fi -> 蜂窝回切时可能带来轻微时延。
    apply_android_setting global mobile_data_always_on 0 || _standby_failed=1

    # keep-5G 分支显式不强制关闭 VoWiFi / WFC。
    # AOSP 中 wfc_ims_enabled 是 Wi-Fi Calling 用户开关；强制关闭会明确影响室内弱覆盖场景的通话连续性。
    # 该项对 5G/5GA/CA 能力本身没有收益，因此本版暂停托管。

    # 扫描与 Nearby 相关项对 5G 能力本身无直接影响，仅减少息屏扫描和发现流量。
    apply_android_setting global nearby_sharing_enabled 0 || _standby_failed=1
    apply_android_setting secure nearby_sharing_slice_enabled 0 || _standby_failed=1
    apply_android_setting global wifi_scan_always_enabled 0 || _standby_failed=1
    apply_android_setting global ble_scan_always_enabled 0 || _standby_failed=1

    # adaptive_connectivity: Google 官方的 5G 节电机制。
    # 开启后，系统在 app 不需要高速时自动从 NR 回退到 LTE，降低 modem 空闲功耗。
    # 来源: https://support.google.com/pixelphone/answer/2819583
    apply_android_setting global adaptive_connectivity_enabled 1 || _standby_failed=1

    # network_recommendations: 系统默认已是开启，显式确保不被其他模块关闭。
    apply_android_setting global network_recommendations_enabled 1 || _standby_failed=1
    [ "$_standby_failed" -eq 0 ]
}

apply_android_setting() {
    _setting_scope="$1"
    _setting_key="$2"
    _setting_value="$3"
    if settings put "$_setting_scope" "$_setting_key" "$_setting_value" 2>/dev/null \
        && [ "$(settings get "$_setting_scope" "$_setting_key" 2>/dev/null | tr -d ' \n\r\t')" = "$_setting_value" ]; then
        return 0
    fi
    log -t pixel9pro_ctrl "WARNING: failed to apply setting $_setting_scope/$_setting_key=$_setting_value"
    return 1
}

manage_sim2_radio() {
    # Persistently switch Active modem count through TelephonyShellCommand.
    # set-sim-count 1 releases the unused DSDS instance; 2 restores DSDS when
    # SIM2 is present or the user disables automation. The command return value
    # is authoritative; this build does not expose a reliable support property.

    _sim2_auto=$(read_onoff_file "$SIM2_AUTO_FILE" "$SIM2_AUTO_DEFAULT")

    if [ "$_sim2_auto" != "on" ]; then
        # 用户显式关闭自动管理: 恢复 DSDS 双 modem
        if [ "$(cat "$MODDIR/.sim2_radio_off" 2>/dev/null)" = "disabled" ]; then
            if runtime_set_sim_count_state "$MODDIR/.sim2_radio_off" 2 enabled 1; then
                log -t pixel9pro_ctrl "SIM2 auto-manage off: restored DSDS (set-sim-count 2)"
            else
                log -t pixel9pro_ctrl "WARNING: SIM2 auto-manage off but DSDS restore failed ($SIM2_TRANSACTION_RESULT)"
                return 1
            fi
        fi
        return 0
    fi

    _sim2_state=$(getprop gsm.sim.state 2>/dev/null | sed 's/.*,//')
    case "$_sim2_state" in
        ABSENT|NOT_READY|PIN_REQUIRED|PUK_REQUIRED|PERM_DISABLED)
            if [ "$(cat "$MODDIR/.sim2_radio_off" 2>/dev/null)" != "disabled" ]; then
                if runtime_set_sim_count_state "$MODDIR/.sim2_radio_off" 1 disabled 2; then
                    log -t pixel9pro_ctrl "SIM2=$_sim2_state: switched to single SIM (set-sim-count 1)"
                else
                    log -t pixel9pro_ctrl "WARNING: SIM2=$_sim2_state but single-SIM switch failed ($SIM2_TRANSACTION_RESULT)"
                    return 1
                fi
            fi
            ;;
        LOADED|READY)
            if [ "$(cat "$MODDIR/.sim2_radio_off" 2>/dev/null)" = "disabled" ]; then
                if runtime_set_sim_count_state "$MODDIR/.sim2_radio_off" 2 enabled 1; then
                    log -t pixel9pro_ctrl "SIM2=$_sim2_state: restored DSDS (set-sim-count 2)"
                else
                    log -t pixel9pro_ctrl "WARNING: SIM2=$_sim2_state but DSDS restore failed ($SIM2_TRANSACTION_RESULT)"
                    return 1
                fi
            fi
            ;;
    esac
}

# ── 三层功耗方案: 参数定义 ──────────────────────────────
# Power profile: balanced (默认) / battery (省电)
# L1 (persistent): App Standby Bucket + AppOps + Freezer
# L2 (volatile): vendor_sched 后台 CPU 限制
# L3 (volatile, profile-time): response_time_ms (由 cpu_profile.sh 管理)
#
# AOSP 验证:
#   - App Standby Bucket: UsageStatsService 持久化到 app_idle_stats.xml, 重启后保留
#     am set-standby-bucket 设置 reason=FORCED_BY_USER, 只有用户交互才会提升
#   - AppOps: 持久化到 appops.xml, 系统不会自动回退
#   - vendor_sched: /proc/vendor_sched/ 纯 RAM, PowerHAL 在 hint 时可能覆盖

VENDOR_SCHED="/proc/vendor_sched"

apply_l1_persistent_limits() {
    # L1: 官方 API 后台限制 — persistent, 从配置文件读取包名策略
    # 文件: .bg_restrict_list (pkg|policy|delay_min), .bg_restrict_enabled (on/off)
    #       .bg_restrict_baseline (限制前 bucket/appops 原值)
    BG_ENABLED_FILE="$MODDIR/.bg_restrict_enabled"
    BG_LIST_FILE="$MODDIR/.bg_restrict_list"
    BG_BASELINE_FILE="$MODDIR/.bg_restrict_baseline"
    BG_STOP_STATE_FILE="$MODDIR/.bg_restrict_stop_state"

    [ -f "$BG_ENABLED_FILE" ] || runtime_write_value "$BG_ENABLED_FILE" on \
        || { log -t pixel9pro_ctrl "WARNING: failed to initialize background restriction state"; return 1; }
    if bg_list_is_legacy_seed "$BG_LIST_FILE"; then
        runtime_write_value "$BG_LIST_FILE" "$(bg_default_seed_entry)" \
            || { log -t pixel9pro_ctrl "WARNING: failed to migrate background restriction seed"; return 1; }
        log -t pixel9pro_ctrl "Background restriction default seed migrated"
    elif [ ! -e "$BG_LIST_FILE" ]; then
        # 首次运行: 只预置抖音。文件存在但为空时表示用户已清空列表，不再重置默认包名。
        runtime_write_value "$BG_LIST_FILE" "$(bg_default_seed_entry)" \
            || { log -t pixel9pro_ctrl "WARNING: failed to initialize background restriction list"; return 1; }
    fi
    rm -f "$BG_STOP_STATE_FILE" 2>/dev/null

    _bg_enabled=$(cat "$BG_ENABLED_FILE" 2>/dev/null | tr -d ' \n\r\t')
    if [ "$_bg_enabled" != "on" ]; then
        log -t pixel9pro_ctrl "L1: bg restrict disabled by user, skip"
        return 0
    fi

    _count=0
    _failed=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        bg_parse_entry "$_line"
        [ -z "$_bg_pkg" ] && continue
        case "$_bg_pkg" in \#*) continue ;; esac
        if bg_apply_policy "$_bg_pkg" "$_bg_policy"; then
            _count=$((_count + 1))
        else
            _failed=$((_failed + 1))
            log -t pixel9pro_ctrl "WARNING: failed to apply background policy for $_bg_pkg"
        fi
    done < "$BG_LIST_FILE"

    # Cached App Freezer: 确保开启 (cgroup v2 freeze, 缓存进程零 CPU)
    apply_android_setting global cached_apps_freezer_enabled 1 \
        || _failed=$((_failed + 1))

    log -t pixel9pro_ctrl "L1: bg restrict applied=$_count failed=$_failed"
    [ "$_failed" -eq 0 ]
}

valid_profile() {
    [ "$CPU_PROFILE_AVAILABLE" -eq 1 ] && cpu_profile_is_valid "$1"
}

read_valid_sched_owner() {
    so_read_effective_owner
}

read_valid_desired_sched_owner() {
    so_read_desired_owner
}

append_profile_history() {
    _ph_profile="$1"
    _ph_reason="$2"
    _ph_epoch="${_now:-}"
    case "$_ph_epoch" in
        ''|*[!0-9]*) _ph_epoch=$(date +%s 2>/dev/null || echo 0) ;;
    esac
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
    profile_state_append_observation "$_ph_profile" "$_ph_reason" "$_ph_epoch" \
        "$_ph_owner" "$_ph_charging" "$_ph_vs" "$_ph_sev"
}

profile_history_has_owner_field() {
    profile_state_history_has_owner_field
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
    display_state_read >/dev/null 2>&1 || true
    _ph_screen=$(display_state_legacy_screen)
    _sev=-1
    if command -v build_thermal_json >/dev/null 2>&1; then
        if [ "$_ph_screen" = on ]; then
            build_thermal_json hal >/dev/null 2>&1
            _ph_json="$THERMAL_BUILD_JSON"
            _sev="$THERMAL_BUILD_STATUS"
        else
            _ph_json=$(build_thermal_json sysfs 2>/dev/null)
        fi
        if [ -n "$_ph_json" ] && [ "$_ph_json" != "[]" ]; then
            if ! runtime_write_value "$THERMAL_CACHE" "$_ph_json"; then
                log -t pixel9pro_ctrl "WARNING: failed to refresh thermal cache baseline"
            fi
        fi
    fi
    _vs_temp=$(sed -n 's/.*VIRTUAL-SKIN","temp":\([0-9]*\).*/\1/p' "$THERMAL_CACHE" 2>/dev/null | head -1)
    case "$_vs_temp" in
        ''|*[!0-9]*) _vs_temp=0 ;;
    esac
    case "$_sev" in ''|*[!0-9]*) _sev=-1 ;; esac
    append_profile_history "$(profile_state_read_profile "$PROFILE_FILE" 'balanced')" "service_start"
    _now="$_ph_saved_now"
}

profile_lock_acquire() {
    so_acquire_transition_lock
}

profile_lock_release() {
    so_release_transition_lock
}

apply_profile_state() {
    _target="$1"
    _reason="$2"
    _expected_policy="${3:-}"
    PROFILE_APPLY_OUTCOME=failed

    [ "$CPU_PROFILE_AVAILABLE" -eq 1 ] || return 1
    valid_profile "$_target" || return 1
    case "$_expected_policy" in ''|manual|auto) ;; *) return 1 ;; esac

    _prelocked_policy=$(profile_state_read_policy)
    _prelocked_profile=$(profile_state_read_profile "$PROFILE_FILE" balanced)
    _prelocked_reason=$(cat "$PROFILE_AUTO_REASON_FILE" 2>/dev/null)
    _prelocked_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \r\n\t')
    [ -n "$_prelocked_boot" ] || _prelocked_boot=unknown
    if [ "$_prelocked_profile" = "$_target" ] \
        && [ "$_prelocked_reason" = "$_reason" ] \
        && { [ -z "$_expected_policy" ] || [ "$_prelocked_policy" = "$_expected_policy" ]; }; then
        PROFILE_APPLY_OUTCOME=already_applied
        return 0
    fi
    stg_init "$MODDIR/.profile_transition_guard"
    stg_load
    if [ "$STG_TERMINAL" = "yes" ] \
        && [ "$STG_BOOT_ID" = "$_prelocked_boot" ] \
        && [ "$STG_KEY" = "profile:${_prelocked_policy}:${_prelocked_profile}->${_target}" ]; then
        PROFILE_APPLY_OUTCOME=latched
        return 78
    fi

    if ! profile_lock_acquire; then
        PROFILE_APPLY_OUTCOME=busy
        log -t pixel9pro_ctrl "CPU profile busy, skip auto switch -> $_target ($_reason)"
        return 75
    fi

    sbm_load_state
    _locked_owner=$(read_valid_sched_owner)
    _locked_policy=$(profile_state_read_policy)
    _previous_profile=$(profile_state_read_profile "$PROFILE_FILE" balanced)
    _previous_reason=$(cat "$PROFILE_AUTO_REASON_FILE" 2>/dev/null)
    if [ "$SBM_PHASE" != "success" ] || [ "$SBM_EFFECTIVE_MODE" != "pixel" ] \
        || [ "$_locked_owner" != "pixel" ]; then
        PROFILE_APPLY_OUTCOME=superseded_owner
        log -t pixel9pro_ctrl "CPU profile decision superseded: scheduler not writable ($_target/$_reason)"
        profile_lock_release
        return 76
    fi
    if [ -n "$_expected_policy" ] && [ "$_locked_policy" != "$_expected_policy" ]; then
        PROFILE_APPLY_OUTCOME=superseded_policy
        log -t pixel9pro_ctrl "CPU profile decision superseded: policy=$_locked_policy expected=$_expected_policy ($_target/$_reason)"
        profile_lock_release
        return 76
    fi
    if [ "$_previous_profile" = "$_target" ]; then
        if runtime_write_value_if_changed "$PROFILE_AUTO_REASON_FILE" "$_reason"; then
            PROFILE_APPLY_OUTCOME=already_applied
            profile_lock_release
            return 0
        fi
        log -t pixel9pro_ctrl "WARNING: failed to update profile reason for stable $_target"
        profile_lock_release
        return 1
    fi

    _profile_guard_file="$MODDIR/.profile_transition_guard"
    stg_init "$_profile_guard_file"
    _profile_guard_now=$(date +%s 2>/dev/null || echo 0)
    _profile_guard_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \r\n\t')
    [ -n "$_profile_guard_boot" ] || _profile_guard_boot=unknown
    stg_begin_attempt "profile:${_locked_policy}:${_previous_profile}->${_target}" "$_profile_guard_boot" "$_profile_guard_now"
    _profile_guard_rc=$?
    if [ "$_profile_guard_rc" -ne 0 ]; then
        if [ "$_profile_guard_rc" -eq 74 ]; then
            PROFILE_APPLY_OUTCOME=guard_commit_failed
            log -t pixel9pro_ctrl "ERROR: CPU profile transition guard could not persist an attempt: $_previous_profile -> $_target"
        else
            PROFILE_APPLY_OUTCOME=latched
            log -t pixel9pro_ctrl "WARNING: CPU profile transition latched: $_previous_profile -> $_target (${STG_RESULT:-retry_budget_exhausted})"
        fi
        profile_lock_release
        return 1
    fi

    _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$_target" "$MODDIR" 2>/dev/null)
    _rc=$?

    if [ "$_rc" -eq 0 ]; then
        if ! profile_state_commit_active_reason "$_target" "$_reason"; then
            _profile_rollback_ok=1
            [ "$PROFILE_STATE_ROLLBACK_RESULT" = "complete" ] || _profile_rollback_ok=0
            sh "$MODDIR/scripts/cpu_profile.sh" "$_previous_profile" "$MODDIR" force >/dev/null 2>&1 || _profile_rollback_ok=0
            if [ "$_profile_rollback_ok" -eq 1 ]; then
                log -t pixel9pro_ctrl "WARNING: CPU profile state commit failed; restored $_previous_profile"
            else
                log -t pixel9pro_ctrl "ERROR: CPU profile state commit failed and rollback to $_previous_profile was incomplete"
            fi
            _profile_guard_now=$(date +%s 2>/dev/null || echo 0)
            stg_record_failure "$_profile_guard_now" state_commit_failed >/dev/null 2>&1 || true
            profile_lock_release
            return 1
        fi
        append_profile_history "$_target" "$_reason"
        if stg_record_success "applied:${_target}" >/dev/null 2>&1; then
            PROFILE_APPLY_OUTCOME=applied
        else
            PROFILE_APPLY_OUTCOME=applied_guard_terminal_unavailable
            log -t pixel9pro_ctrl "ERROR: CPU profile applied but its guard terminal state could not be persisted"
        fi
        log -t pixel9pro_ctrl "CPU profile applied: $_target ($_reason)"
        profile_lock_release
        return 0
    fi

    _profile_guard_now=$(date +%s 2>/dev/null || echo 0)
    _profile_guard_commit_rc=0
    stg_record_failure "$_profile_guard_now" "${_result:-unknown}" >/dev/null 2>&1 \
        || _profile_guard_commit_rc=$?
    if [ "$_profile_guard_commit_rc" -eq 74 ]; then
        PROFILE_APPLY_OUTCOME=guard_terminal_unavailable
        log -t pixel9pro_ctrl "ERROR: CPU profile failed and its guard terminal state could not be persisted"
        profile_lock_release
        return 74
    fi
    stg_load
    if [ "$STG_TERMINAL" = "yes" ]; then
        log -t pixel9pro_ctrl "ERROR: CPU profile transition failed final: $_target (${STG_RESULT:-unknown})"
    else
        log -t pixel9pro_ctrl "WARNING: failed to apply CPU profile $_target; bounded retry pending (${STG_ATTEMPTS}/${STG_MAX_ATTEMPTS})"
    fi
    profile_lock_release
    return 1
}

# ──────────────────────────────────────────────────────────
# 1. 等待系统完全启动
# ──────────────────────────────────────────────────────────
start_control_plane() {

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
done
sleep 20

# ──────────────────────────────────────────────────────────
# 1.1 WebUI 安全: token 生成 + 环境变量导出
# ──────────────────────────────────────────────────────────
mkdir -p "$LOCKDIR_BASE" 2>/dev/null \
    && chmod 700 "$LOCKDIR_BASE" 2>/dev/null \
    || { log -t pixel9pro_ctrl "ERROR: failed to prepare WebUI lock directory"; exit 1; }
token=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ -n "$token" ] || { log -t pixel9pro_ctrl "ERROR: secure token generation failed"; exit 1; }
runtime_write_value "$TOKEN_FILE" "$token" \
    || { log -t pixel9pro_ctrl "ERROR: secure token persistence failed"; exit 1; }
chmod 600 "$TOKEN_FILE" 2>/dev/null
if [ "$?" -ne 0 ]; then
    log -t pixel9pro_ctrl "ERROR: failed to secure WebUI token permissions"
    exit 1
fi

export PIXEL9PRO_MODDIR="$MODDIR"
export PIXEL9PRO_WEBUI_PORT="$PORT"
export PIXEL9PRO_WEBUI_TOKEN_FILE="$TOKEN_FILE"
export PIXEL9PRO_THERMAL_CACHE="$THERMAL_CACHE"
export PIXEL9PRO_LOCKDIR_BASE="$LOCKDIR_BASE"

# Start the control plane before optional radio/scheduler/VM work.  Those
# operations may be slow or unavailable during early boot; they must not make
# the local WebUI disappear.
start_webui_httpd || true
}

# Boot restoration and recurring policies have the same managed owner. A
# paused boot can resume here later without starting a second boot service.
restore_boot_policies() {
background_worker_should_run || return 1
so_migrate_state >/dev/null 2>&1 \
    || log -t pixel9pro_ctrl "WARNING: scheduler-owner state migration failed"
detect_external_scheduler_fresh >/dev/null 2>&1
background_worker_should_run || return 1

# ──────────────────────────────────────────────────────────
# 2. 系统设置优化 (保 5G 分支)
# ──────────────────────────────────────────────────────────
# SIM2 automation defaults to on and is persisted as an explicit user setting.
if [ ! -f "$SIM2_AUTO_FILE" ]; then
    runtime_write_value "$SIM2_AUTO_FILE" "$SIM2_AUTO_DEFAULT" \
        || log -t pixel9pro_ctrl "WARNING: failed to initialize SIM2 automation state"
fi
[ -f "$IDLE_ISOLATE_FILE" ] || runtime_write_value "$IDLE_ISOLATE_FILE" "$IDLE_ISOLATE_DEFAULT" \
    || log -t pixel9pro_ctrl "WARNING: failed to initialize idle-isolate state"

log -t pixel9pro_ctrl "$MOD_VER[$ROOT_IMPL]: applying keep-5G standby optimizations..."

# === UECap 档位 (纯手动三档) ===
# special / balanced / universal 分别对应全面增强 / 国内频段 / Google 默认；
# payload 组合与 hash 由模块资源和构建校验负责，boot 不复制第二份参数表。
apply_uecap_profile
background_worker_should_run || return 1

# === Modem / standby settings ===
# Apply once after boot, then repeat after unlock because Android may restore
# scan/time settings during late framework initialization.
apply_keep5g_standby_settings \
    || log -t pixel9pro_ctrl "WARNING: one or more standby settings failed verification"
background_worker_should_run || return 1
restore_ntp_server
background_worker_should_run || return 1

# === SIM2 空槽省电: 关闭空卡槽的 radio instance ===
manage_sim2_radio
background_worker_should_run || return 1

# === 内核 I/O 参数优化 ===
if [ "$VM_PROFILE_AVAILABLE" -eq 1 ]; then
    _service_swap_mode=$(cat "$MODDIR/.swap_mode" 2>/dev/null | tr -d ' \n\r\t')
    case "$_service_swap_mode" in
        optimized|custom)
            vm_apply_dirty_params \
                || log -t pixel9pro_ctrl "WARNING: failed to apply one or more VM dirty-page parameters"
            ;;
        *)
            log -t pixel9pro_ctrl "VM system/disabled mode: dirty-page parameters observe-only"
            ;;
    esac
fi

# sched_util_clamp_min is applied with the selected CPU profile: balanced and
# battery use 0; default and the internal performance baseline use 1024.

# === ZRAM observation / VM policy ===
if [ "$VM_PROFILE_AVAILABLE" -eq 1 ]; then
    # mmd/fs_mgr own setup when the standard owner properties are enabled. The
    # receipt records setup state, actual device values and inactive swap; boot
    # never seizes ownership or mutates zram0.
    _zram_receipt=$(printf 'schema=2\nepoch=%s\nboot_id=%s\n' \
        "$(date +%s)" "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"; \
        vm_zram_receipt)
    runtime_write_value "$ZRAM_STATE_FILE" "$_zram_receipt" \
        || log -t pixel9pro_ctrl "WARNING: failed to record ZRAM observation"
    log -t pixel9pro_ctrl "ZRAM observed: owner=$(vm_zram_owner) algorithm=$(vm_zram_read_algorithm) size=$(vm_zram_read_disksize) active=$(vm_zram_is_active && printf true || printf false)"

# === Swap / 内存回收调优 (按上次用户选择恢复) ===
SWAP_CUSTOM_FILE="$MODDIR/.swap_custom"

SWAP_MODE=$(cat "$MODDIR/.swap_mode" 2>/dev/null | tr -d ' \n\r')
case "$SWAP_MODE" in
    system|stock|disabled)
        # Observe-only: leave kernel VM values and mmd/Scene ZRAM requests
        # untouched. A reboot restores platform VM defaults; Scene remains the
        # sole interactive ZRAM request owner.
        vm_zram_reconcile_module_request \
            || log -t pixel9pro_ctrl "WARNING: failed to reconcile module-owned ZRAM request"
        case "${VM_ZRAM_RECONCILE_RESULT:-none}" in
            orphaned|external_changed)
                runtime_write_value "$ZRAM_RESTORE_PENDING_FILE" false >/dev/null 2>&1 || true
                ;;
            *)
                if [ "${VM_ZRAM_RESTORE_PENDING:-false}" = true ]; then
                    runtime_write_value "$ZRAM_RESTORE_PENDING_FILE" true >/dev/null 2>&1 || true
                elif [ "$(cat "$ZRAM_RESTORE_PENDING_FILE" 2>/dev/null | tr -d ' \n\r\t')" = true ]; then
                    _service_requested_size=$(vm_zram_read_requested_size)
                    _service_requested_bytes=$(vm_zram_size_to_bytes "$_service_requested_size")
                    if [ -n "$_service_requested_bytes" ] && [ "$(vm_zram_read_disksize)" = "$_service_requested_bytes" ]; then
                        runtime_write_value "$ZRAM_RESTORE_PENDING_FILE" false >/dev/null 2>&1 || true
                    fi
                fi
                ;;
        esac
        [ "$SWAP_MODE" = stock ] && runtime_write_value "$MODDIR/.swap_mode" system >/dev/null 2>&1 || true
        [ "$SWAP_MODE" = disabled ] \
            && runtime_write_value "$MODDIR/.feature_vm" disabled >/dev/null 2>&1 \
            || runtime_write_value "$MODDIR/.feature_vm" system >/dev/null 2>&1 || true
        _service_reboot_required=$(cat "$MODDIR/.vm_reboot_required" 2>/dev/null | tr -d ' \n\r\t')
        _service_reboot_boot=$(cat "$VM_REBOOT_BOOT_FILE" 2>/dev/null | tr -d ' \n\r\t')
        _service_current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')
        case "$_service_reboot_required" in true|false) ;; *) _service_reboot_required=false ;; esac
        # A pending VM reset is a same-boot transaction.  Clear it only after
        # a reboot crossed the recorded boot id; never erase a live WebUI
        # pending state while this service is restoring the current boot.
        if [ "$_service_reboot_required" = true ] \
            && [ -n "$_service_reboot_boot" ] \
            && [ -n "$_service_current_boot" ] \
            && [ "$_service_reboot_boot" != "$_service_current_boot" ]; then
            runtime_write_value "$MODDIR/.vm_reboot_required" false >/dev/null 2>&1 || true
            rm -f "$VM_REBOOT_BOOT_FILE" 2>/dev/null || true
        fi
        log -t pixel9pro_ctrl "Swap: system/disabled observe-only; no VM or ZRAM write"
        ;;
    optimized)
        if vm_write_params "$VM_OPT_SWAPPINESS" "$VM_OPT_MIN_FREE_KBYTES" "$VM_OPT_WATERMARK_SCALE" "$VM_OPT_VFS_CACHE_PRESSURE" \
            && runtime_write_value "$MODDIR/.feature_vm" optimized \
            && runtime_write_value "$MODDIR/.vm_reboot_required" false; then
            rm -f "$VM_REBOOT_BOOT_FILE" 2>/dev/null || true
            log -t pixel9pro_ctrl "Swap: restored optimized VM params; ZRAM remains explicit-request only"
        else
            log -t pixel9pro_ctrl "WARNING: failed to restore optimized VM params"
        fi
        ;;
    custom)
        _custom_sw=$(vm_read_custom_param swappiness "$SWAP_CUSTOM_FILE")
        _custom_mfk=$(vm_read_custom_param min_free_kbytes "$SWAP_CUSTOM_FILE")
        _custom_wsf=$(vm_read_custom_param watermark_scale_factor "$SWAP_CUSTOM_FILE")
        _custom_vcp=$(vm_read_custom_param vfs_cache_pressure "$SWAP_CUSTOM_FILE")
        if vm_is_uint_range "$_custom_sw" "$VM_SWAPPINESS_MIN" "$VM_SWAPPINESS_MAX" \
            && vm_is_uint_range "$_custom_mfk" "$VM_MIN_FREE_KBYTES_MIN" "$VM_MIN_FREE_KBYTES_MAX" \
            && vm_is_uint_range "$_custom_wsf" "$VM_WATERMARK_SCALE_MIN" "$VM_WATERMARK_SCALE_MAX" \
            && vm_is_uint_range "$_custom_vcp" "$VM_VFS_CACHE_PRESSURE_MIN" "$VM_VFS_CACHE_PRESSURE_MAX"; then
            if vm_write_params "$_custom_sw" "$_custom_mfk" "$_custom_wsf" "$_custom_vcp" \
                && runtime_write_value "$MODDIR/.feature_vm" optimized \
                && runtime_write_value "$MODDIR/.vm_reboot_required" false; then
                rm -f "$VM_REBOOT_BOOT_FILE" 2>/dev/null || true
                log -t pixel9pro_ctrl "Swap: restored custom VM params"
            else
                log -t pixel9pro_ctrl "WARNING: failed to restore custom VM params"
            fi
        else
            runtime_write_value "$MODDIR/.swap_mode" system >/dev/null 2>&1 || true
            runtime_write_value "$MODDIR/.feature_vm" system >/dev/null 2>&1 || true
            runtime_write_value "$MODDIR/.vm_reboot_required" true >/dev/null 2>&1 || true
            runtime_write_value "$VM_REBOOT_BOOT_FILE" "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')" >/dev/null 2>&1 || true
            log -t pixel9pro_ctrl "WARNING: invalid custom params; normalized to system observe-only"
        fi
        ;;
    *)
        runtime_write_value "$MODDIR/.swap_mode" system >/dev/null 2>&1 || true
        runtime_write_value "$MODDIR/.feature_vm" system >/dev/null 2>&1 || true
        runtime_write_value "$MODDIR/.vm_reboot_required" true >/dev/null 2>&1 || true
        runtime_write_value "$VM_REBOOT_BOOT_FILE" "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')" >/dev/null 2>&1 || true
        log -t pixel9pro_ctrl "Swap: missing/unknown policy normalized to system observe-only"
        ;;
esac
runtime_write_value "$VM_POLICY_READY_FILE" true >/dev/null 2>&1 \
    || log -t pixel9pro_ctrl "WARNING: VM policy readback gate could not be opened"
else
    log -t pixel9pro_ctrl "WARNING: VM profile library missing, skipped ZRAM/VM restore"
fi

log -t pixel9pro_ctrl "$MOD_VER[$ROOT_IMPL]: boot policy restore completed; warnings above remain authoritative"
background_worker_should_run || return 1

# ──────────────────────────────────────────────────────────
# 2.5 持久后台策略。CPU/L2 由同一 profile transaction 应用。
# ──────────────────────────────────────────────────────────
[ -f "$SCHED_OWNER_FILE" ] || runtime_write_value "$SCHED_OWNER_FILE" pixel \
    || log -t pixel9pro_ctrl "WARNING: failed to initialize scheduler owner state"
[ -f "$SCHED_OWNER_DESIRED_FILE" ] || runtime_write_value "$SCHED_OWNER_DESIRED_FILE" "$(read_valid_sched_owner)" \
    || log -t pixel9pro_ctrl "WARNING: failed to initialize desired scheduler owner"
[ -f "$GAME_HANDOFF_POLICY_FILE" ] || runtime_write_value "$GAME_HANDOFF_POLICY_FILE" off \
    || log -t pixel9pro_ctrl "WARNING: failed to initialize game handoff policy"
apply_l1_persistent_limits
background_worker_should_run || return 1

# ──────────────────────────────────────────────────────────
# 3. 有界恢复 CPU 调度方案 (CPU + cpuset + cap + vendor_sched L2)
# ──────────────────────────────────────────────────────────
PROFILE=$(profile_state_read_profile "$PROFILE_FILE" 'balanced')
[ -f "$PROFILE_MANUAL_FILE" ] || runtime_write_value "$PROFILE_MANUAL_FILE" "$PROFILE" \
    || log -t pixel9pro_ctrl "WARNING: failed to initialize manual profile state"
[ -f "$PROFILE_POLICY_FILE" ] || runtime_write_value "$PROFILE_POLICY_FILE" manual \
    || log -t pixel9pro_ctrl "WARNING: failed to initialize profile policy"
[ -f "$PROFILE_AUTO_REASON_FILE" ] || runtime_write_value "$PROFILE_AUTO_REASON_FILE" manual_policy \
    || log -t pixel9pro_ctrl "WARNING: failed to initialize profile reason"
if [ "$CPU_PROFILE_AVAILABLE" -ne 1 ]; then
    log -t pixel9pro_ctrl "WARNING: CPU profile contract missing, skipped profile restore"
else
    if sh "$MODDIR/scripts/scheduler_reconcile.sh" boot "$MODDIR" >/dev/null 2>&1; then
        log -t pixel9pro_ctrl "Scheduler boot reconcile completed"
    else
        _scheduler_boot_rc=$?
        if [ "$_scheduler_boot_rc" -eq 75 ]; then
            log -t pixel9pro_ctrl "WARNING: scheduler boot reconcile deferred by an active transition"
        else
            log -t pixel9pro_ctrl "ERROR: scheduler boot reconcile reached a terminal failure (rc=$_scheduler_boot_rc)"
        fi
    fi
fi
ensure_profile_history_baseline

# Owner arbiter is intentionally owned by the unified foreground worker. This
# removes a second screen-state loop and guarantees that no owner/top-app IPC
# runs during screen-off standby.
sbm_load_state
if [ "$SBM_PHASE" = "success" ] \
    && { [ "$SBM_EFFECTIVE_MODE" = "pixel" ] || [ "$SBM_EFFECTIVE_MODE" = "ugt" ]; }; then
log -t pixel9pro_ctrl "Owner arbiter folded into screen-on worker for verified ${SBM_EFFECTIVE_MODE} baseline"
else
    log -t pixel9pro_ctrl "Owner arbiter disabled: scheduler boot state=${SBM_PHASE:-unknown}/${SBM_EFFECTIVE_MODE:-unknown}"
fi

# Scheduler health is folded into the foreground worker below. It is a
# read-only observation and must not keep a 900-second sleeper alive while
# the display is off; the first interactive cycle after wake performs it.
if [ "$CPU_PROFILE_AVAILABLE" -eq 1 ]; then
    log -t pixel9pro_ctrl "Scheduler health worker is screen-on only"
else
    log -t pixel9pro_ctrl "Scheduler health observation disabled: CPU profile contract unavailable"
fi
background_worker_should_run || return 1
runtime_write_value "$MODDIR/.background_boot_ready" "$SERVICE_BOOT_ID"
}

if [ "$SERVICE_MODE" = --background-worker ]; then
    . "$MODDIR/scripts/control_worker_lib.sh" || exit 1
    control_worker_main
    exit $?
fi
start_control_plane
if ! background_tasks_enabled; then
    log -t pixel9pro_ctrl "All automatic module tasks are paused; WebUI remains available"
    exit 0
fi

# ──────────────────────────────────────────────────────────
# 4. 统一后台工作循环 (Doze 友好)
#    DRM disabled 直接判息屏；enabled 可能是 AOD，使用有界交互态查询
#    亮屏 15s / 息屏 900s；已切换 LTE 时按既有 NR 恢复周期复查
#    若已降到 LTE, 改为较短复查周期，避免亮屏后长期停留 LTE
#    WiFi multicast: 仅在屏幕状态变化时切换，不轮询
#    NR 降级: 集成防抖，仅在开启时生效
#    温度历史: 亮屏 60s、息屏 900s；息屏只读 sysfs，前台读取共享同一限频写入器
#    UECap: manual profile is applied only during boot or an explicit WebUI action
# ──────────────────────────────────────────────────────────
background_tasks_start \
    || log -t pixel9pro_ctrl "ERROR: background worker did not start"
