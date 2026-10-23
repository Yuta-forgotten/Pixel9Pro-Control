#!/system/bin/sh

# Thermal desired-state endpoint. The regular source is the only mount input;
# this journal makes the source change reversible before the next reboot.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback

MODDIR="${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}"
THERMAL_PROFILE_LIB="$MODDIR/scripts/thermal_profile.sh"
THERMAL_POLICY_LIB="$MODDIR/scripts/thermal_policy_lib.sh"
[ -r "$THERMAL_PROFILE_LIB" ] && . "$THERMAL_PROFILE_LIB" \
    || json_error '500 Internal Server Error' 'thermal profile library not found'
[ -r "$THERMAL_POLICY_LIB" ] && . "$THERMAL_POLICY_LIB" && thermal_policy_init "$MODDIR" \
    || json_error '500 Internal Server Error' 'thermal policy library not found'

THERMAL_MOUNT_BACKEND=none
THERMAL_METAMODULE_ACTIVE=0
thermal_policy_detect_mount_backend

DEVICE=$(cat "$MODDIR/.device_variant" 2>/dev/null | tr -d ' \r\n\t')
case "$DEVICE" in caiman|komodo) ;; *) json_error '500 Internal Server Error' 'invalid device variant' ;; esac
STOCK_JSON=$(thermal_policy_snapshot_path "$DEVICE") \
    || json_error '500 Internal Server Error' 'cannot resolve thermal stock snapshot'

