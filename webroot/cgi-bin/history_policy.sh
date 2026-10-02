#!/system/bin/sh

# Backend-owned retention/cadence contract for Android BatteryStats history.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback
require_token

MODDIR="${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}"
STATE_ROOT="${PIXEL9PRO_STATE_ROOT:-/data/adb/pixel9pro_control}"
CONFIG="$STATE_ROOT/system_history_config"
ROOT="$STATE_ROOT/system_history"
RECEIPT="$ROOT/receipt"
LOCK_NAME=system_history_policy

config_value() {
    _hpc_key="$1"
    _hpc_default="$2"
    _hpc_value=$(sed -n "s/^${_hpc_key}=//p" "$CONFIG" 2>/dev/null | head -n 1 | tr -d ' \r\n\t')
    [ -n "$_hpc_value" ] && printf '%s' "$_hpc_value" || printf '%s' "$_hpc_default"
}

config_enabled() {
    case "$(config_value analytics_enabled 1)" in
        0|false|off|no) printf false ;;
        *) printf true ;;
    esac
}

stop_module_observers() {
    _hpp_rank_lock="${MODDIR}/.power_rank/collect.lock"
    _hpp_pid=$(cat "$_hpp_rank_lock/pid" 2>/dev/null | tr -d ' \r\n\t')
    case "$_hpp_pid" in ''|*[!0-9]*) _hpp_pid=0 ;; esac
    if [ "$_hpp_pid" -gt 0 ] 2>/dev/null && kill -0 "$_hpp_pid" 2>/dev/null; then
        kill -TERM "$_hpp_pid" 2>/dev/null || true
        sleep 1
        kill -KILL "$_hpp_pid" 2>/dev/null || true
    fi
    _hpp_state="${MODDIR}/.telemetry/state"
    _hpp_pid=$(sed -n 's/^pid=//p' "$_hpp_state" 2>/dev/null | head -n 1 | tr -d ' \r\n\t')
    case "$_hpp_pid" in ''|*[!0-9]*) _hpp_pid=0 ;; esac
    [ "$_hpp_pid" -gt 0 ] 2>/dev/null && kill -TERM "$_hpp_pid" 2>/dev/null || true
}

valid_uint_range() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null
}

json_num() { case "$1" in ''|*[!0-9]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }
json_escape() { printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r//g;s/\n/\\n/g'; }

emit_policy() {
    _retention=$(config_value retention_days 7)
    _max_bytes=$(config_value max_bytes 33554432)
    _on=$(config_value system_interval_on_sec 900)
    _off=$(config_value system_interval_off_sec 900)
    _module_on=$(config_value module_interval_on_sec 60)
    _module_off=$(config_value module_interval_off_sec 900)
    _enabled=$(config_enabled)
    _receipt='{}'
    _phase=staged
    if [ -r "$RECEIPT" ]; then
        _attempt=$(sed -n 's/^last_attempt_ts=//p' "$RECEIPT" | head -n 1 | tr -d ' \r\n\t')
        _success=$(sed -n 's/^last_success_ts=//p' "$RECEIPT" | head -n 1 | tr -d ' \r\n\t')
        _result=$(sed -n 's/^last_result=//p' "$RECEIPT" | head -n 1 | tr -d ' \r\n\t')
        _screen=$(sed -n 's/^screen=//p' "$RECEIPT" | head -n 1 | tr -d ' \r\n\t')
        _doze=$(sed -n 's/^doze=//p' "$RECEIPT" | head -n 1 | tr -d ' \r\n\t')
        _config_ts=$(stat -c %Y "$CONFIG" 2>/dev/null || printf '0')
        case "$_success:$_config_ts" in *[!0-9:]*) ;; *) [ "$_success" -ge "$_config_ts" ] 2>/dev/null && _phase=effective ;; esac
        _attempt_json=$(json_num "$_attempt")
        _success_json=$(json_num "$_success")
        _result_json=$(json_escape "$_result")
        _screen_json=$(json_escape "$_screen")
        _doze_json=$(json_escape "$_doze")
        _receipt=$(printf '{"last_attempt_ts":%s,"last_success_ts":%s,"last_result":"%s","screen":"%s","doze":"%s"}' "$_attempt_json" "$_success_json" "$_result_json" "$_screen_json" "$_doze_json")
    fi
    _now=$(date +%s 2>/dev/null || printf '0')
    _age=null
    case "$_success" in ''|*[!0-9]*) ;; *) _age=$((_now - _success)); [ "$_age" -lt 0 ] && _age=0 ;; esac
    printf '{"ok":true,"schema":2,"phase":"%s","policy":{"analytics_enabled":%s,"retention_days":%s,"max_bytes":%s,"module_interval_on_sec":%s,"module_interval_off_sec":%s,"system_interval_on_sec":%s,"system_interval_off_sec":%s},"collection":%s,"collection_age_sec":%s}\n' \
        "$_phase" "$_enabled" "$(json_num "$_retention")" "$(json_num "$_max_bytes")" "$(json_num "$_module_on")" "$(json_num "$_module_off")" "$(json_num "$_on")" "$(json_num "$_off")" "$_receipt" "$(json_num "$_age")"
}

