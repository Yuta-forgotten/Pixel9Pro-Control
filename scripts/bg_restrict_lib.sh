#!/system/bin/sh
##############################################################
# Background restriction helpers shared by service.sh and CGI
##############################################################

BG_ENABLED_FILE="${BG_ENABLED_FILE:-$MODDIR/.bg_restrict_enabled}"
BG_LIST_FILE="${BG_LIST_FILE:-$MODDIR/.bg_restrict_list}"
BG_BASELINE_FILE="${BG_BASELINE_FILE:-$MODDIR/.bg_restrict_baseline}"
BG_STOP_STATE_FILE="${BG_STOP_STATE_FILE:-$MODDIR/.bg_restrict_stop_state}"

bg_read_enabled() {
    _v=$(cat "$BG_ENABLED_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_v" in on|off) printf '%s' "$_v" ;; *) printf 'on' ;; esac
}

bg_read_standby_bucket() {
    am get-standby-bucket "$1" 2>/dev/null | tr -d ' \n\r\t'
}

bg_read_appop_mode() {
    _pkg="$1"
    _op="$2"
    _out=$(cmd appops get "$_pkg" "$_op" 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')
    case "$_out" in
        *ignore*) printf 'ignore' ;;
        *deny*) printf 'deny' ;;
        *foreground*) printf 'foreground' ;;
        *allow*) printf 'allow' ;;
        *default*|*"no operations"*) printf 'default' ;;
        *) printf 'default' ;;
    esac
}

bg_normalize_policy() {
    case "$1" in
        bucket|block_services|block_all|stop_after_leave) printf '%s' "$1" ;;
        reduce|rare) printf 'bucket' ;;
        services) printf 'block_services' ;;
        strict|restricted|'') printf 'block_all' ;;
        stop|force_stop) printf 'stop_after_leave' ;;
        *) printf 'block_all' ;;
    esac
}

bg_normalize_delay() {
    case "$1" in
        3|5|10) printf '%s' "$1" ;;
        *) printf '5' ;;
    esac
}

bg_parse_entry() {
    _bg_raw=$(printf '%s' "$1" | tr -d ' \n\r\t')
    _bg_pkg="${_bg_raw%%|*}"
    _bg_policy="block_all"
    _bg_delay="5"
    if [ "$_bg_raw" != "$_bg_pkg" ]; then
        _bg_rest="${_bg_raw#*|}"
        _bg_policy="${_bg_rest%%|*}"
        if [ "$_bg_rest" != "$_bg_policy" ]; then
            _bg_delay="${_bg_rest#*|}"
            case "$_bg_delay" in *'|'*) _bg_delay="${_bg_delay%%|*}" ;; esac
        fi
    fi
    _bg_policy=$(bg_normalize_policy "$_bg_policy")
    _bg_delay=$(bg_normalize_delay "$_bg_delay")
}

bg_format_entry() {
    _pkg="$1"
    _policy=$(bg_normalize_policy "$2")
    _delay=$(bg_normalize_delay "$3")
    printf '%s|%s|%s\n' "$_pkg" "$_policy" "$_delay"
}

bg_bucket_to_set_arg() {
    case "$1" in
        5|exempted) printf 'exempted' ;;
        10|active) printf 'active' ;;
        20|working_set) printf 'working_set' ;;
        30|frequent) printf 'frequent' ;;
        40|rare) printf 'rare' ;;
        45|restricted) printf 'restricted' ;;
        50|never) printf 'never' ;;
        *) printf '' ;;
    esac
}

bg_set_appop_mode() {
    _pkg="$1"
    _op="$2"
    _mode="$3"
    case "$_mode" in
        allow|ignore|deny|default|foreground)
            cmd appops set "$_pkg" "$_op" "$_mode" 2>/dev/null
            ;;
    esac
}

bg_baseline_line() {
    [ -s "$BG_BASELINE_FILE" ] || return 1
    awk -F'|' -v p="$1" '$1 == p { print; exit }' "$BG_BASELINE_FILE" 2>/dev/null
}

bg_delete_baseline() {
    _pkg="$1"
    [ -s "$BG_BASELINE_FILE" ] || return 0
    awk -F'|' -v p="$_pkg" '$1 != p' "$BG_BASELINE_FILE" > "${BG_BASELINE_FILE}.tmp" 2>/dev/null \
        && mv "${BG_BASELINE_FILE}.tmp" "$BG_BASELINE_FILE" 2>/dev/null
}