parse_thermal_json() {
    # This endpoint accepts only a flat, typed request. Validate the complete
    # body before any mutation; a numeric prefix must never become an offset.
    THERMAL_JSON_FIELDS=$(printf '%s' "$1" | awk '
    function ws() { sub(/^[ \t\r\n]+/, "", s) }
    function fail() { invalid=1; exit 1 }
    { s=s $0 "\n" }
    END {
        if (invalid) exit 1
        ws(); if (substr(s,1,1)!="{") fail()
        s=substr(s,2); ws()
        while (substr(s,1,1)!="}") {
            if (!match(s,/^"[a-z_]+"/)) fail()
            key=substr(s,2,RLENGTH-2); s=substr(s,RLENGTH+1); ws()
            if (seen[key]++ || substr(s,1,1)!=":") fail()
            if (key !~ /^(policy|offset|action|pending_id)$/) fail()
            s=substr(s,2); ws()
            if (key=="offset") {
                if (!match(s,/^-?(0|[1-9][0-9]*)/)) fail()
                value=substr(s,1,RLENGTH); s=substr(s,RLENGTH+1)
            } else {
                if (!match(s,/^"[A-Za-z0-9_.-]+"/)) fail()
                value=substr(s,2,RLENGTH-2); s=substr(s,RLENGTH+1)
            }
            fields=fields key "\t" value "\n"; ws()
            if (substr(s,1,1)=="}") break
            if (substr(s,1,1)!=",") fail()
            s=substr(s,2); ws(); if (substr(s,1,1)=="}") fail()
        }
        s=substr(s,2); ws(); if (s!="") fail()
        if (!seen["policy"] && !seen["offset"] && !seen["action"]) fail()
        if (seen["action"] && (seen["policy"] || seen["offset"])) fail()
        if (seen["pending_id"] && !seen["action"]) fail()
        printf "%s", fields
    }') || return 1
}

thermal_json_field() {
    printf '%s\n' "$THERMAL_JSON_FIELDS" | awk -F '\t' -v key="$1" '$1==key { print $2; exit }'
}

thermal_emit_contract() { thermal_print_ui_contract_json; }

# The POST commit path already owns the thermal lock and has just written the
# staged journal. Re-reading every receipt/hash field through thermal_emit_state
# adds several dozen shell pipelines to the user-visible response. Emit the
# authoritative staged contract from the values committed in this request; a
# later GET still performs the full readback path.
thermal_emit_staged_state() {
    _tes_policy="$1"
    _tes_offset="$2"
    _tes_source_hash="$3"
    _tes_effective_hash="$4"
    _tes_source_context="$5"
    _tes_effective_context="$6"
    _tes_pending_id="$7"
    printf '"policy":"%s","offset":%s,"mount_backend":"%s","metamodule_active":%s,' \
        "$_tes_policy" "$_tes_offset" "$THERMAL_MOUNT_BACKEND" \
        "$([ "$THERMAL_METAMODULE_ACTIVE" -eq 1 ] && printf true || printf false)"
    printf '"reinstall_required":%s,"repair_required":false,"pending":true,"pending_id":"%s","cancel_supported":true,' \
        "$([ "$THERMAL_MOUNT_BACKEND" = metamodule_content ] && printf true || printf false)" \
        "$_tes_pending_id"
    printf '"reboot_required":true,"effective_state":"pending_reboot",'
    printf '"source_hash":"%s","effective_hash":"%s",' \
        "$_tes_source_hash" "$_tes_effective_hash"
    printf '"source_context":"%s","effective_context":"%s","thermal_contract":' \
        "$_tes_source_context" "$_tes_effective_context"
    thermal_emit_contract
}

# Cancellation already restored the previous source and policy under the
# mutation lock. Return that committed state directly; the next GET performs
# the authoritative effective-path/hash readback in the background instead of
# making the button wait through a second full thermal scan.
thermal_emit_cancelled_state() {
    _tec_policy="$1"
    _tec_offset="$2"
    _tec_source_hash="$3"
    _tec_source_context="$4"
    _tec_effective_hash=$(thermal_policy_effective_hash)
    _tec_effective_context=$(thermal_policy_effective_context)
    printf '"policy":"%s","offset":%s,"mount_backend":"%s","metamodule_active":%s,' \
        "$_tec_policy" "$_tec_offset" "$THERMAL_MOUNT_BACKEND" \
        "$([ "$THERMAL_METAMODULE_ACTIVE" -eq 1 ] && printf true || printf false)"
    printf '"reinstall_required":%s,"repair_required":false,"pending":false,"pending_id":"","cancel_supported":false,' \
        "$([ "$THERMAL_MOUNT_BACKEND" = metamodule_content ] && printf true || printf false)"
    printf '"reboot_required":false,"effective_state":"restored_pending_readback",'
    printf '"source_hash":"%s","effective_hash":"%s",' \
        "$_tec_source_hash" "$_tec_effective_hash"
    printf '"source_context":"%s","effective_context":"%s","thermal_contract":' \
        "$_tec_source_context" "$_tec_effective_context"
    thermal_emit_contract
}

thermal_emit_state() {
    _ts_policy=$(thermal_policy_read)
    _ts_offset=$(thermal_policy_offset_read)
    _ts_offset=$(thermal_normalize_offset "$_ts_offset" "$THERMAL_DEFAULT_OFFSET")
    _ts_source_hash=$(thermal_policy_source_hash)
    _ts_effective_hash=$(thermal_policy_effective_hash)
    _ts_source_context=$(thermal_policy_source_context)
    _ts_effective_context=$(thermal_policy_effective_context)
    thermal_policy_transaction_load
    _ts_effective_state=degraded
    if thermal_policy_transaction_pending; then
        _ts_tx_boot="$THERMAL_TX_CACHE_BOOT_ID"
        _ts_current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')
        if [ -n "$_ts_tx_boot" ] && [ "$_ts_tx_boot" = "$_ts_current_boot" ]; then
            _ts_effective_state=pending_reboot
            [ "$THERMAL_TX_CACHE_PHASE" != repair_pending ] || _ts_effective_state=repair_pending
        else
            _ts_effective_state=degraded
        fi
    elif thermal_policy_readback_check "$_ts_policy"; then
        _ts_effective_state=effective
    fi
    _ts_reinstall=false
    [ "$THERMAL_MOUNT_BACKEND" = metamodule_content ] && _ts_reinstall=true
    _ts_repair=false
    [ "$_ts_policy" = custom ] && [ "$_ts_source_hash" = none ] && _ts_repair=true
    [ "$_ts_policy" = system ] && [ "$_ts_source_hash" != none ] && _ts_repair=true
    if [ "$THERMAL_TX_CACHE_PHASE" = repair_failed ]; then
        _ts_effective_state=degraded
        _ts_repair=true
    fi
    _ts_pending=false
    _ts_pending_id=""
    _ts_cancel_supported=false
    if thermal_policy_transaction_pending; then
        _ts_pending=true
        _ts_pending_id="$THERMAL_TX_CACHE_ID"
        _ts_tx_phase="$THERMAL_TX_CACHE_PHASE"
        _ts_tx_boot="$THERMAL_TX_CACHE_BOOT_ID"
        _ts_base_valid="$THERMAL_TX_CACHE_BASE_VALID"
        _ts_current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')
        [ "$_ts_tx_phase" = staged ] && [ "$_ts_base_valid" = 1 ] && [ -n "$_ts_tx_boot" ] \
            && [ "$_ts_tx_boot" = "$_ts_current_boot" ] \
            && _ts_cancel_supported=true
    fi
    _ts_reboot_required=false
    [ "$_ts_pending" = true ] && _ts_reboot_required=true
    printf '"policy":"%s","offset":%s,"mount_backend":"%s","metamodule_active":%s,' \
        "$_ts_policy" "$_ts_offset" "$THERMAL_MOUNT_BACKEND" \
        "$([ "$THERMAL_METAMODULE_ACTIVE" -eq 1 ] && printf true || printf false)"
    printf '"reinstall_required":%s,"repair_required":%s,"pending":%s,"pending_id":"%s","cancel_supported":%s,' \
        "$_ts_reinstall" "$_ts_repair" "$_ts_pending" "$_ts_pending_id" \
        "$_ts_cancel_supported"
    printf '"reboot_required":%s,"effective_state":"%s",' \
        "$_ts_reboot_required" "$_ts_effective_state"
    printf '"source_hash":"%s","effective_hash":"%s",' "$_ts_source_hash" "$_ts_effective_hash"
    printf '"source_context":"%s","effective_context":"%s","thermal_contract":' \
        "$_ts_source_context" "$_ts_effective_context"
    thermal_emit_contract
}

thermal_tx_snapshot() {
    [ ! -e "$THERMAL_TX_META" ] || return 1
    mkdir -p "$THERMAL_TX_ROOT" 2>/dev/null || return 1
    chmod 700 "$THERMAL_TX_ROOT" 2>/dev/null || return 1
    _tx_id="$(date +%s 2>/dev/null || echo 0).$$"
    _tx_old_policy=$(thermal_policy_read)
    _tx_old_offset=$(thermal_policy_offset_read)
    _tx_old_present=0
    _tx_old_hash=none
    _tx_old_context=none
    _tx_base_valid=1
    if [ -e "$THERMAL_SOURCE_FILE" ]; then
        _tx_old_present=1
        _tx_old_hash=$(sha256sum "$THERMAL_SOURCE_FILE" 2>/dev/null | awk '{print $1}')
        _tx_old_context=$(thermal_policy_source_context)
        [ -n "$_tx_old_hash" ] || return 1
        # The journal and regular source live in the same module filesystem on
        # APatch/Hybrid Mount. Preserve the old inode with a hard-link so a
        # staged rename does not copy the payload; fall back to a copy when a
        # backend uses a filesystem that rejects links.
        if ! ln "$THERMAL_SOURCE_FILE" "$THERMAL_TX_SOURCE.tmp.$$" 2>/dev/null; then
            cp -f "$THERMAL_SOURCE_FILE" "$THERMAL_TX_SOURCE.tmp.$$" || return 1
        fi
        mv -f "$THERMAL_TX_SOURCE.tmp.$$" "$THERMAL_TX_SOURCE" || return 1
    fi
    if [ "$_tx_old_policy" = custom ] && [ "$_tx_old_present" -ne 1 ]; then _tx_base_valid=0; fi
    if [ "$_tx_old_policy" = system ] && [ "$_tx_old_present" -eq 1 ]; then _tx_base_valid=0; fi
    _tx_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')
    cgi_atomic_write "$THERMAL_TX_META" "$(printf 'id=%s\nphase=staged\nboot_id=%s\npolicy=%s\noffset=%s\npresent=%s\nhash=%s\ncontext=%s\nbase_valid=%s' \
        "$_tx_id" "$_tx_boot_id" "$_tx_old_policy" "$_tx_old_offset" "$_tx_old_present" "$_tx_old_hash" "$_tx_old_context" "$_tx_base_valid")" \
        || { rm -f "$THERMAL_TX_SOURCE"; rmdir "$THERMAL_TX_ROOT" 2>/dev/null || true; return 1; }
}

thermal_tx_restore() {
    THERMAL_RESTORE_RESULT=invalid_base
    [ -s "$THERMAL_TX_META" ] || return 1
    thermal_policy_transaction_load
    _tx_present="$THERMAL_TX_CACHE_PRESENT"
    _tx_policy="$THERMAL_TX_CACHE_POLICY"
    _tx_offset="$THERMAL_TX_CACHE_OFFSET"
    thermal_policy_is_valid "$_tx_policy" || return 1
    if [ "$_tx_policy" = custom ]; then
        thermal_is_valid_offset "$_tx_offset" || return 1
    fi
    case "$_tx_present" in 0|1) ;; *) return 1 ;; esac
    if [ "$_tx_present" = 1 ]; then
        [ -f "$THERMAL_TX_SOURCE" ] || return 1
        [ "$(sha256sum "$THERMAL_TX_SOURCE" 2>/dev/null | awk '{print $1}')" = "$THERMAL_TX_CACHE_HASH" ] || return 1
    fi

    # A cancel is a transaction too: retain the desired source and both state
    # files until the old state and journal cleanup have all been read back.
    _tr_current_present=0
    _tr_current_hash=none
    _tr_current_context=none
    _tr_current_mode=644
    _tr_policy_present=0
    _tr_offset_present=0
    [ ! -e "$THERMAL_POLICY_FILE" ] || _tr_policy_present=1
    [ ! -e "$THERMAL_OFFSET_FILE" ] || _tr_offset_present=1
    _tr_policy=$(cat "$THERMAL_POLICY_FILE" 2>/dev/null)
    _tr_offset=$(cat "$THERMAL_OFFSET_FILE" 2>/dev/null)
    _tr_meta=$(cat "$THERMAL_TX_META" 2>/dev/null) || return 1
    _tr_current_backup="$THERMAL_TX_ROOT/restore_current.$$"
    _tr_base_backup="$THERMAL_TX_ROOT/restore_base.$$"
    _tx_restore_tmp="$THERMAL_SOURCE_FILE.tmp.$$"
    thermal_tx_restore_link() {
        rm -f "$2" 2>/dev/null || return 1
        if ! ln "$1" "$2" 2>/dev/null; then
            cp -p "$1" "$2" 2>/dev/null || return 1
            [ -z "$3" ] || [ "$3" = none ] || chcon "$3" "$2" 2>/dev/null || true
        fi
    }
    if [ -e "$THERMAL_SOURCE_FILE" ]; then
        [ -f "$THERMAL_SOURCE_FILE" ] || return 1
        _tr_current_present=1
        _tr_current_hash=$(thermal_policy_source_hash)
        _tr_current_context=$(thermal_policy_source_context)
        _tr_current_mode=$(stat -c '%a' "$THERMAL_SOURCE_FILE" 2>/dev/null) || return 1
        thermal_tx_restore_link "$THERMAL_SOURCE_FILE" "$_tr_current_backup" "$_tr_current_context" || return 1
    fi
    if [ "$_tx_present" = 1 ]; then
        thermal_tx_restore_link "$THERMAL_TX_SOURCE" "$_tr_base_backup" "$THERMAL_TX_CACHE_CONTEXT" \
            || { rm -f "$_tr_current_backup"; return 1; }
    fi
    _tr_applied=1
    if [ "$_tx_present" = 1 ]; then
        mkdir -p "${THERMAL_SOURCE_FILE%/*}" \
            && thermal_tx_restore_link "$THERMAL_TX_SOURCE" "$_tx_restore_tmp" "$THERMAL_TX_CACHE_CONTEXT" \
            && chmod 0644 "$_tx_restore_tmp" 2>/dev/null \
            && mv -f "$_tx_restore_tmp" "$THERMAL_SOURCE_FILE" || _tr_applied=0
    else
        rm -f "$THERMAL_SOURCE_FILE" || _tr_applied=0
    fi
    if [ "$_tr_applied" = 1 ] \
        && cgi_atomic_write "$THERMAL_POLICY_FILE" "$_tx_policy" \
        && cgi_atomic_write "$THERMAL_OFFSET_FILE" "$_tx_offset" \
        && [ "$(thermal_policy_source_hash)" = "$THERMAL_TX_CACHE_HASH" ] \
        && [ "$(thermal_policy_read)" = "$_tx_policy" ] \
        && [ "$(thermal_policy_offset_read)" = "$_tx_offset" ] \
        && thermal_policy_transaction_clear; then
        rm -f "$_tr_current_backup" "$_tr_base_backup" "$_tx_restore_tmp" 2>/dev/null
        rmdir "$THERMAL_TX_ROOT" 2>/dev/null || true
        THERMAL_RESTORE_RESULT=restored
        return 0
    fi

    # Restore the cancellation's entry state. Keep the original journal
    # retryable even if its cleanup failed after deleting only one file.
    _tr_rollback=1
    mkdir -p "$THERMAL_TX_ROOT" "${THERMAL_SOURCE_FILE%/*}" || _tr_rollback=0
    if [ "$_tx_present" = 1 ]; then
        thermal_tx_restore_link "$_tr_base_backup" "$THERMAL_TX_SOURCE" "$THERMAL_TX_CACHE_CONTEXT" || _tr_rollback=0
    else
        rm -f "$THERMAL_TX_SOURCE" || _tr_rollback=0
    fi
    cgi_atomic_write "$THERMAL_TX_META" "$_tr_meta" || _tr_rollback=0
    if [ "$_tr_current_present" = 1 ]; then
        thermal_tx_restore_link "$_tr_current_backup" "$_tx_restore_tmp" "$_tr_current_context" \
            && chmod "$_tr_current_mode" "$_tx_restore_tmp" 2>/dev/null \
            && mv -f "$_tx_restore_tmp" "$THERMAL_SOURCE_FILE" || _tr_rollback=0
    else
        rm -f "$THERMAL_SOURCE_FILE" || _tr_rollback=0
    fi
    cgi_restore_file "$THERMAL_POLICY_FILE" "$_tr_policy_present" "$_tr_policy" || _tr_rollback=0
    cgi_restore_file "$THERMAL_OFFSET_FILE" "$_tr_offset_present" "$_tr_offset" || _tr_rollback=0
    [ "$(thermal_policy_source_hash)" = "$_tr_current_hash" ] \
        && [ "$(cat "$THERMAL_TX_META" 2>/dev/null)" = "$_tr_meta" ] \
        && [ "$(cat "$THERMAL_POLICY_FILE" 2>/dev/null)" = "$_tr_policy" ] \
        && [ "$(cat "$THERMAL_OFFSET_FILE" 2>/dev/null)" = "$_tr_offset" ] || _tr_rollback=0
    if [ "$_tr_current_present" = 1 ]; then
        [ "$(thermal_policy_source_context)" = "$_tr_current_context" ] \
            && [ "$(stat -c '%a' "$THERMAL_SOURCE_FILE" 2>/dev/null)" = "$_tr_current_mode" ] || _tr_rollback=0
    else
        [ ! -e "$THERMAL_SOURCE_FILE" ] || _tr_rollback=0
    fi
    if [ "$_tx_present" = 1 ]; then
        [ "$(sha256sum "$THERMAL_TX_SOURCE" 2>/dev/null | awk '{print $1}')" = "$THERMAL_TX_CACHE_HASH" ] || _tr_rollback=0
    else
        [ ! -e "$THERMAL_TX_SOURCE" ] || _tr_rollback=0
    fi
    if [ "$_tr_rollback" = 1 ]; then
        rm -f "$_tr_current_backup" "$_tr_base_backup" "$_tx_restore_tmp" 2>/dev/null
        THERMAL_RESTORE_RESULT=rolled_back
        return 1
    fi
    THERMAL_RESTORE_RESULT=rollback_incomplete
    return 2
}

