#!/system/bin/sh

# Pixel 9 Pro Control late_start service.
# Waits for boot, restores persisted modem/VM/CPU policy, then starts the
# WebUI and the screen-aware standby workers. Versions come from module.prop
# and versions.prop; release history belongs in git, not this runtime file.

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
SCHED_OWNER_DESIRED_FILE="$MODDIR/.sched_owner_desired"
GAME_HANDOFF_POLICY_FILE="$MODDIR/.game_handoff_policy"
SIM2_AUTO_FILE="$MODDIR/.sim2_auto_manage"
IDLE_ISOLATE_FILE="$MODDIR/.idle_isolate_mode"
STANDBY_DIAG_FILE="$MODDIR/.standby_diag_state"
SCHEDULER_INVENTORY_PATH="$MODDIR/.scheduler_inventory"

[ -r "$MODDIR/scripts/runtime_defaults_lib.sh" ] \
    && . "$MODDIR/scripts/runtime_defaults_lib.sh" 2>/dev/null \
    || { log -t pixel9pro_ctrl "ERROR: runtime defaults contract missing"; exit 1; }
[ -r "$MODDIR/scripts/display_state_lib.sh" ] \
    && . "$MODDIR/scripts/display_state_lib.sh" 2>/dev/null \
    || { log -t pixel9pro_ctrl "ERROR: display state contract missing"; exit 1; }
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
so_migrate_state >/dev/null 2>&1 \
    || log -t pixel9pro_ctrl "WARNING: scheduler-owner state migration failed"
detect_external_scheduler_fresh >/dev/null 2>&1
_scheduler_inventory_rc=$?
if [ "$_scheduler_inventory_rc" -gt 1 ] 2>/dev/null; then
    log -t pixel9pro_ctrl "WARNING: scheduler inventory refresh failed"
fi

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
        if uecap_apply_mode "$_mode" "boot_manual" 2>/dev/null; then
            log -t pixel9pro_ctrl "UECap profile applied: $_mode (manual)"
        else
            log -t pixel9pro_ctrl "WARNING: failed to apply UECap profile: $_mode"
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
    if [ ! -e "$BG_LIST_FILE" ]; then
        # 首次运行: 只预置抖音。文件存在但为空时表示用户已清空列表，不再重置默认包名。
        runtime_write_value "$BG_LIST_FILE" 'com.ss.android.ugc.aweme|stop_after_leave|5' \
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
    if [ "$CPU_PROFILE_AVAILABLE" -eq 1 ]; then
        cpu_profile_normalize_runtime "$_profile_value" "$_profile_default"
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
            if ! runtime_write_value "$THERMAL_CACHE" "$_ph_json"; then
                log -t pixel9pro_ctrl "WARNING: failed to refresh thermal cache baseline"
            fi
        fi
    fi
    _vs_temp=$(sed -n 's/.*VIRTUAL-SKIN","temp":\([0-9]*\).*/\1/p' "$THERMAL_CACHE" 2>/dev/null | head -1)
    case "$_vs_temp" in
        ''|*[!0-9]*) _vs_temp=0 ;;
    esac
    _sev=$(dumpsys thermalservice 2>/dev/null | grep "Thermal Status:" | head -1 | sed 's/.*Thermal Status:[[:space:]]*//' | tr -d ' \n\r')
    case "$_sev" in ''|*[!0-9]*) _sev=0 ;; esac
    append_profile_history "$(read_valid_profile "$PROFILE_FILE" 'balanced')" "service_start"
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

    [ "$CPU_PROFILE_AVAILABLE" -eq 1 ] || return 1
    valid_profile "$_target" || return 1

    if [ "$(read_valid_sched_owner)" = "external" ]; then
        log -t pixel9pro_ctrl "CPU profile skipped: scheduler owner=external ($_target/$_reason)"
        return 0
    fi

    _profile_guard_file="$MODDIR/.profile_transition_guard"
    stg_init "$_profile_guard_file"
    _profile_guard_now=$(date +%s 2>/dev/null || echo 0)
    _profile_guard_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \r\n\t')
    [ -n "$_profile_guard_boot" ] || _profile_guard_boot=unknown
    stg_begin_attempt "profile:${_target}" "$_profile_guard_boot" "$_profile_guard_now"
    _profile_guard_rc=$?
    if [ "$_profile_guard_rc" -ne 0 ]; then
        if [ "$_profile_guard_rc" -eq 77 ] || [ "$_profile_guard_rc" -eq 78 ]; then
            log -t pixel9pro_ctrl "WARNING: CPU profile transition latched: $_target (${STG_RESULT:-retry_budget_exhausted})"
        else
            log -t pixel9pro_ctrl "ERROR: CPU profile transition guard failed: $_target (rc=$_profile_guard_rc)"
        fi
        return 1
    fi

    if ! profile_lock_acquire; then
        log -t pixel9pro_ctrl "CPU profile busy, skip auto switch -> $_target ($_reason)"
        return 1
    fi

    _previous_profile=$(read_valid_profile "$PROFILE_FILE" balanced)
    _previous_reason=$(cat "$PROFILE_AUTO_REASON_FILE" 2>/dev/null)
    _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$_target" "$MODDIR" 2>/dev/null)
    _rc=$?

    if [ "$_rc" -eq 0 ]; then
        if ! runtime_write_value "$PROFILE_FILE" "$_target" \
            || ! runtime_write_value "$PROFILE_AUTO_REASON_FILE" "$_reason"; then
            _profile_rollback_ok=1
            runtime_write_value "$PROFILE_FILE" "$_previous_profile" >/dev/null 2>&1 || _profile_rollback_ok=0
            runtime_write_value "$PROFILE_AUTO_REASON_FILE" "$_previous_reason" >/dev/null 2>&1 || _profile_rollback_ok=0
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
        stg_record_success "applied:${_target}" >/dev/null 2>&1 \
            || log -t pixel9pro_ctrl "WARNING: failed to commit profile transition success"
        log -t pixel9pro_ctrl "CPU profile applied: $_target ($_reason)"
        profile_lock_release
        return 0
    fi

    _profile_guard_now=$(date +%s 2>/dev/null || echo 0)
    stg_record_failure "$_profile_guard_now" "${_result:-unknown}" >/dev/null 2>&1 || true
    stg_load
    if [ "$STG_TERMINAL" = "yes" ]; then
        log -t pixel9pro_ctrl "ERROR: CPU profile transition failed final: $_target (${STG_RESULT:-unknown})"
    else
        log -t pixel9pro_ctrl "WARNING: failed to apply CPU profile $_target; bounded retry pending (${STG_ATTEMPTS}/${STG_MAX_ATTEMPTS})"
    fi
    profile_lock_release
    return 1
}

