#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/history_export.sh
# POST JSON {"minutes":15|30|60} or {"mode":"session","start_ts":epoch}
# 手动导出模块功耗/温度历史到 /sdcard/Download
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback
require_json_post
require_token

POWER_HISTORY="$MODDIR/.power_history"
THERMAL_HISTORY="$MODDIR/.thermal_history"
DOWNLOAD_DIR="/sdcard/Download"

len="${CONTENT_LENGTH:-0}"
case "$len" in ''|*[!0-9]*) len=0 ;; esac
[ "$len" -gt 1024 ] 2>/dev/null && len=1024
body=$(dd bs=1 count="$len" 2>/dev/null)

now=$(date +%s 2>/dev/null || echo 0)
mode=$(printf '%s' "$body" | sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([a-zA-Z0-9_]*\)".*/\1/p')
minutes=$(printf '%s' "$body" | sed -n 's/.*"minutes"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
start_ts=$(printf '%s' "$body" | sed -n 's/.*"start_ts"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')

export_mode="minutes"
window_label=""
case "$mode" in
    session)
        case "$start_ts" in
            ''|*[!0-9]*) json_error '400 Bad Request' 'invalid session start_ts' ;;
        esac
        [ "$start_ts" -gt "$now" ] 2>/dev/null && start_ts="$now"
        cutoff="$start_ts"
        minutes=""
        export_mode="session"
        window_label="current_webui_window"
        suffix="session"
        ;;
    *)
        case "$minutes" in
            15|30|60) ;;
            *) minutes=30 ;;
        esac
        cutoff=$((now - minutes * 60))
        window_label="last_${minutes}_minutes"
        suffix="${minutes}min"
        ;;
esac

elapsed_sec=$((now - cutoff))
[ "$elapsed_sec" -lt 0 ] 2>/dev/null && elapsed_sec=0
stamp=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo "$now")
mkdir -p "$DOWNLOAD_DIR" 2>/dev/null || json_error '500 Internal Server Error' 'cannot create Download directory'

out="$DOWNLOAD_DIR/pixel9pro_history_${stamp}_${suffix}.md"
tmp="${out}.tmp.$$"

power_samples=0
thermal_samples=0
[ -s "$POWER_HISTORY" ] && power_samples=$(awk -F, -v cutoff="$cutoff" '$1 + 0 >= cutoff { n++ } END { print n + 0 }' "$POWER_HISTORY" 2>/dev/null)
[ -s "$THERMAL_HISTORY" ] && thermal_samples=$(awk -F, -v cutoff="$cutoff" '$1 + 0 >= cutoff && $2 + 0 > 0 { n++ } END { print n + 0 }' "$THERMAL_HISTORY" 2>/dev/null)
case "$power_samples" in ''|*[!0-9]*) power_samples=0 ;; esac
case "$thermal_samples" in ''|*[!0-9]*) thermal_samples=0 ;; esac

battery_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null | tr -d '\r')
battery_level=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null | tr -d ' \n\r')
charge_uah=$(cat /sys/class/power_supply/battery/charge_counter 2>/dev/null | tr -d ' \n\r')

if {
    printf '# Pixel 9 Pro History Export\n\n'
    printf '- generated_at_epoch: %s\n' "$now"
    printf '- export_mode: %s\n' "$export_mode"
    printf '- window_label: %s\n' "$window_label"
    if [ -n "$minutes" ]; then
        printf '- window_minutes: %s\n' "$minutes"
    else
        printf '- window_minutes: session\n'
    fi
    printf '- window_start_epoch: %s\n' "$cutoff"
    printf '- window_elapsed_sec: %s\n' "$elapsed_sec"
    printf '- cutoff_epoch: %s\n' "$cutoff"
    printf '- battery_status: %s\n' "${battery_status:-Unknown}"
    printf '- battery_level: %s\n' "${battery_level:-unknown}"
    printf '- charge_counter_uah: %s\n' "${charge_uah:-unknown}"
    printf '- power_samples: %s\n' "$power_samples"
    printf '- thermal_samples: %s\n\n' "$thermal_samples"

    printf '## Power History CSV\n\n'
    printf 'Columns: `ts,level,charge_uah,status`\n\n'
    printf '```csv\n'
    printf 'ts,level,charge_uah,status\n'
    if [ -s "$POWER_HISTORY" ]; then
        awk -F, -v cutoff="$cutoff" '$1 + 0 >= cutoff { print }' "$POWER_HISTORY" 2>/dev/null
    fi
    printf '```\n\n'

    printf '## Thermal History CSV\n\n'
    printf 'Columns: `ts,virtual_skin_millicelsius`\n\n'
    printf '```csv\n'
    printf 'ts,virtual_skin_millicelsius\n'
    if [ -s "$THERMAL_HISTORY" ]; then
        awk -F, -v cutoff="$cutoff" '$1 + 0 >= cutoff && $2 + 0 > 0 { print }' "$THERMAL_HISTORY" 2>/dev/null
    fi
    printf '```\n'
} > "$tmp" 2>/dev/null; then
    mv "$tmp" "$out" 2>/dev/null || json_error '500 Internal Server Error' 'cannot finalize export'
else
    json_error '500 Internal Server Error' 'cannot write export'
fi

json_headers
if [ -n "$minutes" ]; then
    minutes_json="$minutes"
else
    minutes_json="null"
fi
printf '{"ok":true,"path":"%s","mode":"%s","window_label":"%s","start_ts":%s,"elapsed_sec":%s,"minutes":%s,"power_samples":%s,"thermal_samples":%s}\n' \
    "$(json_escape "$out")" "$export_mode" "$window_label" "$cutoff" "$elapsed_sec" "$minutes_json" "$power_samples" "$thermal_samples"
