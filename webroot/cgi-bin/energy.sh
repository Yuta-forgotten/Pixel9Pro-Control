#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/energy.sh
# GET → 解析 dumpsys batterystats + 模块低频电池采样
# 返回三层统计口径:
#   1. 当前放电会话 (模块定义, 默认口径)
#   2. 今日累计 (模块低频历史)
#   3. Android batterystats 窗口 (系统分项 / Top 应用来源)
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback
[ "$REQUEST_METHOD" = "GET" ] || json_error '405 Method Not Allowed' 'GET only'
json_headers

POWER_HISTORY="$MODDIR/.power_history"
THERMAL_HISTORY="$MODDIR/.thermal_history"
POWER_SESSION_FILE="$MODDIR/.power_session"
SYSTEM_CACHE="$MODDIR/.energy_system_cache.json"
SYSTEM_CACHE_TS="$MODDIR/.energy_system_cache.ts"
SYSTEM_CACHE_TTL=45
SYSTEM_CACHE_STALE_MAX=600
POWER_WINDOW_BASELINE_MAX_GAP=900
RESET_RULE='连续充电 >= 10 分钟且电量回升，或充满后重新拔线后，重置为新的放电会话'
BATTERYSTATS_NOTE='系统分项和应用排行来自 Android batterystats 当前窗口；若系统或用户执行过 batterystats reset，这个窗口可能比放电会话更短。'
RADIO_MODEL_NOTE='Pixel/Exynos 5400 的 Android mobile_radio 是模型估算；绝对 mAh 不作为硬件电表，只能看相对方向。'

mkdir -p "$LOCKDIR_BASE/tmp" 2>/dev/null || true
chmod 700 "$LOCKDIR_BASE/tmp" 2>/dev/null || true
_tmp="$LOCKDIR_BASE/tmp/energy_$$"
trap 'rm -f "${_tmp}"_*' EXIT

json_num_or_null() {
    case "$1" in
        ''|null) printf 'null' ;;
        *[!0-9.-]*) printf 'null' ;;
        *) printf '%s' "$1" ;;
    esac
}

json_str_or_null() {
    if [ -n "$1" ]; then
        printf '"%s"' "$(json_escape "$1")"
    else
        printf 'null'
    fi
}

json_bool() {
    case "$1" in
        1|true|TRUE|yes|on) printf 'true' ;;
        *) printf 'false' ;;
    esac
}

read_battery_value() {
    tr -d ' \n\r' < "$1" 2>/dev/null
}

detect_external_power() {
    _external_power_online=0
    _power_source="battery"
    for _ps in usb wireless dc mains ac; do
        _online=$(cat "/sys/class/power_supply/${_ps}/online" 2>/dev/null | tr -d ' \n\r\t')
        if [ "$_online" = "1" ]; then
            _external_power_online=1
            case "$_ps" in
                usb) _power_source="usb" ;;
                wireless) _power_source="wireless" ;;
                *) _power_source="$_ps" ;;
            esac
            break
        fi
    done
}

read_state_value() {
    _state_file="$1"
    _state_key="$2"
    sed -n "s/^${_state_key}=//p" "$_state_file" 2>/dev/null | head -n 1 | tr -d '\r'
}

read_system_cache_if_fresh() {
    _cache_now="$1"
    [ -s "$SYSTEM_CACHE" ] || return 1
    _cache_ts=$(cat "$SYSTEM_CACHE_TS" 2>/dev/null | tr -d ' \n\r')
    case "$_cache_ts" in
        ''|*[!0-9]*) return 1 ;;
    esac
    _cache_age=$((_cache_now - _cache_ts))
    [ "$_cache_age" -lt 0 ] && _cache_age=999999
    [ "$_cache_age" -le "$SYSTEM_CACHE_TTL" ] || return 1
    cat "$SYSTEM_CACHE"
    return 0
}

read_system_cache_if_usable() {
    _cache_now="$1"
    [ -s "$SYSTEM_CACHE" ] || return 1
    _cache_ts=$(cat "$SYSTEM_CACHE_TS" 2>/dev/null | tr -d ' \n\r')
    case "$_cache_ts" in
        ''|*[!0-9]*) return 1 ;;
    esac
    _cache_age=$((_cache_now - _cache_ts))
    [ "$_cache_age" -lt 0 ] && _cache_age=999999
    [ "$_cache_age" -le "$SYSTEM_CACHE_STALE_MAX" ] || return 1
    cat "$SYSTEM_CACHE"
    return 0
}

write_system_cache() {
    _payload="$1"
    _cache_now="$2"
    printf '%s\n' "$_payload" > "${SYSTEM_CACHE}.tmp"
    mv "${SYSTEM_CACHE}.tmp" "$SYSTEM_CACHE"
    printf '%s\n' "$_cache_now" > "${SYSTEM_CACHE_TS}.tmp"
    mv "${SYSTEM_CACHE_TS}.tmp" "$SYSTEM_CACHE_TS"
}

