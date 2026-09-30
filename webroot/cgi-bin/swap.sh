#!/system/bin/sh
# GET returns current VM/ZRAM state and the shared profile contract. POST
# applies optimized/custom VM policy, or changes system/disabled intent without
# touching VM sysctls or the external ZRAM owner.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback

SWAP_MODE_FILE="$MODDIR/.swap_mode"
SWAP_CUSTOM_FILE="$MODDIR/.swap_custom"
VM_FEATURE_FILE="$MODDIR/.feature_vm"
VM_REBOOT_FILE="$MODDIR/.vm_reboot_required"
VM_REBOOT_BOOT_FILE="$MODDIR/.vm_reboot_boot_id"
ZRAM_RESTORE_PENDING_FILE="$MODDIR/.zram_restore_pending"
ZRAM_RECEIPT_FILE="$MODDIR/.zram_request_receipt"
VM_POLICY_READY_FILE="$MODDIR/.vm_policy_ready"
VM_PROFILE_LIB="$MODDIR/scripts/vm_profile_lib.sh"

[ -r "$VM_PROFILE_LIB" ] && . "$VM_PROFILE_LIB" \
    || json_error '500 Internal Server Error' 'VM profile contract not found'

json_num_field() {
    printf '%s\n' "$SWAP_JSON_FIELDS" | awk -F '\t' -v key="$2" '$1 == key { print $2; exit }'
}

parse_swap_json() {
    # Flat scalar request schema. Reject duplicate keys, escapes, trailing
    # tokens, exponent/negative numbers and nested values before any write.
    SWAP_JSON_FIELDS=$(printf '%s' "$1" | awk '
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
            if (key !~ /^(mode|size_bytes|capacity|unit|swappiness|min_free_kbytes|watermark_scale_factor|vfs_cache_pressure)$/) fail()
            s=substr(s,2); ws()
            if (match(s,/^"[A-Za-z0-9_.%]+"/)) {
                value=substr(s,2,RLENGTH-2); s=substr(s,RLENGTH+1)
            } else if (match(s,/^(0|[1-9][0-9]*)/)) {
                value=substr(s,1,RLENGTH); s=substr(s,RLENGTH+1)
            } else fail()
            print key "\t" value; ws()
            if (substr(s,1,1)=="}") break
            if (substr(s,1,1)!=",") fail()
            s=substr(s,2); ws(); if (substr(s,1,1)=="}") fail()
        }
        s=substr(s,2); ws(); if (s!="" || !seen["mode"]) fail()
    }') || return 1
}

json_key_count() {
    printf '%s' "$1" | grep -o "\"$2\"" 2>/dev/null | wc -l | tr -d ' \n\r\t'
}

json_require_unique_key() {
    [ "$(json_key_count "$1" "$2")" = 1 ]
}

persist_value() {
    cgi_atomic_write "$1" "$2"
}

restore_mmd_request_if_owned() {
    [ "$(vm_zram_property_value "$VM_MMD_ZRAM_SIZE_PROPERTY")" = "$1" ] || return 1
    vm_zram_restore_property "$VM_MMD_ZRAM_SIZE_PROPERTY" "$2"
}

restore_zram_request_if_owned() {
    _restore_failed=0
    if [ "$(vm_zram_property_value "$VM_MMD_ZRAM_SIZE_PROPERTY")" = "$1" ]; then
        vm_zram_restore_property "$VM_MMD_ZRAM_SIZE_PROPERTY" "$2" \
            || _restore_failed=1
    fi
    if [ "$(vm_zram_property_value "$VM_ZRAM_SIZE_PROPERTY")" = "$1" ]; then
        vm_zram_restore_property "$VM_ZRAM_SIZE_PROPERTY" "$3" \
            || _restore_failed=1
    fi
    [ "$_restore_failed" -eq 0 ]
}

