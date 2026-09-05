#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/thermal.sh
# GET           → 返回关键热区温度 JSON (实时)
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
if [ -s "$THERMAL_CACHE" ]; then
    cat "$THERMAL_CACHE"
    exit 0
fi

build_thermal_json
