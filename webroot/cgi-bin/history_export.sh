#!/system/bin/sh

# Authenticated, atomic export bundle for one fixed history window.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback
require_json_post
require_token
acquire_lock history_export

POWER_HISTORY="$MODDIR/.power_history"
THERMAL_HISTORY="$MODDIR/.thermal_history"
DOWNLOAD_DIR="${PIXEL9PRO_DOWNLOAD_DIR:-/sdcard/Download}"
ENERGY_CGI="$MODDIR/webroot/cgi-bin/energy.sh"

read_json_body 1024
body="$JSON_BODY"
now=$(date +%s 2>/dev/null || printf 0)
case "$now" in ''|*[!0-9]*) now=0 ;; esac
action=$(printf '%s' "$body" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([a-zA-Z0-9_]*\)".*/\1/p')
mode=$(printf '%s' "$body" | sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([a-zA-Z0-9_]*\)".*/\1/p')
minutes=$(printf '%s' "$body" | sed -n 's/.*"minutes"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
start_ts=$(printf '%s' "$body" | sed -n 's/.*"start_ts"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
[ "$action" = export ] || json_error '400 Bad Request' 'invalid action'

export_mode=minutes
case "$mode" in
    session)
        case "$start_ts" in ''|*[!0-9]*) json_error '400 Bad Request' 'invalid session start_ts' ;; esac
        [ "$start_ts" -le "$now" ] 2>/dev/null || start_ts="$now"
        cutoff="$start_ts"
        window_label=current_webui_session
        suffix=session
        export_mode=session
        minutes_json=null
        ;;
    *)
        case "$minutes" in 15|30|60) ;; *) json_error '400 Bad Request' 'invalid minutes' ;; esac
        cutoff=$((now - minutes * 60))
        window_label="last_${minutes}_minutes"
        suffix="${minutes}min"
        minutes_json="$minutes"
        ;;
esac
elapsed_sec=$((now - cutoff))
[ "$elapsed_sec" -ge 0 ] 2>/dev/null || elapsed_sec=0

stamp=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || printf '%s' "$now")
case "$stamp:$suffix" in *[!A-Za-z0-9_:.-]*) json_error '500 Internal Server Error' 'unsafe export suffix' ;; esac
mkdir -p "$DOWNLOAD_DIR" 2>/dev/null || json_error '500 Internal Server Error' 'cannot create Download directory'
final_dir="$DOWNLOAD_DIR/pixel9pro_export_${stamp}_${suffix}_$$"
tmp_dir="$DOWNLOAD_DIR/.pixel9pro_export_${stamp}_${suffix}_$$.tmp"
case "$final_dir:$tmp_dir" in *..*|*\\*) json_error '500 Internal Server Error' 'unsafe export path' ;; esac
[ ! -e "$final_dir" ] && [ ! -e "$tmp_dir" ] || json_error '409 Conflict' 'export path already exists'
mkdir "$tmp_dir" 2>/dev/null || json_error '500 Internal Server Error' 'cannot create export transaction'
EXPORT_SUCCESS=0

export_cleanup() {
    [ -d "$tmp_dir" ] && rm -rf "$tmp_dir" 2>/dev/null || true
    [ "$EXPORT_SUCCESS" -eq 1 ] || { [ ! -d "$final_dir" ] || rm -rf "$final_dir" 2>/dev/null || true; }
    release_lock
}
trap 'export_cleanup' EXIT
trap 'export_cleanup; exit 130' INT
trap 'export_cleanup; exit 143' TERM

power_csv="$tmp_dir/power.csv"
thermal_csv="$tmp_dir/thermal.csv"
summary_json="$tmp_dir/summary.json"
energy_json="$tmp_dir/.energy.json"
attribution_csv="$tmp_dir/attribution.csv"
report_md="$tmp_dir/report.md"

{
    printf 'ts,level,charge_uah,status\n'
    [ ! -s "$POWER_HISTORY" ] \
        || awk -F, -v cutoff="$cutoff" '$1 + 0 >= cutoff { print }' "$POWER_HISTORY" 2>/dev/null
} > "$power_csv" 2>/dev/null || json_error '500 Internal Server Error' 'cannot write power CSV'
{
    printf 'ts,virtual_skin_millicelsius\n'
    [ ! -s "$THERMAL_HISTORY" ] \
        || awk -F, -v cutoff="$cutoff" '$1 + 0 >= cutoff && $2 + 0 > 0 { print }' "$THERMAL_HISTORY" 2>/dev/null
} > "$thermal_csv" 2>/dev/null || json_error '500 Internal Server Error' 'cannot write thermal CSV'

