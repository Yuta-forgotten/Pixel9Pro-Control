#!/system/bin/sh
# Read-only, token-protected tail of the module's structured audit log.
# The client cannot select a path; only the audit library's fixed file is read.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback
[ "$REQUEST_METHOD" = GET ] || json_error '405 Method Not Allowed' 'GET only'
require_token
[ -r "$MODDIR/scripts/audit_log_lib.sh" ] \
    || json_error '500 Internal Server Error' 'audit log library not found'
. "$MODDIR/scripts/audit_log_lib.sh" 2>/dev/null \
    || json_error '500 Internal Server Error' 'audit log library unavailable'
audit_log_init "$MODDIR" || json_error '500 Internal Server Error' 'audit log contract unavailable'

_al_limit=40
_al_query=$(printf '%s' "${QUERY_STRING:-}" | sed -n 's/.*\(^\|&\)limit=\([0-9]*\).*/\2/p' | head -n 1)
if [ -n "$_al_query" ]; then _al_limit="$_al_query"; fi
case "$_al_limit" in ''|*[!0-9]*) _al_limit=40 ;; esac
[ "$_al_limit" -ge 1 ] 2>/dev/null || _al_limit=1
[ "$_al_limit" -le 100 ] 2>/dev/null || _al_limit=100

json_headers
printf '{"ok":true,"schema":%s,"source":"structured_audit","lines":[' "$AUDIT_LOG_SCHEMA"
_al_first=1
if [ -r "$AUDIT_LOG_FILE" ]; then
    tail -n "$_al_limit" "$AUDIT_LOG_FILE" 2>/dev/null | while IFS= read -r _al_line || [ -n "$_al_line" ]; do
        _al_line=$(printf '%s' "$_al_line" | cut -c1-1600)
        [ "$_al_first" -eq 1 ] || printf ','
        _al_first=0
        printf '"%s"' "$(json_escape "$_al_line")"
    done
fi
printf '],"limit":%s,"rotated":%s}\n' "$_al_limit" \
    "$( [ -f "$AUDIT_LOG_FILE.1" ] && printf true || printf false )"
