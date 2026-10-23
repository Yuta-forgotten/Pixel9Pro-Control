#!/system/bin/sh
# Shared CGI boundary: loopback/token checks, bounded JSON bodies, atomic state
# writes, and process-owned mutation locks. CGI scripts source this file first.

MODDIR="${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}"
WEBUI_PORT="${PIXEL9PRO_WEBUI_PORT:-6210}"
TOKEN_FILE="${PIXEL9PRO_WEBUI_TOKEN_FILE:-$MODDIR/.webui_token}"
THERMAL_CACHE="${PIXEL9PRO_THERMAL_CACHE:-$MODDIR/.thermal_cache.json}"
LOCKDIR_BASE="${PIXEL9PRO_LOCKDIR_BASE:-$MODDIR/.locks}"
LOCK_PATH=""
LOCK_START_TICKS=""
LOCK_BOOT_ID=""
JSON_BODY=""
CGI_BODY_READ_TIMEOUT_S=5
AUDIT_LOG_AVAILABLE=0
if [ -r "$MODDIR/scripts/audit_log_lib.sh" ] \
    && . "$MODDIR/scripts/audit_log_lib.sh" 2>/dev/null \
    && audit_log_init "$MODDIR"; then
    AUDIT_LOG_AVAILABLE=1
fi

# Audit records are supplementary telemetry. Queue them after the CGI response
# has been written so a policy mutation never holds the WebUI request open on
# log rotation, chmod or retention cleanup. The child inherits the same
# Android shell/SELinux domain and writes only to the existing private log.
audit_log_event_async() {
    [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] || return 0
    ( audit_log_event "$@" ) >/dev/null 2>&1 </dev/null &
}

json_headers() {
    cgi_refresh_description
    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
}

json_status_headers() {
    cgi_refresh_description
    printf 'Status: %s\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n' "$1"
}

cgi_refresh_description() {
    [ "${CGI_AUTHENTICATED:-0}" = 1 ] && [ "${REQUEST_METHOD:-}" = POST ] \
        && [ "${CGI_DESCRIPTION_REFRESHED:-0}" != 1 ] || return 0
    CGI_DESCRIPTION_REFRESHED=1
    case "${0##*/}" in profile.sh|set_thermal.sh|swap.sh|nr_switch.sh|standby_guard.sh|bg_restrict.sh|uecap.sh|ntp.sh) ;;
        *) return 0 ;; esac
    ( . "$MODDIR/scripts/module_metadata_lib.sh" && module_description_refresh "$MODDIR" ) \
        >/dev/null 2>&1 </dev/null &
}

json_escape() {
    case "$1" in
        *[[:cntrl:]\\\"]*) ;;
        *) printf '%s' "$1"; return 0 ;;
    esac
    # A sentinel preserves trailing newlines; JSON forbids raw controls.
    printf '%s_' "$1" | LC_ALL=C awk '
        function emit(value, i, c) {
            if (printed++) printf "\\n"
            for (i=1; i<=length(value); i++) {
                c=substr(value,i,1)
                if (c=="\\") printf "\\\\"
                else if (c=="\"") printf "\\\""
                else if (c in escaped) printf "%s",escaped[c]
                else printf "%s",c
            }
        }
        BEGIN { for (i=1;i<32;i++) escaped[sprintf("%c",i)]=sprintf("\\u%04x",i) }
        { if (NR>1) emit(previous); previous=$0 }
        END { emit(substr(previous,1,length(previous)-1)) }
    '
}

json_error() {
    code="$1"
    shift
    msg="$*"
    if [ "${BG_TX_ACTIVE:-0}" = 1 ] && command -v bg_tx_rollback >/dev/null 2>&1; then
        if bg_tx_rollback; then msg="$msg; request-entry state restored"
        else msg="$msg; rollback incomplete, recovery journal retained"; code='500 Internal Server Error'; fi
    fi
    if [ "${CGI_VM_POLICY_TX_ACTIVE:-0}" = 1 ] && command -v restore_vm_policy_state >/dev/null 2>&1; then
        CGI_VM_POLICY_TX_ACTIVE=0
        if restore_vm_policy_state; then msg="$msg; VM policy state restored"
        else msg="$msg; VM policy rollback incomplete"; code='500 Internal Server Error'; fi
    fi
    _json_error_status=${code%% *}
    case "$_json_error_status" in ''|*[!0-9]*) _json_error_status=500 ;; esac
    case "$_json_error_status" in
        401|403|405) : ;; # Untrusted/local probing must not fork log writers.
        *) [ "$AUDIT_LOG_AVAILABLE" -ne 1 ] \
            || audit_log_event_async cgi "${0##*/}" failure "HTTP_$_json_error_status" 0 ;;
    esac
    json_status_headers "$code"
    printf '{"ok":false,"error":"%s","error_code":"HTTP_%s"}\n' "$(json_escape "$msg")" "$_json_error_status"
    exit 0
}

