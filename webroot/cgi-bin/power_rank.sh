#!/system/bin/sh

# Read-only selected-window power attribution. BatteryStats collection is done
# by the detached service collector, never on the WebUI request path.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback

MODDIR="${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}"
ROOT="$MODDIR/.power_rank"
SNAPSHOTS="$ROOT/snapshots"
CALC="$MODDIR/scripts/power_rank_calc.awk"
MAX_AGE=604800

json_num() { case "$1" in ''|*[!0-9.-]*) printf null ;; *) printf '%s' "$1" ;; esac; }
json_escape() { printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r//g;s/\n/\\n/g'; }
query_value() { printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1; }
valid_epoch() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

now=$(date +%s 2>/dev/null || printf 0)
valid_epoch "$now" || now=0
end_ts=$(query_value end_ts); start_ts=$(query_value start_ts); granularity=$(query_value granularity)
[ -n "$end_ts" ] || end_ts="$now"
valid_epoch "$end_ts" || { json_error '400 Bad Request' 'invalid end_ts'; exit 0; }
[ -n "$start_ts" ] || start_ts=$((end_ts - 3600))
valid_epoch "$start_ts" || { json_error '400 Bad Request' 'invalid start_ts'; exit 0; }
[ "$start_ts" -le "$end_ts" ] 2>/dev/null || { json_error '400 Bad Request' 'start_ts is after end_ts'; exit 0; }
[ "$start_ts" -ge $((end_ts - MAX_AGE)) ] 2>/dev/null || { json_error '400 Bad Request' 'history range exceeds 7 days'; exit 0; }
case "$granularity" in
    raw) granularity=hour ;;  # legacy system-history callers used raw
    ''|minute|hour) ;;
    *) json_error '400 Bad Request' 'invalid granularity'; exit 0 ;;
esac

if [ ! -r "$CALC" ] || [ ! -d "$SNAPSHOTS" ]; then
    json_headers
    printf '{"ok":true,"schema":1,"status":"unavailable","quality":"unavailable","reason":"collector_not_installed","source":"power_rank_snapshot","start_ts":%s,"end_ts":%s,"granularity":"%s","coverage_sec":0,"coverage_ratio":0,"valid_intervals":0,"valid_samples":0,"raw_samples":0,"gap_count":0,"gaps":[],"updated_at":null,"data_revision":"none","cache":{"hit":false},"apps":[],"components":[]}\n' \
        "$(json_num "$start_ts")" "$(json_num "$end_ts")" "$(json_escape "$granularity")"
    exit 0
fi

tmp="$ROOT/.rank_query.$$"; files="$ROOT/.rank_files.$$"; ledger_tmp="$ROOT/.rank_ledger.$$"; out="$ROOT/.rank_result.$$"; response_tmp="$ROOT/.rank_response.$$"
ledger="$ROOT/ledger.tsv"
trap 'rm -f "$tmp" "$files" "$ledger_tmp" "$out" "$response_tmp" 2>/dev/null' EXIT INT TERM HUP
mkdir -p "$ROOT" 2>/dev/null || json_error '500 Internal Server Error' 'cannot create power rank state'

for file in "$SNAPSHOTS"/*; do
    [ -f "$file" ] || continue
    name=${file##*/}; stamp=${name%%_*}
    case "$stamp" in ''|*[!0-9]*) continue ;; esac
    [ "$stamp" -le "$end_ts" ] 2>/dev/null && printf '%s\t%s\n' "$stamp" "$file"
done | sort -n -k1,1 > "$tmp"

# Keep only the selected window plus its nearest pre-window baseline. Reading
# every retained snapshot through a separate shell `cat` made the CGI exceed
# the WebUI timeout once the seven-day ledger reached a few hundred files.
awk -F '\t' -v start_ts="$start_ts" -v end_ts="$end_ts" '
    $1 < start_ts { baseline=$0; next }
    $1 <= end_ts { if (baseline != "" && !emitted) { print baseline; emitted=1 } print }
' "$tmp" | cut -f2- > "$files"

