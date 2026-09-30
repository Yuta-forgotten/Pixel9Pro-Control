#!/system/bin/sh

# Pixel 9 Pro VM contract shared by boot service and swap CGI.
# VM tuning is opt-in module policy; ZRAM remains owned by Android/APatch mmd.
# The system/disabled policy is observe-only and never submits a ZRAM request.

VM_ZRAM_ALGO="lz77eh"
# There is no module ZRAM size default. A size is an explicit user request.
VM_ZRAM_SIZE_BYTES="0"
VM_ZRAM_SIZE_PROPERTY="persist.vendor.zram_swap_size_v2"
VM_MMD_ZRAM_SIZE_PROPERTY="mmd.zram.size"
VM_ZRAM_BASELINE_FILE="${VM_ZRAM_BASELINE_FILE:-${MODDIR:-/data/adb/modules/pixel9pro_control}/.zram_request_baseline}"
VM_ZRAM_LAST_REQUEST_FILE="${VM_ZRAM_LAST_REQUEST_FILE:-${MODDIR:-/data/adb/modules/pixel9pro_control}/.zram_request_last}"
VM_ZRAM_RECEIPT_FILE="${VM_ZRAM_RECEIPT_FILE:-${MODDIR:-/data/adb/modules/pixel9pro_control}/.zram_request_receipt}"
VM_ZRAM_SIZE_MIN_BYTES=1073741824
VM_ZRAM_SIZE_MAX_BYTES=17179869184
# Requests are accepted on the kernel ZRAM page boundary; Scene/mmd may use
# finer values than the old UI slider step.
VM_ZRAM_SIZE_STEP_BYTES=4096
VM_ZRAM_MB_MIN=1024
VM_ZRAM_MB_MAX=16384
VM_ZRAM_PERCENT_MIN=10
VM_ZRAM_PERCENT_MAX=100

# Conservative opt-in profile. These values are deliberately close to the
# platform baseline; system mode never writes them.
VM_OPT_SWAPPINESS=100
VM_OPT_MIN_FREE_KBYTES=65536
VM_OPT_WATERMARK_SCALE=100
VM_OPT_VFS_CACHE_PRESSURE=100

# Optional manual comparison preset; system mode never writes these values.
VM_STOCK_SWAPPINESS=150
VM_STOCK_MIN_FREE_KBYTES=27386
VM_STOCK_WATERMARK_SCALE=50
VM_STOCK_VFS_CACHE_PRESSURE=100

VM_SWAPPINESS_MIN=0
VM_SWAPPINESS_MAX=200
VM_MIN_FREE_KBYTES_MIN=16384
VM_MIN_FREE_KBYTES_MAX=262144
VM_WATERMARK_SCALE_MIN=10
VM_WATERMARK_SCALE_MAX=500
VM_VFS_CACHE_PRESSURE_MIN=10
VM_VFS_CACHE_PRESSURE_MAX=200

VM_DIRTY_WRITEBACK_CENTISECS=3000
VM_DIRTY_RATIO=50
VM_DIRTY_BACKGROUND_RATIO=20
VM_ZRAM_RECONCILE_RESULT=none
VM_ZRAM_RESTORE_PENDING=false
VM_ZRAM_TXID=""

vm_zram_current_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t'
}

vm_zram_new_txid() {
    _vm_tx_boot=$(vm_zram_current_boot_id)
    _vm_tx_now=$(date +%s 2>/dev/null | tr -d ' \n\r\t')
    [ -n "$_vm_tx_boot" ] || _vm_tx_boot=unknown
    [ -n "$_vm_tx_now" ] || _vm_tx_now=0
    printf '%s-%s-%s' "$_vm_tx_boot" "$$" "$_vm_tx_now"
}

vm_is_uint_range() {
    _vm_value="$1"
    _vm_min="$2"
    _vm_max="$3"
    case "$_vm_value" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$_vm_value" -ge "$_vm_min" ] 2>/dev/null \
        && [ "$_vm_value" -le "$_vm_max" ] 2>/dev/null
}

