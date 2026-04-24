#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/profile.sh
# GET  → 返回当前 profile / policy JSON
# POST → 切换 profile 或 policy
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

PROFILE_FILE="$MODDIR/.current_profile"
PROFILE_POLICY_FILE="$MODDIR/.profile_policy"
PROFILE_MANUAL_FILE="$MODDIR/.profile_manual"
PROFILE_AUTO_REASON_FILE="$MODDIR/.profile_auto_reason"

read_valid_profile() {
    _prof=$(cat "$1" 2>/dev/null | tr -d ' \n\r\t')
    case "$_prof" in
        game|balanced|light|battery|stock) printf '%s' "$_prof" ;;
        *) printf '%s' "$2" ;;
    esac
}

read_valid_policy() {
    _policy=$(cat "$PROFILE_POLICY_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_policy" in
        auto|manual) printf '%s' "$_policy" ;;
        *) printf 'manual' ;;
    esac
}

emit_profile_state() {
    _active=$(read_valid_profile "$PROFILE_FILE" 'balanced')
    _manual=$(read_valid_profile "$PROFILE_MANUAL_FILE" "$_active")
    _policy=$(read_valid_policy)
    _reason=$(cat "$PROFILE_AUTO_REASON_FILE" 2>/dev/null | tr -d '\r')
    case "$_reason" in
        feed_warmup) _reason="steady_screen_warmup" ;;
        feed_hold) _reason="steady_screen_hold" ;;
        feed_hot) _reason="steady_hot_guard" ;;
        nonfeed_reset) _reason="nonsteady_reset" ;;
    esac
    printf '"profile":"%s","manual_profile":"%s","policy":"%s","auto_reason":"%s"' \
        "$_active" "$_manual" "$_policy" "$(json_escape "$_reason")"
}

require_loopback

if [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "profile"
    len="${CONTENT_LENGTH:-0}"
    [ "$len" -gt 512 ] 2>/dev/null && len=512
    body=$(dd bs=1 count="$len" 2>/dev/null)
    newprof=$(printf '%s' "$body" | sed -n 's/.*"profile"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
    newpolicy=$(printf '%s' "$body" | sed -n 's/.*"policy"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')

    case "$newprof" in
        ''|game|balanced|light|battery|stock) ;;
        *) json_error '400 Bad Request' 'invalid profile' ;;
    esac
    case "$newpolicy" in
        ''|auto|manual) ;;
        *) json_error '400 Bad Request' 'invalid policy' ;;
    esac

    if [ -n "$newprof" ]; then
        _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$newprof" "$MODDIR" 2>/dev/null)
        _rc=$?
        if [ "$_rc" -ne 0 ]; then
            case "$_result" in
                BLOCKED:*)
                    _temp_raw=${_result#BLOCKED:}
                    _temp_c=$(awk "BEGIN{printf \"%.1f\", ${_temp_raw:-0}/1000}")
                    json_headers
                    printf '{"ok":false,"error":"温度过高 (%s°C)，游戏模式需冷却到 41°C 以下"}\n' "$_temp_c"
                    ;;
                *)
                    json_error '500 Internal Server Error' 'profile script failed'
                    ;;
            esac
            exit 0
        fi
        printf '%s' "$newprof" > "$PROFILE_FILE"
        printf '%s' "$newprof" > "$PROFILE_MANUAL_FILE"
        printf 'manual' > "$PROFILE_POLICY_FILE"
        printf 'manual_selected' > "$PROFILE_AUTO_REASON_FILE"
        json_headers
        printf '{"ok":true,'
        emit_profile_state
        printf '}\n'
        exit 0
    fi

    case "$newpolicy" in
        auto)
            _active=$(read_valid_profile "$PROFILE_FILE" 'balanced')
            case "$_active" in
                balanced|light|battery) _target="$_active" ;;
                *) _target="balanced" ;;
            esac
            _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$_target" "$MODDIR" 2>/dev/null)
            [ "$?" -eq 0 ] || json_error '500 Internal Server Error' 'profile script failed'
            printf '%s' "$_target" > "$PROFILE_FILE"
            printf 'auto' > "$PROFILE_POLICY_FILE"
            printf 'auto_enabled' > "$PROFILE_AUTO_REASON_FILE"
            ;;
        manual)
            _manual=$(read_valid_profile "$PROFILE_MANUAL_FILE" 'balanced')
            _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$_manual" "$MODDIR" 2>/dev/null)
            [ "$?" -eq 0 ] || json_error '500 Internal Server Error' 'profile script failed'
            printf '%s' "$_manual" > "$PROFILE_FILE"
            printf 'manual' > "$PROFILE_POLICY_FILE"
            printf 'manual_policy' > "$PROFILE_AUTO_REASON_FILE"
            ;;
        '')
            json_error '400 Bad Request' 'missing profile or policy'
            ;;
    esac
    json_headers
    printf '{"ok":true,'
    emit_profile_state
    printf '}\n'
elif [ "$REQUEST_METHOD" = "GET" ]; then
    json_headers
    printf '{'
    emit_profile_state
    printf '}\n'
else
    json_error '405 Method Not Allowed' 'GET or POST only'
fi
