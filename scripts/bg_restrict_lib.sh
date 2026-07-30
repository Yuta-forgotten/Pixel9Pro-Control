#!/system/bin/sh
# Background-restriction transaction helpers shared by service.sh and CGI.
# A baseline is retained until every restore command succeeds and is verified.

BG_ENABLED_FILE="${BG_ENABLED_FILE:-$MODDIR/.bg_restrict_enabled}"
BG_LIST_FILE="${BG_LIST_FILE:-$MODDIR/.bg_restrict_list}"
BG_BASELINE_FILE="${BG_BASELINE_FILE:-$MODDIR/.bg_restrict_baseline}"
BG_STOP_STATE_FILE="${BG_STOP_STATE_FILE:-$MODDIR/.bg_restrict_stop_state}"
BG_POLICY_ORDER="stop_after_leave block_all block_services bucket"
BG_DEFAULT_POLICY="block_all"
BG_UI_DEFAULT_POLICY="stop_after_leave"
BG_ALLOWED_DELAYS="3 5 10"
BG_DEFAULT_DELAY=5
BG_DEFAULT_SEED_PACKAGE="com.ss.android.ugc.aweme"

bg_is_valid_policy() {
    _bg_candidate_policy="$1"
    for _bg_allowed_policy in $BG_POLICY_ORDER; do
        [ "$_bg_candidate_policy" = "$_bg_allowed_policy" ] && return 0
    done
    return 1
}

bg_is_valid_delay() {
    _bg_candidate_delay="$1"
    for _bg_allowed_delay in $BG_ALLOWED_DELAYS; do
        [ "$_bg_candidate_delay" = "$_bg_allowed_delay" ] && return 0
    done
    return 1
}

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
    _out=$(cmd appops get "$_pkg" "$_op" 2>/dev/null) || return 1
    _out=$(printf '%s' "$_out" | tr -d '\r' | tr '[:upper:]' '[:lower:]')
    case "$_out" in
        *ignore*) printf 'ignore' ;;
        *deny*) printf 'deny' ;;
        *foreground*) printf 'foreground' ;;
        *allow*) printf 'allow' ;;
        *default*|*"no operations"*) printf 'default' ;;
        *) return 1 ;;
    esac
}

bg_normalize_policy() {
    if bg_is_valid_policy "$1"; then
        printf '%s' "$1"
        return 0
    fi
    case "$1" in
        reduce|rare) printf 'bucket' ;;
        services) printf 'block_services' ;;
        strict|restricted|'') printf '%s' "$BG_DEFAULT_POLICY" ;;
        stop|force_stop) printf 'stop_after_leave' ;;
        *) printf '%s' "$BG_DEFAULT_POLICY" ;;
    esac
}

bg_normalize_delay() {
    if bg_is_valid_delay "$1"; then
        printf '%s' "$1"
    else
        printf '%s' "$BG_DEFAULT_DELAY"
    fi
}

bg_default_seed_entry() {
    bg_format_entry "$BG_DEFAULT_SEED_PACKAGE" "$BG_UI_DEFAULT_POLICY" "$BG_DEFAULT_DELAY"
}

bg_list_is_legacy_seed() {
    [ -f "$1" ] || return 1
    _bg_legacy_seed=$(sed 's/[[:space:]]//g' "$1" 2>/dev/null | sed '/^$/d')
    _bg_legacy_expected=$(printf 'com.tencent.mobileqq\ncom.tencent.qqmusic')
    [ "$_bg_legacy_seed" = "$_bg_legacy_expected" ]
}

bg_print_ui_contract_json() {
    printf '{"policy_order":['
    _bg_contract_first=1
    for _bg_contract_policy in $BG_POLICY_ORDER; do
        [ "$_bg_contract_first" -eq 1 ] && _bg_contract_first=0 || printf ','
        printf '"%s"' "$_bg_contract_policy"
    done
    printf '],"allowed_delays":['
    _bg_contract_first=1
    for _bg_contract_delay in $BG_ALLOWED_DELAYS; do
        [ "$_bg_contract_first" -eq 1 ] && _bg_contract_first=0 || printf ','
        printf '%s' "$_bg_contract_delay"
    done
    printf '],"default_policy":"%s","default_delay":%s}' \
        "$BG_UI_DEFAULT_POLICY" "$BG_DEFAULT_DELAY"
}

bg_parse_entry() {
    _bg_raw=$(printf '%s' "$1" | tr -d ' \n\r\t')
    _bg_policy="$BG_DEFAULT_POLICY"
    _bg_delay="$BG_DEFAULT_DELAY"
    case "$_bg_raw" in
        *'|'*)
            _bg_pkg=$(printf '%s' "$_bg_raw" | cut -d '|' -f 1)
            _bg_policy=$(printf '%s' "$_bg_raw" | cut -d '|' -f 2)
            _bg_delay=$(printf '%s' "$_bg_raw" | cut -d '|' -f 3)
            ;;
        *)
            _bg_pkg="$_bg_raw"
            ;;
    esac
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
        *) return 1 ;;
    esac
}