build_power_window_json() {
    _mins="$1"
    _start=$((_now - _mins * 60))
    if [ -s "$POWER_HISTORY" ]; then
        awk -F, -v minutes="$_mins" -v start="$_start" -v now="$_now" \
            -v cur_level="${_cur_level:-}" -v cur_charge="${_cur_charge:-0}" \
            -v cur_status="${_cur_status:-}" -v cur_external="${_external_power_online:-0}" \
            -v baseline_max_gap="$POWER_WINDOW_BASELINE_MAX_GAP" '
        function observe_status(value) {
            if (value == "Charging" || value == "Full" || value == "Not charging") saw_charging_like = 1
            if (value == "Discharging") saw_discharging = 1
        }
        function add_charge_delta(from_charge, to_charge, delta) {
            delta = from_charge - to_charge
            if (delta > 0) {
                discharge += delta / 1000
                has_discharge = 1
            } else if (delta < 0) {
                charge_in += (-delta) / 1000
                has_charge = 1
            }
        }
        BEGIN {
            seen = 0
            samples = 0
            effective_samples = 0
            discharge = 0
            charge_in = 0
            has_discharge = 0
            has_charge = 0
            status_changes = 0
            saw_charging_like = 0
            saw_discharging = 0
            baseline_available = 0
            baseline_used = 0
            endpoint_included = 0
            cur_level_valid = (cur_level ~ /^-?[0-9]+$/)
            cur_charge_valid = (cur_charge ~ /^-?[0-9]+$/ && cur_charge + 0 > 0)
            prev_charge_valid = 0
            expected_elapsed = minutes * 60
        }
        $1 ~ /^[0-9]+$/ && $1 + 0 < start {
            baseline_available = 1
            baseline_ts = $1 + 0
            baseline_level = $2 + 0
            baseline_charge = $3 + 0
            baseline_status = $4
            baseline_charge_valid = ($3 ~ /^-?[0-9]+$/ && baseline_charge > 0)
            next
        }
        $1 ~ /^[0-9]+$/ && $1 + 0 >= start && $1 + 0 <= now {
            ts = $1 + 0
            level = $2 + 0
            charge = $3 + 0
            status = $4
            charge_valid = ($3 ~ /^-?[0-9]+$/ && charge > 0)
            if (!seen) {
                seen = 1
                first_ts = ts
                first_level = level
                first_status = status
                coverage_start_ts = ts
                level_start = level
                last_status = status
                last_ts = ts
                last_level = level
                observe_status(status)

                if (baseline_available && baseline_charge_valid && charge_valid &&
                    baseline_ts < start && ts > baseline_ts &&
                    (ts - baseline_ts) <= baseline_max_gap) {
                    fraction = (start - baseline_ts) / (ts - baseline_ts)
                    if (fraction < 0) fraction = 0
                    if (fraction > 1) fraction = 1
                    start_charge = baseline_charge + (charge - baseline_charge) * fraction
                    coverage_start_ts = start
                    level_start = baseline_level
                    baseline_used = 1
                    observe_status(baseline_status)
                    if (baseline_status != "" && status != "" && baseline_status != status) status_changes++
                    add_charge_delta(start_charge, charge)
                    prev_charge = charge
                    prev_charge_valid = 1
                } else if (charge_valid) {
                    prev_charge = charge
                    prev_charge_valid = 1
                } else {
                    prev_charge_valid = 0
                }
            } else {
                if (charge_valid && prev_charge_valid) add_charge_delta(prev_charge, charge)
                if (charge_valid) {
                    prev_charge = charge
                    prev_charge_valid = 1
                } else {
                    prev_charge_valid = 0
                }
                if (status != "" && last_status != "" && status != last_status) status_changes++
                if (status != "") last_status = status
                observe_status(status)
                last_ts = ts
                last_level = level
            }
            samples++
        }
        END {
            if (!seen) {
                if (baseline_available && baseline_charge_valid && cur_charge_valid &&
                    baseline_ts < start && now > baseline_ts &&
                    (now - baseline_ts) <= baseline_max_gap) {
                    fraction = (start - baseline_ts) / (now - baseline_ts)
                    if (fraction < 0) fraction = 0
                    if (fraction > 1) fraction = 1
                    start_charge = baseline_charge + (cur_charge - baseline_charge) * fraction
                    seen = 1
                    first_ts = 0
                    first_level = baseline_level
                    first_status = baseline_status
                    level_start = baseline_level
                    coverage_start_ts = start
                    last_ts = now
                    last_level = cur_level_valid ? cur_level + 0 : baseline_level
                    last_status = cur_status
                    baseline_used = 1
                    endpoint_included = 1
                    observe_status(baseline_status)
                    observe_status(cur_status)
                    if (baseline_status != "" && cur_status != "" && baseline_status != cur_status) status_changes++
                    add_charge_delta(start_charge, cur_charge)
                } else {
                    printf "{\"minutes\":%s,\"start_ts\":%s,\"window_start_ts\":null,\"first_sample_ts\":null,\"baseline_ts\":", minutes, start
                    if (baseline_available) printf "%s", baseline_ts
                    else printf "null"
                    printf ",\"baseline_available\":%s,\"baseline_used\":false,\"endpoint_included\":false,\"expected_elapsed_sec\":%s,\"coverage_elapsed_sec\":0,\"coverage_ratio\":0,\"coverage_quality\":\"no_coverage\",\"elapsed_sec\":0,\"samples\":0,\"effective_samples\":0,\"level_start\":null,\"level_now\":", baseline_available ? "true" : "false", expected_elapsed
                    if (cur_level_valid) printf "%s", cur_level
                    else printf "null"
                    printf ",\"net_level_delta\":null,\"discharge_mah\":null,\"charge_mah\":null,\"net_discharge_mah\":null,\"avg_discharge_mah_per_h\":null,\"avg_discharge_mw\":null,\"trusted_for_average\":false,\"status_start\":null,\"status_last\":null,\"status_changes\":0,\"quality\":\"no_data\",\"source\":\"module_power_history\"}"
                    exit
                }
            }

            if (!endpoint_included && cur_charge_valid && prev_charge_valid && now > last_ts) {
                add_charge_delta(prev_charge, cur_charge)
                endpoint_included = 1
                observe_status(cur_status)
                if (cur_status != "" && last_status != "" && cur_status != last_status) status_changes++
                if (cur_status != "") last_status = cur_status
            }

            level_now = cur_level_valid ? cur_level + 0 : last_level
            net_delta = level_now - level_start
            coverage_elapsed = now - coverage_start_ts
            if (coverage_elapsed < 0) coverage_elapsed = 0
            if (coverage_elapsed > expected_elapsed) coverage_elapsed = expected_elapsed
            coverage_ratio = expected_elapsed > 0 ? coverage_elapsed / expected_elapsed : 0
            effective_samples = samples + baseline_used + endpoint_included
            net_discharge = discharge - charge_in
            coverage_quality = coverage_ratio >= 0.95 ? "complete_window" : (coverage_ratio >= 0.80 ? "usable_window" : "partial_window")
            quality = "pure_discharge"
            if (effective_samples < 2) quality = "insufficient_samples"
            else if (has_charge || status_changes > 0 || (saw_charging_like && saw_discharging)) quality = "mixed_charge_discharge"
            else if (cur_external + 0 == 1 || cur_status == "Charging" || cur_status == "Full") quality = "charging_endpoint"
            else if (coverage_ratio < 0.80) quality = "partial_window"
            else if (!has_discharge) quality = "no_discharge_delta"
            trusted = (quality == "pure_discharge")

            printf "{\"minutes\":%s,\"start_ts\":%s,\"window_start_ts\":%s,\"first_sample_ts\":", minutes, start, coverage_start_ts
            if (first_ts > 0) printf "%s", first_ts
            else printf "null"
            printf ",\"baseline_ts\":"
            if (baseline_available) printf "%s", baseline_ts
            else printf "null"
            printf ",\"baseline_available\":%s,\"baseline_used\":%s,\"endpoint_included\":%s,\"expected_elapsed_sec\":%s,\"coverage_elapsed_sec\":%s,\"coverage_ratio\":%.3f,\"coverage_quality\":\"%s\",\"elapsed_sec\":%s,\"samples\":%s,\"effective_samples\":%s,\"level_start\":%s,\"level_now\":%s,\"net_level_delta\":%s,\"discharge_mah\":", baseline_available ? "true" : "false", baseline_used ? "true" : "false", endpoint_included ? "true" : "false", expected_elapsed, coverage_elapsed, coverage_ratio, coverage_quality, coverage_elapsed, samples, effective_samples, level_start, level_now, net_delta
            if (has_discharge) printf "%.1f", discharge
            else printf "null"
            printf ",\"charge_mah\":"
            if (has_charge) printf "%.1f", charge_in
            else printf "null"
            printf ",\"net_discharge_mah\":"
            if (has_discharge || has_charge) printf "%.1f", net_discharge
            else printf "null"
            printf ",\"avg_discharge_mah_per_h\":"
            if (has_discharge && coverage_elapsed > 0) printf "%.1f", discharge * 3600 / coverage_elapsed
            else printf "null"
            printf ",\"avg_discharge_mw\":"
            if (has_discharge && coverage_elapsed > 0) printf "%.0f", discharge * 3600 / coverage_elapsed * 3.87
            else printf "null"
            gsub(/"/, "\\\"", first_status)
            gsub(/"/, "\\\"", last_status)
            printf ",\"trusted_for_average\":%s,\"status_start\":\"%s\",\"status_last\":\"%s\",\"status_changes\":%s,\"quality\":\"%s\",\"source\":\"module_power_history\"}", trusted ? "true" : "false", first_status, last_status, status_changes, quality
        }
        ' "$POWER_HISTORY"
    else
        printf '{"minutes":%s,"start_ts":%s,"window_start_ts":null,"first_sample_ts":null,"baseline_ts":null,"baseline_available":false,"baseline_used":false,"endpoint_included":false,"expected_elapsed_sec":%s,"coverage_elapsed_sec":0,"coverage_ratio":0,"coverage_quality":"no_coverage","elapsed_sec":0,"samples":0,"effective_samples":0,"level_start":null,"level_now":%s,"net_level_delta":null,"discharge_mah":null,"charge_mah":null,"net_discharge_mah":null,"avg_discharge_mah_per_h":null,"avg_discharge_mw":null,"trusted_for_average":false,"status_start":null,"status_last":null,"status_changes":0,"quality":"no_data","source":"module_power_history"}' \
            "$(json_num_or_null "$_mins")" \
            "$(json_num_or_null "$_start")" \
            "$(json_num_or_null "$((_mins * 60))")" \
            "$(json_num_or_null "$_cur_level")"
    fi
}