power_samples=$(( $(wc -l < "$power_csv" 2>/dev/null) - 1 ))
thermal_samples=$(( $(wc -l < "$thermal_csv" 2>/dev/null) - 1 ))
[ "$power_samples" -ge 0 ] 2>/dev/null || power_samples=0
[ "$thermal_samples" -ge 0 ] 2>/dev/null || thermal_samples=0
thermal_stats=$(awk -F, 'NR>1 { c=$2/1000; if(!n||c<min)min=c; if(!n||c>max)max=c; sum+=c; n++ } END { if(n) printf "%.2f|%.2f|%.2f",min,sum/n,max; else printf "null|null|null" }' "$thermal_csv")
thermal_min=${thermal_stats%%|*}; _thermal_rest=${thermal_stats#*|}
thermal_avg=${_thermal_rest%%|*}; thermal_max=${_thermal_rest#*|}

if [ "${PIXEL9PRO_CGI_TEST_MODE:-0}" = 1 ] && [ -r "${PIXEL9PRO_EXPORT_ENERGY_JSON:-}" ]; then
    cp "$PIXEL9PRO_EXPORT_ENERGY_JSON" "$energy_json" 2>/dev/null \
        || json_error '500 Internal Server Error' 'cannot copy test energy summary'
else
    [ -r "$ENERGY_CGI" ] || json_error '500 Internal Server Error' 'energy CGI is missing'
    _energy_response=$(REMOTE_ADDR=127.0.0.1 REQUEST_METHOD=GET QUERY_STRING= PIXEL9PRO_MODDIR="$MODDIR" \
        sh "$ENERGY_CGI" 2>/dev/null)
    printf '%s\n' "$_energy_response" | sed '1,/^[[:space:]]*\r\{0,1\}$/d' > "$energy_json" 2>/dev/null \
        || json_error '500 Internal Server Error' 'cannot capture energy summary'
fi
_summary_compact=$(tr -d '\r\n' < "$energy_json" 2>/dev/null)
case "$_summary_compact" in \{*\}) ;; *) json_error '500 Internal Server Error' 'energy summary is not JSON' ;; esac
case "$_summary_compact" in *'"ok":false'*) json_error '500 Internal Server Error' 'energy summary reported failure' ;; esac

scope_quality=$(printf '%s' "$_summary_compact" | sed -n 's/.*"scope":{[^}]*"quality":"\([^"]*\)".*/\1/p')
[ -n "$scope_quality" ] || scope_quality=unknown
coverage_ratio=$(awk -F, -v expected="$elapsed_sec" 'NR>1 { if(!first) first=$1; last=$1 } END { if(first && last && expected>0) { r=(last-first)/expected; if(r>1)r=1; if(r<0)r=0; printf "%.3f",r } else printf "0" }' "$power_csv")
odpm_total=$(printf '%s' "$_summary_compact" | sed -n 's/.*"odpm_modem":{[^}]*"total_mah":\([-0-9.][0-9.]*\).*/\1/p')
[ -n "$odpm_total" ] || odpm_total=null
odpm_quality=$(printf '%s' "$_summary_compact" | sed -n 's/.*"odpm_modem":{[^}]*"quality":"\([^"]*\)".*/\1/p')
[ -n "$odpm_quality" ] || odpm_quality=unknown
{
    printf '{"schema":1,"generated_at":%s,"window":{"mode":"%s","label":"%s","start_ts":%s,"elapsed_sec":%s,"minutes":%s},' \
        "$now" "$export_mode" "$window_label" "$cutoff" "$elapsed_sec" "$minutes_json"
    printf '"samples":{"power":%s,"thermal":%s,"coverage_ratio":%s,"scope_quality":"%s"},' \
        "$power_samples" "$thermal_samples" "$coverage_ratio" "$(json_escape "$scope_quality")"
    printf '"thermal":{"min_c":%s,"avg_c":%s,"max_c":%s},"energy":%s}\n' \
        "$thermal_min" "$thermal_avg" "$thermal_max" "$_summary_compact"
} > "$summary_json" 2>/dev/null || json_error '500 Internal Server Error' 'cannot write summary JSON'
rm -f "$energy_json" 2>/dev/null

json_number() {
    _export_key="$1"
    _export_number=$(printf '%s' "$_summary_compact" | sed -n "s/.*\"${_export_key}\":\([-0-9.][0-9.]*\).*/\1/p")
    [ -n "$_export_number" ] && printf '%s' "$_export_number" || printf null
}

csv_field() {
    _csv_value=$(printf '%s' "$1" | tr '\r\n' '  ' | sed 's/"/""/g')
    printf '"%s"' "$_csv_value"
}

