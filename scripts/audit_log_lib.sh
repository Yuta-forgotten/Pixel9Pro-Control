#!/system/bin/sh
# Structured, bounded, private events. Never pass requests, tokens, endpoints,
# dumpsys/logcat output or personal identifiers to this interface.
AUDIT_LOG_SCHEMA=2
AUDIT_LOG_MAX_BYTES="${PIXEL9PRO_AUDIT_LOG_MAX_BYTES:-262144}"
AUDIT_LOG_KEEP="${PIXEL9PRO_AUDIT_LOG_KEEP:-3}"

audit_log_init() {
    AUDIT_MODULE_ROOT="$1"
    AUDIT_LOG_DIR="${PIXEL9PRO_AUDIT_LOG_DIR:-/data/adb/pixel9pro_control/logs}"
    AUDIT_LOG_FILE="$AUDIT_LOG_DIR/events.log"
    case "$AUDIT_LOG_MAX_BYTES:$AUDIT_LOG_KEEP" in *[!0-9:]*|:*|*:) return 1 ;; esac
    [ "$AUDIT_LOG_MAX_BYTES" -ge 4096 ] 2>/dev/null && [ "$AUDIT_LOG_MAX_BYTES" -le 1048576 ] 2>/dev/null || AUDIT_LOG_MAX_BYTES=262144
    [ "$AUDIT_LOG_KEEP" -ge 1 ] 2>/dev/null && [ "$AUDIT_LOG_KEEP" -le 10 ] 2>/dev/null || AUDIT_LOG_KEEP=3
    [ -n "$AUDIT_LOG_DIR" ] && [ ! -L "$AUDIT_LOG_DIR" ]
}

audit_log_token() {
    case "$1" in
        *'@'*|*'/data/user/'*|*'/sdcard/'*|*'C:'*'Users'*|*'C:/'*'Users/'*|100.*.*.*|*[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*|*[0-9A-Fa-f]:[0-9A-Fa-f]:[0-9A-Fa-f]:[0-9A-Fa-f]:[0-9A-Fa-f]:[0-9A-Fa-f]*)
            printf redacted; return 0 ;;
    esac
    _al_value=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._:+/-' | cut -c1-96)
    [ -n "$_al_value" ] && printf '%s' "$_al_value" || printf unknown
}

audit_log_read_first_line() {
    _al_read_value=
    [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] || return 0
    IFS= read -r _al_read_value < "$1" || true
    _al_read_cr=$(printf '\r')
    printf '%s' "${_al_read_value%"$_al_read_cr"}"
}

audit_log_safe_file() {
    [ ! -L "$1" ] && { [ ! -e "$1" ] || [ -f "$1" ]; }
}

audit_log_lock() {
    [ ! -L "$AUDIT_LOG_DIR" ] || return 1
    mkdir -p "$AUDIT_LOG_DIR" 2>/dev/null && chmod 700 "$AUDIT_LOG_DIR" 2>/dev/null || return 1
    _al_lock="$AUDIT_LOG_DIR/.writer.lock"
    [ ! -L "$_al_lock" ] || return 1
    _al_attempt=0
    while ! mkdir "$_al_lock" 2>/dev/null; do
        _al_attempt=$((_al_attempt + 1))
        [ "$_al_attempt" -lt 40 ] || return 75
        _al_lock_pid=$(audit_log_read_first_line "$_al_lock/pid")
        _al_lock_boot=$(audit_log_read_first_line "$_al_lock/boot")
        _al_lock_ticks=$(audit_log_read_first_line "$_al_lock/ticks")
        _al_lock_mtime=$(stat -c %Y "$_al_lock" 2>/dev/null) || return 1
        _al_now=$(date +%s 2>/dev/null) || return 1
        case "$_al_lock_pid" in ''|*[!0-9]*) _al_lock_pid=0 ;; esac
        case "$_al_lock_mtime:$_al_now" in *[!0-9:]*|:*|*:) return 1 ;; esac
        _al_owner_live=0
        if [ "$_al_lock_pid" -gt 1 ] && [ -n "$_al_lock_ticks" ] \
            && [ "$_al_lock_boot" = "$(audit_log_read_first_line /proc/sys/kernel/random/boot_id)" ]; then
            _al_live_stat=$(sed 's/^.*) //' "/proc/$_al_lock_pid/stat" 2>/dev/null || true)
            if [ "${_al_live_stat%% *}" != Z ] \
                && [ "$(printf '%s' "$_al_live_stat" | cut -d' ' -f20)" = "$_al_lock_ticks" ] \
                && kill -0 "$_al_lock_pid" 2>/dev/null; then _al_owner_live=1; fi
        fi
        _al_stale=0
        if [ "$_al_owner_live" = 0 ]; then
            if [ "$_al_lock_pid" -gt 1 ] && [ -n "$_al_lock_boot" ] && [ -n "$_al_lock_ticks" ]; then
                _al_stale=1
            elif [ $((_al_now - _al_lock_mtime)) -gt 30 ]; then _al_stale=1; fi
        fi
        if [ "$_al_stale" = 1 ]; then
            rm -f "$_al_lock/pid" "$_al_lock/boot" "$_al_lock/ticks" 2>/dev/null && rmdir "$_al_lock" 2>/dev/null || return 1
        else
            sleep 0.05
        fi
    done
    # /proc/self identifies this actual subshell; $$ may be the parent shell.
    IFS=' ' read -r _al_self _al_stat < /proc/self/stat || { rmdir "$_al_lock"; return 1; }
    trap 'rm -f "$_al_lock/pid" "$_al_lock/boot" "$_al_lock/ticks" "$_al_lock/snapshot" "$_al_lock/trim"; rmdir "$_al_lock" 2>/dev/null' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    _al_self_ticks=$(sed 's/^.*) //' "/proc/$_al_self/stat" | cut -d' ' -f20)
    [ -n "$_al_self_ticks" ] || return 1
    printf '%s\n' "$(audit_log_read_first_line /proc/sys/kernel/random/boot_id)" > "$_al_lock/boot" \
        && printf '%s\n' "$_al_self_ticks" > "$_al_lock/ticks" \
        && printf '%s\n' "$_al_self" > "$_al_lock/pid"
}

