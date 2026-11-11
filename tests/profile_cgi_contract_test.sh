#!/system/bin/sh
# Real profile CGI -> real finite scheduler worker -> real compact GET.
# Only owner/reconcile command boundaries and display input are fixtures.
SOURCE_ROOT="${1:-/sdcard/Download/Pixel9Pro-Control-TestLab/candidate/control}"
TEST_ROOT="${2:-/sdcard/Download/Pixel9Pro-Control-TestLab/runtime/profile_cgi_$$}"
FIXTURE="$TEST_ROOT/mod"
FAS="$TEST_ROOT/fas"
PASS=0; FAIL=0; TOTAL=0

ok() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); printf 'ok %s - %s\n' "$TOTAL" "$1"; }
not_ok() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); printf 'not ok %s - %s\n' "$TOTAL" "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 expected=$2 actual=$3"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) not_ok "$1 missing=$3" ;; esac; }
assert_absent() { if [ ! -e "$2" ]; then ok "$1"; else not_ok "$1 remains=$2"; fi; }
command_count() { if [ -f "$TEST_ROOT/commands" ]; then wc -l < "$TEST_ROOT/commands" | tr -d ' '; else printf 0; fi; }

mkdir -p "$FIXTURE/webroot/cgi-bin" "$FIXTURE/scripts" "$FAS" "$TEST_ROOT/bin" || exit 2
for name in _common.sh profile.sh; do cp "$SOURCE_ROOT/webroot/cgi-bin/$name" "$FIXTURE/webroot/cgi-bin/" || exit 2; done
for name in scheduler_capability_lib.sh scheduler_detect_lib.sh scheduler_owner_lib.sh cpu_profile_lib.sh \
    scheduler_boot_mode_lib.sh scheduler_transition_guard_lib.sh profile_state_lib.sh \
    scheduler_async_lib.sh scheduler_async_worker.sh state_io_lib.sh background_tasks_lib.sh display_state_lib.sh; do
    cp "$SOURCE_ROOT/scripts/$name" "$FIXTURE/scripts/" || exit 2
done
# Explicit external command boundaries; the production async engine is intact.
cat > "$FIXTURE/scripts/owner_arbiter.sh" <<'EOF'
#!/system/bin/sh
[ "$1" = apply-tick ] && [ "$2" = "$PROFILE_TEST_ROOT/mod" ] && [ "$3" = on ] || exit 64
printf 'owner\n' >> "$PROFILE_TEST_ROOT/commands"
attempt=0
while [ -f "$PROFILE_TEST_ROOT/hold" ] && [ "$attempt" -lt 250 ]; do
    sleep 0.02; attempt=$((attempt+1))
done
[ ! -f "$PROFILE_TEST_ROOT/hold" ] || exit 124
exit "$(cat "$PROFILE_TEST_ROOT/result")"
EOF
cat > "$FIXTURE/scripts/scheduler_reconcile.sh" <<'EOF'
#!/system/bin/sh
[ "$1" = retry ] && [ "$2" = "$PROFILE_TEST_ROOT/mod" ] || exit 64
printf 'retry\n' >> "$PROFILE_TEST_ROOT/commands"
exit "$(cat "$PROFILE_TEST_ROOT/result")"
EOF
cat > "$TEST_ROOT/bin/log" <<'EOF'
#!/system/bin/sh
exit 0
EOF
chmod 700 "$TEST_ROOT/bin/log" || exit 2
export PROFILE_TEST_ROOT="$TEST_ROOT"
export PATH="$TEST_ROOT/bin:$PATH"
printf fixture-token > "$FIXTURE/.webui_token"
printf active > "$FIXTURE/.scheduler_mode"
printf supported > "$FIXTURE/.scheduler_capability"
printf balanced > "$FIXTURE/.current_profile"
printf balanced > "$FIXTURE/.profile_manual"
printf manual > "$FIXTURE/.profile_policy"
printf manual_policy > "$FIXTURE/.profile_auto_reason"
printf pixel > "$FIXTURE/.sched_owner_desired"
printf pixel > "$FIXTURE/.cpu_sched_owner"
printf fas_rs > "$FIXTURE/.game_handoff_policy"
printf default > "$FIXTURE/.game_handoff_source"
cat /proc/sys/kernel/random/boot_id > "$FIXTURE/.boot_id"
cat > "$FIXTURE/.scheduler_boot_state" <<'EOF'
schema=1
transition_id=profile-cgi-fixture
target_mode=pixel
effective_mode=pixel
phase=success
final=yes
ok=yes
result=active_pixel
reason=fixture
attempts=0
deadline_epoch=0
staged_boot_id=
observed_boot_id=fixture
previous_desired=pixel
previous_module_state=disabled
auto_repair_used=no
reboot_required=no
updated_epoch=1
EOF

