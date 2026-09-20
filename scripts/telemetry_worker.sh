#!/system/bin/sh
# Detached low-power telemetry recorder.  The worker deliberately uses sleep
# only: no wakelock, alarm, foreground service, or changes to the main worker.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/scripts/telemetry_lib.sh" \
    || exit 1

_tw_id="$1"
_tw_dir="$2"
_tw_duration="$3"
_tw_max_bytes="$4"
telemetry_valid_id "$_tw_id" || exit 2
[ -d "$_tw_dir" ] || exit 2
case "$_tw_duration" in ''|*[!0-9]*) _tw_duration=0 ;; esac
case "$_tw_max_bytes" in ''|*[!0-9]*) _tw_max_bytes=4194304 ;; esac

_tw_finalized=0
_tw_samples=0
_tw_bytes=0
_tw_last_sample=0
_tw_quality=complete
_tw_reset_count=0
_tw_prev_charge=""

telemetry_worker_update() {
    _tw_status="$1"
    _tw_end="$2"
    _tw_reason="$3"
    _tw_stop=$(telemetry_state_value "$TELEMETRY_STATE" stop_requested 0)
    _tw_start_ts=$(telemetry_state_value "$TELEMETRY_STATE" start_ts 0)
    _tw_pid=$(telemetry_state_value "$TELEMETRY_STATE" pid "$$")
    _tw_pid_start=$(telemetry_state_value "$TELEMETRY_STATE" pid_start_ticks "")
    _tw_duration_state=$(telemetry_state_value "$TELEMETRY_STATE" duration_sec "$_tw_duration")
    _tw_max_state=$(telemetry_state_value "$TELEMETRY_STATE" max_bytes "$_tw_max_bytes")
    telemetry_state_write "$_tw_id" "$_tw_status" "$_tw_start_ts" "$_tw_end" \
        "$_tw_duration_state" "$_tw_max_state" "$_tw_pid" "$_tw_pid_start" \
        "$_tw_reason" "$_tw_samples" "$_tw_bytes" "$_tw_last_sample" \
        "$_tw_quality" "$_tw_reset_count" "$_tw_stop" "$_tw_dir"
}

telemetry_worker_finish() {
    [ "$_tw_finalized" -eq 1 ] && return 0
    _tw_finalized=1
    _tw_now=$(telemetry_now)
    telemetry_capture_batterystats "$_tw_dir" end >/dev/null 2>&1 || true
    telemetry_worker_update "$1" "$_tw_now" "$2" || true
}

telemetry_worker_signal() {
    _tw_current=$(telemetry_state_value "$TELEMETRY_STATE" session_id "")
    [ "$_tw_current" = "$_tw_id" ] || { _tw_finalized=1; exit 0; }
    _tw_status=$(telemetry_state_value "$TELEMETRY_STATE" status running)
    case "$_tw_status" in
        stopping) telemetry_worker_finish stopped user_stop ;;
        running) telemetry_worker_finish stopped signal ;;
        *) _tw_finalized=1 ;;
    esac
    exit 0
}
trap 'telemetry_worker_signal' INT TERM HUP

_tw_current=$(telemetry_state_value "$TELEMETRY_STATE" session_id "")
[ "$_tw_current" = "$_tw_id" ] || exit 3
_tw_status=$(telemetry_state_value "$TELEMETRY_STATE" status pending)
[ "$_tw_status" = pending ] && sleep 1 && _tw_status=$(telemetry_state_value "$TELEMETRY_STATE" status pending)
[ "$_tw_status" = running ] || exit 3

_tw_csv=$(telemetry_sample_file "$_tw_dir")
_tw_jsonl=$(telemetry_jsonl_file "$_tw_dir")
[ ! -e "$_tw_csv" ] || exit 4
{
    printf 'ts,screen,charge_status,level_pct,charge_uah,current_ua,voltage_uv,virtual_skin_mc,battery_mc,soc_mc,charging_therm_mc,btmspkr_therm_mc,thermal_status,odpm_modem_uws,odpm_rffe_uws,sample_quality,top_processes\n'
} > "$_tw_csv" 2>/dev/null || exit 4
: > "$_tw_jsonl" 2>/dev/null || exit 4
chmod 600 "$_tw_csv" "$_tw_jsonl" 2>/dev/null
telemetry_capture_batterystats "$_tw_dir" start >/dev/null 2>&1 || true
telemetry_worker_update running 0 started || exit 4

