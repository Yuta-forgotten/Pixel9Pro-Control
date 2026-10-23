#!/system/bin/sh
# Read-only, token-protected tail of the module's structured audit log.
# The client cannot select a path; only the audit library's fixed file is read.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback
require_token
[ -r "$MODDIR/scripts/audit_log_lib.sh" ] \
    || json_error '500 Internal Server Error' 'audit log library not found'
. "$MODDIR/scripts/audit_log_lib.sh" 2>/dev/null \
    || json_error '500 Internal Server Error' 'audit log library unavailable'
audit_log_init "$MODDIR" || json_error '500 Internal Server Error' 'audit log contract unavailable'

if [ "$REQUEST_METHOD" = POST ]; then
    require_json_post
    acquire_lock audit_log
    read_json_body 256
    cgi_json_schema 'action:string'
    _al_action=$(cgi_json_field action)
    case "$_al_action" in
        clear)
            audit_log_clear || json_error '500 Internal Server Error' 'audit log clear failed'
            json_headers
            printf '{"ok":true,"action":"clear"}\n'
            ;;
        *) json_error '400 Bad Request' 'invalid audit log action' ;;
    esac
    release_lock
    exit 0
fi
[ "$REQUEST_METHOD" = GET ] || json_error '405 Method Not Allowed' 'GET or POST only'

_al_limit=40
_al_query=$(printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n 's/^limit=\([0-9]*\)$/\1/p' | head -n 1)
if [ -n "$_al_query" ]; then _al_limit="$_al_query"; fi
_al_all=$(printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n 's/^all=//p' | head -n 1)
case "$_al_all" in ''|0|false) _al_all=0 ;; 1|true) _al_all=1 ;; *) json_error '400 Bad Request' 'invalid audit log scope' ;; esac
_al_max=100
if [ "$_al_all" = 1 ]; then _al_limit=2000; _al_max=2000; fi
case "$_al_limit" in ''|*[!0-9]*|???????????*) _al_limit=40 ;; esac
[ "$_al_limit" -ge 1 ] 2>/dev/null || _al_limit=1
[ "$_al_limit" -le "$_al_max" ] 2>/dev/null || _al_limit="$_al_max"
_al_snapshot=$(audit_log_read "$_al_limit" "$_al_all") \
    || json_error '503 Service Unavailable' 'audit log busy or unreadable'

json_headers
printf '{"ok":true,"schema":%s,"source":"structured_audit","lines":[' "$AUDIT_LOG_SCHEMA"
_al_first=1
if [ -n "$_al_snapshot" ]; then
    printf '%s\n' "$_al_snapshot" | while IFS= read -r _al_line || [ -n "$_al_line" ]; do
        _al_line=$(printf '%s' "$_al_line" | cut -c1-1600)
        [ "$_al_first" -eq 1 ] || printf ','
        _al_first=0
        printf '"%s"' "$(json_escape "$_al_line")"
    done
fi
printf '],"limit":%s,"rotated":%s}\n' "$_al_limit" \
    "$( [ -f "$AUDIT_LOG_FILE.1" ] && printf true || printf false )"
