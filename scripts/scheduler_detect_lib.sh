#!/system/bin/sh
# Shared scheduler detection contract.
# Detects external CPU schedulers without suggesting installation.
# Uperf-named fields remain a stable compatibility contract for the WebUI.

SCHEDULER_MODULES_ROOT="${SCHEDULER_MODULES_ROOT:-/data/adb/modules}"
SCHEDULER_MODULES_UPDATE_ROOT="${SCHEDULER_MODULES_UPDATE_ROOT:-/data/adb/modules_update}"
SCHEDULER_FAS_RUNTIME_ROOT="${SCHEDULER_FAS_RUNTIME_ROOT:-/data/adb/fas_rs}"
SCHEDULER_FAS_MODE_PATH="${SCHEDULER_FAS_MODE_PATH:-/dev/fas_rs/mode}"
SCHEDULER_TEST_MODE="${SCHEDULER_TEST_MODE:-0}"
SCHEDULER_TEST_RUNTIME_ROOT="${SCHEDULER_TEST_RUNTIME_ROOT:-}"
SCHEDULER_INVENTORY_PATH="${SCHEDULER_INVENTORY_PATH:-/data/adb/modules/pixel9pro_control/.scheduler_inventory}"
SCHEDULER_INVENTORY_SCHEMA=1
SCHEDULER_INVENTORY_STATUS="unloaded"

UPERF_DETECTED="no"
UPERF_MODULE_ID=""
UPERF_MODULE_NAME=""
UPERF_MODULE_PATH=""
UPERF_MODULE_SOURCE=""
UPERF_MODULE_STATE=""
UPERF_MODULE_ENABLED="no"
UPERF_PROCESS_ALIVE="no"
UPERF_ACTIVE="no"

FAS_RS_DETECTED="no"
FAS_RS_MODULE_ID=""
FAS_RS_MODULE_NAME=""
FAS_RS_MODULE_PATH=""
FAS_RS_MODULE_SOURCE=""
FAS_RS_MODULE_STATE=""
FAS_RS_MODULE_ENABLED="no"
FAS_RS_RUNTIME_ROOT=""
FAS_RS_OWNER_STATE=""
FAS_RS_MODE=""
FAS_RS_PROCESS_ALIVE="no"
FAS_RS_RUNTIME_STATE=""
FAS_RS_ACTIVE="no"
FAS_RS_RUNTIME_OWNER_ACTIVE="no"
FAS_RS_RUNTIME_TARGET=""

EXTERNAL_SCHEDULER_DETECTED="no"
EXTERNAL_SCHEDULER_ID=""
EXTERNAL_SCHEDULER_NAME=""
EXTERNAL_SCHEDULER_KIND=""
EXTERNAL_SCHEDULER_PATH=""
EXTERNAL_SCHEDULER_SOURCE=""
EXTERNAL_SCHEDULER_STATE=""
EXTERNAL_SCHEDULER_ENABLED="no"
EXTERNAL_SCHEDULER_ACTIVE="no"

reset_uperf_detection() {
    UPERF_DETECTED="no"
    UPERF_MODULE_ID=""
    UPERF_MODULE_NAME=""
    UPERF_MODULE_PATH=""
    UPERF_MODULE_SOURCE=""
    UPERF_MODULE_STATE=""
    UPERF_MODULE_ENABLED="no"
    UPERF_PROCESS_ALIVE="no"
    UPERF_ACTIVE="no"
}

reset_fas_rs_detection() {
    FAS_RS_DETECTED="no"
    FAS_RS_MODULE_ID=""
    FAS_RS_MODULE_NAME=""
    FAS_RS_MODULE_PATH=""
    FAS_RS_MODULE_SOURCE=""
    FAS_RS_MODULE_STATE=""
    FAS_RS_MODULE_ENABLED="no"
    FAS_RS_RUNTIME_ROOT=""
    FAS_RS_OWNER_STATE=""
    FAS_RS_MODE=""
    FAS_RS_PROCESS_ALIVE="no"
    FAS_RS_RUNTIME_STATE=""
    FAS_RS_ACTIVE="no"
    FAS_RS_RUNTIME_OWNER_ACTIVE="no"
    FAS_RS_RUNTIME_TARGET=""
}

