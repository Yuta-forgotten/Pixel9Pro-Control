#!/system/bin/sh

# Thermal policy CGI. System removes the module overlay and requires a
# reboot when an active mount may still exist. Custom always rebuilds from the
# private, verified device stock snapshot.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback

THERMAL_PROFILE_LIB="$MODDIR/scripts/thermal_profile.sh"
THERMAL_POLICY_LIB="$MODDIR/scripts/thermal_policy_lib.sh"
[ -r "$THERMAL_PROFILE_LIB" ] && . "$THERMAL_PROFILE_LIB" \
    || json_error '500 Internal Server Error' 'thermal profile library not found'
[ -r "$THERMAL_POLICY_LIB" ] && . "$THERMAL_POLICY_LIB" && thermal_policy_init "$MODDIR" \
    || json_error '500 Internal Server Error' 'thermal policy library not found'

DEVICE=$(cat "$MODDIR/.device_variant" 2>/dev/null | tr -d ' \r\n\t')
case "$DEVICE" in caiman|komodo) ;; *) json_error '500 Internal Server Error' 'invalid device variant' ;; esac
STOCK_JSON=$(thermal_policy_snapshot_path "$DEVICE") \
    || json_error '500 Internal Server Error' 'cannot resolve thermal stock snapshot'
OUT_JSON="$THERMAL_OVERLAY_FILE"

thermal_service_getprop() {
    _ts_bin=/system/bin/getprop
    [ "${PIXEL9PRO_CGI_TEST_MODE:-0}" = 1 ] && _ts_bin="${PIXEL9PRO_ANDROID_GETPROP:-getprop}"
    "$_ts_bin" "$@"
}

thermal_service_stop() {
    _ts_bin=/system/bin/stop
    [ "${PIXEL9PRO_CGI_TEST_MODE:-0}" = 1 ] && _ts_bin="${PIXEL9PRO_ANDROID_STOP:-stop}"
    "$_ts_bin" "$@"
}

thermal_service_start() {
    _ts_bin=/system/bin/start
    [ "${PIXEL9PRO_CGI_TEST_MODE:-0}" = 1 ] && _ts_bin="${PIXEL9PRO_ANDROID_START:-start}"
    "$_ts_bin" "$@"
}

thermal_service_log() {
    _ts_bin=/system/bin/log
    [ "${PIXEL9PRO_CGI_TEST_MODE:-0}" = 1 ] && _ts_bin="${PIXEL9PRO_ANDROID_LOG:-log}"
    "$_ts_bin" "$@"
}

ensure_thermal_service_running() {
    _ts_service="$1"
    for _ts_attempt in 1 2; do
        thermal_service_start "$_ts_service" 2>/dev/null || true
        sleep 1
        [ "$(thermal_service_getprop "init.svc.$_ts_service" 2>/dev/null)" = running ] && return 0
    done
    return 1
}

