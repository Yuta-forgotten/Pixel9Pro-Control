#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/standby_guard.sh
# GET  -> 返回待机守护状态 + 低噪声诊断摘要
# POST -> 切换 sim2_auto_manage / idle_isolate_mode
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

SIM2_AUTO_FILE="$MODDIR/.sim2_auto_manage"
IDLE_ISOLATE_FILE="$MODDIR/.idle_isolate_mode"
STANDBY_DIAG_FILE="$MODDIR/.standby_diag_state"
SIM2_RADIO_STATE_FILE="$MODDIR/.sim2_radio_off"
STATE_ROOT="${PIXEL9PRO_STATE_ROOT:-/data/adb/pixel9pro_control}"
HISTORY_CONFIG="$STATE_ROOT/system_history_config"
ANALYTICS_PREV_FILE="$MODDIR/.analytics_enabled_before_isolate"
DEFAULTS_LIB="$MODDIR/scripts/runtime_defaults_lib.sh"

[ -r "$DEFAULTS_LIB" ] && . "$DEFAULTS_LIB" \
    || json_error '500 Internal Server Error' 'runtime defaults contract not found'

read_onoff_file() {
    runtime_read_onoff "$1" "$2"
}

read_state_value() {
    _sg_file="$1"
    _sg_key="$2"
    _sg_default="$3"
    _sg_value=$(sed -n "s/^${_sg_key}=//p" "$_sg_file" 2>/dev/null | head -n 1 | tr -d '\r')
    [ -n "$_sg_value" ] || _sg_value="$_sg_default"
    printf '%s' "$_sg_value"
}

analytics_enabled_value() {
    case "$(sed -n 's/^analytics_enabled=//p' "$HISTORY_CONFIG" 2>/dev/null | head -n 1 | tr -d ' \r\n\t')" in
        0|false|off|no) printf false ;;
        *) printf true ;;
    esac
}

sleep_error_human() {
    case "$1:$2" in
        *19470000.drmdecon:-16*) printf '显示设备在 AOD/atomic commit 尚未完成 hibernation，内核暂缓 suspend。' ;;
        *wlan*:*|*dhdpcie*:*|*cp2ap_wakeup*:*) printf 'Wi-Fi/网络唤醒源仍有活动，系统进入 suspend 后被网络事件唤醒。' ;;
        *s5100*:*|*rmnet*:*|*cpif*:*) printf '基带/蜂窝 modem 唤醒源仍有活动，suspend 回调暂未完成。' ;;
        *:-16*) printf '设备仍处于活动提交或唤醒状态，suspend 回调返回 EBUSY。' ;;
        *) printf '当前没有可归类的 suspend 失败原因；请结合同一 boot 的 kernel log 复核。' ;;
    esac
}

sleep_error_code() {
    case "$1:$2" in
        *19470000.drmdecon:-16*) printf DISPLAY_HIBERNATION_BUSY ;;
        *wlan*:*|*dhdpcie*:*|*cp2ap_wakeup*:*) printf NETWORK_WAKEUP ;;
        *s5100*:*|*rmnet*:*|*cpif*:*) printf MODEM_WAKEUP ;;
        *:-16*) printf DEVICE_SUSPEND_EBUSY ;;
        *) printf SUSPEND_REASON_UNKNOWN ;;
    esac
}

analytics_config_write_enabled() {
    _sg_enabled="$1"
    _sg_old=$(cat "$HISTORY_CONFIG" 2>/dev/null || true)
    _sg_new=$(printf '%s\n' "$_sg_old" | sed '/^analytics_enabled=/d')
    _sg_new=$(printf 'analytics_enabled=%s\n%s\n' "$_sg_enabled" "$_sg_new")
    mkdir -p "$STATE_ROOT" 2>/dev/null || return 1
    cgi_atomic_write "$HISTORY_CONFIG" "$_sg_new"
}

