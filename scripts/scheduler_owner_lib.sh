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
    SO_HANDOFF_SOURCE_FILE="$SO_MODDIR/.game_handoff_source"
    SO_PROFILE_HISTORY_FILE="$SO_MODDIR/.profile_history"
    SO_TRANSITION_LOCK_DIR="$SO_FAS_ROOT/.owner_transition.lock"
    SO_PROC_ROOT="${SO_PROC_ROOT:-/proc}"
    SO_BOOT_ID_PATH="${SO_BOOT_ID_PATH:-/proc/sys/kernel/random/boot_id}"
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

so_read_handoff_source() {
    _so_value=$(cat "$SO_HANDOFF_SOURCE_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_so_value" in
        user|default|legacy) printf '%s' "$_so_value" ;;
        *) printf 'legacy' ;;
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

so_write_handoff_source() {
    case "$1" in user|default|legacy) ;; *) return 1 ;; esac
    so_atomic_write "$SO_HANDOFF_SOURCE_FILE" "$1"
}

so_write_handoff_preference() {
    _so_new_policy="$1"
    _so_new_source="$2"
    case "$_so_new_policy:$_so_new_source" in
        fas_rs:user|fas_rs:default|fas_rs:legacy|off:user|off:default|off:legacy) ;;
        *) return 1 ;;
    esac

    _so_pref_policy_existed=0
    _so_pref_source_existed=0
    [ -e "$SO_HANDOFF_FILE" ] && _so_pref_policy_existed=1
    [ -e "$SO_HANDOFF_SOURCE_FILE" ] && _so_pref_source_existed=1
    _so_pref_old_policy=$(cat "$SO_HANDOFF_FILE" 2>/dev/null)
    _so_pref_old_source=$(cat "$SO_HANDOFF_SOURCE_FILE" 2>/dev/null)
    SO_HANDOFF_PREFERENCE_ROLLBACK_OK=no

    if so_write_handoff_policy "$_so_new_policy" \
        && so_write_handoff_source "$_so_new_source" \
        && [ "$(so_read_handoff_policy)" = "$_so_new_policy" ] \
        && [ "$(so_read_handoff_source)" = "$_so_new_source" ]; then
        SO_HANDOFF_PREFERENCE_ROLLBACK_OK=yes
        return 0
    fi

    _so_pref_rollback=1
    so_restore_state_file "$SO_HANDOFF_SOURCE_FILE" "$_so_pref_source_existed" "$_so_pref_old_source" \
        || _so_pref_rollback=0
    so_restore_state_file "$SO_HANDOFF_FILE" "$_so_pref_policy_existed" "$_so_pref_old_policy" \
        || _so_pref_rollback=0
    [ "$_so_pref_rollback" -eq 1 ] && SO_HANDOFF_PREFERENCE_ROLLBACK_OK=yes
    return 1
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

so_restore_state_file() {
    _so_restore_path="$1"
    _so_restore_existed="$2"
    _so_restore_value="$3"
    if [ "$_so_restore_existed" = "1" ]; then
        so_atomic_write "$_so_restore_path" "$_so_restore_value"
    else
        rm -f "$_so_restore_path" 2>/dev/null
        [ ! -e "$_so_restore_path" ]
    fi
}

