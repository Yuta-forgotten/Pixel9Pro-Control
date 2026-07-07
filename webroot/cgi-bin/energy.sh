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
ENERGY_CACHE="$MODDIR/.energy_cache.json"
ENERGY_CACHE_TS="$MODDIR/.energy_cache.ts"
ENERGY_CACHE_TTL=45
ENERGY_CACHE_STALE_MAX=600
RESET_RULE='连续充电 >= 10 分钟且电量回升，或充满后重新拔线后，重置为新的放电会话'
BATTERYSTATS_NOTE='系统分项和应用排行来自 Android batterystats 当前窗口；若系统或用户执行过 batterystats reset，这个窗口可能比放电会话更短。'

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

read_battery_value() {
    tr -d ' \n\r' < "$1" 2>/dev/null
}

read_state_value() {
    _state_file="$1"
    _state_key="$2"
    sed -n "s/^${_state_key}=//p" "$_state_file" 2>/dev/null | head -n 1 | tr -d '\r'
}

read_energy_cache_if_fresh() {
    _cache_now="$1"
    [ -s "$ENERGY_CACHE" ] || return 1
    _cache_ts=$(cat "$ENERGY_CACHE_TS" 2>/dev/null | tr -d ' \n\r')
    case "$_cache_ts" in
        ''|*[!0-9]*) return 1 ;;
    esac
    _cache_age=$((_cache_now - _cache_ts))
    [ "$_cache_age" -lt 0 ] && _cache_age=999999
    [ "$_cache_age" -le "$ENERGY_CACHE_TTL" ] || return 1
    cat "$ENERGY_CACHE"
    return 0
}

read_energy_cache_if_usable() {
    _cache_now="$1"
    [ -s "$ENERGY_CACHE" ] || return 1
    _cache_ts=$(cat "$ENERGY_CACHE_TS" 2>/dev/null | tr -d ' \n\r')
    case "$_cache_ts" in
        ''|*[!0-9]*) return 1 ;;
    esac
    _cache_age=$((_cache_now - _cache_ts))
    [ "$_cache_age" -lt 0 ] && _cache_age=999999
    [ "$_cache_age" -le "$ENERGY_CACHE_STALE_MAX" ] || return 1
    cat "$ENERGY_CACHE"
    return 0
}

write_energy_cache() {
    _payload="$1"
    _cache_now="$2"
    printf '%s\n' "$_payload" > "${ENERGY_CACHE}.tmp"
    mv "${ENERGY_CACHE}.tmp" "$ENERGY_CACHE"
    printf '%s\n' "$_cache_now" > "${ENERGY_CACHE_TS}.tmp"
    mv "${ENERGY_CACHE_TS}.tmp" "$ENERGY_CACHE_TS"
}

build_power_window_json() {
    _mins="$1"
    _start=$((_now - _mins * 60))
    if [ -s "$POWER_HISTORY" ]; then
        awk -F, -v minutes="$_mins" -v start="$_start" -v now="$_now" -v cur_level="${_cur_level:-}" -v cur_charge="${_cur_charge:-0}" '
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
                printf "{\"minutes\":%s,\"start_ts\":%s,\"window_start_ts\":null,\"elapsed_sec\":0,\"samples\":0,\"level_start\":null,\"level_now\":", minutes, start
                if (cur_level_valid) printf "%s", cur_level
                else printf "null"
                printf ",\"net_level_delta\":null,\"discharge_mah\":null,\"charge_mah\":null,\"avg_discharge_mah_per_h\":null,\"avg_discharge_mw\":null,\"source\":\"module_power_history\"}"
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

            printf "{\"minutes\":%s,\"start_ts\":%s,\"window_start_ts\":%s,\"elapsed_sec\":%s,\"samples\":%s,\"level_start\":%s,\"level_now\":%s,\"net_level_delta\":%s,\"discharge_mah\":", minutes, start, first_ts, elapsed, samples, first_level, level_now, net_delta
            if (has_discharge) printf "%.1f", discharge
            else printf "null"
            printf ",\"charge_mah\":"
            if (has_charge) printf "%.1f", charge_in
            else printf "null"
            printf ",\"avg_discharge_mah_per_h\":"
            if (has_discharge && elapsed > 0) printf "%.1f", discharge * 3600 / elapsed
            else printf "null"
            printf ",\"avg_discharge_mw\":"
            if (has_discharge && elapsed > 0) printf "%.0f", discharge * 3600 / elapsed * 3.87
            else printf "null"
            printf ",\"source\":\"module_power_history\"}"
        }
        ' "$POWER_HISTORY"
    else
        printf '{"minutes":%s,"start_ts":%s,"window_start_ts":null,"elapsed_sec":0,"samples":0,"level_start":null,"level_now":%s,"net_level_delta":null,"discharge_mah":null,"charge_mah":null,"avg_discharge_mah_per_h":null,"avg_discharge_mw":null,"source":"module_power_history"}' \
            "$(json_num_or_null "$_mins")" \
            "$(json_num_or_null "$_start")" \
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
if read_energy_cache_if_fresh "$_now"; then
    exit 0