stop_module_observers() {
    _sg_rank_lock="$MODDIR/.power_rank/collect.lock"
    _sg_rank_pid=$(cat "$_sg_rank_lock/pid" 2>/dev/null | tr -d ' \r\n\t')
    _sg_rank_start=$(cat "$_sg_rank_lock/start_ticks" 2>/dev/null | tr -d ' \r\n\t')
    _sg_rank_boot=$(cat "$_sg_rank_lock/boot_id" 2>/dev/null | tr -d ' \r\n\t')
    _sg_rank_live_start=$(process_start_ticks "$_sg_rank_pid" 2>/dev/null || true)
    _sg_current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \r\n\t')
    case "$_sg_rank_pid" in ''|*[!0-9]*) _sg_rank_pid=0 ;; esac
    if [ "$_sg_rank_pid" -gt 0 ] 2>/dev/null && [ -n "$_sg_rank_start" ] && [ -n "$_sg_rank_boot" ] && [ "$_sg_rank_start" = "$_sg_rank_live_start" ] && [ "$_sg_rank_boot" = "$_sg_current_boot" ] && kill -0 "$_sg_rank_pid" 2>/dev/null; then
        kill -TERM "$_sg_rank_pid" 2>/dev/null || true
        sleep 1
        _sg_rank_live_start=$(process_start_ticks "$_sg_rank_pid" 2>/dev/null || true)
        [ "$_sg_rank_start" = "$_sg_rank_live_start" ] && kill -KILL "$_sg_rank_pid" 2>/dev/null || true
    fi
    _sg_telemetry_state="$MODDIR/.telemetry/state"
    _sg_telemetry_pid=$(sed -n 's/^pid=//p' "$_sg_telemetry_state" 2>/dev/null | head -n 1 | tr -d ' \r\n\t')
    _sg_telemetry_start=$(sed -n 's/^pid_start_ticks=//p' "$_sg_telemetry_state" 2>/dev/null | head -n 1 | tr -d ' \r\n\t')
    _sg_telemetry_boot=$(sed -n 's/^boot_id=//p' "$_sg_telemetry_state" 2>/dev/null | head -n 1 | tr -d ' \r\n\t')
    _sg_telemetry_live_start=$(process_start_ticks "$_sg_telemetry_pid" 2>/dev/null || true)
    case "$_sg_telemetry_pid" in ''|*[!0-9]*) _sg_telemetry_pid=0 ;; esac
    if [ "$_sg_telemetry_pid" -gt 0 ] 2>/dev/null && [ -n "$_sg_telemetry_start" ] && [ -n "$_sg_telemetry_boot" ] && [ "$_sg_telemetry_start" = "$_sg_telemetry_live_start" ] && [ "$_sg_telemetry_boot" = "$_sg_current_boot" ] && kill -0 "$_sg_telemetry_pid" 2>/dev/null; then
        kill -TERM "$_sg_telemetry_pid" 2>/dev/null || true
        sleep 1
        _sg_telemetry_live_start=$(process_start_ticks "$_sg_telemetry_pid" 2>/dev/null || true)
        [ "$_sg_telemetry_start" = "$_sg_telemetry_live_start" ] && kill -KILL "$_sg_telemetry_pid" 2>/dev/null || true
    fi
}

