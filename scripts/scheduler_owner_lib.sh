#!/system/bin/sh

# Shared scheduler-owner state contract.
# .sched_owner_desired is the user's persistent baseline choice.
# .cpu_sched_owner remains the effective runtime owner used by workers.

scheduler_owner_init() {
    SO_MODDIR="${1:-/data/adb/modules/pixel9pro_control}"
    SO_FAS_ROOT="${2:-/data/adb/fas_rs}"
    SO_DESIRED_FILE="$SO_MODDIR/.sched_owner_desired"
    SO_EFFECTIVE_FILE="$SO_MODDIR/.cpu_sched_owner"
    SO_HANDOFF_FILE="$SO_MODDIR/.game_handoff_policy"
    SO_PROFILE_HISTORY_FILE="$SO_MODDIR/.profile_history"
    SO_TRANSITION_LOCK_DIR="$SO_FAS_ROOT/.owner_transition.lock"
    SO_PROC_ROOT="${SO_PROC_ROOT:-/proc}"
}

so_normalize_owner() {
    case "$1" in
        external) printf 'external' ;;
        *) printf 'pixel' ;;
    esac
}

so_read_effective_owner() {
    _so_value=$(cat "$SO_EFFECTIVE_FILE" 2>/dev/null | tr -d ' \n\r\t')
    so_normalize_owner "$_so_value"
}

so_read_desired_owner() {
    _so_value=$(cat "$SO_DESIRED_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_so_value" in
        pixel|external) printf '%s' "$_so_value" ;;
        *) so_read_effective_owner ;;
    esac
}

so_read_handoff_policy() {
    _so_value=$(cat "$SO_HANDOFF_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_so_value" in
        fas_rs) printf 'fas_rs' ;;
        *) printf 'off' ;;
    esac
}

so_atomic_write() {
    _so_file="$1"
    _so_value="$2"
    [ -n "$_so_file" ] && [ ! -d "$_so_file" ] || return 1
    _so_tmp="${_so_file}.$$"
    if printf '%s\n' "$_so_value" > "$_so_tmp" 2>/dev/null \
        && mv "$_so_tmp" "$_so_file" 2>/dev/null \
        && [ -f "$_so_file" ]; then
        _so_written=$(cat "$_so_file" 2>/dev/null | tr -d '\r\n')
        [ "$_so_written" = "$_so_value" ] && return 0
    fi
    rm -f "$_so_tmp" 2>/dev/null
    return 1
}

so_write_desired_owner() {
    case "$1" in pixel|external) ;; *) return 1 ;; esac
    so_atomic_write "$SO_DESIRED_FILE" "$1"
}

so_write_effective_owner() {
    case "$1" in pixel|external) ;; *) return 1 ;; esac
    so_atomic_write "$SO_EFFECTIVE_FILE" "$1"
}

so_write_handoff_policy() {
    case "$1" in fas_rs|off) ;; *) return 1 ;; esac
    so_atomic_write "$SO_HANDOFF_FILE" "$1"
}

so_last_explicit_owner() {
    [ -s "$SO_PROFILE_HISTORY_FILE" ] || return 1
    awk -F, '
        $5 == "pixel_scheduler" { owner = "pixel" }
        $5 == "external_scheduler" { owner = "external" }
        END {
            if (owner == "pixel" || owner == "external") print owner
            else exit 1
        }
    ' "$SO_PROFILE_HISTORY_FILE" 2>/dev/null
}

so_migrate_state() {
    mkdir -p "$SO_FAS_ROOT" 2>/dev/null || return 1

    _so_desired=$(cat "$SO_DESIRED_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_so_desired" in
        pixel|external) ;;
        *)
            _so_desired=$(so_last_explicit_owner 2>/dev/null)
            case "$_so_desired" in
                pixel|external) ;;
                *) _so_desired=$(so_read_effective_owner) ;;
            esac
            so_write_desired_owner "$_so_desired" || return 1
            ;;
    esac

    _so_effective=$(cat "$SO_EFFECTIVE_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_so_effective" in
        pixel|external) ;;
        *) so_write_effective_owner "$_so_desired" || return 1 ;;
    esac

    _so_handoff=$(cat "$SO_HANDOFF_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_so_handoff" in
        fas_rs|off) ;;
        *)
            _so_apply=$(cat "$SO_FAS_ROOT/.arbiter_apply" 2>/dev/null | tr -d ' \n\r\t')
            case "$_so_apply" in
                ''|0|off|false|no) _so_handoff=off ;;
                *) _so_handoff=fas_rs ;;
            esac
            so_write_handoff_policy "$_so_handoff" || return 1
            ;;
    esac
}

