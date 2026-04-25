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

read_onoff_file() {
    _flag_value=$(cat "$1" 2>/dev/null | tr -d ' \n\r\t')
    case "$_flag_value" in
        on|off) printf '%s' "$_flag_value" ;;
        *) printf '%s' "$2" ;;
    esac
}

emit_state() {
    sim2_auto=$(read_onoff_file "$SIM2_AUTO_FILE" 'off')
    idle_isolate=$(read_onoff_file "$IDLE_ISOLATE_FILE" 'off')

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
        . "$STANDBY_DIAG_FILE" 2>/dev/null
        diag_updated_at="${updated_at:-}"
        diag_screen="${screen:-unknown}"
        diag_worker_mode="${worker_mode:-unknown}"
        diag_next_sleep_secs="${next_sleep_secs:-}"
        diag_burst_active="${burst_active:-0}"
        diag_nr_switch="${nr_switch:-off}"
        diag_nr_state="${nr_state:-unknown}"
        diag_profile_policy="${profile_policy:-unknown}"
        diag_active_profile="${active_profile:-unknown}"
        diag_cycle_count="${cycle_count:-0}"
    fi

    printf '"sim2_auto_manage":"%s","idle_isolate_mode":"%s","diag_updated_at":"%s","diag_screen":"%s","diag_worker_mode":"%s","diag_next_sleep_secs":"%s","diag_burst_active":"%s","diag_nr_switch":"%s","diag_nr_state":"%s","diag_profile_policy":"%s","diag_active_profile":"%s","diag_cycle_count":"%s"' \
        "$sim2_auto" "$idle_isolate" \
        "$(json_escape "$diag_updated_at")" "$(json_escape "$diag_screen")" "$(json_escape "$diag_worker_mode")" \
        "$(json_escape "$diag_next_sleep_secs")" "$(json_escape "$diag_burst_active")" "$(json_escape "$diag_nr_switch")" \
        "$(json_escape "$diag_nr_state")" "$(json_escape "$diag_profile_policy")" "$(json_escape "$diag_active_profile")" \
        "$(json_escape "$diag_cycle_count")"
}

restore_sim2_unmanaged_state() {
    _prev_state=$(cat "$SIM2_RADIO_STATE_FILE" 2>/dev/null | tr -d ' \n\r\t')
    if [ "$_prev_state" = "disabled" ]; then
        cmd phone radio power -s 1 on 2>/dev/null
        cmd phone ims enable -s 1 2>/dev/null
        printf 'enabled' > "$SIM2_RADIO_STATE_FILE"
    fi
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
    len="${CONTENT_LENGTH:-0}"
    [ "$len" -gt 512 ] 2>/dev/null && len=512
    body=$(dd bs=1 count="$len" 2>/dev/null)

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

    if [ -n "$new_sim2" ]; then
        printf '%s' "$new_sim2" > "$SIM2_AUTO_FILE"
        [ "$new_sim2" = "off" ] && restore_sim2_unmanaged_state
    fi
    [ -n "$new_isolate" ] && printf '%s' "$new_isolate" > "$IDLE_ISOLATE_FILE"

    json_headers
    printf '{"ok":true,'
    emit_state
    printf '}\n'
else
    json_error '405 Method Not Allowed' 'GET or POST'
fi
