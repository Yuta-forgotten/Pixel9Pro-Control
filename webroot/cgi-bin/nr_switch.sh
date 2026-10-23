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
    timeout -k 1 4 dumpsys -t 3 telephony.registry 2>/dev/null \
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
    recovery_pending=false
    [ ! -e "$MODDIR/.nr_temporary_lease" ] || recovery_pending=true
    printf '{"nr_recovery_pending":%s,' "$recovery_pending"

    printf '"nr_switch":"%s","current_mode":"%s","current_slot0":"%s","actual_rat":"%s","saved_nr_mode":"%s","screen_off_delay_s":%s,"restore_cooldown_s":%s,"lte_recheck_s":%s,"lte_mode":%s}' \
        "$enabled" "$(json_escape "${current:-unknown}")" "$(json_escape "${slot0:-unknown}")" "$(json_escape "$actual_rat")" "$saved_nr" \
        "$NR_SCREEN_OFF_DELAY_S" "$NR_RESTORE_COOLDOWN_S" "$NR_LTE_RECHECK_S" "$NR_LTE_MODE"

elif [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "nr_switch"
    nr_mode_lock_acquire "$MODDIR" || json_error '409 Conflict' 'NR policy transaction is busy'
    trap 'nr_mode_lock_release; release_lock' EXIT
    trap 'nr_mode_lock_release; release_lock; exit 130' INT
    trap 'nr_mode_lock_release; release_lock; exit 143' TERM
    trap 'nr_mode_lock_release; release_lock; exit 129' HUP
    read_json_body 256
    body="$JSON_BODY"
    cgi_json_schema 'action:string enabled:string'
    action=$(cgi_json_field action)
    requested=$(cgi_json_field enabled)
    current=$(cat "$STATE_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$current" in on|off) ;; *) current="$NR_SCREEN_SWITCH_DEFAULT" ;; esac
    case "$action" in
        toggle) [ "$current" = "on" ] && new="off" || new="on" ;;
        set) case "$requested" in on|off) new="$requested" ;; *) json_error '400 Bad Request' 'invalid enabled' ;; esac ;;
        *) json_error '400 Bad Request' 'invalid action' ;;
    esac
    cgi_atomic_write "$STATE_FILE" "$new" \
        || json_error '500 Internal Server Error' 'failed to persist NR policy'
    if [ "$new" = off ] && ! nr_mode_recover_temporary "$MODDIR"; then
        nr_mode_lock_release || true
        json_status_headers '500 Internal Server Error'
        printf '{"ok":false,"committed":true,"nr_switch":"off","error":"NR policy disabled; owned temporary mode restoration unconfirmed; recovery journal retained"}\n'
        exit 1
    fi
    nr_mode_lock_release || json_error '500 Internal Server Error' 'NR policy saved but lock release failed'
    json_headers
    printf '{"ok":true,"nr_switch":"%s"}' "$new"
else
    json_error '405 Method Not Allowed' 'GET or POST'
fi
