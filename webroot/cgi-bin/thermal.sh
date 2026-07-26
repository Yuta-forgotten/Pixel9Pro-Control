#!/system/bin/sh
# Thermal telemetry endpoint. GET serves cached/live zones or history; the
# authenticated POST clear action removes a suspect cache before a live read.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_thermal_cache.sh" \
    || json_error '500 Internal Server Error' 'thermal cache library not found'

_clear=0
case "$REQUEST_METHOD" in
    GET) ;;
    POST)
        require_json_post
        require_token
        read_json_body 128
        _action=$(printf '%s' "$JSON_BODY" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')
        [ "$_action" = "clear" ] || json_error '400 Bad Request' 'invalid thermal action'
        acquire_lock "thermal_cache"
        [ ! -d "$THERMAL_CACHE" ] \
            || json_error '500 Internal Server Error' 'thermal cache path is a directory'
        if [ -e "$THERMAL_CACHE" ]; then
            rm -f "$THERMAL_CACHE" 2>/dev/null \
                || json_error '500 Internal Server Error' 'cannot clear thermal cache'
        fi
        [ ! -e "$THERMAL_CACHE" ] \
            || json_error '500 Internal Server Error' 'thermal cache clear was not committed'
        _clear=1
        ;;
    *) json_error '405 Method Not Allowed' 'GET or POST only' ;;
esac

# --- 历史模式 ---
case "$QUERY_STRING" in *history=1*)
    json_headers
    HIST_FILE="${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/.thermal_history"
    if [ ! -s "$HIST_FILE" ]; then
        printf '{"points":[]}'
        exit 0
    fi
    _mins=30
    case "$QUERY_STRING" in *minutes=*)
        _mins=$(printf '%s' "$QUERY_STRING" | sed 's/.*minutes=\([0-9]*\).*/\1/')
        case "$_mins" in ''|*[!0-9]*) _mins=30 ;; esac
        [ "$_mins" -gt 720 ] 2>/dev/null && _mins=720
        [ "$_mins" -lt 1 ] 2>/dev/null && _mins=1
        ;;
    esac
    _cutoff=$(( $(date +%s) - _mins * 60 ))
    awk -F, -v cutoff="$_cutoff" '
    BEGIN { printf "{\"points\":["; n=0 }
    {
        if ($1+0 >= cutoff && $2+0 > 0) {
            if (n>0) printf ","
            printf "[%.0f,%.0f]", $1 + 0, $2 + 0
            n++
        }
    }
    END { printf "]}" }
    ' "$HIST_FILE"
    exit 0
    ;;
esac

# --- 实时模式 ---
json_headers
_cache_max_age=30
_now=$(date +%s 2>/dev/null || echo 0)
_fresh="$_clear"
case "$QUERY_STRING" in *fresh=1*) _fresh=1 ;; esac

cache_has_valid_skin() {
    _file="$1"
    awk '
        /"zone":"VIRTUAL-SKIN"/ {
            line = $0
            if (match(line, /"temp":[-0-9]+/)) {
                temp = substr(line, RSTART + 7, RLENGTH - 7) + 0
                if (temp >= 10000 && temp <= 85000) ok = 1
            }
        }
        END { exit ok ? 0 : 1 }
    ' "$_file" 2>/dev/null
}

_cache_valid=0
_cache_age=999999
if [ -s "$THERMAL_CACHE" ]; then
    _mtime=$(stat -c %Y "$THERMAL_CACHE" 2>/dev/null)
    case "$_mtime" in
        ''|*[!0-9]*) _mtime=0 ;;
    esac
    _cache_age=$((_now - _mtime))
    [ "$_cache_age" -lt 0 ] && _cache_age=999999
    if cache_has_valid_skin "$THERMAL_CACHE"; then
        _cache_valid=1
    fi
    if [ "$_fresh" -ne 1 ] && [ "$_cache_valid" -eq 1 ] && [ "$_cache_age" -le "$_cache_max_age" ] 2>/dev/null; then
        cat "$THERMAL_CACHE"
        exit 0
    fi
fi

_json=$(build_thermal_json 2>/dev/null)
if [ -n "$_json" ] && [ "$_json" != "[]" ]; then
    _tmp="${THERMAL_CACHE}.$$.$_now.tmp"
    if [ -d "$THERMAL_CACHE" ] \
        || ! printf '%s' "$_json" > "$_tmp" 2>/dev/null \
        || ! mv "$_tmp" "$THERMAL_CACHE" 2>/dev/null \
        || [ ! -f "$THERMAL_CACHE" ]; then
        rm -f "$_tmp" 2>/dev/null
    fi
    printf '%s' "$_json"
    exit 0
fi

[ -s "$THERMAL_CACHE" ] && cat "$THERMAL_CACHE" || printf '[]'
