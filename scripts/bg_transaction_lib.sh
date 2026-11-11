#!/system/bin/sh
# A foreground package-policy request snapshots both actual state and all
# affected local records before the first write. It never resets unknown old
# AppOps to allow. An interrupted/failed rollback journal stays available.

# One finite user-requested operation. The receipt is not a second policy store;
# only the transaction below owns configuration and actual Android writes.
bg_operation_init() {
    BO_FILE="$MODDIR/.bg_operation"
    BO_LOCK="$MODDIR/.locks/bg_operation.lock"
    . "$MODDIR/scripts/state_io_lib.sh" && . "$MODDIR/scripts/background_tasks_lib.sh"
}

bg_operation_load() {
    BO_ID=; BO_BOOT=; BO_START=0; BO_ACTION=; BO_PACKAGE=; BO_POLICY=; BO_DELAY=
    BO_PHASE=none; BO_PENDING=false; BO_COMMITTED=false; BO_ROLLBACK=none
    BO_ERROR_CODE=; BO_ERROR=; BO_DURATION=0
    if [ -f "$BO_FILE" ]; then
        while IFS='=' read -r _bop_key _bop_value || [ -n "$_bop_key" ]; do
            case "$_bop_key" in
                id) BO_ID="$_bop_value" ;; boot) BO_BOOT="$_bop_value" ;; start) BO_START="$_bop_value" ;;
                action) BO_ACTION="$_bop_value" ;; package) BO_PACKAGE="$_bop_value" ;;
                policy) BO_POLICY="$_bop_value" ;; delay) BO_DELAY="$_bop_value" ;;
                phase) BO_PHASE="$_bop_value" ;; committed) BO_COMMITTED="$_bop_value" ;;
                rollback) BO_ROLLBACK="$_bop_value" ;; error_code) BO_ERROR_CODE="$_bop_value" ;;
                error) BO_ERROR="$_bop_value" ;; duration_ms) BO_DURATION="$_bop_value" ;;
            esac
        done < "$BO_FILE"
    fi
    case "$BO_PHASE" in queued|running)
        if [ "$BO_BOOT" = "$(cat /proc/sys/kernel/random/boot_id)" ]; then
            if module_lock_owner_alive "$BO_LOCK"; then BO_PENDING=true
            elif [ "$BO_PHASE" = queued ] && awk -v start="$BO_START" 'BEGIN {getline < "/proc/uptime"; exit !($1>=start && $1-start<=30)}'; then
                # The CGI may exit before its child publishes the new owner.
                BO_PENDING=true
            fi
        fi
        if [ "$BO_PENDING" != true ]; then
            BO_PHASE=unconfirmed; BO_ERROR_CODE=BG_WORKER_UNCONFIRMED
            BO_ERROR='后台限制任务中断，结果尚未确认；请恢复原设置后再操作'
        fi ;;
    esac
}

bg_operation_commit() {
    state_atomic_write "$BO_FILE" "id=$BO_ID
boot=$BO_BOOT
start=$BO_START
action=$BO_ACTION
package=$BO_PACKAGE
policy=$BO_POLICY
delay=$BO_DELAY
phase=$BO_PHASE
committed=$BO_COMMITTED
rollback=$BO_ROLLBACK
error_code=$BO_ERROR_CODE
error=$BO_ERROR
duration_ms=$BO_DURATION"
}

bg_operation_json() {
    printf '"operation":{"id":"%s","action":"%s","phase":"%s","pending":%s,"committed":%s,"rollback":"%s","error_code":"%s","error":"%s","duration_ms":%s}' \
        "$BO_ID" "$BO_ACTION" "$BO_PHASE" "$BO_PENDING" "$BO_COMMITTED" "$BO_ROLLBACK" \
        "$BO_ERROR_CODE" "$(json_escape "$BO_ERROR")" "$BO_DURATION"
}

