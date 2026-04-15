#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/swap.sh
# GET  → 返回当前 swap/VM 参数 + ZRAM 状态 JSON
# POST → 切换 optimized / stock VM 参数 (即时生效, 无需重启)
##############################################################
printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

if [ "$REQUEST_METHOD" = "POST" ]; then
    len="${CONTENT_LENGTH:-0}"
    [ "$len" -gt 512 ] 2>/dev/null && len=512
    body=$(dd bs=1 count="$len" 2>/dev/null)
    mode=$(printf '%s' "$body" | sed 's/.*"mode"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/')
    case "$mode" in
        optimized)
            echo 100 > /proc/sys/vm/swappiness
            echo 65536 > /proc/sys/vm/min_free_kbytes
            echo 60 > /proc/sys/vm/vfs_cache_pressure
            printf '{"ok":true,"mode":"optimized"}'
            ;;
        stock)
            echo 150 > /proc/sys/vm/swappiness
            echo 27386 > /proc/sys/vm/min_free_kbytes
            echo 100 > /proc/sys/vm/vfs_cache_pressure
            printf '{"ok":true,"mode":"stock"}'
            ;;
        *)
            printf '{"ok":false,"error":"invalid mode"}'
            ;;
    esac
else
    sw=$(cat /proc/sys/vm/swappiness 2>/dev/null)
    mfk=$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null)
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
    if [ "$sw" = "100" ] && [ "$mfk" = "65536" ] && [ "$vcp" = "60" ]; then
        mode="optimized"
    elif [ "$sw" = "150" ] && [ "$vcp" = "100" ]; then
        mode="stock"
    fi

    printf '{"swappiness":%s,"min_free_kbytes":%s,"vfs_cache_pressure":%s,"zram_algo":"%s","zram_disksize":%s,"stock_zram_size":%s,"zram_orig_bytes":%s,"zram_compr_bytes":%s,"zram_mem_used_bytes":%s,"mode":"%s"}' \
        "${sw:-0}" "${mfk:-0}" "${vcp:-0}" "${algo:-unknown}" \
        "${disksize:-0}" "${stock_zram_bytes:-0}" \
        "${orig:-0}" "${compr:-0}" "${mem_used:-0}" "$mode"
fi
