#!/system/bin/sh
##############################################################
# Authenticated low-power telemetry sessions.
# GET: status/history. POST: start/stop/export.
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/scripts/telemetry_lib.sh" \
    || json_error '500 Internal Server Error' 'telemetry library not found'
require_loopback

TELEMETRY_WORKER="${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/scripts/telemetry_worker.sh"
DOWNLOAD_DIR="${PIXEL9PRO_DOWNLOAD_DIR:-/sdcard/Download}"

query_value() {
    _tg_key="$1"
    _tg_value=$(printf '%s' "${QUERY_STRING:-}" | sed -n "s/.*\(^\|&\)${_tg_key}=\([^&]*\).*/\2/p" | head -n 1)
    printf '%s' "$_tg_value"
}

validate_epoch() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}

read_session_fields() {
    _tg_requested_id=$(query_value session_id)
    _tg_state_file="$TELEMETRY_STATE"
    _tg_requested_valid=0
    TG_DIR=""
    if telemetry_valid_id "$_tg_requested_id"; then
        _tg_requested_valid=1
        TG_DIR=$(telemetry_session_dir "$_tg_requested_id")
        [ -s "$TG_DIR/state" ] && _tg_state_file="$TG_DIR/state" || { TG_DIR=""; _tg_state_file=/dev/null; }
    fi
    TG_ID=$(telemetry_state_value "$_tg_state_file" session_id "")
    TG_STATUS=$(telemetry_state_value "$_tg_state_file" status "none")
    TG_START=$(telemetry_state_value "$_tg_state_file" start_ts 0)
    TG_END=$(telemetry_state_value "$_tg_state_file" end_ts 0)
    TG_DURATION=$(telemetry_state_value "$_tg_state_file" duration_sec 0)
    TG_MAX_BYTES=$(telemetry_state_value "$_tg_state_file" max_bytes 0)
    TG_PID=$(telemetry_state_value "$_tg_state_file" pid 0)
    TG_PID_START=$(telemetry_state_value "$_tg_state_file" pid_start_ticks "")
    TG_REASON=$(telemetry_state_value "$_tg_state_file" reason "")
    TG_SAMPLES=$(telemetry_state_value "$_tg_state_file" samples 0)
    TG_BYTES=$(telemetry_state_value "$_tg_state_file" bytes 0)
    TG_LAST_SAMPLE=$(telemetry_state_value "$_tg_state_file" last_sample_ts 0)
    TG_QUALITY=$(telemetry_state_value "$_tg_state_file" quality unknown)
    TG_RESETS=$(telemetry_state_value "$_tg_state_file" reset_count 0)
    TG_STOP_REQUESTED=$(telemetry_state_value "$_tg_state_file" stop_requested 0)
    [ -n "$TG_DIR" ] || TG_DIR=$(telemetry_state_value "$_tg_state_file" session_dir "")
    [ "$_tg_requested_valid" -eq 1 ] && [ -s "$_tg_state_file" ] || [ "$_tg_requested_valid" -eq 0 ] || TG_DIR=""
    telemetry_valid_id "$TG_ID" || TG_ID=""
    [ -d "$TG_DIR" ] || TG_DIR=""
}

json_bool() {
    case "$1" in 1|true|yes|on) printf true ;; *) printf false ;; esac
}

