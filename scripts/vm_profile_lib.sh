#!/system/bin/sh

# Pixel 9 Pro VM contract shared by boot service and swap CGI.
# VM tuning remains module policy; ZRAM is an observation-only view of the
# Android/APatch mmd owner. Keeping both contracts here prevents status and UI
# classification from inventing a second ZRAM owner.

VM_ZRAM_ALGO="lz77eh"
VM_ZRAM_SIZE_BYTES="11945377792"
VM_ZRAM_SIZE_PROPERTY="persist.vendor.zram_swap_size_v2"
VM_MMD_ZRAM_SIZE_PROPERTY="mmd.zram.size"
VM_ZRAM_SIZE_MIN_BYTES=1073741824
VM_ZRAM_SIZE_MAX_BYTES=17179869184
VM_ZRAM_SIZE_STEP_BYTES=268435456

VM_OPT_SWAPPINESS=100
VM_OPT_MIN_FREE_KBYTES=131072
VM_OPT_WATERMARK_SCALE=200
VM_OPT_VFS_CACHE_PRESSURE=60

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
    printf '"zram_target":{"algorithm":"%s","size_bytes":%s,"property":"%s","mmd_property":"%s","policy":"mmd_owner_online_if_inactive"},' \
        "$VM_ZRAM_ALGO" "$VM_ZRAM_SIZE_BYTES" "$VM_ZRAM_SIZE_PROPERTY" "$VM_MMD_ZRAM_SIZE_PROPERTY"
    printf '"zram_size_limits":{"min_bytes":%s,"max_bytes":%s,"step_bytes":%s}' "$VM_ZRAM_SIZE_MIN_BYTES" "$VM_ZRAM_SIZE_MAX_BYTES" "$VM_ZRAM_SIZE_STEP_BYTES"
}

vm_zram_size_is_valid() {
    case "$1" in
        ''|*[!0-9%]*) return 1 ;;
        *%) _vm_pct=${1%%%}; [ -n "$_vm_pct" ] && [ "$_vm_pct" -ge 10 ] 2>/dev/null && [ "$_vm_pct" -le 100 ] 2>/dev/null ;;
        *) [ "$1" -ge "$VM_ZRAM_SIZE_MIN_BYTES" ] 2>/dev/null && [ "$1" -le "$VM_ZRAM_SIZE_MAX_BYTES" ] 2>/dev/null ;;
    esac
}

vm_zram_size_to_bytes() {
    case "$1" in
        *%) _vm_pct=${1%%%}; awk -v pct="$_vm_pct" '/^MemTotal:/{printf "%.0f", $2 * 1024 * pct / 100; exit}' /proc/meminfo 2>/dev/null ;;
        *) printf '%s' "$1" ;;
    esac
}

vm_zram_matches() {
    _vm_zram_algo=$(vm_zram_read_algorithm)
    _vm_zram_size=$(vm_zram_read_disksize)
    [ "$_vm_zram_algo" = "$1" ] && [ "$_vm_zram_size" = "$2" ] \
        && vm_zram_is_active
}

# ZRAM is owned by Android mmd or fs_mgr.  Runtime code may only read the
# effective device and the persistent request; it never mutates kernel ZRAM
# state or takes over the active swap device.
vm_zram_read_algorithm() {
    cat /sys/block/zram0/comp_algorithm 2>/dev/null \
        | sed 's/.*\[\([^]]*\)\].*/\1/' \
        | tr -d ' \n\r\t'
}

vm_zram_read_disksize() {
    cat /sys/block/zram0/disksize 2>/dev/null | tr -d ' \n\r\t'
}

vm_zram_read_swap_kb() {
    awk '$1 ~ /(^|\/)zram0$/ { print $3; found=1 } END { if (!found) print 0 }' \
        /proc/swaps 2>/dev/null | tail -1 | tr -d ' \n\r\t'
}

vm_zram_is_active() {
    [ "$(vm_zram_read_swap_kb)" -gt 0 ] 2>/dev/null
}

vm_zram_read_swap_total_kb() {
    awk '/^SwapTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null \
        | tr -d ' \n\r\t'
}

vm_zram_mmd_ready() {
    [ "$(getprop mmd.enabled_aconfig 2>/dev/null | tr -d ' \n\r\t')" = true ] \
        && [ "$(getprop mmd.zram.enabled 2>/dev/null | tr -d ' \n\r\t')" = true ]
}

vm_zram_owner() {
    if vm_zram_mmd_ready; then
        printf mmd
    else
        printf unknown
    fi
}

vm_zram_read_requested_algorithm() {
    _vm_requested_algo=$(getprop persist.vendor.zram_comp_algorithm 2>/dev/null \
        | tr -d ' \n\r\t')
    [ -n "$_vm_requested_algo" ] && printf '%s' "$_vm_requested_algo" || printf unset
}

vm_zram_read_requested_size() {
    _vm_requested_size=$(getprop "$VM_MMD_ZRAM_SIZE_PROPERTY" 2>/dev/null \
        | tr -d ' \n\r\t')
    [ -n "$_vm_requested_size" ] || _vm_requested_size=$(getprop "$VM_ZRAM_SIZE_PROPERTY" 2>/dev/null \
        | tr -d ' \n\r\t')
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
    getprop "$VM_MMD_ZRAM_SIZE_PROPERTY" 2>/dev/null | tr -d ' \n\r\t'
}

vm_mmd_setup_zram() {
    _vm_mmd_bin=""
    for _vm_candidate in /system/bin/mmd /vendor/bin/mmd /product/bin/mmd; do
        [ -x "$_vm_candidate" ] && _vm_mmd_bin="$_vm_candidate" && break
    done
    [ -n "$_vm_mmd_bin" ] || return 127
    "$_vm_mmd_bin" --setup-zram >/dev/null 2>&1
}