build_thermal_window_json() {
    _mins="$1"
    _start=$((_now - _mins * 60))
    if [ -s "$THERMAL_HISTORY" ]; then
        awk -F, -v minutes="$_mins" -v start="$_start" -v now="$_now" '
        BEGIN { seen = 0; samples = 0; sum = 0 }
        $1 + 0 >= start && $2 + 0 > 0 {
            ts = $1 + 0
            temp = ($2 + 0) / 1000
            if (!seen) {
                seen = 1
                first_ts = ts
                min = temp
                max = temp
            }
            if (temp < min) min = temp
            if (temp > max) max = temp
            sum += temp
            last_ts = ts
            samples++
        }
        END {
            if (!seen) {
                printf "{\"minutes\":%s,\"start_ts\":%s,\"window_start_ts\":null,\"elapsed_sec\":0,\"samples\":0,\"temp_min_c\":null,\"temp_avg_c\":null,\"temp_max_c\":null,\"source\":\"module_thermal_history\"}", minutes, start
                exit
            }
            elapsed = now - first_ts
            if (elapsed < 0) elapsed = 0
            printf "{\"minutes\":%s,\"start_ts\":%s,\"window_start_ts\":%s,\"elapsed_sec\":%s,\"samples\":%s,\"temp_min_c\":%.1f,\"temp_avg_c\":%.1f,\"temp_max_c\":%.1f,\"source\":\"module_thermal_history\"}", minutes, start, first_ts, elapsed, samples, min, sum / samples, max
        }
        ' "$THERMAL_HISTORY"
    else
        printf '{"minutes":%s,"start_ts":%s,"window_start_ts":null,"elapsed_sec":0,"samples":0,"temp_min_c":null,"temp_avg_c":null,"temp_max_c":null,"source":"module_thermal_history"}' \
            "$(json_num_or_null "$_mins")" \
            "$(json_num_or_null "$_start")"
    fi
}