vm_write_params() {
    _vm_sw="$1"
    _vm_mfk="$2"
    _vm_wsf="$3"
    _vm_vcp="$4"
    vm_is_uint_range "$_vm_sw" "$VM_SWAPPINESS_MIN" "$VM_SWAPPINESS_MAX" || return 1
    vm_is_uint_range "$_vm_mfk" "$VM_MIN_FREE_KBYTES_MIN" "$VM_MIN_FREE_KBYTES_MAX" || return 1
    vm_is_uint_range "$_vm_wsf" "$VM_WATERMARK_SCALE_MIN" "$VM_WATERMARK_SCALE_MAX" || return 1
    vm_is_uint_range "$_vm_vcp" "$VM_VFS_CACHE_PRESSURE_MIN" "$VM_VFS_CACHE_PRESSURE_MAX" || return 1
    vm_params_match "$_vm_sw" "$_vm_mfk" "$_vm_wsf" "$_vm_vcp" && return 0

    _vm_old=$(vm_current_params)
    if ! vm_write_params_raw "$_vm_sw" "$_vm_mfk" "$_vm_wsf" "$_vm_vcp" \
        || ! vm_params_match "$_vm_sw" "$_vm_mfk" "$_vm_wsf" "$_vm_vcp"; then
        set -- $_vm_old
        if [ "$#" -eq 4 ] \
            && vm_write_params_raw "$1" "$2" "$3" "$4" >/dev/null 2>&1 \
            && vm_params_match "$1" "$2" "$3" "$4"; then
            return 1
        fi
        return 2
    fi
}

vm_read_custom_param() {
    sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -1 | tr -d ' \n\r'
}

vm_current_params() {
    printf '%s %s %s %s' \
        "$(cat /proc/sys/vm/swappiness 2>/dev/null | tr -d ' \n\r')" \
        "$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null | tr -d ' \n\r')" \
        "$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null | tr -d ' \n\r')" \
        "$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null | tr -d ' \n\r')"
}

vm_write_params_raw() {
    printf '%s\n' "$1" > /proc/sys/vm/swappiness 2>/dev/null \
        && printf '%s\n' "$2" > /proc/sys/vm/min_free_kbytes 2>/dev/null \
        && printf '%s\n' "$3" > /proc/sys/vm/watermark_scale_factor 2>/dev/null \
        && printf '%s\n' "$4" > /proc/sys/vm/vfs_cache_pressure 2>/dev/null
}

vm_params_match() {
    [ "$(cat /proc/sys/vm/swappiness 2>/dev/null | tr -d ' \n\r')" = "$1" ] \
        && [ "$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null | tr -d ' \n\r')" = "$2" ] \
        && [ "$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null | tr -d ' \n\r')" = "$3" ] \
        && [ "$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null | tr -d ' \n\r')" = "$4" ]
}

vm_write_one_verified() {
    [ -e "$1" ] || return 1
    printf '%s\n' "$2" > "$1" 2>/dev/null || return 1
    [ "$(cat "$1" 2>/dev/null | tr -d ' \n\r\t')" = "$2" ]
}

vm_apply_dirty_params() {
    vm_write_one_verified /proc/sys/vm/dirty_writeback_centisecs "$VM_DIRTY_WRITEBACK_CENTISECS" \
        && vm_write_one_verified /proc/sys/vm/dirty_ratio "$VM_DIRTY_RATIO" \
        && vm_write_one_verified /proc/sys/vm/dirty_background_ratio "$VM_DIRTY_BACKGROUND_RATIO"
}

vm_profile_params() {
    case "$1" in
        optimized)
            printf '%s %s %s %s' "$VM_OPT_SWAPPINESS" "$VM_OPT_MIN_FREE_KBYTES" \
                "$VM_OPT_WATERMARK_SCALE" "$VM_OPT_VFS_CACHE_PRESSURE"
            ;;
        stock)
            printf '%s %s %s %s' "$VM_STOCK_SWAPPINESS" "$VM_STOCK_MIN_FREE_KBYTES" \
                "$VM_STOCK_WATERMARK_SCALE" "$VM_STOCK_VFS_CACHE_PRESSURE"
            ;;
        *) return 1 ;;
    esac
}

