#!/system/bin/sh
# GET returns the manual UECap tier and active hash. POST switches one of the
# three manual tiers. Unsupported root/device installs explicitly return a stub.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback

_uecap_policy=$(cat "$MODDIR/.uecap_policy" 2>/dev/null | tr -d ' \n\r')
if [ "$_uecap_policy" = "disabled" ]; then
    _uecap_disabled_reason=$(cat "$MODDIR/.uecap_reason" 2>/dev/null | tr -d ' \n\r')
    case "$_uecap_disabled_reason" in
        uecap_unsupported_device)
            _uecap_disabled_message="Pixel 9 Pro XL 不使用 Pixel 9 Pro 专用 UECap payload；当前保持 stock。"
            ;;
        *)
            _uecap_disabled_reason="magisk_no_baseband"
            _uecap_disabled_message="Magisk 版不含基带 UECap 覆盖。Magic Mount 与 modem cbd 早期 mmap 加载存在 race，强制覆盖会卡 G logo。如需 UE 三档切换请使用 APatch / KSU + metamodule。"
            ;;
    esac
    json_headers
    printf '{"ok":true,"reloading":false,"policy":"disabled","mode":"disabled","manual_mode":"disabled","active_mode":"stock","reason":"%s","disabled":true,"disabled_message":"%s","modes":[],"hash":"","stock_hash":""}\n' \
        "$_uecap_disabled_reason" "$(json_escape "$_uecap_disabled_message")"
    exit 0
fi
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
    printf '{"ok":false,"applied":true,"reloading":false,"error":"%s",%s\n' \
        "$(json_escape "$1")" "$_json"
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
        mode=$(printf '%s' "$body" | sed -n 's/.*"mode" *: *"\([a-z]*\)".*/\1/p')
        case "$mode" in special|balanced|universal) ;; *) json_error '400 Bad Request' 'invalid mode' ;; esac
        policy=$(printf '%s' "$body" | sed -n 's/.*"policy" *: *"\([a-z]*\)".*/\1/p')
        case "$policy" in ''|manual) ;; *) json_error '400 Bad Request' 'UECap policy is fixed to manual' ;; esac

        _uecap_rc=0
        uecap_apply_mode "$mode" "manual_locked" || _uecap_rc=$?
        case "$_uecap_rc" in
            0)
                json_headers
                emit_status "$UECAP_RELOAD_DISPATCHED"
                ;;
            3)
                json_headers
                emit_apply_failure '配置已切换，但 modem 重载失败；重启手机后生效'
                ;;
            2)
                json_error '500 Internal Server Error' "uecap apply failed; rollback incomplete ($UECAP_APPLY_RESULT)"
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
