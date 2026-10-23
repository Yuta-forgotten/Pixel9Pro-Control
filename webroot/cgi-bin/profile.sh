#!/system/bin/sh
# Scheduler/profile state CGI. Desired owner, effective owner, handoff policy,
# and Pixel profile state are separate contracts and are committed explicitly.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback

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
[ -r "$MODDIR/scripts/profile_state_lib.sh" ] && . "$MODDIR/scripts/profile_state_lib.sh" \
    && profile_state_init "$MODDIR" \
    || json_error '500 Internal Server Error' 'profile state contract not found'
[ -r "$MODDIR/scripts/scheduler_boot_mode_lib.sh" ] && . "$MODDIR/scripts/scheduler_boot_mode_lib.sh" \
    || json_error '500 Internal Server Error' 'scheduler boot-mode contract not found'
[ -r "$MODDIR/scripts/scheduler_transition_guard_lib.sh" ] && . "$MODDIR/scripts/scheduler_transition_guard_lib.sh" \
    || json_error '500 Internal Server Error' 'scheduler transition guard not found'
[ -r "$MODDIR/scripts/scheduler_capability_lib.sh" ] && . "$MODDIR/scripts/scheduler_capability_lib.sh" \
    && scheduler_capability_init "$MODDIR" \
    || json_error '500 Internal Server Error' 'scheduler capability contract not found'
scheduler_owner_init "$MODDIR" "$FAS_ROOT"
sbm_init "$MODDIR" "$FAS_ROOT"
. "$MODDIR/scripts/scheduler_async_lib.sh" && scheduler_async_init "$MODDIR" \
    || json_error '500 Internal Server Error' 'scheduler async contract unavailable'

PROFILE_SCHEDULER_LOCKED=0
PROFILE_REQUEST_LOCK_MAX_ATTEMPTS="${PROFILE_REQUEST_LOCK_MAX_ATTEMPTS:-3}"
PROFILE_REQUEST_LOCK_RETRY_SLEEP_S="${PROFILE_REQUEST_LOCK_RETRY_SLEEP_S:-1}"

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
    SO_TRANSITION_LOCK_MAX_ATTEMPTS="$PROFILE_REQUEST_LOCK_MAX_ATTEMPTS"
    SO_TRANSITION_LOCK_RETRY_SLEEP_S="$PROFILE_REQUEST_LOCK_RETRY_SLEEP_S"
    so_acquire_transition_lock \
        || json_error '409 Conflict' 'scheduler transition busy'
    PROFILE_SCHEDULER_LOCKED=1
    trap 'profile_request_cleanup' EXIT
    trap 'profile_request_cleanup; exit 130' INT
    trap 'profile_request_cleanup; exit 143' TERM
    so_migrate_state >/dev/null 2>&1 \
        || json_error '500 Internal Server Error' 'scheduler owner state migration failed'
}

acquire_scheduler_mode_lock() {
    SO_TRANSITION_LOCK_MAX_ATTEMPTS="$PROFILE_REQUEST_LOCK_MAX_ATTEMPTS"
    SO_TRANSITION_LOCK_RETRY_SLEEP_S="$PROFILE_REQUEST_LOCK_RETRY_SLEEP_S"
    so_acquire_transition_lock \
        || json_error '409 Conflict' 'scheduler transition busy'
    PROFILE_SCHEDULER_LOCKED=1
    trap 'profile_request_cleanup' EXIT
    trap 'profile_request_cleanup; exit 130' INT
    trap 'profile_request_cleanup; exit 143' TERM
}

require_locked_pixel_scheduler() {
    sbm_load_state
    if [ "$SBM_PHASE" != "success" ] || [ "$SBM_EFFECTIVE_MODE" != "pixel" ] \
        || [ "$(read_valid_sched_owner)" != "pixel" ]; then
        json_error '409 Conflict' 'Pixel scheduler is not in a verified writable state'
    fi
}