reset_external_scheduler_detection() {
    EXTERNAL_SCHEDULER_DETECTED="no"
    EXTERNAL_SCHEDULER_ID=""
    EXTERNAL_SCHEDULER_NAME=""
    EXTERNAL_SCHEDULER_KIND=""
    EXTERNAL_SCHEDULER_PATH=""
    EXTERNAL_SCHEDULER_SOURCE=""
    EXTERNAL_SCHEDULER_STATE=""
    EXTERNAL_SCHEDULER_ENABLED="no"
    EXTERNAL_SCHEDULER_ACTIVE="no"
}

read_module_prop_value() {
    _sd_key="$1"
    _sd_prop="$2"
    if [ -n "${SCHEDULER_TEST_SCAN_COUNTER_PATH:-}" ]; then
        _sd_scan_count=$(cat "$SCHEDULER_TEST_SCAN_COUNTER_PATH" 2>/dev/null | tr -d ' \r\n\t')
        case "$_sd_scan_count" in ''|*[!0-9]*) _sd_scan_count=0 ;; esac
        printf '%s\n' $((_sd_scan_count + 1)) > "$SCHEDULER_TEST_SCAN_COUNTER_PATH" 2>/dev/null || true
    fi
    sed -n "s/^${_sd_key}=//p" "$_sd_prop" 2>/dev/null | head -n 1 | tr -d '\r'
}

scheduler_module_source() {
    case "$1" in
        "$SCHEDULER_MODULES_UPDATE_ROOT"/*) printf '%s' "modules_update" ;;
        "$SCHEDULER_MODULES_ROOT"/*)        printf '%s' "modules" ;;
        *)                          printf '%s' "runtime" ;;
    esac
}

scheduler_module_state() {
    _sd_path="$1"
    _sd_source="$2"
    if [ -f "$_sd_path/remove" ]; then
        printf '%s' "pending_remove"
    elif [ -f "$_sd_path/disable" ]; then
        printf '%s' "disabled"
    elif [ "$_sd_source" = "modules_update" ]; then
        printf '%s' "pending_update"
    else
        printf '%s' "active"
    fi
}

scheduler_state_enabled() {
    case "$1" in
        active|running|module_enabled|runtime_present) return 0 ;;
        *) return 1 ;;
    esac
}

scheduler_process_alive() {
    _sd_proc="$1"
    if [ "$SCHEDULER_TEST_MODE" = "1" ] && [ -n "$SCHEDULER_TEST_RUNTIME_ROOT" ]; then
        [ -f "$SCHEDULER_TEST_RUNTIME_ROOT/${_sd_proc}_alive" ]
        return
    fi
    pidof "$_sd_proc" >/dev/null 2>&1 && return 0
    ps -A 2>/dev/null | grep -E "(^|[[:space:]])${_sd_proc}([[:space:]]|$)" | grep -v grep >/dev/null 2>&1
}

# fas-rs is resident throughout a verified Pixel boot.  A live process only
# proves residency; runtime ownership requires an exact, valid game lease.
scheduler_fas_owner_target() {
    _sd_owner_state="$1"
    case "$_sd_owner_state" in
        fas-rs:game:*) _sd_owner_target=${_sd_owner_state#fas-rs:game:} ;;
        *) return 1 ;;
    esac
    case "$_sd_owner_target" in
        ''|.*|*.|*[!A-Za-z0-9._-]*) return 1 ;;
        *.*) ;;
        *) return 1 ;;
    esac
    printf '%s' "$_sd_owner_target"
}

scheduler_fas_owner_lease_active() {
    [ "$2" = "yes" ] || return 1
    scheduler_fas_owner_target "$1" >/dev/null 2>&1
}

is_uperf_module_prop() {
    _sd_prop="$1"
    _sd_id=$(read_module_prop_value id "$_sd_prop")
    _sd_name=$(read_module_prop_value name "$_sd_prop")
    _sd_desc=$(read_module_prop_value description "$_sd_prop")
    [ "$_sd_id" = "uperf" ] && return 0

    _sd_text=$(printf '%s\n%s\n%s\n' "$_sd_id" "$_sd_name" "$_sd_desc" | tr '[:upper:]' '[:lower:]')
    printf '%s' "$_sd_text" | grep -q 'uperf' || return 1
    printf '%s' "$_sd_text" | grep -q 'game turbo' || return 1
    return 0
}

discover_uperf_module_inventory() {
    reset_uperf_detection

    for _sd_prop in "$SCHEDULER_MODULES_ROOT"/*/module.prop "$SCHEDULER_MODULES_UPDATE_ROOT"/*/module.prop; do
        [ -f "$_sd_prop" ] || continue
        is_uperf_module_prop "$_sd_prop" || continue

        UPERF_DETECTED="yes"
        UPERF_MODULE_PATH="${_sd_prop%/module.prop}"
        UPERF_MODULE_ID=$(read_module_prop_value id "$_sd_prop")
        UPERF_MODULE_NAME=$(read_module_prop_value name "$_sd_prop")
        [ -n "$UPERF_MODULE_ID" ] || UPERF_MODULE_ID="${UPERF_MODULE_PATH##*/}"
        [ -n "$UPERF_MODULE_NAME" ] || UPERF_MODULE_NAME="$UPERF_MODULE_ID"

        UPERF_MODULE_SOURCE=$(scheduler_module_source "$UPERF_MODULE_PATH")
        break
    done

    [ "$UPERF_DETECTED" = "yes" ]
}

