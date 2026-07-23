#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/thermal.sh
# GET           → 返回关键热区温度 JSON (快路径优先读缓存)
# GET ?fresh=1 → 强制重建热区缓存后返回
# GET ?clear=1&fresh=1 → 清除可疑缓存后重建（需 WebUI token）
# GET ?history=1 → 返回后端持久化的温度历史 CSV→JSON
#   可选 &minutes=N (默认 30, 最大 720)
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_thermal_cache.sh"

require_loopback
[ "$REQUEST_METHOD" = "GET" ] || json_error '405 Method Not Allowed' 'GET only'

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
            printf "[%s,%s]", $1, $2
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
_fresh=0
case "$QUERY_STRING" in *fresh=1*) _fresh=1 ;; esac
case "$QUERY_STRING" in *clear=1*) require_token; rm -f "$THERMAL_CACHE" 2>/dev/null; _fresh=1 ;; esac

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
    printf '%s' "$_json" > "$_tmp" 2>/dev/null
    mv "$_tmp" "$THERMAL_CACHE" 2>/dev/null
    printf '%s' "$_json"
    exit 0
fi

[ -s "$THERMAL_CACHE" ] && cat "$THERMAL_CACHE" || printf '[]'
