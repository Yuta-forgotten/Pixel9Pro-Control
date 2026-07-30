#!/system/bin/sh

# owner arbiter 的进程、游戏列表与运行态观测。

first_word() {
    set -- $1
    printf '%s' "$1"
}

pkg_pids() {
    _oa_pkg="$1"
    [ -n "$_oa_pkg" ] || return 0

    _oa_pids=$(pidof "$_oa_pkg" 2>/dev/null)
    if [ -z "$_oa_pids" ]; then
        _oa_pids=$(ps -A 2>/dev/null | awk -v p="$_oa_pkg" '
            NR > 1 {
                name = $NF
                if (name == p || index(name, p ":") == 1) {
                    printf "%s ", $2
                }
            }
        ')
    fi
    printf '%s' "$_oa_pids" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g;s/^ //;s/ $//'
}

game_source_kind() {
    case "$1" in
        "$LEASE_GAME_LIST") printf 'lease_list' ;;
        "$SCENE_PROFILE") printf 'scene_games_xml' ;;
        *.toml) printf 'games_toml' ;;
        *) printf 'unknown' ;;
    esac
}

primary_games_toml_path() {
    for _oa_file in "$FAS_ROOT/games.toml"; do
        [ -s "$_oa_file" ] || continue
        printf '%s' "$_oa_file"
        return 0
    done

    case "$FAS_RS_MODULE_PATH" in
        /data/adb/modules/*)
            if [ -s "$FAS_RS_MODULE_PATH/games.toml" ]; then
                printf '%s' "$FAS_RS_MODULE_PATH/games.toml"
                return 0
            fi
            ;;
    esac

    if [ -s /data/adb/modules/fas_rs/games.toml ]; then
        printf '%s' /data/adb/modules/fas_rs/games.toml
        return 0
    fi

    return 1
}

package_in_lease_list() {
    _oa_pkg="$1"
    [ -n "$_oa_pkg" ] && [ -s "$LEASE_GAME_LIST" ] || return 1
    awk -v p="$_oa_pkg" '$0 == p { found = 1 } END { exit(found ? 0 : 1) }' "$LEASE_GAME_LIST" 2>/dev/null
}

package_in_games_toml() {
    _oa_pkg="$1"
    _oa_source="$2"
    [ -n "$_oa_pkg" ] && [ -s "$_oa_source" ] || return 1

    awk -v p="$_oa_pkg" '
        /^[[:space:]]*\[game_list\][[:space:]]*$/ { in_game = 1; next }
        /^[[:space:]]*\[/ { in_game = 0 }
        in_game && /^[[:space:]]*"/ {
            line = $0
            sub(/^[[:space:]]*"/, "", line)
            sub(/".*/, "", line)
            if (line == p) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$_oa_source" 2>/dev/null
}