refresh_uperf_runtime() {
    UPERF_PROCESS_ALIVE="no"
    UPERF_ACTIVE="no"
    if [ "$UPERF_DETECTED" = "yes" ] && [ -n "$UPERF_MODULE_PATH" ]; then
        UPERF_MODULE_STATE=$(scheduler_module_state "$UPERF_MODULE_PATH" "$UPERF_MODULE_SOURCE")
        if scheduler_state_enabled "$UPERF_MODULE_STATE"; then
            UPERF_MODULE_ENABLED="yes"
        else
            UPERF_MODULE_ENABLED="no"
        fi
    fi

    if scheduler_process_alive "uperf"; then
        UPERF_PROCESS_ALIVE="yes"
        UPERF_ACTIVE="yes"
        UPERF_DETECTED="yes"
        [ -n "$UPERF_MODULE_ID" ] || UPERF_MODULE_ID="uperf"
        [ -n "$UPERF_MODULE_NAME" ] || UPERF_MODULE_NAME="Uperf Game Turbo"
        [ -n "$UPERF_MODULE_PATH" ] || UPERF_MODULE_PATH="runtime"
        [ -n "$UPERF_MODULE_SOURCE" ] || UPERF_MODULE_SOURCE="runtime"
        if [ -z "$UPERF_MODULE_STATE" ]; then
            UPERF_MODULE_STATE="running"
            UPERF_MODULE_ENABLED="yes"
        fi
    fi

    [ "$UPERF_DETECTED" = "yes" ] || return 1
    return 0
}

detect_uperf_module() {
    discover_uperf_module_inventory >/dev/null 2>&1 || true
    refresh_uperf_runtime
}

is_fas_rs_module_prop() {
    _sd_prop="$1"
    _sd_id=$(read_module_prop_value id "$_sd_prop")
    _sd_name=$(read_module_prop_value name "$_sd_prop")
    _sd_desc=$(read_module_prop_value description "$_sd_prop")
    case "$_sd_id" in
        fas_rs|fas-rs) return 0 ;;
    esac

    _sd_text=$(printf '%s\n%s\n%s\n' "$_sd_id" "$_sd_name" "$_sd_desc" | tr '[:upper:]' '[:lower:]')
    printf '%s' "$_sd_text" | grep -q 'fas-rs' && return 0
    printf '%s' "$_sd_text" | grep -q 'fas_rs' && return 0
    printf '%s' "$_sd_text" | grep -q 'frame' && printf '%s' "$_sd_text" | grep -q 'aware' && return 0
    return 1
}

