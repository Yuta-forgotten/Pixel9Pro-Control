#!/system/bin/sh

# Read-only view of Android BatteryStats durable history. The service collector
# owns writes; this CGI only derives interval power and exposes gaps.
MODDIR="${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}"
. "$MODDIR/webroot/cgi-bin/_common.sh"
require_loopback
STATE_ROOT="${PIXEL9PRO_STATE_ROOT:-/data/adb/pixel9pro_control}"
ROOT="$STATE_ROOT/system_history"
EVENTS="$ROOT/events"
MAX_AGE=604800
MAX_GAP=3600

json_num() { case "$1" in ''|*[!0-9.-]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }
json_escape() { printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r//g;s/\n/\\n/g'; }
query_value() { printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1; }
valid_epoch() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
config_value() { _hsc_key="$1"; _hsc_default="$2"; _hsc_value=$(sed -n "s/^${_hsc_key}=//p" "$STATE_ROOT/system_history_config" 2>/dev/null | head -n 1 | tr -d ' \r\n\t'); [ -n "$_hsc_value" ] && printf '%s' "$_hsc_value" || printf '%s' "$_hsc_default"; }
config_enabled() { case "$(config_value analytics_enabled 1)" in 0|false|off|no) printf false ;; *) printf true ;; esac; }
receipt_value() { sed -n "s/^$1=//p" "$ROOT/receipt" 2>/dev/null | head -n 1 | tr -d ' \r\n\t'; }

now=$(date +%s 2>/dev/null || printf '0')
valid_epoch "$now" || now=0
_off_interval=$(config_value system_interval_off_sec 900)
case "$_off_interval" in ''|*[!0-9]*) _off_interval=900 ;; esac
[ "$_off_interval" -ge 900 ] 2>/dev/null || _off_interval=900
MAX_GAP=$((_off_interval * 2))
end_ts=$(query_value end_ts); start_ts=$(query_value start_ts)
[ -n "$end_ts" ] || end_ts="$now"
[ -n "$start_ts" ] || start_ts=$((end_ts - 3600))
valid_epoch "$end_ts" || { json_error '400 Bad Request' 'invalid end_ts'; exit 0; }
valid_epoch "$start_ts" || { json_error '400 Bad Request' 'invalid start_ts'; exit 0; }
[ "$start_ts" -le "$end_ts" ] 2>/dev/null || { json_error '400 Bad Request' 'start_ts is after end_ts'; exit 0; }
[ "$start_ts" -ge $((end_ts - MAX_AGE)) ] 2>/dev/null || { json_error '400 Bad Request' 'history range exceeds 7 days'; exit 0; }

json_headers
case "$(config_enabled)" in false)
    printf '{"ok":true,"schema":2,"status":"disabled","quality":"disabled","reason":"feature_disabled","source":"android_batterystats_history","policy":{"analytics_enabled":false},"power":[],"power_rates":[],"thermal":[]}\n'
    exit 0
    ;;
esac
if [ ! -d "$EVENTS" ]; then
    printf '{"ok":true,"schema":2,"status":"unavailable","quality":"unavailable","reason":"history_not_collected","source":"android_batterystats_history","model":"BatteryStats estimated power use","policy":{"phase":"effective","analytics_enabled":%s,"retention_days":%s,"max_bytes":%s,"module_interval_on_sec":%s,"module_interval_off_sec":%s,"system_interval_on_sec":%s,"system_interval_off_sec":%s},"collection":{"phase":"effective","last_attempt_ts":null,"last_success_ts":null,"last_result":"never"},"start_ts":%s,"end_ts":%s,"coverage_sec":0,"coverage_ratio":0,"valid_samples":0,"raw_samples":0,"gap_count":0,"gaps":[],"updated_at":null,"window":{"start_ts":%s,"end_ts":%s,"coverage_ratio":0,"quality":"unavailable"},"sources":{"power":{"raw_samples":0,"valid_samples":0,"quality":"unavailable"},"thermal":{"raw_samples":0,"valid_samples":0,"quality":"unavailable"}},"power":[],"power_rates":[],"thermal":[]}\n' \
        "$(config_enabled)" "$(config_value retention_days 7)" "$(config_value max_bytes 33554432)" "$(config_value module_interval_on_sec 60)" "$(config_value module_interval_off_sec 900)" "$(config_value system_interval_on_sec 900)" "$(config_value system_interval_off_sec 900)" "$(json_num "$start_ts")" "$(json_num "$end_ts")" "$(json_num "$start_ts")" "$(json_num "$end_ts")"
    exit 0
fi

