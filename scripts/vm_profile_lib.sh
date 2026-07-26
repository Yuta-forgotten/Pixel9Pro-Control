#!/system/bin/sh

# Pixel 9 Pro ZRAM/VM contract shared by boot service and swap CGI.
# Values are device-policy data, not Android-wide defaults. Keeping them here
# prevents boot restore, WebUI writes, and status classification from drifting.

VM_ZRAM_ALGO="lz77eh"
VM_ZRAM_SIZE_BYTES="11945377792"

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
    printf '"zram_target":{"algorithm":"%s","size_bytes":%s}' "$VM_ZRAM_ALGO" "$VM_ZRAM_SIZE_BYTES"
}

vm_zram_matches() {
    _vm_zram_algo=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | sed 's/.*\[\(.*\)\].*/\1/')
    _vm_zram_size=$(cat /sys/block/zram0/disksize 2>/dev/null | tr -d ' \n\r')
    [ "$_vm_zram_algo" = "$1" ] && [ "$_vm_zram_size" = "$2" ] \
        && awk '$1 ~ /(^|\/)zram0$/ { found=1 } END { exit found ? 0 : 1 }' /proc/swaps 2>/dev/null
}

vm_configure_zram_raw() {
    printf '1\n' > /sys/block/zram0/reset 2>/dev/null \
        && printf '%s\n' "$1" > /sys/block/zram0/comp_algorithm 2>/dev/null \
        && printf '%s\n' "$2" > /sys/block/zram0/disksize 2>/dev/null \
        && mkswap /dev/block/zram0 >/dev/null 2>&1 \
        && swapon /dev/block/zram0 2>/dev/null
}

vm_reconfigure_zram() {
    _vm_target_algo="$1"
    _vm_target_size="$2"
    _vm_old_algo=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | sed 's/.*\[\(.*\)\].*/\1/')
    _vm_old_size=$(cat /sys/block/zram0/disksize 2>/dev/null | tr -d ' \n\r')
    case "$_vm_target_algo" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
    case "$_vm_old_algo" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
    case "$_vm_target_size" in ''|*[!0-9]*) return 1 ;; esac
    case "$_vm_old_size" in ''|*[!0-9]*) return 1 ;; esac

    swapoff /dev/block/zram0 2>/dev/null || return 1
    if vm_configure_zram_raw "$_vm_target_algo" "$_vm_target_size" \
        && vm_zram_matches "$_vm_target_algo" "$_vm_target_size"; then
        return 0
    fi

    swapoff /dev/block/zram0 2>/dev/null || true
    if vm_configure_zram_raw "$_vm_old_algo" "$_vm_old_size" >/dev/null 2>&1 \
        && vm_zram_matches "$_vm_old_algo" "$_vm_old_size"; then
        return 1
    fi
    return 2
}
