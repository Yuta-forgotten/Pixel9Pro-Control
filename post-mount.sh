#!/system/bin/sh

MODDIR="${MODDIR:-${0%/*}}"
BASEBAND_MODDIR="$MODDIR"
if [ -f "$MODDIR/scripts/baseband_runtime.sh" ]; then
    . "$MODDIR/scripts/baseband_runtime.sh"
    baseband_runtime_check post-mount || true
else
    if command -v log >/dev/null 2>&1; then
        log -t pixel9pro_baseband -- "post-mount health helper is missing" 2>/dev/null || true
    fi
fi
