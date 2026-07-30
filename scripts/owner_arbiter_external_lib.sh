#!/system/bin/sh

# UGT 与 fas-rs 外部调度器的受控生命周期。

uperf_root_instance_count() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        if [ -f "$TEST_RUNTIME_DIR/uperf_count" ]; then
            _oa_test_count=$(cat "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null | tr -d ' \r\n\t')
            case "$_oa_test_count" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$_oa_test_count" ;; esac
            return
        fi
        [ -f "$TEST_RUNTIME_DIR/uperf_alive" ] && printf '1' || printf '0'
        return
    fi
    _oa_roots=0
    _oa_seen=0
    for _oa_pid in $(pidof uperf 2>/dev/null); do
        case "$_oa_pid" in
            ''|*[!0-9]*) continue ;;
        esac
        _oa_seen=1
        _oa_ppid=$(awk '/^PPid:/{print $2; exit}' "/proc/$_oa_pid/status" 2>/dev/null)
        [ "$_oa_ppid" = "1" ] && _oa_roots=$((_oa_roots + 1))
    done

    if [ "$_oa_seen" -eq 1 ] 2>/dev/null; then
        printf '%s' "$_oa_roots"
        return 0
    fi

    _oa_roots=$(ps -A 2>/dev/null | awk '
        NR > 1 && $NF == "uperf" {
            if ($3 == "1") roots++
        }
        END { print roots + 0 }
    ')
    case "$_oa_roots" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$_oa_roots" ;;
    esac
}

acquire_uperf_start_lock() {
    for _oa_i in 1 2 3 4 5; do
        if mkdir "$UPERF_START_LOCK_DIR" 2>/dev/null; then
            if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
                _oa_lock_start=1
            else
                _oa_lock_start=$(sed 's/^[^)]*) //' "/proc/$$/stat" 2>/dev/null | awk '{print $20}')
            fi
            _oa_lock_boot=$(so_current_boot_id 2>/dev/null)
            if [ -z "$_oa_lock_start" ] || [ -z "$_oa_lock_boot" ] \
                || ! printf '%s\n' "$$" > "$UPERF_START_LOCK_DIR/pid" 2>/dev/null \
                || ! printf '%s\n' "$_oa_lock_start" > "$UPERF_START_LOCK_DIR/start_ticks" 2>/dev/null \
                || ! printf '%s\n' "$_oa_lock_boot" > "$UPERF_START_LOCK_DIR/boot_id" 2>/dev/null; then
                rm -f "$UPERF_START_LOCK_DIR/pid" "$UPERF_START_LOCK_DIR/start_ticks" \
                    "$UPERF_START_LOCK_DIR/boot_id" 2>/dev/null
                rmdir "$UPERF_START_LOCK_DIR" 2>/dev/null
                return 1
            fi
            UPERF_START_LOCK_TICKS="$_oa_lock_start"
            UPERF_START_LOCK_BOOT_ID="$_oa_lock_boot"
            return 0
        fi

        _oa_lock_pid=$(cat "$UPERF_START_LOCK_DIR/pid" 2>/dev/null | tr -d ' \r\n\t')
        _oa_lock_start=$(cat "$UPERF_START_LOCK_DIR/start_ticks" 2>/dev/null | tr -d ' \r\n\t')
        _oa_lock_boot=$(cat "$UPERF_START_LOCK_DIR/boot_id" 2>/dev/null | tr -d ' \r\n\t')
        _oa_current_boot=$(so_current_boot_id 2>/dev/null)
        if [ "$OWNER_ARBITER_TEST_MODE" = "1" ] && pid_alive "$_oa_lock_pid"; then
            _oa_live_start=1
        else
            case "$_oa_lock_pid" in
                ''|*[!0-9]*) _oa_live_start="" ;;
                *) _oa_live_start=$(sed 's/^[^)]*) //' "/proc/$_oa_lock_pid/stat" 2>/dev/null | awk '{print $20}') ;;
            esac
        fi
        if [ -z "$_oa_current_boot" ] || [ "$_oa_lock_boot" != "$_oa_current_boot" ] \
            || ! pid_alive "$_oa_lock_pid" \
            || [ -z "$_oa_lock_start" ] || [ -z "$_oa_live_start" ] \
            || [ "$_oa_live_start" != "$_oa_lock_start" ]; then
            rm -f "$UPERF_START_LOCK_DIR/pid" "$UPERF_START_LOCK_DIR/start_ticks" \
                "$UPERF_START_LOCK_DIR/boot_id" 2>/dev/null
            rmdir "$UPERF_START_LOCK_DIR" 2>/dev/null || true
            continue
        fi
        sleep 1
    done
    return 1
}