fi
if [ "$_fast" -eq 1 ] && read_energy_cache_if_usable "$_now"; then
    exit 0
fi

_cur_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null | tr -d '\r')
_cur_status=$(printf '%s' "$_cur_status" | sed 's/[[:space:]]*$//')
[ -n "$_cur_status" ] || _cur_status="Unknown"
_cur_level=$(read_battery_value /sys/class/power_supply/battery/capacity)
_cur_charge=$(read_battery_value /sys/class/power_supply/battery/charge_counter)

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

# ODPM real modem power: read current IIO values, subtract session baseline
_odpm_modem_mah='null'
_odpm_rffe_mah='null'
_odpm_total_mah='null'
_odpm_modem_now=0; _odpm_rffe_now=0
_d0_now=$(cat /sys/bus/iio/devices/iio:device0/energy_value 2>/dev/null)
_d1_now=$(cat /sys/bus/iio/devices/iio:device1/energy_value 2>/dev/null)
_odpm_modem_now=$(printf '%s' "$_d0_now" | sed -n 's/.*VSYS_PWR_MODEM\], *\([0-9]*\).*/\1/p')
_odpm_rffe_now=$(printf '%s' "$_d1_now" | sed -n 's/.*VSYS_PWR_RFFE\], *\([0-9]*\).*/\1/p')
[ -z "$_odpm_modem_now" ] && _odpm_modem_now=0
[ -z "$_odpm_rffe_now" ] && _odpm_rffe_now=0
if [ "$_odpm_modem_base" -gt 0 ] 2>/dev/null && [ "$_odpm_modem_now" -gt "$_odpm_modem_base" ] 2>/dev/null; then
    _odpm_modem_mah=$(awk -v m="$_odpm_modem_now" -v mb="$_odpm_modem_base" -v r="$_odpm_rffe_now" -v rb="$_odpm_rffe_base" \
        'BEGIN { v=3.87; modem=(m-mb)/1000000/3600/v*1000; rffe=(r-rb)/1000000/3600/v*1000; printf "%.1f", modem }')
    _odpm_rffe_mah=$(awk -v r="$_odpm_rffe_now" -v rb="$_odpm_rffe_base" \
        'BEGIN { v=3.87; rffe=(r-rb)/1000000/3600/v*1000; printf "%.1f", rffe }')
    _odpm_total_mah=$(awk -v m="$_odpm_modem_now" -v mb="$_odpm_modem_base" -v r="$_odpm_rffe_now" -v rb="$_odpm_rffe_base" \
        'BEGIN { v=3.87; total=((m-mb)+(r-rb))/1000000/3600/v*1000; printf "%.1f", total }')
fi

