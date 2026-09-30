#!/system/bin/sh
# Capture one immutable Android BatteryStats snapshot.
# The service may call this on every worker cycle, including screen-off; the
# script self-throttles and records the display/Doze state supplied by caller.

MODDIR="${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}"
ROOT="$MODDIR/.power_rank"
SNAPSHOTS="$ROOT/snapshots"
LOCK="$ROOT/collect.lock"
LAST="$ROOT/last_collect_ts"
PARSER="$MODDIR/scripts/power_rank_parse.awk"
HISTORY_PARSER="$MODDIR/scripts/system_history_parse.awk"
STATE_ROOT="${PIXEL9PRO_STATE_ROOT:-/data/adb/pixel9pro_control}"
HISTORY_ROOT="$STATE_ROOT/system_history"
HISTORY_EVENTS="$HISTORY_ROOT/events"
HISTORY_CONFIG="$STATE_ROOT/system_history_config"
HISTORY_RECEIPT="$HISTORY_ROOT/receipt"
screen_state="${1:-unknown}"
doze_state="${2:-unknown}"
case "$screen_state" in on|off|unknown) ;; *) screen_state=unknown ;; esac
case "$doze_state" in interactive|doze|off|unknown) ;; *) doze_state=unknown ;; esac
INTERVAL=900
RETENTION=604800
MAX_BYTES=33554432
SNAPSHOT_MAX_BYTES=33554432

history_config_value() {
    _hcv_key="$1"
    _hcv_default="$2"
    _hcv_value=$(sed -n "s/^${_hcv_key}=//p" "$HISTORY_CONFIG" 2>/dev/null | head -n 1 | tr -d ' \r\n\t')
    [ -n "$_hcv_value" ] && printf '%s' "$_hcv_value" || printf '%s' "$_hcv_default"
}

retention_days=$(history_config_value retention_days 7)
case "$retention_days" in ''|*[!0-9]*) retention_days=7 ;; esac
[ "$retention_days" -ge 1 ] 2>/dev/null || retention_days=1
[ "$retention_days" -le 7 ] 2>/dev/null || retention_days=7
RETENTION=$((retention_days * 86400))
max_bytes=$(history_config_value max_bytes "$MAX_BYTES")
case "$max_bytes" in ''|*[!0-9]*) max_bytes="$MAX_BYTES" ;; esac
[ "$max_bytes" -ge 4194304 ] 2>/dev/null || max_bytes=4194304
[ "$max_bytes" -le 33554432 ] 2>/dev/null || max_bytes=33554432
MAX_BYTES="$max_bytes"
if [ "$screen_state" = on ]; then
    INTERVAL=$(history_config_value system_interval_on_sec 900)
else
    INTERVAL=$(history_config_value system_interval_off_sec 900)
fi
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=900 ;; esac
[ "$INTERVAL" -ge 300 ] 2>/dev/null || INTERVAL=300
[ "$INTERVAL" -le 7200 ] 2>/dev/null || INTERVAL=7200

case "$MODDIR:$ROOT:$PARSER" in *..*|*' '*|*\\*) exit 2 ;; esac
[ -r "$PARSER" ] || exit 3
[ -r "$HISTORY_PARSER" ] || exit 3
mkdir -p "$SNAPSHOTS" "$HISTORY_EVENTS" 2>/dev/null || exit 4

if ! mkdir "$LOCK" 2>/dev/null; then
    _lock_now=$(date +%s 2>/dev/null || printf 0)
    _lock_mtime=$(stat -c %Y "$LOCK" 2>/dev/null || printf 0)
    case "$_lock_now:$_lock_mtime" in *[!0-9:]*) _lock_now=0; _lock_mtime=0 ;; esac
    if [ "$_lock_mtime" -gt 0 ] && [ $((_lock_now - _lock_mtime)) -gt $((INTERVAL * 2 + 120)) ] 2>/dev/null; then
        rmdir "$LOCK" 2>/dev/null || true
        mkdir "$LOCK" 2>/dev/null || exit 0
    else
        exit 0
    fi
