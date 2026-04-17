#!/system/bin/sh
##############################################################
# _common.sh — CGI 安全基础设施
# 所有 CGI 脚本在开头 source 此文件
# 提供: loopback 校验 / token 认证 / POST+JSON 校验 / 互斥锁
##############################################################

MODDIR="${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}"
WEBUI_PORT="${PIXEL9PRO_WEBUI_PORT:-6210}"
TOKEN_FILE="${PIXEL9PRO_WEBUI_TOKEN_FILE:-$MODDIR/.webui_token}"
THERMAL_CACHE="${PIXEL9PRO_THERMAL_CACHE:-$MODDIR/.thermal_cache.json}"
LOCKDIR_BASE="${PIXEL9PRO_LOCKDIR_BASE:-$MODDIR/.locks}"
LOCK_PATH=""

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
        application/json*|'') ;;
        *) json_error '415 Unsupported Media Type' 'application/json only' ;;
    esac
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

# 文件锁 (mkdir 原子操作 + 过期自动回收)
acquire_lock() {
    name="$1"
    mkdir -p "$LOCKDIR_BASE" 2>/dev/null
    LOCK_PATH="$LOCKDIR_BASE/${name}.lock"
    if mkdir "$LOCK_PATH" 2>/dev/null; then
        echo "$$" > "$LOCK_PATH/pid" 2>/dev/null
        trap 'release_lock' EXIT INT TERM
        return 0
    fi
    # 检查持有锁的进程是否仍然存活
    _lock_pid=$(cat "$LOCK_PATH/pid" 2>/dev/null)
    _stale=0
    if [ -z "$_lock_pid" ]; then
        _stale=1
    elif ! kill -0 "$_lock_pid" 2>/dev/null; then
        _stale=1
    fi
    if [ "$_stale" -eq 1 ]; then
        rm -f "$LOCK_PATH/pid" 2>/dev/null
        rmdir "$LOCK_PATH" 2>/dev/null
        if mkdir "$LOCK_PATH" 2>/dev/null; then
            echo "$$" > "$LOCK_PATH/pid" 2>/dev/null
            trap 'release_lock' EXIT INT TERM
            return 0
        fi
    fi
    json_error '409 Conflict' "${name} busy"
}

release_lock() {
    if [ -n "$LOCK_PATH" ]; then
        rm -f "$LOCK_PATH/pid" 2>/dev/null
        rmdir "$LOCK_PATH" 2>/dev/null
        LOCK_PATH=""
    fi
    trap - EXIT INT TERM
}
