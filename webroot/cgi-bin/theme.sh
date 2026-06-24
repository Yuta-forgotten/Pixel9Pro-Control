#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/theme.sh
# GET  → 返回服务端保存的主题 (mode/palette/custom) JSON
# POST → 保存主题到 $MODDIR/.webui_theme (token 鉴权, 即时落盘)
# 说明: 前端 localStorage 为主、此处为兜底备份; WebView 清数据后回读,
#       并随模块更新由 customize.sh 迁移 .webui_theme, 更新不丢主题。
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback

THEME_FILE="$MODDIR/.webui_theme"

read_theme_field() {
    sed -n "s/^$1=//p" "$THEME_FILE" 2>/dev/null | head -1 | tr -d ' \n\r'
}

emit_theme() {
    json_headers
    mode=$(read_theme_field mode)
    palette=$(read_theme_field palette)
    custom=$(read_theme_field custom)
    printf '{"mode":"%s","palette":"%s","custom":"%s"}' \
        "$(json_escape "$mode")" "$(json_escape "$palette")" "$(json_escape "$custom")"
}

if [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "theme"
    len="${CONTENT_LENGTH:-0}"
    [ "$len" -gt 256 ] 2>/dev/null && len=256
    body=$(dd bs=1 count="$len" 2>/dev/null)
    mode=$(printf '%s' "$body" | sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([a-zA-Z]*\)".*/\1/p')
    palette=$(printf '%s' "$body" | sed -n 's/.*"palette"[[:space:]]*:[[:space:]]*"\([a-zA-Z0-9_]*\)".*/\1/p')
    # custom: 仅接受 #RRGGBB, 捕获 6 位十六进制, 落盘时补回 #
    custom=$(printf '%s' "$body" | sed -n 's/.*"custom"[[:space:]]*:[[:space:]]*"#\([0-9a-fA-F]\{6\}\)".*/\1/p')
    # 服务端兜底校验 (不信任前端)
    case "$mode" in system|light|dark) ;; *) mode="system" ;; esac
    case "$palette" in ''|*[!a-zA-Z0-9_]*) palette="default" ;; esac
    {
        printf 'mode=%s\n' "$mode"
        printf 'palette=%s\n' "$palette"
        [ -n "$custom" ] && printf 'custom=#%s\n' "$custom"
    } > "$THEME_FILE"
    emit_theme
elif [ "$REQUEST_METHOD" = "GET" ]; then
    emit_theme
else
    json_error '405 Method Not Allowed' 'GET or POST only'
fi
