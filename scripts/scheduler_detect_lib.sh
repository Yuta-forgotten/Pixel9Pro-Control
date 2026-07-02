#!/system/bin/sh
# Shared scheduler ownership helpers.
# Detects external CPU schedulers without suggesting installation.
# Keep the legacy Uperf fields/API for WebUI compatibility.

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
    sed -n "s/^${_sd_key}=//p" "$_sd_prop" 2>/dev/null | head -n 1 | tr -d '\r'
}

scheduler_module_source() {
    case "$1" in
        /data/adb/modules_update/*) printf '%s' "modules_update" ;;
        /data/adb/modules/*)        printf '%s' "modules" ;;
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
    pidof "$_sd_proc" >/dev/null 2>&1 && return 0
    ps -A 2>/dev/null | grep -E "(^|[[:space:]])${_sd_proc}([[:space:]]|$)" | grep -v grep >/dev/null 2>&1
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

detect_uperf_module() {
    reset_uperf_detection

    _sd_uperf_found=0
    for _sd_prop in /data/adb/modules/*/module.prop /data/adb/modules_update/*/module.prop; do
        [ -f "$_sd_prop" ] || continue
        is_uperf_module_prop "$_sd_prop" || continue

        UPERF_DETECTED="yes"
        UPERF_MODULE_PATH="${_sd_prop%/module.prop}"
        UPERF_MODULE_ID=$(read_module_prop_value id "$_sd_prop")
        UPERF_MODULE_NAME=$(read_module_prop_value name "$_sd_prop")
        [ -n "$UPERF_MODULE_ID" ] || UPERF_MODULE_ID="${UPERF_MODULE_PATH##*/}"
        [ -n "$UPERF_MODULE_NAME" ] || UPERF_MODULE_NAME="$UPERF_MODULE_ID"

        UPERF_MODULE_SOURCE=$(scheduler_module_source "$UPERF_MODULE_PATH")
        UPERF_MODULE_STATE=$(scheduler_module_state "$UPERF_MODULE_PATH" "$UPERF_MODULE_SOURCE")
        if scheduler_state_enabled "$UPERF_MODULE_STATE"; then
            UPERF_MODULE_ENABLED="yes"
        else
            UPERF_MODULE_ENABLED="no"
        fi
        _sd_uperf_found=1
        break
    done

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

    [ "$_sd_uperf_found" -eq 1 ] || [ "$UPERF_PROCESS_ALIVE" = "yes" ] || return 1
    return 0
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

detect_fas_rs_scheduler() {
    reset_fas_rs_detection
    FAS_RS_RUNTIME_ROOT="/data/adb/fas_rs"

    for _sd_prop in /data/adb/modules/*/module.prop /data/adb/modules_update/*/module.prop; do
        [ -f "$_sd_prop" ] || continue
        is_fas_rs_module_prop "$_sd_prop" || continue

        FAS_RS_DETECTED="yes"
        FAS_RS_MODULE_PATH="${_sd_prop%/module.prop}"
        FAS_RS_MODULE_ID=$(read_module_prop_value id "$_sd_prop")
        FAS_RS_MODULE_NAME=$(read_module_prop_value name "$_sd_prop")
        [ -n "$FAS_RS_MODULE_ID" ] || FAS_RS_MODULE_ID="${FAS_RS_MODULE_PATH##*/}"
        [ -n "$FAS_RS_MODULE_NAME" ] || FAS_RS_MODULE_NAME="fas-rs"

        FAS_RS_MODULE_SOURCE=$(scheduler_module_source "$FAS_RS_MODULE_PATH")
        FAS_RS_MODULE_STATE=$(scheduler_module_state "$FAS_RS_MODULE_PATH" "$FAS_RS_MODULE_SOURCE")
        if scheduler_state_enabled "$FAS_RS_MODULE_STATE"; then
            FAS_RS_MODULE_ENABLED="yes"
        else
            FAS_RS_MODULE_ENABLED="no"
        fi
        break
    done

    if scheduler_process_alive "fas-rs"; then
        FAS_RS_PROCESS_ALIVE="yes"
        FAS_RS_DETECTED="yes"
    fi

    [ -s "$FAS_RS_RUNTIME_ROOT/.owner_state" ] && FAS_RS_OWNER_STATE=$(head -n 1 "$FAS_RS_RUNTIME_ROOT/.owner_state" 2>/dev/null | tr -d '\r')
    [ -e /dev/fas_rs/mode ] && FAS_RS_MODE=$(head -n 1 /dev/fas_rs/mode 2>/dev/null | tr -d ' \r\n\t')

    if [ -d "$FAS_RS_RUNTIME_ROOT" ] || [ -n "$FAS_RS_OWNER_STATE" ] || [ -n "$FAS_RS_MODE" ]; then
        FAS_RS_DETECTED="yes"
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
    elif [ "$FAS_RS_PROCESS_ALIVE" = "yes" ]; then
        FAS_RS_RUNTIME_STATE="running"
        FAS_RS_MODULE_ENABLED="yes"
        FAS_RS_ACTIVE="yes"
    elif [ -n "$FAS_RS_OWNER_STATE" ]; then
        case "$FAS_RS_OWNER_STATE" in
            *running*|*game*|*fas-rs*)
                FAS_RS_RUNTIME_STATE="$FAS_RS_OWNER_STATE"
                FAS_RS_MODULE_ENABLED="yes"
                # .owner_state is a desired/last-owner marker and can be stale
                # after a crash, force-stop, or handoff interruption.  Only the
                # live fas-rs process proves runtime activity.
                FAS_RS_ACTIVE="no"
                ;;
            *)
                FAS_RS_RUNTIME_STATE="$FAS_RS_OWNER_STATE"
                FAS_RS_ACTIVE="no"
                ;;
        esac
    elif [ "$FAS_RS_MODULE_ENABLED" = "yes" ]; then
        FAS_RS_RUNTIME_STATE="module_enabled"
        FAS_RS_ACTIVE="no"
    elif [ -d "$FAS_RS_RUNTIME_ROOT" ] || [ -n "$FAS_RS_MODE" ]; then
        FAS_RS_RUNTIME_STATE="runtime_present"
        FAS_RS_ACTIVE="no"
    else
        [ -n "$FAS_RS_RUNTIME_STATE" ] || FAS_RS_RUNTIME_STATE="${FAS_RS_MODULE_STATE:-detected}"
        FAS_RS_ACTIVE="no"
    fi

    [ -n "$FAS_RS_MODULE_STATE" ] || FAS_RS_MODULE_STATE="$FAS_RS_RUNTIME_STATE"
    return 0
}

detect_external_scheduler() {
    reset_external_scheduler_detection

    _sd_uperf_found=0
    _sd_fas_found=0
    detect_uperf_module 2>/dev/null && _sd_uperf_found=1
    detect_fas_rs_scheduler 2>/dev/null && _sd_fas_found=1

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
