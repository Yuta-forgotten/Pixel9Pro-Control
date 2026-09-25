#!/system/bin/sh
# Low-power telemetry session primitives.  This library is shared by the
# authenticated CGI and the detached worker; it never starts a wakelock or an
# alarm.  All state changes are atomic and scoped to one generated session id.

TELEMETRY_SCHEMA=2
TELEMETRY_ROOT="${PIXEL9PRO_TELEMETRY_ROOT:-${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/.telemetry}"
TELEMETRY_STATE="$TELEMETRY_ROOT/state"
TELEMETRY_SESSIONS="$TELEMETRY_ROOT/sessions"
TELEMETRY_DEFAULT_MAX_BYTES=4194304
TELEMETRY_MAX_BYTES_LIMIT=16777216

telemetry_now() {
    _tl_now=$(date +%s 2>/dev/null || printf '0')
    case "$_tl_now" in ''|*[!0-9]*) _tl_now=0 ;; esac
    printf '%s' "$_tl_now"
}

telemetry_uptime() {
    _tl_up=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)
    case "$_tl_up" in ''|*[!0-9]*) _tl_up=0 ;; esac
    printf '%s' "$_tl_up"
}

telemetry_boot_id() {
    _tl_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \r\n')
    case "$_tl_boot" in
        ''|*[!A-Za-z0-9-]*) _tl_boot=$(getprop ro.boot.bootreason 2>/dev/null | tr -d ' \r\n') ;;
    esac
    [ -n "$_tl_boot" ] || _tl_boot=unknown
    printf '%s' "$_tl_boot" | cut -c1-80
}

telemetry_num() {
    case "$1" in ''|*[!0-9-]*) printf 'null' ;; *) printf '%s' "$1" ;; esac
}

telemetry_json_escape() {
    printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r//g;s/\n/\\n/g'
}

telemetry_sanitize_field() {
    # CSV fields deliberately contain no comma, CR/LF or pipe.  The top
    # process field uses semicolon separators and remains bounded.
    printf '%s' "$1" | tr ',\r\n|' '    ' | tr -cd 'A-Za-z0-9._:+/%; -' | cut -c1-240
}

telemetry_valid_id() {
    case "$1" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac
    return 0
}

telemetry_state_value() {
    _tl_file="$1"
    _tl_key="$2"
    _tl_default="$3"
    _tl_value=$(sed -n "s/^${_tl_key}=//p" "$_tl_file" 2>/dev/null | head -n 1 | tr -d '\r')
    [ -n "$_tl_value" ] && printf '%s' "$_tl_value" || printf '%s' "$_tl_default"
}