restore_vm_state() {
    _vm_restore_failed=0
    set -- $_old_vm_params
    [ "$#" -eq 4 ] \
        && vm_write_params_raw "$1" "$2" "$3" "$4" >/dev/null 2>&1 \
        && vm_params_match "$1" "$2" "$3" "$4" \
        || _vm_restore_failed=1
    cgi_restore_file "$SWAP_MODE_FILE" "$_old_mode_existed" "$_old_mode" >/dev/null 2>&1 \
        || _vm_restore_failed=1
    cgi_restore_file "$SWAP_CUSTOM_FILE" "$_old_custom_existed" "$_old_custom" >/dev/null 2>&1 \
        || _vm_restore_failed=1
    cgi_restore_file "$VM_FEATURE_FILE" "$_old_feature_existed" "$_old_feature" >/dev/null 2>&1 \
        || _vm_restore_failed=1
    cgi_restore_file "$VM_REBOOT_FILE" "$_old_reboot_existed" "$_old_reboot" >/dev/null 2>&1 \
        || _vm_restore_failed=1
    cgi_restore_file "$VM_REBOOT_BOOT_FILE" "$_old_reboot_boot_existed" "$_old_reboot_boot" >/dev/null 2>&1 \
        || _vm_restore_failed=1
    cgi_restore_file "$ZRAM_RESTORE_PENDING_FILE" "$_old_restore_pending_existed" "$_old_restore_pending" >/dev/null 2>&1 \
        || _vm_restore_failed=1
    [ "$_vm_restore_failed" -eq 0 ]
}

restore_vm_policy_state() {
    _vm_policy_restore_failed=0
    cgi_restore_file "$SWAP_MODE_FILE" "$_old_mode_existed" "$_old_mode" >/dev/null 2>&1 \
        || _vm_policy_restore_failed=1
    cgi_restore_file "$VM_FEATURE_FILE" "$_old_feature_existed" "$_old_feature" >/dev/null 2>&1 \
        || _vm_policy_restore_failed=1
    cgi_restore_file "$VM_REBOOT_FILE" "$_old_reboot_existed" "$_old_reboot" >/dev/null 2>&1 \
        || _vm_policy_restore_failed=1
    cgi_restore_file "$VM_REBOOT_BOOT_FILE" "$_old_reboot_boot_existed" "$_old_reboot_boot" >/dev/null 2>&1 \
        || _vm_policy_restore_failed=1
    cgi_restore_file "$ZRAM_RESTORE_PENDING_FILE" "$_old_restore_pending_existed" "$_old_restore_pending" >/dev/null 2>&1 \
        || _vm_policy_restore_failed=1
    [ "$_vm_policy_restore_failed" -eq 0 ]
}

vm_write_error() {
    if restore_vm_state; then
        json_error '500 Internal Server Error' 'failed to write VM params; previous state restored'
    fi
    json_error '500 Internal Server Error' 'failed to write VM params and rollback was incomplete'
}

