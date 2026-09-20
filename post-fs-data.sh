#!/system/bin/sh

# Hybrid Mount promotion boundary.  This runs before Hybrid Mount scans the
# regular-module source.  It only promotes already-validated pending files;
# it never mounts, binds, or writes /vendor directly.
MODDIR="${PIXEL9PRO_MODDIR:-${MODDIR:-${0%/*}}}"
[ -r "$MODDIR/scripts/slot_transaction_lib.sh" ] || exit 0
. "$MODDIR/scripts/slot_transaction_lib.sh" || exit 0
slot_init || exit 0

[ -r "$MODDIR/uecap_profile.sh" ] && . "$MODDIR/uecap_profile.sh" 2>/dev/null || true
if [ "${UECAP_BACKEND:-}" = hybrid_mount ] || [ -f "$MODDIR/.uecap_backend" ] && [ "$(cat "$MODDIR/.uecap_backend" 2>/dev/null)" = hybrid_mount ]; then
    slot_promote_pending uecap "$MODDIR/system/vendor/firmware/uecapconfig/${UECAP_TARGET_NAME:-PLATFORM_9055801516233416490.binarypb}" \
        || slot_rollback_last_good uecap "$MODDIR/system/vendor/firmware/uecapconfig/${UECAP_TARGET_NAME:-PLATFORM_9055801516233416490.binarypb}" \
        || true
fi

_thermal_target="$MODDIR/system/vendor/etc/thermal_info_config.json"
slot_promote_pending thermal "$_thermal_target" \
    || slot_rollback_last_good thermal "$_thermal_target" \
    || true