_scope_json=$(printf '{"mode":"discharge_session","start_ts":%s,"elapsed_sec":%s,"level_start":%s,"level_now":%s,"level_drop":%s,"used_mah":%s,"reset_reason":%s,"reset_rule":%s,"source":"module_power_session"}' \
    "$(json_num_or_null "$_scope_start")" \
    "$(json_num_or_null "$_scope_elapsed")" \
    "$(json_num_or_null "$_scope_level_start")" \
    "$(json_num_or_null "$_cur_level")" \
    "$(json_num_or_null "$_scope_level_drop")" \
    "$(json_num_or_null "$_scope_used")" \
    "$(json_str_or_null "$_scope_reason")" \
    "$(json_str_or_null "$RESET_RULE")")

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
    _charge_state_json=$(printf '{"status":%s,"level":%s,"charge_uah":%s}' \
        "$(json_str_or_null "$_cur_status")" \
        "$(json_num_or_null "$_cur_level")" \
        "$(json_num_or_null "$_cur_charge")")
    printf '{"cap":0,"drain":0,"scroff":0,"scron":0,"bat_time":"","screen":0,"cpu":0,"cell":0,"wifi":0,"wakelock":0,"apps":[],"odpm_modem":{"modem_mah":null,"rffe_mah":null,"total_mah":null,"source":"odpm_iio"},"scope":%s,"today":%s,"history_windows":%s,"charge_state":%s,"batterystats_window":{"window_label":null,"daily_label":null,"time_on_battery":null,"note":"快速缓存口径；系统 batterystats 分项稍后刷新。"},"generated_at":%s,"cache_ttl_sec":%s,"fast":true}\n' \
        "$_scope_json" "$_today_json" "$_history_windows_json" "$_charge_state_json" "$(json_num_or_null "$_now")" "$ENERGY_CACHE_TTL"
    exit 0
fi

_energy_lock="$LOCKDIR_BASE/energy_cache.lock"
_have_energy_lock=0
if try_acquire_energy_lock "$_energy_lock" "$_now"; then
    _have_energy_lock=1
else
    if [ -s "$ENERGY_CACHE" ]; then
        cat "$ENERGY_CACHE"
        exit 0
    fi
fi

pm list packages -U 2>/dev/null > "${_tmp}_pkg"

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
        sub(/^package:/, "", line)
        split(line, p, " uid:")
        if (p[2] + 0 > 0) pm[p[2] + 0] = p[1]
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
    if (index(uid_s, "u0a") == 1) { n = uid_s; sub(/u0a/, "", n); n = n + 10000 }
    else { n = uid_s + 0 }
    pk = pm[n]
    if (pk == "") {
        if (n == 0) pk = "android (root)"
        else if (n == 1000) pk = "android (system)"
        else if (n == 1001) pk = "android (radio)"
        else pk = uid_s
    }
    ap[an] = pk
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
        printf "{\"pkg\":\"%s\",\"mah\":%.0f}", ap[i], am[i]
    }
    printf "]}"
}
' "${_tmp}_bs")

[ -n "$_core_json" ] || _core_json='{"cap":0,"drain":0,"scroff":0,"scron":0,"bat_time":"","screen":0,"cpu":0,"cell":0,"wifi":0,"wakelock":0,"apps":[]}'

_batterystats_json=$(printf '{"window_label":%s,"daily_label":%s,"time_on_battery":%s,"note":%s}' \
    "$(json_str_or_null "$_bs_window")" \
    "$(json_str_or_null "$_bs_daily")" \
    "$(json_str_or_null "$_bs_time")" \
    "$(json_str_or_null "$BATTERYSTATS_NOTE")")

_charge_state_json=$(printf '{"status":%s,"level":%s,"charge_uah":%s}' \
    "$(json_str_or_null "$_cur_status")" \
    "$(json_num_or_null "$_cur_level")" \
    "$(json_num_or_null "$_cur_charge")")

_odpm_json=$(printf '{"modem_mah":%s,"rffe_mah":%s,"total_mah":%s,"source":"odpm_iio"}' \
    "$(json_num_or_null "$_odpm_modem_mah")" \
    "$(json_num_or_null "$_odpm_rffe_mah")" \
    "$(json_num_or_null "$_odpm_total_mah")")

_final_json=$(printf '%s' "$_core_json" | sed 's/}$//')
_final_json=$(printf '%s,"odpm_modem":%s,"scope":%s,"today":%s,"history_windows":%s,"charge_state":%s,"batterystats_window":%s,"generated_at":%s,"cache_ttl_sec":%s}' \
    "$_final_json" \
    "$_odpm_json" \
    "$_scope_json" \
    "$_today_json" \
    "$_history_windows_json" \
    "$_charge_state_json" \
    "$_batterystats_json" \
    "$(json_num_or_null "$_now")" \
    "$ENERGY_CACHE_TTL")

[ "$_have_energy_lock" -eq 1 ] && write_energy_cache "$_final_json" "$_now"
[ "$_have_energy_lock" -eq 1 ] && release_energy_lock "$_energy_lock"
printf '%s\n' "$_final_json"