so_migrate_state() {
    mkdir -p "$SO_FAS_ROOT" 2>/dev/null || return 1
    SO_MIGRATION_ROLLBACK_OK=no

    _so_desired_existed=0
    _so_effective_existed=0
    _so_handoff_existed=0
    _so_handoff_source_existed=0
    _so_desired_old=""
    _so_effective_old=""
    _so_handoff_old=""
    _so_handoff_source_old=""
    if [ -e "$SO_DESIRED_FILE" ]; then
        [ -f "$SO_DESIRED_FILE" ] || return 1
        _so_desired_old=$(cat "$SO_DESIRED_FILE" 2>/dev/null) || return 1
        _so_desired_existed=1
    fi
    if [ -e "$SO_EFFECTIVE_FILE" ]; then
        [ -f "$SO_EFFECTIVE_FILE" ] || return 1
        _so_effective_old=$(cat "$SO_EFFECTIVE_FILE" 2>/dev/null) || return 1
        _so_effective_existed=1
    fi
    if [ -e "$SO_HANDOFF_FILE" ]; then
        [ -f "$SO_HANDOFF_FILE" ] || return 1
        _so_handoff_old=$(cat "$SO_HANDOFF_FILE" 2>/dev/null) || return 1
        _so_handoff_existed=1
    fi
    if [ -e "$SO_HANDOFF_SOURCE_FILE" ]; then
        [ -f "$SO_HANDOFF_SOURCE_FILE" ] || return 1
        _so_handoff_source_old=$(cat "$SO_HANDOFF_SOURCE_FILE" 2>/dev/null) || return 1
        _so_handoff_source_existed=1
    fi

    _so_desired=$(printf '%s' "$_so_desired_old" | tr -d ' \n\r\t')
    case "$_so_desired" in
        pixel|external) ;;
        *)
            _so_desired=$(so_last_explicit_owner 2>/dev/null)
            case "$_so_desired" in
                pixel|external) ;;
                *)
                    _so_effective_seed=$(printf '%s' "$_so_effective_old" | tr -d ' \n\r\t')
                    _so_desired=$(so_normalize_owner "$_so_effective_seed")
                    ;;
            esac
            ;;
    esac
    _so_effective=$(printf '%s' "$_so_effective_old" | tr -d ' \n\r\t')
    case "$_so_effective" in pixel|external) ;; *) _so_effective="$_so_desired" ;; esac
    _so_handoff=$(printf '%s' "$_so_handoff_old" | tr -d ' \n\r\t')
    case "$_so_handoff" in
        fas_rs|off) ;;
        *)
            _so_apply=$(cat "$SO_FAS_ROOT/.arbiter_apply" 2>/dev/null | tr -d ' \n\r\t')
            case "$_so_apply" in ''|0|off|false|no) _so_handoff=off ;; *) _so_handoff=fas_rs ;; esac
            ;;
    esac
    _so_handoff_source=$(printf '%s' "$_so_handoff_source_old" | tr -d ' \n\r\t')
    case "$_so_handoff_source" in user|default|legacy) ;; *) _so_handoff_source=legacy ;; esac

    _so_migration_ok=1
    [ "$(printf '%s' "$_so_desired_old" | tr -d ' \n\r\t')" = "$_so_desired" ] \
        || so_write_desired_owner "$_so_desired" || _so_migration_ok=0
    if [ "$_so_migration_ok" -eq 1 ]; then
        [ "$(printf '%s' "$_so_effective_old" | tr -d ' \n\r\t')" = "$_so_effective" ] \
            || so_write_effective_owner "$_so_effective" || _so_migration_ok=0
    fi
    if [ "$_so_migration_ok" -eq 1 ]; then
        [ "$(printf '%s' "$_so_handoff_old" | tr -d ' \n\r\t')" = "$_so_handoff" ] \
            || so_write_handoff_policy "$_so_handoff" || _so_migration_ok=0
    fi
    if [ "$_so_migration_ok" -eq 1 ]; then
        [ "$(printf '%s' "$_so_handoff_source_old" | tr -d ' \n\r\t')" = "$_so_handoff_source" ] \
            || so_write_handoff_source "$_so_handoff_source" || _so_migration_ok=0
    fi
    if [ "$_so_migration_ok" -eq 1 ] \
        && [ "$(so_read_desired_owner)" = "$_so_desired" ] \
        && [ "$(so_read_effective_owner)" = "$_so_effective" ] \
        && [ "$(so_read_handoff_policy)" = "$_so_handoff" ] \
        && [ "$(so_read_handoff_source)" = "$_so_handoff_source" ]; then
        SO_MIGRATION_ROLLBACK_OK=yes
        return 0
    fi

    _so_rollback_ok=1
    so_restore_state_file "$SO_HANDOFF_SOURCE_FILE" "$_so_handoff_source_existed" "$_so_handoff_source_old" || _so_rollback_ok=0
    so_restore_state_file "$SO_HANDOFF_FILE" "$_so_handoff_existed" "$_so_handoff_old" || _so_rollback_ok=0
    so_restore_state_file "$SO_EFFECTIVE_FILE" "$_so_effective_existed" "$_so_effective_old" || _so_rollback_ok=0
    so_restore_state_file "$SO_DESIRED_FILE" "$_so_desired_existed" "$_so_desired_old" || _so_rollback_ok=0
    [ "$_so_rollback_ok" -eq 1 ] && SO_MIGRATION_ROLLBACK_OK=yes
    return 1
}

so_pid_alive() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "$SO_PROC_ROOT/$1" ]
}

so_process_start_ticks() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    sed 's/^.*) //' "$SO_PROC_ROOT/$1/stat" 2>/dev/null | awk '{print $20}'
}

so_current_boot_id() {
    _so_boot_id=$(cat "$SO_BOOT_ID_PATH" 2>/dev/null | tr -d ' \n\r\t')
    case "$_so_boot_id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    printf '%s' "$_so_boot_id"
}