emit_state() {
    _sim2_auto=$(read_onoff_file "$SIM2_AUTO_FILE" "$SIM2_AUTO_DEFAULT")
    _idle_isolate_mode=$(read_onoff_file "$IDLE_ISOLATE_FILE" "$IDLE_ISOLATE_DEFAULT")
    _analytics_enabled=$(analytics_enabled_value)
    _sleep_mode=$(cat /sys/power/mem_sleep 2>/dev/null | tr -d '\r\n')
    _sleep_failed_dev=$(cat /sys/power/suspend_stats/last_failed_dev 2>/dev/null | tr -d ' \r\n')
    _sleep_failed_errno=$(cat /sys/power/suspend_stats/last_failed_errno 2>/dev/null | tr -d ' \r\n')
    _sleep_failed_step=$(cat /sys/power/suspend_stats/last_failed_step 2>/dev/null | tr -d ' \r\n')
    _sleep_error=$(sleep_error_human "$_sleep_failed_dev" "$_sleep_failed_errno")
    _sleep_error_code=$(sleep_error_code "$_sleep_failed_dev" "$_sleep_failed_errno")
    _sleep_error_severity=info
    [ -n "$_sleep_failed_dev" ] && _sleep_error_severity=warning

    diag_updated_at=""
    diag_screen="unknown"
    diag_worker_mode="unknown"
    diag_next_sleep_secs=""
    diag_burst_active="0"
    diag_nr_switch="off"
    diag_nr_state="unknown"
    diag_profile_policy="unknown"
    diag_active_profile="unknown"
    diag_cycle_count="0"

    if [ -f "$STANDBY_DIAG_FILE" ]; then
        diag_updated_at=$(read_state_value "$STANDBY_DIAG_FILE" updated_at "")
        diag_screen=$(read_state_value "$STANDBY_DIAG_FILE" screen "unknown")
        diag_worker_mode=$(read_state_value "$STANDBY_DIAG_FILE" worker_mode "unknown")
        diag_next_sleep_secs=$(read_state_value "$STANDBY_DIAG_FILE" next_sleep_secs "")
        diag_burst_active=$(read_state_value "$STANDBY_DIAG_FILE" burst_active "0")
        diag_nr_switch=$(read_state_value "$STANDBY_DIAG_FILE" nr_switch "off")
        diag_nr_state=$(read_state_value "$STANDBY_DIAG_FILE" nr_state "unknown")
        diag_profile_policy=$(read_state_value "$STANDBY_DIAG_FILE" profile_policy "unknown")
        diag_active_profile=$(read_state_value "$STANDBY_DIAG_FILE" active_profile "unknown")
        diag_cycle_count=$(read_state_value "$STANDBY_DIAG_FILE" cycle_count "0")
    fi

    printf '"sim2_auto_manage":"%s","idle_isolate_mode":"%s","analytics_enabled":%s,"background_mode":"%s","sleep_mode":"%s","sleep_last_failed_dev":"%s","sleep_last_failed_errno":"%s","sleep_last_failed_step":"%s","sleep_error_code":"%s","sleep_error_severity":"%s","sleep_error_human":"%s","diag_updated_at":"%s","diag_screen":"%s","diag_worker_mode":"%s","diag_next_sleep_secs":"%s","diag_burst_active":"%s","diag_nr_switch":"%s","diag_nr_state":"%s","diag_profile_policy":"%s","diag_active_profile":"%s","diag_cycle_count":"%s"' \
        "$_sim2_auto" "$_idle_isolate_mode" "$_analytics_enabled" "$([ "$_analytics_enabled" = true ] && printf normal || printf foreground_only)" \
        "$(json_escape "$_sleep_mode")" "$(json_escape "$_sleep_failed_dev")" "$(json_escape "$_sleep_failed_errno")" "$(json_escape "$_sleep_failed_step")" "$_sleep_error_code" "$_sleep_error_severity" "$(json_escape "$_sleep_error")" \
        "$(json_escape "$diag_updated_at")" "$(json_escape "$diag_screen")" "$(json_escape "$diag_worker_mode")" \
        "$(json_escape "$diag_next_sleep_secs")" "$(json_escape "$diag_burst_active")" "$(json_escape "$diag_nr_switch")" \
        "$(json_escape "$diag_nr_state")" "$(json_escape "$diag_profile_policy")" "$(json_escape "$diag_active_profile")" \
        "$(json_escape "$diag_cycle_count")"
}

restore_sim2_unmanaged_state() {
    _prev_state=$(cat "$SIM2_RADIO_STATE_FILE" 2>/dev/null | tr -d ' \n\r\t')
    if [ "$_prev_state" = "disabled" ]; then
        runtime_set_sim_count_state "$SIM2_RADIO_STATE_FILE" 2 enabled 1
    fi
}

restore_standby_files() {
    _standby_restore_ok=1
    cgi_restore_file "$SIM2_AUTO_FILE" "$_sim2_existed" "$_sim2_old" \
        >/dev/null 2>&1 || _standby_restore_ok=0
    cgi_restore_file "$IDLE_ISOLATE_FILE" "$_isolate_existed" "$_isolate_old" \
        >/dev/null 2>&1 || _standby_restore_ok=0
    [ "$_standby_restore_ok" -eq 1 ]
}

require_loopback

if [ "$REQUEST_METHOD" = "GET" ]; then
    json_headers
    printf '{'
    emit_state
    printf '}\n'