if [ "$REQUEST_METHOD" = GET ]; then
    acquire_lock thermal
    json_headers
    printf '{'; thermal_emit_state; printf '}\n'
    release_lock
    exit 0
fi

require_json_post
require_token
acquire_lock thermal
read_json_body 512
parse_thermal_json "$JSON_BODY" || json_error '400 Bad Request' 'invalid thermal JSON request'
_action=$(thermal_json_field action)

if [ "$_action" = cancel_pending ]; then
    thermal_policy_transaction_load
    _requested_id=$(thermal_json_field pending_id)
    _current_id="$THERMAL_TX_CACHE_ID"
    _tx_phase="$THERMAL_TX_CACHE_PHASE"
    _tx_boot="$THERMAL_TX_CACHE_BOOT_ID"
    _tx_base_valid="$THERMAL_TX_CACHE_BASE_VALID"
    _current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')
    [ -n "$_current_id" ] && [ "$_requested_id" = "$_current_id" ] \
        || { release_lock; json_error '409 Conflict' 'pending_id 不匹配或不存在'; }
    [ "$_tx_phase" = staged ] \
        || { release_lock; json_error '409 Conflict' '该 thermal journal 已进入不可撤销状态'; }
    [ "$_tx_base_valid" = 1 ] \
        || { release_lock; json_error '409 Conflict' '旧状态缺少可验证基线，请先完成系统修复'; }
    if [ "$_tx_boot" != "$_current_boot" ]; then
        if thermal_policy_readback_check "$(thermal_policy_read)"; then
            thermal_policy_transaction_clear >/dev/null 2>&1 || true
            release_lock
            json_error '409 Conflict' '该变更已在本次启动生效，请刷新状态';
        else
            release_lock
            json_error '409 Conflict' '该变更跨越启动周期且当前 readback 未确认，禁止撤销';
        fi
    fi
    _tx_desired_policy="$THERMAL_TX_CACHE_DESIRED_POLICY"
    _tx_desired_offset="$THERMAL_TX_CACHE_DESIRED_OFFSET"
    _tx_desired_hash="$THERMAL_TX_CACHE_DESIRED_HASH"
    _tx_previous_hash="$THERMAL_TX_CACHE_HASH"
    _tx_previous_context="$THERMAL_TX_CACHE_CONTEXT"
    [ "$(thermal_policy_read)" = "$_tx_desired_policy" ] \
        && [ "$(thermal_policy_offset_read)" = "$_tx_desired_offset" ] \
        && [ "$(thermal_policy_source_hash)" = "$_tx_desired_hash" ] \
        || { release_lock; json_error '409 Conflict' '当前 source 已变化，请刷新状态后再撤销'; }
    if ! thermal_tx_restore; then
        release_lock
        case "$THERMAL_RESTORE_RESULT" in
            rolled_back) json_error '500 Internal Server Error' 'THERMAL_CANCEL_FAILED_DESIRED_STATE_RESTORED' ;;
            rollback_incomplete) json_error '500 Internal Server Error' 'THERMAL_CANCEL_ROLLBACK_INCOMPLETE' ;;
            *) json_error '500 Internal Server Error' '撤销失败，旧 source 未确认恢复' ;;
        esac
    fi
    json_headers
    printf '{"ok":true,"canceled":true,'
    thermal_emit_cancelled_state "$_tx_policy" "$_tx_offset" \
        "$_tx_previous_hash" "$_tx_previous_context"
    printf '}\n'
    release_lock
    audit_log_event_async thermal cancel success THERMAL_CANCELED 0
    exit 0
