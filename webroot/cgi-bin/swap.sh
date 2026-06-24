#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/swap.sh
# GET  → 返回当前 swap/VM 参数 + ZRAM 状态 JSON
# POST → 切换 optimized / stock / custom VM 参数 (即时生效, 无需重启)
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback

SWAP_MODE_FILE="$MODDIR/.swap_mode"
SWAP_CUSTOM_FILE="$MODDIR/.swap_custom"
OPT_SWAPPINESS=100
OPT_MIN_FREE_KBYTES=131072
OPT_WATERMARK_SCALE=200
OPT_VFS_CACHE_PRESSURE=60
STOCK_SWAPPINESS=150
STOCK_MIN_FREE_KBYTES=27386
STOCK_WATERMARK_SCALE=50
STOCK_VFS_CACHE_PRESSURE=100

json_num_field() {
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p"
}

is_uint_range() {
    val="$1"
    min="$2"
    max="$3"
    case "$val" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$val" -ge "$min" ] 2>/dev/null && [ "$val" -le "$max" ] 2>/dev/null
}

write_vm_params() {
    echo "$1" > /proc/sys/vm/swappiness 2>/dev/null || return 1
    echo "$2" > /proc/sys/vm/min_free_kbytes 2>/dev/null || return 1
    echo "$3" > /proc/sys/vm/watermark_scale_factor 2>/dev/null || return 1
    echo "$4" > /proc/sys/vm/vfs_cache_pressure 2>/dev/null || return 1
    return 0
}

emit_state() {
    json_headers
    sw=$(cat /proc/sys/vm/swappiness 2>/dev/null)
    mfk=$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null)
    wsf=$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)
    vcp=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)
    algo=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | sed 's/.*\[\(.*\)\].*/\1/')
    disksize=$(cat /sys/block/zram0/disksize 2>/dev/null)

    # ZRAM mm_stat: orig compr mem_used ...
    mm=$(cat /sys/block/zram0/mm_stat 2>/dev/null)
    orig=$(echo "$mm" | awk '{print $1}')
    compr=$(echo "$mm" | awk '{print $2}')
    mem_used=$(echo "$mm" | awk '{print $3}')

    # 原厂 ZRAM 大小 = 50% RAM (fstab.zram.50p), 用 awk 避免 32 位溢出
    stock_zram_bytes=$(awk '/MemTotal/{printf "%.0f", $2 * 512}' /proc/meminfo 2>/dev/null)

    # 判断当前模式
    mode="custom"
    if [ "$sw" = "$OPT_SWAPPINESS" ] && [ "$mfk" = "$OPT_MIN_FREE_KBYTES" ] && [ "$wsf" = "$OPT_WATERMARK_SCALE" ] && [ "$vcp" = "$OPT_VFS_CACHE_PRESSURE" ]; then
        mode="optimized"
    elif [ "$sw" = "$STOCK_SWAPPINESS" ] && [ "$mfk" = "$STOCK_MIN_FREE_KBYTES" ] && [ "$wsf" = "$STOCK_WATERMARK_SCALE" ] && [ "$vcp" = "$STOCK_VFS_CACHE_PRESSURE" ]; then
        mode="stock"
    fi

    printf '{"swappiness":%s,"min_free_kbytes":%s,"watermark_scale_factor":%s,"vfs_cache_pressure":%s,"zram_algo":"%s","zram_disksize":%s,"stock_zram_size":%s,"zram_orig_bytes":%s,"zram_compr_bytes":%s,"zram_mem_used_bytes":%s,"mode":"%s","optimized":{"swappiness":%s,"min_free_kbytes":%s,"watermark_scale_factor":%s,"vfs_cache_pressure":%s},"stock":{"swappiness":%s,"min_free_kbytes":%s,"watermark_scale_factor":%s,"vfs_cache_pressure":%s}}' \
        "${sw:-0}" "${mfk:-0}" "${wsf:-0}" "${vcp:-0}" "$(json_escape "${algo:-unknown}")" \
        "${disksize:-0}" "${stock_zram_bytes:-0}" \
        "${orig:-0}" "${compr:-0}" "${mem_used:-0}" "$mode" \
        "$OPT_SWAPPINESS" "$OPT_MIN_FREE_KBYTES" "$OPT_WATERMARK_SCALE" "$OPT_VFS_CACHE_PRESSURE" \
        "$STOCK_SWAPPINESS" "$STOCK_MIN_FREE_KBYTES" "$STOCK_WATERMARK_SCALE" "$STOCK_VFS_CACHE_PRESSURE"
}

if [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "swap"
    len="${CONTENT_LENGTH:-0}"
    [ "$len" -gt 512 ] 2>/dev/null && len=512
    body=$(dd bs=1 count="$len" 2>/dev/null)
    mode=$(printf '%s' "$body" | sed 's/.*"mode"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/')
    case "$mode" in
        optimized)
            if write_vm_params "$OPT_SWAPPINESS" "$OPT_MIN_FREE_KBYTES" "$OPT_WATERMARK_SCALE" "$OPT_VFS_CACHE_PRESSURE"; then
                echo "optimized" > "$SWAP_MODE_FILE"
                emit_state
            else
                json_error '500 Internal Server Error' 'failed to write VM params'
            fi
            ;;
        stock)
            if write_vm_params "$STOCK_SWAPPINESS" "$STOCK_MIN_FREE_KBYTES" "$STOCK_WATERMARK_SCALE" "$STOCK_VFS_CACHE_PRESSURE"; then
                echo "stock" > "$SWAP_MODE_FILE"
                emit_state
            else
                json_error '500 Internal Server Error' 'failed to write VM params'
            fi
            ;;
        custom)
            sw=$(json_num_field "$body" swappiness)
            mfk=$(json_num_field "$body" min_free_kbytes)
            wsf=$(json_num_field "$body" watermark_scale_factor)
            vcp=$(json_num_field "$body" vfs_cache_pressure)
            if ! is_uint_range "$sw" 0 200; then
                json_error '400 Bad Request' 'invalid swappiness'
            elif ! is_uint_range "$mfk" 16384 262144; then
                json_error '400 Bad Request' 'invalid min_free_kbytes'
            elif ! is_uint_range "$wsf" 10 500; then
                json_error '400 Bad Request' 'invalid watermark_scale_factor'
            elif ! is_uint_range "$vcp" 10 200; then
                json_error '400 Bad Request' 'invalid vfs_cache_pressure'
            else
                if write_vm_params "$sw" "$mfk" "$wsf" "$vcp"; then
                    {
                        printf 'swappiness=%s\n' "$sw"
                        printf 'min_free_kbytes=%s\n' "$mfk"
                        printf 'watermark_scale_factor=%s\n' "$wsf"
                        printf 'vfs_cache_pressure=%s\n' "$vcp"
                    } > "$SWAP_CUSTOM_FILE"
                    echo "custom" > "$SWAP_MODE_FILE"
                    emit_state
                else
                    json_error '500 Internal Server Error' 'failed to write VM params'
                fi
            fi
            ;;
        *)
            json_error '400 Bad Request' 'invalid mode'
            ;;
    esac
elif [ "$REQUEST_METHOD" = "GET" ]; then
    emit_state
else
    json_error '405 Method Not Allowed' 'GET or POST only'
fi