emit_state() {
    json_headers
    sw=$(cat /proc/sys/vm/swappiness 2>/dev/null)
    mfk=$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null)
    wsf=$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)
    vcp=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)
    algo=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | sed 's/.*\[\(.*\)\].*/\1/')
    disksize=$(cat /sys/block/zram0/disksize 2>/dev/null)
    swap_kb=$(vm_zram_read_swap_kb 2>/dev/null)
    [ -n "$swap_kb" ] || swap_kb=0
    swap_total_kb=$(awk '/^SwapTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
    zram_active_state=$(vm_zram_active_state)
    [ "$zram_active_state" = active ] && zram_active=true || zram_active=false
    feature_vm=$(cat "$VM_FEATURE_FILE" 2>/dev/null | tr -d ' \r\n\t')
    case "$feature_vm" in system|optimized|disabled) ;; *) feature_vm=system ;; esac
    mmd_zram_enabled=$(getprop mmd.zram.enabled 2>/dev/null | tr -d ' \r\n\t')
    mmd_enabled_aconfig=$(getprop mmd.enabled_aconfig 2>/dev/null | tr -d ' \r\n\t')
    mmd_setup_complete=$(getprop mmd.setup_complete 2>/dev/null | tr -d ' \r\n\t')
    mmd_requested_size=$(getprop "$VM_MMD_ZRAM_SIZE_PROPERTY" 2>/dev/null | tr -d ' \r\n\t')
    mmd_requested_algo=$(getprop mmd.zram.comp_algorithm 2>/dev/null | tr -d ' \r\n\t')
    zram_alias_supported=false
    vm_zram_vendor_alias_supported && zram_alias_supported=true
    zram_alias_reason=$(vm_zram_vendor_alias_reason)
    zram_alias_requested=$(vm_zram_property_value "$VM_ZRAM_SIZE_PROPERTY")
    zram_alias_readback_ok=false
    [ "$zram_alias_supported" = true ] \
        && [ -n "$mmd_requested_size" ] \
        && [ -n "$zram_alias_requested" ] \
        && [ "$zram_alias_requested" = "$mmd_requested_size" ] \
        && zram_alias_readback_ok=true
    mmd_owned=false
    vm_zram_mmd_ready && mmd_owned=true
    target_property=""
    target_value=""
    target_size_bytes=0
    target_supported=false
    if [ "${feature_vm:-}" = optimized ]; then
        target_property="$VM_ZRAM_SIZE_PROPERTY"
        if [ "$mmd_owned" = true ]; then
            target_property="$VM_MMD_ZRAM_SIZE_PROPERTY"
        fi
        target_value=$(vm_zram_property_value "$target_property")
        # mmd is the owner when its Aconfig gates are enabled.  Falling back
        # to the legacy vendor property here would expose a stale stock
        # request as the effective mmd request.
        if [ "$mmd_owned" != true ] && [ -z "$target_value" ]; then
            target_value=$(vm_zram_property_value "$VM_ZRAM_SIZE_PROPERTY")
        fi
        [ -n "$target_value" ] && target_size_bytes=$(vm_zram_size_to_bytes "$target_value")
        [ -n "$target_size_bytes" ] || target_size_bytes=0
        [ "$mmd_owned" = true ] && [ "$zram_alias_supported" = true ] \
            && target_supported=true
    fi

    # ZRAM mm_stat: orig compr mem_used ...
    mm=$(cat /sys/block/zram0/mm_stat 2>/dev/null)
    orig=$(echo "$mm" | awk '{print $1}')
    compr=$(echo "$mm" | awk '{print $2}')
    mem_used=$(echo "$mm" | awk '{print $3}')

    # 原厂 ZRAM 大小 = 50% RAM (fstab.zram.50p), 用 awk 避免 32 位溢出
    stock_zram_bytes=$(vm_zram_stock_size_bytes)
    zram_reboot_required=false
    if [ "$target_supported" = true ] \
        && [ -n "${disksize:-}" ] \
        && [ -n "${target_size_bytes:-}" ] \
            && awk -v bytes="${target_size_bytes:-0}" 'BEGIN { exit (bytes > 0 ? 0 : 1) }' \
                </dev/null 2>/dev/null \
        && [ "$disksize" != "$target_size_bytes" ]; then
        zram_reboot_required=true
    fi

    mode=$(cat "$SWAP_MODE_FILE" 2>/dev/null | tr -d ' \r\n\t')
    case "$mode" in
        stock) mode=system ;;
        system|optimized|custom|disabled) ;;
        *) mode="$feature_vm" ;;
    esac
    contract=$(vm_contract_json)

    vm_reboot_required=$(cat "$VM_REBOOT_FILE" 2>/dev/null | tr -d ' \r\n\t')
    case "$vm_reboot_required" in true|false) ;; *) vm_reboot_required=false ;; esac
    vm_policy_ready=$(cat "$VM_POLICY_READY_FILE" 2>/dev/null | tr -d ' \r\n\t')
    case "$vm_policy_ready" in true|false) ;; *) vm_policy_ready=false ;; esac
    zram_restore_pending=$(cat "$ZRAM_RESTORE_PENDING_FILE" 2>/dev/null | tr -d ' \r\n\t')
    case "$zram_restore_pending" in true|false) ;; *) zram_restore_pending=false ;; esac
    [ "$zram_restore_pending" = true ] && zram_reboot_required=true
    # Reconcile only orphaned/cross-boot journals on read. A valid same-boot
    # transaction remains visible and blocks a second mutation until it is
    # explicitly reconciled by the system/disabled transition or a reboot.
    vm_zram_transaction_pending >/dev/null 2>&1
    zram_journal_status=$?
    [ "$zram_journal_status" -eq 2 ] && VM_ZRAM_RECONCILE_RESULT=degraded
    zram_txid=$(vm_zram_state_field txid "$VM_ZRAM_LAST_REQUEST_FILE")
    [ -n "$zram_txid" ] || zram_txid=$(vm_zram_state_field txid "$VM_ZRAM_BASELINE_FILE")
    zram_txphase=$(vm_zram_state_field phase "$VM_ZRAM_LAST_REQUEST_FILE")
    [ -n "$zram_txphase" ] || zram_txphase=$(vm_zram_state_field phase "$VM_ZRAM_BASELINE_FILE")
    zram_receipt_txid=$(vm_zram_state_field txid "$VM_ZRAM_RECEIPT_FILE")
    zram_receipt_phase=$(vm_zram_state_field phase "$VM_ZRAM_RECEIPT_FILE")
    zram_receipt_reason=$(vm_zram_state_field reason "$VM_ZRAM_RECEIPT_FILE")
    zram_receipt_boot=$(vm_zram_state_field boot_id "$VM_ZRAM_RECEIPT_FILE")
    zram_current_boot=$(vm_zram_current_boot_id)
    if [ -n "$zram_receipt_boot" ] && [ -n "$zram_current_boot" ] \
        && [ "$zram_receipt_boot" != "$zram_current_boot" ]; then
        zram_receipt_txid=""
        zram_receipt_phase=historical
        zram_receipt_reason=previous_boot
    fi
    [ -n "$zram_txid" ] || zram_txid="$zram_receipt_txid"
    [ -n "$zram_txphase" ] || zram_txphase="$zram_receipt_phase"
    [ -n "$zram_txphase" ] || zram_txphase=none
    [ "$zram_reboot_required" = true ] && zram_effective_state=pending_reboot || zram_effective_state=effective
    [ "$vm_reboot_required" = true ] && vm_effective_state=pending_reboot || vm_effective_state=effective
    zram_pending_reason=none
    if [ "$zram_journal_status" -eq 2 ]; then
        zram_pending_reason=journal_degraded
    elif [ -n "$(vm_zram_state_field txid "$VM_ZRAM_LAST_REQUEST_FILE")" ]; then
        zram_pending_reason=transaction_active
    elif [ "$zram_restore_pending" = true ]; then
        zram_pending_reason=restore_pending_reboot
    elif [ "$zram_reboot_required" = true ]; then
        zram_pending_reason=effective_size_pending_reboot
    fi
    zram_owner=$(vm_zram_owner)
    [ -n "$zram_owner" ] || zram_owner=unknown
    zram_active_journal_txid=$(vm_zram_state_field txid "$VM_ZRAM_LAST_REQUEST_FILE")
    [ -n "$zram_active_journal_txid" ] || zram_active_journal_txid=$(vm_zram_state_field txid "$VM_ZRAM_BASELINE_FILE")
    zram_reconcile="$VM_ZRAM_RECONCILE_RESULT"
    if [ "$zram_journal_status" -eq 2 ]; then
        zram_reconcile=degraded
    elif [ -n "$zram_active_journal_txid" ]; then
        zram_reconcile=active
    elif [ "$zram_reconcile" = none ]; then
        zram_reconcile="${zram_receipt_phase:-none}"
    fi
    printf '{"swappiness":%s,"min_free_kbytes":%s,"watermark_scale_factor":%s,"vfs_cache_pressure":%s,"zram_algo":"%s","zram_disksize":%s,"zram_active":%s,"zram_active_state":"%s","zram_swap_kb":%s,"swap_total_kb":%s,"mmd_enabled_aconfig":"%s","mmd_zram_enabled":"%s","mmd_setup_complete":"%s","mmd_requested_size":"%s","mmd_requested_algorithm":"%s","zram_alias_property":"%s","zram_alias_requested":"%s","zram_alias_supported":%s,"zram_alias_reason":"%s","zram_alias_readback_ok":%s,"zram_owner":"%s","zram_target_supported":%s,"zram_size_property":"%s","zram_size_requested":"%s","zram_target_current_bytes":%s,"stock_zram_size":%s,"zram_reboot_required":%s,"zram_effective_state":"%s","zram_transaction_id":"%s","zram_transaction_phase":"%s","zram_pending_reason":"%s","vm_reboot_required":%s,"vm_effective_state":"%s","vm_policy_ready":%s,"zram_reconcile":"%s","zram_restore_pending":%s,"zram_orig_bytes":%s,"zram_compr_bytes":%s,"zram_mem_used_bytes":%s,"mode":"%s","feature_vm":"%s",%s}' \
        "${sw:-0}" "${mfk:-0}" "${wsf:-0}" "${vcp:-0}" "$(json_escape "${algo:-unknown}")" \
        "${disksize:-0}" "$zram_active" "$(json_escape "$zram_active_state")" "${swap_kb:-0}" "${swap_total_kb:-0}" "$(json_escape "$mmd_enabled_aconfig")" "$(json_escape "$mmd_zram_enabled")" "$(json_escape "$mmd_setup_complete")" "$(json_escape "$mmd_requested_size")" "$(json_escape "$mmd_requested_algo")" "$(json_escape "$VM_ZRAM_SIZE_PROPERTY")" "$(json_escape "$zram_alias_requested")" "$zram_alias_supported" "$(json_escape "$zram_alias_reason")" "$zram_alias_readback_ok" "$(json_escape "$zram_owner")" "$target_supported" "$(json_escape "$target_property")" "$(json_escape "$target_value")" "$target_size_bytes" "${stock_zram_bytes:-0}" \
        "$zram_reboot_required" "$(json_escape "$zram_effective_state")" "$(json_escape "$zram_txid")" "$(json_escape "$zram_txphase")" "$(json_escape "$zram_pending_reason")" "$vm_reboot_required" "$(json_escape "$vm_effective_state")" "$vm_policy_ready" "$(json_escape "$zram_reconcile")" "$zram_restore_pending" "${orig:-0}" "${compr:-0}" "${mem_used:-0}" "$mode" "$feature_vm" "$contract"
}

