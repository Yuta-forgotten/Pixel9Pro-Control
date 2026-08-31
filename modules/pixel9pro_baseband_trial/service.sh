#!/system/bin/sh

MODDIR="${MODDIR:-${0%/*}}"
BASEBAND_MODDIR="$MODDIR"
if [ -f "$MODDIR/scripts/baseband_runtime.sh" ]; then
    . "$MODDIR/scripts/baseband_runtime.sh"
    # A second readback makes a staged installer unable to masquerade as an
    # effective overlay: the status file records the post-boot result.
    baseband_runtime_check service || true
fi
