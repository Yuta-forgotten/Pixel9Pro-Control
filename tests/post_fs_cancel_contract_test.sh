#!/bin/sh
set -eu

# Exercise the current authenticated thermal journal API and observation-only
# boot hook. No slot-transaction library or device mutation is involved.
SOURCE_ROOT="${1:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
TEST_ROOT="${2:-$SOURCE_ROOT/tmp/thermal-cancel-$$}"
case "$TEST_ROOT" in "$SOURCE_ROOT"/tmp/thermal-cancel-*|/tmp/pixel9pro_*|/sdcard/Download/Pixel9Pro-Control-TestLab/runtime/*) ;; *) exit 64 ;; esac
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (expected=$2 actual=$3)"; fi; }
assert_status() {
    if [ "$2" = 200 ]; then
        if ! grep -q '^Status:' "$RESPONSE"; then ok "$1"; else not_ok "$1"; fi
    elif grep -q "^Status: $2 " "$RESPONSE"; then ok "$1"; else not_ok "$1"; fi
}

mkdir -p "$TEST_ROOT" || exit 2
FIXTURE_REAL_MV=$(command -v mv)
export FIXTURE_REAL_MV
prepare_pending() {
    CASE_ROOT="$TEST_ROOT/$1"
    MODULE="$CASE_ROOT/module"
    mkdir -p "$MODULE/system/vendor/etc" "$MODULE/scripts" "$MODULE/webroot/cgi-bin" "$MODULE/.thermal_tx" "$CASE_ROOT/bin" || exit 2
    rm -f "$CASE_ROOT/bin/mv" "$MODULE/.fail_policy_once" "$MODULE/.fail_policy_committed"
    # Fixture dependency manifest follows only production source dependencies.
    for lib in thermal_profile.sh thermal_policy_lib.sh; do
        cp "$SOURCE_ROOT/scripts/$lib" "$MODULE/scripts/" || exit 2
    done
    for cgi in _common.sh set_thermal.sh; do
        cp "$SOURCE_ROOT/webroot/cgi-bin/$cgi" "$MODULE/webroot/cgi-bin/" || exit 2
    done
    cp "$SOURCE_ROOT/post-fs-data.sh" "$MODULE/" || exit 2
    printf caiman > "$MODULE/.device_variant"
    printf fixture-token > "$MODULE/.webui_token"
    printf old-config > "$MODULE/.thermal_tx/source"
    printf new-config > "$MODULE/system/vendor/etc/thermal_info_config.json"
    printf custom > "$MODULE/.thermal_policy"
    printf 4 > "$MODULE/.thermal_offset"
    OLD_HASH=$(sha256sum "$MODULE/.thermal_tx/source" | awk '{print $1}')
    NEW_HASH=$(sha256sum "$MODULE/system/vendor/etc/thermal_info_config.json" | awk '{print $1}')
    BOOT=$(cat /proc/sys/kernel/random/boot_id)
    {
        printf 'id=123.456\nphase=staged\nboot_id=%s\n' "$BOOT"
        printf 'policy=custom\noffset=2\npresent=1\nhash=%s\ncontext=none\nbase_valid=1\n' "$OLD_HASH"
        printf 'desired_policy=custom\ndesired_offset=4\ndesired_hash=%s' "$NEW_HASH"
    } > "$MODULE/.thermal_tx/meta"
    cp "$MODULE/.thermal_tx/meta" "$CASE_ROOT/original-meta"
    RESPONSE="$CASE_ROOT/response"
}

cancel_pending() {
    _request=$(printf '{"action":"cancel_pending","pending_id":"%s"}' "${1:-123.456}")
    printf '%s' "$_request" | env REQUEST_METHOD=POST REMOTE_ADDR=127.0.0.1 \
        CONTENT_TYPE=application/json CONTENT_LENGTH="${#_request}" \
        HTTP_X_PIXEL9PRO_TOKEN="${2-fixture-token}" PIXEL9PRO_MODDIR="$MODULE" \
        PATH="$CASE_ROOT/bin:$PATH" sh "$MODULE/webroot/cgi-bin/set_thermal.sh" > "$RESPONSE"
}

assert_desired_preserved() {
    assert_eq "$1 source preserved" new-config "$(cat "$MODULE/system/vendor/etc/thermal_info_config.json")"
    assert_eq "$1 policy preserved" custom "$(cat "$MODULE/.thermal_policy")"
    assert_eq "$1 offset preserved" 4 "$(cat "$MODULE/.thermal_offset")"
    if cmp -s "$CASE_ROOT/original-meta" "$MODULE/.thermal_tx/meta" \
        && [ "$(sha256sum "$MODULE/.thermal_tx/source" | awk '{print $1}')" = "$OLD_HASH" ]; then
        ok "$1 journal remains retryable"
    else
        not_ok "$1 journal remains retryable"
    fi
}

prepare_pending match
PIXEL9PRO_MODDIR="$MODULE" sh "$MODULE/post-fs-data.sh"
assert_desired_preserved 'boot observation'
cancel_pending
assert_status 'matching authenticated cancel succeeds' 200
assert_eq 'cancel restores previous source' old-config "$(cat "$MODULE/system/vendor/etc/thermal_info_config.json")"
assert_eq 'cancel restores previous policy' custom "$(cat "$MODULE/.thermal_policy")"
assert_eq 'cancel restores previous offset' 2 "$(cat "$MODULE/.thermal_offset")"
if [ ! -e "$MODULE/.thermal_tx/meta" ] && [ ! -e "$MODULE/.thermal_tx/source" ]; then
    ok 'successful cancel consumes journal'
else
    not_ok 'successful cancel consumes journal'
fi

prepare_pending mismatch
cancel_pending wrong-id
assert_status 'mismatched pending id is rejected' 409
assert_desired_preserved 'id rejection'

prepare_pending unauthorized
cancel_pending 123.456 ''
assert_status 'missing token is rejected' 403
assert_desired_preserved 'authentication rejection'

prepare_pending invalid
sed 's/^base_valid=1$/base_valid=0/' "$MODULE/.thermal_tx/meta" > "$CASE_ROOT/meta"
mv "$CASE_ROOT/meta" "$MODULE/.thermal_tx/meta"
cp "$MODULE/.thermal_tx/meta" "$CASE_ROOT/original-meta"
cancel_pending
assert_status 'invalid rollback baseline is rejected' 409
assert_desired_preserved 'baseline rejection'

prepare_pending crossboot
sed 's/^boot_id=.*/boot_id=previous-boot/' "$MODULE/.thermal_tx/meta" > "$CASE_ROOT/meta"
mv "$CASE_ROOT/meta" "$MODULE/.thermal_tx/meta"
cp "$MODULE/.thermal_tx/meta" "$CASE_ROOT/original-meta"
cancel_pending
assert_status 'cross-boot cancellation is rejected without effective readback' 409
assert_desired_preserved 'cross-boot rejection'