audit_log_prepare() {
    audit_log_safe_file "$AUDIT_LOG_FILE" && audit_log_safe_file "$AUDIT_LOG_DIR/.events_day" || return 1
    [ -e "$AUDIT_LOG_FILE" ] || : > "$AUDIT_LOG_FILE" || return 1
    chmod 600 "$AUDIT_LOG_FILE" || return 1
    audit_log_day_roll
}

audit_log_day_roll() {
    _al_today=$(date '+%Y-%m-%d') || return 1
    _al_day_file="$AUDIT_LOG_DIR/.events_day"
    _al_previous=$(audit_log_read_first_line "$_al_day_file")
    case "$_al_previous" in ????-??-??) ;; *) _al_previous= ;; esac
    case "$_al_previous" in *[!0-9-]*) _al_previous= ;; esac
    if [ -n "$_al_previous" ] && [ "$_al_previous" != "$_al_today" ] && [ -s "$AUDIT_LOG_FILE" ]; then
        _al_daily="$AUDIT_LOG_DIR/events-$_al_previous.log"
        audit_log_safe_file "$_al_daily" || return 1
        _al_day_index="$AUDIT_LOG_KEEP"
        while [ "$_al_day_index" -ge 1 ]; do
            _al_chunk="$AUDIT_LOG_FILE.$_al_day_index"
            audit_log_safe_file "$_al_chunk" || return 1
            [ ! -f "$_al_chunk" ] || cat "$_al_chunk" >> "$_al_daily" || return 1
            rm -f "$_al_chunk" || return 1
            _al_day_index=$((_al_day_index - 1))
        done
        cat "$AUDIT_LOG_FILE" >> "$_al_daily" && chmod 600 "$_al_daily" || return 1
        _al_daily_cap=$(( (AUDIT_LOG_KEEP + 1) * (AUDIT_LOG_MAX_BYTES + 2048) ))
        _al_daily_size=$(wc -c < "$_al_daily" | tr -d ' \r\n')
        if [ "$_al_daily_size" -gt "$_al_daily_cap" ]; then
            tail -c "$_al_daily_cap" "$_al_daily" | sed '1d' > "$_al_lock/trim" \
                && mv "$_al_lock/trim" "$_al_daily" || return 1
        fi
        : > "$AUDIT_LOG_FILE" || return 1
    fi
    printf '%s\n' "$_al_today" > "$_al_day_file" && chmod 600 "$_al_day_file" || return 1
    _al_daily_count=0
    for _al_daily in "$AUDIT_LOG_DIR"/events-????-??-??.log; do
        audit_log_safe_file "$_al_daily" || return 1
        [ ! -f "$_al_daily" ] || _al_daily_count=$((_al_daily_count + 1))
    done
    # ISO-date glob order is chronological; keep four bounded daily archives.
    for _al_daily in "$AUDIT_LOG_DIR"/events-????-??-??.log; do
        [ "$_al_daily_count" -gt 4 ] || break
        [ -f "$_al_daily" ] || continue
        rm -f "$_al_daily" || return 1
        _al_daily_count=$((_al_daily_count - 1))
    done
}

