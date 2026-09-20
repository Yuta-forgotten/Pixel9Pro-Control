#!/system/bin/sh

# Privacy-safe structured audit log. Callers pass controlled facts only; raw
# requests, endpoints, dumpsys/logcat output and personal identifiers are banned.

AUDIT_LOG_SCHEMA=1
AUDIT_LOG_MAX_BYTES="${PIXEL9PRO_AUDIT_LOG_MAX_BYTES:-262144}"
AUDIT_LOG_KEEP="${PIXEL9PRO_AUDIT_LOG_KEEP:-3}"

audit_log_init() {
    AUDIT_MODULE_ROOT="$1"
    AUDIT_LOG_DIR="${PIXEL9PRO_AUDIT_LOG_DIR:-/data/adb/pixel9pro_control/logs}"
    AUDIT_LOG_FILE="$AUDIT_LOG_DIR/events.log"
    case "$AUDIT_LOG_MAX_BYTES:$AUDIT_LOG_KEEP" in
        *[!0-9:]*) return 1 ;;
    esac
    [ "$AUDIT_LOG_MAX_BYTES" -ge 4096 ] 2>/dev/null || AUDIT_LOG_MAX_BYTES=262144
    [ "$AUDIT_LOG_KEEP" -ge 1 ] 2>/dev/null || AUDIT_LOG_KEEP=3
}

audit_log_token() {
    case "$1" in
        *'@'*|*'/data/user/'*|*'/sdcard/'*|*'C:'*'Users'*|*'C:/'*'Users/'*|100.*.*.*)
            printf redacted
            return 0
            ;;
        *[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
            printf redacted
            return 0
            ;;
        *[0-9A-Fa-f]:[0-9A-Fa-f]:[0-9A-Fa-f]:[0-9A-Fa-f]:[0-9A-Fa-f]:[0-9A-Fa-f]*)
            printf redacted
            return 0
            ;;
    esac
    _al_value=$(printf '%s' "$1" | tr '\r\n=|' '____' | tr -cd 'A-Za-z0-9._:@,+/-')
    [ -n "$_al_value" ] && printf '%s' "$_al_value" || printf unknown
}

audit_log_prepare() {
    mkdir -p "$AUDIT_LOG_DIR" 2>/dev/null || return 1
    chmod 700 "$AUDIT_LOG_DIR" 2>/dev/null || return 1
    [ ! -d "$AUDIT_LOG_FILE" ] || return 1
    [ -e "$AUDIT_LOG_FILE" ] || : > "$AUDIT_LOG_FILE" 2>/dev/null || return 1
    chmod 600 "$AUDIT_LOG_FILE" 2>/dev/null || return 1
    audit_log_day_roll
}

audit_log_day_roll() {
    _al_today=$(date '+%Y-%m-%d' 2>/dev/null || printf unknown)
    _al_day_file="$AUDIT_LOG_DIR/.events_day"
    _al_previous=$(cat "$_al_day_file" 2>/dev/null | tr -d ' \r\n\t')
    if [ -n "$_al_previous" ] && [ "$_al_previous" != "$_al_today" ] && [ -s "$AUDIT_LOG_FILE" ]; then
        mv "$AUDIT_LOG_FILE" "$AUDIT_LOG_DIR/events-$_al_previous.log" 2>/dev/null || return 1
        : > "$AUDIT_LOG_FILE" 2>/dev/null || return 1
        chmod 600 "$AUDIT_LOG_FILE" "$AUDIT_LOG_DIR/events-$_al_previous.log" 2>/dev/null || true
    fi
    printf '%s' "$_al_today" > "$_al_day_file" 2>/dev/null || return 1
    chmod 600 "$_al_day_file" 2>/dev/null || true
    for _al_daily in "$AUDIT_LOG_DIR"/events-*.log; do
        [ -f "$_al_daily" ] || continue
        find "$AUDIT_LOG_DIR" -name "${_al_daily##*/}" -mtime +3 -type f -exec rm -f {} \; 2>/dev/null || true
    done
}

audit_log_rotate() {
    [ -f "$AUDIT_LOG_FILE" ] || return 0
    _al_size=$(wc -c < "$AUDIT_LOG_FILE" 2>/dev/null | tr -d ' ')
    case "$_al_size" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_al_size" -lt "$AUDIT_LOG_MAX_BYTES" ] 2>/dev/null && return 0
    _al_index="$AUDIT_LOG_KEEP"
    while [ "$_al_index" -gt 1 ]; do
        _al_previous=$((_al_index - 1))
        [ ! -e "$AUDIT_LOG_FILE.$_al_previous" ] \
            || mv "$AUDIT_LOG_FILE.$_al_previous" "$AUDIT_LOG_FILE.$_al_index" 2>/dev/null \
            || return 1
        _al_index="$_al_previous"
    done
    mv "$AUDIT_LOG_FILE" "$AUDIT_LOG_FILE.1" 2>/dev/null || return 1
    : > "$AUDIT_LOG_FILE" 2>/dev/null || return 1
    chmod 600 "$AUDIT_LOG_FILE" "$AUDIT_LOG_FILE.1" 2>/dev/null || return 1
}

audit_log_context_value() {
    _al_context_path="$1"
    _al_context_fallback="$2"
    _al_context=$(cat "$_al_context_path" 2>/dev/null | tr -d ' \r\n\t')
    [ -n "$_al_context" ] && audit_log_token "$_al_context" || printf '%s' "$_al_context_fallback"
}

audit_log_module_version() {
    _al_version=$(sed -n 's/^version=//p' "$AUDIT_MODULE_ROOT/module.prop" 2>/dev/null | head -n 1)
    [ -n "$_al_version" ] && audit_log_token "$_al_version" || printf unknown
}

audit_log_event() {
    _al_phase=$(audit_log_token "$1")
    _al_operation=$(audit_log_token "$2")
    _al_result=$(audit_log_token "$3")
    _al_reason=$(audit_log_token "$4")
    _al_duration="$5"
    case "$_al_duration" in ''|*[!0-9]*) _al_duration=0 ;; esac
    audit_log_prepare || return 1
    audit_log_rotate || return 1
    _al_epoch=$(date +%s 2>/dev/null || printf 0)
    case "$_al_epoch" in ''|*[!0-9]*) _al_epoch=0 ;; esac
    _al_device=$(audit_log_context_value "$AUDIT_MODULE_ROOT/.device_variant" unknown)
    _al_root=$(audit_log_context_value "$AUDIT_MODULE_ROOT/.root_family" unknown)
    printf 'schema=%s ts=%s module_version=%s root_family=%s device=%s phase=%s operation=%s result=%s reason_code=%s duration_ms=%s\n' \
        "$AUDIT_LOG_SCHEMA" "$_al_epoch" "$(audit_log_module_version)" "$_al_root" "$_al_device" \
        "$_al_phase" "$_al_operation" "$_al_result" "$_al_reason" "$_al_duration" \
        >> "$AUDIT_LOG_FILE" 2>/dev/null || return 1
    chmod 600 "$AUDIT_LOG_FILE" 2>/dev/null
}

audit_log_clear() {
    audit_log_prepare || return 1
    : > "$AUDIT_LOG_FILE" 2>/dev/null || return 1
    chmod 600 "$AUDIT_LOG_FILE" 2>/dev/null || return 1
    for _al_rotated in "$AUDIT_LOG_FILE".* "$AUDIT_LOG_DIR"/events-*.log; do
        [ -f "$_al_rotated" ] || continue
        rm -f "$_al_rotated" 2>/dev/null || return 1
    done
    audit_log_event audit clear success AUDIT_LOG_CLEARED 0
}