bg_record_baseline() {
    _pkg="$1"
    case "$_pkg" in ''|*[!a-zA-Z0-9._]*) return 1 ;; esac
    bg_baseline_line "$_pkg" >/dev/null 2>&1 && return 0

    _bucket=$(bg_read_standby_bucket "$_pkg")
    _op_bg=$(bg_read_appop_mode "$_pkg" RUN_IN_BACKGROUND)
    _op_any=$(bg_read_appop_mode "$_pkg" RUN_ANY_IN_BACKGROUND)

    # If this package is already at the module target and no baseline exists,
    # it is most likely a pre-v4.4.6 restriction. Do not snapshot the restricted
    # state as its own restore target.
    case "$_bucket" in
        45|restricted)
            if [ "$_op_bg" = "ignore" ] && [ "$_op_any" = "ignore" ]; then
                return 0
            fi
            ;;
    esac

    [ -n "$_bucket" ] || _bucket="unknown"
    mkdir -p "${BG_BASELINE_FILE%/*}" 2>/dev/null
    printf '%s|%s|%s|%s\n' "$_pkg" "$_bucket" "$_op_bg" "$_op_any" >> "$BG_BASELINE_FILE" 2>/dev/null
}

bg_restore_baseline() {
    _pkg="$1"
    _line=$(bg_baseline_line "$_pkg")
    if [ -n "$_line" ]; then
        _old_ifs="$IFS"
        IFS='|'
        set -- $_line
        IFS="$_old_ifs"
        _bucket_arg=$(bg_bucket_to_set_arg "$2")
        [ -n "$_bucket_arg" ] && am set-standby-bucket "$_pkg" "$_bucket_arg" 2>/dev/null
        bg_set_appop_mode "$_pkg" RUN_IN_BACKGROUND "$3"
        bg_set_appop_mode "$_pkg" RUN_ANY_IN_BACKGROUND "$4"
        bg_delete_baseline "$_pkg"
        return 0
    fi

    # Legacy fallback for packages restricted before baseline tracking existed.
    am set-standby-bucket "$_pkg" active 2>/dev/null
    cmd appops set "$_pkg" RUN_IN_BACKGROUND allow 2>/dev/null
    cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND allow 2>/dev/null
}

bg_restore_appops_from_baseline() {
    _pkg="$1"
    _line=$(bg_baseline_line "$_pkg")
    if [ -n "$_line" ]; then
        _old_ifs="$IFS"
        IFS='|'
        set -- $_line
        IFS="$_old_ifs"
        bg_set_appop_mode "$_pkg" RUN_IN_BACKGROUND "$3"
        bg_set_appop_mode "$_pkg" RUN_ANY_IN_BACKGROUND "$4"
        return 0
    fi
    cmd appops set "$_pkg" RUN_IN_BACKGROUND allow 2>/dev/null
    cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND allow 2>/dev/null
}

bg_restore_run_any_from_baseline() {
    _pkg="$1"
    _line=$(bg_baseline_line "$_pkg")
    if [ -n "$_line" ]; then
        _old_ifs="$IFS"
        IFS='|'
        set -- $_line
        IFS="$_old_ifs"
        bg_set_appop_mode "$_pkg" RUN_ANY_IN_BACKGROUND "$4"
        return 0
    fi
    cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND allow 2>/dev/null
}

bg_apply_restrict() {
    _pkg="$1"
    bg_record_baseline "$_pkg"
    am set-standby-bucket "$_pkg" restricted 2>/dev/null
    cmd appops set "$_pkg" RUN_IN_BACKGROUND ignore 2>/dev/null
    cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND ignore 2>/dev/null
}

bg_apply_policy() {
    _pkg="$1"
    _policy=$(bg_normalize_policy "$2")
    case "$_pkg" in ''|*[!a-zA-Z0-9._]*) return 1 ;; esac
    bg_record_baseline "$_pkg"
    case "$_policy" in
        bucket)
            am set-standby-bucket "$_pkg" rare 2>/dev/null
            bg_restore_appops_from_baseline "$_pkg"
            ;;
        block_services)
            am set-standby-bucket "$_pkg" restricted 2>/dev/null
            cmd appops set "$_pkg" RUN_IN_BACKGROUND ignore 2>/dev/null
            bg_restore_run_any_from_baseline "$_pkg"
            ;;
        block_all|stop_after_leave|*)
            bg_apply_restrict "$_pkg"
            ;;
    esac
}

bg_apply_entry() {
    bg_parse_entry "$1"
    [ -z "$_bg_pkg" ] && return 0
    case "$_bg_pkg" in \#*) return 0 ;; esac
    bg_apply_policy "$_bg_pkg" "$_bg_policy"
}

bg_remove_restrict() {
    _pkg="$1"
    bg_restore_baseline "$_pkg"
}

bg_apply_all() {
    [ -s "$BG_LIST_FILE" ] || return
    while IFS= read -r _line || [ -n "$_line" ]; do
        bg_apply_entry "$_line"
    done < "$BG_LIST_FILE"
}

bg_remove_all() {
    [ -s "$BG_LIST_FILE" ] || return
    while IFS= read -r _line || [ -n "$_line" ]; do
        bg_parse_entry "$_line"
        [ -z "$_bg_pkg" ] && continue
        case "$_bg_pkg" in \#*) continue ;; esac
        bg_remove_restrict "$_bg_pkg"
    done < "$BG_LIST_FILE"
}
