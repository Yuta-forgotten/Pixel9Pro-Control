#!/system/bin/sh
# Small state files only. Subshell scope prevents helper variables and traps
# from changing the caller's transaction/rollback state. Atomic visibility is
# not a claim of fsync durability after sudden power loss.

state_read_entry() (
    [ ! -L "$1" ] || exit 1
    [ -e "$1" ] || exit 0
    [ -f "$1" ] && [ -r "$1" ] || exit 1
    _sio_size=$(stat -c %s "$1" 2>/dev/null) || exit 1
    case "$_sio_size" in ''|*[!0-9]*) exit 1 ;; esac
    [ "$_sio_size" -le 8388608 ] || exit 1
    cat "$1" 2>/dev/null
)

state_atomic_write() (
    _sio_path="$1"
    _sio_value="$2"
    _sio_mode="${3:-600}"
    case "$_sio_mode" in 600|644) ;; *) exit 1 ;; esac
    [ -n "$_sio_path" ] && [ ! -L "$_sio_path" ] || exit 1
    [ ! -e "$_sio_path" ] || [ -f "$_sio_path" ] || exit 1
    umask 077
    _sio_tmp=$(mktemp "${_sio_path}.tmp.XXXXXX") || exit 1
    trap 'rm -f "$_sio_tmp"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '%s' "$_sio_value" > "$_sio_tmp" && chmod "$_sio_mode" "$_sio_tmp" || exit 1
    if cmp -s "$_sio_tmp" "$_sio_path" \
        && [ "$(stat -c %a "$_sio_path" 2>/dev/null)" = "$_sio_mode" ]; then exit 0; fi
    mv -f "$_sio_tmp" "$_sio_path" || exit 1
    _sio_readback=$(cat "$_sio_path" 2>/dev/null) || exit 1
    _sio_expected=$(printf '%s' "$_sio_value")
    [ -f "$_sio_path" ] && [ ! -L "$_sio_path" ] \
        && [ "$_sio_readback" = "$_sio_expected" ] \
        && [ "$(stat -c %a "$_sio_path" 2>/dev/null)" = "$_sio_mode" ]
)

state_atomic_from_file() (
    _sio_path="$1"
    _sio_source="$2"
    _sio_mode="${3:-600}"
    case "$_sio_mode" in 600|644) ;; *) exit 1 ;; esac
    [ -f "$_sio_source" ] && [ -r "$_sio_source" ] && [ ! -L "$_sio_source" ] || exit 1
    [ -n "$_sio_path" ] && [ ! -L "$_sio_path" ] || exit 1
    [ ! -e "$_sio_path" ] || [ -f "$_sio_path" ] || exit 1
    umask 077
    _sio_tmp=$(mktemp "${_sio_path}.tmp.XXXXXX") || exit 1
    trap 'rm -f "$_sio_tmp"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cat "$_sio_source" > "$_sio_tmp" && cmp -s "$_sio_source" "$_sio_tmp" \
        && chmod "$_sio_mode" "$_sio_tmp" && mv -f "$_sio_tmp" "$_sio_path" \
        && cmp -s "$_sio_source" "$_sio_path" \
        && [ "$(stat -c %a "$_sio_path" 2>/dev/null)" = "$_sio_mode" ]
)

# Caller owns cleanup; these helpers never replace its traps. At most one
# contender reclaims a dead owner, and an unpublished owner gets a grace period.
state_lock_acquire() {
    command -v module_lock_owner_alive >/dev/null 2>&1 \
        || . "${PIXEL9PRO_MODDIR:-${MODDIR:-${MODPATH:-/data/adb/modules/pixel9pro_control}}}/scripts/background_tasks_lib.sh" || return 1
    _sio_lock_path="$1"
    _sio_lock_attempts="${2:-1}"
    _sio_lock_reclaimed=0
    case "$_sio_lock_attempts" in 1|2|3|4|5|6|7|8|9|10) ;; *) return 1 ;; esac
    [ ! -L "$_sio_lock_path" ] && [ ! -L "${_sio_lock_path%/*}" ] || return 1
    mkdir -p "${_sio_lock_path%/*}" || return 1
    while [ "$_sio_lock_attempts" -gt 0 ]; do
        if (umask 077; mkdir "$_sio_lock_path") 2>/dev/null; then
            module_lock_write_owner "$_sio_lock_path" && return 0
            rmdir "$_sio_lock_path" 2>/dev/null
            return 1
        fi
        if ! module_lock_owner_alive "$_sio_lock_path" \
            && ! module_lock_initializing "$_sio_lock_path"; then
            rm -f "$_sio_lock_path/owner" "$_sio_lock_path/owner.tmp" 2>/dev/null || return 1
            rmdir "$_sio_lock_path" 2>/dev/null || return 75
            if [ "$_sio_lock_reclaimed" -eq 0 ]; then
                _sio_lock_reclaimed=1
                continue
            fi
        fi
        _sio_lock_attempts=$((_sio_lock_attempts - 1))
        [ "$_sio_lock_attempts" -eq 0 ] || sleep 0.1
    done
    return 75
}

state_lock_release() {
    IFS=' ' read -r _sio_self _sio_stat < /proc/self/stat || return 1
    if module_lock_owner_alive "$1" && [ "$MODULE_OWNER_PID" = "$_sio_self" ]; then
        rm -f "$1/owner" "$1/owner.tmp" && rmdir "$1"
    else
        return 1
    fi
}