emit_session_json() {
    read_session_fields
    _tg_now=$(telemetry_now)
    validate_epoch "$TG_START" || TG_START="$_tg_now"
    validate_epoch "$TG_END" || TG_END=0
    _tg_alive=false
    if [ "$TG_STATUS" = running ] || [ "$TG_STATUS" = stopping ]; then
        telemetry_pid_alive "$TG_PID" "$TG_PID_START" && _tg_alive=true
    fi
    _tg_end_effective="$TG_END"
    [ "$_tg_end_effective" -gt 0 ] 2>/dev/null || _tg_end_effective="$_tg_now"
    _tg_elapsed=$((_tg_end_effective - TG_START))
    [ "$_tg_elapsed" -ge 0 ] 2>/dev/null || _tg_elapsed=0
    printf '{"id":"%s","status":"%s","start_ts":%s,"end_ts":%s,"duration_sec":%s,"elapsed_sec":%s,' \
        "$(telemetry_json_escape "$TG_ID")" "$(telemetry_json_escape "$TG_STATUS")" \
        "$(telemetry_num "$TG_START")" "$(telemetry_num "$TG_END")" "$(telemetry_num "$TG_DURATION")" "$_tg_elapsed"
    printf '"worker_pid":%s,"worker_alive":%s,"last_sample_ts":%s,"sample_count":%s,"bytes":%s,"max_bytes":%s,' \
        "$(telemetry_num "$TG_PID")" "$_tg_alive" "$(telemetry_num "$TG_LAST_SAMPLE")" \
        "$(telemetry_num "$TG_SAMPLES")" "$(telemetry_num "$TG_BYTES")" "$(telemetry_num "$TG_MAX_BYTES")"
    printf '"quality":"%s","reset_count":%s,"reason":"%s","stop_requested":%s}' \
        "$(telemetry_json_escape "$TG_QUALITY")" "$(telemetry_num "$TG_RESETS")" \
        "$(telemetry_json_escape "$TG_REASON")" "$(json_bool "$TG_STOP_REQUESTED")"
}

emit_status() {
    json_headers
    read_session_fields
    if [ "$TG_STATUS" = running ] && ! telemetry_pid_alive "$TG_PID" "$TG_PID_START"; then
        telemetry_state_write "$TG_ID" failed "$TG_START" "$(telemetry_now)" "$TG_DURATION" "$TG_MAX_BYTES" "$TG_PID" "$TG_PID_START" worker_dead "$TG_SAMPLES" "$TG_BYTES" "$TG_LAST_SAMPLE" failed "$TG_RESETS" "$TG_STOP_REQUESTED" "$TG_DIR" >/dev/null 2>&1 || true
        read_session_fields
    fi
    if [ -z "$TG_ID" ]; then
        printf '{"ok":true,"schema":%s,"session":null}\n' "$TELEMETRY_SCHEMA"
        return 0
    fi
    printf '{"ok":true,"schema":%s,"session":' "$TELEMETRY_SCHEMA"
    emit_session_json
    printf '}\n'
}

history_bounds() {
    TG_NOW=$(telemetry_now)
    TG_END_FILTER=$(query_value end_ts)
    TG_START_FILTER=$(query_value start_ts)
    TG_MINUTES=$(query_value minutes)
    [ -n "$TG_END_FILTER" ] || TG_END_FILTER="$TG_NOW"
    validate_epoch "$TG_END_FILTER" || json_error '400 Bad Request' 'invalid end_ts'
    if [ -n "$TG_START_FILTER" ]; then
        validate_epoch "$TG_START_FILTER" || json_error '400 Bad Request' 'invalid start_ts'
    elif [ -n "$TG_MINUTES" ]; then
        case "$TG_MINUTES" in ''|*[!0-9]*) json_error '400 Bad Request' 'invalid minutes' ;; esac
        [ "$TG_MINUTES" -ge 1 ] 2>/dev/null || TG_MINUTES=1
        [ "$TG_MINUTES" -le 720 ] 2>/dev/null || TG_MINUTES=720
        TG_START_FILTER=$((TG_END_FILTER - TG_MINUTES * 60))
    else
        TG_START_FILTER=$((TG_END_FILTER - 60 * 60))
    fi
    [ "$TG_START_FILTER" -le "$TG_END_FILTER" ] 2>/dev/null \
        || json_error '400 Bad Request' 'start_ts is after end_ts'
}