run_profile_cgi() {
    _test_method="$1"; _test_body="$2"; _test_screen="${3:-true}"
    _test_len=$(printf '%s' "$_test_body" | wc -c | tr -d ' ')
    printf '%s' "$_test_body" | env \
        PIXEL9PRO_MODDIR="$FIXTURE" PIXEL9PRO_FAS_ROOT="$FAS" \
        PIXEL9PRO_LOCKDIR_BASE="$FIXTURE/.locks" SO_BOOT_ID_PATH="$FIXTURE/.boot_id" \
        DISPLAY_STATE_TEST_MODE=1 DISPLAY_STATE_TEST_SCREEN="$_test_screen" \
        REQUEST_METHOD="$_test_method" QUERY_STRING=compact=1 REMOTE_ADDR=127.0.0.1 \
        CONTENT_TYPE=application/json CONTENT_LENGTH="$_test_len" \
        HTTP_X_PIXEL9PRO_TOKEN=fixture-token sh "$FIXTURE/webroot/cgi-bin/profile.sh"
}

wait_terminal() {
    _test_attempt=0
    while [ "$_test_attempt" -lt 80 ]; do
        response=$(run_profile_cgi GET '') || return 1
        case "$response" in *'"pending":false'*) return 0 ;; esac
        sleep 0.05; _test_attempt=$((_test_attempt+1))
    done
    not_ok 'real worker did not reach an observable terminal state'
    return 1
}
wait_command_count() {
    _test_attempt=0
    while [ "$(command_count)" -lt "$1" ] && [ "$_test_attempt" -lt 80 ]; do
        sleep 0.025; _test_attempt=$((_test_attempt+1))
    done
    [ "$(command_count)" -eq "$1" ]
}
record_response() { printf '@@%s\n%s\n@@END\n' "$1" "$response"; }

printf 'TAP version 13\n'
printf 0 > "$TEST_ROOT/result"
: > "$TEST_ROOT/hold"
response=$(run_profile_cgi POST '{"game_handoff":"off"}')
record_response accepted
assert_contains 'handoff accepts durable intent before worker exits' "$response" '"accepted":true'
assert_contains 'accepted handoff is committed but not final' "$response" '"committed":true,"final":false'
assert_eq 'accepted handoff commits requested policy' off "$(cat "$FIXTURE/.game_handoff_policy")"
assert_eq 'accepted handoff records explicit user source' user "$(cat "$FIXTURE/.game_handoff_source")"
wait_command_count 1 || not_ok 'first real worker did not invoke its boundary'
response=$(run_profile_cgi GET '')
record_response pending
assert_contains 'GET observes running worker' "$response" '"phase":"running","pending":true'
first_id=$(sed -n 's/^id=//p' "$FIXTURE/.scheduler_async_state")
response=$(run_profile_cgi POST '{"game_handoff":"off"}')
record_response busy
assert_contains 'second mutation while job runs is rejected' "$response" 'Status: 409 Conflict'
assert_eq 'busy rejection preserves the running job identity' "$first_id" "$(sed -n 's/^id=//p' "$FIXTURE/.scheduler_async_state")"
assert_eq 'busy rejection never dispatches another owner command' 1 "$(command_count)"
rm "$TEST_ROOT/hold" || exit 2
wait_terminal || exit 1
record_response success
assert_contains 'successful worker result is observed via GET' "$response" '"phase":"success","pending":false,"result_code":0'
assert_absent 'successful worker releases operation lock' "$FIXTURE/.scheduler_async.lock"

printf 1 > "$TEST_ROOT/result"
response=$(run_profile_cgi POST '{"game_handoff":"off"}')
assert_contains 'failed downstream action still initially accepts saved choice' "$response" '"accepted":true'
assert_contains 'failure cannot be synchronously claimed by POST' "$response" '"final":false'
wait_terminal || exit 1
record_response failed
assert_contains 'worker failure is terminal and retains exact result' "$response" '"phase":"failed","pending":false,"result_code":1'
assert_eq 'worker failure preserves accepted handoff preference' off "$(cat "$FIXTURE/.game_handoff_policy")"
assert_eq 'worker failure preserves explicit choice source' user "$(cat "$FIXTURE/.game_handoff_source")"
assert_absent 'failed worker releases operation lock' "$FIXTURE/.scheduler_async.lock"

printf 75 > "$TEST_ROOT/result"
response=$(run_profile_cgi POST '{"game_handoff":"off"}')
assert_contains 'deferred downstream work initially accepts saved choice' "$response" '"accepted":true'
wait_terminal || exit 1
record_response deferred
assert_contains 'busy owner boundary becomes deferred without replay' "$response" '"phase":"deferred","pending":false,"result_code":75'
assert_eq 'one owner call per accepted job' 3 "$(command_count)"
response=$(run_profile_cgi GET '')
assert_eq 'GET never replays a deferred mutation' 3 "$(command_count)"

