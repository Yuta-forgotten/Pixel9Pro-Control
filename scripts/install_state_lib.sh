#!/system/bin/sh

# Upgrade preservation registry. Domain libraries validate their own fields;
# do not mirror their defaults or effective-state receipts in a second schema.

INSTALL_STATE_SCHEMA=1

# Upgrade preservation is declared once. Runtime locks, tokens, effective boot
# receipts and readiness markers are rebuilt; they are never user preferences.
install_state_upgrade_files() {
    case "$1" in
        preferences)
            printf '%s\n' .thermal_policy .thermal_offset .scheduler_mode \
                .feature_nr .feature_sim2 .feature_vm .profile_policy .profile_manual \
                .nr_screen_switch .sim2_auto_manage .idle_isolate_mode .swap_mode .swap_custom \
                .ntp_server .uecap_mode .uecap_manual_mode .uecap_policy .uecap_reason \
                .webui_theme .bg_restrict_list .bg_restrict_enabled .sched_owner_desired \
                .game_handoff_policy .game_handoff_source ;;
        recovery)
            printf '%s\n' .current_profile .profile_auto_reason .cpu_sched_owner \
                .vm_reboot_required .vm_reboot_boot_id .zram_request_baseline .zram_request_last \
                .zram_request_receipt .zram_restore_pending .sim2_radio_off .nr_saved_mode .nr_temporary_lease .bg_restrict_baseline ;;
        history) printf '%s\n' .profile_history .thermal_history ;;
        *) return 1 ;;
    esac
}

install_state_migrate() (
    umask 077
    _ism_old="$1"
    _ism_new="$2"
    [ -d "$_ism_old" ] && [ -d "$_ism_new" ] && [ "$_ism_old" != "$_ism_new" ] || return 1
    _ism_schema=''
    if [ -e "$_ism_old/.state_schema" ] || [ -L "$_ism_old/.state_schema" ]; then
        [ -f "$_ism_old/.state_schema" ] && [ ! -L "$_ism_old/.state_schema" ] || return 1
        _ism_schema=$(cat "$_ism_old/.state_schema" 2>/dev/null) || return 1
    fi
    case "$_ism_schema" in ''|1) ;; *) return 1 ;; esac
    # Recovery journals are not ordinary preferences. Never discard a live
    # transaction during upgrade and then silently generate a new baseline.
    for _ism_journal in .bg_policy_tx .uecap_stage_tx .thermal_tx .scheduler_async.lock; do
        [ ! -L "$_ism_old/$_ism_journal" ] || return 1
        [ ! -e "$_ism_old/$_ism_journal" ] || return 1
    done
    for _ism_scope in preferences recovery history; do
        for _ism_name in $(install_state_upgrade_files "$_ism_scope"); do
            _ism_source="$_ism_old/$_ism_name"
            _ism_target="$_ism_new/$_ism_name"
            [ ! -L "$_ism_source" ] && [ ! -L "$_ism_target" ] || return 1
            [ ! -e "$_ism_source" ] || [ -f "$_ism_source" ] || return 1
            [ -f "$_ism_source" ] || continue
            _ism_bytes=$(wc -c < "$_ism_source" | tr -d ' \r\n')
            case "$_ism_bytes" in ''|*[!0-9]*) return 1 ;; esac
            # Histories are bounded by their producers. Refuse unexpected large
            # inputs instead of blocking the installer or truncating user data.
            _ism_limit=1048576
            [ "$_ism_scope" != history ] || _ism_limit=8388608
            [ "$_ism_bytes" -le "$_ism_limit" ] || return 1
            _ism_tmp="$_ism_target.migrate.$$"
            [ ! -e "$_ism_tmp" ] && [ ! -L "$_ism_tmp" ] || return 1
            if (set -C; cat "$_ism_source" > "$_ism_tmp") \
                && chmod 600 "$_ism_tmp" && cmp -s "$_ism_source" "$_ism_tmp" \
                && mv "$_ism_tmp" "$_ism_target" && cmp -s "$_ism_source" "$_ism_target"; then
                :
            else
                rm -f "$_ism_tmp" 2>/dev/null
                return 1
            fi
        done
    done
)
