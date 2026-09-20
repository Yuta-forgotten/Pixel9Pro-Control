#!/system/bin/sh

# Scheduler capability and mode gate. scheduler_mode=off is authoritative:
# callers may read status, but no profile, reconcile, repair, or owner mutation.

scheduler_capability_init() {
    SCHED_CAP_ROOT="$1"
    [ -n "$SCHED_CAP_ROOT" ] || return 1
    SCHED_MODE_FILE="$SCHED_CAP_ROOT/.scheduler_mode"
    SCHED_CAP_FILE="$SCHED_CAP_ROOT/.scheduler_capability"
    SCHED_CAP_RECEIPT_FILE="$SCHED_CAP_ROOT/.scheduler_capability_receipt"
    SCHED_CAP_CPU0="${SCHED_CAP_CPU0:-/sys/devices/system/cpu/cpu0/cpufreq}"
    SCHED_CAP_CPU4="${SCHED_CAP_CPU4:-/sys/devices/system/cpu/cpu4/cpufreq}"
    SCHED_CAP_CPU7="${SCHED_CAP_CPU7:-/sys/devices/system/cpu/cpu7/cpufreq}"
    SCHED_CAP_CPUSET="${SCHED_CAP_CPUSET:-/dev/cpuset}"
    SCHED_CAP_VENDOR="${SCHED_CAP_VENDOR:-/proc/vendor_sched}"
    SCHED_CAP_UCLAMP="${SCHED_CAP_UCLAMP:-/proc/sys/kernel/sched_util_clamp_min}"
    SCHED_CAP_NODES="$SCHED_CAP_CPU0/sched_pixel/response_time_ms
$SCHED_CAP_CPU4/sched_pixel/response_time_ms
$SCHED_CAP_CPU7/sched_pixel/response_time_ms
$SCHED_CAP_CPUSET/top-app/cpus
$SCHED_CAP_CPUSET/foreground/cpus
$SCHED_CAP_CPUSET/background/cpus
$SCHED_CAP_CPUSET/system-background/cpus
$SCHED_CAP_UCLAMP
$SCHED_CAP_VENDOR/ug_bg_uclamp_max
$SCHED_CAP_VENDOR/ug_bg_group_throttle"
}

scheduler_mode_is_valid() {
    case "$1" in active|off|observe) return 0 ;; *) return 1 ;; esac
}

scheduler_mode_read() {
    _sc_mode=$(cat "$SCHED_MODE_FILE" 2>/dev/null | tr -d ' \r\n\t')
    scheduler_mode_is_valid "$_sc_mode" && printf '%s' "$_sc_mode" || printf active
}

scheduler_mode_is_active() {
    [ "$(scheduler_mode_read)" = active ]
}

scheduler_capability_is_valid() {
    case "$1" in supported|partial|unsupported|unknown) return 0 ;; *) return 1 ;; esac
}

scheduler_capability_read() {
    _sc_capability=$(cat "$SCHED_CAP_FILE" 2>/dev/null | tr -d ' \r\n\t')
    scheduler_capability_is_valid "$_sc_capability" \
        && printf '%s' "$_sc_capability" || printf unknown
}

scheduler_capability_atomic_write() {
    _sc_path="$1"
    _sc_value="$2"
    [ -n "$_sc_path" ] && [ ! -d "$_sc_path" ] || return 1
    if command -v runtime_write_value >/dev/null 2>&1; then
        runtime_write_value "$_sc_path" "$_sc_value"
        return $?
    fi
    _sc_tmp="${_sc_path}.tmp.$$"
    printf '%s' "$_sc_value" > "$_sc_tmp" 2>/dev/null \
        && mv "$_sc_tmp" "$_sc_path" 2>/dev/null \
        && [ "$(cat "$_sc_path" 2>/dev/null)" = "$_sc_value" ] && return 0
    rm -f "$_sc_tmp" 2>/dev/null
    return 1
}

scheduler_mode_write() {
    scheduler_mode_is_valid "$1" || return 1
    scheduler_capability_atomic_write "$SCHED_MODE_FILE" "$1"
}

scheduler_capability_probe() {
    _sc_probe_mode="${1:-readonly}"
    case "$_sc_probe_mode" in readonly|verify) ;; *) return 1 ;; esac
    SCHED_CAP_TOTAL=0
    SCHED_CAP_READABLE=0
    SCHED_CAP_WRITABLE=0
    SCHED_CAP_VERIFIED=0
    SCHED_CAP_MISSING=""
    _sc_old_ifs="$IFS"
    IFS='