case "${REQUEST_METHOD:-GET}" in
    GET)
        json_headers
        emit_policy
        ;;
    POST)
        require_json_post
        acquire_lock "$LOCK_NAME"
        read_json_body 2048
        body="$JSON_BODY"
        retention=$(printf '%s' "$body" | sed -n 's/.*"retention_days"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        max_bytes=$(printf '%s' "$body" | sed -n 's/.*"max_bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        interval_on=$(printf '%s' "$body" | sed -n 's/.*"system_interval_on_sec"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        interval_off=$(printf '%s' "$body" | sed -n 's/.*"system_interval_off_sec"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        module_on=$(printf '%s' "$body" | sed -n 's/.*"module_interval_on_sec"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        module_off=$(printf '%s' "$body" | sed -n 's/.*"module_interval_off_sec"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        # Keep the boolean parser POSIX/toybox compatible.  BRE alternation
        # (`\|`) is not available in every Android sed build, which made a
        # valid JSON body look like a missing boolean and returned HTTP 400.
        enabled=$(printf '%s' "$body" | sed -n 's/.*"analytics_enabled"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' | tr -d ' \r\n\t')
        valid_uint_range "$retention" 1 7 || { release_lock; json_error '400 Bad Request' 'retention_days must be 1..7'; }
        valid_uint_range "$max_bytes" 4194304 33554432 || { release_lock; json_error '400 Bad Request' 'max_bytes must be 4..32 MiB'; }
        valid_uint_range "$interval_on" 300 3600 || { release_lock; json_error '400 Bad Request' 'system_interval_on_sec must be 300..3600'; }
        valid_uint_range "$interval_off" 900 7200 || { release_lock; json_error '400 Bad Request' 'system_interval_off_sec must be 900..7200'; }
        [ -n "$module_on" ] || module_on=$(config_value module_interval_on_sec 60)
        [ -n "$module_off" ] || module_off=$(config_value module_interval_off_sec 900)
        valid_uint_range "$module_on" 60 3600 || { release_lock; json_error '400 Bad Request' 'module_interval_on_sec must be 60..3600'; }
        valid_uint_range "$module_off" 900 7200 || { release_lock; json_error '400 Bad Request' 'module_interval_off_sec must be 900..7200'; }
        case "$enabled" in true|1) enabled=1 ;; false|0) enabled=0 ;; *) release_lock; json_error '400 Bad Request' 'analytics_enabled must be boolean' ;; esac
        if [ "$enabled" -eq 1 ] 2>/dev/null && [ "$(sed -n 's/^status=//p' "$MODDIR/.telemetry/state" 2>/dev/null | head -n 1 | tr -d ' \r\n\t')" = running ]; then
            release_lock
            json_error '409 Conflict' 'foreground_session_active'
        fi
        if [ "$enabled" -eq 1 ] 2>/dev/null && [ "$(cat "$MODDIR/.idle_isolate_mode" 2>/dev/null | tr -d ' \r\n\t')" = on ]; then
            release_lock
            json_error '409 Conflict' 'foreground_only_active'
        fi
        mkdir -p "$ROOT" 2>/dev/null || { release_lock; json_error '500 Internal Server Error' 'cannot create history state'; }
        policy_value=$(printf 'analytics_enabled=%s\nretention_days=%s\nmax_bytes=%s\nmodule_interval_on_sec=%s\nmodule_interval_off_sec=%s\nsystem_interval_on_sec=%s\nsystem_interval_off_sec=%s\n' "$enabled" "$retention" "$max_bytes" "$module_on" "$module_off" "$interval_on" "$interval_off")
        cgi_atomic_write "$CONFIG" "$policy_value" \
            || { release_lock; json_error '500 Internal Server Error' 'cannot save history policy'; }
        chmod 600 "$CONFIG" 2>/dev/null || true
        [ "$enabled" -eq 0 ] 2>/dev/null && stop_module_observers
        release_lock
        json_headers
        emit_policy
        ;;
    *)
        json_error '405 Method Not Allowed' 'GET or POST only'
        ;;
esac