fi
if [ "$_action" = repair_system ]; then
    # Keep the accepted repair across independent GETs/reboot. Reuse the same
    # journal owner as policy staging; a second write cannot erase its evidence.
    thermal_policy_transaction_load
    if thermal_policy_transaction_pending; then
        [ "$THERMAL_TX_CACHE_PHASE" = repair_pending ] \
            && [ "$THERMAL_TX_CACHE_BOOT_ID" = "$(cat /proc/sys/kernel/random/boot_id)" ] \
            && [ "$(cat "$THERMAL_POLICY_FILE" 2>/dev/null)" = system ] \
            && [ "$(cat "$THERMAL_OFFSET_FILE" 2>/dev/null)" = 0 ] \
            && [ "$(thermal_policy_source_hash)" = none ] \
            || json_error '409 Conflict' 'THERMAL_PENDING_TRANSACTION_REQUIRES_RECONCILIATION'
    else
        [ ! -L "$THERMAL_SOURCE_FILE" ] && [ ! -d "$THERMAL_SOURCE_FILE" ] \
            || json_error '409 Conflict' 'thermal repair source is not a regular file'
        _repair_policy_present=0; _repair_offset_present=0
        [ ! -e "$THERMAL_POLICY_FILE" ] || _repair_policy_present=1
        [ ! -e "$THERMAL_OFFSET_FILE" ] || _repair_offset_present=1
        _repair_policy_before=''; _repair_offset_before=''
        if [ "$_repair_policy_present" = 1 ]; then
            _repair_policy_before=$(cat "$THERMAL_POLICY_FILE") \
                || json_error '503 Service Unavailable' 'cannot read thermal repair entry policy'
        fi
        if [ "$_repair_offset_present" = 1 ]; then
            _repair_offset_before=$(cat "$THERMAL_OFFSET_FILE") \
                || json_error '503 Service Unavailable' 'cannot read thermal repair entry offset'
        fi
        _repair_source_mode=644
        [ ! -e "$THERMAL_SOURCE_FILE" ] || _repair_source_mode=$(stat -c '%a' "$THERMAL_SOURCE_FILE") \
            || json_error '500 Internal Server Error' 'cannot snapshot thermal repair source mode'
        thermal_tx_snapshot || json_error '500 Internal Server Error' 'cannot snapshot thermal repair'
        thermal_policy_transaction_cache_reset
        thermal_policy_transaction_load
        _repair_meta=$(cat "$THERMAL_TX_META")
        _repair_present="$THERMAL_TX_CACHE_PRESENT"
        _repair_hash="$THERMAL_TX_CACHE_HASH"
        _repair_context="$THERMAL_TX_CACHE_CONTEXT"
        _repair_pending_meta=$(printf '%s\n' "$_repair_meta" | sed 's/^phase=staged$/phase=repair_pending/')
        _repair_pending_meta=$(printf '%s\ndesired_policy=system\ndesired_offset=0\ndesired_hash=none' "$_repair_pending_meta")
        if ! { cgi_atomic_write "$THERMAL_TX_META" "$_repair_pending_meta" \
            && thermal_policy_remove_overlay \
            && cgi_atomic_write "$THERMAL_POLICY_FILE" system \
            && cgi_atomic_write "$THERMAL_OFFSET_FILE" 0 \
            && [ "$(cat "$THERMAL_POLICY_FILE")" = system ] \
            && [ "$(cat "$THERMAL_OFFSET_FILE")" = 0 ] \
            && [ "$(thermal_policy_source_hash)" = none ]; }; then
            _repair_rollback=1
            if [ "$_repair_present" = 1 ]; then
                _repair_tmp="$THERMAL_SOURCE_FILE.repair.$$"
                mkdir -p "${THERMAL_SOURCE_FILE%/*}" \
                    && cp -p "$THERMAL_TX_SOURCE" "$_repair_tmp" \
                    && chmod "$_repair_source_mode" "$_repair_tmp" \
                    && { [ "$_repair_context" = none ] || chcon "$_repair_context" "$_repair_tmp"; } \
                    && mv "$_repair_tmp" "$THERMAL_SOURCE_FILE" || _repair_rollback=0
                rm -f "$_repair_tmp" 2>/dev/null
            else
                thermal_policy_remove_overlay || _repair_rollback=0
            fi
            cgi_restore_file "$THERMAL_POLICY_FILE" "$_repair_policy_present" "$_repair_policy_before" || _repair_rollback=0
            cgi_restore_file "$THERMAL_OFFSET_FILE" "$_repair_offset_present" "$_repair_offset_before" || _repair_rollback=0
            [ "$(thermal_policy_source_hash)" = "$_repair_hash" ] || _repair_rollback=0
            [ "$(cat "$THERMAL_POLICY_FILE" 2>/dev/null)" = "$_repair_policy_before" ] || _repair_rollback=0
            [ "$(cat "$THERMAL_OFFSET_FILE" 2>/dev/null)" = "$_repair_offset_before" ] || _repair_rollback=0
            if [ "$_repair_present" = 1 ]; then
                [ "$(stat -c '%a' "$THERMAL_SOURCE_FILE")" = "$_repair_source_mode" ] \
                    && [ "$(thermal_policy_source_context)" = "$_repair_context" ] || _repair_rollback=0
            fi
            if [ "$_repair_rollback" = 1 ] && thermal_policy_transaction_clear; then
                json_error '500 Internal Server Error' 'THERMAL_REPAIR_FAILED_ENTRY_STATE_RESTORED'
            fi
            _repair_failed_meta=$(printf '%s\n' "$_repair_pending_meta" | sed 's/^phase=repair_pending$/phase=repair_failed/')
            cgi_atomic_write "$THERMAL_TX_META" "$_repair_failed_meta" >/dev/null 2>&1 || true
            json_error '500 Internal Server Error' 'THERMAL_REPAIR_ROLLBACK_INCOMPLETE'
        fi
        thermal_policy_transaction_cache_reset
        thermal_policy_transaction_load
    fi
    _repair_id="$THERMAL_TX_CACHE_ID"
    release_lock
    audit_log_event_async thermal repair success THERMAL_REPAIR_SYSTEM 0
    json_headers
    printf '{"ok":true,"repaired":true,"policy":"system","offset":0,"repair_required":false,'
    printf '"pending":true,"pending_id":"%s","cancel_supported":false,"reboot_required":true,"effective_state":"repair_pending",' "$(json_escape "$_repair_id")"
    printf '"mount_backend":"%s","metamodule_active":%s,"reinstall_required":false,"thermal_contract":' \
        "$THERMAL_MOUNT_BACKEND" "$([ "$THERMAL_METAMODULE_ACTIVE" = 1 ] && printf true || printf false)"
    thermal_emit_contract
    printf '}\n'
    exit 0