telemetry_state_write() {
    _tl_session_id="$1"
    _tl_status="$2"
    _tl_start_ts="$3"
    _tl_end_ts="$4"
    _tl_duration="$5"
    _tl_max_bytes="$6"
    _tl_pid="$7"
    _tl_pid_start="$8"
    _tl_reason="$9"
    _tl_samples="${10}"
    _tl_bytes="${11}"
    _tl_last_sample="${12}"
    _tl_quality="${13}"
    _tl_reset_count="${14}"
    _tl_stop_requested="${15}"
    _tl_session_dir="${16}"
    _tl_boot_id="${17:-}"
    _tl_source="${18:-}"
    _tl_valid_samples="${19:-}"
    _tl_invalid_samples="${20:-}"
    _tl_gap_count="${21:-}"
    _tl_first_sample="${22:-}"
    _tl_interval_on="${23:-}"
    _tl_interval_off="${24:-}"
    _tl_last_screen="${25:-}"
    _tl_last_charge_status="${26:-}"
    _tl_existing_id=$(telemetry_state_value "$TELEMETRY_STATE" session_id "")
    if [ "$_tl_status" = pending ] && [ "$_tl_existing_id" != "$_tl_session_id" ]; then
        _tl_boot_id=$(telemetry_boot_id)
        _tl_source=telemetry_worker
        _tl_valid_samples=0
        _tl_invalid_samples=0
        _tl_gap_count=0
        _tl_first_sample=0
        _tl_last_screen=unknown
        _tl_last_charge_status=unknown
    fi
    [ -n "$_tl_boot_id" ] || _tl_boot_id=$(telemetry_state_value "$TELEMETRY_STATE" boot_id "$(telemetry_boot_id)")
    [ -n "$_tl_source" ] || _tl_source=$(telemetry_state_value "$TELEMETRY_STATE" source telemetry_worker)
    [ -n "$_tl_valid_samples" ] || _tl_valid_samples=$(telemetry_state_value "$TELEMETRY_STATE" valid_samples 0)
    [ -n "$_tl_invalid_samples" ] || _tl_invalid_samples=$(telemetry_state_value "$TELEMETRY_STATE" invalid_samples 0)
    [ -n "$_tl_gap_count" ] || _tl_gap_count=$(telemetry_state_value "$TELEMETRY_STATE" gap_count 0)
    [ -n "$_tl_first_sample" ] || _tl_first_sample=$(telemetry_state_value "$TELEMETRY_STATE" first_sample_ts 0)
    [ -n "$_tl_interval_on" ] || _tl_interval_on=$(telemetry_state_value "$TELEMETRY_STATE" interval_on_sec 60)
    [ -n "$_tl_interval_off" ] || _tl_interval_off=$(telemetry_state_value "$TELEMETRY_STATE" interval_off_sec 600)
    [ -n "$_tl_last_screen" ] || _tl_last_screen=$(telemetry_state_value "$TELEMETRY_STATE" last_screen unknown)
    [ -n "$_tl_last_charge_status" ] || _tl_last_charge_status=$(telemetry_state_value "$TELEMETRY_STATE" last_charge_status unknown)
    _tl_tmp="${TELEMETRY_STATE}.tmp.$$"
    mkdir -p "$TELEMETRY_ROOT" "$TELEMETRY_SESSIONS" 2>/dev/null || return 1
    [ ! -d "$TELEMETRY_STATE" ] || return 1
    {
        printf 'schema=%s\n' "$TELEMETRY_SCHEMA"
        printf 'session_id=%s\nstatus=%s\nstart_ts=%s\nend_ts=%s\n' \
            "$_tl_session_id" "$_tl_status" "$_tl_start_ts" "$_tl_end_ts"
        printf 'duration_sec=%s\nmax_bytes=%s\npid=%s\npid_start_ticks=%s\n' \
            "$_tl_duration" "$_tl_max_bytes" "$_tl_pid" "$_tl_pid_start"
        printf 'reason=%s\nsamples=%s\nbytes=%s\nlast_sample_ts=%s\n' \
            "$(telemetry_sanitize_field "$_tl_reason")" "$_tl_samples" "$_tl_bytes" "$_tl_last_sample"
        printf 'quality=%s\nreset_count=%s\nstop_requested=%s\nsession_dir=%s\n' \
            "$(telemetry_sanitize_field "$_tl_quality")" "$_tl_reset_count" "$_tl_stop_requested" "$_tl_session_dir"
        printf 'boot_id=%s\nsource=%s\nvalid_samples=%s\ninvalid_samples=%s\n' \
            "$(telemetry_sanitize_field "$_tl_boot_id")" "$(telemetry_sanitize_field "$_tl_source")" \
            "$_tl_valid_samples" "$_tl_invalid_samples"
        printf 'gap_count=%s\nfirst_sample_ts=%s\ninterval_on_sec=%s\ninterval_off_sec=%s\n' \
            "$_tl_gap_count" "$_tl_first_sample" "$_tl_interval_on" "$_tl_interval_off"
        printf 'last_screen=%s\nlast_charge_status=%s\n' \
            "$(telemetry_sanitize_field "$_tl_last_screen")" "$(telemetry_sanitize_field "$_tl_last_charge_status")"
    } > "$_tl_tmp" 2>/dev/null \
        && mv "$_tl_tmp" "$TELEMETRY_STATE" 2>/dev/null \
        && [ -f "$TELEMETRY_STATE" ] || {
            rm -f "$_tl_tmp" 2>/dev/null
            return 1
        }
    # Keep an immutable-session-addressed state snapshot so a later WebUI
    # request can inspect an older completed session without relying on the
    # mutable global pointer.  The write remains atomic within that directory.
    if [ -n "$_tl_session_dir" ] && [ -d "$_tl_session_dir" ]; then
        _tl_session_tmp="$_tl_session_dir/state.tmp.$$"
        cp "$TELEMETRY_STATE" "$_tl_session_tmp" 2>/dev/null \
            && mv "$_tl_session_tmp" "$_tl_session_dir/state" 2>/dev/null \
            || rm -f "$_tl_session_tmp" 2>/dev/null
    fi
    [ -f "$TELEMETRY_STATE" ] && return 0
    rm -f "$_tl_tmp" 2>/dev/null
    return 1
}

