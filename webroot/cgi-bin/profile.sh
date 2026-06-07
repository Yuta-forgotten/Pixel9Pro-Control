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
PROFILE_HISTORY_FILE="$MODDIR/.profile_history"
SCHED_OWNER_FILE="$MODDIR/.cpu_sched_owner"

read_valid_profile() {
    _prof=$(cat "$1" 2>/dev/null | tr -d ' \n\r\t')
    case "$_prof" in
        performance|balanced|battery|default) printf '%s' "$_prof" ;;
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

read_valid_sched_owner() {
    _owner=$(cat "$SCHED_OWNER_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_owner" in
        external) printf 'external' ;;
        *)        printf 'pixel' ;;
    esac
}

append_profile_history() {
    _ph_profile="$1"
    _ph_reason="$2"
    _ph_epoch=$(date +%s 2>/dev/null || echo 0)
    _ph_policy=$(read_valid_policy)
    _ph_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null | tr -d ' \n\r\t')
    case "$_ph_status" in
        Charging|Full) _ph_charging=1 ;;
        *) _ph_charging=0 ;;
    esac
    _ph_vs=$(sed -n 's/.*VIRTUAL-SKIN","temp":\([0-9]*\).*/\1/p' "$THERMAL_CACHE" 2>/dev/null | head -1)
    case "$_ph_vs" in
        ''|*[!0-9]*) _ph_vs=0 ;;
    esac
    _ph_sev=$(dumpsys thermalservice 2>/dev/null | grep "Thermal Status:" | head -1 | sed 's/.*Thermal Status:[[:space:]]*//' | tr -d ' \n\r')
    case "$_ph_sev" in
        ''|*[!0-9]*) _ph_sev=-1 ;;
    esac
    _ph_cap=$(cat /proc/sys/kernel/sched_util_clamp_min 2>/dev/null | tr -d ' \n\r\t')
    case "$_ph_cap" in
        ''|*[!0-9]*) _ph_cap=-1 ;;
    esac
    _ph_resp0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/sched_pixel/response_time_ms 2>/dev/null | tr -d ' \n\r\t')
    _ph_resp4=$(cat /sys/devices/system/cpu/cpu4/cpufreq/sched_pixel/response_time_ms 2>/dev/null | tr -d ' \n\r\t')
    _ph_resp7=$(cat /sys/devices/system/cpu/cpu7/cpufreq/sched_pixel/response_time_ms 2>/dev/null | tr -d ' \n\r\t')
    [ -n "$_ph_resp0" ] || _ph_resp0="na"
    [ -n "$_ph_resp4" ] || _ph_resp4="na"
    [ -n "$_ph_resp7" ] || _ph_resp7="na"
    _ph_response="${_ph_resp0}/${_ph_resp4}/${_ph_resp7}"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$_ph_epoch" "$_ph_policy" "$_ph_profile" "$_ph_reason" \
        "$_ph_charging" "$_ph_vs" "$_ph_sev" "$_ph_cap" "$_ph_response" \
        >> "$PROFILE_HISTORY_FILE" 2>/dev/null

    _ph_lines=$(wc -l < "$PROFILE_HISTORY_FILE" 2>/dev/null)
    if [ "${_ph_lines:-0}" -gt 500 ] 2>/dev/null; then
        _ph_trim=$((_ph_lines - 500))
        sed -i "1,${_ph_trim}d" "$PROFILE_HISTORY_FILE" 2>/dev/null
    fi
}