vm_detect_mode() {
    _vm_profile=$(vm_profile_params optimized) || return 1
    set -- $_vm_profile
    if vm_params_match "$1" "$2" "$3" "$4"; then
        printf 'optimized'
        return 0
    fi
    _vm_profile=$(vm_profile_params stock) || return 1
    set -- $_vm_profile
    if vm_params_match "$1" "$2" "$3" "$4"; then
        printf 'stock'
    else
        printf 'custom'
    fi
}

vm_contract_json() {
    printf '"optimized":{"swappiness":%s,"min_free_kbytes":%s,"watermark_scale_factor":%s,"vfs_cache_pressure":%s},' \
        "$VM_OPT_SWAPPINESS" "$VM_OPT_MIN_FREE_KBYTES" "$VM_OPT_WATERMARK_SCALE" "$VM_OPT_VFS_CACHE_PRESSURE"
    printf '"stock":{"swappiness":%s,"min_free_kbytes":%s,"watermark_scale_factor":%s,"vfs_cache_pressure":%s},' \
        "$VM_STOCK_SWAPPINESS" "$VM_STOCK_MIN_FREE_KBYTES" "$VM_STOCK_WATERMARK_SCALE" "$VM_STOCK_VFS_CACHE_PRESSURE"
    printf '"limits":{"swappiness":{"min":%s,"max":%s,"step":5},"min_free_kbytes":{"min":%s,"max":%s,"step":8192},"watermark_scale_factor":{"min":%s,"max":%s,"step":10},"vfs_cache_pressure":{"min":%s,"max":%s,"step":5}},' \
        "$VM_SWAPPINESS_MIN" "$VM_SWAPPINESS_MAX" \
        "$VM_MIN_FREE_KBYTES_MIN" "$VM_MIN_FREE_KBYTES_MAX" \
        "$VM_WATERMARK_SCALE_MIN" "$VM_WATERMARK_SCALE_MAX" \
        "$VM_VFS_CACHE_PRESSURE_MIN" "$VM_VFS_CACHE_PRESSURE_MAX"
    printf '"zram_target":{"algorithm":"%s","size_bytes":%s,"property":"%s","mmd_property":"%s","policy":"explicit_user_request_only"},' \
        "$VM_ZRAM_ALGO" "$VM_ZRAM_SIZE_BYTES" "$VM_ZRAM_SIZE_PROPERTY" "$VM_MMD_ZRAM_SIZE_PROPERTY"
    printf '"zram_size_limits":{"min_bytes":%s,"max_bytes":%s,"step_bytes":%s},' "$VM_ZRAM_SIZE_MIN_BYTES" "$VM_ZRAM_SIZE_MAX_BYTES" "$VM_ZRAM_SIZE_STEP_BYTES"
    printf '"zram_input_limits":{"default_unit":"mb","mb":{"min":%s,"max":%s,"step":1},"percent":{"min":%s,"max":%s,"step":1}}' \
        "$VM_ZRAM_MB_MIN" "$VM_ZRAM_MB_MAX" "$VM_ZRAM_PERCENT_MIN" "$VM_ZRAM_PERCENT_MAX"
}

vm_zram_normalize_capacity() {
    _vm_capacity="$1"
    _vm_capacity_unit="$2"
    case "$_vm_capacity_unit" in
        mb|mib)
            _vm_multiplier=1000000
            [ "$_vm_capacity_unit" = mib ] && _vm_multiplier=1048576
            awk -v value="$_vm_capacity" -v min="$VM_ZRAM_MB_MIN" -v max="$VM_ZRAM_MB_MAX" -v multiplier="$_vm_multiplier" \
                'BEGIN { if (value !~ /^[0-9]+([.][0-9]{1,2})?$/ || value < min || value > max) exit 1; bytes=value * multiplier; printf "%.0f", int((bytes + 4095) / 4096) * 4096 }' \
                </dev/null || return 1 ;;
        percent)
            vm_is_uint_range "$_vm_capacity" "$VM_ZRAM_PERCENT_MIN" "$VM_ZRAM_PERCENT_MAX" || return 1
            printf '%s%%' "$_vm_capacity" ;;
        *) return 1 ;;
    esac
}

