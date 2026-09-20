#!/system/bin/sh

# The selected MetaModule backend runs before this stage. Verify the effective
# UECap target before late service runs; this does not prove modem load.
MODDIR="${0%/*}"
export PIXEL9PRO_MODDIR="$MODDIR"

[ -f "$MODDIR/uecap_profile.sh" ] || exit 0
. "$MODDIR/uecap_profile.sh" 2>/dev/null || exit 0
if ! uecap_is_available; then
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