emit_history_array() {
    _tg_file="$1"
    _tg_kind="$2"
    _tg_start="$3"
    _tg_end="$4"
    awk -F, -v start="$_tg_start" -v end="$_tg_end" -v kind="$_tg_kind" '
        BEGIN { first=1 }
        $1 ~ /^[0-9]+$/ && $1 + 0 >= start && $1 + 0 <= end {
            if (!first) printf ","; first=0
            if (kind == "power") {
                printf "{\"ts\":%s,\"screen\":\"%s\",\"status\":\"%s\",\"level_pct\":", $1, $2, $3
                if ($4 ~ /^-?[0-9]+$/) printf "%s", $4; else printf "null"
                printf ",\"charge_uah\":"; if ($5 ~ /^-?[0-9]+$/) printf "%s", $5; else printf "null"
                printf ",\"current_ua\":"; if ($6 ~ /^-?[0-9]+$/) printf "%s", $6; else printf "null"
                printf ",\"voltage_uv\":"; if ($7 ~ /^-?[0-9]+$/) printf "%s", $7; else printf "null"
                printf ",\"odpm_modem_uws\":"; if ($14 ~ /^-?[0-9]+$/) printf "%s", $14; else printf "null"
                printf ",\"odpm_rffe_uws\":"; if ($15 ~ /^-?[0-9]+$/) printf "%s", $15; else printf "null"
                printf ",\"quality\":\"%s\"}", $16
            } else {
                printf "{\"ts\":%s,\"screen\":\"%s\",\"virtual_skin_mc\":", $1, $2
                if ($8 ~ /^-?[0-9]+$/) printf "%s", $8; else printf "null"
                printf ",\"battery_mc\":"; if ($9 ~ /^-?[0-9]+$/) printf "%s", $9; else printf "null"
                printf ",\"soc_mc\":"; if ($10 ~ /^-?[0-9]+$/) printf "%s", $10; else printf "null"
                printf ",\"charging_therm_mc\":"; if ($11 ~ /^-?[0-9]+$/) printf "%s", $11; else printf "null"
                printf ",\"btmspkr_therm_mc\":"; if ($12 ~ /^-?[0-9]+$/) printf "%s", $12; else printf "null"
                printf ",\"thermal_status\":"; if ($13 ~ /^[0-9]+$/) printf "%s", $13; else printf "null"
                printf ",\"quality\":\"%s\"}", $16
            }
        }
    ' "$_tg_file" 2>/dev/null
}

emit_legacy_array() {
    _tg_file="$1"
    _tg_kind="$2"
    _tg_start="$3"
    _tg_end="$4"
    awk -F, -v start="$_tg_start" -v end="$_tg_end" -v kind="$_tg_kind" '
        BEGIN { first=1 }
        $1 ~ /^[0-9]+$/ && $1 + 0 >= start && $1 + 0 <= end {
            if (!first) printf ","; first=0
            if (kind == "power") {
                printf "{\"ts\":%s,\"screen\":\"unknown\",\"status\":\"%s\",\"level_pct\":", $1, $4
                if ($2 ~ /^-?[0-9]+$/) printf "%s", $2; else printf "null"
                printf ",\"charge_uah\":"; if ($3 ~ /^-?[0-9]+$/) printf "%s", $3; else printf "null"
                printf ",\"current_ua\":null,\"voltage_uv\":null,\"odpm_modem_uws\":null,\"odpm_rffe_uws\":null,\"quality\":\"legacy_history\"}"
            } else {
                printf "{\"ts\":%s,\"screen\":\"unknown\",\"virtual_skin_mc\":", $1
                if ($2 ~ /^-?[0-9]+$/) printf "%s", $2; else printf "null"
                printf ",\"battery_mc\":null,\"soc_mc\":null,\"charging_therm_mc\":null,\"btmspkr_therm_mc\":null,\"thermal_status\":null,\"quality\":\"legacy_history\"}"
            }
        }
    ' "$_tg_file" 2>/dev/null
}

