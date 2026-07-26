#!/system/bin/sh
# GET returns the screen-off NR policy and current RAT mode. POST updates the
# policy; disabling it first restores and verifies the saved NR-capable mode.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback

STATE_FILE="$MODDIR/.nr_screen_switch"
NR_MODE_FILE="$MODDIR/.nr_saved_mode"
DEFAULTS_LIB="$MODDIR/scripts/runtime_defaults_lib.sh"
NR_LIB="$MODDIR/scripts/nr_mode_lib.sh"

[ -r "$DEFAULTS_LIB" ] && [ -r "$NR_LIB" ] \
    || json_error '500 Internal Server Error' 'NR mode contract not found'
. "$DEFAULTS_LIB" && . "$NR_LIB" \
    || json_error '500 Internal Server Error' 'NR mode contract failed to load'

read_actual_rat() {
    dumpsys telephony.registry 2>/dev/null \
        | sed -n 's/.*mTelephonyDisplayInfo=TelephonyDisplayInfo {network=\([^,} ]*\).*/\1/p' \
        | head -n 1
}

if [ "$REQUEST_METHOD" = "GET" ]; then
    json_headers
    enabled=$(cat "$STATE_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$enabled" in on|off) ;; *) enabled="$NR_SCREEN_SWITCH_DEFAULT" ;; esac
    saved_nr=$(nr_mode_read_saved "$NR_MODE_FILE" "$NR_SAVED_MODE_DEFAULT" 2>/dev/null) \
        || saved_nr="$NR_SAVED_MODE_DEFAULT"

    nr_mode_detect_setting
    current="$NR_MODE_CURRENT"
    slot0=$(nr_mode_slot0 "$current")
    actual_rat=$(read_actual_rat)
    [ -n "$actual_rat" ] || actual_rat="unknown"

    printf '{"nr_switch":"%s","current_mode":"%s","current_slot0":"%s","actual_rat":"%s","saved_nr_mode":"%s","screen_off_delay_s":%s,"restore_cooldown_s":%s,"lte_recheck_s":%s,"lte_mode":%s}' \
        "$enabled" "$(json_escape "${current:-unknown}")" "$(json_escape "${slot0:-unknown}")" "$(json_escape "$actual_rat")" "$saved_nr" \
        "$NR_SCREEN_OFF_DELAY_S" "$NR_RESTORE_COOLDOWN_S" "$NR_LTE_RECHECK_S" "$NR_LTE_MODE"

elif [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "nr_switch"
    read_json_body 256
    body="$JSON_BODY"
    action=$(printf '%s' "$body" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')
    requested=$(printf '%s' "$body" | sed -n 's/.*"enabled"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
    current=$(cat "$STATE_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$current" in on|off) ;; *) current="$NR_SCREEN_SWITCH_DEFAULT" ;; esac
    case "$action" in
        toggle) [ "$current" = "on" ] && new="off" || new="on" ;;
        set) case "$requested" in on|off) new="$requested" ;; *) json_error '400 Bad Request' 'invalid enabled' ;; esac ;;
        *) json_error '400 Bad Request' 'invalid action' ;;
    esac
    if [ "$new" = "off" ]; then
        saved_nr=$(nr_mode_read_saved "$NR_MODE_FILE" "$NR_SAVED_MODE_DEFAULT" 2>/dev/null) \
            || json_error '500 Internal Server Error' 'saved NR mode is unavailable'
        nr_mode_detect_setting
        _nr_key="$NR_MODE_KEY"
        _nr_before="$NR_MODE_CURRENT"
        if ! nr_mode_write_verified "$_nr_key" "$saved_nr"; then
            if nr_mode_is_valid_raw "$_nr_before" \
                && nr_mode_write_verified "$_nr_key" "$_nr_before"; then
                json_error '500 Internal Server Error' 'failed to restore NR mode; previous mode restored'
            fi
            json_error '500 Internal Server Error' 'failed to restore NR mode and rollback was incomplete'
        fi
    fi
    if ! cgi_atomic_write "$STATE_FILE" "$new"; then
        if [ "$new" = "off" ]; then
            if nr_mode_is_valid_raw "$_nr_before" \
                && nr_mode_write_verified "$_nr_key" "$_nr_before"; then
                json_error '500 Internal Server Error' 'failed to persist NR setting; previous mode restored'
            fi
            json_error '500 Internal Server Error' 'failed to persist NR setting and rollback was incomplete'
        fi
        json_error '500 Internal Server Error' 'failed to persist NR setting'
    fi
    json_headers
    printf '{"ok":true,"nr_switch":"%s"}' "$new"
else
    json_error '405 Method Not Allowed' 'GET or POST'
fi
