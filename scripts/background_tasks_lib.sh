#!/system/bin/sh
# Highest background policy plus the identity of the one module worker.

background_tasks_enabled() {
    _bg_root="${PIXEL9PRO_MODDIR:-${MODDIR:-/data/adb/modules/pixel9pro_control}}"
    case "$(cat "$_bg_root/.idle_isolate_mode" 2>/dev/null | tr -d ' \r\n\t')" in
        off|'') return 0 ;;
        *) return 1 ;;
    esac
}

module_lock_owner_alive() {
    _bg_owner="$1/owner"
    MODULE_OWNER_PID=""; MODULE_OWNER_BOOT=""; MODULE_OWNER_TICKS=""
    [ -r "$_bg_owner" ] || return 1
    while IFS='=' read -r _bg_key _bg_value; do
        case "$_bg_key" in
            pid) MODULE_OWNER_PID="$_bg_value" ;;
            boot_id) MODULE_OWNER_BOOT="$_bg_value" ;;
            start_ticks) MODULE_OWNER_TICKS="$_bg_value" ;;
        esac
    done < "$_bg_owner"
    case "$MODULE_OWNER_PID:$MODULE_OWNER_TICKS" in *[!0-9:]*|:*|*:) return 1 ;; esac
    [ "${MODULE_OWNER_PID:-0}" -gt 1 ] 2>/dev/null || return 1
    [ -n "$MODULE_OWNER_BOOT" ] && [ "$MODULE_OWNER_BOOT" = "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ] || return 1
    _bg_stat=$(sed 's/^.*) //' "/proc/$MODULE_OWNER_PID/stat" 2>/dev/null)
    _bg_process_state=${_bg_stat%% *}
    _bg_live_ticks=$(printf '%s\n' "$_bg_stat" | cut -d' ' -f20)
    [ "$_bg_process_state" != Z ] && [ "$_bg_live_ticks" = "$MODULE_OWNER_TICKS" ] \
        && kill -0 "$MODULE_OWNER_PID" 2>/dev/null
}

module_lock_write_owner() {
    # Unlike $$, /proc/self identifies the actual POSIX subshell writer.
    IFS=' ' read -r MODULE_OWNER_PID _bg_self_stat < /proc/self/stat || return 1
    MODULE_OWNER_BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || return 1
    MODULE_OWNER_TICKS=$(sed 's/^.*) //' "/proc/$MODULE_OWNER_PID/stat" 2>/dev/null | cut -d' ' -f20)
    [ -n "$MODULE_OWNER_TICKS" ] || return 1
    [ ! -e "$1/owner.tmp" ] && [ ! -L "$1/owner.tmp" ] || return 1
    if ( umask 077; set -C
         printf 'pid=%s\nboot_id=%s\nstart_ticks=%s\n' "$MODULE_OWNER_PID" "$MODULE_OWNER_BOOT" "$MODULE_OWNER_TICKS" > "$1/owner.tmp" \
             && mv "$1/owner.tmp" "$1/owner" ); then return 0; fi
    rm -f "$1/owner.tmp" 2>/dev/null
    return 1
}

module_lock_initializing() {
    # mkdir and owner publication are separate operations. A contender must not
    # steal a freshly-created lock while its owner is publishing its identity.
    [ -d "$1" ] && [ ! -L "$1" ] && [ ! -s "$1/owner" ] || return 1
    _bg_init_mtime=$(stat -c %Y "$1" 2>/dev/null) || return 1
    _bg_init_now=$(date +%s 2>/dev/null) || return 1
    case "$_bg_init_mtime:$_bg_init_now" in *[!0-9:]*|:*|*:) return 1 ;; esac
    _bg_init_age=$((_bg_init_now - _bg_init_mtime))
    # A backward wall-clock correction cannot authorize stealing a new lock.
    [ "$_bg_init_age" -le 30 ]
}