bg_tx_cleanup_only() {
    [ -d "$MODDIR/.bg_policy_tx" ] && [ -n "$BO_ID" ] || return 1
    _btx_cleanup_owner=$(cat "$MODDIR/.bg_policy_tx/operation_id" 2>/dev/null)
    [ -z "$_btx_cleanup_owner" ] || [ "$_btx_cleanup_owner" = "$BO_ID" ] || return 1
    _btx_cleanup_phase=$(cat "$MODDIR/.bg_policy_tx/phase" 2>/dev/null)
    case "$BO_PHASE:$BO_COMMITTED:$BO_ROLLBACK:$_btx_cleanup_phase" in
        success:true:*:committed|success:true:*:rolled_back|failed:false:complete:rolled_back)
            [ "$_btx_cleanup_owner" = "$BO_ID" ] ;;
        # Cleanup can remove the marker before rmdir fails. A published terminal
        # receipt still owns those remnants; start never overwrites it first.
        success:true:*:|failed:false:complete:) [ -z "$_btx_cleanup_owner" ] ;;
        *) return 1 ;;
    esac
}

bg_operation_start() {
    bg_operation_load
    [ "$BO_PENDING" != true ] || return 75
    [ "$BO_PHASE" != unconfirmed ] || [ "$1" = recover ] || return 76
    state_lock_acquire "$BO_LOCK" 2 || return 75
    # Do not overwrite a published terminal receipt while its cleanup-only
    # journal remains. In particular, recover must never undo confirmed success.
    if bg_tx_cleanup_only; then
        state_lock_acquire "$MODDIR/.locks/bg_policy.lock" 2 \
            || { state_lock_release "$BO_LOCK"; return 75; }
        BG_TX_ROOT="$MODDIR/.bg_policy_tx"
        bg_tx_clear
        _bop_cleanup_rc=$?
        state_lock_release "$MODDIR/.locks/bg_policy.lock"
        if [ "$_bop_cleanup_rc" -ne 0 ]; then state_lock_release "$BO_LOCK"; return 77; fi
    elif [ -d "$MODDIR/.bg_policy_tx" ] && [ "$1" != recover ]; then
        state_lock_release "$BO_LOCK"
        return 76
    fi
    BO_BOOT=$(cat /proc/sys/kernel/random/boot_id) || { state_lock_release "$BO_LOCK"; return 1; }
    IFS=' ' read -r BO_START _bop_unused < /proc/uptime || { state_lock_release "$BO_LOCK"; return 1; }
    BO_ID="$BO_BOOT.$$.$BO_START"
    BO_ACTION="$1"; BO_PACKAGE="$2"; BO_POLICY="$3"; BO_DELAY="$4"
    BO_PHASE=queued; BO_PENDING=true; BO_COMMITTED=false; BO_ROLLBACK=none
    BO_ERROR_CODE=; BO_ERROR=; BO_DURATION=0
    if ! bg_operation_commit; then state_lock_release "$BO_LOCK"; return 1; fi
    # This private environment variable is never populated from HTTP headers or
    # query arguments. The child rechecks root, receipt and the exact job ID.
    PIXEL9PRO_BG_WORKER_ID="$BO_ID" sh "$MODDIR/webroot/cgi-bin/bg_restrict.sh" \
        >/dev/null 2>&1 </dev/null &
}

bg_operation_finish() {
    trap - EXIT HUP INT TERM
    BO_PHASE="$1"; BO_COMMITTED="$2"; BO_PENDING=false
    BO_DURATION=$(cgi_duration_ms)
    if bg_operation_commit; then
        # Keep the restoration snapshot until the operation's terminal receipt
        # is durable enough to read back. A failed receipt must remain recoverable.
        if bg_tx_cleanup_only; then
            BG_TX_ROOT="$MODDIR/.bg_policy_tx"
            bg_tx_clear || log -t pixel9pro_ctrl 'WARNING: background terminal journal cleanup pending'
        fi
    else
        [ "${BG_POLICY_LOCKED:-0}" != 1 ] || state_lock_release "$MODDIR/.locks/bg_policy.lock"
        BG_POLICY_LOCKED=0
        log -t pixel9pro_ctrl 'ERROR: background operation result persistence failed'
        return 1
    fi
    # GET holds this same lock while pairing the receipt with configuration.
    [ "${BG_POLICY_LOCKED:-0}" != 1 ] || state_lock_release "$MODDIR/.locks/bg_policy.lock" || return 1
    BG_POLICY_LOCKED=0
    state_lock_release "$BO_LOCK" || return 1
    _bop_result=failure; [ "$BO_PHASE" != success ] || _bop_result=success
    audit_log_event_async background "bg_restrict.$BO_ACTION" "$_bop_result" "${BO_ERROR_CODE:-BG_COMMITTED}" "$BO_DURATION"
    (. "$MODDIR/scripts/module_metadata_lib.sh" && module_description_refresh "$MODDIR") \
        >/dev/null 2>&1 </dev/null &
}

