#!/system/bin/sh

# Hybrid Mount promotion boundary. This promotes already-validated pending
# files from the regular module; APD may have scanned the source before this
# hook, so post-mount hash/context readback remains mandatory. This script never
# mounts, binds, or writes /vendor directly.
MODDIR="${PIXEL9PRO_MODDIR:-${MODDIR:-${0%/*}}}"
[ -r "$MODDIR/scripts/slot_transaction_lib.sh" ] || exit 0
. "$MODDIR/scripts/slot_transaction_lib.sh" || exit 0
slot_init || exit 0

[ -r "$MODDIR/uecap_profile.sh" ] && . "$MODDIR/uecap_profile.sh" 2>/dev/null || true
if [ "${UECAP_BACKEND:-}" = hybrid_mount ] || [ -f "$MODDIR/.uecap_backend" ] && [ "$(cat "$MODDIR/.uecap_backend" 2>/dev/null)" = hybrid_mount ]; then
    _uecap_target_path="$MODDIR/system/vendor/firmware/uecapconfig/${UECAP_TARGET_NAME:-PLATFORM_9055801516233416490.binarypb}"
    if slot_rollback_pending uecap; then
        if slot_rollback_last_good uecap "$_uecap_target_path"; then
            rm -f "$SLOT_ROOT/uecap/rollback_pending" 2>/dev/null || true
        fi
    else
        slot_promote_pending uecap "$_uecap_target_path" || true
    fi
fi

_thermal_target="$MODDIR/system/vendor/etc/thermal_info_config.json"
_thermal_cancel_marker="$SLOT_ROOT/thermal/previous_state"
_thermal_cancelled=0
_thermal_cancel_requested=0
if [ -r "$MODDIR/scripts/thermal_profile.sh" ]; then
    . "$MODDIR/scripts/thermal_profile.sh" 2>/dev/null || true
fi
if [ "$(sed -n 's/^phase=//p' "$_thermal_cancel_marker" 2>/dev/null | head -n 1 | tr -d ' \n\r\t')" = cancel_requested ]; then
    _thermal_cancel_requested=1
    _thermal_cancel_id=$(sed -n 's/^pending_id=//p' "$_thermal_cancel_marker" 2>/dev/null | head -n 1 | tr -d ' \n\r\t')
    _thermal_pending_id=$(slot_pending_id thermal 2>/dev/null || true)
    if [ -z "$_thermal_pending_id" ] || [ "$_thermal_pending_id" = "$_thermal_cancel_id" ]; then
        _thermal_previous_policy=$(sed -n 's/^policy=//p' "$_thermal_cancel_marker" 2>/dev/null | head -n 1)
        _thermal_previous_offset=$(sed -n 's/^offset=//p' "$_thermal_cancel_marker" 2>/dev/null | head -n 1)
        _thermal_previous_valid=0
        case "$_thermal_previous_policy" in
            system|custom)
                case "$_thermal_previous_offset" in
                    -[0-9]|[0-9])
                        if [ "$_thermal_previous_policy" = custom ] \
                            && command -v thermal_is_valid_offset >/dev/null 2>&1; then
                            thermal_is_valid_offset "$_thermal_previous_offset" && _thermal_previous_valid=1
                        elif [ "$_thermal_previous_policy" = system ]; then
                            _thermal_previous_valid=1
                        fi
                        ;;
                esac
                ;;
        esac
        if [ "$_thermal_previous_valid" -eq 1 ] \
            && { [ -z "$_thermal_pending_id" ] || slot_cancel_pending thermal; }; then
            if slot_atomic_write "$MODDIR/.thermal_policy" "$_thermal_previous_policy" \
                && slot_atomic_write "$MODDIR/.thermal_offset" "$_thermal_previous_offset"; then
                rm -f "$_thermal_cancel_marker" 2>/dev/null || true
                _thermal_cancelled=1
            fi
        fi
    fi
fi
if [ "$_thermal_cancelled" -eq 1 ]; then
    :
elif [ "$_thermal_cancel_requested" -eq 1 ]; then
    # A cancel intent is durable. Never promote a matching/unknown pending slot
    # until the marker can be consumed and the previous state is restored.
    log -t pixel9pro_ctrl "WARNING: thermal cancel intent remains pending; skip promotion"
elif slot_rollback_pending thermal; then
    _thermal_rollback_ok=0
    if slot_lock; then
        if slot_rollback_last_good thermal "$_thermal_target"; then
            rm -f "$SLOT_ROOT/thermal/previous_state" 2>/dev/null || true
            _thermal_rollback_ok=1
        fi
        slot_unlock
    fi
    if [ "$_thermal_rollback_ok" -eq 1 ]; then
        # Keep rollback_pending when the last-good copy failed; the next boot
        # must retry instead of silently exposing a potentially bad source.
        rm -f "$SLOT_ROOT/thermal/rollback_pending" 2>/dev/null || true
    fi
else
    if [ -n "$(slot_pending_value thermal 2>/dev/null)" ] && slot_lock; then
        if slot_promote_pending thermal "$_thermal_target"; then
            rm -f "$SLOT_ROOT/thermal/previous_state" 2>/dev/null || true
        fi
        slot_unlock
    fi
fi
