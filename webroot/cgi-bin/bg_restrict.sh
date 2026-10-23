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
. "$MODDIR/scripts/bg_transaction_lib.sh" \
    || json_error '500 Internal Server Error' 'background transaction library not found'

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
    case "$3" in 1|2) _stop_done="$3" ;; esac
    [ "$4" = "$(cat /proc/sys/kernel/random/boot_id)" ] || { _stop_since=0; _stop_done=0; }
}

read_package_stopped() {
    _package_stopped=$(bg_package_stopped "$1")
    case "$_package_stopped" in true|false) ;; *) _package_stopped=unknown ;; esac
}
emit_pkg_status() {
    bg_parse_entry "$1"
    _pkg="$_bg_pkg"
    _policy="$_bg_policy"
    _delay="$_bg_delay"
    _bucket=unknown; _op_bg=unknown; _op_any=unknown; _observed_at=0; _observed_boot=''; _observed_pkg=''
    _observed_row=$(awk -F'|' -v pkg="$_pkg" '$1==pkg {print; exit}' "$MODDIR/.bg_restrict_observed" 2>/dev/null)
    IFS='|' read -r _observed_pkg _observed_bucket _observed_bg _observed_any _observed_boot _observed_at <<EOF
$_observed_row
EOF
    _runtime_freshness=unknown
    if [ "$_observed_pkg" = "$_pkg" ] && [ "$_observed_boot" = "$(cat /proc/sys/kernel/random/boot_id)" ]; then
        _bucket="$_observed_bucket"; _op_bg="$_observed_bg"; _op_any="$_observed_any"
        _runtime_freshness=last_verified
    fi
    case "$_observed_at" in ''|*[!0-9]*) _observed_at=0 ;; esac
    read_stop_state "$_pkg"
    # A stored stop receipt is historical. Current process state is not
    # inferred from it, and automatic GET never runs a per-package dumpsys.
    _package_stopped=unknown
    app_identity_load_package "$_pkg" >/dev/null 2>&1 || true

    _stop_state="not_applicable"
    if [ "$_policy" = "stop_after_leave" ]; then
        if [ "$_stop_since" -gt 0 ] 2>/dev/null; then
            if [ "$_stop_done" -eq 2 ]; then
                _stop_state=failed
            elif [ "$_stop_done" -eq 1 ]; then
                _stop_state=last_verified_stopped
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
    printf '"runtime_freshness":"%s","observed_at":%s,' "$_runtime_freshness" "$_observed_at"
    printf '"policy":"%s","delay":"%s","bucket":"%s","appops":"%s","op_bg":"%s","op_any":"%s",' \
        "$_policy" "$_delay" "$(json_escape "$_bucket")" "$_op_any" "$_op_bg" "$_op_any"
    printf '"stop_since":%s,"stop_done":%s,"package_stopped":%s,"stop_state":"%s"}' \
        "$_stop_since_json" "$_stop_done_json" "$_package_stopped_json" "$_stop_state"
}