thermal_hal_effective_matches() {
    _ts_expected=$(awk -v target=VIRTUAL-SKIN '
        /"Name"/ { n=$0; sub(/.*"Name": *"/, "", n); sub(/".*/, "", n) }
        n==target && /"HotThreshold"/ { line=$0; sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line); gsub(/[ "]/, "", line); print line; exit }
    ' "$OUT_JSON" 2>/dev/null)
    [ -n "$_ts_expected" ] || return 1
    _ts_actual=$(dumpsys thermalservice 2>/dev/null | awk \
        '/TemperatureThreshold.*mName=VIRTUAL-SKIN,/ { print; exit }' \
        | sed 's/.*mHotThrottlingThresholds=\[//; s/\].*//; s/ //g')
    [ -n "$_ts_actual" ] || return 1
    _ts_expected=$(printf '%s' "$_ts_expected" | sed 's/NAN/NaN/g')
    [ "$_ts_actual" = "$_ts_expected" ]
}

parse_thermal_policy() {
    printf '%s\n' "$1" | sed -n 's/.*"policy"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p'
}

parse_thermal_offset() {
    printf '%s\n' "$1" | sed -n 's/.*"offset"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p'
}

thermal_snapshot_transaction() {
    TS_OVERLAY_EXISTED=0
    TS_POLICY_EXISTED=0
    TS_OFFSET_EXISTED=0
    [ -e "$OUT_JSON" ] && TS_OVERLAY_EXISTED=1
    [ -e "$THERMAL_POLICY_FILE" ] && TS_POLICY_EXISTED=1
    [ -e "$THERMAL_OFFSET_FILE" ] && TS_OFFSET_EXISTED=1
    TS_OLD_POLICY=$(cat "$THERMAL_POLICY_FILE" 2>/dev/null)
    TS_OLD_OFFSET=$(cat "$THERMAL_OFFSET_FILE" 2>/dev/null)
    if [ "$TS_OVERLAY_EXISTED" -eq 1 ]; then
        cp "$OUT_JSON" "$TS_OVERLAY_BACKUP" 2>/dev/null || return 1
    fi
}

thermal_restore_transaction() {
    _ts_restore_failed=0
    if [ "$TS_OVERLAY_EXISTED" -eq 1 ]; then
        mkdir -p "${OUT_JSON%/*}" 2>/dev/null \
            && cp "$TS_OVERLAY_BACKUP" "$OUT_JSON" 2>/dev/null || _ts_restore_failed=1
    else
        rm -f "$OUT_JSON" 2>/dev/null || _ts_restore_failed=1
    fi
    cgi_restore_file "$THERMAL_POLICY_FILE" "$TS_POLICY_EXISTED" "$TS_OLD_POLICY" || _ts_restore_failed=1
    cgi_restore_file "$THERMAL_OFFSET_FILE" "$TS_OFFSET_EXISTED" "$TS_OLD_OFFSET" || _ts_restore_failed=1
    [ "$_ts_restore_failed" -eq 0 ]
}

thermal_commit_state() {
    cgi_atomic_write "$THERMAL_POLICY_FILE" "$1" \
        && cgi_atomic_write "$THERMAL_OFFSET_FILE" "$2"
}

emit_thermal_state() {
    _ts_policy=$(thermal_policy_read)
    _ts_offset=$(cat "$THERMAL_OFFSET_FILE" 2>/dev/null | tr -d ' \r\n\t')
    _ts_offset=$(thermal_normalize_offset "$_ts_offset" "$THERMAL_DEFAULT_OFFSET")
    [ -f "$OUT_JSON" ] && _ts_overlay=true || _ts_overlay=false
    if thermal_policy_validate_stock "$STOCK_JSON"; then _ts_custom=true; else _ts_custom=false; fi
    printf '"policy":"%s","offset":%s,"overlay_present":%s,"custom_available":%s,"thermal_contract":' \
        "$_ts_policy" "$_ts_offset" "$_ts_overlay" "$_ts_custom"
    thermal_print_ui_contract_json
}

if [ "$REQUEST_METHOD" = GET ]; then
    json_headers
    printf '{'
    emit_thermal_state
    printf '}\n'
    exit 0
fi

require_json_post
require_token
acquire_lock thermal
read_json_body 512
policy=$(parse_thermal_policy "$JSON_BODY")
offset=$(parse_thermal_offset "$JSON_BODY")
[ -n "$policy" ] || { [ -n "$offset" ] && policy=custom; }
thermal_policy_is_valid "$policy" || json_error '400 Bad Request' 'invalid thermal policy'
if [ "$policy" = custom ]; then
    thermal_is_valid_offset "$offset" || json_error '400 Bad Request' 'invalid thermal offset'
else
    _ts_saved_offset=$(cat "$THERMAL_OFFSET_FILE" 2>/dev/null | tr -d ' \r\n\t')
    offset=$(thermal_normalize_offset "$_ts_saved_offset" "$THERMAL_DEFAULT_OFFSET")
fi

mkdir -p "$LOCKDIR_BASE/tmp" 2>/dev/null \
    && chmod 700 "$LOCKDIR_BASE/tmp" 2>/dev/null \
    || json_error '500 Internal Server Error' 'cannot create thermal transaction directory'
TS_OVERLAY_BACKUP="$LOCKDIR_BASE/tmp/thermal_overlay_$$"
TS_CANDIDATE="$LOCKDIR_BASE/tmp/thermal_candidate_$$"
thermal_transaction_cleanup() {
    rm -f "$TS_OVERLAY_BACKUP" "$TS_CANDIDATE" 2>/dev/null
    release_lock
}
trap 'thermal_transaction_cleanup' EXIT
trap 'thermal_transaction_cleanup; exit 130' INT
trap 'thermal_transaction_cleanup; exit 143' TERM
thermal_snapshot_transaction \
    || json_error '500 Internal Server Error' 'cannot snapshot thermal transaction'

if [ "$policy" != custom ]; then
    thermal_policy_remove_overlay \
        || json_error '500 Internal Server Error' 'cannot remove thermal overlay'
    if ! thermal_commit_state "$policy" "$offset"; then
        thermal_restore_transaction >/dev/null 2>&1 || true
        json_error '500 Internal Server Error' 'cannot commit thermal policy; previous state restored'
    fi
    [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] \
        && audit_log_event thermal policy success THERMAL_SYSTEM_COMMITTED 0 >/dev/null 2>&1 \
        || true
    json_headers
    printf '{"ok":true,"reboot_required":%s,"effective_state":"%s",' \
        "$( [ "$TS_OVERLAY_EXISTED" -eq 1 ] && printf true || printf false )" \
        "$( [ "$TS_OVERLAY_EXISTED" -eq 1 ] && printf pending_reboot || printf "$policy" )"
    emit_thermal_state
    printf '}\n'
    exit 0
fi

old_policy=$(thermal_policy_read)
selected_config=$(thermal_service_getprop vendor.thermal.config 2>/dev/null)
[ -n "$selected_config" ] || selected_config=thermal_info_config.json
case "$selected_config" in
    thermal_info_config.json) ;;
    thermal_info_config_lpm.json)
        [ -r "/vendor/etc/$selected_config" ] \
            || json_error '500 Internal Server Error' 'selected Thermal HAL config is missing'
        ;;
    *) json_error '409 Conflict' 'custom thermal is unsupported by the selected Thermal HAL config' ;;