bg_bucket_matches() {
    _bg_actual=$(bg_read_standby_bucket "$1")
    case "$2:$_bg_actual" in
        exempted:5|exempted:exempted|active:10|active:active|working_set:20|working_set:working_set|frequent:30|frequent:frequent|rare:40|rare:rare|restricted:45|restricted:restricted|never:50|never:never) return 0 ;;
        *) return 1 ;;
    esac
}

bg_appop_matches() {
    _bg_actual=$(bg_read_appop_mode "$1" "$2") || return 1
    [ "$_bg_actual" = "$3" ]
}

bg_baseline_line() {
    [ -s "$BG_BASELINE_FILE" ] || return 1
    awk -F'|' -v p="$1" '$1 == p { print; exit }' "$BG_BASELINE_FILE" 2>/dev/null
}

bg_delete_baseline() {
    _pkg="$1"
    [ -s "$BG_BASELINE_FILE" ] || return 0
    [ ! -d "$BG_BASELINE_FILE" ] || return 1
    _bg_tmp="${BG_BASELINE_FILE}.tmp.$$"
    if awk -F'|' -v p="$_pkg" '$1 != p' "$BG_BASELINE_FILE" > "$_bg_tmp" 2>/dev/null \
        && mv "$_bg_tmp" "$BG_BASELINE_FILE" 2>/dev/null \
        && [ -f "$BG_BASELINE_FILE" ]; then
        return 0
    fi
    rm -f "$_bg_tmp" 2>/dev/null
    return 1
}

bg_record_baseline() {
    _pkg="$1"
    case "$_pkg" in ''|*[!a-zA-Z0-9._]*) return 1 ;; esac
    bg_baseline_line "$_pkg" >/dev/null 2>&1 && return 0

    _bucket=$(bg_read_standby_bucket "$_pkg")
    _op_bg=$(bg_read_appop_mode "$_pkg" RUN_IN_BACKGROUND) || return 1
    _op_any=$(bg_read_appop_mode "$_pkg" RUN_ANY_IN_BACKGROUND) || return 1

    # A package already at the module target without a baseline predates
    # baseline tracking. Do not record the restricted state as its own restore
    # target.
    case "$_bucket" in
        45|restricted)
            if [ "$_op_bg" = "ignore" ] && [ "$_op_any" = "ignore" ]; then
                return 0
            fi
            ;;
    esac

    _bucket_arg=$(bg_bucket_to_set_arg "$_bucket")
    [ -n "$_bucket_arg" ] || return 1
    mkdir -p "${BG_BASELINE_FILE%/*}" 2>/dev/null
    [ ! -d "$BG_BASELINE_FILE" ] || return 1
    _bg_tmp="${BG_BASELINE_FILE}.tmp.$$"
    if {
        [ ! -s "$BG_BASELINE_FILE" ] || cat "$BG_BASELINE_FILE"
        printf '%s|%s|%s|%s\n' "$_pkg" "$_bucket" "$_op_bg" "$_op_any"
    } > "$_bg_tmp" 2>/dev/null \
        && mv "$_bg_tmp" "$BG_BASELINE_FILE" 2>/dev/null \
        && [ -f "$BG_BASELINE_FILE" ]; then
        return 0
    fi
    rm -f "$_bg_tmp" 2>/dev/null
    return 1
}

bg_parse_baseline() {
    _bg_baseline_raw="$1"
    _bg_base_pkg=""
    _bg_base_bucket=""
    _bg_base_op_bg=""
    _bg_base_op_any=""
    IFS='|' read -r _bg_base_pkg _bg_base_bucket _bg_base_op_bg _bg_base_op_any <<EOF
$_bg_baseline_raw
EOF
}