while :; do
    _tw_current=$(telemetry_state_value "$TELEMETRY_STATE" session_id "")
    [ "$_tw_current" = "$_tw_id" ] || { _tw_finalized=1; exit 0; }
    _tw_state=$(telemetry_state_value "$TELEMETRY_STATE" status running)
    _tw_stop=$(telemetry_state_value "$TELEMETRY_STATE" stop_requested 0)
    case "$_tw_state:$_tw_stop" in
        stopping:*|*:1) telemetry_worker_finish stopped user_stop; break ;;
        failed:*|completed:*) _tw_finalized=1; exit 0 ;;
    esac

    _tw_now=$(telemetry_now)
    _tw_start_ts=$(telemetry_state_value "$TELEMETRY_STATE" start_ts "$_tw_now")
    case "$_tw_start_ts" in ''|*[!0-9]*) _tw_start_ts="$_tw_now" ;; esac
    if [ "$_tw_duration" -gt 0 ] 2>/dev/null && [ $((_tw_now - _tw_start_ts)) -ge "$_tw_duration" ] 2>/dev/null; then
        telemetry_worker_finish completed duration_elapsed
        break
    fi

    telemetry_read_screen
    telemetry_read_battery
    telemetry_read_thermal
    telemetry_read_odpm
    telemetry_collect_top

    _tw_sample_quality=ok
    if [ -z "$TL_CHARGE" ]; then
        _tw_sample_quality=missing_charge_counter
        _tw_quality=partial
    elif [ -n "$_tw_prev_charge" ]; then
        _tw_delta=$((TL_CHARGE - _tw_prev_charge))
        _tw_abs=$_tw_delta
        [ "$_tw_abs" -ge 0 ] 2>/dev/null || _tw_abs=$((-_tw_abs))
        if [ "$_tw_abs" -gt 2000000 ] 2>/dev/null; then
            _tw_sample_quality=counter_reset
            _tw_quality=reset_or_mismatch
            _tw_reset_count=$((_tw_reset_count + 1))
        fi
    fi
    [ -n "$TL_CHARGE" ] && _tw_prev_charge="$TL_CHARGE"

    _tw_screen=$(telemetry_sanitize_field "$TL_SCREEN")
    _tw_status_value=$(telemetry_sanitize_field "$TL_STATUS")
    _tw_top=$(telemetry_sanitize_field "$TL_TOP")
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$_tw_now" "$_tw_screen" "$_tw_status_value" "$(telemetry_num "$TL_LEVEL" | sed 's/null//')" \
        "$(telemetry_num "$TL_CHARGE" | sed 's/null//')" "$(telemetry_num "$TL_CURRENT" | sed 's/null//')" \
        "$(telemetry_num "$TL_VOLTAGE" | sed 's/null//')" "$(telemetry_num "$TL_SKIN" | sed 's/null//')" \
        "$(telemetry_num "$TL_BATTERY" | sed 's/null//')" "$(telemetry_num "$TL_SOC" | sed 's/null//')" \
        "$(telemetry_num "$TL_CHARGING" | sed 's/null//')" "$(telemetry_num "$TL_SPEAKER" | sed 's/null//')" \
        "$(telemetry_num "$TL_THERMAL_STATUS" | sed 's/null//')" "$(telemetry_num "$TL_ODPM_MODEM" | sed 's/null//')" \
        "$(telemetry_num "$TL_ODPM_RFFE" | sed 's/null//')" "$_tw_sample_quality" "$_tw_top" \
        >> "$_tw_csv" 2>/dev/null || { telemetry_worker_finish failed write_csv; break; }

    _tw_json_screen=$(telemetry_json_escape "$_tw_screen")
    _tw_json_status=$(telemetry_json_escape "$_tw_status_value")
    _tw_json_quality=$(telemetry_json_escape "$_tw_sample_quality")
    _tw_json_top=$(telemetry_json_escape "$_tw_top")
    {
        printf '{"ts":%s,"screen":"%s","charge_status":"%s","level_pct":%s,"charge_uah":%s,"current_ua":%s,"voltage_uv":%s,' \
            "$_tw_now" "$_tw_json_screen" "$_tw_json_status" "$(telemetry_num "$TL_LEVEL")" \
            "$(telemetry_num "$TL_CHARGE")" "$(telemetry_num "$TL_CURRENT")" "$(telemetry_num "$TL_VOLTAGE")"
        printf '"virtual_skin_mc":%s,"battery_mc":%s,"soc_mc":%s,"charging_therm_mc":%s,"btmspkr_therm_mc":%s,"thermal_status":%s,' \
            "$(telemetry_num "$TL_SKIN")" "$(telemetry_num "$TL_BATTERY")" "$(telemetry_num "$TL_SOC")" \
            "$(telemetry_num "$TL_CHARGING")" "$(telemetry_num "$TL_SPEAKER")" "$(telemetry_num "$TL_THERMAL_STATUS")"
        printf '"odpm_modem_uws":%s,"odpm_rffe_uws":%s,"sample_quality":"%s","top_processes":"%s"}\n' \
            "$(telemetry_num "$TL_ODPM_MODEM")" "$(telemetry_num "$TL_ODPM_RFFE")" "$_tw_json_quality" "$_tw_json_top"
    } >> "$_tw_jsonl" 2>/dev/null || { telemetry_worker_finish failed write_json; break; }

    _tw_previous_last_sample="$_tw_last_sample"
    _tw_samples=$((_tw_samples + 1))
    _tw_last_sample="$_tw_now"
    _tw_bytes=$(wc -c < "$_tw_csv" 2>/dev/null | tr -d ' \r\n')
    _tw_json_bytes=$(wc -c < "$_tw_jsonl" 2>/dev/null | tr -d ' \r\n')
    case "$_tw_bytes:$_tw_json_bytes" in *[!0-9:]*) _tw_bytes=0 ;; *) _tw_bytes=$((_tw_bytes + _tw_json_bytes)) ;; esac
    if [ "$_tw_bytes" -ge "$_tw_max_bytes" ] 2>/dev/null; then
        # Keep the configured bound hard: discard the sample that crossed it,
        # then commit a terminal max_bytes state with the last valid count.
        _tw_trim_csv="${_tw_csv}.trim.$$"
        _tw_trim_json="${_tw_jsonl}.trim.$$"
        if sed '$d' "$_tw_csv" > "$_tw_trim_csv" 2>/dev/null \
            && sed '$d' "$_tw_jsonl" > "$_tw_trim_json" 2>/dev/null \
            && mv "$_tw_trim_csv" "$_tw_csv" 2>/dev/null \
            && mv "$_tw_trim_json" "$_tw_jsonl" 2>/dev/null; then
            _tw_samples=$((_tw_samples - 1))
            [ "$_tw_samples" -ge 0 ] 2>/dev/null || _tw_samples=0
            _tw_last_sample="$_tw_previous_last_sample"
            _tw_bytes=$(wc -c < "$_tw_csv" 2>/dev/null | tr -d ' \r\n')
            _tw_json_bytes=$(wc -c < "$_tw_jsonl" 2>/dev/null | tr -d ' \r\n')
            case "$_tw_bytes:$_tw_json_bytes" in *[!0-9:]*) _tw_bytes=0 ;; *) _tw_bytes=$((_tw_bytes + _tw_json_bytes)) ;; esac
        else
            rm -f "$_tw_trim_csv" "$_tw_trim_json" 2>/dev/null
        fi
        telemetry_worker_finish completed max_bytes
        break
    fi
    telemetry_worker_update running 0 sample || { telemetry_worker_finish failed state_write; break; }

    _tw_interval=600
    [ "$_tw_screen" = on ] && _tw_interval=60
    sleep "$_tw_interval"
done

exit 0