esac
if ! thermal_policy_validate_stock "$STOCK_JSON"; then
    case "$old_policy:$TS_OVERLAY_EXISTED" in
        system:0)
            thermal_policy_capture_stock /vendor/etc/thermal_info_config.json "$STOCK_JSON" \
                || json_error '500 Internal Server Error' 'THERMAL_STOCK_MISSING'
            ;;
        *) json_error '500 Internal Server Error' 'THERMAL_STOCK_MISSING' ;;
    esac
fi
thermal_generate_config "$STOCK_JSON" "$TS_CANDIDATE" "$offset" \
    || json_error '500 Internal Server Error' 'THERMAL_CONFIG_INVALID'
mkdir -p "${OUT_JSON%/*}" 2>/dev/null \
    && mv "$TS_CANDIDATE" "$OUT_JSON" 2>/dev/null \
    || json_error '500 Internal Server Error' 'thermal overlay commit failed'
if ! thermal_commit_state custom "$offset"; then
    thermal_restore_transaction >/dev/null 2>&1 || true
    json_error '500 Internal Server Error' 'thermal state commit failed; previous state restored'
fi

restarted=false
for service in vendor.thermal-hal vendor.thermal-hal-2-0 thermal-hal-2-0 thermalserviced; do
    [ "$(thermal_service_getprop "init.svc.$service" 2>/dev/null)" = running ] || continue
    if ! thermal_service_stop "$service" 2>/dev/null \
        || ! ensure_thermal_service_running "$service"; then
        thermal_restore_transaction >/dev/null 2>&1 || true
        ensure_thermal_service_running "$service" >/dev/null 2>&1 || true
        json_error '500 Internal Server Error' 'thermal restart failed; previous state restored'
    fi
    if thermal_hal_effective_matches; then
        restarted=true
        thermal_service_log -t pixel9pro_ctrl "Thermal custom policy verified: offset=${offset}C"
    fi
    break
done

[ "$AUDIT_LOG_AVAILABLE" -eq 1 ] \
    && audit_log_event thermal policy success "$( [ "$restarted" = true ] && printf THERMAL_READBACK_VERIFIED || printf REBOOT_REQUIRED )" 0 >/dev/null 2>&1 \
    || true
json_headers
printf '{"ok":true,"restarted":%s,"reboot_required":%s,"effective_state":"%s",' \
    "$restarted" "$( [ "$restarted" = true ] && printf false || printf true )" \
    "$( [ "$restarted" = true ] && printf verified || printf pending_reboot )"
emit_thermal_state
printf '}\n'
