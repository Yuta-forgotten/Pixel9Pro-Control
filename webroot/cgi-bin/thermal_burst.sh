#!/system/bin/sh
# GET returns the foreground thermal-capture window. POST atomically starts or
# stops the 5-second sampling hint consumed by service.sh.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

BURST_FILE="$MODDIR/.thermal_burst_until"

require_loopback

case "$REQUEST_METHOD" in
    GET)
        json_headers
        _until=$(cat "$BURST_FILE" 2>/dev/null | tr -d ' \n\r')
        case "$_until" in ''|*[!0-9]*) _until=0 ;; esac
        _now=$(date +%s 2>/dev/null || echo 0)
        _active=false
        [ -n "$_until" ] && [ "$_until" -gt "$_now" ] 2>/dev/null && _active=true
        printf '{"ok":true,"burst_active":%s,"burst_until":"%s"}\n' "$_active" "$_until"
        ;;
    POST)
        require_json_post
        require_token
        acquire_lock "thermal_burst"
        read_json_body 256
        _body="$JSON_BODY"
        _action=$(printf '%s' "$_body" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p')
        _duration=$(printf '%s' "$_body" | sed -n 's/.*"duration_sec"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
        case "$_action" in
            stop)
                cgi_atomic_write "$BURST_FILE" 0 \
                    || json_error '500 Internal Server Error' 'failed to stop thermal capture'
                json_headers
                printf '{"ok":true,"burst_active":false,"burst_until":"0","duration_sec":0}\n'
                exit 0
                ;;
            start) ;;
            *) json_error '400 Bad Request' 'invalid action' ;;
        esac
        [ -n "$_duration" ] || _duration=300
        case "$_duration" in 60|120|300|600) ;; *) json_error '400 Bad Request' 'invalid duration_sec' ;; esac
        _now=$(date +%s 2>/dev/null || echo 0)
        _until=$((_now + _duration))
        cgi_atomic_write "$BURST_FILE" "$_until" \
            || json_error '500 Internal Server Error' 'failed to start thermal capture'
        json_headers
        printf '{"ok":true,"burst_active":true,"burst_until":"%s","duration_sec":%s}\n' "$_until" "$_duration"
        ;;
    *)
        json_error '405 Method Not Allowed' 'GET or POST only'
        ;;
esac
