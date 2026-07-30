#!/system/bin/sh
# GET returns the configured restrictions and verified runtime state. POST
# applies one locked transaction and reports failure instead of committing a
# list/state change that the Android framework did not accept.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback
[ -r "$MODDIR/scripts/bg_restrict_lib.sh" ] && . "$MODDIR/scripts/bg_restrict_lib.sh" \
    || json_error '500 Internal Server Error' 'background restriction library not found'
[ -r "$MODDIR/scripts/app_identity_lib.sh" ] && . "$MODDIR/scripts/app_identity_lib.sh" \
    || json_error '500 Internal Server Error' 'app identity library not found'

BG_ENABLED_FILE="$MODDIR/.bg_restrict_enabled"
BG_LIST_FILE="$MODDIR/.bg_restrict_list"
BG_BASELINE_FILE="$MODDIR/.bg_restrict_baseline"
BG_STOP_STATE_FILE="$MODDIR/.bg_restrict_stop_state"

read_stop_state() {
    _stop_since=0
    _stop_done=0
    [ -s "$BG_STOP_STATE_FILE" ] || return 0
    _stop_line=$(awk -F'|' -v p="$1" '$1 == p { print; exit }' "$BG_STOP_STATE_FILE" 2>/dev/null)
    [ -n "$_stop_line" ] || return 0
    _old_ifs="$IFS"
    IFS='|'
    set -- $_stop_line
    IFS="$_old_ifs"
    case "$2" in
        ''|*[!0-9]*) ;;
        *) _stop_since="$2" ;;
    esac
    [ "$3" = "1" ] && _stop_done=1
}

read_package_stopped() {
    _package_stopped=$(dumpsys package "$1" 2>/dev/null \
        | sed -n 's/.*stopped=\([^ ]*\).*/\1/p' \
        | head -n 1)
    case "$_package_stopped" in
        true|false) ;;
        *) _package_stopped="unknown" ;;
    esac
}

emit_pkg_status() {
    bg_parse_entry "$1"
    _pkg="$_bg_pkg"
    _policy="$_bg_policy"
    _delay="$_bg_delay"
    _bucket=$(bg_read_standby_bucket "$_pkg")
    _op_bg=$(bg_read_appop_mode "$_pkg" RUN_IN_BACKGROUND) || _op_bg="unknown"
    _op_any=$(bg_read_appop_mode "$_pkg" RUN_ANY_IN_BACKGROUND) || _op_any="unknown"
    read_stop_state "$_pkg"
    read_package_stopped "$_pkg"
    app_identity_load_package "$_pkg" >/dev/null 2>&1 || true

    _stop_state="not_applicable"
    if [ "$_policy" = "stop_after_leave" ]; then
        if [ "$_stop_since" -gt 0 ] 2>/dev/null; then
            if [ "$_stop_done" -eq 1 ]; then
                if [ "$_package_stopped" = "true" ]; then
                    _stop_state="force_stopped"
                else
                    _stop_state="relaunched"
                fi
            else
                _stop_state="pending"
            fi
        else
            _stop_state="untracked"
        fi
    fi

    _stop_since_json="null"
    [ "$_stop_since" -gt 0 ] 2>/dev/null && _stop_since_json="$_stop_since"
    _stop_done_json="false"
    [ "$_stop_done" -eq 1 ] && _stop_done_json="true"
    _package_stopped_json="null"
    case "$_package_stopped" in
        true|false) _package_stopped_json="$_package_stopped" ;;
    esac

    printf '{"pkg":"%s","label":"%s","category":"%s","restriction_tier":"%s",' \
        "$(json_escape "$_pkg")" "$(json_escape "$_identity_label")" \
        "$(json_escape "$_identity_category")" "$_identity_restriction_tier"
    printf '"policy":"%s","delay":"%s","bucket":"%s","appops":"%s","op_bg":"%s","op_any":"%s",' \
        "$_policy" "$_delay" "$(json_escape "$_bucket")" "$_op_any" "$_op_bg" "$_op_any"
    printf '"stop_since":%s,"stop_done":%s,"package_stopped":%s,"stop_state":"%s"}' \
        "$_stop_since_json" "$_stop_done_json" "$_package_stopped_json" "$_stop_state"
}

emit_identity_suggestions() {
    printf '"identity_source":"config/app_identities.tsv","suggestions":['
    if [ -s "$APP_IDENTITY_FILE" ]; then
        _installed_packages="|$(pm list packages 2>/dev/null | sed 's/^package://; s/$/|/' | tr -d '\r\n')"
        awk -F'[|]' -v installed="$_installed_packages" '
            BEGIN { first=1 }
            function esc(value) {
                gsub(/\\/, "\\\\", value)
                gsub(/"/, "\\\"", value)
                return value
            }
            $0 !~ /^#/ && $1 == "package" && ($5 == "normal" || $5 == "caution") {
                if (index(installed, "|" $2 "|") == 0) next
                if (!first) printf ","
                first=0
                printf "{\"pkg\":\"%s\",\"label\":\"%s\",\"category\":\"%s\",\"restriction_tier\":\"%s\"}", \
                    esc($2), esc($3), esc($4), esc($5)
            }
        ' "$APP_IDENTITY_FILE"
    fi
    printf ']'
}