fi
cleanup() { rmdir "$LOCK" 2>/dev/null || rm -rf "$LOCK" 2>/dev/null; }
trap 'collector_rc=$?; [ "$collector_rc" -eq 0 ] || { [ -n "${now:-}" ] && write_history_receipt failed 0; }; cleanup; exit "$collector_rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

write_history_receipt() {
    _hr_result="$1"
    _hr_success_ts="${2:-0}"
    _hr_tmp="${HISTORY_RECEIPT}.tmp.$$"
    {
        printf 'schema=1\nlast_attempt_ts=%s\nlast_success_ts=%s\nlast_result=%s\n' "$now" "$_hr_success_ts" "$_hr_result"
        printf 'screen=%s\ndoze=%s\nretention_days=%s\nmax_bytes=%s\ninterval_sec=%s\n' "$screen_state" "$doze_state" "$retention_days" "$MAX_BYTES" "$INTERVAL"
    } > "$_hr_tmp" 2>/dev/null && mv "$_hr_tmp" "$HISTORY_RECEIPT" 2>/dev/null || rm -f "$_hr_tmp" 2>/dev/null
}

now=$(date +%s 2>/dev/null || printf 0)
case "$now" in ''|*[!0-9]*) exit 5 ;; esac
last=$(cat "$LAST" 2>/dev/null | tr -d ' \n\r\t')
case "$last" in ''|*[!0-9]*) last=0 ;; esac
[ $((now - last)) -ge "$INTERVAL" ] 2>/dev/null || exit 0
write_history_receipt attempt 0

boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')
case "$boot_id" in ''|*[!A-Za-z0-9-]*) exit 6 ;; esac
raw="$ROOT/.checkin.$$"
parsed="$ROOT/.snapshot.$$"
history_raw="$HISTORY_ROOT/.history_raw.$$"
history_parsed="$HISTORY_ROOT/.history_parsed.$$"
trap 'collector_rc=$?; rm -f "$raw" "$parsed" "$history_raw" "$history_parsed" 2>/dev/null; [ "$collector_rc" -eq 0 ] || { [ -n "${now:-}" ] && write_history_receipt failed 0; }; cleanup; exit "$collector_rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --charged is the supported cumulative BatteryStats view. A failed or
# incomplete dump is never turned into a zero snapshot.
dumpsys batterystats --charged --checkin > "$raw" 2>/dev/null || exit 7
[ -s "$raw" ] || exit 8
awk -v boot_id="$boot_id" -v capture_ts="$now" -v screen="$screen_state" -v doze="$doze_state" -f "$PARSER" "$raw" > "$parsed" 2>/dev/null || exit 9

meta=$(sed -n '1p' "$parsed" 2>/dev/null)
clock=$(printf '%s' "$meta" | awk -F '\t' '{print $4}')
case "$clock" in ''|*[!0-9]*) exit 10 ;; esac
printf '%s\n' "$meta" | awk -F '\t' '$1 == "meta" { ok=1 } END { exit(ok ? 0 : 1) }' || exit 11

final="$SNAPSHOTS/${now}_${boot_id}"
[ ! -e "$final" ] || exit 0
mv "$parsed" "$final" 2>/dev/null || exit 12
printf '%s\n' "$now" > "$LAST" 2>/dev/null || exit 13

# Android BatteryStats owns the durable history buffer. Capture it separately
# from the charged attribution snapshot; a failed history dump never creates a
# synthetic sample and does not invalidate the attribution snapshot above.
history_result=history_failed
if dumpsys batterystats --checkin --history > "$history_raw" 2>/dev/null \
    && [ -s "$history_raw" ] \
    && awk -f "$HISTORY_PARSER" "$history_raw" > "$history_parsed" 2>/dev/null \
    && grep -q '^meta[[:space:]]' "$history_parsed" 2>/dev/null; then
    history_final="$HISTORY_EVENTS/${now}_${boot_id}"
    [ -e "$history_final" ] || mv "$history_parsed" "$history_final" 2>/dev/null
    [ -f "$history_final" ] && history_result=success
