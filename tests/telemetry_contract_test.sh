#!/bin/sh
# Host fixture for the telemetry CGI contract.  No Android settings, modem,
# wakelock or alarm APIs are touched.
set -u
MOD="${1:-.}"
ROOT="${TMPDIR:-/tmp}/pixel9pro_telemetry_$$"
FIXTURE="$ROOT/module"
mkdir -p "$FIXTURE/scripts" "$FIXTURE/webroot/cgi-bin" "$FIXTURE/config" "$FIXTURE/download" "$FIXTURE/logs" || exit 2
cp "$MOD/webroot/cgi-bin/_common.sh" "$FIXTURE/webroot/cgi-bin/" || exit 2
cp "$MOD/webroot/cgi-bin/telemetry.sh" "$FIXTURE/webroot/cgi-bin/" || exit 2
cp "$MOD/webroot/cgi-bin/audit_log.sh" "$FIXTURE/webroot/cgi-bin/" || exit 2
cp "$MOD/scripts/telemetry_lib.sh" "$FIXTURE/scripts/" || exit 2
cp "$MOD/scripts/telemetry_worker.sh" "$FIXTURE/scripts/" || exit 2
cp "$MOD/scripts/audit_log_lib.sh" "$FIXTURE/scripts/" || exit 2
cp "$MOD/scripts/display_state_lib.sh" "$FIXTURE/scripts/" || exit 2
printf 'version=test\n' > "$FIXTURE/module.prop"
printf 'fixture-token\n' > "$FIXTURE/.webui_token"

run_get() {
    REQUEST_METHOD=GET REMOTE_ADDR=127.0.0.1 HTTP_X_PIXEL9PRO_TOKEN=fixture-token \
    PIXEL9PRO_MODDIR="$FIXTURE" PIXEL9PRO_TELEMETRY_ROOT="$FIXTURE/.telemetry" \
    PIXEL9PRO_DOWNLOAD_DIR="$FIXTURE/download" PIXEL9PRO_AUDIT_LOG_DIR="$FIXTURE/logs" \
        sh "$FIXTURE/webroot/cgi-bin/$1"
}
run_post() {
    _body="$2"
    REQUEST_METHOD=POST CONTENT_TYPE=application/json CONTENT_LENGTH=$(printf '%s' "$_body" | wc -c) \
    REMOTE_ADDR=127.0.0.1 HTTP_X_PIXEL9PRO_TOKEN=fixture-token \
    PIXEL9PRO_MODDIR="$FIXTURE" PIXEL9PRO_TELEMETRY_ROOT="$FIXTURE/.telemetry" \
    PIXEL9PRO_DOWNLOAD_DIR="$FIXTURE/download" PIXEL9PRO_AUDIT_LOG_DIR="$FIXTURE/logs" \
        sh -c 'printf "%s" "$1" | sh "$2"' sh "$_body" "$FIXTURE/webroot/cgi-bin/$1"
}
assert_contains() {
    case "$2" in *"$1"*) printf 'ok - %s\n' "$3" ;; *) printf 'not ok - %s\n' "$3"; exit 1 ;; esac
}

_status=$(QUERY_STRING='action=status' run_get telemetry.sh)
assert_contains '"session":null' "$_status" 'initial status is empty'
printf '%s,77,123456,Discharging\n' "$(date +%s)" > "$FIXTURE/.power_history"
printf '%s,39000\n' "$(date +%s)" > "$FIXTURE/.thermal_history"
_legacy=$(QUERY_STRING='action=history&minutes=1' run_get telemetry.sh)
assert_contains 'legacy_history' "$_legacy" 'history falls back to legacy module samples'
_start=$(run_post telemetry.sh '{"action":"start","duration_sec":60,"max_bytes":65536}')
assert_contains '"status":"running"' "$_start" 'start returns running session'
_id=$(printf '%s' "$_start" | sed -n 's/.*"id":"\([A-Za-z0-9_.:-]*\)".*/\1/p')
[ -n "$_id" ] || { printf 'not ok - session id missing\n'; exit 1; }
sleep 1
_stop=$(run_post telemetry.sh '{"action":"stop"}')
assert_contains '"ok":true' "$_stop" 'stop request accepted'
sleep 1
_history=$(QUERY_STRING="action=history&session_id=$_id&minutes=1" run_get telemetry.sh)
assert_contains '"power":[' "$_history" 'history exposes power series'
assert_contains '"thermal":[' "$_history" 'history exposes thermal series'
_export=$(run_post telemetry.sh '{"action":"export"}')
assert_contains '"files":[' "$_export" 'export returns file manifest'
_audit=$(QUERY_STRING='limit=10' run_get audit_log.sh)
assert_contains '"lines":[' "$_audit" 'audit endpoint returns bounded lines'
printf 'ok - telemetry contract complete\n'
rm -rf "$ROOT"