vm_zram_size_is_valid() {
    case "$1" in
        ''|*[!0-9%]*) return 1 ;;
        *%) _vm_pct=${1%%%}; [ -n "$_vm_pct" ] && [ "$_vm_pct" -ge 10 ] 2>/dev/null && [ "$_vm_pct" -le 100 ] 2>/dev/null ;;
        *) awk -v bytes="$1" -v min="$VM_ZRAM_SIZE_MIN_BYTES" -v max="$VM_ZRAM_SIZE_MAX_BYTES" \
            'BEGIN { exit (bytes >= min && bytes <= max && bytes % 4096 == 0 ? 0 : 1) }' \
            </dev/null 2>/dev/null ;;
    esac
}

vm_zram_size_to_bytes() {
    case "$1" in
        *%) _vm_pct=${1%%%}; awk -v pct="$_vm_pct" '/^MemTotal:/{bytes=$2 * 1024 * pct / 100; printf "%.0f", int(bytes / 4096) * 4096; exit}' /proc/meminfo 2>/dev/null ;;
        *) printf '%s' "$1" ;;
    esac
}

vm_zram_stock_size_bytes() {
    # fstab's 50p request is rounded by mmd to the zram page boundary.  Use
    # the same 4 KiB ceiling so a successful reboot is not reported pending
    # merely because MemTotal*50% lands on a half-page.
    awk '/^MemTotal:/{bytes=$2 * 512; printf "%.0f", int(bytes / 4096) * 4096; exit}' /proc/meminfo 2>/dev/null
}

vm_zram_property_value() {
    getprop "$1" 2>/dev/null | tr -d ' \n\r\t'
}

vm_zram_restore_property() {
    [ -n "$1" ] || return 1
    [ "$(vm_zram_property_value "$1")" = "${2:-}" ] && return 0
    setprop "$1" "${2:-}" 2>/dev/null || return 1
    [ "$(vm_zram_property_value "$1")" = "${2:-}" ]
}

vm_zram_state_field() {
    sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -1 | tr -d ' \n\r\t'
}

vm_zram_atomic_state_write() {
    _vm_state_path="$1"
    _vm_state_value="$2"
    _vm_state_tmp="${_vm_state_path}.tmp.$$"
    printf '%s\n' "$_vm_state_value" > "$_vm_state_tmp" 2>/dev/null \
        && mv "$_vm_state_tmp" "$_vm_state_path" 2>/dev/null \
        && [ "$(cat "$_vm_state_path" 2>/dev/null)" = "$_vm_state_value" ]
}

vm_zram_record_receipt() {
    _vm_receipt_txid="$1"
    _vm_receipt_phase="$2"
    _vm_receipt_reason="$3"
    [ -n "$_vm_receipt_txid" ] || return 1
    [ -n "$_vm_receipt_phase" ] || return 1
    vm_zram_atomic_state_write "$VM_ZRAM_RECEIPT_FILE" "schema=1
txid=$_vm_receipt_txid
phase=$_vm_receipt_phase
reason=$_vm_receipt_reason
boot_id=$(vm_zram_current_boot_id)"
}

vm_zram_clear_journal() {
    rm -f "$VM_ZRAM_BASELINE_FILE" "$VM_ZRAM_LAST_REQUEST_FILE" 2>/dev/null
}

