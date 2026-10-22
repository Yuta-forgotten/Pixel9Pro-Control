#!/system/bin/sh
# Thermal telemetry endpoint. GET serves cached/live zones or history; the
# authenticated POST clear action removes a suspect cache before a live read.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_thermal_cache.sh" \
    || json_error '500 Internal Server Error' 'thermal cache library not found'
. "$MODDIR/scripts/thermal_history_lib.sh" \
    || json_error '500 Internal Server Error' 'thermal history library not found'

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
    HIST_FILE="${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/.thermal_history"
    query_value() { printf '%s' "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1; }
    _now=$(date +%s 2>/dev/null || printf 0)
    case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
    _sensor=$(query_value sensor)
    [ -n "$_sensor" ] || _sensor=module
    case "$_sensor" in module|battery) ;; *) json_error '400 Bad Request' 'sensor must be module or battery' ;; esac
    _end=$(query_value end_ts)
    case "$_end" in ''|*[!0-9]*) _end=$_now ;; esac
    _start=$(query_value start_ts)
    case "$_start" in
        ''|*[!0-9]*)
            _mins=$(query_value minutes)
            case "$_mins" in ''|*[!0-9]*) _mins=30 ;; esac
            [ "$_mins" -ge 1 ] 2>/dev/null || _mins=1
            [ "$_mins" -le 10080 ] 2>/dev/null || _mins=10080
            _start=$((_end - _mins * 60))
            ;;
    esac
    [ "$_start" -le "$_end" ] 2>/dev/null || json_error '400 Bad Request' 'start_ts is after end_ts'
    [ $((_end - _start)) -le 604800 ] 2>/dev/null || json_error '400 Bad Request' 'history range exceeds 7 days'
    [ -f "$HIST_FILE" ] || HIST_FILE=/dev/null
    _updated=$(stat -c %Y "$HIST_FILE" 2>/dev/null || printf 0)
    case "$_updated" in ''|*[!0-9]*) _updated=0 ;; esac
    _recording_enabled=false
    background_tasks_enabled && _recording_enabled=true
    _recording_state=$(background_tasks_state)
    json_headers
    awk -F, -v start="$_start" -v end="$_end" -v selected="$_sensor" -v updated="$_updated" \
        -v enabled="$_recording_enabled" -v recording="$_recording_state" '
    function clean(value) { gsub(/[^A-Za-z0-9_.-]/, "", value); return value }
    BEGIN { printf "{\"points\":["; first=1; raw=0; valid=0; gaps=0; covered=0; first_ts=0; last_ts=0; previous_ts=0; previous_interval=0 }
    $1 ~ /^[0-9]+$/ && $1+0 >= start && $1+0 <= end {
        row_sensor=$11
        # Early extended rows used column 11 for the interval, not a sensor.
        if (row_sensor == "" || row_sensor ~ /^[0-9]+$/) row_sensor="module"
        if (row_sensor == "VIRTUAL-SKIN" || row_sensor == "SKIN") row_sensor="module"
        if (row_sensor != selected) next
        raw++
        if ($2 !~ /^[0-9]+$/ || $2+0 < 10000 || $2+0 > 85000 || $6 == "0") next
        ts=$1+0
        interval=($11 ~ /^[0-9]+$/ && $11+0 > 0 ? $11+0 : ($9 == "on" ? 60 : 900))
        if (previous_ts) {
            if (ts <= previous_ts) next
            if (ts-previous_ts > (previous_interval > interval ? previous_interval : interval)*2 || $3 != previous_boot) gaps++
            else covered+=ts-previous_ts
        }
        previous_boot=$3
        previous_ts=ts; previous_interval=interval
        if (!first) printf ","
        first=0; valid++
        if (!first_ts) first_ts=ts
        last_ts=ts
        printf "{\"ts\":%.0f,\"temp_mc\":%.0f,\"sensor\":\"%s\",\"source\":\"%s\",\"screen\":\"%s\",\"expected_interval_sec\":%d,\"boot_id\":\"%s\",\"session_id\":\"%s\",\"quality\":\"%s\",\"valid\":true}", \
            ts,$2+0,selected,clean($5),clean($9),interval,clean($3),clean($4),clean($8)
    }
    END {
        elapsed=covered
        window=end-start; if (window < 1) window=1
        coverage=elapsed/window; if (coverage > 1) coverage=1
        quality=(valid == 0 ? "no_data" : gaps > 0 ? "partial" : "available")
        print "],\"ok\":true,\"schema\":1,\"source\":\"module_thermal_history\",\"sensor\":\"" selected "\",\"recording_enabled\":" enabled ",\"recording_state\":\"" recording "\",\"time_unit\":\"unix_seconds\",\"temperature_unit\":\"millidegree_celsius\",\"start_ts\":" start ",\"end_ts\":" end ",\"raw_samples\":" raw ",\"valid_samples\":" valid ",\"count\":" valid ",\"coverage_sec\":" elapsed ",\"coverage_ratio\":" coverage ",\"gap_count\":" gaps ",\"quality\":\"" quality "\",\"updated_at\":" updated ",\"data_revision\":\"" updated ":" selected ":" start ":" end "\"}"
    }
    ' "$HIST_FILE" 2>/dev/null
    exit 0
    ;;