fi
[ -z "$_action" ] || { release_lock; json_error '400 Bad Request' 'invalid thermal action'; }

policy=$(thermal_json_field policy)
offset=$(thermal_json_field offset)
[ -n "$policy" ] || { [ -n "$offset" ] && policy=custom; }
thermal_policy_is_valid "$policy" || json_error '400 Bad Request' 'invalid thermal policy'
if [ "$policy" = custom ]; then
    thermal_is_valid_offset "$offset" || json_error '400 Bad Request' 'invalid thermal offset'
    [ "$THERMAL_MOUNT_BACKEND" = hybrid_mount ] \
        || json_error '409 Conflict' 'mount_backend_unavailable'
    thermal_policy_validate_selected_config \
        || json_error '409 Conflict' 'selected_thermal_config_unsupported'
else
    offset=0
fi

if thermal_policy_transaction_pending; then
    thermal_policy_transaction_load
    _pending_id="$THERMAL_TX_CACHE_ID"
    _pending_phase="$THERMAL_TX_CACHE_PHASE"
    _pending_boot="$THERMAL_TX_CACHE_BOOT_ID"
    _current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')
    _pending_cancel=false
    [ "$_pending_phase" = staged ] && [ "$_pending_boot" = "$_current_boot" ] \
        && _pending_cancel=true
    release_lock
    json_status_headers '409 Conflict'
    printf '{"ok":false,"error":"pending_change_exists","pending":true,"pending_id":"%s","cancel_supported":%s}\n' "$_pending_id" "$_pending_cancel"
    exit 0