delete_pkg_line() {
    _pkg="$1"
    [ -s "$BG_LIST_FILE" ] || return 0
    [ ! -d "$BG_LIST_FILE" ] || return 1
    _bg_cgi_tmp="${BG_LIST_FILE}.tmp.$$"
    if awk -F'|' -v p="$_pkg" '{ k=$1; gsub(/[ \t\r]/, "", k); if (k != p) print }' "$BG_LIST_FILE" > "$_bg_cgi_tmp" 2>/dev/null \
        && mv "$_bg_cgi_tmp" "$BG_LIST_FILE" 2>/dev/null \
        && [ -f "$BG_LIST_FILE" ]; then
        return 0
    fi
    rm -f "$_bg_cgi_tmp" 2>/dev/null
    return 1
}

delete_stop_state() {
    _pkg="$1"
    [ -s "$BG_STOP_STATE_FILE" ] || return 0
    [ ! -d "$BG_STOP_STATE_FILE" ] || return 1
    _bg_cgi_tmp="${BG_STOP_STATE_FILE}.tmp.$$"
    if awk -F'|' -v p="$_pkg" '{ k=$1; gsub(/[ \t\r]/, "", k); if (k != p) print }' "$BG_STOP_STATE_FILE" > "$_bg_cgi_tmp" 2>/dev/null \
        && mv "$_bg_cgi_tmp" "$BG_STOP_STATE_FILE" 2>/dev/null \
        && [ -f "$BG_STOP_STATE_FILE" ]; then
        return 0
    fi
    rm -f "$_bg_cgi_tmp" 2>/dev/null
    return 1
}

clear_stop_state_file() {
    [ -e "$BG_STOP_STATE_FILE" ] || return 0
    [ ! -d "$BG_STOP_STATE_FILE" ] || return 1
    rm -f "$BG_STOP_STATE_FILE" 2>/dev/null && [ ! -e "$BG_STOP_STATE_FILE" ]
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
    mkdir -p "${BG_LIST_FILE%/*}" 2>/dev/null || return 1
    [ ! -d "$BG_LIST_FILE" ] || return 1
    _bg_cgi_tmp="${BG_LIST_FILE}.tmp.$$"
    if {
        [ ! -s "$BG_LIST_FILE" ] || awk -F'|' -v p="$_pkg" '{ k=$1; gsub(/[ \t\r]/, "", k); if (k != p) print }' "$BG_LIST_FILE"
        bg_format_entry "$_pkg" "$_policy" "$_delay"
    } > "$_bg_cgi_tmp" 2>/dev/null \
        && mv "$_bg_cgi_tmp" "$BG_LIST_FILE" 2>/dev/null \
        && [ -f "$BG_LIST_FILE" ]; then
        return 0
    fi
    rm -f "$_bg_cgi_tmp" 2>/dev/null
    return 1
}

validate_pkg_policy_request() {
    bg_is_valid_policy "$1" \
        || json_error '400 Bad Request' 'invalid background policy'
    bg_is_valid_delay "$2" \
        || json_error '400 Bad Request' 'invalid background delay'
}

validate_package_name() {
    case "$1" in
        ''|.*|*.|*..*|*[!a-zA-Z0-9._]*) json_error '400 Bad Request' 'invalid package name' ;;
    esac
}

emit_state() {
    _enabled=$(bg_read_enabled)
    printf '"enabled":"%s","bg_contract":' "$_enabled"
    bg_print_ui_contract_json
    printf ',"packages":['
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
    printf '],'
    emit_identity_suggestions
}

if [ "$REQUEST_METHOD" = "GET" ]; then
    json_headers
    printf '{'
    emit_state
    printf '}\n'

