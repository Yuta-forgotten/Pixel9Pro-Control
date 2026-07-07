#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/uecap.sh
# GET  -> 返回当前 UECap 策略 / 档位 / hash
# POST -> 切换 auto/manual 策略，或在 manual 下切换档位
#
# Magisk 自适应: 安装时若检测到 Magisk, customize.sh 会删除
# uecap_profile.sh 与基带 binarypb, 并写入 .uecap_policy=disabled.
# 此时本 CGI 直接返回 stub 状态, 不再 source uecap_profile.sh.
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

# Magisk 短路: 无 uecap_profile.sh 或显式 disabled → 返回 stub
_uecap_policy=$(cat "$MODDIR/.uecap_policy" 2>/dev/null | tr -d ' \n\r')
if [ ! -f "$MODDIR/uecap_profile.sh" ] || [ "$_uecap_policy" = "disabled" ]; then
    require_loopback
    json_headers
    printf '%s\n' '{"ok":true,"reloading":false,"policy":"disabled","mode":"disabled","manual_mode":"disabled","active_mode":"stock","reason":"magisk_no_baseband","disabled":true,"disabled_message":"Magisk 版不含基带 UECap 覆盖。Magic Mount 与 modem cbd 早期 mmap 加载存在 race, 强制覆盖会卡 G logo。如需 UE 三档切换请使用 APatch / KSU + metamodule。","modes":[],"hash":"","stock_hash":""}'
    exit 0
fi

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
        _len="${CONTENT_LENGTH:-0}"
        case "$_len" in ''|*[!0-9]*) _len=0 ;; esac
        [ "$_len" -gt 0 ] 2>/dev/null || json_error '400 Bad Request' 'empty request body'
        [ "$_len" -gt 256 ] 2>/dev/null && _len=256
        body=$(dd bs=1 count="$_len" 2>/dev/null)
        mode=$(printf '%s' "$body" | sed -n 's/.*"mode" *: *"\([a-z]*\)".*/\1/p')
        case "$mode" in special|balanced|universal) ;; *) mode="" ;; esac
        policy=$(printf '%s' "$body" | sed -n 's/.*"policy" *: *"\([a-z]*\)".*/\1/p')
        case "$policy" in auto|manual) ;; *) policy="" ;; esac

        [ -n "$mode" ] || [ -n "$policy" ] || json_error '400 Bad Request' 'missing mode or policy'

        if [ -n "$policy" ]; then
            uecap_set_policy "$policy"
        fi

        if [ -n "$mode" ]; then
            uecap_set_manual_mode "$mode"
        fi

        if [ "$(uecap_current_policy)" = "manual" ]; then
            [ -n "$mode" ] || { json_headers; emit_status false; exit 0; }
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
