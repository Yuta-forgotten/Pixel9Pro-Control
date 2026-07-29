#!/system/bin/sh

# Bounded mutation guard shared by scheduler/profile transactions. It never
# writes scheduler nodes; it only latches attempts and terminal outcomes.

STG_MAX_ATTEMPTS="${STG_MAX_ATTEMPTS:-3}"
STG_DEADLINE_S="${STG_DEADLINE_S:-30}"
STG_STATE_COMMIT_ATTEMPTS="${STG_STATE_COMMIT_ATTEMPTS:-3}"
STG_STATE_COMMIT_RETRY_SLEEP_S="${STG_STATE_COMMIT_RETRY_SLEEP_S:-1}"

stg_init() {
    STG_FILE="$1"
    STG_TERMINAL_FILE="${STG_TERMINAL_FILE_OVERRIDE:-${STG_FILE}.terminal}"
    STG_KEY=""
    STG_BOOT_ID=""
    STG_ATTEMPTS=0
    STG_FIRST_EPOCH=0
    STG_DEADLINE_EPOCH=0
    STG_TERMINAL=no
    STG_OK=pending
    STG_RESULT=uninitialized
}

stg_safe_field() {
    printf '%s' "$1" | tr '=|\r\n' '____'
}

stg_atomic_write() {
    _stg_value="$1"
    [ -n "$STG_FILE" ] && [ ! -d "$STG_FILE" ] || return 1
    _stg_tmp="${STG_FILE}.tmp.$$"
    if printf '%s' "$_stg_value" > "$_stg_tmp" 2>/dev/null \
        && mv "$_stg_tmp" "$STG_FILE" 2>/dev/null \
        && [ "$(cat "$STG_FILE" 2>/dev/null)" = "$_stg_value" ]; then
        return 0
    fi
    rm -f "$_stg_tmp" 2>/dev/null
    return 1
}

stg_read_value() {
    [ -s "$STG_FILE" ] || return 1
    sed -n "s/^$1=//p" "$STG_FILE" 2>/dev/null | head -n 1 | tr -d '\r'
}

stg_load() {
    STG_KEY=$(stg_read_value key 2>/dev/null)
    STG_BOOT_ID=$(stg_read_value boot_id 2>/dev/null)
    STG_ATTEMPTS=$(stg_read_value attempts 2>/dev/null)
    STG_FIRST_EPOCH=$(stg_read_value first_epoch 2>/dev/null)
    STG_DEADLINE_EPOCH=$(stg_read_value deadline_epoch 2>/dev/null)
    STG_TERMINAL=$(stg_read_value terminal 2>/dev/null)
    STG_OK=$(stg_read_value ok 2>/dev/null)
    STG_RESULT=$(stg_read_value result 2>/dev/null)
    case "$STG_ATTEMPTS" in ''|*[!0-9]*) STG_ATTEMPTS=0 ;; esac
    case "$STG_FIRST_EPOCH" in ''|*[!0-9]*) STG_FIRST_EPOCH=0 ;; esac
    case "$STG_DEADLINE_EPOCH" in ''|*[!0-9]*) STG_DEADLINE_EPOCH=0 ;; esac
    case "$STG_TERMINAL" in yes|no) ;; *) STG_TERMINAL=no ;; esac
    case "$STG_OK" in yes|no|pending) ;; *) STG_OK=pending ;; esac

    _stg_terminal_key=$(stg_read_file_value "$STG_TERMINAL_FILE" key 2>/dev/null)
    _stg_terminal_boot=$(stg_read_file_value "$STG_TERMINAL_FILE" boot_id 2>/dev/null)
    _stg_terminal_flag=$(stg_read_file_value "$STG_TERMINAL_FILE" terminal 2>/dev/null)
    if [ "$_stg_terminal_flag" = "yes" ] \
        && [ -n "$_stg_terminal_key" ] \
        && { [ -z "$STG_KEY" ] \
            || { [ "$STG_KEY" = "$_stg_terminal_key" ] \
                && [ "$STG_BOOT_ID" = "$_stg_terminal_boot" ]; }; }; then
        STG_KEY="$_stg_terminal_key"
        STG_BOOT_ID="$_stg_terminal_boot"
        STG_ATTEMPTS=$(stg_read_file_value "$STG_TERMINAL_FILE" attempts 2>/dev/null)
        STG_FIRST_EPOCH=$(stg_read_file_value "$STG_TERMINAL_FILE" first_epoch 2>/dev/null)
        STG_DEADLINE_EPOCH=$(stg_read_file_value "$STG_TERMINAL_FILE" deadline_epoch 2>/dev/null)
        STG_TERMINAL=yes
        STG_OK=$(stg_read_file_value "$STG_TERMINAL_FILE" ok 2>/dev/null)
        STG_RESULT=$(stg_read_file_value "$STG_TERMINAL_FILE" result 2>/dev/null)
        case "$STG_ATTEMPTS" in ''|*[!0-9]*) STG_ATTEMPTS=0 ;; esac
        case "$STG_FIRST_EPOCH" in ''|*[!0-9]*) STG_FIRST_EPOCH=0 ;; esac
        case "$STG_DEADLINE_EPOCH" in ''|*[!0-9]*) STG_DEADLINE_EPOCH=0 ;; esac
        case "$STG_OK" in yes|no) ;; *) STG_OK=no ;; esac
    fi
}

stg_read_file_value() {
    _stg_read_file="$1"
    _stg_read_key="$2"
    [ -s "$_stg_read_file" ] || return 1
    sed -n "s/^$_stg_read_key=//p" "$_stg_read_file" 2>/dev/null | head -n 1 | tr -d '\r'
}