elif [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "bg_restrict"
    read_json_body 1024
    body="$JSON_BODY"

    action=$(printf '%s' "$body" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')
    pkg=$(printf '%s' "$body" | sed -n 's/.*"package"[[:space:]]*:[[:space:]]*"\([a-zA-Z0-9._]*\)".*/\1/p')
    policy=$(printf '%s' "$body" | sed -n 's/.*"policy"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')
    delay=$(printf '%s' "$body" | sed -n 's/.*"delay"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')

    case "$action" in
        toggle)
            cur=$(bg_read_enabled)
            if [ "$cur" = "on" ]; then
                bg_remove_all || json_error '500 Internal Server Error' 'failed to restore one or more app restrictions'
                if ! cgi_atomic_write "$BG_ENABLED_FILE" off; then
                    if bg_apply_all >/dev/null 2>&1; then
                        json_error '500 Internal Server Error' 'failed to persist background restriction state; restrictions restored'
                    fi
                    json_error '500 Internal Server Error' 'failed to persist background restriction state and rollback was incomplete'
                fi
                if ! clear_stop_state_file; then
                    if cgi_atomic_write "$BG_ENABLED_FILE" on >/dev/null 2>&1 \
                        && bg_apply_all >/dev/null 2>&1; then
                        json_error '500 Internal Server Error' 'failed to clear background timers; restrictions restored'
                    fi
                    json_error '500 Internal Server Error' 'failed to clear background timers and rollback was incomplete'
                fi
            else
                clear_stop_state_file \
                    || json_error '500 Internal Server Error' 'failed to clear background timers'
                if ! bg_apply_all; then
                    if bg_remove_all >/dev/null 2>&1; then
                        json_error '500 Internal Server Error' 'failed to apply one or more app restrictions; previous state restored'
                    fi
                    json_error '500 Internal Server Error' 'failed to apply restrictions and rollback was incomplete'
                fi
                if ! cgi_atomic_write "$BG_ENABLED_FILE" on; then
                    if bg_remove_all >/dev/null 2>&1; then
                        json_error '500 Internal Server Error' 'failed to persist background restriction state; previous state restored'
                    fi
                    json_error '500 Internal Server Error' 'failed to persist background restriction state and rollback was incomplete'
                fi
            fi
            ;;
        refresh)
            cur=$(bg_read_enabled)
            if [ "$cur" = "on" ]; then
                bg_apply_all || json_error '500 Internal Server Error' 'failed to refresh one or more app restrictions'
            fi
            ;;
        add)
            validate_package_name "$pkg"
            validate_pkg_policy_request "$policy" "$delay"
            if pkg_exists "$pkg"; then
                json_error '400 Bad Request' 'package already in list'
            fi
            write_pkg_entry "$pkg" "$policy" "$delay" \
                || json_error '500 Internal Server Error' 'failed to persist package entry'
            if ! delete_stop_state "$pkg"; then
                if delete_pkg_line "$pkg" >/dev/null 2>&1; then
                    json_error '500 Internal Server Error' 'failed to clear stale package timer; package entry removed'
                fi
                json_error '500 Internal Server Error' 'failed to clear stale package timer and rollback was incomplete'
            fi
            cur=$(bg_read_enabled)
            if [ "$cur" = "on" ] && ! bg_apply_policy "$pkg" "$policy"; then
                if delete_pkg_line "$pkg" >/dev/null 2>&1 \
                    && bg_remove_restrict "$pkg" >/dev/null 2>&1; then
                    json_error '500 Internal Server Error' 'failed to apply package restriction; package entry removed'
                fi
                json_error '500 Internal Server Error' 'failed to apply package restriction and rollback was incomplete'
            fi
            ;;
        update)
            validate_package_name "$pkg"
            validate_pkg_policy_request "$policy" "$delay"
            pkg_exists "$pkg" || json_error '400 Bad Request' 'package not in list'
            _old_entry=$(awk -F'|' -v p="$pkg" '$1 == p { print; exit }' "$BG_LIST_FILE" 2>/dev/null)
            bg_parse_entry "$_old_entry"
            _old_policy="$_bg_policy"
            _old_delay="$_bg_delay"
            write_pkg_entry "$pkg" "$policy" "$delay" \
                || json_error '500 Internal Server Error' 'failed to persist package entry'
            if ! delete_stop_state "$pkg"; then
                if write_pkg_entry "$pkg" "$_old_policy" "$_old_delay" >/dev/null 2>&1; then
                    json_error '500 Internal Server Error' 'failed to clear stale package timer; previous entry restored'
                fi
                json_error '500 Internal Server Error' 'failed to clear stale package timer and rollback was incomplete'
            fi
            cur=$(bg_read_enabled)
            if [ "$cur" = "on" ] && ! bg_apply_policy "$pkg" "$policy"; then
                if write_pkg_entry "$pkg" "$_old_policy" "$_old_delay" >/dev/null 2>&1 \
                    && bg_apply_policy "$pkg" "$_old_policy" >/dev/null 2>&1; then
                    json_error '500 Internal Server Error' 'failed to update package restriction; previous policy restored'
                fi
                json_error '500 Internal Server Error' 'failed to update package restriction and rollback was incomplete'
            fi
            ;;
        remove)
            validate_package_name "$pkg"
            _old_entry=$(awk -F'|' -v p="$pkg" '$1 == p { print; exit }' "$BG_LIST_FILE" 2>/dev/null)
            bg_parse_entry "$_old_entry"
            _old_policy="$_bg_policy"
            _old_delay="$_bg_delay"
            bg_remove_restrict "$pkg" \
                || json_error '500 Internal Server Error' 'failed to restore package baseline'
            if ! delete_pkg_line "$pkg"; then
                if bg_apply_policy "$pkg" "$_old_policy" >/dev/null 2>&1; then
                    json_error '500 Internal Server Error' 'failed to remove package entry; restriction reapplied'
                fi
                json_error '500 Internal Server Error' 'failed to remove package entry and rollback was incomplete'
            fi
            if ! delete_stop_state "$pkg"; then
                if write_pkg_entry "$pkg" "$_old_policy" "$_old_delay" >/dev/null 2>&1 \
                    && bg_apply_policy "$pkg" "$_old_policy" >/dev/null 2>&1; then
                    json_error '500 Internal Server Error' 'failed to clear package timer; package entry and restriction restored'
                fi
                json_error '500 Internal Server Error' 'failed to clear package timer and rollback was incomplete'
            fi
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
