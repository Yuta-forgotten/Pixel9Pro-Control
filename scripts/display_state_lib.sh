#!/system/bin/sh

# Shared display-state contract. DRM enabled means the panel encoder is still
# connected and is not proof of an interactive display while AOD is in DOZE.

DISPLAY_STATE_CMD_BIN="${DISPLAY_STATE_CMD_BIN:-/system/bin/cmd}"
DISPLAY_STATE_DUMPSYS_BIN="${DISPLAY_STATE_DUMPSYS_BIN:-/system/bin/dumpsys}"
DISPLAY_STATE_DRM_PATH="${DISPLAY_STATE_DRM_PATH:-/sys/class/drm/card0-DSI-1/enabled}"
DISPLAY_STATE_TEST_MODE="${DISPLAY_STATE_TEST_MODE:-0}"
DISPLAY_STATE="unknown"
DISPLAY_STATE_SOURCE="none"
DISPLAY_STATE_INTERACTIVE="unknown"

display_state_classify() {
    _ds_screen="$1"
    _ds_wakefulness="$2"
    _ds_drm="$3"

    DISPLAY_STATE="unknown"
    DISPLAY_STATE_SOURCE="unavailable"
    DISPLAY_STATE_INTERACTIVE="unknown"

    case "$_ds_screen" in
        true)
            DISPLAY_STATE="interactive"
            DISPLAY_STATE_SOURCE="deviceidle"
            DISPLAY_STATE_INTERACTIVE="yes"
            return 0
            ;;
        false)
            DISPLAY_STATE_INTERACTIVE="no"
            DISPLAY_STATE_SOURCE="deviceidle"
            case "$_ds_wakefulness" in
                Dozing) DISPLAY_STATE="doze" ;;
                Asleep) DISPLAY_STATE="off" ;;
                *)
                    case "$_ds_drm" in
                        enabled) DISPLAY_STATE="doze" ;;
                        disabled) DISPLAY_STATE="off" ;;
                        *) DISPLAY_STATE="noninteractive" ;;
                    esac
                    ;;
            esac
            return 0
            ;;
    esac

    case "$_ds_wakefulness" in
        Awake)
            DISPLAY_STATE="interactive"
            DISPLAY_STATE_SOURCE="power"
            DISPLAY_STATE_INTERACTIVE="yes"
            return 0
            ;;
        Dozing)
            DISPLAY_STATE="doze"
            DISPLAY_STATE_SOURCE="power"
            DISPLAY_STATE_INTERACTIVE="no"
            return 0
            ;;
        Asleep)
            DISPLAY_STATE="off"
            DISPLAY_STATE_SOURCE="power"
            DISPLAY_STATE_INTERACTIVE="no"
            return 0
            ;;
    esac

    if [ "$_ds_drm" = "disabled" ]; then
        DISPLAY_STATE="off"
        DISPLAY_STATE_SOURCE="drm_disabled"
        DISPLAY_STATE_INTERACTIVE="no"
        return 0
    fi
    return 1
}

display_state_read() {
    _ds_screen=""
    _ds_wakefulness=""
    _ds_drm=""

    if [ "$DISPLAY_STATE_TEST_MODE" = "1" ]; then
        _ds_screen="${DISPLAY_STATE_TEST_SCREEN:-}"
        _ds_wakefulness="${DISPLAY_STATE_TEST_WAKEFULNESS:-}"
        _ds_drm="${DISPLAY_STATE_TEST_DRM:-}"
        display_state_classify "$_ds_screen" "$_ds_wakefulness" "$_ds_drm"
        return $?
    fi

    if [ -r "$DISPLAY_STATE_DRM_PATH" ]; then
        IFS= read -r _ds_drm < "$DISPLAY_STATE_DRM_PATH" 2>/dev/null || _ds_drm=""
        _ds_drm=${_ds_drm%%[!A-Za-z]*}
    fi

    if [ -x "$DISPLAY_STATE_CMD_BIN" ]; then
        _ds_screen=$("$DISPLAY_STATE_CMD_BIN" deviceidle get screen 2>/dev/null)
        _ds_screen=${_ds_screen%%[!A-Za-z]*}
        case "$_ds_screen" in
            true|false)
                display_state_classify "$_ds_screen" "" "$_ds_drm"
                return $?
                ;;
        esac
    fi

    if [ -x "$DISPLAY_STATE_DUMPSYS_BIN" ]; then
        _ds_wakefulness=$("$DISPLAY_STATE_DUMPSYS_BIN" power 2>/dev/null \
            | sed -n 's/^[[:space:]]*mWakefulness=//p' | head -n 1 | tr -d ' \r\n\t')
    fi
    display_state_classify "" "$_ds_wakefulness" "$_ds_drm"
}

display_state_legacy_screen() {
    case "$DISPLAY_STATE_INTERACTIVE" in
        yes) printf 'on' ;;
        no) printf 'off' ;;
        *) printf 'unknown' ;;
    esac
}