so_pid_alive() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "$SO_PROC_ROOT/$1" ]
}

so_process_start_ticks() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    sed 's/^.*) //' "$SO_PROC_ROOT/$1/stat" 2>/dev/null | awk '{print $20}'
}

so_initialize_transition_lock() {
    _so_start=$(so_process_start_ticks "$$")
    if [ -z "$_so_start" ] \
        || ! printf '%s\n' "$$" > "$SO_TRANSITION_LOCK_DIR/pid" 2>/dev/null \
        || ! printf '%s\n' "$_so_start" > "$SO_TRANSITION_LOCK_DIR/start_ticks" 2>/dev/null; then
        rm -f "$SO_TRANSITION_LOCK_DIR/pid" "$SO_TRANSITION_LOCK_DIR/start_ticks" 2>/dev/null
        rmdir "$SO_TRANSITION_LOCK_DIR" 2>/dev/null
        return 1
    fi
    SO_TRANSITION_LOCK_START="$_so_start"
    return 0
}

so_acquire_transition_lock() {
    _so_max_attempts="${SO_TRANSITION_LOCK_MAX_ATTEMPTS:-8}"
    case "$_so_max_attempts" in ''|*[!0-9]*) _so_max_attempts=8 ;; esac
    [ "$_so_max_attempts" -ge 1 ] 2>/dev/null || _so_max_attempts=1
    _so_attempt=1
    while [ "$_so_attempt" -le "$_so_max_attempts" ] 2>/dev/null; do
        if mkdir "$SO_TRANSITION_LOCK_DIR" 2>/dev/null; then
            so_initialize_transition_lock
            return $?
        fi

        _so_lock_pid=$(cat "$SO_TRANSITION_LOCK_DIR/pid" 2>/dev/null | tr -d ' \n\r\t')
        _so_lock_start=$(cat "$SO_TRANSITION_LOCK_DIR/start_ticks" 2>/dev/null | tr -d ' \n\r\t')
        _so_live_start=$(so_process_start_ticks "$_so_lock_pid")
        if ! so_pid_alive "$_so_lock_pid" \
            || [ -z "$_so_lock_start" ] \
            || [ -z "$_so_live_start" ] \
            || [ "$_so_live_start" != "$_so_lock_start" ]; then
            rm -f "$SO_TRANSITION_LOCK_DIR/pid" "$SO_TRANSITION_LOCK_DIR/start_ticks" "$SO_TRANSITION_LOCK_DIR/epoch" 2>/dev/null
            rmdir "$SO_TRANSITION_LOCK_DIR" 2>/dev/null || true
            continue
        fi
        _so_attempt=$((_so_attempt + 1))
        [ "$_so_attempt" -gt "$_so_max_attempts" ] 2>/dev/null || sleep 1
    done
    return 1
}

so_release_transition_lock() {
    _so_lock_pid=$(cat "$SO_TRANSITION_LOCK_DIR/pid" 2>/dev/null | tr -d ' \n\r\t')
    _so_lock_start=$(cat "$SO_TRANSITION_LOCK_DIR/start_ticks" 2>/dev/null | tr -d ' \n\r\t')
    [ "$_so_lock_pid" = "$$" ] \
        && [ -n "${SO_TRANSITION_LOCK_START:-}" ] \
        && [ "$_so_lock_start" = "$SO_TRANSITION_LOCK_START" ] || return 0
    rm -f "$SO_TRANSITION_LOCK_DIR/pid" "$SO_TRANSITION_LOCK_DIR/start_ticks" "$SO_TRANSITION_LOCK_DIR/epoch" 2>/dev/null
    rmdir "$SO_TRANSITION_LOCK_DIR" 2>/dev/null || true
    SO_TRANSITION_LOCK_START=""
}
