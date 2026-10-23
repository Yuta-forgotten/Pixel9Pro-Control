#!/system/bin/sh
# A foreground package-policy request snapshots both actual state and all
# affected local records before the first write. It never resets unknown old
# AppOps to allow. An interrupted/failed rollback journal stays available.

bg_tx_begin() {
    . "$MODDIR/scripts/state_io_lib.sh" || return 1
    BG_TX_ROOT="$MODDIR/.bg_policy_tx"
    if [ -d "$BG_TX_ROOT" ] && [ ! -L "$BG_TX_ROOT" ]; then
        case "$(cat "$BG_TX_ROOT/phase" 2>/dev/null)" in
            committed|rolled_back) bg_tx_clear || return 75 ;;
            *) return 75 ;;
        esac
    fi
    (umask 077; mkdir "$BG_TX_ROOT") || return 75
    chmod 700 "$BG_TX_ROOT" || return 1
    BG_TX_ACTIVE=0
    for _btx_name in .bg_restrict_list .bg_restrict_enabled .bg_restrict_baseline .bg_restrict_stop_state .bg_restrict_observed; do
        _btx_path="$MODDIR/$_btx_name"
        state_read_entry "$_btx_path" >/dev/null || { bg_tx_clear; return 1; }
        if [ -e "$_btx_path" ]; then
            cp "$_btx_path" "$BG_TX_ROOT/$_btx_name" \
                && chmod 600 "$BG_TX_ROOT/$_btx_name" \
                && cmp -s "$_btx_path" "$BG_TX_ROOT/$_btx_name" \
                && : > "$BG_TX_ROOT/$_btx_name.present" || { bg_tx_clear; return 1; }
        fi
    done
    _btx_packages=''
    case "$1" in
        add|update|remove) _btx_packages="$2" ;;
        toggle|refresh)
            if [ -e "$BG_LIST_FILE" ]; then
                _btx_packages=$(awk -F'|' '$0 !~ /^#/ && $1!="" { print $1 }' "$BG_LIST_FILE") || { bg_tx_clear; return 1; }
            fi ;;
        *) bg_tx_clear; return 1 ;;
    esac
    case "$1" in add|update|remove)
        [ "$(bg_read_enabled)" = on ] || _btx_packages='' ;;
    esac
    if [ "$1" = remove ] && [ -n "$_btx_packages" ]; then
        bg_package_presence "$2"
        _btx_presence=$?
        case "$_btx_presence" in 0) ;; 1) _btx_packages='' ;; *) bg_tx_clear; return 1 ;; esac
    fi
    _btx_count=$(printf '%s\n' "$_btx_packages" | awk 'NF {n++} END {print n+0}')
    [ "$_btx_count" -le "$BG_MAX_PACKAGES" ] || { bg_tx_clear; return 1; }
    : > "$BG_TX_ROOT/runtime" || { bg_tx_clear; return 1; }
    chmod 600 "$BG_TX_ROOT/runtime" || { bg_tx_clear; return 1; }
    for _btx_pkg in $_btx_packages; do
        case "$_btx_pkg" in ''|*[!A-Za-z0-9._]*) bg_tx_clear; return 1 ;; esac
        bg_package_presence "$_btx_pkg"
        _btx_presence=$?
        case "$_btx_presence" in 0) ;; 1) continue ;; *) bg_tx_clear; return 1 ;; esac
        _btx_bucket=$(bg_read_standby_bucket "$_btx_pkg")
        _btx_bucket_arg=$(bg_bucket_to_set_arg "$_btx_bucket")
        _btx_bg=$(bg_read_appop_mode "$_btx_pkg" RUN_IN_BACKGROUND) \
            && _btx_any=$(bg_read_appop_mode "$_btx_pkg" RUN_ANY_IN_BACKGROUND) \
            && [ -n "$_btx_bucket_arg" ] || { bg_tx_clear; return 1; }
        printf '%s|%s|%s|%s\n' "$_btx_pkg" "$_btx_bucket_arg" "$_btx_bg" "$_btx_any" \
            >> "$BG_TX_ROOT/runtime" || { bg_tx_clear; return 1; }
    done
    state_atomic_write "$BG_TX_ROOT/phase" prepared || { bg_tx_clear; return 1; }
    BG_TX_ACTIVE=1
}

bg_tx_clear() {
    [ -n "${BG_TX_ROOT:-}" ] && [ ! -L "$BG_TX_ROOT" ] || return 1
    for _btx_name in .bg_restrict_list .bg_restrict_enabled .bg_restrict_baseline .bg_restrict_stop_state .bg_restrict_observed; do
        rm -f "$BG_TX_ROOT/$_btx_name" "$BG_TX_ROOT/$_btx_name.present" || return 1
    done
    rm -f "$BG_TX_ROOT/runtime" "$BG_TX_ROOT/phase" && rmdir "$BG_TX_ROOT"
}