# POSIX $$ remains the parent shell PID inside background subshells. Ask a
# short-lived child shell for its PPID so orphaned service workers publish
# their own live PID in lock metadata.  The child writes to a file directly:
# putting the probe in a pipeline makes BusyBox ash report the pipeline
# subshell PID, which has already exited by the time its start ticks are read.
so_capture_current_process_id() {
    _so_pid_probe="$SO_TRANSITION_LOCK_DIR/.pid_probe"
    rm -f "$_so_pid_probe" 2>/dev/null
    sh -c 'printf "%s" "$PPID"' > "$_so_pid_probe" 2>/dev/null || {
        rm -f "$_so_pid_probe" 2>/dev/null
        return 1
    }
    SO_CALLER_PROCESS_PID=$(cat "$_so_pid_probe" 2>/dev/null | tr -d ' \n\r\t')
    rm -f "$_so_pid_probe" 2>/dev/null
    case "$SO_CALLER_PROCESS_PID" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "$SO_PROC_ROOT/$SO_CALLER_PROCESS_PID" ]
}

# A directory with incomplete metadata is active only during a short
# initialization grace. Read-only callers never reclaim locks; mutation paths
# may reclaim stale metadata after that grace expires.
so_transition_lock_epoch() {
    _so_epoch_value=$(cat "$SO_TRANSITION_LOCK_DIR/epoch" 2>/dev/null | tr -d ' \n\r\t')
    case "$_so_epoch_value" in
        ''|*[!0-9]*|0) _so_epoch_value=$(stat -c '%Y' "$SO_TRANSITION_LOCK_DIR" 2>/dev/null | tr -d ' \n\r\t') ;;
    esac
    case "$_so_epoch_value" in ''|*[!0-9]*|0) return 1 ;; esac
    printf '%s' "$_so_epoch_value"
}

so_transition_lock_is_active() {
    [ -d "$SO_TRANSITION_LOCK_DIR" ] || return 1
    _so_active_pid=$(cat "$SO_TRANSITION_LOCK_DIR/pid" 2>/dev/null | tr -d ' \n\r\t')
    _so_active_start=$(cat "$SO_TRANSITION_LOCK_DIR/start_ticks" 2>/dev/null | tr -d ' \n\r\t')
    _so_active_boot=$(cat "$SO_TRANSITION_LOCK_DIR/boot_id" 2>/dev/null | tr -d ' \n\r\t')
    if [ -z "$_so_active_pid" ] || [ -z "$_so_active_start" ] || [ -z "$_so_active_boot" ]; then
        _so_active_grace="${SO_TRANSITION_LOCK_INIT_GRACE_S:-5}"
        case "$_so_active_grace" in ''|*[!0-9]*) _so_active_grace=5 ;; esac
        _so_active_now=$(date +%s 2>/dev/null | tr -d ' \n\r\t')
        _so_active_epoch=$(so_transition_lock_epoch 2>/dev/null)
        case "$_so_active_now:$_so_active_epoch" in
            *[!0-9:]*|:*|*:) return 0 ;;
        esac
        _so_active_age=$((_so_active_now - _so_active_epoch))
        [ "$_so_active_age" -le "$_so_active_grace" ] 2>/dev/null
        return $?
    fi
    _so_current_boot=$(so_current_boot_id 2>/dev/null) || return 0
    [ "$_so_active_boot" = "$_so_current_boot" ] || return 1
    _so_active_live_start=$(so_process_start_ticks "$_so_active_pid")
    so_pid_alive "$_so_active_pid" \
        && [ -n "$_so_active_live_start" ] \
        && [ "$_so_active_live_start" = "$_so_active_start" ]
}

so_reclaim_transition_lock() {
    rm -f "$SO_TRANSITION_LOCK_DIR/.pid_probe" "$SO_TRANSITION_LOCK_DIR/pid" \
        "$SO_TRANSITION_LOCK_DIR/start_ticks" "$SO_TRANSITION_LOCK_DIR/boot_id" \
        "$SO_TRANSITION_LOCK_DIR/epoch" 2>/dev/null
    rmdir "$SO_TRANSITION_LOCK_DIR" 2>/dev/null || true
    [ ! -d "$SO_TRANSITION_LOCK_DIR" ]
}

