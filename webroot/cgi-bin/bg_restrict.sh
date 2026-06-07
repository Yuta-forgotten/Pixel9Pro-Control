#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/bg_restrict.sh
# GET  -> 返回后台限制开关状态 + 包名列表 + 各包当前 bucket/appops
# POST -> 开关切换 / 添加包名 / 移除包名
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
. "$MODDIR/scripts/bg_restrict_lib.sh"

BG_ENABLED_FILE="$MODDIR/.bg_restrict_enabled"
BG_LIST_FILE="$MODDIR/.bg_restrict_list"
BG_BASELINE_FILE="$MODDIR/.bg_restrict_baseline"

emit_pkg_status() {
    _pkg="$1"
    _bucket=$(bg_read_standby_bucket "$_pkg")
    _ops_mode=$(bg_read_appop_mode "$_pkg" RUN_ANY_IN_BACKGROUND)
    printf '{"pkg":"%s","bucket":"%s","appops":"%s"}' \
        "$(json_escape "$_pkg")" "$(json_escape "$_bucket")" "$_ops_mode"
}

emit_state() {
    _enabled=$(bg_read_enabled)
    printf '"enabled":"%s","packages":[' "$_enabled"
    _first=1
    if [ -s "$BG_LIST_FILE" ]; then
        while IFS= read -r _line || [ -n "$_line" ]; do
            _p=$(printf '%s' "$_line" | tr -d ' \n\r\t')
            [ -z "$_p" ] && continue
            case "$_p" in \#*) continue ;; esac
            [ "$_first" -eq 1 ] && _first=0 || printf ','
            emit_pkg_status "$_p"
        done < "$BG_LIST_FILE"
    fi
    printf ']'
}

require_loopback

if [ "$REQUEST_METHOD" = "GET" ]; then
    json_headers
    printf '{'
    emit_state
    printf '}\n'

elif [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "bg_restrict"
    len="${CONTENT_LENGTH:-0}"
    [ "$len" -gt 1024 ] 2>/dev/null && len=1024
    body=$(dd bs=1 count="$len" 2>/dev/null)

    action=$(printf '%s' "$body" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')
    pkg=$(printf '%s' "$body" | sed -n 's/.*"package"[[:space:]]*:[[:space:]]*"\([a-zA-Z0-9._]*\)".*/\1/p')

    case "$action" in
        toggle)
            cur=$(bg_read_enabled)
            if [ "$cur" = "on" ]; then
                printf 'off' > "$BG_ENABLED_FILE"
                bg_remove_all
            else
                printf 'on' > "$BG_ENABLED_FILE"
                bg_apply_all
            fi
            ;;
        refresh)
            cur=$(bg_read_enabled)
            [ "$cur" = "on" ] && bg_apply_all
            ;;
        add)
            [ -z "$pkg" ] && json_error '400 Bad Request' 'missing package name'
            case "$pkg" in
                *[!a-zA-Z0-9._]*) json_error '400 Bad Request' 'invalid package name' ;;
            esac
            if grep -qxF "$pkg" "$BG_LIST_FILE" 2>/dev/null; then
                json_error '400 Bad Request' 'package already in list'
            fi
            printf '%s\n' "$pkg" >> "$BG_LIST_FILE"
            cur=$(bg_read_enabled)
            [ "$cur" = "on" ] && bg_apply_restrict "$pkg"
            ;;
        remove)
            [ -z "$pkg" ] && json_error '400 Bad Request' 'missing package name'
            if [ -s "$BG_LIST_FILE" ]; then
                grep -vxF "$pkg" "$BG_LIST_FILE" > "${BG_LIST_FILE}.tmp" 2>/dev/null
                mv "${BG_LIST_FILE}.tmp" "$BG_LIST_FILE"
            fi
            bg_remove_restrict "$pkg"
            ;;
        *)
            json_error '400 Bad Request' 'unknown action (toggle/refresh/add/remove)'
            ;;
    esac

    json_headers
    printf '{"ok":true,'
    emit_state
    printf '}\n'
else
    json_error '405 Method Not Allowed' 'GET or POST'
fi
