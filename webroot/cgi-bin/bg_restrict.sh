#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/bg_restrict.sh
# GET  -> 返回后台限制开关状态 + 包名列表 + 各包当前 bucket/appops
# POST -> 开关切换 / 添加包名 / 更新策略 / 移除包名
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
. "$MODDIR/scripts/bg_restrict_lib.sh"

BG_ENABLED_FILE="$MODDIR/.bg_restrict_enabled"
BG_LIST_FILE="$MODDIR/.bg_restrict_list"
BG_BASELINE_FILE="$MODDIR/.bg_restrict_baseline"
BG_STOP_STATE_FILE="$MODDIR/.bg_restrict_stop_state"

emit_pkg_status() {
    bg_parse_entry "$1"
    _pkg="$_bg_pkg"
    _policy="$_bg_policy"
    _delay="$_bg_delay"
    _bucket=$(bg_read_standby_bucket "$_pkg")
    _op_bg=$(bg_read_appop_mode "$_pkg" RUN_IN_BACKGROUND)
    _op_any=$(bg_read_appop_mode "$_pkg" RUN_ANY_IN_BACKGROUND)
    printf '{"pkg":"%s","policy":"%s","delay":"%s","bucket":"%s","appops":"%s","op_bg":"%s","op_any":"%s"}' \
        "$(json_escape "$_pkg")" "$_policy" "$_delay" "$(json_escape "$_bucket")" "$_op_any" "$_op_bg" "$_op_any"
}

delete_pkg_line() {
    _pkg="$1"
    [ -s "$BG_LIST_FILE" ] || return 0
    awk -F'|' -v p="$_pkg" '{ k=$1; gsub(/[ \t\r]/, "", k); if (k != p) print }' "$BG_LIST_FILE" > "${BG_LIST_FILE}.tmp" 2>/dev/null \
        && mv "${BG_LIST_FILE}.tmp" "$BG_LIST_FILE" 2>/dev/null
}

delete_stop_state() {
    _pkg="$1"
    [ -s "$BG_STOP_STATE_FILE" ] || return 0
    awk -F'|' -v p="$_pkg" '{ k=$1; gsub(/[ \t\r]/, "", k); if (k != p) print }' "$BG_STOP_STATE_FILE" > "${BG_STOP_STATE_FILE}.tmp" 2>/dev/null \
        && mv "${BG_STOP_STATE_FILE}.tmp" "$BG_STOP_STATE_FILE" 2>/dev/null
}

pkg_exists() {
    _pkg="$1"
    [ -s "$BG_LIST_FILE" ] || return 1
    awk -F'|' -v p="$_pkg" '{ k=$1; gsub(/[ \t\r]/, "", k); if (k == p) { found=1; exit } } END { exit found ? 0 : 1 }' "$BG_LIST_FILE" 2>/dev/null
}

write_pkg_entry() {
    _pkg="$1"
    _policy=$(bg_normalize_policy "$2")
    _delay=$(bg_normalize_delay "$3")
    mkdir -p "${BG_LIST_FILE%/*}" 2>/dev/null
    delete_pkg_line "$_pkg"
    bg_format_entry "$_pkg" "$_policy" "$_delay" >> "$BG_LIST_FILE"
}

emit_state() {
    _enabled=$(bg_read_enabled)
    printf '"enabled":"%s","packages":[' "$_enabled"
    _first=1
    if [ -s "$BG_LIST_FILE" ]; then
        while IFS= read -r _line || [ -n "$_line" ]; do
            bg_parse_entry "$_line"
            [ -z "$_bg_pkg" ] && continue
            case "$_bg_pkg" in \#*) continue ;; esac
            [ "$_first" -eq 1 ] && _first=0 || printf ','
            emit_pkg_status "$_line"
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
    policy=$(printf '%s' "$body" | sed -n 's/.*"policy"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')
    delay=$(printf '%s' "$body" | sed -n 's/.*"delay"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
    policy=$(bg_normalize_policy "$policy")
    delay=$(bg_normalize_delay "$delay")

    case "$action" in
        toggle)
            cur=$(bg_read_enabled)
            if [ "$cur" = "on" ]; then
                printf 'off' > "$BG_ENABLED_FILE"
                bg_remove_all
                rm -f "$BG_STOP_STATE_FILE" 2>/dev/null
            else
                printf 'on' > "$BG_ENABLED_FILE"
                rm -f "$BG_STOP_STATE_FILE" 2>/dev/null
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
            if pkg_exists "$pkg"; then
                json_error '400 Bad Request' 'package already in list'
            fi
            write_pkg_entry "$pkg" "$policy" "$delay"
            delete_stop_state "$pkg"
            cur=$(bg_read_enabled)
            [ "$cur" = "on" ] && bg_apply_policy "$pkg" "$policy"
            ;;
        update)
            [ -z "$pkg" ] && json_error '400 Bad Request' 'missing package name'
            case "$pkg" in
                *[!a-zA-Z0-9._]*) json_error '400 Bad Request' 'invalid package name' ;;
            esac
            pkg_exists "$pkg" || json_error '400 Bad Request' 'package not in list'
            write_pkg_entry "$pkg" "$policy" "$delay"
            delete_stop_state "$pkg"
            cur=$(bg_read_enabled)
            [ "$cur" = "on" ] && bg_apply_policy "$pkg" "$policy"
            ;;
        remove)
            [ -z "$pkg" ] && json_error '400 Bad Request' 'missing package name'
            delete_pkg_line "$pkg"
            delete_stop_state "$pkg"
            bg_remove_restrict "$pkg"
            ;;
        *)
            json_error '400 Bad Request' 'unknown action (toggle/refresh/add/update/remove)'
            ;;
    esac

    json_headers
    printf '{"ok":true,'
    emit_state
    printf '}\n'
else
    json_error '405 Method Not Allowed' 'GET or POST'
fi
