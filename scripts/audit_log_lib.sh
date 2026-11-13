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
    command -v flock >/dev/null 2>&1 || return 1
    [ ! -L "$AUDIT_LOG_DIR" ] || return 1
    [ -d "$AUDIT_LOG_DIR" ] || mkdir -p "$AUDIT_LOG_DIR" 2>/dev/null || return 1
    _al_lock="$AUDIT_LOG_DIR/.writer.flock"
    audit_log_safe_file "$_al_lock" || return 1
    exec 9>>"$_al_lock" || return 1
    _al_lock_mode=$(stat -c %a "$_al_lock") || return 1
    [ "$_al_lock_mode" = 600 ] || chmod 600 "$_al_lock" || return 1
    _al_attempt=0
    while ! flock -n 9; do
        _al_attempt=$((_al_attempt + 1))
        [ "$_al_attempt" -lt 40 ] || return 75
        sleep 0.05
    done
    # Every caller is a subshell; the kernel releases FD 9 on exit or a signal.
    # The previous mkdir lock, if present, is legacy state and is left untouched.
}

audit_log_prepare() {
    audit_log_safe_file "$AUDIT_LOG_FILE" || return 1
    [ -e "$AUDIT_LOG_FILE" ] || : > "$AUDIT_LOG_FILE" || return 1
    chmod 600 "$AUDIT_LOG_FILE"
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

# Fixed owned sources, oldest first. Legacy daily archives are read-only until
# an explicit clear; new events use only the existing bounded size rotation.
audit_log_source_paths() {
    if [ "$1" = 1 ]; then
        for _al_daily in "$AUDIT_LOG_DIR"/events-????-??-??.log; do
            audit_log_safe_file "$_al_daily" || return 1
            [ ! -f "$_al_daily" ] || printf '%s\n' "$_al_daily"
        done
        _al_index="$AUDIT_LOG_KEEP"
        while [ "$_al_index" -ge 1 ]; do
            _al_chunk="$AUDIT_LOG_FILE.$_al_index"
            audit_log_safe_file "$_al_chunk" || return 1
            [ ! -f "$_al_chunk" ] || printf '%s\n' "$_al_chunk"
            _al_index=$((_al_index - 1))
        done
    fi
    audit_log_safe_file "$AUDIT_LOG_FILE" || return 1
    [ ! -f "$AUDIT_LOG_FILE" ] || printf '%s\n' "$AUDIT_LOG_FILE"
}

# Keep the existing text-tail ABI for shell consumers without a disk snapshot.
audit_log_read() (
    umask 077
    _al_read_limit="$1"
    case "$_al_read_limit" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_al_read_limit" -ge 1 ] && [ "$_al_read_limit" -le 2000 ] || return 1
    audit_log_lock || return $?
    _al_sources=$(audit_log_source_paths "${2:-0}") || return 1
    set -- /dev/null
    while IFS= read -r _al_source; do
        [ -z "$_al_source" ] || set -- "$@" "$_al_source"
    done <<EOF
$_al_sources
EOF
    LC_ALL=C awk -v limit="$_al_read_limit" '
        { lines[(NR-1)%limit]=$0 }
        END { for (i=(NR>limit ? NR-limit : 0);i<NR;i++) print lines[i%limit] }
    ' "$@"
)

# CGI validates the query once. Hashing each fixed source under the writer lock
# detects same-second writes and rotation between pages without a saved file.
# Returns 65 for oversized records/page, 66 for offset, 73 for snapshot change.
audit_log_page() (
    umask 077
    _al_page_limit="$1"
    _al_page_offset="$2"
    _al_page_all="$3"
    _al_expected_snapshot="$4"
    audit_log_lock || return $?
    _al_sources=$(audit_log_source_paths "$_al_page_all") || return 1
    _al_identity="scope=$_al_page_all"
    _al_rotated=false
    for _al_archive in "$AUDIT_LOG_FILE.1" "$AUDIT_LOG_DIR"/events-????-??-??.log; do
        [ ! -f "$_al_archive" ] || _al_rotated=true
    done
    set -- /dev/null
    while IFS= read -r _al_source; do
        [ -n "$_al_source" ] || continue
        _al_hash=$(sha256sum "$_al_source") || return 1
        _al_identity="$_al_identity
$_al_hash"
        set -- "$@" "$_al_source"
    done <<EOF
$_al_sources
EOF
    _al_snapshot=$(printf '%s\n' "$_al_identity" | sha256sum) || return 1
    _al_snapshot=${_al_snapshot%% *}
    [ -z "$_al_expected_snapshot" ] || [ "$_al_expected_snapshot" = "$_al_snapshot" ] || return 73
    LC_ALL=C awk -v limit="$_al_page_limit" -v offset="$_al_page_offset" \
        -v snapshot="$_al_snapshot" -v rotated="$_al_rotated" -v schema="$AUDIT_LOG_SCHEMA" '
        function escape(value, result,i,c) {
            result=""
            for (i=1;i<=length(value);i++) {
                c=substr(value,i,1)
                if (c=="\\") result=result "\\\\"
                else if (c=="\"") result=result "\\\""
                else if (c in escaped) result=result escaped[c]
                else result=result c
            }
            return result
        }
        BEGIN { for (i=0;i<32;i++) escaped[sprintf("%c",i)]=sprintf("\\u%04x",i) }
        {
            # The former API silently cut these lines; reject damaged history.
            if (length($0)>1600) { invalid=1; next }
            if (NR>offset && returned<limit) {
                line=escape($0)
                bytes+=length(line)+3
                if (bytes>3145728) { invalid=1; next }
                lines=lines (returned++ ? "," : "") "\"" line "\""
            }
        }
        END {
            if (invalid) exit 65
            if (offset>NR) exit 66
            next_offset=offset+returned
            more=next_offset<NR
            printf "{\"ok\":true,\"schema\":%d,\"source\":\"structured_audit\",\"lines\":[%s],\"limit\":%d,\"rotated\":%s,\"total_lines\":%d,\"offset\":%d,\"next_offset\":%s,\"complete\":%s,\"truncated\":%s,\"snapshot_id\":\"%s\"}\n", \
                schema,lines,limit,rotated,NR,offset,(more ? sprintf("%d",next_offset) : "null"), \
                (more ? "false" : "true"),(more ? "true" : "false"),snapshot
        }
    ' "$@"
)