esac

# --- 实时模式 ---
json_headers
# The service refreshes the foreground cache on a 60-second cadence. Keep a
# foreground read can also record a real sample while the service is asleep.
_cache_max_age=60
_now=$(date +%s 2>/dev/null || echo 0)
_fresh="$_clear"
case "$QUERY_STRING" in *fresh=1*) _fresh=1 ;; esac

cache_has_valid_skin() {
    _file="$1"
    # The builder emits flat zone objects; bind the temperature to its object
    # rather than relying on HAL/sysfs sensor ordering in the array.
    awk -F '[{}]' '
        {
            for (i = 1; i <= NF; i++) {
                object = $i
                if (object !~ /"zone"[[:space:]]*:[[:space:]]*"VIRTUAL-SKIN"/) continue
                if (match(object, /"temp"[[:space:]]*:[[:space:]]*-?[0-9]+[[:space:]]*(,|$)/)) {
                    value = substr(object, RSTART, RLENGTH)
                    sub(/^"temp"[[:space:]]*:[[:space:]]*/, "", value)
                    temp = value + 0
                    if (temp >= 10000 && temp <= 85000) ok = 1
                }
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
    if [ "$_fresh" -ne 1 ] && [ "$_cache_valid" -eq 1 ] && [ "$_cache_age" -lt "$_cache_max_age" ] 2>/dev/null; then
        _cached_json=$(cat "$THERMAL_CACHE" 2>/dev/null)
        thermal_history_record "$_cached_json" "$_mtime" on cache >/dev/null 2>&1 || true
        printf '%s' "$_cached_json"
        exit 0
    fi
fi

build_thermal_json >/dev/null 2>&1
_json="$THERMAL_BUILD_JSON"
if [ -n "$_json" ] && [ "$_json" != "[]" ]; then
    _now=$(date +%s 2>/dev/null || printf 0)
    _tmp="${THERMAL_CACHE}.$$.$_now.tmp"
    if [ -d "$THERMAL_CACHE" ] \
        || ! printf '%s' "$_json" > "$_tmp" 2>/dev/null \
        || ! mv "$_tmp" "$THERMAL_CACHE" 2>/dev/null \
        || [ ! -f "$THERMAL_CACHE" ]; then
        rm -f "$_tmp" 2>/dev/null
    fi
    thermal_history_record "$_json" "$_now" on "$THERMAL_BUILD_SOURCE" >/dev/null 2>&1 || true
    printf '%s' "$_json"
    exit 0
fi

[ -s "$THERMAL_CACHE" ] && cat "$THERMAL_CACHE" || printf '[]'
