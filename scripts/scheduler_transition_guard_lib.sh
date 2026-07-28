#!/system/bin/sh

# Bounded mutation guard shared by scheduler/profile transactions. It never
# writes scheduler nodes; it only latches attempts and terminal outcomes.

STG_MAX_ATTEMPTS="${STG_MAX_ATTEMPTS:-3}"
STG_DEADLINE_S="${STG_DEADLINE_S:-30}"

stg_init() {
    STG_FILE="$1"
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
}

stg_commit() {
    _stg_payload=$(printf '%s\n' \
        "key=$(stg_safe_field "$STG_KEY")" \
        "boot_id=$(stg_safe_field "$STG_BOOT_ID")" \
        "attempts=$STG_ATTEMPTS" \
        "first_epoch=$STG_FIRST_EPOCH" \
        "deadline_epoch=$STG_DEADLINE_EPOCH" \
        "terminal=$STG_TERMINAL" \
        "ok=$STG_OK" \
        "result=$(stg_safe_field "$STG_RESULT")")
    stg_atomic_write "$_stg_payload"
}

stg_reset() {
    rm -f "$STG_FILE" 2>/dev/null
    [ ! -e "$STG_FILE" ]
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
        stg_commit >/dev/null 2>&1 || true
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
        stg_commit
        return 1
    fi
    STG_TERMINAL=no
    STG_OK=pending
    STG_RESULT="retry_pending:${_stg_reason}"
    stg_commit
    return 0
}

stg_record_success() {
    _stg_result="$1"
    stg_load
    STG_TERMINAL=yes
    STG_OK=yes
    STG_RESULT="$_stg_result"
    stg_commit
}
