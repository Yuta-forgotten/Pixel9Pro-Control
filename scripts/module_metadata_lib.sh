#!/system/bin/sh
# Derived manager-card summary. Refresh only at boot/configuration commits;
# it describes saved intent and never probes Binder or wakes a polling loop.

module_description_refresh() (
    _md_root="$1"
    . "$_md_root/scripts/state_io_lib.sh" || exit 1
    state_lock_acquire "$_md_root/.locks/metadata.lock" 10 || exit 1
    trap 'state_lock_release "$_md_root/.locks/metadata.lock" >/dev/null 2>&1' EXIT
    _md_read() { state_read_entry "$_md_root/$1"; }
    _md_add() { _md_text="${_md_text}${_md_text:+ · }$1"; }
    _md_text=''
    _md_thermal=$(_md_read .thermal_policy) || exit 1
    if [ "$_md_thermal" = custom ]; then
        _md_offset=$(_md_read .thermal_offset) || exit 1
        case "$_md_offset" in -2|0|2|4|6) ;; *) exit 1 ;; esac
        case "$_md_offset" in -*) ;; *) _md_offset="+$_md_offset" ;; esac
        _md_pending=''
        [ ! -s "$_md_root/.thermal_tx/meta" ] || _md_pending='（待重启或处理）'
        _md_add "温控 ${_md_offset}℃$_md_pending"
    fi
    if [ "$_md_thermal" = system ] && [ -s "$_md_root/.thermal_tx/meta" ]; then
        _md_add '恢复系统温控（待重启或处理）'
    fi
    . "$_md_root/scripts/scheduler_capability_lib.sh" \
        && scheduler_capability_init "$_md_root" || exit 1
    _md_scheduler=$(scheduler_mode_read) || exit 1
    if [ "$_md_scheduler" = active ]; then
        _md_owner=$(_md_read .sched_owner_desired) || exit 1
        if [ "$_md_owner" = external ]; then _md_add 'UGT 日常调度'; else
            _md_policy=$(_md_read .profile_policy) || exit 1
            if [ "$_md_policy" = auto ]; then _md_add 'Pixel 自动调度'; else
                _md_profile=$(_md_read .profile_manual) || exit 1
                case "$_md_profile" in performance) _md_label=性能 ;; balanced) _md_label=均衡 ;; battery) _md_label=省电 ;; default) _md_label=系统默认 ;; *) _md_label=未确认 ;; esac
                _md_add "Pixel $_md_label"
            fi
        fi
        [ "$(_md_read .game_handoff_policy)" != fas_rs ] || _md_add '游戏移交'
    fi
    if [ -f "$_md_root/.scheduler_boot_state" ] \
        && grep -qx 'phase=pending_reboot' "$_md_root/.scheduler_boot_state"; then
        _md_target=$(sed -n 's/^target_mode=//p' "$_md_root/.scheduler_boot_state")
        case "$_md_target" in pixel) _md_add '待重启切换 Pixel' ;; ugt) _md_add '待重启切换 UGT' ;; esac
    fi
    if [ "$(_md_read .feature_vm)" = optimized ]; then
        _md_vm=$(_md_read .swap_mode) || exit 1
        case "$_md_vm" in custom) _md_add 'VM 自定义' ;; optimized) _md_add 'VM 优化' ;; esac
    fi
    if [ "$(_md_read .vm_reboot_required)" = true ]; then _md_add 'VM 待重启'; fi
    if [ -s "$_md_root/.zram_request_last" ]; then _md_add 'ZRAM 请求待处理'; fi
    [ "$(_md_read .nr_screen_switch)" != on ] || _md_add 'NR 息屏降级'
    [ ! -e "$_md_root/.nr_temporary_lease" ] || _md_add 'NR 临时状态待恢复'
    [ "$(_md_read .sim2_auto_manage)" != on ] || _md_add 'SIM2 自动管理'
    _md_ue=$(_md_read .uecap_manual_mode) || exit 1
    case "$_md_ue" in
        balanced) _md_ue_label=均衡 ;; special) _md_ue_label=专用 ;;
        universal) _md_ue_label=通用 ;; candidate) _md_ue_label=候选 ;;
        *) _md_ue_label='' ;;
    esac
    if [ -n "$_md_ue_label" ]; then
        _md_pending=''
        [ ! -f "$_md_root/.uecap_reboot_required" ] || _md_pending='（待重启）'
        _md_add "UECap $_md_ue_label$_md_pending"
    fi
    if [ "$(_md_read .bg_restrict_enabled)" = on ] && [ -s "$_md_root/.bg_restrict_list" ]; then _md_add '应用后台限制'; fi
    _md_ntp=$(_md_read .ntp_server) || exit 1
    [ -z "$_md_ntp" ] || _md_add '网络校时'
    [ "$(_md_read .idle_isolate_mode)" != on ] || _md_add '后台任务暂停'
    _md_add WebUI
    _md_text="已选配置：$_md_text"
    _md_prop="$_md_root/module.prop"
    [ -f "$_md_prop" ] && [ ! -L "$_md_prop" ] || exit 1
    _md_tmp=$(mktemp "$_md_root/.description.XXXXXX") || exit 1
    trap 'rm -f "$_md_tmp"; state_lock_release "$_md_root/.locks/metadata.lock" >/dev/null 2>&1' EXIT
    awk -v description="$_md_text" '
        /^description=/ { if (++seen>1) exit 1; print "description=" description; next }
        { print }
        END { if (!seen) exit 1 }
    ' "$_md_prop" > "$_md_tmp" && state_atomic_from_file "$_md_prop" "$_md_tmp" 644
)
