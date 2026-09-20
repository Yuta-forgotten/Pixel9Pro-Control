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
    _uecap_target_path="$MODDIR/system/vendor/firmware/uecapconfig/${UECAP_TARGET_NAME:-PLATFORM_9055801516233416490.binarypb}"
    if slot_rollback_pending uecap; then
        slot_rollback_last_good uecap "$_uecap_target_path" || true
        rm -f "$SLOT_ROOT/uecap/rollback_pending" 2>/dev/null || true
    else
        slot_promote_pending uecap "$_uecap_target_path" || true
    fi
fi

_thermal_target="$MODDIR/system/vendor/etc/thermal_info_config.json"
if slot_rollback_pending thermal; then
    slot_rollback_last_good thermal "$_thermal_target" || true
    rm -f "$SLOT_ROOT/thermal/rollback_pending" 2>/dev/null || true
else
    slot_promote_pending thermal "$_thermal_target" || true
fi
