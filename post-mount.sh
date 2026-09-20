#!/system/bin/sh

# The selected MetaModule backend runs before this stage. Verify the effective
# UECap target before late service runs; this does not prove modem load.
MODDIR="${0%/*}"
export PIXEL9PRO_MODDIR="$MODDIR"

[ -f "$MODDIR/uecap_profile.sh" ] || exit 0
. "$MODDIR/uecap_profile.sh" 2>/dev/null || exit 0
[ -r "$MODDIR/scripts/slot_transaction_lib.sh" ] && . "$MODDIR/scripts/slot_transaction_lib.sh" 2>/dev/null || true
slot_init >/dev/null 2>&1 || true

hybrid_thermal_readback() {
    [ "$UECAP_BACKEND" = hybrid_mount ] || return 0
    _thermal_policy="$(cat "$MODDIR/.thermal_policy" 2>/dev/null | tr -d ' \n\r\t')"
    _thermal_source="$MODDIR/system/vendor/etc/thermal_info_config.json"
    _thermal_effective=/vendor/etc/thermal_info_config.json
    _thermal_effective_context=$(ls -Zd "$_thermal_effective" 2>/dev/null | awk '{print $1}')
    _thermal_status=failed
    _thermal_source_hash=none
    _thermal_effective_hash=$(sha256sum "$_thermal_effective" 2>/dev/null | awk '{print $1}')
    if [ "$_thermal_policy" = system ]; then
        [ ! -e "$_thermal_source" ] && [ "$_thermal_effective_context" = u:object_r:vendor_configs_file:s0 ] \
            && _thermal_status=verified
    elif [ "$_thermal_policy" = custom ] && [ -f "$_thermal_source" ]; then
        _thermal_source_hash=$(sha256sum "$_thermal_source" 2>/dev/null | awk '{print $1}')
        _thermal_source_context=$(ls -Zd "$_thermal_source" 2>/dev/null | awk '{print $1}')
        [ -n "$_thermal_source_hash" ] \
            && [ "$_thermal_source_hash" = "$_thermal_effective_hash" ] \
            && [ "$_thermal_source_context" = u:object_r:vendor_configs_file:s0 ] \
            && [ "$_thermal_effective_context" = u:object_r:vendor_configs_file:s0 ] \
            && _thermal_status=verified
    fi
    _thermal_tmp="${MODDIR}/.thermal_runtime_receipt.tmp.$$"
    {
        printf 'backend=hybrid_mount\n'
        printf 'policy=%s\n' "$_thermal_policy"
        printf 'status=%s\n' "$_thermal_status"
        printf 'source_hash=%s\n' "$_thermal_source_hash"
        printf 'effective_hash=%s\n' "$_thermal_effective_hash"
        printf 'effective_context=%s\n' "$_thermal_effective_context"
    } > "$_thermal_tmp" 2>/dev/null && mv "$_thermal_tmp" "$MODDIR/.thermal_runtime_receipt" 2>/dev/null || rm -f "$_thermal_tmp" 2>/dev/null
    [ "$_thermal_status" = verified ]
}

if ! hybrid_thermal_readback; then
    [ "$UECAP_BACKEND" = hybrid_mount ] && slot_mark_rollback_pending thermal >/dev/null 2>&1 || true
    log -t pixel9pro_ctrl "WARNING: Hybrid Mount thermal effective readback failed"
elif [ "$UECAP_BACKEND" = hybrid_mount ]; then
    slot_mark_verified thermal >/dev/null 2>&1 || true
fi

if ! uecap_is_available; then
    log -t pixel9pro_ctrl "UECap post-mount skipped: $(uecap_current_reason)"
    exit 0
fi

_uecap_post_mount_mode=$(uecap_current_manual_mode)
if [ "$UECAP_BACKEND" = metamodule_content ] || [ "$UECAP_BACKEND" = hybrid_mount ]; then
    if uecap_verify_staged_mode "$_uecap_post_mount_mode" >/dev/null 2>&1; then
        [ "$UECAP_BACKEND" = hybrid_mount ] && slot_mark_verified uecap >/dev/null 2>&1 || true
        log -t pixel9pro_ctrl "UECap effective target verified from $UECAP_BACKEND: $_uecap_post_mount_mode; modem load remains unconfirmed"
    else
        [ "$UECAP_BACKEND" = hybrid_mount ] && slot_mark_rollback_pending uecap >/dev/null 2>&1 || true
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