foreground_package_name() {
    # Keep this parser aligned with scripts/owner_arbiter.sh.  Android 17 can
    # print transient overlays (NotificationShade, keyguard/bouncer) before
    # the real focused app in `dumpsys window`; scan by semantic priority and
    # only accept lines that contain a package/activity pair.
    _dump=$(dumpsys window 2>/dev/null)
    _pkg=""
    for _prefix in "mFocusedApp=" "mCurrentFocus=" "mFocusedWindow=" "topResumedActivity=" "ResumedActivity:"; do
        _pkg=$(printf '%s\n' "$_dump" | awk -v prefix="$_prefix" '
            {
                line = $0
                sub(/^[ \t]+/, "", line)
                if (index(line, prefix) == 1) print line
            }
        ' | sed -n '
            s/.*[[:space:]]u[0-9][0-9]*[[:space:]]\([^/ }][^/ }]*\)\/.*/\1/p
            s/.*[[:space:]]\([A-Za-z0-9_.$][A-Za-z0-9_.$]*\)\/.*/\1/p
        ' | head -n 1)
        [ -n "$_pkg" ] && break
    done
    if [ -z "$_pkg" ]; then
        _pkg=$(dumpsys activity top 2>/dev/null | sed -n 's/^  ACTIVITY \([^/ ][^/ ]*\)\/.*/\1/p' | head -n 1)
    fi
    printf '%s' "$_pkg" | tr -d ' \r\n\t'
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

# === Modem / standby settings ===
# Apply once after boot, then repeat after unlock because Android may restore
# scan/time settings during late framework initialization.
apply_keep5g_standby_settings \
    || log -t pixel9pro_ctrl "WARNING: one or more standby settings failed verification"
restore_ntp_server

# === SIM2 空槽省电: 关闭空卡槽的 radio instance ===
manage_sim2_radio

# Wi-Fi multicast follows screen state through the interface flag. The
# WifiShellCommand has no mutating disable-multicast command on this build.
ip link set wlan0 multicast off 2>/dev/null

# === 内核 I/O 参数优化 ===
if [ "$VM_PROFILE_AVAILABLE" -eq 1 ]; then
    vm_apply_dirty_params \
        || log -t pixel9pro_ctrl "WARNING: failed to apply one or more VM dirty-page parameters"
fi

# sched_util_clamp_min is applied with the selected CPU profile: balanced and
# battery use 0; default and the internal performance baseline use 1024.

# === ZRAM / VM 配置 ===
if [ "$VM_PROFILE_AVAILABLE" -eq 1 ]; then
# 原厂出厂: persist.vendor.zram_comp_algorithm 默认为 lz4, ZRAM 大小 50% RAM ≈ 8GB.
# init.rc 代码兜底默认是 lz77eh (Emerald Hill 硬件), 但出厂 persist 属性覆盖为 lz4.
# 目标算法、大小和 VM 预设由 scripts/vm_profile_lib.sh 统一定义。
#
# persist 属性确保后续重启时 init.rc 直接使用 lz77eh, 减少 swapoff 次数.
if ! setprop persist.vendor.zram_comp_algorithm "$VM_ZRAM_ALGO" 2>/dev/null \
    || [ "$(getprop persist.vendor.zram_comp_algorithm 2>/dev/null | tr -d ' \n\r\t')" != "$VM_ZRAM_ALGO" ]; then
    log -t pixel9pro_ctrl "WARNING: failed to persist ZRAM algorithm property"
fi