stg_payload() {
    printf '%s\n' \
        "key=$(stg_safe_field "$STG_KEY")" \
        "boot_id=$(stg_safe_field "$STG_BOOT_ID")" \
        "attempts=$STG_ATTEMPTS" \
        "first_epoch=$STG_FIRST_EPOCH" \
        "deadline_epoch=$STG_DEADLINE_EPOCH" \
        "terminal=$STG_TERMINAL" \
        "ok=$STG_OK" \
        "result=$(stg_safe_field "$STG_RESULT")"
}

stg_commit() {
    [ "${STG_TEST_FAIL_PRIMARY_ALWAYS:-0}" != "1" ] || return 1
    if [ "${STG_TEST_FAIL_PRIMARY_TERMINAL:-0}" = "1" ] \
        && [ "$STG_TERMINAL" = "yes" ]; then
        return 1
    fi
    _stg_payload=$(stg_payload)
    stg_atomic_write "$_stg_payload"
}

stg_commit_terminal_fallback() {
    [ "$STG_TERMINAL" = "yes" ] || return 64
    [ "${STG_TEST_FAIL_TERMINAL_FALLBACK:-0}" != "1" ] || return 1
    _stg_terminal_payload=$(stg_payload)
    _stg_terminal_payload=$(printf '%s\n%s' "$_stg_terminal_payload" 'fallback=yes')
    _stg_primary_file="$STG_FILE"
    STG_FILE="$STG_TERMINAL_FILE"
    stg_atomic_write "$_stg_terminal_payload"
    _stg_terminal_rc=$?
    STG_FILE="$_stg_primary_file"
    [ "$_stg_terminal_rc" -eq 0 ] || return "$_stg_terminal_rc"
    [ "$(stg_read_file_value "$STG_TERMINAL_FILE" key 2>/dev/null)" = "$STG_KEY" ] \
        && [ "$(stg_read_file_value "$STG_TERMINAL_FILE" terminal 2>/dev/null)" = "yes" ]
}

stg_commit_terminal_bounded() {
    _stg_terminal_attempt=1
    while [ "$_stg_terminal_attempt" -le "$STG_STATE_COMMIT_ATTEMPTS" ] 2>/dev/null; do
        if stg_commit; then
            rm -f "$STG_TERMINAL_FILE" 2>/dev/null
            return 0
        fi
        _stg_terminal_attempt=$((_stg_terminal_attempt + 1))
        [ "$_stg_terminal_attempt" -gt "$STG_STATE_COMMIT_ATTEMPTS" ] 2>/dev/null \
            || sleep "$STG_STATE_COMMIT_RETRY_SLEEP_S"
    done
    stg_commit_terminal_fallback && return 0
    return 74
}

stg_reset() {
    rm -f "$STG_FILE" "$STG_TERMINAL_FILE" 2>/dev/null
    [ ! -e "$STG_FILE" ] && [ ! -e "$STG_TERMINAL_FILE" ]
}

stg_prepare_key() {
    _stg_key="$1"
    _stg_boot="$2"
    _stg_now="$3"
    stg_load
    if [ "$STG_KEY" != "$_stg_key" ] || [ "$STG_BOOT_ID" != "$_stg_boot" ]; then
        STG_KEY="$_stg_key"
        STG_BOOT_ID="$_stg_boot"
        STG_ATTEMPTS=0
        STG_FIRST_EPOCH="$_stg_now"
        STG_DEADLINE_EPOCH=$((_stg_now + STG_DEADLINE_S))
        STG_TERMINAL=no
        STG_OK=pending
        STG_RESULT=ready
        stg_commit || return 74
    fi
    return 0
}

stg_begin_attempt() {
    _stg_key="$1"
    _stg_boot="$2"
    _stg_now="$3"
    stg_prepare_key "$_stg_key" "$_stg_boot" "$_stg_now" || return $?
    if [ "$STG_TERMINAL" = "yes" ]; then
        return 77
    fi
    if [ "$STG_ATTEMPTS" -ge "$STG_MAX_ATTEMPTS" ] 2>/dev/null \
        || [ "$_stg_now" -gt "$STG_DEADLINE_EPOCH" ] 2>/dev/null; then
        STG_TERMINAL=yes
        STG_OK=no
        STG_RESULT=retry_budget_exhausted
        stg_commit_terminal_bounded >/dev/null 2>&1 || return 74
        return 78
    fi
    STG_ATTEMPTS=$((STG_ATTEMPTS + 1))
    STG_RESULT="attempt_${STG_ATTEMPTS}"
    stg_commit || return 74
    return 0
}

stg_record_failure() {
    _stg_now="$1"
    _stg_reason="$2"
    stg_load
    if [ "$STG_ATTEMPTS" -ge "$STG_MAX_ATTEMPTS" ] 2>/dev/null \
        || [ "$_stg_now" -ge "$STG_DEADLINE_EPOCH" ] 2>/dev/null; then
        STG_TERMINAL=yes
        STG_OK=no
        STG_RESULT="failed_final:${_stg_reason}"
        stg_commit_terminal_bounded || return 74
        return 1
    fi
    STG_TERMINAL=no
    STG_OK=pending
    STG_RESULT="retry_pending:${_stg_reason}"
    stg_commit || return 74
    return 0
}

stg_record_success() {
    _stg_result="$1"
    stg_load
    STG_TERMINAL=yes
    STG_OK=yes
    STG_RESULT="$_stg_result"
    stg_commit_terminal_bounded
}
