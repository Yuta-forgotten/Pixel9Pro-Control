#!/system/bin/sh

# Local fixture for CGI rollback/error contracts. It never touches Android
# settings or telephony; mock commands persist their state under TEST_ROOT.

if [ -x /system/bin/sh ]; then
    printf '1..0 # SKIP host-only mock-command fixture\n'
    exit 0
fi

MOD="${1:-${0%/tests/*}}"
TEST_ROOT="${2:-${TMPDIR:-/tmp}/pixel9pro_cgi_failure_$$}"
FIXTURE="$TEST_ROOT/module"
MOCK_BIN="$TEST_ROOT/bin"
MOCK_STATE_DIR="$TEST_ROOT/mock_state"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1"; }

assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (expected=$2 actual=$3)"; fi
}

assert_contains() {
    case "$2" in *"$3"*) ok "$1" ;; *) not_ok "$1 (missing=$3)" ;; esac
}

mkdir -p "$FIXTURE/webroot/cgi-bin" "$FIXTURE/scripts" "$FIXTURE/config" \
    "$FIXTURE/system/vendor/etc" "$FIXTURE/system/vendor/firmware/uecapconfig" \
    "$MOCK_BIN" "$MOCK_STATE_DIR" || exit 2
cp "$MOD/webroot/cgi-bin/_common.sh" "$FIXTURE/webroot/cgi-bin/" || exit 2
cp "$MOD/webroot/cgi-bin/nr_switch.sh" "$FIXTURE/webroot/cgi-bin/" || exit 2
cp "$MOD/webroot/cgi-bin/standby_guard.sh" "$FIXTURE/webroot/cgi-bin/" || exit 2
cp "$MOD/webroot/cgi-bin/set_thermal.sh" "$FIXTURE/webroot/cgi-bin/" || exit 2
cp "$MOD/webroot/cgi-bin/bg_restrict.sh" "$FIXTURE/webroot/cgi-bin/" || exit 2
cp "$MOD/webroot/cgi-bin/uecap.sh" "$FIXTURE/webroot/cgi-bin/" || exit 2
cp "$MOD/webroot/cgi-bin/thermal.sh" "$FIXTURE/webroot/cgi-bin/" || exit 2
cp "$MOD/webroot/cgi-bin/_thermal_cache.sh" "$FIXTURE/webroot/cgi-bin/" || exit 2
cp "$MOD/webroot/cgi-bin/owner_arbiter.sh" "$FIXTURE/webroot/cgi-bin/" || exit 2
cp "$MOD/scripts/runtime_defaults_lib.sh" "$FIXTURE/scripts/" || exit 2
cp "$MOD/scripts/nr_mode_lib.sh" "$FIXTURE/scripts/" || exit 2
cp "$MOD/scripts/thermal_profile.sh" "$FIXTURE/scripts/" || exit 2
cp "$MOD/scripts/bg_restrict_lib.sh" "$FIXTURE/scripts/" || exit 2
cp "$MOD/scripts/app_identity_lib.sh" "$FIXTURE/scripts/" || exit 2
cp "$MOD/scripts/display_state_lib.sh" "$FIXTURE/scripts/" || exit 2
cp "$MOD/scripts/scheduler_detect_lib.sh" "$FIXTURE/scripts/" || exit 2
cp "$MOD/uecap_profile.sh" "$FIXTURE/" || exit 2
cp "$MOD/config/app_identities.tsv" "$FIXTURE/config/" || exit 2
cp "$MOD/system/vendor/etc/thermal_stock.json" "$FIXTURE/system/vendor/etc/" || exit 2
cp "$MOD/system/vendor/etc/thermal_info_config.json" "$FIXTURE/system/vendor/etc/" || exit 2
cp "$MOD/system/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.special.binarypb" "$FIXTURE/system/vendor/firmware/uecapconfig/" || exit 2
cp "$MOD/system/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.balanced.binarypb" "$FIXTURE/system/vendor/firmware/uecapconfig/" || exit 2
cp "$MOD/system/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.universal.binarypb" "$FIXTURE/system/vendor/firmware/uecapconfig/" || exit 2
cp "$MOD/system/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.balanced.binarypb" "$FIXTURE/uecap_target.binarypb" || exit 2
printf 'fixture-token' > "$FIXTURE/.webui_token"

