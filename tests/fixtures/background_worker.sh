#!/bin/sh
# Explicit host fixture for lifecycle signalling, not a replacement policy worker.
MODDIR="${0%/*}"
lock="$MODDIR/.background_worker.lock"
[ "${1:-}" != --history-writer ] || lock="$MODDIR/.thermal_history.lock"
mkdir "$lock" 2>/dev/null || exit 1
. "$MODDIR/scripts/background_tasks_lib.sh" || exit 1
module_lock_write_owner "$lock" || exit 1
[ "${1:-}" = --history-writer ] || printf '%s' "$MODULE_OWNER_BOOT" > "$MODDIR/.background_boot_ready"
child=""
cleanup() {
    if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
    rm -f "$lock/owner" "$lock/stopping"
    rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT
trap '[ -f "$MODDIR/hold-stop" ] || exit 143' TERM
while :; do
    sleep 900 &
    child=$!
    printf '%s' "$child" > "$MODDIR/last-sleep"
    wait "$child" 2>/dev/null || true
    # If a deferred TERM interrupted wait, retire its child before continuing.
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    child=""
done
