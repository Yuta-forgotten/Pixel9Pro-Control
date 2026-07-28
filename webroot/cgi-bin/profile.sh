#!/system/bin/sh
# Scheduler/profile state CGI. Desired owner, effective owner, handoff policy,
# and Pixel profile state are separate contracts and are committed explicitly.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback

PROFILE_FILE="$MODDIR/.current_profile"
PROFILE_POLICY_FILE="$MODDIR/.profile_policy"
PROFILE_MANUAL_FILE="$MODDIR/.profile_manual"
PROFILE_AUTO_REASON_FILE="$MODDIR/.profile_auto_reason"
PROFILE_HISTORY_FILE="$MODDIR/.profile_history"
SCHED_OWNER_FILE="$MODDIR/.cpu_sched_owner"
SCHED_OWNER_DESIRED_FILE="$MODDIR/.sched_owner_desired"
GAME_HANDOFF_POLICY_FILE="$MODDIR/.game_handoff_policy"
FAS_ROOT="${PIXEL9PRO_FAS_ROOT:-/data/adb/fas_rs}"
ARBITER_STATE_FILE="$FAS_ROOT/.arbiter_state"
SCHEDULER_INVENTORY_PATH="${SCHEDULER_INVENTORY_PATH:-$MODDIR/.scheduler_inventory}"

[ -r "$MODDIR/scripts/scheduler_detect_lib.sh" ] && . "$MODDIR/scripts/scheduler_detect_lib.sh" \
    || json_error '500 Internal Server Error' 'scheduler detection contract not found'
[ -r "$MODDIR/scripts/scheduler_owner_lib.sh" ] && . "$MODDIR/scripts/scheduler_owner_lib.sh" \
    || json_error '500 Internal Server Error' 'scheduler owner contract not found'
[ -r "$MODDIR/scripts/cpu_profile_lib.sh" ] && . "$MODDIR/scripts/cpu_profile_lib.sh" \
    || json_error '500 Internal Server Error' 'CPU profile contract not found'
[ -r "$MODDIR/scripts/scheduler_boot_mode_lib.sh" ] && . "$MODDIR/scripts/scheduler_boot_mode_lib.sh" \
    || json_error '500 Internal Server Error' 'scheduler boot-mode contract not found'
scheduler_owner_init "$MODDIR" "$FAS_ROOT"
sbm_init "$MODDIR" "$FAS_ROOT"
so_migrate_state >/dev/null 2>&1 \
    || json_error '500 Internal Server Error' 'scheduler owner state migration failed'

PROFILE_SCHEDULER_LOCKED=0

release_profile_scheduler_lock() {
    if [ "$PROFILE_SCHEDULER_LOCKED" -eq 1 ]; then
        so_release_transition_lock >/dev/null 2>&1 || true
        PROFILE_SCHEDULER_LOCKED=0
    fi
}

profile_request_cleanup() {
    release_profile_scheduler_lock
    release_lock
}

acquire_profile_scheduler_lock() {
    so_acquire_transition_lock \
        || json_error '409 Conflict' 'scheduler transition busy'
    PROFILE_SCHEDULER_LOCKED=1
    trap 'profile_request_cleanup' EXIT
    trap 'profile_request_cleanup; exit 130' INT
    trap 'profile_request_cleanup; exit 143' TERM
}

read_valid_profile() {
    _prof=$(cat "$1" 2>/dev/null | tr -d ' \n\r\t')
    cpu_profile_normalize_runtime "$_prof" "$2"
}

read_valid_policy() {
    _policy=$(cat "$PROFILE_POLICY_FILE" 2>/dev/null | tr -d ' \n\r\t')
    case "$_policy" in
        auto|manual) printf '%s' "$_policy" ;;
        *) printf 'manual' ;;
    esac
}

read_valid_sched_owner() {
    so_read_effective_owner
}

read_valid_desired_sched_owner() {
    so_read_desired_owner
}

read_valid_handoff_policy() {
    so_read_handoff_policy
}

read_arbiter_value() {
    [ -s "$ARBITER_STATE_FILE" ] || return 0
    sed -n "s/^$1=//p" "$ARBITER_STATE_FILE" 2>/dev/null | head -n 1 | tr -d '\r'
}

reconcile_owner_now() {
    [ -f "$MODDIR/scripts/owner_arbiter.sh" ] || return 1
    sh "$MODDIR/scripts/owner_arbiter.sh" apply-tick "$MODDIR" on >/dev/null 2>&1
}