vm_zram_capture_request_baseline() {
    # A baseline without its matching last-request journal is an interrupted
    # transaction.  Do not reuse it for a new request: that would restore an
    # unrelated, stale owner value when the user later selects system mode.
    _vm_base_boot=$(vm_zram_state_field boot_id "$VM_ZRAM_BASELINE_FILE")
    _vm_last_boot=$(vm_zram_state_field boot_id "$VM_ZRAM_LAST_REQUEST_FILE")
    _vm_base_tx=$(vm_zram_state_field txid "$VM_ZRAM_BASELINE_FILE")
    _vm_last_tx=$(vm_zram_state_field txid "$VM_ZRAM_LAST_REQUEST_FILE")
    _vm_current_boot=$(vm_zram_current_boot_id)
    if [ -s "$VM_ZRAM_BASELINE_FILE" ] && [ -s "$VM_ZRAM_LAST_REQUEST_FILE" ] \
        && [ -n "$_vm_base_tx" ] && [ "$_vm_base_tx" = "$_vm_last_tx" ] \
        && [ -n "$_vm_current_boot" ] && [ "$_vm_base_boot" = "$_vm_current_boot" ] \
        && [ "$_vm_last_boot" = "$_vm_current_boot" ]; then
        VM_ZRAM_TXID="$_vm_base_tx"
        return 0
    fi
    rm -f "$VM_ZRAM_BASELINE_FILE" "$VM_ZRAM_LAST_REQUEST_FILE" 2>/dev/null || true
    rm -f "$VM_ZRAM_RECEIPT_FILE" 2>/dev/null || true
    VM_ZRAM_TXID=$(vm_zram_new_txid)
    vm_zram_atomic_state_write "$VM_ZRAM_BASELINE_FILE" "schema=1
txid=$VM_ZRAM_TXID
phase=baseline
boot_id=$(vm_zram_current_boot_id)
mmd_size=$(vm_zram_property_value "$VM_MMD_ZRAM_SIZE_PROPERTY")
vendor_size=$(vm_zram_property_value "$VM_ZRAM_SIZE_PROPERTY")
vendor_algo=$(vm_zram_property_value persist.vendor.zram_comp_algorithm)"
}

vm_zram_record_last_request() {
    _vm_requested_size="$1"
    _vm_request_phase="${2:-requested}"
    [ -n "$_vm_requested_size" ] || return 1
    [ -n "$VM_ZRAM_TXID" ] || VM_ZRAM_TXID=$(vm_zram_state_field txid "$VM_ZRAM_BASELINE_FILE")
    [ -n "$VM_ZRAM_TXID" ] || return 1
    vm_zram_atomic_state_write "$VM_ZRAM_LAST_REQUEST_FILE" "schema=1
txid=$VM_ZRAM_TXID
phase=$_vm_request_phase
boot_id=$(vm_zram_current_boot_id)
mmd_size=$_vm_requested_size
vendor_size=$_vm_requested_size
vendor_algo=$(vm_zram_property_value persist.vendor.zram_comp_algorithm)"
}

vm_zram_commit_effective_request() {
    _vm_effective_tx=$(vm_zram_state_field txid "$VM_ZRAM_LAST_REQUEST_FILE")
    [ -n "$_vm_effective_tx" ] || return 1
    vm_zram_record_receipt "$_vm_effective_tx" effective online \
        || return 1
    vm_zram_clear_journal || return 1
    VM_ZRAM_RECONCILE_RESULT=effective
}

vm_zram_transaction_pending() {
    _vm_base_boot=$(vm_zram_state_field boot_id "$VM_ZRAM_BASELINE_FILE")
    _vm_last_boot=$(vm_zram_state_field boot_id "$VM_ZRAM_LAST_REQUEST_FILE")
    _vm_base_tx=$(vm_zram_state_field txid "$VM_ZRAM_BASELINE_FILE")
    _vm_last_tx=$(vm_zram_state_field txid "$VM_ZRAM_LAST_REQUEST_FILE")
    _vm_base_phase=$(vm_zram_state_field phase "$VM_ZRAM_BASELINE_FILE")
    _vm_last_phase=$(vm_zram_state_field phase "$VM_ZRAM_LAST_REQUEST_FILE")
    _vm_current_boot=$(vm_zram_current_boot_id)
    if [ -s "$VM_ZRAM_BASELINE_FILE" ] && [ -s "$VM_ZRAM_LAST_REQUEST_FILE" ] \
        && [ -n "$_vm_base_tx" ] && [ "$_vm_base_tx" = "$_vm_last_tx" ] \
        && [ -n "$_vm_current_boot" ] && [ "$_vm_base_boot" = "$_vm_current_boot" ] \
        && [ "$_vm_last_boot" = "$_vm_current_boot" ] \
        && [ "$_vm_base_phase" = baseline ] \
        && { [ "$_vm_last_phase" = staged ] || [ "$_vm_last_phase" = requested ] || [ "$_vm_last_phase" = effective ]; }; then
        VM_ZRAM_TXID="$_vm_base_tx"
        return 0
    fi
    if [ -e "$VM_ZRAM_BASELINE_FILE" ] || [ -e "$VM_ZRAM_LAST_REQUEST_FILE" ]; then
        vm_zram_reconcile_module_request >/dev/null 2>&1 || return 2
    fi
    return 1
}

