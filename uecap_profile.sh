#!/system/bin/sh

# Manual UECap tier contract. The module bind-mounts one validated payload and
# records the requested/active tier; no background auto policy exists.

MODDIR="${PIXEL9PRO_MODDIR:-${MODDIR:-${0%/*}}}"
UECAP_MODE_FILE="${PIXEL9PRO_UECAP_MODE_FILE:-$MODDIR/.uecap_mode}"
UECAP_MANUAL_MODE_FILE="${PIXEL9PRO_UECAP_MANUAL_MODE_FILE:-$MODDIR/.uecap_manual_mode}"
UECAP_POLICY_FILE="${PIXEL9PRO_UECAP_POLICY_FILE:-$MODDIR/.uecap_policy}"
UECAP_REASON_FILE="${PIXEL9PRO_UECAP_REASON_FILE:-$MODDIR/.uecap_reason}"
UECAP_SWITCH_FILE="${PIXEL9PRO_UECAP_SWITCH_FILE:-$MODDIR/.uecap_last_switch}"
UECAP_LOGDIR="${PIXEL9PRO_UECAP_LOGDIR:-$MODDIR/.logs}"
UECAP_LOGFILE="${PIXEL9PRO_UECAP_LOGFILE:-$UECAP_LOGDIR/pixel9pro_uecap.log}"
UECAP_TARGET="${PIXEL9PRO_UECAP_TARGET:-/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.binarypb}"
UECAP_SPECIAL="${PIXEL9PRO_UECAP_SPECIAL:-$MODDIR/system/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.special.binarypb}"
UECAP_BALANCED="${PIXEL9PRO_UECAP_BALANCED:-$MODDIR/system/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.balanced.binarypb}"
UECAP_UNIVERSAL="${PIXEL9PRO_UECAP_UNIVERSAL:-$MODDIR/system/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.universal.binarypb}"
UECAP_RELOAD_DISPATCHED=false
UECAP_APPLY_RESULT="idle"
UECAP_STATE_ROLLBACK_RESULT="not_needed"