cat > "$MOCK_BIN/android_settings" <<'EOF'
#!/bin/sh
case "$1:$2" in
    get:global)
        [ -f "$MOCK_STATE_DIR/$3" ] && cat "$MOCK_STATE_DIR/$3" || printf 'null\n'
        ;;
    put:global)
        [ "${MOCK_SETTINGS_FAIL_PUT:-0}" = "0" ] || exit 1
        printf '%s' "$4" > "$MOCK_STATE_DIR/$3"
        ;;
    *) exit 1 ;;
esac
EOF

cat > "$MOCK_BIN/android_cmd" <<'EOF'
#!/bin/sh
case "$1:$2" in
    phone:set-sim-count)
        [ "${MOCK_CMD_FAIL_SIM:-0}" = "0" ] || exit 1
        printf '%s' "$3" > "$MOCK_STATE_DIR/sim_count"
        ;;
    *) exit 1 ;;
esac
EOF

cat > "$MOCK_BIN/android_getprop" <<'EOF'
#!/bin/sh
case "$1" in
    init.svc.vendor.thermal-hal) cat "$MOCK_STATE_DIR/thermal_service_state" ;;
    init.svc.*) printf 'stopped\n' ;;
    *) printf '\n' ;;
esac
EOF

cat > "$MOCK_BIN/android_stop" <<'EOF'
#!/bin/sh
printf 'stopped' > "$MOCK_STATE_DIR/thermal_service_state"
EOF

cat > "$MOCK_BIN/android_start" <<'EOF'
#!/bin/sh
count=$(cat "$MOCK_STATE_DIR/thermal_start_count" 2>/dev/null || printf '0')
case "$count" in ''|*[!0-9]*) count=0 ;; esac
fail_count="${MOCK_START_FAIL_COUNT:-0}"
case "$fail_count" in ''|*[!0-9]*) fail_count=0 ;; esac
if [ "$count" -lt "$fail_count" ]; then
    printf '%s' "$((count + 1))" > "$MOCK_STATE_DIR/thermal_start_count"
    exit 1
fi
printf 'running' > "$MOCK_STATE_DIR/thermal_service_state"
EOF

cat > "$MOCK_BIN/android_log" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod +x "$MOCK_BIN/android_settings" "$MOCK_BIN/android_cmd" \
    "$MOCK_BIN/android_getprop" "$MOCK_BIN/android_stop" "$MOCK_BIN/android_start" \
    "$MOCK_BIN/android_log" || exit 2

run_cgi() {
    _test_script="$1"
    _test_body="$2"
    _test_settings_fail="${3:-0}"
    _test_cmd_fail="${4:-0}"
    _test_start_fail_count="${5:-0}"
    _test_len=$(printf '%s' "$_test_body" | wc -c | tr -d ' ')
    printf '%s' "$_test_body" | env \
        MOCK_STATE_DIR="$MOCK_STATE_DIR" \
        MOCK_SETTINGS_FAIL_PUT="$_test_settings_fail" \
        MOCK_CMD_FAIL_SIM="$_test_cmd_fail" \
        MOCK_START_FAIL_COUNT="$_test_start_fail_count" \
        PIXEL9PRO_CGI_TEST_MODE=1 \
        PIXEL9PRO_ANDROID_SETTINGS="$MOCK_BIN/android_settings" \
        PIXEL9PRO_ANDROID_CMD="$MOCK_BIN/android_cmd" \
        PIXEL9PRO_ANDROID_GETPROP="$MOCK_BIN/android_getprop" \
        PIXEL9PRO_ANDROID_STOP="$MOCK_BIN/android_stop" \
        PIXEL9PRO_ANDROID_START="$MOCK_BIN/android_start" \
        PIXEL9PRO_ANDROID_LOG="$MOCK_BIN/android_log" \
        PIXEL9PRO_MODDIR="$FIXTURE" \
        REQUEST_METHOD=POST \
        REMOTE_ADDR=127.0.0.1 \
        CONTENT_TYPE=application/json \
        CONTENT_LENGTH="$_test_len" \
        HTTP_X_PIXEL9PRO_TOKEN=fixture-token \
        sh "$FIXTURE/webroot/cgi-bin/$_test_script"
}