# 只允许回环地址访问
require_loopback_address() {
    case "${REMOTE_ADDR:-}" in
        127.0.0.1|::1|::ffff:127.0.0.1) ;;
        *) json_error '403 Forbidden' 'loopback only' ;;
    esac
}

require_loopback() {
    require_loopback_address
    # Android apps share loopback. It is a transport boundary, not permission
    # to read root-derived package, history, configuration or log data.
    require_token
}

# 要求 POST + application/json (触发 CORS preflight, 阻止浏览器 CSRF)
require_json_post() {
    [ "$REQUEST_METHOD" = "POST" ] || json_error '405 Method Not Allowed' 'POST only'
    case "${CONTENT_TYPE:-}" in
        application/json|application/json\;*) ;;
        *) json_error '415 Unsupported Media Type' 'application/json only' ;;
    esac
}

read_json_body() {
    _json_max="${1:-1024}"
    case "$_json_max" in ''|*[!0-9]*|0) _json_max=1024 ;; esac

    _json_len="${CONTENT_LENGTH:-0}"
    case "$_json_len" in
        ''|*[!0-9]*) json_error '400 Bad Request' 'invalid Content-Length' ;;
    esac
    [ "$_json_len" -gt 0 ] 2>/dev/null \
        || json_error '400 Bad Request' 'empty request body'
    [ "$_json_len" -le "$_json_max" ] 2>/dev/null \
        || json_error '413 Payload Too Large' "request body exceeds ${_json_max} bytes"

    # Command substitution strips trailing newlines. Appending one sentinel byte
    # keeps valid JSON whitespace intact until after the exact-length check.
    command -v timeout >/dev/null 2>&1 \
        || json_error '503 Service Unavailable' 'bounded request reader unavailable'
    _json_raw=$(timeout -k 1 "$CGI_BODY_READ_TIMEOUT_S" dd bs=1 count="$_json_len" 2>/dev/null; printf 'x')
    JSON_BODY=${_json_raw%x}
    [ -n "$JSON_BODY" ] || json_error '400 Bad Request' 'empty request body'
    _json_actual=$(printf '%s' "$JSON_BODY" | wc -c | tr -d ' \r\n\t')
    [ "$_json_actual" -eq "$_json_len" ] 2>/dev/null \
        || json_error '400 Bad Request' 'incomplete request body'
    _json_shape=$(printf '%s' "$JSON_BODY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$_json_shape" in
        \{*\}) ;;
        *) json_error '400 Bad Request' 'JSON object required' ;;
    esac
    cgi_parse_json "$JSON_BODY" || json_error '400 Bad Request' 'invalid JSON request'
}

