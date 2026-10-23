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
cgi_json_schema 'action:string'
_action=$(cgi_json_field action)
[ "$_action" = "tick" ] || json_error '400 Bad Request' 'invalid owner arbiter action'

FAS_ROOT="${PIXEL9PRO_FAS_ROOT:-/data/adb/fas_rs}"

detect_external_scheduler 2>/dev/null

if [ "${FAS_RS_DETECTED:-no}" != "yes" ]; then
    json_status_headers '409 Conflict'
    printf '{"ok":false,"error":"未检测到 fas-rs，owner 手动唤醒不可用"}\n'
    exit 0
fi

if [ ! -f "$MODDIR/scripts/owner_arbiter.sh" ]; then
    json_error '503 Service Unavailable' 'owner arbiter script missing'
fi

_handoff=$(cat "$MODDIR/.game_handoff_policy" 2>/dev/null | tr -d ' \n\r\t')
_lease_state=$(cat "$FAS_ROOT/.owner_state" 2>/dev/null | tr -d '\r\n')
_lease_active=0
case "$_lease_state" in *fas-rs:game:*) _lease_active=1 ;; esac
if [ "$_handoff" != fas_rs ] && [ "$_lease_active" -ne 1 ]; then
    json_status_headers '409 Conflict'
    printf '{"ok":false,"error":"未开启游戏移交且没有有效 lease，owner arbiter 不运行"}\n'
    exit 0
fi

. "$MODDIR/scripts/scheduler_async_lib.sh" && scheduler_async_init "$MODDIR" \
    || json_error '500 Internal Server Error' 'scheduler async contract unavailable'
scheduler_async_start tick || json_error '409 Conflict' 'scheduler operation already running or could not start'
json_headers
printf '{"ok":true,"accepted":true,"final":false'
scheduler_async_json
printf '}\n'
