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
case "$granularity" in ''|minute|hour) ;; *) json_error '400 Bad Request' 'invalid granularity'; exit 0 ;; esac

json_headers
if [ ! -r "$CALC" ] || [ ! -d "$SNAPSHOTS" ]; then
    printf '{"ok":true,"schema":1,"status":"unavailable","quality":"unavailable","reason":"collector_not_installed","source":"power_rank_snapshot","start_ts":%s,"end_ts":%s,"granularity":"%s","coverage_sec":0,"coverage_ratio":0,"valid_intervals":0,"valid_samples":0,"raw_samples":0,"gap_count":0,"gaps":[],"updated_at":null,"data_revision":"none","cache":{"hit":false},"apps":[],"components":[]}\n' \
        "$(json_num "$start_ts")" "$(json_num "$end_ts")" "$(json_escape "$granularity")"
    exit 0
fi

tmp="$ROOT/.rank_query.$$"; ledger="$ROOT/.rank_ledger.$$"; out="$ROOT/.rank_result.$$"
trap 'rm -f "$tmp" "$ledger" "$out" 2>/dev/null' EXIT INT TERM HUP
mkdir -p "$ROOT" 2>/dev/null || { printf '{"ok":false,"error":"cannot create power rank state"}\n'; exit 0; }

for file in "$SNAPSHOTS"/*; do
    [ -f "$file" ] || continue
    name=${file##*/}; stamp=${name%%_*}
    case "$stamp" in ''|*[!0-9]*) continue ;; esac
    [ "$stamp" -le "$end_ts" ] 2>/dev/null && printf '%s\t%s\n' "$stamp" "$file"
done | sort -n -k1,1 | cut -f2- > "$tmp"

count=$(wc -l < "$tmp" 2>/dev/null | tr -d ' \r\n')
case "$count" in ''|*[!0-9]*) count=0 ;; esac
if [ "$count" -lt 2 ] 2>/dev/null; then
    printf '{"ok":true,"schema":1,"status":"unavailable","quality":"unavailable","reason":"need_two_snapshots","source":"power_rank_snapshot","start_ts":%s,"end_ts":%s,"granularity":"%s","coverage_sec":0,"coverage_ratio":0,"valid_intervals":0,"valid_samples":0,"raw_samples":0,"gap_count":0,"gaps":[],"updated_at":null,"data_revision":"empty","cache":{"hit":false},"apps":[],"components":[]}\n' \
        "$(json_num "$start_ts")" "$(json_num "$end_ts")" "$(json_escape "$granularity")"
    exit 0
fi

: > "$ledger" 2>/dev/null || { printf '{"ok":false,"error":"cannot create power rank ledger"}\n'; exit 0; }
while IFS= read -r file; do
    [ -r "$file" ] || continue
    cat "$file" >> "$ledger" 2>/dev/null || true
done < "$tmp"
awk -F '\t' -v start_ts="$start_ts" -v end_ts="$end_ts" \
    -v max_gap=1800 -f "$CALC" "$ledger" > "$out" 2>/dev/null
meta=$(sed -n '/^meta[[:space:]]/p' "$out" 2>/dev/null | tail -n 1)
TAB=$(printf '\t')
IFS="$TAB" read -r _ status quality reason coverage valid_intervals snapshots updated revision <<EOF
$meta
EOF
[ -n "$status" ] || status=unavailable; [ -n "$quality" ] || quality=unavailable
[ -n "$reason" ] || reason=collector_no_window; [ -n "$coverage" ] || coverage=0
[ -n "$valid_intervals" ] || valid_intervals=0; [ -n "$updated" ] || updated=0
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

printf '{"ok":true,"schema":1,"status":"%s","quality":"%s","reason":"%s","source":"power_rank_snapshot","start_ts":%s,"end_ts":%s,"granularity":"%s","coverage_sec":%s,"coverage_ratio":%s,"valid_intervals":%s,"valid_samples":%s,"raw_samples":%s,"gap_count":%s,"gaps":[%s],"updated_at":%s,"data_revision":"%s","cache":{"hit":false},"total_mah":null,"apps":[%s],"components":[%s]}\n' \
    "$(json_escape "$status")" "$(json_escape "$quality")" "$(json_escape "$reason")" \
    "$(json_num "$start_ts")" "$(json_num "$end_ts")" "$(json_escape "$granularity")" "$(json_num "$coverage")" "$coverage_ratio" \
    "$(json_num "$valid_intervals")" "$(json_num "$valid_intervals")" "$(json_num "$snapshots")" "$gap_count" "$gaps" "$(json_num "$updated")" "$(json_escape "$revision")" "$apps" "$components"