# All mutation endpoints accept flat scalar objects. Parse the entire object
# once, reject duplicate keys and unsupported escapes, and retain scalar types
# so an integer prefix or a nested key cannot become a policy write.
cgi_parse_json() {
    CGI_JSON_FIELDS=$(printf '%s' "$1" | LC_ALL=C awk '
    function ws() { sub(/^[ \t\r\n]+/, "", s) }
    function fail() { invalid=1; exit 1 }
    { s=s $0 "\n" }
    END {
        if (invalid) exit 1
        ws(); if (substr(s,1,1)!="{") fail()
        s=substr(s,2); ws()
        while (substr(s,1,1)!="}") {
            if (!match(s,/^"[A-Za-z_][A-Za-z0-9_]*"/)) fail()
            key=substr(s,2,RLENGTH-2); s=substr(s,RLENGTH+1); ws()
            if (seen[key]++ || substr(s,1,1)!=":") fail()
            s=substr(s,2); ws()
            if (match(s,/^"[^"\\[:cntrl:]]*"/)) {
                value=substr(s,2,RLENGTH-2); type="string"
            } else if (match(s,/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) {
                value=substr(s,1,RLENGTH); type="number"
            } else if (match(s,/^(true|false)/)) {
                value=substr(s,1,RLENGTH); type="boolean"
            } else if (match(s,/^null/)) {
                value="null"; type="null"
            } else fail()
            s=substr(s,RLENGTH+1); ws()
            fields=fields key "\t" value "\t" type "\n"
            if (substr(s,1,1)=="}") break
            if (substr(s,1,1)!=",") fail()
            s=substr(s,2); ws(); if (substr(s,1,1)=="}") fail()
        }
        s=substr(s,2); ws(); if (s!="") fail()
        printf "%s", fields
    }')
}

cgi_json_field() {
    printf '%s\n' "$CGI_JSON_FIELDS" | awk -F '\t' -v key="$1" '$1==key { print $2; exit }'
}

# Schema describes optional fields; endpoint business validation decides which
# combination is required. Unknown fields and wrong scalar types fail closed.
cgi_json_schema() {
    printf '%s\n' "$CGI_JSON_FIELDS" | awk -F '\t' -v schema="$1" '
        BEGIN {
            n=split(schema, entries, " ")
            for (i=1;i<=n;i++) { split(entries[i], pair, ":"); allowed[pair[1]]=pair[2] }
        }
        NF { if (!($1 in allowed) || $3 != allowed[$1]) exit 1 }
    ' || json_error '400 Bad Request' 'unknown JSON field or invalid field type'
}

cgi_atomic_write() {
    command -v state_atomic_write >/dev/null 2>&1 \
        || . "$MODDIR/scripts/state_io_lib.sh" || return 1
    state_atomic_write "$1" "$2"
}

cgi_read_entry() {
    command -v state_read_entry >/dev/null 2>&1 \
        || . "$MODDIR/scripts/state_io_lib.sh" || return 1
    state_read_entry "$1"
}

cgi_restore_file() {
    _cgi_restore_file="$1"
    _cgi_restore_existed="$2"
    _cgi_restore_value="$3"
    if [ "$_cgi_restore_existed" = "1" ]; then
        cgi_atomic_write "$_cgi_restore_file" "$_cgi_restore_value"
    else
        rm -f "$_cgi_restore_file" 2>/dev/null && [ ! -e "$_cgi_restore_file" ] && [ ! -L "$_cgi_restore_file" ]
    fi
}

# Token 认证
read_webui_token() {
    tr -d ' \r\n\t' < "$TOKEN_FILE" 2>/dev/null
}

require_token() {
    [ ! -L "$TOKEN_FILE" ] && [ -f "$TOKEN_FILE" ] && [ -r "$TOKEN_FILE" ] \
        || json_error '503 Service Unavailable' 'server token unavailable'
    expected="$(read_webui_token)"
    actual="${HTTP_X_PIXEL9PRO_TOKEN:-}"
    case "$expected" in ''|*[!A-Za-z0-9._:-]*) json_error '503 Service Unavailable' 'server token invalid' ;; esac
    [ -n "$expected" ] || json_error '503 Service Unavailable' 'missing server token'
    [ -n "$actual" ] || json_error '403 Forbidden' 'missing token'
    [ "$actual" = "$expected" ] || json_error '403 Forbidden' 'invalid token'
    CGI_AUTHENTICATED=1
}

process_start_ticks() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    if [ "${PIXEL9PRO_CGI_TEST_MODE:-0}" = "1" ]; then
        printf '%s' "${PIXEL9PRO_TEST_START_TICKS:-1}"
        return 0
    fi
    sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'
}

# mkdir is the atomic lock primitive. PID plus /proc start ticks prevent an old
# lock from becoming permanent after PID reuse.
cgi_initialize_lock() {
    _lock_start=$(process_start_ticks "$$")
    _lock_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    if [ -z "$_lock_start" ] || [ -z "$_lock_boot" ] \
        || ! printf '%s\n' "$$" > "$LOCK_PATH/pid" 2>/dev/null \
        || ! printf '%s\n' "$_lock_start" > "$LOCK_PATH/start_ticks" 2>/dev/null \
        || ! printf '%s\n' "$_lock_boot" > "$LOCK_PATH/boot_id" 2>/dev/null \
        || ! chmod 600 "$LOCK_PATH/pid" "$LOCK_PATH/start_ticks" "$LOCK_PATH/boot_id" 2>/dev/null; then
        rm -f "$LOCK_PATH/pid" "$LOCK_PATH/start_ticks" "$LOCK_PATH/boot_id" 2>/dev/null
        rmdir "$LOCK_PATH" 2>/dev/null
        json_error '500 Internal Server Error' 'cannot initialize lock'
    fi
    LOCK_START_TICKS="$_lock_start"
    LOCK_BOOT_ID="$_lock_boot"
    trap 'release_lock' EXIT
    trap 'release_lock; exit 129' HUP
    trap 'release_lock; exit 130' INT
    trap 'release_lock; exit 143' TERM
}