discover_fas_rs_inventory() {
    reset_fas_rs_detection
    FAS_RS_RUNTIME_ROOT="$SCHEDULER_FAS_RUNTIME_ROOT"

    for _sd_prop in "$SCHEDULER_MODULES_ROOT"/*/module.prop "$SCHEDULER_MODULES_UPDATE_ROOT"/*/module.prop; do
        [ -f "$_sd_prop" ] || continue
        is_fas_rs_module_prop "$_sd_prop" || continue

        FAS_RS_DETECTED="yes"
        FAS_RS_MODULE_PATH="${_sd_prop%/module.prop}"
        FAS_RS_MODULE_ID=$(read_module_prop_value id "$_sd_prop")
        FAS_RS_MODULE_NAME=$(read_module_prop_value name "$_sd_prop")
        [ -n "$FAS_RS_MODULE_ID" ] || FAS_RS_MODULE_ID="${FAS_RS_MODULE_PATH##*/}"
        [ -n "$FAS_RS_MODULE_NAME" ] || FAS_RS_MODULE_NAME="fas-rs"

        FAS_RS_MODULE_SOURCE=$(scheduler_module_source "$FAS_RS_MODULE_PATH")
        break
    done

    [ "$FAS_RS_DETECTED" = "yes" ]
}

refresh_fas_rs_runtime() {
    FAS_RS_RUNTIME_ROOT="$SCHEDULER_FAS_RUNTIME_ROOT"
    FAS_RS_OWNER_STATE=""
    FAS_RS_MODE=""
    FAS_RS_PROCESS_ALIVE="no"
    FAS_RS_RUNTIME_STATE=""
    FAS_RS_ACTIVE="no"
    FAS_RS_RUNTIME_OWNER_ACTIVE="no"
    FAS_RS_RUNTIME_TARGET=""

    if [ "$FAS_RS_DETECTED" = "yes" ] && [ -n "$FAS_RS_MODULE_PATH" ]; then
        FAS_RS_MODULE_STATE=$(scheduler_module_state "$FAS_RS_MODULE_PATH" "$FAS_RS_MODULE_SOURCE")
        if scheduler_state_enabled "$FAS_RS_MODULE_STATE"; then
            FAS_RS_MODULE_ENABLED="yes"
        else
            FAS_RS_MODULE_ENABLED="no"
        fi
    fi

    if scheduler_process_alive "fas-rs"; then
        FAS_RS_PROCESS_ALIVE="yes"
        FAS_RS_DETECTED="yes"
    fi

    [ -s "$FAS_RS_RUNTIME_ROOT/.owner_state" ] && FAS_RS_OWNER_STATE=$(head -n 1 "$FAS_RS_RUNTIME_ROOT/.owner_state" 2>/dev/null | tr -d '\r')
    if [ -e "$SCHEDULER_FAS_MODE_PATH" ]; then
        FAS_RS_MODE=$(head -n 1 "$SCHEDULER_FAS_MODE_PATH" 2>/dev/null | tr -d ' \r\n\t')
        FAS_RS_DETECTED="yes"
    fi
    if _sd_fas_target=$(scheduler_fas_owner_target "$FAS_RS_OWNER_STATE" 2>/dev/null); then
        FAS_RS_RUNTIME_TARGET="$_sd_fas_target"
        if scheduler_fas_owner_lease_active "$FAS_RS_OWNER_STATE" "$FAS_RS_PROCESS_ALIVE"; then
            FAS_RS_RUNTIME_OWNER_ACTIVE="yes"
        fi
    fi

    # The control module also owns /data/adb/fas_rs arbiter state. A runtime
    # directory or stale .owner_state alone is not proof that fas-rs is
    # installed. Only a module, live process, or /dev/fas_rs mode interface
    # may expose fas-rs-specific UI and handoff controls.
    if [ "$FAS_RS_DETECTED" = "yes" ]; then
        [ -n "$FAS_RS_MODULE_ID" ] || FAS_RS_MODULE_ID="fas_rs"
        [ -n "$FAS_RS_MODULE_NAME" ] || FAS_RS_MODULE_NAME="fas-rs"
        [ -n "$FAS_RS_MODULE_PATH" ] || FAS_RS_MODULE_PATH="$FAS_RS_RUNTIME_ROOT"
        [ -n "$FAS_RS_MODULE_SOURCE" ] || FAS_RS_MODULE_SOURCE="runtime"
    fi

    [ "$FAS_RS_DETECTED" = "yes" ] || return 1

    if [ -f "$FAS_RS_RUNTIME_ROOT/.disable" ]; then
        FAS_RS_RUNTIME_STATE="disabled_marker"
        FAS_RS_MODULE_ENABLED="no"
        FAS_RS_ACTIVE="no"
    elif [ "$FAS_RS_RUNTIME_OWNER_ACTIVE" = "yes" ]; then
        FAS_RS_RUNTIME_STATE="game_lease_active"
        FAS_RS_MODULE_ENABLED="yes"
        FAS_RS_ACTIVE="yes"
    elif [ "$FAS_RS_PROCESS_ALIVE" = "yes" ]; then
        FAS_RS_RUNTIME_STATE="resident_idle"
        FAS_RS_MODULE_ENABLED="yes"
        FAS_RS_ACTIVE="no"
    elif [ -n "$FAS_RS_RUNTIME_TARGET" ]; then
        FAS_RS_RUNTIME_STATE="stale_game_lease"
        FAS_RS_ACTIVE="no"
    elif [ -n "$FAS_RS_OWNER_STATE" ]; then
        FAS_RS_RUNTIME_STATE="stale_owner_state"
        FAS_RS_ACTIVE="no"
    elif [ "$FAS_RS_MODULE_ENABLED" = "yes" ]; then
        FAS_RS_RUNTIME_STATE="module_enabled"
        FAS_RS_ACTIVE="no"
    elif [ -n "$FAS_RS_MODE" ]; then
        FAS_RS_RUNTIME_STATE="runtime_present"
        FAS_RS_ACTIVE="no"
    else
        [ -n "$FAS_RS_RUNTIME_STATE" ] || FAS_RS_RUNTIME_STATE="${FAS_RS_MODULE_STATE:-detected}"
        FAS_RS_ACTIVE="no"
    fi

    [ -n "$FAS_RS_MODULE_STATE" ] || FAS_RS_MODULE_STATE="$FAS_RS_RUNTIME_STATE"
    return 0
}