audit_log_rotate() {
    _al_size=$(wc -c < "$AUDIT_LOG_FILE" | tr -d ' \r\n')
    case "$_al_size" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_al_size" -lt "$AUDIT_LOG_MAX_BYTES" ] && return 0
    _al_index="$AUDIT_LOG_KEEP"
    while [ "$_al_index" -gt 1 ]; do
        _al_previous=$((_al_index - 1))
        audit_log_safe_file "$AUDIT_LOG_FILE.$_al_previous" && audit_log_safe_file "$AUDIT_LOG_FILE.$_al_index" || return 1
        [ ! -e "$AUDIT_LOG_FILE.$_al_previous" ] || mv "$AUDIT_LOG_FILE.$_al_previous" "$AUDIT_LOG_FILE.$_al_index" || return 1
        _al_index="$_al_previous"
    done
    audit_log_safe_file "$AUDIT_LOG_FILE.1" || return 1
    mv "$AUDIT_LOG_FILE" "$AUDIT_LOG_FILE.1" && : > "$AUDIT_LOG_FILE" || return 1
    chmod 600 "$AUDIT_LOG_FILE" "$AUDIT_LOG_FILE.1"
}

audit_log_context_value() {
    _al_context=$(audit_log_read_first_line "$1")
    [ -n "$_al_context" ] && audit_log_token "$_al_context" || printf '%s' "$2"
}

audit_log_module_version() {
    [ -r "$AUDIT_MODULE_ROOT/module.prop" ] || { printf unknown; return; }
    _al_version=$(sed -n 's/^version=//p' "$AUDIT_MODULE_ROOT/module.prop" | head -n 1)
    audit_log_token "$_al_version"
}

audit_log_append() {
    _al_phase=$(audit_log_token "$1")
    _al_operation=$(audit_log_token "$2")
    _al_result=$(audit_log_token "$3")
    _al_reason=$(audit_log_token "$4")
    _al_duration="${5:-0}"
    case "$_al_duration" in ''|*[!0-9]*|?????????????*) _al_duration=0 ;; esac
    _al_epoch=$(date +%s) || return 1
    printf 'schema=%s ts=%s boot_id=%s module_version=%s root_family=%s device=%s phase=%s operation=%s result=%s reason_code=%s duration_ms=%s\n' \
        "$AUDIT_LOG_SCHEMA" "$_al_epoch" "$(audit_log_token "$(audit_log_read_first_line /proc/sys/kernel/random/boot_id)")" \
        "$(audit_log_module_version)" "$(audit_log_context_value "$AUDIT_MODULE_ROOT/.root_family" unknown)" \
        "$(audit_log_context_value "$AUDIT_MODULE_ROOT/.device_variant" unknown)" \
        "$_al_phase" "$_al_operation" "$_al_result" "$_al_reason" "$_al_duration" >> "$AUDIT_LOG_FILE"
}

audit_log_event() (
    umask 077
    audit_log_lock && audit_log_prepare && audit_log_rotate && audit_log_append "$@"
)

audit_log_clear() (
    umask 077
    audit_log_lock && audit_log_prepare || return 1
    for _al_rotated in "$AUDIT_LOG_FILE".* "$AUDIT_LOG_DIR"/events-*.log; do
        audit_log_safe_file "$_al_rotated" || return 1
    done
    for _al_rotated in "$AUDIT_LOG_FILE".* "$AUDIT_LOG_DIR"/events-*.log; do
        [ ! -f "$_al_rotated" ] || rm -f "$_al_rotated" || return 1
    done
    : > "$AUDIT_LOG_FILE" && audit_log_append audit clear success AUDIT_LOG_CLEARED 0
)

audit_log_read() (
    umask 077
    _al_read_limit="$1"
    _al_read_all="${2:-0}"
    case "$_al_read_limit" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_al_read_limit" -ge 1 ] && [ "$_al_read_limit" -le 2000 ] || return 1
    audit_log_lock && audit_log_prepare || return 1
    : > "$_al_lock/snapshot" || return 1
    if [ "$_al_read_all" = 1 ]; then
        for _al_daily in "$AUDIT_LOG_DIR"/events-????-??-??.log; do
            audit_log_safe_file "$_al_daily" || return 1
            [ ! -f "$_al_daily" ] || cat "$_al_daily" >> "$_al_lock/snapshot" || return 1
        done
        _al_index="$AUDIT_LOG_KEEP"
        while [ "$_al_index" -ge 1 ]; do
            _al_chunk="$AUDIT_LOG_FILE.$_al_index"
            audit_log_safe_file "$_al_chunk" || return 1
            [ ! -f "$_al_chunk" ] || cat "$_al_chunk" >> "$_al_lock/snapshot" || return 1
            _al_index=$((_al_index - 1))
        done
    fi
    cat "$AUDIT_LOG_FILE" >> "$_al_lock/snapshot" || return 1
    tail -n "$_al_read_limit" "$_al_lock/snapshot"
)