emit_history() {
    history_bounds
    read_session_fields
    [ "${_tg_requested_valid:-0}" -eq 1 ] && [ -z "$TG_DIR" ] \
        && json_error '404 Not Found' 'telemetry session not found'
    _tg_legacy=0
    if [ -n "$TG_DIR" ]; then
        _tg_csv=$(telemetry_sample_file "$TG_DIR")
        [ -s "$_tg_csv" ] || _tg_legacy=1
    else
        _tg_legacy=1
    fi
    _tg_coverage_file="$_tg_csv"
    [ "$_tg_legacy" -eq 1 ] && _tg_coverage_file="${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/.power_history"
    _tg_coverage=$(awk -F, -v start="$TG_START_FILTER" -v end="$TG_END_FILTER" '
        $1 ~ /^[0-9]+$/ && $1 >= start && $1 <= end { if (!first) first=$1; last=$1; n++ }
        END { if (n && end > start) { c=last-first; if(c<0)c=0; if(c>end-start)c=end-start; printf "%.3f", c/(end-start) } else printf "0" }
    ' "$_tg_coverage_file" 2>/dev/null)
    [ -n "$_tg_coverage" ] || _tg_coverage=0
    _tg_quality="$TG_QUALITY"
    [ "$_tg_legacy" -eq 1 ] && _tg_quality=legacy_history
    _tg_attr_source=batterystats_start_end
    [ "$_tg_legacy" -eq 1 ] && _tg_attr_source=none_legacy_module_history
    _tg_json_start=$(telemetry_num "$TG_START_FILTER")
    _tg_json_end=$(telemetry_num "$TG_END_FILTER")
    json_headers
    printf '{"ok":true,"schema":%s,"session_id":"%s","window":{"start_ts":%s,"end_ts":%s,"coverage_ratio":%s,"quality":"%s"},"power":[' \
        "$TELEMETRY_SCHEMA" "$(telemetry_json_escape "$TG_ID")" "$_tg_json_start" "$_tg_json_end" \
        "$_tg_coverage" "$(telemetry_json_escape "$_tg_quality")"
    if [ "$_tg_legacy" -eq 1 ]; then
        emit_legacy_array "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/.power_history" power "$TG_START_FILTER" "$TG_END_FILTER"
    else
        emit_history_array "$_tg_csv" power "$TG_START_FILTER" "$TG_END_FILTER"
    fi
    printf '],"thermal":['
    if [ "$_tg_legacy" -eq 1 ]; then
        emit_legacy_array "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/.thermal_history" thermal "$TG_START_FILTER" "$TG_END_FILTER"
    else
        emit_history_array "$_tg_csv" thermal "$TG_START_FILTER" "$TG_END_FILTER"
    fi
    printf '],"attribution":{"source":"%s","quality":"%s","start_snapshot":%s,"end_snapshot":%s}}\n' \
        "$(telemetry_json_escape "$_tg_attr_source")" "$(telemetry_json_escape "$_tg_quality")" \
        "$( [ "$_tg_legacy" -eq 0 ] && [ -s "$TG_DIR/batterystats_start.txt" ] && printf true || printf false )" \
        "$( [ "$_tg_legacy" -eq 0 ] && [ -s "$TG_DIR/batterystats_end.txt" ] && printf true || printf false )"
}

write_session_json() {
    _tg_dir="$1"
    _tg_start="$2"
    _tg_end="$3"
    _tg_file="$4"
    _tg_quality="$5"
    _tg_coverage=$(awk -F, -v start="$_tg_start" -v end="$_tg_end" '
        $1 ~ /^[0-9]+$/ { if(!first)first=$1; last=$1; n++ }
        END { if(n && end>start){ c=last-first; if(c<0)c=0; if(c>end-start)c=end-start; printf "%.3f", c/(end-start) } else printf "0" }
    ' "$_tg_file" 2>/dev/null)
    [ -n "$_tg_coverage" ] || _tg_coverage=0
    {
        printf '{"schema":%s,"session_id":"%s","window":{"start_ts":%s,"end_ts":%s,"coverage_ratio":%s,"quality":"%s"},' \
            "$TELEMETRY_SCHEMA" "$(telemetry_json_escape "$TG_ID")" "$(telemetry_num "$_tg_start")" \
            "$(telemetry_num "$_tg_end")" "$_tg_coverage" "$(telemetry_json_escape "$_tg_quality")"
        printf '"sample_csv":"samples.csv","sample_jsonl":"samples.jsonl","units":{"charge_uah":"uAh","current_ua":"uA","voltage_uv":"uV","temperature_mc":"mC","odpm_uws":"uWs"},'
        printf '"batterystats":{"start_snapshot":%s,"end_snapshot":%s,"scope":"independent snapshots; not selected-window attribution"}}\n' \
            "$( [ -s "$_tg_dir/batterystats_start.txt" ] && printf true || printf false )" \
            "$( [ -s "$_tg_dir/batterystats_end.txt" ] && printf true || printf false )"
    } > "$_tg_file" 2>/dev/null
}

export_session() {
    _tg_body_id=$(printf '%s' "${JSON_BODY:-}" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_.:-]*\)".*/\1/p')
    if [ -n "$_tg_body_id" ]; then QUERY_STRING="action=status&session_id=$_tg_body_id"; fi
    read_session_fields
    [ -n "$TG_DIR" ] || json_error '404 Not Found' 'telemetry session not found'
    # A stop can race the worker's one-time startup. Preserve an honest,
    # exportable empty session instead of failing only because no sample ran.
    if [ ! -e "$TG_DIR/samples.csv" ]; then
        printf 'ts,screen,charge_status,level_pct,charge_uah,current_ua,voltage_uv,virtual_skin_mc,battery_mc,soc_mc,charging_therm_mc,btmspkr_therm_mc,thermal_status,odpm_modem_uws,odpm_rffe_uws,sample_quality,top_processes\n' > "$TG_DIR/samples.csv" 2>/dev/null || json_error '500 Internal Server Error' 'cannot initialize empty telemetry samples'
    fi
    _tg_now=$(telemetry_now)
    _tg_stamp=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || printf '%s' "$_tg_now")
    _tg_final="$DOWNLOAD_DIR/pixel9pro_telemetry_${TG_ID}_${_tg_stamp}"
    _tg_tmp="$DOWNLOAD_DIR/.pixel9pro_telemetry_${TG_ID}_${_tg_stamp}_$$.tmp"
    case "$DOWNLOAD_DIR:$_tg_final:$_tg_tmp" in ''|*..*|*\\*) json_error '500 Internal Server Error' 'unsafe export path' ;; esac
    mkdir -p "$DOWNLOAD_DIR" 2>/dev/null || json_error '500 Internal Server Error' 'cannot create Download directory'
    [ ! -e "$_tg_final" ] && [ ! -e "$_tg_tmp" ] || json_error '409 Conflict' 'export path already exists'
    mkdir "$_tg_tmp" 2>/dev/null || json_error '500 Internal Server Error' 'cannot create export transaction'
    trap 'rm -rf "$_tg_tmp" 2>/dev/null' EXIT INT TERM
    for _tg_name in samples.csv samples.jsonl batterystats_start.txt batterystats_end.txt; do
        [ -s "$TG_DIR/$_tg_name" ] && cp "$TG_DIR/$_tg_name" "$_tg_tmp/$_tg_name" 2>/dev/null || true
    done
    [ -s "$_tg_tmp/samples.csv" ] || json_error '500 Internal Server Error' 'samples.csv missing'
    write_session_json "$_tg_tmp" "$TG_START" "$TG_END" "$_tg_tmp/schema.json" "$TG_QUALITY"
    [ -s "$_tg_tmp/schema.json" ] || json_error '500 Internal Server Error' 'schema.json missing'
    mv "$_tg_tmp" "$_tg_final" 2>/dev/null || json_error '500 Internal Server Error' 'cannot finalize export directory'
    trap - EXIT INT TERM
    _tg_files=""
    for _tg_path in "$_tg_final"/*; do
        [ -f "$_tg_path" ] || continue
        _tg_name=${_tg_path##*/}
        _tg_bytes=$(wc -c < "$_tg_path" 2>/dev/null | tr -d ' \r\n')
        _tg_hash=$(sha256sum "$_tg_path" 2>/dev/null | awk '{print $1}')
        [ -n "$_tg_bytes" ] && [ -n "$_tg_hash" ] || continue
        [ -z "$_tg_files" ] || _tg_files="$_tg_files,"
        _tg_files="$_tg_files{\"name\":\"$(telemetry_json_escape "$_tg_name")\",\"bytes\":$_tg_bytes,\"sha256\":\"$_tg_hash\"}"
    done
    json_headers
    printf '{"ok":true,"schema":%s,"session_id":"%s","directory":"%s","files":[%s]}\n' \
        "$TELEMETRY_SCHEMA" "$(telemetry_json_escape "$TG_ID")" "$(telemetry_json_escape "$_tg_final")" "$_tg_files"
}