CURRENT_ALGO=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | sed 's/.*\[\(.*\)\].*/\1/')
CURRENT_SIZE=$(cat /sys/block/zram0/disksize 2>/dev/null)

if [ "$CURRENT_ALGO" != "$VM_ZRAM_ALGO" ] || [ "$CURRENT_SIZE" != "$VM_ZRAM_SIZE_BYTES" ]; then
    log -t pixel9pro_ctrl "ZRAM reconfigure: ${CURRENT_ALGO}/${CURRENT_SIZE} -> ${VM_ZRAM_ALGO}/${VM_ZRAM_SIZE_BYTES}"
    if vm_reconfigure_zram "$VM_ZRAM_ALGO" "$VM_ZRAM_SIZE_BYTES"; then
        log -t pixel9pro_ctrl "ZRAM: $VM_ZRAM_ALGO $(($VM_ZRAM_SIZE_BYTES / 1048576))MB ready"
    else
        _zram_rc=$?
        if [ "$_zram_rc" -eq 2 ]; then
            log -t pixel9pro_ctrl "ERROR: ZRAM reconfigure failed and previous configuration restore was incomplete"
        else
            log -t pixel9pro_ctrl "WARNING: ZRAM reconfigure failed; previous configuration restored"
        fi
    fi
else
    log -t pixel9pro_ctrl "ZRAM: already $VM_ZRAM_ALGO $(($VM_ZRAM_SIZE_BYTES / 1048576))MB, skip"
fi

# === Swap / 内存回收调优 (按上次用户选择恢复) ===
SWAP_CUSTOM_FILE="$MODDIR/.swap_custom"

SWAP_MODE=$(cat "$MODDIR/.swap_mode" 2>/dev/null | tr -d ' \n\r')
case "$SWAP_MODE" in
    stock)
        if vm_write_params "$VM_STOCK_SWAPPINESS" "$VM_STOCK_MIN_FREE_KBYTES" "$VM_STOCK_WATERMARK_SCALE" "$VM_STOCK_VFS_CACHE_PRESSURE"; then
            log -t pixel9pro_ctrl "Swap: restored stock VM params"
        else
            log -t pixel9pro_ctrl "WARNING: failed to restore stock VM params"
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
            if vm_write_params "$_custom_sw" "$_custom_mfk" "$_custom_wsf" "$_custom_vcp"; then
                log -t pixel9pro_ctrl "Swap: restored custom VM params"
            else
                log -t pixel9pro_ctrl "WARNING: failed to restore custom VM params"
            fi
        else
            if vm_write_params "$VM_OPT_SWAPPINESS" "$VM_OPT_MIN_FREE_KBYTES" "$VM_OPT_WATERMARK_SCALE" "$VM_OPT_VFS_CACHE_PRESSURE"; then
                if runtime_write_value "$MODDIR/.swap_mode" optimized >/dev/null 2>&1; then
                    log -t pixel9pro_ctrl "Swap: invalid custom params, restored optimized VM params"
                else
                    log -t pixel9pro_ctrl "ERROR: optimized VM params restored but swap-mode state commit failed"
                fi
            else
                log -t pixel9pro_ctrl "WARNING: invalid custom params and optimized fallback failed"
            fi
        fi
        ;;
    *)
        if vm_write_params "$VM_OPT_SWAPPINESS" "$VM_OPT_MIN_FREE_KBYTES" "$VM_OPT_WATERMARK_SCALE" "$VM_OPT_VFS_CACHE_PRESSURE"; then
            runtime_write_value "$MODDIR/.swap_mode" optimized >/dev/null 2>&1 \
                || log -t pixel9pro_ctrl "WARNING: failed to normalize VM mode state"
        else
            log -t pixel9pro_ctrl "WARNING: failed to restore optimized VM params"
        fi
        ;;
esac
else
    log -t pixel9pro_ctrl "WARNING: VM profile library missing, skipped ZRAM/VM restore"
fi

log -t pixel9pro_ctrl "$MOD_VER[$ROOT_IMPL]: boot policy restore completed; warnings above remain authoritative"

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

# 延迟复写：NTP 服务器和扫描类设置可能在用户解锁后被系统回写。
(
    sleep 120
    _late_settings_result=ok
    apply_keep5g_standby_settings || _late_settings_result=failed
    restore_ntp_server
    if [ "$_late_settings_result" = "ok" ]; then
        log -t pixel9pro_ctrl "Standby settings re-applied after late boot"
    else
        log -t pixel9pro_ctrl "WARNING: late-boot standby settings were only partially applied"
    fi
) &

# ──────────────────────────────────────────────────────────
# 3. 有界恢复 CPU 调度方案 (CPU + cpuset + cap + vendor_sched L2)
# ──────────────────────────────────────────────────────────
PROFILE=$(read_valid_profile "$PROFILE_FILE" 'balanced')
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
        log -t pixel9pro_ctrl "ERROR: scheduler boot reconcile reached a terminal failure (rc=$_scheduler_boot_rc)"
    fi
fi
ensure_profile_history_baseline