emit_identity_suggestions() {
    printf '"identity_source":"config/app_identities.tsv","suggestions":['
    if [ -s "$APP_IDENTITY_FILE" ]; then
        _installed_packages="|$(cat "$MODDIR/.bg_installed_packages" 2>/dev/null | sed 's/^package://; s/$/|/' | tr -d '\r\n')"
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
    bg_table_replace "$BG_LIST_FILE" "$1"
}
delete_stop_state() {
    bg_table_replace "$BG_STOP_STATE_FILE" "$1"
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
    bg_table_replace "$BG_LIST_FILE" "$_pkg" "$(bg_format_entry "$_pkg" "$_policy" "$_delay")"
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
    _bg_recovery_required=false
    [ ! -d "$MODDIR/.bg_policy_tx" ] || _bg_recovery_required=true
    printf ',"recovery_required":%s,"policy_user_id":%s' "$_bg_recovery_required" "$BG_USER_ID"
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
    . "$MODDIR/scripts/state_io_lib.sh" || json_error '500 Internal Server Error' 'state I/O unavailable'
    state_lock_acquire "$MODDIR/.locks/bg_policy.lock" 2 || json_error '409 Conflict' 'background policy changing; retry later'
    trap 'state_lock_release "$MODDIR/.locks/bg_policy.lock" >/dev/null 2>&1' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    json_headers
    printf '{'
    emit_state
    printf '}\n'

elif [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "bg_restrict"
    . "$MODDIR/scripts/state_io_lib.sh" || json_error '500 Internal Server Error' 'state I/O unavailable'
    state_lock_acquire "$MODDIR/.locks/bg_policy.lock" 10 || json_error '409 Conflict' 'background policy busy'
    trap 'bg_tx_rollback >/dev/null 2>&1; state_lock_release "$MODDIR/.locks/bg_policy.lock" >/dev/null 2>&1; release_lock' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    read_json_body 1024
    body="$JSON_BODY"

    cgi_json_schema 'action:string package:string policy:string delay:number'
    action=$(cgi_json_field action)
    pkg=$(cgi_json_field package)
    policy=$(cgi_json_field policy)
    delay=$(cgi_json_field delay)
    case "$action" in add|update|remove) validate_package_name "$pkg" ;; toggle|refresh|recover) ;;
        *) json_error '400 Bad Request' 'unknown background action' ;; esac
    if [ "$action" = recover ]; then
        bg_tx_recover || json_error '500 Internal Server Error' 'background recovery incomplete; journal retained'
    else
        bg_tx_begin "$action" "$pkg" || json_error '409 Conflict' 'background state cannot be snapshotted, or an interrupted transaction requires recovery'
    fi

    case "$action" in
        recover) ;;
        toggle)
            if [ "$(bg_read_enabled)" = on ]; then
                bg_remove_all || json_error '500 Internal Server Error' 'one or more app baselines could not be restored'
                cgi_atomic_write "$BG_ENABLED_FILE" off \
                    && clear_stop_state_file || json_error '500 Internal Server Error' 'cannot save disabled background policy'
            else
                clear_stop_state_file && bg_apply_all \
                    && cgi_atomic_write "$BG_ENABLED_FILE" on \
                    || json_error '500 Internal Server Error' 'cannot apply and save background policy'
            fi
            ;;
        refresh)
            [ "$(bg_read_enabled)" != on ] || bg_apply_all \
                || json_error '500 Internal Server Error' 'one or more app policies could not be applied'
            ;;
        add|update)
            validate_pkg_policy_request "$policy" "$delay"
            if [ "$action" = add ]; then
                pkg_exists "$pkg" && json_error '400 Bad Request' 'package already in list'
                _bg_count=$(awk -F'|' '$0 !~ /^#/ && $1!="" {n++} END {print n+0}' "$BG_LIST_FILE" 2>/dev/null) || _bg_count=0
                [ "$_bg_count" -lt "$BG_MAX_PACKAGES" ] || json_error '409 Conflict' 'background policy list is full (32 owner-user packages)'
            else
                pkg_exists "$pkg" || json_error '400 Bad Request' 'package not in list'
            fi
            write_pkg_entry "$pkg" "$policy" "$delay" && delete_stop_state "$pkg" \
                || json_error '500 Internal Server Error' 'cannot save package policy'
            [ "$(bg_read_enabled)" != on ] || bg_apply_policy "$pkg" "$policy" \
                || json_error '500 Internal Server Error' 'cannot apply package policy'
            ;;
        remove)
            pkg_exists "$pkg" || json_error '400 Bad Request' 'package not in list'
            if [ "$(bg_read_enabled)" = on ]; then
                bg_package_presence "$pkg"
                _bg_presence=$?
                case "$_bg_presence" in
                    0) bg_remove_restrict "$pkg" || json_error '500 Internal Server Error' 'cannot restore package baseline' ;;
                    1) bg_delete_baseline "$pkg" || json_error '500 Internal Server Error' 'cannot remove uninstalled package baseline' ;;
                    *) json_error '503 Service Unavailable' 'package presence is unreadable' ;;
                esac
            fi
            delete_pkg_line "$pkg" && delete_stop_state "$pkg" \
                || json_error '500 Internal Server Error' 'cannot remove package policy'
            ;;
        *) json_error '400 Bad Request' 'unknown background action' ;;
    esac

    [ "$action" = recover ] || bg_tx_commit || json_error '500 Internal Server Error' 'background transaction commit failed'
    json_headers
    printf '{"ok":true,'
    # Mutation completion cannot depend on a per-package Binder/pm scan.
    printf '"committed":true,"enabled":"%s","action":"%s"' "$(bg_read_enabled)" "$action"
    printf '}\n'
else
    json_error '405 Method Not Allowed' 'GET or POST'
fi