handle_start() {
    acquire_lock telemetry
    read_session_fields
    if [ "$TG_STATUS" = running ] || [ "$TG_STATUS" = stopping ]; then
        telemetry_pid_alive "$TG_PID" "$TG_PID_START" && json_error '409 Conflict' 'telemetry session already running'
        telemetry_state_write "$TG_ID" failed "$TG_START" "$(telemetry_now)" "$TG_DURATION" "$TG_MAX_BYTES" "$TG_PID" "$TG_PID_START" worker_dead "$TG_SAMPLES" "$TG_BYTES" "$TG_LAST_SAMPLE" failed "$TG_RESETS" 0 "$TG_DIR" \
            || json_error '500 Internal Server Error' 'cannot persist stale worker state'
    fi
    _tg_body="$JSON_BODY"
    _tg_duration=$(printf '%s' "$_tg_body" | sed -n 's/.*"duration_sec"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
    _tg_max=$(printf '%s' "$_tg_body" | sed -n 's/.*"max_bytes"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
    [ -n "$_tg_duration" ] || _tg_duration=0
    case "$_tg_duration" in ''|*[!0-9]*) json_error '400 Bad Request' 'invalid duration_sec' ;; esac
    [ "$_tg_duration" -eq 0 ] 2>/dev/null \
        || { [ "$_tg_duration" -ge 60 ] 2>/dev/null && [ "$_tg_duration" -le 86400 ] 2>/dev/null; } \
        || json_error '400 Bad Request' 'duration_sec must be 0 or 60..86400'
    [ -n "$_tg_max" ] || _tg_max=$TELEMETRY_DEFAULT_MAX_BYTES
    case "$_tg_max" in ''|*[!0-9]*) json_error '400 Bad Request' 'invalid max_bytes' ;; esac
    [ "$_tg_max" -ge 65536 ] 2>/dev/null && [ "$_tg_max" -le "$TELEMETRY_MAX_BYTES_LIMIT" ] 2>/dev/null \
        || json_error '400 Bad Request' 'max_bytes out of bounds'
    _tg_now=$(telemetry_now)
    _tg_id="${_tg_now}_$$"
    _tg_dir=$(telemetry_session_dir "$_tg_id")
    mkdir -p "$_tg_dir" 2>/dev/null || json_error '500 Internal Server Error' 'cannot create telemetry session'
    telemetry_state_write "$_tg_id" pending "$_tg_now" 0 "$_tg_duration" "$_tg_max" 0 0 pending 0 0 0 complete 0 0 "$_tg_dir" \
        || json_error '500 Internal Server Error' 'cannot persist telemetry session'
    sh "$TELEMETRY_WORKER" "$_tg_id" "$_tg_dir" "$_tg_duration" "$_tg_max" >/dev/null 2>&1 &
    _tg_pid=$!
    _tg_pid_start=$(telemetry_pid_start "$_tg_pid")
    telemetry_state_write "$_tg_id" running "$_tg_now" 0 "$_tg_duration" "$_tg_max" "$_tg_pid" "$_tg_pid_start" started 0 0 0 complete 0 0 "$_tg_dir" \
        || json_error '500 Internal Server Error' 'cannot persist worker state'
    if [ "$AUDIT_LOG_AVAILABLE" -eq 1 ]; then audit_log_event telemetry start success SESSION_STARTED 0 >/dev/null 2>&1 || true; fi
    json_headers
    printf '{"ok":true,"schema":%s,"session":' "$TELEMETRY_SCHEMA"
    emit_session_json
    printf '}\n'
}