printf 0 > "$TEST_ROOT/result"
response=$(run_profile_cgi POST '{"game_handoff":"off"}' false)
assert_contains 'screen-off request accepts persistent preference' "$response" '"accepted":true'
wait_terminal || exit 1
record_response screen_off
assert_contains 'screen-off worker defers' "$response" '"phase":"deferred","pending":false,"result_code":75'
assert_eq 'screen-off worker does not invoke owner mutation' 3 "$(command_count)"

sed 's/^phase=success$/phase=failed/' "$FIXTURE/.scheduler_boot_state" > "$TEST_ROOT/boot.failed"
cp "$TEST_ROOT/boot.failed" "$FIXTURE/.scheduler_boot_state" || exit 2
response=$(run_profile_cgi POST '{"scheduler_action":"retry"}')
assert_contains 'explicit retry is accepted asynchronously' "$response" '"accepted":true,"final":false'
wait_terminal || exit 1
record_response retry
assert_contains 'retry worker reports its actual terminal result' "$response" '"kind":"retry","phase":"success","pending":false,"result_code":0'
assert_eq 'retry boundary is dispatched exactly once' 4 "$(command_count)"
sed 's/^phase=failed$/phase=success/' "$FIXTURE/.scheduler_boot_state" > "$TEST_ROOT/boot.success"
cp "$TEST_ROOT/boot.success" "$FIXTURE/.scheduler_boot_state" || exit 2

# Actual filesystem error after persistence: reset cannot unlink a directory.
# The real preference transaction must restore both prior fields, with no job.
printf fas_rs > "$FIXTURE/.game_handoff_policy"
printf default > "$FIXTURE/.game_handoff_source"
mkdir "$FAS/.owner_mutation_guard" || exit 2
response=$(run_profile_cgi POST '{"game_handoff":"off"}')
record_response rollback
assert_contains 'guard reset failure is a real error' "$response" 'Status: 500 Internal Server Error'
assert_contains 'guard failure reports verified preference restoration' "$response" 'previous policy restored'
assert_eq 'guard failure rolls preference back' fas_rs "$(cat "$FIXTURE/.game_handoff_policy")"
assert_eq 'guard failure rolls source back' default "$(cat "$FIXTURE/.game_handoff_source")"
assert_eq 'rollback failure path never launches a worker' 4 "$(command_count)"
rmdir "$FAS/.owner_mutation_guard" || exit 2

# Failed queue commit is not the same as a failed preference transaction.
rm "$FIXTURE/.scheduler_async_state" || exit 2
mkdir "$FIXTURE/.scheduler_async_state" || exit 2
response=$(run_profile_cgi POST '{"game_handoff":"off"}')
record_response queue_failure
assert_contains 'queue persistence failure is explicit' "$response" 'Status: 500 Internal Server Error'
assert_contains 'queue error distinguishes saved choice from unstarted work' "$response" 'handoff preference saved; reconciliation could not start'
assert_eq 'queue failure retains already saved preference' off "$(cat "$FIXTURE/.game_handoff_policy")"
assert_eq 'queue failure retains explicit source' user "$(cat "$FIXTURE/.game_handoff_source")"
assert_eq 'queue persistence failure never starts worker' 4 "$(command_count)"
assert_absent 'queue failure releases acquired lock' "$FIXTURE/.scheduler_async.lock"
rmdir "$FIXTURE/.scheduler_async_state" || exit 2

response=$(run_profile_cgi POST '{"game_handoff":"invalid"}')
record_response invalid
assert_contains 'invalid handoff is rejected before persistence' "$response" 'Status: 400 Bad Request'
assert_eq 'invalid handoff preserves preference' off "$(cat "$FIXTURE/.game_handoff_policy")"
assert_eq 'invalid input never starts worker' 4 "$(command_count)"
assert_absent 'invalid input does not create async receipt' "$FIXTURE/.scheduler_async_state"

cat > "$FIXTURE/.scheduler_async_state" <<EOF
id=dead-worker
boot_id=$(cat /proc/sys/kernel/random/boot_id)
kind=handoff
phase=running
rc=0
uptime=1
EOF
response=$(run_profile_cgi GET '')
record_response unconfirmed
assert_contains 'missing worker is not successful or pending forever' "$response" '"phase":"unconfirmed","pending":false'
assert_eq 'observation never replays a dead worker' 4 "$(command_count)"
printf '1..%s\n' "$TOTAL"
[ "$FAIL" -eq 0 ]