commit_profile_state() {
    _profile_new_active="$1"
    _profile_new_manual="$2"
    _profile_new_policy="$3"
    _profile_new_reason="$4"

    _profile_active_existed=0
    _profile_manual_existed=0
    _profile_policy_existed=0
    _profile_reason_existed=0
    [ -e "$PROFILE_FILE" ] && _profile_active_existed=1
    [ -e "$PROFILE_MANUAL_FILE" ] && _profile_manual_existed=1
    [ -e "$PROFILE_POLICY_FILE" ] && _profile_policy_existed=1
    [ -e "$PROFILE_AUTO_REASON_FILE" ] && _profile_reason_existed=1
    _profile_old_active=$(cat "$PROFILE_FILE" 2>/dev/null)
    _profile_old_manual=$(cat "$PROFILE_MANUAL_FILE" 2>/dev/null)
    _profile_old_policy=$(cat "$PROFILE_POLICY_FILE" 2>/dev/null)
    _profile_old_reason=$(cat "$PROFILE_AUTO_REASON_FILE" 2>/dev/null)

    if cgi_atomic_write "$PROFILE_FILE" "$_profile_new_active" \
        && cgi_atomic_write "$PROFILE_MANUAL_FILE" "$_profile_new_manual" \
        && cgi_atomic_write "$PROFILE_POLICY_FILE" "$_profile_new_policy" \
        && cgi_atomic_write "$PROFILE_AUTO_REASON_FILE" "$_profile_new_reason"; then
        return 0
    fi

    PROFILE_STATE_ROLLBACK_OK=1
    cgi_restore_file "$PROFILE_FILE" "$_profile_active_existed" "$_profile_old_active" >/dev/null 2>&1 || PROFILE_STATE_ROLLBACK_OK=0
    cgi_restore_file "$PROFILE_MANUAL_FILE" "$_profile_manual_existed" "$_profile_old_manual" >/dev/null 2>&1 || PROFILE_STATE_ROLLBACK_OK=0
    cgi_restore_file "$PROFILE_POLICY_FILE" "$_profile_policy_existed" "$_profile_old_policy" >/dev/null 2>&1 || PROFILE_STATE_ROLLBACK_OK=0
    cgi_restore_file "$PROFILE_AUTO_REASON_FILE" "$_profile_reason_existed" "$_profile_old_reason" >/dev/null 2>&1 || PROFILE_STATE_ROLLBACK_OK=0
    return 1
}

rollback_profile_runtime_or_error() {
    _profile_rollback_target="$1"
    if sh "$MODDIR/scripts/cpu_profile.sh" "$_profile_rollback_target" "$MODDIR" force >/dev/null 2>&1 \
        && [ "${PROFILE_STATE_ROLLBACK_OK:-1}" -eq 1 ]; then
        json_error '500 Internal Server Error' 'failed to persist profile state; previous runtime restored'
    fi
    json_error '500 Internal Server Error' 'failed to persist profile state and rollback was incomplete'
}

append_profile_history() {
    _ph_profile="$1"
    _ph_reason="$2"
    _ph_epoch=$(date +%s 2>/dev/null || echo 0)
    _ph_policy=$(read_valid_policy)
    _ph_owner=$(read_valid_desired_sched_owner)
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

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$_ph_epoch" "$_ph_policy" "$_ph_owner" "$_ph_profile" "$_ph_reason" \
        "$_ph_charging" "$_ph_vs" "$_ph_sev" "$_ph_cap" "$_ph_response" \
        >> "$PROFILE_HISTORY_FILE" 2>/dev/null

    _ph_lines=$(wc -l < "$PROFILE_HISTORY_FILE" 2>/dev/null)
    if [ "${_ph_lines:-0}" -gt 500 ] 2>/dev/null; then
        _ph_trim=$((_ph_lines - 500))
        sed -i "1,${_ph_trim}d" "$PROFILE_HISTORY_FILE" 2>/dev/null
    fi
}

