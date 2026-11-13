#!/system/bin/sh
# Read-only, token-protected tail of the module's structured audit log.
# The client cannot select a path; only the audit library's fixed file is read.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback
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

_al_query=${QUERY_STRING:-}
[ "${#_al_query}" -le 256 ] || json_error '400 Bad Request' '日志读取参数过长'
case "$_al_query" in *[[:space:]]*) json_error '400 Bad Request' '日志读取参数无效' ;; esac
_al_fields=$(printf '%s' "$_al_query" | LC_ALL=C awk '
    BEGIN { limit=40; offset=0; all=0; snapshot="-" }
    {
        count=split($0,fields,"&")
        for (i=1;i<=count;i++) {
            if (split(fields[i],pair,"=")!=2 || seen[pair[1]]++) exit 1
            key=pair[1]; value=pair[2]
            if (key=="limit") {
                if (value !~ /^[0-9]+$/ || length(value)>3 || value<1 || value>500) exit 1
                limit=value+0
            } else if (key=="offset") {
                if (value !~ /^[0-9]+$/ || length(value)>10 || value>2147483647) exit 1
                offset=value+0
            } else if (key=="all") {
                if (value=="1" || value=="true") all=1
                else if (value=="0" || value=="false") all=0
                else exit 1
            } else if (key=="snapshot_id") {
                if (length(value)!=64 || value !~ /^[0-9a-f]+$/) exit 1
                snapshot=value
            } else exit 1
        }
    }
    END { if (count && i<=count) exit 1; printf "%d %d %d %s\n",limit,offset,all,snapshot }
') || json_error '400 Bad Request' '日志读取参数无效'
set -- $_al_fields
_al_limit="$1"
_al_offset="$2"
_al_all="$3"
_al_expected="$4"
[ "$_al_expected" != - ] || _al_expected=
_al_page=$(audit_log_page "$_al_limit" "$_al_offset" "$_al_all" "$_al_expected")
_al_page_rc=$?
case "$_al_page_rc" in
    0) ;;
    65) CGI_ERROR_CODE=AUDIT_LOG_INTEGRITY; json_error '422 Unprocessable Content' '日志记录或本页内容超出完整读取范围，未截断返回' ;;
    66) CGI_ERROR_CODE=AUDIT_OFFSET_INVALID; json_error '400 Bad Request' '日志读取位置超出范围' ;;
    73) CGI_ERROR_CODE=AUDIT_SNAPSHOT_CHANGED; json_error '409 Conflict' '日志已变化，请重新开始读取或导出' ;;
    *) CGI_ERROR_CODE=AUDIT_LOG_UNAVAILABLE; json_error '503 Service Unavailable' '日志正忙或无法读取' ;;
esac
json_headers
printf '%s\n' "$_al_page"
