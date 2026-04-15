#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/set_thermal.sh
# GET  → 返回当前温控档位 {"offset": N}
# POST → 切换温控档位（body: {"offset": 0|2|4|6}）
#        1. 以 stock JSON 为基准 + offset 重写 thermal_info_config.json
#        2. 尝试重启 thermalserviced（无需整机重启）
#        3. 保存 offset 到 .thermal_offset
##############################################################
MODDIR="/data/adb/modules/pixel9pro_control"
OFFSET_FILE="$MODDIR/.thermal_offset"
STOCK_JSON="$MODDIR/system/vendor/etc/thermal_stock.json"
OUT_JSON="$MODDIR/system/vendor/etc/thermal_info_config.json"

if [ "$REQUEST_METHOD" = "POST" ]; then
    body=$(dd bs=1 count="${CONTENT_LENGTH:-0}" 2>/dev/null)
    offset=$(printf '%s' "$body" | sed 's/.*"offset"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/')

    # 只接受 0 / 2 / 4 / 6
    case "$offset" in
        0|2|4|6) ;;
        *)
            printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
            printf '{"ok":false,"error":"invalid offset: %s"}\n' "$offset"
            exit 0
            ;;
    esac

    if [ ! -f "$STOCK_JSON" ]; then
        printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
        printf '{"ok":false,"error":"stock json not found"}\n'
        exit 0
    fi

    # ──────────────────────────────────────────────────────────
    # 用 awk 将目标传感器的 HotThreshold 数值整体 +offset
    # 目标传感器：VIRTUAL-SKIN / VIRTUAL-SKIN-HINT / VIRTUAL-SKIN-SOC
    # HotThreshold 中的 "NAN" 字符串跳过，其余浮点数 +offset
    # 不修改 HotHysteresis，不修改充电链路传感器
    # ──────────────────────────────────────────────────────────
    awk -v off="$offset" '
    /"Name":/ {
        n = $0
        sub(/.*"Name": *"/, "", n)
        sub(/".*/, "", n)
        cur = n
        tgt = (cur == "VIRTUAL-SKIN" || cur == "VIRTUAL-SKIN-HINT" || cur == "VIRTUAL-SKIN-SOC" || cur == "VIRTUAL-SKIN-CPU-LIGHT-ODPM" || cur == "VIRTUAL-SKIN-CPU-MID" || cur == "VIRTUAL-SKIN-CPU-ODPM")
    }
    tgt && /"HotThreshold":/ {
        line = $0
        bs = index(line, "[")
        prefix = substr(line, 1, bs - 1)
        rest   = substr(line, bs + 1)
        be     = index(rest, "]")
        inner  = substr(rest, 1, be - 1)
        suffix = substr(rest, be)

        n_v = split(inner, vals, ", ")
        result = ""
        for (i = 1; i <= n_v; i++) {
            v = vals[i]
            if (v != "\"NAN\"") {
                v = sprintf("%.1f", v + off + 0)
            }
            result = result (i > 1 ? ", " : "") v
        }
        print prefix "[" result suffix
        next
    }
    { print }
    ' "$STOCK_JSON" > "${OUT_JSON}.tmp"

    if [ $? -ne 0 ] || [ ! -s "${OUT_JSON}.tmp" ]; then
        rm -f "${OUT_JSON}.tmp"
        printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
        printf '{"ok":false,"error":"awk failed"}\n'
        exit 0
    fi

    mv "${OUT_JSON}.tmp" "$OUT_JSON"
    printf '%s' "$offset" > "$OFFSET_FILE"

    # ──────────────────────────────────────────────────────────
    # 尝试重启温控服务使修改立即生效（无需整机重启）
    # 遍历不同固件版本的服务名
    # ──────────────────────────────────────────────────────────
    restarted=false
    for svc in vendor.thermal-hal vendor.thermal-hal-2-0 thermal-hal-2-0 thermalserviced; do
        state=$(getprop "init.svc.$svc" 2>/dev/null)
        if [ "$state" = "running" ]; then
            stop "$svc" 2>/dev/null
            sleep 1
            start "$svc" 2>/dev/null
            restarted=true
            log -t pixel9pro_ctrl "Thermal service restarted: $svc (offset=${offset}C)"
            break
        fi
    done

    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    printf '{"ok":true,"offset":%s,"restarted":%s}\n' "$offset" "$restarted"

else
    # GET: 返回当前保存的温控档位
    offset=$(cat "$OFFSET_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$offset" in
        0|2|4|6) ;;
        *) offset="4" ;;
    esac
    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    printf '{"offset":%s}\n' "$offset"
fi