so_initialize_transition_lock() {
    so_capture_current_process_id || return 1
    _so_pid="$SO_CALLER_PROCESS_PID"
    _so_start=$(so_process_start_ticks "$_so_pid")
    _so_boot=$(so_current_boot_id 2>/dev/null)
    _so_epoch=$(date +%s 2>/dev/null || printf '0')
    if [ -z "$_so_pid" ] || [ -z "$_so_start" ] || [ -z "$_so_boot" ] \
        || ! printf '%s\n' "$_so_epoch" > "$SO_TRANSITION_LOCK_DIR/epoch" 2>/dev/null \
        || ! printf '%s\n' "$_so_boot" > "$SO_TRANSITION_LOCK_DIR/boot_id" 2>/dev/null \
        || ! printf '%s\n' "$_so_pid" > "$SO_TRANSITION_LOCK_DIR/pid" 2>/dev/null \
        || ! printf '%s\n' "$_so_start" > "$SO_TRANSITION_LOCK_DIR/start_ticks" 2>/dev/null; then
        rm -f "$SO_TRANSITION_LOCK_DIR/.pid_probe" "$SO_TRANSITION_LOCK_DIR/pid" \
            "$SO_TRANSITION_LOCK_DIR/start_ticks" "$SO_TRANSITION_LOCK_DIR/boot_id" \
            "$SO_TRANSITION_LOCK_DIR/epoch" 2>/dev/null
        rmdir "$SO_TRANSITION_LOCK_DIR" 2>/dev/null
        return 1
    fi
    SO_TRANSITION_LOCK_PID="$_so_pid"
    SO_TRANSITION_LOCK_START="$_so_start"
    SO_TRANSITION_LOCK_BOOT_ID="$_so_boot"
    return 0
}

so_acquire_transition_lock() {
    _so_max_attempts="${SO_TRANSITION_LOCK_MAX_ATTEMPTS:-8}"
    _so_retry_sleep="${SO_TRANSITION_LOCK_RETRY_SLEEP_S:-1}"
    case "$_so_max_attempts" in ''|*[!0-9]*) _so_max_attempts=8 ;; esac
    case "$_so_retry_sleep" in ''|*[!0-9]*) _so_retry_sleep=1 ;; esac
    [ "$_so_max_attempts" -ge 1 ] 2>/dev/null || _so_max_attempts=1
    _so_attempt=1
    while [ "$_so_attempt" -le "$_so_max_attempts" ] 2>/dev/null; do
        if mkdir "$SO_TRANSITION_LOCK_DIR" 2>/dev/null; then
            so_initialize_transition_lock
            return $?
        fi

        if so_transition_lock_is_active; then
            _so_attempt=$((_so_attempt + 1))
            [ "$_so_attempt" -gt "$_so_max_attempts" ] 2>/dev/null || sleep "$_so_retry_sleep"
            continue
        fi
        if so_reclaim_transition_lock; then
            continue
        fi
        _so_attempt=$((_so_attempt + 1))
        [ "$_so_attempt" -gt "$_so_max_attempts" ] 2>/dev/null || sleep "$_so_retry_sleep"
    done
    return 1
}

so_release_transition_lock() {
    _so_lock_pid=$(cat "$SO_TRANSITION_LOCK_DIR/pid" 2>/dev/null | tr -d ' \n\r\t')
    _so_lock_start=$(cat "$SO_TRANSITION_LOCK_DIR/start_ticks" 2>/dev/null | tr -d ' \n\r\t')
    _so_lock_boot=$(cat "$SO_TRANSITION_LOCK_DIR/boot_id" 2>/dev/null | tr -d ' \n\r\t')
    _so_current_pid=""
    if so_capture_current_process_id 2>/dev/null; then
        _so_current_pid="$SO_CALLER_PROCESS_PID"
    fi
    [ -n "${SO_TRANSITION_LOCK_PID:-}" ] \
        && [ "$_so_current_pid" = "$SO_TRANSITION_LOCK_PID" ] \
        && [ "$_so_lock_pid" = "$SO_TRANSITION_LOCK_PID" ] \
        && [ -n "${SO_TRANSITION_LOCK_START:-}" ] \
        && [ "$_so_lock_start" = "$SO_TRANSITION_LOCK_START" ] \
        && [ -n "${SO_TRANSITION_LOCK_BOOT_ID:-}" ] \
        && [ "$_so_lock_boot" = "$SO_TRANSITION_LOCK_BOOT_ID" ] || return 0
    rm -f "$SO_TRANSITION_LOCK_DIR/.pid_probe" "$SO_TRANSITION_LOCK_DIR/pid" \
        "$SO_TRANSITION_LOCK_DIR/start_ticks" "$SO_TRANSITION_LOCK_DIR/boot_id" \
        "$SO_TRANSITION_LOCK_DIR/epoch" 2>/dev/null
    rmdir "$SO_TRANSITION_LOCK_DIR" 2>/dev/null || true
    SO_TRANSITION_LOCK_PID=""
    SO_TRANSITION_LOCK_START=""
    SO_TRANSITION_LOCK_BOOT_ID=""
}
