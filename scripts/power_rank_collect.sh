#!/system/bin/sh
# Capture one immutable BatteryStats power-ranking snapshot.
# The service may call this on every worker cycle; the script self-throttles.

MODDIR="${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}"
ROOT="$MODDIR/.power_rank"
SNAPSHOTS="$ROOT/snapshots"
LOCK="$ROOT/collect.lock"
LAST="$ROOT/last_collect_ts"
PARSER="$MODDIR/scripts/power_rank_parse.awk"
INTERVAL=900
RETENTION=604800

case "$MODDIR:$ROOT:$PARSER" in *..*|*' '*|*\\*) exit 2 ;; esac
[ -r "$PARSER" ] || exit 3
mkdir -p "$SNAPSHOTS" 2>/dev/null || exit 4

if ! mkdir "$LOCK" 2>/dev/null; then
    exit 0
fi
cleanup() { rmdir "$LOCK" 2>/dev/null || rm -rf "$LOCK" 2>/dev/null; }
trap cleanup EXIT INT TERM HUP

now=$(date +%s 2>/dev/null || printf 0)
case "$now" in ''|*[!0-9]*) exit 5 ;; esac
last=$(cat "$LAST" 2>/dev/null | tr -d ' \n\r\t')
case "$last" in ''|*[!0-9]*) last=0 ;; esac
[ $((now - last)) -ge "$INTERVAL" ] 2>/dev/null || exit 0

boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')
case "$boot_id" in ''|*[!A-Za-z0-9-]*) exit 6 ;; esac
raw="$ROOT/.checkin.$$"
parsed="$ROOT/.snapshot.$$"
trap 'rm -f "$raw" "$parsed" 2>/dev/null; cleanup' EXIT INT TERM HUP

# --charged is the supported cumulative BatteryStats view. A failed or
# incomplete dump is never turned into a zero snapshot.
dumpsys batterystats --charged --checkin > "$raw" 2>/dev/null || exit 7
[ -s "$raw" ] || exit 8
awk -v boot_id="$boot_id" -v capture_ts="$now" -f "$PARSER" "$raw" > "$parsed" 2>/dev/null || exit 9

meta=$(sed -n '1p' "$parsed" 2>/dev/null)
clock=$(printf '%s' "$meta" | awk -F '\t' '{print $4}')
case "$clock" in ''|*[!0-9]*) exit 10 ;; esac
printf '%s\n' "$meta" | awk -F '\t' '$1 == "meta" { ok=1 } END { exit(ok ? 0 : 1) }' || exit 11

final="$SNAPSHOTS/${now}_${boot_id}"
[ ! -e "$final" ] || exit 0
mv "$parsed" "$final" 2>/dev/null || exit 12
printf '%s\n' "$now" > "$LAST" 2>/dev/null || exit 13

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
exit 0