telemetry_session_dir() {
    _tl_id="$1"
    telemetry_valid_id "$_tl_id" || return 1
    printf '%s/%s' "$TELEMETRY_SESSIONS" "$_tl_id"
}

telemetry_pid_start() {
    _tl_pid="$1"
    case "$_tl_pid" in ''|*[!0-9]*) return 1 ;; esac
    if [ "${PIXEL9PRO_CGI_TEST_MODE:-0}" = 1 ]; then
        printf '%s' "${PIXEL9PRO_TEST_START_TICKS:-1}"
        return 0
    fi
    [ -r "/proc/$_tl_pid/stat" ] || return 1
    sed 's/^.*) //' "/proc/$_tl_pid/stat" 2>/dev/null | awk '{print $20}'
}

telemetry_pid_alive() {
    _tl_pid="$1"
    _tl_start="$2"
    case "$_tl_pid:$_tl_start" in *[!0-9:]*) return 1 ;; esac
    kill -0 "$_tl_pid" 2>/dev/null || return 1
    _tl_live=$(telemetry_pid_start "$_tl_pid")
    [ -n "$_tl_live" ] && [ "$_tl_live" = "$_tl_start" ]
}

telemetry_read_current_id() {
    telemetry_state_value "$TELEMETRY_STATE" session_id ""
}

telemetry_sample_file() {
    _tl_dir="$1"
    printf '%s/samples.csv' "$_tl_dir"
}

telemetry_jsonl_file() {
    _tl_dir="$1"
    printf '%s/samples.jsonl' "$_tl_dir"
}

telemetry_read_battery() {
    TL_STATUS=$(cat /sys/class/power_supply/battery/status 2>/dev/null | tr -d '\r\n' | cut -c1-32)
    TL_LEVEL=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null | tr -d ' \r\n')
    TL_CHARGE=$(cat /sys/class/power_supply/battery/charge_counter 2>/dev/null | tr -d ' \r\n')
    TL_CURRENT=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null | tr -d ' \r\n')
    [ -n "$TL_CURRENT" ] || TL_CURRENT=$(cat /sys/class/power_supply/battery/current_avg 2>/dev/null | tr -d ' \r\n')
    TL_VOLTAGE=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null | tr -d ' \r\n')
    [ -n "$TL_VOLTAGE" ] || TL_VOLTAGE=$(cat /sys/class/power_supply/battery/voltage_ocv 2>/dev/null | tr -d ' \r\n')
    case "$TL_LEVEL" in ''|*[!0-9]*) TL_LEVEL="" ;; esac
    case "$TL_CHARGE" in ''|*[!0-9-]*) TL_CHARGE="" ;; esac
    case "$TL_CURRENT" in ''|*[!0-9-]*) TL_CURRENT="" ;; esac
    case "$TL_VOLTAGE" in ''|*[!0-9-]*) TL_VOLTAGE="" ;; esac
    [ -n "$TL_STATUS" ] || TL_STATUS=Unknown
}