fi

# Repair only an interrupted legacy state when the effective vendor file is
# provably stock. This prevents an old source/policy mismatch from becoming a
# permanent 409 without ever deleting a possibly active custom payload.
_legacy_policy=$(thermal_policy_read)
_legacy_source_hash=$(thermal_policy_source_hash)
_legacy_effective_hash=$(thermal_policy_effective_hash)
_legacy_stock_hash=$(sha256sum "$STOCK_JSON" 2>/dev/null | awk '{print $1}')
_legacy_effective_context=$(thermal_policy_effective_context)
if [ "$_legacy_effective_context" = "$THERMAL_SOURCE_CONTEXT" ] \
    && [ "$_legacy_effective_hash" = "$_legacy_stock_hash" ]; then
    if [ "$_legacy_policy" = custom ] && [ "$_legacy_source_hash" = none ]; then
        cgi_atomic_write "$THERMAL_POLICY_FILE" system \
            && cgi_atomic_write "$THERMAL_OFFSET_FILE" 0 || true
    elif [ "$_legacy_policy" = system ] && [ "$_legacy_source_hash" != none ]; then
        thermal_policy_remove_overlay >/dev/null 2>&1 || true
    fi
fi

if [ "$THERMAL_MOUNT_BACKEND" = metamodule_content ]; then
    release_lock
    json_status_headers '409 Conflict'
    printf '{"ok":false,"error":"reinstall_required","reinstall_required":true,"mount_backend":"metamodule_content"}\n'
    exit 0
