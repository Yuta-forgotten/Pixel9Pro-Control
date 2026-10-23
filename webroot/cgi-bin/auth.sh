#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/auth.sh
# GET confirms a capability. POST automatically bootstraps an approved browser
# app using its live kernel socket UID and exact same-origin request boundary.
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback_address
if [ "$REQUEST_METHOD" = POST ]; then
    require_json_post
    [ "${HTTP_HOST:-}" = "127.0.0.1:$WEBUI_PORT" ] \
        && [ "${HTTP_ORIGIN:-}" = "http://127.0.0.1:$WEBUI_PORT" ] \
        && [ "${HTTP_X_PIXEL9PRO_BOOTSTRAP:-}" = 1 ] \
        || json_error '403 Forbidden' 'browser session requires a same-origin request'
    case "${HTTP_SEC_FETCH_SITE:-same-origin}" in same-origin) ;;
        *) json_error '403 Forbidden' 'cross-origin session request' ;; esac
    read_json_body 128
    cgi_json_schema 'action:string'
    [ "$(cgi_json_field action)" = bootstrap ] || json_error '400 Bad Request' 'invalid session action'
    . "$MODDIR/scripts/browser_session_lib.sh" \
        || json_error '503 Service Unavailable' 'browser session service unavailable'
    browser_session_authorize \
        || json_error '403 Forbidden' "自动连接未能确认浏览器身份（$BROWSER_SESSION_ERROR），请重试或从管理器打开"
    token=$(read_webui_token)
    case "$token" in ''|*[!A-Za-z0-9._:-]*) json_error '503 Service Unavailable' 'server token unavailable' ;; esac
    json_headers
    printf '{"ok":true,"paired":true,"token":"%s"}\n' "$token"
    audit_log_event_async auth browser_session success BROWSER_AUTO_SESSION 0
    exit 0
fi
[ "$REQUEST_METHOD" = GET ] || json_error '405 Method Not Allowed' 'GET or POST only'
require_token

token="$(read_webui_token)"
[ -n "$token" ] || json_error '503 Service Unavailable' 'missing server token'

json_headers
printf '{"ok":true,"paired":true,"token_len":%s}\n' "${#token}"