telemetry_read_screen() {
    TL_SCREEN=unknown
    _tl_display="$TELEMETRY_ROOT/../scripts/display_state_lib.sh"
    [ -r "$_tl_display" ] && . "$_tl_display" 2>/dev/null
    if command -v display_state_read >/dev/null 2>&1; then
        display_state_read >/dev/null 2>&1 || true
        TL_SCREEN=$(display_state_legacy_screen 2>/dev/null)
    fi
    case "$TL_SCREEN" in on|off) ;; *) TL_SCREEN=unknown ;; esac
}

telemetry_read_odpm() {
    TL_ODPM_MODEM=$(cat /sys/bus/iio/devices/iio:device0/energy_value 2>/dev/null \
        | sed -n 's/.*VSYS_PWR_MODEM\], *\([0-9][0-9]*\).*/\1/p' | head -n 1)
    TL_ODPM_RFFE=$(cat /sys/bus/iio/devices/iio:device1/energy_value 2>/dev/null \
        | sed -n 's/.*VSYS_PWR_RFFE\], *\([0-9][0-9]*\).*/\1/p' | head -n 1)
    case "$TL_ODPM_MODEM" in ''|*[!0-9]*) TL_ODPM_MODEM="" ;; esac
    case "$TL_ODPM_RFFE" in ''|*[!0-9]*) TL_ODPM_RFFE="" ;; esac
}

telemetry_read_thermal() {
    TL_SKIN=""; TL_BATTERY=""; TL_SOC=""; TL_CHARGING=""; TL_SPEAKER=""
    _tl_cache="${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_thermal_cache.sh"
    if [ -r "$_tl_cache" ]; then
        . "$_tl_cache" 2>/dev/null
        TL_JSON=$(build_thermal_json 2>/dev/null)
    else
        TL_JSON='[]'
    fi
    telemetry_extract_temp() {
        _tl_zone="$1"
        printf '%s' "$TL_JSON" | sed -n "s/.*\"zone\":\"${_tl_zone}\",\"temp\":\([-0-9][0-9]*\).*/\1/p" | head -n 1
    }
    TL_SKIN=$(telemetry_extract_temp VIRTUAL-SKIN)
    TL_BATTERY=$(telemetry_extract_temp battery)
    TL_SOC=$(telemetry_extract_temp soc_therm)
    TL_CHARGING=$(telemetry_extract_temp charging_therm)
    TL_SPEAKER=$(telemetry_extract_temp btmspkr_therm)
    TL_THERMAL_STATUS=$(dumpsys thermalservice 2>/dev/null \
        | sed -n 's/.*Thermal Status:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1 | tr -d ' \r\n')
    case "$TL_THERMAL_STATUS" in ''|*[!0-9]*) TL_THERMAL_STATUS="" ;; esac
}

telemetry_collect_top() {
    # Only PID/name/CPU/MEM are retained.  cmdline/arguments and paths are
    # intentionally excluded from the capture contract.
    TL_TOP=$(ps -A -o PID,NAME,CPU,MEM 2>/dev/null | sed -n '2,6p' \
        | awk '{ if ($1 ~ /^[0-9]+$/) { name=$2; gsub(/[,|;]/,"",name); printf "%s:%s:%s:%s;",$1,name,$3,$4 } }' \
        | cut -c1-720)
    TL_TOP=$(telemetry_sanitize_field "$TL_TOP")
}

telemetry_capture_batterystats() {
    _tl_dir="$1"
    _tl_name="$2"
    case "$_tl_name" in start|end) ;; *) return 1 ;; esac
    # Keep only aggregate/UID estimate lines; raw dumpsys/logcat and command
    # arguments never enter a telemetry export.
    dumpsys batterystats 2>/dev/null | awk '
        /Estimated power use/ || /^  UID / || /Screen off discharge:/ || /Screen on discharge:/ { print }
    ' | head -n 80 > "$_tl_dir/batterystats_${_tl_name}.txt" 2>/dev/null
    [ -f "$_tl_dir/batterystats_${_tl_name}.txt" ] || return 1
    chmod 600 "$_tl_dir/batterystats_${_tl_name}.txt" 2>/dev/null
}