require_locked_verified_baseline() {
    sbm_load_state
    _locked_desired_owner=$(so_read_desired_owner)
    _locked_expected_mode=$(sbm_owner_to_mode "$_locked_desired_owner")
    if [ "$SBM_PHASE" != "success" ] \
        || [ "$SBM_EFFECTIVE_MODE" != "$_locked_expected_mode" ]; then
        json_error '409 Conflict' 'scheduler baseline is not in a verified state'
    fi
}

reset_auto_profile_guard() {
    stg_init "$MODDIR/.profile_transition_guard"
    stg_reset || json_error '500 Internal Server Error' 'failed to reset automatic profile retry state'
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

commit_profile_state() {
    profile_state_commit "$1" "$2" "$3" "$4"
    _profile_commit_rc=$?
    PROFILE_STATE_ROLLBACK_OK=1
    [ "$PROFILE_STATE_ROLLBACK_RESULT" != "incomplete" ] || PROFILE_STATE_ROLLBACK_OK=0
    return "$_profile_commit_rc"
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
    # History must not hold the shared scheduler lock on a fresh HAL Binder
    # dump. No matching severity snapshot is available here; record missing.
    _ph_sev=-1
    _ph_cap=$(profile_state_read_uclamp_cap)
    _ph_response=$(profile_state_read_response_triplet)
    _ph_policy=$(profile_state_read_policy)
    ( profile_state_append_history "$_ph_profile" "$_ph_reason" "$_ph_epoch" "$_ph_policy" \
        "$_ph_owner" "$_ph_charging" "$_ph_vs" "$_ph_sev" "$_ph_cap" "$_ph_response" ) \
        >/dev/null 2>&1 </dev/null &
}

# Mutation responses only publish state that has already been verified and
# committed by the current request.  Full scheduler discovery and contract
# serialization remain on GET so a completed write cannot be reported as a
# client timeout while unrelated read-only details are still being assembled.
emit_profile_mutation_state() {
    _mutation_active=$(profile_state_read_profile "$PROFILE_FILE" 'balanced')
    _mutation_manual=$(profile_state_read_profile "$PROFILE_MANUAL_FILE" "$_mutation_active")
    _mutation_policy=$(profile_state_read_policy)
    _mutation_sched_owner=$(read_valid_desired_sched_owner)
    _mutation_effective_owner=$(read_valid_sched_owner)
    _mutation_handoff=$(read_valid_handoff_policy)
    _mutation_reason=$(cat "$PROFILE_AUTO_REASON_FILE" 2>/dev/null | tr -d '\r')

    printf '"state_scope":"profile_mutation","scheduler_mode":"%s","scheduler_capability":"%s","profile":"%s","manual_profile":"%s","policy":"%s","sched_owner":"%s","sched_effective_owner":"%s","game_handoff_policy":"%s","auto_reason":"%s"' \
        "$(scheduler_mode_read)" "$(scheduler_capability_read)" \
        "$_mutation_active" "$_mutation_manual" "$_mutation_policy" \
        "$_mutation_sched_owner" "$_mutation_effective_owner" "$_mutation_handoff" \
        "$(json_escape "$_mutation_reason")"
    emit_profile_transition_state
}

emit_profile_transition_state() {
    stg_init "$MODDIR/.profile_transition_guard"
    stg_load
    printf ',"profile_transition":{"key":"%s","attempts":%s,"first_epoch":"%s","deadline_epoch":"%s","terminal":"%s","ok":"%s","result":"%s"}' \
        "$(json_escape "$STG_KEY")" "${STG_ATTEMPTS:-0}" \
        "$(json_escape "$STG_FIRST_EPOCH")" "$(json_escape "$STG_DEADLINE_EPOCH")" \
        "$(json_escape "$STG_TERMINAL")" "$(json_escape "$STG_OK")" "$(json_escape "$STG_RESULT")"
    scheduler_async_json
}

emit_profile_arbiter_state() {
    printf ',"arbiter_state":"%s","arbiter_apply_result":"%s","arbiter_reason":"%s"' \
        "$(json_escape "$(read_arbiter_value state)")" \
        "$(json_escape "$(read_arbiter_value apply_result)")" \
        "$(json_escape "$(read_arbiter_value reason)")"
}

emit_scheduler_boot_state() {
    sbm_load_state
    printf ',"scheduler_boot":{"target_mode":"%s","effective_mode":"%s","phase":"%s","final":"%s","ok":"%s","result":"%s","reason":"%s","attempts":%s,"reboot_required":"%s","auto_repair_used":"%s","staged_boot_id":"%s","observed_boot_id":"%s"}' \
        "$(json_escape "$SBM_TARGET_MODE")" "$(json_escape "$SBM_EFFECTIVE_MODE")" \
        "$(json_escape "$SBM_PHASE")" "$(json_escape "$SBM_FINAL")" "$(json_escape "$SBM_OK")" \
        "$(json_escape "$SBM_RESULT")" "$(json_escape "$SBM_REASON")" "${SBM_ATTEMPTS:-0}" \
        "$(json_escape "$SBM_REBOOT_REQUIRED")" "$(json_escape "$SBM_AUTO_REPAIR_USED")" \
        "$(json_escape "$SBM_STAGED_BOOT_ID")" "$(json_escape "$SBM_OBSERVED_BOOT_ID")"
}

emit_scheduler_health_state() {
    _health_status=$(sbm_state_value "$SBM_HEALTH_FILE" status 2>/dev/null)
    _health_reason=$(sbm_state_value "$SBM_HEALTH_FILE" reason 2>/dev/null)
    _health_checked=$(sbm_state_value "$SBM_HEALTH_FILE" checked_epoch 2>/dev/null)
    _health_profile_verified=$(sbm_state_value "$SBM_HEALTH_FILE" profile_verified 2>/dev/null)
    _health_cpufreq=$(sbm_state_value "$SBM_HEALTH_FILE" cpufreq_permissions 2>/dev/null)
    _health_powerhal=$(sbm_state_value "$SBM_HEALTH_FILE" powerhal_failures 2>/dev/null)
    if so_transition_lock_is_active; then
        _health_status=deferred
        _health_reason=transition_in_progress
        _health_checked=$(date +%s 2>/dev/null || printf '0')
        _health_profile_verified=unknown
    fi
    printf ',"scheduler_health":{"status":"%s","reason":"%s","checked_epoch":"%s","profile_verified":"%s","cpufreq_permissions":"%s","powerhal_failures":"%s"}' \
        "$(json_escape "$_health_status")" \
        "$(json_escape "$_health_reason")" \
        "$(json_escape "$_health_checked")" \
        "$(json_escape "$_health_profile_verified")" \
        "$(json_escape "$_health_cpufreq")" \
        "$(json_escape "$_health_powerhal")"
}

emit_profile_state() {
    _active=$(profile_state_read_profile "$PROFILE_FILE" 'balanced')
    _manual=$(profile_state_read_profile "$PROFILE_MANUAL_FILE" "$_active")
    _policy=$(profile_state_read_policy)
    _sched_owner=$(read_valid_desired_sched_owner)
    _sched_effective_owner=$(read_valid_sched_owner)
    _game_handoff_policy=$(read_valid_handoff_policy)
    _arbiter_state=$(read_arbiter_value state)
    _arbiter_apply_result=$(read_arbiter_value apply_result)
    _arbiter_reason=$(read_arbiter_value reason)
    _reason=$(cat "$PROFILE_AUTO_REASON_FILE" 2>/dev/null | tr -d '\r')
    _last_profile_change=$(profile_state_history_last)
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

    printf '"profile":"%s","manual_profile":"%s","policy":"%s","sched_owner":"%s","sched_effective_owner":"%s","game_handoff_policy":"%s","arbiter_state":"%s","arbiter_apply_result":"%s","arbiter_reason":"%s","auto_reason":"%s","last_profile_change":"%s","uperf_detected":%s,"uperf_module_id":"%s","uperf_module_name":"%s","uperf_module_path":"%s","uperf_module_source":"%s","uperf_module_state":"%s","uperf_module_enabled":"%s","uperf_process_alive":"%s","uperf_active":"%s","fas_rs_detected":%s,"fas_rs_module_id":"%s","fas_rs_module_name":"%s","fas_rs_module_path":"%s","fas_rs_module_source":"%s","fas_rs_module_state":"%s","fas_rs_module_enabled":"%s","fas_rs_owner_state":"%s","fas_rs_mode":"%s","fas_rs_process_alive":"%s","fas_rs_runtime_state":"%s","fas_rs_runtime_owner_active":"%s","fas_rs_runtime_target":"%s","fas_rs_active":"%s","external_scheduler_detected":%s,"external_scheduler_active":%s,"external_scheduler_id":"%s","external_scheduler_name":"%s","external_scheduler_kind":"%s","external_scheduler_path":"%s","external_scheduler_source":"%s","external_scheduler_state":"%s","external_scheduler_enabled":"%s","effective_scheduler_owner":"%s","effective_scheduler_name":"%s","effective_scheduler_kind":"%s","effective_scheduler_mode":"%s","profile_surface":"%s","profile_surface_stale":%s,"profile_surface_note":"%s"' \
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
        "$(json_escape "$FAS_RS_PROCESS_ALIVE")" "$(json_escape "$FAS_RS_RUNTIME_STATE")" \
        "$(json_escape "$FAS_RS_RUNTIME_OWNER_ACTIVE")" "$(json_escape "$FAS_RS_RUNTIME_TARGET")" "$(json_escape "$FAS_RS_ACTIVE")" \
        "$_external_scheduler_detected" "$_external_scheduler_active" "$(json_escape "$EXTERNAL_SCHEDULER_ID")" \
        "$(json_escape "$EXTERNAL_SCHEDULER_NAME")" "$(json_escape "$EXTERNAL_SCHEDULER_KIND")" \
        "$(json_escape "$EXTERNAL_SCHEDULER_PATH")" "$(json_escape "$EXTERNAL_SCHEDULER_SOURCE")" \
        "$(json_escape "$EXTERNAL_SCHEDULER_STATE")" "$(json_escape "$EXTERNAL_SCHEDULER_ENABLED")" \
        "$(json_escape "$_effective_scheduler_owner")" "$(json_escape "$_effective_scheduler_name")" \
        "$(json_escape "$_effective_scheduler_kind")" "$(json_escape "$_effective_scheduler_mode")" \
        "$(json_escape "$_profile_surface")" "$_profile_surface_stale" "$(json_escape "$_profile_surface_note")"
    printf ',"cpu_contract":%s' "$_cpu_contract"
    _scheduler_capability_reason=$(sed -n 's/^reason=//p' "$SCHED_CAP_RECEIPT_FILE" 2>/dev/null | head -n 1 | tr -d '\r')
    printf ',"scheduler_mode":"%s","scheduler_capability":"%s","scheduler_capability_reason":"%s"' \
        "$(scheduler_mode_read)" "$(scheduler_capability_read)" "$(json_escape "$_scheduler_capability_reason")"
    printf ',"scheduler_boot":{"target_mode":"%s","effective_mode":"%s","phase":"%s","final":"%s","ok":"%s","result":"%s","reason":"%s","attempts":%s,"reboot_required":"%s","auto_repair_used":"%s","staged_boot_id":"%s","observed_boot_id":"%s"}' \
        "$(json_escape "$SBM_TARGET_MODE")" "$(json_escape "$SBM_EFFECTIVE_MODE")" \
        "$(json_escape "$SBM_PHASE")" "$(json_escape "$SBM_FINAL")" "$(json_escape "$SBM_OK")" \
        "$(json_escape "$SBM_RESULT")" "$(json_escape "$SBM_REASON")" "${SBM_ATTEMPTS:-0}" \
        "$(json_escape "$SBM_REBOOT_REQUIRED")" "$(json_escape "$SBM_AUTO_REPAIR_USED")" \
        "$(json_escape "$SBM_STAGED_BOOT_ID")" "$(json_escape "$SBM_OBSERVED_BOOT_ID")"
    emit_scheduler_health_state
    emit_profile_transition_state
}

if [ "$REQUEST_METHOD" = "POST" ]; then
    IFS=' ' read -r _profile_request_uptime _profile_unused < /proc/uptime
    case "$_profile_request_uptime" in ''|*[!0-9.]*) _profile_request_uptime=0 ;; esac
    require_json_post
    require_token
    acquire_lock "profile"
    read_json_body 512
    body="$JSON_BODY"
    cgi_json_schema 'profile:string policy:string sched_owner:string game_handoff:string scheduler_action:string scheduler_mode:string'
    newprof=$(cgi_json_field profile)
    newpolicy=$(cgi_json_field policy)
    newowner=$(cgi_json_field sched_owner)
    newhandoff=$(cgi_json_field game_handoff)
    scheduler_action=$(cgi_json_field scheduler_action)
    requested_scheduler_mode=$(cgi_json_field scheduler_mode)
    _profile_actions=0
    for _profile_action in "$newprof" "$newpolicy" "$newowner" "$newhandoff" "$scheduler_action" "$requested_scheduler_mode"; do
        [ -z "$_profile_action" ] || _profile_actions=$((_profile_actions + 1))
    done
    [ "$_profile_actions" -le 1 ] || json_error '400 Bad Request' 'submit one scheduler mutation at a time'

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
    case "$requested_scheduler_mode" in
        ''|off) ;;
        active) json_error '409 Conflict' 're-enable scheduler through the module installer and reboot' ;;
        *) json_error '400 Bad Request' 'invalid scheduler mode' ;;
    esac

    scheduler_async_load
    [ "$SA_PENDING" != true ] || json_error '409 Conflict' 'a scheduler operation is already running; read current state before another mutation'
    # Fast APD staging/cancel uses one bounded attempt. Slow validation and
    # owner reconciliation run as explicit finite jobs below.
    SBM_MAX_WRITE_ATTEMPTS=1
    SBM_APD_LIST_TIMEOUT_S=2
    SBM_APD_SET_TIMEOUT_S=3
    SBM_STATE_COMMIT_ATTEMPTS=1

    if [ -n "$requested_scheduler_mode" ]; then
        acquire_scheduler_mode_lock
        _scheduler_cleanup_result=not_needed
        _scheduler_reboot_required=false
        case "$requested_scheduler_mode" in
            off)
                if scheduler_mode_is_active \
                    && [ "$(read_valid_sched_owner)" = pixel ]; then
                    CPU_PROFILE_ALLOW_OFF_CLEANUP=1 \
                        sh "$MODDIR/scripts/cpu_profile.sh" default "$MODDIR" force >/dev/null 2>&1 \
                        && _scheduler_cleanup_result=system_default_restored \
                        || _scheduler_cleanup_result=cleanup_unverified
                elif scheduler_mode_is_active; then
                    _scheduler_cleanup_result=external_owner_untouched
                fi
                scheduler_mode_write off \
                    || json_error '500 Internal Server Error' 'failed to commit scheduler off mode'
                scheduler_capability_probe readonly >/dev/null 2>&1 \
                    && scheduler_capability_commit >/dev/null 2>&1 \
                    || _scheduler_cleanup_result="${_scheduler_cleanup_result}_receipt_unverified"
                profile_state_commit default default manual scheduler_mode_off >/dev/null 2>&1 \
                    || _scheduler_cleanup_result="${_scheduler_cleanup_result}_state_unverified"
                [ "$_scheduler_cleanup_result" = system_default_restored ] \
                    || _scheduler_reboot_required=true
                ;;
        esac
        release_profile_scheduler_lock
        [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] \
            && audit_log_event scheduler mode success SCHEDULER_OFF 0 >/dev/null 2>&1 \
            || true
        json_headers
        printf '{"ok":true,"accepted":true,"final":true,"cleanup_result":"%s","reboot_required":%s,' \
            "$(json_escape "$_scheduler_cleanup_result")" "$_scheduler_reboot_required"
        emit_profile_mutation_state
        printf '}\n'
        exit 0
    fi

    scheduler_mode_is_active \
        || json_error '409 Conflict' '本模块性能调度已关闭'

    if [ "$scheduler_action" = "cancel_pending" ]; then
        acquire_profile_scheduler_lock
        _cancel_rc=0
        sbm_cancel_pending || _cancel_rc=$?
        if [ "$_cancel_rc" -eq 0 ]; then
            release_profile_scheduler_lock
            json_headers
            printf '{"ok":true,"accepted":true,"final":true,'
            emit_profile_mutation_state
            emit_scheduler_boot_state
            printf '}\n'
            exit 0
        fi
        release_profile_scheduler_lock
        json_status_headers '500 Internal Server Error'
        printf '{"ok":false,"accepted":false,"final":true,"error":"cancel failed (rc=%s)",' "$_cancel_rc"
        emit_profile_mutation_state
        emit_scheduler_boot_state
        printf '}\n'
        exit 0
    fi

    if [ "$scheduler_action" = retry ]; then
        sbm_load_state
        case "$SBM_PHASE" in failed|blocked) ;; *) json_error '409 Conflict' 'scheduler retry requires a terminal failed state' ;; esac
        scheduler_async_start retry || json_error '409 Conflict' 'scheduler job could not be accepted'
        json_headers
        printf '{"ok":true,"accepted":true,"final":false,'
        emit_profile_mutation_state
        emit_scheduler_boot_state
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
        if [ "$_stage_rc" -eq 0 ]; then
            json_headers
            printf '{"ok":true,"accepted":true,"final":false,'
        elif [ "$_stage_rc" -eq 79 ]; then
            json_headers
            printf '{"ok":true,"accepted":true,"final":true,'
        elif [ "$_stage_rc" -eq 81 ]; then
            json_status_headers '409 Conflict'
            printf '{"ok":false,"accepted":false,"final":false,"error":"cancel the existing pending scheduler change first",'
        else
            json_status_headers '500 Internal Server Error'
            printf '{"ok":false,"accepted":false,"final":true,"error":"scheduler mode staging failed (rc=%s)",' "$_stage_rc"
        fi
        emit_profile_mutation_state
        emit_scheduler_boot_state
        printf '}\n'
        exit 0
    fi

    if [ -n "$newhandoff" ]; then
        acquire_profile_scheduler_lock
        require_locked_verified_baseline
        if [ "$newhandoff" = "fas_rs" ]; then
            detect_external_scheduler 2>/dev/null || true
            [ "$FAS_RS_DETECTED" = "yes" ] && [ "$FAS_RS_MODULE_ENABLED" = "yes" ] \
                || json_error '409 Conflict' 'fas-rs is not installed or enabled'
        fi
        _old_handoff=$(read_valid_handoff_policy)
        _old_handoff_source=$(so_read_handoff_source)
        so_write_handoff_preference "$newhandoff" user \
            || json_error '500 Internal Server Error' 'failed to persist game handoff policy'
        stg_init "$FAS_ROOT/.owner_mutation_guard"
        if ! stg_reset; then
            if so_write_handoff_preference "$_old_handoff" "$_old_handoff_source" \
                && [ "$(read_valid_handoff_policy)" = "$_old_handoff" ] \
                && [ "$(so_read_handoff_source)" = "$_old_handoff_source" ]; then
                json_error '500 Internal Server Error' 'failed to reset game handoff retry state; previous policy restored'
            fi
            json_error '500 Internal Server Error' 'failed to reset game handoff retry state and rollback was incomplete'
        fi
        release_profile_scheduler_lock
        scheduler_async_start handoff \
            || json_error '500 Internal Server Error' 'handoff preference saved; reconciliation could not start; refresh and retry the owner check'
        json_headers
        printf '{"ok":true,"accepted":true,"committed":true,"final":false,"pending_reason":"handoff preference saved; owner reconciliation is running",'
        emit_profile_mutation_state
        emit_profile_arbiter_state
        printf '}\n'
        exit 0
    fi

    sbm_load_state
    if [ "$SBM_PHASE" != "success" ] || [ "$SBM_EFFECTIVE_MODE" != "pixel" ]; then
        json_status_headers '409 Conflict'
        printf '{"ok":false,"error":"Pixel scheduler is not in a verified writable state",'
        emit_profile_mutation_state
        emit_scheduler_boot_state
        printf '}\n'
        exit 0
    fi

    if [ "$(read_valid_sched_owner)" = "external" ]; then
        detect_external_scheduler 2>/dev/null
        json_status_headers '409 Conflict'
        if [ "$EXTERNAL_SCHEDULER_DETECTED" = "yes" ]; then
            printf '{"ok":false,"error":"CPU 调度由 %s 接管"}\n' "$(json_escape "${EXTERNAL_SCHEDULER_NAME:-外部模块}")"
        else
            printf '{"ok":false,"error":"本模块 CPU 调度未启用"}\n'
        fi
        exit 0
    fi

    acquire_profile_scheduler_lock
    require_locked_pixel_scheduler

    if [ -n "$newpolicy" ] && [ "$(profile_state_read_policy)" = "$newpolicy" ]; then
        release_profile_scheduler_lock
        json_headers
        printf '{"ok":true,"accepted":true,"committed":true,"idempotent":true,"final":true,'
        emit_profile_mutation_state
        printf '}\n'
        exit 0
    fi

    if [ -n "$newprof" ]; then
        reset_auto_profile_guard
        _old_active=$(profile_state_read_profile "$PROFILE_FILE" balanced)
        _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$newprof" "$MODDIR" 2>/dev/null)
        _rc=$?
        if [ "$_rc" -ne 0 ]; then
            case "$_result" in
                BLOCKED:*)
                    _temp_raw=${_result#BLOCKED:}
                    _temp_c=$(awk "BEGIN{printf \"%.1f\", ${_temp_raw:-0}/1000}")
                    json_status_headers '409 Conflict'
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
        printf '{"ok":true,"accepted":true,"final":true,'
        emit_profile_mutation_state
        printf '}\n'
        exit 0
    fi

    case "$newpolicy" in
        auto)
            reset_auto_profile_guard
            _active=$(profile_state_read_profile "$PROFILE_FILE" 'balanced')
            _old_active="$_active"
            _manual=$(profile_state_read_profile "$PROFILE_MANUAL_FILE" balanced)
            case "$_active" in
                balanced|battery) _target="$_active" ;;
                *) _target="balanced" ;;
            esac
            if [ "$_target" != "$_old_active" ]; then
                _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$_target" "$MODDIR" 2>/dev/null)
                [ "$?" -eq 0 ] || json_error '500 Internal Server Error' 'profile script failed'
            fi
            if ! commit_profile_state "$_target" "$_manual" auto auto_enabled; then
                rollback_profile_runtime_or_error "$_old_active"
            fi
            append_profile_history "$_target" "auto_enabled"
            ;;
        manual)
            reset_auto_profile_guard
            _manual=$(profile_state_read_profile "$PROFILE_MANUAL_FILE" 'balanced')
            _old_active=$(profile_state_read_profile "$PROFILE_FILE" balanced)
            if [ "$_manual" != "$_old_active" ]; then
                _result=$(sh "$MODDIR/scripts/cpu_profile.sh" "$_manual" "$MODDIR" 2>/dev/null)
                [ "$?" -eq 0 ] || json_error '500 Internal Server Error' 'profile script failed'
            fi
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
    _profile_duration_ms=$(awk -v start="$_profile_request_uptime" 'BEGIN { getline < "/proc/uptime"; duration=($1-start)*1000; printf "%.0f",duration<0?0:duration }')
    audit_log_event_async scheduler policy success "POLICY_$newpolicy" "$_profile_duration_ms"
    json_headers
    printf '{"ok":true,"accepted":true,"committed":true,"final":true,"duration_ms":%s,' "$_profile_duration_ms"
    emit_profile_mutation_state
    printf '}\n'
elif [ "$REQUEST_METHOD" = "GET" ]; then
    json_headers
    printf '{'
    case "&${QUERY_STRING:-}&" in
        *'&compact=1&'*)
            emit_profile_mutation_state
            emit_scheduler_boot_state
            emit_scheduler_health_state
            ;;
        *) emit_profile_state ;;
    esac
    printf '}\n'
else
    json_error '405 Method Not Allowed' 'GET or POST only'
fi