run_get_cgi() {
    _test_script="$1"
    env \
        PIXEL9PRO_CGI_TEST_MODE=1 \
        PIXEL9PRO_MODDIR="$FIXTURE" \
        PIXEL9PRO_UECAP_TARGET="$FIXTURE/uecap_target.binarypb" \
        REQUEST_METHOD=GET \
        REMOTE_ADDR=127.0.0.1 \
        sh "$FIXTURE/webroot/cgi-bin/$_test_script"
}

printf '4' > "$FIXTURE/.thermal_offset"
response=$(run_get_cgi set_thermal.sh)
assert_contains 'thermal GET exposes backend-owned UI contract' "$response" '"thermal_contract":{"offsets":[-2,0,2,4,6],"default_offset":4}'

response=$(run_get_cgi bg_restrict.sh)
assert_contains 'BG GET exposes backend-owned UI contract' "$response" '"bg_contract":{"policy_order":["stop_after_leave","block_all","block_services","bucket"],"allowed_delays":[3,5,10],"default_policy":"stop_after_leave","default_delay":5}'

printf 'manual' > "$FIXTURE/.uecap_policy"
printf 'balanced' > "$FIXTURE/.uecap_mode"
printf 'balanced' > "$FIXTURE/.uecap_manual_mode"
printf 'fixture' > "$FIXTURE/.uecap_reason"
response=$(run_get_cgi uecap.sh)
assert_contains 'UECap GET exposes backend-owned UI contract' "$response" '"uecap_contract":{"mode_order":["balanced","special","universal"],"default_mode":"balanced"}'

printf 'disabled' > "$FIXTURE/.uecap_policy"
printf 'uecap_unsupported_device' > "$FIXTURE/.uecap_reason"
response=$(run_get_cgi uecap.sh)
assert_contains 'disabled UECap keeps legacy fields' "$response" '"disabled":true'
assert_contains 'disabled UECap adds an empty mode contract' "$response" '"uecap_contract":{"mode_order":[],"default_mode":"disabled"}'
printf 'manual' > "$FIXTURE/.uecap_policy"

printf 'on' > "$FIXTURE/.nr_screen_switch"
printf '33' > "$FIXTURE/.nr_saved_mode"
printf '11' > "$MOCK_STATE_DIR/preferred_network_mode"
response=$(run_cgi nr_switch.sh '{"action":"set","enabled":"off"}' 1 0)
assert_contains 'NR command failure returns HTTP error' "$response" 'Status: 500 Internal Server Error'
assert_eq 'NR command failure keeps automation enabled' on "$(cat "$FIXTURE/.nr_screen_switch")"
assert_eq 'NR command failure keeps prior RAT mode' 11 "$(cat "$MOCK_STATE_DIR/preferred_network_mode")"

response=$(run_cgi nr_switch.sh '{"action":"set","enabled":"off"}' 0 0)
assert_contains 'NR success returns ok' "$response" '"ok":true'
assert_eq 'NR success commits automation state' off "$(cat "$FIXTURE/.nr_screen_switch")"
assert_eq 'NR success restores saved RAT mode' 33 "$(cat "$MOCK_STATE_DIR/preferred_network_mode")"

printf 'on' > "$FIXTURE/.sim2_auto_manage"
printf 'off' > "$FIXTURE/.idle_isolate_mode"
printf 'disabled' > "$FIXTURE/.sim2_radio_off"
response=$(run_cgi standby_guard.sh '{"sim2_auto_manage":"off"}' 0 1)
assert_contains 'SIM2 restore failure returns HTTP error' "$response" 'Status: 500 Internal Server Error'
assert_eq 'SIM2 restore failure keeps automation enabled' on "$(cat "$FIXTURE/.sim2_auto_manage")"
assert_eq 'SIM2 restore failure keeps disabled marker' disabled "$(cat "$FIXTURE/.sim2_radio_off")"

response=$(run_cgi standby_guard.sh '{"sim2_auto_manage":"off"}' 0 0)
assert_contains 'SIM2 success returns ok' "$response" '"ok":true'
assert_eq 'SIM2 success commits automation state' off "$(cat "$FIXTURE/.sim2_auto_manage")"
assert_eq 'SIM2 success commits enabled marker' enabled "$(cat "$FIXTURE/.sim2_radio_off")"
assert_eq 'SIM2 success requests DSDS' 2 "$(cat "$MOCK_STATE_DIR/sim_count")"