# Owner arbiter needs a faster wake->game reaction than the main standby
# worker can provide after it enters the 600s deep-standby sleep.  Keep this
# loop cheap while screen-off and only run top-app/window IPC when display is on.
sbm_load_state
if [ "$SBM_PHASE" = "success" ] && [ "$SBM_EFFECTIVE_MODE" = "pixel" ]; then
(
    _owner_arbiter_fast_on="${OWNER_ARBITER_FAST_ON:-$OWNER_ARBITER_DEFAULT_SCREEN_ON_POLL_S}"
    _owner_arbiter_fast_off="${OWNER_ARBITER_FAST_OFF:-$OWNER_ARBITER_DEFAULT_SCREEN_OFF_POLL_S}"
    _owner_arbiter_off_grace_s="${OWNER_ARBITER_OFF_GRACE_S:-$OWNER_ARBITER_DEFAULT_SCREEN_OFF_GRACE_S}"
    _owner_arbiter_off_pause_s="${OWNER_ARBITER_OFF_PAUSE_S:-$OWNER_ARBITER_DEFAULT_SCREEN_OFF_PAUSE_S}"
    _owner_arbiter_pause_poll_s="${OWNER_ARBITER_PAUSE_POLL_S:-$OWNER_ARBITER_DEFAULT_PAUSE_POLL_S}"
    case "$_owner_arbiter_fast_on" in ''|*[!0-9]*) _owner_arbiter_fast_on=5 ;; esac
    case "$_owner_arbiter_fast_off" in ''|*[!0-9]*) _owner_arbiter_fast_off=15 ;; esac
    case "$_owner_arbiter_off_grace_s" in ''|*[!0-9]*) _owner_arbiter_off_grace_s=360 ;; esac
    case "$_owner_arbiter_off_pause_s" in ''|*[!0-9]*) _owner_arbiter_off_pause_s=3600 ;; esac
    case "$_owner_arbiter_pause_poll_s" in ''|*[!0-9]*) _owner_arbiter_pause_poll_s=30 ;; esac
    [ "$_owner_arbiter_fast_on" -lt 3 ] 2>/dev/null && _owner_arbiter_fast_on=3
    [ "$_owner_arbiter_fast_off" -lt 10 ] 2>/dev/null && _owner_arbiter_fast_off=10
    [ "$_owner_arbiter_off_grace_s" -lt 60 ] 2>/dev/null && _owner_arbiter_off_grace_s=60
    [ "$_owner_arbiter_off_pause_s" -lt 600 ] 2>/dev/null && _owner_arbiter_off_pause_s=600
    [ "$_owner_arbiter_pause_poll_s" -lt 10 ] 2>/dev/null && _owner_arbiter_pause_poll_s=10
    _owner_arbiter_screen_off_since=0
    _owner_arbiter_long_paused=0

    while true; do
        _owner_arbiter_now=$(date +%s 2>/dev/null || echo 0)
        display_state_read >/dev/null 2>&1 || true
        _oa_screen=$(display_state_legacy_screen)

        if [ "$_oa_screen" = "on" ] && [ -f "$MODDIR/scripts/owner_arbiter.sh" ]; then
            _owner_arbiter_screen_off_since=0
            _owner_arbiter_long_paused=0
            sh "$MODDIR/scripts/owner_arbiter.sh" tick "$MODDIR" "$_oa_screen" 2>/dev/null
            sleep "$_owner_arbiter_fast_on"
        else
            if [ "$_owner_arbiter_screen_off_since" -eq 0 ] 2>/dev/null; then
                _owner_arbiter_screen_off_since="$_owner_arbiter_now"
            fi
            _owner_arbiter_off_elapsed=$((_owner_arbiter_now - _owner_arbiter_screen_off_since))
            if [ "$_owner_arbiter_off_elapsed" -ge "$_owner_arbiter_off_grace_s" ] 2>/dev/null; then
                if [ "$_owner_arbiter_long_paused" -ne 1 ] 2>/dev/null; then
                    log -t pixel9pro_ctrl "Owner arbiter paused after ${_owner_arbiter_off_elapsed}s screen-off"
                    _owner_arbiter_long_paused=1
                fi
                _owner_arbiter_pause_until=$((_owner_arbiter_now + _owner_arbiter_off_pause_s))
                while true; do
                    display_state_read >/dev/null 2>&1 || true
                    [ "$DISPLAY_STATE_INTERACTIVE" = "yes" ] && break
                    _owner_arbiter_now=$(date +%s 2>/dev/null || echo 0)
                    [ "$_owner_arbiter_now" -ge "$_owner_arbiter_pause_until" ] 2>/dev/null && break
                    sleep "$_owner_arbiter_pause_poll_s"
                done
                continue
            fi
            sleep "$_owner_arbiter_fast_off"
        fi
    done
) &
log -t pixel9pro_ctrl "Owner arbiter worker started"
else
    log -t pixel9pro_ctrl "Owner arbiter worker disabled: scheduler boot state=${SBM_PHASE:-unknown}/${SBM_EFFECTIVE_MODE:-unknown}"
fi