try_acquire_energy_lock() {
    _lock="$1"
    _lock_now="$2"
    _lock_max_age=180
    mkdir -p "$LOCKDIR_BASE" 2>/dev/null
    if mkdir "$_lock" 2>/dev/null; then
        echo "$$" > "$_lock/pid" 2>/dev/null
        echo "$_lock_now" > "$_lock/ts" 2>/dev/null
        return 0
    fi

    _lock_pid=$(cat "$_lock/pid" 2>/dev/null)
    _lock_ts=$(cat "$_lock/ts" 2>/dev/null | tr -d ' \n\r\t')
    _lock_stale=0
    if [ -z "$_lock_pid" ]; then
        _lock_stale=1
    elif ! kill -0 "$_lock_pid" 2>/dev/null; then
        _lock_stale=1
    else
        case "$_lock_ts" in
            ''|*[!0-9]*) ;;
            *)
                _lock_age=$((_lock_now - _lock_ts))
                [ "$_lock_age" -gt "$_lock_max_age" ] 2>/dev/null && _lock_stale=1
                ;;
        esac
    fi

    if [ "$_lock_stale" -eq 1 ]; then
        rm -f "$_lock/pid" "$_lock/ts" 2>/dev/null
        rmdir "$_lock" 2>/dev/null
        if mkdir "$_lock" 2>/dev/null; then
            echo "$$" > "$_lock/pid" 2>/dev/null
            echo "$_lock_now" > "$_lock/ts" 2>/dev/null
            return 0
        fi
    fi
    return 1
}

release_energy_lock() {
    _lock="$1"
    rm -f "$_lock/pid" "$_lock/ts" 2>/dev/null
    rmdir "$_lock" 2>/dev/null
}

_now=$(date +%s 2>/dev/null || echo 0)
_fast=0
case "$QUERY_STRING" in *fast=1*) _fast=1 ;; esac

_cur_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null | tr -d '\r')
_cur_status=$(printf '%s' "$_cur_status" | sed 's/[[:space:]]*$//')
[ -n "$_cur_status" ] || _cur_status="Unknown"
_cur_level=$(read_battery_value /sys/class/power_supply/battery/capacity)
_cur_charge=$(read_battery_value /sys/class/power_supply/battery/charge_counter)
detect_external_power
_is_charging_like=0
case "$_cur_status" in
    Charging|Full) _is_charging_like=1 ;;
    Not\ charging) [ "$_external_power_online" -eq 1 ] && _is_charging_like=1 ;;
esac

case "$_cur_level" in
    ''|*[!0-9-]*) _cur_level='' ;;
esac
case "$_cur_charge" in
    ''|*[!0-9-]*) _cur_charge=0 ;;
esac

_scope_start=$_now
_scope_level_start=${_cur_level:-0}
_scope_charge_start=$_cur_charge
_scope_reason='boot_init'

_odpm_modem_base=0
_odpm_rffe_base=0

if [ -s "$POWER_SESSION_FILE" ]; then
    start_ts=$(read_state_value "$POWER_SESSION_FILE" start_ts)
    start_level=$(read_state_value "$POWER_SESSION_FILE" start_level)
    start_charge_uah=$(read_state_value "$POWER_SESSION_FILE" start_charge_uah)
    reset_reason=$(read_state_value "$POWER_SESSION_FILE" reset_reason)
    odpm_modem_uws=$(read_state_value "$POWER_SESSION_FILE" odpm_modem_uws)
    odpm_rffe_uws=$(read_state_value "$POWER_SESSION_FILE" odpm_rffe_uws)
    case "$start_ts" in
        ''|*[!0-9]*) ;;
        *) _scope_start=$start_ts ;;
    esac
    case "$start_level" in
        ''|*[!0-9-]*) ;;
        *) _scope_level_start=$start_level ;;
    esac
    case "$start_charge_uah" in
        ''|*[!0-9-]*) ;;
        *) _scope_charge_start=$start_charge_uah ;;
    esac
    [ -n "$reset_reason" ] && _scope_reason=$reset_reason
    case "$odpm_modem_uws" in
        ''|*[!0-9]*) ;;
        *) _odpm_modem_base=$odpm_modem_uws ;;
    esac
    case "$odpm_rffe_uws" in
        ''|*[!0-9]*) ;;
        *) _odpm_rffe_base=$odpm_rffe_uws ;;
    esac
fi

_scope_elapsed=$((_now - _scope_start))
[ "$_scope_elapsed" -lt 0 ] && _scope_elapsed=0
_scope_level_drop=0
if [ -n "$_cur_level" ] && [ "$_scope_level_start" -gt "$_cur_level" ] 2>/dev/null; then
    _scope_level_drop=$((_scope_level_start - _cur_level))
fi

_scope_used='null'
if [ "$_scope_charge_start" -gt 0 ] 2>/dev/null && [ "$_cur_charge" -gt 0 ] 2>/dev/null && [ "$_scope_charge_start" -ge "$_cur_charge" ] 2>/dev/null; then
    _scope_used=$(awk -v s="$_scope_charge_start" -v c="$_cur_charge" 'BEGIN { printf "%.1f", (s - c) / 1000 }')
fi

_scope_quality='pure_discharge'
_scope_warning='模块会话为当前放电口径；和 Android batterystats 比较前必须核对 Start clock time / since last charge 是否同窗口。'
_scope_comparable=0
case "$_scope_reason" in
    full_replug|charged_10m)
        _scope_quality='session_window_mismatch'
        _scope_warning='模块会话因 full_replug/charged_10m 重置；不要和旧 batterystats reset 前后的窗口混用。'
        ;;
esac
if [ "$_scope_charge_start" -gt 0 ] 2>/dev/null && [ "$_cur_charge" -gt "$_scope_charge_start" ] 2>/dev/null; then
    _scope_quality='mixed_charge_discharge'
    _scope_warning='当前会话出现回充或 USB 末端跳变；放电值保留用于趋势，不用于待机结论或 batterystats 对账。'