package_excluded_by_games_toml() {
    _oa_pkg="$1"
    _oa_source="$2"
    [ -n "$_oa_pkg" ] && [ -s "$_oa_source" ] || return 1

    awk -v p="$_oa_pkg" '
        /^[[:space:]]*\[config\][[:space:]]*$/ { in_config = 1; next }
        /^[[:space:]]*\[/ { in_config = 0 }
        in_config && /^[[:space:]]*exclude_list[[:space:]]*=/ {
            line = $0
            sub(/^[^[]*\[/, "", line)
            sub(/\].*$/, "", line)
            n = split(line, items, ",")
            for (i = 1; i <= n; i++) {
                item = items[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
                gsub(/^"|"$/, "", item)
                if (item == p) found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$_oa_source" 2>/dev/null
}

scene_game_list_enabled_by_toml() {
    _oa_source="$1"
    [ -s "$_oa_source" ] || return 1

    awk '
        BEGIN { seen = 0; enabled = 1 }
        /^[[:space:]]*\[config\][[:space:]]*$/ { in_config = 1; next }
        /^[[:space:]]*\[/ { in_config = 0 }
        in_config && /^[[:space:]]*scene_game_list[[:space:]]*=/ {
            seen = 1
            line = $0
            sub(/^[^=]*=/, "", line)
            gsub(/[[:space:]]|"/, "", line)
            if (line == "false") enabled = 0
            else enabled = 1
        }
        END { exit(enabled ? 0 : 1) }
    ' "$_oa_source" 2>/dev/null
}

package_in_scene_profile() {
    _oa_pkg="$1"
    [ -n "$_oa_pkg" ] && [ -s "$SCENE_PROFILE" ] || return 1

    awk -v p="$_oa_pkg" '
        /<boolean/ && /value="true"/ {
            line = $0
            sub(/^.*name="/, "", line)
            sub(/".*$/, "", line)
            if (line == p) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$SCENE_PROFILE" 2>/dev/null
}

package_matches_fas_target() {
    _oa_pkg="$1"
    GAME_SOURCE="none"
    [ -n "$_oa_pkg" ] || return 1

    _oa_toml=$(primary_games_toml_path 2>/dev/null)

    if [ -n "$_oa_toml" ] && package_excluded_by_games_toml "$_oa_pkg" "$_oa_toml"; then
        GAME_SOURCE="$(game_source_kind "$_oa_toml"):exclude_list"
        return 1
    fi

    if package_in_lease_list "$_oa_pkg"; then
        GAME_SOURCE="$LEASE_GAME_LIST"
        return 0
    fi

    if [ -n "$_oa_toml" ] && package_in_games_toml "$_oa_pkg" "$_oa_toml"; then
        GAME_SOURCE="$_oa_toml"
        return 0
    fi

    if [ -n "$_oa_toml" ] && scene_game_list_enabled_by_toml "$_oa_toml" && package_in_scene_profile "$_oa_pkg"; then
        GAME_SOURCE="$SCENE_PROFILE"
        return 0
    fi

    if [ -n "$_oa_toml" ]; then
        GAME_SOURCE="$_oa_toml"
    fi
    return 1
}

fas_handoff_available() {
    [ "$FAS_RS_DETECTED" = "yes" ] || return 1
    [ "$FAS_RS_MODULE_ENABLED" = "yes" ] || return 1
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        [ ! -f "$TEST_RUNTIME_DIR/fas_payload_incomplete" ] || return 1
        return 0
    fi
    [ "$FAS_RS_MODULE_SOURCE" = "modules" ] || return 1
    [ "$(scheduler_module_state "$FAS_RS_MODULE_PATH" "$FAS_RS_MODULE_SOURCE")" = "active" ] || return 1
    [ -f "$FAS_RS_MODULE_PATH/fas-rs" ] || return 1
    [ -s "$FAS_RS_MODULE_PATH/games.toml" ] || return 1
    _oa_payload_router="$FAS_RS_MODULE_PATH/vtools/powercfg.sh"
    [ -s "$_oa_payload_router" ] || return 1
    grep -q '/data/adb/fas_rs/.owner_state' "$_oa_payload_router" 2>/dev/null || return 1
    sh -n "$_oa_payload_router" >/dev/null 2>&1 || return 1
    return 0
}

process_alive() {
    _oa_proc="$1"
    pidof "$_oa_proc" >/dev/null 2>&1 && return 0
    ps -A 2>/dev/null | grep -E "(^|[[:space:]])${_oa_proc}([[:space:]]|$)" | grep -v grep >/dev/null 2>&1
}

pid_alive() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$1" ]
}

process_start_ticks() {
    _oa_pid="$1"
    case "$_oa_pid" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        _oa_test_pid=$(cat "$TEST_RUNTIME_DIR/fas_pid" 2>/dev/null | tr -d ' \r\n\t')
        [ -n "$_oa_test_pid" ] || _oa_test_pid=4242
        [ "$_oa_pid" = "$_oa_test_pid" ] || return 1
        _oa_test_ticks=$(cat "$TEST_RUNTIME_DIR/fas_start_ticks" 2>/dev/null | tr -d ' \r\n\t')
        case "$_oa_test_ticks" in ''|*[!0-9]*) _oa_test_ticks=100 ;; esac
        printf '%s' "$_oa_test_ticks"
        return 0
    fi
    sed 's/^[^)]*) //' "/proc/$_oa_pid/stat" 2>/dev/null | awk '{print $20}'
}

uperf_process_alive() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        if [ -f "$TEST_RUNTIME_DIR/uperf_count" ]; then
            _oa_test_count=$(cat "$TEST_RUNTIME_DIR/uperf_count" 2>/dev/null | tr -d ' \r\n\t')
            case "$_oa_test_count" in ''|*[!0-9]*) return 1 ;; esac
            [ "$_oa_test_count" -gt 0 ] 2>/dev/null
            return
        fi
        [ -f "$TEST_RUNTIME_DIR/uperf_alive" ]
        return
    fi
    process_alive "uperf"
}

fas_process_alive() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        [ -f "$TEST_RUNTIME_DIR/fas_alive" ]
        return
    fi
    process_alive "fas-rs"
}

fas_process_pids() {
    if [ "$OWNER_ARBITER_TEST_MODE" = "1" ]; then
        fas_process_alive || return 0
        _oa_test_pid=$(cat "$TEST_RUNTIME_DIR/fas_pid" 2>/dev/null | tr -d ' \r\n\t')
        [ -n "$_oa_test_pid" ] || _oa_test_pid=4242
        printf '%s' "$_oa_test_pid"
        return 0
    fi
    pidof fas-rs 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g;s/^ //;s/ $//'
}

fas_primary_pid() {
    _oa_pids=$(fas_process_pids)
    first_word "$_oa_pids"
}

fas_identity_matches() {
    _oa_pid="$1"
    _oa_start="$2"
    case "$_oa_pid:$_oa_start" in
        *[!0-9:]*|:*|*:) return 1 ;;
    esac
    fas_process_alive || return 1
    _oa_live_start=$(process_start_ticks "$_oa_pid")
    [ -n "$_oa_live_start" ] && [ "$_oa_live_start" = "$_oa_start" ]
}

fas_game_lease_target() {
    _oa_fas_owner=$(cat "$FAS_OWNER_FILE" 2>/dev/null | tr -d '\r\n')
    scheduler_fas_owner_target "$_oa_fas_owner"
}

fas_game_lease_active() {
    fas_process_alive || return 1
    fas_game_lease_target >/dev/null 2>&1
}