# Fixed-interval scheduler health worker. The health action is scheduler-node
# read-only. A first Pixel drift may enqueue one bounded repair generation;
# after that generation reaches a terminal state, later probes never write.
(
    while true; do
        sleep "$SBM_HEALTH_INTERVAL_S"
        sh "$MODDIR/scripts/scheduler_reconcile.sh" health "$MODDIR" >/dev/null 2>&1
        _scheduler_health_rc=$?
        if [ "$_scheduler_health_rc" -eq 5 ]; then
            sbm_load_state
            if [ "$SBM_EFFECTIVE_MODE" = "pixel" ] \
                && [ "$SBM_AUTO_REPAIR_USED" != "yes" ] \
                && [ "$SBM_PHASE" = "success" ]; then
                sh "$MODDIR/scripts/scheduler_reconcile.sh" repair "$MODDIR" >/dev/null 2>&1 || true
            fi
        fi
    done
) &
log -t pixel9pro_ctrl "Scheduler read-only health worker started (${SBM_HEALTH_INTERVAL_S}s)"

# ──────────────────────────────────────────────────────────
# 4. 统一后台工作循环 (Doze 友好)
#    屏幕状态优先读 DRM sysfs，仅在节点异常时回退一次 display/power IPC
#    亮屏 15s / 息屏首次 60s (NR防抖) / 息屏后续 600s / 突发 5s
#    若已降到 LTE, 改为较短复查周期，避免亮屏后长期停留 LTE
#    WiFi multicast: 仅在屏幕状态变化时切换，不轮询
#    NR 降级: 集成防抖，仅在开启时生效
#    温度历史: 仅亮屏记录，WebUI 前台突发窗口缩短为 5s
#    UECap: manual profile is applied only during boot or an explicit WebUI action
# ──────────────────────────────────────────────────────────
NR_SWITCH_FILE="$MODDIR/.nr_screen_switch"
NR_MODE_FILE="$MODDIR/.nr_saved_mode"
THERMAL_HISTORY="$MODDIR/.thermal_history"
THERMAL_HISTORY_MAX=8640
THERMAL_BURST_FILE="$MODDIR/.thermal_burst_until"
POWER_HISTORY="$MODDIR/.power_history"
POWER_HISTORY_MAX=20160
POWER_SESSION_FILE="$MODDIR/.power_session"

[ -f "$NR_SWITCH_FILE" ] || runtime_write_value "$NR_SWITCH_FILE" "$NR_SCREEN_SWITCH_DEFAULT" >/dev/null 2>&1 \
    || log -t pixel9pro_ctrl "WARNING: failed to initialize NR switch state"

