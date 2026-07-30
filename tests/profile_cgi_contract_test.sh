#!/system/bin/sh

SOURCE_ROOT="${1:-/sdcard/Download/Pixel9Pro-Control-TestLab/candidate/control}"
TEST_ROOT="${2:-/sdcard/Download/Pixel9Pro-Control-TestLab/runtime/profile_cgi_$$}"
FIXTURE="$TEST_ROOT/mod"
FAS="$TEST_ROOT/fas"
PASS=0
FAIL=0
TOTAL=0

ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$TOTAL" "$1"; }
not_ok() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$TOTAL" "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 expected=$2 actual=$3"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) not_ok "$1 missing=$3" ;; esac; }

mkdir -p "$FIXTURE/webroot/cgi-bin" "$FIXTURE/scripts" "$FAS" || exit 2
cp "$SOURCE_ROOT/webroot/cgi-bin/_common.sh" "$FIXTURE/webroot/cgi-bin/" || exit 2
cp "$SOURCE_ROOT/webroot/cgi-bin/profile.sh" "$FIXTURE/webroot/cgi-bin/" || exit 2
for _test_script in scheduler_detect_lib.sh scheduler_owner_lib.sh cpu_profile_lib.sh \
    scheduler_boot_mode_lib.sh scheduler_transition_guard_lib.sh profile_state_lib.sh \
    foreground_app_lib.sh owner_arbiter_state_lib.sh owner_arbiter_observation_lib.sh \
    owner_arbiter_external_lib.sh owner_arbiter_cpufreq_lib.sh owner_arbiter.sh; do
    cp "$SOURCE_ROOT/scripts/$_test_script" "$FIXTURE/scripts/" || exit 2
done

printf 'fixture-token' > "$FIXTURE/.webui_token"
printf 'balanced\n' > "$FIXTURE/.current_profile"
printf 'balanced\n' > "$FIXTURE/.profile_manual"
printf 'manual\n' > "$FIXTURE/.profile_policy"
printf 'manual_policy\n' > "$FIXTURE/.profile_auto_reason"
printf 'pixel\n' > "$FIXTURE/.sched_owner_desired"
printf 'pixel\n' > "$FIXTURE/.cpu_sched_owner"
printf 'fas_rs\n' > "$FIXTURE/.game_handoff_policy"
printf 'default\n' > "$FIXTURE/.game_handoff_source"
printf 'fixture-boot-id\n' > "$FIXTURE/.boot_id"
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
    _test_body="$1"
    _test_reconcile_rc="$2"
    _test_len=$(printf '%s' "$_test_body" | wc -c | tr -d ' ')
    printf '%s' "$_test_body" | env \
        PIXEL9PRO_CGI_TEST_MODE=1 \
        PIXEL9PRO_TEST_RECONCILE_RC="$_test_reconcile_rc" \
        PIXEL9PRO_MODDIR="$FIXTURE" \
        PIXEL9PRO_FAS_ROOT="$FAS" \
        PIXEL9PRO_LOCKDIR_BASE="$FIXTURE/.locks" \
        SO_BOOT_ID_PATH="$FIXTURE/.boot_id" \
        REQUEST_METHOD=POST \
        REMOTE_ADDR=127.0.0.1 \
        CONTENT_TYPE=application/json \
        CONTENT_LENGTH="$_test_len" \
        HTTP_X_PIXEL9PRO_TOKEN=fixture-token \
        sh "$FIXTURE/webroot/cgi-bin/profile.sh"
}

printf 'TAP version 13\n'

response=$(run_profile_cgi '{"game_handoff":"off"}' 75)
assert_contains 'busy reconcile accepts the persisted preference' "$response" '"accepted":true'
assert_contains 'busy reconcile remains nonterminal' "$response" '"final":false'
assert_contains 'busy reconcile reports pending instead of failure' "$response" '"ok":true'
assert_eq 'busy reconcile commits requested handoff policy' off "$(cat "$FIXTURE/.game_handoff_policy")"
assert_eq 'busy reconcile records explicit user choice' user "$(cat "$FIXTURE/.game_handoff_source")"

response=$(run_profile_cgi '{"game_handoff":"off"}' 0)
assert_contains 'completed reconcile reports terminal success' "$response" '"final":true'
assert_contains 'completed reconcile reports ok' "$response" '"ok":true'

response=$(run_profile_cgi '{"game_handoff":"off"}' 1)
assert_contains 'terminal reconcile failure preserves accepted intent' "$response" '"accepted":true'
assert_contains 'terminal reconcile failure is final' "$response" '"final":true'
assert_contains 'terminal reconcile failure reports not ok' "$response" '"ok":false'

printf '1..%s\n' "$TOTAL"
[ "$FAIL" -eq 0 ]