bg_request_error() {
    CGI_ERROR_CODE="$3"
    if [ "${BG_OPERATION_WORKER:-0}" != 1 ]; then json_error "$1" "$2"; fi
    BO_ERROR_CODE="$3"; BO_ERROR="$2"; BO_ROLLBACK=none
    _btx_error_phase=$(cat "$MODDIR/.bg_policy_tx/phase" 2>/dev/null)
    _btx_error_owner=$(cat "$MODDIR/.bg_policy_tx/operation_id" 2>/dev/null)
    if [ "$_btx_error_phase" = committed ] && [ "$_btx_error_owner" = "$BO_ID" ]; then
        # A signal after the transaction marker but before success publication
        # still owns a complete rollback snapshot. Do not report uncommitted
        # failure while leaving its Android writes in place.
        BG_TX_ACTIVE=1
    fi
    if [ "${BG_TX_ACTIVE:-0}" = 1 ]; then
        if bg_tx_rollback; then BO_ROLLBACK=complete
        else BO_ROLLBACK=incomplete; BO_ERROR="$BO_ERROR; rollback incomplete, recovery journal retained"; fi
    elif [ "$_btx_error_phase" = rolled_back ] && [ "$_btx_error_owner" = "$BO_ID" ]; then
        BO_ROLLBACK=complete
    elif [ "$BO_ACTION" = recover ] && [ -d "$MODDIR/.bg_policy_tx" ]; then
        BO_ROLLBACK=incomplete
    fi
    bg_operation_finish failed false
    exit 1
}