vm_zram_reconcile_module_request() {
    VM_ZRAM_RECONCILE_RESULT=none
    VM_ZRAM_RESTORE_PENDING=false
    if [ ! -s "$VM_ZRAM_BASELINE_FILE" ] && [ ! -s "$VM_ZRAM_LAST_REQUEST_FILE" ]; then
        return 0
    fi
    _vm_base_boot=$(vm_zram_state_field boot_id "$VM_ZRAM_BASELINE_FILE")
    _vm_last_boot=$(vm_zram_state_field boot_id "$VM_ZRAM_LAST_REQUEST_FILE")
    _vm_base_tx=$(vm_zram_state_field txid "$VM_ZRAM_BASELINE_FILE")
    _vm_last_tx=$(vm_zram_state_field txid "$VM_ZRAM_LAST_REQUEST_FILE")
    _vm_base_phase=$(vm_zram_state_field phase "$VM_ZRAM_BASELINE_FILE")
    _vm_last_phase=$(vm_zram_state_field phase "$VM_ZRAM_LAST_REQUEST_FILE")
    _vm_current_boot=$(vm_zram_current_boot_id)
    if [ ! -s "$VM_ZRAM_BASELINE_FILE" ] || [ ! -s "$VM_ZRAM_LAST_REQUEST_FILE" ] \
        || [ -z "$_vm_base_tx" ] || [ "$_vm_base_tx" != "$_vm_last_tx" ] \
        || [ -z "$_vm_base_boot" ] || [ "$_vm_base_boot" != "$_vm_last_boot" ] \
        || [ "$_vm_base_phase" != baseline ] \
        || { [ "$_vm_last_phase" != staged ] && [ "$_vm_last_phase" != requested ] && [ "$_vm_last_phase" != effective ]; }; then
        _vm_orphan_tx=${_vm_last_tx:-$_vm_base_tx}
        [ -n "$_vm_orphan_tx" ] || _vm_orphan_tx=$(vm_zram_new_txid)
        vm_zram_record_receipt "$_vm_orphan_tx" orphaned journal_invalid \
            || return 1
        vm_zram_clear_journal || return 1
        VM_ZRAM_RECONCILE_RESULT=orphaned
        return 0
    fi
    _vm_last_mmd=$(vm_zram_state_field mmd_size "$VM_ZRAM_LAST_REQUEST_FILE")
    _vm_last_vendor=$(vm_zram_state_field vendor_size "$VM_ZRAM_LAST_REQUEST_FILE")
    _vm_last_algo=$(vm_zram_state_field vendor_algo "$VM_ZRAM_LAST_REQUEST_FILE")
    _vm_current_mmd=$(vm_zram_property_value "$VM_MMD_ZRAM_SIZE_PROPERTY")
    _vm_current_vendor=$(vm_zram_property_value "$VM_ZRAM_SIZE_PROPERTY")
    _vm_current_algo=$(vm_zram_property_value persist.vendor.zram_comp_algorithm)
    if [ "$_vm_last_phase" = staged ]; then
        _vm_staged_bytes=$(vm_zram_size_to_bytes "$_vm_last_mmd")
        if [ "$_vm_current_mmd" = "$_vm_last_mmd" ] \
            && [ "$_vm_current_vendor" = "$_vm_last_vendor" ] \
            && vm_zram_is_active \
            && [ "$(vm_zram_read_disksize)" = "$_vm_staged_bytes" ]; then
            vm_zram_record_receipt "$_vm_last_tx" committed staged_effective \
                || return 1
            vm_zram_clear_journal || return 1
            VM_ZRAM_RECONCILE_RESULT=committed
            return 0
        fi
        vm_zram_record_receipt "$_vm_last_tx" degraded interrupted_staged \
            || return 1
        VM_ZRAM_RECONCILE_RESULT=degraded
        return 2
    fi
    if [ "$_vm_current_mmd" = "$_vm_last_mmd" ] \
        && [ "$_vm_current_vendor" = "$_vm_last_vendor" ] \
        && [ "$_vm_current_algo" = "$_vm_last_algo" ]; then
        if [ "$_vm_base_boot" != "$_vm_current_boot" ]; then
            _vm_request_bytes=$(vm_zram_size_to_bytes "$_vm_last_mmd")
            if vm_zram_is_active \
                && [ -n "$_vm_request_bytes" ] \
                && [ "$(vm_zram_read_disksize)" = "$_vm_request_bytes" ]; then
                _vm_receipt_phase=committed
                _vm_receipt_reason=boot_effective
            else
                _vm_receipt_phase=degraded
                _vm_receipt_reason=boot_readback_mismatch
            fi
        else
            _vm_receipt_phase=canceled
            _vm_receipt_reason=observe_only_preserved
        fi
    else
        _vm_receipt_phase=external_changed
        _vm_receipt_reason=owner_changed
    fi
    vm_zram_record_receipt "$_vm_last_tx" "$_vm_receipt_phase" "$_vm_receipt_reason" \
        || return 1
    if [ "$_vm_receipt_phase" = degraded ]; then
        VM_ZRAM_RECONCILE_RESULT=degraded
        return 2
    fi
    vm_zram_clear_journal || return 1
    VM_ZRAM_RECONCILE_RESULT="$_vm_receipt_phase"
    return 0
}