printf 'on' > "$FIXTURE/.nr_screen_switch"
oversized=$(printf '%0300d' 0 | tr '0' 'x')
response=$(run_cgi nr_switch.sh "$oversized" 0 0)
assert_contains 'oversized JSON is rejected, not truncated' "$response" 'Status: 413 Payload Too Large'
assert_eq 'oversized JSON cannot mutate state' on "$(cat "$FIXTURE/.nr_screen_switch")"

response=$(run_cgi nr_switch.sh '[]' 0 0)
assert_contains 'non-object JSON is rejected' "$response" 'JSON object required'
assert_eq 'non-object JSON cannot mutate state' on "$(cat "$FIXTURE/.nr_screen_switch")"

mv "$FIXTURE/scripts/display_state_lib.sh" "$FIXTURE/scripts/display_state_lib.sh.missing" || exit 2
response=$(run_cgi owner_arbiter.sh '{"action":"invalid"}' 0 0)
assert_contains 'owner CGI fails explicitly when display-state dependency is missing' "$response" 'display state contract not found'
mv "$FIXTURE/scripts/display_state_lib.sh.missing" "$FIXTURE/scripts/display_state_lib.sh" || exit 2

response=$(run_cgi owner_arbiter.sh '{"action":"invalid"}' 0 0)
assert_contains 'owner arbiter rejects an unknown action before runtime execution' "$response" 'invalid owner arbiter action'

printf '4' > "$FIXTURE/.thermal_offset"
printf 'running' > "$MOCK_STATE_DIR/thermal_service_state"
printf '0' > "$MOCK_STATE_DIR/thermal_start_count"
thermal_before=$(sha256sum "$FIXTURE/system/vendor/etc/thermal_info_config.json" | awk '{print $1}')
response=$(run_cgi set_thermal.sh '{"offset":2}' 0 0 2)
thermal_after=$(sha256sum "$FIXTURE/system/vendor/etc/thermal_info_config.json" | awk '{print $1}')
assert_contains 'thermal restart failure returns HTTP error' "$response" 'previous config restored'
assert_eq 'thermal restart failure restores config bytes' "$thermal_before" "$thermal_after"
assert_eq 'thermal restart failure restores offset' 4 "$(cat "$FIXTURE/.thermal_offset")"
assert_eq 'thermal rollback restarts prior service' running "$(cat "$MOCK_STATE_DIR/thermal_service_state")"

printf 'running' > "$MOCK_STATE_DIR/thermal_service_state"
printf '0' > "$MOCK_STATE_DIR/thermal_start_count"
response=$(run_cgi set_thermal.sh '{"offset":2}' 0 0 0)
thermal_after=$(sha256sum "$FIXTURE/system/vendor/etc/thermal_info_config.json" | awk '{print $1}')
assert_contains 'thermal success returns ok' "$response" '"ok":true'
assert_eq 'thermal success commits offset' 2 "$(cat "$FIXTURE/.thermal_offset")"
if [ "$thermal_before" != "$thermal_after" ]; then
    ok 'thermal success commits regenerated config'
else
    not_ok 'thermal success commits regenerated config (hash unchanged)'
fi

printf '[{"zone":"VIRTUAL-SKIN","temp":42000}]' > "$FIXTURE/.thermal_cache.json"
response=$(run_cgi thermal.sh '{"action":"clear"}' 0 0 0)
assert_contains 'thermal cache clear returns a live JSON response' "$response" 'Content-Type: application/json'
if [ ! -e "$FIXTURE/.thermal_cache.json" ]; then
    ok 'thermal cache clear commits deletion'
else
    not_ok 'thermal cache clear commits deletion (cache still exists)'
fi

mkdir "$FIXTURE/.thermal_cache.json" || exit 2
response=$(run_cgi thermal.sh '{"action":"clear"}' 0 0 0)
assert_contains 'thermal cache directory is rejected' "$response" 'thermal cache path is a directory'
if [ ! -d "$FIXTURE/.locks/thermal_cache.lock" ]; then
    ok 'thermal cache failure releases mutation lock'
else
    not_ok 'thermal cache failure releases mutation lock (lock remains)'
fi
rmdir "$FIXTURE/.thermal_cache.json" || exit 2

printf '1..%s\n' "$((PASS + FAIL))"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
