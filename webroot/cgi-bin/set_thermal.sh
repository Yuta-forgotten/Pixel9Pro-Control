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
if [ -r "$MODDIR/uecap_profile.sh" ] && . "$MODDIR/uecap_profile.sh" 2>/dev/null \
    && uecap_active_metamodule; then
    THERMAL_METAMODULE_ACTIVE=1
    THERMAL_MOUNT_BACKEND="${UECAP_BACKEND:-metamodule_content}"
fi

DEVICE=$(cat "$MODDIR/.device_variant" 2>/dev/null | tr -d ' \r\n\t')
case "$DEVICE" in caiman|komodo) ;; *) json_error '500 Internal Server Error' 'invalid device variant' ;; esac
STOCK_JSON=$(thermal_policy_snapshot_path "$DEVICE") \
    || json_error '500 Internal Server Error' 'cannot resolve thermal stock snapshot'

parse_policy() { printf '%s\n' "$1" | sed -n 's/.*"policy"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p'; }
parse_offset() { printf '%s\n' "$1" | sed -n 's/.*"offset"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p'; }
parse_action() { printf '%s\n' "$1" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p'; }
parse_pending_id() { printf '%s\n' "$1" | sed -n 's/.*"pending_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'; }

thermal_emit_contract() { thermal_print_ui_contract_json; }

thermal_emit_state() {
    _ts_policy=$(thermal_policy_read)
    _ts_offset=$(thermal_policy_offset_read)
    _ts_offset=$(thermal_normalize_offset "$_ts_offset" "$THERMAL_DEFAULT_OFFSET")
    _ts_source_hash=$(thermal_policy_source_hash)
    _ts_effective_hash=$(thermal_policy_effective_hash)
    _ts_source_context=$(thermal_policy_source_context)
    _ts_effective_context=$(thermal_policy_effective_context)
    _ts_effective_state=degraded
    if thermal_policy_transaction_pending; then
        _ts_tx_boot=$(thermal_policy_transaction_value boot_id)
        _ts_current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')
        if [ -n "$_ts_tx_boot" ] && [ "$_ts_tx_boot" = "$_ts_current_boot" ]; then
            _ts_effective_state=pending_reboot
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
    _ts_pending=false
    _ts_pending_id=""
    _ts_cancel_supported=false
    if thermal_policy_transaction_pending; then
        _ts_pending=true
        _ts_pending_id=$(thermal_policy_transaction_value id)
        _ts_tx_phase=$(thermal_policy_transaction_value phase)
        _ts_tx_boot=$(thermal_policy_transaction_value boot_id)
        _ts_base_valid=$(thermal_policy_transaction_value base_valid)
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
        cp -f "$THERMAL_SOURCE_FILE" "$THERMAL_TX_SOURCE.tmp.$$" || return 1
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
    [ -s "$THERMAL_TX_META" ] || return 1
    _tx_present=$(thermal_policy_transaction_value present)
    _tx_policy=$(thermal_policy_transaction_value policy)
    _tx_offset=$(thermal_policy_transaction_value offset)
    thermal_policy_is_valid "$_tx_policy" || return 1
    if [ "$_tx_policy" = custom ]; then
        thermal_is_valid_offset "$_tx_offset" || return 1
    fi
    if [ "$_tx_present" = 1 ]; then
        [ -f "$THERMAL_TX_SOURCE" ] || return 1
        mkdir -p "${THERMAL_SOURCE_FILE%/*}" || return 1
        cp -f "$THERMAL_TX_SOURCE" "$THERMAL_SOURCE_FILE.tmp.$$" || return 1
        _tx_context=$(thermal_policy_transaction_value context)
        [ -n "$_tx_context" ] && [ "$_tx_context" != none ] \
            && chcon "$_tx_context" "$THERMAL_SOURCE_FILE.tmp.$$" 2>/dev/null || true
        mv -f "$THERMAL_SOURCE_FILE.tmp.$$" "$THERMAL_SOURCE_FILE" || return 1
    else
        rm -f "$THERMAL_SOURCE_FILE" || return 1
    fi
    cgi_atomic_write "$THERMAL_POLICY_FILE" "$_tx_policy" \
        && cgi_atomic_write "$THERMAL_OFFSET_FILE" "$_tx_offset" \
        && { [ "$_tx_present" != 1 ] || [ "$(sha256sum "$THERMAL_SOURCE_FILE" 2>/dev/null | awk '{print $1}')" = "$(thermal_policy_transaction_value hash)" ]; } \
        && [ "$(thermal_policy_read)" = "$_tx_policy" ] \
        && thermal_policy_transaction_clear
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
_action=$(parse_action "$JSON_BODY")

if [ "$_action" = cancel_pending ]; then
    _requested_id=$(parse_pending_id "$JSON_BODY")
    _current_id=$(thermal_policy_transaction_value id)
    _tx_phase=$(thermal_policy_transaction_value phase)
    _tx_boot=$(thermal_policy_transaction_value boot_id)
    _tx_base_valid=$(thermal_policy_transaction_value base_valid)
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
        fi
    fi
    _tx_desired_policy=$(thermal_policy_transaction_value desired_policy)
    _tx_desired_offset=$(thermal_policy_transaction_value desired_offset)
    _tx_desired_hash=$(thermal_policy_transaction_value desired_hash)
    [ "$(thermal_policy_read)" = "$_tx_desired_policy" ] \
        && [ "$(thermal_policy_offset_read)" = "$_tx_desired_offset" ] \
        && [ "$(thermal_policy_source_hash)" = "$_tx_desired_hash" ] \
        || { release_lock; json_error '409 Conflict' '当前 source 已变化，请刷新状态后再撤销'; }
    thermal_tx_restore \
        || { release_lock; json_error '500 Internal Server Error' '撤销失败，旧 source 未确认恢复'; }
    [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] \
        && audit_log_event thermal cancel success THERMAL_CANCELED 0 >/dev/null 2>&1 || true
    json_headers
    printf '{"ok":true,"canceled":true,'
    thermal_emit_state
    printf '}\n'
    release_lock
    exit 0
fi
if [ "$_action" = repair_system ]; then
    { thermal_policy_remove_overlay || [ ! -e "$THERMAL_SOURCE_FILE" ]; } \
        && cgi_atomic_write "$THERMAL_POLICY_FILE" system \
        && cgi_atomic_write "$THERMAL_OFFSET_FILE" 0 \
        && thermal_policy_transaction_clear >/dev/null 2>&1 || {
            release_lock
            json_error '500 Internal Server Error' 'thermal repair failed'
        }
    release_lock
    [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] \
        && audit_log_event thermal repair success THERMAL_REPAIR_SYSTEM 0 >/dev/null 2>&1 || true
    json_headers
    printf '{"ok":true,"repaired":true,"reboot_required":true,"effective_state":"repair_pending"}\n'
    exit 0
fi
[ -z "$_action" ] || { release_lock; json_error '400 Bad Request' 'invalid thermal action'; }

if thermal_policy_transaction_pending; then
    _pending_id=$(thermal_policy_transaction_value id)
    _pending_phase=$(thermal_policy_transaction_value phase)
    _pending_boot=$(thermal_policy_transaction_value boot_id)
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

policy=$(parse_policy "$JSON_BODY")
offset=$(parse_offset "$JSON_BODY")
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
_tx_base_valid=$(thermal_policy_transaction_value base_valid)
[ "$_tx_base_valid" = 1 ] \
    || { thermal_policy_transaction_clear >/dev/null 2>&1 || true; release_lock; json_error '409 Conflict' 'repair_required'; }
if [ "$policy" = custom ]; then
    thermal_policy_stock_provenance_valid "$STOCK_JSON" \
        || json_error '409 Conflict' 'THERMAL_STOCK_MISSING_OR_FOREIGN'
    thermal_generate_config "$STOCK_JSON" "$TS_CANDIDATE" "$offset" \
        || json_error '422 Unprocessable Entity' 'THERMAL_CONFIG_INVALID'
    mkdir -p "${THERMAL_SOURCE_FILE%/*}" 2>/dev/null \
        || json_error '500 Internal Server Error' 'cannot create thermal source directory'
    cp "$TS_CANDIDATE" "$TS_SOURCE_TMP" 2>/dev/null \
        || json_error '500 Internal Server Error' 'cannot stage thermal source'
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
_tx_committed=1
_pending_id=$(thermal_policy_transaction_value id)
[ "$AUDIT_LOG_AVAILABLE" -eq 1 ] \
    && audit_log_event thermal policy success THERMAL_STAGED 0 >/dev/null 2>&1 || true
json_headers
printf '{"ok":true,"restarted":false,'
thermal_emit_state
printf '}\n'