release_uperf_start_lock() {
    _oa_lock_pid=$(cat "$UPERF_START_LOCK_DIR/pid" 2>/dev/null | tr -d ' \r\n\t')
    _oa_lock_start=$(cat "$UPERF_START_LOCK_DIR/start_ticks" 2>/dev/null | tr -d ' \r\n\t')
    _oa_lock_boot=$(cat "$UPERF_START_LOCK_DIR/boot_id" 2>/dev/null | tr -d ' \r\n\t')
    [ "$_oa_lock_pid" = "$$" ] \
        && [ -n "${UPERF_START_LOCK_TICKS:-}" ] \
        && [ "$_oa_lock_start" = "$UPERF_START_LOCK_TICKS" ] \
        && [ -n "${UPERF_START_LOCK_BOOT_ID:-}" ] \
        && [ "$_oa_lock_boot" = "$UPERF_START_LOCK_BOOT_ID" ] || return 0
    rm -f "$UPERF_START_LOCK_DIR/pid" "$UPERF_START_LOCK_DIR/start_ticks" \
        "$UPERF_START_LOCK_DIR/boot_id" 2>/dev/null
    rmdir "$UPERF_START_LOCK_DIR" 2>/dev/null || true
    UPERF_START_LOCK_TICKS=""
    UPERF_START_LOCK_BOOT_ID=""
}

normalize_uperf_instances() {
    _oa_roots=$(uperf_root_instance_count)
    [ "$_oa_roots" -gt 1 ] 2>/dev/null || return 0
    UPERF_NORMALIZED="yes"
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        printf '1\n' > "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null || return 1
        printf '1\n' > "$TEST_RUNTIME_DIR/uperf_alive" 2>/dev/null || return 1
        return 0
    fi
    killall uperf 2>/dev/null || true
    for _oa_i in 1 2 3 4 5; do
        sleep 1
        [ "$(uperf_root_instance_count)" -le 1 ] 2>/dev/null && return 0
    done
    return 2
}

uperf_storage_ready() {
    [ "$OWNER_ARBITER_TEST_MODE" = "1" ] && return 0
    [ "$(getprop sys.boot_completed 2>/dev/null | tr -d ' \r\n\t')" = "1" ] || return 1
    [ -d /sdcard/Android ] || [ -d /storage/emulated/0/Android ]
}

uperf_single_instance_stable() {
    for _oa_i in 1 2 3 4 5; do
        [ "$OWNER_ARBITER_TEST_MODE" = "1" ] || sleep 1
        uperf_process_alive || return 1
        _oa_roots=$(uperf_root_instance_count)
        [ "$_oa_roots" -le 1 ] 2>/dev/null || return 2
        [ "$OWNER_ARBITER_TEST_MODE" = "1" ] && break
    done
    return 0
}

