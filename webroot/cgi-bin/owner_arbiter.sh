#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/owner_arbiter.sh
# POST -> 手动触发 owner arbiter tick, 仅在检测到 fas-rs 时允许
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

[ -f "$MODDIR/scripts/scheduler_detect_lib.sh" ] && . "$MODDIR/scripts/scheduler_detect_lib.sh"

require_loopback
require_json_post
require_token
acquire_lock "owner_arbiter"

detect_external_scheduler 2>/dev/null

if [ "${FAS_RS_DETECTED:-no}" != "yes" ]; then
    json_headers
    printf '{"ok":false,"error":"未检测到 fas-rs，owner 手动唤醒不可用"}\n'
    exit 0
fi

if [ ! -f "$MODDIR/scripts/owner_arbiter.sh" ]; then
    json_error '503 Service Unavailable' 'owner arbiter script missing'
fi

_screen="on"
_drm=$(cat /sys/class/drm/card0-DSI-1/enabled 2>/dev/null | tr -d ' \r\n\t')
case "$_drm" in
    disabled) _screen="off" ;;
    enabled) _screen="on" ;;
esac

_out=$(sh "$MODDIR/scripts/owner_arbiter.sh" apply-tick "$MODDIR" "$_screen" 2>&1)
_rc=$?
_state=$(cat /data/adb/fas_rs/.arbiter_state 2>/dev/null)

json_headers
if [ "$_rc" -eq 0 ]; then
    printf '{"ok":true,"screen":"%s","output":"%s","state":"%s"}\n' \
        "$(json_escape "$_screen")" "$(json_escape "$_out")" "$(json_escape "$_state")"
else
    printf '{"ok":false,"error":"owner arbiter tick failed","screen":"%s","output":"%s","state":"%s"}\n' \
        "$(json_escape "$_screen")" "$(json_escape "$_out")" "$(json_escape "$_state")"
fi