background_worker_alive() {
    _bg_root="${PIXEL9PRO_MODDIR:-${MODDIR:-/data/adb/modules/pixel9pro_control}}"
    if module_lock_owner_alive "$_bg_root/.background_worker.lock"; then
        BG_WORKER_PID="$MODULE_OWNER_PID"
        _bg_boot="$MODULE_OWNER_BOOT"
        return 0
    fi
    BG_WORKER_PID=""
    return 1
}

background_history_writer_busy() {
    _bg_root="${PIXEL9PRO_MODDIR:-${MODDIR:-/data/adb/modules/pixel9pro_control}}"
    _bg_history_lock="$_bg_root/.thermal_history.lock"
    [ -d "$_bg_history_lock" ] || return 1
    module_lock_owner_alive "$_bg_history_lock" && return 0
    [ ! -s "$_bg_history_lock/owner" ] || return 1
    # A just-created lock may not have published its owner yet. Old locks
    # cannot keep the master switch pending forever.
    _bg_history_boot=$(cat "$_bg_history_lock/boot" 2>/dev/null)
    [ -z "$_bg_history_boot" ] || [ "$_bg_history_boot" = "$(cat /proc/sys/kernel/random/boot_id)" ] || return 1
    _bg_history_mtime=$(stat -c %Y "$_bg_history_lock" 2>/dev/null) || return 1
    _bg_history_age=$(( $(date +%s) - _bg_history_mtime ))
    [ "$_bg_history_age" -le 30 ]
}

background_tasks_state() {
    if background_tasks_enabled; then
        if background_worker_alive; then
            if [ "$(cat "$_bg_root/.background_boot_ready" 2>/dev/null)" = "$_bg_boot" ]; then
                printf running
            else
                printf starting
            fi
        else
            printf stopped
        fi
    else
        if background_worker_alive || background_history_writer_busy; then printf stopping; else printf paused; fi
    fi
}

background_tasks_cleanup_state() {
    _bg_root="${PIXEL9PRO_MODDIR:-${MODDIR:-/data/adb/modules/pixel9pro_control}}"
    if [ -e "$_bg_root/.nr_temporary_lease" ] || [ -L "$_bg_root/.nr_temporary_lease" ]; then printf unconfirmed; return; fi
    _bg_run=$(cat "$_bg_root/.background_run" 2>/dev/null)
    _bg_cleanup=$(cat "$_bg_root/.background_cleanup_state" 2>/dev/null)
    _bg_current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    case "$_bg_run" in "$_bg_current_boot"'|'*) ;;
        *) printf none; return ;; esac
    case "$_bg_cleanup" in
        "$_bg_run|ok") printf ok ;;
        "$_bg_run|failed") printf failed ;;
        *) printf unconfirmed ;;
    esac
}

background_tasks_start() {
    background_tasks_enabled || return 0
    # A previously signalled worker must finish before a replacement starts.
    _bg_start_attempt=0
    while background_worker_alive && [ -f "$_bg_root/.background_worker.lock/stopping" ]; do
        [ "$_bg_start_attempt" -lt 30 ] || return 1
        sleep 0.1
        _bg_start_attempt=$((_bg_start_attempt + 1))
    done
    background_worker_alive && return 0
    sh "$_bg_root/service.sh" --background-worker >/dev/null 2>&1 </dev/null &
    _bg_start_attempt=0
    while [ "$_bg_start_attempt" -lt 30 ]; do
        background_worker_alive && return 0
        background_tasks_enabled || return 0
        sleep 0.1
        _bg_start_attempt=$((_bg_start_attempt + 1))
    done
    return 1
}

background_tasks_stop() {
    if background_worker_alive; then
        : > "$_bg_root/.background_worker.lock/stopping" || return 1
        # Only the verified module worker receives this signal.
        kill -TERM "$BG_WORKER_PID" 2>/dev/null || return 1
    fi
    _bg_stop_attempt=0
    while [ "$_bg_stop_attempt" -lt 60 ]; do
        if ! background_worker_alive && ! background_history_writer_busy; then return 0; fi
        sleep 0.1
        _bg_stop_attempt=$((_bg_stop_attempt + 1))
    done
    # A transaction may still be finishing. Never SIGKILL a policy rollback.
    return 75
}