'
    for _sc_node in $SCHED_CAP_NODES; do
        IFS="$_sc_old_ifs"
        SCHED_CAP_TOTAL=$((SCHED_CAP_TOTAL + 1))
        if [ ! -e "$_sc_node" ] || [ ! -r "$_sc_node" ]; then
            SCHED_CAP_MISSING="${SCHED_CAP_MISSING}${SCHED_CAP_MISSING:+,}${_sc_node##*/}"
            IFS='
'
            continue
        fi
        SCHED_CAP_READABLE=$((SCHED_CAP_READABLE + 1))
        [ -w "$_sc_node" ] && SCHED_CAP_WRITABLE=$((SCHED_CAP_WRITABLE + 1))
        if [ "$_sc_probe_mode" = verify ] && [ -w "$_sc_node" ]; then
            _sc_before=$(cat "$_sc_node" 2>/dev/null | tr -d ' \r\n\t')
            if [ -n "$_sc_before" ] \
                && printf '%s\n' "$_sc_before" > "$_sc_node" 2>/dev/null \
                && [ "$(cat "$_sc_node" 2>/dev/null | tr -d ' \r\n\t')" = "$_sc_before" ]; then
                SCHED_CAP_VERIFIED=$((SCHED_CAP_VERIFIED + 1))
            fi
        elif [ "$_sc_probe_mode" = readonly ] && [ -w "$_sc_node" ]; then
            SCHED_CAP_VERIFIED=$((SCHED_CAP_VERIFIED + 1))
        fi
        IFS='
'
    done
    IFS="$_sc_old_ifs"

    if [ "$SCHED_CAP_TOTAL" -eq 10 ] \
        && [ "$SCHED_CAP_READABLE" -eq "$SCHED_CAP_TOTAL" ] \
        && [ "$SCHED_CAP_WRITABLE" -eq "$SCHED_CAP_TOTAL" ] \
        && [ "$SCHED_CAP_VERIFIED" -eq "$SCHED_CAP_TOTAL" ]; then
        SCHED_CAPABILITY=supported
        SCHED_CAP_REASON=all_nodes_verified
    elif [ "$SCHED_CAP_READABLE" -gt 0 ]; then
        SCHED_CAPABILITY=partial
        SCHED_CAP_REASON=incomplete_control_plane
    elif [ "$SCHED_CAP_TOTAL" -eq 10 ]; then
        SCHED_CAPABILITY=unsupported
        SCHED_CAP_REASON=no_scheduler_nodes
    else
        SCHED_CAPABILITY=unknown
        SCHED_CAP_REASON=probe_incomplete
    fi
}

scheduler_capability_commit() {
    scheduler_capability_is_valid "$SCHED_CAPABILITY" || return 1
    scheduler_capability_atomic_write "$SCHED_CAP_FILE" "$SCHED_CAPABILITY" || return 1
    _sc_receipt_tmp="${SCHED_CAP_RECEIPT_FILE}.tmp.$$"
    {
        printf 'schema=1\n'
        printf 'updated_at=%s\n' "$(date +%s 2>/dev/null || printf 0)"
        printf 'mode=%s\n' "$(scheduler_mode_read)"
        printf 'capability=%s\n' "$SCHED_CAPABILITY"
        printf 'reason=%s\n' "$SCHED_CAP_REASON"
        printf 'total=%s\n' "$SCHED_CAP_TOTAL"
        printf 'readable=%s\n' "$SCHED_CAP_READABLE"
        printf 'writable=%s\n' "$SCHED_CAP_WRITABLE"
        printf 'verified=%s\n' "$SCHED_CAP_VERIFIED"
        printf 'missing=%s\n' "$(printf '%s' "$SCHED_CAP_MISSING" | tr '\r\n=|' '    ')"
    } > "$_sc_receipt_tmp" 2>/dev/null \
        && mv "$_sc_receipt_tmp" "$SCHED_CAP_RECEIPT_FILE" 2>/dev/null \
        && chmod 600 "$SCHED_CAP_RECEIPT_FILE" 2>/dev/null \
        && return 0
    rm -f "$_sc_receipt_tmp" 2>/dev/null
    return 1
}

scheduler_capability_enforce_mode() {
    scheduler_capability_probe "${1:-readonly}" || return 1
    if scheduler_mode_is_active && [ "$SCHED_CAPABILITY" != supported ]; then
        scheduler_mode_write off || return 1
        SCHED_CAP_REASON="${SCHED_CAP_REASON}_forced_off"
    fi
    scheduler_capability_commit
}