prepare_pending changed
printf external-change > "$MODULE/system/vendor/etc/thermal_info_config.json"
cancel_pending
assert_status 'externally changed desired source is rejected' 409
assert_eq 'external source is not overwritten' external-change "$(cat "$MODULE/system/vendor/etc/thermal_info_config.json")"

prepare_pending system-baseline
sed 's/^policy=custom$/policy=system/; s/^offset=2$/offset=0/; s/^present=1$/present=0/; s/^hash=.*/hash=none/' \
    "$MODULE/.thermal_tx/meta" > "$CASE_ROOT/meta"
mv "$CASE_ROOT/meta" "$MODULE/.thermal_tx/meta"
rm -f "$MODULE/.thermal_tx/source"
cancel_pending
assert_status 'system baseline cancel succeeds' 200
assert_eq 'system baseline restores policy' system "$(cat "$MODULE/.thermal_policy")"
assert_eq 'system baseline restores zero offset' 0 "$(cat "$MODULE/.thermal_offset")"
if [ ! -e "$MODULE/system/vendor/etc/thermal_info_config.json" ] && [ ! -e "$MODULE/.thermal_tx/meta" ]; then
    ok 'system baseline removes custom source and consumes journal'
else
    not_ok 'system baseline removes custom source and consumes journal'
fi

# Fail the policy marker's first rename after the old source was restored.
# A successful compensation must put the desired source back and retain the
# journal, so the next authenticated cancel can safely retry.
prepare_pending marker-failure
cat > "$CASE_ROOT/bin/mv" <<'EOF'
#!/bin/sh
for target do :; done
case "$target" in
    */.thermal_policy)
        failure="${target%/*}/.fail_policy_once"
        if [ ! -e "$failure" ]; then : > "$failure"; exit 1; fi
        ;;
esac
exec "$FIXTURE_REAL_MV" "$@"
EOF
chmod 755 "$CASE_ROOT/bin/mv"
cancel_pending
assert_status 'marker write failure returns an error' 500
assert_desired_preserved 'cancel compensation'
cancel_pending
assert_status 'cancel can retry after completed compensation' 200
assert_eq 'retry restores previous source' old-config "$(cat "$MODULE/system/vendor/etc/thermal_info_config.json")"
assert_eq 'retry restores previous offset' 2 "$(cat "$MODULE/.thermal_offset")"

# The second policy write is compensation; refuse it after failing the offset
# write so the endpoint must expose an incomplete rollback and retain backups.
prepare_pending rollback-incomplete
sed 's/^policy=custom$/policy=system/; s/^offset=2$/offset=0/; s/^present=1$/present=0/; s/^hash=.*/hash=none/' \
    "$MODULE/.thermal_tx/meta" > "$CASE_ROOT/meta"
mv "$CASE_ROOT/meta" "$MODULE/.thermal_tx/meta"
rm -f "$MODULE/.thermal_tx/source"
cat > "$CASE_ROOT/bin/mv" <<'EOF'
#!/bin/sh
for target do :; done
case "$target" in
    */.thermal_policy)
        failure="${target%/*}/.fail_policy_committed"
        [ ! -e "$failure" ] || exit 1
        : > "$failure"
        ;;
    */.thermal_offset) exit 1 ;;
esac
exec "$FIXTURE_REAL_MV" "$@"
EOF
chmod 755 "$CASE_ROOT/bin/mv"
cancel_pending
assert_status 'failed compensation is not reported as success' 500
if [ "$(cat "$MODULE/.thermal_policy")" = system ] \
    && [ -s "$MODULE/.thermal_tx/meta" ] \
    && [ -n "$(find "$MODULE/.thermal_tx" -maxdepth 1 -name 'restore_current.*' -type f -print)" ]; then
    ok 'incomplete rollback retains the desired-source recovery snapshot'
else
    not_ok 'incomplete rollback retains the desired-source recovery snapshot'
fi

printf '1..%s\n' "$((PASS + FAIL))"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