fi
write_history_receipt "$history_result" "$([ "$history_result" = success ] && printf '%s' "$now" || printf '0')"

# Keep only the seven-day retention horizon. Snapshot names start with epoch
# seconds, so this pruning never depends on file mtime or wall-clock locale.
cutoff=$((now - RETENTION))
for file in "$SNAPSHOTS"/*; do
    [ -f "$file" ] || continue
    name=${file##*/}
    stamp=${name%%_*}
    case "$stamp" in ''|*[!0-9]*) continue ;; esac
    [ "$stamp" -lt "$cutoff" ] 2>/dev/null && rm -f "$file" 2>/dev/null
done
snapshot_bytes=0
for file in "$SNAPSHOTS"/*; do
    [ -f "$file" ] || continue
    file_bytes=$(wc -c < "$file" 2>/dev/null | tr -d ' \r\n\t')
    case "$file_bytes" in ''|*[!0-9]*) file_bytes=0 ;; esac
    snapshot_bytes=$((snapshot_bytes + file_bytes))
done
for file in "$SNAPSHOTS"/*; do
    [ "$snapshot_bytes" -gt "$SNAPSHOT_MAX_BYTES" ] 2>/dev/null || break
    [ -f "$file" ] || continue
    file_bytes=$(wc -c < "$file" 2>/dev/null | tr -d ' \r\n\t')
    case "$file_bytes" in ''|*[!0-9]*) file_bytes=0 ;; esac
    rm -f "$file" 2>/dev/null
    snapshot_bytes=$((snapshot_bytes - file_bytes))
done
for file in "$HISTORY_EVENTS"/*; do
    [ -f "$file" ] || continue
    name=${file##*/}
    stamp=${name%%_*}
    case "$stamp" in ''|*[!0-9]*) continue ;; esac
    [ "$stamp" -lt "$cutoff" ] 2>/dev/null && rm -f "$file" 2>/dev/null
done
history_bytes=0
for file in "$HISTORY_EVENTS"/*; do
    [ -f "$file" ] || continue
    file_bytes=$(wc -c < "$file" 2>/dev/null | tr -d ' \r\n\t')
    case "$file_bytes" in ''|*[!0-9]*) file_bytes=0 ;; esac
    history_bytes=$((history_bytes + file_bytes))
done
for file in "$HISTORY_ROOT/cache"/*; do
    [ -f "$file" ] || continue
    file_bytes=$(wc -c < "$file" 2>/dev/null | tr -d ' \r\n\t')
    case "$file_bytes" in ''|*[!0-9]*) file_bytes=0 ;; esac
    history_bytes=$((history_bytes + file_bytes))
done
for file in "$HISTORY_EVENTS"/*; do
    [ "$history_bytes" -gt "$MAX_BYTES" ] 2>/dev/null || break
    [ -f "$file" ] || continue
    file_bytes=$(wc -c < "$file" 2>/dev/null | tr -d ' \r\n\t')
    case "$file_bytes" in ''|*[!0-9]*) file_bytes=0 ;; esac
    rm -f "$file" 2>/dev/null
    history_bytes=$((history_bytes - file_bytes))
done
for file in "$HISTORY_ROOT/cache"/*; do
    [ "$history_bytes" -gt "$MAX_BYTES" ] 2>/dev/null || break
    [ -f "$file" ] || continue
    file_bytes=$(wc -c < "$file" 2>/dev/null | tr -d ' \r\n\t')
    case "$file_bytes" in ''|*[!0-9]*) file_bytes=0 ;; esac
    rm -f "$file" 2>/dev/null
    history_bytes=$((history_bytes - file_bytes))
done
exit 0