elif [ "$_is_charging_like" -eq 1 ]; then
    _scope_quality='charging_endpoint'
    _scope_warning='当前 endpoint 为 Charging/Full/Not charging；ADB/USB 末端状态会污染短窗口，不能直接代表历史待机窗口。'
fi

# ODPM real modem power: read current IIO values, subtract session baseline
_odpm_modem_mah='null'
_odpm_rffe_mah='null'
_odpm_total_mah='null'
_odpm_modem_now=0; _odpm_rffe_now=0
_odpm_quality='missing_baseline'
_odpm_note='ODPM modem/RFFE 缺少有效会话基线或 endpoint，当前不输出 rail delta。'
_d0_now=$(cat /sys/bus/iio/devices/iio:device0/energy_value 2>/dev/null)
_d1_now=$(cat /sys/bus/iio/devices/iio:device1/energy_value 2>/dev/null)
_odpm_modem_now=$(printf '%s' "$_d0_now" | sed -n 's/.*VSYS_PWR_MODEM\], *\([0-9]*\).*/\1/p')
_odpm_rffe_now=$(printf '%s' "$_d1_now" | sed -n 's/.*VSYS_PWR_RFFE\], *\([0-9]*\).*/\1/p')
[ -z "$_odpm_modem_now" ] && _odpm_modem_now=0
[ -z "$_odpm_rffe_now" ] && _odpm_rffe_now=0
if [ "$_odpm_modem_base" -gt 0 ] 2>/dev/null && [ "$_odpm_rffe_base" -gt 0 ] 2>/dev/null && [ "$_odpm_modem_now" -gt "$_odpm_modem_base" ] 2>/dev/null && [ "$_odpm_rffe_now" -gt "$_odpm_rffe_base" ] 2>/dev/null; then
    _odpm_modem_mah=$(awk -v m="$_odpm_modem_now" -v mb="$_odpm_modem_base" -v r="$_odpm_rffe_now" -v rb="$_odpm_rffe_base" \
        'BEGIN { v=3.87; modem=(m-mb)/1000000/3600/v*1000; rffe=(r-rb)/1000000/3600/v*1000; printf "%.1f", modem }')
    _odpm_rffe_mah=$(awk -v r="$_odpm_rffe_now" -v rb="$_odpm_rffe_base" \
        'BEGIN { v=3.87; rffe=(r-rb)/1000000/3600/v*1000; printf "%.1f", rffe }')
    _odpm_total_mah=$(awk -v m="$_odpm_modem_now" -v mb="$_odpm_modem_base" -v r="$_odpm_rffe_now" -v rb="$_odpm_rffe_base" \
        'BEGIN { v=3.87; total=((m-mb)+(r-rb))/1000000/3600/v*1000; printf "%.1f", total }')
    _odpm_quality='session_delta'
    _odpm_note='ODPM 为模块 .power_session 到当前 endpoint 的 modem+RFFE rail delta；不是 Android batterystats 窗口。'
elif [ "$_odpm_modem_base" -gt 0 ] 2>/dev/null || [ "$_odpm_rffe_base" -gt 0 ] 2>/dev/null; then
    _odpm_quality='invalid_endpoint'
    _odpm_note='ODPM baseline 存在但 endpoint 未超过 modem/RFFE 双 rail baseline，可能是 rail 重置、采样失败或非同一会话。'
fi

_scope_json=$(printf '{"mode":"discharge_session","start_ts":%s,"elapsed_sec":%s,"level_start":%s,"level_now":%s,"level_drop":%s,"used_mah":%s,"reset_reason":%s,"reset_rule":%s,"comparable_to_batterystats":%s,"quality":%s,"warning":%s,"source":"module_power_session"}' \
    "$(json_num_or_null "$_scope_start")" \
    "$(json_num_or_null "$_scope_elapsed")" \
    "$(json_num_or_null "$_scope_level_start")" \
    "$(json_num_or_null "$_cur_level")" \
    "$(json_num_or_null "$_scope_level_drop")" \
    "$(json_num_or_null "$_scope_used")" \
    "$(json_str_or_null "$_scope_reason")" \
    "$(json_str_or_null "$RESET_RULE")" \
    "$(json_bool "$_scope_comparable")" \
    "$(json_str_or_null "$_scope_quality")" \
    "$(json_str_or_null "$_scope_warning")")

_odpm_json=$(printf '{"modem_mah":%s,"rffe_mah":%s,"total_mah":%s,"scope_start_ts":%s,"elapsed_sec":%s,"quality":%s,"note":%s,"source":"odpm_iio"}' \
    "$(json_num_or_null "$_odpm_modem_mah")" \
    "$(json_num_or_null "$_odpm_rffe_mah")" \
    "$(json_num_or_null "$_odpm_total_mah")" \
    "$(json_num_or_null "$_scope_start")" \
    "$(json_num_or_null "$_scope_elapsed")" \
    "$(json_str_or_null "$_odpm_quality")" \
    "$(json_str_or_null "$_odpm_note")")

_h=$(date +%H 2>/dev/null | sed 's/^0//')
_m=$(date +%M 2>/dev/null | sed 's/^0//')
_s=$(date +%S 2>/dev/null | sed 's/^0//')
[ -n "$_h" ] || _h=0
[ -n "$_m" ] || _m=0
[ -n "$_s" ] || _s=0
_today_start=$((_now - _h * 3600 - _m * 60 - _s))

