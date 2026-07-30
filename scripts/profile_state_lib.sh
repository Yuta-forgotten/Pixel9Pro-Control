#!/system/bin/sh

# profile 持久状态的文件名、合法值与兜底读取统一由本契约维护。
profile_state_init() {
    _ps_root="$1"
    [ -n "$_ps_root" ] || return 1
    PROFILE_FILE="$_ps_root/.current_profile"
    PROFILE_POLICY_FILE="$_ps_root/.profile_policy"
    PROFILE_MANUAL_FILE="$_ps_root/.profile_manual"
    PROFILE_AUTO_REASON_FILE="$_ps_root/.profile_auto_reason"
    PROFILE_HISTORY_FILE="$_ps_root/.profile_history"
}

profile_state_policy_is_valid() {
    case "$1" in
        manual|auto) return 0 ;;
        *) return 1 ;;
    esac
}

profile_state_read_profile() {
    _ps_path="$1"
    _ps_default="$2"
    _ps_value=$(cat "$_ps_path" 2>/dev/null | tr -d ' \n\r\t')
    if command -v cpu_profile_normalize_runtime >/dev/null 2>&1; then
        cpu_profile_normalize_runtime "$_ps_value" "$_ps_default"
    else
        printf '%s' "$_ps_default"
    fi
}

profile_state_read_active() {
    profile_state_read_profile "$PROFILE_FILE" "$1"
}

profile_state_read_manual() {
    profile_state_read_profile "$PROFILE_MANUAL_FILE" "$1"
}

profile_state_read_policy() {
    _ps_policy=$(cat "$PROFILE_POLICY_FILE" 2>/dev/null | tr -d ' \n\r\t')
    if profile_state_policy_is_valid "$_ps_policy"; then
        printf '%s' "$_ps_policy"
    else
        printf 'manual'
    fi
}
