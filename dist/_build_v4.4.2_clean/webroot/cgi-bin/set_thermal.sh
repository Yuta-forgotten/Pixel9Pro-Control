#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/set_thermal.sh
# GET  → 返回当前温控档位 {"offset": N}
# POST → 切换温控档位（body: {"offset": 0|2|4|6}）
#        1. 以 stock JSON 为基准 + offset 重写 thermal_info_config.json
#        2. 尝试重启 thermalserviced（无需整机重启）
#        3. 保存 offset 到 .thermal_offset
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback

OFFSET_FILE="$MODDIR/.thermal_offset"
STOCK_JSON="$MODDIR/system/vendor/etc/thermal_stock.json"
OUT_JSON="$MODDIR/system/vendor/etc/thermal_info_config.json"

if [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "thermal"
    len="${CONTENT_LENGTH:-0}"
    [ "$len" -gt 512 ] 2>/dev/null && len=512
    body=$(dd bs=1 count="$len" 2>/dev/null)
    offset=$(printf '%s' "$body" | sed 's/.*"offset"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/')

    # 只接受 0 / 2 / 4 / 6
    case "$offset" in
        0|2|4|6) ;;
        *)
            json_error '400 Bad Request' "invalid offset: $offset"
            ;;
    esac

    if [ ! -f "$STOCK_JSON" ]; then
        json_error '500 Internal Server Error' 'stock json not found'
    fi

    # ──────────────────────────────────────────────────────────
    # 用 awk 将目标传感器的 HotThreshold 数值整体 +offset
    # 目标传感器 (Pro + Pro XL 共有):
    #   VIRTUAL-SKIN / VIRTUAL-SKIN-HINT / VIRTUAL-SKIN-SOC
    #   VIRTUAL-SKIN-CPU-LIGHT-ODPM / CPU-MID / CPU-ODPM / CPU-HIGH / GPU
    # HotThreshold 中的 "NAN" 字符串跳过，其余浮点数 +offset
    # 支持多行 JSON 格式 (HotThreshold 数组跨行)
    # ──────────────────────────────────────────────────────────
    awk -v off="$offset" '
    /"Name":/ {
        n = $0
        sub(/.*"Name": *"/, "", n)
        sub(/".*/, "", n)
        cur = n
        tgt = (cur == "VIRTUAL-SKIN" || cur == "VIRTUAL-SKIN-HINT" || cur == "VIRTUAL-SKIN-SOC" || cur == "VIRTUAL-SKIN-CPU-LIGHT-ODPM" || cur == "VIRTUAL-SKIN-CPU-MID" || cur == "VIRTUAL-SKIN-CPU-ODPM" || cur == "VIRTUAL-SKIN-CPU-HIGH" || cur == "VIRTUAL-SKIN-GPU")
    }
    tgt && /"HotThreshold"/ && /\[/ && /\]/ {
        line = $0
        bs = index(line, "[")
        prefix = substr(line, 1, bs - 1)
        rest   = substr(line, bs + 1)
        be     = index(rest, "]")
        inner  = substr(rest, 1, be - 1)
        suffix = substr(rest, be)
        n_v = split(inner, vals, ",")
        result = ""
        for (i = 1; i <= n_v; i++) {
            v = vals[i]; gsub(/[ \t]/, "", v)
            if (v == "\"NAN\"") {
                result = result (i > 1 ? ", " : "") v
            } else {
                result = result (i > 1 ? ", " : "") sprintf("%.1f", v + off + 0)
            }
        }
        print prefix "[" result suffix
        next
    }
    tgt && /"HotThreshold"/ && /\[/ && !/\]/ {
        in_hot = 1; print; next
    }
    in_hot {
        if (/\]/) { in_hot = 0; print; next }
        line = $0; gsub(/[ \t]/, "", line); gsub(/,/, "", line)
        if (line == "\"NAN\"") { print; next }
        if (match(line, /^[0-9]/) || match(line, /^-/)) {
            indent = $0; sub(/[^ \t].*/, "", indent)
            val = line + 0
            newval = sprintf("%.1f", val + off)
            trailing = ""
            if (sub(/,[ \t]*$/, "", $0) > 0) trailing = ","
            printf "%s%s%s\n", indent, newval, trailing
            next
        }
        print; next
    }
    { print }
    ' "$STOCK_JSON" > "${OUT_JSON}.tmp"

    if [ $? -ne 0 ] || [ ! -s "${OUT_JSON}.tmp" ]; then
        rm -f "${OUT_JSON}.tmp"
        json_error '500 Internal Server Error' 'awk failed'
    fi

    mv "${OUT_JSON}.tmp" "$OUT_JSON"
    printf '%s' "$offset" > "$OFFSET_FILE"

    # ──────────────────────────────────────────────────────────
    # 尝试重启温控服务使修改立即生效（无需整机重启）
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

    json_headers
    printf '{"ok":true,"offset":%s,"restarted":%s}\n' "$offset" "$restarted"

elif [ "$REQUEST_METHOD" = "GET" ]; then
    offset=$(cat "$OFFSET_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$offset" in
        0|2|4|6) ;;
        *) offset="4" ;;
    esac
    json_headers
    printf '{"offset":%s}\n' "$offset"
else
    json_error '405 Method Not Allowed' 'GET or POST only'
fi