vm_zram_matches() {
    _vm_zram_algo=$(vm_zram_read_algorithm)
    _vm_zram_size=$(vm_zram_read_disksize)
    [ "$_vm_zram_algo" = "$1" ] && [ "$_vm_zram_size" = "$2" ] \
        && vm_zram_is_active
}

# ZRAM is owned by Android mmd or fs_mgr.  Runtime code may read the effective
# device and update only the documented persistent request; it never mutates
# kernel ZRAM state or takes over the active swap device.
vm_zram_read_algorithm() {
    cat /sys/block/zram0/comp_algorithm 2>/dev/null \
        | sed 's/.*\[\([^]]*\)\].*/\1/' \
        | tr -d ' \n\r\t'
}

vm_zram_read_disksize() {
    cat /sys/block/zram0/disksize 2>/dev/null | tr -d ' \n\r\t'
}

vm_zram_read_swap_kb() {
    _vm_swap_used=$(awk '$1 ~ /(^|\/)zram0$/ { print $4; found=1 } END { if (!found) print 0 }' \
        /proc/swaps 2>/dev/null)
    _vm_swap_rc=$?
    [ "$_vm_swap_rc" -eq 0 ] || return 1
    printf '%s' "$_vm_swap_used" | tail -1 | tr -d ' \n\r\t'
}

vm_zram_is_active() {
    [ "$(vm_zram_active_state)" = active ]
}

vm_zram_active_state() {
    # /proc/swaps' Used column may be zero on an idle but fully enabled zram
    # device. Presence of the zram0 row is the lifecycle signal. A read error
    # is distinct from an empty table and must never authorize online setup.
    _vm_active_probe=$(awk '$1 ~ /(^|\/)zram0$/ { found=1 } END { print found ? "active" : "inactive" }' \
        /proc/swaps 2>/dev/null)
    _vm_active_rc=$?
    [ "$_vm_active_rc" -eq 0 ] || { printf unknown; return 0; }
    printf '%s' "$_vm_active_probe"
}

vm_zram_read_swap_total_kb() {
    awk '/^SwapTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null \
        | tr -d ' \n\r\t'
}