handle_stop() {
    acquire_lock telemetry
    _tg_body_id=$(printf '%s' "${JSON_BODY:-}" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_.:-]*\)".*/\1/p')
    if [ -n "$_tg_body_id" ]; then QUERY_STRING="action=status&session_id=$_tg_body_id"; fi
    read_session_fields
    [ -n "$TG_ID" ] || json_error '404 Not Found' 'no telemetry session'
    telemetry_pid_alive "$TG_PID" "$TG_PID_START"
    _tg_alive=$?
    if [ "$TG_STATUS" = running ] && [ "$_tg_alive" -eq 0 ]; then
        telemetry_state_write "$TG_ID" stopping "$TG_START" 0 "$TG_DURATION" "$TG_MAX_BYTES" "$TG_PID" "$TG_PID_START" user_stop "$TG_SAMPLES" "$TG_BYTES" "$TG_LAST_SAMPLE" "$TG_QUALITY" "$TG_RESETS" 1 "$TG_DIR" \
            || json_error '500 Internal Server Error' 'cannot persist stop request'
        kill -TERM "$TG_PID" 2>/dev/null || true
        # A shell can defer a TERM trap while waiting in sleep.  Commit the
        # user-visible terminal state immediately; the worker observes this
        # state and exits without overwriting it when the trap is delivered.
        telemetry_state_write "$TG_ID" stopped "$TG_START" "$(telemetry_now)" "$TG_DURATION" "$TG_MAX_BYTES" "$TG_PID" "$TG_PID_START" user_stop "$TG_SAMPLES" "$TG_BYTES" "$TG_LAST_SAMPLE" "$TG_QUALITY" "$TG_RESETS" 1 "$TG_DIR" \
            || json_error '500 Internal Server Error' 'cannot persist stopped state'
    elif [ "$TG_STATUS" = running ]; then
        telemetry_state_write "$TG_ID" failed "$TG_START" "$(telemetry_now)" "$TG_DURATION" "$TG_MAX_BYTES" "$TG_PID" "$TG_PID_START" worker_dead "$TG_SAMPLES" "$TG_BYTES" "$TG_LAST_SAMPLE" failed "$TG_RESETS" 0 "$TG_DIR" \
            || json_error '500 Internal Server Error' 'cannot persist worker failure'
    fi
    if [ "$AUDIT_LOG_AVAILABLE" -eq 1 ]; then audit_log_event telemetry stop success SESSION_STOP_REQUESTED 0 >/dev/null 2>&1 || true; fi
    json_headers
    printf '{"ok":true,"schema":%s,"session":' "$TELEMETRY_SCHEMA"
    emit_session_json
    printf '}\n'
}

require_token
case "$REQUEST_METHOD:${QUERY_STRING:-}" in
    GET:*action=status*|GET:) emit_status ;;
    GET:*action=history*) emit_history ;;
    GET:*action=export*) json_error '405 Method Not Allowed' 'export requires POST' ;;
    POST:*)
        require_json_post
        read_json_body 1024
        _tg_action=$(printf '%s' "$JSON_BODY" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')
        case "$_tg_action" in
            start) handle_start ;;
            stop) handle_stop ;;
            export) export_session ;;
            *) json_error '400 Bad Request' 'invalid telemetry action' ;;
        esac
        ;;
    *) json_error '405 Method Not Allowed' 'GET or POST only' ;;
esac
