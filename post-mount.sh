#!/system/bin/sh

# The selected MetaModule backend runs before this stage. Verify the effective
# UECap target before late service runs; this does not prove modem load.
MODDIR="${0%/*}"
export PIXEL9PRO_MODDIR="$MODDIR"

THERMAL_POLICY_AVAILABLE=0
if [ -r "$MODDIR/scripts/thermal_policy_lib.sh" ] \
    && . "$MODDIR/scripts/thermal_policy_lib.sh" 2>/dev/null \
    && thermal_policy_init "$MODDIR"; then
    THERMAL_POLICY_AVAILABLE=1
fi

UECAP_PROFILE_AVAILABLE=0
if [ -f "$MODDIR/uecap_profile.sh" ] \
    && . "$MODDIR/uecap_profile.sh" 2>/dev/null; then
    UECAP_PROFILE_AVAILABLE=1
fi

thermal_readback_receipt() {
    _thermal_policy=$(cat "$MODDIR/.thermal_policy" 2>/dev/null | tr -d ' \n\r\t')
    _thermal_source="$MODDIR/system/vendor/etc/thermal_info_config.json"
    _thermal_effective=/vendor/etc/thermal_info_config.json
    _thermal_source_hash=none
    _thermal_source_context=none
    _thermal_source_present=false
    _thermal_effective_hash=none
    _thermal_effective_context=none
    _thermal_config_name=$(getprop vendor.thermal.config 2>/dev/null | tr -d ' \n\r\t')
    [ -n "$_thermal_config_name" ] || _thermal_config_name=thermal_info_config.json
    _thermal_mount_observed=$(grep -F " /vendor " /proc/self/mountinfo 2>/dev/null | head -n 1 | tr '\n' ' ')
    [ -f "$_thermal_source" ] && _thermal_source_present=true \
        && _thermal_source_hash=$(sha256sum "$_thermal_source" 2>/dev/null | awk '{print $1}') \
        && _thermal_source_context=$(ls -Zd "$_thermal_source" 2>/dev/null | awk '{print $1}')
    [ -f "$_thermal_effective" ] \
        && _thermal_effective_hash=$(sha256sum "$_thermal_effective" 2>/dev/null | awk '{print $1}')
    [ -e "$_thermal_effective" ] \
        && _thermal_effective_context=$(ls -Zd "$_thermal_effective" 2>/dev/null | awk '{print $1}')

    _thermal_status=failed
    _thermal_context_status=failed
    [ "$_thermal_effective_context" = u:object_r:vendor_configs_file:s0 ] \
        && _thermal_context_status=verified
    if [ "$THERMAL_POLICY_AVAILABLE" -eq 1 ] \
        && thermal_policy_readback_check "$_thermal_policy"; then
        _thermal_status=verified
    fi

    # Source SELinux context is recorded for diagnosis but does not gate the
    # effective mount: regular-module paths can legitimately carry an adb/data
    # label while /vendor readback must carry vendor_configs_file.
    _thermal_tmp="${MODDIR}/.thermal_runtime_receipt.tmp.$$"
    {
        printf 'schema=2\nboot_id=%s\nbackend=%s\nphase=post_mount\n' \
            "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')" \
            "${UECAP_BACKEND:-unknown}"
        printf 'policy=%s\nsource_path=%s\nsource_present=%s\n' \
            "$_thermal_policy" "$_thermal_source" "$_thermal_source_present"
        printf 'source_hash=%s\nsource_context=%s\n' \
            "$_thermal_source_hash" "$_thermal_source_context"
        printf 'effective_path=%s\neffective_hash=%s\neffective_context=%s\n' \
            "$_thermal_effective" "$_thermal_effective_hash" "$_thermal_effective_context"
        printf 'selected_config=%s\nmount_observed=%s\n' \
            "$_thermal_config_name" "$_thermal_mount_observed"
        printf 'effective_context_status=%s\nstatus=%s\n' \
            "$_thermal_context_status" "$_thermal_status"
    } > "$_thermal_tmp" 2>/dev/null \
        && mv -f "$_thermal_tmp" "$MODDIR/.thermal_runtime_receipt" 2>/dev/null \
        || rm -f "$_thermal_tmp" 2>/dev/null
    [ "$_thermal_status" = verified ]
}

if ! thermal_readback_receipt; then
    [ "$UECAP_BACKEND" = hybrid_mount ] \
        && log -t pixel9pro_ctrl "WARNING: Hybrid Mount thermal effective readback failed" \
        || true
fi
if [ "$THERMAL_POLICY_AVAILABLE" -eq 1 ] \
    && [ "$_thermal_status" = verified ] \
    && thermal_policy_transaction_pending; then
    thermal_policy_transaction_clear >/dev/null 2>&1 || \
        log -t pixel9pro_ctrl "WARNING: thermal transaction receipt verified but journal cleanup failed"
fi

if [ "$UECAP_PROFILE_AVAILABLE" -ne 1 ] || ! uecap_is_available; then
    log -t pixel9pro_ctrl "UECap post-mount skipped: $(uecap_current_reason)"
    exit 0
fi

_uecap_post_mount_mode=$(uecap_current_manual_mode)
if [ "$UECAP_BACKEND" = metamodule_content ] || [ "$UECAP_BACKEND" = hybrid_mount ]; then
    if uecap_verify_staged_mode "$_uecap_post_mount_mode" >/dev/null 2>&1; then
        log -t pixel9pro_ctrl "UECap effective target verified from $UECAP_BACKEND: $_uecap_post_mount_mode; modem load remains unconfirmed"
    else
        UECAP_MOUNT_OBSERVED=content_readback_failed
        uecap_write_runtime_receipt "$_uecap_post_mount_mode" "" "" \
            metamodule_effective_readback_failed failed unverified >/dev/null 2>&1 || true
        log -t pixel9pro_ctrl "WARNING: MetaModule UECap effective readback failed: $_uecap_post_mount_mode"
    fi
elif uecap_apply_mode "$_uecap_post_mount_mode" pre_modem >/dev/null 2>&1; then
    log -t pixel9pro_ctrl "UECap bind verified after mount: $_uecap_post_mount_mode; modem load remains unconfirmed"
else
    log -t pixel9pro_ctrl "WARNING: UECap bind failed: $_uecap_post_mount_mode result=${UECAP_APPLY_RESULT:-unknown}"
fi

# Never block boot.  The late service validates the same-boot receipt and
# exposes failure instead of silently claiming modem effectiveness.
exit 0