fi

mkdir -p "$LOCKDIR_BASE/tmp" 2>/dev/null \
    || json_error '500 Internal Server Error' 'cannot create thermal transaction directory'
TS_CANDIDATE="$LOCKDIR_BASE/tmp/thermal_candidate_$$"
TS_SOURCE_TMP="${THERMAL_SOURCE_FILE}.tmp.$$"
_tx_committed=0
thermal_cleanup() {
    rm -f "$TS_CANDIDATE" "$TS_SOURCE_TMP" 2>/dev/null
    [ "$_tx_committed" -eq 1 ] || thermal_tx_restore >/dev/null 2>&1 || true
    release_lock
}
trap 'thermal_cleanup' EXIT
trap 'thermal_cleanup; exit 130' INT
trap 'thermal_cleanup; exit 143' TERM

thermal_tx_snapshot \
    || json_error '500 Internal Server Error' '无法建立可撤销的 thermal journal'
thermal_policy_transaction_cache_reset
thermal_policy_transaction_load
_tx_base_valid="$THERMAL_TX_CACHE_BASE_VALID"
[ "$_tx_base_valid" = 1 ] \
    || { thermal_policy_transaction_clear >/dev/null 2>&1 || true; release_lock; json_error '409 Conflict' 'repair_required'; }