bg_tx_begin() {
    . "$MODDIR/scripts/state_io_lib.sh" || return 1
    BG_TX_ROOT="$MODDIR/.bg_policy_tx"
    if [ -d "$BG_TX_ROOT" ] && [ ! -L "$BG_TX_ROOT" ]; then
        case "$(cat "$BG_TX_ROOT/phase" 2>/dev/null)" in
            committed|rolled_back) bg_tx_clear || return 75 ;;
            *) return 75 ;;
        esac
    fi
    (umask 077; mkdir "$BG_TX_ROOT") || return 75
    chmod 700 "$BG_TX_ROOT" || return 1
    BG_TX_ACTIVE=0
    if [ "${BG_OPERATION_WORKER:-0}" = 1 ]; then
        state_atomic_write "$BG_TX_ROOT/operation_id" "$BO_ID" || { bg_tx_clear; return 1; }
    fi
    for _btx_name in .bg_restrict_list .bg_restrict_enabled .bg_restrict_baseline .bg_restrict_stop_state .bg_restrict_observed; do
        _btx_path="$MODDIR/$_btx_name"
        state_read_entry "$_btx_path" >/dev/null || { bg_tx_clear; return 1; }
        if [ -e "$_btx_path" ]; then
            cp "$_btx_path" "$BG_TX_ROOT/$_btx_name" \
                && chmod 600 "$BG_TX_ROOT/$_btx_name" \
                && cmp -s "$_btx_path" "$BG_TX_ROOT/$_btx_name" \
                && : > "$BG_TX_ROOT/$_btx_name.present" || { bg_tx_clear; return 1; }
        fi
    done
    _btx_packages=''
    case "$1" in
        add|update|remove) _btx_packages="$2" ;;
        toggle|refresh)
            if [ -e "$BG_LIST_FILE" ]; then
                _btx_packages=$(awk -F'|' '$0 !~ /^#/ && $1!="" { print $1 }' "$BG_LIST_FILE") || { bg_tx_clear; return 1; }
            fi ;;
        *) bg_tx_clear; return 1 ;;
    esac
    case "$1" in add|update|remove)
        [ "$(bg_read_enabled)" = on ] || _btx_packages='' ;;
    esac
    if [ "$1" = remove ] && [ -n "$_btx_packages" ]; then
        bg_package_presence "$2"
        _btx_presence=$?
        case "$_btx_presence" in 0) ;; 1) _btx_packages='' ;; *) bg_tx_clear; return 1 ;; esac
    fi
    _btx_count=$(printf '%s\n' "$_btx_packages" | awk 'NF {n++} END {print n+0}')
    [ "$_btx_count" -le "$BG_MAX_PACKAGES" ] || { bg_tx_clear; return 1; }
    : > "$BG_TX_ROOT/runtime" || { bg_tx_clear; return 1; }
    chmod 600 "$BG_TX_ROOT/runtime" || { bg_tx_clear; return 1; }
    for _btx_pkg in $_btx_packages; do
        case "$_btx_pkg" in ''|*[!A-Za-z0-9._]*) bg_tx_clear; return 1 ;; esac
        bg_package_presence "$_btx_pkg"
        _btx_presence=$?
        case "$_btx_presence" in 0) ;; 1) continue ;; *) bg_tx_clear; return 1 ;; esac
        _btx_bucket=$(bg_read_standby_bucket "$_btx_pkg")
        _btx_bucket_arg=$(bg_bucket_to_set_arg "$_btx_bucket")
        _btx_bg=$(bg_read_appop_mode "$_btx_pkg" RUN_IN_BACKGROUND) \
            && _btx_any=$(bg_read_appop_mode "$_btx_pkg" RUN_ANY_IN_BACKGROUND) \
            && [ -n "$_btx_bucket_arg" ] || { bg_tx_clear; return 1; }
        printf '%s|%s|%s|%s\n' "$_btx_pkg" "$_btx_bucket_arg" "$_btx_bg" "$_btx_any" \
            >> "$BG_TX_ROOT/runtime" || { bg_tx_clear; return 1; }
    done
    state_atomic_write "$BG_TX_ROOT/phase" prepared || { bg_tx_clear; return 1; }
    BG_TX_ACTIVE=1
}

bg_tx_clear() {
    [ -n "${BG_TX_ROOT:-}" ] && [ ! -L "$BG_TX_ROOT" ] || return 1
    for _btx_name in .bg_restrict_list .bg_restrict_enabled .bg_restrict_baseline .bg_restrict_stop_state .bg_restrict_observed; do
        rm -f "$BG_TX_ROOT/$_btx_name" "$BG_TX_ROOT/$_btx_name.present" || return 1
    done
    rm -f "$BG_TX_ROOT/runtime" "$BG_TX_ROOT/phase" "$BG_TX_ROOT/operation_id" && rmdir "$BG_TX_ROOT"
}

