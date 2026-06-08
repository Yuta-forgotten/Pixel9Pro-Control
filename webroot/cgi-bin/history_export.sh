#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/history_export.sh
# POST JSON {"minutes":15|30|60}
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

minutes=$(printf '%s' "$body" | sed -n 's/.*"minutes"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
case "$minutes" in
    15|30|60) ;;
    *) minutes=30 ;;
esac

now=$(date +%s 2>/dev/null || echo 0)
cutoff=$((now - minutes * 60))
stamp=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo "$now")
mkdir -p "$DOWNLOAD_DIR" 2>/dev/null || json_error '500 Internal Server Error' 'cannot create Download directory'

out="$DOWNLOAD_DIR/pixel9pro_history_${stamp}_${minutes}min.md"
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
    printf '- window_minutes: %s\n' "$minutes"
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
printf '{"ok":true,"path":"%s","minutes":%s,"power_samples":%s,"thermal_samples":%s}\n' \
    "$(json_escape "$out")" "$minutes" "$power_samples" "$thermal_samples"
