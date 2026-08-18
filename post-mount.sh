#!/system/bin/sh

# MetaModule mount runs before this stage.  Bind the selected caiman UECap
# payload here so cbd/shamp sees it on the modem's first boot-time read.
MODDIR="${0%/*}"
export PIXEL9PRO_MODDIR="$MODDIR"

[ -f "$MODDIR/uecap_profile.sh" ] || exit 0
. "$MODDIR/uecap_profile.sh" 2>/dev/null || exit 0

_uecap_post_mount_mode=$(uecap_current_manual_mode)
if uecap_apply_mode "$_uecap_post_mount_mode" pre_modem >/dev/null 2>&1; then
    log -t pixel9pro_ctrl "UECap pre-modem bind verified: $_uecap_post_mount_mode"
else
    log -t pixel9pro_ctrl "WARNING: UECap pre-modem bind failed: $_uecap_post_mount_mode result=${UECAP_APPLY_RESULT:-unknown}"
fi

# Never block boot.  The late service validates the same-boot receipt and
# exposes failure instead of silently claiming modem effectiveness.
exit 0