{
    printf 'kind,key,label,value_mah,source\n'
    for _component in screen cpu cell wifi wakelock; do
        _component_value=$(json_number "$_component")
        [ "$_component_value" != null ] || continue
        _component_label="$_component"
        _component_source=android_batterystats
        [ "$_component" != cell ] || _component_label=mobile_radio_model
        printf 'system,'; csv_field "$_component"; printf ','; csv_field "$_component_label"; printf ',%s,' "$_component_value"; csv_field "$_component_source"; printf '\n'
    done
    _apps=$(printf '%s' "$_summary_compact" | sed -n 's/.*"apps":\[\(.*\)\],"batterystats_window".*/\1/p' | sed 's/},{/}\
{/g')
    printf '%s\n' "$_apps" | while IFS= read -r _app; do
        [ -n "$_app" ] || continue
        _app_uid=$(printf '%s' "$_app" | sed -n 's/.*"uid_num":\([-0-9][0-9]*\).*/\1/p')
        _app_pkg=$(printf '%s' "$_app" | sed -n 's/.*"pkg":"\([^"]*\)".*/\1/p')
        _app_label=$(printf '%s' "$_app" | sed -n 's/.*"label":"\([^"]*\)".*/\1/p')
        _app_mah=$(printf '%s' "$_app" | sed -n 's/.*"mah":\([-0-9.][0-9.]*\).*/\1/p')
        [ -n "$_app_mah" ] || continue
        printf 'app,'; csv_field "${_app_pkg:-uid_${_app_uid:-unknown}}"; printf ','; csv_field "${_app_label:-unknown}"; printf ',%s,' "$_app_mah"; csv_field android_batterystats_top10; printf '\n'
    done
} > "$attribution_csv" 2>/dev/null || json_error '500 Internal Server Error' 'cannot write attribution CSV'

battery_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null | tr -d '\r' | tr '\n' ' ')
battery_level=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null | tr -d ' \r\n')
{
    printf '# Pixel9Pro-Control 功耗导出\n\n'
    printf '## 窗口与质量\n\n'
    printf -- '- schema: 1\n- generated_at_epoch: %s\n- mode: %s\n- window: %s\n- start_epoch: %s\n- elapsed_sec: %s\n' "$now" "$export_mode" "$window_label" "$cutoff" "$elapsed_sec"
    printf -- '- power_samples: %s\n- thermal_samples: %s\n- scope_quality: %s\n- coverage_ratio: %s\n\n' "$power_samples" "$thermal_samples" "$scope_quality" "$coverage_ratio"
    printf '## 当前电池与温度\n\n'
    printf -- '- battery_status: %s\n- battery_level: %s\n- thermal_min_c: %s\n- thermal_avg_c: %s\n- thermal_max_c: %s\n\n' "${battery_status:-unknown}" "${battery_level:-unknown}" "$thermal_min" "$thermal_avg" "$thermal_max"
    printf '## 蜂窝与系统归因\n\n'
    printf -- '- odpm_total_mah: %s\n- odpm_quality: %s\n- 系统分项与 Top 应用见 `attribution.csv`。\n\n' "$odpm_total" "$odpm_quality"
    printf '## 文件与证据边界\n\n'
    printf -- '- `summary.json`: 完整 energy CGI 快照，含会话、15/30/60 分钟窗口、ODPM、batterystats 和 Top 10。\n'
    printf -- '- `power.csv` / `thermal.csv`: 本窗口原始采样。\n'
    printf -- '- ODPM 仅表示 modem/RFFE rail delta，不等于整机功耗。\n'
    printf -- '- Android mobile_radio 和应用归因为系统模型估算，不等于硬件电表。\n'
    printf -- '- 未导出完整 installed package list、原始 dumpsys/logcat 或设备个人标识。\n'
} > "$report_md" 2>/dev/null || json_error '500 Internal Server Error' 'cannot write report'

for _export_file in report.md summary.json power.csv thermal.csv attribution.csv; do
    [ -s "$tmp_dir/$_export_file" ] || json_error '500 Internal Server Error' "empty export file: $_export_file"
done
mv "$tmp_dir" "$final_dir" 2>/dev/null || json_error '500 Internal Server Error' 'cannot finalize export directory'

file_json=""
for _export_file in report.md summary.json power.csv thermal.csv attribution.csv; do
    _export_path="$final_dir/$_export_file"
    _export_bytes=$(wc -c < "$_export_path" 2>/dev/null | tr -d ' ')
    _export_hash=$(sha256sum "$_export_path" 2>/dev/null | awk '{print $1}')
    [ -n "$_export_bytes" ] && [ -n "$_export_hash" ] \
        || json_error '500 Internal Server Error' 'cannot hash finalized export'
    [ -z "$file_json" ] || file_json="$file_json,"
    file_json="${file_json}{\"name\":\"$_export_file\",\"bytes\":$_export_bytes,\"sha256\":\"$_export_hash\"}"
done

[ "$AUDIT_LOG_AVAILABLE" -eq 1 ] \
    && audit_log_event energy export success ENERGY_EXPORT_COMPLETE 0 >/dev/null 2>&1 \
    || true
EXPORT_SUCCESS=1
json_headers
printf '{"ok":true,"schema":1,"directory":"%s","mode":"%s","window_label":"%s","start_ts":%s,"elapsed_sec":%s,"minutes":%s,"power_samples":%s,"thermal_samples":%s,"quality":"%s","files":[%s]}\n' \
    "$(json_escape "$final_dir")" "$export_mode" "$window_label" "$cutoff" "$elapsed_sec" "$minutes_json" \
    "$power_samples" "$thermal_samples" "$(json_escape "$scope_quality")" "$file_json"
