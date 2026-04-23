#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/uecap.sh
# GET  -> 返回当前 UECap 策略 / 档位 / hash
# POST -> 切换 auto/manual 策略，或在 manual 下切换档位
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
. "$MODDIR/uecap_profile.sh"

emit_status() {
    _json=$(uecap_print_status_json)
    _json=${_json#\{}
    _reload="${1:-false}"
    printf '{"ok":true,"reloading":%s,%s\n' "$_reload" "$_json"
}

toggle_mode() {
    case "$(uecap_current_mode)" in
        special) echo "balanced" ;;
        balanced) echo "special" ;;
        *) echo "special" ;;
    esac
}

require_loopback

case "$REQUEST_METHOD" in
    GET)
        json_headers
        emit_status false
        ;;
    POST)
        require_json_post
        require_token
        acquire_lock "uecap_profile"
        _len="${CONTENT_LENGTH:-256}"
        [ "$_len" -le 0 ] 2>/dev/null && _len=256
        [ "$_len" -gt 256 ] 2>/dev/null && _len=256
        body=$(dd bs=1 count="$_len" 2>/dev/null)
        mode=$(printf '%s' "$body" | sed -n 's/.*"mode" *: *"\([a-z]*\)".*/\1/p')
        case "$mode" in special|balanced|universal) ;; *) mode="" ;; esac
        policy=$(printf '%s' "$body" | sed -n 's/.*"policy" *: *"\([a-z]*\)".*/\1/p')
        case "$policy" in auto|manual) ;; *) policy="" ;; esac

        if [ -n "$policy" ]; then
            uecap_set_policy "$policy"
        fi

        if [ -n "$mode" ]; then
            uecap_set_manual_mode "$mode"
        fi

        if [ "$(uecap_current_policy)" = "manual" ]; then
            [ -n "$mode" ] || mode=$(uecap_current_manual_mode)
            if uecap_apply_mode "$mode" "manual_locked"; then
                uecap_set_reason manual_locked
                json_headers
                emit_status true
            else
                json_error '500 Internal Server Error' "uecap apply failed"
            fi
        elif [ "$(uecap_current_policy)" = "auto" ]; then
            json_headers
            emit_status false
        else
            [ -n "$mode" ] || mode=$(toggle_mode)
            if uecap_apply_mode "$mode" "manual"; then
                json_headers
                emit_status true
            else
                json_error '500 Internal Server Error' "uecap apply failed"
            fi
        fi
        ;;
    *)
        json_error '405 Method Not Allowed' 'GET or POST only'
        ;;
esac