bg_restore_baseline() {
    _pkg="$1"
    _line=$(bg_baseline_line "$_pkg")
    if [ -n "$_line" ]; then
        bg_parse_baseline "$_line"
        _bucket_arg=$(bg_bucket_to_set_arg "$_bg_base_bucket")
        [ -n "$_bucket_arg" ] || return 1
        am set-standby-bucket "$_pkg" "$_bucket_arg" 2>/dev/null \
            && bg_set_appop_mode "$_pkg" RUN_IN_BACKGROUND "$_bg_base_op_bg" \
            && bg_set_appop_mode "$_pkg" RUN_ANY_IN_BACKGROUND "$_bg_base_op_any" \
            && bg_bucket_matches "$_pkg" "$_bucket_arg" \
            && bg_appop_matches "$_pkg" RUN_IN_BACKGROUND "$_bg_base_op_bg" \
            && bg_appop_matches "$_pkg" RUN_ANY_IN_BACKGROUND "$_bg_base_op_any" \
            && bg_delete_baseline "$_pkg"
        return $?
    fi

    # Compatibility fallback when no pre-restriction baseline was captured.
    am set-standby-bucket "$_pkg" active 2>/dev/null \
        && cmd appops set "$_pkg" RUN_IN_BACKGROUND allow 2>/dev/null \
        && cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND allow 2>/dev/null \
        && bg_bucket_matches "$_pkg" active \
        && bg_appop_matches "$_pkg" RUN_IN_BACKGROUND allow \
        && bg_appop_matches "$_pkg" RUN_ANY_IN_BACKGROUND allow
}

bg_restore_appops_from_baseline() {
    _pkg="$1"
    _line=$(bg_baseline_line "$_pkg")
    if [ -n "$_line" ]; then
        bg_parse_baseline "$_line"
        bg_set_appop_mode "$_pkg" RUN_IN_BACKGROUND "$_bg_base_op_bg" \
            && bg_set_appop_mode "$_pkg" RUN_ANY_IN_BACKGROUND "$_bg_base_op_any" \
            && bg_appop_matches "$_pkg" RUN_IN_BACKGROUND "$_bg_base_op_bg" \
            && bg_appop_matches "$_pkg" RUN_ANY_IN_BACKGROUND "$_bg_base_op_any"
        return $?
    fi
    cmd appops set "$_pkg" RUN_IN_BACKGROUND allow 2>/dev/null \
        && cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND allow 2>/dev/null \
        && bg_appop_matches "$_pkg" RUN_IN_BACKGROUND allow \
        && bg_appop_matches "$_pkg" RUN_ANY_IN_BACKGROUND allow
}

bg_restore_run_any_from_baseline() {
    _pkg="$1"
    _line=$(bg_baseline_line "$_pkg")
    if [ -n "$_line" ]; then
        bg_parse_baseline "$_line"
        bg_set_appop_mode "$_pkg" RUN_ANY_IN_BACKGROUND "$_bg_base_op_any" \
            && bg_appop_matches "$_pkg" RUN_ANY_IN_BACKGROUND "$_bg_base_op_any"
        return $?
    fi
    cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND allow 2>/dev/null \
        && bg_appop_matches "$_pkg" RUN_ANY_IN_BACKGROUND allow
}

bg_apply_restrict() {
    _pkg="$1"
    am set-standby-bucket "$_pkg" restricted 2>/dev/null \
        && cmd appops set "$_pkg" RUN_IN_BACKGROUND ignore 2>/dev/null \
        && cmd appops set "$_pkg" RUN_ANY_IN_BACKGROUND ignore 2>/dev/null \
        && bg_bucket_matches "$_pkg" restricted \
        && bg_appop_matches "$_pkg" RUN_IN_BACKGROUND ignore \
        && bg_appop_matches "$_pkg" RUN_ANY_IN_BACKGROUND ignore
}

bg_apply_policy() {
    _pkg="$1"
    _policy=$(bg_normalize_policy "$2")
    case "$_pkg" in ''|*[!a-zA-Z0-9._]*) return 1 ;; esac
    bg_record_baseline "$_pkg" || return 1
    case "$_policy" in
        bucket)
            am set-standby-bucket "$_pkg" rare 2>/dev/null \
                && bg_restore_appops_from_baseline "$_pkg" \
                && bg_bucket_matches "$_pkg" rare
            ;;
        block_services)
            am set-standby-bucket "$_pkg" restricted 2>/dev/null \
                && cmd appops set "$_pkg" RUN_IN_BACKGROUND ignore 2>/dev/null \
                && bg_restore_run_any_from_baseline "$_pkg" \
                && bg_bucket_matches "$_pkg" restricted \
                && bg_appop_matches "$_pkg" RUN_IN_BACKGROUND ignore
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
    [ -s "$BG_LIST_FILE" ] || return 0
    _bg_failed=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        bg_apply_entry "$_line" || _bg_failed=1
    done < "$BG_LIST_FILE"
    [ "$_bg_failed" -eq 0 ]
}

bg_remove_all() {
    [ -s "$BG_LIST_FILE" ] || return 0
    _bg_failed=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        bg_parse_entry "$_line"
        [ -z "$_bg_pkg" ] && continue
        case "$_bg_pkg" in \#*) continue ;; esac
        bg_remove_restrict "$_bg_pkg" || _bg_failed=1
    done < "$BG_LIST_FILE"
    [ "$_bg_failed" -eq 0 ]
}
