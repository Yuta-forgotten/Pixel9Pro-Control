#!/system/bin/sh

# NTP state and mutation CGI. Hosts, labels, and the module default come from
# config/ntp_servers.tsv through the shared parser; request values are never
# evaluated as shell code.

. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback

NTP_SAVE="$MODDIR/.ntp_server"
NTP_CONFIG_FILE="$MODDIR/config/ntp_servers.tsv"
NTP_LIB="$MODDIR/scripts/ntp_config_lib.sh"
DEFAULTS_LIB="$MODDIR/scripts/runtime_defaults_lib.sh"

[ -r "$NTP_LIB" ] && [ -r "$NTP_CONFIG_FILE" ] && [ -r "$DEFAULTS_LIB" ] \
    || json_error '500 Internal Server Error' 'NTP configuration not found'
. "$NTP_LIB" \
    || json_error '500 Internal Server Error' 'NTP configuration failed to load'
. "$DEFAULTS_LIB" \
    || json_error '500 Internal Server Error' 'runtime defaults contract failed to load'
ntp_config_validate \
    || json_error '500 Internal Server Error' 'NTP configuration is invalid'

restore_system_ntp() {
    case "$1" in
        ''|null)
            runtime_android_settings delete global ntp_server >/dev/null 2>&1 || return 1
            _ntp_restored=$(runtime_android_settings get global ntp_server 2>/dev/null | tr -d ' \n\r')
            [ -z "$_ntp_restored" ] || [ "$_ntp_restored" = "null" ]
            ;;
        *)
            runtime_android_settings put global ntp_server "$1" >/dev/null 2>&1 || return 1
            [ "$(runtime_android_settings get global ntp_server 2>/dev/null | tr -d ' \n\r')" = "$1" ]
            ;;
    esac
}

emit_ntp_state() {
    server=$(runtime_android_settings get global ntp_server 2>/dev/null | tr -d ' \n\r')
    server=$(ntp_server_normalize "$server" 2>/dev/null) \
        || json_error '500 Internal Server Error' 'NTP default is missing'
    default_server=$(ntp_server_default 2>/dev/null) \
        || json_error '500 Internal Server Error' 'NTP default is missing'
    auto_time=$(runtime_android_settings get global auto_time 2>/dev/null | tr -d ' \n\r')
    dev_time=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    servers=$(ntp_servers_json)
    json_headers
    printf '{"ntp_server":"%s","default_server":"%s","auto_time":"%s","device_time":"%s","servers":%s}' \
        "$(json_escape "$server")" "$(json_escape "$default_server")" \
        "$(json_escape "${auto_time:-1}")" "$(json_escape "$dev_time")" "${servers:-[]}"
}

if [ "$REQUEST_METHOD" = "GET" ]; then
    emit_ntp_state
elif [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "ntp"

    read_json_body 512
    body="$JSON_BODY"

    action=$(printf '%s' "$body" | sed -n 's/.*"action" *: *"\([^"]*\)".*/\1/p')
    server=$(printf '%s' "$body" | sed -n 's/.*"server" *: *"\([^"]*\)".*/\1/p')

    if [ "$action" = "sync" ]; then
        runtime_android_cmd network_time_update_service force_refresh >/dev/null 2>&1 \
            || json_error '500 Internal Server Error' 'NTP refresh failed'
        dev_time=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
        json_headers
        printf '{"ok":true,"action":"sync","refreshed":true,"device_time":"%s"}' "$(json_escape "$dev_time")"
    elif [ -n "$server" ]; then
        ntp_server_is_allowed "$server" \
            || json_error '400 Bad Request' 'unsupported server'
        _save_existed=0
        [ -e "$NTP_SAVE" ] && _save_existed=1
        _save_old=$(cat "$NTP_SAVE" 2>/dev/null)
        _system_old=$(runtime_android_settings get global ntp_server 2>/dev/null | tr -d ' \n\r')
        if ! runtime_android_settings put global ntp_server "$server" 2>/dev/null \
            || [ "$(runtime_android_settings get global ntp_server 2>/dev/null | tr -d ' \n\r')" != "$server" ]; then
            if restore_system_ntp "$_system_old"; then
                json_error '500 Internal Server Error' 'failed to update NTP server; previous system value restored'
            fi
            json_error '500 Internal Server Error' 'failed to update NTP server and system rollback failed'
        fi
        if ! cgi_atomic_write "$NTP_SAVE" "$server"; then
            _ntp_rollback_ok=1
            restore_system_ntp "$_system_old" || _ntp_rollback_ok=0
            cgi_restore_file "$NTP_SAVE" "$_save_existed" "$_save_old" >/dev/null 2>&1 || _ntp_rollback_ok=0
            if [ "$_ntp_rollback_ok" -eq 1 ]; then
                json_error '500 Internal Server Error' 'failed to persist NTP server; previous state restored'
            fi
            json_error '500 Internal Server Error' 'failed to persist NTP server and rollback was incomplete'
        fi
        refreshed=false
        runtime_android_cmd network_time_update_service force_refresh >/dev/null 2>&1 && refreshed=true
        sleep 1
        dev_time=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
        json_headers
        printf '{"ok":true,"ntp_server":"%s","refreshed":%s,"device_time":"%s"}' \
            "$(json_escape "$server")" "$refreshed" "$(json_escape "$dev_time")"
    else
        json_error '400 Bad Request' 'missing server or action'
    fi
else
    json_error '405 Method Not Allowed' 'GET or POST'
fi