if [ -s "$POWER_HISTORY" ]; then
    _today_json=$(awk -F, -v start="$_today_start" -v now="$_now" -v cur_level="${_cur_level:-}" -v cur_charge="${_cur_charge:-0}" '
    BEGIN {
        seen = 0
        samples = 0
        discharge = 0
        charge_in = 0
        has_discharge = 0
        has_charge = 0
        cur_level_valid = (cur_level ~ /^-?[0-9]+$/)
        cur_charge_valid = (cur_charge ~ /^-?[0-9]+$/ && cur_charge + 0 > 0)
        prev_charge_valid = 0
    }
    $1 + 0 >= start {
        ts = $1 + 0
        level = $2 + 0
        charge = $3 + 0
        charge_valid = ($3 ~ /^-?[0-9]+$/ && charge > 0)
        if (!seen) {
            seen = 1
            first_ts = ts
            first_level = level
            last_ts = ts
            last_level = level
            if (charge_valid) {
                prev_charge = charge
                prev_charge_valid = 1
            } else {
                prev_charge_valid = 0
            }
        } else {
            if (charge_valid && prev_charge_valid) {
                delta = prev_charge - charge
                if (delta > 0) {
                    discharge += delta / 1000
                    has_discharge = 1
                } else if (delta < 0) {
                    charge_in += (-delta) / 1000
                    has_charge = 1
                }
            }
            if (charge_valid) {
                prev_charge = charge
                prev_charge_valid = 1
            } else {
                prev_charge_valid = 0
            }
            last_ts = ts
            last_level = level
        }
        samples++
    }
    END {
        if (!seen) {
            printf "{\"start_ts\":%s,\"window_start_ts\":null,\"elapsed_sec\":0,\"samples\":0,\"level_start\":null,\"level_now\":", start
            if (cur_level_valid) printf "%s", cur_level
            else printf "null"
            printf ",\"net_level_delta\":null,\"discharge_mah\":null,\"charge_mah\":null,\"source\":\"module_power_history\"}"
            exit
        }

        if (cur_charge_valid && prev_charge_valid && now > last_ts) {
            delta = prev_charge - cur_charge
            if (delta > 0) {
                discharge += delta / 1000
                has_discharge = 1
            } else if (delta < 0) {
                charge_in += (-delta) / 1000
                has_charge = 1
            }
        }

        level_now = cur_level_valid ? cur_level + 0 : last_level
        net_delta = level_now - first_level
        elapsed = now - first_ts
        if (elapsed < 0) elapsed = 0

        printf "{\"start_ts\":%s,\"window_start_ts\":%s,\"elapsed_sec\":%s,\"samples\":%s,\"level_start\":%s,\"level_now\":%s,\"net_level_delta\":%s,\"discharge_mah\":", start, first_ts, elapsed, samples, first_level, level_now, net_delta
        if (has_discharge) printf "%.1f", discharge
        else printf "null"
        printf ",\"charge_mah\":"
        if (has_charge) printf "%.1f", charge_in
        else printf "null"
        printf ",\"source\":\"module_power_history\"}"
    }
    ' "$POWER_HISTORY")
else
    _today_json=$(printf '{"start_ts":%s,"window_start_ts":null,"elapsed_sec":0,"samples":0,"level_start":null,"level_now":%s,"net_level_delta":null,"discharge_mah":null,"charge_mah":null,"source":"module_power_history"}' \
        "$(json_num_or_null "$_today_start")" \
        "$(json_num_or_null "$_cur_level")")
fi

_history_windows_json='['
_history_first=1
for _hist_min in 15 30 60; do
    _hist_power_json=$(build_power_window_json "$_hist_min")
    _hist_thermal_json=$(build_thermal_window_json "$_hist_min")
    [ "$_history_first" -eq 1 ] && _history_first=0 || _history_windows_json="${_history_windows_json},"
    _history_windows_json="${_history_windows_json}{\"minutes\":$_hist_min,\"power\":$_hist_power_json,\"thermal\":$_hist_thermal_json}"
done
_history_windows_json="${_history_windows_json}]"

if [ "$_fast" -eq 1 ]; then
    _charge_state_json=$(printf '{"status":%s,"level":%s,"charge_uah":%s,"is_charging_like":%s,"external_power_online":%s,"power_source":%s}' \
        "$(json_str_or_null "$_cur_status")" \
        "$(json_num_or_null "$_cur_level")" \
        "$(json_num_or_null "$_cur_charge")" \
        "$(json_bool "$_is_charging_like")" \
        "$(json_bool "$_external_power_online")" \
        "$(json_str_or_null "$_power_source")")
    printf '{"cap":0,"drain":0,"scroff":0,"scron":0,"bat_time":"","screen":0,"cpu":0,"cell":0,"wifi":0,"wakelock":0,"apps":[],"odpm_modem":%s,"scope":%s,"today":%s,"history_windows":%s,"charge_state":%s,"batterystats_window":{"window_label":null,"daily_label":null,"time_on_battery":null,"model_quality":"fast_no_batterystats","radio_note":%s,"note":"快速缓存口径；系统 batterystats 分项稍后刷新。"},"generated_at":%s,"live_generated_at":%s,"system_generated_at":null,"system_cache_age_sec":null,"system_cache_stale":false,"cache_ttl_sec":%s,"fast":true}\n' \
        "$_odpm_json" "$_scope_json" "$_today_json" "$_history_windows_json" "$_charge_state_json" "$(json_str_or_null "$RADIO_MODEL_NOTE")" "$(json_num_or_null "$_now")" "$(json_num_or_null "$_now")" "$SYSTEM_CACHE_TTL"
    exit 0
fi

_system_payload=""
_system_generated_at=""
_system_cache_age=""
_system_cache_stale=0
_build_system_snapshot=0
_system_lock="$LOCKDIR_BASE/energy_system_cache.lock"
_have_system_lock=0

if _system_payload=$(read_system_cache_if_fresh "$_now"); then
    _system_generated_at=$(cat "$SYSTEM_CACHE_TS" 2>/dev/null | tr -d ' \n\r')
    case "$_system_generated_at" in
        ''|*[!0-9]*) _system_generated_at="" ;;
        *)
            _system_cache_age=$((_now - _system_generated_at))
            [ "$_system_cache_age" -lt 0 ] && _system_cache_age=999999
            ;;
    esac
