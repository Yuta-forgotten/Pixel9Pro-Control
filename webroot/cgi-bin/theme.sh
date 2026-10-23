#!/system/bin/sh
# GET returns the persisted WebUI theme fallback. POST validates and atomically
# updates it; browser localStorage remains the primary copy.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback

THEME_FILE="$MODDIR/.webui_theme"

read_theme_field() {
    printf '%s\n' "$_theme_snapshot" | sed -n "s/^$1=//p" | head -1 | tr -d ' \n\r'
}

emit_theme() {
    _theme_snapshot=''
    if [ -e "$THEME_FILE" ] || [ -L "$THEME_FILE" ]; then
        [ -f "$THEME_FILE" ] && [ ! -L "$THEME_FILE" ] \
            || json_error '503 Service Unavailable' 'theme state is not a regular file'
        _theme_snapshot=$(head -c 1025 "$THEME_FILE" 2>/dev/null) \
            || json_error '503 Service Unavailable' 'cannot read persisted theme'
        _theme_bytes=$(printf '%s' "$_theme_snapshot" | wc -c | tr -d ' \r\n')
        [ "$_theme_bytes" -le 1024 ] || json_error '503 Service Unavailable' 'persisted theme exceeds size bound'
    fi
    mode=$(read_theme_field mode)
    palette=$(read_theme_field palette)
    custom=$(read_theme_field custom)
    json_headers
    printf '{"mode":"%s","palette":"%s","custom":"%s"}' \
        "$(json_escape "$mode")" "$(json_escape "$palette")" "$(json_escape "$custom")"
}

if [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "theme"
    read_json_body 256
    body="$JSON_BODY"
    cgi_json_schema 'mode:string palette:string custom:string'
    mode=$(cgi_json_field mode)
    palette=$(cgi_json_field palette)
    custom=$(cgi_json_field custom)
    case "$custom" in
        '') ;;
        \#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) custom=${custom#\#} ;;
        *) json_error '400 Bad Request' 'invalid custom theme color' ;;
    esac
    case "$mode" in system|light|dark) ;; *) json_error '400 Bad Request' 'invalid theme mode' ;; esac
    case "$palette" in
        ''|*[!a-zA-Z0-9_]*) json_error '400 Bad Request' 'invalid theme palette' ;;
        *) ;;
    esac
    [ "$palette" != custom ] || [ -n "$custom" ] || json_error '400 Bad Request' 'custom palette requires a color'
    [ ! -d "$THEME_FILE" ] \
        || json_error '500 Internal Server Error' 'theme state path is not a file'
    _theme_value=$({
        printf 'mode=%s\n' "$mode"
        printf 'palette=%s\n' "$palette"
        [ -z "$custom" ] || printf 'custom=#%s\n' "$custom"
    })
    cgi_atomic_write "$THEME_FILE" "$_theme_value" || json_error '500 Internal Server Error' 'failed to persist theme'
    emit_theme
elif [ "$REQUEST_METHOD" = "GET" ]; then
    emit_theme
else
    json_error '405 Method Not Allowed' 'GET or POST only'
fi