if [ "$REQUEST_METHOD" = "POST" ]; then
    [ "$(cat "$VM_POLICY_READY_FILE" 2>/dev/null | tr -d ' \r\n\t')" = true ] \
        || json_error '503 Service Unavailable' 'VM policy is still initializing; retry after boot readback'
    require_json_post
    require_token
    acquire_lock "swap"
    read_json_body 512
    body="$JSON_BODY"
    parse_swap_json "$body" || json_error '400 Bad Request' 'invalid VM/ZRAM JSON request'
    json_require_unique_key "$body" mode \
        || json_error '400 Bad Request' 'mode must be a unique JSON key'
    # Mode names include the underscore in zram_size.  The previous
    # `[a-z]*` parser truncated `zram_size` to `zram`, so every capacity
    # request reached the default branch and returned HTTP 400 even when the
    # body and size value were valid.  Keep the parser narrow and let the
    # explicit case statement below reject unknown modes.
    mode=$(json_num_field "$body" mode)
    _old_vm_params=$(vm_current_params)
    _old_mode_existed=0
    _old_custom_existed=0
    _old_feature_existed=0
    _old_reboot_existed=0
    _old_reboot_boot_existed=0
    _old_restore_pending_existed=0
    [ -e "$SWAP_MODE_FILE" ] && _old_mode_existed=1
    [ -e "$SWAP_CUSTOM_FILE" ] && _old_custom_existed=1
    [ -e "$VM_FEATURE_FILE" ] && _old_feature_existed=1
    [ -e "$VM_REBOOT_FILE" ] && _old_reboot_existed=1
    [ -e "$VM_REBOOT_BOOT_FILE" ] && _old_reboot_boot_existed=1
    [ -e "$ZRAM_RESTORE_PENDING_FILE" ] && _old_restore_pending_existed=1
    _old_mode=$(cat "$SWAP_MODE_FILE" 2>/dev/null)
    _old_custom=$(cat "$SWAP_CUSTOM_FILE" 2>/dev/null)
    _old_feature=$(cat "$VM_FEATURE_FILE" 2>/dev/null)
    _old_reboot=$(cat "$VM_REBOOT_FILE" 2>/dev/null)
    _old_reboot_boot=$(cat "$VM_REBOOT_BOOT_FILE" 2>/dev/null)
    _old_restore_pending=$(cat "$ZRAM_RESTORE_PENDING_FILE" 2>/dev/null)
    _old_mmd_zram_size=$(vm_zram_property_value "$VM_MMD_ZRAM_SIZE_PROPERTY")
    _old_vendor_zram_size=$(vm_zram_property_value "$VM_ZRAM_SIZE_PROPERTY")
    _old_vendor_zram_algo=$(vm_zram_property_value persist.vendor.zram_comp_algorithm)
    VM_POLICY_REBOOT_REQUIRED=false
    case "$mode" in
        optimized)
            set -- $(vm_profile_params optimized)
            if persist_value "$VM_FEATURE_FILE" optimized \
                && persist_value "$SWAP_MODE_FILE" optimized \
                && vm_write_params "$1" "$2" "$3" "$4" \
                && persist_value "$VM_REBOOT_FILE" false; then
                rm -f "$VM_REBOOT_BOOT_FILE" 2>/dev/null || true
                [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] && audit_log_event_async vm policy success VM_OPTIMIZED 0 || true
                json_headers
                printf '{"ok":true,"mode":"optimized","feature_vm":"optimized","message":"VM candidate submitted"}\n'
            else
                vm_write_error
            fi
            ;;
        system|stock)
            # System mode is observe-only. If this request leaves a module VM
            # profile active, the kernel baseline becomes effective at reboot;
            # do not guess stock sysctl values and do not touch mmd/Scene ZRAM.
            case "$_old_mode:$_old_feature" in
                optimized:*|custom:*|*:optimized) VM_POLICY_REBOOT_REQUIRED=true ;;
            esac
            [ "$_old_reboot" = true ] && VM_POLICY_REBOOT_REQUIRED=true
            vm_zram_reconcile_module_request \
                || json_error '500 Internal Server Error' 'failed to reconcile the module-owned ZRAM request'
            persist_value "$ZRAM_RESTORE_PENDING_FILE" "$VM_ZRAM_RESTORE_PENDING" \
                || json_error '500 Internal Server Error' 'failed to persist ZRAM restore pending state'
            if ! persist_value "$VM_FEATURE_FILE" system \
                || ! persist_value "$SWAP_MODE_FILE" system \
                || ! persist_value "$VM_REBOOT_FILE" "$VM_POLICY_REBOOT_REQUIRED"; then
                restore_vm_policy_state >/dev/null 2>&1 || true
                json_error '500 Internal Server Error' 'failed to commit system observe-only state'
            fi
            if [ "$VM_POLICY_REBOOT_REQUIRED" = true ]; then
                persist_value "$VM_REBOOT_BOOT_FILE" "$(vm_zram_current_boot_id)" \
                    || { restore_vm_policy_state >/dev/null 2>&1 || true; json_error '500 Internal Server Error' 'failed to persist VM reboot transaction'; }
            else
                rm -f "$VM_REBOOT_BOOT_FILE" 2>/dev/null || true
            fi
            [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] && audit_log_event_async vm policy success VM_SYSTEM_OBSERVE_ONLY 0 || true
            json_headers
            printf '{"ok":true,"mode":"system","feature_vm":"system","vm_reboot_required":%s,"message":"system observe-only submitted"}\n' "$VM_POLICY_REBOOT_REQUIRED"
            ;;
        custom)
            json_require_unique_key "$body" swappiness \
                && json_require_unique_key "$body" min_free_kbytes \
                && json_require_unique_key "$body" watermark_scale_factor \
                && json_require_unique_key "$body" vfs_cache_pressure \
                || json_error '400 Bad Request' 'custom VM keys must be unique JSON fields'
            sw=$(json_num_field "$body" swappiness)
            mfk=$(json_num_field "$body" min_free_kbytes)
            wsf=$(json_num_field "$body" watermark_scale_factor)
            vcp=$(json_num_field "$body" vfs_cache_pressure)
            if ! vm_is_uint_range "$sw" "$VM_SWAPPINESS_MIN" "$VM_SWAPPINESS_MAX"; then
                json_error '400 Bad Request' 'invalid swappiness'
            elif ! vm_is_uint_range "$mfk" "$VM_MIN_FREE_KBYTES_MIN" "$VM_MIN_FREE_KBYTES_MAX"; then
                json_error '400 Bad Request' 'invalid min_free_kbytes'
            elif ! vm_is_uint_range "$wsf" "$VM_WATERMARK_SCALE_MIN" "$VM_WATERMARK_SCALE_MAX"; then
                json_error '400 Bad Request' 'invalid watermark_scale_factor'
            elif ! vm_is_uint_range "$vcp" "$VM_VFS_CACHE_PRESSURE_MIN" "$VM_VFS_CACHE_PRESSURE_MAX"; then
                json_error '400 Bad Request' 'invalid vfs_cache_pressure'
            else
                [ ! -d "$SWAP_CUSTOM_FILE" ] \
                    || json_error '500 Internal Server Error' 'custom VM state path is not a file'
                _custom_tmp="${SWAP_CUSTOM_FILE}.tmp.$$"
                if {
                        printf 'swappiness=%s\n' "$sw"
                        printf 'min_free_kbytes=%s\n' "$mfk"
                        printf 'watermark_scale_factor=%s\n' "$wsf"
                        printf 'vfs_cache_pressure=%s\n' "$vcp"
                    } > "$_custom_tmp" 2>/dev/null \
                    && mv "$_custom_tmp" "$SWAP_CUSTOM_FILE" 2>/dev/null \
                    && [ -f "$SWAP_CUSTOM_FILE" ] \
                    && persist_value "$VM_FEATURE_FILE" optimized \
                    && persist_value "$SWAP_MODE_FILE" custom \
                    && vm_write_params "$sw" "$mfk" "$wsf" "$vcp" \
                    && persist_value "$VM_REBOOT_FILE" false; then
                    rm -f "$VM_REBOOT_BOOT_FILE" 2>/dev/null || true
                    [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] && audit_log_event_async vm policy success VM_CUSTOM 0 || true
                    json_headers
                    printf '{"ok":true,"mode":"custom","feature_vm":"optimized","message":"custom VM submitted"}\n'
                else
                    rm -f "$_custom_tmp" 2>/dev/null
                    vm_write_error
                fi
            fi
            ;;
        disabled)
            case "$_old_mode:$_old_feature" in
                optimized:*|custom:*|*:optimized) VM_POLICY_REBOOT_REQUIRED=true ;;
            esac
            [ "$_old_reboot" = true ] && VM_POLICY_REBOOT_REQUIRED=true
            vm_zram_reconcile_module_request \
                || json_error '500 Internal Server Error' 'failed to reconcile the module-owned ZRAM request'
            persist_value "$ZRAM_RESTORE_PENDING_FILE" "$VM_ZRAM_RESTORE_PENDING" \
                || json_error '500 Internal Server Error' 'failed to persist ZRAM restore pending state'
            if ! persist_value "$VM_FEATURE_FILE" disabled \
                || ! persist_value "$SWAP_MODE_FILE" disabled \
                || ! persist_value "$VM_REBOOT_FILE" "$VM_POLICY_REBOOT_REQUIRED"; then
                restore_vm_policy_state >/dev/null 2>&1 || true
                json_error '500 Internal Server Error' 'failed to commit disabled observe-only state'
            fi
            if [ "$VM_POLICY_REBOOT_REQUIRED" = true ]; then
                persist_value "$VM_REBOOT_BOOT_FILE" "$(vm_zram_current_boot_id)" \
                    || { restore_vm_policy_state >/dev/null 2>&1 || true; json_error '500 Internal Server Error' 'failed to persist VM reboot transaction'; }
            else
                rm -f "$VM_REBOOT_BOOT_FILE" 2>/dev/null || true
            fi
            [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] && audit_log_event_async vm policy success VM_DISABLED_OBSERVE_ONLY 0 || true
            json_headers
            printf '{"ok":true,"mode":"disabled","feature_vm":"disabled","vm_reboot_required":%s,"message":"module writes disabled"}\n' "$VM_POLICY_REBOOT_REQUIRED"
            ;;
        zram_size)
            _capacity=$(json_num_field "$body" capacity)
            _unit=$(json_num_field "$body" unit)
            _legacy_size=$(json_num_field "$body" size_bytes)
            if [ -n "$_capacity" ] || [ -n "$_unit" ]; then
                [ -z "$_legacy_size" ] || json_error '400 Bad Request' 'use capacity/unit or size_bytes, not both'
                _zram_requested=$(vm_zram_normalize_capacity "$_capacity" "$_unit") \
                    || json_error '400 Bad Request' 'capacity requires MB (1024..16384) or percent (10..100)'
            else
                _zram_requested="$_legacy_size"
            fi
            case "$(cat "$SWAP_MODE_FILE" 2>/dev/null | tr -d ' \r\n\t')" in
                optimized|custom) ;;
                *) json_error '409 Conflict' 'ZRAM capacity requests require optimized or custom VM policy' ;;
            esac
            [ "$(cat "$VM_FEATURE_FILE" 2>/dev/null | tr -d ' \r\n\t')" = optimized ] \
                || json_error '409 Conflict' 'VM optimization is not enabled'
            vm_zram_size_is_valid "$_zram_requested" \
                || json_error '400 Bad Request' 'invalid zram size_bytes (1GiB..16GiB or percent)'
            if ! vm_zram_mmd_ready; then
                json_error '409 Conflict' 'mmd owner is not ready; zram size change requires reboot'
            fi
            vm_zram_vendor_alias_supported \
                || json_error '409 Conflict' 'target build does not prove the persistent ZRAM alias; request not applied'
            _zram_requested_bytes=$(vm_zram_size_to_bytes "$_zram_requested")
            # Re-submitting an already effective request must be idempotent and
            # must not create a fresh rollback journal for an external owner.
            if [ "$(vm_zram_property_value "$VM_MMD_ZRAM_SIZE_PROPERTY")" = "$_zram_requested" ] \
                && vm_zram_is_active \
                && [ "$(vm_zram_read_disksize)" = "$_zram_requested_bytes" ]; then
                json_headers
                [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] && audit_log_event_async vm zram success ZRAM_ALREADY_EFFECTIVE 0 || true
                printf '{"ok":true,"mode":"already_effective","zram_size_property":"%s","zram_size_requested":"%s","message":"mmd 请求与当前 active ZRAM 已一致"}\n' \
                    "$VM_MMD_ZRAM_SIZE_PROPERTY" "$_zram_requested"
                exit 0
            fi
            vm_zram_transaction_pending
            _zram_journal_rc=$?
            [ "$_zram_journal_rc" -eq 0 ] \
                && json_error '409 Conflict' 'a ZRAM request transaction is already pending; reconcile or reboot before another mutation'
            [ "$_zram_journal_rc" -eq 2 ] \
                && json_error '500 Internal Server Error' 'ZRAM journal reconciliation is degraded; request preserved'
            vm_zram_capture_request_baseline \
                || json_error '500 Internal Server Error' 'failed to persist the pre-request ZRAM owner baseline'
            _zram_property="$VM_MMD_ZRAM_SIZE_PROPERTY"
            vm_zram_record_last_request "$_zram_requested" staged \
                || json_error '500 Internal Server Error' 'failed to persist staged ZRAM request intent'
            if ! setprop "$VM_MMD_ZRAM_SIZE_PROPERTY" "$_zram_requested" 2>/dev/null \
                || [ "$(getprop "$VM_MMD_ZRAM_SIZE_PROPERTY" 2>/dev/null | tr -d ' \n\r\t')" != "$_zram_requested" ] \
                || ! setprop "$VM_ZRAM_SIZE_PROPERTY" "$_zram_requested" 2>/dev/null \
                || [ "$(getprop "$VM_ZRAM_SIZE_PROPERTY" 2>/dev/null | tr -d ' \n\r\t')" != "$_zram_requested" ]; then
                # mmd is the active owner; never fall back to a second vendor
                # request and leave two conflicting persistent values behind.
                restore_zram_request_if_owned "$_zram_requested" "$_old_mmd_zram_size" "$_old_vendor_zram_size" \
                    && vm_zram_clear_journal || vm_zram_record_receipt "${VM_ZRAM_TXID:-unknown}" degraded property_write_failed
                json_error '409 Conflict' 'mmd zram size property is not writable on this build'
            fi
            vm_zram_record_last_request "$_zram_requested" requested \
                || {
                    restore_zram_request_if_owned "$_zram_requested" "$_old_mmd_zram_size" "$_old_vendor_zram_size" \
                        && vm_zram_clear_journal || vm_zram_record_receipt "${VM_ZRAM_TXID:-unknown}" degraded journal_write_failed
                    json_error '500 Internal Server Error' 'ZRAM request applied but transaction journal could not be persisted'
                }
            persist_value "$ZRAM_RESTORE_PENDING_FILE" false \
                || json_error '500 Internal Server Error' 'failed to replace the previous ZRAM restore marker'
            _zram_mode=pending_reboot
            if [ "$(vm_zram_active_state)" = inactive ]; then
                vm_mmd_setup_zram >/dev/null 2>&1 || true
                sleep 1
                [ "$(vm_zram_active_state)" = active ] \
                    && [ "$(vm_zram_read_disksize)" = "$_zram_requested_bytes" ] \
                    && vm_zram_commit_effective_request \
                    && _zram_mode=applied_online
            fi
            json_headers
            [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] && audit_log_event_async vm zram success ZRAM_REBOOT_REQUEST 0 || true
            printf '{"ok":true,"mode":"%s","zram_size_property":"%s","zram_size_requested":"%s","message":"%s"}\n' \
                "$_zram_mode" "$_zram_property" "$_zram_requested" \
                "$( [ "$_zram_mode" = applied_online ] && printf 'mmd 已在线应用容量' || printf '当前 swap 正在使用，重启后由 mmd 应用' )"
            ;;
        *)
            json_error '400 Bad Request' 'invalid mode'
            ;;
    esac
elif [ "$REQUEST_METHOD" = "GET" ]; then
    acquire_lock "swap"
    emit_state
    release_lock
else
    json_error '405 Method Not Allowed' 'GET or POST only'
fi