vm_zram_mmd_ready() {
    [ "$(getprop mmd.enabled_aconfig 2>/dev/null | tr -d ' \n\r\t')" = true ] \
        && [ "$(getprop mmd.zram.enabled 2>/dev/null | tr -d ' \n\r\t')" = true ]
}

vm_zram_vendor_alias_supported() {
    # The property must be consumed by this build's init rc before mmd setup.
    # Device name alone is not evidence of a persistent alias.
    grep -Eq '^[[:space:]]*setprop[[:space:]]+mmd[.]zram[.]size[[:space:]]+\$\{persist[.]vendor[.]zram_swap_size_v2(:-[^}]*)?\}' \
        /vendor/etc/init/hw/init.*.board.rc 2>/dev/null
}

vm_zram_vendor_alias_reason() {
    if vm_zram_vendor_alias_supported; then
        printf 'target_init_rc_alias'
    else
        printf 'unproven_board_alias'
    fi
}

vm_zram_owner() {
    if vm_zram_mmd_ready; then
        printf mmd
    else
        printf unknown
    fi
}

vm_zram_read_requested_algorithm() {
    if vm_zram_mmd_ready; then
        _vm_requested_algo=$(vm_zram_property_value mmd.zram.comp_algorithm)
    else
        _vm_requested_algo=$(vm_zram_property_value persist.vendor.zram_comp_algorithm)
    fi
    [ -n "$_vm_requested_algo" ] && printf '%s' "$_vm_requested_algo" || printf unset
}

vm_zram_read_requested_size() {
    if vm_zram_mmd_ready; then
        _vm_requested_size=$(vm_zram_property_value "$VM_MMD_ZRAM_SIZE_PROPERTY")
    else
        _vm_requested_size=$(vm_zram_property_value "$VM_ZRAM_SIZE_PROPERTY")
    fi
    [ -n "$_vm_requested_size" ] && printf '%s' "$_vm_requested_size" || printf unset
}

vm_zram_receipt() {
    printf 'owner=%s\n' "$(vm_zram_owner)"
    printf 'mmd_setup_complete=%s\n' "$(getprop mmd.setup_complete 2>/dev/null | tr -d ' \n\r\t')"
    printf 'mmd_enabled_aconfig=%s\n' "$(getprop mmd.enabled_aconfig 2>/dev/null | tr -d ' \n\r\t')"
    printf 'mmd_zram_enabled=%s\n' "$(getprop mmd.zram.enabled 2>/dev/null | tr -d ' \n\r\t')"
    printf 'mmd_requested_size=%s\n' "$(getprop mmd.zram.size 2>/dev/null | tr -d ' \n\r\t')"
    printf 'mmd_requested_algorithm=%s\n' "$(getprop mmd.zram.comp_algorithm 2>/dev/null | tr -d ' \n\r\t')"
    printf 'algorithm=%s\n' "$(vm_zram_read_algorithm)"
    printf 'disksize_bytes=%s\n' "$(vm_zram_read_disksize)"
    printf 'active=%s\n' "$(vm_zram_is_active && printf true || printf false)"
    printf 'swap_kb=%s\n' "$(vm_zram_read_swap_kb)"
    printf 'swap_total_kb=%s\n' "$(vm_zram_read_swap_total_kb)"
    printf 'requested_algorithm=%s\n' "$(vm_zram_read_requested_algorithm)"
    printf 'requested_size=%s\n' "$(vm_zram_read_requested_size)"
}

vm_zram_read_requested_mmd_size() {
    vm_zram_property_value "$VM_MMD_ZRAM_SIZE_PROPERTY"
}

vm_mmd_setup_zram() {
    _vm_mmd_bin=""
    for _vm_candidate in /system/bin/mmd /vendor/bin/mmd /product/bin/mmd; do
        [ -x "$_vm_candidate" ] && _vm_mmd_bin="$_vm_candidate" && break
    done
    [ -n "$_vm_mmd_bin" ] || return 127
    "$_vm_mmd_bin" --setup-zram >/dev/null 2>&1
}