uecap_log_line() {
    case "$UECAP_LOGFILE" in
        "$MODDIR"/*)
            mkdir -p "${UECAP_LOGFILE%/*}" 2>/dev/null || true
            chmod 700 "${UECAP_LOGFILE%/*}" 2>/dev/null || true
            ;;
    esac
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$1" >> "$UECAP_LOGFILE"
}

uecap_hash() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

uecap_mount_bind() {
    _uecap_mount_bin="/system/bin/mount"
    [ "${PIXEL9PRO_UECAP_TEST_MODE:-0}" = "1" ] \
        && _uecap_mount_bin="${PIXEL9PRO_UECAP_MOUNT_BIN:-mount}"
    "$_uecap_mount_bin" --bind "$1" "$2" >/dev/null 2>&1
}

uecap_unmount() {
    _uecap_umount_bin="/system/bin/umount"
    [ "${PIXEL9PRO_UECAP_TEST_MODE:-0}" = "1" ] \
        && _uecap_umount_bin="${PIXEL9PRO_UECAP_UMOUNT_BIN:-umount}"
    "$_uecap_umount_bin" "$1" >/dev/null 2>&1
}

uecap_target_is_mounted() {
    _uecap_mount_list_bin="/system/bin/mount"
    [ "${PIXEL9PRO_UECAP_TEST_MODE:-0}" = "1" ] \
        && _uecap_mount_list_bin="${PIXEL9PRO_UECAP_MOUNT_BIN:-mount}"
    "$_uecap_mount_list_bin" 2>/dev/null | grep -F " on $UECAP_TARGET " >/dev/null 2>&1
}

uecap_mode_label() {
    case "$1" in
        special|balanced|universal) echo "$1" ;;
        *) echo "unknown" ;;
    esac
}

uecap_current_mode() {
    _mode=$(cat "$UECAP_MODE_FILE" 2>/dev/null | tr -d ' \n\r')
    case "$_mode" in
        special|balanced|universal) echo "$_mode" ;;
        *) echo "balanced" ;;
    esac
}

uecap_current_manual_mode() {
    _mode=$(cat "$UECAP_MANUAL_MODE_FILE" 2>/dev/null | tr -d ' \n\r')
    case "$_mode" in
        special|balanced|universal) echo "$_mode" ;;
        *) echo "balanced" ;;
    esac
}

uecap_current_policy() {
    printf 'manual'
}

uecap_current_reason() {
    cat "$UECAP_REASON_FILE" 2>/dev/null | tr -d '\n\r'
}

uecap_last_switch() {
    cat "$UECAP_SWITCH_FILE" 2>/dev/null | tr -d ' \n\r'
}

uecap_json_escape() {
    printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r//g;s/\n/\\n/g'
}

uecap_atomic_write() {
    _uecap_file="$1"
    _uecap_value="$2"
    [ -n "$_uecap_file" ] && [ ! -d "$_uecap_file" ] || return 1
    _uecap_tmp="${_uecap_file}.tmp.$$"
    if printf '%s' "$_uecap_value" > "$_uecap_tmp" 2>/dev/null \
        && mv "$_uecap_tmp" "$_uecap_file" 2>/dev/null \
        && [ -f "$_uecap_file" ]; then
        _uecap_written=$(cat "$_uecap_file" 2>/dev/null)
        [ "$_uecap_written" = "$_uecap_value" ] && return 0
    fi
    rm -f "$_uecap_tmp" 2>/dev/null
    return 1
}

uecap_restore_file() {
    if [ "$2" = "1" ]; then
        uecap_atomic_write "$1" "$3"
    else
        rm -f "$1" 2>/dev/null
    fi
}

uecap_commit_state() {
    _uecap_commit_mode="$1"
    _uecap_commit_reason="$2"
    _uecap_commit_time="$3"
    case "$_uecap_commit_reason" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac
    case "$_uecap_commit_time" in ''|*[!0-9]*) return 1 ;; esac

    _uecap_mode_existed=0; [ -e "$UECAP_MODE_FILE" ] && _uecap_mode_existed=1
    _uecap_manual_existed=0; [ -e "$UECAP_MANUAL_MODE_FILE" ] && _uecap_manual_existed=1
    _uecap_policy_existed=0; [ -e "$UECAP_POLICY_FILE" ] && _uecap_policy_existed=1
    _uecap_reason_existed=0; [ -e "$UECAP_REASON_FILE" ] && _uecap_reason_existed=1
    _uecap_switch_existed=0; [ -e "$UECAP_SWITCH_FILE" ] && _uecap_switch_existed=1
    _uecap_mode_old=$(cat "$UECAP_MODE_FILE" 2>/dev/null)
    _uecap_manual_old=$(cat "$UECAP_MANUAL_MODE_FILE" 2>/dev/null)
    _uecap_policy_old=$(cat "$UECAP_POLICY_FILE" 2>/dev/null)
    _uecap_reason_old=$(cat "$UECAP_REASON_FILE" 2>/dev/null)
    _uecap_switch_old=$(cat "$UECAP_SWITCH_FILE" 2>/dev/null)

    UECAP_STATE_ROLLBACK_RESULT="not_needed"
    if uecap_set_mode "$_uecap_commit_mode" \
        && uecap_set_manual_mode "$_uecap_commit_mode" \
        && uecap_set_policy manual \
        && uecap_set_reason "$_uecap_commit_reason" \
        && uecap_set_switch_time "$_uecap_commit_time"; then
        return 0
    fi

    _uecap_restore_failed=0
    uecap_restore_file "$UECAP_MODE_FILE" "$_uecap_mode_existed" "$_uecap_mode_old" || _uecap_restore_failed=1
    uecap_restore_file "$UECAP_MANUAL_MODE_FILE" "$_uecap_manual_existed" "$_uecap_manual_old" || _uecap_restore_failed=1
    uecap_restore_file "$UECAP_POLICY_FILE" "$_uecap_policy_existed" "$_uecap_policy_old" || _uecap_restore_failed=1
    uecap_restore_file "$UECAP_REASON_FILE" "$_uecap_reason_existed" "$_uecap_reason_old" || _uecap_restore_failed=1
    uecap_restore_file "$UECAP_SWITCH_FILE" "$_uecap_switch_existed" "$_uecap_switch_old" || _uecap_restore_failed=1
    if [ "$_uecap_restore_failed" -eq 0 ]; then
        UECAP_STATE_ROLLBACK_RESULT="complete"
    else
        UECAP_STATE_ROLLBACK_RESULT="incomplete"
    fi
    return 1
}

uecap_set_mode() {
    _mode=$(uecap_mode_label "$1")
    [ "$_mode" != "unknown" ] || return 1
    uecap_atomic_write "$UECAP_MODE_FILE" "$_mode"
}

uecap_set_manual_mode() {
    _mode=$(uecap_mode_label "$1")
    [ "$_mode" != "unknown" ] || return 1
    uecap_atomic_write "$UECAP_MANUAL_MODE_FILE" "$_mode"
}

uecap_set_policy() {
    case "$1" in
        manual) uecap_atomic_write "$UECAP_POLICY_FILE" manual ;;
        *) return 1 ;;
    esac
}

uecap_set_reason() {
    case "$1" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac
    uecap_atomic_write "$UECAP_REASON_FILE" "$1"
}

uecap_set_switch_time() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    uecap_atomic_write "$UECAP_SWITCH_FILE" "$1"
}

uecap_resolve_source() {
    case "$1" in
        universal) echo "$UECAP_UNIVERSAL" ;;
        special) echo "$UECAP_SPECIAL" ;;
        *) echo "$UECAP_BALANCED" ;;
    esac
}

uecap_reload_modem() {
    _reason="${1:-manual}"
    case "$_reason" in
        boot|boot_manual)
            UECAP_RELOAD_DISPATCHED=false
            uecap_log_line "skip modem reload (reason=$_reason, boot reads fresh)"
            return 0 ;;
    esac
    # restart-modem only cycles cellular radio, does NOT touch WiFi/BT
    # Much safer than airplane toggle which crashed the network stack (B29)
    if /system/bin/cmd phone restart-modem >/dev/null 2>&1; then
        UECAP_RELOAD_DISPATCHED=true
        uecap_log_line "modem restart accepted (reason=$_reason)"
        return 0
    fi
    UECAP_RELOAD_DISPATCHED=false
    uecap_log_line "modem restart failed (reason=$_reason)"
    return 1
}

uecap_detect_active_mode() {
    _target_hash=$(uecap_hash "$UECAP_TARGET")
    [ -z "$_target_hash" ] && { echo "custom"; return; }

    # Prefer the recorded mode if its hash matches — avoids ambiguity
    # when multiple tiers share the same binarypb
    _req=$(uecap_current_mode)
    _req_src=$(uecap_resolve_source "$_req")
    _req_hash=$(uecap_hash "$_req_src")
    if [ "$_target_hash" = "$_req_hash" ]; then
        echo "$_req"
        return
    fi

    _special_hash=$(uecap_hash "$UECAP_SPECIAL")
    _balanced_hash=$(uecap_hash "$UECAP_BALANCED")
    _universal_hash=$(uecap_hash "$UECAP_UNIVERSAL")

    if [ "$_target_hash" = "$_special_hash" ]; then echo "special"
    elif [ "$_target_hash" = "$_balanced_hash" ]; then echo "balanced"
    elif [ "$_target_hash" = "$_universal_hash" ]; then echo "universal"
    else echo "custom"
    fi
}

uecap_restore_previous_mount() {
    _uecap_restore_old_mounted="$1"
    _uecap_restore_old_source="$2"
    _uecap_restore_old_hash="$3"
    if uecap_target_is_mounted && ! uecap_unmount "$UECAP_TARGET"; then
        return 1
    fi
    if [ "$_uecap_restore_old_mounted" -eq 1 ]; then
        [ -f "$_uecap_restore_old_source" ] && [ -n "$_uecap_restore_old_hash" ] || return 1
        uecap_mount_bind "$_uecap_restore_old_source" "$UECAP_TARGET" || return 1
        [ "$(uecap_hash "$UECAP_TARGET")" = "$_uecap_restore_old_hash" ] || return 1
        uecap_target_is_mounted
        return $?
    fi
    ! uecap_target_is_mounted
}

uecap_apply_mode() {
    UECAP_APPLY_RESULT="invalid"
    _mode=$(uecap_mode_label "$1")
    [ "$_mode" != "unknown" ] || return 1
    _reason="${2:-manual}"
    case "$_reason" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac

    _source=$(uecap_resolve_source "$_mode")
    [ -f "$_source" ] || {
        uecap_log_line "source missing: $_source"
        return 1
    }
    [ -e "$UECAP_TARGET" ] || {
        uecap_log_line "target missing: $UECAP_TARGET"
        return 1
    }

    _source_hash=$(uecap_hash "$_source")
    [ -n "$_source_hash" ] || return 1

    _target_ctx=$(ls -Zd "$UECAP_TARGET" 2>/dev/null | awk '{print $1}')
    _source_ctx=$(ls -Zd "$_source" 2>/dev/null | awk '{print $1}')
    if [ -n "$_target_ctx" ] && [ "$_source_ctx" != "$_target_ctx" ]; then
        chcon "$_target_ctx" "$_source" 2>/dev/null || {
            uecap_log_line "SELinux context update failed mode=$_mode"
            return 1
        }
        _source_ctx=$(ls -Zd "$_source" 2>/dev/null | awk '{print $1}')
        [ "$_source_ctx" = "$_target_ctx" ] || return 1
    fi

    _old_mounted=0
    _old_source=""
    _old_hash=""
    if uecap_target_is_mounted; then
        _old_mounted=1
        _old_mode=$(uecap_detect_active_mode)
        case "$_old_mode" in
            special|balanced|universal) _old_source=$(uecap_resolve_source "$_old_mode") ;;
            *)
                uecap_log_line "refuse to replace unknown active bind"
                return 1
                ;;
        esac
        _old_hash=$(uecap_hash "$_old_source")
        [ -n "$_old_hash" ] || return 1
        uecap_unmount "$UECAP_TARGET" || {
            uecap_log_line "unbind failed mode=$_mode"
            return 1
        }
    fi

    if ! uecap_mount_bind "$_source" "$UECAP_TARGET"; then
        if uecap_restore_previous_mount "$_old_mounted" "$_old_source" "$_old_hash"; then
            UECAP_APPLY_RESULT="bind_failed_rolled_back"
            uecap_log_line "bind failed mode=$_mode rollback=complete"
            return 1
        fi
        UECAP_APPLY_RESULT="bind_failed_rollback_incomplete"
        uecap_log_line "bind failed mode=$_mode rollback=incomplete"
        return 2
    fi

    if [ "$(uecap_hash "$UECAP_TARGET")" != "$_source_hash" ]; then
        if uecap_restore_previous_mount "$_old_mounted" "$_old_source" "$_old_hash"; then
            UECAP_APPLY_RESULT="bind_verify_failed_rolled_back"
            uecap_log_line "bind verification failed mode=$_mode rollback=complete"
            return 1
        fi
        UECAP_APPLY_RESULT="bind_verify_failed_rollback_incomplete"
        uecap_log_line "bind verification failed mode=$_mode rollback=incomplete"
        return 2
    fi

    _switch_time=$(date +%s 2>/dev/null || echo 0)
    if ! uecap_commit_state "$_mode" "$_reason" "$_switch_time"; then
        if uecap_restore_previous_mount "$_old_mounted" "$_old_source" "$_old_hash" \
            && [ "$UECAP_STATE_ROLLBACK_RESULT" = "complete" ]; then
            UECAP_APPLY_RESULT="state_failed_rolled_back"
            uecap_log_line "state transaction failed mode=$_mode rollback=complete"
            return 1
        fi
        UECAP_APPLY_RESULT="state_failed_rollback_incomplete"
        uecap_log_line "state transaction failed mode=$_mode rollback=incomplete state=$UECAP_STATE_ROLLBACK_RESULT"
        return 2
    fi
    uecap_log_line "bind ok mode=$_mode hash=$(uecap_hash "$_source")"
    if uecap_reload_modem "$_reason"; then
        UECAP_APPLY_RESULT="applied"
        return 0
    fi
    UECAP_APPLY_RESULT="applied_reload_failed"
    return 3
}

uecap_print_status_json() {
    _requested=$(uecap_current_mode)
    _policy=$(uecap_current_policy)
    _manual=$(uecap_current_manual_mode)
    _reason=$(uecap_current_reason)
    _active=$(uecap_detect_active_mode)
    _target_hash=$(uecap_hash "$UECAP_TARGET")
    _special_hash=$(uecap_hash "$UECAP_SPECIAL")
    _balanced_hash=$(uecap_hash "$UECAP_BALANCED")
    _universal_hash=$(uecap_hash "$UECAP_UNIVERSAL")
    _last_switch=$(uecap_last_switch)
    case "$_last_switch" in ''|*[!0-9]*) _last_switch=0 ;; esac

    printf '{"policy":"%s","requested_mode":"%s","manual_mode":"%s","active_mode":"%s","reason":"%s","last_switch":"%s","target_hash":"%s","special_hash":"%s","balanced_hash":"%s","universal_hash":"%s"}' \
        "$_policy" "$_requested" "$_manual" "$_active" "$(uecap_json_escape "${_reason:-unknown}")" "$_last_switch" \
        "${_target_hash:-unknown}" "${_special_hash:-unknown}" "${_balanced_hash:-unknown}" "${_universal_hash:-unknown}"
}

case "$1" in
    apply)
        _mode=$(uecap_mode_label "${2:-$(uecap_current_mode)}")
        [ "$_mode" = "unknown" ] && exit 1
        uecap_apply_mode "$_mode" manual
        ;;
    status)
        uecap_print_status_json
        ;;
esac
