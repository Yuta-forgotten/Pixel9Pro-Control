#!/system/bin/sh
MODDIR="$1"
expected_id="$2"
. "$MODDIR/scripts/memory_lib.sh" && memory_init "$MODDIR" || exit 1
zram_runtime_load
[ "$ZR_ID" = "$expected_id" ] && [ "$ZR_PHASE" = queued ] \
    && [ "$ZR_BOOT" = "$(vm_zram_current_boot_id)" ] || exit 1
vm_zram_size_is_valid "$ZR_SIZE" && vm_zram_algorithm_valid "$ZR_ALGORITHM" || exit 1
module_lock_write_owner "$ZR_LOCK" || exit 1
ZR_TOUCHED=false; ZR_DEVICE_TOUCHED=false; ZR_SUCCESS=false
ZR_VM_TOUCHED=false
ZR_PREVIOUS_VM=$(vm_current_params)

finish() {
    local result="$1" failure="$ZR_REASON"
    trap - EXIT HUP INT TERM
    if [ "$ZR_SUCCESS" != true ] && [ "$ZR_TOUCHED" = true ]; then
        if zram_runtime_rollback; then ZR_PHASE=rollback_complete
        else zram_runtime_start_mmd || true; ZR_PHASE=rollback_incomplete; fi
        ZR_REASON="$failure"
    elif [ "$ZR_SUCCESS" != true ] && [ "$ZR_PHASE" != deferred ]; then ZR_PHASE=failed; fi
    if [ "$ZR_SUCCESS" != true ] && [ "$ZR_VM_TOUCHED" = true ]; then
        set -- $ZR_PREVIOUS_VM
        memory_apply_vm "$1" "$2" "$3" "$4" rollback || ZR_PHASE=rollback_incomplete
    fi
    if zram_runtime_commit; then state_lock_release "$ZR_LOCK" || true; fi
    log -t pixel9pro_ctrl "ZRAM operation $ZR_ID: $ZR_PHASE/$ZR_REASON"
    exit "$result"
}
trap 'finish "$?"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
ZR_PHASE=preflight; ZR_REASON=checking_memory_and_owner
zram_runtime_commit || exit 1
case "$ZR_KIND" in
    restore_original|restore_original_zram)
        memory_original_refresh || { ZR_REASON=original_source_read_failed; exit 1; }
        ZR_SIZE=$(vm_zram_state_field size "$MC_ORIGINAL")
        ZR_ALGORITHM=$(vm_zram_state_field algorithm "$MC_ORIGINAL")
        vm_zram_size_is_valid "$ZR_SIZE" && vm_zram_algorithm_valid "$ZR_ALGORITHM" \
            || { ZR_REASON=original_source_values_invalid; exit 1; }
        zram_runtime_commit || exit 1
        if vm_zram_capacity_matches "$ZR_SIZE" && [ "$(vm_zram_read_algorithm)" = "$ZR_ALGORITHM" ]; then
            if [ "$ZR_KIND" = restore_original ]; then
                values=$(memory_original_params) || exit 1
                set -- $values
                memory_apply_vm "$1" "$2" "$3" "$4" restore || { ZR_REASON=vm_restore_failed; exit 1; }
            fi
            ZR_SUCCESS=true; ZR_PHASE=success; ZR_REASON=original_parameters_applied
            exit 0
        fi
        ;;
esac
if [ "$ZR_KIND" = recover ]; then
    zram_runtime_load_snapshot || { ZR_REASON=recovery_snapshot_unavailable; exit 1; }
    zram_runtime_recovery_owned || { ZR_REASON=external_runtime_owner_changed; exit 1; }
    ZR_DEVICE_TOUCHED=true
else
    zram_runtime_capability
    if [ "$ZR_CAPABLE" != true ]; then ZR_PHASE=deferred; ZR_REASON="$ZR_CAPABILITY_REASON"; exit 77; fi
    zram_runtime_snapshot || { ZR_REASON=snapshot_failed; exit 1; }
fi
ZR_PHASE=stopping_mmd; ZR_REASON=coordinating_platform_owner
zram_runtime_commit || exit 1
ZR_TOUCHED=true
setprop ctl.stop mmd && zram_runtime_wait_service stopped || { ZR_REASON=mmd_stop_failed; exit 1; }
zram_runtime_memory_ready && zram_runtime_pressure_ready || { ZR_REASON=memory_pressure_changed; exit 1; }
[ "$(vm_zram_property_value "$VM_ZRAM_SIZE_PROPERTY")" = "$ZR_OLD_PERSIST" ] \
    || { ZR_REASON=external_persistent_request_changed; exit 1; }
if [ "$ZR_KIND" != recover ]; then
    [ "$(vm_zram_read_requested_size)" = "$ZR_OLD_REQUEST" ] \
        && [ "$(vm_zram_read_requested_algorithm)" = "$ZR_OLD_ALGORITHM" ] \
        && vm_zram_matches "$ZR_OLD_ALGORITHM" "$ZR_OLD_DISKSIZE" \
        || { ZR_REASON=external_runtime_owner_changed; exit 1; }
else
    zram_runtime_recovery_owned || { ZR_REASON=external_runtime_owner_changed; exit 1; }
fi
if vm_zram_is_active; then
    ZR_PHASE=swapoff; ZR_REASON=draining_swap
    zram_runtime_commit || exit 1
    swapoff /dev/block/zram0 || { ZR_REASON=swapoff_failed; exit 1; }
fi
[ "$(vm_zram_active_state)" = inactive ] || { ZR_REASON=swap_still_active; exit 1; }
ZR_DEVICE_TOUCHED=true
ZR_PHASE=rebuilding; ZR_REASON=platform_setup
zram_runtime_commit || exit 1
zram_runtime_properties "$ZR_SIZE" "$ZR_ALGORITHM" \
    && zram_runtime_build "$ZR_SIZE" "$ZR_ALGORITHM" || { ZR_REASON=platform_setup_failed; exit 1; }
ZR_PHASE=verifying; ZR_REASON=checking_swap_and_daemon
zram_runtime_commit || exit 1
zram_runtime_start_mmd \
    && vm_zram_capacity_matches "$ZR_SIZE" \
    && [ "$(vm_zram_read_algorithm)" = "$ZR_ALGORITHM" ] \
    && [ "$(vm_zram_property_value "$VM_ZRAM_SIZE_PROPERTY")" = "$ZR_OLD_PERSIST" ] \
    && [ "$(vm_zram_read_swap_total_kb)" -gt 0 ] \
    || { ZR_REASON=final_readback_failed; exit 1; }
case "$ZR_KIND" in
    preset|restore|restore_original)
        if [ "$ZR_KIND" = preset ]; then values=$(vm_preset_params)
        else values=$(memory_original_params) || { ZR_REASON=vm_baseline_unavailable; exit 1; }; fi
        set -- $values
        ZR_VM_TOUCHED=true
        vm_source="$ZR_KIND"; [ "$ZR_KIND" != restore_original ] || vm_source=restore
        memory_apply_vm "$1" "$2" "$3" "$4" "$vm_source" || { ZR_REASON=vm_preset_failed; exit 1; }
        ;;
esac
ZR_SUCCESS=true; ZR_PHASE=success; ZR_REASON=temporary_until_reboot
exit 0