elif [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    # The idle-isolate toggle also updates system_history_config.  Reuse the
    # history policy lock so a policy POST and a standby toggle cannot do
    # last-writer-wins updates to the same backend-owned file.
    acquire_lock "system_history_policy"
    read_json_body 512
    body="$JSON_BODY"

    new_sim2=$(printf '%s' "$body" | sed -n 's/.*"sim2_auto_manage"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
    new_isolate=$(printf '%s' "$body" | sed -n 's/.*"idle_isolate_mode"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')

    case "$new_sim2" in
        ''|on|off) ;;
        *) json_error '400 Bad Request' 'invalid sim2_auto_manage' ;;
    esac
    case "$new_isolate" in
        ''|on|off) ;;
        *) json_error '400 Bad Request' 'invalid idle_isolate_mode' ;;
    esac

    [ -n "$new_sim2" ] || [ -n "$new_isolate" ] || json_error '400 Bad Request' 'missing standby guard field'

    _sim2_existed=0
    _isolate_existed=0
    [ -e "$SIM2_AUTO_FILE" ] && _sim2_existed=1
    [ -e "$IDLE_ISOLATE_FILE" ] && _isolate_existed=1
    _sim2_old=$(cat "$SIM2_AUTO_FILE" 2>/dev/null)
    _isolate_old=$(cat "$IDLE_ISOLATE_FILE" 2>/dev/null)
    _analytics_old=$(sed -n 's/^analytics_enabled=//p' "$HISTORY_CONFIG" 2>/dev/null | head -n 1 | tr -d ' \r\n\t')
    _analytics_prev_existed=0
    [ -e "$ANALYTICS_PREV_FILE" ] && _analytics_prev_existed=1
    _analytics_prev_old=$(cat "$ANALYTICS_PREV_FILE" 2>/dev/null)

    if [ "$new_isolate" = on ]; then
        [ -n "$_analytics_old" ] || _analytics_old=1
        cgi_atomic_write "$ANALYTICS_PREV_FILE" "$_analytics_old" \
            && analytics_config_write_enabled 0 \
            || json_error '500 Internal Server Error' 'failed to enter foreground-only standby mode'
        stop_module_observers
    elif [ "$new_isolate" = off ]; then
        _analytics_restore="$_analytics_prev_old"
        [ -n "$_analytics_restore" ] || _analytics_restore=1
        analytics_config_write_enabled "$_analytics_restore" \
            || json_error '500 Internal Server Error' 'failed to restore background analytics mode'
        cgi_restore_file "$ANALYTICS_PREV_FILE" "$_analytics_prev_existed" "$_analytics_prev_old" \
            >/dev/null 2>&1 || true
    fi

    if { [ -z "$new_sim2" ] || cgi_atomic_write "$SIM2_AUTO_FILE" "$new_sim2"; } \
        && { [ -z "$new_isolate" ] || cgi_atomic_write "$IDLE_ISOLATE_FILE" "$new_isolate"; }; then
        :
    else
        analytics_config_write_enabled "${_analytics_old:-1}" >/dev/null 2>&1 || true
        cgi_restore_file "$ANALYTICS_PREV_FILE" "$_analytics_prev_existed" "$_analytics_prev_old" >/dev/null 2>&1 || true
        if restore_standby_files; then
            json_error '500 Internal Server Error' 'failed to persist standby setting; previous state restored'
        fi
        json_error '500 Internal Server Error' 'failed to persist standby setting and rollback was incomplete'
    fi
    if [ "$new_sim2" = "off" ] && ! restore_sim2_unmanaged_state; then
        _sim2_result="$SIM2_TRANSACTION_RESULT"
        if restore_standby_files && [ "$_sim2_result" != "state_failed_rollback_incomplete" ]; then
            json_error '500 Internal Server Error' "failed to restore DSDS ($_sim2_result); previous state restored"
        fi
        json_error '500 Internal Server Error' "failed to restore DSDS ($_sim2_result) and rollback was incomplete"
    fi

    json_headers
    printf '{"ok":true,'
    emit_state
    printf '}\n'
else
    json_error '405 Method Not Allowed' 'GET or POST'
fi