selected_count=$(awk -F '\t' -v start_ts="$start_ts" -v end_ts="$end_ts" '$1 >= start_ts && $1 <= end_ts { n++ } END { print n + 0 }' "$tmp" 2>/dev/null)
case "$selected_count" in ''|*[!0-9]*) selected_count=0 ;; esac
count=$(wc -l < "$files" 2>/dev/null | tr -d ' \r\n')
case "$count" in ''|*[!0-9]*) count=0 ;; esac
if [ "$selected_count" -lt 2 ] 2>/dev/null; then
    json_headers
    printf '{"ok":true,"schema":1,"status":"unavailable","quality":"unavailable","reason":"need_two_selected_snapshots","source":"power_rank_snapshot","start_ts":%s,"end_ts":%s,"granularity":"%s","coverage_sec":0,"coverage_ratio":0,"valid_intervals":0,"valid_samples":0,"raw_samples":%s,"selected_snapshots":%s,"gap_count":0,"gaps":[],"updated_at":null,"data_revision":"empty","cache":{"hit":false},"apps":[],"components":[]}\n' \
        "$(json_num "$start_ts")" "$(json_num "$end_ts")" "$(json_escape "$granularity")" "$(json_num "$selected_count")" "$(json_num "$selected_count")"
    exit 0
fi

latest_stamp=0
while IFS= read -r file; do
    name=${file##*/}; stamp=${name%%_*}
    case "$stamp" in ''|*[!0-9]*) continue ;; esac
    [ "$stamp" -gt "$latest_stamp" ] 2>/dev/null && latest_stamp="$stamp"
done < "$files"
_rank_policy_revision="$(sed -n 's/^system_interval_on_sec=//p' "${PIXEL9PRO_STATE_ROOT:-/data/adb/pixel9pro_control}/system_history_config" 2>/dev/null | head -n 1)_$(sed -n 's/^system_interval_off_sec=//p' "${PIXEL9PRO_STATE_ROOT:-/data/adb/pixel9pro_control}/system_history_config" 2>/dev/null | head -n 1)"
case "$_rank_policy_revision" in *[!0-9_]*) _rank_policy_revision=default ;; esac
mkdir -p "$ROOT/cache" 2>/dev/null || json_error '500 Internal Server Error' 'cannot create power rank cache'
cache_file="$ROOT/cache/v2_${start_ts}_${end_ts}_${latest_stamp}_${granularity}_${_rank_policy_revision}.json"
if [ -s "$cache_file" ]; then
    sed 's/"hit":false/"hit":true/' "$cache_file" 2>/dev/null
    exit 0
fi

ledger_ready=0
if [ -s "$ledger" ]; then
    ledger_latest=$(awk -F '\t' '$1 == "meta" { latest=$3 } END { print latest + 0 }' "$ledger" 2>/dev/null)
    case "$ledger_latest" in ''|*[!0-9]*) ledger_latest=0 ;; esac
    [ "$ledger_latest" -ge "$latest_stamp" ] 2>/dev/null && ledger_ready=1
fi
if [ "$ledger_ready" -ne 1 ]; then
    : > "$ledger_tmp" 2>/dev/null || json_error '500 Internal Server Error' 'cannot create power rank ledger'
    while IFS= read -r file; do
        [ -r "$file" ] || json_error '500 Internal Server Error' 'power rank snapshot missing'
        cat "$file" >> "$ledger_tmp" 2>/dev/null || json_error '500 Internal Server Error' 'cannot read power rank snapshot'
    done < "$files"
    _ledger_commit_tmp="${ledger}.tmp.$$"
    if cp "$ledger_tmp" "$_ledger_commit_tmp" 2>/dev/null && mv "$_ledger_commit_tmp" "$ledger" 2>/dev/null; then
        ledger="$ledger"
    else
        rm -f "$_ledger_commit_tmp" 2>/dev/null
        ledger="$ledger_tmp"
    fi
fi
_rank_max_gap=$(awk -v on="$(sed -n 's/^system_interval_on_sec=//p' "${PIXEL9PRO_STATE_ROOT:-/data/adb/pixel9pro_control}/system_history_config" 2>/dev/null | head -n 1)" -v off="$(sed -n 's/^system_interval_off_sec=//p' "${PIXEL9PRO_STATE_ROOT:-/data/adb/pixel9pro_control}/system_history_config" 2>/dev/null | head -n 1)" 'BEGIN { if(on<900)on=900; if(off<900)off=900; m=(on>off?on:off)*2+120; if(m<1800)m=1800; print m }')
if ! awk -F '\t' -v start_ts="$start_ts" -v end_ts="$end_ts" -v max_gap="$_rank_max_gap" \
    -f "$CALC" "$ledger" > "$out" 2>/dev/null; then
    json_error '500 Internal Server Error' 'power rank calculation failed: collector_calc_failed'