bg_tx_rollback() {
    [ "${BG_TX_ACTIVE:-0}" = 1 ] || return 0
    bg_tx_validate || { BG_TX_ACTIVE=0; return 1; }
    _btx_restore_failed=0
    while IFS='|' read -r _btx_pkg _btx_bucket _btx_bg _btx_any; do
        bg_am set-standby-bucket --user "$BG_USER_ID" "$_btx_pkg" "$_btx_bucket" \
            && bg_set_appop_mode "$_btx_pkg" RUN_IN_BACKGROUND "$_btx_bg" \
            && bg_set_appop_mode "$_btx_pkg" RUN_ANY_IN_BACKGROUND "$_btx_any" \
            && bg_bucket_matches "$_btx_pkg" "$_btx_bucket" \
            && bg_appop_matches "$_btx_pkg" RUN_IN_BACKGROUND "$_btx_bg" \
            && bg_appop_matches "$_btx_pkg" RUN_ANY_IN_BACKGROUND "$_btx_any" || _btx_restore_failed=1
    done < "$BG_TX_ROOT/runtime"
    for _btx_name in .bg_restrict_list .bg_restrict_enabled .bg_restrict_baseline .bg_restrict_stop_state .bg_restrict_observed; do
        if [ -f "$BG_TX_ROOT/$_btx_name.present" ]; then
            state_atomic_from_file "$MODDIR/$_btx_name" "$BG_TX_ROOT/$_btx_name" || _btx_restore_failed=1
        else
            rm -f "$MODDIR/$_btx_name" && [ ! -e "$MODDIR/$_btx_name" ] || _btx_restore_failed=1
        fi
    done
    BG_TX_ACTIVE=0
    [ "$_btx_restore_failed" -eq 0 ] || return 1
    state_atomic_write "$BG_TX_ROOT/phase" rolled_back || return 1
    if [ "${BG_OPERATION_WORKER:-0}" != 1 ]; then
        bg_tx_clear || log -t pixel9pro_ctrl 'WARNING: restored background journal cleanup pending'
    fi
    return 0
}

bg_tx_validate() {
    [ -d "$BG_TX_ROOT" ] && [ ! -L "$BG_TX_ROOT" ] \
        && [ -f "$BG_TX_ROOT/runtime" ] && [ -r "$BG_TX_ROOT/runtime" ] \
        && [ ! -L "$BG_TX_ROOT/runtime" ] || return 1
    case "$(state_read_entry "$BG_TX_ROOT/phase")" in prepared|committed|rolled_back) ;; *) return 1 ;; esac
    for _btx_name in .bg_restrict_list .bg_restrict_enabled .bg_restrict_baseline .bg_restrict_stop_state .bg_restrict_observed; do
        [ ! -L "$BG_TX_ROOT/$_btx_name.present" ] || return 1
        if [ -f "$BG_TX_ROOT/$_btx_name.present" ]; then
            [ -f "$BG_TX_ROOT/$_btx_name" ] || return 1
            state_read_entry "$BG_TX_ROOT/$_btx_name" >/dev/null || return 1
        fi
    done
    awk -F'|' '
        NF!=4 || $1 !~ /^[A-Za-z0-9_.]+$/ || seen[$1]++ { exit 1 }
        $2 !~ /^(exempted|active|working_set|frequent|rare|restricted|never)$/ { exit 1 }
        $3 !~ /^(allow|ignore|deny|default|foreground)$/ || $4 !~ /^(allow|ignore|deny|default|foreground)$/ { exit 1 }
    ' "$BG_TX_ROOT/runtime"
}

bg_tx_recover() {
    . "$MODDIR/scripts/state_io_lib.sh" || return 1
    BG_TX_ROOT="$MODDIR/.bg_policy_tx"
    [ -d "$BG_TX_ROOT" ] && [ ! -L "$BG_TX_ROOT" ] || return 0
    _btx_phase=$(state_read_entry "$BG_TX_ROOT/phase") || return 1
    case "$_btx_phase" in
        prepared|committed|rolled_back)
            if [ "${BG_OPERATION_WORKER:-0}" = 1 ]; then
                state_atomic_write "$BG_TX_ROOT/operation_id" "$BO_ID" || return 1
            fi
            BG_TX_ACTIVE=1; bg_tx_rollback ;;
        '')
            # No prepared marker means begin never authorized a mutation.
            # Only the fixed snapshot filenames may be removed here.
            bg_tx_clear ;;
        *) return 1 ;;
    esac
}

bg_tx_commit() {
    [ "${BG_TX_ACTIVE:-0}" = 1 ] || return 1
    state_atomic_write "$BG_TX_ROOT/phase" committed || return 1
    BG_TX_ACTIVE=0
    if [ "${BG_OPERATION_WORKER:-0}" != 1 ]; then
        bg_tx_clear || log -t pixel9pro_ctrl 'WARNING: committed background journal cleanup pending'
    fi
    return 0
}
