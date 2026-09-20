#!/system/bin/sh
# GET returns device-scoped UECap state. POST switches caiman profiles or the
# explicit komodo stock/candidate choice; unsupported roots remain read-only. This
# endpoint reports UECap ownership only; standalone baseband availability is
# queried independently through check_baseband.sh.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback
[ -f "$MODDIR/uecap_profile.sh" ] \
    || json_error '500 Internal Server Error' 'UECap runtime script is missing'

. "$MODDIR/uecap_profile.sh"

emit_status() {
    _json=$(uecap_print_status_json)
    _json=${_json#\{}
    _reload="${1:-false}"
    printf '{"ok":true,"reloading":%s,%s\n' "$_reload" "$_json"
}

emit_apply_failure() {
    _json=$(uecap_print_status_json)
    _json=${_json#\{}
    _applied="${2:-false}"
    printf '{"ok":false,"applied":%s,"reloading":false,"error":"%s",%s\n' \
        "$_applied" "$(json_escape "$1")" "$_json"
}

case "$REQUEST_METHOD" in
    GET)
        json_headers
        emit_status false
        ;;
    POST)
        require_json_post
        require_token
        acquire_lock "uecap_profile"
        read_json_body 256
        body="$JSON_BODY"
        uecap_is_available \
            || json_error '409 Conflict' "UECap 当前为只读状态: $(uecap_current_reason)"
        mode=$(printf '%s' "$body" | sed -n 's/.*"mode" *: *"\([a-z]*\)".*/\1/p')
        uecap_is_valid_mode "$mode" \
            || json_error '400 Bad Request' 'invalid mode'
        policy=$(printf '%s' "$body" | sed -n 's/.*"policy" *: *"\([a-z_]*\)".*/\1/p')
        _uecap_expected_policy=$(uecap_current_policy)
        case "$policy" in
            '') ;;
            managed_profiles|single_candidate)
                [ "$policy" = "$_uecap_expected_policy" ] \
                    || json_error '409 Conflict' 'UECap policy does not match current SKU'
                ;;
            *) json_error '400 Bad Request' 'invalid UECap policy' ;;
        esac

        _uecap_rc=0
        uecap_apply_mode "$mode" "manual_locked" || _uecap_rc=$?
        case "$_uecap_rc" in
            0)
                [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] \
                    && audit_log_event uecap apply success "UECAP_${mode}" 0 >/dev/null 2>&1 \
                    || true
                json_headers
                emit_status "$UECAP_RELOAD_DISPATCHED"
                ;;
            3)
                [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] \
                    && audit_log_event uecap apply failure MODEM_RELOAD_FAILED 0 >/dev/null 2>&1 \
                    || true
                json_status_headers '500 Internal Server Error'
                emit_apply_failure '配置已切换，但 modem 重载失败；重启手机后生效' true
                ;;
            2)
                json_error '500 Internal Server Error' "uecap apply failed; rollback incomplete ($UECAP_APPLY_RESULT)"
                ;;
            4)
                json_status_headers '409 Conflict'
                emit_apply_failure '活动 MetaModule 使用 content image；UECap 档位变更需卸载 Control、重启后重新安装' false
                ;;
            *)
                json_error '500 Internal Server Error' "uecap apply failed ($UECAP_APPLY_RESULT)"
                ;;
        esac
        ;;
    *)
        json_error '405 Method Not Allowed' 'GET or POST only'
        ;;
esac