fi
[ -s "$out" ] || json_error '500 Internal Server Error' 'power rank calculation returned no data: collector_calc_empty'
meta=$(sed -n '/^meta[[:space:]]/p' "$out" 2>/dev/null | tail -n 1)
TAB=$(printf '\t')
IFS="$TAB" read -r _ status quality reason coverage valid_intervals snapshots updated revision observed_start observed_end reference_seen reference_start reference_end boot_transitions <<EOF
$meta
EOF
[ -n "$status" ] || status=unavailable; [ -n "$quality" ] || quality=unavailable
[ -n "$reason" ] || reason=collector_no_window; [ -n "$coverage" ] || coverage=0
[ -n "$valid_intervals" ] || valid_intervals=0; [ -n "$updated" ] || updated=0
[ -n "$boot_transitions" ] || boot_transitions=0
case "$reference_seen" in
    1) window_proven=false; attribution_state=reference_baseline ;;
    *) window_proven=true; attribution_state=selected_window ;;
esac
elapsed=$((end_ts - start_ts)); [ "$elapsed" -gt 0 ] 2>/dev/null || elapsed=1
coverage_ratio=$(awk -v c="$coverage" -v e="$elapsed" 'BEGIN { r=c/e; if(r<0)r=0; if(r>1)r=1; printf "%.3f",r }')
revision="${status}:${quality}:${updated}:${valid_intervals}:${granularity}"
gap_count=$(awk -F '\t' '$1 == "gap" { n++ } END { print n + 0 }' "$out" 2>/dev/null)
case "$gap_count" in ''|*[!0-9]*) gap_count=0 ;; esac
gaps=''; gap_first=1
while IFS="$TAB" read -r gap_kind gap_start gap_end gap_reason; do
    [ "$gap_kind" = gap ] || continue
    [ "$gap_first" -eq 1 ] || gaps="$gaps,"
    gap_first=0
    gaps="${gaps}{\"start_ts\":$(json_num "$gap_start"),\"end_ts\":$(json_num "$gap_end"),\"reason\":\"$(json_escape "$gap_reason")\"}"
done < "$out"

apps=''; components=''
while IFS="$TAB" read -r kind key label value; do
    case "$kind" in
        app)
            case "$value" in ''|*[!0-9.]*) continue ;; esac
            [ -z "$apps" ] || apps="$apps,"
            apps="${apps}{\"uid\":\"$(json_escape "$key")\",\"pkg\":\"$(json_escape "$label")\",\"label\":\"$(json_escape "$label")\",\"mah\":$value}"
            ;;
        component)
            case "$value" in ''|*[!0-9.]*) continue ;; esac
            [ -z "$components" ] || components="$components,"
            components="${components}{\"key\":\"$(json_escape "$key")\",\"label\":\"$(json_escape "$label")\",\"mah\":$value}"
            ;;
    esac
done < "$out"

{
json_headers
printf '{"ok":true,"schema":1,"status":"%s","quality":"%s","reason":"%s","attribution_state":"%s","window_proven":%s,"observed_start_ts":%s,"observed_end_ts":%s,"reference_start_ts":%s,"reference_end_ts":%s,"source":"power_rank_snapshot","start_ts":%s,"end_ts":%s,"granularity":"%s","coverage_sec":%s,"coverage_ratio":%s,"valid_intervals":%s,"valid_samples":%s,"raw_samples":%s,"selected_snapshots":%s,"boot_transition_count":%s,"gap_count":%s,"gaps":[%s],"updated_at":%s,"data_revision":"%s","cache":{"hit":false},"total_mah":null,"apps":[%s],"components":[%s]}\n' \
    "$(json_escape "$status")" "$(json_escape "$quality")" "$(json_escape "$reason")" "$(json_escape "$attribution_state")" "$window_proven" "$(json_num "$observed_start")" "$(json_num "$observed_end")" "$(json_num "$reference_start")" "$(json_num "$reference_end")" \
    "$(json_num "$start_ts")" "$(json_num "$end_ts")" "$(json_escape "$granularity")" "$(json_num "$coverage")" "$coverage_ratio" \
    "$(json_num "$valid_intervals")" "$(json_num "$valid_intervals")" "$(json_num "$snapshots")" "$(json_num "$selected_count")" "$(json_num "$boot_transitions")" "$gap_count" "$gaps" "$(json_num "$updated")" "$(json_escape "$revision")" "$apps" "$components"
} > "$response_tmp" 2>/dev/null || json_error '500 Internal Server Error' 'cannot serialize power rank response'
if mv "$response_tmp" "$cache_file" 2>/dev/null; then
    cat "$cache_file"
else
    cat "$response_tmp" 2>/dev/null
fi
