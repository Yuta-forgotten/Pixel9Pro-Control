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
DEFAULTS_LIB="$MODDIR/scripts/runtime_defaults_lib.sh"

[ -r "$DEFAULTS_LIB" ] && . "$DEFAULTS_LIB" \
    || json_error '500 Internal Server Error' 'runtime defaults contract not found'
. "$MODDIR/scripts/background_tasks_lib.sh" \
    || json_error '500 Internal Server Error' 'background lifecycle contract not found'

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

sleep_error_human() {
    case "$2" in
        -16) printf '内核记录的最后一次 suspend 回调返回 EBUSY（-16）；设备名和错误码不能单独确定原因，也不代表刚刚发生。' ;;
        ''|0) printf '没有可用的最后一次 suspend 失败记录；这不等同于整个时间窗口没有失败。' ;;
        *) printf '下方为内核最后一次 suspend 失败记录；原因需结合同一 boot、同一时间段的日志核对。' ;;
    esac
}

sleep_error_code() {
    case "$1:$2" in
        *:-16*) printf DEVICE_SUSPEND_EBUSY ;;
        *) printf SUSPEND_REASON_UNKNOWN ;;
    esac
}

emit_state() {
    _sim2_auto=$(read_onoff_file "$SIM2_AUTO_FILE" "$SIM2_AUTO_DEFAULT")
    _idle_isolate_mode=$(read_onoff_file "$IDLE_ISOLATE_FILE" "$IDLE_ISOLATE_DEFAULT")
    _background_state=$(background_tasks_state)
    _background_enabled=false
    background_tasks_enabled && _background_enabled=true
    _background_final=true
    case "$_background_state" in starting|stopping|stopped) _background_final=false ;; esac
    _background_cleanup=none
    [ "$_background_state" != paused ] || _background_cleanup=$(background_tasks_cleanup_state)
    [ "$_background_cleanup" != unconfirmed ] || _background_final=false
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

    if [ -f "$STANDBY_DIAG_FILE" ] \
        && [ "$(read_state_value "$STANDBY_DIAG_FILE" boot_id '')" = "$(cat /proc/sys/kernel/random/boot_id)" ] \
        && [ "$(read_state_value "$STANDBY_DIAG_FILE" worker_id '')" = "$(cat "$MODDIR/.background_run" 2>/dev/null)" ]; then
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

    printf '"background_enabled":%s,"background_state":"%s","background_cleanup":"%s","final":%s,' "$_background_enabled" "$_background_state" "$_background_cleanup" "$_background_final"
    printf '"sim2_auto_manage":"%s","idle_isolate_mode":"%s","sleep_mode":"%s","sleep_last_failed_dev":"%s","sleep_last_failed_errno":"%s","sleep_last_failed_step":"%s","sleep_error_code":"%s","sleep_error_severity":"%s","sleep_error_human":"%s","diag_updated_at":"%s","diag_screen":"%s","diag_worker_mode":"%s","diag_next_sleep_secs":"%s","diag_burst_active":"%s","diag_nr_switch":"%s","diag_nr_state":"%s","diag_profile_policy":"%s","diag_active_profile":"%s","diag_cycle_count":"%s"' \
        "$_sim2_auto" "$_idle_isolate_mode" \
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
    acquire_lock "standby_guard"
    read_json_body 512
    body="$JSON_BODY"

    cgi_json_schema 'sim2_auto_manage:string idle_isolate_mode:string'
    new_sim2=$(cgi_json_field sim2_auto_manage)
    new_isolate=$(cgi_json_field idle_isolate_mode)

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
    _sim2_old=$(cgi_read_entry "$SIM2_AUTO_FILE") \
        || json_error '500 Internal Server Error' 'cannot snapshot existing state before mutation'
    _isolate_old=$(cgi_read_entry "$IDLE_ISOLATE_FILE") \
        || json_error '500 Internal Server Error' 'cannot snapshot existing state before mutation'
    if { [ -z "$new_sim2" ] || cgi_atomic_write "$SIM2_AUTO_FILE" "$new_sim2"; } \
        && { [ -z "$new_isolate" ] || cgi_atomic_write "$IDLE_ISOLATE_FILE" "$new_isolate"; }; then
        :
    else
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

    if [ -n "$new_isolate" ]; then
        # Persist intent first so every writer immediately rejects new work.
        # Stop is bounded but never kills an in-flight policy rollback.
        if [ "$new_isolate" = on ]; then
            background_tasks_stop
            _background_rc=$?
        else
            background_tasks_start
            _background_rc=$?
        fi
        if [ "$_background_rc" -ne 0 ] && [ "$_background_rc" -ne 75 ]; then
            if restore_standby_files; then
                if background_tasks_enabled; then background_tasks_start; else background_tasks_stop; fi
                _background_rollback_rc=$?
                [ "$_background_rollback_rc" -eq 0 ] \
                    && json_error '500 Internal Server Error' 'background lifecycle failed; previous state restored'
            fi
            json_error '500 Internal Server Error' 'background lifecycle failed and rollback was incomplete'
        fi
    fi

    _cleanup_state=$(background_tasks_cleanup_state)
    if [ "$new_isolate" = on ] && [ "$(background_tasks_state)" = paused ] \
        && { [ "$_cleanup_state" = failed ] || [ "$_cleanup_state" = unconfirmed ]; }; then
        json_status_headers '500 Internal Server Error'
        printf '{"ok":false,"committed":true,"error":"background stopped; temporary policy restoration failed or is unconfirmed; pause intent retained",'
        emit_state
        printf '}\n'
        exit 1
    fi
    json_headers
    printf '{"ok":true,'
    emit_state
    printf '}\n'
else
    json_error '405 Method Not Allowed' 'GET or POST'
fi
