#!/system/bin/sh
# One bounded writer shared by the service and foreground temperature reads.
if ! command -v background_tasks_enabled >/dev/null 2>&1; then
    . "${PIXEL9PRO_MODDIR:-${MODDIR:-/data/adb/modules/pixel9pro_control}}/scripts/background_tasks_lib.sh" || return 1
fi

thermal_history_record() (
    umask 077
    background_tasks_enabled || return 0
    _th_json="$1"
    _th_ts="$2"
    _th_screen="$3"
    _th_source="$4"
    _th_mod="${PIXEL9PRO_MODDIR:-${MODDIR:-/data/adb/modules/pixel9pro_control}}"
    _th_file="$_th_mod/.thermal_history"
    _th_lock="$_th_mod/.thermal_history.lock"
    case "$_th_ts" in ''|*[!0-9]*) return 1 ;; esac
    case "$_th_screen" in on|off|unknown) ;; *) return 1 ;; esac
    case "$_th_source" in hal|sysfs|cache) ;; *) return 1 ;; esac
    [ ! -d "$_th_file" ] && [ ! -L "$_th_file" ] && [ ! -L "$_th_lock" ] || return 1
    _th_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -cd 'A-Za-z0-9-')
    _th_now=$(date +%s 2>/dev/null) || return 1
    if ! mkdir "$_th_lock" 2>/dev/null; then
        module_lock_owner_alive "$_th_lock" && return 0
        _th_old_boot=$(cat "$_th_lock/boot" 2>/dev/null || true)
        _th_lock_time=$(stat -c %Y "$_th_lock" 2>/dev/null) || return 0
        case "$_th_lock_time" in ''|*[!0-9]*) return 0 ;; esac
        if { [ -n "$_th_old_boot" ] && [ "$_th_old_boot" != "$_th_boot" ]; }; then
            : # A previous boot cannot have an initializing live writer.
        elif module_lock_initializing "$_th_lock"; then
            return 0
        fi
        if [ -s "$_th_lock/owner" ] \
            || { [ -n "$_th_old_boot" ] && [ "$_th_old_boot" != "$_th_boot" ]; } \
            || [ $((_th_now - _th_lock_time)) -gt 30 ] 2>/dev/null; then
            rm -f "$_th_lock/owner" "$_th_lock/owner.tmp" "$_th_lock/boot" "$_th_lock/token" "$_th_lock/rows" "$_th_lock/trim" 2>/dev/null
            rmdir "$_th_lock" 2>/dev/null || return 0
            mkdir "$_th_lock" 2>/dev/null || return 0
        else
            return 0
        fi
    fi
    module_lock_write_owner "$_th_lock" || { rmdir "$_th_lock" 2>/dev/null; return 1; }
    trap 'rm -f "$_th_lock/owner" "$_th_lock/owner.tmp" "$_th_lock/token" "$_th_lock/boot"; rmdir "$_th_lock" 2>/dev/null' EXIT
    _th_token="$_th_boot:$_th_now:$MODULE_OWNER_PID"
    trap '[ "$(cat "$_th_lock/token" 2>/dev/null)" != "$_th_token" ] || { rm -f "$_th_lock/owner" "$_th_lock/owner.tmp" "$_th_lock/boot" "$_th_lock/token" "$_th_lock/rows" "$_th_lock/trim"; rmdir "$_th_lock" 2>/dev/null; }' EXIT
    printf '%s\n' "$_th_token" > "$_th_lock/token" || return 1
    printf '%s\n' "$_th_boot" > "$_th_lock/boot" || return 1
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    _th_values=$(printf '%s\n' "$_th_json" | awk -F '[{}]' '
        { for (i=1;i<=NF;i++) {
            object=$i
            sensor=""
            if (object ~ /"zone"[[:space:]]*:[[:space:]]*"(VIRTUAL-SKIN|SKIN)"/) sensor="module"
            if (object ~ /"zone"[[:space:]]*:[[:space:]]*"battery"/) sensor="battery"
            if (sensor == "" || !match(object,/"temp"[[:space:]]*:[[:space:]]*[0-9]+/)) continue
            value=substr(object,RSTART,RLENGTH); sub(/^.*:/,"",value); value+=0
            if (value>=10000 && value<=85000 && !seen[sensor]++) printf "%s,%d\n",sensor,value
        }}')
    [ -n "$_th_values" ] || return 0
    _th_last=$(tail -n 8 "$_th_file" 2>/dev/null || true)
    : > "$_th_lock/rows" || return 1
    while IFS=, read -r _th_sensor _th_temp; do
        [ -n "$_th_sensor" ] || continue
        _th_previous=$(printf '%s\n' "$_th_last" | awk -F, -v sensor="$_th_sensor" '
            $1 ~ /^[0-9]+$/ && (((NF == 2 || $11 ~ /^[0-9]+$/) && sensor == "module") || $11 == sensor) { last=$1 }
            END { if (last != "") print last }')
        case "$_th_previous" in ''|*[!0-9]*) _th_previous=0 ;; esac
        _th_since=$((_th_ts - _th_previous))
        [ "$_th_previous" -gt 0 ] && [ "$_th_since" -ge 0 ] && [ "$_th_since" -lt 60 ] && continue
        _th_quality=ok
        [ "$_th_screen" = off ] && _th_quality=screen_off_sample
        printf '%s,%s,%s,%s,%s,1,0,%s,%s,0,%s\n' "$_th_ts" "$_th_temp" "$_th_boot" \
            "thermal_$_th_boot" "$_th_source" "$_th_quality" "$_th_screen" "$_th_sensor" >> "$_th_lock/rows" || return 1
    done <<EOF
$_th_values
EOF
    [ -s "$_th_lock/rows" ] || return 0
    # Recheck after parsing/lock acquisition: foreground reads cannot bypass
    # a master pause committed while this sample was being prepared.
    background_tasks_enabled || return 0
    [ ! -L "$_th_file" ] || return 1
    cat "$_th_lock/rows" >> "$_th_file" || return 1
    chmod 600 "$_th_file" || return 1
    # At most two rows per minute; trim complete rows and preserve seven days.
    _th_lines=$(wc -l < "$_th_file" 2>/dev/null | tr -d ' \r\n')
    case "$_th_lines" in ''|*[!0-9]*) return 1 ;; esac
    _th_oldest=$(head -n 1 "$_th_file" 2>/dev/null | cut -d, -f1)
    case "$_th_oldest" in ''|*[!0-9]*) _th_oldest=0 ;; esac
    if [ "$_th_lines" -gt 20160 ] 2>/dev/null || [ "$_th_oldest" -lt "$((_th_ts - 604800))" ]; then
        tail -n 20160 "$_th_file" > "$_th_lock/trim" \
            && awk -F, -v cutoff="$((_th_ts - 604800))" '$1 ~ /^[0-9]+$/ && $1+0 >= cutoff' "$_th_lock/trim" > "$_th_lock/rows" \
            && [ -s "$_th_lock/rows" ] && mv "$_th_lock/rows" "$_th_file" || return 1
    fi
)