emit_profile_state() {
    _active=$(read_valid_profile "$PROFILE_FILE" 'default')
    _manual=$(read_valid_profile "$PROFILE_MANUAL_FILE" "$_active")
    _policy=$(read_valid_policy)
    _sched_owner=$(read_valid_sched_owner)
    _reason=$(cat "$PROFILE_AUTO_REASON_FILE" 2>/dev/null | tr -d '\r')
    _last_profile_change=$(tail -n 1 "$PROFILE_HISTORY_FILE" 2>/dev/null | tr -d '\r')
    case "$_reason" in
        feed_warmup|feed_hold|feed_hot|nonfeed_reset) _reason="" ;;
    esac
    printf '"profile":"%s","manual_profile":"%s","policy":"%s","sched_owner":"%s","auto_reason":"%s","last_profile_change":"%s"' \
        "$_active" "$_manual" "$_policy" "$_sched_owner" "$(json_escape "$_reason")" "$(json_escape "$_last_profile_change")"
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
    newowner=$(printf '%s' "$body" | sed -n 's/.*"sched_owner"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')

    case "$newprof" in
        ''|performance|balanced|battery|default) ;;
        *) json_error '400 Bad Request' 'invalid profile' ;;
    esac
    case "$newpolicy" in
        ''|auto|manual) ;;
        *) json_error '400 Bad Request' 'invalid policy' ;;
    esac
    case "$newowner" in
        ''|pixel|external) ;;
        *) json_error '400 Bad Request' 'invalid scheduler owner' ;;
    esac

    if [ -n "$newowner" ]; then
        if [ "$newowner" = "external" ]; then
            printf 'external' > "$SCHED_OWNER_FILE"
            printf 'external_scheduler' > "$PROFILE_AUTO_REASON_FILE"
            append_profile_history "$(read_valid_profile "$PROFILE_FILE" 'default')" "external_scheduler"
        else
            _manual=$(read_valid_profile "$PROFILE_MANUAL_FILE" 'default')
            printf 'pixel' > "$SCHED_OWNER_FILE"
            _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$_manual" "$MODDIR" 2>/dev/null)
            [ "$?" -eq 0 ] || json_error '500 Internal Server Error' 'profile script failed'
            printf '%s' "$_manual" > "$PROFILE_FILE"
            printf 'manual' > "$PROFILE_POLICY_FILE"
            printf 'pixel_scheduler' > "$PROFILE_AUTO_REASON_FILE"
            append_profile_history "$_manual" "pixel_scheduler"
        fi
        json_headers
        printf '{"ok":true,'
        emit_profile_state
        printf '}\n'
        exit 0
    fi

    if [ "$(read_valid_sched_owner)" = "external" ]; then
        json_headers
        printf '{"ok":false,"error":"Uperf 共存模式已开启，CPU 调度由外部模块接管"}\n'
        exit 0
    fi

    if [ -n "$newprof" ]; then
        _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$newprof" "$MODDIR" 2>/dev/null)
        _rc=$?
        if [ "$_rc" -ne 0 ]; then
            case "$_result" in
                BLOCKED:*)
                    _temp_raw=${_result#BLOCKED:}
                    _temp_c=$(awk "BEGIN{printf \"%.1f\", ${_temp_raw:-0}/1000}")
                    json_headers
                    printf '{"ok":false,"error":"温度过高 (%s°C)，请先降温后再切换性能档"}\n' "$_temp_c"
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
        append_profile_history "$newprof" "manual_selected"
        json_headers
        printf '{"ok":true,'
        emit_profile_state
        printf '}\n'
        exit 0
    fi

    case "$newpolicy" in
        auto)
            _active=$(read_valid_profile "$PROFILE_FILE" 'default')
            case "$_active" in
                default|balanced|battery) _target="$_active" ;;
                *) _target="default" ;;
            esac
            _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$_target" "$MODDIR" 2>/dev/null)
            [ "$?" -eq 0 ] || json_error '500 Internal Server Error' 'profile script failed'
            printf '%s' "$_target" > "$PROFILE_FILE"
            printf 'auto' > "$PROFILE_POLICY_FILE"
            printf 'auto_enabled' > "$PROFILE_AUTO_REASON_FILE"
            append_profile_history "$_target" "auto_enabled"
            ;;
        manual)
            _manual=$(read_valid_profile "$PROFILE_MANUAL_FILE" 'default')
            _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$_manual" "$MODDIR" 2>/dev/null)
            [ "$?" -eq 0 ] || json_error '500 Internal Server Error' 'profile script failed'
            printf '%s' "$_manual" > "$PROFILE_FILE"
            printf 'manual' > "$PROFILE_POLICY_FILE"
            printf 'manual_policy' > "$PROFILE_AUTO_REASON_FILE"
            append_profile_history "$_manual" "manual_policy"
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
