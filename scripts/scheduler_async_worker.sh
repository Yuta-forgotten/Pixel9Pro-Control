#!/system/bin/sh
# Finite task launched only by an explicit owner/retry request. Each domain
# command retains its own bounded attempts and rollback; no timeout SIGKILL.
MODDIR="$1"
_sa_expected_id="$2"
. "$MODDIR/scripts/scheduler_async_lib.sh" && scheduler_async_init "$MODDIR" || exit 1
scheduler_async_load
[ "$SA_ID" = "$_sa_expected_id" ] && [ "$SA_PHASE" = queued ] || exit 1
[ "$SA_BOOT" = "$(cat /proc/sys/kernel/random/boot_id)" ] || exit 1
module_lock_write_owner "$SA_LOCK" || exit 1
_sa_owned_id="$SA_ID"
_sa_owned_kind="$SA_KIND"
_sa_owned_boot="$SA_BOOT"
_sa_owned_uptime="$SA_UPTIME"
scheduler_async_finish() {
    _sa_result="$1"
    trap - EXIT HUP INT TERM
    SA_ID="$_sa_owned_id"; SA_KIND="$_sa_owned_kind"; SA_BOOT="$_sa_owned_boot"; SA_UPTIME="$_sa_owned_uptime"
    SA_RC="$_sa_result"; SA_PHASE=failed
    case "$_sa_result" in 0) SA_PHASE=success ;; 75) SA_PHASE=deferred ;; esac
    if scheduler_async_commit; then
        state_lock_release "$SA_LOCK" || true
    else
        # Keep the dead owner's lock/queued receipt as unconfirmed evidence.
        log -t pixel9pro_ctrl 'ERROR: scheduler async result persistence failed'
    fi
    (. "$MODDIR/scripts/module_metadata_lib.sh" && module_description_refresh "$MODDIR") >/dev/null 2>&1 || true
    exit "$_sa_result"
}
trap 'scheduler_async_finish "$?"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
SA_PHASE=running
scheduler_async_commit || exit 1
log -t pixel9pro_ctrl "scheduler request started: $_sa_owned_kind"
case "$SA_KIND" in
    retry)
        sh "$MODDIR/scripts/scheduler_reconcile.sh" retry "$MODDIR"
        exit $? ;;
    handoff|tick)
        . "$MODDIR/scripts/display_state_lib.sh" || exit 1
        display_state_read >/dev/null 2>&1 || true
        [ "$(display_state_legacy_screen)" = on ] || exit 75
        SO_TRANSITION_LOCK_MAX_ATTEMPTS=1 SO_TRANSITION_LOCK_RETRY_SLEEP_S=0 \
            sh "$MODDIR/scripts/owner_arbiter.sh" apply-tick "$MODDIR" on
        exit $? ;;
    *) exit 64 ;;
esac