(
    . "$MODDIR/webroot/cgi-bin/_thermal_cache.sh"

    _cleanup_nr() {
        if [ "$_nr_state" = "lte" ] && [ -n "$_nr_key" ]; then
            _nr_restore=$(nr_mode_read_saved "$NR_MODE_FILE" "$NR_SAVED_MODE_DEFAULT" 2>/dev/null)
            if [ -n "$_nr_restore" ] && nr_mode_write_verified "$_nr_key" "$_nr_restore"; then
                log -t pixel9pro_ctrl "NR switch: worker exit, restored NR"
            else
                log -t pixel9pro_ctrl "WARNING: worker exit NR restore failed"
            fi
        fi
    }
    trap '_cleanup_nr' EXIT
    trap '_cleanup_nr; exit 130' INT
    trap '_cleanup_nr; exit 143' TERM
    trap '_cleanup_nr; exit 129' HUP

    _write_standby_diag_state() {
        _diag_tmp="${STANDBY_DIAG_FILE}.tmp.$$"
        [ ! -d "$STANDBY_DIAG_FILE" ] || return 1
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
        } > "$_diag_tmp" 2>/dev/null \
            && mv "$_diag_tmp" "$STANDBY_DIAG_FILE" 2>/dev/null \
            && [ -f "$STANDBY_DIAG_FILE" ] && return 0
        rm -f "$_diag_tmp" 2>/dev/null
        return 1
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
        _ps_tmp="${POWER_SESSION_FILE}.tmp.$$"
        [ ! -d "$POWER_SESSION_FILE" ] || return 1
        {
            printf 'start_ts=%s\n' "$_ps_start"
            printf 'start_level=%s\n' "$_ps_level"
            printf 'start_charge_uah=%s\n' "${_ps_charge:-0}"
            printf 'reset_reason=%s\n' "$_ps_reason"
            printf 'odpm_modem_uws=%s\n' "$_odpm_modem"
            printf 'odpm_rffe_uws=%s\n' "$_odpm_rffe"
        } > "$_ps_tmp" 2>/dev/null \
            && mv "$_ps_tmp" "$POWER_SESSION_FILE" 2>/dev/null \
            && [ -f "$POWER_SESSION_FILE" ] && return 0
        rm -f "$_ps_tmp" 2>/dev/null
        return 1
    }

    _compact_power_history_if_needed() {
        [ "$_power_history_lines" -lt "$POWER_HISTORY_MAX" ] && return 0
        _keep=$((POWER_HISTORY_MAX - 240))
        _trim_tmp="${POWER_HISTORY}.trim.$$"
        if tail -n "$_keep" "$POWER_HISTORY" > "$_trim_tmp" 2>/dev/null; then
            if [ ! -d "$POWER_HISTORY" ] && mv "$_trim_tmp" "$POWER_HISTORY" 2>/dev/null \
                && [ -f "$POWER_HISTORY" ]; then
                _power_history_lines=$_keep
            else
                rm -f "$_trim_tmp" 2>/dev/null
                log -t pixel9pro_ctrl "WARNING: failed to compact power history"
            fi
        else
            rm -f "$_trim_tmp"
        fi
    }

    _compact_thermal_history_if_needed() {
        [ "$_thermal_history_lines" -lt "$THERMAL_HISTORY_MAX" ] && return 0
        _keep=$((THERMAL_HISTORY_MAX - 360))
        _trim_tmp="${THERMAL_HISTORY}.trim.$$"
        if tail -n "$_keep" "$THERMAL_HISTORY" > "$_trim_tmp" 2>/dev/null; then
            if [ ! -d "$THERMAL_HISTORY" ] && mv "$_trim_tmp" "$THERMAL_HISTORY" 2>/dev/null \
                && [ -f "$THERMAL_HISTORY" ]; then
                _thermal_history_lines=$_keep
            else
                rm -f "$_trim_tmp" 2>/dev/null
                log -t pixel9pro_ctrl "WARNING: failed to compact thermal history"
            fi
        else
            rm -f "$_trim_tmp"
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
                _write_power_session "$_now" "$_p_level" "$_p_charge" "boot_init" \
                    || log -t pixel9pro_ctrl "WARNING: failed to initialize power session"
            elif [ "$_power_prev_is_charging" -eq 1 ] && [ "$_power_reset_armed" -eq 1 ]; then
                _reason="charged_10m"
                [ "$_power_charge_seen_full" -eq 1 ] && _reason="full_replug"
                _write_power_session "$_now" "$_p_level" "$_p_charge" "$_reason" \
                    || log -t pixel9pro_ctrl "WARNING: failed to reset power session ($_reason)"
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
            _compact_power_history_if_needed
            printf '%s,%s,%s,%s\n' "$_now" "$_p_level" "$_p_charge" "$_p_status" >> "$POWER_HISTORY"
            _power_history_lines=$((_power_history_lines + 1))
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
        mkdir -p "${BG_STOP_STATE_FILE%/*}" 2>/dev/null || return 1
        [ ! -d "$BG_STOP_STATE_FILE" ] || return 1
        _bg_state_tmp="${BG_STOP_STATE_FILE}.tmp.$$"
        if [ -s "$BG_STOP_STATE_FILE" ]; then
            awk -F'|' -v p="$_bg_stop_pkg" '$1 != p' "$BG_STOP_STATE_FILE" > "$_bg_state_tmp" 2>/dev/null \
                || { rm -f "$_bg_state_tmp" 2>/dev/null; return 1; }
        else
            : > "$_bg_state_tmp" 2>/dev/null \
                || return 1
        fi
        printf '%s|%s|%s\n' "$_bg_stop_pkg" "$_bg_stop_since" "$_bg_stop_done" >> "$_bg_state_tmp" 2>/dev/null \
            && mv "$_bg_state_tmp" "$BG_STOP_STATE_FILE" 2>/dev/null \
            && [ -f "$BG_STOP_STATE_FILE" ] && return 0
        rm -f "$_bg_state_tmp" 2>/dev/null
        return 1
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
                _bg_stop_state_set "$_bg_pkg" "$_now" 0 \
                    || log -t pixel9pro_ctrl "WARNING: failed to persist background-stop timer for $_bg_pkg"
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
                    _bg_stop_state_set "$_bg_pkg" "$_now" 1 \
                        || log -t pixel9pro_ctrl "WARNING: failed to persist background-stop completion for $_bg_pkg"
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

    # Detect the active Settings key once. DSDS values keep slot 1 unchanged.
    nr_mode_detect_setting
    _nr_key="$NR_MODE_KEY"
    _cur="$NR_MODE_CURRENT"
    if nr_mode_is_valid_raw "$_cur" && nr_mode_is_nr_capable "$_cur"; then
        nr_mode_save_current "$NR_MODE_FILE" "$_cur" >/dev/null 2>&1 \
            || log -t pixel9pro_ctrl "WARNING: failed to persist current NR mode"
    elif [ ! -s "$NR_MODE_FILE" ]; then
        runtime_write_value "$NR_MODE_FILE" "$NR_SAVED_MODE_DEFAULT" >/dev/null 2>&1 \
            || log -t pixel9pro_ctrl "WARNING: failed to initialize NR mode fallback"
    fi

    _NR_LTE="$NR_LTE_MODE"
    _mc_state=""
    _cur_slot0=$(nr_mode_slot0 "$_cur")
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
    _sim2_check_count=0
    # _NR_DELAY: 屏幕熄灭后多久才切到 LTE-only。
    # 60s 会让短时间锁屏(口袋亮灭/查看消息)反复触发 modem 重注册,
    # 每次 attach/detach 持 s5100_wake_lock ~1-2s。300s 防抖,只在真待机时切。
    _NR_DELAY="$NR_SCREEN_OFF_DELAY_S"
    _NR_COOLDOWN="$NR_RESTORE_COOLDOWN_S"
    # _NR_LTE_POLL: 切换到 LTE 后,worker 多久醒一次检查屏幕状态。
    # 60s 节奏会让 alarmtimer.4.auto 与 suspend 流程挤兑(实测 71 次 failed_suspend)。
    # 300s 把 wakeup 密度降到 12 次/h,给 kernel 真正的 deep suspend 窗口。
    # 代价:屏幕点亮后 NR 恢复最多滞后 5 分钟(用户体感可接受,RIL 数据通道不受影响)。
    _NR_LTE_POLL="$NR_LTE_RECHECK_S"
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
    if [ -s "$THERMAL_HISTORY" ]; then
        _thermal_history_lines=$(wc -l < "$THERMAL_HISTORY" 2>/dev/null)
    else
        _thermal_history_lines=0
    fi
    if [ -s "$POWER_HISTORY" ]; then
        _power_history_lines=$(wc -l < "$POWER_HISTORY" 2>/dev/null)
    else
        _power_history_lines=0
    fi
    case "$_thermal_history_lines" in ''|*[!0-9]*) _thermal_history_lines=0 ;; esac
    case "$_power_history_lines" in ''|*[!0-9]*) _power_history_lines=0 ;; esac
    _compact_thermal_history_if_needed
    _compact_power_history_if_needed
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
        sbm_load_state
        _scheduler_profile_writable=0
        if [ "$SBM_PHASE" = "success" ] && [ "$SBM_EFFECTIVE_MODE" = "pixel" ] \
            && [ "$_sched_owner" = "pixel" ]; then
            _scheduler_profile_writable=1
        else
            _sched_owner=external
        fi

        # DeviceIdle tracks user interactivity across ON/AOD/OFF. DRM enabled
        # only identifies an attached encoder and remains enabled during DOZE.
        display_state_read >/dev/null 2>&1 || true
        _screen=$(display_state_legacy_screen)
        [ "$_screen" != "unknown" ] || _screen="off"
        _idle_isolate=$(read_onoff_file "$IDLE_ISOLATE_FILE" "$IDLE_ISOLATE_DEFAULT")
        _sim2_auto=$(read_onoff_file "$SIM2_AUTO_FILE" "$SIM2_AUTO_DEFAULT")
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

        # Check SIM2 every ~10 on-screen cycles. Boot performs one initial
        # application; screen-off avoids telephony IPC so suspend is not disturbed.
        if [ "$_screen" = "on" ] && [ "$_idle_isolate" != "on" ]; then
            _sim2_check_count=$((_sim2_check_count + 1))
            if [ "$_sim2_check_count" -ge 10 ]; then
                manage_sim2_radio
                _sim2_check_count=0
            fi
        fi

        # --- NR screen-off switch ---
        _nr_enabled=$(read_onoff_file "$NR_SWITCH_FILE" "$NR_SCREEN_SWITCH_DEFAULT")
        if [ "$_screen_off_isolate" -eq 1 ]; then
            _nr_off_since=0
        else
            if [ "$_nr_enabled" != "on" ]; then
                if [ "$_nr_state" = "lte" ]; then
                    _nr_restore=$(nr_mode_read_saved "$NR_MODE_FILE" "$NR_SAVED_MODE_DEFAULT" 2>/dev/null)
                    if [ -n "$_nr_restore" ] && nr_mode_write_verified "$_nr_key" "$_nr_restore"; then
                        _nr_state="5g"
                        _nr_restored=$_now
                        log -t pixel9pro_ctrl "NR switch: disabled, restored NR"
                    else
                        log -t pixel9pro_ctrl "WARNING: NR switch disabled but restore failed"
                    fi
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
                            if ! nr_mode_is_valid_raw "$_cur" || ! nr_mode_is_nr_capable "$_cur"; then
                                log -t pixel9pro_ctrl "WARNING: NR switch skipped invalid current mode ($_cur)"
                            elif ! nr_mode_save_current "$NR_MODE_FILE" "$_cur"; then
                                log -t pixel9pro_ctrl "WARNING: NR switch skipped because restore mode could not be persisted"
                            else
                                _lte_val=$(nr_mode_replace_slot0 "$_cur" "$_NR_LTE")
                            fi
                            if [ -n "${_lte_val:-}" ] && nr_mode_write_verified "$_nr_key" "$_lte_val"; then
                                _nr_state="lte"
                                log -t pixel9pro_ctrl "NR switch: off ${_elapsed}s, switched to LTE ($_lte_val)"
                            elif [ -n "${_lte_val:-}" ]; then
                                log -t pixel9pro_ctrl "WARNING: NR switch to LTE failed ($_lte_val)"
                            fi
                            _lte_val=""
                        fi
                    fi
                fi
            else
                _nr_off_since=0
                if [ "$_nr_state" = "lte" ]; then
                    _nr_restore=$(nr_mode_read_saved "$NR_MODE_FILE" "$NR_SAVED_MODE_DEFAULT" 2>/dev/null)
                    if [ -n "$_nr_restore" ] && nr_mode_write_verified "$_nr_key" "$_nr_restore"; then
                        _nr_state="5g"
                        _nr_restored=$_now
                        log -t pixel9pro_ctrl "NR switch: screen on, restored NR"
                    else
                        log -t pixel9pro_ctrl "WARNING: screen on but NR restore failed"
                    fi
                fi
            fi
        fi

        # Screen-off skips thermal/profile sampling to protect deep standby,
        # while power tracking remains active for session accounting.
        _burst_until=$(cat "$THERMAL_BURST_FILE" 2>/dev/null | tr -d ' \n\r')
        _burst_active=0
        if [ -n "$_burst_until" ] && [ "$_burst_until" -gt "$_now" ] 2>/dev/null; then
            _burst_active=1
        fi
        # 高频温度记录只允许亮屏。WebUI 进入后台时会清除 burst 标记；
        # 即使标记因进程切换未及时清除，息屏也绝不进入 5s 采样路径。
        _burst_effective=0
        if [ "$_screen" = "on" ] && [ "$_burst_active" -eq 1 ]; then
            _burst_effective=1
        fi

        _worker_mode="deep_standby"
        _vs_temp=""
        if [ "$_screen" = "on" ]; then
            _worker_mode="screen_on"
            # --- 仅亮屏执行 thermal 更新；WebUI 历史页可临时提高采样频率 ---
            _json=$(build_thermal_json 2>/dev/null)
            if [ -n "$_json" ] && [ "$_json" != "[]" ]; then
                if ! runtime_write_value "$THERMAL_CACHE" "$_json"; then
                    log -t pixel9pro_ctrl "WARNING: failed to refresh thermal cache"
                fi

                _vs_temp=$(printf '%s' "$_json" | sed 's/.*VIRTUAL-SKIN","temp":\([0-9]*\).*/\1/')
                if [ -n "$_vs_temp" ] && [ "$_vs_temp" != "$_json" ]; then
                    _compact_thermal_history_if_needed
                    printf '%s,%s\n' "$_now" "$_vs_temp" >> "$THERMAL_HISTORY"
                    _thermal_history_lines=$((_thermal_history_lines + 1))
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
                _active_profile=$(read_valid_profile "$PROFILE_FILE" "$_active_profile")
                if [ "$(cat "$PROFILE_AUTO_REASON_FILE" 2>/dev/null | tr -d ' \r\n\t')" != "external_scheduler" ]; then
                    runtime_write_value "$PROFILE_AUTO_REASON_FILE" external_scheduler >/dev/null 2>&1 \
                        || log -t pixel9pro_ctrl "WARNING: failed to persist external scheduler reason"
                fi
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
                    # Discharge uses the VIRTUAL-SKIN thresholds and hold times
                    # defined by the _AUTO_BATTERY_* / _AUTO_BALANCED_* contract.
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
                    elif [ "$_active_profile" = "battery" ]; then
                        # Keep battery inside the configured hot/cool deadband;
                        # otherwise one sample below the hot threshold would
                        # bypass the cool hold and make the profile oscillate.
                        _target_profile="battery"
                        _target_reason="steady_hot_guard"
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
                        runtime_write_value "$PROFILE_AUTO_REASON_FILE" "$_target_reason" >/dev/null 2>&1 \
                            || log -t pixel9pro_ctrl "WARNING: failed to update profile reason: $_target_reason"
                    fi
                fi
            else
                # --- 息屏深度待机: 不做前台探测 / 自动调度 ---
                if [ "$_active_profile" != "balanced" ]; then
                    if apply_profile_state "balanced" "deep_standby_reset"; then
                        _active_profile="balanced"
                    fi
                elif [ "$_just_off" -eq 1 ]; then
                    runtime_write_value "$PROFILE_AUTO_REASON_FILE" deep_standby_reset >/dev/null 2>&1 \
                        || log -t pixel9pro_ctrl "WARNING: failed to persist deep-standby profile reason"
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
            if [ "$_burst_effective" -eq 1 ]; then
                _next_sleep_secs=5
            else
                _next_sleep_secs=15
            fi
        elif [ "$_screen_off_isolate" -eq 1 ]; then
            _just_off=0
            _next_sleep_secs=600
        elif [ "$_just_off" -eq 1 ]; then
            _just_off=0
            _next_sleep_secs=60
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
        _write_standby_diag_state "$_now" "$_screen" "$_worker_mode" "$_next_sleep_secs" "$_burst_effective" "$_nr_enabled" "$_nr_state" "$_diag_profile_policy" "$_active_profile" "$_idle_isolate" "$_sim2_auto" "$_cycle_count" \
            || log -t pixel9pro_ctrl "WARNING: failed to persist standby diagnostics"
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
        if "$BB" httpd -p "127.0.0.1:$PORT" -h "$MODDIR/webroot" \
            && record_webui_httpd_pid; then
            log -t pixel9pro_ctrl "WebUI(loopback)[$ROOT_IMPL]: http://127.0.0.1:$PORT"
        else
            log -t pixel9pro_ctrl "ERROR[$ROOT_IMPL]: WebUI httpd failed to start or publish its PID"
        fi
    fi
else
    log -t pixel9pro_ctrl "WARNING[$ROOT_IMPL]: busybox not found"
fi