rows="$ROOT/.event_rows.$$"
sorted="$ROOT/.event_rows_sorted.$$"
out="$ROOT/.event_calc.$$"
trap 'rm -f "$rows" "$sorted" "$out" 2>/dev/null' EXIT INT TERM HUP
: > "$rows" 2>/dev/null || { printf '{"ok":false,"error":"cannot create system history rows"}\n'; exit 0; }

latest_file=''
latest_stamp=0
for file in "$EVENTS"/*; do
    [ -f "$file" ] || continue
    name=${file##*/}
    stamp=${name%%_*}
    case "$stamp" in ''|*[!0-9]*) continue ;; esac
    if [ "$stamp" -le "$end_ts" ] 2>/dev/null && [ "$stamp" -ge "$latest_stamp" ] 2>/dev/null; then
        latest_file="$file"
        latest_stamp="$stamp"
    fi
done
[ -n "$latest_file" ] || { printf '{"ok":true,"schema":2,"status":"unavailable","quality":"unavailable","reason":"history_not_collected","source":"android_batterystats_history","power":[],"power_rates":[],"thermal":[]}\n'; exit 0; }
name=${latest_file##*/}
boot_id=${name#*_}
cache_dir="$ROOT/cache"
mkdir -p "$cache_dir" 2>/dev/null || true
_policy_revision="$(config_value retention_days 7)_$(config_value max_bytes 33554432)_$(config_value system_interval_on_sec 900)_$_off_interval"
cache_file="$cache_dir/v5_${start_ts}_${end_ts}_${latest_stamp}_${_policy_revision}.json"
cache_count=0
for _cache_entry in "$cache_dir"/*.json; do
    [ -f "$_cache_entry" ] || continue
    cache_count=$((cache_count + 1))
done
if [ "$cache_count" -gt 48 ] 2>/dev/null; then
    for _cache_entry in "$cache_dir"/*.json; do
        [ "$cache_count" -gt 32 ] 2>/dev/null || break
        [ -f "$_cache_entry" ] || continue
        rm -f "$_cache_entry" 2>/dev/null
        cache_count=$((cache_count - 1))
    done
fi
if [ -s "$cache_file" ]; then
    cat "$cache_file" 2>/dev/null
    exit 0
fi
awk -F '\t' -v boot="$boot_id" -v start_ts="$start_ts" -v end_ts="$end_ts" -v lookback="$MAX_GAP" \
    '$1 == "event" && $2 ~ /^[0-9]+$/ && $2 >= start_ts - lookback && $2 <= end_ts { print $2 "\t" $3 "\t" boot "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $9 "\t" $10 "\t" $11 }' \
    "$latest_file" > "$sorted" 2>/dev/null
cp "$sorted" "$rows" 2>/dev/null || true

awk -F '\t' -v start_ts="$start_ts" -v end_ts="$end_ts" -v max_gap="$MAX_GAP" '
BEGIN { OFS="\t"; prev_ts=0; prev_seg=""; prev_boot=""; prev_charge=""; prev_status=""; raw=0; valid=0; coverage=0; gap_count=0; updated=0 }
function is_num(v) { return v ~ /^-?[0-9]+(\.[0-9]+)?$/ }
function emit_gap(a,b,r) { if (b>a) { gap_count++; printf "gap\t%d\t%d\t%s\n",a,b,r } }
{
  ts=$1+0; seg=$2; sub(/\..*$/, "", seg); boot=$3; level=$4; charge=$5; temp=$6; voltage=$7; status=$8; screen=$9; idle=$10; quality=$11
  if (ts > end_ts) next
  in_window=(ts >= start_ts)
  if (in_window) { raw++; if (ts>updated) updated=ts }
  point_valid=0; rate="null"; interval=0; point_quality=quality
  if (prev_ts>0 && ts>prev_ts) {
    interval=ts-prev_ts
    if (prev_ts < start_ts) { point_quality="window_boundary"; emit_gap(start_ts,ts,point_quality) }
    else if (seg != prev_seg || boot != prev_boot) { point_quality="segment_changed"; emit_gap(prev_ts,ts,point_quality) }
    else if (interval > max_gap) { point_quality="interval_too_long"; emit_gap(prev_ts,ts,point_quality) }
    else if (is_num(charge) && is_num(prev_charge) && status == "Discharging" && prev_status == "Discharging") {
      delta=prev_charge-charge
      if (delta >= 0) { rate=(delta/1000)*3600/interval; point_valid=1; point_quality="ok"; valid++; coverage+=interval }
      else { point_quality="counter_reset"; emit_gap(prev_ts,ts,point_quality) }
    }
  }
  if (in_window) printf "point\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\n", ts, boot, seg, level, charge, temp, voltage, status, screen, idle, rate, point_quality, interval, point_valid
  prev_ts=ts; prev_seg=seg; prev_boot=boot; prev_charge=charge; prev_status=status
}
END { status=(valid>0?"available":"unavailable"); quality=(valid==0?"unavailable":(gap_count>0?"partial":"complete")); reason=(valid>0?(gap_count>0?"gaps_or_counter_reset":"ok"):"need_two_discharge_events"); printf "meta\t%s\t%s\t%s\t%d\t%d\t%d\t%d\n",status,quality,reason,coverage,valid,raw,updated,gap_count }
' "$sorted" > "$out" 2>/dev/null

TAB=$(printf '\t')
meta=$(sed -n '/^meta'"$TAB"'/p' "$out" 2>/dev/null | tail -n 1)
IFS="$TAB" read -r _meta _status quality reason coverage valid_samples raw_samples updated gap_count <<EOF
$meta
EOF
[ -n "$_status" ] || _status=unavailable
[ -n "$quality" ] || quality=unavailable
[ -n "$reason" ] || reason=history_not_collected
case "$coverage" in ''|*[!0-9]*) coverage=0 ;; esac
case "$valid_samples" in ''|*[!0-9]*) valid_samples=0 ;; esac
case "$raw_samples" in ''|*[!0-9]*) raw_samples=0 ;; esac
case "$updated" in ''|*[!0-9]*) updated=0 ;; esac
case "$gap_count" in ''|*[!0-9]*) gap_count=0 ;; esac
elapsed=$((end_ts-start_ts)); [ "$elapsed" -gt 0 ] 2>/dev/null || elapsed=1
coverage_ratio=$(awk -v c="$coverage" -v e="$elapsed" 'BEGIN { r=c/e; if(r<0)r=0; if(r>1)r=1; printf "%.3f",r }')
_policy_phase=staged
_policy_success=$(receipt_value last_success_ts)
_policy_config_ts=$(stat -c %Y "$STATE_ROOT/system_history_config" 2>/dev/null || printf '0')
case "$_policy_success:$_policy_config_ts" in *[!0-9:]*) ;; *) [ "$_policy_success" -ge "$_policy_config_ts" ] 2>/dev/null && _policy_phase=effective ;; esac
policy_json=$(printf '{"phase":"%s","analytics_enabled":%s,"retention_days":%s,"max_bytes":%s,"module_interval_on_sec":%s,"module_interval_off_sec":%s,"system_interval_on_sec":%s,"system_interval_off_sec":%s}' \
    "$_policy_phase" "$(config_enabled)" "$(config_value retention_days 7)" "$(config_value max_bytes 33554432)" "$(config_value module_interval_on_sec 60)" "$(config_value module_interval_off_sec 900)" "$(config_value system_interval_on_sec 900)" "$(config_value system_interval_off_sec 900)")
collection_json=$(printf '{"phase":"effective","last_attempt_ts":%s,"last_success_ts":%s,"last_result":"%s","screen":"%s","doze":"%s"}' \
    "$(json_num "$(receipt_value last_attempt_ts)")" "$(json_num "$(receipt_value last_success_ts)")" "$(json_escape "$(receipt_value last_result)")" "$(json_escape "$(receipt_value screen)")" "$(json_escape "$(receipt_value doze)")")
screen_totals=$(awk -F '\t' '$1 == "point" && $15 == 1 { mah=$12*$14/3600; if ($10 == "on") { on_mah+=mah; on_sec+=$14 } else if ($10 == "off") { off_mah+=mah; off_sec+=$14 } } END { printf "{\"on_mah\":%.6f,\"off_mah\":%.6f,\"on_sec\":%d,\"off_sec\":%d}",on_mah+0,off_mah+0,on_sec+0,off_sec+0 }' "$out")
battery_level=$(awk -F '\t' '$1 == "point" { level=$5 } END { if (level ~ /^[0-9]+$/) print level; else print "null" }' "$out")

power_json="$ROOT/.event_power_json.$$"
thermal_json="$ROOT/.event_thermal_json.$$"
gaps_json="$ROOT/.event_gaps_json.$$"
rates_json="$ROOT/.event_rates_json.$$"
response_tmp="$ROOT/.event_response.$$"
trap 'rm -f "$rows" "$sorted" "$out" "$power_json" "$thermal_json" "$gaps_json" "$rates_json" "$response_tmp" 2>/dev/null' EXIT INT TERM HUP
awk -F '\t' 'BEGIN { first=1 } $1 == "point" { if (!first) printf ","; first=0; charge="null"; if ($6 ~ /^-?[0-9]+(\.[0-9]+)?$/) charge=$6/1000; printf "{\"ts\":%s,\"system_mah\":%s,\"system_rate_mah_h\":%s,\"interval_sec\":%s,\"screen\":\"%s\",\"doze\":\"%s\",\"boot_id\":\"%s\",\"source\":\"android_batterystats_history\",\"valid\":%s,\"quality\":\"%s\"}", $2,charge,($12 == "null" ? "null" : $12),$14,$10,$11,$3,($15 == 1 ? "true" : "false"),$13 }' "$out" > "$power_json" 2>/dev/null
awk -F '\t' 'BEGIN { first=1 } $1 == "point" { if (!first) printf ","; first=0; temp="null"; if ($7 ~ /^-?[0-9]+(\.[0-9]+)?$/) temp=$7; printf "{\"ts\":%s,\"battery_mc\":%s,\"screen\":\"%s\",\"doze\":\"%s\",\"boot_id\":\"%s\",\"source\":\"android_batterystats_history\",\"valid\":%s,\"quality\":\"%s\"}", $2,temp,$10,$11,$3,(temp == "null" ? "false" : "true"),$13 }' "$out" > "$thermal_json" 2>/dev/null
awk -F '\t' 'BEGIN { first=1 } $1 == "gap" { if (!first) printf ","; first=0; printf "{\"start_ts\":%s,\"end_ts\":%s,\"reason\":\"%s\"}",$2,$3,$4 }' "$out" > "$gaps_json" 2>/dev/null
awk -F '\t' 'BEGIN { first=1 } $1 == "point" && $15 == 1 { if (!first) printf ","; first=0; mah=$12*$14/3600; printf "{\"start_ts\":%s,\"end_ts\":%s,\"ts\":%s,\"mah\":%.6f,\"rate_mah_h\":%s,\"interval_sec\":%s,\"screen\":\"%s\",\"segment_id\":\"%s\",\"source\":\"android\",\"valid\":true,\"quality\":\"%s\"}",$2-$14,$2,$2,mah,$12,$14,$10,$4,$13 }' "$out" > "$rates_json" 2>/dev/null
{
    printf '{"ok":true,"schema":2,"status":"%s","quality":"%s","reason":"%s","source":"android_batterystats_history","model":"BatteryStats estimated power use","rank_revision":"%s","policy":%s,"collection":%s,"screen_totals":%s,"battery_level":%s,"sources":{"power":{"raw_samples":%s,"valid_samples":%s,"quality":"%s","coverage_ratio":%s},"thermal":{"raw_samples":%s,"valid_samples":%s,"quality":"%s","coverage_ratio":%s}},"start_ts":%s,"end_ts":%s,"coverage_sec":%s,"coverage_ratio":%s,"valid_samples":%s,"raw_samples":%s,"gap_count":%s,"gaps":[' "$(json_escape "$_status")" "$(json_escape "$quality")" "$(json_escape "$reason")" "$(json_escape "$latest_stamp")" "$policy_json" "$collection_json" "$screen_totals" "$(json_num "$battery_level")" "$(json_num "$raw_samples")" "$(json_num "$valid_samples")" "$(json_escape "$quality")" "$coverage_ratio" "$(json_num "$raw_samples")" "$(json_num "$valid_samples")" "$(json_escape "$quality")" "$coverage_ratio" "$(json_num "$start_ts")" "$(json_num "$end_ts")" "$(json_num "$coverage")" "$coverage_ratio" "$(json_num "$valid_samples")" "$(json_num "$raw_samples")" "$(json_num "$gap_count")"
    cat "$gaps_json" 2>/dev/null
    printf '],"updated_at":%s,"data_revision":"%s:%s:%s","window":{"start_ts":%s,"end_ts":%s,"coverage_ratio":%s,"valid_samples":%s,"raw_samples":%s,"gap_count":%s,"quality":"%s"},"power":[' "$(json_num "$updated")" "$(json_escape "$_status")" "$(json_escape "$quality")" "$(json_num "$updated")" "$(json_num "$start_ts")" "$(json_num "$end_ts")" "$coverage_ratio" "$(json_num "$valid_samples")" "$(json_num "$raw_samples")" "$(json_num "$gap_count")" "$(json_escape "$quality")"
    cat "$power_json" 2>/dev/null
    printf '],"thermal":['
    cat "$thermal_json" 2>/dev/null
    printf '],"power_rates":['
    cat "$rates_json" 2>/dev/null
    printf ']}\n'
} > "$response_tmp" 2>/dev/null
mv "$response_tmp" "$cache_file" 2>/dev/null || true
cat "$cache_file" 2>/dev/null
exit 0
