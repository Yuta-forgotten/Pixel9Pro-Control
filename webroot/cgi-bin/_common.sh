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
JSON_BODY=""

json_headers() {
    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
}

json_status_headers() {
    printf 'Status: %s\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n' "$1"
}

json_escape() {
    printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r//g;s/\n/\\n/g'
}

json_error() {
    code="$1"
    shift
    msg="$*"
    json_status_headers "$code"
    printf '{"ok":false,"error":"%s"}\n' "$(json_escape "$msg")"
    exit 0
}

# 只允许回环地址访问
require_loopback() {
    case "${REMOTE_ADDR:-}" in
        127.0.0.1|::1|::ffff:127.0.0.1) ;;
        *) json_error '403 Forbidden' 'loopback only' ;;
    esac
}

# 要求 POST + application/json (触发 CORS preflight, 阻止浏览器 CSRF)
require_json_post() {
    [ "$REQUEST_METHOD" = "POST" ] || json_error '405 Method Not Allowed' 'POST only'
    case "${CONTENT_TYPE:-}" in
        application/json*) ;;
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
    _json_raw=$(dd bs=1 count="$_json_len" 2>/dev/null; printf 'x')
    JSON_BODY=${_json_raw%x}
    [ -n "$JSON_BODY" ] || json_error '400 Bad Request' 'empty request body'
    _json_actual=$(printf '%s' "$JSON_BODY" | wc -c | tr -d ' \r\n\t')
    [ "$_json_actual" = "$_json_len" ] \
        || json_error '400 Bad Request' 'incomplete request body'
    _json_shape=$(printf '%s' "$JSON_BODY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$_json_shape" in
        \{*\}) ;;
        *) json_error '400 Bad Request' 'JSON object required' ;;
    esac
}

cgi_atomic_write() {
    _cgi_file="$1"
    _cgi_value="$2"
    [ -n "$_cgi_file" ] && [ ! -d "$_cgi_file" ] || return 1
    _cgi_tmp="${_cgi_file}.tmp.$$"
    if printf '%s' "$_cgi_value" > "$_cgi_tmp" 2>/dev/null \
        && mv "$_cgi_tmp" "$_cgi_file" 2>/dev/null \
        && [ -f "$_cgi_file" ]; then
        _cgi_written=$(cat "$_cgi_file" 2>/dev/null)
        [ "$_cgi_written" = "$_cgi_value" ] && return 0
    fi
    rm -f "$_cgi_tmp" 2>/dev/null
    return 1
}

cgi_restore_file() {
    _cgi_restore_file="$1"
    _cgi_restore_existed="$2"
    _cgi_restore_value="$3"
    if [ "$_cgi_restore_existed" = "1" ]; then
        cgi_atomic_write "$_cgi_restore_file" "$_cgi_restore_value"
    else
        rm -f "$_cgi_restore_file" 2>/dev/null
    fi
}

# Token 认证
read_webui_token() {
    tr -d ' \r\n\t' < "$TOKEN_FILE" 2>/dev/null
}

require_token() {
    expected="$(read_webui_token)"
    actual="${HTTP_X_PIXEL9PRO_TOKEN:-}"
    [ -n "$expected" ] || json_error '503 Service Unavailable' 'missing server token'
    [ -n "$actual" ] || json_error '403 Forbidden' 'missing token'
    [ "$actual" = "$expected" ] || json_error '403 Forbidden' 'invalid token'
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
acquire_lock() {
    name="$1"
    case "$name" in ''|*[!A-Za-z0-9_.-]*) json_error '500 Internal Server Error' 'invalid lock name' ;; esac
    mkdir -p "$LOCKDIR_BASE" 2>/dev/null \
        || json_error '500 Internal Server Error' 'cannot create lock directory'
    chmod 700 "$LOCKDIR_BASE" 2>/dev/null \
        || json_error '500 Internal Server Error' 'cannot secure lock directory'
    LOCK_PATH="$LOCKDIR_BASE/${name}.lock"
    if mkdir "$LOCK_PATH" 2>/dev/null; then
        _lock_start=$(process_start_ticks "$$")
        if [ -z "$_lock_start" ] \
            || ! printf '%s\n' "$$" > "$LOCK_PATH/pid" 2>/dev/null \
            || ! printf '%s\n' "$_lock_start" > "$LOCK_PATH/start_ticks" 2>/dev/null; then
            rm -f "$LOCK_PATH/pid" "$LOCK_PATH/start_ticks" 2>/dev/null
            rmdir "$LOCK_PATH" 2>/dev/null
            json_error '500 Internal Server Error' 'cannot initialize lock'
        fi
        LOCK_START_TICKS="$_lock_start"
        trap 'release_lock' EXIT
        trap 'release_lock; exit 130' INT
        trap 'release_lock; exit 143' TERM
        return 0
    fi
    _lock_pid=$(cat "$LOCK_PATH/pid" 2>/dev/null | tr -d ' \r\n\t')
    _lock_start=$(cat "$LOCK_PATH/start_ticks" 2>/dev/null | tr -d ' \r\n\t')
    _lock_live_start=$(process_start_ticks "$_lock_pid")
    _stale=0
    if [ -z "$_lock_pid" ] || [ -z "$_lock_start" ]; then
        _stale=1
    elif ! kill -0 "$_lock_pid" 2>/dev/null; then
        _stale=1
    elif [ -z "$_lock_live_start" ] || [ "$_lock_live_start" != "$_lock_start" ]; then
        _stale=1
    fi
    if [ "$_stale" -eq 1 ]; then
        rm -f "$LOCK_PATH/pid" "$LOCK_PATH/start_ticks" 2>/dev/null
        rmdir "$LOCK_PATH" 2>/dev/null
        if mkdir "$LOCK_PATH" 2>/dev/null; then
            _lock_start=$(process_start_ticks "$$")
            if [ -z "$_lock_start" ] \
                || ! printf '%s\n' "$$" > "$LOCK_PATH/pid" 2>/dev/null \
                || ! printf '%s\n' "$_lock_start" > "$LOCK_PATH/start_ticks" 2>/dev/null; then
                rm -f "$LOCK_PATH/pid" "$LOCK_PATH/start_ticks" 2>/dev/null
                rmdir "$LOCK_PATH" 2>/dev/null
                json_error '500 Internal Server Error' 'cannot initialize lock'
            fi
            LOCK_START_TICKS="$_lock_start"
            trap 'release_lock' EXIT
            trap 'release_lock; exit 130' INT
            trap 'release_lock; exit 143' TERM
            return 0
        fi
    fi
    json_error '409 Conflict' "${name} busy"
}

release_lock() {
    if [ -n "$LOCK_PATH" ]; then
        _release_pid=$(cat "$LOCK_PATH/pid" 2>/dev/null | tr -d ' \r\n\t')
        _release_start=$(cat "$LOCK_PATH/start_ticks" 2>/dev/null | tr -d ' \r\n\t')
        if [ "$_release_pid" = "$$" ] \
            && [ -n "$LOCK_START_TICKS" ] \
            && [ "$_release_start" = "$LOCK_START_TICKS" ]; then
            rm -f "$LOCK_PATH/pid" "$LOCK_PATH/start_ticks" 2>/dev/null
            rmdir "$LOCK_PATH" 2>/dev/null
        fi
        LOCK_PATH=""
        LOCK_START_TICKS=""
    fi
    trap - EXIT INT TERM
}
