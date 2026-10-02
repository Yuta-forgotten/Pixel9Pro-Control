#!/system/bin/sh

# Read-only Android BatteryStats history. The service owns snapshot writes;
# this endpoint only derives window-local rates and exposes coverage/gaps.
MODDIR="$PIXEL9PRO_MODDIR"
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/pixel9pro_control
STATE_ROOT="${PIXEL9PRO_STATE_ROOT:-/data/adb/pixel9pro_control}"
. "$MODDIR/webroot/cgi-bin/_common.sh"
require_loopback
_events_ready=0
for _event_file in "$STATE_ROOT/system_history/events"/*; do
    if [ -s "$_event_file" ] && grep -q 'events=[1-9][0-9]*' "$_event_file" 2>/dev/null; then
        _events_ready=1
        break
    fi
done
if [ -r "$MODDIR/webroot/cgi-bin/system_history_events.sh" ] && [ "$_events_ready" -eq 1 ]; then
    exec sh "$MODDIR/webroot/cgi-bin/system_history_events.sh"
fi

ROOT="$MODDIR/.power_rank"
SNAPSHOTS="$ROOT/snapshots"
CALC="$MODDIR/scripts/system_history_calc.awk"
MAX_AGE=604800
MAX_GAP=1800
history_config_value() {
    _hsc_key="$1"; _hsc_default="$2"
    _hsc_value=$(sed -n "s/^${_hsc_key}=//p" "$STATE_ROOT/system_history_config" 2>/dev/null | head -n 1 | tr -d ' \r\n\t')
    [ -n "$_hsc_value" ] && printf '%s' "$_hsc_value" || printf '%s' "$_hsc_default"
}
history_config_enabled() {
    case "$(history_config_value analytics_enabled 1)" in 0|false|off|no) printf false ;; *) printf true ;; esac
}
history_receipt_value() { sed -n "s/^$1=//p" "$STATE_ROOT/system_history/receipt" 2>/dev/null | head -n 1 | tr -d ' \r\n\t'; }
history_policy_phase() {
    _hsc_success=$(history_receipt_value last_success_ts)
    _hsc_config_ts=$(stat -c %Y "$STATE_ROOT/system_history_config" 2>/dev/null || printf '0')
    case "$_hsc_success:$_hsc_config_ts" in
        *[!0-9:]*) printf staged ;;
        *) [ "$_hsc_success" -ge "$_hsc_config_ts" ] 2>/dev/null && printf effective || printf staged ;;
    esac
}
_fallback_off=$(sed -n 's/^system_interval_off_sec=//p' "$STATE_ROOT/system_history_config" 2>/dev/null | head -n 1 | tr -d ' \r\n\t')
case "$_fallback_off" in ''|*[!0-9]*) _fallback_off=900 ;; esac
[ "$_fallback_off" -ge 900 ] 2>/dev/null || _fallback_off=900
MAX_GAP=$((_fallback_off * 2))

json_num() { case "$1" in ''|*[!0-9.-]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }
json_escape() { printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r//g;s/\n/\\n/g'; }
query_value() { printf '%s' "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1; }
valid_epoch() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

now=$(date +%s 2>/dev/null || printf '0')
valid_epoch "$now" || now=0
end_ts=$(query_value end_ts); start_ts=$(query_value start_ts)
[ -n "$end_ts" ] || end_ts="$now"
[ -n "$start_ts" ] || start_ts=$((end_ts - 3600))
valid_epoch "$end_ts" || { json_error '400 Bad Request' 'invalid end_ts'; exit 0; }
valid_epoch "$start_ts" || { json_error '400 Bad Request' 'invalid start_ts'; exit 0; }
[ "$start_ts" -le "$end_ts" ] 2>/dev/null || { json_error '400 Bad Request' 'start_ts is after end_ts'; exit 0; }
[ "$start_ts" -ge $((end_ts - MAX_AGE)) ] 2>/dev/null || { json_error '400 Bad Request' 'history range exceeds 7 days'; exit 0; }

if [ ! -r "$CALC" ] || [ ! -d "$SNAPSHOTS" ]; then
    json_headers
    _hsc_phase=$(history_policy_phase)
    _hsc_attempt=$(history_receipt_value last_attempt_ts); _hsc_success=$(history_receipt_value last_success_ts); _hsc_result=$(history_receipt_value last_result)
    [ -n "$_hsc_attempt" ] || _hsc_attempt=null; [ -n "$_hsc_success" ] || _hsc_success=null; [ -n "$_hsc_result" ] || _hsc_result=never
    printf '{"ok":true,"schema":1,"status":"unavailable","quality":"unavailable","reason":"collector_not_installed","source":"android_batterystats","policy":{"phase":"%s","analytics_enabled":%s,"retention_days":%s,"max_bytes":%s,"module_interval_on_sec":%s,"module_interval_off_sec":%s,"system_interval_on_sec":%s,"system_interval_off_sec":%s},"collection":{"phase":"%s","last_attempt_ts":%s,"last_success_ts":%s,"last_result":"%s"},"start_ts":%s,"end_ts":%s,"coverage_sec":0,"coverage_ratio":0,"valid_samples":0,"raw_samples":0,"gap_count":0,"gaps":[],"updated_at":null,"data_revision":"none","model":"BatteryStats estimated power use","power":[]}\n' \
        "$_hsc_phase" "$(history_config_enabled)" "$(history_config_value retention_days 7)" "$(history_config_value max_bytes 33554432)" "$(history_config_value module_interval_on_sec 60)" "$(history_config_value module_interval_off_sec 900)" "$(history_config_value system_interval_on_sec 900)" "$(history_config_value system_interval_off_sec 900)" "$_hsc_phase" "$(json_num "$_hsc_attempt")" "$(json_num "$_hsc_success")" "$(json_escape "$_hsc_result")" "$(json_num "$start_ts")" "$(json_num "$end_ts")"
    exit 0
fi

tmp="$ROOT/.system_rows.$$"
sorted="$ROOT/.system_rows_sorted.$$"
out="$ROOT/.system_history_result.$$"
trap 'rm -f "$tmp" "$sorted" "$out" 2>/dev/null' EXIT INT TERM HUP
mkdir -p "$ROOT" 2>/dev/null || json_error '500 Internal Server Error' 'cannot create system history state'
: > "$tmp" 2>/dev/null || json_error '500 Internal Server Error' 'cannot create system history rows'

for file in "$SNAPSHOTS"/*; do
    [ -f "$file" ] || continue
    name=$(basename "$file")
    stamp=$(printf '%s' "$name" | cut -d_ -f1)
    case "$stamp" in ''|*[!0-9]*) continue ;; esac
    [ "$stamp" -le "$end_ts" ] 2>/dev/null || continue
    awk -F '\t' -v fallback="$stamp" '
        $1 == "meta" { boot=$2; ts=$3; clock=$4; screen=$5; doze=$6; next }
        $1 == "app" && $4 ~ /^[0-9]+(\.[0-9]+)?$/ { app_total += $4; app_count++; next }
        $1 == "component" && $4 ~ /^[0-9]+(\.[0-9]+)?$/ { component_total += $4; component_count++; next }
        END {
            if (ts !~ /^[0-9]+$/) ts=fallback
            if (app_count > 0) total=app_total; else total=component_total
            if (ts ~ /^[0-9]+$/ && boot != "" && total >= 0) printf "%s\t%s\t%.6f\t%s\t%s\t%s\n", ts, boot, total, screen, doze, clock
        }
    ' "$file" >> "$tmp" 2>/dev/null
done

sort -n -k1,1 "$tmp" > "$sorted" 2>/dev/null || cp "$tmp" "$sorted" 2>/dev/null
awk -F '\t' -v start_ts="$start_ts" -v end_ts="$end_ts" -v max_gap="$MAX_GAP" -f "$CALC" "$sorted" > "$out" 2>/dev/null

TAB=$(printf '\t')
meta=$(sed -n '/^meta'"$TAB"'/p' "$out" 2>/dev/null | tail -n 1)
IFS="$TAB" read -r _meta _status quality reason coverage valid_samples raw_samples updated gap_count <<EOF
$meta
EOF
[ -n "$_status" ] || _status=unavailable
[ -n "$quality" ] || quality=unavailable
[ -n "$reason" ] || reason=need_two_same_identity_snapshots
case "$coverage" in ''|*[!0-9]*) coverage=0 ;; esac
case "$valid_samples" in ''|*[!0-9]*) valid_samples=0 ;; esac
case "$raw_samples" in ''|*[!0-9]*) raw_samples=0 ;; esac
case "$updated" in ''|*[!0-9]*) updated=0 ;; esac
case "$gap_count" in ''|*[!0-9]*) gap_count=0 ;; esac
elapsed=$((end_ts - start_ts)); [ "$elapsed" -gt 0 ] 2>/dev/null || elapsed=1
coverage_ratio=$(awk -v c="$coverage" -v e="$elapsed" 'BEGIN { r=c/e; if (r<0) r=0; if (r>1) r=1; printf "%.3f", r }')

points=''
gaps=''
while IFS="$TAB" read -r kind ts boot screen doze total rate interval valid point_quality; do
    if [ "$kind" = point ]; then
        [ -z "$points" ] || points="$points,"
        rate_json=$(json_num "$rate")
        point_json=$(printf '{"ts":%s,"system_mah":%s,"system_rate_mah_h":%s,"interval_sec":%s,"screen":"%s","doze":"%s","boot_id":"%s","source":"android_batterystats","valid":%s,"quality":"%s"}' \
            "$(json_num "$ts")" "$(json_num "$total")" "$rate_json" "$(json_num "$interval")" \
            "$(json_escape "$screen")" "$(json_escape "$doze")" "$(json_escape "$boot")" \
            "$([ "$valid" = 1 ] && printf true || printf false)" "$(json_escape "$point_quality")")
        points="$points$point_json"
    elif [ "$kind" = gap ]; then
        [ -z "$gaps" ] || gaps="$gaps,"
        gap_json=$(printf '{"start_ts":%s,"end_ts":%s,"reason":"%s"}' "$(json_num "$ts")" "$(json_num "$boot")" "$(json_escape "$screen")")
        gaps="$gaps$gap_json"
    fi
done < "$out"

_hsc_phase=$(history_policy_phase)
_hsc_attempt=$(history_receipt_value last_attempt_ts); _hsc_success=$(history_receipt_value last_success_ts); _hsc_result=$(history_receipt_value last_result)
[ -n "$_hsc_attempt" ] || _hsc_attempt=null; [ -n "$_hsc_success" ] || _hsc_success=null; [ -n "$_hsc_result" ] || _hsc_result=never
json_headers
printf '{"ok":true,"schema":1,"status":"%s","quality":"%s","reason":"%s","source":"android_batterystats","model":"BatteryStats estimated power use","policy":{"phase":"%s","analytics_enabled":%s,"retention_days":%s,"max_bytes":%s,"module_interval_on_sec":%s,"module_interval_off_sec":%s,"system_interval_on_sec":%s,"system_interval_off_sec":%s},"collection":{"phase":"%s","last_attempt_ts":%s,"last_success_ts":%s,"last_result":"%s"},"start_ts":%s,"end_ts":%s,"coverage_sec":%s,"coverage_ratio":%s,"valid_samples":%s,"raw_samples":%s,"gap_count":%s,"gaps":[%s],"updated_at":%s,"data_revision":"%s:%s:%s","window":{"start_ts":%s,"end_ts":%s,"coverage_ratio":%s,"valid_samples":%s,"raw_samples":%s,"gap_count":%s,"quality":"%s"},"power":[%s]}\n' \
    "$(json_escape "$_status")" "$(json_escape "$quality")" "$(json_escape "$reason")" "$_hsc_phase" "$(history_config_enabled)" "$(history_config_value retention_days 7)" "$(history_config_value max_bytes 33554432)" "$(history_config_value module_interval_on_sec 60)" "$(history_config_value module_interval_off_sec 900)" "$(history_config_value system_interval_on_sec 900)" "$(history_config_value system_interval_off_sec 900)" "$_hsc_phase" "$(json_num "$_hsc_attempt")" "$(json_num "$_hsc_success")" "$(json_escape "$_hsc_result")" \
    "$(json_num "$start_ts")" "$(json_num "$end_ts")" "$(json_num "$coverage")" "$coverage_ratio" \
    "$(json_num "$valid_samples")" "$(json_num "$raw_samples")" "$(json_num "$gap_count")" "$gaps" "$(json_num "$updated")" \
    "$(json_escape "$_status")" "$(json_escape "$quality")" "$(json_num "$updated")" \
    "$(json_num "$start_ts")" "$(json_num "$end_ts")" "$coverage_ratio" "$(json_num "$valid_samples")" "$(json_num "$raw_samples")" "$(json_num "$gap_count")" "$(json_escape "$quality")" "$points"