else
    if try_acquire_energy_lock "$_system_lock" "$_now"; then
        _have_system_lock=1
        _build_system_snapshot=1
    else
        if _system_payload=$(read_system_cache_if_usable "$_now"); then
            _system_cache_stale=1
            _system_generated_at=$(cat "$SYSTEM_CACHE_TS" 2>/dev/null | tr -d ' \n\r')
            case "$_system_generated_at" in
                ''|*[!0-9]*) _system_generated_at="" ;;
                *)
                    _system_cache_age=$((_now - _system_generated_at))
                    [ "$_system_cache_age" -lt 0 ] && _system_cache_age=999999
                    ;;
            esac
        else
            _build_system_snapshot=1
        fi
    fi
fi

if [ "$_build_system_snapshot" -eq 1 ]; then
    # 先把 PackageManager 输出规范化为 uid|package，避免 Android awk 对
    # "package:... uid:..." 的多字符 split 在部分 toybox 版本上漏映射。
    pm list packages -U 2>/dev/null \
        | sed -n 's/^package:\(.*\) uid:\([0-9][0-9]*\)$/\2|\1/p' \
        > "${_tmp}_pkg"

    dumpsys batterystats 2>/dev/null | awk '
/^Statistics since last charge:/ && !seen_win { print "WIN:" $0; seen_win=1 }
/^[[:space:]]*Daily stats:/ && !seen_day { print "DAY:" $0; seen_day=1 }
/^  Estimated power use/,/^  *\(/ { print "EST:" $0 }
/^  UID / { print "UID:" $0 }
/Time on battery:/ && !seen_bat { print "BAT:" $0; seen_bat=1 }
/Screen off discharge:/ && !seen_soff { print "SOFF:" $0; seen_soff=1 }
/Screen on discharge:/ && !seen_son { print "SON:" $0; seen_son=1 }
' > "${_tmp}_bs"

    _bs_window=$(sed -n 's/^WIN://p' "${_tmp}_bs" | head -1)
    _bs_daily=$(sed -n 's/^DAY://p' "${_tmp}_bs" | head -1)
    _bs_time=$(sed -n 's/^BAT://p' "${_tmp}_bs" | head -1 | sed 's/.*battery: //; s/ (.*//')

    _core_json=$(awk -v pkgfile="${_tmp}_pkg" '
    BEGIN {
        while ((getline line < pkgfile) > 0) {
            split(line, p, "|")
            uid = p[1] + 0
            if (uid > 0 && p[2] != "") {
                if (pm[uid] == "") pm[uid] = p[2]
                else if (index("," pm[uid] ",", "," p[2] ",") == 0) pm[uid] = pm[uid] ", " p[2]
            }
        }
        close(pkgfile)
        an = 0
    }

    /^BAT:/ { sub(/.*battery: /, ""); sub(/ \(.*/, ""); bat_time = $0; next }
    /^SOFF:/ { match($0, /[0-9]+/); scroff = substr($0, RSTART, RLENGTH) + 0; next }
    /^SON:/ { match($0, /[0-9]+/); scron = substr($0, RSTART, RLENGTH) + 0; next }

    /^EST:/ {
        line = substr($0, 5)
        if (line ~ /Capacity:/) {
            n = split(line, w, " ")
            for (i = 1; i <= n; i++) {
                if (w[i] == "Capacity:") { v = w[i + 1]; gsub(/,/, "", v); cap = v + 0 }
                if (w[i] == "drain:" && w[i - 1] == "Computed") { v = w[i + 1]; gsub(/,/, "", v); drain = v + 0 }
            }
        }
        if (line ~ /^    screen:/ && !gs) { split(line, w); gs = w[2] + 0 }
        if (line ~ /^    cpu:/ && !gc) { split(line, w); gc = w[2] + 0 }
        if (line ~ /^    mobile_radio:/ && !gm) { split(line, w); gm = w[2] + 0 }
        if (line ~ /^    wifi:/ && !gw) { split(line, w); gw = w[2] + 0 }
        if (line ~ /^    wakelock:/ && !gk) { split(line, w); gk = w[2] + 0 }
        next
    }

    /^UID:/ {
        line = substr($0, 5)
        split(line, w)
        uid_s = w[2]
        gsub(/:/, "", uid_s)
        mah = w[3] + 0
        uid_label = ""
        if (uid_s ~ /^u[0-9]+a[0-9]+$/) {
            uid_part = uid_s
            sub(/^u/, "", uid_part)
            user_id = uid_part
            sub(/a.*/, "", user_id)
            app_id = uid_part
            sub(/^[0-9]+a/, "", app_id)
            n = (user_id + 0) * 100000 + 10000 + (app_id + 0)
        } else if (uid_s ~ /^u[0-9]+i[0-9]+$/) {
            uid_part = uid_s
            sub(/^u/, "", uid_part)
            user_id = uid_part
            sub(/i.*/, "", user_id)
            isolated_id = uid_part
            sub(/^[0-9]+i/, "", isolated_id)
            n = (user_id + 0) * 100000 + 99000 + (isolated_id + 0)
            uid_label = "应用隔离进程"
        } else { n = uid_s + 0 }
        pk = pm[n]
        label = uid_label
        if (n == 0) { pk = "android"; label = "Android 系统核心 (root)" }
        else if (n == 1000) { pk = "android"; label = "Android 系统服务 (system)" }
        else if (n == 1001) { pk = "android.radio"; label = "电话与基带服务 (radio)" }
        else if (n == 1002) { pk = "android.bluetooth"; label = "蓝牙系统服务" }
        else if (n == 1003) { pk = "android.graphics"; label = "图形系统服务" }
        else if (n == 1006) { pk = "android.camera"; label = "相机系统服务" }
        else if (n == 1013) { pk = "android.media"; label = "媒体系统服务" }
        else if (n == 1019) { pk = "android.drm"; label = "DRM 系统服务" }
        else if (n == 1027) { pk = "android.nfc"; label = "NFC 系统服务" }
        else if (n == 2000) { pk = "android.shell"; label = "ADB / Shell" }
        else if (pk == "" && label == "") { pk = ""; label = "已卸载或未知应用" }
        ap[an] = pk
        al[an] = label
        au[an] = uid_s
        ai[an] = n
        am[an] = mah
        an++
        next
    }

    END {
        gsub(/"/, "\\\"", bat_time)
        printf "{\"cap\":%d,\"drain\":%.0f,\"scroff\":%d,\"scron\":%d,\"bat_time\":\"%s\",", cap, drain, scroff, scron, bat_time
        printf "\"screen\":%.0f,\"cpu\":%.0f,\"cell\":%.0f,\"wifi\":%.0f,\"wakelock\":%.0f,\"apps\":[", gs, gc, gm, gw, gk
        top = an
        if (top > 10) top = 10
        for (i = 0; i < top; i++) {
            if (i) printf ","
            gsub(/"/, "\\\"", ap[i])
            gsub(/"/, "\\\"", al[i])
            gsub(/"/, "\\\"", au[i])
            printf "{\"uid\":\"%s\",\"uid_num\":%s,\"pkg\":", au[i], ai[i]
            if (ap[i] != "") printf "\"%s\"", ap[i]
            else printf "null"
            printf ",\"label\":", al[i]
            if (al[i] != "") printf "\"%s\"", al[i]
            else printf "null"
            printf ",\"mah\":%.0f}", am[i]
        }
        printf "]}"
    }
    ' "${_tmp}_bs")

    [ -n "$_core_json" ] || _core_json='{"cap":0,"drain":0,"scroff":0,"scron":0,"bat_time":"","screen":0,"cpu":0,"cell":0,"wifi":0,"wakelock":0,"apps":[]}'

    _core_drain=$(printf '%s' "$_core_json" | sed -n 's/.*"drain":\([0-9.][0-9.]*\).*/\1/p')
    _core_scroff=$(printf '%s' "$_core_json" | sed -n 's/.*"scroff":\([0-9.][0-9.]*\).*/\1/p')
    _core_cell=$(printf '%s' "$_core_json" | sed -n 's/.*"cell":\([0-9.][0-9.]*\).*/\1/p')
    [ -n "$_core_drain" ] || _core_drain=0
    [ -n "$_core_scroff" ] || _core_scroff=0
    [ -n "$_core_cell" ] || _core_cell=0
    _bs_model_quality='total_ok_radio_model_reference'
    if awk -v c="$_core_cell" -v d="$_core_drain" -v s="$_core_scroff" 'BEGIN { exit !((d > 0 && c > d * 0.70) || (s > 0 && c > s)) }'; then
        _bs_model_quality='total_ok_radio_model_untrusted'
    fi

    _batterystats_json=$(printf '{"window_label":%s,"daily_label":%s,"time_on_battery":%s,"model_quality":%s,"radio_note":%s,"note":%s}' \
        "$(json_str_or_null "$_bs_window")" \
        "$(json_str_or_null "$_bs_daily")" \
        "$(json_str_or_null "$_bs_time")" \
        "$(json_str_or_null "$_bs_model_quality")" \
        "$(json_str_or_null "$RADIO_MODEL_NOTE")" \
        "$(json_str_or_null "$BATTERYSTATS_NOTE")")

    _system_payload=$(printf '%s' "$_core_json" | sed 's/}$//')
    _system_payload=$(printf '%s,"batterystats_window":%s}' "$_system_payload" "$_batterystats_json")
    _system_generated_at=$_now
    _system_cache_age=0
    _system_cache_stale=0
    [ "$_have_system_lock" -eq 1 ] && write_system_cache "$_system_payload" "$_system_generated_at"
fi

[ "$_have_system_lock" -eq 1 ] && release_energy_lock "$_system_lock"

if [ -z "$_system_payload" ]; then
    _batterystats_json=$(printf '{"window_label":null,"daily_label":null,"time_on_battery":null,"model_quality":"no_system_snapshot","radio_note":%s,"note":"系统 batterystats 快照不可用；实时字段仍可用。"}' "$(json_str_or_null "$RADIO_MODEL_NOTE")")
    _system_payload=$(printf '{"cap":0,"drain":0,"scroff":0,"scron":0,"bat_time":"","screen":0,"cpu":0,"cell":0,"wifi":0,"wakelock":0,"apps":[],"batterystats_window":%s}' "$_batterystats_json")
fi

_charge_state_json=$(printf '{"status":%s,"level":%s,"charge_uah":%s,"is_charging_like":%s,"external_power_online":%s,"power_source":%s}' \
    "$(json_str_or_null "$_cur_status")" \
    "$(json_num_or_null "$_cur_level")" \
    "$(json_num_or_null "$_cur_charge")" \
    "$(json_bool "$_is_charging_like")" \
    "$(json_bool "$_external_power_online")" \
    "$(json_str_or_null "$_power_source")")

_final_json=$(printf '%s' "$_system_payload" | sed 's/}$//')
_final_json=$(printf '%s,"odpm_modem":%s,"scope":%s,"today":%s,"history_windows":%s,"charge_state":%s,"generated_at":%s,"live_generated_at":%s,"system_generated_at":%s,"system_cache_age_sec":%s,"system_cache_stale":%s,"cache_ttl_sec":%s}' \
    "$_final_json" \
    "$_odpm_json" \
    "$_scope_json" \
    "$_today_json" \
    "$_history_windows_json" \
    "$_charge_state_json" \
    "$(json_num_or_null "$_now")" \
    "$(json_num_or_null "$_now")" \
    "$(json_num_or_null "$_system_generated_at")" \
    "$(json_num_or_null "$_system_cache_age")" \
    "$(json_bool "$_system_cache_stale")" \
    "$SYSTEM_CACHE_TTL")
printf '%s\n' "$_final_json"