if [ "$policy" = custom ]; then
    # customize.sh accepts the snapshot only after the same generator has
    # validated it and records its fingerprint/hash provenance. Keep that
    # provenance check on every request; the selected output is generated once
    # below and the effective path is verified by the later readback.
    thermal_policy_stock_provenance_valid "$STOCK_JSON" \
        || json_error '409 Conflict' 'THERMAL_STOCK_MISSING_OR_FOREIGN'
    _cached_profile=$(thermal_policy_profile_cache_path "$DEVICE" "$offset" 2>/dev/null || true)
    if thermal_policy_profile_cache_valid "$DEVICE" "$STOCK_JSON" "$offset" \
        && [ -s "$_cached_profile" ]; then
        cp -f "$_cached_profile" "$TS_CANDIDATE" 2>/dev/null \
            || json_error '500 Internal Server Error' 'THERMAL_PROFILE_CACHE_COPY_FAILED'
    else
        thermal_generate_config "$STOCK_JSON" "$TS_CANDIDATE" "$offset" \
            || json_error '422 Unprocessable Entity' 'THERMAL_CONFIG_INVALID'
    fi
    mkdir -p "${THERMAL_SOURCE_FILE%/*}" 2>/dev/null \
        || json_error '500 Internal Server Error' 'cannot create thermal source directory'
    cp "$TS_CANDIDATE" "$TS_SOURCE_TMP" 2>/dev/null \
        || json_error '500 Internal Server Error' 'cannot stage thermal source'
    chmod 0644 "$TS_SOURCE_TMP" 2>/dev/null \
        || json_error '500 Internal Server Error' 'cannot set thermal source mode'
    chcon "$THERMAL_SOURCE_CONTEXT" "$TS_SOURCE_TMP" 2>/dev/null || true
    mv "$TS_SOURCE_TMP" "$THERMAL_SOURCE_FILE" 2>/dev/null \
        || json_error '500 Internal Server Error' 'thermal source commit failed'
else
    thermal_policy_remove_overlay \
        || json_error '500 Internal Server Error' 'cannot remove thermal source'
fi

cgi_atomic_write "$THERMAL_POLICY_FILE" "$policy" \
    && cgi_atomic_write "$THERMAL_OFFSET_FILE" "$offset" \
    || json_error '500 Internal Server Error' 'thermal state commit failed'
_tx_meta_payload=$(cat "$THERMAL_TX_META" 2>/dev/null)
_tx_next_hash=$(thermal_policy_source_hash)
cgi_atomic_write "$THERMAL_TX_META" "$(printf '%s\ndesired_policy=%s\ndesired_offset=%s\ndesired_hash=%s' \
    "$_tx_meta_payload" "$policy" "$offset" "$_tx_next_hash")" \
    || json_error '500 Internal Server Error' 'thermal journal commit failed'
thermal_policy_transaction_cache_reset
_tx_committed=1
thermal_policy_transaction_load
_pending_id="$THERMAL_TX_CACHE_ID"
json_headers
printf '{"ok":true,"restarted":false,'
thermal_emit_staged_state "$policy" "$offset" "$_tx_next_hash" "$_legacy_effective_hash" \
    "$(thermal_policy_source_context)" "$_legacy_effective_context" "$_pending_id"
printf '}\n'
release_lock
audit_log_event_async thermal policy success THERMAL_STAGED 0
