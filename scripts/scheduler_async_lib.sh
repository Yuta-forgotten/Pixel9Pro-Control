#!/system/bin/sh
# A single on-demand owner/retry job. No resident worker or automatic replay.
# The caller receives accepted intent; GET reports the independent outcome.

scheduler_async_init() {
    SA_ROOT="$1"
    SA_LOCK="$SA_ROOT/.scheduler_async.lock"
    SA_STATE="$SA_ROOT/.scheduler_async_state"
    SA_FAS_ROOT="${FAS_ROOT:-/data/adb/fas_rs}"
    . "$SA_ROOT/scripts/state_io_lib.sh" || return 1
    . "$SA_ROOT/scripts/background_tasks_lib.sh" || return 1
}

scheduler_async_load() {
    SA_ID=''; SA_BOOT=''; SA_KIND=''; SA_PHASE=none; SA_RC=0; SA_UPTIME=0
    SA_PENDING=false
    if [ -f "$SA_STATE" ] && [ ! -L "$SA_STATE" ]; then
        while IFS='=' read -r _sa_key _sa_value || [ -n "$_sa_key" ]; do
            case "$_sa_key" in id) SA_ID="$_sa_value" ;; boot_id) SA_BOOT="$_sa_value" ;;
                kind) SA_KIND="$_sa_value" ;; phase) SA_PHASE="$_sa_value" ;;
                rc) SA_RC="$_sa_value" ;; uptime) SA_UPTIME="$_sa_value" ;; esac
        done < "$SA_STATE"
    fi
    case "$SA_ID" in *[!A-Za-z0-9._-]*) SA_ID=''; SA_PHASE=unconfirmed ;; esac
    case "$SA_KIND" in ''|retry|handoff|tick) ;; *) SA_KIND=''; SA_PHASE=unconfirmed ;; esac
    case "$SA_PHASE" in none|queued|running|success|failed|deferred|unconfirmed) ;; *) SA_PHASE=unconfirmed ;; esac
    case "$SA_RC" in ''|*[!0-9]*) SA_RC=1 ;; esac
    case "$SA_UPTIME" in ''|*[!0-9]*) SA_UPTIME=0 ;; esac
    case "$SA_PHASE" in queued|running)
        _sa_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
        if [ "$SA_BOOT" = "$_sa_boot" ] && module_lock_owner_alive "$SA_LOCK"; then
            SA_PENDING=true
        elif [ "$SA_PHASE" = queued ] && [ "$SA_BOOT" = "$_sa_boot" ]; then
            _sa_now=$(awk '{printf "%d",$1}' /proc/uptime 2>/dev/null)
            case "$_sa_now" in ''|*[!0-9]*) _sa_now=0 ;; esac
            if [ "$SA_UPTIME" -gt 0 ] && [ "$_sa_now" -ge "$SA_UPTIME" ] && [ "$((_sa_now - SA_UPTIME))" -le 30 ]; then SA_PENDING=true
            else SA_PHASE=unconfirmed; fi
        else SA_PHASE=unconfirmed; fi ;;
    esac
}

scheduler_async_commit() {
    state_atomic_write "$SA_STATE" "id=$SA_ID
boot_id=$SA_BOOT
kind=$SA_KIND
phase=$SA_PHASE
rc=$SA_RC
uptime=$SA_UPTIME"
}

scheduler_async_start() {
    _sa_requested_kind="$1"
    case "$_sa_requested_kind" in retry|handoff|tick) ;; *) return 64 ;; esac
    scheduler_async_load
    [ "$SA_PENDING" != true ] || return 75
    state_lock_acquire "$SA_LOCK" 2 || return 75
    SA_BOOT=$(cat /proc/sys/kernel/random/boot_id) || { state_lock_release "$SA_LOCK"; return 1; }
    SA_UPTIME=$(awk '{printf "%d",$1}' /proc/uptime)
    SA_ID="$SA_BOOT.$$.$SA_UPTIME"
    SA_KIND="$_sa_requested_kind"; SA_PHASE=queued; SA_RC=0; SA_PENDING=true
    scheduler_async_commit || { state_lock_release "$SA_LOCK"; return 1; }
    # The worker explicitly takes over this exact published job identity.
    SCHEDULER_RECONCILE_FAS_ROOT="$SA_FAS_ROOT" OWNER_ARBITER_FAS_ROOT="$SA_FAS_ROOT" \
        sh "$SA_ROOT/scripts/scheduler_async_worker.sh" "$SA_ROOT" "$SA_ID" \
        >/dev/null 2>&1 </dev/null &
    return 0
}

scheduler_async_json() {
    scheduler_async_load
    printf ',"scheduler_operation":{"id":"%s","kind":"%s","phase":"%s","pending":%s,"result_code":%s}' \
        "$SA_ID" "$SA_KIND" "$SA_PHASE" "$SA_PENDING" "$SA_RC"
}