bg_tx_rollback() {
    [ "${BG_TX_ACTIVE:-0}" = 1 ] || return 0
    bg_tx_validate || { BG_TX_ACTIVE=0; return 1; }
    _btx_restore_failed=0
    while IFS='|' read -r _btx_pkg _btx_bucket _btx_bg _btx_any; do
        bg_am set-standby-bucket --user "$BG_USER_ID" "$_btx_pkg" "$_btx_bucket" \
            && bg_set_appop_mode "$_btx_pkg" RUN_IN_BACKGROUND "$_btx_bg" \
            && bg_set_appop_mode "$_btx_pkg" RUN_ANY_IN_BACKGROUND "$_btx_any" \
            && bg_bucket_matches "$_btx_pkg" "$_btx_bucket" \
            && bg_appop_matches "$_btx_pkg" RUN_IN_BACKGROUND "$_btx_bg" \
            && bg_appop_matches "$_btx_pkg" RUN_ANY_IN_BACKGROUND "$_btx_any" || _btx_restore_failed=1
    done < "$BG_TX_ROOT/runtime"
    for _btx_name in .bg_restrict_list .bg_restrict_enabled .bg_restrict_baseline .bg_restrict_stop_state .bg_restrict_observed; do
        if [ -f "$BG_TX_ROOT/$_btx_name.present" ]; then
            state_atomic_from_file "$MODDIR/$_btx_name" "$BG_TX_ROOT/$_btx_name" || _btx_restore_failed=1
        else
            rm -f "$MODDIR/$_btx_name" && [ ! -e "$MODDIR/$_btx_name" ] || _btx_restore_failed=1
        fi
    done
    BG_TX_ACTIVE=0
    [ "$_btx_restore_failed" -eq 0 ] || return 1
    state_atomic_write "$BG_TX_ROOT/phase" rolled_back || return 1
    bg_tx_clear || log -t pixel9pro_ctrl 'WARNING: restored background journal cleanup pending'
    return 0
}

bg_tx_validate() {
    [ -d "$BG_TX_ROOT" ] && [ ! -L "$BG_TX_ROOT" ] \
        && [ -f "$BG_TX_ROOT/runtime" ] && [ -r "$BG_TX_ROOT/runtime" ] \
        && [ ! -L "$BG_TX_ROOT/runtime" ] \
        && [ "$(state_read_entry "$BG_TX_ROOT/phase")" = prepared ] || return 1
    for _btx_name in .bg_restrict_list .bg_restrict_enabled .bg_restrict_baseline .bg_restrict_stop_state .bg_restrict_observed; do
        [ ! -L "$BG_TX_ROOT/$_btx_name.present" ] || return 1
        if [ -f "$BG_TX_ROOT/$_btx_name.present" ]; then
            [ -f "$BG_TX_ROOT/$_btx_name" ] || return 1
            state_read_entry "$BG_TX_ROOT/$_btx_name" >/dev/null || return 1
        fi
    done
    awk -F'|' '
        NF!=4 || $1 !~ /^[A-Za-z0-9_.]+$/ || seen[$1]++ { exit 1 }
        $2 !~ /^(exempted|active|working_set|frequent|rare|restricted|never)$/ { exit 1 }
        $3 !~ /^(allow|ignore|deny|default|foreground)$/ || $4 !~ /^(allow|ignore|deny|default|foreground)$/ { exit 1 }
    ' "$BG_TX_ROOT/runtime"
}

bg_tx_recover() {
    . "$MODDIR/scripts/state_io_lib.sh" || return 1
    BG_TX_ROOT="$MODDIR/.bg_policy_tx"
    [ -d "$BG_TX_ROOT" ] && [ ! -L "$BG_TX_ROOT" ] || return 0
    _btx_phase=$(state_read_entry "$BG_TX_ROOT/phase") || return 1
    case "$_btx_phase" in
        committed|rolled_back) bg_tx_clear ;;
        prepared) BG_TX_ACTIVE=1; bg_tx_rollback ;;
        '')
            # No prepared marker means begin never authorized a mutation.
            # Only the fixed snapshot filenames may be removed here.
            bg_tx_clear ;;
        *) return 1 ;;
    esac
}

bg_tx_commit() {
    [ "${BG_TX_ACTIVE:-0}" = 1 ] || return 1
    state_atomic_write "$BG_TX_ROOT/phase" committed || return 1
    BG_TX_ACTIVE=0
    bg_tx_clear || log -t pixel9pro_ctrl 'WARNING: committed background journal cleanup pending'
    return 0
}