emit_profile_state() {
    _active=$(read_valid_profile "$PROFILE_FILE" 'balanced')
    _manual=$(read_valid_profile "$PROFILE_MANUAL_FILE" "$_active")
    _policy=$(read_valid_policy)
    _sched_owner=$(read_valid_desired_sched_owner)
    _sched_effective_owner=$(read_valid_sched_owner)
    _game_handoff_policy=$(read_valid_handoff_policy)
    _arbiter_state=$(read_arbiter_value state)
    _arbiter_apply_result=$(read_arbiter_value apply_result)
    _arbiter_reason=$(read_arbiter_value reason)
    _reason=$(cat "$PROFILE_AUTO_REASON_FILE" 2>/dev/null | tr -d '\r')
    _last_profile_change=$(tail -n 1 "$PROFILE_HISTORY_FILE" 2>/dev/null | tr -d '\r')
    case "$_reason" in
        feed_warmup|feed_hold|feed_hot|nonfeed_reset) _reason="" ;;
    esac
    # detect_external_scheduler populates UGT and fas-rs state together.
    # Avoid scanning every installed module twice on each WebUI request.
    detect_external_scheduler 2>/dev/null
    if [ "$UPERF_DETECTED" = "yes" ]; then
        _uperf_detected=true
    else
        _uperf_detected=false
    fi
    if [ "$FAS_RS_DETECTED" = "yes" ]; then
        _fas_rs_detected=true
    else
        _fas_rs_detected=false
    fi
    if [ "$EXTERNAL_SCHEDULER_DETECTED" = "yes" ]; then
        _external_scheduler_detected=true
    else
        _external_scheduler_detected=false
    fi
    if [ "$EXTERNAL_SCHEDULER_ACTIVE" = "yes" ]; then
        _external_scheduler_active=true
    else
        _external_scheduler_active=false
    fi
    _effective_scheduler_owner="pixel"
    _effective_scheduler_name="Pixel9Pro-Control"
    _effective_scheduler_kind="pixel"
    _effective_scheduler_mode=""
    _profile_surface="authoritative"
    _profile_surface_stale=false
    _profile_surface_note=""
    _cpu_contract=$(cpu_profile_contract_json) \
        || json_error '500 Internal Server Error' 'CPU profile contract serialization failed'
    sbm_load_state
    _scheduler_health_status=$(sbm_state_value "$SBM_HEALTH_FILE" status 2>/dev/null)
    _scheduler_health_reason=$(sbm_state_value "$SBM_HEALTH_FILE" reason 2>/dev/null)
    _scheduler_health_checked=$(sbm_state_value "$SBM_HEALTH_FILE" checked_epoch 2>/dev/null)
    _scheduler_health_profile_verified=$(sbm_state_value "$SBM_HEALTH_FILE" profile_verified 2>/dev/null)
    _scheduler_health_cpufreq=$(sbm_state_value "$SBM_HEALTH_FILE" cpufreq_permissions 2>/dev/null)
    _scheduler_health_powerhal=$(sbm_state_value "$SBM_HEALTH_FILE" powerhal_failures 2>/dev/null)
    if [ "$_sched_effective_owner" = "external" ]; then
        _profile_surface="delegated"
        _profile_surface_stale=true
        _profile_surface_note="profile_policy_display_only_external_owner"
        if [ "$EXTERNAL_SCHEDULER_DETECTED" = "yes" ]; then
            _effective_scheduler_owner="${EXTERNAL_SCHEDULER_ID:-external}"
            _effective_scheduler_name="${EXTERNAL_SCHEDULER_NAME:-external scheduler}"
            _effective_scheduler_kind="${EXTERNAL_SCHEDULER_KIND:-external}"
        else
            _effective_scheduler_owner="external"
            _effective_scheduler_name="external scheduler"
            _effective_scheduler_kind="external"
        fi
        if [ "$EXTERNAL_SCHEDULER_KIND" = "fas_rs" ]; then
            _effective_scheduler_mode="$FAS_RS_MODE"
        fi
    fi

    printf '"profile":"%s","manual_profile":"%s","policy":"%s","sched_owner":"%s","sched_effective_owner":"%s","game_handoff_policy":"%s","arbiter_state":"%s","arbiter_apply_result":"%s","arbiter_reason":"%s","auto_reason":"%s","last_profile_change":"%s","uperf_detected":%s,"uperf_module_id":"%s","uperf_module_name":"%s","uperf_module_path":"%s","uperf_module_source":"%s","uperf_module_state":"%s","uperf_module_enabled":"%s","uperf_process_alive":"%s","uperf_active":"%s","fas_rs_detected":%s,"fas_rs_module_id":"%s","fas_rs_module_name":"%s","fas_rs_module_path":"%s","fas_rs_module_source":"%s","fas_rs_module_state":"%s","fas_rs_module_enabled":"%s","fas_rs_owner_state":"%s","fas_rs_mode":"%s","fas_rs_process_alive":"%s","fas_rs_runtime_state":"%s","fas_rs_active":"%s","external_scheduler_detected":%s,"external_scheduler_active":%s,"external_scheduler_id":"%s","external_scheduler_name":"%s","external_scheduler_kind":"%s","external_scheduler_path":"%s","external_scheduler_source":"%s","external_scheduler_state":"%s","external_scheduler_enabled":"%s","effective_scheduler_owner":"%s","effective_scheduler_name":"%s","effective_scheduler_kind":"%s","effective_scheduler_mode":"%s","profile_surface":"%s","profile_surface_stale":%s,"profile_surface_note":"%s"' \
        "$_active" "$_manual" "$_policy" "$_sched_owner" "$_sched_effective_owner" "$_game_handoff_policy" \
        "$(json_escape "$_arbiter_state")" "$(json_escape "$_arbiter_apply_result")" "$(json_escape "$_arbiter_reason")" \
        "$(json_escape "$_reason")" "$(json_escape "$_last_profile_change")" \
        "$_uperf_detected" "$(json_escape "$UPERF_MODULE_ID")" "$(json_escape "$UPERF_MODULE_NAME")" \
        "$(json_escape "$UPERF_MODULE_PATH")" "$(json_escape "$UPERF_MODULE_SOURCE")" \
        "$(json_escape "$UPERF_MODULE_STATE")" "$(json_escape "$UPERF_MODULE_ENABLED")" \
        "$(json_escape "$UPERF_PROCESS_ALIVE")" "$(json_escape "$UPERF_ACTIVE")" \
        "$_fas_rs_detected" "$(json_escape "$FAS_RS_MODULE_ID")" "$(json_escape "$FAS_RS_MODULE_NAME")" \
        "$(json_escape "$FAS_RS_MODULE_PATH")" "$(json_escape "$FAS_RS_MODULE_SOURCE")" \
        "$(json_escape "$FAS_RS_MODULE_STATE")" "$(json_escape "$FAS_RS_MODULE_ENABLED")" \
        "$(json_escape "$FAS_RS_OWNER_STATE")" "$(json_escape "$FAS_RS_MODE")" \
        "$(json_escape "$FAS_RS_PROCESS_ALIVE")" "$(json_escape "$FAS_RS_RUNTIME_STATE")" "$(json_escape "$FAS_RS_ACTIVE")" \
        "$_external_scheduler_detected" "$_external_scheduler_active" "$(json_escape "$EXTERNAL_SCHEDULER_ID")" \
        "$(json_escape "$EXTERNAL_SCHEDULER_NAME")" "$(json_escape "$EXTERNAL_SCHEDULER_KIND")" \
        "$(json_escape "$EXTERNAL_SCHEDULER_PATH")" "$(json_escape "$EXTERNAL_SCHEDULER_SOURCE")" \
        "$(json_escape "$EXTERNAL_SCHEDULER_STATE")" "$(json_escape "$EXTERNAL_SCHEDULER_ENABLED")" \
        "$(json_escape "$_effective_scheduler_owner")" "$(json_escape "$_effective_scheduler_name")" \
        "$(json_escape "$_effective_scheduler_kind")" "$(json_escape "$_effective_scheduler_mode")" \
        "$(json_escape "$_profile_surface")" "$_profile_surface_stale" "$(json_escape "$_profile_surface_note")"
    printf ',"cpu_contract":%s' "$_cpu_contract"
    printf ',"scheduler_boot":{"target_mode":"%s","effective_mode":"%s","phase":"%s","final":"%s","ok":"%s","result":"%s","reason":"%s","attempts":%s,"reboot_required":"%s","auto_repair_used":"%s","staged_boot_id":"%s","observed_boot_id":"%s"}' \
        "$(json_escape "$SBM_TARGET_MODE")" "$(json_escape "$SBM_EFFECTIVE_MODE")" \
        "$(json_escape "$SBM_PHASE")" "$(json_escape "$SBM_FINAL")" "$(json_escape "$SBM_OK")" \
        "$(json_escape "$SBM_RESULT")" "$(json_escape "$SBM_REASON")" "${SBM_ATTEMPTS:-0}" \
        "$(json_escape "$SBM_REBOOT_REQUIRED")" "$(json_escape "$SBM_AUTO_REPAIR_USED")" \
        "$(json_escape "$SBM_STAGED_BOOT_ID")" "$(json_escape "$SBM_OBSERVED_BOOT_ID")"
    printf ',"scheduler_health":{"status":"%s","reason":"%s","checked_epoch":"%s","profile_verified":"%s","cpufreq_permissions":"%s","powerhal_failures":"%s"}' \
        "$(json_escape "$_scheduler_health_status")" "$(json_escape "$_scheduler_health_reason")" \
        "$(json_escape "$_scheduler_health_checked")" "$(json_escape "$_scheduler_health_profile_verified")" \
        "$(json_escape "$_scheduler_health_cpufreq")" "$(json_escape "$_scheduler_health_powerhal")"
}