resolve_fas_module_path() {
    _oa_path="$FAS_RS_MODULE_PATH"
    case "$_oa_path" in
        ""|*";"*) _oa_path="/data/adb/modules/fas_rs" ;;
    esac
    if [ -f /data/adb/modules/fas_rs/fas-rs ]; then
        _oa_path="/data/adb/modules/fas_rs"
    else
        case "$_oa_path" in
            /data/adb/modules/*)
                [ -f "$_oa_path/fas-rs" ] || _oa_path="/data/adb/modules/fas_rs"
                ;;
            *)
                _oa_path="/data/adb/modules/fas_rs"
                ;;
        esac
    fi
    printf '%s' "$_oa_path"
}

resolve_uperf_module_path() {
    _oa_path="$UPERF_MODULE_PATH"
    case "$_oa_path" in
        ""|*";"*) _oa_path="/data/adb/modules/uperf" ;;
    esac
    if [ -d /data/adb/modules/uperf ]; then
        _oa_path="/data/adb/modules/uperf"
    else
        case "$_oa_path" in
            /data/adb/modules/*) [ -d "$_oa_path" ] || _oa_path="/data/adb/modules/uperf" ;;
            *) _oa_path="/data/adb/modules/uperf" ;;
        esac
    fi
    printf '%s' "$_oa_path"
}

ensure_powercfg_router() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        mkdir -p "$TEST_RUNTIME_DIR" 2>/dev/null || return 1
        _oa_router_calls=$(cat "$TEST_RUNTIME_DIR/powercfg_router_calls" 2>/dev/null | tr -d ' \r\n\t')
        case "$_oa_router_calls" in ''|*[!0-9]*) _oa_router_calls=0 ;; esac
        printf '%s\n' $((_oa_router_calls + 1)) > "$TEST_RUNTIME_DIR/powercfg_router_calls" 2>/dev/null || return 1
        [ ! -f "$TEST_RUNTIME_DIR/fail_powercfg_router" ] || return 1
        printf 'ready\n' > "$TEST_RUNTIME_DIR/powercfg_router_ready" 2>/dev/null || return 1
        return 0
    fi
    _oa_fas_mod=$(resolve_fas_module_path)
    _oa_router="$_oa_fas_mod/vtools/powercfg.sh"
    [ -s "$_oa_router" ] || return 1
    grep -q '/data/adb/fas_rs/.owner_state' "$_oa_router" 2>/dev/null || return 1
    sh -n "$_oa_router" >/dev/null 2>&1 || return 1
    _oa_router_hash=$(sha256sum "$_oa_router" 2>/dev/null | awk '{print $1}')
    case "$_oa_router_hash" in ''|*[!0-9a-fA-F]*) return 1 ;; esac

    case "$POWERCFG_ENTRY_EXECUTABLE_REQUIRED" in
        yes|no) ;;
        *) return 1 ;;
    esac

    _oa_entry_hash=$(sha256sum "$POWERCFG_ENTRY" 2>/dev/null | awk '{print $1}')
    if [ "$_oa_entry_hash" = "$_oa_router_hash" ]; then
        if [ "$POWERCFG_ENTRY_EXECUTABLE_REQUIRED" = "no" ] || [ -x "$POWERCFG_ENTRY" ]; then
            return 0
        fi
    fi

    [ ! -e "$POWERCFG_ENTRY" ] || [ -f "$POWERCFG_ENTRY" ] || return 1
    _oa_router_tmp="${POWERCFG_ENTRY}.pixel9pro_control.$$"
    _oa_router_backup="${POWERCFG_ENTRY}.pixel9pro_control.prev.$$"
    _oa_router_old_existed=no
    _oa_router_old_hash=""
    _oa_router_old_mode=""
    if [ -f "$POWERCFG_ENTRY" ]; then
        _oa_router_old_existed=yes
        _oa_router_old_hash=$(sha256sum "$POWERCFG_ENTRY" 2>/dev/null | awk '{print $1}')
        _oa_router_old_mode=$(stat -c '%a' "$POWERCFG_ENTRY" 2>/dev/null | tr -d ' \r\n\t')
        case "$_oa_router_old_hash:$_oa_router_old_mode" in
            *[!0-9a-fA-F:]*|:*|*:) return 1 ;;
        esac
        cp -p "$POWERCFG_ENTRY" "$_oa_router_backup" 2>/dev/null || return 1
    fi

    _oa_router_installed=no
    if cp "$_oa_router" "$_oa_router_tmp" 2>/dev/null \
        && { [ "$POWERCFG_ENTRY_EXECUTABLE_REQUIRED" = "no" ] || chmod 0755 "$_oa_router_tmp" 2>/dev/null; } \
        && { [ "$POWERCFG_ENTRY_EXECUTABLE_REQUIRED" = "no" ] || [ -x "$_oa_router_tmp" ]; } \
        && sh -n "$_oa_router_tmp" >/dev/null 2>&1 \
        && [ "$(sha256sum "$_oa_router_tmp" 2>/dev/null | awk '{print $1}')" = "$_oa_router_hash" ] \
        && mv -f "$_oa_router_tmp" "$POWERCFG_ENTRY" 2>/dev/null \
        && { [ "$POWERCFG_ENTRY_EXECUTABLE_REQUIRED" = "no" ] || [ -x "$POWERCFG_ENTRY" ]; } \
        && [ "$(sha256sum "$POWERCFG_ENTRY" 2>/dev/null | awk '{print $1}')" = "$_oa_router_hash" ]; then
        _oa_router_installed=yes
    fi

    if [ "$_oa_router_installed" = "yes" ]; then
        rm -f "$_oa_router_backup" 2>/dev/null
        return 0
    fi

    rm -f "$_oa_router_tmp" 2>/dev/null
    _oa_router_rollback_ok=no
    if [ "$_oa_router_old_existed" = "yes" ]; then
        if mv -f "$_oa_router_backup" "$POWERCFG_ENTRY" 2>/dev/null \
            && chmod "$_oa_router_old_mode" "$POWERCFG_ENTRY" 2>/dev/null \
            && [ "$(sha256sum "$POWERCFG_ENTRY" 2>/dev/null | awk '{print $1}')" = "$_oa_router_old_hash" ]; then
            _oa_router_rollback_ok=yes
        fi
    else
        rm -f "$POWERCFG_ENTRY" 2>/dev/null
        [ ! -e "$POWERCFG_ENTRY" ] && _oa_router_rollback_ok=yes
    fi
    rm -f "$_oa_router_backup" 2>/dev/null
    [ "$_oa_router_rollback_ok" = "yes" ] || APPLY_RESULT="failed_powercfg_router_rollback_incomplete"
    return 1
}

stop_uperf() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        mkdir -p "$TEST_RUNTIME_DIR" 2>/dev/null || return 1
        [ -f "$TEST_RUNTIME_DIR/fail_stop_uperf" ] && return 1
        rm -f "$TEST_RUNTIME_DIR/uperf_alive" 2>/dev/null
        [ -f "$TEST_RUNTIME_DIR/uperf_count" ] && printf '0\n' > "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null
        return 0
    fi
    uperf_process_alive || return 0
    killall uperf 2>/dev/null || true
    for _oa_i in 1 2 3 4 5; do
        uperf_process_alive || return 0
        sleep 1
    done
    return 1
}

start_uperf() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        mkdir -p "$TEST_RUNTIME_DIR" 2>/dev/null || return 1
        acquire_uperf_start_lock || return 1
        if [ -f "$TEST_RUNTIME_DIR/fail_start_uperf" ]; then
            release_uperf_start_lock
            return 1
        fi
        if [ -f "$TEST_RUNTIME_DIR/defer_start_uperf" ]; then
            release_uperf_start_lock
            return 3
        fi
        _oa_test_alive_before=no
        [ -f "$TEST_RUNTIME_DIR/uperf_alive" ] && _oa_test_alive_before=yes
        _oa_test_count_file_before=no
        [ -f "$TEST_RUNTIME_DIR/uperf_count" ] && _oa_test_count_file_before=yes
        _oa_test_count=$(cat "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null | tr -d ' \r\n\t')
        case "$_oa_test_count" in ''|*[!0-9]*) _oa_test_count=0 ;; esac
        _oa_test_normalized_before="$UPERF_NORMALIZED"
        [ "$_oa_test_count" -gt 1 ] 2>/dev/null && UPERF_NORMALIZED="yes"
        if ! printf '1\n' > "$TEST_RUNTIME_DIR/uperf_alive" 2>/dev/null; then
            release_uperf_start_lock
            return 1
        fi
        _oa_test_count_write_ok=yes
        if [ -f "$TEST_RUNTIME_DIR/fail_write_uperf_count_once" ]; then
            rm -f "$TEST_RUNTIME_DIR/fail_write_uperf_count_once" 2>/dev/null
            _oa_test_count_write_ok=no
        elif [ "$_oa_test_count_file_before" = "yes" ] \
            && ! printf '1\n' > "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null; then
            _oa_test_count_write_ok=no
        fi
        if [ "$_oa_test_count_write_ok" != "yes" ]; then
            if [ "$_oa_test_alive_before" = "yes" ]; then
                printf '1\n' > "$TEST_RUNTIME_DIR/uperf_alive" 2>/dev/null || true
            else
                rm -f "$TEST_RUNTIME_DIR/uperf_alive" 2>/dev/null
            fi
            if [ "$_oa_test_count_file_before" = "yes" ]; then
                printf '%s\n' "$_oa_test_count" > "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null || true
            else
                rm -f "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null
            fi
            UPERF_NORMALIZED="$_oa_test_normalized_before"
            release_uperf_start_lock
            return 1
        fi
        release_uperf_start_lock
        return 0
    fi
    uperf_storage_ready || return 3

    if ! acquire_uperf_start_lock; then
        for _oa_i in 1 2 3 4 5 6 7 8; do
            sleep 1
            if uperf_process_alive; then
                _oa_roots=$(uperf_root_instance_count)
                if [ "$_oa_roots" -le 1 ] 2>/dev/null; then
                    uperf_single_instance_stable
                    _oa_stable=$?
                    [ "$_oa_stable" -eq 0 ] && return 0
                    [ "$_oa_stable" -eq 2 ] && break
                else
                    break
                fi
            fi
        done
        acquire_uperf_start_lock || return 1
    fi

    if uperf_process_alive; then
        normalize_uperf_instances
        _oa_norm=$?
        if [ "$_oa_norm" -eq 0 ]; then
            uperf_single_instance_stable
            _oa_stable=$?
            if [ "$_oa_stable" -eq 0 ]; then
                release_uperf_start_lock
                return 0
            fi
            [ "$_oa_stable" -eq 2 ] && normalize_uperf_instances >/dev/null 2>&1 || true
        elif [ "$_oa_norm" -eq 2 ]; then
            release_uperf_start_lock
            return 1
        fi
    fi

    _oa_uperf_mod=$(resolve_uperf_module_path)
    _oa_uperf_lib="$_oa_uperf_mod/script/libuperf.sh"
    if [ ! -f "$_oa_uperf_lib" ]; then
        release_uperf_start_lock
        return 1
    fi

    _oa_start_attempt=1
    while [ "$_oa_start_attempt" -le 2 ] 2>/dev/null; do
        # Runtime restore only calls UGT's process lifecycle helper.  Replaying
        # initsvc.sh would also rerun platform_special/miui_migt/powercfg_once
        # and append another router entry on every game exit.
        sh -c '. "$0"; uperf_start' "$_oa_uperf_lib" >/dev/null 2>&1 &
        for _oa_i in 1 2 3 4 5 6 7 8; do
            sleep 1
            if uperf_process_alive; then
                uperf_single_instance_stable
                _oa_stable=$?
                if [ "$_oa_stable" -eq 0 ]; then
                    release_uperf_start_lock
                    return 0
                elif [ "$_oa_stable" -eq 2 ]; then
                    normalize_uperf_instances >/dev/null 2>&1 || true
                    break
                else
                    release_uperf_start_lock
                    return 1
                fi
            fi
        done
        _oa_start_attempt=$((_oa_start_attempt + 1))
    done
    release_uperf_start_lock
    return 1
}

fas_pid_is_ours() {
    _oa_pid="$1"
    _oa_start="$2"
    fas_identity_matches "$_oa_pid" "$_oa_start" || return 1
    [ "$OWNER_ARBITER_TEST_MODE" = "1" ] && return 0
    _oa_comm=$(cat "/proc/$_oa_pid/comm" 2>/dev/null | tr -d ' \r\n\t')
    [ "$_oa_comm" = "fas-rs" ]
}

cleanup_fas_started_by_transaction() {
    [ "$FAS_STARTED_BY_TRANSACTION" = "yes" ] || return 0
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        fas_pid_is_ours "$FAS_STARTED_PID" "$FAS_STARTED_START_TICKS" || return 0
        rm -f "$TEST_RUNTIME_DIR/fas_alive" "$TEST_RUNTIME_DIR/fas_pid" \
            "$TEST_RUNTIME_DIR/fas_start_ticks" 2>/dev/null
        FAS_STARTED_BY_TRANSACTION="no"
        FAS_STARTED_PID=""
        FAS_STARTED_START_TICKS=""
        return
    fi
    if ! fas_pid_is_ours "$FAS_STARTED_PID" "$FAS_STARTED_START_TICKS"; then
        FAS_STARTED_BY_TRANSACTION="no"
        FAS_STARTED_PID=""
        FAS_STARTED_START_TICKS=""
        return 0
    fi
    kill "$FAS_STARTED_PID" 2>/dev/null || return 1
    for _oa_i in 1 2 3 4 5; do
        if ! fas_pid_is_ours "$FAS_STARTED_PID" "$FAS_STARTED_START_TICKS"; then
            FAS_STARTED_BY_TRANSACTION="no"
            FAS_STARTED_PID=""
            FAS_STARTED_START_TICKS=""
            return 0
        fi
        sleep 1
    done
    return 1
}

stop_fas_lease_instance() {
    _oa_pid="$1"
    _oa_start="$2"
    if ! fas_identity_matches "$_oa_pid" "$_oa_start"; then
        fas_process_alive && return 2
        return 0
    fi
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        [ -f "$TEST_RUNTIME_DIR/fail_stop_fas" ] && return 1
        rm -f "$TEST_RUNTIME_DIR/fas_alive" "$TEST_RUNTIME_DIR/fas_pid" \
            "$TEST_RUNTIME_DIR/fas_start_ticks" 2>/dev/null
        fas_process_alive && return 1
        return 0
    fi
    kill "$_oa_pid" 2>/dev/null || return 1
    for _oa_i in 1 2 3 4 5; do
        if ! fas_identity_matches "$_oa_pid" "$_oa_start"; then
            fas_process_alive && return 2
            return 0
        fi
        sleep 1
    done
    return 1
}

start_fas_rs() {
    if fas_process_alive; then
        return 0
    fi
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        mkdir -p "$TEST_RUNTIME_DIR" 2>/dev/null || return 1
        [ -f "$TEST_RUNTIME_DIR/fail_start_fas" ] && return 1
        _oa_start_count=$(cat "$TEST_RUNTIME_DIR/fas_start_calls" 2>/dev/null | tr -d ' \r\n\t')
        case "$_oa_start_count" in ''|*[!0-9]*) _oa_start_count=0 ;; esac
        printf '%s\n' $((_oa_start_count + 1)) > "$TEST_RUNTIME_DIR/fas_start_calls" 2>/dev/null || return 1
        if [ -f "$TEST_RUNTIME_DIR/require_cap_before_start_fas" ]; then
            _oa_test_cap=$(cat "$UCLAMP_CAP_PATH" 2>/dev/null | tr -d ' \r\n\t')
            printf '%s\n' "$_oa_test_cap" > "$TEST_RUNTIME_DIR/cap_at_fas_start" 2>/dev/null
            [ "$_oa_test_cap" = "$CPU_PROFILE_FULL_CAP" ] || return 1
        fi
        printf '1\n' > "$TEST_RUNTIME_DIR/fas_alive" 2>/dev/null || return 1
        printf '4242\n' > "$TEST_RUNTIME_DIR/fas_pid" 2>/dev/null || return 1
        printf '100\n' > "$TEST_RUNTIME_DIR/fas_start_ticks" 2>/dev/null || return 1
        FAS_STARTED_BY_TRANSACTION="yes"
        FAS_STARTED_PID="4242"
        FAS_STARTED_START_TICKS="100"
        return
    fi

    _oa_fas_mod=$(resolve_fas_module_path)
    _oa_fas_bin="$_oa_fas_mod/fas-rs"
    [ -f "$_oa_fas_bin" ] || return 1

    _oa_fas_std_conf="$_oa_fas_mod/games.toml"
    [ -s "$FAS_ROOT/games.toml" ] || return 1
    [ -s "$_oa_fas_std_conf" ] || return 1

    mkdir -p "$FAS_ROOT" 2>/dev/null || return 1
    write_fas_owner_state "fas-rs:starting-arbiter" || return 1
    RUST_BACKTRACE=1 nohup "$_oa_fas_bin" run "$_oa_fas_std_conf" >>"$FAS_LOG_FILE" 2>&1 &
    _oa_spawn_pid=$!
    case "$_oa_spawn_pid" in ''|*[!0-9]*) return 1 ;; esac
    FAS_STARTED_BY_TRANSACTION="yes"
    FAS_STARTED_PID="$_oa_spawn_pid"
    FAS_STARTED_START_TICKS=$(process_start_ticks "$_oa_spawn_pid")
    case "$FAS_STARTED_START_TICKS" in ''|*[!0-9]*) return 1 ;; esac
    for _oa_i in 1 2 3 4 5; do
        sleep 1
        fas_pid_is_ours "$FAS_STARTED_PID" "$FAS_STARTED_START_TICKS" && return 0
    done
    return 1
}
