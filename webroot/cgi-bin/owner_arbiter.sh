#!/system/bin/sh
# Authenticated manual owner-arbiter tick. The request is available only when
# fas-rs is detected; the runtime arbiter still owns all transition checks.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback
SCHEDULER_INVENTORY_PATH="${SCHEDULER_INVENTORY_PATH:-$MODDIR/.scheduler_inventory}"

[ -r "$MODDIR/scripts/scheduler_detect_lib.sh" ] && . "$MODDIR/scripts/scheduler_detect_lib.sh" \
    || json_error '500 Internal Server Error' 'scheduler detection contract not found'
[ -r "$MODDIR/scripts/display_state_lib.sh" ] && . "$MODDIR/scripts/display_state_lib.sh" \
    || json_error '500 Internal Server Error' 'display state contract not found'
require_json_post
require_token
acquire_lock "owner_arbiter"
read_json_body 128
_action=$(printf '%s' "$JSON_BODY" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')
[ "$_action" = "tick" ] || json_error '400 Bad Request' 'invalid owner arbiter action'

FAS_ROOT="${PIXEL9PRO_FAS_ROOT:-/data/adb/fas_rs}"

detect_external_scheduler 2>/dev/null

if [ "${FAS_RS_DETECTED:-no}" != "yes" ]; then
    json_headers
    printf '{"ok":false,"error":"未检测到 fas-rs，owner 手动唤醒不可用"}\n'
    exit 0
fi

if [ ! -f "$MODDIR/scripts/owner_arbiter.sh" ]; then
    json_error '503 Service Unavailable' 'owner arbiter script missing'
fi

display_state_read >/dev/null 2>&1 || true
_display_state="$DISPLAY_STATE"
_display_source="$DISPLAY_STATE_SOURCE"
_screen=$(display_state_legacy_screen)

_out=$(OWNER_ARBITER_FAS_ROOT="$FAS_ROOT" \
    sh "$MODDIR/scripts/owner_arbiter.sh" apply-tick "$MODDIR" "$_screen" 2>&1)
_rc=$?
_state=$(cat "$FAS_ROOT/.arbiter_state" 2>/dev/null)

json_headers
if [ "$_rc" -eq 0 ]; then
    printf '{"ok":true,"screen":"%s","screen_source":"%s","output":"%s","state":"%s"}\n' \
        "$(json_escape "$_display_state")" "$(json_escape "$_display_source")" \
        "$(json_escape "$_out")" "$(json_escape "$_state")"
else
    printf '{"ok":false,"error":"owner arbiter tick failed","screen":"%s","screen_source":"%s","output":"%s","state":"%s"}\n' \
        "$(json_escape "$_display_state")" "$(json_escape "$_display_source")" \
        "$(json_escape "$_out")" "$(json_escape "$_state")"
fi