if [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "profile"
    read_json_body 512
    body="$JSON_BODY"
    newprof=$(printf '%s' "$body" | sed -n 's/.*"profile"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
    newpolicy=$(printf '%s' "$body" | sed -n 's/.*"policy"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
    newowner=$(printf '%s' "$body" | sed -n 's/.*"sched_owner"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
    newhandoff=$(printf '%s' "$body" | sed -n 's/.*"game_handoff"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')
    scheduler_action=$(printf '%s' "$body" | sed -n 's/.*"scheduler_action"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')

    case "$newprof" in
        ''|balanced|battery|default) ;;
        performance) json_error '400 Bad Request' 'performance is internal-only: use battery/balanced/default, or hand scheduling to an external scheduler' ;;
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
    case "$newhandoff" in
        ''|fas_rs|off) ;;
        *) json_error '400 Bad Request' 'invalid game handoff policy' ;;
    esac
    case "$scheduler_action" in
        ''|cancel_pending|retry) ;;
        *) json_error '400 Bad Request' 'invalid scheduler action' ;;
    esac

    if [ "$scheduler_action" = "cancel_pending" ]; then
        acquire_profile_scheduler_lock
        if sbm_cancel_pending; then
            release_profile_scheduler_lock
            json_headers
            printf '{"ok":true,"accepted":true,"final":true,'
            emit_profile_state
            printf '}\n'
            exit 0
        fi
        _cancel_rc=$?
        release_profile_scheduler_lock
        json_headers
        printf '{"ok":false,"accepted":false,"final":true,"error":"cancel failed (rc=%s)",' "$_cancel_rc"
        emit_profile_state
        printf '}\n'
        exit 0
    fi

    if [ "$scheduler_action" = "retry" ]; then
        sbm_load_state
        case "$SBM_PHASE" in failed|blocked) ;; *) json_error '409 Conflict' 'scheduler retry requires a terminal failed state' ;; esac
        _retry_rc=0
        sh "$MODDIR/scripts/scheduler_reconcile.sh" retry "$MODDIR" >/dev/null 2>&1 || _retry_rc=$?
        sbm_load_state
        json_headers
        if [ "$_retry_rc" -eq 0 ] && [ "$SBM_PHASE" = "success" ]; then
            printf '{"ok":true,"accepted":true,"final":true,'
        else
            printf '{"ok":false,"accepted":true,"final":true,"error":"scheduler retry reached terminal failure",'
        fi
        emit_profile_state
        printf '}\n'
        exit 0
    fi

    if [ -n "$newowner" ]; then
        _target_mode=pixel
        [ "$newowner" = "external" ] && _target_mode=ugt
        detect_external_scheduler 2>/dev/null || true
        if [ "$_target_mode" = "ugt" ] && [ "$UPERF_DETECTED" != "yes" ]; then
            json_error '409 Conflict' 'UGT is not installed'
        fi
        case "$UPERF_MODULE_ID" in ''|*[!A-Za-z0-9._-]*) ;; *) SBM_UPERF_ID="$UPERF_MODULE_ID" ;; esac
        acquire_profile_scheduler_lock
        _stage_rc=0
        sbm_stage_mode "$_target_mode" || _stage_rc=$?
        release_profile_scheduler_lock
        json_headers
        if [ "$_stage_rc" -eq 0 ]; then
            printf '{"ok":true,"accepted":true,"final":false,'
        elif [ "$_stage_rc" -eq 79 ]; then
            printf '{"ok":true,"accepted":true,"final":true,'
        elif [ "$_stage_rc" -eq 81 ]; then
            printf '{"ok":false,"accepted":false,"final":false,"error":"cancel the existing pending scheduler change first",'
        else
            printf '{"ok":false,"accepted":false,"final":true,"error":"scheduler mode staging failed (rc=%s)",' "$_stage_rc"
        fi
        emit_profile_state
        printf '}\n'
        exit 0
    fi

    if [ -n "$newhandoff" ]; then
        sbm_load_state
        if [ "$SBM_PHASE" != "success" ] || [ "$SBM_EFFECTIVE_MODE" != "pixel" ]; then
            json_error '409 Conflict' 'fas-rs handoff requires a verified Pixel boot mode'
        fi
        so_write_handoff_policy "$newhandoff" \
            || json_error '500 Internal Server Error' 'failed to persist game handoff policy'
        _reconcile_rc=0
        reconcile_owner_now || _reconcile_rc=$?
        _apply_result=$(read_arbiter_value apply_result)
        json_headers
        case "$_apply_result" in failed_*|transition_busy) _transition_ok=false ;; *) _transition_ok=true ;; esac
        [ "$_reconcile_rc" -eq 0 ] || _transition_ok=false
        printf '{"ok":%s,' "$_transition_ok"
        emit_profile_state
        printf '}\n'
        exit 0
    fi

    sbm_load_state
    if [ "$SBM_PHASE" != "success" ] || [ "$SBM_EFFECTIVE_MODE" != "pixel" ]; then
        json_headers
        printf '{"ok":false,"error":"Pixel scheduler is not in a verified writable state",'
        emit_profile_state
        printf '}\n'
        exit 0
    fi

    if [ "$(read_valid_sched_owner)" = "external" ]; then
        detect_external_scheduler 2>/dev/null
        json_headers
        if [ "$EXTERNAL_SCHEDULER_DETECTED" = "yes" ]; then
            printf '{"ok":false,"error":"CPU 调度由 %s 接管"}\n' "$(json_escape "${EXTERNAL_SCHEDULER_NAME:-外部模块}")"
        else
            printf '{"ok":false,"error":"本模块 CPU 调度未启用"}\n'
        fi
        exit 0
    fi

    acquire_profile_scheduler_lock
    if [ "$(read_valid_sched_owner)" = "external" ]; then
        release_profile_scheduler_lock
        json_headers
        printf '{"ok":false,"error":"本模块 CPU 调度未启用"}\n'
        exit 0
    fi

    if [ -n "$newprof" ]; then
        _old_active=$(read_valid_profile "$PROFILE_FILE" balanced)
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
        if ! commit_profile_state "$newprof" "$newprof" manual manual_selected; then
            rollback_profile_runtime_or_error "$_old_active"
        fi
        append_profile_history "$newprof" "manual_selected"
        release_profile_scheduler_lock
        json_headers
        printf '{"ok":true,'
        emit_profile_state
        printf '}\n'
        exit 0
    fi

    case "$newpolicy" in
        auto)
            _active=$(read_valid_profile "$PROFILE_FILE" 'balanced')
            _old_active="$_active"
            _manual=$(read_valid_profile "$PROFILE_MANUAL_FILE" balanced)
            case "$_active" in
                balanced|battery) _target="$_active" ;;
                *) _target="balanced" ;;
            esac
            _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$_target" "$MODDIR" 2>/dev/null)
            [ "$?" -eq 0 ] || json_error '500 Internal Server Error' 'profile script failed'
            if ! commit_profile_state "$_target" "$_manual" auto auto_enabled; then
                rollback_profile_runtime_or_error "$_old_active"
            fi
            append_profile_history "$_target" "auto_enabled"
            ;;
        manual)
            _manual=$(read_valid_profile "$PROFILE_MANUAL_FILE" 'balanced')
            _old_active=$(read_valid_profile "$PROFILE_FILE" balanced)
            _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$_manual" "$MODDIR" 2>/dev/null)
            [ "$?" -eq 0 ] || json_error '500 Internal Server Error' 'profile script failed'
            if ! commit_profile_state "$_manual" "$_manual" manual manual_policy; then
                rollback_profile_runtime_or_error "$_old_active"
            fi
            append_profile_history "$_manual" "manual_policy"
            ;;
        '')
            json_error '400 Bad Request' 'missing profile, policy, scheduler owner, or game handoff policy'
            ;;
    esac
    release_profile_scheduler_lock
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