acquire_lock() {
    name="$1"
    case "$name" in ''|*[!A-Za-z0-9_.-]*) json_error '500 Internal Server Error' 'invalid lock name' ;; esac
    [ ! -L "$LOCKDIR_BASE" ] || json_error '500 Internal Server Error' 'invalid lock directory'
    (umask 077; mkdir -p "$LOCKDIR_BASE") 2>/dev/null \
        || json_error '500 Internal Server Error' 'cannot create lock directory'
    chmod 700 "$LOCKDIR_BASE" 2>/dev/null \
        || json_error '500 Internal Server Error' 'cannot secure lock directory'
    LOCK_PATH="$LOCKDIR_BASE/${name}.lock"
    [ ! -L "$LOCK_PATH" ] || json_error '500 Internal Server Error' 'invalid lock path'
    if (umask 077; mkdir "$LOCK_PATH") 2>/dev/null; then
        cgi_initialize_lock
        return 0
    fi
    _lock_pid=$(cat "$LOCK_PATH/pid" 2>/dev/null | tr -d ' \r\n\t')
    _lock_start=$(cat "$LOCK_PATH/start_ticks" 2>/dev/null | tr -d ' \r\n\t')
    _lock_boot=$(cat "$LOCK_PATH/boot_id" 2>/dev/null | tr -d ' \r\n\t')
    _lock_live_start=$(process_start_ticks "$_lock_pid")
    _stale=0
    if [ -z "$_lock_pid" ] || [ -z "$_lock_start" ] || [ -z "$_lock_boot" ]; then
        # mkdir precedes owner publication. A concurrent request must not
        # remove a lock while its first owner is still initializing it.
        _lock_mtime=$(stat -c %Y "$LOCK_PATH" 2>/dev/null)
        _lock_now=$(date +%s 2>/dev/null)
        case "$_lock_mtime:$_lock_now" in
            *[!0-9:]*|:*) ;;
            *) [ $((_lock_now - _lock_mtime)) -gt 30 ] 2>/dev/null && _stale=1 ;;
        esac
    elif [ "$_lock_boot" != "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ]; then
        _stale=1
    elif ! kill -0 "$_lock_pid" 2>/dev/null; then
        _stale=1
    elif [ -z "$_lock_live_start" ] || [ "$_lock_live_start" != "$_lock_start" ]; then
        _stale=1
    fi
    if [ "$_stale" -eq 1 ]; then
        rm -f "$LOCK_PATH/pid" "$LOCK_PATH/start_ticks" "$LOCK_PATH/boot_id" 2>/dev/null
        rmdir "$LOCK_PATH" 2>/dev/null
        if (umask 077; mkdir "$LOCK_PATH") 2>/dev/null; then
            cgi_initialize_lock
            return 0
        fi
    fi
    json_error '409 Conflict' "${name} busy"
}

release_lock() {
    if [ -n "$LOCK_PATH" ]; then
        _release_pid=$(cat "$LOCK_PATH/pid" 2>/dev/null | tr -d ' \r\n\t')
        _release_start=$(cat "$LOCK_PATH/start_ticks" 2>/dev/null | tr -d ' \r\n\t')
        _release_boot=$(cat "$LOCK_PATH/boot_id" 2>/dev/null | tr -d ' \r\n\t')
        if [ "$_release_pid" = "$$" ] \
            && [ -n "$LOCK_START_TICKS" ] \
            && [ "$_release_start" = "$LOCK_START_TICKS" ] \
            && [ -n "$LOCK_BOOT_ID" ] && [ "$_release_boot" = "$LOCK_BOOT_ID" ]; then
            rm -f "$LOCK_PATH/pid" "$LOCK_PATH/start_ticks" "$LOCK_PATH/boot_id" 2>/dev/null
            rmdir "$LOCK_PATH" 2>/dev/null
        fi
        LOCK_PATH=""
        LOCK_START_TICKS=""
        LOCK_BOOT_ID=""
    fi
    trap - EXIT HUP INT TERM
}