detect_fas_rs_scheduler() {
    discover_fas_rs_inventory >/dev/null 2>&1 || true
    refresh_fas_rs_runtime
}

scheduler_inventory_value() {
    printf '%s' "$1" | tr '\r\n' '  '
}

scheduler_write_inventory() {
    _sd_inventory_dir=${SCHEDULER_INVENTORY_PATH%/*}
    _sd_inventory_tmp="${SCHEDULER_INVENTORY_PATH}.$$"
    [ -n "$SCHEDULER_INVENTORY_PATH" ] && [ ! -d "$SCHEDULER_INVENTORY_PATH" ] || return 1
    [ -d "$_sd_inventory_dir" ] || mkdir -p "$_sd_inventory_dir" 2>/dev/null || return 1
    {
        printf 'schema=%s\n' "$SCHEDULER_INVENTORY_SCHEMA"
        printf 'uperf_detected=%s\n' "$UPERF_DETECTED"
        printf 'uperf_id=%s\n' "$(scheduler_inventory_value "$UPERF_MODULE_ID")"
        printf 'uperf_name=%s\n' "$(scheduler_inventory_value "$UPERF_MODULE_NAME")"
        printf 'uperf_path=%s\n' "$(scheduler_inventory_value "$UPERF_MODULE_PATH")"
        printf 'uperf_source=%s\n' "$UPERF_MODULE_SOURCE"
        printf 'fas_detected=%s\n' "$FAS_RS_DETECTED"
        printf 'fas_id=%s\n' "$(scheduler_inventory_value "$FAS_RS_MODULE_ID")"
        printf 'fas_name=%s\n' "$(scheduler_inventory_value "$FAS_RS_MODULE_NAME")"
        printf 'fas_path=%s\n' "$(scheduler_inventory_value "$FAS_RS_MODULE_PATH")"
        printf 'fas_source=%s\n' "$FAS_RS_MODULE_SOURCE"
    } > "$_sd_inventory_tmp" 2>/dev/null \
        && mv "$_sd_inventory_tmp" "$SCHEDULER_INVENTORY_PATH" 2>/dev/null \
        && [ -f "$SCHEDULER_INVENTORY_PATH" ] && return 0
    rm -f "$_sd_inventory_tmp" 2>/dev/null
    return 1
}

scheduler_inventory_path_valid() {
    _sd_path="$1"
    _sd_detected="$2"
    if [ "$_sd_detected" = "no" ]; then
        [ -z "$_sd_path" ]
        return
    fi
    case "$_sd_path" in
        "$SCHEDULER_MODULES_ROOT"/*|"$SCHEDULER_MODULES_UPDATE_ROOT"/*)
            [ -f "$_sd_path/module.prop" ]
            ;;
        *) return 1 ;;
    esac
}

scheduler_load_inventory() {
    reset_uperf_detection
    reset_fas_rs_detection
    reset_external_scheduler_detection
    SCHEDULER_INVENTORY_STATUS="invalid"
    [ -s "$SCHEDULER_INVENTORY_PATH" ] || {
        SCHEDULER_INVENTORY_STATUS="missing"
        return 1
    }

    _sd_schema=""
    while IFS='=' read -r _sd_key _sd_value; do
        case "$_sd_key" in
            schema) _sd_schema="$_sd_value" ;;
            uperf_detected) UPERF_DETECTED="$_sd_value" ;;
            uperf_id) UPERF_MODULE_ID="$_sd_value" ;;
            uperf_name) UPERF_MODULE_NAME="$_sd_value" ;;
            uperf_path) UPERF_MODULE_PATH="$_sd_value" ;;
            uperf_source) UPERF_MODULE_SOURCE="$_sd_value" ;;
            fas_detected) FAS_RS_DETECTED="$_sd_value" ;;
            fas_id) FAS_RS_MODULE_ID="$_sd_value" ;;
            fas_name) FAS_RS_MODULE_NAME="$_sd_value" ;;
            fas_path) FAS_RS_MODULE_PATH="$_sd_value" ;;
            fas_source) FAS_RS_MODULE_SOURCE="$_sd_value" ;;
        esac
    done < "$SCHEDULER_INVENTORY_PATH"

    [ "$_sd_schema" = "$SCHEDULER_INVENTORY_SCHEMA" ] || return 1
    case "$UPERF_DETECTED:$FAS_RS_DETECTED" in
        yes:yes|yes:no|no:yes|no:no) ;;
        *) return 1 ;;
    esac
    scheduler_inventory_path_valid "$UPERF_MODULE_PATH" "$UPERF_DETECTED" || return 1
    scheduler_inventory_path_valid "$FAS_RS_MODULE_PATH" "$FAS_RS_DETECTED" || return 1
    case "$UPERF_MODULE_SOURCE" in modules|modules_update|'') ;; *) return 1 ;; esac
    case "$FAS_RS_MODULE_SOURCE" in modules|modules_update|'') ;; *) return 1 ;; esac
    FAS_RS_RUNTIME_ROOT="$SCHEDULER_FAS_RUNTIME_ROOT"
    SCHEDULER_INVENTORY_STATUS="ready"
    return 0
}

compose_external_scheduler() {
    reset_external_scheduler_detection

    if [ "$UPERF_DETECTED" = "yes" ]; then _sd_uperf_found=1; else _sd_uperf_found=0; fi
    if [ "$FAS_RS_DETECTED" = "yes" ]; then _sd_fas_found=1; else _sd_fas_found=0; fi

    [ "$_sd_uperf_found" -eq 1 ] || [ "$_sd_fas_found" -eq 1 ] || return 1

    EXTERNAL_SCHEDULER_DETECTED="yes"

    if [ "$UPERF_ACTIVE" = "yes" ] && [ "$FAS_RS_ACTIVE" = "yes" ]; then
        EXTERNAL_SCHEDULER_ID="multiple"
        EXTERNAL_SCHEDULER_NAME="${UPERF_MODULE_NAME:-Uperf Game Turbo} / ${FAS_RS_MODULE_NAME:-fas-rs}"
        EXTERNAL_SCHEDULER_KIND="multiple"
        EXTERNAL_SCHEDULER_PATH="${UPERF_MODULE_PATH};${FAS_RS_MODULE_PATH}"
        EXTERNAL_SCHEDULER_SOURCE="${UPERF_MODULE_SOURCE};${FAS_RS_MODULE_SOURCE}"
        EXTERNAL_SCHEDULER_STATE="active"
        EXTERNAL_SCHEDULER_ENABLED="yes"
        EXTERNAL_SCHEDULER_ACTIVE="yes"
        return 0
    fi

    if [ "$UPERF_ACTIVE" = "yes" ]; then
        EXTERNAL_SCHEDULER_ID="${UPERF_MODULE_ID:-uperf}"
        EXTERNAL_SCHEDULER_NAME="${UPERF_MODULE_NAME:-Uperf Game Turbo}"
        EXTERNAL_SCHEDULER_KIND="uperf"
        EXTERNAL_SCHEDULER_PATH="$UPERF_MODULE_PATH"
        EXTERNAL_SCHEDULER_SOURCE="$UPERF_MODULE_SOURCE"
        EXTERNAL_SCHEDULER_STATE="$UPERF_MODULE_STATE"
        EXTERNAL_SCHEDULER_ENABLED="yes"
        EXTERNAL_SCHEDULER_ACTIVE="yes"
        return 0
    fi

    if [ "$FAS_RS_ACTIVE" = "yes" ]; then
        EXTERNAL_SCHEDULER_ID="${FAS_RS_MODULE_ID:-fas_rs}"
        EXTERNAL_SCHEDULER_NAME="${FAS_RS_MODULE_NAME:-fas-rs}"
        EXTERNAL_SCHEDULER_KIND="fas_rs"
        EXTERNAL_SCHEDULER_PATH="$FAS_RS_MODULE_PATH"
        EXTERNAL_SCHEDULER_SOURCE="$FAS_RS_MODULE_SOURCE"
        EXTERNAL_SCHEDULER_STATE="$FAS_RS_RUNTIME_STATE"
        EXTERNAL_SCHEDULER_ENABLED="yes"
        EXTERNAL_SCHEDULER_ACTIVE="yes"
        return 0
    fi

    if [ "$FAS_RS_RUNTIME_OWNER_ACTIVE" = "yes" ]; then
        EXTERNAL_SCHEDULER_ID="${FAS_RS_MODULE_ID:-fas_rs}"
        EXTERNAL_SCHEDULER_NAME="${FAS_RS_MODULE_NAME:-fas-rs}"
        EXTERNAL_SCHEDULER_KIND="fas_rs"
        EXTERNAL_SCHEDULER_PATH="$FAS_RS_MODULE_PATH"
        EXTERNAL_SCHEDULER_SOURCE="$FAS_RS_MODULE_SOURCE"
        EXTERNAL_SCHEDULER_STATE="${FAS_RS_RUNTIME_STATE:-$FAS_RS_OWNER_STATE}"
        EXTERNAL_SCHEDULER_ENABLED="yes"
        EXTERNAL_SCHEDULER_ACTIVE="yes"
        return 0
    fi

    if [ "$_sd_uperf_found" -eq 1 ]; then
        EXTERNAL_SCHEDULER_ID="${UPERF_MODULE_ID:-uperf}"
        EXTERNAL_SCHEDULER_NAME="${UPERF_MODULE_NAME:-Uperf Game Turbo}"
        EXTERNAL_SCHEDULER_KIND="uperf"
        EXTERNAL_SCHEDULER_PATH="$UPERF_MODULE_PATH"
        EXTERNAL_SCHEDULER_SOURCE="$UPERF_MODULE_SOURCE"
        EXTERNAL_SCHEDULER_STATE="$UPERF_MODULE_STATE"
        return 0
    fi

    EXTERNAL_SCHEDULER_ID="${FAS_RS_MODULE_ID:-fas_rs}"
    EXTERNAL_SCHEDULER_NAME="${FAS_RS_MODULE_NAME:-fas-rs}"
    EXTERNAL_SCHEDULER_KIND="fas_rs"
    EXTERNAL_SCHEDULER_PATH="$FAS_RS_MODULE_PATH"
    EXTERNAL_SCHEDULER_SOURCE="$FAS_RS_MODULE_SOURCE"
    EXTERNAL_SCHEDULER_STATE="$FAS_RS_MODULE_STATE"
    return 0
}

detect_external_scheduler_fresh() {
    discover_uperf_module_inventory >/dev/null 2>&1 || true
    discover_fas_rs_inventory >/dev/null 2>&1 || true
    scheduler_write_inventory || {
        SCHEDULER_INVENTORY_STATUS="write_failed"
        return 2
    }
    SCHEDULER_INVENTORY_STATUS="ready"
    refresh_uperf_runtime >/dev/null 2>&1 || true
    refresh_fas_rs_runtime >/dev/null 2>&1 || true
    compose_external_scheduler
}

detect_external_scheduler() {
    if ! scheduler_load_inventory; then
        return 2
    fi
    refresh_uperf_runtime >/dev/null 2>&1 || true
    refresh_fas_rs_runtime >/dev/null 2>&1 || true
    compose_external_scheduler
}
