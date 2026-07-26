#!/system/bin/sh

# Preferred-network-mode contract shared by the boot worker and NR CGI.
# DSDS values retain every slot; screen-off switching changes slot 0 only.

nr_mode_slot0() {
    case "$1" in
        *,*) printf '%s' "${1%%,*}" ;;
        *) printf '%s' "$1" ;;
    esac
}

nr_mode_replace_slot0() {
    case "$1" in
        *,*) printf '%s,%s' "$2" "${1#*,}" ;;
        *) printf '%s' "$2" ;;
    esac
}

nr_mode_is_nr_capable() {
    _nr_mode_slot=$(nr_mode_slot0 "$1")
    case "$_nr_mode_slot" in ''|null|*[!0-9]*) return 1 ;; esac
    [ "$_nr_mode_slot" -ge 23 ] 2>/dev/null
}

nr_mode_is_valid_raw() {
    case "$1" in
        ''|null|*[!0-9,]*|*,*,*) return 1 ;;
        *,*)
            _nr_mode_first=${1%%,*}
            _nr_mode_rest=${1#*,}
            case "$_nr_mode_first" in ''|*[!0-9]*) return 1 ;; esac
            case "$_nr_mode_rest" in ''|*[!0-9]*) return 1 ;; esac
            ;;
    esac
    return 0
}

nr_mode_detect_setting() {
    NR_MODE_KEY="preferred_network_mode1"
    NR_MODE_CURRENT=$(runtime_android_settings get global "$NR_MODE_KEY" 2>/dev/null | tr -d ' \n\r')
    if [ -z "$NR_MODE_CURRENT" ] || [ "$NR_MODE_CURRENT" = "null" ]; then
        NR_MODE_KEY="preferred_network_mode"
        NR_MODE_CURRENT=$(runtime_android_settings get global "$NR_MODE_KEY" 2>/dev/null | tr -d ' \n\r')
    fi
}

nr_mode_write_verified() {
    _nr_mode_key="$1"
    _nr_mode_value="$2"
    nr_mode_is_valid_raw "$_nr_mode_value" || return 1
    runtime_android_settings put global "$_nr_mode_key" "$_nr_mode_value" 2>/dev/null || return 1
    _nr_mode_verified=$(runtime_android_settings get global "$_nr_mode_key" 2>/dev/null | tr -d ' \n\r')
    [ "$_nr_mode_verified" = "$_nr_mode_value" ]
}

nr_mode_read_saved() {
    _nr_mode_file="$1"
    _nr_mode_fallback="$2"
    _nr_mode_saved=$(cat "$_nr_mode_file" 2>/dev/null | tr -d ' \n\r\t')
    if nr_mode_is_valid_raw "$_nr_mode_saved" && nr_mode_is_nr_capable "$_nr_mode_saved"; then
        printf '%s' "$_nr_mode_saved"
        return 0
    fi
    nr_mode_is_valid_raw "$_nr_mode_fallback" && nr_mode_is_nr_capable "$_nr_mode_fallback" || return 1
    runtime_write_value "$_nr_mode_file" "$_nr_mode_fallback" 2>/dev/null || return 1
    printf '%s' "$_nr_mode_fallback"
}

nr_mode_save_current() {
    _nr_mode_file="$1"
    _nr_mode_current="$2"
    nr_mode_is_valid_raw "$_nr_mode_current" && nr_mode_is_nr_capable "$_nr_mode_current" || return 1
    runtime_write_value "$_nr_mode_file" "$_nr_mode_current"
}
