#!/system/bin/sh
# GET returns the persisted WebUI theme fallback. POST validates and atomically
# updates it; browser localStorage remains the primary copy.
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
    read_json_body 256
    body="$JSON_BODY"
    mode=$(printf '%s' "$body" | sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([a-zA-Z]*\)".*/\1/p')
    palette=$(printf '%s' "$body" | sed -n 's/.*"palette"[[:space:]]*:[[:space:]]*"\([a-zA-Z0-9_]*\)".*/\1/p')
    # custom: 仅接受 #RRGGBB, 捕获 6 位十六进制, 落盘时补回 #
    custom=$(printf '%s' "$body" | sed -n 's/.*"custom"[[:space:]]*:[[:space:]]*"#\([0-9a-fA-F]\{6\}\)".*/\1/p')
    case "$mode" in system|light|dark) ;; *) json_error '400 Bad Request' 'invalid theme mode' ;; esac
    case "$palette" in
        ''|*[!a-zA-Z0-9_]*) json_error '400 Bad Request' 'invalid theme palette' ;;
        *) ;;
    esac
    [ ! -d "$THEME_FILE" ] \
        || json_error '500 Internal Server Error' 'theme state path is not a file'
    _theme_tmp="${THEME_FILE}.tmp.$$"
    if {
        printf 'mode=%s\n' "$mode"
        printf 'palette=%s\n' "$palette"
        [ -z "$custom" ] || printf 'custom=#%s\n' "$custom"
    } > "$_theme_tmp" 2>/dev/null \
        && mv "$_theme_tmp" "$THEME_FILE" 2>/dev/null \
        && [ -f "$THEME_FILE" ]; then
        :
    else
        rm -f "$_theme_tmp" 2>/dev/null
        json_error '500 Internal Server Error' 'failed to persist theme'
    fi
    emit_theme
elif [ "$REQUEST_METHOD" = "GET" ]; then
    emit_theme
else
    json_error '405 Method Not Allowed' 'GET or POST only'
fi
